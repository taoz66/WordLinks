import Foundation
import OSLog

/// Authentication diagnostics contain only fixed vocabulary and HTTP status codes.
/// Never pass URLs, response bodies, callback values, claims, or credentials here.
/// OAuth descriptions are classified locally; their text is never emitted.
enum ChatGPTAuthDiagnostics {
    enum Stage: String {
        case signInStarted, discoveryStarted, discoveryReady, listenerReady, browserOpened
        case callbackReceived, codeExchangeStarted, codeExchangeHTTP, tokenDecoded, tokenDecodeFailed
        case jwksStarted, jwksReady, jwtRejected, identityValidated, identityOnlySession
        case sessionPrepared, sessionRejected, signInCompleted, signInFailed
        case discoveryRejected, requestRejected, authorizationRestarted
    }

    enum Cause: String {
        case none, unknown, cancelled, offline, timedOut, serviceUnavailable
        case authorizationDenied, browserUnavailable, callbackUnavailable, loginTimedOut
        case invalidAuthorization, authorizationCodeRejected, notEligible, unsupportedRequest, rateLimited
        case missingIDToken, tokenFields, tokenDecode, discoveryFormat, requestOrigin
        case jwtFormat, jwtAlgorithm, jwtSignatureKey, jwtSignature, jwtIssuer, jwtSubject
        case jwtExpiry, jwtIssuedAt, jwtAudience, jwtAuthorizedParty, jwtNotBefore
        case jwtNonce, jwtReturningSubject
    }

    private enum OAuthCode: String {
        case none, unknown
        case invalid_request, invalid_client, invalid_grant, unauthorized_client
        case unsupported_grant_type, invalid_scope, access_denied, temporarily_unavailable
        case invalid_refresh_token, token_expired, refresh_token_expired, refresh_token_invalid
        case refresh_token_invalidated, refresh_token_reused
    }

    private enum TokenField: String {
        case unknown, access_token, refresh_token, id_token, token_type, expires_in, scope, earliest_refresh_at
    }

    private enum OAuthDescription: String {
        case none, pkce, redirect, expired, reused, client, unknown

        init(_ text: String?) {
            guard let text, !text.isEmpty else { self = .none; return }
            let value = text.lowercased()
            if ["pkce", "code_verifier", "code verifier", "code_challenge", "code challenge"].contains(where: { value.contains($0) }) {
                self = .pkce
            } else if value.contains("redirect") { self = .redirect }
            else if ["already used", "already been used", "already redeemed", "reuse", "replay"].contains(where: { value.contains($0) }) {
                self = .reused
            } else if value.contains("expir") { self = .expired }
            else if value.contains("client") { self = .client }
            else { self = .unknown }
        }
    }

    private static let logger = Logger(subsystem: "com.readingtool.daily", category: "ChatGPTAuth")

    static func record(_ stage: Stage, cause: Cause = .none) {
        logger.notice("stage=\(stage.rawValue, privacy: .public) cause=\(cause.rawValue, privacy: .public)")
    }

    static func codeExchange(status: Int, oauthCode: String?, oauthDescription: String? = nil) {
        let code = oauthCode.map { OAuthCode(rawValue: $0) ?? .unknown } ?? .none
        let reason = OAuthDescription(oauthDescription)
        let safeStatus = (100...599).contains(status) ? status : 0
        logger.notice("stage=codeExchangeHTTP status=\(safeStatus, privacy: .public) oauth=\(code.rawValue, privacy: .public) reason=\(reason.rawValue, privacy: .public)")
    }

    static func tokenDecodeFailure(_ error: Error) {
        let key: String?
        switch error {
        case DecodingError.keyNotFound(let missing, _): key = missing.stringValue
        case DecodingError.typeMismatch(_, let context),
             DecodingError.valueNotFound(_, let context),
             DecodingError.dataCorrupted(let context): key = context.codingPath.last?.stringValue
        default: key = nil
        }
        let field = key.flatMap(TokenField.init(rawValue:)) ?? .unknown
        logger.error("stage=tokenDecodeFailed cause=tokenDecode field=\(field.rawValue, privacy: .public)")
    }

    static func signInFailure(_ error: Error) {
        let cause: Cause
        if error is CancellationError { cause = .cancelled }
        else {
            switch error as? ChatGPTError {
            case .offline?: cause = .offline
            case .timedOut?: cause = .timedOut
            case .serviceUnavailable?: cause = .serviceUnavailable
            case .authorizationDenied?: cause = .authorizationDenied
            case .browserUnavailable?: cause = .browserUnavailable
            case .callbackUnavailable?: cause = .callbackUnavailable
            case .loginTimedOut?: cause = .loginTimedOut
            case .invalidAuthorization?: cause = .invalidAuthorization
            case .authorizationCodeRejected?: cause = .authorizationCodeRejected
            case .notEligible?: cause = .notEligible
            case .unsupportedRequest?: cause = .unsupportedRequest
            case .rateLimited?: cause = .rateLimited
            default: cause = .unknown
            }
        }
        record(.signInFailed, cause: cause)
    }
}
