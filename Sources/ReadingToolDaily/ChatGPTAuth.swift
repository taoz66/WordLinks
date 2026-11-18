import AppKit
import CryptoKit
import Foundation
import Network
import Security

struct ChatGPTRegistration: Codable, Equatable {
    let clientID: String
    let subject: String
    let email: String?
}

struct ChatGPTSession: Codable, Equatable {
    let registration: ChatGPTRegistration
    let accessToken: String
    let refreshToken: String
    let idToken: String
    let expiresAt: Date
    let refreshExpiresAt: Date
    let scopes: Set<String>
    let earliestRefreshAt: Date?
}

@MainActor
protocol ChatGPTAuthenticating {
    func signIn(hostID: String, previous: ChatGPTRegistration?, idTokenHint: String?,
                requestConsent: Bool) async throws -> ChatGPTSession
    func refresh(_ session: ChatGPTSession) async throws -> ChatGPTSession
    func revoke(_ session: ChatGPTSession) async throws
}

/// A public OAuth client: every installation registers itself with OpenAI. No app secret
/// or developer API key is distributed, and credentials never leave the OpenAI origin.
@MainActor
final class ChatGPTAuthService: ChatGPTAuthenticating {
    nonisolated static let issuer = "https://auth.openai.com"
    nonisolated static let resource = "https://api.openai.com/v1"
    nonisolated static let requestedScopes = "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct"

    private let network: URLSession
    private let openBrowser: (URL) -> Bool
    private let onCallbackReceived: @MainActor () -> Void
    private let now: () -> Date
    private var discoveryCache: Discovery?

    init(network: URLSession? = nil,
         openBrowser: @escaping (URL) -> Bool = { NSWorkspace.shared.open($0) },
         onCallbackReceived: @escaping @MainActor () -> Void = { NSApp?.activate(ignoringOtherApps: true) },
         now: @escaping () -> Date = Date.init) {
        self.network = network ?? URLSession(configuration: .ephemeral,
                                             delegate: ChatGPTNoRedirects(), delegateQueue: nil)
        self.openBrowser = openBrowser
        self.onCallbackReceived = onCallbackReceived
        self.now = now
    }

    func signIn(hostID: String, previous: ChatGPTRegistration?, idTokenHint: String?,
                requestConsent: Bool) async throws -> ChatGPTSession {
        ChatGPTAuthDiagnostics.record(.signInStarted)
        do {
            let session = try await performSignIn(hostID: hostID, previous: previous,
                                                 idTokenHint: idTokenHint, requestConsent: requestConsent)
            ChatGPTAuthDiagnostics.record(.signInCompleted)
            return session
        } catch {
            ChatGPTAuthDiagnostics.signInFailure(error)
            throw error
        }
    }

    private func performSignIn(hostID: String, previous: ChatGPTRegistration?, idTokenHint: String?,
                               requestConsent: Bool) async throws -> ChatGPTSession {
        let discovery = try await discovery()
        // An issued client ID is only a routing hint until an ID token is verified.
        // Keep it local to this attempt; never create a registration from the callback.
        var pendingClientID: String?
        var previousCallbackPort: Int?
        for attempt in 0..<2 {
            try Task.checkCancellation()
            let state = try Self.randomValue()
            let nonce = try Self.randomValue()
            let verifier = try Self.randomValue()
            let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URL
            let (callback, redirect) = try await startCallback(state: state,
                                                              clientID: previous?.clientID ?? pendingClientID,
                                                              avoidingPort: previousCallbackPort)
            defer { callback.cancel() }
            previousCallbackPort = redirect.port
            ChatGPTAuthDiagnostics.record(.listenerReady)
            let url = try Self.authorizationURL(endpoint: discovery.authorizationEndpoint, hostID: hostID,
                                                previous: previous, idTokenHint: idTokenHint,
                                                requestConsent: requestConsent, redirect: redirect,
                                                state: state, nonce: nonce, challenge: challenge,
                                                issuedClientID: pendingClientID)
            try Task.checkCancellation()
            guard openBrowser(url) else { throw ChatGPTError.browserUnavailable }
            ChatGPTAuthDiagnostics.record(.browserOpened)
            let response: ChatGPTOAuthCallback
            do {
                response = try await callback.waitForCallback()
                ChatGPTAuthDiagnostics.record(.callbackReceived)
                onCallbackReceived()
            } catch let error as ChatGPTError {
                if error != .loginTimedOut { onCallbackReceived() }
                throw error
            }
            try Task.checkCancellation()
            ChatGPTAuthDiagnostics.record(.codeExchangeStarted)
            let result: TokenResponse
            do {
                result = try await tokenRequest(endpoint: discovery.tokenEndpoint, parameters: [
                    "grant_type": "authorization_code", "client_id": response.clientID,
                    "code": response.code, "code_verifier": verifier,
                    "redirect_uri": redirect.absoluteString, "resource": Self.resource
                ], refreshing: false)
            } catch CodeExchangeError.invalidGrant {
                guard attempt == 0 else { throw ChatGPTError.authorizationCodeRejected }
                // OpenAI requires a fresh authorization, never a replay of the old code.
                // The next iteration creates a new listener, state, nonce, and PKCE pair.
                pendingClientID = response.clientID
                ChatGPTAuthDiagnostics.record(.authorizationRestarted)
                continue
            }
            guard let idToken = result.idToken, !idToken.isEmpty else {
                ChatGPTAuthDiagnostics.record(.sessionRejected, cause: .missingIDToken)
                throw ChatGPTError.invalidAuthorization
            }
            let identity = try await validate(idToken: idToken, discovery: discovery, clientID: response.clientID,
                                              nonce: nonce, subject: previous?.subject)
            ChatGPTAuthDiagnostics.record(.identityValidated)
            let registration = ChatGPTRegistration(clientID: response.clientID, subject: identity.subject,
                                                    email: identity.email ?? previous?.email)
            return try makeSession(result, registration: registration, idToken: idToken, old: nil)
        }
        throw ChatGPTError.authorizationCodeRejected
    }

    private enum CodeExchangeError: Error { case invalidGrant }

    private func startCallback(state: String, clientID: String?, avoidingPort: Int?) async throws
        -> (ChatGPTLoopbackCallback, URL) {
        // A new listener normally receives a new ephemeral port. If the OS reuses
        // the old port, try a bounded number of fresh listeners before opening a browser.
        for _ in 0..<3 {
            try Task.checkCancellation()
            let callback = ChatGPTLoopbackCallback(expectedState: state, previousClientID: clientID)
            do {
                let redirect = try await callback.start()
                if redirect.port != avoidingPort { return (callback, redirect) }
                callback.cancel()
            } catch {
                callback.cancel()
                throw error
            }
        }
        throw ChatGPTError.callbackUnavailable
    }

    func refresh(_ session: ChatGPTSession) async throws -> ChatGPTSession {
        guard session.refreshExpiresAt > now() else { throw ChatGPTError.loginExpired }
        let discovery = try await discovery()
        let result = try await tokenRequest(endpoint: discovery.tokenEndpoint, parameters: [
            "grant_type": "refresh_token", "client_id": session.registration.clientID,
            "refresh_token": session.refreshToken, "resource": Self.resource
        ], refreshing: true)
        var registration = session.registration
        if let idToken = result.idToken {
            let identity = try await validate(idToken: idToken, discovery: discovery,
                                              clientID: registration.clientID, nonce: nil,
                                              subject: registration.subject)
            registration = ChatGPTRegistration(clientID: registration.clientID, subject: identity.subject,
                                                email: identity.email ?? registration.email)
        }
        return try makeSession(result, registration: registration,
                               idToken: result.idToken ?? session.idToken, old: session)
    }

    func revoke(_ session: ChatGPTSession) async throws {
        // Identity-only consent did not create a renewable inference session.
        guard !session.refreshToken.isEmpty else { return }
        // Revocation is idempotent. Retry one transient failure while the refresh
        // token is still available; never retry a token exchange this way.
        for attempt in 0..<2 {
            do {
                let discovery = try await discovery()
                let (_, response) = try await request(Self.formRequest(url: discovery.revocationEndpoint, parameters: [
                    "token": session.refreshToken, "token_type_hint": "refresh_token",
                    "client_id": session.registration.clientID
                ]))
                if response.statusCode == 200 { return }
                if response.statusCode >= 500 { throw ChatGPTError.serviceUnavailable }
                throw ChatGPTError.signOutUnconfirmed
            } catch is CancellationError { throw CancellationError() }
            catch let error as ChatGPTError {
                if attempt == 0, [.offline, .timedOut, .serviceUnavailable].contains(error) {
                    try await Task.sleep(nanoseconds: 250_000_000)
                    continue
                }
                throw ChatGPTError.signOutUnconfirmed
            } catch { throw ChatGPTError.signOutUnconfirmed }
        }
        throw ChatGPTError.signOutUnconfirmed
    }

    static func authorizationURL(endpoint: URL, hostID: String, previous: ChatGPTRegistration?,
                                 idTokenHint: String?, requestConsent: Bool, redirect: URL,
                                 state: String, nonce: String, challenge: String,
                                 issuedClientID: String? = nil) throws -> URL {
        guard isOpenAIURL(endpoint), !hostID.isEmpty,
              var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else {
            throw ChatGPTError.invalidAuthorization
        }
        var values = [
            "client_id": previous?.clientID ?? issuedClientID ?? "dynamic_agent_client", "ext_agent_host_id": hostID,
            "response_type": "code", "redirect_uri": redirect.absoluteString,
            "scope": requestedScopes, "resource": resource, "state": state, "nonce": nonce,
            "code_challenge_method": "S256", "code_challenge": challenge
        ]
        if previous == nil && issuedClientID == nil { values["agent_name_hint"] = "ReadingTool" }
        if previous != nil, let idTokenHint, !idTokenHint.isEmpty { values["id_token_hint"] = idTokenHint }
        if let email = previous?.email { values["login_hint"] = email }
        if requestConsent { values["prompt"] = "consent" }
        components.queryItems = values.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let url = components.url else { throw ChatGPTError.invalidAuthorization }
        return url
    }

    private func makeSession(_ result: TokenResponse, registration: ChatGPTRegistration,
                             idToken: String, old: ChatGPTSession?) throws -> ChatGPTSession {
        let scopes = result.scope.map { Set($0.split(separator: " ").map(String.init)) } ?? old?.scopes ?? []
        let received = now()
        // Identity-only consent is a valid sign-in. Preserve the verified account
        // so the user can grant plan use later, without treating it as an expired login.
        guard scopes.contains("chatgpt.tokens.use.direct") else {
            ChatGPTAuthDiagnostics.record(.identityOnlySession)
            return ChatGPTSession(registration: registration, accessToken: "", refreshToken: "",
                                  idToken: idToken, expiresAt: received, refreshExpiresAt: received,
                                  scopes: scopes, earliestRefreshAt: nil)
        }
        // Rotating refresh tokens must be replaced as one record with the access token.
        guard result.tokenType?.lowercased() == "bearer",
              let accessToken = result.accessToken, !accessToken.isEmpty,
              let refreshToken = result.refreshToken, !refreshToken.isEmpty,
              let expiresIn = result.expiresIn, expiresIn.isFinite, expiresIn > 0, expiresIn <= 86_400 else {
            ChatGPTAuthDiagnostics.record(.sessionRejected, cause: .tokenFields)
            throw ChatGPTError.invalidAuthorization
        }
        ChatGPTAuthDiagnostics.record(.sessionPrepared)
        return ChatGPTSession(registration: registration, accessToken: accessToken,
                              refreshToken: refreshToken, idToken: idToken,
                              expiresAt: received.addingTimeInterval(expiresIn),
                              refreshExpiresAt: received.addingTimeInterval(30 * 24 * 60 * 60),
                              scopes: scopes,
                              earliestRefreshAt: result.earliestRefreshAt.flatMap(Self.refreshDate))
    }

    private static func refreshDate(_ value: JSONTimestamp) -> Date? {
        switch value {
        case .number(let seconds): return seconds.isFinite ? Date(timeIntervalSince1970: seconds) : nil
        case .text(let text): return ISO8601DateFormatter().date(from: text)
        }
    }

    private func tokenRequest(endpoint: URL, parameters: [String: String], refreshing: Bool) async throws -> TokenResponse {
        let (data, response) = try await request(Self.formRequest(url: endpoint, parameters: parameters))
        guard response.statusCode == 200 else {
            let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let code = (body?["error"] as? String)
                ?? ((body?["error"] as? [String: Any])?["code"] as? String)
            let description = (body?["error_description"] as? String)
                ?? ((body?["error"] as? [String: Any])?["message"] as? String)
            ChatGPTAuthDiagnostics.codeExchange(status: response.statusCode, oauthCode: code,
                                                oauthDescription: description)
            if refreshing, let code, ["invalid_grant", "invalid_refresh_token", "token_expired",
                                      "refresh_token_expired", "refresh_token_invalid", "refresh_token_invalidated",
                                      "refresh_token_reused"].contains(code) {
                throw ChatGPTError.loginExpired
            }
            if !refreshing, response.statusCode == 400, code == "invalid_grant" {
                throw CodeExchangeError.invalidGrant
            }
            if code == "invalid_client" || code == "unsupported_grant_type" { throw ChatGPTError.unsupportedRequest }
            if response.statusCode == 429 { throw ChatGPTError.rateLimited }
            if response.statusCode >= 500 { throw ChatGPTError.serviceUnavailable }
            if code == "access_denied" { throw ChatGPTError.authorizationDenied }
            if response.statusCode == 403 { throw ChatGPTError.notEligible }
            throw ChatGPTError.invalidAuthorization
        }
        ChatGPTAuthDiagnostics.codeExchange(status: response.statusCode, oauthCode: nil)
        do {
            let tokens = try JSONDecoder().decode(TokenResponse.self, from: data)
            ChatGPTAuthDiagnostics.record(.tokenDecoded)
            return tokens
        } catch {
            ChatGPTAuthDiagnostics.tokenDecodeFailure(error)
            throw ChatGPTError.invalidAuthorization
        }
    }

    private func discovery() async throws -> Discovery {
        if let discoveryCache {
            ChatGPTAuthDiagnostics.record(.discoveryReady)
            return discoveryCache
        }
        ChatGPTAuthDiagnostics.record(.discoveryStarted)
        let url = URL(string: Self.issuer + "/.well-known/openid-configuration")!
        let (data, response) = try await request(URLRequest(url: url))
        guard response.statusCode == 200,
              let value = try? JSONDecoder().decode(Discovery.self, from: data),
              value.issuer == Self.issuer,
              [value.authorizationEndpoint, value.tokenEndpoint, value.jwksURI,
               value.revocationEndpoint].allSatisfy(Self.isOpenAIURL) else {
            ChatGPTAuthDiagnostics.record(.discoveryRejected, cause: .discoveryFormat)
            if response.statusCode >= 500 { throw ChatGPTError.serviceUnavailable }
            throw ChatGPTError.invalidAuthorization
        }
        discoveryCache = value
        ChatGPTAuthDiagnostics.record(.discoveryReady)
        return value
    }

    private func validate(idToken: String, discovery: Discovery, clientID: String,
                          nonce: String?, subject: String?) async throws -> ChatGPTIdentity {
        // Fetch for each token validation so a newly rotated signing key is immediately accepted.
        ChatGPTAuthDiagnostics.record(.jwksStarted)
        let (data, response) = try await request(URLRequest(url: discovery.jwksURI))
        guard response.statusCode == 200 else { throw ChatGPTError.serviceUnavailable }
        ChatGPTAuthDiagnostics.record(.jwksReady)
        return try ChatGPTIDTokenValidator.validate(idToken, jwks: data, clientID: clientID,
                                                    nonce: nonce, subject: subject, now: now())
    }

    private func request(_ input: URLRequest) async throws -> (Data, HTTPURLResponse) {
        guard let url = input.url, Self.isOpenAIURL(url) else { throw ChatGPTError.invalidAuthorization }
        var request = input
        request.timeoutInterval = 30
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            try Task.checkCancellation()
            let (data, response) = try await network.data(for: request)
            try Task.checkCancellation()
            guard let http = response as? HTTPURLResponse, let actualURL = http.url,
                  Self.isOpenAIURL(actualURL), actualURL == url,
                  data.count <= 1_048_576 else {
                ChatGPTAuthDiagnostics.record(.requestRejected, cause: .requestOrigin)
                throw ChatGPTError.invalidAuthorization
            }
            return (data, http)
        } catch is CancellationError { throw CancellationError() }
        catch let error as URLError {
            if error.code == .cancelled { throw CancellationError() }
            if error.code == .timedOut { throw ChatGPTError.timedOut }
            throw ChatGPTError.offline
        }
    }

    private static func isOpenAIURL(_ url: URL) -> Bool {
        url.scheme == "https" && url.host == "auth.openai.com" && url.user == nil && url.password == nil
            && (url.port == nil || url.port == 443) && url.fragment == nil
    }

    private static func formRequest(url: URL, parameters: [String: String]) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        let encoded = parameters.sorted { $0.key < $1.key }.map { key, value in
            key.addingPercentEncoding(withAllowedCharacters: allowed)! + "="
                + value.addingPercentEncoding(withAllowedCharacters: allowed)!
        }.joined(separator: "&")
        request.httpBody = Data(encoded.utf8)
        return request
    }

    static func randomValue() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw ChatGPTError.invalidAuthorization
        }
        return Data(bytes).base64URL
    }

    private struct Discovery: Decodable {
        let issuer: String
        let authorizationEndpoint: URL
        let tokenEndpoint: URL
        let jwksURI: URL
        let revocationEndpoint: URL
        enum CodingKeys: String, CodingKey {
            case issuer
            case authorizationEndpoint = "authorization_endpoint"
            case tokenEndpoint = "token_endpoint"
            case jwksURI = "jwks_uri"
            case revocationEndpoint = "revocation_endpoint"
        }
    }

    private struct TokenResponse: Decodable {
        let accessToken: String?
        let refreshToken: String?
        let idToken: String?
        let tokenType: String?
        let expiresIn: TimeInterval?
        let scope: String?
        let earliestRefreshAt: JSONTimestamp?
        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token", refreshToken = "refresh_token", idToken = "id_token"
            case tokenType = "token_type", expiresIn = "expires_in", scope
            case earliestRefreshAt = "earliest_refresh_at"
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            accessToken = try values.decodeIfPresent(String.self, forKey: .accessToken)
            refreshToken = try values.decodeIfPresent(String.self, forKey: .refreshToken)
            idToken = try values.decodeIfPresent(String.self, forKey: .idToken)
            tokenType = try values.decodeIfPresent(String.self, forKey: .tokenType)
            expiresIn = try values.decodeIfPresent(TimeInterval.self, forKey: .expiresIn)
            scope = try values.decodeIfPresent(String.self, forKey: .scope)
            // A scheduling hint is not part of authentication. Ignore unfamiliar
            // hint formats without discarding otherwise valid OAuth credentials.
            earliestRefreshAt = try? values.decodeIfPresent(JSONTimestamp.self, forKey: .earliestRefreshAt)
        }
    }

    private enum JSONTimestamp: Decodable {
        case number(Double), text(String)
        init(from decoder: Decoder) throws {
            let value = try decoder.singleValueContainer()
            if let number = try? value.decode(Double.self) { self = .number(number) }
            else { self = .text(try value.decode(String.self)) }
        }
    }
}

private final class ChatGPTNoRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

struct ChatGPTIdentity: Equatable {
    let subject: String
    let email: String?
}

/// OpenAI currently publishes RS256 as its sole ID-token signing algorithm. Only
/// that algorithm is accepted; the JWT header never controls algorithm selection.
enum ChatGPTIDTokenValidator {
    static func validate(_ token: String, jwks: Data, clientID: String, nonce: String?,
                         subject: String?, now: Date) throws -> ChatGPTIdentity {
        guard token.utf8.count <= 65_536 else { throw rejected(.jwtFormat) }
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3,
              let headerData = Data(base64URL: String(parts[0])),
              let payloadData = Data(base64URL: String(parts[1])),
              let signature = Data(base64URL: String(parts[2])),
              let header = try? JSONSerialization.jsonObject(with: headerData) as? [String: Any] else {
            throw rejected(.jwtFormat)
        }
        guard header["alg"] as? String == "RS256", header["crit"] == nil else {
            throw rejected(.jwtAlgorithm)
        }
        guard let kid = header["kid"] as? String, !kid.isEmpty,
              let keySet = try? JSONSerialization.jsonObject(with: jwks) as? [String: Any],
              let keys = keySet["keys"] as? [[String: Any]],
              let key = keys.first(where: { $0["kid"] as? String == kid }),
              key["kty"] as? String == "RSA",
              key["use"] == nil || key["use"] as? String == "sig",
              key["alg"] == nil || key["alg"] as? String == "RS256",
              let modulusText = key["n"] as? String, let exponentText = key["e"] as? String,
              let modulus = Data(base64URL: modulusText), let exponent = Data(base64URL: exponentText),
              modulus.count >= 256, modulus.count <= 1_024, !exponent.isEmpty, exponent.count <= 8 else {
            throw rejected(.jwtSignatureKey)
        }
        let encoded = sequence(integer(modulus) + integer(exponent))
        let attributes: [String: Any] = [kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
                                       kSecAttrKeyClass as String: kSecAttrKeyClassPublic]
        guard let publicKey = SecKeyCreateWithData(encoded as CFData, attributes as CFDictionary, nil),
              SecKeyIsAlgorithmSupported(publicKey, .verify, .rsaSignatureMessagePKCS1v15SHA256) else {
            throw rejected(.jwtSignatureKey)
        }
        guard SecKeyVerifySignature(publicKey, .rsaSignatureMessagePKCS1v15SHA256,
                                    Data((parts[0] + "." + parts[1]).utf8) as CFData,
                                    signature as CFData, nil) else { throw rejected(.jwtSignature) }
        guard let payload = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any] else {
            throw rejected(.jwtFormat)
        }
        guard payload["iss"] as? String == ChatGPTAuthService.issuer else { throw rejected(.jwtIssuer) }
        guard let sub = payload["sub"] as? String, !sub.isEmpty else { throw rejected(.jwtSubject) }
        guard let expiry = payload["exp"] as? Double, expiry.isFinite,
              expiry > now.timeIntervalSince1970 - 5 else { throw rejected(.jwtExpiry) }
        guard let issued = payload["iat"] as? Double, issued.isFinite,
              issued <= now.timeIntervalSince1970 + 5 else { throw rejected(.jwtIssuedAt) }
        let audiences: [String]
        if let audience = payload["aud"] as? String { audiences = [audience] }
        else { audiences = payload["aud"] as? [String] ?? [] }
        guard audiences.contains(clientID) else { throw rejected(.jwtAudience) }
        if audiences.count > 1 || payload["azp"] != nil {
            guard payload["azp"] as? String == clientID else { throw rejected(.jwtAuthorizedParty) }
        }
        if let notBefore = payload["nbf"] {
            guard let timestamp = notBefore as? Double, timestamp.isFinite,
                  timestamp <= now.timeIntervalSince1970 + 5 else { throw rejected(.jwtNotBefore) }
        }
        if let nonce, payload["nonce"] as? String != nonce { throw rejected(.jwtNonce) }
        if let subject, sub != subject { throw rejected(.jwtReturningSubject) }
        return ChatGPTIdentity(subject: sub, email: payload["email"] as? String)
    }

    private static func rejected(_ cause: ChatGPTAuthDiagnostics.Cause) -> ChatGPTError {
        ChatGPTAuthDiagnostics.record(.jwtRejected, cause: cause)
        return .invalidAuthorization
    }

    private static func length(_ count: Int) -> Data {
        if count < 128 { return Data([UInt8(count)]) }
        var value = count
        var bytes = [UInt8]()
        while value > 0 { bytes.insert(UInt8(value & 0xff), at: 0); value >>= 8 }
        return Data([0x80 | UInt8(bytes.count)] + bytes)
    }

    private static func integer(_ value: Data) -> Data {
        var bytes = Array(value.drop(while: { $0 == 0 }))
        if bytes.isEmpty { bytes = [0] }
        if bytes[0] & 0x80 != 0 { bytes.insert(0, at: 0) }
        return Data([0x02]) + length(bytes.count) + Data(bytes)
    }

    private static func sequence(_ value: Data) -> Data { Data([0x30]) + length(value.count) + value }
}

struct ChatGPTOAuthCallback: Equatable {
    let code: String
    let clientID: String
}

/// Returning nil rejects an unrelated local HTTP request without consuming the login.
enum ChatGPTCallbackParser {
    static func parse(_ request: String, port: UInt16, expectedState: String,
                      previousClientID: String?) -> Result<ChatGPTOAuthCallback, ChatGPTError>? {
        let lines = request.components(separatedBy: "\r\n")
        guard let first = lines.first else { return nil }
        let words = first.split(separator: " ")
        guard words.count == 3, words[0] == "GET", words[2] == "HTTP/1.1",
              words[1].hasPrefix("/"), !words[1].hasPrefix("//"),
              let components = URLComponents(string: "http://127.0.0.1:\(port)" + words[1]),
              components.path == "/auth/callback", components.fragment == nil else { return nil }
        let hostLines = lines.dropFirst().filter { $0.lowercased().hasPrefix("host:") }
        guard hostLines.count == 1,
              hostLines[0].dropFirst(5).trimmingCharacters(in: .whitespaces).lowercased() == "127.0.0.1:\(port)" else { return nil }
        let items = components.queryItems ?? []
        let states = items.filter { $0.name == "state" }
        guard states.count == 1, states[0].value == expectedState else { return nil }
        var values = [String: String]()
        for item in items {
            guard values[item.name] == nil, let value = item.value else { return .failure(.invalidAuthorization) }
            values[item.name] = value
        }
        if let error = values["error"] {
            return .failure(error == "access_denied" ? .authorizationDenied : .invalidAuthorization)
        }
        guard let code = values["code"], !code.isEmpty, code.utf8.count <= 8_192 else {
            return .failure(.invalidAuthorization)
        }
        let issued = values["client_id"] ?? previousClientID
        guard let clientID = issued, !clientID.isEmpty, clientID != "dynamic_agent_client",
              clientID.utf8.count <= 512,
              previousClientID == nil || previousClientID == clientID else { return .failure(.invalidAuthorization) }
        return .success(ChatGPTOAuthCallback(code: code, clientID: clientID))
    }
}

@MainActor
private final class ChatGPTLoopbackCallback {
    private let expectedState: String
    private let previousClientID: String?
    private var listener: NWListener?
    private var startContinuation: CheckedContinuation<URL, Error>?
    private var callbackContinuation: CheckedContinuation<ChatGPTOAuthCallback, Error>?
    private var outcome: Result<ChatGPTOAuthCallback, Error>?
    private var timeout: Task<Void, Never>?
    private var connections = [UUID: NWConnection]()
    private var connectionTimeouts = [UUID: Task<Void, Never>]()
    private var port: UInt16 = 0

    init(expectedState: String, previousClientID: String?) {
        self.expectedState = expectedState
        self.previousClientID = previousClientID
    }

    func start() async throws -> URL {
        try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                startContinuation = continuation
                let parameters = NWParameters.tcp
                parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
                do {
                    let listener = try NWListener(using: parameters)
                    self.listener = listener
                    listener.stateUpdateHandler = { [weak self] state in
                        Task { @MainActor in self?.listenerStateChanged(state) }
                    }
                    listener.newConnectionHandler = { [weak self] connection in
                        Task { @MainActor in self?.accept(connection) }
                    }
                    listener.start(queue: .main)
                    timeout = Task { [weak self] in
                        do { try await Task.sleep(nanoseconds: 180_000_000_000) }
                        catch { return }
                        self?.finish(.failure(ChatGPTError.loginTimedOut))
                    }
                } catch { finish(.failure(ChatGPTError.callbackUnavailable)) }
            }
        }, onCancel: { Task { @MainActor [weak self] in self?.cancel() } })
    }

    func waitForCallback() async throws -> ChatGPTOAuthCallback {
        try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            if let outcome { return try outcome.get() }
            return try await withCheckedThrowingContinuation { callbackContinuation = $0 }
        }, onCancel: { Task { @MainActor [weak self] in self?.cancel() } })
    }

    func cancel() { finish(.failure(CancellationError())) }

    private func listenerStateChanged(_ state: NWListener.State) {
        switch state {
        case .ready:
            guard let port = listener?.port?.rawValue, let continuation = startContinuation else { return }
            self.port = port
            startContinuation = nil
            continuation.resume(returning: URL(string: "http://127.0.0.1:\(port)/auth/callback")!)
        case .failed, .waiting: finish(.failure(ChatGPTError.callbackUnavailable))
        default: break
        }
    }

    private func accept(_ connection: NWConnection) {
        guard outcome == nil, connections.count < 12 else { connection.cancel(); return }
        let id = UUID()
        connections[id] = connection
        connection.start(queue: .main)
        connectionTimeouts[id] = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 10_000_000_000) }
            catch { return }
            self?.close(id)
        }
        receive(connection, id: id, accumulated: Data())
    }

    private func receive(_ connection: NWConnection, id: UUID, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, complete, error in
            Task { @MainActor in
                guard let self, self.connections[id] != nil else { return }
                var buffer = accumulated
                if let data { buffer.append(data) }
                guard buffer.count <= 16_384 else { self.reply(connection, id: id, accepted: false); return }
                if buffer.range(of: Data("\r\n\r\n".utf8)) != nil {
                    let request = String(decoding: buffer, as: UTF8.self)
                    let parsed = ChatGPTCallbackParser.parse(request, port: self.port,
                                                             expectedState: self.expectedState,
                                                             previousClientID: self.previousClientID)
                    self.reply(connection, id: id, accepted: parsed != nil)
                    if let parsed {
                        // Let the completion response reach the browser before stopping the listener.
                        self.finish(parsed.mapError { $0 as Error }, preserveConnection: id)
                    }
                } else if complete || error != nil { self.close(id) }
                else { self.receive(connection, id: id, accumulated: buffer) }
            }
        }
    }

    private func reply(_ connection: NWConnection, id: UUID, accepted: Bool) {
        let body = accepted
            ? "<!doctype html><meta charset=utf-8><title>ReadingTool</title><p>已收到登录结果，请返回 ReadingTool 查看连接状态。Sign-in result received. Return to ReadingTool to check the connection status.</p>"
            : "<!doctype html><meta charset=utf-8><title>ReadingTool</title><p>此页面无法完成登录，请返回 ReadingTool。Return to ReadingTool to continue.</p>"
        let response = "HTTP/1.1 \(accepted ? "200 OK" : "400 Bad Request")\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\nCache-Control: no-store\r\nContent-Security-Policy: default-src 'none'; frame-ancestors 'none'\r\nReferrer-Policy: no-referrer\r\n\r\n" + body
        connection.send(content: Data(response.utf8), completion: .contentProcessed { [weak self] _ in
            Task { @MainActor in self?.close(id) }
        })
    }

    private func close(_ id: UUID) {
        connectionTimeouts.removeValue(forKey: id)?.cancel()
        connections.removeValue(forKey: id)?.cancel()
    }

    private func finish(_ result: Result<ChatGPTOAuthCallback, Error>, preserveConnection: UUID? = nil) {
        guard outcome == nil else { return }
        outcome = result
        timeout?.cancel()
        timeout = nil
        listener?.cancel()
        listener = nil
        for id in Array(connections.keys) where id != preserveConnection { close(id) }
        if let continuation = startContinuation {
            startContinuation = nil
            switch result {
            case .failure(let error): continuation.resume(throwing: error)
            case .success: continuation.resume(throwing: ChatGPTError.invalidAuthorization)
            }
        }
        if let continuation = callbackContinuation {
            callbackContinuation = nil
            continuation.resume(with: result)
        }
    }
}

private extension Data {
    var base64URL: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    init?(base64URL value: String) {
        guard !value.isEmpty, value.unicodeScalars.allSatisfy({
            CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_").contains($0)
        }) else { return nil }
        let base64 = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        self.init(base64Encoded: base64 + String(repeating: "=", count: (4 - base64.count % 4) % 4))
    }
}
