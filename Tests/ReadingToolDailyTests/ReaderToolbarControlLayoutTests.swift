import AppKit
import SwiftUI
import XCTest
@testable import ReadingToolDaily

@MainActor
final class ReaderToolbarControlLayoutTests: XCTestCase {
    func testIntensiveButtonKeepsNativeButtonDimensionsWhenLoadingAndActive() throws {
        _ = NSApplication.shared
        if NSScreen.screens.isEmpty { throw XCTSkip("Toolbar control layout requires a WindowServer session") }
        // The installed XCTest runner predates the Swift compiler required by
        // the app. Keep XCTest's Objective-C entry synchronous; its normal wait
        // pumps AppKit while a child task drives the real asynchronous control.
        let finished = expectation(description: "Toolbar state dimensions checked")
        let task = Task { @MainActor in
            defer { finished.fulfill() }
            do { try await verifyIntensiveButtonDimensions() }
            catch { XCTFail("Toolbar layout failed: \(error)") }
        }
        wait(for: [finished], timeout: 10)
        task.cancel()
    }

    private func verifyIntensiveButtonDimensions() async throws {
        XCTAssertNotNil(NSImage(systemSymbolName: "append.page.fill", accessibilityDescription: nil))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try ReadingLibraryStore(rootURL: root, bundledCollections: [])
        let article = try store.addMarkdown(markdown: "# Layout\n\nA synthetic sentence.", sourceName: "layout.md")
        let suite = "ReaderToolbarControlLayoutTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let client = ToolbarLayoutClient()
        let settings = AISettingsStore(defaults: defaults, credentials: ToolbarLayoutCredentials(),
                                       language: AppLanguageStore(defaults: defaults),
                                       customCredentials: ToolbarLayoutProfileCredentials(), customClient: client)
        try settings.saveCustomProfile(name: "Synthetic layout", baseURL: "https://layout.example.invalid/v1",
                                       apiKey: "", model: "synthetic-layout", authentication: .none)
        let model = IntensiveReadingModel(article: article, profileID: store.archive.id, store: store, settings: settings)
        defer {
            model.cancel()
            client.finish(throwing: CancellationError())
        }
        var sizes: [String: CGSize] = [:]
        let host = NSHostingView(rootView: ToolbarSizingProbe(model: model, onSizes: { sizes = $0 }))
        let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 240, height: 90),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderBack(nil)
        defer {
            window.orderOut(nil)
            window.contentView = nil
            window.close()
        }
        await settle(host)
        let inactive = try XCTUnwrap(sizes["intensive"])
        let reference = try XCTUnwrap(sizes["reference"])
        XCTAssertGreaterThan(inactive.width, 0)
        XCTAssertGreaterThan(inactive.height, 0)
        assertSize(inactive, equals: reference)

        model.setActivated(true)
        try await waitUntil { client.hasPendingRequest }
        await settle(host)
        XCTAssertTrue(model.isGenerating)
        assertSize(try XCTUnwrap(sizes["intensive"]), equals: inactive)

        try client.complete()
        try await waitUntil { model.progress.isComplete }
        await settle(host)
        XCTAssertTrue(model.isActivated)
        assertSize(try XCTUnwrap(sizes["intensive"]), equals: inactive)
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<200 {
            try Task.checkCancellation()
            if condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw ToolbarLayoutTimeout.pendingState
    }

    private func assertSize(_ actual: CGSize, equals expected: CGSize,
                            file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.width, expected.width, accuracy: 0.5, file: file, line: line)
        XCTAssertEqual(actual.height, expected.height, accuracy: 0.5, file: file, line: line)
    }

    private func settle(_ host: NSView) async {
        for _ in 0..<12 {
            host.layoutSubtreeIfNeeded()
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }
}

private struct ToolbarSizingProbe: View {
    let model: IntensiveReadingModel
    let onSizes: ([String: CGSize]) -> Void

    var body: some View {
        HStack {
            Button {} label: { ReaderToolbarIcon(systemName: "viewfinder") }
                .background { measure("reference") }
            IntensiveReadingControl(model: model)
                .background { measure("intensive") }
        }
        .controlSize(.regular)
        .fixedSize()
        .onPreferenceChange(ToolbarControlSizeKey.self, perform: onSizes)
    }

    private func measure(_ name: String) -> some View {
        GeometryReader { geometry in
            Color.clear.preference(key: ToolbarControlSizeKey.self, value: [name: geometry.size])
        }
    }
}

private struct ToolbarControlSizeKey: PreferenceKey {
    static var defaultValue: [String: CGSize] = [:]
    static func reduce(value: inout [String: CGSize], nextValue: () -> [String: CGSize]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

private struct ToolbarLayoutCredentials: AICredentialStorage {
    func read() throws -> String? { nil }
    func write(_ value: String) throws { }
}

private struct ToolbarLayoutProfileCredentials: AICustomCredentialStorage {
    func read(profileID: UUID) throws -> String? { nil }
    func write(_ value: String?, profileID: UUID) throws { }
}

@MainActor
private final class ToolbarLayoutClient: AICustomServing {
    private var continuation: CheckedContinuation<String, Error>?
    private var inputs: [[String: Any]] = []
    var hasPendingRequest: Bool { continuation != nil }

    func fetchModels(baseURL: String, apiKey: String) async throws -> [String] { [] }
    func explain(selection: String, context: String, focusedSentence: String?, purpose: AIExplanationPurpose,
                 configuration: AIConfiguration) async throws -> String {
        inputs = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(selection.utf8)) as? [[String: Any]])
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
        }
    }

    func complete() throws {
        let response: [String: Any] = ["sentences": inputs.map {
            ["id": $0["id"] ?? 0, "translation": "合成译文。", "links": []] as [String: Any]
        }]
        let data = try JSONSerialization.data(withJSONObject: response)
        let pending = try XCTUnwrap(continuation)
        continuation = nil
        pending.resume(returning: String(decoding: data, as: UTF8.self))
    }

    func finish(throwing error: Error) {
        continuation?.resume(throwing: error)
        continuation = nil
    }
}

private enum ToolbarLayoutTimeout: Error { case pendingState }
