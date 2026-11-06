import AppKit

/// Positions and draws the suggestion. Owns a single panel that is created once and only ever
/// moved, redrawn, or made transparent — never re-created — so nothing flickers.
@MainActor
final class GhostPresenter {
    private let panel = GhostPanel()
    private let view = GhostView()
    private(set) var isVisible = false
    private(set) var content: GhostContent?
    /// The text the user would accept (may be shorter than the suggestion if it had to be cut to fit).
    private(set) var displayedText = ""
    private var lastLayout: Layout?

    struct Layout {
        var caret: CGRect          // AX coordinates
        var font: NSFont
        var baseline: CGFloat
        var style: GhostContent.Style
        var frame: NSRect          // Cocoa coordinates
        var anchorX: CGFloat       // Cocoa x of the caret
    }

    init() {
        panel.contentView = view
        panel.alphaValue = 0
        panel.orderFrontRegardless()
    }

    var debugFrame: NSRect { panel.frame }

    // MARK: Showing

    /// Shows `text` for `snapshot`. Returns the text actually displayed (possibly trimmed to fit), or
    /// nil when it can't be shown sensibly.
    @discardableResult
    func show(_ text: String, snapshot: FieldSnapshot, preferPill: Bool, correction original: String? = nil,
              correctionRect: CGRect? = nil) -> String? {
        let prefs = Preferences.shared
        guard let caretRect = correctionRect ?? snapshot.caret ?? fallbackCaret(for: snapshot) else { hide(); return nil }
        let font = matchedFont(name: snapshot.fontName, size: snapshot.fontSize, caretHeight: caretRect.height)
        let color = ghostColor(textColor: snapshot.textColor)
        let hint = prefs.showKeyHint ? prefs.acceptAllKey.displayString : nil
        let screen = ScreenGeometry.screen(containing: CGPoint(x: caretRect.midX, y: ScreenGeometry.primaryHeight - caretRect.midY))
        let scale = screen?.backingScaleFactor ?? 2
        let visible = screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero

        var style: GhostContent.Style = original != nil ? .correction(original: original!) : .inline
        var shown = text
        let baseline = round(Self.baseline(for: font, lineHeight: caretRect.height, web: snapshot.info.isWebContent) * scale) / scale

        if style == .inline {
            if preferPill || snapshot.caretIsEstimated || snapshot.caret == nil {
                style = .pill
            } else {
                // Does it fit before the field's right edge?
                let available: CGFloat
                if let field = snapshot.fieldFrame, field.width > 20 {
                    available = field.maxX - caretRect.minX - 6
                } else {
                    available = visible.maxX - caretRect.minX - 8
                }
                if GhostView.width(of: shown, font: font) > available {
                    if let fitted = fit(shown, font: font, width: available) {
                        shown = fitted
                    } else {
                        style = .pill
                    }
                }
            }
        }

        var content = GhostContent(text: shown, style: style, font: font, color: color,
                                   hint: style == .inline ? nil : hint, baseline: baseline, lineHeight: caretRect.height)
        let cocoaCaret = ScreenGeometry.cocoaRect(fromAX: caretRect)
        var frame: NSRect
        switch style {
        case .inline:
            let width = GhostView.width(of: shown, font: font) + 4
            frame = NSRect(x: cocoaCaret.minX, y: cocoaCaret.minY, width: width, height: caretRect.height)
        case .pill, .correction:
            // Pill text is drawn at a comfortable size even if the field's text is tiny or huge.
            let pillFont = NSFont(descriptor: font.fontDescriptor, size: min(max(font.pointSize, 12), 17)) ?? .systemFont(ofSize: 13)
            content.font = pillFont
            if case .pill = style {
                // A pill can be long: cap it at a readable width.
                let maxTextWidth = min(520, visible.width - 40)
                if GhostView.width(of: shown, font: pillFont) > maxTextWidth,
                   let fitted = fit(shown, font: pillFont, width: maxTextWidth) {
                    shown = fitted
                    content.text = fitted
                }
            }
            let size = GhostView.pillSize(for: content)
            var x = cocoaCaret.minX - GhostView.pillPadding.left
            var y = cocoaCaret.minY - 5 - size.height // below the line
            if y < visible.minY + 2 { y = cocoaCaret.maxY + 5 } // no room: above
            x = min(max(x, visible.minX + 4), visible.maxX - size.width - 4)
            frame = NSRect(origin: NSPoint(x: x, y: y), size: size)
        }
        frame.origin.x = round(frame.origin.x * scale) / scale
        frame.origin.y = round(frame.origin.y * scale) / scale

        apply(content: content, frame: frame)
        lastLayout = Layout(caret: caretRect, font: font, baseline: baseline, style: style, frame: frame, anchorX: cocoaCaret.minX)
        displayedText = shown
        return shown
    }

    /// The user typed `typed` and it matched the start of the suggestion: shift the ghost right by
    /// the typed text's width and drop it from the displayed text, without waiting for the app.
    func advance(by typed: String, remaining: String) {
        guard isVisible, var content, var layout = lastLayout else { return }
        if remaining.isEmpty { hide(); return }
        displayedText = remaining
        content.text = remaining
        var frame = layout.frame
        switch layout.style {
        case .inline:
            let shift = GhostView.width(of: typed, font: layout.font)
            frame.origin.x += shift
            frame.size.width = GhostView.width(of: remaining, font: layout.font) + 4
            layout.anchorX += shift
            layout.caret.origin.x += shift
        case .pill, .correction:
            let size = GhostView.pillSize(for: content)
            frame.size.width = size.width
        }
        apply(content: content, frame: frame)
        layout.frame = frame
        lastLayout = layout
    }

    /// Moves the ghost to a new caret position without changing its text (e.g. after the window moved).
    func reposition(snapshot: FieldSnapshot) {
        guard isVisible, let content else { return }
        if case .correction = content.style { return }
        let preferPill = content.style != .inline
        show(displayedText, snapshot: snapshot, preferPill: preferPill)
    }

    func hide() {
        guard isVisible else { return }
        isVisible = false
        content = nil
        displayedText = ""
        lastLayout = nil
        panel.alphaValue = 0
        view.content = nil
    }

    private func apply(content: GhostContent, frame: NSRect) {
        let styleChanged = self.content?.style != content.style
        self.content = content
        // Order matters for a flicker-free update: draw the new content, then move, then reveal.
        NSAnimationContext.beginGrouping()
        NSAnimationContext.current.duration = 0
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        view.content = content
        if panel.frame != frame { panel.setFrame(frame, display: false) }
        view.frame = NSRect(origin: .zero, size: frame.size)
        view.displayIfNeeded()
        if styleChanged {
            let isPill = content.style != .inline
            panel.hasShadow = isPill
        }
        if !isVisible {
            panel.alphaValue = 1
            isVisible = true
            if !panel.isVisible { panel.orderFrontRegardless() }
        }
        if panel.hasShadow { panel.invalidateShadow() }
        CATransaction.commit()
        NSAnimationContext.endGrouping()
    }

    // MARK: Fonts & colors

    private static let layoutManager = NSLayoutManager()

    /// Distance from the top of a line box of `lineHeight` to the text baseline.
    /// Web engines split extra line height evenly above and below the glyphs (CSS half-leading);
    /// TextKit puts the baseline at its default offset and extra height from line-height multiples above.
    static func baseline(for font: NSFont, lineHeight h: CGFloat, web: Bool) -> CGFloat {
        let ascent = font.ascender, descent = -font.descender
        let centered = (h - (ascent + descent)) / 2 + ascent
        guard !web else { return centered }
        let natural = layoutManager.defaultLineHeight(for: font)
        let offset = layoutManager.defaultBaselineOffset(for: font)
        if abs(h - natural) <= 1.5 { return offset + (h - natural) / 2 }
        if h > natural { return h - (natural - offset) }
        return centered
    }

    /// The field's font when the app reports it, scaled by the caret height when the content is zoomed.
    func matchedFont(name: String?, size reportedSize: CGFloat?, caretHeight: CGFloat) -> NSFont {
        var size: CGFloat
        if let reportedSize, reportedSize >= 4 {
            let ratio = caretHeight / reportedSize
            // A line is normally 1.1–1.8× the font size; outside that the view is zoomed.
            size = (0.95...1.9).contains(ratio) ? reportedSize : caretHeight / 1.2
        } else {
            size = caretHeight / 1.2
        }
        size = min(max(size, 8), 96)
        if let name, let font = NSFont(name: name, size: size) { return font }
        if let name, name.lowercased().contains("mono"), let mono = NSFont.userFixedPitchFont(ofSize: size) { return mono }
        return NSFont.systemFont(ofSize: size)
    }

    private func ghostColor(textColor: CGColor?) -> NSColor {
        let prefs = Preferences.shared
        let opacity = CGFloat(prefs.ghostOpacity)
        switch prefs.ghostColor {
        case .accent:
            return NSColor.controlAccentColor.withAlphaComponent(min(1, opacity + 0.25))
        case .gray:
            return NSColor(white: 0.5, alpha: min(1, opacity + 0.35))
        case .automatic:
            if let textColor, let color = NSColor(cgColor: textColor)?.usingColorSpace(.sRGB), color.alphaComponent > 0.5 {
                return color.withAlphaComponent(opacity)
            }
            return NSColor(white: 0.5, alpha: min(1, opacity + 0.35))
        }
    }

    /// The longest word-boundary prefix of `text` that fits in `width`.
    private func fit(_ text: String, font: NSFont, width: CGFloat) -> String? {
        guard width > 10 else { return nil }
        var best: String?
        var current = ""
        var index = text.startIndex
        while index < text.endIndex {
            let ch = text[index]
            let next = text.index(after: index)
            current.append(ch)
            let atBoundary = next == text.endIndex || text[next] == " "
            if atBoundary, current.contains(where: { !$0.isWhitespace }) {
                if GhostView.width(of: current, font: font) <= width {
                    best = current
                } else {
                    break
                }
            }
            index = next
        }
        guard let best, best.count >= 2 else { return nil }
        return best
    }

    private func fallbackCaret(for snapshot: FieldSnapshot) -> CGRect? {
        guard let field = snapshot.fieldFrame, field.width > 20, field.height > 8 else { return nil }
        let height = min(field.height, 20)
        return CGRect(x: field.minX + 8, y: field.maxY - height - 4, width: 0, height: height)
    }
}
