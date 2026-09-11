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
| 動画の取り込み   | Photos（PhotoKit）で写真ライブラリの動画を一覧し `PHAssetResourceManager` で原本を書き出す（§2）。権限が無いときは PhotosUI `PhotosPicker` + CoreTransferable `FileRepresentation(contentType: .movie)`。取り込み後に AVFoundation `AVAssetExportSession`（パススルー）で映像トラックだけにする（§4） |
| 永続化           | JSON（`Documents/library.json`）+ 動画ファイル（`Documents/Videos/`）。**外部依存なし**            |
| 言語 / 最低 OS   | Swift 5 言語モード / iOS 17                                                                    |
| プロジェクト     | `SwingDuet.xcodeproj`（手書き。`PBXFileSystemSynchronizedRootGroup` で `SwingDuet/` 配下を自動収集） |

## 2. モジュール構成

```
SwingDuet/
├── SwingDuetApp.swift            # エントリ。ClipStore を環境に注入、ダーク固定。ルートは SwingListView
├── Models/                       # 他に依存しない純粋な値型（Foundation だけ。解析 CLI もそのまま使う）
│   ├── Swing.swift               # SwingPhase / SwingSegment / PhaseSet（4 フェーズと 3 区間）
│   ├── VideoConfig.swift         # VideoSide / VideoConfig（動画の情報・解析結果・表示変換）
│   ├── Clip.swift                # Clip / ClipRole / AnalysisState / Pairing / Library（保存単位と保存する全体）
│   ├── SyncEngine.swift          # 共通タイムライン ⇔ 各動画時刻の区間別線形写像（§3）
│   ├── Formatting.swift          # 日時・時間の表記と、日付ごとの節への分け方
│   └── Geometry.swift            # CGPoint / CGRect の小さな補助（距離・外接矩形）
├── Services/                     # 入出力・解析・再生制御
│   ├── SwingAnalyzer.swift       # 自動解析の入口。PoseTracker → SwingDetector をつなぎ、保存用の VideoConfig にする（§5）。動画を読めないときの VideoError
│   ├── PoseTracker.swift         # Vision の姿勢推定で人物を追跡（手首・腰・首の位置、関節の外接矩形）
│   ├── SwingDetector.swift       # 手の高さの系列からスイング区間・4 フェーズを検出し候補を採点（純粋計算）
│   ├── PhotoLibrary.swift        # 写真ライブラリ（PhotoKit）：権限、動画の一覧、原本の書き出し。ピッカーで選んだ動画の出どころ LibrarySource
│   ├── VideoImporter.swift       # OS のピッカー（PhotosPicker）から動画を受け取る・撮影日時・映像トラックだけへの書き換え（stripAudioTrack）
│   ├── ClipStore.swift           # クリップの永続化（JSON + 動画ファイル管理）、旧データの移行、解析キュー、上限、元に戻す
│   └── PlaybackController.swift  # CADisplayLink マスタークロック + 区間別レート再生（§4）
└── Views/                        # 画面ごとのフォルダ
    ├── Home/
    │   └── SwingListView.swift   # ホーム（起動画面）。スイングの一覧（★ ベスト / 撮影日ごと）、＋、選択モード、元に戻す
    ├── Stage/
    │   ├── StageView.swift       # ステージ。左のスイングと相手（右）。両方の解析が済めば ComparisonView、それまでは解析中 / お手本なし / 失敗の表示
    │   ├── ComparisonView.swift  # 比較（ペイン 2 つ + 操作パネル）。左右の編集をクリップに保存し、同期設定を controller に反映
    │   ├── VideoPaneView.swift   # 動画ペイン（自動フィット・拡大縮小・位置合わせ。上端に選び直しのラベル、下端中央にフェーズ調整）
    │   ├── ControlPanelView.swift # 操作パネル（基準切替 + シークバー + 再生操作）。比較前のステージにも飾りとして出す
    │   ├── SeekBarView.swift     # 区間色分けの共通シークバー
    │   ├── TransportControlsView.swift # フェーズジャンプ / コマ送り / 再生 / 速度 / ループ
    │   ├── HoldRepeatButton.swift # 押した瞬間と離した瞬間を伝えるボタン（コマ送りの長押し用）
    │   └── PhaseEditView.swift   # フェーズ手動修正（マーカードラッグ・±コマ・スイング候補の切り替え）
    ├── Picker/
    │   ├── VideoPickerSheet.swift # 動画を選ぶシート（「動画」「お手本」の 2 タブ。押した側のペインに入る）。名前付けのステップ
    │   ├── LibraryGridView.swift # 「動画」タブ：写真ライブラリの動画のグリッド（権限の 3 状態、限定アクセス、拒否時の OS ピッカー）
    │   ├── LibraryPreviewView.swift # 選んだ動画のプレビュー（原本を等速で繰り返し再生、下端の進捗バーでシーク）
    │   ├── ModelShelfView.swift  # 「お手本」タブ：登録済みお手本と ★ ベストのカード（「…」で名前の変更・削除・★ から外す）
    │   └── AssetThumbnail.swift  # 写真ライブラリの動画のサムネイル（PhotoKit）と、出どころで描き分ける SourceThumbnail
    └── Shared/
        ├── VideoThumbnail.swift  # 動画ファイルの 1 コマを非同期に描くサムネイル
        ├── PlayerLayerView.swift # AVPlayerLayer ラッパー
        ├── Alerts.swift          # 名前を付けるアラート・エラーのアラート
        └── SwingSegment+Color.swift # 区間の色（SwiftUI 依存を Models に持ち込まないための拡張）
```

依存方向は Views → Services → Models。`ClipStore` は `@EnvironmentObject` でルートから全 View に配る。

ペインの初期表示は、解析時に得た人物の範囲（`VideoConfig.focusRect`。採用スイングの間に見えていた関節の外接矩形）が余白付きで収まる
拡大率・位置に自動フィットする（縮小はしない。映像の端がペインに入って黒帯が出る手前で止める）。
拡大率・位置は自動フィットからの相対値として `VideoConfig.scale / offsetX / offsetY`（pt）に保存する（1 と 0 で自動フィットどおり）。
ジェスチャー中は `@GestureState` の一時値で描画し、
指を離した時点で `config` に確定 → `ComparisonContent.onChange` → `ClipStore.update` で JSON に書く
（ジェスチャーの途中でディスクに書かないため）。ピンチ中はドラッグを無視する（2 本指の 1 本目がドラッグとして拾われ、ピンチ中心がずれるのを防ぐ）。

**クリップ**（`Clip`、`Documents/library.json`）が保存単位。スイング（左ペインの自分の動画）もお手本（右ペイン）も同じ型で `role` で分け、
動画の情報と解析結果（`VideoConfig`）、名前、撮影日時、★、解析の状態を持つ。スイングは最後に比べた相手と右ペインの位置合わせを
`pairing` に持つ（相手が違えば位置も違うのでスイング側に置く。お手本自身の `scale / offset` は初期値のまま）。
お手本のフェーズは 1 か所（お手本のクリップ）にしか無いので、どのスイングのステージで直しても全部に効く。
「いつものお手本」は保存せず、`pairedAt` が最新の相手から導く（`ClipStore.usualPartner`）。
★ の無い解析済みのスイングは追加のたびに新しい順に 60 本（`ClipStore.swingLimit`）だけ残す。
保存形式には版（`Library.version`）があり、古い版を読んだときは `ClipStore.load` が組み替えて保存し直す（版 2 で `slowFactor` をユーザーの選択だけにした）。
削除は JSON から外すだけで、直前の分を `lastDeleted` に持って「元に戻す」で戻せる。動画ファイルはクリップ同士で共有し、
JSON のどこからも参照されなくなったファイルを起動時に `ClipStore.removeUnreferencedVideos` が片付ける（取り込みの途中で終了したときの残りも同様）。
旧形式（`projects.json` の比較ペアと `models.json` の登録済みお手本）は初回起動時に `ClipStore.migrateLegacy` がクリップへ組み替える。

**取り込みと解析**：「動画」タブ（`LibraryGridView`）は PhotoKit の権限を取り、写真ライブラリの動画を撮影日順に並べる。
選んだ動画は `PhotoLibrary.exportOriginal`（`PHAssetResourceManager`）で原本を一時ファイルへ書き出し、`ClipStore.importVideo` で
`Documents/Videos/` へ移す。権限が無いときは `PhotosPicker`（30fps のレンダリング版）に落ちる。同じ写真ライブラリの動画（`assetID`）を
既に持っていれば書き出さずにファイルを共有し、解析済みなら結果も写す（`ClipStore.obtain`）。解析は `ClipStore` のキューが取り込み順に
1 本ずつ行い（`stripAudio` → `SwingAnalyzer.analyze`。理由は §4）、途中で終了しても次回起動時に `pending` のものから再開する。

**ステージ**（`StageView`）は左のクリップ 1 本と、`ClipStore.partner(of:)` で解決した相手（最後に比べた相手 → いつものお手本 → 無し）を持ち、
両方の解析が済めば `ComparisonView`、それまでは解析中・お手本なし（右が ⊕）・失敗の表示。左右どちらのラベルからも「動画を選ぶ」シートを
開き（左は「動画」タブ、右は「お手本」タブで始まる）、左に新しい動画を入れると新しいスイング（相手は引き継ぐ）、右に入れると相手が替わる。

## 3. 同期の仕組み（SyncEngine）

- **共通タイムライン**は**実世界の秒**。長さは基準側（`reference`）のスイング区間（アドレス〜フィニッシュ）を
  基準側の速さ `VideoConfig.effectiveSlowFactor`（動画秒 ÷ 実秒。実速なら 1、1/8 の焼き込みスローなら 8）で割ったもの
- 各フェーズの位置（`commonTime(of:)`）も基準側で決まる（基準側のアドレスが 0。同じく速さで割る）
- 非基準側は各区間（バックスイング / ダウンスイング / フォロー。区間の始点・終点は `SwingSegment.start / end`）を
  線形に伸縮して写像する（`videoTime(at:for:)`）。これにより 4 点が必ず一致する
- 区間ごとの速度倍率 `rateMultiplier(for:in:)` = その側の区間長（動画秒）÷ 共通タイムライン上の区間長（実秒）。
  基準側は `slowFactor` そのもの。非基準側の速さは区間長の比に含まれるので、同期に使うのは基準側の `slowFactor` だけでよい
  （左右両方がスローでも同じ。設計は [design/260911_0805](./design/260911_0805-slow-factor-on-clips.md)）
- コマ送りの 1 ステップは基準側動画の 1 フレーム（`referenceFrameDuration`。共通タイムライン上では 1 ÷ (fps × slowFactor)）

## 4. 再生の仕組み（PlaybackController）

- `CADisplayLink`（30〜60Hz）がマスタークロック。毎 tick で `commonTime += dt × speed`。
  共通タイムラインが実秒なので `speed` は**実速に対する倍率**（x1 = 実速。スロー動画でも同じ）
- 各 `AVPlayer` は「再生速度 × 区間倍率」の `rate` で走らせ、区間境界で `rate` を切り替える
  （1/8 スローの動画を基準に x1 で見ると `rate` は 8。ローカルファイルなら再生できるが、滑らかさは実機で確認する）
- 実時刻と期待時刻のドリフトが **80ms（実秒）** を超えたらシークで補正（許容 20ms）。`currentTime` の揺れは実秒でほぼ一定なので、
  動画秒で比べる閾値には rate を掛ける（rate 8 で 80ms のまま比べると常に超えてシークが連鎖する）。
  一時停止・ジャンプ・コマ送り・スクラブ終了時は許容ゼロの精密シーク
- コマ送りボタンの押しっぱなしは 0.4 秒後から 0.1 秒ごとに 1 コマ進める（`beginStepping` / `endStepping`）。
  前のコマの精密シークが終わるまで次へ進まない（シークを重ねると後のシークが前のを取り消し続け、画面が更新されなくなる）
- ループ範囲は `loop`（`LoopMode`：スイング全体 / 1 区間 / ループしない）。範囲を出たら先頭へ戻る（ループしないなら停止）
- フェーズ修正・基準切替時は `updateSync` で相対位置（進捗率）を保って追従する
- 比較が開いたら `playWhenReady` が両方の `AVPlayerItem` の準備（`readyToPlay`）を待って自動で再生を始める
- **音声トラックは取り込み時に落とす**（`stripAudioTrack`）。再生は常にミュートだが、
  音声トラックのある `AVPlayerItem` は再生開始・シークのたびに音声レンダラの起動を待って `currentTime` が 100〜200ms 止まり、
  ドリフト補正がそれをシークで直し、そのシークがまた時計を止めて連鎖する（速度 × 停止時間 > 80ms で発生。実機の x0.3 で顕在化した。
  [research/260907_0254](./research/260907_0254-model-video-stutter-on-device.md)）
- シーク中（完了ハンドラが呼ばれるまで）の側はドリフト補正しない。シーク中は `currentTime` が進まないので、補正すると同じ連鎖になる
- `PlaybackController` は `@Observable`（`ObservableObject` ではない）。`commonTime` が毎 tick 変わるので、
  `ObservableObject` だと比較画面の View 全体が 60Hz で再描画され、再生中はループ範囲の Menu の項目が押せなくなる。
  `@Observable` なら `commonTime` を読むシークバーだけが再描画される（`ClipStore` は更新頻度が低いので `ObservableObject` のまま）。
  `ComparisonView` は controller を `task` で 1 度だけ作る薄いラッパーで、本体は `ComparisonContent`
  （`@State` の初期値は View の作り直しごとに評価されるため、init で作ると保存のたびに使い捨ての AVPlayer ができる）
- 比較前のステージは、動画を持たない `PlaybackController.placeholder` で同じ `ControlPanelView` を操作できない飾りとして出す
  （両ペインがそろった瞬間にパネルの高さが変わらないように。形を真似た別の View だと、パネルを変えたときにずれる）

## 5. フェーズ検出の仕組み（SwingAnalyzer）

Vision の姿勢推定で追った**体に対する手の高さ**からフェーズを決める（クラブヘッド追跡は未実装、[SPEC.md](./SPEC.md) §3）。
高さは撮影方向（正面・後方）にも再生速度にも依存せず、基準点を選ばないのでトップで長く静止してもアドレスと取り違えない。
1 本の動画に素振りなど複数のスイングが写っている前提で、手が低い区間から順に形を読んで候補を作り、採点する。
`SwingAnalyzer.analyze` が入口で、1 は `PoseTracker`、2〜4 は `SwingDetector`（Vision に依存しない純粋計算）が担う。
設計の経緯と実測値は [design/260910_0236](./design/260910_0236-hand-height-phase-detection.md)。
スロー動画で秒の閾値が壊れる分析は [research/260910_0220](./research/260910_0220-slowmo-detection-failure.md)。

1. **追跡**（PoseTracker）: `AVAssetReader` でフレームを読み、`frameRate / 30` 間隔で間引いて `VNDetectHumanBodyPoseRequest` を実行。
   複数人が写るとき（Golfboy の 2 視点合成など）は腰の位置が前フレームに最も近い人物を追い続ける（初回は最も大きく写る人物）。
   手首は両手首の中点。片方しか見えないフレームは直前の「手首 → 中点」のずれを足して中点相当にし（切り替わりで位置が飛ばないように）、
   直前の点から 0.1 以内で続いていれば信頼度 0.15 まで採用する（他の関節は 0.3 未満を無視）。3 点メディアンで単発の飛びを消す。
   腰（root）・首（neck）の位置と、見えている関節の外接矩形（ペインの自動フィットに使う `focusRect`。§2）もフレームごとに残す
2. **手の系列**（`handSamples`）: 手の高さ h = (手首 y − 腰 y) ÷ 体の大きさ（腰〜首の高さの動画全体の中央値）。腰 = 0、首 = 1。
   速度は体の大きさ/秒で移動平均（窓 5）。手首が 0.2 秒以上見えなかった（欠測）直後の速度は作らない
3. **スイングの読み取り**（`detect` / `swingCandidate`）: 手が低い（h < 0.3）区間から順に「低い → 高い（h ≥ 0.5）→ 低い → 高い」の形を読む。
   スイングが成立したら、そのフィニッシュより後の低い区間から続ける（後方視点のスローではインパクト付近の手が奥へ動いて
   画面上は止まって見えるが、それを次のスイングのアドレスと取り違えない）
   - アドレス: 低い区間で最も低い高さの近く（0.1 以内）にいて、速度がバックスイングの最大の 15% 以下（まだ動き出していない）である最後の点
   - トップ: 手が最も高い点の後、高さが下がりながら速度がダウンスイングの最大の 30% に達した点（切り返し）。トップで止まっても下ろし始めが取れる
   - インパクト: トップの後、次に高くなるまでの最低点
   - フィニッシュ: フォローで手が上がりきる山（そこから 0.3 下がるまで）の高さの 90% に最初に達した点
   - フォローの後に手が低く戻る速さがフォローで上がった速さ以上なら、その高い区間は別のスイングのトップなので、この区間からはスイングを作らない
     （素振りの直後に本番があるとき）。高くならない（振り上げただけ）・低いまま終わる（トップからアドレス位置へ戻すだけ）も候補にしない
   - **手首が見えない区間**（後方視点ではトップ〜インパクトが体の陰に入る。30fps のブレでも欠ける）に切り返しが掛かるときは、
     再出現から次に高くなるまでの最低点をインパクト、消える前に高ければその時点を、まだ上がり途中ならアドレスから
     バックスイング : ダウンスイング = 3 : 1 の位置をトップに置き、`SwingCandidate.estimated` に記録する
4. **採点と採用**: `0.5 × 振り上げ（h の最大 − アドレスの h、候補内の最大で正規化）+ 0.5 × ピーク速度（同）+ 0.03 × 時系列順`。
   素振りは振り上げ・速度とも小さく、本番と同じ振り切りなら後のスイングが選ばれる。候補はすべて `VideoConfig.candidates` に保存し、
   フェーズ調整画面で切り替えられる
5. `PhaseSet.sanitize` で順序と範囲を強制
6. **動画の速さの推定**（`VideoConfig.estimatedSlowFactor` → `SlowFactor.estimate`）: 焼き込みスローには倍率のメタデータが無いので、
   フェーズのダウンスイング長を実速の代表値 0.37 秒と比べ、1 / 2 / 4 / 8 / 16 / 32 のうち log2 で最も近いものにする
   （境目 0.52 / 1.04 / 2.08 / 4.2 / 8.3 秒。実速寄りに丸める）。フェーズの純関数なので保存せず、手で直せば追従する
   （検出に失敗してフェーズを手で置いたスーパースロー動画でも出る）。検出失敗時の仮のフェーズのままなら 1。
   ユーザーが選んだ値（`VideoConfig.slowFactor`）があればそれが優先（`effectiveSlowFactor`）。隣の倍率とは内容から区別できないので
   推定は提案（[design/260911_0805](./design/260911_0805-slow-factor-on-clips.md)）

しきい値は高さ（体の大きさ単位）と、同じ動画の中での速度の比だけで、**秒の閾値は持たない**。検出が動画の速さに依存しないためで、
スロー再生が焼き込まれた動画ではトップの間が 2 秒に伸び、「何秒止まったか」で決めるとスイングが割れる（欠測の判定 0.2 秒だけは
解析フレーム 6 個という意味。速さは検出の前には分からないので、閾値を速さで割る設計は循環する）。
検出に失敗した場合は `PhaseSet.fallback`（動画長の 15% / 45% / 55% / 85%）を設定する。
`lowConfidence`（記録のみ。画面には出さない）になるのは、検出失敗・手首の検出率 40% 未満・採用スイングのトップかインパクトを推定で置いたとき。

実機なしで検出を確認するには macOS 用 CLI `scripts/analyze-swing/` を使う（[guides/build-test.md](./guides/build-test.md)）。
純粋計算の部分は `SwingDuetTests` で合成した系列に対して単体テストしている（同ガイド）。
後方視点で外れていた原因の分析は [research/260910_0215](./research/260910_0215-rear-view-phase-detection.md)。
旧方式（手首とアドレス位置の距離）の根拠だった実データ系列は [research/260906_1641](./research/260906_1641-multi-swing-detection.md)。

**シミュレータでは Vision のモデル重みが無く動作しない**（`Missing weights path cnn_human_pose.espresso.weights`）ため、
常にフォールバックになる。検出精度の確認は実機で行う。

## 6. コーディング規約（コメント・命名）

- コード内のコメントは**日本語**で記述し、`TODO:` / `FIXME:` / `NOTE:` を用途に応じて使い分ける
- 複雑なロジックには「なぜそうしたか」を説明するコメントを付ける（行動規範は [AGENTS.md](../AGENTS.md) §5.3）
- 命名は Swift 標準に従う：型は UpperCamelCase、変数・関数は lowerCamelCase。View は `〜View`、
  ロジックの置き場は役割で分ける（`Models/` 値型と写像、`Services/` 入出力・解析・再生制御）
- 1 ファイル 1 型を基本とし、ファイル内だけで使う補助 View は `private` にする

## 7. 検証と既知の制約

- ビルド・シミュレータ・実機の手順: [guides/build-test.md](./guides/build-test.md)
- 通しの自動 E2E（XCUITest ハーネス）: [.claude/skills/e2e-simulator/SKILL.md](../.claude/skills/e2e-simulator/SKILL.md)
- 写真ライブラリの権限を拒否したときの OS ピッカー（PhotosPicker）経由では、スローモーション動画が 30fps のレンダリング版になる（権限があれば原本を取り込む。§2）
- 画面構成（ホーム / 動画を選ぶ / ステージ）の設計: [design/260911_0530](./design/260911_0530-diary-screen-flow.md)
- 実機でお手本だけがカクついた原因（音声トラック）と対策の比較: [research/260907_0254](./research/260907_0254-model-video-stutter-on-device.md)
- 動画を写真ライブラリの参照ではなくコピーで持つ理由: [research/260907_0316](./research/260907_0316-copy-vs-reference-video-storage.md)
- 初回検証の記録: [research/260906_1531-simulator-verification.md](./research/260906_1531-simulator-verification.md)
