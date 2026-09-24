import Foundation
import SQLite3

/// The compact, path-free archive is shared with the app and CloudKit. The request ledger
/// stays on the collecting Mac and is never copied into defaults or cloud status records.
nonisolated enum ModelUsageArchiveStore {
    static var directory: URL {
        let manager = FileManager.default
        let root = manager.containerURL(forSecurityApplicationGroupIdentifier: "group.com.chrisizatt.LLMUsageCounter")
            ?? manager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("LimitCounter")
        return root.appendingPathComponent("ModelUsage", isDirectory: true)
    }

    /// Schema 2 lives beside the schema 1 file, which an older build can still read.
    static func load(from directory: URL = directory) -> ModelUsageArchive {
        for name in ["rollups-v2.json", "rollups-v1.json"] {
            if let data = try? Data(contentsOf: directory.appendingPathComponent(name)),
               let archive = try? ModelUsageArchive.decode(data) { return archive }
        }
        return .empty
    }

    static func save(_ archive: ModelUsageArchive, to directory: URL = directory) throws {
        _ = try archive.validated()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(archive).write(to: directory.appendingPathComponent("rollups-v2.json"), options: .atomic)
    }
}

/// Used serially by ModelUsageLogScanner. One row per file/call permits a changed or
/// truncated file to replace its own contribution atomically. Global ranking collapses
/// copied transcripts while retaining the most complete response, not the first chunk.
nonisolated final class ModelUsageLedger {
    private var database: OpaquePointer?
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            throw ModelUsageError.database("Cannot open ledger")
        }
        sqlite3_busy_timeout(database, 5000)
        try execute("PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL;")
        try execute("""
            CREATE TABLE IF NOT EXISTS files (
                source TEXT NOT NULL, file TEXT NOT NULL, modified REAL NOT NULL,
                bytes INTEGER NOT NULL, version INTEGER NOT NULL, malformed INTEGER NOT NULL DEFAULT 0,
                PRIMARY KEY(source,file));
            CREATE TABLE IF NOT EXISTS calls (
                source TEXT NOT NULL, file TEXT NOT NULL, call TEXT NOT NULL, at REAL NOT NULL,
                output REAL NOT NULL, total REAL NOT NULL, payload BLOB NOT NULL,
                PRIMARY KEY(source,file,call));
            CREATE INDEX IF NOT EXISTS calls_identity ON calls(source,call);
            CREATE INDEX IF NOT EXISTS calls_date ON calls(at);
            """)
    }

    deinit { sqlite3_close(database) }

    func isCurrent(source: String, file: String, modified: Date, bytes: Int, version: Int) throws -> Bool {
        let statement = try prepare("SELECT modified,bytes,version FROM files WHERE source=? AND file=?")
        defer { sqlite3_finalize(statement) }
        bind(source, 1, statement); bind(file, 2, statement)
        guard sqlite3_step(statement) == SQLITE_ROW else { return false }
        return sqlite3_column_double(statement, 0) == modified.timeIntervalSince1970
            && sqlite3_column_int64(statement, 1) == bytes && sqlite3_column_int(statement, 2) == version
    }

    func replaceFile(source: String, file: String, modified: Date, bytes: Int, version: Int,
                     read: (_ emit: (ModelUsageCall) throws -> Void) throws -> Int) throws {
        try execute("BEGIN IMMEDIATE")
        do {
            let delete = try prepare("DELETE FROM calls WHERE source=? AND file=?")
            bind(source, 1, delete); bind(file, 2, delete)
            defer { sqlite3_finalize(delete) }
            try step(delete)
            let insert = try prepare("""
                INSERT INTO calls VALUES(?,?,?,?,?,?,?)
                ON CONFLICT(source,file,call) DO UPDATE SET
                    at=MIN(calls.at,excluded.at), output=excluded.output, total=excluded.total, payload=excluded.payload
                WHERE excluded.output > calls.output OR (excluded.output = calls.output AND excluded.total >= calls.total)
                """)
            defer { sqlite3_finalize(insert) }
            let malformed = try read { call in
                guard call.tokens.isValid, call.tokens.total > 0 else { return }
                sqlite3_reset(insert); sqlite3_clear_bindings(insert)
                bind(source, 1, insert); bind(file, 2, insert); bind(call.id, 3, insert)
                sqlite3_bind_double(insert, 4, call.timestamp.timeIntervalSince1970)
                sqlite3_bind_double(insert, 5, call.tokens.output)
                sqlite3_bind_double(insert, 6, call.tokens.total)
                let payload = try encoder.encode(call)
                _ = payload.withUnsafeBytes { sqlite3_bind_blob(insert, 7, $0.baseAddress, Int32($0.count), transient) }
                try step(insert)
            }
            let metadata = try prepare("INSERT OR REPLACE INTO files VALUES(?,?,?,?,?,?)")
            defer { sqlite3_finalize(metadata) }
            bind(source, 1, metadata); bind(file, 2, metadata)
            sqlite3_bind_double(metadata, 3, modified.timeIntervalSince1970)
            sqlite3_bind_int64(metadata, 4, Int64(bytes)); sqlite3_bind_int(metadata, 5, Int32(version))
            sqlite3_bind_int(metadata, 6, Int32(malformed)); try step(metadata)
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    func rollups(now: Date) throws -> [ModelUsageRollup] {
        let statement = try prepare("""
            SELECT payload,first_at FROM (
                SELECT payload,MIN(at) OVER(PARTITION BY source,call) AS first_at,
                       ROW_NUMBER() OVER(PARTITION BY source,call ORDER BY output DESC,total DESC,at DESC,file) AS rank
                FROM calls WHERE at >= ? AND at <= ?
            ) WHERE rank=1
            """)
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, now.addingTimeInterval(-366 * 86400).timeIntervalSince1970)
        sqlite3_bind_double(statement, 2, now.timeIntervalSince1970)
        var result: [String: ModelUsageRollup] = [:]
        var status = sqlite3_step(statement)
        while status == SQLITE_ROW {
            if let bytes = sqlite3_column_blob(statement, 0) {
                let data = Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 0)))
                var call = try decoder.decode(ModelUsageCall.self, from: data)
                call.timestamp = Date(timeIntervalSince1970: sqlite3_column_double(statement, 1))
                ModelUsageAggregation.add(call, now: now, into: &result)
            }
            status = sqlite3_step(statement)
        }
        guard status == SQLITE_DONE else { throw error() }
        return result.values.sorted { $0.id < $1.id }
    }

    func malformedLines(source: String) throws -> Int {
        let statement = try prepare("SELECT COALESCE(SUM(malformed),0) FROM files WHERE source=?")
        defer { sqlite3_finalize(statement) }
        bind(source, 1, statement)
        guard sqlite3_step(statement) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int64(statement, 0))
    }

    func prune(now: Date) throws {
        let statement = try prepare("DELETE FROM calls WHERE at < ?")
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, now.addingTimeInterval(-367 * 86400).timeIntervalSince1970)
        try step(statement)
    }

    private func error() -> ModelUsageError { .database(String(cString: sqlite3_errmsg(database))) }
    private func execute(_ sql: String) throws {
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else { throw error() }
    }
    private func prepare(_ sql: String) throws -> OpaquePointer? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { throw error() }
        return statement
    }
    private func bind(_ value: String, _ index: Int32, _ statement: OpaquePointer?) {
        sqlite3_bind_text(statement, index, value, -1, transient)
    }
    private func step(_ statement: OpaquePointer?) throws {
        guard sqlite3_step(statement) == SQLITE_DONE else { throw error() }
    }
}
