import CryptoKit
import CarrotEngine
import Foundation
import os

/// Downloads, verifies and loads the language model, and owns the `CompletionEngine`.
@MainActor
final class ModelManager: NSObject, ObservableObject {
    static let shared = ModelManager()

    enum Status: Equatable {
        case notDownloaded
        case downloading(progress: Double, bytesPerSecond: Double)
        case verifying
        case loading
        case ready
        case failed(String)

        var isBusy: Bool {
            switch self {
            case .downloading, .verifying, .loading: return true
            default: return false
            }
        }
    }

    @Published private(set) var status: Status = .notDownloaded
    @Published private(set) var loadedModelID: String?
    @Published private(set) var loadedDescription: String?
    /// "Balanced · Qwen3.5 2B", or the file name of a custom model.
    var loadedDisplayName: String? {
        guard let id = loadedModelID else { return nil }
        if let spec = ModelCatalog.spec(id: id) { return "\(spec.name) · \(spec.modelName)" }
        return Preferences.shared.customModelPath.map { ($0 as NSString).lastPathComponent }
    }

    /// Rolling average suggestion latency in milliseconds.
    @Published private(set) var averageLatency: Double?

    private(set) var engine: CompletionEngine?
    private var downloadSession: URLSession?
    private var downloadTask: URLSessionDownloadTask?
    private var downloadingSpec: ModelSpec?
    /// Where an interrupted download can pick up, and which model it belongs to.
    private var resumeData: (specID: String, data: Data)?
    /// Each load gets a number; a load that finishes after a newer one started is ignored.
    private var loadGeneration = 0
    private var loadingTarget: (path: URL, id: String)?
    private var lastProgressTime = Date()
    private var lastProgressBytes: Int64 = 0
    private let log = Logger(subsystem: "io.github.mason363.Foreword", category: "model")

    /// The model the user picked, or a custom file.
    var selectedSpec: ModelSpec {
        ModelCatalog.spec(id: Preferences.shared.modelID) ?? ModelCatalog.defaultModel
    }

    var selectedModelPath: URL? {
        if Preferences.shared.modelID == "custom", let path = Preferences.shared.customModelPath {
            return URL(fileURLWithPath: path)
        }
        let spec = selectedSpec
        return ModelCatalog.isDownloaded(spec) ? ModelCatalog.localURL(for: spec) : nil
    }

    /// Loads the selected model if it is on disk.
    func start() {
        guard engine == nil || loadedModelID != Preferences.shared.modelID else { return }
        if let path = selectedModelPath, FileManager.default.fileExists(atPath: path.path) {
            load(path: path, id: Preferences.shared.modelID)
        } else if !status.isBusy {
            status = .notDownloaded
        }
    }

    func select(_ id: String) {
        guard id != Preferences.shared.modelID || engine == nil else { return }
        Preferences.shared.modelID = id
        unload()
        start()
    }

    func useCustomModel(at url: URL) {
        Preferences.shared.customModelPath = url.path
        Preferences.shared.modelID = "custom"
        unload()
        start()
    }

    func unload() {
        loadGeneration += 1 // a load in flight is now stale
        loadingTarget = nil
        engine?.cancel()
        engine = nil
        loadedModelID = nil
        loadedDescription = nil
        if !status.isBusy || status == .loading { status = .notDownloaded }
    }

    func recordLatency(_ ms: Double) {
        guard !TestBench.isDebugging else { return }
        if let avg = averageLatency {
            averageLatency = avg * 0.9 + ms * 0.1
        } else {
            averageLatency = ms
        }
    }

    // MARK: Loading

    private func load(path: URL, id: String) {
        if let target = loadingTarget, target.path == path, target.id == id, status == .loading { return } // already on it
        loadGeneration += 1
        let generation = loadGeneration
        loadingTarget = (path, id)
        status = .loading
        let started = Date()
        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                LlamaRuntime.initialize()
                let engine = try CompletionEngine(modelPath: path.path)
                // Compile GPU pipelines now rather than on the first keystroke.
                _ = try? engine.completeNow(CompletionRequest(context: "", prefix: "Thanks for getting back to me so"))
                let description = engine.model.summary
                await MainActor.run {
                    guard let self, generation == self.loadGeneration else { engine.cancel(); return }
                    self.loadingTarget = nil
                    guard Preferences.shared.modelID == id else { return } // switched meanwhile
                    self.engine = engine
                    self.loadedModelID = id
                    self.loadedDescription = description
                    self.status = .ready
                    self.log.info("Loaded \(description, privacy: .public) in \(Date().timeIntervalSince(started), privacy: .public)s")
                    NotificationCenter.default.post(name: .carrotEngineReady, object: nil)
                }
            } catch {
                await MainActor.run {
                    guard let self, generation == self.loadGeneration else { return } // superseded
                    self.loadingTarget = nil
                    self.status = .failed("The model could not be loaded. Try downloading it again.")
                    self.log.error("Load failed: \(String(describing: error), privacy: .public)")
                }
            }
        }
    }

    // MARK: Downloading

    func download(_ spec: ModelSpec) {
        guard downloadTask == nil else { return }
        try? FileManager.default.createDirectory(at: ModelCatalog.directory, withIntermediateDirectories: true)
        downloadingSpec = spec
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 60 * 60 * 6
        configuration.waitsForConnectivity = true
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        downloadSession = session
        let task: URLSessionDownloadTask
        if let resumeData, resumeData.specID == spec.id {
            task = session.downloadTask(withResumeData: resumeData.data)
        } else {
            var request = URLRequest(url: spec.url)
            request.setValue("Carrot", forHTTPHeaderField: "User-Agent")
            task = session.downloadTask(with: request)
        }
        resumeData = nil
        downloadTask = task
        lastProgressTime = Date()
        lastProgressBytes = 0
        status = .downloading(progress: 0, bytesPerSecond: 0)
        task.resume()
    }

    func cancelDownload() {
        let specID = downloadingSpec?.id
        downloadTask?.cancel(byProducingResumeData: { [weak self] data in
            Task { @MainActor in
                if let data, let specID { self?.resumeData = (specID, data) }
            }
        })
        downloadTask = nil
        downloadingSpec = nil
        downloadSession?.finishTasksAndInvalidate()
        downloadSession = nil
        status = engine != nil ? .ready : .notDownloaded
    }

    /// Whether a delegate callback belongs to the download in progress (not one cancelled earlier).
    fileprivate func isCurrent(_ task: URLSessionTask) -> Bool {
        downloadTask.map { $0.taskIdentifier == task.taskIdentifier } ?? false
    }

    func delete(_ spec: ModelSpec) {
        if loadedModelID == spec.id { unload() }
        try? FileManager.default.removeItem(at: ModelCatalog.localURL(for: spec))
        objectWillChange.send()
    }

    fileprivate func finishDownload(at temporary: URL) {
        guard let spec = downloadingSpec else { return }
        status = .verifying
        let destination = ModelCatalog.localURL(for: spec)
        Task.detached(priority: .userInitiated) { [weak self] in
            let ok = Self.verify(file: temporary, sha256: spec.sha256)
            if ok {
                try? FileManager.default.removeItem(at: destination)
                do {
                    try FileManager.default.moveItem(at: temporary, to: destination)
                } catch {
                    await MainActor.run { self?.status = .failed("Couldn't save the model: \(error.localizedDescription)") }
                    return
                }
            } else {
                try? FileManager.default.removeItem(at: temporary)
            }
            await MainActor.run {
                guard let self else { return }
                self.downloadTask = nil
                self.downloadingSpec = nil
                if ok {
                    if Preferences.shared.modelID == spec.id {
                        // Load the model that was just downloaded.
                        self.engine = nil
                        self.loadedModelID = nil
                    }
                    self.status = self.engine != nil ? .ready : .notDownloaded
                    self.objectWillChange.send()
                    self.start()
                } else {
                    self.status = .failed("The download was corrupted. Please try again.")
                }
            }
        }
    }

    nonisolated static func verify(file: URL, sha256 expected: String) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return false }
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk = autoreleasepool { handle.readData(ofLength: 8 * 1024 * 1024) }
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return digest == expected
    }
}

extension ModelManager: URLSessionDownloadDelegate {
    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                                didFinishDownloadingTo location: URL) {
        // The file at `location` is deleted when this method returns: move it somewhere safe first.
        let staging = ModelCatalog.directory.appendingPathComponent("download-\(UUID().uuidString).partial")
        do {
            try FileManager.default.moveItem(at: location, to: staging)
        } catch {
            Task { @MainActor in self.status = .failed("Couldn't save the download.") }
            return
        }
        if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            try? FileManager.default.removeItem(at: staging)
            Task { @MainActor in
                guard self.isCurrent(downloadTask) else { return }
                self.downloadTask = nil
                self.downloadingSpec = nil
                self.status = .failed("The server returned an error (\(http.statusCode)).")
            }
            return
        }
        Task { @MainActor in
            guard self.isCurrent(downloadTask) else { try? FileManager.default.removeItem(at: staging); return }
            self.finishDownload(at: staging)
        }
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                                totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        Task { @MainActor in
            guard self.isCurrent(downloadTask), let spec = self.downloadingSpec else { return }
            let total = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : spec.bytes
            let now = Date()
            let elapsed = now.timeIntervalSince(self.lastProgressTime)
            var speed: Double = 0
            if case .downloading(_, let previous) = self.status { speed = previous }
            if elapsed > 0.5 {
                let instant = Double(totalBytesWritten - self.lastProgressBytes) / elapsed
                speed = speed == 0 ? instant : speed * 0.7 + instant * 0.3
                self.lastProgressTime = now
                self.lastProgressBytes = totalBytesWritten
            }
            self.status = .downloading(progress: Double(totalBytesWritten) / Double(total), bytesPerSecond: speed)
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        let nsError = error as NSError
        let resume = nsError.userInfo[NSURLSessionDownloadTaskResumeData] as? Data
        Task { @MainActor in
            guard self.isCurrent(task) else { return }
            let specID = self.downloadingSpec?.id
            self.downloadTask = nil
            self.downloadingSpec = nil
            if nsError.code == NSURLErrorCancelled { return }
            if let resume, let specID { self.resumeData = (specID, resume) }
            self.status = .failed("Download interrupted: \(error.localizedDescription)")
        }
    }
}

extension Notification.Name {
    static let carrotEngineReady = Notification.Name("CarrotEngineReady")
}
