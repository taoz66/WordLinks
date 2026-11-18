import AppKit
import Foundation
import XCTest
@testable import WordLinks

@MainActor
final class StudyLibraryExportTests: XCTestCase {
    func testThreeScopesKeepEveryAccumulationAndActualSpelling() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let (store, first, second) = try fixture(root)
        let all = try StudyExportSnapshot.make(store: store, scope: .library, language: .english)
        let entry = try StudyExportSnapshot.make(store: store, scope: .entry("alpha"), language: .english)
        let article = try StudyExportSnapshot.make(store: store, scope: .article(first.id), language: .english)
        XCTAssertEqual(all.records.count, 3)
        XCTAssertEqual(entry.records.count, 2)
        XCTAssertEqual(Set(entry.records.map(\.expression)), ["Alpha", "alpha"])
        XCTAssertEqual(article.records.count, 2)
        XCTAssertEqual(Set(article.records.map(\.meaning)), ["first", "second"])
        XCTAssertTrue(all.records.contains(where: { $0.articleTitle == second.title }))
        XCTAssertEqual(Set(all.records.map(\.cardID)).count, 3)
    }

    func testSnapshotDoesNotReadUIFiltersAndIsFixedBeforeProfileOrContentChanges() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let (store, first, _) = try fixture(root)
        let profileID = store.activeProfileID
        let snapshot = try StudyExportSnapshot.make(store: store, scope: .library, language: .chinese)
        let originalData = snapshot.csvData
        try store.deleteArticle(first.id)
        try store.createProfile(name: "Independent")
        XCTAssertTrue(store.cards.isEmpty)
        XCTAssertEqual(snapshot.profileID, profileID)
        XCTAssertEqual(snapshot.records.count, 3)
        XCTAssertEqual(snapshot.csvData, originalData)
        XCTAssertThrowsError(try StudyExportSnapshot.make(store: store, scope: .library, language: .english))
    }

    func testManagedAndUnavailableExternalPathsAreExportedWithoutAccessingFiles() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try ReadingLibraryStore(rootURL: root, bundledCollections: [])
        let managed = try store.addMarkdown(markdown: "# Managed\n\nOne saved word.", sourceName: "managed.md")
        let missing = root.appendingPathComponent("missing-source.md")
        let external = try store.addMarkdown(markdown: "# External\n\nAnother saved word.",
                                             sourceName: "missing-source.md", sourceFilePath: missing.path)
        for article in [managed, external] {
            try store.saveCard(articleID: article.id, range: (article.text as NSString).range(of: "word"),
                               expression: "word", meaning: "definition")
        }
        let managedURL = try store.articleFileURL(managed.id)
        try FileManager.default.removeItem(at: managedURL)
        let snapshot = try StudyExportSnapshot.make(store: store, scope: .library, language: .english)
        XCTAssertEqual(Set(snapshot.records.map(\.articlePath)), [managedURL.path, missing.path])
        XCTAssertEqual(Set(snapshot.records.map(\.articleTitle)), ["Managed", "External"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: managedURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path))
    }

    func testDetachedAccumulationExportsSavedHistoricalSentence() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try ReadingLibraryStore(rootURL: root, bundledCollections: [])
        let article = try store.addMarkdown(markdown: "# Original\n\nAn old word, with history.", sourceName: "history.md")
        let card = try store.saveCard(articleID: article.id, range: (article.text as NSString).range(of: "word"),
                                     expression: "expression", meaning: "meaning")
        let sourceURL = try store.articleFileURL(article.id)
        try "# Updated\n\nEntirely different text.".write(to: sourceURL, atomically: true, encoding: .utf8)
        store.refreshArticleFiles()
        let current = try XCTUnwrap(store.card(id: card.id))
        XCTAssertEqual(current.isDetached, true)
        let snapshot = try StudyExportSnapshot.make(store: store, scope: .library, language: .english)
        XCTAssertEqual(snapshot.records.first?.cardID, card.id)
        XCTAssertEqual(snapshot.records.first?.originalSentence, card.originalSentence)
        XCTAssertEqual(snapshot.records.first?.articleTitle, "Updated")
        XCTAssertEqual(store.card(id: card.id), current)
    }

    func testInvalidStoredPathIsReportedInsteadOfInventedOrSkipped() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try ReadingLibraryStore(rootURL: root, bundledCollections: [])
        let article = try store.addMarkdown(markdown: "# Invalid\n\nA word.", sourceName: "invalid.md", sourceFilePath: "relative.md")
        try store.saveCard(articleID: article.id, range: (article.text as NSString).range(of: "word"),
                           expression: "word", meaning: "meaning")
        XCTAssertThrowsError(try StudyExportSnapshot.make(store: store, scope: .library, language: .english)) {
            guard case StudyExportError.invalidPath(let id) = $0 else { return XCTFail("Expected invalidPath") }
            XCTAssertEqual(id, article.id)
        }
    }

    func testCSVHasSingleBOMQuotedFieldsCRLFAndLosslessUnicodeMultilineValues() throws {
        let value = "=1+1,\"中文\"\nline\r\n🙂 e\u{301}"
        let snapshot = syntheticSnapshot(language: .english, expression: value, meaning: "not limited to Chinese",
                                         example: "First, \"quoted\".\nSecond sentence.")
        let data = snapshot.csvData
        XCTAssertEqual(Array(data.prefix(3)), [0xEF, 0xBB, 0xBF])
        let decoded = String(decoding: data.dropFirst(3), as: UTF8.self)
        XCTAssertEqual(decoded.filter { $0 == "\u{FEFF}" }.count, 0)
        XCTAssertTrue(decoded.hasPrefix("\"Entry\",\"Definition\",\"Example Sentence\",\"Article Title\",\"Article Path\",\"Date\"\r\n"))
        XCTAssertTrue(decoded.hasSuffix("\r\n"))
        let rows = parseCSV(decoded)
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[1].count, 6)
        XCTAssertEqual(rows[1][0], value)
        XCTAssertEqual(rows[1][1], "not limited to Chinese")
        XCTAssertEqual(rows[1][2], "First, \"quoted\".\nSecond sentence.")
        XCTAssertTrue(decoded.contains("\"=1+1,"))
        XCTAssertFalse(decoded.contains("'=1+1"))
    }

    func testGregorianDatesAndLocalizedFilenamesUseCalendarYearAndPinnedTimeZone() {
        let date = ISO8601DateFormatter().date(from: "2021-01-01T00:30:00Z")!
        let west = TimeZone(secondsFromGMT: -3600)!
        let east = TimeZone(secondsFromGMT: 8 * 3600)!
        let chinese = syntheticSnapshot(language: .chinese, timeZone: west, date: date)
        let english = syntheticSnapshot(language: .english, timeZone: east, date: date)
        XCTAssertEqual(chinese.defaultFilename, "词文库_词条导出_20201231.csv")
        XCTAssertEqual(english.defaultFilename, "WordLinks_ExportedEntries_20210101.csv")
        let zhRows = parseCSV(String(decoding: chinese.csvData.dropFirst(3), as: UTF8.self))
        let enRows = parseCSV(String(decoding: english.csvData.dropFirst(3), as: UTF8.self))
        XCTAssertEqual(zhRows[0], ["词条", "释义", "例句", "文章标题", "文章路径", "日期"])
        XCTAssertEqual(zhRows[1][5], "2020-12-31")
        XCTAssertEqual(enRows[1][5], "2021-01-01")
    }

    func testSnapshotOrderIsStableByCreatedAtThenUUID() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let (store, _, _) = try fixture(root)
        let one = try StudyExportSnapshot.make(store: store, scope: .library, language: .english)
        let two = try StudyExportSnapshot.make(store: store, scope: .library, language: .english)
        let expected = store.cards.sorted {
            if $0.createdAt != $1.createdAt { return $0.createdAt < $1.createdAt }
            return $0.id.uuidString < $1.id.uuidString
        }.map(\.id)
        XCTAssertEqual(one.records.map(\.cardID), expected)
        XCTAssertEqual(two.records.map(\.cardID), expected)
    }

    func testDefaultFilenameUsesSmallestAvailablePositiveNumber() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let name = "WordLinks_ExportedEntries_20261112.csv"
        XCTAssertEqual(StudyExportFilename.available(name, in: root), name)
        try Data().write(to: root.appendingPathComponent(name))
        try Data().write(to: root.appendingPathComponent("WordLinks_ExportedEntries_20261112 (2).csv"))
        XCTAssertEqual(StudyExportFilename.available(name, in: root), "WordLinks_ExportedEntries_20261112 (1).csv")
        try Data().write(to: root.appendingPathComponent("WordLinks_ExportedEntries_20261112 (1).csv"))
        XCTAssertEqual(StudyExportFilename.available(name, in: root), "WordLinks_ExportedEntries_20261112 (3).csv")
    }

    func testFilenameDelegateNeverRewritesUserNameAtConfirmation() throws {
        let root = temporaryDirectory()
        let delegate = StudyExportSavePanelDelegate(defaultFilename: "Default.csv", directory: root)
        XCTAssertEqual(delegate.panel(NSObject(), userEnteredFilename: "Chosen.csv", confirmed: true), "Chosen.csv")
        XCTAssertTrue(delegate.userChangedFilename)
        XCTAssertEqual(delegate.suggestedFilename, "Default.csv")
    }

    func testWriterCreatesOnlyCompleteConfirmedFileAndReplacesApprovedExistingFile() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("saved.csv")
        let first = Data("first complete file".utf8)
        try StudyExportWriter.write(first, to: StudyExportDestination.capture(url))
        XCTAssertEqual(try Data(contentsOf: url), first)
        let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        let second = Data("second complete file".utf8)
        try StudyExportWriter.write(second, to: StudyExportDestination.capture(url))
        XCTAssertEqual(try Data(contentsOf: url), second)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber, permissions)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["saved.csv"])
    }

    func testNewCollisionAfterConfirmationDoesNotOverwriteOrRename() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("conflict.csv")
        let destination = try StudyExportDestination.capture(url)
        let original = Data("newly appeared".utf8)
        try original.write(to: url)
        XCTAssertThrowsError(try StudyExportWriter.write(Data("export".utf8), to: destination))
        XCTAssertEqual(try Data(contentsOf: url), original)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["conflict.csv"])
    }

    func testChangedExistingDestinationIsNotOverwritten() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("changed.csv")
        try Data("approved".utf8).write(to: url)
        let approved = try StudyExportDestination.capture(url)
        let changed = Data("changed after confirmation".utf8)
        try changed.write(to: url, options: .atomic)
        XCTAssertThrowsError(try StudyExportWriter.write(Data("export".utf8), to: approved))
        XCTAssertEqual(try Data(contentsOf: url), changed)
    }

    func testWriteFailureLeavesNoPartialOutputOrStagingFile() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("missing/export.csv")
        let destination = try StudyExportDestination.capture(url)
        XCTAssertThrowsError(try StudyExportWriter.write(Data("complete".utf8), to: destination))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    func testExportGuardCoversNoDetailEmptyProfileAndRepeatedCommands() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let (store, _, _) = try fixture(root)
        var calls = 0
        var completion: ((StudyLibraryExporter.PanelResult) -> Void)?
        let exporter = StudyLibraryExporter(presenter: { _, _, done in calls += 1; completion = done })
        XCTAssertTrue(exporter.canExport(store: store))
        exporter.export(scope: .library, store: store, window: nil, language: .english, finishEditing: { true })
        XCTAssertTrue(exporter.isExporting)
        XCTAssertFalse(exporter.canExport(store: store))
        exporter.export(scope: .library, store: store, window: nil, language: .english, finishEditing: { XCTFail("Duplicate"); return true })
        XCTAssertEqual(calls, 1)
        completion?(.cancelled)
        XCTAssertFalse(exporter.isExporting)
        XCTAssertNil(exporter.successMessage)
        XCTAssertNil(exporter.errorMessage)
        try store.createProfile(name: "Empty")
        XCTAssertFalse(exporter.canExport(store: store))
        exporter.export(scope: .library, store: store, window: nil, language: .english, finishEditing: { XCTFail("Empty"); return true })
        XCTAssertEqual(calls, 1)
    }

    func testEditingMustCommitBeforeSnapshotAndFailedDraftAbortsExport() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let (store, first, _) = try fixture(root)
        var received: StudyExportSnapshot?
        let exporter = StudyLibraryExporter(presenter: { snapshot, _, done in received = snapshot; done(.cancelled) })
        exporter.export(scope: .library, store: store, window: nil, language: .english, finishEditing: { false })
        XCTAssertNil(received)
        XCTAssertFalse(exporter.isExporting)
        exporter.export(scope: .library, store: store, window: nil, language: .english, finishEditing: {
            try! store.deleteArticle(first.id)
            return true
        })
        XCTAssertEqual(received?.records.count, 1)
    }

    func testFailureKeepsSnapshotForRetryAndSuccessCountsCards() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let (store, _, _) = try fixture(root)
        var completion: ((StudyLibraryExporter.PanelResult) -> Void)?
        var snapshots: [StudyExportSnapshot] = []
        var failWrite = true
        var written: Data?
        let exporter = StudyLibraryExporter(presenter: { snapshot, _, done in snapshots.append(snapshot); completion = done }, writer: { data, _ in
            if failWrite { throw CocoaError(.fileWriteNoPermission) }
            written = data
        })
        exporter.export(scope: .library, store: store, window: nil, language: .english, finishEditing: { true })
        let destination = try StudyExportDestination.capture(root.appendingPathComponent("out.csv"))
        completion?(.confirmed(destination))
        XCTAssertNotNil(exporter.errorMessage)
        XCTAssertNil(exporter.successMessage)
        XCTAssertFalse(exporter.isExporting)
        try store.createProfile(name: "Different")
        failWrite = false
        exporter.retry()
        XCTAssertEqual(snapshots.count, 2)
        XCTAssertEqual(snapshots[0].profileID, snapshots[1].profileID)
        completion?(.confirmed(destination))
        XCTAssertEqual(exporter.successMessage, "Exported 3 saved cards")
        XCTAssertEqual(written, snapshots[0].csvData)
        XCTAssertNil(exporter.errorMessage)
        XCTAssertTrue(store.cards.isEmpty)
    }

    private func fixture(_ root: URL) throws -> (ReadingLibraryStore, LibraryArticle, LibraryArticle) {
        let store = try ReadingLibraryStore(rootURL: root, bundledCollections: [])
        let first = try store.addMarkdown(markdown: "# First\n\nAlpha beta.", sourceName: "first.md")
        let second = try store.addMarkdown(markdown: "# Second\n\nAnother alpha.", sourceName: "second.md")
        try store.saveCard(articleID: first.id, range: (first.text as NSString).range(of: "Alpha"), expression: "Alpha", meaning: "first")
        try store.saveCard(articleID: first.id, range: (first.text as NSString).range(of: "beta"), expression: "beta", meaning: "second")
        try store.saveCard(articleID: second.id, range: (second.text as NSString).range(of: "alpha"), expression: "alpha", meaning: "different context")
        return (store, first, second)
    }

    private func syntheticSnapshot(language: InterfaceLanguage, timeZone: TimeZone = TimeZone(secondsFromGMT: 0)!,
                                   date: Date = Date(timeIntervalSince1970: 0), expression: String = "entry",
                                   meaning: String = "definition", example: String = "Sentence.") -> StudyExportSnapshot {
        StudyExportSnapshot(profileID: UUID(), scope: .library, language: language, timeZone: timeZone, exportedAt: date,
                            records: [.init(cardID: UUID(), expression: expression, meaning: meaning,
                                            originalSentence: example, articleTitle: "Title", articlePath: "/tmp/article.md", createdAt: date)])
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("WordLinksExport-" + UUID().uuidString, isDirectory: true)
    }

    /// An independent test parser keeps quoted field line breaks inside a row.
    private func parseCSV(_ csv: String) -> [[String]] {
        let scalars = Array(csv.unicodeScalars)
        var rows: [[String]] = [], fields: [String] = [], field = "", quoted = false, index = 0
        while index < scalars.count {
            let scalar = scalars[index]
            if scalar == "\"" {
                if quoted, index + 1 < scalars.count, scalars[index + 1] == "\"" { field.append("\""); index += 1 }
                else { quoted.toggle() }
            } else if scalar == ",", !quoted { fields.append(field); field = "" }
            else if scalar == "\r", !quoted, index + 1 < scalars.count, scalars[index + 1] == "\n" {
                fields.append(field); rows.append(fields); fields = []; field = ""; index += 1
            } else { field.unicodeScalars.append(scalar) }
            index += 1
        }
        return rows
    }
}
