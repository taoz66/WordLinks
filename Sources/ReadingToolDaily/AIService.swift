import Combine
import Foundation
import Security

struct AIConfiguration: Equatable {
    let baseURL: String
    let apiKey: String
    let model: String
    let sourceLanguage: StudyLanguage
    let targetLanguage: StudyLanguage
    let authentication: AICustomAuthentication

    init(baseURL: String, apiKey: String, model: String,
         sourceLanguage: StudyLanguage = .english, targetLanguage: StudyLanguage = .chinese,
         authentication: AICustomAuthentication = .apiKey) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.model = model
        self.sourceLanguage = sourceLanguage
        self.targetLanguage = targetLanguage
        self.authentication = authentication
    }

    func validated() throws -> AIConfiguration {
        let configuration = AIConfiguration(
            baseURL: baseURL.trimmingCharacters(in: .whitespacesAndNewlines),
            apiKey: authentication == .apiKey ? apiKey.trimmingCharacters(in: .whitespacesAndNewlines) : "",
            model: model.trimmingCharacters(in: .whitespacesAndNewlines),
            sourceLanguage: sourceLanguage, targetLanguage: targetLanguage, authentication: authentication
        )
        _ = try Self.endpointURL(for: configuration.baseURL)
        guard configuration.authentication == .none || !configuration.apiKey.isEmpty else { throw AIError.missingAPIKey }
        guard configuration.apiKey.rangeOfCharacter(from: .newlines) == nil else {
            throw AIError.invalidAPIKey
        }
        guard !configuration.model.isEmpty,
              configuration.model.rangeOfCharacter(from: .newlines) == nil else {
            throw AIError.missingModel
        }
        return configuration
    }

    static func endpointURL(for address: String) throws -> URL {
        var components = try apiComponents(for: address)
        var path = normalizedAPIPath(components.percentEncodedPath)
        let isCompleteModelsEndpoint = path.hasSuffix("/models")
        if isCompleteModelsEndpoint { path.removeLast("/models".count) }
        if !path.hasSuffix("/chat/completions") {
            path += path.isEmpty && !isCompleteModelsEndpoint ? "/v1/chat/completions" : "/chat/completions"
        }
        components.percentEncodedPath = path
        guard let url = components.url else { throw AIError.invalidAddress }
        return url
    }

    static func modelsURL(for address: String) throws -> URL {
        var components = try apiComponents(for: address)
        var path = normalizedAPIPath(components.percentEncodedPath)
        let isCompleteChatEndpoint = path.hasSuffix("/chat/completions")
        if isCompleteChatEndpoint {
            path.removeLast("/chat/completions".count)
        }
        if !path.hasSuffix("/models") {
            path += path.isEmpty && !isCompleteChatEndpoint ? "/v1/models" : "/models"
        }
        components.percentEncodedPath = path
        guard let url = components.url else { throw AIError.invalidAddress }
        return url
    }

    private static func apiComponents(for address: String) throws -> URLComponents {
        guard let components = URLComponents(string: address.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = components.scheme?.lowercased(), ["https", "http"].contains(scheme),
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil,
              components.fragment == nil else { throw AIError.invalidAddress }
        return components
    }

    private static func normalizedAPIPath(_ path: String) -> String {
        let segments = path.split(separator: "/", omittingEmptySubsequences: true)
        return segments.isEmpty ? "" : "/" + segments.joined(separator: "/")
    }
}

enum AIError: LocalizedError, Equatable {
    case missingAPIKey
    case invalidAPIKey
    case missingModel
    case invalidAddress
    case invalidSelection
    case inputTooLarge
    case invalidResponse
    case emptyResponse
    case outputTruncated
    case invalidModelsResponse
    case emptyModels
    case modelsHTTP(Int)
    case http(Int)
    case timedOut
    case connectionFailed
    case keychain(OSStatus)
    case missingProfile
    case profileStorage

    var errorDescription: String? {
        switch self {
        case .missingAPIKey: return L("请先在设置的 AI 选项卡中填写并保存 API Key。", "Enter and save an API key in AI settings first.")
        case .invalidAPIKey: return L("API Key 不能包含换行，请重新填写。", "The API key cannot contain line breaks. Enter it again.")
        case .missingModel: return L("请选择模型，或手动输入模型 ID。", "Choose a model, or enter a model ID manually.")
        case .invalidAddress: return L("请填写完整的 HTTP 或 HTTPS API 地址，例如 https://api.openai.com/v1。", "Enter a complete HTTP or HTTPS API address, such as https://api.openai.com/v1.")
        case .invalidSelection: return L("请在文章中选中要解释或翻译的内容后重试。", "Select the text to explain or translate in the article and try again.")
        case .inputTooLarge: return L("选中的内容太长，请缩短选区后重试。", "The selected text is too long. Select a shorter passage and try again.")
        case .invalidResponse: return L("AI 服务返回了无法读取的内容，请确认地址和模型支持 Chat Completions。", "The AI response could not be read. Check that the address and model support Chat Completions.")
        case .emptyResponse: return L("AI 没有返回解释，请重试或检查模型设置。", "AI returned no explanation. Try again or check the model settings.")
        case .outputTruncated: return L("译文太长，服务未能完整返回。请缩短选区后重试。", "The translation was too long for the service to return completely. Select a shorter passage and try again.")
        case .invalidModelsResponse: return L("无法读取服务返回的模型列表，请确认 API 地址支持 /models 接口。", "The model list could not be read. Check that the API address supports /models.")
        case .emptyModels: return L("服务没有返回可用模型，请确认 API Key 具有模型访问权限。", "The service returned no available models. Check the API key's model permissions.")
        case .timedOut: return L("AI 请求超时，请检查网络后重试。", "The AI request timed out. Check your connection and try again.")
        case .connectionFailed: return L("无法连接 AI 服务，请检查网络和 API 地址。", "Could not connect to the AI service. Check your connection and API address.")
        case .keychain: return L("无法保存或读取 API Key，请检查 macOS 钥匙串权限后重试。", "Could not save or read the API key. Check macOS Keychain permissions and try again.")
        case .missingProfile: return L("这个自定义 AI 配置已不存在，请在设置中重新选择。", "This custom AI configuration no longer exists. Choose another in settings.")
        case .profileStorage: return L("无法读取已保存的 AI 配置，请重试。原配置已保留。", "Saved AI configurations couldn’t be read. Try again; the original data is preserved.")
        case .modelsHTTP(let status):
            switch status {
            case 401, 403: return L("获取模型列表被拒绝（\(status)），请检查 API Key 及访问权限。", "Model access was denied (\(status)). Check the API key and permissions.")
            case 404: return L("找不到模型列表接口（404），请检查 API 地址是否支持 /models。", "The models endpoint was not found (404). Check that the API address supports /models.")
            case 429: return L("获取模型列表过于频繁或服务额度不足（429），请稍后重试。", "The model request was rate limited or the quota was exceeded (429). Try again later.")
            case 500...599: return L("模型列表服务暂时不可用（\(status)），请稍后重试。", "The model service is temporarily unavailable (\(status)). Try again later.")
            default: return L("获取模型列表失败（\(status)），请检查 API 地址后重试。", "Could not fetch models (\(status)). Check the API address and try again.")
            }
        case .http(let status):
            switch status {
            case 401, 403: return L("AI 服务拒绝了请求（\(status)），请检查 API Key 及模型访问权限。", "The AI request was denied (\(status)). Check the API key and model permissions.")
            case 404: return L("找不到 AI 接口或模型（404），请检查 API 地址和模型名称。", "The AI endpoint or model was not found (404). Check the API address and model.")
            case 429: return L("AI 服务的额度不足或请求过于频繁（429），请稍后重试。", "The AI quota was exceeded or requests were rate limited (429). Try again later.")
            case 500...599: return L("AI 服务暂时不可用（\(status)），请稍后重试。", "The AI service is temporarily unavailable (\(status)). Try again later.")
            default: return L("AI 请求失败（\(status)），请检查服务配置后重试。", "The AI request failed (\(status)). Check the service settings and try again.")
            }
        }
    }
}

@MainActor
final class AISettingsStore: ObservableObject {
    let appleIntelligence: any AppleIntelligenceServing
    // Custom services do not instantiate or require a ChatGPT session.
    var chatGPT: ChatGPTAccountStore {
        if let chatGPTStore { return chatGPTStore }
        let store = ChatGPTAccountStore()
        observeChatGPT(store)
        return store
    }
    @Published var baseURL: String
    @Published var apiKey: String
    @Published var model: String
    @Published private(set) var aiPrefillEnabled: Bool
    @Published private(set) var availableModels: [String]
    @Published private(set) var customProfiles: [AICustomProfile] = []
    @Published private(set) var selectedService: AIServiceSelection = .chatGPT
    @Published private(set) var configurationRevision: UInt64 = 0
    @Published private(set) var customStorageIssue: AIUsageIssue?
    var storageError: String? { credentialReadError?.localizedDescription }

    private let defaults: UserDefaults
    private let credentials: any AICredentialStorage
    private let customCredentials: any AICustomCredentialStorage
    private let customClient: any AICustomServing
    private let language: AppLanguageStore
    private var chatGPTStore: ChatGPTAccountStore?
    private var observations: Set<AnyCancellable> = []
    private var profileMetadataFailed = false
    private var legacyProfileID: UUID?
    // A key (including a missing key or a read failure) is resolved once per
    // session. SwiftUI status checks must not repeatedly ask Keychain for access.
    private var profileCredentials: [UUID: Result<String, Error>] = [:]
    @Published private var credentialReadError: Error?

    init(defaults: UserDefaults = .standard, credentials: any AICredentialStorage = AICredentialStore(),
         language: AppLanguageStore = .shared,
         customCredentials: any AICustomCredentialStorage = AICustomKeychainStore(),
         customClient: any AICustomServing = AIClient(), chatGPT: ChatGPTAccountStore? = nil,
         appleIntelligence: (any AppleIntelligenceServing)? = nil) {
        self.appleIntelligence = appleIntelligence ?? AppleIntelligenceClient()
        self.defaults = defaults
        self.credentials = credentials
        self.customCredentials = customCredentials
        self.customClient = customClient
        self.language = language
        baseURL = defaults.string(forKey: "ai.baseURL") ?? "https://api.openai.com/v1"
        model = defaults.string(forKey: "ai.model") ?? ""
        aiPrefillEnabled = defaults.object(forKey: "ai.prefillEnabled") as? Bool ?? true
        availableModels = normalizedModelIDs(defaults.stringArray(forKey: "ai.availableModels") ?? [])
        apiKey = ""
        do { apiKey = try credentials.read() ?? "" }
        catch {
            credentialReadError = error
            customStorageIssue = .custom(AIError.keychain(errSecAuthFailed))
        }
        do { try loadProfiles() }
        catch { profileMetadataFailed = true; customStorageIssue = .custom(.profileStorage) }
        if !profileMetadataFailed { migrateLegacyConfiguration() }
        if let value = defaults.string(forKey: "ai.selectedService"),
           let saved = AIServiceSelection(preferenceValue: value) { selectedService = saved }
        if let chatGPT { observeChatGPT(chatGPT) }
    }

    /// Legacy configuration API is retained for older callers and stored preferences.
    var isConfigured: Bool { (try? configuration()) != nil }

    func configuration() throws -> AIConfiguration {
        if let credentialReadError { throw credentialReadError }
        let studyLanguage = language.language.studyLanguage
        return try AIConfiguration(baseURL: baseURL, apiKey: apiKey, model: model,
                                   sourceLanguage: studyLanguage, targetLanguage: studyLanguage).validated()
    }

    var isAIConfigured: Bool { aiConfigurationIssue == nil }
    var studyLanguage: StudyLanguage { language.language.studyLanguage }

    var aiConfigurationIssue: AIUsageIssue? {
        switch selectedService {
        case .chatGPT:
            let account = chatGPT
            if !account.isSignedIn { return .chatGPT(account.issue == .storage ? .storage : .notSignedIn) }
            if account.needsAuthorization { return .chatGPT(.missingPlanPermission) }
            if account.needsReauthentication { return .chatGPT(.loginExpired) }
            return nil
        case .custom(let id):
            do { _ = try customConfiguration(for: id, reportStorage: false); return nil }
            catch { return AIUsageIssue.from(error) }
        case .appleIntelligence:
            let availability = appleIntelligence.availability
            return availability == .available ? nil : .appleIntelligence(.unavailable(availability))
        }
    }

    var activeAIIdentity: String {
        let identity: String
        switch selectedService {
        case .chatGPT: identity = "chatGPT:" + (chatGPT.activeClientID ?? "signed-out")
        case .custom(let id): identity = "custom:" + id.uuidString
        case .appleIntelligence: identity = "appleIntelligence"
        }
        return identity + ":" + String(configurationRevision)
    }

    private func observeChatGPT(_ store: ChatGPTAccountStore) {
        chatGPTStore = store
        store.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &observations)
        store.$activeClientID.removeDuplicates().dropFirst().sink { [weak self, weak store] accountID in
            guard self?.selectedService == .chatGPT else { return }
            // Published emits before the account and its authorization flags have changed.
            // Notify callers after publishAccount has committed the entire new state.
            Task { @MainActor [weak self, weak store] in
                guard let self, self.selectedService == .chatGPT,
                      store?.activeClientID == accountID else { return }
                self.configurationRevision &+= 1
            }
        }.store(in: &observations)
    }

    private func loadProfiles() throws {
        if let value = defaults.object(forKey: "ai.customProfiles") {
            guard let data = value as? Data,
                  let profiles = try? JSONDecoder().decode([AICustomProfile].self, from: data),
                  Set(profiles.map(\.id)).count == profiles.count else { throw AIError.profileStorage }
            customProfiles = profiles
        }
        legacyProfileID = defaults.string(forKey: "ai.legacyProfileID").flatMap(UUID.init(uuidString:))
        profileMetadataFailed = false
    }

    private func prepareProfiles() throws {
        if profileMetadataFailed {
            do { try loadProfiles() }
            catch { customStorageIssue = .custom(.profileStorage); throw AIError.profileStorage }
        }
    }

    private func commitProfiles(_ profiles: [AICustomProfile], data: Data, selected: AIServiceSelection) {
        defaults.set(data, forKey: "ai.customProfiles")
        defaults.set(selected.preferenceValue, forKey: "ai.selectedService")
        if selected != .chatGPT {
            chatGPTStore?.cancelSignIn()
            chatGPTStore?.cancelCheck()
        }
        customProfiles = profiles
        selectedService = selected
        customStorageIssue = nil
        configurationRevision &+= 1
    }

    private func migrateLegacyConfiguration() {
        guard legacyProfileID == nil, let configuration = try? configuration() else { return }
        let id = UUID()
        let profile = AICustomProfile(id: id, name: profileName("", address: configuration.baseURL),
                                      baseURL: configuration.baseURL, model: configuration.model,
                                      availableModels: availableModels, usesLegacyCredential: true)
        let profiles = customProfiles + [profile]
        guard let data = try? JSONEncoder().encode(profiles) else { return }
        // Refer to the original Keychain entry. Migration never copies, replaces, or deletes it.
        let selected = defaults.string(forKey: "ai.selectedService").flatMap(AIServiceSelection.init(preferenceValue:))
            ?? .custom(id)
        legacyProfileID = id
        defaults.set(id.uuidString, forKey: "ai.legacyProfileID")
        commitProfiles(profiles, data: data, selected: selected)
    }

    func retryCustomStorage() {
        do {
            try prepareProfiles()
            profileCredentials.removeAll()
            if credentialReadError != nil {
                apiKey = try credentials.read() ?? ""
                credentialReadError = nil
            }
            migrateLegacyConfiguration()
            if case .custom(let id) = selectedService { _ = try apiKey(for: id) }
            customStorageIssue = nil
        } catch { customStorageIssue = AIUsageIssue.from(error) }
    }

    func selectService(_ service: AIServiceSelection) throws {
        if service == .appleIntelligence {
            let availability = appleIntelligence.availability
            guard availability == .available else {
                throw AIUsageIssue.appleIntelligence(.unavailable(availability))
            }
        }
        if case .custom(let id) = service {
            try prepareProfiles()
            _ = try apiKey(for: id)
        }
        guard service != selectedService else { return }
        defaults.set(service.preferenceValue, forKey: "ai.selectedService")
        if service != .chatGPT {
            chatGPTStore?.cancelSignIn()
            chatGPTStore?.cancelCheck()
        }
        selectedService = service
        configurationRevision &+= 1
    }

    func apiKey(for profileID: UUID) throws -> String {
        try secret(for: profileID, reportStorage: true)
    }

    /// Only an explicit retry should ask Keychain again after a failed read.
    func reloadAPIKey(for profileID: UUID) throws -> String {
        try prepareProfiles()
        guard let profile = customProfiles.first(where: { $0.id == profileID }) else { throw AIError.missingProfile }
        guard profile.authentication == .apiKey else { return "" }
        if profile.usesLegacyCredential {
            do {
                apiKey = try credentials.read() ?? ""
                credentialReadError = nil
            } catch {
                credentialReadError = error
                customStorageIssue = AIUsageIssue.from(error)
                throw error
            }
        } else { profileCredentials[profileID] = nil }
        return try apiKey(for: profileID)
    }

    private func secret(for profileID: UUID, reportStorage: Bool) throws -> String {
        do {
            guard !profileMetadataFailed else { throw AIError.profileStorage }
            guard let profile = customProfiles.first(where: { $0.id == profileID }) else { throw AIError.missingProfile }
            guard profile.authentication == .apiKey else {
                if reportStorage { customStorageIssue = nil }
                return ""
            }
            let value: String
            if profile.usesLegacyCredential {
                if let credentialReadError { throw credentialReadError }
                value = apiKey
            } else {
                let resolved: Result<String, Error>
                if let cached = profileCredentials[profileID] { resolved = cached }
                else {
                    resolved = Result { try customCredentials.read(profileID: profileID) ?? "" }
                    profileCredentials[profileID] = resolved
                }
                value = try resolved.get()
            }
            if reportStorage { customStorageIssue = nil }
            return value
        } catch {
            if reportStorage { customStorageIssue = AIUsageIssue.from(error) }
            throw error
        }
    }

    func configuration(for profileID: UUID) throws -> AIConfiguration {
        try customConfiguration(for: profileID, reportStorage: true)
    }

    private func customConfiguration(for id: UUID, reportStorage: Bool) throws -> AIConfiguration {
        let key = try secret(for: id, reportStorage: reportStorage)
        guard let profile = customProfiles.first(where: { $0.id == id }) else { throw AIError.missingProfile }
        let studyLanguage = language.language.studyLanguage
        return try AIConfiguration(baseURL: profile.baseURL, apiKey: key, model: profile.model,
                                   sourceLanguage: studyLanguage, targetLanguage: studyLanguage,
                                   authentication: profile.authentication).validated()
    }

    @discardableResult
    func saveCustomProfile(id: UUID? = nil, name: String, baseURL: String, apiKey: String, model: String,
                           availableModels: [String]? = nil, select: Bool = true,
                           kind: AIServiceKind = .customAPI,
                           authentication: AICustomAuthentication = .apiKey) throws -> UUID {
        try prepareProfiles()
        guard kind == .customAPI || kind == .localModel else { throw AIError.profileStorage }
        if let id, !customProfiles.contains(where: { $0.id == id }) { throw AIError.missingProfile }
        let configuration = try AIConfiguration(baseURL: baseURL, apiKey: apiKey, model: model,
                                                authentication: authentication).validated()
        let id = id ?? UUID()
        let previous = customProfiles.first { $0.id == id }
        let sameProvider = previous?.baseURL == configuration.baseURL
        let profile = AICustomProfile(id: id, name: profileName(name, address: configuration.baseURL),
                                      baseURL: configuration.baseURL, model: configuration.model,
                                      availableModels: normalizedModelIDs(availableModels ?? (sameProvider ? previous?.availableModels ?? [] : [])),
                                      kind: kind, authentication: authentication)
        var profiles = customProfiles
        if let index = profiles.firstIndex(where: { $0.id == id }) { profiles[index] = profile }
        else { profiles.append(profile) }
        let data = try JSONEncoder().encode(profiles)
        if authentication == .apiKey {
            do { try customCredentials.write(configuration.apiKey, profileID: id) }
            catch { customStorageIssue = AIUsageIssue.from(error); throw error }
            profileCredentials[id] = .success(configuration.apiKey)
        }
        commitProfiles(profiles, data: data, selected: select ? .custom(id) : selectedService)
        return id
    }

    func deleteCustomProfile(id: UUID) throws {
        try prepareProfiles()
        guard let profile = customProfiles.first(where: { $0.id == id }) else { throw AIError.missingProfile }
        let profiles = customProfiles.filter { $0.id != id }
        let data = try JSONEncoder().encode(profiles)
        // A migrated profile is a reference: removing it must never delete the old API key.
        if !profile.usesLegacyCredential && profile.authentication == .apiKey {
            do { try customCredentials.write(nil, profileID: id) }
            catch { customStorageIssue = AIUsageIssue.from(error); throw error }
        }
        profileCredentials[id] = nil
        // Keep an absent selected ID explicit, rather than silently billing another provider.
        commitProfiles(profiles, data: data, selected: selectedService)
    }

    private func profileName(_ name: String, address: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? (URLComponents(string: address)?.host ?? L("自定义 AI", "Custom AI")) : trimmed
    }

    func resetUsageBlock() {
        if selectedService == .chatGPT { chatGPT.resetUsageBlock() }
    }

    /// Preferences update immediately and never require access to credentials.
    func setAIPrefillEnabled(_ enabled: Bool) {
        aiPrefillEnabled = enabled
        defaults.set(enabled, forKey: "ai.prefillEnabled")
    }

    func explain(selection: String, context: String, focusedSentence: String? = nil,
                 purpose: AIExplanationPurpose = .lookup) async throws -> String {
        let revision = configurationRevision
        let service = selectedService
        do {
            let text: String
            switch service {
            case .chatGPT:
                text = try await chatGPT.explain(selection: selection, context: context,
                                                 focusedSentence: focusedSentence, purpose: purpose,
                                                 language: language.language.studyLanguage)
            case .custom(let id):
                let configuration = try configuration(for: id)
                text = try await customClient.explain(selection: selection, context: context,
                                                       focusedSentence: focusedSentence, purpose: purpose,
                                                       configuration: configuration)
            case .appleIntelligence:
                text = try await appleIntelligence.explain(selection: selection, context: context,
                    focusedSentence: focusedSentence, purpose: purpose, language: language.language.studyLanguage)
            }
            try Task.checkCancellation()
            guard revision == configurationRevision, service == selectedService else { throw CancellationError() }
            return text
        } catch {
            if error is CancellationError || (error as? URLError)?.code == .cancelled ||
                revision != configurationRevision || service != selectedService { throw CancellationError() }
            throw AIUsageIssue.from(error)
        }
    }

    func save() throws {
        try save(baseURL: baseURL, apiKey: apiKey, model: model)
    }

    func save(baseURL: String, apiKey: String, model: String, availableModels: [String]? = nil) throws {
        try prepareProfiles()
        let address = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let secret = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let modelName = model.trimmingCharacters(in: .whitespacesAndNewlines)
        // An unreadable existing credential is not an empty credential. Preserve it unless
        // the user explicitly supplies a replacement key.
        if secret.isEmpty, let credentialReadError { throw credentialReadError }
        _ = try AIConfiguration.endpointURL(for: address)
        guard secret.rangeOfCharacter(from: .newlines) == nil else { throw AIError.invalidAPIKey }
        guard modelName.rangeOfCharacter(from: .newlines) == nil,
              secret.isEmpty || !modelName.isEmpty else {
            throw AIError.missingModel
        }
        let suppliedModels = availableModels.map(normalizedModelIDs)
        if !secret.isEmpty, let suppliedModels, !suppliedModels.contains(modelName) {
            throw AIError.missingModel
        }
        let models: [String]
        if secret.isEmpty {
            models = []
        } else if let suppliedModels {
            models = suppliedModels
        } else if address != self.baseURL || secret != self.apiKey {
            models = []
        } else {
            models = self.availableModels
        }
        var profiles = customProfiles
        let id = legacyProfileID ?? UUID()
        let profile = AICustomProfile(id: id, name: profiles.first(where: { $0.id == id })?.name ?? profileName("", address: address),
                                      baseURL: address, model: modelName, availableModels: models, usesLegacyCredential: true)
        if let index = profiles.firstIndex(where: { $0.id == id }) { profiles[index] = profile }
        else if !secret.isEmpty { profiles.append(profile) }
        let profileData = try JSONEncoder().encode(profiles)
        try credentials.write(secret)
        defaults.set(address, forKey: "ai.baseURL")
        defaults.set(modelName, forKey: "ai.model")
        defaults.set(models, forKey: "ai.availableModels")
        self.baseURL = address
        self.apiKey = secret
        self.model = modelName
        self.availableModels = models
        credentialReadError = nil
        if profiles.contains(where: { $0.id == id }) {
            legacyProfileID = id
            defaults.set(id.uuidString, forKey: "ai.legacyProfileID")
            commitProfiles(profiles, data: profileData, selected: .custom(id))
        } else { configurationRevision &+= 1 }
    }
}

protocol AICredentialStorage {
    func read() throws -> String?
    func write(_ value: String) throws
}

struct AICredentialStore: AICredentialStorage {
    private let service = "ReadingToolDaily.AI"
    private let account = "api-key"

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    func read() throws -> String? {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data,
              let value = String(data: data, encoding: .utf8) else { throw AIError.keychain(status) }
        return value
    }

    func write(_ value: String) throws {
        if value.isEmpty {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw AIError.keychain(status)
            }
            return
        }
        let attributes = [kSecValueData as String: Data(value.utf8)]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else { throw AIError.keychain(updateStatus) }
        var item = query
        item[kSecValueData as String] = Data(value.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw AIError.keychain(status) }
    }
}

enum AIExplanationPurpose: Equatable {
    case lookup
    case translation
    case prefill
    case intensive
}

enum IntensiveReadingPrompt {
    static let task = """
    The selectedText JSON contains sentence records with an integer id, exact source sentence, and words array. Each word has a zero-based id in the supplied order and its exact source word. Translate every source sentence naturally and independently, and include every sentence exactly once.
    Return only valid JSON in this shape: {"sentences":[{"id":0,"translation":"...","links":[{"sourceWordIDs":[0,1],"targetPhrases":[{"text":"...","occurrence":0}]}]}]}. Keep each input sentence id unchanged and use only its supplied word IDs.
    Links are deliberate semantic hover groups, not forced word-for-word alignment. Precision matters more than coverage of function words: prefer omission over a weak or debatable link, but capture clear, useful content. Prioritize names, places, dates, quantities, technical terms, key actions, and key descriptions whenever the translation has an exact match. Make each link independently useful to a learner when hovered. Usually align content words or short idiomatic phrases; do not annotate every token or create one link per word just to increase coverage. Articles, pronouns, ordinary prepositions, auxiliaries, and routine conjunctions should normally remain unmatched. Explicit negation and logical contrast or choice (such as not, no, but, however, although, or rather than) are high-priority when the translation expresses them clearly; use a narrow target phrase when possible. Include other function words only when they carry useful meaning in context, such as modality, cause, time, or quantity, and group them with the related content word when that makes a natural unit.
    Use the smallest natural meaning-bearing source unit that makes sense on its own: use one word when it has a distinct useful translation, and group words only for a fixed expression, phrasal verb, or meaning naturally expressed together. Every source word in a link must contribute to its target meaning. Do not map one source word to a whole clause, a grammatical expansion, or unrelated parts of the translation. Do not combine separate concepts merely because they are adjacent. A normal sentence should have only a handful of links, with zero links allowed when nothing is precise and useful.
    Preserve polarity: whenever no, not, never, or another negative changes the meaning, include it with the smallest predicate or noun phrase that expresses the same absence or negation. Never link a negative source unit to an affirmative-only target phrase. For example, "no assessment was forthcoming" must align to a target phrase that expresses that no assessment appeared, not only to the positive concept "assessment".
    A sourceWordIDs list may contain contiguous or discontinuous IDs only when those words form one semantic unit. Every target phrase must express only the meaning contributed by those IDs, without neighboring concepts or modifiers supplied only by wider context. Do not map a word to a merely related nearby concept when its own meaning is implicit or translated with another part of speech; if "exhibition" is rendered as "展出", do not map it to "画廊" when that phrase translates "Macquarie Galleries". For example, "Aboriginal art" may map to "原住民艺术", not "澳大利亚原住民艺术" unless Australian/Australia is in those source IDs.
    Check target ranges against every other link. Avoid overlap unless the source meanings genuinely share that exact expression. If translation order puts another concept inside the target wording, split into exact, non-overlapping fragments and link the other concept separately when useful. For "using striking contrasts of black and white" translated as "运用了醒目的黑白对比", map "using striking contrasts" only to "运用了醒目的" and "对比", then map "black and white" to "黑白"; do not let the first link swallow or overlap "黑白". For "Far from drifting, as proposed by Sharp" translated with "并非像夏普所说的那样随波漂流", map "Far from drifting" only to "并非" and "随波漂流"; keep "像夏普所说的那样" out, and map "Sharp" separately when useful. For "in comparison with earlier works," separate the comparison from "earlier works."
    If an object or another concept is nested inside a target phrase, avoid parent-child highlights: for "convinced the public" translated as "让公众相信", map "convinced" to the separate fragments "让" and "相信" and map "public" to "公众", or combine the source words and use the whole phrase once. When adjacent source units are jointly expressed by one indivisible target phrase, either group them or let both source links point to that exact same target range; do not assign a partial nested range to one link and the whole phrase to another. For example, if "or perhaps" is expressed as the single Chinese phrase "或许", link the combined source phrase to "或许" once instead of creating nested links "or" to "或" and "perhaps" to "或许".
    A link may contain multiple target phrases when that compact source meaning is split into meaningful fragments, or when the same source meaning is clearly repeated in multiple translation locations; include each exact occurrence. Do not collect a clause, grammatical scaffolding, or distant paraphrases. Separate links may point to the same target phrase occurrence when multiple source units genuinely share it. Each targetPhrases item must be an exact, contiguous substring copied from the translation. occurrence is zero-based among all left-to-right exact substring matches, including a match inside a longer phrase. Select the occurrence that means the source concept: for "new research" in a translation containing both "重新" and "新研究", select the "新" in "新研究" (occurrence 1), not the earlier "新" inside "重新". Omit punctuation unless it belongs to the expression. Leave a source word unmatched when no useful, precise target exists.
    JSON keys and structural values stay in English; translations and target phrase text use the reply language. Do not include Markdown or extra keys.
    """
}

struct AIClient {
    private let session: URLSession
    private let redirectGuard = AICustomRedirectGuard()

    init(session: URLSession = .shared) { self.session = session }

    func fetchModels(baseURL: String, apiKey: String) async throws -> [String] {
        try await fetchModels(baseURL: baseURL, apiKey: apiKey, authentication: .apiKey)
    }

    func fetchModels(baseURL: String, apiKey: String, authentication: AICustomAuthentication) async throws -> [String] {
        let endpoint = try AIConfiguration.modelsURL(for: baseURL)
        let secret = authentication == .apiKey ? apiKey.trimmingCharacters(in: .whitespacesAndNewlines) : ""
        guard authentication == .none || !secret.isEmpty else { throw AIError.missingAPIKey }
        guard secret.rangeOfCharacter(from: .newlines) == nil else { throw AIError.invalidAPIKey }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.timeoutInterval = 45
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if authentication == .apiKey { request.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization") }

        do {
            try Task.checkCancellation()
            let (data, response) = try await session.data(for: request, delegate: redirectGuard)
            try Task.checkCancellation()
            guard let http = response as? HTTPURLResponse else { throw AIError.invalidModelsResponse }
            guard (200..<300).contains(http.statusCode) else { throw AIError.modelsHTTP(http.statusCode) }
            guard data.count <= 4_194_304,
                  let result = try? JSONDecoder().decode(ModelsResponse.self, from: data) else {
                throw AIError.invalidModelsResponse
            }
            let models = normalizedModelIDs(result.data.map(\.id))
            guard !models.isEmpty else { throw AIError.emptyModels }
            return models
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError {
            if error.code == .cancelled { throw CancellationError() }
            if error.code == .timedOut { throw AIError.timedOut }
            throw AIError.connectionFailed
        } catch let error as AIError {
            throw error
        } catch {
            throw AIError.invalidModelsResponse
        }
    }

    func explain(selection: String, context: String, focusedSentence: String? = nil,
                 purpose: AIExplanationPurpose = .lookup,
                 configuration: AIConfiguration) async throws -> String {
        let configuration = try configuration.validated()
        let explanationRequest = try AIExplanationRequest(selection: selection, context: context,
            focusedSentence: focusedSentence, purpose: purpose, language: configuration.targetLanguage)
        let messages = [
            Message(role: "system", content: explanationRequest.instructions),
            Message(role: "user", content: explanationRequest.inputJSON)
        ]
        var request = URLRequest(url: try AIConfiguration.endpointURL(for: configuration.baseURL))
        request.httpMethod = "POST"
        request.timeoutInterval = 45
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if configuration.authentication == .apiKey {
            request.setValue("Bearer \(configuration.apiKey)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONEncoder().encode(Request(model: configuration.model, messages: messages,
                                                            maxTokens: explanationRequest.maximumResponseTokens))

        do {
            try Task.checkCancellation()
            let (data, response) = try await session.data(for: request, delegate: redirectGuard)
            try Task.checkCancellation()
            guard let http = response as? HTTPURLResponse else { throw AIError.invalidResponse }
            guard (200..<300).contains(http.statusCode) else { throw AIError.http(http.statusCode) }
            guard data.count <= 1_048_576,
                  let result = try? JSONDecoder().decode(Response.self, from: data) else {
                throw AIError.invalidResponse
            }
            if (purpose == .translation || purpose == .intensive), result.choices.first?.finishReason == "length" {
                throw AIError.outputTruncated
            }
            return try explanationRequest.validatedResponse(result.choices.first?.message.content ?? "")
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError {
            if error.code == .cancelled { throw CancellationError() }
            if error.code == .timedOut { throw AIError.timedOut }
            throw AIError.connectionFailed
        } catch let error as AIError {
            throw error
        } catch {
            throw AIError.invalidResponse
        }
    }

    private struct ModelsResponse: Decodable {
        let data: [Model]
        struct Model: Decodable { let id: String }
    }

    private struct Message: Encodable {
        let role: String
        let content: String
    }

    private struct Request: Encodable {
        let model: String
        let messages: [Message]
        let max_tokens: Int
        let temperature = 0.2
        let stream = false

        init(model: String, messages: [Message], maxTokens: Int) {
            self.model = model
            self.messages = messages
            max_tokens = maxTokens
        }
    }

    private struct Response: Decodable {
        let choices: [Choice]
        struct Choice: Decodable {
            let message: Reply
            let finishReason: String?
            enum CodingKeys: String, CodingKey {
                case message
                case finishReason = "finish_reason"
            }
            struct Reply: Decodable { let content: String? }
        }
    }
}

func normalizedModelIDs(_ identifiers: [String]) -> [String] {
    Array(Set(identifiers.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty && $0.rangeOfCharacter(from: .newlines) == nil })).sorted()
}
