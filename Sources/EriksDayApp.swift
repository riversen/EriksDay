import SwiftUI

@main
struct EriksDayApp: App {
    @StateObject private var store = FolderStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
        }
    }
}
