# リファクタの採点記録・第 2 回：ずんだもんとめたんの対話（2026-09-12）

2026-09-12 に行ったプロジェクト全体のリファクタ（ファイル配置・重複・コメント・ドキュメント整合）で、何がどれだけ良くなったかを残す記録。
数字は git の HEAD（リファクタ前）と作業ツリー（後）を比べた実測値。採点は実施した AI エージェントの自己採点（10 点満点）で、
根拠は書くが主観であることに注意。前回（2026-09-11）の記録は [260911_0609](./260911_0609-refactor-scorecard-dialogue.md)、
変更後の構成の索引は [ARCHITECTURE.md](../ARCHITECTURE.md) §2 を参照。

**登場人物**

- **ずんだもん**：1 年後にこのコードを読みに来た人の役
- **めたん**：今回のリファクタを実施した人の役

---

## 第 1 幕　まず数字を見るのだ

**ずんだもん**「めたん、また全体をリファクタしたって聞いたのだ。前回は行数がほとんど減らなかったのだ。今回はどうなのだ？」

**めたん**「今回は 1 行も減っていないわ。アプリ本体で 4,333 行が 4,334 行。ぴったり同じと言っていい」

**ずんだもん**「それは……リファクタしたと言えるのだ？」

**めたん**「言えるわ。減らしたのは行ではなくて、**同じ判断を書いている場所の数**と、**1 つのファイルを開いたときに目に入る型の数**よ。
足したのは、その判断を 1 か所に置くための小さな部品と、その部品の説明。数字はこう」

| 指標                                                         | 前              | 後                         |
| ------------------------------------------------------------ | --------------- | -------------------------- |
| アプリの Swift 行数（`SwingDuet/`）                          | 4,333           | 4,334（±0）                |
| Swift ファイル数                                             | 32              | 34（`JogRotation` / `PaneHeader` を分離） |
| 非 private の型が 2 つ以上同居しているファイル               | 13              | 9                          |
| 「Optional が nil でなければ表示」を手書きした `Binding`     | 3 か所          | 0（`Binding.isPresent()`） |
| 「解析済みならそのフェーズ、未解析なら 0 秒」のサムネイル判定 | 3 か所          | 0（`Clip.thumbnailTime(of:)`） |
| 拡大率・位置を 1 と 0 に戻す 3 行の並び                       | 2 か所          | 0（`VideoConfig.resetTransform()`） |
| View がファイル名から動画 URL を引く `videoURL(for: clip.fileName)` | 6 か所      | 0（`ClipStore.videoURL(of:)`。ファイル名版は private） |
| `DateFormatter` の生成                                       | 表示のたびに 3 種 | 起動後 1 回ずつ 4 つ       |
| 非推奨 API（`UIScreen.main`）                                | 1               | 0（環境の `displayScale`） |
| 合成できるのに手書きしていた memberwise init                  | 1（`Pairing`）  | 0                          |
| 写真ライブラリ（PhotoKit）を扱う型                           | 2（enum + View 内のクラス） | 1（`PhotoLibrary`） |
| テストの実態と食い違っていたドキュメント                     | 4（AGENTS / ROADMAP / TODO / build-test） | 0        |
| 単体テスト                                                   | 32 件 pass      | 32 件 pass                 |

**ずんだもん**「ファイルごとに見るとどうなのだ」

| ファイル                              | 前  | 後  | 何をしたか                                                                         |
| ------------------------------------- | --- | --- | ---------------------------------------------------------------------------------- |
| `Views/Stage/JogWheelView.swift`      | 219 | 142 | 回転を目盛りに数える `JogRotation` を分離                                          |
| `Views/Stage/JogRotation.swift`       | —   | 78  | 新設（純粋計算。テスト対象）                                                       |
| `Views/Stage/VideoPaneView.swift`     | 209 | 164 | 2 画面で使う `PaneHeader` と `paneChip` を分離                                     |
| `Views/Stage/PaneHeader.swift`        | —   | 44  | 新設                                                                               |
| `Views/Picker/LibraryGridView.swift`  | 218 | 184 | View の中にあった PhotoKit の一覧クラスを `Services/` へ                            |
| `Services/PhotoLibrary.swift`         | 77  | 98  | 一覧・権限・原本の書き出しを `PhotoLibrary` 1 つの型に                              |
| `Views/Picker/AssetThumbnail.swift`   | 56  | 42  | 1 か所でしか使わない `SourceThumbnail` を使う側へ                                  |
| `Views/Picker/VideoPickerSheet.swift` | 153 | 167 | `SourceThumbnail` を private で受け入れ。`PickerTab` を `VideoPickerSheet.Tab` に  |
| `Models/Formatting.swift`             | 45  | 50  | `DateFormatter` を使い回す                                                         |
| `Models/VideoConfig.swift`            | 114 | 121 | `resetTransform()` を追加                                                          |
| `Models/Clip.swift`                   | 113 | 112 | `Pairing` の手書き init を削除、`thumbnailTime(of:)` を追加                        |
| `Views/Shared/Alerts.swift`           | 35  | 42  | `Binding.isPresent()` を追加                                                       |
| `Views/Stage/ComparisonView.swift`    | 126 | 123 | 基準の Binding を `$store.reference` に。相手へ写す範囲の理由をコメントに           |

---

## 第 2 幕　何がどう分かりやすくなったのか

### 2.1　ファイルを開いたら、その名前の型が出てくる

**ずんだもん**「`JogWheelView.swift` を開いたら、後半に `JogRotation` っていう別の型が 75 行あったのだ。あれは何だったのだ？」

**めたん**「ホイールの回転を目盛りに数えて、周回でギアを上げる純粋計算よ。テストも 10 件ある。
テストされている型が View のファイルの後ろに隠れていると、テストから探しに行く人が迷うでしょう。独立させたわ」

**めたん**「同じ理由で 3 つ動かしたの」

- `PaneHeader`（ペイン上端の名前と「替える」）は `VideoPaneView` と `StageView` の 2 画面で使うのに、片方のファイルの末尾にあった → 独立
- `PhotoLibraryVideos`（写真ライブラリの一覧と変更監視）は `Services/` の仕事なのに `LibraryGridView.swift` の中にあった → `Services/PhotoLibrary.swift` へ
- `SourceThumbnail` は `VideoPickerSheet` の名前付けステップでしか使わないのに `AssetThumbnail.swift` にいた → 使う側の private へ

**ずんだもん**「`PhotoLibrary.swift` は、動かしたあとにもう一回いじってるのだ」

**めたん**「最初は『一覧のクラス』と『書き出しの enum』を同じファイルに並べたの。でも読み直したら、enum の static 関数 3 つ
（権限の確認・権限の要求・動画の一覧）は呼び出し元がそのクラスだけだった。それなら型は 1 つでいい」

```swift
// 前：2 つの型に分かれ、View 側は 2 つの名前を覚える
@StateObject private var library = PhotoLibraryVideos()
Button("さらに選ぶ") { PhotoLibrary.presentLimitedLibraryPicker() }

// 後：写真ライブラリは PhotoLibrary の 1 語
@StateObject private var library = PhotoLibrary()
Button("さらに選ぶ") { PhotoLibrary.presentLimitedLibraryPicker() }
```

**ずんだもん**「ファイル名と型名が同じになったのだ。探しやすいのだ」

### 2.2　同じ判断を 3 回書かない

**ずんだもん**「重複って、具体的にどんなのがあったのだ？」

**めたん**「1 つ 1 つは 1 行の、目立たないものばかりよ。だからこそ 3 か所に散っていたの」

```swift
// 前：アラートとダイアログの isPresented に、毎回この Binding を組み立てていた（3 か所）
isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })

// 後
isPresented: $deleting.isPresent()
```

```swift
// 前：サムネイルの時刻を出すたびに「解析済みか」を見ていた（3 か所。しかもフェーズがそれぞれ違う）
VideoThumbnail(url: ..., time: clip.isAnalyzed ? clip.video.phases.address : 0, ...)

// 後：「未解析なら先頭」という判断は Clip が 1 回だけ持つ
VideoThumbnail(url: store.videoURL(of: clip), time: clip.thumbnailTime(of: .address), ...)
```

**めたん**「`videoURL` も同じ。View は `clip.fileName` を取り出して `ClipStore` に渡していたけれど、ファイル名は保存の都合であって
View が知る必要はないわ。`videoURL(of: clip)` にして、ファイル名で引く版は `ClipStore` の中だけの private にした」

**ずんだもん**「`Pairing` の init が消えてるのだ。壊れないのだ？」

**めたん**「Swift は独自の init を書くと memberwise init を作ってくれなくなる。だから手書きで再現していたの。
独自の init を extension に移せば、本体の memberwise init は生きたままよ。`SyncEngine` が既にその形だったから、揃えただけ」

### 2.3　毎回作っていたものを 1 回にする

**めたん**「一覧の行ごとに `DateFormatter()` を作っていたわ。あれは作るのが重い部類で、60 行の一覧なら 60 個。
静的に 4 つ持って使い回すようにした。見た目は変わらないけれど、1 年後に『一覧が重い』と調べに来る人が 1 人減る」

### 2.4　View が持たなくていいものを持たない

```swift
// 前：@EnvironmentObject の値を、わざわざ Binding に包み直していた
private var reference: Binding<VideoSide> {
    Binding(get: { store.reference }, set: { store.reference = $0 })
}
ControlPanelView(controller: controller, reference: reference)

// 後：$store.reference で足りる
ControlPanelView(controller: controller, reference: $store.reference)
```

**めたん**「ホームの一覧で最後の節だけにフッターを付けるのも、`enumerated()` で添字を数えて `index == count - 1` と比べていたのを、
『この節は最後の節か』の比較に変えたわ。読むときに添字を追わなくて済む」

### 2.5　コメント

**ずんだもん**「コメントは前回『元からよく書けている』って言ってたのだ。今回は何を直したのだ？」

**めたん**「4 種類。どれも小さいけれど、1 年後に読む人の足を止めるものよ」

1. **推測の削除**：`PlaybackController` の NOTE にあった「基準の Picker が再生中に効かないのも同じ原因とみている」。もう起きていない症状の推測は、読む人に『今も起きるの？』と考えさせるだけ
2. **種類の修正**：`VideoImporter` の「iOS 18 で置き換わった。最低 OS を上げたら移行する」は将来の作業なので `NOTE` ではなく `TODO`
3. **実態とのずれ**：`ClipStore.swingLimit` の「フッターの文言と合わせる」は、フッターが定数を表示するようになって以降は何も合わせる必要がない。今の関係（フッターにこの数を出す）に書き換えた
4. **理由の追記**：`ComparisonContent` が相手のクリップにフェーズだけを写して位置合わせを写さないのは、相手が ★ ベストのスイングだったときに、そのスイング自身の位置合わせを壊さないため。これは読んでも分からないので書いた

**めたん**「あとは『1本』『4つ』のように数字と単位がくっついていたコメントを、他と同じ『1 本』『4 つ』に揃えたわ。細かいけれど、揃っていないと目が引っかかる」

### 2.6　ドキュメントが実態から遅れていた

**ずんだもん**「ドキュメントも直したのだ？」

**めたん**「これが今回いちばん大きいかもしれない。テストの状況を書いた場所が 4 つあって、全部『検出ロジックしかテストがない』と言っていたの。
実際には `SyncEngine`・動画の速さ・`ClipStore`・`JogRotation` のテストが既に 32 件あった。前回のわたくしが宿題にした `SyncEngine` は、
その後の機能追加のときに片付いていたのに、宿題の紙だけ残っていたのよ」

**ずんだもん**「1 年後のボクが、その紙を信じて同じテストを書いてしまうところだったのだ」

**めたん**「そう。だから `AGENTS.md` §4.4、`ROADMAP.md` フェーズ 3、`TODO.md` B、`build-test.md` を全部『残っているのは `PhaseSet` だけ』に揃えたわ。
`ARCHITECTURE.md` の構成図も動かしたファイルに合わせ、`stripAudio` と書かれていた関数名も本当の `VideoImporter.stripAudioTrack` に直した」

### 2.7　見送ったこと

**ずんだもん**「直さなかったところも教えるのだ」

**めたん**「4 つ。理由つきで」

1. **相手のクリップへ `partner.video = newValue` とまとめて代入する案**。行は減るけれど、相手が ★ ベストのスイングのとき自身の位置合わせを消してしまう。危ないので据え置き、代わりに理由をコメントにした
2. **カプセル状のボタン（フェーズジャンプ・候補・±コマ・速度）のスタイル統一**。余白が 5pt と 6pt で違うなど見た目が変わる。リファクタで見た目を変えない
3. **`VideoError` を独立ファイルに**。macOS の解析 CLI がコンパイルするファイルを名前で列挙しているので、増やすとそちらも直す必要がある。得るものより手間が多い
4. **一覧の行とステージのメニュー（もう一度解析 / 名前 / 削除）の共通化**。★ の有無と閉じる動作が違い、共通化すると分岐が増える

---

## 第 3 幕　採点

**ずんだもん**「で、何点が何点になったのだ？」

**めたん**「前回と同じ 7 つの観点で、わたくしの自己採点よ。前回の『後』は 7.6 だったけれど、そのあと機能（クリップ・ジョグホイール・写真ライブラリの取り込み）が
増えて、型の同居とドキュメントのずれが生まれていたから、今回の『前』はそれより少し低い 7.3 から始まるわ」

| 観点             | 前  | 後  | 根拠                                                                                                                       |
| ---------------- | --- | --- | -------------------------------------------------------------------------------------------------------------------------- |
| 構造・配置       | 7   | 9   | 画面別フォルダは前回で整っていた。今回は同居ファイル 13 → 9、View の中の Service を `Services/` へ。残：`Models/Clip.swift` の 5 型は保存形式として同居させたまま |
| 重複             | 7   | 8   | 1 行の重複 5 種（Optional の表示判定・サムネイル時刻・位置合わせのリセット・URL・memberwise init）を解消。残：行とステージのメニュー、解析中のオーバーレイ |
| 簡潔さ           | 7   | 8   | 基準の Binding、フッターの添字、`Pairing` の init が消えた。ただし行数は ±0 で、部品が増えた分だけ「どこにあるか」を知る必要はある |
| 命名             | 8   | 9   | `PhotoLibrary` が 1 語に、`PickerTab` → `VideoPickerSheet.Tab`、`videoURL(of: clip)`。残：`VideoImporter` は撮影日時と音声除去も担い、名前より広い |
| 一貫性           | 7   | 9   | Optional → `isPresented` が 1 方式、サムネイル時刻が 1 方式、独自 init は extension に置く流儀で `Pairing` と `SyncEngine` が揃った |
| コメント         | 8   | 9   | 推測の削除、NOTE と TODO の使い分け、実態とずれた 1 文、読んでも分からない理由 1 つ。元から良く、伸び幅は小さい                 |
| テスト・検証     | 7   | 8   | テストは 32 件で前後同じ。ドキュメントが「検出ロジックだけ」と古いままだったのを直した。残：`PhaseSet`（[TODO.md](../TODO.md) B） |
| **総合（平均）** | **7.3** | **8.6** |                                                                                                                    |

**ずんだもん**「前回は 5.9 → 7.6 で、今回は 7.3 → 8.6 なのだ。伸びが小さいのだ」

**めたん**「土台が良くなるほど、1 回のリファクタで動く幅は小さくなるものよ。今回の価値は点数より、**古い宿題の紙を剥がした**ことと、
**ファイル名と型名が一致する**ようになったこと。どちらも、1 年後に読む人が迷う時間を減らすものだわ」

---

## 第 4 幕　残った宿題

**ずんだもん**「次に来た人がやることは何なのだ？」

1. **`PhaseSet.sanitize / assign / fallback` のテスト**（[TODO.md](../TODO.md) B）。純関数なので書くのは簡単。今回の唯一の未整備
2. **E2E は回していない**。画面構成も識別子も変えていないので壊れていないはずだが、確認はしていない（[TODO.md](../TODO.md) G と同じ状態）
3. **`Views/Stage/` が 10 ファイル**。まだ一覧できる範囲。再生まわり（`ControlPanel` / `SeekBar` / `TransportControls` / `JogWheel` / `JogRotation`）が増えるなら `Stage/Playback/` に分ける
4. **`xcodebuild` が `project.pbxproj` のセクション順を並べ替える**件は前回と同じ。今回も HEAD の内容に戻してある

---

## 検証したこと

- iOS シミュレータ向けビルド（iPhone 16e）：成功、警告なし
- 単体テスト `SwingDuetTests`：32 件 pass（前後とも）
- macOS 用 CLI `build/analyze-swing`：ビルド成功（`Models/` を変えたので、アプリ外でも成立することの確認）
- 画面の見た目は変えていない（余白・文言・識別子は前後で同じ）。E2E は未実施

**ずんだもん**「行数が同じでも、開いたファイルに知らない型がいなくて、宿題の紙が本当のことを言っている。それが今回の成果なのだ」

**めたん**「1 年後のあなたが、ドキュメントを信じてよかったと思えることを祈っているわ」
