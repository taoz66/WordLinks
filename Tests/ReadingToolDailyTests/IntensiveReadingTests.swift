import Foundation
import XCTest
@testable import ReadingToolDaily

final class IntensiveReadingTests: XCTestCase {
    @MainActor
    func testModelPoolReusesTheArticleModelAcrossReaderViewRecreation() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString,
                                                                                 isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try ReadingLibraryStore(rootURL: root, bundledCollections: [])
        let article = try store.addMarkdown(markdown: "# Test\n\nA short sentence.", sourceName: "test.md")

        let suite = "IntensiveReadingTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AISettingsStore(defaults: defaults,
                                       credentials: IntensiveReadingTestCredentials(),
                                       language: AppLanguageStore(defaults: defaults),
                                       customCredentials: IntensiveReadingTestCustomCredentials(),
                                       customClient: IntensiveReadingTestAIClient())
        let pool = IntensiveReadingModelPool()

        let first = pool.model(for: article, profileID: store.archive.id, store: store, settings: settings)
        let afterNavigation = pool.model(for: article, profileID: store.archive.id,
                                         store: store, settings: settings)

        XCTAssertTrue(first === afterNavigation)
    }

    @MainActor
    func testNavigatingToAnotherArticleKeepsItsProgressIndependentAndGenerationRunning() async throws {
        let fixture = try IntensiveReadingFixture()
        defer { fixture.cleanUp() }
        let first = fixture.model(for: fixture.firstArticle)
        let entered = expectation(description: "First article request started")
        fixture.client.onRequest = { _ in entered.fulfill() }
        first.setActivated(true)
        await fulfillment(of: [entered], timeout: 2)

        let second = fixture.model(for: fixture.secondArticle)
        XCTAssertTrue(first.isGenerating)
        XCTAssertFalse(second.isGenerating)
        XCTAssertFalse(second.isActivated)
        XCTAssertEqual(second.progress.completedCount, 0)
        XCTAssertTrue(first === fixture.model(for: fixture.firstArticle))

        let finished = expectation(description: "First article finishes in background")
        first.onProgressChange = { if $0.isComplete { finished.fulfill() } }
        try fixture.client.complete(source: fixture.firstSource)
        await fulfillment(of: [finished], timeout: 2)
        XCTAssertTrue(first.isActivated)
        XCTAssertTrue(fixture.model(for: fixture.firstArticle).isActivated)
        XCTAssertFalse(second.isGenerating)
        XCTAssertFalse(second.isActivated)
    }

    @MainActor
    func testConcurrentArticlesCompleteIndependently() async throws {
        let fixture = try IntensiveReadingFixture()
        defer { fixture.cleanUp() }
        let first = fixture.model(for: fixture.firstArticle)
        let second = fixture.model(for: fixture.secondArticle)
        let entered = expectation(description: "Both article requests started")
        entered.expectedFulfillmentCount = 2
        fixture.client.onRequest = { _ in entered.fulfill() }
        first.setActivated(true)
        second.setActivated(true)
        await fulfillment(of: [entered], timeout: 2)

        let secondFinished = expectation(description: "Second article finishes first")
        second.onProgressChange = { if $0.isComplete { secondFinished.fulfill() } }
        try fixture.client.complete(source: fixture.secondSource)
        await fulfillment(of: [secondFinished], timeout: 2)
        XCTAssertTrue(first.isGenerating)
        XCTAssertEqual(first.completedCount, 0)
        XCTAssertFalse(first.isActivated)
        XCTAssertTrue(second.isActivated)
        XCTAssertEqual(second.completedCount, second.progress.totalCount)

        let firstFinished = expectation(description: "First article finishes separately")
        first.onProgressChange = { if $0.isComplete { firstFinished.fulfill() } }
        try fixture.client.complete(source: fixture.firstSource)
        await fulfillment(of: [firstFinished], timeout: 2)
        XCTAssertTrue(first.isActivated)
        XCTAssertTrue(second.isActivated)
        XCTAssertEqual(fixture.client.requestCount, 2)
    }

    @MainActor
    func testCancellingOneArticleDoesNotCancelAnotherOrCommitItsLateResult() async throws {
        let fixture = try IntensiveReadingFixture()
        defer { fixture.cleanUp() }
        let first = fixture.model(for: fixture.firstArticle)
        let second = fixture.model(for: fixture.secondArticle)
        let entered = expectation(description: "Both requests entered")
        entered.expectedFulfillmentCount = 2
        fixture.client.onRequest = { _ in entered.fulfill() }
        first.setActivated(true)
        second.setActivated(true)
        await fulfillment(of: [entered], timeout: 2)

        first.cancel()
        XCTAssertFalse(first.isGenerating)
        XCTAssertTrue(second.isGenerating)
        try fixture.client.complete(source: fixture.firstSource)
        let secondFinished = expectation(description: "Other article remains active")
        second.onProgressChange = { if $0.isComplete { secondFinished.fulfill() } }
        try fixture.client.complete(source: fixture.secondSource)
        await fulfillment(of: [secondFinished], timeout: 2)
        XCTAssertTrue(second.isActivated)
        XCTAssertFalse(first.isActivated)
        XCTAssertTrue(first.translations.isEmpty)
        XCTAssertTrue(try fixture.store.intensiveTranslations(articleID: fixture.firstArticle.id,
                                                              targetLanguage: .chinese).isEmpty)
    }

    @MainActor
    func testCachedArticleActivatesImmediatelyWithoutAnotherAIRequest() throws {
        let fixture = try IntensiveReadingFixture()
        defer { fixture.cleanUp() }
        let cached = IntensiveReadingTranslation(sourceSentence: fixture.firstSource,
                                                translation: "缓存译文。", alignments: [], generatedAt: Date())
        try fixture.store.saveIntensiveTranslation(cached, articleID: fixture.firstArticle.id,
                                                  targetLanguage: .chinese)
        let model = fixture.model(for: fixture.firstArticle)

        model.setActivated(true)
        XCTAssertTrue(model.isActivated)
        XCTAssertFalse(model.isGenerating)
        XCTAssertTrue(model.progress.isComplete)
        model.setActivated(false)
        XCTAssertFalse(model.isActivated)
        model.setActivated(true)
        XCTAssertTrue(model.isActivated)
        XCTAssertEqual(fixture.client.requestCount, 0)
    }

    @MainActor
    func testDisablingDisplayDoesNotCancelGenerationOrReenableItOnCompletion() async throws {
        let fixture = try IntensiveReadingFixture()
        defer { fixture.cleanUp() }
        let model = fixture.model(for: fixture.firstArticle)
        let entered = expectation(description: "Request started")
        fixture.client.onRequest = { _ in entered.fulfill() }
        model.setActivated(true)
        await fulfillment(of: [entered], timeout: 2)
        model.setActivated(false)
        XCTAssertTrue(model.isGenerating)

        let finished = expectation(description: "Generation completes while display is disabled")
        model.onProgressChange = { if $0.isComplete { finished.fulfill() } }
        try fixture.client.complete(source: fixture.firstSource)
        await fulfillment(of: [finished], timeout: 2)
        XCTAssertFalse(model.isActivated)
        model.setActivated(true)
        XCTAssertTrue(model.isActivated)
        XCTAssertEqual(fixture.client.requestCount, 1)
    }

    @MainActor
    func testLanguageScopeChangeCancelsOldTasksAndReusesTheNewScopeModel() async throws {
        let fixture = try IntensiveReadingFixture()
        defer { fixture.cleanUp() }
        let oldModel = fixture.model(for: fixture.firstArticle)
        let entered = expectation(description: "Old language request entered")
        fixture.client.onRequest = { _ in entered.fulfill() }
        oldModel.setActivated(true)
        await fulfillment(of: [entered], timeout: 2)

        fixture.language.language = .english
        fixture.pool.synchronizeScope(profileID: fixture.store.archive.id, targetLanguage: .english)
        XCTAssertFalse(oldModel.isGenerating, "Changing scope must cancel even before another reader opens")
        let newModel = fixture.model(for: fixture.secondArticle)
        XCTAssertFalse(oldModel.isGenerating)
        XCTAssertFalse(oldModel.isActivated)
        XCTAssertEqual(newModel.targetLanguage, .english)
        fixture.pool.synchronizeScope(profileID: fixture.store.archive.id, targetLanguage: .english)
        XCTAssertTrue(newModel === fixture.model(for: fixture.secondArticle))

        let newEntered = expectation(description: "New language request entered")
        fixture.client.onRequest = { _ in newEntered.fulfill() }
        newModel.setActivated(true)
        await fulfillment(of: [newEntered], timeout: 2)
        try fixture.client.complete(source: fixture.firstSource)
        let newFinished = expectation(description: "New language request finishes")
        newModel.onProgressChange = { if $0.isComplete { newFinished.fulfill() } }
        try fixture.client.complete(source: fixture.secondSource)
        await fulfillment(of: [newFinished], timeout: 2)
        XCTAssertTrue(newModel.isActivated)
        XCTAssertTrue(oldModel.translations.isEmpty)
        XCTAssertTrue(try fixture.store.intensiveTranslations(articleID: fixture.firstArticle.id,
                                                              targetLanguage: .chinese).isEmpty)
    }

    @MainActor
    func testProfileScopeChangeCancelsOldTasksBeforeCreatingReusableNewModels() async throws {
        let fixture = try IntensiveReadingFixture()
        defer { fixture.cleanUp() }
        let oldProfileID = fixture.store.archive.id
        let oldModel = fixture.model(for: fixture.firstArticle)
        let entered = expectation(description: "Old profile request entered")
        fixture.client.onRequest = { _ in entered.fulfill() }
        oldModel.setActivated(true)
        await fulfillment(of: [entered], timeout: 2)

        try fixture.store.createProfile(name: "Other synthetic profile")
        let article = try fixture.store.addMarkdown(markdown: "# Other\n\nA profile sentence.",
                                                    sourceName: "other.md")
        let newModel = fixture.model(for: article)
        XCTAssertFalse(oldModel.isGenerating)
        fixture.pool.synchronizeScope(profileID: fixture.store.archive.id, targetLanguage: .chinese)
        XCTAssertTrue(newModel === fixture.model(for: article))

        let newEntered = expectation(description: "New profile request entered")
        fixture.client.onRequest = { _ in newEntered.fulfill() }
        newModel.setActivated(true)
        await fulfillment(of: [newEntered], timeout: 2)
        try fixture.client.complete(source: fixture.firstSource)
        let newFinished = expectation(description: "New profile request finishes")
        newModel.onProgressChange = { if $0.isComplete { newFinished.fulfill() } }
        try fixture.client.complete(source: "A profile sentence.")
        await fulfillment(of: [newFinished], timeout: 2)
        XCTAssertTrue(newModel.isActivated)
        XCTAssertTrue(oldModel.translations.isEmpty)
        try fixture.store.selectProfile(oldProfileID)
        XCTAssertTrue(try fixture.store.intensiveTranslations(articleID: fixture.firstArticle.id,
                                                              targetLanguage: .chinese).isEmpty)
    }

    @MainActor
    func testRegenerationFailureCanRetryWhenAllPreviousTranslationsRemainCached() async throws {
        let fixture = try IntensiveReadingFixture()
        defer { fixture.cleanUp() }
        let cached = IntensiveReadingTranslation(sourceSentence: fixture.firstSource,
                                                translation: "先前译文。", alignments: [], generatedAt: Date())
        try fixture.store.saveIntensiveTranslation(cached, articleID: fixture.firstArticle.id,
                                                  targetLanguage: .chinese)
        let model = fixture.model(for: fixture.firstArticle)
        let entered = expectation(description: "Regeneration started")
        fixture.client.onRequest = { _ in entered.fulfill() }
        model.regenerate()
        await fulfillment(of: [entered], timeout: 2)
        let failed = expectation(description: "Regeneration failed while retaining old translations")
        model.onProgressChange = { if !$0.isGenerating && $0.issue != nil { failed.fulfill() } }
        try fixture.client.fail(source: fixture.firstSource)
        await fulfillment(of: [failed], timeout: 2)
        XCTAssertFalse(model.progress.isComplete)
        XCTAssertEqual(model.translations[0]?.translation, cached.translation)

        let retried = expectation(description: "Retry sends another request")
        fixture.client.onRequest = { _ in retried.fulfill() }
        model.onProgressChange = nil
        model.setActivated(true)
        await fulfillment(of: [retried], timeout: 2)
        let finished = expectation(description: "Retried regeneration activates")
        model.onProgressChange = { if $0.isComplete { finished.fulfill() } }
        try fixture.client.complete(source: fixture.firstSource)
        await fulfillment(of: [finished], timeout: 2)
        XCTAssertTrue(model.isActivated)
        XCTAssertNil(model.issue)
        XCTAssertEqual(fixture.client.requestCount, 2)
    }

    func testProgressIsCompleteOnlyAfterAllSentencesFinishWithoutAnIssue() {
        XCTAssertFalse(IntensiveReadingProgress(isGenerating: true, completedCount: 4,
                                                totalCount: 4, issue: nil).isComplete)
        XCTAssertFalse(IntensiveReadingProgress(isGenerating: false, completedCount: 3,
                                                totalCount: 4, issue: nil).isComplete)
        XCTAssertTrue(IntensiveReadingProgress(isGenerating: false, completedCount: 4,
                                               totalCount: 4, issue: nil).isComplete)
        XCTAssertFalse(IntensiveReadingProgress(isGenerating: false, completedCount: 4,
                                                totalCount: 4, issue: "failed").isComplete)
        XCTAssertFalse(IntensiveReadingProgress(isGenerating: false, completedCount: 0,
                                                totalCount: 0, issue: nil).isComplete)
    }

    func testToolbarHasOnlyInactiveLoadingAndActiveStates() {
        XCTAssertEqual(IntensiveReadingToolbarState(isGenerating: false, isActivated: false), .inactive)
        XCTAssertEqual(IntensiveReadingToolbarState(isGenerating: true, isActivated: false), .loading)
        XCTAssertEqual(IntensiveReadingToolbarState(isGenerating: true, isActivated: true), .loading)
        XCTAssertEqual(IntensiveReadingToolbarState(isGenerating: false, isActivated: true), .active)
    }

    func testHoverRangesMergeWhitespaceButStaySeparateAcrossPunctuation() {
        let text = "we  kept moving; forward"
        let merged = IntensiveReadingHighlightRanges.mergingWhitespaceSeparated([
            NSRange(location: 0, length: 2),
            NSRange(location: 4, length: 4),
            NSRange(location: 9, length: 6),
            NSRange(location: 17, length: 7)
        ], in: text)

        XCTAssertEqual(merged, [NSRange(location: 0, length: 15), NSRange(location: 17, length: 7)])
        XCTAssertEqual((text as NSString).substring(with: merged[0]), "we  kept moving")
    }

    func testIntensiveSelectionMapsAcrossInsertedTranslationsBackToSource() {
        let document = IntensiveRenderDocument(
            attributedText: NSAttributedString(string: "first\n译文\nsecond"),
            alignments: [],
            sourceSegments: [
                IntensiveDocumentSegment(articleRange: NSRange(location: 0, length: 5),
                                         displayRange: NSRange(location: 0, length: 5)),
                IntensiveDocumentSegment(articleRange: NSRange(location: 6, length: 6),
                                         displayRange: NSRange(location: 9, length: 6))
            ],
            articleText: "first second"
        )

        XCTAssertEqual(document.articleRange(forDisplayRange: NSRange(location: 2, length: 9)),
                       NSRange(location: 2, length: 6))
        XCTAssertEqual(document.displayRanges(forArticleRange: NSRange(location: 2, length: 6)),
                       [NSRange(location: 2, length: 3), NSRange(location: 9, length: 2)])
        XCTAssertNil(document.sourceDisplayRange(forDisplayRange: NSRange(location: 2, length: 9)))
        XCTAssertEqual(document.sourceDisplayRange(forDisplayRange: NSRange(location: 10, length: 3)),
                       NSRange(location: 10, length: 3))
    }

    func testAlignmentSupportsDiscontinuousSourceAndSeveralSharedTargetPhrases() throws {
        let source = "We nearly gave up."
        let translation = "我们差点放弃，最终还是放弃了。"
        let response = try IntensiveReadingBatchResponse.decode("""
        ```json
        {"sentences":[{"id":0,"translation":"我们差点放弃，最终还是放弃了。","links":[
          {"sourceWordIDs":[1,3],"targetPhrases":[{"text":"差点放弃","occurrence":0},{"text":"放弃了","occurrence":0}]},
          {"sourceWordIDs":[2],"targetPhrases":[{"text":"差点放弃","occurrence":0},{"text":"放弃了","occurrence":0}]}
        ]}]}
        ```
        """)
        let suggestion = try XCTUnwrap(response.sentences.first)
        let result = try XCTUnwrap(IntensiveReadingAlignmentBuilder.translation(source: source,
                                                                                suggestion: suggestion))

        XCTAssertTrue(result.isValid(for: source))
        XCTAssertEqual(result.alignments.count, 2)
        XCTAssertEqual(result.alignments[0].sourceRanges.count, 2)
        XCTAssertEqual(result.alignments[0].targetRanges.count, 2)
        XCTAssertEqual(result.alignments[0].targetRanges, result.alignments[1].targetRanges)
        XCTAssertEqual((source as NSString).substring(with: result.alignments[0].sourceRanges[0].range), "nearly")
        XCTAssertEqual((source as NSString).substring(with: result.alignments[0].sourceRanges[1].range), "up")
        XCTAssertEqual((translation as NSString).substring(with: result.alignments[0].targetRanges[0].range), "差点放弃")
    }

    func testRepeatedTargetPhraseUsesOnlyTheRequestedOccurrence() throws {
        let source = "She created work that shows her originality."
        let translation = "她创作了一系列作品，展现了她的原创性。"
        let response = try IntensiveReadingBatchResponse.decode("""
        {"sentences":[{"id":0,"translation":"\(translation)","links":[
          {"sourceWordIDs":[0],"targetPhrases":[{"text":"她","occurrence":0}]},
          {"sourceWordIDs":[5],"targetPhrases":[{"text":"她","occurrence":1}]}
        ]}]}
        """)
        let result = try XCTUnwrap(IntensiveReadingAlignmentBuilder.translation(
            source: source, suggestion: XCTUnwrap(response.sentences.first)
        ))

        XCTAssertEqual(result.alignments.count, 2)
        let firstTarget = try XCTUnwrap(result.alignments.first?.targetRanges.first)
        let secondTarget = try XCTUnwrap(result.alignments.last?.targetRanges.first)
        XCTAssertEqual((translation as NSString).substring(with: firstTarget.range), "她")
        XCTAssertEqual((translation as NSString).substring(with: secondTarget.range), "她")
        XCTAssertNotEqual(firstTarget.location, secondTarget.location)
        XCTAssertEqual((source as NSString).substring(with: result.alignments[0].sourceRanges[0].range), "She")
        XCTAssertEqual((source as NSString).substring(with: result.alignments[1].sourceRanges[0].range), "her")
    }

    func testUnmatchedOrUnresolvableLinksDoNotInvalidateTheTranslation() throws {
        let source = "A clear example."
        let response = try IntensiveReadingBatchResponse.decode("""
        {"sentences":[{"id":0,"translation":"一个清楚的例子。","links":[
          {"sourceWordIDs":[1],"targetPhrases":["不存在的片段"]},
          {"sourceWordIDs":[2],"targetPhrases":["例子"]}
        ]}]}
        """)
        let result = try XCTUnwrap(IntensiveReadingAlignmentBuilder.translation(source: source,
                                                                                suggestion: XCTUnwrap(response.sentences.first)))

        XCTAssertEqual(result.translation, "一个清楚的例子。")
        XCTAssertEqual(result.alignments.count, 1)
        XCTAssertEqual((source as NSString).substring(with: result.alignments[0].sourceRanges[0].range), "example")
    }

    @MainActor
    func testReadingLibraryStoreLoadsBundledIntensiveReadingAndAllowsProfileOverride() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = try ReadingLibraryStore(rootURL: root, bundledCollections: [])
        let article = try store.addMarkdown(markdown: "# Test Title\n\nFirst sentence of article. Second sentence here.", sourceName: "test.md")

        // 默认无内置且无本地缓存时返回空
        let empty = try store.intensiveTranslations(articleID: article.id, targetLanguage: .chinese)
        XCTAssertTrue(empty.isEmpty)

        // 保存一条翻译到用户 profile
        let userResult = IntensiveReadingTranslation(
            sourceSentence: "First sentence of article.",
            translation: "文章的第一句话。",
            alignments: [],
            generatedAt: Date()
        )
        try store.saveIntensiveTranslation(userResult, articleID: article.id, targetLanguage: .chinese)

        let loaded = try store.intensiveTranslations(articleID: article.id, targetLanguage: .chinese)
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded["First sentence of article."]?.translation, "文章的第一句话。")
    }

    func testVerifyGeneratedIntensiveCacheFileIfExists() throws {
        guard let bundledURL = BundledArticleCollection.bundledIntensiveReadingCacheURL(),
              FileManager.default.fileExists(atPath: bundledURL.path) else {
            return
        }
        let data = try Data(contentsOf: bundledURL)
        let cache = try JSONDecoder().decode(IntensiveReadingCacheFile.self, from: data)
        XCTAssertEqual(cache.version, 1)
        XCTAssertFalse(cache.entries.isEmpty)
        for entry in cache.entries {
            XCTAssertTrue(entry.result.isValid(for: entry.result.sourceSentence),
                          "Invalid translation for: \(entry.result.sourceSentence)")
        }
    }
}

private struct IntensiveReadingTestCredentials: AICredentialStorage {
    func read() throws -> String? { nil }
    func write(_ value: String) throws {}
}

private struct IntensiveReadingTestCustomCredentials: AICustomCredentialStorage {
    func read(profileID: UUID) throws -> String? { nil }
    func write(_ value: String?, profileID: UUID) throws {}
}

private struct IntensiveReadingTestAIClient: AICustomServing {
    func fetchModels(baseURL: String, apiKey: String) async throws -> [String] { [] }

    func explain(selection: String, context: String, focusedSentence: String?,
                 purpose: AIExplanationPurpose, configuration: AIConfiguration) async throws -> String {
        throw AIError.invalidResponse
    }
}

@MainActor
private final class IntensiveReadingFixture {
    let root: URL
    let suite: String
    let defaults: UserDefaults
    let store: ReadingLibraryStore
    let settings: AISettingsStore
    let language: AppLanguageStore
    let client = IntensiveReadingGatedClient()
    let pool = IntensiveReadingModelPool()
    let firstArticle: LibraryArticle
    let secondArticle: LibraryArticle
    let firstSource = "A short sentence."
    let secondSource = "Another different sentence."

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString,
                                                                            isDirectory: true)
        suite = "IntensiveReadingFixture.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        store = try ReadingLibraryStore(rootURL: root, bundledCollections: [])
        firstArticle = try store.addMarkdown(markdown: "# First\n\nA short sentence.", sourceName: "first.md")
        secondArticle = try store.addMarkdown(markdown: "# Second\n\nAnother different sentence.",
                                              sourceName: "second.md")
        language = AppLanguageStore(defaults: defaults)
        settings = AISettingsStore(defaults: defaults,
                                   credentials: IntensiveReadingTestCredentials(),
                                   language: language,
                                   customCredentials: IntensiveReadingTestCustomCredentials(),
                                   customClient: client)
        try settings.saveCustomProfile(name: "Synthetic", baseURL: "https://intensive.example/v1",
                                        apiKey: "", model: "synthetic", authentication: .none)
    }

    func model(for article: LibraryArticle) -> IntensiveReadingModel {
        pool.model(for: article, profileID: store.archive.id, store: store, settings: settings)
    }

    func cleanUp() {
        pool.cancelAll()
        client.cancelPending()
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }
}

@MainActor
private final class IntensiveReadingGatedClient: AICustomServing {
    private struct Input: Decodable {
        let id: Int
        let source: String
    }
    private struct Pending {
        let items: [Input]
        let continuation: CheckedContinuation<String, Error>
    }
    private var pending: [String: Pending] = [:]
    private(set) var requestCount = 0
    var onRequest: ((String) -> Void)?

    func fetchModels(baseURL: String, apiKey: String) async throws -> [String] { [] }

    func explain(selection: String, context: String, focusedSentence: String?,
                 purpose: AIExplanationPurpose, configuration: AIConfiguration) async throws -> String {
        let items = try JSONDecoder().decode([Input].self, from: Data(selection.utf8))
        let source = try XCTUnwrap(items.first?.source)
        requestCount += 1
        return try await withCheckedThrowingContinuation { continuation in
            pending[source] = Pending(items: items, continuation: continuation)
            onRequest?(source)
        }
    }

    func complete(source: String) throws {
        let request = try XCTUnwrap(pending.removeValue(forKey: source))
        let response: [String: Any] = ["sentences": request.items.map {
            ["id": $0.id, "translation": "合成译文：\($0.source)", "links": []] as [String: Any]
        }]
        let data = try JSONSerialization.data(withJSONObject: response)
        request.continuation.resume(returning: String(decoding: data, as: UTF8.self))
    }

    func fail(source: String) throws {
        let request = try XCTUnwrap(pending.removeValue(forKey: source))
        request.continuation.resume(throwing: AIError.invalidResponse)
    }

    func cancelPending() {
        let requests = Array(pending.values)
        pending.removeAll()
        for request in requests { request.continuation.resume(throwing: CancellationError()) }
    }
}
