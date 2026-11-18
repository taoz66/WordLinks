import AppKit
import SwiftUI

@MainActor
struct AISettingsView: View {
    @EnvironmentObject private var settings: AISettingsStore

    var body: some View {
        AISettingsContent(settings: settings)
    }
}

/// Browsing a category never changes the saved service or starts another provider.
struct AISettingsDestination: Equatable {
    let kind: AIServiceKind
    let profileID: UUID?

    init(kind: AIServiceKind, profileID: UUID? = nil) {
        self.kind = kind.settingsKind
        self.profileID = profileID
    }

    init(service: AIServiceSelection, profiles: [AICustomProfile]) {
        switch service {
        case .chatGPT:
            self.init(kind: .chatGPT)
        case .custom(let id):
            self.init(kind: profiles.first(where: { $0.id == id })?.kind ?? .customAPI, profileID: id)
        case .appleIntelligence:
            self.init(kind: .appleIntelligence)
        }
    }

    init(kind: AIServiceKind, service: AIServiceSelection, profiles: [AICustomProfile]) {
        let profile = kind.preferredProfile(in: profiles, selection: service)
        self.init(kind: kind, profileID: profile?.id)
    }
}

@MainActor
struct AISettingsContent: View {
    @ObservedObject var settings: AISettingsStore
    @State private var destination: AISettingsDestination
    @State private var pendingDestination: AISettingsDestination?
    @State private var formIdentity = UUID()
    @State private var hasUnsavedChanges = false
    @State private var showingHelp = false
    @State private var measuredPaneHeight: CGFloat = 0
    @State private var measuredFormHeight: CGFloat = 460
    @State private var formOuterInset: CGFloat?
    @State private var expectedProfilesAfterSave: [AICustomProfile]?

    init(settings: AISettingsStore, initialKind: AIServiceKind? = nil) {
        self.settings = settings
        let saved = AISettingsDestination(service: settings.selectedService, profiles: settings.customProfiles)
        let initial: AISettingsDestination
        if let initialKind, initialKind.settingsKind != saved.kind {
            initial = AISettingsDestination(kind: initialKind, service: settings.selectedService,
                                            profiles: settings.customProfiles)
        } else {
            initial = saved
        }
        _destination = State(initialValue: initial)
    }

    private var selectedProfile: AICustomProfile? {
        settings.customProfiles.first { $0.id == destination.profileID && $0.kind.settingsKind == destination.kind }
    }

    private var activeKind: AIServiceKind? {
        switch settings.selectedService {
        case .chatGPT: return settings.chatGPT.activeClientID == nil ? nil : .chatGPT
        case .custom(let id):
            return settings.customProfiles.first(where: { $0.id == id })?.kind.settingsKind
        case .appleIntelligence: return .appleIntelligence
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    servicePicker
                        .reportAISettingsBounds("services")
                }
                Section {
                    configurationPanel
                        .id(formIdentity)
                        .reportAISettingsBounds("configuration")
                }
                Section {
                    prefillOption
                        .reportAISettingsBounds("prefill")
                }
            }
            .formStyle(.grouped)
            .coordinateSpace(name: "AISettingsForm")
            .onPreferenceChange(AISettingsSectionBoundsKey.self) { bounds in
                guard let first = bounds["services"], let last = bounds["prefill"],
                      first.minY.isFinite, last.maxY.isFinite else { return }
                // Measure the native form's actual section spacing, rather than
                // its viewport. The span remains stable when its content scrolls.
                let inset = formOuterInset ?? max(0, first.minY)
                let height = ceil(last.maxY - first.minY + inset * 2)
                Task { @MainActor in
                    if formOuterInset == nil { formOuterInset = inset }
                    if height > 0, abs(measuredFormHeight - height) > 1 {
                        measuredFormHeight = height
                    }
                }
            }
            .preference(key: AISettingsMeasuredSectionsKey.self, value: ["content": measuredFormHeight])
            footer
                .padding(.horizontal, 20)
                .padding(.bottom, 16)
                .background {
                    GeometryReader { geometry in
                        Color.clear.preference(key: AISettingsMeasuredSectionsKey.self,
                                               value: ["footer": geometry.size.height])
                    }
                }
        }
        .onPreferenceChange(AISettingsMeasuredSectionsKey.self) { heights in
            let height = ceil(heights.values.reduce(0, +))
            Task { @MainActor in
                if height.isFinite, abs(measuredPaneHeight - height) > 1 { measuredPaneHeight = height }
            }
        }
        .preference(key: SettingsPaneHeightPreferenceKey.self, value: measuredPaneHeight)
        .transaction { $0.animation = nil }
        .onChange(of: settings.customProfiles) { previous, profiles in
            if profiles == expectedProfilesAfterSave {
                expectedProfilesAfterSave = nil
                return
            }
            expectedProfilesAfterSave = nil
            let preferred = AISettingsDestination(kind: destination.kind, service: settings.selectedService,
                                                  profiles: profiles)
            if !hasUnsavedChanges, selectedProfile == nil, preferred != destination {
                applyDestination(preferred)
            } else if !hasUnsavedChanges,
                      previous.first(where: { $0.id == destination.profileID }) != selectedProfile {
                formIdentity = UUID()
            }
        }
        .confirmationDialog(L("放弃未保存的修改？", "Discard unsaved changes?"),
                            isPresented: Binding(get: { pendingDestination != nil },
                                                 set: { if !$0 { pendingDestination = nil } })) {
            Button(L("放弃修改", "Discard changes"), role: .destructive) {
                if let next = pendingDestination { applyDestination(next) }
                pendingDestination = nil
            }
            Button(L("继续编辑", "Keep editing"), role: .cancel) { pendingDestination = nil }
        }
    }

    private var servicePicker: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("AI 服务", "AI service")).font(.headline)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    serviceOptions
                }
                .frame(minWidth: 390)
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                    serviceOptions
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(L("选择 AI 服务类型", "Choose an AI service type"))
        }
    }

    private var serviceOptions: some View {
        ForEach(AIServiceKind.settingsCases, id: \.self) { kind in
            AIServiceOptionCard(kind: kind, isViewed: destination.kind == kind,
                                isActive: activeKind == kind) {
                chooseKind(kind)
            }
        }
    }

    private var configurationPanel: some View {
        let identity = formIdentity
        return VStack(alignment: .leading, spacing: 16) {
            switch destination.kind {
            case .chatGPT:
                ChatGPTConfigurationForm(settings: settings, onSaved: didSave,
                                         onDirtyChanged: { if identity == formIdentity { hasUnsavedChanges = $0 } })
            case .customAPI, .localModel:
                CustomAIConfigurationForm(
                    settings: settings, profile: selectedProfile, kind: destination.kind,
                    requiresActivation: selectedProfile.map { settings.selectedService != .custom($0.id) } ?? false,
                    onSaved: didSave,
                    onDirtyChanged: { if identity == formIdentity { hasUnsavedChanges = $0 } }
                )
            case .appleIntelligence:
                AppleIntelligenceConfigurationForm(settings: settings, onSaved: didSave,
                    onDirtyChanged: { if identity == formIdentity { hasUnsavedChanges = $0 } })
            }
        }
        .accessibilityIdentifier("ai.configuration.\(destination.kind.rawValue)")
    }

    private var prefillOption: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(L("AI 预填释义", "Prefill meanings with AI"))
                Text(L("使用当前服务，为新卡片建议释义", "Suggest meanings for new cards using the current service"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            Toggle(L("AI 预填释义", "Prefill meanings with AI"), isOn: Binding(
                get: { settings.aiPrefillEnabled }, set: { settings.setAIPrefillEnabled($0) }
            ))
            .toggleStyle(.switch).labelsHidden()
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if settings.customStorageIssue == .custom(.profileStorage) {
                Text(L("无法读取 AI 配置", "Couldn’t read AI settings"))
                    .font(.caption).foregroundStyle(.red)
                Button(L("重试", "Retry")) { settings.retryCustomStorage() }
                    .controlSize(.small)
            }
            Spacer(minLength: 8)
            Button { showingHelp = true } label: {
                Image(systemName: "questionmark.circle")
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .accessibilityLabel(L("AI 数据使用说明", "About AI data use"))
            .help(L("AI 数据使用说明", "About AI data use"))
            .popover(isPresented: $showingHelp) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(L("AI 数据使用说明", "About AI data use")).font(.headline)
                    Text(L("解释与预填会将选中文字和必要上下文发送给当前服务；开启精读后，会分批处理文章句子。",
                           "Explanations and prefills send selected text and context to the current service. Intensive Reading processes article sentences in batches."))
                }
                .padding(16).frame(width: 340, alignment: .leading)
            }
        }
        .frame(minHeight: 24)
    }

    private func chooseKind(_ kind: AIServiceKind) {
        guard kind != destination.kind else { return }
        requestDestination(AISettingsDestination(kind: kind, service: settings.selectedService,
                                                 profiles: settings.customProfiles))
    }

    private func requestDestination(_ next: AISettingsDestination) {
        guard next != destination else { return }
        if hasUnsavedChanges { pendingDestination = next }
        else { applyDestination(next) }
    }

    private func applyDestination(_ next: AISettingsDestination) {
        hasUnsavedChanges = false
        destination = next
        formIdentity = UUID()
    }

    private func didSave() {
        hasUnsavedChanges = false
        if destination.kind == .customAPI || destination.kind == .localModel {
            expectedProfilesAfterSave = settings.customProfiles
            destination = AISettingsDestination(service: settings.selectedService, profiles: settings.customProfiles)
        }
    }
}

private struct AIServiceOptionCard: View {
    let kind: AIServiceKind
    let isViewed: Bool
    let isActive: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 10) {
                AIServiceLogo(kind: kind)
                    .accessibilityHidden(true)
                Text(kind.displayName)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(2).multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 106)
            .overlay(alignment: .topTrailing) {
                if isActive {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, Color.accentColor)
                        .padding(7)
                        .accessibilityHidden(true)
                }
            }
        }
        .buttonStyle(ChoiceCardButtonStyle(isSelected: isViewed))
        .accessibilityLabel(kind.displayName)
        .accessibilityValue(isActive
            ? (isViewed ? L("正在查看，已启用", "Viewing, active") : L("已启用", "Active"))
            : (isViewed ? L("正在查看，未启用", "Viewing, inactive") : L("未启用", "Inactive")))
        .accessibilityAddTraits(isViewed ? .isSelected : [])
        .accessibilityHint(L("显示服务配置", "Show service configuration"))
        .accessibilityIdentifier("ai.serviceKind.\(kind.rawValue)")
    }
}

private extension AIServiceKind {
    var displayName: String {
        switch self {
        case .chatGPT: return "ChatGPT"
        case .customAPI, .localModel: return L("自定义 API", "Custom API")
        case .appleIntelligence: return L("Apple 智能", "Apple Intelligence")
        }
    }
}

private struct AISettingsMeasuredSectionsKey: PreferenceKey {
    static let defaultValue: [String: CGFloat] = [:]

    static func reduce(value: inout [String: CGFloat], nextValue: () -> [String: CGFloat]) {
        value.merge(nextValue(), uniquingKeysWith: { _, latest in latest })
    }
}

private extension View {
    func reportAISettingsBounds(_ section: String) -> some View {
        background {
            GeometryReader { geometry in
                Color.clear.preference(key: AISettingsSectionBoundsKey.self,
                                       value: [section: geometry.frame(in: .named("AISettingsForm"))])
            }
        }
    }
}

private struct AISettingsSectionBoundsKey: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]

    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, latest in latest })
    }
}
