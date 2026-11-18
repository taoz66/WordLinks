import Foundation
import Security
import XCTest
@testable import ReadingToolDaily

@MainActor
final class AICustomConfigurationDraftTests: XCTestCase {
    func testEditsAndModelSelectionWaitForExplicitTestAndTestingSavedConfigurationDoesNotEnableSave() async {
        let client = DraftClient()
        let draft = makeDraft(client: client)
        draft.retryValidation()
        XCTAssertEqual(draft.testState, .testing)
        await waitUntil { !draft.isChecking }
        XCTAssertEqual(draft.testState, .available)
        XCTAssertFalse(draft.canSave, "Testing an unchanged saved request must not enable Save")

        draft.address = "https://edited.example/v1"
        draft.apiKey = "edited-synthetic-secret"
        draft.selectModel("edited-model")
        await Task.yield()
        XCTAssertEqual(client.configurations.count, 1)
        XCTAssertEqual(draft.testState, .idle)
        XCTAssertFalse(draft.canSave)
        draft.retryValidation()
        await waitUntil { !draft.isChecking }
        XCTAssertEqual(client.configurations.count, 2)
        XCTAssertEqual(draft.testState, .available)
        XCTAssertTrue(draft.save())
        XCTAssertFalse(draft.canSave)
        XCTAssertEqual(draft.testState, .available)
    }

    func testNoAuthenticationCanFetchAndVerifyBeforeSavingWithoutAKey() async {
        let client = DraftClient()
        client.fetch = { address, key in
            XCTAssertEqual(address, "http://127.0.0.1:11434/v1")
            XCTAssertEqual(key, "")
            return ["local-model"]
        }
        var savedConfiguration: AIConfiguration?
        let draft = AICustomConfigurationDraft(name: "Local", address: "http://127.0.0.1:11434/v1",
                                               kind: .localModel, authentication: .none, client: client) { _, configuration, _ in
            savedConfiguration = configuration
            return UUID()
        }
        XCTAssertTrue(draft.canFetchModels)
        XCTAssertFalse(draft.canSave)
        draft.fetchModels()
        await waitUntil { !draft.isFetching && !draft.isChecking }
        XCTAssertTrue(draft.model.isEmpty, "Fetching never chooses a model or sends an inference request")
        XCTAssertTrue(client.configurations.isEmpty)
        draft.selectModel("local-model")
        draft.retryValidation()
        await waitUntil { !draft.isChecking }
        XCTAssertEqual(draft.model, "local-model")
        XCTAssertEqual(client.configurations.last?.authentication, AICustomAuthentication.none)
        XCTAssertEqual(client.configurations.last?.apiKey, "")
        XCTAssertTrue(draft.canSave)
        XCTAssertTrue(draft.save())
        XCTAssertEqual(savedConfiguration?.authentication, AICustomAuthentication.none)
        XCTAssertFalse(draft.hasChanges)
    }

    func testAuthenticationChangeInvalidatesVerificationAndRequiresNewKey() async {
        let client = DraftClient()
        let draft = AICustomConfigurationDraft(name: "Local", address: "http://127.0.0.1:11434/v1",
                                               model: "local-model", kind: .localModel, authentication: .none,
                                               client: client) { _, _, _ in UUID() }
        draft.retryValidation()
        await waitUntil { !draft.isChecking }
        XCTAssertTrue(draft.canSave)
        draft.authentication = .apiKey
        XCTAssertNil(draft.validatedConfiguration)
        XCTAssertNil(draft.configuration)
        XCTAssertFalse(draft.canFetchModels)
        XCTAssertFalse(draft.canSave)
        draft.apiKey = "synthetic-secret"
        draft.retryValidation()
        await waitUntil { !draft.isChecking }
        XCTAssertTrue(draft.canSave)
        XCTAssertEqual(client.configurations.last?.authentication, .apiKey)
        XCTAssertEqual(client.configurations.last?.apiKey, "synthetic-secret")
    }

    func testNewEmptyDraftIsNotReportedAsSaved() {
        let draft = AICustomConfigurationDraft(client: DraftClient()) { _, _, _ in UUID() }
        XCTAssertFalse(draft.hasChanges)
        XCTAssertFalse(draft.canSave)
        XCTAssertEqual(draft.testState, .idle)
    }

    func testCredentialReadRetryRestoresOnlySecretAndVerifiesEditedDraft() async {
        let client = DraftClient()
        var reloads = 0
        let draft = AICustomConfigurationDraft(name: "Original", address: "https://original.example/v1", apiKey: "",
                                               model: "original-model", models: ["original-model", "edited-model"], isSaved: true,
                                               initialIssue: .custom(.keychain(errSecAuthFailed)),
                                               credentialReload: { reloads += 1; return "recovered-secret" }, client: client) { _, _, _ in UUID() }
        draft.name = "Keep this name"
        draft.model = "edited-model"
        XCTAssertFalse(draft.isChecking, "A credential read failure must wait for the explicit Test action")
        XCTAssertFalse(draft.canSave)
        draft.retryValidation()
        await waitUntil { !draft.isChecking }
        XCTAssertEqual(reloads, 1)
        XCTAssertEqual(draft.name, "Keep this name")
        XCTAssertEqual(draft.address, "https://original.example/v1")
        XCTAssertEqual(draft.model, "edited-model")
        XCTAssertEqual(draft.models, ["original-model", "edited-model"])
        XCTAssertEqual(client.configurations.last?.apiKey, "recovered-secret")
        XCTAssertEqual(client.configurations.last?.model, "edited-model")
        XCTAssertNil(draft.issue)
        XCTAssertTrue(draft.canSave)
    }

    func testFailedCredentialReadRetryKeepsOtherFieldsAndRecoveryAvailable() {
        let client = DraftClient()
        let draft = AICustomConfigurationDraft(name: "Keep this name", address: "https://original.example/v1", apiKey: "",
                                               model: "selected-model", isSaved: true,
                                               initialIssue: .custom(.keychain(errSecAuthFailed)),
                                               credentialReload: { throw AIError.keychain(errSecAuthFailed) }, client: client) { _, _, _ in UUID() }
        draft.retryValidation()
        XCTAssertFalse(draft.isChecking)
        XCTAssertEqual(draft.validationIssue, .custom(.keychain(errSecAuthFailed)))
        XCTAssertEqual(draft.name, "Keep this name")
        XCTAssertEqual(draft.model, "selected-model")
        XCTAssertTrue(draft.apiKey.isEmpty)
        XCTAssertTrue(client.configurations.isEmpty)
        XCTAssertFalse(draft.canSave)
    }

    func testManuallyEnteredReplacementKeyIsNeverOverwrittenByCredentialRetry() async {
        let client = DraftClient()
        var reloads = 0
        let draft = AICustomConfigurationDraft(name: "Original", address: "https://original.example/v1", apiKey: "",
                                               model: "selected-model", isSaved: true,
                                               initialIssue: .custom(.keychain(errSecAuthFailed)),
                                               credentialReload: { reloads += 1; return "stored-secret" }, client: client) { _, _, _ in UUID() }
        draft.apiKey = "replacement-secret"
        draft.retryValidation()
        await waitUntil { !draft.isChecking }
        XCTAssertEqual(reloads, 0)
        XCTAssertEqual(draft.apiKey, "replacement-secret")
        XCTAssertEqual(client.configurations.last?.apiKey, "replacement-secret")
        XCTAssertTrue(draft.canSave)
    }

    func testSelectionMustFinishAnActualExplanationBeforeSave() async throws {
        let client = DraftClient()
        let gate = DraftGate<String>()
        let started = expectation(description: "Generation check started")
        client.explanation = { _ in started.fulfill(); return try await gate.wait() }
        var saves = 0
        let draft = makeDraft(client: client) { _, _, _ in saves += 1; return UUID() }

        draft.selectModel("new-model")
        draft.retryValidation()
        XCTAssertTrue(draft.isChecking)
        XCTAssertFalse(draft.canSave)
        XCTAssertFalse(draft.save())
        await fulfillment(of: [started], timeout: 2)
        XCTAssertEqual(client.configurations.map(\.model), ["new-model"])
        XCTAssertEqual(client.purposes, [.prefill])
        XCTAssertEqual(saves, 0)

        gate.complete(.success("明亮"))
        await waitUntil { !draft.isChecking }
        XCTAssertTrue(draft.canSave)
        XCTAssertTrue(draft.save())
        XCTAssertEqual(saves, 1)
        XCTAssertFalse(draft.hasChanges)
        XCTAssertFalse(draft.canSave)
    }

    func testNewerModelIsNotOverwrittenByLateOlderResult() async {
        let client = DraftClient()
        let old = DraftGate<String>()
        let fresh = DraftGate<String>()
        let oldStarted = expectation(description: "Old model started")
        let newStarted = expectation(description: "New model started")
        client.explanation = { config in
            if config.model == "old-model" { oldStarted.fulfill(); return try await old.wait() }
            newStarted.fulfill(); return try await fresh.wait()
        }
        let draft = makeDraft(client: client)
        draft.selectModel("old-model")
        draft.retryValidation()
        await fulfillment(of: [oldStarted], timeout: 2)
        draft.selectModel("new-model")
        draft.retryValidation()
        await fulfillment(of: [newStarted], timeout: 2)
        old.complete(.success("old result"))
        await Task.yield()
        XCTAssertTrue(draft.isChecking)
        XCTAssertFalse(draft.canSave)
        fresh.complete(.success("new result"))
        await waitUntil { !draft.isChecking }
        XCTAssertEqual(draft.validatedConfiguration?.model, "new-model")
        XCTAssertTrue(draft.canSave)
    }

    func testCredentialsEditImmediatelyInvalidatesPreviousCheckAndUsesOnlyLatestInput() async {
        let client = DraftClient()
        let draft = makeDraft(client: client)
        draft.selectModel("new-model")
        draft.retryValidation()
        await waitUntil { !draft.isChecking }
        XCTAssertTrue(draft.canSave)
        draft.address = "https://new.example/v1"
        draft.apiKey = "new-secret"
        XCTAssertFalse(draft.canSave)
        XCTAssertNil(draft.validatedConfiguration)
        XCTAssertEqual(client.configurations.count, 1, "Editing must not test the new configuration automatically")
        draft.retryValidation()
        await waitUntil { !draft.isChecking }
        XCTAssertEqual(client.configurations.count, 2)
        XCTAssertEqual(client.configurations.last?.baseURL, "https://new.example/v1")
        XCTAssertEqual(client.configurations.last?.apiKey, "new-secret")
        XCTAssertTrue(draft.canSave)
    }

    func testFailedGenerationBlocksSavingUntilSuccessfulRetry() async {
        let client = DraftClient()
        client.explanation = { _ in throw AIError.http(429) }
        let draft = makeDraft(client: client)
        draft.selectModel("new-model")
        draft.retryValidation()
        await waitUntil { !draft.isChecking }
        XCTAssertEqual(draft.validationIssue, .custom(.http(429)))
        XCTAssertFalse(draft.canSave)
        XCTAssertFalse(draft.isChecking)
        XCTAssertFalse(draft.save())
        client.explanation = { _ in "definition" }
        draft.retryValidation()
        await waitUntil { !draft.isChecking }
        XCTAssertNil(draft.issue)
        XCTAssertTrue(draft.canSave)
    }

    func testOpeningSavedConfigurationDoesNotGenerateRequestAndRenameNeedsNoNewCheck() async {
        let client = DraftClient()
        let draft = makeDraft(client: client)
        await Task.yield()
        XCTAssertTrue(client.configurations.isEmpty)
        XCTAssertEqual(client.fetchCount, 0)
        XCTAssertFalse(draft.canSave)
        draft.name = "Renamed"
        XCTAssertTrue(draft.canSave)
        XCTAssertTrue(draft.save())
        XCTAssertTrue(client.configurations.isEmpty)
    }

    func testActivatingAnotherSavedProfileRequiresVerificationEvenWithoutEditing() async {
        let client = DraftClient()
        let draft = makeDraft(client: client, requiresActivation: true)
        XCTAssertTrue(draft.hasChanges)
        XCTAssertFalse(draft.canSave)
        draft.retryValidation()
        await waitUntil { !draft.isChecking }
        XCTAssertEqual(client.configurations.count, 1)
        XCTAssertTrue(draft.canSave)
        XCTAssertTrue(draft.save())
        XCTAssertFalse(draft.hasChanges)
    }

    func testEditingCredentialsAndRestoringOriginalValuesCannotBypassFailedValidation() async {
        let client = DraftClient()
        client.explanation = { _ in throw AIError.http(401) }
        let draft = makeDraft(client: client)
        draft.name = "Renamed"
        XCTAssertTrue(draft.canSave)
        draft.apiKey = "changed-secret"
        draft.apiKey = "old-secret"
        XCTAssertFalse(draft.canSave)
        draft.retryValidation()
        await waitUntil { !draft.isChecking }
        XCTAssertEqual(draft.validationIssue, .custom(.http(401)))
        XCTAssertFalse(draft.canSave)
        XCTAssertFalse(draft.save())
    }

    func testSaveFailurePreservesVerifiedDraftForRetryWithoutAdditionalGeneration() async {
        let client = DraftClient()
        var attempts = 0
        let draft = makeDraft(client: client) { _, _, _ in
            attempts += 1
            if attempts == 1 { throw AIError.profileStorage }
            return UUID()
        }
        draft.selectModel("new-model")
        draft.retryValidation()
        await waitUntil { !draft.isChecking }
        XCTAssertFalse(draft.save())
        XCTAssertNotNil(draft.saveIssue)
        XCTAssertTrue(draft.canSave)
        XCTAssertTrue(draft.hasChanges)
        XCTAssertEqual(draft.model, "new-model")
        XCTAssertTrue(draft.save())
        XCTAssertEqual(attempts, 2)
        XCTAssertEqual(client.configurations.count, 1)
        XCTAssertFalse(draft.hasChanges)
    }

    func testReselectingSameModelAndFailingCannotUseRenameExemption() async {
        let client = DraftClient()
        client.explanation = { _ in throw AIError.http(402) }
        let draft = makeDraft(client: client)
        draft.name = "Renamed"
        XCTAssertTrue(draft.canSave)
        draft.selectModel("original-model")
        draft.retryValidation()
        XCTAssertFalse(draft.canSave)
        await waitUntil { !draft.isChecking }
        XCTAssertEqual(draft.validationIssue, .custom(.http(402)))
        XCTAssertFalse(draft.canSave)
        XCTAssertFalse(draft.save())
    }

    func testTimeoutStopsSpinnerAndRejectsLateSuccess() async {
        let client = DraftClient()
        let gate = DraftGate<String>()
        let started = expectation(description: "Check started")
        client.explanation = { _ in started.fulfill(); return try await gate.wait() }
        let draft = makeDraft(client: client, timeout: 5_000_000)
        draft.selectModel("new-model")
        draft.retryValidation()
        await fulfillment(of: [started], timeout: 2)
        await waitUntil { !draft.isChecking }
        XCTAssertEqual(draft.validationIssue, .custom(.timedOut))
        XCTAssertFalse(draft.canSave)
        gate.complete(.success("too late"))
        await Task.yield()
        XCTAssertNil(draft.validatedConfiguration)
        XCTAssertFalse(draft.canSave)
    }

    func testModelsEndpointSuccessDoesNotCountAsSuccessfulGeneration() async {
        let client = DraftClient()
        let draft = AICustomConfigurationDraft(name: "New", address: "https://new.example/v1", apiKey: "secret",
                                               model: "typed-model", client: client) { _, _, _ in UUID() }
        draft.fetchModels()
        await waitUntil { !draft.isFetching }
        XCTAssertEqual(draft.models, ["listed-model"])
        XCTAssertEqual(draft.model, "", "A model absent from the newly fetched list must be deselected")
        XCTAssertTrue(client.configurations.isEmpty)
        XCTAssertFalse(draft.canSave)
    }

    func testChangingProviderRejectsOldModelList() async {
        let client = DraftClient()
        let gate = DraftGate<[String]>()
        let started = expectation(description: "Fetch started")
        client.fetch = { _, _ in started.fulfill(); return try await gate.wait() }
        let draft = makeDraft(client: client)
        draft.fetchModels()
        await fulfillment(of: [started], timeout: 2)
        draft.address = "https://other.example/v1"
        gate.complete(.success(["old-provider-model"]))
        await Task.yield()
        XCTAssertTrue(draft.models.isEmpty)
        draft.cancelPending()
    }

    func testRefreshingCacheKeepsListedSelectionAndSavesWithoutNewInference() async {
        let client = DraftClient()
        client.fetch = { _, _ in [" next-model ", "original-model", "next-model", "  "] }
        var savedModels: [String]?
        let draft = makeDraft(client: client) { _, _, models in
            savedModels = models
            return UUID()
        }
        draft.fetchModels()
        await waitUntil { !draft.isFetching }

        XCTAssertEqual(draft.models, ["next-model", "original-model"])
        XCTAssertEqual(draft.model, "original-model")
        XCTAssertTrue(draft.hasChanges)
        XCTAssertTrue(draft.canSave)
        XCTAssertTrue(client.configurations.isEmpty)
        XCTAssertTrue(draft.save())
        XCTAssertEqual(savedModels, draft.models)
        XCTAssertFalse(draft.hasChanges)
        XCTAssertFalse(draft.canSave)
    }

    func testRepeatedFetchActionLeavesOriginalRequestRunning() async {
        let client = DraftClient()
        let gate = DraftGate<[String]>()
        let started = expectation(description: "Fetch started")
        client.fetch = { _, _ in started.fulfill(); return try await gate.wait() }
        let draft = makeDraft(client: client)
        draft.fetchModels()
        await fulfillment(of: [started], timeout: 2)

        draft.fetchModels()

        XCTAssertTrue(draft.isFetching)
        XCTAssertEqual(client.fetchCount, 1)
        gate.complete(.success(["original-model"]))
        await waitUntil { !draft.isFetching }
        XCTAssertNil(draft.fetchIssue)
        XCTAssertEqual(draft.model, "original-model")
    }

    func testEmptyOrFailedFetchPreservesCacheSelectionAndVerifiedSave() async {
        for result in [Result<[String], Error>.success(["  "]), .failure(AIError.modelsHTTP(404))] {
            let client = DraftClient()
            client.fetch = { _, _ in try result.get() }
            let draft = makeDraft(client: client)
            draft.selectModel("original-model")
            draft.retryValidation()
            await waitUntil { !draft.isChecking }
            draft.name = "Edited"
            XCTAssertTrue(draft.canSave)

            draft.fetchModels()
            await waitUntil { !draft.isFetching }

            XCTAssertEqual(draft.models, ["original-model"])
            XCTAssertEqual(draft.model, "original-model")
            XCTAssertNotNil(draft.fetchIssue)
            XCTAssertNotNil(draft.fetchStatusMessage)
            XCTAssertNil(draft.issue, "Catalog feedback must not mark an already verified model as unavailable")
            XCTAssertTrue(draft.canSave)
            XCTAssertTrue(draft.save())
        }
    }

    func testManualModelIsNormalizedCachedAndWaitsForExplicitTestingWithoutFetching() async {
        let client = DraftClient()
        let draft = makeDraft(client: client)
        XCTAssertFalse(draft.commitManualModel(" \n "))
        XCTAssertFalse(draft.commitManualModel("bad\nmodel"))
        XCTAssertEqual(draft.models, ["original-model"])

        XCTAssertTrue(draft.commitManualModel("  unlisted-model  "))
        XCTAssertTrue(client.configurations.isEmpty, "Entering a model must wait for explicit testing")
        draft.retryValidation()
        await waitUntil { !draft.isChecking }
        XCTAssertEqual(draft.model, "unlisted-model")
        XCTAssertEqual(draft.models, ["original-model", "unlisted-model"])
        XCTAssertEqual(client.configurations.last?.model, "unlisted-model")
        XCTAssertEqual(client.fetchCount, 0)
        XCTAssertTrue(draft.canSave)

        XCTAssertTrue(draft.commitManualModel("unlisted-model"))
        await waitUntil { !draft.isChecking }
        XCTAssertEqual(draft.models, ["original-model", "unlisted-model"])
    }

    func testManualValidationDoesNotErasePriorCatalogFeedback() async {
        let client = DraftClient()
        client.fetch = { _, _ in throw AIError.modelsHTTP(403) }
        let draft = makeDraft(client: client)
        draft.fetchModels()
        await waitUntil { !draft.isFetching }
        let feedback = draft.fetchStatusMessage

        XCTAssertTrue(draft.commitManualModel("manual-model"))
        draft.retryValidation()
        await waitUntil { !draft.isChecking }

        XCTAssertEqual(draft.fetchIssue, .custom(.modelsHTTP(403)))
        XCTAssertEqual(draft.fetchStatusMessage, feedback)
        XCTAssertTrue(draft.canSave)
    }

    func testEditingKeyClearsCacheAndRejectsLateModelList() async {
        let client = DraftClient()
        let gate = DraftGate<[String]>()
        let started = expectation(description: "Fetch started")
        client.fetch = { _, _ in started.fulfill(); return try await gate.wait() }
        let draft = makeDraft(client: client)
        draft.fetchModels()
        await fulfillment(of: [started], timeout: 2)

        draft.apiKey = "replacement-secret"
        XCTAssertTrue(draft.models.isEmpty)
        XCTAssertFalse(draft.isFetching)
        gate.complete(.success(["stale-model"]))
        await Task.yield()

        XCTAssertTrue(draft.models.isEmpty)
        draft.cancelPending()
    }

    func testCatalogErrorsHaveDistinctManualEntryFeedback() async {
        let errors: [AIError] = [.modelsHTTP(401), .modelsHTTP(403), .modelsHTTP(404),
                                 .emptyModels, .invalidModelsResponse, .timedOut]
        var messages = Set<String>()
        for error in errors {
            let client = DraftClient()
            client.fetch = { _, _ in throw error }
            let draft = makeDraft(client: client)
            draft.fetchModels()
            await waitUntil { !draft.isFetching }
            let message = draft.fetchStatusMessage ?? ""
            XCTAssertFalse(message.isEmpty)
            messages.insert(message)
            XCTAssertEqual(draft.models, ["original-model"])
            XCTAssertEqual(draft.model, "original-model")
        }
        XCTAssertEqual(messages.count, errors.count)
    }

    func testExplicitTestWithIncompleteConfigurationReportsValidationErrorMessage() {
        let client = DraftClient()
        let draft = AICustomConfigurationDraft(name: "New", address: "not-a-url", apiKey: "",
                                               model: "", authentication: .none, client: client) { _, _, _ in UUID() }
        draft.retryValidation()
        XCTAssertEqual(draft.testState, .unavailable)
        XCTAssertEqual(draft.validationIssue, .custom(.invalidAddress))
        XCTAssertEqual(draft.errorMessage, AIError.invalidAddress.errorDescription)
        XCTAssertTrue(client.configurations.isEmpty)

        draft.address = "https://valid.example/v1"
        draft.retryValidation()
        XCTAssertEqual(draft.testState, .unavailable)
        XCTAssertEqual(draft.validationIssue, .custom(.missingModel))
        XCTAssertEqual(draft.errorMessage, AIError.missingModel.errorDescription)
        XCTAssertTrue(client.configurations.isEmpty)
    }

    private func makeDraft(client: DraftClient, requiresActivation: Bool = false,
                           timeout: UInt64 = 2_000_000_000,
                           save: @escaping (String, AIConfiguration, [String]) throws -> UUID = { _, _, _ in UUID() }) -> AICustomConfigurationDraft {
        AICustomConfigurationDraft(name: "Original", address: "https://original.example/v1", apiKey: "old-secret",
                                   model: "original-model", models: ["original-model"], isSaved: true,
                                   requiresActivation: requiresActivation, client: client,
                                   timeoutNanoseconds: timeout, saveAction: save)
    }

    private func waitUntil(_ condition: @escaping () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        let limit = ContinuousClock.now.advanced(by: .seconds(2))
        while !condition(), ContinuousClock.now < limit { await Task.yield() }
        XCTAssertTrue(condition(), "Async operation did not reach its expected state", file: file, line: line)
    }
}

@MainActor
private final class DraftClient: AICustomServing {
    var explanation: (AIConfiguration) async throws -> String = { _ in "definition" }
    var fetch: (String, String) async throws -> [String] = { _, _ in ["listed-model"] }
    var configurations: [AIConfiguration] = []
    var purposes: [AIExplanationPurpose] = []
    var fetchCount = 0
    func fetchModels(baseURL: String, apiKey: String) async throws -> [String] {
        fetchCount += 1
        return try await fetch(baseURL, apiKey)
    }
    func explain(selection: String, context: String, focusedSentence: String?, purpose: AIExplanationPurpose,
                 configuration: AIConfiguration) async throws -> String {
        configurations.append(configuration)
        purposes.append(purpose)
        return try await explanation(configuration)
    }
}

@MainActor
private final class DraftGate<Value> {
    private var continuation: CheckedContinuation<Value, Error>?
    func wait() async throws -> Value { try await withCheckedThrowingContinuation { continuation = $0 } }
    func complete(_ result: Result<Value, Error>) { let pending = continuation; continuation = nil; pending?.resume(with: result) }
}
