import SwiftUI

extension View {
    /// クリップに名前を付ける（変更する）アラート。`clip` が nil でない間だけ出す。空にすると日時表示に戻る
    func renameAlert(_ clip: Binding<Clip?>) -> some View {
        modifier(RenameAlert(clip: clip))
    }

    /// 動画を使えなかったときのアラート。`message` が nil でない間だけ出し、閉じると nil に戻す
    func errorAlert(_ message: Binding<String?>) -> some View {
        alert("動画を使えませんでした", isPresented: Binding(get: { message.wrappedValue != nil }, set: { if !$0 { message.wrappedValue = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(message.wrappedValue ?? "")
        }
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
            .alert("名前を付ける", isPresented: Binding(get: { clip != nil }, set: { if !$0 { clip = nil } }), presenting: clip) { target in
                TextField("名前", text: $name)
                Button("保存") { store.rename(target.id, to: name) }
                Button("キャンセル", role: .cancel) {}
            }
    }
}
