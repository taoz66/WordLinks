import AppKit
import QuartzCore

/// Coordinates animated split-column transitions (sidebar toggles and focus-mode entry/exit)
/// per window so reader text views wait for all columns to finish sliding before reflowing.
@MainActor
final class ReaderSplitAnimationCoordinator {
    static let shared = ReaderSplitAnimationCoordinator()

    private struct WeakObserver {
        weak var target: AnyObject?
        let handler: () -> Void
    }

    private final class WindowState {
        var activeTokens: [UUID: DispatchWorkItem] = [:]
        var observers: [WeakObserver] = []
    }

    private var states: [ObjectIdentifier: WindowState] = [:]

    func beginTransition(for window: NSWindow?, maxDuration: TimeInterval = 0.65) -> UUID {
        let token = UUID()
        guard let window else { return token }
        let key = ObjectIdentifier(window)
        let state = states[key] ?? WindowState()
        states[key] = state
        let timeout = DispatchWorkItem { [weak self, weak window] in
            self?.endTransition(for: window, token: token)
        }
        state.activeTokens[token] = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + maxDuration, execute: timeout)
        return token
    }

    func endTransition(for window: NSWindow?, token: UUID) {
        guard let window else { return }
        let key = ObjectIdentifier(window)
        guard let state = states[key], let timeout = state.activeTokens.removeValue(forKey: token) else {
            return
        }
        timeout.cancel()
        if state.activeTokens.isEmpty {
            state.observers.removeAll { $0.target == nil }
            let handlers = state.observers.map(\.handler)
            if state.observers.isEmpty {
                states.removeValue(forKey: key)
            }
            for handler in handlers {
                handler()
            }
        }
    }

    func isTransitionActive(for window: NSWindow?) -> Bool {
        guard let window else { return false }
        let key = ObjectIdentifier(window)
        return states[key]?.activeTokens.isEmpty == false
    }

    func registerFlushObserver(_ target: AnyObject, in window: NSWindow?, handler: @escaping () -> Void) {
        guard let window else { return }
        let key = ObjectIdentifier(window)
        let state = states[key] ?? WindowState()
        states[key] = state
        state.observers.removeAll { $0.target == nil || $0.target === target }
        state.observers.append(WeakObserver(target: target, handler: handler))
    }

    func unregisterFlushObserver(_ target: AnyObject, in window: NSWindow?) {
        guard let window else { return }
        let key = ObjectIdentifier(window)
        guard let state = states[key] else { return }
        state.observers.removeAll { $0.target == nil || $0.target === target }
        if state.activeTokens.isEmpty && state.observers.isEmpty {
            states.removeValue(forKey: key)
        }
    }
}

/// Shared split-resize reflow controller for reader `NSTextView` subclasses.
/// Short passages reflow live at full frame rate; longer documents hold their
/// line breaks until split animations complete and crossfade smoothly into the new layout.
@MainActor
final class ReaderSplitReflowController {
    static let liveReflowUTF16Limit = 2_200

    private weak var textView: NSTextView?
    private weak var observedWindow: NSWindow?
    private let onFlush: (_ lockedWidth: CGFloat, _ crossfade: Bool) -> Void
    private(set) var deferredTextWidth: CGFloat?
    private var flushWork: DispatchWorkItem?

    init(textView: NSTextView, onFlush: @escaping (_ lockedWidth: CGFloat, _ crossfade: Bool) -> Void) {
        self.textView = textView
        self.onFlush = onFlush
    }

    var isAnimatingSplitResize: Bool {
        guard let textView else { return false }
        let appKitLiveSplit = textView.inLiveResize && !(textView.window?.inLiveResize ?? false)
        let coordinatedTransition = ReaderSplitAnimationCoordinator.shared.isTransitionActive(for: textView.window)
        return appKitLiveSplit || coordinatedTransition
    }

    func willMove(toWindow newWindow: NSWindow?) {
        if let observedWindow, let textView, observedWindow !== newWindow {
            ReaderSplitAnimationCoordinator.shared.unregisterFlushObserver(textView, in: observedWindow)
            self.observedWindow = nil
        }
    }

    func didMoveToWindow() {
        guard let textView, let window = textView.window else { return }
        if observedWindow !== window {
            observedWindow = window
            ReaderSplitAnimationCoordinator.shared.registerFlushObserver(textView, in: window) { [weak self] in
                self?.flushIfSettled()
            }
        }
        flushIfSettled()
    }

    func shouldDeferReflow(newTextWidth: CGFloat, currentWidth: CGFloat, utf16Length: Int) -> Bool {
        guard isAnimatingSplitResize else { return false }
        if deferredTextWidth != nil { return true }
        guard utf16Length > Self.liveReflowUTF16Limit else { return false }
        return abs(newTextWidth - currentWidth) > 0.5
    }

    /// Returns true if this call initiated a new deferral window.
    @discardableResult
    func beginOrContinueDeferral(currentContainerWidth: CGFloat) -> Bool {
        let started = deferredTextWidth == nil
        if started {
            deferredTextWidth = currentContainerWidth
        }
        scheduleFlush()
        return started
    }

    func clearPendingDeferral() {
        flushWork?.cancel()
        flushWork = nil
        deferredTextWidth = nil
    }

    func flushIfSettled() {
        guard deferredTextWidth != nil, !isAnimatingSplitResize else { return }
        flush()
    }

    func flush() {
        flushWork?.cancel()
        flushWork = nil
        guard let lockedWidth = deferredTextWidth else { return }
        deferredTextWidth = nil
        onFlush(lockedWidth, true)
    }

    private func scheduleFlush() {
        flushWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.deferredTextWidth != nil else { return }
            if self.isAnimatingSplitResize {
                self.scheduleFlush()
            } else {
                self.flush()
            }
        }
        flushWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.04, execute: work)
    }

    static func applyCrossfadeIfNeeded(to textView: NSTextView, enabled: Bool) {
        guard enabled, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let targetView: NSView = textView.enclosingScrollView?.contentView ?? textView
        if !targetView.wantsLayer { targetView.wantsLayer = true }
        let transition = CATransition()
        transition.type = .fade
        transition.duration = 0.16
        transition.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        targetView.layer?.add(transition, forKey: "readerSplitReflowFade")
    }
}
