import Foundation

/// View data preserves source boundaries: local request ledgers never get added to
/// their own quota-card copies, and provider cost reports retain their own meaning.
struct ModelUsageInsightEntry: Identifiable {
    let id: String
    let source: String
    /// Nil for sources that span providers, such as TaskWraith runs.
    let provider: ProviderID?
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
    /// API-equivalent bounds where the split or prompt tier is unknown; zero otherwise.
    var rangeLowUSD: Double = 0
    var rangeHighUSD: Double = 0
    var rangedTokens: Double = 0
    /// Token counts are a local estimate rather than provider-reported.
    var inferred = false
    /// Requests that are whole runs of unknown call count, such as TaskWraith runs.
    var runs: Double = 0
}

struct ModelUsageInsightSource: Identifiable {
    let id: String
    let provider: ProviderID?
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
    var inferredTokens: Double = 0
    var requests: Double = 0
    var runs: Double = 0
    var estimatedUSD: Double?
    var actualUSD: Double?
    var reportedEstimateUSD: Double?
    var pricedTokens: Double = 0
    var rangeLowUSD: Double = 0
    var rangeHighUSD: Double = 0
    var rangedTokens: Double = 0
    var cacheShare: Double { tokens.prompt > 0 ? tokens.cacheRead / tokens.prompt : 0 }
    var coverage: Double { tokens.total > 0 ? pricedTokens / tokens.total : 0 }
    var rangeCoverage: Double { tokens.total > 0 ? rangedTokens / tokens.total : 0 }
    var measuredTokens: Double { tokens.total - inferredTokens }
    /// Exact estimates plus the bounds of everything that could only be bounded.
    var estimateBounds: ClosedRange<Double>? {
        guard estimatedUSD != nil || rangedTokens > 0 else { return nil }
        let exact = estimatedUSD ?? 0
        return (exact + rangeLowUSD)...(exact + max(rangeLowUSD, rangeHighUSD))
    }

    init(_ entries: [ModelUsageInsightEntry]) {
        for entry in entries {
            tokens.add(entry.tokens); requests += entry.requests; runs += entry.runs; pricedTokens += entry.pricedTokens
            if entry.inferred { inferredTokens += entry.tokens.total }
            if let cost = entry.estimatedUSD { estimatedUSD = (estimatedUSD ?? 0) + cost }
            if let cost = entry.actualUSD { actualUSD = (actualUSD ?? 0) + cost }
            if let cost = entry.reportedEstimateUSD { reportedEstimateUSD = (reportedEstimateUSD ?? 0) + cost }
            rangeLowUSD += entry.rangeLowUSD; rangeHighUSD += entry.rangeHighUSD; rangedTokens += entry.rangedTokens
        }
    }
}

struct ModelUsageInsightData {
    let sources: [ModelUsageInsightSource]
    let entries: [ModelUsageInsightEntry]

    /// `since` keeps only records that end after it, for views that show one recent
    /// window; every source is still listed with its full coverage.
    init(archive: ModelUsageArchive, snapshots: [QuotaSnapshot], since: Date? = nil) {
        var sources: [ModelUsageInsightSource] = []
        var entries: [ModelUsageInsightEntry] = []
        let bySource = Dictionary(grouping: archive.buckets, by: \.source)
        let ledgerSources = Set(bySource.keys)
        let isRecent = { (end: Date) in since.map { end > $0 } ?? true }
        for name in archive.sources {
            let provider = ModelUsageSourceIdentity.host(name)
            let coverage = archive.coverage.first { $0.source == name }
            let rows = bySource[name] ?? []
            let problems = coverage.map { $0.unreadableFiles + $0.malformedLines } ?? 0
            sources.append(.init(id: name, provider: provider, title: ModelUsageSourceIdentity.title(name),
                detail: ModelUsageSourceIdentity.detail(name, files: coverage?.files ?? 0),
                first: coverage?.firstEvent ?? rows.map(\.start).min(), last: coverage?.lastEvent ?? rows.map(\.start).max(),
                scanned: coverage?.scannedAt, local: true,
                issue: problems > 0 ? "\(coverage?.unreadableFiles ?? 0) files deferred; \(coverage?.malformedLines ?? 0) malformed lines skipped" : nil))
            entries += rows.filter { isRecent($0.start.addingTimeInterval(Double($0.seconds))) }.map { row in
                .init(id: row.id, source: name, provider: provider, model: row.model, start: row.start,
                    end: row.start.addingTimeInterval(Double(row.seconds)), tokens: row.tokens, requests: Double(row.requests),
                    estimatedUSD: row.pricedRequests > 0 ? row.estimatedUSD : nil, pricedTokens: row.pricedTokens,
                    actualUSD: nil, reportedEstimateUSD: nil, precise: true, rangeLowUSD: row.rangeLowUSD,
                    rangeHighUSD: row.rangeHighUSD, rangedTokens: row.rangedTokens, inferred: row.inferred, runs: Double(row.runs))
            }
        }
        var seen = Set<String>()
        for snapshot in snapshots {
            for bucket in snapshot.analyticsBuckets where bucket.hasUsage && isRecent(bucket.endDate) {
                if bucket.source != .officialAPI {
                    if ledgerSources.contains("codex"), snapshot.providerID == .openai || snapshot.providerID == .codexTelemetry { continue }
                    if ledgerSources.contains("claude"), snapshot.providerID == .claude { continue }
                    // The Vibe card's chars ÷ 4 estimates describe the sessions the ledger measured.
                    if ledgerSources.contains("mistral"), snapshot.providerID == .mistral { continue }
                }
                let source = "\(snapshot.providerID.rawValue):\(bucket.source.rawValue)"
                guard seen.insert("\(source):\(bucket.id)").inserted else { continue }
                let model = bucket.model ?? (bucket.totalTokens == 0 && bucket.costUSD != nil ? "Provider spend" : "Unknown model")
                let counts = ModelTokenCounts(input: max(0, bucket.inputTokens), cacheRead: max(0, bucket.cachedInputTokens), output: max(0, bucket.outputTokens))
                let provider = snapshot.providerID
                let rateProvider = provider == .meta ? "muse" : provider.rawValue
                // Aggregate buckets cannot reveal whether individual calls crossed a prompt tier,
                // so only a single-request bucket may select one; others are bounded.
                let cost = counts.total > 0
                    ? ModelRateCatalog.costRange(source: rateProvider, model: model, tokens: counts, calls: bucket.requests == 1 ? 1 : 0)
                    : nil
                let exact = cost?.exact == true ? cost?.low : nil
                entries.append(.init(id: "\(source):\(bucket.id)", source: source, provider: provider, model: model,
                    start: bucket.startDate, end: bucket.endDate, tokens: counts, requests: bucket.requests,
                    estimatedUSD: exact, pricedTokens: exact == nil ? 0 : counts.total,
                    actualUSD: bucket.source == .officialAPI ? bucket.costUSD : nil,
                    reportedEstimateUSD: bucket.source == .localEstimate ? bucket.costUSD : nil, precise: false,
                    rangeLowUSD: exact == nil ? cost?.low ?? 0 : 0, rangeHighUSD: exact == nil ? cost?.high ?? 0 : 0,
                    rangedTokens: exact == nil && cost != nil ? counts.total : 0,
                    inferred: ModelUsageTokenBasis.isInferred(note: bucket.note)))
            }
        }
        // Cards that keep only per-event totals, for providers no ledger or bucket history
        // covers: the split is unknown, so tokens stay unsplit and any estimate a range.
        var covered = Set(ledgerSources.compactMap(ModelUsageSourceIdentity.host))
        if ledgerSources.contains("codex") { covered.insert(.codexTelemetry) }
        var seenEvents = Set<UUID>()
        for snapshot in snapshots where snapshot.analyticsBuckets.isEmpty && !covered.contains(snapshot.providerID) {
            var hours: [String: (start: Date, model: String, tokens: Double, messages: Double)] = [:]
            for event in UsageEventDeduplicator.flatten([snapshot]) where seenEvents.insert(event.id).inserted {
                guard let tokens = event.tokens, tokens.isFinite, tokens > 0, isRecent(event.timestamp.addingTimeInterval(3600)) else { continue }
                let start = Date(timeIntervalSince1970: floor(event.timestamp.timeIntervalSince1970 / 3600) * 3600)
                let model = event.model.map { String($0.prefix(256)) } ?? "Unknown model"
                let key = "\(start.timeIntervalSince1970)|\(model)"
                var hour = hours[key] ?? (start, model, 0, 0)
                hour.tokens += tokens
                if event.type == .message { hour.messages += 1 }
                hours[key] = hour
            }
            let provider = snapshot.providerID
            let source = "\(provider.rawValue):events"
            for (key, hour) in hours {
                let counts = ModelTokenCounts(unsplit: hour.tokens)
                let cost = ModelRateCatalog.costRange(source: provider == .meta ? "muse" : provider.rawValue, model: hour.model, tokens: counts, calls: 0)
                entries.append(.init(id: "\(source):\(key)", source: source, provider: provider, model: hour.model,
                    start: hour.start, end: hour.start.addingTimeInterval(3600), tokens: counts, requests: hour.messages,
                    estimatedUSD: nil, pricedTokens: 0, actualUSD: nil, reportedEstimateUSD: nil, precise: false,
                    rangeLowUSD: cost?.low ?? 0, rangeHighUSD: cost?.high ?? 0, rangedTokens: cost == nil ? 0 : hour.tokens, inferred: false))
            }
        }
        for (id, rows) in Dictionary(grouping: entries.filter { !$0.precise }, by: \.source) {
            guard let row = rows.first else { continue }
            let official = id.hasSuffix(UsageAnalyticsSource.officialAPI.rawValue), events = id.hasSuffix(":events")
            let label = official ? "API report" : events ? "card activity" : "provider history"
            sources.append(.init(id: id, provider: row.provider, title: "\(row.provider?.displayName ?? id) · \(label)",
                detail: events ? "Token totals per event from the quota card; no input/output split"
                    : "Available provider buckets; retention and resolution vary",
                first: rows.map(\.start).min(), last: rows.map(\.end).max(),
                scanned: snapshots.first { $0.providerID == row.provider }?.fetchedAt, local: false, issue: nil))
        }
        self.sources = sources.sorted { $0.id < $1.id }
        self.entries = entries.sorted { $0.start < $1.start }
    }

    func selected(source: String, model: String = "", window: ModelUsageWindow, now: Date) -> [ModelUsageInsightEntry] {
        entries.filter { row in
            (source.isEmpty || row.source == source) && (model.isEmpty || row.model == model) && Self.contains(row, window: window, now: now)
        }
    }

    /// The hue class a source wears: its provider's, or for one spanning providers (such
    /// as TaskWraith's runs) the brand behind most of its tokens in the window.
    func brand(of source: ModelUsageInsightSource, window: ModelUsageWindow, now: Date) -> String? {
        if let provider = source.provider { return TaskWraithBranding.runtimeProvider(forSource: provider.rawValue) }
        var weights: [String: Double] = [:]
        for row in entries where row.source == source.id && Self.contains(row, window: window, now: now) {
            weights[ModelUsageDisplayIdentity.provider(model: row.model, source: row.source), default: 0] += row.tokens.total
        }
        return weights.max { $0.value == $1.value ? $0.key > $1.key : $0.value < $1.value }?.key
    }

    /// A precise record overlapping the window, or a coarse bucket that fits inside it.
    static func contains(_ row: ModelUsageInsightEntry, window: ModelUsageWindow, now: Date) -> Bool {
        row.start <= now && row.end > now.addingTimeInterval(-window.seconds)
            && (row.precise || row.end.timeIntervalSince(row.start) <= window.seconds)
    }

    /// The sources with the most tokens in the window, ledgers first on a tie, so a
    /// busy source is never hidden behind quieter ones that sort earlier by name.
    func busiest(_ limit: Int, window: ModelUsageWindow, now: Date) -> [(source: ModelUsageInsightSource, totals: ModelUsageInsightTotals)] {
        let ranked = sources.map { (source: $0, totals: ModelUsageInsightTotals(selected(source: $0.id, window: window, now: now))) }
        return Array(ranked.sorted {
            if $0.totals.tokens.total != $1.totals.tokens.total { return $0.totals.tokens.total > $1.totals.tokens.total }
            if $0.source.local != $1.source.local { return $0.source.local }
            return $0.source.id < $1.source.id
        }.prefix(limit))
    }

    func chartRows(source: String, model: String = "") -> [ModelUsageRollup] {
        entries.filter { $0.source == source && (model.isEmpty || $0.model == model) && $0.tokens.total > 0 }.map {
            ModelUsageRollup(source: $0.source, model: $0.model, start: $0.start,
                seconds: max(1, Int($0.end.timeIntervalSince($0.start))), tokens: $0.tokens, requests: Int($0.requests), runs: Int($0.runs))
        }
    }
}

/// Producers declare their counting method in the bucket note. Character-length
/// estimates (the Mistral Vibe card's chars ÷ 4) are inferred, not provider-reported.
enum ModelUsageTokenBasis {
    static func isInferred(note: String?) -> Bool {
        guard let note = note?.lowercased().replacingOccurrences(of: " ", with: "") else { return false }
        return note.contains("chars÷4") || note.contains("chars/4")
    }
}

enum ModelUsageFormat {
    /// One figure only when every priced token was priced exactly; otherwise a range.
    static func estimate(_ totals: ModelUsageInsightTotals) -> String {
        guard let bounds = totals.estimateBounds else { return "—" }
        guard bounds.lowerBound != bounds.upperBound else { return money(bounds.lowerBound) }
        return "\(money(bounds.lowerBound))–\(money(bounds.upperBound))"
    }

    /// Whole runs are never called calls: their API call counts were not recorded.
    static func requests(_ requests: Double, runs: Double) -> String {
        let count = tokens(requests)
        if runs <= 0 { return "\(count) calls" }
        return runs >= requests ? "\(count) runs" : "\(count) calls & runs"
    }

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
