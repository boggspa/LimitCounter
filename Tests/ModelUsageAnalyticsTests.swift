import Foundation

@main
struct ModelUsageAnalyticsTests {
    static var checks = 0
    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        checks += 1
        guard condition() else { fatalError(message) }
    }
    static func close(_ a: Double, _ b: Double, _ message: String) { expect(abs(a - b) < 0.000001, message) }
    static func date(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }

    static func main() async throws {
        let now = date("2026-09-24T12:00:00Z")
        let tokens = ModelTokenCounts(input: 100, cacheRead: 200, cacheWrite: 30, output: 40, reasoning: 10)
        close(tokens.total, 370, "Reasoning is an output subset")
        close(ModelRateCatalog.estimate(source: "codex", model: "codex/gpt-6-sol", tokens: tokens)!, 0.0007, "Disjoint cache pricing")
        expect(ModelRateCatalog.resolve(source: "codex", model: "unknown-routed-model") == nil, "Unknown must not use fallback")
        expect(ModelRateCatalog.resolve(source: "codex", model: "vendor/gpt-6-sol") == nil, "Unknown prefix must not be stripped")
        let tier = ModelTokenCounts(input: 272000, output: 1000)
        close(ModelRateCatalog.estimate(source: "codex", model: "gpt-6-sol", tokens: tier)!, 1.103, "Long prompt switches every token")
        close(ModelRateCatalog.estimate(source: "codex", model: "gpt-6-sol", tokens: .init(input: 271999, output: 1000))!, 0.553998, "Below threshold uses base rate")
        expect(ModelRateCatalog.rates.count == 191, "Whole verified catalog imported")
        for rate in ModelRateCatalog.rates where rate.status == .subscription || rate.status == .pending {
            expect(rate.estimate(tokens) == nil, "Subscription and pending are not free")
        }
        for rate in ModelRateCatalog.rates where rate.status == .free { expect(rate.estimate(tokens) == 0, "Explicit free models retain zero") }

        var parser = ModelUsageLogParser.State(source: .codex, fileID: "test")
        func tokenRow(_ total: [String: Int], last: [String: Int]? = nil) -> [String: Any] {
            ["timestamp": "2026-09-24T11:00:00Z", "payload": ["type": "token_count", "info": ["total_token_usage": total, "last_token_usage": last ?? total]]]
        }
        let first = parser.consume(tokenRow(["input_tokens": 100, "cached_input_tokens": 40, "cache_write_input_tokens": 10, "output_tokens": 20, "reasoning_output_tokens": 5]))!
        expect(first.model == "Unknown model", "No retroactive model attribution before turn_context")
        close(first.tokens.total, 120, "Codex cache fields are subsets of input")
        close(first.tokens.input, 50, "Codex fresh input subtracts both cache fields")
        expect(parser.consume(tokenRow(["input_tokens": 100, "output_tokens": 20])) == nil, "Repeated cumulative total skipped")
        _ = parser.consume(["type": "turn_context", "payload": ["model": "gpt-6-sol"]])
        let second = parser.consume(tokenRow(["input_tokens": 180, "cached_input_tokens": 60, "cache_write_input_tokens": 10, "output_tokens": 30], last: ["input_tokens": 80, "cached_input_tokens": 20, "output_tokens": 10]))!
        close(second.tokens.total, 90, "Cumulative delta counted once")
        expect(second.model == "gpt-6-sol", "Turn model retained")
        let reset = parser.consume(tokenRow(["input_tokens": 25, "output_tokens": 5]))!
        close(reset.tokens.total, 30, "Reset is a new usage cycle")
        var inherited = ModelUsageLogParser.State(source: .codex, fileID: "inherited")
        let inheritedCall = inherited.consume(tokenRow(["input_tokens": 1000000, "output_tokens": 200000], last: ["input_tokens": 50, "output_tokens": 10]))!
        close(inheritedCall.tokens.total, 60, "First event does not count inherited cumulative history")

        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("model-usage-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let ledger = try ModelUsageLedger(url: temporary.appendingPathComponent("test.sqlite"))
        var call = ModelUsageCall(id: "same-request", source: "claude", timestamp: now.addingTimeInterval(-100), model: "claude-opus-5-5", tokens: .init(input: 100, cacheRead: 1000, output: 10))
        try ledger.replaceFile(source: "claude", file: "a", modified: now, bytes: 10, version: 1) { emit in
            try emit(call); call.tokens.output = 20; try emit(call); return 0
        }
        call.tokens.output = 15
        try ledger.replaceFile(source: "claude", file: "b", modified: now, bytes: 20, version: 1) { emit in try emit(call); return 0 }
        let rows = try ledger.rollups(now: now)
        close(ModelUsageTotals(rows).tokens.total, 1120, "Global duplicates choose most complete response")
        expect(ModelUsageTotals(rows).requests == 1, "Streaming blocks and copies are one call")
        let isCurrent = try ledger.isCurrent(source: "claude", file: "a", modified: now, bytes: 10, version: 1)
        let changedVersion = try ledger.isCurrent(source: "claude", file: "a", modified: now, bytes: 10, version: 2)
        expect(isCurrent, "Unchanged file cached")
        expect(!changedVersion, "Parser changes invalidate cache")
        do {
            try ledger.replaceFile(source: "claude", file: "a", modified: now, bytes: 99, version: 1) { _ in throw ModelUsageError.incompleteFile }
        } catch {}
        close(ModelUsageTotals(try ledger.rollups(now: now)).tokens.total, 1120, "Failed replacement rolls back")
        try ledger.replaceFile(source: "claude", file: "a", modified: now, bytes: 0, version: 1) { _ in 0 }
        close(ModelUsageTotals(try ledger.rollups(now: now)).tokens.total, 1115, "Truncation removes only its own contribution")

        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "Europe/London")!
        let autumn = date("2026-10-25T12:00:00Z")
        let days = ModelUsageCalendar.days([], count: 365, now: autumn, calendar: calendar)
        expect(days.count == 365 && Set(days.map(\.date)).count == 365, "Calendar days survive DST")
        expect(ModelUsageCalendar.twoHourIndex(date("2026-10-25T00:30:00Z"), calendar: calendar) == ModelUsageCalendar.twoHourIndex(date("2026-10-25T01:30:00Z"), calendar: calendar), "Repeated hour shares the wall-clock cell")
        let spring = ModelUsageCalendar.days([], count: 3, now: date("2026-03-30T12:00:00Z"), calendar: calendar)
        expect(spring[2].date.timeIntervalSince(spring[1].date) == 23 * 3600, "Spring day is 23 hours")
        expect(ModelUsageCalendar.streaks([.init(date: now, tokens: 10), .init(date: now, tokens: 20), .init(date: now)]).current == 2, "Today may be empty before activity starts")
        expect(ModelUsageAggregation.bucketStart(now.addingTimeInterval(-91 * 86400), now: now).1 == 3600, "Older history compacts to hours")
        expect(ModelUsageAggregation.bucketStart(now.addingTimeInterval(-3600), now: now).1 == 300, "Recent history retains five minute precision")

        let archive = ModelUsageArchive(generatedAt: now, buckets: rows)
        try ModelUsageArchiveStore.save(archive, to: temporary)
        expect(ModelUsageArchiveStore.load(from: temporary) == archive, "Atomic archive round trip")
        let data = try JSONEncoder().encode(archive)
        let decoded = try ModelUsageArchive.decode(data)
        expect(decoded == archive, "Cloud payload round trip")
        let compressed = try archive.cloudEncoded()
        let cloudDecoded = try ModelUsageArchive.decodeCloud(compressed)
        expect(cloudDecoded == archive, "Compressed CloudKit archive round trip")
        let oldTransport = try ModelUsageArchive.decodeCloud(data)
        expect(oldTransport == archive, "Uncompressed archive backward compatibility")
        var largeArchive = archive
        largeArchive.buckets = (0..<10000).map { index in
            var row = rows[0]; row.start = now.addingTimeInterval(Double(-index * 300)); return row
        }
        let compact = try largeArchive.cloudEncoded()
        expect(compact.count < 300_000, "Year rollups remain compact in cloud transport")
        let json = String(decoding: data, as: UTF8.self)
        expect(!json.contains("same-request") && !json.contains("file"), "Cloud payload has no request IDs or paths")
        var future = archive; future.version = 999
        do { _ = try future.validated(); fatalError("Unsupported schema accepted") } catch {}

        // Large, malformed and unfinished transcript rows do not prevent later valid rows.
        let fixtures = temporary.appendingPathComponent("fixture.jsonl")
        let claudeLine: [String: Any] = ["timestamp":"2026-09-24T11:30:00Z", "requestId":"r", "message":["id":"m", "model":"claude-opus-5-5", "usage":["input_tokens":100,"cache_creation_input_tokens":20,"cache_read_input_tokens":30,"output_tokens":40]]]
        var fixture = Data("bad json\n".utf8); fixture.append(try JSONSerialization.data(withJSONObject: claudeLine)); fixture.append(10); fixture.append(Data("{unfinished".utf8))
        try fixture.write(to: fixtures)
        var parsed: [ModelUsageCall] = []
        let malformed = try ModelUsageLogParser.read(url: fixtures, source: .claude, fileID: "f") { parsed.append($0) }
        expect(malformed == 2 && parsed.count == 1, "Malformed lines isolated")
        close(parsed[0].tokens.total, 190, "Claude cache counts are additive")
        print("Model usage analytics: \(checks) checks passed")
    }
}
