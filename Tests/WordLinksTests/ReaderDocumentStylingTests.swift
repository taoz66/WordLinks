import AppKit
import XCTest
@testable import WordLinks

@MainActor
final class ReaderDocumentStylingTests: XCTestCase {
    func testEmphasisListsQuotesAndLinksRenderWithoutChangingSelectableText() throws {
        let markdown = """
        # A reading sample

        Read **bold**, *italic* and ***both*** beside café 👩🏽‍💻 and [a source](https://example.org/story).

        > A quotation after the first paragraph.

        3. The numbered item wraps onto another visual line when space is narrow.
           - A nested item with **an emphasis**.

        A poem line  
        and another line.
        """
        let document = try ArticleMarkdownDocument.parse(markdown)
        for style in ReadingViewStyle.allCases {
            let typography = style.defaultTypography
            let rendered = NSMutableAttributedString(string: document.text, attributes: [
                .font: style.readerFont(size: typography.fontSize),
                .foregroundColor: style.readerForeground
            ])
            styleReaderParagraphs(rendered, title: document.title, blocks: document.blocks,
                                  readingStyle: style, typography: typography)
            styleReaderInline(rendered, styles: document.inlineStyles, readingStyle: style, typography: typography)
            XCTAssertEqual(rendered.string, document.text, "Formatting must not move card anchors")
            for (word, bold, italic) in [("bold", true, false), ("italic", false, true), ("both", true, true)] {
                let range = (document.text as NSString).range(of: word)
                let font = try XCTUnwrap(rendered.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont)
                let traits = NSFontManager.shared.traits(of: font)
                XCTAssertEqual(traits.contains(.boldFontMask), bold, style.rawValue + ": " + word)
                XCTAssertEqual(traits.contains(.italicFontMask), italic, style.rawValue + ": " + word)
            }
            let link = (document.text as NSString).range(of: "a source")
            XCTAssertEqual((rendered.attribute(.link, at: link.location, effectiveRange: nil) as? URL)?.absoluteString,
                           "https://example.org/story")
            let quotation = try XCTUnwrap(document.blocks.first { $0.kind == .quote })
            let quoteStyle = try XCTUnwrap(rendered.attribute(.paragraphStyle, at: quotation.range.location,
                                                             effectiveRange: nil) as? NSParagraphStyle)
            XCTAssertGreaterThan(quoteStyle.headIndent, 0)
            let lists = document.blocks.filter { if case .listItem = $0.kind { return true }; return false }
            XCTAssertEqual(lists.count, 2)
            let outer = try XCTUnwrap(rendered.attribute(.paragraphStyle, at: lists[0].range.location,
                                                        effectiveRange: nil) as? NSParagraphStyle)
            let nested = try XCTUnwrap(rendered.attribute(.paragraphStyle, at: lists[1].range.location,
                                                         effectiveRange: nil) as? NSParagraphStyle)
            XCTAssertGreaterThan(outer.headIndent, outer.firstLineHeadIndent)
            XCTAssertGreaterThan(nested.headIndent, outer.headIndent)
            XCTAssertTrue(document.text.contains("3.\tThe numbered item"))
            XCTAssertTrue(document.text.contains("A poem line\nand another line."))
        }
    }

    func testUnsafeLinksNeverBecomeClickableWhileReadableLabelsRemain() throws {
        let source = "Safe and unsafe labels remain visible."
        let text = NSMutableAttributedString(string: source)
        let range = (source as NSString).range(of: "unsafe")
        for target in ["file:///private/document", "javascript:alert(1)", "https:/hostless"] {
            let url = try XCTUnwrap(URL(string: target))
            styleReaderInline(text, styles: [ArticleInlineStyle(range: range, kind: .link(url))],
                              readingStyle: .standard, typography: ReadingViewStyle.standard.defaultTypography)
            XCTAssertNil(text.attribute(.link, at: range.location, effectiveRange: nil))
            XCTAssertEqual(text.string, source)
        }
    }

    func testTrailingLicenseBlockRendersAsColophonWithTextLinkWithoutAffectingBodyParagraphs() throws {
        let markdown = """
        # A licensed story

        License: this middle paragraph mentions a word and stays normal body prose.

        License: [CC BY 3.0](https://creativecommons.org/licenses/by/3.0/). Edited for reading; links, citations and media omitted.
        """
        let document = try ArticleMarkdownDocument.parse(markdown)
        XCTAssertEqual(document.blocks.map(\.kind), [.title, .paragraph, .license])
        XCTAssertFalse(document.text.contains("https://"))

        for style in ReadingViewStyle.allCases {
            let typography = style.defaultTypography
            let rendered = NSMutableAttributedString(string: document.text, attributes: [
                .font: style.readerFont(size: typography.fontSize),
                .foregroundColor: style.readerForeground
            ])
            styleReaderParagraphs(rendered, title: document.title, blocks: document.blocks,
                                  readingStyle: style, typography: typography)
            styleReaderInline(rendered, styles: document.inlineStyles, readingStyle: style, typography: typography)

            let bodyBlock = try XCTUnwrap(document.blocks.first { $0.kind == .paragraph })
            let licenseBlock = try XCTUnwrap(document.blocks.last { $0.kind == .license })
            let bodyFont = try XCTUnwrap(rendered.attribute(.font, at: bodyBlock.range.location, effectiveRange: nil) as? NSFont)
            let licenseFont = try XCTUnwrap(rendered.attribute(.font, at: licenseBlock.range.location, effectiveRange: nil) as? NSFont)
            XCTAssertLessThan(licenseFont.pointSize, bodyFont.pointSize, style.rawValue)

            let licenseParagraph = try XCTUnwrap(rendered.attribute(.paragraphStyle, at: licenseBlock.range.location,
                                                                    effectiveRange: nil) as? NSParagraphStyle)
            XCTAssertGreaterThan(licenseParagraph.paragraphSpacingBefore, 0, style.rawValue)

            let linkRange = (document.text as NSString).range(of: "CC BY 3.0")
            XCTAssertEqual((rendered.attribute(.link, at: linkRange.location, effectiveRange: nil) as? URL)?.absoluteString,
                           "https://creativecommons.org/licenses/by/3.0/")
            let linkFont = try XCTUnwrap(rendered.attribute(.font, at: linkRange.location, effectiveRange: nil) as? NSFont)
            XCTAssertEqual(linkFont.pointSize, licenseFont.pointSize, style.rawValue)
        }
    }
}
