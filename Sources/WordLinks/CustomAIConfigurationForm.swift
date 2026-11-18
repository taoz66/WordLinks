import SwiftUI

/// Configures a Chat Completions-compatible endpoint on a remote or local server.
@MainActor
struct CustomAIConfigurationForm: View {
    @StateObject private var draft: AICustomConfigurationDraft
    private let onSaved: () -> Void
    @State private var enteringModel = false
    @State private var manualModelID = ""
    private let onDirtyChanged: (Bool) -> Void
    private let onCancel: (() -> Void)?

    init(settings: AISettingsStore, profile: AICustomProfile?, kind: AIServiceKind = .customAPI,
         requiresActivation: Bool = false,
         onSaved: @escaping () -> Void = {},
         onDirtyChanged: @escaping (Bool) -> Void = { _ in }, onCancel: (() -> Void)? = nil) {
        _draft = StateObject(wrappedValue: AICustomConfigurationDraft(settings: settings, profile: profile,
                                                                    kind: kind,
                                                                    requiresActivation: requiresActivation))
        self.onSaved = onSaved
        self.onDirtyChanged = onDirtyChanged
        self.onCancel = onCancel
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 12) {
                GridRow(alignment: .top) {
                    fieldLabel(L("API 地址", "API address"))
                        .padding(.top, 4)
                    VStack(alignment: .leading, spacing: 5) {
                        TextField("", text: $draft.address, prompt: Text("https://api.example.com/v1"))
                            .autocorrectionDisabled()
                            .accessibilityLabel(L("API 地址", "API address"))
                            .accessibilityIdentifier("ai.custom.address")
                        Text(L("需兼容 Chat Completions 协议", "Requires Chat Completions compatibility"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                GridRow {
                    fieldLabel(L("API 密钥", "API key"))
                    SecureField("", text: Binding(
                        get: { draft.apiKey },
                        set: { value in
                            draft.apiKey = value
                            draft.authentication = value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .none : .apiKey
                        }
                    ), prompt: Text(L("选填，无需认证时留空", "Optional for servers without authentication")))
                    .accessibilityLabel(L("API 密钥", "API key"))
                    .accessibilityIdentifier("ai.custom.key")
                }
                GridRow(alignment: .top) {
                    fieldLabel(L("模型", "Model"))
                        .padding(.top, 4)
                    VStack(alignment: .leading, spacing: 5) {
                        modelPicker
                        if let message = draft.fetchStatusMessage {
                            Text(message)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                                .accessibilityIdentifier("ai.custom.fetchStatus")
                        }
                    }
                }
            }
            .textFieldStyle(.roundedBorder)
            .labelsHidden()
            .disabled(draft.isSaving)

            HStack(spacing: 8) {
                Button { draft.retryValidation() } label: {
                    Text(L("测试", "Test")).frame(minWidth: 32)
                }
                .disabled(draft.isChecking || draft.isSaving)
                .accessibilityIdentifier("ai.custom.test")
                AIServiceTestFeedback(state: draft.testState)
                    .accessibilityIdentifier("ai.custom.status")
                Spacer(minLength: 4)
                if let onCancel {
                    Button(L("取消", "Cancel"), action: onCancel)
                        .keyboardShortcut(.cancelAction)
                }
                Button {
                    if draft.save() { onSaved() }
                } label: {
                    Text(L("保存", "Save")).frame(minWidth: 32)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!draft.canSave)
                .accessibilityIdentifier("ai.custom.save")
            }
            .controlSize(.regular)
            .frame(height: 38)

            if let errorMessage = draft.errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("ai.custom.error")
            }

        }
        .onAppear {
            onDirtyChanged(draft.hasChanges)
        }
        .onChange(of: draft.hasChanges) { _, changed in onDirtyChanged(changed) }
        .onDisappear { draft.cancelPending() }
        .sheet(isPresented: $enteringModel) {
            ManualModelEntry(identifier: $manualModelID) {
                enteringModel = false
            } onCommit: {
                if draft.commitManualModel(manualModelID) { enteringModel = false }
            }
        }
        .transaction { $0.animation = nil }
    }

    private var modelPicker: some View {
        AIModelPicker(models: draft.models, selectedModel: draft.model,
                      isFetching: draft.isFetching, canFetch: draft.canFetchModels,
                      onSelect: { draft.selectModel($0) }, onFetch: { draft.fetchModels() },
                      onManualEntry: {
                          manualModelID = draft.model
                          enteringModel = true
                      })
            .frame(maxWidth: 260, alignment: .leading)
    }

    private func fieldLabel(_ title: String) -> some View {
        Text(title)
            .frame(width: AppLanguageStore.shared.language == .english ? 100 : 68, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }
}

@MainActor
private struct ManualModelEntry: View {
    @Binding var identifier: String
    let onCancel: () -> Void
    let onCommit: () -> Void
    @FocusState private var fieldFocused: Bool

    private var validIdentifier: Bool {
        !identifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            identifier.trimmingCharacters(in: .whitespacesAndNewlines).rangeOfCharacter(from: .newlines) == nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L("输入模型 ID", "Enter model ID")).font(.headline)
            TextField(L("服务商提供的模型 ID", "Model ID from your provider"), text: $identifier)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
                .focused($fieldFocused)
                .onSubmit { if validIdentifier { onCommit() } }
                .accessibilityLabel(L("模型 ID", "Model ID"))
                .accessibilityIdentifier("ai.custom.manualModelID")
            HStack {
                Spacer()
                Button(L("取消", "Cancel"), action: onCancel).keyboardShortcut(.cancelAction)
                Button(L("使用此模型", "Use model"), action: onCommit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!validIdentifier)
            }
        }
        .padding(20)
        .frame(width: 360)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { fieldFocused = true }
    }
}
