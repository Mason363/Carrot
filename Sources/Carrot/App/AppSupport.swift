import Foundation

/// ~/Library/Application Support/Carrot: models and memory. The folder carried the app's former
/// name (Foreword) and is moved over on first launch.
enum AppSupport {
    static let directory: URL = {
        let fileManager = FileManager.default
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let current = base.appendingPathComponent("Carrot", isDirectory: true)
        let former = base.appendingPathComponent("Foreword", isDirectory: true)
        if !fileManager.fileExists(atPath: current.path), fileManager.fileExists(atPath: former.path) {
            try? fileManager.moveItem(at: former, to: current)
        }
        return current
    }()
}
