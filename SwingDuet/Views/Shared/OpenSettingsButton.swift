import SwiftUI

/// 権限を拒否されたときの「設定を開く」。押すと設定アプリのこのアプリのページが開く。
/// NOTE: `SettingsLink` は macOS 専用なので使えない
struct OpenSettingsButton: View {
    @Environment(\.openURL) private var openURL
    /// 横いっぱいに広げる（縦に並ぶ他のボタンと幅をそろえるとき）。
    /// NOTE: 幅は label の内側で決める。ボタンの外側で広げると、`borderedProminent` の地は固有の幅のまま中央に置かれる
    var fillsWidth = false

    var body: some View {
        Button {
            if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
        } label: {
            if fillsWidth {
                Text("設定を開く")
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
            } else {
                Text("設定を開く")
            }
        }
    }
}
