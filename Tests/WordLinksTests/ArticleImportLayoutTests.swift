import AppKit
import SwiftUI
import XCTest
@testable import WordLinks

/// Host the import form's actual AppKit views using disposable article data.
/// No AI settings, credential storage, network or global preference writes occur.
@MainActor
final class ArticleImportLayoutTests: XCTestCase {
    func testCompactImportKeepsFooterAndBodyVisibleWithLongSaveError() async throws {
        let store = try makeStore()
        var first = makeItem(title: "First synthetic article", marker: "FIRST ARTICLE")
        first.saveError = Array(repeating: "Could not save a synthetic article at a deliberately long unavailable path.",
                                count: 18).joined(separator: "\n")
        let second = makeItem(title: "Second synthetic article", marker: "SECOND ARTICLE")
        let host = NSHostingView(rootView: ArticleImportSheet(items: [first, second], targetFolderID: nil) { _ in }
            .environmentObject(store))
        let window = try makeWindow(host: host, size: NSSize(width: 580, height: 440))
        defer { close(window) }
        await settle(window)
        // A native sheet's preferred size may be initially larger. Explicitly
        // exercise the supported compact viewport after its screen probe settles.
        window.setContentSize(NSSize(width: 580, height: 440))
        await settle(window)
        XCTAssertEqual(host.bounds.width, 580, accuracy: 2)
        XCTAssertEqual(host.bounds.height, 440, accuracy: 2)
        try assertFooterAndEditorVisible(in: host, window: window)
        XCTAssertTrue(descendants(CardInputTextView.self, in: host).contains { $0.string.contains("FIRST ARTICLE") })
        try snapshot(host, name: "import-compact-long-error")
        XCTAssertTrue(store.articles.isEmpty, "Layout checks must not import articles")
    }

    func testWideBatchImportUsesNativeSelectionAndKeepsFooterVisible() async throws {
        let store = try makeStore()
        let first = makeItem(title: "First synthetic article", marker: "FIRST ARTICLE")
        let second = makeItem(title: "Second synthetic article", marker: "SECOND ARTICLE")
        let host = NSHostingView(rootView: ArticleImportSheet(items: [first, second], targetFolderID: nil) { _ in }
            .environmentObject(store))
        let window = try makeWindow(host: host, size: NSSize(width: 1040, height: 740))
        defer { close(window) }
        await settle(window)
        window.setContentSize(NSSize(width: 1040, height: 740))
        await settle(window)
        try assertFooterAndEditorVisible(in: host, window: window)
        let table = try XCTUnwrap(descendants(NSTableView.self, in: host).first { $0.numberOfRows == 2 },
                                 "Batch import must use a real native selectable list")
        XCTAssertFalse(table.allowsMultipleSelection)
        table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        await settle(window)
        XCTAssertTrue(descendants(CardInputTextView.self, in: host).contains { $0.string.contains("SECOND ARTICLE") },
                      "Selecting a native batch row must display that article's independent draft")
        try assertFooterAndEditorVisible(in: host, window: window)
        try snapshot(host, name: "import-wide-second-selection")
        XCTAssertTrue(store.articles.isEmpty, "Selecting a draft must not import it")
    }

    func testTallSingleArticleKeepsTitleVisibleWithoutPreviewControls() async throws {
        let store = try makeStore()
        for size in [NSSize(width: 580, height: 728), NSSize(width: 880, height: 740)] {
            let host = NSHostingView(rootView: ArticleImportSheet(
                items: [makeItem(title: "Single article layout", marker: "SINGLE ARTICLE")], targetFolderID: nil) { _ in }
                .environmentObject(store))
            let window = try makeWindow(host: host, size: size)
            defer { close(window) }
            await settle(window)
            window.setContentSize(size)
            await settle(window)
            assertNoPreviewControls(in: host)
            let title = try XCTUnwrap(descendants(NSTextField.self, in: host).first {
                $0.stringValue == "Single article layout"
            })
            assertFieldCompletelyVisible(title, window: window)
            try assertFooterAndEditorVisible(in: host, window: window)
            try snapshot(host, name: "import-direct-edit-\(Int(size.width))-\(Int(size.height))")
        }
    }

    func testPresentedSheetStartsAtPreferredWidthAndPreservesUserResize() async throws {
        let store = try makeStore()
        let state = ImportSheetPresentation()
        let parentHost = NSHostingView(rootView: ImportSheetPresentationHost(
            state: state, item: makeItem(title: "Presented sheet", marker: "PRESENTED ARTICLE"), store: store))
        let parent = try makeWindow(host: parentHost, size: NSSize(width: 1100, height: 850))
        defer { close(parent) }
        await settle(parent)
        state.isPresented = true
        await settle(parent)
        let sheet = try XCTUnwrap(parent.attachedSheet, "Exercise a real SwiftUI sheet rather than a manually sized window")
        defer {
            state.isPresented = false
            if sheet.sheetParent != nil { parent.endSheet(sheet) }
        }
        await settle(sheet)
        let screen = try XCTUnwrap(sheet.screen ?? parent.screen)
        let visible = screen.visibleFrame.insetBy(dx: 20, dy: 20)
        let available = sheet.contentRect(forFrameRect: visible).size
        let expectedWidth = min(560, available.width)
        XCTAssertEqual(sheet.contentRect(forFrameRect: sheet.frame).width, expectedWidth, accuracy: 2,
                       "The first presentation must use the preferred width without manual setContentSize")
        XCTAssertEqual(sheet.contentRect(forFrameRect: sheet.frame).height, min(600, available.height), accuracy: 2,
                       "The direct editor must open at its compact preferred height")
        if let content = sheet.contentView { assertNoPreviewControls(in: content) }
        let resized = NSSize(width: min(650, available.width), height: min(600, available.height))
        sheet.setContentSize(resized)
        await settle(sheet)
        // Re-evaluate the display constraints using the same AppKit notification
        // as a real display move. The initial size must not override user sizing.
        let content = try XCTUnwrap(sheet.contentView)
        NotificationCenter.default.post(name: NSWindow.didChangeScreenNotification, object: sheet)
        await settle(sheet)
        let actual = sheet.contentRect(forFrameRect: sheet.frame).size
        XCTAssertEqual(actual.width, resized.width, accuracy: 2)
        XCTAssertEqual(actual.height, resized.height, accuracy: 2)
        try assertFooterAndEditorVisible(in: content, window: sheet)
    }

    func testTemplateSheetPresentsAtItsCompactSizeAndStaysThere() async throws {
        let store = try makeStore()
        let state = ImportSheetPresentation()
        let parentHost = NSHostingView(rootView: ImportSheetPresentationHost(
            state: state, item: makeItem(title: "Unused article", marker: "UNUSED"), store: store,
            showsTemplate: true))
        let parent = try makeWindow(host: parentHost, size: NSSize(width: 1100, height: 850))
        defer { close(parent) }
        await settle(parent)
        state.isPresented = true
        await settle(parent)
        let sheet = try XCTUnwrap(parent.attachedSheet)
        defer {
            state.isPresented = false
            if sheet.sheetParent != nil { parent.endSheet(sheet) }
        }
        await settle(sheet)
        let screen = try XCTUnwrap(sheet.screen ?? parent.screen)
        let available = sheet.contentRect(forFrameRect: screen.visibleFrame.insetBy(dx: 20, dy: 20)).size
        let expected = NSSize(width: min(620, available.width), height: min(460, available.height))
        let initial = sheet.contentRect(forFrameRect: sheet.frame).size
        XCTAssertEqual(initial.width, expected.width, accuracy: 2)
        XCTAssertEqual(initial.height, expected.height, accuracy: 2)
        await settle(sheet)
        let subsequent = sheet.contentRect(forFrameRect: sheet.frame).size
        XCTAssertEqual(subsequent.width, initial.width, accuracy: 1)
        XCTAssertEqual(subsequent.height, initial.height, accuracy: 1)
        let host = try XCTUnwrap(sheet.contentView)
        let closeButton = try XCTUnwrap(descendants(NSButton.self, in: host).first {
            $0.keyEquivalent == "\u{1b}"
        })
        let viewport = sheet.convertToScreen(host.convert(host.bounds, to: nil))
        XCTAssertTrue(viewport.contains(sheet.convertToScreen(closeButton.convert(closeButton.bounds, to: nil))))
        try snapshot(host, name: "template-compact-presentation")
        XCTAssertTrue(store.articles.isEmpty)
    }

    private func assertNoPreviewControls(in host: NSView, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(descendants(NSSegmentedControl.self, in: host).isEmpty,
                      "The article form must provide direct editing without an Edit/Preview switch", file: file, line: line)
        XCTAssertFalse(descendants(NSButton.self, in: host).contains { ["预览", "Preview"].contains($0.title) },
                       file: file, line: line)
    }

    private func assertFieldCompletelyVisible(_ field: NSTextField, window: NSWindow,
                                              file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertGreaterThan(field.bounds.width, 0, file: file, line: line)
        XCTAssertGreaterThan(field.bounds.height, 0, file: file, line: line)
        // AppKit text fields can enlarge visibleRect beyond bounds to redraw
        // their bezel/focus treatment. Require containment, not equal sizes.
        XCTAssertTrue(field.visibleRect.insetBy(dx: -1, dy: -1).contains(field.bounds),
                      "The complete metadata field must remain visible", file: file, line: line)
        if let scroll = field.enclosingScrollView {
            let clip = scroll.contentView
            let clipRect = window.convertToScreen(clip.convert(clip.bounds, to: nil))
            let rect = window.convertToScreen(field.convert(field.bounds, to: nil))
            XCTAssertTrue(clipRect.insetBy(dx: -1, dy: -1).contains(rect),
                          "Each expanded field must fit within the metadata viewport", file: file, line: line)
        }
    }

    private func makeStore() throws -> ReadingLibraryStore {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "LiquidGlassImportLayoutTests-" + UUID().uuidString, isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return try ReadingLibraryStore(rootURL: root, bundledCollections: [])
    }

    private func makeItem(title: String, marker: String) -> ArticleImportItem {
        var draft = ArticleDraft()
        draft.title = title
        draft.body = marker + "\n\n" + Array(repeating: "A synthetic café paragraph with a clear reading viewport.",
                                               count: 30).joined(separator: "\n\n")
        return ArticleImportItem(draft: draft)
    }

    private func makeWindow<Content: View>(host: NSHostingView<Content>, size: NSSize) throws -> NSWindow {
        _ = NSApplication.shared
        if NSScreen.screens.isEmpty { throw XCTSkip("Native import layout requires a WindowServer session") }
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: 80, y: 80), size: size),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "Wordlinks disposable import layout check"
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = host
        window.orderBack(nil)
        return window
    }

    private func close(_ window: NSWindow) {
        window.orderOut(nil)
        window.contentView = nil
        window.close()
    }

    private func settle(_ window: NSWindow) async {
        for _ in 0..<15 {
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    private func assertFooterAndEditorVisible(in host: NSView, window: NSWindow,
                                              file: StaticString = #filePath, line: UInt = #line) throws {
        let viewport = window.convertToScreen(host.convert(host.bounds, to: nil))
        let buttons = descendants(NSButton.self, in: host).filter {
            $0.enclosingScrollView == nil && !$0.isHiddenOrHasHiddenAncestor
        }
        let cancel = try XCTUnwrap(buttons.first { $0.keyEquivalent == "\u{1b}" },
                                  "The native Cancel button must remain available", file: file, line: line)
        let add = try XCTUnwrap(buttons.first { $0.keyEquivalent == "\r" },
                               "The native default Add button must remain available", file: file, line: line)
        for button in [cancel, add] {
            let rect = window.convertToScreen(button.convert(button.bounds, to: nil))
            XCTAssertGreaterThan(rect.width, 0, file: file, line: line)
            XCTAssertGreaterThan(rect.height, 0, file: file, line: line)
            XCTAssertTrue(viewport.insetBy(dx: -1, dy: -1).contains(rect),
                          "Footer buttons must stay fully within the viewport", file: file, line: line)
        }
        let body = try XCTUnwrap(descendants(CardInputTextView.self, in: host).first {
            $0.accessibilityIdentifier() == "articleDraftBody"
        }, file: file, line: line)
        let scroll = try XCTUnwrap(body.enclosingScrollView, file: file, line: line)
        let bodyRect = window.convertToScreen(scroll.convert(scroll.bounds, to: nil))
        let footerTop = [cancel, add].map { window.convertToScreen($0.convert($0.bounds, to: nil)).maxY }.max()!
        XCTAssertGreaterThan(bodyRect.height, 30, "Body text must retain a usable viewport", file: file, line: line)
        XCTAssertTrue(viewport.insetBy(dx: -1, dy: -1).contains(bodyRect),
                      "Body editor must remain inside the viewport", file: file, line: line)
        XCTAssertGreaterThanOrEqual(bodyRect.minY, footerTop,
                                    "Long auxiliary text must not overlap footer controls", file: file, line: line)
        XCTAssertTrue(add.isEnabled, "A save failure must not disable retry for a valid draft", file: file, line: line)
    }

    private func descendants<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
        var result = (view as? T).map { [$0] } ?? []
        for child in view.subviews { result += descendants(type, in: child) }
        return result
    }

    private func snapshot(_ host: NSView, name: String) throws {
        guard let directory = ProcessInfo.processInfo.environment["WORDLINKS_UI_INSPECTION_DIR"],
              !directory.isEmpty else { return }
        let output = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: output.appendingPathComponent(name + ".png"), options: .atomic)
    }
}

@MainActor
private final class ImportSheetPresentation: ObservableObject {
    @Published var isPresented = false
}

private struct ImportSheetPresentationHost: View {
    @ObservedObject var state: ImportSheetPresentation
    let item: ArticleImportItem
    let store: ReadingLibraryStore
    var showsTemplate = false

    var body: some View {
        Text("Disposable sheet parent")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .sheet(isPresented: $state.isPresented) {
                if showsTemplate {
                    ArticleTemplatesSheet()
                } else {
                    ArticleImportSheet(items: [item], targetFolderID: nil) { _ in }
                        .environmentObject(store)
                }
            }
    }
}
