import CryptoKit
import Foundation

/// Immutable resources are copied into each profile; profile articles remain independent afterwards.
struct BundledArticleCollection: Sendable {
    let id: String
    let folderName: String
    let articles: [BundledArticle]

    static func resourceBundle() -> Bundle {
        let installedBundle = Bundle.main.resourceURL
            .flatMap { Bundle(url: $0.appendingPathComponent("ReadingToolDaily_ReadingToolDaily.bundle")) }
        return installedBundle ?? Bundle.module
    }

    static func bundledIntensiveReadingCacheURL(bundle: Bundle = resourceBundle()) -> URL? {
        bundle.url(forResource: "intensive-reading", withExtension: "json", subdirectory: "Resources/Licensed")
            ?? bundle.url(forResource: "intensive-reading", withExtension: "json", subdirectory: "Licensed")
            ?? bundle.url(forResource: "intensive-reading", withExtension: "json")
    }

    static func load(rootURL: URL? = nil, fileManager: FileManager = .default) throws -> [BundledArticleCollection] {
        let resources = resourceBundle()
        let catalogs = [
            (directory: "Licensed/GlobalVoices", name: "Global Voices"),
            (directory: "Licensed/Wikipedia", name: "Wikipedia"),
            (directory: "Licensed/PLOS", name: "PLOS")
        ]
        var loaded = try loadLocalCollections(rootURL: rootURL, fileManager: fileManager)
        loaded.append(contentsOf: try catalogs.map { catalog in
            guard let catalogURL = resources.url(forResource: "catalog", withExtension: "json",
                                                subdirectory: "Resources/\(catalog.directory)")
                    ?? resources.url(forResource: "catalog", withExtension: "json", subdirectory: catalog.directory) else {
                throw ReadingLibraryError.fileAccess(L("找不到应用内置的 \(catalog.name) 阅读材料。", "The bundled \(catalog.name) reading materials could not be found."))
            }
            return try load(catalogURL: catalogURL)
        })
        return loaded
    }

    private static func loadLocalCollections(rootURL: URL?, fileManager: FileManager) throws -> [BundledArticleCollection] {
        guard let localRoot = rootURL?.appendingPathComponent("LocalCollections", isDirectory: true),
              fileManager.fileExists(atPath: localRoot.path) else { return [] }
        let directories = try fileManager.contentsOfDirectory(
            at: localRoot, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        ).sorted { $0.lastPathComponent < $1.lastPathComponent }
        return try directories.compactMap { directory in
            let catalogURL = directory.appendingPathComponent("catalog.json")
            guard fileManager.fileExists(atPath: catalogURL.path) else { return nil }
            return try load(catalogURL: catalogURL)
        }
    }

    static func load(catalogURL: URL) throws -> BundledArticleCollection {
        struct Catalog: Decodable {
            struct Article: Decodable {
                let id: UUID
                let file: String
                let title: String
                let sourceURL: String
                let previousMarkdownSHA256: [String]?
            }
            let id: String
            let folderName: String?
            let collectionURL: String
            let articles: [Article]
        }

        do {
            let catalog = try JSONDecoder().decode(Catalog.self, from: Data(contentsOf: catalogURL))
            let folderName = (catalog.folderName ?? "IELTS").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !catalog.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !folderName.isEmpty,
                  isWebURL(catalog.collectionURL), !catalog.articles.isEmpty,
                  Set(catalog.articles.map(\.id)).count == catalog.articles.count,
                  Set(catalog.articles.map(\.file)).count == catalog.articles.count,
                  Set(catalog.articles.map(\.sourceURL)).count == catalog.articles.count else {
                throw ReadingLibraryError.invalidArchive
            }
            let directory = catalogURL.deletingLastPathComponent()
            let articles = try catalog.articles.map { item in
                guard !item.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      isWebURL(item.sourceURL), item.file == (item.file as NSString).lastPathComponent,
                      (item.file as NSString).pathExtension.lowercased() == "md",
                      (item.previousMarkdownSHA256 ?? []).allSatisfy({
                          $0.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil
                      }) else {
                    throw ReadingLibraryError.invalidArchive
                }
                let markdown = try String(contentsOf: directory.appendingPathComponent(item.file), encoding: .utf8)
                return BundledArticle(id: item.id, file: item.file, title: item.title,
                                      sourceURL: item.sourceURL, markdown: markdown,
                                      previousMarkdownSHA256: item.previousMarkdownSHA256 ?? [])
            }
            return BundledArticleCollection(id: catalog.id, folderName: folderName, articles: articles)
        } catch {
            throw ReadingLibraryError.fileAccess(L("无法读取内置阅读材料：\(error.localizedDescription)", "Could not read the bundled reading materials: \(error.localizedDescription)"))
        }
    }

    private static func isWebURL(_ value: String) -> Bool {
        guard let url = URL(string: value), let scheme = url.scheme?.lowercased(),
              ["https", "http"].contains(scheme), url.host != nil else { return false }
        return true
    }
}

struct BundledArticle: Sendable {
    let id: UUID
    let file: String
    let title: String
    let sourceURL: String
    let markdown: String
    /// Only exact, previously distributed copies may receive a bundled revision.
    let previousMarkdownSHA256: [String]

    init(id: UUID, file: String, title: String, sourceURL: String, markdown: String,
         previousMarkdownSHA256: [String] = []) {
        self.id = id
        self.file = file
        self.title = title
        self.sourceURL = sourceURL
        self.markdown = markdown
        self.previousMarkdownSHA256 = previousMarkdownSHA256
    }

    static func markdownSHA256(_ markdown: String) -> String {
        SHA256.hash(data: Data(markdown.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
