import SwiftUI

@main
struct EriksDayApp: App {
    @StateObject private var store = FolderStore()
    @StateObject private var language = AppLanguage()
    @StateObject private var lock = AppLock()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .environmentObject(language)
                .environmentObject(lock)
        }
    }
}
