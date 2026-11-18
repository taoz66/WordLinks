import Foundation
import XCTest
@testable import ReadingToolDaily

@MainActor
final class BundledContentMigrationTests: XCTestCase {
    private let articleID = UUID(uuidString: "70DCBE95-0873-5A8C-A32E-4C2F900A0892")!
    private let deletedID = UUID(uuidString: "0FE2C1A3-3F4C-5A3C-A1D9-EABD4B411520")!
    private let originalMarkdown = "# Notes\n\nAuthor: A Writer\nDate: 2026-11-11\nSource: [Global Voices](https://globalvoices.org/notes/)\n\nA café reader [1] keeps careful notes.\n\n## Source and license\n\nA lengthy old license notice.\n"
    private let cleanedMarkdown = "# Notes\n\nAuthor: A Writer\nDate: 2026-11-11\nSource: [Global Voices](https://globalvoices.org/notes/)\n\nA café reader keeps careful notes.\n\nLicense: CC BY 3.0. Reading edition: references omitted.\n"

    func testExactBundledRevisionKeepsMovedArticleCardsAndReadingAnchorWithoutReseedingDeletion() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let old = try ReadingLibraryStore(rootURL: root, bundledCollections: [collection(cleaned: false, includeSecond: true)])
        let source = try XCTUnwrap(old.article(id: articleID))
        let notes = try old.saveCard(articleID: articleID, range: (source.text as NSString).range(of: "careful notes"),
                                     expression: "careful notes", meaning: "仔细的笔记")
        let citation = try old.saveCard(articleID: articleID, range: (source.text as NSString).range(of: "[1]"),
                                        expression: "old citation", meaning: "Keep this saved card")
        try old.setReadOffset(articleID: articleID, offset: notes.start + 2)
        let customFolder = try old.createFolder(name: "My saved reports")
        try old.moveArticle(articleID, to: customFolder.id)
        try old.deleteArticle(deletedID)
        let originalDate = try persisted(source).createdAt
        let file = try old.articleFileURL(articleID)

        let upgraded = try ReadingLibraryStore(rootURL: root, bundledCollections: [collection(cleaned: true, includeSecond: true)])
        let article = try XCTUnwrap(upgraded.article(id: articleID))
        let card = try XCTUnwrap(upgraded.card(id: notes.id))
        XCTAssertEqual(upgraded.articles.count, 1)
        XCTAssertNil(upgraded.article(id: deletedID))
        XCTAssertEqual(article.id, articleID)
        XCTAssertEqual(article.folderID, customFolder.id)
        XCTAssertEqual(article.createdAt, originalDate)
        XCTAssertEqual(article.markdown, cleanedMarkdown)
        XCTAssertEqual(article.metadata.author, "A Writer")
        let selection = try XCTUnwrap(article.text.range(of: "careful notes"))
        let expectedStart = article.text[..<selection.lowerBound].unicodeScalars.count
        XCTAssertEqual(card.start, expectedStart)
        XCTAssertEqual(card.end, expectedStart + "careful notes".unicodeScalars.count)
        XCTAssertEqual(card.selectedText, notes.selectedText)
        XCTAssertEqual(card.meaning, notes.meaning)
        XCTAssertNotEqual(card.isDetached, true)
        XCTAssertEqual(article.readOffset, expectedStart + 2)
        let detached = try XCTUnwrap(upgraded.card(id: citation.id))
        XCTAssertEqual(detached.selectedText, "[1]")
        XCTAssertEqual(detached.meaning, citation.meaning)
        XCTAssertEqual(detached.isDetached, true)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), cleanedMarkdown)
        XCTAssertEqual(upgraded.archive.seededCollections, ["global-voices-fixture-v1"])

        let snapshot = try persisted(upgraded.archive)
        let backups = upgraded.automaticBackups().count
        let reopened = try ReadingLibraryStore(rootURL: root, bundledCollections: [collection(cleaned: true, includeSecond: true)])
        XCTAssertEqual(reopened.archive, snapshot)
        XCTAssertEqual(reopened.automaticBackups().count, backups)
    }

    func testArchivedAndPendingManagedFileEditsTakePrecedenceOverBundledRevision() throws {
        for refreshFirst in [false, true] {
            let root = temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let old = try ReadingLibraryStore(rootURL: root, bundledCollections: [collection(cleaned: false)])
            let file = try old.articleFileURL(articleID)
            let edited = originalMarkdown.replacingOccurrences(of: "A café reader", with: "My own café reader")
            try Data(edited.utf8).write(to: file, options: .atomic)
            if refreshFirst { old.refreshArticleFiles() }

            let reopened = try ReadingLibraryStore(rootURL: root, bundledCollections: [collection(cleaned: true)])
            XCTAssertEqual(reopened.article(id: articleID)?.markdown, edited)
            XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), edited)
            XCTAssertTrue(reopened.fileSyncErrors.isEmpty)
        }
    }

    func testLinkedOriginalAndSameSourceWithDifferentIdentityAreNotReplaced() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let old = try ReadingLibraryStore(rootURL: root, bundledCollections: [collection(cleaned: false)])
        let external = root.appendingPathComponent("external.md")
        try Data(originalMarkdown.utf8).write(to: external, options: .atomic)
        var linked = old.archive
        linked.articles[0].sourceFilePath = external.path
        try writeArchive(linked, root: root)
        let reopened = try ReadingLibraryStore(rootURL: root, bundledCollections: [collection(cleaned: true)])
        XCTAssertEqual(reopened.article(id: articleID)?.markdown, originalMarkdown)
        XCTAssertEqual(reopened.article(id: articleID)?.sourceFilePath, external.path)
        XCTAssertEqual(try String(contentsOf: external, encoding: .utf8), originalMarkdown)

        // A user copy can share the original URL without being the distributed article.
        let secondRoot = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: secondRoot) }
        let user = try ReadingLibraryStore(rootURL: secondRoot, bundledCollections: [])
        let copy = try user.addMarkdown(markdown: originalMarkdown, sourceName: "my-copy.md")
        var snapshot = user.archive
        snapshot.articles[0].sourceURL = "https://globalvoices.org/notes/"
        snapshot.seededCollections = ["global-voices-fixture-v1"]
        try writeArchive(snapshot, root: secondRoot)
        let copyStore = try ReadingLibraryStore(rootURL: secondRoot, bundledCollections: [collection(cleaned: true)])
        XCTAssertEqual(copyStore.articles.map(\.id), [copy.id])
        XCTAssertEqual(copyStore.article(id: copy.id)?.markdown, originalMarkdown)
    }

    func testMissingManagedCopyAndImportedOrRestoredLegacySnapshotsReceiveTheRevision() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let old = try ReadingLibraryStore(rootURL: root, bundledCollections: [collection(cleaned: false)])
        let export = root.appendingPathComponent("old-profile.json")
        try old.exportActiveProfile(to: export)
        let file = try old.articleFileURL(articleID)
        try FileManager.default.removeItem(at: file)
        let upgraded = try ReadingLibraryStore(rootURL: root, bundledCollections: [collection(cleaned: true)])
        XCTAssertEqual(upgraded.article(id: articleID)?.markdown, cleanedMarkdown)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), cleanedMarkdown)

        let activeID = upgraded.activeProfileID
        let backupDirectory = root.appendingPathComponent("Profiles/\(activeID.uuidString)/Backups")
        try FileManager.default.createDirectory(at: backupDirectory, withIntermediateDirectories: true)
        let backup = backupDirectory.appendingPathComponent("legacy-content.json")
        try FileManager.default.copyItem(at: export, to: backup)
        try upgraded.restoreAutomaticBackup(from: backup)
        XCTAssertEqual(upgraded.article(id: articleID)?.markdown, cleanedMarkdown)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), cleanedMarkdown)

        try upgraded.importProfile(from: export)
        XCTAssertNotEqual(upgraded.activeProfileID, activeID)
        XCTAssertEqual(upgraded.article(id: articleID)?.markdown, cleanedMarkdown)
        XCTAssertEqual(try String(contentsOf: upgraded.articleFileURL(articleID), encoding: .utf8), cleanedMarkdown)
    }

    func testGlobalVoicesCatalogRecordsFiveDistinctLegacyRevisions() throws {
        let collection = try XCTUnwrap(BundledArticleCollection.load().first { $0.folderName == "Global Voices" })
        XCTAssertEqual(collection.articles.count, 5)
        let hashes = collection.articles.flatMap(\.previousMarkdownSHA256)
        XCTAssertEqual(hashes.count, 10)
        XCTAssertEqual(Set(hashes).count, 10)
        for article in collection.articles {
            XCTAssertEqual(article.previousMarkdownSHA256.count, 2, article.file)
            XCTAssertFalse(article.previousMarkdownSHA256.contains(BundledArticle.markdownSHA256(article.markdown)), article.file)
        }
    }

    private func collection(cleaned: Bool, includeSecond: Bool = false) -> BundledArticleCollection {
        var articles = [BundledArticle(id: articleID, file: "notes.md", title: "Notes",
            sourceURL: "https://globalvoices.org/notes/", markdown: cleaned ? cleanedMarkdown : originalMarkdown,
            previousMarkdownSHA256: cleaned ? [BundledArticle.markdownSHA256(originalMarkdown)] : [])]
        if includeSecond {
            let old = "# Deleted report\n\nA paragraph with a citation [2].\n"
            articles.append(BundledArticle(id: deletedID, file: "deleted.md", title: "Deleted report",
                sourceURL: "https://globalvoices.org/deleted/",
                markdown: cleaned ? "# Deleted report\n\nA paragraph with a citation.\n" : old,
                previousMarkdownSHA256: cleaned ? [BundledArticle.markdownSHA256(old)] : []))
        }
        return BundledArticleCollection(id: "global-voices-fixture-v1", folderName: "Global Voices", articles: articles)
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    private func writeArchive(_ archive: ProfileArchive, root: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(archive).write(to: root.appendingPathComponent("Profiles/\(archive.id.uuidString)/library.json"), options: .atomic)
    }

    private func persisted<T: Codable>(_ value: T) throws -> T {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(T.self, from: encoder.encode(value))
    }
}
