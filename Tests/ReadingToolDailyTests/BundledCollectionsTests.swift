import Foundation
import XCTest
@testable import ReadingToolDaily

@MainActor
final class BundledCollectionsTests: XCTestCase {
    func testFreshAndNewProfilesEachReceiveIndependentIELTSArticles() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let collection = fixture()
        let store = try ReadingLibraryStore(rootURL: root, bundledCollections: [collection])
        let originalID = store.activeProfileID
        let originalFolder = try XCTUnwrap(store.folders.first)

        XCTAssertEqual(store.folders.map(\.name), ["IELTS"])
        XCTAssertEqual(store.articles.map(\.id), collection.articles.map(\.id))
        XCTAssertTrue(store.articles.allSatisfy { $0.folderID == originalFolder.id })
        XCTAssertEqual(store.articles.map(\.sourceURL), collection.articles.map { Optional($0.sourceURL) })
        XCTAssertEqual(store.archive.seededCollections, [collection.id])
        XCTAssertNil(store.archive.lastArticleID)

        try store.createProfile(name: "Second reader")
        XCTAssertEqual(store.articles.count, 2)
        XCTAssertEqual(store.archive.seededCollections, [collection.id])
        XCTAssertNotEqual(store.folders.first?.id, originalFolder.id)
        try store.deleteArticle(collection.articles[0].id)
        try store.selectProfile(originalID)
        XCTAssertEqual(store.articles.count, 2)
    }

    func testExistingProfileReusesFolderAndPreservesArticleTextCardsProgressAndSelection() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let oldStore = try ReadingLibraryStore(rootURL: root, bundledCollections: [])
        let folder = try oldStore.createFolder(name: "IELTS")
        let original = try oldStore.addMarkdown(markdown: "# My version\n\nKeep this original passage.",
                                               sourceName: "original.md", folderID: folder.id)
        let card = try oldStore.saveCard(articleID: original.id,
                                        range: (original.text as NSString).range(of: "original"),
                                        expression: "original", meaning: "原始的")
        try oldStore.setReadOffset(12, articleID: original.id)
        let preserved = try persisted(XCTUnwrap(oldStore.article(id: original.id)))
        let collection = fixture(firstArticleID: original.id)

        let store = try ReadingLibraryStore(rootURL: root, bundledCollections: [collection])

        XCTAssertEqual(store.folders, [try persisted(folder)])
        XCTAssertEqual(store.article(id: original.id), preserved)
        XCTAssertEqual(store.cards, [try persisted(card)])
        XCTAssertEqual(store.archive.lastArticleID, original.id)
        XCTAssertEqual(store.articles.count, 2)
        XCTAssertEqual(store.article(id: collection.articles[1].id)?.folderID, folder.id)
        XCTAssertEqual(store.archive.seededCollections, [collection.id])
    }

    func testExistingInactiveProfileIsSeededWhenSelected() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let oldStore = try ReadingLibraryStore(rootURL: root, bundledCollections: [])
        let originalID = oldStore.activeProfileID
        try oldStore.createProfile(name: "Another existing reader")
        let collection = fixture()

        let store = try ReadingLibraryStore(rootURL: root, bundledCollections: [collection])
        XCTAssertEqual(store.articles.count, 2)
        try store.selectProfile(originalID)
        XCTAssertEqual(store.articles.count, 2)
        XCTAssertEqual(store.archive.seededCollections, [collection.id])
    }

    func testRestartDoesNotDuplicateOrRecreateDeletedArticlesAndFolder() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let collection = fixture()
        let first = try ReadingLibraryStore(rootURL: root, bundledCollections: [collection])
        let seeded = first.archive
        let firstBackupCount = first.automaticBackups().count
        let reopened = try ReadingLibraryStore(rootURL: root, bundledCollections: [collection])
        XCTAssertEqual(reopened.archive, seeded)
        XCTAssertEqual(reopened.automaticBackups().count, firstBackupCount)

        try reopened.deleteArticle(collection.articles[0].id)
        try reopened.deleteFolder(try XCTUnwrap(reopened.folders.first).id)
        let afterDeletion = reopened.archive
        let third = try ReadingLibraryStore(rootURL: root, bundledCollections: [collection])

        XCTAssertEqual(third.archive, afterDeletion)
        XCTAssertTrue(third.folders.isEmpty)
        XCTAssertEqual(third.articles.map(\.id), [collection.articles[1].id])
        XCTAssertNil(third.articles.first?.folderID)
    }

    func testLegacyJSONWithoutMetadataRemainsReadableAndReceivesTheCollection() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let oldStore = try ReadingLibraryStore(rootURL: root, bundledCollections: [])
        let article = try oldStore.addMarkdown(markdown: "# Existing\n\nAn older saved article.", sourceName: "old.md")
        let path = root.appendingPathComponent("Profiles/\(oldStore.activeProfileID.uuidString)/library.json")
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any])
        legacy.removeValue(forKey: "seededCollections")
        var legacyArticles = try XCTUnwrap(legacy["articles"] as? [[String: Any]])
        legacyArticles[0].removeValue(forKey: "sourceURL")
        legacy["articles"] = legacyArticles
        try JSONSerialization.data(withJSONObject: legacy).write(to: path, options: .atomic)

        let store = try ReadingLibraryStore(rootURL: root, bundledCollections: [fixture()])

        XCTAssertEqual(store.article(id: article.id), try persisted(article))
        XCTAssertNil(store.article(id: article.id)?.sourceURL)
        XCTAssertEqual(store.articles.count, 3)
        XCTAssertEqual(store.archive.seededCollections, [fixture().id])
    }

    func testExportImportAndBackupRestoreKeepSeedMarkerSourcesAndUserDeletions() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let collection = fixture()
        let store = try ReadingLibraryStore(rootURL: root, bundledCollections: [collection])
        let originalProfileID = store.activeProfileID
        let keptID = collection.articles[1].id
        try store.deleteArticle(collection.articles[0].id)
        try store.setReadOffset(5, articleID: keptID)
        let exportURL = root.appendingPathComponent("export.json")
        try store.exportActiveProfile(to: exportURL)
        let originalArchive = store.archive

        try store.importProfile(from: exportURL)
        XCTAssertEqual(store.articles, originalArchive.articles)
        XCTAssertEqual(store.archive.seededCollections, originalArchive.seededCollections)
        XCTAssertEqual(store.articles.first?.sourceURL, collection.articles[1].sourceURL)

        try store.selectProfile(originalProfileID)
        try store.setReadOffset(8, articleID: keptID)
        let backup = try XCTUnwrap(store.automaticBackups().first)
        try store.deleteArticle(keptID)
        try store.restoreAutomaticBackup(from: backup)
        XCTAssertEqual(store.archive, originalArchive)
        let reopened = try ReadingLibraryStore(rootURL: root, bundledCollections: [collection])
        XCTAssertEqual(reopened.archive, originalArchive)
    }

    func testLegacyImportedProfileAndLegacyBackupGetMissingArticles() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let collection = fixture()
        let store = try ReadingLibraryStore(rootURL: root, bundledCollections: [collection])
        let legacy = ProfileArchive(id: UUID(), name: "Old exported reader")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var legacyObject = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(legacy)) as? [String: Any])
        legacyObject.removeValue(forKey: "seededCollections")
        let exportURL = root.appendingPathComponent("legacy.json")
        try JSONSerialization.data(withJSONObject: legacyObject).write(to: exportURL)

        try store.importProfile(from: exportURL)
        XCTAssertEqual(store.articles.count, 2)
        XCTAssertEqual(store.archive.seededCollections, [collection.id])

        let backupDirectory = root.appendingPathComponent("Profiles/\(store.activeProfileID.uuidString)/Backups")
        try FileManager.default.createDirectory(at: backupDirectory, withIntermediateDirectories: true)
        legacyObject["id"] = store.activeProfileID.uuidString
        let backupURL = backupDirectory.appendingPathComponent("legacy.json")
        try JSONSerialization.data(withJSONObject: legacyObject).write(to: backupURL)
        try store.restoreAutomaticBackup(from: backupURL)
        XCTAssertEqual(store.articles.count, 2)
        XCTAssertEqual(store.archive.seededCollections, [collection.id])
    }

    func testProductionCatalogHasFiftyAttributedLicensedArticlesAcrossThreeCollections() throws {
        let collections = try BundledArticleCollection.load()
        XCTAssertEqual(collections.map(\.folderName), ["Global Voices", "Wikipedia", "PLOS"])
        XCTAssertEqual(collections.map { $0.articles.count }, [5, 30, 15])
        XCTAssertEqual(collections.map(\.id), [
            "global-voices-reading-2026-11-v1",
            "wikipedia-featured-reading-2026-11-v1",
            "plos-reading-2026-11-v2"
        ])
        let all = collections.flatMap(\.articles)
        XCTAssertEqual(all.count, 50)
        XCTAssertEqual(Set(all.map(\.id)).count, 50)
        XCTAssertEqual(Set(all.map(\.sourceURL)).count, 50)
        let expectedLicenses: [String: String] = [
            "Global Voices": "License: [CC BY 3.0](https://creativecommons.org/licenses/by/3.0/).",
            "Wikipedia": "License: [CC BY-SA 4.0](https://creativecommons.org/licenses/by-sa/4.0/).",
            "PLOS": "License: [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/)."
        ]
        for collection in collections {
            let expectedLicense = try XCTUnwrap(expectedLicenses[collection.folderName])
            for article in collection.articles {
                XCTAssertTrue(article.markdown.hasPrefix("# \(article.title)\n\nAuthor: "), article.file)
                XCTAssertTrue(article.markdown.contains("\nDate: "), article.file)
                XCTAssertTrue(article.markdown.contains("\nSource: [\(collection.folderName)](\(article.sourceURL))\n"), article.file)
                XCTAssertFalse(article.markdown.contains("## Source and license"), article.file)
                XCTAssertTrue(article.markdown.contains("Edited for reading;"), article.file)
                XCTAssertTrue(article.markdown.contains(expectedLicense), article.file)
                let parsed = try ArticleMarkdownDocument.parse(article.markdown)
                XCTAssertEqual(parsed.blocks.last?.kind, .license, article.file)
                XCTAssertNil(parsed.text.range(of: "https?://", options: .regularExpression), article.file)
                let body = article.markdown.components(separatedBy: "\n\n").dropFirst(2).dropLast().joined(separator: "\n\n")
                XCTAssertNil(body.range(of: #"https?://|\[\d[\d, –-]*\]"#, options: .regularExpression), article.file)
                XCTAssertGreaterThan(article.markdown.split(whereSeparator: \.isWhitespace).count, 700, article.file)
            }
        }
    }

    func testLocalCollectionsInRootDirectoryAreLoadedBeforeBundledCollections() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let localIELTS = root.appendingPathComponent("LocalCollections/IELTS", isDirectory: true)
        try FileManager.default.createDirectory(at: localIELTS, withIntermediateDirectories: true)
        let markdown = "# Local passage\n\nA locally preserved reading passage for personal practice.\n"
        try Data(markdown.utf8).write(to: localIELTS.appendingPathComponent("local-passage.md"), options: .atomic)
        let catalog = """
        {
          "id": "ielts-local-v1",
          "folderName": "IELTS",
          "collectionURL": "https://mini-ielts.com/zyz?c=recent-actual-tests",
          "articles": [
            {
              "id": "712F67FD-8743-56E3-9264-A10B163F42BD",
              "file": "local-passage.md",
              "title": "Local passage",
              "sourceURL": "https://mini-ielts.com/1518/reading/australian-artist-margaret-preston"
            }
          ]
        }
        """
        try Data(catalog.utf8).write(to: localIELTS.appendingPathComponent("catalog.json"), options: .atomic)

        let store = try ReadingLibraryStore(rootURL: root)
        XCTAssertEqual(store.folders.map(\.name), ["IELTS", "Global Voices", "Wikipedia", "PLOS"])
        XCTAssertEqual(store.articles.count, 51)
    }

    func testLicensedCollectionsUpgradeExistingProfilesOnceAndSeedNewProfilesIndependently() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let collections = try BundledArticleCollection.load()
        let oldStore = try ReadingLibraryStore(rootURL: root, bundledCollections: [try XCTUnwrap(collections.first)])
        let originalProfileID = oldStore.activeProfileID
        let original = try oldStore.addMarkdown(markdown: "# Personal article\n\nKeep this original passage.", sourceName: "personal.md")
        let card = try oldStore.saveCard(articleID: original.id,
                                        range: (original.text as NSString).range(of: "original"),
                                        expression: "original", meaning: "原始的")
        try oldStore.setReadOffset(5, articleID: original.id)
        let preservedArticle = try persisted(XCTUnwrap(oldStore.article(id: original.id)))
        let preservedCard = try persisted(card)

        let upgraded = try ReadingLibraryStore(rootURL: root, bundledCollections: collections)
        XCTAssertEqual(upgraded.articles.count, 51)
        XCTAssertEqual(upgraded.folders.map(\.name), ["Global Voices", "Wikipedia", "PLOS"])
        XCTAssertEqual(upgraded.article(id: original.id), preservedArticle)
        XCTAssertEqual(upgraded.cards, [preservedCard])
        XCTAssertEqual(upgraded.archive.lastArticleID, original.id)
        XCTAssertEqual(upgraded.archive.seededCollections, collections.map(\.id))

        let deletedID = try XCTUnwrap(collections.first(where: { $0.folderName == "Global Voices" })?.articles.first?.id)
        try upgraded.deleteArticle(deletedID)
        let deletedFolderID = try XCTUnwrap(upgraded.folders.first(where: { $0.name == "Global Voices" })?.id)
        try upgraded.deleteFolder(deletedFolderID)
        // Newly seeded articles still have subsecond in-memory timestamps;
        // the archive's ISO-8601 writer intentionally persists whole seconds.
        let afterDeletion = try persisted(upgraded.archive)
        let reopened = try ReadingLibraryStore(rootURL: root, bundledCollections: collections)
        XCTAssertEqual(reopened.archive, afterDeletion)
        XCTAssertNil(reopened.article(id: deletedID))
        XCTAssertFalse(reopened.folders.contains { $0.name == "Global Voices" })

        try reopened.createProfile(name: "Fresh licensed reader")
        XCTAssertEqual(reopened.articles.count, 50)
        XCTAssertEqual(reopened.folders.map(\.name), ["Global Voices", "Wikipedia", "PLOS"])
        XCTAssertNotNil(reopened.article(id: deletedID))
        try reopened.selectProfile(originalProfileID)
        XCTAssertNil(reopened.article(id: deletedID))
        XCTAssertEqual(reopened.article(id: original.id), preservedArticle)
        XCTAssertEqual(reopened.cards, [preservedCard])
    }

    private func fixture(firstArticleID: UUID = UUID(uuidString: "99999999-1111-4444-8888-111111111111")!) -> BundledArticleCollection {
        BundledArticleCollection(id: "ielts-test-v1", folderName: "IELTS", articles: [
            BundledArticle(id: firstArticleID, file: "first.md", title: "First passage",
                           sourceURL: "https://mini-ielts.com/first",
                           markdown: "# First passage\n\nAn example IELTS reading passage."),
            BundledArticle(id: UUID(uuidString: "99999999-2222-4444-8888-222222222222")!,
                           file: "second.md", title: "Second passage",
                           sourceURL: "https://mini-ielts.com/second",
                           markdown: "# Second passage\n\nAnother example IELTS reading passage.")
        ])
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    private func persisted<T: Codable>(_ value: T) throws -> T {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(T.self, from: encoder.encode(value))
    }
}
