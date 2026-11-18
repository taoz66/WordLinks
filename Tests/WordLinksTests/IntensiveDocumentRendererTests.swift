import AppKit
import XCTest
@testable import WordLinks

final class IntensiveDocumentRendererTests: XCTestCase {
    @MainActor
    func testRendererReusesUnchangedDocumentAndRefreshesTranslationAlignment() {
        let renderer = IntensiveDocumentRenderer()
        let article = makeArticle()
        let sentence = makeSentence(for: article.text)

        let waiting = render(renderer, article: article, sentence: sentence)
        var progressedArticle = article
        progressedArticle.readOffset = 8
        let unchanged = render(renderer, article: progressedArticle, sentence: sentence)
        XCTAssertTrue(waiting.attributedText === unchanged.attributedText)

        let translation = IntensiveReadingTranslation(sourceSentence: sentence.source,
                                                       translation: "一条短句。",
                                                       alignments: [],
                                                       generatedAt: Date(timeIntervalSince1970: 0))
        let translated = render(renderer, article: article, sentence: sentence,
                                translations: [sentence.id: translation])
        XCTAssertNotEqual(waiting.attributedText.string, translated.attributedText.string)

        let aligned = IntensiveReadingTranslation(sourceSentence: sentence.source,
                                                   translation: translation.translation,
                                                   alignments: [IntensiveReadingAlignment(
                                                    sourceRanges: [IntensiveReadingSpan(location: 0, length: 1)],
                                                    targetRanges: [IntensiveReadingSpan(location: 0, length: 1)]
                                                   )],
                                                   generatedAt: translation.generatedAt)
        let realigned = render(renderer, article: article, sentence: sentence,
                               translations: [sentence.id: aligned])
        XCTAssertEqual(translated.attributedText.string, realigned.attributedText.string)
        XCTAssertFalse(translated.attributedText === realigned.attributedText)
        XCTAssertEqual(realigned.alignments.count, 1)
    }

    @MainActor
    func testRendererInvalidatesForCardAndReadingStyleChanges() {
        let renderer = IntensiveDocumentRenderer()
        let article = makeArticle()
        let sentence = makeSentence(for: article.text)
        let baseline = render(renderer, article: article, sentence: sentence)
        let cardRange = (article.text as NSString).range(of: "short")
        let card = StudyCard(articleID: article.id, start: cardRange.location,
                             end: NSMaxRange(cardRange), selectedText: "short",
                             expression: "short", meaning: "短的")

        let highlighted = render(renderer, article: article, sentence: sentence, cards: [card])
        XCTAssertFalse(baseline.attributedText === highlighted.attributedText)
        let displayRange = highlighted.displayRanges(forArticleRange: cardRange)[0]
        XCTAssertNotNil(highlighted.attributedText.attribute(.backgroundColor,
                                                             at: displayRange.location, effectiveRange: nil))

        let focused = render(renderer, article: article, sentence: sentence,
                             cards: [card], readingStyle: .focus)
        XCTAssertFalse(highlighted.attributedText === focused.attributedText)
    }

    @MainActor
    func testRendererRefreshesTypographyAndLocalizedWaitingText() {
        let renderer = IntensiveDocumentRenderer()
        let article = makeArticle()
        let sentence = makeSentence(for: article.text)
        let baseline = render(renderer, article: article, sentence: sentence)
        var typography = ReadingViewStyle.standard.defaultTypography
        typography.fontSize += 2
        let resized = render(renderer, article: article, sentence: sentence, typography: typography)
        XCTAssertFalse(baseline.attributedText === resized.attributedText)
        let displayRange = resized.displayRanges(forArticleRange: sentence.sourceRange)[0]
        let font = resized.attributedText.attribute(.font, at: displayRange.location,
                                                    effectiveRange: nil) as? NSFont
        XCTAssertEqual(font?.pointSize, CGFloat(typography.fontSize))

        let localized = render(renderer, article: article, sentence: sentence,
                               typography: typography, waitingText: "正在等待译文…")
        XCTAssertFalse(resized.attributedText === localized.attributedText)
        XCTAssertTrue(localized.attributedText.string.contains("正在等待译文…"))
    }

    @MainActor
    func testRendererRefreshesMetadataWhilePreservingSourceMapping() {
        let renderer = IntensiveDocumentRenderer()
        let article = makeArticle()
        let sentence = makeSentence(for: article.text)
        let baseline = render(renderer, article: article, sentence: sentence)
        let revised = LibraryArticle(id: article.id, title: article.title, sourceName: article.sourceName,
                                     markdown: "# Test\nAuthor: A Writer\n\nA short sentence.",
                                     text: article.text)
        let refreshed = render(renderer, article: revised, sentence: sentence)
        XCTAssertFalse(baseline.attributedText === refreshed.attributedText)
        XCTAssertTrue(baseline.attributedText.isEqual(to: refreshed.attributedText))
        XCTAssertEqual(renderer.metadata.author, "A Writer")
        let display = refreshed.displayRanges(forArticleRange: sentence.sourceRange)[0]
        XCTAssertEqual(refreshed.articleRange(forDisplayRange: display), sentence.sourceRange)
    }

    @MainActor
    func testRendererPreservesLegacyHeaderLikeProseAndSelectionRanges() throws {
        let renderer = IntensiveDocumentRenderer()
        let markdown = "# Legacy\n\nAuthor: a character\n\nA café 🙂 makes progress."
        let text = "Legacy\n\nAuthor: a character\n\nA café 🙂 makes progress."
        let article = LibraryArticle(title: "Legacy", sourceName: "legacy.md",
                                     markdown: markdown, text: text)
        XCTAssertNotEqual(try ArticleMarkdownDocument.parse(markdown).text, article.text)
        let range = (text as NSString).range(of: "A café 🙂 makes progress.")
        let sentence = IntensiveSentence(id: 0, sourceRange: range,
                                          source: (text as NSString).substring(with: range))
        let document = render(renderer, article: article, sentence: sentence)
        XCTAssertEqual(renderer.metadata, ArticleMetadata())
        XCTAssertTrue(document.attributedText.string.contains("Author: a character"))
        let display = try XCTUnwrap(document.displayRanges(forArticleRange: range).first)
        XCTAssertEqual((document.attributedText.string as NSString).substring(with: display), sentence.source)
        XCTAssertEqual(document.articleRange(forDisplayRange: display), range)
    }

    private func makeArticle() -> LibraryArticle {
        let source = "A short sentence."
        return LibraryArticle(title: "Test", sourceName: "test.md",
                              markdown: "# Test\n\n\(source)", text: "Test\n\n\(source)")
    }

    private func makeSentence(for source: String) -> IntensiveSentence {
        let body = "A short sentence."
        return IntensiveSentence(id: 0, sourceRange: (source as NSString).range(of: body), source: body)
    }

    @MainActor
    private func render(_ renderer: IntensiveDocumentRenderer, article: LibraryArticle,
                        sentence: IntensiveSentence,
                        translations: [Int: IntensiveReadingTranslation] = [:],
                        cards: [StudyCard] = [],
                        readingStyle: ReadingViewStyle = .standard,
                        typography: ReadingTypography? = nil,
                        waitingText: String = "Waiting") -> IntensiveRenderDocument {
        renderer.document(article: article, sentences: [sentence], translations: translations,
                          cards: cards, readingStyle: readingStyle,
                          typography: typography ?? readingStyle.defaultTypography, waitingText: waitingText)
    }
}
