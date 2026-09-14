import SwiftUI

/// 下端に数秒だけ出す帯（撮影の結果・削除の取り消し）。`id` が変わると消えるまでの時間を数え直す
struct BottomBanner<ID: Equatable>: View {
    let text: String
    let actionTitle: String
    /// 消えるまでの時間
    let dismissAfter: Duration
    /// 数え直しの単位（同じ帯の中身が入れ替わったとき）
    let id: ID
    /// ボタンを押したとき
    let action: () -> Void
    /// 押されずに消えたとき。省略すると押したときと同じ（「元に戻す」のように後始末が違う帯があるので分けられる）
    var onTimeout: (() -> Void)?

    var body: some View {
        HStack {
            Text(text)
                .font(.subheadline)
            Spacer()
            Button(actionTitle, action: action)
                .bold()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal, 16)
        .task(id: id) {
            try? await Task.sleep(for: dismissAfter)
            if !Task.isCancelled { (onTimeout ?? action)() }
        }
    }
}
