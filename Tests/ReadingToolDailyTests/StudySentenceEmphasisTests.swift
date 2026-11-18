import Foundation
import XCTest
@testable import ReadingToolDaily

final class StudySentenceEmphasisTests: XCTestCase {
    func testEmphasizesSavedInflectionRatherThanEditedExpression() {
        let sentence = "The forests contracted toward the coast, while the contract stayed unchanged."
        let card = card(selection: "contracted", expression: "contract")
        XCTAssertEqual(emphasized(in: sentence, card: card), ["contracted"])
    }

    func testSourceAnchorSelectsTheCorrectRepeatedOccurrenceWithUnicodeOffsets() throws {
        let sentence = "A café 🙂 can form a form before formation."
        let article = article(text: "Notes\n\n" + sentence)
        let selected = try XCTUnwrap(article.text.range(of: "form before"))
        let selectionEnd = article.text.index(selected.lowerBound, offsetBy: 4)
        let card = StudyCard(articleID: article.id,
                             start: article.text[..<selected.lowerBound].unicodeScalars.count,
                             end: article.text[..<selectionEnd].unicodeScalars.count,
                             selectedText: "form", expression: "form", meaning: "形态")
        let ranges = StudySentenceEmphasis.ranges(in: sentence, for: card, article: article)
        XCTAssertEqual(ranges.count, 1)
        let range = try XCTUnwrap(ranges.first)
        XCTAssertEqual(String(sentence[range]), "form")
        XCTAssertEqual(String(sentence[..<range.lowerBound]), "A café 🙂 can form a ")
    }

    func testDetachedSnapshotsMatchLiteralWordsWithoutMatchingLongerWordRoots() {
        var card = card(selection: "form")
        card.isDetached = true
        XCTAssertEqual(emphasized(in: "A form and another form precede formation.", card: card), ["form", "form"])
        XCTAssertEqual(emphasized(in: "Only formation remains.", card: card), [])
    }

    func testSelectionAcrossSentenceWhitespaceAndRegexCharactersRemainLiteral() {
        let sentence = "They used C++ (v2). Local people agreed."
        let card = card(selection: "C++ (v2).\n\nLocal people")
        XCTAssertEqual(emphasized(in: sentence, card: card), ["C++ (v2). Local people"])
        XCTAssertEqual(emphasized(in: "A café 🙂 opened here.", card: self.card(selection: "café 🙂")), ["café 🙂"])
    }

    func testChangedSourceDoesNotApplyAnUnrelatedAnchorOrInventAMatch() {
        let source = article(text: "A different form appears here.")
        let card = StudyCard(articleID: source.id, start: 0, end: 4,
                             selectedText: "form", expression: "formation", meaning: "形态")
        XCTAssertEqual(emphasized(in: "The saved form remains.", card: card, article: source), ["form"])
        XCTAssertEqual(emphasized(in: "The saved sentence remains.", card: card, article: source), [])
    }

    private func card(selection: String, expression: String? = nil) -> StudyCard {
        StudyCard(articleID: UUID(), start: 0, end: selection.unicodeScalars.count,
                  selectedText: selection, expression: expression ?? selection, meaning: "释义")
    }

    private func article(text: String) -> LibraryArticle {
        LibraryArticle(title: "Notes", sourceName: "notes.md", markdown: "# Notes\n\n" + text, text: text)
    }

    private func emphasized(in sentence: String, card: StudyCard, article: LibraryArticle? = nil) -> [String] {
        StudySentenceEmphasis.ranges(in: sentence, for: card, article: article).map { String(sentence[$0]) }
    }
}
