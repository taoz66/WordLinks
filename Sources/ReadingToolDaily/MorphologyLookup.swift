import CSQLite
import Foundation

/// Reuses the native reader's public lexicon and conservative, direct-lemma rules.
/// Ambiguous words stay as selected; suffixes are never removed by guessing.
final class MorphologyLookup {
    private var database: OpaquePointer?

    init(url: URL? = MorphologyLookup.bundledLexiconURL) {
        guard let url else { return }
        if sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) != SQLITE_OK {
            sqlite3_close(database)
            database = nil
        }
    }

    deinit { sqlite3_close(database) }

    func initialExpression(for selected: String) -> String {
        guard Self.isLowercaseWord(selected), let database else { return selected }
        var statement: OpaquePointer?
        let query = "SELECT lemma, blockers, source_mask, kind_mask FROM candidates WHERE form = ?"
        guard sqlite3_prepare_v2(database, query, -1, &statement, nil) == SQLITE_OK else { return selected }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        guard sqlite3_bind_text(statement, 1, selected, -1, transient) == SQLITE_OK else { return selected }

        guard sqlite3_step(statement) == SQLITE_ROW,
              let lemma = sqlite3_column_text(statement, 0) else { return selected }
        let expression = String(cString: lemma)
        let blockers = sqlite3_column_int(statement, 1)
        let sources = sqlite3_column_int(statement, 2)
        let kinds = sqlite3_column_int(statement, 3)
        // Require one unblocked relation supported by SPECIALIST (source bit 1)
        // and explicitly identified as an inflection (kind bit 2).
        guard sqlite3_step(statement) == SQLITE_DONE,
              blockers == 0, sources & 1 != 0, kinds & 2 != 0,
              Self.isLowercaseWord(expression) else { return selected }
        return expression
    }

    private static func isLowercaseWord(_ text: String) -> Bool {
        !text.isEmpty && text.utf8.allSatisfy { (97...122).contains($0) }
    }

    private static var bundledLexiconURL: URL? {
        // The distributed app stores SwiftPM resources in Contents/Resources.
        let installedBundle = Bundle.main.resourceURL.flatMap {
            Bundle(url: $0.appendingPathComponent("ReadingToolDaily_ReadingToolDaily.bundle"))
        }
        let resources = installedBundle ?? Bundle.module
        return resources.url(forResource: "lexicon", withExtension: "sqlite3", subdirectory: "Language")
    }
}
