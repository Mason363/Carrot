import AppKit
import Combine
import CarrotEngine
import ServiceManagement
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var onboardingWindow: NSWindow?
    private var cancellables = Set<AnyCancellable>()
    /// Keeps App Nap away: Carrot sits in the keyboard path, so it must never be throttled.
    private var activity: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical],
            reason: "Carrot responds to typing")
        // Models and memory move from the app's former name before anything opens them.
        _ = AppSupport.directory
        // Open at login follows the app to its new name and place.
        if SMAppService.mainApp.status == .enabled { try? SMAppService.mainApp.register() }
        MainActor.assumeIsolated {
            NSApp.setActivationPolicy(.accessory)
            let prefs = Preferences.shared
            if !TestBench.benchOnly { ModelManager.shared.start() }

            if TestBench.isActive {
                TestBenchController.shared.start()
                if !TestBench.benchOnly { SuggestionController.shared.start() }
                return
            }
            if TestBench.observedBundleID != nil || TestBench.isLiveTest {
                TestBenchController.shared.startObserving()
                SuggestionController.shared.start()
                return
            }

            Permissions.shared.startMonitoring()
            Permissions.shared.$isTrusted
                .removeDuplicates()
                .sink { trusted in
                    MainActor.assumeIsolated {
                        if trusted {
                            SuggestionController.shared.start()
                        }
                    }
                }
                .store(in: &cancellables)

            if !prefs.hasCompletedOnboarding || !Permissions.shared.isTrusted || ModelManager.shared.selectedModelPath == nil {
                showOnboarding()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated {
            SuggestionController.shared.stop()
            MemoryStore.shared.flush()
            Journal.shared.flush()
            UserDefaults.standard.synchronize()
        }
        // ggml's Metal backend asserts if its device is torn down while buffers are alive during
        // static destruction; everything worth saving is saved, so leave without running destructors.
        _exit(0)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        MainActor.assumeIsolated { openSettings() }
        return true
    }

    @MainActor
    func showOnboarding() {
        if let window = onboardingWindow {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let view = OnboardingView { [weak self] in
            self?.onboardingWindow?.close()
            self?.onboardingWindow = nil
        }
        let hosting = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: hosting)
        window.title = "Welcome to Carrot"
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.setContentSize(NSSize(width: 560, height: 520))
        window.center()
        window.isReleasedWhenClosed = false
        onboardingWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

/// Opens Settings from AppKit code (reopening the app, onboarding). SwiftUI no longer answers the
/// old `showSettingsWindow:` action, but it still installs a "Settings…" item in the app menu, which
/// opens its Settings scene when performed.
@MainActor
func openSettings() {
    NSApp.activate(ignoringOtherApps: true)
    if let (menu, index) = settingsMenuItem(in: NSApp.mainMenu) {
        menu.performActionForItem(at: index)
    }
    bringSettingsToFront()
}

@MainActor
private func settingsMenuItem(in menu: NSMenu?) -> (NSMenu, Int)? {
    guard let menu else { return nil }
    for (index, item) in menu.items.enumerated() {
        if item.keyEquivalent == "," && item.keyEquivalentModifierMask == .command { return (menu, index) }
        if let found = settingsMenuItem(in: item.submenu) { return found }
    }
    return nil
}

/// A menu bar app isn't active when its menu is used, so Settings would open behind other windows.
@MainActor
func bringSettingsToFront() {
    NSApp.activate(ignoringOtherApps: true)
    DispatchQueue.main.async {
        for window in NSApp.windows where window.identifier?.rawValue.contains("Settings") == true || window.title.hasSuffix("Settings") {
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
        }
    }
}
