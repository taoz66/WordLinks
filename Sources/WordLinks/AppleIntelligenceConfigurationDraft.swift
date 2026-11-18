import Combine
import Foundation

/// Device checks and test inference stay separate from the saved service selection.
@MainActor
final class AppleIntelligenceConfigurationDraft: ObservableObject {
    @Published private(set) var availability: AppleIntelligenceAvailability
    @Published private(set) var isChecking = false
    @Published private(set) var isVerified = false
    @Published private(set) var issue: AIUsageIssue?
    @Published private(set) var testState: AIServiceTestState = .idle

    private let settings: AISettingsStore
    private let timeoutNanoseconds: UInt64
    private var verifiedRevision: UInt64?
    private var verifiedLanguage: StudyLanguage?
    private var requestID: UUID?
    private var task: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?

    init(settings: AISettingsStore, timeoutNanoseconds: UInt64 = 60_000_000_000) {
        self.settings = settings
        self.timeoutNanoseconds = timeoutNanoseconds
        availability = settings.appleIntelligence.availability
    }

    var isSaved: Bool { settings.selectedService == .appleIntelligence }
    var hasUnsavedChanges: Bool { !isSaved && (isChecking || isVerified) }
    var canCheck: Bool { availability == .available && !isChecking }
    var canSave: Bool {
        !isSaved && !isChecking && isVerified && issue == nil &&
            verifiedRevision == settings.configurationRevision && verifiedLanguage == settings.studyLanguage &&
            settings.appleIntelligence.availability == .available
    }

    func refreshAvailability() {
        availability = settings.appleIntelligence.availability
        if availability != .available {
            cancelPending()
        }
        if verifiedRevision != settings.configurationRevision || verifiedLanguage != settings.studyLanguage {
            cancelPending()
        }
    }

    func check() {
        cancelPending()
        issue = nil
        refreshAvailability()
        guard canCheck else {
            issue = .appleIntelligence(.unavailable(availability))
            testState = .unavailable
            return
        }
        let id = UUID()
        let revision = settings.configurationRevision
        let language = settings.studyLanguage
        verifiedRevision = revision
        verifiedLanguage = language
        requestID = id
        isChecking = true
        testState = .testing
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let response = try await self.settings.appleIntelligence.explain(
                    selection: "bright", context: "The room is bright.", focusedSentence: "The room is bright.",
                    purpose: .prefill, language: language)
                try Task.checkCancellation()
                guard self.requestID == id else { return }
                guard revision == self.settings.configurationRevision, language == self.settings.studyLanguage else {
                    self.finish(id: id)
                    return
                }
                guard !response.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw AppleIntelligenceError.emptyResponse
                }
                self.availability = self.settings.appleIntelligence.availability
                guard self.availability == .available else {
                    throw AppleIntelligenceError.unavailable(self.availability)
                }
                self.verifiedRevision = revision
                self.verifiedLanguage = language
                self.isVerified = true
                self.testState = .available
                self.finish(id: id)
            } catch {
                guard self.requestID == id else { return }
                guard revision == self.settings.configurationRevision, language == self.settings.studyLanguage else {
                    self.finish(id: id)
                    return
                }
                if !(error is CancellationError) {
                    self.issue = AIUsageIssue.from(error)
                    self.testState = .unavailable
                }
                self.finish(id: id)
            }
        }
        let timeout = timeoutNanoseconds
        timeoutTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: timeout) } catch { return }
            guard let self, self.requestID == id else { return }
            self.cancelPending()
            self.issue = .appleIntelligence(.timedOut)
            self.testState = .unavailable
        }
    }

    @discardableResult
    func save() -> Bool {
        guard canSave else { return false }
        do {
            try settings.selectService(.appleIntelligence)
            verifiedRevision = settings.configurationRevision
            issue = nil
            return true
        } catch {
            issue = AIUsageIssue.from(error)
            return false
        }
    }

    func cancelPending() {
        requestID = nil
        task?.cancel()
        task = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        isChecking = false
        isVerified = false
        testState = .idle
        verifiedRevision = nil
        verifiedLanguage = nil
    }

    private func finish(id: UUID) {
        guard requestID == id else { return }
        requestID = nil
        isChecking = false
        task = nil
        timeoutTask?.cancel()
        timeoutTask = nil
    }
}
