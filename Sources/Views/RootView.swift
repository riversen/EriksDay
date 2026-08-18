import SwiftUI

/// Wraps the app in the device-owner lock and hides its contents whenever it
/// isn't frontmost, so care data doesn't linger in the app-switcher snapshot.
struct RootView: View {
    @EnvironmentObject private var language: AppLanguage
    @EnvironmentObject private var lock: AppLock
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack {
            ContentView()

            if lock.isUnlocked && scenePhase != .active {
                PrivacyCover()
            }
            if !lock.isUnlocked {
                LockScreen()
            }
        }
        .animation(.easeInOut(duration: 0.15), value: lock.isUnlocked)
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:  lock.didBecomeActive(reason: language.s.unlockReason)
            default:       lock.willResignActive()
            }
        }
    }
}

/// Opaque cover used for the backgrounded snapshot.
private struct PrivacyCover: View {
    var body: some View {
        ZStack {
            Rectangle().fill(.regularMaterial).ignoresSafeArea()
            Image("AppLogo")
                .resizable()
                .frame(width: 72, height: 72)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .transition(.opacity)
    }
}

private struct LockScreen: View {
    @EnvironmentObject private var language: AppLanguage
    @EnvironmentObject private var lock: AppLock

    private var s: Strings { language.s }

    var body: some View {
        ZStack {
            Rectangle().fill(.regularMaterial).ignoresSafeArea()
            VStack(spacing: 18) {
                Image("AppLogo")
                    .resizable()
                    .frame(width: 72, height: 72)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

                Text(s.appLocked).font(.headline)
                Button(s.unlock) { lock.authenticate(reason: s.unlockReason) }
                    .buttonStyle(.borderedProminent)
            }
        }
        .transition(.opacity)
        .onAppear { lock.authenticate(reason: s.unlockReason) }
    }
}

/// Small settings sheet — currently just the lock, and the device label that
/// shows up in each entry's edit history.
struct SettingsView: View {
    @EnvironmentObject private var language: AppLanguage
    @EnvironmentObject private var lock: AppLock
    @EnvironmentObject private var store: FolderStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    private var s: Strings { language.s }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle(s.requireUnlock, isOn: $lock.isEnabled)
                    if !lock.isSupported {
                        // Never a silent downgrade: say why the lock can't apply.
                        Label(s.lockInactive, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.secondary)
                        Button(s.openSettings) {
                            if let url = URL(string: UIApplication.openSettingsURLString) {
                                openURL(url)
                            }
                        }
                    }
                } header: {
                    Text(s.security)
                } footer: {
                    Text(lock.isSupported ? s.requireUnlockHelp : s.passcodeNeeded)
                }

                if let folder = store.folderName {
                    Section {
                        LabeledContent(s.folderLabel, value: folder)
                        LabeledContent(s.thisDevice, value: store.deviceName)
                    }
                }
            }
            .navigationTitle(s.settings)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(s.done) { dismiss() }
                }
            }
        }
    }
}
