# TODO

フェーズ計画（[ROADMAP.md](./ROADMAP.md)）に乗らない、個別の未対応事項を書き留める場所。
対応したら項目ごと消すか、経緯が重要なら研究・設計ドキュメントへ昇格させる。

## ステータス一覧

- [ ] A. PhotosPicker 経由のスローモーション動画が 30fps レンダリング版になる（2026-09-06 起票）
- [ ] B. テストが検出ロジックにしかない（2026-09-06 起票）
- [ ] D. 手首が見えない区間に掛かるトップ・インパクトは推定で、0.15〜0.2 秒ずれる（2026-09-06 起票）
- [ ] E. 焼き込み済みスロー動画の倍率が分からず、x1 が実速にならない（2026-09-06 起票）
- [ ] F. 2 セッションが同時に E2E を回すと壊れる（2026-09-06 起票）

---

### A. PhotosPicker 経由のスローモーション動画が 30fps レンダリング版になる（2026-09-06 起票）

- **背景**: 2026-09-06 のシミュレータ検証で、240fps・3.0 秒の動画を選ぶとアプリには **30fps・14.67 秒**（スロー効果が焼き込まれた再エンコード版）が渡された。
  写真アプリは 240fps 動画を「スローモーション」として扱い、`FileRepresentation(contentType: .movie)` は編集適用済みの現行バージョンを返すため。
  README / [SPEC.md](./SPEC.md) §2.1 の「実フレームレート単位でコマ送り」が成り立たず、スロー区間の伸縮でフェーズ時間・テンポ比も歪む。
  シミュレータの写真アプリでの再現が根拠で、実機の PhotosPicker でも同じ挙動と見込んでいるが未確認。
- **対象**: `SwingDuet/Services/VideoImporter.swift`（`ImportedMovie`）、`SwingDuet/Views/VideoPickerSheet.swift`（`PhotosPicker` / `loadMovie`）
- **やること**: `PhotosPicker(..., photoLibrary: .shared())` にして `PhotosPickerItem.itemIdentifier` を取得 →
  `PHAsset.fetchAssets(withLocalIdentifiers:)` → `PHImageManager.requestAVAsset(forVideo:options:)`（`version = .original`）で
  元の 240fps ファイルを取り出す。取り出した原本も `ProjectStore.importVideo` → `stripAudio` の経路に通す（音声トラックを残さない）。
  写真ライブラリの読み取り権限（`NSPhotoLibraryUsageDescription` は設定済み）が必要になるので、
  拒否時は現行の PhotosPicker 経路（30fps 版）にフォールバックし、その旨を表示する（[AGENTS.md](../AGENTS.md) §6.3）。
- **やらない理由（今）**: 実機での挙動確認と権限 UX の設計が先。
- **参照**: [research/260906_1531-simulator-verification.md](./research/260906_1531-simulator-verification.md) §4.1、[research/260906_1723-slow-motion-speed-detection.md](./research/260906_1723-slow-motion-speed-detection.md) §3.3（PhotoKit で取れるもの）

### B. テストが検出ロジックにしかない（2026-09-06 起票）

- **背景**: MVP はテスト無しで作られた。[AGENTS.md](../AGENTS.md) §5.1 は「最初からテストを書く」前提。
  2026-09-10 に Swift Testing のターゲット `SwingDuetTests` を追加し、`SwingDetector` を合成した手の高さの系列で固定した（実行方法は [guides/build-test.md](./guides/build-test.md)）。
- **対象**: `SwingDuet/Models/SyncEngine.swift`、`SwingDuet/Models/SwingModels.swift`（`PhaseSet.sanitize` / `assign` / `fallback`）
- **やること**: 上記の純粋ロジックにテストを足す。
- **参照**: [ROADMAP.md](./ROADMAP.md) フェーズ 3

### D. 手首が見えない区間に掛かるトップ・インパクトは推定で、0.15〜0.2 秒ずれる（2026-09-06 起票）

- **背景**: 30fps ではトップ〜インパクトがブレで欠測し（Golfboy: 1.6〜2.3 秒）、後方視点では体の陰に入って見えない（yuta: 15.4〜16.2 秒）。
  2026-09-10 の手の高さモデル（[design/260910_0236](./design/260910_0236-hand-height-phase-detection.md)）で、欠測に掛かるときは
  再出現後の最低点をインパクト、消える前に高ければその時点・まだ低ければ 3 : 1 の比をトップに置き、`lowConfidence` を立てるようにした。
  それでも Golfboy はトップが 0.15 秒早く、インパクトが 0.15 秒遅い（欠測の両端）。手動修正に頼っている（`lowConfidence` は画面に出ない）。
- **対象**: `SwingDuet/Services/SwingDetector.swift`（`swingCandidate` の欠測の分岐）
- **やること**: (1) 実速の自撮り動画では衝突音でインパクトを精密化する（取り込み時の音声削除より前に解析する順序が必要。隣の打席の音は映像の推定 ±0.1 秒で絞る）。
  (2) クラブヘッド追跡で欠測区間を埋める（[ROADMAP.md](./ROADMAP.md) フェーズ 4）。(3) 240fps の元ファイル取得（A）で欠測そのものを減らす。
  `build/analyze-swing --series --joints docs/data/*` で検証する。
- **やらない理由（今）**: 推定と手動修正で運用できる。A が入れば自分の動画側の欠測は減る見込み。
- **参照**: [research/260910_0215](./research/260910_0215-rear-view-phase-detection.md) §3.2、[research/260906_1641](./research/260906_1641-multi-swing-detection.md) §2.2

### E. 焼き込み済みスロー動画の倍率が分からず、x1 が実速にならない（2026-09-06 起票）

- **背景**: 再生速度の x1 は「動画のタイムラインを等速で流す」なので、スロー効果が焼き込まれた 30fps 動画（他アプリの書き出し、
  YouTube のスロー動画）では x1 でも実速にならない。焼き込みスローにはフレームレート以外のメタデータが無く、倍率は映像から推定するか手動指定するしかない。
  写真アプリのスローモーションは PhotoKit で原本（240fps・実速）を取れるので A で解消する。
- **対象**: `SwingDuet/Models/SwingModels.swift`（`VideoConfig` に倍率を追加）、`SwingDuet/Models/SyncEngine.swift`（共通タイムラインの実秒化）、
  `SwingDuet/Playback/PlaybackController.swift`、`SwingDuet/Views/TransportControlsView.swift`（速度表示）、`SwingDuet/Services/SwingAnalyzer.swift`（倍率の推定）
- **やること**: 動画ごとに倍率（動画秒 ÷ 実秒）を持ち、`AVPlayer.rate` に掛けて x1 を実速にする。倍率はダウンスイング長（実速なら 0.2〜0.45 秒）から
  1 / 2 / 4 / 8 に丸めて提案し、手動で選び直せる UI を付ける。8 倍再生が実機で滑らかかを確認する。
- **やらない理由（今）**: 設計（データモデル・UI）が先。A を先に入れると自分の動画側は倍率 1 に揃い、対象がお手本側の焼き込みスローに絞られる。
- **参照**: [research/260906_1723-slow-motion-speed-detection.md](./research/260906_1723-slow-motion-speed-detection.md)

### F. 2 セッションが同時に E2E を回すと壊れる（2026-09-06 起票）

- **背景**: `run.sh` は起動中のシミュレータ 1 台目を自動選択し、共有の `build/e2e-harness/` でアプリのアンインストール・`out/` の削除・
  同じ DerivedData でのビルドを行うため、別セッションの E2E と重なると両方のテストランナーが落ちる。
  シミュレータ自体は 2 台同時に起動できる（実測）。
- **対象**: `.claude/skills/e2e-simulator/make-harness.py`（出力先の固定）、同 `run.sh`（端末の選択）、
  `.claude/skills/e2e-simulator/SKILL.md`、`docs/guides/build-test.md`（`booted` 前提の手順）
- **やること**: セッションごとに git worktree を切り、worktree ごとに名前付きのシミュレータ端末を持つ。
  `run.sh` は `booted` ではなく名前で端末を選び、無ければ作成・起動・`addmedia` する。
- **やらない理由（今）**: 運用（worktree の切り方・端末の命名）を決めてから実装する。それまでは `pgrep -f "xcodebuild tes[t]"` で確認して直列に回す。
- **参照**: [research/260906_1811-parallel-e2e-simulators.md](./research/260906_1811-parallel-e2e-simulators.md)
