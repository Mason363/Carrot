import AppKit
import ApplicationServices
import os

/// Follows keyboard focus across apps and reports text, selection and window changes.
///
/// Notifications come from an `AXObserver` on the frontmost app. Because some apps send them late
/// or not at all, the controller also polls after keystrokes; this class only reports what it sees.
@MainActor
final class FocusTracker {
    enum Event {
        case focusChanged
        case valueChanged
        case selectionChanged
        case geometryChanged
    }

    var onEvent: ((Event) -> Void)?

    private var observer: AXObserver?
    private var observedPID: pid_t?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var pollTimer: Timer?
    private(set) var frontmostApp: NSRunningApplication?
    private let log = Logger(subsystem: "io.github.mason363.Foreword", category: "focus")

    func start() {
        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers.append(center.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
                                                     object: nil, queue: .main) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated { self?.attach(to: app) }
        })
        attach(to: NSWorkspace.shared.frontmostApplication)
        // Safety net for apps that don't post focus notifications.
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.onEvent?(.focusChanged) }
        }
    }

    func stop() {
        workspaceObservers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        workspaceObservers = []
        pollTimer?.invalidate()
        detach()
    }

    private func detach() {
        if let observer {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        }
        observer = nil
        observedPID = nil
    }

    private func attach(to app: NSRunningApplication?) {
        var app = app
        if TestBench.observedBundleID != nil {
            app = TestBench.observedApplication()
        }
        frontmostApp = app
        guard let app, app.processIdentifier != ProcessInfo.processInfo.processIdentifier || TestBench.isActive
                || TestBench.observedPID != nil else {
            detach()
            onEvent?(.focusChanged)
            return
        }
        let pid = app.processIdentifier
        if observedPID == pid { onEvent?(.focusChanged); return }
        detach()

        WebAccessibility.enableIfNeeded(for: app)

        var newObserver: AXObserver?
        let callback: AXObserverCallback = { _, _, notification, refcon in
            guard let refcon else { return }
            let tracker = Unmanaged<FocusTracker>.fromOpaque(refcon).takeUnretainedValue()
            let name = notification as String
            MainActor.assumeIsolated { tracker.handle(name) }
        }
        guard AXObserverCreate(pid, callback, &newObserver) == .success, let newObserver else {
            log.error("AXObserverCreate failed for \(app.bundleIdentifier ?? "?", privacy: .public)")
            onEvent?(.focusChanged)
            return
        }
        let appElement = AXUIElementCreateApplication(pid)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        for name in [kAXFocusedUIElementChangedNotification, kAXValueChangedNotification, kAXSelectedTextChangedNotification,
                     kAXFocusedWindowChangedNotification, kAXWindowMovedNotification, kAXWindowResizedNotification,
                     kAXMainWindowChangedNotification] {
            AXObserverAddNotification(newObserver, appElement, name as CFString, refcon)
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(newObserver), .defaultMode)
        observer = newObserver
        observedPID = pid
        onEvent?(.focusChanged)
    }

    private func handle(_ notification: String) {
        switch notification {
        case kAXFocusedUIElementChangedNotification, kAXFocusedWindowChangedNotification, kAXMainWindowChangedNotification:
            onEvent?(.focusChanged)
        case kAXValueChangedNotification:
            onEvent?(.valueChanged)
        case kAXSelectedTextChangedNotification:
            onEvent?(.selectionChanged)
        case kAXWindowMovedNotification, kAXWindowResizedNotification:
            onEvent?(.geometryChanged)
        default:
            break
        }
    }
}

/// Chromium, Electron and Gecko build their web accessibility tree only when asked.
enum WebAccessibility {
    private static var enabledPIDs = Set<pid_t>()

    @MainActor
    static func enableIfNeeded(for app: NSRunningApplication) {
        let pid = app.processIdentifier
        guard !enabledPIDs.contains(pid) else { return }
        let bundleID = app.bundleIdentifier
        let isChromium = AppRules.isChromium(bundleID) || isElectron(app)
        let isGecko = bundleID.map { $0.hasPrefix("org.mozilla.") || $0.contains("zen-browser") || $0.hasPrefix("net.waterfox") || $0.hasPrefix("org.torproject") } ?? false
        // iWork builds its document text tree only for assistive clients.
        let isIWork = bundleID.map { $0.hasPrefix("com.apple.iWork.") } ?? false
        guard isChromium || isGecko || isIWork else { return }
        enabledPIDs.insert(pid)
        AXQueue.queue.async {
            let element = AXElement.application(pid: pid)
            element.setTimeout(0.5)
            if isChromium {
                // Chromium's own switch; unlike AXEnhancedUserInterface it doesn't disturb window animations.
                if !element.set("AXManualAccessibility", kCFBooleanTrue) {
                    element.set("AXEnhancedUserInterface", kCFBooleanTrue)
                }
            } else {
                element.set("AXEnhancedUserInterface", kCFBooleanTrue)
            }
        }
    }

    private static var electronCache: [String: Bool] = [:]

    static func isElectron(_ app: NSRunningApplication) -> Bool {
        guard let url = app.bundleURL else { return false }
        if let cached = electronCache[url.path] { return cached }
        let framework = url.appendingPathComponent("Contents/Frameworks/Electron Framework.framework")
        let result = FileManager.default.fileExists(atPath: framework.path)
        electronCache[url.path] = result
        return result
    }
}
