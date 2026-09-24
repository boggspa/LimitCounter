import Foundation

/// Disjoint token categories. Reasoning is a subset of output, never added to total.
/// `unsplit` tokens were measured but their category was not reported; they count
/// toward the total, yet support only a bounded cost range.
nonisolated struct ModelTokenCounts: Hashable, Sendable {
    var input: Double = 0
    var cacheRead: Double = 0
    var cacheWrite: Double = 0
    var output: Double = 0
    var reasoning: Double = 0
    var unsplit: Double = 0

    var prompt: Double { input + cacheRead + cacheWrite }
    var total: Double { prompt + output + unsplit }
    var isValid: Bool { [input, cacheRead, cacheWrite, output, reasoning, unsplit].allSatisfy { $0.isFinite && $0 >= 0 } }

    mutating func add(_ other: Self) {
        input += other.input; cacheRead += other.cacheRead; cacheWrite += other.cacheWrite
        output += other.output; reasoning += other.reasoning; unsplit += other.unsplit
    }
}

/// Split-only rows encode exactly as before, so older readers keep decoding them.
nonisolated extension ModelTokenCounts: Codable {
    private enum CodingKeys: String, CodingKey { case input, cacheRead, cacheWrite, output, reasoning, unsplit }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(input: try values.decode(Double.self, forKey: .input), cacheRead: try values.decode(Double.self, forKey: .cacheRead),
            cacheWrite: try values.decode(Double.self, forKey: .cacheWrite), output: try values.decode(Double.self, forKey: .output),
            reasoning: try values.decode(Double.self, forKey: .reasoning), unsplit: try values.decodeIfPresent(Double.self, forKey: .unsplit) ?? 0)
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(input, forKey: .input); try values.encode(cacheRead, forKey: .cacheRead)
        try values.encode(cacheWrite, forKey: .cacheWrite); try values.encode(output, forKey: .output)
        try values.encode(reasoning, forKey: .reasoning)
        if unsplit != 0 { try values.encode(unsplit, forKey: .unsplit) }
    }
}

nonisolated enum LocalModelUsageSource: String, CaseIterable, Codable, Sendable {
    case codex, claude, taskwraith, grok, gemini, kimi
    var title: String {
        switch self {
        case .codex: return "Codex"
        case .claude: return "Claude Code"
        case .taskwraith: return "TaskWraith"
        case .grok: return "Grok CLI"
        case .gemini: return "Gemini CLI"
        case .kimi: return "Kimi CLI"
        }
    }
}

/// Attribution for archive sources on every surface (dashboard, heatmap, iPhone).
/// A source that spans providers, or one this build does not know, claims none
/// rather than borrowing another provider's identity.
enum ModelUsageSourceIdentity {
    static func host(_ source: String) -> ProviderID? {
        switch source {
        case "codex": return .openai
        case "claude": return .claude
        case "grok": return .grok
        case "gemini": return .gemini
        case "kimi": return .kimi
        default: return nil
        }
    }

    static func title(_ source: String) -> String {
        switch source {
        case "codex": return "Codex local"
        case "claude": return "Claude Code local"
        case "grok": return "Grok CLI local"
        case "gemini": return "Gemini CLI local"
        case "kimi": return "Kimi CLI local"
        case "taskwraith": return "TaskWraith runs"
        default: return source
        }
    }

    static func detail(_ source: String, files: Int) -> String {
        switch source {
        case "codex", "claude": return "\(files) logs · request deduplication · up to 366 days"
        case "taskwraith": return "\(files) usage files · runs outside Codex and Claude transcripts · one record per run"
        default: return "\(files) CLI logs · provider-reported tokens · up to 366 days"
        }
    }

    /// The quota-card host whose total-only event copy a request ledger replaces on
    /// the activity heatmap. Other ledgers overlap cards in ways a swap would lose.
    static func replacedSnapshotHost(_ source: String) -> ProviderID? {
        switch source {
        case "codex": return .openai
        case "claude": return .claude
        default: return nil
        }
    }
}

/// Local-only normalized record. IDs are one-way hashes; no prompts, paths or credentials.
nonisolated struct ModelUsageCall: Sendable {
    var id: String
    var source: String
    var timestamp: Date
    var model: String
    var tokens: ModelTokenCounts
    /// Catalog identity used for pricing when it differs from the display model.
    var rateModel: String? = nil
    /// API calls this record covers; 0 when the source does not say (a whole agent run).
    var calls = 1
    /// Counts are a local estimate (for example characters ÷ 4), not provider-reported.
    var inferred = false
}

nonisolated extension ModelUsageCall: Codable {
    private enum CodingKeys: String, CodingKey { case id, source, timestamp, model, tokens, rateModel, calls, inferred }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: try values.decode(String.self, forKey: .id), source: try values.decode(String.self, forKey: .source),
            timestamp: try values.decode(Date.self, forKey: .timestamp), model: try values.decode(String.self, forKey: .model),
            tokens: try values.decode(ModelTokenCounts.self, forKey: .tokens),
            rateModel: try values.decodeIfPresent(String.self, forKey: .rateModel),
            calls: try values.decodeIfPresent(Int.self, forKey: .calls) ?? 1,
            inferred: try values.decodeIfPresent(Bool.self, forKey: .inferred) ?? false)
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id); try values.encode(source, forKey: .source)
        try values.encode(timestamp, forKey: .timestamp); try values.encode(model, forKey: .model)
        try values.encode(tokens, forKey: .tokens)
        try values.encodeIfPresent(rateModel, forKey: .rateModel)
        if calls != 1 { try values.encode(calls, forKey: .calls) }
        if inferred { try values.encode(inferred, forKey: .inferred) }
    }
}

nonisolated enum ModelUsageWindow: String, CaseIterable, Identifiable {
    case hour = "1H", day = "24H", week = "7D", month = "30D", quarter = "90D"
    var id: String { rawValue }
    var seconds: TimeInterval {
        switch self {
        case .hour: return 3600
        case .day: return 86400
        case .week: return 7 * 86400
        case .month: return 30 * 86400
        case .quarter: return 90 * 86400
        }
    }
}

/// Five-minute UTC buckets for 90 days, UTC hours for the remainder of the year.
/// Retaining hours (rather than local days) permits correct day bucketing after travel/DST.
/// Estimated token counts never share a row with measured ones.
nonisolated struct ModelUsageRollup: Hashable, Identifiable, Sendable {
    var source: String
    var model: String
    var start: Date
    var seconds: Int
    var inferred = false
    var tokens = ModelTokenCounts()
    /// API calls, plus one for each record whose call count was not reported.
    var requests: Int = 0
    /// Records whose call count was not reported, such as whole agent runs.
    var runs: Int = 0
    var estimatedUSD: Double = 0
    var pricedTokens: Double = 0
    var pricedRequests: Int = 0
    /// API-equivalent bounds for records whose token split or prompt tier is unknown.
    var rangeLowUSD: Double = 0
    var rangeHighUSD: Double = 0
    var rangedTokens: Double = 0
    var id: String { "\(source)|\(model)|\(start.timeIntervalSince1970)|\(seconds)\(inferred ? "|inferred" : "")" }
}

/// Short keys keep a year of rows compact. Fields added in schema 2 are omitted
/// while zero, so split-only request rows still read as schema 1.
nonisolated extension ModelUsageRollup: Codable {
    private enum CodingKeys: String, CodingKey {
        case source = "s", model = "m", start = "t", seconds = "d", tokens = "k"
        case requests = "n", estimatedUSD = "c", pricedTokens = "p", pricedRequests = "q"
        case inferred = "i", runs = "r", rangeLowUSD = "lo", rangeHighUSD = "hi", rangedTokens = "rt"
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(source: try values.decode(String.self, forKey: .source), model: try values.decode(String.self, forKey: .model),
            start: try values.decode(Date.self, forKey: .start), seconds: try values.decode(Int.self, forKey: .seconds),
            inferred: try values.decodeIfPresent(Bool.self, forKey: .inferred) ?? false,
            tokens: try values.decode(ModelTokenCounts.self, forKey: .tokens), requests: try values.decode(Int.self, forKey: .requests),
            runs: try values.decodeIfPresent(Int.self, forKey: .runs) ?? 0,
            estimatedUSD: try values.decode(Double.self, forKey: .estimatedUSD), pricedTokens: try values.decode(Double.self, forKey: .pricedTokens),
            pricedRequests: try values.decode(Int.self, forKey: .pricedRequests),
            rangeLowUSD: try values.decodeIfPresent(Double.self, forKey: .rangeLowUSD) ?? 0,
            rangeHighUSD: try values.decodeIfPresent(Double.self, forKey: .rangeHighUSD) ?? 0,
            rangedTokens: try values.decodeIfPresent(Double.self, forKey: .rangedTokens) ?? 0)
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(source, forKey: .source); try values.encode(model, forKey: .model)
        try values.encode(start, forKey: .start); try values.encode(seconds, forKey: .seconds)
        try values.encode(tokens, forKey: .tokens); try values.encode(requests, forKey: .requests)
        try values.encode(estimatedUSD, forKey: .estimatedUSD); try values.encode(pricedTokens, forKey: .pricedTokens)
        try values.encode(pricedRequests, forKey: .pricedRequests)
        if inferred { try values.encode(inferred, forKey: .inferred) }
        if runs != 0 { try values.encode(runs, forKey: .runs) }
        if rangedTokens != 0 || rangeHighUSD != 0 {
            try values.encode(rangeLowUSD, forKey: .rangeLowUSD); try values.encode(rangeHighUSD, forKey: .rangeHighUSD)
            try values.encode(rangedTokens, forKey: .rangedTokens)
        }
    }
}

nonisolated struct ModelUsageCoverage: Codable, Equatable, Sendable {
    var source: String
    var scannedAt: Date
    var firstEvent: Date?
    var lastEvent: Date?
    var files: Int
    var unreadableFiles: Int
    var malformedLines: Int
    var status: String
}

nonisolated struct ModelUsageArchive: Codable, Equatable, Sendable {
    /// Schema 2 adds unsplit/inferred rows, cost ranges and sources beyond Codex and Claude.
    static let schemaVersion = 2
    static let supportedVersions = 1...schemaVersion
    /// The only sources a schema 1 reader can attribute correctly.
    static let legacySources: Set<String> = ["codex", "claude"]
    var version = schemaVersion
    var rateVersion = ModelRateCatalog.revision
    var generatedAt = Date()
    var buckets: [ModelUsageRollup] = []
    var coverage: [ModelUsageCoverage] = []

    static let empty = ModelUsageArchive(generatedAt: .distantPast)
    var sources: [String] { Array(Set(buckets.map(\.source) + coverage.map(\.source))).sorted() }

    /// Schema 1 copy for builds that map every non-Codex source to Claude.
    var legacySubset: ModelUsageArchive {
        var copy = self
        copy.version = 1
        copy.buckets = buckets.filter { Self.legacySources.contains($0.source) && !$0.inferred }
        copy.coverage = coverage.filter { Self.legacySources.contains($0.source) }
        return copy
    }

    func hasSameContent(as other: Self) -> Bool {
        func stableCoverage(_ values: [ModelUsageCoverage]) -> [ModelUsageCoverage] {
            values.map { value in
                var copy = value; copy.scannedAt = .distantPast; return copy
            }.sorted { $0.source < $1.source }
        }
        return version == other.version && rateVersion == other.rateVersion && buckets == other.buckets
            && stableCoverage(coverage) == stableCoverage(other.coverage)
    }

    func selected(source: String, now: Date, window: ModelUsageWindow) -> [ModelUsageRollup] {
        // Include a boundary bucket as a whole; the UI discloses five-minute precision.
        let cutoff = now.addingTimeInterval(-window.seconds)
        return buckets.filter { $0.source == source && $0.start <= now && $0.start.addingTimeInterval(Double($0.seconds)) > cutoff }
    }

    func validated() throws -> Self {
        guard Self.supportedVersions.contains(version), buckets.count <= 500_000,
              buckets.allSatisfy({ row in
                  row.tokens.isValid && row.model.count <= 256 && row.source.count <= 80
                    && [300, 3600].contains(row.seconds) && row.requests >= 0
                    && row.runs >= 0 && row.runs <= row.requests
                    && row.pricedRequests >= 0 && row.pricedRequests <= row.requests
                    && row.estimatedUSD.isFinite && row.estimatedUSD >= 0
                    && row.pricedTokens.isFinite && row.pricedTokens >= 0
                    && row.rangedTokens.isFinite && row.rangedTokens >= 0
                    && row.pricedTokens + row.rangedTokens <= row.tokens.total + 0.001
                    && row.rangeLowUSD.isFinite && row.rangeHighUSD.isFinite && row.rangeLowUSD >= 0
                    && row.rangeLowUSD <= row.rangeHighUSD + 0.000001
              }) else { throw ModelUsageError.invalidArchive }
        return self
    }

    static func decode(_ data: Data) throws -> Self {
        guard data.count <= 80_000_000 else { throw ModelUsageError.invalidArchive }
        return try JSONDecoder().decode(Self.self, from: data).validated()
    }

    /// Versioned compressed transport for CKAsset, independent of quota payloads.
    func cloudEncoded() throws -> Data {
        _ = try validated()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(self)
        guard data.count <= 80_000_000 else { throw ModelUsageError.invalidArchive }
        var result = Data("LCMA1".utf8)
        result.append(try (data as NSData).compressed(using: .lzfse) as Data)
        return result
    }

    static func decodeCloud(_ data: Data) throws -> Self {
        guard data.count <= 80_000_000 else { throw ModelUsageError.invalidArchive }
        if data.prefix(5) == Data("LCMA1".utf8) {
            let inflated = try (Data(data.dropFirst(5)) as NSData).decompressed(using: .lzfse) as Data
            return try decode(inflated)
        }
        // Accept the uncompressed first-generation JSON representation too.
        return try decode(data)
    }
}

nonisolated enum ModelUsageError: LocalizedError {
    case invalidArchive, database(String), folderAccess, incompleteFile
    var errorDescription: String? {
        switch self {
        case .invalidArchive: return "The analytics archive is invalid or from an unsupported version."
        case .database(let message): return "Analytics storage: \(message)"
        case .folderAccess: return "Connect the local log folder in provider setup to backfill model usage."
        case .incompleteFile: return "A log changed during the scan; it will be retried on the next refresh."
        }
    }
}

nonisolated struct ModelUsageTotals {
    var tokens = ModelTokenCounts()
    var requests = 0
    var runs = 0
    var estimatedUSD: Double = 0
    var pricedTokens: Double = 0
    var pricedRequests = 0
    var rangeLowUSD: Double = 0
    var rangeHighUSD: Double = 0
    var rangedTokens: Double = 0
    var cacheShare: Double { tokens.prompt > 0 ? tokens.cacheRead / tokens.prompt : 0 }
    var priceCoverage: Double { tokens.total > 0 ? pricedTokens / tokens.total : 0 }
    var hasEstimate: Bool { pricedRequests > 0 }

    init(_ rows: [ModelUsageRollup] = []) {
        for row in rows {
            tokens.add(row.tokens); requests += row.requests; runs += row.runs; estimatedUSD += row.estimatedUSD
            pricedTokens += row.pricedTokens; pricedRequests += row.pricedRequests
            rangeLowUSD += row.rangeLowUSD; rangeHighUSD += row.rangeHighUSD; rangedTokens += row.rangedTokens
        }
    }
}

nonisolated struct ModelUsageDay: Identifiable {
    var date: Date
    var tokens: Double = 0
    var requests: Int = 0
    var runs: Int = 0
    var id: Date { date }
}

nonisolated enum ModelUsageCalendar {
    static func days(_ rows: [ModelUsageRollup], count: Int, now: Date, calendar: Calendar = .current) -> [ModelUsageDay] {
        let today = calendar.startOfDay(for: now)
        var totals: [Date: ModelUsageDay] = [:]
        for row in rows where row.start <= now {
            let day = calendar.startOfDay(for: row.start)
            var value = totals[day] ?? ModelUsageDay(date: day)
            value.tokens += row.tokens.total; value.requests += row.requests; value.runs += row.runs
            totals[day] = value
        }
        return (0..<count).reversed().compactMap { offset in
            guard let date = calendar.date(byAdding: .day, value: -offset, to: today) else { return nil }
            return totals[date] ?? ModelUsageDay(date: date)
        }
    }

    /// Local wall-clock hour determines the row; a repeated autumn hour lands in the same cell.
    static func twoHourIndex(_ date: Date, calendar: Calendar = .current) -> Int {
        calendar.component(.hour, from: date) / 2
    }

    static func streaks(_ days: [ModelUsageDay]) -> (current: Int, longest: Int) {
        var longest = 0, run = 0
        for day in days { run = day.tokens > 0 ? run + 1 : 0; longest = max(longest, run) }
        if days.last?.tokens == 0 {
            run = 0
            for day in days.dropLast().reversed() { guard day.tokens > 0 else { break }; run += 1 }
        }
        return (run, longest)
    }
}

nonisolated enum ModelUsageAggregation {
    /// Bump when bucketing, retention or pricing semantics change so cached rollups are rebuilt.
    static let version = 2
    static let fineResolutionAge: TimeInterval = 90 * 86400
    static let retention: TimeInterval = 366 * 86400

    /// Resolution and retention boundaries advance a whole UTC day at a time, so rollups
    /// stay constant between midnights unless the ledger changes or a future call arrives.
    static func dayStart(_ now: Date) -> Date { Date(timeIntervalSince1970: floor(now.timeIntervalSince1970 / 86400) * 86400) }
    static func retentionStart(_ now: Date) -> Date { dayStart(now).addingTimeInterval(-retention) }

    static func bucketStart(_ date: Date, now: Date) -> (Date, Int) {
        let seconds = date >= dayStart(now).addingTimeInterval(-fineResolutionAge) ? 300 : 3600
        return (Date(timeIntervalSince1970: floor(date.timeIntervalSince1970 / Double(seconds)) * Double(seconds)), seconds)
    }

    /// Each record is priced on its own before it joins a bucket, so an aggregate can
    /// never cross a per-prompt tier that none of its calls reached.
    static func add(_ call: ModelUsageCall, now: Date, into result: inout [String: ModelUsageRollup],
                    rates: inout [String: ModelRate?]) {
        guard call.tokens.isValid, call.tokens.total > 0, call.calls >= 0, call.timestamp <= now,
              call.timestamp >= retentionStart(now) else { return }
        let (start, seconds) = bucketStart(call.timestamp, now: now)
        var row = ModelUsageRollup(source: call.source, model: call.model, start: start, seconds: seconds, inferred: call.inferred)
        row = result[row.id] ?? row
        let weight = max(1, call.calls)
        row.tokens.add(call.tokens); row.requests += weight
        if call.calls == 0 { row.runs += 1 }
        // A pass meets each model thousands of times; resolve it once (misses included).
        let rateModel = call.rateModel ?? call.model, key = "\(call.source)|\(rateModel)"
        let rate: ModelRate?
        if let known = rates[key] { rate = known } else {
            rate = ModelRateCatalog.resolve(source: call.source, model: rateModel)
            rates[key] = rate
        }
        if let cost = rate?.costRange(call.tokens, calls: call.calls) {
            if cost.exact {
                row.estimatedUSD += cost.low; row.pricedTokens += call.tokens.total; row.pricedRequests += weight
            } else {
                row.rangeLowUSD += cost.low; row.rangeHighUSD += cost.high; row.rangedTokens += call.tokens.total
            }
        }
        result[row.id] = row
    }
}

/// Presentation only. Explicit routing namespaces may choose a vendor's colour,
/// while deduplication, pricing and accounting retain the original source.
nonisolated enum ModelUsageDisplayIdentity {
    static func provider(model: String?, source: String) -> String {
        let host = source.split(separator: ":", maxSplits: 1).first.map(String.init) ?? source
        let fallback = host == "codex" || host == "codexTelemetry" ? "openai" : host
        // Pi is a router: its namespace names the seat and the next one names the vendor.
        guard var model else { return fallback }
        if model.lowercased().hasPrefix("pi/") { model.removeFirst(3) }
        guard let slash = model.firstIndex(of: "/"),
              model.index(after: slash) < model.endIndex else { return fallback }
        let namespace = model[..<slash].lowercased()
        let known = [
            "codex": "openai", "openai": "openai", "claude": "claude", "anthropic": "claude",
            "grok": "grok", "xai": "grok", "mistral": "mistral", "deepseek": "deepseek",
            "gemini": "gemini", "google": "gemini", "kimi": "kimi", "moonshot": "kimi",
            "cursor": "cursor", "cerebras": "cerebras", "ollama": "ollama", "openrouter": "openrouter",
            "qwen": "qwen", "alibaba": "qwen", "meta": "meta", "muse": "meta",
            "antigravity": "antigravity", "devin": "devin", "mimo": "mimo", "xiaomi": "mimo"
        ]
        return known[namespace] ?? fallback
    }

    static func dominant(in rows: [ModelUsageRollup]) -> String? {
        var weights: [String: Double] = [:]
        for row in rows {
            weights[provider(model: row.model, source: row.source), default: 0] += row.tokens.total
        }
        return weights.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }.first?.key
    }
}
