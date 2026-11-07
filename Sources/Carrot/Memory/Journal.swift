import CryptoKit
import Foundation
import SQLite3

private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// An opt-in record of what Carrot saw, decided and suggested, and what the user did with it, so
/// suggestions can be reviewed and tuned against how this person actually writes. Stays on this
/// Mac (Application Support, owner-only), is kept for 30 days, and is never sent anywhere.
///
/// Recorded: each field the user writes in (app, window, site, field), the context the engine was
/// given (stored once per version), every decision (text around the caret, the suggestion or none,
/// its confidence and speed, how it was shown), what happened to it (taken whole or by word,
/// dismissed, typed past), typo fixes, and the text the field ended up with.
final class Journal: @unchecked Sendable {
    static let shared = Journal()

    static var fileURL: URL {
        TestBench.journalsToTemporaryFile
            ? URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("carrot-test-journal.sqlite")
            : AppSupport.directory.appendingPathComponent("journal.sqlite")
    }
    static let retention: TimeInterval = 30 * 24 * 3600
    static let maxBytes: Int64 = 400 * 1024 * 1024

    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "app.carrot.journal", qos: .utility)
    private var contextIDs: [String: Int64] = [:]
    private var writesSincePrune = 0

    private init() {}

    // MARK: Recording

    /// A new field: returns the session that later records refer to.
    func beginSession(app: String?, bundleID: String?, title: String?, site: String?, field: [String: Any]) -> Int64 {
        let session = Int64(Date().timeIntervalSince1970 * 1000)
        var detail = field
        detail["bundle"] = bundleID ?? ""
        detail["site"] = site ?? ""
        insert(kind: "focus", session: session, app: app, title: title, context: nil, prefix: nil, suffix: nil,
               suggestion: nil, detail: detail)
        return session
    }

    /// One event of a session. `context` is the prompt header the engine was given.
    func record(_ kind: String, session: Int64, app: String? = nil, context: String? = nil, prefix: String? = nil,
                suffix: String? = nil, suggestion: String? = nil, detail: [String: Any] = [:]) {
        insert(kind: kind, session: session, app: app, title: nil, context: context, prefix: prefix, suffix: suffix,
               suggestion: suggestion, detail: detail)
    }

    private func insert(kind: String, session: Int64, app: String?, title: String?, context: String?, prefix: String?,
                        suffix: String?, suggestion: String?, detail: [String: Any]) {
        let time = Date().timeIntervalSince1970
        queue.async { [self] in
            guard openIfNeeded(), let db else { return }
            let contextID = context.flatMap { storeContext($0) }
            var statement: OpaquePointer?
            let sql = """
                INSERT INTO events (time, session, kind, app, title, context, prefix, suffix, suggestion, detail)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_double(statement, 1, time)
            sqlite3_bind_int64(statement, 2, session)
            bind(statement, 3, kind)
            bind(statement, 4, app)
            bind(statement, 5, title)
            if let contextID { sqlite3_bind_int64(statement, 6, contextID) } else { sqlite3_bind_null(statement, 6) }
            bind(statement, 7, prefix)
            bind(statement, 8, suffix)
            bind(statement, 9, suggestion)
            let json = (try? JSONSerialization.data(withJSONObject: detail, options: [.sortedKeys]))
                .flatMap { String(data: $0, encoding: .utf8) }
            bind(statement, 10, json)
            sqlite3_step(statement)
            writesSincePrune += 1
            if writesSincePrune >= 1000 { prune() }
        }
    }

    /// Headers repeat for every keystroke in a field: each distinct one is stored once.
    private func storeContext(_ text: String) -> Int64? {
        guard let db, !text.isEmpty else { return nil }
        let hash = SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
        if let id = contextIDs[hash] { return id }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, "INSERT OR IGNORE INTO contexts (hash, text) VALUES (?, ?)", -1, &statement, nil) == SQLITE_OK else {
            return nil
        }
        bind(statement, 1, hash)
        bind(statement, 2, text)
        sqlite3_step(statement)
        var lookup: OpaquePointer?
        defer { sqlite3_finalize(lookup) }
        guard sqlite3_prepare_v2(db, "SELECT id FROM contexts WHERE hash = ?", -1, &lookup, nil) == SQLITE_OK else { return nil }
        bind(lookup, 1, hash)
        guard sqlite3_step(lookup) == SQLITE_ROW else { return nil }
        let id = sqlite3_column_int64(lookup, 0)
        if contextIDs.count > 2000 { contextIDs.removeAll() }
        contextIDs[hash] = id
        return id
    }

    private func bind(_ statement: OpaquePointer?, _ index: Int32, _ text: String?) {
        if let text { sqlite3_bind_text(statement, index, text, -1, transient) } else { sqlite3_bind_null(statement, index) }
    }

    // MARK: Storage

    private func openIfNeeded() -> Bool {
        if db != nil { return true }
        let url = Self.fileURL
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            db = nil
            return false
        }
        // Owner-only: this is everything the user typed.
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        exec("PRAGMA journal_mode=WAL;")
        exec("PRAGMA secure_delete=ON;")
        exec("""
            CREATE TABLE IF NOT EXISTS contexts (id INTEGER PRIMARY KEY, hash TEXT UNIQUE NOT NULL, text TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS events (
                id INTEGER PRIMARY KEY, time REAL NOT NULL, session INTEGER NOT NULL, kind TEXT NOT NULL,
                app TEXT, title TEXT, context INTEGER REFERENCES contexts(id),
                prefix TEXT, suffix TEXT, suggestion TEXT, detail TEXT
            );
            CREATE INDEX IF NOT EXISTS events_time ON events(time);
            CREATE INDEX IF NOT EXISTS events_session ON events(session);
            """)
        prune()
        return true
    }

    @discardableResult
    private func exec(_ sql: String) -> Bool {
        guard let db else { return false }
        return sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK
    }

    /// Drops what's older than the retention period, and the oldest tenth while over the size cap.
    private func prune() {
        writesSincePrune = 0
        let cutoff = Date().timeIntervalSince1970 - Self.retention
        exec("DELETE FROM events WHERE time < \(cutoff)")
        for _ in 0..<5 where bytes() > Self.maxBytes {
            exec("DELETE FROM events WHERE id IN (SELECT id FROM events ORDER BY time ASC LIMIT (SELECT count(*) / 10 + 1 FROM events))")
        }
        exec("DELETE FROM contexts WHERE id NOT IN (SELECT DISTINCT context FROM events WHERE context IS NOT NULL)")
        contextIDs.removeAll()
    }

    private func bytes() -> Int64 {
        guard let db else { return 0 }
        func pragma(_ name: String) -> Int64 {
            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }
            guard sqlite3_prepare_v2(db, "PRAGMA \(name)", -1, &statement, nil) == SQLITE_OK,
                  sqlite3_step(statement) == SQLITE_ROW else { return 0 }
            return sqlite3_column_int64(statement, 0)
        }
        return pragma("page_count") * pragma("page_size")
    }

    // MARK: Settings

    /// Size on disk (0 when there's no journal).
    var fileSize: Int64 {
        let paths = [Self.fileURL.path, Self.fileURL.path + "-wal"]
        return paths.reduce(0) { total, path in
            total + ((try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int64) ?? 0)
        }
    }

    /// Waits for pending writes (before the app exits).
    func flush() {
        queue.sync {}
    }

    /// Deletes the journal file entirely.
    func clear() {
        queue.sync {
            if let db { sqlite3_close(db) }
            db = nil
            contextIDs.removeAll()
            for suffix in ["", "-wal", "-shm"] {
                try? FileManager.default.removeItem(atPath: Self.fileURL.path + suffix)
            }
        }
    }
}
