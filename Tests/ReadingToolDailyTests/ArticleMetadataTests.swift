import Foundation
import XCTest
@testable import ReadingToolDaily

@MainActor
final class ArticleMetadataTests: XCTestCase {
    func testOptionalHeaderFieldsPreserveMarkdownAndCanonicalSelectionRanges() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ReadingLibraryStore(rootURL: directory, bundledCollections: [])
        let body = "> A short introduction.\n\nThe reader 👩🏽‍💻 follows **the same words**.\n\n## A section\n\nThe last paragraph."
        let plain = try store.addMarkdown(markdown: "# A title\n\n" + body, sourceName: "plain.md")
        let markdown = "# A title\n\nAuthor: Jo Carter\nDate: 2026-01-21\nSource: [Global Voices](https://globalvoices.org/a-story/)\n\n" + body
        let article = try store.addMarkdown(markdown: markdown, sourceName: "metadata.md")
        XCTAssertEqual(article.metadata.author, "Jo Carter")
        XCTAssertEqual(article.metadata.date, "2026-01-21")
        XCTAssertEqual(article.metadata.source, "Global Voices")
        XCTAssertEqual(article.metadata.sourceURL?.absoluteString, "https://globalvoices.org/a-story/")
        XCTAssertEqual(article.markdown, markdown)
        XCTAssertEqual(article.text, plain.text)
        XCTAssertEqual(ReadingLibraryStore.readingBlocks(for: article), ReadingLibraryStore.readingBlocks(for: plain))
        for block in ReadingLibraryStore.readingBlocks(for: article) {
            XCTAssertGreaterThan(block.range.length, 0)
            XCTAssertLessThanOrEqual(NSMaxRange(block.range), (article.text as NSString).length)
        }
    }

    func testMissingEmptyPartialAndLocalizedFieldsDoNotRequireOneDateFormat() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ReadingLibraryStore(rootURL: directory, bundledCollections: [])
        for fields in ["", "Author: \nDate:\t\nSource: \n"] {
            let article = try store.addMarkdown(markdown: "# Title\n\n\(fields)\nBody.", sourceName: "empty.md")
            XCTAssertEqual(article.metadata, ArticleMetadata())
            XCTAssertEqual(article.text, "Title\n\nBody.")
        }
        let authorOnly = try store.addMarkdown(markdown: "# Title\n\tAuThOr\t:\tMatt\t\n\nBody.", sourceName: "author.md")
        XCTAssertEqual(authorOnly.metadata.author, "Matt")
        XCTAssertNil(authorOnly.metadata.date)
        let dateOnly = try store.addMarkdown(markdown: "# Title\nDate: circa 1900\n\nBody.", sourceName: "date.md")
        XCTAssertEqual(dateOnly.metadata.date, "circa 1900")
        XCTAssertNil(dateOnly.metadata.author)
        let localized = try store.addMarkdown(markdown: "\u{FEFF}## 标题\r\n\r\n 作者 ： 张三、李四 \r\n\r\n发表日期：2026年11月\r\n来源：媒体名\r\n\r\n正文。", sourceName: "localized.md")
        XCTAssertEqual(localized.metadata, ArticleMetadata(author: "张三、李四", date: "2026年11月", source: "媒体名"))
        XCTAssertEqual(localized.text, "标题\n\n正文。")
    }

    func testSourceOnlyAndMalformedSourceValuesRemainReadable() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ReadingLibraryStore(rootURL: directory, bundledCollections: [])
        let sourceOnly = try store.addMarkdown(markdown: "# Title\nSource: [PLOS](https://journals.plos.org/article?id=10.1371/test)\n\nBody.", sourceName: "source.md")
        XCTAssertEqual(sourceOnly.metadata.source, "PLOS")
        XCTAssertNotNil(sourceOnly.metadata.sourceURL)
        XCTAssertNil(sourceOnly.metadata.author)
        XCTAssertNil(sourceOnly.metadata.date)
        for value in ["[Unfinished](https://example.org", "[Source](not-a-url)", "[Source](file:///private/test)", "[Source](javascript:alert(1))"] {
            let article = try store.addMarkdown(markdown: "# Title\nAuthor: Matt\nSource: \(value)\nDate: unknown\n\nBody.", sourceName: "malformed.md")
            XCTAssertEqual(article.metadata.author, "Matt")
            XCTAssertEqual(article.metadata.date, "unknown")
            XCTAssertNotNil(article.metadata.source)
            XCTAssertNil(article.metadata.sourceURL)
            XCTAssertEqual(article.text, "Title\n\nBody.")
        }
    }

    func testFieldLookingBodyAndMalformedHeadersStayInBody() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ReadingLibraryStore(rootURL: directory, bundledCollections: [])
        let body = "The story begins.\n\nAuthor: another character\nDate: a date in the story\nSource: a sentence."
        let article = try store.addMarkdown(markdown: "# Title\nAuthor: Matt\n\n" + body, sourceName: "late.md")
        XCTAssertEqual(article.metadata.author, "Matt")
        XCTAssertNil(article.metadata.date)
        XCTAssertNil(article.metadata.source)
        XCTAssertTrue(article.text.contains("Author: another character"))
        XCTAssertTrue(article.text.contains("Date: a date in the story"))
        let leadFirst = try store.addMarkdown(markdown: "# Title\n\n> A lead.\n\nAuthor: remains in body", sourceName: "lead.md")
        XCTAssertEqual(leadFirst.metadata, ArticleMetadata())
        XCTAssertTrue(leadFirst.text.contains("Author: remains in body"))
        for firstLine in ["Author - Matt", "Publisher: A publication"] {
            let malformed = try store.addMarkdown(markdown: "# Title\n\n\(firstLine)\nDate: remains prose\n\nBody.", sourceName: "unknown.md")
            XCTAssertEqual(malformed.metadata, ArticleMetadata())
            XCTAssertTrue(malformed.text.contains(firstLine))
            XCTAssertTrue(malformed.text.contains("Date: remains prose"))
        }
    }

    func testMetadataOnlyFileChangesPreserveCardsAndReadingOffset() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let libraryURL = directory.appendingPathComponent("Library", isDirectory: true)
        let sourceURL = directory.appendingPathComponent("notes.md")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let body = "A café 🙂 makes progress today."
        try Data("# Notes\n\n\(body)\n".utf8).write(to: sourceURL, options: .atomic)
        let store = try ReadingLibraryStore(rootURL: libraryURL, bundledCollections: [])
        let id = try store.importMarkdown(from: sourceURL)
        let original = try XCTUnwrap(store.article(id: id))
        let card = try store.saveCard(articleID: id, range: (original.text as NSString).range(of: "progress"),
                                      expression: "make progress", meaning: "取得进展")
        try store.setReadOffset(articleID: id, offset: card.start + 2)

        for author in ["Jo Carter", "Updated Author With A Longer Name"] {
            let markdown = "# Notes\n\nAuthor: \(author)\nDate: 2026-11\nSource: [Source](https://example.org/story)\n\n\(body)\n"
            try Data(markdown.utf8).write(to: sourceURL, options: .atomic)
            store.refreshArticleFiles()
            let revised = try XCTUnwrap(store.article(id: id))
            XCTAssertEqual(revised.metadata.author, author)
            XCTAssertEqual(revised.markdown, markdown)
            XCTAssertEqual(revised.text, original.text)
            XCTAssertEqual(revised.readOffset, card.start + 2)
            XCTAssertEqual(store.card(id: card.id), card)
            XCTAssertTrue(store.fileSyncErrors.isEmpty)
        }
        let reopened = try ReadingLibraryStore(rootURL: libraryURL, bundledCollections: [])
        XCTAssertEqual(reopened.article(id: id)?.metadata.author, "Updated Author With A Longer Name")
        XCTAssertEqual(reopened.card(id: card.id)?.start, card.start)
        XCTAssertEqual(reopened.article(id: id)?.readOffset, card.start + 2)
    }

    func testMetadataOnlyRevisionDoesNotReattachDetachedCardsOrMigrateTheirContext() {
        let article = LibraryArticle(title: "Title", sourceName: "notes.md", markdown: "# Title\n\nA word.",
                                     text: "Title\n\nA word.", readOffset: 8)
        let card = StudyCard(articleID: article.id, start: 9, end: 13, selectedText: "word",
                             expression: "word", meaning: "词", isDetached: true)
        let updated = ArticleRevision.replace(article, markdown: "# Title\nAuthor: Matt\n\nA word.",
                                               title: article.title, text: article.text, cards: [card])
        XCTAssertEqual(updated.cards, [card])
        XCTAssertEqual(updated.article.readOffset, article.readOffset)
        XCTAssertEqual(updated.article.id, article.id)
        XCTAssertEqual(updated.article.metadata.author, "Matt")
    }

    func testLegacyArchiveWithAuthorDateProseLoadsAndKeepsCanonicalTextAndCards() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let markdown = "# Legacy\n\nAuthor: a character\n\nDate: 1900\n\nSource: Archive\n\nA café 🙂 makes progress."
        let text = "Legacy\n\nAuthor: a character\n\nDate: 1900\n\nSource: Archive\n\nA café 🙂 makes progress."
        let range = try XCTUnwrap(text.range(of: "progress"))
        let start = text[..<range.lowerBound].unicodeScalars.count
        let article = LibraryArticle(title: "Legacy", sourceName: "legacy.md", markdown: markdown, text: text, readOffset: start)
        let card = StudyCard(articleID: article.id, start: start, end: start + "progress".count,
                             selectedText: "progress", expression: "make progress", meaning: "取得进展")
        let snapshot = ProfileArchive(id: UUID(), name: "Legacy profile", articles: [article], cards: [card], lastArticleID: article.id)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let snapshotURL = directory.appendingPathComponent("legacy.json")
        try encoder.encode(snapshot).write(to: snapshotURL)
        let libraryURL = directory.appendingPathComponent("Library", isDirectory: true)
        let store = try ReadingLibraryStore(rootURL: libraryURL, bundledCollections: [])
        try store.importProfile(from: snapshotURL)
        let restored = try XCTUnwrap(store.article(id: article.id))
        XCTAssertEqual(restored.metadata, ArticleMetadata())
        XCTAssertEqual(restored.text, text)
        XCTAssertEqual(restored.markdown, markdown)
        XCTAssertEqual(restored.readOffset, start)
        XCTAssertEqual(store.card(id: card.id)?.start, start)
        XCTAssertEqual(store.card(id: card.id)?.meaning, card.meaning)
        let blocks = ReadingLibraryStore.readingBlocks(for: restored)
        XCTAssertEqual(blocks.count, 5)
        XCTAssertEqual(blocks.map { (restored.text as NSString).substring(with: $0.range) }.joined(separator: "\n\n"), text)
        let reopened = try ReadingLibraryStore(rootURL: libraryURL, bundledCollections: [])
        XCTAssertEqual(reopened.article(id: article.id)?.text, text)
        XCTAssertEqual(reopened.article(id: article.id)?.metadata, ArticleMetadata())
        XCTAssertEqual(reopened.card(id: card.id)?.selectedText, "progress")
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("Wordlinks-Metadata-\(UUID().uuidString)", isDirectory: true)
    }
}
