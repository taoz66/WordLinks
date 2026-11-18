import AppKit

enum AppIconColor: String, CaseIterable, Identifiable {
    case indigo
    case teal
    case amber
    case slate

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .indigo: return L("靛蓝", "Indigo")
        case .teal: return L("青绿", "Teal")
        case .amber: return L("暖橙", "Amber")
        case .slate: return L("灰蓝", "Slate")
        }
    }

    // Keep palette thumbnails stable while the Dock follows appearance changes.
    var image: NSImage? {
        guard let url = iconURL() else { return nil }
        return NSImage(contentsOf: url)
    }

    func image(for appearance: NSAppearance?) -> NSImage? {
        let isDark = appearance?.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        guard let url = iconURL(isDark: isDark) else { return nil }
        return NSImage(contentsOf: url)
    }

    func iconURL(in applicationBundle: Bundle = .main) -> URL? {
        iconURL(isDark: false, in: applicationBundle)
    }

    func iconURL(isDark: Bool, in applicationBundle: Bundle = .main) -> URL? {
        // Packaged apps keep SwiftPM resources in Contents/Resources. Prefer
        // that copy so moving the app never depends on a developer's .build.
        let installedBundle = applicationBundle.resourceURL.flatMap {
            Bundle(url: $0.appendingPathComponent("ReadingToolDaily_ReadingToolDaily.bundle"))
        }
        let resources = installedBundle ?? Bundle.module
        let name = isDark ? "\(rawValue)-dark" : rawValue
        return resources.url(forResource: name, withExtension: "icns", subdirectory: "AppIcons")
            ?? resources.url(forResource: rawValue, withExtension: "icns", subdirectory: "AppIcons")
    }

    @MainActor
    func apply(appearance: NSAppearance? = nil) {
        guard let app = NSApp else { return }
        if self == .indigo, Self.hasInstalledNativeIcon() {
            // Let Icon Services choose the layered icon's system appearance.
            // Also undo a previous runtime override when switching back to Indigo.
            app.applicationIconImage = nil
            return
        }
        guard let image = image(for: appearance ?? app.effectiveAppearance) else { return }
        app.applicationIconImage = image
    }

    static func hasInstalledNativeIcon(in applicationBundle: Bundle = .main) -> Bool {
        guard applicationBundle.object(forInfoDictionaryKey: "WordlinksNativeLayeredIcon") as? Bool == true,
              let name = applicationBundle.object(forInfoDictionaryKey: "CFBundleIconName") as? String,
              !name.isEmpty,
              let catalog = applicationBundle.resourceURL?.appendingPathComponent("Assets.car") else { return false }
        return FileManager.default.fileExists(atPath: catalog.path)
    }
}
