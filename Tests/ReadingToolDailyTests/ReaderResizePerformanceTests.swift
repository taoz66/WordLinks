import AppKit
import XCTest
@testable import ReadingToolDaily

@MainActor
final class ReaderResizePerformanceTests: XCTestCase {
    func testRepeatedWidthsKeepVisibleSelectionAndAvoidLayingOutTheEntireArticle() throws {
        let title = "Resize test"
        let paragraphs = (0..<240).map { index in
            "Paragraph \(index): café 🙂 keeps the selected passage stable while the window changes width."
        }
        let body = paragraphs.joined(separator: "\n\n")
        let source = title + "\n\n" + body
        let target = (source as NSString).range(of: "Paragraph 120:")
        XCTAssertNotEqual(target.location, NSNotFound)

        let view = makeTextView(source: source, width: 760)
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 760, height: 620))
        scrollView.documentView = view
        let window = NSWindow(contentRect: scrollView.frame, styleMask: [.titled, .resizable],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = scrollView
        window.orderBack(nil)
        defer {
            window.orderOut(nil)
            window.contentView = nil
            window.close()
        }
        view.layoutManager?.ensureLayout(forCharacterRange: target)
        view.scrollRangeToVisible(target)
        let selection = NSRange(location: target.location + 2, length: 8)
        view.setSelectedRange(selection)
        let manager = try XCTUnwrap(view.layoutManager as? ResizeTrackingLayoutManager)
        let originalLength = (source as NSString).length
        manager.fullContainerRequests = 0

        for width in [620.0, 690.0, 540.0, 760.0, 610.0] {
            scrollView.setFrameSize(NSSize(width: width, height: 620))
            view.setFrameSize(NSSize(width: width, height: view.frame.height))
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        window.contentView?.layoutSubtreeIfNeeded()

        XCTAssertEqual(manager.fullContainerRequests, 0,
                       "Resize anchor preservation must not synchronously lay out the full document")
        XCTAssertEqual(view.selectedRange(), selection)
        let visible = scrollView.contentView.bounds
        let selectedRect = view.firstRect(forCharacterRange: selection, actualRange: nil)
        let selectedInWindow = window.convertFromScreen(selectedRect)
        let visibleInWindow = scrollView.contentView.convert(visible, to: nil)
        XCTAssertTrue(visibleInWindow.insetBy(dx: 0, dy: -8).intersects(selectedInWindow),
                      "The selected passage should remain near the viewport after width changes")
        XCTAssertGreaterThan(originalLength, 12_000)
    }

    func testBylineWidthChangesRequestOnlyTheTitleRangeAndReuseSameWidthMeasurement() throws {
        let source = "A title 👩🏽‍💻\n\n" + Array(repeating: "Body text remains unchanged.", count: 500).joined(separator: " ")
        let title = "A title 👩🏽‍💻"
        let view = makeTextView(source: source, width: 760)
        let byline = ReaderArticleByline()
        let layout = try XCTUnwrap(view.layoutManager as? ResizeTrackingLayoutManager)
        let metadata = ArticleMetadata(author: "A long author name", source: "Source")
        layout.fullContainerRequests = 0
        layout.requestedCharacterRanges.removeAll()

        byline.update(in: view, title: title, metadata: metadata,
                      readingStyle: .standard, typography: ReadingViewStyle.standard.defaultTypography)
        XCTAssertEqual(layout.requestedCharacterRanges.last,
                       NSRange(location: (title as NSString).length + 1, length: 1))
        XCTAssertEqual(layout.fullContainerRequests, 0)
        let firstMeasurement = byline.measurementCount

        view.setFrameSize(NSSize(width: 760, height: view.frame.height))
        byline.layout(in: view)
        XCTAssertEqual(byline.measurementCount, firstMeasurement,
                       "An unchanged width should reuse the byline measurement")

        view.setFrameSize(NSSize(width: 560, height: view.frame.height))
        byline.layout(in: view)
        XCTAssertEqual(byline.measurementCount, firstMeasurement + 1)
        XCTAssertEqual(layout.fullContainerRequests, 0)
    }

    func testCoordinatedSplitTransitionDefersLongArticleUntilCompletionEvenAfterTimerAndLayout() throws {
        let longBody = Array(repeating: "Coordinated split transitions wait for all columns before rewrapping long prose.",
                             count: 80).joined(separator: " ")
        XCTAssertGreaterThan((longBody as NSString).length, ReaderSplitReflowController.liveReflowUTF16Limit)

        let view = makeTextView(source: longBody, width: 640)
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 640, height: 480))
        scrollView.documentView = view
        let window = NSWindow(contentRect: scrollView.frame, styleMask: [.titled, .resizable],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = scrollView
        defer {
            window.orderOut(nil)
            window.contentView = nil
            window.close()
        }

        let token = ReaderSplitAnimationCoordinator.shared.beginTransition(for: window, maxDuration: 1.0)
        scrollView.setFrameSize(NSSize(width: 780, height: 480))
        view.setFrameSize(NSSize(width: 780, height: view.frame.height))
        view.layout()
        RunLoop.main.run(until: Date().addingTimeInterval(0.08))

        XCTAssertEqual(view.textContainer?.containerSize.width ?? 0, 580, accuracy: 0.5,
                       "Long prose must stay locked while coordinated split transition is still active")
        XCTAssertEqual(view.textContainerInset.width, 100, accuracy: 0.5,
                       "Locked prose must keep centering within the widening viewport during transition")

        ReaderSplitAnimationCoordinator.shared.endTransition(for: window, token: token)
        XCTAssertEqual(view.textContainer?.containerSize.width ?? 0, 720, accuracy: 0.5,
                       "Ending the coordinated split transition must flush the text container width")
        XCTAssertEqual(view.textContainerInset.width, 30, accuracy: 0.5)
    }

    func testShortPassagesReflowImmediatelyDuringCoordinatedSplitTransitions() throws {
        let shortBody = "A brief passage stays within the single-millisecond live reflow budget."
        XCTAssertLessThanOrEqual((shortBody as NSString).length, ReaderSplitReflowController.liveReflowUTF16Limit)

        let view = makeTextView(source: shortBody, width: 640)
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 640, height: 480))
        scrollView.documentView = view
        let window = NSWindow(contentRect: scrollView.frame, styleMask: [.titled, .resizable],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = scrollView
        defer {
            window.orderOut(nil)
            window.contentView = nil
            window.close()
        }

        let token = ReaderSplitAnimationCoordinator.shared.beginTransition(for: window, maxDuration: 1.0)
        defer { ReaderSplitAnimationCoordinator.shared.endTransition(for: window, token: token) }
        scrollView.setFrameSize(NSSize(width: 780, height: 480))
        view.setFrameSize(NSSize(width: 780, height: view.frame.height))

        XCTAssertEqual(view.textContainer?.containerSize.width ?? 0, 720, accuracy: 0.5,
                       "Short passages should reflow live every frame instead of deferring")
        XCTAssertEqual(view.textContainerInset.width, 30, accuracy: 0.5)
    }

    private func makeTextView(source: String, width: CGFloat) -> CardAwareTextView {
        let storage = NSTextStorage(string: source, attributes: [.font: NSFont.systemFont(ofSize: 16)])
        let manager = ResizeTrackingLayoutManager()
        manager.allowsNonContiguousLayout = true
        let container = NSTextContainer(size: NSSize(width: width - 60, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        storage.addLayoutManager(manager)
        manager.addTextContainer(container)
        let view = CardAwareTextView(frame: NSRect(x: 0, y: 0, width: width, height: 18_000), textContainer: container)
        view.readingStyle = .standard
        view.typography = ReadingViewStyle.standard.defaultTypography
        view.textContainerInset = NSSize(width: 30, height: 28)
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        container.widthTracksTextView = true
        container.containerSize = NSSize(width: width - 60, height: .greatestFiniteMagnitude)
        return view
    }
}

private final class ResizeTrackingLayoutManager: NSLayoutManager {
    var fullContainerRequests = 0
    var requestedCharacterRanges: [NSRange] = []

    override func ensureLayout(for textContainer: NSTextContainer) {
        fullContainerRequests += 1
        super.ensureLayout(for: textContainer)
    }

    override func ensureLayout(forCharacterRange charRange: NSRange) {
        requestedCharacterRanges.append(charRange)
        super.ensureLayout(forCharacterRange: charRange)
    }
}
