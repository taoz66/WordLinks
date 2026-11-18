import AppKit
import SwiftUI
import XCTest
@testable import WordLinks

/// Check immediate native title clipping and toolbar items installed by the
/// production SwiftUI hierarchy, without mirroring it in a test toolbar delegate.
@MainActor
final class LibraryToolbarLayoutTests: XCTestCase {
    func testColumnTitleUsesMeasuredLeadingSpaceInsteadOfSidebarWidthDeductions() {
        let column = CGRect(x: 220, y: 0, width: 360, height: 700)
        XCTAssertEqual(LibraryToolbarTitleLayout.availableWidth(columnFrame: column, titleLeading: 236), 344)
        let collapsedColumn = CGRect(x: 0, y: 0, width: 360, height: 700)
        XCTAssertEqual(LibraryToolbarTitleLayout.availableWidth(columnFrame: collapsedColumn, titleLeading: 132), 228)
        XCTAssertEqual(LibraryToolbarTitleLayout.availableWidth(columnFrame: collapsedColumn, titleLeading: 90), 270,
                       "The actual native title position controls how much room is available")
        XCTAssertEqual(LibraryToolbarTitleLayout.availableWidth(columnFrame: column, titleLeading: 610), 0)
        XCTAssertEqual(LibraryToolbarTitleLayout.availableWidth(columnFrame: column, titleLeading: nil), 1)
    }

    func testNativeTitleMovementImmediatelyClipsToTheContentColumn() throws {
        let fixture = try makeNativeTitleFixture()
        defer { closeNativeTitleFixture(fixture.window) }
        let title = fixture.title
        let longTitle = title.label.stringValue
        let initialWidth = title.label.frame.width
        let initialIntrinsicWidth = title.intrinsicContentSize.width

        title.setFrameOrigin(NSPoint(x: title.frame.minX + 64, y: title.frame.minY))

        assertNativeTitle(title, staysInside: fixture.content)
        XCTAssertEqual(title.label.frame.width, initialWidth - 64, accuracy: 0.01,
                       "Moving the native title must clip its label in the same call")
        XCTAssertEqual(title.intrinsicContentSize.width, initialIntrinsicWidth, accuracy: 0.01,
                       "Changing the title position must not feed back into native toolbar allocation")
        XCTAssertEqual(title.label.maximumNumberOfLines, 1)
        XCTAssertEqual(title.label.lineBreakMode, .byTruncatingTail)
        XCTAssertEqual(title.label.cell?.wraps, false)
        XCTAssertEqual(title.label.cell?.isScrollable, false)
        XCTAssertGreaterThan(title.label.intrinsicContentSize.width, title.label.frame.width,
                             "The synthetic title must exercise visible truncation")
        XCTAssertEqual(title.label.toolTip, longTitle)
        XCTAssertEqual(title.label.accessibilityLabel(), longTitle,
                       "Truncation must retain the full accessible title")

        title.setFrameSize(NSSize(width: 90, height: title.frame.height))
        XCTAssertEqual(title.label.frame.width, 90, accuracy: 0.01,
                       "The label must also respect a narrower native toolbar host")
        XCTAssertEqual(title.intrinsicContentSize.width, initialIntrinsicWidth, accuracy: 0.01,
                       "Native host clipping must not change the title's ideal allocation")
    }

    func testNativeTitleUsesLiveSplitColumnBoundsBeforeItsLeafRelayouts() throws {
        let fixture = try makeNativeTitleFixture()
        defer { closeNativeTitleFixture(fixture.window) }
        let initialWidth = fixture.title.label.frame.width
        let initialLeafWidth = fixture.leaf.frame.width
        let initialColumnWidth = fixture.content.frame.width
        let initialIntrinsicWidth = fixture.title.intrinsicContentSize.width
        let rightDivider = fixture.content.frame.maxX

        fixture.split.setPosition(rightDivider - 120, ofDividerAt: 1)
        fixture.geometry.refreshTitle()

        XCTAssertLessThan(fixture.content.frame.width, initialColumnWidth)
        XCTAssertEqual(fixture.leaf.frame.width, initialLeafWidth,
                       "The content leaf deliberately retains its old frame during this layout pass")
        XCTAssertLessThan(fixture.title.label.frame.width, initialWidth)
        assertNativeTitle(fixture.title, staysInside: fixture.content)
        XCTAssertLessThan(fixture.title.intrinsicContentSize.width, initialIntrinsicWidth,
                          "A genuinely narrower column must lower the ideal-width cap")
        let narrowedIntrinsicWidth = fixture.title.intrinsicContentSize.width

        fixture.split.setFrameOrigin(NSPoint(x: fixture.split.frame.minX + 24,
                                              y: fixture.split.frame.minY))
        fixture.geometry.refreshTitle()
        assertNativeTitle(fixture.title, staysInside: fixture.content)
        XCTAssertEqual(fixture.title.intrinsicContentSize.width, narrowedIntrinsicWidth, accuracy: 0.01,
                       "Moving the split host without resizing the column must preserve ideal width")
    }

    private func makeNativeTitleFixture() throws -> (
        window: NSWindow, split: NSSplitView, content: NSView, leaf: NSView,
        title: LibraryColumnToolbarTitle.TitleView, geometry: LibraryToolbarGeometry
    ) {
        _ = NSApplication.shared
        if NSScreen.screens.isEmpty { throw XCTSkip("Native title layout requires a WindowServer session") }
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 1000, height: 600))
        let window = NSWindow(contentRect: root.frame, styleMask: [.titled, .resizable],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = root
        let split = NSSplitView(frame: NSRect(x: 20, y: 0, width: 960, height: 500))
        split.isVertical = true
        split.dividerStyle = .thin
        let sidebar = NSView(frame: NSRect(x: 0, y: 0, width: 180, height: 500))
        let content = NSView(frame: NSRect(x: 181, y: 0, width: 399, height: 500))
        let detail = NSView(frame: NSRect(x: 581, y: 0, width: 379, height: 500))
        for column in [sidebar, content, detail] { split.addSubview(column) }
        root.addSubview(split)
        let leaf = NSView(frame: content.bounds)
        leaf.autoresizingMask = []
        content.addSubview(leaf)
        let geometry = LibraryToolbarGeometry()
        geometry.attachColumn(leaf)
        let title = LibraryColumnToolbarTitle.TitleView(
            frame: NSRect(x: 240, y: 540, width: 700, height: 24))
        title.geometry = geometry
        title.updateTitle(Array(repeating: "A long native toolbar title 标题", count: 12).joined(separator: " "))
        root.addSubview(title)
        geometry.attachTitle(title)
        return (window, split, content, leaf, title, geometry)
    }

    private func assertNativeTitle(_ title: LibraryColumnToolbarTitle.TitleView,
                                   staysInside content: NSView,
                                   file: StaticString = #filePath, line: UInt = #line) {
        let columnFrame = content.convert(content.bounds, to: nil)
        let titleLeading = title.convert(.zero, to: nil).x
        let scale = max(1, title.window?.backingScaleFactor ?? 1)
        let inwardRight = (columnFrame.maxX * scale).rounded(.down) / scale
        let expectedWidth = (max(0, inwardRight - max(columnFrame.minX, titleLeading)) * scale)
            .rounded(.down) / scale
        let idealWidth = min(title.naturalLabelSize.width, inwardRight - columnFrame.minX)
        let visibleLabelBounds = title.label.bounds.intersection(title.label.visibleRect)
        let labelFrame = title.label.convert(visibleLabelBounds, to: nil)
        XCTAssertEqual(title.intrinsicContentSize.width, idealWidth, accuracy: 0.01, file: file, line: line)
        XCTAssertEqual(title.label.frame.width, min(title.bounds.width, expectedWidth), accuracy: 0.01,
                       file: file, line: line)
        XCTAssertGreaterThanOrEqual(labelFrame.minX, columnFrame.minX, file: file, line: line)
        XCTAssertLessThanOrEqual(labelFrame.maxX, columnFrame.maxX, file: file, line: line)
    }

    private func closeNativeTitleFixture(_ window: NSWindow) {
        window.orderOut(nil)
        window.contentView = nil
        window.close()
    }

    func testLibraryWindowInstallsLeadingSidebarAndSeparatedReadingAndSettingsControls() throws {
        _ = NSApplication.shared
        if NSScreen.screens.isEmpty { throw XCTSkip("Library toolbar layout requires a WindowServer session") }
        // Keep the XCTest entry synchronous when its runner predates the Swift
        // compiler used for the app. The waiter still pumps AppKit for the task.
        let finished = expectation(description: "Production library toolbar checked")
        let task = Task { @MainActor in
            defer { finished.fulfill() }
            do { try await verifyLibraryToolbar() }
            catch { XCTFail("Library toolbar layout failed: \(error)") }
        }
        wait(for: [finished], timeout: 20)
        task.cancel()
    }

    private func verifyLibraryToolbar() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try ReadingLibraryStore(rootURL: root, bundledCollections: [])
        let longTitle = Array(repeating: "A deliberately long synthetic article title 标题", count: 12).joined(separator: " ")
        _ = try store.addMarkdown(markdown: "# \(longTitle)\n\nA synthetic reading sentence.",
                                  sourceName: "toolbar.md")
        let suite = "LibraryToolbarLayoutTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let client = LibraryToolbarTestAIClient()
        let settings = AISettingsStore(defaults: defaults, credentials: LibraryToolbarTestCredentials(),
                                       language: AppLanguageStore(defaults: defaults),
                                       customCredentials: LibraryToolbarTestProfileCredentials(), customClient: client)
        _ = try settings.saveCustomProfile(name: "Synthetic toolbar service",
            baseURL: "https://toolbar.example.invalid/v1", apiKey: "", model: "synthetic-toolbar",
            authentication: .none)
        let host = NSHostingController(rootView: LibraryWindow()
            .environmentObject(store).environmentObject(settings)
            .defaultAppStorage(defaults)
            .preferredColorScheme(.light))
        let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 1280, height: 820),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.toolbarStyle = .unified
        window.title = "Wordlinks disposable library toolbar check"
        window.contentViewController = host
        window.orderBack(nil)
        defer {
            window.orderOut(nil)
            window.contentViewController = nil
            window.close()
        }
        await settle(window)
        let toolbar = try XCTUnwrap(window.toolbar,
            "NSHostingController must install the production toolbar; a missing toolbar is not a successful layout check")
        let items = toolbar.items
        print("Production library toolbar: " + items.map { $0.itemIdentifier.rawValue }.joined(separator: ", "))
        let sidebarIndex = try index(of: "library.sidebar", in: items)
        let focusIndex = try XCTUnwrap(items.firstIndex { $0.label == L("专注阅读", "Distraction-free Reading") })
        let intensiveIndex = try XCTUnwrap(items.firstIndex { $0.label == L("精读", "Intensive Reading") })
        let settingsIndex = try index(of: "reader.settings", in: items)
        XCTAssertFalse(items.contains { $0.itemIdentifier == .toggleSidebar
            || $0.itemIdentifier.rawValue.contains("navigationSplitView.toggleSidebar") },
                       "Only the explicit leading sidebar button may remain")
        XCTAssertLessThan(sidebarIndex, focusIndex)
        XCTAssertEqual(intensiveIndex, focusIndex + 1)
        XCTAssertLessThan(intensiveIndex, settingsIndex)

        let sidebarFrame = try frame(of: items[sidebarIndex], in: window)
        let contentFrame = try contentColumnFrame(in: window)
        XCTAssertFalse(items.contains { $0.itemIdentifier.rawValue.contains("library.columnTitle") },
                       "The content column must not install any title toolbar item")
        XCTAssertGreaterThanOrEqual(sidebarFrame.minX, 0)
        XCTAssertLessThanOrEqual(sidebarFrame.midX, contentFrame.minX + contentFrame.width / 2,
                                "The sidebar toggle must remain in the leading navigation area")
        try assertTitleStaysInsideDetailColumn(longTitle, in: window)
        let focusFrame = try frame(of: items[focusIndex], in: window)
        let nativeIntensiveFrame = try frame(of: items[intensiveIndex], in: window)
        let modesFrame = focusFrame.union(nativeIntensiveFrame)
        let settingsFrame = try frame(of: items[settingsIndex], in: window)
        let groupView = try XCTUnwrap(items[intensiveIndex].view)
        let intensive = try XCTUnwrap(descendant(with: IntensiveReadingToolbarHitTarget.identifier, in: groupView),
                                       "The shared reading-mode group must retain a distinct intensive button")
        let intensiveFrame = intensive.convert(intensive.bounds, to: nil)
        do {
            let contextTarget = ReaderFocusWindow.Coordinator()
            contextTarget.update(isActive: false, backgroundColor: .textBackgroundColor,
                                 onToggle: {}, onRegenerateIntensiveReading: {})
            contextTarget.attach(to: window)
            defer { contextTarget.detach() }
            let probes: [(NSPoint, Bool)] = [
                (intensive.convert(NSPoint(x: intensive.bounds.midX, y: intensive.bounds.midY), to: nil), true),
                (groupView.convert(NSPoint(x: groupView.bounds.minX - 1, y: groupView.bounds.midY), to: nil), false),
                (groupView.convert(NSPoint(x: groupView.bounds.maxX + 1, y: groupView.bounds.midY), to: nil), false),
                (NSPoint(x: focusFrame.midX, y: focusFrame.midY), false)
            ]
            for (location, shouldHit) in probes {
                let event = try XCTUnwrap(NSEvent.mouseEvent(with: .rightMouseDown,
                    location: location, modifierFlags: [], timestamp: 0,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                    clickCount: 1, pressure: 0))
                XCTAssertEqual(contextTarget.intensiveToolbarItemView(for: event) != nil, shouldHit,
                               "The intensive toolbar target must stay within the intensive button bounds")
            }
        }
        print("Production toolbar frames: sidebar=\(sidebarFrame), modes=\(modesFrame), intensive=\(intensiveFrame), settings=\(settingsFrame)")
        XCTAssertLessThan(sidebarFrame.midX, window.frame.width / 2,
                          "The library sidebar control belongs in the leading half of the window")
        XCTAssertLessThan(sidebarFrame.maxX, modesFrame.minX)
        // AppKit sizes the native hosts for their symbols. The hit marker must
        // stay inside its group; equal outer dimensions are not a platform rule.
        XCTAssertTrue(modesFrame.insetBy(dx: -1, dy: -1).contains(intensiveFrame))
        XCTAssertLessThan(modesFrame.maxX, settingsFrame.minX)
        XCTAssertTrue(toolbar.isVisible)
        XCTAssertFalse(toolbar.allowsUserCustomization)
        if #available(macOS 15.0, *) { XCTAssertFalse(toolbar.allowsDisplayModeCustomization) }
        XCTAssertEqual(toolbar.displayMode, .iconOnly)
        XCTAssertEqual(client.requests, 0, "Rendering the library toolbar must never issue an AI request")
        try snapshot(window)

        try await sampleSidebarTransition(items[sidebarIndex], in: window)
        await settle(window)
        let hiddenItems = toolbar.items
        let restoreIndex = try index(of: "library.sidebar", in: hiddenItems)
        let restoreFrame = try frame(of: hiddenItems[restoreIndex], in: window)
        let expandedContentFrame = try contentColumnFrame(in: window)
        XCTAssertLessThan(expandedContentFrame.minX, contentFrame.minX,
                          "Hiding the sidebar must release its horizontal space")
        XCTAssertGreaterThanOrEqual(restoreFrame.minX, expandedContentFrame.minX - 1)
        XCTAssertLessThanOrEqual(restoreFrame.maxX, expandedContentFrame.maxX + 1,
                                "The hidden sidebar must retain a leading restore control in the content column")
        try assertTitleStaysInsideDetailColumn(longTitle, in: window)

        window.setContentSize(NSSize(width: 1040, height: 720))
        await settle(window)
        try assertTitleStaysInsideDetailColumn(longTitle, in: window)
        window.setContentSize(NSSize(width: 1440, height: 860))
        await settle(window)
        try assertTitleStaysInsideDetailColumn(longTitle, in: window)
        window.setContentSize(NSSize(width: 1280, height: 820))
        await settle(window)

        try await sampleSidebarTransition(hiddenItems[restoreIndex], in: window)
        await settle(window)
        try assertTitleStaysInsideDetailColumn(longTitle, in: window)
        let restoredContentFrame = try contentColumnFrame(in: window)
        XCTAssertEqual(restoredContentFrame.minX, contentFrame.minX, accuracy: 2,
                       "Showing the sidebar restores the original column layout")

        let restoredFocus = try XCTUnwrap(toolbar.items.first {
            $0.label == L("专注阅读", "Distraction-free Reading")
        })
        try click(restoredFocus, in: window)
        await settle(window)
        let focusedItems = toolbar.items
        for identity in ["library.sidebar", "library.columnTitle", "library.detailTitle", "reader.settings"] {
            XCTAssertFalse(focusedItems.contains { $0.itemIdentifier.rawValue.contains(identity) },
                           "Focused reading must remove the entire \(identity) item and its reserved space")
        }
        XCTAssertTrue(window.title.isEmpty || window.titleVisibility == .hidden,
                      "Focused reading must hide the article title")
        XCTAssertEqual(focusedItems.filter {
            $0.label == L("专注阅读", "Distraction-free Reading")
                || $0.label == L("精读", "Intensive Reading")
        }.count, 2, "Focused reading retains both reading-mode controls")
        XCTAssertEqual(client.requests, 0, "Sidebar and focus changes must not issue an AI request")
    }

    private func contentColumnFrame(in window: NSWindow) throws -> NSRect {
        let root = try XCTUnwrap(window.contentView)
        let search = try XCTUnwrap(descendant(of: NSSearchField.self, in: root),
                                  "The production article list must contain its native search field")
        return try splitColumnFrame(containing: search)
    }

    private func assertTitleStaysInsideDetailColumn(_ expectedTitle: String,
                                                    in window: NSWindow,
                                                    file: StaticString = #filePath, line: UInt = #line) throws {
        let toolbar = try XCTUnwrap(window.toolbar, file: file, line: line)
        let items = toolbar.items
        let item = items[try index(of: "library.detailTitle", in: items)]
        let host = try XCTUnwrap(item.view, file: file, line: line)
        let titleView = try XCTUnwrap(descendant(of: LibraryColumnToolbarTitle.TitleView.self, in: host),
                                      "The detail title item must contain its native title view", file: file, line: line)
        let titleLabel = titleView.label
        XCTAssertEqual(titleLabel.stringValue, expectedTitle, file: file, line: line)
        let titleWindow = try XCTUnwrap(titleLabel.window, file: file, line: line)
        let visible = titleLabel.bounds.intersection(titleLabel.visibleRect)
        XCTAssertFalse(visible.isEmpty, "The detail title label must remain visible", file: file, line: line)
        let titleFrame = window.convertFromScreen(titleWindow.convertToScreen(titleLabel.convert(visible, to: nil)))
        let contentFrame = try contentColumnFrame(in: window)
        let root = try XCTUnwrap(window.contentView, file: file, line: line)
        let reader = try XCTUnwrap(descendant(with: ReaderTextViewIdentity.article, in: root),
                                  file: file, line: line)
        let detailFrame = try splitColumnFrame(containing: reader)
        let focusItem = try XCTUnwrap(items.first { $0.label == L("专注阅读", "Distraction-free Reading") }, file: file, line: line)
        let focusFrame = try frame(of: focusItem, in: window)
        print("Production detail title frames: content=\(contentFrame), title=\(titleFrame), detail=\(detailFrame), focus=\(focusFrame), itemFrame=\(try frame(of: item, in: window))")
        XCTAssertGreaterThanOrEqual(titleFrame.minX, detailFrame.minX - 1,
                                    "The article title must start inside the detail column", file: file, line: line)
        XCTAssertGreaterThanOrEqual(titleFrame.minX, contentFrame.maxX - 1,
                                    "The content column must not contain the article title", file: file, line: line)
        XCTAssertLessThanOrEqual(titleFrame.maxX, detailFrame.maxX + 1, file: file, line: line)
        XCTAssertLessThanOrEqual(titleFrame.maxX, focusFrame.minX + 1,
                                 "A long title must truncate before the trailing reader toolbar buttons", file: file, line: line)
        XCTAssertEqual(titleLabel.toolTip, expectedTitle, file: file, line: line)
        XCTAssertEqual(titleLabel.accessibilityLabel(), expectedTitle, file: file, line: line)
    }

    func testShortDetailTitleStartsInsideDetailColumnAndContentColumnHasNoTitle() throws {
        _ = NSApplication.shared
        if NSScreen.screens.isEmpty { throw XCTSkip("Library toolbar layout requires a WindowServer session") }
        let finished = expectation(description: "Short detail title and empty content title checked")
        let task = Task { @MainActor in
            defer { finished.fulfill() }
            do { try await verifyShortDetailTitleAndEmptyContentColumn() }
            catch { XCTFail("Short detail title layout failed: \(error)") }
        }
        wait(for: [finished], timeout: 15)
        task.cancel()
    }

    private func verifyShortDetailTitleAndEmptyContentColumn() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try ReadingLibraryStore(rootURL: root, bundledCollections: [])
        let mediumTitle = "The Importance of Law"
        _ = try store.addMarkdown(markdown: "# \(mediumTitle)\n\nThe law influences all of us.",
                                  sourceName: "law.md")
        let suite = "LibraryToolbarLayoutTests.short." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let client = LibraryToolbarTestAIClient()
        let settings = AISettingsStore(defaults: defaults, credentials: LibraryToolbarTestCredentials(),
                                       language: AppLanguageStore(defaults: defaults),
                                       customCredentials: LibraryToolbarTestProfileCredentials(), customClient: client)
        let host = NSHostingController(rootView: LibraryWindow()
            .environmentObject(store).environmentObject(settings)
            .defaultAppStorage(defaults)
            .preferredColorScheme(.light))
        let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 1280, height: 820),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.toolbarStyle = .unified
        window.contentViewController = host
        window.orderBack(nil)
        defer {
            window.orderOut(nil)
            window.contentViewController = nil
            window.close()
        }
        await settle(window)
        let toolbar = try XCTUnwrap(window.toolbar)
        XCTAssertFalse(toolbar.items.contains { $0.itemIdentifier.rawValue.contains("library.columnTitle") })
        try assertTitleStaysInsideDetailColumn(mediumTitle, in: window)
        let mediumItem = toolbar.items[try index(of: "library.detailTitle", in: toolbar.items)]
        let mediumView = try XCTUnwrap(descendant(of: LibraryColumnToolbarTitle.TitleView.self, in: try XCTUnwrap(mediumItem.view)))
        XCTAssertGreaterThanOrEqual(mediumView.label.frame.width, mediumView.naturalLabelSize.width,
                                    "A short/medium title must receive its full cell width while detail toolbar space remains")
        XCTAssertEqual(mediumView.label.cell?.expansionFrame(withFrame: mediumView.label.bounds, in: mediumView.label) ?? .zero,
                       .zero, "A fitting detail title must not be truncated by NSTextFieldCell")

        // Widen the content column and verify the title still fits without premature truncation.
        if let root = window.contentView,
           let split = descendant(of: NSSplitView.self, in: root) {
            split.setPosition(440, ofDividerAt: split.subviews.count > 2 ? 1 : 0)
            await settle(window)
            try assertTitleStaysInsideDetailColumn(mediumTitle, in: window)
            XCTAssertGreaterThanOrEqual(mediumView.label.frame.width, mediumView.naturalLabelSize.width,
                                        "Widening the content column must not prematurely truncate a fitting detail title")
            XCTAssertEqual(mediumView.label.cell?.expansionFrame(withFrame: mediumView.label.bounds, in: mediumView.label) ?? .zero,
                           .zero, "Widening the content column must not cause NSTextFieldCell truncation on a fitting title")
        }

        for article in store.archive.articles {
            try store.deleteArticle(article.id)
        }
        await settle(window)
        XCTAssertFalse(toolbar.items.contains { $0.itemIdentifier.rawValue.contains("library.columnTitle") },
                       "The content column must not display a title even when no article is selected")
        XCTAssertFalse(toolbar.items.contains { $0.itemIdentifier.rawValue.contains("library.detailTitle") },
                       "The detail column must not display an article title when no article is selected")
    }

    private func sampleSidebarTransition(_ item: NSToolbarItem, in window: NSWindow) async throws {
        let initialSidebarView = try XCTUnwrap(item.view)
        let initialIdentity = ObjectIdentifier(initialSidebarView)
        var sidebarIdentities: Set<ObjectIdentifier> = [initialIdentity]
        try click(item, in: window)
        // Keep this bounded to the native transition instead of adding a second
        // long UI pass. No per-frame snapshots or data/AI operations are needed.
        for _ in 0..<32 {
            window.contentView?.layoutSubtreeIfNeeded()
            window.update()
            window.displayIfNeeded()
            let items = try XCTUnwrap(window.toolbar).items
            let sidebar = items[try index(of: "library.sidebar", in: items)]
            sidebarIdentities.insert(ObjectIdentifier(try XCTUnwrap(sidebar.view)))
            try await Task.sleep(nanoseconds: 16_000_000)
        }
        XCTAssertEqual(sidebarIdentities, Set([initialIdentity]),
                       "Sidebar toggling must retain its native toolbar view throughout the animation")
    }

    private func splitColumnFrame(containing view: NSView) throws -> NSRect {
        var child = view
        while let parent = child.superview {
            if parent is NSSplitView {
                let safe = child.safeAreaRect
                let horizontal = NSRect(x: safe.minX, y: child.bounds.minY,
                                        width: max(0, safe.width), height: child.bounds.height)
                return child.convert(horizontal, to: nil)
            }
            child = parent
        }
        throw NSError(domain: "LibraryToolbarLayoutTests", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "The production view must belong to a split-view column"])
    }

    private func click(_ item: NSToolbarItem, in window: NSWindow) throws {
        let view = try XCTUnwrap(item.view)
        let eventWindow = try XCTUnwrap(view.window)
        let point = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: eventWindow.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0))
            eventWindow.sendEvent(event)
        }
    }

    private func index(of identity: String, in items: [NSToolbarItem]) throws -> Int {
        try XCTUnwrap(items.firstIndex { $0.itemIdentifier.rawValue.contains(identity) },
                      "Missing production toolbar item: \(identity)")
    }

    private func frame(of item: NSToolbarItem, in window: NSWindow) throws -> NSRect {
        let view = try XCTUnwrap(item.view, "The production toolbar item must expose its native view: \(item.itemIdentifier)")
        let itemWindow = try XCTUnwrap(view.window)
        let frame = window.convertFromScreen(itemWindow.convertToScreen(view.convert(view.bounds, to: nil)))
        XCTAssertGreaterThan(frame.width, 0)
        XCTAssertGreaterThan(frame.height, 0)
        return frame
    }

    private func descendant(with identity: NSUserInterfaceItemIdentifier, in view: NSView) -> NSView? {
        if view.identifier == identity { return view }
        return view.subviews.lazy.compactMap { self.descendant(with: identity, in: $0) }.first
    }

    private func descendant<T: NSView>(of type: T.Type, in view: NSView) -> T? {
        if let match = view as? T { return match }
        return view.subviews.lazy.compactMap { self.descendant(of: type, in: $0) }.first
    }

    private func settle(_ window: NSWindow) async {
        var lastIdentities: [NSToolbarItem.Identifier] = []
        var lastFrames: [CGRect] = []
        var stablePasses = 0
        for _ in 0..<80 {
            window.contentView?.layoutSubtreeIfNeeded()
            // XCTest hosts this controller without NSApplication.run(). Pump
            // the public window update used by the production geometry reader.
            window.update()
            window.displayIfNeeded()
            try? await Task.sleep(nanoseconds: 20_000_000)
            let identities = window.toolbar?.items.map(\.itemIdentifier) ?? []
            var frames = window.toolbar?.items.compactMap { item in
                item.view.map { $0.convert($0.bounds, to: nil) }
            } ?? []
            if let columnFrame = try? contentColumnFrame(in: window) { frames.append(columnFrame) }
            if !identities.isEmpty && identities == lastIdentities && frames == lastFrames {
                stablePasses += 1
            } else {
                stablePasses = 0
            }
            lastIdentities = identities
            lastFrames = frames
            if stablePasses >= 20 { return }
        }
    }

    private func snapshot(_ window: NSWindow) throws {
        guard let directory = ProcessInfo.processInfo.environment["WORDLINKS_UI_INSPECTION_DIR"],
              !directory.isEmpty, let frameView = window.contentView?.superview else { return }
        let output = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        // Capture the window frame view to include the real toolbar. AppKit's
        // bitmap cache can omit SwiftUI compositor layers; use item geometry as
        // the authoritative automated layout evidence if the image is incomplete.
        let bitmap = try XCTUnwrap(frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds))
        frameView.cacheDisplay(in: frameView.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: output.appendingPathComponent("library-toolbar-standard-light.png"), options: .atomic)
    }
}

private struct LibraryToolbarTestCredentials: AICredentialStorage {
    func read() throws -> String? { nil }
    func write(_ value: String) throws { }
}

private struct LibraryToolbarTestProfileCredentials: AICustomCredentialStorage {
    func read(profileID: UUID) throws -> String? { nil }
    func write(_ value: String?, profileID: UUID) throws { }
}

@MainActor
private final class LibraryToolbarTestAIClient: AICustomServing {
    private(set) var requests = 0
    func fetchModels(baseURL: String, apiKey: String) async throws -> [String] {
        requests += 1
        throw AIError.invalidResponse
    }
    func explain(selection: String, context: String, focusedSentence: String?, purpose: AIExplanationPurpose,
                 configuration: AIConfiguration) async throws -> String {
        requests += 1
        throw AIError.invalidResponse
    }
}
