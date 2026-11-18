import Combine
import Foundation
import Security

protocol ChatGPTCredentialStorage {
    func read() throws -> Data?
    func write(_ data: Data?) throws
}

struct ChatGPTKeychainStorage: ChatGPTCredentialStorage {
    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "ReadingToolDaily.ChatGPT",
         kSecAttrAccount as String: "accounts"]
    }

    func read() throws -> Data? {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw ChatGPTError.storage }
        return data
    }

    func write(_ data: Data?) throws {
        guard let data else {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw ChatGPTError.storage }
            return
        }
        let attributes = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw ChatGPTError.storage }
        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw ChatGPTError.storage }
    }
}

protocol ChatGPTServing {
    func fetchModel(accessToken: String) async throws -> String
    func explain(selection: String, context: String, focusedSentence: String?,
                 purpose: AIExplanationPurpose, language: StudyLanguage,
                 accessToken: String, model: String) async throws -> String
}

extension ChatGPTClient: ChatGPTServing { }

@MainActor
final class ChatGPTAccountStore: ObservableObject {
    static let usageURL = URL(string: "https://chatgpt.com/settings/usage")!

    @Published private(set) var accountEmail: String?
    @Published private(set) var activeClientID: String?
    @Published private(set) var savedAccounts: [ChatGPTRegistration] = []
    @Published private(set) var isSigningIn = false
    @Published private(set) var isSigningOut = false
    @Published private(set) var isChecking = false
    @Published private(set) var issue: ChatGPTError?
    @Published private(set) var notice: String?
    @Published private(set) var needsAuthorization = false
    @Published private(set) var needsReauthentication = false
    @Published var showPlanWelcome = false
    @Published private(set) var configurationClientID: String?
    @Published private(set) var isConfigurationSigningIn = false
    @Published private(set) var configurationIssue: ChatGPTError?

    var isSignedIn: Bool { activeClientID != nil }

    private struct Vault: Codable {
        var registrations: [ChatGPTRegistration] = []
        var sessions: [ChatGPTSession] = []
        var activeClientID: String?
        var lastClientID: String?
    }

    private let credentials: any ChatGPTCredentialStorage
    private let auth: any ChatGPTAuthenticating
    private let client: any ChatGPTServing
    private let defaults: UserDefaults
    private let now: () -> Date
    private var vault = Vault()
    private var loadFailed = false
    private var needsPersistence = false
    private var generation = UUID()
    private var loginTask: Task<Void, Never>?
    private var loginID: UUID?
    private var checkTask: Task<Void, Never>?
    private var checkID: UUID?
    private var logoutTask: Task<Void, Never>?
    private var refreshTasks: [String: Task<ChatGPTSession, Error>] = [:]
    private var reauthenticationRequired: Set<String> = []
    private var models: [String: String] = [:]
    private var usageBlock: ChatGPTError?
    private var configurationOpen = false
    private var configurationGeneration = UUID()
    private var validatedConfigurationGeneration: UUID?
    private var configurationLoginTask: Task<Void, Never>?
    private var configurationLoginID: UUID?

    var configurationEmail: String? {
        vault.registrations.first { $0.clientID == configurationClientID }?.email
    }

    var configurationNeedsAuthorization: Bool {
        vault.sessions.first { $0.registration.clientID == configurationClientID }
            .map { !$0.scopes.contains("chatgpt.tokens.use.direct") } ?? false
    }

    var configurationNeedsReauthentication: Bool {
        guard let id = configurationClientID, !configurationNeedsAuthorization else { return false }
        let session = vault.sessions.first { $0.registration.clientID == id }
        return reauthenticationRequired.contains(id) || (session.map { $0.refreshExpiresAt <= now() } ?? true)
    }

    init(defaults: UserDefaults = .standard,
         credentials: any ChatGPTCredentialStorage = ChatGPTKeychainStorage(),
         auth: (any ChatGPTAuthenticating)? = nil,
         client: any ChatGPTServing = ChatGPTClient(), now: @escaping () -> Date = Date.init) {
        self.defaults = defaults
        self.credentials = credentials
        self.auth = auth ?? ChatGPTAuthService()
        self.client = client
        self.now = now
        do { try loadVault() }
        catch { loadFailed = true; issue = .storage }
    }

    private var currentSession: ChatGPTSession? {
        vault.sessions.first { $0.registration.clientID == vault.activeClientID }
    }

    private var currentRegistration: ChatGPTRegistration? {
        vault.registrations.first { $0.clientID == vault.activeClientID }
    }

    private func loadVault() throws {
        if let data = try credentials.read() {
            let loaded = try JSONDecoder().decode(Vault.self, from: data)
            guard Set(loaded.registrations.map(\.clientID)).count == loaded.registrations.count,
                  Set(loaded.sessions.map { $0.registration.clientID }).count == loaded.sessions.count,
                  loaded.registrations.allSatisfy({ !$0.clientID.isEmpty && !$0.subject.isEmpty }),
                  loaded.sessions.allSatisfy({ loaded.registrations.contains($0.registration) }) else {
                throw ChatGPTError.storage
            }
            vault = loaded
        }
        loadFailed = false
        publishAccount()
    }

    private func prepareStorage() throws {
        do {
            if loadFailed { try loadVault() }
            if needsPersistence { try persist() }
        } catch { throw ChatGPTError.storage }
    }

    private func persist() throws {
        do {
            try credentials.write(try JSONEncoder().encode(vault))
            needsPersistence = false
        } catch {
            // In particular retain a rotated refresh token in memory if Keychain is locked.
            needsPersistence = true
            throw ChatGPTError.storage
        }
    }

    private func publishAccount() {
        savedAccounts = vault.registrations
        activeClientID = currentRegistration?.clientID
        accountEmail = currentRegistration?.email
        let session = currentSession
        needsAuthorization = session.map { !$0.scopes.contains("chatgpt.tokens.use.direct") } ?? false
        needsReauthentication = activeClientID.map { id in
            !needsAuthorization && (reauthenticationRequired.contains(id) ||
                session.map { $0.refreshExpiresAt <= now() } ?? true)
        } ?? false
    }

    private func requireReauthentication() {
        if let activeClientID { reauthenticationRequired.insert(activeClientID) }
        publishAccount()
    }

    private func save(_ session: ChatGPTSession, activate: Bool) throws {
        let id = session.registration.clientID
        vault.registrations.removeAll { $0.clientID == id }
        vault.registrations.append(session.registration)
        vault.sessions.removeAll { $0.registration.clientID == id }
        vault.sessions.append(session)
        if activate {
            vault.activeClientID = id
            vault.lastClientID = id
            // Only a completed interactive sign-in resolves a confirmed auth failure.
            // Saving another account's background refresh must preserve this state.
            reauthenticationRequired.remove(id)
        }
        publishAccount()
        try persist()
    }

    private var hostID: String {
        if let stored = defaults.string(forKey: "chatgpt.hostID"),
           stored.hasPrefix("urn:uuid:"), UUID(uuidString: String(stored.dropFirst(9))) != nil {
            return stored
        }
        let value = "urn:uuid:" + UUID().uuidString.lowercased()
        defaults.set(value, forKey: "chatgpt.hostID")
        return value
    }

    func signIn() {
        do { try prepareStorage() }
        catch { issue = .storage; return }
        // Signing out ends a renewable session, not the user's client registration.
        let previous = currentRegistration
            ?? vault.registrations.first(where: { $0.clientID == vault.lastClientID })
            ?? (vault.registrations.count == 1 ? vault.registrations.first : nil)
        beginSignIn(previous: previous, hint: currentSession?.idToken,
                    consent: needsAuthorization)
    }

    func connectAnotherAccount() {
        beginSignIn(previous: nil, hint: nil, consent: false)
    }

    private func beginSignIn(previous: ChatGPTRegistration?, hint: String?, consent: Bool) {
        guard !isSigningOut else { return }
        cancelSignIn()
        cancelCheck()
        do { try prepareStorage() }
        catch { issue = .storage; return }
        let id = UUID()
        loginID = id
        isSigningIn = true
        issue = nil
        notice = L("请在浏览器中完成 ChatGPT 登录与授权。", "Finish signing in and authorizing in your browser.")
        let host = hostID
        loginTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.loginID == id { self.isSigningIn = false; self.loginTask = nil; self.loginID = nil }
            }
            do {
                let session = try await self.auth.signIn(hostID: host, previous: previous,
                                                        idTokenHint: hint, requestConsent: consent)
                try Task.checkCancellation()
                guard self.loginID == id else { return }
                self.generation = UUID()
                self.models.removeAll()
                self.usageBlock = nil
                try self.save(session, activate: true)
                if self.needsAuthorization { throw ChatGPTError.missingPlanPermission }
                let gen = self.generation
                let model = try await self.withAuthorizedSession { try await self.client.fetchModel(accessToken: $0.accessToken) }
                try Task.checkCancellation()
                guard self.loginID == id, self.generation == gen else { return }
                self.models[session.registration.clientID] = model
                self.notice = L("已连接 ChatGPT，可以使用 AI 释义了。", "ChatGPT is connected. AI explanations are ready.")
                let welcomeKey = "chatgpt.welcomed." + session.registration.clientID
                if !self.defaults.bool(forKey: welcomeKey) {
                    self.showPlanWelcome = true
                    self.defaults.set(true, forKey: welcomeKey)
                }
            } catch is CancellationError {
                // Cancelling a pending sign-in preserves the previous account.
            } catch {
                guard self.loginID == id else { return }
                self.record(error)
            }
        }
    }

    func cancelSignIn() {
        loginID = nil
        loginTask?.cancel()
        loginTask = nil
        isSigningIn = false
        notice = nil
    }

    func selectAccount(_ registration: ChatGPTRegistration) {
        guard !isSigningOut, vault.registrations.contains(registration) else { return }
        cancelSignIn()
        cancelCheck()
        generation = UUID()
        // A refresh may already have rotated its server-side token. Keep it alive and
        // save that account's replacement, even when the user switches accounts.
        vault.activeClientID = registration.clientID
        vault.lastClientID = registration.clientID
        usageBlock = nil
        issue = nil
        notice = nil
        publishAccount()
        do { try persist() }
        catch { issue = .storage; return }
        if needsReauthentication { signIn() }
    }

    func signOut() {
        signOut(registration: currentRegistration)
    }

    /// The settings form can contain a newly connected, uncommitted account.
    func signOutConfiguration() {
        signOut(registration: vault.registrations.first { $0.clientID == configurationClientID })
    }

    private func signOut(registration: ChatGPTRegistration?) {
        guard !isSigningOut, let selected = registration else { return }
        cancelSignIn()
        cancelCheck()
        isSigningOut = true
        if configurationOpen, configurationClientID == selected.clientID {
            cancelConfigurationSignIn()
            configurationGeneration = UUID()
            validatedConfigurationGeneration = nil
            configurationClientID = nil
            configurationIssue = nil
        }
        notice = nil
        issue = nil
        let pendingRefresh = refreshTasks[selected.clientID]
        logoutTask = Task { [weak self] in
            guard let self else { return }
            // Let a rotating refresh finish before revoking the newest token.
            if let pendingRefresh { _ = try? await pendingRefresh.value }
            let session = self.vault.sessions.first { $0.registration.clientID == selected.clientID }
            self.generation = UUID()
            self.refreshTasks.removeValue(forKey: selected.clientID)
            self.vault.sessions.removeAll { $0.registration.clientID == selected.clientID }
            self.vault.lastClientID = selected.clientID
            if self.vault.activeClientID == selected.clientID { self.vault.activeClientID = nil }
            self.models.removeValue(forKey: selected.clientID)
            self.usageBlock = nil
            self.showPlanWelcome = false
            self.publishAccount()
            var storageFailed = false
            do { try self.persist() } catch { storageFailed = true }
            var remoteConfirmed = true
            if let session {
                do { try await self.auth.revoke(session) }
                catch { remoteConfirmed = false }
            }
            if storageFailed { self.issue = .storage }
            else if !remoteConfirmed { self.issue = .signOutUnconfirmed }
            else { self.notice = L("已退出 ChatGPT。", "Signed out of ChatGPT.") }
            if self.configurationOpen, self.configurationClientID == nil {
                self.configurationIssue = self.issue
            }
            self.isSigningOut = false
            self.logoutTask = nil
        }
    }

    func dismissIssue() { issue = nil; notice = nil }

    /// Only an explicit user retry/check clears a usage block; background prefill does not.
    func resetUsageBlock() { usageBlock = nil }

    func checkConnection() {
        guard !isSigningIn, !isSigningOut else { return }
        cancelCheck()
        resetUsageBlock()
        issue = nil
        notice = nil
        let id = UUID()
        let gen = generation
        checkID = id
        isChecking = true
        checkTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.checkID == id { self.checkID = nil; self.isChecking = false; self.checkTask = nil }
            }
            do {
                _ = try await self.explain(selection: "bright", context: "The room is bright.",
                                          focusedSentence: "The room is bright.", purpose: .prefill,
                                          language: .english)
                try Task.checkCancellation()
                guard self.checkID == id, self.generation == gen else { return }
                self.notice = L("连接正常，可以使用 AI 释义。", "Connection checked. AI explanations are ready.")
            } catch is CancellationError { }
            catch {
                guard self.checkID == id, self.generation == gen else { return }
                self.record(error)
            }
        }
    }

    func cancelCheck() {
        checkID = nil
        checkTask?.cancel()
        checkTask = nil
        isChecking = false
    }

    /// Configuration edits use a candidate identity; production requests keep using the saved account.
    func beginConfiguration() {
        guard !configurationOpen else { return }
        configurationOpen = true
        configurationGeneration = UUID()
        validatedConfigurationGeneration = nil
        configurationClientID = activeClientID
        configurationIssue = issue
    }

    func endConfiguration() {
        cancelConfigurationSignIn()
        configurationOpen = false
        configurationGeneration = UUID()
        validatedConfigurationGeneration = nil
        configurationClientID = nil
        configurationIssue = nil
    }

    func selectConfigurationAccount(_ registration: ChatGPTRegistration) {
        guard configurationOpen, !isSigningOut, vault.registrations.contains(registration) else { return }
        cancelConfigurationSignIn()
        configurationGeneration = UUID()
        validatedConfigurationGeneration = nil
        configurationClientID = registration.clientID
        configurationIssue = nil
    }

    func discardConfigurationCandidate() {
        guard configurationOpen else { return }
        cancelConfigurationSignIn()
        configurationGeneration = UUID()
        validatedConfigurationGeneration = nil
        configurationClientID = activeClientID
        configurationIssue = nil
    }

    func dismissConfigurationIssue() { configurationIssue = nil }

    func signInConfiguration(otherAccount: Bool) {
        guard configurationOpen, !isSigningOut else { return }
        cancelConfigurationSignIn()
        configurationGeneration = UUID()
        validatedConfigurationGeneration = nil
        do { try prepareStorage() }
        catch { configurationIssue = .storage; return }
        let registration: ChatGPTRegistration?
        if otherAccount { registration = nil }
        else {
            registration = vault.registrations.first { $0.clientID == configurationClientID }
                ?? vault.registrations.first { $0.clientID == vault.lastClientID }
                ?? (vault.registrations.count == 1 ? vault.registrations.first : nil)
        }
        let session = vault.sessions.first { $0.registration.clientID == registration?.clientID }
        let consent = !otherAccount && (session.map { !$0.scopes.contains("chatgpt.tokens.use.direct") } ?? false)
        let id = UUID()
        let gen = configurationGeneration
        configurationLoginID = id
        isConfigurationSigningIn = true
        configurationIssue = nil
        configurationLoginTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.configurationLoginID == id {
                    self.configurationLoginID = nil
                    self.configurationLoginTask = nil
                    self.isConfigurationSigningIn = false
                }
            }
            do {
                let authenticated = try await self.auth.signIn(hostID: self.hostID, previous: registration,
                                                              idTokenHint: session?.idToken, requestConsent: consent)
                try Task.checkCancellation()
                guard self.configurationOpen, self.configurationLoginID == id,
                      self.configurationGeneration == gen else { return }
                // Tokens must survive refresh rotation, but the selected production identity is unchanged.
                self.reauthenticationRequired.remove(authenticated.registration.clientID)
                self.models.removeValue(forKey: authenticated.registration.clientID)
                self.configurationClientID = authenticated.registration.clientID
                try self.save(authenticated, activate: false)
                self.publishAccount()
                if !authenticated.scopes.contains("chatgpt.tokens.use.direct") {
                    throw ChatGPTError.missingPlanPermission
                }
            } catch is CancellationError { }
            catch {
                guard !Task.isCancelled, self.configurationOpen, self.configurationLoginID == id,
                      self.configurationGeneration == gen else { return }
                self.configurationIssue = ChatGPTError.from(error)
            }
        }
    }

    func cancelConfigurationSignIn() {
        configurationLoginID = nil
        configurationLoginTask?.cancel()
        configurationLoginTask = nil
        isConfigurationSigningIn = false
    }

    func validateConfigurationCandidate() async throws {
        guard configurationOpen, let selected = configurationClientID else { throw ChatGPTError.notSignedIn }
        let gen = configurationGeneration
        validatedConfigurationGeneration = nil
        configurationIssue = nil
        do {
            let text = try await withConfigurationSession(clientID: selected, generation: gen) { session in
                var model = self.models[selected]
                if model == nil {
                    model = try await self.client.fetchModel(accessToken: session.accessToken)
                    try self.checkConfiguration(selected, generation: gen)
                    self.models[selected] = model
                }
                do {
                    return try await self.client.explain(selection: "bright", context: "The room is bright.",
                                                         focusedSentence: "The room is bright.", purpose: .prefill,
                                                         language: .english, accessToken: session.accessToken, model: model!)
                } catch ChatGPTError.modelUnavailable {
                    try self.checkConfiguration(selected, generation: gen)
                    let replacement = try await self.client.fetchModel(accessToken: session.accessToken)
                    try self.checkConfiguration(selected, generation: gen)
                    guard replacement != model else { throw ChatGPTError.modelUnavailable }
                    self.models[selected] = replacement
                    return try await self.client.explain(selection: "bright", context: "The room is bright.",
                                                         focusedSentence: "The room is bright.", purpose: .prefill,
                                                         language: .english, accessToken: session.accessToken, model: replacement)
                }
            }
            try checkConfiguration(selected, generation: gen)
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ChatGPTError.emptyResponse }
            validatedConfigurationGeneration = gen
        } catch {
            try checkConfiguration(selected, generation: gen)
            let problem = ChatGPTError.from(error)
            configurationIssue = problem
            throw problem
        }
    }

    func commitConfigurationCandidate() throws {
        try prepareStorage()
        guard configurationOpen, let selected = configurationClientID,
              validatedConfigurationGeneration == configurationGeneration,
              configurationIssue == nil, !isConfigurationSigningIn, !isSigningOut,
              vault.sessions.contains(where: { $0.registration.clientID == selected }),
              !configurationNeedsAuthorization, !configurationNeedsReauthentication else {
            throw ChatGPTError.invalidAuthorization
        }
        var committed = vault
        committed.activeClientID = selected
        committed.lastClientID = selected
        // Persist before publishing. A failed write leaves the previous production account active.
        do { try credentials.write(try JSONEncoder().encode(committed)) }
        catch { throw ChatGPTError.storage }
        vault = committed
        needsPersistence = false
        generation = UUID()
        usageBlock = nil
        issue = nil
        notice = nil
        publishAccount()
    }

    private func checkConfiguration(_ clientID: String, generation expected: UUID) throws {
        try Task.checkCancellation()
        guard configurationOpen, configurationGeneration == expected,
              configurationClientID == clientID, !isSigningOut else { throw CancellationError() }
    }

    private func withConfigurationSession<T>(clientID: String, generation gen: UUID,
                                              operation: (ChatGPTSession) async throws -> T) async throws -> T {
        let session = try await readySession(for: clientID)
        try checkConfiguration(clientID, generation: gen)
        do { return try await operation(session) }
        catch let error as ChatGPTError where error == .loginExpired || error == .invalidAuthorization {
            try checkConfiguration(clientID, generation: gen)
            let renewed: ChatGPTSession
            if let latest = vault.sessions.first(where: { $0.registration.clientID == clientID }),
               latest.accessToken != session.accessToken, latest.expiresAt > now(),
               latest.scopes.contains("chatgpt.tokens.use.direct") {
                renewed = latest
            } else { renewed = try await readySession(for: clientID, forceRefresh: true) }
            try checkConfiguration(clientID, generation: gen)
            do { return try await operation(renewed) }
            catch let problem as ChatGPTError where problem == .loginExpired || problem == .invalidAuthorization {
                try checkConfiguration(clientID, generation: gen)
                reauthenticationRequired.insert(clientID)
                publishAccount()
                throw ChatGPTError.loginExpired
            }
        }
    }

    func explain(selection: String, context: String, focusedSentence: String? = nil,
                 purpose: AIExplanationPurpose = .lookup, language: StudyLanguage) async throws -> String {
        let gen = generation
        do {
            try prepareStorage()
            if let usageBlock { throw usageBlock }
            let text: String = try await withAuthorizedSession { session in
                let id = session.registration.clientID
                let model: String
                if let cached = self.models[id] { model = cached }
                else {
                    model = try await self.client.fetchModel(accessToken: session.accessToken)
                    try Task.checkCancellation()
                    guard self.generation == gen, !self.isSigningOut else { throw CancellationError() }
                    self.models[id] = model
                }
                do {
                    return try await self.client.explain(selection: selection, context: context,
                                                         focusedSentence: focusedSentence, purpose: purpose,
                                                         language: language, accessToken: session.accessToken, model: model)
                } catch ChatGPTError.modelUnavailable {
                    try Task.checkCancellation()
                    let replacement = try await self.client.fetchModel(accessToken: session.accessToken)
                    guard replacement != model else { throw ChatGPTError.modelUnavailable }
                    try Task.checkCancellation()
                    guard self.generation == gen, !self.isSigningOut else { throw CancellationError() }
                    self.models[id] = replacement
                    return try await self.client.explain(selection: selection, context: context,
                                                         focusedSentence: focusedSentence, purpose: purpose,
                                                         language: language, accessToken: session.accessToken, model: replacement)
                }
            }
            try Task.checkCancellation()
            guard generation == gen, !isSigningOut else { throw CancellationError() }
            issue = nil
            notice = nil
            return text
        } catch is CancellationError { throw CancellationError() }
        catch {
            try Task.checkCancellation()
            guard generation == gen, !isSigningOut else { throw CancellationError() }
            let problem = ChatGPTError.from(error)
            record(problem)
            throw problem
        }
    }

    private func withAuthorizedSession<T>(_ operation: (ChatGPTSession) async throws -> T) async throws -> T {
        let gen = generation
        let account = activeClientID
        let session = try await readySession()
        try Task.checkCancellation()
        guard generation == gen, activeClientID == account, !isSigningOut else { throw CancellationError() }
        do { return try await operation(session) }
        catch let error as ChatGPTError where error == .loginExpired || error == .invalidAuthorization {
            try Task.checkCancellation()
            guard generation == gen, activeClientID == account, !isSigningOut else { throw CancellationError() }
            let renewed: ChatGPTSession
            if let latest = currentSession, latest.accessToken != session.accessToken,
               latest.expiresAt > now(), latest.scopes.contains("chatgpt.tokens.use.direct") {
                renewed = latest
            } else {
                renewed = try await readySession(forceRefresh: true)
            }
            try Task.checkCancellation()
            guard generation == gen, activeClientID == account, !isSigningOut else { throw CancellationError() }
            do { return try await operation(renewed) }
            catch let problem as ChatGPTError where problem == .loginExpired || problem == .invalidAuthorization {
                try Task.checkCancellation()
                guard generation == gen, activeClientID == account, !isSigningOut else { throw CancellationError() }
                requireReauthentication()
                throw ChatGPTError.loginExpired
            }
        }
    }

    private func readySession(forceRefresh: Bool = false) async throws -> ChatGPTSession {
        try Task.checkCancellation()
        try prepareStorage()
        let gen = generation
        guard let clientID = activeClientID else { throw ChatGPTError.notSignedIn }
        let session = try await readySession(for: clientID, forceRefresh: forceRefresh)
        try Task.checkCancellation()
        guard generation == gen, activeClientID == clientID, !isSigningOut else { throw CancellationError() }
        return session
    }

    /// Both production and candidate callers share the same rotating-refresh task per account.
    private func readySession(for clientID: String, forceRefresh: Bool = false) async throws -> ChatGPTSession {
        try Task.checkCancellation()
        try prepareStorage()
        guard !isSigningOut else { throw CancellationError() }
        guard !reauthenticationRequired.contains(clientID),
              let session = vault.sessions.first(where: { $0.registration.clientID == clientID }) else {
            throw ChatGPTError.loginExpired
        }
        guard session.scopes.contains("chatgpt.tokens.use.direct") else { throw ChatGPTError.missingPlanPermission }
        if !forceRefresh, session.expiresAt > now().addingTimeInterval(60) { return session }
        if !forceRefresh, let earliest = session.earliestRefreshAt,
           now() < earliest, session.expiresAt > now() { return session }
        if session.refreshExpiresAt <= now() {
            reauthenticationRequired.insert(clientID)
            publishAccount()
            throw ChatGPTError.loginExpired
        }
        if let task = refreshTasks[clientID] {
            let renewed = try await task.value
            try Task.checkCancellation()
            return renewed
        }
        let task = Task { [weak self] () throws -> ChatGPTSession in
            guard let self else { throw CancellationError() }
            defer { self.refreshTasks.removeValue(forKey: clientID) }
            do {
                let renewed = try await self.auth.refresh(session)
                // Never replace a newer interactive login with this older refresh.
                guard let stored = self.vault.sessions.first(where: { $0.registration.clientID == clientID }),
                      stored.refreshToken == session.refreshToken else {
                    throw CancellationError()
                }
                try self.save(renewed, activate: false)
                guard renewed.scopes.contains("chatgpt.tokens.use.direct") else { throw ChatGPTError.missingPlanPermission }
                return renewed
            } catch ChatGPTError.loginExpired {
                guard let stored = self.vault.sessions.first(where: { $0.registration.clientID == clientID }),
                      stored.refreshToken == session.refreshToken else { throw CancellationError() }
                self.vault.sessions.removeAll { $0.registration.clientID == session.registration.clientID }
                self.publishAccount()
                try self.persist()
                throw ChatGPTError.loginExpired
            }
        }
        refreshTasks[clientID] = task
        let renewed = try await task.value
        try Task.checkCancellation()
        return renewed
    }

    private func record(_ error: Error) {
        let problem = ChatGPTError.from(error)
        issue = problem
        notice = nil
        if problem == .loginExpired { requireReauthentication() }
        if problem == .missingPlanPermission { needsAuthorization = isSignedIn }
        if problem == .usageLimit || problem == .insufficientCredits { usageBlock = problem }
    }
}
