import Foundation

/// The models Foreword can download. All are *base* (not chat) models: they continue text instead
/// of answering it, which is what autocomplete needs.
struct ModelSpec: Identifiable, Equatable {
    let id: String
    let name: String
    /// The underlying model, for display ("Qwen3.5 2B").
    let modelName: String
    let summary: String
    let url: URL
    let fileName: String
    let bytes: Int64
    let sha256: String
    /// Below this much memory the model is not recommended.
    let recommendedMemoryGB: Int

    var sizeDescription: String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

enum ModelCatalog {
    static let fast = ModelSpec(
        id: "qwen3.5-0.8b", name: "Fast", modelName: "Qwen3.5 0.8B",
        summary: "Smallest and quickest. Good on 8 GB Macs.",
        url: URL(string: "https://huggingface.co/ggml-org/Qwen3.5-0.8B-Base-GGUF/resolve/main/Qwen3.5-0.8B-Base-Q8_0.gguf")!,
        fileName: "Qwen3.5-0.8B-Base-Q8_0.gguf", bytes: 833_591_872,
        sha256: "02fbcf13dd07601e5801cdef73ace47426c422742fa68fd0c607a8b88eea0790", recommendedMemoryGB: 8)

    static let balanced = ModelSpec(
        id: "qwen3.5-2b", name: "Balanced", modelName: "Qwen3.5 2B",
        summary: "Sharp predictions at typing speed.",
        url: URL(string: "https://huggingface.co/mradermacher/Qwen3.5-2B-Base-i1-GGUF/resolve/main/Qwen3.5-2B-Base.i1-Q4_K_M.gguf")!,
        fileName: "Qwen3.5-2B-Base.i1-Q4_K_M.gguf", bytes: 1_274_397_056,
        sha256: "e3daa3f6e5ed8de264fc6e4128713ae1eb0c2649ad69b83f97bfc6a6ddca3da8", recommendedMemoryGB: 8)

    static let best = ModelSpec(
        id: "qwen3.5-4b", name: "Best", modelName: "Qwen3.5 4B",
        summary: "Most accurate. Needs a recent Mac with 16 GB or more.",
        url: URL(string: "https://huggingface.co/mradermacher/Qwen3.5-4B-Base-i1-GGUF/resolve/main/Qwen3.5-4B-Base.i1-Q4_K_M.gguf")!,
        fileName: "Qwen3.5-4B-Base.i1-Q4_K_M.gguf", bytes: 2_708_804_864,
        sha256: "306f85edfd07bea006c438947d1f16fd476decb9d9aec9ea65e0cecc8671bed3", recommendedMemoryGB: 16)

    static let all = [fast, balanced, best]
    static let defaultModel = balanced

    static func spec(id: String) -> ModelSpec? { all.first { $0.id == id } }

    /// The default for this Mac's memory.
    static var recommended: ModelSpec {
        let gb = Int(ProcessInfo.processInfo.physicalMemory / 1_073_741_824)
        return gb < 12 ? fast : balanced
    }

    static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Foreword/Models", isDirectory: true)
    }

    static func localURL(for spec: ModelSpec) -> URL {
        directory.appendingPathComponent(spec.fileName)
    }

    static func isDownloaded(_ spec: ModelSpec) -> Bool {
        let url = localURL(for: spec)
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? Int64 else { return false }
        return size == spec.bytes
    }
}
