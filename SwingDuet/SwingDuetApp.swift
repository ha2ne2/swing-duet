import SwiftUI

@main
struct SwingDuetApp: App {
    @StateObject private var store = ClipStore()

    var body: some Scene {
        WindowGroup {
            SwingListView()
                .environmentObject(store)
                .preferredColorScheme(.dark)
        }
    }
}
