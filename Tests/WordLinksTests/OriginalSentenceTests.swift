import Foundation
import XCTest
@testable import WordLinks

@MainActor
final class OriginalSentenceTests: XCTestCase {
    func testNewCardsCaptureCoveredSentencesAndKeepSnapshotsAfterEditsAndDetach() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try ReadingLibraryStore(rootURL: root, bundledCollections: [])
        let article = try store.addMarkdown(markdown: """
            # Notes

            A café 🙂 opened here. The river changed course. Local people moved away. The final sentence stays.
            """, sourceName: "notes.md")
        let single = try store.saveCard(articleID: article.id,
            range: (article.text as NSString).range(of: "café"), expression: "café", meaning: "咖啡馆")
        let selectedText = "changed course. Local people"
        let selection = (article.text as NSString).range(of: selectedText)
        let saved = try store.saveCard(articleID: article.id, range: selection,
            expression: "change course", meaning: "改变方向")
        let expected = "The river changed course. Local people moved away."
        XCTAssertEqual(single.originalSentence, "A café 🙂 opened here.")
        XCTAssertEqual(saved.originalSentence, expected)
        XCTAssertEqual(store.originalSentence(for: saved), expected)

        let edited = try store.saveCard(id: saved.id, articleID: article.id, range: selection,
            expression: "change course", meaning: "改变河道")
        XCTAssertEqual(edited.originalSentence, expected)
        let file = try store.articleFileURL(article.id)
        try Data("# Notes\n\nA café 🙂 opened here. The wide river changed course. Local people moved away quickly. The final sentence stays.".utf8)
            .write(to: file, options: .atomic)
        store.refreshArticleFiles()
        let relocated = try XCTUnwrap(store.card(id: saved.id))
        XCTAssertNotEqual(relocated.isDetached, true)
        XCTAssertEqual(relocated.originalSentence, expected)
        XCTAssertEqual(store.originalSentence(for: relocated), expected)

        try Data("# Notes\n\nThe final sentence stays.".utf8).write(to: file, options: .atomic)
        store.refreshArticleFiles()
        let detached = try XCTUnwrap(store.card(id: saved.id))
        XCTAssertEqual(detached.isDetached, true)
        XCTAssertEqual(store.originalSentence(for: detached), expected)
        let reopened = try ReadingLibraryStore(rootURL: root, bundledCollections: [])
        XCTAssertEqual(reopened.card(id: saved.id)?.originalSentence, expected)
        XCTAssertEqual(reopened.card(id: single.id)?.originalSentence, "A café 🙂 opened here.")
    }

    func testLegacyCardsDecodeUseExactAnchorsAndCaptureContextBeforeMarkdownChanges() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try ReadingLibraryStore(rootURL: root, bundledCollections: [])
        let article = try store.addMarkdown(markdown: "# Notes\n\nFirst café 🙂 word belongs here. Another word belongs elsewhere. Tail stays.",
            sourceName: "legacy.md")
        let text = article.text as NSString
        let firstRange = text.range(of: "word")
        let secondRange = text.range(of: "word", options: .backwards)
        let first = try store.saveCard(articleID: article.id, range: firstRange, expression: "word", meaning: "词")
        let second = try store.saveCard(articleID: article.id, range: secondRange, expression: "word", meaning: "词")
        let legacyURL = root.appendingPathComponent("legacy.json")
        try store.exportActiveProfile(to: legacyURL)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: legacyURL)) as? [String: Any])
        var cards = try XCTUnwrap(json["cards"] as? [[String: Any]])
        for index in cards.indices { cards[index].removeValue(forKey: "originalSentence") }
        json["cards"] = cards
        try JSONSerialization.data(withJSONObject: json).write(to: legacyURL)
        try store.importProfile(from: legacyURL)

        let legacyFirst = try XCTUnwrap(store.card(id: first.id))
        let legacySecond = try XCTUnwrap(store.card(id: second.id))
        XCTAssertNil(legacyFirst.originalSentence)
        XCTAssertNil(legacySecond.originalSentence)
        XCTAssertEqual(store.originalSentence(for: legacyFirst), "First café 🙂 word belongs here.")
        XCTAssertEqual(store.originalSentence(for: legacySecond), "Another word belongs elsewhere.")
        var detached = legacySecond
        detached.isDetached = true
        XCTAssertEqual(store.originalSentence(for: detached), "word")
        let invalidAnchor = StudyCard(articleID: article.id, start: first.start + 1, end: first.end + 1,
            selectedText: "word", expression: "word", meaning: "词")
        XCTAssertEqual(store.originalSentence(for: invalidAnchor), "word")

        let edited = try store.saveCard(id: first.id, articleID: article.id, range: firstRange,
            expression: "word", meaning: "单词")
        XCTAssertNil(edited.originalSentence)
        let file = try store.articleFileURL(article.id)
        try Data("# Notes\n\nFirst café 🙂 word now belongs here. Another word now belongs elsewhere. Tail stays.".utf8)
            .write(to: file, options: .atomic)
        store.refreshArticleFiles()
        XCTAssertEqual(store.card(id: first.id)?.originalSentence, "First café 🙂 word belongs here.")
        XCTAssertEqual(store.card(id: second.id)?.originalSentence, "Another word belongs elsewhere.")
        let reopened = try ReadingLibraryStore(rootURL: root, bundledCollections: [])
        XCTAssertEqual(reopened.card(id: first.id)?.originalSentence, "First café 🙂 word belongs here.")
        XCTAssertEqual(reopened.card(id: second.id)?.originalSentence, "Another word belongs elsewhere.")
    }
}
