import AppKit
import SwiftUI
import WebKit

/// A scripted test harness (launch with `--testbench`). It shows a small non-activating window with
/// native and web text fields, drives Foreword against them through Accessibility, and never posts
/// global keyboard events — so it can run while someone keeps working on the same Mac.
///
/// Commands arrive as distributed notifications named `io.github.mason363.Foreword.debug` whose
/// object is a JSON string, e.g. {"cmd":"type","text":"Hello","out":"/tmp/state.json"}.
enum TestBench {
    static let isActive = CommandLine.arguments.contains("--testbench")
    static var forceTarget: Bool { isActive }
    /// `--observe <bundle id>`: follow that app's focused field even in the background, without
    /// an event tap and without ever inserting text (for testing inside real apps).
    static let observedBundleID: String? = {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--observe"), i + 1 < args.count else { return nil }
        return args[i + 1]
    }()
    static var isDebugging: Bool { isActive || observedBundleID != nil }
    /// Where insertions go while testing (instead of synthesised global key events).
    @MainActor static var insertHandler: ((String) -> Void)?
    @MainActor static var backspaceHandler: ((Int) -> Void)?
}

@MainActor
final class TestBenchController: NSObject, WKNavigationDelegate {
    static let shared = TestBenchController()
    private var window: NSPanel?
    private var textView: NSTextView!
    private var textField: NSTextField!
    private var webView: WKWebView!
    private var current = "textview"
    private var downloadReport = ""

    func startObserving() {
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(command(_:)), name: Notification.Name("io.github.mason363.Foreword.debug"),
            object: nil, suspensionBehavior: .deliverImmediately)
    }

    func start() {
        guard TestBench.isActive else { return }
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 640, height: 520),
                            styleMask: [.titled, .nonactivatingPanel, .utilityWindow], backing: .buffered, defer: false)
        panel.title = "Foreword Test Bench"
        panel.level = .floating
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        if let screen = NSScreen.main {
            panel.setFrameOrigin(NSPoint(x: screen.visibleFrame.maxX - 660, y: screen.visibleFrame.minY + 20))
        }
        let content = NSView(frame: panel.contentRect(forFrameRect: panel.frame))

        let scroll = NSTextView.scrollableTextView()
        scroll.frame = NSRect(x: 16, y: 300, width: 608, height: 200)
        textView = (scroll.documentView as! NSTextView)
        textView.font = NSFont(name: "Helvetica", size: 15)
        textView.isRichText = false
        textView.setAccessibilityIdentifier("bench.textview")
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        content.addSubview(scroll)

        textField = NSTextField(frame: NSRect(x: 16, y: 262, width: 608, height: 26))
        textField.font = NSFont.systemFont(ofSize: 14)
        textField.placeholderString = "Message"
        textField.setAccessibilityIdentifier("bench.textfield")
        content.addSubview(textField)

        webView = WKWebView(frame: NSRect(x: 16, y: 16, width: 608, height: 236))
        webView.navigationDelegate = self
        content.addSubview(webView)
        webView.loadHTMLString(Self.html, baseURL: URL(string: "https://bench.foreword.test/"))

        panel.contentView = content
        panel.orderFrontRegardless()
        window = panel

        TestBench.insertHandler = { [weak self] text in self?.insert(text) }
        TestBench.backspaceHandler = { [weak self] count in self?.backspace(count) }

        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(command(_:)), name: Notification.Name("io.github.mason363.Foreword.debug"),
            object: nil, suspensionBehavior: .deliverImmediately)
    }

    static let html = """
    <!doctype html><html><head><meta charset="utf-8"><style>
    body { font-family: -apple-system, Helvetica; margin: 8px; background: #fff; }
    textarea { font: 17px Georgia; width: 570px; height: 70px; }
    input { font: 15px -apple-system; width: 570px; margin-top: 6px; }
    #editable { font: 16px Helvetica; border: 1px solid #ccc; min-height: 60px; margin-top: 6px; padding: 4px; }
    </style></head><body>
    <textarea id="ta" aria-label="Notes"></textarea>
    <input id="in" type="text" placeholder="Subject">
    <div id="editable" contenteditable="true" aria-label="Body"></div>
    </body></html>
    """

    // MARK: Commands

    @objc private func command(_ note: Notification) {
        guard let json = note.object as? String, let data = json.data(using: .utf8),
              let cmd = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        let out = cmd["out"] as? String
        Task { @MainActor in
            await self.run(cmd)
            if let out { self.writeState(to: out) }
        }
    }

    private func run(_ cmd: [String: Any]) async {
        switch cmd["cmd"] as? String {
        case "select":
            await select(cmd["field"] as? String ?? "textview")
        case "setText":
            await setText(cmd["text"] as? String ?? "", caret: cmd["caret"] as? Int)
        case "type":
            let text = cmd["text"] as? String ?? ""
            let delay = cmd["delay"] as? Double ?? 0.06
            for ch in text {
                SuggestionController.shared.debugNoteTyped(String(ch))
                insert(String(ch))
                try? await Task.sleep(nanoseconds: UInt64(delay * 1e9))
            }
            try? await Task.sleep(nanoseconds: UInt64((cmd["settle"] as? Double ?? 0.4) * 1e9))
        case "accept":
            SuggestionController.shared.debugAccept(all: cmd["all"] as? Bool ?? true)
            try? await Task.sleep(nanoseconds: 400_000_000)
        case "download":
            guard let spec = ModelCatalog.spec(id: cmd["model"] as? String ?? "") else { break }
            let models = ModelManager.shared
            let started = Date()
            models.download(spec)
            // Wait for the download, verification and install to finish (or fail).
            while Date().timeIntervalSince(started) < 1800 {
                try? await Task.sleep(nanoseconds: 500_000_000)
                if case .downloading = models.status { continue }
                if models.status == .verifying || models.status == .loading { continue }
                break
            }
            downloadReport = "status=\(models.status) downloaded=\(ModelCatalog.isDownloaded(spec)) seconds=\(Int(Date().timeIntervalSince(started)))"
        case "render":
            renderViews(to: cmd["dir"] as? String ?? NSTemporaryDirectory())
        case "wait":
            try? await Task.sleep(nanoseconds: UInt64((cmd["seconds"] as? Double ?? 0.5) * 1e9))
        default:
            break
        }
    }

    /// Renders settings tabs and onboarding offscreen (never shown on screen) for visual review.
    private func renderViews(to directory: String) {
        let views: [(String, AnyView, CGFloat)] = [
            ("general", AnyView(GeneralSettings()), 560),
            ("appearance", AnyView(AppearanceSettings()), 560),
            ("keyboard", AnyView(KeyboardSettings()), 560),
            ("apps", AnyView(AppsSettings()), 560),
            ("personal", AnyView(PersonalSettings()), 560),
            ("model", AnyView(ModelSettings()), 560),
            ("onboarding", AnyView(OnboardingView(onFinish: {})), 560),
            ("onboarding-try", AnyView(OnboardingView(onFinish: {}, initialStep: 3)), 560),
        ]
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            for (name, view, width) in views {
                let hosting = NSHostingView(rootView: view.frame(width: width).fixedSize(horizontal: false, vertical: true)
                    .background(Color(nsColor: .windowBackgroundColor)))
                let size = hosting.fittingSize
                let window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: width, height: max(size.height, 100)),
                                      styleMask: [.borderless], backing: .buffered, defer: false)
                window.appearance = NSAppearance(named: appearance)
                window.contentView = hosting
                hosting.frame = NSRect(x: 0, y: 0, width: width, height: max(size.height, 100))
                hosting.layoutSubtreeIfNeeded()
                hosting.display()
                guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { continue }
                hosting.cacheDisplay(in: hosting.bounds, to: rep)
                let suffix = appearance == .darkAqua ? "-dark" : ""
                try? rep.representation(using: .png, properties: [:])?
                    .write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(name)\(suffix).png"))
                window.contentView = nil
            }
        }
    }

    private var benchIdentifier: String {
        switch current {
        case "textview": return "bench.textview"
        case "textfield": return "bench.textfield"
        case "web-textarea": return "ta"
        case "web-input": return "in"
        default: return "editable"
        }
    }

    private func writeState(to path: String) {
        var state = SuggestionController.shared.debugState
        state["benchFrame"] = window.map { NSStringFromRect($0.frame) } ?? ""
        state["overlayFrame"] = SuggestionController.shared.debugOverlayFrame
        state["download"] = downloadReport
        state["screenHeight"] = NSScreen.screens.first?.frame.height ?? 0
        state["benchField"] = current
        if let data = try? JSONSerialization.data(withJSONObject: state, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: path))
        }
    }

    private func select(_ name: String) async {
        current = name
        switch name {
        case "textview":
            window?.makeFirstResponder(textView)
        case "textfield":
            window?.makeFirstResponder(textField)
        default:
            window?.makeFirstResponder(webView)
            let id = name == "web-textarea" ? "ta" : name == "web-input" ? "in" : "editable"
            _ = try? await webView.evaluateJavaScript("document.getElementById('\(id)').focus(); true")
        }
        try? await Task.sleep(nanoseconds: 200_000_000)
        SuggestionController.shared.debugRetarget(identifier: benchIdentifier)
        try? await Task.sleep(nanoseconds: 1_200_000_000)
    }

    private func setText(_ text: String, caret: Int?) async {
        let location = caret ?? (text as NSString).length
        switch current {
        case "textview":
            textView.string = text
            textView.setSelectedRange(NSRange(location: location, length: 0))
        case "textfield":
            textField.stringValue = text
            textField.currentEditor()?.selectedRange = NSRange(location: location, length: 0)
        default:
            let escaped = text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "`", with: "\\`")
            let js = """
            (function(){ const e = document.activeElement;
              if (e.isContentEditable) { e.innerText = `\(escaped)`; const r = document.createRange(); r.selectNodeContents(e); r.collapse(false);
                const s = getSelection(); s.removeAllRanges(); s.addRange(r); }
              else { e.value = `\(escaped)`; e.selectionStart = e.selectionEnd = e.value.length; }
              return true; })()
            """
            _ = try? await webView.evaluateJavaScript(js)
        }
        try? await Task.sleep(nanoseconds: 150_000_000)
        SuggestionController.shared.debugRetarget(identifier: benchIdentifier)
    }

    private func insert(_ text: String) {
        switch current {
        case "textview":
            textView.insertText(text, replacementRange: textView.selectedRange())
        case "textfield":
            if let editor = textField.currentEditor() as? NSTextView {
                editor.insertText(text, replacementRange: editor.selectedRange())
            } else {
                textField.stringValue += text
            }
        default:
            let escaped = text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'")
            webView.evaluateJavaScript("document.execCommand('insertText', false, '\(escaped)')")
        }
    }

    private func backspace(_ count: Int) {
        for _ in 0..<count {
            switch current {
            case "textview": textView.deleteBackward(nil)
            case "textfield": (textField.currentEditor() as? NSTextView)?.deleteBackward(nil)
            default: webView.evaluateJavaScript("document.execCommand('delete')")
            }
        }
    }
}
