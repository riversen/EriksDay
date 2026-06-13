import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject private var store: FolderStore
    @Environment(\.scenePhase) private var scenePhase
    @State private var showingImporter = false

    var body: some View {
        NavigationStack {
            Group {
                if store.hasFolder {
                    LogView()
                } else {
                    folderPrompt
                }
            }
            .navigationTitle("Erik's Day")
            .toolbar {
                if store.hasFolder {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            store.reload()
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                }
            }
        }
        .fileImporter(isPresented: $showingImporter, allowedContentTypes: [.folder]) { result in
            switch result {
            case .success(let url): store.setFolder(url)
            case .failure(let error): store.lastError = error.localizedDescription
            }
        }
        // Pull fresh files when returning to the app. A file presenter would
        // give live updates; this is enough for the first iteration.
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { store.reload() }
        }
        .alert("Something went wrong",
               isPresented: Binding(get: { store.lastError != nil },
                                    set: { if !$0 { store.lastError = nil } })) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(store.lastError ?? "")
        }
    }

    private var folderPrompt: some View {
        ContentUnavailableView {
            Label("Choose your shared folder", systemImage: "folder.badge.person.crop")
        } description: {
            Text("Pick the iCloud Drive folder you shared with family. Everyone selects the same folder on their own device.")
        } actions: {
            Button("Choose Folder") { showingImporter = true }
                .buttonStyle(.borderedProminent)
        }
    }
}
