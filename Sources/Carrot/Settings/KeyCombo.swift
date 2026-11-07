import AppKit
import Carbon.HIToolbox

/// A key plus modifiers, as used for Carrot's shortcuts.
struct KeyCombo: Codable, Equatable, Hashable {
    var keyCode: UInt16
    /// Device-independent modifier flags (command, option, control, shift).
    var modifiers: UInt

    static let relevantModifiers: NSEvent.ModifierFlags = [.command, .option, .control, .shift]

    init(keyCode: UInt16, modifiers: NSEvent.ModifierFlags = []) {
        self.keyCode = keyCode
        self.modifiers = modifiers.intersection(Self.relevantModifiers).rawValue
    }

    var modifierFlags: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: modifiers) }

    static let tab = KeyCombo(keyCode: UInt16(kVK_Tab))
    static let shiftTab = KeyCombo(keyCode: UInt16(kVK_Tab), modifiers: .shift)
    static let optionRight = KeyCombo(keyCode: UInt16(kVK_RightArrow), modifiers: .option)
    static let escape = KeyCombo(keyCode: UInt16(kVK_Escape))
    static let rightArrow = KeyCombo(keyCode: UInt16(kVK_RightArrow))

    /// Matches a CGEvent's key code and flags.
    func matches(keyCode: UInt16, flags: CGEventFlags) -> Bool {
        guard keyCode == self.keyCode else { return false }
        var eventModifiers: NSEvent.ModifierFlags = []
        if flags.contains(.maskCommand) { eventModifiers.insert(.command) }
        if flags.contains(.maskAlternate) { eventModifiers.insert(.option) }
        if flags.contains(.maskControl) { eventModifiers.insert(.control) }
        if flags.contains(.maskShift) { eventModifiers.insert(.shift) }
        return eventModifiers == modifierFlags
    }

    /// Human-readable form, e.g. "⌥→" or "⇥".
    var displayString: String {
        var s = ""
        let m = modifierFlags
        if m.contains(.control) { s += "⌃" }
        if m.contains(.option) { s += "⌥" }
        if m.contains(.shift) { s += "⇧" }
        if m.contains(.command) { s += "⌘" }
        return s + Self.keyName(keyCode)
    }

    static func keyName(_ code: UInt16) -> String {
        switch Int(code) {
        case kVK_Tab: return "⇥"
        case kVK_Return: return "↩"
        case kVK_Escape: return "esc"
        case kVK_Space: return "Space"
        case kVK_Delete: return "⌫"
        case kVK_ForwardDelete: return "⌦"
        case kVK_LeftArrow: return "←"
        case kVK_RightArrow: return "→"
        case kVK_UpArrow: return "↑"
        case kVK_DownArrow: return "↓"
        case kVK_Home: return "↖"
        case kVK_End: return "↘"
        case kVK_PageUp: return "⇞"
        case kVK_PageDown: return "⇟"
        case kVK_ANSI_Grave: return "`"
        case kVK_F1: return "F1"
        case kVK_F2: return "F2"
        case kVK_F3: return "F3"
        case kVK_F4: return "F4"
        case kVK_F5: return "F5"
        case kVK_F6: return "F6"
        case kVK_F7: return "F7"
        case kVK_F8: return "F8"
        case kVK_F9: return "F9"
        case kVK_F10: return "F10"
        case kVK_F11: return "F11"
        case kVK_F12: return "F12"
        default:
            return characterForKeyCode(code)?.uppercased() ?? "Key \(code)"
        }
    }

    /// The character the current keyboard layout produces for a key code (no modifiers).
    static func characterForKeyCode(_ code: UInt16) -> String? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let layoutPointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let layoutData = Unmanaged<CFData>.fromOpaque(layoutPointer).takeUnretainedValue() as Data
        return layoutData.withUnsafeBytes { raw -> String? in
            guard let layout = raw.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return nil }
            var deadKeyState: UInt32 = 0
            var length = 0
            var chars = [UniChar](repeating: 0, count: 4)
            let status = UCKeyTranslate(layout, code, UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                                        OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeyState, 4, &length, &chars)
            guard status == noErr, length > 0 else { return nil }
            return String(utf16CodeUnits: chars, count: length)
        }
    }
}
