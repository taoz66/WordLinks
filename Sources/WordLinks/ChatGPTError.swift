import Foundation

enum ChatGPTRecovery: Equatable {
    case signIn, authorize, manageUsage, retry, none
}

/// Only these curated messages reach the UI. Server bodies and credentials never do.
enum ChatGPTError: Error, LocalizedError, Equatable {
    case notSignedIn, loginExpired, authorizationDenied, missingPlanPermission
    case notEligible, usageLimit, insufficientCredits, rateLimited
    case offline, timedOut, serviceUnavailable, loginTimedOut
    case browserUnavailable, callbackUnavailable, invalidAuthorization, authorizationCodeRejected
    case unsupportedRequest, inputTooLarge, modelUnavailable, emptyResponse, interrupted
    case storage, signOutUnconfirmed, refused, invalidSelection, unknown

    var errorDescription: String? {
        switch self {
        case .notSignedIn: return L("请先登录 ChatGPT，即可使用 AI 释义。", "Sign in to ChatGPT to use AI explanations.")
        case .loginExpired: return L("ChatGPT 登录已过期，请重新登录。", "Your ChatGPT sign-in has expired. Sign in again.")
        case .authorizationDenied: return L("这次没有完成授权，可以重新登录。", "Authorization wasn’t completed. You can sign in again.")
        case .missingPlanPermission: return L("还未允许使用 ChatGPT 订阅，请完成授权。", "Allow this app to use your ChatGPT plan to continue.")
        case .notEligible: return L("当前账号暂不支持此功能，请使用符合条件的 ChatGPT Plus 或 Pro 账号。", "This account can’t use this feature. Use an eligible ChatGPT Plus or Pro account.")
        case .usageLimit: return L("ChatGPT 使用额度已达上限，请查看用量或稍后再试。", "Your ChatGPT usage limit was reached. Review usage or try again later.")
        case .insufficientCredits: return L("可用余额不足，请前往 ChatGPT 查看额度。", "Your available credits are insufficient. Review your ChatGPT usage.")
        case .rateLimited: return L("请求有点频繁，请稍后再试。", "Too many requests. Please try again shortly.")
        case .offline: return L("暂时连不上 ChatGPT，请检查网络后重试。", "Can’t connect to ChatGPT. Check your connection and try again.")
        case .timedOut: return L("ChatGPT 响应超时，请重试。", "ChatGPT took too long to respond. Please try again.")
        case .serviceUnavailable: return L("ChatGPT 暂时不可用，请稍后重试。", "ChatGPT is temporarily unavailable. Try again later.")
        case .loginTimedOut: return L("登录等待超时，请重新登录。", "Sign-in timed out. Please start again.")
        case .browserUnavailable: return L("无法打开登录页面，请检查默认浏览器后重试。", "Can’t open the sign-in page. Check your default browser and try again.")
        case .callbackUnavailable: return L("暂时无法接收登录结果，请重试。", "Can’t receive the sign-in result right now. Please try again.")
        case .invalidAuthorization: return L("无法确认这次登录，请重新登录。", "This sign-in couldn’t be verified. Please sign in again.")
        case .authorizationCodeRejected: return L("ChatGPT 未接受这次授权，请稍后重新连接。", "ChatGPT didn’t accept this authorization. Try connecting again later.")
        case .unsupportedRequest: return L("当前连接暂不支持这项功能，请更新应用后重试。", "This connection doesn’t currently support this feature. Update the app and try again.")
        case .inputTooLarge: return L("选中的内容太长，请缩短选区后重试。", "The selected text is too long. Select a shorter passage and try again.")
        case .modelUnavailable: return L("暂时没有可用的 AI 模型，请稍后重试。", "No AI model is available right now. Please try again later.")
        case .emptyResponse: return L("这次没有收到释义，请重试。", "No explanation was received. Please try again.")
        case .interrupted: return L("释义接收中断，请重试。", "The explanation was interrupted. Please try again.")
        case .storage: return L("无法读取或保存登录信息，请检查钥匙串权限后重试。", "Can’t read or save sign-in information. Check Keychain access and try again.")
        case .signOutUnconfirmed: return L("已在本机退出。暂时无法确认远程退出，可在 ChatGPT 设置中断开本应用。", "Signed out on this Mac. Remote sign-out couldn’t be confirmed; you can disconnect this app in ChatGPT settings.")
        case .refused: return L("这段内容暂时无法解释，请换一段文字。", "This text can’t be explained right now. Try another selection.")
        case .invalidSelection: return L("请重新选择要解释的词句。", "Select the word or phrase again.")
        case .unknown: return L("这次未能完成，请重试。", "This couldn’t be completed. Please try again.")
        }
    }

    var recovery: ChatGPTRecovery {
        switch self {
        case .notSignedIn, .loginExpired, .authorizationDenied, .loginTimedOut,
             .browserUnavailable, .callbackUnavailable, .invalidAuthorization, .authorizationCodeRejected: return .signIn
        case .missingPlanPermission: return .authorize
        case .usageLimit, .insufficientCredits, .notEligible, .signOutUnconfirmed: return .manageUsage
        case .rateLimited, .offline, .timedOut, .serviceUnavailable, .modelUnavailable,
             .emptyResponse, .interrupted, .storage, .unknown: return .retry
        case .unsupportedRequest, .inputTooLarge, .refused, .invalidSelection: return .none
        }
    }

    static func from(_ error: Error) -> ChatGPTError {
        if let issue = error as? ChatGPTError { return issue }
        if let error = error as? URLError {
            return error.code == .timedOut ? .timedOut : .offline
        }
        if let error = error as? AIError {
            switch error {
            case .invalidSelection: return .invalidSelection
            case .keychain: return .storage
            case .timedOut: return .timedOut
            case .connectionFailed: return .offline
            case .emptyResponse: return .emptyResponse
            case .inputTooLarge: return .inputTooLarge
            default: return .unknown
            }
        }
        return .unknown
    }

    static func fromHTTP(status: Int, data: Data) -> ChatGPTError {
        let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let error = body?["error"] as? [String: Any] ?? body ?? [:]
        let code = error["code"] as? String ?? error["type"] as? String ?? ""
        switch code {
        case "subscription_sharing_user_not_eligible": return .notEligible
        case "subscription_sharing_usage_limit_exceeded": return .usageLimit
        case "insufficient_quota", "insufficient_credits", "credit_balance_too_low", "billing_hard_limit_reached": return .insufficientCredits
        case "rate_limit_exceeded", "rate_limit_error": return .rateLimited
        case "subscription_sharing_usage_unavailable", "subscription_sharing_user_unavailable": return .serviceUnavailable
        case "subscription_sharing_invalid_user", "invalid_api_key", "token_expired", "invalid_grant",
             "invalid_refresh_token", "refresh_token_expired", "refresh_token_invalid", "refresh_token_invalidated", "refresh_token_reused": return .loginExpired
        case "subscription_sharing_unsupported_capability":
            return error["param"] as? String == "model" ? .modelUnavailable : .unsupportedRequest
        case "subscription_sharing_route_not_supported", "chatpass_v2_scope_not_authorized",
             "chatpass_v2_invalid_authorization_context", "invalid_client": return .unsupportedRequest
        case "model_not_found", "model_not_available": return .modelUnavailable
        case "access_denied": return .authorizationDenied
        case "content_policy_violation": return .refused
        default: break
        }
        switch status {
        case 401: return .invalidAuthorization
        case 402: return .insufficientCredits
        case 403: return .notEligible
        case 408, 504: return .timedOut
        case 429: return .rateLimited
        case 500...599: return .serviceUnavailable
        default: return .unknown
        }
    }
}
