import llama
import Foundation

/// A loaded GGUF model plus a byte-level index of its vocabulary.
///
/// The index lets the decoder constrain generation to tokens that agree with text the user
/// has already typed (token healing / mid-word completion) without scanning the whole vocabulary.
public final class LlamaModel: @unchecked Sendable {
    let pointer: OpaquePointer
    let vocab: OpaquePointer

    public let path: String
    public let name: String
    public let vocabSize: Int
    public let addBOS: Bool
    public let bosToken: Int32
    /// Recurrent or hybrid models (Mamba, DeltaNet, LFM…) cannot truncate their state in place.
    public let isRecurrent: Bool
    public let slidingWindow: Int
    public let trainedContext: Int
    public let parameterCount: UInt64
    public let fileSize: UInt64

    // MARK: Vocabulary tables

    /// All token pieces concatenated; token `t` occupies `pieceBytes[pieceStart[t]..<pieceStart[t+1]]`.
    let pieceBytes: [UInt8]
    let pieceStart: [Int32]
    let flags: [TokenFlags]
    /// Tokens bucketed by their first byte, and by their first two bytes.
    let byFirstByte: [[Int32]]
    let byFirstTwoBytes: [UInt16: [Int32]]

    struct TokenFlags: OptionSet {
        let rawValue: UInt8
        /// Control / special / empty tokens: never produced as text.
        static let banned = TokenFlags(rawValue: 1 << 0)
        static let endOfGeneration = TokenFlags(rawValue: 1 << 1)
        static let containsNewline = TokenFlags(rawValue: 1 << 2)
        /// Piece begins with a space, tab or punctuation: a word boundary precedes it.
        static let boundaryBefore = TokenFlags(rawValue: 1 << 3)
        /// Piece is pure whitespace.
        static let whitespace = TokenFlags(rawValue: 1 << 4)
        /// Piece contains a byte that is not valid as a standalone UTF-8 sequence.
        static let partialUTF8 = TokenFlags(rawValue: 1 << 5)
    }

    public init(path: String, gpuLayers: Int32 = -1) throws {
        var params = llama_model_default_params()
        params.n_gpu_layers = gpuLayers
        guard let model = llama_model_load_from_file(path, params) else {
            throw LlamaError.modelLoadFailed(path)
        }
        pointer = model
        vocab = llama_model_get_vocab(model)
        self.path = path
        vocabSize = Int(llama_vocab_n_tokens(vocab))
        addBOS = llama_vocab_get_add_bos(vocab)
        bosToken = llama_vocab_bos(vocab)
        isRecurrent = llama_model_is_recurrent(model) || llama_model_is_hybrid(model)
        slidingWindow = Int(llama_model_n_swa(model))
        trainedContext = Int(llama_model_n_ctx_train(model))
        parameterCount = llama_model_n_params(model)
        fileSize = llama_model_size(model)

        var descBuffer = [CChar](repeating: 0, count: 256)
        llama_model_desc(model, &descBuffer, descBuffer.count)
        name = String(cString: descBuffer)

        // Build the vocabulary tables.
        var bytes: [UInt8] = []
        bytes.reserveCapacity(vocabSize * 7)
        var starts: [Int32] = []
        starts.reserveCapacity(vocabSize + 1)
        var flags: [TokenFlags] = []
        flags.reserveCapacity(vocabSize)
        var buffer = [CChar](repeating: 0, count: 256)

        for token in 0..<Int32(vocabSize) {
            starts.append(Int32(bytes.count))
            var f: TokenFlags = []
            if llama_vocab_is_eog(vocab, token) { f.insert(.endOfGeneration) }
            if llama_vocab_is_control(vocab, token) { f.insert(.banned) }
            var n = llama_token_to_piece(vocab, token, &buffer, Int32(buffer.count), 0, false)
            if n < 0 {
                buffer = [CChar](repeating: 0, count: Int(-n) + 1)
                n = llama_token_to_piece(vocab, token, &buffer, Int32(buffer.count), 0, false)
            }
            if n <= 0 {
                f.insert(.banned)
            } else {
                let piece = buffer[0..<Int(n)].map { UInt8(bitPattern: $0) }
                bytes.append(contentsOf: piece)
                if piece.contains(0x0A) || piece.contains(0x0D) { f.insert(.containsNewline) }
                if piece.allSatisfy({ $0 == 0x20 || $0 == 0x09 || $0 == 0x0A || $0 == 0x0D }) {
                    f.insert(.whitespace)
                }
                if let first = piece.first, LlamaModel.isBoundaryByte(first) { f.insert(.boundaryBefore) }
                if String(validatingUTF8: buffer[0..<Int(n)] + [0]) == nil { f.insert(.partialUTF8) }
            }
            flags.append(f)
        }
        starts.append(Int32(bytes.count))

        var firstByte = [[Int32]](repeating: [], count: 256)
        var firstTwo: [UInt16: [Int32]] = [:]
        for token in 0..<vocabSize where !flags[token].contains(.banned) {
            let s = Int(starts[token]), e = Int(starts[token + 1])
            guard e > s else { continue }
            firstByte[Int(bytes[s])].append(Int32(token))
            if e - s >= 2 {
                let key = UInt16(bytes[s]) << 8 | UInt16(bytes[s + 1])
                firstTwo[key, default: []].append(Int32(token))
            }
        }

        pieceBytes = bytes
        pieceStart = starts
        self.flags = flags
        byFirstByte = firstByte
        byFirstTwoBytes = firstTwo

        fim = Self.findFIM(vocab: vocab)
    }

    /// Fill-in-the-middle tokens, from metadata or by their conventional spelling.
    private static func findFIM(vocab: OpaquePointer) -> (prefix: Int32, suffix: Int32, middle: Int32)? {
        func special(_ id: Int32, _ spelling: String) -> Int32? {
            if id >= 0 { return id }
            var tokens = [Int32](repeating: 0, count: 8)
            let n = llama_tokenize(vocab, spelling, Int32(spelling.utf8.count), &tokens, 8, false, true)
            return n == 1 ? tokens[0] : nil
        }
        guard let pre = special(llama_vocab_fim_pre(vocab), "<|fim_prefix|>"),
              let suf = special(llama_vocab_fim_suf(vocab), "<|fim_suffix|>"),
              let mid = special(llama_vocab_fim_mid(vocab), "<|fim_middle|>") else { return nil }
        return (pre, suf, mid)
    }

    /// Fill-in-the-middle control tokens (prefix, suffix, middle), when the model has them.
    public let fim: (prefix: Int32, suffix: Int32, middle: Int32)?

    deinit {
        llama_model_free(pointer)
    }

    // MARK: Tokenization

    public func tokenize(_ text: String, addSpecial: Bool) -> [Int32] {
        let count = text.utf8.count
        guard count > 0 || addSpecial else { return [] }
        var capacity = count + 16
        var tokens = [Int32](repeating: 0, count: capacity)
        var n = llama_tokenize(vocab, text, Int32(count), &tokens, Int32(capacity), addSpecial, false)
        if n < 0 {
            capacity = Int(-n)
            tokens = [Int32](repeating: 0, count: capacity)
            n = llama_tokenize(vocab, text, Int32(count), &tokens, Int32(capacity), addSpecial, false)
        }
        guard n >= 0 else { return [] }
        return Array(tokens.prefix(Int(n)))
    }

    @inline(__always)
    func pieceRange(_ token: Int32) -> Range<Int> {
        Int(pieceStart[Int(token)])..<Int(pieceStart[Int(token) + 1])
    }

    @inline(__always)
    func piece(_ token: Int32) -> ArraySlice<UInt8> {
        pieceBytes[pieceRange(token)]
    }

    public func text(of tokens: [Int32]) -> String {
        var bytes: [UInt8] = []
        for t in tokens { bytes.append(contentsOf: piece(t)) }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// Tokens whose piece is consistent with `required`: either the piece is a prefix of
    /// `required`, or `required` is a prefix of the piece.
    func tokensCompatible(with required: ArraySlice<UInt8>) -> [Int32] {
        guard let b0 = required.first else { return [] }
        var result: [Int32] = []
        // Single-byte pieces and pieces that are prefixes of `required` start with b0.
        // Use the two-byte bucket when possible to avoid scanning the whole first-byte bucket.
        let candidates: [Int32]
        if required.count >= 2 {
            let b1 = required[required.startIndex + 1]
            let key = UInt16(b0) << 8 | UInt16(b1)
            var merged = byFirstTwoBytes[key] ?? []
            // Add the one-byte piece equal to b0 (if any).
            for t in byFirstByte[Int(b0)] where pieceRange(t).count == 1 { merged.append(t) }
            candidates = merged
        } else {
            candidates = byFirstByte[Int(b0)]
        }
        pieceBytes.withUnsafeBufferPointer { all in
            required.withUnsafeBufferPointer { req in
                for t in candidates {
                    let r = pieceRange(t)
                    let n = min(r.count, req.count)
                    var ok = true
                    var i = 0
                    while i < n {
                        if all[r.lowerBound + i] != req[i] { ok = false; break }
                        i += 1
                    }
                    if ok { result.append(t) }
                }
            }
        }
        return result
    }

    @inline(__always)
    static func isBoundaryByte(_ b: UInt8) -> Bool {
        switch b {
        case 0x20, 0x09, 0x0A, 0x0D: return true
        case 0x21...0x2F, 0x3A...0x40, 0x5B...0x60, 0x7B...0x7E: return true // ASCII punctuation
        default: return false
        }
    }

    public var summary: String {
        let gb = Double(fileSize) / 1_073_741_824
        return String(format: "%@ · %.2f GB · vocab %d%@%@", name, gb, vocabSize,
                      isRecurrent ? " · recurrent" : "", slidingWindow > 0 ? " · swa \(slidingWindow)" : "")
    }
}
