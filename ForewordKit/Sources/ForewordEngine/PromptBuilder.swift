import Foundation

/// Everything known about where the user is writing, gathered by the app.
public struct WritingContext: Sendable, Equatable {
    public var appName: String?
    public var windowTitle: String?
    /// Web domain when writing in a browser.
    public var website: String?
    /// Placeholder / label / title of the text field ("Subject", "Message #general"…).
    public var fieldLabel: String?
    /// Text visible around the field (conversation, the email being replied to…), most relevant last.
    public var screenText: String?
    /// The user's self description from Settings.
    public var aboutUser: String?
    /// Snippets of the user's earlier writing that look relevant here.
    public var memories: [String] = []
    /// Preferred language / style notes.
    public var styleNotes: String?
    /// Text the user copied recently (a link, an address, a quote they're about to reference).
    public var clipboard: String?
    /// Text visible in other apps' windows around the one being written in (the page behind a note).
    public var otherWindows: [VisibleWindow] = []

    public struct VisibleWindow: Sendable, Equatable {
        public var title: String
        public var text: String
        public init(title: String, text: String) {
            self.title = title
            self.text = text
        }
    }

    public init(appName: String? = nil, windowTitle: String? = nil, website: String? = nil,
                fieldLabel: String? = nil, screenText: String? = nil, aboutUser: String? = nil,
                memories: [String] = [], styleNotes: String? = nil, clipboard: String? = nil) {
        self.appName = appName
        self.windowTitle = windowTitle
        self.website = website
        self.fieldLabel = fieldLabel
        self.screenText = screenText
        self.aboutUser = aboutUser
        self.memories = memories
        self.styleNotes = styleNotes
        self.clipboard = clipboard
    }
}

/// Renders a `WritingContext` into the prompt header that precedes the document.
///
/// Base models continue documents, so the header reads like a document preamble rather than an
/// instruction. Stable information comes first and the most volatile last, which keeps the cached
/// prompt prefix valid for as long as possible.
public enum PromptBuilder {
    public static let screenBudget = 1800   // characters
    public static let memoryBudget = 900
    public static let aboutBudget = 600
    public static let clipboardBudget = 700
    public static let otherWindowsBudget = 1400

    public static func header(for context: WritingContext) -> String {
        var lines: [String] = []

        if let about = clean(context.aboutUser, limit: aboutBudget) {
            lines.append("About the writer: \(about)")
        }
        if let style = clean(context.styleNotes, limit: 300) {
            lines.append("Writing style: \(style)")
        }
        if !context.memories.isEmpty {
            var budget = memoryBudget
            var snippets: [String] = []
            for m in context.memories {
                guard let s = clean(m, limit: min(budget, 400)) else { continue }
                snippets.append("- \(s)")
                budget -= s.count
                if budget < 80 { break }
            }
            if !snippets.isEmpty {
                lines.append("Things the writer has written before:")
                lines.append(contentsOf: snippets)
            }
        }

        var place: [String] = []
        if let app = clean(context.appName, limit: 60) { place.append(app) }
        if let site = clean(context.website, limit: 80), !(context.appName ?? "").localizedCaseInsensitiveContains(site) {
            place.append(site)
        }
        if let title = clean(context.windowTitle, limit: 140), !place.contains(title) { place.append(title) }
        if !place.isEmpty { lines.append("Writing in: " + place.joined(separator: " — ")) }
        if let label = clean(context.fieldLabel, limit: 120) { lines.append("Field: \(label)") }

        // Other windows first: the window being written in is the closer context.
        var otherBudget = otherWindowsBudget
        for window in context.otherWindows where otherBudget > 120 {
            guard let text = clean(window.text, limit: otherBudget, keepTail: false, singleLine: false) else { continue }
            otherBudget -= text.count
            let title = clean(window.title, limit: 120).map { " (\($0))" } ?? ""
            lines.append("Also on screen\(title):")
            lines.append("\"\"\"")
            lines.append(text)
            lines.append("\"\"\"")
        }
        if let screen = clean(context.screenText, limit: screenBudget, keepTail: true, singleLine: false) {
            lines.append("On screen:")
            lines.append("\"\"\"")
            lines.append(screen)
            lines.append("\"\"\"")
        }
        // Closest to the document: what the user just copied is often what they're about to use.
        if let copied = clean(context.clipboard, limit: clipboardBudget, singleLine: false) {
            lines.append("Recently copied:")
            lines.append("\"\"\"")
            lines.append(copied)
            lines.append("\"\"\"")
        }

        guard !lines.isEmpty else { return "" }
        lines.append("")
        lines.append("Text being written:")
        lines.append("")
        return lines.joined(separator: "\n")
    }

    static func clean(_ text: String?, limit: Int, keepTail: Bool = false, singleLine: Bool = true) -> String? {
        guard var t = text?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        if singleLine {
            t = t.split(whereSeparator: \.isNewline).joined(separator: " ")
        } else {
            // Collapse runs of blank lines.
            t = t.replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
        }
        if t.count > limit {
            if keepTail {
                t = "…" + String(t.suffix(limit))
            } else {
                t = String(t.prefix(limit)) + "…"
            }
        }
        return t
    }
}
