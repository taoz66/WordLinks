import Foundation
import XCTest
@testable import ReadingToolDaily

@MainActor
final class ReadingLibraryStoreTests: XCTestCase {
    func testCardKeepsUnicodeScalarSourcePositionAndRejectsOverlap() throws {
        let (root, cleanup) = temporaryDirectory()
        defer { cleanup() }
        let store = try ReadingLibraryStore(rootURL: root, bundledCollections: [])
        let article = try store.addMarkdown(markdown: "# Notes\n\nA café 🙂 world to remember.", sourceName: "notes.md")
        let range = (article.text as NSString).range(of: "world")

        let card = try store.saveCard(articleID: article.id, range: range, expression: "world", meaning: "世界")

        XCTAssertEqual(card.selectedText, "world")
        let prefix = (article.text as NSString).substring(to: range.location)
        XCTAssertEqual(card.start, prefix.unicodeScalars.count)
        XCTAssertThrowsError(try store.saveCard(articleID: article.id, range: range,
                                                expression: "planet", meaning: "星球")) { error in
            guard case ReadingLibraryError.overlappingCard = error else {
                return XCTFail("Expected overlappingCard, got \(error)")
            }
        }
    }

    func testProfilesImportAsIndependentLocalCopiesAndAggregateSourcesByMeaning() throws {
        let (root, cleanup) = temporaryDirectory()
        defer { cleanup() }
        let store = try ReadingLibraryStore(rootURL: root, bundledCollections: [])
        let article = try store.addMarkdown(markdown: "# Notes\n\nTo make progress.", sourceName: "notes.md")
        let range = (article.text as NSString).range(of: "progress")
        try store.saveCard(articleID: article.id, range: range, expression: "make progress", meaning: "取得进展")

        XCTAssertEqual(store.entries.count, 1)
        XCTAssertEqual(store.entries[0].meanings.first?.sources.map(\.id), [article.id])

        let exportURL = root.appendingPathComponent("backup.json")
        try store.exportActiveProfile(to: exportURL)
        let imported = try store.importProfile(from: exportURL)
        XCTAssertNotEqual(imported.id, store.profiles.first?.id)
        XCTAssertEqual(store.archive.articles.count, 1)
        XCTAssertEqual(store.archive.cards.count, 1)

        try store.createProfile(name: "Blank")
        XCTAssertTrue(store.archive.articles.isEmpty)
        try store.selectProfile(imported.id)
        XCTAssertEqual(store.archive.cards.count, 1)
    }

    func testAutomaticBackupsAreBoundedAndFolderDeletionReturnsArticlesToRoot() throws {
        let (root, cleanup) = temporaryDirectory()
        defer { cleanup() }
        let store = try ReadingLibraryStore(rootURL: root, bundledCollections: [])
        let folder = try store.createFolder(name: "Essays")
        let article = try store.addMarkdown(markdown: "# Notes\n\nA short article.",
                                            sourceName: "notes.md", folderID: folder.id)

        for offset in 0..<15 {
            try store.setReadOffset(offset, articleID: article.id)
        }
        let mostRecentBackup = try XCTUnwrap(store.automaticBackups().first)
        try store.restoreAutomaticBackup(from: mostRecentBackup)
        try store.deleteFolder(folder.id)

        XCTAssertNil(store.archive.articles.first(where: { $0.id == article.id })?.folderID)
        XCTAssertEqual(store.archive.articles.first(where: { $0.id == article.id })?.readOffset, 13)
        let backupFolder = root.appendingPathComponent("Profiles/\(store.archive.id.uuidString)/Backups")
        let backups = try FileManager.default.contentsOfDirectory(at: backupFolder, includingPropertiesForKeys: nil)
        XCTAssertLessThanOrEqual(backups.count, ReadingLibraryStore.backupLimit)
        XCTAssertFalse(store.archive.folders.contains(where: { $0.id == folder.id }))
    }

    func testIntensiveTranslationsPersistOutsideTheLibraryArchive() throws {
        let (root, cleanup) = temporaryDirectory()
        defer { cleanup() }
        let store = try ReadingLibraryStore(rootURL: root, bundledCollections: [])
        let article = try store.addMarkdown(markdown: "# Notes\n\nWe gave up.", sourceName: "notes.md")
        let source = "We gave up."
        let target = "我们放弃了。"
        let result = IntensiveReadingTranslation(sourceSentence: source, translation: target, alignments: [
            IntensiveReadingAlignment(
                sourceRanges: [IntensiveReadingSpan(location: 3, length: 4),
                               IntensiveReadingSpan(location: 8, length: 2)],
                targetRanges: [IntensiveReadingSpan(location: 2, length: 3)]
            )
        ], generatedAt: Date())

        try store.saveIntensiveTranslation(result, articleID: article.id, targetLanguage: .chinese)

        let cacheURL = root.appendingPathComponent("Profiles/\(store.archive.id.uuidString)/intensive-reading.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: cacheURL.path))
        let loaded = try XCTUnwrap(store.intensiveTranslations(articleID: article.id, targetLanguage: .chinese)[source])
        XCTAssertEqual(loaded.sourceSentence, result.sourceSentence)
        XCTAssertEqual(loaded.translation, result.translation)
        XCTAssertEqual(loaded.alignments, result.alignments)
        XCTAssertLessThan(abs(loaded.generatedAt.timeIntervalSince(result.generatedAt)), 1)
        XCTAssertTrue(try store.intensiveTranslations(articleID: article.id, targetLanguage: .english).isEmpty)
        let stale = IntensiveReadingTranslation(sourceSentence: "No longer in this article.",
                                                translation: "不属于本文。", alignments: [], generatedAt: Date())
        XCTAssertThrowsError(try store.saveIntensiveTranslation(stale, articleID: article.id,
                                                                 targetLanguage: .chinese))
        let archiveJSON = String(decoding: try Data(contentsOf: root.appendingPathComponent(
            "Profiles/\(store.archive.id.uuidString)/library.json")), as: UTF8.self)
        XCTAssertFalse(archiveJSON.contains("intensiveTranslations"))
    }

    private func temporaryDirectory() -> (URL, () -> Void) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        return (url, { try? FileManager.default.removeItem(at: url) })
    }
}
