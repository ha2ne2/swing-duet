# 動画を写真ライブラリの参照で持つ（アプリ内へのコピーをやめる）

- 日付：2026-09-12
- 種別：設計 → 実装（[design/260912_1951](./260912_1951-in-app-slowmo-capture-and-shot-split.md) §8 の 7 で決定）
- 対象：`Models/Clip.swift`、`Services/ClipStore.swift`（取り込み・読み出しの窓口・削除）、`Services/SwingAnalyzer.swift`（`analyze(asset:)`）、
  動画を読む View（`VideoThumbnail`、`ComparisonView` / `PlaybackController`、`PhaseEditView`、`StageView` の `SlotPane`）、`Services/PhotoLibrary.swift`
- 前提：コピーを選んだ調査 [research/260907_0316](../research/260907_0316-copy-vs-reference-video-storage.md)。その「参照へ行く判断になる条件」
  （写真ライブラリを一覧して選ぶギャラリー型で、フル権限が前提）が 2026-09-11 の「動画」タブでそろい、撮ったショットを写真ライブラリに残す決定で二重の容量が問題になった

## 1. 決めたこと

| 項目 | 決定 |
| --- | --- |
| 写真ライブラリから来た動画（「動画」タブで選んだもの、切り出したショット） | **参照**。`PHAsset` の識別子を持ち、読むたびに `requestAVAsset(version: .original)` で原本を取る。ファイルはコピーしない |
| 権限が無いときの OS ピッカー（`PhotosPicker`）経由 | 今までどおり `Documents/Videos/` へ**コピー**（一時ファイルしか渡されないため） |
| 既存のコピー済みクリップ | そのまま（ファイルで読み続ける）。写真ライブラリへ書き戻さない |
| 切り出したショット（長い動画の分割・撮影） | 一時ファイルに切り出し → 写真ライブラリに保存（アルバム「SwingDuet」）→ その識別子で参照。保存できなければコピーに落とす |
| 音声 | 参照はファイルを触れないので、**再生時**に映像トラックだけの `AVMutableComposition` にする（コピーは今までどおり取り込み時に落とす）。解析は原本をそのまま読む |
| アプリで消す | 記録だけ消す。写真ライブラリの動画は残る（コピーのファイルは今までどおり起動時の孤児掃除で消える） |
| 写真アプリで消された・iCloud にしか無い | 欠損として見せる（§5）。取り込み時に `PHCloudIdentifier` も保存し、復元で識別子が変わっても引き直す |

## 2. データ

`Clip` に動画の出どころを持たせる。保存形式は旧キーを残し、旧ビルド（本流と atelier が同じ iPhone に入れ替わりで入る）でも JSON が読めるようにする。

```swift
/// 動画の出どころ
enum VideoSource: Equatable {
    /// アプリ内のコピー（Documents/Videos/<fileName>）
    case file(String)
    /// 写真ライブラリの動画（PHAsset.localIdentifier。cloudID は復元で識別子が変わったときの引き直し用）
    case library(localID: String, cloudID: String?)
}
```

- 保存：`video.fileName` は残す（参照のときは空文字）。`assetID` は今までどおり `localIdentifier`。**`fileName` が空なら参照**。`cloudID` を新しいキーで足す
- 旧データ：`fileName` が入っているので `.file`。`cloudID` は無ければ nil
- 旧ビルドで新データを読んだとき：`fileName` が空のクリップはファイルが見つからず解析失敗・サムネイル無しになるが、JSON は読めるので他のクリップは無事
- `Library.currentVersion` は変えない（組み替えは要らない）

## 3. 読み出しの窓口

`ClipStore.videoAsset(of clip: Clip) async throws -> AVAsset` を唯一の窓口にし、View と解析は URL ではなく `AVAsset` を受け取る。

- `.file` → `AVURLAsset(url:)`
- `.library` → `PHAsset.fetchAssets(withLocalIdentifiers:)`。無ければ `cloudID` から `localIdentifierMappings(for:)` で引き直して `assetID` を更新。
  取れた `PHAsset` を `PHImageManager.requestAVAsset(version: .original, isNetworkAccessAllowed: true)` で `AVAsset` に（`LibraryPreviewView` が既に同じことをしている）
- 再生用は `ClipStore.playerItem(for asset)`：映像トラックだけの `AVMutableComposition`（`preferredTransform` を写す）。コピーのファイルは音声が無いので合成しなくてよいが、
  分岐を増やさず常に合成する（合成の中身は 1 トラックのパススルーで、再生とシークの重さは変わらない。実機で確かめる）
- 解析（`SwingAnalyzer.analyze(asset:)`）とサムネイル（`AVAssetImageGenerator`）は原本の `AVAsset` をそのまま読む

読み手の変更：

| 読み手 | 今 | 変更後 |
| --- | --- | --- |
| `VideoThumbnail` | `url` | `asset: AVAsset?`（呼び手が `.task` で `videoAsset(of:)` を解く。解けるまで黒） |
| `ComparisonView` → `PlaybackController` | `mineURL` / `modelURL` | `.task` で両方の `AVAsset` を解いてから controller を作る（今も `.task` で遅延生成している） |
| `PhaseEditView` | `videoURL` | `asset: AVAsset` |
| `StageView` の `SlotPane` | `videoURL` | `asset` を `.task` で解く。解けなければ欠損の表示（§5） |
| `ClipStore.analyze` | `videoURL(of:)` | `videoAsset(of:)`。`.file` のときだけ `stripAudioTrack` |

## 4. 取り込みの経路

- 「動画」タブ（権限あり）：`obtain(role:source: .asset)` は原本を書き出さず、`Clip(assetID:, video.fileName: "")` を足すだけになる。同じ動画の重複（`existingClip(assetID:)`）は今までどおり。
  別の役割で同じ動画を持つときの「ファイルの共有」は不要になる（両方が同じ識別子を参照するだけ）
- OS ピッカー（権限なし）：`.file(url)` → `importVideo` でコピー（変えない）
- ショットの切り出し：`AVAssetExportSession`（パススルー）で一時ファイルへ → `PHAssetCreationRequest.creationRequestForAssetFromVideo(atFileURL:)` で
  写真ライブラリへ → `placeholderForCreatedAsset.localIdentifier` を持つ。アルバム「SwingDuet」を無ければ作って入れる。
  写真ライブラリの権限は「動画」タブと同じ `readWrite`（追加も含む）なので新しい権限は要らない。保存に失敗したら `importVideo` でコピーに落とす
- `PhotoLibrary.exportOriginal`（原本の書き出し）は取り込みで使わなくなる。残す用途が無ければ消す

## 5. 欠損とダウンロード

- 写真ライブラリに無い（消された・限定アクセスで外れた）：`videoAsset(of:)` が `VideoError.missingInLibrary` を投げる。
  ステージのペインに「動画が写真ライブラリにありません。一覧の「…」から削除できます」、一覧の行はサムネイル無し。解析待ちなら `failed` にする
- iCloud にしか無い：`requestAVAsset` がダウンロードする。ペインに「iCloud からダウンロード中」を出す（`progressHandler`）。
  電波の無い練習場では古いスイングが開けないことがある。最近撮ったものは端末にある
- 復元で識別子が変わった：`cloudID` から引き直し、直った `assetID` を保存する。`cloudID` も無いものは欠損として扱う

## 6. 削除と上限

- 削除は記録だけ。「元に戻す」は今までどおり（参照は識別子が残っているので戻せる）
- 上限（★ 無しのスイングは 60 本）は [design/260912_1951](./260912_1951-in-app-slowmo-capture-and-shot-split.md) の決定どおり **200 本にし、当日のものは数えない**。
  参照になるので上限で流れても写真ライブラリの動画は残る

## 7. 実装の手順

1. `Clip.source`（`fileName` 空 → 参照）と `cloudID`。`ClipStoreTests` に旧データの読み込み・参照クリップにファイルが無いこと・削除がファイルを消さないこと
2. `ClipStore.videoAsset(of:)` / `playerItem(for:)`、`SwingAnalyzer.analyze(asset:)`（`analyze(url:)` は CLI 用に残す）
3. 読み手を `AVAsset` に（§3 の表）。欠損とダウンロードの表示
4. 「動画」タブの取り込みを参照に。`exportOriginal` の削除
5. 上限 200・当日除外
6. ショットの写真ライブラリへの保存は、長い動画の分割の取り込み（design/260912_1951 第 1 段）で作る

実機で確かめること：参照の再生（合成）でシークが重くならないこと、iCloud の動画のダウンロード、写真アプリで消した後の表示、限定アクセスでの取り込み。

## 8. 更新するドキュメント

[SPEC.md](../SPEC.md) §2.1（取り込み）・§2.5（保存）、[ARCHITECTURE.md](../ARCHITECTURE.md) §2（取り込みの流れ・ファイル表）・§4（音声の扱い）・末尾のコピー理由のリンク、
[README.md](../README.md) の保存の説明、[AGENTS.md](../AGENTS.md) §6.1（データの扱い）。[research/260907_0316](../research/260907_0316-copy-vs-reference-video-storage.md) は経緯として残す。

## 9. やらないこと

- 既存のコピー済みクリップを写真ライブラリへ書き戻すこと
- 写真ライブラリのアルバムをアプリの一覧として使うこと（一覧は `library.json` のまま）
- 限定アクセスの特別扱い（ユーザーが許可した動画とアプリが保存した動画は識別子で取れる。それ以外は欠損として見せる）

## 10. 実装の記録（2026-09-12）

§7 の 1〜5 を実装した（6 のショットの保存は長い動画の分割の取り込みと一緒に）。

- `Clip.source`（`VideoSource`）：`video.fileName` が空で `assetID` があれば `.library`、あれば `.file`。`cloudID` を足した（旧データは nil）。`Library.version` は変えていない
- `ClipStore.videoAsset(of:)` が動画を読む唯一の窓口。参照は `PhotoLibrary.fetchVideo`（`localID` → 無ければ `cloudID` から引き直し、直った識別子を保存）→
  `requestOriginalAsset`（`LibraryPreviewView` から移した）。`exportOriginal` は削除
- 再生は常に `VideoImporter.playerItem(for:)`（映像トラックだけの合成。`stripAudioTrack` と合成の作り方を共有）。解析は `SwingAnalyzer.analyze(asset:)` で原本を読む
- 読み手：`VideoThumbnail` は `AVAsset` を受け、クリップ用に `ClipThumbnail`（`videoAsset(of:)` を解いてから描く）を足した。`ComparisonView` は
  両方の動画を解いてから `PlaybackController(mineItem:modelItem:…)` を作り、解けなければ理由（`VideoError.missingInLibrary` / `unavailable`）と
  「一覧の「…」から削除できます」を出す。`PhaseEditView` は `asset` を受ける
- 上限 200・当日除外（`trimSwings`）。一覧のフッターの文言も
- テスト：`ClipStoreTests` に出どころの判定（保存して読み直し・旧データ）と当日除外を追加。50 件合格
- 実機で未確認：合成での再生とシークの重さ、iCloud の動画のダウンロード、写真アプリで消した後の表示、限定アクセスでの取り込み
