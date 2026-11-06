import AppKit
import ApplicationServices

/// Tracks the Accessibility permission Foreword needs to read text fields and handle keys.
@MainActor
final class Permissions: ObservableObject {
    static let shared = Permissions()

    @Published private(set) var isTrusted = AXIsProcessTrusted()
    private var timer: Timer?

    func startMonitoring() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let trusted = AXIsProcessTrusted()
                if trusted != self.isTrusted { self.isTrusted = trusted }
            }
        }
    }

    /// Shows the system prompt (which also adds Foreword to the list in System Settings).
    func request() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        isTrusted = AXIsProcessTrustedWithOptions(options)
    }

    func openSystemSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}
