import Foundation

/// How long suggestions may get.
public enum SuggestionLength: String, Codable, CaseIterable, Sendable {
    case short, medium, long

    var maxTokens: Int {
        switch self {
        case .short: return 8
        case .medium: return 16
        case .long: return 32
        }
    }

    var maxWords: Double {
        switch self {
        case .short: return 5
        case .medium: return 12
        case .long: return 26
        }
    }

    var maxSentences: Int {
        switch self {
        case .short, .medium: return 1
        case .long: return 2
        }
    }
}

/// Tunables for the decoder and the suggestion policy.
public struct CompletionOptions: Sendable, Equatable {
    public var length: SuggestionLength = .medium
    /// Probability the first word must reach for anything to be shown.
    public var minFirstWordProbability: Double = 0.36
    /// The suggestion grows word by word while its joint probability stays above this.
    public var minJointProbability: Double = 0.12
    /// Any single token below this probability ends the suggestion.
    public var minTokenProbability: Double = 0.11
    /// Single filler words ("the", "and"…) must be at least this likely to be shown on their own.
    public var minFillerProbability: Double = 0.70
    /// Finishing the word under the cursor is cheap to ignore, so it needs less certainty.
    public var minWordCompletionProbability: Double = 0.24
    /// Expected number of characters the user would accept; below this a suggestion isn't worth a glance.
    public var minExpectedCharacters: Double = 3.0
    /// Each word after the first must be at least this likely given the words before it.
    public var minExtensionProbability: Double = 0.5
    /// Allow suggestions when there is text after the cursor on the same line.
    public var allowMidLine = true
    /// Penalise verbatim repetition of the user's own text.
    public var repetitionGuard = true

    public init() {}

    /// Maps a 0…1 "eagerness" slider onto the thresholds (0 = conservative, 1 = eager).
    /// Tuned with `foreword-eval sim`: 0.5 keeps ~77% of shown suggestions right on the first word
    /// and ~70% right in full while saving ~46% of keystrokes on Qwen3.5 2B.
    public mutating func applyEagerness(_ eagerness: Double) {
        let e = min(max(eagerness, 0), 1)
        minFirstWordProbability = 0.50 - 0.28 * e        // 0.50 … 0.22
        minJointProbability = 0.18 - 0.12 * e            // 0.18 … 0.06
        minTokenProbability = 0.15 - 0.08 * e            // 0.15 … 0.07
        minExtensionProbability = 0.62 - 0.24 * e        // 0.62 … 0.38
        minWordCompletionProbability = 0.34 - 0.20 * e   // 0.34 … 0.14
        minExpectedCharacters = 4.0 - 2.0 * e            // 4.0 … 2.0
        minFillerProbability = 0.85 - 0.30 * e           // 0.85 … 0.55
    }
}

public struct CompletionRequest: Sendable {
    /// Prompt header: everything the model should know that is not the document itself.
    public var context: String
    /// Document text before the cursor.
    public var prefix: String
    /// Document text after the cursor.
    public var suffix: String
    public var options: CompletionOptions

    public init(context: String, prefix: String, suffix: String = "", options: CompletionOptions = .init()) {
        self.context = context
        self.prefix = prefix
        self.suffix = suffix
        self.options = options
    }
}

public struct Completion: Sendable, Equatable {
    public enum Kind: String, Sendable {
        /// Text to show after the cursor (end of line).
        case continuation
        /// Text to insert between the cursor and the rest of the line.
        case insertion
    }

    /// Text to insert at the cursor.
    public var text: String
    public var kind: Kind
    /// Joint probability of `text`.
    public var probability: Double
    /// Probability of the first word (or of finishing the current word).
    public var firstWordProbability: Double
    /// Probability the model assigned to the fragment the user is in the middle of typing.
    public var fragmentProbability: Double
    /// Prompt / reuse / generation statistics.
    public var promptTokens = 0
    public var reusedTokens = 0
    public var generatedTokens = 0
    public var milliseconds: Double = 0
    /// Why generation stopped (diagnostics).
    public var stopReason: String = ""
}
