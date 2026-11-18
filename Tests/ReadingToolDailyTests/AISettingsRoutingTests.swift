import Foundation
import Security
import XCTest
@testable import ReadingToolDaily

@MainActor
final class AISettingsRoutingTests: XCTestCase {
    func testExistingProfileMetadataDecodesWithAPIKeyAndCustomCategory() throws {
        let id = UUID()
        let metadata = """
        [{"id":"\(id.uuidString)","name":"Existing","baseURL":"https://existing.example/v1",
          "model":"existing-model","availableModels":["existing-model"],"usesLegacyCredential":true}]
        """
        let profiles = try JSONDecoder().decode([AICustomProfile].self, from: Data(metadata.utf8))
        let profile = try XCTUnwrap(profiles.first)
        XCTAssertEqual(profile.id, id)
        XCTAssertEqual(profile.kind, .customAPI)
        XCTAssertEqual(profile.authentication, .apiKey)
        XCTAssertTrue(profile.usesLegacyCredential)
    }

    func testMergedAPISettingsRetainActiveLegacyLocalProfileAndCredentials() async throws {
        let defaults = preferences()
        let secrets = RoutingProfileCredentials()
        let client = RoutingCustomClient()
        let settings = makeSettings(defaults: defaults, secrets: secrets, client: client)
        let cloudID = try save(settings, name: "Cloud")
        let localID = try settings.saveCustomProfile(name: "Local", baseURL: "http://127.0.0.1:1234/v1",
            apiKey: "synthetic-local-secret", model: "local-model", availableModels: ["local-model"],
            kind: .localModel, authentication: .apiKey)
        let metadata = defaults.data(forKey: "ai.customProfiles")
        let writes = secrets.writes

        let initial = AISettingsDestination(service: settings.selectedService, profiles: settings.customProfiles)
        let reopenedPage = AISettingsDestination(kind: .customAPI, service: settings.selectedService,
                                                 profiles: settings.customProfiles)
        XCTAssertEqual(initial.kind, .customAPI)
        XCTAssertEqual(initial.profileID, localID)
        XCTAssertEqual(reopenedPage, initial, "Returning to Custom API must keep the active historical local connection")
        let profile = try XCTUnwrap(AIServiceKind.customAPI.preferredProfile(
            in: settings.customProfiles, selection: settings.selectedService))
        XCTAssertEqual(profile.id, localID)
        let draft = AICustomConfigurationDraft(settings: settings, profile: profile, client: client)
        defer { draft.cancelPending() }
        await Task.yield()
        XCTAssertEqual(draft.address, "http://127.0.0.1:1234/v1")
        XCTAssertEqual(draft.apiKey, "synthetic-local-secret")
        XCTAssertEqual(draft.models, ["local-model"])
        XCTAssertFalse(draft.hasChanges)
        XCTAssertTrue(client.configurations.isEmpty)
        XCTAssertEqual(settings.selectedService, .custom(localID))
        XCTAssertEqual(settings.customProfiles.map(\.id), [cloudID, localID])
        XCTAssertEqual(settings.customProfiles.last?.kind, .localModel, "Presentation merging must not rewrite saved metadata")
        XCTAssertEqual(defaults.data(forKey: "ai.customProfiles"), metadata)
        XCTAssertEqual(secrets.writes, writes)
    }

    func testMergedAPISettingsIncludeHistoricalLocalProfileWhenAnotherServiceIsActive() throws {
        let profiles = [
            AICustomProfile(id: UUID(), name: "Local", baseURL: "http://127.0.0.1:1234/v1", model: "local-model",
                            availableModels: ["local-model"], kind: .localModel, authentication: .none),
            AICustomProfile(id: UUID(), name: "Cloud", baseURL: "https://custom.example/v1", model: "cloud-model",
                            availableModels: ["cloud-model"])
        ]
        XCTAssertEqual(AIServiceKind.settingsCases, [.chatGPT, .customAPI, .appleIntelligence])
        let customPage = AISettingsDestination(kind: .customAPI, service: .chatGPT, profiles: profiles)
        let legacyPage = AISettingsDestination(kind: .localModel, service: .chatGPT, profiles: profiles)
        XCTAssertEqual(customPage.kind, .customAPI)
        XCTAssertEqual(customPage.profileID, profiles.first?.id)
        XCTAssertEqual(legacyPage, customPage, "An old local destination must resolve to the same unified API form")
        XCTAssertEqual(AIServiceKind.customAPI.preferredProfile(in: profiles, selection: .appleIntelligence)?.id,
                       profiles.first?.id)
    }

    func testLocalProfilePersistsRoutesAndDeletesWithoutAccessingProfileKeychain() async throws {
        let defaults = preferences()
        let secrets = RoutingProfileCredentials()
        secrets.readError = .keychain(errSecAuthFailed)
        secrets.writeError = .keychain(errSecAuthFailed)
        let client = RoutingCustomClient()
        let settings = makeSettings(defaults: defaults, secrets: secrets, client: client)
        let revision = settings.configurationRevision
        let id = try settings.saveCustomProfile(name: "Local", baseURL: "http://127.0.0.1:1234/v1",
                                                 apiKey: "unused-secret", model: "local-model",
                                                 kind: .localModel, authentication: .none)
        XCTAssertEqual(settings.selectedService, .custom(id))
        XCTAssertGreaterThan(settings.configurationRevision, revision)
        XCTAssertEqual(settings.customProfiles.first?.kind, .localModel)
        XCTAssertEqual(settings.customProfiles.first?.authentication, AICustomAuthentication.none)
        XCTAssertTrue(settings.isAIConfigured)
        XCTAssertEqual(try settings.apiKey(for: id), "")
        XCTAssertEqual(try settings.reloadAPIKey(for: id), "")
        _ = try await settings.explain(selection: "bank", context: "A river bank.")
        XCTAssertEqual(client.configurations.last?.authentication, AICustomAuthentication.none)
        XCTAssertEqual(client.configurations.last?.apiKey, "")
        XCTAssertEqual(client.configurations.last?.model, "local-model")

        let reopened = makeSettings(defaults: defaults, secrets: secrets)
        XCTAssertEqual(reopened.selectedService, .custom(id))
        XCTAssertEqual(reopened.customProfiles, settings.customProfiles)
        try reopened.selectService(.chatGPT)
        try reopened.selectService(.custom(id))
        XCTAssertTrue(reopened.isAIConfigured)
        let metadata = try XCTUnwrap(defaults.data(forKey: "ai.customProfiles"))
        XCTAssertFalse(String(decoding: metadata, as: UTF8.self).contains("unused-secret"))
        try reopened.deleteCustomProfile(id: id)
        XCTAssertTrue(secrets.reads.isEmpty)
        XCTAssertTrue(secrets.writes.isEmpty)
    }

    func testChangingAuthenticationDiscardsPendingResultAndStopsUsingSavedKey() async throws {
        let client = RoutingCustomClient()
        let gate = RoutingGate()
        let started = expectation(description: "Authenticated request entered")
        client.onExplain = { _ in started.fulfill(); return try await gate.wait() }
        let secrets = RoutingProfileCredentials()
        let settings = makeSettings(secrets: secrets, client: client)
        let id = try settings.saveCustomProfile(name: "Local", baseURL: "http://127.0.0.1:1234/v1",
                                                 apiKey: "saved-secret", model: "local-model", kind: .localModel)
        let pending = Task { try await settings.explain(selection: "bank", context: "A river bank.") }
        await fulfillment(of: [started], timeout: 2)
        let keychainWrites = secrets.writes.count
        try settings.saveCustomProfile(id: id, name: "Local", baseURL: "http://127.0.0.1:1234/v1",
                                       apiKey: "saved-secret", model: "local-model", kind: .localModel,
                                       authentication: .none)
        gate.complete(.success("stale result"))
        await assertCancelled(pending)
        XCTAssertEqual(secrets.writes.count, keychainWrites)
        XCTAssertEqual(try settings.configuration(for: id).apiKey, "")
        XCTAssertEqual(try settings.configuration(for: id).authentication, .none)
    }

    func testValidLegacyConfigurationMigratesWithoutWritingOrCopyingItsSecret() throws {
        let defaults = preferences()
        defaults.set("https://legacy.example/v1", forKey: "ai.baseURL")
        defaults.set("legacy-model", forKey: "ai.model")
        defaults.set(["legacy-model"], forKey: "ai.availableModels")
        let legacy = RoutingLegacyCredentials("legacy-secret")
        let secrets = RoutingProfileCredentials()
        let settings = makeSettings(defaults: defaults, legacy: legacy, secrets: secrets)

        let migrated = try XCTUnwrap(settings.customProfiles.first)
        XCTAssertEqual(settings.customProfiles.count, 1)
        XCTAssertEqual(settings.selectedService, .custom(migrated.id))
        XCTAssertEqual(migrated.baseURL, "https://legacy.example/v1")
        XCTAssertEqual(migrated.model, "legacy-model")
        XCTAssertEqual(migrated.availableModels, ["legacy-model"])
        XCTAssertTrue(settings.isAIConfigured)
        XCTAssertEqual(try settings.apiKey(for: migrated.id), "legacy-secret")
        XCTAssertTrue(legacy.writes.isEmpty)
        XCTAssertTrue(secrets.writes.isEmpty)
        let metadata = try XCTUnwrap(defaults.data(forKey: "ai.customProfiles"))
        XCTAssertFalse(String(decoding: metadata, as: UTF8.self).contains("legacy-secret"))
        XCTAssertNil(defaults.object(forKey: "ai.apiKey"))

        let reopened = makeSettings(defaults: defaults, legacy: legacy, secrets: secrets)
        XCTAssertEqual(reopened.customProfiles, settings.customProfiles)
        XCTAssertEqual(reopened.selectedService, .custom(migrated.id))
        XCTAssertTrue(legacy.writes.isEmpty)
    }

    func testMigrationDoesNotOverrideAnExplicitChatGPTSelection() throws {
        let defaults = preferences()
        defaults.set("https://legacy.example/v1", forKey: "ai.baseURL")
        defaults.set("legacy-model", forKey: "ai.model")
        defaults.set(AIServiceSelection.chatGPT.preferenceValue, forKey: "ai.selectedService")
        let settings = makeSettings(defaults: defaults, legacy: RoutingLegacyCredentials("legacy-secret"))
        XCTAssertEqual(settings.customProfiles.count, 1)
        XCTAssertEqual(settings.selectedService, .chatGPT)
    }

    func testUnreadableLegacyCredentialCanBeRetriedWithoutReplacingIt() throws {
        let defaults = preferences()
        defaults.set("https://legacy.example/v1", forKey: "ai.baseURL")
        defaults.set("legacy-model", forKey: "ai.model")
        let legacy = RoutingLegacyCredentials("legacy-secret")
        legacy.readError = .keychain(errSecAuthFailed)
        let settings = makeSettings(defaults: defaults, legacy: legacy)
        XCTAssertTrue(settings.customProfiles.isEmpty)
        XCTAssertNotNil(settings.customStorageIssue)
        XCTAssertTrue(legacy.writes.isEmpty)

        legacy.readError = nil
        settings.retryCustomStorage()
        let profile = try XCTUnwrap(settings.customProfiles.first)
        XCTAssertEqual(settings.selectedService, .custom(profile.id))
        XCTAssertEqual(try settings.apiKey(for: profile.id), "legacy-secret")
        XCTAssertTrue(legacy.writes.isEmpty)
        XCTAssertNil(settings.customStorageIssue)
    }

    func testEditingMigratedProfileUsesIndependentSecretAndPreservesLegacyRecord() throws {
        let defaults = preferences()
        defaults.set("https://legacy.example/v1", forKey: "ai.baseURL")
        defaults.set("legacy-model", forKey: "ai.model")
        let legacy = RoutingLegacyCredentials("legacy-secret")
        let secrets = RoutingProfileCredentials()
        let settings = makeSettings(defaults: defaults, legacy: legacy, secrets: secrets)
        let id = try XCTUnwrap(settings.customProfiles.first?.id)

        try settings.saveCustomProfile(id: id, name: "Updated", baseURL: "https://new.example/v1",
                                       apiKey: "new-secret", model: "new-model")
        XCTAssertEqual(try settings.apiKey(for: id), "new-secret")
        XCTAssertEqual(legacy.value, "legacy-secret")
        XCTAssertTrue(legacy.writes.isEmpty)
        XCTAssertEqual(secrets.values[id], "new-secret")
        XCTAssertEqual(defaults.string(forKey: "ai.baseURL"), "https://legacy.example/v1")
        XCTAssertEqual(defaults.string(forKey: "ai.model"), "legacy-model")

        try settings.deleteCustomProfile(id: id)
        XCTAssertEqual(legacy.value, "legacy-secret")
        XCTAssertTrue(legacy.writes.isEmpty)
        XCTAssertNil(secrets.values[id])
        let reopened = makeSettings(defaults: defaults, legacy: legacy, secrets: secrets)
        XCTAssertTrue(reopened.customProfiles.isEmpty, "Deleting the migrated entry must not migrate it again")
    }

    func testFailedProfileSecretWritePreservesOldProfileSelectionAndRevision() throws {
        let defaults = preferences()
        let secrets = RoutingProfileCredentials()
        let settings = makeSettings(defaults: defaults, secrets: secrets)
        let id = try save(settings, name: "A", key: "a-secret")
        let profile = settings.customProfiles
        let metadata = defaults.data(forKey: "ai.customProfiles")
        let revision = settings.configurationRevision
        secrets.writeError = .keychain(errSecAuthFailed)

        XCTAssertThrowsError(try settings.saveCustomProfile(id: id, name: "Changed", baseURL: "https://changed.example/v1",
                                                           apiKey: "changed-secret", model: "changed-model"))
        XCTAssertEqual(settings.customProfiles, profile)
        XCTAssertEqual(settings.selectedService, .custom(id))
        XCTAssertEqual(settings.configurationRevision, revision)
        XCTAssertEqual(defaults.data(forKey: "ai.customProfiles"), metadata)
        XCTAssertEqual(secrets.values[id], "a-secret")
        XCTAssertNotNil(settings.customStorageIssue)
    }

    func testMultipleProfilesRouteToTheirOwnKeysModelsAndLanguageWithoutChatGPT() async throws {
        let defaults = preferences()
        defaults.set(InterfaceLanguage.chinese.rawValue, forKey: "interface.language")
        let secrets = RoutingProfileCredentials()
        let client = RoutingCustomClient()
        let settings = makeSettings(defaults: defaults, secrets: secrets, client: client)
        let a = try settings.saveCustomProfile(name: "A", baseURL: "https://a.example/v1", apiKey: "a-secret", model: "a-model")
        let b = try settings.saveCustomProfile(name: "B", baseURL: "https://b.example/v1", apiKey: "b-secret", model: "b-model")
        XCTAssertFalse(settings.chatGPT.isSignedIn)
        let bText = try await settings.explain(selection: "bank", context: "river bank", purpose: .prefill)
        XCTAssertEqual(bText, "definition")
        try settings.selectService(.custom(a))
        _ = try await settings.explain(selection: "bank", context: "river bank")
        _ = try await settings.explain(selection: "A full sentence.", context: "A full sentence.",
                                       purpose: .translation)

        XCTAssertEqual(client.configurations.map(\.baseURL), ["https://b.example/v1", "https://a.example/v1", "https://a.example/v1"])
        XCTAssertEqual(client.configurations.map(\.apiKey), ["b-secret", "a-secret", "a-secret"])
        XCTAssertEqual(client.configurations.map(\.model), ["b-model", "a-model", "a-model"])
        XCTAssertEqual(client.purposes, [.prefill, .lookup, .translation])
        XCTAssertTrue(client.configurations.allSatisfy { $0.targetLanguage == .chinese })
        let reopened = makeSettings(defaults: defaults, secrets: secrets)
        XCTAssertEqual(reopened.selectedService, .custom(a))
        XCTAssertEqual(reopened.customProfiles.map(\.id), [a, b])
        XCTAssertEqual(try reopened.configuration(for: b).apiKey, "b-secret")
    }

    func testSwitchingProviderDiscardsOldResultWithoutSendingItToTheNewProvider() async throws {
        let client = RoutingCustomClient()
        let gate = RoutingGate()
        let started = expectation(description: "Custom request entered")
        client.onExplain = { _ in started.fulfill(); return try await gate.wait() }
        let settings = makeSettings(client: client)
        _ = try save(settings)
        let pending = Task { try await settings.explain(selection: "bank", context: "river bank") }
        await fulfillment(of: [started], timeout: 2)
        try settings.selectService(.chatGPT)
        gate.complete(.success("old definition"))
        await assertCancelled(pending)
        XCTAssertEqual(client.configurations.count, 1)
        XCTAssertEqual(settings.selectedService, .chatGPT)
        XCTAssertFalse(settings.chatGPT.isSignedIn)
    }

    func testEditingTheSelectedProfileDiscardsItsOlderRequest() async throws {
        let client = RoutingCustomClient()
        let gate = RoutingGate()
        let started = expectation(description: "Original request entered")
        client.onExplain = { _ in started.fulfill(); return try await gate.wait() }
        let settings = makeSettings(client: client)
        let id = try save(settings, key: "original-secret")
        let pending = Task { try await settings.explain(selection: "bank", context: "river bank") }
        await fulfillment(of: [started], timeout: 2)
        try settings.saveCustomProfile(id: id, name: "Edited", baseURL: "https://edited.example/v1",
                                       apiKey: "edited-secret", model: "edited-model")
        gate.complete(.success("stale definition"))
        await assertCancelled(pending)
        XCTAssertEqual(client.configurations.first?.apiKey, "original-secret")
        client.onExplain = { _ in "updated definition" }
        let text = try await settings.explain(selection: "bank", context: "river bank")
        XCTAssertEqual(text, "updated definition")
        XCTAssertEqual(client.configurations.last?.apiKey, "edited-secret")
    }

    func testMissingKeyAndCustomHTTPFailureStayCustomAndNeverFallBack() async throws {
        let secrets = RoutingProfileCredentials()
        let client = RoutingCustomClient()
        let settings = makeSettings(secrets: secrets, client: client)
        let id = try save(settings)
        secrets.values[id] = nil
        settings.retryCustomStorage()
        XCTAssertFalse(settings.isAIConfigured)
        XCTAssertEqual(settings.aiConfigurationIssue, .custom(.missingAPIKey))
        await assertIssue(.custom(.missingAPIKey)) {
            try await settings.explain(selection: "bank", context: "river bank")
        }
        XCTAssertTrue(client.configurations.isEmpty)
        secrets.values[id] = "restored-secret"
        settings.retryCustomStorage()
        client.onExplain = { _ in throw AIError.http(401) }
        await assertIssue(.custom(.http(401))) {
            try await settings.explain(selection: "bank", context: "river bank")
        }
        XCTAssertEqual(settings.selectedService, .custom(id))
        XCTAssertFalse(settings.chatGPT.isSignedIn)
        XCTAssertEqual(client.configurations.count, 1)
    }

    func testSelectingUnreadableProfilePreservesTheCurrentSelection() throws {
        let defaults = preferences()
        let secrets = RoutingProfileCredentials()
        let original = makeSettings(defaults: defaults, secrets: secrets)
        let a = try save(original, name: "A")
        let b = try save(original, name: "B")
        try original.selectService(.custom(a))
        let settings = makeSettings(defaults: defaults, secrets: secrets)
        let revision = settings.configurationRevision
        secrets.readError = .keychain(errSecAuthFailed)
        XCTAssertThrowsError(try settings.selectService(.custom(b)))
        XCTAssertEqual(settings.selectedService, .custom(a))
        XCTAssertEqual(settings.configurationRevision, revision)
        XCTAssertNotNil(settings.customStorageIssue)
        secrets.readError = nil
        _ = try settings.reloadAPIKey(for: b)
        XCTAssertNil(settings.customStorageIssue)
    }

    func testSessionReusesProfileCredentialAcrossStatusRequestsAndSettingsDrafts() async throws {
        let defaults = preferences()
        let secrets = RoutingProfileCredentials()
        let original = makeSettings(defaults: defaults, secrets: secrets)
        let id = try save(original, key: "session-secret")
        let client = RoutingCustomClient()
        let settings = makeSettings(defaults: defaults, secrets: secrets, client: client)
        let profile = try XCTUnwrap(settings.customProfiles.first)

        for _ in 0..<3 {
            XCTAssertTrue(settings.isAIConfigured)
            XCTAssertEqual(try settings.configuration(for: id).apiKey, "session-secret")
            XCTAssertEqual(try settings.apiKey(for: id), "session-secret")
            let draft = AICustomConfigurationDraft(settings: settings, profile: profile, client: client)
            XCTAssertEqual(draft.apiKey, "session-secret")
        }
        _ = try await settings.explain(selection: "A full sentence.", context: "A full sentence.", purpose: .intensive)

        XCTAssertEqual(secrets.reads[id], 1)
        XCTAssertEqual(client.configurations.last?.apiKey, "session-secret")
    }

    func testMissingProfileCredentialIsCachedUntilExplicitRetry() throws {
        let defaults = preferences()
        let secrets = RoutingProfileCredentials()
        let id = try save(makeSettings(defaults: defaults, secrets: secrets))
        secrets.values[id] = nil
        let settings = makeSettings(defaults: defaults, secrets: secrets)

        for _ in 0..<3 {
            XCTAssertEqual(settings.aiConfigurationIssue, .custom(.missingAPIKey))
            XCTAssertEqual(try settings.apiKey(for: id), "")
        }
        XCTAssertEqual(secrets.reads[id], 1)
        secrets.values[id] = "restored-secret"
        XCTAssertFalse(settings.isAIConfigured)
        XCTAssertEqual(secrets.reads[id], 1)

        settings.retryCustomStorage()

        XCTAssertTrue(settings.isAIConfigured)
        XCTAssertEqual(try settings.configuration(for: id).apiKey, "restored-secret")
        XCTAssertEqual(secrets.reads[id], 2)
    }

    func testProfileReadFailureDoesNotRetryDuringRenderingAndDraftRetryCanRecover() throws {
        let defaults = preferences()
        let secrets = RoutingProfileCredentials()
        let id = try save(makeSettings(defaults: defaults, secrets: secrets))
        secrets.readError = .keychain(errSecAuthFailed)
        let settings = makeSettings(defaults: defaults, secrets: secrets)
        let profile = try XCTUnwrap(settings.customProfiles.first)
        let draft = AICustomConfigurationDraft(settings: settings, profile: profile, client: RoutingCustomClient())
        defer { draft.cancelPending() }

        for _ in 0..<3 {
            XCTAssertEqual(settings.aiConfigurationIssue, .custom(.keychain(errSecAuthFailed)))
            XCTAssertThrowsError(try settings.apiKey(for: id))
        }
        XCTAssertEqual(secrets.reads[id], 1)
        secrets.readError = nil
        XCTAssertFalse(settings.isAIConfigured)

        draft.retryValidation()

        XCTAssertEqual(draft.apiKey, "custom-secret")
        XCTAssertTrue(settings.isAIConfigured)
        XCTAssertEqual(secrets.reads[id], 2)
    }

    func testLegacyReadFailureDoesNotRetryDuringRenderingAndExplicitRetryCanRecover() throws {
        let defaults = preferences()
        defaults.set("https://legacy.example/v1", forKey: "ai.baseURL")
        defaults.set("legacy-model", forKey: "ai.model")
        let legacy = RoutingLegacyCredentials("legacy-secret")
        let original = makeSettings(defaults: defaults, legacy: legacy)
        let id = try XCTUnwrap(original.customProfiles.first?.id)
        legacy.readError = .keychain(errSecAuthFailed)
        let settings = makeSettings(defaults: defaults, legacy: legacy)

        for _ in 0..<3 {
            XCTAssertEqual(settings.aiConfigurationIssue, .custom(.keychain(errSecAuthFailed)))
            XCTAssertThrowsError(try settings.apiKey(for: id))
        }
        XCTAssertEqual(legacy.reads, 2)
        legacy.readError = nil
        XCTAssertFalse(settings.isAIConfigured)
        XCTAssertEqual(legacy.reads, 2)

        settings.retryCustomStorage()

        XCTAssertTrue(settings.isAIConfigured)
        XCTAssertEqual(try settings.configuration(for: id).apiKey, "legacy-secret")
        XCTAssertEqual(legacy.reads, 3)
        XCTAssertTrue(legacy.writes.isEmpty)
    }

    func testSuccessfulProfileSaveRefreshesCachedKeyAndFailedSavePreservesIt() throws {
        let defaults = preferences()
        let secrets = RoutingProfileCredentials()
        let id = try save(makeSettings(defaults: defaults, secrets: secrets), key: "original-secret")
        let settings = makeSettings(defaults: defaults, secrets: secrets)
        XCTAssertEqual(try settings.apiKey(for: id), "original-secret")

        _ = try settings.saveCustomProfile(id: id, name: "Updated", baseURL: "https://custom.example/v1",
                                          apiKey: "updated-secret", model: "custom-model")
        XCTAssertEqual(try settings.configuration(for: id).apiKey, "updated-secret")
        secrets.writeError = .keychain(errSecAuthFailed)
        XCTAssertThrowsError(try settings.saveCustomProfile(id: id, name: "Failed", baseURL: "https://custom.example/v1",
                                                           apiKey: "failed-secret", model: "custom-model"))
        XCTAssertEqual(try settings.apiKey(for: id), "updated-secret")
        XCTAssertEqual(secrets.reads[id], 1)

        XCTAssertThrowsError(try settings.deleteCustomProfile(id: id))
        XCTAssertEqual(try settings.apiKey(for: id), "updated-secret")
        secrets.writeError = nil
        try settings.deleteCustomProfile(id: id)
        XCTAssertThrowsError(try settings.apiKey(for: id)) { XCTAssertEqual($0 as? AIError, .missingProfile) }
        _ = try settings.saveCustomProfile(id: nil, name: "Other", baseURL: "https://custom.example/v1",
                                          apiKey: "other-secret", model: "custom-model")
        XCTAssertThrowsError(try settings.configuration(for: id)) { XCTAssertEqual($0 as? AIError, .missingProfile) }
    }

    func testDeletingSelectedProfileDoesNotSilentlySelectAnotherBillingSource() throws {
        let settings = makeSettings()
        let a = try save(settings, name: "A")
        let b = try save(settings, name: "B")
        try settings.deleteCustomProfile(id: b)
        XCTAssertEqual(settings.customProfiles.map(\.id), [a])
        XCTAssertEqual(settings.selectedService, .custom(b))
        XCTAssertEqual(settings.aiConfigurationIssue, .custom(.missingProfile))
        XCTAssertFalse(settings.isAIConfigured)
    }

    func testDamagedProfileMetadataCannotBeOverwrittenBySavingAnotherProfile() throws {
        let defaults = preferences()
        let original = Data("unreadable profile metadata".utf8)
        defaults.set(original, forKey: "ai.customProfiles")
        let secrets = RoutingProfileCredentials()
        let settings = makeSettings(defaults: defaults, secrets: secrets)
        XCTAssertEqual(settings.customStorageIssue, .custom(.profileStorage))
        XCTAssertThrowsError(try save(settings))
        XCTAssertEqual(defaults.data(forKey: "ai.customProfiles"), original)
        XCTAssertTrue(secrets.writes.isEmpty)
        XCTAssertTrue(settings.customProfiles.isEmpty)
    }

    private func preferences() -> UserDefaults {
        let name = "AISettingsRoutingTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }

    private func makeSettings(defaults: UserDefaults? = nil, legacy: RoutingLegacyCredentials? = nil,
                              secrets: RoutingProfileCredentials? = nil, client: RoutingCustomClient? = nil) -> AISettingsStore {
        let defaults = defaults ?? preferences()
        let account = ChatGPTAccountStore(defaults: defaults, credentials: RoutingChatGPTCredentials())
        return AISettingsStore(defaults: defaults, credentials: legacy ?? RoutingLegacyCredentials(),
                               language: AppLanguageStore(defaults: defaults),
                               customCredentials: secrets ?? RoutingProfileCredentials(),
                               customClient: client ?? RoutingCustomClient(), chatGPT: account)
    }

    @discardableResult
    private func save(_ settings: AISettingsStore, name: String = "Custom", key: String = "custom-secret") throws -> UUID {
        try settings.saveCustomProfile(name: name, baseURL: "https://custom.example/v1", apiKey: key, model: "custom-model")
    }

    private func assertCancelled(_ task: Task<String, Error>, file: StaticString = #filePath, line: UInt = #line) async {
        do { _ = try await task.value; XCTFail("Expected cancellation", file: file, line: line) }
        catch { XCTAssertTrue(error is CancellationError, "Unexpected error: \(error)", file: file, line: line) }
    }

    private func assertIssue(_ expected: AIUsageIssue, operation: () async throws -> String,
                             file: StaticString = #filePath, line: UInt = #line) async {
        do { _ = try await operation(); XCTFail("Expected \(expected)", file: file, line: line) }
        catch { XCTAssertEqual(error as? AIUsageIssue, expected, file: file, line: line) }
    }
}

private final class RoutingLegacyCredentials: AICredentialStorage {
    var value: String?
    var readError: AIError?
    private(set) var writes: [String] = []
    private(set) var reads = 0
    init(_ value: String? = nil) { self.value = value }
    func read() throws -> String? { reads += 1; if let readError { throw readError }; return value }
    func write(_ value: String) throws { writes.append(value); self.value = value }
}

private final class RoutingProfileCredentials: AICustomCredentialStorage {
    var values: [UUID: String] = [:]
    var readError: AIError?
    var writeError: AIError?
    private(set) var writes: [UUID] = []
    private(set) var reads: [UUID: Int] = [:]
    func read(profileID: UUID) throws -> String? {
        reads[profileID, default: 0] += 1
        if let readError { throw readError }
        return values[profileID]
    }
    func write(_ value: String?, profileID: UUID) throws {
        if let writeError { throw writeError }
        writes.append(profileID)
        values[profileID] = value
    }
}

private final class RoutingChatGPTCredentials: ChatGPTCredentialStorage {
    func read() throws -> Data? { nil }
    func write(_ data: Data?) throws { }
}

@MainActor
private final class RoutingCustomClient: AICustomServing {
    var onExplain: (AIConfiguration) async throws -> String = { _ in "definition" }
    private(set) var configurations: [AIConfiguration] = []
    private(set) var purposes: [AIExplanationPurpose] = []
    func fetchModels(baseURL: String, apiKey: String) async throws -> [String] { ["custom-model"] }
    func explain(selection: String, context: String, focusedSentence: String?, purpose: AIExplanationPurpose,
                 configuration: AIConfiguration) async throws -> String {
        configurations.append(configuration)
        purposes.append(purpose)
        return try await onExplain(configuration)
    }
}

@MainActor
private final class RoutingGate {
    private var continuation: CheckedContinuation<String, Error>?
    func wait() async throws -> String { try await withCheckedThrowingContinuation { continuation = $0 } }
    func complete(_ result: Result<String, Error>) {
        let pending = continuation
        continuation = nil
        pending?.resume(with: result)
    }
}
