import Foundation
import XCTest
@testable import ReadingToolDaily

@MainActor
final class StudyCardSelectionTests: XCTestCase {
    func testExactSavedUnitIsRecognizedWithoutChangingItsUserFields() throws {
        let (store, article) = try fixture()
        defer { try? FileManager.default.removeItem(at: store.rootURL) }
        let range = (article.text as NSString).range(of: "beta")
        XCTAssertEqual(try store.cardSelectionStatus(articleID: article.id, range: range), .available)
        let card = try store.saveCard(articleID: article.id, range: range,
                                     expression: "my expression", meaning: "my definition")
        let before = store.archive

        XCTAssertEqual(try store.cardSelectionStatus(articleID: article.id, range: range), .existing(card))
        XCTAssertEqual(store.archive, before)
        assertOverlapRejected(store: store, articleID: article.id, range: range)
        XCTAssertEqual(store.card(id: card.id), card)
        XCTAssertEqual(store.cards.count, 1)
    }

    func testPartialContainedAndContainingSelectionsShareSaveConflictRules() throws {
        let (store, article) = try fixture()
        defer { try? FileManager.default.removeItem(at: store.rootURL) }
        let text = article.text as NSString
        try store.saveCard(articleID: article.id, range: text.range(of: "beta"),
                           expression: "beta", meaning: "test")

        for selection in ["bet", "eta", "a bet", "eta g", "alpha beta", "beta gamma", "alpha beta gamma"] {
            let range = text.range(of: selection)
            XCTAssertNotEqual(range.location, NSNotFound, selection)
            XCTAssertEqual(try store.cardSelectionStatus(articleID: article.id, range: range), .overlapping, selection)
            assertOverlapRejected(store: store, articleID: article.id, range: range)
        }
        XCTAssertEqual(store.cards.count, 1)
    }

    func testAdjacentUnitsRemainAvailable() throws {
        let (store, article) = try fixture()
        defer { try? FileManager.default.removeItem(at: store.rootURL) }
        let range = (article.text as NSString).range(of: "beta")
        try store.saveCard(articleID: article.id, range: range, expression: "beta", meaning: "test")
        for adjacent in [NSRange(location: range.location - 2, length: 2),
                         NSRange(location: NSMaxRange(range), length: 2)] {
            XCTAssertEqual(try store.cardSelectionStatus(articleID: article.id, range: adjacent), .available)
            try store.saveCard(articleID: article.id, range: adjacent, expression: "adjacent", meaning: "test")
        }
        XCTAssertEqual(store.cards.count, 3)
    }

    func testSameSpellingAtAnotherOccurrenceOrInAnotherArticleIsIndependent() throws {
        let (store, article) = try fixture(body: "A bank stands near another bank.")
        defer { try? FileManager.default.removeItem(at: store.rootURL) }
        let text = article.text as NSString
        let first = text.range(of: "bank")
        let second = text.range(of: "bank", options: .backwards)
        try store.saveCard(articleID: article.id, range: first, expression: "bank", meaning: "银行")
        XCTAssertEqual(try store.cardSelectionStatus(articleID: article.id, range: second), .available)
        try store.saveCard(articleID: article.id, range: second, expression: "bank", meaning: "银行")

        let other = try store.addMarkdown(markdown: "# Notes\n\nA bank stands near another bank.", sourceName: "other.md")
        XCTAssertEqual(try store.cardSelectionStatus(articleID: other.id, range: first), .available)
        XCTAssertEqual(store.cards.count, 2)
    }

    func testDetachedHistoryDoesNotBlockNewAttachedAccumulation() throws {
        let (store, article) = try fixture()
        defer { try? FileManager.default.removeItem(at: store.rootURL) }
        let range = (article.text as NSString).range(of: "beta")
        let card = try store.saveCard(articleID: article.id, range: range, expression: "beta", meaning: "history")
        var archive = store.archive
        archive.cards[0].isDetached = true
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let importedURL = store.rootURL.appendingPathComponent("detached.json")
        try encoder.encode(archive).write(to: importedURL)
        try store.importProfile(from: importedURL)

        XCTAssertEqual(store.card(id: card.id)?.isDetached, true)
        XCTAssertEqual(try store.cardSelectionStatus(articleID: article.id, range: range), .available)
        let added = try store.saveCard(articleID: article.id, range: range, expression: "beta", meaning: "new")
        XCTAssertEqual(try store.cardSelectionStatus(articleID: article.id, range: range), .existing(added))
        XCTAssertEqual(store.card(id: card.id)?.meaning, "history")
        XCTAssertEqual(store.cards.count, 2)
    }

    func testUTF16RangesMatchScalarAnchorsWithEmojiAndCombiningCharacters() throws {
        let (store, article) = try fixture(body: "A 🧭 points toward 🙂 cafe\u{301} nearby.")
        defer { try? FileManager.default.removeItem(at: store.rootURL) }
        let text = article.text as NSString
        let selected = "🙂 cafe\u{301}"
        let range = text.range(of: selected)
        let card = try store.saveCard(articleID: article.id, range: range, expression: selected, meaning: "test")
        XCTAssertEqual(card.start, text.substring(to: range.location).unicodeScalars.count)
        XCTAssertEqual(card.end - card.start, selected.unicodeScalars.count)
        XCTAssertNotEqual(card.start, range.location)
        XCTAssertEqual(try store.cardSelectionStatus(articleID: article.id, range: range), .existing(card))
        XCTAssertEqual(try store.cardSelectionStatus(articleID: article.id, range: text.range(of: "cafe\u{301}")), .overlapping)
    }

    func testEditingCanExcludeOnlyItsOwnCard() throws {
        let (store, article) = try fixture()
        defer { try? FileManager.default.removeItem(at: store.rootURL) }
        let text = article.text as NSString
        let range = text.range(of: "beta")
        let card = try store.saveCard(articleID: article.id, range: range, expression: "beta", meaning: "before")
        let other = try store.saveCard(articleID: article.id, range: text.range(of: "gamma"),
                                      expression: "gamma", meaning: "other")
        XCTAssertEqual(try store.cardSelectionStatus(articleID: article.id, range: range,
                                                      excludingCardID: card.id), .available)
        XCTAssertEqual(try store.cardSelectionStatus(articleID: article.id, range: text.range(of: "gamma"),
                                                      excludingCardID: card.id), .existing(other))
        let edited = try store.saveCard(id: card.id, articleID: article.id, range: range,
                                       expression: "beta", meaning: "after")
        XCTAssertEqual(edited.id, card.id)
        XCTAssertEqual(edited.meaning, "after")
        XCTAssertEqual(edited.originalSentence, card.originalSentence)
    }

    func testInvalidRangesAndMissingArticleUseExistingValidation() throws {
        let (store, article) = try fixture(body: "A 🙂 cafe\u{301} nearby.")
        defer { try? FileManager.default.removeItem(at: store.rootURL) }
        let text = article.text as NSString
        let emoji = text.range(of: "🙂")
        let accented = text.range(of: "e\u{301}")
        let invalid = [NSRange(location: NSNotFound, length: 1), NSRange(location: -1, length: 1),
                       NSRange(location: 0, length: 0), NSRange(location: text.length, length: 1),
                       NSRange(location: 1, length: Int.max), NSRange(location: emoji.location, length: 1),
                       NSRange(location: emoji.location + 1, length: 1),
                       NSRange(location: accented.location, length: 1)]
        for range in invalid {
            XCTAssertThrowsError(try store.cardSelectionStatus(articleID: article.id, range: range)) { error in
                guard case ReadingLibraryError.invalidRange = error else {
                    return XCTFail("Expected invalidRange, got \(error)")
                }
            }
        }
        XCTAssertThrowsError(try store.cardSelectionStatus(articleID: UUID(), range: emoji)) { error in
            guard case ReadingLibraryError.missingArticle = error else {
                return XCTFail("Expected missingArticle, got \(error)")
            }
        }
        XCTAssertTrue(store.cards.isEmpty)
    }

    private func fixture(body: String = "alpha beta gamma.") throws -> (ReadingLibraryStore, LibraryArticle) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = try ReadingLibraryStore(rootURL: root, bundledCollections: [])
        let article = try store.addMarkdown(markdown: "# Notes\n\n\(body)", sourceName: "notes.md")
        return (store, article)
    }

    private func assertOverlapRejected(store: ReadingLibraryStore, articleID: UUID, range: NSRange,
                                       file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try store.saveCard(articleID: articleID, range: range,
                                               expression: "new", meaning: "new"), file: file, line: line) { error in
            guard case ReadingLibraryError.overlappingCard = error else {
                return XCTFail("Expected overlappingCard, got \(error)", file: file, line: line)
            }
        }
    }
}
