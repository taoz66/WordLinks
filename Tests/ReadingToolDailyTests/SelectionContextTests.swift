import Foundation
import XCTest
@testable import ReadingToolDaily

final class SelectionContextTests: XCTestCase {
    func testMiddleSelectionIncludesOnlyPreviousCurrentAndNextSentences() throws {
        let text = "Ignore this sentence. The previous sentence helps. This word has a special meaning. The next sentence helps too. Leave this sentence out."
        let result = try extract("special", from: text)

        XCTAssertEqual(result.selectedText, "special")
        XCTAssertEqual(result.focusedSentence, "This word has a special meaning.")
        XCTAssertEqual(result.context, "The previous sentence helps. This word has a special meaning. The next sentence helps too.")
    }

    func testSelectionAcrossSentencesKeepsBothAndTheirNeighbours() throws {
        let text = "Earlier history. The river changed course. Local people moved away. A new town grew. Later history."
        let result = try extract("changed course. Local people", from: text)

        XCTAssertEqual(result.focusedSentence, "The river changed course. Local people moved away.")
        XCTAssertEqual(result.context, "Earlier history. The river changed course. Local people moved away. A new town grew.")
        XCTAssertEqual(result.translationContext, "Earlier history. A new town grew.")
        XCTAssertEqual(result.selectedSentenceCount, 2)
        XCTAssertEqual(result.askAIPurpose, .translation)
    }

    func testWholeParagraphTranslationContextUsesAdjacentParagraphSentences() throws {
        let text = "Previous paragraph ends here.\n\nFirst selected sentence. Second selected sentence.\n\nNext paragraph starts here."
        let result = try extract("First selected sentence. Second selected sentence.", from: text)

        XCTAssertEqual(result.translationContext, "Previous paragraph ends here. Next paragraph starts here.")
        XCTAssertEqual(result.selectedSentenceCount, 2)
        XCTAssertEqual(result.askAIPurpose, .translation)
    }

    func testAskAIPurposeKeepsShortPhrasesForLookupAndRoutesLongSelectionsToTranslation() throws {
        let text = "She tried to give someone a run for their money. \(String(repeating: "A useful passage without punctuation ", count: 3)) continues here."
        XCTAssertEqual(try extract("give someone a run for their money", from: text).askAIPurpose, .lookup)
        XCTAssertEqual(try extract(String(repeating: "A useful passage without punctuation ", count: 3), from: text).askAIPurpose,
                       .translation)

        let chineseText = "前一句。\(String(repeating: "這是一段很長的中文选区内容", count: 3))后一句。"
        let chineseSelection = String(repeating: "這是一段很長的中文选区内容", count: 3)
        XCTAssertEqual(try extract(chineseSelection, from: chineseText).askAIPurpose, .translation)
    }

    func testCompleteShortSentenceUsesTranslationWhileSingleWordUsesLookup() throws {
        let text = "She sat on the bank. The river was quiet."
        XCTAssertEqual(try extract("She sat on the bank", from: text).askAIPurpose, .translation)
        XCTAssertEqual(try extract("bank", from: text).askAIPurpose, .lookup)
    }

    func testArticleEdgesDoNotInventMissingSentences() throws {
        let text = "First sentence. Middle sentence. Final sentence."
        XCTAssertEqual(try extract("First", from: text).context, "First sentence. Middle sentence.")
        XCTAssertEqual(try extract("Final", from: text).context, "Middle sentence. Final sentence.")
        XCTAssertEqual(try extract("Only", from: "Only one sentence.").context, "Only one sentence.")
    }

    func testTitleAndSeparateParagraphMarkersAreExcluded() throws {
        let text = "A title with a question?\n\nA\n\nThe opening sentence. The focus is here.\n\nB\n\nAnother paragraph begins. Its next sentence follows."
        let result = try extract("focus", from: text, title: "A title with a question?")

        XCTAssertEqual(result.context, "The opening sentence. The focus is here. Another paragraph begins.")
        XCTAssertEqual(result.focusedSentence, "The focus is here.")
    }

    func testInlineIELTSParagraphLabelsAreExcluded() throws {
        let text = "IELTS title\n\nA The opening sentence. The focus is here.\n\nB Another paragraph begins. Its next sentence follows."
        let result = try extract("focus", from: text, title: "IELTS title")

        XCTAssertEqual(result.context, "The opening sentence. The focus is here. Another paragraph begins.")
        XCTAssertEqual(try extract("opening", from: text, title: "IELTS title").focusedSentence,
                       "The opening sentence.")
    }

    func testAbbreviationsInitialsAndDecimalNumbersRemainWithinTheSentence() throws {
        let text = "An earlier event occurred. Dr. J. Smith measured 3.14 metres in the U.S. laboratory. The result was useful. Another event followed."
        let result = try extract("metres", from: text)

        XCTAssertEqual(result.focusedSentence, "Dr. J. Smith measured 3.14 metres in the U.S. laboratory.")
        XCTAssertEqual(result.context, "An earlier event occurred. Dr. J. Smith measured 3.14 metres in the U.S. laboratory. The result was useful.")
    }

    func testMultipleInitialsMergeButAnAcronymCanStillEndASentence() throws {
        let text = "An earlier event occurred. Prof. A. B. Jones works in a U.S. laboratory. The final sentence follows. A later event occurred."
        let result = try extract("laboratory", from: text)
        XCTAssertEqual(result.focusedSentence, "Prof. A. B. Jones works in a U.S. laboratory.")
        XCTAssertEqual(result.context, "An earlier event occurred. Prof. A. B. Jones works in a U.S. laboratory. The final sentence follows.")

        let finalAcronym = "An earlier sentence. She moved to the U.S. The next sentence follows. A later sentence."
        XCTAssertEqual(try extract("moved", from: finalAcronym).focusedSentence, "She moved to the U.S.")
    }

    func testEmojiAccentsAndCJKUseUTF16SelectionOffsets() throws {
        let text = "A café opened 🌳. Its façade was beautiful. Visitors enjoyed it."
        let result = try extract("façade", from: text)
        XCTAssertEqual(result.context, text)
        XCTAssertEqual(result.selectedText, "façade")

        let chinese = "前一句。这个词有特殊含义。后一句。再后一句。"
        XCTAssertEqual(try extract("特殊", from: chinese).context, "前一句。 这个词有特殊含义。 后一句。")
    }

    func testSelectionWhitespaceIsTrimmed() throws {
        let result = try extract(" special ", from: "This special word has a meaning.")
        XCTAssertEqual(result.selectedText, "special")
        XCTAssertEqual(result.focusedSentence, "This special word has a meaning.")
    }

    func testParagraphWithoutFinalPunctuationRemainsAvailable() throws {
        let text = "An opening sentence.\n\nA paragraph without final punctuation\n\nThe following paragraph."
        let result = try extract("without", from: text)
        XCTAssertEqual(result.focusedSentence, "A paragraph without final punctuation")
        XCTAssertEqual(result.context, "An opening sentence. A paragraph without final punctuation The following paragraph.")
    }

    func testInvalidRangesAndWhitespaceSelectionsReportChineseErrors() {
        let text = "First 🌳 sentence."
        for range in [NSRange(location: NSNotFound, length: 1), NSRange(location: -1, length: 1),
                      NSRange(location: 0, length: 0), NSRange(location: 0, length: 100),
                      NSRange(location: 7, length: 1), NSRange(location: Int.max, length: Int.max)] {
            XCTAssertThrowsError(try SelectionContext.extract(from: text, range: range)) {
                XCTAssertEqual($0.localizedDescription, "选中的文字位置无效，请重新选择一个词或词组。")
            }
        }
        XCTAssertThrowsError(try extract(" ", from: text)) {
            XCTAssertEqual($0.localizedDescription, "请先选中一个词或词组。")
        }
        XCTAssertThrowsError(try extract(".", from: text)) {
            XCTAssertEqual($0.localizedDescription, "请先选中一个词或词组。")
        }
    }

    func testPartialCombiningCharactersAndEmojiSequencesAreRejected() {
        let text = "A cafe\u{301} and a 👨‍👩‍👧‍👦 family."
        let source = text as NSString
        let accent = source.range(of: "e\u{301}")
        let family = source.range(of: "👨‍👩‍👧‍👦")
        for range in [NSRange(location: accent.location, length: 1),
                      NSRange(location: accent.location + 1, length: 1),
                      NSRange(location: family.location, length: 2)] {
            XCTAssertThrowsError(try SelectionContext.extract(from: text, range: range)) {
                XCTAssertEqual($0.localizedDescription, "选中的文字位置无效，请重新选择一个词或词组。")
            }
        }
    }

    func testTitleAndParagraphLabelSelectionsDoNotBecomeBodyContext() {
        let text = "The title\n\nA\n\nThe body is here."
        XCTAssertThrowsError(try extract("title", from: text, title: "The title")) {
            XCTAssertEqual($0.localizedDescription, "请选中文章正文中的词或词组。")
        }
        XCTAssertThrowsError(try extract("A", from: text, title: "The title")) {
            XCTAssertEqual($0.localizedDescription, "请选中文章正文中的词或词组。")
        }
    }

    private func extract(_ selection: String, from text: String, title: String? = nil) throws -> SelectionContext {
        try SelectionContext.extract(from: text, range: (text as NSString).range(of: selection), articleTitle: title)
    }
}
