import SwiftUI

@main
struct SwingDuetApp: App {
    @StateObject private var store = ClipStore()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            SwingListView()
                .environmentObject(store)
                .preferredColorScheme(.dark)
                .onChange(of: scenePhase) { _, phase in
                    // 背景に回ると次に起きられるとは限らないので、待たせている保存をここで書き切る
                    if phase != .active { store.flushPendingWrites() }
                }
        }
    }
}
