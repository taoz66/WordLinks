import AppKit
import SwiftUI

struct LibrarySidebarCommandState {
    let isVisible: Bool
    let onToggle: () -> Void
}

private struct LibrarySidebarCommandKey: FocusedValueKey {
    typealias Value = LibrarySidebarCommandState
}

extension FocusedValues {
    var librarySidebar: LibrarySidebarCommandState? {
        get { self[LibrarySidebarCommandKey.self] }
        set { self[LibrarySidebarCommandKey.self] = newValue }
    }
}

/// Keep the menu action scoped to the active library window, including when
/// its sidebar is hidden and no sidebar view can receive focus.
struct LibrarySidebarCommands: Commands {
    @FocusedValue(\.librarySidebar) private var sidebar

    var body: some Commands {
        CommandGroup(replacing: .sidebar) {
            Button(sidebar?.isVisible == true
                   ? L("隐藏阅读库边栏", "Hide Library Sidebar")
                   : L("显示阅读库边栏", "Show Library Sidebar")) {
                sidebar?.onToggle()
            }
            .disabled(sidebar == nil)
        }
    }
}

enum LibraryToolbarTitleLayout {
    /// Use the title's actual native leading edge. System window controls and
    /// navigation items have already consumed their space at this point.
    static func availableWidth(columnFrame: CGRect, titleLeading: CGFloat?) -> CGFloat {
        guard columnFrame.width > 0, let titleLeading, titleLeading.isFinite else { return 1 }
        return max(0, columnFrame.maxX - max(columnFrame.minX, titleLeading))
    }
}

/// Keep live native geometry out of SwiftUI state. Both sides of the title's
/// available width are read together, including during split-view animation.
@MainActor
final class LibraryToolbarGeometry {
    private weak var columnView: NSView?
    private weak var titleView: LibraryColumnToolbarTitle.TitleView?

    func attachColumn(_ view: NSView) {
        columnView = view
        refreshTitle()
    }

    func detachColumn(_ view: NSView) {
        guard columnView === view else { return }
        columnView = nil
        refreshTitle()
    }

    func attachTitle(_ view: LibraryColumnToolbarTitle.TitleView) {
        titleView = view
        refreshTitle()
    }

    func detachTitle(_ view: LibraryColumnToolbarTitle.TitleView) {
        if titleView === view { titleView = nil }
    }

    func refreshTitle() {
        titleView?.updateLiveGeometry()
    }

    func availableWidth(for title: NSView, trailingLimit: CGFloat? = nil) -> CGFloat {
        guard let frame = columnFrame(in: title.window), let titleWindow = title.window else { return 1 }
        let scale = max(1, titleWindow.backingScaleFactor)
        let leading = title.convert(.zero, to: nil).x
        let boundedFrame = trailingLimit.map { limit in
            CGRect(x: frame.minX, y: frame.minY,
                   width: max(0, min(frame.maxX, limit) - frame.minX),
                   height: frame.height)
        } ?? frame
        return (LibraryToolbarTitleLayout.availableWidth(columnFrame: boundedFrame, titleLeading: leading) * scale)
            .rounded(.down) / scale
    }

    func detailLabelInsets(for title: NSView, trailingLimit: CGFloat?) -> (leadingOffset: CGFloat, availableWidth: CGFloat)? {
        guard let frame = columnFrame(in: title.window), let titleWindow = title.window else { return nil }
        let scale = max(1, titleWindow.backingScaleFactor)
        let titleLeading = title.convert(.zero, to: nil).x
        guard titleLeading.isFinite else { return nil }
        let minimumLabelLeading = frame.minX + 10
        let leadingOffset = max(0, ((minimumLabelLeading - titleLeading) * scale).rounded(.up) / scale)
        let effectiveLeading = titleLeading + leadingOffset
        let rightLimit = min(frame.maxX, trailingLimit ?? frame.maxX)
        let available = max(0, ((rightLimit - effectiveLeading) * scale).rounded(.down) / scale)
        return (leadingOffset, available)
    }

    func columnWidth(in window: NSWindow?) -> CGFloat? {
        columnFrame(in: window)?.width
    }

    func detailAvailableSpan(in window: NSWindow?, excluding titleView: NSView) -> (span: CGFloat, trailingLimit: CGFloat?)? {
        guard let window, let frame = columnFrame(in: window) else { return nil }
        let scale = max(1, window.backingScaleFactor)
        let trailing = trailingToolbarMinX(in: window, columnFrame: frame, excluding: titleView).map { $0 - 10 }
        let rightLimit = min(frame.maxX, trailing ?? frame.maxX)
        let leading = leadingToolbarMaxX(in: window, columnFrame: frame, excluding: titleView).map { $0 + 10 }
        let leftLimit = min(frame.minX + 10, leading ?? (frame.minX + 10))
        let span = max(1, ((rightLimit - leftLimit - 10) * scale).rounded(.down) / scale)
        return (span, trailing)
    }

    private func leadingToolbarMaxX(in window: NSWindow, columnFrame: CGRect, excluding titleView: NSView) -> CGFloat? {
        guard let toolbar = window.toolbar else { return nil }
        let items = toolbar.visibleItems ?? toolbar.items
        var maxX: CGFloat?
        for item in items {
            guard let view = item.view, view.window != nil, !view.isHiddenOrHasHiddenAncestor else { continue }
            if titleView === view || titleView.isDescendant(of: view) { continue }
            var frame = view.convert(view.bounds, to: nil)
            if let viewWindow = view.window, viewWindow !== window {
                frame = window.convertFromScreen(viewWindow.convertToScreen(frame))
            }
            guard frame.width > 0, frame.maxX.isFinite, frame.minX < columnFrame.minX else { continue }
            maxX = max(maxX ?? frame.maxX, frame.maxX)
        }
        return maxX
    }

    private func trailingToolbarMinX(in window: NSWindow, columnFrame: CGRect, excluding titleView: NSView) -> CGFloat? {
        guard let toolbar = window.toolbar else { return nil }
        let items = toolbar.visibleItems ?? toolbar.items
        var minX: CGFloat?
        for item in items {
            guard let view = item.view, view.window != nil, !view.isHiddenOrHasHiddenAncestor else { continue }
            if titleView === view || titleView.isDescendant(of: view) { continue }
            var frame = view.convert(view.bounds, to: nil)
            if let viewWindow = view.window, viewWindow !== window {
                frame = window.convertFromScreen(viewWindow.convertToScreen(frame))
            }
            guard frame.width > 0, frame.minX.isFinite, frame.minX >= columnFrame.minX else { continue }
            minX = min(minX ?? frame.minX, frame.minX)
        }
        return minX
    }

    var isSidebarCollapsed: Bool {
        splitController()?.splitViewItems.first(where: { $0.behavior == .sidebar })?.isCollapsed == true
    }

    var hostWindow: NSWindow? {
        splitController()?.view.window
    }

    @discardableResult
    func toggleSidebar() -> Bool {
        guard let controller = splitController(),
              let sidebarItem = controller.splitViewItems.first(where: { $0.behavior == .sidebar }) else {
            return false
        }
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            sidebarItem.isCollapsed.toggle()
        } else {
            let window = controller.view.window
            let token = ReaderSplitAnimationCoordinator.shared.beginTransition(for: window, maxDuration: 0.5)
            NSAnimationContext.runAnimationGroup { _ in
                controller.toggleSidebar(nil)
            } completionHandler: { [weak window] in
                MainActor.assumeIsolated {
                    ReaderSplitAnimationCoordinator.shared.endTransition(for: window, token: token)
                }
            }
        }
        refreshTitle()
        return true
    }

    func ensureContentColumnVisibleIfNeeded() {
        guard let controller = splitController() else { return }
        // Heal stale NSSplitView autosave where contentList was persisted as collapsed while non-collapsible.
        for item in controller.splitViewItems where item.behavior == .contentList && item.isCollapsed && !item.canCollapse {
            item.isCollapsed = false
        }
    }

    private func splitController() -> NSSplitViewController? {
        var ancestor = columnView?.superview
        while let view = ancestor {
            if let split = view as? NSSplitView, split.isVertical,
               let controller = split.delegate as? NSSplitViewController {
                return controller
            }
            ancestor = view.superview
        }
        return nil
    }

    private func columnFrame(in window: NSWindow?) -> NSRect? {
        guard let columnView, let columnWindow = columnView.window,
              let window else { return nil }
        // The split item can already have moved while its SwiftUI contents are
        // still laying out. Use the item's live safe-area horizontal bounds so
        // an overlaid Liquid Glass sidebar does not look like a growing column.
        var column = columnView
        while let parent = column.superview {
            if parent is NSSplitView { break }
            column = parent
        }
        let safeRect = column.safeAreaRect
        let horizontalRect = NSRect(x: safeRect.minX,
                                    y: column.bounds.minY,
                                    width: max(0, safeRect.width),
                                    height: column.bounds.height)
        var frame = column.convert(horizontalRect, to: nil)
        if columnWindow !== window {
            frame = window.convertFromScreen(columnWindow.convertToScreen(frame))
        }
        let scale = max(1, window.backingScaleFactor)
        let right = (frame.maxX * scale).rounded(.down) / scale
        // Round inward so text never draws a fractional pixel past the divider.
        frame.size.width = max(0, right - frame.minX)
        return frame
    }
}

/// Observe the actual split column without publishing per-frame view state.
struct LibraryToolbarColumnReader: NSViewRepresentable {
    let geometry: LibraryToolbarGeometry
    var isDistractionFree = false

    func makeNSView(context: Context) -> FrameView {
        let view = FrameView()
        view.setAccessibilityElement(false)
        view.geometry = geometry
        view.isDistractionFree = isDistractionFree
        geometry.attachColumn(view)
        if !isDistractionFree { geometry.ensureContentColumnVisibleIfNeeded() }
        return view
    }

    func updateNSView(_ view: FrameView, context: Context) {
        view.geometry = geometry
        view.isDistractionFree = isDistractionFree
        geometry.attachColumn(view)
        if !isDistractionFree { geometry.ensureContentColumnVisibleIfNeeded() }
    }

    static func dismantleNSView(_ view: FrameView, coordinator: ()) {
        view.geometry?.detachColumn(view)
        view.geometry = nil
        view.stopObserving()
    }

    final class FrameView: NSView {
        weak var geometry: LibraryToolbarGeometry?
        var isDistractionFree = false
        private var observers: [NSObjectProtocol] = []

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func layout() {
            super.layout()
            if !isDistractionFree { geometry?.ensureContentColumnVisibleIfNeeded() }
            geometry?.refreshTitle()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stopObserving()
            if let window {
                for name in [NSWindow.didUpdateNotification, NSWindow.didResizeNotification, NSWindow.didEnterFullScreenNotification,
                             NSWindow.didExitFullScreenNotification] {
                    observers.append(NotificationCenter.default.addObserver(forName: name, object: window,
                        queue: .main) { [weak self] _ in
                            MainActor.assumeIsolated { self?.geometry?.refreshTitle() }
                        })
                }
                var ancestor = superview
                while let view = ancestor {
                    if let split = view as? NSSplitView {
                        observers.append(NotificationCenter.default.addObserver(
                            forName: NSSplitView.didResizeSubviewsNotification, object: split, queue: .main
                        ) { [weak self] _ in
                            MainActor.assumeIsolated { self?.geometry?.refreshTitle() }
                        })
                    }
                    ancestor = view.superview
                }
            }
            if !isDistractionFree { geometry?.ensureContentColumnVisibleIfNeeded() }
            geometry?.refreshTitle()
        }

        func stopObserving() {
            observers.forEach(NotificationCenter.default.removeObserver)
            observers.removeAll()
        }

    }
}

/// The native label clips against the live content column in the same layout
/// pass. Its clipping does not wait for a SwiftUI geometry-state round trip.
struct LibraryColumnToolbarTitle: NSViewRepresentable {
    let title: String
    let geometry: LibraryToolbarGeometry
    var fillsColumnWidth = false

    func makeNSView(context: Context) -> TitleView {
        let view = TitleView()
        view.fillsColumnWidth = fillsColumnWidth
        view.geometry = geometry
        view.updateTitle(title)
        geometry.attachTitle(view)
        return view
    }

    func updateNSView(_ view: TitleView, context: Context) {
        view.fillsColumnWidth = fillsColumnWidth
        view.geometry = geometry
        view.updateTitle(title)
        geometry.attachTitle(view)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: TitleView, context: Context) -> CGSize? {
        // SwiftUI can ask for the new title's size before updateNSView runs.
        // Do not retain the previous (for example, "All Articles") allocation.
        nsView.fillsColumnWidth = fillsColumnWidth
        nsView.updateTitle(title)
        let size = nsView.intrinsicContentSize
        if fillsColumnWidth {
            if let proposedWidth = proposal.width {
                if proposedWidth <= 1 { return NSSize(width: max(0, proposedWidth), height: size.height) }
                return NSSize(width: proposedWidth.isFinite ? proposedWidth : 10000, height: size.height)
            }
            return NSSize(width: min(nsView.naturalLabelSize.width, 160), height: size.height)
        }
        return NSSize(width: min(size.width, proposal.width ?? min(size.width, 240)), height: size.height)
    }

    static func dismantleNSView(_ view: TitleView, coordinator: ()) {
        view.clearToolbarAllocation()
        view.geometry?.detachTitle(view)
        view.geometry = nil
    }

    final class TitleView: NSView {
        let label = NSTextField(labelWithString: "")
        weak var geometry: LibraryToolbarGeometry?
        var fillsColumnWidth = false {
            didSet {
                if oldValue != fillsColumnWidth {
                    invalidateIntrinsicContentSize()
                    updateLiveGeometry()
                }
            }
        }
        private var columnWidth: CGFloat?
        var measuredColumnWidth: CGFloat? { columnWidth }
        private var updatingGeometry = false
        private weak var sizingHost: NSView?
        private var toolbarWidthConstraint: NSLayoutConstraint?

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true
            layer?.masksToBounds = true
            label.font = NSFont.preferredFont(forTextStyle: .headline)
            label.textColor = .labelColor
            label.maximumNumberOfLines = 1
            label.lineBreakMode = .byTruncatingTail
            label.cell?.wraps = false
            label.cell?.isScrollable = false
            label.isSelectable = false
            label.wantsLayer = true
            label.layer?.masksToBounds = true
            label.setAccessibilityIdentifier("library.columnTitle.text")
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            addSubview(label)
        }

        required init?(coder: NSCoder) { nil }

        var naturalLabelSize: NSSize {
            let intrinsic = label.intrinsicContentSize
            let unlimited = NSRect(x: 0, y: 0,
                                   width: CGFloat.greatestFiniteMagnitude,
                                   height: CGFloat.greatestFiniteMagnitude)
            let fitted = label.sizeThatFits(unlimited.size)
            let cellSize = label.cell?.cellSize(forBounds: unlimited) ?? .zero
            return NSSize(
                width: ceil(max(intrinsic.width, max(fitted.width, cellSize.width))),
                height: ceil(max(intrinsic.height, max(fitted.height, cellSize.height)))
            )
        }

        override var intrinsicContentSize: NSSize {
            let natural = naturalLabelSize
            let cap = fillsColumnWidth ? (columnWidth ?? min(natural.width, 160)) : min(natural.width, columnWidth ?? natural.width)
            return NSSize(width: cap, height: natural.height)
        }

        override var mouseDownCanMoveWindow: Bool { true }

        override func hitTest(_ point: NSPoint) -> NSView? {
            guard fillsColumnWidth else { return super.hitTest(point) }
            let local = convert(point, from: superview)
            return label.frame.contains(local) ? super.hitTest(point) : nil
        }

        func updateTitle(_ title: String) {
            guard label.stringValue != title else { return }
            label.stringValue = title
            label.toolTip = title
            label.setAccessibilityLabel(title)
            invalidateIntrinsicContentSize()
            updateLiveGeometry()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil { clearToolbarAllocation() }
            updateLiveGeometry()
        }

        override func setFrameOrigin(_ newOrigin: NSPoint) {
            super.setFrameOrigin(newOrigin)
            updateLiveGeometry()
        }

        override func setFrameSize(_ newSize: NSSize) {
            super.setFrameSize(newSize)
            updateLiveGeometry()
        }

        override func layout() {
            super.layout()
            updateLiveGeometry()
        }

        func updateLiveGeometry() {
            guard !updatingGeometry else { return }
            updatingGeometry = true
            defer { updatingGeometry = false }
            // Allocation depends only on the column's width, never on the
            // toolbar item's current origin. Feeding that origin back into
            // intrinsic size makes native toolbar placement oscillate.
            let detailSpan = fillsColumnWidth ? geometry?.detailAvailableSpan(in: window, excluding: self) : nil
            let newColumnWidth = fillsColumnWidth ? detailSpan?.span : geometry?.columnWidth(in: window)
            if newColumnWidth != columnWidth {
                columnWidth = newColumnWidth
                invalidateIntrinsicContentSize()
            }
            updateToolbarAllocation()
            let labelFrame: NSRect
            if fillsColumnWidth,
               let insets = geometry?.detailLabelInsets(for: self, trailingLimit: detailSpan?.trailingLimit) {
                let natural = naturalLabelSize.width
                let maxInBounds = max(0, bounds.width - insets.leadingOffset)
                let labelWidth = min(natural, min(maxInBounds, insets.availableWidth))
                labelFrame = NSRect(x: insets.leadingOffset, y: 0, width: max(0, labelWidth), height: bounds.height)
            } else {
                let width = geometry?.availableWidth(for: self, trailingLimit: detailSpan?.trailingLimit) ?? 1
                labelFrame = NSRect(x: 0, y: 0, width: min(bounds.width, width), height: bounds.height)
            }
            if label.frame != labelFrame { label.frame = labelFrame }
        }

        func clearToolbarAllocation() {
            toolbarWidthConstraint?.isActive = false
            toolbarWidthConstraint = nil
            sizingHost = nil
        }

        private func updateToolbarAllocation() {
            guard let host = window?.toolbar?.items.first(where: { item in
                guard let view = item.view else { return false }
                return self === view || isDescendant(of: view)
            })?.view else { return }
            if sizingHost !== host {
                clearToolbarAllocation()
                sizingHost = host
                let constraint = host.widthAnchor.constraint(equalToConstant: max(1, intrinsicContentSize.width))
                constraint.priority = .defaultLow
                constraint.identifier = "library.columnTitle.width"
                toolbarWidthConstraint = constraint
                constraint.isActive = true
            } else if toolbarWidthConstraint?.constant != max(1, intrinsicContentSize.width) {
                toolbarWidthConstraint?.constant = max(1, intrinsicContentSize.width)
            }
        }
    }
}
