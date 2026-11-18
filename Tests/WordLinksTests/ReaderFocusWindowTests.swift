import AppKit
import SwiftUI
import XCTest
@testable import WordLinks

@MainActor
final class ReaderFocusWindowTests: XCTestCase {
    func testFocusRestoresTwoAndThreeColumnLayoutsWithoutResizingTheWindowDuringReversals() throws {
        try requireWindowServer()
        let finished = expectation(description: "Native focus restoration keeps the original window and columns")
        let task = Task { @MainActor in
            defer { finished.fulfill() }
            for sidebarWasCollapsed in [false, true] {
                let reader = NSView()
                reader.identifier = ReaderTextViewIdentity.article
                let fixture = makeSplitWindow(reader: reader)
                // Match the production SwiftUI window, whose content extends
                // into a unified titlebar without a separate visible title row.
                fixture.window.styleMask.insert(.fullSizeContentView)
                fixture.window.toolbarStyle = .unified
                fixture.window.titleVisibility = .hidden
                let coordinator = ReaderFocusWindow.Coordinator()
                coordinator.chromeIdleDelay = 60
                defer {
                    coordinator.detach()
                    close(fixture.window)
                }
                fixture.sidebar.canCollapse = true
                fixture.sidebar.isCollapsed = sidebarWasCollapsed
                coordinator.update(isActive: false, backgroundColor: .textBackgroundColor,
                                   onToggle: {}, onRegenerateIntensiveReading: {})
                coordinator.attach(to: fixture.window)
                // Attachment configures the native toolbar's display mode,
                // which can change its initial titlebar height. Measure the
                // baseline only after that independent setup has settled.
                await settle(fixture.window)
                XCTAssertEqual(fixture.window.toolbar?.displayMode, .iconOnly)
                let originalWindowFrame = fixture.window.frame
                let sidebarBehavior = fixture.sidebar.collapseBehavior
                let contentBehavior = fixture.content.collapseBehavior

                coordinator.update(isActive: true, backgroundColor: .textBackgroundColor,
                                   onToggle: {}, onRegenerateIntensiveReading: {})
                await settle(fixture.window, preserving: originalWindowFrame)
                XCTAssertTrue(fixture.sidebar.isCollapsed)
                XCTAssertTrue(fixture.content.isCollapsed)
                coordinator.update(isActive: false, backgroundColor: .textBackgroundColor,
                                   onToggle: {}, onRegenerateIntensiveReading: {})
                await settle(fixture.window, preserving: originalWindowFrame)
                XCTAssertEqual(fixture.sidebar.isCollapsed, sidebarWasCollapsed)
                XCTAssertFalse(fixture.content.isCollapsed)

                // Reverse a live native transition rather than starting only
                // after every previous animation has already finished.
                for isActive in [true, false, true, false] {
                    coordinator.update(isActive: isActive, backgroundColor: .textBackgroundColor,
                                       onToggle: {}, onRegenerateIntensiveReading: {})
                    fixture.window.contentView?.layoutSubtreeIfNeeded()
                    try? await Task.sleep(nanoseconds: 40_000_000)
                }
                await settle(fixture.window, preserving: originalWindowFrame)
                XCTAssertEqual(fixture.sidebar.isCollapsed, sidebarWasCollapsed,
                               "Rapid reversals must retain the user's original two- or three-column layout")
                XCTAssertFalse(fixture.content.isCollapsed)
                XCTAssertFalse(fixture.detail.isCollapsed)
                XCTAssertTrue(fixture.sidebar.canCollapse)
                XCTAssertFalse(fixture.content.canCollapse)
                XCTAssertEqual(fixture.sidebar.collapseBehavior, sidebarBehavior)
                XCTAssertEqual(fixture.content.collapseBehavior, contentBehavior)
            }
        }
        wait(for: [finished], timeout: 10)
        task.cancel()
    }

    func testRepeatedFocusUpdatesRestoreOriginallyCollapsedColumnsAndNativeCollapseConfiguration() throws {
        try requireWindowServer()
        let finished = expectation(description: "Original native split state restored")
        let task = Task { @MainActor in
            defer { finished.fulfill() }
            let reader = NSView()
            reader.identifier = ReaderTextViewIdentity.article
            let fixture = makeSplitWindow(reader: reader)
            let coordinator = ReaderFocusWindow.Coordinator()
            coordinator.chromeIdleDelay = 60
            defer {
                coordinator.detach()
                close(fixture.window)
            }
            fixture.sidebar.canCollapse = true
            fixture.sidebar.collapseBehavior = .useConstraints
            fixture.sidebar.isCollapsed = true
            fixture.content.collapseBehavior = .preferResizingSplitViewWithFixedSiblings
            let originalContentBehavior = fixture.content.collapseBehavior
            await settle(fixture.window)

            // The second cycle must take a fresh snapshot of the same restored
            // native state, rather than the temporary focus configuration.
            for _ in 0..<2 {
                coordinator.update(isActive: true, backgroundColor: .textBackgroundColor,
                                   onToggle: {}, onRegenerateIntensiveReading: {})
                coordinator.attach(to: fixture.window)
                await settle(fixture.window)
                XCTAssertTrue(fixture.sidebar.isCollapsed)
                XCTAssertTrue(fixture.content.isCollapsed)
                XCTAssertFalse(fixture.detail.isCollapsed)

                for _ in 0..<3 {
                    coordinator.update(isActive: true, backgroundColor: .textBackgroundColor,
                                       onToggle: {}, onRegenerateIntensiveReading: {})
                    coordinator.attach(to: fixture.window)
                }
                coordinator.update(isActive: false, backgroundColor: .textBackgroundColor,
                                   onToggle: {}, onRegenerateIntensiveReading: {})
                await settle(fixture.window)

                XCTAssertTrue(fixture.sidebar.isCollapsed, "Focus must preserve a sidebar already hidden by the user")
                XCTAssertTrue(fixture.sidebar.canCollapse)
                XCTAssertEqual(fixture.sidebar.collapseBehavior, .useConstraints)
                XCTAssertFalse(fixture.content.isCollapsed)
                XCTAssertFalse(fixture.content.canCollapse)
                XCTAssertEqual(fixture.content.collapseBehavior, originalContentBehavior)
                XCTAssertFalse(fixture.detail.isCollapsed)
            }
        }
        wait(for: [finished], timeout: 10)
        task.cancel()
    }

    func testFullscreenReconciliationKeepsFocusColumnsHiddenWithoutReplacingTheOriginalSnapshot() throws {
        try requireWindowServer()
        let finished = expectation(description: "Full-screen focus split state reconciled")
        let task = Task { @MainActor in
            defer { finished.fulfill() }
            let reader = NSView()
            reader.identifier = ReaderTextViewIdentity.article
            let fixture = makeSplitWindow(reader: reader)
            let coordinator = ReaderFocusWindow.Coordinator()
            coordinator.chromeIdleDelay = 60
            defer {
                coordinator.detach()
                close(fixture.window)
            }
            let originalSidebarBehavior = fixture.sidebar.collapseBehavior
            let originalContentBehavior = fixture.content.collapseBehavior
            coordinator.update(isActive: true, backgroundColor: .textBackgroundColor,
                               onToggle: {}, onRegenerateIntensiveReading: {})
            coordinator.attach(to: fixture.window)
            await settle(fixture.window)

            // AppKit can rebuild a split hierarchy around a full-screen change.
            // Check the notification route without changing the user's Space.
            for name in [NSWindow.didEnterFullScreenNotification, NSWindow.didExitFullScreenNotification] {
                fixture.sidebar.isCollapsed = false
                fixture.content.isCollapsed = false
                NotificationCenter.default.post(name: name, object: fixture.window)
                XCTAssertTrue(fixture.sidebar.isCollapsed, "Reconciliation must finish without starting another split animation")
                XCTAssertTrue(fixture.content.isCollapsed)
                XCTAssertFalse(fixture.detail.isCollapsed)
            }

            coordinator.update(isActive: false, backgroundColor: .textBackgroundColor,
                               onToggle: {}, onRegenerateIntensiveReading: {})
            await settle(fixture.window)
            XCTAssertFalse(fixture.sidebar.isCollapsed)
            XCTAssertFalse(fixture.content.isCollapsed)
            XCTAssertFalse(fixture.sidebar.canCollapse)
            XCTAssertFalse(fixture.content.canCollapse)
            XCTAssertEqual(fixture.sidebar.collapseBehavior, originalSidebarBehavior)
            XCTAssertEqual(fixture.content.collapseBehavior, originalContentBehavior)
        }
        wait(for: [finished], timeout: 10)
        task.cancel()
    }

    func testFocusCollapsesBothLibraryColumnsForOriginalAndIntensiveReadersAndKeepsToolbar() async throws {
        try requireWindowServer()
        for identity in [ReaderTextViewIdentity.article, ReaderTextViewIdentity.intensive] {
            let reader = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 600))
            reader.identifier = identity
            let fixture = makeSplitWindow(reader: reader)
            let coordinator = ReaderFocusWindow.Coordinator()
            defer {
                coordinator.detach()
                close(fixture.window)
            }
            let originalTitleVisibility = fixture.window.titleVisibility
            let originalBackground = fixture.window.backgroundColor
            let originalSidebarCollapseBehavior = fixture.sidebar.collapseBehavior
            let originalContentCollapseBehavior = fixture.content.collapseBehavior

            coordinator.update(isActive: true, backgroundColor: .textBackgroundColor,
                               onToggle: {}, onRegenerateIntensiveReading: {})
            coordinator.attach(to: fixture.window)
            await settle(fixture.window)

            XCTAssertTrue(fixture.sidebar.isCollapsed, "Focus must hide the library sidebar for \(identity.rawValue)")
            XCTAssertTrue(fixture.content.isCollapsed, "Focus must hide the article list for \(identity.rawValue)")
            XCTAssertFalse(fixture.detail.isCollapsed)
            XCTAssertEqual(fixture.window.toolbar?.isVisible, true)
            XCTAssertEqual(fixture.window.titleVisibility, .hidden)
            XCTAssertFalse(try XCTUnwrap(fixture.window.standardWindowButton(.closeButton)).isHidden)

            coordinator.update(isActive: false, backgroundColor: .textBackgroundColor,
                               onToggle: {}, onRegenerateIntensiveReading: {})
            await settle(fixture.window)

            XCTAssertFalse(fixture.sidebar.isCollapsed)
            XCTAssertFalse(fixture.content.isCollapsed)
            XCTAssertFalse(fixture.sidebar.canCollapse)
            XCTAssertFalse(fixture.content.canCollapse)
            XCTAssertEqual(fixture.sidebar.collapseBehavior, originalSidebarCollapseBehavior)
            XCTAssertEqual(fixture.content.collapseBehavior, originalContentCollapseBehavior)
            XCTAssertEqual(fixture.window.toolbar?.isVisible, true)
            XCTAssertEqual(fixture.window.titleVisibility, originalTitleVisibility)
            XCTAssertEqual(fixture.window.backgroundColor, originalBackground)
        }
    }

    func testSwitchingTheFocusedArticleBetweenCachedIntensiveAndOriginalKeepsColumnsHidden() async throws {
        try requireWindowServer()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try ReadingLibraryStore(rootURL: root, bundledCollections: [])
        let article = try store.addMarkdown(markdown: "# Focus test\n\nA synthetic sentence.", sourceName: "focus.md")
        let suite = "ReaderFocusWindowTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AISettingsStore(defaults: defaults, credentials: FocusTestCredentials(),
                                       language: AppLanguageStore(defaults: defaults),
                                       customCredentials: FocusTestProfileCredentials(),
                                       customClient: FocusTestAIClient())
        _ = try settings.saveCustomProfile(name: "Synthetic focus service", baseURL: "https://focus.example.invalid/v1",
                                           apiKey: "", model: "synthetic-model", authentication: .none)
        for range in SelectionContext.sentenceRanges(in: article.text, articleTitle: article.title) {
            let source = (article.text as NSString).substring(with: range)
            try store.saveIntensiveTranslation(IntensiveReadingTranslation(sourceSentence: source,
                translation: "合成译文。", alignments: [], generatedAt: Date()),
                articleID: article.id, targetLanguage: settings.studyLanguage)
        }
        let model = IntensiveReadingModel(article: article, profileID: store.archive.id, store: store, settings: settings)
        model.setActivated(true)
        XCTAssertTrue(model.isActivated)
        let host = NSHostingView(rootView: ArticleReaderView(article: article, store: store, aiSettings: settings,
            initialOffset: 0, isDistractionFree: true, onExitDistractionFree: {}, intensiveModel: model)
            .environmentObject(store).environmentObject(settings))
        let fixture = makeSplitWindow(reader: host)
        let coordinator = ReaderFocusWindow.Coordinator()
        defer {
            coordinator.detach()
            close(fixture.window)
        }
        await settle(fixture.window)
        XCTAssertNotNil(reader(with: ReaderTextViewIdentity.intensive, in: host),
                        "Exercise the production intensive reader inside the split hierarchy")
        coordinator.update(isActive: true, backgroundColor: .textBackgroundColor,
                           onToggle: {}, onRegenerateIntensiveReading: {})
        coordinator.attach(to: fixture.window)
        await settle(fixture.window)
        XCTAssertTrue(fixture.sidebar.isCollapsed)
        XCTAssertTrue(fixture.content.isCollapsed)

        for enabled in [false, true, false] {
            model.setActivated(enabled)
            await settle(fixture.window)
            XCTAssertNotNil(reader(with: enabled ? ReaderTextViewIdentity.intensive : ReaderTextViewIdentity.article,
                                  in: host))
            XCTAssertTrue(fixture.sidebar.isCollapsed)
            XCTAssertTrue(fixture.content.isCollapsed)
            XCTAssertEqual(fixture.window.toolbar?.isVisible, true)
        }
    }

    func testFixedIconToolbarSuppressesChromeMenusAndKeepsTheIntensiveTargetDistinct() throws {
        try requireWindowServer()
        let fixture = makeSplitWindow(reader: NSView())
        let delegate = FocusToolbarDelegate()
        defer { withExtendedLifetime(delegate) {} }
        let toolbar = try XCTUnwrap(fixture.window.toolbar)
        toolbar.delegate = delegate
        for identifier in ["reader.focus", "reader.intensive", "reader.settings"] {
            toolbar.insertItem(withItemIdentifier: NSToolbarItem.Identifier(identifier), at: toolbar.items.count)
        }
        toolbar.allowsUserCustomization = true
        if #available(macOS 15.0, *) { toolbar.allowsDisplayModeCustomization = true }
        toolbar.displayMode = .iconAndLabel
        let coordinator = ReaderFocusWindow.Coordinator()
        defer {
            coordinator.detach()
            close(fixture.window)
        }
        coordinator.update(isActive: false, backgroundColor: .textBackgroundColor,
                           onToggle: {}, onRegenerateIntensiveReading: {})
        coordinator.attach(to: fixture.window)
        fixture.window.contentView?.layoutSubtreeIfNeeded()
        fixture.window.update()

        XCTAssertEqual(toolbar.items.count, 3, "The synthetic toolbar must materialize all three custom controls")
        XCTAssertFalse(toolbar.allowsUserCustomization)
        if #available(macOS 15.0, *) { XCTAssertFalse(toolbar.allowsDisplayModeCustomization) }
        XCTAssertEqual(toolbar.displayMode, .iconOnly)
        let titlebarPoint = NSPoint(x: fixture.window.frame.width / 2,
                                   y: (fixture.window.contentLayoutRect.maxY + fixture.window.frame.height) / 2)
        XCTAssertTrue(coordinator.isWindowChromeEvent(rightClick(at: titlebarPoint, in: fixture.window)))
        XCTAssertFalse(coordinator.isWindowChromeEvent(rightClick(at: NSPoint(x: 300, y: 100), in: fixture.window)),
                       "Article and library context menus must retain native event handling")

        for item in toolbar.items {
            let view = try XCTUnwrap(item.view)
            let point = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
            let event = rightClick(at: point, in: fixture.window)
            XCTAssertTrue(coordinator.isWindowChromeEvent(event))
            if item.itemIdentifier.rawValue == "reader.intensive" {
                XCTAssertTrue(coordinator.intensiveToolbarItemView(for: event) === view,
                              "The stable item ID must work independently of localized toolbar labels")
                let controlClick = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown,
                    location: point, modifierFlags: [.control], timestamp: 0,
                    windowNumber: fixture.window.windowNumber, context: nil,
                    eventNumber: 0, clickCount: 1, pressure: 1))
                XCTAssertTrue(coordinator.intensiveToolbarItemView(for: controlClick) === view)
                for outside in [NSPoint(x: view.bounds.minX - 1, y: view.bounds.midY),
                                NSPoint(x: view.bounds.maxX + 1, y: view.bounds.midY)] {
                    XCTAssertNil(coordinator.intensiveToolbarItemView(for:
                        rightClick(at: view.convert(outside, to: nil), in: fixture.window)),
                        "The intensive menu must not extend into a neighboring control or toolbar whitespace")
                }
            } else {
                XCTAssertNil(coordinator.intensiveToolbarItemView(for: event))
            }
        }

        let otherWindow = makeSplitWindow(reader: NSView())
        defer { close(otherWindow.window) }
        let foreignEvent = rightClick(at: titlebarPoint, in: otherWindow.window)
        XCTAssertFalse(coordinator.isWindowChromeEvent(foreignEvent),
                       "Chrome suppression must stay within the attached window")
        XCTAssertNil(coordinator.intensiveToolbarItemView(for: foreignEvent))

        let replacement = NSToolbar(identifier: "replacement-focus-test")
        replacement.allowsUserCustomization = true
        if #available(macOS 15.0, *) { replacement.allowsDisplayModeCustomization = true }
        replacement.displayMode = .iconAndLabel
        fixture.window.toolbar = replacement
        coordinator.attach(to: fixture.window)
        XCTAssertFalse(replacement.allowsUserCustomization)
        if #available(macOS 15.0, *) { XCTAssertFalse(replacement.allowsDisplayModeCustomization) }
        XCTAssertEqual(replacement.displayMode, .iconOnly)
    }

    func testOwnedToolbarChildWindowKeepsExactContextTargetsAndForeignChildrenRemainUnchanged() throws {
        try requireWindowServer()
        let fixture = makeSplitWindow(reader: NSView())
        let delegate = FocusToolbarDelegate()
        defer { withExtendedLifetime(delegate) {} }
        let toolbar = NSToolbar(identifier: "owned-toolbar-child-" + UUID().uuidString)
        toolbar.delegate = delegate
        fixture.window.toolbar = toolbar
        let coordinator = ReaderFocusWindow.Coordinator()
        defer {
            coordinator.detach()
            close(fixture.window)
        }
        coordinator.update(isActive: false, backgroundColor: .textBackgroundColor,
                           onToggle: {}, onRegenerateIntensiveReading: {})
        coordinator.attach(to: fixture.window)
        fixture.window.contentView?.layoutSubtreeIfNeeded()
        fixture.window.update()
        let item = try XCTUnwrap(toolbar.items.first(where: {
            $0.itemIdentifier.rawValue == "reader.intensive"
        }), "The dedicated toolbar must contain its synthetic intensive item")
        let view = try XCTUnwrap(item.view)
        let child = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 240, height: 52),
                             styleMask: .borderless, backing: .buffered, defer: false)
        child.isReleasedWhenClosed = false
        fixture.window.addChildWindow(child, ordered: .above)
        child.contentView?.addSubview(view)
        view.setFrameOrigin(NSPoint(x: 80, y: 12))
        defer {
            fixture.window.removeChildWindow(child)
            close(child)
        }
        let center = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
        let event = rightClick(at: center, in: child)
        XCTAssertTrue(coordinator.isWindowChromeEvent(event))
        XCTAssertTrue(coordinator.intensiveToolbarItemView(for: event) === view,
                      "Full-screen toolbar hosting must use the event's own window coordinate system")
        XCTAssertNil(coordinator.intensiveToolbarItemView(for:
            rightClick(at: NSPoint(x: 5, y: 10), in: child)))
        let foreignChild = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 80),
                                    styleMask: .borderless, backing: .buffered, defer: false)
        foreignChild.isReleasedWhenClosed = false
        fixture.window.addChildWindow(foreignChild, ordered: .above)
        defer {
            fixture.window.removeChildWindow(foreignChild)
            close(foreignChild)
        }
        XCTAssertFalse(coordinator.isWindowChromeEvent(rightClick(at: center, in: foreignChild)),
                       "Attached popovers and other child windows retain their own input handling")
    }

    func testFocusChromeHidesTheNativeToolbarAndWindowButtonsTogetherAndRevealsOnActivity() async throws {
        try requireWindowServer()
        let reader = NSView()
        reader.identifier = ReaderTextViewIdentity.article
        let fixture = makeSplitWindow(reader: reader)
        let coordinator = ReaderFocusWindow.Coordinator()
        coordinator.chromeIdleDelay = 0.03
        let originalInsets = NSEdgeInsets(top: 7, left: 3, bottom: 4, right: 5)
        fixture.window.contentView?.additionalSafeAreaInsets = originalInsets
        let originalMouseMovedEvents = fixture.window.acceptsMouseMovedEvents
        let originalTitleVisibility = fixture.window.titleVisibility
        defer {
            coordinator.detach()
            close(fixture.window)
        }
        coordinator.update(isActive: true, backgroundColor: .textBackgroundColor,
                           onToggle: {}, onRegenerateIntensiveReading: {})
        coordinator.attach(to: fixture.window)
        XCTAssertTrue(fixture.window.acceptsMouseMovedEvents)
        let visibleChromeHeight = fixture.window.frame.height - fixture.window.contentLayoutRect.maxY

        if !NSWorkspace.shared.isVoiceOverEnabled {
            await settle(fixture.window)
            XCTAssertFalse(coordinator.focusChromeIsVisible, "Idle focus must hide without another user action")
            XCTAssertEqual(fixture.window.toolbar?.isVisible, false)
        }

        coordinator.setFocusChromeVisible(false, animated: false)
        XCTAssertFalse(coordinator.focusChromeIsVisible)
        XCTAssertEqual(fixture.window.toolbar?.isVisible, false)
        let hiddenChromeHeight = fixture.window.frame.height - fixture.window.contentLayoutRect.maxY
        var reservedInsets = originalInsets
        reservedInsets.top += max(0, visibleChromeHeight - hiddenChromeHeight)
        assertInsets(try XCTUnwrap(fixture.window.contentView).additionalSafeAreaInsets, equal: reservedInsets)
        for type in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            if let button = fixture.window.standardWindowButton(type) { XCTAssertTrue(button.isHidden) }
        }

        let move = try XCTUnwrap(NSEvent.mouseEvent(with: .mouseMoved, location: NSPoint(x: 300, y: 200),
            modifierFlags: [], timestamp: 0, windowNumber: fixture.window.windowNumber, context: nil,
            eventNumber: 0, clickCount: 0, pressure: 0))
        coordinator.recordActivity(move)
        XCTAssertTrue(coordinator.focusChromeIsVisible)
        XCTAssertEqual(fixture.window.toolbar?.isVisible, true)
        XCTAssertFalse(try XCTUnwrap(fixture.window.standardWindowButton(.closeButton)).isHidden)
        assertInsets(try XCTUnwrap(fixture.window.contentView).additionalSafeAreaInsets, equal: originalInsets)

        coordinator.setFocusChromeVisible(false, animated: false)
        coordinator.update(isActive: false, backgroundColor: .textBackgroundColor,
                           onToggle: {}, onRegenerateIntensiveReading: {})
        XCTAssertEqual(fixture.window.toolbar?.isVisible, true)
        XCTAssertFalse(try XCTUnwrap(fixture.window.standardWindowButton(.closeButton)).isHidden)
        XCTAssertEqual(fixture.window.titleVisibility, originalTitleVisibility)
        XCTAssertEqual(fixture.window.acceptsMouseMovedEvents, originalMouseMovedEvents)
        assertInsets(try XCTUnwrap(fixture.window.contentView).additionalSafeAreaInsets, equal: originalInsets)
    }

    private func assertInsets(_ actual: NSEdgeInsets, equal expected: NSEdgeInsets,
                              file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.top, expected.top, accuracy: 0.01, file: file, line: line)
        XCTAssertEqual(actual.left, expected.left, accuracy: 0.01, file: file, line: line)
        XCTAssertEqual(actual.bottom, expected.bottom, accuracy: 0.01, file: file, line: line)
        XCTAssertEqual(actual.right, expected.right, accuracy: 0.01, file: file, line: line)
    }

    private func rightClick(at point: NSPoint, in window: NSWindow) -> NSEvent {
        NSEvent.mouseEvent(with: .rightMouseDown, location: point, modifierFlags: [],
                          timestamp: 0, windowNumber: window.windowNumber, context: nil,
                          eventNumber: 0, clickCount: 1, pressure: 0)!
    }

    private func requireWindowServer() throws {
        _ = NSApplication.shared
        if NSScreen.screens.isEmpty { throw XCTSkip("Reader focus verification requires a WindowServer session") }
    }

    private func makeSplitWindow(reader: NSView) -> SplitFixture {
        let sidebarController = NSViewController()
        sidebarController.view = NSView(frame: NSRect(x: 0, y: 0, width: 180, height: 600))
        let contentController = NSViewController()
        contentController.view = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 600))
        let readerController = NSViewController()
        readerController.view = reader
        let inner = NSSplitViewController()
        inner.splitView.isVertical = true
        let content = NSSplitViewItem(viewController: contentController)
        let detail = NSSplitViewItem(viewController: readerController)
        inner.addSplitViewItem(content)
        inner.addSplitViewItem(detail)
        let outer = NSSplitViewController()
        outer.splitView.isVertical = true
        let sidebar = NSSplitViewItem(viewController: sidebarController)
        outer.addSplitViewItem(sidebar)
        outer.addSplitViewItem(NSSplitViewItem(viewController: inner))
        sidebar.canCollapse = false
        content.canCollapse = false
        let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 1040, height: 700),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "Wordlinks disposable reader focus check"
        window.toolbar = NSToolbar(identifier: "reader-focus-test")
        window.toolbar?.isVisible = true
        window.contentViewController = outer
        window.orderBack(nil)
        window.contentView?.layoutSubtreeIfNeeded()
        return SplitFixture(window: window, sidebar: sidebar, content: content, detail: detail)
    }

    private func reader(with identity: NSUserInterfaceItemIdentifier, in view: NSView) -> NSView? {
        if view.identifier == identity { return view }
        return view.subviews.lazy.compactMap { self.reader(with: identity, in: $0) }.first
    }

    private func settle(_ window: NSWindow, preserving expectedWindowFrame: NSRect? = nil,
                        file: StaticString = #filePath, line: UInt = #line) async {
        var largestWindowFrameChange: CGFloat = 0
        for _ in 0..<16 {
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            if let expectedWindowFrame {
                let frame = window.frame
                largestWindowFrameChange = max(largestWindowFrameChange,
                    abs(frame.minX - expectedWindowFrame.minX), abs(frame.minY - expectedWindowFrame.minY),
                    abs(frame.width - expectedWindowFrame.width), abs(frame.height - expectedWindowFrame.height))
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        if expectedWindowFrame != nil {
            XCTAssertLessThanOrEqual(largestWindowFrameChange, 0.5,
                                    "A focus split transition must not resize or reposition its window", file: file, line: line)
        }
    }

    private func close(_ window: NSWindow) {
        window.orderOut(nil)
        window.contentViewController = nil
        window.close()
    }

    private struct SplitFixture {
        let window: NSWindow
        let sidebar: NSSplitViewItem
        let content: NSSplitViewItem
        let detail: NSSplitViewItem
    }
}

private struct FocusTestCredentials: AICredentialStorage {
    func read() throws -> String? { nil }
    func write(_ value: String) throws { }
}

private struct FocusTestProfileCredentials: AICustomCredentialStorage {
    func read(profileID: UUID) throws -> String? { nil }
    func write(_ value: String?, profileID: UUID) throws { }
}

private struct FocusTestAIClient: AICustomServing {
    func fetchModels(baseURL: String, apiKey: String) async throws -> [String] { throw AIError.invalidResponse }
    func explain(selection: String, context: String, focusedSentence: String?, purpose: AIExplanationPurpose,
                 configuration: AIConfiguration) async throws -> String { throw AIError.invalidResponse }
}

@MainActor
private final class FocusToolbarDelegate: NSObject, NSToolbarDelegate {
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarAllowedItemIdentifiers(toolbar)
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        ["reader.focus", "reader.intensive", "reader.settings"].map { NSToolbarItem.Identifier($0) }
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.label = "Synthetic label"
        let button = NSButton(image: NSImage(systemSymbolName: "circle", accessibilityDescription: nil)!,
                              target: nil, action: nil)
        button.frame = NSRect(x: 0, y: 0, width: 28, height: 28)
        item.view = button
        return item
    }
}
