# TODO

フェーズ計画（[ROADMAP.md](./ROADMAP.md)）に乗らない、個別の未対応事項を書き留める場所。
対応したら項目ごと消すか、経緯が重要なら研究・設計ドキュメントへ昇格させる。

## ステータス一覧

- [ ] D. 手首が見えない区間に掛かるトップ・インパクトは推定で、0.15〜0.2 秒ずれる（2026-09-06 起票）
- [ ] F. 2 セッションが同時に E2E を回すと壊れる（2026-09-06 起票）
- [ ] G. 2026-09-11 の画面構成の変更後、E2E を通しで回していない（2026-09-11 起票）
- [ ] H. 観客の写る中継映像は追跡が途切れやすい（2026-09-11 起票）
- [ ] I. キーフレーム間隔が長い動画では、戻る操作の絵の更新が復号速度で頭打ちになる（2026-09-12 起票）
- [ ] J. ゆっくり素振りの底で止まらずに本番へ入ると、素振りと本番が 1 スイングに繋がる（2026-09-12 起票）
- [ ] K. 撮影画面の実機確認が途中（2026-09-13 起票）
- [ ] L. 関節の軌跡に不要な振動が残る（2026-09-14 起票）
- [ ] N. 関節の軌跡が短い間に激しく暴れる（見失いの前後、2026-09-14 起票）
- [ ] O. 両肩と両股関節を結んだ面を軌跡に重ねる（2026-09-14 起票）
- [ ] P. ホームの一覧をサムネイルの格子にし、お気に入りを付けた順で上に出す（2026-09-14 起票）
- [ ] Q. 撮影を止めたら最後のスイングを比較画面で開き、前後のショットへ送れるようにする（2026-09-14 起票）
- [ ] R. `library.json` の書き出しがメインスレッドで重い（2026-09-14 起票）
- [ ] S. 一覧のサムネイルに保存が無く、行ごとに動画を解き直す（2026-09-14 起票）
- [ ] T. 撮影まわりが Swift 6 の並行性チェックに通らない（2026-09-14 起票）
- [ ] U. 「振り切り度」の採点が後解析と撮影中で別の式（2026-09-14 起票）
- [ ] V. 削除と「元に戻す」の作法が画面ごとに違う（2026-09-14 起票）
- [ ] W. `VideoConfig` が 4 つの関心事を抱えている（2026-09-14 起票）
- [ ] X. プレビューの iCloud ダウンロード進捗を表示する（2026-09-14 起票）
- [ ] Y. フェーズ調整のマーカードラッグが精密シークを連射する（2026-09-14 起票）
- [ ] Z. 撮影のログと全体の動画が溜まり続ける（2026-09-14 起票）
- [ ] AA. 同期のとり方の 2 つの値（基準側と揃えるフェーズ）が排他なのに常に両方ある（2026-09-14 起票）
- [ ] AB. 参照されなくなった動画をその場で消している（ゴミ箱を挟む）（2026-09-14 起票）

---

### D. 手首が見えない区間に掛かるトップ・インパクトは推定で、0.15〜0.2 秒ずれる（2026-09-06 起票）

- **背景**: 30fps ではトップ〜インパクトがブレで欠測し（Golfboy: 1.6〜2.3 秒）、後方視点では体の陰に入って見えない（yuta: 15.4〜16.2 秒）。
  2026-09-10 の手の高さモデル（[design/260910_0236](./design/260910_0236-hand-height-phase-detection.md)）で、欠測に掛かるときは
  再出現後の最低点をインパクト、消える前に高ければその時点・まだ低ければ 3 : 1 の比をトップに置き、`lowConfidence` を立てるようにした。
  それでも Golfboy はトップが 0.15 秒早く、インパクトが 0.15 秒遅い（欠測の両端）。手動修正に頼っている（`lowConfidence` は画面に出ない）。
- **対象**: `SwingDuet/Services/Analysis/SwingDetector.swift`（`swingCandidate` の欠測の分岐）
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

### H. 観客の写る中継映像は追跡が途切れやすい（2026-09-11 起票 / 2026-09-14 に内容を差し替え）

- **直したこと**: 起票時の症状（YouTube のスーパースローで追跡が別の点に固定され、検出が `PhaseSet.fallback` になる）は 2026-09-14 に直した。
  原因は 2 つで、どちらも観客が並ぶ画で起きる。Vision が**別々の人の関節をつないだ骨格**を返して「最も大きく写る人物」の選択に勝つことと、
  追跡中のゴルファーが一瞬とれなくなった隙に**後ろの観客へ乗り換える**こと。候補を「胴体が縦向き」「大きさが前フレームから 25% 以内」に絞って解決
  （`PoseTracker.selectPerson`。手元の 9 本で他の動画のフェーズは変わらない）。
- **残る問題**: このマキロイの動画は検出率が 80% で、トップ付近でゴルファーが Vision の結果から落ちる。
  軌跡は 2〜3 本に切れ、フェーズも A=4.37 T=15.48 I=17.75 F=21.32（テンポ 4.9 : 1）と、正しいかどうかは目視でしか確かめていない。
  中継のスーパースローは焼き込みの速さが一定でない可能性があり（切り返しだけ強く落とす編集がある）、その場合は
  1 本に 1 つしか倍率を持たない `VideoConfig.slowFactor` では同期がずれる。実測はしていない。
- **対象**: `SwingDuet/Services/Analysis/PoseTracker.swift`、`SwingDuet/Models/VideoConfig.swift`（`SlowFactor`）
- **やらない理由（今）**: 自分で撮った動画（iPhone のスロー、観客なし）では起きない。中継映像をお手本にするときだけの話。
- **参照**: [design/260911_0805](./design/260911_0805-slow-factor-on-clips.md) §3.1

### I. キーフレーム間隔が長い動画では、戻る操作の絵の更新が復号速度で頭打ちになる（2026-09-12 起票）

- **背景**: 後ろへのシークは手前のキーフレームから復号し直すため、キーフレームからの距離に比例して遅い（Mac で 1 回 24〜34ms、実機はさらに遅い）。
  YouTube 由来のお手本（キーフレーム 120〜160 フレームごと）と iPhone の 240fps スロー原本（235 フレームごと）が該当する。
  2026-09-12 にシークバーのシークをジョグと同じ「前のシークが終わってから最新の位置へ 1 回」にまとめ（`PlaybackController.show`）、
  連射による取り消しは無くなったが、後退の絵の更新は復号の速さ（Mac で 10〜28fps）が上限のまま。
- **対象**: `SwingDuet/Services/Media/VideoImporter.swift`（`stripAudioTrack` の置き換え）、`SwingDuet/Services/Library/ClipStore.swift`（既存ファイルの移行）
- **やること**: 取り込み時に HEVC・キーフレーム間隔 8〜15 フレーム・B フレーム無し・音声無しへ再エンコードする
  （後退が前進と同じ 5〜10ms になる。1080p30 で 6〜8Mbps、元に対して 43dB、Mac で実時間の 1/7）。既存の `Documents/Videos/` は起動時にバックグラウンドで移行する。
  決める点（キーフレーム間隔の決め方・常に変換するか・移行の方式・トリム）は research §6。決まったら `docs/design/` に設計書を書いてから実装する。
- **参照**: [research/260912_0319](./research/260912_0319-scrub-friendly-media-options.md)、[research/260912_0249](./research/260912_0249-seekbar-backward-scrub-stutter.md)

### K. 撮影画面の実機確認が途中（2026-09-13 起票）

- **背景**: 撮影画面（[ARCHITECTURE.md](./ARCHITECTURE.md) §6）はシミュレータにカメラが無いので、ビルドと純粋計算の単体テストしか通していない。
  実機で確かめる項目：1080p240 の `AVCaptureDevice.Format` が選ばれること、`AVAssetWriter` へのコマ落ち（`SegmentWriter.droppedFrames`）、
  240fps の写真ライブラリへの保存（`performChanges` が通ること。写真アプリでは実速で再生される）、キーフレーム間隔 15 / 30 / 60 の 1 ショットの大きさと戻る操作、
  30 分続けたときの熱（`systemPressureState` の推移）と電池、構えの判定の余白（関節の外接矩形が端から 4%）、合図の音の音量、区切りの切り替えでフレームが落ちないこと、
  前面カメラ（120fps・鏡像）の向き
- **対象**: `SwingDuet/Services/Capture/*`、`SwingDuet/Views/Capture/CaptureView.swift`
- **2026-09-13 の状況**: 実機で数球打ったが検出できなかった（詳細は未調査）。調査用に「全体の動画も残す」（既定オン）と `Documents/CaptureLogs/` のログを足した。
  取り出し方：`xcrun devicectl device copy from --device <ID> --domain-type appDataContainer --domain-identifier com.ha2ne2.SwingDuet --source Documents/CaptureLogs --destination <dir>`
  （動画は `Documents/CaptureTakes` に区切りごと。`build/analyze-swing --shots` で後解析が見つけるかを先に確かめる）
- **2026-09-13 の解析**: ログで判明。人物は見えていた（手首 100%）が、Vision に渡す向きが `.up` になっていて人物を横倒しのまま追跡し、手の高さが壊れていた
  （`CGAffineTransform(rotationAngle:)` の cos(π/2) が厳密な 0 にならず、`PoseTracker.orientation(from:)` の厳密比較に外れた）。
  向きの判定を丸めに、撮影の回転行列を厳密な整数に直し、写像を `OrientationTests` で固定した。240fps の書き込みはコマ落ち 0、切り出しと保存は動いた。
  区切りをつなぐ書き出しの失敗は `AVMutableComposition` への 2 本目の `insertTimeRange` が -11800 で落ちるため（Mac で再現）。`AVMutableMovie` のサンプルコピーに変えた（Mac で確認、実機は未）。
  前回のカット位置（アドレス・トップ・インパクト）の誤りは、向きの不具合で手の高さが壊れた候補から範囲を決めたため（同じ原因）。直した版で撮った全体の動画とログで、
  `build/analyze-swing --shots` の後解析とライブの `decision` の範囲が一致するかを確かめる
- **2026-09-13 の実機確認（向きを直した版）**: 検出・切り出し・写真ライブラリへの保存・帯・合図の音は通った。残った 2 つを調査
  （[research/260913_1204](./research/260913_1204-capture-stop-phantom-shot-and-short-take.md)）。大きな球数が「＋1」の後に前の数を一瞬見せる件は直した（帯のショット数を出す）
- **やること**（上のレポートの対策。どちらも未実装）:
  1. 止める直前に打席から戻る場面が 1 球になる。窓の先頭が前のスイングのアドレスを過ぎると、インパクトの窪みをアドレス、
     カメラに近づいて体が大きく写ったところをフィニッシュと読む。`LiveShotJudge.observe` で前のフィニッシュより前にアドレスがある候補を捨てる（レポート §3.5）
  2. 「全体の動画」が最後の区切り 1 本だけになる。`pruneSegments` が `.stopping` を「終わった」扱いにし、止める途中の切り出しの `defer` から区切りを消す（レポート §4.4）
  3. 残りの実機確認：30 分続けたときの熱と電池、キーフレーム間隔（15 / 30 / 60）の比較、前面カメラ（120fps・鏡像）の向き、合図の音の音量
- **参照**: [design/260912_2251](./design/260912_2251-capture-screen.md) §5.1・§7

### J. ゆっくり素振りの底で止まらずに本番へ入ると、素振りと本番が 1 スイングに繋がる（2026-09-12 起票）

- **背景**: 練習場の長回し（`docs/data/IMG_0186.mov`、30fps・正面）で、素振り直後の本番 8 回のうち 2 回（533 秒・641 秒）が素振りの下ろしと繋がったまま
  （フェーズが素振り側に付き、クリップは 12 秒になる）。他の 6 回は「アドレスで止まる」ことを手掛かりに分けられた（[ARCHITECTURE.md](./ARCHITECTURE.md) §5）が、
  この 2 回は素振りの底で止まらずにそのままテークバックへ入っている。
- **対象**: `SwingDuet/Services/Analysis/SwingDetector.swift`（`swingCandidate` の見えている形の判定）
- **やること**: 止まりが無くても「フォローの中に、低いまま始まる欠測（30fps の本番のブレ）」だけで別のスイングとみなせるか、実データで確かめる。
  30fps 後方視点の本番のフォローのブレと区別できることが条件。240fps で撮ればインパクトは欠測にならないので、撮影画面（design/260912_1951 第 2 段）が
  入れば頻度は下がる。
- **やらない理由（今）**: クリップには本番が含まれ、フェーズ調整で直せる。手掛かりが 1 本の動画の 2 例しか無い。
- **参照**: [design/260912_1951](./design/260912_1951-in-app-slowmo-capture-and-shot-split.md) §10

### L. 関節の軌跡に不要な振動が残る（2026-09-14 起票）

- **やったこと**（2026-09-14。調査は [research/260914_0311](./research/260914_0311-joint-trail-smoothing.md)）:
  1. 描く曲線を「点を必ず通る」Catmull–Rom から「点の近くを通る」B スプラインに替えた。
     点を通る曲線ではブレが角になるのが仕組み上避けられない。曲がりの揺れが半分になった
  2. 平滑化の強さを部位で分けた。手は 5 点の Savitzky–Golay のまま、ほとんど動かない頭・肩・股関節は
     スイングのコマ数に比例した移動平均（研究 §12）。実機で「頭と股関節の振動が強い」という指摘を受けての対応
  3. 軌跡の版を 3 に上げ、古いやり方で作った軌跡は開いたときに作り直すようにした
- **取り消した判断**: 「頭の軌跡は出さない」は取り消し。正面の動画では**起き上がり**が読めるので残す
- **フィニッシュへの影響は無い**: 軌跡の平滑化は表示だけに閉じ、検出に使う手首の系列は触っていない
  （掛けると macroy_behind が検出失敗になる。研究 §8）。フィニッシュの決め方は別に直した（[ARCHITECTURE.md](./ARCHITECTURE.md) §5 の `finishBand`）
- **残っていること**:
  - それでも足りなければ Whittaker（罰則付き）平滑化に置き換える案がある（研究 §7 案 B）。
    欠けたコマの補間と、Vision の信頼度による重み付けも同じ式で入る
  - 検出側の窓はまだコマ数固定。`SwingDetector.handSamples` の速度の移動平均は 5 コマ固定で、
    解析（30fps）と撮影中のライブ追跡（15fps）で掛かる秒数が倍違う

### N. 関節の軌跡が短い間に激しく暴れる（見失いの前後、2026-09-14 起票）

- **背景**: マキロイ正面（`YTDown.com_Shorts_Media_yGSGJ9KOE48...`）で、肩の軌跡が短い間にガクガクと大きく飛ぶ。
  フィニッシュの少し手前など、肩が体に隠れて見えなくなるところがきっかけらしい。Vision の結果が常に正しいとは限らず、
  見失うと別の点を関節として返す。人体の関節は短い間にそんな動き方をしないので、出てきた値をそのまま描いてはいけない。
- **対象**: `SwingDuet/Services/Analysis/PoseTracker.swift`（関節の採用と信頼度）、`SwingDuet/Models/JointTrail.swift`（軌跡の組み立て）
- **やること**: そこに至るまでの軌跡から類推して補正する。
  1. 1 コマで人体があり得ない距離を動いた値は採用せず、直前までの動きから外挿した位置で埋める（速度の連続性を手掛かりにする）。
  2. ただしトップの切り返しのように向きが反転する場面はある。反転そのものを禁じるのではなく、
     それまでの軌跡に沿って戻る動き（来た経路をなぞる）なら許す、という見方でロジックを組む。
  3. Vision の信頼度も併せて見る（低い値は採用せず補間する）。
- **L との関係**: 触る場所は同じで、L は連続した小刻みな揺れ、N は単発〜短時間の大きな飛び。設計は一緒に考える。
- **調べ方**: `build/analyze-swing --joints` で関節の生の位置と信頼度を出し、暴れる区間の信頼度を確かめる。

### O. 両肩と両股関節を結んだ面を軌跡に重ねる（2026-09-14 起票）

- **背景**: 今の軌跡は部位ごとの線だけ。左右の肩と左右の股関節を結んで四角形の面として出すと、
  体のねじれ（肩と腰の開きの差）と、その時点で体がどちらを向いているかが一目で分かる。
- **対象**: `SwingDuet/Views/Stage/JointTrailOverlay.swift`（描画）、`SwingDuet/Views/Shared/BodyPart+Color.swift`（色）
- **やること**: 再生位置のコマの 4 点（左右の肩・左右の股関節）を結んだ四角形を半透明で塗る。
  肩の辺と腰の辺を別の色にして開きを見せるか、線の軌跡と重なって煩くないか（オン・オフや濃さ）は描いてみて決める。
- **備考**: 4 点とも `JointTrails` に既にあるので、追加の解析は要らない。

### P. ホームの一覧をサムネイルの格子にし、お気に入りを付けた順で上に出す（2026-09-14 起票）

- **背景**: 今のホームは 1 行 1 枚のカード（自分とお手本のインパクトのコマ・名前・日時・★）で、一度に数本しか見えず一覧性が悪い。
  スイングは絵で選ぶものなので、サムネイルを大きく・数多く並べたい。
- **対象**: `SwingDuet/Views/Home/SwingListView.swift`（`list` と `SwingRow`）、`SwingDuet/Services/Library/ClipStore.swift`（`favorites` の並び）、
  `SwingDuet/Models/Clip.swift`（★ を付けた日時を持たせるなら）
- **やること**:
  1. 並び：★ お気に入りを一番上に、その中は**★ を付けた順（最後に付けたものが一番上）**。今は撮影日順なので、`Clip` に ★ を付けた日時が要る。
  2. 表示：1 行 1 枚のカードをやめ、サムネイルの格子にする。1 行 3 枚か 4 枚かは実機で見て決める。
  3. サムネイルはインパクトの瞬間（今と同じ `ClipThumbnail(phase: .impact)`）。
  4. お手本は並べない（幅を食う）。自分のスイングだけ。
- **決めること**: 撮影日ごとの節・名前・時刻・★ の印を格子のどこに出すか（文字を置く場所が減る）。
  選択モード（まとめて ★ / 削除）のタップの扱い。

### Q. 撮影を止めたら最後のスイングを比較画面で開き、前後のショットへ送れるようにする（2026-09-14 起票）

- **背景**: 撮ったらすぐ見たいのに、今は撮影を止めるとホームの一覧に戻って結果の帯が出るだけで、
  自分で目的のスイングを探して開き直す必要がある。撮ったショットは `ClipStore.keepCapturedShot` で
  クリップになり相手も付いているので、足りないのは開く動きだけ。
- **対象**: `SwingDuet/Views/Home/SwingListView.swift`（撮影を閉じた後の遷移。`captureSummary` と `path`）、
  `SwingDuet/Views/Stage/StageView.swift`（前後への送り）
- **やること**:
  1. 撮影を止めたら、その回の最後のスイングをステージ（比較画面）で開く。
  2. ステージで前のショット・次のショットへ送れるようにする（5 球続けて撮ったときに見比べたい）。
     送る範囲は「その回に撮ったショット」か「一覧の並び順」かを決める。
- **決めること**: 送りの UI。ステージは既に操作が多く、ボタンを足すと画面がごちゃつく。
  スワイプ（ページめくり）・上端の小さな送り・撮影直後だけ出る帯など、案を比べて決める。**先にデザインを詰めてから実装する**。

### R. `library.json` の書き出しがメインスレッドで重い（2026-09-14 起票）

- **背景**: `ClipStore.persist()` は全クリップ（軌跡込み）を符号化して書く（現在は `.sortedKeys` のみ）。軌跡が入って保存データが 2 桁大きくなり、
  クリップ 16 本で 7.4 MB・1 回 62ms（Mac の実測。実機はさらに遅い）。`@MainActor` なのでその間 UI が止まる。
  ループ範囲のつまみのドラッグ中に毎コマ書いていた件は、設定の保存を 0.3 秒に 1 回までにまとめて凌いだ（`ClipStore.persistThrottled`）が、
  ピンチの確定・フェーズの保存・撮影中の 1 球ごとの追加は今も 1 回ずつ全体を書いている。
- **対象**: `SwingDuet/Services/Library/ClipStore.swift`（`persist`）
- **やること**: 符号化と書き込みをメインアクターの外へ出す（値のスナップショットを取って detach する）。
  それでも足りなければ、軌跡を別ファイル（クリップごと）に分けて本体を小さくする。
- **やらない理由（今）**: 手元のクリップ数では体感できていない。撮影を続けて 200 本まで溜めてから測る。
- **参照**: [review/260914_0616](./review/260914_0616-post-capture-and-trails-refactor.md) §4

### S. 一覧のサムネイルに保存が無く、行ごとに動画を解き直す（2026-09-14 起票）

- **背景**: `ClipThumbnail` は行が見えるたびに `ClipStore.videoAsset(of:)` → `AVAssetImageGenerator` で作り直す。
  保存（キャッシュ）がどこにも無いので、スクロールで往復するたびに解き直しになる。一覧の右側のサムネイルはほぼ全行が同じお手本なので、
  同じ絵を行数分だけ作っている。2026-09-14 に、サムネイルの経路だけ iCloud からのダウンロードを止めた（44pt の絵のために本体を落とさない）。
- **対象**: `SwingDuet/Views/Shared/VideoThumbnail.swift`、`SwingDuet/Services/Library/ClipStore.swift`（`videoAsset`）
- **やること**: `(clip.id, phase)` を鍵にした小さなメモリキャッシュ（`NSCache`）を置く。`PhotoLibrary.fetchVideo` の
  `localIdentifierMappings`（Apple が「重いのでまとめて呼べ」と書いている API）がメインスレッドで走る経路も外す。
- **やらない理由（今）**: 手元の本数ではスクロールが引っかかっていない。P（一覧を格子にする）で 1 画面のサムネイル枚数が増えるので、そのときに一緒に。
- **同じ層の別件**（一緒に見る）: `PhotoLibrary.refetch` が `PHFetchResult` の遅延評価を捨てて全件を配列にし、
  写真ライブラリが変わるたび（撮影中は 1 球ごと）にメインアクターでやり直す。動画が数千本ある端末での挙動は未確認。
  あわせて権限の状態を `PHAuthorizationStatus`（5 ケース）のまま View に持ち込んでいるので、`.restricted` が「拒否」に混ざり
  「設定を開く」で解決できない案内を出す。`PhotoLibrary` 側に 4 状態の enum を出せば両方まとまる

### T. 撮影まわりが Swift 6 の並行性チェックに通らない（2026-09-14 起票）

- **背景**: `CaptureController` は撮影のキュー・追跡のキュー・main の 3 つでフレームと状態を受け渡すので、
  `CaptureSession` / `CaptureFrameWriter` / `SegmentWriter` / `CapturePoseProcessor` / `CVPixelBuffer` を `@Sendable` クロージャで捕まえる警告が出る
  （Swift 5 言語モードなので警告どまり。現在の件数はビルドログで確認する）。キューの所有権はコメントで示しているだけで、型では守られていない。
- **対象**: `SwingDuet/Services/Capture/CaptureController.swift`、同 `CaptureSession.swift` / `SegmentWriter.swift`
- **やること**: キューごとの状態を `actor`（または `@unchecked Sendable` を明示した型）に閉じ、渡す値を `Sendable` にする。
  Swift 6 言語モードへ上げるかは、その後で決める。
- **やらない理由（今）**: 実機で動いており、キューの分担は設計として書かれている（[design/260912_2251](./design/260912_2251-capture-screen.md) §5.1）。
  撮影の実機確認（K）が済むまで、この層は触らない。

### U. 「振り切り度」の採点が後解析と撮影中で別の式（2026-09-14 起票）

- **背景**: 「組の中でいちばん振り切った候補」を選ぶ式が 2 つある。`SwingDetector.detect` は
  `0.5 × 振り上げ/最大 + 0.5 × ピーク速度/最大 + 0.03 × 並び順`、`LiveShotJudge.settle` は `振り上げ/最大 + ピーク速度/最大`（同点なら後の候補）。
  素振りを捨てる規則（`ShotSplitter.isPractice`）と切り出す範囲（`ShotSplitter.range`）は 1 つに寄せたが、この採点だけ残っている。
  撮影中と後解析で別の球を「本番」と決めうる。
- **対象**: `SwingDuet/Services/Analysis/SwingDetector.swift`（`detect` の採点）、`SwingDuet/Services/Capture/LiveShotJudge.swift`（`settle`）
- **やること**: 採点を `SwingCandidate` 側の 1 つの関数にまとめる。
- **やらない理由（今）**: 判定が変わりうるので、実機の撮影ログ（`Documents/CaptureLogs`）と `build/analyze-swing --shots` の後解析を
  突き合わせて、同じ球を選ぶことを確かめてから入れる。
- **関連**: 手の高さの計算も後解析（動画全体の中央値）と撮影中（そのコマの首〜腰）で別実装。しきい値（`SwingDetector.highHeight`）は
  1 つに寄せたが、撮影中は先のコマが無いので同じ式にはできない（`LiveDetector.handHeight` の NOTE）。

### V. 削除と「元に戻す」の作法が画面ごとに違う（2026-09-14 起票）

- **背景**: 削除の確認は一覧（確認なし）・お手本の棚（確認あり）・撮影の帯（確認あり）で 3 通り。
  一方 `ClipStore.delete` はどこから呼んでも `lastDeleted` を埋めるが、「元に戻す」の帯はホームにしか無い。
  棚や撮影画面から消すと、戻せるのに戻す入口が無く、後でホームを開いたときに文脈の無い帯が出うる。
- **対象**: `SwingDuet/Services/Library/ClipStore.swift`（`delete` / `lastDeleted`）、`SwingDuet/Views/Home/SwingListView.swift`、
  `SwingDuet/Views/Picker/ModelShelfView.swift`、`SwingDuet/Views/Capture/CaptureView.swift`
- **やること**: 「確認して消す」か「すぐ消して戻せる」のどちらかに揃える。後者なら帯を消した画面に出す。
- **やらない理由（今）**: UI の判断が要る。P（一覧の作り直し）で削除の導線も変わるので、そのときに一緒に決める。

### W. `VideoConfig` が 4 つの関心事を抱えている（2026-09-14 起票）

- **現状**: 位置合わせは `PaneTransform` に分離し、画面の編集は変換とフェーズの更新に分けた。
  設定全体をコピーして部分的に写すヘルパーは除去済み。
- **残り**: `VideoConfig` には保存場所 `fileName`、動画の素性、解析結果、手動の倍率が同居している。
  保存形式を見直す際に、`fileName` を `Clip` の出どころに統合し、動画の素性と解析結果を分けるか検討する。
- **対象**: `SwingDuet/Models/VideoConfig.swift`、`SwingDuet/Models/Clip.swift`。
- **制約**: 既存の版 2 との読み書きの互換性を維持する。現在の操作は範囲を限定した API で更新できるため、
  追加の分割は保存形式を単純化できる範囲で行う。

### X. プレビューの iCloud ダウンロード進捗を表示する（2026-09-14 起票）

- 読み込み中・失敗の表示と、原本が読めるまで決定ボタンを無効にする処理は実装済み。
- 残りは `PHVideoRequestOptions.progressHandler` を使った数値の進捗表示と、iCloud にだけある原本を使った実機確認。
- 対象: `LibraryPreviewView` / `PhotoLibrary`。

### Y. フェーズ調整のマーカードラッグが精密シークを連射する（2026-09-14 起票）

- **背景**: 比較画面は「前のシークが終わってから最新の位置へ 1 回」にまとめている（`PlaybackController.show`。
  理由は [research/260912_0249](./research/260912_0249-seekbar-backward-scrub-stutter.md)）のに、
  同じ操作を毎フレームするフェーズ調整だけが許容ゼロのシークを直に呼んでいる。240fps 原本（キーフレーム間隔 235 コマ）で効くはず。
- **対象**: `SwingDuet/Views/Stage/PhaseEditView.swift`
- **やること**: シークのまとめ方を小さな型に出して両方から使う。
- **未確認**: 実機でどれだけ引っかかるか。まず触って確かめる。

### Z. 撮影のログと全体の動画が溜まり続ける（2026-09-14 起票）

- **背景**: `Documents/CaptureLogs/` と `Documents/CaptureTakes/` を消す経路が無い。「全体の動画も残す（調査用）」は既定オンで、
  1 回の録画で数百 MB〜GB。実機では既に 8.5 GB 溜まっていた（2026-09-14 に `devicectl` で確認）。
- 保存失敗・途中終了の作業動画は `Documents/CaptureTakes/Pending-<UUID>/` に残す。自動削除の対象に加える前に、復旧・取り込みの導線を設ける必要がある。
- **対象**: `SwingDuet/Services/Capture/CaptureController.swift`（`takesDirectory`）、`SwingDuet/Services/Capture/CaptureLog.swift`
- **やること**: 起動時に古い分を消す（日数か本数の上限）。撮影の実機確認（K）が済んだら「全体の動画も残す」を既定オフにする。
- **やらない理由（今）**: K の調査中は残しておきたい。消す規則（何本残すか）を決めてから。

### AA. 同期のとり方の 2 つの値（基準側と揃えるフェーズ）が排他なのに常に両方ある（2026-09-14 起票）

- **背景**: `SyncEngine` は `basis`（自分基準 / お手本基準 / 同期しない）と `anchor`（揃えるフェーズ）を常に両方持つが、
  `anchor` に意味があるのは「同期しない」のときだけ、`basis.reference` に意味があるのは同期しているときだけ。
  そのため `if let reference = basis.reference { … } else { … }` の二値分岐が `SyncEngine` の中に 5 か所
  （`commonDuration` / `commonTime(of:for:)` / `frameStep` / `videoTime` / `rateMultiplier`）、外に 4 か所
  （`PlaybackController` の 2 か所・`SeekBarView` の帯の本数・`TransportControlsView` の表示）ある。
- **対象**: `SwingDuet/Models/SyncEngine.swift`、`SwingDuet/Services/Playback/PlaybackController.swift`、
  `SwingDuet/Views/Stage/SeekBarView.swift`、`SwingDuet/Views/Stage/TransportControlsView.swift`
- **やること**: 中身を payload 付きの enum にする（`case stretched(reference: VideoSide)` / `case free(anchor: SwingPhase)`）。
  保存形式（`PlaybackSettings.syncBasis`）と UI の 3 択は `SyncBasis` のままにして、写像を作るときに変換する。
  「同期しないに入ったら揃えるフェーズを既定に戻す」の条件付き代入（`PlaybackController.syncBasis` の setter）が
  `.free(anchor: .impact)` を作るだけになる。
- **やらない理由（今）**: 同じ概念に型が 2 つ（保存用と計算用）並ぶ形になるので、その分かりにくさと釣り合うかを見てから。
  再生の見え方に関わるので、入れるときは実機で 3 モードを一通り触って確かめる。
- **参照**: [review/260914_1029](./review/260914_1029-second-pass-capture-and-persistence.md) §6

### AB. 参照されなくなった動画をその場で消している（ゴミ箱を挟む）（2026-09-14 起票）

- **背景**: `LibraryFiles.removeUnreferencedVideos` は起動時に「クリップが参照していないファイル＝孤児」として
  `Documents/Videos/` のファイルを即座に消す。**導出した集合を根拠にユーザーのデータを消す**形なので、
  導出の元（`clips`）が想定どおりでない状況が 1 つでもあると全部消える。実際にそうなっていたのが
  [review/260914_1103](./review/260914_1103-incident-video-deletion.md) のインシデントで、
  読み込みに失敗した回を弾いて塞いだが、設計そのものは変えていない。
- **対象**: `SwingDuet/Services/Library/ClipStore.swift`（`removeUnreferencedVideos`）
- **やること**: 孤児をその場で消さず `Documents/Videos/Trash/` へ移し、一定期間（たとえば 7 日）過ぎたものだけを消す。
  容量が逼迫しているときは即時に消してよい。「消した」ではなく「移した」ならログと突き合わせて戻せる。
- **残る経路**: 起動時の読み込み異常と、写真ライブラリへの移動・破棄に伴う保存失敗は保護する。
  一方、クリップ追加後の JSON 書き込み失敗は全操作を通じたトランザクションになっていない。
  古い JSON が次回正常に読み込まれると、新しいローカル動画が孤児扱いになる余地があるため、
  ゴミ箱への退避と併せて書き込み失敗の通知・再試行を整える。撮影した球は写真ライブラリへ移るまでアプリ内にしか無い点に注意する。
