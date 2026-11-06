import llama
import Foundation

/// Owns a llama context and keeps its memory in sync with the prompt being completed so that
/// each keystroke only pays for the tokens that changed.
///
/// * Attention-only models (including SWA models, run with a full-size SWA cache) keep the
///   prompt in sequence 0 and truncate it in place.
/// * Recurrent / hybrid models cannot truncate their state, so the context keeps a few
///   checkpoints of the prompt in spare sequences (a head right behind the cursor and two that
///   lag further back for backspacing) and copies the best one into sequence 0 per request.
///   Copies are copy-on-write inside llama.cpp, so they are cheap.
final class LlamaContext {
    let model: LlamaModel
    let pointer: OpaquePointer
    let memory: llama_memory_t
    let contextLength: Int
    let batchSize: Int
    private var batch: llama_batch

    /// Tokens currently held in sequence 0.
    private(set) var tokens: [Int32] = []

    private static let workSeq: llama_seq_id = 0
    /// Recurrent checkpoints: seq 1 = head, seq 2 = near, seq 3 = far.
    private var checkpoints: [[Int32]] = [[], [], []]
    private static let checkpointSeqs: [llama_seq_id] = [1, 2, 3]
    private static let nearLag = 32
    private static let farLag = 128

    private(set) var stats = Stats()

    struct Stats {
        var promptTokensEvaluated = 0
        var promptTokensReused = 0
        var generatedTokens = 0
    }

    init(model: LlamaModel, contextLength: Int = 4096, batchSize: Int = 512, threads: Int32 = 4) throws {
        self.model = model
        var params = llama_context_default_params()
        params.n_ctx = UInt32(contextLength)
        params.n_batch = UInt32(batchSize)
        params.n_ubatch = UInt32(batchSize)
        params.n_seq_max = model.isRecurrent ? 4 : 1
        params.n_threads = threads
        params.n_threads_batch = threads
        params.flash_attn_type = LLAMA_FLASH_ATTN_TYPE_AUTO
        params.swa_full = true
        params.kv_unified = true
        params.no_perf = true
        params.offload_kqv = true
        guard let ctx = llama_init_from_model(model.pointer, params) else {
            throw LlamaError.contextCreationFailed
        }
        pointer = ctx
        memory = llama_get_memory(ctx)
        self.contextLength = Int(llama_n_ctx(ctx))
        self.batchSize = batchSize
        batch = llama_batch_init(Int32(batchSize), 0, 1)
    }

    deinit {
        llama_batch_free(batch)
        llama_free(pointer)
    }

    func reset() {
        llama_memory_clear(memory, true)
        tokens = []
        checkpoints = [[], [], []]
    }

    /// Makes sequence 0 hold exactly `prompt` and returns the logits for its last token.
    func evaluate(_ prompt: [Int32], cancelled: () -> Bool) throws -> UnsafeMutablePointer<Float> {
        precondition(!prompt.isEmpty)
        if model.isRecurrent {
            return try evaluateRecurrent(prompt, cancelled: cancelled)
        }
        var keep = commonPrefixLength(tokens, prompt)
        if keep == prompt.count { keep -= 1 } // need fresh logits for the last token
        if keep < tokens.count {
            if !llama_memory_seq_rm(memory, Self.workSeq, Int32(keep), -1) {
                llama_memory_seq_rm(memory, Self.workSeq, -1, -1)
                keep = 0
            }
            tokens.removeSubrange(keep...)
        }
        stats.promptTokensReused += keep
        return try decode(Array(prompt[keep...]), seq: Self.workSeq, startPos: keep, wantLogits: true,
                          cancelled: cancelled)!
    }

    private func isValid(_ checkpoint: [Int32], for prompt: [Int32], upTo limit: Int) -> Bool {
        checkpoint.count <= limit && commonPrefixLength(checkpoint, prompt) == checkpoint.count
    }

    private func evaluateRecurrent(_ prompt: [Int32], cancelled: () -> Bool) throws -> UnsafeMutablePointer<Float> {
        let target = prompt.count - 1 // the last token is decoded in seq 0 for logits
        let head = Self.checkpointSeqs[0], near = Self.checkpointSeqs[1], far = Self.checkpointSeqs[2]

        // Invalidate checkpoints that no longer match.
        for i in 0..<3 where !checkpoints[i].isEmpty && !isValid(checkpoints[i], for: prompt, upTo: target) {
            llama_memory_seq_rm(memory, Self.checkpointSeqs[i], -1, -1)
            checkpoints[i] = []
        }
        // Make the head the best starting point.
        if checkpoints[0].isEmpty {
            if checkpoints[1].count >= checkpoints[2].count, !checkpoints[1].isEmpty {
                llama_memory_seq_cp(memory, near, head, -1, -1)
                checkpoints[0] = checkpoints[1]
            } else if !checkpoints[2].isEmpty {
                llama_memory_seq_cp(memory, far, head, -1, -1)
                checkpoints[0] = checkpoints[2]
            }
        }
        // Age the lagging checkpoints before the head moves on.
        if checkpoints[0].count - checkpoints[1].count >= Self.nearLag && target > checkpoints[0].count {
            if checkpoints[1].count - checkpoints[2].count >= Self.farLag || (checkpoints[2].isEmpty && !checkpoints[1].isEmpty) {
                llama_memory_seq_rm(memory, far, -1, -1)
                llama_memory_seq_cp(memory, near, far, -1, -1)
                checkpoints[2] = checkpoints[1]
            }
            llama_memory_seq_rm(memory, near, -1, -1)
            if !checkpoints[0].isEmpty { llama_memory_seq_cp(memory, head, near, -1, -1) }
            checkpoints[1] = checkpoints[0]
        }
        // Advance the head to just before the end of the prompt.
        if target > checkpoints[0].count {
            let extra = Array(prompt[checkpoints[0].count..<target])
            do {
                _ = try decode(extra, seq: head, startPos: checkpoints[0].count, wantLogits: false,
                               cancelled: cancelled, track: false)
            } catch {
                llama_memory_seq_rm(memory, head, -1, -1)
                checkpoints[0] = []
                throw error
            }
            checkpoints[0].append(contentsOf: extra)
        }
        // Rebuild the working sequence from the head.
        llama_memory_seq_rm(memory, Self.workSeq, -1, -1)
        if !checkpoints[0].isEmpty {
            llama_memory_seq_cp(memory, head, Self.workSeq, -1, -1)
        }
        tokens = checkpoints[0]
        stats.promptTokensReused += tokens.count
        return try decode(Array(prompt[tokens.count...]), seq: Self.workSeq, startPos: tokens.count,
                          wantLogits: true, cancelled: cancelled)!
    }

    /// Appends a generated token to sequence 0 and returns the next logits.
    func append(_ token: Int32) throws -> UnsafeMutablePointer<Float> {
        stats.generatedTokens += 1
        return try decode([token], seq: Self.workSeq, startPos: tokens.count, wantLogits: true,
                          cancelled: { false }, countAsPrompt: false)!
    }

    /// Drops everything after the first `count` tokens of sequence 0 (attention models only;
    /// recurrent models rebuild from a checkpoint on the next request anyway).
    func truncate(to count: Int) {
        guard !model.isRecurrent, count < tokens.count else { return }
        if llama_memory_seq_rm(memory, Self.workSeq, Int32(count), -1) {
            tokens.removeSubrange(count...)
        } else {
            reset()
        }
    }

    // MARK: Decoding

    private func decode(_ input: [Int32], seq: llama_seq_id, startPos: Int, wantLogits: Bool,
                        cancelled: () -> Bool, track: Bool = true,
                        countAsPrompt: Bool = true) throws -> UnsafeMutablePointer<Float>? {
        if input.isEmpty { return wantLogits ? llama_get_logits_ith(pointer, -1) : nil }
        var offset = 0
        while offset < input.count {
            if cancelled() { throw LlamaError.cancelled }
            let n = min(batchSize, input.count - offset)
            batch.n_tokens = Int32(n)
            for i in 0..<n {
                batch.token[i] = input[offset + i]
                batch.pos[i] = Int32(startPos + offset + i)
                batch.n_seq_id[i] = 1
                batch.seq_id[i]![0] = seq
                batch.logits[i] = 0
            }
            if offset + n == input.count && wantLogits { batch.logits[n - 1] = 1 }
            let status = llama_decode(pointer, batch)
            if status != 0 {
                // Memory may be partially updated; start clean next time.
                reset()
                throw LlamaError.decodeFailed(status)
            }
            if track { tokens.append(contentsOf: input[offset..<(offset + n)]) }
            if countAsPrompt { stats.promptTokensEvaluated += n }
            offset += n
        }
        return wantLogits ? llama_get_logits_ith(pointer, -1) : nil
    }
}

@inline(__always)
func commonPrefixLength(_ a: [Int32], _ b: [Int32]) -> Int {
    let n = min(a.count, b.count)
    var i = 0
    a.withUnsafeBufferPointer { pa in
        b.withUnsafeBufferPointer { pb in
            while i < n && pa[i] == pb[i] { i += 1 }
        }
    }
    return i
}
