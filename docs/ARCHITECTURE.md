# アーキテクチャ

SwingDuet の技術スタック・モジュール構成・主要な仕組み（同期・再生・フェーズ検出・永続化）の索引。
機能要件は [SPEC.md](./SPEC.md)、ビルド手順は [guides/build-test.md](./guides/build-test.md)。

## 1. 技術スタック

| カテゴリ         | 技術                                                                                          |
| ---------------- | --------------------------------------------------------------------------------------------- |
| UI               | SwiftUI（`AVPlayerLayer` のみ `UIViewRepresentable` でブリッジ: `PlayerLayerView`）           |
| 動画再生         | AVFoundation（`AVPlayer` × 2 本、`rate` と `seek` で同期）                                     |
| フレーム読み出し | AVFoundation `AVAssetReader`（解析用に 30fps 相当へ間引き）                                    |
| 姿勢推定         | Vision `VNDetectHumanBodyPoseRequest`（左右手首の平均位置を追跡）                             |
| 動画の取り込み   | PhotosUI `PhotosPicker` + CoreTransferable `FileRepresentation(contentType: .movie)`          |
| 永続化           | JSON（`Documents/projects.json`）+ 動画ファイル（`Documents/Videos/`）。**外部依存なし**       |
| 言語 / 最低 OS   | Swift 5 言語モード / iOS 17                                                                    |
| プロジェクト     | `SwingDuet.xcodeproj`（手書き。`PBXFileSystemSynchronizedRootGroup` で `SwingDuet/` 配下を自動収集） |

## 2. モジュール構成

```
SwingDuet/
├── SwingDuetApp.swift            # エントリ。ProjectStore を環境に注入、ダーク固定
├── Models/
│   ├── SwingModels.swift         # SwingPhase / SwingSegment / PhaseSet / VideoConfig / ComparisonProject
│   └── SyncEngine.swift          # 共通タイムライン ⇔ 各動画時刻の区間別線形写像（§3）
├── Services/
│   ├── SwingAnalyzer.swift       # Vision 手首追跡 + スイング区間の検出と 4 フェーズ決定（§5）
│   ├── VideoImporter.swift       # PhotosPicker 用 Transferable（ImportedMovie）・メタデータ取得
│   └── ProjectStore.swift        # プロジェクト永続化（JSON + 動画ファイル管理）
├── Playback/
│   └── PlaybackController.swift  # CADisplayLink マスタークロック + 区間別レート再生（§4）
└── Views/
    ├── ProjectListView.swift     # プロジェクト一覧（NavigationStack のルート）
    ├── NewComparisonView.swift   # 動画選択 + 解析 → プロジェクト作成
    ├── ComparisonView.swift      # 比較画面本体（ペイン・テンポ・基準切替・シークバー・操作）
    ├── VideoPaneView.swift       # 動画ペイン（反転・ピンチ位置を中心にした拡大縮小・位置合わせ。指を離した時点で config に確定）
    ├── SeekBarView.swift         # 区間色分きの共通シークバー
    ├── TransportControlsView.swift # フェーズジャンプ / コマ送り / 再生 / 速度 / ループ
    ├── PhaseEditView.swift       # フェーズ手動修正（マーカードラッグ・±コマ）
    └── PlayerLayerView.swift     # AVPlayerLayer ラッパー
```

依存方向は Views → Playback / Services → Models。Models は他に依存しない純粋な値型。

ペインの拡大率・位置は `VideoConfig.scale / offsetX / offsetY`（pt）に保存する。ジェスチャー中は `@GestureState` の一時値で描画し、
指を離した時点で `config` に確定 → `ComparisonView.onChange(of: project)` → `ProjectStore.update` で JSON に書く
（ジェスチャーの途中でディスクに書かないため）。ピンチ中はドラッグを無視する（2 本指の 1 本目がドラッグとして拾われ、ピンチ中心がずれるのを防ぐ）。

## 3. 同期の仕組み（SyncEngine）

- **共通タイムライン**の長さは基準側（`reference`）のスイング区間（アドレス〜フィニッシュ）と同じ
- トップ・インパクトの位置（`topBoundary` / `impactBoundary`）も基準側で決まる
- 非基準側は各区間（バックスイング / ダウンスイング / フォロー）を線形に伸縮して写像する（`videoTime(at:for:)`）。
  これにより 4 点が必ず一致する
- 区間ごとの速度倍率 `rateMultiplier(for:in:)` = その側の区間長 ÷ 基準側の区間長（基準側は常に 1.0）
- コマ送りの 1 ステップは基準側動画の 1 フレーム（`referenceFrameDuration`）

## 4. 再生の仕組み（PlaybackController）

- `CADisplayLink`（30〜60Hz）がマスタークロック。毎 tick で `commonTime += dt × speed`
- 各 `AVPlayer` は「再生速度 × 区間倍率」の `rate` で走らせ、区間境界で `rate` を切り替える
- 実時刻と期待時刻のドリフトが **80ms** を超えたらシークで補正（許容 20ms）。
  一時停止・ジャンプ・コマ送り・スクラブ終了時は許容ゼロの精密シーク
- ループ範囲は「全体」または 1 区間（`loopSegment`）。範囲を出たら先頭へ戻る（`loopEnabled` が false なら停止）
- フェーズ修正・基準切替時は `updateSync` で相対位置（進捗率）を保って追従する

## 5. フェーズ検出の仕組み（SwingAnalyzer）

Vision の手首座標による先行検証の実装（クラブヘッド追跡は未実装、[SPEC.md](./SPEC.md) §3）。
1 本の動画に素振りなど複数のスイングが写っている前提で、動作区間ごとに候補を作って採点する。

1. **手首追跡**: `AVAssetReader` でフレームを読み、`frameRate / 30` 間隔で間引いて `VNDetectHumanBodyPoseRequest` を実行。
   複数人が写るとき（Golfboy の 2 視点合成など）は腰の位置が前フレームに最も近い人物を追い続ける（初回は最も大きく写る人物）。
   両手首の平均位置（信頼度 0.3 未満は無視）に 3 点メディアンをかけ、単発の飛びを消す
2. **速度系列**: 手首の移動距離/秒を移動平均（窓 5）で平滑化。検出できないフレームは飛ばし、0.25 秒以上あいた区間の速度は作らない
3. **動作区間の分割**: 速度が最大値の 20% 以上の区間を 1 スイングとし、切り返しの短い減速（低速サンプルの連なりが 0.6 秒未満）や
   ブレによる欠測はつなぐ（`motionSegments`）
4. **各区間のフェーズ**（`swingCandidate`）: 手首とアドレス位置との距離の形で決める
   - アドレス: 区間の手前で静止（最大速度の 10% 未満が 0.15 秒）が続く点
   - トップ: 手首がアドレス位置から最も離れた点
   - インパクト: トップの後、半分以上戻ってきてからアドレス位置に最も近づく点（再び離れ始めたら探索終了）
   - フィニッシュ: インパクト後に静止（0.2 秒）が続く点。次の区間には踏み込まない
   - 速度の最大値をインパクトにしないのは、30fps ではインパクト前後がブレて手首を見失い、観測できる最大速度がフォロー側にずれるため
5. **採点と採用**: `0.5 × 手の移動量（バックスイング + フォロー、候補内の最大で正規化） + 0.5 × ピーク速度（同） + 0.03 × 時系列順`。
   素振りは移動量・速度とも小さく、本番と同じ振り切りなら後のスイングが選ばれる。候補はすべて `VideoConfig.candidates` に保存し、
   フェーズ調整画面で切り替えられる
6. `PhaseSet.sanitize` で順序と範囲を強制

検出に失敗した場合は `PhaseSet.fallback`（動画長の 15% / 45% / 55% / 85%）を設定する。
`lowConfidence`（警告表示）になるのは、検出失敗・手首の検出率 40% 未満・採用スイングのトップ〜インパクトに 0.2 秒以上の欠測があるとき。

実機なしで検出を確認するには macOS 用 CLI `scripts/analyze-swing/` を使う（[guides/build-test.md](./guides/build-test.md)）。
閾値の根拠になった実データの系列は [research/260906_1641-multi-swing-detection.md](./research/260906_1641-multi-swing-detection.md)。

**シミュレータでは Vision のモデル重みが無く動作しない**（`Missing weights path cnn_human_pose.espresso.weights`）ため、
常にフォールバックになる。検出精度の確認は実機で行う。

## 6. コーディング規約（コメント・命名）

- コード内のコメントは**日本語**で記述し、`TODO:` / `FIXME:` / `NOTE:` を用途に応じて使い分ける
- 複雑なロジックには「なぜそうしたか」を説明するコメントを付ける（行動規範は [AGENTS.md](../AGENTS.md) §5.3）
- 命名は Swift 標準に従う：型は UpperCamelCase、変数・関数は lowerCamelCase。View は `〜View`、
  ロジックの置き場は役割で分ける（`Models/` 値型と写像、`Services/` 入出力と解析、`Playback/` 再生制御）
- 1 ファイル 1 型を基本とし、ファイル内だけで使う補助 View は `private` にする

## 7. 検証と既知の制約

- ビルド・シミュレータ・実機の手順: [guides/build-test.md](./guides/build-test.md)
- 通しの自動 E2E（XCUITest ハーネス）: [.claude/skills/e2e-simulator/SKILL.md](../.claude/skills/e2e-simulator/SKILL.md)
- PhotosPicker 経由のスローモーション動画は 30fps のレンダリング版になる: [TODO.md](./TODO.md) A
- 初回検証の記録: [research/260906_1531-simulator-verification.md](./research/260906_1531-simulator-verification.md)
