import AppKit
import SwiftUI
import XCTest
@testable import ReadingToolDaily

@MainActor
final class StudyDetailIntegrationTests: XCTestCase {
    func testSavedEditsAndSystemUndoRefreshBothNativeStudyDetails() throws {
        _ = NSApplication.shared
        if NSScreen.screens.isEmpty { throw XCTSkip("Study detail integration requires WindowServer") }
        XCTAssertNotNil(NSImage(systemSymbolName: "arrow.up.doc", accessibilityDescription: nil))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try ReadingLibraryStore(rootURL: root, bundledCollections: [])
        let article = try store.addMarkdown(markdown: "# Study\n\nA word and another word.", sourceName: "study.md")
        let source = article.text as NSString
        let first = try store.saveCard(articleID: article.id, range: source.range(of: "word"),
                                       expression: "word", meaning: "original definition")
        _ = try store.saveCard(articleID: article.id, range: source.range(of: "word", options: .backwards),
                               expression: "WORD", meaning: "original definition")
        let editing = StudyInlineEditCoordinator()
        let vocabulary = NSHostingView(rootView:
            VocabularyEntryDetail(entryKey: "word", showsMeanings: true, showsExamples: true, openSource: { _ in })
                .environmentObject(store).environmentObject(editing))
        let articleView = NSHostingView(rootView:
            ArticleStudyDetail(article: article, showsMeanings: true, showsExamples: true,
                               openEntry: { _ in }, openSource: { _ in })
                .environmentObject(store).environmentObject(StudyInlineEditCoordinator()))
        let windows = [makeWindow(vocabulary), makeWindow(articleView)]
        defer { windows.forEach { $0.orderOut(nil); $0.contentView = nil; $0.close() } }
        settle(windows)
        XCTAssertEqual(inlineTexts(vocabulary), ["original definition"])
        XCTAssertEqual(inlineTexts(articleView).filter { $0 == "original definition" }.count, 2)

        let manager = UndoManager()
        manager.groupsByEvent = false
        let owner = UUID()
        XCTAssertTrue(editing.begin(owner: owner,
            target: StudyInlineEditTarget(profileID: store.archive.id, cardIDs: [first.id], field: .meaning),
            text: first.meaning, store: store, undoManager: manager))
        editing.updateDraft("updated definition", owner: owner)
        manager.beginUndoGrouping()
        XCTAssertTrue(editing.finishEditing())
        manager.endUndoGrouping()
        settle(windows)
        XCTAssertTrue(inlineTexts(vocabulary).contains("updated definition"))
        XCTAssertTrue(inlineTexts(articleView).contains("updated definition"))
        XCTAssertTrue(inlineTexts(articleView).contains("original definition"))
        manager.undo()
        settle(windows)
        XCTAssertEqual(inlineTexts(vocabulary), ["original definition"])
        XCTAssertEqual(inlineTexts(articleView).filter { $0 == "original definition" }.count, 2)
        manager.redo()
        settle(windows)
        XCTAssertTrue(inlineTexts(vocabulary).contains("updated definition"))
        XCTAssertTrue(inlineTexts(articleView).contains("updated definition"))
    }

    private func makeWindow(_ content: NSView) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 60, y: 60, width: 560, height: 500),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = content
        window.orderBack(nil)
        return window
    }

    private func inlineTexts(_ view: NSView) -> [String] {
        if let text = view as? InlineStudyTextView { return [text.string] }
        return view.subviews.flatMap(inlineTexts)
    }

    private func settle(_ windows: [NSWindow]) {
        for _ in 0..<5 {
            windows.forEach { $0.contentView?.layoutSubtreeIfNeeded(); $0.displayIfNeeded() }
            RunLoop.main.run(until: Date().addingTimeInterval(0.04))
        }
    }
}
