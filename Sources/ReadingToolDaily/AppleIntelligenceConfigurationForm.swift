import AppKit
import SwiftUI

@MainActor
struct AppleIntelligenceConfigurationForm: View {
    @StateObject private var draft: AppleIntelligenceConfigurationDraft
    @ObservedObject private var settings: AISettingsStore
    @Environment(\.scenePhase) private var scenePhase
    let onSaved: () -> Void
    let onDirtyChanged: (Bool) -> Void

    init(settings: AISettingsStore, onSaved: @escaping () -> Void,
         onDirtyChanged: @escaping (Bool) -> Void = { _ in }) {
        self.settings = settings
        _draft = StateObject(wrappedValue: AppleIntelligenceConfigurationDraft(settings: settings))
        self.onSaved = onSaved
        self.onDirtyChanged = onDirtyChanged
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(L("Apple 智能", "Apple Intelligence"))
                    .font(.headline)
                Text(L("使用本机端侧模型，无需账号或 API 密钥。",
                       "Uses the on-device model. No account or API key required."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                Button(L("测试", "Test")) { draft.check() }
                    .disabled(draft.isChecking)
                    .accessibilityIdentifier("ai.apple.check")
                AIServiceTestFeedback(state: draft.testState)
                    .accessibilityIdentifier("ai.apple.validationStatus")
                Spacer(minLength: 4)
                Button(L("保存", "Save")) {
                    if draft.save() { onSaved() }
                }
                .disabled(!draft.canSave)
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("ai.apple.save")
            }
            .controlSize(.regular)
            .frame(minHeight: 40)
            if let issue = draft.issue {
                Text(issue.localizedDescription)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("ai.apple.error")
            } else if draft.availability != .available {
                Text(draft.availability.message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("ai.apple.availability")
            }
        }
        .onAppear { draft.refreshAvailability(); onDirtyChanged(draft.hasUnsavedChanges) }
        .onDisappear { draft.cancelPending(); onDirtyChanged(false) }
        .onChange(of: draft.hasUnsavedChanges) { _, dirty in onDirtyChanged(dirty) }
        .onChange(of: settings.configurationRevision) { _, _ in draft.refreshAvailability() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { draft.refreshAvailability() }
        }
        .onChange(of: AppLanguageStore.shared.language) { _, _ in
            draft.cancelPending()
            draft.refreshAvailability()
        }
    }

}
