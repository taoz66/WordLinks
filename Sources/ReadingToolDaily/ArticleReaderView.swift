import AppKit
import SwiftUI
import Translation

struct ArticleReaderView: View {
    @EnvironmentObject private var store: ReadingLibraryStore
    @EnvironmentObject private var aiSettings: AISettingsStore
    @Environment(\.openSettings) private var openSettings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appearance = AppearanceSettingsStore.shared
    let article: LibraryArticle
    let initialOffset: Int
    var sourceReveal: ReaderSourceReveal? = nil
    var isDistractionFree = false
    var onExitDistractionFree: (() -> Void)? = nil
    @State private var searchText = ""
    @State private var searchRequest = 0
    @State private var searchDirection = 1
    @State private var isShowingFind = false
    @State private var isShowingSystemTranslation = false
    @State private var systemTranslationText = ""
    @State private var systemTranslationAnchor = UnitPoint(x: 0.5, y: 0.5)
    @State private var readerFocusRequest = 0
    @State private var readingProgress = 0.0
    @ObservedObject private var intensiveModel: IntensiveReadingModel
    @State private var isFindFocused = false

    init(article: LibraryArticle, store: ReadingLibraryStore, aiSettings: AISettingsStore,
         initialOffset: Int, sourceReveal: ReaderSourceReveal? = nil,
         isDistractionFree: Bool = false, onExitDistractionFree: (() -> Void)? = nil,
         intensiveModel: IntensiveReadingModel) {
        self.article = article
        self.initialOffset = initialOffset
        self.sourceReveal = sourceReveal
        self.isDistractionFree = isDistractionFree
        self.onExitDistractionFree = onExitDistractionFree
        _intensiveModel = ObservedObject(wrappedValue: intensiveModel)
    }

    private var cards: [StudyCard] {
        store.archive.cards.filter { $0.articleID == article.id && $0.isDetached != true }
    }

    private var supportsSystemTranslation: Bool {
        if #available(macOS 14.4, *) { return true }
        return false
    }

    var body: some View {
        let profileID = store.archive.id
        VStack(spacing: 0) {
            if !isDistractionFree {
                if let syncError = store.fileSyncErrors[article.id] {
                    Text(syncError)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .lineLimit(2)
                        .help(syncError)
                        .padding(.horizontal, appearance.readingTypography.sideInset)
                        .padding(.vertical, 8)
                }
            }
            if intensiveModel.isActivated {
                IntensiveReadingView(
                    article: article,
                    model: intensiveModel,
                    cards: cards,
                    store: store,
                    aiSettings: aiSettings,
                    initialOffset: initialOffset,
                    sourceReveal: sourceReveal,
                    searchText: searchText,
                    searchRequest: searchRequest,
                    searchDirection: searchDirection,
                    isShowingFind: isShowingFind,
                    readerFocusRequest: readerFocusRequest,
                    readingStyle: appearance.readingStyle,
                    typography: appearance.readingTypography,
                    isDistractionFree: isDistractionFree,
                    onShowFind: showFind,
                    onCloseFind: handleEscape,
                    onExitDistractionFree: isDistractionFree ? onExitDistractionFree : nil,
                    onFind: find,
                    onReadOffset: { offset in
                        guard store.archive.id == profileID else { return }
                        do { try store.setReadOffset(offset, articleID: article.id) }
                        catch { showReadOffsetError(error) }
                    },
                    onReadingProgress: { readingProgress = $0 },
                    supportsSystemTranslation: supportsSystemTranslation,
                    onOpenAISettings: {
                        SettingsNavigation.shared.selection = .ai
                        openSettings()
                    },
                    onTranslate: { selection, anchor in
                        systemTranslationText = selection
                        systemTranslationAnchor = anchor
                        isShowingSystemTranslation = true
                    }
                )
                .transition(.opacity)
                .modifier(SystemTranslationPresentation(
                    isPresented: $isShowingSystemTranslation,
                    text: systemTranslationText,
                    anchor: systemTranslationAnchor
                ))
            } else {
                ArticleTextView(
                    article: article,
                    cards: cards,
                    store: store,
                    initialOffset: initialOffset,
                    sourceReveal: sourceReveal,
                    searchText: searchText,
                    searchRequest: searchRequest,
                    searchDirection: searchDirection,
                    isShowingFind: isShowingFind,
                    readerFocusRequest: readerFocusRequest,
                    readingStyle: appearance.readingStyle,
                    typography: appearance.readingTypography,
                    isDistractionFree: isDistractionFree,
                    aiSettings: aiSettings,
                    supportsSystemTranslation: supportsSystemTranslation,
                    onShowFind: showFind,
                    onCloseFind: handleEscape,
                    onExitDistractionFree: isDistractionFree ? onExitDistractionFree : nil,
                    onFind: find,
                    onOpenAISettings: {
                        SettingsNavigation.shared.selection = .ai
                        openSettings()
                    },
                    onReadOffset: { offset in
                        guard store.archive.id == profileID else { return }
                        do { try store.setReadOffset(offset, articleID: article.id) }
                        catch { showReadOffsetError(error) }
                    },
                    onReadingProgress: { readingProgress = $0 },
                    onTranslate: { selection, anchor in
                        systemTranslationText = selection
                        systemTranslationAnchor = anchor
                        isShowingSystemTranslation = true
                    }
                )
                .id("\(profileID)-\(article.id)")
                .transition(.opacity)
                .modifier(SystemTranslationPresentation(
                    isPresented: $isShowingSystemTranslation,
                    text: systemTranslationText,
                    anchor: systemTranslationAnchor
                ))
            }
            if !isDistractionFree, appearance.readingStyle == .focus {
                GeometryReader { geometry in
                    Rectangle()
                        .fill(Color(nsColor: appearance.readingStyle.readerAccent))
                        .frame(width: geometry.size.width * readingProgress)
                }
                .frame(height: 2)
                .accessibilityLabel(L("阅读进度", "Reading progress"))
                .accessibilityValue("\(Int(readingProgress * 100))%")
            }
        }
        .background(Color(nsColor: appearance.readingStyle.readerBackground))
        .nativeLibraryControlBar(isPresented: isShowingFind) { findBar }
        .navigationTitle("")
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: intensiveModel.isActivated)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: isShowingFind)
        .onChange(of: article.id) { _, _ in
            closeFind()
            isShowingSystemTranslation = false
        }
        .onChange(of: store.archive.id) { _, _ in
            closeFind()
            isShowingSystemTranslation = false
        }
        .onChange(of: isDistractionFree) { _, _ in
            closeFind()
            isShowingSystemTranslation = false
        }
        .onAppear {
            if isDistractionFree { readerFocusRequest += 1 }
        }
    }

    private var findBar: some View {
        HStack(spacing: 8) {
            NativeLibrarySearchField(prompt: L("查找文章", "Find in article"), text: $searchText,
                                     isFocused: $isFindFocused,
                                     onSubmit: { find(direction: 1) }, onCancel: closeFind)
                .frame(minWidth: 120, maxWidth: 340)
            ControlGroup {
                Button { find(direction: -1) } label: { Image(systemName: "chevron.up") }
                    .help(L("上一个匹配项", "Previous match"))
                    .accessibilityLabel(L("上一个匹配项", "Previous match"))
                Button { find(direction: 1) } label: { Image(systemName: "chevron.down") }
                    .help(L("下一个匹配项", "Next match"))
                    .accessibilityLabel(L("下一个匹配项", "Next match"))
            }
            .disabled(searchText.isEmpty)
            Spacer(minLength: 0)
            Button(action: closeFind) { Image(systemName: "xmark") }
                .buttonStyle(.borderless)
                .help(L("关闭查找", "Close find"))
                .accessibilityLabel(L("关闭查找", "Close find"))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .onExitCommand(perform: closeFind)
    }

    private func handleEscape() -> Bool {
        if isShowingFind {
            closeFind()
            return true
        }
        if isDistractionFree, let onExitDistractionFree {
            onExitDistractionFree()
            return true
        }
        return false
    }

    private func find(direction: Int) {
        guard !searchText.isEmpty else { return }
        searchDirection = direction
        searchRequest += 1
    }

    private func showFind() {
        isShowingFind = true
        DispatchQueue.main.async {
            if isShowingFind { isFindFocused = true }
        }
    }

    private func closeFind() {
        isFindFocused = false
        isShowingFind = false
        searchText = ""
        readerFocusRequest += 1
    }

    private func showReadOffsetError(_ error: Error) {
        let alert = NSAlert(error: error)
        alert.buttons.first?.title = L("好", "OK")
        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }

}

private struct ArticleTextView: NSViewRepresentable {
    let article: LibraryArticle
    let cards: [StudyCard]
    let store: ReadingLibraryStore
    let initialOffset: Int
    let sourceReveal: ReaderSourceReveal?
    let searchText: String
    let searchRequest: Int
    let searchDirection: Int
    let isShowingFind: Bool
    let readerFocusRequest: Int
    let readingStyle: ReadingViewStyle
    let typography: ReadingTypography
    let isDistractionFree: Bool
    let aiSettings: AISettingsStore
    let supportsSystemTranslation: Bool
    let onShowFind: () -> Void
    let onCloseFind: () -> Bool
    let onExitDistractionFree: (() -> Void)?
    let onFind: (Int) -> Void
    let onOpenAISettings: () -> Void
    let onReadOffset: (Int) -> Void
    let onReadingProgress: (Double) -> Void
    let onTranslate: (String, UnitPoint) -> Void

    private var text: String { article.text }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = !isDistractionFree
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = readingStyle.readerBackground
        scrollView.contentView.postsBoundsChangedNotifications = true
        scrollView.contentView.postsFrameChangedNotifications = true

        let textView = CardAwareTextView(frame: .zero)
        textView.layoutManager?.allowsNonContiguousLayout = true
        textView.identifier = ReaderTextViewIdentity.article
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.allowsUndo = false
        textView.drawsBackground = false
        textView.usesFindPanel = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.readingStyle = readingStyle
        textView.typography = typography
        textView.isDistractionFree = isDistractionFree
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.containerSize = NSSize(width: 820, height: CGFloat.greatestFiniteMagnitude)
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.delegate = context.coordinator
        textView.onCardClick = { [weak coordinator = context.coordinator] card in
            coordinator?.editCard(card)
        }
        textView.onAskAI = { [weak coordinator = context.coordinator] range in
            coordinator?.askAI(for: range)
        }
        textView.onCreateCard = { [weak coordinator = context.coordinator] range in
            coordinator?.presentCardEditor(for: range)
        }
        textView.onTranslate = { [weak coordinator = context.coordinator] range in
            coordinator?.translate(range)
        }
        textView.supportsSystemTranslation = supportsSystemTranslation
        textView.onShowFind = onShowFind
        textView.onCloseFind = onCloseFind
        textView.onFind = onFind
        textView.onExitDistractionFree = onExitDistractionFree
        scrollView.documentView = textView
        context.coordinator.textView = textView
        context.coordinator.scrollView = scrollView
        context.coordinator.onReadOffset = onReadOffset
        context.coordinator.onReadingProgress = onReadingProgress
        context.coordinator.article = article
        context.coordinator.libraryStore = store
        context.coordinator.aiSettings = aiSettings
        context.coordinator.onOpenAISettings = onOpenAISettings
        context.coordinator.onShowFind = onShowFind
        context.coordinator.onCloseFind = onCloseFind
        context.coordinator.onFind = onFind
        context.coordinator.onTranslate = onTranslate
        context.coordinator.supportsSystemTranslation = supportsSystemTranslation
        context.coordinator.isShowingFind = isShowingFind
        context.coordinator.lastReaderFocusRequest = readerFocusRequest
        context.coordinator.installScrollObserver()
        context.coordinator.installFindKeyMonitor()
        context.coordinator.render(text: text, cards: cards, searchText: searchText, readingStyle: readingStyle,
                                   typography: typography)
        context.coordinator.restore(offset: initialOffset, in: text)
        context.coordinator.revealSource(sourceReveal)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.onReadOffset = onReadOffset
        coordinator.onReadingProgress = onReadingProgress
        coordinator.article = article
        coordinator.libraryStore = store
        coordinator.aiSettings = aiSettings
        coordinator.onOpenAISettings = onOpenAISettings
        coordinator.textView?.onShowFind = onShowFind
        coordinator.textView?.onCloseFind = onCloseFind
        coordinator.textView?.onFind = onFind
        coordinator.textView?.onTranslate = { [weak coordinator] range in
            coordinator?.translate(range)
        }
        coordinator.textView?.supportsSystemTranslation = supportsSystemTranslation
        coordinator.textView?.onExitDistractionFree = onExitDistractionFree
        coordinator.textView?.isDistractionFree = isDistractionFree
        scrollView.hasVerticalScroller = !isDistractionFree
        coordinator.onShowFind = onShowFind
        coordinator.onCloseFind = onCloseFind
        coordinator.onFind = onFind
        coordinator.onTranslate = onTranslate
        coordinator.supportsSystemTranslation = supportsSystemTranslation
        coordinator.isShowingFind = isShowingFind
        coordinator.render(text: text, cards: cards, searchText: searchText, readingStyle: readingStyle,
                           typography: typography)
        coordinator.restore(offset: initialOffset, in: text)
        coordinator.revealSource(sourceReveal)
        if coordinator.lastSearchRequest != searchRequest, !searchText.isEmpty {
            coordinator.lastSearchRequest = searchRequest
            coordinator.find(searchText, direction: searchDirection)
        }
        if coordinator.lastReaderFocusRequest != readerFocusRequest {
            coordinator.lastReaderFocusRequest = readerFocusRequest
            coordinator.textView?.focusPreservingReadingPosition()
        }
    }

    static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
        coordinator.flushReadOffset()
        coordinator.removeScrollObserver()
        coordinator.removeFindKeyMonitor()
        coordinator.closeExplanation()
        coordinator.discardEditorSessions()
        coordinator.textView?.clearSourceReveal()
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate, NSPopoverDelegate {
        weak var textView: CardAwareTextView?
        weak var scrollView: NSScrollView?
        var onReadOffset: ((Int) -> Void)?
        var onReadingProgress: ((Double) -> Void)?
        var article: LibraryArticle?
        weak var libraryStore: ReadingLibraryStore?
        var aiSettings: AISettingsStore?
        var onOpenAISettings: (() -> Void)?
        var onShowFind: (() -> Void)?
        var onCloseFind: (() -> Bool)?
        var onFind: ((Int) -> Void)?
        var onTranslate: ((String, UnitPoint) -> Void)?
        var supportsSystemTranslation = false
        var isShowingFind = false
        var lastReaderFocusRequest = 0
        private var explanationPopover: NSPopover?
        private var explanationModel: AIExplanationModel?
        private var editorPopover: NSPopover?
        private var activeEditorKey: EditorKey?
        private var editorSessions: [EditorKey: CardEditorSession] = [:]

        private struct EditorKey: Hashable {
            let location: Int
            let length: Int
            let cardID: UUID?
        }
        var lastSearchRequest = 0
        private var renderedText: String?
        private var renderedCards: [StudyCard] = []
        private var renderedSearch = ""
        private var renderedStyle: ReadingViewStyle?
        private var renderedTypography: ReadingTypography?
        private var renderedMarkdown: String?
        private var renderedBlocks: [ArticleTextBlock] = []
        private var renderedInlineStyles: [ArticleInlineStyle] = []
        private var scrollObserver: NSObjectProtocol?
        private var viewportObserver: NSObjectProtocol?
        private var saveWork: DispatchWorkItem?
        private var lastRestoredOffset: Int?
        private var lastSourceRevealID: UUID?
        private var lastReportedReadOffset: Int?
        private var lastReportedProgress: Double = -1
        private var findKeyMonitor: Any?

        /// Keep Command-F in this reader's window, including when its NSTextView
        /// or another control in that window currently owns the responder chain.
        func installFindKeyMonitor() {
            findKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                let handled = MainActor.assumeIsolated {
                    guard let self, let window = self.textView?.window,
                          event.window === window, window.isKeyWindow,
                          window.attachedSheet == nil else { return false }
                    let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                        .subtracting([.capsLock, .numericPad, .function])
                    let key = event.charactersIgnoringModifiers?.lowercased()
                    if modifiers == .command, key == "f" {
                        self.onShowFind?()
                        return true
                    }
                    if self.isShowingFind, key == "g",
                       modifiers == .command || modifiers == [.command, .shift] {
                        self.onFind?(modifiers.contains(.shift) ? -1 : 1)
                        return true
                    }
                    if event.keyCode == 53, modifiers.isEmpty,
                       self.editorPopover?.isShown != true, self.explanationPopover?.isShown != true,
                       self.onCloseFind?() == true {
                        return true
                    }
                    return false
                }
                return handled ? nil : event
            }
        }

        func removeFindKeyMonitor() {
            if let findKeyMonitor { NSEvent.removeMonitor(findKeyMonitor) }
            findKeyMonitor = nil
        }

        func editCard(_ card: StudyCard) {
            guard let article,
                  let range = scalarRange(start: card.start, end: card.end, in: article.text) else { return }
            presentCardEditor(for: range, existingCard: card)
        }

        func presentCardEditor(for range: NSRange, existingCard: StudyCard? = nil) {
            guard let textView, textView.window != nil, let article,
                  article.text == textView.string, let libraryStore, let aiSettings,
                  range.location != NSNotFound, range.location >= 0, range.length > 0,
                  range.location <= (article.text as NSString).length,
                  range.length <= (article.text as NSString).length - range.location else { return }
            closeExplanation()
            closeCardEditor()
            let key = EditorKey(location: range.location, length: range.length, cardID: existingCard?.id)
            let session = editorSessions[key] ?? CardEditorSession(
                article: article, selectedRange: range, existingCard: existingCard,
                prefillEnabled: aiSettings.aiPrefillEnabled
            )
            editorSessions[key] = session
            let popover = NSPopover()
            popover.behavior = .transient
            popover.delegate = self
            let controller = NSHostingController(rootView: CardEditorPopover(
                session: session,
                close: { [weak self] in self?.closeCardEditor(discardDraft: true) },
                openSettings: { [weak self] in
                    self?.closeCardEditor()
                    self?.onOpenAISettings?()
                }
            )
            .environmentObject(libraryStore)
            .environmentObject(aiSettings))
            controller.sizingOptions = [.preferredContentSize]
            popover.contentViewController = controller
            editorPopover = popover
            activeEditorKey = key
            textView.setSelectedRange(range)
            popover.show(relativeTo: anchor(for: range, in: textView), of: textView, preferredEdge: .maxY)
        }

        func closeCardEditor(discardDraft: Bool = false) {
            if let key = activeEditorKey {
                editorSessions[key]?.cancelPendingRequest()
                if discardDraft { editorSessions.removeValue(forKey: key) }
            }
            let popover = editorPopover
            editorPopover = nil
            activeEditorKey = nil
            popover?.delegate = nil
            popover?.close()
        }

        func discardEditorSessions() {
            closeCardEditor()
            editorSessions.values.forEach { $0.cancelPendingRequest() }
            editorSessions.removeAll()
        }

        private func anchor(for range: NSRange, in textView: NSTextView) -> NSRect {
            let visibleRect = textView.visibleRect
            let fallback = NSRect(x: visibleRect.midX, y: visibleRect.midY, width: 1, height: 1)
            guard let layout = textView.layoutManager, let container = textView.textContainer else {
                return fallback
            }
            layout.ensureLayout(for: container)
            let origin = textView.textContainerOrigin
            let selectionGlyphs = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            let visibleGlyphs = layout.glyphRange(
                forBoundingRect: visibleRect.offsetBy(dx: -origin.x, dy: -origin.y), in: container
            )
            let visibleSelection = NSIntersectionRange(selectionGlyphs, visibleGlyphs)
            guard visibleSelection.length > 0 else { return fallback }
            var lineRange = NSRange()
            _ = layout.lineFragmentUsedRect(forGlyphAt: visibleSelection.location, effectiveRange: &lineRange)
            let firstLine = NSIntersectionRange(visibleSelection, lineRange)
            let rect = layout.boundingRect(forGlyphRange: firstLine, in: container)
                .offsetBy(dx: origin.x, dy: origin.y)
                .intersection(visibleRect)
            guard !rect.isEmpty, rect.minX.isFinite, rect.minY.isFinite,
                  rect.width.isFinite, rect.height.isFinite else { return fallback }
            return NSRect(x: rect.minX, y: rect.minY, width: min(rect.width, 12), height: rect.height)
        }

        func translate(_ range: NSRange) {
            guard supportsSystemTranslation, let textView,
                  range.location != NSNotFound, range.length > 0,
                  NSMaxRange(range) <= (textView.string as NSString).length else { return }
            let selectedText = (textView.string as NSString).substring(with: range)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !selectedText.isEmpty else { return }
            closeCardEditor()
            closeExplanation()
            let selectionRect = anchor(for: range, in: textView)
            let bounds = scrollView?.bounds ?? .zero
            let point = scrollView?.convert(
                NSPoint(x: selectionRect.midX, y: selectionRect.midY), from: textView
            )
            let anchor: UnitPoint
            if let point, bounds.width > 0, bounds.height > 0 {
                anchor = UnitPoint(
                    x: min(max(point.x / bounds.width, 0), 1),
                    y: 1 - min(max(point.y / bounds.height, 0), 1)
                )
            } else {
                anchor = UnitPoint(x: 0.5, y: 0.5)
            }
            onTranslate?(selectedText, anchor)
        }

        func askAI(for range: NSRange) {
            guard let textView, let aiSettings, let article, let libraryStore else { return }
            let selection: SelectionContext
            do {
                selection = try SelectionContext.extract(from: textView.string, range: range,
                                                         articleTitle: article.title)
            } catch {
                if let window = textView.window {
                    let alert = NSAlert(error: error)
                    alert.buttons.first?.title = L("好", "OK")
                    alert.beginSheetModal(for: window)
                }
                return
            }
            closeCardEditor()
            closeExplanation()
            let model = AIExplanationModel(selection: selection, article: article,
                                           sourceRange: range, store: libraryStore)
            let popover = NSPopover()
            popover.behavior = .transient
            popover.delegate = self
            let controller = NSHostingController(rootView: AIExplanationPopover(
                model: model,
                retry: { [weak model, weak aiSettings] in
                    guard let aiSettings else { return }
                    model?.start(settings: aiSettings)
                },
                openSettings: { [weak self] in
                    self?.closeExplanation()
                    self?.onOpenAISettings?()
                }
            ))
            controller.sizingOptions = [.preferredContentSize]
            popover.contentViewController = controller
            explanationPopover = popover
            explanationModel = model
            textView.setSelectedRange(range)
            popover.show(relativeTo: anchor(for: range, in: textView), of: textView, preferredEdge: .maxY)
            model.start(settings: aiSettings)
        }

        func closeExplanation() {
            explanationModel?.cancel()
            let popover = explanationPopover
            explanationModel = nil
            explanationPopover = nil
            popover?.delegate = nil
            popover?.close()
        }

        func popoverDidShow(_ notification: Notification) {
            guard let shown = notification.object as? NSPopover, shown === editorPopover,
                  let view = shown.contentViewController?.view else { return }
            view.layoutSubtreeIfNeeded()
            guard let editor = initialCardEditor(in: view), let window = editor.window else { return }
            window.initialFirstResponder = editor
            window.makeFirstResponder(editor)
        }

        private func initialCardEditor(in view: NSView) -> CardInputTextView? {
            if let editor = view as? CardInputTextView,
               editor.isInitialFirstResponder, editor.isEditable { return editor }
            for subview in view.subviews {
                if let editor = initialCardEditor(in: subview) { return editor }
            }
            return nil
        }

        func popoverDidClose(_ notification: Notification) {
            guard let closed = notification.object as? NSPopover else { return }
            if closed === explanationPopover {
                explanationModel?.cancel()
                explanationModel = nil
                explanationPopover = nil
            } else if closed === editorPopover {
                if let key = activeEditorKey { editorSessions[key]?.cancelPendingRequest() }
                editorPopover = nil
                activeEditorKey = nil
            }
        }

        func installScrollObserver() {
            guard let clip = scrollView?.contentView else { return }
            viewportObserver = NotificationCenter.default.addObserver(
                forName: NSView.frameDidChangeNotification, object: clip, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.textView?.sourceRevealViewportDidChange() }
            }
            scrollObserver = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification,
                object: clip,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.scheduleReadOffsetSave()
                    self?.reportReadingProgress()
                }
            }
        }

        func removeScrollObserver() {
            if let scrollObserver { NotificationCenter.default.removeObserver(scrollObserver) }
            scrollObserver = nil
            if let viewportObserver { NotificationCenter.default.removeObserver(viewportObserver) }
            viewportObserver = nil
            saveWork?.cancel()
        }

        func render(text: String, cards: [StudyCard], searchText: String, readingStyle: ReadingViewStyle,
                    typography: ReadingTypography) {
            let activeCards = cards.filter { $0.isDetached != true }
            guard renderedText != text || renderedCards != activeCards || renderedSearch != searchText ||
                  renderedStyle != readingStyle || renderedTypography != typography ||
                  renderedMarkdown != article?.markdown else { return }
            guard let textView else { return }
            let changingStyle = renderedStyle != nil &&
                (renderedStyle != readingStyle || renderedTypography != typography)
            let visibleLocation = changingStyle ? textView.characterIndexForInsertion(at: NSPoint(
                x: textView.textContainerOrigin.x + 1, y: textView.visibleRect.minY + 4
            )) : nil
            if renderedText != text {
                textView.clearSourceReveal()
                closeExplanation()
                discardEditorSessions()
                textView.resetCapturedSelection()
            } else if changingStyle {
                closeExplanation()
                closeCardEditor()
            }
            let oldSelection = textView.selectedRange()
            if renderedMarkdown != article?.markdown || renderedText != text {
                renderedBlocks = article.map(ReadingLibraryStore.readingBlocks(for:)) ?? []
                renderedInlineStyles = article.map(ReadingLibraryStore.readingInlineStyles(for:)) ?? []
            }
            textView.readingStyle = readingStyle
            textView.typography = typography
            textView.updateReadingMargins()
            scrollView?.backgroundColor = readingStyle.readerBackground
            textView.backgroundColor = readingStyle.readerBackground
            textView.textColor = readingStyle.readerForeground
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineBreakMode = .byWordWrapping
            paragraph.lineSpacing = typography.lineSpacing
            let result = NSMutableAttributedString(string: text, attributes: [
                .font: readingStyle.readerFont(size: typography.fontSize),
                .foregroundColor: readingStyle.readerForeground,
                .paragraphStyle: paragraph
            ])
            styleReaderParagraphs(result, title: article?.title, blocks: renderedBlocks,
                                  readingStyle: readingStyle, typography: typography)
            styleReaderInline(result, styles: renderedInlineStyles,
                              readingStyle: readingStyle, typography: typography)
            textView.linkTextAttributes = readerLinkAttributes(readingStyle: readingStyle)
            for card in activeCards {
                guard let range = scalarRange(start: card.start, end: card.end, in: text),
                      range.location >= 0, NSMaxRange(range) <= result.length else { continue }
                result.addAttribute(.backgroundColor, value: readingStyle.readerHighlight, range: range)
                result.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: range)
                result.addAttribute(.underlineColor, value: readingStyle.readerAccent.withAlphaComponent(0.65), range: range)
            }
            if !searchText.isEmpty {
                let source = text as NSString
                var searchRange = NSRange(location: 0, length: source.length)
                while searchRange.length > 0 {
                    let match = source.range(of: searchText, options: [.caseInsensitive], range: searchRange)
                    if match.location == NSNotFound { break }
                    result.addAttribute(.backgroundColor, value: NSColor.systemGreen.withAlphaComponent(0.3), range: match)
                    let next = NSMaxRange(match)
                    searchRange = NSRange(location: next, length: source.length - next)
                }
            }
            textView.textStorage?.setAttributedString(result)
            textView.configureByline(article: article)
            textView.decorationBlocks = renderedBlocks.filter { block in
                switch block.kind {
                case .title, .heading, .license: return true
                default: return false
                }
            }
            textView.cardRanges = activeCards.compactMap { card in
                scalarRange(start: card.start, end: card.end, in: text).map { ($0, card) }
            }
            let clampedLocation = min(oldSelection.location, result.length)
            let selectionLength = renderedText == text ? min(oldSelection.length, result.length - clampedLocation) : 0
            textView.setSelectedRange(NSRange(location: clampedLocation, length: selectionLength))
            renderedText = text
            renderedCards = activeCards
            renderedSearch = searchText
            renderedStyle = readingStyle
            renderedTypography = typography
            renderedMarkdown = article?.markdown
            if let visibleLocation {
                textView.scrollRangeToVisible(NSRange(location: min(visibleLocation, result.length), length: 0))
            }
            reportReadingProgress()
        }

        func restore(offset: Int, in text: String) {
            // A saved scroll position is echoed through the observable article.
            // It is progress reporting, not a new navigation request.
            if offset == lastReportedReadOffset {
                lastRestoredOffset = offset
                return
            }
            guard lastRestoredOffset != offset, let textView else { return }
            lastRestoredOffset = offset
            let location = utf16Offset(forScalarOffset: offset, in: text)
            textView.scrollRangeToVisible(NSRange(location: min(location, (text as NSString).length), length: 0))
        }

        func revealSource(_ request: ReaderSourceReveal?) {
            guard let request, lastSourceRevealID != request.id, let article,
                  let range = request.range(in: article), let textView else { return }
            lastSourceRevealID = request.id
            textView.revealSource(range)
        }

        func find(_ query: String, direction: Int) {
            guard let textView, !query.isEmpty else { return }
            let source = textView.string as NSString
            let length = source.length
            guard length > 0 else { return }
            let selection = textView.selectedRange()
            let options: NSString.CompareOptions = [.caseInsensitive]
            let range: NSRange
            let found: NSRange
            if direction >= 0 {
                let start = min(NSMaxRange(selection), length)
                range = NSRange(location: start, length: length - start)
                found = source.range(of: query, options: options, range: range)
                let wrapped = found.location == NSNotFound ? source.range(of: query, options: options) : found
                guard wrapped.location != NSNotFound else { return }
                textView.setSelectedRange(wrapped)
                textView.scrollRangeToVisible(wrapped)
            } else {
                let end = min(selection.location, length)
                range = NSRange(location: 0, length: end)
                found = source.range(of: query, options: options.union(.backwards), range: range)
                let wrapped = found.location == NSNotFound
                    ? source.range(of: query, options: options.union(.backwards)) : found
                guard wrapped.location != NSNotFound else { return }
                textView.setSelectedRange(wrapped)
                textView.scrollRangeToVisible(wrapped)
            }
        }

        func scheduleReadOffsetSave() {
            saveWork?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.flushReadOffset() }
            saveWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: work)
        }

        func flushReadOffset() {
            saveWork?.cancel()
            guard let textView else { return }
            guard !textView.hasPendingReadingPositionRestoration else {
                scheduleReadOffsetSave()
                return
            }
            let visibleOrigin = textView.enclosingScrollView?.contentView.bounds.origin ?? .zero
            let point = NSPoint(x: textView.textContainerInset.width + 5,
                                y: visibleOrigin.y + textView.textContainerInset.height + 4)
            let utf16Location = max(0, min(textView.characterIndexForInsertion(at: point), (textView.string as NSString).length))
            let scalarOffset = ((textView.string as NSString).substring(to: utf16Location)).unicodeScalars.count
            lastReportedReadOffset = scalarOffset
            onReadOffset?(scalarOffset)
        }

        private func reportReadingProgress() {
            guard renderedStyle == .focus, textView?.isDistractionFree != true,
                  let scrollView, let textView else { return }
            let visible = scrollView.contentView.bounds
            let distance = max(0, textView.bounds.height - visible.height)
            let fraction = distance > 0 ? min(1, max(0, visible.minY / distance)) : 1
            guard abs(fraction - lastReportedProgress) > 0.002 else { return }
            lastReportedProgress = fraction
            DispatchQueue.main.async { [weak self] in self?.onReadingProgress?(fraction) }
        }
    }
}

final class CardAwareTextView: NSTextView {
    private static let maximumTextWidth: CGFloat = 820
    private let articleByline = ReaderArticleByline()

    func configureByline(article: LibraryArticle?) {
        articleByline.update(in: self, title: article?.title,
                             metadata: article?.metadata ?? ArticleMetadata(),
                             readingStyle: readingStyle, typography: typography)
    }

    var readingStyle: ReadingViewStyle = .standard {
        didSet { if oldValue != readingStyle { updateReadingMargins() } }
    }
    var typography = ReadingViewStyle.standard.defaultTypography {
        didSet { if oldValue != typography { updateReadingMargins() } }
    }
    var isDistractionFree = false {
        didSet { needsDisplay = true }
    }
    var decorationBlocks: [ArticleTextBlock] = [] {
        didSet { needsDisplay = true }
    }
    private var updatingReadingMargins = false
    private struct ReadingAnchor {
        let character: Int
        let offsetFromLineTop: CGFloat
    }
    private var pendingReadingAnchor: ReadingAnchor?
    private var resizeRestoration: DispatchWorkItem?
    private var resizeRestorationGeneration = 0
    private var restoringReadingAnchor = false
    private var suppressesSelectionScrolling = false
    private var sourceRevealRange: NSRange?
    private var sourceRevealStartedAt: TimeInterval?
    private var sourceRevealTimer: Timer?
    private var sourceRevealWork: DispatchWorkItem?
    private var sourceRevealGeneration = 0
    private var isPositioningSourceReveal = false
    private var sourceRevealPositioningCancelled = false

    private var isSettlingSourceReveal: Bool {
        sourceRevealRange != nil && !sourceRevealPositioningCancelled &&
            (sourceRevealStartedAt.map { ProcessInfo.processInfo.systemUptime - $0 < 0.6 } ?? true)
    }

    /// A source jump wins over restoration of a previously visible reading line.
    func revealSource(_ range: NSRange) {
        clearSourceReveal()
        cancelReadingAnchorRestoration()
        sourceRevealRange = range
        sourceRevealPositioningCancelled = false
        scheduleSourceRevealPositioning()
    }

    func clearSourceReveal() {
        sourceRevealGeneration += 1
        sourceRevealWork?.cancel()
        sourceRevealWork = nil
        sourceRevealTimer?.invalidate()
        sourceRevealTimer = nil
        sourceRevealRange = nil
        sourceRevealStartedAt = nil
        needsDisplay = true
    }

    func sourceRevealViewportDidChange() {
        guard isSettlingSourceReveal, !isPositioningSourceReveal else { return }
        cancelReadingAnchorRestoration()
        scheduleSourceRevealPositioning()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        splitReflow.willMove(toWindow: newWindow)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { clearSourceReveal() }
        else { sourceRevealViewportDidChange() }
        splitReflow.didMoveToWindow()
    }

    private func scheduleSourceRevealPositioning() {
        sourceRevealWork?.cancel()
        sourceRevealGeneration += 1
        let generation = sourceRevealGeneration
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.sourceRevealGeneration == generation else { return }
            self.sourceRevealWork = nil
            self.positionSourceReveal()
        }
        sourceRevealWork = work
        DispatchQueue.main.async(execute: work)
    }

    private func positionSourceReveal() {
        guard isSettlingSourceReveal, window != nil, let range = sourceRevealRange,
              range.location != NSNotFound, range.length > 0,
              NSMaxRange(range) <= (string as NSString).length,
              let scrollView = enclosingScrollView, let layoutManager, let textContainer else { return }
        isPositioningSourceReveal = true
        defer { isPositioningSourceReveal = false }
        scrollView.layoutSubtreeIfNeeded()
        let clip = scrollView.contentView
        guard clip.bounds.width > 0, clip.bounds.height > 0 else { return }
        layoutManager.ensureLayout(for: textContainer)
        sizeToFit()
        let lineRects = sourceRevealLineRects(for: range)
        guard !lineRects.isEmpty else { return }
        let targetY = ReaderSourceReveal.centeredScrollY(
            lineRects: lineRects, documentHeight: bounds.height, viewportHeight: clip.bounds.height
        )
        clip.scroll(to: NSPoint(x: clip.bounds.minX, y: targetY))
        scrollView.reflectScrolledClipView(clip)
        // Use the native word indicator alongside the quieter full-line cue.
        showFindIndicator(for: range)
        if sourceRevealStartedAt == nil {
            sourceRevealStartedAt = ProcessInfo.processInfo.systemUptime
            let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, let started = self.sourceRevealStartedAt else { return }
                    if ProcessInfo.processInfo.systemUptime - started >= 2.1 {
                        self.clearSourceReveal()
                    } else {
                        self.needsDisplay = true
                    }
                }
            }
            sourceRevealTimer = timer
            RunLoop.main.add(timer, forMode: .common)
        }
        needsDisplay = true
    }

    private func cancelSourceRevealPositioning() {
        sourceRevealPositioningCancelled = true
        sourceRevealGeneration += 1
        sourceRevealWork?.cancel()
        sourceRevealWork = nil
    }

    private func sourceRevealLineRects(for range: NSRange) -> [NSRect] {
        guard let layoutManager, let textContainer,
              range.location != NSNotFound, range.length > 0,
              NSMaxRange(range) <= (string as NSString).length else { return [] }
        return ReaderSourceReveal.lineRects(for: range, layoutManager: layoutManager,
                                            textContainer: textContainer, origin: textContainerOrigin)
    }

    var hasPendingReadingPositionRestoration: Bool {
        pendingReadingAnchor != nil || restoringReadingAnchor || suppressesSelectionScrolling
    }

    func focusPreservingReadingPosition() {
        window?.makeFirstResponder(self)
    }

    override func becomeFirstResponder() -> Bool {
        let clip = enclosingScrollView?.contentView
        let origin = clip?.bounds.origin
        // NSTextView can reveal its old insertion point when it becomes first
        // responder. In a read-only view that point may still be the title.
        let wasSuppressing = suppressesSelectionScrolling
        suppressesSelectionScrolling = true
        let accepted = super.becomeFirstResponder()
        suppressesSelectionScrolling = wasSuppressing
        if let clip, let origin, clip.bounds.origin != origin {
            clip.scroll(to: origin)
            enclosingScrollView?.reflectScrolledClipView(clip)
        }
        return accepted
    }

    private lazy var splitReflow = ReaderSplitReflowController(textView: self) { [weak self] lockedWidth, crossfade in
        self?.applyDeferredSplitFlush(lockedWidth: lockedWidth, crossfade: crossfade)
    }

    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        splitReflow.flushIfSettled()
    }

    override func layout() {
        super.layout()
        splitReflow.flushIfSettled()
    }

    func flushDeferredSplitTextLayout() {
        splitReflow.flush()
    }

    private func applyDeferredSplitFlush(lockedWidth: CGFloat, crossfade: Bool) {
        let targetWidth = readingTextWidth(for: bounds.width)
        let widthChanged = abs(targetWidth - lockedWidth) > 0.5
        if widthChanged,
           !isSettlingSourceReveal, !restoringReadingAnchor, pendingReadingAnchor == nil {
            pendingReadingAnchor = visibleReadingAnchor()
        }
        ReaderSplitReflowController.applyCrossfadeIfNeeded(to: self, enabled: crossfade && widthChanged)
        updateReadingMargins()
        if isSettlingSourceReveal {
            sourceRevealViewportDidChange()
        }
        restoreReadingAnchor()
    }

    override func setFrameSize(_ newSize: NSSize) {
        let newTextWidth = readingTextWidth(for: newSize.width)
        let currentWidth = textContainer?.containerSize.width ?? readingTextWidth(for: frame.width)
        let utf16Length = (string as NSString).length
        if splitReflow.shouldDeferReflow(newTextWidth: newTextWidth,
                                         currentWidth: currentWidth,
                                         utf16Length: utf16Length),
           let textContainer {
            if splitReflow.beginOrContinueDeferral(currentContainerWidth: textContainer.containerSize.width),
               !isSettlingSourceReveal, !restoringReadingAnchor, pendingReadingAnchor == nil {
                pendingReadingAnchor = visibleReadingAnchor()
            }
            if textContainer.widthTracksTextView { textContainer.widthTracksTextView = false }
            super.setFrameSize(newSize)
            updateReadingMargins()
            return
        }
        splitReflow.clearPendingDeferral()
        // Centering an already capped text column doesn't rewrap any lines.
        // Only preserve an anchor when the usable text width actually changes.
        let widthChanges = abs(newTextWidth - readingTextWidth(for: frame.width)) > 0.5
        if widthChanges, !isSettlingSourceReveal, !restoringReadingAnchor, pendingReadingAnchor == nil {
            pendingReadingAnchor = visibleReadingAnchor()
        }
        let nextInset = NSSize(width: readingHorizontalInset(for: newSize.width),
                               height: readingStyle.readerVerticalInset)
        if textContainerInset != nextInset { textContainerInset = nextInset }
        // Keep container width fixed across frames when already capped at maximumTextWidth
        // so super.setFrameSize doesn't momentarily alter containerSize with the stale inset.
        if let textContainer {
            let isCappedAndUnchanged = !widthChanges
                && newTextWidth >= Self.maximumTextWidth - 0.5
                && abs(textContainer.containerSize.width - newTextWidth) <= 0.5
            let shouldTrack = !isCappedAndUnchanged
            if textContainer.widthTracksTextView != shouldTrack {
                textContainer.widthTracksTextView = shouldTrack
            }
        }
        super.setFrameSize(newSize)
        updateReadingMargins()
        if isSettlingSourceReveal {
            sourceRevealViewportDidChange()
            return
        }
        if widthChanges, pendingReadingAnchor != nil, resizeRestoration == nil {
            // Keep one restoration per run-loop turn, using the anchor from
            // before that turn's first width change rather than intermediate layouts.
            let generation = resizeRestorationGeneration
            let restoration = DispatchWorkItem { [weak self] in
                guard let self, self.resizeRestorationGeneration == generation else { return }
                self.restoreReadingAnchor()
            }
            resizeRestoration = restoration
            DispatchQueue.main.async(execute: restoration)
        }
    }

    private func visibleReadingAnchor() -> ReadingAnchor? {
        guard !string.isEmpty, let layoutManager, let textContainer,
              enclosingScrollView != nil else { return nil }
        let viewport = visibleRect.offsetBy(dx: -textContainerOrigin.x, dy: -textContainerOrigin.y)
        layoutManager.ensureLayout(forBoundingRect: viewport, in: textContainer)
        let glyphs = layoutManager.glyphRange(
            forBoundingRect: viewport,
            in: textContainer
        )
        guard glyphs.length > 0 else { return nil }
        let line = layoutManager.lineFragmentRect(forGlyphAt: glyphs.location, effectiveRange: nil)
        return ReadingAnchor(character: layoutManager.characterIndexForGlyph(at: glyphs.location),
                             offsetFromLineTop: visibleRect.minY - textContainerOrigin.y - line.minY)
    }

    private func restoreReadingAnchor() {
        guard let anchor = pendingReadingAnchor else { return }
        pendingReadingAnchor = nil
        resizeRestoration = nil
        guard let scrollView = enclosingScrollView, let layoutManager,
              anchor.character < (string as NSString).length else { return }
        restoringReadingAnchor = true
        defer { restoringReadingAnchor = false }
        let anchorRange = (string as NSString).rangeOfComposedCharacterSequence(at: anchor.character)
        layoutManager.ensureLayout(forCharacterRange: anchorRange)
        let glyph = layoutManager.glyphIndexForCharacter(at: anchor.character)
        let line = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        let clip = scrollView.contentView
        let maximumY = max(0, bounds.height - clip.bounds.height)
        let targetY = min(maximumY, max(0, textContainerOrigin.y + line.minY + anchor.offsetFromLineTop))
        clip.scroll(to: NSPoint(x: clip.bounds.minX, y: targetY))
        scrollView.reflectScrolledClipView(clip)
    }

    private func cancelReadingAnchorRestoration() {
        pendingReadingAnchor = nil
        resizeRestorationGeneration += 1
        resizeRestoration?.cancel()
        resizeRestoration = nil
    }

    override func scrollRangeToVisible(_ range: NSRange) {
        guard !suppressesSelectionScrolling else { return }
        if !isPositioningSourceReveal { cancelSourceRevealPositioning() }
        cancelReadingAnchorRestoration()
        super.scrollRangeToVisible(range)
    }

    override func scrollWheel(with event: NSEvent) {
        cancelSourceRevealPositioning()
        cancelReadingAnchorRestoration()
        super.scrollWheel(with: event)
    }

    override func keyDown(with event: NSEvent) {
        cancelSourceRevealPositioning()
        cancelReadingAnchorRestoration()
        super.keyDown(with: event)
    }

    func updateReadingMargins() {
        guard !updatingReadingMargins else { return }
        updatingReadingMargins = true
        defer { updatingReadingMargins = false }
        let targetWidth = splitReflow.deferredTextWidth ?? Self.maximumTextWidth
        let horizontalInset = readingHorizontalInset(for: bounds.width, targetWidth: targetWidth)
        let inset = NSSize(width: horizontalInset,
                           height: readingStyle.readerVerticalInset)
        if textContainerInset != inset { textContainerInset = inset }
        if let textContainer {
            if let deferredWidth = splitReflow.deferredTextWidth {
                if textContainer.widthTracksTextView { textContainer.widthTracksTextView = false }
                if abs(textContainer.containerSize.width - deferredWidth) > 0.5 {
                    textContainer.containerSize = NSSize(width: deferredWidth, height: CGFloat.greatestFiniteMagnitude)
                }
                return
            }
            let textWidth = readingTextWidth(for: bounds.width)
            let isCapped = textWidth >= Self.maximumTextWidth - 0.5
            if isCapped && abs(textContainer.containerSize.width - textWidth) <= 0.5 {
                if textContainer.widthTracksTextView { textContainer.widthTracksTextView = false }
            } else {
                if !textContainer.widthTracksTextView {
                    textContainer.widthTracksTextView = true
                }
                if abs(textContainer.containerSize.width - textWidth) > 0.5 {
                    textContainer.containerSize = NSSize(width: textWidth, height: textContainer.containerSize.height)
                }
            }
        }
        articleByline.layout(in: self)
    }

    private func readingHorizontalInset(for width: CGFloat, targetWidth: CGFloat = maximumTextWidth) -> CGFloat {
        max(CGFloat(typography.sideInset), (width - targetWidth) / 2)
    }

    private func readingTextWidth(for width: CGFloat) -> CGFloat {
        max(1, width - 2 * readingHorizontalInset(for: width))
    }

    var cardRanges: [(NSRange, StudyCard)] = []
    var onCardClick: ((StudyCard) -> Void)?
    var onAskAI: ((NSRange) -> Void)?
    var onCreateCard: ((NSRange) -> Void)?
    var onTranslate: ((NSRange) -> Void)?
    var supportsSystemTranslation = false
    var onShowFind: (() -> Void)?
    var onCloseFind: (() -> Bool)?
    var onFind: ((Int) -> Void)?
    var onExitDistractionFree: (() -> Void)?
    private var contextSelection = NSRange(location: 0, length: 0)

    func resetCapturedSelection() {
        contextSelection = NSRange(location: 0, length: 0)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            .subtracting([.capsLock, .numericPad, .function])
        if modifiers == .command, event.charactersIgnoringModifiers?.lowercased() == "f",
           let onShowFind {
            onShowFind()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func performFindPanelAction(_ sender: Any?) {
        let action = (sender as? NSMenuItem)?.tag ?? NSTextFinder.Action.showFindInterface.rawValue
        switch action {
        case NSTextFinder.Action.nextMatch.rawValue: onFind?(1)
        case NSTextFinder.Action.previousMatch.rawValue: onFind?(-1)
        case NSTextFinder.Action.hideFindInterface.rawValue: _ = onCloseFind?()
        default: onShowFind?()
        }
    }

    override func cancelOperation(_ sender: Any?) {
        if onCloseFind?() != true { super.cancelOperation(sender) }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        let location = characterIndexForInsertion(at: point)
        let selected = selectedRange()
        if selected.length == 0 || !NSLocationInRange(location, selected) {
            let range = selectionRange(forProposedRange: NSRange(location: location, length: 0),
                                       granularity: .selectByWord)
            setSelectedRange(range)
        }
        contextSelection = selectedRange()
        let valid = contextSelection.length > 0 &&
            !(string as NSString).substring(with: contextSelection)
                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.allowsContextMenuPlugIns = false
        if #available(macOS 15.2, *) {
            menu.automaticallyInsertsWritingToolsItems = false
        }
        @discardableResult
        func item(_ title: String, _ action: Selector, enabled: Bool = true) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.isEnabled = enabled
            menu.addItem(item)
            return item
        }
        item(L("添加划记", "Add highlight"), #selector(createCardFromMenu(_:)), enabled: valid)
        item(L("查询词典", "Look up in Dictionary"), #selector(lookUpFromMenu(_:)), enabled: valid)
        item(L("翻译", "Translate"), #selector(translateFromMenu(_:)),
             enabled: valid && supportsSystemTranslation)
        item(L("询问AI", "Ask AI"), #selector(askAIFromMenu(_:)), enabled: valid)
        menu.addItem(.separator())
        item(L("复制", "Copy"), #selector(NSText.copy(_:)), enabled: valid)
        item(L("全选", "Select All"), #selector(NSText.selectAll(_:)))
        menu.addItem(.separator())
        item(L("开始朗读", "Start Speaking"), #selector(NSTextView.startSpeaking(_:)), enabled: valid)
        item(L("停止朗读", "Stop Speaking"), #selector(NSTextView.stopSpeaking(_:)))
        if onExitDistractionFree != nil {
            menu.addItem(.separator())
            item(L("退出专注阅读", "Exit Focused Reading"), #selector(exitDistractionFree(_:)))
        }
        return menu
    }

    @objc private func exitDistractionFree(_ sender: Any?) {
        onExitDistractionFree?()
    }

    override func draw(_ dirtyRect: NSRect) {
        drawSourceReveal(in: dirtyRect)
        super.draw(dirtyRect)
        guard !isDistractionFree, let layoutManager, let textContainer else { return }
        for block in decorationBlocks where NSMaxRange(block.range) <= (string as NSString).length && block.range.length > 0 {
            let isLicense = block.kind == .license
            guard isLicense || readingStyle == .magazine else { continue }
            let glyphs = layoutManager.glyphRange(forCharacterRange: block.range, actualCharacterRange: nil)
            let rect = layoutManager.boundingRect(forGlyphRange: glyphs, in: textContainer)
                .offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y)
            if isLicense {
                readingStyle.readerForeground.withAlphaComponent(0.14).setFill()
                let rule = NSRect(x: textContainerOrigin.x, y: rect.minY - 8,
                                  width: min(140, textContainer.containerSize.width), height: 1)
                if dirtyRect.intersects(rule) { rule.fill() }
            } else {
                let isTitle = block.kind == .title
                readingStyle.readerAccent.withAlphaComponent(isTitle ? 0.65 : 0.16).setFill()
                let rule = NSRect(x: textContainerOrigin.x, y: isTitle ? rect.maxY + 6 : rect.minY - 6,
                                  width: isTitle ? 42 : textContainer.containerSize.width, height: isTitle ? 2 : 1)
                if dirtyRect.intersects(rule) { rule.fill() }
            }
        }
    }

    private func drawSourceReveal(in dirtyRect: NSRect) {
        guard let range = sourceRevealRange, let started = sourceRevealStartedAt,
              NSMaxRange(range) <= (string as NSString).length,
              let textContainer else { return }
        let lines = sourceRevealLineRects(for: range)
        guard !lines.isEmpty else { return }
        let elapsed = ProcessInfo.processInfo.systemUptime - started
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let pulse = reduceMotion ? 0.5 : (1 + cos(elapsed * .pi * 2 / 0.9)) / 2
        let fade = reduceMotion ? 1 : min(1, max(0, (2.1 - elapsed) / 0.6))
        NSColor.systemYellow.withAlphaComponent((0.09 + 0.12 * pulse) * fade).setFill()
        for line in lines {
            let band = NSRect(x: textContainerOrigin.x - 6, y: line.minY - 3,
                              width: textContainer.containerSize.width + 12, height: line.height + 6)
            guard dirtyRect.intersects(band) else { continue }
            NSBezierPath(roundedRect: band, xRadius: 5, yRadius: 5).fill()
        }
    }

    @objc private func askAIFromMenu(_ sender: Any?) {
        guard let selection = restoreContextSelection() else { return }
        onAskAI?(selection)
    }

    @objc private func createCardFromMenu(_ sender: Any?) {
        guard let selection = restoreContextSelection() else { return }
        onCreateCard?(selection)
    }

    @objc private func lookUpFromMenu(_ sender: Any?) {
        guard let selection = restoreContextSelection() else { return }
        showDefinition(for: nil, range: selection,
                       options: [.presentationType: NSView.DefinitionPresentationType.overlay],
                       baselineOriginProvider: nil)
    }

    @objc private func translateFromMenu(_ sender: Any?) {
        guard supportsSystemTranslation, let selection = restoreContextSelection() else { return }
        onTranslate?(selection)
    }

    private func restoreContextSelection() -> NSRange? {
        let length = (string as NSString).length
        guard contextSelection.location != NSNotFound, contextSelection.location >= 0,
              contextSelection.length > 0, contextSelection.location <= length,
              contextSelection.length <= length - contextSelection.location else { return nil }
        window?.makeFirstResponder(self)
        setSelectedRange(contextSelection)
        return contextSelection
    }

    override func mouseDown(with event: NSEvent) {
        cancelSourceRevealPositioning()
        cancelReadingAnchorRestoration()
        if event.clickCount >= 1 {
            let point = convert(event.locationInWindow, from: nil)
            let location = characterIndexForInsertion(at: point)
            if let card = cardRanges.first(where: { NSLocationInRange(location, $0.0) })?.1 {
                onCardClick?(card)
                return
            }
        }
        super.mouseDown(with: event)
    }
}

private struct SystemTranslationPresentation: ViewModifier {
    @Binding var isPresented: Bool
    let text: String
    let anchor: UnitPoint

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 14.4, *) {
            content.translationPresentation(
                isPresented: $isPresented,
                text: text,
                attachmentAnchor: .point(anchor),
                arrowEdge: .top
            )
        } else {
            content
        }
    }
}

extension ReadingViewStyle {
    func readerTitleFont(size: Double) -> NSFont {
        let pointSize = size + (self == .magazine ? 24 : 13)
        let base = NSFont.systemFont(ofSize: pointSize, weight: self == .magazine ? .bold : .semibold)
        guard self == .book || self == .magazine,
              let descriptor = base.fontDescriptor.withDesign(.serif) else { return base }
        return NSFont(descriptor: descriptor, size: base.pointSize) ?? base
    }

    func readerFont(size: Double) -> NSFont {
        let base = NSFont.systemFont(ofSize: size)
        guard self == .book,
              let descriptor = base.fontDescriptor.withDesign(.serif) else { return base }
        return NSFont(descriptor: descriptor, size: size) ?? base
    }

    var readerVerticalInset: CGFloat {
        switch self {
        case .standard: return 28
        case .book: return 40
        case .focus: return 48
        case .magazine: return 36
        }
    }

    var readerBackground: NSColor {
        switch self {
        case .standard: return .textBackgroundColor
        case .book:
            return NSColor(name: nil) { appearance in
                appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                    ? NSColor(srgbRed: 0.13, green: 0.12, blue: 0.10, alpha: 1)
                    : NSColor(srgbRed: 0.98, green: 0.96, blue: 0.91, alpha: 1)
            }
        case .focus:
            return NSColor(name: nil) { appearance in
                appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                    ? NSColor(srgbRed: 0.09, green: 0.10, blue: 0.11, alpha: 1)
                    : NSColor(srgbRed: 0.95, green: 0.96, blue: 0.97, alpha: 1)
            }
        case .magazine:
            return NSColor(name: nil) { appearance in
                appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                    ? NSColor(srgbRed: 0.10, green: 0.12, blue: 0.15, alpha: 1)
                    : NSColor(srgbRed: 0.99, green: 0.99, blue: 0.97, alpha: 1)
            }
        }
    }

    var readerForeground: NSColor {
        guard self == .book else { return .labelColor }
        return NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? NSColor(srgbRed: 0.89, green: 0.86, blue: 0.79, alpha: 1)
                : NSColor(srgbRed: 0.20, green: 0.17, blue: 0.13, alpha: 1)
        }
    }

    var readerAccent: NSColor {
        switch self {
        case .standard: return .secondaryLabelColor
        case .book: return NSColor.systemBrown
        case .focus: return .systemGray
        case .magazine: return .systemBlue
        }
    }

    var readerHighlight: NSColor {
        self == .book
            ? NSColor.systemBrown.withAlphaComponent(0.19)
            : NSColor.systemYellow.withAlphaComponent(0.30)
    }

    var readerAlignmentHighlight: NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let components: (red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat)
            switch (self, isDark) {
            case (.standard, false): components = (0.15, 0.62, 0.58, 0.30)
            case (.standard, true): components = (0.08, 0.50, 0.48, 0.46)
            case (.book, false): components = (0.24, 0.61, 0.48, 0.30)
            case (.book, true): components = (0.08, 0.47, 0.40, 0.45)
            case (.focus, false): components = (0.18, 0.57, 0.65, 0.29)
            case (.focus, true): components = (0.07, 0.45, 0.55, 0.46)
            case (.magazine, false): components = (0.16, 0.58, 0.67, 0.29)
            case (.magazine, true): components = (0.08, 0.47, 0.59, 0.45)
            }
            return NSColor(srgbRed: components.red, green: components.green,
                           blue: components.blue, alpha: components.alpha)
        }
    }
}

/// Style the stored block separators without removing characters: annotations,
/// search and reading progress all use offsets into the original article text.
func styleReaderParagraphs(_ text: NSMutableAttributedString, title: String?,
                                   blocks: [ArticleTextBlock], readingStyle: ReadingViewStyle,
                                   typography: ReadingTypography) {
    let source = text.string as NSString
    var location = 0
    var followsTitle = false
    while location < source.length {
        var end = 0
        var contentsEnd = 0
        source.getParagraphStart(nil, end: &end, contentsEnd: &contentsEnd,
                                 for: NSRange(location: location, length: 0))
        let range = NSRange(location: location, length: end - location)
        let content = source.substring(with: NSRange(location: location, length: contentsEnd - location))
        if location == 0, content == title {
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineBreakMode = .byWordWrapping
            paragraph.lineSpacing = 4
            text.addAttributes([.font: readingStyle.readerTitleFont(size: typography.fontSize),
                                .paragraphStyle: paragraph, .kern: readingStyle == .magazine ? -0.5 : 0], range: range)
            followsTitle = true
        } else if content.trimmingCharacters(in: .whitespaces).isEmpty {
            let paragraph = NSMutableParagraphStyle()
            let height = typography.paragraphSpacing + (followsTitle ? (readingStyle == .magazine ? 14 : 8) : 0)
            paragraph.minimumLineHeight = height
            paragraph.maximumLineHeight = height
            text.addAttributes([.font: NSFont.systemFont(ofSize: 1), .paragraphStyle: paragraph], range: range)
        } else {
            followsTitle = false
        }
        location = end
    }
    for block in blocks where block.range.length > 0 && NSMaxRange(block.range) <= text.length {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.lineSpacing = typography.lineSpacing
        switch block.kind {
        case .heading(let level):
            let size = typography.fontSize + max(1, 9 - Double(level) * 2)
            paragraph.lineSpacing = 3
            paragraph.paragraphSpacingBefore = readingStyle == .magazine ? 12 : 6
            text.addAttributes([.font: NSFont.systemFont(ofSize: size, weight: .semibold),
                                .paragraphStyle: paragraph,
                                .foregroundColor: readingStyle == .magazine ? readingStyle.readerAccent : readingStyle.readerForeground],
                               range: block.range)
        case .lead:
            if readingStyle == .magazine {
                paragraph.lineSpacing = typography.lineSpacing + 2
                text.addAttributes([.font: NSFont.systemFont(ofSize: typography.fontSize + 2, weight: .medium),
                                    .paragraphStyle: paragraph,
                                    .foregroundColor: readingStyle.readerForeground.withAlphaComponent(0.78)],
                                   range: block.range)
            }
        case .quote:
            paragraph.firstLineHeadIndent = 18
            paragraph.headIndent = 18
            paragraph.tailIndent = -12
            text.addAttributes([.paragraphStyle: paragraph,
                                .foregroundColor: readingStyle.readerForeground.withAlphaComponent(0.76)],
                               range: block.range)
        case .listItem(let depth):
            let indent = CGFloat(max(0, depth)) * 22
            let markerWidth: CGFloat = 28
            paragraph.firstLineHeadIndent = indent
            paragraph.headIndent = indent + markerWidth
            paragraph.tabStops = [NSTextTab(textAlignment: .left, location: indent + markerWidth)]
            paragraph.defaultTabInterval = markerWidth
            text.addAttribute(.paragraphStyle, value: paragraph, range: block.range)
        case .license:
            let size = max(12, min(14, typography.fontSize - 3))
            paragraph.lineSpacing = max(3, typography.lineSpacing * 0.55)
            paragraph.paragraphSpacingBefore = readingStyle == .magazine ? 20 : 16
            text.addAttributes([.font: NSFont.systemFont(ofSize: size, weight: .regular),
                                .paragraphStyle: paragraph,
                                .foregroundColor: readingStyle.readerForeground.withAlphaComponent(0.58)],
                               range: block.range)
        case .paragraph, .title, .list, .literal:
            break
        }
    }
}

private func scalarRange(start: Int, end: Int, in text: String) -> NSRange? {
    guard start >= 0, end > start, end <= text.unicodeScalars.count else { return nil }
    let lower = text.unicodeScalars.index(text.unicodeScalars.startIndex, offsetBy: start)
    let upper = text.unicodeScalars.index(text.unicodeScalars.startIndex, offsetBy: end)
    guard let lowerIndex = String.Index(lower, within: text), let upperIndex = String.Index(upper, within: text) else { return nil }
    return NSRange(lowerIndex..<upperIndex, in: text)
}

private func utf16Offset(forScalarOffset offset: Int, in text: String) -> Int {
    let scalars = text.unicodeScalars
    let clamped = max(0, min(offset, scalars.count))
    let index = scalars.index(scalars.startIndex, offsetBy: clamped)
    return (text[..<index] as NSString).length
}
