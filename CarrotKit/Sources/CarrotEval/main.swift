import CarrotEngine
import Foundation

// carrot-eval — quality and latency harness for the prediction engine.
//
//   carrot-eval cases <model.gguf> [--eager 0.5] [--length medium] [--trace]
//   carrot-eval sim   <model.gguf> [--eager 0.5] [--length medium] [--verbose] [--docs corpus.json] [--log out.jsonl]
//   carrot-eval bench <model.gguf>

setvbuf(stdout, nil, _IONBF, 0)
let args = CommandLine.arguments
guard args.count >= 3 else {
    print("usage: carrot-eval <cases|sim|bench> <model.gguf> [--eager x] [--length short|medium|long] [--trace] [--verbose]")
    exit(1)
}
let command = args[1]
let modelPath = args[2]

func flag(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}

var options = CompletionOptions()
if let e = flag("--eager").flatMap(Double.init) { options.applyEagerness(e) } else { options.applyEagerness(0.5) }
if let l = flag("--length").flatMap(SuggestionLength.init(rawValue:)) { options.length = l }
if let v = flag("--min-joint").flatMap(Double.init) { options.minJointProbability = v }
if let v = flag("--min-ext").flatMap(Double.init) { options.minExtensionProbability = v }
if let v = flag("--min-first").flatMap(Double.init) { options.minFirstWordProbability = v }
if let v = flag("--min-word").flatMap(Double.init) { options.minWordCompletionProbability = v }
if let v = flag("--min-expected").flatMap(Double.init) { options.minExpectedCharacters = v }
if let v = flag("--phrase-ext").flatMap(Double.init) { options.minPhraseExtensionProbability = v }
if let v = flag("--phrase-joint").flatMap(Double.init) { options.minPhraseJointProbability = v }
if let v = flag("--phrase-token").flatMap(Double.init) { options.minPhraseTokenProbability = v }
if let v = flag("--min-new").flatMap(Double.init) { options.minNewWordProbability = v }
if let v = flag("--cost").flatMap(Double.init) { options.wrongCharacterCost = v }
let checksWords = args.contains("--check-words")
// `--chain`: after a suggestion is taken whole, the next one is asked for right away (as the app
// does) instead of after the next keystroke.
let chains = args.contains("--chain")
let wordChecker = WordChecker()
let trace = args.contains("--trace")
let verbose = args.contains("--verbose")

LlamaRuntime.initialize(verbose: args.contains("--llama-logs"))
let loadStart = Date()
let engine: CompletionEngine
do {
    engine = try CompletionEngine(modelPath: modelPath)
} catch {
    print("error: \(error)")
    exit(1)
}
engine.traceEnabled = trace || verbose
print("model: \(engine.model.summary) — loaded in \(String(format: "%.2f", Date().timeIntervalSince(loadStart)))s")
print(String(format: "thresholds: first %.2f joint %.2f token %.2f length %@", options.minFirstWordProbability,
             options.minJointProbability, options.minTokenProbability, options.length.rawValue))

func percentile(_ values: [Double], _ p: Double) -> Double {
    guard !values.isEmpty else { return 0 }
    let sorted = values.sorted()
    return sorted[min(sorted.count - 1, Int(Double(sorted.count) * p))]
}

switch command {
case "cases":
    // Warm up Metal pipelines.
    _ = try? engine.completeNow(CompletionRequest(context: "", prefix: "Hello there, how are", options: options))
    var times: [Double] = []
    for c in evalCases {
        let header = PromptBuilder.header(for: c.context)
        let result = try engine.completeNow(CompletionRequest(context: header, prefix: c.prefix, suffix: c.suffix, options: options))
        let tail = String(c.prefix.suffix(50)).replacingOccurrences(of: "\n", with: "⏎")
        if let r = result {
            times.append(r.milliseconds)
            print(String(format: "✓ %-26@ …%@ ⟨%@⟩  p=%.2f first=%.2f frag=%.3f %.0fms [%@] (%@)",
                         c.name as NSString, tail, r.text.replacingOccurrences(of: "\n", with: "⏎"), r.probability,
                         r.firstWordProbability, r.fragmentProbability, r.milliseconds, r.stopReason, r.kind.rawValue))
        } else {
            print(String(format: "· %-26@ …%@ ⟨—⟩", c.name as NSString, tail))
        }
        print("    expect: \(c.expect)")
        if trace { print(engine.lastTrace) }
    }
    print(String(format: "latency p50 %.0fms p95 %.0fms", percentile(times, 0.5), percentile(times, 0.95)))

case "sim":
    _ = try? engine.completeNow(CompletionRequest(context: "", prefix: "Hello there, how are", options: options))
    // `--docs`: a JSON corpus instead of the built-in documents; `--log`: one JSON line per suggestion shown.
    var documents = simDocuments.enumerated().map { (id: "builtin-\($0.offset)", genre: "builtin", doc: $0.element) }
    if let path = flag("--docs") {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        documents = try JSONDecoder().decode([CorpusDocument].self, from: data).map { ($0.id, $0.genre, $0.simDocument) }
    }
    let log: FileHandle? = flag("--log").flatMap { path in
        FileManager.default.createFile(atPath: path, contents: nil)
        return FileHandle(forWritingAtPath: path)
    }
    func write(_ object: [String: Any]) {
        guard let log, let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return }
        log.write(data + Data("\n".utf8))
    }
    var totalChars = 0, keystrokes = 0, shown = 0, correct = 0, wrong = 0, savedChars = 0, full = 0, wrongChars = 0
    var shownWords = 0.0, multiWord = 0, firstWordRight = 0
    var latencies: [Double] = []
    for (docID, genre, doc) in documents {
        let header: String
        switch flag("--header") {
        case "none": header = ""
        case "alt": header = altHeader(doc.context)
        default: header = PromptBuilder.header(for: doc.context)
        }
        let chars = Array(doc.text)
        totalChars += chars.count
        var i = 0
        var needsKey = true
        while i < chars.count {
            let chained = !needsKey
            if needsKey {
                i += 1
                keystrokes += 1
            }
            needsKey = true
            let prefix = String(chars[..<i])
            let truth = String(chars[i...])
            let start = DispatchTime.now()
            var request = CompletionRequest(context: header, prefix: prefix, options: options)
            request.afterAcceptance = chained
            let result = try engine.completeNow(request)
            latencies.append(Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1e6)
            guard let r = result else { continue }
            if checksWords, wordChecker.breaksWord(prefix: prefix, suggestion: r.text, context: header) { continue }
            shown += 1
            let (accepted, presses) = acceptedLength(suggestion: r.text, truth: truth)
            write(["doc": docID, "genre": genre, "at": i, "prefix": String(prefix.suffix(160)), "suggestion": r.text,
                   "truth": String(truth.prefix(80)), "accepted": accepted, "full": truth.hasPrefix(r.text),
                   "p": r.probability, "first": r.firstWordProbability, "frag": r.fragmentProbability,
                   "ms": r.milliseconds, "stop": r.stopReason, "kind": r.kind.rawValue,
                   "midWord": TextAnalysis.split(prefix).isMidWord])
            if truth.hasPrefix(r.text) { full += 1 }
            let words = TextAnalysis.wordCount(r.text)
            shownWords += words
            if words >= 2 { multiWord += 1 }
            wrongChars += max(0, r.text.count - accepted)
            if accepted > 0 {
                correct += 1
                savedChars += accepted
                keystrokes += presses
                i += accepted
                if chains, accepted == r.text.count, i < chars.count { needsKey = false }
                if verbose { print("  ✓ …\(prefix.suffix(40).replacingOccurrences(of: "\n", with: "⏎"))⟨\(r.text)⟩ +\(accepted)") }
            } else {
                wrong += 1
                if verbose {
                    print(String(format: "  ✗ …%@⟨%@⟩ truth:%@ p=%.2f f=%.2f", String(prefix.suffix(40)).replacingOccurrences(of: "\n", with: "⏎"), r.text,
                                 String(truth.prefix(25)).replacingOccurrences(of: "\n", with: "⏎"), r.probability, r.firstWordProbability))
                    print(engine.lastTrace)
                }
            }
        }
    }
    let savings = Double(totalChars - keystrokes) / Double(totalChars) * 100
    print(String(format: "chars %d  keystrokes %d  saved %.1f%%  shown %d (%.1f/100 keys)  precision %.1f%%  exact %.1f%%  wrong %d  noise %.2f chars/key",
                 totalChars, keystrokes, savings, shown, Double(shown) / Double(keystrokes) * 100,
                 Double(correct) / Double(max(shown, 1)) * 100, Double(full) / Double(max(shown, 1)) * 100, wrong,
                 Double(wrongChars) / Double(keystrokes)))
    print(String(format: "avg %.1f words per suggestion, %.0f%% multi-word", shownWords / Double(max(shown, 1)),
                 Double(multiWord) / Double(max(shown, 1)) * 100))
    print(String(format: "latency p50 %.1fms p90 %.1fms p99 %.1fms max %.1fms", percentile(latencies, 0.5),
                 percentile(latencies, 0.9), percentile(latencies, 0.99), latencies.max() ?? 0))

case "verify":
    // Cached decoding must match decoding from scratch, keystroke by keystroke (incl. backspaces).
    let fresh = try CompletionEngine(modelPath: modelPath)
    var mismatches = 0, checks = 0
    var maxDelta = 0.0
    for doc in simDocuments.prefix(3) {
        let header = PromptBuilder.header(for: doc.context)
        let chars = Array(doc.text)
        var i = 0
        var step = 0
        while i < chars.count {
            step += 1
            // Every 37th step, backspace 9 characters to exercise checkpoint restore.
            if step % 37 == 0 && i > 12 { i -= 9 } else { i += 1 }
            let prefix = String(chars[..<i])
            let request = CompletionRequest(context: header, prefix: prefix, options: options)
            let a = try engine.completeNow(request)
            fresh.resetCache()
            let b = try fresh.completeNow(request)
            checks += 1
            if a?.text != b?.text {
                mismatches += 1
                print("  mismatch at …\(prefix.suffix(30)): cached=\(a?.text ?? "nil") fresh=\(b?.text ?? "nil")")
            } else if let a, let b {
                maxDelta = max(maxDelta, abs(a.probability - b.probability))
            }
        }
    }
    print("verify: \(checks) checks, \(mismatches) text mismatches, max probability delta \(String(format: "%.4f", maxDelta))")

case "bench":
    let speeds = engine.measureThroughput()
    print(String(format: "prompt processing %.0f tok/s, generation %.0f tok/s (%.1f ms/token)", speeds.prompt, speeds.generation, 1000 / speeds.generation))
    let header = PromptBuilder.header(for: simDocuments[2].context)
    let text = simDocuments[2].text
    var cold: [Double] = []
    for _ in 0..<3 {
        let r = try engine.completeNow(CompletionRequest(context: header + String(repeating: " ", count: cold.count), prefix: text, options: options))
        cold.append(r?.milliseconds ?? -1)
    }
    print("cold prompt (\(text.count) chars): \(cold.map { String(format: "%.0fms", $0) })")
    var warm: [Double] = []
    var prefix = String(text.prefix(200))
    for ch in text.dropFirst(200).prefix(120) {
        prefix.append(ch)
        let start = DispatchTime.now()
        _ = try engine.completeNow(CompletionRequest(context: header, prefix: prefix, options: options))
        warm.append(Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1e6)
    }
    print(String(format: "per-keystroke p50 %.1fms p90 %.1fms max %.1fms", percentile(warm, 0.5), percentile(warm, 0.9), warm.max() ?? 0))

default:
    print("unknown command \(command)")
}

/// Experimental lighter header: reads like the top of a document rather than a form.
func altHeader(_ c: WritingContext) -> String {
    var parts: [String] = []
    if let about = c.aboutUser { parts.append("(About me: \(about))") }
    let place = [c.appName, c.website, c.windowTitle].compactMap { $0 }.joined(separator: " — ")
    if !place.isEmpty { parts.append("[\(place)]") }
    if let screen = c.screenText { parts.append(screen) }
    if let copied = c.clipboard { parts.append("(Copied: \(copied))") }
    guard !parts.isEmpty else { return "" }
    return parts.joined(separator: "\n\n") + "\n\n---\n\n"
}

/// How much of `suggestion` a user would accept given what they actually typed next, and how many
/// key presses that takes (one Tab for the whole suggestion, otherwise one per accepted word).
func acceptedLength(suggestion: String, truth: String) -> (Int, Int) {
    let s = Array(suggestion), t = Array(truth)
    var n = 0
    while n < s.count, n < t.count, s[n] == t[n] { n += 1 }
    if n == s.count { return (n, 1) }
    // Back off to a word boundary inside the suggestion.
    var k = n
    while k > 0, !(s[k].isWhitespace || (s[k].isPunctuation && s[k] != "'")) { k -= 1 }
    if k == 0 { return (0, 0) }
    let words = String(s[..<k]).split(whereSeparator: { $0.isWhitespace }).count
    return (k, max(1, words))
}

// Skip static destructors: ggml-metal asserts if the device is torn down while buffers are alive.
fflush(stdout)
_exit(0)

/// A document of a corpus file for `sim --docs`.
struct CorpusDocument: Decodable {
    var id: String
    var genre: String
    var app: String?
    var title: String?
    var website: String?
    var field: String?
    var screen: String?
    var about: String?
    var clipboard: String?
    var text: String

    var simDocument: SimDocument {
        SimDocument(context: WritingContext(appName: app, windowTitle: title, website: website, fieldLabel: field,
                                            screenText: screen, aboutUser: about, clipboard: clipboard), text: text)
    }
}
