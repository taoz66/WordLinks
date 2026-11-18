import Combine
import XCTest
@testable import ReadingToolDaily

@MainActor
final class ChatGPTConfigurationDraftTests: XCTestCase {
    func testOpeningSavedOrInactiveAccountDoesNotSendInferenceOrShowTestResult() async {
        for saved in [false, true] {
            let account = ConfigurationTestAccount(accountID: "a")
            var saves = 0
            let draft = ChatGPTConfigurationDraft(account: account, selectionIsSaved: saved) { saves += 1 }
            draft.activate()
            await settle()
            XCTAssertEqual(account.validationCount, 0)
            XCTAssertEqual(saves, 0)
            XCTAssertEqual(draft.testState, .idle)
            XCTAssertFalse(draft.canSave)
        }
    }

    func testExplicitTestMustFinishInferenceBeforeCommittingAccountAndService() async {
        let account = ConfigurationTestAccount(accountID: "a")
        let gate = ConfigurationTestGate()
        account.validation = { try await gate.wait() }
        var saves = 0
        let draft = ChatGPTConfigurationDraft(account: account, selectionIsSaved: false) { saves += 1 }
        draft.activate()
        draft.test()
        await settle()
        XCTAssertEqual(draft.phase, .checking)
        XCTAssertEqual(draft.testState, .testing)
        XCTAssertFalse(draft.canSave)
        XCTAssertEqual(saves, 0)

        gate.succeed()
        await settle()
        XCTAssertEqual(saves, 1)
        XCTAssertEqual(account.commitCount, 1)
        XCTAssertEqual(draft.phase, .saved)
        XCTAssertEqual(draft.testState, .available)
        XCTAssertFalse(draft.canSave)
        XCTAssertFalse(draft.hasUnsavedChanges)
    }

    func testRetestingSavedAccountDoesNotRecommitOrPersistSelectionEvenAfterTransientFailure() async {
        let account = ConfigurationTestAccount(accountID: "saved")
        var saves = 0
        let draft = ChatGPTConfigurationDraft(account: account, selectionIsSaved: true) { saves += 1 }
        draft.activate()
        draft.test()
        await settle()
        XCTAssertEqual(draft.testState, .available)
        XCTAssertEqual(account.commitCount, 0)
        XCTAssertEqual(saves, 0)

        account.validation = {
            account.update { $0.issue = .serviceUnavailable }
            throw ChatGPTError.serviceUnavailable
        }
        draft.test()
        await settle()
        XCTAssertEqual(draft.phase, .failed(.serviceUnavailable))
        XCTAssertEqual(account.commitCount, 0)
        XCTAssertEqual(saves, 0)

        account.validation = { }
        draft.test()
        await settle()
        XCTAssertEqual(account.validationCount, 3)
        XCTAssertEqual(draft.phase, .saved)
        XCTAssertEqual(draft.testState, .available)
        XCTAssertFalse(draft.canSave)
        XCTAssertFalse(draft.hasUnsavedChanges)
        XCTAssertEqual(account.commitCount, 0, "A health check must preserve the current production account generation")
        XCTAssertEqual(saves, 0, "Testing the saved service must not persist the service selection again")
    }

    func testFailedTestCannotActivateServiceAndExplicitRetryCanRecover() async {
        let account = ConfigurationTestAccount(accountID: "a")
        account.validation = { throw ChatGPTError.insufficientCredits }
        var saves = 0
        let draft = ChatGPTConfigurationDraft(account: account, selectionIsSaved: false) { saves += 1 }
        draft.activate()
        draft.test()
        await settle()
        XCTAssertEqual(draft.phase, .failed(.insufficientCredits))
        XCTAssertEqual(draft.testState, .unavailable)
        XCTAssertFalse(draft.canSave)
        XCTAssertEqual(saves, 0)

        account.validation = { }
        draft.test()
        await settle()
        XCTAssertEqual(draft.phase, .saved)
        XCTAssertEqual(draft.testState, .available)
        XCTAssertEqual(account.validationCount, 2)
        XCTAssertEqual(saves, 1)
    }

    func testBrowserSignInCompletesAndTestsBeforeActivatingWithoutSaveAction() async {
        let account = ConfigurationTestAccount(accountID: nil)
        let gate = ConfigurationTestGate()
        account.validation = { try await gate.wait() }
        var saves = 0
        let draft = ChatGPTConfigurationDraft(account: account, selectionIsSaved: false) { saves += 1 }
        draft.activate()
        draft.beginSignIn()
        await settle()
        XCTAssertEqual(draft.phase, .signingIn)
        account.update { $0.accountID = "new" }
        await settle()
        XCTAssertEqual(account.validationCount, 0)
        XCTAssertEqual(saves, 0)
        account.update { $0.signingIn = false }
        await settle()
        XCTAssertEqual(account.validationCount, 1)
        XCTAssertEqual(draft.testState, .testing)
        XCTAssertEqual(saves, 0)
        gate.succeed()
        await settle()
        XCTAssertEqual(draft.phase, .saved)
        XCTAssertEqual(draft.testState, .available)
        XCTAssertEqual(saves, 1)
    }

    func testLateResultForPreviousAccountCannotCommitNewAccount() async {
        let account = ConfigurationTestAccount(accountID: "a")
        let old = ConfigurationTestGate()
        let current = ConfigurationTestGate()
        account.validation = { try await (account.validationCount == 1 ? old : current).wait() }
        var saves = 0
        let draft = ChatGPTConfigurationDraft(account: account, selectionIsSaved: false) { saves += 1 }
        draft.activate()
        draft.test()
        await settle()
        account.update { $0.accountID = "b" }
        await settle()
        XCTAssertEqual(account.validationCount, 1, "An external identity change must wait for an explicit Test")
        draft.test()
        await settle()
        XCTAssertEqual(account.validationCount, 2)
        old.succeed()
        await settle()
        XCTAssertEqual(draft.testState, .testing)
        XCTAssertEqual(saves, 0)
        current.succeed()
        await settle()
        XCTAssertEqual(draft.testState, .available)
        XCTAssertEqual(saves, 1)
    }

    func testCommitFailureReportsUnavailableAndTestCanRetry() async {
        let account = ConfigurationTestAccount(accountID: "a")
        var fail = true
        var attempts = 0
        let draft = ChatGPTConfigurationDraft(account: account, selectionIsSaved: false) {
            attempts += 1
            if fail { throw ChatGPTError.storage }
        }
        draft.activate()
        draft.test()
        await settle()
        XCTAssertEqual(draft.phase, .saveFailed)
        XCTAssertEqual(draft.testState, .unavailable)
        fail = false
        draft.test()
        await settle()
        XCTAssertEqual(draft.phase, .saved)
        XCTAssertEqual(draft.testState, .available)
        XCTAssertEqual(attempts, 2)
        XCTAssertEqual(account.validationCount, 2)
    }

    func testLoginExpiryInvalidatesEarlierSuccessfulTest() async {
        let account = ConfigurationTestAccount(accountID: "a")
        let draft = ChatGPTConfigurationDraft(account: account, selectionIsSaved: false) { }
        draft.activate()
        draft.test()
        await settle()
        XCTAssertEqual(draft.testState, .available)
        account.update { $0.needsReauthentication = true }
        await settle()
        XCTAssertEqual(draft.phase, .failed(.loginExpired))
        XCTAssertFalse(draft.canSave)
        draft.test()
        XCTAssertEqual(draft.testState, .unavailable)
    }

    func testExplicitTestSettingLoginExpiryAndIssuePreservesUnavailableStatus() async {
        let account = ConfigurationTestAccount(accountID: "a")
        account.validation = {
            account.update {
                $0.needsReauthentication = true
                $0.issue = .loginExpired
            }
            throw ChatGPTError.loginExpired
        }
        let draft = ChatGPTConfigurationDraft(account: account, selectionIsSaved: true) { }
        draft.activate()
        draft.test()
        await settle()
        XCTAssertEqual(draft.phase, .failed(.loginExpired))
        XCTAssertEqual(draft.testState, .unavailable)
        XCTAssertFalse(draft.canSave)
    }

    func testLeavingFormIgnoresLateTestAndCannotActivateService() async {
        let account = ConfigurationTestAccount(accountID: "a")
        let gate = ConfigurationTestGate()
        account.validation = { try await gate.wait() }
        var saves = 0
        let draft = ChatGPTConfigurationDraft(account: account, selectionIsSaved: false) { saves += 1 }
        draft.activate()
        draft.test()
        await settle()
        draft.deactivate()
        gate.succeed()
        await settle()
        XCTAssertFalse(draft.canSave)
        XCTAssertEqual(draft.phase, .idle)
        XCTAssertEqual(saves, 0)
    }

    func testTimeoutEndsPendingTestAndIgnoresItsLateResultAfterRetry() async {
        let account = ConfigurationTestAccount(accountID: "a")
        let old = ConfigurationTestGate()
        account.validation = {
            if account.validationCount == 1 { try await old.wait() }
        }
        var saves = 0
        let draft = ChatGPTConfigurationDraft(account: account, selectionIsSaved: false,
                                               validationTimeoutNanoseconds: 10_000_000) { saves += 1 }
        let timedOut = expectation(description: "The validation deadline is enforced")
        let observation = draft.$phase.sink { phase in
            if phase == .failed(.timedOut) { timedOut.fulfill() }
        }
        draft.activate()
        draft.test()
        await fulfillment(of: [timedOut], timeout: 1)
        observation.cancel()
        XCTAssertFalse(draft.isBusy)
        XCTAssertEqual(draft.testState, .unavailable)
        XCTAssertEqual(saves, 0)
        draft.test()
        await settle()
        XCTAssertEqual(account.validationCount, 2)
        XCTAssertEqual(draft.testState, .available)
        old.succeed()
        await settle()
        XCTAssertEqual(draft.testState, .available)
        XCTAssertEqual(saves, 1)
    }

    private func settle() async {
        for _ in 0..<30 { await Task.yield() }
    }
}

@MainActor
private final class ConfigurationTestAccount: ChatGPTConfigurationAccount {
    private let changes = PassthroughSubject<Void, Never>()
    var configurationSnapshot: ChatGPTConfigurationSnapshot
    var configurationChanges: AnyPublisher<Void, Never> { changes.eraseToAnyPublisher() }
    var validation: () async throws -> Void = { }
    private(set) var validationCount = 0
    private(set) var commitCount = 0

    init(accountID: String?) { configurationSnapshot = .init(accountID: accountID) }

    func update(_ body: (inout ChatGPTConfigurationSnapshot) -> Void) {
        changes.send()
        body(&configurationSnapshot)
    }

    func validateConfiguration() async throws {
        validationCount += 1
        try await validation()
    }

    func beginConfiguration() { }
    func endConfiguration() { }
    func commitConfigurationCandidate() throws { commitCount += 1 }
    func signInConfiguration(otherAccount: Bool) { update { $0.signingIn = true } }
    func cancelConfigurationSignIn() { update { $0.signingIn = false } }
    func dismissConfigurationIssue() { update { $0.issue = nil } }
}

@MainActor
private final class ConfigurationTestGate {
    private var continuation: CheckedContinuation<Void, Error>?
    func wait() async throws {
        try await withCheckedThrowingContinuation { continuation = $0 }
    }
    func succeed() {
        continuation?.resume()
        continuation = nil
    }
}
