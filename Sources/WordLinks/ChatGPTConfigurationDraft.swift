import Combine
import Foundation

struct ChatGPTConfigurationSnapshot: Equatable {
    var accountID: String?
    var signingIn = false
    var signingOut = false
    var needsAuthorization = false
    var needsReauthentication = false
    var issue: ChatGPTError?

    var isReady: Bool {
        accountID != nil && !signingIn && !signingOut && !needsAuthorization && !needsReauthentication
    }
}

@MainActor
protocol ChatGPTConfigurationAccount: AnyObject {
    var configurationSnapshot: ChatGPTConfigurationSnapshot { get }
    var configurationChanges: AnyPublisher<Void, Never> { get }
    func beginConfiguration()
    func endConfiguration()
    func validateConfiguration() async throws
    func signInConfiguration(otherAccount: Bool)
    func cancelConfigurationSignIn()
    func dismissConfigurationIssue()
    func commitConfigurationCandidate() throws
}

extension ChatGPTAccountStore: ChatGPTConfigurationAccount {
    var configurationSnapshot: ChatGPTConfigurationSnapshot {
        ChatGPTConfigurationSnapshot(accountID: configurationClientID, signingIn: isConfigurationSigningIn,
                                     signingOut: isSigningOut, needsAuthorization: configurationNeedsAuthorization,
                                     needsReauthentication: configurationNeedsReauthentication, issue: configurationIssue)
    }

    var configurationChanges: AnyPublisher<Void, Never> { objectWillChange.eraseToAnyPublisher() }

    func validateConfiguration() async throws {
        try await validateConfigurationCandidate()
    }
}

/// Signing in obtains an identity; only a successful inference allows activating the service.
@MainActor
final class ChatGPTConfigurationDraft: ObservableObject {
    enum Phase: Equatable {
        case idle, signedOut, signingIn, signingOut, checking, verified, saving, saved, cancelled
        case failed(ChatGPTError)
        case saveFailed
    }

    @Published private(set) var phase: Phase
    @Published private(set) var testState: AIServiceTestState = .idle
    private let account: any ChatGPTConfigurationAccount
    private let persistSelection: () throws -> Void
    private let validationTimeoutNanoseconds: UInt64
    private var observation: AnyCancellable?
    private var lastSnapshot: ChatGPTConfigurationSnapshot
    private var verifiedAccountID: String?
    private var savedAccountID: String?
    private var selectionIsSaved: Bool
    private var visible = false
    private var task: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?
    private var taskID: UUID?
    private var testAfterSignIn = false

    convenience init(settings: AISettingsStore) {
        self.init(account: settings.chatGPT, selectionIsSaved: settings.selectedService == .chatGPT) {
            try settings.selectService(.chatGPT)
        }
    }

    init(account: any ChatGPTConfigurationAccount, selectionIsSaved: Bool,
         validationTimeoutNanoseconds: UInt64 = 20_000_000_000,
         persistSelection: @escaping () throws -> Void) {
        self.account = account
        self.persistSelection = persistSelection
        self.validationTimeoutNanoseconds = validationTimeoutNanoseconds
        self.selectionIsSaved = selectionIsSaved
        account.beginConfiguration()
        let snapshot = account.configurationSnapshot
        lastSnapshot = snapshot
        let saved = selectionIsSaved && snapshot.isReady && snapshot.issue == nil
        savedAccountID = saved ? snapshot.accountID : nil
        phase = saved ? .saved : .idle
        observation = account.configurationChanges.sink { [weak self] in
            // ObservableObject publishes before its properties are committed.
            Task { @MainActor [weak self] in self?.synchronize() }
        }
    }

    var canSave: Bool {
        guard let verifiedAccountID, verifiedAccountID == account.configurationSnapshot.accountID,
              account.configurationSnapshot.isReady, account.configurationSnapshot.issue == nil else { return false }
        return phase == .verified || phase == .saveFailed
    }

    var isBusy: Bool {
        switch phase { case .checking, .signingIn, .signingOut, .saving: return true; default: return false }
    }

    var hasUnsavedChanges: Bool {
        switch phase {
        case .verified, .saveFailed, .checking, .signingIn: return true
        default: return false
        }
    }

    var issue: ChatGPTError? {
        if case .failed(let issue) = phase { return issue }
        return nil
    }

    func activate() {
        account.beginConfiguration()
        let snapshot = account.configurationSnapshot
        if !visible, selectionIsSaved, snapshot.isReady, snapshot.issue == nil {
            savedAccountID = snapshot.accountID
            phase = .saved
            lastSnapshot = snapshot
        }
        visible = true
        synchronize()
    }

    func deactivate() {
        visible = false
        testAfterSignIn = false
        cancelValidation()
        account.endConfiguration()
        if phase == .checking { phase = .idle; testState = .idle }
    }

    func beginSignIn(otherAccount: Bool = false) {
        invalidate()
        testAfterSignIn = true
        account.dismissConfigurationIssue()
        account.signInConfiguration(otherAccount: otherAccount)
        synchronize()
    }

    /// Call before explicit account-management operations that mutate the underlying identity.
    func accountWillChange() { invalidate() }

    func cancel() {
        testAfterSignIn = false
        cancelValidation()
        if account.configurationSnapshot.signingIn { account.cancelConfigurationSignIn() }
        phase = .cancelled
        testState = .idle
    }

    func retry() {
        test()
    }

    /// The explicit Test action commits a successful account because ChatGPT has no Save control.
    func test() {
        guard !isBusy else { return }
        account.dismissConfigurationIssue()
        synchronize()
        if account.configurationSnapshot.isReady { validate() }
        else { testState = .unavailable }
    }

    @discardableResult
    func save() -> Bool {
        guard canSave else { return false }
        phase = .saving
        do {
            try account.commitConfigurationCandidate()
            try persistSelection()
            savedAccountID = verifiedAccountID
            selectionIsSaved = true
            phase = .saved
            testState = .available
            return true
        } catch {
            phase = .saveFailed
            testState = .unavailable
            return false
        }
    }

    private func invalidate() {
        cancelValidation()
        verifiedAccountID = nil
        savedAccountID = nil
        phase = .idle
        testState = .idle
    }

    private func synchronize() {
        let snapshot = account.configurationSnapshot
        guard visible else { lastSnapshot = snapshot; return }
        let previous = lastSnapshot
        let hadActiveOrFailedTest = testAfterSignIn || testState == .testing || testState == .unavailable
        lastSnapshot = snapshot
        if snapshot.accountID != previous.accountID ||
            (!previous.signingIn && snapshot.signingIn) ||
            (!previous.signingOut && snapshot.signingOut) ||
            snapshot.needsAuthorization != previous.needsAuthorization ||
            snapshot.needsReauthentication != previous.needsReauthentication {
            invalidate()
        }
        if snapshot.signingIn { phase = .signingIn; return }
        if snapshot.signingOut { phase = .signingOut; return }
        if let issue = snapshot.issue {
            cancelValidation()
            verifiedAccountID = nil
            phase = .failed(issue)
            if testAfterSignIn || snapshot.needsAuthorization || snapshot.needsReauthentication ||
                (hadActiveOrFailedTest && snapshot.accountID == previous.accountID) {
                testState = .unavailable
            }
            testAfterSignIn = false
            return
        }
        guard snapshot.accountID != nil else { phase = .signedOut; return }
        if snapshot.needsAuthorization { phase = .failed(.missingPlanPermission); testState = .unavailable; return }
        if snapshot.needsReauthentication { phase = .failed(.loginExpired); testState = .unavailable; return }
        guard visible, taskID == nil else { return }
        if testAfterSignIn {
            testAfterSignIn = false
            validate()
        }
        else if savedAccountID == snapshot.accountID { phase = .saved }
    }

    private func validate() {
        let snapshot = account.configurationSnapshot
        guard visible, snapshot.isReady, let identity = snapshot.accountID else { return }
        cancelValidation()
        let id = UUID()
        taskID = id
        verifiedAccountID = nil
        phase = .checking
        testState = .testing
        timeoutTask = Task { [weak self] in
            guard let self else { return }
            do { try await Task.sleep(nanoseconds: self.validationTimeoutNanoseconds) }
            catch { return }
            guard self.taskID == id else { return }
            // End the UI operation even if a service ignores task cancellation.
            self.cancelValidation()
            self.verifiedAccountID = nil
            self.phase = .failed(.timedOut)
            self.testState = .unavailable
        }
        task = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.taskID == id {
                    self.taskID = nil
                    self.task = nil
                    self.timeoutTask?.cancel()
                    self.timeoutTask = nil
                }
            }
            do {
                try await self.account.validateConfiguration()
                try Task.checkCancellation()
                guard self.taskID == id, self.account.configurationSnapshot.accountID == identity,
                      self.account.configurationSnapshot.isReady else { return }
                self.verifiedAccountID = identity
                if self.selectionIsSaved, self.savedAccountID == identity {
                    // A health check must not recommit the active account: doing so
                    // rotates its production generation and interrupts ongoing reading tasks.
                    self.phase = .saved
                    self.testState = .available
                } else {
                    self.phase = .verified
                    _ = self.save()
                }
            } catch is CancellationError { }
            catch {
                guard self.taskID == id, self.account.configurationSnapshot.accountID == identity else { return }
                self.verifiedAccountID = nil
                self.phase = .failed(ChatGPTError.from(error))
                self.testState = .unavailable
            }
        }
    }

    private func cancelValidation() {
        taskID = nil
        task?.cancel()
        task = nil
        timeoutTask?.cancel()
        timeoutTask = nil
    }
}
