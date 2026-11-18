import Foundation
import Observation

enum InterfaceLanguage: String, CaseIterable, Identifiable {
    case chinese = "zh-Hans"
    case english = "en"

    var id: String { rawValue }
    var displayName: String { self == .chinese ? "中文" : "English" }
    var studyLanguage: StudyLanguage { self == .chinese ? .chinese : .english }
}

@Observable
final class AppLanguageStore {
    static let shared = AppLanguageStore()
    private let defaults: UserDefaults

    var language: InterfaceLanguage {
        didSet {
            defaults.set(language.rawValue, forKey: "interface.language")
            defaults.set([language.rawValue], forKey: "AppleLanguages")
        }
    }

    var locale: Locale { Locale(identifier: language.rawValue) }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        language = InterfaceLanguage(rawValue: defaults.string(forKey: "interface.language") ?? "") ?? .chinese
        defaults.set([language.rawValue], forKey: "AppleLanguages")
    }
}

/// Observable language reads also refresh SwiftUI views that call this helper.
func L(_ chinese: String, _ english: String) -> String {
    AppLanguageStore.shared.language == .chinese ? chinese : english
}

enum StudyLanguage: String, CaseIterable, Identifiable, Codable {
    case english = "en"
    case chinese = "zh-Hans"
    case japanese = "ja"
    case korean = "ko"
    case french = "fr"
    case german = "de"
    case spanish = "es"
    case italian = "it"
    case portuguese = "pt"
    case russian = "ru"
    case arabic = "ar"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .english: return L("英语", "English")
        case .chinese: return L("中文", "Chinese")
        case .japanese: return L("日语", "Japanese")
        case .korean: return L("韩语", "Korean")
        case .french: return L("法语", "French")
        case .german: return L("德语", "German")
        case .spanish: return L("西班牙语", "Spanish")
        case .italian: return L("意大利语", "Italian")
        case .portuguese: return L("葡萄牙语", "Portuguese")
        case .russian: return L("俄语", "Russian")
        case .arabic: return L("阿拉伯语", "Arabic")
        }
    }

    var promptName: String {
        switch self {
        case .english: return "English"
        case .chinese: return "Simplified Chinese"
        case .japanese: return "Japanese"
        case .korean: return "Korean"
        case .french: return "French"
        case .german: return "German"
        case .spanish: return "Spanish"
        case .italian: return "Italian"
        case .portuguese: return "Portuguese"
        case .russian: return "Russian"
        case .arabic: return "Arabic"
        }
    }
}
