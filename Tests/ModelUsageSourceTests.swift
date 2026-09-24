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
    }
}
