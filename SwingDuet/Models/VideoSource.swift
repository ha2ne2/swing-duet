import Foundation

/// クリップの動画の出どころ（設計は docs/design/260912_2011-photo-library-reference-storage.md）
enum VideoSource: Hashable {
    /// アプリ内のコピー（Documents/Videos/<fileName>）。権限が無いときの OS ピッカー経由と、参照にする前に取り込んだもの
    case file(String)
    /// 写真ライブラリの動画。`localID` は `PHAsset.localIdentifier`、`cloudID` はバックアップの復元で識別子が変わったときに引き直す `PHCloudIdentifier`
    case library(localID: String, cloudID: String?)

    /// 保存する形に分ける（`VideoConfig.fileName` / `Clip.assetID` / `Clip.cloudID`。参照は `fileName` が空）
    var stored: (fileName: String, assetID: String?, cloudID: String?) {
        switch self {
        case .file(let fileName): return (fileName, nil, nil)
        case .library(let localID, let cloudID): return ("", localID, cloudID)
        }
    }
}
