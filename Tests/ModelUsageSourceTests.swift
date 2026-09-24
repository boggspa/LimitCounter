import Foundation

/// Pricing bounds, schema compatibility and source parsing for model usage history.
@main
struct ModelUsageSourceTests {
    static var checks = 0
    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        checks += 1
        guard condition() else { fatalError(message) }
    }
    static func close(_ a: Double?, _ b: Double, _ message: String) { expect(a.map { abs($0 - b) < 0.000001 } ?? false, message) }
    static func date(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }

    static func main() async throws {
        try pricingBounds()
        try aggregationPricesEachRecord()
        try schemaCompatibility()
        try snapshotInsights()
        sourceAttribution()
        try await unchangedRefreshSkipsRollups()
        try await changedDayRollups()
        try streamingArrays()
        try await taskWraithImport()
        try await taskWraithPrivateHomes()
        try await nativeCLILogs()
        try await mistralVibeSessions()
        print("Model usage sources: \(checks) checks passed")
    }

    static func sourceAttribution() {
        let now = date("2026-09-24T12:00:00Z")
        let rows = ["codex", "claude", "grok", "gemini", "kimi", "taskwraith", "future-source"].map {
            ModelUsageRollup(source: $0, model: "m", start: now.addingTimeInterval(-600), seconds: 300, tokens: .init(input: 10), requests: 1)
        }
        let data = ModelUsageInsightData(archive: ModelUsageArchive(generatedAt: now, buckets: rows), snapshots: [])
        let byID = Dictionary(uniqueKeysWithValues: data.sources.map { ($0.id, $0) })
        expect(byID["codex"]?.provider == .openai && byID["claude"]?.provider == .claude, "Codex and Claude keep their hosts")
        expect(byID["grok"]?.provider == .grok && byID["gemini"]?.provider == .gemini && byID["kimi"]?.provider == .kimi, "CLI ledgers keep their own hosts")
        expect(byID["taskwraith"]?.provider == nil && byID["taskwraith"]?.title == "TaskWraith runs", "TaskWraith spans providers and claims none")
        expect(byID["future-source"]?.provider == nil && byID["future-source"]?.title == "future-source", "An unknown source never borrows Claude's identity")
        expect(data.sources.filter { $0.provider == .claude }.count == 1, "Only the Claude ledger is attributed to Claude")
        expect(ModelUsageSourceIdentity.replacedSnapshotHost("taskwraith") == nil && ModelUsageSourceIdentity.replacedSnapshotHost("grok") == nil,
               "Only request ledgers that fully cover a card replace its heatmap copy")
    }

    static func temporaryDirectory(_ name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(name)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func streamingArrays() throws {
        let directory = try temporaryDirectory("json-stream")
        defer { try? FileManager.default.removeItem(at: directory) }
        let long = String(repeating: "x", count: 700_000)
        let array = #"[ {"a":1,"s":"} ] { [ \" \\"}, {"a":2,"nested":[{"b":[1,2]}],"long":"\#(long)"} ,{"a":3} ]"#
        let arrayURL = directory.appendingPathComponent("array.json")
        try array.write(to: arrayURL, atomically: true, encoding: .utf8)
        var seen: [Int] = []
        let arrayMalformed = try JSONArrayObjectStream.read(url: arrayURL, key: nil) { seen.append(($0["a"] as? Int) ?? -1) }
        expect(seen == [1, 2, 3] && arrayMalformed == 0, "Top-level elements survive braces in strings and chunk boundaries")

        let document = #"{"sessionId":"s","directories":["messages"],"summary":"{\"messages\":[{\"a\":9}]}","messages":[{"a":4,"tokens":{"x":[1]}},{"a":5},{"broken":}],"after":[{"a":6}]}"#
        let documentURL = directory.appendingPathComponent("chat.json")
        try document.write(to: documentURL, atomically: true, encoding: .utf8)
        seen = []
        let keyedMalformed = try JSONArrayObjectStream.read(url: documentURL, key: "messages") { seen.append(($0["a"] as? Int) ?? -1) }
        expect(seen == [4, 5], "Only the keyed array is streamed, never look-alikes in values or other keys")
        expect(keyedMalformed == 1, "A broken element is counted and skipped")
        try #"[{"a":1},{"a":"#.write(to: arrayURL, atomically: true, encoding: .utf8)
        seen = []
        let truncated = try JSONArrayObjectStream.read(url: arrayURL, key: nil) { seen.append(($0["a"] as? Int) ?? -1) }
        expect(seen == [1] && truncated == 1, "A truncated checkpoint keeps complete records and counts the rest")

        // An attachment larger than the element cap, with escapes at the elision point
        // and across chunk boundaries, still yields the message's usage fields.
        let attachment = String(repeating: "z", count: JSONArrayObjectStream.maximumStringBytes - 1) + #"\"\\"#
            + String(repeating: "w", count: JSONArrayObjectStream.maximumElementBytes + 1_000_000) + #"\"}]"#
        let heavy = #"{"messages":[{"a":7,"content":"\#(attachment)","tokens":{"input":5},"note":"kept"},{"a":8,"short":"\#(long.prefix(1000))"}]}"#
        try heavy.write(to: documentURL, atomically: true, encoding: .utf8)
        var elements: [[String: Any]] = []
        let heavyMalformed = try JSONArrayObjectStream.read(url: documentURL, key: "messages") { elements.append($0) }
        expect(heavyMalformed == 0 && elements.map { ($0["a"] as? Int) ?? -1 } == [7, 8], "An element over the cap because of one string still decodes")
        expect(elements.first?["content"] as? String == "" && elements.first?["note"] as? String == "kept"
               && (elements.first?["tokens"] as? [String: Any])?["input"] as? Int == 5, "Only the oversized string is emptied")
        expect((elements.last?["short"] as? String)?.count == 1000, "Strings under the limit are kept whole")
    }

    static func taskWraithRecord(_ id: String, provider: String = "grok", model: String = "grok-4.6", input: Double = 100,
                                 output: Double = 20, total: Double? = nil, cacheRead: Double? = nil, cacheWrite: Double? = nil,
                                 extra: [String: Any] = [:]) -> [String: Any] {
        var record: [String: Any] = ["id": id, "timestamp": 1_790_000_000_000.0, "provider": provider, "workspaceId": "w", "chatId": "c",
            "runId": "run-\(id)", "usageKind": "run", "model": model, "inputTokens": input, "outputTokens": output,
            "totalTokens": total ?? (input + output + (cacheRead ?? 0) + (cacheWrite ?? 0)), "durationMs": 10,
            "promptText": "never read", "responseText": "never read"]
        if let cacheRead { record["cacheReadInputTokens"] = cacheRead }
        if let cacheWrite { record["cacheCreationInputTokens"] = cacheWrite }
        record.merge(extra) { $1 }
        return record
    }

    static func taskWraithImport() async throws {
        let call = TaskWraithUsageParser.call(from: taskWraithRecord("a", input: 100, output: 20, cacheRead: 900, cacheWrite: 50), fileID: "f")!
        expect(call.source == "taskwraith" && call.model == "grok/grok-4.6" && call.calls == 0 && !call.inferred, "A run keeps provider, model and unknown call count")
        expect(call.tokens == ModelTokenCounts(input: 100, cacheRead: 900, cacheWrite: 50, output: 20), "Itemised fresh input and cache fields stay disjoint")
        expect(call.timestamp == Date(timeIntervalSince1970: 1_790_000_000), "Epoch milliseconds are read exactly")
        let again = TaskWraithUsageParser.call(from: taskWraithRecord("a"), fileID: "other-file")!
        expect(again.id == call.id, "TaskWraith's record id deduplicates across checkpoint, journal and archive")
        let claudeRun = TaskWraithUsageParser.call(from: taskWraithRecord("d", provider: "Claude", model: "claude-opus-5-5"), fileID: "f")!
        expect(claudeRun.model == "claude/claude-opus-5-5" && ModelUsageAggregation.coverageKey(ofRun: claudeRun) == "claude",
               "Claude runs are kept, and dropped only where a Claude transcript covers them")
        let codexRun = TaskWraithUsageParser.call(from: taskWraithRecord("c", provider: "codex"), fileID: "f")!
        let cursorRun = TaskWraithUsageParser.call(from: taskWraithRecord("c2", provider: "cursor"), fileID: "f")!
        expect(ModelUsageAggregation.coverageKey(ofRun: codexRun) == "taskwraith:codex" && ModelUsageAggregation.coverageKey(ofRun: cursorRun) == nil,
               "Codex runs defer to TaskWraith's own Codex transcripts; Cursor runs have none")
        expect(TaskWraithUsageParser.call(from: taskWraithRecord("e", extra: ["usageKind": "reset_hint"]), fileID: "f") == nil, "Reset hints are not usage")
        expect(TaskWraithUsageParser.call(from: taskWraithRecord("g", extra: ["runCount": 4]), fileID: "f") == nil, "External-scan aggregates are not runs")
        expect(TaskWraithUsageParser.call(from: taskWraithRecord("h", input: 0, output: 0), fileID: "f") == nil, "Empty runs are skipped")
        var anonymous = taskWraithRecord("i"); anonymous.removeValue(forKey: "provider")
        expect(TaskWraithUsageParser.call(from: anonymous, fileID: "f") == nil, "A record without a provider cannot be kept apart from native transcripts")

        let muse = TaskWraithUsageParser.call(from: taskWraithRecord("m", provider: "muse", model: "muse-spark-1.3", input: 1000,
            output: 100, total: 1100, cacheRead: 700), fileID: "f")!
        expect(muse.tokens == ModelTokenCounts(input: 300, cacheRead: 700, output: 100), "Cache-inclusive input is separated once")
        let gemini = TaskWraithUsageParser.call(from: taskWraithRecord("n", provider: "gemini", model: "gemini-3.1-pro-preview",
            input: 100, output: 50, total: 200), fileID: "f")!
        expect(gemini.tokens == ModelTokenCounts(input: 100, output: 50, unsplit: 50), "An unitemised excess stays unsplit, not guessed")
        let odd = TaskWraithUsageParser.call(from: taskWraithRecord("o", input: 500, output: 500, total: 300), fileID: "f")!
        expect(odd.tokens == ModelTokenCounts(unsplit: 300), "Contradictory parts fall back to the inclusive total alone")
        let estimated = TaskWraithUsageParser.call(from: taskWraithRecord("p", provider: "kimi", model: "kimi-k2.7-code",
            extra: ["tokenCountConfidence": "estimated", "costRateModel": "kimi-k2.7-code-highspeed"]), fileID: "f")!
        expect(estimated.inferred && estimated.rateModel == "kimi/kimi-k2.7-code-highspeed", "Estimated counts and cost-rate models are kept")
        let projected = TaskWraithUsageParser.call(from: taskWraithRecord("p2"), fileID: "f")!
        let itemised = TaskWraithUsageParser.call(from: taskWraithRecord("p3", provider: "kimi", model: "kimi-k3", cacheRead: 800), fileID: "f")!
        expect(projected.inferred && !itemised.inferred && !cursorRun.inferred,
               "An unflagged Grok run is still a projection; itemised cache tokens and reporting providers stay measured")
        let pi = TaskWraithUsageParser.call(from: taskWraithRecord("q", provider: "pi", model: "deepseek/deepseek-v4-flash"), fileID: "f")!
        expect(ModelRateCatalog.resolve(source: pi.source, model: pi.model)?.provider == "pi", "Pi runs price with Pi rows")

        let directory = try temporaryDirectory("taskwraith")
        defer { try? FileManager.default.removeItem(at: directory) }
        let checkpoint = [taskWraithRecord("r1"), taskWraithRecord("r2", provider: "cursor", model: "composer-2.5-fast"),
                          taskWraithRecord("r3", provider: "claude")]
        try JSONSerialization.data(withJSONObject: checkpoint).write(to: directory.appendingPathComponent("usage.json"))
        let journal = ["", String(decoding: try JSONSerialization.data(withJSONObject: taskWraithRecord("r2", provider: "cursor", model: "composer-2.5-fast")), as: UTF8.self),
                       String(decoding: try JSONSerialization.data(withJSONObject: taskWraithRecord("r4", provider: "mistral", model: "devstral-small")), as: UTF8.self)]
        try journal.joined(separator: "\n").write(to: directory.appendingPathComponent("usage-journal.jsonl"), atomically: true, encoding: .utf8)
        let now = Date(timeIntervalSince1970: 1_790_000_600)
        let scanner = ModelUsageLogScanner(directory: directory.appendingPathComponent("ledger"))
        let archive = try await scanner.scan(roots: [.taskwraith: directory], now: now)
        let rows = archive.buckets.filter { $0.source == "taskwraith" }
        expect(ModelUsageTotals(rows).runs == 4, "Checkpoint and journal copies of one run count once; with no Claude log connected its run is kept")
        expect(Set(rows.map(\.model)) == ["grok/grok-4.6", "cursor/composer-2.5-fast", "mistral/devstral-small", "claude/grok-4.6"], "Runs keep their provider namespace")
        expect(archive.coverage.first { $0.source == "taskwraith" }?.files == 2, "Both TaskWraith files are indexed")
        let fileOnly = try await ModelUsageLogScanner(directory: directory.appendingPathComponent("ledger-file"))
            .scan(roots: [.taskwraith: directory.appendingPathComponent("usage.json")], now: now)
        expect(ModelUsageTotals(fileOnly.buckets).runs == 3, "A grant on usage.json alone reads just that file")
        for (stamp, kept) in [("2026-09-21T14:00:00Z", false), ("2026-09-21T14:20:00Z", true)] {
            let claude = directory.appendingPathComponent("claude-\(kept)")
            try FileManager.default.createDirectory(at: claude.appendingPathComponent("projects"), withIntermediateDirectories: true)
            try claudeLine(stamp, request: "native").write(to: claude.appendingPathComponent("projects/s.jsonl"), atomically: true, encoding: .utf8)
            let both = try await ModelUsageLogScanner(directory: directory.appendingPathComponent("ledger-\(kept)"))
                .scan(roots: [.taskwraith: directory, .claude: claude], now: now)
            let runs = both.buckets.filter { $0.source == "taskwraith" }
            expect(runs.contains { $0.model == "claude/grok-4.6" } == kept && ModelUsageTotals(runs).runs == (kept ? 4 : 3),
                   kept ? "A run from before the Claude transcripts begin is kept" : "A Claude transcript reaching back past the run supersedes its record")
        }
        let json = String(decoding: try JSONEncoder().encode(archive), as: UTF8.self)
        expect(!json.contains("never read") && !json.contains("run-r1"), "Prompts, responses and run ids never leave the record")
    }

    static func taskWraithPrivateHomes() async throws {
        let data = try temporaryDirectory("taskwraith-homes")
        defer { try? FileManager.default.removeItem(at: data) }
        func text(_ lines: [String], to path: String) throws {
            let url = data.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        }
        // TaskWraith's private Codex home: one thread whose two requests start at 12:00:05.
        try text([#"{"timestamp":"2026-09-20T12:00:00.000Z","type":"session_meta","payload":{"id":"tw-thread","originator":"taskwraith"}}"#,
                  #"{"timestamp":"2026-09-20T12:00:00.100Z","type":"turn_context","payload":{"model":"gpt-5.6-sol"}}"#,
                  #"{"timestamp":"2026-09-20T12:00:05.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":1000,"cached_input_tokens":800,"output_tokens":50},"last_token_usage":{"input_tokens":1000,"cached_input_tokens":800,"output_tokens":50}}}}"#,
                  #"{"timestamp":"2026-09-20T12:00:09.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":2200,"cached_input_tokens":1800,"output_tokens":90},"last_token_usage":{"input_tokens":1200,"cached_input_tokens":1000,"output_tokens":40}}}}"#],
                 to: "codex-home/sessions/2026/09/20/rollout-2026-09-20T12-00-00-tw-thread.jsonl")
        // A Kimi seat home, measured from 13:00.
        let seat: [String: Any] = ["type": "usage.record", "model": "kimi-code/k3", "usageScope": "turn", "time": 1_789_909_200_000,
                                   "usage": ["inputOther": 300, "output": 20, "inputCacheRead": 700, "inputCacheCreation": 0]]
        try text([#"{"type":"metadata","protocol_version":"1.5"}"#, String(decoding: try JSONSerialization.data(withJSONObject: seat), as: UTF8.self)],
                 to: "kimi-acp-seats-v2/0a1b/sessions/wd_x/session_1/agents/main/wire.jsonl")
        try text(["{}"], to: "kimi-acp-seats-v2/0a1b/credentials/kimi-code.json")
        // Run records either side of each transcript's first call.
        let records = [taskWraithRecord("early", provider: "codex", model: "gpt-5.5", extra: ["timestamp": 1_789_902_000_000.0]),
                       taskWraithRecord("late", provider: "codex", model: "gpt-5.4", extra: ["timestamp": 1_789_905_610_000.0]),
                       taskWraithRecord("before", provider: "kimi", model: "kimi-k2.7-code", extra: ["timestamp": 1_789_812_000_000.0]),
                       taskWraithRecord("after", provider: "kimi", model: "kimi-k3", extra: ["timestamp": 1_789_912_800_000.0]),
                       taskWraithRecord("vibe", provider: "mistral", model: "devstral-small", extra: ["timestamp": 1_789_912_800_000.0])]
        try JSONSerialization.data(withJSONObject: records).write(to: data.appendingPathComponent("usage.json"))

        var failed = 0
        let files = ModelUsageLogScanner.logFiles(for: .taskwraith, root: data, failed: &failed).map { $0.0.lastPathComponent }
        expect(Set(files) == ["usage.json", "rollout-2026-09-20T12-00-00-tw-thread.jsonl", "wire.jsonl"], "TaskWraith's private Codex and Kimi transcripts are found")
        let archive = try await ModelUsageLogScanner(directory: data.appendingPathComponent("ledger"))
            .scan(roots: [.taskwraith: data], now: date("2026-09-21T00:00:00Z"))
        let rows = archive.buckets.filter { $0.source == "taskwraith" }
        let codex = ModelUsageTotals(rows.filter { $0.model == "codex/gpt-5.6-sol" })
        expect(codex.requests == 2 && codex.runs == 0 && codex.tokens == ModelTokenCounts(input: 400, cacheRead: 1800, output: 90)
               && codex.pricedRequests == 2, "Each Codex call in TaskWraith's home counts once, measured and priced")
        let kimi = ModelUsageTotals(rows.filter { $0.model == "kimi/kimi-code/k3" })
        expect(kimi.requests == 1 && kimi.pricedRequests == 1 && !rows.contains { $0.model == "kimi/kimi-code/k3" && $0.inferred },
               "A Kimi seat's measured request prices through its alias")
        expect(Set(rows.filter { $0.runs > 0 }.map(\.model)) == ["codex/gpt-5.5", "kimi/kimi-k2.7-code", "mistral/devstral-small"],
               "Run records stand in only before each provider's transcripts begin")
        expect(rows.filter { $0.runs > 0 && $0.model != "codex/gpt-5.5" }.allSatisfy(\.inferred), "Projected Kimi and Mistral runs stay inferred")
        expect(archive.buckets.allSatisfy { $0.source == "taskwraith" }, "TaskWraith's transcripts never join the user's own Codex or Kimi sources")
    }

    static func write(_ object: Any, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: object).write(to: url)
    }

    /// Mistral Vibe keeps only per-session totals, as the Mistral API reported them;
    /// TaskWraith's projected Mistral runs give way to them model by model.
    static func mistralVibeSessions() async throws {
        let times = ModelUsageTimestamps()
        func session(_ id: String, start: String, model: String = "mistral-medium-3.5", prompt: Double = 67080,
                     cached: Double? = 2176, completion: Double = 661) -> [String: Any] {
            var stats: [String: Any] = ["steps": 2, "session_prompt_tokens": prompt, "session_completion_tokens": completion,
                                        "session_total_llm_tokens": prompt + completion, "session_cost": 0.1]
            if let cached { stats["session_cached_tokens"] = cached }
            return ["session_id": id, "start_time": start, "end_time": start, "stats": stats,
                    "config": ["active_model": model], "environment": ["working_directory": "/never/read"]]
        }
        let measured = MistralVibeSessionParser.call(from: session("v1", start: "2026-09-03T11:58:56.500+00:00"), fileID: "meta", times: times)!
        expect(measured.tokens == ModelTokenCounts(input: 64904, cacheRead: 2176, output: 661) && measured.calls == 0 && !measured.inferred,
               "A Vibe session keeps its reported split, as one run with an unreported call count")
        expect(measured.source == "mistral" && measured.model == "mistral-medium-3.5", "…under Mistral and its active model")
        close(measured.timestamp.timeIntervalSince1970, 1_788_436_736.5, "…dated at its start")
        expect(MistralVibeSessionParser.call(from: session("v1", start: "2026-09-03T11:58:56Z"), fileID: "other", times: times)?.id == measured.id,
               "A session's identity is its id, whichever file holds it")
        let early = MistralVibeSessionParser.call(from: session("v0", start: "2026-07-26T09:40:07Z", cached: nil), fileID: "meta", times: times)!
        let range = ModelRateCatalog.costRange(source: early.source, model: early.model, tokens: early.tokens, calls: 0)
        expect(early.tokens == ModelTokenCounts(output: 661, unsplit: 67080) && range.map { !$0.exact && $0.low < $0.high } == true,
               "A session from before Vibe reported cache keeps its prompt unsplit and prices as a range")
        expect(MistralVibeSessionParser.call(from: session("v2", start: "2026-09-03T12:00:00Z", prompt: 0, cached: 0, completion: 0), fileID: "m", times: times) == nil
               && MistralVibeSessionParser.call(from: ["session_id": "v4", "start_time": "2026-09-03T12:00:00Z"], fileID: "m", times: times) == nil,
               "Sessions without tokens are not usage")

        let home = try temporaryDirectory("vibe")
        defer { try? FileManager.default.removeItem(at: home) }
        let sessions = home.appendingPathComponent(".vibe/logs/session")
        try write(session("v1", start: "2026-09-20T10:00:00Z"), to: sessions.appendingPathComponent("session_a/meta.json"))
        try write(session("v3", start: "2026-09-21T10:00:00Z", model: "devstral-small", prompt: 1000, cached: 900, completion: 10),
                  to: sessions.appendingPathComponent("session_b/meta.json"))
        try "{\"role\":\"user\",\"content\":\"never read\"}\n".write(to: sessions.appendingPathComponent("session_a/messages.jsonl"), atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: sessions.appendingPathComponent("session_c"), withIntermediateDirectories: true)
        try "{ not json".write(to: sessions.appendingPathComponent("session_c/meta.json"), atomically: true, encoding: .utf8)
        var failed = 0
        for grant in [".vibe", ".vibe/logs", ".vibe/logs/session", ".vibe/logs/session/session_a/meta.json"] {
            let files = ModelUsageLogScanner.logFiles(for: .mistral, root: home.appendingPathComponent(grant), failed: &failed)
            expect(files.count == 3 && files.allSatisfy { $0.0.lastPathComponent == "meta.json" }, "Vibe grant \(grant) finds session metadata only")
        }

        let data = home.appendingPathComponent("taskwraith")
        let runs = [("t1", "mistral-medium-3.5", "2026-09-19T12:00:00Z"), ("t2", "mistral-medium-3.5", "2026-09-20T12:00:00Z"),
                    ("t3", "devstral-2512", "2026-09-20T12:00:00Z")].map {
            taskWraithRecord($0.0, provider: "mistral", model: $0.1, extra: ["timestamp": date($0.2).timeIntervalSince1970 * 1000])
        }
        try write(runs, to: data.appendingPathComponent("usage.json"))
        let now = date("2026-09-24T12:00:00Z")
        let archive = try await ModelUsageLogScanner(directory: home.appendingPathComponent("ledger"))
            .scan(roots: [.mistral: home.appendingPathComponent(".vibe"), .taskwraith: data], now: now)
        let vibe = ModelUsageTotals(archive.buckets.filter { $0.source == "mistral" })
        expect(vibe.runs == 2 && vibe.tokens.total == 67741 + 1010 && vibe.pricedRequests == vibe.requests,
               "Vibe sessions index as runs and price through Mistral's rows")
        expect(archive.coverage.first { $0.source == "mistral" }?.malformedLines == 1, "An unreadable session file is counted, not guessed")
        let taskwraith = archive.buckets.filter { $0.source == "taskwraith" }
        expect(ModelUsageTotals(taskwraith).runs == 2 && Set(taskwraith.map(\.model)) == ["mistral/mistral-medium-3.5", "mistral/devstral-2512"],
               "TaskWraith's run before Vibe's first session of its model stays, the later one is dropped, and runs of models Vibe never ran stay")
        expect(ModelUsageSourceIdentity.title("mistral") == "Mistral Vibe local" && ModelUsageSourceIdentity.host("mistral") == .mistral,
               "The source is attributed to Mistral")

        let card = QuotaSnapshot(providerID: .mistral, displayName: "Mistral", windows: [], analyticsBuckets: [
            UsageAnalyticsBucket(startDate: now.addingTimeInterval(-86400), endDate: now, model: "mistral-medium-3.5", inputTokens: 10_000,
                outputTokens: 1000, requests: 5, costUSD: 0.5, source: .localEstimate, note: "TaskWraith-style chars÷4 × catalogue"),
            UsageAnalyticsBucket(startDate: now.addingTimeInterval(-86400), endDate: now, costUSD: 9, source: .officialAPI, note: "Cost")])
        let sources = Set(ModelUsageInsightData(archive: archive, snapshots: [card]).entries.map(\.source))
        expect(!sources.contains("mistral:localEstimate") && sources.contains("mistral:officialAPI") && sources.contains("mistral"),
               "Measured Vibe history replaces the card's estimates, never its API spend")
    }

    static func nativeCLILogs() async throws {
        let times = ModelUsageTimestamps()
        // Grok: input includes cached reads and cache creation; one row per model per turn.
        let turn: [String: Any] = ["turnNumber": 3, "endedAt": "2026-09-23T13:00:13.969886+00:00", "inputTokens": 1000,
            "modelUsage": ["grok-4.6-build": ["inputTokens": 600, "cachedReadTokens": 500, "cacheCreationTokens": 40,
                                              "outputTokens": 30, "reasoningTokens": 10, "totalTokens": 630, "modelCalls": 2],
                           "grok-4.7-build": ["inputTokens": 400, "cachedReadTokens": 0, "outputTokens": 20, "totalTokens": 420, "modelCalls": 1]]]
        let grok = GrokUsageParser.calls(from: turn, fileID: "session", times: times)
        expect(grok.count == 2 && grok[0].model == "grok-4.6-build", "Each model in a turn is its own record")
        expect(grok[0].tokens == ModelTokenCounts(input: 60, cacheRead: 500, cacheWrite: 40, output: 30, reasoning: 10), "Grok cache fields are carved out of input")
        expect(grok[0].calls == 2 && grok[1].calls == 1, "Grok's model call counts are kept")
        close(grok[0].timestamp.timeIntervalSince1970, 1_790_168_413.969, "Microsecond timestamps parse")
        expect(grok[0].id != grok[1].id && grok[0].id == GrokUsageParser.calls(from: turn, fileID: "session", times: times)[0].id, "Grok identity is stable per turn and model")
        let bare: [String: Any] = ["turnNumber": 4, "endedAt": "2026-09-23T13:05:00+00:00", "inputTokens": 50, "outputTokens": 5, "totalTokens": 55]
        let unattributed = GrokUsageParser.calls(from: bare, fileID: "session", times: times)
        expect(unattributed.count == 1 && unattributed[0].model == "Unknown model" && unattributed[0].calls == 0, "A turn without model usage stays unattributed")

        // Gemini: cached is part of input; tool prompts bill as input and thoughts as output.
        let message: [String: Any] = ["id": "g1", "timestamp": "2026-05-01T10:00:00.000Z", "type": "gemini", "model": "gemini-3-flash-preview",
            "tokens": ["input": 1000, "output": 50, "cached": 800, "thoughts": 20, "tool": 5, "total": 1075]]
        let gemini = GeminiChatParser.call(from: message, fileID: "chat", times: times)!
        expect(gemini.tokens == ModelTokenCounts(input: 205, cacheRead: 800, output: 70, reasoning: 20), "Gemini reconciles to its reported total")
        expect(gemini.tokens.total == 1075 && gemini.calls == 1, "Nothing is left unsplit when the total reconciles")

        // Kimi: one StatusUpdate per step; no model is recorded, so none is assumed.
        let status: [String: Any] = ["timestamp": 1_780_000_000.5, "message": ["type": "StatusUpdate", "payload": [
            "message_id": "k1", "context_tokens": 1100, "token_usage": ["input_other": 100, "input_cache_read": 900, "input_cache_creation": 100, "output": 40]]]]
        let kimi = KimiWireParser.call(from: status, fileID: "wire", line: 7)!
        expect(kimi.tokens == ModelTokenCounts(input: 100, cacheRead: 900, cacheWrite: 100, output: 40) && kimi.model == "Unknown model", "Kimi steps keep their split and no guessed model")
        expect(ModelRateCatalog.resolve(source: kimi.source, model: kimi.model) == nil, "An unnamed Kimi model stays unpriced")
        expect(KimiWireParser.call(from: ["timestamp": 1, "message": ["type": "TurnBegin", "payload": [:]]], fileID: "wire", line: 1) == nil, "Only StatusUpdate rows are usage")
        // Kimi Code: one usage.record per request, naming its route alias.
        let record: [String: Any] = ["type": "usage.record", "agentId": "main", "model": "kimi-code/k3", "usageScope": "turn", "time": 1_789_183_678_370,
            "usage": ["inputOther": 4645, "output": 499, "inputCacheRead": 18944, "inputCacheCreation": 0]]
        let kimiCode = KimiWireParser.call(from: record, fileID: "wire", line: 9)!
        expect(kimiCode.tokens == ModelTokenCounts(input: 4645, cacheRead: 18944, output: 499) && kimiCode.model == "kimi-code/k3", "Kimi Code records keep their split and model")
        close(kimiCode.timestamp.timeIntervalSince1970, 1_789_183_678.37, "Kimi Code times are milliseconds")
        expect(ModelRateCatalog.resolve(source: "kimi", model: "kimi-code/k3")?.model == "kimi-k3"
               && ModelRateCatalog.resolve(source: "kimi", model: "kimi-code/kimi-for-coding")?.model == "kimi-k2.8-preview"
               && ModelRateCatalog.resolve(source: "kimi", model: "kimi-code/k4") == nil, "Kimi Code aliases price explicitly and nothing else")
        expect(KimiWireParser.call(from: record, fileID: "wire", line: 9)?.id == kimiCode.id && KimiWireParser.call(from: record, fileID: "wire", line: 10)?.id != kimiCode.id,
               "A Kimi Code record's identity is its file and line")
        var cumulative = record; cumulative["usageScope"] = "session"
        expect(KimiWireParser.call(from: cumulative, fileID: "wire", line: 11) == nil, "Unknown usage scopes are never summed")

        // Grants: each shape provider setup stores resolves to the right log folder.
        let home = try temporaryDirectory("native-logs")
        defer { try? FileManager.default.removeItem(at: home) }
        try write(["sessionId": "s", "turns": [turn]], to: home.appendingPathComponent(".grok/sessions/p/s/usage.json"))
        try write(["x": 1], to: home.appendingPathComponent(".grok/sessions/p/s/other.json"))
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".grok/bin"), withIntermediateDirectories: true)
        try Data().write(to: home.appendingPathComponent(".grok/bin/grok"))
        try write(["sessionId": "c", "messages": [message, message]], to: home.appendingPathComponent(".gemini/tmp/project/chats/session-1.json"))
        var subagent = message; subagent["id"] = "g2"
        try write(["kind": "subagent", "messages": [subagent]], to: home.appendingPathComponent(".gemini/tmp/project/chats/0b1c/agent.json"))
        let jsonl = [["sessionId": "c", "kind": "main"], message, ["$set": ["summary": "x"]]].map {
            String(decoding: try! JSONSerialization.data(withJSONObject: $0), as: UTF8.self)
        }.joined(separator: "\n")
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".gemini/tmp/project2/chats"), withIntermediateDirectories: true)
        try jsonl.write(to: home.appendingPathComponent(".gemini/tmp/project2/chats/session-2.jsonl"), atomically: true, encoding: .utf8)
        try write(["not": "a chat"], to: home.appendingPathComponent(".gemini/tmp/project/logs.json"))
        let wire = String(decoding: try JSONSerialization.data(withJSONObject: status), as: UTF8.self)
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".kimi/sessions/h/u"), withIntermediateDirectories: true)
        try "{\"type\":\"metadata\",\"protocol_version\":1}\n\(wire)\n".write(to: home.appendingPathComponent(".kimi/sessions/h/u/wire.jsonl"), atomically: true, encoding: .utf8)
        try write(["access_token": "never read"], to: home.appendingPathComponent(".kimi/credentials/kimi-code.json"))
        let recordLine = String(decoding: try JSONSerialization.data(withJSONObject: record), as: UTF8.self)
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".kimi-code/sessions/wd_x/session_1/agents/main"), withIntermediateDirectories: true)
        try "{\"type\":\"metadata\",\"protocol_version\":\"1.5\"}\n\(recordLine)\n\(recordLine)\n".write(
            to: home.appendingPathComponent(".kimi-code/sessions/wd_x/session_1/agents/main/wire.jsonl"), atomically: true, encoding: .utf8)

        var failed = 0
        for grant in [".grok", ".grok/bin", ".grok/bin/grok"] {
            let files = ModelUsageLogScanner.logFiles(for: .grok, root: home.appendingPathComponent(grant), failed: &failed)
            expect(files.map { $0.0.lastPathComponent } == ["usage.json"], "Grok grant \(grant) finds session usage only")
        }
        expect(ModelUsageLogScanner.logFiles(for: .gemini, root: home.appendingPathComponent(".gemini"), failed: &failed).count == 3, "Gemini reads chats and subagent chats only, in both formats")
        for grant in [".kimi", ".kimi/credentials", ".kimi/credentials/kimi-code.json", ".kimi-code"] {
            let files = ModelUsageLogScanner.logFiles(for: .kimi, root: home.appendingPathComponent(grant), failed: &failed)
            expect(files.map { $0.0.lastPathComponent } == ["wire.jsonl"], "Kimi grant \(grant) finds wire logs")
        }
        let now = date("2026-09-24T12:00:00Z")
        let scanner = ModelUsageLogScanner(directory: home.appendingPathComponent("ledger"))
        let archive = try await scanner.scan(roots: [.grok: home.appendingPathComponent(".grok/bin"), .gemini: home.appendingPathComponent(".gemini"),
                                                     .kimi: home.appendingPathComponent(".kimi/credentials/kimi-code.json")], now: now)
        func requests(_ source: String) -> Int { ModelUsageTotals(archive.buckets.filter { $0.source == source }).requests }
        expect(requests("grok") == 3, "Grok model calls weigh its requests")
        expect(requests("gemini") == 2, "A Gemini message repeated within and across chat files counts once")
        expect(requests("kimi") == 1 && failed == 0, "Kimi steps are indexed")
        let kimiCodeArchive = try await ModelUsageLogScanner(directory: home.appendingPathComponent("ledger-kimi-code"))
            .scan(roots: [.kimi: home.appendingPathComponent(".kimi-code")], now: now)
        let kimiCodeRows = kimiCodeArchive.buckets.filter { $0.source == "kimi" }
        expect(ModelUsageTotals(kimiCodeRows).requests == 2 && kimiCodeRows.allSatisfy { $0.pricedRequests == $0.requests },
               "Each Kimi Code request line counts and prices through its alias")
        let grokRows = archive.buckets.filter { $0.source == "grok" }
        expect(grokRows.allSatisfy { $0.pricedRequests > 0 }, "Grok Build ids price through their explicit aliases")
    }

    static func claudeLine(_ stamp: String, request: String) -> String {
        #"{"timestamp":"\#(stamp)","requestId":"\#(request)","message":{"id":"m-\#(request)","model":"claude-opus-5-5","usage":{"input_tokens":100,"output_tokens":40}}}"# + "\n"
    }

    static func unchangedRefreshSkipsRollups() async throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("model-usage-refresh-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let root = temporary.appendingPathComponent("claude")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("projects"), withIntermediateDirectories: true)
        let log = root.appendingPathComponent("projects/session.jsonl")
        let start = date("2026-06-01T12:00:00Z")
        try claudeLine("2026-06-01T12:00:00Z", request: "a").write(to: log, atomically: true, encoding: .utf8)
        let storage = temporary.appendingPathComponent("scanner")
        let scanner = ModelUsageLogScanner(directory: storage)
        func expectPasses(_ count: Int, _ condition: Bool, _ message: String) async {
            let passes = await scanner.rollupPasses
            expect(passes == count && condition, message)
        }

        let now = start.addingTimeInterval(86400)
        let first = try await scanner.scan(roots: [.claude: root], now: now)
        await expectPasses(1, first.buckets.first?.seconds == 300, "First scan builds rollups")
        let second = try await scanner.scan(roots: [.claude: root], now: now.addingTimeInterval(300))
        await expectPasses(1, true, "An unchanged refresh skips prune and rollups")
        expect(second == first, "…and returns the saved archive untouched")

        let sameDay = start.addingTimeInterval(ModelUsageAggregation.fineResolutionAge + 60)
        let held = try await scanner.scan(roots: [.claude: root], now: sameDay)
        await expectPasses(2, held.buckets.first?.seconds == 300, "A call just past 90 days keeps five-minute precision until midnight")
        _ = try await scanner.scan(roots: [.claude: root], now: sameDay.addingTimeInterval(300))
        await expectPasses(2, true, "…so later refreshes that day skip rollups")
        let resolution = start.addingTimeInterval(ModelUsageAggregation.fineResolutionAge + 86400)
        let coarse = try await scanner.scan(roots: [.claude: root], now: resolution)
        await expectPasses(3, coarse.buckets.first?.seconds == 3600, "The next day's horizon rebuilds rollups at hourly resolution")
        _ = try await scanner.scan(roots: [.claude: root], now: resolution.addingTimeInterval(300))
        await expectPasses(3, true, "…then refreshes are steady again")

        let handle = try FileHandle(forWritingTo: log)
        try handle.seekToEnd(); try handle.write(contentsOf: Data(claudeLine("2026-08-15T12:00:00Z", request: "b").utf8)); try handle.close()
        let grown = try await scanner.scan(roots: [.claude: root], now: resolution.addingTimeInterval(600))
        await expectPasses(4, ModelUsageTotals(grown.buckets).requests == 2, "A changed log rebuilds rollups")

        try ModelUsageArchiveStore.save(ModelUsageArchive(generatedAt: resolution), to: storage)
        let restored = try await scanner.scan(roots: [.claude: root], now: resolution.addingTimeInterval(900))
        await expectPasses(5, ModelUsageTotals(restored.buckets).requests == 2, "A replaced archive is never trusted as current")

        let expiry = start.addingTimeInterval(ModelUsageAggregation.retention + 86400)
        let expired = try await scanner.scan(roots: [.claude: root], now: expiry)
        await expectPasses(6, ModelUsageTotals(expired.buckets).requests == 1, "Leaving retention rebuilds rollups")

        let handleFuture = try FileHandle(forWritingTo: log)
        try handleFuture.seekToEnd()
        try handleFuture.write(contentsOf: Data(claudeLine("2027-06-03T13:00:00Z", request: "c").utf8)); try handleFuture.close()
        let early = try await scanner.scan(roots: [.claude: root], now: date("2027-06-03T12:02:00Z"))
        await expectPasses(7, ModelUsageTotals(early.buckets).requests == 1, "A future call is excluded until its time")
        _ = try await scanner.scan(roots: [.claude: root], now: date("2027-06-03T12:30:00Z"))
        await expectPasses(7, true, "Waiting for it does not rebuild")
        let arrived = try await scanner.scan(roots: [.claude: root], now: date("2027-06-03T13:00:30Z"))
        await expectPasses(8, ModelUsageTotals(arrived.buckets).requests == 2, "Its arrival rebuilds rollups")
    }

    /// A changed log rebuilds rollups only from the UTC day its earliest changed call
    /// reaches; after every change the result must equal a full rollup of the same logs.
    static func changedDayRollups() async throws {
        let directory = try temporaryDirectory("changed-day")
        defer { try? FileManager.default.removeItem(at: directory) }
        let claude = directory.appendingPathComponent("claude"), projects = claude.appendingPathComponent("projects")
        let taskwraith = directory.appendingPathComponent("taskwraith")
        for folder in [projects, taskwraith] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        func line(_ stamp: String, _ request: String, output: Int = 40) -> String {
            #"{"timestamp":"\#(stamp)","requestId":"\#(request)","message":{"id":"m-\#(request)","model":"claude-opus-5-5","usage":{"input_tokens":100,"output_tokens":\#(output)}}}"# + "\n"
        }
        var modified = date("2026-06-06T00:00:00Z")
        func write(_ data: Data, to url: URL) throws {
            try data.write(to: url)
            modified = modified.addingTimeInterval(10)   // every rewrite is seen as a change
            try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
        }
        func log(_ name: String, _ lines: [String]) throws { try write(Data(lines.joined().utf8), to: projects.appendingPathComponent(name)) }
        func runs(_ output: Double = 20) throws {
            let records = [("r1", "2026-06-01T12:00:00Z", 20.0), ("r2", "2026-06-02T12:00:00Z", output), ("r3", "2026-06-03T12:00:00Z", 20)].map {
                taskWraithRecord($0.0, provider: "claude", model: "claude-opus-5-5", output: $0.2, extra: ["timestamp": date($0.1).timeIntervalSince1970 * 1000])
            }
            try write(try JSONSerialization.data(withJSONObject: records), to: taskwraith.appendingPathComponent("usage.json"))
        }
        let roots: [LocalModelUsageSource: URL] = [.claude: claude, .taskwraith: taskwraith]
        let scanner = ModelUsageLogScanner(directory: directory.appendingPathComponent("ledger"))
        var step = 0.0
        func matchesFullRollup(passes: Int, from day: String?, runs: Int, _ message: String) async throws {
            step += 1
            let now = date("2026-06-06T12:00:00Z").addingTimeInterval(step * 60)
            let archive = try await scanner.scan(roots: roots, now: now)
            let full = try await ModelUsageLogScanner(directory: directory.appendingPathComponent("full-\(Int(step))")).scan(roots: roots, now: now)
            let count = await scanner.rollupPasses, rebuilt = await scanner.rebuiltFrom
            expect(archive.buckets == full.buckets && count == passes && rebuilt == day.map(date)
                   && ModelUsageTotals(archive.buckets.filter { $0.source == "taskwraith" }).runs == runs, message)
        }

        try runs()
        try log("a.jsonl", [line("2026-06-03T10:00:00Z", "a"), line("2026-06-04T10:00:00Z", "b")])
        try log("b.jsonl", [line("2026-06-04T09:00:00Z", "b", output: 30)])
        try await matchesFullRollup(passes: 1, from: nil, runs: 2, "A first scan rolls up everything; runs before the transcripts begin are kept")
        try log("a.jsonl", [line("2026-06-03T10:00:00Z", "a"), line("2026-06-04T10:00:00Z", "b"), line("2026-06-05T10:00:00Z", "c")])
        try await matchesFullRollup(passes: 2, from: "2026-06-05T00:00:00Z", runs: 2, "A new call rebuilds from its own day")
        try log("b.jsonl", [line("2026-06-04T09:00:00Z", "b", output: 50)])
        try await matchesFullRollup(passes: 3, from: "2026-06-04T00:00:00Z", runs: 2, "A copy that becomes the winner rebuilds from its first copy's day")
        try log("c.jsonl", [line("2026-06-02T08:00:00Z", "d")])
        try await matchesFullRollup(passes: 4, from: "2026-06-02T00:00:00Z", runs: 1, "An earlier transcript call lowers the watermark and drops the run it now covers")
        try log("c.jsonl", [line("2026-06-02T14:00:00Z", "d")])
        try await matchesFullRollup(passes: 5, from: "2026-06-02T00:00:00Z", runs: 2, "A watermark that rises restores the run")
        try log("a.jsonl", [line("2026-06-03T10:00:00Z", "a"), line("2026-06-04T10:00:00Z", "b"), line("2026-06-05T10:00:00Z", "c"),
                            #"{"type":"user","timestamp":"2026-06-06T11:00:00Z"}"# + "\n"])
        try await matchesFullRollup(passes: 5, from: "2026-06-02T00:00:00Z", runs: 2, "A log that grows without calls reuses every bucket")
        try runs(25)
        try await matchesFullRollup(passes: 6, from: "2026-06-02T00:00:00Z", runs: 2, "A changed run record rebuilds from its day")
    }

    static func pricingBounds() throws {
        let sol = ModelRateCatalog.resolve(source: "codex", model: "gpt-6-sol")!
        let below = ModelTokenCounts(input: 271_999, output: 1000)
        let above = ModelTokenCounts(input: 300_000, output: 100)
        let single = sol.costRange(below, calls: 1)!
        expect(single.exact && single.low == sol.estimate(below), "A single call below the threshold is exact")
        close(sol.costRange(above, calls: 1)?.low, 1.2015, "A single long prompt bills every token at the long tier")
        let aggregateBelow = sol.costRange(below, calls: 0)!
        expect(aggregateBelow.exact, "An aggregate below the threshold proves every call was below it")
        let aggregateAbove = sol.costRange(above, calls: 0)!
        expect(!aggregateAbove.exact, "An aggregate above the threshold cannot select a tier")
        close(aggregateAbove.low, 0.601, "Range floor prices every call at the base tier")
        close(aggregateAbove.high, 1.2015, "Range ceiling prices every call at the long tier")
        expect(sol.costRange(above, calls: 3)?.exact == false, "Several known calls still cannot select a tier")
        expect(sol.estimate(ModelTokenCounts(input: 300_000, output: 100, unsplit: 5)) == nil, "Estimate refuses a split it does not know")

        let grok45 = ModelRateCatalog.resolve(source: "grok", model: "grok-4.5")!
        let totalOnly = grok45.costRange(ModelTokenCounts(unsplit: 1_000_000), calls: 0)!
        expect(!totalOnly.exact, "Total-only tokens are never one figure")
        close(totalOnly.low, 0.5, "Total-only floor is the cheapest category")
        close(totalOnly.high, 6, "Total-only ceiling is the dearest category")
        let grok46 = ModelRateCatalog.resolve(source: "grok", model: "grok-4.6")!
        let straddle = grok46.costRange(ModelTokenCounts(input: 150_000, unsplit: 60_000), calls: 1)!
        close(straddle.low, 0.3 + 0.03, "Unsplit tokens that may reach the threshold keep the base floor")
        close(straddle.high, 0.6 + 0.72, "…and the long-tier ceiling")
        let free = ModelRateCatalog.resolve(source: "codex", model: "openrouter/stealth/space-bunny-alpha")!
        expect(free.costRange(ModelTokenCounts(unsplit: 5000), calls: 0) == ModelCostRange(low: 0, high: 0, exact: true), "Free routes stay exactly free")
        expect(ModelRateCatalog.costRange(source: "codex", model: "unknown-model", tokens: below, calls: 1) == nil, "Unknown model has no fallback")
        expect(ModelRateCatalog.costRange(source: "codex", model: "ollama/qwen3.5:4b", tokens: below, calls: 1) == nil, "Local inference is not an API charge")
        expect(ModelRateCatalog.costRange(source: "codex", model: "qwen-token-plan/qwen3.8-max", tokens: below, calls: 1) == nil, "Subscription rows stay unpriced")

        expect(ModelRateCatalog.resolve(source: "grok", model: "grok-4.6-build")?.model == "grok-4.6", "Grok Build wire id maps to its catalog model")
        expect(ModelRateCatalog.resolve(source: "taskwraith", model: "grok/grok-4.7-build")?.model == "grok-4.7", "Namespaced Build id maps too")
        expect(ModelRateCatalog.resolve(source: "grok", model: "grok-4.8-build") == nil, "Only listed Build ids are aliased")
        expect(ModelRateCatalog.resolve(source: "taskwraith", model: "pi/deepseek/deepseek-v4-flash")?.provider == "pi", "Pi routes price with Pi rows")
        expect(ModelRateCatalog.resolve(source: "taskwraith", model: "cursor/grok-4.6")?.provider == "cursor", "Cursor routes price with Cursor rows")
        expect(ModelRateCatalog.resolve(source: "taskwraith", model: "devin/swe-1-6-slow") == nil, "Uncatalogued providers stay unpriced")
        expect(ModelRateCatalog.resolve(source: "taskwraith", model: "antigravity/gemini-3.1-pro-high") == nil, "Near-miss ids are not guessed")
        expect(ModelUsageDisplayIdentity.provider(model: "pi/deepseek/deepseek-v4-flash", source: "taskwraith") == "deepseek", "Pi route colours by vendor")

        expect(ModelRateCatalog.fingerprint == ModelRateCatalog.fingerprint(of: ModelRateCatalog.rates), "Fingerprint is deterministic")
        var edited = ModelRateCatalog.rates
        edited[0].output += 0.01
        expect(ModelRateCatalog.fingerprint(of: edited) != ModelRateCatalog.fingerprint, "A rate edit changes the fingerprint")
        expect(ModelRateCatalog.revision.hasPrefix(ModelRateCatalog.version + "#"), "Revision carries the dated catalog")
    }

    static func aggregationPricesEachRecord() throws {
        let now = date("2026-09-24T12:00:00Z")
        let at = now.addingTimeInterval(-600)
        var rows: [String: ModelUsageRollup] = [:]
        var rates: [String: ModelRate?] = [:]
        // Two 150K calls in one bucket: 300K together, yet neither call reached 200K.
        for index in 0..<2 {
            ModelUsageAggregation.add(ModelUsageCall(id: "\(index)", source: "grok", timestamp: at, model: "grok-4.6",
                tokens: .init(input: 150_000, output: 1000)), now: now, into: &rows, rates: &rates)
        }
        var totals = ModelUsageTotals(Array(rows.values))
        close(totals.estimatedUSD, 2 * (0.3 + 0.006), "Bucket totals never trigger a per-prompt tier")
        expect(totals.rangedTokens == 0 && totals.requests == 2, "Per-call records stay exact")

        ModelUsageAggregation.add(ModelUsageCall(id: "run", source: "taskwraith", timestamp: at, model: "grok/grok-4.6",
            tokens: .init(input: 250_000, output: 1000), calls: 0), now: now, into: &rows, rates: &rates)
        ModelUsageAggregation.add(ModelUsageCall(id: "turn", source: "grok", timestamp: at, model: "grok-4.6-build",
            tokens: .init(input: 10_000, output: 500), calls: 3), now: now, into: &rows, rates: &rates)
        ModelUsageAggregation.add(ModelUsageCall(id: "guess", source: "taskwraith", timestamp: at, model: "mistral/mistral-medium-3.5",
            tokens: .init(input: 4000, output: 1000), calls: 0, inferred: true), now: now, into: &rows, rates: &rates)
        totals = ModelUsageTotals(Array(rows.values))
        close(totals.rangeLowUSD, 0.5 + 0.006, "A run over the threshold is bounded below by the base tier")
        close(totals.rangeHighUSD, 1.0 + 0.012, "…and above by the long tier")
        expect(totals.runs == 2 && totals.requests == 2 + 1 + 3 + 1, "Known call counts weigh requests; runs count once")
        let inferred = rows.values.filter(\.inferred)
        expect(inferred.count == 1 && inferred[0].id.hasSuffix("|inferred"), "Estimated counts never share a measured row")
        close(inferred[0].estimatedUSD, (4000 * 1.5 + 1000 * 7.5) / 1_000_000, "Inferred counts still price at catalog rates, labelled as inferred")
        let rateModelled = ModelUsageCall(id: "r", source: "taskwraith", timestamp: at, model: "kimi/kimi-k2.7-code",
            tokens: .init(input: 1_000_000), rateModel: "kimi/kimi-k2.7-code-highspeed", calls: 0)
        var single: [String: ModelUsageRollup] = [:]
        ModelUsageAggregation.add(rateModelled, now: now, into: &single, rates: &rates)
        close(single.values.first?.estimatedUSD, 1.9, "A recorded cost-rate model prices the record")
        expect(single.values.first?.model == "kimi/kimi-k2.7-code", "…while the display model is kept")
    }

    static func schemaCompatibility() throws {
        let oldCall = #"{"id":"a","model":"gpt-6-sol","source":"codex","timestamp":811947078.099,"tokens":{"cacheRead":1,"cacheWrite":0,"input":2,"output":3,"reasoning":0}}"#
        let call = try JSONDecoder().decode(ModelUsageCall.self, from: Data(oldCall.utf8))
        expect(call.calls == 1 && !call.inferred && call.rateModel == nil && call.tokens.unsplit == 0, "Schema 1 ledger payloads keep their meaning")
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let reencoded = String(decoding: try encoder.encode(call), as: UTF8.self)
        expect(reencoded == oldCall, "A per-call payload encodes exactly as before")
        let run = ModelUsageCall(id: "b", source: "taskwraith", timestamp: Date(timeIntervalSinceReferenceDate: 0), model: "kimi/k",
            tokens: .init(unsplit: 5), rateModel: "kimi/kimi-k3", calls: 0, inferred: true)
        let decodedRun = try JSONDecoder().decode(ModelUsageCall.self, from: try encoder.encode(run))
        expect(decodedRun.calls == 0 && decodedRun.inferred && decodedRun.rateModel == "kimi/kimi-k3" && decodedRun.tokens.unsplit == 5, "New fields round trip")

        let now = date("2026-09-24T12:00:00Z")
        let measured = ModelUsageRollup(source: "codex", model: "gpt-6-sol", start: now, seconds: 300, tokens: .init(input: 10), requests: 1)
        let rowJSON = String(decoding: try encoder.encode(measured), as: UTF8.self)
        expect(!["\"i\"", "\"r\"", "\"lo\"", "\"hi\"", "\"rt\"", "unsplit"].contains { rowJSON.contains($0) }, "Split-only rows add no schema 2 keys")
        var ranged = measured; ranged.source = "taskwraith"; ranged.inferred = true; ranged.runs = 1
        ranged.rangeLowUSD = 1; ranged.rangeHighUSD = 2; ranged.rangedTokens = 10
        let rangedCopy = try JSONDecoder().decode(ModelUsageRollup.self, from: try encoder.encode(ranged))
        expect(rangedCopy == ranged, "Schema 2 rows round trip")

        let archive = ModelUsageArchive(generatedAt: now, buckets: [measured, ranged],
            coverage: [.init(source: "codex", scannedAt: now, files: 1, unreadableFiles: 0, malformedLines: 0, status: "ok"),
                       .init(source: "taskwraith", scannedAt: now, files: 1, unreadableFiles: 0, malformedLines: 0, status: "ok")])
        expect(archive.version == 2 && archive.rateVersion == ModelRateCatalog.revision, "New archives are schema 2 with the rate revision")
        let legacy = archive.legacySubset
        expect(legacy.version == 1 && legacy.buckets == [measured] && legacy.coverage.map(\.source) == ["codex"], "Legacy copy keeps only sources schema 1 can attribute")
        let legacyJSON = String(decoding: try encoder.encode(legacy), as: UTF8.self)
        expect(!legacyJSON.contains("taskwraith") && !legacyJSON.contains("\"lo\""), "Legacy copy carries no schema 2 content")
        let legacyCopy = try ModelUsageArchive.decodeCloud(try legacy.cloudEncoded())
        expect(legacyCopy == legacy, "Schema 1 archives still decode")
        var future = archive; future.version = 3
        do { _ = try future.validated(); fatalError("Unknown schema accepted") } catch {}
        var invalid = archive; invalid.buckets[1].rangeLowUSD = 3
        do { _ = try invalid.validated(); fatalError("Inverted range accepted") } catch {}

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("model-usage-source-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try encoder.encode(legacy).write(to: directory.appendingPathComponent("rollups-v1.json"))
        expect(ModelUsageArchiveStore.load(from: directory) == legacy, "A schema 1 file still loads after upgrade")
        try ModelUsageArchiveStore.save(archive, to: directory)
        expect(ModelUsageArchiveStore.load(from: directory) == archive, "The schema 2 file wins once written")
        expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("rollups-v1.json").path), "Schema 1 file is left for older builds")
    }

    static func snapshotInsights() throws {
        let now = date("2026-09-24T12:00:00Z")
        let aggregate = UsageAnalyticsBucket(startDate: now.addingTimeInterval(-86400), endDate: now,
            model: "gpt-6-sol", inputTokens: 300_000, outputTokens: 100, requests: 5, source: .officialAPI)
        let estimated = UsageAnalyticsBucket(startDate: now.addingTimeInterval(-86400), endDate: now,
            model: "mistral-medium-3.5", inputTokens: 10_000, outputTokens: 1000, requests: 5, costUSD: 0.5,
            source: .localEstimate, note: "TaskWraith-style chars÷4 × catalogue")
        let data = ModelUsageInsightData(archive: .empty, snapshots: [
            QuotaSnapshot(providerID: .openaiAPI, displayName: "API", windows: [], analyticsBuckets: [aggregate]),
            QuotaSnapshot(providerID: .mistral, displayName: "Mistral", windows: [], analyticsBuckets: [estimated])
        ])
        let api = ModelUsageInsightTotals(data.selected(source: "openaiAPI:officialAPI", window: .day, now: now))
        expect(api.estimatedUSD == nil && api.rangedTokens == 300_100, "An aggregate over the threshold is bounded, not guessed")
        close(api.estimateBounds?.lowerBound, 0.601, "Bounds start at the base tier")
        close(api.estimateBounds?.upperBound, 1.2015, "Bounds end at the long tier")
        expect(ModelUsageFormat.estimate(api).contains("–"), "A bounded estimate reads as a range")
        let mistral = ModelUsageInsightTotals(data.selected(source: "mistral:localEstimate", window: .day, now: now))
        expect(mistral.inferredTokens == 11_000 && mistral.measuredTokens == 0, "Character-length counts are marked inferred")
        expect(mistral.reportedEstimateUSD == 0.5 && mistral.actualUSD == nil, "A card's own estimate is never billed spend")
        expect(ModelUsageTokenBasis.isInferred(note: "Catalogue × Vibe session tokens") == false, "Vendor-reported session tokens stay measured")

        // Card events carry totals only: unsplit tokens, priced as a range, unless a ledger covers the provider.
        let hour = date("2026-09-24T11:00:00Z")
        let events = [UsageEvent(timestamp: hour.addingTimeInterval(60), tokens: 600_000, model: "gemini-3.1-pro-preview"),
                      UsageEvent(timestamp: hour.addingTimeInterval(60), tokens: 600_000, model: "gemini-3.1-pro-preview"),
                      UsageEvent(timestamp: hour.addingTimeInterval(120), tokens: 400_000, model: "gemini-3.1-pro-preview"),
                      UsageEvent(timestamp: hour.addingTimeInterval(180), tokens: nil, model: "gemini-3.1-pro-preview", type: .activity)]
        let card = QuotaSnapshot(providerID: .gemini, displayName: "Gemini", events: events)
        let cardData = ModelUsageInsightData(archive: .empty, snapshots: [card, card])
        let activity = ModelUsageInsightTotals(cardData.selected(source: "gemini:events", window: .hour, now: now))
        expect(activity.tokens.unsplit == 1_000_000 && activity.tokens.prompt == 0 && activity.requests == 2,
               "A re-appended or repeated card event counts once, as unsplit tokens")
        expect(activity.estimatedUSD == nil && activity.rangedTokens == 1_000_000, "Card totals are priced only as a range")
        close(activity.estimateBounds?.lowerBound, 0.2, "The range starts at the cheapest token rate")
        close(activity.estimateBounds?.upperBound, 12, "The range ends at the dearest token rate")
        expect(cardData.sources.first { $0.id == "gemini:events" }?.title.hasSuffix("card activity") == true, "The source names where its totals came from")
        let ledger = ModelUsageArchive(generatedAt: now, buckets: [ModelUsageRollup(source: "gemini", model: "gemini-3.1-pro-preview",
            start: hour, seconds: 300, tokens: .init(input: 10), requests: 1)])
        expect(!ModelUsageInsightData(archive: ledger, snapshots: [card]).sources.contains { $0.id == "gemini:events" },
               "A native ledger supersedes the card's totals")
        let ranked = ModelUsageInsightData(archive: ledger, snapshots: [QuotaSnapshot(providerID: .mistral, displayName: "Mistral", windows: [],
            analyticsBuckets: [estimated])]).busiest(3, window: .day, now: now)
        expect(ranked.map(\.source.id) == ["mistral:localEstimate", "gemini"] && ranked.first?.totals.tokens.total == 11_000,
               "The summary lists the busiest sources first, not the first by name")
        let quiet = ModelUsageInsightData(archive: ModelUsageArchive(generatedAt: now, buckets: [ModelUsageRollup(source: "taskwraith", model: "grok/grok-4.6",
            start: hour, seconds: 300, tokens: .init(input: 10), requests: 2, runs: 2)]), snapshots: [])
        let runTotals = ModelUsageInsightTotals(quiet.selected(source: "taskwraith", window: .day, now: now))
        expect(runTotals.runs == 2 && ModelUsageFormat.requests(runTotals.requests, runs: runTotals.runs) == "2 runs"
               && ModelUsageFormat.requests(5, runs: 2) == "5 calls & runs" && ModelUsageFormat.requests(5, runs: 0) == "5 calls",
               "Whole runs are never labelled as calls")
        expect(TaskWraithProviderPalette.hex(for: "openai") == "#705AFF" && TaskWraithProviderPalette.hex(for: "codexTelemetry") == "#705AFF"
               && TaskWraithProviderPalette.hex(for: "Claude") == "#B16105" && TaskWraithProviderPalette.hex(for: "qwen") == "#8C52EF",
               "Provider ids and routed vendors take TaskWraith's accents, aliases included")
        expect(TaskWraithProviderPalette.hex(for: "taskwraith") == "#986781" && TaskWraithProviderPalette.hex(for: "heatmap") == nil,
               "Runs spanning providers wear the ensemble hue; unknown identities get no borrowed accent")
        let unnamed = QuotaSnapshot(providerID: .antigravity, displayName: "Antigravity", events: [UsageEvent(timestamp: hour, tokens: 5000, model: "gemini-api:x")])
        let unpriced = ModelUsageInsightTotals(ModelUsageInsightData(archive: .empty, snapshots: [unnamed]).selected(source: "antigravity:events", window: .day, now: now))
        expect(unpriced.tokens.unsplit == 5000 && unpriced.estimateBounds == nil, "An unknown model stays unpriced rather than borrowing a rate")
    }
}
