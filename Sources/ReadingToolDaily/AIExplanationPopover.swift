import AppKit
import Combine
import SwiftUI

/// One explanation belongs to one captured selection. Closing it cancels its request.
@MainActor
final class AIExplanationModel: ObservableObject {
    enum HighlightState: Equatable {
        case hidden
        case unavailable
        case available
        case added
        case overlapping
    }

    enum Phase {
        case loading
        case needsConfiguration(String)
        case failed(AIUsageIssue)
        case explained(String)
    }

    let selection: SelectionContext
    let purpose: AIExplanationPurpose
    @Published private(set) var phase: Phase = .loading
    @Published private(set) var highlightState: HighlightState = .hidden
    @Published private(set) var highlightError: String?
    private let article: LibraryArticle?
    private let sourceRange: NSRange?
    private let store: ReadingLibraryStore?
    private let profileID: UUID?
    private var task: Task<Void, Never>?
    private var requestID: UUID?
    private var configurationObserver: AnyCancellable?
    private var archiveObserver: AnyCancellable?

    init(selection: SelectionContext) {
        self.selection = selection
        purpose = selection.askAIPurpose
        article = nil
        sourceRange = nil
        store = nil
        profileID = nil
    }

    init(selection: SelectionContext, article: LibraryArticle, sourceRange: NSRange,
         store: ReadingLibraryStore) {
        self.selection = selection
        purpose = selection.askAIPurpose
        self.article = article
        self.sourceRange = sourceRange
        self.store = store
        profileID = store.activeProfileID
        if purpose == .lookup {
            archiveObserver = store.$archive.dropFirst().sink { [weak self] _ in
                DispatchQueue.main.async { self?.refreshHighlightState() }
            }
        }
        refreshHighlightState()
    }

    var canAddHighlight: Bool {
        guard highlightState == .available,
              case .explained = phase,
              meaningToSave != nil else { return false }
        return true
    }

    var meaningToSave: String? {
        guard case .explained(let explanation) = phase else { return nil }
        return explanation.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty })
    }

    func addHighlight() {
        guard canAddHighlight, let article, let sourceRange, let store,
              store.activeProfileID == profileID,
              let currentArticle = store.articles.first(where: { $0.id == article.id }),
              currentArticle.text == article.text,
              let expression = sourceText(in: article.text, range: sourceRange),
              let meaning = meaningToSave else { return }
        highlightError = nil
        do {
            switch try store.cardSelectionStatus(articleID: article.id, range: sourceRange) {
            case .existing:
                highlightState = .added
                return
            case .overlapping:
                highlightState = .overlapping
                return
            case .available:
                break
            }
            _ = try store.saveCard(articleID: article.id, range: sourceRange,
                                   expression: expression.trimmingCharacters(in: .whitespacesAndNewlines),
                                   meaning: meaning)
            highlightError = nil
            highlightState = .added
        } catch {
            highlightError = error.localizedDescription
            refreshHighlightState()
        }
    }

    func start(settings: AISettingsStore) {
        cancel()
        // A lookup starts only after an explicit Ask AI or Retry action.
        settings.resetUsageBlock()
        guard settings.isAIConfigured else {
            presentConfigurationIssue(settings)
            return
        }
        phase = .loading
        let id = UUID()
        requestID = id
        let identity = settings.activeAIIdentity
        let revision = settings.configurationRevision
        configurationObserver = settings.$configurationRevision.dropFirst().sink { [weak self, weak settings] _ in
            guard let self, let settings, self.requestID == id else { return }
            self.configurationChanged(settings: settings)
        }
        let selection = selection
        let purpose = purpose
        let context = purpose == .translation ? selection.translationContext : selection.context
        let focusedSentence = purpose == .translation ? nil : selection.focusedSentence
        task = Task { [weak self] in
            do {
                let explanation = try await settings.explain(
                    selection: selection.selectedText, context: context,
                    focusedSentence: focusedSentence, purpose: purpose
                )
                try Task.checkCancellation()
                guard let self, self.requestID == id else { return }
                guard settings.activeAIIdentity == identity, settings.configurationRevision == revision else {
                    self.configurationChanged(settings: settings)
                    return
                }
                self.phase = .explained(explanation)
                self.refreshHighlightState()
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
                    self.phase = .failed(.configurationChanged)
                } else {
                    self.phase = .failed(settings.selectedService == .chatGPT ? .chatGPT(.interrupted) : .configurationChanged)
                }
            } catch {
                guard let self, self.requestID == id else { return }
                guard settings.activeAIIdentity == identity, settings.configurationRevision == revision else {
                    self.configurationChanged(settings: settings)
                    return
                }
                self.phase = .failed(AIUsageIssue.from(error))
                self.requestID = nil
                self.task = nil
                self.configurationObserver = nil
            }
        }
    }

    func cancel() {
        requestID = nil
        task?.cancel()
        task = nil
        configurationObserver = nil
    }

    private func refreshHighlightState() {
        guard purpose == .lookup, let article, let sourceRange, let store else {
            highlightState = .hidden
            return
        }
        guard store.activeProfileID == profileID,
              let currentArticle = store.articles.first(where: { $0.id == article.id }),
              currentArticle.text == article.text else {
            highlightState = .unavailable
            return
        }
        do {
            switch try store.cardSelectionStatus(articleID: article.id, range: sourceRange) {
            case .available:
                highlightState = .available
            case .existing:
                highlightState = .added
            case .overlapping:
                highlightState = .overlapping
            }
        } catch {
            highlightState = .unavailable
        }
    }

    private func sourceText(in text: String, range: NSRange) -> String? {
        let source = text as NSString
        guard range.location != NSNotFound, range.location >= 0,
              range.length > 0, range.location <= source.length,
              range.length <= source.length - range.location,
              Range(range, in: text) != nil else { return nil }
        return source.substring(with: range)
    }

    private func configurationChanged(settings: AISettingsStore) {
        cancel()
        if settings.isAIConfigured { phase = .failed(.configurationChanged) }
        else { presentConfigurationIssue(settings) }
    }

    private func presentConfigurationIssue(_ settings: AISettingsStore) {
        if let issue = settings.aiConfigurationIssue, !issue.isMissingConfiguration {
            phase = .failed(issue)
        } else {
            phase = .needsConfiguration(settings.aiConfigurationIssue?.localizedDescription
                ?? L("请先配置 AI，即可使用释义。", "Configure an AI service to use explanations."))
        }
    }
}

struct AIExplanationPopover: View {
    @ObservedObject var model: AIExplanationModel
    let retry: () -> Void
    let openSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 8) {
                BoundedPopoverText(text: model.selection.selectedText, font: .headline, maximumHeight: 84)
                if model.purpose == .lookup {
                    addHighlightButton
                }
            }
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text(model.purpose == .translation ? L("翻译", "Translation") : L("释义", "Meaning"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            switch model.phase {
            case .loading:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(model.purpose == .translation ? L("正在翻译…", "Translating…") : L("正在解释…", "Explaining…"))
                        .foregroundStyle(.secondary)
                }
            case .needsConfiguration(let message):
                BoundedPopoverText(text: message, maximumHeight: 160, color: .secondary)
            case .failed(let issue):
                BoundedPopoverText(text: issue.localizedDescription, maximumHeight: 160, color: .secondary)
            case .explained(let explanation):
                BoundedPopoverText(text: explanation, maximumHeight: 260)
            }
            switch model.phase {
            case .needsConfiguration:
                Button(L("AI 设置…", "AI Settings…"), action: openSettings)
                    .controlSize(.small)
            case .failed(let issue):
                AIUsageRecoveryActions(issue: issue, retry: retry, openSettings: openSettings)
            default:
                EmptyView()
            }
            if let highlightError = model.highlightError {
                BoundedPopoverText(text: highlightError, maximumHeight: 72, color: .red)
            }
        }
        .font(.body)
        .padding(16)
        .frame(width: 340, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var addHighlightButton: some View {
        Button(action: model.addHighlight) {
            Image(systemName: model.highlightState == .added ? "checkmark.circle" : "highlighter")
                .font(.system(size: 15, weight: .regular))
                .foregroundStyle(model.highlightState == .added ? Color.accentColor :
                    model.canAddHighlight ? Color.accentColor : Color.secondary)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!model.canAddHighlight)
        .animation(.snappy(duration: 0.25), value: model.highlightState == .added)
        .help(model.highlightState == .added
            ? L("已添加划记", "Highlight added")
            : L("添加划记", "Add highlight"))
        .accessibilityLabel(model.highlightState == .added
            ? L("已添加划记", "Highlight added")
            : L("添加划记", "Add highlight"))
    }
}

/// Keeps the popover compact for a word and scrollable for a whole passage.
/// The symbol and action row stay outside these independently scrolling areas.
private struct BoundedPopoverText: View {
    let text: String
    var font: Font = .body
    let maximumHeight: CGFloat
    var color: Color = .primary
    @State private var contentHeight: CGFloat = 20

    var body: some View {
        ScrollView(.vertical) {
            Text(text)
                .font(font)
                .foregroundStyle(color)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background {
                    GeometryReader { geometry in
                        Color.clear.preference(key: PopoverTextHeight.self, value: geometry.size.height)
                    }
                }
        }
        .frame(height: min(maximumHeight, max(20, contentHeight)))
        .onPreferenceChange(PopoverTextHeight.self) { contentHeight = $0 }
    }
}

private struct PopoverTextHeight: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
