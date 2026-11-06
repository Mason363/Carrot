import AppKit
import CoreText

/// A continuation line of a wrapped inline suggestion, in view coordinates (y down).
struct GhostLine: Equatable {
    var text: String
    var x: CGFloat
    var baseline: CGFloat
}

/// What the overlay shows.
struct GhostContent: Equatable {
    enum Style: Equatable {
        /// Gray text right after the caret, on the text's own baseline.
        case inline
        /// A small floating card below (or above) the caret, used when inline text would collide
        /// with existing text or the caret position is uncertain.
        case pill
        /// A spelling fix for the word just typed.
        case correction(original: String)
    }

    var text: String
    var style: Style
    var font: NSFont
    var color: NSColor
    var hint: String?
    /// Inline: distance from the top of the view to the text baseline.
    var baseline: CGFloat
    var lineHeight: CGFloat
    /// Inline: where the first glyph starts, from the view's left edge. Fractional on purpose: the
    /// panel sits on the pixel grid while the text lands exactly where the app would draw it.
    var originX: CGFloat = 0
    /// Whether kerning applies between a space and the letter after it. WebKit shapes each word with
    /// its trailing space on its own, so it never kerns across into the next word.
    var kernsAfterSpaces = true
    /// Inline: further lines when the suggestion wraps.
    var extraLines: [GhostLine] = []
}

/// Borderless, click-through, never-key panel that floats above everything (including full-screen apps).
final class GhostPanel: NSPanel {
    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 10, height: 10),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.assistiveTechHighWindow)))
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        ignoresMouseEvents = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        hidesOnDeactivate = false
        animationBehavior = .none
        isReleasedWhenClosed = false
        becomesKeyOnlyIfNeeded = true
        isMovable = false
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class GhostView: NSView {
    var content: GhostContent? {
        didSet { if content != oldValue { needsDisplay = true } }
    }

    static let pillPadding = NSEdgeInsets(top: 4, left: 8, bottom: 4, right: 8)
    static let pillCorner: CGFloat = 7

    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { false }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.drawsAsynchronously = false
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        guard let content, let context = NSGraphicsContext.current?.cgContext else { return }
        context.clear(bounds)
        switch content.style {
        case .inline:
            drawLine(content.text, font: content.font, color: content.color, x: content.originX, baseline: content.baseline,
                     kernsAfterSpaces: content.kernsAfterSpaces, in: context)
            for line in content.extraLines {
                drawLine(line.text, font: content.font, color: content.color, x: line.x, baseline: line.baseline,
                         kernsAfterSpaces: content.kernsAfterSpaces, in: context)
            }
        case .pill, .correction:
            drawPill(content, in: context)
        }
    }

    private func drawLine(_ text: String, font: NSFont, color: NSColor, x: CGFloat, baseline: CGFloat,
                          kernsAfterSpaces: Bool = true, in context: CGContext) {
        let attributed = Self.attributed(text, font: font, color: color, kernsAfterSpaces: kernsAfterSpaces)
        let line = CTLineCreateWithAttributedString(attributed)
        context.saveGState()
        // Fractional glyph positions, like the apps whose text we continue.
        context.setAllowsFontSubpixelPositioning(true)
        context.setShouldSubpixelPositionFonts(true)
        // Same glyph-position quantization AppKit text uses.
        context.setAllowsFontSubpixelQuantization(true)
        context.setShouldSubpixelQuantizeFonts(true)
        // Flipped view: undo the flip for CoreText.
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        context.textPosition = CGPoint(x: x, y: baseline)
        CTLineDraw(line, context)
        context.restoreGState()
    }

    private func drawPill(_ content: GhostContent, in context: CGContext) {
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: rect, xRadius: Self.pillCorner, yRadius: Self.pillCorner)
        NSColor.ghostPillBackground.setFill()
        path.fill()
        NSColor.ghostPillBorder.setStroke()
        path.lineWidth = 0.5
        path.stroke()

        let padding = Self.pillPadding
        var x = padding.left
        let ascent = content.font.ascender
        let descent = -content.font.descender
        let baseline = (bounds.height - (ascent + descent)) / 2 + ascent

        if case .correction(let original) = content.style {
            // "recieve → receive": the original struck through, then the fix.
            let originalWidth = Self.width(of: original, font: content.font)
            drawLine(original, font: content.font, color: .secondaryLabelColor, x: x, baseline: baseline, in: context)
            let strikeY = baseline - ascent * 0.32
            context.setStrokeColor(NSColor.secondaryLabelColor.cgColor)
            context.setLineWidth(1)
            context.move(to: CGPoint(x: x, y: strikeY))
            context.addLine(to: CGPoint(x: x + originalWidth, y: strikeY))
            context.strokePath()
            x += originalWidth + 6
            let arrowFont = NSFont.systemFont(ofSize: content.font.pointSize * 0.85)
            drawLine("→", font: arrowFont, color: .tertiaryLabelColor, x: x, baseline: baseline, in: context)
            x += Self.width(of: "→", font: arrowFont) + 6
            drawLine(content.text, font: content.font, color: .labelColor, x: x, baseline: baseline, in: context)
            x += Self.width(of: content.text, font: content.font)
        } else {
            drawLine(content.text, font: content.font, color: .secondaryLabelColor, x: x, baseline: baseline, in: context)
            x += Self.width(of: content.text, font: content.font)
        }

        if let hint = content.hint {
            let hintFont = NSFont.systemFont(ofSize: max(9, content.font.pointSize * 0.72), weight: .medium)
            let hintWidth = Self.width(of: hint, font: hintFont)
            let capWidth = max(hintWidth + 8, 18)
            let capHeight = hintFont.ascender - hintFont.descender + 4
            let capRect = NSRect(x: bounds.width - padding.right - capWidth, y: (bounds.height - capHeight) / 2,
                                 width: capWidth, height: capHeight)
            let cap = NSBezierPath(roundedRect: capRect, xRadius: 4, yRadius: 4)
            NSColor.ghostKeycap.setFill()
            cap.fill()
            let hintBaseline = capRect.minY + (capHeight - (hintFont.ascender - hintFont.descender)) / 2 + hintFont.ascender
            drawLine(hint, font: hintFont, color: .secondaryLabelColor, x: capRect.minX + (capWidth - hintWidth) / 2,
                     baseline: hintBaseline, in: context)
        }
    }

    static func width(of text: String, font: NSFont) -> CGFloat {
        ceil(exactWidth(of: text, font: font))
    }

    /// The typographic advance of `text`, unrounded: where the pen ends up after drawing it.
    static func exactWidth(of text: String, font: NSFont, kernsAfterSpaces: Bool = true) -> CGFloat {
        let line = CTLineCreateWithAttributedString(attributed(text, font: font, color: nil, kernsAfterSpaces: kernsAfterSpaces))
        return CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
    }

    /// `text` styled for drawing. Without kerning after spaces, each space gets a zero kern, which
    /// turns off the pair it would form with the next letter (the letter before it keeps its pair).
    static func attributed(_ text: String, font: NSFont, color: NSColor?, kernsAfterSpaces: Bool) -> NSAttributedString {
        var attributes: [NSAttributedString.Key: Any] = [.font: font]
        if let color { attributes[.foregroundColor] = color }
        let string = NSMutableAttributedString(string: text, attributes: attributes)
        if !kernsAfterSpaces {
            let ns = text as NSString
            var index = 0
            while index < ns.length {
                let found = ns.range(of: " ", range: NSRange(location: index, length: ns.length - index))
                guard found.location != NSNotFound else { break }
                string.addAttribute(.kern, value: 0.0, range: found)
                index = found.location + 1
            }
        }
        return string
    }

    /// How far kerning moves `next` when it follows `previous` (zero across a ligature, which can't be
    /// continued in a separate layer anyway).
    static func pairKerning(_ previous: Character, _ next: Character, font: NSFont, kernsAfterSpaces: Bool) -> CGFloat {
        if previous == " " && !kernsAfterSpaces { return 0 }
        if previous.isWhitespace && previous != " " || next.isNewline || previous.isNewline { return 0 }
        let pair = String(previous) + String(next)
        let line = CTLineCreateWithAttributedString(attributed(pair, font: font, color: nil, kernsAfterSpaces: kernsAfterSpaces))
        guard CTLineGetGlyphCount(line) == pair.utf16.count else { return 0 }
        let kern = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
            - exactWidth(of: String(previous), font: font) - exactWidth(of: String(next), font: font)
        return abs(kern) < font.pointSize * 0.3 ? kern : 0
    }

    /// Size the pill needs for `content`.
    static func pillSize(for content: GhostContent) -> NSSize {
        var width = pillPadding.left + pillPadding.right + width(of: content.text, font: content.font)
        if case .correction(let original) = content.style {
            let arrowFont = NSFont.systemFont(ofSize: content.font.pointSize * 0.85)
            width += self.width(of: original, font: content.font) + 12 + self.width(of: "→", font: arrowFont)
        }
        if let hint = content.hint {
            let hintFont = NSFont.systemFont(ofSize: max(9, content.font.pointSize * 0.72), weight: .medium)
            width += max(self.width(of: hint, font: hintFont) + 8, 18) + 8
        }
        let height = ceil(content.font.ascender - content.font.descender) + pillPadding.top + pillPadding.bottom + 2
        return NSSize(width: ceil(width), height: max(height, 20))
    }
}

extension NSColor {
    static let ghostPillBackground = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(white: 0.17, alpha: 0.97) : NSColor(white: 0.99, alpha: 0.97)
    }
    static let ghostPillBorder = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(white: 1, alpha: 0.14) : NSColor(white: 0, alpha: 0.14)
    }
    static let ghostKeycap = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(white: 1, alpha: 0.10) : NSColor(white: 0, alpha: 0.06)
    }
}
