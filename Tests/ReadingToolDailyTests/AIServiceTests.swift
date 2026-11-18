import Foundation
import Network
import XCTest
@testable import ReadingToolDaily

final class AIServiceTests: XCTestCase {
    func testNoAuthenticationOmitsHeaderForModelCatalogAndInferenceAndDiscardsHiddenKey() async throws {
        let catalogSession = makeSession { request in
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url?.absoluteString, "http://127.0.0.1:11434/v1/models")
            return (200, "{\"data\":[{\"id\":\"local-model\"}]}")
        }
        defer { catalogSession.invalidateAndCancel() }
        let models = try await AIClient(session: catalogSession).fetchModels(
            baseURL: "http://127.0.0.1:11434/v1", apiKey: "unused-secret", authentication: .none)
        XCTAssertEqual(models, ["local-model"])

        let inferenceSession = makeSession { request in
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.absoluteString, "http://127.0.0.1:11434/v1/chat/completions")
            let body = try Self.requestBody(request)
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            XCTAssertEqual(object["model"] as? String, "local-model")
            XCTAssertFalse(String(decoding: body, as: UTF8.self).contains("unused-secret"))
            return (200, "{\"choices\":[{\"message\":{\"content\":\"河岸\"},\"finish_reason\":\"stop\"}]}")
        }
        defer { inferenceSession.invalidateAndCancel() }
        let configuration = try AIConfiguration(baseURL: "http://127.0.0.1:11434/v1", apiKey: "unused-secret",
                                                model: "local-model", authentication: .none).validated()
        XCTAssertTrue(configuration.apiKey.isEmpty)
        let explanation = try await AIClient(session: inferenceSession).explain(
            selection: "bank", context: "She sat on the river bank.", configuration: configuration)
        XCTAssertEqual(explanation, "河岸")
    }

    func testFetchModelsNeedsNoModelAndResolvesEndpointBeforeNormalizingAvailableModels() async throws {
        let addresses = [
            ("https://example.com", "https://example.com/v1/models"),
            ("https://example.com/v1/", "https://example.com/v1/models"),
            ("https://example.com/chat/completions", "https://example.com/models"),
            ("https://example.com/proxy/v1/chat/completions/?route=reading", "https://example.com/proxy/v1/models?route=reading"),
            ("https://example.com//proxy///v1//chat//completions///?route=a%2Fb", "https://example.com/proxy/v1/models?route=a%2Fb"),
            ("https://example.com//v1///models///", "https://example.com/v1/models")
        ]
        for (address, expected) in addresses {
            let session = makeSession { request in
                XCTAssertEqual(request.url?.absoluteString, expected)
                XCTAssertEqual(request.httpMethod, "GET")
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer models-only-key")
                XCTAssertNil(request.httpBody)
                return (200, "{\"data\":[{\"id\":\" model-z \"},{\"id\":\"model-a\"},{\"id\":\"model-z\"},{\"id\":\"  \"}]}")
            }
            defer { session.invalidateAndCancel() }
            let models = try await AIClient(session: session).fetchModels(baseURL: address, apiKey: " models-only-key ")
            XCTAssertEqual(models, ["model-a", "model-z"])
        }
    }

    func testModelCatalogRejectsEmptyMalformedAndUnauthorizedReplies() async {
        let replies: [(Int, String, AIError)] = [
            (200, "{\"data\":[]}", .emptyModels),
            (200, "{\"data\":[{\"id\":\"   \"}]}", .emptyModels),
            (200, "{\"models\":[\"model\"]}", .invalidModelsResponse),
            (401, "private upstream error", .modelsHTTP(401)),
            (403, "private upstream error", .modelsHTTP(403)),
            (404, "private upstream error", .modelsHTTP(404))
        ]
        for (status, response, expected) in replies {
            let session = makeSession { _ in (status, response) }
            do {
                _ = try await AIClient(session: session).fetchModels(baseURL: "https://example.com/v1", apiKey: "test-secret")
                XCTFail("Expected model catalog failure")
            } catch {
                XCTAssertEqual(error as? AIError, expected)
                XCTAssertFalse(error.localizedDescription.contains("private upstream"))
                XCTAssertFalse(error.localizedDescription.contains("test-secret"))
            }
            session.invalidateAndCancel()
        }
    }

    @MainActor
    func testUnreadableCredentialReportsStorageErrorAndCannotBeDeletedBySavingEmptyDraft() throws {
        let suite = "ReadingToolDaily.AISettingsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let credentials = AITestCredentialStore(readError: AIError.keychain(-25293))
        let language = AppLanguageStore(defaults: defaults)
        let settings = AISettingsStore(defaults: defaults, credentials: credentials, language: language)

        XCTAssertNotNil(settings.storageError)
        XCTAssertFalse(settings.isConfigured)
        XCTAssertThrowsError(try settings.configuration()) { error in
            XCTAssertEqual(error as? AIError, .keychain(-25293))
        }
        XCTAssertThrowsError(try settings.save(baseURL: "https://new.example.com/v1", apiKey: " \n ",
                                             model: "new-model")) { error in
            XCTAssertEqual(error as? AIError, .keychain(-25293))
        }
        XCTAssertTrue(credentials.writes.isEmpty)
        XCTAssertNil(defaults.string(forKey: "ai.baseURL"))
        XCTAssertNil(defaults.string(forKey: "ai.model"))
        XCTAssertEqual(settings.baseURL, "https://api.openai.com/v1")
        XCTAssertNotNil(settings.storageError)
    }

    @MainActor
    func testExplicitReplacementKeyRecoversFromCredentialReadFailure() throws {
        let suite = "ReadingToolDaily.AISettingsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let credentials = AITestCredentialStore(readError: AIError.keychain(-25293))
        let language = AppLanguageStore(defaults: defaults)
        let settings = AISettingsStore(defaults: defaults, credentials: credentials, language: language)

        try settings.save(baseURL: " https://new.example.com/v1 ", apiKey: " replacement-key ", model: " new-model ")

        XCTAssertEqual(credentials.writes, ["replacement-key"])
        XCTAssertNil(settings.storageError)
        let studyLanguage = language.language.studyLanguage
        XCTAssertEqual(try settings.configuration(), AIConfiguration(baseURL: "https://new.example.com/v1",
                                                                     apiKey: "replacement-key", model: "new-model",
                                                                     sourceLanguage: studyLanguage, targetLanguage: studyLanguage))
        XCTAssertEqual(defaults.string(forKey: "ai.baseURL"), "https://new.example.com/v1")
        XCTAssertEqual(defaults.string(forKey: "ai.model"), "new-model")
        XCTAssertNil(defaults.string(forKey: "ai.apiKey"))
    }

    @MainActor
    func testPrefillPreferencePersistsWithoutSavingCredentialsAfterReadFailure() throws {
        let suite = "ReadingToolDaily.AISettingsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let credentials = AITestCredentialStore(readError: AIError.keychain(-25293))
        let language = AppLanguageStore(defaults: defaults)
        let settings = AISettingsStore(defaults: defaults, credentials: credentials, language: language)
        XCTAssertTrue(settings.aiPrefillEnabled)

        // A popover can be cancelled without saving a card or its API settings.
        settings.setAIPrefillEnabled(false)

        XCTAssertFalse(settings.aiPrefillEnabled)
        XCTAssertEqual(defaults.object(forKey: "ai.prefillEnabled") as? Bool, false)
        XCTAssertNotNil(settings.storageError)
        XCTAssertTrue(credentials.writes.isEmpty)
        XCTAssertNil(defaults.string(forKey: "ai.baseURL"))
        let reopenedCredentials = AITestCredentialStore(readError: AIError.keychain(-25293))
        let reopened = AISettingsStore(defaults: defaults, credentials: reopenedCredentials, language: language)
        XCTAssertFalse(reopened.aiPrefillEnabled)
        XCTAssertTrue(reopenedCredentials.writes.isEmpty)
    }

    @MainActor
    func testCredentialSavePreservesLatestPrefillPreference() throws {
        let suite = "ReadingToolDaily.AISettingsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let credentials = AITestCredentialStore()
        let language = AppLanguageStore(defaults: defaults)
        let settings = AISettingsStore(defaults: defaults, credentials: credentials, language: language)
        XCTAssertTrue(settings.aiPrefillEnabled)

        settings.setAIPrefillEnabled(false)
        try settings.save(baseURL: "https://example.com/v1", apiKey: "test-key", model: "test-model")

        XCTAssertFalse(settings.aiPrefillEnabled)
        XCTAssertEqual(defaults.object(forKey: "ai.prefillEnabled") as? Bool, false)
        XCTAssertEqual(credentials.writes, ["test-key"])
        let reopened = AISettingsStore(defaults: defaults, credentials: AITestCredentialStore(), language: language)
        XCTAssertFalse(reopened.aiPrefillEnabled)
    }

    @MainActor
    func testConfigurationFollowsInterfaceLanguageAndIgnoresOldTargetPreference() throws {
        let suite = "ReadingToolDaily.AISettingsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(InterfaceLanguage.chinese.rawValue, forKey: "interface.language")
        defaults.set(StudyLanguage.japanese.rawValue, forKey: "ai.targetLanguage")
        defaults.set("test-model", forKey: "ai.model")
        let language = AppLanguageStore(defaults: defaults)
        let credentials = AITestCredentialStore(value: "test-key")
        let settings = AISettingsStore(defaults: defaults, credentials: credentials, language: language)

        var configuration = try settings.configuration()
        XCTAssertEqual(configuration.sourceLanguage, .chinese)
        XCTAssertEqual(configuration.targetLanguage, .chinese)

        language.language = .english
        configuration = try settings.configuration()
        XCTAssertEqual(configuration.sourceLanguage, .english)
        XCTAssertEqual(configuration.targetLanguage, .english)
        XCTAssertEqual(defaults.string(forKey: "ai.targetLanguage"), StudyLanguage.japanese.rawValue)
        XCTAssertTrue(credentials.writes.isEmpty)
    }

    func testBaseAndCompleteEndpointAddressesResolveWithoutDuplicatedPaths() throws {
        let addresses = [
            ("https://example.com", "https://example.com/v1/chat/completions"),
            ("https://example.com/v1/", "https://example.com/v1/chat/completions"),
            ("https://example.com/proxy/v1", "https://example.com/proxy/v1/chat/completions"),
            ("https://example.com/v1/chat/completions/", "https://example.com/v1/chat/completions"),
            ("https://example.com//v1///chat//completions///", "https://example.com/v1/chat/completions"),
            ("https://example.com/v1/models/?route=a%2Fb", "https://example.com/v1/chat/completions?route=a%2Fb"),
            ("https://example.com/models", "https://example.com/chat/completions"),
            ("https://example.com/proxy%2Froute//v1///", "https://example.com/proxy%2Froute/v1/chat/completions"),
            ("http://localhost:1234/v1", "http://localhost:1234/v1/chat/completions"),
            ("https://example.com/v1?api-version=test", "https://example.com/v1/chat/completions?api-version=test")
        ]
        for (address, expected) in addresses {
            XCTAssertEqual(try AIConfiguration.endpointURL(for: address).absoluteString, expected)
        }
    }

    func testConfigurationRejectsInvalidAddressMissingCredentialsAndHeaderInjection() throws {
        for address in ["example.com/v1", "file:///tmp/key", "https://user:secret@example.com/v1", "https://example.com/#fragment"] {
            XCTAssertThrowsError(try AIConfiguration.endpointURL(for: address)) { error in
                XCTAssertEqual(error as? AIError, .invalidAddress)
            }
        }
        XCTAssertThrowsError(try configuration(apiKey: " \n ").validated()) { error in
            XCTAssertEqual(error as? AIError, .missingAPIKey)
        }
        XCTAssertThrowsError(try configuration(apiKey: "secret\nAuthorization: injected").validated()) { error in
            XCTAssertEqual(error as? AIError, .invalidAPIKey)
        }
        XCTAssertThrowsError(try AIConfiguration(baseURL: "https://example.com/v1", apiKey: "secret", model: " ").validated()) { error in
            XCTAssertEqual(error as? AIError, .missingModel)
        }
    }

    func testExplainSendsOnlySuppliedSelectionAndContextAsDataAndReturnsCompactExplanation() async throws {
        let session = makeSession { request in
            XCTAssertEqual(request.url?.absoluteString, "https://example.com/v1/chat/completions")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-secret")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
            XCTAssertEqual(request.timeoutInterval, 45)
            let body = try Self.requestBody(request)
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            XCTAssertEqual(object["model"] as? String, "test-model")
            XCTAssertEqual(object["stream"] as? Bool, false)
            XCTAssertEqual(object["max_tokens"] as? Int, 180)
            let messages = try XCTUnwrap(object["messages"] as? [[String: String]])
            XCTAssertEqual(messages.count, 2)
            XCTAssertEqual(messages.first?["role"], "system")
            XCTAssertTrue(messages.first?["content"]?.contains("Reply only in English.") == true)
            XCTAssertTrue(messages.first?["content"]?.contains("on the first line") == true)
            XCTAssertTrue(messages.first?["content"]?.contains("On a new line") == true)
            let userData = try XCTUnwrap(messages.last?["content"]?.data(using: .utf8))
            let input = try XCTUnwrap(JSONSerialization.jsonObject(with: userData) as? [String: String])
            XCTAssertEqual(input, ["selectedText": "bank", "surroundingSentences": "It was quiet. She sat on the bank. The river was calm.",
                                   "focusedSentence": "She sat on the bank."])
            return (200, "{\"choices\":[{\"message\":{\"content\":\"  河岸\\n此处指河流边缘，不是银行。\\n第三行不应显示。  \"}}]}")
        }
        defer { session.invalidateAndCancel() }
        let explanation = try await AIClient(session: session).explain(
            selection: " bank ", context: "It was quiet. She sat on the bank. The river was calm.",
            focusedSentence: "She sat on the bank.",
            configuration: AIConfiguration(baseURL: "https://example.com/v1", apiKey: "test-secret", model: "test-model",
                                           sourceLanguage: .chinese, targetLanguage: .english)
        )
        XCTAssertEqual(explanation, "河岸\n此处指河流边缘，不是银行。")
    }

    func testPrefillRequestsBriefContextualGlossInTargetLanguage() async throws {
        let session = makeSession { request in
            let body = try Self.requestBody(request)
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            let messages = try XCTUnwrap(object["messages"] as? [[String: String]])
            let instruction = try XCTUnwrap(messages.first?["content"])
            XCTAssertTrue(instruction.contains("Reply only in English."))
            XCTAssertFalse(instruction.contains("written in Japanese."))
            XCTAssertTrue(instruction.contains("a few words or one brief phrase"))
            XCTAssertTrue(instruction.contains("one short, standalone vocabulary gloss"))
            return (200, "{\"choices\":[{\"message\":{\"content\":\"  a riverbank\\nextra note  \"}}]}")
        }
        defer { session.invalidateAndCancel() }
        let meaning = try await AIClient(session: session).explain(
            selection: "岸", context: "川の岸に座った。", focusedSentence: "川の岸に座った。",
            purpose: .prefill,
            configuration: AIConfiguration(baseURL: "https://example.com/v1", apiKey: "test-secret", model: "test-model",
                                           sourceLanguage: .japanese, targetLanguage: .english)
        )
        XCTAssertEqual(meaning, "a riverbank")
    }

    func testTranslationKeepsFullOutputAndUsesContextOnlyAsReference() async throws {
        let selected = "First paragraph.\n\nSecond paragraph."
        let translated = String(repeating: "第一段译文完整保留。\n", count: 40).trimmingCharacters(in: .newlines)
        let session = makeSession { request in
            let body = try Self.requestBody(request)
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            XCTAssertEqual(object["max_tokens"] as? Int, 512)
            let messages = try XCTUnwrap(object["messages"] as? [[String: String]])
            let instruction = try XCTUnwrap(messages.first?["content"])
            XCTAssertTrue(instruction.contains("Translate only selectedText"))
            XCTAssertTrue(instruction.contains("never translate or include them"))
            let data = try XCTUnwrap(messages.last?["content"]?.data(using: .utf8))
            let input = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: String])
            XCTAssertEqual(input["selectedText"], selected)
            XCTAssertEqual(input["surroundingSentences"], "Previous paragraph sentence. Next paragraph sentence.")
            XCTAssertNil(input["focusedSentence"])
            let response = try JSONSerialization.data(withJSONObject: [
                "choices": [["finish_reason": "stop", "message": ["content": "  \(translated)  "]]]
            ])
            return (200, String(decoding: response, as: UTF8.self))
        }
        defer { session.invalidateAndCancel() }

        let result = try await AIClient(session: session).explain(
            selection: selected, context: "Previous paragraph sentence. Next paragraph sentence.",
            purpose: .translation, configuration: configuration()
        )

        XCTAssertEqual(result, translated)
        XCTAssertGreaterThan(result.count, 320)
    }

    func testTranslationReportsWhenCustomProviderTruncatesOutput() async throws {
        let session = makeSession { _ in
            (200, "{\"choices\":[{\"finish_reason\":\"length\",\"message\":{\"content\":\"partial translation\"}}]}")
        }
        defer { session.invalidateAndCancel() }

        do {
            _ = try await AIClient(session: session).explain(
                selection: "A long paragraph.", context: "", purpose: .translation,
                configuration: configuration()
            )
            XCTFail("Expected a truncated translation error")
        } catch {
            XCTAssertEqual(error as? AIError, .outputTruncated)
        }
    }

    func testIntensiveRequestKeepsStructuredJSONAndExpandsOutputBudget() async throws {
        let output = #"{"sentences":[{"id":0,"translation":"我们放弃了。","links":[{"sourceWordIDs":[1,2],"targetPhrases":[{"text":"放弃了","occurrence":0}]}]}]}"#
        let session = makeSession { request in
            let body = try Self.requestBody(request)
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            XCTAssertGreaterThan(object["max_tokens"] as? Int ?? 0, 180)
            let messages = try XCTUnwrap(object["messages"] as? [[String: String]])
            let instruction = try XCTUnwrap(messages.first?["content"])
            XCTAssertTrue(instruction.contains("structured output may use English keys"))
            XCTAssertTrue(instruction.contains("discontinuous IDs"))
            XCTAssertTrue(instruction.contains("Precision matters more than coverage"))
            XCTAssertTrue(instruction.contains("do not annotate every token"))
            XCTAssertTrue(instruction.contains("Prioritize names, places, dates, quantities"))
            XCTAssertTrue(instruction.contains("Preserve polarity"))
            XCTAssertTrue(instruction.contains("Every target phrase must express only the meaning contributed"))
            XCTAssertTrue(instruction.contains("include each exact occurrence"))
            XCTAssertTrue(instruction.contains("or perhaps"))
            XCTAssertTrue(instruction.contains("occurrence is zero-based"))
            let response = try JSONSerialization.data(withJSONObject: ["choices": [["message": ["content": output]]]])
            return (200, String(decoding: response, as: UTF8.self))
        }
        defer { session.invalidateAndCancel() }

        let result = try await AIClient(session: session).explain(
            selection: #"[{"id":0,"source":"We gave up.","words":[{"id":0,"text":"We"},{"id":1,"text":"gave"},{"id":2,"text":"up"}]}]"#,
            context: "We gave up.", purpose: .intensive, configuration: configuration())

        XCTAssertEqual(result, output)
    }

    func testHTTPFailureUsesChineseMessageWithoutEchoingResponseOrAPIKey() async {
        let session = makeSession { _ in (401, "{\"error\":\"test-secret private upstream error\"}") }
        defer { session.invalidateAndCancel() }
        do {
            _ = try await AIClient(session: session).explain(selection: "bank", context: "The bank is closed.",
                                                           configuration: configuration())
            XCTFail("Expected authorization error")
        } catch {
            XCTAssertEqual(error as? AIError, .http(401))
            XCTAssertTrue(error.localizedDescription.contains("API Key"))
            XCTAssertFalse(error.localizedDescription.contains("test-secret"))
            XCTAssertFalse(error.localizedDescription.contains("upstream"))
        }
    }

    func testMalformedAndEmptyResponsesProduceActionableErrors() async {
        for (reply, expected) in [
            ("<html>gateway</html>", AIError.invalidResponse),
            ("{\"choices\":[]}", AIError.emptyResponse),
            ("{\"choices\":[{\"message\":{\"content\":null}}]}", AIError.emptyResponse)
        ] {
            let session = makeSession { _ in (200, reply) }
            do {
                _ = try await AIClient(session: session).explain(selection: "bank", context: "The bank is closed.",
                                                               configuration: configuration())
                XCTFail("Expected response error")
            } catch {
                XCTAssertEqual(error as? AIError, expected)
            }
            session.invalidateAndCancel()
        }
    }

    func testCancellationIsPreservedInsteadOfShownAsConnectionFailure() async {
        let session = makeSession { _ in throw URLError(.cancelled) }
        defer { session.invalidateAndCancel() }
        do {
            _ = try await AIClient(session: session).explain(selection: "bank", context: "The bank is closed.",
                                                           configuration: configuration())
            XCTFail("Expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
    }

    @MainActor
    func testCustomInferenceRejectsCrossHostRedirectBeforeSendingAnotherRequest() async throws {
        let server = try AICredentialRedirectServer()
        let baseURL = try await server.start()
        defer { server.stop() }
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        do {
            _ = try await AIClient(session: session).explain(selection: "bank", context: "river bank",
                configuration: AIConfiguration(baseURL: baseURL.absoluteString, apiKey: "test-only-secret", model: "model"))
            XCTFail("The credential-bearing request followed a redirect")
        } catch { XCTAssertEqual(error as? AIError, .http(302)) }
        XCTAssertEqual(server.requests, 1)
    }

    @MainActor
    func testCustomModelCatalogRejectsCrossHostRedirect() async throws {
        let server = try AICredentialRedirectServer()
        let baseURL = try await server.start()
        defer { server.stop() }
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        do {
            _ = try await AIClient(session: session).fetchModels(baseURL: baseURL.absoluteString, apiKey: "test-only-secret")
            XCTFail("The model request followed a redirect")
        } catch { XCTAssertEqual(error as? AIError, .modelsHTTP(302)) }
        XCTAssertEqual(server.requests, 1)
    }

    private func configuration(apiKey: String = "test-secret") -> AIConfiguration {
        AIConfiguration(baseURL: "https://example.com/v1", apiKey: apiKey, model: "test-model")
    }

    private static func requestBody(_ request: URLRequest) throws -> Data {
        if let data = request.httpBody { return data }
        let stream = try XCTUnwrap(request.httpBodyStream)
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count < 0 { throw stream.streamError ?? AIError.invalidResponse }
            if count == 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }

    private func makeSession(handler: @escaping (URLRequest) throws -> (Int, String)) -> URLSession {
        let id = UUID().uuidString
        AIStubURLProtocol.register(id: id, handler: handler)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AIStubURLProtocol.self]
        configuration.httpAdditionalHeaders = ["X-ReadingTool-Test": id]
        return URLSession(configuration: configuration)
    }
}

private final class AITestCredentialStore: AICredentialStorage {
    let readError: Error?
    let value: String?
    private(set) var writes: [String] = []

    init(readError: Error? = nil, value: String? = nil) {
        self.readError = readError
        self.value = value
    }

    func read() throws -> String? {
        if let readError { throw readError }
        return value
    }

    func write(_ value: String) throws { writes.append(value) }
}

private final class AIStubURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var handlers: [String: (URLRequest) throws -> (Int, String)] = [:]

    static func register(id: String, handler: @escaping (URLRequest) throws -> (Int, String)) {
        lock.lock()
        defer { lock.unlock() }
        handlers[id] = handler
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        let handler = request.value(forHTTPHeaderField: "X-ReadingTool-Test").flatMap { Self.handlers.removeValue(forKey: $0) }
        Self.lock.unlock()
        do {
            let handler = try XCTUnwrap(handler)
            let (status, body) = try handler(request)
            let response = try XCTUnwrap(HTTPURLResponse(url: request.url!, statusCode: status,
                                                       httpVersion: nil, headerFields: ["Content-Type": "application/json"]))
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() { }
}

/// Both hosts resolve to this local listener; no credential or request can leave the test machine.
@MainActor
private final class AICredentialRedirectServer {
    private let listener: NWListener
    private var ready: CheckedContinuation<URL, Error>?
    private var connections: [NWConnection] = []
    private(set) var requests = 0

    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }

    func start() async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            ready = continuation
            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    guard let self, let waiting = self.ready else { return }
                    switch state {
                    case .ready:
                        self.ready = nil
                        waiting.resume(returning: URL(string: "http://127.0.0.1:\(self.listener.port!.rawValue)/v1")!)
                    case .failed(let error):
                        self.ready = nil
                        waiting.resume(throwing: error)
                    default: break
                    }
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in self?.serve(connection) }
            }
            listener.start(queue: .main)
        }
    }

    private func serve(_ connection: NWConnection) {
        connections.append(connection)
        connection.start(queue: .main)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] _, _, _, _ in
            Task { @MainActor in
                guard let self, let port = self.listener.port?.rawValue else { return }
                self.requests += 1
                let response: String
                if self.requests == 1 {
                    response = "HTTP/1.1 302 Found\r\nLocation: http://localhost:\(port)/credential-target\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
                } else {
                    response = "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\n{}"
                }
                connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
            }
        }
    }

    func stop() {
        listener.cancel()
        connections.forEach { $0.cancel() }
        if let ready { self.ready = nil; ready.resume(throwing: CancellationError()) }
    }
}
