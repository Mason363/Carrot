import AppKit
import Carbon.HIToolbox
import Combine
import ForewordEngine
import os

/// The conductor: follows focus, reads the field, asks the engine, shows the ghost, and handles
/// type-through, acceptance, dismissal and corrections.
@MainActor
final class SuggestionController: ObservableObject {
    static let shared = SuggestionController()

    // MARK: Collaborators
    private let prefs = Preferences.shared
    private let models = ModelManager.shared
    private let tracker = FocusTracker()
    private let tap = KeyEventTap()
    private let tapState = TapState()
    private let presenter = GhostPresenter()
    private let assembler = ContextAssembler()
    private let typo = TypoCorrector()
    private let log = Logger(subsystem: "io.github.mason363.Foreword", category: "controller")
    private var cancellables = Set<AnyCancellable>()

    // MARK: Published status
    @Published private(set) var isRunning = false
    @Published private(set) var tapAvailable = true
    @Published private(set) var currentAppName: String?
    @Published private(set) var currentFieldEligible = false
    @Published private(set) var stats = Stats()

    struct Stats: Codable {
        var shown = 0
        var accepted = 0
        var charactersAccepted = 0
    }

    // MARK: Field state
    private var field: FieldInfo?
    private var fieldEligible = false
    private var lastSnapshot: FieldSnapshot?
    private var geometry: FieldReader.CachedGeometry?
    /// What the user has written in the current field since the last memory commit: the keys they
    /// typed and the suggestions they accepted, never text that was already there or pasted.
    private var writtenText = ""
    private var focusCheckInFlight = false
    private var lastFocusedElement: AXElement?
    private var snapshotInFlight = false
    private var snapshotDirty = false

    // MARK: Suggestion state
    private struct Active {
        enum Kind { case continuation, insertion, correction(TypoCorrector.Correction) }
        var remaining: String
        /// The text before the caret at which `remaining` applies.
        var anchorPrefix: String
        var kind: Kind
        var version: UInt64
        var typedSinceShown = 0
        /// Fully accepted: the ghost stays on screen (under the text being inserted) until the app
        /// has drawn the inserted text, so there is never a frame with neither.
        var acceptedAt: TimeInterval?
        var isCorrection: Bool { if case .correction = kind { return true } else { return false } }
    }

    private var active: Active?
    private var requestSerial = 0
    private var lastKey: KeyKind = .other
    private var lastKeyTime: TimeInterval = 0
    private var suppressUntilBoundary = false
    /// Counts handled keys and clicks: anything computed before the latest one is stale.
    private var keySequence = 0
    /// The newest request whose answer (or cancellation) has come back.
    private var finishedSerial = 0
    private var appBias: [String: Double] = UserDefaults.standard.dictionary(forKey: "appBias") as? [String: Double] ?? [:]

    // MARK: Lifecycle

    func start() {
        guard !isRunning else { return }
        isRunning = true
        assembler.onUpdate = { [weak self] in self?.prefillCurrent() }
        if !TestBench.isActive {
            tracker.onEvent = { [weak self] event in self?.handleTracker(event) }
            tracker.start()
        }
        if !TestBench.disablesGlobalInput {
            // The test bench and observe mode never touch global input.
            tap.handler = { [weak self] type, event in
                self?.handleTapEvent(type: type, event: event) ?? false
            }
            tapAvailable = tap.start()
            if !tapAvailable {
                // Right after Accessibility is granted macOS can refuse the tap for a moment.
                log.error("Event tap unavailable; retrying")
                retryTap(attempt: 1)
            }
        }
        syncKeys()

        prefs.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                DispatchQueue.main.async {
                    self?.syncKeys()
                    // Turned on (or allowed in this app) while it's in front: its web content needs
                    // the accessibility switch now rather than at its next activation.
                    if let app = NSWorkspace.shared.frontmostApplication { WebAccessibility.enableIfNeeded(for: app) }
                    self?.reevaluateField()
                }
            }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: .forewordEngineReady)
            .sink { [weak self] _ in self?.reevaluateField() }
            .store(in: &cancellables)
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didDeactivateApplicationNotification)
            .sink { [weak self] _ in self?.commitMemory() }
            .store(in: &cancellables)
        loadStats()
    }

    private func retryTap(attempt: Int) {
        guard attempt <= 60, isRunning, !tapAvailable else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self, self.isRunning else { return }
            self.tapAvailable = self.tap.start()
            if !self.tapAvailable { self.retryTap(attempt: attempt + 1) }
        }
    }

    func stop() {
        commitMemory()
        tracker.stop()
        tap.stop()
        hide()
        isRunning = false
        cancellables.removeAll()
    }

    private func syncKeys() {
        tapState.setKeys(acceptAll: prefs.acceptAllKey, acceptWord: prefs.acceptWordKey,
                         dismiss: prefs.dismissKey, toggle: prefs.toggleShortcut)
    }

    // MARK: Event tap (tap thread)

    nonisolated private func handleTapEvent(type: CGEventType, event: CGEvent) -> Bool {
        switch type {
        case .keyDown:
            let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
            var length = 0
            var buffer = [UniChar](repeating: 0, count: 8)
            event.keyboardGetUnicodeString(maxStringLength: 8, actualStringLength: &length, unicodeString: &buffer)
            let characters = length > 0 ? String(utf16CodeUnits: buffer, count: length) : ""
            let decision = tapState.decide(keyCode: keyCode, flags: event.flags, characters: characters)
            DispatchQueue.main.async { [weak self] in
                self?.handleKey(outcome: decision.outcome, kind: decision.kind, version: decision.version)
            }
            return decision.consume
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            let state = tapState.hideFromTap()
            DispatchQueue.main.async { [weak self] in self?.handleMouse(wasVisible: state.wasVisible) }
            return false
        case .scrollWheel:
            if tapState.isVisible {
                let state = tapState.hideFromTap()
                DispatchQueue.main.async { [weak self] in self?.handleScroll(wasVisible: state.wasVisible) }
            }
            return false
        default:
            return false
        }
    }

    // MARK: Key handling (main)

    private func handleKey(outcome: TapOutcome, kind: KeyKind, version: UInt64) {
        keySequence += 1
        // A key decided against an older suggestion than the one showing now: whatever it did, the
        // newer one no longer matches what's on screen.
        if outcome != .toggle, let current = active, current.version != version {
            hide()
            noteWriting(kind)
            noteKeyActivity(kind)
            return
        }
        switch outcome {
        case .toggle:
            prefs.isEnabled.toggle()
            if !prefs.isEnabled { hide() }
            return
        case .none:
            break
        case .acceptAll, .acceptWord, .dismiss, .typedThrough, .diverged:
            // A decision made against an older suggestion: resync and hide to be safe.
            guard let current = active, current.version == version else {
                if outcome != .diverged { hide() }
                break
            }
            switch outcome {
            case .acceptAll: accept(all: true)
            case .acceptWord: accept(all: false)
            case .dismiss: dismiss()
            case .typedThrough(let typed): typeThrough(typed)
            case .diverged: hide()
            default: break
            }
        }
        noteWriting(kind)
        noteKeyActivity(kind)
    }

    private func noteKeyActivity(_ kind: KeyKind) {
        lastKey = kind
        lastKeyTime = ProcessInfo.processInfo.systemUptime
        switch kind {
        case .text, .delete, .newline, .accept, .shortcut:
            // The app applies the key asynchronously; read soon, then again in case it was slow.
            for delay in [0.006, 0.04, 0.14, 0.35] { scheduleSnapshot(after: delay) }
        case .navigation, .tab:
            hide()
            scheduleSnapshot(after: 0.03)
        default:
            break
        }
    }

    private func handleMouse(wasVisible: Bool) {
        keySequence += 1
        if wasVisible { hide() }
        noteWriting(.mouse)
        lastKey = .mouse
        lastKeyTime = ProcessInfo.processInfo.systemUptime
        scheduleSnapshot(after: 0.05)
    }

    private func handleScroll(wasVisible: Bool) {
        if wasVisible { hide() }
    }

    // MARK: Focus

    private func handleTracker(_ event: FocusTracker.Event) {
        switch event {
        case .focusChanged:
            checkFocus()
        case .valueChanged, .selectionChanged:
            scheduleSnapshot(after: 0)
        case .geometryChanged:
            if active != nil { scheduleSnapshot(after: 0.02) }
        }
    }

    private func checkFocus() {
        guard !focusCheckInFlight, !TestBench.isActive else { return }
        let observedPID = TestBench.observedApplication()?.processIdentifier
        // Never send Accessibility queries to ourselves from a background thread (they run in-process).
        if observedPID == nil,
           NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier {
            lastFocusedElement = nil
            if field != nil { setField(nil) }
            return
        }
        focusCheckInFlight = true
        // Compare with whatever had focus last time — text field or not — so the periodic check is
        // a single cheap query while focus stays put.
        let current = lastFocusedElement
        let ownPID = ProcessInfo.processInfo.processIdentifier
        AXQueue.queue.async { [weak self] in
            var element = observedPID.map(FieldReader.focusedElement(inApp:)) ?? FieldReader.focusedElement()
            if element?.pid == ownPID { element = nil }
            _ = ownPID
            var info: FieldInfo?
            var changed = false
            var definite = true
            var docsHint: CGRect?
            if element != current {
                changed = true
                info = element.flatMap(FieldReader.info(for:))
                // Nil can mean "not a text field" or "the app didn't answer in time"; only the first
                // is worth remembering, or a slow app would never get suggestions in this field.
                if info == nil, let element { definite = element.role != nil }
                // Google Docs without its braille support exposes no text at all: say how to fix that.
                if info == nil, let element, Self.mayShowDocsHint(), FieldReader.isUnreadableGoogleDocs(element) {
                    docsHint = FieldReader.googleDocsCaretRect(near: element) ?? element.window?.frame
                }
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.focusCheckInFlight = false
                if changed {
                    self.lastFocusedElement = definite ? element : nil
                    if info != self.field || info == nil { self.setField(info) }
                }
                if let rect = docsHint, self.prefs.isActive, self.prefs.isAppEnabled(NSWorkspace.shared.frontmostApplication?.bundleIdentifier) {
                    UserDefaults.standard.set(Date(), forKey: "docsHintShown")
                    self.presenter.showNotice("For suggestions in Google Docs, turn on screen reader and braille support in Tools › Accessibility.",
                                              below: rect.height > 200 ? CGRect(x: rect.midX - 200, y: rect.minY + 120, width: 0, height: 20) : rect)
                }
            }
        }
    }

    /// The Google Docs hint shows at most once a day.
    nonisolated static func mayShowDocsHint() -> Bool {
        guard let last = UserDefaults.standard.object(forKey: "docsHintShown") as? Date else { return true }
        return Date().timeIntervalSince(last) > 86_400
    }

    private func setField(_ info: FieldInfo?) {
        commitMemory()
        hide()
        field = info
        if TestBench.observedBundleID != nil { TextInserter.observedTarget = info?.element }
        lastSnapshot = nil
        geometry = nil
        writtenText = ""
        suppressUntilBoundary = false
        currentAppName = info?.appName ?? NSWorkspace.shared.frontmostApplication?.localizedName
        fieldEligible = info.map(isEligible) ?? false
        currentFieldEligible = fieldEligible
        assembler.reset()
        guard let info, fieldEligible else { return }
        readInitialSnapshot(info, attempt: 0)
    }

    /// First read: remember the starting text (for memory) and warm the model's cache. Apps that
    /// were just activated sometimes answer late, so retry a few times.
    private func readInitialSnapshot(_ info: FieldInfo, attempt: Int) {
        AXQueue.queue.async { [weak self] in
            let snapshot = FieldReader.snapshot(of: info)
            DispatchQueue.main.async {
                guard let self, self.field == info else { return }
                if let snapshot {
                    if self.lastSnapshot == nil { self.lastSnapshot = snapshot }
                    self.rememberGeometry(snapshot)
                } else if attempt < 3 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { self.readInitialSnapshot(info, attempt: attempt + 1) }
                }
                if attempt == 0 || snapshot != nil {
                    self.assembler.prepare(for: info, snapshot: snapshot)
                    self.prefillCurrent()
                }
            }
        }
    }

    /// Re-checks eligibility after a settings change or once the model is ready.
    private func reevaluateField() {
        guard let field else { return }
        let eligible = isEligible(field)
        if eligible != fieldEligible {
            if !eligible { commitMemory() } // what was written before the pause
            fieldEligible = eligible
            currentFieldEligible = eligible
            writtenText = ""
            if eligible {
                assembler.prepare(for: field, snapshot: lastSnapshot)
                prefillCurrent()
            } else {
                hide()
            }
        }
    }

    private func isEligible(_ info: FieldInfo) -> Bool {
        guard prefs.isActive, models.engine != nil else { return false }
        if info.pid == ProcessInfo.processInfo.processIdentifier && !TestBench.isActive { return false }
        if TestBench.observedPID != nil { return prefs.isActive && models.engine != nil && !info.isSecure }
        guard prefs.isAppEnabled(info.bundleID) else { return false }
        if info.isSecure || info.isSearch { return false }
        if IsSecureEventInputEnabled() { return false }
        if AppRules.isQuietURL(info.url) || prefs.isSiteDisabled(info.domain) { return false }
        if info.isSingleLine && AppRules.isDataField(label: info.label) { return false }
        // Browser chrome (address bar, find bar…) is outside any web page.
        if AppRules.isBrowser(info.bundleID) && !info.isWebContent { return false }
        return true
    }

    private func prefillCurrent() {
        // Warming the cache would cancel a request in flight, and nothing would ask again.
        guard finishedSerial >= requestSerial else { return }
        guard fieldEligible, let engine = models.engine, let snapshot = lastSnapshot else { return }
        engine.prefill(context: assembler.header, prefix: snapshot.prefix)
    }

    // MARK: Snapshots

    private func scheduleSnapshot(after delay: TimeInterval) {
        guard field != nil, fieldEligible else { return }
        if delay <= 0 {
            readSnapshot()
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.readSnapshot() }
        }
    }

    private func readSnapshot() {
        guard let field, fieldEligible else { return }
        if snapshotInFlight { snapshotDirty = true; return }
        snapshotInFlight = true
        let cached = geometry
        AXQueue.queue.async { [weak self] in
            let snapshot = FieldReader.snapshot(of: field, cached: cached)
            DispatchQueue.main.async {
                guard let self else { return }
                self.snapshotInFlight = false
                if let snapshot, self.field == snapshot.info { self.process(snapshot) }
                if self.snapshotDirty {
                    self.snapshotDirty = false
                    self.readSnapshot()
                }
            }
        }
    }

    private func rememberGeometry(_ snapshot: FieldSnapshot) {
        if snapshot.fontName != nil || snapshot.fontSize != nil {
            if geometry == nil || ProcessInfo.processInfo.systemUptime - (geometry?.queriedAt ?? 0) >= 2 {
                geometry = .init(fontName: snapshot.fontName, fontSize: snapshot.fontSize, textColor: snapshot.textColor,
                                 sampleText: snapshot.sampleText, sampleWidth: snapshot.sampleWidth,
                                 queriedAt: ProcessInfo.processInfo.systemUptime)
            }
        }
    }

    private enum Change {
        case unchanged
        case appended(String)
        case deleted
        case cleared
        case other
    }

    private func classify(from old: FieldSnapshot, to new: FieldSnapshot) -> Change {
        if new.prefix == old.prefix && new.selection.location == old.selection.location { return .unchanged }
        if new.prefix.isEmpty && new.suffix.isEmpty && !(old.prefix.isEmpty && old.suffix.isEmpty) { return .cleared }
        if new.prefix.count > old.prefix.count, new.prefix.hasPrefix(old.prefix) {
            return .appended(String(new.prefix.dropFirst(old.prefix.count)))
        }
        // A bounded prefix window may have slid: compare tails.
        if old.prefix.count >= FieldReader.prefixLimit - 50, new.selection.location > old.selection.location {
            let grown = new.selection.location - old.selection.location
            if grown < 200 {
                let added = String(new.prefix.suffix(grown))
                if String(new.prefix.dropLast(grown)).hasSuffix(String(old.prefix.suffix(200))) { return .appended(added) }
            }
        }
        if old.prefix.hasPrefix(new.prefix) { return .deleted }
        return .other
    }

    private func process(_ snapshot: FieldSnapshot) {
        rememberGeometry(snapshot)
        let previous = lastSnapshot
        lastSnapshot = snapshot

        if snapshot.hasSelection {
            hide()
            return
        }
        if IsSecureEventInputEnabled() {
            hide()
            return
        }

        // Keep a visible suggestion if the field is consistent with it.
        if let active {
            if case .correction(let c) = active.kind {
                if Self.sameText(snapshot.prefix, c.prefix) { return }
                hide()
            } else {
                if Self.sameText(snapshot.prefix, active.anchorPrefix) {
                    if active.acceptedAt != nil || active.remaining.trimmingCharacters(in: .whitespaces).isEmpty {
                        // The accepted text is on screen now: let the ghost go and continue below.
                        presenter.hide()
                        self.active = nil
                    } else {
                        // The app has drawn what the user typed (or accepted): re-lay out the rest exactly.
                        if let shown = presenter.reposition(snapshot: snapshot, text: active.remaining), shown != active.remaining {
                            var updated = active
                            updated.remaining = shown
                            updated.version = tapState.publish(visible: true, remaining: shown, isCorrection: false)
                            self.active = updated
                        }
                        return
                    }
                }
                // A lagging read: the app hasn't applied keys we already accounted for (type-through / accept).
                let recent = ProcessInfo.processInfo.systemUptime - lastKeyTime < 0.5
                let lag = active.anchorPrefix.count - snapshot.prefix.count
                if recent || active.acceptedAt != nil, lag > 0, lag <= active.typedSinceShown,
                   Self.sameText(snapshot.prefix, String(active.anchorPrefix.dropLast(lag))) {
                    return
                }
                hide()
            }
        }

        let sinceKey = ProcessInfo.processInfo.systemUptime - lastKeyTime
        guard let previous else {
            // No baseline yet (the first read failed): still answer a fresh keystroke.
            if case .text = lastKey, sinceKey < 1.0 { request(for: snapshot) }
            return
        }
        let change = classify(from: previous, to: snapshot)
        switch change {
        case .unchanged:
            return
        case .cleared:
            // A message was sent: remember it and re-read the conversation.
            commitMemory()
            assembler.refreshScreen(snapshot: snapshot)
        case .deleted:
            return
        case .other:
            // The app rewrote what was just typed (autocorrect, smart quotes, auto-capitalisation):
            // still the user's typing. Anything else (undo, paste, clicks) gets no suggestion.
            let typedRecently: Bool
            switch lastKey {
            case .text, .accept: typedRecently = sinceKey < 0.8
            default: typedRecently = false
            }
            guard typedRecently, !suppressUntilBoundary else { return }
            request(for: snapshot)
        case .appended(let added):
            // Only react to the user's own typing (or an acceptance), not to remote edits or pastes.
            var userTyped: Bool
            switch lastKey {
            case .text, .accept, .newline: userTyped = sinceKey < 1.5
            default: userTyped = false
            }
            // Observe mode: the observed app is driven by a test tool, not by key presses.
            if TestBench.observedBundleID != nil { userTyped = true }
            guard userTyped else { return }
            if suppressUntilBoundary {
                if added.contains(where: { $0.isWhitespace || $0.isPunctuation }) {
                    suppressUntilBoundary = false
                } else {
                    return
                }
            }
            if InputMethod.isComposing(added: added) { return }
            if prefs.typoCorrection, lastKey != .accept, let last = added.last, last == " " || ",.;:!?".contains(last) {
                checkTypo(snapshot)
            }
            request(for: snapshot)
        }
    }

    /// Text equality that tolerates the bounded prefix window having moved.
    static func sameText(_ a: String, _ b: String) -> Bool {
        if a.count < 900 || b.count < 900 { return a == b }
        return a.suffix(800) == b.suffix(800)
    }

    // MARK: Requests

    private func shouldRequest(_ snapshot: FieldSnapshot) -> Bool {
        let trimmed = snapshot.prefix.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if snapshot.info.isSingleLine && trimmed.count < 3 { return false }
        // Inside a word with letters right after the caret: never.
        if let next = snapshot.suffix.first, next.isLetter || next.isNumber,
           let previous = snapshot.prefix.last, previous.isLetter || previous.isNumber { return false }
        return true
    }

    private func request(for snapshot: FieldSnapshot) {
        guard fieldEligible, let engine = models.engine, shouldRequest(snapshot) else { return }
        assembler.refreshClipboard(fieldText: snapshot.prefix + snapshot.suffix)
        requestSerial += 1
        let serial = requestSerial
        let keysAtRequest = keySequence
        var options = prefs.completionOptions
        let bias = snapshot.info.bundleID.flatMap { appBias[$0] } ?? 0
        options.applyEagerness(prefs.eagerness + bias)
        options.length = prefs.length
        options.allowMidLine = prefs.midLineSuggestions
        let request = CompletionRequest(context: assembler.header, prefix: snapshot.prefix, suffix: snapshot.suffix, options: options)
        Task { [weak self] in
            let result = await engine.complete(request)
            if TestBench.isDebugging {
                let line = "request …\(request.prefix.suffix(40).debugDescription) → \(result.map { "\($0.text.debugDescription) p=\(String(format: "%.2f", $0.probability)) \(Int($0.milliseconds))ms" } ?? "nil")\n"
                FileHandle.standardError.write(line.data(using: .utf8)!)
            }
            guard let self else { return }
            self.finishedSerial = max(self.finishedSerial, serial)
            guard serial == self.requestSerial, let result else { return }
            // Turned off meanwhile, or the user kept typing before the app showed it.
            guard self.fieldEligible, self.prefs.isActive, self.keySequence == keysAtRequest else { return }
            guard let current = self.lastSnapshot, current.info == snapshot.info, current.prefix == snapshot.prefix,
                  !current.hasSelection, self.active?.isCorrection != true else { return }
            self.models.recordLatency(result.milliseconds)
            self.present(result, snapshot: current)
        }
    }

    private func present(_ completion: Completion, snapshot: FieldSnapshot) {
        let lineSuffix = snapshot.lineSuffix.trimmingCharacters(in: .whitespaces)
        let preferPill = completion.kind == .insertion || !lineSuffix.isEmpty
        guard let shown = presenter.show(completion.text, snapshot: snapshot, preferPill: preferPill),
              !shown.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        let version = tapState.publish(visible: true, remaining: shown, isCorrection: false)
        active = Active(remaining: shown, anchorPrefix: snapshot.prefix,
                        kind: completion.kind == .insertion ? .insertion : .continuation, version: version)
        stats.shown += 1
    }

    // MARK: Type-through, accept, dismiss

    private func typeThrough(_ typed: String) {
        guard var current = active else { return }
        current.remaining.removeFirst(min(typed.count, current.remaining.count))
        current.anchorPrefix += typed
        current.typedSinceShown += typed.count
        active = current
        // Inline ghosts stay put until the app has drawn the typed character on top of its gray
        // twin (the next snapshot re-lays them out); moving early would leave a one-frame gap.
        if !presenter.isInline {
            if current.remaining.trimmingCharacters(in: .whitespaces).isEmpty { hide(); return }
            presenter.advance(by: typed, remaining: current.remaining)
        }
    }

    private func accept(all: Bool) {
        guard var current = active else { return }
        if case .correction(let correction) = current.kind {
            applyCorrection(correction)
            return
        }
        let text = all ? current.remaining
            : Self.nextWord(of: current.remaining, after: current.anchorPrefix.last,
                            includePunctuation: Preferences.shared.wordIncludesPunctuation)
        guard !text.isEmpty else { hide(); return }
        TextInserter.type(text)
        noteWriting(.text(text))
        noteAccepted(characters: text.count, explicit: true)
        current.remaining.removeFirst(text.count)
        current.anchorPrefix += text
        current.typedSinceShown += text.count
        if current.remaining.trimmingCharacters(in: .whitespaces).isEmpty {
            // Keep the ghost under the text being inserted until the app has drawn it.
            current.acceptedAt = ProcessInfo.processInfo.systemUptime
            current.version = tapState.publish(visible: false, remaining: "", isCorrection: false)
            active = current
            let version = current.version
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                // Safety net if the app never reports the change.
                guard let self, let pending = self.active, pending.version == version, pending.acceptedAt != nil else { return }
                self.hide()
            }
        } else {
            current.version = tapState.publish(visible: true, remaining: current.remaining, isCorrection: false)
            active = current
            if !presenter.isInline { presenter.advance(by: text, remaining: current.remaining) }
        }
    }

    /// The next word of a suggestion, with its leading space. Punctuation right after the word (a
    /// comma, a period, a closing quote) stays for the next press unless `includePunctuation`; when
    /// the suggestion continues with punctuation, that punctuation is the next piece on its own.
    /// `previous` is the character just before the suggestion (it can make an apostrophe part of a word).
    static func nextWord(of text: String, after previous: Character? = nil, includePunctuation: Bool = false) -> String {
        let chars = Array(text)
        var i = 0
        while i < chars.count, chars[i].isWhitespace, !chars[i].isNewline { i += 1 }
        let lead = i
        guard i < chars.count else { return text }
        if chars[i].isNewline { return String(chars[0...i]) }
        if includePunctuation {
            while i < chars.count, !chars[i].isWhitespace { i += 1 }
            return String(chars[0..<i])
        }
        func isWordish(_ c: Character) -> Bool { c.isLetter || c.isNumber || c == "_" }
        func isCJK(_ c: Character) -> Bool { c.unicodeScalars.first.map(TextAnalysis.isCJK) ?? false }
        func isWordCharacter(_ index: Int) -> Bool {
            let c = chars[index]
            if isWordish(c) { return true }
            let before: Character? = index > 0 ? chars[index - 1] : (index == lead ? previous : nil)
            let after: Character? = index + 1 < chars.count ? chars[index + 1] : nil
            guard let before, let after else { return false }
            switch c {
            case "'", "’", "-", "‐": return isWordish(before) && isWordish(after)          // don't, well-known
            case ".": return (before.isNumber && after.isNumber) || (before.isLetter && after.isLetter) // 3.5, e.g
            case ",", ":": return before.isNumber && after.isNumber                          // 1,000, 10:30
            default: return false
            }
        }
        // Opening quotes, brackets and symbols lead into the word they belong to.
        let opening: Set<Character> = ["\"", "'", "“", "‘", "(", "[", "{", "«", "¿", "¡", "$", "€", "£", "¥", "#", "@"]
        while i < chars.count, opening.contains(chars[i]) { i += 1 }
        let wordStart = i
        if i < chars.count, isCJK(chars[i]) {
            // No spaces between CJK words: take one word as the system segments it.
            let rest = String(chars[i...])
            let tokenizer = CFStringTokenizerCreate(nil, rest as CFString, CFRange(location: 0, length: (rest as NSString).length),
                                                    kCFStringTokenizerUnitWord, nil)
            if CFStringTokenizerAdvanceToNextToken(tokenizer) != [] {
                let range = CFStringTokenizerGetCurrentTokenRange(tokenizer)
                let word = (rest as NSString).substring(with: NSRange(location: range.location, length: max(1, range.length)))
                i += word.count
            } else {
                i += 1
            }
        } else {
            while i < chars.count, isWordCharacter(i), !isCJK(chars[i]) { i += 1 }
        }
        if i == wordStart {
            // No word: the punctuation run itself, up to the next space or word.
            i = lead
            while i < chars.count, !chars[i].isWhitespace, !isWordish(chars[i]) { i += 1 }
            if i == lead { i = lead + 1 }
        }
        return String(chars[0..<i])
    }

    private func dismiss() {
        if case .correction(let c) = active?.kind { typo.ignore(c.original) }
        if let bundle = field?.bundleID, !TestBench.isDebugging {
            appBias[bundle] = max(-0.2, (appBias[bundle] ?? 0) - 0.02)
            UserDefaults.standard.set(appBias, forKey: "appBias")
        }
        hide()
        suppressUntilBoundary = true
    }

    private func hide() {
        if active != nil || presenter.isVisible {
            presenter.hide()
        }
        active = nil
        tapState.publish(visible: false, remaining: "", isCorrection: false)
    }

    private func noteAccepted(characters: Int, explicit: Bool) {
        stats.accepted += 1
        stats.charactersAccepted += characters
        if let bundle = field?.bundleID, explicit, !TestBench.isDebugging {
            appBias[bundle] = min(0.15, (appBias[bundle] ?? 0) + 0.01)
            UserDefaults.standard.set(appBias, forKey: "appBias")
        }
        saveStats()
    }

    // MARK: Typos

    private func checkTypo(_ snapshot: FieldSnapshot) {
        let engine = models.engine
        let header = assembler.header
        let keysAtCheck = keySequence
        Task { [weak self] in
            guard let self, let correction = await self.typo.correction(for: snapshot, engine: engine, header: header) else { return }
            guard self.fieldEligible, self.prefs.isActive, self.keySequence == keysAtCheck,
                  let current = self.lastSnapshot, current.prefix == correction.prefix, current.info == snapshot.info else { return }
            let info = snapshot.info
            let length = (correction.original as NSString).length
            AXQueue.queue.async {
                let rect = info.element.bounds(for: CFRange(location: correction.wordStart, length: length))
                DispatchQueue.main.async {
                    guard self.fieldEligible, self.prefs.isActive, self.keySequence == keysAtCheck,
                          let current = self.lastSnapshot, current.prefix == correction.prefix else { return }
                    self.showCorrection(correction, snapshot: current, wordRect: rect)
                }
            }
        }
    }

    private func showCorrection(_ correction: TypoCorrector.Correction, snapshot: FieldSnapshot, wordRect: CGRect?) {
        presenter.hide()
        var anchor = wordRect
        if let rect = wordRect, rect.height < 4 { anchor = nil }
        guard presenter.show(correction.replacement, snapshot: snapshot, preferPill: true,
                             correction: correction.original, correctionRect: anchor ?? snapshot.caret) != nil else { return }
        let version = tapState.publish(visible: true, remaining: "", isCorrection: true)
        active = Active(remaining: "", anchorPrefix: snapshot.prefix, kind: .correction(correction), version: version)
    }

    private func applyCorrection(_ correction: TypoCorrector.Correction) {
        hide()
        // Backspaces are blind: only send them if the text still ends with the word being fixed.
        guard let current = lastSnapshot, current.prefix.hasSuffix(correction.original + correction.trailing) else { return }
        let deleteCount = correction.original.count + correction.trailing.count
        TextInserter.backspace(count: deleteCount)
        TextInserter.type(correction.replacement + correction.trailing)
        lastKey = .accept
        lastKeyTime = ProcessInfo.processInfo.systemUptime
        suppressUntilBoundary = false
        for delay in [0.02, 0.08, 0.2] { scheduleSnapshot(after: delay) }
    }

    // MARK: Memory

    /// After Forget All: drop what's pending and what the current prompt already recalled.
    func forgetMemories() {
        writtenText = ""
        if let field, fieldEligible {
            assembler.reset()
            assembler.prepare(for: field, snapshot: lastSnapshot)
        }
    }

    private func commitMemory() {
        defer { writtenText = "" }
        guard prefs.memoryEnabled, !TestBench.isDebugging, let field, fieldEligible, !field.isSecure else { return }
        let written = writtenText.trimmingCharacters(in: .whitespacesAndNewlines)
        if written.count >= 40 {
            MemoryStore.shared.remember(written, app: field.appName, title: field.windowTitle)
        }
    }

    /// Keeps `writtenText` in step with what the user writes. Only keys typed while suggestions are on
    /// for this field count; moving the cursor elsewhere starts a new passage.
    private func noteWriting(_ kind: KeyKind) {
        guard field != nil, fieldEligible, prefs.isActive else { return }
        switch kind {
        case .text(let typed):
            writtenText += typed
        case .newline:
            writtenText += "\n"
        case .delete:
            if !writtenText.isEmpty { writtenText.removeLast() }
        case .navigation, .mouse, .shortcut:
            if !writtenText.isEmpty, !writtenText.hasSuffix("\n") { writtenText += "\n" }
        default:
            break
        }
        if writtenText.count > 8000 { writtenText.removeFirst(writtenText.count - 8000) }
    }

    // MARK: Stats

    private func loadStats() {
        if let data = UserDefaults.standard.data(forKey: "stats"), let s = try? JSONDecoder().decode(Stats.self, from: data) {
            stats = s
        }
    }

    private func saveStats() {
        guard !TestBench.isDebugging else { return }
        if let data = try? JSONEncoder().encode(stats) { UserDefaults.standard.set(data, forKey: "stats") }
    }

    func resetStats() {
        stats = Stats()
        saveStats()
    }

    // MARK: Test hooks

    var debugState: [String: Any] {
        [
            "field": field.map { "\($0.appName ?? "?") \($0.role ?? "?") eligible=\(fieldEligible)" } ?? "none",
            "prefix": String(lastSnapshot?.prefix.suffix(80) ?? ""),
            "suggestion": active?.remaining ?? "",
            "visible": presenter.isVisible,
            "style": presenter.content.map { "\($0.style)" } ?? "",
            "caret": lastSnapshot?.caret.map { "\($0)" } ?? "nil",
            "font": "\(lastSnapshot?.fontName ?? "nil") \(lastSnapshot?.fontSize ?? 0)",
            // Never echo the user's clipboard into debug output.
            "layout": presenter.debugLayout,
            "header": assembler.header.replacingOccurrences(
                of: "Recently copied:\n\"\"\"\n[\\s\\S]*?\n\"\"\"", with: "Recently copied: [redacted]", options: .regularExpression),
            "clipboardAccess": "\(ClipboardMonitor.shared.access)",
            "screenRecording": ScreenCalibrator.hasPermission, "exactPlacement": prefs.exactPlacement,
        ]
    }

    var debugOverlayFrame: String { presenter.isVisible ? NSStringFromRect(presenter.debugFrame) : "" }

    /// Test bench: point Foreword at the bench's selected field.
    func debugRetarget(identifier: String, attempt: Int = 0) {
        guard TestBench.isActive || TestBench.observedPID != nil else { return }
        let pid = TestBench.observedPID ?? ProcessInfo.processInfo.processIdentifier
        AXQueue.queue.async { [weak self] in
            let app = AXElement.application(pid: pid)
            app.setTimeout(1)
            var queue: [AXElement] = app.elements(kAXWindowsAttribute)
            var found: AXElement?
            var visited = 0
            let focused = app.element(kAXFocusedUIElementAttribute)
            while !queue.isEmpty, visited < 4000 {
                let element = queue.removeFirst()
                visited += 1
                let elementID = element.string(kAXIdentifierAttribute) ?? element.string("AXDOMIdentifier") ?? ""
                if elementID == identifier, element.raw(kAXSelectedTextRangeAttribute) != nil {
                    found = element
                    break
                }
                queue.append(contentsOf: element.children)
            }
            let info = (found ?? focused).flatMap(FieldReader.info(for:))
            DispatchQueue.main.async {
                if info == nil, attempt < 10 {
                    // WebKit builds its accessibility tree lazily; try again shortly.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        self?.debugRetarget(identifier: identifier, attempt: attempt + 1)
                    }
                    return
                }
                self?.setField(info)
            }
        }
    }

    /// Test modes: read the field and request a suggestion for the current caret, whatever changed.
    func debugSuggestNow() {
        guard let field, fieldEligible else { return }
        AXQueue.queue.async { [weak self] in
            let snapshot = FieldReader.snapshot(of: field)
            DispatchQueue.main.async {
                guard let self, let snapshot else { return }
                self.rememberGeometry(snapshot)
                self.lastSnapshot = snapshot
                self.hide()
                self.request(for: snapshot)
            }
        }
    }

    /// Debug: show `text` as the suggestion at the field's caret, without asking the model.
    func debugShowGhost(_ text: String) {
        guard let field else { return }
        AXQueue.queue.async { [weak self] in
            let snapshot = FieldReader.snapshot(of: field)
            DispatchQueue.main.async {
                guard let self, let snapshot else { return }
                self.lastSnapshot = snapshot
                _ = self.presenter.show(text, snapshot: snapshot, preferPill: false)
            }
        }
    }

    /// Live test: report key activity for text typed by tools that bypass the OS event stream.
    func debugNoteKey(_ kind: KeyKind) {
        noteKeyActivity(kind)
    }

    /// Test bench: simulate a key outcome without a real key press.
    func debugAccept(all: Bool) {
        guard active != nil else { return }
        accept(all: all)
        noteKeyActivity(.accept)
    }

    func debugNoteTyped(_ text: String) {
        if let current = active, current.remaining.hasPrefix(text), !current.isCorrection {
            let version = tapState.publish(visible: true, remaining: String(current.remaining.dropFirst(text.count)), isCorrection: false)
            active?.version = version
            typeThrough(text)
        } else if active != nil {
            hide()
        }
        noteKeyActivity(.text(text))
    }
}

/// Detects input-method composition (e.g. Pinyin), during which the field holds provisional text.
enum InputMethod {
    static func isComposing(added: String) -> Bool {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              let typePointer = TISGetInputSourceProperty(source, kTISPropertyInputSourceType) else { return false }
        let type = Unmanaged<CFString>.fromOpaque(typePointer).takeUnretainedValue() as String
        guard type == (kTISTypeKeyboardInputMode as String) else { return false }
        // While composing, the field shows Latin letters (the reading); committed text is CJK.
        return added.unicodeScalars.allSatisfy { $0.isASCII && ($0.properties.isAlphabetic || $0 == "'") }
    }
}
