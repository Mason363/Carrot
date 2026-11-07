import XCTest
@testable import CarrotEngine

final class PromptBuilderTests: XCTestCase {
    func testOtherWindowsComeBeforeTheWritingWindow() {
        var context = WritingContext()
        context.screenText = "Reply to Sam"
        context.otherWindows = [.init(title: "Zen — Model O Mice", text: "Model O3 Wireless Mouse\n$99.99")]
        let header = PromptBuilder.header(for: context)
        let other = header.range(of: "Also on screen (Zen — Model O Mice):")
        let own = header.range(of: "On screen:\n")
        XCTAssertNotNil(other)
        XCTAssertNotNil(own)
        XCTAssertLessThan(other!.lowerBound, own!.lowerBound)
        XCTAssertTrue(header.contains("Model O3 Wireless Mouse\n$99.99"))
        XCTAssertTrue(header.hasSuffix("Text being written:\n"))
    }

    func testOtherWindowsShareOneBudget() {
        var context = WritingContext()
        let long = String(repeating: "word ", count: 600)
        context.otherWindows = [.init(title: "A", text: long), .init(title: "B", text: long), .init(title: "C", text: long)]
        let header = PromptBuilder.header(for: context)
        XCTAssertLessThan(header.count, PromptBuilder.otherWindowsBudget + 200)
        XCTAssertTrue(header.contains("Also on screen (A):"))
    }

    func testNoOtherWindowsNoSection() {
        XCTAssertFalse(PromptBuilder.header(for: WritingContext(windowTitle: "Notes")).contains("Also on screen"))
    }
}
