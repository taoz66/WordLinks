import Foundation
import XCTest
@testable import WordLinks

@MainActor
final class ArticleDraftTests: XCTestCase {
    func testNewFormDetectsFormattingWithoutReplacingEnteredFields() throws {
        var draft = ArticleDraft()
        draft.title = "My own title"
        draft.author = "A Writer"
        draft.body = "A café by the water.\nAnother line with 2 * 3 and [a bracket]."
        XCTAssertEqual(draft.resolvedContentFormat, .plainText)
        let plain = try ArticleMarkdownDocument.parse(draft.markdown)
        XCTAssertEqual(plain.text, draft.title + "\n\n" + draft.body)
        XCTAssertTrue(plain.inlineStyles.isEmpty)

        draft.body = "## A section\n\nRead **carefully** with [a link](https://example.org).\n\n- First idea\n- Second idea"
        XCTAssertEqual(draft.resolvedContentFormat, .markdown)
        let formatted = try ArticleMarkdownDocument.parse(draft.markdown)
        XCTAssertTrue(formatted.text.contains("Read carefully with a link."))
        XCTAssertTrue(formatted.inlineStyles.contains { $0.kind == .strong })
        XCTAssertTrue(formatted.blocks.contains { $0.kind == .heading(2) })
        XCTAssertEqual(formatted.metadata.author, "A Writer")
        XCTAssertEqual(draft.title, "My own title")
        XCTAssertTrue(draft.body.hasPrefix("## A section"))

        draft.body = "Author: a fictional role\n日期：a line in the story\n\nRead **carefully**."
        let metadataLookingProse = try ArticleMarkdownDocument.parse(draft.markdown)
        XCTAssertTrue(metadataLookingProse.text.contains("Author: a fictional role"))
        XCTAssertTrue(metadataLookingProse.text.contains("日期：a line in the story"))
        XCTAssertEqual(metadataLookingProse.metadata.author, "A Writer")
        XCTAssertNil(metadataLookingProse.metadata.date)

        draft.body = "Back to plain text.\nKeep this line break."
        XCTAssertEqual(draft.resolvedContentFormat, .plainText)
        XCTAssertEqual(try ArticleMarkdownDocument.parse(draft.markdown).text,
                       draft.title + "\n\n" + draft.body)
    }

    func testAutomaticDetectionRecognizesInlineMarkdownAndKeepsFileFormatExplicit() throws {
        for body in ["Read *closely*.", "Use `a word`.", "> A quotation", "1. First\n2. Second",
                     "A [source](https://example.org).", "A line  \nAnother line."] {
            var draft = ArticleDraft()
            draft.title = "A title"
            draft.body = body
            XCTAssertEqual(draft.resolvedContentFormat, .markdown, body)
            XCTAssertTrue(draft.canSave)
        }
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("literal.txt")
        try Data("Keep **these marks**.\nAnother line.".utf8).write(to: url)
        let fileDraft = try ArticleDraft.read(from: url)
        XCTAssertEqual(fileDraft.resolvedContentFormat, .plainText)
        let document = try ArticleMarkdownDocument.parse(fileDraft.markdown)
        XCTAssertTrue(document.text.contains("**these marks**.\nAnother line."))
        XCTAssertTrue(document.inlineStyles.isEmpty)
    }

    func testOrdinaryPastedTextKeepsAllLinesAndLiteralMarkdownCharacters() throws {
        let original = "A title suggestion\nA *literal* word and [a bracket], not a link.\nThird line &copy; <tag>.\n\nA new stanza."
        let draft = ArticleDraft.pasted(original)
        XCTAssertEqual(draft.contentFormat, .plainText)
        XCTAssertEqual(draft.title, "A title suggestion")
        XCTAssertEqual(draft.body, original, "A suggested title must not consume the first line of prose")
        XCTAssertTrue(draft.canSave)
        XCTAssertTrue(draft.markdown.contains("A \\*literal\\* word"))
        XCTAssertTrue(draft.markdown.contains("suggestion\\\n"))
        let document = try ArticleMarkdownDocument.parse(draft.markdown)
        XCTAssertEqual(document.text, draft.title + "\n\n" + original)
        XCTAssertTrue(document.inlineStyles.isEmpty)
    }

    func testValidMarkdownRemainsByteForByteUntouchedUntilAFieldIsEdited() throws {
        let raw = "\u{FEFF}\r\n# **A title**\r\n\r\n 作者 ： Jo Carter\r\nDate: circa 1900\r\nSource: [Global Voices](https://globalvoices.org/example/)\r\n\r\nA **bold** paragraph.\r\n"
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("article.md")
        try Data(raw.utf8).write(to: url)
        var draft = try ArticleDraft.read(from: url)
        XCTAssertEqual(draft.title, "A title")
        XCTAssertEqual(draft.author, "Jo Carter")
        XCTAssertEqual(draft.date, "circa 1900")
        XCTAssertEqual(draft.source, "Global Voices")
        XCTAssertEqual(draft.sourceURL, "https://globalvoices.org/example/")
        XCTAssertEqual(draft.markdown, raw)
        XCTAssertEqual(draft.sourceFileURL, url.standardizedFileURL)
        XCTAssertFalse(draft.keepsSourceLinked)
        draft.date = "2026年11月"
        XCTAssertNotEqual(draft.markdown, raw)
        let parsed = try ArticleMarkdownDocument.parse(draft.markdown)
        XCTAssertEqual(parsed.metadata.date, "2026年11月")
        XCTAssertEqual(parsed.metadata.author, "Jo Carter")
        XCTAssertTrue(parsed.text.contains("A bold paragraph."))
        XCTAssertEqual(try Data(contentsOf: url), Data(raw.utf8), "Editing the form must not write to the source file")
    }

    func testFileNameFallbackAndUTF16BOMImportsKeepReadableBody() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        for (extensionName, encoding, bom) in [
            ("txt", String.Encoding.utf16LittleEndian, Data([0xFF, 0xFE])),
            ("markdown", String.Encoding.utf16BigEndian, Data([0xFE, 0xFF]))
        ] {
            let url = directory.appendingPathComponent("Poem.\(extensionName)")
            let prose = "A café by the water.\nAnother line."
            let data = try XCTUnwrap(prose.data(using: encoding))
            try (bom + data).write(to: url)
            let draft = try ArticleDraft.read(from: url)
            XCTAssertEqual(draft.title, "Poem")
            XCTAssertEqual(draft.body, prose)
            XCTAssertEqual(draft.sourceFileURL, url.standardizedFileURL)
            XCTAssertEqual(draft.fileName, extensionName == "txt" ? "Poem.md" : "Poem.markdown")
            XCTAssertGreaterThanOrEqual(draft.notices.count, 2)
            XCTAssertTrue(draft.canSave)
            let parsed = try ArticleMarkdownDocument.parse(draft.markdown)
            XCTAssertTrue(parsed.text.hasPrefix("Poem\n\nA café by the water."))
            if extensionName == "txt" { XCTAssertTrue(parsed.text.contains("water.\nAnother line.")) }
        }
    }

    func testSimpleFrontMatterBecomesOptionalFieldsAndComplexFrontMatterStaysInBody() throws {
        let input = """
        ---
        title: "A useful article"
        author: 'A Writer'
        date: 2026年11月
        source: A publisher
        url: https://example.org/article
        ---

        The first paragraph.
        """
        let draft = ArticleDraft.pasted(input)
        XCTAssertEqual(draft.title, "A useful article")
        XCTAssertEqual(draft.author, "A Writer")
        XCTAssertEqual(draft.date, "2026年11月")
        XCTAssertEqual(draft.source, "A publisher")
        XCTAssertEqual(draft.sourceURL, "https://example.org/article")
        XCTAssertEqual(draft.body, "The first paragraph.")
        XCTAssertFalse(draft.markdown.hasPrefix("---"))
        XCTAssertEqual(try ArticleMarkdownDocument.parse(draft.markdown).metadata.author, "A Writer")
        for fields in ["tags: [one, two]", "author:\n  name: A Writer", "description: |\n  More than one line"] {
            let complex = "---\n\(fields)\n---\n\nKeep this paragraph."
            let preserved = ArticleDraft.pasted(complex)
            XCTAssertEqual(preserved.body, complex)
            XCTAssertFalse(preserved.notices.isEmpty)
            XCTAssertTrue(preserved.markdown.contains(complex))
        }
        for header in ["### Deeper title", "  # Indented title", "#\tTabbed title"] {
            let compatible = ArticleDraft.pasted(header + "\n\nKeep the body.")
            XCTAssertTrue(compatible.canSave, header)
            let parsed = try ArticleMarkdownDocument.parse(compatible.markdown)
            XCTAssertEqual(parsed.title, compatible.title, header)
            XCTAssertTrue(parsed.text.contains("Keep the body."), header)
        }
    }

    func testOptionalSourceValidationAndHeaderInjectionDoNotEraseArticleText() throws {
        var draft = ArticleDraft.pasted("An ordinary article.")
        draft.author = "Alice\nDate: accidental field"
        draft.date = "any publication date"
        draft.source = "A Publisher"
        draft.sourceURL = "example.org/an-article"
        XCTAssertTrue(draft.canSave)
        XCTAssertTrue(draft.markdown.contains("Source: [A Publisher](https://example.org/an-article)"))
        let parsed = try ArticleMarkdownDocument.parse(draft.markdown)
        XCTAssertEqual(parsed.metadata.author, "Alice Date: accidental field")
        XCTAssertEqual(parsed.metadata.date, "any publication date")
        for target in ["javascript:alert(1)", "file:///private/article", "http:"] {
            draft.sourceURL = target
            XCTAssertFalse(draft.canSave, target)
            XCTAssertNotNil(draft.validationMessage)
            XCTAssertTrue(draft.markdown.contains("An ordinary article"))
        }
        draft.sourceURL = ""
        XCTAssertTrue(draft.canSave)

        let fieldLookingProse = ArticleDraft.pasted("Author: a character in the story\nDate: a word spoken aloud")
        let prose = try ArticleMarkdownDocument.parse(fieldLookingProse.markdown)
        XCTAssertNil(prose.metadata.author)
        XCTAssertNil(prose.metadata.date)
        XCTAssertTrue(prose.text.contains("Author: a character in the story\nDate: a word spoken aloud"))
    }

    func testLinkedDraftUsesThePreparedSourceEvenWhenFormFieldsHaveChanged() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("source.md")
        let source = "# Source\n\nThe source is authoritative.\n"
        try Data(source.utf8).write(to: url)
        var draft = try ArticleDraft.read(from: url)
        draft.title = "An unsaved form title"
        draft.body = "Different form body."
        draft.keepsSourceLinked = true
        XCTAssertEqual(draft.markdown, source)
        draft.keepsSourceLinked = false
        XCTAssertTrue(draft.markdown.contains("Different form body."))
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), source)
    }

    func testEscapedSourceLabelAndParenthesizedURLRoundTripWhenEditingMetadata() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var draft = ArticleDraft.pasted("A plain article.\nBody continues.")
        draft.source = "Book [Series]"
        draft.sourceURL = "https://example.org/path_(section)"
        let url = directory.appendingPathComponent("notes.md")
        try Data(draft.markdown.utf8).write(to: url)

        var imported = try ArticleDraft.read(from: url)
        XCTAssertEqual(imported.source, "Book [Series]")
        XCTAssertEqual(imported.sourceURL, "https://example.org/path_%28section%29")
        imported.date = "2026-11-11"
        let reparsed = try ArticleMarkdownDocument.parse(imported.markdown)
        XCTAssertEqual(reparsed.metadata.source, "Book [Series]")
        XCTAssertEqual(reparsed.metadata.sourceURL?.absoluteString, "https://example.org/path_%28section%29")
        XCTAssertEqual(reparsed.metadata.date, "2026-11-11")
        XCTAssertTrue(reparsed.text.contains("A plain article."))
    }

    func testUnsupportedFilesAndEncodingsFailClearlyAndLocalizedTemplatesAreReadable() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let unsupported = directory.appendingPathComponent("article.pdf")
        try Data("Not a PDF".utf8).write(to: unsupported)
        XCTAssertThrowsError(try ArticleDraft.read(from: unsupported))
        let invalid = directory.appendingPathComponent("invalid.txt")
        try Data([0x81, 0xFF, 0x31]).write(to: invalid)
        XCTAssertThrowsError(try ArticleDraft.read(from: invalid))
        let empty = directory.appendingPathComponent("empty.md")
        try Data(" \n\t".utf8).write(to: empty)
        XCTAssertThrowsError(try ArticleDraft.read(from: empty))
        for language in [InterfaceLanguage.chinese, .english] {
            let markdown = ArticleTemplate.markdown(for: language)
            XCTAssertTrue(ArticleDraft.pasted(markdown).canSave)
            let parsed = try ArticleMarkdownDocument.parse(markdown)
            XCTAssertFalse(parsed.text.isEmpty)
            XCTAssertTrue(parsed.blocks.contains { $0.kind == .heading(2) })
            XCTAssertFalse(parsed.metadata.author?.contains("optional") == true)
            XCTAssertFalse(parsed.metadata.author?.contains("选填") == true)
            if language == .english {
                XCTAssertEqual(parsed.metadata.sourceURL?.absoluteString, "https://example.com")
            }
        }
        let unsupportedDraft = ArticleDraft.pasted("# Article\n\n![A description](https://example.org/image.png)\n\n| Column |\n| --- |\n| Value |")
        XCTAssertFalse(unsupportedDraft.notices.isEmpty)
        XCTAssertTrue(unsupportedDraft.markdown.contains("![A description]"))
    }

    func testLocalizedFileImportsAllowOmittedAndEmptyOptionalHeaderLines() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        for language in [InterfaceLanguage.chinese, .english] {
            let chinese = language == .chinese
            let title = chinese ? "我的文章" : "My article"
            let labels = chinese ? ["作者：", "日期：", "来源："] : ["Author:", "Date:", "Source:"]
            let values = ["Jo Carter", "circa 1900", "[Publisher](https://example.com)"]
            let body = chinese ? "第一段。\n\n##正文小标题\n\n最后一段。" : "First paragraph.\n\n## Heading\n\nLast paragraph."
            for keepsEmptyLabels in [false, true] {
                // Every subset of optional fields is valid, in either language.
                for mask in 0..<8 {
                    let headers = labels.indices.compactMap { index -> String? in
                        if mask & (1 << index) != 0 { return labels[index] + " " + values[index] }
                        return keepsEmptyLabels ? labels[index] : nil
                    }.joined(separator: "\n")
                    let markdown = "# \(title)\n\n\(headers)\n\n\(body)\n"
                    let url = directory.appendingPathComponent("article.md")
                    try Data(markdown.utf8).write(to: url)
                    var draft = try ArticleDraft.read(from: url)
                    let document = try ArticleMarkdownDocument.parse(draft.markdown)
                    XCTAssertTrue(draft.canSave)
                    XCTAssertEqual(draft.title, title)
                    XCTAssertEqual(draft.body.trimmingCharacters(in: .newlines), body)
                    XCTAssertEqual(draft.author, mask & 1 != 0 ? "Jo Carter" : "")
                    XCTAssertEqual(draft.date, mask & 2 != 0 ? "circa 1900" : "")
                    XCTAssertEqual(draft.source, mask & 4 != 0 ? "Publisher" : "")
                    XCTAssertEqual(draft.sourceURL, mask & 4 != 0 ? "https://example.com" : "")
                    XCTAssertEqual(document.metadata.author, mask & 1 != 0 ? "Jo Carter" : nil)
                    XCTAssertEqual(document.metadata.date, mask & 2 != 0 ? "circa 1900" : nil)
                    XCTAssertTrue(document.blocks.contains { $0.kind == .heading(2) })
                    XCTAssertFalse(document.text.contains("Author:"))
                    XCTAssertFalse(document.text.contains("作者："))
                    XCTAssertEqual(draft.markdown, markdown, "An untouched import must retain its original source")
                    draft.title = "Changed title"
                    let edited = try ArticleMarkdownDocument.parse(draft.markdown)
                    XCTAssertEqual(edited.metadata, document.metadata)
                    XCTAssertEqual(edited.text, document.text.replacingOccurrences(of: title, with: "Changed title"))
                }
            }
        }
    }

    func testOptionalHintsDoNotBecomeMetadataAndDoNotStripBodyParentheses() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        for labels in [["Author: (optional)", "Date: (optional)", "Source: (optional)"],
                       ["作者：（选填）", "日期：（选填）", "来源：（选填）"]] {
            let markdown = "# Title\n\n" + labels.joined(separator: "\n") + "\n\nBody (optional).\n\n正文（选填）。"
            let url = directory.appendingPathComponent("empty-fields.markdown")
            try Data(markdown.utf8).write(to: url)
            let draft = try ArticleDraft.read(from: url)
            XCTAssertTrue(draft.canSave)
            XCTAssertEqual(draft.author, "")
            XCTAssertEqual(draft.date, "")
            XCTAssertEqual(draft.source, "")
            let document = try ArticleMarkdownDocument.parse(draft.markdown)
            XCTAssertEqual(document.metadata, ArticleMetadata())
            XCTAssertTrue(document.text.contains("Body (optional)."))
            XCTAssertTrue(document.text.contains("正文（选填）。"))
        }
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
