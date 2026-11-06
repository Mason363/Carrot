import AppKit
import CoreGraphics
import os

/// A session-wide event tap on a dedicated high-priority thread. The handler runs on that thread
/// and must decide quickly whether to swallow the event.
final class KeyEventTap: @unchecked Sendable {
    /// Marks events Foreword posts itself so the tap lets them through untouched.
    static let syntheticMarker: Int64 = 0x464F_5257_4F52_4421

    /// Return `true` to consume the event.
    var handler: ((CGEventType, CGEvent) -> Bool)?

    private var tap: CFMachPort?
    private var runLoop: CFRunLoop?
    private var thread: Thread?
    private let log = Logger(subsystem: "io.github.mason363.Foreword", category: "tap")

    var isRunning: Bool { tap.map { CGEvent.tapIsEnabled(tap: $0) } ?? false }

    func start() -> Bool {
        guard thread == nil else { return true }
        let ready = DispatchSemaphore(value: 0)
        var success = false
        let thread = Thread { [weak self] in
            guard let self else { ready.signal(); return }
            let types: [CGEventType] = [.keyDown, .flagsChanged, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel]
            let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
            let callback: CGEventTapCallBack = { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let me = Unmanaged<KeyEventTap>.fromOpaque(refcon).takeUnretainedValue()
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    if let tap = me.tap { CGEvent.tapEnable(tap: tap, enable: true) }
                    return Unmanaged.passUnretained(event)
                }
                if event.getIntegerValueField(.eventSourceUserData) == KeyEventTap.syntheticMarker {
                    return Unmanaged.passUnretained(event)
                }
                if me.handler?(type, event) == true { return nil }
                return Unmanaged.passUnretained(event)
            }
            guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                              eventsOfInterest: mask, callback: callback,
                                              userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
                self.log.error("Could not create event tap")
                ready.signal()
                return
            }
            self.tap = tap
            let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
            self.runLoop = CFRunLoopGetCurrent()
            CFRunLoopAddSource(self.runLoop, source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            success = true
            ready.signal()
            CFRunLoopRun()
        }
        thread.name = "Foreword event tap"
        thread.qualityOfService = .userInteractive
        thread.start()
        self.thread = thread
        ready.wait()
        if !success { self.thread = nil }
        return success
    }

    func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let runLoop { CFRunLoopStop(runLoop) }
        tap = nil
        runLoop = nil
        thread = nil
    }
}

/// Types text into the focused app by synthesising keyboard events (works in every app,
/// including web pages, and leaves the clipboard alone).
enum TextInserter {
    private static let source: CGEventSource? = {
        let source = CGEventSource(stateID: .privateState)
        source?.userData = KeyEventTap.syntheticMarker
        return source
    }()

    /// Observe mode only: the field to edit through Accessibility (the observed app is in the
    /// background, so synthesized key events would reach whichever app the user is in).
    @MainActor static var observedTarget: AXElement?

    @MainActor
    static func type(_ text: String) {
        guard !text.isEmpty else { return }
        if TestBench.isActive { TestBench.insertHandler?(text); return }
        if TestBench.observedBundleID != nil {
            if let target = observedTarget {
                AXQueue.queue.async { target.set(kAXSelectedTextAttribute, text as CFString) }
            }
            return
        }
        let units = Array(text.utf16)
        var index = 0
        while index < units.count {
            // Up to 20 UTF-16 units per event, never splitting a surrogate pair.
            var end = min(index + 20, units.count)
            if end < units.count, UTF16.isLeadSurrogate(units[end - 1]) { end -= 1 }
            let chunk = Array(units[index..<end])
            post(chunk)
            index = end
        }
    }

    private static func post(_ chunk: [UniChar]) {
        for keyDown in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: keyDown) else { continue }
            event.flags = []
            chunk.withUnsafeBufferPointer { buffer in
                event.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: buffer.baseAddress)
            }
            event.setIntegerValueField(.eventSourceUserData, value: KeyEventTap.syntheticMarker)
            event.post(tap: .cgSessionEventTap)
        }
    }

    @MainActor
    static func backspace(count: Int) {
        guard count > 0 else { return }
        if TestBench.isActive { TestBench.backspaceHandler?(count); return }
        if TestBench.observedBundleID != nil {
            if let target = observedTarget {
                AXQueue.queue.async {
                    guard let range = target.range(kAXSelectedTextRangeAttribute) else { return }
                    let start = max(0, range.location - count)
                    var r = CFRange(location: start, length: range.location - start)
                    if let value = AXValueCreate(.cfRange, &r) {
                        target.set(kAXSelectedTextRangeAttribute, value)
                        target.set(kAXSelectedTextAttribute, "" as CFString)
                    }
                }
            }
            return
        }
        for _ in 0..<count {
            for keyDown in [true, false] {
                guard let event = CGEvent(keyboardEventSource: source, virtualKey: 51, keyDown: keyDown) else { continue }
                event.flags = []
                event.setIntegerValueField(.eventSourceUserData, value: KeyEventTap.syntheticMarker)
                event.post(tap: .cgSessionEventTap)
            }
        }
    }
}
