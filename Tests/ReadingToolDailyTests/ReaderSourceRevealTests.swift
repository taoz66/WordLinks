import Foundation
import XCTest
@testable import ReadingToolDaily

final class ReaderSourceRevealTests: XCTestCase {
    func testLocatesTheAnchoredRepeatedWordAfterUnicodeText() throws {
        let article = article(text: "A café 🙂 can form a form before formation.")
        let selection = try XCTUnwrap(article.text.range(of: "form before"))
        let end = article.text.index(selection.lowerBound, offsetBy: 4)
        let card = StudyCard(articleID: article.id,
                             start: article.text[..<selection.lowerBound].unicodeScalars.count,
                             end: article.text[..<end].unicodeScalars.count,
                             selectedText: "form", expression: "formation", meaning: "形态")
        let range = try XCTUnwrap(ReaderSourceReveal(card: card).range(in: article))

        XCTAssertEqual(range, (article.text as NSString).range(of: "form", options: .backwards,
                       range: NSRange(location: 0, length: (article.text as NSString).range(of: " before").location)))
        XCTAssertEqual((article.text as NSString).substring(with: range), "form")
        XCTAssertEqual(range.location, ("A café 🙂 can form a " as NSString).length)
        XCTAssertNotEqual(range.location, card.start)
    }

    func testDoesNotRevealDetachedOrStaleAnchorsOrADifferentArticle() {
        let article = article(text: "The word is here.")
        let valid = card(article: article, start: 4, end: 8, selectedText: "word")
        XCTAssertNotNil(ReaderSourceReveal(card: valid).range(in: article))
        XCTAssertNil(ReaderSourceReveal(card: valid).range(in: self.article(text: article.text)))

        var detached = valid
        detached.isDetached = true
        XCTAssertNil(ReaderSourceReveal(card: detached).range(in: article))
        let stale = card(article: article, start: 4, end: 8, selectedText: "term")
        XCTAssertNil(ReaderSourceReveal(card: stale).range(in: article))
    }

    func testRejectsEmptyNegativeAndOutOfBoundsAnchors() {
        let article = article(text: "word")
        for (start, end) in [(-1, 3), (0, 0), (3, 2), (0, 5), (Int.max, Int.max)] {
            let invalid = card(article: article, start: start, end: end, selectedText: "word")
            XCTAssertNil(ReaderSourceReveal(card: invalid).range(in: article))
        }
    }

    func testEveryClickCreatesANewRevealRequestForTheSameCard() {
        let article = article(text: "word")
        let card = card(article: article, start: 0, end: 4, selectedText: "word")
        XCTAssertNotEqual(ReaderSourceReveal(card: card).id, ReaderSourceReveal(card: card).id)
    }

    func testCentersALineAndClampsNearBothArticleEnds() {
        XCTAssertEqual(scrollY(lineYs: [900]), 610)
        XCTAssertEqual(scrollY(lineYs: [20]), 0)
        XCTAssertEqual(scrollY(lineYs: [1940]), 1400)
        XCTAssertEqual(ReaderSourceReveal.centeredScrollY(
            lineRects: [NSRect(x: 0, y: 250, width: 500, height: 20)],
            documentHeight: 300, viewportHeight: 600), 0)
    }

    func testCentersAllSelectedLinesWhenTheyFitAndStartsLargeSelectionsAtTheirFirstLine() {
        let twoLines = [
            NSRect(x: 0, y: 800, width: 500, height: 20),
            NSRect(x: 0, y: 840, width: 500, height: 20)
        ]
        XCTAssertEqual(ReaderSourceReveal.centeredScrollY(
            lineRects: twoLines, documentHeight: 2000, viewportHeight: 600), 530)

        let manyParagraphs = (0..<20).map {
            NSRect(x: 0, y: 400 + CGFloat($0) * 40, width: 500, height: 20)
        }
        XCTAssertEqual(ReaderSourceReveal.centeredScrollY(
            lineRects: manyParagraphs, documentHeight: 2000, viewportHeight: 300), 260)
    }

    func testCollectsEveryWrappedLineAndParagraphLineForTheMarkedRange() throws {
        let text = "This marked selection wraps across several lines.\n\nA second paragraph stays part of the same marked selection."
        let storage = NSTextStorage(string: text, attributes: [.font: NSFont.systemFont(ofSize: 14)])
        let layoutManager = NSLayoutManager()
        let textContainer = NSTextContainer(size: NSSize(width: 150, height: CGFloat.greatestFiniteMagnitude))
        textContainer.lineFragmentPadding = 0
        storage.addLayoutManager(layoutManager)
        layoutManager.addTextContainer(textContainer)
        let range = NSRange(location: 0, length: (text as NSString).length)

        let lines = ReaderSourceReveal.lineRects(for: range, layoutManager: layoutManager,
                                                  textContainer: textContainer, origin: .zero)

        XCTAssertGreaterThanOrEqual(lines.count, 6)
        XCTAssertEqual(lines, lines.sorted { $0.minY < $1.minY })
        XCTAssertGreaterThan(lines.map { $0.minY }.max() ?? 0, lines.first?.minY ?? 0)
    }

    private func scrollY(lineYs: [CGFloat]) -> CGFloat {
        ReaderSourceReveal.centeredScrollY(
            lineRects: lineYs.map { NSRect(x: 32, y: $0, width: 500, height: 20) },
            documentHeight: 2000, viewportHeight: 600)
    }

    private func article(text: String) -> LibraryArticle {
        LibraryArticle(title: "Notes", sourceName: "notes.md", markdown: text, text: text)
    }

    private func card(article: LibraryArticle, start: Int, end: Int, selectedText: String) -> StudyCard {
        StudyCard(articleID: article.id, start: start, end: end, selectedText: selectedText,
                  expression: selectedText, meaning: "释义")
    }
}
