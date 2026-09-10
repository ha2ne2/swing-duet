import SwiftUI

/// 比較画面の下段の操作パネル：基準の切り替え・共通シークバー・再生操作。
/// 比較前のステージも同じ View を（`PlaybackController.placeholder` で）飾りとして出し、両ペインがそろった瞬間に高さが変わらないようにする
struct ControlPanelView: View {
    let controller: PlaybackController
    @Binding var reference: VideoSide

    var body: some View {
        VStack(spacing: 8) {
            ReferencePicker(reference: $reference)
                .padding(.horizontal)

            SeekBarView(controller: controller)
                .padding(.horizontal)

            TransportControlsView(controller: controller)
                .padding(.horizontal)
                .padding(.bottom, 6)
        }
    }
}

/// 同期の基準（自分基準 / お手本基準）の切り替え。行の右端に置く
private struct ReferencePicker: View {
    @Binding var reference: VideoSide

    var body: some View {
        Picker("基準", selection: $reference) {
            ForEach(VideoSide.allCases) { side in
                Text("\(side.label)基準").tag(side)
            }
        }
        .pickerStyle(.segmented)
        .frame(width: 170)
        .frame(maxWidth: .infinity, alignment: .trailing)
    }
}
