import CarrotEngine
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings()
                .tabItem { Label("General", systemImage: "gearshape") }
            AppearanceSettings()
                .tabItem { Label("Appearance", systemImage: "textformat") }
            KeyboardSettings()
                .tabItem { Label("Keyboard", systemImage: "keyboard") }
            AppsSettings()
                .tabItem { Label("Apps", systemImage: "square.grid.2x2") }
            PersonalSettings()
                .tabItem { Label("Personal", systemImage: "person.crop.circle") }
            ModelSettings()
                .tabItem { Label("Model", systemImage: "cpu") }
        }
        .frame(width: 560)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { bringSettingsToFront() }
    }
}

// MARK: - General

struct GeneralSettings: View {
    @ObservedObject private var prefs = Preferences.shared
    @ObservedObject private var controller = SuggestionController.shared
    @ObservedObject private var models = ModelManager.shared
    @ObservedObject private var permissions = Permissions.shared
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        Form {
            if !permissions.isTrusted {
                Section {
                    HStack(alignment: .firstTextBaseline) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Carrot needs Accessibility access").font(.headline)
                            Text("It reads the text around your cursor to predict what comes next. Nothing leaves this Mac.")
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Open Settings") {
                            permissions.request()
                            permissions.openSystemSettings()
                        }
                    }
                }
            }
            if NSSpellChecker.isAutomaticInlinePredictionEnabled {
                Section { SystemPredictionNotice() }
            }
            Section {
                Toggle("Show suggestions", isOn: $prefs.isEnabled)
                Toggle("Open at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in
                        do {
                            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                        } catch {
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }
            }
            Section("Suggestions") {
                VStack(alignment: .leading, spacing: 6) {
                    LabeledContent("How often") {
                        HStack(spacing: 8) {
                            Text("Fewer").font(.caption).foregroundStyle(.secondary)
                            Slider(value: $prefs.eagerness, in: 0...1)
                                .frame(maxWidth: 220)
                            Text("More").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Text("Carrot only offers text it's reasonably sure of. Slide right to see suggestions more often.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Picker("Length", selection: $prefs.length) {
                    Text("Short · 2–3 words").tag(SuggestionLength.short)
                    Text("Medium · 3–6 words").tag(SuggestionLength.medium)
                    Text("Long · up to a sentence").tag(SuggestionLength.long)
                }
                Toggle(isOn: $prefs.midLineSuggestions) {
                    Text("Suggest in the middle of a line")
                    Text("Offers words to insert before existing text, shown in a small card.")
                }
                Toggle(isOn: $prefs.typoCorrection) {
                    Text("Fix typos")
                    Text("Offers a correction when the word you just typed looks misspelled.")
                }
            }
            Section("This Mac") {
                LabeledContent("Accepted suggestions", value: controller.stats.accepted.formatted())
                LabeledContent("Characters written for you", value: controller.stats.charactersAccepted.formatted())
                if let latency = models.averageLatency {
                    LabeledContent("Average response time", value: "\(Int(latency.rounded())) ms")
                }
            }
        }
        .formStyle(.grouped)
    }
}

/// macOS's own inline predictions draw in the same place as Carrot's.
struct SystemPredictionNotice: View {
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "text.badge.xmark").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text("macOS is showing its own predictions too").font(.headline)
                Text("They appear in the same spot as Carrot's. Turn off “Show inline predictive text” in Keyboard › Text Input › Edit.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button("Open Keyboard Settings") {
                if let url = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension") {
                    NSWorkspace.shared.open(url)
                }
            }
        }
    }
}

// MARK: - Appearance

struct AppearanceSettings: View {
    @ObservedObject private var prefs = Preferences.shared

    var body: some View {
        Form {
            Section {
                GhostPreview()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 6)
            }
            Section("Ghost text") {
                Picker("Color", selection: $prefs.ghostColor) {
                    ForEach(Preferences.GhostColor.allCases) { Text($0.title).tag($0) }
                }
                LabeledContent("Opacity") {
                    Slider(value: $prefs.ghostOpacity, in: 0.2...0.8)
                        .frame(maxWidth: 240)
                }
                Toggle(isOn: $prefs.showKeyHint) {
                    Text("Show the accept key on floating suggestions")
                    Text("When a suggestion can't sit inline — in the middle of a line, or where the cursor position is uncertain — it appears in a small card below the text.")
                }
            }
            Section {
                Toggle(isOn: Binding(get: { prefs.exactPlacement }, set: { on in
                    prefs.exactPlacement = on
                    if on && !ScreenCalibrator.hasPermission { ScreenCalibrator.requestPermission() }
                    ScreenCalibrator.shared.forgetAll()
                })) {
                    Text("Exact placement in browsers")
                    Text("Web pages only tell other apps where their text is to the nearest point, so suggestions in Chrome, Safari and web apps can sit a pixel off. With this on, Carrot looks at the text just before your cursor once per line to line suggestions up exactly. What it sees is only compared with the suggestion's text, never saved or sent anywhere.")
                }
                if prefs.exactPlacement {
                    ScreenRecordingRow()
                }
            }
        }
        .formStyle(.grouped)
    }
}

struct ScreenRecordingRow: View {
    @State private var allowed = ScreenCalibrator.hasPermission
    private let timer = Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()

    var body: some View {
        Group {
            if allowed {
                Label("Screen Recording is allowed", systemImage: "checkmark.circle")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                HStack {
                    Text("Needs Screen Recording permission: turn on Carrot in Privacy & Security › Screen & System Audio Recording. macOS may ask you to reopen Carrot.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("Open Settings") { ScreenCalibrator.requestPermission() }
                }
            }
        }
        .onReceive(timer) { _ in allowed = ScreenCalibrator.hasPermission }
    }
}

struct GhostPreview: View {
    @ObservedObject private var prefs = Preferences.shared

    var body: some View {
        let ghost: Color = {
            switch prefs.ghostColor {
            case .accent: return Color.accentColor.opacity(min(1, prefs.ghostOpacity + 0.25))
            case .gray: return Color.gray.opacity(min(1, prefs.ghostOpacity + 0.35))
            case .automatic: return Color.primary.opacity(prefs.ghostOpacity)
            }
        }()
        (Text("Thanks for the notes, I'll send the revised draft ") + Text("by Friday afternoon").foregroundColor(ghost))
            .font(.system(size: 15))
            .textSelection(.disabled)
    }
}

// MARK: - Keyboard

struct KeyboardSettings: View {
    @ObservedObject private var prefs = Preferences.shared
    private var toggle: [KeyCombo] { prefs.toggleShortcut.map { [$0] } ?? [] }

    var body: some View {
        Form {
            Section {
                LabeledContent("Accept next word") {
                    KeyRecorder(combo: $prefs.acceptWordKey, taken: [prefs.acceptAllKey, prefs.dismissKey] + toggle)
                }
                LabeledContent("Accept whole suggestion") {
                    KeyRecorder(combo: $prefs.acceptAllKey, taken: [prefs.acceptWordKey, prefs.dismissKey] + toggle)
                }
                LabeledContent("Dismiss") {
                    KeyRecorder(combo: $prefs.dismissKey, acceptsEscape: true, taken: [prefs.acceptWordKey, prefs.acceptAllKey] + toggle)
                }
                Toggle("Include punctuation when accepting a word", isOn: $prefs.wordIncludesPunctuation)
            } footer: {
                Text("These keys are only taken over while a suggestion is showing; otherwise they work as usual. Without punctuation, a word is accepted on its own (“Thursday”), and the comma or period after it comes with the next press.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                LabeledContent("Turn suggestions on or off") {
                    HStack {
                        KeyRecorder(combo: Binding(get: { prefs.toggleShortcut ?? KeyCombo(keyCode: 0xFFFF) },
                                                   set: { prefs.toggleShortcut = $0 }),
                                    allowsNone: true, isNone: prefs.toggleShortcut == nil, requiresModifier: true,
                                    taken: [prefs.acceptWordKey, prefs.acceptAllKey, prefs.dismissKey])
                        if prefs.toggleShortcut != nil {
                            Button { prefs.toggleShortcut = nil } label: { Image(systemName: "xmark.circle.fill") }
                                .buttonStyle(.borderless)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } footer: {
                Text("Works everywhere. Use a combination with ⌘, ⌃ or ⌥ so it doesn't get in the way of typing.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Button("Restore Defaults") {
                    prefs.acceptWordKey = .tab
                    prefs.acceptAllKey = .shiftTab
                    prefs.wordIncludesPunctuation = false
                    prefs.dismissKey = .escape
                    prefs.toggleShortcut = nil
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Apps

struct AppsSettings: View {
    @ObservedObject private var prefs = Preferences.shared
    @State private var search = ""
    @State private var newSite = ""

    private struct AppRow: Identifiable, Hashable {
        let id: String
        let name: String
        let url: URL?
    }

    private var rows: [AppRow] {
        var map: [String: AppRow] = [:]
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            guard let id = app.bundleIdentifier, id != Bundle.main.bundleIdentifier else { continue }
            map[id] = AppRow(id: id, name: app.localizedName ?? id, url: app.bundleURL)
        }
        for id in prefs.appOverrides.keys where map[id] == nil {
            let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)
            let name = url.map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") } ?? id
            map[id] = AppRow(id: id, name: name, url: url)
        }
        for id in AppRules.defaultDisabled where map[id] == nil {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
                let name = FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
                map[id] = AppRow(id: id, name: name, url: url)
            }
        }
        return map.values
            .filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        Form {
            Section {
                TextField("Search apps", text: $search, prompt: Text("Search apps"))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(rows) { row in
                            HStack(spacing: 10) {
                                if let url = row.url {
                                    Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                                        .resizable().frame(width: 20, height: 20)
                                } else {
                                    Image(systemName: "app").frame(width: 20, height: 20)
                                }
                                Text(row.name)
                                Spacer()
                                Toggle("", isOn: Binding(get: { prefs.isAppEnabled(row.id) },
                                                         set: { prefs.setApp(row.id, enabled: $0) }))
                                    .labelsHidden()
                                    .toggleStyle(.switch)
                                    .controlSize(.small)
                            }
                            .padding(.vertical, 5)
                            Divider()
                        }
                    }
                }
                .frame(height: 230)
            } header: {
                Text("Apps")
            } footer: {
                Text("Terminals, code editors and password managers are off by default. Password fields are always skipped.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Websites to skip") {
                ForEach(prefs.disabledSites, id: \.self) { site in
                    HStack {
                        Text(site)
                        Spacer()
                        Button { prefs.disabledSites.removeAll { $0 == site } } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                    }
                }
                HStack {
                    TextField("Website", text: $newSite, prompt: Text("example.com"))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(addSite)
                    Button("Add", action: addSite).disabled(newSite.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func addSite() {
        var site = newSite.trimmingCharacters(in: .whitespaces).lowercased()
        if let host = URL(string: site.contains("://") ? site : "https://" + site)?.host { site = host }
        site = site.replacingOccurrences(of: "www.", with: "")
        guard !site.isEmpty, !prefs.disabledSites.contains(site) else { return }
        prefs.disabledSites.append(site)
        newSite = ""
    }
}

// MARK: - Personal

struct PersonalSettings: View {
    @ObservedObject private var prefs = Preferences.shared
    @State private var memoryCount = MemoryStore.shared.count
    @State private var showingMemory = false
    @State private var confirmClear = false
    @State private var journalSize = Journal.shared.fileSize
    @State private var confirmDeleteJournal = false

    var body: some View {
        Form {
            Section {
                ZStack(alignment: .topLeading) {
                    if prefs.aboutMe.isEmpty {
                        Text("e.g. I'm Alex Kim, a product designer at Lumen in Toronto. I write short, friendly emails and sign them “Alex”.")
                            .foregroundStyle(.tertiary)
                            .padding(.top, 1)
                            .padding(.leading, 5)
                            .allowsHitTesting(false)
                    }
                    TextEditor(text: $prefs.aboutMe)
                        .font(.body)
                        .scrollContentBackground(.hidden)
                        .frame(height: 90)
                }
            } header: {
                Text("About you")
            } footer: {
                Text("Carrot uses this for details like your name, role and sign-off.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Toggle(isOn: $prefs.memoryEnabled) {
                    Text("Learn from what I write")
                    Text("Keeps a private index of your writing so suggestions can reuse your names, phrasing and facts.")
                }
                HStack {
                    Text("\(memoryCount.formatted()) passages remembered").foregroundStyle(.secondary)
                    Spacer()
                    Button("Show…") { showingMemory = true }.disabled(memoryCount == 0)
                    Button("Forget All…") { confirmClear = true }.disabled(memoryCount == 0)
                }
                Toggle(isOn: $prefs.useScreenContext) {
                    Text("Use text on screen")
                    Text("Reads what's around the text field and in the windows you can see next to it — the message you're replying to, the page behind your note. Password managers are never read.")
                }
                Toggle(isOn: $prefs.useClipboard) {
                    Text("Use what I copy")
                    Text("Something you copied in the last few minutes — a link, an address, a quote — can show up in suggestions.")
                }
                if prefs.useClipboard {
                    ClipboardAccessRow()
                }
            } footer: {
                Label("Everything stays on this Mac. Carrot never sends what you type anywhere.", systemImage: "lock")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Toggle(isOn: $prefs.keepJournal) {
                    Text("Keep a suggestion journal")
                    Text("Records what Carrot saw, what it suggested and what you wrote, to review how well it works for you. Kept on this Mac for 30 days; never sent anywhere.")
                }
                if journalSize > 0 {
                    HStack {
                        Text("Journal: \(ByteCountFormatter.string(fromByteCount: journalSize, countStyle: .file))")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([Journal.fileURL]) }
                        Button("Delete…") { confirmDeleteJournal = true }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            journalSize = Journal.shared.fileSize
            memoryCount = MemoryStore.shared.count
            ClipboardMonitor.shared.updateAccess()
        }
        .sheet(isPresented: $showingMemory) { MemoryList() }
        .confirmationDialog("Delete the suggestion journal?", isPresented: $confirmDeleteJournal) {
            Button("Delete Journal", role: .destructive) {
                Journal.shared.clear()
                journalSize = 0
            }
        } message: {
            Text("Everything it recorded is removed from this Mac.")
        }
        .confirmationDialog("Forget everything Carrot has learned from your writing?", isPresented: $confirmClear) {
            Button("Forget All", role: .destructive) {
                MemoryStore.shared.clear()
                SuggestionController.shared.forgetMemories()
                memoryCount = 0
            }
        }
    }
}

/// Shows whether macOS lets Carrot read the clipboard without asking, with a way to allow it.
struct ClipboardAccessRow: View {
    @ObservedObject private var clipboard = ClipboardMonitor.shared

    var body: some View {
        switch clipboard.access {
        case .allowed:
            Label("Clipboard access is allowed", systemImage: "checkmark.circle")
                .font(.caption).foregroundStyle(.secondary)
        case .wouldPrompt:
            HStack {
                Text("macOS asks before apps read the clipboard. Allow it once, then choose “Always Allow” for Carrot in Privacy & Security › Paste from Other Apps.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("Allow…") { clipboard.requestAccess() }
            }
        case .denied:
            HStack {
                Text("Clipboard access is turned off for Carrot in System Settings.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Open Settings") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Pasteboard") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
        }
    }
}

struct MemoryList: View {
    @Environment(\.dismiss) private var dismiss
    private let rows = MemoryStore.shared.recent(limit: 300)

    var body: some View {
        VStack(spacing: 0) {
            List(Array(rows.enumerated()), id: \.offset) { _, row in
                VStack(alignment: .leading, spacing: 3) {
                    Text(row.text).lineLimit(4)
                    Text("\(row.app) · \(row.date.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(.vertical, 3)
            }
            Divider()
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 520, height: 420)
    }
}

// MARK: - Model

struct ModelSettings: View {
    @ObservedObject private var models = ModelManager.shared
    @ObservedObject private var prefs = Preferences.shared

    var body: some View {
        Form {
            Section {
                ForEach(ModelCatalog.all) { spec in
                    ModelRow(spec: spec)
                }
            } header: {
                Text("Prediction model")
            } footer: {
                Text("Models run on this Mac's GPU. Larger models predict better and use more memory.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                if case .failed(let message) = models.status {
                    Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                }
                if models.status == .ready, let name = models.loadedDisplayName {
                    LabeledContent("In use", value: name)
                }
                if let latency = models.averageLatency {
                    LabeledContent("Average response time", value: "\(Int(latency.rounded())) ms")
                }
                HStack {
                    if prefs.modelID == "custom", let path = prefs.customModelPath {
                        Text((path as NSString).lastPathComponent).lineLimit(1).truncationMode(.middle)
                    } else {
                        Text("Use your own GGUF base model").foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Choose File…") { chooseCustom() }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func chooseCustom() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.init(filenameExtension: "gguf") ?? .data]
        panel.allowsMultipleSelection = false
        panel.message = "Choose a GGUF base (not chat) model"
        if panel.runModal() == .OK, let url = panel.url {
            models.useCustomModel(at: url)
        }
    }
}

struct ModelRow: View {
    let spec: ModelSpec
    @ObservedObject private var models = ModelManager.shared
    @ObservedObject private var prefs = Preferences.shared

    private var isSelected: Bool { prefs.modelID == spec.id }
    private var downloaded: Bool { ModelCatalog.isDownloaded(spec) }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                .font(.title3)
                .onTapGesture { if downloaded { models.select(spec.id) } }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(spec.name).font(.headline)
                    if spec.id == ModelCatalog.recommended.id {
                        Text("Recommended").font(.caption2).padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                    }
                }
                Text("\(spec.summary) \(spec.sizeDescription).").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            trailing
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }

    @ViewBuilder private var trailing: some View {
        if isSelected, case .downloading(let progress, _) = models.status {
            HStack {
                ProgressView(value: progress).frame(width: 90)
                Button { models.cancelDownload() } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless).foregroundStyle(.secondary)
            }
        } else if isSelected, models.status == .verifying || models.status == .loading {
            ProgressView().controlSize(.small)
        } else if downloaded {
            if isSelected {
                Text(models.status == .ready ? "In use" : "Selected").foregroundStyle(.secondary)
            } else {
                Menu {
                    Button("Use") { models.select(spec.id) }
                    Button("Delete", role: .destructive) { models.delete(spec) }
                } label: { Text("Downloaded") }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
            }
        } else {
            Button("Download") {
                prefs.modelID = spec.id
                models.unload()
                models.download(spec)
            }
            .disabled(models.status.isBusy)
        }
    }
}
