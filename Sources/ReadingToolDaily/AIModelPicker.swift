import AppKit
import SwiftUI

/// A real popup keeps the model title and its menu anchored to the form's input column.
@MainActor
struct AIModelPicker: NSViewRepresentable {
    let models: [String]
    let selectedModel: String
    let isFetching: Bool
    let canFetch: Bool
    let onSelect: (String) -> Void
    let onFetch: () -> Void
    let onManualEntry: () -> Void
    @Environment(\.isEnabled) private var isEnabled

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> NSPopUpButton {
        let control = NSPopUpButton(frame: .zero, pullsDown: false)
        control.controlSize = .regular
        control.bezelStyle = .rounded
        control.alignment = .left
        control.font = .systemFont(ofSize: NSFont.systemFontSize)
        control.lineBreakMode = .byTruncatingMiddle
        control.target = context.coordinator
        control.action = #selector(Coordinator.selectItem(_:))
        control.setContentHuggingPriority(.defaultLow, for: .horizontal)
        control.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return control
    }

    func updateNSView(_ control: NSPopUpButton, context: Context) {
        context.coordinator.parent = self
        let menu = NSMenu()
        menu.autoenablesItems = false
        if selectedModel.isEmpty || !models.contains(selectedModel) {
            let placeholder = NSMenuItem(title: selectedModel.isEmpty ? L("选择模型", "Choose a model") : selectedModel,
                                         action: nil, keyEquivalent: "")
            placeholder.isEnabled = !selectedModel.isEmpty
            if !selectedModel.isEmpty { placeholder.representedObject = selectedModel }
            menu.addItem(placeholder)
        }
        for model in models {
            let item = NSMenuItem(title: model, action: nil, keyEquivalent: "")
            item.representedObject = model
            item.toolTip = model
            item.state = model == selectedModel ? .on : .off
            menu.addItem(item)
        }
        if !models.isEmpty || !selectedModel.isEmpty { menu.addItem(.separator()) }
        let fetch = NSMenuItem(title: isFetching ? L("正在获取模型…", "Fetching models…") :
                               L("获取模型列表", "Fetch model list"), action: nil, keyEquivalent: "")
        fetch.tag = Coordinator.fetchTag
        fetch.isEnabled = canFetch && !isFetching
        fetch.setAccessibilityIdentifier("ai.custom.fetchModels")
        menu.addItem(fetch)
        let manual = NSMenuItem(title: L("手动输入模型 ID…", "Enter model ID…"), action: nil, keyEquivalent: "")
        manual.tag = Coordinator.manualTag
        manual.setAccessibilityIdentifier("ai.custom.enterModel")
        menu.addItem(manual)
        control.menu = menu
        context.coordinator.restoreSelection(control)
        control.isEnabled = isEnabled
        control.toolTip = selectedModel.isEmpty ? L("获取模型列表，或手动输入模型 ID", "Fetch the model list or enter a model ID") : selectedModel
        control.setAccessibilityIdentifier("ai.custom.model")
        control.setAccessibilityLabel(L("模型", "Model"))
        control.setAccessibilityValue(selectedModel)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSPopUpButton, context: Context) -> NSSize? {
        NSSize(width: max(0, min(proposal.width ?? 260, 260)),
               height: nsView.intrinsicContentSize.height)
    }

    @MainActor
    final class Coordinator: NSObject {
        static let fetchTag = -1
        static let manualTag = -2
        var parent: AIModelPicker

        init(parent: AIModelPicker) { self.parent = parent }

        func restoreSelection(_ control: NSPopUpButton) {
            if let item = control.itemArray.first(where: { ($0.representedObject as? String) == parent.selectedModel }) {
                control.select(item)
            } else {
                control.selectItem(at: 0)
            }
        }

        @objc func selectItem(_ control: NSPopUpButton) {
            guard let item = control.selectedItem else { return }
            // Menu commands are actions, so the displayed model remains the selection.
            restoreSelection(control)
            if item.tag == Self.fetchTag {
                guard parent.canFetch, !parent.isFetching else { return }
                parent.onFetch()
            } else if item.tag == Self.manualTag {
                parent.onManualEntry()
            } else if let model = item.representedObject as? String {
                parent.onSelect(model)
            }
        }
    }
}
