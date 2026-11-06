import SwiftUI

@main
struct ForewordApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @ObservedObject private var prefs = Preferences.shared
    @ObservedObject private var models = ModelManager.shared
    @ObservedObject private var controller = SuggestionController.shared
    @ObservedObject private var permissions = Permissions.shared

    var body: some Scene {
        MenuBarExtra {
            MenuContent()
        } label: {
            Image(nsImage: MenuBarIcon.image(active: prefs.isActive && models.status == .ready && permissions.isTrusted))
                .accessibilityLabel("Foreword")
        }
        .menuBarExtraStyle(.menu)

        Settings {
            SettingsView()
        }
    }
}
