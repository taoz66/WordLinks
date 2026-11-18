import Foundation
#if WORDLINKS_REQUIRE_APPLE_INTELLIGENCE && !canImport(FoundationModels)
#error("A packaged Wordlinks app requires a Foundation Models SDK and a compatible Swift compiler.")
#endif
#if canImport(FoundationModels)
import FoundationModels
#endif

enum AppleIntelligenceAvailability: Equatable {
    case available
    case unsupportedOS
    case unsupportedBuild
    case deviceNotEligible
    case notEnabled
    case modelNotReady
    case unsupportedLanguage
    case unavailable

    var isAvailable: Bool { self == .available }

    var message: String {
        switch self {
        case .available:
            return L("Apple 智能已就绪", "Apple Intelligence is ready")
        case .unsupportedOS:
            return L("Apple 智能需要 macOS 26 或更新版本。", "Apple Intelligence requires macOS 26 or later.")
        case .unsupportedBuild:
            return L("此应用版本未包含 Apple 智能支持，请使用支持 Apple 智能的构建版本。",
                     "This build doesn’t include Apple Intelligence support. Use a build with Apple Intelligence enabled.")
        case .deviceNotEligible:
            return L("这台 Mac 当前无法使用 Apple 智能，请检查设备与地区支持情况。",
                     "Apple Intelligence isn’t available on this Mac. Check device and region support.")
        case .notEnabled:
            return L("请先在系统设置中启用 Apple 智能。", "Enable Apple Intelligence in System Settings first.")
        case .modelNotReady:
            return L("Apple 智能模型尚未就绪，请等待系统下载完成后重试。",
                     "The Apple Intelligence model isn’t ready. Wait for the system download to finish and try again.")
        case .unsupportedLanguage:
            return L("Apple 智能暂不支持本次请求的语言。", "Apple Intelligence doesn’t support a language in this request.")
        case .unavailable:
            return L("Apple 智能暂不可用，请检查系统设置后重试。", "Apple Intelligence is unavailable. Check System Settings and try again.")
        }
    }
}

enum AppleIntelligenceError: LocalizedError, Equatable {
    case unavailable(AppleIntelligenceAvailability)
    case inputTooLarge
    case invalidSelection
    case emptyResponse
    case refused
    case rateLimited
    case timedOut
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .unavailable(let reason): return reason.message
        case .inputTooLarge:
            return L("内容超出了 Apple 智能的单次处理范围，请缩短选区后重试。",
                     "This content exceeds Apple Intelligence’s context window. Select a shorter passage and try again.")
        case .invalidSelection:
            return L("请重新选择要解释的词句。", "Select the word or phrase again.")
        case .emptyResponse:
            return L("Apple 智能未返回内容，请重试。", "Apple Intelligence returned no content. Please try again.")
        case .refused:
            return L("Apple 智能未能处理这段内容。", "Apple Intelligence couldn’t process this content.")
        case .rateLimited:
            return L("Apple 智能当前繁忙，请稍后重试。", "Apple Intelligence is busy. Try again shortly.")
        case .timedOut:
            return L("Apple 智能响应超时，请重试。", "Apple Intelligence took too long to respond. Please try again.")
        case .invalidResponse:
            return L("无法读取 Apple 智能的完整回复，请重试。", "The complete Apple Intelligence response couldn’t be read. Please try again.")
        }
    }

    static func from(_ error: Error) -> AppleIntelligenceError {
        if let error = error as? AppleIntelligenceError { return error }
        switch error as? AIError {
        case .invalidSelection: return .invalidSelection
        case .inputTooLarge: return .inputTooLarge
        case .emptyResponse: return .emptyResponse
        case .timedOut: return .timedOut
        default: return .invalidResponse
        }
    }
}

@MainActor
protocol AppleIntelligenceServing {
    var availability: AppleIntelligenceAvailability { get }
    func explain(selection: String, context: String, focusedSentence: String?,
                 purpose: AIExplanationPurpose, language: StudyLanguage) async throws -> String
}

/// This boundary makes transport-independent validation and cancellation testable without a model.
@MainActor
protocol AppleLanguageModelRuntime {
    var availability: AppleIntelligenceAvailability { get }
    func respond(instructions: String, prompt: String, language: StudyLanguage) async throws -> String
}

/// Calls Apple's on-device model only; never invokes PCC, ChatGPT, or another provider.
@MainActor
final class AppleIntelligenceClient: AppleIntelligenceServing {
    private let runtime: any AppleLanguageModelRuntime
    private var isResponding = false
    private var waiting: [(id: UUID, continuation: CheckedContinuation<Void, Error>)] = []

    init(runtime: (any AppleLanguageModelRuntime)? = nil) {
        self.runtime = runtime ?? SystemAppleLanguageModelRuntime()
    }

    var availability: AppleIntelligenceAvailability { runtime.availability }

    func explain(selection: String, context: String, focusedSentence: String? = nil,
                 purpose: AIExplanationPurpose = .lookup, language: StudyLanguage) async throws -> String {
        do {
            try Task.checkCancellation()
            guard availability.isAvailable else { throw AppleIntelligenceError.unavailable(availability) }
            let request = try AIExplanationRequest(selection: selection, context: context,
                                                    focusedSentence: focusedSentence, purpose: purpose,
                                                    language: language)
            if purpose == .intensive { return try await explainIntensively(request, language: language) }
            return try await respond(to: request, language: language)
        } catch {
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            throw AppleIntelligenceError.from(error)
        }
    }

    private func respond(to request: AIExplanationRequest, language: StudyLanguage) async throws -> String {
        try await acquire()
        defer { release() }
        try Task.checkCancellation()
        guard availability.isAvailable else { throw AppleIntelligenceError.unavailable(availability) }
        let text = try await runtime.respond(instructions: request.instructions, prompt: request.inputJSON,
                                             language: language)
        try Task.checkCancellation()
        return try request.validatedResponse(text)
    }

    private func explainIntensively(_ request: AIExplanationRequest, language: StudyLanguage) async throws -> String {
        guard let data = request.selectedText.data(using: .utf8),
              let sentences = try? JSONDecoder().decode([SentenceInput].self, from: data),
              !sentences.isEmpty,
              Set(sentences.map(\.id)).count == sentences.count,
              sentences.allSatisfy({ !$0.source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            throw AppleIntelligenceError.invalidSelection
        }
        var results: [SentenceOutput] = []
        for sentence in sentences {
            try Task.checkCancellation()
            // One complete source sentence per fresh session. Never clip the source JSON or word IDs.
            let selection = String(decoding: try JSONEncoder().encode([sentence]), as: UTF8.self)
            let single = try AIExplanationRequest(selection: selection, context: "", purpose: .intensive,
                                                   language: language, compactIntensive: true)
            let text = try await respond(to: single, language: language)
            let decoded = try IntensiveReadingBatchResponse.decode(text)
            guard decoded.sentences.count == 1, let value = decoded.sentences.first,
                  value.id == sentence.id,
                  !value.translation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw AppleIntelligenceError.invalidResponse
            }
            results.append(SentenceOutput(value))
        }
        guard Set(results.map(\.id)) == Set(sentences.map(\.id)), results.count == sentences.count else {
            throw AppleIntelligenceError.invalidResponse
        }
        try Task.checkCancellation()
        return String(decoding: try JSONEncoder().encode(BatchOutput(sentences: results)), as: UTF8.self)
    }

    private func acquire() async throws {
        try Task.checkCancellation()
        guard isResponding else { isResponding = true; return }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                guard !Task.isCancelled else { continuation.resume(throwing: CancellationError()); return }
                waiting.append((id, continuation))
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard let self, let index = self.waiting.firstIndex(where: { $0.id == id }) else { return }
                self.waiting.remove(at: index).continuation.resume(throwing: CancellationError())
            }
        }
    }

    private func release() {
        if waiting.isEmpty { isResponding = false }
        else { waiting.removeFirst().continuation.resume() }
    }

    private struct SentenceInput: Codable {
        struct Word: Codable { let id: Int; let text: String }
        let id: Int
        let source: String
        let words: [Word]
    }

    private struct BatchOutput: Encodable { let sentences: [SentenceOutput] }

    private struct SentenceOutput: Encodable {
        struct Link: Encodable {
            struct Target: Encodable { let text: String; let occurrence: Int }
            let sourceWordIDs: [Int]
            let targetPhrases: [Target]
        }
        let id: Int
        let translation: String
        let links: [Link]

        init(_ value: IntensiveReadingSuggestion) {
            id = value.id
            translation = value.translation
            links = value.links.map { link in
                Link(sourceWordIDs: link.sourceWordIDs,
                     targetPhrases: link.targetPhrases.map { Link.Target(text: $0.text, occurrence: $0.occurrence) })
            }
        }
    }
}

/// A production Apple-enabled build must compile this file with the macOS 26+ SDK.
/// The explicit fallback exists for old SDK development/tests, never as a claim of native support.
@MainActor
private final class SystemAppleLanguageModelRuntime: AppleLanguageModelRuntime {
    var availability: AppleIntelligenceAvailability {
        guard #available(macOS 26.0, *) else { return .unsupportedOS }
        #if canImport(FoundationModels)
        return nativeAvailability
        #else
        return .unsupportedBuild
        #endif
    }

    func respond(instructions: String, prompt: String, language: StudyLanguage) async throws -> String {
        guard #available(macOS 26.0, *) else {
            throw AppleIntelligenceError.unavailable(.unsupportedOS)
        }
        #if canImport(FoundationModels)
        return try await nativeRespond(instructions: instructions, prompt: prompt, language: language)
        #else
        throw AppleIntelligenceError.unavailable(.unsupportedBuild)
        #endif
    }

    #if canImport(FoundationModels)
    @available(macOS 26.0, *)
    private var nativeAvailability: AppleIntelligenceAvailability {
        switch SystemLanguageModel.default.availability {
        case .available: return .available
        case .unavailable(.deviceNotEligible): return .deviceNotEligible
        case .unavailable(.appleIntelligenceNotEnabled): return .notEnabled
        case .unavailable(.modelNotReady): return .modelNotReady
        @unknown default: return .unavailable
        }
    }

    @available(macOS 26.0, *)
    private func nativeRespond(instructions: String, prompt: String, language: StudyLanguage) async throws -> String {
        guard nativeAvailability.isAvailable else { throw AppleIntelligenceError.unavailable(nativeAvailability) }
        let model = SystemLanguageModel.default
        guard model.supportsLocale(Locale(identifier: language.rawValue)) else {
            throw AppleIntelligenceError.unavailable(.unsupportedLanguage)
        }
        let session = LanguageModelSession(model: model) { instructions }
        var options = GenerationOptions()
        options.temperature = 0.2
        // No artificial response-token cap: never accept a deliberately truncated translation.
        // Inputs, outputs and schemas share the model window; oversized requests fail explicitly.
        do {
            let response = try await session.respond(to: prompt, options: options)
            try Task.checkCancellation()
            return response.content
        } catch {
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            if let known = error as? LanguageModelSession.GenerationError {
                switch known {
                case .assetsUnavailable: throw AppleIntelligenceError.unavailable(.modelNotReady)
                case .exceededContextWindowSize: throw AppleIntelligenceError.inputTooLarge
                case .guardrailViolation, .refusal: throw AppleIntelligenceError.refused
                case .rateLimited, .concurrentRequests: throw AppleIntelligenceError.rateLimited
                case .unsupportedLanguageOrLocale: throw AppleIntelligenceError.unavailable(.unsupportedLanguage)
                case .decodingFailure, .unsupportedGuide: throw AppleIntelligenceError.invalidResponse
                @unknown default: throw AppleIntelligenceError.invalidResponse
                }
            }
            throw AppleIntelligenceError.invalidResponse
        }
    }
    #endif
}
