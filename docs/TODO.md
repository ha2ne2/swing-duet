# TODO

フェーズ計画（[ROADMAP.md](./ROADMAP.md)）に乗らない、個別の未対応事項を書き留める場所。
対応したら項目ごと消すか、経緯が重要なら研究・設計ドキュメントへ昇格させる。

## ステータス一覧

- [ ] B. テストが検出ロジックにしかない（2026-09-06 起票）
- [ ] D. 手首が見えない区間に掛かるトップ・インパクトは推定で、0.15〜0.2 秒ずれる（2026-09-06 起票）
- [ ] F. 2 セッションが同時に E2E を回すと壊れる（2026-09-06 起票）
- [ ] G. 2026-09-11 の画面構成の変更後、E2E を通しで回していない（2026-09-11 起票）
- [ ] H. 小さく写る人物では追跡が別の点に固定され、検出に失敗する（2026-09-11 起票）

---

### B. テストが検出ロジックにしかない（2026-09-06 起票）

- **背景**: MVP はテスト無しで作られた。[AGENTS.md](../AGENTS.md) §5.1 は「最初からテストを書く」前提。
  2026-09-10 に Swift Testing のターゲット `SwingDuetTests` を追加し、`SwingDetector` を合成した手の高さの系列で固定した（実行方法は [guides/build-test.md](./guides/build-test.md)）。
  2026-09-11 に `ClipStore`（旧データの移行・上限・相手の解決・元に戻す・同じ動画の共有）のテストを足した。
- **対象**: `SwingDuet/Models/SyncEngine.swift`、`SwingDuet/Models/Swing.swift`（`PhaseSet.sanitize` / `assign` / `fallback`）
- **やること**: 上記の純粋ロジックにテストを足す。
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
- **やること**: [SKILL.md](../.claude/skills/e2e-simulator/SKILL.md) の手順で 4 テストを回し、識別子・待ち時間・権限の扱いを直す。
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
