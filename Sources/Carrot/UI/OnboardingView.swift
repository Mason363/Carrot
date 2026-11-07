import SwiftUI

/// First-run flow: what Carrot does → Accessibility permission → model download → try it.
struct OnboardingView: View {
    var onFinish: () -> Void
    var initialStep = 0

    @ObservedObject private var permissions = Permissions.shared
    @ObservedObject private var models = ModelManager.shared
    @ObservedObject private var prefs = Preferences.shared
    @ObservedObject private var clipboard = ClipboardMonitor.shared
    @State private var step = 0
    @State private var chosen = ModelCatalog.recommended.id

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch step {
                case 0: welcome
                case 1: permission
                case 2: model
                default: tryIt
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 44)
            .padding(.top, 40)

            HStack {
                StepDots(count: 4, current: step)
                Spacer()
                if step > 0 && step < 3 {
                    Button("Back") { step -= 1 }
                }
                Button(primaryTitle) { advance() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canAdvance)
            }
            .padding(20)
        }
        .frame(width: 560, height: 520)
        .onAppear {
            step = initialStep
            if let existing = ModelCatalog.all.first(where: ModelCatalog.isDownloaded) { chosen = existing.id }
        }
    }

    private var primaryTitle: String {
        switch step {
        case 0: return "Get Started"
        case 1: return permissions.isTrusted ? "Continue" : "Waiting for Access…"
        case 2:
            if models.status == .ready { return "Continue" }
            return models.status.isBusy ? "Downloading…" : "Download"
        default: return "Done"
        }
    }

    private var canAdvance: Bool {
        switch step {
        case 1: return permissions.isTrusted
        case 2: return !models.status.isBusy
        default: return true
        }
    }

    private func advance() {
        switch step {
        case 2 where models.status != .ready:
            if let spec = ModelCatalog.spec(id: chosen) {
                prefs.modelID = chosen
                if ModelCatalog.isDownloaded(spec) { models.select(chosen) } else { models.download(spec) }
            }
        case 3:
            prefs.hasCompletedOnboarding = true
            onFinish()
        default:
            step += 1
        }
    }

    // MARK: Steps

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 18) {
            AppIconView().frame(width: 72, height: 72)
            Text("Carrot finishes your sentences.")
                .font(.system(size: 26, weight: .semibold))
            VStack(alignment: .leading, spacing: 8) {
                (Text("As you type, it suggests what comes next ") + Text("right where you're writing.").foregroundColor(.secondary.opacity(0.7)))
                    .font(.title3)
                Text("It works in mail, messages, documents and the web, learns how you write, and runs entirely on this Mac. No account, no limits, nothing sent anywhere.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
    }

    private var permission: some View {
        VStack(alignment: .leading, spacing: 16) {
            Image(systemName: "hand.raised.square.fill")
                .font(.system(size: 44)).foregroundStyle(Color.accentColor)
            Text("Allow Accessibility access")
                .font(.system(size: 24, weight: .semibold))
            Text("Carrot reads the text around your cursor to predict what comes next, and listens for Tab so you can accept a suggestion. macOS asks you to approve this once.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 12) {
                Button("Open System Settings") {
                    permissions.request()
                    permissions.openSystemSettings()
                }
                if permissions.isTrusted {
                    Label("Access granted", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                } else {
                    Text("Turn on Carrot in the list, then come back.").font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
    }

    private var model: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Choose a model")
                .font(.system(size: 24, weight: .semibold))
            Text("The model runs on your Mac. You can change it later in Settings.")
                .foregroundStyle(.secondary)
            VStack(spacing: 8) {
                ForEach(ModelCatalog.all) { spec in
                    Button { if !models.status.isBusy { chosen = spec.id } } label: {
                        HStack(spacing: 12) {
                            Image(systemName: chosen == spec.id ? "largecircle.fill.circle" : "circle")
                                .foregroundStyle(chosen == spec.id ? Color.accentColor : .secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                HStack {
                                    Text(spec.name).font(.headline)
                                    if spec.id == ModelCatalog.recommended.id {
                                        Text("Recommended").font(.caption2).foregroundStyle(.secondary)
                                    }
                                }
                                Text(spec.summary).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(ModelCatalog.isDownloaded(spec) ? "Downloaded" : spec.sizeDescription)
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .padding(10)
                        .background(RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(chosen == spec.id ? Color.accentColor : Color.secondary.opacity(0.25)))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            statusLine
            Spacer()
        }
    }

    @ViewBuilder private var statusLine: some View {
        switch models.status {
        case .downloading(let progress, let speed):
            VStack(alignment: .leading, spacing: 4) {
                ProgressView(value: progress)
                Text(speed > 0 ? "\(Int(progress * 100))% · \(ByteCountFormatter.string(fromByteCount: Int64(speed), countStyle: .file))/s"
                     : "\(Int(progress * 100))%")
                    .font(.caption).foregroundStyle(.secondary)
            }
        case .verifying:
            Label("Checking the download…", systemImage: "checkmark.shield").font(.caption)
        case .loading:
            Label("Loading…", systemImage: "hourglass").font(.caption)
        case .ready:
            Label("Ready", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).font(.caption)
        case .notDownloaded:
            EmptyView()
        }
    }

    private var tryIt: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Try it")
                .font(.system(size: 24, weight: .semibold))
            Text("Start typing in Notes, Mail or anywhere else. When gray text appears:")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 10) {
                KeyHintRow(keys: prefs.acceptWordKey.displayString, text: "accepts the next word")
                KeyHintRow(keys: prefs.acceptAllKey.displayString, text: "accepts the whole suggestion")
                KeyHintRow(keys: "Keep typing", text: "if it matches, the suggestion follows along")
                KeyHintRow(keys: prefs.dismissKey.displayString, text: "dismisses it")
            }
            Divider().padding(.vertical, 2)
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "doc.on.clipboard").font(.title2).foregroundStyle(.secondary).frame(width: 28)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Use what you copy").font(.headline)
                    Text("Carrot can draw on text you just copied — like a link you're about to share. macOS will ask once.")
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                if clipboard.access == .allowed {
                    Label("On", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                } else {
                    Button("Allow…") {
                        prefs.useClipboard = true
                        clipboard.requestAccess()
                    }
                }
            }
            if NSSpellChecker.isAutomaticInlinePredictionEnabled {
                SystemPredictionNotice()
            }
            Text("Tell Carrot a little about yourself in Settings › Personal so it can fill in your name and details.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
    }
}

private struct KeyHintRow: View {
    let keys: String
    let text: String
    var body: some View {
        HStack(spacing: 12) {
            Text(keys)
                .font(.system(.callout, design: .rounded).weight(.medium))
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: 5).fill(Color.secondary.opacity(0.12)))
                .frame(minWidth: 96, alignment: .leading)
            Text(text)
        }
    }
}

private struct StepDots: View {
    let count: Int
    let current: Int
    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<count, id: \.self) { i in
                Circle().fill(i == current ? Color.primary.opacity(0.7) : Color.secondary.opacity(0.3))
                    .frame(width: 6, height: 6)
            }
        }
    }
}

struct AppIconView: View {
    var body: some View {
        Image(nsImage: NSApp.applicationIconImage ?? NSImage())
            .resizable()
            .interpolation(.high)
    }
}
