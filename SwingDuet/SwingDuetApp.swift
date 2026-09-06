import SwiftUI

@main
struct SwingDuetApp: App {
    @StateObject private var store = ProjectStore()

    var body: some Scene {
        WindowGroup {
            StageView()
                .environmentObject(store)
                .preferredColorScheme(.dark)
        }
    }
}
