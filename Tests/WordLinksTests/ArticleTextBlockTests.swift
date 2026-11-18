import Foundation
import XCTest
@testable import WordLinks

@MainActor
final class ArticleTextBlockTests: XCTestCase {
    private let markdown = """
    # **题目 🙂**

    > 导语 **中文** 与 [链接](https://example.com)。

    ## 标题 café 🙂

    正文含有 **目标词**，还有 🙂。

    题目 🙂
    """

    func testSemanticBlocksCoverExactUTF16TextWithUnicodeAndRepeatedTitle() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ReadingLibraryStore(rootURL: directory, bundledCollections: [])
        let article = try store.addMarkdown(markdown: markdown, sourceName: "unicode.md")
        let blocks = ReadingLibraryStore.readingBlocks(for: article)
        let expected = ["题目 🙂", "导语 中文 与 链接。", "标题 café 🙂", "正文含有 目标词，还有 🙂。", "题目 🙂"]

        XCTAssertEqual(article.text, expected.joined(separator: "\n\n"))
        XCTAssertEqual(blocks.map(\.kind), [.title, .lead, .heading(2), .paragraph, .paragraph])
        XCTAssertEqual(blocks.count, expected.count)
        var cursor = article.text.startIndex
        for (block, content) in zip(blocks, expected) {
            let range = try XCTUnwrap(article.text.range(of: content, range: cursor..<article.text.endIndex))
            XCTAssertEqual(block.range, NSRange(range, in: article.text))
            XCTAssertEqual((article.text as NSString).substring(with: block.range), content)
            cursor = range.upperBound
        }
        XCTAssertEqual(blocks.last.map { NSMaxRange($0.range) }, (article.text as NSString).length)
    }

    func testSemanticFormattingChangesPreserveTextCardAnchorsAndReadingProgress() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ReadingLibraryStore(rootURL: directory, bundledCollections: [])
        let article = try store.addMarkdown(markdown: markdown, sourceName: "unicode.md")
        let selection = (article.text as NSString).range(of: "目标词")
        let card = try store.saveCard(articleID: article.id, range: selection,
                                      expression: "目标词", meaning: "目标表达")
        try store.setReadOffset(articleID: article.id, offset: card.start)
        let originalBlocks = ReadingLibraryStore.readingBlocks(for: article)
        let revisedMarkdown = markdown
            .replacingOccurrences(of: "# **题目 🙂**", with: "# 题目 🙂")
            .replacingOccurrences(of: "> 导语", with: "导语")
            .replacingOccurrences(of: "## 标题", with: "### 标题")
        let sourceURL = try store.articleFileURL(article.id)
        try Data(revisedMarkdown.utf8).write(to: sourceURL, options: .atomic)

        store.refreshArticleFiles()

        let revised = try XCTUnwrap(store.article(id: article.id))
        let revisedBlocks = ReadingLibraryStore.readingBlocks(for: revised)
        XCTAssertEqual(revised.text, article.text)
        XCTAssertEqual(revisedBlocks.map(\.range), originalBlocks.map(\.range))
        XCTAssertEqual(revisedBlocks.map(\.kind), [.title, .paragraph, .heading(3), .paragraph, .paragraph])
        XCTAssertEqual(store.card(id: card.id), card)
        XCTAssertEqual(revised.readOffset, card.start)
    }
}
