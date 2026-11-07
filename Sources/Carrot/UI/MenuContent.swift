import AppKit
import Carbon.HIToolbox
import SwiftUI

/// The menu bar menu.
struct MenuContent: View {
    @ObservedObject private var prefs = Preferences.shared
    @ObservedObject private var models = ModelManager.shared
    @ObservedObject private var permissions = Permissions.shared

    private var frontApp: NSRunningApplication? {
        let app = NSWorkspace.shared.frontmostApplication
        return app?.processIdentifier == ProcessInfo.processInfo.processIdentifier ? nil : app
    }

    var body: some View {
        Text(statusLine)

        Divider()

        Toggle("Suggestions", isOn: Binding(
            get: { prefs.isEnabled },
            set: { prefs.isEnabled = $0; if $0 { prefs.pausedUntil = nil } }
        ))
        .keyboardShortcut("s")

        if let app = frontApp, let bundleID = app.bundleIdentifier, let name = app.localizedName {
            Toggle("Use in \(name)", isOn: Binding(
                get: { prefs.isAppEnabled(bundleID) },
                set: { prefs.setApp(bundleID, enabled: $0) }
            ))
        }

        if let until = prefs.pausedUntil, until > Date() {
            Button("Resume Now") { prefs.pausedUntil = nil }
        } else {
            Menu("Pause") {
                Button("For 15 Minutes") { pause(minutes: 15) }
                Button("For 1 Hour") { pause(minutes: 60) }
                Button("Until Tomorrow") {
                    prefs.pausedUntil = Calendar.current.startOfDay(for: Date().addingTimeInterval(86_400))
                }
            }
            .disabled(!prefs.isEnabled)
        }

        Divider()

        SettingsLink { Text("Settings…") }
            .keyboardShortcut(",")
        Button("About Carrot") {
            NSApp.activate(ignoringOtherApps: true)
            NSApp.orderFrontStandardAboutPanel(nil)
        }
        Button("Check for Updates…") {
            // Opens the releases page; Carrot itself never phones home.
            if let url = URL(string: "https://github.com/Mason363/Carrot/releases/latest") {
                NSWorkspace.shared.open(url)
            }
        }

        Divider()

        Button("Quit Carrot") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    private var statusLine: String {
        if !permissions.isTrusted { return "Needs Accessibility permission" }
        switch models.status {
        case .notDownloaded: return "No model downloaded"
        case .downloading(let progress, _): return "Downloading model… \(Int(progress * 100))%"
        case .verifying: return "Checking download…"
        case .loading: return "Loading model…"
        case .failed: return "Model problem — see Settings"
        case .ready: break
        }
        if !prefs.isEnabled { return "Suggestions are off" }
        if IsSecureEventInputEnabled() { return "Paused while a password field is active" }
        if let until = prefs.pausedUntil, until > Date() {
            return "Paused until \(until.formatted(date: .omitted, time: .shortened))"
        }
        return "Ready"
    }

    private func pause(minutes: Double) {
        prefs.pausedUntil = Date().addingTimeInterval(minutes * 60)
    }
}

/// The menu bar glyph: a little carrot standing in for the text caret, followed by faint "ghost" text.
enum MenuBarIcon {
    static func image(active: Bool) -> NSImage {
        let size = NSSize(width: 18, height: 16)
        let image = NSImage(size: size, flipped: false) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            NSColor.black.setFill()
            NSColor.black.setStroke()
            // Inactive: the whole glyph dims, like a disabled menu bar item.
            context.setAlpha(active ? 1 : 0.45)
            context.saveGState()
            // The carrot leans toward the text it's about to write, like the app icon's.
            context.translateBy(x: 6.2, y: 11.4)
            context.rotate(by: -12 * .pi / 180)
            let body = NSBezierPath()
            body.move(to: NSPoint(x: -2.4, y: 0))
            body.curve(to: NSPoint(x: 2.4, y: 0), controlPoint1: NSPoint(x: -2.4, y: 1.0), controlPoint2: NSPoint(x: 2.4, y: 1.0))
            body.curve(to: NSPoint(x: 0.3, y: -10.0), controlPoint1: NSPoint(x: 2.4, y: -3.6), controlPoint2: NSPoint(x: 1.0, y: -8.0))
            body.curve(to: NSPoint(x: -0.3, y: -10.0), controlPoint1: NSPoint(x: 0.15, y: -10.4), controlPoint2: NSPoint(x: -0.15, y: -10.4))
            body.curve(to: NSPoint(x: -2.4, y: 0), controlPoint1: NSPoint(x: -1.0, y: -8.0), controlPoint2: NSPoint(x: -2.4, y: -3.6))
            body.fill()
            let leaves = NSBezierPath()
            leaves.lineWidth = 1.25
            leaves.lineCapStyle = .round
            leaves.move(to: NSPoint(x: 0, y: 1.2)); leaves.line(to: NSPoint(x: 0, y: 4.2))
            leaves.move(to: NSPoint(x: -0.2, y: 1.2)); leaves.line(to: NSPoint(x: -2.1, y: 3.3))
            leaves.move(to: NSPoint(x: 0.2, y: 1.2)); leaves.line(to: NSPoint(x: 2.1, y: 3.3))
            leaves.stroke()
            context.restoreGState()
            // Ghost text: dashes after the carrot, on the line it sits on.
            let ghost = NSBezierPath()
            ghost.lineWidth = 1.6
            ghost.lineCapStyle = .round
            ghost.move(to: NSPoint(x: 10.2, y: 5.5)); ghost.line(to: NSPoint(x: 12.0, y: 5.5))
            ghost.move(to: NSPoint(x: 14.4, y: 5.5)); ghost.line(to: NSPoint(x: 16.2, y: 5.5))
            context.setAlpha(active ? 0.55 : 0.2)
            ghost.stroke()
            return true
        }
        image.isTemplate = true
        return image
    }
}
