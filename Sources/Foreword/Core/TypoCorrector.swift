import AppKit
import ForewordEngine
import NaturalLanguage

/// Finds a misspelling in the word the user just finished and proposes a fix. The system spell
/// checker supplies candidates; the language model picks the one that fits the sentence.
@MainActor
final class TypoCorrector {
    struct Correction: Equatable {
        /// The misspelled word.
        let original: String
        let replacement: String
        /// UTF-16 offset (in the full text) where the word starts.
        let wordStart: Int
        /// Characters between the end of the word and the caret ("" or " " or ", ").
        let trailing: String
        /// The prefix this correction was computed for.
        let prefix: String
    }

    private let checker = NSSpellChecker.shared
    private let documentTag = NSSpellChecker.uniqueSpellDocumentTag()
    private var ignored = Set<String>()

    func ignore(_ word: String) {
        ignored.insert(word.lowercased())
        checker.ignoreWord(word, inSpellDocumentWithTag: documentTag)
    }

    /// Checks the word right before the caret when the caret follows a word boundary.
    func candidate(in snapshot: FieldSnapshot) -> (word: String, start: Int, trailing: String, before: String)? {
        let prefix = snapshot.prefix
        guard let last = prefix.last, last == " " || ",.;:!?)".contains(last) else { return nil }
        // trailing = boundary characters after the word (at most 2).
        var trailing = ""
        var index = prefix.endIndex
        while index > prefix.startIndex {
            let previous = prefix.index(before: index)
            let ch = prefix[previous]
            if ch == " " || ",.;:!?)".contains(ch) { trailing.insert(ch, at: trailing.startIndex); index = previous } else { break }
            if trailing.count > 2 { return nil }
        }
        var wordStart = index
        while wordStart > prefix.startIndex {
            let previous = prefix.index(before: wordStart)
            let ch = prefix[previous]
            if ch.isLetter || ch == "'" || ch == "’" { wordStart = previous } else { break }
        }
        let word = String(prefix[wordStart..<index])
        guard word.count >= 3, word.count <= 24, word.allSatisfy({ $0.isLetter || $0 == "'" || $0 == "’" }) else { return nil }
        // The character before the word must be a separator (not part of a URL, handle, path…).
        if wordStart > prefix.startIndex {
            let before = prefix[prefix.index(before: wordStart)]
            if !(before.isWhitespace || "\"'“‘([-—".contains(before)) { return nil }
        }
        // Proper nouns and acronyms are left alone.
        if word.first!.isUppercase {
            let beforeWord = prefix[..<wordStart].trimmingCharacters(in: .whitespaces)
            let sentenceStart = beforeWord.isEmpty || ".!?\n".contains(beforeWord.last!)
            if !sentenceStart || word.dropFirst().contains(where: \.isUppercase) { return nil }
        }
        if ignored.contains(word.lowercased()) { return nil }
        let utf16Offset = snapshot.selection.location - String(prefix[wordStart...]).utf16.count
        return (word, utf16Offset, trailing, String(prefix[..<wordStart]))
    }

    /// Returns a correction if the candidate word is misspelled. Uses the engine (if given) to rank
    /// the spell checker's guesses in context.
    func correction(for snapshot: FieldSnapshot, engine: CompletionEngine?, header: String) async -> Correction? {
        guard let candidate = candidate(in: snapshot) else { return nil }
        let word = candidate.word
        let language = detectLanguage(snapshot.prefix)
        let misspelled = checker.checkSpelling(of: word, startingAt: 0, language: language, wrap: false,
                                               inSpellDocumentWithTag: documentTag, wordCount: nil)
        guard misspelled.location != NSNotFound else { return nil }
        // Words the user has already used elsewhere in this text are intentional.
        let occurrences = snapshot.prefix.components(separatedBy: word).count - 1 + (snapshot.suffix.contains(word) ? 1 : 0)
        if occurrences > 1 { return nil }

        let range = NSRange(location: 0, length: (word as NSString).length)
        var guesses = checker.guesses(forWordRange: range, in: word, language: language, inSpellDocumentWithTag: documentTag) ?? []
        if let auto = checker.correction(forWordRange: range, in: word, language: language ?? "en", inSpellDocumentWithTag: documentTag) {
            guesses.removeAll { $0 == auto }
            guesses.insert(auto, at: 0)
        }
        guesses = Array(guesses.filter { !$0.contains(" ") || word.count > 6 }.prefix(5))
        guard !guesses.isEmpty else { return nil }

        var best = guesses[0]
        if guesses.count > 1, let engine {
            // Score " guess" after the text that precedes the word (space folded into the guess,
            // matching how the tokenizer sees words).
            let before = candidate.before
            let endsWithSpace = before.last?.isWhitespace ?? false
            let stable = endsWithSpace ? String(before.dropLast()) : before
            let options = guesses.map { (endsWithSpace ? " " : "") + matchCase($0, to: word) }
            let scores = await Task.detached(priority: .userInitiated) {
                engine.score(context: header, prefix: stable, candidates: options)
            }.value
            if let top = zip(guesses, scores).max(by: { $0.1 < $1.1 }) { best = top.0 }
        }
        let replacement = matchCase(best, to: word)
        guard replacement != word else { return nil }
        return Correction(original: word, replacement: replacement, wordStart: candidate.start,
                          trailing: candidate.trailing, prefix: snapshot.prefix)
    }

    private func matchCase(_ guess: String, to word: String) -> String {
        if word == word.uppercased() && word.count > 1 { return guess.uppercased() }
        if word.first?.isUppercase == true { return guess.prefix(1).uppercased() + guess.dropFirst() }
        return guess
    }

    private func detectLanguage(_ text: String) -> String? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(String(text.suffix(400)))
        guard let language = recognizer.dominantLanguage else { return nil }
        let code = language.rawValue
        return checker.availableLanguages.contains(where: { $0.hasPrefix(code) }) ? code : nil
    }
}
