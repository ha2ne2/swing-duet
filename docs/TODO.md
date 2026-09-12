# TODO

フェーズ計画（[ROADMAP.md](./ROADMAP.md)）に乗らない、個別の未対応事項を書き留める場所。
対応したら項目ごと消すか、経緯が重要なら研究・設計ドキュメントへ昇格させる。

## ステータス一覧

- [ ] B. `PhaseSet` の純粋ロジックにテストが無い（2026-09-06 起票）
- [ ] D. 手首が見えない区間に掛かるトップ・インパクトは推定で、0.15〜0.2 秒ずれる（2026-09-06 起票）
- [ ] F. 2 セッションが同時に E2E を回すと壊れる（2026-09-06 起票）
- [ ] G. 2026-09-11 の画面構成の変更後、E2E を通しで回していない（2026-09-11 起票）
- [ ] H. 小さく写る人物では追跡が別の点に固定され、検出に失敗する（2026-09-11 起票）
- [ ] I. キーフレーム間隔が長い動画では、戻る操作の絵の更新が復号速度で頭打ちになる（2026-09-12 起票）
- [ ] J. ゆっくり素振りの底で止まらずに本番へ入ると、素振りと本番が 1 スイングに繋がる（2026-09-12 起票）

---

### B. `PhaseSet` の純粋ロジックにテストが無い（2026-09-06 起票）

- **背景**: MVP はテスト無しで作られた。[AGENTS.md](../AGENTS.md) §5.1 は「最初からテストを書く」前提。
  2026-09-10 に Swift Testing のターゲット `SwingDuetTests` を追加し、`SwingDetector` を合成した手の高さの系列で固定した（実行方法は [guides/build-test.md](./guides/build-test.md)）。
  2026-09-11 に `ClipStore`（旧データの移行・上限・相手の解決・元に戻す・同じ動画の共有）、`SyncEngine`（実秒の共通タイムラインと速度倍率）、
  `SlowFactor`（動画の速さの推定）、`JogRotation`（ジョグホイールの目盛りとギア）のテストを足した。2026-09-12 に `LoopRange`（ループ範囲の端の丸め・詰め・追従）を足した。
- **対象**: `SwingDuet/Models/Swing.swift`（`PhaseSet.sanitize` / `assign` / `fallback`）
- **やること**: 上記の純粋ロジックにテストを足す。`SyncEngine` は区間の写像（`videoTime` / `segment(at:)`）の境界もまだ薄い。
- **参照**: [ROADMAP.md](./ROADMAP.md) フェーズ 3

### D. 手首が見えない区間に掛かるトップ・インパクトは推定で、0.15〜0.2 秒ずれる（2026-09-06 起票）

- **背景**: 30fps ではトップ〜インパクトがブレで欠測し（Golfboy: 1.6〜2.3 秒）、後方視点では体の陰に入って見えない（yuta: 15.4〜16.2 秒）。
  2026-09-10 の手の高さモデル（[design/260910_0236](./design/260910_0236-hand-height-phase-detection.md)）で、欠測に掛かるときは
  再出現後の最低点をインパクト、消える前に高ければその時点・まだ低ければ 3 : 1 の比をトップに置き、`lowConfidence` を立てるようにした。
  それでも Golfboy はトップが 0.15 秒早く、インパクトが 0.15 秒遅い（欠測の両端）。手動修正に頼っている（`lowConfidence` は画面に出ない）。
- **対象**: `SwingDuet/Services/SwingDetector.swift`（`swingCandidate` の欠測の分岐）
- **やること**: (1) 実速の自撮り動画では衝突音でインパクトを精密化する（取り込み時の音声削除より前に解析する順序が必要。隣の打席の音は映像の推定 ±0.1 秒で絞る）。
  (2) クラブヘッド追跡で欠測区間を埋める（[ROADMAP.md](./ROADMAP.md) フェーズ 4）。(3) 写真ライブラリから原本（240fps）を取り込めるようになった
  （2026-09-11）ので、実機で欠測率がどれだけ減るかを確認する。`build/analyze-swing --series --joints docs/data/*` で検証する。
- **やらない理由（今）**: 推定と手動修正で運用できる。原本の取り込みで自分の動画側の欠測は減る見込み。
- **参照**: [research/260910_0215](./research/260910_0215-rear-view-phase-detection.md) §3.2、[research/260906_1641](./research/260906_1641-multi-swing-detection.md) §2.2

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

### G. 2026-09-11 の画面構成の変更後、E2E を通しで回していない（2026-09-11 起票）

- **背景**: 保存単位をクリップに変え、ホーム / 動画を選ぶ / ステージの構成にした際に `FlowTests.swift` を新フローに書き直したが、
  シミュレータで通しでは回していない（単体テストとビルドのみ）。自前のピッカーは写真ライブラリの権限を使うので、`run.sh` に
  `simctl privacy grant photos` を足し、ダイアログが出た場合はテスト側で押す（`allowPhotosIfAsked`）ようにしてあるが、どちらも未検証。
- **対象**: `.claude/skills/e2e-simulator/FlowTests.swift`、同 `make-harness.py`（`run.sh`）、同 `SKILL.md`
- **2026-09-12 の状況**: iOS 26.2 のシミュレータでは写真の権限ダイアログが別プロセスで出て、XCTest からは押せない（springboard の要素としても
  `addUIInterruptionMonitor` でも「Failed to get matching snapshot」で落ちる）。しかも `xcodebuild test` がアプリを入れ直すと `simctl privacy grant` の
  記録が消え、出たダイアログを XCTest が自動で「許可しない」で閉じる（TCC.db の `auth_value` が 0 になる）。この日は比較画面まで到達できなかった。
  `testLoopTrimHandles`（ループ範囲のつまみのドラッグ）を足したが未実行。
- **やること**: 権限を xcodebuild の入れ直しの後に与える（`build-for-testing` → `simctl install` → `simctl privacy grant` → `test-without-building` の順にする）。
  その上で [SKILL.md](../.claude/skills/e2e-simulator/SKILL.md) の手順で 5 テストを回し、識別子・待ち時間を直す。
- **参照**: [design/260911_0530](./design/260911_0530-diary-screen-flow.md) §7 STEP 5

### H. 小さく写る人物では追跡が別の点に固定され、検出に失敗する（2026-09-11 起票）

- **背景**: YouTube のスーパースロー（1/16、横長 30 秒、人物が画面の幅の 1/3 ほど）で、体の大きさ（腰〜首）が 0.079 と小さく、
  手首の追跡が 6 秒以降ずっと (0.15, 0.53) 付近に固定されて手の高さが動かない（Vision が別の点を手首と読んでいるか、
  別の人物を追っている）。候補が出ず `PhaseSet.fallback` になり、ユーザーがフェーズを手で置いて使っている。
  動画の速さの推定はフェーズの純関数にしたので、手で置けば倍率（1/16）は出る。
- **対象**: `SwingDuet/Services/PoseTracker.swift`（人物の選択 `selectPerson`、手首の採用 `WristTracker`）
- **やること**: `build/analyze-swing --joints` で関節の生の位置と信頼度を見て、追跡が固定される原因（小さい人物の信頼度、別人物への乗り換え）を確かめる。
  必要なら人物の範囲を切り出して Vision に渡す（小さい人物の精度を上げる）。
- **やらない理由（今）**: 手動のフェーズで運用できる。実サンプルは 1 本（個人の端末上）。
- **参照**: [design/260911_0805](./design/260911_0805-slow-factor-on-clips.md) §3.1

### I. キーフレーム間隔が長い動画では、戻る操作の絵の更新が復号速度で頭打ちになる（2026-09-12 起票）

- **背景**: 後ろへのシークは手前のキーフレームから復号し直すため、キーフレームからの距離に比例して遅い（Mac で 1 回 24〜34ms、実機はさらに遅い）。
  YouTube 由来のお手本（キーフレーム 120〜160 フレームごと）と iPhone の 240fps スロー原本（235 フレームごと）が該当する。
  2026-09-12 にシークバーのシークをジョグと同じ「前のシークが終わってから最新の位置へ 1 回」にまとめ（`PlaybackController.show`）、
  連射による取り消しは無くなったが、後退の絵の更新は復号の速さ（Mac で 10〜28fps）が上限のまま。
- **対象**: `SwingDuet/Services/VideoImporter.swift`（`stripAudioTrack` の置き換え）、`SwingDuet/Services/ClipStore.swift`（既存ファイルの移行）
- **やること**: 取り込み時に HEVC・キーフレーム間隔 8〜15 フレーム・B フレーム無し・音声無しへ再エンコードする
  （後退が前進と同じ 5〜10ms になる。1080p30 で 6〜8Mbps、元に対して 43dB、Mac で実時間の 1/7）。既存の `Documents/Videos/` は起動時にバックグラウンドで移行する。
  決める点（キーフレーム間隔の決め方・常に変換するか・移行の方式・トリム）は research §6。決まったら `docs/design/` に設計書を書いてから実装する。
- **参照**: [research/260912_0319](./research/260912_0319-scrub-friendly-media-options.md)、[research/260912_0249](./research/260912_0249-seekbar-backward-scrub-stutter.md)

### J. ゆっくり素振りの底で止まらずに本番へ入ると、素振りと本番が 1 スイングに繋がる（2026-09-12 起票）

- **背景**: 練習場の長回し（`docs/data/IMG_0186.mov`、30fps・正面）で、素振り直後の本番 8 回のうち 2 回（533 秒・641 秒）が素振りの下ろしと繋がったまま
  （フェーズが素振り側に付き、クリップは 12 秒になる）。他の 6 回は「アドレスで止まる」ことを手掛かりに分けられた（[ARCHITECTURE.md](./ARCHITECTURE.md) §5）が、
  この 2 回は素振りの底で止まらずにそのままテークバックへ入っている。
- **対象**: `SwingDuet/Services/SwingDetector.swift`（`swingCandidate` の見えている形の判定）
- **やること**: 止まりが無くても「フォローの中に、低いまま始まる欠測（30fps の本番のブレ）」だけで別のスイングとみなせるか、実データで確かめる。
  30fps 後方視点の本番のフォローのブレと区別できることが条件。240fps で撮ればインパクトは欠測にならないので、撮影画面（design/260912_1951 第 2 段）が
  入れば頻度は下がる。
- **やらない理由（今）**: クリップには本番が含まれ、フェーズ調整で直せる。手掛かりが 1 本の動画の 2 例しか無い。
- **参照**: [design/260912_1951](./design/260912_1951-in-app-slowmo-capture-and-shot-split.md) §10
