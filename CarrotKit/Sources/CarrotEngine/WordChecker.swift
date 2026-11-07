#if canImport(AppKit)
import AppKit
import NaturalLanguage

/// Catches suggestions that finish the word under the caret into something that isn't a word
/// ("whos" + "pends", "withou" + "th"), using the system spell checker. Call it from the main thread.
///
/// It errs towards letting words through: a word counts as real if any likely language knows it
/// (English, the user's languages, the text's language when that is clear), and names,
/// contractions and words already on screen are never questioned.
public final class WordChecker: @unchecked Sendable {
    private let checker = NSSpellChecker.shared
    private let tag = NSSpellChecker.uniqueSpellDocumentTag()
    private lazy var baseLanguages: [String] = {
        var codes = ["en", "en_GB"]
        for preferred in Locale.preferredLanguages {
            let code = preferred.replacingOccurrences(of: "-", with: "_")
            if let match = checker.availableLanguages.first(where: { $0 == code || $0 == String(code.prefix(2)) }) {
                codes.append(match)
            }
        }
        return codes
    }()

    public init() {}

    /// Whether `suggestion` would turn the partial word at the end of `prefix` into something no
    /// likely language knows and that isn't already in the text or on screen (`context`).
    public func breaksWord(prefix: String, suggestion: String, context: String = "") -> Bool {
        guard let word = TextAnalysis.completedWord(prefix: prefix, suggestion: suggestion) else { return false }
        // Names ("Okafor", "Fushimi") are often missing from dictionaries.
        if word.first?.isUppercase == true { return false }
        // A contraction on its way ("didn" + "'t").
        let lead = suggestion.prefix { $0.isLetter }
        if let next = suggestion.dropFirst(lead.count).first, next == "'" || next == "’" { return false }
        // Words the writer already used, or that are on screen, are intentional.
        let earlier = prefix.dropLast(TextAnalysis.split(prefix).partialWord.count)
        if earlier.range(of: word, options: [.caseInsensitive, .diacriticInsensitive]) != nil { return false }
        if context.range(of: word, options: [.caseInsensitive, .diacriticInsensitive]) != nil { return false }
        let languages = baseLanguages + likelyLanguages(of: prefix)
        for language in languages where isWord(word, in: language) || isWord(word.capitalized, in: language) {
            return false
        }
        return true
    }

    private func isWord(_ word: String, in language: String) -> Bool {
        checker.checkSpelling(of: word, startingAt: 0, language: language, wrap: false,
                              inSpellDocumentWithTag: tag, wordCount: nil).location == NSNotFound
    }

    /// The languages the text might be in (short texts are ambiguous: all plausible ones count),
    /// as far as the spell checker knows them.
    private func likelyLanguages(of prefix: String) -> [String] {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(String(prefix.suffix(400)))
        return recognizer.languageHypotheses(withMaximum: 3).filter { $0.value >= 0.05 }.compactMap { language, _ in
            let code = language.rawValue
            return checker.availableLanguages.first { $0 == code || $0.hasPrefix(code + "_") }
        }
    }
}
#endif
