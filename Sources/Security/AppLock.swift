import Combine
import Foundation
import LocalAuthentication

/// Gates the app behind the device owner's Face ID / Touch ID / passcode.
///
/// The folder holds health information, so this defaults to on. It also closes
/// the gap where the data is only as protected as the device it sits on:
/// `.deviceOwnerAuthentication` fails outright when the device has no passcode,
/// so an unprotected device is refused rather than silently allowed.
@MainActor
final class AppLock: ObservableObject {
    enum State: Equatable {
        case locked
        case unlocked
    }

    @Published private(set) var state: State
    /// False when the device has no passcode or biometrics. iOS file
    /// protection is already inert without a device passcode, so refusing to
    /// open would protect nothing — the app opens and says so in Settings
    /// instead. Enforcing a passcode is an MDM concern, not an app one.
    @Published private(set) var isSupported: Bool
    @Published var isEnabled: Bool {
        didSet {
            guard oldValue != isEnabled else { return }
            UserDefaults.standard.set(isEnabled, forKey: Self.key)
            state = isEnabled ? .locked : .unlocked
        }
    }

    private static let key = "requireUnlock"
    /// When the app last stopped being frontmost, used for the grace period.
    private var leftAt: Date?
    /// Short trips out of the app shouldn't demand Face ID every time.
    private let grace: TimeInterval = 60

    init() {
        // Default on — this is health information.
        if UserDefaults.standard.object(forKey: Self.key) == nil {
            UserDefaults.standard.set(true, forKey: Self.key)
        }
        var enabled = UserDefaults.standard.bool(forKey: Self.key)
        #if DEBUG
        // Demo/screenshot runs shouldn't sit behind a biometric prompt.
        if ProcessInfo.processInfo.arguments.contains("-demoData") { enabled = false }
        #endif
        isEnabled = enabled
        var capabilityError: NSError?
        let supported = LAContext().canEvaluatePolicy(.deviceOwnerAuthentication,
                                                      error: &capabilityError)
        isSupported = supported
        state = (enabled && supported) ? .locked : .unlocked
    }

    var isUnlocked: Bool { state == .unlocked }

    func willResignActive() {
        leftAt = .now
    }

    func didBecomeActive(reason: String) {
        guard isEnabled, refreshSupport() else {
            state = .unlocked
            return
        }
        if state == .unlocked {
            // Only re-lock after being away longer than the grace period.
            guard let leftAt, Date.now.timeIntervalSince(leftAt) >= grace else { return }
        }
        state = .locked
        authenticate(reason: reason)
    }

    func authenticate(reason: String) {
        guard isEnabled, refreshSupport() else {
            state = .unlocked
            return
        }
        let context = LAContext()
        context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { success, error in
            Task { @MainActor in
                if success {
                    self.state = .unlocked
                    self.leftAt = nil
                    return
                }
                // Belt and braces: some platforms report the capability but
                // then fail because there is nothing to authenticate against.
                // Treat that like an unsupported device rather than locking
                // the user out of their own care log.
                if let code = (error as? LAError)?.code,
                   code == .passcodeNotSet || code == .biometryNotAvailable {
                    self.isSupported = false
                    self.state = .unlocked
                } else {
                    self.state = .locked
                }
            }
        }
    }

    /// Whether the device can authenticate its owner at all.
    @discardableResult
    private func refreshSupport() -> Bool {
        var error: NSError?
        let ok = LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: &error)
        isSupported = ok
        return ok
    }
}
