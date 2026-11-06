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
    /// Field frame in AX coordinates.
    var fieldFrame: CGRect?
    let timestamp = ProcessInfo.processInfo.systemUptime

    var hasSelection: Bool { selection.length > 0 }
    /// Text after the caret on the same line.
    var lineSuffix: Substring {
        suffix.prefix(while: { $0 != "\n" && $0 != "\r" && $0 != "\u{2028}" && $0 != "\u{2029}" })
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
        if let element = system.element(kAXFocusedUIElementAttribute) { return element }
        // Some apps answer only through their application element.
        if let app = NSWorkspace.shared.frontmostApplication {
            let appElement = AXElement.application(pid: app.processIdentifier)
            appElement.setTimeout(0.25)
            return appElement.element(kAXFocusedUIElementAttribute)
        }
        return nil
    }

    static func focusedElement(inApp pid: pid_t) -> AXElement? {
        let appElement = AXElement.application(pid: pid)
        appElement.setTimeout(0.25)
        if let element = appElement.element(kAXFocusedUIElementAttribute) { return element }
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
        guard hasSelectionRange && (isEditableRole || editableAncestor || element.isSettable(kAXValueAttribute)) else {
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
        let webArea = element.ancestor(maxDepth: 40, where: { $0.role == "AXWebArea" })
        let url = webArea.flatMap(webURL(of:))
        let domain = url.flatMap { URL(string: $0)?.host?.replacingOccurrences(of: "www.", with: "") }

        return FieldInfo(
            element: element, pid: pid, bundleID: app?.bundleIdentifier, appName: app?.localizedName,
            role: role, subrole: subrole, isSecure: isSecure, isSearch: isSearch,
            isSingleLine: role == "AXTextField" || role == "AXComboBox" || role == "AXSearchField",
            label: label?.trimmingCharacters(in: .whitespacesAndNewlines),
            windowTitle: windowTitle, url: url, domain: domain, isWebContent: webArea != nil)
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
            prefix = element.string(for: CFRange(location: start, length: caret - start)) ?? ""
            let length = min(total - end, suffixLimit)
            suffix = length > 0 ? (element.string(for: CFRange(location: end, length: length)) ?? "") : ""
            // Drop a possibly split surrogate at the window start.
            if let first = prefix.unicodeScalars.first, first.properties.generalCategory == .surrogate {
                prefix.removeFirst()
            }
        }

        var snapshot = FieldSnapshot(info: info, prefix: prefix, suffix: suffix, selection: selection, totalLength: total,
                                     fieldFrame: fieldFrame)
        if selection.length == 0 {
            locateCaret(&snapshot, element: element, cached: cached)
        }
        return snapshot
    }

    /// Geometry that is expensive to query and rarely changes.
    struct CachedGeometry {
        var fontName: String?
        var fontSize: CGFloat?
        var textColor: CGColor?
        var queriedAt: TimeInterval
    }

    private static func safeBoundary(_ ns: NSString, _ index: Int) -> Int {
        guard index > 0, index < ns.length else { return index }
        return ns.rangeOfComposedCharacterSequence(at: index).location
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
        let previousIsBreak = previous.map { $0 == "\n" || $0 == "\r" || $0 == "\u{2029}" || $0 == "\u{2028}" } ?? true
        let previousLength = snapshot.prefix.last.map { String($0).utf16.count } ?? 1

        // The character before the caret is the most reliable anchor across apps. A collapsed range is
        // used to detect soft wraps (caret already on the next visual line) — but some text systems
        // (TextKit 2) report collapsed ranges a line too high, so it only wins when it sits *below*.
        let collapsed = validRect(element.bounds(for: CFRange(location: location, length: 0)), near: frame)
            .flatMap { $0.width <= 3 ? $0 : nil }
        if location > 0, !previousIsBreak,
           let r = validRect(element.bounds(for: CFRange(location: location - previousLength, length: previousLength)), near: frame) {
            if let c = collapsed, c.minY > r.minY + r.height * 0.6, abs(c.height - r.height) < r.height * 0.5 {
                snapshot.caret = CGRect(x: c.minX, y: c.minY, width: 0, height: c.height) // wrapped
            } else if let c = collapsed, abs(c.minY - r.minY) < r.height * 0.5, abs(c.minX - r.maxX) < 6 {
                // Same line: the collapsed range is the precise caret (glyph boxes can overlap).
                snapshot.caret = CGRect(x: c.minX, y: r.minY, width: 0, height: r.height)
            } else {
                snapshot.caret = CGRect(x: r.maxX, y: r.minY, width: 0, height: r.height)
            }
        }
        // At the start of a line with text after the caret: that character's box is on the caret's line.
        if snapshot.caret == nil, let next, next != "\n", next != "\r",
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
        }
        // Empty single-line field: estimate from its frame.
        if snapshot.caret == nil, location == 0, let frame, frame.height < 80 {
            let height = min(frame.height - 4, 22)
            snapshot.caret = CGRect(x: frame.minX + 6, y: frame.midY - height / 2, width: 0, height: height)
            snapshot.caretIsEstimated = true
        }

        // Font: cached for a while because it's an extra round trip and rarely changes.
        let now = ProcessInfo.processInfo.systemUptime
        if let cached, now - cached.queriedAt < 2 {
            snapshot.fontName = cached.fontName
            snapshot.fontSize = cached.fontSize
            snapshot.textColor = cached.textColor
        } else {
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
