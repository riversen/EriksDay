import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject private var store: FolderStore
    @EnvironmentObject private var language: AppLanguage
    @Environment(\.scenePhase) private var scenePhase
    @State private var showingImporter = false
    @State private var selectedTab = ProcessInfo.processInfo.arguments.contains("-tabRoutines") ? 1 : 0

    private var s: Strings { language.s }

    var body: some View {
        Group {
            if store.hasFolder {
                tabs
            } else {
                NavigationStack {
                    folderPrompt
                        .navigationTitle("Erik's Day")
                        .toolbar {
                            ToolbarItem(placement: .topBarLeading) { LanguageToggle() }
                            ToolbarItem(placement: .topBarTrailing) { AppLogoView() }
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
        // Pull fresh files when returning to the app.
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { store.reloadAll() }
        }
        .alert(s.errorTitle,
               isPresented: Binding(get: { store.lastError != nil },
                                    set: { if !$0 { store.lastError = nil } })) {
            Button(s.ok, role: .cancel) { }
        } message: {
            Text(store.lastError ?? "")
        }
    }

    private var tabs: some View {
        TabView(selection: $selectedTab) {
            NavigationStack {
                LogView()
                    .navigationTitle("Erik's Day")
                    .modifier(AppBars())
            }
            .tabItem { Label(s.tabLog, systemImage: "checklist") }
            .tag(0)

            NavigationStack {
                RoutinesView()
                    .navigationTitle(s.routines)
                    .modifier(AppBars())
            }
            .tabItem { Label(s.tabRoutines, systemImage: "folder") }
            .tag(1)
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

/// Shared top bar for both tabs: language toggle (leading), refresh + app
/// icon (trailing).
private struct AppBars: ViewModifier {
    @EnvironmentObject private var store: FolderStore

    func body(content: Content) -> some View {
        content.toolbar {
            ToolbarItem(placement: .topBarLeading) { LanguageToggle() }
            ToolbarItem(placement: .topBarTrailing) {
                HStack(spacing: 12) {
                    Button { store.reloadAll() } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    AppLogoView()
                }
            }
        }
    }
}

/// Tiny app icon shown in the top-right.
private struct AppLogoView: View {
    var body: some View {
        Image("AppLogo")
            .resizable()
            .frame(width: 26, height: 26)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .accessibilityHidden(true)
    }
}

/// Flag buttons for the three languages; the active one is highlighted. The two
/// Norwegian standards share the flag, so each chip also shows its code.
private struct LanguageToggle: View {
    @EnvironmentObject private var language: AppLanguage

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Language.allCases) { lang in
                let selected = language.current == lang
                Button {
                    language.current = lang
                } label: {
                    VStack(spacing: 0) {
                        Text(lang.flag).font(.system(size: 16))
                        Text(lang.code).font(.system(size: 9, weight: .semibold))
                    }
                    .frame(width: 34, height: 34)
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
