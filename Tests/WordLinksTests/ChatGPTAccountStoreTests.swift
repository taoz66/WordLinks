import Combine
import Foundation
import XCTest
@testable import WordLinks

@MainActor
final class ChatGPTAccountStoreTests: XCTestCase {
    private let date = Date(timeIntervalSince1970: 2_000_000_000)

    func testConcurrentExplanationsShareOneRotatingRefresh() async throws {
        let old = session("a", expired: true)
        let renewed = session("a", suffix: "renewed")
        let credentials = try storage([old], active: old.registration)
        let auth = AccountStoreTestAuth()
        let client = AccountStoreTestClient()
        let started = expectation(description: "Refresh entered")
        let gate = AccountStoreTestGate<ChatGPTSession>()
        auth.onRefresh = { _ in started.fulfill(); return try await gate.wait() }
        let store = makeStore(credentials: credentials, auth: auth, client: client)

        let first = explanation(store)
        await fulfillment(of: [started], timeout: 2)
        let secondStarted = expectation(description: "Second explanation entered")
        let second = Task {
            secondStarted.fulfill()
            return try await store.explain(selection: "bank", context: "She sat on the bank.", language: .english)
        }
        await fulfillment(of: [secondStarted], timeout: 2)
        gate.succeed(renewed)

        let firstText = try await first.value
        let secondText = try await second.value
        XCTAssertEqual(firstText, "a riverbank")
        XCTAssertEqual(secondText, "a riverbank")
        XCTAssertEqual(auth.refreshes.map(\.refreshToken), [old.refreshToken])
        XCTAssertEqual(client.explanationTokens, [renewed.accessToken, renewed.accessToken])
        XCTAssertEqual(try credentials.vault().sessions, [renewed])
    }

    func testTemporaryRefreshFailurePreservesSessionAndCanRetry() async throws {
        let old = session("a", expired: true)
        let renewed = session("a", suffix: "renewed")
        let credentials = try storage([old], active: old.registration)
        let auth = AccountStoreTestAuth()
        var attempt = 0
        auth.onRefresh = { _ in
            attempt += 1
            if attempt == 1 { throw ChatGPTError.offline }
            return renewed
        }
        let store = makeStore(credentials: credentials, auth: auth)

        await assertError(.offline) { try await self.explain(store) }
        XCTAssertEqual(try credentials.vault().sessions, [old])
        XCTAssertFalse(store.needsReauthentication)
        let text = try await explain(store)
        XCTAssertEqual(text, "a riverbank")
        XCTAssertEqual(auth.refreshes.map(\.refreshToken), [old.refreshToken, old.refreshToken])
        XCTAssertEqual(try credentials.vault().sessions, [renewed])
    }

    func testTerminalRefreshFailureClearsTokensButRetainsRegistration() async throws {
        let old = session("a", expired: true)
        let credentials = try storage([old], active: old.registration)
        let auth = AccountStoreTestAuth()
        auth.onRefresh = { _ in throw ChatGPTError.loginExpired }
        let store = makeStore(credentials: credentials, auth: auth)

        await assertError(.loginExpired) { try await self.explain(store) }
        XCTAssertEqual(store.activeClientID, old.registration.clientID)
        XCTAssertTrue(store.needsReauthentication)
        XCTAssertEqual(store.savedAccounts, [old.registration])
        XCTAssertEqual(try credentials.vault().registrations, [old.registration])
        XCTAssertTrue(try credentials.vault().sessions.isEmpty)
        await assertError(.loginExpired) { try await self.explain(store) }
        XCTAssertEqual(auth.refreshes.count, 1)
    }

    func testIdentityOnlySessionRequiresConsentWithoutCallingInference() async throws {
        let identityOnly = session("a", scopes: ["openid", "profile", "email"])
        let credentials = try storage([identityOnly], active: identityOnly.registration)
        let auth = AccountStoreTestAuth()
        let client = AccountStoreTestClient()
        let store = makeStore(credentials: credentials, auth: auth, client: client)

        XCTAssertTrue(store.isSignedIn)
        XCTAssertTrue(store.needsAuthorization)
        await assertError(.missingPlanPermission) { try await self.explain(store) }
        XCTAssertTrue(auth.refreshes.isEmpty)
        XCTAssertTrue(client.modelTokens.isEmpty)
        XCTAssertTrue(client.explanationTokens.isEmpty)
        XCTAssertEqual(try credentials.vault().sessions, [identityOnly])
    }

    func testRefreshRemovingPlanPermissionSavesNewTokensAndRequestsConsent() async throws {
        let old = session("a", expired: true)
        let identityOnly = session("a", suffix: "renewed", scopes: ["openid", "profile", "email"])
        let credentials = try storage([old], active: old.registration)
        let auth = AccountStoreTestAuth()
        auth.onRefresh = { _ in identityOnly }
        let client = AccountStoreTestClient()
        let store = makeStore(credentials: credentials, auth: auth, client: client)

        await assertError(.missingPlanPermission) { try await self.explain(store) }
        XCTAssertEqual(try credentials.vault().sessions, [identityOnly])
        XCTAssertTrue(store.needsAuthorization)
        XCTAssertFalse(store.needsReauthentication)
        XCTAssertTrue(client.explanationTokens.isEmpty)
    }

    func testQuotaFailurePausesBackgroundRequestsUntilExplicitReset() async throws {
        let current = session("a")
        let credentials = try storage([current], active: current.registration)
        let client = AccountStoreTestClient()
        var blocked = true
        client.onExplain = { _ in
            if blocked { throw ChatGPTError.usageLimit }
            return "a riverbank"
        }
        let store = makeStore(credentials: credentials, client: client)

        await assertError(.usageLimit) { try await self.explain(store) }
        blocked = false
        await assertError(.usageLimit) { try await self.explain(store) }
        XCTAssertEqual(client.explanationTokens.count, 1)
        XCTAssertEqual(store.issue, .usageLimit)
        store.resetUsageBlock()
        let text = try await explain(store)
        XCTAssertEqual(text, "a riverbank")
        XCTAssertEqual(client.explanationTokens.count, 2)
        XCTAssertNil(store.issue)
    }

    func testSwitchingAccountWhileRefreshingPreservesRotatedOldAccountToken() async throws {
        let a = session("a", expired: true)
        let b = session("b")
        let renewedA = session("a", suffix: "renewed")
        let credentials = try storage([a, b], active: a.registration)
        let auth = AccountStoreTestAuth()
        let client = AccountStoreTestClient()
        let gate = AccountStoreTestGate<ChatGPTSession>()
        let started = expectation(description: "A refresh entered")
        auth.onRefresh = { _ in started.fulfill(); return try await gate.wait() }
        let store = makeStore(credentials: credentials, auth: auth, client: client)

        let pendingA = explanation(store)
        await fulfillment(of: [started], timeout: 2)
        store.selectAccount(b.registration)
        gate.succeed(renewedA)
        await assertCancelled(pendingA)

        let saved = try credentials.vault()
        XCTAssertEqual(saved.activeClientID, b.registration.clientID)
        XCTAssertEqual(saved.sessions.first { $0.registration == a.registration }, renewedA)
        XCTAssertEqual(store.activeClientID, b.registration.clientID)
        XCTAssertFalse(store.needsReauthentication)
        XCTAssertTrue(client.explanationTokens.isEmpty)
        _ = try await explain(store)
        XCTAssertEqual(client.explanationTokens, [b.accessToken])
        XCTAssertEqual(auth.refreshes.count, 1)
    }

    func testOldAccountUnauthorizedResponseDoesNotRefreshOrCallNewAccount() async throws {
        let a = session("a")
        let b = session("b")
        let credentials = try storage([a, b], active: a.registration)
        let auth = AccountStoreTestAuth()
        let client = AccountStoreTestClient()
        let started = expectation(description: "A inference entered")
        let gate = AccountStoreTestGate<String>()
        client.onExplain = { token in
            if token == a.accessToken { started.fulfill(); return try await gate.wait() }
            return "a riverbank"
        }
        let store = makeStore(credentials: credentials, auth: auth, client: client)

        let pendingA = explanation(store)
        await fulfillment(of: [started], timeout: 2)
        store.selectAccount(b.registration)
        gate.fail(ChatGPTError.invalidAuthorization)
        await assertCancelled(pendingA)

        XCTAssertEqual(client.explanationTokens, [a.accessToken])
        XCTAssertTrue(auth.refreshes.isEmpty)
        XCTAssertEqual(store.activeClientID, b.registration.clientID)
        XCTAssertFalse(store.needsReauthentication)
        XCTAssertNil(store.issue)
        _ = try await explain(store)
        XCTAssertEqual(client.explanationTokens, [a.accessToken, b.accessToken])
    }

    func testSignOutWaitsForRefreshAndRevokesNewestToken() async throws {
        let old = session("a", expired: true)
        let renewed = session("a", suffix: "renewed")
        let credentials = try storage([old], active: old.registration)
        let auth = AccountStoreTestAuth()
        let client = AccountStoreTestClient()
        let started = expectation(description: "Refresh entered")
        let finished = expectation(description: "Sign out completed")
        let gate = AccountStoreTestGate<ChatGPTSession>()
        auth.onRefresh = { _ in started.fulfill(); return try await gate.wait() }
        let store = makeStore(credentials: credentials, auth: auth, client: client)
        let observer = store.$isSigningOut.dropFirst().filter { !$0 }.prefix(1).sink { _ in finished.fulfill() }
        defer { observer.cancel() }

        let pending = explanation(store)
        await fulfillment(of: [started], timeout: 2)
        store.signOut()
        XCTAssertTrue(store.isSigningOut)
        XCTAssertTrue(auth.revocations.isEmpty)
        gate.succeed(renewed)
        await fulfillment(of: [finished], timeout: 2)
        await assertCancelled(pending)

        XCTAssertEqual(auth.revocations.map(\.refreshToken), [renewed.refreshToken])
        XCTAssertFalse(store.isSignedIn)
        XCTAssertFalse(store.isSigningOut)
        XCTAssertTrue(client.explanationTokens.isEmpty)
        let saved = try credentials.vault()
        XCTAssertNil(saved.activeClientID)
        XCTAssertEqual(saved.registrations, [old.registration])
        XCTAssertTrue(saved.sessions.isEmpty)
    }

    func testRotatedTokenSurvivesKeychainFailureAndIsPersistedBeforeNextCall() async throws {
        let old = session("a", expired: true)
        let renewed = session("a", suffix: "renewed")
        let credentials = try storage([old], active: old.registration)
        let auth = AccountStoreTestAuth()
        auth.onRefresh = { _ in renewed }
        let client = AccountStoreTestClient()
        let store = makeStore(credentials: credentials, auth: auth, client: client)
        credentials.failWrites = true

        await assertError(.storage) { try await self.explain(store) }
        XCTAssertEqual(try credentials.vault().sessions, [old])
        XCTAssertTrue(client.explanationTokens.isEmpty)
        XCTAssertEqual(auth.refreshes.count, 1)
        credentials.failWrites = false
        _ = try await explain(store)

        XCTAssertEqual(auth.refreshes.count, 1, "The consumed refresh token must never be retried")
        XCTAssertEqual(try credentials.vault().sessions, [renewed])
        XCTAssertEqual(client.explanationTokens, [renewed.accessToken])
        XCTAssertNil(store.issue)
    }

    func testFailedNewAccountLoginPreservesExistingAccountAndSession() async throws {
        let a = session("a")
        let credentials = try storage([a], active: a.registration)
        let originalData = credentials.data
        let auth = AccountStoreTestAuth()
        auth.onSignIn = { _, _, _, _ in throw ChatGPTError.authorizationDenied }
        let store = makeStore(credentials: credentials, auth: auth)

        await signIn(store, anotherAccount: true)
        XCTAssertEqual(store.issue, .authorizationDenied)
        XCTAssertEqual(store.activeClientID, a.registration.clientID)
        XCTAssertEqual(store.savedAccounts, [a.registration])
        XCTAssertEqual(credentials.data, originalData)
        XCTAssertEqual(try credentials.vault().sessions, [a])
        let text = try await explain(store)
        XCTAssertEqual(text, "a riverbank")
    }

    func testNewInteractiveLoginCannotBeOverwrittenByOlderRefresh() async throws {
        let old = session("a", expired: true)
        let refreshed = session("a", suffix: "old-refresh-result")
        let interactive = session("a", suffix: "interactive")
        let credentials = try storage([old], active: old.registration)
        let auth = AccountStoreTestAuth()
        let started = expectation(description: "Old refresh entered")
        let gate = AccountStoreTestGate<ChatGPTSession>()
        auth.onRefresh = { _ in started.fulfill(); return try await gate.wait() }
        auth.onSignIn = { _, previous, _, _ in
            XCTAssertEqual(previous, old.registration)
            return interactive
        }
        let client = AccountStoreTestClient()
        let store = makeStore(credentials: credentials, auth: auth, client: client)

        let pending = explanation(store)
        await fulfillment(of: [started], timeout: 2)
        await signIn(store)
        gate.succeed(refreshed)
        await assertCancelled(pending)

        XCTAssertEqual(try credentials.vault().sessions, [interactive])
        XCTAssertEqual(store.activeClientID, interactive.registration.clientID)
        _ = try await explain(store)
        XCTAssertEqual(client.explanationTokens, [interactive.accessToken])
        XCTAssertEqual(auth.refreshes.count, 1)
    }

    func testUnreadableKeychainCannotBeOverwrittenByNewLogin() async throws {
        let a = session("a")
        let credentials = try storage([a], active: a.registration)
        let originalData = credentials.data
        credentials.failReads = true
        let auth = AccountStoreTestAuth()
        let store = makeStore(credentials: credentials, auth: auth)

        store.connectAnotherAccount()
        XCTAssertEqual(store.issue, .storage)
        XCTAssertFalse(store.isSigningIn)
        XCTAssertEqual(auth.signInCount, 0)
        XCTAssertEqual(credentials.writeCount, 0)
        XCTAssertEqual(credentials.data, originalData)
    }

    func testSignInAfterRestartAndSignOutReusesTheSelectedRegistration() async throws {
        let a = session("a")
        let b = session("b")
        let credentials = try storage([a, b], active: b.registration)
        let auth = AccountStoreTestAuth()
        let store = makeStore(credentials: credentials, auth: auth)
        let finished = expectation(description: "Signed out")
        let observer = store.$isSigningOut.dropFirst().filter { !$0 }.prefix(1).sink { _ in finished.fulfill() }
        store.signOut()
        await fulfillment(of: [finished], timeout: 2)
        observer.cancel()
        XCTAssertFalse(store.isSignedIn)
        XCTAssertEqual(try credentials.vault().sessions, [a])

        let reopened = makeStore(credentials: credentials, auth: auth)
        auth.onSignIn = { _, previous, hint, _ in
            XCTAssertEqual(previous, b.registration)
            XCTAssertNil(hint, "Signed-out ID tokens must not become login hints")
            return self.session("b", suffix: "signed-back-in")
        }
        await signIn(reopened)
        XCTAssertEqual(reopened.activeClientID, b.registration.clientID)
        XCTAssertNil(reopened.issue)
    }

    func testRemoteSignOutFailureStillClearsLocalTokensAndExplainsTheLimitation() async throws {
        let a = session("a")
        let credentials = try storage([a], active: a.registration)
        let auth = AccountStoreTestAuth()
        auth.onRevoke = { _ in throw ChatGPTError.offline }
        let store = makeStore(credentials: credentials, auth: auth)
        let finished = expectation(description: "Local sign-out completed")
        let observer = store.$isSigningOut.dropFirst().filter { !$0 }.prefix(1).sink { _ in finished.fulfill() }
        store.signOut()
        await fulfillment(of: [finished], timeout: 2)
        observer.cancel()
        XCTAssertFalse(store.isSignedIn)
        XCTAssertTrue(try credentials.vault().sessions.isEmpty)
        XCTAssertEqual(store.issue, .signOutUnconfirmed)
        XCTAssertEqual(auth.revocations, [a])
    }

    func testCancelledCallerDoesNotLoseASuccessfullyRotatedCredential() async throws {
        let old = session("a", expired: true)
        let renewed = session("a", suffix: "renewed")
        let credentials = try storage([old], active: old.registration)
        let auth = AccountStoreTestAuth()
        let gate = AccountStoreTestGate<ChatGPTSession>()
        let started = expectation(description: "Refresh started")
        auth.onRefresh = { _ in started.fulfill(); return try await gate.wait() }
        let store = makeStore(credentials: credentials, auth: auth)
        let pending = explanation(store)
        await fulfillment(of: [started], timeout: 2)
        pending.cancel()
        gate.succeed(renewed)
        await assertCancelled(pending)
        XCTAssertEqual(try credentials.vault().sessions, [renewed])
        XCTAssertNil(store.issue)
        _ = try await explain(store)
        XCTAssertEqual(auth.refreshes.count, 1)
    }

    func testInactiveRefreshCannotClearAnotherAccountsRequiredSignIn() async throws {
        let a = session("a", expired: true)
        let renewedA = session("a", suffix: "renewed")
        let b = session("b")
        let renewedB = session("b", suffix: "renewed")
        let interactiveB = session("b", suffix: "interactive")
        let credentials = try storage([a, b], active: a.registration)
        let auth = AccountStoreTestAuth()
        let client = AccountStoreTestClient()
        let started = expectation(description: "A refresh entered")
        let gate = AccountStoreTestGate<ChatGPTSession>()
        auth.onRefresh = { old in
            if old.registration == a.registration {
                started.fulfill()
                return try await gate.wait()
            }
            XCTAssertEqual(old.registration, b.registration)
            return renewedB
        }
        client.onExplain = { _ in throw ChatGPTError.invalidAuthorization }
        let store = makeStore(credentials: credentials, auth: auth, client: client)

        let pendingA = explanation(store)
        await fulfillment(of: [started], timeout: 2)
        store.selectAccount(b.registration)
        await assertError(.loginExpired) { try await self.explain(store) }
        XCTAssertEqual(client.explanationTokens, [b.accessToken, renewedB.accessToken])
        XCTAssertTrue(store.needsReauthentication)

        gate.succeed(renewedA)
        await assertCancelled(pendingA)
        XCTAssertEqual(try credentials.vault().sessions.first { $0.registration == a.registration }, renewedA)
        XCTAssertEqual(store.activeClientID, b.registration.clientID)
        XCTAssertTrue(store.needsReauthentication, "An inactive refresh must not make B appear connected again")
        await assertError(.loginExpired) { try await self.explain(store) }
        XCTAssertEqual(auth.refreshes.count, 2)
        XCTAssertEqual(client.explanationTokens.count, 2)

        auth.onSignIn = { _, previous, _, _ in
            XCTAssertEqual(previous, b.registration)
            return interactiveB
        }
        client.onExplain = { _ in "a riverbank" }
        await signIn(store)
        XCTAssertFalse(store.needsReauthentication)
        _ = try await explain(store)
        XCTAssertEqual(client.explanationTokens.last, interactiveB.accessToken)
        XCTAssertEqual(auth.refreshes.count, 2)
    }

    func testFailedCandidateAccountNeverChangesProductionIdentityOrQuotaBlock() async throws {
        let a = session("a")
        let b = session("b")
        let credentials = try storage([a, b], active: a.registration)
        let client = AccountStoreTestClient()
        client.onExplain = { token in
            if token == b.accessToken { throw ChatGPTError.insufficientCredits }
            return "a riverbank"
        }
        let store = makeStore(credentials: credentials, client: client)
        store.beginConfiguration()
        store.selectConfigurationAccount(b.registration)

        do { try await store.validateConfigurationCandidate(); XCTFail("Expected candidate failure") }
        catch { XCTAssertEqual(error as? ChatGPTError, .insufficientCredits) }

        XCTAssertEqual(store.activeClientID, a.registration.clientID)
        XCTAssertEqual(try credentials.vault().activeClientID, a.registration.clientID)
        XCTAssertNil(store.issue)
        let text = try await explain(store)
        XCTAssertEqual(text, "a riverbank")
        XCTAssertEqual(client.explanationTokens.last, a.accessToken)
        XCTAssertEqual(store.configurationIssue, .insufficientCredits)
    }

    func testSigningOutConfigurationCandidatePreservesPreviousProductionAccount() async throws {
        let active = session("active")
        let candidate = session("candidate")
        let credentials = try storage([active, candidate], active: active.registration)
        let auth = AccountStoreTestAuth()
        let store = makeStore(credentials: credentials, auth: auth)
        store.beginConfiguration()
        store.selectConfigurationAccount(candidate.registration)
        let finished = expectation(description: "Candidate signs out")
        let observation = store.$isSigningOut.dropFirst().filter { !$0 }.prefix(1).sink { _ in finished.fulfill() }
        store.signOutConfiguration()
        await fulfillment(of: [finished], timeout: 2)
        observation.cancel()

        XCTAssertNil(store.configurationClientID)
        XCTAssertEqual(store.activeClientID, active.registration.clientID)
        XCTAssertEqual(try credentials.vault().activeClientID, active.registration.clientID)
        XCTAssertEqual(try credentials.vault().sessions.map(\.registration.clientID), [active.registration.clientID])
        XCTAssertEqual(auth.revocations.map(\.registration.clientID), [candidate.registration.clientID])
    }

    func testValidatedCandidateBecomesProductionOnlyAfterCommit() async throws {
        let a = session("a")
        let b = session("b")
        let credentials = try storage([a, b], active: a.registration)
        let client = AccountStoreTestClient()
        let store = makeStore(credentials: credentials, client: client)
        store.beginConfiguration()
        store.selectConfigurationAccount(b.registration)
        try await store.validateConfigurationCandidate()
        XCTAssertEqual(store.activeClientID, a.registration.clientID)
        _ = try await explain(store)
        XCTAssertEqual(client.explanationTokens.last, a.accessToken)

        try store.commitConfigurationCandidate()
        XCTAssertEqual(store.activeClientID, b.registration.clientID)
        XCTAssertEqual(try credentials.vault().activeClientID, b.registration.clientID)
        _ = try await explain(store)
        XCTAssertEqual(client.explanationTokens.last, b.accessToken)
    }

    func testCandidateCommitFailurePreservesOldIdentityAndCanRetryWithoutInference() async throws {
        let a = session("a")
        let b = session("b")
        let credentials = try storage([a, b], active: a.registration)
        let client = AccountStoreTestClient()
        let store = makeStore(credentials: credentials, client: client)
        store.beginConfiguration()
        store.selectConfigurationAccount(b.registration)
        try await store.validateConfigurationCandidate()
        credentials.failWrites = true
        XCTAssertThrowsError(try store.commitConfigurationCandidate())
        XCTAssertEqual(store.activeClientID, a.registration.clientID)
        XCTAssertEqual(try credentials.vault().activeClientID, a.registration.clientID)
        credentials.failWrites = false
        try store.commitConfigurationCandidate()
        XCTAssertEqual(store.activeClientID, b.registration.clientID)
        XCTAssertEqual(client.explanationTokens, [b.accessToken])
    }

    func testCandidateAndProductionShareRefreshEvenWhenCandidateIsCancelled() async throws {
        let old = session("a", expired: true)
        let renewed = session("a", suffix: "renewed")
        let credentials = try storage([old], active: old.registration)
        let auth = AccountStoreTestAuth()
        let entered = expectation(description: "Shared refresh entered")
        let gate = AccountStoreTestGate<ChatGPTSession>()
        auth.onRefresh = { _ in entered.fulfill(); return try await gate.wait() }
        let client = AccountStoreTestClient()
        let store = makeStore(credentials: credentials, auth: auth, client: client)
        let production = explanation(store)
        await fulfillment(of: [entered], timeout: 2)
        store.beginConfiguration()
        let candidate = Task {
            try await store.validateConfigurationCandidate()
            return "validated"
        }
        for _ in 0..<20 { await Task.yield() }
        candidate.cancel()
        store.endConfiguration()
        gate.succeed(renewed)
        let text = try await production.value
        XCTAssertEqual(text, "a riverbank")
        await assertCancelled(candidate)
        XCTAssertEqual(auth.refreshes.count, 1)
        XCTAssertEqual(try credentials.vault().sessions, [renewed])
        XCTAssertEqual(client.explanationTokens, [renewed.accessToken])
    }

    func testLeavingConfigurationCancelsLateBrowserLoginWithoutActivatingOrSavingIt() async throws {
        let a = session("a")
        let b = session("b")
        let credentials = try storage([a], active: a.registration)
        let auth = AccountStoreTestAuth()
        let entered = expectation(description: "Candidate sign-in entered")
        let gate = AccountStoreTestGate<ChatGPTSession>()
        auth.onSignIn = { _, _, _, _ in entered.fulfill(); return try await gate.wait() }
        let store = makeStore(credentials: credentials, auth: auth)
        store.beginConfiguration()
        store.signInConfiguration(otherAccount: true)
        await fulfillment(of: [entered], timeout: 2)
        store.endConfiguration()
        gate.succeed(b)
        for _ in 0..<30 { await Task.yield() }
        XCTAssertFalse(store.isConfigurationSigningIn)
        XCTAssertEqual(store.activeClientID, a.registration.clientID)
        XCTAssertEqual(try credentials.vault().sessions, [a])
        XCTAssertNil(store.configurationIssue)
    }

    func testCancelledProductionErrorCannotWriteQuotaIssue() async throws {
        let a = session("a")
        let credentials = try storage([a], active: a.registration)
        let client = AccountStoreTestClient()
        let entered = expectation(description: "Inference entered")
        let gate = AccountStoreTestGate<String>()
        client.onExplain = { _ in entered.fulfill(); return try await gate.wait() }
        let store = makeStore(credentials: credentials, client: client)
        let task = explanation(store)
        await fulfillment(of: [entered], timeout: 2)
        task.cancel()
        gate.fail(ChatGPTError.insufficientCredits)
        await assertCancelled(task)
        XCTAssertNil(store.issue)
        client.onExplain = { _ in "a riverbank" }
        let text = try await explain(store)
        XCTAssertEqual(text, "a riverbank")
    }

    private func makeStore(credentials: AccountStoreTestStorage,
                           auth: AccountStoreTestAuth? = nil,
                           client: AccountStoreTestClient? = nil) -> ChatGPTAccountStore {
        let defaults = UserDefaults(suiteName: "ChatGPTAccountStoreTests." + UUID().uuidString)!
        return ChatGPTAccountStore(defaults: defaults, credentials: credentials, auth: auth ?? AccountStoreTestAuth(),
                                   client: client ?? AccountStoreTestClient(), now: { self.date })
    }

    private func session(_ account: String, suffix: String = "saved", expired: Bool = false,
                         scopes: Set<String> = ["openid", "chatgpt.tokens.use.direct"]) -> ChatGPTSession {
        ChatGPTSession(registration: .init(clientID: "oaiapp_" + account, subject: "user-" + account,
                                          email: account + "@example.com"),
                       accessToken: account + "-" + suffix + "-access",
                       refreshToken: account + "-" + suffix + "-refresh", idToken: account + "-id",
                       expiresAt: date.addingTimeInterval(expired ? -10 : 3600),
                       refreshExpiresAt: date.addingTimeInterval(86_400), scopes: scopes, earliestRefreshAt: nil)
    }

    private func storage(_ sessions: [ChatGPTSession], active: ChatGPTRegistration) throws -> AccountStoreTestStorage {
        let vault = AccountStoreTestVault(registrations: sessions.map(\.registration), sessions: sessions,
                                         activeClientID: active.clientID)
        return AccountStoreTestStorage(data: try JSONEncoder().encode(vault))
    }

    private func explain(_ store: ChatGPTAccountStore) async throws -> String {
        try await store.explain(selection: "bank", context: "She sat on the bank.", language: .english)
    }

    private func explanation(_ store: ChatGPTAccountStore) -> Task<String, Error> {
        Task { try await self.explain(store) }
    }

    private func signIn(_ store: ChatGPTAccountStore, anotherAccount: Bool = false) async {
        let finished = expectation(description: "Sign in completed")
        let observer = store.$isSigningIn.dropFirst().filter { !$0 }.prefix(1).sink { _ in finished.fulfill() }
        if anotherAccount { store.connectAnotherAccount() } else { store.signIn() }
        await fulfillment(of: [finished], timeout: 2)
        observer.cancel()
    }

    private func assertError(_ expected: ChatGPTError, file: StaticString = #filePath, line: UInt = #line,
                             operation: () async throws -> String) async {
        do { _ = try await operation(); XCTFail("Expected \(expected)", file: file, line: line) }
        catch { XCTAssertEqual(error as? ChatGPTError, expected, file: file, line: line) }
    }

    private func assertCancelled(_ task: Task<String, Error>, file: StaticString = #filePath, line: UInt = #line) async {
        do { _ = try await task.value; XCTFail("Expected cancellation", file: file, line: line) }
        catch { XCTAssertTrue(error is CancellationError, "Unexpected error: \(error)", file: file, line: line) }
    }
}

private struct AccountStoreTestVault: Codable {
    var registrations: [ChatGPTRegistration]
    var sessions: [ChatGPTSession]
    var activeClientID: String?
}

private final class AccountStoreTestStorage: ChatGPTCredentialStorage {
    var data: Data?
    var failReads = false
    var failWrites = false
    private(set) var writeCount = 0

    init(data: Data?) { self.data = data }

    func read() throws -> Data? {
        if failReads { throw ChatGPTError.storage }
        return data
    }

    func write(_ data: Data?) throws {
        writeCount += 1
        if failWrites { throw ChatGPTError.storage }
        self.data = data
    }

    func vault() throws -> AccountStoreTestVault {
        try JSONDecoder().decode(AccountStoreTestVault.self, from: XCTUnwrap(data))
    }
}

@MainActor
private final class AccountStoreTestAuth: ChatGPTAuthenticating {
    var onSignIn: (String, ChatGPTRegistration?, String?, Bool) async throws -> ChatGPTSession = { _, _, _, _ in
        throw ChatGPTError.authorizationDenied
    }
    var onRefresh: (ChatGPTSession) async throws -> ChatGPTSession = { _ in throw ChatGPTError.loginExpired }
    var onRevoke: (ChatGPTSession) async throws -> Void = { _ in }
    private(set) var signInCount = 0
    private(set) var refreshes: [ChatGPTSession] = []
    private(set) var revocations: [ChatGPTSession] = []

    func signIn(hostID: String, previous: ChatGPTRegistration?, idTokenHint: String?,
                requestConsent: Bool) async throws -> ChatGPTSession {
        signInCount += 1
        return try await onSignIn(hostID, previous, idTokenHint, requestConsent)
    }

    func refresh(_ session: ChatGPTSession) async throws -> ChatGPTSession {
        refreshes.append(session)
        return try await onRefresh(session)
    }

    func revoke(_ session: ChatGPTSession) async throws {
        revocations.append(session)
        try await onRevoke(session)
    }
}

@MainActor
private final class AccountStoreTestClient: ChatGPTServing {
    var onExplain: (String) async throws -> String = { _ in "a riverbank" }
    private(set) var modelTokens: [String] = []
    private(set) var explanationTokens: [String] = []

    func fetchModel(accessToken: String) async throws -> String {
        modelTokens.append(accessToken)
        return "available-model"
    }

    func explain(selection: String, context: String, focusedSentence: String?,
                 purpose: AIExplanationPurpose, language: StudyLanguage,
                 accessToken: String, model: String) async throws -> String {
        explanationTokens.append(accessToken)
        return try await onExplain(accessToken)
    }
}

@MainActor
private final class AccountStoreTestGate<Value> {
    private var continuation: CheckedContinuation<Value, Error>?

    func wait() async throws -> Value {
        try await withCheckedThrowingContinuation { continuation = $0 }
    }

    func succeed(_ value: Value) {
        let pending = continuation
        continuation = nil
        pending?.resume(returning: value)
    }

    func fail(_ error: Error) {
        let pending = continuation
        continuation = nil
        pending?.resume(throwing: error)
    }
}
