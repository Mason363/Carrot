import AppKit
import ApplicationServices

/// CodeMirror 6 editors (Obsidian, and the editors of many websites) in Chromium.
///
/// Once a document has headings, lists or widgets, Chromium's value for the editor and its
/// selection offsets stop agreeing, so reading "the text before the selection offset" lands on the
/// wrong text. Each editor line is its own element, though, and text markers place the caret
/// exactly: the text is rebuilt line by line around the caret instead. Obsidian's Live Preview
/// hides Markdown syntax on the lines without the caret; it is put back from the lines' classes so
/// predictions see the document as written.
enum CodeMirrorReader {
    static func isEditor(_ element: AXElement) -> Bool {
        (element.raw("AXDOMClassList") as? [String])?.contains("cm-content") == true
    }

    private struct Line {
        var classes: Set<String>
        var text: String
        /// A task's checkbox, when the line is a task.
        var checked = false
    }

    /// The lines other than the caret's, kept while the editor's lines and the caret's line stay the
    /// same (typing within a line): one round trip per line otherwise.
    private static var cache: (editor: AXElement, lines: [AXElement], active: Int, read: [Int: Line], at: TimeInterval)?

    static func snapshot(of info: FieldInfo, prefixLimit: Int, suffixLimit: Int) -> FieldSnapshot? {
        let editor = info.element
        editor.setTimeout(0.3)
        let attrs = FieldReader.attributes(editor, ["AXSelectedTextMarkerRange", kAXChildrenAttribute,
                                                    kAXPositionAttribute, kAXSizeAttribute])
        guard let selectionValue = attrs["AXSelectedTextMarkerRange"],
              CFGetTypeID(selectionValue) == AXTextMarkerRangeGetTypeID(),
              let children = attrs[kAXChildrenAttribute] as? [AnyObject] else { return nil }
        let lines = children.compactMap { child -> AXElement? in
            CFGetTypeID(child) == AXUIElementGetTypeID() ? AXElement(child as! AXUIElement) : nil
        }
        let selection = selectionValue as! AXTextMarkerRange
        let caret = AXTextMarkerRangeCopyStartMarker(selection)
        let selectionEnd = AXTextMarkerRangeCopyEndMarker(selection)
        guard !lines.isEmpty, let active = lineIndex(of: caret, in: editor, lines: lines) else { return nil }

        let now = ProcessInfo.processInfo.systemUptime
        if let c = cache, c.editor != editor || c.lines != lines || c.active != active || now - c.at > 3 { cache = nil }
        var read = cache?.read ?? [:]
        func line(_ index: Int) -> Line? {
            if let known = read[index] { return known }
            guard let text = text(of: lines[index]) else { return nil }
            let classes = Set((lines[index].raw("AXDOMClassList") as? [String]) ?? [])
            var line = Line(classes: classes, text: text)
            if classes.contains("HyperMD-task-line") {
                line.checked = lines[index].children.first { $0.role == "AXCheckBox" }?.int(kAXValueAttribute) == 1
            }
            if index != active { read[index] = line }
            return line
        }

        // The caret's line, split at the caret.
        guard let current = line(active),
              let lineRange = lines[active].parameterized("AXTextMarkerRangeForUIElement", lines[active].ref),
              CFGetTypeID(lineRange) == AXTextMarkerRangeGetTypeID() else { return nil }
        let lineStart = AXTextMarkerRangeCopyStartMarker(lineRange as! AXTextMarkerRange)
        let lineEnd = AXTextMarkerRangeCopyEndMarker(lineRange as! AXTextMarkerRange)
        let head = string(from: lineStart, to: caret, in: editor) ?? ""
        let tail = string(from: selectionEnd, to: lineEnd, in: editor) ?? ""
        let selected = string(from: caret, to: selectionEnd, in: editor) ?? ""
        // A marker read that doesn't fit the line means the caret moved meanwhile.
        guard current.text.hasPrefix(head) || head.isEmpty else { return nil }
        let headText = cleaned(head).isEmpty ? "" : markdown(cleaned(head), classes: current.classes, checked: current.checked) ?? ""
        let tailText = headText.isEmpty
            ? markdown(cleaned(tail), classes: current.classes, checked: current.checked) ?? "" : cleaned(tail)

        // Lines before, back to a little more than the prefix window.
        var before: [String] = []
        var count = headText.utf16.count
        var index = active - 1
        while index >= 0, count < prefixLimit + 1024, active - index <= 400 {
            if let l = line(index), let text = markdown(cleaned(l.text), classes: l.classes, checked: l.checked) {
                before.append(text)
                count += text.utf16.count + 1
            }
            index -= 1
        }
        // Lines after, up to the suffix window.
        var after: [String] = []
        count = tailText.utf16.count
        index = active + 1
        while index < lines.count, count < suffixLimit, index - active <= 60 {
            if let l = line(index), let text = markdown(cleaned(l.text), classes: l.classes, checked: l.checked) {
                after.append(text)
                count += text.utf16.count + 1
            }
            index += 1
        }
        cache = (editor, lines, active, read, cache?.at ?? now)

        var prefix = (before.reversed() + [headText]).joined(separator: "\n")
        var suffix = ([tailText] + after).joined(separator: "\n")
        // Same window as plain fields: the start moves in 1024-unit steps so the prompt cache holds.
        let prefixNS = prefix as NSString
        if prefixNS.length > prefixLimit {
            let start = safeBoundary(prefixNS, ((prefixNS.length - prefixLimit) / 1024) * 1024)
            prefix = prefixNS.substring(from: start)
        }
        let suffixNS = suffix as NSString
        if suffixNS.length > suffixLimit {
            suffix = suffixNS.substring(to: safeBoundary(suffixNS, suffixLimit))
        }

        var fieldFrame: CGRect?
        if let p = attrs[kAXPositionAttribute], let s = attrs[kAXSizeAttribute] {
            var origin = CGPoint.zero, size = CGSize.zero
            AXValueGetValue(p as! AXValue, .cgPoint, &origin)
            AXValueGetValue(s as! AXValue, .cgSize, &size)
            fieldFrame = CGRect(origin: origin, size: size)
        }
        let location = (prefix as NSString).length
        let length = (selected as NSString).length
        return FieldSnapshot(info: info, prefix: prefix, suffix: suffix,
                             selection: CFRange(location: location, length: length),
                             totalLength: location + length + (suffix as NSString).length, fieldFrame: fieldFrame)
    }

    /// The bounds of `length` UTF-16 units starting `distance` units before the caret (a word just
    /// typed), stepping through text markers: the editor's own offsets can't be trusted.
    static func bounds(before distance: Int, length: Int, in editor: AXElement) -> CGRect? {
        guard distance >= length, distance <= 64,
              let value = editor.raw("AXSelectedTextMarkerRange"), CFGetTypeID(value) == AXTextMarkerRangeGetTypeID() else {
            return nil
        }
        var marker = AXTextMarkerRangeCopyStartMarker(value as! AXTextMarkerRange)
        var end: AXTextMarker?
        for step in 0..<distance {
            if step == distance - length { end = marker }
            guard let previous = editor.parameterized("AXPreviousTextMarkerForTextMarker", marker),
                  CFGetTypeID(previous) == AXTextMarkerGetTypeID() else { return nil }
            marker = previous as! AXTextMarker
        }
        guard let end, let bounds = editor.parameterized("AXBoundsForTextMarkerRange",
                                                         AXTextMarkerRangeCreate(kCFAllocatorDefault, marker, end)),
              CFGetTypeID(bounds) == AXValueGetTypeID() else { return nil }
        var rect = CGRect.zero
        return AXValueGetValue(bounds as! AXValue, .cgRect, &rect) ? rect : nil
    }

    // MARK: Lines

    /// The editor line holding the caret: the element its text belongs to, up to a child of the editor.
    private static func lineIndex(of caret: AXTextMarker, in editor: AXElement, lines: [AXElement]) -> Int? {
        if let value = editor.parameterized("AXUIElementForTextMarker", caret), CFGetTypeID(value) == AXUIElementGetTypeID() {
            var element = AXElement(value as! AXUIElement)
            for _ in 0..<12 {
                if let index = lines.firstIndex(of: element) { return index }
                guard let parent = element.parent, parent != editor else { break }
                element = parent
            }
        }
        // CodeMirror marks the caret's line (Obsidian "cm-active", the stock extension "cm-activeLine").
        return lines.firstIndex { line in
            let classes = (line.raw("AXDOMClassList") as? [String]) ?? []
            return classes.contains("cm-active") || classes.contains("cm-activeLine")
        }
    }

    private static func text(of line: AXElement) -> String? {
        guard let range = line.parameterized("AXTextMarkerRangeForUIElement", line.ref),
              CFGetTypeID(range) == AXTextMarkerRangeGetTypeID() else { return nil }
        return line.parameterized("AXStringForTextMarkerRange", range) as? String
    }

    private static func string(from start: AXTextMarker, to end: AXTextMarker, in element: AXElement) -> String? {
        element.parameterized("AXStringForTextMarkerRange", AXTextMarkerRangeCreate(kCFAllocatorDefault, start, end)) as? String
    }

    private static func safeBoundary(_ ns: NSString, _ index: Int) -> Int {
        guard index > 0, index < ns.length else { return index }
        return ns.rangeOfComposedCharacterSequence(at: index).location
    }

    // MARK: Markdown

    /// Widget placeholders (checkboxes, embeds, folded syntax) and an empty line's break, removed.
    static func cleaned(_ text: String) -> String {
        var scalars = String.UnicodeScalarView()
        scalars.append(contentsOf: text.unicodeScalars.filter {
            $0 != "\u{200B}" && $0 != "\u{FEFF}" && $0 != "\u{FFFC}" && $0 != "\u{2060}"
        })
        var result = String(scalars)
        while result.last?.isNewline == true { result.removeLast() }
        return result
    }

    /// A line as Markdown: the syntax Live Preview drew as widgets put back. Nil for lines that
    /// carry no text of the document (placeholders for lines scrolled far away).
    static func markdown(_ text: String, classes: Set<String>, checked: Bool = false) -> String? {
        if classes.contains("cm-gap") { return nil }
        if classes.contains("hr") { return "---" }
        if classes.contains(where: { $0.hasSuffix("-embed") }) {
            let title = text.split(whereSeparator: \.isNewline).first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
            return title.isEmpty ? nil : "![[\(title)]]"
        }
        let indentEnd = text.firstIndex { $0 != "\t" && $0 != " " } ?? text.endIndex
        let indent = text[..<indentEnd].filter { $0 == "\t" }
        let body = text[indentEnd...]
        if let level = level(in: classes, prefix: "HyperMD-header-"), !body.hasPrefix("#") {
            return String(repeating: "#", count: level) + " " + body
        }
        if classes.contains("HyperMD-task-line"), !startsWithListMarker(body) {
            return indent + (checked ? "- [x] " : "- [ ] ") + body
        }
        if classes.contains("HyperMD-quote"), !body.hasPrefix(">") {
            return "> " + body
        }
        return text
    }

    private static func level(in classes: Set<String>, prefix: String) -> Int? {
        for c in classes where c.hasPrefix(prefix) {
            if let n = Int(c.dropFirst(prefix.count)), (1...6).contains(n) { return n }
        }
        return nil
    }

    private static func startsWithListMarker(_ text: Substring) -> Bool {
        if text.hasPrefix("- ") || text.hasPrefix("* ") || text.hasPrefix("+ ") { return true }
        let digits = text.prefix { $0.isNumber }
        return !digits.isEmpty && (text.dropFirst(digits.count).hasPrefix(". ") || text.dropFirst(digits.count).hasPrefix(") "))
    }
}
