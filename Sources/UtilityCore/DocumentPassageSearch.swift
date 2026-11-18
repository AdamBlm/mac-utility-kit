import Foundation
import NaturalLanguage
import SQLite3

/// The connection is opened in SQLite serialized mode. Its contents are
/// immutable after initialization, and each search owns its statements.
final class DocumentPassageSearch: @unchecked Sendable {
    private let database: OpaquePointer

    init(_ passages: [AskDocument.Passage]) throws {
        var handle: OpaquePointer?
        let status = sqlite3_open_v2(":memory:", &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil)
        guard status == SQLITE_OK, let handle else {
            sqlite3_close(handle)
            throw ToolError.invalid("Could not open the local document index.")
        }
        do {
            guard sqlite3_exec(handle, """
                PRAGMA temp_store=MEMORY;

                CREATE VIRTUAL TABLE passages USING fts5(words, tokenize='unicode61 remove_diacritics 2');
                BEGIN;
                """, nil, nil, nil) == SQLITE_OK else { throw Self.error(handle) }
            try Self.withStatement(handle, "INSERT INTO passages(rowid, words) VALUES (?1, ?2)") { statement in
                for passage in passages {
                    try Task.checkCancellation()
                    let words = Self.words(passage.text).joined(separator: " ")
                    guard sqlite3_bind_int64(statement, 1, Int64(passage.id)) == SQLITE_OK,
                          Self.bind(words, to: statement, index: 2) == SQLITE_OK,
                          sqlite3_step(statement) == SQLITE_DONE,
                          sqlite3_reset(statement) == SQLITE_OK else { throw Self.error(handle) }
                }
            }
            guard sqlite3_exec(handle, "COMMIT", nil, nil, nil) == SQLITE_OK else { throw Self.error(handle) }
        } catch {
            sqlite3_close(handle)
            throw error
        }
        database = handle
    }

    deinit { sqlite3_close(database) }

    func retrieve(_ terms: [String], limit: Int) throws -> [Int] {
        guard !terms.isEmpty else { return [] }
        let query = terms.map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }.joined(separator: " OR ")
        return try Self.withStatement(database, """
            SELECT rowid FROM passages WHERE passages MATCH ?1 ORDER BY rank LIMIT ?2
            """) { statement in
            guard Self.bind(query, to: statement, index: 1) == SQLITE_OK,
                  sqlite3_bind_int(statement, 2, Int32(limit)) == SQLITE_OK else { throw Self.error(database) }
            var matches: [Int] = []
            while true {
                try Task.checkCancellation()
                switch sqlite3_step(statement) {
                case SQLITE_ROW: matches.append(Int(sqlite3_column_int64(statement, 0)))
                case SQLITE_DONE: return matches
                default: throw Self.error(database)
                }
            }
        }
    }

    static func words(_ text: String) -> [String] {
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = text
        var words: [String] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let token = String(text[range])
            if token.unicodeScalars.contains(where: { CharacterSet.alphanumerics.contains($0) }) {
                words.append(token)
            }
            return true
        }
        return words
    }

    private static func bind(_ value: String, to statement: OpaquePointer, index: Int32) -> Int32 {
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        return value.withCString { sqlite3_bind_text(statement, index, $0, -1, transient) }
    }

    private static func withStatement<T>(
        _ database: OpaquePointer, _ sql: String, _ body: (OpaquePointer) throws -> T
    ) throws -> T {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            sqlite3_finalize(statement)
            throw error(database)
        }
        defer { sqlite3_finalize(statement) }
        return try body(statement)
    }

    private static func error(_ database: OpaquePointer) -> ToolError {
        let detail = sqlite3_errmsg(database).map { String(cString: $0) } ?? "unknown error"
        return .invalid("Could not search the local document index. " + detail)
    }
}
