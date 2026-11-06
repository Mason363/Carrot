import AppKit
import Carbon.HIToolbox

/// What a key press means for Foreword.
enum KeyKind: Equatable {
    case text(String)
    case delete
    case newline
    case navigation
    case shortcut
    case tab
    case escape
    case accept
    case mouse
    case other
}

/// The tap thread's decision about one key press.
enum TapOutcome: Equatable {
    case none
    case acceptAll
    case acceptWord
    case dismiss
    case typedThrough(String)
    case diverged
    case toggle
}

/// The slice of suggestion state the event-tap thread needs to make instant decisions.
/// Every update from the main thread bumps `version`; outcomes carry the version they were based on
/// so the main thread can ignore decisions made against a suggestion that has since been replaced.
final class TapState: @unchecked Sendable {
    private let lock = NSLock()
    private var visible = false
    private var remaining = ""
    private var isCorrection = false
    private var version: UInt64 = 0
    private var acceptAllKey = KeyCombo.tab
    private var acceptWordKey = KeyCombo.optionRight
    private var dismissKey = KeyCombo.escape
    private var toggleKey: KeyCombo?

    func setKeys(acceptAll: KeyCombo, acceptWord: KeyCombo, dismiss: KeyCombo, toggle: KeyCombo?) {
        lock.lock(); defer { lock.unlock() }
        acceptAllKey = acceptAll
        acceptWordKey = acceptWord
        dismissKey = dismiss
        toggleKey = toggle
    }

    /// Main thread: publish the currently shown suggestion. Returns the new version.
    @discardableResult
    func publish(visible: Bool, remaining: String, isCorrection: Bool) -> UInt64 {
        lock.lock(); defer { lock.unlock() }
        self.visible = visible
        self.remaining = remaining
        self.isCorrection = isCorrection
        version &+= 1
        return version
    }

    var currentVersion: UInt64 {
        lock.lock(); defer { lock.unlock() }
        return version
    }

    var isVisible: Bool {
        lock.lock(); defer { lock.unlock() }
        return visible
    }

    /// Tap thread: classify a key press and decide whether to swallow it.
    func decide(keyCode: UInt16, flags: CGEventFlags, characters: String) -> (consume: Bool, outcome: TapOutcome, kind: KeyKind, version: UInt64) {
        let kind = Self.classify(keyCode: keyCode, flags: flags, characters: characters)
        lock.lock(); defer { lock.unlock() }
        let basedOn = version
        if let toggleKey, toggleKey.matches(keyCode: keyCode, flags: flags) {
            return (true, .toggle, kind, basedOn)
        }
        guard visible else { return (false, .none, kind, basedOn) }
        if acceptAllKey.matches(keyCode: keyCode, flags: flags) {
            return (true, .acceptAll, .accept, basedOn)
        }
        if !isCorrection, acceptWordKey.matches(keyCode: keyCode, flags: flags) {
            return (true, .acceptWord, .accept, basedOn)
        }
        if dismissKey.matches(keyCode: keyCode, flags: flags) {
            visible = false
            return (true, .dismiss, kind, basedOn)
        }
        if case .text(let typed) = kind, !isCorrection, !typed.isEmpty, remaining.hasPrefix(typed) {
            remaining.removeFirst(typed.count)
            if remaining.isEmpty { visible = false }
            return (false, .typedThrough(typed), kind, basedOn)
        }
        visible = false
        return (false, .diverged, kind, basedOn)
    }

    func hideFromTap() -> (wasVisible: Bool, version: UInt64) {
        lock.lock(); defer { lock.unlock() }
        let was = visible
        visible = false
        return (was, version)
    }

    static func classify(keyCode: UInt16, flags: CGEventFlags, characters: String) -> KeyKind {
        switch Int(keyCode) {
        case kVK_Delete, kVK_ForwardDelete: return .delete
        case kVK_Return, kVK_ANSI_KeypadEnter: return .newline
        case kVK_LeftArrow, kVK_RightArrow, kVK_UpArrow, kVK_DownArrow, kVK_Home, kVK_End, kVK_PageUp, kVK_PageDown:
            return .navigation
        case kVK_Tab: return .tab
        case kVK_Escape: return .escape
        default: break
        }
        if flags.contains(.maskCommand) || flags.contains(.maskControl) { return .shortcut }
        guard !characters.isEmpty,
              characters.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value != 0x7F && !(0xF700...0xF8FF).contains($0.value) })
        else { return .other }
        return .text(characters)
    }
}
