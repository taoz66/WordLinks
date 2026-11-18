import AppKit
import SwiftUI
import XCTest
@testable import WordLinks

@MainActor
final class ArticleImportEditorTests: XCTestCase {
    func testBodyEditorCaretAndPlaceholderShareInsetsAndLongTextScrolls() throws {
        let host = NSHostingView(rootView: NativeCardTextEditor(
            text: .constant(""), placeholder: "输入正文", label: "文章正文", minimumHeight: 220,
            maximumHeight: .greatestFiniteMagnitude, fillsAvailableHeight: true,
            textInset: NSSize(width: 10, height: 10), accessibilityIdentifier: "articleDraftBody"))
        host.frame = NSRect(x: 0, y: 0, width: 500, height: 300)
        host.layoutSubtreeIfNeeded()
        let scroll = try XCTUnwrap(descendant(CardInputScrollView.self, in: host))
        let textView = try XCTUnwrap(scroll.documentView as? CardInputTextView)
        let manager = try XCTUnwrap(textView.layoutManager)
        let container = try XCTUnwrap(textView.textContainer)
        manager.ensureLayout(for: container)
        XCTAssertEqual(textView.textContainerOrigin, NSPoint(x: 10, y: 10))
        XCTAssertEqual(container.lineFragmentPadding, 0)
        XCTAssertEqual(textView.placeholder, "输入正文")
        XCTAssertEqual(textView.accessibilityIdentifier(), "articleDraftBody")
        XCTAssertEqual(scroll.frame.height, 300, accuracy: 1)
        XCTAssertEqual(textView.selectedRange().location, 0)

        textView.string = Array(repeating: "Long text café 👩🏽‍💻 wraps in the editor.", count: 80).joined(separator: "\n")
        scroll.refreshDocumentGeometry()
        manager.ensureLayout(for: container)
        XCTAssertEqual(scroll.frame.height, 300, accuracy: 1)
        XCTAssertGreaterThan(textView.frame.height, scroll.contentSize.height)
        let firstGlyph = manager.boundingRect(forGlyphRange: NSRange(location: 0, length: 1), in: container)
        XCTAssertEqual(firstGlyph.minX + textView.textContainerOrigin.x, 10, accuracy: 1)
    }

    private func descendant<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
        if let result = view as? T { return result }
        return view.subviews.lazy.compactMap { self.descendant(type, in: $0) }.first
    }
}
