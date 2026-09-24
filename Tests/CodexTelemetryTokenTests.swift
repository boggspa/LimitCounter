import Foundation
import SQLite3

private enum TestError: Error, CustomStringConvertible {
    case failure(String)

    var description: String {
        switch self {
        case .failure(let message):
            return message
        }
    }
}

private func expect(_ condition: Bool, _ label: String) throws {
    guard condition else {
        throw TestError.failure(label)
    }
}

private func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ label: String) throws {
    guard actual == expected else {
        throw TestError.failure("\(label): expected \(expected), got \(actual)")
    }
}

// MARK: - Fixture helpers

private func makeTempRoot(_ name: String) throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("codex-telemetry-tests-\(name)-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

/// One `token_count` line as Codex writes it: a cumulative session running
/// total plus, optionally, that turn's own delta.
private func tokenCountLine(
    at date: Date,
    cumulative: Double,
    lastTurn: Double?
) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    var info: [String: Any] = [
        "total_token_usage": ["total_tokens": cumulative]
    ]
    if let lastTurn {
        info["last_token_usage"] = ["total_tokens": lastTurn]
    }
    let object: [String: Any] = [
        "timestamp": formatter.string(from: date),
        "type": "event_msg",
        "payload": ["type": "token_count", "info": info]
    ]
    let data = try! JSONSerialization.data(withJSONObject: object)
    return String(data: data, encoding: .utf8)!
}

private func writeSession(
    in root: URL,
    named name: String,
    lines: [String],
    on date: Date
) throws {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy/MM/dd"
    let dir = root
        .appendingPathComponent("sessions")
        .appendingPathComponent(formatter.string(from: date))
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try lines.joined(separator: "\n").write(
        to: dir.appendingPathComponent(name),
        atomically: true,
        encoding: .utf8
    )
}

private func snapshot(root: URL) throws -> QuotaSnapshot {
    let client = CodexTelemetryProviderClient(
        fileManager: .default,
        previousEvents: { [] },
        parseCache: TelemetryParseCache(filename: "parse-cache.jsonl", directory: root),
        supplementalEvents: { [] }
    )
    let credential = ProviderCredential(customEndpoint: root.path)

    var result: Result<QuotaSnapshot, Error>?
    let done = DispatchSemaphore(value: 0)
    Task {
        do {
            result = .success(try await client.fetchSnapshot(credentials: credential))
        } catch {
            result = .failure(error)
        }
        done.signal()
    }
    done.wait()

    switch result {
    case .success(let snapshot):
        return snapshot
    case .failure(let error):
        throw error
    case .none:
        throw TestError.failure("fetchSnapshot produced no result")
    }
}

private func snapshotTokens(root: URL) throws -> Double {
    try snapshot(root: root).events.reduce(0) { $0 + ($1.tokens ?? 0) }
}

private func sessionLine(at date: Date, type: String, payload: [String: Any]) throws -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let data = try JSONSerialization.data(withJSONObject: [
        "timestamp": formatter.string(from: date), "type": type, "payload": payload
    ])
    return String(decoding: data, as: UTF8.self)
}

// MARK: - Tests

/// `total_token_usage` is cumulative, so a token_count event that restates an
/// unchanged total is a repeat of a turn already counted, not new spend.
private func testRepeatedTokenCountCountedOnce() throws {
    let root = try makeTempRoot("repeat")
    defer { try? FileManager.default.removeItem(at: root) }

    let now = Date().addingTimeInterval(-60 * 60)
    try writeSession(
        in: root,
        named: "rollout-repeat.jsonl",
        lines: [
            tokenCountLine(at: now, cumulative: 100, lastTurn: 100),
            tokenCountLine(at: now.addingTimeInterval(60), cumulative: 200, lastTurn: 100),
            // Same cumulative re-emitted twice: no new spend.
            tokenCountLine(at: now.addingTimeInterval(120), cumulative: 200, lastTurn: 100),
            tokenCountLine(at: now.addingTimeInterval(180), cumulative: 200, lastTurn: 100)
        ],
        on: now
    )

    let result = try snapshot(root: root)
    try expectEqual(result.events.reduce(0) { $0 + ($1.tokens ?? 0) }, 200, "repeated token_count events counted once")
    try expectEqual(result.events.count, 2, "repeated token_count events do not create activity markers")
}

/// A turn with no `last_token_usage` must be billed the cumulative ADVANCE,
/// never the cumulative total itself.
private func testMissingDeltaUsesAdvance() throws {
    let root = try makeTempRoot("advance")
    defer { try? FileManager.default.removeItem(at: root) }

    let now = Date().addingTimeInterval(-60 * 60)
    try writeSession(
        in: root,
        named: "rollout-advance.jsonl",
        lines: [
            tokenCountLine(at: now, cumulative: 1_000, lastTurn: 1_000),
            tokenCountLine(at: now.addingTimeInterval(60), cumulative: 1_250, lastTurn: nil)
        ],
        on: now
    )

    try expectEqual(try snapshotTokens(root: root), 1_250, "missing delta billed as advance, not total")
}

/// The per-bucket event cap bounds how much reaches the persisted snapshot. It
/// must not bound the tokens: overflow spend is folded into a retained event.
private func testBucketOverflowKeepsTokens() throws {
    let root = try makeTempRoot("overflow")
    defer { try? FileManager.default.removeItem(at: root) }

    // 40 turns of 100 tokens inside one 2h bucket, well past the cap of 8.
    let now = Date().addingTimeInterval(-60 * 60)
    var lines: [String] = []
    for turn in 1...40 {
        lines.append(
            tokenCountLine(
                at: now.addingTimeInterval(Double(turn)),
                cumulative: Double(turn) * 100,
                lastTurn: 100
            )
        )
    }
    try writeSession(in: root, named: "rollout-overflow.jsonl", lines: lines, on: now)

    try expectEqual(try snapshotTokens(root: root), 4_000, "bucket overflow retains every token")
}

/// Session JSONL used to collapse to two files whenever logs_2.sqlite existed,
/// even though the SQLite path contributes no tokens at all.
private func testSessionFilesReadDespiteSQLite() throws {
    let root = try makeTempRoot("sqlite")
    defer { try? FileManager.default.removeItem(at: root) }

    // Presence is what used to trigger the collapse; contents don't matter.
    FileManager.default.createFile(atPath: root.appendingPathComponent("logs_2.sqlite").path, contents: Data())

    let now = Date().addingTimeInterval(-60 * 60)
    for session in 1...5 {
        try writeSession(
            in: root,
            named: "rollout-\(session).jsonl",
            lines: [tokenCountLine(at: now.addingTimeInterval(Double(session)), cumulative: 500, lastTurn: 500)],
            on: now
        )
    }

    try expectEqual(try snapshotTokens(root: root), 2_500, "all session files read when logs_2.sqlite is present")
}

private func testDiagnosticDatabaseDoesNotCreateActivity() throws {
    let root = try makeTempRoot("idle-sqlite")
    defer { try? FileManager.default.removeItem(at: root) }
    var db: OpaquePointer?
    try expectEqual(sqlite3_open(root.appendingPathComponent("logs_2.sqlite").path, &db), SQLITE_OK, "create log database")
    defer { sqlite3_close(db) }
    try expectEqual(sqlite3_exec(db, "CREATE TABLE logs (ts INTEGER, target TEXT, feedback_log_body TEXT)", nil, nil, nil), SQLITE_OK, "create logs table")
    let timestamp = Int(Date().addingTimeInterval(-3_600).timeIntervalSince1970)
    for _ in 0..<300 {
        let sql = "INSERT INTO logs VALUES (\(timestamp), 'codex_config::loader', 'background configuration reload')"
        try expectEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK, "insert idle diagnostic")
    }
    let result = try snapshot(root: root)
    try expect(result.events.isEmpty, "idle logs do not light any heatmap cells")
    try expect(result.windows.allSatisfy { $0.used == 0 }, "idle logs do not increase session or weekly activity counts")
}

private func testMetadataAndEmptyTokenNotificationsAreIgnored() throws {
    let root = try makeTempRoot("metadata")
    defer { try? FileManager.default.removeItem(at: root) }
    let now = Date().addingTimeInterval(-3_600)
    let lines = try [
        sessionLine(at: now, type: "session_meta", payload: ["name": "user prompt", "content": "assistant response"]),
        sessionLine(at: now, type: "world_state", payload: ["message": "updated"]),
        sessionLine(at: now, type: "turn_context", payload: ["type": "message", "role": "user"]),
        sessionLine(at: now, type: "response_item", payload: ["type": "message", "role": "developer", "content": "context"]),
        sessionLine(at: now, type: "event_msg", payload: ["type": "thread_settings_applied"]),
        sessionLine(at: now, type: "event_msg", payload: ["type": "token_count", "info": NSNull()]),
        sessionLine(at: now, type: "token_usage_record", payload: ["usage": ["total_tokens": 500]]),
        tokenCountLine(at: now, cumulative: 0, lastTurn: 0)
    ]
    try writeSession(in: root, named: "rollout-metadata.jsonl", lines: lines, on: now)
    try expect(try snapshot(root: root).events.isEmpty, "metadata and empty token notifications are not activity")
}

private func testConfirmedActivityKeepsItsRealTimestamp() throws {
    let root = try makeTempRoot("confirmed-activity")
    defer { try? FileManager.default.removeItem(at: root) }
    let calendar = Calendar.current
    let yesterday = calendar.date(byAdding: .day, value: -1, to: Date())!
    let promptTime = calendar.date(bySettingHour: 11, minute: 59, second: 0, of: yesterday)!
    let toolTime = promptTime.addingTimeInterval(120)
    let futureTime = Date().addingTimeInterval(7_200)
    try writeSession(in: root, named: "rollout-activity.jsonl", lines: [
        try sessionLine(at: promptTime, type: "response_item", payload: ["type": "message", "role": "user"]),
        try sessionLine(at: toolTime, type: "response_item", payload: ["type": "function_call", "name": "exec_command"]),
        try sessionLine(at: futureTime, type: "event_msg", payload: ["type": "task_started"])
    ], on: yesterday)
    let events = try snapshot(root: root).events.sorted { $0.timestamp < $1.timestamp }
    try expectEqual(events.map(\.timestamp), [promptTime, toolTime], "activity is not spread across a bucket or into the future")
    try expect(events.allSatisfy { $0.type == .activity && $0.tokens == 0 }, "recognised work without token counts stays visible")
}

private func testLegacyHistoryIsCleanedOnReadAndWrite() throws {
    let suiteName = "codex-history-tests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let store = QuotaSnapshotStore(defaults: defaults)
    let date = Date().addingTimeInterval(-3_600)
    let legacyNoise = UsageEvent(timestamp: date, tokens: 0, model: "Codex", type: .telemetry)
    let legacyUsage = UsageEvent(timestamp: date, tokens: 100, model: "Codex", type: .telemetry)
    let task = UsageEvent(timestamp: date, tokens: 0, model: "Codex", type: .activity)
    let importedRun = UsageEvent(timestamp: date, model: "Codex", type: .message)
    let future = UsageEvent(timestamp: Date().addingTimeInterval(3_600), tokens: 100, model: "Codex", type: .telemetry)
    let events = [legacyNoise, legacyUsage, task, importedRun, future]
    let snapshots = [ProviderID.openai, .codexTelemetry, .claude].map {
        QuotaSnapshot(providerID: $0, displayName: $0.displayName, events: events, fetchState: .success)
    }
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    defaults.set(try encoder.encode(snapshots), forKey: "cachedQuotaSnapshots")
    let cleaned = store.loadSnapshots()
    for snapshot in cleaned where snapshot.providerID != .claude {
        try expectEqual(snapshot.events.map(\.id), [legacyUsage.id, task.id, importedRun.id], "clean both Codex snapshot copies without deleting verified history")
    }
    try expectEqual(cleaned.last?.events.map(\.id), events.map(\.id), "other providers are unchanged")
    let persisted = try decoder.decode([QuotaSnapshot].self, from: defaults.data(forKey: "cachedQuotaSnapshots")!)
    try expectEqual(persisted, cleaned, "migration persists cleaned history")
    store.replaceAll(snapshots)
    let written = try decoder.decode([QuotaSnapshot].self, from: defaults.data(forKey: "cachedQuotaSnapshots")!)
    try expectEqual(written, cleaned, "old synced snapshots cannot restore diagnostic markers")
    try expectEqual(store.loadSnapshots(), cleaned, "cleanup is idempotent")
}

private func testPreviousParserCacheIsInvalidated() throws {
    let root = try makeTempRoot("old-parser-cache")
    defer { try? FileManager.default.removeItem(at: root) }

    let turnAt = Date().addingTimeInterval(-60 * 60)
    try writeSession(
        in: root,
        named: "rollout-cached.jsonl",
        lines: [tokenCountLine(at: turnAt, cumulative: 100, lastTurn: 100)],
        on: turnAt
    )
    // Found the way the client finds it, so the cache key's path matches
    // (the enumerator resolves the temporary directory's /var symlink).
    let enumerator = FileManager.default.enumerator(
        at: root.appendingPathComponent("sessions"),
        includingPropertiesForKeys: nil
    )
    let file = try (enumerator?.allObjects as? [URL])?
        .first { $0.lastPathComponent == "rollout-cached.jsonl" }
        ?? { throw TestError.failure("session fixture missing") }()
    let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
    let modifiedAt = try (attributes[.modificationDate] as? Date)
        ?? { throw TestError.failure("no modification date") }()
    let size = (attributes[.size] as? NSNumber)?.intValue ?? 0

    // Records a parser produced for this exact file, in the whole-file layout.
    let staleRecords = """
    [{"t":\(turnAt.timeIntervalSinceReferenceDate),"e":"token_count","k":999999,"p":false,"r":false,"o":false,"a":false,"n":1}]
    """
    func writeCache(version: Int) throws {
        let entry = try JSONSerialization.data(withJSONObject: [
            "p": "codexTelemetry", "f": file.path,
            "m": modifiedAt.timeIntervalSince1970, "s": size,
            "d": Data(staleRecords.utf8).base64EncodedString()
        ])
        let contents = "{\"version\":\(version)}\n" + String(decoding: entry, as: UTF8.self) + "\n"
        try contents.write(to: root.appendingPathComponent("parse-cache.jsonl"), atomically: true, encoding: .utf8)
    }

    // Control: the current version's entry is served, so the file matches it.
    try writeCache(version: 2)
    try expectEqual(try snapshotTokens(root: root), 999_999, "a current cache entry is served for an unchanged file")

    try writeCache(version: 1)
    try expectEqual(
        try snapshotTokens(root: root),
        100,
        "unchanged session files are reparsed instead of serving an old parser's records"
    )
}

// MARK: - Runner

@main
private enum CodexTelemetryTokenTestRunner {
    static func main() throws {
        try testRepeatedTokenCountCountedOnce()
        try testMissingDeltaUsesAdvance()
        try testBucketOverflowKeepsTokens()
        try testSessionFilesReadDespiteSQLite()
        try testDiagnosticDatabaseDoesNotCreateActivity()
        try testMetadataAndEmptyTokenNotificationsAreIgnored()
        try testConfirmedActivityKeepsItsRealTimestamp()
        try testLegacyHistoryIsCleanedOnReadAndWrite()
        try testPreviousParserCacheIsInvalidated()
        print("Codex telemetry token tests passed")
    }
}
