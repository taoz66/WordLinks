import Combine
import Foundation

public struct ProfileDescriptor: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public var name: String
    public let createdAt: Date
    public var modifiedAt: Date

    public init(id: UUID = UUID(), name: String, createdAt: Date = Date(), modifiedAt: Date = Date()) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
    }
}

public struct LibraryFolder: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public var name: String
    public let createdAt: Date

    public init(id: UUID = UUID(), name: String, createdAt: Date = Date()) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
    }
}

/// Optional header fields reconstructed from Markdown, independent of card anchors.
public struct ArticleMetadata: Equatable, Sendable {
    public var author: String?
    public var date: String?
    public var source: String?
    public var sourceURL: URL?

    public init(author: String? = nil, date: String? = nil, source: String? = nil, sourceURL: URL? = nil) {
        self.author = author
        self.date = date
        self.source = source
        self.sourceURL = sourceURL
    }
}

public struct LibraryArticle: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public var title: String
    public var sourceName: String
    public var sourceURL: String?
    /// Imported files stay linked; nil uses the profile's editable Markdown copy.
    public var sourceFilePath: String?
    public let markdown: String
    public let text: String
    public var folderID: UUID?
    /// Unicode-scalar offset into `text`.
    public var readOffset: Int
    public let createdAt: Date

    /// Old archives keep field-looking prose in their original selection text.
    public var metadata: ArticleMetadata { ReadingLibraryStore.metadata(for: self) }

    public init(id: UUID = UUID(), title: String, sourceName: String, sourceURL: String? = nil, markdown: String,
                text: String, folderID: UUID? = nil, readOffset: Int = 0, createdAt: Date = Date(),
                sourceFilePath: String? = nil) {
        self.id = id
        self.title = title
        self.sourceName = sourceName
        self.sourceURL = sourceURL
        self.sourceFilePath = sourceFilePath
        self.markdown = markdown
        self.text = text
        self.folderID = folderID
        self.readOffset = readOffset
        self.createdAt = createdAt
    }
}

public struct StudyCard: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public let articleID: UUID
    /// Half-open Unicode-scalar range; retained as history when detached.
    public let start: Int
    public let end: Int
    public let selectedText: String
    public var expression: String
    public var meaning: String
    public let createdAt: Date
    public var updatedAt: Date
    /// Keep vocabulary when its original text can no longer be located.
    public var isDetached: Bool?
    /// Complete sentence(s) at the time of highlighting, independent of later article edits.
    public var originalSentence: String?

    public init(id: UUID = UUID(), articleID: UUID, start: Int, end: Int, selectedText: String,
                expression: String, meaning: String, createdAt: Date = Date(), updatedAt: Date = Date(),
                isDetached: Bool? = nil, originalSentence: String? = nil) {
        self.id = id
        self.articleID = articleID
        self.start = start
        self.end = end
        self.selectedText = selectedText
        self.expression = expression
        self.meaning = meaning
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.isDetached = isDetached
        self.originalSentence = originalSentence
    }
}

/// A source selection can be accumulated only when no attached card already occupies it.
public enum StudyCardSelectionStatus: Equatable, Sendable {
    case available
    case existing(StudyCard)
    case overlapping
}

public struct ProfileArchive: Codable, Equatable, Sendable {
    public var version: Int
    public var id: UUID
    public var name: String
    public var createdAt: Date
    public var folders: [LibraryFolder]
    public var articles: [LibraryArticle]
    public var cards: [StudyCard]
    public var lastArticleID: UUID?
    /// A collection is offered once per profile, so a later user deletion stays deleted.
    public var seededCollections: [String]

    public var profileID: UUID {
        get { id }
        set { id = newValue }
    }
    public var profileName: String {
        get { name }
        set { name = newValue }
    }
    public var entries: [VocabularyEntry] {
        Dictionary(grouping: cards, by: { normalizedExpression($0.expression) })
            .keys.sorted().compactMap { key in
                guard let group = Dictionary(grouping: cards, by: { normalizedExpression($0.expression) })[key],
                      let first = group.first else { return nil }
                return VocabularyEntry(key: key, expression: first.expression,
                                       cards: group.sorted { $0.createdAt < $1.createdAt })
            }
    }

    public init(version: Int = 1, id: UUID, name: String, createdAt: Date = Date(),
                folders: [LibraryFolder] = [], articles: [LibraryArticle] = [], cards: [StudyCard] = [],
                lastArticleID: UUID? = nil, seededCollections: [String] = []) {
        self.version = version
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.folders = folders
        self.articles = articles
        self.cards = cards
        self.lastArticleID = lastArticleID
        self.seededCollections = seededCollections
    }

    public init(version: Int = 1, profileID: UUID, profileName: String, createdAt: Date = Date(),
                folders: [LibraryFolder] = [], articles: [LibraryArticle] = [], cards: [StudyCard] = [],
                lastArticleID: UUID? = nil, seededCollections: [String] = []) {
        self.init(version: version, id: profileID, name: profileName, createdAt: createdAt,
                  folders: folders, articles: articles, cards: cards, lastArticleID: lastArticleID,
                  seededCollections: seededCollections)
    }

    private enum CodingKeys: String, CodingKey {
        case version, id, name, createdAt, folders, articles, cards, lastArticleID, seededCollections
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = try values.decode(Int.self, forKey: .version)
        id = try values.decode(UUID.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        createdAt = try values.decode(Date.self, forKey: .createdAt)
        folders = try values.decode([LibraryFolder].self, forKey: .folders)
        articles = try values.decode([LibraryArticle].self, forKey: .articles)
        cards = try values.decode([StudyCard].self, forKey: .cards)
        lastArticleID = try values.decodeIfPresent(UUID.self, forKey: .lastArticleID)
        seededCollections = try values.decodeIfPresent([String].self, forKey: .seededCollections) ?? []
    }
}

public struct VocabularyEntry: Identifiable, Equatable, Sendable {
    public var id: String { key }
    public let key: String
    public let expression: String
    public let cards: [StudyCard]

    public init(key: String, expression: String, cards: [StudyCard]) {
        self.key = key
        self.expression = expression
        self.cards = cards
    }
}

private func normalizedExpression(_ expression: String) -> String {
    expression.replacingOccurrences(of: "...", with: "…")
        .split(whereSeparator: \.isWhitespace).joined(separator: " ").lowercased()
}

public struct LibraryMeaningGroup: Identifiable, Equatable, Sendable {
    public var id: String { meaning }
    public let meaning: String
    public let cards: [StudyCard]
    public let sources: [LibraryArticle]

    public init(meaning: String, cards: [StudyCard], sources: [LibraryArticle]) {
        self.meaning = meaning
        self.cards = cards
        self.sources = sources
    }
}

public struct LibraryEntry: Identifiable, Equatable, Sendable {
    /// Normalized accumulation spelling, used as the stable aggregate key.
    public var id: String { key }
    public let key: String
    public let expressions: [String]
    public let cards: [StudyCard]
    public let meanings: [LibraryMeaningGroup]

    public init(key: String, expressions: [String], cards: [StudyCard], meanings: [LibraryMeaningGroup]) {
        self.key = key
        self.expressions = expressions
        self.cards = cards
        self.meanings = meanings
    }
}

public enum ReadingLibraryError: LocalizedError {
    case invalidName, missingProfile, missingFolder, missingArticle, missingCard, lastProfile
    case invalidMarkdown, invalidRange, overlappingCard, emptyExpression, emptyMeaning
    case unsupportedArchive, invalidArchive, fileAccess(String)

    public var errorDescription: String? {
        switch self {
        case .invalidName: return L("名称不能为空。", "Name cannot be empty.")
        case .missingProfile: return L("找不到指定档案。", "The selected profile could not be found.")
        case .missingFolder: return L("找不到指定文件夹。", "The selected folder could not be found.")
        case .missingArticle: return L("找不到指定文章。", "The selected article could not be found.")
        case .missingCard: return L("找不到指定卡片。", "The selected card could not be found.")
        case .lastProfile: return L("至少保留一个档案。", "At least one profile must be kept.")
        case .invalidMarkdown: return L("Markdown 文章需要以 # 或 ## 标题开头。", "Markdown articles must begin with a # or ## heading.")
        case .invalidRange: return L("选区与文章原文不匹配。", "The selection does not match the article text.")
        case .overlappingCard: return L("选区与已有卡片重叠。", "The selection overlaps an existing card.")
        case .emptyExpression: return L("积累写法不能为空。", "Expression cannot be empty.")
        case .emptyMeaning: return L("释义不能为空。", "Meaning cannot be empty.")
        case .unsupportedArchive: return L("不支持此档案文件版本。", "This profile file version is not supported.")
        case .invalidArchive: return L("档案文件内容无效，现有资料未被修改。", "The profile file is invalid. Your existing data has not been changed.")
        case .fileAccess(let message): return message
        }
    }
}

@MainActor
public final class ReadingLibraryStore: ObservableObject {
    @Published public private(set) var profiles: [ProfileDescriptor]
    @Published public private(set) var activeProfileID: UUID
    @Published public private(set) var archive: ProfileArchive
    @Published public private(set) var fileSyncErrors: [UUID: String] = [:]

    public var folders: [LibraryFolder] { archive.folders }
    public var articles: [LibraryArticle] { archive.articles }
    public var cards: [StudyCard] { archive.cards }

    public static let backupLimit = 10
    public let rootURL: URL
    private let fileManager: FileManager
    private let bundledCollections: [BundledArticleCollection]
    private var revision: ProfileArchive { archive }
    private var fileRefreshTimer: AnyCancellable?
    private var fileStamps: [URL: ArticleFileStamp] = [:]
    private var preparedFiles = Set<URL>()
    private var synchronizedProfileID: UUID?

    private struct Index: Codable {
        var version = 1
        var activeProfileID: UUID
        var profiles: [ProfileDescriptor]
    }

    private static var defaultRootURL: URL {
        if let path = ProcessInfo.processInfo.environment["READINGTOOL_DAILY_DATA_DIR"], !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ReadingToolDaily", isDirectory: true)
    }

    public convenience init(fileManager: FileManager = .default) throws {
        try self.init(rootURL: Self.defaultRootURL, fileManager: fileManager)
    }

    public convenience init(rootURL: URL, fileManager: FileManager = .default) throws {
        try self.init(rootURL: rootURL, fileManager: fileManager,
                      bundledCollections: BundledArticleCollection.load(rootURL: rootURL, fileManager: fileManager))
    }

    init(rootURL: URL, fileManager: FileManager = .default,
         bundledCollections: [BundledArticleCollection]) throws {
        self.rootURL = rootURL
        self.fileManager = fileManager
        self.bundledCollections = bundledCollections
        let indexURL = rootURL.appendingPathComponent("profiles.json")
        var needsInitialIndex = false
        let loadedProfiles: [ProfileDescriptor]
        let loadedProfileID: UUID
        if fileManager.fileExists(atPath: indexURL.path) {
            do {
                let index = try Self.decoder().decode(Index.self, from: Data(contentsOf: indexURL))
                guard index.version == 1, !index.profiles.isEmpty,
                      Set(index.profiles.map(\.id)).count == index.profiles.count,
                      index.profiles.contains(where: { $0.id == index.activeProfileID }) else {
                    throw ReadingLibraryError.invalidArchive
                }
                loadedProfiles = index.profiles
                loadedProfileID = index.activeProfileID
            } catch let error as ReadingLibraryError { throw error }
            catch { throw ReadingLibraryError.fileAccess(L("无法读取档案索引：\(error.localizedDescription)", "Could not read the profile index: \(error.localizedDescription)")) }
        } else {
            let first = ProfileDescriptor(name: L("我的阅读库", "My Library"))
            loadedProfiles = [first]
            loadedProfileID = first.id
            needsInitialIndex = true
        }
        profiles = loadedProfiles
        activeProfileID = loadedProfileID
        let profileName = loadedProfiles.first(where: { $0.id == loadedProfileID })?.name ?? ""
        archive = ProfileArchive(id: loadedProfileID, name: profileName)
        if needsInitialIndex {
            archive = try addingBundledCollections(to: archive)
            try persistArchive(archive, profileID: activeProfileID, makingBackup: false)
            try persistIndex()
        }
        try loadActiveProfile()
        refreshArticleFiles()
        fileRefreshTimer = Timer.publish(every: 0.75, on: .main, in: .common)
            .autoconnect().sink { [weak self] _ in self?.refreshArticleFiles() }
    }

    public var activeProfile: ProfileDescriptor {
        profiles.first(where: { $0.id == activeProfileID })!
    }

    public var entries: [LibraryEntry] {
        let grouped = Dictionary(grouping: cards, by: { Self.associationKey($0.expression) })
        return grouped.keys.sorted().compactMap { key in
            guard let records = grouped[key] else { return nil }
            let meanings = Dictionary(grouping: records, by: \.meaning)
                .keys.sorted().compactMap { meaning -> LibraryMeaningGroup? in
                    guard let meaningCards = Dictionary(grouping: records, by: \.meaning)[meaning] else { return nil }
                    let sources = meaningCards.compactMap { card in articles.first(where: { $0.id == card.articleID }) }
                    return LibraryMeaningGroup(meaning: meaning, cards: meaningCards.sorted { $0.createdAt < $1.createdAt },
                                               sources: Self.uniqueArticles(sources))
                }
            return LibraryEntry(key: key, expressions: Array(Set(records.map(\.expression))).sorted(),
                                cards: records.sorted { $0.createdAt < $1.createdAt }, meanings: meanings)
        }
    }

    public func cards(articleID: UUID) -> [StudyCard] {
        cards.filter { $0.articleID == articleID }.sorted { $0.start < $1.start }
    }

    public func cards(expression: String) -> [StudyCard] {
        let key = Self.associationKey(expression)
        return cards.filter { Self.associationKey($0.expression) == key }.sorted { $0.createdAt < $1.createdAt }
    }

    public func records(entryKey: String, meaning: String? = nil) -> [StudyCard] {
        cards.filter {
            Self.associationKey($0.expression) == Self.associationKey(entryKey) &&
            (meaning == nil || $0.meaning == meaning)
        }.sorted { $0.createdAt < $1.createdAt }
    }

    public func article(id: UUID) -> LibraryArticle? { articles.first { $0.id == id } }
    public func folder(id: UUID) -> LibraryFolder? { folders.first { $0.id == id } }
    public func card(id: UUID) -> StudyCard? { cards.first { $0.id == id } }

    public func originalSentence(for card: StudyCard) -> String {
        if let snapshot = card.originalSentence,
           !snapshot.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return snapshot
        }
        guard card.isDetached != true, let article = article(id: card.articleID) else {
            return card.selectedText
        }
        return SelectionContext.focusedSentence(from: article.text,
            scalarStart: card.start, scalarEnd: card.end, expectedSelection: card.selectedText,
            articleTitle: article.title) ?? card.selectedText
    }

    @discardableResult
    public func createProfile(name: String) throws -> ProfileDescriptor {
        let name = try Self.validName(name)
        let descriptor = ProfileDescriptor(name: name)
        let initial = try addingBundledCollections(to: ProfileArchive(
            id: descriptor.id, name: descriptor.name, createdAt: descriptor.createdAt))
        try persistArchive(initial, profileID: descriptor.id, makingBackup: false)
        profiles.append(descriptor)
        activeProfileID = descriptor.id
        try persistIndex()
        try publish(initial)
        return descriptor
    }

    public func selectProfile(id: UUID) throws {
        guard profiles.contains(where: { $0.id == id }) else { throw ReadingLibraryError.missingProfile }
        guard activeProfileID != id else { return }
        let nextArchive = try readArchive(profileID: id)
        let previousID = activeProfileID
        activeProfileID = id
        do {
            try persistIndex()
            try publish(nextArchive)
        } catch {
            activeProfileID = previousID
            throw error
        }
        objectWillChange.send()
    }

    public func selectProfile(_ id: UUID) throws { try selectProfile(id: id) }

    public func renameProfile(id: UUID, name: String) throws {
        guard let index = profiles.firstIndex(where: { $0.id == id }) else { throw ReadingLibraryError.missingProfile }
        let clean = try Self.validName(name)
        guard profiles[index].name != clean else { return }
        profiles[index].name = clean
        profiles[index].modifiedAt = Date()
        if id == activeProfileID {
            var next = revision
            next.name = clean
            try commit(next)
        } else {
            let url = archiveURL(id)
            guard fileManager.fileExists(atPath: url.path) else { throw ReadingLibraryError.invalidArchive }
            var other: ProfileArchive
            do { other = try Self.decoder().decode(ProfileArchive.self, from: Data(contentsOf: url)) }
            catch { throw ReadingLibraryError.invalidArchive }
            try Self.validate(other)
            other.name = clean
            try persistArchive(other, profileID: id, makingBackup: true)
            try persistIndex()
        }
    }

    public func renameProfile(_ id: UUID, name: String) throws { try renameProfile(id: id, name: name) }

    public func deleteProfile(id: UUID) throws {
        guard let index = profiles.firstIndex(where: { $0.id == id }) else { throw ReadingLibraryError.missingProfile }
        guard profiles.count > 1 else { throw ReadingLibraryError.lastProfile }
        let wasActive = activeProfileID == id
        let replacement = wasActive ? profiles.first(where: { $0.id != id })! : nil
        let replacementArchive = try replacement.map { try readArchive(profileID: $0.id) }
        let oldProfiles = profiles
        let oldActiveID = activeProfileID
        let oldArchive = archive
        profiles.remove(at: index)
        if let replacement {
            activeProfileID = replacement.id
            if let replacementArchive { try publish(replacementArchive) }
        }
        do {
            try persistIndex()
        } catch {
            profiles = oldProfiles
            activeProfileID = oldActiveID
            try publish(oldArchive)
            throw error
        }
        let profileURL = profileDirectory(id)
        try? fileManager.removeItem(at: profileURL)
        objectWillChange.send()
    }

    public func deleteProfile(_ id: UUID) throws { try deleteProfile(id: id) }

    @discardableResult
    public func createFolder(name: String) throws -> LibraryFolder {
        let folder = LibraryFolder(name: try Self.validName(name))
        var next = revision
        next.folders.append(folder)
        try commit(next)
        return folder
    }

    public func renameFolder(id: UUID, name: String) throws {
        guard let index = revision.folders.firstIndex(where: { $0.id == id }) else { throw ReadingLibraryError.missingFolder }
        let clean = try Self.validName(name)
        guard revision.folders[index].name != clean else { return }
        var next = revision
        next.folders[index].name = clean
        try commit(next)
    }

    public func renameFolder(_ id: UUID, name: String) throws { try renameFolder(id: id, name: name) }

    public func deleteFolder(id: UUID) throws {
        guard revision.folders.contains(where: { $0.id == id }) else { throw ReadingLibraryError.missingFolder }
        var next = revision
        next.folders.removeAll { $0.id == id }
        for index in next.articles.indices where next.articles[index].folderID == id { next.articles[index].folderID = nil }
        try commit(next)
    }

    public func deleteFolder(_ id: UUID) throws { try deleteFolder(id: id) }

    @discardableResult
    public func addMarkdown(markdown: String, sourceName: String, folderID: UUID? = nil,
                            sourceFilePath: String? = nil) throws -> LibraryArticle {
        let parsed = try Self.parseMarkdown(markdown)
        if let folderID, !revision.folders.contains(where: { $0.id == folderID }) { throw ReadingLibraryError.missingFolder }
        let article = LibraryArticle(title: parsed.title, sourceName: sourceName, markdown: markdown,
                                     text: parsed.text, folderID: folderID, sourceFilePath: sourceFilePath)
        var next = revision
        next.articles.append(article)
        next.lastArticleID = article.id
        try commit(next)
        return article
    }

    @discardableResult
    public func importMarkdown(from url: URL, folderID: UUID? = nil) throws -> UUID {
        do {
            let markdown = try ArticleDraft.read(from: url).markdown
            return try addMarkdown(markdown: markdown, sourceName: url.lastPathComponent, folderID: folderID,
                                   sourceFilePath: url.standardizedFileURL.path).id
        } catch let error as ReadingLibraryError { throw error }
        catch { throw ReadingLibraryError.fileAccess(L("无法导入 Markdown：\(error.localizedDescription)", "Could not import Markdown: \(error.localizedDescription)")) }
    }

    public func articleFileURL(_ id: UUID) throws -> URL {
        guard let article = article(id: id) else { throw ReadingLibraryError.missingArticle }
        return fileURL(for: article, profileID: activeProfileID)
    }

    /// Compare metadata first so unchanged files do not need to be read or parsed.
    public func refreshArticleFiles() {
        var next = archive
        var errors = fileSyncErrors
        var stamps = fileStamps
        for index in next.articles.indices {
            let article = next.articles[index]
            let url = fileURL(for: article, profileID: activeProfileID)
            let stamp = fileStamp(at: url)
            guard stamp != fileStamps[url] else { continue }
            stamps[url] = stamp
            do {
                let markdown: String
                if article.sourceFilePath != nil {
                    markdown = try ArticleDraft.read(from: url).markdown
                } else {
                    // Managed copies always contain canonical Markdown, even if
                    // their original display filename had a .txt extension.
                    markdown = try String(contentsOf: url, encoding: .utf8)
                }
                errors[article.id] = nil
                guard markdown != article.markdown else { continue }
                let parsed = try Self.parseMarkdown(markdown)
                let updated = ArticleRevision.replace(article, markdown: markdown,
                    title: parsed.title, text: parsed.text,
                    cards: next.cards.filter { $0.articleID == article.id })
                next.articles[index] = updated.article
                next.cards.removeAll { $0.articleID == article.id }
                next.cards.append(contentsOf: updated.cards)
            } catch {
                errors[article.id] = L("文件暂时无法更新，正在显示上次保存的内容：\(error.localizedDescription)",
                                       "The file could not be updated. Showing the last saved content: \(error.localizedDescription)")
            }
        }
        fileStamps = stamps
        if next != archive {
            do { try commit(next) }
            catch {
                // Retry a failed archive write on the next pass without losing the file edit.
                fileStamps.removeAll()
                for article in next.articles {
                    errors[article.id] = error.localizedDescription
                }
            }
        }
        if fileSyncErrors != errors { fileSyncErrors = errors }
    }

    private func fileURL(for article: LibraryArticle, profileID: UUID) -> URL {
        if let path = article.sourceFilePath {
            return URL(fileURLWithPath: path).standardizedFileURL
        }
        let name = (article.sourceName as NSString).lastPathComponent
        return profileDirectory(profileID).appendingPathComponent("Articles", isDirectory: true)
            .appendingPathComponent(article.id.uuidString, isDirectory: true)
            .appendingPathComponent(name.isEmpty ? "article.md" : name)
    }

    private func prepareArticleFiles() {
        if synchronizedProfileID != activeProfileID {
            synchronizedProfileID = activeProfileID
            fileStamps.removeAll()
            fileSyncErrors.removeAll()
        }
        let urls = Set(archive.articles.map { fileURL(for: $0, profileID: activeProfileID) })
        fileStamps = fileStamps.filter { urls.contains($0.key) }
        fileSyncErrors = fileSyncErrors.filter { id, _ in archive.articles.contains { $0.id == id } }
        for article in archive.articles {
            let url = fileURL(for: article, profileID: activeProfileID)
            if article.sourceFilePath == nil, preparedFiles.insert(url).inserted {
                do {
                    if !fileManager.fileExists(atPath: url.path) {
                        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                        try Data(article.markdown.utf8).write(to: url, options: .atomic)
                    }
                } catch { fileSyncErrors[article.id] = error.localizedDescription }
            }
        }
    }

    private enum ArticleFileStamp: Equatable {
        case missing
        case present(Date?, UInt64, UInt64?)
    }

    private func fileStamp(at url: URL) -> ArticleFileStamp {
        guard let values = try? fileManager.attributesOfItem(atPath: url.path) else { return .missing }
        return .present(values[.modificationDate] as? Date,
                        (values[.size] as? NSNumber)?.uint64Value ?? 0,
                        (values[.systemFileNumber] as? NSNumber)?.uint64Value)
    }

    public func moveArticle(id: UUID, folderID: UUID?) throws {
        guard let index = revision.articles.firstIndex(where: { $0.id == id }) else { throw ReadingLibraryError.missingArticle }
        if let folderID, !revision.folders.contains(where: { $0.id == folderID }) { throw ReadingLibraryError.missingFolder }
        guard revision.articles[index].folderID != folderID else { return }
        var next = revision
        next.articles[index].folderID = folderID
        try commit(next)
    }

    public func moveArticle(_ id: UUID, to folderID: UUID?) throws { try moveArticle(id: id, folderID: folderID) }

    public func deleteArticle(_ id: UUID) throws {
        guard revision.articles.contains(where: { $0.id == id }) else { throw ReadingLibraryError.missingArticle }
        var next = revision
        next.articles.removeAll { $0.id == id }
        next.cards.removeAll { $0.articleID == id }
        if next.lastArticleID == id { next.lastArticleID = nil }
        try commit(next)
    }

    public func exportArticle(_ id: UUID, to url: URL) throws {
        guard let article = revision.articles.first(where: { $0.id == id }) else { throw ReadingLibraryError.missingArticle }
        do { try Data(article.markdown.utf8).write(to: url, options: .atomic) }
        catch { throw ReadingLibraryError.fileAccess(L("无法导出文章：\(error.localizedDescription)", "Could not export the article: \(error.localizedDescription)")) }
    }

    public func setReadOffset(articleID: UUID, offset: Int) throws {
        guard let index = revision.articles.firstIndex(where: { $0.id == articleID }) else { throw ReadingLibraryError.missingArticle }
        let maximum = revision.articles[index].text.unicodeScalars.count
        guard (0...maximum).contains(offset) else { throw ReadingLibraryError.invalidRange }
        guard revision.articles[index].readOffset != offset || revision.lastArticleID != articleID else { return }
        var next = revision
        next.articles[index].readOffset = offset
        next.lastArticleID = articleID
        try commit(next)
    }

    public func setReadOffset(_ offset: Int, articleID: UUID) throws {
        try setReadOffset(articleID: articleID, offset: offset)
    }

    func intensiveTranslations(articleID: UUID, targetLanguage: StudyLanguage) throws -> [String: IntensiveReadingTranslation] {
        guard let article = revision.articles.first(where: { $0.id == articleID }) else {
            throw ReadingLibraryError.missingArticle
        }
        let currentSentences = Set(SelectionContext.sentenceRanges(in: article.text, articleTitle: article.title)
            .map { (article.text as NSString).substring(with: $0) })
        var results: [String: IntensiveReadingTranslation] = [:]

        if let bundledURL = BundledArticleCollection.bundledIntensiveReadingCacheURL(),
           fileManager.fileExists(atPath: bundledURL.path) {
            if let bundledCache = try? Self.decoder().decode(IntensiveReadingCacheFile.self, from: Data(contentsOf: bundledURL)),
               bundledCache.version == 1 {
                for entry in bundledCache.entries {
                    if entry.articleID == articleID, entry.targetLanguage == targetLanguage,
                       currentSentences.contains(entry.result.sourceSentence),
                       entry.result.isValid(for: entry.result.sourceSentence) {
                        results[entry.result.sourceSentence] = entry.result
                    }
                }
            }
        }

        let url = intensiveCacheURL(activeProfileID)
        guard fileManager.fileExists(atPath: url.path) else { return results }
        do {
            let cache = try Self.decoder().decode(IntensiveReadingCacheFile.self, from: Data(contentsOf: url))
            guard cache.version == 1 else { throw ReadingLibraryError.invalidArchive }
            for entry in cache.entries {
                if entry.articleID == articleID, entry.targetLanguage == targetLanguage,
                   currentSentences.contains(entry.result.sourceSentence),
                   entry.result.isValid(for: entry.result.sourceSentence) {
                    results[entry.result.sourceSentence] = entry.result
                }
            }
            return results
        } catch {
            throw ReadingLibraryError.fileAccess(L("无法读取精读缓存：\(error.localizedDescription)", "Could not read intensive reading cache: \(error.localizedDescription)"))
        }
    }

    func saveIntensiveTranslation(_ result: IntensiveReadingTranslation, articleID: UUID,
                                  targetLanguage: StudyLanguage) throws {
        guard let article = revision.articles.first(where: { $0.id == articleID }),
              result.isValid(for: result.sourceSentence) else { throw ReadingLibraryError.invalidRange }
        let currentSentences = Set(SelectionContext.sentenceRanges(in: article.text, articleTitle: article.title)
            .map { (article.text as NSString).substring(with: $0) })
        guard currentSentences.contains(result.sourceSentence) else { throw ReadingLibraryError.invalidRange }
        let url = intensiveCacheURL(activeProfileID)
        var cache = IntensiveReadingCacheFile()
        if fileManager.fileExists(atPath: url.path) {
            do { cache = try Self.decoder().decode(IntensiveReadingCacheFile.self, from: Data(contentsOf: url)) }
            catch {
                throw ReadingLibraryError.fileAccess(L("无法读取精读缓存：\(error.localizedDescription)", "Could not read intensive reading cache: \(error.localizedDescription)"))
            }
            guard cache.version == 1 else { throw ReadingLibraryError.invalidArchive }
        }
        cache.entries.removeAll {
            $0.articleID == articleID &&
                (!currentSentences.contains($0.result.sourceSentence) ||
                    ($0.targetLanguage == targetLanguage && $0.result.sourceSentence == result.sourceSentence))
        }
        cache.entries.append(IntensiveReadingCacheEntry(articleID: articleID, targetLanguage: targetLanguage,
                                                        result: result))
        do {
            try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Self.encoder().encode(cache).write(to: url, options: .atomic)
        } catch {
            throw ReadingLibraryError.fileAccess(L("无法保存精读结果：\(error.localizedDescription)", "Could not save the intensive reading result: \(error.localizedDescription)"))
        }
    }

    /// Uses the same UTF-16 validation and scalar overlap rules as saving a card.
    public func cardSelectionStatus(articleID: UUID, range: NSRange,
                                    excludingCardID: UUID? = nil) throws -> StudyCardSelectionStatus {
        guard let article = article(id: articleID) else { throw ReadingLibraryError.missingArticle }
        let (start, end, _) = try Self.scalarRange(range, in: article.text)
        return cardSelectionStatus(articleID: articleID, start: start, end: end,
                                   excludingCardID: excludingCardID)
    }

    private func cardSelectionStatus(articleID: UUID, start: Int, end: Int,
                                     excludingCardID: UUID?) -> StudyCardSelectionStatus {
        for card in revision.cards where card.articleID == articleID &&
            card.id != excludingCardID && card.isDetached != true {
            if start == card.start && end == card.end { return .existing(card) }
            if start < card.end && card.start < end { return .overlapping }
        }
        return .available
    }

    @discardableResult
    public func saveCard(id: UUID? = nil, articleID: UUID, range: NSRange,
                         expression: String, meaning: String) throws -> StudyCard {
        guard let article = revision.articles.first(where: { $0.id == articleID }) else { throw ReadingLibraryError.missingArticle }
        let key = Self.associationKey(expression)
        guard !key.isEmpty else { throw ReadingLibraryError.emptyExpression }
        guard !meaning.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ReadingLibraryError.emptyMeaning }
        let (start, end, selected) = try Self.scalarRange(range, in: article.text)
        let existing = id.flatMap { requestedID in revision.cards.first(where: { $0.id == requestedID }) }
        if id != nil && existing == nil { throw ReadingLibraryError.missingCard }
        if let existing, existing.articleID != articleID || existing.start != start || existing.end != end {
            throw ReadingLibraryError.invalidRange
        }
        guard cardSelectionStatus(articleID: articleID, start: start, end: end,
                                  excludingCardID: id) == .available else {
            throw ReadingLibraryError.overlappingCard
        }
        let now = Date()
        // Editing a card changes its explanation, never its historical source context.
        let originalSentence: String?
        if let existing {
            originalSentence = existing.originalSentence
        } else {
            originalSentence = (try? SelectionContext.extract(from: article.text, range: range,
                articleTitle: article.title).focusedSentence) ?? selected
        }
        let card = StudyCard(id: existing?.id ?? UUID(), articleID: articleID, start: start, end: end,
                             selectedText: selected, expression: expression, meaning: meaning,
                             createdAt: existing?.createdAt ?? now, updatedAt: now,
                             originalSentence: originalSentence)
        var next = revision
        next.cards.removeAll { $0.id == card.id }
        next.cards.append(card)
        try commit(next)
        return card
    }

    public func deleteCard(id: UUID) throws {
        guard revision.cards.contains(where: { $0.id == id }) else { throw ReadingLibraryError.missingCard }
        var next = revision
        next.cards.removeAll { $0.id == id }
        try commit(next)
    }

    public func deleteCard(_ id: UUID) throws { try deleteCard(id: id) }

    /// Edits a saved field without consulting or rebuilding its historical source anchor.
    /// The caller captures IDs when editing starts, rather than finding a text group at save time.
    @discardableResult
    func updateCardFields(profileID: UUID, cardIDs: [UUID], field: StudyCardEditableField,
                          value: String, expectedValue: String? = nil) throws -> StudyCardFieldEdit? {
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let original = try cardFieldArchive(profileID: profileID)
        let ids = Set(cardIDs)
        guard !ids.isEmpty, ids.count == cardIDs.count else { throw ReadingLibraryError.missingCard }
        let records = original.cards.filter { ids.contains($0.id) }
        guard records.count == ids.count else { throw ReadingLibraryError.missingCard }
        if let expectedValue, records.contains(where: { field.value(in: $0) != expectedValue }) {
            throw StudyInlineEditError.recordChanged
        }
        let before = Dictionary(uniqueKeysWithValues: records.map { ($0.id, field.value(in: $0)) })
        guard before.values.contains(where: { $0 != value }) else { return nil }
        let edit = StudyCardFieldEdit(profileID: profileID, field: field, before: before,
                                     after: Dictionary(uniqueKeysWithValues: records.map { ($0.id, value) }))
        try applyCardFieldEdit(edit)
        return edit
    }

    /// Undo/redo changes only the recorded field, retaining later changes to all other fields.
    func applyCardFieldEdit(_ edit: StudyCardFieldEdit) throws {
        var next = try cardFieldArchive(profileID: edit.profileID)
        guard Set(edit.before.keys) == Set(edit.after.keys), !edit.before.isEmpty else {
            throw ReadingLibraryError.missingCard
        }
        let indices = next.cards.indices.filter { edit.before[next.cards[$0].id] != nil }
        guard indices.count == edit.before.count else { throw ReadingLibraryError.missingCard }
        for index in indices {
            let card = next.cards[index]
            guard edit.field.value(in: card) == edit.before[card.id] else { throw StudyInlineEditError.recordChanged }
            guard let value = edit.after[card.id], !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw edit.field == .expression ? ReadingLibraryError.emptyExpression : ReadingLibraryError.emptyMeaning
            }
        }
        let now = Date()
        for index in indices {
            let id = next.cards[index].id
            edit.field.set(edit.after[id]!, in: &next.cards[index])
            next.cards[index].updatedAt = now
        }
        // A field edit has one durability boundary. In particular, an index write after this
        // atomic archive write must not turn an already-saved edit into an apparent failure.
        // No article-file preparation, anchor validation, or source synchronization runs here.
        try persistArchive(next, profileID: edit.profileID, makingBackup: true)
        if activeProfileID == edit.profileID { archive = next }
    }

    private func cardFieldArchive(profileID: UUID) throws -> ProfileArchive {
        guard profiles.contains(where: { $0.id == profileID }) else { throw ReadingLibraryError.missingProfile }
        if profileID == activeProfileID { return archive }
        do {
            let saved = try Self.decoder().decode(ProfileArchive.self, from: Data(contentsOf: archiveURL(profileID)))
            guard saved.id == profileID, saved.version == 1 else { throw ReadingLibraryError.invalidArchive }
            return saved
        } catch let error as ReadingLibraryError { throw error }
        catch { throw ReadingLibraryError.fileAccess(error.localizedDescription) }
    }

    public func exportActiveProfile(to url: URL) throws {
        do {
            let data = try Self.encoder().encode(revision)
            try data.write(to: url, options: .atomic)
        } catch { throw ReadingLibraryError.fileAccess(L("无法导出档案：\(error.localizedDescription)", "Could not export the profile: \(error.localizedDescription)")) }
    }

    public func automaticBackups(profileID: UUID? = nil) -> [URL] {
        let id = profileID ?? activeProfileID
        guard profiles.contains(where: { $0.id == id }) else { return [] }
        let directory = profileDirectory(id).appendingPathComponent("Backups", isDirectory: true)
        guard let files = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else {
            return []
        }
        return files.filter { $0.pathExtension.lowercased() == "json" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    public func restoreAutomaticBackup(from url: URL) throws {
        let backupDirectory = profileDirectory(activeProfileID)
            .appendingPathComponent("Backups", isDirectory: true).standardizedFileURL
        guard url.standardizedFileURL.deletingLastPathComponent() == backupDirectory,
              url.pathExtension.lowercased() == "json" else {
            throw ReadingLibraryError.invalidArchive
        }
        let restored: ProfileArchive
        do { restored = try Self.decoder().decode(ProfileArchive.self, from: Data(contentsOf: url)) }
        catch { throw ReadingLibraryError.invalidArchive }
        guard restored.id == activeProfileID, restored.version == 1 else {
            throw ReadingLibraryError.invalidArchive
        }
        try Self.validate(restored)
        var local = restored
        local.name = activeProfile.name
        for index in local.articles.indices { local.articles[index].sourceFilePath = nil }
        local = try addingBundledCollections(to: local)
        // Restoring a snapshot explicitly restores its managed files below.
        local = try updatingBundledContents(in: local, synchronizeManagedFiles: false)
        local = try updatingMarkdownFormatting(in: updatingBundledTitles(in: local))
        try persistArchive(local, profileID: activeProfileID, makingBackup: true)
        try writeManagedArticleSnapshots(in: local)
        fileStamps.removeAll()
        if let index = profiles.firstIndex(where: { $0.id == activeProfileID }) {
            profiles[index].modifiedAt = Date()
        }
        try persistIndex()
        try publish(local)
    }

    @discardableResult
    public func importProfile(from url: URL) throws -> ProfileDescriptor {
        let decoded: ProfileArchive
        do { decoded = try Self.decoder().decode(ProfileArchive.self, from: Data(contentsOf: url)) }
        catch { throw ReadingLibraryError.invalidArchive }
        guard decoded.version == 1 else { throw ReadingLibraryError.unsupportedArchive }
        try Self.validate(decoded)
        var name = try Self.validName(decoded.profileName)
        if profiles.contains(where: { $0.name == name }) { name += L(" (导入)", " (Imported)") }
        let descriptor = ProfileDescriptor(name: name)
        var local = decoded
        local.id = descriptor.id
        local.name = descriptor.name
        local.createdAt = descriptor.createdAt
        for index in local.articles.indices { local.articles[index].sourceFilePath = nil }
        local = try addingBundledCollections(to: local)
        // Imported copies get new, independent managed files when published.
        local = try updatingBundledContents(in: local, synchronizeManagedFiles: false)
        local = try updatingMarkdownFormatting(in: updatingBundledTitles(in: local))
        try persistArchive(local, profileID: descriptor.id, makingBackup: false)
        profiles.append(descriptor)
        activeProfileID = descriptor.id
        try publish(local)
        try persistIndex()
        objectWillChange.send()
        return descriptor
    }

    private func commit(_ next: ProfileArchive) throws {
        try Self.validate(next)
        var updated = next
        if let index = profiles.firstIndex(where: { $0.id == activeProfileID }) {
            profiles[index].modifiedAt = Date()
            updated.name = profiles[index].name
            try persistArchive(updated, profileID: activeProfileID, makingBackup: true)
            try persistIndex()
        } else {
            throw ReadingLibraryError.missingProfile
        }
        try publish(updated)
    }

    private func publish(_ archive: ProfileArchive) throws {
        self.archive = archive
        prepareArticleFiles()
        objectWillChange.send()
    }

    private func loadActiveProfile() throws {
        try publish(readArchive(profileID: activeProfileID))
    }

    private func readArchive(profileID: UUID) throws -> ProfileArchive {
        let url = archiveURL(profileID)
        if fileManager.fileExists(atPath: url.path) {
            do {
                let archive = try Self.decoder().decode(ProfileArchive.self, from: Data(contentsOf: url))
                guard archive.version == 1, archive.id == profileID else { throw ReadingLibraryError.invalidArchive }
                try Self.validate(archive)
                let seeded = try updatingMarkdownFormatting(in: updatingBundledTitles(in: updatingBundledContents(in: addingBundledCollections(to: archive))))
                if seeded != archive {
                    try persistArchive(seeded, profileID: profileID, makingBackup: true)
                }
                return seeded
            } catch let error as ReadingLibraryError { throw error }
            catch { throw ReadingLibraryError.fileAccess(L("无法读取档案：\(error.localizedDescription)", "Could not read the profile: \(error.localizedDescription)")) }
        } else { throw ReadingLibraryError.invalidArchive }
    }

    /// Only selectable text changes; the original Markdown and external files stay intact.
    private func updatingMarkdownFormatting(in original: ProfileArchive) throws -> ProfileArchive {
        var next = original
        for index in next.articles.indices {
            let article = next.articles[index]
            // Earlier archives may intentionally contain Author:/Date: as prose.
            // Keep their original field semantics rather than consuming that text.
            if let literalFields = try? Self.parseLegacyMarkdown(article.markdown, recognizeMetadata: false),
               literalFields.text == article.text,
               let headerFields = try? Self.parseLegacyMarkdown(article.markdown),
               headerFields.text != article.text { continue }
            let parsed = try Self.parseMarkdown(article.markdown)
            guard parsed.text != article.text || parsed.title != article.title else { continue }
            let revision = ArticleRevision.replace(article, markdown: article.markdown,
                title: parsed.title, text: parsed.text, cards: next.cards)
            next.articles[index] = revision.article
            next.cards = revision.cards
        }
        try Self.validate(next)
        return next
    }

    private func addingBundledCollections(to original: ProfileArchive) throws -> ProfileArchive {
        var next = original
        for collection in bundledCollections where !next.seededCollections.contains(collection.id) {
            let missing = collection.articles.filter { bundled in
                !next.articles.contains {
                    $0.id == bundled.id || $0.sourceURL == bundled.sourceURL
                }
            }
            if !missing.isEmpty {
                let folder: LibraryFolder
                if let existing = next.folders.first(where: {
                    $0.name.trimmingCharacters(in: .whitespacesAndNewlines)
                        .caseInsensitiveCompare(collection.folderName) == .orderedSame
                }) {
                    folder = existing
                } else {
                    folder = LibraryFolder(name: collection.folderName)
                    next.folders.append(folder)
                }
                for bundled in missing {
                    let parsed = try Self.parseMarkdown(bundled.markdown)
                    guard parsed.title == bundled.title else { throw ReadingLibraryError.invalidArchive }
                    next.articles.append(LibraryArticle(
                        id: bundled.id, title: parsed.title, sourceName: bundled.file,
                        sourceURL: bundled.sourceURL, markdown: bundled.markdown, text: parsed.text,
                        folderID: folder.id))
                }
            }
            next.seededCollections.append(collection.id)
        }
        try Self.validate(next)
        return next
    }

    /// Revise exact distributed copies without reseeding deletions or replacing user edits.
    private func updatingBundledContents(in original: ProfileArchive,
                                         synchronizeManagedFiles: Bool = true) throws -> ProfileArchive {
        var next = original
        let bundled = bundledCollections.flatMap(\.articles)
        var writes: [(URL, String)] = []
        for index in next.articles.indices {
            let article = next.articles[index]
            guard article.sourceFilePath == nil,
                  let canonical = bundled.first(where: { $0.id == article.id }),
                  !canonical.previousMarkdownSHA256.isEmpty,
                  article.markdown != canonical.markdown,
                  canonical.previousMarkdownSHA256.contains(BundledArticle.markdownSHA256(article.markdown)) else { continue }
            let url = fileURL(for: article, profileID: next.id)
            if synchronizeManagedFiles, fileManager.fileExists(atPath: url.path) {
                // A pending edit in an external Markdown editor wins over an update.
                guard let saved = try? String(contentsOf: url, encoding: .utf8),
                      saved == article.markdown else { continue }
            }
            let parsed = try Self.parseMarkdown(canonical.markdown)
            guard parsed.title == canonical.title else { throw ReadingLibraryError.invalidArchive }
            let revised = ArticleRevision.replace(article, markdown: canonical.markdown,
                                                  title: parsed.title, text: parsed.text,
                                                  cards: next.cards)
            next.articles[index] = revised.article
            next.cards = revised.cards
            if synchronizeManagedFiles { writes.append((url, canonical.markdown)) }
        }
        try Self.validate(next)
        // The archive's normal migration backup retains the original Markdown.
        // A partial write can also be recovered by the normal file-sync revision path.
        for (url, markdown) in writes {
            try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(markdown.utf8).write(to: url, options: .atomic)
        }
        return next
    }

    /// Apply capitalization changes without reseeding deleted articles or replacing edited bodies.
    private func updatingBundledTitles(in original: ProfileArchive) throws -> ProfileArchive {
        var next = original
        let bundled = bundledCollections.flatMap(\.articles)
        for index in next.articles.indices {
            let article = next.articles[index]
            guard let canonical = bundled.first(where: {
                $0.id == article.id || $0.sourceURL == article.sourceURL
            }), article.title != canonical.title,
                  article.title.caseInsensitiveCompare(canonical.title) == .orderedSame,
                  let heading = article.markdown.range(of: "(?m)^#{1,2} +[^\\r\\n]+", options: .regularExpression) else { continue }
            var markdown = article.markdown
            markdown.replaceSubrange(heading, with: "# " + canonical.title)
            let parsed = try Self.parseMarkdown(markdown)
            let revised = ArticleRevision.replace(article, markdown: markdown, title: parsed.title,
                                                  text: parsed.text, cards: next.cards)
            next.articles[index] = revised.article
            next.cards = revised.cards
            if article.sourceFilePath == nil {
                let url = fileURL(for: article, profileID: next.id)
                // A file already edited by the user takes precedence when it is refreshed.
                if let saved = try? String(contentsOf: url, encoding: .utf8), saved == article.markdown {
                    try Data(markdown.utf8).write(to: url, options: .atomic)
                }
            }
        }
        try Self.validate(next)
        return next
    }

    /// Restoring a snapshot also restores its editable copies, independently of imported originals.
    private func writeManagedArticleSnapshots(in snapshot: ProfileArchive) throws {
        for article in snapshot.articles where article.sourceFilePath == nil {
            let url = fileURL(for: article, profileID: snapshot.id)
            try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(article.markdown.utf8).write(to: url, options: .atomic)
        }
    }

    private func persistArchive(_ archive: ProfileArchive, profileID: UUID, makingBackup: Bool) throws {
        do {
            let directory = profileDirectory(profileID)
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            let destination = archiveURL(profileID)
            if makingBackup, fileManager.fileExists(atPath: destination.path) {
                let backupDirectory = directory.appendingPathComponent("Backups", isDirectory: true)
                try fileManager.createDirectory(at: backupDirectory, withIntermediateDirectories: true)
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                let stamp = formatter.string(from: Date()).replacingOccurrences(of: ":", with: "-")
                let backup = backupDirectory.appendingPathComponent("\(stamp)-\(UUID().uuidString).json")
                try fileManager.copyItem(at: destination, to: backup)
                let backups = try fileManager.contentsOfDirectory(at: backupDirectory, includingPropertiesForKeys: nil)
                    .sorted { $0.lastPathComponent > $1.lastPathComponent }
                for old in backups.dropFirst(Self.backupLimit) { try? fileManager.removeItem(at: old) }
            }
            try Self.encoder().encode(archive).write(to: destination, options: .atomic)
        } catch { throw ReadingLibraryError.fileAccess(L("无法保存档案：\(error.localizedDescription)", "Could not save the profile: \(error.localizedDescription)")) }
    }

    private func persistIndex() throws {
        do {
            try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
            let index = Index(activeProfileID: activeProfileID, profiles: profiles)
            try Self.encoder().encode(index).write(to: rootURL.appendingPathComponent("profiles.json"), options: .atomic)
        } catch { throw ReadingLibraryError.fileAccess(L("无法保存档案列表：\(error.localizedDescription)", "Could not save the profile list: \(error.localizedDescription)")) }
    }

    private func archiveURL(_ id: UUID) -> URL { profileDirectory(id).appendingPathComponent("library.json") }
    private func intensiveCacheURL(_ id: UUID) -> URL { profileDirectory(id).appendingPathComponent("intensive-reading.json") }
    private func profileDirectory(_ id: UUID) -> URL { rootURL.appendingPathComponent("Profiles", isDirectory: true).appendingPathComponent(id.uuidString, isDirectory: true) }

    private static func associationKey(_ expression: String) -> String {
        expression.replacingOccurrences(of: "...", with: "…")
            .split(whereSeparator: \.isWhitespace).joined(separator: " ").lowercased()
    }

    private static func validName(_ value: String) throws -> String {
        let name = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw ReadingLibraryError.invalidName }
        return name
    }

    private static func uniqueArticles(_ articles: [LibraryArticle]) -> [LibraryArticle] {
        var seen = Set<UUID>()
        return articles.filter { seen.insert($0.id).inserted }
    }

    private static func scalarRange(_ range: NSRange, in text: String) throws -> (Int, Int, String) {
        guard range.location >= 0, range.length > 0, range.location <= (text as NSString).length,
              range.length <= (text as NSString).length - range.location,
              (text as NSString).rangeOfComposedCharacterSequences(for: range) == range,
              let swiftRange = Range(range, in: text) else { throw ReadingLibraryError.invalidRange }
        let start = text[..<swiftRange.lowerBound].unicodeScalars.count
        let selected = String(text[swiftRange])
        return (start, start + selected.unicodeScalars.count, selected)
    }

    private static func selectedText(start: Int, end: Int, from text: String) throws -> String {
        let scalars = text.unicodeScalars
        guard start >= 0, end > start, end <= scalars.count else { throw ReadingLibraryError.invalidRange }
        let lower = scalars.index(scalars.startIndex, offsetBy: start)
        let upper = scalars.index(scalars.startIndex, offsetBy: end)
        guard let lowerIndex = String.Index(lower, within: text), let upperIndex = String.Index(upper, within: text) else {
            throw ReadingLibraryError.invalidRange
        }
        return String(text[lowerIndex..<upperIndex])
    }

    private static func validate(_ archive: ProfileArchive) throws {
        guard archive.version == 1 else { throw ReadingLibraryError.unsupportedArchive }
        guard Set(archive.folders.map(\.id)).count == archive.folders.count,
              Set(archive.articles.map(\.id)).count == archive.articles.count,
              Set(archive.cards.map(\.id)).count == archive.cards.count else { throw ReadingLibraryError.invalidArchive }
        let folderIDs = Set(archive.folders.map(\.id))
        let articles = Dictionary(uniqueKeysWithValues: archive.articles.map { ($0.id, $0) })
        guard archive.lastArticleID == nil || articles[archive.lastArticleID!] != nil else { throw ReadingLibraryError.invalidArchive }
        for article in archive.articles {
            guard article.readOffset >= 0, article.readOffset <= article.text.unicodeScalars.count,
                  article.folderID == nil || folderIDs.contains(article.folderID!),
                  let parsed = parsedMarkdown(for: article),
                  parsed.title == article.title else { throw ReadingLibraryError.invalidArchive }
        }
        for card in archive.cards {
            guard let article = articles[card.articleID], card.start >= 0, card.end > card.start,
                  !card.selectedText.isEmpty,
                  !associationKey(card.expression).isEmpty,
                  !card.meaning.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ReadingLibraryError.invalidArchive
            }
            if card.isDetached != true,
               try selectedText(start: card.start, end: card.end, from: article.text) != card.selectedText {
                throw ReadingLibraryError.invalidArchive
            }
        }
        for article in archive.articles {
            let sorted = archive.cards.filter { $0.articleID == article.id && $0.isDetached != true }.sorted { $0.start < $1.start }
            for pair in zip(sorted, sorted.dropFirst()) where pair.0.end > pair.1.start {
                throw ReadingLibraryError.invalidArchive
            }
        }
    }

    nonisolated static func readingBlocks(for article: LibraryArticle) -> [ArticleTextBlock] {
        parsedMarkdown(for: article)?.blocks ?? []
    }

    nonisolated static func metadata(for article: LibraryArticle) -> ArticleMetadata {
        parsedMarkdown(for: article)?.metadata ?? ArticleMetadata()
    }

    nonisolated static func readingInlineStyles(for article: LibraryArticle) -> [ArticleInlineStyle] {
        parsedMarkdown(for: article)?.inlineStyles ?? []
    }

    private typealias ParsedMarkdown = (title: String, text: String, blocks: [ArticleTextBlock], metadata: ArticleMetadata,
                                       inlineStyles: [ArticleInlineStyle])

    /// Both earlier pure-text formats remain valid while opening old snapshots.
    nonisolated private static func parsedMarkdown(for article: LibraryArticle) -> ParsedMarkdown? {
        if let parsed = try? parseMarkdown(article.markdown), parsed.text == article.text { return parsed }
        for recognizesFields in [true, false] {
            if let legacy = try? parseLegacyMarkdown(article.markdown, recognizeMetadata: recognizesFields),
               legacy.text == article.text { return legacy }
        }
        return nil
    }

    nonisolated private static func parseMarkdown(_ markdown: String) throws -> ParsedMarkdown {
        let parsed = try ArticleMarkdownDocument.parse(markdown)
        return (parsed.title, parsed.text, parsed.blocks, parsed.metadata, parsed.inlineStyles)
    }

    nonisolated private static func parseLegacyMarkdown(_ markdown: String, recognizeMetadata: Bool = true) throws -> ParsedMarkdown {
        let normalized = markdown.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        var lines = (normalized.hasPrefix("\u{FEFF}") ? String(normalized.dropFirst()) : normalized).components(separatedBy: "\n")
        while let first = lines.first, first.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeFirst() }
        guard let first = lines.first, let titleMatch = first.range(of: "^#{1,2} +(.+)$", options: .regularExpression) else {
            throw ReadingLibraryError.invalidMarkdown
        }
        let _ = titleMatch
        let titleSource = String(first.drop(while: { $0 == "#" || $0 == " " || $0 == "\t" }))
            .replacingOccurrences(of: "[ \\t]+#+[ \\t]*$", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        guard !titleSource.isEmpty else { throw ReadingLibraryError.invalidMarkdown }
        var plainBlocks = [stripInline(titleSource)]
        var blockKinds: [ArticleTextBlock.Kind] = [.title]
        func appendBlock(_ content: String, kind: ArticleTextBlock.Kind) {
            plainBlocks.append(content)
            blockKinds.append(kind)
        }
        var index = 1
        while index < lines.count && lines[index].trimmingCharacters(in: .whitespaces).isEmpty { index += 1 }
        var metadata = ArticleMetadata()
        if recognizeMetadata {
            // Fields are optional and only recognized before the first lead/body block.
            while index < lines.count {
                if lines[index].trimmingCharacters(in: .whitespaces).isEmpty { index += 1; continue }
                let pattern = #"(?i)^[ \t]*(author|authors|作者|date|日期|写作日期|发表日期|source|来源)[ \t]*[:：][ \t]*(.*?)[ \t]*$"#
                guard let regex = try? NSRegularExpression(pattern: pattern),
                      let match = regex.firstMatch(in: lines[index], range: NSRange(location: 0, length: (lines[index] as NSString).length)) else { break }
                let key = (lines[index] as NSString).substring(with: match.range(at: 1)).lowercased()
                let value = (lines[index] as NSString).substring(with: match.range(at: 2)).trimmingCharacters(in: .whitespaces)
                if !value.isEmpty {
                    if ["author", "authors", "作者"].contains(key) {
                        if metadata.author == nil { metadata.author = value }
                    } else if ["source", "来源"].contains(key) {
                        if metadata.source == nil {
                            let source = parseMetadataSource(value)
                            metadata.source = source.label
                            metadata.sourceURL = source.url
                        }
                    } else if metadata.date == nil { metadata.date = value }
                }
                index += 1
            }
        }
        if index < lines.count && lines[index].hasPrefix(">") {
            var quote: [String] = []
            while index < lines.count && lines[index].hasPrefix(">") {
                let line = String(lines[index].dropFirst())
                quote.append(line.hasPrefix(" ") ? String(line.dropFirst()) : line)
                index += 1
            }
            appendBlock(stripInline(quote.joined(separator: " ")), kind: .lead)
        }
        while index < lines.count {
            let line = lines[index]
            if line.trimmingCharacters(in: .whitespaces).isEmpty { index += 1; continue }
            if line.range(of: "^ *(`{3,}|~{3,}).*$", options: .regularExpression) != nil {
                let marker = line.trimmingCharacters(in: .whitespaces).first ?? "`"
                let length = line.trimmingCharacters(in: .whitespaces).prefix(while: { $0 == marker }).count
                var literal = [line]
                index += 1
                while index < lines.count {
                    let next = lines[index]
                    literal.append(next)
                    index += 1
                    let trimmed = next.trimmingCharacters(in: .whitespaces)
                    if trimmed.count >= length && trimmed.allSatisfy({ $0 == marker }) { break }
                }
                appendBlock(literal.joined(separator: "\n"), kind: .literal)
            } else if line.range(of: "^(#{2,6}) +(.+)$", options: .regularExpression) != nil {
                let heading = line.replacingOccurrences(of: "^#{2,6} +", with: "", options: .regularExpression)
                    .replacingOccurrences(of: "[ \\t]+#+[ \\t]*$", with: "", options: .regularExpression)
                appendBlock(stripInline(heading), kind: .heading(line.prefix(while: { $0 == "#" }).count))
                index += 1
            } else if let list = line.range(of: "^[ \\t]*([-+*]|[0-9]{1,9}[.)]) +", options: .regularExpression) {
                var value = String(line[list.upperBound...])
                index += 1
                while index < lines.count, !lines[index].trimmingCharacters(in: .whitespaces).isEmpty,
                      lines[index].range(of: "^[ \\t]*([-+*]|[0-9]{1,9}[.)]) +", options: .regularExpression) == nil,
                      lines[index].hasPrefix(" ") || lines[index].hasPrefix("\t") {
                    value += " " + lines[index].trimmingCharacters(in: .whitespaces)
                    index += 1
                }
                appendBlock(stripInline(value), kind: .list)
            } else if isLiteralLine(line) {
                var literal = [line]
                index += 1
                while index < lines.count && !lines[index].trimmingCharacters(in: .whitespaces).isEmpty {
                    literal.append(lines[index])
                    index += 1
                }
                appendBlock(literal.joined(separator: "\n"), kind: .literal)
            } else {
                var paragraph = [line]
                index += 1
                while index < lines.count && !lines[index].trimmingCharacters(in: .whitespaces).isEmpty &&
                    !startsBlock(lines[index]) {
                    paragraph.append(lines[index])
                    index += 1
                }
                appendBlock(stripInline(paragraph.joined(separator: " ")), kind: .paragraph)
            }
        }
        var offset = 0
        let blocks = zip(plainBlocks, blockKinds).map { content, kind in
            let range = NSRange(location: offset, length: (content as NSString).length)
            offset += range.length + 2
            return ArticleTextBlock(range: range, kind: kind)
        }
        return (stripInline(titleSource), plainBlocks.joined(separator: "\n\n"), blocks, metadata, [])
    }

    nonisolated private static func parseMetadataSource(_ value: String) -> (label: String, url: URL?) {
        guard let regex = try? NSRegularExpression(pattern: #"^\[([^\]]+)\]\((.+)\)$"#),
              let match = regex.firstMatch(in: value, range: NSRange(location: 0, length: (value as NSString).length)) else { return (value, nil) }
        let label = (value as NSString).substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespaces)
        let target = (value as NSString).substring(with: match.range(at: 2)).trimmingCharacters(in: .whitespaces)
        guard !label.isEmpty else { return (value, nil) }
        guard let url = URL(string: target), ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
              let host = url.host, !host.isEmpty else { return (label, nil) }
        return (label, url)
    }

    nonisolated private static func isLiteralLine(_ line: String) -> Bool {
        let value = line.trimmingCharacters(in: .whitespaces)
        return value.hasPrefix("|") || value.hasPrefix("<") || value.hasPrefix("$$") || value.hasPrefix(">") ||
            value == "---" || value == "***" || value == "___"
    }

    nonisolated private static func startsBlock(_ line: String) -> Bool {
        line.range(of: "^(#{2,6} +|[ \\t]*(?:[-+*]|[0-9]{1,9}[.)]) +| *`{3,}| *~{3,})", options: .regularExpression) != nil || isLiteralLine(line)
    }

    nonisolated private static func stripInline(_ source: String) -> String {
        var result = source
        result = result.replacingOccurrences(of: "!\\[([^\\]]*)\\]\\([^)]*\\)", with: "$1", options: .regularExpression)
        result = result.replacingOccurrences(of: "\\[([^\\]]+)\\]\\([^)]*\\)", with: "$1", options: .regularExpression)
        result = result.replacingOccurrences(of: "\\[([^\\]]+)\\]\\[[^]]*\\]", with: "$1", options: .regularExpression)
        result = result.replacingOccurrences(of: "`+([^`]+)`+", with: "$1", options: .regularExpression)
        result = result.replacingOccurrences(of: "(?<!\\w)(\\*{1,3}|_{1,3})(.+?)\\1(?!\\w)", with: "$2", options: .regularExpression)
        result = result.replacingOccurrences(of: "\\\\([\\\\`*{}\\[\\]()#+.!_>~-])", with: "$1", options: .regularExpression)
        return result
    }

    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
