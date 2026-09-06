# 動画を「コピーして持つ」か「写真ライブラリを参照する」か

**作成日時**: 2026-09-07 03:16 JST
**対象**: `SwingDuet/Services/VideoImporter.swift`（PhotosPicker からの受け取り）、`SwingDuet/Services/ProjectStore.swift`
（`Documents/Videos/` へのコピー・削除・複製）
**目的**: このアプリは動画を読むだけで編集もトリミングもしない。それでも取り込んだ動画を自分の領域へコピーして持つのが定石なのか、
写真ライブラリを参照するだけにできないのかを、Apple の設計と他アプリの実例から整理する
**種別**: 調査（コード・設定は変更していない）

---

## 1. 結論

- **iOS のサードパーティアプリではコピーが定石。** 理由は「参照だけ」が成立する仕組みが Apple の枠組みに無いから。
  権限不要の `PhotosPicker` が渡すのは一時ファイルで、完了ハンドラを抜けると消える。持ち続けたければコピーするしかない（§3.1）
- 参照モデルに相当するのは **PhotoKit の識別子を保存する方式**で、これは「写真ライブラリの読み取り権限」と同義。
  権限ダイアログ、限定アクセス（識別子で取れない）、iCloud に退避された動画のダウンロード、ユーザーが写真を消したときの欠損、
  バックアップ復元で識別子が変わる問題がまとめて付いてくる（§3.2）
- 実例も同じ。LumaFusion と Final Cut Pro for iPad は Photos から取り込むとコピーし、Final Cut Pro（Mac）も既定はライブラリへコピー。
  参照しているのは Apple 純正の iMovie（iPhone）で、これはフル権限を前提にできる立場の例（§4）
- このアプリの要件（権限なし・オフラインで履歴が必ず開く・YouTube 由来のお手本）では**コピー所有が筋**。
  「消す」「複製する」はコピー所有の帰結で、複製は削除の単純化のための割り切りにすぎず、参照確認に置き換えられる（§5.4）
- 参照モデルへ切り替える動機になりうるのは 240fps 原本の容量（1 スイング 40〜80MB）だが、
  原本の取得（[TODO.md](../TODO.md) A）は PhotoKit で取り出して**コピーする**形でも成立し、
  容量はスイング区間だけ切り出せば解決する。これはコピー所有だからできる（§5.1、§6）

---

## 2. 2 つのモデル

| 観点 | コピー所有（現状） | 参照（PhotoKit 識別子を保存） |
| ---- | ------------------ | ----------------------------- |
| 写真ライブラリの権限 | 不要（`PhotosPicker` は別プロセス） | **必須**。拒否・限定アクセスの UI と再要求の流れが要る |
| 取り込み後に写真アプリで元を消す | 影響なし | 比較が開けなくなる。欠損の表示と復旧手段が要る |
| iCloud 写真の「ストレージを最適化」 | 影響なし（自分のコピーがある） | 端末に無ければ再生前にダウンロード。オフラインでは開けない |
| バックアップからの復元 | 影響なし | `localIdentifier` が変わる。`PHCloudIdentifier` で保存し直す必要 |
| 限定アクセス（「写真を選択」） | 影響なし | 識別子で `PHAsset` を取れない。結局コピー経路へのフォールバックが要る |
| 写真アプリ以外の入力（ファイル App・AirDrop） | 同じ経路 | 扱えない、またはコピー経路を別に持つ |
| 容量 | 写真ライブラリと二重 | 二重にならない |
| 「消す」「複製」の概念 | 要る（削除時に参照確認、または複製） | 不要（JSON だけ消す） |
| 240fps 原本（TODO A） | PhotoKit で取り出してコピー | PhotoKit で毎回取り出す |
| 音声トラックの除去（[research/260907_0254](./260907_0254-model-video-stutter-on-device.md) §8） | 取り込み時に落とせる（B） | ファイルを触れないので再生時の合成（A'）になる |
| 実装経路 | 1 本 | 参照 + コピーのフォールバックで 2 本 |

---

## 3. Apple の設計（根拠）

### 3.1 PhotosPicker は「渡して終わり」

- Apple の PhotoKit のプライバシーガイドは、読むだけのアプリには `PHPickerViewController` を勧め、
  「retrieving assets and collections, or updating the library」のような PhotoKit の機能を使うなら「the user must explicitly authorize it」と明記している
  （[Delivering an enhanced privacy experience in your Photos app](https://developer.apple.com/documentation/photokit/delivering-an-enhanced-privacy-experience-in-your-photos-app)）
- WWDC20「Meet the new Photos picker」: 渡される一時ファイルは完了ハンドラから戻ると消えるので、
  アプリが管理する場所へコピーしてから戻ること（[WWDC Notes](https://wwdcnotes.com/documentation/wwdc20-10652-meet-the-new-photos-picker/)）。
  今の `ImportedMovie`（`FileRepresentation` の importing クロージャで `copyItem`）はこの指示どおり
- `PhotosPickerItem.itemIdentifier` は「This value is nil if you create a Photos picker without a photo library」
  （[Apple Developer Documentation](https://developer.apple.com/documentation/photosui/photospickeritem/itemidentifier)）。
  つまり参照の手掛かり（識別子）を得ること自体が `photoLibrary: .shared()` ＝ ライブラリ権限の前提
- 限定アクセスでは識別子があっても `PHAsset` を取れない。Apple のエンジニアの回答:
  「In this case, the asset data is only accessible through the item provider, not the asset identifier.」
  （[Apple Developer Forums #759040](https://developer.apple.com/forums/thread/759040)）

### 3.2 PhotoKit の参照は「取れないことがある」前提

- `PHImageManager.requestAVAsset` は再生用の `AVAsset` を返す。動画が iCloud に退避されていると
  `PHVideoRequestOptions.isNetworkAccessAllowed = true` でダウンロードしないと nil になる
  （[isNetworkAccessAllowed](https://developer.apple.com/documentation/photos/phimagerequestoptions/isnetworkaccessallowed)、
  [Apple Developer Forums #98669](https://forums.developer.apple.com/thread/98669)）
- `localIdentifier` はバックアップ復元で変わり、保存した識別子で fetch しても何も返らない。Apple のエンジニアは
  「Use PHCloudIdentifier everywhere」と `cloudIdentifiers(forLocalIdentifiers:)` での変換を案内している
  （[Apple Developer Forums #105366](https://developer.apple.com/forums/thread/105366)）
- `requestAVAsset` が返す URL はサンドボックス外（写真ライブラリ内）で、iOS 18 では末尾に余分な文字列が付く報告もある。
  永続化に使うものではない（[Medium: iOS 18 PHAsset URL from requestAVAsset](https://medium.com/@mi9nxi/ios-18-phasset-url-from-requestavasset-09c67fd069f1)）

### 3.3 PhotosPicker 経路の副作用（既知）

スローモーション動画は `PhotosPicker` が渡す時点で 30fps のレンダリング版に再エンコードされ、実時間ほどの時間がかかる
（[Apple Developer Forums #693127](https://developer.apple.com/forums/thread/693127)、
本リポジトリの実測は [research/260906_1723](./260906_1723-slow-motion-speed-detection.md) §3.3）。
原本が要る TODO A は、コピー所有・参照のどちらでも PhotoKit（ライブラリ権限）が要る。

---

## 4. 他のアプリはどうしているか

| アプリ | 方式 | 根拠 |
| ------ | ---- | ---- |
| LumaFusion（iOS 動画編集） | **コピー**。Photos から取り込むとコピーし、写真アプリで消しても残る | [Luma Touch ナレッジベース](https://luma-touch.helpscoutdocs.com/category/4-importing-media-and-library)（Importing） |
| Final Cut Pro for iPad | **コピー**。「Imported media files are copied from their original locations and stored on your iPad.」 | [Apple サポート](https://support.apple.com/guide/final-cut-pro-ipad/dev6887d080d/ipados) |
| Final Cut Pro（Mac） | 既定はライブラリへコピー（managed media）。「Leave files in place」は選択肢 | [Larry Jordan: Where Does Final Cut Pro X Store Media?](https://larryjordan.com/articles/where-does-final-cut-pro-x-store-media/) |
| iMovie（iPhone） | **参照**。Photos のクリップはプロジェクトから参照され、プロジェクトを消しても写真ライブラリに残る | [Apple サポート](https://support.apple.com/guide/imovie-iphone/work-with-projects-knaafa21fc0e/ios)、[Macworld](https://www.macworld.com/article/230515/how-to-safely-clean-imovie-files-from-iphone-or-ipad.html) |
| OnForm / V1 Golf（スイング解析） | 自前ストレージ（端末＋クラウド）に取り込む。無料枠の容量制限あり | [Onform](https://onform.com/sports/golf/)、[Golf Insider](https://golfinsideruk.com/best-golf-swing-analyzer-app/) |

サードパーティの動画アプリは、Mac のプロ用ツールも含めてコピーが既定。参照しているのは Apple 純正で、
写真ライブラリを自分のものとして扱える立場（権限・iCloud 連携・欠損時の再ダウンロード UI を全部持っている）の例と読むのが妥当。

---

## 5. このアプリでの検討

### 5.1 容量の見積り

| 動画 | 大きさ | 100 スイング分 |
| ---- | ------ | -------------- |
| Golfboy 書き出し（1440×1080、30fps、4 秒） | 2.2MB | 0.2GB |
| YouTube Shorts（640×640、7 秒） | 0.5MB | 0.05GB |
| iPhone スロー原本（1080p・240fps・HEVC、5〜10 秒） | 40〜80MB（480MB/分。[iDownloadBlog](https://www.idownloadblog.com/2017/11/22/how-to-shoot-slo-mo-video-1080p-at-240fps-iphone/)） | 4〜8GB |

今の入力（30fps）では問題にならない。TODO A で原本が入るとコピーの二重化が効いてくるが、
スイングは撮影 10 秒のうち 2〜3 秒なので、**取り込み時にスイング区間の前後だけを切り出せば**（パススルー書き出しは
[research/260907_0254](./260907_0254-model-video-stutter-on-device.md) §8 で数十 ms と実測）1 本 10〜25MB に収まる。
参照モデルでは切り出せない（写真ライブラリのファイルは触れない）ので、容量対策はむしろコピー所有の方が打てる。

なお `ProjectStore.duplicate` の APFS クローンは端末上では容量を食わないが、iCloud はクローンを保持しないという報告がある
（[The Eclectic Light Company](https://eclecticlight.co/2025/04/07/how-robust-are-apfs-clone-and-sparse-files/)）。
バックアップ上で二重になる可能性はコピー所有の弱点として残る（複製をやめれば消える。§5.4）。

### 5.2 参照モデルへ切り替えると必要になるもの

1. ライブラリ権限の要求と、拒否・限定アクセス時の UI（[AGENTS.md](../AGENTS.md) §6.3 の設計が先）
2. 限定アクセスでは識別子で取れないので、コピー経路へのフォールバック（＝コピー経路は残る）
3. iCloud 退避時のダウンロード待ち UI、オフライン時のエラー
4. 写真アプリで消された・復元で識別子が変わったときの欠損表示と、`PHCloudIdentifier` での保存
5. YouTube 等のお手本は「写真アプリに保存してから選ぶ」前提を仕様に書く
6. 音声トラックの除去は再生時の合成（A'）に変える

つまり参照モデルは「コピー経路 + 参照経路 + 欠損処理」で、今より経路が増える。

### 5.3 ハイブリッド（写真の原本は参照、それ以外はコピー）

TODO A と容量の両方に効くが、5.2 の 1〜4 はそのまま必要で、動画の出どころごとに再生・解析・サムネイルの読み方が分かれる。
利点が容量だけなら、5.1 の切り出しで足りる。

### 5.4 コピー所有を保つ場合の整理

コピー所有の中でも、今の「持ち主ごとに複製」は必須ではない（ファイルは取り込み後に書き換えないので共有できる）。

- 削除時に「その fileName を他の比較・登録済みお手本が使っていないか」を `projects` / `models` から確認して消す
- 起動時に `Documents/Videos/` を走査し、どの JSON からも参照されないファイルを消す（片ペインに入れただけで終了した動画の取り残しも片付く）
- `ProjectStore.duplicate` と `SlotSource` の「取り込んだばかり / 他の持ち主」の区別を廃止

「消す」という操作は残るが、`ProjectStore` の 2 つのメソッドに閉じる。

---

## 6. 推奨

**コピー所有を続ける。** 定石どおりで、権限なし・オフラインで履歴が必ず開く・お手本が YouTube 由来という要件に合い、実装経路が 1 本で済む。

- TODO A（240fps 原本）は「PhotoKit で `PHAssetResource`（`.video`）を取り出して `Documents/Videos/` へコピー」で実装する。
  参照へ切り替える必要はない。権限は「原本が欲しいときだけ」求め、拒否されれば今の PhotosPicker 経路（30fps）に戻す
- 容量は取り込み時のスイング区間の切り出し（パススルー）で抑える。解析でスイング区間は分かっている
- 複製は廃止し、削除は参照確認 + 起動時の孤児掃除にする（§5.4）。音声トラックの除去は取り込み時（B 案）で行う

参照モデルへ行く判断になるのは、アプリが「写真ライブラリの中のスイングを一覧して選ぶ」ギャラリー型になるとき。
その場合はどのみちフル権限が前提になるので、参照が自然になる。

---

## 参照

- [Delivering an enhanced privacy experience in your Photos app — Apple Developer Documentation](https://developer.apple.com/documentation/photokit/delivering-an-enhanced-privacy-experience-in-your-photos-app)
- [PhotosPickerItem.itemIdentifier — Apple Developer Documentation](https://developer.apple.com/documentation/photosui/photospickeritem/itemidentifier)
- [Meet the new Photos picker (WWDC20) — WWDC Notes](https://wwdcnotes.com/documentation/wwdc20-10652-meet-the-new-photos-picker/)
- [PHPickerViewController in Limited Access photos mode — Apple Developer Forums](https://developer.apple.com/forums/thread/759040)
- [PHObject localIdentifier not persistent between backup restores — Apple Developer Forums](https://developer.apple.com/forums/thread/105366)
- [isNetworkAccessAllowed — Apple Developer Documentation](https://developer.apple.com/documentation/photos/phimagerequestoptions/isnetworkaccessallowed)
- [requestAVAssetForVideo returns AVAsset==nil while networkAccessAllowed=true — Apple Developer Forums](https://forums.developer.apple.com/thread/98669)
- [Slow-mo videos take a long time for loadFileRepresentation — Apple Developer Forums](https://developer.apple.com/forums/thread/693127)
- [iOS 18 PHAsset URL from requestAVAsset — Medium](https://medium.com/@mi9nxi/ios-18-phasset-url-from-requestavasset-09c67fd069f1)
- [Importing — Luma Touch Knowledge Base](https://luma-touch.helpscoutdocs.com/category/4-importing-media-and-library)
- [Import media into Final Cut Pro for iPad — Apple サポート](https://support.apple.com/guide/final-cut-pro-ipad/dev6887d080d/ipados)
- [Where Does Final Cut Pro X Store Media? — Larry Jordan](https://larryjordan.com/articles/where-does-final-cut-pro-x-store-media/)
- [Work with projects in iMovie on iPhone — Apple サポート](https://support.apple.com/guide/imovie-iphone/work-with-projects-knaafa21fc0e/ios)
- [How to free up iPhone storage space by cleaning out iMovie files — Macworld](https://www.macworld.com/article/230515/how-to-safely-clean-imovie-files-from-iphone-or-ipad.html)
- [Golf Video Analysis App — Onform](https://onform.com/sports/golf/)
- [The 5 Best Golf Swing Analyzer Apps — Golf Insider](https://golfinsideruk.com/best-golf-swing-analyzer-app/)
- [How to record 1080p/240 fps video on iPhone — iDownloadBlog](https://www.idownloadblog.com/2017/11/22/how-to-shoot-slo-mo-video-1080p-at-240fps-iphone/)
- [How robust are APFS clone and sparse files? — The Eclectic Light Company](https://eclecticlight.co/2025/04/07/how-robust-are-apfs-clone-and-sparse-files/)
