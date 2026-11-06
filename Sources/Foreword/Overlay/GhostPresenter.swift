import AppKit
import ForewordEngine

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
    /// Where the current line starts (AX x), narrowed keystroke by keystroke: each new set of rounded
    /// boxes bounds it differently.
    private var lineStartEstimate: (element: AXElement, line: CGRect, range: ClosedRange<CGFloat>)?

    struct Layout {
        var caret: CGRect          // AX coordinates
        var font: NSFont
        var baseline: CGFloat
        var style: GhostContent.Style
        var frame: NSRect          // Cocoa coordinates
        var anchorX: CGFloat       // Cocoa x of the caret
        var debug = ""
    }

    init() {
        panel.contentView = view
        panel.alphaValue = 0
        panel.orderFrontRegardless()
    }

    var debugFrame: NSRect { panel.frame }
    var debugLayout: String {
        guard let l = lastLayout else { return "" }
        return String(format: "caret %.3f,%.3f h %.3f baseline %.3f font %@ %.3f asc %.4f desc %.4f leading %.4f",
                      l.caret.minX, l.caret.minY, l.caret.height, l.baseline, l.font.fontName, l.font.pointSize,
                      l.font.ascender, l.font.descender, l.font.leading) + l.debug
    }

    // MARK: Showing

    /// Shows `text` for `snapshot`. Returns the text actually displayed (possibly trimmed to fit), or
    /// nil when it can't be shown sensibly.
    @discardableResult
    func show(_ text: String, snapshot: FieldSnapshot, preferPill: Bool, correction original: String? = nil,
              correctionRect: CGRect? = nil) -> String? {
        let prefs = Preferences.shared
        guard var caretRect = correctionRect ?? snapshot.caret ?? fallbackCaret(for: snapshot) else { hide(); return nil }
        let engine = snapshot.info.engine
        let reportedHeight = snapshot.reportedCaret?.height
        let font = matchedFont(name: snapshot.fontName, size: snapshot.fontSize, caretHeight: caretRect.height,
                               sampleText: snapshot.sampleText, sampleWidth: snapshot.sampleWidth,
                               web: snapshot.info.isWebContent,
                               heightCheck: reportedHeight == nil || engine != .blink ? nil : { height in
                                   { font in TextEngine.blinkBoxHeights(font: font, scale: 2).contains(height.rounded()) }
                               })
        let color = ghostColor(textColor: snapshot.textColor)
        let hint = prefs.showKeyHint ? prefs.acceptAllKey.displayString : nil
        let screen = ScreenGeometry.screen(containing: CGPoint(x: caretRect.midX, y: ScreenGeometry.primaryHeight - caretRect.midY))
        let scale = screen?.backingScaleFactor ?? 2
        let visible = screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero

        var style: GhostContent.Style = original != nil ? .correction(original: original!) : .inline
        var shown = text
        // Web engines report whole-point caret boxes; their own rounding rules say where the text is.
        let reported = correctionRect == nil ? snapshot.reportedCaret : nil
        let kernsAfterSpaces = engine != .webkit
        if let reported, engine != .native, abs(reported.minY - caretRect.minY) < 0.5 {
            caretRect.origin.x = TextEngine.caretX(engine: engine, reported: reported, scale: scale)
            if let lineStart = snapshot.lineStart, let lineText = snapshot.lineText {
                let advance = GhostView.exactWidth(of: lineText, font: font, kernsAfterSpaces: kernsAfterSpaces)
                if let x = refinedLineX(snapshot: snapshot, lineStart: lineStart, reported: reported, advance: advance,
                                        engine: engine, scale: scale) {
                    caretRect.origin.x = x
                }
            }
        }
        // Baseline from the top of the caret's line box, snapped to device pixels like the app's text.
        let modelBaseline = reported.flatMap { reported -> CGFloat? in
            guard abs(reported.minY - caretRect.minY) < 0.5 else { return nil }
            return TextEngine.baseline(engine: engine, font: font, caret: reported, scale: scale,
                                       isRichText: snapshot.info.isRichText, laterLineInBlock: snapshot.laterLineInBlock,
                                       textBox: snapshot.laterLineInBlock ? nil : snapshot.textBox)
        }
        let baseline = modelBaseline
            ?? round(Self.baseline(for: font, lineHeight: caretRect.height, web: snapshot.info.isWebContent) * scale) / scale
        // The app kerns the letter before the caret with the next one typed; the ghost's first letter
        // sits where that letter will.
        if style == .inline, correctionRect == nil, let previous = snapshot.prefix.last, let first = shown.first {
            caretRect.origin.x += GhostView.pairKerning(previous, first, font: font, kernsAfterSpaces: kernsAfterSpaces)
        }

        // Continuation lines when the suggestion runs past the end of the line, laid out the way the
        // field wraps its own text.
        var wrapped: (lines: [String], left: CGFloat, pitch: CGFloat)?
        if style == .inline {
            if preferPill || snapshot.caretIsEstimated || snapshot.caret == nil {
                style = .pill
            } else {
                let wrap = wrapGeometry(snapshot: snapshot, caret: caretRect, font: font, engine: engine, scale: scale)
                // Does it fit before the end of the line?
                let available: CGFloat
                if let wrap {
                    available = wrap.right - caretRect.minX
                } else if let field = snapshot.fieldFrame, field.width > 20 {
                    available = field.maxX - caretRect.minX - 6
                } else {
                    available = visible.maxX - caretRect.minX - 8
                }
                if GhostView.exactWidth(of: shown.trailingSpacesTrimmed, font: font, kernsAfterSpaces: kernsAfterSpaces) > available {
                    if let wrap, let lines = wrapLines(shown, firstWidth: available, wrap: wrap, caret: caretRect,
                                                       baseline: baseline, font: font, kernsAfterSpaces: kernsAfterSpaces,
                                                       overflowLimit: (snapshot.fieldFrame?.maxX ?? wrap.right) - caretRect.minX) {
                        wrapped = (lines, wrap.left, wrap.pitch)
                        shown = lines.joined()
                    } else if let fitted = fit(shown, font: font, width: available) {
                        shown = fitted
                    } else {
                        style = .pill
                    }
                }
            }
        }

        var content = GhostContent(text: shown, style: style, font: font, color: color,
                                   hint: style == .inline ? nil : hint, baseline: baseline, lineHeight: caretRect.height)
        if style == .inline { content.kernsAfterSpaces = kernsAfterSpaces }
        let cocoaCaret = ScreenGeometry.cocoaRect(fromAX: caretRect)
        var frame: NSRect
        switch style {
        case .inline:
            // Window on the pixel grid with a small margin (glyphs can overhang their advance);
            // the text itself is drawn at the exact fractional caret position inside it.
            // macOS places windows on whole points, so the frame is snapped to whole points and the
            // fractional part of the caret position goes into where the text is drawn.
            let margin: CGFloat = 2
            let lines = wrapped?.lines ?? [shown]
            let pitch = wrapped?.pitch ?? 0
            let continuationX = wrapped?.left ?? cocoaCaret.minX
            // Baselines in Cocoa coordinates (y up), one per line.
            let firstBaseline = cocoaCaret.maxY - baseline
            let baselines = lines.indices.map { firstBaseline - CGFloat($0) * pitch }
            let xs = lines.indices.map { $0 == 0 ? cocoaCaret.minX : continuationX }
            let widths = lines.map { GhostView.exactWidth(of: $0, font: font, kernsAfterSpaces: kernsAfterSpaces) }
            let left = floor(xs.min()! - margin)
            let right = ceil(zip(xs, widths).map { $0 + $1 }.max()! + margin)
            let lineTop = cocoaCaret.maxY // Cocoa y of the top of the line box
            let top = ceil(max(lineTop, firstBaseline + font.ascender) + margin)
            let lastBaseline = baselines.last!
            let bottom = floor(min(lines.count == 1 ? cocoaCaret.minY : lastBaseline, lastBaseline + font.descender) - margin)
            frame = NSRect(x: left, y: bottom, width: right - left, height: top - bottom)
            content.text = lines[0]
            content.originX = cocoaCaret.minX - left
            content.baseline = top - firstBaseline
            content.extraLines = lines.indices.dropFirst().map {
                GhostLine(text: lines[$0], x: continuationX - left, baseline: top - baselines[$0])
            }
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
        if style != .inline {
            frame.origin.x = round(frame.origin.x * scale) / scale
            frame.origin.y = round(frame.origin.y * scale) / scale
        }

        apply(content: content, frame: frame)
        lastLayout = Layout(caret: caretRect, font: font, baseline: baseline, style: style, frame: frame, anchorX: cocoaCaret.minX)
        if TestBench.isDebugging {
            let r = snapshot.reportedCaret, ls = snapshot.lineStart
            let est = lineStartEstimate.map { String(format: "[%.3f, %.3f]", $0.range.lowerBound, $0.range.upperBound) } ?? "nil"
            lastLayout?.debug = " | startRange " + est + String(format: " | engine %@ rich %d later %d textBox %@ reported %@ lineStart %@ lineText %ld advance %.3f",
                                       engine.rawValue, snapshot.info.isRichText ? 1 : 0, snapshot.laterLineInBlock ? 1 : 0,
                                       snapshot.textBox.map { NSStringFromRect($0) } ?? "nil",
                                       r.map { NSStringFromRect($0) } ?? "nil", ls.map { NSStringFromRect($0) } ?? "nil",
                                       snapshot.lineText?.count ?? -1,
                                       snapshot.lineText.map { GhostView.exactWidth(of: $0, font: font) } ?? -1)
        }
        displayedText = shown
        return shown
    }

    /// The user typed `typed` and it matched the start of the suggestion: shift the ghost right by
    /// the typed text's width and drop it from the displayed text, without waiting for the app.
    func advance(by typed: String, remaining: String) {
        guard isVisible, var content, var layout = lastLayout else { return }
        // A wrapped ghost is laid out again from the app's next caret position.
        if layout.style == .inline, !content.extraLines.isEmpty { return }
        if remaining.isEmpty { hide(); return }
        let wasDisplayed = displayedText
        displayedText = remaining
        content.text = remaining
        var frame = layout.frame
        switch layout.style {
        case .inline:
            // Where the rest started inside the drawn line, kerning included.
            let previous = wasDisplayed
            let kerns = content.kernsAfterSpaces
            let shift = previous.hasPrefix(typed) && previous.count > typed.count
                ? GhostView.exactWidth(of: previous, font: layout.font, kernsAfterSpaces: kerns)
                    - GhostView.exactWidth(of: String(previous.dropFirst(typed.count)), font: layout.font, kernsAfterSpaces: kerns)
                : GhostView.exactWidth(of: typed, font: layout.font, kernsAfterSpaces: kerns)
            layout.anchorX += shift
            layout.caret.origin.x += shift
            // The window stays on whole points (the window server would snap it); the text moves inside it.
            let margin: CGFloat = 2
            let left = floor(layout.anchorX - margin)
            frame.origin.x = left
            frame.size.width = ceil(GhostView.exactWidth(of: remaining, font: layout.font) + (layout.anchorX - left) + margin * 2)
            content.originX = layout.anchorX - left
        case .pill, .correction:
            let size = GhostView.pillSize(for: content)
            frame.size.width = size.width
        }
        apply(content: content, frame: frame)
        layout.frame = frame
        lastLayout = layout
    }

    /// Re-lays out the ghost for the app's current caret, optionally with new text (after the user
    /// typed part of it or accepted a word: the app has drawn those characters by now).
    @discardableResult
    func reposition(snapshot: FieldSnapshot, text: String? = nil) -> String? {
        guard isVisible, let content else { return nil }
        if case .correction = content.style { return displayedText }
        let preferPill = content.style != .inline
        return show(text ?? displayedText, snapshot: snapshot, preferPill: preferPill)
    }

    /// Pill/correction cards don't sit on the text, so their text can change right away.
    var isInline: Bool { content?.style == .inline }

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
        var content = content
        let styleChanged = self.content?.style != content.style
        // Order matters for a flicker-free update: draw the new content, then move, then reveal.
        NSAnimationContext.beginGrouping()
        NSAnimationContext.current.duration = 0
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if panel.frame != frame { panel.setFrame(frame, display: false) }
        // If the window server adjusted the frame, keep the text where it belongs anyway.
        let actual = panel.frame
        if content.style == .inline, actual.origin != frame.origin || actual.size != frame.size {
            let dx = frame.minX - actual.minX, dy = actual.maxY - frame.maxY
            content.originX += dx
            content.baseline += dy
            content.extraLines = content.extraLines.map { GhostLine(text: $0.text, x: $0.x + dx, baseline: $0.baseline + dy) }
        }
        self.content = content
        view.content = content
        view.frame = NSRect(origin: .zero, size: actual.size)
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

    /// Fonts to try when an app reports a size but no family (Chromium does this). The text the
    /// user just typed was drawn by the app; the candidate whose advance matches it is the font.
    private static let nativeCandidates = [".AppleSystemUIFont", "HelveticaNeue", "Helvetica"]
    // In priority order: faces with the same widths (Arial and Helvetica) resolve to the earlier one,
    // as a "font-family: Arial, Helvetica" stack does on a Mac.
    private static let webCandidates = [
        ".AppleSystemUIFont", "Arial", "Helvetica", "HelveticaNeue", "Roboto", "Inter", "Google Sans Text", "Open Sans",
        "Lato", "Verdana", "Tahoma", "Trebuchet MS", "Georgia", "Times New Roman", "Charter", "Menlo", "Courier New",
        "SF Mono", "Avenir Next",
    ]
    private var fingerprintCache: [String: (name: String, size: CGFloat)] = [:]

    /// Browser zoom levels: a face drawn at one of these multiples of its reported size.
    private static let zoomLevels: [CGFloat] = [1, 0.9, 1.1, 0.8, 1.25, 0.75, 1.5, 0.67, 1.75, 2, 0.5, 0.33, 2.5, 3]

    /// Identifies the face an app drew `sample` in from its width. Faces built to the same widths
    /// (Arial and Helvetica) differ in height: `heightMatches` tells which agrees with the line box
    /// the app reported, and wins among faces whose widths fit.
    private func fingerprint(sample: String, width: CGFloat, size: CGFloat, web: Bool,
                             heightMatches: ((NSFont) -> Bool)? = nil, heightKey: CGFloat = 0) -> NSFont? {
        let key = "\(web)|\(size)|\(sample)|\(width)|\(heightKey)"
        if let hit = fingerprintCache[key] { return Self.font(named: hit.name, size: hit.size) }
        // The measured width is rounded to whole points at each end, so allow that much slack.
        let tolerance = max(0.012, 1.6 / max(width, 1))
        var candidates: [(name: String, error: CGFloat, zoom: CGFloat, font: NSFont)] = []
        for name in web ? Self.webCandidates : Self.nativeCandidates {
            guard let font = Self.font(named: name, size: size) else { continue }
            let measured = GhostView.exactWidth(of: sample, font: font)
            guard measured > 0 else { continue }
            let ratio = width / measured
            guard let zoom = Self.zoomLevels.min(by: { abs(ratio - $0) < abs(ratio - $1) }) else { continue }
            candidates.append((name, abs(ratio - zoom) / zoom, zoom, font))
        }
        guard let closest = candidates.min(by: { $0.error < $1.error }), closest.error < max(0.03, tolerance) else { return nil }
        var best = closest
        // Every face whose width fits within measuring error is as good as the closest: the one whose
        // height agrees with the app's line box wins, then the earlier one in the list.
        let fitting = candidates.filter { $0.error <= max(tolerance, closest.error * 1.5) }
        if let heightMatches, let agreeing = fitting.first(where: {
            heightMatches(Self.font(named: $0.name, size: size * $0.zoom) ?? $0.font)
        }) {
            best = agreeing
        } else if let first = fitting.first {
            best = first
        }
        // Within measuring error the face is drawn at an exact zoom level of its reported size;
        // otherwise (an unusual zoom) take the size the measurement implies.
        let measured = GhostView.exactWidth(of: sample, font: best.font)
        let tuned = best.error <= tolerance ? size * best.zoom : size * width / max(measured, 0.1)
        if fingerprintCache.count > 64 { fingerprintCache.removeAll() }
        fingerprintCache[key] = (best.name, tuned)
        return Self.font(named: best.name, size: tuned) ?? best.font
    }

    /// A font from what an app reports: a PostScript or full name, or (Firefox) a CSS family name.
    static func resolveFont(_ name: String, size: CGFloat) -> NSFont? {
        let lowered = name.lowercased()
        if ["-apple-system", "system-ui", "blinkmacsystemfont", ".applesystemuifont", "sans-serif"].contains(lowered)
            || lowered.hasPrefix(".sf") {
            return .systemFont(ofSize: size)
        }
        if lowered == "ui-monospace" || lowered == "monospace" { return .monospacedSystemFont(ofSize: size, weight: .regular) }
        if let font = NSFont(name: name, size: size) { return font }
        return NSFontManager.shared.font(withFamily: name, traits: [], weight: 5, size: size)
    }

    private static func font(named name: String, size: CGFloat) -> NSFont? {
        name == ".AppleSystemUIFont" ? NSFont.systemFont(ofSize: size) : NSFont(name: name, size: size)
    }

    /// The field's font when the app reports it, scaled by the caret height when the content is zoomed.
    func matchedFont(name: String?, size reportedSize: CGFloat?, caretHeight: CGFloat,
                     sampleText: String? = nil, sampleWidth: CGFloat? = nil, web: Bool = false,
                     heightCheck: ((CGFloat) -> (NSFont) -> Bool)? = nil) -> NSFont {
        // No family reported: identify it from what the app drew.
        if name == nil, let sampleText, let sampleWidth, sampleText.count >= 4, sampleWidth > 8 {
            let size = reportedSize.map { $0 >= 4 ? $0 : caretHeight / 1.2 } ?? caretHeight / 1.2
            let heightMatches = heightCheck?(caretHeight)
            if let font = fingerprint(sample: sampleText, width: sampleWidth, size: size, web: web,
                                      heightMatches: heightMatches, heightKey: heightMatches == nil ? 0 : caretHeight) { return font }
            // Unknown face: the system font, sized so its advance matches what the app drew.
            let system = NSFont.systemFont(ofSize: size)
            let measured = GhostView.exactWidth(of: sampleText, font: system)
            if measured > 0 {
                let scaled = size * sampleWidth / measured
                if (0.6...1.6).contains(scaled / size) { return NSFont.systemFont(ofSize: scaled) }
            }
        }
        var size: CGFloat
        if let reportedSize, reportedSize >= 4 {
            let ratio = caretHeight / reportedSize
            // A line is normally 1.1–1.8× the font size; outside that the view is zoomed.
            size = (0.95...1.9).contains(ratio) ? reportedSize : caretHeight / 1.2
            // With the real font known, the width of the text just typed reveals the zoom exactly.
            if let name, let sampleText, let sampleWidth, sampleWidth > 4,
               let reference = Self.resolveFont(name, size: reportedSize) {
                let expected = GhostView.exactWidth(of: sampleText, font: reference)
                if expected > 4 {
                    let zoom = sampleWidth / expected
                    if (0.4...4).contains(zoom), abs(zoom - 1) > 0.06 { size = reportedSize * zoom }
                }
            }
        } else {
            size = caretHeight / 1.2
        }
        size = min(max(size, 6), 120)
        if let name, let font = Self.resolveFont(name, size: size) { return font }
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
                    // Never stop on "…and" / "…the" just because the line ran out.
                    if !TextAnalysis.endsDangling(current) || best == nil { best = current }
                } else {
                    break
                }
            }
            index = next
        }
        guard let best, best.count >= 2 else { return nil }
        return best
    }

    /// The caret's x as the line's start plus the width of the text on it, with the start narrowed
    /// down by every keystroke's boxes on the same line.
    private func refinedLineX(snapshot: FieldSnapshot, lineStart: CGRect, reported: CGRect, advance: CGFloat,
                              engine: TextEngine, scale: CGFloat) -> CGFloat? {
        let element = snapshot.info.element
        let current = TextEngine.lineStartRange(engine: engine, lineStart: lineStart, caret: engine == .blink ? reported : nil,
                                                lineBox: snapshot.lineBox, textBox: snapshot.textBox, width: advance)
        var range = current
        if let estimate = lineStartEstimate, estimate.element == element,
           abs(estimate.line.minY - lineStart.minY) < 0.5, abs(estimate.line.minX - lineStart.minX) < 0.5 {
            if let current {
                let lower = max(current.lowerBound, estimate.range.lowerBound)
                let upper = min(current.upperBound, estimate.range.upperBound)
                range = lower <= upper ? lower...upper : current
            } else {
                range = estimate.range
            }
        }
        guard let range else {
            // Fall back to the single-box rule.
            return TextEngine.refinedCaretX(engine: engine, reported: reported, lineStart: lineStart, advance: advance, scale: scale)
        }
        lineStartEstimate = (element, lineStart, range)
        let x = (range.lowerBound + range.upperBound) / 2 + advance
        // Never stray from what the caret box itself says.
        return abs(x - (reported.minX + reported.width / 2)) <= 2 ? x : nil
    }

    struct WrapGeometry {
        /// AX x where continuation lines start, and where lines end.
        var left: CGFloat
        var right: CGFloat
        /// Distance between baselines.
        var pitch: CGFloat
        /// AX y below which the field's text can't be seen.
        var bottom: CGFloat
    }

    /// How the field wraps lines: continuation lines start at the paragraph's left edge, and text
    /// stops as far inside the right edge as it starts inside the left (padding is symmetric).
    private func wrapGeometry(snapshot: FieldSnapshot, caret: CGRect, font: NSFont, engine: TextEngine,
                              scale: CGFloat) -> WrapGeometry? {
        guard !snapshot.info.isSingleLine, let field = snapshot.fieldFrame, field.width > 40,
              let lineStart = snapshot.lineStart else { return nil }
        // A web page's line spacing (CSS line-height) is only knowable from two lines on screen.
        if engine != .native, snapshot.previousLineTop == nil { return nil }
        var left = lineStart.minX
        if engine == .webkit, lineStart.width > 2.5 && lineStart.width < 3.5 { left += 0.5 }
        let inset = left - field.minX
        guard inset >= 0, inset < field.width / 3 else { return nil }
        let right = field.maxX - inset
        guard right - left > 40, right > caret.minX - 1 else { return nil }
        let pitch = linePitch(snapshot: snapshot, caret: caret, font: font, engine: engine, scale: scale)
        let bottom = (snapshot.visibleFrame ?? field).maxY
        return WrapGeometry(left: left, right: right, pitch: pitch, bottom: bottom)
    }

    /// Distance between the baselines of consecutive lines: measured from the line above when there
    /// is one, otherwise the engine's normal line height (or the caret's line box for native text).
    private func linePitch(snapshot: FieldSnapshot, caret: CGRect, font: NSFont, engine: TextEngine, scale: CGFloat) -> CGFloat {
        let normal = TextEngine.normalLineHeight(engine: engine, font: font, scale: scale) ?? caret.height
        if let previous = snapshot.previousLineTop {
            let measured = caret.minY - previous
            if measured > font.pointSize * 0.8, measured < font.pointSize * 3.2 {
                // Both lines are rounded to whole points: within that error, the exact normal height wins.
                return engine != .native && abs(measured - normal) <= 1 ? normal : measured
            }
        }
        return normal
    }

    /// Breaks `text` into lines like the field would: greedily at spaces, spaces at a break hanging
    /// at the end of the line, the first line starting at the caret. Stops at the field's visible
    /// bottom. Nil when a single word can't be placed.
    private func wrapLines(_ text: String, firstWidth: CGFloat, wrap: WrapGeometry, caret: CGRect, baseline: CGFloat,
                           font: NSFont, kernsAfterSpaces: Bool, overflowLimit: CGFloat) -> [String]? {
        // Chunks: leading spaces plus the word after them.
        var chunks: [String] = []
        var current = ""
        var inWord = false
        for ch in text {
            if ch == " " {
                if inWord { chunks.append(current); current = ""; inWord = false }
            } else {
                inWord = true
            }
            current.append(ch)
        }
        if !current.isEmpty { chunks.append(current) }
        let width = { (s: String) in GhostView.exactWidth(of: s.trailingSpacesTrimmed, font: font, kernsAfterSpaces: kernsAfterSpaces) }
        let otherWidth = wrap.right - wrap.left
        var lines = [""]
        var limit = firstWidth
        for (index, chunk) in chunks.enumerated() {
            let candidate = lines[lines.count - 1] + chunk
            if width(candidate) <= limit + 0.01 {
                lines[lines.count - 1] = candidate
                continue
            }
            if index == 0, chunk.first != " " {
                // The end of the word being typed: the app would move the whole word down, which a
                // separate layer can't; keep it on this line if it stays inside the field.
                guard width(chunk) <= overflowLimit else { return nil }
                lines[0] = chunk
                continue
            }
            let spaces = String(chunk.prefix(while: { $0 == " " }))
            let word = String(chunk.dropFirst(spaces.count))
            guard width(word) <= otherWidth else { return nil } // the app would break inside the word
            // Would the next line still be visible?
            let nextBaseline = caret.minY + baseline + CGFloat(lines.count) * wrap.pitch
            if nextBaseline - font.descender > wrap.bottom + 1 || lines.count >= 6 { break }
            lines[lines.count - 1] += spaces
            lines.append(word)
            limit = otherWidth
        }
        // Don't end on a dangling word when the text had to stop early.
        let joined = lines.joined()
        if joined.count < text.count, TextAnalysis.endsDangling(joined), lines.count > 1 {
            var last = lines.removeLast()
            if let space = last.lastIndex(of: " ") { last = String(last[..<space]); if !last.isEmpty { lines.append(last) } }
        }
        guard lines.joined().contains(where: { !$0.isWhitespace }) else { return nil }
        return lines
    }

    private func fallbackCaret(for snapshot: FieldSnapshot) -> CGRect? {
        guard let field = snapshot.fieldFrame, field.width > 20, field.height > 8 else { return nil }
        let height = min(field.height, 20)
        return CGRect(x: field.minX + 8, y: field.maxY - height - 4, width: 0, height: height)
    }
}

private extension String {
    var trailingSpacesTrimmed: String {
        var s = self
        while s.last == " " { s.removeLast() }
        return s
    }
}
