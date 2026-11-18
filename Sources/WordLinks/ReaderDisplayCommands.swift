import SwiftUI

/// The reading window's display state for the View menu. The scene publishes
/// it, so commands follow whichever window is key instead of a stored copy.
struct ReaderDisplayCommandState {
    let isFocusAvailable: Bool
    let isFocused: Bool
    let onToggleFocus: () -> Void
    /// The current article's own model; nil when no article is open.
    let intensiveModel: IntensiveReadingModel?
    let isStudyDisplayAvailable: Bool
    let showsMeanings: Bool
    let showsExamples: Bool
    let onSetShowsMeanings: (Bool) -> Void
    let onSetShowsExamples: (Bool) -> Void
}

private struct ReaderDisplayCommandKey: FocusedValueKey {
    typealias Value = ReaderDisplayCommandState
}

extension FocusedValues {
    var readerDisplay: ReaderDisplayCommandState? {
        get { self[ReaderDisplayCommandKey.self] }
        set { self[ReaderDisplayCommandKey.self] = newValue }
    }
}

/// View-menu commands for toolbar actions. Settings stays the system Settings
/// item, and export stays in the File menu.
struct ReaderDisplayCommands: Commands {
    @FocusedValue(\.readerDisplay) private var display

    var body: some Commands {
        // Join the system View menu after the sidebar item instead of adding
        // a second menu with the same title.
        CommandGroup(after: .sidebar) {
            Toggle(L("专注阅读", "Distraction-free Reading"), isOn: Binding(
                get: { display?.isFocused ?? false },
                set: { _ in display?.onToggleFocus() }
            ))
            .keyboardShortcut("f", modifiers: [.command, .shift])
            .disabled(display?.isFocusAvailable != true)

            if let model = display?.intensiveModel {
                IntensiveReadingMenuToggle(model: model)
            } else {
                Toggle(L("精读", "Intensive Reading"), isOn: .constant(false)).disabled(true)
            }

            Divider()

            Toggle(L("显示释义", "Show Definitions"), isOn: Binding(
                get: { display?.showsMeanings ?? false },
                set: { display?.onSetShowsMeanings($0) }
            ))
            .disabled(display?.isStudyDisplayAvailable != true)

            Toggle(L("显示例句", "Show Examples"), isOn: Binding(
                get: { display?.showsExamples ?? false },
                set: { display?.onSetShowsExamples($0) }
            ))
            .disabled(display?.isStudyDisplayAvailable != true)

            Divider()
        }
    }
}

/// Observes the article model directly so the checkmark follows generation
/// completing in the background. Progress stays on the toolbar popover, so the
/// item is disabled while a generation runs.
private struct IntensiveReadingMenuToggle: View {
    @ObservedObject var model: IntensiveReadingModel

    var body: some View {
        Toggle(L("精读", "Intensive Reading"), isOn: Binding(
            get: { model.isActivated },
            set: { model.setActivated($0) }
        ))
        .disabled(model.isGenerating)
    }
}
