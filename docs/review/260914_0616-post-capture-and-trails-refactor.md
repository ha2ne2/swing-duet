# 撮影・軌跡が入った後の全体リファクタ（2026-09-14）

前回の全体リファクタ（`6ef709a`、2026-09-12）以降に 20 コミットが入った。撮影画面（240fps・1 球ずつの切り出し）、
写真ライブラリの参照保存、長い動画の分割、ループ範囲のつまみ、再生の設定の保存、関節の軌跡、再生速度のプリセット変更。
機能ごとに継ぎ足したので、同じ規則が別々に実装されたところと、画面ごとに写しを持って壊れやすくなったところが溜まっていた。

対象は `SwingDuet/` 全体（約 60 ファイル・7,500 行）。View 層と横断的な重複は 4 本の並行レビューで洗い出し、
`Models/` `Services/` は直接読んだ。**単体テストは 99 → 125 件**（すべて通る）。

---

## 1. 直したもの（構造）

### 1.1 同じ規則の二重実装をやめた

| 何が | どこにあったか | どこへ寄せたか |
| --- | --- | --- |
| ショットを切り出す範囲（前後の余白・重なり・動画の端） | `ShotSplitter.shots` / `LiveShotJudge.settle` / `LiveDetector.range` の 3 か所 | `ShotSplitter.range(of:after:duration:)` |
| 追跡結果を範囲で切って先頭を 0 にする | `SwingAnalysisResult.sliced` / `LiveDetector.track` | `PoseTrack.sliced(to:)` |
| 手首の 3 点メディアン | `PoseTracker` の静的関数を 3 か所から呼ぶ | `PoseTrack.medianFilteredWrists()` |
| 追跡結果からスイング候補を検出して結果を組む | `SwingAnalyzer.analyze` / `.sliced` / `VisionWorker.liveShot` | `SwingAnalysisResult.init(pose:duration:frameRate:videoAspect:)` |
| 手が「高い」しきい値 0.5 | `SwingDetector.highHeight` と `LiveDetector.motionHeight` に同じ値を 2 つ | `SwingDetector.highHeight` 1 つ |
| 表示される映像の縦横比 | `PoseTracker.shownAspect`（テストあり）と `CaptureController.record` の手書き | `PoseTracker.shownAspect` |
| 時間軸と幅の対応（秒 ⇄ x） | シークバー・フェーズ調整・プレビューに 6 か所 | `TimeScale`（新設。テストあり） |
| Documents と一時ファイルのパス | 3 か所ずつ | `URL.documents` / `URL.temporary(extension:)` |

撮影中（ライブ）と後解析が**同じ規則で動くこと**が、切り出しの正しさの前提になっている。
その規則が 3 か所に書かれていたのが、今回いちばん危ない重複だった。

### 1.2 画面が持っていた写しを、持ち主（ストア）に返した

`ComparisonContent` が `VideoConfig` 2 本を `@State` に丸ごと複製し、そのズレを直すための `onChange` を 4 本持っていた。
コメント自身が「写さないと、拡大などで設定を保存し直したときに付いたばかりの軌跡を消してしまう」と書いていて、
複製を修復するためのコードだった。

書き抜けの `Binding` に置き換え、`onChange` 4 本を 1 本（同期の写像の作り直し）に減らした。あわせて

- 書き込みはストアの**いまの値**に対して行い、画面が開いた時点の写しを書き戻さない（`VideoConfig.applyPhaseEdits` / `applyTransform`）
- 撮影した球が 30fps で解析し直されたとき、開いたままの比較画面が古いフェーズを表示・保存し続ける経路が消えた

### 1.3 見た目の部品を共通化した

`Views/Shared/` に `Chips`（`paneChip` / `videoChip` / `capsuleChip` と幕の濃さ `Scrim`）、`AnalyzingOverlay`、
`FavoriteButton`、`BottomBanner`、`OpenSettingsButton`、`LayerHostView` を置き、各画面の手書きを寄せた。
副産物として **44pt のタッチ領域が 4 か所で足りていなかったのが揃った**（フェーズジャンプ 26pt・ループのメニュー 22pt・
コマ送り 28pt・スイング候補 27pt）。

### 1.4 長い関数・古い分岐を落とした

- `SwingDetector.swingCandidate`（100 行・入れ子の関数 8 個）→ `HandSeries` に読み方をまとめ、本体は 50 行の手順書に
- `CaptureController.stop`（70 行）→ `finishCuts()` と `saveTake()` に分割
- `ClipStore` の旧データ移行（`projects.json` / `models.json` → クリップ、75 行）を削除。
  実機の `Documents` を `devicectl` で確認し、旧ファイルが無いことを確かめてから消した
- 使われていない `PhaseSet.swingDuration` / `SyncBasis.init(reference:)` / 効かない既定引数 2 つを削除、
  外から読まれていない `private(set)` 4 つを `private` に

---

## 2. 直したもの（不具合）

レビュー中に見つかった、リファクタとは別の不具合。

1. **再生の設定が 1 つでも読めないと、クリップが全部消える**（`PlaybackSettings`）。
   この型だけ寛容な `init(from:)` を持たず、キーが欠けると例外 → `Library` ごと読めない → 空から始まる。
   `Documents/library.json` はスイングと動画への参照そのものなので、設定 1 つで失ってよいものではない。
   `PlaybackSettings` を寛容にし、`Library` 側でも設定の復号失敗はクリップを巻き込まないようにした
2. **ループ範囲のつまみを動かしている間、`library.json`（軌跡込みで数 MB）を毎フレーム書いていた**。
   軌跡（保存データを 2 桁大きくした）とつまみ（指が 1 コマ動くたびに設定が変わる）が別々に入って噛み合っていなかった。
   再生の設定の保存を 0.3 秒に 1 回までにした
3. **解析に失敗したお手本が「解析中…」のまま押せなくなる**（棚に再解析の導線が無いので回復できない）。3 状態を出すようにした
4. **権限が無いときの「写真アプリから選ぶ」で、同じ動画を 2 回選べない**（`PhotosPickerItem` を nil に戻していなかった）
5. **プレビューを開いた直後に戻ると、`AVPlayer` と監視が残る**（原本の取り出しを待つ間に画面を離れると、
   `teardown` の後で監視を仕掛けていた）
6. **プレビューだけ音声トラック付きで再生していた**（`VideoImporter` の NOTE が「シークのたびに `currentTime` が止まる」と
   書いている経路。ここは常時シークする画面）
7. **左（自分）のペインに、役割がお手本のクリップを入れられた**。入れると一覧に出ない・★ が効かない行になる。
   「お手本」タブの登録済みの節は、右に入れるときだけ出すようにした（★ お気に入りは中身がスイングなので両方に出す）
8. **一覧のサムネイルが iCloud にしか無い動画の本体をダウンロードしうる**。サムネイルの経路だけ通信を切った
9. `1 / speed` は `speed == 0` でトラップする（いまは到達しないが、公開プロパティなので防いだ）

---

## 3. 足したテスト（99 → 125）

「壊れても全部緑のまま気付けない」ところを埋めた。

- `PersistenceTests`（新）：`Clip` / `VideoConfig` / `Library` / `CaptureSettings` / `PlaybackSettings` の往復。
  **手書きの `init(from:)` にプロパティを足し忘れると、ここで落ちる**。古いキー欠けの読み込みと、壊れた設定でクリップが消えないことも
- `PoseTrackTests`（新）：手首のメディアン（飛びの除去・端・欠けの隣・軸ごと）と範囲の切り出し。全フェーズ検出の前処理でテストが 0 だった
- `SegmentWriterTests`（新）：`Segment.contains` / `localRange`（撮影中に球が黙って消える・フェーズがずれる計算）
- `TimeScaleTests`（新）：時間軸と幅の対応
- `ShotSplitterTests`：`range` の重なり・動画の端・空になる場合（撮影と後解析が共通で通る 1 か所）
- `JointTrailsTests`：ほとんど動かない部位の平滑化（直近で入れた枝が一度も通っていなかった）
- `JointTrailOverlayTests`：再生位置までの線の規則（`played`）

---

## 4. あえて直さなかったもの

| 見つけたもの | 判断 |
| --- | --- |
| 手の高さの計算が後解析（動画全体の中央値）と撮影中（そのコマ）で別実装 | しきい値だけ 1 つにし、計算は残した。撮影中は先のコマが無いので同じにはできない。理由を NOTE に書いた |
| 振り切り度の採点が `SwingDetector` と `LiveShotJudge` で別式 | 素振り判定が変わるので、実機で確かめてから。TODO U |
| `persist()` がメインスレッドで数 MB を符号化する（つまみ以外の保存も同じ） | 今回は設定の保存を間引いて凌いだ。根治は別作業。TODO R |
| 一覧のサムネイルにキャッシュが無い | 通信だけ切った。キャッシュは別作業。TODO S |
| 撮影まわりの non-Sendable 警告 10 件 | Swift 6 移行として別に。TODO T |
| 削除と「元に戻す」の作法が画面ごとに違う | UI の判断が要る。TODO V |
| 軌跡の下ごしらえを毎フレームやり直している | 実測 1 ペイン 0.098ms（60Hz 予算の 1%）。View の階層をひねる価値が無いと判断し、規則の切り出しと全走査の解消だけ |

---

## 5. 確認

- 単体テスト 125 件（シミュレータ iPhone 16e）
- 実機向けビルド（`generic/platform=iOS`）
- 開発用 CLI（`scripts/analyze-swing`）が同じソースでビルドできること
- 実機の動作確認は Vision がシミュレータで動かないため必須（撮影・検出・軌跡）
