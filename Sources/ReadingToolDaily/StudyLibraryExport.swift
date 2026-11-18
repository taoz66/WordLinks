import AppKit
import Combine
import Darwin
import Foundation
import UniformTypeIdentifiers

/// The scope is selected before opening the save panel, independently of list filters.
enum StudyExportScope: Equatable {
    case entry(String)
    case article(UUID)
    case library
}

enum StudyExportError: LocalizedError {
    case emptyLibrary
    case unavailableScope
    case invalidRecord(UUID)
    case missingArticle(UUID)
    case invalidPath(UUID)
    case destinationChanged
    case invalidDestination
    case savePanelUnavailable
    case profileChanged

    var errorDescription: String? { message(language: AppLanguageStore.shared.language) }

    func message(language: InterfaceLanguage) -> String {
        let chinese = language == .chinese
        switch self {
        case .emptyLibrary:
            return chinese ? "当前档案没有积累。" : "This profile has no saved cards."
        case .unavailableScope:
            return chinese ? "当前词条或文章已不可用，请重新选择后导出。" : "The selected entry or article is no longer available. Select it again to export."
        case .invalidRecord(let id):
            return chinese ? "积累记录 \(id.uuidString) 不符合资料约束，未导出文件。" : "Saved card \(id.uuidString) is invalid. No file was exported."
        case .missingArticle(let id):
            return chinese ? "找不到积累所属的文章 \(id.uuidString)，未导出文件。" : "The article for saved card \(id.uuidString) is missing. No file was exported."
        case .invalidPath(let id):
            return chinese ? "文章 \(id.uuidString) 的已记录文件路径无效，未导出文件。" : "The recorded file path for article \(id.uuidString) is invalid. No file was exported."
        case .destinationChanged:
            return chinese ? "保存位置在确认后发生了变化。请重试并在保存面板中重新确认文件名。" : "The destination changed after confirmation. Retry and confirm the filename again in the save panel."
        case .invalidDestination:
            return chinese ? "请选择普通 CSV 文件的保存位置。" : "Choose a destination for a regular CSV file."
        case .savePanelUnavailable:
            return chinese ? "无法打开保存面板，请重试。" : "The save panel could not be opened. Please retry."
        case .profileChanged:
            return chinese ? "当前档案已切换，请返回原档案后重试此次导出。" : "The active profile changed. Return to the original profile to retry this export."
        }
    }
}

/// An immutable export, fixed to one profile, scope, language and time zone.
/// Sorting is by accumulation createdAt ascending, then card UUID ascending.
struct StudyExportSnapshot {
    struct Record: Equatable {
        let cardID: UUID
        let expression: String
        let meaning: String
        let originalSentence: String
        let articleTitle: String
        let articlePath: String
        let createdAt: Date
    }

    let profileID: UUID
    let scope: StudyExportScope
    let language: InterfaceLanguage
    let timeZone: TimeZone
    let exportedAt: Date
    let records: [Record]

    @MainActor
    static func make(store: ReadingLibraryStore, scope: StudyExportScope,
                     language: InterfaceLanguage, timeZone: TimeZone = .current,
                     now: Date = Date()) throws -> Self {
        let archive = store.archive
        guard !archive.cards.isEmpty else { throw StudyExportError.emptyLibrary }
        let cards: [StudyCard]
        switch scope {
        case .library:
            cards = archive.cards
        case .entry(let key):
            guard let entry = store.entries.first(where: { $0.key == key }) else {
                throw StudyExportError.unavailableScope
            }
            cards = entry.cards
        case .article(let id):
            guard archive.articles.contains(where: { $0.id == id }) else {
                throw StudyExportError.unavailableScope
            }
            cards = archive.cards.filter { $0.articleID == id }
        }
        guard !cards.isEmpty else { throw StudyExportError.unavailableScope }
        var seen = Set<UUID>()
        let sorted = cards.sorted {
            if $0.createdAt != $1.createdAt { return $0.createdAt < $1.createdAt }
            return $0.id.uuidString < $1.id.uuidString
        }
        let records = try sorted.map { card -> Record in
            guard seen.insert(card.id).inserted,
                  !card.expression.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !card.meaning.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw StudyExportError.invalidRecord(card.id)
            }
            guard let article = archive.articles.first(where: { $0.id == card.articleID }) else {
                throw StudyExportError.missingArticle(card.id)
            }
            if let path = article.sourceFilePath,
               path.isEmpty || !(path as NSString).isAbsolutePath {
                throw StudyExportError.invalidPath(article.id)
            }
            let url = try store.articleFileURL(article.id)
            guard url.isFileURL, !url.path.isEmpty else { throw StudyExportError.invalidPath(article.id) }
            return Record(cardID: card.id, expression: card.expression, meaning: card.meaning,
                          originalSentence: store.originalSentence(for: card), articleTitle: article.title,
                          articlePath: url.path, createdAt: card.createdAt)
        }
        return Self(profileID: archive.id, scope: scope, language: language, timeZone: timeZone,
                    exportedAt: now, records: records)
    }

    var defaultFilename: String {
        let date = Self.formatter("yyyyMMdd", timeZone: timeZone).string(from: exportedAt)
        return language == .chinese ? "词文库_词条导出_\(date).csv" : "WordLinks_ExportedEntries_\(date).csv"
    }

    var csvData: Data {
        let headers = language == .chinese
            ? ["词条", "释义", "例句", "文章标题", "文章路径", "日期"]
            : ["Entry", "Definition", "Example Sentence", "Article Title", "Article Path", "Date"]
        let formatter = Self.formatter("yyyy-MM-dd", timeZone: timeZone)
        var lines = [headers.map(Self.quote).joined(separator: ",")]
        lines.append(contentsOf: records.map { record in
            [record.expression, record.meaning, record.originalSentence, record.articleTitle,
             record.articlePath, formatter.string(from: record.createdAt)]
                .map(Self.quote).joined(separator: ",")
        })
        var data = Data([0xEF, 0xBB, 0xBF])
        data.append(contentsOf: (lines.joined(separator: "\r\n") + "\r\n").utf8)
        return data
    }

    private static func quote(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    private static func formatter(_ format: String, timeZone: TimeZone) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = format
        return formatter
    }
}

enum StudyExportFilename {
    /// Suggestions are calculated before the panel is confirmed, never after.
    static func available(_ filename: String, in directory: URL,
                          fileManager: FileManager = .default) -> String {
        let stem = (filename as NSString).deletingPathExtension
        let ext = (filename as NSString).pathExtension
        var candidate = filename
        var number = 0
        while fileManager.fileExists(atPath: directory.appendingPathComponent(candidate).path) {
            number += 1
            candidate = "\(stem) (\(number)).\(ext)"
        }
        return candidate
    }
}

/// Captured by the panel's public URL-validation delegate, after the user has
/// selected a destination (including the system's replacement confirmation).
struct StudyExportDestination: Equatable {
    struct Identity: Equatable {
        let device: UInt64
        let inode: UInt64
        let size: UInt64
        let modifiedAt: Date
    }

    let url: URL
    let identity: Identity?

    static func capture(_ url: URL, fileManager: FileManager = .default) throws -> Self {
        guard url.isFileURL, url.pathExtension.lowercased() == "csv" else {
            throw StudyExportError.invalidDestination
        }
        let attributes: [FileAttributeKey: Any]
        do { attributes = try fileManager.attributesOfItem(atPath: url.path) }
        catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError {
            return Self(url: url, identity: nil)
        }
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let device = attributes[.systemNumber] as? NSNumber,
              let inode = attributes[.systemFileNumber] as? NSNumber,
              let size = attributes[.size] as? NSNumber,
              let modifiedAt = attributes[.modificationDate] as? Date else {
            throw StudyExportError.invalidDestination
        }
        return Self(url: url, identity: Identity(device: device.uint64Value, inode: inode.uint64Value,
                                               size: size.uint64Value, modifiedAt: modifiedAt))
    }
}

enum StudyExportWriter {
    /// Stage complete bytes beside the destination. A newly appearing filename
    /// is never overwritten; existing replacements must still match approval.
    static func write(_ data: Data, to destination: StudyExportDestination,
                      fileManager: FileManager = .default) throws {
        let temporary = destination.url.deletingLastPathComponent()
            .appendingPathComponent(".wordlinks-export-\(UUID().uuidString).tmp")
        defer { try? fileManager.removeItem(at: temporary) }
        try data.write(to: temporary, options: .withoutOverwriting)
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinationError: NSError?
        var writeError: Error?
        coordinator.coordinate(writingItemAt: destination.url, options: .forReplacing,
                               error: &coordinationError) { url in
            do {
                guard try StudyExportDestination.capture(url, fileManager: fileManager).identity == destination.identity else {
                    throw StudyExportError.destinationChanged
                }
                if destination.identity == nil {
                    // link(2) installs complete staged content only if the exact
                    // confirmed path is still absent, even in a concurrent race.
                    guard link(temporary.path, url.path) == 0 else {
                        if errno == EEXIST { throw StudyExportError.destinationChanged }
                        throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
                    }
                } else {
                    // Foundation preserves the original file's metadata; do not
                    // alter source files, directory permissions, or user names.
                    _ = try fileManager.replaceItemAt(url, withItemAt: temporary)
                }
            } catch { writeError = error }
        }
        if let coordinationError { throw coordinationError }
        if let writeError { throw writeError }
    }
}

@MainActor
final class StudyExportSavePanelDelegate: NSObject, NSOpenSavePanelDelegate {
    let defaultFilename: String
    private(set) var suggestedFilename: String
    private(set) var userChangedFilename = false
    private(set) var destination: StudyExportDestination?

    init(defaultFilename: String, directory: URL) {
        self.defaultFilename = defaultFilename
        suggestedFilename = StudyExportFilename.available(defaultFilename, in: directory)
    }

    func panel(_ sender: Any, didChangeToDirectoryURL url: URL?) {
        guard let panel = sender as? NSSavePanel, let url else { return }
        guard !userChangedFilename else { return }
        if !matchesSuggestion(panel.nameFieldStringValue) {
            userChangedFilename = true
            return
        }
        suggestedFilename = StudyExportFilename.available(defaultFilename, in: url)
        panel.nameFieldStringValue = suggestedFilename
    }

    func panel(_ sender: Any, userEnteredFilename filename: String, confirmed okFlag: Bool) -> String? {
        if !matchesSuggestion(filename) { userChangedFilename = true }
        // Never rewrite a user's filename, especially a confirmed one. AppKit
        // applies the CSV extension and performs its own replacement prompt.
        return filename
    }

    func panel(_ sender: Any, validate url: URL) throws {
        destination = try StudyExportDestination.capture(url)
    }

    private func matchesSuggestion(_ filename: String) -> Bool {
        filename == suggestedFilename || filename == (suggestedFilename as NSString).deletingPathExtension
    }
}

/// One instance belongs to one library window. The menu, toolbar and Command+E
/// all call the same guarded entry point.
@MainActor
final class StudyLibraryExporter: ObservableObject {
    enum PanelResult {
        case cancelled
        case confirmed(StudyExportDestination)
        case failed(Error)
    }
    typealias Presenter = (StudyExportSnapshot, NSWindow?, @escaping (PanelResult) -> Void) -> Void
    typealias Writer = (Data, StudyExportDestination) throws -> Void

    @Published private(set) var isExporting = false
    @Published private(set) var successMessage: String?
    @Published private(set) var errorMessage: String?
    private var failedSnapshot: StudyExportSnapshot?
    private struct Request {
        weak var store: ReadingLibraryStore?
        let profileID: UUID
        let scope: StudyExportScope
        let language: InterfaceLanguage
        let timeZone: TimeZone
        let startedAt: Date
        let finishEditing: () -> Bool
    }
    private var request: Request?
    private weak var ownerWindow: NSWindow?
    private var panel: NSSavePanel?
    private var panelDelegate: StudyExportSavePanelDelegate?
    private var lastDirectory: URL?
    private let presenter: Presenter?
    private let writer: Writer

    init(presenter: Presenter? = nil,
         writer: @escaping Writer = { try StudyExportWriter.write($0, to: $1) }) {
        self.presenter = presenter
        self.writer = writer
    }

    func canExport(store: ReadingLibraryStore) -> Bool { !isExporting && !store.cards.isEmpty }

    var canRetry: Bool {
        guard !isExporting, let request else { return false }
        return failedSnapshot != nil || request.store?.activeProfileID == request.profileID
    }

    var retryUsesSavedSnapshot: Bool { failedSnapshot != nil }

    func export(scope: StudyExportScope, store: ReadingLibraryStore, window: NSWindow?,
                language: InterfaceLanguage, finishEditing: @escaping () -> Bool) {
        guard canExport(store: store) else { return }
        isExporting = true
        successMessage = nil
        errorMessage = nil
        failedSnapshot = nil
        request = nil
        // Editing may fail and keep its draft; no panel or snapshot is opened.
        guard finishEditing() else { isExporting = false; return }
        let request = Request(store: store, profileID: store.activeProfileID, scope: scope, language: language,
                              timeZone: .current, startedAt: Date(), finishEditing: finishEditing)
        self.request = request
        ownerWindow = window
        do {
            let snapshot = try StudyExportSnapshot.make(store: store, scope: scope, language: language,
                                                        timeZone: request.timeZone, now: request.startedAt)
            present(snapshot, window: window)
        } catch {
            errorMessage = localized(error, language: language)
            isExporting = false
        }
    }

    func retry() {
        guard canRetry, let request else { return }
        isExporting = true
        errorMessage = nil
        guard request.finishEditing() else { isExporting = false; return }
        if let snapshot = failedSnapshot { present(snapshot, window: ownerWindow); return }
        do {
            guard let store = request.store, store.activeProfileID == request.profileID else {
                throw StudyExportError.profileChanged
            }
            let snapshot = try StudyExportSnapshot.make(store: store, scope: request.scope, language: request.language,
                                                        timeZone: request.timeZone, now: request.startedAt)
            present(snapshot, window: ownerWindow)
        } catch {
            errorMessage = localized(error, language: request.language)
            isExporting = false
        }
    }

    func dismissError() { errorMessage = nil; failedSnapshot = nil; request = nil }
    func dismissSuccess() { successMessage = nil }

    private func present(_ snapshot: StudyExportSnapshot, window: NSWindow?) {
        let completion: (PanelResult) -> Void = { [weak self] result in
            self?.complete(result, snapshot: snapshot)
        }
        if let presenter { presenter(snapshot, window, completion); return }
        let directory = lastDirectory ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        let delegate = StudyExportSavePanelDelegate(defaultFilename: snapshot.defaultFilename, directory: directory)
        let panel = NSSavePanel()
        panel.title = snapshot.language == .chinese ? "导出词条" : "Export Entries"
        panel.prompt = snapshot.language == .chinese ? "导出" : "Export"
        panel.nameFieldLabel = snapshot.language == .chinese ? "名称：" : "Name:"
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.allowsOtherFileTypes = false
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.directoryURL = directory
        panel.nameFieldStringValue = delegate.suggestedFilename
        panel.delegate = delegate
        self.panel = panel
        panelDelegate = delegate
        let finished: (NSApplication.ModalResponse) -> Void = { [weak self, weak panel] response in
            guard let self else { return }
            panel?.orderOut(nil)
            self.lastDirectory = panel?.directoryURL
            if response == .cancel { completion(.cancelled) }
            else if response == .OK, let destination = delegate.destination,
                    destination.url == panel?.url {
                completion(.confirmed(destination))
            } else { completion(.failed(StudyExportError.savePanelUnavailable)) }
            self.panel = nil
            self.panelDelegate = nil
        }
        if let window { panel.beginSheetModal(for: window, completionHandler: finished) }
        else { panel.begin(completionHandler: finished) }
    }

    private func complete(_ result: PanelResult, snapshot: StudyExportSnapshot) {
        defer { isExporting = false }
        switch result {
        case .cancelled:
            failedSnapshot = nil
            request = nil
        case .failed(let error):
            failedSnapshot = snapshot
            errorMessage = localized(error, language: snapshot.language)
        case .confirmed(let destination):
            do {
                try writer(snapshot.csvData, destination)
                failedSnapshot = nil
                request = nil
                let count = snapshot.records.count
                successMessage = snapshot.language == .chinese ? "已导出 \(count) 条积累" : "Exported \(count) saved cards"
                DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
                    if self?.successMessage == (snapshot.language == .chinese ? "已导出 \(count) 条积累" : "Exported \(count) saved cards") {
                        self?.successMessage = nil
                    }
                }
            } catch {
                failedSnapshot = snapshot
                errorMessage = localized(error, language: snapshot.language)
            }
        }
    }

    private func localized(_ error: Error, language: InterfaceLanguage) -> String {
        if let error = error as? StudyExportError { return error.message(language: language) }
        return language == .chinese ? "导出失败：\(error.localizedDescription)" : "Export failed: \(error.localizedDescription)"
    }
}
