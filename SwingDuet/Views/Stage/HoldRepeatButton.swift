import SwiftUI

/// 押した瞬間に反応し、指を離すまで押下を伝えるボタン（コマ送りの長押しのように、押している間だけ何かを続けるための部品）。
///
/// `Button` は指を離したときに action を呼ぶので、押している間に進めた分と二重になってしまう。
/// そのため Button は使わず、押下を `DragGesture(minimumDistance: 0)` で見る。`@GestureState` はジェスチャが
/// 途中で中断されたとき（着信・バックグラウンド移行など）も初期値に戻るので、離した通知が漏れて続けっぱなしになることはない。
/// VoiceOver 等の支援技術からは押しっぱなしができないので、1 回分の操作を `action` として別に受ける
struct HoldRepeatButton<Label: View>: View {
    /// 押した瞬間
    let onPress: () -> Void
    /// 指が離れた（または中断された）瞬間
    let onRelease: () -> Void
    /// 支援技術から操作されたときの 1 回分
    let action: () -> Void
    @ViewBuilder let label: () -> Label

    @GestureState private var isPressed = false

    var body: some View {
        label()
            .opacity(isPressed ? 0.5 : 1)
            .frame(minWidth: 44, minHeight: 44)   // タッチ領域
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .updating($isPressed) { _, pressed, _ in pressed = true }
            )
            .onChange(of: isPressed) { _, pressed in
                pressed ? onPress() : onRelease()
            }
            // アイコンではなくこの View を 1 つのボタン要素として読ませる（ラベルは使う側が付ける）
            .accessibilityElement(children: .ignore)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { action() }
    }
}
