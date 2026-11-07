import AppKit
import SwiftUI

/// Click, then press a key combination.
struct KeyRecorder: View {
    @Binding var combo: KeyCombo
    var allowsNone = false
    var isNone = false
    /// Recording the dismiss key: Esc on its own is a valid answer rather than "cancel".
    var acceptsEscape = false
    /// A shortcut that works everywhere needs ⌘, ⌃ or ⌥, or it would eat ordinary typing.
    var requiresModifier = false
    /// Combinations other shortcuts already use.
    var taken: [KeyCombo] = []
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        Button {
            recording ? stop() : start()
        } label: {
            Text(recording ? "Press keys…" : (isNone ? "None" : combo.displayString))
                .font(.system(.body, design: .rounded).monospacedDigit())
                .frame(minWidth: 72)
                .foregroundStyle(recording ? Color.accentColor : (isNone ? .secondary : .primary))
        }
        .buttonStyle(.bordered)
        .onDisappear { stop() }
    }

    private func start() {
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
            let modifiers = event.modifierFlags.intersection(KeyCombo.relevantModifiers)
            // Escape alone cancels recording, unless it's the dismiss key being recorded.
            if event.keyCode == 53 && modifiers.isEmpty && !acceptsEscape {
                stop()
                return nil
            }
            let candidate = KeyCombo(keyCode: event.keyCode, modifiers: modifiers)
            let hasCommandKey = !modifiers.intersection([.command, .control, .option]).isEmpty
            if (requiresModifier && !hasCommandKey) || taken.contains(candidate) {
                NSSound.beep() // keep listening for a usable combination
                return nil
            }
            combo = candidate
            stop()
            return nil
        }
    }

    private func stop() {
        recording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}
