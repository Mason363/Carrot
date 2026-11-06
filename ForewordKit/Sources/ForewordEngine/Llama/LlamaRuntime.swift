import Foundation
import llama

/// Process-wide llama.cpp initialisation.
public enum LlamaRuntime {
    private static let lock = NSLock()
    private static var initialized = false
    nonisolated(unsafe) fileprivate static var verbose = false

    /// Initialises llama.cpp (Metal and CPU backends are built into the framework). Safe to call
    /// more than once.
    public static func initialize(verbose: Bool = false) {
        lock.lock()
        defer { lock.unlock() }
        guard !initialized else { return }
        Self.verbose = verbose
        let callback: ggml_log_callback = { level, text, _ in
            guard let text else { return }
            if LlamaRuntime.verbose || level == GGML_LOG_LEVEL_ERROR { fputs(text, stderr) }
        }
        llama_log_set(callback, nil)
        ggml_log_set(callback, nil)
        llama_backend_init()
        initialized = true
    }
}

public enum LlamaError: Error, CustomStringConvertible {
    case modelLoadFailed(String)
    case contextCreationFailed
    case decodeFailed(Int32)
    case tokenizationFailed
    case cancelled

    public var description: String {
        switch self {
        case .modelLoadFailed(let path): return "Could not load model at \(path)"
        case .contextCreationFailed: return "Could not create inference context"
        case .decodeFailed(let code): return "Decode failed (\(code))"
        case .tokenizationFailed: return "Tokenization failed"
        case .cancelled: return "Cancelled"
        }
    }
}
