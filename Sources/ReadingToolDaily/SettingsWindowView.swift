import AppKit
import Observation
import SwiftUI

enum SettingsTab: Hashable {
    case appearance
    case ai
}

/// A settings pane reports its natural content height, including its padding and footer.
struct SettingsPaneHeightPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct SettingsPaneViewportHeightPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

@MainActor
@Observable
final class SettingsNavigation {
    static let shared = SettingsNavigation()
    var selection: SettingsTab = .appearance
}

@MainActor
struct SettingsWindowView: View {
    @EnvironmentObject private var aiSettings: AISettingsStore
    @Bindable private var appearance: AppearanceSettingsStore
    @Bindable private var language: AppLanguageStore
    @Bindable private var navigation: SettingsNavigation
    @State private var availableContentSize: NSSize?
    @State private var appearanceContentHeight: CGFloat?
    @State private var appearanceFormOuterInset: CGFloat?
    @State private var aiContentHeight: CGFloat?
    @State private var paneContainerInsets: CGFloat = 24
    private let initialAIKind: AIServiceKind?
    private let appliesAppAppearance: Bool

    init(appearance: AppearanceSettingsStore? = nil,
         language: AppLanguageStore? = nil,
         navigation: SettingsNavigation? = nil,
         initialAIKind: AIServiceKind? = nil,
         appliesAppAppearance: Bool = true) {
        self.appearance = appearance ?? .shared
        self.language = language ?? .shared
        self.navigation = navigation ?? .shared
        self.initialAIKind = initialAIKind
        self.appliesAppAppearance = appliesAppAppearance
    }

    private var paneHeight: CGFloat {
        let height = navigation.selection == .appearance ? appearanceContentHeight : aiContentHeight
        return height.map { $0 + paneContainerInsets } ?? 540
    }

    private var preferredContentSize: NSSize {
        NSSize(width: 600, height: paneHeight)
    }

    private var contentSize: NSSize {
        guard let availableContentSize else { return preferredContentSize }
        return NSSize(width: min(preferredContentSize.width, availableContentSize.width),
                      height: min(preferredContentSize.height, availableContentSize.height))
    }

    private var paneTitle: String {
        navigation.selection == .appearance ? L("外观", "Appearance") : "AI"
    }

    var body: some View {
        // Pair a viewport measurement with the size proposed in the same layout.
        // Reading live @State after another preference updates it can mistake a
        // content-height change for extra TabView chrome and keep growing insets.
        let proposedHeight = contentSize.height
        let isShowingAI = navigation.selection == .ai
        return TabView(selection: $navigation.selection) {
            Form {
                Section {
                    Picker(L("界面语言", "Interface language"), selection: $language.language) {
                        ForEach(InterfaceLanguage.allCases) { option in
                            Text(option.displayName).tag(option)
                        }
                    }
                    .pickerStyle(.radioGroup)
                    .reportAppearanceSettingsBounds("first")
                    Picker(L("明暗模式", "Appearance mode"), selection: $appearance.appearanceMode) {
                        ForEach(AppAppearanceMode.allCases) { option in
                            Text(option.displayName).tag(option)
                        }
                    }
                    iconColorPicker
                }
                Section(L("阅读风格", "Reading style")) {
                    ReadingStylePicker(selection: $appearance.readingStyle)
                        .frame(maxWidth: .infinity)
                    Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 12) {
                        typographySlider(L("字号", "Font size"), keyPath: \.fontSize, range: ReadingTypography.fontSizeRange)
                        typographySlider(L("行距", "Line spacing"), keyPath: \.lineSpacing, range: ReadingTypography.lineSpacingRange)
                        typographySlider(L("段距", "Paragraph gap"), keyPath: \.paragraphSpacing, range: ReadingTypography.paragraphSpacingRange)
                        typographySlider(L("左右边距", "Side margins"), keyPath: \.sideInset, range: ReadingTypography.sideInsetRange)
                    }
                    HStack {
                        Spacer()
                        Button(L("恢复默认", "Reset")) { appearance.resetReadingTypography() }
                            .disabled(appearance.readingTypography == appearance.readingStyle.defaultTypography)
                            .help(L("恢复当前阅读风格的默认排版", "Restore this reading style’s default typography"))
                    }
                    .reportAppearanceSettingsBounds("last")
                }
            }
            .formStyle(.grouped)
            .coordinateSpace(name: "AppearanceSettingsForm")
            .onPreferenceChange(AppearanceSettingsBoundsKey.self) { bounds in
                guard let first = bounds["first"], let last = bounds["last"],
                      first.minY.isFinite, last.maxY.isFinite else { return }
                // A grouped Form fills its viewport. Measure its rows instead so
                // unused viewport space does not become the window's ideal height.
                let inset = appearanceFormOuterInset ?? max(0, first.minY)
                let height = ceil(last.maxY - first.minY + inset * 2)
                Task { @MainActor in
                    if appearanceFormOuterInset == nil { appearanceFormOuterInset = inset }
                    if height > 0, appearanceContentHeight.map({ abs($0 - height) > 1 }) ?? true {
                        appearanceContentHeight = height
                    }
                }
            }
            .background {
                GeometryReader { geometry in
                    Color.clear.preference(key: SettingsPaneViewportHeightPreferenceKey.self,
                                           value: geometry.size.height)
                        .preference(key: AppearanceSettingsBoundsKey.self,
                                    value: ["viewport": CGRect(origin: .zero, size: geometry.size)])
                }
            }
            .onPreferenceChange(SettingsPaneViewportHeightPreferenceKey.self) { height in
                Task { @MainActor in
                    guard !isShowingAI, navigation.selection == .appearance, height.isFinite, height > 0 else { return }
                    let insets = max(24, ceil(proposedHeight - height))
                    if abs(paneContainerInsets - insets) > 1 { paneContainerInsets = insets }
                }
            }
            .tabItem { Label(L("外观", "Appearance"), systemImage: "paintbrush") }
            .tag(SettingsTab.appearance)
            AISettingsContent(settings: aiSettings, initialKind: initialAIKind)
                .background {
                    GeometryReader { geometry in
                        Color.clear.preference(key: SettingsPaneViewportHeightPreferenceKey.self,
                                               value: geometry.size.height)
                    }
                }
                .onPreferenceChange(SettingsPaneHeightPreferenceKey.self) { height in
                    Task { @MainActor in
                        guard height.isFinite, height > 0 else { return }
                        let roundedHeight = ceil(height)
                        if aiContentHeight.map({ abs($0 - roundedHeight) > 1 }) ?? true {
                            aiContentHeight = roundedHeight
                        }
                    }
                }
                .onPreferenceChange(SettingsPaneViewportHeightPreferenceKey.self) { height in
                    Task { @MainActor in
                        guard isShowingAI, navigation.selection == .ai, height.isFinite, height > 0 else { return }
                        // Native TabView chrome can live in the title bar or in the content
                        // depending on macOS. Measure its contribution instead of guessing it.
                        let insets = max(24, ceil(proposedHeight - height))
                        if abs(paneContainerInsets - insets) > 1 { paneContainerInsets = insets }
                    }
                }
                .tabItem { Label("AI", systemImage: "sparkles") }
                .tag(SettingsTab.ai)
        }
        .padding(12)
        .frame(width: contentSize.width, height: contentSize.height, alignment: .top)
        .navigationTitle(paneTitle)
        .background {
            SettingsWindowGeometry(title: paneTitle, contentSize: preferredContentSize) { size in
                if availableContentSize != size { availableContentSize = size }
            }
        }
        .environment(\.locale, language.locale)
        .preferredColorScheme(appearance.colorScheme)
        .onAppear {
            if appliesAppAppearance { appearance.applyAppAppearance() }
        }
    }

    private var iconColorPicker: some View {
        HStack(alignment: .center) {
            Text(L("图标颜色", "Icon color"))
            Spacer(minLength: 16)
            HStack(spacing: 8) {
                ForEach(AppIconColor.allCases) { color in
                    let isSelected = appearance.iconColor == color
                    Button {
                        appearance.iconColor = color
                    } label: {
                        VStack(spacing: 3) {
                            Group {
                                if let image = color.image {
                                    Image(nsImage: image)
                                        .resizable()
                                        .scaledToFit()
                                } else {
                                    Image(systemName: "app")
                                        .resizable()
                                        .scaledToFit()
                                }
                            }
                            .frame(width: 40, height: 40)
                            Text(color.displayName)
                                .font(.caption)
                        }
                        .frame(width: 60, height: 66)
                        .overlay(alignment: .topTrailing) {
                            if isSelected {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.system(size: 12))
                                    .symbolRenderingMode(.palette)
                                    .foregroundStyle(.white, Color.accentColor)
                                    .padding(4)
                            }
                        }
                    }
                    .buttonStyle(ChoiceCardButtonStyle(isSelected: isSelected, cornerRadius: 10))
                    .accessibilityLabel(color.displayName)
                    .accessibilityValue(isSelected ? L("已选择", "Selected") : L("未选择", "Not selected"))
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                    .accessibilityIdentifier("appearance.iconColor.\(color.rawValue)")
                    .help(color.displayName)
                }
            }
        }
    }

    private func typographySlider(_ title: String, keyPath: WritableKeyPath<ReadingTypography, Double>,
                                  range: ClosedRange<Double>) -> some View {
        GridRow {
            Text(title)
                .fixedSize(horizontal: false, vertical: true)
            Slider(value: Binding(
                get: { appearance.readingTypography[keyPath: keyPath] },
                set: { value in
                    var typography = appearance.readingTypography
                    typography[keyPath: keyPath] = value.rounded()
                    appearance.readingTypography = typography
                }
            ), in: range)
            .accessibilityLabel(title)
            .accessibilityValue("\(Int(appearance.readingTypography[keyPath: keyPath])) pt")
            .frame(maxWidth: .infinity)
            Text("\(Int(appearance.readingTypography[keyPath: keyPath])) pt")
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 50, alignment: .trailing)
        }
    }
}

struct AppearanceSettingsBoundsKey: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]

    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, latest in latest })
    }
}

private extension View {
    func reportAppearanceSettingsBounds(_ row: String) -> some View {
        background {
            GeometryReader { geometry in
                Color.clear.preference(key: AppearanceSettingsBoundsKey.self,
                                       value: [row: geometry.frame(in: .named("AppearanceSettingsForm"))])
            }
        }
    }
}

/// The SwiftUI segmented picker keeps its intrinsic width on macOS, even inside
/// an expanding frame. Let AppKit distribute these presets across the form row.
private struct ReadingStylePicker: NSViewRepresentable {
    @Binding var selection: ReadingViewStyle

    func makeCoordinator() -> Coordinator {
        Coordinator(selection: $selection)
    }

    func makeNSView(context: Context) -> NSSegmentedControl {
        let control = NSSegmentedControl(labels: ReadingViewStyle.allCases.map(\.displayName),
                                         trackingMode: .selectOne,
                                         target: context.coordinator,
                                         action: #selector(Coordinator.selectStyle(_:)))
        control.segmentStyle = .automatic
        control.segmentDistribution = .fillEqually
        control.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return control
    }

    func updateNSView(_ control: NSSegmentedControl, context: Context) {
        context.coordinator.selection = $selection
        for (index, option) in ReadingViewStyle.allCases.enumerated() {
            control.setLabel(option.displayName, forSegment: index)
            control.setToolTip(option.displayName, forSegment: index)
        }
        control.selectedSegment = ReadingViewStyle.allCases.firstIndex(of: selection) ?? 0
        control.setAccessibilityLabel(L("阅读视图风格", "Reading view style"))
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSSegmentedControl,
                      context: Context) -> NSSize? {
        let intrinsicSize = nsView.intrinsicContentSize
        return NSSize(width: proposal.width ?? intrinsicSize.width, height: intrinsicSize.height)
    }

    final class Coordinator: NSObject {
        var selection: Binding<ReadingViewStyle>

        init(selection: Binding<ReadingViewStyle>) {
            self.selection = selection
        }

        @objc func selectStyle(_ sender: NSSegmentedControl) {
            let options = ReadingViewStyle.allCases
            guard options.indices.contains(sender.selectedSegment) else { return }
            selection.wrappedValue = options[sender.selectedSegment]
        }
    }
}

/// Keep native Settings chrome in sync while preserving the window's top edge on pane changes.
private struct SettingsWindowGeometry: NSViewRepresentable {
    let title: String
    let contentSize: NSSize
    let availableContentSizeChanged: (NSSize) -> Void

    func makeNSView(context: Context) -> GeometryView {
        let view = GeometryView()
        view.configure(title: title, contentSize: contentSize,
                       availableContentSizeChanged: availableContentSizeChanged)
        return view
    }

    func updateNSView(_ view: GeometryView, context: Context) {
        view.configure(title: title, contentSize: contentSize,
                       availableContentSizeChanged: availableContentSizeChanged)
    }

    final class GeometryView: NSView {
        private var desiredTitle = ""
        private var desiredContentSize = NSSize(width: 600, height: 540)
        private var availableContentSizeChanged: ((NSSize) -> Void)?
        private var titleObservation: NSKeyValueObservation?
        private var updateScheduled = false

        func configure(title: String, contentSize: NSSize,
                       availableContentSizeChanged: @escaping (NSSize) -> Void) {
            desiredTitle = title
            desiredContentSize = contentSize
            self.availableContentSizeChanged = availableContentSizeChanged
            scheduleUpdate()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            titleObservation = nil
            NotificationCenter.default.removeObserver(self, name: NSWindow.didChangeScreenNotification, object: nil)
            NotificationCenter.default.removeObserver(self, name: NSApplication.didChangeScreenParametersNotification, object: nil)
            guard let window else { return }
            titleObservation = window.observe(\.title, options: [.initial]) { [weak self] _, _ in
                Task { @MainActor [weak self] in self?.scheduleUpdate() }
            }
            NotificationCenter.default.addObserver(self, selector: #selector(screenDidChange),
                                                   name: NSWindow.didChangeScreenNotification, object: window)
            NotificationCenter.default.addObserver(self, selector: #selector(screenDidChange),
                                                   name: NSApplication.didChangeScreenParametersNotification, object: nil)
            scheduleUpdate()
        }

        @objc private func screenDidChange(_ notification: Notification) {
            scheduleUpdate()
        }

        private func scheduleUpdate() {
            guard !updateScheduled else { return }
            updateScheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.updateScheduled = false
                self.applyGeometry()
            }
        }

        private func applyGeometry() {
            guard let window else { return }
            if window.title != desiredTitle { window.title = desiredTitle }

            let visibleFrame = (window.screen ?? NSScreen.main)?.visibleFrame
            let availableSize = visibleFrame.map { window.contentRect(forFrameRect: $0).size } ?? desiredContentSize
            availableContentSizeChanged?(availableSize)
            let fittedContentSize = NSSize(width: min(desiredContentSize.width, availableSize.width),
                                          height: min(desiredContentSize.height, availableSize.height))
            let size = window.frameRect(forContentRect: NSRect(origin: .zero, size: fittedContentSize)).size
            let oldFrame = window.frame
            var newFrame = NSRect(x: oldFrame.midX - size.width / 2,
                                  y: oldFrame.maxY - size.height,
                                  width: size.width, height: size.height)
            if let visibleFrame {
                newFrame.origin.x = max(visibleFrame.minX, min(newFrame.minX, visibleFrame.maxX - size.width))
                newFrame.origin.y = max(visibleFrame.minY, min(newFrame.minY, visibleFrame.maxY - size.height))
            }
            guard abs(oldFrame.minX - newFrame.minX) > 0.5 || abs(oldFrame.minY - newFrame.minY) > 0.5 ||
                    abs(oldFrame.width - newFrame.width) > 0.5 || abs(oldFrame.height - newFrame.height) > 0.5 else { return }
            window.setFrame(newFrame, display: true, animate: false)
        }
    }
}
