import Foundation
import CryptoKit
import Security
import XCTest
@testable import WordLinks

@MainActor
final class ChatGPTAuthTests: XCTestCase {
    private let date = Date(timeIntervalSince1970: 2_000_000_000)

    func testInitialAuthorizationUsesPublicDynamicRegistrationAndPKCE() throws {
        let url = try ChatGPTAuthService.authorizationURL(
            endpoint: URL(string: "https://auth.openai.com/api/accounts/authorize")!,
            hostID: "urn:uuid:test", previous: nil, idTokenHint: nil, requestConsent: false,
            redirect: URL(string: "http://127.0.0.1:54321/auth/callback")!,
            state: "fresh-state", nonce: "fresh-nonce", challenge: "challenge")
        let query = Dictionary(uniqueKeysWithValues: URLComponents(url: url, resolvingAgainstBaseURL: false)!
            .queryItems!.map { ($0.name, $0.value!) })
        XCTAssertEqual(query["client_id"], "dynamic_agent_client")
        XCTAssertEqual(query["agent_name_hint"], "ReadingTool")
        XCTAssertEqual(query["code_challenge_method"], "S256")
        XCTAssertEqual(query["nonce"], "fresh-nonce")
        XCTAssertEqual(query["resource"], "https://api.openai.com/v1")
        XCTAssertTrue(query["scope"]!.contains("chatgpt.tokens.use.direct"))
        XCTAssertNil(query["client_secret"])
        XCTAssertNil(query["prompt"])
    }

    func testReturningAuthorizationReusesIssuedClientAndConsentIsExplicit() throws {
        let registration = ChatGPTRegistration(clientID: "oaiapp_saved", subject: "user", email: "user@example.com")
        let url = try ChatGPTAuthService.authorizationURL(
            endpoint: URL(string: "https://auth.openai.com/api/accounts/authorize")!,
            hostID: "urn:uuid:test", previous: registration, idTokenHint: "retained-token",
            requestConsent: true, redirect: URL(string: "http://127.0.0.1:54321/auth/callback")!,
            state: "state", nonce: "nonce", challenge: "challenge")
        let query = Dictionary(uniqueKeysWithValues: URLComponents(url: url, resolvingAgainstBaseURL: false)!
            .queryItems!.map { ($0.name, $0.value!) })
        XCTAssertEqual(query["client_id"], "oaiapp_saved")
        XCTAssertNil(query["agent_name_hint"])
        XCTAssertEqual(query["id_token_hint"], "retained-token")
        XCTAssertEqual(query["prompt"], "consent")
        XCTAssertThrowsError(try ChatGPTAuthService.authorizationURL(
            endpoint: URL(string: "https://attacker.example/authorize")!,
            hostID: "host", previous: registration, idTokenHint: "secret", requestConsent: false,
            redirect: URL(string: "http://127.0.0.1:54321/auth/callback")!, state: "s", nonce: "n", challenge: "c"))
    }

    func testCallbackRejectsUnrelatedRequestsWithoutConsumingLogin() {
        for target in ["/favicon.ico", "/auth/callback?state=wrong&code=x&client_id=oaiapp_1",
                       "/auth/callback?state=expected&state=wrong&code=x&client_id=oaiapp_1",
                       "http://attacker.example/auth/callback?state=expected&code=x"] {
            XCTAssertNil(parse(target))
        }
        XCTAssertNil(parse("/auth/callback?state=expected&code=x&client_id=oaiapp_1", host: "attacker.example"))
        XCTAssertEqual(try? parse("/auth/callback?state=expected&code=real&client_id=oaiapp_1")?.get(),
                       ChatGPTOAuthCallback(code: "real", clientID: "oaiapp_1"))
    }

    func testCallbackRequiresIssuedClientAndRejectsDuplicateParametersAndClientChanges() {
        for target in ["/auth/callback?state=expected&code=x",
                       "/auth/callback?state=expected&code=x&client_id=dynamic_agent_client",
                       "/auth/callback?state=expected&code=x&code=y&client_id=oaiapp_1"] {
            XCTAssertEqual(parse(target)?.failure, .invalidAuthorization)
        }
        XCTAssertEqual(parse("/auth/callback?state=expected&error=access_denied")?.failure, .authorizationDenied)
        XCTAssertEqual(parse("/auth/callback?state=expected&code=x&client_id=oaiapp_other", previous: "oaiapp_saved")?.failure,
                       .invalidAuthorization)
        XCTAssertEqual(try? parse("/auth/callback?state=expected&code=x", previous: "oaiapp_saved")?.get(),
                       ChatGPTOAuthCallback(code: "x", clientID: "oaiapp_saved"))
    }

    func testRS256IdentityValidationChecksSignatureAndClaims() throws {
        let key = try TestSigningKey()
        let claims = validClaims
        let token = try key.token(claims)
        let identity = try ChatGPTIDTokenValidator.validate(token, jwks: key.jwks,
                                                            clientID: "oaiapp_test", nonce: "expected",
                                                            subject: nil, now: date)
        XCTAssertEqual(identity, ChatGPTIdentity(subject: "user-1", email: "reader@example.com"))
        XCTAssertThrowsError(try ChatGPTIDTokenValidator.validate(token, jwks: key.jwks,
                                                                  clientID: "other", nonce: "expected", subject: nil, now: date))
        XCTAssertThrowsError(try ChatGPTIDTokenValidator.validate(token, jwks: key.jwks,
                                                                  clientID: "oaiapp_test", nonce: "wrong", subject: nil, now: date))
        XCTAssertThrowsError(try ChatGPTIDTokenValidator.validate(token, jwks: key.jwks,
                                                                  clientID: "oaiapp_test", nonce: nil, subject: "other", now: date))
        let otherKey = try TestSigningKey()
        XCTAssertThrowsError(try ChatGPTIDTokenValidator.validate(token, jwks: otherKey.jwks,
                                                                  clientID: "oaiapp_test", nonce: "expected", subject: nil, now: date))
    }

    func testIdentityRejectsUnsignedExpiredFutureAndWrongIssuerTokens() throws {
        let key = try TestSigningKey()
        let unsigned = base64URL(try JSONSerialization.data(withJSONObject: ["alg": "none", "kid": "test-key"]))
            + "." + base64URL(try JSONSerialization.data(withJSONObject: validClaims)) + ".fake"
        XCTAssertThrowsError(try ChatGPTIDTokenValidator.validate(unsigned, jwks: key.jwks,
                                                                  clientID: "oaiapp_test", nonce: "expected", subject: nil, now: date))
        for (field, value) in [("iss", "https://attacker.example" as Any),
                               ("exp", date.timeIntervalSince1970 - 10 as Any),
                               ("iat", date.timeIntervalSince1970 + 60 as Any),
                               ("nbf", date.timeIntervalSince1970 + 60 as Any),
                               ("aud", ["oaiapp_test", "other"] as Any)] {
            var claims = validClaims
            claims[field] = value
            XCTAssertThrowsError(try ChatGPTIDTokenValidator.validate(key.token(claims), jwks: key.jwks,
                                                                      clientID: "oaiapp_test", nonce: "expected", subject: nil, now: date), field)
        }
    }

    func testRefreshReplacesRotatingTokensAndRetainsGrantedScopes() async throws {
        let network = makeNetwork { request in
            if request.url!.path.contains("openid-configuration") { return (200, Self.discovery) }
            XCTAssertEqual(request.url?.host, "auth.openai.com")
            XCTAssertEqual(request.url?.path, "/api/accounts/oauth/token")
            let body = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
            XCTAssertTrue(body.contains("grant_type=refresh_token"))
            XCTAssertTrue(body.contains("resource=https%3A%2F%2Fapi.openai.com%2Fv1"))
            XCTAssertFalse(body.contains("scope="))
            return (200, "{\"access_token\":\"new-access\",\"refresh_token\":\"new-refresh\",\"token_type\":\"Bearer\",\"expires_in\":3600}")
        }
        defer { network.invalidateAndCancel() }
        let service = ChatGPTAuthService(network: network, now: { self.date })
        let refreshed = try await service.refresh(savedSession)
        XCTAssertEqual(refreshed.accessToken, "new-access")
        XCTAssertEqual(refreshed.refreshToken, "new-refresh")
        XCTAssertEqual(refreshed.idToken, "saved-id")
        XCTAssertEqual(refreshed.registration, savedSession.registration)
        XCTAssertEqual(refreshed.scopes, savedSession.scopes)
        XCTAssertEqual(refreshed.expiresAt, date.addingTimeInterval(3600))
        XCTAssertEqual(refreshed.refreshExpiresAt, date.addingTimeInterval(30 * 86_400))
    }

    func testUnknownRefreshSchedulingHintDoesNotRejectValidCredentials() async throws {
        for hint in ["{}", "false", "[]"] {
            let network = makeNetwork { request in
                if request.url!.path.contains("openid-configuration") { return (200, Self.discovery) }
                return (200, "{\"access_token\":\"new-access\",\"refresh_token\":\"new-refresh\",\"token_type\":\"Bearer\",\"expires_in\":3600,\"earliest_refresh_at\":\(hint)}")
            }
            defer { network.invalidateAndCancel() }
            let refreshed = try await ChatGPTAuthService(network: network, now: { self.date }).refresh(savedSession)
            XCTAssertEqual(refreshed.accessToken, "new-access")
            XCTAssertEqual(refreshed.refreshToken, "new-refresh")
            XCTAssertNil(refreshed.earliestRefreshAt)
        }
    }

    func testRefreshDistinguishesExpiredLoginFromTemporaryServiceFailure() async throws {
        for (status, body, expected) in [(400, "{\"error\":\"invalid_grant\"}", ChatGPTError.loginExpired),
                                         (400, "{\"error\":\"refresh_token_invalid\"}", .loginExpired),
                                         (400, "{\"error\":\"invalid_client\"}", .unsupportedRequest),
                                         (400, "{\"error\":\"unsupported_grant_type\"}", .unsupportedRequest),
                                         (403, "{}", .notEligible),
                                         (503, "{\"error\":\"temporarily_unavailable\"}", .serviceUnavailable),
                                         (429, "{}", .rateLimited)] {
            let network = makeNetwork { request in
                request.url!.path.contains("openid-configuration") ? (200, Self.discovery) : (status, body)
            }
            defer { network.invalidateAndCancel() }
            do {
                _ = try await ChatGPTAuthService(network: network, now: { self.date }).refresh(savedSession)
                XCTFail("Expected \(expected)")
            } catch { XCTAssertEqual(error as? ChatGPTError, expected) }
        }
    }

    func testRevocationRetriesTransientFailureOnceAndReportsUnconfirmedAfterFailure() async throws {
        for eventuallySucceeds in [true, false] {
            var attempts = 0
            let network = makeNetwork { request in
                if request.url!.path.contains("openid-configuration") { return (200, Self.discovery) }
                XCTAssertEqual(request.url?.path, "/api/accounts/oauth/revoke")
                attempts += 1
                return eventuallySucceeds && attempts == 2 ? (200, "") : (503, "")
            }
            defer { network.invalidateAndCancel() }
            let service = ChatGPTAuthService(network: network, now: { self.date })
            do {
                try await service.revoke(savedSession)
                XCTAssertTrue(eventuallySucceeds)
            } catch {
                XCTAssertFalse(eventuallySucceeds)
                XCTAssertEqual(error as? ChatGPTError, .signOutUnconfirmed)
            }
            XCTAssertEqual(attempts, 2)
        }
    }

    func testDiscoveryCannotRedirectCredentialEndpointsToAnotherHost() async throws {
        let network = makeNetwork { _ in
            (200, Self.discovery.replacingOccurrences(of: "https://auth.openai.com/api/accounts/oauth/token",
                                                       with: "https://attacker.example/token"))
        }
        defer { network.invalidateAndCancel() }
        do {
            _ = try await ChatGPTAuthService(network: network, now: { self.date }).refresh(savedSession)
            XCTFail("Untrusted token endpoint was accepted")
        } catch { XCTAssertEqual(error as? ChatGPTError, .invalidAuthorization) }
    }

    func testBrowserOpenFailureEndsPendingLoopbackLogin() async throws {
        let network = makeNetwork { _ in (200, Self.discovery) }
        defer { network.invalidateAndCancel() }
        let service = ChatGPTAuthService(network: network, openBrowser: { _ in false })
        do {
            _ = try await service.signIn(hostID: "urn:uuid:test", previous: nil, idTokenHint: nil, requestConsent: false)
            XCTFail("Expected browser failure")
        } catch { XCTAssertEqual(error as? ChatGPTError, .browserUnavailable) }
    }

    func testCompleteLoginWithLocalCallbackAndSignedIdentity() async throws {
        let session = try await performMockLogin(grantDirectUse: true)
        XCTAssertEqual(session.registration.clientID, "oaiapp_test")
        XCTAssertEqual(session.registration.subject, "user-1")
        XCTAssertEqual(session.registration.email, "reader@example.com")
        XCTAssertEqual(session.accessToken, "new-access")
        XCTAssertTrue(session.scopes.contains("chatgpt.tokens.use.direct"))
    }

    func testIdentityOnlyConsentPreservesVerifiedAccountWithoutInferenceTokens() async throws {
        let session = try await performMockLogin(grantDirectUse: false)
        XCTAssertEqual(session.registration.clientID, "oaiapp_test")
        XCTAssertEqual(session.registration.subject, "user-1")
        XCTAssertEqual(session.registration.email, "reader@example.com")
        XCTAssertFalse(session.idToken.isEmpty)
        XCTAssertTrue(session.accessToken.isEmpty)
        XCTAssertTrue(session.refreshToken.isEmpty)
        XCTAssertFalse(session.scopes.contains("chatgpt.tokens.use.direct"))
        XCTAssertEqual(session.scopes, ["openid", "profile", "email"])
    }

    func testRejectedInitialCodeReauthorizesIssuedClientWithFreshBindings() async throws {
        let session = try await performMockLoginWithRejectedCode(rejectSecondExchange: false)
        XCTAssertEqual(session.registration.clientID, "oaiapp_test")
        XCTAssertEqual(session.registration.subject, "user-1")
        XCTAssertEqual(session.accessToken, "new-access")
        XCTAssertTrue(session.scopes.contains("chatgpt.tokens.use.direct"))
    }

    func testRepeatedCodeRejectionStopsAfterOneFreshAuthorization() async throws {
        do {
            _ = try await performMockLoginWithRejectedCode(rejectSecondExchange: true)
            XCTFail("Expected bounded code rejection")
        } catch { XCTAssertEqual(error as? ChatGPTError, .authorizationCodeRejected) }
    }

    private func performMockLoginWithRejectedCode(rejectSecondExchange: Bool) async throws -> ChatGPTSession {
        let key = try TestSigningKey()
        var queries = [[String: String]]()
        var verifiers = [String]()
        var exchanges = 0
        var callbacksReceived = 0
        let network = makeNetwork { request in
            if request.url!.path.contains("openid-configuration") { return (200, Self.discovery) }
            if request.url!.path.contains("jwks") { return (200, String(decoding: key.jwks, as: UTF8.self)) }
            exchanges += 1
            let form = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
            let values = Dictionary(uniqueKeysWithValues: URLComponents(string: "https://example.invalid/?" + form)!
                .queryItems!.map { ($0.name, $0.value!) })
            XCTAssertEqual(exchanges, queries.count)
            XCTAssertEqual(values["grant_type"], "authorization_code")
            XCTAssertEqual(values["client_id"], "oaiapp_test")
            XCTAssertEqual(values["code"], "local-code-\(exchanges)")
            XCTAssertEqual(values["redirect_uri"], queries.last?["redirect_uri"])
            XCTAssertEqual(values["resource"], ChatGPTAuthService.resource)
            let verifier = values["code_verifier"]!
            let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64EncodedString()
                .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
            XCTAssertEqual(challenge, queries.last?["code_challenge"])
            XCTAssertFalse(verifiers.contains(verifier))
            verifiers.append(verifier)
            if exchanges == 1 || rejectSecondExchange {
                return (400, "{\"error\":\"invalid_grant\",\"error_description\":\"Authorization code expired\"}")
            }
            var claims = self.validClaims
            claims["nonce"] = queries.last?["nonce"]
            let body: [String: Any] = ["access_token": "new-access", "refresh_token": "new-refresh",
                                       "id_token": try! key.token(claims), "token_type": "Bearer",
                                       "expires_in": 3600, "scope": ChatGPTAuthService.requestedScopes]
            return (200, String(decoding: try! JSONSerialization.data(withJSONObject: body), as: UTF8.self))
        }
        defer {
            network.invalidateAndCancel()
            XCTAssertEqual(exchanges, 2)
            XCTAssertEqual(queries.count, 2)
            XCTAssertEqual(callbacksReceived, 2)
        }
        let service = ChatGPTAuthService(network: network, openBrowser: { url in
            let query = Dictionary(uniqueKeysWithValues: URLComponents(url: url, resolvingAgainstBaseURL: false)!
                .queryItems!.map { ($0.name, $0.value!) })
            if let first = queries.first {
                XCTAssertEqual(query["client_id"], "oaiapp_test")
                XCTAssertNil(query["agent_name_hint"])
                XCTAssertNil(query["id_token_hint"])
                for field in ["state", "nonce", "code_challenge", "redirect_uri"] {
                    XCTAssertNotEqual(query[field], first[field], field)
                }
                XCTAssertEqual(query["ext_agent_host_id"], first["ext_agent_host_id"])
            } else {
                XCTAssertEqual(query["client_id"], "dynamic_agent_client")
                XCTAssertEqual(query["agent_name_hint"], "ReadingTool")
            }
            queries.append(query)
            var callback = URLComponents(string: query["redirect_uri"]!)!
            callback.queryItems = [URLQueryItem(name: "code", value: "local-code-\(queries.count)"),
                                   URLQueryItem(name: "state", value: query["state"])]
            // A returning callback is allowed to omit the issued ID; the pending
            // request must retain it from the first, unverified registration callback.
            if queries.count == 1 {
                callback.queryItems!.append(URLQueryItem(name: "client_id", value: "oaiapp_test"))
            }
            let callbackURL = callback.url!
            Task {
                let localNetwork = URLSession(configuration: .ephemeral)
                defer { localNetwork.invalidateAndCancel() }
                do {
                    let (_, response) = try await localNetwork.data(from: callbackURL)
                    XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
                } catch { XCTFail("Local callback failed: \(error)") }
            }
            return true
        }, onCallbackReceived: { callbacksReceived += 1 }, now: { self.date })
        return try await service.signIn(hostID: "urn:uuid:test", previous: nil,
                                       idTokenHint: nil, requestConsent: false)
    }

    private func performMockLogin(grantDirectUse: Bool) async throws -> ChatGPTSession {
        let key = try TestSigningKey()
        var returnedIDToken = ""
        var callbacksReceived = 0
        let network = makeNetwork { request in
            if request.url!.path.contains("openid-configuration") { return (200, Self.discovery) }
            if request.url!.path.contains("jwks") { return (200, String(decoding: key.jwks, as: UTF8.self)) }
            let form = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
            XCTAssertTrue(form.contains("client_id=oaiapp_test"))
            XCTAssertTrue(form.contains("code=local-code"))
            XCTAssertTrue(form.contains("code_verifier="))
            let body: [String: Any] = grantDirectUse
                ? ["access_token": "new-access", "refresh_token": "new-refresh",
                   "id_token": returnedIDToken, "token_type": "Bearer", "expires_in": 3600,
                   "scope": ChatGPTAuthService.requestedScopes]
                : ["id_token": returnedIDToken, "scope": "openid profile email"]
            return (200, String(decoding: try! JSONSerialization.data(withJSONObject: body), as: UTF8.self))
        }
        defer { network.invalidateAndCancel() }
        let service = ChatGPTAuthService(network: network, openBrowser: { url in
            let query = Dictionary(uniqueKeysWithValues: URLComponents(url: url, resolvingAgainstBaseURL: false)!
                .queryItems!.map { ($0.name, $0.value!) })
            var claims = self.validClaims
            claims["nonce"] = query["nonce"]!
            returnedIDToken = try! key.token(claims)
            var callback = URLComponents(string: query["redirect_uri"]!)!
            XCTAssertEqual(callback.host, "127.0.0.1")
            XCTAssertEqual(callback.path, "/auth/callback")
            callback.queryItems = [URLQueryItem(name: "code", value: "local-code"),
                                   URLQueryItem(name: "state", value: query["state"]),
                                   URLQueryItem(name: "client_id", value: "oaiapp_test")]
            let callbackURL = callback.url!
            Task {
                let localNetwork = URLSession(configuration: .ephemeral)
                defer { localNetwork.invalidateAndCancel() }
                do {
                    let (_, response) = try await localNetwork.data(from: callbackURL)
                    XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
                } catch { XCTFail("Local callback failed: \(error)") }
            }
            return true
        }, onCallbackReceived: { callbacksReceived += 1 }, now: { self.date })
        let session = try await service.signIn(hostID: "urn:uuid:test", previous: nil,
                                               idTokenHint: nil, requestConsent: false)
        XCTAssertEqual(callbacksReceived, 1)
        return session
    }

    func testCancelledLoginReleasesLoopbackAndReturnsCancellation() async throws {
        let network = makeNetwork { _ in (200, Self.discovery) }
        defer { network.invalidateAndCancel() }
        let opened = expectation(description: "Browser opened")
        let service = ChatGPTAuthService(network: network, openBrowser: { _ in opened.fulfill(); return true })
        let task = Task {
            try await service.signIn(hostID: "urn:uuid:test", previous: nil, idTokenHint: nil, requestConsent: false)
        }
        await fulfillment(of: [opened], timeout: 3)
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
    }

    private var validClaims: [String: Any] {
        ["iss": "https://auth.openai.com", "sub": "user-1", "aud": ["oaiapp_test"],
         "iat": date.timeIntervalSince1970 - 10, "exp": date.timeIntervalSince1970 + 3600,
         "nonce": "expected", "email": "reader@example.com"]
    }

    private var savedSession: ChatGPTSession {
        ChatGPTSession(registration: .init(clientID: "oaiapp_test", subject: "user-1", email: nil),
                       accessToken: "old-access", refreshToken: "old-refresh", idToken: "saved-id",
                       expiresAt: date.addingTimeInterval(-1), refreshExpiresAt: date.addingTimeInterval(100),
                       scopes: ["openid", "chatgpt.tokens.use.direct"], earliestRefreshAt: nil)
    }

    private func parse(_ target: String, host: String = "127.0.0.1:54321", previous: String? = nil)
        -> Result<ChatGPTOAuthCallback, ChatGPTError>? {
        ChatGPTCallbackParser.parse("GET \(target) HTTP/1.1\r\nHost: \(host)\r\n\r\n", port: 54321,
                                     expectedState: "expected", previousClientID: previous)
    }

    private static let discovery = """
    {"issuer":"https://auth.openai.com","authorization_endpoint":"https://auth.openai.com/api/accounts/authorize","token_endpoint":"https://auth.openai.com/api/accounts/oauth/token","jwks_uri":"https://auth.openai.com/.well-known/jwks.json","revocation_endpoint":"https://auth.openai.com/api/accounts/oauth/revoke"}
    """

    private func makeNetwork(_ handler: @escaping (URLRequest) -> (Int, String)) -> URLSession {
        ChatGPTAuthTestURLProtocol.handler = handler
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ChatGPTAuthTestURLProtocol.self]
        return URLSession(configuration: configuration)
    }
}

private extension Result where Success == ChatGPTOAuthCallback, Failure == ChatGPTError {
    var failure: ChatGPTError? { if case .failure(let value) = self { return value }; return nil }
}

private final class ChatGPTAuthTestURLProtocol: URLProtocol {
    static var handler: ((URLRequest) -> (Int, String))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        // URLSession may materialize a POST body as an InputStream before delivering
        // it to URLProtocol. Normalize it for request assertions, just as on the wire.
        var captured = request
        if captured.httpBody == nil, let stream = captured.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var bytes = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                bytes.append(buffer, count: count)
            }
            captured.httpBody = bytes
        }
        let (status, body) = Self.handler!(captured)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status,
                                                             httpVersion: "HTTP/1.1", headerFields: nil)!,
                            cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}

private struct TestSigningKey {
    let privateKey: SecKey
    let jwks: Data

    init() throws {
        var error: Unmanaged<CFError>?
        privateKey = try XCTUnwrap(SecKeyCreateRandomKey([kSecAttrKeyType: kSecAttrKeyTypeRSA,
                                                         kSecAttrKeySizeInBits: 2048] as CFDictionary, &error))
        let publicKey = try XCTUnwrap(SecKeyCopyPublicKey(privateKey))
        let publicData = try XCTUnwrap(SecKeyCopyExternalRepresentation(publicKey, &error)) as Data
        var offset = 0
        let sequence = try Self.read(publicData, offset: &offset, tag: 0x30)
        var innerOffset = 0
        let n = try Self.read(sequence, offset: &innerOffset, tag: 0x02).drop(while: { $0 == 0 })
        let e = try Self.read(sequence, offset: &innerOffset, tag: 0x02).drop(while: { $0 == 0 })
        jwks = try JSONSerialization.data(withJSONObject: ["keys": [[
            "kty": "RSA", "alg": "RS256", "use": "sig", "kid": "test-key",
            "n": base64URL(Data(n)), "e": base64URL(Data(e))
        ]]])
    }

    func token(_ claims: [String: Any]) throws -> String {
        let header = base64URL(try JSONSerialization.data(withJSONObject: ["alg": "RS256", "kid": "test-key"]))
        let payload = base64URL(try JSONSerialization.data(withJSONObject: claims))
        let message = header + "." + payload
        let signature = try XCTUnwrap(SecKeyCreateSignature(privateKey, .rsaSignatureMessagePKCS1v15SHA256,
                                                            Data(message.utf8) as CFData, nil)) as Data
        return message + "." + base64URL(signature)
    }

    private static func read(_ data: Data, offset: inout Int, tag: UInt8) throws -> Data {
        let bytes = Array(data)
        guard offset + 2 <= bytes.count, bytes[offset] == tag else { throw ChatGPTError.invalidAuthorization }
        offset += 1
        var count = Int(bytes[offset]); offset += 1
        if count & 0x80 != 0 {
            let size = count & 0x7f
            guard size > 0, size <= 4, offset + size <= bytes.count else { throw ChatGPTError.invalidAuthorization }
            count = 0
            for _ in 0..<size { count = (count << 8) | Int(bytes[offset]); offset += 1 }
        }
        guard offset + count <= bytes.count else { throw ChatGPTError.invalidAuthorization }
        defer { offset += count }
        return Data(bytes[offset..<(offset + count)])
    }
}

private func base64URL(_ data: Data) -> String {
    data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
}
