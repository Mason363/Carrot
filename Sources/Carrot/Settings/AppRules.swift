import Foundation

/// Built-in knowledge about apps and fields where suggestions don't belong.
enum AppRules {
    /// Apps Carrot stays out of unless the user turns them on.
    static let defaultDisabled: Set<String> = [
        // Terminals
        "com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.Warp-Stable", "com.mitchellh.ghostty",
        "net.kovidgoyal.kitty", "org.alacritty", "com.github.wez.wezterm", "co.zeit.hyper", "com.raphaelamorim.rio",
        // Code editors / IDEs (they ship their own completion)
        "com.apple.dt.Xcode", "com.microsoft.VSCode", "com.microsoft.VSCodeInsiders", "com.todesktop.230313mzl4w4u92",
        "dev.zed.Zed", "dev.zed.Zed-Preview", "com.sublimetext.4", "com.sublimetext.3", "com.panic.Nova",
        "com.barebones.bbedit", "com.vscodium", "com.google.antigravity", "com.exafunction.windsurf",
        "com.jetbrains.intellij", "com.jetbrains.intellij.ce", "com.jetbrains.pycharm", "com.jetbrains.pycharm.ce",
        "com.jetbrains.WebStorm", "com.jetbrains.goland", "com.jetbrains.CLion", "com.jetbrains.rider",
        "com.jetbrains.rubymine", "com.jetbrains.PhpStorm", "com.jetbrains.datagrip", "com.google.android.studio",
        "cc.arduino.IDE2", "org.godotengine.godot",
        // Passwords & security
        "com.apple.keychainaccess", "com.apple.Passwords", "com.1password.1password", "com.agilebits.onepassword7",
        "com.bitwarden.desktop", "com.lastpass.LastPass", "com.dashlane.dashlanephonefinal",
        // Launchers & system UI
        "com.apple.Spotlight", "com.raycast.macos", "com.runningwithcrayons.Alfred", "com.apple.systempreferences",
        "com.apple.loginwindow", "com.apple.SecurityAgent", "com.apple.calculator", "com.apple.finder",
        "com.apple.ScreenSharing", "com.microsoft.rdc.macos", "com.apple.dt.instruments",
        // Spreadsheets
        "com.apple.iWork.Numbers", "com.microsoft.Excel",
    ]

    static func disabledByDefault(_ bundleID: String) -> Bool {
        if defaultDisabled.contains(bundleID) { return true }
        return bundleID.hasPrefix("com.jetbrains.")
    }

    /// Chromium-based browsers and Electron apps: their web accessibility tree must be switched on.
    static let chromiumBundlePrefixes = [
        "com.google.Chrome", "com.microsoft.edgemac", "com.brave.Browser", "company.thebrowser.Browser",
        "com.vivaldi.Vivaldi", "com.operasoftware.Opera", "org.chromium.Chromium", "com.kagi.kagimacOS",
        "ai.perplexity.comet", "com.openai.atlas",
    ]

    static func isChromium(_ bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        return chromiumBundlePrefixes.contains { bundleID.hasPrefix($0) }
    }

    static let browserBundleIDs: Set<String> = [
        "com.apple.Safari", "com.apple.SafariTechnologyPreview", "org.mozilla.firefox", "org.mozilla.firefoxdeveloperedition",
        "app.zen-browser.zen", "io.zen-browser.zen", "com.google.Chrome", "com.google.Chrome.canary", "com.microsoft.edgemac",
        "com.brave.Browser", "company.thebrowser.Browser", "com.vivaldi.Vivaldi", "com.operasoftware.Opera",
        "org.chromium.Chromium", "com.kagi.kagimacOS", "ai.perplexity.comet", "com.openai.atlas",
    ]

    static func isBrowser(_ bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        return browserBundleIDs.contains(bundleID) || isChromium(bundleID)
    }

    /// Websites where typing isn't prose.
    static let quietSites: [String] = [
        "docs.google.com/spreadsheets", "sheets.google.com", "github.com/*/blob", "colab.research.google.com",
        "replit.com", "codepen.io", "codesandbox.io", "stackblitz.com", "leetcode.com/problems",
        "vscode.dev", "github.dev", "excel.office.com", "airtable.com",
    ]

    static func isQuietURL(_ url: String?) -> Bool {
        guard let url = url?.lowercased() else { return false }
        for pattern in quietSites {
            if pattern.contains("*") {
                let parts = pattern.split(separator: "*").map(String.init)
                if parts.allSatisfy({ url.contains($0) }) { return true }
            } else if url.contains(pattern) {
                return true
            }
        }
        return false
    }

    /// Field labels that indicate the text is data, not prose.
    static let dataFieldKeywords = [
        "password", "passcode", "pin", "email", "e-mail", "username", "user name", "phone", "zip", "postal",
        "card", "cvv", "cvc", "expiry", "expiration", "ssn", "social security", "iban", "routing", "account number",
        "otp", "verification code", "one-time", "2fa", "url", "website", "address bar", "search", "find", "filter",
        "quantity", "amount", "price", "date", "time", "coupon", "promo", "captcha", "api key", "token", "secret",
    ]

    static func isDataField(label: String?) -> Bool {
        guard let label = label?.lowercased(), !label.isEmpty else { return false }
        return dataFieldKeywords.contains { keyword in
            // Match whole words so "pinned" or "searchlight" don't trigger.
            label.range(of: "\\b\(NSRegularExpression.escapedPattern(for: keyword))\\b", options: .regularExpression) != nil
        }
    }
}
