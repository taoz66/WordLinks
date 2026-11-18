import Foundation
import XCTest
@testable import WordLinks

@MainActor
final class MorphologyLookupTests: XCTestCase {
    func testBundledLexiconRestoresOnlyUniqueDirectInflections() {
        let lookup = MorphologyLookup()
        for (selection, expected) in [
            ("books", "book"), ("beauties", "beauty"),
            ("walked", "walk"), ("arriving", "arrive"),
            ("took", "take"), ("went", "go"), ("children", "child"),
            ("meetings", "meeting")
        ] {
            XCTAssertEqual(lookup.initialExpression(for: selection), expected, selection)
        }
    }

    func testPreservesAmbiguityProperNamesNegationAndNonWords() {
        let lookup = MorphologyLookup()
        for selection in ["meeting", "running", "saw", "leaves", "beautiful", "cannot",
                          "May", "US", "Books", "in other words", "books!", "café", "中文", ""] {
            XCTAssertEqual(lookup.initialExpression(for: selection), selection, selection)
        }
    }

    func testUnavailableOrInvalidLexiconPreservesSelection() throws {
        XCTAssertEqual(MorphologyLookup(url: nil).initialExpression(for: "books"), "books")
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        XCTAssertEqual(MorphologyLookup(url: missing).initialExpression(for: "books"), "books")
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path))

        let invalid = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("invalid database".utf8).write(to: invalid)
        defer { try? FileManager.default.removeItem(at: invalid) }
        XCTAssertEqual(MorphologyLookup(url: invalid).initialExpression(for: "books"), "books")
    }

    func testNewCardUsesLemmaWhileKeepingOriginalSelectionAndSourcePosition() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try ReadingLibraryStore(rootURL: root, bundledCollections: [])
        let article = try store.addMarkdown(markdown: "# Notes\n\nThe café visitors 🙂 walked home together.",
                                            sourceName: "notes.md")
        let range = (article.text as NSString).range(of: "walked")
        let session = CardEditorSession(article: article, selectedRange: range,
                                        existingCard: nil, prefillEnabled: false)
        XCTAssertEqual(session.draft.expression, "walk")
        session.draft.updateManualMeaning("行走")
        let card = try store.saveCard(articleID: article.id, range: range,
                                      expression: session.draft.expression,
                                      meaning: session.draft.meaningToSave)

        XCTAssertEqual(card.expression, "walk")
        XCTAssertEqual(card.selectedText, "walked")
        XCTAssertEqual(card.start, (article.text as NSString).substring(to: range.location).unicodeScalars.count)
        XCTAssertEqual(card.end - card.start, "walked".unicodeScalars.count)
        XCTAssertEqual(card.originalSentence, "The café visitors 🙂 walked home together.")
    }

    func testExistingAndManuallyEditedExpressionsArePreserved() throws {
        let article = LibraryArticle(title: "Notes", sourceName: "notes.md",
                                     markdown: "They walked home.", text: "They walked home.")
        let range = (article.text as NSString).range(of: "walked")
        let card = StudyCard(id: UUID(), articleID: article.id, start: range.location,
                             end: NSMaxRange(range), selectedText: "walked", expression: "walked",
                             meaning: "走过", createdAt: Date(), updatedAt: Date())
        let session = CardEditorSession(article: article, selectedRange: range,
                                        existingCard: card, prefillEnabled: false)
        XCTAssertEqual(session.draft.expression, "walked")
        session.draft.updateExpression("books")
        XCTAssertEqual(session.draft.expression, "books")
    }
}
