import AppKit
import SwiftUI
import XCTest
@testable import WordLinks

/// Exercise popup actions through AppKit and let SwiftUI commit the resulting state.
/// All state is memory-only; opening the system menu or contacting a service is unnecessary.
@MainActor
final class AIModelPickerTests: XCTestCase {
    func testNativeModelSelectionUpdatesBindingAndCommandsKeepItsTitle() async throws {
        let state = ModelPickerState(models: ["model-a", "model-b"], selectedModel: "model-a")
        let (host, window) = try makeHost(state)
        defer { close(window) }
        await settle(host)
        let popup = try control(in: host)
        let alternative = try XCTUnwrap(popup.itemArray.first { ($0.representedObject as? String) == "model-b" })

        perform(alternative, in: popup)
        await settle(host)

        XCTAssertEqual(state.selections, ["model-b"])
        XCTAssertEqual(state.selectedModel, "model-b")
        XCTAssertEqual(popup.title, "model-b")
        XCTAssertEqual(popup.selectedItem?.representedObject as? String, "model-b")

        perform(try command("ai.custom.enterModel", in: popup), in: popup)
        XCTAssertEqual(state.manualEntries, 1)
        XCTAssertEqual(popup.title, "model-b", "A command must not replace the displayed model")
        XCTAssertEqual(state.selections, ["model-b"])

        perform(try command("ai.custom.fetchModels", in: popup), in: popup)
        await settle(host)
        XCTAssertEqual(state.fetches, 1)
        XCTAssertTrue(state.isFetching)
        XCTAssertEqual(popup.title, "model-b")
        let pendingFetch = try command("ai.custom.fetchModels", in: popup)
        XCTAssertFalse(pendingFetch.isEnabled)
        // Programmatic AppKit actions can bypass a disabled menu item. The
        // coordinator must still reject a second fetch after SwiftUI updates it.
        perform(pendingFetch, in: popup)
        XCTAssertEqual(state.fetches, 1)
        XCTAssertEqual(popup.title, "model-b")
        XCTAssertEqual(state.selectedModel, "model-b")
    }

    func testSavedUnlistedModelRemainsDisplayedAndSelectableModelsStillWork() async throws {
        let state = ModelPickerState(models: ["listed-model"], selectedModel: "saved-unlisted-model")
        let (host, window) = try makeHost(state)
        defer { close(window) }
        await settle(host)
        let popup = try control(in: host)

        XCTAssertEqual(popup.title, "saved-unlisted-model")
        XCTAssertTrue(try XCTUnwrap(popup.selectedItem).isEnabled,
                      "A saved model remains a valid choice even when the catalog does not list it")
        XCTAssertEqual(state.fetches, 0, "Rendering a saved model must not fetch the catalog")
        perform(try command("ai.custom.enterModel", in: popup), in: popup)
        XCTAssertEqual(popup.title, "saved-unlisted-model")
        XCTAssertEqual(state.manualEntries, 1)

        let listed = try XCTUnwrap(popup.itemArray.first { ($0.representedObject as? String) == "listed-model" })
        perform(listed, in: popup)
        await settle(host)
        XCTAssertEqual(state.selectedModel, "listed-model")
        XCTAssertEqual(popup.title, "listed-model")
        XCTAssertFalse(popup.itemArray.contains { $0.title == "saved-unlisted-model" },
                       "SwiftUI updates must replace the old placeholder after a real selection")
    }

    func testEmptyCatalogAllowsManualEntryEvenWithoutFetchCredentials() async throws {
        let state = ModelPickerState(models: [], selectedModel: "", canFetch: false)
        let (host, window) = try makeHost(state)
        defer { close(window) }
        await settle(host)
        let popup = try control(in: host)
        let placeholderTitle = popup.title
        let fetch = try command("ai.custom.fetchModels", in: popup)
        let manual = try command("ai.custom.enterModel", in: popup)

        XCTAssertFalse(fetch.isEnabled)
        XCTAssertTrue(manual.isEnabled)
        XCTAssertTrue(popup.isEnabled)
        XCTAssertFalse(try XCTUnwrap(popup.selectedItem).isEnabled)
        perform(fetch, in: popup)
        XCTAssertEqual(state.fetches, 0)
        perform(manual, in: popup)
        XCTAssertEqual(state.manualEntries, 1)
        XCTAssertEqual(popup.title, placeholderTitle)
        XCTAssertTrue(state.selectedModel.isEmpty)
        XCTAssertTrue(state.selections.isEmpty)
    }

    private func makeHost(_ state: ModelPickerState) throws -> (NSHostingView<ModelPickerHost>, NSWindow) {
        _ = NSApplication.shared
        if NSScreen.screens.isEmpty { throw XCTSkip("Native popup checks require a WindowServer session") }
        let host = NSHostingView(rootView: ModelPickerHost(state: state))
        let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 360, height: 70),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "Wordlinks disposable model picker check"
        window.contentView = host
        window.orderBack(nil)
        return (host, window)
    }

    private func close(_ window: NSWindow) {
        window.orderOut(nil)
        window.contentView = nil
        window.close()
    }

    private func settle(_ host: NSView) async {
        for _ in 0..<5 {
            host.layoutSubtreeIfNeeded()
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    private func control(in view: NSView) throws -> NSPopUpButton {
        try XCTUnwrap(descendant(NSPopUpButton.self, in: view))
    }

    private func descendant<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
        if let result = view as? T { return result }
        return view.subviews.lazy.compactMap { self.descendant(type, in: $0) }.first
    }

    private func command(_ identifier: String, in popup: NSPopUpButton) throws -> NSMenuItem {
        try XCTUnwrap(popup.itemArray.first { $0.accessibilityIdentifier() == identifier })
    }

    private func perform(_ item: NSMenuItem, in popup: NSPopUpButton) {
        popup.select(item)
        _ = popup.sendAction(popup.action, to: popup.target)
    }
}

@MainActor
private final class ModelPickerState: ObservableObject {
    @Published var models: [String]
    @Published var selectedModel: String
    @Published var isFetching = false
    @Published var canFetch: Bool
    private(set) var selections: [String] = []
    private(set) var fetches = 0
    private(set) var manualEntries = 0

    init(models: [String], selectedModel: String, canFetch: Bool = true) {
        self.models = models
        self.selectedModel = selectedModel
        self.canFetch = canFetch
    }

    func select(_ model: String) { selections.append(model); selectedModel = model }
    func fetch() { fetches += 1; isFetching = true }
    func enterManually() { manualEntries += 1 }
}

private struct ModelPickerHost: View {
    @ObservedObject var state: ModelPickerState

    var body: some View {
        AIModelPicker(models: state.models, selectedModel: state.selectedModel,
                      isFetching: state.isFetching, canFetch: state.canFetch,
                      onSelect: state.select, onFetch: state.fetch, onManualEntry: state.enterManually)
            .frame(maxWidth: .infinity)
            .padding(12)
    }
}
