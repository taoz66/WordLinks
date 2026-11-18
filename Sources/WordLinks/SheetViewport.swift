import AppKit
import SwiftUI

/// Keep a native sheet within the current display while leaving its body resizable.
@MainActor
private struct SheetViewport: ViewModifier {
    let preferredSize: NSSize
    let minimumSize: NSSize
    @State private var availableSize = NSScreen.main?.visibleFrame.insetBy(dx: 20, dy: 20).size
        ?? NSSize(width: 1000, height: 700)

    func body(content: Content) -> some View {
        let sizedContent = content
            .frame(minWidth: min(minimumSize.width, availableSize.width),
                   idealWidth: min(preferredSize.width, availableSize.width),
                   maxWidth: availableSize.width,
                   minHeight: min(minimumSize.height, availableSize.height),
                   idealHeight: min(preferredSize.height, availableSize.height),
                   maxHeight: availableSize.height)
            .background {
                SheetViewportProbe(preferredSize: preferredSize, minimumSize: minimumSize) { size in
                    if abs(availableSize.width - size.width) > 0.5 ||
                        abs(availableSize.height - size.height) > 0.5 {
                        availableSize = size
                    }
                }
                .frame(width: 0, height: 0)
            }
        if #available(macOS 15.0, *) {
            // Native sheet presentation must use the ideal size before its
            // opening animation, rather than resizing an already visible sheet.
            sizedContent.presentationSizing(.fitted)
        } else {
            sizedContent
        }
    }
}

extension View {
    func sheetViewport(preferredSize: NSSize, minimumSize: NSSize) -> some View {
        modifier(SheetViewport(preferredSize: preferredSize, minimumSize: minimumSize))
    }
}

private struct SheetViewportProbe: NSViewRepresentable {
    let preferredSize: NSSize
    let minimumSize: NSSize
    let availableSizeChanged: (NSSize) -> Void

    func makeNSView(context: Context) -> ProbeView {
        let view = ProbeView()
        view.preferredSize = preferredSize
        view.minimumSize = minimumSize
        view.availableSizeChanged = availableSizeChanged
        return view
    }

    func updateNSView(_ view: ProbeView, context: Context) {
        view.preferredSize = preferredSize
        view.minimumSize = minimumSize
        view.availableSizeChanged = availableSizeChanged
        view.scheduleUpdate()
    }

    final class ProbeView: NSView {
        var preferredSize = NSSize(width: 880, height: 740)
        var minimumSize = NSSize(width: 580, height: 440)
        var availableSizeChanged: ((NSSize) -> Void)?
        private var updateScheduled = false

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            NotificationCenter.default.removeObserver(self)
            guard let window else { return }
            NotificationCenter.default.addObserver(self, selector: #selector(screenDidChange),
                                                   name: NSWindow.didChangeScreenNotification, object: window)
            NotificationCenter.default.addObserver(self, selector: #selector(screenDidChange),
                                                   name: NSApplication.didChangeScreenParametersNotification, object: nil)
            // macOS 14 has no presentationSizing API. Supply the same ideal
            // size synchronously, while the sheet is still being attached.
            if #unavailable(macOS 15.0) {
                updateViewport(initialSize: preferredSize)
            }
            scheduleUpdate()
        }

        @objc private func screenDidChange(_ notification: Notification) { scheduleUpdate() }

        func scheduleUpdate() {
            guard !updateScheduled else { return }
            updateScheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.updateScheduled = false
                self.updateViewport()
            }
        }

        private func updateViewport(initialSize: NSSize? = nil) {
            guard let window, let screen = window.screen ?? window.sheetParent?.screen ?? NSScreen.main else { return }
            let visible = screen.visibleFrame.insetBy(dx: 20, dy: 20)
            let content = window.contentRect(forFrameRect: visible).size
            let available = NSSize(width: max(1, content.width), height: max(1, content.height))
            DispatchQueue.main.async { [weak self] in self?.availableSizeChanged?(available) }
            window.contentMinSize = NSSize(width: min(minimumSize.width, available.width),
                                           height: min(minimumSize.height, available.height))
            window.contentMaxSize = available
            let current = window.contentRect(forFrameRect: window.frame).size
            // Subsequent screen or layout changes only constrain the user's
            // current size. Never replace it with the initial preferred size.
            let proposed = initialSize ?? current
            let fitted = NSSize(width: min(proposed.width, available.width),
                                height: min(proposed.height, available.height))
            if abs(current.width - fitted.width) > 0.5 || abs(current.height - fitted.height) > 0.5 {
                window.setContentSize(fitted)
            }
        }
    }
}
