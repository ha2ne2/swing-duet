# クラブヘッド軌跡の取り方：世の中の方式の調査と SwingDuet の選択肢

- 日付：2026-09-13
- 種別：調査（コード変更なし）
- 問い：「動画からクラブヘッドの軌跡を描く」はよくある要件で、うまく取る方法があるはず。今の方向
  （[design/260912_1635](../design/260912_1635-club-head-tracking.md) の A 線・B 塊 ＋ F 学習した検出器）でよいのか
- 前提：iOS ネイティブ、外部依存ゼロ（同梱する Core ML モデルは可）、主な入力は 240fps スロー原本、正面・後方の両方、練習場は夜もある

## 0. 結論

1. **「よくある要件」だが、動画だけで自動に描ける製品は少なく、あっても条件を強く絞っている**（§2）。
   自動でヘッド軌跡を描くのは ShaShot・GOLFTEC・ブリヂストン公式・楽天GORA・Golfboy 程度で、いずれも
   「明るい場所・三脚・スロー（120fps 以上）・ドライバーのみ・後方のみ・サーバーで 15 分」のような制約付き。
   V1 Golf / Onform / Swing Profile は骨格・3D・スイングプレーン線までで、ヘッド軌跡は自動で描いていない。
   ShaShot は「暗いと自動追跡が効かない」と開発者自身がレビューに回答している。
   → 苦戦しているのは方向違いではなく、問題そのものが難しい。**撮影条件を仕様として決める**のが製品の共通解
2. **研究と本格製品の主流は「クラブを姿勢推定のキーポイントとして、体と一緒に学習する」方式**（§3・§4）。
   Sportsbox（体・クラブ・ボールで 30 点超）、GolfPose（ICPR 2024、体 17 点＋クラブ 5 点）、単一カメラ研究（DeepLabCut、240fps 後方）、
   MDPI 2026（ヘッドとグリップ）がそう。ヘッドだけを物体検出（箱）で探すより、手首・腕との位置関係を同じネットが使えるので、小さく速いヘッドに強い。
   それでも**ヘッドは最も誤差が大きい点**（GolfPose：クラブ 62.8 mm vs 体 32.3 mm。学習からブレたコマを除いている。DeepLabCut 研究もインパクト付近で精度低下）
3. **少数の自前ラベルで効く**のがキーポイント方式の利点。DeepLabCut 研究は 27 本 × 約 30 コマ（約 800 ラベル）で軌跡を取り、
   Roboflow の例は 68 枚で mAP50 0.87。公開データ（Roboflow 8,405 枚）は昼しか覆わず、今日の Create ML 検出器も
   **昼の後方は塊追跡と 8〜9 割一致するが夜は 0%**（§1）。自前の条件（夜の練習場、正面・後方、240fps）で数百コマのラベルを作ることは、方式を問わず必須
4. **推奨**（§5）：方式 F を「箱の検出」から「キーポイント（ヘッド・グリップの 2 点）の回帰」へ組み替え、自前ラベルを主データにする。
   実行は Core ML（外部依存ゼロは変わらない）。学習は Create ML にキーポイント学習が無いので、開発機だけ Python（MMPose / RTMPose：Apache-2.0）を使う。
   その前に **1 日で済む確認**として、今日の Create ML 検出器に自前ラベル（箱）を足して再学習し、夜が上がるかを見る価値がある（学習 15 分・評価 1 分の環境が整った）。
   A・B（線・塊）は候補の検証と欠けの補間に残す

## 1. 現状：Create ML 検出器の結果（2026-09-13）

Roboflow「Golf club」全データ（train 15,972 / valid 2,952）を Create ML の転移学習で 2,000 反復（12 分）。

| 指標（mAP50） | 学習データ | 検証データ |
| --- | --- | --- |
| 全体 | 0.53 | 0.30 |
| club（クラブ全体） | 0.70 | 0.44 |
| club_head（ヘッド） | 0.35 | **0.16** |

| 動画 | ヘッドが出たフレーム | 塊（B）との一致 | 線（A）との一致 |
| --- | --- | --- | --- |
| macroy_behind（昼・後方・1/2 スロー） | 48%（103/214） | **80%**（51/64） | **90%**（27/30） |
| yuta_behind（夜・後方・1/4 スロー） | 0% | — | — |
| YouTube Shorts（昼・正面・実速 30fps・640p） | 8%（3/38） | — | — |
| Golfboy 合成（暗い室内・正面） | 2%（1/64） | — | — |

一致は箱の中心と塊・線の先端の距離が画面の 0.05 以内。昼の後方では「出れば正しい」候補になる。夜・低解像度・実速は公開データだけでは効かない
（昨日の YOLOv8n 1 エポックの実験と同じ結論。検証 mAP50 は YOLO 0.42 に対し Create ML 0.30 で、転移学習の方が弱い）。
落とし穴：Create ML の検出器は `VNCoreMLRequest.imageCropAndScaleOption = .scaleFill` にしないと箱の座標がずれる（既定の centerCrop では縦長動画で y が 0.56 倍に縮む）。

## 2. 製品調査：動画からヘッド軌跡を自動で描くか、その条件

| 製品 | ヘッド軌跡の自動描画 | 撮影条件 | 処理 | 備考 |
| --- | --- | --- | --- | --- |
| [ShaShot](https://apps.apple.com/us/app/shashot-golf-ball-tracer/id1595050744)（米） | あり（有料 $49.99〜）。「色・形・動きの手掛かり」で自動 | 30fps 可、60fps/スロー推奨。**暗いと不可**（開発者回答） | 端末 | レビューに「調整が多い・始点終点を拾えない」 |
| [Shot Tracer](https://www.shottracerapp.com/ios) | 「ストロボ式スイングトレーサー」 | 120 / 240fps、三脚 | 端末 | 技術は非公開。主は弾道 |
| [GOLFTEC アプリ](https://scramble.golftec.com/blog/2024/01/swing-record-golftec-app/) | クラブトレーサー（ヘッドとスイングパス） | 非公開 | 非公開 | |
| [Swing Profile](https://www.swingprofile.com/golf-swing-video-analysis/) | なし。自動はスイングプレーン線（地面に置いたクラブが基準） | 自動検出・録画 | 端末 | |
| [ブリヂストンゴルフ公式](https://www.golf-app.bridgestone/guide/image_diagnosis/) | 骨格・クラブ軌道・手軌道・頭軌道・ヘッドスピード | スロー動画・720p 以上・16:9、正面/後方、高さ 1 m・距離 4.5 m、**明るい場所**、三脚 | **サーバー約 15 分** | **ドライバーのみ** |
| [楽天GORA](https://gora.golf.rakuten.co.jp/doc/guide/gora_app/score/swing/) | 骨格とクラブ、バック/ダウンの軌道 | **後方のみ**、120fps 以上のスロー推奨、明るい場所、5 秒以内 | サーバー数分 | ドライバー/FW/UT/アイアン |
| [Golfboy](https://golfboy.jp/)（Qoncept） | インパクト前後のクラブ軌道の合成画像を自動生成 | 三脚で正面上から | 端末 | 主は弾道計測 |
| [Sportsbox 3D Golf](https://www.sportsbox.ai/technology) | 体・クラブ・ボールで 30 点超のキーポイント → 3D | 高速シャッター（クラブのブレ回避）、明るさ、単純な背景 | サーバー | [精度資料](https://help.sportsbox.ai/sportsbox-ai-accuracy)は体の指標のみ。クラブの精度は非公開 |
| [Onform](https://onform.com/blog/onform-launches-fast-reliable-and-accessible-markerless-3d-motion-capture-for-golf/)（2025-09 に 3D）/ [V1 Golf](https://goatcode.ai/v1-golf-app-review-2026-honest.html) | 見当たらない | 骨格追跡・自動切り出し・弾道 | | |

## 3. 研究・公開実装

| 出典 | 方式 | データ | 結果・限界 |
| --- | --- | --- | --- |
| [Gehrig ら 2003（BMVC）](https://www.commsp.ee.ic.ac.uk/~ng1/pdf/gehrig-et-al-bmvc03.pdf) | 動きマスク＋平行な縁の対＋極座標多項式の RANSAC | 学習なし | 設計書 §3 の元。候補が毎フレーム多数ある前提 |
| [Golfzon 特許 US11229824](https://patents.google.com/patent/US11229824B2/en)（2017） | 差分画像 → Hough でシャフト → 左右輪郭の間隔が広がる点をホーゼルとする | 学習なし | 高速ステレオカメラ（シミュレータの室内）前提 |
| [Chugh（UCSD）](https://people.cs.uchicago.edu/~rchugh/static/misc/golf/golfReport.pdf) | 動画素の線分の端点 | 学習なし | 30fps のブレが最大の問題 |
| [AICaddy](https://github.com/oswinkil-git/AICaddy-A-Golf-Club-Tracer)（2023、BSD-3） | YOLOv8 | ドライバーのヘッド 6,000 枚 | 重み・データ非公開 |
| [GolfTracer](https://github.com/jeremiahgivens/GolfTracer)（iOS、2023） | Core ML のクラブ＋ヘッド検出器（12 MB）。毎フレーム信頼度 0.05 で全部出し、クラブ箱の中のヘッド候補から、前 2〜3 点のラグランジュ外挿に最も近いものを選ぶ。無ければ前回と同じ象限に置く | 不明 | ライセンス不明。「候補は緩く出して運動モデルで選ぶ」は本設計と同じ |
| [onkar-99](https://github.com/onkar-99/Golf-Ball-Tracking) | YOLOv5 ＋ 失敗時はオプティカルフロー＋重心距離 | 自前 | ダウンスイングのブレで破綻、と作者自身が記載 |
| [GolfPose（ICPR 2024）](https://minghanlee.github.io/papers/ICPR_2024_GolfPose.pdf)・[コード](https://github.com/MingHanLee/GolfPose) | **体 17＋クラブ 5 のキーポイント**。YOLOX-s（golfer-with-club）AP 0.984 → HRNet / ViTPose / DEKR を微調整 | Vicon で 3D 真値、RGB に投影（許可制、屋内） | クラブ 2D AP 0.857〜0.870、3D はクラブ 62.8 mm（体 32.3）。GPU 27 FPS。**学習からブレたコマを除去**。屋外撮影は不可 |
| [単一カメラ研究（Sports 2023）](https://pmc.ncbi.nlm.nih.gov/articles/PMC10684732/) | DeepLabCut（ResNet-50）でヘッドをキーポイント追跡 | 27 名 × 約 30 コマ、240 Hz、後方 3.5 m | アドレス〜インパクトのみ（インパクト付近で精度低下） |
| [MDPI Applied Sciences 2026](https://www.mdpi.com/2076-3417/16/8/3813) | ヘッド 4,812・グリップ 4,639 の箱、YOLO11m | スタジオ、6 名 321 スイング | データ公開の記載なし |
| [TrackNet（2019）](https://arxiv.org/abs/1907.03698) → [V4（ICASSP 2025）](https://arxiv.org/abs/2409.14543) | **連続 3 フレーム → ヒートマップ**。V4 は差分画像の「動き注意」で 1.01M パラメータ、Jetson Nano 85 FPS | テニス・バドミントン | ゴルフへの適用例は無い。ブレの残像も手掛かりにできる |
| [Roboflow ブログ（2025）](https://blog.roboflow.com/golf-swing-analysis-with-vision-ai/) | 体＋クラブのキーポイント | [68 枚](https://universe.roboflow.com/golfswing-e1qwd/golf_club_pose) | mAP50 0.87。同じ撮り方なら少数で足りる例 |

## 4. 方式の比較

| 方式 | 学習するもの | 必要なデータ | ブレ・小ささへの強さ | iOS 実行 | ライセンス | 所見 |
| --- | --- | --- | --- | --- | --- | --- |
| (a) 物体検出（箱）＋追跡（今の F） | ヘッド・クラブの箱 | 公開数千枚＋自前 | 中。箱は 20〜40 px、ブレると箱にならない | Core ML。学習も Create ML で済む | データ CC BY 4.0 | 昼は効くが条件外に弱い（§1） |
| **(b) キーポイント（体と同時）** | ヘッド・グリップ（＋体） | **自前 数百〜千コマ** | 中〜高。腕との位置関係を使える | Core ML（PyTorch → coremltools） | MMPose / RTMPose Apache-2.0 | Sportsbox・GolfPose・DeepLabCut 研究。**Create ML は非対応** |
| (c) 連続フレームのヒートマップ（TrackNet 系） | ヘッド 1 点 | 数千コマ | 高。動きそのものを学習 | Core ML（1M パラメータ） | 実装 MIT 等 | ボール向け。(b) に時間軸を足す形で後から |
| (d) 古典：差分＋線＋塊（今の A・B） | なし | なし | 低。30fps 実速で破綻 | そのまま | — | 候補の検証と欠け埋めに残す |

## 5. SwingDuet への提案（段階）

1. **撮影条件を仕様にする**（[SPEC.md](../SPEC.md) §2 への追記候補）：240fps スロー・三脚・全身とクラブが入る・明るい。条件外は軌跡を出さない。製品は皆この割り切りをしている
2. **自前ラベル**：`docs/data/swings/` 32 本＋既存 4 本から、フェーズ前後を 60fps 相当で間引いて 300〜600 コマ。ラベルは**ヘッドとグリップの 2 点**
   （箱より速く付けられ、キーポイントにも箱にも変換できる）。下書きは今日の検出器＋塊の追跡。道具は Roboflow（無料、アカウントあり）
3. **最短の確認（1 日）**：Create ML 物体検出に自前の箱を足して再学習（15 分）→ 4 本＋夜の切り出しで評価。夜が数十 % に上がれば (a) のまま進める余地がある
4. **本命**：(b) RTMPose-t（Apache-2.0）をヘッド・グリップの 2 点で微調整。入力は手首中心の切り出し（体の高さの 1.5 倍角）。coremltools で Core ML に変換。
   学習は開発機の Python だけで、アプリの依存は増えない
5. 後処理は既存の極座標多項式・補間（設計書 §3.1 の 9）を、候補が密になった前提で仕上げる
6. 240fps 原本では解析レートを 60〜120fps に上げる（ブレが 1/8。研究も 240 Hz）

## 6. ライセンスと依存

- 使えない：Ultralytics（YOLOv8 / 11、YOLO-World）は AGPL-3.0
- 使える：MMPose / RTMPose・YOLOX（Apache-2.0）、DeepLabCut（LGPL-3.0。学習ツールとしてのみ）、RF-DETR・D-FINE（Apache-2.0）、coremltools（BSD-3）。
  Roboflow のデータは CC BY 4.0（About に表示）。GolfPose のデータは許可制で屋内モーションキャプチャ（自前条件には合わない）
- アプリ側は Core ML モデルの同梱のみ（[AGENTS.md](../../AGENTS.md) §4.2 の文言の見直しは設計書 §7 の提案のまま未合意）

## 7. 未確認と、次に決めること

- キーポイント学習の実行環境：Mac（M4・16 GB）の PyTorch / MPS で RTMPose-t の微調整が現実的か（数百枚なら 1 時間以内の見込み。未検証）
- 夜の 240fps 原本を撮る（既存の夜動画は 1/4 スローの書き出し）
- ラベル付けの道具：Roboflow か Mac の自作
- 決めること：§5 の 3（1 日の確認）をやってから 4 に行くか、直接 4 に行くか
