import AppKit
import SwiftUI
import XCTest
@testable import WordLinks

@MainActor
final class InlineStudyEditingTests: XCTestCase {
    func testMeaningGroupUsesCapturedIDsAndMergesOnlyByExistingAggregation() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let original = fixture.store.cards
        let ids = Array(original.prefix(2)).map(\.id)
        let change = try XCTUnwrap(fixture.store.updateCardFields(profileID: fixture.profileID,
            cardIDs: ids, field: .meaning, value: "second definition", expectedValue: "first definition"))
        XCTAssertEqual(Set(change.before.keys), Set(ids))
        XCTAssertEqual(fixture.store.cards.filter { ids.contains($0.id) }.map(\.meaning),
                       ["second definition", "second definition"])
        XCTAssertEqual(fixture.store.card(id: original[2].id), original[2])
        XCTAssertEqual(fixture.store.card(id: original[3].id), original[3])
        XCTAssertEqual(fixture.store.entries.count, 2)
        XCTAssertEqual(fixture.store.entries.first { $0.key == "word" }?.meanings.count, 1)
        for old in original.prefix(2) { assertHistory(fixture.store.card(id: old.id)!, equals: old) }
    }

    func testArticleFieldEditTouchesOnlyOneCardAndReaggregatesExpression() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let old = fixture.store.cards[0]
        let other = fixture.store.cards[1]
        try fixture.store.updateCardFields(profileID: fixture.profileID, cardIDs: [old.id],
                                          field: .expression, value: "another entry")
        XCTAssertEqual(fixture.store.card(id: old.id)?.expression, "another entry")
        XCTAssertEqual(fixture.store.card(id: other.id), other)
        XCTAssertEqual(fixture.store.entries.first { $0.key == "another entry" }?.cards.map(\.id), [old.id])
        assertHistory(fixture.store.card(id: old.id)!, equals: old)
    }

    func testDetachedCardFieldsEditWithoutChangingHistoricalData() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let card = fixture.store.cards[0]
        let article = try XCTUnwrap(fixture.store.article(id: card.articleID))
        let url = try fixture.store.articleFileURL(article.id)
        try "# Notes\n\nThe old source selection is gone.".write(to: url, atomically: true, encoding: .utf8)
        fixture.store.refreshArticleFiles()
        let detached = try XCTUnwrap(fixture.store.card(id: card.id))
        XCTAssertEqual(detached.isDetached, true)
        try fixture.store.updateCardFields(profileID: fixture.profileID, cardIDs: [card.id],
                                          field: .expression, value: "自由写法 🙂")
        try fixture.store.updateCardFields(profileID: fixture.profileID, cardIDs: [card.id],
                                          field: .meaning, value: "Definition in any language 日本語")
        let edited = try XCTUnwrap(fixture.store.card(id: card.id))
        assertHistory(edited, equals: detached)
        XCTAssertEqual(fixture.store.originalSentence(for: edited), fixture.store.originalSentence(for: detached))
    }

    func testBlankUnchangedAndEscapeDoNotWriteOrRegisterUndo() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let card = fixture.store.cards[0]
        let before = fixture.store.archive
        let backups = fixture.store.automaticBackups().count
        let manager = UndoManager()
        let coordinator = StudyInlineEditCoordinator()
        for draft in [card.meaning, " \t\n", "cancel this change"] {
            let owner = UUID()
            XCTAssertTrue(coordinator.begin(owner: owner, target: target(card, fixture), text: card.meaning,
                                            store: fixture.store, undoManager: manager))
            coordinator.updateDraft(draft, owner: owner)
            if draft == "cancel this change" {
                coordinator.cancelEditing()
                coordinator.resigned(owner: owner)
            } else { XCTAssertTrue(coordinator.finishEditing()) }
            XCTAssertFalse(coordinator.hasActiveEdit)
        }
        XCTAssertEqual(fixture.store.archive, before)
        XCTAssertEqual(fixture.store.automaticBackups().count, backups)
        XCTAssertFalse(manager.canUndo)
    }

    func testPersistenceFailureRetainsWholeGroupAndDraftThenRetryCommits() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let cards = Array(fixture.store.cards.prefix(2))
        let original = fixture.store.archive
        let coordinator = StudyInlineEditCoordinator()
        let manager = UndoManager()
        let owner = UUID()
        XCTAssertTrue(coordinator.begin(owner: owner,
            target: StudyInlineEditTarget(profileID: fixture.profileID, cardIDs: cards.map(\.id), field: .meaning),
            text: cards[0].meaning, store: fixture.store, undoManager: manager))
        coordinator.updateDraft("new group meaning", owner: owner)
        let backupDirectory = fixture.root.appendingPathComponent("Profiles/\(fixture.profileID)/Backups")
        try FileManager.default.removeItem(at: backupDirectory)
        try Data("blocks the backup directory".utf8).write(to: backupDirectory)
        XCTAssertFalse(coordinator.finishEditing())
        XCTAssertEqual(coordinator.draft, "new group meaning")
        XCTAssertNotNil(coordinator.errorMessage)
        XCTAssertEqual(fixture.store.archive, original)
        XCTAssertFalse(manager.canUndo)
        try FileManager.default.removeItem(at: backupDirectory)
        coordinator.retry()
        XCTAssertFalse(coordinator.hasActiveEdit)
        XCTAssertNil(coordinator.errorMessage)
        XCTAssertTrue(manager.canUndo)
        XCTAssertEqual(fixture.store.cards.filter { cards.map(\.id).contains($0.id) }.map(\.meaning),
                       ["new group meaning", "new group meaning"])
    }

    func testBatchUndoRedoUpdatesSharedArchiveAndRemainsBoundToOriginalProfile() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let cards = Array(fixture.store.cards.prefix(2))
        let manager = UndoManager()
        manager.groupsByEvent = false
        let coordinator = StudyInlineEditCoordinator()
        let owner = UUID()
        XCTAssertTrue(coordinator.begin(owner: owner,
            target: StudyInlineEditTarget(profileID: fixture.profileID, cardIDs: cards.map(\.id), field: .meaning),
            text: cards[0].meaning, store: fixture.store, undoManager: manager))
        coordinator.updateDraft("a grouped edit", owner: owner)
        manager.beginUndoGrouping()
        XCTAssertTrue(coordinator.finishEditing())
        manager.endUndoGrouping()
        XCTAssertEqual(fixture.store.entries.first { $0.key == "word" }?.meanings.first?.meaning, "a grouped edit")
        manager.undo()
        XCTAssertEqual(fixture.store.cards.filter { cards.map(\.id).contains($0.id) }.map(\.meaning),
                       ["first definition", "first definition"])
        XCTAssertTrue(manager.canRedo)
        manager.redo()
        XCTAssertEqual(fixture.store.cards.filter { cards.map(\.id).contains($0.id) }.map(\.meaning),
                       ["a grouped edit", "a grouped edit"])

        let newProfile = try fixture.store.createProfile(name: "Other profile")
        let untouched = fixture.store.archive
        manager.undo()
        XCTAssertEqual(fixture.store.archive, untouched)
        XCTAssertEqual(fixture.store.activeProfileID, newProfile.id)
        try fixture.store.selectProfile(fixture.profileID)
        XCTAssertEqual(fixture.store.cards.filter { cards.map(\.id).contains($0.id) }.map(\.meaning),
                       ["first definition", "first definition"])
    }

    func testMissingIDAndConcurrentFieldChangeFailWithoutPartialCommit() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let first = fixture.store.cards[0]
        let before = fixture.store.archive
        XCTAssertThrowsError(try fixture.store.updateCardFields(profileID: fixture.profileID,
            cardIDs: [first.id, UUID()], field: .meaning, value: "bad partial"))
        XCTAssertThrowsError(try fixture.store.updateCardFields(profileID: fixture.profileID,
            cardIDs: [first.id], field: .meaning, value: "bad stale", expectedValue: "not current"))
        XCTAssertEqual(fixture.store.archive, before)
    }

    func testFailedUndoAndRedoRetryThroughTheCorrectSystemStack() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let card = fixture.store.cards[0]
        let manager = UndoManager()
        manager.groupsByEvent = false
        let coordinator = StudyInlineEditCoordinator()
        let owner = UUID()
        XCTAssertTrue(coordinator.begin(owner: owner, target: target(card, fixture), text: card.meaning,
                                        store: fixture.store, undoManager: manager))
        coordinator.updateDraft("saved change", owner: owner)
        manager.beginUndoGrouping()
        XCTAssertTrue(coordinator.finishEditing())
        manager.endUndoGrouping()

        let backups = fixture.root.appendingPathComponent("Profiles/\(fixture.profileID)/Backups")
        func blockPersistence() throws {
            try FileManager.default.removeItem(at: backups)
            try Data("blocks backup writes".utf8).write(to: backups)
        }
        try blockPersistence()
        manager.undo()
        XCTAssertEqual(fixture.store.card(id: card.id)?.meaning, "saved change")
        XCTAssertNotNil(coordinator.errorMessage)
        XCTAssertTrue(coordinator.canDismissError)
        try FileManager.default.removeItem(at: backups)
        coordinator.retry()
        XCTAssertNil(coordinator.errorMessage)
        XCTAssertEqual(fixture.store.card(id: card.id)?.meaning, card.meaning)
        XCTAssertTrue(manager.canRedo)
        manager.redo()
        XCTAssertEqual(fixture.store.card(id: card.id)?.meaning, "saved change")

        manager.undo()
        try blockPersistence()
        manager.redo()
        XCTAssertEqual(fixture.store.card(id: card.id)?.meaning, card.meaning)
        XCTAssertNotNil(coordinator.errorMessage)
        try FileManager.default.removeItem(at: backups)
        coordinator.retry()
        XCTAssertNil(coordinator.errorMessage)
        XCTAssertEqual(fixture.store.card(id: card.id)?.meaning, "saved change")
        XCTAssertTrue(manager.canUndo)
        manager.undo()
        XCTAssertEqual(fixture.store.card(id: card.id)?.meaning, card.meaning)
    }

    func testDismissingPermanentlyFailedUndoKeepsDataAndSystemHistoryWithoutBlockingWindow() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let card = fixture.store.cards[0]
        let coordinator = StudyInlineEditCoordinator()
        let manager = UndoManager()
        manager.groupsByEvent = false
        let owner = UUID()
        XCTAssertTrue(coordinator.begin(owner: owner, target: target(card, fixture), text: card.meaning,
                                        store: fixture.store, undoManager: manager))
        coordinator.updateDraft("saved change", owner: owner)
        manager.beginUndoGrouping()
        XCTAssertTrue(coordinator.finishEditing())
        manager.endUndoGrouping()
        try fixture.store.updateCardFields(profileID: fixture.profileID, cardIDs: [card.id],
                                           field: .meaning, value: "changed elsewhere")
        let saved = fixture.store.archive
        manager.undo()
        XCTAssertNotNil(coordinator.errorMessage)
        XCTAssertFalse(coordinator.finishEditing())
        XCTAssertTrue(coordinator.canDismissError)
        coordinator.dismissError()
        XCTAssertNil(coordinator.errorMessage)
        XCTAssertTrue(coordinator.finishEditing())
        XCTAssertEqual(fixture.store.archive, saved)
        XCTAssertTrue(manager.canUndo, "The failed operation stays in the system history after dismissing its error")
    }

    func testReusedDetailWithSameTextGetsANewEditorBoundToItsOwnCard() throws {
        _ = NSApplication.shared
        if NSScreen.screens.isEmpty { throw XCTSkip("Native inline editing requires WindowServer") }
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let first = fixture.store.cards[0]
        let second = fixture.store.cards[1]
        let coordinator = StudyInlineEditCoordinator()
        func content(for card: StudyCard) -> StudyInlineEditableText {
            StudyInlineEditableText(text: card.meaning, target: target(card, fixture),
                store: fixture.store, coordinator: coordinator, font: .systemFont(ofSize: 15),
                placeholder: "Definition", label: "Definition")
        }
        let host = InlineInteractionHostingView(rootView: content(for: first))
        let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 320, height: 100),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderBack(nil)
        defer { window.orderOut(nil); window.contentView = nil; window.close() }
        settle(host)
        let previous = try XCTUnwrap(findTextView(host))
        previous.onBegin?()
        previous.insertText("belongs only to the first card", replacementRange: previous.selectedRange())
        XCTAssertTrue(coordinator.hasActiveEdit)
        host.rootView = content(for: second)
        settle(host)
        let current = try XCTUnwrap(findTextView(host))
        XCTAssertFalse(current === previous)
        XCTAssertNotEqual(current.owner, previous.owner)
        XCTAssertFalse(current.isEditable)
        XCTAssertEqual(current.string, second.meaning)
        XCTAssertEqual(fixture.store.card(id: first.id)?.meaning, "belongs only to the first card")
        XCTAssertEqual(fixture.store.card(id: second.id), second)
        XCTAssertFalse(coordinator.hasActiveEdit)
    }

    func testNativeTextConsumesFirstClickStartsOnlyOnDoubleClickAndKeepsNativeEditing() throws {
        _ = NSApplication.shared
        if NSScreen.screens.isEmpty { throw XCTSkip("Native inline editing requires WindowServer") }
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let card = fixture.store.cards[0]
        let coordinator = StudyInlineEditCoordinator()
        var navigations = 0
        let host = InlineInteractionHostingView(rootView:
            VStack(alignment: .leading) {
                StudyInlineEditableText(text: card.meaning, target: target(card, fixture),
                    store: fixture.store, coordinator: coordinator,
                    font: .systemFont(ofSize: 15, weight: .medium), placeholder: "Definition", label: "Definition")
                Text("Other card surface").frame(maxWidth: .infinity, minHeight: 40)
            }
            .padding(20).frame(width: 380, height: 160)
            .contentShape(Rectangle()).onTapGesture { navigations += 1 })
        let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 380, height: 160),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil; window.close() }
        settle(host)
        let textView = try XCTUnwrap(findTextView(host))
        let textPoint = textView.convert(NSPoint(x: 4, y: 6), to: nil)
        click(window, point: textPoint, count: 1)
        XCTAssertFalse(coordinator.hasActiveEdit)
        XCTAssertEqual(navigations, 0)
        click(window, point: textPoint, count: 2)
        settle(host)
        XCTAssertTrue(coordinator.hasActiveEdit)
        XCTAssertEqual(navigations, 0)
        XCTAssertEqual(textView.selectedRange(), NSRange(location: 0, length: (card.meaning as NSString).length))
        textView.insertText("draft", replacementRange: textView.selectedRange())
        XCTAssertEqual(textView.string, "draft")
        textView.undoManager?.undo()
        XCTAssertEqual(textView.string, card.meaning, "The focused editor owns ordinary text undo")
        textView.cancelOperation(nil)
        XCTAssertFalse(coordinator.hasActiveEdit)
        XCTAssertEqual(fixture.store.card(id: card.id)?.meaning, card.meaning)
        XCTAssertNil(textView.hitTest(textView.convert(NSPoint(x: textView.bounds.maxX - 2, y: 5), to: textView.superview)),
                     "Trailing blank space must remain available to card navigation")
        click(window, point: host.convert(NSPoint(x: 190, y: 95), to: nil), count: 1)
        settle(host)
        XCTAssertEqual(navigations, 1, "Non-text card surface retains navigation")

        let destination = NSTextField(frame: NSRect(x: 20, y: 130, width: 180, height: 22))
        host.addSubview(destination)
        textView.onBegin?()
        XCTAssertTrue(coordinator.hasActiveEdit)
        textView.insertText("committed on blur", replacementRange: textView.selectedRange())
        let backupsBeforeBlur = fixture.store.automaticBackups().count
        XCTAssertTrue(window.makeFirstResponder(destination))
        let destinationEditor = try XCTUnwrap(destination.currentEditor())
        XCTAssertTrue(window.firstResponder === destinationEditor,
                      "Committing on resign must not recursively clear the new control's focus")
        XCTAssertEqual(fixture.store.card(id: card.id)?.meaning, "committed on blur")
        XCTAssertFalse(coordinator.hasActiveEdit)
        XCTAssertEqual(fixture.store.automaticBackups().count, backupsBeforeBlur + 1)
        coordinator.resigned(owner: textView.owner)
        XCTAssertEqual(fixture.store.automaticBackups().count, backupsBeforeBlur + 1,
                       "A subsequent resign callback must not commit the same edit again")
    }

    private struct Fixture {
        let root: URL
        let store: ReadingLibraryStore
        let profileID: UUID
        func cleanup() { try? FileManager.default.removeItem(at: root) }
    }

    private func makeFixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = try ReadingLibraryStore(rootURL: root, bundledCollections: [])
        let article = try store.addMarkdown(markdown: "# Notes\n\nOne word, another word, a third term, a fourth word.", sourceName: "notes.md")
        let source = article.text as NSString
        let first = source.range(of: "word")
        let second = source.range(of: "word", range: NSRange(location: first.location + first.length,
                                                            length: source.length - first.location - first.length))
        _ = try store.saveCard(articleID: article.id, range: first, expression: "word", meaning: "first definition")
        _ = try store.saveCard(articleID: article.id, range: second, expression: "WORD", meaning: "first definition")
        _ = try store.saveCard(articleID: article.id, range: source.range(of: "term"), expression: "term", meaning: "second definition")
        _ = try store.saveCard(articleID: article.id, range: source.range(of: "word", options: .backwards),
                               expression: "Word", meaning: "second definition")
        return Fixture(root: root, store: store, profileID: store.activeProfileID)
    }

    private func target(_ card: StudyCard, _ fixture: Fixture) -> StudyInlineEditTarget {
        StudyInlineEditTarget(profileID: fixture.profileID, cardIDs: [card.id], field: .meaning)
    }

    private func assertHistory(_ card: StudyCard, equals original: StudyCard, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(card.id, original.id, file: file, line: line)
        XCTAssertEqual(card.articleID, original.articleID, file: file, line: line)
        XCTAssertEqual(card.start, original.start, file: file, line: line)
        XCTAssertEqual(card.end, original.end, file: file, line: line)
        XCTAssertEqual(card.selectedText, original.selectedText, file: file, line: line)
        XCTAssertEqual(card.createdAt, original.createdAt, file: file, line: line)
        XCTAssertEqual(card.originalSentence, original.originalSentence, file: file, line: line)
        XCTAssertEqual(card.isDetached, original.isDetached, file: file, line: line)
    }

    private func findTextView(_ view: NSView) -> InlineStudyTextView? {
        if let result = view as? InlineStudyTextView { return result }
        for child in view.subviews { if let result = findTextView(child) { return result } }
        return nil
    }

    private func settle(_ view: NSView) {
        view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.08))
        view.layoutSubtreeIfNeeded()
    }

    private func click(_ window: NSWindow, point: NSPoint, count: Int) {
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            if let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: count, clickCount: count, pressure: type == .leftMouseDown ? 1 : 0) {
                NSApp.sendEvent(event)
            }
        }
    }
}

/// XCTest is not the active application. Accepting its synthetic first mouse
/// lets the normal SwiftUI gesture recognizer exercise the active-window path.
private final class InlineInteractionHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
