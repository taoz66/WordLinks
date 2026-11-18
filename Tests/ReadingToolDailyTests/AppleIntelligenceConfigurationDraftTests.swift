import Combine
import Foundation
import XCTest
@testable import ReadingToolDaily

@MainActor
final class AppleIntelligenceConfigurationDraftTests: XCTestCase {
    func testSuccessfulDetectionRequiresExplicitSaveBeforeReplacingCurrentService() async throws {
        let fixture = try makeFixture()
        let settings = try XCTUnwrap(fixture.settings)
        let original = settings.selectedService
        let originalPreference = fixture.defaults.string(forKey: "ai.selectedService")
        let draft = AppleIntelligenceConfigurationDraft(settings: settings)
        defer { draft.cancelPending() }

        XCTAssertTrue(draft.canCheck)
        XCTAssertEqual(draft.testState, .idle)
        XCTAssertFalse(draft.canSave)
        XCTAssertFalse(draft.save())
        XCTAssertTrue(fixture.apple.requests.isEmpty)
        draft.check()
        XCTAssertEqual(draft.testState, .testing)
        await settle()

        XCTAssertFalse(draft.isChecking)
        XCTAssertTrue(draft.isVerified)
        XCTAssertEqual(draft.testState, .available)
        XCTAssertTrue(draft.canSave)
        XCTAssertEqual(settings.selectedService, original)
        XCTAssertEqual(fixture.defaults.string(forKey: "ai.selectedService"), originalPreference)
        XCTAssertEqual(fixture.apple.requests.count, 1)
        XCTAssertEqual(fixture.apple.requests.first?.purpose, .prefill)
        XCTAssertTrue(draft.save())
        XCTAssertEqual(settings.selectedService, .appleIntelligence)
        XCTAssertEqual(fixture.defaults.string(forKey: "ai.selectedService"),
                       AIServiceSelection.appleIntelligence.preferenceValue)
        XCTAssertTrue(draft.isSaved)
        XCTAssertFalse(draft.canSave)
        XCTAssertEqual(draft.testState, .available, "Saving must retain the test result without a Saved message")
        XCTAssertEqual(fixture.custom.explanationCount, 0)
        XCTAssertEqual(fixture.chatGPT.explanationCount, 0)
    }

    func testUnavailableDeviceCannotRunDetectionOrSaveAndKeepsExistingSelection() async throws {
        for unavailable in [AppleIntelligenceAvailability.unsupportedOS, .unsupportedBuild, .deviceNotEligible,
                            .notEnabled, .modelNotReady, .unsupportedLanguage, .unavailable] {
            let fixture = try makeFixture()
            let original = fixture.settings.selectedService
            fixture.apple.availability = unavailable
            let draft = AppleIntelligenceConfigurationDraft(settings: fixture.settings)
            defer { draft.cancelPending() }

            draft.check()
            await settle()

            XCTAssertEqual(draft.availability, unavailable)
            XCTAssertFalse(draft.canCheck)
            XCTAssertFalse(draft.canSave)
            XCTAssertEqual(draft.testState, .unavailable)
            XCTAssertFalse(draft.save())
            XCTAssertTrue(fixture.apple.requests.isEmpty)
            XCTAssertThrowsError(try fixture.settings.selectService(.appleIntelligence)) { error in
                XCTAssertEqual(error as? AIUsageIssue, .appleIntelligence(.unavailable(unavailable)))
            }
            XCTAssertEqual(fixture.settings.selectedService, original)
            XCTAssertEqual(fixture.custom.explanationCount, 0)
            XCTAssertEqual(fixture.chatGPT.explanationCount, 0)
        }
    }

    func testFailedDetectionCannotSaveAndExplicitRetryCanRecover() async throws {
        let fixture = try makeFixture()
        let original = fixture.settings.selectedService
        fixture.apple.response = { _ in throw AppleIntelligenceError.refused }
        let draft = AppleIntelligenceConfigurationDraft(settings: fixture.settings)
        defer { draft.cancelPending() }
        draft.check()
        await settle()
        XCTAssertEqual(draft.issue, .appleIntelligence(.refused))
        XCTAssertFalse(draft.canSave)
        XCTAssertFalse(draft.save())
        XCTAssertEqual(fixture.settings.selectedService, original)

        fixture.apple.response = { _ in "明亮的" }
        draft.check()
        await settle()
        XCTAssertNil(draft.issue)
        XCTAssertTrue(draft.canSave)
        XCTAssertEqual(fixture.apple.requests.count, 2)
        XCTAssertEqual(fixture.settings.selectedService, original)
    }

    func testWhitespaceResponseCannotVerifyOrActivateAppleIntelligence() async throws {
        let fixture = try makeFixture()
        let original = fixture.settings.selectedService
        fixture.apple.response = { _ in " \n\t " }
        let draft = AppleIntelligenceConfigurationDraft(settings: fixture.settings)
        defer { draft.cancelPending() }
        draft.check()
        await settle()

        XCTAssertFalse(draft.isChecking)
        XCTAssertFalse(draft.isVerified)
        XCTAssertEqual(draft.issue, .appleIntelligence(.emptyResponse))
        XCTAssertFalse(draft.save())
        XCTAssertEqual(fixture.settings.selectedService, original)
    }

    func testLeavingOrCancellingFormIgnoresLateDetectionResult() async throws {
        let fixture = try makeFixture()
        let original = fixture.settings.selectedService
        let gate = AppleDraftTestGate()
        fixture.apple.response = { _ in try await gate.wait() }
        let draft = AppleIntelligenceConfigurationDraft(settings: fixture.settings)
        draft.check()
        await settle()
        XCTAssertTrue(draft.isChecking)
        XCTAssertEqual(fixture.apple.requests.count, 1)

        draft.cancelPending()
        gate.complete(.success("late detection result"))
        await settle()

        XCTAssertFalse(draft.isChecking)
        XCTAssertFalse(draft.isVerified)
        XCTAssertFalse(draft.canSave)
        XCTAssertFalse(draft.hasUnsavedChanges)
        XCTAssertNil(draft.issue)
        XCTAssertTrue(draft.canCheck)
        XCTAssertEqual(fixture.settings.selectedService, original)
    }

    func testRetryIgnoresOldFailureWhileNewDetectionIsPending() async throws {
        let fixture = try makeFixture()
        let old = AppleDraftTestGate()
        let current = AppleDraftTestGate()
        var attempt = 0
        fixture.apple.response = { _ in
            attempt += 1
            return try await (attempt == 1 ? old : current).wait()
        }
        let draft = AppleIntelligenceConfigurationDraft(settings: fixture.settings)
        defer { draft.cancelPending() }
        draft.check()
        await settle()
        draft.check()
        await settle()
        XCTAssertEqual(fixture.apple.requests.count, 2)

        old.complete(.failure(AppleIntelligenceError.refused))
        await settle()
        XCTAssertTrue(draft.isChecking)
        XCTAssertFalse(draft.canSave)
        XCTAssertNil(draft.issue)

        current.complete(.success("current result"))
        await settle()
        XCTAssertFalse(draft.isChecking)
        XCTAssertTrue(draft.canSave)
        XCTAssertNil(draft.issue)
    }

    func testDetectionTimeoutCanRetryAndLateTimedOutResponseCannotReplaceVerification() async throws {
        let fixture = try makeFixture()
        let old = AppleDraftTestGate()
        var attempt = 0
        fixture.apple.response = { _ in
            attempt += 1
            if attempt == 1 { return try await old.wait() }
            return "retry succeeded"
        }
        let draft = AppleIntelligenceConfigurationDraft(settings: fixture.settings, timeoutNanoseconds: 100_000_000)
        defer { draft.cancelPending() }
        let deadline = expectation(description: "Detection deadline expires")
        let observation = draft.$issue.sink { issue in
            if issue == .appleIntelligence(.timedOut) { deadline.fulfill() }
        }
        draft.check()
        await fulfillment(of: [deadline], timeout: 2)
        observation.cancel()
        XCTAssertFalse(draft.isChecking)
        XCTAssertFalse(draft.canSave)
        XCTAssertTrue(draft.canCheck)

        draft.check()
        await settle()
        XCTAssertTrue(draft.canSave)
        XCTAssertNil(draft.issue)
        old.complete(.success("late timed-out response"))
        await settle()
        XCTAssertTrue(draft.canSave)
        XCTAssertNil(draft.issue)
        XCTAssertEqual(fixture.apple.requests.count, 2)
    }

    func testChangingSavedServiceDuringDetectionDiscardsResultAndAllowsNewDetection() async throws {
        let fixture = try makeFixture()
        let gate = AppleDraftTestGate()
        fixture.apple.response = { _ in try await gate.wait() }
        let draft = AppleIntelligenceConfigurationDraft(settings: fixture.settings)
        defer { draft.cancelPending() }
        draft.check()
        await settle()
        try fixture.settings.selectService(.chatGPT)
        gate.complete(.success("result for previous revision"))
        await settle()

        XCTAssertFalse(draft.isChecking)
        XCTAssertTrue(draft.canCheck)
        XCTAssertFalse(draft.canSave)
        XCTAssertFalse(draft.save())
        XCTAssertEqual(fixture.settings.selectedService, .chatGPT)
        fixture.apple.response = { _ in "fresh verification" }
        draft.check()
        await settle()
        XCTAssertTrue(draft.canSave)
        XCTAssertEqual(fixture.settings.selectedService, .chatGPT)
    }

    func testChangingLanguageDiscardsPendingDetectionAndRequiresVerificationInNewLanguage() async throws {
        let fixture = try makeFixture()
        let gate = AppleDraftTestGate()
        fixture.apple.response = { _ in try await gate.wait() }
        let draft = AppleIntelligenceConfigurationDraft(settings: fixture.settings)
        defer { draft.cancelPending() }
        draft.check()
        await settle()
        fixture.language.language = .english
        gate.complete(.success("result in previous language"))
        await settle()

        XCTAssertFalse(draft.isChecking)
        XCTAssertFalse(draft.canSave)
        fixture.apple.response = { _ in "bright" }
        draft.check()
        await settle()
        XCTAssertTrue(draft.canSave)
        XCTAssertEqual(fixture.apple.requests.map(\.language), [.chinese, .english])
    }

    func testDetectionErrorForPreviousConfigurationCannotPolluteCurrentForm() async throws {
        let fixture = try makeFixture()
        let gate = AppleDraftTestGate()
        fixture.apple.response = { _ in try await gate.wait() }
        let draft = AppleIntelligenceConfigurationDraft(settings: fixture.settings)
        defer { draft.cancelPending() }
        draft.check()
        await settle()
        try fixture.settings.selectService(.chatGPT)
        gate.complete(.failure(AppleIntelligenceError.refused))
        await settle()

        XCTAssertFalse(draft.isChecking)
        XCTAssertFalse(draft.isVerified)
        XCTAssertFalse(draft.canSave)
        XCTAssertNil(draft.issue)
        XCTAssertEqual(fixture.settings.selectedService, .chatGPT)
    }

    func testChangingConfigurationOrAvailabilityInvalidatesSuccessfulDetectionBeforeSave() async throws {
        let fixture = try makeFixture()
        let draft = AppleIntelligenceConfigurationDraft(settings: fixture.settings)
        defer { draft.cancelPending() }
        draft.check()
        await settle()
        XCTAssertTrue(draft.canSave)
        try fixture.settings.selectService(.chatGPT)
        XCTAssertFalse(draft.canSave)
        XCTAssertFalse(draft.save())
        draft.refreshAvailability()
        XCTAssertFalse(draft.isVerified)

        draft.check()
        await settle()
        XCTAssertTrue(draft.canSave)
        fixture.apple.availability = .notEnabled
        XCTAssertFalse(draft.canSave)
        XCTAssertFalse(draft.save())
        draft.refreshAvailability()
        XCTAssertFalse(draft.isVerified)
        XCTAssertFalse(draft.canCheck)
        XCTAssertEqual(fixture.settings.selectedService, .chatGPT)
    }

    func testSelectedServiceChangeDiscardsLateAppleResponseWithoutCallingReplacementProvider() async throws {
        let fixture = try makeFixture()
        let custom = fixture.settings.selectedService
        try fixture.settings.selectService(.appleIntelligence)
        let gate = AppleDraftTestGate()
        fixture.apple.response = { _ in try await gate.wait() }
        let pending = Task { try await fixture.settings.explain(selection: "bright", context: "A bright room.") }
        await settle()
        XCTAssertEqual(fixture.apple.requests.count, 1)
        try fixture.settings.selectService(custom)
        gate.complete(.success("late Apple response"))
        await assertCancelled(pending)

        XCTAssertEqual(fixture.settings.selectedService, custom)
        XCTAssertEqual(fixture.custom.explanationCount, 0)
        XCTAssertEqual(fixture.chatGPT.explanationCount, 0)
    }

    func testUnavailableActiveAppleServiceReportsErrorWithoutFallingBack() async throws {
        let fixture = try makeFixture()
        try fixture.settings.selectService(.appleIntelligence)
        fixture.apple.availability = .modelNotReady
        XCTAssertFalse(fixture.settings.isAIConfigured)
        XCTAssertEqual(fixture.settings.aiConfigurationIssue, .appleIntelligence(.unavailable(.modelNotReady)))

        do {
            _ = try await fixture.settings.explain(selection: "bright", context: "A bright room.")
            XCTFail("Unavailable Apple Intelligence must report its own failure")
        } catch {
            XCTAssertEqual(error as? AIUsageIssue, .appleIntelligence(.unavailable(.modelNotReady)))
        }
        XCTAssertEqual(fixture.settings.selectedService, .appleIntelligence)
        XCTAssertEqual(fixture.custom.explanationCount, 0)
        XCTAssertEqual(fixture.chatGPT.explanationCount, 0)
    }

    func testAppleSelectionPersistsAcrossRestartEvenWhenDeviceBecomesUnavailable() throws {
        let fixture = try makeFixture()
        try fixture.settings.selectService(.appleIntelligence)
        let profileIDs = fixture.settings.customProfiles.map(\.id)
        fixture.apple.availability = .deviceNotEligible
        let reopened = fixture.reopenedSettings()

        XCTAssertEqual(reopened.selectedService, .appleIntelligence)
        XCTAssertEqual(reopened.customProfiles.map(\.id), profileIDs)
        XCTAssertEqual(reopened.aiConfigurationIssue, .appleIntelligence(.unavailable(.deviceNotEligible)))
        XCTAssertTrue(fixture.apple.requests.isEmpty)
        XCTAssertEqual(fixture.custom.explanationCount, 0)
        XCTAssertEqual(fixture.chatGPT.explanationCount, 0)
    }

    func testAllFourPurposesRouteOriginalInputsAndStudyLanguageToAppleIntelligence() async throws {
        let fixture = try makeFixture()
        fixture.language.language = .english
        fixture.apple.response = { request in "Apple response: " + request.selection }
        try fixture.settings.selectService(.appleIntelligence)
        let purposes: [AIExplanationPurpose] = [.lookup, .translation, .prefill, .intensive]
        let selections = ["bright", "The room is bright.", "bright",
                          "[{\"id\":0,\"source\":\"The room is bright.\",\"words\":[]}]" ]
        for (purpose, selection) in zip(purposes, selections) {
            let response = try await fixture.settings.explain(selection: selection, context: "surrounding context",
                                                                focusedSentence: "The room is bright.", purpose: purpose)
            XCTAssertEqual(response, "Apple response: " + selection)
        }

        XCTAssertEqual(fixture.apple.requests.map(\.purpose), purposes)
        XCTAssertEqual(fixture.apple.requests.map(\.selection), selections)
        XCTAssertEqual(fixture.apple.requests.map(\.context), Array(repeating: "surrounding context", count: 4))
        XCTAssertEqual(fixture.apple.requests.map(\.focusedSentence), Array<String?>(repeating: "The room is bright.", count: 4))
        XCTAssertEqual(fixture.apple.requests.map(\.language), Array(repeating: .english, count: 4))
        XCTAssertEqual(fixture.custom.explanationCount, 0)
        XCTAssertEqual(fixture.chatGPT.explanationCount, 0)
    }

    private func makeFixture() throws -> AppleDraftFixture {
        let name = "AppleIntelligenceConfigurationDraftTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return try AppleDraftFixture(defaults: defaults)
    }

    private func settle() async {
        for _ in 0..<40 { await Task.yield() }
    }

    private func assertCancelled(_ task: Task<String, Error>, file: StaticString = #filePath, line: UInt = #line) async {
        do { _ = try await task.value; XCTFail("Expected cancellation", file: file, line: line) }
        catch { XCTAssertTrue(error is CancellationError, "Unexpected error: \(error)", file: file, line: line) }
    }
}

@MainActor
private final class AppleDraftFixture {
    let defaults: UserDefaults
    let language: AppLanguageStore
    let apple = AppleDraftTestService()
    let custom = AppleDraftTestCustomClient()
    let chatGPT = AppleDraftTestChatGPTClient()
    let credentials = AppleDraftTestProfileCredentials()
    private(set) var settings: AISettingsStore!

    init(defaults: UserDefaults) throws {
        self.defaults = defaults
        defaults.set(InterfaceLanguage.chinese.rawValue, forKey: "interface.language")
        language = AppLanguageStore(defaults: defaults)
        settings = reopenedSettings()
        try settings.saveCustomProfile(name: "Existing API", baseURL: "https://api.example.invalid/v1",
                                       apiKey: "synthetic-apple-draft-test-key", model: "synthetic-model")
    }

    func reopenedSettings() -> AISettingsStore {
        let account = ChatGPTAccountStore(defaults: defaults, credentials: AppleDraftTestChatGPTCredentials(),
                                          auth: AppleDraftTestChatGPTAuth(), client: chatGPT)
        return AISettingsStore(defaults: defaults, credentials: AppleDraftTestLegacyCredentials(), language: language,
                               customCredentials: credentials, customClient: custom, chatGPT: account,
                               appleIntelligence: apple)
    }
}

@MainActor
private final class AppleDraftTestService: AppleIntelligenceServing {
    struct Request {
        let selection: String
        let context: String
        let focusedSentence: String?
        let purpose: AIExplanationPurpose
        let language: StudyLanguage
    }

    var availability: AppleIntelligenceAvailability = .available
    var response: (Request) async throws -> String = { _ in "synthetic Apple response" }
    private(set) var requests: [Request] = []

    func explain(selection: String, context: String, focusedSentence: String?,
                 purpose: AIExplanationPurpose, language: StudyLanguage) async throws -> String {
        let request = Request(selection: selection, context: context, focusedSentence: focusedSentence,
                              purpose: purpose, language: language)
        requests.append(request)
        guard availability == .available else { throw AppleIntelligenceError.unavailable(availability) }
        return try await response(request)
    }
}

/// Deliberately ignores task cancellation so late-result protection is exercised.
@MainActor
private final class AppleDraftTestGate {
    private var continuation: CheckedContinuation<String, Error>?

    func wait() async throws -> String {
        try await withCheckedThrowingContinuation { continuation = $0 }
    }

    func complete(_ result: Result<String, Error>) {
        continuation?.resume(with: result)
        continuation = nil
    }
}

private struct AppleDraftTestLegacyCredentials: AICredentialStorage {
    func read() throws -> String? { nil }
    func write(_ value: String) throws { }
}

private final class AppleDraftTestProfileCredentials: AICustomCredentialStorage {
    private var values: [UUID: String] = [:]
    func read(profileID: UUID) throws -> String? { values[profileID] }
    func write(_ value: String?, profileID: UUID) throws { values[profileID] = value }
}

private struct AppleDraftTestChatGPTCredentials: ChatGPTCredentialStorage {
    func read() throws -> Data? { nil }
    func write(_ data: Data?) throws { }
}

private enum AppleDraftUnexpectedRequest: Error { case unexpected }

@MainActor
private final class AppleDraftTestCustomClient: AICustomServing {
    private(set) var explanationCount = 0
    func fetchModels(baseURL: String, apiKey: String) async throws -> [String] {
        throw AppleDraftUnexpectedRequest.unexpected
    }
    func explain(selection: String, context: String, focusedSentence: String?,
                 purpose: AIExplanationPurpose, configuration: AIConfiguration) async throws -> String {
        explanationCount += 1
        throw AppleDraftUnexpectedRequest.unexpected
    }
}

@MainActor
private final class AppleDraftTestChatGPTClient: ChatGPTServing {
    private(set) var explanationCount = 0
    func fetchModel(accessToken: String) async throws -> String { throw AppleDraftUnexpectedRequest.unexpected }
    func explain(selection: String, context: String, focusedSentence: String?, purpose: AIExplanationPurpose,
                 language: StudyLanguage, accessToken: String, model: String) async throws -> String {
        explanationCount += 1
        throw AppleDraftUnexpectedRequest.unexpected
    }
}

@MainActor
private struct AppleDraftTestChatGPTAuth: ChatGPTAuthenticating {
    func signIn(hostID: String, previous: ChatGPTRegistration?, idTokenHint: String?,
                requestConsent: Bool) async throws -> ChatGPTSession { throw AppleDraftUnexpectedRequest.unexpected }
    func refresh(_ session: ChatGPTSession) async throws -> ChatGPTSession { throw AppleDraftUnexpectedRequest.unexpected }
    func revoke(_ session: ChatGPTSession) async throws { throw AppleDraftUnexpectedRequest.unexpected }
}
