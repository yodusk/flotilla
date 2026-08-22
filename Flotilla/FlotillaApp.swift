import SwiftUI
import SwiftData

@main
struct FlotillaApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(for: [Repo.self, Worktree.self, Chat.self])
        .windowStyle(.titleBar)
    }
}
