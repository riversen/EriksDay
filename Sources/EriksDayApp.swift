import SwiftUI

@main
struct EriksDayApp: App {
    @StateObject private var store = FolderStore()
    @StateObject private var language = AppLanguage()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
                .environmentObject(language)
        }
    }
}
