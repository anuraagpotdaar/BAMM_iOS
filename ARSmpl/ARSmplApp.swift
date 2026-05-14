import SwiftUI

@main
struct ARSmplApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .preferredColorScheme(.dark)
                .ignoresSafeArea(edges: .all)
        }
    }
}
