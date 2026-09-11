import SwiftUI

extension View {
    /// クリップに名前を付ける（変更する）アラート。`clip` が nil でない間だけ出す。空にすると日時表示に戻る
    func renameAlert(_ clip: Binding<Clip?>) -> some View {
        modifier(RenameAlert(clip: clip))
    }

    /// 動画を使えなかったときのアラート。`message` が nil でない間だけ出し、閉じると nil に戻す
    func errorAlert(_ message: Binding<String?>) -> some View {
        alert("動画を使えませんでした", isPresented: message.isPresent()) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(message.wrappedValue ?? "")
        }
    }
}

extension Binding {
    /// 「表示する対象」の Optional を、アラートやダイアログの `isPresented` に変える（nil でなければ表示、閉じたら nil に戻す）
    func isPresent<Wrapped>() -> Binding<Bool> where Value == Wrapped? {
        Binding<Bool>(get: { wrappedValue != nil }, set: { if !$0 { wrappedValue = nil } })
    }
}

private struct RenameAlert: ViewModifier {
    @EnvironmentObject private var store: ClipStore
    @Binding var clip: Clip?
    @State private var name = ""

    func body(content: Content) -> some View {
        content
            .onChange(of: clip?.id) { _, _ in
                name = clip?.name ?? ""
            }
            .alert("名前を付ける", isPresented: $clip.isPresent(), presenting: clip) { target in
                TextField("名前", text: $name)
                Button("保存") { store.rename(target.id, to: name) }
                Button("キャンセル", role: .cancel) {}
            }
    }
}
