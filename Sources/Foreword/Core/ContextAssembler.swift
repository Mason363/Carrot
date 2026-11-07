import AppKit
import ForewordEngine

/// Builds the prompt header for a field: where the user is writing, what's on screen, what they've
/// written before and what they told Foreword about themselves. The header is computed once per
/// field (and refreshed when the conversation moves on) so the model's prompt cache stays warm.
@MainActor
final class ContextAssembler {
    private(set) var header = ""
    private(set) var context = WritingContext()
    private var field: FieldInfo?
    private var generation = 0
    private var lastScreenRefresh: TimeInterval = 0

    /// Called when the header changed asynchronously (screen text or memories arrived).
    var onUpdate: (() -> Void)?

    func prepare(for info: FieldInfo, snapshot: FieldSnapshot?) {
        field = info
        generation += 1
        let prefs = Preferences.shared
        var ctx = WritingContext()
        let isBrowser = AppRules.isBrowser(info.bundleID)
        ctx.appName = isBrowser ? nil : info.appName
        // Electron apps load their own pages (app://obsidian.md/…): only real web pages are websites.
        let isWebPage = info.url.map { $0.hasPrefix("http://") || $0.hasPrefix("https://") } ?? false
        ctx.website = isWebPage ? info.domain : nil
        ctx.windowTitle = cleanTitle(info.windowTitle, appName: info.appName)
        if let label = info.label, label.count <= 120, !label.isEmpty { ctx.fieldLabel = label }
        ctx.aboutUser = prefs.aboutMe.isEmpty ? nil : prefs.aboutMe
        ctx.clipboard = usableClipboard(fieldText: (snapshot?.prefix ?? "") + (snapshot?.suffix ?? ""))
        context = ctx
        header = PromptBuilder.header(for: ctx)
        refreshAsync(info: info, snapshot: snapshot)
    }

    /// Picks up a new copy (cheap when nothing changed). Returns true when the header changed.
    @discardableResult
    func refreshClipboard(fieldText: String) -> Bool {
        guard field != nil else { return false }
        let copied = usableClipboard(fieldText: fieldText)
        guard copied != context.clipboard else { return false }
        context.clipboard = copied
        header = PromptBuilder.header(for: context)
        return true
    }

    /// The recent copy, unless it's just text from this same field.
    private func usableClipboard(fieldText: String) -> String? {
        guard let copied = ClipboardMonitor.shared.recentText() else { return nil }
        if copied.count >= 12, fieldText.contains(copied) { return nil }
        return copied
    }

    /// Re-reads the screen (e.g. after a chat message was sent and the field emptied).
    func refreshScreen(snapshot: FieldSnapshot?) {
        guard let field else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastScreenRefresh > 1.5 else { return }
        refreshAsync(info: field, snapshot: snapshot)
    }

    func reset() {
        field = nil
        generation += 1
        header = ""
        context = WritingContext()
    }

    private func refreshAsync(info: FieldInfo, snapshot: FieldSnapshot?) {
        let prefs = Preferences.shared
        let token = generation
        lastScreenRefresh = ProcessInfo.processInfo.systemUptime
        let useScreen = prefs.useScreenContext
        let useMemory = prefs.memoryEnabled
        let fieldFrame = snapshot?.fieldFrame
        let existingText = (snapshot?.prefix ?? "") + (snapshot?.suffix ?? "")

        ScreenContextCollector.queue.async { [weak self] in
            let screen = useScreen ? ScreenContextCollector.collect(around: info, fieldFrame: fieldFrame) : nil
            let others = useScreen
                ? ScreenContextCollector.collectOtherWindows(excluding: info, fieldFrame: fieldFrame)
                    .map { WritingContext.VisibleWindow(title: $0.title, text: $0.text) }
                : []
            let query = [info.windowTitle ?? "", info.label ?? "", String(existingText.suffix(600)), String((screen ?? "").suffix(800))]
                .joined(separator: " ")
            let finish: ([String]) -> Void = { memories in
                DispatchQueue.main.async {
                    guard let self, self.generation == token else { return }
                    var ctx = self.context
                    ctx.screenText = screen.map { self.trimScreen($0, excluding: existingText) }
                    ctx.otherWindows = others
                    ctx.clipboard = self.context.clipboard
                    ctx.memories = memories
                    if ctx != self.context {
                        self.context = ctx
                        self.header = PromptBuilder.header(for: ctx)
                        self.onUpdate?()
                    }
                }
            }
            if useMemory {
                MemoryStore.shared.recall(query, limit: 3, completion: finish)
            } else {
                finish([])
            }
        }
    }

    /// Removes the field's own text from the screen text (it's already the document).
    private func trimScreen(_ screen: String, excluding fieldText: String) -> String {
        guard !fieldText.isEmpty else { return screen }
        let lines = screen.split(separator: "\n", omittingEmptySubsequences: true).filter { line in
            line.count < 12 || !fieldText.contains(line)
        }
        return lines.joined(separator: "\n")
    }

    /// Window titles often end with the app name ("Draft — Mail"); drop it.
    private func cleanTitle(_ title: String?, appName: String?) -> String? {
        guard var t = title?.trimmingCharacters(in: .whitespaces), !t.isEmpty else { return nil }
        if let appName {
            // "Note - Vault - Obsidian 1.15.0": the app's name, with or without its version.
            for separator in [" — ", " - ", " – ", " | "] {
                guard let range = t.range(of: separator + appName, options: .backwards) else { continue }
                let rest = t[range.upperBound...].trimmingCharacters(in: .whitespaces)
                if rest.isEmpty || rest.allSatisfy({ $0.isNumber || $0 == "." || $0 == "v" }) {
                    t = String(t[..<range.lowerBound])
                }
            }
        }
        // Browsers append their name, and Chromium also the profile ("… - Google Chrome - Work").
        for browser in ["Google Chrome", "Chromium", "Microsoft Edge", "Brave", "Arc", "Vivaldi", "Opera", "Safari",
                        "Zen", "Mozilla Firefox", "Firefox"] {
            for separator in [" — ", " - ", " – "] {
                if let range = t.range(of: separator + browser, options: .backwards) {
                    t = String(t[..<range.lowerBound])
                }
            }
        }
        // Chromium tab groups: "Page - Part of group Research".
        if let range = t.range(of: " - Part of group ") { t = String(t[..<range.lowerBound]) }
        // Window titles of private windows.
        t = t.replacingOccurrences(of: " (Private Browsing)", with: "")
        return t.isEmpty ? nil : t
    }
}
