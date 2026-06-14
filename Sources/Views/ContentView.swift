import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject private var store: FolderStore
    @EnvironmentObject private var language: AppLanguage
    @Environment(\.scenePhase) private var scenePhase
    @State private var showingImporter = false

    private var s: Strings { language.s }

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
                ToolbarItem(placement: .topBarLeading) {
                    LanguageToggle()
                }
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
            // 24-hour clock always; month names/date order follow the language.
            .environment(\.locale, language.current.locale)
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
        .alert(s.errorTitle,
               isPresented: Binding(get: { store.lastError != nil },
                                    set: { if !$0 { store.lastError = nil } })) {
            Button(s.ok, role: .cancel) { }
        } message: {
            Text(store.lastError ?? "")
        }
    }

    private var folderPrompt: some View {
        ContentUnavailableView {
            Label(s.chooseFolderTitle, systemImage: "folder.badge.person.crop")
        } description: {
            Text(s.chooseFolderBody)
        } actions: {
            Button(s.chooseFolderButton) { showingImporter = true }
                .buttonStyle(.borderedProminent)
        }
    }
}

/// A pair of flag buttons in the top bar; the active language is highlighted.
/// Each flag gets a fixed cell so the emoji never clips or squashes, and the
/// whole control is fixed-size so the toolbar can't compress it.
private struct LanguageToggle: View {
    @EnvironmentObject private var language: AppLanguage

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Language.allCases) { lang in
                let selected = language.current == lang
                Button {
                    language.current = lang
                } label: {
                    Text(lang.flag)
                        .font(.system(size: 21))
                        .frame(width: 40, height: 30)
                        .background(selected ? Color.accentColor.opacity(0.22) : .clear,
                                    in: RoundedRectangle(cornerRadius: 8))
                        .opacity(selected ? 1 : 0.4)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(lang.accessibilityName)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .fixedSize()
    }
}
