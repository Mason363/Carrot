import Foundation

/// Splits the text before the cursor into a stable part and the trailing fragment the user is in
/// the middle of typing. The fragment is removed from the prompt and re-imposed on generation as a
/// byte constraint ("token healing"), so the model sees a natural tokenisation and can complete
/// partial words (`"the docu"` → `"ment"`) and handle trailing spaces correctly.
public struct PrefixSplit: Equatable, Sendable {
    public var stable: String
    public var fragment: String
    /// The user is inside a word (the fragment contains word characters).
    public var isMidWord: Bool
    /// The trailing word looks like something we should not complete (URL, path, hash…).
    public var isSuspicious: Bool
    /// The fragment's word characters (without leading whitespace).
    public var partialWord: String { String(fragment.drop(while: { $0 == " " || $0 == "\t" })) }
}

public enum TextAnalysis {
    static let maxFragmentWordLength = 32

    public static func split(_ prefix: String) -> PrefixSplit {
        let scalars = Array(prefix.unicodeScalars)
        var i = scalars.count
        var wordLength = 0

        // A single trailing CJK character is its own "word".
        if i > 0, isCJK(scalars[i - 1]) {
            i -= 1
            let stable = String(String.UnicodeScalarView(scalars[0..<i]))
            let fragment = String(String.UnicodeScalarView(scalars[i...]))
            return PrefixSplit(stable: stable, fragment: fragment, isMidWord: true, isSuspicious: false)
        }

        // A trailing joiner right after a word ("don'", "well-") is part of that word.
        if i > 1, isJoiner(scalars[i - 1]), isWordScalar(scalars[i - 2]) {
            i -= 1
            wordLength += 1
        }
        while i > 0, isWordScalar(scalars[i - 1]) {
            i -= 1
            wordLength += 1
        }
        // Allow an internal apostrophe / hyphen only when followed by letters we already consumed.
        while i > 1, wordLength > 0, isJoiner(scalars[i - 1]), isWordScalar(scalars[i - 2]) {
            i -= 1
            while i > 0, isWordScalar(scalars[i - 1]) { i -= 1; wordLength += 1 }
        }
        var suspicious = wordLength > maxFragmentWordLength
        // Characters immediately before the word that make it a URL / path / handle / code.
        if wordLength > 0, i > 0 {
            let before = scalars[i - 1]
            if "/\\@#_=<>{}[]|~`$%^&*+".unicodeScalars.contains(before) { suspicious = true }
            if before == ".", i > 1, isWordScalar(scalars[i - 2]) { suspicious = true } // "example.co"
        }
        // Horizontal whitespace before the word (or at the end) belongs to the fragment.
        while i > 0, scalars[i - 1] == " " || scalars[i - 1] == "\t" || scalars[i - 1] == "\u{00A0}" {
            i -= 1
        }
        let stable = String(String.UnicodeScalarView(scalars[0..<i]))
        let fragment = String(String.UnicodeScalarView(scalars[i...]))
        return PrefixSplit(stable: stable, fragment: fragment, isMidWord: wordLength > 0, isSuspicious: suspicious)
    }

    @inline(__always)
    static func isWordScalar(_ s: Unicode.Scalar) -> Bool {
        if s.properties.isAlphabetic { return !isCJK(s) }
        switch s.properties.generalCategory {
        case .decimalNumber, .nonspacingMark, .spacingMark, .enclosingMark, .connectorPunctuation:
            return s != "_"
        default:
            return false
        }
    }

    @inline(__always)
    static func isJoiner(_ s: Unicode.Scalar) -> Bool {
        s == "'" || s == "\u{2019}" || s == "-"
    }

    public static func isCJK(_ s: Unicode.Scalar) -> Bool {
        switch s.value {
        case 0x3040...0x30FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF,
             0x20000...0x2FA1F, 0xAC00...0xD7AF, 0x3000...0x303F, 0xFF00...0xFFEF:
            return true
        default:
            return false
        }
    }

    /// Sentence-ending punctuation (Latin and CJK).
    static func isSentenceEnd(_ c: Character) -> Bool {
        ".!?。！？…".contains(c)
    }

    static func isClauseEnd(_ c: Character) -> Bool {
        ",;:，；：、—".contains(c)
    }

    /// Counts words in a suggestion; CJK characters count as half a word each.
    public static func wordCount(_ text: String) -> Double {
        var words = 0.0
        var inWord = false
        for s in text.unicodeScalars {
            if isCJK(s) {
                words += 0.5
                inWord = false
            } else if isWordScalar(s) {
                if !inWord { words += 1; inWord = true }
            } else {
                inWord = false
            }
        }
        return words
    }

    /// Normalises text for fuzzy comparisons (case-folded, whitespace collapsed).
    public static func normalized(_ text: String) -> String {
        text.lowercased()
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }

    /// The part of `suffix` up to the end of its first line.
    public static func lineSuffix(_ suffix: String) -> Substring {
        if let nl = suffix.firstIndex(where: { $0 == "\n" || $0 == "\r" || $0 == "\u{2028}" || $0 == "\u{2029}" }) {
            return suffix[..<nl]
        }
        return suffix[...]
    }

    /// Closing characters that may sit right after the cursor without making the cursor "mid-line".
    static let closers: Set<Character> = [")", "]", "}", "\"", "'", "”", "’", "»", "›", "」", "』", "）", "】", "*", "_", "`"]

    /// Whether the text after the cursor on this line is only whitespace / closing punctuation.
    public static func isTrivialLineSuffix(_ lineSuffix: Substring) -> Bool {
        lineSuffix.allSatisfy { $0.isWhitespace || closers.contains($0) }
    }
}
