import Combine
import Foundation

/// Edits stay in memory until both the exact request configuration is verified and Save succeeds.
@MainActor
final class AICustomConfigurationDraft: ObservableObject {
    let kind: AIServiceKind
    @Published var name: String
    @Published var address: String { didSet { if address != oldValue { configurationChanged(resetModels: true) } } }
    @Published var apiKey: String {
        didSet {
            if apiKey != oldValue {
                if !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { credentialReadFailed = false }
                configurationChanged(resetModels: !isReloadingCredential)
            }
        }
    }
    @Published var model: String { didSet { if model != oldValue { configurationChanged(resetModels: false) } } }
    @Published var authentication: AICustomAuthentication {
        didSet {
            if authentication != oldValue {
                if authentication == .none { credentialReadFailed = false }
                configurationChanged(resetModels: true)
            }
        }
    }
    @Published private(set) var models: [String]
    @Published private(set) var isChecking = false
    @Published private(set) var isFetching = false
    @Published private(set) var isSaving = false
    @Published private(set) var validationIssue: AIUsageIssue?
    @Published private(set) var fetchIssue: AIUsageIssue?
    @Published private(set) var saveIssue: AIUsageIssue?
    @Published private(set) var savedID: UUID?
    @Published private(set) var validatedConfiguration: AIConfiguration?
    @Published private(set) var testState: AIServiceTestState = .idle

    private let client: AICustomServing
    private let timeoutNanoseconds: UInt64
    private let saveAction: (String, AIConfiguration, [String]) throws -> UUID
    private let credentialReload: (() throws -> String)?
    private var originalName: String
    private var originalConfiguration: AIConfiguration?
    private var originalModels: [String]
    private var activationRequired: Bool
    private var requiresFreshValidation = false
    private var credentialReadFailed: Bool
    private var isReloadingCredential = false
    private var validationID: UUID?
    private var fetchID: UUID?
    private var validationTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?
    private var fetchTask: Task<Void, Never>?
    private var fetchTimeoutTask: Task<Void, Never>?

    convenience init(settings: AISettingsStore, profile: AICustomProfile?, kind: AIServiceKind = .customAPI,
                     requiresActivation: Bool = false,
                     client: AICustomServing = AIClient()) {
        let kind = profile?.kind ?? kind
        let authentication = profile?.authentication ?? .none
        let key: String
        let readIssue: AIUsageIssue?
        do { key = try profile.map { try settings.apiKey(for: $0.id) } ?? ""; readIssue = nil }
        catch { key = ""; readIssue = AIUsageIssue.from(error) }
        let credentialReload: (() throws -> String)? = profile.flatMap { profile in
            guard profile.authentication == .apiKey else { return nil }
            return { try settings.reloadAPIKey(for: profile.id) }
        }
        let idBox = ProfileIDBox(id: profile?.id)
        self.init(name: profile?.name ?? "", address: profile?.baseURL ?? "", apiKey: key,
                  model: profile?.model ?? "", models: profile?.availableModels ?? [],
                  kind: kind, authentication: authentication,
                  isSaved: profile != nil, requiresActivation: requiresActivation,
                  initialIssue: readIssue, credentialReload: credentialReload, client: client) { name, configuration, models in
            let saved = try settings.saveCustomProfile(id: idBox.id, name: name, baseURL: configuration.baseURL,
                                                       apiKey: configuration.apiKey, model: configuration.model,
                                                       availableModels: models, select: true, kind: kind,
                                                       authentication: configuration.authentication)
            idBox.id = saved
            return saved
        }
        savedID = profile?.id
    }

    init(name: String = "", address: String = "", apiKey: String = "", model: String = "",
         models: [String] = [], kind: AIServiceKind = .customAPI,
         authentication: AICustomAuthentication = .apiKey,
         isSaved: Bool = false, requiresActivation: Bool = false,
         initialIssue: AIUsageIssue? = nil, credentialReload: (() throws -> String)? = nil, client: AICustomServing,
         timeoutNanoseconds: UInt64 = 20_000_000_000,
         saveAction: @escaping (String, AIConfiguration, [String]) throws -> UUID) {
        self.kind = kind
        self.authentication = authentication
        self.name = name
        self.address = address
        self.apiKey = apiKey
        self.model = model
        self.models = models
        self.client = client
        self.timeoutNanoseconds = timeoutNanoseconds
        self.saveAction = saveAction
        self.credentialReload = credentialReload
        credentialReadFailed = initialIssue.map(Self.isCredentialStorageFailure) ?? false
        originalName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        originalModels = models
        originalConfiguration = isSaved ? (try? AIConfiguration(baseURL: address, apiKey: apiKey, model: model,
                                                                authentication: authentication).validated()) : nil
        activationRequired = requiresActivation
        validationIssue = initialIssue
    }

    var configuration: AIConfiguration? {
        try? AIConfiguration(baseURL: address, apiKey: apiKey, model: model, authentication: authentication).validated()
    }

    var hasChanges: Bool {
        if activationRequired { return true }
        if originalConfiguration == nil {
            return [name, address, apiKey, model].contains { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        }
        return configuration != originalConfiguration || name.trimmingCharacters(in: .whitespacesAndNewlines) != originalName ||
            models != originalModels
    }

    var canSave: Bool {
        guard !isSaving, !isChecking, hasChanges, let configuration else { return false }
        if validatedConfiguration == configuration { return true }
        // Updating local metadata or its model cache does not change the active request.
        return !activationRequired && !requiresFreshValidation && validationIssue == nil && configuration == originalConfiguration
    }

    var canFetchModels: Bool {
        !address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            (authentication == .none || !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    var issue: AIUsageIssue? { saveIssue ?? validationIssue }

    var errorMessage: String? {
        guard let issue else { return nil }
        switch issue {
        case .custom(let error) where [.invalidAddress, .missingModel, .missingAPIKey, .invalidAPIKey].contains(error):
            return error.errorDescription
        default:
            return issue.localizedDescription
        }
    }

    var fetchStatusMessage: String? {
        guard let fetchIssue else { return nil }
        switch fetchIssue {
        case .custom(.modelsHTTP(401)):
            return L("获取模型列表的身份验证失败，请检查 API 密钥；也可手动输入模型 ID。",
                     "Model list authentication failed. Check the API key, or enter a model ID manually.")
        case .custom(.modelsHTTP(403)):
            return L("无权获取模型列表，可手动输入有权使用的模型 ID。",
                     "Access to the model list was denied. Enter an authorized model ID manually.")
        case .custom(.modelsHTTP(404)):
            return L("找不到模型列表接口，可检查 API 地址或手动输入模型 ID。",
                     "The model list endpoint was not found. Check the API address, or enter a model ID manually.")
        case .custom(.emptyModels):
            return L("服务返回了空模型列表，请手动输入模型 ID。",
                     "The service returned an empty model list. Enter a model ID manually.")
        case .custom(.invalidModelsResponse):
            return L("无法读取模型列表格式，可手动输入模型 ID。",
                     "The model list format could not be read. Enter a model ID manually.")
        case .custom(.timedOut):
            return L("获取模型列表超时，可重试或手动输入模型 ID。",
                     "Fetching the model list timed out. Try again, or enter a model ID manually.")
        default:
            return fetchIssue.localizedDescription + L(" 可手动输入模型 ID。", " You can enter a model ID manually.")
        }
    }

    func selectModel(_ selected: String) {
        if model != selected { model = selected }
    }

    @discardableResult
    func commitManualModel(_ identifier: String) -> Bool {
        let identifier = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !identifier.isEmpty, identifier.rangeOfCharacter(from: .newlines) == nil else { return false }
        models = normalizedModelIDs(models + [identifier])
        selectModel(identifier)
        return true
    }

    func retryValidation() {
        guard !isSaving, !isChecking else { return }
        if canReloadCredential, let credentialReload {
            do {
                let recovered = try credentialReload()
                credentialReadFailed = false
                isReloadingCredential = true
                apiKey = recovered
                isReloadingCredential = false
                if recovered.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    validationIssue = .custom(.missingAPIKey)
                    testState = .unavailable
                    return
                }
            } catch {
                let issue = AIUsageIssue.from(error)
                credentialReadFailed = Self.isCredentialStorageFailure(issue)
                validationIssue = issue
                testState = .unavailable
                return
            }
        }
        scheduleValidation()
    }

    private var canReloadCredential: Bool {
        authentication == .apiKey && credentialReadFailed && credentialReload != nil &&
            apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func isCredentialStorageFailure(_ issue: AIUsageIssue) -> Bool {
        switch issue {
        case .custom(.keychain), .custom(.profileStorage): return true
        default: return false
        }
    }

    private func configurationChanged(resetModels: Bool) {
        cancelValidation()
        testState = .idle
        requiresFreshValidation = true
        if resetModels {
            cancelFetch()
            models = []
            fetchIssue = nil
        }
        validationIssue = nil
        saveIssue = nil
        validatedConfiguration = nil
    }

    private func scheduleValidation() {
        cancelValidation()
        requiresFreshValidation = true
        validatedConfiguration = nil
        validationIssue = nil
        saveIssue = nil
        let configuration: AIConfiguration
        do {
            configuration = try AIConfiguration(baseURL: address, apiKey: apiKey, model: model,
                                                authentication: authentication).validated()
        } catch {
            validationIssue = AIUsageIssue.from(error)
            testState = .unavailable
            return
        }
        let id = UUID()
        validationID = id
        isChecking = true
        testState = .testing
        let client = client
        validationTask = Task { [weak self] in
            do {
                try Task.checkCancellation()
                guard let self, self.validationID == id else { return }
                self.startValidationTimeout(id: id)
                let response = try await client.explain(selection: "bright", context: "The room is bright.",
                                                        focusedSentence: "The room is bright.", purpose: .prefill,
                                                        configuration: configuration)
                try Task.checkCancellation()
                guard self.validationID == id, self.configuration == configuration else { return }
                guard !response.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AIError.emptyResponse }
                self.validatedConfiguration = configuration
                self.testState = .available
                self.finishValidation(id: id)
            } catch is CancellationError { }
            catch {
                guard let self, self.validationID == id, self.configuration == configuration else { return }
                self.validationIssue = AIUsageIssue.from(error)
                self.testState = .unavailable
                self.finishValidation(id: id)
            }
        }
    }

    private func startValidationTimeout(id: UUID) {
        let delay = timeoutNanoseconds
        timeoutTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: delay) } catch { return }
            guard let self, self.validationID == id else { return }
            self.validationIssue = .custom(.timedOut)
            self.testState = .unavailable
            self.cancelValidation()
        }
    }

    private func finishValidation(id: UUID) {
        guard validationID == id else { return }
        validationID = nil
        isChecking = false
        validationTask = nil
        timeoutTask?.cancel()
        timeoutTask = nil
    }

    private func cancelValidation() {
        validationID = nil
        validationTask?.cancel()
        validationTask = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        isChecking = false
    }

    func fetchModels() {
        guard !isFetching, !isSaving, canFetchModels else { return }
        let address = address.trimmingCharacters(in: .whitespacesAndNewlines)
        let authentication = authentication
        let key = authentication == .apiKey ? apiKey.trimmingCharacters(in: .whitespacesAndNewlines) : ""
        let id = UUID()
        fetchID = id
        isFetching = true
        fetchIssue = nil
        let client = client
        let timeout = timeoutNanoseconds
        fetchTimeoutTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: timeout) } catch { return }
            guard let self, self.fetchID == id else { return }
            self.fetchIssue = .custom(.timedOut)
            self.cancelFetch()
        }
        fetchTask = Task { [weak self] in
            do {
                let fetchedModels = try await client.fetchModels(baseURL: address, apiKey: key, authentication: authentication)
                try Task.checkCancellation()
                guard let self, self.fetchID == id else { return }
                let models = normalizedModelIDs(fetchedModels)
                guard !models.isEmpty else { throw AIError.emptyModels }
                self.models = models
                self.finishFetch(id: id)
                if !models.contains(self.model.trimmingCharacters(in: .whitespacesAndNewlines)) {
                    self.model = ""
                }
            } catch is CancellationError { }
            catch {
                guard let self, self.fetchID == id else { return }
                self.fetchIssue = AIUsageIssue.from(error)
                self.finishFetch(id: id)
            }
        }
    }

    private func finishFetch(id: UUID) {
        guard fetchID == id else { return }
        fetchID = nil
        isFetching = false
        fetchTask = nil
        fetchTimeoutTask?.cancel()
        fetchTimeoutTask = nil
    }

    private func cancelFetch() {
        fetchID = nil
        fetchTask?.cancel()
        fetchTask = nil
        fetchTimeoutTask?.cancel()
        fetchTimeoutTask = nil
        isFetching = false
    }

    func cancelPending() {
        cancelValidation()
        cancelFetch()
        if testState == .testing { testState = .idle }
    }

    @discardableResult
    func save() -> Bool {
        guard canSave, let configuration else { return false }
        isSaving = true
        saveIssue = nil
        defer { isSaving = false }
        do {
            savedID = try saveAction(name, configuration, models)
            originalName = name.trimmingCharacters(in: .whitespacesAndNewlines)
            originalConfiguration = configuration
            originalModels = models
            activationRequired = false
            requiresFreshValidation = false
            return true
        } catch { saveIssue = AIUsageIssue.from(error); return false }
    }

}

private final class ProfileIDBox {
    var id: UUID?
    init(id: UUID?) { self.id = id }
}
