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
        /// The device has no passcode, so there is nothing to authenticate against.
        case noDevicePasscode
    }

    @Published private(set) var state: State
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
        state = enabled ? .locked : .unlocked
    }

    var isUnlocked: Bool { state == .unlocked }

    func willResignActive() {
        leftAt = .now
    }

    func didBecomeActive(reason: String) {
        guard isEnabled else {
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
        guard isEnabled else {
            state = .unlocked
            return
        }
        let context = LAContext()
        var error: NSError?
        // Falls back to the passcode, and reports unavailable when the device
        // has none — the case worth refusing.
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            state = .noDevicePasscode
            return
        }
        context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { success, _ in
            Task { @MainActor in
                self.state = success ? .unlocked : .locked
                if success { self.leftAt = nil }
            }
        }
    }
}
