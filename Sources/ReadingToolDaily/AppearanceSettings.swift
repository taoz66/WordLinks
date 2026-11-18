import AppKit
import Observation
import SwiftUI

enum AppAppearanceMode: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system: return L("跟随系统", "Follow system")
        case .light: return L("浅色", "Light")
        case .dark: return L("深色", "Dark")
        }
    }
}

enum ReadingViewStyle: String, CaseIterable, Identifiable {
    case standard
    case book
    case focus
    case magazine

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .standard: return L("标准", "Standard")
        case .book: return L("书页", "Book")
        case .focus: return L("专注", "Focus")
        case .magazine: return L("杂志", "Magazine")
        }
    }

    var defaultTypography: ReadingTypography {
        switch self {
        case .standard:
            return ReadingTypography(fontSize: 17, lineSpacing: 8, paragraphSpacing: 10, sideInset: 30)
        case .book:
            return ReadingTypography(fontSize: 19, lineSpacing: 8, paragraphSpacing: 12, sideInset: 42)
        case .focus:
            return ReadingTypography(fontSize: 18, lineSpacing: 8, paragraphSpacing: 14, sideInset: 56)
        case .magazine:
            return ReadingTypography(fontSize: 18, lineSpacing: 8, paragraphSpacing: 12, sideInset: 36)
        }
    }
}

struct ReadingTypography: Codable, Equatable {
    var fontSize: Double
    var lineSpacing: Double
    var paragraphSpacing: Double
    var sideInset: Double

    static let fontSizeRange: ClosedRange<Double> = 14...28
    static let lineSpacingRange: ClosedRange<Double> = 0...18
    static let paragraphSpacingRange: ClosedRange<Double> = 4...28
    static let sideInsetRange: ClosedRange<Double> = 16...100

    func clamped(fallback: ReadingTypography) -> ReadingTypography {
        func limit(_ value: Double, to range: ClosedRange<Double>, fallback: Double) -> Double {
            value.isFinite ? min(max(value, range.lowerBound), range.upperBound) : fallback
        }
        return ReadingTypography(
            fontSize: limit(fontSize, to: Self.fontSizeRange, fallback: fallback.fontSize),
            lineSpacing: limit(lineSpacing, to: Self.lineSpacingRange, fallback: fallback.lineSpacing),
            paragraphSpacing: limit(paragraphSpacing, to: Self.paragraphSpacingRange, fallback: fallback.paragraphSpacing),
            sideInset: limit(sideInset, to: Self.sideInsetRange, fallback: fallback.sideInset)
        )
    }
}

@MainActor
@Observable
final class AppearanceSettingsStore {
    static let shared = AppearanceSettingsStore()
    private let defaults: UserDefaults
    private var typographyByStyle: [String: ReadingTypography]
    @ObservationIgnored private var iconAppearanceObservation: NSKeyValueObservation?

    var appearanceMode: AppAppearanceMode {
        didSet {
            defaults.set(appearanceMode.rawValue, forKey: "appearance.mode")
            applyAppAppearance()
        }
    }

    var iconColor: AppIconColor {
        didSet {
            defaults.set(iconColor.rawValue, forKey: "appearance.iconColor")
            applyAppIcon()
        }
    }

    var readingStyle: ReadingViewStyle {
        didSet { defaults.set(readingStyle.rawValue, forKey: "appearance.readingStyle") }
    }

    var readingTypography: ReadingTypography {
        get { typographyByStyle[readingStyle.rawValue] ?? readingStyle.defaultTypography }
        set {
            typographyByStyle[readingStyle.rawValue] = newValue.clamped(fallback: readingStyle.defaultTypography)
            saveReadingTypography()
        }
    }

    func resetReadingTypography() {
        typographyByStyle.removeValue(forKey: readingStyle.rawValue)
        saveReadingTypography()
    }

    private func saveReadingTypography() {
        guard let data = try? JSONEncoder().encode(typographyByStyle) else { return }
        defaults.set(data, forKey: "appearance.typographyByStyle")
    }

    var colorScheme: ColorScheme? {
        switch appearanceMode {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let savedTypography = defaults.data(forKey: "appearance.typographyByStyle")
            .flatMap { try? JSONDecoder().decode([String: ReadingTypography].self, from: $0) } ?? [:]
        typographyByStyle = Dictionary(uniqueKeysWithValues: ReadingViewStyle.allCases.compactMap { style in
            savedTypography[style.rawValue].map { (style.rawValue, $0.clamped(fallback: style.defaultTypography)) }
        })
        appearanceMode = defaults.string(forKey: "appearance.mode")
            .flatMap(AppAppearanceMode.init(rawValue:)) ?? .system
        iconColor = defaults.string(forKey: "appearance.iconColor")
            .flatMap(AppIconColor.init(rawValue:)) ?? .indigo
        readingStyle = defaults.string(forKey: "appearance.readingStyle")
            .flatMap(ReadingViewStyle.init(rawValue:)) ?? .standard
    }

    func applyAppIcon() {
        guard let app = NSApp else { return }
        if iconAppearanceObservation == nil {
            iconAppearanceObservation = app.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, _ in
                Task { @MainActor [weak self] in self?.applyAppIcon() }
            }
        }
        iconColor.apply(appearance: app.effectiveAppearance)
    }

    /// Native popovers and panels share the app's appearance with SwiftUI windows.
    func applyAppAppearance() {
        guard let app = NSApp else { return }
        switch appearanceMode {
        case .system: app.appearance = nil
        case .light: app.appearance = NSAppearance(named: .aqua)
        case .dark: app.appearance = NSAppearance(named: .darkAqua)
        }
        applyAppIcon()
    }
}
