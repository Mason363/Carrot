import AppKit
import ApplicationServices

/// Facts about a focused text field that don't change while the user types in it.
struct FieldInfo: Equatable {
    let element: AXElement
    let pid: pid_t
    let bundleID: String?
    let appName: String?
    let role: String?
    let subrole: String?
    let isSecure: Bool
    let isSearch: Bool
    let isSingleLine: Bool
    let label: String?
    let windowTitle: String?
    let url: String?
    let domain: String?
    /// Inside a web view (browser, Electron, WebKit-based editors): text follows CSS line boxes.
    let isWebContent: Bool
    /// An editable web area (Mail compose, designMode pages) that only speaks in text markers.
    var usesTextMarkers = false
    /// The engine drawing the text, for its caret-geometry rules.
    var engine = TextEngine.native
    /// Rich text (contenteditable) rather than a form control: its lines live in the element's own boxes.
    var isRichText = false
    /// The scroll view showing the field, which bounds where its text can be seen.
    var scrollArea: AXElement?
    /// Google Docs draws its text on a canvas; with its braille support on, the focused (off-screen)
    /// text area holds the document's text, and the visible caret is a separate element.
    var isGoogleDocs: Bool { domain == "docs.google.com" }

    static func == (lhs: FieldInfo, rhs: FieldInfo) -> Bool { lhs.element == rhs.element }
}

/// The text and geometry around the caret at one moment.
struct FieldSnapshot {
    let info: FieldInfo
    /// Text before the caret (bounded window).
    let prefix: String
    /// Text after the caret / selection (bounded window).
    let suffix: String
    /// UTF-16 selection in the full text.
    let selection: CFRange
    let totalLength: Int
    /// Caret rectangle in AX (top-left origin) coordinates; width is 0.
    var caret: CGRect?
    var caretIsEstimated = false
    var fontName: String?
    var fontSize: CGFloat?
    var textColor: CGColor?
    /// The last few characters before the caret and their on-screen width, to detect zoomed views
    /// (the app reports the document's font size, not the size it's drawn at).
    var sampleText: String?
    var sampleWidth: CGFloat?
    /// Field frame in AX coordinates.
    var fieldFrame: CGRect?
    /// The collapsed caret rectangle exactly as a web engine reported it (whole points), when the
    /// caret came from one; the engine's rules recover where the text really is from it.
    var reportedCaret: CGRect?
    /// The caret's line continues a paragraph started on an earlier line (WebKit measures such
    /// carets from the previous line's text).
    var laterLineInBlock = false
    /// The caret rectangle at the start of the caret's line, as reported, and the text from there to
    /// the caret: with the font, they give the caret's x more precisely than the rounded caret box.
    var lineStart: CGRect?
    var lineText: String?
    /// WebKit: the whole-point box of the text run the caret follows (single line, on the caret's line).
    var textBox: CGRect?
    /// Chromium: the box of the caret's line from its start to the caret, as reported.
    var lineBox: CGRect?
    /// Top of the visual line above the caret's (AX y), to measure the line pitch for wrapping.
    var previousLineTop: CGFloat?
    /// The part of the screen where the field's text is visible (its scroll view), AX coordinates.
    var visibleFrame: CGRect?
    /// The caret came from Google Docs' own caret element over its canvas (no text geometry).
    var isCanvasCaret = false
    let timestamp = ProcessInfo.processInfo.systemUptime

    var hasSelection: Bool { selection.length > 0 }
    /// Text after the caret on the same line.
    var lineSuffix: Substring {
        suffix.prefix(while: { !$0.isNewline })
    }
}

/// Reads fields through the Accessibility API. Call only on `AXQueue`.
enum FieldReader {
    static let prefixLimit = 6000
    static let suffixLimit = 1200
    private static let editableRoles: Set<String> = ["AXTextArea", "AXTextField", "AXComboBox", "AXSearchField"]

    /// The element that has keyboard focus, system-wide.
    static func focusedElement() -> AXElement? {
        let system = AXElement.systemWide
        system.setTimeout(0.25)
        if let element = system.element(kAXFocusedUIElementAttribute) { return focusedText(in: element) }
        // Some apps answer only through their application element.
        if let app = NSWorkspace.shared.frontmostApplication {
            let appElement = AXElement.application(pid: app.processIdentifier)
            appElement.setTimeout(0.25)
            return appElement.element(kAXFocusedUIElementAttribute).map(focusedText(in:))
        }
        return nil
    }

    private static let containerRoles: Set<String> = ["AXScrollArea", "AXLayoutArea", "AXGroup", "AXSplitGroup"]

    /// Some apps (Pages, Keynote) report the document's scroll area as focused; the text area that
    /// really holds the caret is a descendant that says it's focused.
    private static var containerSearch: (container: AXElement, result: AXElement, at: TimeInterval)?

    static func focusedText(in element: AXElement) -> AXElement {
        guard element.raw(kAXSelectedTextRangeAttribute) == nil,
              let role = element.role, containerRoles.contains(role) else { return element }
        // The focus poll asks every 0.6 s; while focus rests on the same container, reuse the answer.
        let now = ProcessInfo.processInfo.systemUptime
        if let cached = containerSearch, cached.container == element, now - cached.at < 3 { return cached.result }
        let result = searchFocusedText(in: element)
        containerSearch = (element, result, now)
        return result
    }

    private static func searchFocusedText(in element: AXElement) -> AXElement {
        var queue: [(AXElement, Int)] = [(element, 0)]
        var visited = 0
        while !queue.isEmpty, visited < 400 {
            let (current, depth) = queue.removeFirst()
            visited += 1
            if current != element, current.bool(kAXFocusedAttribute) == true,
               current.raw(kAXSelectedTextRangeAttribute) != nil {
                return current
            }
            if depth < 8 { queue.append(contentsOf: current.children.map { ($0, depth + 1) }) }
        }
        return element
    }

    static func focusedElement(inApp pid: pid_t) -> AXElement? {
        let appElement = AXElement.application(pid: pid)
        appElement.setTimeout(0.25)
        if let element = appElement.element(kAXFocusedUIElementAttribute) {
            let text = focusedText(in: element)
            if text.raw(kAXSelectedTextRangeAttribute) != nil || text.raw("AXSelectedTextMarkerRange") != nil
                || TestBench.observedBundleID == nil { return text }
        }
        // Background apps (observe mode) don't report a focused element; look for one that says it is.
        guard TestBench.observedBundleID != nil else { return nil }
        var queue = appElement.elements(kAXWindowsAttribute)
        var visited = 0
        while !queue.isEmpty, visited < 5000 {
            let element = queue.removeFirst()
            visited += 1
            if element.bool(kAXFocusedAttribute) == true, element.raw(kAXSelectedTextRangeAttribute) != nil {
                return element
            }
            queue.append(contentsOf: element.children)
        }
        return nil
    }

    /// Batch-reads several attributes in one IPC round trip.
    static func attributes(_ element: AXElement, _ names: [String]) -> [String: CFTypeRef] {
        var values: CFArray?
        let error = AXUIElementCopyMultipleAttributeValues(element.ref, names as CFArray, [], &values)
        guard error == .success, let array = values as? [AnyObject] else { return [:] }
        var result: [String: CFTypeRef] = [:]
        for (name, value) in zip(names, array) {
            // Errors come back as AXValue of type .axError.
            if CFGetTypeID(value) == AXValueGetTypeID(), AXValueGetType(value as! AXValue) == .axError { continue }
            if value is NSNull { continue }
            result[name] = value
        }
        return result
    }

    static func info(for element: AXElement) -> FieldInfo? {
        element.setTimeout(0.3)
        let attrs = attributes(element, [
            kAXRoleAttribute, kAXSubroleAttribute, kAXSelectedTextRangeAttribute, kAXPlaceholderValueAttribute,
            kAXTitleAttribute, kAXDescriptionAttribute, "AXEditableAncestor", kAXWindowAttribute,
        ])
        let role = attrs[kAXRoleAttribute] as? String
        let subrole = attrs[kAXSubroleAttribute] as? String
        let hasSelectionRange = attrs[kAXSelectedTextRangeAttribute] != nil
        let editableAncestor = attrs["AXEditableAncestor"] != nil
        let isEditableRole = role.map(editableRoles.contains) ?? false
        // A whole editable web document (Mail's compose body) has no plain ranges, only text markers.
        let markerDocument = !hasSelectionRange && role == "AXWebArea"
            && element.raw("AXSelectedTextMarkerRange") != nil && element.isSettable(kAXValueAttribute)
        guard markerDocument || (hasSelectionRange && (isEditableRole || editableAncestor || element.isSettable(kAXValueAttribute))) else {
            return nil
        }
        let pid = element.pid ?? 0
        let app = NSRunningApplication(processIdentifier: pid)
        let isSecure = subrole == kAXSecureTextFieldSubrole || role == "AXSecureTextField"
        let isSearch = subrole == kAXSearchFieldSubrole || role == "AXSearchField"

        var label = (attrs[kAXPlaceholderValueAttribute] as? String) ?? (attrs[kAXTitleAttribute] as? String)
        if label?.isEmpty ?? true { label = attrs[kAXDescriptionAttribute] as? String }
        if label?.isEmpty ?? true, let titleElement = element.element(kAXTitleUIElementAttribute) {
            label = titleElement.string(kAXValueAttribute) ?? titleElement.string(kAXTitleAttribute)
        }

        var windowTitle: String?
        if let windowValue = attrs[kAXWindowAttribute], CFGetTypeID(windowValue) == AXUIElementGetTypeID() {
            windowTitle = AXElement(windowValue as! AXUIElement).string(kAXTitleAttribute)
        }
        let webArea = markerDocument ? element : element.ancestor(maxDepth: 40, where: { $0.role == "AXWebArea" })
        // Site rules follow the page in the address bar, not an editor embedded in a frame of it.
        let url = webArea.flatMap(pageURL(from:))
        let domain = url.flatMap { URL(string: $0)?.host }.map { $0.hasPrefix("www.") ? String($0.dropFirst(4)) : $0 }

        var info = FieldInfo(
            element: element, pid: pid, bundleID: app?.bundleIdentifier, appName: app?.localizedName,
            role: role, subrole: subrole, isSecure: isSecure, isSearch: isSearch,
            isSingleLine: role == "AXTextField" || role == "AXComboBox" || role == "AXSearchField",
            label: label?.trimmingCharacters(in: .whitespacesAndNewlines),
            windowTitle: windowTitle, url: url, domain: domain, isWebContent: webArea != nil)
        info.usesTextMarkers = markerDocument
        if !info.isSingleLine {
            info.scrollArea = (role == "AXScrollArea" ? nil : element.ancestor(maxDepth: 8, where: { $0.role == "AXScrollArea" }))
        }
        if webArea != nil {
            info.engine = TextEngine.webEngine(for: app)
            info.isRichText = markerDocument || isWebRichText(element, role: role)
        }
        return info
    }

    /// Whether a web text field is rich text (contenteditable) rather than a form control. Form
    /// controls answer the selected text with a string (empty for a bare caret); rich text has none
    /// for a bare caret. With a real selection both answer, and children tell them apart instead: an
    /// input has none, a textarea one empty inner box.
    private static func isWebRichText(_ element: AXElement, role: String?) -> Bool {
        if role == "AXTextField" || role == "AXSearchField" || role == "AXComboBox" { return false }
        guard let selected = element.raw(kAXSelectedTextAttribute) else { return true }
        if let text = selected as? String, text.isEmpty { return false }
        let children = element.children
        guard children.count == 1, let child = children.first, child.role == "AXGroup" else { return !children.isEmpty }
        return !child.children.allSatisfy { $0.role == "AXStaticText" } || child.children.count > 1
    }

    /// The URL of the outermost web page containing `webArea` (frames nest web areas).
    static func pageURL(from webArea: AXElement) -> String? {
        var best = webURL(of: webArea).flatMap { URL(string: $0)?.host != nil ? $0 : nil }
        var current = webArea.parent
        var depth = 0
        while let element = current, depth < 60 {
            if element.role == "AXWebArea", let url = webURL(of: element), URL(string: url)?.host != nil { best = url }
            current = element.parent
            depth += 1
        }
        return best ?? webURL(of: webArea)
    }

    /// The URL of a web area.
    static func webURL(of webArea: AXElement) -> String? {
        if let url = webArea.raw(kAXURLAttribute) {
            if let u = url as? URL { return u.absoluteString }
            if let s = url as? String { return s }
        }
        return nil
    }

    /// Reads the text around the caret plus caret geometry.
    static func snapshot(of info: FieldInfo, cached: CachedGeometry? = nil) -> FieldSnapshot? {
        if info.usesTextMarkers { return markerSnapshot(of: info, cached: cached) }
        let element = info.element
        element.setTimeout(0.3)
        let attrs = attributes(element, [
            kAXSelectedTextRangeAttribute, kAXNumberOfCharactersAttribute, kAXPositionAttribute, kAXSizeAttribute,
        ])
        guard let rangeValue = attrs[kAXSelectedTextRangeAttribute], CFGetTypeID(rangeValue) == AXValueGetTypeID() else {
            return nil
        }
        var selection = CFRange()
        guard AXValueGetValue(rangeValue as! AXValue, .cfRange, &selection), selection.location >= 0 else { return nil }

        var fieldFrame: CGRect?
        if let p = attrs[kAXPositionAttribute], let s = attrs[kAXSizeAttribute] {
            var origin = CGPoint.zero, size = CGSize.zero
            AXValueGetValue(p as! AXValue, .cgPoint, &origin)
            AXValueGetValue(s as! AXValue, .cgSize, &size)
            fieldFrame = CGRect(origin: origin, size: size)
        }

        // Text: read the whole value when it's small, otherwise just a window around the caret.
        let reportedLength = (attrs[kAXNumberOfCharactersAttribute] as? NSNumber)?.intValue
        var prefix = ""
        var suffix = ""
        var total = reportedLength ?? 0
        let caret = selection.location
        let end = selection.location + selection.length
        // The window start is aligned to 1024-unit blocks so it doesn't slide with every keystroke
        // (a sliding start would invalidate the model's prompt cache).
        let alignedStart = max(0, ((caret - prefixLimit) / 1024) * 1024)
        if reportedLength == nil || reportedLength! <= 30_000 {
            guard let value = element.string(kAXValueAttribute) else { return nil }
            let ns = value as NSString
            total = ns.length
            guard end <= total else { return nil }
            let start = safeBoundary(ns, alignedStart)
            prefix = ns.substring(with: NSRange(location: start, length: caret - start))
            let stop = safeBoundary(ns, min(total, end + suffixLimit))
            suffix = ns.substring(with: NSRange(location: end, length: max(0, stop - end)))
        } else {
            guard end <= total else { return nil }
            let start = alignedStart
            // A failed read is a failed snapshot, never an empty field (that would look like "sent").
            if caret > start {
                guard let text = element.string(for: CFRange(location: start, length: caret - start)) else { return nil }
                prefix = text
            }
            let length = min(total - end, suffixLimit)
            if length > 0 {
                guard let text = element.string(for: CFRange(location: end, length: length)) else { return nil }
                suffix = text
            }
            // A window edge can split a surrogate pair; Swift turns the lone half into U+FFFD.
            if prefix.unicodeScalars.first == "\u{FFFD}" { prefix.unicodeScalars.removeFirst() }
            if suffix.unicodeScalars.last == "\u{FFFD}" { suffix.unicodeScalars.removeLast() }
        }

        var snapshot = FieldSnapshot(info: info, prefix: prefix, suffix: suffix, selection: selection, totalLength: total,
                                     fieldFrame: fieldFrame)
        if selection.length == 0 {
            if info.isGoogleDocs, let frame = fieldFrame, frame.maxY < -1000 {
                // The text area is parked far off-screen: everything visible comes from Docs' caret.
                googleDocsCaret(&snapshot, element: element)
            } else {
                locateCaret(&snapshot, element: element, cached: cached)
                snapshot.visibleFrame = visibleFrame(of: info, fieldFrame: fieldFrame)
            }
        }
        return snapshot
    }

    /// Geometry that is expensive to query and rarely changes.
    struct CachedGeometry {
        var fontName: String?
        var fontSize: CGFloat?
        var textColor: CGColor?
        var sampleText: String?
        var sampleWidth: CGFloat?
        var queriedAt: TimeInterval
    }

    private static func safeBoundary(_ ns: NSString, _ index: Int) -> Int {
        guard index > 0, index < ns.length else { return index }
        return ns.rangeOfComposedCharacterSequence(at: index).location
    }

    // MARK: Google Docs

    /// Docs' visible caret for the current user (collaborators' carets have other ids), and the
    /// editor around it; found once per window and then only re-read.
    private static var docsCaretCache: (window: AXElement, caret: AXElement, editor: AXElement?)?
    static let docsCaretIdentifier = "kix-current-user-cursor-caret"

    private static func docsCaretElements(for element: AXElement) -> (caret: AXElement, editor: AXElement?)? {
        guard let window = element.window else { return nil }
        if let cached = docsCaretCache, cached.window == window,
           cached.caret.string("AXDOMIdentifier") == docsCaretIdentifier {
            return (cached.caret, cached.editor)
        }
        var queue = [window]
        var index = 0
        while index < queue.count, index < 4000 {
            let current = queue[index]
            index += 1
            if current.string("AXDOMIdentifier") == docsCaretIdentifier {
                let editor = current.ancestor(maxDepth: 8) { $0.string("AXDOMIdentifier") == "kix-appview" }
                docsCaretCache = (window, current, editor)
                return (current, editor)
            }
            queue.append(contentsOf: current.children)
        }
        return nil
    }

    private static func googleDocsCaret(_ snapshot: inout FieldSnapshot, element: AXElement) {
        guard let (caretElement, editor) = docsCaretElements(for: element), let caret = caretElement.frame,
              caret.height >= 4, caret.height < 200 else {
            docsCaretCache = nil
            return
        }
        let editorFrame = editor?.frame
        // Hidden while the caret is scrolled out of the editor.
        if let editorFrame, !editorFrame.insetBy(dx: -2, dy: -2).contains(CGPoint(x: caret.minX, y: caret.midY)) { return }
        snapshot.caret = CGRect(x: caret.minX, y: caret.minY, width: 0, height: caret.height)
        snapshot.isCanvasCaret = true
        snapshot.fieldFrame = editorFrame
        snapshot.visibleFrame = editorFrame
        // The font: Docs reports the family (its size is rounded); the size follows from the caret.
        let location = snapshot.selection.location
        if location > 0, let attributed = element.attributedString(for: CFRange(location: location - 1, length: 1)),
           attributed.length > 0,
           let font = attributed.attributes(at: 0, effectiveRange: nil)[NSAttributedString.Key(rawValue: "AXFont")] as? [String: Any] {
            snapshot.fontName = (font["AXFontName"] as? String) ?? (font["AXFontFamily"] as? String)
            snapshot.fontSize = (font["AXFontSize"] as? NSNumber).map { CGFloat($0.doubleValue) }
        }
        snapshot.fontName = snapshot.fontName ?? "Arial"
        snapshot.fontSize = docsFontSize(caretHeight: caret.height, family: snapshot.fontName!, reported: snapshot.fontSize)
    }

    /// Docs sizes text in points (at 4/3 px each) and makes its caret as tall as the font's
    /// ascent plus descent, rounded up. Of the sizes that fit the caret, the one nearest what Docs
    /// reported wins.
    static func docsFontSize(caretHeight: CGFloat, family: String, reported: CGFloat?) -> CGFloat {
        let sizes: [CGFloat] = [6, 7, 8, 9, 10, 10.5, 11, 12, 13, 14, 15, 16, 18, 20, 22, 24, 26, 28, 30, 32, 36, 40, 48, 60, 72, 96]
        let probe = NSFont(name: family, size: 100) ?? NSFontManager.shared.font(withFamily: family, traits: [], weight: 5, size: 100)
            ?? NSFont.systemFont(ofSize: 100)
        let extent = (probe.ascender - probe.descender) / 100
        let fitting = sizes.map { $0 * 4 / 3 }.filter { abs(($0 * extent).rounded(.up) - caretHeight.rounded()) <= 0.5 }
        if let reported, let nearest = fitting.min(by: { abs($0 - reported) < abs($1 - reported) }) { return nearest }
        if let first = fitting.first { return first }
        return caretHeight / max(extent, 0.5)
    }

    /// Whether `element` is Docs' hidden input in its default mode (no text exposed): Foreword can
    /// do nothing there until braille support is turned on.
    static func isUnreadableGoogleDocs(_ element: AXElement) -> Bool {
        guard let frame = element.frame, frame.maxY < -1000, element.raw(kAXSelectedTextRangeAttribute) == nil,
              element.raw("AXSelectedTextMarkerRange") != nil,
              let webArea = element.ancestor(maxDepth: 40, where: { $0.role == "AXWebArea" }),
              let url = webURL(of: webArea), URL(string: url)?.host == "docs.google.com" else { return false }
        return true
    }

    /// The visible Docs caret near `element`, for pointing at it (hints).
    static func googleDocsCaretRect(near element: AXElement) -> CGRect? {
        docsCaretElements(for: element)?.caret.frame
    }

    /// Where the field's text can be seen: its frame clipped to the scroll view around it.
    private static func visibleFrame(of info: FieldInfo, fieldFrame: CGRect?) -> CGRect? {
        guard let fieldFrame else { return nil }
        guard let scroll = info.scrollArea?.frame, scroll.width > 0, scroll.height > 0 else { return fieldFrame }
        let clipped = fieldFrame.intersection(scroll)
        return clipped.isNull || clipped.isEmpty ? fieldFrame : clipped
    }

    /// Tabs, attachments and control characters take up space that isn't the font's: such text
    /// can't calibrate size or identify the face.
    static func containsLayoutCharacters(_ text: String) -> Bool {
        text.unicodeScalars.contains { $0 == "\t" || $0 == "\u{FFFC}" || $0.properties.generalCategory == .control }
    }

    /// Records the start of the caret's line and the text from there to the caret (the last
    /// `length` UTF-16 units of the prefix), when that text is all on this line.
    private static func setLine(_ snapshot: inout FieldSnapshot, start: CGRect, length: Int) {
        guard let caret = snapshot.caret, abs(start.minY - caret.minY) < caret.height * 0.5, length > 0 else { return }
        let units = Array(snapshot.prefix.utf16)
        guard length <= units.count, length <= 400 else { return }
        guard let text = String(utf16CodeUnits: Array(units[(units.count - length)...]), count: length) as String?,
              !text.contains(where: \.isNewline), !text.contains("\t") else { return }
        snapshot.lineStart = start
        snapshot.lineText = text
    }

    /// Whether the caret's line continues a paragraph from an earlier line: a soft wrap, or any line
    /// after the first in a form control (which is a single paragraph box).
    private static func continuesParagraph(_ snapshot: FieldSnapshot, lineStart: Int, caret: Int) -> Bool {
        let prefix = Array(snapshot.prefix.utf16)
        let back = caret - lineStart + 1
        guard back > 0 else { return false }
        guard back <= prefix.count else { return true } // a line longer than the window: wrapped
        let unit = prefix[prefix.count - back]
        let hardBreak = unit == 0x0A || unit == 0x0D || unit == 0x2028 || unit == 0x2029
        // Rich text starts a new box at every hard break.
        return !hardBreak || !snapshot.info.isRichText
    }

    /// The frame of the text run holding `marker`, when it is a single line on the caret's line.
    private static func textRunBox(after marker: AXTextMarker, in element: AXElement, caret: CGRect?) -> CGRect? {
        guard let caret, let value = element.parameterized("AXUIElementForTextMarker", marker),
              CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        let text = AXElement(value as! AXUIElement)
        guard text.role == "AXStaticText", let box = text.frame, box.height >= 4,
              box.height < caret.height * 1.6, abs(box.minY - caret.minY) <= 1.5 else { return nil }
        return box
    }

    /// Top of the visual line before the one starting at `lineStart`, through text markers.
    private static func previousLineTop(before lineStart: AXTextMarker, in element: AXElement, below caret: CGRect?,
                                        frame: CGRect?) -> CGFloat? {
        guard let caret,
              let value = element.parameterized("AXPreviousLineStartTextMarkerForTextMarker", lineStart),
              CFGetTypeID(value) == AXTextMarkerGetTypeID() else { return nil }
        let start = value as! AXTextMarker
        guard let nextValue = element.parameterized("AXNextTextMarkerForTextMarker", start),
              CFGetTypeID(nextValue) == AXTextMarkerGetTypeID(),
              let r = validRect(bounds(markerRange(start, nextValue as! AXTextMarker), in: element), near: frame),
              r.minY < caret.minY - 1 else { return nil }
        return r.minY
    }

    /// Chromium's rich text (contenteditable) has no range-based geometry; the selection, the line
    /// so far and the font are reachable through text markers instead.
    private static func blinkMarkerCaret(_ snapshot: inout FieldSnapshot, element: AXElement, needCaret: Bool) -> Bool {
        guard let value = element.raw("AXSelectedTextMarkerRange"), CFGetTypeID(value) == AXTextMarkerRangeGetTypeID() else {
            return false
        }
        let selection = value as! AXTextMarkerRange
        let caretMarker = AXTextMarkerRangeCopyStartMarker(selection)
        let frame = snapshot.fieldFrame
        var previousRange: AXTextMarkerRange?
        if let previous = element.parameterized("AXPreviousTextMarkerForTextMarker", caretMarker),
           CFGetTypeID(previous) == AXTextMarkerGetTypeID() {
            previousRange = markerRange(previous as! AXTextMarker, caretMarker)
        }
        let previousIsBreak = snapshot.prefix.last.map { $0.isNewline } ?? true
        if !needCaret {
            // Form controls already answered by range.
        } else if let c = validRect(bounds(selection, in: element), near: frame), c.width <= 3 {
            snapshot.caret = CGRect(x: c.minX, y: c.minY, width: 0, height: c.height)
            snapshot.reportedCaret = c
        } else if !previousIsBreak, let range = previousRange, let r = validRect(bounds(range, in: element), near: frame) {
            snapshot.caret = CGRect(x: r.maxX, y: r.minY, width: 0, height: r.height)
            snapshot.reportedCaret = CGRect(x: r.maxX, y: r.minY, width: 0, height: r.height)
        } else {
            return false
        }
        snapshot.caretIsEstimated = false
        // The line so far: Chromium names only the font size, and this width identifies the face.
        if let left = element.parameterized("AXLeftLineTextMarkerRangeForTextMarker", caretMarker),
           CFGetTypeID(left) == AXTextMarkerRangeGetTypeID() {
            let line = left as! AXTextMarkerRange
            if let text = string(line, in: element), !text.isEmpty, !text.contains(where: \.isNewline),
               let r = validRect(bounds(line, in: element), near: frame), let caret = snapshot.caret,
               abs(r.minY - caret.minY) < caret.height * 0.5, abs(r.height - caret.height) < caret.height * 0.5 {
                if text.count >= 4, !containsLayoutCharacters(text) {
                    snapshot.sampleText = text
                    snapshot.sampleWidth = r.width
                }
                if !text.contains("\t"), text.utf16.count <= 400 {
                    snapshot.lineStart = CGRect(x: r.minX, y: r.minY, width: 0, height: r.height)
                    snapshot.lineText = text
                    snapshot.lineBox = r
                }
            }
            snapshot.previousLineTop = previousLineTop(before: AXTextMarkerRangeCopyStartMarker(line), in: element,
                                                       below: snapshot.caret, frame: frame)
        }
        if let range = previousRange,
           let attributed = element.parameterized("AXAttributedStringForTextMarkerRange", range) as? NSAttributedString,
           attributed.length > 0 {
            let attrs = attributed.attributes(at: 0, effectiveRange: nil)
            if let font = attrs[NSAttributedString.Key(rawValue: "AXFont")] as? [String: Any] {
                snapshot.fontName = (font["AXFontName"] as? String) ?? (font["AXFontFamily"] as? String)
                snapshot.fontSize = (font["AXFontSize"] as? NSNumber).map { CGFloat($0.doubleValue) }
            }
            if let color = attrs[NSAttributedString.Key(rawValue: "AXForegroundColor")],
               CFGetTypeID(color as CFTypeRef) == CGColor.typeID {
                snapshot.textColor = (color as! CGColor)
            }
        }
        return true
    }

    // MARK: Text-marker documents

    private static func marker(at index: Int, in element: AXElement) -> AXTextMarker? {
        guard let value = element.parameterized("AXTextMarkerForIndex", index as CFNumber),
              CFGetTypeID(value) == AXTextMarkerGetTypeID() else { return nil }
        return (value as! AXTextMarker)
    }

    private static func index(of marker: AXTextMarker, in element: AXElement) -> Int? {
        (element.parameterized("AXIndexForTextMarker", marker) as? NSNumber)?.intValue
    }

    private static func markerRange(_ start: AXTextMarker, _ end: AXTextMarker) -> AXTextMarkerRange {
        AXTextMarkerRangeCreate(kCFAllocatorDefault, start, end)
    }

    private static func string(_ range: AXTextMarkerRange, in element: AXElement) -> String? {
        element.parameterized("AXStringForTextMarkerRange", range) as? String
    }

    private static func bounds(_ range: AXTextMarkerRange, in element: AXElement) -> CGRect? {
        guard let value = element.parameterized("AXBoundsForTextMarkerRange", range),
              CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var rect = CGRect.zero
        return AXValueGetValue(value as! AXValue, .cgRect, &rect) ? rect : nil
    }

    /// Snapshot of an editable web document addressed through text markers (Mail's compose body).
    static func markerSnapshot(of info: FieldInfo, cached: CachedGeometry?) -> FieldSnapshot? {
        let element = info.element
        element.setTimeout(0.3)
        guard let selectionValue = element.raw("AXSelectedTextMarkerRange"),
              CFGetTypeID(selectionValue) == AXTextMarkerRangeGetTypeID() else { return nil }
        let selection = selectionValue as! AXTextMarkerRange
        let caretMarker = AXTextMarkerRangeCopyStartMarker(selection)
        let selectionEnd = AXTextMarkerRangeCopyEndMarker(selection)
        guard let caret = index(of: caretMarker, in: element), let end = index(of: selectionEnd, in: element),
              let docEndValue = element.raw("AXEndTextMarker"), CFGetTypeID(docEndValue) == AXTextMarkerGetTypeID(),
              let total = index(of: docEndValue as! AXTextMarker, in: element), caret >= 0, end >= caret, total >= end
        else { return nil }

        let start = max(0, ((caret - prefixLimit) / 1024) * 1024)
        var prefix = ""
        if caret > start {
            guard let startMarker = marker(at: start, in: element),
                  let text = string(markerRange(startMarker, caretMarker), in: element) else { return nil }
            prefix = text
        }
        var suffix = ""
        let stop = min(total, end + suffixLimit)
        if stop > end {
            guard let stopMarker = marker(at: stop, in: element),
                  let text = string(markerRange(selectionEnd, stopMarker), in: element) else { return nil }
            suffix = text
        }
        let frame = element.frame
        var snapshot = FieldSnapshot(info: info, prefix: prefix, suffix: suffix,
                                     selection: CFRange(location: caret, length: end - caret), totalLength: total,
                                     fieldFrame: frame)
        guard end == caret else { return snapshot }

        // Caret: the collapsed range, cross-checked against the previous character like elsewhere.
        let collapsed = validRect(bounds(selection, in: element), near: frame).flatMap { $0.width <= 3 ? $0 : nil }
        let previous = prefix.last
        let previousIsBreak = previous.map { $0.isNewline } ?? true
        var previousRange: AXTextMarkerRange?
        if caret > 0, let before = marker(at: caret - 1, in: element) { previousRange = markerRange(before, caretMarker) }
        if !previousIsBreak, let range = previousRange, let r = validRect(bounds(range, in: element), near: frame) {
            if let c = collapsed, abs(c.minY - r.minY) < r.height * 0.5 || c.minY > r.minY + r.height * 0.6 {
                snapshot.caret = CGRect(x: c.minX, y: c.minY, width: 0, height: c.height)
                snapshot.reportedCaret = c
                snapshot.textBox = textRunBox(after: AXTextMarkerRangeCopyStartMarker(range), in: element, caret: snapshot.caret)
            } else {
                snapshot.caret = CGRect(x: r.maxX, y: r.minY, width: 0, height: r.height)
            }
        } else if let c = collapsed {
            snapshot.caret = CGRect(x: c.minX, y: c.minY, width: 0, height: c.height)
            snapshot.reportedCaret = c
            snapshot.caretIsEstimated = previousIsBreak && caret > 0 ? false : snapshot.caretIsEstimated
        }
        if snapshot.reportedCaret != nil, caret > 0,
           let lineValue = element.parameterized("AXLineTextMarkerRangeForTextMarker", caretMarker),
           CFGetTypeID(lineValue) == AXTextMarkerRangeGetTypeID() {
            let startMarker = AXTextMarkerRangeCopyStartMarker(lineValue as! AXTextMarkerRange)
            if let lineStart = index(of: startMarker, in: element), lineStart <= caret {
                if lineStart > 0 { snapshot.laterLineInBlock = continuesParagraph(snapshot, lineStart: lineStart, caret: caret) }
                if let start = validRect(bounds(markerRange(startMarker, startMarker), in: element), near: frame), start.width <= 3 {
                    setLine(&snapshot, start: start, length: caret - lineStart)
                }
            }
            snapshot.previousLineTop = previousLineTop(before: startMarker, in: element, below: snapshot.caret, frame: frame)
        }
        snapshot.visibleFrame = visibleFrame(of: info, fieldFrame: frame)

        let now = ProcessInfo.processInfo.systemUptime
        if let cached, now - cached.queriedAt < 2 {
            snapshot.fontName = cached.fontName
            snapshot.fontSize = cached.fontSize
            snapshot.textColor = cached.textColor
        } else if let range = previousRange,
                  let attributed = element.parameterized("AXAttributedStringForTextMarkerRange", range) as? NSAttributedString,
                  attributed.length > 0 {
            let attrs = attributed.attributes(at: 0, effectiveRange: nil)
            if let font = attrs[NSAttributedString.Key(rawValue: "AXFont")] as? [String: Any] {
                snapshot.fontName = (font["AXFontName"] as? String) ?? (font["AXFontFamily"] as? String)
                snapshot.fontSize = (font["AXFontSize"] as? NSNumber).map { CGFloat($0.doubleValue) }
            }
            if let color = attrs[NSAttributedString.Key(rawValue: "AXForegroundColor")],
               CFGetTypeID(color as CFTypeRef) == CGColor.typeID {
                snapshot.textColor = (color as! CGColor)
            }
        }
        return snapshot
    }

    // MARK: Caret

    private static func validRect(_ rect: CGRect?, near frame: CGRect?) -> CGRect? {
        guard let rect, rect.height >= 4, rect.height < 400, rect.origin.x.isFinite, rect.origin.y.isFinite else { return nil }
        if rect.origin == .zero && rect.width == 0 { return nil }
        if let frame, frame.width > 0, frame.height > 0 {
            // Allow some slack: carets sit on the field's padding edge, and scrolled content can overhang.
            let slack = frame.insetBy(dx: -40, dy: -40)
            guard slack.intersects(rect) else { return nil }
        }
        // Must be on some screen.
        let cocoa = ScreenGeometry.cocoaRect(fromAX: rect)
        guard NSScreen.screens.contains(where: { $0.frame.insetBy(dx: -2, dy: -2).intersects(cocoa) }) else { return nil }
        return rect
    }

    private static func locateCaret(_ snapshot: inout FieldSnapshot, element: AXElement, cached: CachedGeometry?) {
        let location = snapshot.selection.location
        let frame = snapshot.fieldFrame
        let previous = snapshot.prefix.last
        let next = snapshot.suffix.first
        let previousIsBreak = previous.map { $0.isNewline } ?? true
        let previousLength = snapshot.prefix.last.map { String($0).utf16.count } ?? 1

        // The character before the caret is the most reliable anchor across apps. A collapsed range is
        // used to detect soft wraps (caret already on the next visual line) — but some text systems
        // (TextKit 2) report collapsed ranges a line too high, so it only wins when it sits *below*.
        let engine = snapshot.info.engine
        let web = engine != .native
        let collapsed = validRect(element.bounds(for: CFRange(location: location, length: 0)), near: frame)
            .flatMap { $0.width <= 3 ? $0 : nil }
        if location > 0, !previousIsBreak,
           let r = validRect(element.bounds(for: CFRange(location: location - previousLength, length: previousLength)), near: frame) {
            if let c = collapsed, c.minY > r.minY + r.height * 0.6, abs(c.height - r.height) < r.height * 0.5 {
                snapshot.caret = CGRect(x: c.minX, y: c.minY, width: 0, height: c.height) // wrapped
                if web { snapshot.reportedCaret = c }
            } else if let c = collapsed, abs(c.minY - r.minY) < r.height * 0.5, abs(c.minX - r.maxX) < 6 {
                // Same line: the collapsed range is the precise caret (glyph boxes can overlap).
                snapshot.caret = CGRect(x: c.minX, y: r.minY, width: 0, height: r.height)
                if web { snapshot.reportedCaret = CGRect(x: c.minX, y: r.minY, width: c.width, height: r.height) }
            } else {
                snapshot.caret = CGRect(x: r.maxX, y: r.minY, width: 0, height: r.height)
                // Gecko has no collapsed caret box; its glyph boxes are exact to the device pixel.
                if engine == .gecko { snapshot.reportedCaret = snapshot.caret }
            }
        }
        // At the start of a line with text after the caret: that character's box is on the caret's line.
        if snapshot.caret == nil, let next, !next.isNewline,
           let r = validRect(element.bounds(for: CFRange(location: location, length: String(next).utf16.count)), near: frame) {
            snapshot.caret = CGRect(x: r.minX, y: r.minY, width: 0, height: r.height)
        }
        // On an empty line after a newline: the newline's box sits on the line above.
        if snapshot.caret == nil, previousIsBreak, location > 0,
           let nl = validRect(element.bounds(for: CFRange(location: location - 1, length: 1)), near: frame) {
            if let c = collapsed, c.minY > nl.minY + nl.height * 0.6 {
                snapshot.caret = CGRect(x: c.minX, y: c.minY, width: 0, height: c.height)
            } else {
                let left = validRect(element.bounds(for: CFRange(location: 0, length: 1)), near: frame)?.minX
                    ?? (frame?.minX ?? nl.minX) + 4
                snapshot.caret = CGRect(x: left, y: nl.maxY, width: 0, height: nl.height)
                snapshot.caretIsEstimated = true
            }
        }
        if snapshot.caret == nil, let c = collapsed {
            snapshot.caret = CGRect(x: c.minX, y: c.minY, width: 0, height: c.height)
            if web { snapshot.reportedCaret = c }
        }
        // Chromium answers range-based geometry only for form controls; rich text speaks in text markers.
        // Markers also give the line so far, which identifies the font and pins the caret's x.
        var markerGeometry = false
        if engine == .blink {
            markerGeometry = blinkMarkerCaret(&snapshot, element: element,
                                              needCaret: snapshot.caret == nil || snapshot.reportedCaret == nil)
        }
        // The caret's line: where it starts (wrapping, precise x), whether it continues a paragraph,
        // and where the line above is (line pitch).
        let multiLine = !snapshot.info.isSingleLine
        let wantsLine = (engine == .webkit && snapshot.reportedCaret != nil) || (multiLine && !markerGeometry)
        if wantsLine, let caret = snapshot.caret,
           let line = element.line(forIndex: location), let range = element.range(forLine: line),
           range.location <= location {
            if engine == .webkit, line > 0, range.location > 0 {
                snapshot.laterLineInBlock = continuesParagraph(snapshot, lineStart: range.location, caret: location)
            }
            if engine == .webkit || engine == .blink {
                if let start = validRect(element.bounds(for: CFRange(location: range.location, length: 0)), near: frame),
                   start.width <= 3 {
                    if range.location < location { setLine(&snapshot, start: start, length: location - range.location) }
                    else { snapshot.lineStart = start; snapshot.lineText = "" }
                }
                if engine == .blink, snapshot.lineText?.isEmpty == false,
                   let box = validRect(element.bounds(for: CFRange(location: range.location, length: location - range.location)), near: frame),
                   abs(box.minY - caret.minY) < caret.height * 0.5, box.height < caret.height * 1.5 {
                    snapshot.lineBox = box
                }
            } else if range.location < location,
                      let first = validRect(element.bounds(for: CFRange(location: range.location, length: 1)), near: frame) {
                // The first character's box starts the line.
                setLine(&snapshot, start: CGRect(x: first.minX, y: first.minY, width: 0, height: first.height),
                        length: location - range.location)
            } else if range.location == location {
                snapshot.lineStart = CGRect(x: caret.minX, y: caret.minY, width: 0, height: caret.height)
                snapshot.lineText = ""
            }
            if multiLine, line > 0, let previous = element.range(forLine: line - 1), previous.length > 0,
               let r = validRect(element.bounds(for: CFRange(location: previous.location, length: 1)), near: frame),
               r.minY < caret.minY {
                snapshot.previousLineTop = r.minY
            }
        }
        if engine == .webkit, snapshot.reportedCaret != nil, !snapshot.laterLineInBlock, location > 0, !previousIsBreak,
           snapshot.info.role != "AXTextField",
           let value = element.parameterized("AXTextMarkerForIndex", (location - 1) as CFNumber),
           CFGetTypeID(value) == AXTextMarkerGetTypeID() {
            snapshot.textBox = textRunBox(after: value as! AXTextMarker, in: element, caret: snapshot.caret)
        }
        // Empty single-line field: estimate from its frame.
        if snapshot.caret == nil, location == 0, let frame, frame.height < 80 {
            let height = min(frame.height - 4, 22)
            snapshot.caret = CGRect(x: frame.minX + 6, y: frame.midY - height / 2, width: 0, height: height)
            snapshot.caretIsEstimated = true
        }

        // Font: cached for a while because it's an extra round trip and rarely changes.
        let now = ProcessInfo.processInfo.systemUptime
        if markerGeometry {
            // Already read through text markers.
        } else if let cached, now - cached.queriedAt < 2 {
            snapshot.fontName = cached.fontName
            snapshot.fontSize = cached.fontSize
            snapshot.textColor = cached.textColor
            snapshot.sampleText = cached.sampleText
            snapshot.sampleWidth = cached.sampleWidth
        } else {
            // Width of up to 24 characters right before the caret, on the same line: reveals zoom, and
            // identifies the font when the app doesn't name it.
            let lineTail = snapshot.prefix.suffix(24).split(omittingEmptySubsequences: false, whereSeparator: { $0.isNewline })
                .last.map(String.init) ?? ""
            if lineTail.count >= 4, !containsLayoutCharacters(lineTail), let caret = snapshot.caret {
                let length = lineTail.utf16.count
                if let r = validRect(element.bounds(for: CFRange(location: location - length, length: length)), near: frame),
                   abs(r.minY - caret.minY) < caret.height * 0.5, abs(r.height - caret.height) < caret.height * 0.5 {
                    snapshot.sampleText = lineTail
                    snapshot.sampleWidth = r.width
                }
            }
            let probe = location > 0 ? CFRange(location: location - previousLength, length: previousLength)
                : (next != nil ? CFRange(location: 0, length: 1) : nil)
            if let probe, let attributed = element.attributedString(for: probe), attributed.length > 0 {
                let attrs = attributed.attributes(at: 0, effectiveRange: nil)
                let fontValue = attrs[NSAttributedString.Key(rawValue: "AXFont")] ?? attrs[.font]
                if let font = fontValue as? [String: Any] {
                    snapshot.fontName = (font["AXFontName"] as? String) ?? (font["AXFontFamily"] as? String)
                    snapshot.fontSize = (font["AXFontSize"] as? NSNumber).map { CGFloat($0.doubleValue) }
                } else if let font = fontValue as? NSFont {
                    snapshot.fontName = font.fontName
                    snapshot.fontSize = font.pointSize
                }
                if let color = attrs[NSAttributedString.Key(rawValue: "AXForegroundColor")] {
                    if CFGetTypeID(color as CFTypeRef) == CGColor.typeID { snapshot.textColor = (color as! CGColor) }
                }
            }
        }
    }
}
