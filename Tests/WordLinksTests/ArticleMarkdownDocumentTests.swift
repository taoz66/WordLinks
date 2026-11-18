import Foundation
import XCTest
@testable import WordLinks

final class ArticleMarkdownDocumentTests: XCTestCase {
    func testCompactChineseHeadingsRenderWithoutChangingCodeOrOrdinaryHashes() throws {
        let markdown = """
        # 中文文章

        正文。

        ##正文小标题

        正文包含 #标签 和 C#。

        ```markdown
        ##代码中的文字
        ```

        `##行内代码`

        ## English heading

        Last paragraph.
        """
        let document = try ArticleMarkdownDocument.parse(markdown)
        XCTAssertTrue(document.blocks.contains {
            $0.kind == .heading(2) && (document.text as NSString).substring(with: $0.range) == "正文小标题"
        })
        XCTAssertTrue(document.text.contains("##代码中的文字"))
        XCTAssertTrue(document.text.contains("##行内代码"))
        XCTAssertTrue(document.text.contains("#标签 和 C#"))
        var draft = ArticleDraft()
        draft.title = "中文文章"
        draft.body = "##正文小标题\n\n正文。"
        XCTAssertEqual(draft.resolvedContentFormat, .markdown)
        XCTAssertTrue(try ArticleMarkdownDocument.parse(draft.markdown).blocks.contains { $0.kind == .heading(2) })
    }

    func testNestedInlineStylesAndBalancedLinksUseSelectableUTF16Ranges() throws {
        let markdown = "# **Notes 🙂**\n\nA café **bold and *italic*** reader uses `code` and [a source](https://example.org/a_(b))."
        let document = try ArticleMarkdownDocument.parse(markdown)
        XCTAssertEqual(document.title, "Notes 🙂")
        XCTAssertEqual(document.text, "Notes 🙂\n\nA café bold and italic reader uses code and a source.")
        let source = document.text as NSString
        let styles = document.inlineStyles
        XCTAssertTrue(styles.contains { $0.kind == .strong && source.substring(with: $0.range) == "bold and italic" })
        XCTAssertTrue(styles.contains { $0.kind == .emphasis && source.substring(with: $0.range) == "italic" })
        XCTAssertTrue(styles.contains { $0.kind == .code && source.substring(with: $0.range) == "code" })
        XCTAssertTrue(styles.contains {
            guard case .link(let url) = $0.kind else { return false }
            return url.absoluteString == "https://example.org/a_(b)" && source.substring(with: $0.range) == "a source"
        })
        for style in styles {
            XCTAssertGreaterThan(style.range.length, 0)
            XCTAssertLessThanOrEqual(NSMaxRange(style.range), source.length)
        }
    }

    func testListsKeepMarkersOrderingAndNestedDepthAndQuotesWorkInTheBody() throws {
        let document = try ArticleMarkdownDocument.parse("""
        # Notes

        An introduction.

        3. Third item
            - Child **bold**
        4. Fourth item

        > A quoted sentence.

        A conclusion.
        """)
        let blocks = document.blocks
        let source = document.text as NSString
        let lists = blocks.filter { if case .listItem = $0.kind { return true }; return false }
        XCTAssertEqual(lists.map(\.kind), [.listItem(depth: 0), .listItem(depth: 1), .listItem(depth: 0)])
        XCTAssertEqual(lists.map { source.substring(with: $0.range) }, ["3.\tThird item", "•\tChild bold", "4.\tFourth item"])
        XCTAssertTrue(blocks.contains { $0.kind == .quote && source.substring(with: $0.range) == "A quoted sentence." })
        XCTAssertFalse(document.text.contains(">"))
    }

    func testExplicitLineBreaksStayWhileSoftWrappingJoinsTheParagraph() throws {
        let document = try ArticleMarkdownDocument.parse("# A poem\n\nFirst line  \nSecond line\\\nThird line\nsoft continuation.\n\nLast stanza.")
        XCTAssertEqual(document.text, "A poem\n\nFirst line\nSecond line\nThird line soft continuation.\n\nLast stanza.")
        XCTAssertEqual(document.blocks.count, 3)
    }

    func testLinksAllowOnlyHTTPAndHTTPSAndDoNotActivateCodeOrUnsupportedBlocks() throws {
        let document = try ArticleMarkdownDocument.parse("""
        # Links

        See https://example.org/story, [web](http://example.org/) and [unsafe](javascript:alert(1)).

        `[code](https://example.org/code)`

        ```text
        https://example.org/literal
        ```
        """)
        let destinations = document.inlineStyles.compactMap { style -> URL? in
            if case .link(let url) = style.kind { return url }; return nil
        }
        XCTAssertEqual(Set(destinations.map(\.absoluteString)), ["https://example.org/story", "http://example.org/"])
        XCTAssertTrue(document.text.contains("unsafe"))
        XCTAssertTrue(document.text.contains("https://example.org/literal"))
    }

    func testMetadataRemainsOptionalAndDoesNotEnterReadingText() throws {
        let document = try ArticleMarkdownDocument.parse("\u{FEFF}# Title\r\n作者：张三\r\n日期：约1900年\r\n来源：[Source](https://example.org/)\r\n\r\n> A lead.\r\n\r\n## Section\r\n\r\nBody.")
        XCTAssertEqual(document.metadata, ArticleMetadata(author: "张三", date: "约1900年", source: "Source", sourceURL: URL(string: "https://example.org/")))
        XCTAssertEqual(document.text, "Title\n\nA lead.\n\nSection\n\nBody.")
        XCTAssertEqual(document.blocks.map(\.kind), [.title, .lead, .heading(2), .paragraph])
    }

    func testATXTitleAllowsCommonMarkIndentTabsAndClosingHashesAtSupportedLevels() throws {
        for (heading, expectedTitle) in [("  #\tA title ###", "A title"), ("   ## Title ##", "Title")] {
            let document = try ArticleMarkdownDocument.parse("\(heading)\n\nA paragraph.")
            XCTAssertEqual(document.title, expectedTitle)
            XCTAssertEqual(document.blocks.first?.kind, .title)
            XCTAssertEqual(document.text, expectedTitle + "\n\nA paragraph.")
        }
        XCTAssertThrowsError(try ArticleMarkdownDocument.parse("    # Indented too far\n\nBody."))
        XCTAssertThrowsError(try ArticleMarkdownDocument.parse("### Unsupported level\n\nBody."))
    }

    func testSourceLinkUsesMarkdownASTForEscapedLabelsAndParenthesizedURLs() throws {
        let markdown = "# Notes\nSource: [Book \\[Series\\]](https://example.org/a%28b%29)\n\nBody."
        let document = try ArticleMarkdownDocument.parse(markdown)
        XCTAssertEqual(document.metadata.source, "Book [Series]")
        XCTAssertEqual(document.metadata.sourceURL?.absoluteString, "https://example.org/a%28b%29")
        XCTAssertEqual(document.text, "Notes\n\nBody.")

        let nonWeb = try ArticleMarkdownDocument.parse("# Notes\nSource: [Archive](file:///tmp/notes)\n\nBody.")
        XCTAssertEqual(nonWeb.metadata.source, "Archive")
        XCTAssertNil(nonWeb.metadata.sourceURL)
    }
}

@MainActor
final class MarkdownFormattingMigrationTests: XCTestCase {
    func testLinkedPlainTextImportAndEditsNormalizeExactlyOnce() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let external = root.appendingPathComponent("Poem.txt")
        let original = "First *literal* line.\nSecond café line."
        try Data(original.utf8).write(to: external, options: .atomic)
        let store = try ReadingLibraryStore(rootURL: root.appendingPathComponent("Library"), bundledCollections: [])
        let id = try store.importMarkdown(from: external)
        let article = try XCTUnwrap(store.article(id: id))
        XCTAssertEqual(article.text, "Poem\n\n" + original)
        XCTAssertEqual(article.sourceFilePath, external.standardizedFileURL.path)
        let edited = original + "\nThird line."
        try Data(edited.utf8).write(to: external, options: .atomic)
        store.refreshArticleFiles()
        XCTAssertEqual(store.article(id: id)?.text, "Poem\n\n" + edited)
        XCTAssertTrue(store.fileSyncErrors.isEmpty)
        let reopened = try ReadingLibraryStore(rootURL: root.appendingPathComponent("Library"), bundledCollections: [])
        XCTAssertEqual(reopened.article(id: id)?.text, "Poem\n\n" + edited)
        XCTAssertEqual(try String(contentsOf: external, encoding: .utf8), edited)
    }

    func testManagedCanonicalMarkdownWithTextFilenameIsNotReinterpretedAsPlainText() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try ReadingLibraryStore(rootURL: root, bundledCollections: [])
        let markdown = "# Notes\n\nOne **bold** line.\n"
        let article = try store.addMarkdown(markdown: markdown, sourceName: "notes.txt")
        store.refreshArticleFiles()
        XCTAssertEqual(store.article(id: article.id)?.markdown, markdown)
        XCTAssertEqual(store.article(id: article.id)?.text, "Notes\n\nOne bold line.")
        let file = try store.articleFileURL(article.id)
        let edited = markdown.replacingOccurrences(of: "One", with: "Another")
        try Data(edited.utf8).write(to: file, options: .atomic)
        store.refreshArticleFiles()
        let reopened = try ReadingLibraryStore(rootURL: root, bundledCollections: [])
        XCTAssertEqual(reopened.article(id: article.id)?.markdown, edited)
        XCTAssertEqual(reopened.article(id: article.id)?.text, "Notes\n\nAnother bold line.")
        XCTAssertTrue(reopened.fileSyncErrors.isEmpty)
    }

    func testIndependentPlainTextDraftCopyStaysIndependentAndDoesNotDuplicateItsTitle() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let external = root.appendingPathComponent("Poem.txt")
        let original = "First line.\nSecond *literal* line."
        try Data(original.utf8).write(to: external)
        let draft = try ArticleDraft.read(from: external)
        let store = try ReadingLibraryStore(rootURL: root.appendingPathComponent("Library"), bundledCollections: [])
        let article = try store.addMarkdown(markdown: draft.markdown, sourceName: draft.fileName)
        try Data("Changed external text.".utf8).write(to: external, options: .atomic)
        store.refreshArticleFiles()
        let reopened = try ReadingLibraryStore(rootURL: root.appendingPathComponent("Library"), bundledCollections: [])
        XCTAssertEqual(reopened.article(id: article.id)?.text, "Poem\n\n" + original)
        XCTAssertEqual(reopened.article(id: article.id)?.markdown, draft.markdown)
        XCTAssertNil(reopened.article(id: article.id)?.sourceFilePath)
        XCTAssertTrue(reopened.fileSyncErrors.isEmpty)
    }

    func testLegacyListUpgradeRelocatesCardsAndReadingAnchorAndPreservesMarkdown() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try ReadingLibraryStore(rootURL: root, bundledCollections: [])
        let markdown = "# Notes\n\n- We keep **careful notes**.\n- Another item.\n"
        let current = try store.addMarkdown(markdown: markdown, sourceName: "notes.md")
        let oldText = "Notes\n\nWe keep careful notes.\n\nAnother item."
        let range = try XCTUnwrap(oldText.range(of: "careful notes"))
        let start = oldText[..<range.lowerBound].unicodeScalars.count
        let legacy = LibraryArticle(id: current.id, title: current.title, sourceName: current.sourceName,
                                    markdown: markdown, text: oldText, readOffset: start + 2)
        let card = StudyCard(articleID: legacy.id, start: start, end: start + "careful notes".count,
                             selectedText: "careful notes", expression: "careful notes", meaning: "仔细的笔记")
        var snapshot = store.archive
        snapshot.articles = [legacy]
        snapshot.cards = [card]
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let archiveURL = root.appendingPathComponent("Profiles/\(store.activeProfileID.uuidString)/library.json")
        try encoder.encode(snapshot).write(to: archiveURL, options: .atomic)

        let upgraded = try ReadingLibraryStore(rootURL: root, bundledCollections: [])
        let article = try XCTUnwrap(upgraded.article(id: legacy.id))
        let remapped = try XCTUnwrap(upgraded.card(id: card.id))
        XCTAssertEqual(article.markdown, markdown)
        XCTAssertEqual(article.text, "Notes\n\n•\tWe keep careful notes.\n\n•\tAnother item.")
        XCTAssertEqual(article.readOffset, remapped.start + 2)
        XCTAssertEqual(remapped.selectedText, card.selectedText)
        XCTAssertNotEqual(remapped.isDetached, true)
        XCTAssertEqual(try String(contentsOf: upgraded.articleFileURL(article.id), encoding: .utf8), markdown)
        XCTAssertFalse(upgraded.automaticBackups().isEmpty)
        let backups = upgraded.automaticBackups().count
        let reopened = try ReadingLibraryStore(rootURL: root, bundledCollections: [])
        XCTAssertEqual(reopened.article(id: article.id)?.text, article.text)
        XCTAssertEqual(reopened.automaticBackups().count, backups)
    }
}
