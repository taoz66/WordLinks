import AppKit
import SwiftUI
import XCTest
@testable import ReadingToolDaily

/// Exercise the real native Form layout. These tests use disposable preferences
/// and memory-only credentials; no model, network, browser or Keychain is used.
@MainActor
final class LiquidGlassSettingsLayoutTests: XCTestCase {
    func testAppearanceWindowFitsItsRowsAndKeepsItsHeightAcrossTabChanges() async throws {
        try requireWindowServer()
        let fixture = try makeFixture()
        let navigation = SettingsNavigation()
        var appearanceBounds: [String: CGRect] = [:]
        let host = NSHostingView(rootView: SettingsWindowView(
            appearance: AppearanceSettingsStore(defaults: fixture.defaults),
            language: fixture.language, navigation: navigation, appliesAppAppearance: false
        ).environmentObject(fixture.settings)
            .onPreferenceChange(AppearanceSettingsBoundsKey.self) { appearanceBounds = $0 })
        let window = makeWindow(host: host, size: NSSize(width: 600, height: 700), dark: false)
        defer { close(window) }
        await settle(window)
        try snapshot(host, name: "settings-appearance-fitted-light")
        let fittedHeight = window.contentRect(forFrameRect: window.frame).height
        XCTAssertEqual(window.contentRect(forFrameRect: window.frame).width, 600, accuracy: 1)
        try assertReadingStyleSegmentsFit(in: host)
        XCTAssertLessThan(fittedHeight, 600, "Appearance must fit its controls instead of retaining a fixed tall viewport")
        // Grouped Form buttons can be virtual SwiftUI elements. Use the same
        // actual row geometry that sizes the window, in the Form's coordinates.
        let first = try XCTUnwrap(appearanceBounds["first"])
        let last = try XCTUnwrap(appearanceBounds["last"])
        let viewport = try XCTUnwrap(appearanceBounds["viewport"])
        XCTAssertGreaterThan(first.width, 0)
        XCTAssertGreaterThan(first.height, 0)
        XCTAssertGreaterThan(last.width, 0)
        XCTAssertGreaterThan(last.height, 0)
        print("Appearance Form geometry: first=\(first), last=\(last), viewport=\(viewport)")
        // Grouped Form aligns Picker labels outside the row's proposed width.
        // The fitting contract concerns the vertical extent of these rows.
        for row in [first, last] {
            XCTAssertGreaterThanOrEqual(row.minY, viewport.minY - 1,
                                        "Appearance rows must remain below the top of the Form viewport")
            XCTAssertLessThanOrEqual(row.maxY, viewport.maxY + 1,
                                     "Appearance rows must remain above the bottom of the Form viewport")
        }
        for _ in 0..<2 {
            navigation.selection = .ai
            await settle(window)
            navigation.selection = .appearance
            await settle(window)
            XCTAssertEqual(window.contentRect(forFrameRect: window.frame).height, fittedHeight, accuracy: 3,
                           "Switching panes must not accumulate form or TabView insets")
        }
        XCTAssertEqual(fixture.network.requests, 0)
    }

    func testEnglishAppearanceSegmentsFitTheCompactWindowInBothAppearances() async throws {
        try requireWindowServer()
        guard Bundle.main.bundleIdentifier != "com.readingtool.daily" else {
            throw XCTSkip("Layout verification requires its disposable test process")
        }
        let originalLanguage = AppLanguageStore.shared.language
        AppLanguageStore.shared.language = .english
        defer { AppLanguageStore.shared.language = originalLanguage }
        for dark in [false, true] {
            let fixture = try makeFixture()
            fixture.defaults.set(dark ? AppAppearanceMode.dark.rawValue : AppAppearanceMode.light.rawValue,
                                 forKey: "appearance.mode")
            let navigation = SettingsNavigation()
            let host = NSHostingView(rootView: SettingsWindowView(
                appearance: AppearanceSettingsStore(defaults: fixture.defaults),
                language: fixture.language, navigation: navigation, appliesAppAppearance: false
            ).environmentObject(fixture.settings))
            let window = makeWindow(host: host, size: NSSize(width: 600, height: 700), dark: dark)
            defer { close(window) }
            await settle(window)
            XCTAssertEqual(window.contentRect(forFrameRect: window.frame).width, 600, accuracy: 1)
            try assertReadingStyleSegmentsFit(in: host)
            try snapshot(host, name: "settings-appearance-compact-english-" + (dark ? "dark" : "light"))
            XCTAssertEqual(fixture.network.requests, 0)
        }
    }

    private func assertReadingStyleSegmentsFit(in host: NSView,
                                               file: StaticString = #filePath, line: UInt = #line) throws {
        let control = try XCTUnwrap(descendants(NSSegmentedControl.self, in: host).first,
                                   "Reading styles must use a native segmented control", file: file, line: line)
        XCTAssertEqual(control.segmentCount, 4, file: file, line: line)
        XCTAssertEqual(control.segmentStyle, .automatic, file: file, line: line)
        XCTAssertEqual(control.segmentDistribution, .fillEqually, file: file, line: line)
        let font = control.font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize)
        let segmentWidth = control.bounds.width / CGFloat(control.segmentCount)
        for index in 0..<control.segmentCount {
            let label = control.label(forSegment: index) ?? ""
            let textWidth = (label as NSString).size(withAttributes: [.font: font]).width
            XCTAssertGreaterThanOrEqual(segmentWidth, textWidth + 16,
                                        "Each reading-style segment must fit its complete label", file: file, line: line)
        }
    }

    func testAIServiceChangesResizeSettingsWithoutGrowingInsets() async throws {
        try requireWindowServer()
        let fixture = try makeFixture()
        let navigation = SettingsNavigation()
        navigation.selection = .ai
        let appearance = AppearanceSettingsStore(defaults: fixture.defaults)
        let root = { (kind: AIServiceKind) in
            SettingsWindowView(appearance: appearance, language: fixture.language,
                navigation: navigation, initialAIKind: kind, appliesAppAppearance: false)
                .id(kind)
                .environmentObject(fixture.settings)
        }
        let host = NSHostingView(rootView: root(.customAPI))
        let window = makeWindow(host: host, size: NSSize(width: 600, height: 700), dark: false)
        defer { close(window) }

        await settle(window)
        try snapshot(host, name: "settings-custom-light")
        try assertFooterVisible(in: host, window: window)
        assertSingleModelControl(in: host)
        let tallHeight = window.frame.height

        for iteration in 0..<2 {
            host.rootView = root(.chatGPT)
            await settle(window)
            XCTAssertTrue(descendants(NSSecureTextField.self, in: host).isEmpty)
            try assertFooterVisible(in: host, window: window)
            XCTAssertLessThan(window.frame.height, tallHeight,
                              "The sign-in card must shrink the window to its shorter content")
            let shortHeight = window.frame.height
            try snapshot(host, name: "settings-chatgpt-light-\(iteration)")

            host.rootView = root(.customAPI)
            await settle(window)
            XCTAssertFalse(descendants(NSSecureTextField.self, in: host).isEmpty)
            XCTAssertEqual(window.frame.height, tallHeight, accuracy: 3,
                           "Repeated content changes must not accumulate toolbar or form insets")
            assertSingleModelControl(in: host)
            host.rootView = root(.chatGPT)
            await settle(window)
            XCTAssertEqual(window.frame.height, shortHeight, accuracy: 3)
            try assertFooterVisible(in: host, window: window)
            host.rootView = root(.customAPI)
            await settle(window)
        }

        XCTAssertEqual(fixture.settings.selectedService, .custom(fixture.profileID))
        host.rootView = root(.appleIntelligence)
        await settle(window)
        try assertFooterVisible(in: host, window: window)
        try snapshot(host, name: "settings-apple-light")
        XCTAssertEqual(fixture.network.requests, 0)
    }

    private func assertSingleModelControl(in host: NSView,
                                          file: StaticString = #filePath, line: UInt = #line) {
        let fields = descendants(NSTextField.self, in: host).filter { $0.isEditable }
        XCTAssertEqual(fields.count, 2, "Only the API address and secure key may be permanent text fields",
                       file: file, line: line)
        let buttons = descendants(NSButton.self, in: host)
        XCTAssertFalse(buttons.contains {
            ["获取模型", "获取模型列表", "Fetch models", "Fetch model list", "手动输入模型 ID…", "Enter model ID…"].contains($0.title)
        }, "Fetch and manual entry actions belong inside the model menu", file: file, line: line)
        let modelMenus = descendants(NSPopUpButton.self, in: host).filter {
            $0.title == "synthetic-layout-model" || $0.accessibilityIdentifier() == "ai.custom.model"
        }
        XCTAssertEqual(modelMenus.count, 1, "The form must expose one model selection menu", file: file, line: line)
        guard let model = modelMenus.first, let address = fields.first(where: { !($0 is NSSecureTextField) }),
              let modelContainer = model.superview, let addressContainer = address.superview else { return }
        // AppKit controls extend their frames beyond the geometry used for
        // alignment to accommodate native bezels, shadows and focus treatment.
        let modelFrame = modelContainer.convert(model.alignmentRect(forFrame: model.frame), to: host)
        let addressFrame = addressContainer.convert(address.alignmentRect(forFrame: address.frame), to: host)
        print("API control alignment: model=\(modelFrame), address=\(addressFrame), modelInsets=\(model.alignmentRectInsets), addressInsets=\(address.alignmentRectInsets)")
        XCTAssertEqual(model.alignment, .left, "The model title must remain left-aligned", file: file, line: line)
        XCTAssertEqual(modelFrame.minX, addressFrame.minX, accuracy: 3,
                       "Model selection and API input fields must share their leading edge", file: file, line: line)
        XCTAssertLessThanOrEqual(modelFrame.width, 264,
                                "The model selector must stay compact in the input column", file: file, line: line)
        XCTAssertLessThanOrEqual(modelFrame.width, addressFrame.width + 4,
                                "The model selector must shrink with a narrow input column", file: file, line: line)
    }

    func testCompactSettingsKeepNativeFieldsAndFooterInsideViewport() async throws {
        try requireWindowServer()
        let fixture = try makeFixture()
        let host = NSHostingView(rootView: AISettingsContent(settings: fixture.settings, initialKind: .customAPI)
            .preferredColorScheme(.dark))
        let window = makeWindow(host: host, size: NSSize(width: 600, height: 420), dark: true)
        defer { close(window) }

        for width in [CGFloat(600), 440, 600] {
            window.setContentSize(NSSize(width: width, height: 420))
            await settle(window)
            try snapshot(host, name: "settings-compact-dark-\(Int(width))")
            try assertFooterVisible(in: host, window: window)
            assertSingleModelControl(in: host)
            let viewport = window.convertToScreen(host.convert(host.bounds, to: nil))
            for field in descendants(NSTextField.self, in: host) {
                guard field.isEditable else { continue }
                let frame = window.convertToScreen(field.convert(field.bounds, to: nil))
                XCTAssertGreaterThan(frame.width, 0)
                XCTAssertGreaterThanOrEqual(frame.minX, viewport.minX - 1)
                XCTAssertLessThanOrEqual(frame.maxX, viewport.maxX + 1,
                                         "The native Form must reflow input fields without horizontal clipping")
            }
            let scroll = try XCTUnwrap(descendant(NSScrollView.self, in: host))
            let document = try XCTUnwrap(scroll.documentView)
            XCTAssertLessThanOrEqual(document.frame.width, scroll.contentView.bounds.width + 1,
                                     "A narrow native Form must not leave a wider, horizontally clipped document")
            try snapshot(host, name: "settings-compact-dark-\(Int(width))")
        }
        XCTAssertEqual(fixture.network.requests, 0)
    }

    private func makeFixture() throws -> LayoutFixture {
        let suite = "LiquidGlassSettingsLayoutTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        defaults.set(InterfaceLanguage.english.rawValue, forKey: "interface.language")
        defaults.set(AppAppearanceMode.light.rawValue, forKey: "appearance.mode")
        let language = AppLanguageStore(defaults: defaults)
        let network = LayoutNetwork()
        let chatGPT = ChatGPTAccountStore(defaults: defaults, credentials: LayoutChatGPTCredentials(),
                                          auth: network, client: network,
                                          now: { Date(timeIntervalSince1970: 1_800_000_000) })
        let settings = AISettingsStore(defaults: defaults, credentials: LayoutLegacyCredentials(),
                                       language: language, customCredentials: LayoutProfileCredentials(),
                                       customClient: network, chatGPT: chatGPT, appleIntelligence: network)
        let profileID = try settings.saveCustomProfile(name: "Synthetic layout service",
            baseURL: "https://layout.example.invalid/v1", apiKey: "synthetic-layout-key",
            model: "synthetic-layout-model", kind: .customAPI, authentication: .apiKey)
        return LayoutFixture(defaults: defaults, language: language, settings: settings,
                             network: network, profileID: profileID)
    }

    private func requireWindowServer() throws {
        _ = NSApplication.shared
        if NSScreen.screens.isEmpty { throw XCTSkip("Native settings layout requires a WindowServer session") }
    }

    private func makeWindow<Content: View>(host: NSHostingView<Content>, size: NSSize, dark: Bool) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: 80, y: 80), size: size),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "Wordlinks disposable settings layout check"
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = host
        window.orderBack(nil)
        return window
    }

    private func close(_ window: NSWindow) {
        window.orderOut(nil)
        window.contentView = nil
        window.close()
    }

    private func settle(_ window: NSWindow) async {
        // Yield to AppKit layout and SwiftUI preference tasks; fixed test-size
        // assertions are made only after the actual window geometry stabilizes.
        var previous = NSRect.zero
        var stablePasses = 0
        for _ in 0..<80 {
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            try? await Task.sleep(nanoseconds: 20_000_000)
            if window.frame == previous { stablePasses += 1 } else { stablePasses = 0 }
            previous = window.frame
            if stablePasses >= 8 { return }
        }
    }

    private func assertFooterVisible(in host: NSView, window: NSWindow,
                                     file: StaticString = #filePath, line: UInt = #line) throws {
        // Native Form owns the scrolling controls; its only external native
        // button is the persistent footer. This avoids requiring a global
        // accessibility client to activate SwiftUI's virtual accessibility tree.
        let buttons = descendants(NSButton.self, in: host).filter {
            $0.enclosingScrollView == nil && !$0.isHiddenOrHasHiddenAncestor
        }
        let help = try XCTUnwrap(buttons.last, "The settings footer must remain reachable", file: file, line: line)
        let frame = window.convertToScreen(help.convert(help.bounds, to: nil))
        let viewport = window.convertToScreen(host.convert(host.bounds, to: nil))
        XCTAssertGreaterThan(frame.width, 0, file: file, line: line)
        XCTAssertGreaterThan(frame.height, 0, file: file, line: line)
        XCTAssertTrue(viewport.insetBy(dx: -1, dy: -1).contains(frame),
                      "The footer must stay visible outside the Form's scrolling viewport", file: file, line: line)
    }

    private func descendants<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
        var result = (view as? T).map { [$0] } ?? []
        for child in view.subviews { result += descendants(type, in: child) }
        return result
    }

    private func descendant<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
        if let result = view as? T { return result }
        return view.subviews.lazy.compactMap { self.descendant(type, in: $0) }.first
    }

    private func snapshot(_ host: NSView, name: String) throws {
        guard let directory = ProcessInfo.processInfo.environment["WORDLINKS_UI_INSPECTION_DIR"],
              !directory.isEmpty else { return }
        let output = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: output.appendingPathComponent(name + ".png"), options: .atomic)
    }
}

@MainActor
private struct LayoutFixture {
    let defaults: UserDefaults
    let language: AppLanguageStore
    let settings: AISettingsStore
    let network: LayoutNetwork
    let profileID: UUID
}

private struct LayoutLegacyCredentials: AICredentialStorage {
    func read() throws -> String? { nil }
    func write(_ value: String) throws { }
}

private struct LayoutChatGPTCredentials: ChatGPTCredentialStorage {
    func read() throws -> Data? { nil }
    func write(_ data: Data?) throws { }
}

private final class LayoutProfileCredentials: AICustomCredentialStorage {
    private var values: [UUID: String] = [:]
    func read(profileID: UUID) throws -> String? { values[profileID] }
    func write(_ value: String?, profileID: UUID) throws { values[profileID] = value }
}

private enum LayoutUnexpectedRequest: Error { case network }

@MainActor
private final class LayoutNetwork: AICustomServing, ChatGPTServing, ChatGPTAuthenticating, AppleIntelligenceServing {
    private(set) var requests = 0
    let availability: AppleIntelligenceAvailability = .deviceNotEligible

    private func unexpected<T>() throws -> T {
        requests += 1
        throw LayoutUnexpectedRequest.network
    }

    func fetchModels(baseURL: String, apiKey: String) async throws -> [String] { try unexpected() }
    func fetchModel(accessToken: String) async throws -> String { try unexpected() }
    func explain(selection: String, context: String, focusedSentence: String?, purpose: AIExplanationPurpose,
                 configuration: AIConfiguration) async throws -> String { try unexpected() }
    func explain(selection: String, context: String, focusedSentence: String?, purpose: AIExplanationPurpose,
                 language: StudyLanguage, accessToken: String, model: String) async throws -> String { try unexpected() }
    func explain(selection: String, context: String, focusedSentence: String?, purpose: AIExplanationPurpose,
                 language: StudyLanguage) async throws -> String { try unexpected() }
    func signIn(hostID: String, previous: ChatGPTRegistration?, idTokenHint: String?,
                requestConsent: Bool) async throws -> ChatGPTSession { try unexpected() }
    func refresh(_ session: ChatGPTSession) async throws -> ChatGPTSession { try unexpected() }
    func revoke(_ session: ChatGPTSession) async throws { let _: Void = try unexpected() }
}
