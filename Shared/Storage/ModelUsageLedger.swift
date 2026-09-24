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
    /// Sorted keys make a payload canonical, so a re-read file can tell its unchanged
    /// calls from changed ones.
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()
    private let decoder = JSONDecoder()
    private static let changedKey = "changedFrom", watermarksKey = "rollupWatermarks"

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
            CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
            CREATE TEMP TABLE IF NOT EXISTS previous (
                call TEXT PRIMARY KEY, at REAL NOT NULL, output REAL NOT NULL, total REAL NOT NULL, payload BLOB NOT NULL);
            """)
    }

    /// Advances whenever a file's calls are replaced; rollups built from an older
    /// generation are stale.
    func generation() throws -> Int { Int(try metaValue("generation") ?? "") ?? 0 }

    func metaValue(_ key: String) throws -> String? {
        let statement = try prepare("SELECT value FROM meta WHERE key=?")
        defer { sqlite3_finalize(statement) }
        bind(key, 1, statement)
        guard sqlite3_step(statement) == SQLITE_ROW, let text = sqlite3_column_text(statement, 0) else { return nil }
        return String(cString: text)
    }

    func setMetaValue(_ value: String, for key: String) throws {
        let statement = try prepare("INSERT INTO meta VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value")
        defer { sqlite3_finalize(statement) }
        bind(key, 1, statement); bind(value, 2, statement)
        try step(statement)
    }

    /// The first instant at which the passage of time alone can change `rollups(now:)`:
    /// the next UTC midnight, when resolution and retention boundaries advance, or the
    /// moment a call logged with a future timestamp becomes current.
    func nextRollupChange(after now: Date) throws -> Date {
        let midnight = ModelUsageAggregation.dayStart(now).addingTimeInterval(86400)
        let statement = try prepare("SELECT MIN(at) FROM calls WHERE at > ?")
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, now.timeIntervalSince1970)
        guard sqlite3_step(statement) == SQLITE_ROW, sqlite3_column_type(statement, 0) != SQLITE_NULL else { return midnight }
        return min(midnight, Date(timeIntervalSince1970: sqlite3_column_double(statement, 0)))
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
            // The file's calls as they were, to find the ones this read changes.
            try execute("DELETE FROM temp.previous")
            let keep = try prepare("INSERT INTO temp.previous SELECT call,at,output,total,payload FROM calls WHERE source=? AND file=?")
            bind(source, 1, keep); bind(file, 2, keep)
            defer { sqlite3_finalize(keep) }
            try step(keep)
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
            try markChanged(source: source, file: file)
            try execute("""
                INSERT INTO meta VALUES('generation','1')
                ON CONFLICT(key) DO UPDATE SET value=CAST(CAST(value AS INTEGER)+1 AS TEXT)
                """)
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    /// Notes the earliest instant a replaced file's changed calls reach, counting every copy
    /// of each changed call in any file, before and after, since those copies decide its
    /// winner and first time. The mark accumulates until a rollup absorbs it.
    private func markChanged(source: String, file: String) throws {
        let statement = try prepare("""
            WITH changed(call) AS (
                SELECT call FROM temp.previous p WHERE NOT EXISTS (
                    SELECT 1 FROM calls c WHERE c.source=?1 AND c.file=?2 AND c.call=p.call
                        AND c.at=p.at AND c.output=p.output AND c.total=p.total AND c.payload=p.payload)
                UNION
                SELECT call FROM calls c WHERE c.source=?1 AND c.file=?2 AND NOT EXISTS (
                    SELECT 1 FROM temp.previous p WHERE p.call=c.call
                        AND p.at=c.at AND p.output=c.output AND p.total=c.total AND p.payload=c.payload))
            SELECT MIN(at) FROM (
                SELECT at FROM calls WHERE source=?1 AND call IN (SELECT call FROM changed)
                UNION ALL SELECT at FROM temp.previous WHERE call IN (SELECT call FROM changed))
            """)
        defer { sqlite3_finalize(statement) }
        bind(source, 1, statement); bind(file, 2, statement)
        guard sqlite3_step(statement) == SQLITE_ROW, sqlite3_column_type(statement, 0) != SQLITE_NULL else { return }
        // Whole seconds a second early: the text is exact and never later than the call.
        let earliest = Int64(floor(sqlite3_column_double(statement, 0))) - 1
        if let known = try metaValue(Self.changedKey).flatMap(Int64.init), known <= earliest { return }
        try setMetaValue(String(earliest), for: Self.changedKey)
    }

    /// The earliest instant any call changed since the last committed rollup, if one did.
    func changedFrom() throws -> Date? {
        try metaValue(Self.changedKey).flatMap(Int64.init).map { Date(timeIntervalSince1970: Double($0)) }
    }

    /// The watermarks the last committed rollup ended with.
    func watermarks() throws -> [String: Date]? {
        guard let text = try metaValue(Self.watermarksKey),
              let values = try? decoder.decode([String: Double].self, from: Data(text.utf8)) else { return nil }
        return values.mapValues { Date(timeIntervalSince1970: $0) }
    }

    /// Saves a finished rollup's state and watermarks and clears the changes it absorbed,
    /// in one transaction, so a later rollup never continues from a mismatched pair.
    func commitRollup(state: String, for key: String, watermarks: [String: Date]) throws {
        let marks = String(decoding: try encoder.encode(watermarks.mapValues(\.timeIntervalSince1970)), as: UTF8.self)
        try execute("BEGIN IMMEDIATE")
        do {
            try setMetaValue(state, for: key)
            try setMetaValue(marks, for: Self.watermarksKey)
            let clear = try prepare("DELETE FROM meta WHERE key=?")
            defer { sqlite3_finalize(clear) }
            bind(Self.changedKey, 1, clear); try step(clear)
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    func rollups(now: Date) throws -> [ModelUsageRollup] { try rollupPass(now: now).buckets }

    /// Buckets of the winning copy of every call first seen from `from` on (every call when
    /// nil), and the earliest transcript call per coverage key. A pass from a day continues
    /// an earlier one: `earlier` holds that pass's watermarks, of which those before `from`
    /// still stand, and only calls with a copy on or after `from` are read.
    func rollupPass(now: Date, from: Date? = nil, earlier: [String: Date] = [:]) throws
        -> (buckets: [ModelUsageRollup], watermarks: [String: Date]) {
        // Every copy of each call seen from `from` on, looked up by identity.
        let calls = from == nil ? "calls WHERE at >= ?1 AND at <= ?2" : """
            (SELECT DISTINCT source AS s,call AS k FROM calls WHERE at >= ?3 AND at <= ?2)
                JOIN calls ON source=s AND call=k WHERE at >= ?1 AND at <= ?2
            """
        let statement = try prepare("""
            SELECT payload,first_at FROM (
                SELECT payload,MIN(at) OVER(PARTITION BY source,call) AS first_at,
                       ROW_NUMBER() OVER(PARTITION BY source,call ORDER BY output DESC,total DESC,at DESC,file) AS rank
                FROM \(calls)
            ) WHERE rank=1\(from == nil ? "" : " AND first_at >= ?3")
            """)
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, ModelUsageAggregation.retentionStart(now).timeIntervalSince1970)
        sqlite3_bind_double(statement, 2, now.timeIntervalSince1970)
        if let from { sqlite3_bind_double(statement, 3, from.timeIntervalSince1970) }
        var result: [String: ModelUsageRollup] = [:]
        var rates: [String: ModelRate?] = [:]
        // Run records wait until every transcript call has lowered its coverage watermark.
        var watermarks = from.map { from in earlier.filter { $0.value < from } } ?? [:]
        var runs: [(key: String, call: ModelUsageCall)] = []
        var status = sqlite3_step(statement)
        while status == SQLITE_ROW {
            if let bytes = sqlite3_column_blob(statement, 0) {
                let data = Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 0)))
                var call = try decoder.decode(ModelUsageCall.self, from: data)
                call.timestamp = Date(timeIntervalSince1970: sqlite3_column_double(statement, 1))
                if let key = ModelUsageAggregation.coverageKey(of: call) {
                    watermarks[key] = min(watermarks[key] ?? call.timestamp, call.timestamp)
                }
                if let key = ModelUsageAggregation.coverageKey(ofRun: call) { runs.append((key, call)) }
                else { ModelUsageAggregation.add(call, now: now, into: &result, rates: &rates) }
            }
            status = sqlite3_step(statement)
        }
        guard status == SQLITE_DONE else { throw error() }
        for run in runs where watermarks[run.key].map({ run.call.timestamp < $0 }) ?? true {
            ModelUsageAggregation.add(run.call, now: now, into: &result, rates: &rates)
        }
        return (result.values.sorted { $0.id < $1.id }, watermarks)
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
