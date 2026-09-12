import SwiftUI
import UIKit

/// 横スワイプで前の画面へ戻る `NavigationStack` のジェスチャを、この View が画面にある間だけ止める（戻るのは左上の「<」で）。
///
/// ステージで使う：ループ範囲の開始のつまみは画面の左端から 16pt に立つことがあり、そこから右へなぞる指を戻るスワイプが先に取る。
/// SwiftUI に止める API は無いので、ウインドウに付いたときに応答チェーン（`UIResponder.next`）で `UINavigationController` を見つけ
/// （`NavigationStack` の中身はこれに載っている）、戻るジェスチャの認識器を無効にする。外れたら元に戻す。見つからなければ何もしない。
/// 認識器は左端の `interactivePopGestureRecognizer` と、iOS 26 からの画面全体の `interactiveContentPopGestureRecognizer` の 2 つ。
/// 後者は「前者が受け持たない場合」に働くので、左端の方だけ止めると左端のスワイプまで後者が拾う（実機で確認）
struct InteractivePopGestureBlocker: UIViewRepresentable {
    func makeUIView(context: Context) -> BlockerView {
        let view = BlockerView()
        view.isUserInteractionEnabled = false   // 当たりを持たない（重ねた SwiftUI のジェスチャに影響させない）
        return view
    }

    func updateUIView(_ uiView: BlockerView, context: Context) {}

    final class BlockerView: UIView {
        /// いま無効にしている戻るジェスチャ（元に戻すために持つ）
        private var blocked: [UIGestureRecognizer] = []

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window != nil {
                guard blocked.isEmpty,
                      let navigation = sequence(first: self as UIResponder, next: \.next)
                          .lazy.compactMap({ $0 as? UINavigationController }).first
                else { return }
                var gestures = [navigation.interactivePopGestureRecognizer]
                if #available(iOS 26.0, *) {
                    gestures.append(navigation.interactiveContentPopGestureRecognizer)
                }
                blocked = gestures.compactMap { $0 }.filter(\.isEnabled)
                blocked.forEach { $0.isEnabled = false }
            } else {
                blocked.forEach { $0.isEnabled = true }
                blocked = []
            }
        }
    }
}
