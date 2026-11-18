import Foundation
import SwiftUI

/// Provider-specific failures retain their origin so an API error never becomes a ChatGPT sign-in prompt.
enum AIUsageIssue: Error, LocalizedError, Equatable {
    case chatGPT(ChatGPTError)
    case custom(AIError)
    case appleIntelligence(AppleIntelligenceError)
    case configurationChanged

    var isMissingConfiguration: Bool {
        switch self {
        case .chatGPT(.notSignedIn): return true
        case .custom(.missingAPIKey), .custom(.missingModel), .custom(.invalidAPIKey),
             .custom(.invalidAddress), .custom(.missingProfile): return true
        default: return false
        }
    }

    var errorDescription: String? {
        switch self {
        case .chatGPT(.notSignedIn):
            return L("请先配置 AI，再使用释义。", "Configure an AI service before using explanations.")
        case .chatGPT(let issue):
            return issue.localizedDescription
        case .appleIntelligence(let issue):
            return issue.localizedDescription
        case .configurationChanged:
            return L("AI 配置已更改，请重试。", "AI settings changed. Please try again.")
        case .custom(let issue):
            switch issue {
            case .missingAPIKey:
                return L("请先在 AI 设置中填写 API 密钥。", "Enter an API key in AI settings first.")
            case .invalidAPIKey:
                return L("API 密钥格式不正确，请在 AI 设置中检查。", "The API key format is invalid. Check AI settings.")
            case .missingModel:
                return L("请先在 AI 设置中选择模型。", "Select a model in AI settings first.")
            case .invalidAddress:
                return L("API 地址不正确，请在 AI 设置中检查。", "The API address is invalid. Check AI settings.")
            case .missingProfile:
                return L("请先选择并配置一个 AI 服务。", "Choose and configure an AI service first.")
            case .profileStorage:
                return L("无法读取或保存 AI 配置，请在 AI 设置中重试。", "AI settings couldn’t be read or saved. Try again in AI settings.")
            case .invalidSelection:
                return L("请重新选择要解释的词句。", "Select the word or phrase again.")
            case .inputTooLarge:
                return L("选中的内容太长，请缩短选区后重试。", "The selected text is too long. Select a shorter passage and try again.")
            case .outputTruncated:
                return L("译文太长，服务未能完整返回。请缩短选区后重试。", "The translation was too long for the service to return completely. Select a shorter passage and try again.")
            case .keychain:
                return L("无法读取或保存 API 密钥，请检查钥匙串权限后重试。", "The API key couldn’t be read or saved. Check Keychain access and try again.")
            case .timedOut:
                return L("AI 响应超时，请重试。", "AI took too long to respond. Please try again.")
            case .connectionFailed:
                return L("暂时连不上 AI 服务，请检查网络后重试。", "Can’t connect to the AI service. Check your connection and try again.")
            case .emptyResponse:
                return L("这次没有收到释义，请重试。", "No explanation was received. Please try again.")
            case .emptyModels:
                return L("没有找到可用模型，请检查 API 权限。", "No models are available. Check the API permissions.")
            case .invalidResponse, .invalidModelsResponse:
                return L("AI 服务返回的内容无法读取，请检查接口和模型设置。", "The AI response couldn’t be read. Check the endpoint and model in AI settings.")
            case .http(let status), .modelsHTTP(let status):
                return Self.httpMessage(status)
            }
        }
    }

    var recovery: AIUsageRecovery {
        switch self {
        case .configurationChanged:
            return .retry
        case .appleIntelligence(let issue):
            switch issue {
            case .unavailable: return .settingsAndRetry
            case .inputTooLarge, .invalidSelection, .refused: return .none
            default: return .retry
            }
        case .chatGPT(let issue):
            switch issue.recovery {
            case .signIn, .authorize: return .settings
            case .manageUsage:
                switch issue {
                case .usageLimit, .insufficientCredits: return .usageAndRetry
                case .notEligible: return .accountAndSettings
                default: return .manageUsage
                }
            case .retry: return .retry
            case .none: return .none
            }
        case .custom(let issue):
            switch issue {
            case .missingAPIKey, .invalidAPIKey, .missingModel, .invalidAddress, .missingProfile,
                 .profileStorage, .keychain, .emptyModels, .invalidModelsResponse, .invalidResponse:
                return .settings
            case .connectionFailed, .timedOut, .emptyResponse:
                return .retry
            case .invalidSelection, .inputTooLarge, .outputTruncated:
                return .none
            case .http(let status), .modelsHTTP(let status):
                switch status {
                case 402, 429: return .settingsAndRetry
                case 408, 500...599: return .retry
                default: return .settings
                }
            }
        }
    }

    static func from(_ error: Error) -> AIUsageIssue {
        if let issue = error as? AIUsageIssue { return issue }
        if let issue = error as? ChatGPTError { return .chatGPT(issue) }
        if let issue = error as? AIError { return .custom(issue) }
        if let issue = error as? AppleIntelligenceError { return .appleIntelligence(issue) }
        if let issue = error as? URLError {
            return .custom(issue.code == .timedOut ? .timedOut : .connectionFailed)
        }
        return .custom(.invalidResponse)
    }

    private static func httpMessage(_ status: Int) -> String {
        switch status {
        case 401:
            return L("API 密钥无效或已过期，请在 AI 设置中更新。", "The API key is invalid or expired. Update it in AI settings.")
        case 403:
            return L("当前 API 没有调用权限，请检查账号和模型权限。", "This API request isn’t permitted. Check the account and model permissions.")
        case 402:
            return L("API 余额不足，请到服务商账户查看余额。", "The API balance is insufficient. Review your provider account.")
        case 429:
            return L("API 额度不足或请求过于频繁，请查看服务商额度或稍后重试。", "The API quota was reached or requests are too frequent. Review your provider’s usage or try again later.")
        case 408, 504:
            return L("AI 响应超时，请重试。", "AI took too long to respond. Please try again.")
        case 500...599:
            return L("AI 服务暂时不可用，请稍后重试。", "The AI service is temporarily unavailable. Please try again later.")
        case 404:
            return L("找不到当前接口或模型，请检查 AI 设置。", "The endpoint or model couldn’t be found. Check AI settings.")
        default:
            return L("AI 请求未能完成，请检查接口和模型设置。", "The AI request couldn’t be completed. Check the endpoint and model in AI settings.")
        }
    }
}

enum AIUsageRecovery: Equatable {
    case settings, retry, settingsAndRetry, manageUsage, usageAndRetry, accountAndSettings, none
}

/// Shared actions for either provider. Only ChatGPT issues link to ChatGPT usage.
struct AIUsageRecoveryActions: View {
    let issue: AIUsageIssue
    let retry: () -> Void
    let openSettings: () -> Void

    @ViewBuilder var body: some View {
        switch issue.recovery {
        case .settings:
            settingsButton
        case .retry:
            retryButton
        case .settingsAndRetry:
            HStack(spacing: 10) { settingsButton; retryButton }
        case .manageUsage:
            usageLink
        case .usageAndRetry:
            HStack(spacing: 10) { usageLink; retryButton }
        case .accountAndSettings:
            HStack(spacing: 10) {
                Link(L("查看账号", "Review account"), destination: ChatGPTAccountStore.usageURL)
                settingsButton
            }
            .controlSize(.small)
        case .none:
            EmptyView()
        }
    }

    private var settingsButton: some View {
        Button(L("AI 设置…", "AI Settings…"), action: openSettings).controlSize(.small)
    }

    private var retryButton: some View {
        Button(L("重试", "Retry"), action: retry).controlSize(.small)
    }

    private var usageLink: some View {
        Link(L("管理用量", "Manage usage"), destination: ChatGPTAccountStore.usageURL).controlSize(.small)
    }
}

