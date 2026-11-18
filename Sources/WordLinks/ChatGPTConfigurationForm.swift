import SwiftUI

@MainActor
struct ChatGPTConfigurationForm: View {
    @ObservedObject private var connection: ChatGPTAccountStore
    @StateObject private var draft: ChatGPTConfigurationDraft
    private let onSaved: () -> Void
    private let onDirtyChanged: (Bool) -> Void

    init(settings: AISettingsStore, onSaved: @escaping () -> Void,
         onDirtyChanged: @escaping (Bool) -> Void = { _ in }) {
        _connection = ObservedObject(wrappedValue: settings.chatGPT)
        _draft = StateObject(wrappedValue: ChatGPTConfigurationDraft(settings: settings))
        self.onSaved = onSaved
        self.onDirtyChanged = onDirtyChanged
    }

    var body: some View {
        Group {
            if connection.configurationClientID == nil {
                signInCard
            } else {
                accountConfiguration
            }
        }
        .onAppear { draft.activate(); onDirtyChanged(draft.hasUnsavedChanges) }
        .onDisappear { draft.deactivate(); onDirtyChanged(false) }
        .onChange(of: draft.hasUnsavedChanges) { _, dirty in onDirtyChanged(dirty) }
        .onChange(of: draft.phase) { _, phase in
            if phase == .saved, draft.testState == .available { onSaved() }
        }
        .onChange(of: connection.showPlanWelcome) { _, show in
            if show { connection.showPlanWelcome = false }
        }
    }

    private var signInCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 14) {
                AIServiceLogo(kind: .chatGPT).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text("ChatGPT").font(.headline)
                    Text(L("需符合条件的 ChatGPT 订阅。", "Requires an eligible ChatGPT subscription."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                Button(L("连接 OpenAI 账号", "Connect OpenAI account")) { draft.beginSignIn() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .fixedSize()
                    .disabled(draft.isBusy)
                    .accessibilityIdentifier("ai.chatgpt.signIn")
            }
            .padding(.vertical, 6)
            if draft.phase == .signingIn || draft.phase == .signingOut {
                HStack(spacing: 8) {
                    AIServiceTestFeedback(state: .testing)
                    Text(draft.phase == .signingIn
                         ? L("请在浏览器中完成登录与授权…", "Finish signing in in your browser…")
                         : L("正在退出登录…", "Signing out…"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 4)
                    if draft.phase == .signingIn {
                        Button(L("取消", "Cancel")) { draft.cancel() }
                            .accessibilityIdentifier("ai.chatgpt.cancelSignIn")
                    }
                }
                .controlSize(.regular)
                .frame(minHeight: 32)
            } else if let issue = draft.issue {
                Text(issue.localizedDescription)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("ai.chatgpt.error")
            }
        }
    }

    private var accountConfiguration: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("ChatGPT").font(.headline)
            HStack(spacing: 12) {
                Text(L("账号", "Account"))
                    .foregroundStyle(.secondary)
                    .frame(width: AppLanguageStore.shared.language == .english ? 100 : 68, alignment: .leading)
                Text(connection.configurationEmail ?? L("已登录", "Signed in"))
                    .lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 8)
                Button(L("退出登录", "Sign out")) {
                    draft.accountWillChange()
                    connection.signOutConfiguration()
                }
                .disabled(draft.isBusy)
                .accessibilityIdentifier("ai.chatgpt.signOut")
            }
            .frame(minHeight: 28)
            Divider()
            testRow
            if let issue = draft.issue, draft.phase != .signingIn, draft.phase != .signingOut {
                Text(issue.localizedDescription)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("ai.chatgpt.error")
            }
        }
    }

    private var needsReconnect: Bool {
        connection.configurationNeedsAuthorization || connection.configurationNeedsReauthentication ||
            draft.issue?.recovery == .signIn || draft.issue?.recovery == .authorize
    }

    private var testRow: some View {
        HStack(spacing: 8) {
            Button(L("测试", "Test")) { draft.test() }
                .disabled(draft.isBusy)
                .accessibilityIdentifier("ai.chatgpt.test")
            if draft.phase == .signingIn || draft.phase == .signingOut {
                AIServiceTestFeedback(state: .testing)
            } else {
                AIServiceTestFeedback(state: draft.testState)
                    .accessibilityIdentifier("ai.chatgpt.validationStatus")
            }
            Spacer(minLength: 4)
            if draft.phase == .signingIn {
                Button(L("取消", "Cancel")) { draft.cancel() }
                    .accessibilityIdentifier("ai.chatgpt.cancelSignIn")
            } else if needsReconnect {
                Button(connection.configurationNeedsAuthorization || draft.issue == .missingPlanPermission
                       ? L("重新授权", "Authorize")
                       : L("重新登录", "Sign in again")) {
                    draft.beginSignIn()
                }
                .disabled(draft.isBusy)
                .accessibilityIdentifier("ai.chatgpt.reconnect")
            }
        }
        .controlSize(.regular)
        .frame(height: 40)
    }
}
