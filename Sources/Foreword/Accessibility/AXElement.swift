import ApplicationServices
import AppKit

/// Thin, typed wrapper over `AXUIElement`. All calls are synchronous IPC to the target app, so they
/// must never run on the main thread (see `AXQueue`).
struct AXElement: Hashable, @unchecked Sendable {
    let ref: AXUIElement

    init(_ ref: AXUIElement) { self.ref = ref }

    static let systemWide = AXElement(AXUIElementCreateSystemWide())

    static func application(pid: pid_t) -> AXElement {
        AXElement(AXUIElementCreateApplication(pid))
    }

    static func == (lhs: AXElement, rhs: AXElement) -> Bool { CFEqual(lhs.ref, rhs.ref) }
    func hash(into hasher: inout Hasher) { hasher.combine(CFHash(ref)) }

    var pid: pid_t? {
        var pid: pid_t = 0
        return AXUIElementGetPid(ref, &pid) == .success ? pid : nil
    }

    func setTimeout(_ seconds: Float) {
        AXUIElementSetMessagingTimeout(ref, seconds)
    }

    // MARK: Attributes

    func raw(_ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(ref, attribute as CFString, &value)
        return error == .success ? value : nil
    }

    func string(_ attribute: String) -> String? {
        raw(attribute) as? String
    }

    func bool(_ attribute: String) -> Bool? {
        if let n = raw(attribute) as? NSNumber { return n.boolValue }
        return nil
    }

    func int(_ attribute: String) -> Int? {
        (raw(attribute) as? NSNumber)?.intValue
    }

    func element(_ attribute: String) -> AXElement? {
        guard let value = raw(attribute), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return AXElement(value as! AXUIElement)
    }

    func elements(_ attribute: String) -> [AXElement] {
        guard let array = raw(attribute) as? [AnyObject] else { return [] }
        return array.compactMap { item in
            CFGetTypeID(item) == AXUIElementGetTypeID() ? AXElement(item as! AXUIElement) : nil
        }
    }

    func range(_ attribute: String) -> CFRange? {
        guard let value = raw(attribute), CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        return AXValueGetValue(value as! AXValue, .cfRange, &range) ? range : nil
    }

    func point(_ attribute: String) -> CGPoint? {
        guard let value = raw(attribute), CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        return AXValueGetValue(value as! AXValue, .cgPoint, &point) ? point : nil
    }

    func size(_ attribute: String) -> CGSize? {
        guard let value = raw(attribute), CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var size = CGSize.zero
        return AXValueGetValue(value as! AXValue, .cgSize, &size) ? size : nil
    }

    /// Frame in AX (top-left origin) screen coordinates.
    var frame: CGRect? {
        guard let origin = point(kAXPositionAttribute), let size = size(kAXSizeAttribute) else { return nil }
        return CGRect(origin: origin, size: size)
    }

    @discardableResult
    func set(_ attribute: String, _ value: CFTypeRef) -> Bool {
        AXUIElementSetAttributeValue(ref, attribute as CFString, value) == .success
    }

    func isSettable(_ attribute: String) -> Bool {
        var settable: DarwinBoolean = false
        return AXUIElementIsAttributeSettable(ref, attribute as CFString, &settable) == .success && settable.boolValue
    }

    var attributeNames: [String] {
        var names: CFArray?
        guard AXUIElementCopyAttributeNames(ref, &names) == .success else { return [] }
        return (names as? [String]) ?? []
    }

    var parameterizedAttributeNames: [String] {
        var names: CFArray?
        guard AXUIElementCopyParameterizedAttributeNames(ref, &names) == .success else { return [] }
        return (names as? [String]) ?? []
    }

    // MARK: Parameterized attributes

    func parameterized(_ attribute: String, _ parameter: CFTypeRef) -> CFTypeRef? {
        var value: CFTypeRef?
        let error = AXUIElementCopyParameterizedAttributeValue(ref, attribute as CFString, parameter, &value)
        return error == .success ? value : nil
    }

    func bounds(for range: CFRange) -> CGRect? {
        var r = range
        guard let param = AXValueCreate(.cfRange, &r),
              let value = parameterized(kAXBoundsForRangeParameterizedAttribute, param),
              CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(value as! AXValue, .cgRect, &rect) else { return nil }
        return rect
    }

    func string(for range: CFRange) -> String? {
        var r = range
        guard let param = AXValueCreate(.cfRange, &r) else { return nil }
        return parameterized(kAXStringForRangeParameterizedAttribute, param) as? String
    }

    func attributedString(for range: CFRange) -> NSAttributedString? {
        var r = range
        guard let param = AXValueCreate(.cfRange, &r) else { return nil }
        return parameterized(kAXAttributedStringForRangeParameterizedAttribute, param) as? NSAttributedString
    }

    func range(forLine line: Int) -> CFRange? {
        guard let value = parameterized(kAXRangeForLineParameterizedAttribute, line as CFNumber),
              CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        return AXValueGetValue(value as! AXValue, .cfRange, &range) ? range : nil
    }

    func line(forIndex index: Int) -> Int? {
        parameterized(kAXLineForIndexParameterizedAttribute, index as CFNumber) as? Int
    }

    // MARK: Convenience

    var role: String? { string(kAXRoleAttribute) }
    var subrole: String? { string(kAXSubroleAttribute) }
    var parent: AXElement? { element(kAXParentAttribute) }
    var window: AXElement? { element(kAXWindowAttribute) }
    var children: [AXElement] { elements(kAXChildrenAttribute) }

    func ancestor(maxDepth: Int = 30, where predicate: (AXElement) -> Bool) -> AXElement? {
        var current = parent
        var depth = 0
        while let c = current, depth < maxDepth {
            if predicate(c) { return c }
            current = c.parent
            depth += 1
        }
        return nil
    }
}

/// Serial queue for all Accessibility IPC so the UI never blocks on a slow app.
enum AXQueue {
    /// Accessibility calls into *this* process are serviced in-process on the calling thread, which
    /// would race AppKit; the test bench (which inspects its own windows) therefore uses the main queue.
    static let queue: DispatchQueue = TestBench.isActive
        ? .main : DispatchQueue(label: "app.foreword.ax", qos: .userInteractive)
}

/// Conversions between AX (top-left origin) and Cocoa (bottom-left origin) coordinates.
enum ScreenGeometry {
    /// Height of the primary screen, which anchors both coordinate systems.
    static var primaryHeight: CGFloat {
        NSScreen.screens.first?.frame.height ?? 0
    }

    static func cocoaRect(fromAX rect: CGRect) -> CGRect {
        CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    static func screen(containing point: CGPoint) -> NSScreen? {
        NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main
    }
}
