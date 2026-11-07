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
///
/// Chromium only reports exact text geometry (caret and character boxes) in its full accessibility
/// mode. The switch is applied every time such an app comes to the front and again shortly after
/// it first appears (a switch flipped while the app is still starting can be lost), and once more
/// whenever its geometry goes missing, so suggestions never get stuck in the fallback pill.
enum WebAccessibility {
    private static var applied: [pid_t: TimeInterval] = [:]

    @MainActor
    static func enableIfNeeded(for app: NSRunningApplication) {
        let pid = app.processIdentifier
        let bundleID = app.bundleIdentifier
        // The switch changes how the app behaves for its whole life (Electron editors turn on their
        // screen-reader mode), so only flip it where Carrot is actually going to work.
        let prefs = Preferences.shared
        guard prefs.isActive, prefs.isAppEnabled(bundleID) || TestBench.isDebugging else { return }
        guard let kind = kind(of: app) else { return }
        let firstTime = applied[pid] == nil
        apply(kind, pid: pid)
        if firstTime {
            for delay in [2.0, 6.0] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    guard !app.isTerminated else { return }
                    apply(kind, pid: pid)
                }
            }
        }
    }

    /// The app's text geometry went missing (the caret's position had to be guessed): switch the
    /// full mode on again, at most every few seconds.
    @MainActor
    static func refresh(pid: pid_t) {
        guard let app = NSRunningApplication(processIdentifier: pid), let kind = kind(of: app) else { return }
        if let last = applied[pid], ProcessInfo.processInfo.systemUptime - last < 5 { return }
        apply(kind, pid: pid)
    }

    private enum Kind { case chromium, gecko, iWork }

    @MainActor
    private static func kind(of app: NSRunningApplication) -> Kind? {
        let bundleID = app.bundleIdentifier
        if AppRules.isChromium(bundleID) || isElectron(app) { return .chromium }
        if let id = bundleID, id.hasPrefix("org.mozilla.") || id.contains("zen-browser") || id.hasPrefix("net.waterfox")
            || id.hasPrefix("org.torproject") { return .gecko }
        // iWork builds its document text tree only for assistive clients.
        if let id = bundleID, id.hasPrefix("com.apple.iWork.") { return .iWork }
        return nil
    }

    @MainActor
    private static func apply(_ kind: Kind, pid: pid_t) {
        applied[pid] = ProcessInfo.processInfo.systemUptime
        if applied.count > 64 { applied = applied.filter { NSRunningApplication(processIdentifier: $0.key) != nil } }
        AXQueue.queue.async {
            let element = AXElement.application(pid: pid)
            element.setTimeout(0.5)
            if kind == .chromium {
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
