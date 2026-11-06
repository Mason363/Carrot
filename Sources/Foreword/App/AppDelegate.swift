import AppKit
import Combine
import ForewordEngine
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var onboardingWindow: NSWindow?
    private var cancellables = Set<AnyCancellable>()
    /// Keeps App Nap away: Foreword sits in the keyboard path, so it must never be throttled.
    private var activity: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical],
            reason: "Foreword responds to typing")
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
        window.title = "Welcome to Foreword"
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

@MainActor
func openSettings() {
    NSApp.activate(ignoringOtherApps: true)
    if #available(macOS 14, *) {
        // SwiftUI's Settings scene responds to this selector.
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    }
}
