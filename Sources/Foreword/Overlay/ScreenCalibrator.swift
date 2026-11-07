import AppKit
import ScreenCaptureKit

/// Optional, opt-in: finds the pixel row an app drew the text before the caret on by looking at the
/// screen, for apps whose accessibility geometry is only accurate to the point (web browsers).
///
/// Once per line it captures a thin strip of the screen just left of the caret (never the ghost
/// itself: this app's windows are excluded), matches it against the same text rendered at
/// candidate positions, and remembers the line's baseline. The
/// capture is used for that comparison only: it is never stored or sent anywhere.
@MainActor
final class ScreenCalibrator {
    static let shared = ScreenCalibrator()

    /// A line of text in a field, identified by where the app says it is.
    struct LineKey: Hashable {
        var element: AXElement
        var lineTop: Int
        var lineStartX: Int
        var fontSize: Int
    }

    /// Where the line's text really starts (pen x), its baseline (global top-left points), and the
    /// face it is drawn in (when the app didn't name it, the candidate whose glyphs matched).
    struct Calibration {
        var lineStartX: CGFloat
        var baselineY: CGFloat
        var fontName: String
        /// How many characters the match was made from; more give a better horizontal fit.
        var characters: Int
    }

    /// One way the text before the caret might look: a candidate face, and where its tail starts
    /// relative to the line's start.
    struct Candidate {
        var request: CalibrationMatcher.Request
        var lineOffset: CGFloat
    }

    private var results: [LineKey: Calibration] = [:]
    private var attempts: [LineKey: Int] = [:]
    private var inFlight: LineKey?
    private var filterCache: (displayID: CGDirectDisplayID, filter: SCContentFilter, at: Date)?

    var isEnabled: Bool { Preferences.shared.exactPlacement && Self.hasPermission }

    static var hasPermission: Bool { CGPreflightScreenCaptureAccess() }

    /// Asks macOS for screen recording permission; opens the settings pane when it won't ask again.
    static func requestPermission() {
        if !CGRequestScreenCaptureAccess(),
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    func calibration(for key: LineKey) -> Calibration? { results[key] }

    func forgetAll() {
        results.removeAll()
        attempts.removeAll()
    }

    /// Calibrates `key` in the background unless it already was (or failed twice). `completion`
    /// runs on the main actor when a new calibration is available.
    func calibrate(_ key: LineKey, candidates: [Candidate], completion: @escaping () -> Void) {
        guard isEnabled, inFlight == nil, attempts[key, default: 0] < 3, let request = candidates.first?.request else { return }
        // A line is measured again once there is much more text to match than the first time.
        if let existing = results[key], existing.characters >= 8 || request.text.count < existing.characters * 2 { return }
        var displayID: CGDirectDisplayID = 0
        var count: UInt32 = 0
        guard CGGetDisplaysWithPoint(CGPoint(x: request.region.midX, y: request.region.midY), 1, &displayID, &count) == .success,
              count == 1 else { return }
        inFlight = key
        attempts[key, default: 0] += 1
        if results.count > 200 { results.removeAll() }
        let displayBounds = CGDisplayBounds(displayID) // global top-left points
        Task {
            defer { self.inFlight = nil }
            // Let the app finish painting what was just typed.
            try? await Task.sleep(nanoseconds: 50_000_000)
            guard let filter = await self.filter(for: displayID) else { self.debug("no capture filter"); return }
            let configuration = SCStreamConfiguration()
            configuration.sourceRect = request.region.offsetBy(dx: -displayBounds.minX, dy: -displayBounds.minY)
            configuration.width = Int((request.region.width * request.scale).rounded())
            configuration.height = Int((request.region.height * request.scale).rounded())
            configuration.showsCursor = false
            configuration.captureResolution = .best
            let image: CGImage
            do {
                image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
            } catch {
                self.debug("capture failed: \(error)")
                return
            }
            // Every candidate face against the same capture; the best match wins.
            let matched = await Task.detached(priority: .userInitiated) { () -> (CalibrationMatcher.Result, Candidate)? in
                var best: (CalibrationMatcher.Result, Candidate)?
                for candidate in candidates {
                    var r = candidate.request
                    r.region = request.region
                    guard let result = CalibrationMatcher.match(image: image, request: r) else { continue }
                    if best == nil || result.score > best!.0.score + 0.005 { best = (result, candidate) }
                }
                return best
            }.value
            let result = matched?.0
            if TestBench.isDebugging {
                self.debug("text \(request.text.count) chars, region \(NSStringFromRect(request.region)) -> "
                           + (result.map { String(format: "baseline %+.2f score %.3f", $0.baselineY - request.baselineY, $0.score) }
                              ?? "no match"))
                self.lastCapture = image
                self.captureCount += 1
                let base = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("foreword-calibration-\(self.captureCount)")
                if let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) {
                    try? data.write(to: base.appendingPathExtension("png"))
                }
                let info: [String: Any] = ["text": request.text, "font": request.font.fontName, "size": request.font.pointSize,
                                           "kerns": request.kernsAfterSpaces, "penX": request.penX, "baselineY": request.baselineY,
                                           "region": [request.region.minX, request.region.minY, request.region.width, request.region.height],
                                           "scale": request.scale]
                if let json = try? JSONSerialization.data(withJSONObject: info) { try? json.write(to: base.appendingPathExtension("json")) }
                self.debug("saved \(base.path)")
            }
            guard let (result, candidate) = matched else { return }
            self.results[key] = Calibration(lineStartX: result.penX - candidate.lineOffset, baselineY: result.baselineY,
                                            fontName: candidate.request.font.fontName, characters: request.text.count)
            self.debug("font \(candidate.request.font.fontName) of \(candidates.count)")
            completion()
        }
    }

    /// The last capture (debug runs only), for inspection.
    private(set) var lastCapture: CGImage?
    private var captureCount = 0

    private func debug(_ message: String) {
        guard TestBench.isDebugging else { return }
        FileHandle.standardError.write("calibration: \(message)\n".data(using: .utf8)!)
    }

    /// Everything on the display except this app's own windows (the ghost must never match itself).
    private func filter(for displayID: CGDirectDisplayID) async -> SCContentFilter? {
        if let cached = filterCache, cached.displayID == displayID, Date().timeIntervalSince(cached.at) < 30 {
            return cached.filter
        }
        guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true),
              let display = content.displays.first(where: { $0.displayID == displayID }) else { return nil }
        // Exclude this process's windows only (the ghost overlay above all), by window.
        let pid = ProcessInfo.processInfo.processIdentifier
        let own = content.windows.filter { $0.owningApplication?.processID == pid }
        let filter = SCContentFilter(display: display, excludingWindows: own)
        filterCache = (displayID, filter, Date())
        return filter
    }
}
