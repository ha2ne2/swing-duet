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
| 動画の取り込み   | Photos（PhotoKit）で写真ライブラリの動画を一覧し、選んだ動画は識別子で**参照**する（原本は `PHImageManager.requestAVAsset(version: .original)` で読む。§2）。権限が無いときは PhotosUI `PhotosPicker` + CoreTransferable `FileRepresentation(contentType: .movie)` でコピーし、AVFoundation `AVAssetExportSession`（パススルー）で映像トラックだけにする（§4） |
| 永続化           | JSON（`Documents/library.json`）。動画は写真ライブラリの参照（コピーは `Documents/Videos/`。OS ピッカー経由と参照にする前に取り込んだもの）。**外部依存なし** |
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
│   ├── SyncEngine.swift          # SyncBasis / SyncEngine：共通タイムライン ⇔ 各動画時刻の写像（同期の区間別線形伸縮、同期しない等速。§3）
│   ├── LoopRange.swift           # LoopEdge / LoopRange（ループ範囲の端。フェーズからのコマ数で持ち、丸め・詰めは純粋計算）
│   ├── PlaybackSettings.swift    # 比較画面の再生の設定（同期のとり方・揃えるフェーズ・速度・ループ範囲。アプリ全体で 1 つ保存）
│   ├── Formatting.swift          # 日時・時間の表記と、日付ごとの節への分け方
│   └── Geometry.swift            # CGPoint / CGRect の小さな補助（距離・外接矩形）
├── Services/                     # 入出力・解析・再生制御
│   ├── SwingAnalyzer.swift       # 自動解析の入口。PoseTracker → SwingDetector をつなぎ、保存用の VideoConfig にする（§5）。動画を読めないときの VideoError
│   ├── PoseTracker.swift         # Vision の姿勢推定で人物を追跡（手首・腰・首の位置、関節の外接矩形）。フレーム 1 枚ずつの FrameTracker と動画ファイルの読み出し
│   ├── SwingDetector.swift       # 手の高さの系列からスイング区間・4 フェーズを検出し候補を採点（純粋計算）
│   ├── ShotSplitter.swift        # 候補の列を 1 球ずつのショット（切り出す範囲）に組む。素振りは除く（純粋計算）
│   ├── PhotoLibrary.swift        # 写真ライブラリ（PhotoKit）：権限と動画の一覧（変更に追従）、限定アクセスの選び直し、原本の書き出し。ピッカーで選んだ動画の出どころ LibrarySource
│   ├── VideoImporter.swift       # OS のピッカー（PhotosPicker）から動画を受け取る・撮影日時・映像トラックだけへの書き換え（stripAudioTrack）
│   ├── ClipStore.swift           # クリップの永続化（JSON + 動画ファイル管理）、旧データの移行、解析キュー、上限、元に戻す
│   └── PlaybackController.swift  # CADisplayLink マスタークロックで 2 本を SyncEngine の倍率で再生。再生の設定の持ち主（§4）
└── Views/                        # 画面ごとのフォルダ
    ├── Home/
    │   └── SwingListView.swift   # ホーム（起動画面）。スイングの一覧（★ お気に入り / 撮影日ごと）、＋、選択モード、元に戻す
    ├── Stage/
    │   ├── StageView.swift       # ステージ。左のスイングと相手（右）。両方の解析が済めば ComparisonView、それまでは解析中 / お手本なし / 失敗の表示
    │   ├── ComparisonView.swift  # 比較（ペイン 2 つ + 操作パネル）。左右の編集をクリップに、再生の設定を Library に保存
    │   ├── VideoPaneView.swift   # 動画ペイン（自動フィット・拡大縮小・位置合わせ。下端中央にフェーズ調整）
    │   ├── PaneSwapButton.swift  # ペイン右上の「替える」（比較前の SlotPane と共通）。動画に重ねるカプセル paneChip
    │   ├── ControlPanelView.swift # 操作パネル（同期のとり方の切替 + シークバー + 再生操作）。比較前のステージにも飾りとして出す
    │   ├── SeekBarView.swift     # 区間色分けの共通シークバー（同期しないときは上下 2 本）。ループ範囲を枠で囲んで外を暗くし、両端のつまみで端をコマ単位に動かす
    │   ├── TransportControlsView.swift # フェーズジャンプ / ジョグホイール / 速度 / ループ
    │   ├── JogWheelView.swift    # 再生ボタンを中心にしたジョグホイール（回してコマ送り、左右タップで ±1、触覚）
    │   ├── JogRotation.swift     # 回転を目盛りに数え、周回でギア（1 目盛りのコマ数）を上げる純粋計算
    │   └── PhaseEditView.swift   # フェーズ手動修正（マーカードラッグ・±コマ・スイング候補の切り替え）
    ├── Picker/
    │   ├── VideoPickerSheet.swift # 動画を選ぶシート（「動画」「お手本」の 2 タブ。押した側のペインに入る）。お手本に名前を付けるステップ
    │   ├── LibraryGridView.swift # 「動画」タブ：写真ライブラリの動画のグリッド（権限の 3 状態、限定アクセス、拒否時の OS ピッカー）
    │   ├── LibraryPreviewView.swift # 選んだ動画のプレビュー（原本を等速で繰り返し再生、下端の進捗バーでシーク）
    │   ├── ModelShelfView.swift  # 「お手本」タブ：登録済みお手本と ★ お気に入りのカード（「…」で名前の変更・削除・★ から外す）
    │   └── AssetThumbnail.swift  # 写真ライブラリの動画のサムネイル（PhotoKit）
    └── Shared/
        ├── VideoThumbnail.swift  # 動画ファイルの 1 コマを非同期に描くサムネイル
        ├── PlayerLayerView.swift # AVPlayerLayer ラッパー
        ├── InteractivePopGestureBlocker.swift # NavigationStack の「戻る」スワイプを、置いた画面（ステージ）にいる間だけ止める
        ├── Alerts.swift          # 名前を付けるアラート・エラーのアラート。Optional を isPresented に変える Binding.isPresent
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
★ の無い解析済みのスイングは追加のたびに新しい順に 200 本（`ClipStore.swingLimit`）だけ残す（当日のものは数えず、流さない）。
保存形式には版（`Library.version`）があり、古い版を読んだときは `ClipStore.load` が組み替えて保存し直す（版 2 で `slowFactor` をユーザーの選択だけにした）。
削除は JSON から外すだけで、直前の分を `lastDeleted` に持って「元に戻す」で戻せる（写真ライブラリの動画は残る）。コピーの動画ファイルは
JSON のどこからも参照されなくなったものを起動時に `ClipStore.removeUnreferencedVideos` が片付ける（取り込みの途中で終了したときの残りも同様）。
旧形式（`projects.json` の比較ペアと `models.json` の登録済みお手本）は初回起動時に `ClipStore.migrateLegacy` がクリップへ組み替える。

**取り込みと解析**：「動画」タブ（`LibraryGridView`）は PhotoKit の権限を取り、写真ライブラリの動画を撮影日順に並べる。
選んだ動画は**コピーせず参照で持つ**（`Clip.source` = `.library`。`assetID` が `PHAsset.localIdentifier`、`cloudID` が復元で識別子が変わったときの引き直し用。
`video.fileName` は空）。動画を読む窓口は `ClipStore.videoAsset(of:)` の 1 つで、参照は `PhotoLibrary.fetchVideo` → `requestOriginalAsset`
（原本。iCloud にしか無ければダウンロード）で `AVAsset` にし、写真アプリで消されていれば `VideoError.missingInLibrary` を投げる（ステージに理由を出す）。
権限が無いときは `PhotosPicker`（30fps のレンダリング版）に落ち、この経路だけ `ClipStore.importVideo` で `Documents/Videos/` へコピーする（`.file`）。
同じ写真ライブラリの動画（`assetID`）を解析済みで既に持っていれば結果を写す（`ClipStore.obtain`）。解析は `ClipStore` のキューが取り込み順に
1 本ずつ行い（コピーは `VideoImporter.stripAudioTrack` の後で。`SwingAnalyzer.analyze(asset:)`）、途中で終了しても次回起動時に `pending` のものから再開する。
コピーから参照へ変えた経緯は [design/260912_2011](./design/260912_2011-photo-library-reference-storage.md)。

**長い動画の分割**（`ClipStore.split`）：スイングの解析でショット（`SwingAnalysisResult.shots`。§5）が 2 つ以上あれば、1 球ずつ
`VideoImporter.exportSegment`（パススルー）で一時ファイルに切り出し、`PhotoLibrary.saveVideo` で写真ライブラリのアルバム「SwingDuet」に保存して
参照のクリップにする（保存できなければコピー）。解析結果は `sliced(to:)` で範囲の分を写すので解析し直さない。元のクリップは最後のショットに
置き換える（id を引き継ぐので開いたままのステージは最後の球を映す）。分けた長い動画の識別子は `Library.splitTakes` に残し、
もう一度選ばれたら `VideoError.alreadySplit` で断る。

**ステージ**（`StageView`）は左のクリップ 1 本と、`ClipStore.partner(of:)` で解決した相手（最後に比べた相手 → いつものお手本 → 無し）を持ち、
両方の解析が済めば `ComparisonView`、それまでは解析中・お手本なし（右が ⊕）・失敗の表示。ペイン右上の「替える」（`PaneSwapButton`）から「動画を選ぶ」シートを
開き（左は「動画」タブ、右は「お手本」タブで始まる）、左に新しい動画を入れると新しいスイング（相手は引き継ぐ）、右に入れると相手が替わる。

## 3. 同期の仕組み（SyncEngine）

**共通タイムライン**は**実世界の秒**。同期のとり方（`SyncBasis`：自分基準 / お手本基準 / 同期しない。アプリ全体で 1 つ、`Library.playback` に保存）で
写像が変わる。フェーズの位置は `commonTime(of:for:)` で側ごとに読む（同期しているときは両側で同じ）。

**自分基準 / お手本基準**（区間ごとの線形伸縮）：

- 長さは基準側のスイング区間（アドレス〜フィニッシュ）を基準側の速さ `VideoConfig.effectiveSlowFactor`
  （動画秒 ÷ 実秒。実速なら 1、1/8 の焼き込みスローなら 8）で割ったもの。各フェーズの位置も基準側で決まる（基準側のアドレスが 0）
- 非基準側は各区間（バックスイング / ダウンスイング / フォロー。区間の始点・終点は `SwingSegment.start / end`）を
  線形に伸縮して写像する（`videoTime(at:for:)`）。これにより 4 点が必ず一致する
- 速度倍率 `rateMultiplier(for:at:)` はその時刻の区間の、その側の区間長（動画秒）÷ 共通タイムライン上の区間長（実秒）。
  基準側は `slowFactor` そのもの。非基準側の速さは区間長の比に含まれるので、同期に使うのは基準側の `slowFactor` だけでよい
  （左右両方がスローでも同じ。設計は [design/260911_0805](./design/260911_0805-slow-factor-on-clips.md)）
- コマ送りの 1 ステップ（`frameStep`）は基準側動画の 1 フレーム（共通タイムライン上では 1 ÷ (fps × slowFactor)）

**同期しない**（等速。設計は [design/260912_1047](./design/260912_1047-free-run-alignment.md)）：

- 伸縮せず、両方をそれぞれの速さで実秒に戻し、揃えるフェーズ `anchor`（同期しないに入った時点ではインパクト。フェーズジャンプのボタンで替える）の瞬間だけ一致させる。
  長さは早い方のアドレスから遅い方のフィニッシュまでで、フェーズの位置は側ごとに違う
- 速度倍率は常にその側の `slowFactor`。共通タイムラインがその側の動画の端の外に及ぶ範囲では 0（端の絵のまま待つ）
- コマ送りの 1 ステップは細かい方の 1 フレーム（どちらの動画のコマも飛ばさない）
- ループ範囲の端（`LoopEdge`）は開始なら早い方、終了なら遅い方のフェーズから数える（「ダウンスイングのみ」は両方のダウンスイングを含む範囲）

## 4. 再生の仕組み（PlaybackController）

- `CADisplayLink`（30〜60Hz）がマスタークロック。毎 tick で `commonTime += dt × speed`。
  共通タイムラインが実秒なので `speed` は**実速に対する倍率**（x1 = 実速。スロー動画でも同じ）
- 各 `AVPlayer` は「再生速度 × `SyncEngine` の倍率」の `rate` で走らせ、倍率が変わる tick（同期しているときは区間境界）で `rate` を切り替える
  （1/8 スローの動画を基準に x1 で見ると `rate` は 8。ローカルファイルなら再生できるが、滑らかさは実機で確認する）
- 実時刻と期待時刻のドリフトが **80ms（実秒）** を超えたらシークで補正（許容 20ms）。`currentTime` の揺れは実秒でほぼ一定なので、
  動画秒で比べる閾値には rate を掛ける（rate 8 で 80ms のまま比べると常に超えてシークが連鎖する）。
  一時停止・ジャンプ・コマ送り・スクラブ終了時は許容ゼロの精密シーク
- コマ送りはジョグホイール（`JogWheelView`）。帯を 12° 回すごとに 1 コマ（`SyncEngine.frameStep`。1 周 30 コマ）、帯の左右のタップで ±1 コマ。
  回し続けると 1 周ごとに 1 目盛りのコマ数が倍になる（`JogRotation.framesPerDetent`：1 周目 1、2 周目 2、3 周目以降 4。
  指を離す・0.3 秒止まる・逆回転で 1 に戻る）。瞬間の速さで決めないのは、親指の円運動は伸ばす区間だけ速いという手の構造上の偏りがあり、
  速さで決めると 1 周の中で重さが脈打つため（[research/260911_1226](./research/260911_1226-jog-wheel-acceleration-survey.md)）。
  触覚は 1 コマごとに軽く、トップ / インパクトの通過で中くらい、ループ範囲の端で重く（`sensoryFeedback`。設計は
  [design/260911_0741](./design/260911_0741-jog-wheel-frame-stepping.md)）。横画面（コンパクト高さ）はホイールを Ø 96pt に縮める
- コマ送り・スクラブ・つまみのドラッグ（`stepFrame` / `scrub` / `trim` → `show`）は時計をすぐ動かし、プレーヤーのシークは前のシークが
  終わってから最新の位置へ 1 回だけ行う。速く回す・速くなぞると移動がシークより速く来る。重ねると `AVPlayer` は後のシークで前のを取り消して
  復号をやり直し続け、動かしている間ずっと画面が更新されなくなる。後ろへのシークは手前のキーフレームから復号し直すので 1 回に数十 ms かかり
  （YouTube 由来のお手本や 240fps の原本はキーフレーム間隔が 120〜235 フレーム）、まとめないとシークバーで戻るときだけカクつく
  （[research/260912_0249](./research/260912_0249-seekbar-backward-scrub-stutter.md)）。後退の絵の更新はそれでも復号の速さが上限で、
  根本策はキーフレーム間隔を詰める取り込み時の再エンコード（[TODO.md](./TODO.md) I）
- ループ範囲は `loop`（`LoopRange?`。nil ならループしない）。範囲を出たら先頭へ戻る（ループしないなら停止）。
  範囲の端 `LoopEdge` はフェーズからのコマ数で持つので、フェーズ修正・同期のとり方の切替で共通タイムラインが伸縮しても端がフェーズに付いてくる
  （既定の「スイング全体」`LoopRange.all` はアドレスとフィニッシュ、メニューの「ダウンスイングのみ」は区間の両端を、コマ数 0 で置いた範囲）。
  シークバーはループする間つねに範囲の両端につまみを出す。つまみのドラッグ（`beginTrim` / `trim` / `endTrim`）は端を最も近いフェーズから
  整数コマに丸め、反対側と 1 コマ以上離し、時計を端に置いて映像で端のコマを見せる。シークのまとめ方はコマ送りと同じ
  （設計は [design/260912_0252](./design/260912_0252-loop-trim-handles.md)）。
  開始のつまみは画面の左端に近く右へなぞる指が「戻る」スワイプに取られるので、ステージ（`StageView`）にいる間は `InteractivePopGestureBlocker` が
  `NavigationStack` の戻るスワイプを止める（応答チェーンで `UINavigationController` を見つけ、左端の `interactivePopGestureRecognizer` と
  iOS 26 からの画面全体の `interactiveContentPopGestureRecognizer` を無効にし、一覧へ戻ったら元に戻す。後者は前者が受け持たない場合に働くので
  片方だけでは止まらない。一覧へは左上の「<」で戻る）
- フェーズ修正（`updateVideos`）と同期のとり方の切替（`syncBasis`）は相対位置（進捗率）を保って追従する。
  同期しないときのフェーズジャンプ（`jump(to:)`）はそのフェーズで揃え直してから移る
- 再生の設定（`PlaybackSettings`：同期のとり方・揃えるフェーズ・速度・ループ範囲）の持ち主は controller（`settings`）。
  `ComparisonView` がその変化を `ClipStore.playback` に書き、次に開く比較の初期値になる（アプリ全体で 1 つ。再生位置は保存しない）
- 比較が開いたら `playWhenReady` が両方の `AVPlayerItem` の準備（`readyToPlay`）を待って自動で再生を始める
- **音声トラックは落とす**：コピーは取り込み時にファイルを書き換え（`stripAudioTrack`）、写真ライブラリの参照はファイルを触れないので
  再生時に映像トラックだけの合成にする（`VideoImporter.playerItem(for:)`。比較画面とフェーズ調整のプレビュー）。再生は常にミュートだが、
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

1. **追跡**（PoseTracker）: `AVAssetReader` でフレームを読み、`frameRate / 30` 間隔で間引いて `VNDetectHumanBodyPoseRequest` を実行
   （フレーム 1 枚ずつの追跡は `FrameTracker` が持ち、撮影中のフレームにも同じものを使う）。
   複数人が写るとき（Golfboy の 2 視点合成など）は腰の位置が前フレームに最も近い人物を追い続ける（初回は最も大きく写る人物。
   腰と首の両方が見えていない観測は掴まない）。追跡中の人物を 1 秒（解析フレーム 30 個）見失ったらアンカーを捨てて選び直す。
   長回しでは人物が画面を離れて戻る・序盤に誤検出を掴むことがあり、捨てないと二度と追い直せない（14 分の練習場の動画で検出率 0% になった原因）。
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
   - インパクト付近の低い区間で手が止まり（速度の最小がダウンスイングの最大の 20% 未満）、止まった後の動きが下ろしより速いか低いまま欠測になる
     （30fps の本番はブレて消える）なら、そこは次のスイングのアドレスなので、見えている形からはスイングを作らない。
     ゆっくりした素振りをアドレスへ戻してそのまま本番を打つ流れ（練習場で多い）で、素振りの下ろしと本番を 1 つに繋げないため。
     後方視点ではインパクト付近の手が奥へ動いて止まって見えるが、本物のフォローは下ろしより遅く、手首が隠れる欠測は肩の高さで起きるので残る
   - 見えている形を捨てたとき（上の止まり、または別のスイングにまたがる）、テークバック直後に欠測があり、消える前に手が上がり始めていれば
     「切り返しが欠測の中」の推定に落とす。30fps の本番はダウンスイング〜インパクトが丸ごとブレて消え、形の探索がフォロー → フィニッシュ →
     次の球のアドレスまでまたいでしまうため（14 分の練習場の動画で、素振り直後の本番 8 回がこれで拾えた）
   - **手首が見えない区間**（後方視点ではトップ〜インパクトが体の陰に入る。30fps のブレでも欠ける）に切り返しが掛かるときは、
     再出現から次に高くなるまでの最低点をインパクト、消える前に高ければその時点を、まだ上がり途中ならアドレスから
     バックスイング : ダウンスイング = 3 : 1 の位置をトップに置き、`SwingCandidate.estimated` に記録する
4. **採点と採用**: `0.5 × 振り上げ（h の最大 − アドレスの h、候補内の最大で正規化）+ 0.5 × ピーク速度（同）+ 0.03 × 時系列順`。
   素振りは振り上げ・速度とも小さく、本番と同じ振り切りなら後のスイングが選ばれる。候補はすべて `VideoConfig.candidates` に保存し、
   フェーズ調整画面で切り替えられる
5. `PhaseSet.sanitize` で順序と範囲を強制
   - **長い動画を 1 球ずつに分ける**（`ShotSplitter` → `SwingAnalysisResult.shots`）: 候補のフィニッシュから次のアドレスまで 6 秒以内なら同じ組
     （素振りと本番）とみなし、組の中で最も振り切った候補に比べて振り上げ・ピーク速度とも 6 割未満の候補を素振りとして捨てる（同程度なら両方とも本番。
     自動ティーアップでは本番が 5〜6 秒おきに続く）。残った候補の中央値に対して両方 6 割未満のものも素振りとみなして捨てる（比べる相手が無ければ残す）。範囲はアドレスの 1.5 秒前〜フィニッシュの 1.5 秒後で、
     前のショットと重ねない。`sliced(to:)` で範囲の中だけを 1 本の動画として見た結果（時刻は先頭基準、スイングは検出し直し）が得られ、
     切り出した動画を解析し直さずにクリップにできる（設計は [design/260912_1951](./design/260912_1951-in-app-slowmo-capture-and-shot-split.md)）
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
- 写真ライブラリの権限を拒否したときの OS ピッカー（PhotosPicker）経由では、スローモーション動画が 30fps のレンダリング版になる（権限があれば原本を参照する。§2）
- 画面構成（ホーム / 動画を選ぶ / ステージ）の設計: [design/260911_0530](./design/260911_0530-diary-screen-flow.md)
- 実機でお手本だけがカクついた原因（音声トラック）と対策の比較: [research/260907_0254](./research/260907_0254-model-video-stutter-on-device.md)
- 動画をコピーで持っていた理由と、参照へ変えた判断: [research/260907_0316](./research/260907_0316-copy-vs-reference-video-storage.md) → [design/260912_2011](./design/260912_2011-photo-library-reference-storage.md)
- 初回検証の記録: [research/260906_1531-simulator-verification.md](./research/260906_1531-simulator-verification.md)
