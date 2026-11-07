import AppKit
import CoreText

/// The engine that lays out and draws a field's text. Each one rounds font metrics and line
/// positions differently, and each reports caret rectangles rounded to whole points in its own way,
/// so placing ghost text on the exact pixel row of the real text needs that engine's rules.
enum TextEngine: String {
    /// AppKit / TextKit (and anything else that isn't a web engine).
    case native
    /// Safari, Mail, and apps built on WKWebView.
    case webkit
    /// Chrome and other Chromium browsers, plus Electron apps.
    case blink
    /// Firefox and its forks.
    case gecko

    private static let geckoPrefixes = ["org.mozilla.", "net.waterfox", "org.torproject", "io.gitlab.librewolf", "one.ablaze.floorp"]
    private static let cacheLock = NSLock()
    private static var bundleCache: [String: TextEngine] = [:]

    /// The web engine of an app, from its bundle. Only meaningful for web content.
    static func webEngine(for app: NSRunningApplication?) -> TextEngine {
        let bundleID = app?.bundleIdentifier
        let path = app?.bundleURL?.path
        let key = path ?? bundleID ?? ""
        cacheLock.lock()
        if let cached = bundleCache[key] { cacheLock.unlock(); return cached }
        cacheLock.unlock()

        var engine = TextEngine.webkit
        if let bundleID, geckoPrefixes.contains(where: bundleID.hasPrefix) || bundleID.contains("zen-browser") {
            engine = .gecko
        } else if AppRules.isChromium(bundleID) {
            engine = .blink
        } else if let path {
            let fm = FileManager.default
            let frameworks = path + "/Contents/Frameworks/"
            if fm.fileExists(atPath: frameworks + "Electron Framework.framework")
                || fm.fileExists(atPath: frameworks + "Chromium Embedded Framework.framework") {
                engine = .blink
            } else if fm.fileExists(atPath: path + "/Contents/MacOS/XUL") {
                engine = .gecko
            }
        }
        cacheLock.lock()
        bundleCache[key] = engine
        cacheLock.unlock()
        return engine
    }

    // MARK: Vertical placement

    /// Families whose ascent both WebKit and Blink inflate by 15% to match their Windows metrics.
    private static func hasAscentHack(_ font: CTFont) -> Bool {
        let family = CTFontCopyFamilyName(font) as String
        return family == "Times" || family == "Helvetica" || family == "Courier"
    }

    /// Distance from the top of the reported caret rectangle to the baseline the app draws its text
    /// on, snapped to device pixels. `caret` is the rectangle as the app reported it.
    static func baseline(engine: TextEngine, font: NSFont, caret: CGRect, scale: CGFloat,
                         isRichText: Bool, laterLineInBlock: Bool, textBox: CGRect? = nil) -> CGFloat? {
        let snap = { (v: CGFloat) in (v * scale).rounded(.toNearestOrAwayFromZero) / scale }
        switch engine {
        case .blink:
            return blinkBaseline(font: font, caret: caret, scale: scale)
        case .webkit:
            if !laterLineInBlock, let textBox,
               let b = webkitTextBoxBaseline(font: font, caret: caret, textBox: textBox, scale: scale) {
                return b
            }
            return snap(webkitBaseline(font: font, caret: caret, scale: scale, isRichText: isRichText,
                                       laterLineInBlock: laterLineInBlock))
        case .gecko:
            // Gecko reports glyph boxes on the device-pixel grid; the baseline is the box top plus the
            // ascent rounded up to a whole device pixel.
            return (CTFontGetAscent(font as CTFont) * scale).rounded(.up) / scale
        case .native:
            return nil
        }
    }

    /// The baseline (relative to `reference`) the engine draws on, for a glyph box whose exact top
    /// lies somewhere in `tops`: each possible top gives a baseline snapped to device pixels, and the
    /// one that most of the range agrees on wins. When the range is narrow it is exact; when the
    /// engine's whole-point rectangles leave it wide it is the likeliest pixel row.
    private static func likeliestBaseline(tops: ClosedRange<CGFloat>, ascent: CGFloat, reference: CGFloat,
                                          scale: CGFloat) -> CGFloat {
        var votes: [CGFloat: Int] = [:]
        let steps = 64
        for i in 0...steps {
            let top = tops.lowerBound + (tops.upperBound - tops.lowerBound) * CGFloat(i) / CGFloat(steps)
            let b = ((top + ascent) * scale).rounded(.toNearestOrAwayFromZero) / scale
            votes[b, default: 0] += 1
        }
        let best = votes.max { $0.value < $1.value || ($0.value == $1.value && $0.key > $1.key) }!.key
        return best - reference
    }

    /// The caret box heights Blink can report for `font`: its device-pixel glyph box with the top
    /// rounded and the bottom rounded up.
    static func blinkBoxHeights(font: NSFont, scale: CGFloat) -> Set<CGFloat> {
        let deviceFont = CTFontCreateCopyWithAttributes(font as CTFont, font.pointSize * scale, nil, nil)
        var ascent = (CTFontGetAscent(deviceFont) + 0.5).rounded(.down)
        let descent = (CTFontGetDescent(deviceFont) + 0.5).rounded(.down)
        if hasAscentHack(deviceFont) { ascent += ((ascent + descent) * 0.15 + 0.5).rounded(.down) }
        let height = (ascent + descent) / scale
        var heights = Set<CGFloat>()
        for i in 0..<16 {
            let top = -0.5 + CGFloat(i) / 16
            heights.insert((top + height).rounded(.up) - top.rounded(.toNearestOrAwayFromZero))
        }
        return heights
    }

    /// Blink lays text out in device pixels: font metrics are rounded to whole device pixels at the
    /// device size and a line's glyph box is `ascent + descent` tall. The rectangle it reports is that
    /// box with its top rounded to the nearest point and its bottom rounded up.
    static func blinkBaseline(font: NSFont, caret: CGRect, scale: CGFloat) -> CGFloat {
        let deviceFont = CTFontCreateCopyWithAttributes(font as CTFont, font.pointSize * scale, nil, nil)
        var ascent = (CTFontGetAscent(deviceFont) + 0.5).rounded(.down)
        let descent = (CTFontGetDescent(deviceFont) + 0.5).rounded(.down)
        if hasAscentHack(deviceFont) { ascent += ((ascent + descent) * 0.15 + 0.5).rounded(.down) }
        let height = (ascent + descent) / scale
        let top = caret.minY.rounded(), bottom = top + caret.height.rounded()
        let epsilon: CGFloat = 1 / 256
        var lower = max(top - 0.5, bottom - 1 - height + epsilon)
        var upper = min(top + 0.5 - epsilon, bottom - height)
        if lower > upper { lower = top; upper = top }
        return likeliestBaseline(tops: lower...upper, ascent: ascent / scale, reference: caret.minY, scale: scale)
    }

    /// WebKit reports a text run's box as the whole-point rectangle enclosing its glyph box (top at
    /// the line's text top, `ascent + descent` tall), which bounds where the text really is more
    /// tightly than the caret does. `textBox` must be a single line, on the caret's line.
    static func webkitTextBoxBaseline(font: NSFont, caret: CGRect, textBox: CGRect, scale: CGFloat) -> CGFloat? {
        let ct = font as CTFont
        var ascent = CTFontGetAscent(ct)
        let descent = CTFontGetDescent(ct)
        if hasAscentHack(ct) { ascent += ((ascent + descent) * 0.15).rounded(.toNearestOrAwayFromZero) }
        let height = ascent + descent
        let top = textBox.minY.rounded(), bottom = top + textBox.height.rounded()
        guard bottom - top >= height.rounded(.down), bottom - top <= height.rounded(.up) + 1,
              abs(top - caret.minY.rounded()) <= 1 else { return nil }
        let epsilon: CGFloat = 1 / 256
        var lower = max(top, bottom - 1 - height + epsilon)
        let upper = min(top + 1 - epsilon, bottom - height)
        guard lower <= upper + epsilon else { return nil }
        lower = min(lower, upper)
        // The caret's box is truncated to whole points in the same coordinates: exactly the text's
        // height (rounded down) means the text starts on a whole point.
        if caret.height.rounded() == height.rounded(.down), caret.minY.rounded() == top, lower <= top + epsilon {
            return likeliestBaseline(tops: top...top, ascent: ascent, reference: caret.minY, scale: scale)
        }
        return likeliestBaseline(tops: lower...upper, ascent: ascent, reference: caret.minY, scale: scale)
    }

    /// WebKit keeps fractional font metrics, puts half the line gap above the text, truncates the
    /// caret's top and height to whole points in the line's own coordinates, and then rounds the
    /// rectangle outward on screen. A box one point taller than the text means the line sits at a
    /// fraction of a point; without more information that fraction is taken to be one half.
    static func webkitBaseline(font: NSFont, caret: CGRect, scale: CGFloat, isRichText: Bool,
                               laterLineInBlock: Bool) -> CGFloat {
        let ct = font as CTFont
        var ascent = CTFontGetAscent(ct)
        let descent = CTFontGetDescent(ct)
        let gap = CTFontGetLeading(ct)
        if hasAscentHack(ct) { ascent += ((ascent + descent) * 0.15).rounded(.toNearestOrAwayFromZero) }
        let roundHalfUp = { (v: CGFloat) in v.rounded(.toNearestOrAwayFromZero) }
        let spacing = roundHalfUp(ascent) + roundHalfUp(descent) + roundHalfUp(gap)
        let height = ascent + descent
        // Layout units are 1/64 pt, truncated toward zero.
        let half = ((spacing - height) / 2 * 64).rounded(.towardZero) / 64
        let fraction = { (v: CGFloat) in v - v.rounded(.down) }
        let reported = caret.height.rounded()
        if laterLineInBlock {
            // The caret spans from the previous line's text bottom to this line's text bottom.
            if reported == spacing || reported == spacing + 1 {
                let phi: CGFloat = reported == spacing ? 0 : 0.5
                return phi + fraction(half + height) + spacing - descent
            }
            // A line height other than "normal": anchor on the bottom.
            return reported - descent + 0.5
        }
        let phi: CGFloat = reported == height.rounded(.towardZero) ? 0 : 0.5
        let offset = isRichText ? fraction(half) : half - half.rounded(.towardZero)
        return phi + offset + ascent
    }

    /// The distance between lines with `line-height: normal`, as the engine computes it.
    static func normalLineHeight(engine: TextEngine, font: NSFont, scale: CGFloat) -> CGFloat? {
        switch engine {
        case .blink:
            let deviceFont = CTFontCreateCopyWithAttributes(font as CTFont, font.pointSize * scale, nil, nil)
            var ascent = (CTFontGetAscent(deviceFont) + 0.5).rounded(.down)
            let descent = (CTFontGetDescent(deviceFont) + 0.5).rounded(.down)
            let gap = (CTFontGetLeading(deviceFont) + 0.5).rounded(.down)
            if hasAscentHack(deviceFont) { ascent += ((ascent + descent) * 0.15 + 0.5).rounded(.down) }
            return (ascent + descent + gap) / scale
        case .webkit:
            let ct = font as CTFont
            var ascent = CTFontGetAscent(ct)
            let descent = CTFontGetDescent(ct)
            if hasAscentHack(ct) { ascent += ((ascent + descent) * 0.15).rounded(.toNearestOrAwayFromZero) }
            return ascent.rounded(.toNearestOrAwayFromZero) + descent.rounded(.toNearestOrAwayFromZero)
                + CTFontGetLeading(ct).rounded(.toNearestOrAwayFromZero)
        case .native, .gecko:
            return nil
        }
    }

    // MARK: Horizontal placement

    /// The x the next glyph will be drawn at, from the caret rectangle the engine reported.
    static func caretX(engine: TextEngine, reported caret: CGRect, scale: CGFloat) -> CGFloat {
        switch engine {
        case .webkit:
            // WebKit's caret is two points wide, placed at the pen position minus one point and
            // rounded, then rounded outward on screen (three points wide when the line sits at a
            // fractional position).
            if scale >= 2, caret.width > 1.5 && caret.width < 2.5 { return caret.minX + 0.75 }
            if scale >= 2, caret.width > 2.5 && caret.width < 3.5 { return caret.minX + 1.25 }
            if caret.width > 0.5 && caret.width < 1.5 { return caret.minX + 0.5 }
            return caret.minX
        case .blink, .gecko, .native:
            return caret.minX
        }
    }

    /// Where the caret's line really starts (AX x), as a range, from the whole-point boxes the engine
    /// reported and the width `width` of the line's text so far. Each box is the true position rounded
    /// its own way; together they bound it. Nil when the boxes don't fit together (the line changed).
    static func lineStartRange(engine: TextEngine, lineStart: CGRect, caret: CGRect?, lineBox: CGRect?,
                               textBox: CGRect?, width: CGFloat) -> ClosedRange<CGFloat>? {
        let epsilon: CGFloat = 1 / 256
        var lower: CGFloat, upper: CGFloat
        switch engine {
        case .blink:
            // Line starts and carets are rounded to the nearest point.
            lower = lineStart.minX - 0.5; upper = lineStart.minX + 0.5 - epsilon
            if let caret {
                // Chromium's own advances drift from CoreText's by about a hundredth of a point per
                // character; leave that much slack so the range doesn't settle on the wrong side.
                let slack = min(0.25, 0.04 + width * 0.0012)
                lower = max(lower, caret.minX - width - 0.5 - slack); upper = min(upper, caret.minX - width + 0.5 + slack)
            }
            // (Right edges are rounded inconsistently, so the line box adds nothing reliable.)
            _ = lineBox
        case .webkit:
            // A 2-point caret box at a line start sits exactly on it; 3 points means a fraction past it.
            if lineStart.width > 1.5 && lineStart.width < 2.5 { lower = lineStart.minX; upper = lineStart.minX }
            else if lineStart.width > 2.5 && lineStart.width < 3.5 { lower = lineStart.minX + epsilon; upper = lineStart.minX + 1 - epsilon }
            else { return nil }
            // A text run's box encloses its glyphs: left edge rounded down, right edge up.
            if let box = textBox, abs(box.minX - lineStart.minX) <= 1 {
                lower = max(lower, box.minX); upper = min(upper, box.minX + 1 - epsilon)
                lower = max(lower, box.maxX - 1 - width + epsilon); upper = min(upper, box.maxX - width)
            }
        case .native, .gecko:
            return nil
        }
        return lower <= upper ? lower...upper : nil
    }

    /// The caret's x from the start of its line plus the width of the text since then (measured in
    /// the field's font), when that agrees with the rounded caret box. Lines usually start on a whole
    /// point (padding and borders are whole points), which the rounded box alone can't tell.
    static func refinedCaretX(engine: TextEngine, reported caret: CGRect, lineStart: CGRect, advance: CGFloat,
                              scale: CGFloat) -> CGFloat? {
        guard advance > 0 else { return nil }
        switch engine {
        case .webkit:
            guard scale >= 2 else { return nil }
            // At a line start the caret box is clamped to the line's left edge: a 2-point box starts
            // exactly there; a 3-point box means the line sits at an unknown fraction of a point.
            let start: CGFloat
            if lineStart.width > 1.5 && lineStart.width < 2.5 { start = lineStart.minX }
            else if lineStart.width > 2.5 && lineStart.width < 3.5 { start = lineStart.minX + 0.5 }
            else { return nil }
            let x = start + advance
            // The caret box is the pen position (snapped to half points) minus one point, rounded:
            // the pen lies 0.25–1.75 points inside it, a point more when the box is 3 points wide.
            let window: ClosedRange<CGFloat> = caret.width < 2.5 ? (caret.minX + 0.2)...(caret.minX + 1.8)
                                                                 : (caret.minX + 0.2)...(caret.minX + 2.8)
            return window.contains(x) ? x : nil
        case .blink:
            // Chromium rounds both boxes to the nearest point.
            let x = lineStart.minX + advance
            return abs(x - caret.minX) <= 0.55 ? x : nil
        case .native, .gecko:
            return nil
        }
    }
}
