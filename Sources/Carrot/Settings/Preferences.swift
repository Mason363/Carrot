import AppKit
import Combine
import CarrotEngine

/// User settings, persisted in UserDefaults.
@MainActor
final class Preferences: ObservableObject {
    static let shared = Preferences()
    private let defaults = UserDefaults.standard

    enum GhostColor: String, CaseIterable, Identifiable, Codable {
        case automatic, gray, accent
        var id: String { rawValue }
        var title: String {
            switch self {
            case .automatic: return "Match text"
            case .gray: return "Gray"
            case .accent: return "Accent color"
            }
        }
    }

    @Published var isEnabled: Bool { didSet { defaults.set(isEnabled, forKey: "isEnabled") } }
    @Published var pausedUntil: Date? {
        didSet {
            defaults.set(pausedUntil, forKey: "pausedUntil")
            schedulePauseEnd()
        }
    }
    private var pauseTimer: Timer?

    /// Clears the pause when it runs out, so everything watching preferences (the focused field,
    /// the menu bar icon) wakes up on time.
    private func schedulePauseEnd() {
        pauseTimer?.invalidate()
        pauseTimer = nil
        guard let until = pausedUntil else { return }
        guard until > Date() else {
            DispatchQueue.main.async { [weak self] in if self?.pausedUntil == until { self?.pausedUntil = nil } }
            return
        }
        let timer = Timer(fire: until.addingTimeInterval(0.5), interval: 0, repeats: false) { [weak self] _ in
            DispatchQueue.main.async { if self?.pausedUntil == until { self?.pausedUntil = nil } }
        }
        RunLoop.main.add(timer, forMode: .common)
        pauseTimer = timer
    }
    /// 0 = only very confident suggestions, 1 = suggest often.
    @Published var eagerness: Double { didSet { defaults.set(eagerness, forKey: "eagerness") } }
    @Published var length: SuggestionLength { didSet { defaults.set(length.rawValue, forKey: "length") } }
    @Published var acceptAllKey: KeyCombo { didSet { save(acceptAllKey, "acceptAllKey") } }
    @Published var acceptWordKey: KeyCombo { didSet { save(acceptWordKey, "acceptWordKey") } }
    @Published var dismissKey: KeyCombo { didSet { save(dismissKey, "dismissKey") } }
    @Published var toggleShortcut: KeyCombo? { didSet { save(toggleShortcut, "toggleShortcut") } }
    @Published var typoCorrection: Bool { didSet { defaults.set(typoCorrection, forKey: "typoCorrection") } }
    @Published var midLineSuggestions: Bool { didSet { defaults.set(midLineSuggestions, forKey: "midLineSuggestions") } }
    @Published var ghostColor: GhostColor { didSet { defaults.set(ghostColor.rawValue, forKey: "ghostColor") } }
    @Published var ghostOpacity: Double { didSet { defaults.set(ghostOpacity, forKey: "ghostOpacity") } }
    @Published var showKeyHint: Bool { didSet { defaults.set(showKeyHint, forKey: "showKeyHint") } }
    /// Line ghost text up with web pages' text by looking at the screen (needs Screen Recording).
    @Published var exactPlacement: Bool { didSet { defaults.set(exactPlacement, forKey: "exactPlacement") } }
    /// Accepting a word also takes the punctuation attached to it ("Thursday," rather than "Thursday").
    @Published var wordIncludesPunctuation: Bool { didSet { defaults.set(wordIncludesPunctuation, forKey: "wordIncludesPunctuation") } }
    /// Explicit per-app choices (bundle id → enabled). Apps without an entry use `AppRules` defaults.
    @Published var appOverrides: [String: Bool] { didSet { defaults.set(appOverrides, forKey: "appOverrides") } }
    /// Websites (domains) where Carrot stays quiet.
    @Published var disabledSites: [String] { didSet { defaults.set(disabledSites, forKey: "disabledSites") } }
    @Published var aboutMe: String { didSet { defaults.set(aboutMe, forKey: "aboutMe") } }
    @Published var memoryEnabled: Bool { didSet { defaults.set(memoryEnabled, forKey: "memoryEnabled") } }
    @Published var useScreenContext: Bool { didSet { defaults.set(useScreenContext, forKey: "useScreenContext") } }
    @Published var useClipboard: Bool { didSet { defaults.set(useClipboard, forKey: "useClipboard") } }
    @Published var modelID: String { didSet { defaults.set(modelID, forKey: "modelID") } }
    @Published var customModelPath: String? { didSet { defaults.set(customModelPath, forKey: "customModelPath") } }
    @Published var hasCompletedOnboarding: Bool { didSet { defaults.set(hasCompletedOnboarding, forKey: "hasCompletedOnboarding") } }

    private init() {
        defaults.register(defaults: [
            "isEnabled": true, "eagerness": 0.5, "length": SuggestionLength.medium.rawValue,
            "typoCorrection": true, "midLineSuggestions": true, "ghostColor": GhostColor.automatic.rawValue,
            "ghostOpacity": 0.45, "showKeyHint": true, "wordIncludesPunctuation": false, "exactPlacement": false,
            "memoryEnabled": true, "useScreenContext": true, "useClipboard": true,
            "modelID": ModelCatalog.defaultModel.id, "hasCompletedOnboarding": false,
        ])
        isEnabled = defaults.bool(forKey: "isEnabled")
        pausedUntil = defaults.object(forKey: "pausedUntil") as? Date
        eagerness = defaults.double(forKey: "eagerness")
        length = SuggestionLength(rawValue: defaults.string(forKey: "length") ?? "") ?? .medium
        var acceptAll: KeyCombo = Self.load("acceptAllKey", defaults) ?? .shiftTab
        var acceptWord: KeyCombo = Self.load("acceptWordKey", defaults) ?? .tab
        // Tab used to accept everything and ⌥→ a word; Tab now takes the next word and ⇧Tab everything.
        if defaults.integer(forKey: "shortcutsVersion") < 2 {
            if acceptAll == .tab && acceptWord == .optionRight { acceptAll = .shiftTab; acceptWord = .tab }
            defaults.set(2, forKey: "shortcutsVersion")
        }
        acceptAllKey = acceptAll
        acceptWordKey = acceptWord
        dismissKey = Self.load("dismissKey", defaults) ?? .escape
        // A global shortcut without ⌘, ⌃ or ⌥ (an older recorder could save a bare Esc) eats normal typing.
        let savedToggle: KeyCombo? = Self.load("toggleShortcut", defaults)
        toggleShortcut = savedToggle.flatMap { $0.modifierFlags.intersection([.command, .control, .option]).isEmpty ? nil : $0 }
        typoCorrection = defaults.bool(forKey: "typoCorrection")
        midLineSuggestions = defaults.bool(forKey: "midLineSuggestions")
        ghostColor = GhostColor(rawValue: defaults.string(forKey: "ghostColor") ?? "") ?? .automatic
        ghostOpacity = defaults.double(forKey: "ghostOpacity")
        showKeyHint = defaults.bool(forKey: "showKeyHint")
        wordIncludesPunctuation = defaults.bool(forKey: "wordIncludesPunctuation")
        exactPlacement = defaults.bool(forKey: "exactPlacement") || TestBench.forcesExactPlacement
        appOverrides = defaults.dictionary(forKey: "appOverrides") as? [String: Bool] ?? [:]
        disabledSites = defaults.stringArray(forKey: "disabledSites") ?? []
        aboutMe = defaults.string(forKey: "aboutMe") ?? ""
        memoryEnabled = defaults.bool(forKey: "memoryEnabled")
        useScreenContext = defaults.bool(forKey: "useScreenContext")
        useClipboard = defaults.bool(forKey: "useClipboard")
        modelID = defaults.string(forKey: "modelID") ?? ModelCatalog.defaultModel.id
        customModelPath = defaults.string(forKey: "customModelPath")
        hasCompletedOnboarding = defaults.bool(forKey: "hasCompletedOnboarding")
        schedulePauseEnd() // didSet doesn't run during init
    }

    private func save<T: Encodable>(_ value: T?, _ key: String) {
        if let value, let data = try? JSONEncoder().encode(value) {
            defaults.set(data, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }

    private static func load<T: Decodable>(_ key: String, _ defaults: UserDefaults) -> T? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    /// Whether suggestions are active right now (enabled and not paused).
    var isActive: Bool {
        guard isEnabled else { return false }
        if let until = pausedUntil, until > Date() { return false }
        return true
    }

    func isAppEnabled(_ bundleID: String?) -> Bool {
        guard let bundleID else { return true }
        if let explicit = appOverrides[bundleID] { return explicit }
        return !AppRules.disabledByDefault(bundleID)
    }

    func setApp(_ bundleID: String, enabled: Bool) {
        if enabled == !AppRules.disabledByDefault(bundleID) {
            appOverrides.removeValue(forKey: bundleID)
        } else {
            appOverrides[bundleID] = enabled
        }
    }

    func isSiteDisabled(_ domain: String?) -> Bool {
        guard let domain = domain?.lowercased() else { return false }
        return disabledSites.contains { domain == $0 || domain.hasSuffix("." + $0) }
    }

    /// Engine options derived from the user's settings.
    var completionOptions: CompletionOptions {
        var options = CompletionOptions()
        options.applyEagerness(eagerness)
        options.length = length
        options.allowMidLine = midLineSuggestions
        return options
    }
}
