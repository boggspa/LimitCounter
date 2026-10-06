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

private func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ label: String) throws {
    guard actual == expected else {
        throw TestError.failure("\(label): expected \(expected), got \(actual)")
    }
}

private func window(_ label: String) -> QuotaWindow {
    QuotaWindow(
        label: label,
        windowKind: .daily,
        used: label.contains("Pro") ? 2 : 0,
        total: 100,
        resetDate: Date().addingTimeInterval(24 * 60 * 60),
        unit: "%",
        subtitle: "test"
    )
}

private func testGeminiLiveSummaryWindows() throws {
    let snapshot = QuotaSnapshot(
        providerID: .gemini,
        displayName: "Gemini CLI",
        windows: [
            window("Pro 3.1 (preview)"),
            window("Flash Lite 3.1 (preview)"),
            window("Pro 3 (preview)"),
            window("Flash 3 (preview)"),
            window("Pro 2.5"),
            window("Flash 2.5"),
            window("Flash Lite 2.5")
        ]
    )

    try expectEqual(snapshot.windows.count, 7, "full window count")
    try expectEqual(
        snapshot.summaryWindows.map(\.label),
        ["Pro 3.1 (preview)", "Flash 3 (preview)", "Flash Lite 3.1 (preview)"],
        "Gemini live summary labels"
    )
}

private func testGeminiLocalFallbackSummaryWindows() throws {
    let snapshot = QuotaSnapshot(
        providerID: .gemini,
        displayName: "Gemini CLI",
        windows: [
            window("Flash"),
            window("Flash Lite"),
            window("Pro"),
            window("Daily Requests"),
            window("Weekly Requests")
        ]
    )

    try expectEqual(
        snapshot.summaryWindows.map(\.label),
        ["Pro", "Flash", "Flash Lite"],
        "Gemini local fallback summary labels"
    )
}

private func fractionalDate(_ value: String) throws -> Date {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    guard let date = formatter.date(from: value) else {
        throw TestError.failure("fixture timestamp did not parse: \(value)")
    }
    return date
}

/// Gemini CLI writes `.jsonl` session files whose every line carries a
/// JavaScript `toISOString()` timestamp, always with milliseconds. Where
/// `JSONDecoder`'s `.iso8601` strategy rejects those, every message line was
/// skipped, no session had messages, and the provider reported nothing; the
/// reader now parses them explicitly on every Foundation.
private func testGeminiLocalReaderDecodesFractionalSecondTimestamps() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("limit-counter-gemini-reader-\(UUID().uuidString)", isDirectory: true)
    let chats = root.appendingPathComponent("tmp/project-hash/chats", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: chats, withIntermediateDirectories: true)

    let modern = """
    {"sessionId":"session-1","projectHash":"project-hash","startTime":"2026-05-01T10:00:00.000Z","lastUpdated":"2026-05-01T10:00:02.250Z","kind":"session"}
    {"id":"m1","timestamp":"2026-05-01T10:00:00.000Z","type":"user","content":"hello"}
    {"id":"m2","timestamp":"2026-05-01T10:00:01.500Z","type":"gemini","model":"gemini-2.5-pro","content":[{"text":"hi"}],"tokens":{"input":1000,"output":50,"cached":800,"thoughts":20,"total":1070}}
    {"id":"m3","timestamp":"2026-05-01T10:00:02.250Z","type":"gemini","model":"gemini-2.5-flash","content":"done","tokens":{"input":10,"output":5,"total":15}}
    """
    let modernURL = chats.appendingPathComponent("session-2026-05-01T10-00-session-1.jsonl")
    try modern.write(to: modernURL, atomically: true, encoding: .utf8)

    // Older CLI builds wrote one object per file with whole-second
    // timestamps; those must keep parsing alongside the fractional ones.
    let legacy = """
    {"sessionId":"session-0","messages":[
      {"id":"l1","timestamp":"2026-04-30T09:00:00Z","type":"user","content":"older"},
      {"id":"l2","timestamp":"2026-04-30T09:00:03Z","type":"gemini","model":"gemini-2.5-pro","content":"reply","tokens":{"input":5,"output":5,"total":10}}
    ]}
    """
    try legacy.write(to: chats.appendingPathComponent("session-legacy.json"), atomically: true, encoding: .utf8)

    let reader = GeminiLocalStateReader(fileManager: .default)
    let parsed = try reader.parseGeminiSessionFile(at: modernURL)
        ?? { throw TestError.failure("session with fractional-second timestamps did not parse") }()
    try expectEqual(parsed.sessionId, "session-1", "JSONL session id")
    try expectEqual(parsed.messages.count, 3, "JSONL message count")
    try expectEqual(
        parsed.messages.compactMap(\.timestamp),
        [
            fractionalDate("2026-05-01T10:00:00.000Z"),
            fractionalDate("2026-05-01T10:00:01.500Z"),
            fractionalDate("2026-05-01T10:00:02.250Z")
        ],
        "JSONL message timestamps keep their milliseconds"
    )
    try expectEqual(parsed.messages[1].tokens?.input, 1000, "JSONL message tokens")

    let snapshot = try reader.loadSnapshotUncached(rootURL: root, credentials: nil, latestFileDate: Date())
    try expectEqual(snapshot.stats.first(where: { $0.label == "Sessions" })?.value, 2, "Gemini conversation count")
    try expectEqual(snapshot.stats.first(where: { $0.label == "Total Requests" })?.value, 3, "Gemini request count")
    try expectEqual(snapshot.fetchedAt, fractionalDate("2026-05-01T10:00:02.250Z"), "latest activity keeps its milliseconds")
}

private func testNonGeminiSummaryWindowsAreUnchanged() throws {
    let snapshot = QuotaSnapshot(
        providerID: .claude,
        displayName: "Claude Code",
        windows: [window("Session"), window("Weekly"), window("Other")]
    )

    try expectEqual(snapshot.summaryWindows.map(\.label), snapshot.windows.map(\.label), "non-Gemini summary labels")
}

@main
private enum GeminiSummaryWindowTestRunner {
    static func main() throws {
        try testGeminiLiveSummaryWindows()
        try testGeminiLocalFallbackSummaryWindows()
        try testNonGeminiSummaryWindowsAreUnchanged()
        try testGeminiLocalReaderDecodesFractionalSecondTimestamps()
        print("Gemini summary window tests passed")
    }
}
