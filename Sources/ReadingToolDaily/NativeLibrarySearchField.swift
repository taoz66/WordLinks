import AppKit
import SwiftUI

/// Native search affordances without changing the scope of the surrounding list.
struct NativeLibrarySearchField: NSViewRepresentable {
    let prompt: String
    @Binding var text: String
    var isFocused: Binding<Bool>? = nil
    var onSubmit: () -> Void = {}
    var onCancel: (() -> Void)? = nil
    @Environment(\.isEnabled) private var isEnabled

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.controlSize = .regular
        field.sendsWholeSearchString = false
        field.sendsSearchStringImmediately = true
        field.delegate = context.coordinator
        field.target = context.coordinator
        field.action = #selector(Coordinator.searchChanged(_:))
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        updateNSView(field, context: context)
        return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
        context.coordinator.parent = self
        field.placeholderString = prompt
        field.setAccessibilityLabel(prompt)
        field.isEnabled = isEnabled
        // Do not replace an in-progress input-method composition or its selection.
        if field.stringValue != text, (field.currentEditor() as? NSTextView)?.hasMarkedText() != true {
            field.stringValue = text
        }
        context.coordinator.requestFocusIfNeeded(in: field)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSSearchField, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 240, height: nsView.intrinsicContentSize.height)
    }

    @MainActor
    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var parent: NativeLibrarySearchField
        private var focusRequestPending = false

        init(parent: NativeLibrarySearchField) { self.parent = parent }

        func requestFocusIfNeeded(in field: NSSearchField) {
            guard parent.isFocused?.wrappedValue == true, field.currentEditor() == nil,
                  !focusRequestPending else { return }
            focusRequestPending = true
            DispatchQueue.main.async { [weak self, weak field] in
                guard let self else { return }
                self.focusRequestPending = false
                guard self.parent.isFocused?.wrappedValue == true, let field,
                      let window = field.window else { return }
                window.makeFirstResponder(field)
            }
        }

        @objc func searchChanged(_ field: NSSearchField) {
            updateText(from: field)
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSSearchField else { return }
            updateText(from: field)
        }

        func controlTextDidBeginEditing(_ notification: Notification) {
            if parent.isFocused?.wrappedValue == false { parent.isFocused?.wrappedValue = true }
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            if let field = notification.object as? NSSearchField { updateText(from: field) }
            if parent.isFocused?.wrappedValue == true { parent.isFocused?.wrappedValue = false }
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                if let field = control as? NSSearchField { updateText(from: field) }
                parent.onSubmit()
                return true
            }
            if commandSelector == #selector(NSResponder.cancelOperation(_:)), let onCancel = parent.onCancel {
                onCancel()
                return true
            }
            return false
        }

        private func updateText(from field: NSSearchField) {
            guard (field.currentEditor() as? NSTextView)?.hasMarkedText() != true else { return }
            if parent.text != field.stringValue { parent.text = field.stringValue }
        }
    }
}

/// Let the system own the control layer and its transition into scrolling content.
private struct NativeLibraryControlBar<Bar: View>: ViewModifier {
    let edge: VerticalEdge
    let isPresented: Bool
    let bar: Bar

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content
                .safeAreaBar(edge: edge, spacing: 0) {
                    if isPresented { bar }
                }
                .scrollEdgeEffectStyle(.soft, for: edge == .top ? .top : .bottom)
        } else {
            content.safeAreaInset(edge: edge, spacing: 0) {
                if isPresented { bar.background(.bar) }
            }
        }
    }
}

extension View {
    func nativeLibraryControlBar<Bar: View>(edge: VerticalEdge = .top,
                                            isPresented: Bool = true,
                                            @ViewBuilder content: () -> Bar) -> some View {
        modifier(NativeLibraryControlBar(edge: edge, isPresented: isPresented, bar: content()))
    }
}
