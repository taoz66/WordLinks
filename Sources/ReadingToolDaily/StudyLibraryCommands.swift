import AppKit
import SwiftUI

struct StudyLibraryExportCommandState {
    let isEnabled: Bool
    let exportLibrary: () -> Void
}

private struct StudyLibraryExportCommandKey: FocusedValueKey {
    typealias Value = StudyLibraryExportCommandState
}

extension FocusedValues {
    var studyLibraryExport: StudyLibraryExportCommandState? {
        get { self[StudyLibraryExportCommandKey.self] }
        set { self[StudyLibraryExportCommandKey.self] = newValue }
    }
}

/// Command+E has one fixed scope, and exists only in the active study window.
struct StudyLibraryExportCommands: Commands {
    @FocusedValue(\.studyLibraryExport) private var state

    var body: some Commands {
        CommandGroup(after: .importExport) {
            if let state {
                Button(L("导出整个词条库…", "Export Entire Entry Library…"), action: state.exportLibrary)
                    .keyboardShortcut("e", modifiers: .command)
                    .disabled(!state.isEnabled)
            }
        }
    }
}

@MainActor
final class StudyLibraryWindowContext: ObservableObject {
    weak var window: NSWindow?
}

enum LibraryWindowOwnership {
    static func isToolbarChild(_ candidate: NSWindow, of window: NSWindow) -> Bool {
        guard candidate !== window, window.childWindows?.contains(where: { $0 === candidate }) == true,
              let toolbar = window.toolbar, toolbar.isVisible else { return false }
        return (toolbar.visibleItems ?? toolbar.items).contains { $0.view?.window === candidate }
    }
}

/// Obtain this view's window; never borrow whichever unrelated window is key.
struct StudyLibraryWindowReader: NSViewRepresentable {
    let context: StudyLibraryWindowContext

    func makeNSView(context: Context) -> Reader {
        let view = Reader()
        view.owner = self.context
        self.context.window = view.window
        return view
    }

    func updateNSView(_ view: Reader, context: Context) {
        view.owner = self.context
        self.context.window = view.window
    }

    static func dismantleNSView(_ view: Reader, coordinator: ()) {
        view.owner?.window = nil
        view.owner = nil
    }

    final class Reader: NSView {
        weak var owner: StudyLibraryWindowContext?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            owner?.window = window
        }
    }
}
