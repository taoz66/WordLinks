import AppKit
import Combine
import SwiftUI

enum StudyCardEditableField: Hashable {
    case expression, meaning

    func value(in card: StudyCard) -> String {
        switch self { case .expression: return card.expression; case .meaning: return card.meaning }
    }

    func set(_ value: String, in card: inout StudyCard) {
        switch self { case .expression: card.expression = value; case .meaning: card.meaning = value }
    }

    var actionName: String { self == .expression ? L("修改词条", "Edit Entry") : L("修改释义", "Edit Definition") }
}

struct StudyCardFieldEdit {
    let profileID: UUID
    let field: StudyCardEditableField
    let before: [UUID: String]
    let after: [UUID: String]

    var reversed: Self { Self(profileID: profileID, field: field, before: after, after: before) }
}

struct StudyInlineEditTarget: Hashable {
    let profileID: UUID
    let cardIDs: [UUID]
    let field: StudyCardEditableField
}

enum StudyInlineEditError: LocalizedError {
    case recordChanged

    var errorDescription: String? {
        L("这些积累已在其他位置修改。草稿已保留，请取消后重新打开编辑。",
          "These study records changed elsewhere. Your draft is kept; cancel and reopen the edit.")
    }
}

/// One instance belongs to one library window. A session retains its original
/// profile, exact record IDs, and field even after its originating view disappears.
@MainActor
final class StudyInlineEditCoordinator: ObservableObject {
    @Published private(set) var errorMessage: String?
    @Published private(set) var revision = 0

    private final class Session {
        let owner: UUID
        let target: StudyInlineEditTarget
        let original: String
        var draft: String
        let store: ReadingLibraryStore
        weak var undoManager: UndoManager?
        weak var editor: InlineStudyTextView?
        var cancelled = false

        init(owner: UUID, target: StudyInlineEditTarget, original: String,
             store: ReadingLibraryStore, undoManager: UndoManager?, editor: InlineStudyTextView?) {
            self.owner = owner
            self.target = target
            self.original = original
            self.draft = original
            self.store = store
            self.undoManager = undoManager
            self.editor = editor
        }
    }

    private var session: Session?
    private final class FailedUndo {
        weak var manager: UndoManager?
        let wasUndo: Bool
        var needsStackRestoration = true

        init(manager: UndoManager, wasUndo: Bool) {
            self.manager = manager
            self.wasUndo = wasUndo
        }
    }
    private var failedUndo: FailedUndo?
    var hasActiveEdit: Bool { session != nil }
    var canDismissError: Bool { session == nil }
    var draft: String? { session?.draft }

    func isEditing(owner: UUID) -> Bool { session?.owner == owner && session?.cancelled == false }

    @discardableResult
    func begin(owner: UUID, target: StudyInlineEditTarget, text: String,
               store: ReadingLibraryStore, undoManager: UndoManager?, editor: InlineStudyTextView? = nil) -> Bool {
        if session?.owner == owner { return true }
        guard finishEditing() else { return false }
        guard store.activeProfileID == target.profileID,
              target.cardIDs.allSatisfy({ store.card(id: $0).map { target.field.value(in: $0) == text } == true }) else {
            errorMessage = StudyInlineEditError.recordChanged.localizedDescription
            return false
        }
        session = Session(owner: owner, target: target, original: text, store: store,
                          undoManager: undoManager, editor: editor)
        errorMessage = nil
        revision += 1
        return true
    }

    func updateDraft(_ text: String, owner: UUID) {
        guard let session, session.owner == owner, !session.cancelled else { return }
        session.draft = text
        revision += 1
    }

    /// Synchronous and shared by focus loss and export. Only saved data may be exported.
    @discardableResult
    func finishEditing() -> Bool {
        guard let active = session else { return failedUndo == nil }
        guard !active.cancelled else { return true }
        if let editor = active.editor {
            if editor.hasMarkedText() { editor.unmarkText() }
            active.draft = editor.string
        }
        if active.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || active.draft == active.original {
            end(active, displaying: active.original)
            return true
        }
        do {
            if let edit = try active.store.updateCardFields(profileID: active.target.profileID,
                cardIDs: active.target.cardIDs, field: active.target.field, value: active.draft,
                expectedValue: active.original) {
                registerUndo(edit.reversed, store: active.store, manager: active.undoManager)
            }
            end(active, displaying: active.draft)
            return true
        } catch {
            errorMessage = L("未能保存修改：", "Could not save the edit: ") + error.localizedDescription
            revision += 1
            return false
        }
    }

    func cancelEditing() {
        guard let active = session else { return }
        // Mark cancellation before changing focus: resignFirstResponder may synchronously call back.
        active.cancelled = true
        end(active, displaying: active.original)
    }

    func resigned(owner: UUID) {
        guard session?.owner == owner, session?.cancelled == false else { return }
        _ = finishEditing()
    }

    func detached(owner: UUID) {
        guard session?.owner == owner else { return }
        _ = finishEditing()
    }

    func retry() {
        if let failure = failedUndo {
            restoreUndoStack(after: failure)
            guard !failure.needsStackRestoration, let manager = failure.manager else { return }
            if failure.wasUndo { manager.undo() } else { manager.redo() }
        } else {
            _ = finishEditing()
        }
    }

    func dismissError() {
        guard canDismissError else { return }
        if let failure = failedUndo {
            // Dismissing an undo error must not permanently block the window.
            // Restore the original system action before releasing the retry UI;
            // the saved records and the rest of the undo history stay untouched.
            restoreUndoStack(after: failure)
            guard !failure.needsStackRestoration || failure.manager == nil else { return }
            failedUndo = nil
        }
        errorMessage = nil
    }

    private func end(_ active: Session, displaying text: String) {
        guard session === active else { return }
        let editor = active.editor
        session = nil
        errorMessage = nil
        editor?.endEditing(displaying: text)
        revision += 1
    }

    private func registerUndo(_ edit: StudyCardFieldEdit, store: ReadingLibraryStore, manager: UndoManager?) {
        guard let manager else { return }
        manager.registerUndo(withTarget: self) { [weak manager] target in
            guard let manager else { return }
            target.performUndo(edit, store: store, manager: manager)
        }
        manager.setActionName(edit.field.actionName)
    }

    private func performUndo(_ edit: StudyCardFieldEdit, store: ReadingLibraryStore, manager: UndoManager) {
        do {
            try store.applyCardFieldEdit(edit)
            failedUndo = nil
            errorMessage = nil
            registerUndo(edit.reversed, store: store, manager: manager)
        } catch {
            errorMessage = L("未能保存撤销或重做：", "Could not save undo or redo: ") + error.localizedDescription
            let failure = FailedUndo(manager: manager, wasUndo: manager.isUndoing)
            failedUndo = failure
            // UndoManager cannot throw from an action. Register a bookkeeping-only
            // inverse, then execute it after the failed action leaves the manager.
            // This restores the original stack position without changing data or
            // discarding older redo history. A retry then runs a real system undo
            // or redo, so its successful inverse lands on the correct stack.
            manager.registerUndo(withTarget: self) { [weak manager] target in
                guard let manager else { return }
                target.registerUndo(edit, store: store, manager: manager)
            }
            manager.setActionName(edit.field.actionName)
            Task { @MainActor [weak self] in self?.restoreUndoStack(after: failure) }
        }
    }

    private func restoreUndoStack(after failure: FailedUndo) {
        guard failedUndo === failure, failure.needsStackRestoration,
              let manager = failure.manager, !manager.isUndoing, !manager.isRedoing else { return }
        failure.needsStackRestoration = false
        if failure.wasUndo { manager.redo() } else { manager.undo() }
    }
}

/// Read mode consumes clicks only over actual text. It has no edit keyboard or
/// accessibility action. Once editing, NSTextView owns selection, IME and undo.
struct StudyInlineEditableText: View {
    let text: String
    let target: StudyInlineEditTarget
    let store: ReadingLibraryStore
    @ObservedObject var coordinator: StudyInlineEditCoordinator
    let font: NSFont
    var lineSpacing: CGFloat = 0
    let placeholder: String
    let label: String
    var undoManager: UndoManager?

    var body: some View {
        InlineStudyText(text: text, target: target, store: store, coordinator: coordinator,
                        font: font, lineSpacing: lineSpacing, placeholder: placeholder,
                        label: label, undoManager: undoManager)
            .id(target)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct InlineStudyText: NSViewRepresentable {
    let text: String
    let target: StudyInlineEditTarget
    let store: ReadingLibraryStore
    @ObservedObject var coordinator: StudyInlineEditCoordinator
    let font: NSFont
    let lineSpacing: CGFloat
    let placeholder: String
    let label: String
    let undoManager: UndoManager?
    @State private var owner = UUID()

    func makeNSView(context: Context) -> InlineStudyTextView {
        let view = InlineStudyTextView(frame: .zero)
        view.isRichText = false
        view.importsGraphics = false
        view.drawsBackground = false
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = true
        view.textContainer?.heightTracksTextView = false
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.allowsUndo = true
        view.isEditable = false
        view.isSelectable = false
        view.focusRingType = .default
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: InlineStudyTextView, context: Context) {
        view.owner = owner
        view.editCoordinator = coordinator
        view.font = font
        view.textColor = .textColor
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineSpacing = lineSpacing
        view.defaultParagraphStyle = paragraphStyle
        view.typingAttributes = [.font: font, .foregroundColor: NSColor.textColor, .paragraphStyle: paragraphStyle]
        view.placeholder = placeholder
        view.setAccessibilityLabel(label)
        if !coordinator.isEditing(owner: owner), !view.hasMarkedText(), view.string != text {
            view.string = text
        }
        view.onBegin = { [weak view] in
            guard let view else { return }
            if coordinator.begin(owner: owner, target: target, text: text, store: store,
                                 undoManager: undoManager ?? view.window?.undoManager, editor: view) {
                view.startEditing()
            }
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: InlineStudyTextView, context: Context) -> NSSize? {
        let width = max(1, proposal.width ?? 320)
        nsView.textContainer?.containerSize = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)
        if let container = nsView.textContainer, let manager = nsView.layoutManager {
            manager.ensureLayout(for: container)
            return NSSize(width: width, height: ceil(max(font.ascender - font.descender + font.leading,
                                                        manager.usedRect(for: container).height)))
        }
        return NSSize(width: width, height: ceil(font.ascender - font.descender + font.leading))
    }

    static func dismantleNSView(_ nsView: InlineStudyTextView, coordinator: ()) {
        let owner = nsView.owner
        let editCoordinator = nsView.editCoordinator
        // A removed view must not cause an old session to become a new object's edit.
        Task { @MainActor in editCoordinator?.detached(owner: owner) }
    }
}

@MainActor
final class InlineStudyTextView: NSTextView {
    var owner = UUID()
    weak var editCoordinator: StudyInlineEditCoordinator?
    var onBegin: (() -> Void)?
    var placeholder = ""
    private let textUndoManager = UndoManager()
    private var isResigning = false

    override var undoManager: UndoManager? { isEditable ? textUndoManager : super.undoManager }
    override var acceptsFirstResponder: Bool { isEditable }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func startEditing() {
        guard !isEditable else { return }
        textUndoManager.removeAllActions()
        isEditable = true
        isSelectable = true
        window?.makeFirstResponder(self)
        selectAll(nil)
    }

    func endEditing(displaying text: String) {
        string = text
        isEditable = false
        isSelectable = false
        if !isResigning, window?.firstResponder === self { window?.makeFirstResponder(nil) }
        textUndoManager.removeAllActions()
        needsDisplay = true
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        if isEditable { return hit }
        return containsDisplayedText(convert(point, from: superview)) ? hit : nil
    }

    func containsDisplayedText(_ point: NSPoint) -> Bool {
        guard let manager = layoutManager, let container = textContainer, !string.isEmpty else { return false }
        manager.ensureLayout(for: container)
        let origin = textContainerOrigin
        let local = NSPoint(x: point.x - origin.x, y: point.y - origin.y)
        var found = false
        manager.enumerateLineFragments(forGlyphRange: manager.glyphRange(for: container)) { _, used, _, _, stop in
            if used.contains(local) { found = true; stop.pointee = true }
        }
        return found
    }

    override func mouseDown(with event: NSEvent) {
        if isEditable {
            super.mouseDown(with: event)
        } else if event.clickCount == 2 {
            onBegin?()
        }
        // The first click deliberately does not reach an enclosing card's navigation gesture.
    }

    override func mouseUp(with event: NSEvent) {
        if isEditable { super.mouseUp(with: event) }
    }

    override func didChangeText() {
        super.didChangeText()
        editCoordinator?.updateDraft(string, owner: owner)
        invalidateIntrinsicContentSize()
        needsDisplay = true
    }

    override func resignFirstResponder() -> Bool {
        let accepted = super.resignFirstResponder()
        if accepted {
            isResigning = true
            editCoordinator?.resigned(owner: owner)
            isResigning = false
        }
        return accepted
    }

    override func cancelOperation(_ sender: Any?) {
        guard isEditable else { return }
        editCoordinator?.cancelEditing()
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if isEditable, string.isEmpty, !hasMarkedText() {
            (placeholder as NSString).draw(at: textContainerOrigin,
                withAttributes: [.font: font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize),
                                 .foregroundColor: NSColor.placeholderTextColor])
        }
    }
}
