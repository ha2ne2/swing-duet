import SwiftUI

/// 比較画面の下段の操作パネル：同期のとり方の切り替え・共通シークバー・再生操作。
/// 比較前のステージも同じ View を（`PlaybackController.placeholder` で）飾りとして出し、両ペインがそろった瞬間に高さが変わらないようにする
struct ControlPanelView: View {
    @Bindable var controller: PlaybackController

    var body: some View {
        VStack(spacing: 8) {
            SyncBasisPicker(basis: $controller.syncBasis)
                .padding(.horizontal)

            SeekBarView(controller: controller)
                .padding(.horizontal)

            TransportControlsView(controller: controller)
                .padding(.horizontal)
                .padding(.bottom, 6)
        }
    }
}

/// 同期のとり方（自分基準 / お手本基準 / 同期しない）の切り替え。行の右端に置く
private struct SyncBasisPicker: View {
    @Binding var basis: SyncBasis

    var body: some View {
        Picker("同期", selection: $basis) {
            ForEach(SyncBasis.allCases) { basis in
                Text(basis.label).tag(basis)
            }
        }
        .pickerStyle(.segmented)
        .frame(width: 260)
        .frame(maxWidth: .infinity, alignment: .trailing)
    }
}
