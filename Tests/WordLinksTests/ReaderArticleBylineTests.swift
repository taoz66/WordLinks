import AppKit
import XCTest
@testable import WordLinks

@MainActor
final class ReaderArticleBylineTests: XCTestCase {
    private let title = "Reading notes 👩🏽‍💻"
    private let body = "A café reader keeps careful notes.\n\nThe second paragraph stays selectable."

    func testMetadataAppearsWithoutChangingSourceTextBodyAttributesOrSelection() throws {
        let sourceURL = try XCTUnwrap(URL(string: "https://journals.plos.org/article?id=example"))
        for style in ReadingViewStyle.allCases {
            let view = makeTextView(width: 760, style: style)
            let original = view.string
            let bodyRange = NSRange(location: (title as NSString).length + 2, length: (body as NSString).length)
            let storage = try XCTUnwrap(view.textStorage)
            let originalBody = storage.attributedSubstring(from: bodyRange)
            let selection = (original as NSString).range(of: "careful notes")
            view.setSelectedRange(selection)
            let byline = ReaderArticleByline()

            byline.update(in: view, title: title,
                          metadata: ArticleMetadata(author: "Marcos Méndez", date: "2018-10-11",
                                                    source: "PLOS", sourceURL: sourceURL),
                          readingStyle: style, typography: style.defaultTypography)

            let label = try bylineLabel(in: view)
            XCTAssertFalse(label.isHidden, style.rawValue)
            XCTAssertTrue(label.stringValue.contains("Marcos Méndez"), style.rawValue)
            XCTAssertTrue(label.stringValue.contains("2018-10-11"), style.rawValue)
            XCTAssertTrue(label.stringValue.contains("PLOS"), style.rawValue)
            XCTAssertFalse(label.stringValue.contains(sourceURL.absoluteString), "The source displays its readable name")
            let sourceRange = (label.stringValue as NSString).range(of: "PLOS")
            XCTAssertEqual(label.attributedStringValue.attribute(.link, at: sourceRange.location,
                                                                  effectiveRange: nil) as? URL, sourceURL)
            XCTAssertNil(label.attributedStringValue.attribute(.link, at: 0, effectiveRange: nil),
                         "The author must not become part of the source link")
            XCTAssertEqual(view.string, original)
            XCTAssertEqual(view.selectedRange(), selection)
            XCTAssertEqual((view.string as NSString).substring(with: selection), "careful notes")
            XCTAssertTrue(storage.attributedSubstring(from: bodyRange).isEqual(to: originalBody),
                          "Byline layout must not restyle body characters used by cards and alignment")
            try assertBylineEndsBeforeBody(label, in: view, bodyRange: bodyRange)
        }
    }

    func testRemovingOrBlankingMetadataHidesTheBylineAndRestoresTheOriginalGap() throws {
        for style in ReadingViewStyle.allCases {
            let view = makeTextView(width: 400, style: style)
            let original = view.string
            let originalGap = try separatorStyle(in: view)
            let byline = ReaderArticleByline()
            let authors = "Maureen A. Carey, Kevin L. Steiner, William A. Petri Jr, Another Researcher"
            byline.update(in: view, title: title, metadata: ArticleMetadata(author: authors, date: "2026-11-11"),
                          readingStyle: style, typography: style.defaultTypography)
            XCTAssertGreaterThan(try separatorStyle(in: view).minimumLineHeight, originalGap.minimumLineHeight)

            for empty in [ArticleMetadata(), ArticleMetadata(author: " \n", date: "\t", source: " ")] {
                byline.update(in: view, title: title, metadata: empty,
                              readingStyle: style, typography: style.defaultTypography)
                let restoredGap = try separatorStyle(in: view)
                XCTAssertTrue(try bylineLabel(in: view).isHidden, style.rawValue)
                XCTAssertEqual(restoredGap.minimumLineHeight, originalGap.minimumLineHeight, accuracy: 0.01)
                XCTAssertEqual(restoredGap.maximumLineHeight, originalGap.maximumLineHeight, accuracy: 0.01)
                XCTAssertEqual(view.string, original)
            }
        }
    }

    func testSourceOnlyMetadataLinksOnlyToWebURLs() throws {
        let view = makeTextView(width: 600)
        let byline = ReaderArticleByline()
        for target in ["https://example.org/story", "http://example.org/story"] {
            let url = try XCTUnwrap(URL(string: target))
            byline.update(in: view, title: title,
                          metadata: ArticleMetadata(source: "Original article", sourceURL: url),
                          readingStyle: .standard, typography: ReadingViewStyle.standard.defaultTypography)
            let label = try bylineLabel(in: view)
            XCTAssertFalse(label.isHidden)
            XCTAssertEqual(label.stringValue, "Original article")
            XCTAssertEqual(label.attributedStringValue.attribute(.link, at: 0, effectiveRange: nil) as? URL, url)
        }
        for target in ["file:///private/article.md", "javascript:alert(1)", "mailto:author@example.org", "https:relative"] {
            let url = try XCTUnwrap(URL(string: target))
            byline.update(in: view, title: title,
                          metadata: ArticleMetadata(source: "Source name", sourceURL: url),
                          readingStyle: .standard, typography: ReadingViewStyle.standard.defaultTypography)
            let label = try bylineLabel(in: view)
            XCTAssertFalse(label.isHidden)
            XCTAssertEqual(label.stringValue, "Source name")
            XCTAssertNil(label.attributedStringValue.attribute(.link, at: 0, effectiveRange: nil), target)
        }
    }

    func testLongMultiAuthorBylineWrapsAndExpandsItsReservedGapWhenNarrowed() throws {
        let view = makeTextView(width: 940, style: .magazine)
        let original = view.string
        let selection = (original as NSString).range(of: "second paragraph")
        view.setSelectedRange(selection)
        let metadata = ArticleMetadata(
            author: "Maureen A. Carey, Kevin L. Steiner, William A. Petri Jr, Tatsuya Amano, Juan P. González-Varo, William J. Sutherland",
            date: "2026-11-11", source: "PLOS Computational Biology")
        let byline = ReaderArticleByline()
        byline.update(in: view, title: title, metadata: metadata,
                      readingStyle: .magazine, typography: ReadingViewStyle.magazine.defaultTypography)
        let label = try bylineLabel(in: view)
        let wideFrame = label.frame
        let wideGap = try separatorStyle(in: view).minimumLineHeight

        view.setFrameSize(NSSize(width: 340, height: view.frame.height))
        view.textContainer?.containerSize = NSSize(width: 340 - 2 * view.textContainerInset.width,
                                                   height: .greatestFiniteMagnitude)
        byline.layout(in: view)

        XCTAssertLessThan(label.frame.width, wideFrame.width)
        XCTAssertGreaterThan(label.frame.height, wideFrame.height)
        XCTAssertGreaterThan(try separatorStyle(in: view).minimumLineHeight, wideGap)
        XCTAssertTrue(label.stringValue.contains("William J. Sutherland"), "The final author must remain present")
        XCTAssertEqual(view.string, original)
        XCTAssertEqual(view.selectedRange(), selection)
        let bodyRange = NSRange(location: (title as NSString).length + 2, length: (body as NSString).length)
        try assertBylineEndsBeforeBody(label, in: view, bodyRange: bodyRange)
    }

    private func makeTextView(width: CGFloat, style: ReadingViewStyle = .standard) -> NSTextView {
        let typography = style.defaultTypography
        let text = NSMutableAttributedString(string: title + "\n\n" + body, attributes: [
            .font: NSFont.systemFont(ofSize: typography.fontSize),
            .foregroundColor: NSColor.textColor
        ])
        styleReaderParagraphs(text, title: title, blocks: [], readingStyle: style, typography: typography)
        let storage = NSTextStorage(attributedString: text)
        let manager = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: width - 48, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 5
        storage.addLayoutManager(manager)
        manager.addTextContainer(container)
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: width, height: 900), textContainer: container)
        view.textContainerInset = NSSize(width: 24, height: 28)
        view.isHorizontallyResizable = false
        view.isVerticallyResizable = true
        view.isEditable = false
        view.isSelectable = true
        container.widthTracksTextView = true
        container.containerSize = NSSize(width: width - 48, height: .greatestFiniteMagnitude)
        manager.ensureLayout(for: container)
        return view
    }

    private func bylineLabel(in view: NSTextView) throws -> NSTextField {
        let fields = view.subviews.compactMap { $0 as? NSTextField }
        XCTAssertEqual(fields.count, 1)
        return try XCTUnwrap(fields.first)
    }

    private func separatorStyle(in view: NSTextView) throws -> NSParagraphStyle {
        let storage = try XCTUnwrap(view.textStorage)
        return try XCTUnwrap(storage.attribute(.paragraphStyle, at: (title as NSString).length + 1,
                                               effectiveRange: nil) as? NSParagraphStyle)
    }

    private func assertBylineEndsBeforeBody(_ label: NSTextField, in view: NSTextView, bodyRange: NSRange) throws {
        let manager = try XCTUnwrap(view.layoutManager)
        let container = try XCTUnwrap(view.textContainer)
        manager.ensureLayout(for: container)
        let glyph = manager.glyphIndexForCharacter(at: bodyRange.location)
        let line = manager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        XCTAssertLessThanOrEqual(label.frame.maxY, view.textContainerOrigin.y + line.minY + 0.5,
                                 "The metadata must fit before the first body line")
    }
}
