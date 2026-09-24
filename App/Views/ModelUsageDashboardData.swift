import Foundation

/// View data preserves source boundaries: local request ledgers never get added to
/// their own quota-card copies, and provider cost reports retain their own meaning.
struct ModelUsageInsightEntry: Identifiable {
    let id: String
    let source: String
    let provider: ProviderID
    let model: String
    let start: Date
    let end: Date
    let tokens: ModelTokenCounts
    let requests: Double
    let estimatedUSD: Double?
    let pricedTokens: Double
    let actualUSD: Double?
    let reportedEstimateUSD: Double?
    let precise: Bool
}

struct ModelUsageInsightSource: Identifiable {
    let id: String
    let provider: ProviderID
    let title: String
    let detail: String
    let first: Date?
    let last: Date?
    let scanned: Date?
    let local: Bool
    let issue: String?
}

struct ModelUsageInsightTotals {
    var tokens = ModelTokenCounts()
    var requests: Double = 0
    var estimatedUSD: Double?
    var actualUSD: Double?
    var reportedEstimateUSD: Double?
    var pricedTokens: Double = 0
    var cacheShare: Double { tokens.prompt > 0 ? tokens.cacheRead / tokens.prompt : 0 }
    var coverage: Double { tokens.total > 0 ? pricedTokens / tokens.total : 0 }

    init(_ entries: [ModelUsageInsightEntry]) {
        for entry in entries {
            tokens.add(entry.tokens); requests += entry.requests; pricedTokens += entry.pricedTokens
            if let cost = entry.estimatedUSD { estimatedUSD = (estimatedUSD ?? 0) + cost }
            if let cost = entry.actualUSD { actualUSD = (actualUSD ?? 0) + cost }
            if let cost = entry.reportedEstimateUSD { reportedEstimateUSD = (reportedEstimateUSD ?? 0) + cost }
        }
    }
}

struct ModelUsageInsightData {
    let sources: [ModelUsageInsightSource]
    let entries: [ModelUsageInsightEntry]

    init(archive: ModelUsageArchive, snapshots: [QuotaSnapshot]) {
        var sources: [ModelUsageInsightSource] = []
        var entries: [ModelUsageInsightEntry] = []
        let ledgerSources = Set(archive.buckets.map(\.source))
        for name in archive.sources {
            let provider: ProviderID = name == "codex" ? .openai : .claude
            let coverage = archive.coverage.first { $0.source == name }
            let rows = archive.buckets.filter { $0.source == name }
            let problems = coverage.map { $0.unreadableFiles + $0.malformedLines } ?? 0
            sources.append(.init(id: name, provider: provider, title: name == "codex" ? "Codex local" : "Claude Code local",
                detail: "\(coverage?.files ?? 0) logs · request deduplication · up to 365 days",
                first: coverage?.firstEvent ?? rows.map(\.start).min(), last: coverage?.lastEvent ?? rows.map(\.start).max(),
                scanned: coverage?.scannedAt, local: true,
                issue: problems > 0 ? "\(coverage?.unreadableFiles ?? 0) files deferred; \(coverage?.malformedLines ?? 0) malformed lines skipped" : nil))
            entries += rows.map { row in
                .init(id: row.id, source: name, provider: provider, model: row.model, start: row.start,
                    end: row.start.addingTimeInterval(Double(row.seconds)), tokens: row.tokens, requests: Double(row.requests),
                    estimatedUSD: row.pricedRequests > 0 ? row.estimatedUSD : nil, pricedTokens: row.pricedTokens,
                    actualUSD: nil, reportedEstimateUSD: nil, precise: true)
            }
        }
        var seen = Set<String>()
        for snapshot in snapshots {
            for bucket in snapshot.analyticsBuckets where bucket.hasUsage {
                if bucket.source != .officialAPI {
                    if ledgerSources.contains("codex"), snapshot.providerID == .openai || snapshot.providerID == .codexTelemetry { continue }
                    if ledgerSources.contains("claude"), snapshot.providerID == .claude { continue }
                }
                let source = "\(snapshot.providerID.rawValue):\(bucket.source.rawValue)"
                guard seen.insert("\(source):\(bucket.id)").inserted else { continue }
                let model = bucket.model ?? (bucket.totalTokens == 0 && bucket.costUSD != nil ? "Provider spend" : "Unknown model")
                let counts = ModelTokenCounts(input: max(0, bucket.inputTokens), cacheRead: max(0, bucket.cachedInputTokens), output: max(0, bucket.outputTokens))
                let provider = snapshot.providerID
                let rateProvider = provider == .meta ? "muse" : provider.rawValue
                let rate = ModelRateCatalog.resolve(source: rateProvider, model: model)
                // Aggregate buckets cannot reveal whether individual calls crossed a prompt tier.
                let estimate = counts.total > 0 && (rate?.threshold == nil || bucket.requests == 1) ? rate?.estimate(counts) : nil
                entries.append(.init(id: "\(source):\(bucket.id)", source: source, provider: provider, model: model,
                    start: bucket.startDate, end: bucket.endDate, tokens: counts, requests: bucket.requests,
                    estimatedUSD: estimate, pricedTokens: estimate == nil ? 0 : counts.total,
                    actualUSD: bucket.source == .officialAPI ? bucket.costUSD : nil,
                    reportedEstimateUSD: bucket.source == .localEstimate ? bucket.costUSD : nil, precise: false))
            }
        }
        for (id, rows) in Dictionary(grouping: entries.filter { !$0.precise }, by: \.source) {
            guard let row = rows.first else { continue }
            let official = id.hasSuffix(UsageAnalyticsSource.officialAPI.rawValue)
            let label = official ? "API report" : "provider history"
            sources.append(.init(id: id, provider: row.provider, title: "\(row.provider.displayName) · \(label)",
                detail: "Available provider buckets; retention and resolution vary",
                first: rows.map(\.start).min(), last: rows.map(\.end).max(),
                scanned: snapshots.first { $0.providerID == row.provider }?.fetchedAt, local: false, issue: nil))
        }
        self.sources = sources.sorted { $0.id < $1.id }
        self.entries = entries.sorted { $0.start < $1.start }
    }

    func selected(source: String, model: String = "", window: ModelUsageWindow, now: Date) -> [ModelUsageInsightEntry] {
        let cutoff = now.addingTimeInterval(-window.seconds)
        return entries.filter { row in
            (source.isEmpty || row.source == source) && (model.isEmpty || row.model == model)
                && row.start <= now && row.end > cutoff
                && (row.precise || row.end.timeIntervalSince(row.start) <= window.seconds)
        }
    }

    func chartRows(source: String, model: String = "") -> [ModelUsageRollup] {
        entries.filter { $0.source == source && (model.isEmpty || $0.model == model) && $0.tokens.total > 0 }.map {
            ModelUsageRollup(source: $0.source, model: $0.model, start: $0.start,
                seconds: max(1, Int($0.end.timeIntervalSince($0.start))), tokens: $0.tokens, requests: Int($0.requests))
        }
    }
}

enum ModelUsageFormat {
    static func tokens(_ value: Double) -> String {
        if value >= 1_000_000_000 { return String(format: "%.2fB", value / 1_000_000_000) }
        if value >= 1_000_000 { return String(format: "%.2fM", value / 1_000_000) }
        if value >= 1_000 { return String(format: "%.1fK", value / 1_000) }
        return value.formatted(.number.precision(.fractionLength(0)))
    }
    static func money(_ value: Double?) -> String {
        guard let value else { return "—" }
        return value.formatted(.currency(code: "USD").precision(.fractionLength(2)))
    }
    static func rate(_ value: Double?) -> String {
        guard let value else { return "—" }
        return value.formatted(.currency(code: "USD").precision(.fractionLength(0...6)))
    }
}
