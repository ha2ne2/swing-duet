# 他のゴルフスイングアプリの良い機能：自動録画・切り出し、骨格表示、その他

- 日付：2026-09-12
- 種別：調査（コード変更なし）
- 発端：「自動録画＆切り出し（アプリでスロー撮影できるか）」「骨格の棒人間（ひねりを見たいので棒＋面）」が気になる。他にも取り込む価値のある機能はあるか。
  参考記事：[ゴルフスイング軌道アプリおすすめ 8 選（LOVE ゴルフスクール）](https://loveledge.jp/mover/golf-swing-path-app-free/)
- 問い：(1) 自動録画と切り出しは各アプリがどう実現していて、アプリ内でスロー撮影できるのか。(2) 骨格はどう見せていて、「ひねり」を面で見せる例はあるか。
  (3) それ以外に SwingDuet に合う機能は何か
- 注意：各社の公開ページ（App Store・公式サイト・サポート記事）の記述をまとめたもので、実機で試してはいない

## 1. 見たアプリと機能の一覧

| アプリ | 自動録画・切り出し | アプリ内スロー撮影 | 骨格・3D | 比較 | 目を引く機能 | 料金・OS |
| --- | --- | --- | --- | --- | --- | --- |
| [Swing Profile](https://www.swingprofile.com/)（NZ） | 「AI」でスイングを連続検出し、**2 秒だけに自動トリム**、直後に**スロー自動再生**。三脚に置いて手放し | 最高 240fps（背面カメラのみ。レビューでは iPad 60 / iPhone 120） | 無し | 並べ・重ね。**テンポが違っても自動同期** | 自動ライン（スイングプレーン・肩の面・鉛直線）、ボール追跡 | 無料枠あり、Coach $19.99/月。iOS/Android |
| [SWNG](https://swnggolf.app/) | **画面内の動き**で検出し、始まった瞬間から録画。成功を**音**（スピーカー / AirPods）で知らせる。体の枠のガイド | **240 / 120fps**、1/8 スロー | 無し（AI 解析なしを売りにする） | 無し | コマ送り・描画・クラブ別ライブラリ・書き出し | 無料。iPhone のみ |
| [Swing Loop](https://swingloop.app/) | 体の動きで検出。**インパクト音**を同期して保存 | 30 / 60 / 120fps | 無し | 練習ごとに並べる | 端末内保存 | 無料。iOS/Android |
| [Golf Vision](https://www.golf-vision.com/)（[App Store](https://apps.apple.com/us/app/golf-vision-ai-swing-recorder/id1582271201)） | AI が動きを認識し**アドレス〜フィニッシュを 1 打ごとに自動切り出し** | 記載なし | 無し | 無し | **ジェスチャーで NICE / BAD のタグ**、11 種のガイドライン | 1 日 10 ショット無料。iPhone/iPad |
| [Golf Swing Cam](https://apps.apple.com/us/app/golf-swing-cam-slow-motion/id6458876528) | スマート検出、直後にスロー再生 | 120fps | 無し | 無し | | iOS |
| [Onform](https://onform.com/sports/golf/) | **Auto-Detect**（AI がスイングを検出して 1 クリップに自動トリム、題名を音声で）。ほかに **One-Tap**（インパクトでタップし、前後の秒数を合成）、Bluetooth ボタン、音声、Apple Watch、マルチカム（[録画モード一覧](https://support.onform.com/article/101-recording-modes)） | 最高 1080p 240fps、**シャッター速度を手動で**（[ブレ対策](https://onform.com/blog/eliminate-motion-blur/)。Auto-Detect は低めの設定になる記述あり、要確認） | 2026 年に**単眼マーカーレス 3D**（胴体・骨盤の回転、スウェイ、リフト、テンポなど 12 指標、[解説](https://onform.com/3d-golf-swing-analysis/)） | 並べ・重ね・3D | 描画・音声コメント・コーチ連携・打球計測器の数値重ね | 個人は 14 日体験後に有料。iOS/Android |
| [V1 Golf](https://apps.apple.com/us/app/v1-golf-golf-swing-analyzer/id349715369) | 記載なし | 240fps | **V1sion**：骨格オーバーレイ（腰の回転・肩の面・姿勢角。正面・後方どちらでも、[解説](https://v1sports.com/inside-v1-golfs-skeletal-tracking-feature/)） | 並べ・重ね、ツアープロの動画ライブラリ | 描画・角度、**Hand Trace**（手の軌跡、[解説](https://v1sports.com/hand-trace-the-v1-golf-feature-that-reveals-why-your-swing-isnt-improving/)）、コーチ送信 | Premium 有料。iOS/Android |
| [Sportsbox 3D Golf](https://www.sportsbox.ai/) | 記載なし | 記載なし | **単眼 2D → 3D アバター**。真上を含む 6 方向から見られる（[視点](https://help.sportsbox.ai/what-angles-can-i-view-the-avatar-from-in-the-sportsbox-3dgolf-app)）。Chest / Pelvis の Turn・Bend・Side Bend・Sway・Lift、**X-Factor**、テンポなど数値（[トラッカー一覧](https://help.sportsbox.ai/what-trackers-are-included-with-3d-practice)） | プロと 3D で | 数値の推移グラフ | 有料。iOS |
| [DeepSwing](https://deepswing.io/ai-golf-swing-analyzer/) | 自動でフェーズ分割（6 フェーズ） | 記載なし | 端末内 AI で **24 点**、**回転できる 3D 骨格**。肩の回転・腰の回転・脊椎角・スイングプレーン | **ゴーストオーバーレイ**（お手本を半透明で重ねる） | 課題の優先順位・ドリル | 無料 + 有料。iOS/Android |
| [GolfFix](https://www.golffix.io/en/golffix)（韓国・日本語対応） | アドレス〜フィニッシュを**自動検出して記録**、スイングの連続画像を生成 | 記載なし | 骨格オーバーレイ | | 45 種の問題を検出。**テンポを 4 分割**（全体・バック・**トップの静止**・ダウン） | 広告 + 課金。iOS/Android |
| [SwingX](https://swing-x.com/lp/)（日本） | 記載なし | 記載なし | 骨格を自動で出す | **プロと自動でタイミングを合わせて並べ、差を色で** | YouTuber プロのレッスン動画 | 500 円/回、980 円/月。iOS/Android |
| [18Birdies AI Coach](https://18birdies.com/aicoach/) | 記載なし | 記載なし | 体の上に緑のマーカー（注目箇所） | プロのモデルと | スコア、テンポのバー、3 つのドリル | 有料。iOS/Android |
| [Golfboy](https://golfboy.jp/)（日本） | **自動録画**（2 台ペアリングで撮影側が自動保存）、打球計測（飛距離・ボール速度・打ち出し角・クラブ速度）と**クラブ軌道の合成画像** | 記載なし | 記載なし | 過去データと | モーション画像・パノラマ | 500 円/月。iPhone のみ |

## 2. 自動録画と切り出し

**検出の方式は 3 つ**に分かれる：

1. **画面内の動きの量**で検出する（SWNG、Swing Loop）。軽く、AI 不要。人以外の動き（後ろを通る人）に反応しうる
2. **姿勢推定・AI でスイングと認識**する（Swing Profile、Onform Auto-Detect、Golf Vision、GolfFix）。アドレス〜フィニッシュを切り出せる
3. **手動の起点だけ楽にする**（Onform One-Tap：インパクトでタップすると前後の設定秒数を切り出す。Bluetooth ボタン、音声、Apple Watch）。自動検出の保険になる

**どのアプリも同じ作法**：三脚に置いて手放し → スイングごとに 2〜3 秒の 1 クリップ → **直後にスローで自動再生** → 次のスイングを待ち続ける。
SWNG は成功を音で知らせ（打席から画面を見なくて済む）、Golf Vision はジェスチャーで NICE / BAD を付け、Onform は題名を音声で入れる。

**アプリ内でスロー撮影できるか：できる。** iPhone の 240fps はサードパーティにも開かれていて、`AVCaptureDevice` の `activeFormat` に
240fps を含む形式を選ぶだけで撮れる（1080p 240fps は iPhone 8 以降。[Apple のカメラ対応表](https://developer.apple.com/library/archive/documentation/DeviceInformation/Reference/iOSDeviceCompatibility/Cameras/Cameras.html)、
[TN2409](https://developer.apple.com/library/archive/technotes/tn2409/_index.html)）。実際に SWNG が 240fps、Swing Profile と Onform が最高 240fps を謳う。
ただし**毎フレームの姿勢推定と 240fps 録画の両立は負荷が高い**ので、Onform の Auto-Detect が手動より低い解像度・fps になるという記述があるのはそのためと見られる。

**SwingDuet でやるなら**：

- 240fps で常時録り続ける**リングバッファ**（`AVCaptureVideoDataOutput`）に、間引いたフレーム（例：30fps）だけを既存の `PoseTracker`（手首・腰・首）に通す。
  既存の `SwingDetector`（手の高さの系列からアドレス〜フィニッシュを出す）がそのまま「切り出し」になる。検出したら前後に余白を付けて `AVAssetWriter` で 1 クリップに書き出す
- 書き出しは取り込み時と同じ形式に揃える（[TODO.md](../TODO.md) I の再エンコード方針が決まればそれに合わせる）
- 直後の比較：切り出したクリップをスイングとして保存し、いつものお手本と並べてスローで自動再生する（今の「取り込み → 解析 → 比較」の流れの入口を増やすだけ）
- One-Tap 相当（インパクトでタップ）は、検出が外れたときの保険として安い
- 制約：シミュレータでは Vision が動かないので実機でしか試せない（[AGENTS.md](../../AGENTS.md) §4.4）。長時間の 240fps 録画は熱と電池を実機で見る

## 3. 骨格表示と「ひねり」

**見せ方は 2 段階**：

- **2D の骨格オーバーレイ**（V1 Golf V1sion、GolfFix、SwingX、18Birdies、DeepSwing）：動画の上に関節と棒を描く。後方視点なら肩の線・腰の線の**縮み**で回転が読める。
  SwingDuet はすでに `PoseTracker` で関節を追跡しているので、その結果を描けば最小の骨格は出せる
- **3D**（Sportsbox、Onform 3D、DeepSwing）：単眼の動画から 3D の姿勢を出し、アバターや骨格を回して見る。Sportsbox は**真上（Bird's-eye）からの視点**で胸と骨盤の回転を見せ、
  Chest Turn・Pelvis Turn・その差の **X-Factor** を数値で出す（[説明](https://clubhousehawaii.com/blogs/news/sportsbox-ai-x-factor-swing-analysis)）

**「棒＋面」を明示しているアプリは見つからなかった。** 3D 勢は「アバター＋数値」「真上から見る」で、面（肩の面・骨盤の面）そのものを描く例は公開情報になかった。
ひねりの中身は「肩の線と腰の線の水平角の差」なので、面で見せるなら 3D の関節が要る。

**iOS 標準で 3D が取れる**：iOS 17 の Vision `VNDetectHumanBodyPose3DRequest` は単眼の画像から **17 関節の 3D 位置**（カメラ相対、メートル）を返す
（[Apple](https://developer.apple.com/documentation/vision/vndetecthumanbodypose3drequest)、[サンプル](https://developer.apple.com/documentation/vision/detecting-human-body-poses-in-3d-with-vision)、
[WWDC23](https://wwdcnotes.com/documentation/wwdc23-111241-explore-3d-body-pose-and-person-segmentation-in-vision/)）。Neural Engine 必須、シミュレータ不可、1 人だけ。
今の `PoseTracker` は 2D の `VNDetectHumanBodyPoseRequest` なので、3D 版に替えるか併用すれば外部依存ゼロのまま面が作れる。精度（後方視点・ブレ・小さく写る人物）は実機で要検証。

**SwingDuet での見せ方の案**：

- 動画の上に骨格（棒）と、両肩・両腰から作る**半透明の板 2 枚**（肩の面・骨盤の面）。板の向きの水平角を「肩 60° / 腰 40° / 差 20°」と数字で添える
- 画面の隅に**真上から見た 2 本の線**（肩・腰）だけを出す「上から見た回転メーター」。左右 2 本を同時に出せば、同期再生のまま差が読める
- まず 2D の骨格（`PoseTracker` の結果の描画）を出し、3D は `VNDetectHumanBodyPose3DRequest` の精度を実機で測ってから決める

## 4. その他の取り込み候補

| 機能 | 見た例 | SwingDuet との相性 |
| --- | --- | --- |
| 直後のスロー自動再生 + 成功音 | Swing Profile、SWNG、Onform | 自動録画とセット。打席から画面を見ずに済む |
| ゴーストオーバーレイ（2 本を半透明で重ねる） | V1 Golf、DeepSwing、[FreeGolfSwingAnalyzer](https://freegolfswinganalyzer.com/)、[PitchGrid](https://apps.apple.com/ca/app/pitchgrid/id6748971191) | 同期・位置合わせ・拡大がすでにあるので、左右並びに「重ねる」表示を足すだけ |
| 手の軌跡（Hand Trace）・自動ライン（スイングプレーン、肩の面、鉛直線） | V1 Golf、Swing Profile | 手首の追跡結果から手の軌跡は描ける。SPEC §3 で除外中の「線引き」の自動版 |
| テンポにトップの静止を足す（4 分割） | GolfFix | 今のテンポ比（バック : ダウン）に「トップの間」を加えるだけ |
| ジェスチャー / 音声でタグ | Golf Vision、Onform | ★ お気に入りに相当。自動録画ができてから |
| プロとの差を色で | SwingX | 骨格ができてから |
| 2 台で正面と後方を同時に | Onform マルチカム、Golfboy ペアリング | 大きい。先送り |
| 打球計測（ボール速度・飛距離） | Golfboy、Onform + 計測器 | 別物。やらない |

## 5. 進め方の提案

1. **自動録画（アプリ内 240fps キャプチャ + 既存の検出で切り出し + 直後の比較）**を第 1 候補にする。取り込みの手間が今いちばんの摩擦で、
   `SwingDetector` と `SlowFactor` がそのまま使える。設計で決める点：リングバッファの長さ、検出に使う fps、熱と電池、保存形式、カメラ権限の文言、三脚時の枠ガイド
2. **骨格は 2D から**。`PoseTracker` の結果を動画に重ねるだけなので小さい。「面」は `VNDetectHumanBodyPose3DRequest` を実機で測る調査を挟む
3. **ゴーストオーバーレイ**は小さいので、隙間で入れられる
