import XCTest
@testable import ForewordEngine

final class TextAnalysisTests: XCTestCase {
    func testSplitsPartialWord() {
        let split = TextAnalysis.split("I'll send you the docu")
        XCTAssertEqual(split.stable, "I'll send you the")
        XCTAssertEqual(split.fragment, " docu")
        XCTAssertTrue(split.isMidWord)
        XCTAssertEqual(split.partialWord, "docu")
    }

    func testTrailingSpaceIsFragment() {
        let split = TextAnalysis.split("Looking forward to ")
        XCTAssertEqual(split.stable, "Looking forward to")
        XCTAssertEqual(split.fragment, " ")
        XCTAssertFalse(split.isMidWord)
    }

    func testNewlineStaysInStablePart() {
        let split = TextAnalysis.split("Best regards,\n")
        XCTAssertEqual(split.stable, "Best regards,\n")
        XCTAssertEqual(split.fragment, "")
    }

    func testApostropheAndHyphenBelongToWord() {
        XCTAssertEqual(TextAnalysis.split("I don'").fragment, " don'")
        XCTAssertEqual(TextAnalysis.split("a well-kno").fragment, " well-kno")
    }

    func testURLsAndHandlesAreSuspicious() {
        XCTAssertTrue(TextAnalysis.split("check out https://github.com/ggml-or").isSuspicious)
        XCTAssertTrue(TextAnalysis.split("email me at mason@exam").isSuspicious)
        XCTAssertTrue(TextAnalysis.split("go to example.co").isSuspicious)
        XCTAssertFalse(TextAnalysis.split("I think so").isSuspicious)
    }

    func testCJKCharacterIsOwnFragment() {
        let split = TextAnalysis.split("我们今天去图书馆")
        XCTAssertEqual(split.fragment, "馆")
        XCTAssertTrue(split.isMidWord)
    }

    func testLineSuffixAndTrivialSuffix() {
        XCTAssertEqual(TextAnalysis.lineSuffix(" store today.\nNext line"), " store today.")
        XCTAssertTrue(TextAnalysis.isTrivialLineSuffix("\")"))
        XCTAssertTrue(TextAnalysis.isTrivialLineSuffix("  "))
        XCTAssertFalse(TextAnalysis.isTrivialLineSuffix(" the store"))
    }

    func testWordCount() {
        XCTAssertEqual(TextAnalysis.wordCount(" minutes late"), 2)
        XCTAssertEqual(TextAnalysis.wordCount("学习"), 1)
    }
}

final class WordEndTests: XCTestCase {
    private func end(_ text: String, at index: Int, complete: Bool = true) -> Bool {
        CompletionEngine.isWordEnd(output: Array(text.utf8), at: index, outputComplete: complete)
    }

    func testSpaceEndsWord() {
        XCTAssertTrue(end("minutes late", at: 7))
    }

    func testSentencePunctuationThenSpaceEndsWord() {
        XCTAssertTrue(end("Thursday. Then", at: 8))
        XCTAssertTrue(end("Thursday.", at: 8))
    }

    func testIntraTokenPunctuationDoesNotEndWord() {
        XCTAssertFalse(end("figma.com/design", at: 5))   // before ".com"
        XCTAssertFalse(end("3.5 hours", at: 1))          // before ".5"
        XCTAssertFalse(end("10:30 tomorrow", at: 2))     // before ":30"
        XCTAssertFalse(end("don't know", at: 3))         // before "'t"
        XCTAssertFalse(end("mason@example.com", at: 5))  // before "@"
    }

    func testIncompleteOutputUsesFlag() {
        XCTAssertFalse(end("eat", at: 3, complete: false))
        XCTAssertTrue(end("eat", at: 3, complete: true))
    }
}
