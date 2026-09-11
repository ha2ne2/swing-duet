# ジョグホイールの加速：親指の癖と既存製品・研究の調査

- 日付：2026-09-11
- 種別：調査（コード変更なし）
- 発端：実機で「親指で円を回すと、伸ばす瞬間（縁の右下 → 左上）だけ速い」ため、回す速さで 1 目盛りのコマ数を変える加速が
  1 周の中で ×1 と ×4 を行き来して違和感が出た（[design/260911_0741](../design/260911_0741-jog-wheel-frame-stepping.md) §7 の第 2 段）
- 問い：(1) その癖は個人の癖か、手の構造か。(2) 回して動かす製品・研究は「速く回すと速く進む」をどう決め、どう破綻を避けているか。
  (3) 親指 1 本のタッチで、精密な 1 コマと大きな移動を両立する直感的な方法は何か

## 1. 親指の速さの偏りは手の構造による

- Trudeau ら（Harvard、2012。片手持ちの携帯で親指のタッピング性能を Fitts の法則で計測、右利き 20 名）：
  親指の「外向き」の動き（**伸展と外転**：付け根から離れる方向）は「内向き」（屈曲と内転）より性能が高い（IPe 14.2 対 13.1）。
  内向きの動きは IP・MCP 関節の大きな屈曲と CMC 関節の伸展を同時に要し、拮抗筋の共収縮で細かい制御が落ちる。
  方向別では、右下 ⇄ 左上に近い斜め（外転・内転が主）が最良、左 ⇄ 右と左上 ⇄ 右下（屈曲・伸展が主）が最低
  （[論文](https://journals.sagepub.com/doi/10.1177/0018720811423660)、[要旨 PDF](https://stacks.cdc.gov/view/cdc/224404/cdc_224404_DS1.pdf)）
- Hoober の観察（1,333 件の持ち方の実地観察）：片手持ちの親指は付け根を中心にした**弧**の上を楽に動き、画面の上側や遠い隅には持ち替えないと届かない
  （[Smashing Magazine の解説](https://www.smashingmagazine.com/2016/09/the-thumb-zone-designing-for-mobile-users/)、[A List Apart](https://alistapart.com/article/how-we-hold-our-gadgets/)）

**結論**：右手の親指が円を描くと、伸ばす区間（右下 → 左上）が速く、曲げて戻す区間が遅いのは構造的な性質で、誰でも同じ向きに偏る。
**瞬間の角速度**を入力に使う限り、1 周ごとに 1 回は速い区間が来て、加速が周期的に脈打つ。

## 2. 既存の製品・研究はどう決めているか

| もの | 入力 → 出力 | 速さの扱い | 破綻を避ける工夫 |
| --- | --- | --- | --- |
| iPod クリックホイール（Rockbox の実装） | 1 周 96 クリック。クリック間の時間から度/秒 | 速度で加速 | 速度は `(15 × 前回 + 今回) / 16` の指数移動平均（強い平滑化）。250ms 入力が無ければ加速を解除。**逆回転で速度とためを 0 に戻す**（[ソース](https://github.com/mguentner/rockbox/blob/master/firmware/target/arm/ipod/button-clickwheel.c)、[Rockbox 文字入力: 逆転で加速オフ](https://www.rockbox.org/tracker/task/10763)） |
| マウスホイールの加速（Microsoft 特許 US7665034） | 連続したノッチの数と間隔 | ノッチが 130ms 以内に続く「連なり」の長さ C で 1 ノッチあたり `1 + Q(C − 1)` 行、4 ノッチが 80ms 以内ならページ送り | 連なりが途切れたら 1 行に戻る。150ms 待って次のノッチを見てから実行（[特許](https://patents.google.com/patent/US7665034B2/en)） |
| Apple Watch Digital Crown / Wear OS | 回転量と回転速度 | 速度に応じて量を増やす（対応表） | 物理クラウンは指の動きが一様なので脈打たない。触覚の刻みは一定距離ごと（[HIG](https://developer.apple.com/design/human-interface-guidelines/inputs/digital-crown)、[Wear OS](https://developer.android.com/training/wearables/compose/rotary-input)） |
| Final Cut Pro for iPad のジョグホイール | 円の中を**ドラッグ**した量 | 「速くドラッグで流し見、ゆっくりで 1 コマ」 | 画面の左右どちらにも置き直せる（親指側）。時計回り = 進む（設定で逆）。触覚の記述は無し（[Apple サポート](https://support.apple.com/guide/final-cut-pro-ipad/make-precise-edits-with-the-jog-wheel-dev06c7d60ae/ipados)） |
| Coach's Eye / Hudl Technique（スポーツ動画分析） | 横の「フライホイール」をなでる | 往復で精密、弾くと慣性で高速 | 同じ用途（フォーム分析）の先例。円ではなく横の帯（[Google Play](https://play.google.com/store/apps/details?id=org.gymart.coachseye)、[Hudl Technique](https://appstor.io/app/hudl-technique-golf-formerly-ubersense-swing-analysis)） |
| Pioneer CDJ のフレームサーチ | ジョグを回した量 | 1 周 = 135 フレーム（1.8 秒）固定。速く回せば速く進む（比例。ギアは無い） | 高速サーチは SEARCH ボタンを押しながら回す（モードを分ける）（[CDJ-800 取説](https://www.manualslib.com/manual/130570/Pioneer-Cdj-800.html?page=13)） |
| ジョグ / シャトルダイヤル（Contour など） | ジョグ = 1:1 のコマ。シャトル = 外輪をひねった**角度**が速さ | 角度 ±30° までスロー、±90° で最速。離すとバネで中央に戻り停止 | 「回し続ける」代わりに「ひねって保持」で連続移動する（[Deskthority](https://deskthority.net/wiki/Jog/shuttle_dial)、[特許の説明](https://patents.justia.com/patent/20030190141)） |
| iOS のミュージック / TV のシーク | つまみを横に動かしつつ、**下へ離した距離**で精度 | 高速 → 1/2 → 1/4 → 細かく の 4 段。段が変わるとき触覚 | 精度の切り替えを速さではなく指の位置で決める（[How-To Geek](https://www.howtogeek.com/254608/how-to-scrub-through-audio-and-video-slowly-in-ios/)） |
| Virtual Scroll Ring（Moscovich & Hughes、UIST 2004） | 直近 30 点に円を当てはめ、**円周上の移動距離** 2θr | 「角度で決めるのは逆効果。小さく速い円で速く、大きくゆっくりで遅くなってしまう」。距離なら大きく or 速く動かせば速い | 円を固定しない（半径と中心のずれを許す）。半径を変えると同じ回す速さで送り速度を広く変えられる（[論文 PDF](https://www.dgp.toronto.edu/~tomer/store/papers/scrollring04.pdf)） |
| Radial Scroll（Smith & schraefel、UIST 2004）/ Synaptics ChiralMotion | 円運動の向きと量 | 距離に比例 | 一度回し始めれば面のどこでも続けられる。逆回転で即反転（[Radial Scroll](https://dl.acm.org/doi/10.1145/1029632.1029641)、[ChiralMotion](https://investor.synaptics.com/news-releases/news-release-details/synaptics-chiralmotiontm-technology-provides-intuitive-touch)） |

## 3. 分かったこと

1. **速さで加速している物は、指の動きが一様な物理ダイヤルか、強い平滑化と「逆転で解除」を持つ物だけ**。iPod は親指の円運動を受けるが、
   速度を 16 回分ならして、しかも用途はリストのスクロールなので多少の脈打ちは目立たない。コマ単位で映像を見る用途では脈打ちがそのまま見える
2. **連続して回したら速く**の定番は「連なりの長さ」（Microsoft）＝回した量の累積。瞬間の速さではない。途切れ（間隔の上限）と**逆回転**で解除する
3. **距離（弧の長さ）で決めれば脈打たない**。VSR は角度ではなく円周上の距離を使い、「大きく回す or 速く回す = 速い」を自然に成り立たせている。
   固定の輪では角度と弧長は同じものなので、輪の上では「回した量に比例」＝いまの ×1 の挙動がすでにこれに当たる
4. **精度の切り替えは速さ以外の軸に置ける**：指の位置（iOS のシーク：下へ離す距離）、ひねりの角度（シャトル）、別ボタン（CDJ の SEARCH）
5. **「回し続ける」以外に「ひねって保持」がある**（シャトル）。保持は静止なので親指の速さの偏りが入り込まない。
   ただし触覚の刻みは「距離」に付いてこそ意味があり、シャトルでは音楽の早送りのような別の合図が要る
6. Apple の FCP for iPad はホイールを**親指側に置き直せる**ようにしている。横画面や左利きの扱い（設計書 §6 第 3 段）はこの形が先例

## 4. 提案（設計書 §6 の再整理）

親指の偏りを前提に、**1 周の中で目盛りの重さを変えない**ことを原則にする。

| 案 | 仕組み | 精密な 1 コマ | 大きな移動 | 偏りへの耐性 | 先例 |
| --- | --- | --- | --- | --- | --- |
| **A 周回ギア（推し）** | 指を置いてからの累積回転で 1 周目 ×1、2 周目 ×2、3 周目 ×4、4 周目〜 ×8。離す・0.3 秒止まる・逆回転で ×1 に戻る | 1 周目は常に 1 コマ | 4 周で約 15 秒分 | ◎ 1 周の中は一定 | Microsoft の「連なり」、iPod の逆転解除 |
| B シャトル | 再生ボタンを左右に引いて保持。引いた距離が速さ（±3 段）。離すと戻って停止 | 輪の回転（×1）はそのまま | 保持している間ずっと | ◎ 静止なので偏り無関係 | ジョグ / シャトルダイヤル |
| C 精度を位置で選ぶ | 輪の外縁を回すと ×1、内縁寄りを回すと ×4（半径で決める） | 外縁 | 内縁 | △ 親指の半径も伸ばす区間で変わる | iOS のシーク（距離で精度） |
| D 自由な円 | 輪を捨て、ペインの下半分で描いた円に中心を当てはめ、弧長で進める | 大きな円 | 小さく速い円 | ○ 距離基準 | VSR / ChiralMotion |
| 却下 瞬間の速さ | 現状 | — | — | × 1 周ごとに脈打つ | iPod でも 16 回の平滑化が必要 |

- A は実装が最も小さく（`JogRotation` の速度平均を「累積角度」に置き換えるだけ）、動きが言葉で説明できる（「回した周の数で段が上がる」）。
  ギアが上がる瞬間に `.increase` の触覚を 1 回入れると、指で段が分かる
- B は A と両立する（回す = 精密、引いて保持 = 連続）。A で足りなければ足す
- C は手の構造上、半径も伸ばす区間で変わるので避ける。D は既存のピンチ・ドラッグと衝突するので保留

## 5. 参照

- Trudeau, Udtamadilok, Karlson, Dennerlein. Thumb Motor Performance Varies by Movement Orientation, Direction, and Device Size During Single-Handed Mobile Phone Use. Human Factors, 2012. https://journals.sagepub.com/doi/10.1177/0018720811423660
- Hoober. How We Hold Our Gadgets. https://alistapart.com/article/how-we-hold-our-gadgets/
- Rockbox iPod click wheel driver. https://github.com/mguentner/rockbox/blob/master/firmware/target/arm/ipod/button-clickwheel.c
- Microsoft. Accelerated scrolling (US7665034B2). https://patents.google.com/patent/US7665034B2/en
- Apple. Digital Crown – Human Interface Guidelines. https://developer.apple.com/design/human-interface-guidelines/inputs/digital-crown
- Apple. Make precise edits with the jog wheel in Final Cut Pro for iPad. https://support.apple.com/guide/final-cut-pro-ipad/make-precise-edits-with-the-jog-wheel-dev06c7d60ae/ipados
- Moscovich, Hughes. Navigating Documents with the Virtual Scroll Ring. UIST 2004. https://www.dgp.toronto.edu/~tomer/store/papers/scrollring04.pdf
- Smith, schraefel. The Radial Scroll Tool. UIST 2004. https://dl.acm.org/doi/10.1145/1029632.1029641
- Deskthority. Jog/shuttle dial. https://deskthority.net/wiki/Jog/shuttle_dial
- How-To Geek. How to Scrub Through Audio and Video Slowly in iOS. https://www.howtogeek.com/254608/how-to-scrub-through-audio-and-video-slowly-in-ios/
- Pioneer CDJ-800 取扱説明書（ジョグダイヤル）. https://www.manualslib.com/manual/130570/Pioneer-Cdj-800.html?page=13
- Coach's Eye (Google Play). https://play.google.com/store/apps/details?id=org.gymart.coachseye
