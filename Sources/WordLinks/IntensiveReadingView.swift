import AppKit
import Combine
import SwiftUI

struct IntensiveSentence: Equatable {
    let id: Int
    let sourceRange: NSRange
    let source: String
}

@MainActor
final class IntensiveReadingModel: ObservableObject {
    @Published private(set) var translations: [Int: IntensiveReadingTranslation] = [:]
    @Published private(set) var isGenerating = false
    @Published private(set) var completedCount = 0
    @Published private(set) var issue: String?
    @Published private(set) var isActivated = false

    fileprivate let sentences: [IntensiveSentence]
    let targetLanguage: StudyLanguage
    private let profileID: UUID
    private let articleID: UUID
    private let articleText: String
    private let settings: AISettingsStore
    private let store: ReadingLibraryStore
    private var task: Task<Void, Never>?
    private var generationID = UUID()
    private var regenerationPending = Set<Int>()
    private var activationRequested = false
    var onProgressChange: ((IntensiveReadingProgress) -> Void)?

    init(article: LibraryArticle, profileID: UUID, store: ReadingLibraryStore, settings: AISettingsStore) {
        self.profileID = profileID
        articleID = article.id
        articleText = article.text
        self.store = store
        self.settings = settings
        targetLanguage = settings.studyLanguage
        let source = article.text as NSString
        sentences = SelectionContext.sentenceRanges(in: article.text, articleTitle: article.title)
            .enumerated().compactMap { index, range in
                guard range.location >= 0, NSMaxRange(range) <= source.length else { return nil }
                return IntensiveSentence(id: index, sourceRange: range, source: source.substring(with: range))
            }
        do {
            let cached = try store.intensiveTranslations(articleID: article.id, targetLanguage: targetLanguage)
            for sentence in sentences {
                if let result = cached[sentence.source], result.isValid(for: sentence.source) {
                    translations[sentence.id] = result
                }
            }
        } catch {
            issue = error.localizedDescription
        }
        completedCount = translations.count
    }

    func setActivated(_ enabled: Bool) {
        activationRequested = enabled
        guard enabled else {
            isActivated = false
            return
        }
        if progress.isComplete {
            isActivated = true
        } else {
            startIfNeeded()
        }
    }

    func startIfNeeded() {
        activationRequested = true
        if progress.isComplete {
            isActivated = true
            return
        }
        guard !isGenerating,
              (translations.count < sentences.count || !regenerationPending.isEmpty) else { return }
        generate(force: false)
    }

    func regenerate() {
        task?.cancel()
        generationID = UUID()
        activationRequested = true
        isActivated = false
        regenerationPending = Set(sentences.map(\.id))
        completedCount = 0
        generate(force: true)
    }

    func cancel() {
        generationID = UUID()
        task?.cancel()
        task = nil
        isGenerating = false
        activationRequested = false
        notifyProgressChange()
    }

    var progress: IntensiveReadingProgress {
        IntensiveReadingProgress(isGenerating: isGenerating,
                                 completedCount: completedCount,
                                 totalCount: sentences.count,
                                 issue: issue)
    }

    private func notifyProgressChange() {
        onProgressChange?(progress)
    }

    private func generate(force: Bool) {
        let pending = sentences.filter {
            force || translations[$0.id] == nil || regenerationPending.contains($0.id)
        }
        guard !pending.isEmpty else { return }
        let batches = stride(from: 0, to: pending.count, by: 4).map {
            Array(pending[$0..<min($0 + 4, pending.count)])
        }
        let requestID = generationID
        let configurationRevision = settings.configurationRevision
        issue = nil
        completedCount = force ? 0 : (regenerationPending.isEmpty
                                        ? translations.count
                                        : sentences.count - regenerationPending.count)
        isGenerating = true
        notifyProgressChange()
        task = Task { [weak self] in
            guard let self else { return }
            do {
                try await withThrowingTaskGroup(of: Void.self) { group in
                    var next = batches.makeIterator()
                    for _ in 0..<min(3, batches.count) {
                        if let batch = next.next() {
                            group.addTask {
                                try await self.translate(batch, requestID: requestID,
                                                         configurationRevision: configurationRevision)
                            }
                        }
                    }
                    while try await group.next() != nil {
                        guard self.generationID == requestID else { throw CancellationError() }
                        if let batch = next.next() {
                            group.addTask {
                                try await self.translate(batch, requestID: requestID,
                                                         configurationRevision: configurationRevision)
                            }
                        }
                    }
                }
            } catch is CancellationError {
                if self.generationID == requestID &&
                    (self.translations.count < self.sentences.count || !self.regenerationPending.isEmpty) {
                    self.issue = L("AI 配置已变化，请重试未完成的句子。", "AI settings changed. Retry the remaining sentences.")
                }
            } catch {
                if self.generationID == requestID { self.issue = error.localizedDescription }
            }
            if self.generationID == requestID {
                self.isGenerating = false
                self.task = nil
                if self.progress.isComplete && self.activationRequested { self.isActivated = true }
                self.notifyProgressChange()
            }
        }
    }

    private func validateGeneration(_ requestID: UUID, configurationRevision: UInt64) throws {
        try Task.checkCancellation()
        guard generationID == requestID,
              store.archive.id == profileID,
              store.archive.articles.first(where: { $0.id == articleID })?.text == articleText,
              settings.studyLanguage == targetLanguage,
              settings.configurationRevision == configurationRevision else { throw CancellationError() }
    }

    private func translate(_ batch: [IntensiveSentence], requestID: UUID,
                           configurationRevision: UInt64) async throws {
        try validateGeneration(requestID, configurationRevision: configurationRevision)
        let items = batch.map { sentence in
            IntensiveReadingBatchInput(id: sentence.id, source: sentence.source,
                                       words: IntensiveReadingAlignmentBuilder.wordRanges(in: sentence.source)
                .enumerated().map { index, range in
                    let text = (sentence.source as NSString).substring(with: range.range)
                    return IntensiveReadingBatchInput.Word(id: index, text: text)
                })
        }
        let encoded = String(decoding: try JSONEncoder().encode(items), as: UTF8.self)
        let responseText = try await settings.explain(selection: encoded,
                                                      context: "",
                                                      purpose: .intensive)
        try validateGeneration(requestID, configurationRevision: configurationRevision)
        let decoded = try IntensiveReadingBatchResponse.decode(responseText)
        let suggestions = Dictionary(decoded.sentences.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        guard suggestions.count == batch.count,
              batch.allSatisfy({ suggestions[$0.id] != nil }) else { throw AIError.invalidResponse }

        for sentence in batch {
            try validateGeneration(requestID, configurationRevision: configurationRevision)
            guard let suggestion = suggestions[sentence.id],
                  let result = IntensiveReadingAlignmentBuilder.translation(source: sentence.source,
                                                                            suggestion: suggestion),
                  result.isValid(for: sentence.source) else {
                throw AIError.invalidResponse
            }
            try store.saveIntensiveTranslation(result, articleID: articleID, targetLanguage: targetLanguage)
            translations[sentence.id] = result
            regenerationPending.remove(sentence.id)
            completedCount += 1
            notifyProgressChange()
        }
    }
}

@MainActor
final class IntensiveReadingModelPool: ObservableObject {
    private struct Scope: Equatable {
        let profileID: UUID
        let targetLanguage: StudyLanguage
    }

    private struct Key: Hashable {
        let profileID: UUID
        let articleID: UUID
        let articleText: String
        let targetLanguage: String
    }

    private var models: [Key: IntensiveReadingModel] = [:]
    private var scope: Scope?

    func synchronizeScope(profileID: UUID, targetLanguage: StudyLanguage) {
        let requestedScope = Scope(profileID: profileID, targetLanguage: targetLanguage)
        guard scope != requestedScope else { return }
        cancelAll()
        scope = requestedScope
    }

    func model(for article: LibraryArticle, profileID: UUID, store: ReadingLibraryStore,
               settings: AISettingsStore) -> IntensiveReadingModel {
        synchronizeScope(profileID: profileID, targetLanguage: settings.studyLanguage)
        let key = Key(profileID: profileID, articleID: article.id, articleText: article.text,
                      targetLanguage: settings.studyLanguage.rawValue)
        if let model = models[key] { return model }

        let staleKeys = models.keys.filter {
            $0.profileID == profileID && $0.articleID == article.id && $0 != key
        }
        for staleKey in staleKeys {
            guard let staleModel = models.removeValue(forKey: staleKey) else { continue }
            staleModel.cancel()
            staleModel.onProgressChange = nil
        }

        let model = IntensiveReadingModel(article: article, profileID: profileID,
                                          store: store, settings: settings)
        models[key] = model
        return model
    }

    func cancelAll() {
        let modelsToCancel = Array(models.values)
        models.removeAll()
        scope = nil
        for model in modelsToCancel {
            model.onProgressChange = nil
            model.cancel()
        }
    }
}

struct IntensiveReadingView: View {
    @ObservedObject var model: IntensiveReadingModel
    let article: LibraryArticle
    let cards: [StudyCard]
    let store: ReadingLibraryStore
    let aiSettings: AISettingsStore
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
    let onShowFind: () -> Void
    let onCloseFind: () -> Bool
    let onExitDistractionFree: (() -> Void)?
    let onFind: (Int) -> Void
    let onReadOffset: (Int) -> Void
    let onReadingProgress: (Double) -> Void
    let supportsSystemTranslation: Bool
    let onOpenAISettings: () -> Void
    let onTranslate: (String, UnitPoint) -> Void

    init(article: LibraryArticle, model: IntensiveReadingModel, cards: [StudyCard],
         store: ReadingLibraryStore, aiSettings: AISettingsStore,
         initialOffset: Int, sourceReveal: ReaderSourceReveal?, searchText: String, searchRequest: Int,
         searchDirection: Int, isShowingFind: Bool, readerFocusRequest: Int,
         readingStyle: ReadingViewStyle, typography: ReadingTypography, isDistractionFree: Bool,
         onShowFind: @escaping () -> Void, onCloseFind: @escaping () -> Bool,
         onExitDistractionFree: (() -> Void)?, onFind: @escaping (Int) -> Void,
         onReadOffset: @escaping (Int) -> Void, onReadingProgress: @escaping (Double) -> Void,
         supportsSystemTranslation: Bool, onOpenAISettings: @escaping () -> Void,
         onTranslate: @escaping (String, UnitPoint) -> Void) {
        self.model = model
        self.article = article
        self.cards = cards
        self.store = store
        self.aiSettings = aiSettings
        self.initialOffset = initialOffset
        self.sourceReveal = sourceReveal
        self.searchText = searchText
        self.searchRequest = searchRequest
        self.searchDirection = searchDirection
        self.isShowingFind = isShowingFind
        self.readerFocusRequest = readerFocusRequest
        self.readingStyle = readingStyle
        self.typography = typography
        self.isDistractionFree = isDistractionFree
        self.onShowFind = onShowFind
        self.onCloseFind = onCloseFind
        self.onExitDistractionFree = onExitDistractionFree
        self.onFind = onFind
        self.onReadOffset = onReadOffset
        self.onReadingProgress = onReadingProgress
        self.supportsSystemTranslation = supportsSystemTranslation
        self.onOpenAISettings = onOpenAISettings
        self.onTranslate = onTranslate
    }

    var body: some View {
        VStack(spacing: 0) {
            IntensiveArticleTextView(
                article: article,
                sentences: model.sentences,
                translations: model.translations,
                cards: cards,
                store: store,
                aiSettings: aiSettings,
                supportsSystemTranslation: supportsSystemTranslation,
                onOpenAISettings: onOpenAISettings,
                onTranslate: onTranslate,
                initialOffset: initialOffset,
                sourceReveal: sourceReveal,
                searchText: searchText,
                searchRequest: searchRequest,
                searchDirection: searchDirection,
                isShowingFind: isShowingFind,
                readerFocusRequest: readerFocusRequest,
                readingStyle: readingStyle,
                typography: typography,
                isDistractionFree: isDistractionFree,
                onShowFind: onShowFind,
                onCloseFind: onCloseFind,
                onExitDistractionFree: onExitDistractionFree,
                onFind: onFind,
                onReadOffset: onReadOffset,
                onReadingProgress: onReadingProgress
            )
        }
    }
}

struct IntensiveDocumentSegment {
    let articleRange: NSRange
    let displayRange: NSRange
}

struct IntensiveRenderDocument {
    let attributedText: NSAttributedString
    let alignments: [IntensiveReadingAlignment]
    let sourceSegments: [IntensiveDocumentSegment]
    let articleText: String

    func displayRanges(forArticleRange range: NSRange) -> [NSRange] {
        sourceSegments.compactMap { segment in
            let intersection = NSIntersectionRange(range, segment.articleRange)
            guard intersection.length > 0 else { return nil }
            return NSRange(location: segment.displayRange.location + intersection.location - segment.articleRange.location,
                          length: intersection.length)
        }
    }

    func articleRange(forDisplayRange range: NSRange) -> NSRange? {
        guard range.location != NSNotFound, range.location >= 0, range.length > 0,
              range.location <= attributedText.length,
              range.length <= attributedText.length - range.location else { return nil }
        let matches = sourceSegments.compactMap { segment -> (NSRange, NSRange)? in
            let intersection = NSIntersectionRange(range, segment.displayRange)
            guard intersection.length > 0 else { return nil }
            let articleLocation = segment.articleRange.location + intersection.location - segment.displayRange.location
            return (intersection, NSRange(location: articleLocation, length: intersection.length))
        }
        guard let first = matches.first, let last = matches.last else { return nil }
        let end = NSMaxRange(last.1)
        return NSRange(location: first.1.location, length: end - first.1.location)
    }

    func sourceDisplayRange(forDisplayRange range: NSRange) -> NSRange? {
        guard range.location != NSNotFound, range.location >= 0, range.length > 0,
              range.location <= attributedText.length,
              range.length <= attributedText.length - range.location else { return nil }
        let matches = sourceSegments.compactMap { segment -> NSRange? in
            let intersection = NSIntersectionRange(range, segment.displayRange)
            return intersection.length > 0 ? intersection : nil
        }
        return matches.count == 1 ? matches[0] : nil
    }
}

/// Cache the document by content inputs, independently of viewport, focus,
/// search and persisted reading-position updates from the hosting hierarchy.
@MainActor
final class IntensiveDocumentRenderer {
    private struct SourceKey: Equatable {
        let id: UUID
        let title: String
        let markdown: String
        let text: String
    }

    private struct RenderKey: Equatable {
        let source: SourceKey
        let sentences: [IntensiveSentence]
        let translations: [Int: IntensiveReadingTranslation]
        let cards: [StudyCard]
        let style: ReadingViewStyle
        let typography: ReadingTypography
        let waitingText: String
    }

    private struct ParsedSource {
        let metadata: ArticleMetadata
        let blocks: [ArticleTextBlock]
        let inlineStyles: [ArticleInlineStyle]
    }

    private var sourceKey: SourceKey?
    private var parsedSource = ParsedSource(metadata: ArticleMetadata(), blocks: [], inlineStyles: [])
    private var renderKey: RenderKey?
    private var cachedDocument: IntensiveRenderDocument?
    private(set) var metadata = ArticleMetadata()

    func document(article: LibraryArticle, sentences: [IntensiveSentence],
                  translations: [Int: IntensiveReadingTranslation], cards: [StudyCard],
                  readingStyle: ReadingViewStyle, typography: ReadingTypography,
                  waitingText: String) -> IntensiveRenderDocument {
        let source = SourceKey(id: article.id, title: article.title,
                               markdown: article.markdown, text: article.text)
        let key = RenderKey(source: source, sentences: sentences, translations: translations,
                            cards: cards, style: readingStyle, typography: typography,
                            waitingText: waitingText)
        if renderKey == key, let cachedDocument { return cachedDocument }
        if sourceKey != source {
            // Use the shared compatibility accessors for legacy archives whose
            // selectable text differs from the current Markdown interpretation.
            if let parsed = try? ArticleMarkdownDocument.parse(article.markdown), parsed.text == article.text {
                parsedSource = ParsedSource(metadata: parsed.metadata, blocks: parsed.blocks,
                                            inlineStyles: parsed.inlineStyles)
            } else {
                parsedSource = ParsedSource(metadata: article.metadata,
                                            blocks: ReadingLibraryStore.readingBlocks(for: article),
                                            inlineStyles: ReadingLibraryStore.readingInlineStyles(for: article))
            }
            sourceKey = source
        }
        let parsed = parsedSource
        metadata = parsed.metadata
        let document = Self.makeDocument(article: article, sentences: sentences,
                                         translations: translations, cards: cards,
                                         readingStyle: readingStyle, typography: typography,
                                         parsedSource: parsed, waitingText: waitingText)
        renderKey = key
        cachedDocument = document
        return document
    }

    private static func makeDocument(article: LibraryArticle, sentences: [IntensiveSentence],
                                     translations: [Int: IntensiveReadingTranslation],
                                     cards: [StudyCard],
                                     readingStyle: ReadingViewStyle,
                                     typography: ReadingTypography, parsedSource: ParsedSource,
                                     waitingText: String) -> IntensiveRenderDocument {
        let baseParagraph = NSMutableParagraphStyle()
        baseParagraph.lineBreakMode = .byWordWrapping
        baseParagraph.lineSpacing = typography.lineSpacing
        baseParagraph.paragraphSpacing = 0
        let baseAttributes: [NSAttributedString.Key: Any] = [
            .font: readingStyle.readerFont(size: typography.fontSize),
            .foregroundColor: readingStyle.readerForeground,
            .paragraphStyle: baseParagraph
        ]
        let translationParagraph = NSMutableParagraphStyle()
        translationParagraph.lineBreakMode = .byWordWrapping
        translationParagraph.lineSpacing = max(3, typography.lineSpacing - 2)
        translationParagraph.paragraphSpacingBefore = 3
        let text = NSMutableAttributedString(string: "", attributes: baseAttributes)
        let source = article.text as NSString
        var cursor = 0
        var sourceSegments: [IntensiveDocumentSegment] = []
        var alignments: [IntensiveReadingAlignment] = []

        func appendSource(_ range: NSRange) {
            guard range.location >= cursor, range.length >= 0, NSMaxRange(range) <= source.length else { return }
            if range.length > 0 {
                let display = NSRange(location: text.length, length: range.length)
                text.append(NSAttributedString(string: source.substring(with: range), attributes: baseAttributes))
                sourceSegments.append(IntensiveDocumentSegment(articleRange: range, displayRange: display))
                cursor = NSMaxRange(range)
            }
        }

        for sentence in sentences {
            guard sentence.sourceRange.location >= cursor,
                  NSMaxRange(sentence.sourceRange) <= source.length else { continue }
            if sentence.sourceRange.location > cursor {
                let gap = NSRange(location: cursor, length: sentence.sourceRange.location - cursor)
                let gapText = source.substring(with: gap)
                if gapText.contains(where: { !$0.isWhitespace }) {
                    appendSource(gap)
                } else {
                    cursor = NSMaxRange(gap)
                }
            }
            let sourceDisplay = NSRange(location: text.length, length: sentence.sourceRange.length)
            appendSource(sentence.sourceRange)
            text.append(NSAttributedString(string: "\n", attributes: baseAttributes))
            if let translation = translations[sentence.id], translation.isValid(for: sentence.source) {
                let targetDisplayStart = text.length
                let targetAttributes: [NSAttributedString.Key: Any] = [
                    .font: readingStyle.readerFont(size: max(12, typography.fontSize - 1)),
                    .foregroundColor: readingStyle.readerForeground.withAlphaComponent(0.70),
                    .paragraphStyle: translationParagraph
                ]
                text.append(NSAttributedString(string: translation.translation, attributes: targetAttributes))
                for alignment in translation.alignments {
                    let sourceRanges = alignment.sourceRanges.map {
                        IntensiveReadingSpan(location: sourceDisplay.location + $0.location, length: $0.length)
                    }
                    let targetRanges = alignment.targetRanges.map {
                        IntensiveReadingSpan(location: targetDisplayStart + $0.location, length: $0.length)
                    }
                    let global = IntensiveReadingAlignment(sourceRanges: sourceRanges, targetRanges: targetRanges)
                    if global.isValid(source: text.string, target: text.string) { alignments.append(global) }
                }
            } else {
                let loadingAttributes: [NSAttributedString.Key: Any] = [
                    .font: readingStyle.readerFont(size: max(12, typography.fontSize - 1)),
                    .foregroundColor: readingStyle.readerForeground.withAlphaComponent(0.70),
                    .paragraphStyle: translationParagraph
                ]
                text.append(NSAttributedString(string: waitingText, attributes: loadingAttributes))
            }
            text.append(NSAttributedString(string: "\n\n", attributes: baseAttributes))
        }
        if cursor < source.length { appendSource(NSRange(location: cursor, length: source.length - cursor)) }

        let blocks = parsedSource.blocks
        let displayBlocks = blocks.flatMap { block in
            sourceSegments.compactMap { segment -> ArticleTextBlock? in
                let intersection = NSIntersectionRange(block.range, segment.articleRange)
                guard intersection.length > 0 else { return nil }
                let range = NSRange(location: segment.displayRange.location + intersection.location - segment.articleRange.location,
                                    length: intersection.length)
                return ArticleTextBlock(range: range, kind: block.kind)
            }
        }
        styleReaderParagraphs(text, title: article.title, blocks: displayBlocks,
                              readingStyle: readingStyle, typography: typography)
        let displayStyles = parsedSource.inlineStyles.flatMap { style in
            sourceSegments.compactMap { segment -> ArticleInlineStyle? in
                let intersection = NSIntersectionRange(style.range, segment.articleRange)
                guard intersection.length > 0 else { return nil }
                let range = NSRange(location: segment.displayRange.location + intersection.location - segment.articleRange.location,
                                    length: intersection.length)
                return ArticleInlineStyle(range: range, kind: style.kind)
            }
        }
        styleReaderInline(text, styles: displayStyles, readingStyle: readingStyle, typography: typography)
        for card in cards {
            guard let sourceRange = intensiveScalarRange(start: card.start, end: card.end,
                                                         in: article.text) else { continue }
            for displayRange in displayRanges(forArticleRange: sourceRange, in: sourceSegments) {
                text.addAttributes([.backgroundColor: readingStyle.readerHighlight,
                                    .underlineStyle: NSUnderlineStyle.single.rawValue,
                                    .underlineColor: readingStyle.readerAccent.withAlphaComponent(0.65)],
                                   range: displayRange)
            }
        }
        return IntensiveRenderDocument(attributedText: text, alignments: alignments,
                                       sourceSegments: sourceSegments, articleText: article.text)
    }

}

private struct IntensiveArticleTextView: NSViewRepresentable {
    let article: LibraryArticle
    fileprivate let sentences: [IntensiveSentence]
    let translations: [Int: IntensiveReadingTranslation]
    let cards: [StudyCard]
    let store: ReadingLibraryStore
    let aiSettings: AISettingsStore
    let supportsSystemTranslation: Bool
    let onOpenAISettings: () -> Void
    let onTranslate: (String, UnitPoint) -> Void
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
    let onShowFind: () -> Void
    let onCloseFind: () -> Bool
    let onExitDistractionFree: (() -> Void)?
    let onFind: (Int) -> Void
    let onReadOffset: (Int) -> Void
    let onReadingProgress: (Double) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = !isDistractionFree
        scrollView.hasHorizontalScroller = false
        scrollView.horizontalScrollElasticity = .none
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = readingStyle.readerBackground
        scrollView.contentView.postsBoundsChangedNotifications = true

        let textView = IntensiveAlignmentTextView(frame: .zero)
        textView.layoutManager?.allowsNonContiguousLayout = true
        textView.identifier = ReaderTextViewIdentity.intensive
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.allowsUndo = false
        textView.drawsBackground = false
        textView.usesFindPanel = false
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.containerSize = NSSize(width: 820, height: CGFloat.greatestFiniteMagnitude)
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        scrollView.documentView = textView
        context.coordinator.textView = textView
        context.coordinator.scrollView = scrollView
        textView.onShowFind = onShowFind
        textView.onCloseFind = onCloseFind
        textView.onFind = onFind
        textView.onExitDistractionFree = onExitDistractionFree
        textView.supportsSystemTranslation = supportsSystemTranslation
        textView.onCardClick = { [weak coordinator = context.coordinator] card, range in
            coordinator?.editCard(card, displayRange: range)
        }
        textView.onAskAI = { [weak coordinator = context.coordinator] range in coordinator?.askAI(for: range) }
        textView.onCreateCard = { [weak coordinator = context.coordinator] range in coordinator?.presentCardEditor(for: range) }
        textView.onTranslate = { [weak coordinator = context.coordinator] range in coordinator?.translate(range) }
        context.coordinator.article = article
        context.coordinator.libraryStore = store
        context.coordinator.aiSettings = aiSettings
        context.coordinator.onOpenAISettings = onOpenAISettings
        context.coordinator.onTranslate = onTranslate
        context.coordinator.supportsSystemTranslation = supportsSystemTranslation
        context.coordinator.installFindKeyMonitor()
        context.coordinator.installScrollObserver()
        context.coordinator.update(article: article, sentences: sentences, translations: translations,
                                  cards: cards,
                                  initialOffset: initialOffset, readingStyle: readingStyle,
                                  typography: typography, searchText: searchText,
                                  isDistractionFree: isDistractionFree)
        context.coordinator.onReadOffset = onReadOffset
        context.coordinator.onReadingProgress = onReadingProgress
        context.coordinator.onShowFind = onShowFind
        context.coordinator.onCloseFind = onCloseFind
        context.coordinator.onExitDistractionFree = onExitDistractionFree
        context.coordinator.onFind = onFind
        context.coordinator.isShowingFind = isShowingFind
        context.coordinator.lastReaderFocusRequest = readerFocusRequest
        context.coordinator.revealSource(sourceReveal)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.onReadOffset = onReadOffset
        coordinator.onReadingProgress = onReadingProgress
        coordinator.onShowFind = onShowFind
        coordinator.onCloseFind = onCloseFind
        coordinator.onExitDistractionFree = onExitDistractionFree
        coordinator.onFind = onFind
        coordinator.isShowingFind = isShowingFind
        coordinator.article = article
        coordinator.libraryStore = store
        coordinator.aiSettings = aiSettings
        coordinator.onOpenAISettings = onOpenAISettings
        coordinator.onTranslate = onTranslate
        coordinator.supportsSystemTranslation = supportsSystemTranslation
        coordinator.textView?.onShowFind = onShowFind
        coordinator.textView?.onCloseFind = onCloseFind
        coordinator.textView?.onFind = onFind
        coordinator.textView?.onExitDistractionFree = onExitDistractionFree
        coordinator.textView?.supportsSystemTranslation = supportsSystemTranslation
        coordinator.textView?.onCardClick = { [weak coordinator] card, range in
            coordinator?.editCard(card, displayRange: range)
        }
        coordinator.textView?.onAskAI = { [weak coordinator] range in coordinator?.askAI(for: range) }
        coordinator.textView?.onCreateCard = { [weak coordinator] range in coordinator?.presentCardEditor(for: range) }
        coordinator.textView?.onTranslate = { [weak coordinator] range in coordinator?.translate(range) }
        scrollView.hasVerticalScroller = !isDistractionFree
        coordinator.update(article: article, sentences: sentences, translations: translations,
                           cards: cards,
                           initialOffset: initialOffset, readingStyle: readingStyle,
                           typography: typography, searchText: searchText,
                           isDistractionFree: isDistractionFree)
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
        coordinator.textView?.clearHighlights()
        coordinator.textView?.clearSourceReveal()
    }

    @MainActor
    final class Coordinator: NSObject, NSPopoverDelegate {
        weak var textView: IntensiveAlignmentTextView?
        weak var scrollView: NSScrollView?
        var onReadOffset: ((Int) -> Void)?
        var onReadingProgress: ((Double) -> Void)?
        var article: LibraryArticle?
        weak var libraryStore: ReadingLibraryStore?
        var aiSettings: AISettingsStore?
        var onOpenAISettings: (() -> Void)?
        var onTranslate: ((String, UnitPoint) -> Void)?
        var supportsSystemTranslation = false
        var onShowFind: (() -> Void)?
        var onCloseFind: (() -> Bool)?
        var onExitDistractionFree: (() -> Void)?
        var onFind: ((Int) -> Void)?
        var isShowingFind = false
        var lastSearchRequest = 0
        var lastReaderFocusRequest = 0
        private var explanationPopover: NSPopover?
        private var explanationModel: AIExplanationModel?
        private var editorPopover: NSPopover?
        private var activeEditorKey: EditorKey?
        private var editorSessions: [EditorKey: CardEditorSession] = [:]
        private var findKeyMonitor: Any?

        private struct EditorKey: Hashable {
            let location: Int
            let length: Int
            let cardID: UUID?
        }

        private var document: IntensiveRenderDocument?
        private let documentRenderer = IntensiveDocumentRenderer()
        private var renderedSearch = ""
        private var renderedStyle: ReadingViewStyle?
        private var renderedTypography: ReadingTypography?
        private var renderedMetadata: ArticleMetadata?
        private var renderedBylineTitle: String?
        private var renderedDistractionFree: Bool?
        private var scrollObserver: NSObjectProtocol?
        private var saveWork: DispatchWorkItem?
        private var restoredInitialPosition = false
        private var lastSourceRevealID: UUID?
        private var currentArticle: LibraryArticle?

        func installScrollObserver() {
            guard scrollObserver == nil, let clip = scrollView?.contentView else { return }
            scrollObserver = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification, object: clip, queue: .main
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
            saveWork?.cancel()
        }

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

        func editCard(_ card: StudyCard, displayRange: NSRange) {
            guard let article,
                  let sourceRange = intensiveScalarRange(start: card.start, end: card.end, in: article.text) else { return }
            presentCardEditor(for: displayRange, sourceRange: sourceRange, existingCard: card)
        }

        func presentCardEditor(for displayRange: NSRange) {
            guard let document, let sourceRange = document.articleRange(forDisplayRange: displayRange) else { return }
            presentCardEditor(for: displayRange, sourceRange: sourceRange, existingCard: nil)
        }

        private func presentCardEditor(for displayRange: NSRange, sourceRange: NSRange,
                                       existingCard: StudyCard?) {
            guard let textView, textView.window != nil, let article,
                  let document, document.articleText == article.text,
                  let libraryStore, let aiSettings,
                  displayRange.location >= 0, displayRange.length > 0,
                  NSMaxRange(displayRange) <= (textView.string as NSString).length,
                  sourceRange.location >= 0, sourceRange.length > 0,
                  NSMaxRange(sourceRange) <= (article.text as NSString).length else { return }
            closeExplanation()
            closeCardEditor()
            let key = EditorKey(location: sourceRange.location, length: sourceRange.length,
                                cardID: existingCard?.id)
            let session = editorSessions[key] ?? CardEditorSession(
                article: article, selectedRange: sourceRange, existingCard: existingCard,
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
            textView.setSelectedRange(displayRange)
            popover.show(relativeTo: anchor(for: displayRange, in: textView), of: textView, preferredEdge: .maxY)
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
            guard let layout = textView.layoutManager, let container = textView.textContainer else { return fallback }
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

        func translate(_ displayRange: NSRange) {
            guard supportsSystemTranslation, let textView, let document, let article,
                  let sourceRange = document.articleRange(forDisplayRange: displayRange) else { return }
            let selectedText = (article.text as NSString).substring(with: sourceRange)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !selectedText.isEmpty else { return }
            closeCardEditor()
            closeExplanation()
            let selectionRect = anchor(for: displayRange, in: textView)
            let bounds = scrollView?.bounds ?? .zero
            let point = scrollView?.convert(NSPoint(x: selectionRect.midX, y: selectionRect.midY), from: textView)
            let anchor: UnitPoint
            if let point, bounds.width > 0, bounds.height > 0 {
                anchor = UnitPoint(x: min(max(point.x / bounds.width, 0), 1),
                                   y: 1 - min(max(point.y / bounds.height, 0), 1))
            } else {
                anchor = UnitPoint(x: 0.5, y: 0.5)
            }
            onTranslate?(selectedText, anchor)
        }

        func askAI(for displayRange: NSRange) {
            guard let document, let article, let aiSettings, let libraryStore,
                  let sourceRange = document.articleRange(forDisplayRange: displayRange) else { return }
            let selection: SelectionContext
            do {
                selection = try SelectionContext.extract(from: article.text, range: sourceRange,
                                                         articleTitle: article.title)
            } catch {
                if let window = textView?.window {
                    let alert = NSAlert(error: error)
                    alert.buttons.first?.title = L("好", "OK")
                    alert.beginSheetModal(for: window)
                }
                return
            }
            closeCardEditor()
            closeExplanation()
            let model = AIExplanationModel(selection: selection, article: article,
                                           sourceRange: sourceRange, store: libraryStore)
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
            textView?.setSelectedRange(displayRange)
            if let textView {
                popover.show(relativeTo: anchor(for: displayRange, in: textView), of: textView, preferredEdge: .maxY)
            }
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

        func update(article: LibraryArticle, sentences: [IntensiveSentence],
                    translations: [Int: IntensiveReadingTranslation], cards: [StudyCard], initialOffset: Int,
                    readingStyle: ReadingViewStyle, typography: ReadingTypography,
                    searchText: String, isDistractionFree: Bool) {
            guard let textView, let scrollView else { return }
            currentArticle = article
            let nextDocument = documentRenderer.document(article: article, sentences: sentences,
                                                         translations: translations, cards: cards,
                                                         readingStyle: readingStyle, typography: typography,
                                                         waitingText: L("正在等待译文…", "Waiting for translation…"))
            let styleChanged = renderedStyle != readingStyle
            let typographyChanged = renderedTypography != typography
            let metadata = documentRenderer.metadata
            let metadataChanged = renderedMetadata != metadata
            let bylineChanged = renderedBylineTitle != article.title || metadataChanged ||
                styleChanged || typographyChanged
            let reusesDocument = document?.attributedText === nextDocument.attributedText
            let contentChanged = !reusesDocument &&
                document?.attributedText.isEqual(to: nextDocument.attributedText) != true
            let oldAnchor = contentChanged || metadataChanged ? currentSourceScalarOffset() : nil

            if styleChanged {
                textView.readingStyle = readingStyle
                textView.linkTextAttributes = readerLinkAttributes(readingStyle: readingStyle)
                scrollView.backgroundColor = readingStyle.readerBackground
            }
            if styleChanged || typographyChanged {
                textView.typography = typography
                textView.updateReadingMargins()
            }
            if renderedDistractionFree != isDistractionFree {
                scrollView.hasVerticalScroller = !isDistractionFree
                renderedDistractionFree = isDistractionFree
            }
            renderedBylineTitle = article.title
            renderedStyle = readingStyle
            renderedTypography = typography
            renderedMetadata = metadata

            if reusesDocument {
                if bylineChanged {
                    textView.configureByline(title: article.title, metadata: metadata)
                }
                if renderedSearch != searchText {
                    textView.searchRanges = Self.ranges(of: searchText, in: textView.string)
                    renderedSearch = searchText
                    textView.needsDisplay = true
                }
                return
            }
            if contentChanged {
                textView.textColor = readingStyle.readerForeground
                textView.clearHighlights()
                textView.textStorage?.setAttributedString(nextDocument.attributedText)
                document = nextDocument
                textView.configureByline(title: article.title, metadata: metadata)
                if let oldAnchor {
                    scroll(toScalarOffset: oldAnchor)
                } else if !restoredInitialPosition {
                    restoredInitialPosition = true
                    scroll(toScalarOffset: initialOffset)
                }
            } else {
                document = nextDocument
                if bylineChanged {
                    textView.configureByline(title: article.title, metadata: metadata)
                }
                if metadataChanged, let oldAnchor { scroll(toScalarOffset: oldAnchor) }
            }
            renderedSearch = searchText
            textView.searchRanges = Self.ranges(of: searchText, in: textView.string)
            textView.articleText = article.text
            textView.mapSelectionToSource = { [weak self] range in
                self?.document?.articleRange(forDisplayRange: range)
            }
            textView.sourceDisplayRangeForSelection = { [weak self] range in
                self?.document?.sourceDisplayRange(forDisplayRange: range)
            }
            textView.cardRanges = cards.reduce(into: [(NSRange, StudyCard)]()) { ranges, card in
                guard let range = intensiveScalarRange(start: card.start, end: card.end, in: article.text) else { return }
                ranges.append(contentsOf: nextDocument.displayRanges(forArticleRange: range).map { ($0, card) })
            }
            textView.onHoverCharacter = { [weak self, weak textView] index in
                guard let self, let textView, let index, let document = self.document else {
                    textView?.clearHighlights()
                    return
                }
                let matching = document.alignments.filter { alignment in
                    alignment.sourceRanges.contains(where: { $0.contains(index) })
                }
                textView.setHighlights(matching.flatMap { $0.sourceRanges + $0.targetRanges }.map(\.range))
            }
            textView.needsDisplay = true
            reportReadingProgress()
        }

        func revealSource(_ request: ReaderSourceReveal?) {
            guard let request, lastSourceRevealID != request.id, let article = currentArticle,
                  let range = request.range(in: article), let textView,
                  let document else { return }
            lastSourceRevealID = request.id
            let scalarStart = (article.text as NSString).substring(to: range.location).unicodeScalars.count
            scroll(toScalarOffset: scalarStart, in: document)
            if let segment = document.sourceSegments.first(where: {
                NSIntersectionRange($0.articleRange, range).length > 0
            }) {
                let intersection = NSIntersectionRange(segment.articleRange, range)
                let displayRange = NSRange(location: segment.displayRange.location + intersection.location - segment.articleRange.location,
                                           length: intersection.length)
                textView.revealSource(displayRange)
            }
        }

        func find(_ query: String, direction: Int) {
            guard let textView, !query.isEmpty else { return }
            let source = textView.string as NSString
            let options: NSString.CompareOptions = [.caseInsensitive]
            let selection = textView.selectedRange()
            let found: NSRange
            if direction >= 0 {
                let start = selection.length > 0 ? NSMaxRange(selection) : selection.location
                let first = source.range(of: query, options: options,
                                         range: NSRange(location: min(start, source.length), length: max(0, source.length - min(start, source.length))))
                found = first.location == NSNotFound ? source.range(of: query, options: options) : first
            } else {
                let start = selection.location
                let first = start > 0 ? source.range(of: query, options: options.union(.backwards),
                                                      range: NSRange(location: 0, length: start)) : NSRange(location: NSNotFound, length: 0)
                found = first.location == NSNotFound ? source.range(of: query, options: options.union(.backwards)) : first
            }
            guard found.location != NSNotFound else { return }
            textView.setSelectedRange(found)
            textView.scrollRangeToVisible(found)
        }

        private func scheduleReadOffsetSave() {
            saveWork?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.flushReadOffset() }
            saveWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: work)
        }

        func flushReadOffset() {
            saveWork?.cancel()
            if let offset = currentSourceScalarOffset() { onReadOffset?(offset) }
        }

        private func currentSourceScalarOffset() -> Int? {
            guard let textView, let document, let scrollView else { return nil }
            let visible = scrollView.contentView.bounds
            let point = NSPoint(x: textView.textContainerOrigin.x + 2,
                                y: visible.minY + textView.textContainerInset.height + 4)
            let location = max(0, min(textView.characterIndexForInsertion(at: point), (textView.string as NSString).length))
            let candidate = document.sourceSegments.last(where: { $0.displayRange.location <= location })
                ?? document.sourceSegments.first
            guard let candidate else { return articleScalarCount(document.articleText) }
            let displayDelta = max(0, min(location - candidate.displayRange.location, candidate.articleRange.length))
            let articleOffset = candidate.articleRange.location + displayDelta
            return articleScalarCount((document.articleText as NSString).substring(to: articleOffset))
        }

        private func scroll(toScalarOffset offset: Int) {
            guard let document else { return }
            scroll(toScalarOffset: offset, in: document)
        }

        private func scroll(toScalarOffset offset: Int, in document: IntensiveRenderDocument) {
            guard let textView else { return }
            let clamped = max(0, min(offset, document.articleText.unicodeScalars.count))
            let articleOffset = utf16Offset(forScalar: clamped, in: document.articleText)
            let segment = document.sourceSegments.first(where: {
                $0.articleRange.location <= articleOffset && articleOffset < NSMaxRange($0.articleRange)
            }) ?? document.sourceSegments.first(where: { $0.articleRange.location >= articleOffset })
            if let segment {
                let delta = max(0, min(articleOffset - segment.articleRange.location, segment.displayRange.length))
                textView.scrollRangeToVisible(NSRange(location: segment.displayRange.location + delta, length: 0))
            }
        }

        private func reportReadingProgress() {
            guard let scrollView, let textView else { return }
            let distance = max(0, textView.bounds.height - scrollView.contentView.bounds.height)
            let progress = distance > 0 ? min(1, max(0, scrollView.contentView.bounds.minY / distance)) : 1
            DispatchQueue.main.async { [weak self] in self?.onReadingProgress?(progress) }
        }

        private static func ranges(of query: String, in text: String) -> [NSRange] {
            guard !query.isEmpty else { return [] }
            let source = text as NSString
            var ranges: [NSRange] = []
            var search = NSRange(location: 0, length: source.length)
            while search.length > 0 {
                let found = source.range(of: query, options: [.caseInsensitive], range: search)
                guard found.location != NSNotFound else { break }
                ranges.append(found)
                let next = NSMaxRange(found)
                search = NSRange(location: next, length: source.length - next)
            }
            return ranges
        }
    }
}

private func articleScalarCount(_ text: String) -> Int { text.unicodeScalars.count }

private func intensiveScalarRange(start: Int, end: Int, in text: String) -> NSRange? {
    guard start >= 0, end > start, end <= text.unicodeScalars.count else { return nil }
    let lower = text.unicodeScalars.index(text.unicodeScalars.startIndex, offsetBy: start)
    let upper = text.unicodeScalars.index(text.unicodeScalars.startIndex, offsetBy: end)
    guard let lowerIndex = String.Index(lower, within: text),
          let upperIndex = String.Index(upper, within: text) else { return nil }
    return NSRange(lowerIndex..<upperIndex, in: text)
}

private func displayRanges(forArticleRange range: NSRange,
                           in segments: [IntensiveDocumentSegment]) -> [NSRange] {
    segments.compactMap { segment in
        let intersection = NSIntersectionRange(range, segment.articleRange)
        guard intersection.length > 0 else { return nil }
        return NSRange(location: segment.displayRange.location + intersection.location - segment.articleRange.location,
                      length: intersection.length)
    }
}

private func utf16Offset(forScalar offset: Int, in text: String) -> Int {
    let scalars = text.unicodeScalars
    let index = scalars.index(scalars.startIndex, offsetBy: min(max(offset, 0), scalars.count))
    return text[..<index].utf16.count
}

private final class IntensiveAlignmentTextView: NSTextView {
    private let articleByline = ReaderArticleByline()
    private var isUpdatingReadingMargins = false
    var readingStyle: ReadingViewStyle = .standard
    var typography = ReadingViewStyle.standard.defaultTypography
    var onHoverCharacter: ((Int?) -> Void)?
    var cardRanges: [(NSRange, StudyCard)] = []
    var onCardClick: ((StudyCard, NSRange) -> Void)?
    var onAskAI: ((NSRange) -> Void)?
    var onCreateCard: ((NSRange) -> Void)?
    var onTranslate: ((NSRange) -> Void)?
    var mapSelectionToSource: ((NSRange) -> NSRange?)?
    var sourceDisplayRangeForSelection: ((NSRange) -> NSRange?)?
    var articleText: String?
    var supportsSystemTranslation = false
    var onShowFind: (() -> Void)?
    var onCloseFind: (() -> Bool)?
    var onFind: ((Int) -> Void)?
    var onExitDistractionFree: (() -> Void)?
    var searchRanges: [NSRange] = [] { didSet { needsDisplay = true } }
    private var trackingArea: NSTrackingArea?
    private var highlightedRanges: [NSRange] = []
    private var sourceRevealRange: NSRange?
    private var sourceRevealStartedAt: TimeInterval?
    private var sourceRevealTimer: Timer?
    private var contextSelection = NSRange(location: 0, length: 0)

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        trackingArea = NSTrackingArea(rect: .zero, options: [.activeInKeyWindow, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect],
                                      owner: self, userInfo: nil)
        addTrackingArea(trackingArea!)
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let index = characterIndexForInsertion(at: point)
        onHoverCharacter?(index < (string as NSString).length ? index : nil)
    }

    override func mouseExited(with event: NSEvent) { onHoverCharacter?(nil) }

    func setHighlights(_ ranges: [NSRange]) {
        guard let layoutManager else { return }
        for range in highlightedRanges {
            layoutManager.removeTemporaryAttribute(.backgroundColor, forCharacterRange: range)
        }
        highlightedRanges = IntensiveReadingHighlightRanges.mergingWhitespaceSeparated(ranges, in: string)
        for range in highlightedRanges {
            layoutManager.addTemporaryAttribute(.backgroundColor,
                                                value: readingStyle.readerAlignmentHighlight,
                                                forCharacterRange: range)
        }
    }

    func clearHighlights() { setHighlights([]) }

    func resetCapturedSelection() {
        contextSelection = NSRange(location: 0, length: 0)
    }

    func clearSourceReveal() {
        sourceRevealTimer?.invalidate()
        sourceRevealTimer = nil
        sourceRevealRange = nil
        sourceRevealStartedAt = nil
        needsDisplay = true
    }

    func revealSource(_ range: NSRange) {
        clearSourceReveal()
        sourceRevealRange = range
        sourceRevealStartedAt = ProcessInfo.processInfo.systemUptime
        needsDisplay = true
        sourceRevealTimer = Timer.scheduledTimer(withTimeInterval: 0.9, repeats: false) { [weak self] _ in
            self?.clearSourceReveal()
        }
    }

    func configureByline(title: String, metadata: ArticleMetadata) {
        articleByline.update(in: self, title: title, metadata: metadata,
                             readingStyle: readingStyle, typography: typography)
    }

    private lazy var splitReflow = ReaderSplitReflowController(textView: self) { [weak self] lockedWidth, crossfade in
        self?.applyDeferredSplitFlush(lockedWidth: lockedWidth, crossfade: crossfade)
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        splitReflow.willMove(toWindow: newWindow)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        splitReflow.didMoveToWindow()
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
        ReaderSplitReflowController.applyCrossfadeIfNeeded(to: self, enabled: crossfade && widthChanged)
        updateReadingMargins()
    }

    private func readingHorizontalInset(for width: CGFloat, targetWidth: CGFloat = 820) -> CGFloat {
        max(CGFloat(typography.sideInset), (width - targetWidth) / 2)
    }

    private func readingTextWidth(for width: CGFloat) -> CGFloat {
        max(1, width - 2 * readingHorizontalInset(for: width))
    }

    func updateReadingMargins() {
        guard !isUpdatingReadingMargins else { return }
        isUpdatingReadingMargins = true
        defer { isUpdatingReadingMargins = false }
        let targetWidth = splitReflow.deferredTextWidth ?? 820
        let inset = readingHorizontalInset(for: bounds.width, targetWidth: targetWidth)
        let nextInset = NSSize(width: inset, height: readingStyle.readerVerticalInset)
        if textContainerInset != nextInset { textContainerInset = nextInset }
        if let textContainer {
            if let deferredWidth = splitReflow.deferredTextWidth {
                if textContainer.widthTracksTextView { textContainer.widthTracksTextView = false }
                if abs(textContainer.containerSize.width - deferredWidth) > 0.5 {
                    textContainer.containerSize = NSSize(width: deferredWidth, height: CGFloat.greatestFiniteMagnitude)
                }
                return
            }
            let textWidth = max(1, bounds.width - 2 * inset)
            let isCapped = textWidth >= 820 - 0.5
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

    func focusPreservingReadingPosition() {
        window?.makeFirstResponder(self)
    }

    override func becomeFirstResponder() -> Bool {
        let clip = enclosingScrollView?.contentView
        let origin = clip?.bounds.origin
        let accepted = super.becomeFirstResponder()
        if let clip, let origin, clip.bounds.origin != origin {
            clip.scroll(to: origin)
            enclosingScrollView?.reflectScrolledClipView(clip)
        }
        return accepted
    }

    override func setFrameSize(_ newSize: NSSize) {
        let newTextWidth = readingTextWidth(for: newSize.width)
        let currentWidth = textContainer?.containerSize.width ?? readingTextWidth(for: frame.width)
        let utf16Length = textStorage?.length ?? 0
        if splitReflow.shouldDeferReflow(newTextWidth: newTextWidth,
                                         currentWidth: currentWidth,
                                         utf16Length: utf16Length),
           let textContainer {
            splitReflow.beginOrContinueDeferral(currentContainerWidth: textContainer.containerSize.width)
            if textContainer.widthTracksTextView { textContainer.widthTracksTextView = false }
            super.setFrameSize(newSize)
            updateReadingMargins()
            return
        }
        splitReflow.clearPendingDeferral()
        let nextInset = NSSize(width: readingHorizontalInset(for: newSize.width),
                               height: readingStyle.readerVerticalInset)
        if textContainerInset != nextInset { textContainerInset = nextInset }
        if let textContainer {
            let widthChanges = abs(newTextWidth - readingTextWidth(for: frame.width)) > 0.5
            let isCappedAndUnchanged = !widthChanges
                && newTextWidth >= 820 - 0.5
                && abs(textContainer.containerSize.width - newTextWidth) <= 0.5
            let shouldTrack = !isCappedAndUnchanged
            if textContainer.widthTracksTextView != shouldTrack {
                textContainer.widthTracksTextView = shouldTrack
            }
        }
        super.setFrameSize(newSize)
        updateReadingMargins()
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            .subtracting([.capsLock, .numericPad, .function])
        if modifiers == .command, event.charactersIgnoringModifiers?.lowercased() == "f", let onShowFind {
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
        let mapped = mapSelectionToSource?(contextSelection)
        let valid = mapped.flatMap { range -> String? in
            guard let articleText,
                  range.location >= 0, range.length > 0,
                  NSMaxRange(range) <= (articleText as NSString).length else { return nil }
            return (articleText as NSString).substring(with: range)
        }?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false

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
        item(L("查询词典", "Look up in Dictionary"), #selector(lookUpFromMenu(_:)),
             enabled: valid && sourceDisplayRangeForSelection?(contextSelection) != nil)
        item(L("翻译", "Translate"), #selector(translateFromMenu(_:)),
             enabled: valid && supportsSystemTranslation)
        item(L("询问AI", "Ask AI"), #selector(askAIFromMenu(_:)), enabled: valid)
        menu.addItem(.separator())
        item(L("复制", "Copy"), #selector(NSText.copy(_:)), enabled: contextSelection.length > 0)
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

    @objc private func askAIFromMenu(_ sender: Any?) {
        guard let selection = restoreContextSelection() else { return }
        onAskAI?(selection)
    }

    @objc private func createCardFromMenu(_ sender: Any?) {
        guard let selection = restoreContextSelection() else { return }
        onCreateCard?(selection)
    }

    @objc private func lookUpFromMenu(_ sender: Any?) {
        guard let selection = sourceDisplayRangeForSelection?(contextSelection) else { return }
        window?.makeFirstResponder(self)
        setSelectedRange(selection)
        showDefinition(for: nil, range: selection,
                       options: [.presentationType: NSView.DefinitionPresentationType.overlay],
                       baselineOriginProvider: nil)
    }

    @objc private func translateFromMenu(_ sender: Any?) {
        guard supportsSystemTranslation, let selection = restoreContextSelection() else { return }
        onTranslate?(selection)
    }

    @objc private func exitDistractionFree(_ sender: Any?) {
        onExitDistractionFree?()
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
        if event.clickCount >= 1 {
            let point = convert(event.locationInWindow, from: nil)
            let location = characterIndexForInsertion(at: point)
            if let (range, card) = cardRanges.first(where: { NSLocationInRange(location, $0.0) }) {
                onCardClick?(card, range)
                return
            }
        }
        super.mouseDown(with: event)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let layoutManager, let textContainer else { super.draw(dirtyRect); return }
        for range in searchRanges where NSMaxRange(range) <= (string as NSString).length {
            NSColor.systemGreen.withAlphaComponent(0.23).setFill()
            for rect in ReaderSourceReveal.lineRects(for: range, layoutManager: layoutManager,
                                                     textContainer: textContainer, origin: textContainerOrigin)
                where dirtyRect.intersects(rect) { rect.fill() }
        }
        if let range = sourceRevealRange, NSMaxRange(range) <= (string as NSString).length {
            readingStyle.readerAccent.withAlphaComponent(0.18).setFill()
            for rect in ReaderSourceReveal.lineRects(for: range, layoutManager: layoutManager,
                                                     textContainer: textContainer, origin: textContainerOrigin)
                where dirtyRect.intersects(rect) { rect.fill() }
        }
        super.draw(dirtyRect)
    }

}
