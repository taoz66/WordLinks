import Combine
import Foundation
import XCTest
@testable import ReadingToolDaily

@MainActor
final class AIExplanationHighlightTests: XCTestCase {
    func testAddsExactSelectionAndOnlyFirstExplanationLine() throws {
        let fixture = try makeFixture(text: "She sat on the river bank.", selection: "river bank")
        fixture.client.onExplain = { _, _ in "河岸\n此处指河流边缘。\n不要保存这一行。" }
        defer { fixture.model.cancel() }

        waitForResult(fixture)

        XCTAssertEqual(fixture.model.meaningToSave, "河岸")
        XCTAssertTrue(fixture.model.canAddHighlight)
        fixture.model.addHighlight()

        let card = try XCTUnwrap(fixture.store.cards(articleID: fixture.article.id).first)
        XCTAssertEqual(card.selectedText, "river bank")
        XCTAssertEqual(card.expression, "river bank")
        XCTAssertEqual(card.meaning, "河岸")
        XCTAssertEqual(fixture.model.highlightState, .added)
    }

    func testAnExactExistingSelectionIsAlreadyAddedAndIsNotOverwritten() throws {
        let fixture = try makeFixture(text: "She sat on the bank.", selection: "bank")
        let range = fixture.range
        _ = try fixture.store.saveCard(articleID: fixture.article.id, range: range,
                                       expression: "bank", meaning: "手动释义")
        fixture.client.onExplain = { _, _ in "AI 建议" }
        defer { fixture.model.cancel() }

        waitForResult(fixture)

        XCTAssertEqual(fixture.model.highlightState, .added)
        XCTAssertFalse(fixture.model.canAddHighlight)
        fixture.model.addHighlight()
        XCTAssertEqual(fixture.store.cards(articleID: fixture.article.id).map(\.meaning), ["手动释义"])
    }

    func testPartialOverlapIsDisabledAndDoesNotAddAnotherCard() throws {
        let fixture = try makeFixture(text: "She sat on the river bank.", selection: "bank")
        _ = try fixture.store.saveCard(articleID: fixture.article.id,
                                       range: (fixture.article.text as NSString).range(of: "river bank"),
                                       expression: "river bank", meaning: "河岸")
        fixture.client.onExplain = { _, _ in "银行" }
        defer { fixture.model.cancel() }

        waitForResult(fixture)

        XCTAssertEqual(fixture.model.highlightState, .overlapping)
        XCTAssertFalse(fixture.model.canAddHighlight)
        fixture.model.addHighlight()
        XCTAssertEqual(fixture.store.cards(articleID: fixture.article.id).count, 1)
        XCTAssertNil(fixture.model.highlightError)
    }

    func testTranslationNeverOffersHighlightAction() throws {
        let text = "She sat on the bank."
        let fixture = try makeFixture(text: text, selection: text)
        XCTAssertEqual(fixture.model.purpose, .translation)
        XCTAssertEqual(fixture.model.highlightState, .hidden)
        XCTAssertFalse(fixture.model.canAddHighlight)
        fixture.model.addHighlight()
        XCTAssertTrue(fixture.store.cards(articleID: fixture.article.id).isEmpty)
    }

    func testLoadingAndFailedExplanationCannotBeAdded() throws {
        let loading = try makeFixture(text: "She sat on the bank.", selection: "bank")
        XCTAssertFalse(loading.model.canAddHighlight)
        XCTAssertNil(loading.model.meaningToSave)
        loading.model.cancel()

        let failed = try makeFixture(text: "She sat on the bank.", selection: "bank")
        failed.client.onExplain = { _, _ in throw AIError.http(500) }
        defer { failed.model.cancel() }
        waitForResult(failed, expectingFailure: true)
        XCTAssertFalse(failed.model.canAddHighlight)
        XCTAssertNil(failed.model.meaningToSave)
        failed.model.addHighlight()
        XCTAssertTrue(failed.store.cards(articleID: failed.article.id).isEmpty)
    }

    func testSameSpellingAtAnotherSourcePositionCanBeAdded() throws {
        let fixture = try makeFixture(text: "The bank was quiet. The bank was busy.", selection: "bank")
        let firstRange = (fixture.article.text as NSString).range(of: "bank")
        _ = try fixture.store.saveCard(articleID: fixture.article.id, range: firstRange,
                                       expression: "bank", meaning: "第一处")
        let secondRange = (fixture.article.text as NSString).range(of: "bank", options: .backwards)
        let secondSelection = try SelectionContext.extract(from: fixture.article.text, range: secondRange,
                                                           articleTitle: fixture.article.title)
        let secondModel = AIExplanationModel(selection: secondSelection, article: fixture.article,
                                             sourceRange: secondRange, store: fixture.store)
        let second = Fixture(store: fixture.store, article: fixture.article, range: secondRange,
                             model: secondModel, settings: fixture.settings, client: fixture.client)
        fixture.client.onExplain = { _, _ in "第二处" }
        defer { second.model.cancel() }

        waitForResult(second)

        XCTAssertTrue(second.model.canAddHighlight)
        second.model.addHighlight()
        let cards = fixture.store.cards(articleID: fixture.article.id)
        XCTAssertEqual(cards.map(\.selectedText), ["bank", "bank"])
        XCTAssertEqual(cards.map(\.meaning), ["第一处", "第二处"])
    }

    func testSwitchingProfileWhilePopoverIsOpenCannotWriteIntoNewProfile() throws {
        let fixture = try makeFixture(text: "She sat on the bank.", selection: "bank")
        fixture.client.onExplain = { _, _ in "河岸" }
        defer { fixture.model.cancel() }
        waitForResult(fixture)
        let previousProfileID = fixture.store.archive.id
        try fixture.store.createProfile(name: "Other profile")

        fixture.model.addHighlight()

        XCTAssertNotEqual(fixture.store.archive.id, previousProfileID)
        XCTAssertTrue(fixture.store.archive.cards.isEmpty)
    }

    private struct Fixture {
        let store: ReadingLibraryStore
        let article: LibraryArticle
        let range: NSRange
        let model: AIExplanationModel
        let settings: AISettingsStore
        let client: HighlightTestCustomClient
    }

    private func makeFixture(text: String, selection: String) throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AIExplanationHighlightTests-\(UUID().uuidString)", isDirectory: true)
        let store = try ReadingLibraryStore(rootURL: root, bundledCollections: [])
        let markdown = "# Notes\n\n\(text)"
        let article = try store.addMarkdown(markdown: markdown, sourceName: "notes.md")
        let range = (article.text as NSString).range(of: selection)
        let context = try SelectionContext.extract(from: article.text, range: range, articleTitle: article.title)
        let model = AIExplanationModel(selection: context, article: article, sourceRange: range, store: store)
        let client = HighlightTestCustomClient()
        let suite = "AIExplanationHighlightTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        let settings = AISettingsStore(defaults: defaults, credentials: HighlightLegacyCredentials(),
                                       language: AppLanguageStore(defaults: defaults),
                                       customCredentials: HighlightCustomCredentials(), customClient: client)
        try settings.saveCustomProfile(name: "Synthetic", baseURL: "https://example.invalid/v1",
                                       apiKey: "synthetic-key", model: "synthetic-model")
        return Fixture(store: store, article: article, range: range, model: model,
                       settings: settings, client: client)
    }

    private func waitForResult(_ fixture: Fixture, expectingFailure: Bool = false,
                               file: StaticString = #filePath, line: UInt = #line) {
        let finished = expectation(description: "AI explanation finishes")
        let observer = fixture.model.$phase.sink { phase in
            switch phase {
            case .explained:
                if !expectingFailure { finished.fulfill() }
            case .failed:
                if expectingFailure { finished.fulfill() }
            default:
                break
            }
        }
        let task = Task { @MainActor in fixture.model.start(settings: fixture.settings) }
        defer { observer.cancel(); task.cancel() }
        wait(for: [finished], timeout: 3)
        if expectingFailure {
            guard case .failed = fixture.model.phase else {
                XCTFail("Expected the simulated AI request to fail", file: file, line: line)
                return
            }
        } else {
            guard case .explained = fixture.model.phase else {
                XCTFail("Expected the simulated AI request to succeed", file: file, line: line)
                return
            }
        }
    }
}

@MainActor
private final class HighlightTestCustomClient: AICustomServing {
    var onExplain: (AIExplanationPurpose, AIConfiguration) async throws -> String = { _, _ in "河岸" }

    func fetchModels(baseURL: String, apiKey: String) async throws -> [String] { ["synthetic-model"] }

    func explain(selection: String, context: String, focusedSentence: String?,
                 purpose: AIExplanationPurpose, configuration: AIConfiguration) async throws -> String {
        try await onExplain(purpose, configuration)
    }
}

private struct HighlightLegacyCredentials: AICredentialStorage {
    func read() throws -> String? { nil }
    func write(_ value: String) throws { }
}

private final class HighlightCustomCredentials: AICustomCredentialStorage {
    func read(profileID: UUID) throws -> String? { "synthetic-key" }
    func write(_ value: String?, profileID: UUID) throws { }
}
