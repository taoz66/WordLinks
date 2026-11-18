import Foundation
import XCTest
@testable import WordLinks

@MainActor
final class ReadingAppearanceTests: XCTestCase {
    func testTypographyRemainsIndependentAcrossStylesAndReloads() throws {
        let suite = "ReadingToolDaily-Appearance-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppearanceSettingsStore(defaults: defaults)

        settings.readingStyle = .book
        var book = settings.readingTypography
        book.fontSize += 2
        settings.readingTypography = book
        settings.readingStyle = .magazine
        var magazine = settings.readingTypography
        magazine.sideInset += 8
        settings.readingTypography = magazine

        settings.readingStyle = .book
        XCTAssertEqual(settings.readingTypography, book)
        let reopened = AppearanceSettingsStore(defaults: defaults)
        XCTAssertEqual(reopened.readingStyle, .book)
        XCTAssertEqual(reopened.readingTypography, book)
        reopened.readingStyle = .magazine
        XCTAssertEqual(reopened.readingTypography, magazine)
        reopened.readingStyle = .standard
        XCTAssertEqual(reopened.readingTypography, ReadingViewStyle.standard.defaultTypography)
    }

    func testResetRestoresOnlyTheCurrentStyleAndPersists() throws {
        let suite = "ReadingToolDaily-Appearance-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppearanceSettingsStore(defaults: defaults)
        settings.readingStyle = .standard
        var standard = settings.readingTypography
        standard.paragraphSpacing += 3
        settings.readingTypography = standard
        settings.readingStyle = .focus
        var focus = settings.readingTypography
        focus.lineSpacing += 2
        settings.readingTypography = focus

        settings.resetReadingTypography()

        XCTAssertEqual(settings.readingTypography, ReadingViewStyle.focus.defaultTypography)
        let reopened = AppearanceSettingsStore(defaults: defaults)
        XCTAssertEqual(reopened.readingTypography, ReadingViewStyle.focus.defaultTypography)
        reopened.readingStyle = .standard
        XCTAssertEqual(reopened.readingTypography, standard)
    }

    func testExistingAppearancePreferencesLoadWithoutTypographyData() throws {
        let suite = "ReadingToolDaily-Appearance-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(ReadingViewStyle.book.rawValue, forKey: "appearance.readingStyle")
        defaults.set(AppAppearanceMode.dark.rawValue, forKey: "appearance.mode")

        let settings = AppearanceSettingsStore(defaults: defaults)

        XCTAssertEqual(settings.readingStyle, .book)
        XCTAssertEqual(settings.appearanceMode, .dark)
        XCTAssertEqual(settings.iconColor, .indigo)
        XCTAssertEqual(settings.readingTypography, ReadingViewStyle.book.defaultTypography)
    }

    func testIconColorPersistsAndInvalidPreferenceFallsBackToIndigo() throws {
        let suite = "ReadingToolDaily-Appearance-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        defaults.set("not-a-color", forKey: "appearance.iconColor")
        let settings = AppearanceSettingsStore(defaults: defaults)
        XCTAssertEqual(settings.iconColor, .indigo)

        settings.iconColor = .amber
        let reopened = AppearanceSettingsStore(defaults: defaults)
        XCTAssertEqual(reopened.iconColor, .amber)
    }

    func testReadingTypographyResetDoesNotChangeIconColor() throws {
        let suite = "ReadingToolDaily-Appearance-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppearanceSettingsStore(defaults: defaults)

        settings.readingStyle = .book
        var typography = settings.readingTypography
        typography.fontSize += 2
        settings.readingTypography = typography
        settings.iconColor = .teal
        XCTAssertEqual(settings.readingTypography, typography)
        settings.resetReadingTypography()

        XCTAssertEqual(settings.iconColor, .teal)
        XCTAssertEqual(settings.readingTypography, ReadingViewStyle.book.defaultTypography)
        let reopened = AppearanceSettingsStore(defaults: defaults)
        XCTAssertEqual(reopened.iconColor, .teal)
    }

    func testBundledIconColorsLoadFromAppIconsResources() {
        for color in AppIconColor.allCases {
            guard let image = color.image else {
                XCTFail("Missing bundled icon for \(color.rawValue)")
                continue
            }
            XCTAssertGreaterThan(image.size.width, 0, color.rawValue)
            XCTAssertGreaterThan(image.size.height, 0, color.rawValue)
        }
    }

    func testPackagedIconsTakePrecedenceOverBuildResources() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Wordlinks-Icons-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let applicationURL = root.appendingPathComponent("Wordlinks.app", isDirectory: true)
        let contents = applicationURL.appendingPathComponent("Contents", isDirectory: true)
        let icons = contents.appendingPathComponent(
            "Resources/WordLinks_WordLinks.bundle/AppIcons", isDirectory: true
        )
        try FileManager.default.createDirectory(at: icons, withIntermediateDirectories: true)
        let info: [String: String] = [
            "CFBundleIdentifier": "Wordlinks.IconResourceTests.\(UUID().uuidString)",
            "CFBundleName": "Wordlinks",
            "CFBundlePackageType": "APPL"
        ]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
        for color in AppIconColor.allCases {
            let source = try XCTUnwrap(color.iconURL())
            let packagedIcon = icons.appendingPathComponent("\(color.rawValue).icns")
            try FileManager.default.copyItem(at: source, to: packagedIcon)
        }
        let application = try XCTUnwrap(Bundle(url: applicationURL))

        for color in AppIconColor.allCases {
            let packagedIcon = icons.appendingPathComponent("\(color.rawValue).icns")
            let resolved = try XCTUnwrap(color.iconURL(in: application))
            XCTAssertEqual(resolved.standardizedFileURL, packagedIcon.standardizedFileURL,
                           "\(color.rawValue) must load from the portable app bundle")
        }
    }
}
