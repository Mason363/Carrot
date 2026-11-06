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

        Button("Settings…") { openSettings() }
            .keyboardShortcut(",")
        Button("About Foreword") {
            NSApp.activate(ignoringOtherApps: true)
            NSApp.orderFrontStandardAboutPanel(nil)
        }
        Button("Check for Updates…") {
            // Opens the releases page; Foreword itself never phones home.
            if let url = URL(string: "https://github.com/Mason363/Foreword/releases/latest") {
                NSWorkspace.shared.open(url)
            }
        }

        Divider()

        Button("Quit Foreword") { NSApp.terminate(nil) }
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

/// The menu bar glyph: a text caret followed by a faint "ghost" line.
enum MenuBarIcon {
    static func image(active: Bool) -> NSImage {
        let size = NSSize(width: 18, height: 16)
        let image = NSImage(size: size, flipped: false) { _ in
            NSColor.black.setFill()
            NSColor.black.setStroke()
            // Caret (I-beam)
            let caret = NSBezierPath()
            caret.lineWidth = 1.6
            caret.lineCapStyle = .round
            caret.move(to: NSPoint(x: 5, y: 2.5)); caret.line(to: NSPoint(x: 5, y: 13.5))
            caret.move(to: NSPoint(x: 3, y: 2.5)); caret.line(to: NSPoint(x: 7, y: 2.5))
            caret.move(to: NSPoint(x: 3, y: 13.5)); caret.line(to: NSPoint(x: 7, y: 13.5))
            // Inactive: the whole glyph dims, like a disabled menu bar item.
            NSGraphicsContext.current?.cgContext.setAlpha(active ? 1 : 0.45)
            caret.stroke()
            // Ghost text: dashes after the caret
            let ghost = NSBezierPath()
            ghost.lineWidth = 1.6
            ghost.lineCapStyle = .round
            ghost.move(to: NSPoint(x: 9.5, y: 6)); ghost.line(to: NSPoint(x: 11.5, y: 6))
            ghost.move(to: NSPoint(x: 14, y: 6)); ghost.line(to: NSPoint(x: 16, y: 6))
            NSGraphicsContext.current?.cgContext.setAlpha(active ? 0.55 : 0.2)
            ghost.stroke()
            return true
        }
        image.isTemplate = true
        return image
    }
}
