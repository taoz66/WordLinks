import AppKit
import SwiftUI

enum ReaderTextViewIdentity {
    static let article = NSUserInterfaceItemIdentifier("articleReaderText")
    static let intensive = NSUserInterfaceItemIdentifier("intensiveArticleReaderText")

    static func isReader(_ view: NSView) -> Bool {
        view.identifier == article || view.identifier == intensive
    }
}

/// Use the existing reader window so entering focus keeps its selection,
/// scroll position, and popover state in the same view hierarchy.
struct ReaderFocusWindow: NSViewRepresentable {
    let isActive: Bool
    let backgroundColor: NSColor
    let onToggle: () -> Void
    let onRegenerateIntensiveReading: () -> Void

    func makeNSView(context: Context) -> WindowAttachment {
        let view = WindowAttachment()
        view.onWindowChanged = { [weak coordinator = context.coordinator] window in
            coordinator?.attach(to: window)
        }
        context.coordinator.update(isActive: isActive, backgroundColor: backgroundColor,
                                   onToggle: onToggle,
                                   onRegenerateIntensiveReading: onRegenerateIntensiveReading)
        return view
    }

    func updateNSView(_ view: WindowAttachment, context: Context) {
        context.coordinator.update(isActive: isActive, backgroundColor: backgroundColor,
                                   onToggle: onToggle,
                                   onRegenerateIntensiveReading: onRegenerateIntensiveReading)
        context.coordinator.attach(to: view.window)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    static func dismantleNSView(_ view: WindowAttachment, coordinator: Coordinator) {
        view.onWindowChanged = nil
        coordinator.detach()
    }

    final class WindowAttachment: NSView {
        var onWindowChanged: ((NSWindow?) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            onWindowChanged?(window)
        }
    }

    @MainActor
    final class Coordinator {
        private weak var window: NSWindow?
        private var isActive = false
        private var appliedFocus = false
        private var backgroundColor = NSColor.windowBackgroundColor
        private var onToggle: (() -> Void)?
        private var onRegenerateIntensiveReading: (() -> Void)?
        private var observers: [NSObjectProtocol] = []
        private var activityMonitor: Any?
        private var toolbarContextMenuMonitor: Any?
        private var toolbarObservation: NSKeyValueObservation?
        private var voiceOverObservation: NSKeyValueObservation?
        private var chromeHideTimer: Timer?
        private var trackingMenus: Set<ObjectIdentifier> = []
        private var shownPopovers: Set<ObjectIdentifier> = []
        private var keyboardNavigationIsActive = false
        private(set) var focusChromeIsVisible = true
        private var chromeTransitionID = UUID()
        private var visibleFocusChromeHeight: CGFloat?
        private var currentContentSafeArea: ContentSafeArea?
        var chromeIdleDelay: TimeInterval = 3
        private var previousChrome: Chrome?
        private var previousSplitItems: [SplitItemState] = []
        private var pendingPolicyRestoreStates: [SplitItemState] = []
        private var splitAnimationGeneration = UUID()
        private var isUpdatingSplitItems = false

        private struct SplitItemState {
            let item: NSSplitViewItem
            let ancestorSplitLevel: Int
            let collapsed: Bool
            let canCollapse: Bool
            let collapseBehavior: NSSplitViewItem.CollapseBehavior
        }

        private struct Chrome {
            let titleVisibility: NSWindow.TitleVisibility
            let transparentTitlebar: Bool
            let separator: NSTitlebarSeparatorStyle
            let backgroundColor: NSColor
            let toolbarIsVisible: Bool?
            let acceptsMouseMovedEvents: Bool
            let contentSafeArea: ContentSafeArea?
            let buttons: [(button: NSButton, hidden: Bool)]
        }

        private struct ContentSafeArea {
            let view: NSView
            let additionalInsets: NSEdgeInsets
        }

        func update(isActive: Bool, backgroundColor: NSColor, onToggle: @escaping () -> Void,
                    onRegenerateIntensiveReading: @escaping () -> Void) {
            self.isActive = isActive
            self.backgroundColor = backgroundColor
            self.onToggle = onToggle
            self.onRegenerateIntensiveReading = onRegenerateIntensiveReading
            apply()
        }

        func attach(to window: NSWindow?) {
            guard self.window !== window else {
                configureToolbar()
                return
            }
            detach()
            self.window = window
            guard let window else { return }
            toolbarObservation = window.observe(\.toolbar, options: [.new]) { [weak self] _, _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.configureToolbar()
                    if self.appliedFocus && !self.focusChromeIsVisible { self.window?.toolbar?.isVisible = false }
                }
            }
            for name in [NSWindow.didEnterFullScreenNotification, NSWindow.didExitFullScreenNotification,
                         NSWindow.didBecomeKeyNotification] {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated {
                        let reconcilesSplit = name != NSWindow.didBecomeKeyNotification
                        self?.apply(reconcileFocusColumnsWithoutAnimation: reconcilesSplit)
                        self?.revealFocusChrome()
                    }
                })
            }
            installChromeActivityObservers()
            voiceOverObservation = NSWorkspace.shared.observe(\.isVoiceOverEnabled, options: [.new]) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.revealFocusChrome() }
            }
            activityMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDown, .rightMouseDown,
                                                                         .otherMouseDown, .keyDown, .flagsChanged,
                                                                         .mouseEntered]) { [weak self] event in
                MainActor.assumeIsolated { self?.recordActivity(event) }
                return event
            }
            toolbarContextMenuMonitor = NSEvent.addLocalMonitorForEvents(matching: [.rightMouseDown, .leftMouseDown]) { [weak self] event in
                let handled = MainActor.assumeIsolated {
                    guard let self, event.type == .rightMouseDown
                            || (event.type == .leftMouseDown && event.modifierFlags.contains(.control)) else { return false }
                    self.configureToolbar()
                    if let target = self.intensiveToolbarItemView(for: event) {
                        let point = self.eventLocation(event, in: target)
                        self.showIntensiveToolbarMenu(in: target, at: point)
                        return true
                    }
                    // Only the Intensive Reading control has a toolbar context menu.
                    // Library rows and article text retain their own native menus.
                    return self.isWindowChromeEvent(event)
                }
                return handled ? nil : event
            }
            apply()
        }

        func detach() {
            observers.forEach(NotificationCenter.default.removeObserver)
            observers.removeAll()
            if let activityMonitor { NSEvent.removeMonitor(activityMonitor) }
            activityMonitor = nil
            if let toolbarContextMenuMonitor { NSEvent.removeMonitor(toolbarContextMenuMonitor) }
            toolbarContextMenuMonitor = nil
            toolbarObservation?.invalidate()
            toolbarObservation = nil
            voiceOverObservation?.invalidate()
            voiceOverObservation = nil
            chromeHideTimer?.invalidate()
            chromeHideTimer = nil
            trackingMenus.removeAll()
            shownPopovers.removeAll()
            keyboardNavigationIsActive = false
            restoreSplitItems(animated: false)
            restoreChrome()
            window = nil
            appliedFocus = false
        }

        func intensiveToolbarItemView(for event: NSEvent) -> NSView? {
            guard let window,
                  isWindowChromeEvent(event),
                  let toolbar = window.toolbar, toolbar.isVisible else { return nil }
            let items = toolbar.visibleItems ?? toolbar.items

            func hitTarget(in view: NSView) -> NSView? {
                guard !view.isHiddenOrHasHiddenAncestor else { return nil }
                if view.identifier == IntensiveReadingToolbarHitTarget.identifier {
                    // Never accept a hosting view that has expanded to cover
                    // the reader. A marker is exactly the native button size.
                    guard view.bounds.width > 0, view.bounds.width <= 44,
                          view.bounds.height > 0, view.bounds.height <= 44 else { return nil }
                    let point = eventLocation(event, in: view)
                    // A nonclipping native host may expose a visibleRect beyond
                    // its own bounds; both rectangles must contain the click.
                    return view.bounds.contains(point) && view.visibleRect.contains(point) ? view : nil
                }
                return view.subviews.lazy.compactMap { hitTarget(in: $0) }.first
            }
            // A native ControlGroup shares one toolbar item. Route only the
            // Intensive Reading button's rectangle, leaving its neighbor clear.
            for item in items {
                guard let view = item.view, !view.isHiddenOrHasHiddenAncestor else { continue }
                if let target = hitTarget(in: view) { return target }
            }

            // Compatibility with a standalone toolbar item and native fixtures.
            guard let item = items.first(where: {
                let identifier = $0.itemIdentifier.rawValue
                return identifier.contains("reader.intensive")
                    || (!identifier.contains("reader.modes")
                        && ($0.label == L("精读", "Intensive Reading")
                            || $0.paletteLabel == L("精读", "Intensive Reading")))
            }), let view = item.view, !view.isHiddenOrHasHiddenAncestor,
                  view.bounds.width > 0, view.bounds.width <= 44,
                  view.bounds.height > 0, view.bounds.height <= 44 else { return nil }
            let point = eventLocation(event, in: view)
            return view.bounds.contains(point) && view.visibleRect.contains(point) ? view : nil
        }

        /// SwiftUI may share a toolbar hosting view with the content hierarchy.
        /// Its bounds are not a safe context-menu hit target: use the native
        /// titlebar band before inspecting any individual button marker.
        func isWindowChromeEvent(_ event: NSEvent) -> Bool {
            guard let window, let eventWindow = event.window else { return false }
            if eventWindow !== window {
                // AppKit can host this window's toolbar in an attached window
                // while full screen. Recognize it through our own public
                // toolbar views, without depending on its implementation class.
                guard ownsToolbarWindow(eventWindow) else { return false }
                return CGRect(origin: .zero, size: eventWindow.frame.size).contains(event.locationInWindow)
            }
            let point = event.locationInWindow
            return point.x >= 0 && point.x <= window.frame.width
                && point.y >= window.contentLayoutRect.maxY && point.y <= window.frame.height
        }

        private func ownsToolbarWindow(_ candidate: NSWindow?) -> Bool {
            guard let window, let candidate else { return false }
            return LibraryWindowOwnership.isToolbarChild(candidate, of: window)
        }

        private func eventLocation(_ event: NSEvent, in view: NSView) -> NSPoint {
            guard let sourceWindow = event.window, let targetWindow = view.window else {
                return view.convert(event.locationInWindow, from: nil)
            }
            let screenPoint = sourceWindow.convertPoint(toScreen: event.locationInWindow)
            return view.convert(targetWindow.convertPoint(fromScreen: screenPoint), from: nil)
        }

        private func configureToolbar() {
            guard let toolbar = window?.toolbar else { return }
            if toolbar.allowsUserCustomization { toolbar.allowsUserCustomization = false }
            if #available(macOS 15.0, *), toolbar.allowsDisplayModeCustomization {
                toolbar.allowsDisplayModeCustomization = false
            }
            if toolbar.displayMode != .iconOnly { toolbar.displayMode = .iconOnly }
        }

        private func showIntensiveToolbarMenu(in view: NSView, at point: NSPoint) {
            let menu = NSMenu()
            let item = NSMenuItem(title: L("重新生成", "Regenerate"),
                                  action: #selector(regenerateIntensiveReadingFromMenu(_:)),
                                  keyEquivalent: "")
            item.target = self
            menu.addItem(item)
            menu.popUp(positioning: nil, at: point, in: view)
        }

        @objc private func regenerateIntensiveReadingFromMenu(_ sender: NSMenuItem) {
            onRegenerateIntensiveReading?()
        }

        private func apply(reconcileFocusColumnsWithoutAnimation: Bool = false) {
            guard let window else { return }
            configureToolbar()
            if isActive {
                let enteringFocus = !appliedFocus
                if !appliedFocus {
                    previousChrome = Chrome(titleVisibility: window.titleVisibility,
                                            transparentTitlebar: window.titlebarAppearsTransparent,
                                            separator: window.titlebarSeparatorStyle,
                                            backgroundColor: window.backgroundColor,
                                            toolbarIsVisible: window.toolbar?.isVisible,
                                            acceptsMouseMovedEvents: window.acceptsMouseMovedEvents,
                                            contentSafeArea: window.contentView.map {
                                                ContentSafeArea(view: $0, additionalInsets: $0.additionalSafeAreaInsets)
                                            },
                                            buttons: [.closeButton, .miniaturizeButton, .zoomButton].compactMap {
                                                window.standardWindowButton($0).map { (button: $0, hidden: $0.isHidden) }
                                            })
                    appliedFocus = true
                    currentContentSafeArea = previousChrome?.contentSafeArea
                    window.acceptsMouseMovedEvents = true
                    window.titleVisibility = .hidden
                    window.titlebarAppearsTransparent = true
                    window.titlebarSeparatorStyle = .none
                    window.backgroundColor = backgroundColor
                    revealFocusChrome()
                }
                if enteringFocus || previousSplitItems.isEmpty || reconcileFocusColumnsWithoutAnimation {
                    collapseLibraryColumns(animated: enteringFocus && !reconcileFocusColumnsWithoutAnimation)
                }
                reserveHiddenChromeSpace()
            } else {
                if appliedFocus {
                    restoreChrome()
                    restoreSplitItems(animated: true)
                    appliedFocus = false
                }
            }
        }

        /// NavigationSplitView's detailOnly visibility can be ignored on macOS.
        /// Collapse native siblings along the existing reader's path as well.
        private func collapseLibraryColumns(animated: Bool) {
            guard !isUpdatingSplitItems, let root = window?.contentView else { return }
            isUpdatingSplitItems = true
            defer { isUpdatingSplitItems = false }
            splitAnimationGeneration = UUID()

            func reader(in view: NSView) -> NSView? {
                if ReaderTextViewIdentity.isReader(view) { return view }
                return view.subviews.lazy.compactMap { reader(in: $0) }.first
            }
            guard let textView = reader(in: root) else { return }
            var ancestor: NSView? = textView.superview
            var ancestorSplitLevel = 0
            var itemsToCollapse: [NSSplitViewItem] = []
            while let view = ancestor {
                if let split = view as? NSSplitView, split.isVertical,
                   let controller = split.delegate as? NSSplitViewController {
                    for item in controller.splitViewItems {
                        let keepsReader = textView === item.viewController.view || textView.isDescendant(of: item.viewController.view)
                        if !previousSplitItems.contains(where: { $0.item === item }) {
                            let saved = pendingPolicyRestoreStates.first(where: { $0.item === item })
                            previousSplitItems.append(saved ?? SplitItemState(item: item,
                                                                              ancestorSplitLevel: ancestorSplitLevel,
                                                                              collapsed: item.isCollapsed,
                                                                              canCollapse: item.canCollapse,
                                                                              collapseBehavior: item.collapseBehavior))
                        }
                        if keepsReader {
                            itemsToCollapse.append(item)
                        } else {
                            item.canCollapse = true
                            item.collapseBehavior = .preferResizingSiblingsWithFixedSplitView
                            itemsToCollapse.append(item)
                        }
                    }
                    ancestorSplitLevel += 1
                }
                ancestor = view.superview
            }
            pendingPolicyRestoreStates.removeAll()
            animateSplitItemChanges(itemsToCollapse, animated: animated) { item in
                let keepsReader = textView === item.viewController.view || textView.isDescendant(of: item.viewController.view)
                return !keepsReader
            }
        }

        private func animateSplitItemChanges(_ items: [NSSplitViewItem], animated: Bool,
                                             duration: TimeInterval? = nil,
                                             target: (NSSplitViewItem) -> Bool,
                                             onComplete: (() -> Void)? = nil) {
            let changes = items.filter { $0.isCollapsed != target($0) }
            guard !changes.isEmpty else {
                onComplete?()
                return
            }
            if animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                let activeWindow = window
                let token = ReaderSplitAnimationCoordinator.shared.beginTransition(for: activeWindow, maxDuration: 0.65)
                NSAnimationContext.runAnimationGroup { context in
                    if let duration { context.duration = duration }
                    for item in changes { item.animator().isCollapsed = target(item) }
                } completionHandler: { [weak activeWindow] in
                    MainActor.assumeIsolated {
                        onComplete?()
                        ReaderSplitAnimationCoordinator.shared.endTransition(for: activeWindow, token: token)
                    }
                }
            } else {
                for item in changes { item.isCollapsed = target(item) }
                onComplete?()
            }
        }

        private func restoreSplitItems(animated: Bool) {
            guard !isUpdatingSplitItems else { return }
            isUpdatingSplitItems = true
            defer { isUpdatingSplitItems = false }
            let generation = UUID()
            splitAnimationGeneration = generation
            // Establish each parent split's final topology before expanding
            // its nested content. Preserve item order within the same split.
            let states = previousSplitItems.enumerated().sorted { first, second in
                if first.element.ancestorSplitLevel != second.element.ancestorSplitLevel {
                    return first.element.ancestorSplitLevel > second.element.ancestorSplitLevel
                }
                return first.offset < second.offset
            }.map(\.element)
            previousSplitItems.removeAll()
            pendingPolicyRestoreStates = states
            for state in states where state.item.collapseBehavior != state.collapseBehavior {
                state.item.collapseBehavior = state.collapseBehavior
            }

            let applyCanCollapse: ([SplitItemState]) -> Void = { [weak self] batch in
                guard let self, self.splitAnimationGeneration == generation else { return }
                for state in batch where state.item.canCollapse != state.canCollapse {
                    state.item.canCollapse = state.canCollapse
                }
                if self.pendingPolicyRestoreStates.allSatisfy({ state in
                    state.item.isCollapsed == state.collapsed && state.item.canCollapse == state.canCollapse
                }) {
                    self.pendingPolicyRestoreStates.removeAll()
                }
            }

            let expandingSidebarAndContent = animated
                && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
                && states.contains(where: { !$0.collapsed && $0.item.isCollapsed && $0.item.behavior == .sidebar })
                && states.contains(where: { !$0.collapsed && $0.item.isCollapsed && $0.item.behavior != .sidebar })

            if expandingSidebarAndContent {
                // Stage 1: animate the content column (0 -> 200 pt) while sidebar stays collapsed,
                // then restore content's non-collapsible policy so Stage 2's sidebar slide (0 -> 144 pt)
                // pushes content smoothly to 344 pt with no completion snap.
                let nonSidebarStates = states.filter { $0.item.behavior != .sidebar }
                let sidebarStates = states.filter { $0.item.behavior == .sidebar }
                let activeWindow = window
                let fullTransitionToken = ReaderSplitAnimationCoordinator.shared.beginTransition(for: activeWindow, maxDuration: 0.7)
                animateSplitItemChanges(nonSidebarStates.map(\.item), animated: true, duration: 0.14, target: { item in
                    nonSidebarStates.first(where: { $0.item === item })?.collapsed ?? item.isCollapsed
                }, onComplete: { [weak self, weak activeWindow] in
                    guard let self, self.splitAnimationGeneration == generation else {
                        ReaderSplitAnimationCoordinator.shared.endTransition(for: activeWindow, token: fullTransitionToken)
                        return
                    }
                    applyCanCollapse(nonSidebarStates)
                    self.animateSplitItemChanges(sidebarStates.map(\.item), animated: true, duration: 0.16, target: { item in
                        sidebarStates.first(where: { $0.item === item })?.collapsed ?? item.isCollapsed
                    }, onComplete: { [weak self, weak activeWindow] in
                        applyCanCollapse(sidebarStates)
                        self?.pendingPolicyRestoreStates.removeAll()
                        ReaderSplitAnimationCoordinator.shared.endTransition(for: activeWindow, token: fullTransitionToken)
                    })
                })
                return
            }

            // Keep items collapsible while animating open so AppKit animates both columns
            // smoothly instead of snapping contentList at frame 0, then restore canCollapse.
            animateSplitItemChanges(states.map(\.item), animated: animated, target: { item in
                states.first(where: { $0.item === item })?.collapsed ?? item.isCollapsed
            }, onComplete: { [weak self] in
                applyCanCollapse(states)
                self?.pendingPolicyRestoreStates.removeAll()
            })
        }

        private func restoreChrome() {
            guard let window, let chrome = previousChrome else { return }
            chromeHideTimer?.invalidate()
            chromeHideTimer = nil
            chromeTransitionID = UUID()
            focusChromeIsVisible = true
            keyboardNavigationIsActive = false
            window.titleVisibility = chrome.titleVisibility
            window.titlebarAppearsTransparent = chrome.transparentTitlebar
            window.titlebarSeparatorStyle = chrome.separator
            window.backgroundColor = chrome.backgroundColor
            window.acceptsMouseMovedEvents = chrome.acceptsMouseMovedEvents
            if let isVisible = chrome.toolbarIsVisible { window.toolbar?.isVisible = isVisible }
            restoreContentSafeArea()
            visibleFocusChromeHeight = nil
            for view in toolbarViews { view.alphaValue = 1 }
            for state in chrome.buttons {
                state.button.alphaValue = 1
                state.button.isHidden = state.hidden
            }
            previousChrome = nil
        }

        private func restoreContentSafeArea() {
            if let state = currentContentSafeArea {
                state.view.additionalSafeAreaInsets = state.additionalInsets
            }
            currentContentSafeArea = nil
        }

        /// Removing a native toolbar grows the content layout rect. Preserve
        /// its former reading boundary with a public safe-area inset, so text
        /// and selection remain still while the controls appear and disappear.
        private func reserveHiddenChromeSpace() {
            guard appliedFocus, !focusChromeIsVisible,
                  let window, window.toolbar?.isVisible == false,
                  let view = window.contentView, let visibleFocusChromeHeight else { return }
            if currentContentSafeArea?.view !== view {
                restoreContentSafeArea()
                currentContentSafeArea = ContentSafeArea(view: view, additionalInsets: view.additionalSafeAreaInsets)
            }
            guard let state = currentContentSafeArea else { return }
            let currentChromeHeight = window.frame.height - window.contentLayoutRect.maxY
            var insets = state.additionalInsets
            insets.top += max(0, visibleFocusChromeHeight - currentChromeHeight)
            let existing = view.additionalSafeAreaInsets
            if abs(existing.top - insets.top) > 0.01 || abs(existing.left - insets.left) > 0.01
                || abs(existing.bottom - insets.bottom) > 0.01 || abs(existing.right - insets.right) > 0.01 {
                view.additionalSafeAreaInsets = insets
            }
        }

        private var toolbarViews: [NSView] {
            guard let window else { return [] }
            return window.toolbar?.items.compactMap(\.view).filter { view in
                let frame = view.convert(view.bounds, to: nil)
                // A shared SwiftUI hosting view can include the entire
                // document. Only fade actual, compact native toolbar views.
                return view.bounds.height > 0 && view.bounds.height <= 64
                    && frame.maxY >= window.contentLayoutRect.maxY
            } ?? []
        }

        private func installChromeActivityObservers() {
            for name in [NSMenu.didBeginTrackingNotification, NSMenu.didEndTrackingNotification] {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                    MainActor.assumeIsolated {
                        guard let self, let menu = notification.object as? NSMenu else { return }
                        let identifier = ObjectIdentifier(menu)
                        if notification.name == NSMenu.didBeginTrackingNotification {
                            guard self.window?.isKeyWindow == true else { return }
                            self.trackingMenus.insert(identifier)
                        } else {
                            guard self.trackingMenus.remove(identifier) != nil else { return }
                        }
                        self.revealFocusChrome()
                    }
                })
            }
            for name in [NSPopover.willShowNotification, NSPopover.didCloseNotification] {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                    MainActor.assumeIsolated {
                        guard let self, let popover = notification.object as? NSPopover else { return }
                        let identifier = ObjectIdentifier(popover)
                        if notification.name == NSPopover.willShowNotification {
                            guard self.window?.isKeyWindow == true else { return }
                            self.shownPopovers.insert(identifier)
                        } else {
                            guard self.shownPopovers.remove(identifier) != nil else { return }
                        }
                        self.revealFocusChrome()
                    }
                })
            }
        }

        /// Cursor movement and keyboard use reveal the same native controls;
        /// scrolling alone leaves uninterrupted reading free of chrome.
        func recordActivity(_ event: NSEvent) {
            guard let window, event.window === window || ownsToolbarWindow(event.window) else { return }
            if event.type == .mouseMoved || event.type == .leftMouseDown || event.type == .rightMouseDown {
                keyboardNavigationIsActive = false
            } else if event.type == .keyDown,
                      event.keyCode == 48 || (event.keyCode == 96 && event.modifierFlags.contains(.control)) {
                // Tab navigation and the system Control-F5 toolbar shortcut
                // keep controls reachable until pointer interaction resumes.
                keyboardNavigationIsActive = true
            }
            revealFocusChrome()
        }

        func revealFocusChrome() {
            guard isActive, appliedFocus else { return }
            setFocusChromeVisible(true, animated: true)
            scheduleChromeHide()
        }

        private func scheduleChromeHide() {
            chromeHideTimer?.invalidate()
            chromeHideTimer = nil
            guard isActive, appliedFocus, !NSWorkspace.shared.isVoiceOverEnabled else { return }
            let timer = Timer(timeInterval: chromeIdleDelay, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.hideFocusChromeIfIdle() }
            }
            RunLoop.main.add(timer, forMode: .common)
            chromeHideTimer = timer
        }

        private func hideFocusChromeIfIdle() {
            guard isActive, appliedFocus, let window else { return }
            let pointer = window.convertPoint(fromScreen: NSEvent.mouseLocation)
            let pointerInMainChrome = pointer.x >= 0 && pointer.x <= window.frame.width
                && pointer.y >= window.contentLayoutRect.maxY && pointer.y <= window.frame.height
            let pointerInToolbarWindow = window.childWindows?.contains {
                ownsToolbarWindow($0) && $0.isVisible && $0.frame.contains(NSEvent.mouseLocation)
            } == true
            let pointerInChrome = window.isKeyWindow && (pointerInMainChrome || pointerInToolbarWindow)
            let hasToolbarKeyboardFocus = (window.firstResponder as? NSView).map { responder in
                toolbarViews.contains { view in responder === view || responder.isDescendant(of: view) }
            } ?? false
            let needsControls = NSWorkspace.shared.isVoiceOverEnabled || keyboardNavigationIsActive || pointerInChrome
                || window.attachedSheet != nil || !trackingMenus.isEmpty || !shownPopovers.isEmpty
                || hasToolbarKeyboardFocus || window.childWindows?.contains(where: {
                    $0.isVisible && !ownsToolbarWindow($0)
                }) == true
                || NSEvent.pressedMouseButtons != 0 || window.inLiveResize
            if needsControls {
                scheduleChromeHide()
            } else {
                setFocusChromeVisible(false, animated: true)
            }
        }

        /// Visibility changes use the existing AppKit toolbar and window
        /// buttons. No replica controls or custom glass surfaces are added.
        func setFocusChromeVisible(_ visible: Bool, animated: Bool) {
            guard isActive, appliedFocus, let window, visible != focusChromeIsVisible else { return }
            chromeTransitionID = UUID()
            let transitionID = chromeTransitionID
            focusChromeIsVisible = visible
            if visible {
                window.toolbar?.isVisible = true
                if let state = currentContentSafeArea { state.view.additionalSafeAreaInsets = state.additionalInsets }
                for state in previousChrome?.buttons ?? [] { state.button.isHidden = state.hidden }
            }
            let views = toolbarViews + (previousChrome?.buttons.map(\.button) ?? [])
            let alpha: CGFloat = visible ? 1 : 0
            let finish = { [weak self, weak window] in
                guard let self, self.chromeTransitionID == transitionID, self.appliedFocus else { return }
                if !visible {
                    if let window {
                        self.visibleFocusChromeHeight = window.frame.height - window.contentLayoutRect.maxY
                    }
                    window?.toolbar?.isVisible = false
                    self.reserveHiddenChromeSpace()
                    for state in self.previousChrome?.buttons ?? [] { state.button.isHidden = true }
                }
            }
            if animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.18
                    for view in views { view.animator().alphaValue = alpha }
                } completionHandler: {
                    MainActor.assumeIsolated { finish() }
                }
            } else {
                for view in views { view.alphaValue = alpha }
                finish()
            }
        }
    }
}
