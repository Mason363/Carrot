import AppKit
import CoreText

/// Finds the pixel row an app drew a piece of text on, by rendering the same text and comparing
/// it with a capture of the screen. Pure computation: no capture, no state.
enum CalibrationMatcher {
    struct Request {
        /// The text just before the caret, as the app drew it.
        var text: String
        var font: NSFont
        var kernsAfterSpaces: Bool
        /// Where the text is believed to start (pen x) and its baseline, in global top-left points.
        var penX: CGFloat
        var baselineY: CGFloat
        /// The captured area, in the same coordinates.
        var region: CGRect
        /// Device pixels per point of the capture.
        var scale: CGFloat
    }

    struct Result: Equatable {
        var penX: CGFloat
        var baselineY: CGFloat
        /// Normalised correlation of the best match (1 = identical).
        var score: Float
    }

    /// How far from the estimate to look (points).
    static let verticalRange: CGFloat = 1.5
    static let horizontalRange: CGFloat = 1.0

    /// The baseline at which `request.text` sits in `image`, or nil when nothing matches convincingly
    /// (selection highlights, a different font…).
    ///
    /// Only the vertical position is reported. Apps lay glyphs out a hair differently from CoreText,
    /// so the text is also slid sideways while matching, but the horizontal fit is only a means to
    /// compare rows: the pixel row the text sits on is what the accessibility geometry can't tell.
    static func match(image: CGImage, request: Request) -> Result? {
        let width = Int((request.region.width * request.scale).rounded())
        let height = Int((request.region.height * request.scale).rounded())
        guard width >= 8, height >= 8, width <= 2048, height <= 512,
              let captured = grayscale(image, width: width, height: height) else { return nil }
        var ink = inkMap(captured)
        guard ink.contains(where: { $0 > 0.3 }) else { return nil }
        // A text caret (the app may not have redrawn since the last keystroke) is a bar taller
        // than any glyph: leave such columns out.
        let glyphHeight = (request.font.ascender - request.font.descender) * request.scale
        let caretRows = Int((glyphHeight * 0.85).rounded(.up))
        var caretColumns = Set<Int>()
        for column in 0..<width {
            var rows = 0
            for row in 0..<height where ink[row * width + column] > 0.5 { rows += 1 }
            if rows >= caretRows { caretColumns.formUnion([column - 1, column, column + 1]) }
        }
        for column in caretColumns where column >= 0 && column < width {
            for row in 0..<height { ink[row * width + column] = 0 }
        }

        let pixel = 1 / request.scale
        let verticalSteps = Int((verticalRange / pixel).rounded())
        let horizontalStep = pixel / 2
        let horizontalSteps = Int((horizontalRange / horizontalStep).rounded())
        // For each row offset, the best score over the horizontal offsets.
        var scores = [Int: [Int: Float]]() // dy → dx index → score
        for dxIndex in -horizontalSteps...horizontalSteps {
            guard let rendered = render(request, offsetX: CGFloat(dxIndex) * horizontalStep, width: width, height: height)
            else { continue }
            for dy in -verticalSteps...verticalSteps {
                scores[dy, default: [:]][dxIndex] = correlation(ink, rendered, width: width, height: height, shiftRows: dy)
            }
        }
        let rowScores = scores.mapValues { $0.values.max() ?? -1 }
        let ranked = rowScores.sorted { $0.value > $1.value }
        guard let best = ranked.first, best.value >= 0.75 else { return nil }
        // The best row must clearly beat the others, or the baseline isn't really known.
        if ranked.count > 1, best.value - ranked[1].value < 0.012 { return nil }
        // The horizontal fit on that row, refined between samples (useful where the app's glyph
        // advances are CoreText's own, as in Chromium).
        let row = scores[best.key] ?? [:]
        var penX = request.penX
        if let bestDx = row.max(by: { $0.value < $1.value })?.key {
            var refined = CGFloat(bestDx)
            if let left = row[bestDx - 1], let right = row[bestDx + 1], let center = row[bestDx] {
                let denominator = left - 2 * center + right
                if abs(denominator) > 1e-6 { refined += CGFloat(max(-0.5, min(0.5, 0.5 * (left - right) / denominator))) }
            }
            penX += refined * horizontalStep
        }
        return Result(penX: penX, baselineY: request.baselineY + CGFloat(best.key) * pixel, score: best.value)
    }

    /// Normalised cross-correlation of `a` and `b` with `b` moved down by `shiftRows` rows.
    static func correlation(_ a: [Float], _ b: [Float], width: Int, height: Int, shiftRows: Int) -> Float {
        var dot: Float = 0, aa: Float = 0, bb: Float = 0
        for row in 0..<height {
            let source = row - shiftRows
            guard source >= 0, source < height else { continue }
            let ra = row * width, rb = source * width
            for column in 0..<width {
                let x = a[ra + column], y = b[rb + column]
                dot += x * y
                aa += x * x
                bb += y * y
            }
        }
        guard aa > 0, bb > 0 else { return -1 }
        return dot / (aa * bb).squareRoot()
    }

    // MARK: Pixels

    /// The image as 0–255 gray values, top row first.
    static func grayscale(_ image: CGImage, width: Int, height: Int) -> [Float]? {
        var bytes = [UInt8](repeating: 0, count: width * height)
        let ok = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                                          bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            context.interpolationQuality = .none
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return ok ? bytes.map(Float.init) : nil
    }

    /// How far each pixel is from the background (the most common value), 0…1. Works for dark text
    /// on light backgrounds and the other way round.
    static func inkMap(_ gray: [Float]) -> [Float] {
        var histogram = [Int](repeating: 0, count: 256)
        for v in gray { histogram[Int(max(0, min(255, v)))] += 1 }
        let background = Float(histogram.indices.max { histogram[$0] < histogram[$1] } ?? 255)
        let distances = gray.map { abs($0 - background) }
        let peak = max(distances.max() ?? 1, 1)
        return distances.map { $0 / peak }
    }

    /// The text drawn white on black at the estimated position shifted by `offsetX` points.
    static func render(_ request: Request, offsetX: CGFloat, width: Int, height: Int) -> [Float]? {
        var bytes = [UInt8](repeating: 0, count: width * height)
        let ok = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                                          bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            context.setAllowsFontSmoothing(false)
            context.setShouldSmoothFonts(false)
            context.setAllowsAntialiasing(true)
            context.setShouldAntialias(true)
            context.setAllowsFontSubpixelPositioning(true)
            context.setShouldSubpixelPositionFonts(true)
            context.setAllowsFontSubpixelQuantization(false)
            context.setShouldSubpixelQuantizeFonts(false)
            context.scaleBy(x: request.scale, y: request.scale)
            context.textMatrix = .identity
            // Region coordinates are top-left; the context's are bottom-left.
            let x = request.penX + offsetX - request.region.minX
            let baselineFromBottom = request.region.maxY - request.baselineY
            GhostView.draw(request.text, font: request.font, color: .white, kernsAfterSpaces: request.kernsAfterSpaces,
                           at: CGPoint(x: x, y: baselineFromBottom), in: context)
            return true
        }
        guard ok else { return nil }
        // Bitmap contexts keep the top row first, like `grayscale`.
        return bytes.map { Float($0) / 255 }
    }
}
