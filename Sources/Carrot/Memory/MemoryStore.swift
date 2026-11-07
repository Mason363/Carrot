import Foundation
import SQLite3

/// Remembers what the user writes (locally, in a full-text index) so suggestions can reuse their
/// names, phrasing and facts. Never stores text from secure fields or excluded apps.
final class MemoryStore: @unchecked Sendable {
    static let shared = MemoryStore()

    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "app.carrot.memory", qos: .utility)
    private let maxEntries = 5000

    static var fileURL: URL {
        AppSupport.directory.appendingPathComponent("memory.sqlite")
    }

    private init() {
        queue.sync { open() }
    }

    private func open() {
        let url = Self.fileURL
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            db = nil
            return
        }
        // Owner-only permissions: this is the user's writing.
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        exec("PRAGMA journal_mode=WAL;")
        exec("PRAGMA secure_delete=ON;") // deleted text is overwritten, not just unlinked
        exec("""
            CREATE VIRTUAL TABLE IF NOT EXISTS entries USING fts5(
                text, app UNINDEXED, title UNINDEXED, created UNINDEXED, tokenize='unicode61 remove_diacritics 2'
            );
            """)
    }

    @discardableResult
    private func exec(_ sql: String) -> Bool {
        guard let db else { return false }
        return sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK
    }

    /// Stores a piece of the user's writing.
    func remember(_ text: String, app: String?, title: String?) {
        let cleaned = Self.sanitize(text)
        guard cleaned.count >= 40 else { return }
        queue.async { [self] in
            guard let db else { return }
            // Skip exact duplicates.
            var check: OpaquePointer?
            if sqlite3_prepare_v2(db, "SELECT 1 FROM entries WHERE text = ? LIMIT 1", -1, &check, nil) == SQLITE_OK {
                sqlite3_bind_text(check, 1, cleaned, -1, SQLITE_TRANSIENT)
                let exists = sqlite3_step(check) == SQLITE_ROW
                sqlite3_finalize(check)
                if exists { return }
            }
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, "INSERT INTO entries (text, app, title, created) VALUES (?, ?, ?, ?)", -1, &statement, nil) == SQLITE_OK else { return }
            sqlite3_bind_text(statement, 1, cleaned, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(statement, 2, app ?? "", -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(statement, 3, String((title ?? "").prefix(200)), -1, SQLITE_TRANSIENT)
            sqlite3_bind_double(statement, 4, Date().timeIntervalSince1970)
            sqlite3_step(statement)
            sqlite3_finalize(statement)
            exec("DELETE FROM entries WHERE rowid IN (SELECT rowid FROM entries ORDER BY created ASC LIMIT max(0, (SELECT count(*) FROM entries) - \(maxEntries)))")
        }
    }

    /// Finds earlier writing related to `query` (keywords from the field, window and screen).
    func recall(_ query: String, limit: Int = 3, completion: @escaping ([String]) -> Void) {
        let terms = Self.keywords(in: query).prefix(24)
        guard !terms.isEmpty else { completion([]); return }
        let match = terms.map { "\"\($0)\"" }.joined(separator: " OR ")
        queue.async { [self] in
            guard let db else { completion([]); return }
            var statement: OpaquePointer?
            var results: [String] = []
            let sql = "SELECT text FROM entries WHERE entries MATCH ? ORDER BY bm25(entries) LIMIT ?"
            if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
                sqlite3_bind_text(statement, 1, match, -1, SQLITE_TRANSIENT)
                sqlite3_bind_int(statement, 2, Int32(limit))
                while sqlite3_step(statement) == SQLITE_ROW {
                    if let c = sqlite3_column_text(statement, 0) { results.append(String(cString: c)) }
                }
            }
            sqlite3_finalize(statement)
            completion(results)
        }
    }

    var count: Int {
        queue.sync {
            guard let db else { return 0 }
            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }
            guard sqlite3_prepare_v2(db, "SELECT count(*) FROM entries", -1, &statement, nil) == SQLITE_OK,
                  sqlite3_step(statement) == SQLITE_ROW else { return 0 }
            return Int(sqlite3_column_int(statement, 0))
        }
    }

    func recent(limit: Int = 200) -> [(text: String, app: String, date: Date)] {
        queue.sync {
            guard let db else { return [] }
            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }
            var rows: [(String, String, Date)] = []
            guard sqlite3_prepare_v2(db, "SELECT text, app, created FROM entries ORDER BY created DESC LIMIT ?", -1, &statement, nil) == SQLITE_OK else { return [] }
            sqlite3_bind_int(statement, 1, Int32(limit))
            while sqlite3_step(statement) == SQLITE_ROW {
                let text = sqlite3_column_text(statement, 0).map { String(cString: $0) } ?? ""
                let app = sqlite3_column_text(statement, 1).map { String(cString: $0) } ?? ""
                rows.append((text, app, Date(timeIntervalSince1970: sqlite3_column_double(statement, 2))))
            }
            return rows
        }
    }

    /// Waits for pending writes (before the app exits).
    func flush() {
        queue.sync {}
    }

    /// Forgets everything, leaving no trace on disk: full-text deletes only add tombstones until the
    /// index is merged, and the write-ahead log keeps old pages until it is checkpointed.
    func clear() {
        queue.sync {
            _ = exec("DELETE FROM entries")
            _ = exec("INSERT INTO entries(entries) VALUES('optimize')")
            _ = exec("VACUUM")
            _ = exec("PRAGMA wal_checkpoint(TRUNCATE)")
        }
    }

    // MARK: Text helpers

    private static let stopWords: Set<String> = [
        "the", "and", "for", "that", "this", "with", "you", "your", "are", "was", "but", "not", "have", "has", "had",
        "from", "they", "will", "would", "can", "could", "about", "there", "their", "what", "when", "which", "just",
        "been", "were", "into", "than", "then", "them", "also", "some", "more", "very", "here", "our", "out", "all",
    ]

    static func keywords(in text: String) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for raw in text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }) {
            let word = String(raw)
            guard word.count >= 3, !stopWords.contains(word), !word.allSatisfy(\.isNumber), seen.insert(word).inserted else { continue }
            result.append(word)
        }
        return result
    }

    /// Removes things that look like secrets or identifiers before storing.
    static func sanitize(_ text: String) -> String {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let patterns = [
            "\\b(?:\\d[ -]?){13,19}\\b",                       // card-like numbers
            "\\b\\d{3}-\\d{2}-\\d{4}\\b",                      // SSN
            "\\b[A-Za-z0-9_\\-]{32,}\\b",                      // tokens / keys / hashes
            "(?i)\\b(?:password|passcode|pwd)\\s*[:=]\\s*\\S+",
        ]
        for pattern in patterns {
            t = t.replacingOccurrences(of: pattern, with: "…", options: .regularExpression)
        }
        if t.count > 1200 { t = String(t.suffix(1200)) }
        return t
    }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
