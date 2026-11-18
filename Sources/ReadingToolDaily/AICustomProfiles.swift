import Foundation
import Security

enum AIServiceKind: String, Codable, CaseIterable, Hashable {
    case chatGPT
    case customAPI
    case localModel
    case appleIntelligence

    /// Keep the historical local-model value decodable without a separate settings category.
    var settingsKind: AIServiceKind { self == .localModel ? .customAPI : self }

    static let settingsCases: [AIServiceKind] = [.chatGPT, .customAPI, .appleIntelligence]

    func preferredProfile(in profiles: [AICustomProfile], selection: AIServiceSelection) -> AICustomProfile? {
        let candidates = profiles.filter { $0.kind.settingsKind == settingsKind }
        if case .custom(let id) = selection,
           let active = candidates.first(where: { $0.id == id }) { return active }
        return candidates.first
    }
}

enum AICustomAuthentication: String, Codable, CaseIterable, Hashable {
    case apiKey
    case none
}

/// Public preferences contain the service description, never its API credential.
struct AICustomProfile: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    var baseURL: String
    var model: String
    var availableModels: [String]
    var usesLegacyCredential: Bool = false
    var kind: AIServiceKind = .customAPI
    var authentication: AICustomAuthentication = .apiKey

    init(id: UUID, name: String, baseURL: String, model: String, availableModels: [String],
         usesLegacyCredential: Bool = false, kind: AIServiceKind = .customAPI,
         authentication: AICustomAuthentication = .apiKey) {
        self.id = id
        self.name = name
        self.baseURL = baseURL
        self.model = model
        self.availableModels = availableModels
        self.usesLegacyCredential = usesLegacyCredential
        self.kind = kind
        self.authentication = authentication
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, baseURL, model, availableModels, usesLegacyCredential, kind, authentication
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        baseURL = try values.decode(String.self, forKey: .baseURL)
        model = try values.decode(String.self, forKey: .model)
        availableModels = try values.decode([String].self, forKey: .availableModels)
        usesLegacyCredential = try values.decodeIfPresent(Bool.self, forKey: .usesLegacyCredential) ?? false
        kind = try values.decodeIfPresent(AIServiceKind.self, forKey: .kind) ?? .customAPI
        authentication = try values.decodeIfPresent(AICustomAuthentication.self, forKey: .authentication) ?? .apiKey
        guard kind == .customAPI || kind == .localModel else {
            throw DecodingError.dataCorruptedError(forKey: .kind, in: values,
                                                   debugDescription: "Unsupported custom service category")
        }
    }
}

enum AIServiceSelection: Codable, Equatable, Hashable {
    case chatGPT
    case custom(UUID)
    case appleIntelligence

    var preferenceValue: String {
        switch self {
        case .chatGPT: return "chatGPT"
        case .custom(let id): return "custom:" + id.uuidString
        case .appleIntelligence: return "appleIntelligence"
        }
    }

    init?(preferenceValue: String) {
        if preferenceValue == "chatGPT" { self = .chatGPT }
        else if preferenceValue == "appleIntelligence" { self = .appleIntelligence }
        else if preferenceValue.hasPrefix("custom:"),
                let id = UUID(uuidString: String(preferenceValue.dropFirst(7))) {
            self = .custom(id)
        } else { return nil }
    }
}

protocol AICustomCredentialStorage {
    func read(profileID: UUID) throws -> String?
    func write(_ value: String?, profileID: UUID) throws
}

struct AICustomKeychainStore: AICustomCredentialStorage {
    private func query(_ id: UUID) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "ReadingToolDaily.AIProfiles",
         kSecAttrAccount as String: id.uuidString]
    }

    func read(profileID: UUID) throws -> String? {
        var request = query(profileID)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data,
              let value = String(data: data, encoding: .utf8) else { throw AIError.keychain(status) }
        return value
    }

    func write(_ value: String?, profileID: UUID) throws {
        let query = query(profileID)
        guard let value else {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw AIError.keychain(status) }
            return
        }
        let attributes = [kSecValueData as String: Data(value.utf8)]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw AIError.keychain(status) }
        var item = query
        item[kSecValueData as String] = Data(value.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let addStatus = SecItemAdd(item as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw AIError.keychain(addStatus) }
    }
}

protocol AICustomServing {
    func fetchModels(baseURL: String, apiKey: String) async throws -> [String]
    func fetchModels(baseURL: String, apiKey: String, authentication: AICustomAuthentication) async throws -> [String]
    func explain(selection: String, context: String, focusedSentence: String?,
                 purpose: AIExplanationPurpose, configuration: AIConfiguration) async throws -> String
}

extension AICustomServing {
    func fetchModels(baseURL: String, apiKey: String, authentication: AICustomAuthentication) async throws -> [String] {
        try await fetchModels(baseURL: baseURL, apiKey: authentication == .apiKey ? apiKey : "")
    }
}

extension AIClient: AICustomServing { }

/// Even a redirect to an otherwise trusted host can change who receives a custom API key.
final class AICustomRedirectGuard: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
