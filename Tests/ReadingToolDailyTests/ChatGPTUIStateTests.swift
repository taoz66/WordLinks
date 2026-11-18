import Combine
import Foundation
import XCTest
@testable import ReadingToolDaily

@MainActor
final class ChatGPTUIStateTests: XCTestCase {
    private let date = Date(timeIntervalSince1970: 2_000_000_000)
    private let text = "She sat on the bank. The river was quiet."

    func testAccountSwitchEndsBothLookupAndPrefillLoadingWithoutPublishingOldResults() async throws {
        let a = session("a")
        let b = session("b")
        let auth = UIStateAuth()
        let client = UIStateClient()
        let lookupGate = UIStateGate<String>()
        let prefillGate = UIStateGate<String>()
        let started = expectation(description: "Both old-account requests started")
        started.expectedFulfillmentCount = 2
        client.onExplain = { token, purpose in
            XCTAssertEqual(token, a.accessToken)
            started.fulfill()
            switch purpose {
            case .lookup: return try await lookupGate.wait()
            case .translation, .intensive: return "unexpected translation"
            case .prefill: return try await prefillGate.wait()
            }
        }
        let store = try makeStore(sessions: [a, b], active: a.registration, auth: auth, client: client)
        let settings = makeSettings(store)
        let lookup = try makeLookup()
        let draft = CardEditorDraft(expression: "bank", meaning: "")
        defer { lookup.cancel(); draft.cancelPendingRequest() }

        lookup.start(settings: settings)
        draft.start(article: article, range: selectedRange, settings: settings)
        await fulfillment(of: [started], timeout: 2)
        let lookupFinished = expectation(description: "Lookup leaves loading")
        let prefillFinished = expectation(description: "Prefill leaves loading")
        let lookupObserver = lookup.$phase.filter { phase in
            if case .loading = phase { return false }; return true
        }.prefix(1).sink { _ in lookupFinished.fulfill() }
        let prefillObserver = draft.$phase.filter { phase in
            if case .loading = phase { return false }; return true
        }.prefix(1).sink { _ in prefillFinished.fulfill() }
        defer { lookupObserver.cancel(); prefillObserver.cancel() }

        store.selectAccount(b.registration)
        lookupGate.succeed("stale lookup from A")
        prefillGate.succeed("stale prefill from A")
        await fulfillment(of: [lookupFinished, prefillFinished], timeout: 2)

        guard case .failed(let lookupIssue) = lookup.phase else {
            return XCTFail("A stale lookup must finish with a retryable interruption")
        }
        XCTAssertEqual(lookupIssue, .configurationChanged)
        guard case .failed = draft.phase else { return XCTFail("A stale prefill must leave loading") }
        XCTAssertEqual(draft.lastIssue, .configurationChanged)
        XCTAssertNil(draft.suggestion)
        XCTAssertEqual(draft.manualMeaning, "")
        XCTAssertEqual(store.activeClientID, b.registration.clientID)
    }

    func testSignOutDuringLookupReturnsToSignInInsteadOfRemainingLoading() async throws {
        let current = session("a")
        let client = UIStateClient()
        let gate = UIStateGate<String>()
        let started = expectation(description: "Lookup started")
        client.onExplain = { _, _ in started.fulfill(); return try await gate.wait() }
        let store = try makeStore(sessions: [current], active: current.registration, client: client)
        let lookup = try makeLookup()
        defer { lookup.cancel() }
        lookup.start(settings: makeSettings(store))
        await fulfillment(of: [started], timeout: 2)
        await signOut(store)

        let finished = expectation(description: "Signed-out lookup leaves loading")
        let observer = lookup.$phase.filter { phase in
            if case .loading = phase { return false }; return true
        }.prefix(1).sink { _ in finished.fulfill() }
        defer { observer.cancel() }
        gate.succeed("stale text")
        await fulfillment(of: [finished], timeout: 2)
        guard case .needsConfiguration = lookup.phase else {
            return XCTFail("An invalidated signed-out lookup should offer sign-in")
        }
    }

    func testUnconfirmedRemoteSignOutDoesNotBlockLookupOrCardSignInEntry() async throws {
        let current = session("a")
        let auth = UIStateAuth()
        auth.onRevoke = { _ in throw ChatGPTError.offline }
        let client = UIStateClient()
        let store = try makeStore(sessions: [current], active: current.registration, auth: auth, client: client)
        await signOut(store)
        XCTAssertEqual(store.issue, .signOutUnconfirmed)
        XCTAssertFalse(store.isSignedIn)

        let settings = makeSettings(store)
        let lookup = try makeLookup()
        let draft = CardEditorDraft(expression: "bank", meaning: "")
        lookup.start(settings: settings)
        draft.start(article: article, range: selectedRange, settings: settings)
        guard case .needsConfiguration = lookup.phase else { return XCTFail("Lookup should offer sign-in") }
        guard case .needsConfiguration = draft.phase else { return XCTFail("Card should offer sign-in") }
        XCTAssertNil(draft.lastIssue)
        XCTAssertEqual(client.explanationCount, 0)
    }

    func testUnreadableCredentialsAreShownAsStorageFailureInsteadOfSignInEntry() throws {
        let credentials = UIStateCredentials(data: nil)
        credentials.failReads = true
        let store = ChatGPTAccountStore(defaults: makeDefaults(), credentials: credentials,
                                       auth: UIStateAuth(), client: UIStateClient(), now: { self.date })
        let settings = makeSettings(store)
        let lookup = try makeLookup()
        let draft = CardEditorDraft(expression: "bank", meaning: "")
        lookup.start(settings: settings)
        draft.start(article: article, range: selectedRange, settings: settings)
        guard case .failed(let issue) = lookup.phase else { return XCTFail("Expected storage failure") }
        XCTAssertEqual(issue, .chatGPT(.storage))
        XCTAssertEqual(draft.lastIssue, .chatGPT(.storage))
        guard case .failed = draft.phase else { return XCTFail("Expected card storage failure") }
    }

    func testSuccessfulReauthenticationResumesExpiredCardPrefill() async throws {
        let expired = session("a", expired: true)
        let renewed = session("a", expired: false)
        let auth = UIStateAuth()
        auth.onSignIn = { renewed }
        let client = UIStateClient()
        let store = try makeStore(sessions: [expired], active: expired.registration, auth: auth, client: client)
        let settings = makeSettings(store)
        let editor = CardEditorSession(article: article, selectedRange: selectedRange,
                                       existingCard: nil, prefillEnabled: true)
        await waitForDraft(editor.draft, matching: { phase in
            if case .failed = phase { return true }; return false
        }) { editor.appear(settings: settings) }
        XCTAssertEqual(editor.draft.lastIssue, .chatGPT(.loginExpired))
        XCTAssertEqual(client.explanationCount, 0)

        await signIn(store)
        XCTAssertNil(store.issue)
        await waitForDraft(editor.draft, matching: { phase in
            if case .ready = phase { return true }; return false
        }) { editor.resumePrefillAfterSignIn(settings: settings) }
        XCTAssertEqual(editor.draft.suggestion, "a riverbank")
        XCTAssertEqual(editor.draft.meaningToSave, "a riverbank")
        XCTAssertEqual(client.explanationCount, 1)
    }

    func testManualMeaningIsPreservedWhenLoginCompletesAfterExpiredPrefill() async throws {
        let expired = session("a", expired: true)
        let renewed = session("a", expired: false)
        let auth = UIStateAuth()
        auth.onSignIn = { renewed }
        let client = UIStateClient()
        let store = try makeStore(sessions: [expired], active: expired.registration, auth: auth, client: client)
        let settings = makeSettings(store)
        let editor = CardEditorSession(article: article, selectedRange: selectedRange,
                                       existingCard: nil, prefillEnabled: true)
        await waitForDraft(editor.draft, matching: { phase in
            if case .failed = phase { return true }; return false
        }) { editor.appear(settings: settings) }
        XCTAssertEqual(editor.draft.lastIssue, .chatGPT(.loginExpired))
        editor.draft.updateManualMeaning("my own meaning")
        await signIn(store)
        editor.resumePrefillAfterSignIn(settings: settings)

        guard case .idle = editor.draft.phase else { return XCTFail("Manual edits should keep prefill idle") }
        XCTAssertEqual(editor.draft.manualMeaning, "my own meaning")
        XCTAssertEqual(editor.draft.meaningToSave, "my own meaning")
        XCTAssertNil(editor.draft.suggestion)
        XCTAssertEqual(client.explanationCount, 0)
    }

    func testCustomProviderExplainsAndPrefillsWithoutChatGPTSignIn() async throws {
        let chatClient = UIStateClient()
        let store = makeSignedOutStore(client: chatClient)
        let customClient = UIStateCustomClient()
        let settings = makeCustomSettings(store: store, client: customClient)
        let profileID = try configureCustom(settings)
        let lookup = try makeLookup()
        let draft = CardEditorDraft(expression: "bank", meaning: "")
        defer { lookup.cancel(); draft.cancelPendingRequest() }

        await waitForLookup(lookup, matching: { phase in
            if case .explained = phase { return true }; return false
        }) { lookup.start(settings: settings) }
        await waitForDraft(draft, matching: { phase in
            if case .ready = phase { return true }; return false
        }) { draft.start(article: article, range: selectedRange, settings: settings) }

        guard case .explained(let explanation) = lookup.phase else { return XCTFail("Custom lookup did not complete") }
        XCTAssertEqual(explanation, "custom riverbank")
        XCTAssertEqual(draft.meaningToSave, "custom riverbank")
        XCTAssertEqual(settings.selectedService, .custom(profileID))
        XCTAssertFalse(store.isSignedIn)
        XCTAssertEqual(customClient.explanationCount, 2)
        XCTAssertEqual(chatClient.explanationCount, 0)
    }

    func testAskAIUsesAutomaticTranslationPurposeForACompleteSentence() async throws {
        let current = session("translation")
        let client = UIStateClient()
        client.onExplain = { _, purpose in
            XCTAssertEqual(purpose, .translation)
            return "她坐在河岸上。"
        }
        let store = try makeStore(sessions: [current], active: current.registration, client: client)
        let settings = makeSettings(store)
        let selection = try SelectionContext.extract(from: text,
            range: (text as NSString).range(of: "She sat on the bank"))
        let model = AIExplanationModel(selection: selection)
        XCTAssertEqual(model.purpose, .translation)
        defer { model.cancel() }

        await waitForLookup(model, matching: { phase in
            if case .explained = phase { return true }; return false
        }) { model.start(settings: settings) }

        guard case .explained(let result) = model.phase else { return XCTFail("Translation did not complete") }
        XCTAssertEqual(result, "她坐在河岸上。")
    }

    func testProviderSwitchDiscardsOldCustomLookupAndPrefillResults() async throws {
        let current = session("a")
        let chatClient = UIStateClient()
        chatClient.onExplain = { _, _ in "fresh ChatGPT result" }
        let store = try makeStore(sessions: [current], active: current.registration, client: chatClient)
        let customClient = UIStateCustomClient()
        let lookupGate = UIStateGate<String>()
        let prefillGate = UIStateGate<String>()
        let started = expectation(description: "Both custom requests started")
        started.expectedFulfillmentCount = 2
        customClient.onExplain = { purpose, _ in
            started.fulfill()
            switch purpose {
            case .lookup: return try await lookupGate.wait()
            case .translation, .intensive: return "unexpected translation"
            case .prefill: return try await prefillGate.wait()
            }
        }
        let settings = makeCustomSettings(store: store, client: customClient)
        _ = try configureCustom(settings)
        let lookup = try makeLookup()
        let draft = CardEditorDraft(expression: "bank", meaning: "")
        defer { lookup.cancel(); draft.cancelPendingRequest() }
        lookup.start(settings: settings)
        draft.start(article: article, range: selectedRange, settings: settings)
        await fulfillment(of: [started], timeout: 2)
        let lookupFinished = expectation(description: "Old custom lookup leaves loading")
        let prefillFinished = expectation(description: "Old custom prefill leaves loading")
        let lookupObserver = lookup.$phase.filter { phase in
            if case .loading = phase { return false }; return true
        }.prefix(1).sink { _ in lookupFinished.fulfill() }
        let prefillObserver = draft.$phase.filter { phase in
            if case .loading = phase { return false }; return true
        }.prefix(1).sink { _ in prefillFinished.fulfill() }
        defer { lookupObserver.cancel(); prefillObserver.cancel() }

        try settings.selectService(.chatGPT)
        lookupGate.succeed("stale custom lookup")
        prefillGate.succeed("stale custom prefill")
        await fulfillment(of: [lookupFinished, prefillFinished], timeout: 2)
        guard case .failed(let issue) = lookup.phase else { return XCTFail("Discarded lookup should offer recovery") }
        XCTAssertEqual(issue, .configurationChanged)
        guard case .failed = draft.phase else { return XCTFail("Discarded prefill should offer recovery") }
        XCTAssertEqual(draft.lastIssue, .configurationChanged)
        XCTAssertNil(draft.suggestion)
        XCTAssertEqual(draft.manualMeaning, "")

        await waitForLookup(lookup, matching: { phase in
            if case .explained = phase { return true }; return false
        }) { lookup.start(settings: settings) }
        guard case .explained(let explanation) = lookup.phase else { return XCTFail("New provider lookup did not complete") }
        XCTAssertEqual(explanation, "fresh ChatGPT result")
        XCTAssertEqual(chatClient.explanationCount, 1)
        XCTAssertEqual(customClient.explanationCount, 2)
    }

    func testSavingCustomConfigurationResumesPreviouslyUnconfiguredPrefill() async throws {
        let chatClient = UIStateClient()
        let store = makeSignedOutStore(client: chatClient)
        let customClient = UIStateCustomClient()
        let settings = makeCustomSettings(store: store, client: customClient)
        let editor = CardEditorSession(article: article, selectedRange: selectedRange,
                                       existingCard: nil, prefillEnabled: true)
        editor.appear(settings: settings)
        guard case .needsConfiguration = editor.draft.phase else { return XCTFail("Expected a configuration entry") }

        _ = try configureCustom(settings)
        await waitForDraft(editor.draft, matching: { phase in
            if case .ready = phase { return true }; return false
        }) { editor.resumePrefillAfterSignIn(settings: settings) }

        XCTAssertEqual(editor.draft.meaningToSave, "custom riverbank")
        XCTAssertEqual(customClient.explanationCount, 1)
        XCTAssertEqual(chatClient.explanationCount, 0)
        XCTAssertFalse(store.isSignedIn)
    }

    func testSavingCustomConfigurationPreservesMeaningTypedWhileUnconfigured() throws {
        let chatClient = UIStateClient()
        let store = makeSignedOutStore(client: chatClient)
        let customClient = UIStateCustomClient()
        let settings = makeCustomSettings(store: store, client: customClient)
        let editor = CardEditorSession(article: article, selectedRange: selectedRange,
                                       existingCard: nil, prefillEnabled: true)
        editor.appear(settings: settings)
        guard case .needsConfiguration = editor.draft.phase else { return XCTFail("Expected a configuration entry") }
        editor.draft.updateManualMeaning("my own meaning")

        _ = try configureCustom(settings)
        editor.resumePrefillAfterSignIn(settings: settings)

        guard case .idle = editor.draft.phase else { return XCTFail("Manual edits must keep prefill idle") }
        XCTAssertEqual(editor.draft.meaningToSave, "my own meaning")
        XCTAssertNil(editor.draft.suggestion)
        XCTAssertEqual(customClient.explanationCount, 0)
        XCTAssertEqual(chatClient.explanationCount, 0)
    }

    private var article: LibraryArticle {
        LibraryArticle(title: "Notes", sourceName: "notes.md", markdown: "# Notes\n\n" + text, text: text)
    }

    private var selectedRange: NSRange { (text as NSString).range(of: "bank") }

    private func makeLookup() throws -> AIExplanationModel {
        AIExplanationModel(selection: try SelectionContext.extract(from: text, range: selectedRange))
    }

    private func makeSettings(_ store: ChatGPTAccountStore) -> AISettingsStore {
        let defaults = makeDefaults()
        return AISettingsStore(defaults: defaults, credentials: UIStateLegacyCredentials(),
                               language: AppLanguageStore(defaults: defaults),
                               customCredentials: UIStateCustomCredentials(), chatGPT: store)
    }

    private func makeCustomSettings(store: ChatGPTAccountStore, client: UIStateCustomClient) -> AISettingsStore {
        let defaults = makeDefaults()
        return AISettingsStore(defaults: defaults, credentials: UIStateLegacyCredentials(),
                               language: AppLanguageStore(defaults: defaults),
                               customCredentials: UIStateCustomCredentials(), customClient: client, chatGPT: store)
    }

    private func makeSignedOutStore(client: UIStateClient) -> ChatGPTAccountStore {
        ChatGPTAccountStore(defaults: makeDefaults(), credentials: UIStateCredentials(data: nil),
                            auth: UIStateAuth(), client: client, now: { self.date })
    }

    private func configureCustom(_ settings: AISettingsStore) throws -> UUID {
        try settings.saveCustomProfile(name: "My API", baseURL: "https://example.com/v1",
                                       apiKey: "custom-key", model: "custom-model",
                                       availableModels: ["custom-model"])
    }

    private func makeDefaults() -> UserDefaults {
        let name = "ChatGPTUIStateTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }

    private func makeStore(sessions: [ChatGPTSession], active: ChatGPTRegistration,
                           auth: UIStateAuth? = nil, client: UIStateClient? = nil) throws -> ChatGPTAccountStore {
        let vault = UIStateVault(registrations: sessions.map(\.registration), sessions: sessions,
                                 activeClientID: active.clientID)
        let credentials = UIStateCredentials(data: try JSONEncoder().encode(vault))
        return ChatGPTAccountStore(defaults: makeDefaults(), credentials: credentials,
                                   auth: auth ?? UIStateAuth(), client: client ?? UIStateClient(), now: { self.date })
    }

    private func session(_ name: String, expired: Bool = false) -> ChatGPTSession {
        ChatGPTSession(registration: .init(clientID: "oaiapp_" + name, subject: "user-" + name,
                                          email: name + "@example.com"),
                       accessToken: name + "-access", refreshToken: name + "-refresh", idToken: name + "-id",
                       expiresAt: date.addingTimeInterval(expired ? -10 : 3600),
                       refreshExpiresAt: date.addingTimeInterval(86_400),
                       scopes: ["openid", "chatgpt.tokens.use.direct"], earliestRefreshAt: nil)
    }

    private func waitForDraft(_ draft: CardEditorDraft,
                              matching predicate: @escaping (CardEditorDraft.Phase) -> Bool,
                              action: () -> Void) async {
        let finished = expectation(description: "Card reaches expected state")
        let observer = draft.$phase.dropFirst().filter(predicate).prefix(1).sink { _ in finished.fulfill() }
        action()
        await fulfillment(of: [finished], timeout: 2)
        observer.cancel()
    }

    private func waitForLookup(_ lookup: AIExplanationModel,
                              matching predicate: @escaping (AIExplanationModel.Phase) -> Bool,
                              action: () -> Void) async {
        let finished = expectation(description: "Lookup reaches expected state")
        let observer = lookup.$phase.dropFirst().filter(predicate).prefix(1).sink { _ in finished.fulfill() }
        action()
        await fulfillment(of: [finished], timeout: 2)
        observer.cancel()
    }

    private func signIn(_ store: ChatGPTAccountStore) async {
        let finished = expectation(description: "Sign-in completed")
        let observer = store.$isSigningIn.dropFirst().filter { !$0 }.prefix(1).sink { _ in finished.fulfill() }
        store.signIn()
        await fulfillment(of: [finished], timeout: 2)
        observer.cancel()
    }

    private func signOut(_ store: ChatGPTAccountStore) async {
        let finished = expectation(description: "Sign-out completed")
        let observer = store.$isSigningOut.dropFirst().filter { !$0 }.prefix(1).sink { _ in finished.fulfill() }
        store.signOut()
        await fulfillment(of: [finished], timeout: 2)
        observer.cancel()
    }
}

private struct UIStateVault: Codable {
    var registrations: [ChatGPTRegistration]
    var sessions: [ChatGPTSession]
    var activeClientID: String?
}

private final class UIStateCredentials: ChatGPTCredentialStorage {
    var data: Data?
    var failReads = false
    init(data: Data?) { self.data = data }
    func read() throws -> Data? {
        if failReads { throw ChatGPTError.storage }
        return data
    }
    func write(_ data: Data?) throws { self.data = data }
}

private struct UIStateLegacyCredentials: AICredentialStorage {
    func read() throws -> String? { nil }
    func write(_ value: String) throws { }
}

private final class UIStateCustomCredentials: AICustomCredentialStorage {
    private var keys = [UUID: String]()
    func read(profileID: UUID) throws -> String? { keys[profileID] }
    func write(_ value: String?, profileID: UUID) throws { keys[profileID] = value }
}

@MainActor
private final class UIStateCustomClient: AICustomServing {
    var onExplain: (AIExplanationPurpose, AIConfiguration) async throws -> String = { _, _ in "custom riverbank" }
    private(set) var explanationCount = 0
    func fetchModels(baseURL: String, apiKey: String) async throws -> [String] { ["custom-model"] }
    func explain(selection: String, context: String, focusedSentence: String?,
                 purpose: AIExplanationPurpose, configuration: AIConfiguration) async throws -> String {
        explanationCount += 1
        return try await onExplain(purpose, configuration)
    }
}

@MainActor
private final class UIStateAuth: ChatGPTAuthenticating {
    var onSignIn: () async throws -> ChatGPTSession = { throw ChatGPTError.authorizationDenied }
    var onRevoke: (ChatGPTSession) async throws -> Void = { _ in }
    func signIn(hostID: String, previous: ChatGPTRegistration?, idTokenHint: String?,
                requestConsent: Bool) async throws -> ChatGPTSession { try await onSignIn() }
    func refresh(_ session: ChatGPTSession) async throws -> ChatGPTSession { throw ChatGPTError.loginExpired }
    func revoke(_ session: ChatGPTSession) async throws { try await onRevoke(session) }
}

@MainActor
private final class UIStateClient: ChatGPTServing {
    var onExplain: (String, AIExplanationPurpose) async throws -> String = { _, _ in "a riverbank" }
    private(set) var explanationCount = 0
    func fetchModel(accessToken: String) async throws -> String { "available-model" }
    func explain(selection: String, context: String, focusedSentence: String?,
                 purpose: AIExplanationPurpose, language: StudyLanguage,
                 accessToken: String, model: String) async throws -> String {
        explanationCount += 1
        return try await onExplain(accessToken, purpose)
    }
}

@MainActor
private final class UIStateGate<Value> {
    private var continuation: CheckedContinuation<Value, Error>?
    func wait() async throws -> Value { try await withCheckedThrowingContinuation { continuation = $0 } }
    func succeed(_ value: Value) {
        let pending = continuation
        continuation = nil
        pending?.resume(returning: value)
    }
}
