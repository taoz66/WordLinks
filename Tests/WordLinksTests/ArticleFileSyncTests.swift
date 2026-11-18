import Foundation
import XCTest
@testable import WordLinks

@MainActor
final class ArticleFileSyncTests: XCTestCase {
    func testAtomicExternalEditsRemapCardsAndPreserveDetachedVocabulary() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let libraryURL = directory.appendingPathComponent("Library", isDirectory: true)
        let sourceURL = directory.appendingPathComponent("notes.md")
        let originalMarkdown = "# Notes\n\nA café 🙂 makes progress today.\n"
        try Data(originalMarkdown.utf8).write(to: sourceURL, options: .atomic)
        let store = try ReadingLibraryStore(rootURL: libraryURL, bundledCollections: [])
        let articleID = try store.importMarkdown(from: sourceURL)
        let original = try XCTUnwrap(store.article(id: articleID))
        let selection = (original.text as NSString).range(of: "progress")
        let saved = try store.saveCard(articleID: articleID, range: selection,
                                       expression: "make progress", meaning: "取得进展")
        try store.setReadOffset(articleID: articleID, offset: saved.start)
        XCTAssertEqual(try store.articleFileURL(articleID), sourceURL.standardizedFileURL)

        // Atomic replacement changes the file identity, as many Markdown editors do.
        let editedMarkdown = "# Revised Notes\n\nA new introduction 🙂.\n\nA café 🙂 makes progress today.\n"
        try Data(editedMarkdown.utf8).write(to: sourceURL, options: .atomic)
        store.refreshArticleFiles()

        let revised = try XCTUnwrap(store.article(id: articleID))
        let remapped = try XCTUnwrap(store.card(id: saved.id))
        let newSelection = try XCTUnwrap(revised.text.range(of: "progress"))
        let expectedStart = revised.text[..<newSelection.lowerBound].unicodeScalars.count
        XCTAssertEqual(revised.title, "Revised Notes")
        XCTAssertEqual(revised.markdown, editedMarkdown)
        XCTAssertEqual(revised.text, "Revised Notes\n\nA new introduction 🙂.\n\nA café 🙂 makes progress today.")
        XCTAssertEqual(revised.readOffset, expectedStart)
        XCTAssertGreaterThan(remapped.start, saved.start)
        XCTAssertEqual(remapped.start, expectedStart)
        XCTAssertEqual(remapped.end, expectedStart + "progress".unicodeScalars.count)
        XCTAssertEqual(remapped.selectedText, "progress")
        XCTAssertEqual(remapped.meaning, saved.meaning)
        XCTAssertNotEqual(remapped.isDetached, true)

        let removedMarkdown = "# Revised Notes\n\nA new introduction 🙂.\n\nA café 🙂 keeps learning today.\n"
        try Data(removedMarkdown.utf8).write(to: sourceURL, options: .atomic)
        store.refreshArticleFiles()

        let detached = try XCTUnwrap(store.card(id: saved.id))
        XCTAssertEqual(store.article(id: articleID)?.markdown, removedMarkdown)
        XCTAssertEqual(detached.isDetached, true)
        XCTAssertEqual(detached.expression, saved.expression)
        XCTAssertEqual(detached.meaning, saved.meaning)
        XCTAssertEqual(detached.selectedText, saved.selectedText)
        XCTAssertEqual(store.entries.first?.cards.map(\.id), [saved.id])

        let reopened = try ReadingLibraryStore(rootURL: libraryURL, bundledCollections: [])
        XCTAssertEqual(reopened.card(id: saved.id)?.isDetached, true)
        XCTAssertEqual(reopened.card(id: saved.id)?.meaning, saved.meaning)
        XCTAssertEqual(reopened.article(id: articleID)?.markdown, removedMarkdown)
    }

    func testManagedArticleHasAnEditableFileThatRefreshesTheLibrary() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let libraryURL = directory.appendingPathComponent("Library", isDirectory: true)
        let store = try ReadingLibraryStore(rootURL: libraryURL, bundledCollections: [])
        let markdown = "# Local Notes\n\nAn offline reading passage.\n"
        let article = try store.addMarkdown(markdown: markdown, sourceName: "local.md")
        let fileURL = try store.articleFileURL(article.id)

        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
        XCTAssertTrue(fileURL.path.hasPrefix(libraryURL.path + "/"))
        XCTAssertEqual(fileURL.deletingLastPathComponent().lastPathComponent, article.id.uuidString)
        XCTAssertEqual(fileURL.lastPathComponent, "local.md")
        XCTAssertEqual(try String(contentsOf: fileURL, encoding: .utf8), markdown)

        let editedMarkdown = "# Updated Local Notes\n\nEdited in the managed Markdown file.\n"
        try Data(editedMarkdown.utf8).write(to: fileURL, options: .atomic)
        store.refreshArticleFiles()

        let revised = try XCTUnwrap(store.article(id: article.id))
        XCTAssertEqual(revised.title, "Updated Local Notes")
        XCTAssertEqual(revised.markdown, editedMarkdown)
        XCTAssertEqual(revised.text, "Updated Local Notes\n\nEdited in the managed Markdown file.")
        XCTAssertEqual(try store.articleFileURL(article.id), fileURL)
    }

    func testBundledTitleUpgradeKeepsTitleCardProgressAndManagedFileInSync() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let articleID = UUID()
        let body = "The importance of law shapes communities."
        func collection(title: String) -> BundledArticleCollection {
            BundledArticleCollection(id: "title-upgrade-v1", folderName: "IELTS", articles: [
                BundledArticle(id: articleID, file: "law.md", title: title,
                               sourceURL: "https://mini-ielts.com/test-law",
                               markdown: "# \(title)\n\n\(body)\n")
            ])
        }
        let old = try ReadingLibraryStore(rootURL: directory,
                                          bundledCollections: [collection(title: "The importance of law")])
        let article = try XCTUnwrap(old.article(id: articleID))
        let saved = try old.saveCard(articleID: articleID,
                                     range: (article.text as NSString).range(of: "importance of law"),
                                     expression: "importance of law", meaning: "法律的重要性")
        let progress = saved.start + 2
        try old.setReadOffset(articleID: articleID, offset: progress)
        let managedURL = try old.articleFileURL(articleID)

        let title = "The Importance of Law"
        let upgraded = try ReadingLibraryStore(rootURL: directory,
                                               bundledCollections: [collection(title: title)])
        let migrated = try XCTUnwrap(upgraded.article(id: articleID))
        let card = try XCTUnwrap(upgraded.card(id: saved.id))
        let expectedMarkdown = "# \(title)\n\n\(body)\n"
        XCTAssertEqual(migrated.title, title)
        XCTAssertEqual(migrated.markdown, expectedMarkdown)
        XCTAssertEqual(migrated.readOffset, progress)
        XCTAssertEqual(card.start, saved.start)
        XCTAssertEqual(card.end, saved.end)
        XCTAssertEqual(card.selectedText, "Importance of Law")
        XCTAssertEqual(card.meaning, saved.meaning)
        XCTAssertNotEqual(card.isDetached, true)
        XCTAssertEqual(try String(contentsOf: managedURL, encoding: .utf8), expectedMarkdown)

        upgraded.refreshArticleFiles()
        XCTAssertEqual(upgraded.article(id: articleID)?.title, title)
        XCTAssertEqual(upgraded.article(id: articleID)?.markdown, expectedMarkdown)
        XCTAssertEqual(upgraded.card(id: saved.id)?.selectedText, "Importance of Law")
        XCTAssertNotEqual(upgraded.card(id: saved.id)?.isDetached, true)
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReadingToolDaily-FileSync-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
