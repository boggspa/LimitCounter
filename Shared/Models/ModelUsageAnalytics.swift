import Foundation

/// Disjoint token categories. Reasoning is a subset of output, never added to total.
nonisolated struct ModelTokenCounts: Codable, Hashable, Sendable {
    var input: Double = 0
    var cacheRead: Double = 0
    var cacheWrite: Double = 0
    var output: Double = 0
    var reasoning: Double = 0

    var prompt: Double { input + cacheRead + cacheWrite }
    var total: Double { prompt + output }
    var isValid: Bool { [input, cacheRead, cacheWrite, output, reasoning].allSatisfy { $0.isFinite && $0 >= 0 } }

    mutating func add(_ other: Self) {
        input += other.input; cacheRead += other.cacheRead; cacheWrite += other.cacheWrite
        output += other.output; reasoning += other.reasoning
    }
}

nonisolated enum LocalModelUsageSource: String, CaseIterable, Codable, Sendable {
    case codex, claude
    var title: String { self == .codex ? "Codex" : "Claude Code" }
}

/// Local-only normalized record. IDs are one-way hashes; no prompts, paths or credentials.
nonisolated struct ModelUsageCall: Codable, Sendable {
    var id: String
    var source: String
    var timestamp: Date
    var model: String
    var tokens: ModelTokenCounts
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
nonisolated struct ModelUsageRollup: Codable, Hashable, Identifiable, Sendable {
    var source: String
    var model: String
    var start: Date
    var seconds: Int
    var tokens = ModelTokenCounts()
    var requests: Int = 0
    var estimatedUSD: Double = 0
    var pricedTokens: Double = 0
    var pricedRequests: Int = 0
    var id: String { "\(source)|\(model)|\(start.timeIntervalSince1970)|\(seconds)" }

    enum CodingKeys: String, CodingKey {
        case source = "s", model = "m", start = "t", seconds = "d", tokens = "k"
        case requests = "n", estimatedUSD = "c", pricedTokens = "p", pricedRequests = "q"
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
    static let schemaVersion = 1
    var version = schemaVersion
    var rateVersion = ModelRateCatalog.version
    var generatedAt = Date()
    var buckets: [ModelUsageRollup] = []
    var coverage: [ModelUsageCoverage] = []

    static let empty = ModelUsageArchive(generatedAt: .distantPast)
    var sources: [String] { Array(Set(buckets.map(\.source) + coverage.map(\.source))).sorted() }

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
        guard version == Self.schemaVersion, buckets.count <= 500_000,
              buckets.allSatisfy({ row in
                  row.tokens.isValid && row.model.count <= 256 && row.source.count <= 80
                    && [300, 3600].contains(row.seconds) && row.requests >= 0
                    && row.pricedRequests >= 0 && row.pricedRequests <= row.requests
                    && row.estimatedUSD.isFinite && row.estimatedUSD >= 0
                    && row.pricedTokens.isFinite && row.pricedTokens >= 0
                    && row.pricedTokens <= row.tokens.total + 0.001
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
    var estimatedUSD: Double = 0
    var pricedTokens: Double = 0
    var pricedRequests = 0
    var cacheShare: Double { tokens.prompt > 0 ? tokens.cacheRead / tokens.prompt : 0 }
    var priceCoverage: Double { tokens.total > 0 ? pricedTokens / tokens.total : 0 }
    var hasEstimate: Bool { pricedRequests > 0 }

    init(_ rows: [ModelUsageRollup] = []) {
        for row in rows {
            tokens.add(row.tokens); requests += row.requests; estimatedUSD += row.estimatedUSD
            pricedTokens += row.pricedTokens; pricedRequests += row.pricedRequests
        }
    }
}

nonisolated struct ModelUsageDay: Identifiable {
    var date: Date
    var tokens: Double = 0
    var requests: Int = 0
    var id: Date { date }
}

nonisolated enum ModelUsageCalendar {
    static func days(_ rows: [ModelUsageRollup], count: Int, now: Date, calendar: Calendar = .current) -> [ModelUsageDay] {
        let today = calendar.startOfDay(for: now)
        var totals: [Date: ModelUsageDay] = [:]
        for row in rows where row.start <= now {
            let day = calendar.startOfDay(for: row.start)
            var value = totals[day] ?? ModelUsageDay(date: day)
            value.tokens += row.tokens.total; value.requests += row.requests
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
    static func bucketStart(_ date: Date, now: Date) -> (Date, Int) {
        let seconds = now.timeIntervalSince(date) <= 90 * 86400 ? 300 : 3600
        return (Date(timeIntervalSince1970: floor(date.timeIntervalSince1970 / Double(seconds)) * Double(seconds)), seconds)
    }

    static func add(_ call: ModelUsageCall, now: Date, into result: inout [String: ModelUsageRollup]) {
        guard call.tokens.isValid, call.tokens.total > 0, call.timestamp <= now,
              call.timestamp >= now.addingTimeInterval(-366 * 86400) else { return }
        let (start, seconds) = bucketStart(call.timestamp, now: now)
        var row = ModelUsageRollup(source: call.source, model: call.model, start: start, seconds: seconds)
        row = result[row.id] ?? row
        row.tokens.add(call.tokens); row.requests += 1
        if let estimate = ModelRateCatalog.estimate(source: call.source, model: call.model, tokens: call.tokens) {
            row.estimatedUSD += estimate; row.pricedTokens += call.tokens.total; row.pricedRequests += 1
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
        guard let model, let slash = model.firstIndex(of: "/"),
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
