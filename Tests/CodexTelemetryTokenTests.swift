import Foundation

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

private func snapshotTokens(root: URL) throws -> Double {
    let client = CodexTelemetryProviderClient()
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
        return snapshot.events.reduce(0) { $0 + ($1.tokens ?? 0) }
    case .failure(let error):
        throw error
    case .none:
        throw TestError.failure("fetchSnapshot produced no result")
    }
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

    try expectEqual(try snapshotTokens(root: root), 200, "repeated token_count events counted once")
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

// MARK: - Runner

@main
private enum CodexTelemetryTokenTestRunner {
    static func main() throws {
        try testRepeatedTokenCountCountedOnce()
        try testMissingDeltaUsesAdvance()
        try testBucketOverflowKeepsTokens()
        try testSessionFilesReadDespiteSQLite()
        print("Codex telemetry token tests passed")
    }
}
