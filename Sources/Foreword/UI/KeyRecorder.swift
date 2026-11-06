import AppKit
import SwiftUI

/// Click, then press a key combination.
struct KeyRecorder: View {
    @Binding var combo: KeyCombo
    var allowsNone = false
    var isNone = false
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
            // Escape alone cancels recording unless we're recording the dismiss key itself.
            let modifiers = event.modifierFlags.intersection(KeyCombo.relevantModifiers)
            if event.keyCode == 53 && modifiers.isEmpty && combo != .escape && !allowsNone {
                stop()
                return nil
            }
            combo = KeyCombo(keyCode: event.keyCode, modifiers: modifiers)
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
