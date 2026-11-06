import AppKit
import ApplicationServices

/// Gathers the text visible around a field (the conversation above a chat box, the email being
/// replied to…) so predictions can draw on it. Runs on its own queue with a strict time budget.
enum ScreenContextCollector {
    static let queue: DispatchQueue = TestBench.isActive
        ? .main : DispatchQueue(label: "app.foreword.screen-context", qos: .utility)
    private static let textRoles: Set<String> = ["AXStaticText", "AXTextArea", "AXTextField", "AXHeading", "AXCell"]
    private static let skipRoles: Set<String> = [
        "AXMenuBar", "AXMenu", "AXMenuItem", "AXToolbar", "AXButton", "AXPopUpButton", "AXMenuButton", "AXCheckBox",
        "AXRadioButton", "AXScrollBar", "AXSlider", "AXImage", "AXTabGroup", "AXSplitter", "AXDisclosureTriangle",
        "AXIncrementor", "AXColorWell", "AXProgressIndicator", "AXBusyIndicator", "AXValueIndicator", "AXRuler",
    ]

    struct Item {
        var text: String
        var frame: CGRect
    }

    /// Returns visible text near `field`, in reading order, at most `limit` characters.
    static func collect(around field: FieldInfo, fieldFrame: CGRect?, limit: Int = 2400, budget: TimeInterval = 0.15) -> String? {
        let start = ProcessInfo.processInfo.systemUptime
        guard let window = field.element.window ?? field.element.ancestor(where: { $0.role == "AXWindow" }) else { return nil }
        window.setTimeout(0.1)
        let windowFrame = window.frame
        var items: [Item] = []
        var visited = 0
        var stack: [(AXElement, Int)] = [(window, 0)]
        let names = [kAXRoleAttribute, kAXValueAttribute, kAXTitleAttribute, kAXChildrenAttribute,
                     kAXPositionAttribute, kAXSizeAttribute, kAXDescriptionAttribute]

        while let (element, depth) = stack.popLast() {
            if ProcessInfo.processInfo.systemUptime - start > budget || visited > 2500 { break }
            visited += 1
            if element == field.element { continue }
            element.setTimeout(0.05)
            let attrs = FieldReader.attributes(element, names)
            let role = attrs[kAXRoleAttribute] as? String ?? ""
            if skipRoles.contains(role) { continue }

            var frame: CGRect?
            if let p = attrs[kAXPositionAttribute], let s = attrs[kAXSizeAttribute] {
                var origin = CGPoint.zero, size = CGSize.zero
                AXValueGetValue(p as! AXValue, .cgPoint, &origin)
                AXValueGetValue(s as! AXValue, .cgSize, &size)
                frame = CGRect(origin: origin, size: size)
            }
            // Skip subtrees scrolled out of view.
            if let frame, let windowFrame, frame.width > 0, frame.height > 0, !windowFrame.intersects(frame) { continue }

            if textRoles.contains(role) {
                let text = (attrs[kAXValueAttribute] as? String) ?? (attrs[kAXTitleAttribute] as? String)
                    ?? (role == "AXHeading" ? attrs[kAXDescriptionAttribute] as? String : nil)
                if let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), text.count >= 2, let frame {
                    items.append(Item(text: text, frame: frame))
                    if role == "AXStaticText" || role == "AXTextArea" { continue } // children repeat the text
                }
            }
            if depth < 40, let children = attrs[kAXChildrenAttribute] as? [AnyObject] {
                // Push in reverse so we visit in document order.
                for child in children.reversed() where CFGetTypeID(child) == AXUIElementGetTypeID() {
                    stack.append((AXElement(child as! AXUIElement), depth + 1))
                }
            }
        }
        return compose(items, fieldFrame: fieldFrame, limit: limit)
    }

    /// Orders items top-to-bottom and keeps those closest to the field within the budget.
    static func compose(_ items: [Item], fieldFrame: CGRect?, limit: Int) -> String? {
        guard !items.isEmpty else { return nil }
        // De-duplicate (web content often exposes the same text twice).
        var seen = Set<String>()
        var unique: [Item] = []
        for item in items where seen.insert(item.text).inserted {
            unique.append(item)
        }
        // Rank by distance to the field; text above the field (what is being replied to) wins ties.
        let anchor = fieldFrame.map { CGPoint(x: $0.midX, y: $0.minY) }
        func distance(_ item: Item) -> CGFloat {
            guard let anchor else { return 0 }
            let dy = item.frame.maxY <= anchor.y ? anchor.y - item.frame.maxY : (item.frame.minY - anchor.y) * 1.6 + 40
            let dx = max(0, abs(item.frame.midX - anchor.x) - item.frame.width / 2)
            return dy + dx * 0.3
        }
        var chosen: [Item] = []
        var used = 0
        for item in unique.sorted(by: { distance($0) < distance($1) }) {
            let cost = item.text.count + 1
            if used + cost > limit {
                if used > limit / 2 { break }
                continue
            }
            chosen.append(item)
            used += cost
        }
        chosen.sort { a, b in
            if abs(a.frame.minY - b.frame.minY) > 4 { return a.frame.minY < b.frame.minY }
            return a.frame.minX < b.frame.minX
        }
        let text = chosen.map(\.text).joined(separator: "\n")
        return text.isEmpty ? nil : text
    }
}
