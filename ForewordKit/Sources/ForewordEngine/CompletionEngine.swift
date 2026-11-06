import llama
import Foundation
import os

/// Turns "text before the cursor + context" into a single, confident suggestion.
///
/// Decoding is greedy (deterministic, so suggestions never flicker between alternatives) with:
/// * token healing — the partial word under the cursor is re-generated under a byte constraint;
/// * a repetition guard against parroting the user's own text;
/// * confidence tracking — the suggestion is cut at the last word boundary the model is sure of;
/// * natural stopping at sentence / clause / line ends depending on the length setting.
///
/// All llama.cpp work happens on one serial queue. A newer request cancels older ones between tokens.
public final class CompletionEngine: @unchecked Sendable {
    public let model: LlamaModel
    private let context: LlamaContext
    private let queue = DispatchQueue(label: "app.foreword.engine", qos: .userInteractive)
    private let latestRequest = OSAllocatedUnfairLock(initialState: UInt64(0))
    private var scratch: [Float] = []
    private var bannedTokens: [Int32] = []
    private var newlineTokens: Set<Int32> = []
    private let repetitionGuard = RepetitionGuard()

    private var cachedHeader: (text: String, tokens: [Int32])?

    /// Diagnostics for tools: when enabled, `lastTrace` describes the last decode.
    public var traceEnabled = false
    public private(set) var lastTrace = ""
    private var traceAlternatives: [String] = []

    private func topAlternatives(_ logits: Logits, lse: Float, count: Int) -> String {
        var best: [(Int32, Float)] = []
        for t in 0..<Int32(model.vocabSize) {
            let v = logits[t]
            if best.count < count || v > best[best.count - 1].1 {
                best.append((t, v))
                best.sort { $0.1 > $1.1 }
                if best.count > count { best.removeLast() }
            }
        }
        return best.map { String(format: "%@ %.2f", String(decoding: model.piece($0.0), as: UTF8.self).debugDescription, exp($0.1 - lse)) }
            .joined(separator: ", ")
    }

    /// Maximum document tokens kept in the prompt; older text is dropped in coarse chunks so the
    /// cached prefix stays valid while typing.
    public var maxDocumentTokens = 1536
    public var maxContextTokens = 900
    private let dropChunk = 384

    public init(modelPath: String, contextLength: Int = 4096) throws {
        model = try LlamaModel(path: modelPath)
        context = try LlamaContext(model: model, contextLength: contextLength)
        for t in 0..<Int32(model.vocabSize) {
            let f = model.flags[Int(t)]
            if f.contains(.banned) && !f.contains(.endOfGeneration) { bannedTokens.append(t) }
            if f.contains(.containsNewline) { newlineTokens.insert(t) }
        }
        maxDocumentTokens = min(maxDocumentTokens, context.contextLength / 2)
        maxContextTokens = min(maxContextTokens, context.contextLength / 4)
    }

    // MARK: Public API

    /// Computes a suggestion. Returns `nil` when there is nothing worth showing or the request
    /// was superseded by a newer one.
    public func complete(_ request: CompletionRequest) async -> Completion? {
        let id = latestRequest.withLock { value -> UInt64 in value += 1; return value }
        return await withCheckedContinuation { continuation in
            queue.async {
                guard self.isCurrent(id) else { continuation.resume(returning: nil); return }
                let result = try? self.run(request, isCurrent: { self.isCurrent(id) })
                continuation.resume(returning: result)
            }
        }
    }

    /// Synchronous variant for tools and tests (not cancellable).
    public func completeNow(_ request: CompletionRequest) throws -> Completion? {
        try queue.sync { try run(request, isCurrent: { true }) }
    }

    /// Processes the prompt for a field ahead of time so the first keystroke is fast.
    public func prefill(context header: String, prefix: String) {
        let id = latestRequest.withLock { value -> UInt64 in value += 1; return value }
        queue.async {
            guard self.isCurrent(id) else { return }
            let split = TextAnalysis.split(prefix)
            let prompt = self.promptTokens(header: header, stable: split.stable)
            _ = try? self.context.evaluate(prompt, cancelled: { !self.isCurrent(id) })
        }
    }

    /// Forgets all cached prompt state (diagnostics / after memory pressure).
    public func resetCache() {
        queue.sync { context.reset() }
    }

    /// Cancels any in-flight request.
    public func cancel() {
        latestRequest.withLock { $0 += 1 }
    }

    /// Log-probability scoring of candidate words after `prefix` (used for typo correction).
    /// Returns one log-probability per candidate, in order.
    public func score(context header: String, prefix: String, candidates: [String]) -> [Double] {
        queue.sync {
            candidates.map { candidate in
                let prompt = promptTokens(header: header, stable: prefix)
                let continuation = model.tokenize(candidate, addSpecial: false)
                guard !continuation.isEmpty, var logits = try? context.evaluate(prompt, cancelled: { false }) else {
                    return -.infinity
                }
                var total = 0.0
                for (i, token) in continuation.enumerated() {
                    let l = Logits(pointer: logits, count: model.vocabSize)
                    total += Double(l[token] - l.logSumExp(scratch: &scratch))
                    if i < continuation.count - 1 {
                        guard let next = try? context.append(token) else { return -.infinity }
                        logits = next
                    }
                }
                context.truncate(to: prompt.count)
                return total
            }
        }
    }

    /// Measures prompt-processing and generation throughput (tokens per second).
    public func measureThroughput() -> (prompt: Double, generation: Double) {
        queue.sync {
            context.reset()
            let prompt = (0..<512).map { _ in Int32.random(in: 1000..<Int32(min(model.vocabSize, 20000))) }
            let t0 = DispatchTime.now()
            guard var logits = try? context.evaluate(prompt, cancelled: { false }) else { return (0, 0) }
            let t1 = DispatchTime.now()
            for _ in 0..<32 {
                let next = Logits(pointer: logits, count: model.vocabSize).argmax().index
                guard let l = try? context.append(next) else { break }
                logits = l
            }
            let t2 = DispatchTime.now()
            context.reset()
            let pp = 512 / (Double(t1.uptimeNanoseconds - t0.uptimeNanoseconds) / 1e9)
            let tg = 32 / (Double(t2.uptimeNanoseconds - t1.uptimeNanoseconds) / 1e9)
            return (pp, tg)
        }
    }

    private func isCurrent(_ id: UInt64) -> Bool {
        latestRequest.withLock { $0 == id }
    }

    // MARK: Prompt

    private func promptTokens(header: String, stable: String) -> [Int32] {
        let (headerTokens, doc) = promptParts(header: header, stable: stable)
        if headerTokens.isEmpty && doc.isEmpty && model.addBOS {
            return [model.bosToken]
        }
        return headerTokens + doc
    }

    /// Header tokens (with BOS when the model wants one) and document tokens, trimmed to budget.
    private func promptParts(header: String, stable: String) -> (header: [Int32], document: [Int32]) {
        var headerTokens: [Int32]
        if let cached = cachedHeader, cached.text == header {
            headerTokens = cached.tokens
        } else {
            headerTokens = model.tokenize(header, addSpecial: true)
            if headerTokens.count > maxContextTokens {
                // Keep BOS + the tail of the header (the most specific context is last).
                let bos = model.addBOS ? [headerTokens[0]] : []
                headerTokens = bos + headerTokens.suffix(maxContextTokens - bos.count)
            }
            cachedHeader = (header, headerTokens)
        }
        var doc = model.tokenize(stable, addSpecial: false)
        if doc.count > maxDocumentTokens {
            let excess = doc.count - maxDocumentTokens
            let drop = ((excess + dropChunk - 1) / dropChunk) * dropChunk
            doc.removeFirst(min(drop, doc.count))
        }
        return (headerTokens, doc)
    }

    /// Fill-in-the-middle prompt: <pre> header + text before <suf> text after <mid>.
    private func fimPromptTokens(header: String, stable: String, suffix: String,
                                 fim: (prefix: Int32, suffix: Int32, middle: Int32)) -> (tokens: [Int32], document: [Int32]) {
        var (headerTokens, doc) = promptParts(header: header, stable: stable)
        var bos: [Int32] = []
        if model.addBOS, headerTokens.first == model.bosToken {
            bos = [model.bosToken]
            headerTokens.removeFirst()
        } else if model.addBOS {
            bos = [model.bosToken]
        }
        let after = model.tokenize(String(suffix.prefix(400)), addSpecial: false)
        let tokens = bos + [fim.prefix] + headerTokens + doc + [fim.suffix] + after + [fim.middle]
        return (tokens, doc)
    }

    // MARK: Decoding

    private struct Step {
        var token: Int32
        /// Byte offset in `output` where this step's text ends.
        var end: Int
        var probability: Float
        /// Step happened while reproducing the user's fragment.
        var constrained: Bool
    }

    private enum Stop: String {
        case endOfText, newline, sentence, clause, words, tokens, lowConfidence, closer, unproducible
    }

    private func run(_ request: CompletionRequest, isCurrent: () -> Bool) throws -> Completion? {
        let started = DispatchTime.now()
        let options = request.options
        let split = TextAnalysis.split(request.prefix)
        if split.isSuspicious { return nil }

        let lineSuffix = TextAnalysis.lineSuffix(request.suffix)
        let midLine = !TextAnalysis.isTrivialLineSuffix(lineSuffix)
        if midLine && !options.allowMidLine { return nil }
        // Mid-word with text glued to the cursor ("wor|ld"): never suggest.
        if let first = lineSuffix.first, !first.isWhitespace, split.isMidWord,
           first.unicodeScalars.first.map(TextAnalysis.isWordScalar) == true {
            return nil
        }
        let closer = midLine ? nil : lineSuffix.first(where: { !$0.isWhitespace })

        let prompt: [Int32]
        var history: [Int32]
        let usesFIM = midLine && model.fim != nil
        if midLine, let fim = model.fim {
            let built = fimPromptTokens(header: request.context, stable: split.stable, suffix: request.suffix, fim: fim)
            prompt = built.tokens
            history = Array(built.document.suffix(512))
        } else {
            let parts = promptParts(header: request.context, stable: split.stable)
            prompt = parts.header.isEmpty && parts.document.isEmpty && model.addBOS ? [model.bosToken] : parts.header + parts.document
            history = Array(parts.document.suffix(512))
        }
        let reusedBefore = context.stats.promptTokensReused
        var logitsPointer = try context.evaluate(prompt, cancelled: { !isCurrent() })
        let reused = context.stats.promptTokensReused - reusedBefore
        defer { context.truncate(to: prompt.count) }

        var required = ArraySlice(Array(split.fragment.utf8))
        var output: [UInt8] = []
        var steps: [Step] = []
        var fragmentLogProbability: Float = 0
        var stop: Stop = .tokens
        var lastWordComplete = true
        var sentences = 0
        var pendingSentenceEnd = false
        var runningJoint: Float = 1
        var sawContent = false
        var stopProbability: Float = 1

        let generationBudget = midLine ? 22 : options.length.maxTokens
        let hardLimit = generationBudget * 2 + 10 + max(4, split.fragment.utf8.count)
        var freeSteps = 0

        decodeLoop: for _ in 0..<hardLimit {
            if !isCurrent() { throw LlamaError.cancelled }
            let logits = Logits(pointer: logitsPointer, count: model.vocabSize)
            for t in bannedTokens { logits[t] = -.infinity }

            let token: Int32
            let probability: Float

            if !required.isEmpty {
                // Reproduce the user's fragment. Only allow tokens at least as long as the first
                // token of the fragment's canonical tokenisation, so " at" is never split into
                // " a" + "t…" (an unnatural path that derails the model).
                var allowed = model.tokensCompatible(with: required)
                let canonical = model.tokenize(String(decoding: required, as: UTF8.self), addSpecial: false)
                if let first = canonical.first {
                    let minLength = model.pieceRange(first).count
                    let filtered = allowed.filter { model.pieceRange($0).count >= minLength }
                    if !filtered.isEmpty { allowed = filtered }
                }
                if allowed.isEmpty { stop = .unproducible; return nil }
                let lseAll = logits.logSumExp(scratch: &scratch)
                let lseAllowed = logits.logSumExp(of: allowed)
                fragmentLogProbability += lseAllowed - lseAll
                var best = allowed[0]
                for t in allowed where logits[t] > logits[best] { best = t }
                token = best
                probability = exp(logits[best] - lseAllowed)
                let piece = model.piece(token)
                if piece.count <= required.count {
                    required = required.dropFirst(piece.count)
                    steps.append(Step(token: token, end: output.count, probability: probability, constrained: true))
                } else {
                    let overflow = piece.dropFirst(required.count)
                    required = []
                    // The overflow may already contain a newline / closer.
                    if overflow.contains(0x0A) || overflow.contains(0x0D) {
                        stop = .newline
                        lastWordComplete = true
                        break decodeLoop
                    }
                    output.append(contentsOf: overflow)
                    steps.append(Step(token: token, end: output.count, probability: probability, constrained: false))
                    freeSteps += 1
                }
            } else {
                if options.repetitionGuard {
                    let penalties = repetitionGuard.penalties(history: history) { self.newlineTokens.contains($0) }
                    for (t, p) in penalties { logits[t] -= p }
                }
                let lse = logits.logSumExp(scratch: &scratch)
                let (best, value) = logits.argmax()
                token = best
                probability = exp(value - lse)
                if traceEnabled { traceAlternatives.append(topAlternatives(logits, lse: lse, count: 4)) }
                let flags = model.flags[Int(token)]
                let boundary = flags.contains(.boundaryBefore) || flags.contains(.endOfGeneration)

                if pendingSentenceEnd {
                    pendingSentenceEnd = false
                    if boundary || flags.contains(.containsNewline) {
                        sentences += 1
                        if sentences >= options.length.maxSentences && !midLine {
                            stop = .sentence
                            lastWordComplete = true
                            break decodeLoop
                        }
                    }
                }
                if flags.contains(.endOfGeneration) {
                    stop = .endOfText
                    stopProbability = probability
                    lastWordComplete = true
                    break decodeLoop
                }
                if freeSteps >= generationBudget {
                    // Copying something verbatim (a link, an address) is cheap and certain: let it finish.
                    let copying = steps.suffix(3).allSatisfy { $0.probability >= 0.9 } && probability >= 0.9
                    if !(copying && freeSteps < generationBudget * 2 + 8) {
                        stop = .tokens
                        lastWordComplete = boundary || flags.contains(.containsNewline)
                        break decodeLoop
                    }
                }
                // Nothing past this point could be shown: the joint probability only decreases.
                // Within the phrase target the looser phrase thresholds apply.
                let prospectiveJoint = runningJoint * probability
                let withinTarget = TextAnalysis.wordCount(String(decoding: output, as: UTF8.self)) < Double(options.length.targetWords)
                let jointFloor = !sawContent ? min(options.minFirstWordProbability, options.minWordCompletionProbability)
                    : (withinTarget ? options.minPhraseJointProbability : options.minJointProbability)
                let tokenFloor = withinTarget ? options.minPhraseTokenProbability : options.minTokenProbability
                if !midLine && (Double(probability) < tokenFloor || Double(prospectiveJoint) < jointFloor) {
                    stop = .lowConfidence
                    lastWordComplete = boundary || flags.contains(.containsNewline)
                    break decodeLoop
                }
                let piece = model.piece(token)
                if flags.contains(.containsNewline) {
                    // Keep whatever precedes the newline, then stop.
                    let before = piece.prefix(while: { $0 != 0x0A && $0 != 0x0D })
                    if !before.isEmpty && !before.allSatisfy({ $0 == 0x20 || $0 == 0x09 }) {
                        output.append(contentsOf: before)
                        steps.append(Step(token: token, end: output.count, probability: probability, constrained: false))
                    }
                    stop = .newline
                    lastWordComplete = true
                    break decodeLoop
                }
                if let closer, let text = String(bytes: piece, encoding: .utf8), text.contains(closer) {
                    let before = text[..<text.firstIndex(of: closer)!]
                    if !before.isEmpty {
                        output.append(contentsOf: Array(before.utf8))
                        steps.append(Step(token: token, end: output.count, probability: probability, constrained: false))
                    }
                    stop = .closer
                    lastWordComplete = true
                    break decodeLoop
                }
                if !midLine, options.length == .short, boundary, freeSteps > 0,
                   let lastChar = String(decoding: output.suffix(4), as: UTF8.self).last,
                   TextAnalysis.isClauseEnd(lastChar), TextAnalysis.wordCount(String(decoding: output, as: UTF8.self)) >= 2 {
                    stop = .clause
                    lastWordComplete = true
                    break decodeLoop
                }
                if !midLine, boundary, TextAnalysis.wordCount(String(decoding: output, as: UTF8.self)) >= options.length.maxWords {
                    stop = .words
                    lastWordComplete = true
                    break decodeLoop
                }
                output.append(contentsOf: piece)
                steps.append(Step(token: token, end: output.count, probability: probability, constrained: false))
                freeSteps += 1

                // Sentence end? CJK terminators end immediately; Latin ones need a following boundary.
                if let text = String(bytes: piece, encoding: .utf8), let last = text.last, TextAnalysis.isSentenceEnd(last) {
                    if "。！？".contains(last) {
                        sentences += 1
                        if sentences >= options.length.maxSentences && !midLine {
                            stop = .sentence
                            lastWordComplete = true
                            history.append(token)
                            break decodeLoop
                        }
                    } else {
                        pendingSentenceEnd = true
                    }
                }
            }
            history.append(token)
            runningJoint *= probability
            if !sawContent, output.contains(where: { !LlamaModel.isBoundaryByte($0) }) { sawContent = true }
            logitsPointer = try context.append(token)
        }

        if traceEnabled {
            var t = "  raw: \(String(decoding: output, as: UTF8.self).debugDescription) [\(stop.rawValue)]\n  steps:"
            var previous = 0
            for s in steps {
                let piece = s.end > previous ? String(decoding: output[previous..<s.end], as: UTF8.self) : "·"
                t += String(format: " %@%@=%.2f", s.constrained ? "^" : "", piece.debugDescription, s.probability)
                previous = max(previous, s.end)
            }
            t += "\n  top: " + traceAlternatives.prefix(4).joined(separator: " | ")
            lastTrace = t
            traceAlternatives = []
        }

        let fragmentProbability = Double(exp(fragmentLogProbability))
        var completion: Completion?
        if midLine {
            if usesFIM, stop == .endOfText {
                completion = fimMiddle(output: output, steps: steps, endProbability: stopProbability,
                                       lineSuffix: lineSuffix, options: options)
            }
            if completion == nil {
                completion = alignInsertion(output: output, steps: steps, lineSuffix: lineSuffix, options: options)
            }
            // Finishing the word under the cursor is safe even when the rest can't be placed.
            if completion == nil, split.isMidWord, let first = lineSuffix.first, first.isWhitespace || first.isPunctuation {
                completion = wordCompletion(output: output, steps: steps, split: split, options: options)
            }
        } else {
            completion = selectContinuation(output: output, steps: steps, lastWordComplete: lastWordComplete,
                                            split: split, prefix: request.prefix, options: options)
        }
        guard var result = completion else { return nil }
        result.fragmentProbability = fragmentProbability
        result.promptTokens = prompt.count
        result.reusedTokens = reused
        result.generatedTokens = steps.count
        result.stopReason = stop.rawValue
        result.milliseconds = Double(DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1e6
        return result
    }

    // MARK: Suggestion selection

    private static let fillerWords: Set<String> = [
        "the", "a", "an", "and", "or", "but", "to", "of", "in", "on", "at", "for", "with", "is", "it",
        "i", "that", "this", "be", "as", "so", "we", "you", "my", "your", "if", "are", "was", "not",
        "have", "has", "by", "from", "will", "can", "do", "just", "also", "very", "really",
    ]

    /// Whether a suggestion may end at byte `index` of `output`: only where the word really ends —
    /// whitespace after any closing punctuation — so links, emails, numbers ("3.5", "10:30") and
    /// contractions ("don't") are never cut in half.
    static func isWordEnd(output: [UInt8], at index: Int, outputComplete: Bool) -> Bool {
        var j = index
        let trailing: Set<UInt8> = Set(".,;:!?)]}\"'".utf8)
        while j < output.count, trailing.contains(output[j]) { j += 1 }
        if j >= output.count { return outputComplete }
        let b = output[j]
        if b == 0x20 || b == 0x09 || b == 0x0A || b == 0x0D { return true }
        // Multi-byte punctuation (…, ”, ’) followed by a space also ends a word.
        if b >= 0x80 {
            let rest = String(decoding: output[j...].prefix(8), as: UTF8.self)
            if let first = rest.first, "…”’»」".contains(first) {
                let after = rest.dropFirst().first
                return after == nil ? outputComplete : after!.isWhitespace
            }
        }
        return false
    }

    private static var danglingWords: Set<String> { TextAnalysis.danglingWords }

    /// Picks the longest prefix of the generated text that ends on a word boundary and that the
    /// model is confident about.
    private func selectContinuation(output: [UInt8], steps: [Step], lastWordComplete: Bool, split: PrefixSplit,
                                    prefix: String, options: CompletionOptions) -> Completion? {
        guard !steps.isEmpty, !output.isEmpty else { return nil }

        // Cut points: after step i if the next step starts a new word (or generation ended at a boundary).
        struct Cut {
            var end: Int
            var joint: Float
            /// Expected characters a user could accept up to here (word by word).
            var expected: Float
            var lastWord: String
        }
        var joint: Float = 1
        var minProbability: Float = 1
        var firstWordProbability: Float?
        var cuts: [Cut] = []
        var expected: Float = 0
        var previousCut = 0
        for (i, step) in steps.enumerated() {
            joint *= step.probability
            if !step.constrained { minProbability = min(minProbability, step.probability) }
            let isLast = i == steps.count - 1
            let nextStartsWord: Bool
            if isLast {
                nextStartsWord = lastWordComplete
            } else {
                let next = steps[i + 1]
                nextStartsWord = model.flags[Int(next.token)].contains(.boundaryBefore) && !next.constrained
                    && Self.isWordEnd(output: output, at: step.end, outputComplete: lastWordComplete)
            }
            guard nextStartsWord, step.end > 0 else { continue }
            let text = String(decoding: output[..<step.end], as: UTF8.self)
            let hasContent = text.unicodeScalars.contains { TextAnalysis.isWordScalar($0) || TextAnalysis.isCJK($0) }
            if !hasContent { continue }
            if firstWordProbability == nil { firstWordProbability = joint }
            let segment = String(decoding: output[previousCut..<step.end], as: UTF8.self)
            let previousJoint = cuts.last?.joint ?? 1
            let conditional = cuts.isEmpty ? 1 : joint / max(previousJoint, 1e-6)
            // Phrases: up to the target length a further word only has to be plausible.
            let withinTarget = cuts.count < options.length.targetWords
            let jointFloor = withinTarget ? options.minPhraseJointProbability : options.minJointProbability
            let tokenFloor = withinTarget ? options.minPhraseTokenProbability : options.minTokenProbability
            let extensionFloor = withinTarget ? options.minPhraseExtensionProbability : options.minExtensionProbability
            if Double(joint) >= jointFloor && Double(minProbability) >= tokenFloor && Double(conditional) >= extensionFloor {
                expected += joint * Float(segment.count)
                previousCut = step.end
                let word = segment.trimmingCharacters(in: .whitespaces).lowercased()
                cuts.append(Cut(end: step.end, joint: joint, expected: expected, lastWord: word))
            } else {
                break
            }
        }
        guard let firstWord = firstWordProbability, !cuts.isEmpty else { return nil }
        let completesWord = split.isMidWord && output.first.map({ !LlamaModel.isBoundaryByte($0) }) == true
        var firstThreshold = completesWord ? options.minWordCompletionProbability : options.minFirstWordProbability
        // One or two typed letters leave too many possible words: demand more certainty.
        if split.isMidWord, let first = split.partialWord.unicodeScalars.first, !TextAnalysis.isCJK(first) {
            let typed = split.partialWord.count
            if typed < 3 { firstThreshold += 0.14 * Double(3 - typed) }
        }
        guard Double(firstWord) >= firstThreshold else { return nil }

        // Don't leave the user hanging on "…and", "…the", "…I am".
        while cuts.count > 1, Self.danglingWords.contains(cuts[cuts.count - 1].lastWord) {
            cuts.removeLast()
        }
        var best = cuts[cuts.count - 1]
        // Worth showing? Word completions are cheap to ignore; full words must pay for the glance.
        if !(Double(best.expected) >= options.minExpectedCharacters || Double(firstWord) >= 0.6) {
            // A phrase that isn't worth it can still be worth finishing the word under the cursor.
            guard completesWord else { return nil }
            best = cuts[0]
        }
        let bestJoint = best.joint

        var text = String(decoding: output[..<best.end], as: UTF8.self)
        // Never end on whitespace; never start with whitespace the user already typed.
        while let last = text.last, last.isWhitespace { text.removeLast() }
        guard text.unicodeScalars.filter({ !$0.properties.isWhitespace }).count >= 2 else { return nil }

        // A lone filler word is rarely worth a glance.
        if !split.isMidWord {
            let words = TextAnalysis.wordCount(text)
            let normalized = TextAnalysis.normalized(text).trimmingCharacters(in: .punctuationCharacters)
            if words <= 1, Self.fillerWords.contains(normalized), Double(bestJoint) < options.minFillerProbability {
                return nil
            }
        }
        // Echo: the suggestion already appears verbatim in what the user wrote.
        if TextAnalysis.wordCount(text) >= 4 {
            let haystack = TextAnalysis.normalized(String(prefix.suffix(6000)))
            if haystack.contains(TextAnalysis.normalized(text)) { return nil }
        }
        return Completion(text: text, kind: .continuation, probability: Double(bestJoint),
                          firstWordProbability: Double(firstWord), fragmentProbability: 0)
    }

    /// Just the rest of the word under the cursor ("smi" → "led").
    private func wordCompletion(output: [UInt8], steps: [Step], split: PrefixSplit, options: CompletionOptions) -> Completion? {
        var joint: Float = 1
        for (i, step) in steps.enumerated() {
            joint *= step.probability
            guard step.end > 0 else { continue }
            let nextIsBoundary = i + 1 < steps.count
                ? model.flags[Int(steps[i + 1].token)].contains(.boundaryBefore)
                : true
            guard nextIsBoundary else { continue }
            let text = String(decoding: output[..<step.end], as: UTF8.self)
            guard let firstScalar = text.unicodeScalars.first, TextAnalysis.isWordScalar(firstScalar),
                  text.count >= 2 else { return nil }
            var threshold = options.minWordCompletionProbability
            if split.partialWord.count < 3 { threshold += 0.14 * Double(3 - split.partialWord.count) }
            guard Double(joint) >= max(threshold, 0.35) else { return nil }
            return Completion(text: text, kind: .insertion, probability: Double(joint),
                              firstWordProbability: Double(joint), fragmentProbability: 0)
        }
        return nil
    }

    /// FIM: the model ended the middle on its own. The whole output is the insertion.
    private func fimMiddle(output: [UInt8], steps: [Step], endProbability: Float, lineSuffix: Substring,
                           options: CompletionOptions) -> Completion? {
        guard !steps.isEmpty else { return nil }
        var text = String(decoding: output, as: UTF8.self)
        // If the middle runs into the text after the cursor, cut it there.
        if let aligned = alignInsertion(output: output, steps: steps, lineSuffix: lineSuffix, options: options) {
            return aligned
        }
        // Spacing: never double the space the suffix already starts with.
        if lineSuffix.first == " " { while text.last == " " { text.removeLast() } }
        guard text.unicodeScalars.contains(where: { TextAnalysis.isWordScalar($0) || TextAnalysis.isCJK($0) }),
              TextAnalysis.wordCount(text) <= 8 else { return nil }
        let joint = steps.reduce(Float(1)) { $0 * $1.probability } * endProbability
        guard Double(joint) >= options.minFirstWordProbability * 0.7 else { return nil }
        return Completion(text: text, kind: .insertion, probability: Double(joint),
                          firstWordProbability: Double(joint), fragmentProbability: 0)
    }

    /// For mid-line suggestions: find where the generated text rejoins the existing text after the
    /// cursor and suggest only what goes in between.
    private func alignInsertion(output: [UInt8], steps: [Step], lineSuffix: Substring,
                                options: CompletionOptions) -> Completion? {
        guard !steps.isEmpty else { return nil }
        let leading = lineSuffix.prefix(while: { $0 == " " || $0 == "\t" })
        let body = lineSuffix.dropFirst(leading.count)
        guard !body.isEmpty else { return nil }
        let words = body.split(separator: " ", omittingEmptySubsequences: true)
        let lowered = Array(String(decoding: output, as: UTF8.self).lowercased().utf8)
        guard lowered.count == output.count else { return nil } // case folding changed length; skip

        // Prefer matching two words; fall back to one distinctive word.
        var heads: [String] = []
        if words.count >= 2 { heads.append(String(leading) + words.prefix(2).joined(separator: " ")) }
        if let first = words.first, first.count >= 3 || words.count == 1 { heads.append(String(leading) + first) }

        for head in heads {
            guard head.trimmingCharacters(in: .whitespaces).count >= 2 else { continue }
            // Tokenizers glue spaces to the following word, so when the existing text starts right at
            // the cursor ("grocery|store"), look for " head" and keep that space in the insertion.
            let variants: [(bytes: [UInt8], keep: Int)] = leading.isEmpty
                ? [(Array(head.lowercased().utf8), 0), (Array((" " + head).lowercased().utf8), 1)]
                : [(Array(head.lowercased().utf8), 0)]
            var joint: Float = 1
            for step in steps {
                joint *= step.probability
                let k = step.end
                var matchedKeep: Int?
                for variant in variants {
                    let headBytes = variant.bytes
                    guard k > 0, k + headBytes.count <= lowered.count,
                          Array(lowered[k..<(k + headBytes.count)]) == headBytes else { continue }
                    // The match must be a whole word in the generated text.
                    if leading.isEmpty, variant.keep == 0, !LlamaModel.isBoundaryByte(lowered[k - 1]) { continue }
                    let after = k + headBytes.count
                    if after < lowered.count, !LlamaModel.isBoundaryByte(lowered[after]),
                       headBytes.last.map({ !LlamaModel.isBoundaryByte($0) }) == true { continue }
                    matchedKeep = variant.keep
                    break
                }
                guard let keep = matchedKeep else { continue }
                let text = String(decoding: output[..<(k + keep)], as: UTF8.self)
                guard Double(joint) >= options.minFirstWordProbability * 0.7,
                      text.unicodeScalars.contains(where: { TextAnalysis.isWordScalar($0) || TextAnalysis.isCJK($0) })
                else { return nil }
                return Completion(text: text, kind: .insertion, probability: Double(joint),
                                  firstWordProbability: Double(joint), fragmentProbability: 0)
            }
        }
        return nil
    }
}
