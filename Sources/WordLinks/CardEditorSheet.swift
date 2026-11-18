import AppKit
import Combine
import SwiftUI

/// The reader retains this session when its transient popover is dismissed.
@MainActor
final class CardEditorSession: ObservableObject {
    let article: LibraryArticle
    let selectedRange: NSRange?
    let existingCard: StudyCard?
    let draft: CardEditorDraft

    @Published private(set) var prefillEnabled: Bool
    @Published var errorMessage: String?
    private var didAppear = false

    init(article: LibraryArticle, selectedRange: NSRange?, existingCard: StudyCard?,
         prefillEnabled: Bool) {
        self.article = article
        self.selectedRange = selectedRange
        self.existingCard = existingCard
        self.prefillEnabled = prefillEnabled
        let originalSelection: String
        let source = article.text as NSString
        if let range = selectedRange,
           range.location != NSNotFound, range.location >= 0,
           range.length > 0, range.location <= source.length,
           range.length <= source.length - range.location {
            originalSelection = source.substring(with: range)
        } else {
            originalSelection = existingCard?.selectedText ?? ""
        }
        draft = CardEditorDraft(expression: existingCard?.expression
                                    ?? MorphologyLookup().initialExpression(for: originalSelection),
                                meaning: existingCard?.meaning ?? "")
    }

    func appear(settings: AISettingsStore) {
        synchronizePrefillPreference(settings: settings)
        guard !didAppear else { return }
        didAppear = true
        if prefillEnabled, existingCard == nil {
            draft.start(article: article, range: selectedRange, settings: settings)
        }
    }

    func setPrefillEnabled(_ enabled: Bool, settings: AISettingsStore) {
        settings.setAIPrefillEnabled(enabled)
        guard prefillEnabled != enabled else { return }
        prefillEnabled = enabled
        if enabled {
            draft.start(article: article, range: selectedRange, settings: settings)
        } else {
            draft.disablePrefill()
        }
    }

    func synchronizePrefillPreference(settings: AISettingsStore) {
        let enabled = settings.aiPrefillEnabled
        guard prefillEnabled != enabled else { return }
        prefillEnabled = enabled
        if !enabled {
            draft.disablePrefill()
        } else if didAppear, existingCard == nil {
            draft.start(article: article, range: selectedRange, settings: settings)
        }
    }

    func cancelPendingRequest() {
        draft.cancelPendingRequest()
    }

    func resumePrefillAfterSignIn(settings: AISettingsStore) {
        guard prefillEnabled, settings.isAIConfigured else { return }
        if settings.selectedService == .chatGPT {
            guard !settings.chatGPT.isSigningIn, !settings.chatGPT.isConfigurationSigningIn,
                  !settings.chatGPT.isSigningOut, settings.chatGPT.issue == nil else { return }
        }
        switch draft.phase {
        case .needsConfiguration:
            break
        case .failed:
            // Switching during a request requires an explicit retry. A saved fix
            // to an earlier failure can resume, but never repeats a quota/network failure.
            guard draft.lastIssue != .configurationChanged else { return }
            if draft.lastAttemptRevision != settings.configurationRevision { break }
            switch draft.lastIssue {
            case .chatGPT(.notSignedIn)?, .chatGPT(.loginExpired)?, .chatGPT(.missingPlanPermission)?,
                 .chatGPT(.authorizationDenied)?, .chatGPT(.loginTimedOut)?,
                 .chatGPT(.invalidAuthorization)?, .chatGPT(.authorizationCodeRejected)?,
                 .custom(.keychain)?, .custom(.profileStorage)?:
                break
            default:
                return
            }
        default:
            // Editing the meaning makes the draft idle and must never trigger prefill.
            return
        }
        draft.start(article: article, range: selectedRange, settings: settings)
    }
}

@MainActor
struct CardEditorPopover: View {
    @EnvironmentObject private var store: ReadingLibraryStore
    @EnvironmentObject private var aiSettings: AISettingsStore
    @ObservedObject private var session: CardEditorSession
    @ObservedObject private var draft: CardEditorDraft
    private let close: () -> Void
    private let openSettings: () -> Void

    init(session: CardEditorSession, close: @escaping () -> Void, openSettings: @escaping () -> Void) {
        _session = ObservedObject(wrappedValue: session)
        _draft = ObservedObject(wrappedValue: session.draft)
        self.close = close
        self.openSettings = openSettings
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(session.existingCard == nil ? L("新增积累", "Add word") : L("编辑积累", "Edit word"))
                .font(.headline)

            VStack(alignment: .leading, spacing: 4) {
                Text(L("词或表达", "Word or expression"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                NativeCardTextEditor(text: Binding(
                    get: { draft.expression }, set: { draft.updateExpression($0) }
                ), placeholder: "", label: L("词或表达", "Word or expression"),
                                     minimumHeight: 30, maximumHeight: 78)
            }

            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(L("释义", "Meaning"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Toggle(L("AI预填", "AI prefill"), isOn: Binding(
                        get: { session.prefillEnabled },
                        set: { session.setPrefillEnabled($0, settings: aiSettings) }
                    ))
                    .toggleStyle(.checkbox)
                    .font(.caption)
                }
                meaningEditor
                if let suggestion = draft.suggestion, !draft.manualMeaning.isEmpty {
                    NativeCardTextEditor(text: .constant(suggestion), placeholder: "",
                                         label: L("AI建议", "AI suggestion"),
                                         minimumHeight: 30, maximumHeight: 80, isEditable: false)
                    Button(L("使用建议", "Use suggestion")) { draft.useSuggestion() }
                        .controlSize(.small)
                }
                if session.prefillEnabled { prefillStatus }
            }

            if let errorMessage = session.errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.red)
                    .font(.caption)
                    .lineLimit(3)
                    .help(errorMessage)
            }

            HStack {
                if session.existingCard != nil {
                    Button(L("删除划记", "Delete highlight"), role: .destructive, action: delete)
                }
                Spacer(minLength: 8)
                Button(L("取消", "Cancel"), role: .cancel, action: finish)
                    .keyboardShortcut(.cancelAction)
                Button(L("保存", "Save"), action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(draft.expression.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                              draft.meaningToSave.isEmpty)
            }
        }
        .padding(14)
        .frame(width: 380)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear {
            session.appear(settings: aiSettings)
            session.resumePrefillAfterSignIn(settings: aiSettings)
        }
        .onChange(of: aiSettings.aiPrefillEnabled) { _, _ in
            session.synchronizePrefillPreference(settings: aiSettings)
        }
        .onChange(of: aiSettings.configurationRevision) { _, _ in
            session.resumePrefillAfterSignIn(settings: aiSettings)
        }
        .background {
            CardChatGPTAvailabilityObserver(connection: aiSettings.chatGPT) {
                session.resumePrefillAfterSignIn(settings: aiSettings)
            }
        }
    }

    private var meaningEditor: some View {
        NativeCardTextEditor(text: Binding(
            get: { draft.manualMeaning }, set: { draft.updateManualMeaning($0) }
        ), placeholder: draft.suggestion ?? L("填写释义", "Enter a meaning"),
                             label: L("释义", "Meaning"), minimumHeight: 46, maximumHeight: 142,
                             isInitialFirstResponder: true)
    }

    @ViewBuilder private var prefillStatus: some View {
        switch draft.phase {
        case .loading:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(L("正在获取释义…", "Getting a meaning…"))
                    .foregroundStyle(.secondary)
            }
            .font(.caption)
        case .needsConfiguration:
            HStack(spacing: 6) {
                Text(L("配置 AI 后可自动填写。", "Configure AI to suggest a meaning."))
                    .foregroundStyle(.secondary)
                Button(L("AI 设置…", "AI Settings…"), action: openSettings)
                .buttonStyle(.link)
            }
            .font(.caption)
        case .failed(let message):
            VStack(alignment: .leading, spacing: 6) {
                Text(message)
                    .foregroundStyle(.secondary)
                    .font(.caption)
                    .lineLimit(3)
                    .help(message)
                if let issue = draft.lastIssue {
                    AIUsageRecoveryActions(issue: issue, retry: {
                        aiSettings.resetUsageBlock()
                        draft.start(article: session.article, range: session.selectedRange, settings: aiSettings)
                    }, openSettings: openSettings)
                }
            }
        case .idle, .ready:
            EmptyView()
        }
    }

    private func finish() {
        session.cancelPendingRequest()
        close()
    }

    private func save() {
        guard let selectedRange = session.selectedRange else {
            session.errorMessage = L("文章中的原始位置无效，无法保存。", "The original selection is invalid and cannot be saved.")
            return
        }
        do {
            try store.saveCard(id: session.existingCard?.id, articleID: session.article.id, range: selectedRange,
                               expression: draft.expression, meaning: draft.meaningToSave)
            finish()
        } catch { session.errorMessage = error.localizedDescription }
    }

    private func delete() {
        guard let existingCard = session.existingCard else { return }
        do { try store.deleteCard(existingCard.id); finish() }
        catch { session.errorMessage = error.localizedDescription }
    }
}

private struct CardChatGPTAvailabilityObserver: View {
    @ObservedObject var connection: ChatGPTAccountStore
    let resume: () -> Void

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onChange(of: connection.activeClientID) { _, _ in resume() }
            .onChange(of: connection.needsAuthorization) { _, _ in resume() }
            .onChange(of: connection.needsReauthentication) { _, _ in resume() }
            .onChange(of: connection.isSigningIn) { _, _ in resume() }
            .onChange(of: connection.isConfigurationSigningIn) { _, _ in resume() }
            .onChange(of: connection.issue) { _, _ in resume() }
    }
}

/// A plain AppKit editor keeps insertion, wrapping, and placeholder geometry in
/// one coordinate system. Its document can scroll while the form stays compact.
@MainActor
struct NativeCardTextEditor: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let label: String
    let minimumHeight: CGFloat
    let maximumHeight: CGFloat
    var isEditable = true
    var isInitialFirstResponder = false
    var fillsAvailableHeight = false
    var textInset = EditorSurface.textInset
    var accessibilityIdentifier: String?

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> CardInputScrollView {
        let scrollView = CardInputScrollView()
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .textBackgroundColor
        scrollView.wantsLayer = true
        scrollView.layer?.cornerRadius = EditorSurface.cornerRadius
        scrollView.layer?.cornerCurve = .continuous
        scrollView.layer?.masksToBounds = true

        // The frame-only initializer creates the editor's backing text system.
        let textView = CardInputTextView(frame: .zero)
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainerInset = textInset
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.heightTracksTextView = false
        textView.font = .systemFont(ofSize: NSFont.systemFontSize)
        textView.defaultParagraphStyle = CardInputTextView.paragraphStyle
        textView.typingAttributes = textView.inputAttributes
        textView.textColor = .textColor
        textView.backgroundColor = .textBackgroundColor
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.delegate = context.coordinator
        scrollView.documentView = textView
        updateNSView(scrollView, context: context)
        return scrollView
    }

    func updateNSView(_ scrollView: CardInputScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scrollView.documentView as? CardInputTextView else { return }
        context.coordinator.isUpdating = true
        if textView.string != text, !textView.hasMarkedText() {
            let selection = textView.selectedRange()
            textView.string = text
            let length = (text as NSString).length
            let location = min(selection.location, length)
            textView.setSelectedRange(NSRange(location: location, length: min(selection.length, length - location)))
        }
        textView.placeholder = placeholder
        textView.isEditable = isEditable
        textView.isInitialFirstResponder = isInitialFirstResponder
        textView.isSelectable = true
        textView.typingAttributes = textView.inputAttributes
        textView.setAccessibilityLabel(label)
        textView.setAccessibilityIdentifier(accessibilityIdentifier)
        textView.needsDisplay = true
        scrollView.refreshDocumentGeometry()
        scrollView.refreshEditorChrome()
        context.coordinator.isUpdating = false
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: CardInputScrollView, context: Context) -> NSSize? {
        guard let textView = nsView.documentView as? CardInputTextView else { return nil }
        let proposedWidth = proposal.width ?? 352
        let width = proposedWidth.isFinite ? max(1, proposedWidth) : 352
        if fillsAvailableHeight {
            let height = proposal.height.flatMap { $0.isFinite ? $0 : nil } ?? minimumHeight
            return NSSize(width: width, height: max(minimumHeight, height))
        }
        let height = min(maximumHeight, max(minimumHeight, textView.contentHeight(for: width)))
        return NSSize(width: width, height: ceil(height))
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: NativeCardTextEditor
        var isUpdating = false

        init(_ parent: NativeCardTextEditor) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard !isUpdating, let textView = notification.object as? CardInputTextView else { return }
            parent.text = textView.string
            textView.needsDisplay = true
            (textView.enclosingScrollView as? CardInputScrollView)?.refreshDocumentGeometry()
        }
    }
}

@MainActor
final class CardInputScrollView: NSScrollView {
    private var editorHasFocus = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self)
        if let window {
            for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
                NotificationCenter.default.addObserver(self, selector: #selector(windowFocusChanged),
                                                       name: name, object: window)
            }
        }
        refreshEditorChrome()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshEditorChrome()
    }

    @objc private func windowFocusChanged(_ notification: Notification) { refreshEditorChrome() }

    func setEditorFocused(_ focused: Bool) {
        editorHasFocus = focused
        refreshEditorChrome()
    }

    func refreshEditorChrome() {
        guard let layer else { return }
        let editable = (documentView as? NSTextView)?.isEditable == true
        let focused = editorHasFocus && editable && window?.isKeyWindow == true
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer.cornerCurve = .continuous
            layer.borderColor = (focused ? NSColor.keyboardFocusIndicatorColor : NSColor.separatorColor).cgColor
            layer.borderWidth = focused ? 1.5 : 1
        }
    }

    override func layout() {
        super.layout()
        refreshDocumentGeometry()
    }

    func refreshDocumentGeometry() {
        guard let textView = documentView as? CardInputTextView else { return }
        let width = max(1, contentSize.width)
        let height = max(contentSize.height, textView.contentHeight(for: width))
        textView.minSize = NSSize(width: 0, height: contentSize.height)
        textView.textContainer?.containerSize = NSSize(
            width: max(1, width - 2 * textView.textContainerInset.width),
            height: .greatestFiniteMagnitude
        )
        let size = NSSize(width: width, height: ceil(height))
        if textView.frame.size != size { textView.setFrameSize(size) }
    }
}

@MainActor
final class CardInputTextView: NSTextView {
    var placeholder = ""
    var isInitialFirstResponder = false

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { (enclosingScrollView as? CardInputScrollView)?.setEditorFocused(true) }
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let accepted = super.resignFirstResponder()
        if accepted { (enclosingScrollView as? CardInputScrollView)?.setEditorFocused(false) }
        return accepted
    }

    static var paragraphStyle: NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byWordWrapping
        return style
    }

    var inputAttributes: [NSAttributedString.Key: Any] {
        [.font: font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize),
         .foregroundColor: NSColor.textColor,
         .paragraphStyle: Self.paragraphStyle]
    }

    func contentHeight(for width: CGFloat) -> CGFloat {
        let layout = makeLayout(for: string.isEmpty ? placeholder : string, width: width)
        let used = layout.manager.usedRect(for: layout.container)
        let extra = layout.manager.extraLineFragmentUsedRect
        let lineHeight = layout.manager.defaultLineHeight(for: font ?? .systemFont(ofSize: NSFont.systemFontSize))
        return ceil(max(lineHeight, max(used.maxY, extra.maxY)) + 2 * textContainerInset.height)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !placeholder.isEmpty else { return }
        let layout = makeLayout(for: placeholder, width: bounds.width, isPlaceholder: true)
        let glyphs = layout.manager.glyphRange(for: layout.container)
        layout.manager.drawGlyphs(forGlyphRange: glyphs, at: textContainerOrigin)
    }

    private func makeLayout(for text: String, width: CGFloat, isPlaceholder: Bool = false) -> TextLayout {
        var attributes = inputAttributes
        if isPlaceholder { attributes[.foregroundColor] = NSColor.placeholderTextColor }
        return TextLayout(text: text, attributes: attributes,
                          width: max(1, width - 2 * textContainerInset.width))
    }

    private struct TextLayout {
        // Keep the storage alive for the entire layout and drawing operation.
        let storage: NSTextStorage
        let manager: NSLayoutManager
        let container: NSTextContainer

        init(text: String, attributes: [NSAttributedString.Key: Any], width: CGFloat) {
            storage = NSTextStorage(string: text, attributes: attributes)
            manager = NSLayoutManager()
            container = NSTextContainer(size: NSSize(width: width, height: .greatestFiniteMagnitude))
            container.lineFragmentPadding = 0
            manager.addTextContainer(container)
            storage.addLayoutManager(manager)
            manager.ensureLayout(for: container)
        }
    }
}

/// The candidate is deliberately separate from the editor's typed text. The
/// first edit discards it, so typing replaces a suggestion rather than appends.
@MainActor
final class CardEditorDraft: ObservableObject {
    enum Phase {
        case idle
        case loading
        case needsConfiguration
        case failed(String)
        case ready
    }

    @Published private(set) var expression: String
    @Published private(set) var manualMeaning: String
    @Published private(set) var suggestion: String?
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var lastIssue: AIUsageIssue?
    private(set) var lastIssueAccountID: String?
    private(set) var lastAttemptRevision: UInt64?
    private var requestID: UUID?
    private var task: Task<Void, Never>?
    private var configurationObserver: AnyCancellable?

    init(expression: String, meaning: String) {
        self.expression = expression
        self.manualMeaning = meaning
    }

    var meaningToSave: String {
        let manual = manualMeaning.trimmingCharacters(in: .whitespacesAndNewlines)
        if !manual.isEmpty { return manual }
        return suggestion?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    func updateExpression(_ value: String) {
        guard expression != value else { return }
        expression = value
        disablePrefill()
    }

    func updateManualMeaning(_ value: String) {
        guard manualMeaning != value else { return }
        cancelPendingRequest()
        suggestion = nil
        phase = .idle
        lastIssue = nil
        lastIssueAccountID = nil
        lastAttemptRevision = nil
        manualMeaning = value
    }

    func useSuggestion() {
        guard let suggestion else { return }
        cancelPendingRequest()
        manualMeaning = suggestion
        self.suggestion = nil
        phase = .idle
        lastIssue = nil
        lastIssueAccountID = nil
        lastAttemptRevision = nil
    }

    func disablePrefill() {
        cancelPendingRequest()
        suggestion = nil
        phase = .idle
        lastIssue = nil
        lastIssueAccountID = nil
        lastAttemptRevision = nil
    }

    func start(article: LibraryArticle, range: NSRange?, settings: AISettingsStore) {
        disablePrefill()
        let identity = settings.activeAIIdentity
        let revision = settings.configurationRevision
        let accountID = settings.selectedService == .chatGPT ? settings.chatGPT.activeClientID : nil
        lastAttemptRevision = revision
        guard settings.isAIConfigured else {
            presentConfigurationIssue(settings)
            return
        }
        guard let range else {
            phase = .failed(L("选中的文字位置无效，请重新选择。", "The selected text is invalid. Please select it again."))
            return
        }
        let context: SelectionContext
        do {
            context = try SelectionContext.extract(from: article.text, range: range,
                                                   articleTitle: article.title)
        } catch {
            phase = .failed(error.localizedDescription)
            return
        }
        let selection = expression.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !selection.isEmpty else {
            phase = .failed(L("请先填写词或表达。", "Enter a word or expression first."))
            return
        }
        let id = UUID()
        requestID = id
        phase = .loading
        configurationObserver = settings.$configurationRevision.dropFirst().sink { [weak self, weak settings] _ in
            guard let self, let settings, self.requestID == id else { return }
            self.configurationChanged(settings: settings)
        }
        task = Task { [weak self] in
            do {
                let result = try await settings.explain(
                    selection: selection, context: context.context,
                    focusedSentence: context.focusedSentence,
                    purpose: .prefill
                )
                try Task.checkCancellation()
                guard let self, self.requestID == id else { return }
                guard settings.activeAIIdentity == identity, settings.configurationRevision == revision else {
                    self.configurationChanged(settings: settings)
                    return
                }
                self.suggestion = result
                self.phase = .ready
                self.requestID = nil
                self.task = nil
                self.configurationObserver = nil
            } catch is CancellationError {
                guard let self, self.requestID == id else { return }
                self.requestID = nil
                self.task = nil
                self.configurationObserver = nil
                if !settings.isAIConfigured {
                    self.presentConfigurationIssue(settings)
                } else if settings.activeAIIdentity != identity || settings.configurationRevision != revision {
                    self.fail(.configurationChanged, accountID: accountID)
                } else {
                    self.fail(settings.selectedService == .chatGPT ? .chatGPT(.interrupted) : .configurationChanged,
                              accountID: accountID)
                }
            } catch {
                guard let self, self.requestID == id else { return }
                guard settings.activeAIIdentity == identity, settings.configurationRevision == revision else {
                    self.configurationChanged(settings: settings)
                    return
                }
                self.fail(AIUsageIssue.from(error), accountID: accountID)
                self.requestID = nil
                self.task = nil
                self.configurationObserver = nil
            }
        }
    }

    func cancelPendingRequest() {
        requestID = nil
        task?.cancel()
        task = nil
        configurationObserver = nil
        if case .loading = phase { phase = .idle }
    }

    private func configurationChanged(settings: AISettingsStore) {
        requestID = nil
        task?.cancel()
        task = nil
        configurationObserver = nil
        if settings.isAIConfigured {
            fail(.configurationChanged)
        } else {
            presentConfigurationIssue(settings)
        }
    }

    private func presentConfigurationIssue(_ settings: AISettingsStore) {
        if let issue = settings.aiConfigurationIssue, !issue.isMissingConfiguration {
            fail(issue, accountID: settings.selectedService == .chatGPT ? settings.chatGPT.activeClientID : nil)
        } else {
            lastIssue = nil
            lastIssueAccountID = nil
            phase = .needsConfiguration
        }
    }

    private func fail(_ issue: AIUsageIssue, accountID: String? = nil) {
        lastIssueAccountID = accountID
        lastIssue = issue
        phase = .failed(issue.localizedDescription)
    }
}
