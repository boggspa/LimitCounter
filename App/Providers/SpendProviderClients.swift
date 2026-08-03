import Foundation

enum SpendProviderCredentialField {
    static let manualSpent = "manualSpent"
    static let manualAllowance = "manualAllowance"
    static let manualCurrency = "manualCurrency"
    static let manualResetAt = "manualResetAt"
    static let manualCurrentBalance = "manualCurrentBalance"
    static let manualTopUpTotal = "manualTopUpTotal"
    static let manualPlanName = "manualPlanName"
    static let anchorUpdatedAt = "anchorUpdatedAt"
}

private enum ProviderDateParser {
    static func parse(_ value: String?) -> Date? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }

        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) { return date }

        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        if let date = plain.date(from: value) { return date }

        for format in ["yyyy-MM-dd", "MM/dd/yyyy", "dd/MM/yyyy"] {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = format
            if let date = formatter.date(from: value) { return date }
        }
        return nil
    }

    static func isoString(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}

private struct SecurityScopedCredentialAccess {
    let url: URL
    let stop: () -> Void

    static func resolve(
        credentials: ProviderCredential?,
        fallbackURL: URL? = nil
    ) -> SecurityScopedCredentialAccess? {
        if let bookmarkData = credentials?.bookmarkData
            ?? credentials?.extraFields?["bookmarkData"].flatMap({ Data(base64Encoded: $0) }) {
            var stale = false
            #if os(macOS)
            let options: URL.BookmarkResolutionOptions = .withSecurityScope
            #else
            let options: URL.BookmarkResolutionOptions = []
            #endif
            if let url = try? URL(
                resolvingBookmarkData: bookmarkData,
                options: options,
                bookmarkDataIsStale: &stale
            ) {
                if stale { print("[SpendProvider] Security-scoped bookmark is stale") }
                let didStart = url.startAccessingSecurityScopedResource()
                return SecurityScopedCredentialAccess(url: url) {
                    if didStart { url.stopAccessingSecurityScopedResource() }
                }
            }
        }

        if let path = credentials?.normalizedCustomEndpoint {
            let url = URL(fileURLWithPath: path)
            let didStart = url.startAccessingSecurityScopedResource()
            return SecurityScopedCredentialAccess(url: url) {
                if didStart { url.stopAccessingSecurityScopedResource() }
            }
        }

        guard let fallbackURL else { return nil }
        return SecurityScopedCredentialAccess(url: fallbackURL, stop: {})
    }
}

struct MistralLocalUsageSummary {
    struct CostObservation {
        let timestamp: Date
        let costUSD: Double
    }

    let currentMonthCostUSD: Double
    let last30DaysCostUSD: Double
    let inputTokens: Double
    let outputTokens: Double
    let events: [UsageEvent]
    let analyticsBuckets: [UsageAnalyticsBucket]
    let costObservations: [CostObservation]

    func costUSD(since date: Date) -> Double {
        costObservations
            .filter { $0.timestamp > date }
            .reduce(0) { $0 + $1.costUSD }
    }
}

enum MistralVibeUsageReader {
    private struct SessionMeta: Decodable {
        struct Stats: Decodable {
            let sessionPromptTokens: Double?
            let sessionCompletionTokens: Double?
            let sessionCost: Double?
            let inputPricePerMillion: Double?
            let outputPricePerMillion: Double?

            enum CodingKeys: String, CodingKey {
                case sessionPromptTokens = "session_prompt_tokens"
                case sessionCompletionTokens = "session_completion_tokens"
                case sessionCost = "session_cost"
                case inputPricePerMillion = "input_price_per_million"
                case outputPricePerMillion = "output_price_per_million"
            }
        }

        struct Configuration: Decodable {
            let activeModel: String?

            enum CodingKeys: String, CodingKey {
                case activeModel = "active_model"
            }
        }

        let startTime: String?
        let endTime: String?
        let stats: Stats?
        let config: Configuration?

        enum CodingKeys: String, CodingKey {
            case startTime = "start_time"
            case endTime = "end_time"
            case stats
            case config
        }
    }

    private struct DailyKey: Hashable {
        let start: Date
        let model: String
    }

    private struct DailyValue {
        var inputTokens = 0.0
        var outputTokens = 0.0
        var costUSD = 0.0
        var requests = 0.0
    }

    static func read(rootURL: URL, now: Date = Date()) -> MistralLocalUsageSummary? {
        let sessionsURL = normalizedSessionsURL(rootURL)
        guard FileManager.default.fileExists(atPath: sessionsURL.path) else { return nil }

        let cutoff = now.addingTimeInterval(-40 * 86_400)
        let decoder = JSONDecoder()
        var daily: [DailyKey: DailyValue] = [:]
        var events: [UsageEvent] = []
        var costObservations: [MistralLocalUsageSummary.CostObservation] = []
        var scannedMetaFiles = 0
        var candidates: [(url: URL, modified: Date?)] = []

        guard let enumerator = FileManager.default.enumerator(
            at: sessionsURL,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return nil }

        for case let fileURL as URL in enumerator {
            guard fileURL.lastPathComponent == "meta.json" else { continue }
            scannedMetaFiles += 1
            if scannedMetaFiles > 20_000 { break }

            let values = try? fileURL.resourceValues(
                forKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]
            )
            guard values?.isRegularFile == true else { continue }
            if let modified = values?.contentModificationDate, modified < cutoff { continue }
            guard (values?.fileSize ?? Int.max) <= 1_048_576 else { continue }
            candidates.append((fileURL, values?.contentModificationDate))
        }

        candidates.sort { lhs, rhs in
            (lhs.modified ?? .distantPast) > (rhs.modified ?? .distantPast)
        }

        for candidate in candidates.prefix(2_000) {
            guard let data = boundedFileData(at: candidate.url, maximumBytes: 1_048_576),
                  let meta = try? decoder.decode(SessionMeta.self, from: data),
                  let stats = meta.stats else { continue }

            let timestamp = ProviderDateParser.parse(meta.endTime)
                ?? ProviderDateParser.parse(meta.startTime)
                ?? candidate.modified
                ?? now
            guard timestamp >= cutoff else { continue }

            let input = max(stats.sessionPromptTokens ?? 0, 0)
            let output = max(stats.sessionCompletionTokens ?? 0, 0)
            let derivedCost = input / 1_000_000 * max(stats.inputPricePerMillion ?? 0, 0)
                + output / 1_000_000 * max(stats.outputPricePerMillion ?? 0, 0)
            let cost = max(stats.sessionCost ?? derivedCost, 0)
            let model = meta.config?.activeModel?.trimmingCharacters(in: .whitespacesAndNewlines)
                .nilIfEmpty ?? "Mistral Vibe"
            let day = utcCalendar.startOfDay(for: timestamp)
            let key = DailyKey(start: day, model: model)
            var value = daily[key] ?? DailyValue()
            value.inputTokens += input
            value.outputTokens += output
            value.costUSD += cost
            value.requests += 1
            daily[key] = value
            costObservations.append(.init(timestamp: timestamp, costUSD: cost))
            events.append(
                UsageEvent(
                    timestamp: timestamp,
                    tokens: input + output > 0 ? input + output : nil,
                    model: model,
                    type: .telemetry
                )
            )
        }

        guard !daily.isEmpty else { return nil }
        let monthStart = utcCalendar.date(
            from: utcCalendar.dateComponents([.year, .month], from: now)
        ) ?? utcCalendar.startOfDay(for: now)
        let thirtyDayCutoff = now.addingTimeInterval(-30 * 86_400)
        let analytics = daily.map { key, value in
            UsageAnalyticsBucket(
                startDate: key.start,
                endDate: utcCalendar.date(byAdding: .day, value: 1, to: key.start)
                    ?? key.start.addingTimeInterval(86_400),
                model: key.model,
                inputTokens: value.inputTokens,
                outputTokens: value.outputTokens,
                requests: value.requests,
                costUSD: value.costUSD,
                source: .localTelemetry,
                note: "Vibe meta.json"
            )
        }.sorted { $0.startDate > $1.startDate }

        return MistralLocalUsageSummary(
            currentMonthCostUSD: analytics.filter { $0.startDate >= monthStart }.compactMap(\.costUSD).reduce(0, +),
            last30DaysCostUSD: analytics.filter { $0.endDate >= thirtyDayCutoff }.compactMap(\.costUSD).reduce(0, +),
            inputTokens: analytics.reduce(0) { $0 + $1.inputTokens },
            outputTokens: analytics.reduce(0) { $0 + $1.outputTokens },
            events: events.sorted { $0.timestamp > $1.timestamp },
            analyticsBuckets: analytics,
            costObservations: costObservations
        )
    }

    private static func normalizedSessionsURL(_ selectedURL: URL) -> URL {
        if selectedURL.lastPathComponent == "meta.json" {
            return selectedURL.deletingLastPathComponent().deletingLastPathComponent()
        }
        if selectedURL.lastPathComponent == "session" { return selectedURL }
        if selectedURL.lastPathComponent == "logs" {
            return selectedURL.appendingPathComponent("session", isDirectory: true)
        }
        return selectedURL.appendingPathComponent("logs/session", isDirectory: true)
    }

    private static var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        return calendar
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

struct MistralAdminUsageResult {
    let totalSpend: Double
    let totalSpendIsComplete: Bool
    let vibeSpend: Double?
    let currency: String
    let periodStart: Date?
    let periodEnd: Date?
}

enum MistralAdminUsageParser {
    private static let categories = [
        "chat", "completion", "ocr", "audio", "audio_characters", "connectors",
        "libraries_api", "fine_tuning", "vibe_usage"
    ]
    private static let costFields = ["cost", "amount", "total_cost", "totalCost", "spend", "total", "cost_amount"]

    static func parse(data: Data) -> MistralAdminUsageResult? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        var envelopes = [root]
        for key in ["usage", "data", "categories", "breakdown"] {
            if let nested = root[key] as? [String: Any] { envelopes.append(nested) }
        }

        var categoryCosts: [String: Double] = [:]
        var hasUnparsedCategory = false
        for category in categories {
            var categoryWasPresent = false
            for envelope in envelopes where categoryCosts[category] == nil {
                guard envelope.keys.contains(category) else { continue }
                categoryWasPresent = true
                if let cost = readCost(envelope[category]) { categoryCosts[category] = cost }
            }
            if categoryWasPresent, categoryCosts[category] == nil { hasUnparsedCategory = true }
        }

        let declared = readCost(root["total"])
            ?? readCost(root["total_cost"])
            ?? readCost(root["totalCost"])
        guard declared != nil || !categoryCosts.isEmpty else { return nil }
        let total = declared ?? categoryCosts.values.reduce(0, +)
        let currency = currencyCode(from: root)
        return MistralAdminUsageResult(
            totalSpend: total,
            totalSpendIsComplete: declared != nil || !hasUnparsedCategory,
            vibeSpend: categoryCosts["vibe_usage"],
            currency: currency,
            periodStart: ProviderDateParser.parse(root["start_date"] as? String),
            periodEnd: ProviderDateParser.parse(root["end_date"] as? String)
        )
    }

    private static func readCost(_ value: Any?) -> Double? {
        if let value = value as? NSNumber, value.doubleValue >= 0 { return value.doubleValue }
        if let value = value as? String, let number = Double(value), number >= 0 { return number }
        guard let object = value as? [String: Any] else { return nil }
        for field in costFields {
            if let result = readCost(object[field]) { return result }
        }
        return nil
    }

    private static func currencyCode(from root: [String: Any]) -> String {
        if let value = (root["currency"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !value.isEmpty {
            return value.uppercased()
        }
        switch (root["currency_symbol"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) {
        case "$": return "USD"
        case "£": return "GBP"
        case "€": return "EUR"
        default: return "billing units"
        }
    }
}

private struct MistralAdminUsageClient {
    func fetch(apiKey: String, now: Date = Date()) async -> MistralAdminUsageResult? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        let month = calendar.component(.month, from: now)
        let year = calendar.component(.year, from: now)
        guard var components = URLComponents(string: "https://api.mistral.ai/v1/admin/usage") else {
            return nil
        }
        components.queryItems = [
            URLQueryItem(name: "month", value: String(month)),
            URLQueryItem(name: "year", value: String(year))
        ]
        guard let url = components.url else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode),
                  data.count <= 1_048_576 else {
                return nil
            }
            return MistralAdminUsageParser.parse(data: data)
        } catch {
            return nil
        }
    }
}

enum MistralAnchorWatermarkStore {
    struct Adjustment {
        let spend: Double
        let localIncrement: Double
    }

    private static let appGroupID = "group.com.chrisizatt.LLMUsageCounter"
    private static let signatureKey = "mistral.manualAnchor.signature"
    private static let localCostKey = "mistral.manualAnchor.localCostUSD"
    private static let localMonthKey = "mistral.manualAnchor.localCostMonth"
    private static let accumulatedCostKey = "mistral.manualAnchor.accumulatedLocalCostUSD"
    private static let hasBaselineKey = "mistral.manualAnchor.hasLocalBaseline"

    private static let unitsPerUSD: [String: Double] = [
        "USD": 1,
        "EUR": 0.92,
        "GBP": 0.79
    ]

    static func adjustment(
        anchoredSpend: Double,
        currentLocalSpendUSD: Double?,
        currency: String,
        signature: String,
        initialLocalIncrementUSD: Double = 0,
        now: Date = Date(),
        defaults overrideDefaults: UserDefaults? = nil
    ) -> Adjustment {
        guard let conversionRate = unitsPerUSD[currency.uppercased()] else {
            return Adjustment(spend: anchoredSpend, localIncrement: 0)
        }
        let defaults = overrideDefaults ?? UserDefaults(suiteName: appGroupID) ?? .standard
        guard defaults.string(forKey: signatureKey) == signature else {
            defaults.set(signature, forKey: signatureKey)
            let recoveredIncrement = max(initialLocalIncrementUSD, 0)
            defaults.set(recoveredIncrement, forKey: accumulatedCostKey)
            if let currentLocalSpendUSD {
                defaults.set(currentLocalSpendUSD, forKey: localCostKey)
                defaults.set(monthKey(for: now), forKey: localMonthKey)
                defaults.set(true, forKey: hasBaselineKey)
            } else {
                defaults.removeObject(forKey: localCostKey)
                defaults.removeObject(forKey: localMonthKey)
                defaults.set(false, forKey: hasBaselineKey)
            }
            return result(
                anchoredSpend: anchoredSpend,
                accumulatedUSD: recoveredIncrement,
                conversionRate: conversionRate
            )
        }

        var accumulated = defaults.double(forKey: accumulatedCostKey)
        guard let currentLocalSpendUSD else {
            return result(
                anchoredSpend: anchoredSpend,
                accumulatedUSD: accumulated,
                conversionRate: conversionRate
            )
        }
        let currentMonth = monthKey(for: now)
        guard defaults.bool(forKey: hasBaselineKey) else {
            if defaults.object(forKey: localCostKey) != nil {
                let legacyBaseline = defaults.double(forKey: localCostKey)
                accumulated += max(currentLocalSpendUSD - legacyBaseline, 0)
                defaults.set(accumulated, forKey: accumulatedCostKey)
            } else if initialLocalIncrementUSD > accumulated {
                accumulated = initialLocalIncrementUSD
                defaults.set(accumulated, forKey: accumulatedCostKey)
            }
            defaults.set(currentLocalSpendUSD, forKey: localCostKey)
            defaults.set(currentMonth, forKey: localMonthKey)
            defaults.set(true, forKey: hasBaselineKey)
            return result(
                anchoredSpend: anchoredSpend,
                accumulatedUSD: accumulated,
                conversionRate: conversionRate
            )
        }

        let previousLocalCost = defaults.double(forKey: localCostKey)
        let storedLocalCost: Double
        if defaults.string(forKey: localMonthKey) == currentMonth {
            accumulated += max(currentLocalSpendUSD - previousLocalCost, 0)
            storedLocalCost = max(currentLocalSpendUSD, previousLocalCost)
        } else {
            // The local month-to-date counter restarted. Preserve previously
            // accumulated post-anchor spend and begin with the new month.
            accumulated += currentLocalSpendUSD
            storedLocalCost = currentLocalSpendUSD
        }
        defaults.set(storedLocalCost, forKey: localCostKey)
        defaults.set(currentMonth, forKey: localMonthKey)
        defaults.set(accumulated, forKey: accumulatedCostKey)
        return result(
            anchoredSpend: anchoredSpend,
            accumulatedUSD: accumulated,
            conversionRate: conversionRate
        )
    }

    static func adjustedSpend(
        anchoredSpend: Double,
        currentLocalSpendUSD: Double?,
        currency: String,
        signature: String,
        initialLocalIncrementUSD: Double = 0,
        now: Date = Date(),
        defaults overrideDefaults: UserDefaults? = nil
    ) -> Double {
        adjustment(
            anchoredSpend: anchoredSpend,
            currentLocalSpendUSD: currentLocalSpendUSD,
            currency: currency,
            signature: signature,
            initialLocalIncrementUSD: initialLocalIncrementUSD,
            now: now,
            defaults: overrideDefaults
        ).spend
    }

    private static func result(
        anchoredSpend: Double,
        accumulatedUSD: Double,
        conversionRate: Double
    ) -> Adjustment {
        let localIncrement = max(accumulatedUSD, 0) * conversionRate
        return Adjustment(
            spend: anchoredSpend + localIncrement,
            localIncrement: localIncrement
        )
    }

    private static func monthKey(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM"
        return formatter.string(from: date)
    }
}

public struct MistralProviderClient: ProviderClient {
    public let providerID: ProviderID = .mistral

    public init() {}

    public func fetchSnapshot(credentials: ProviderCredential?) async throws -> QuotaSnapshot {
        let now = Date()
        #if os(macOS)
        let fallback = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".vibe", isDirectory: true)
        #else
        let fallback: URL? = nil
        #endif
        let access = SecurityScopedCredentialAccess.resolve(credentials: credentials, fallbackURL: fallback)
        defer { access?.stop() }
        let local = access.flatMap { MistralVibeUsageReader.read(rootURL: $0.url, now: now) }
        let fields = credentials?.extraFields ?? [:]
        let token = credentials?.normalizedAccessToken
        let admin: MistralAdminUsageResult? = if let token, !token.isEmpty {
            await MistralAdminUsageClient().fetch(apiKey: token, now: now)
        } else {
            nil
        }

        let manualAllowance = positiveDouble(fields[SpendProviderCredentialField.manualAllowance])
            ?? positiveDouble(credentials?.normalizedAccountIdentifier)
        let manualSpend = nonnegativeDouble(fields[SpendProviderCredentialField.manualSpent])
        let manualCurrency = normalizedCurrency(fields[SpendProviderCredentialField.manualCurrency])
        let manualReset = ProviderDateParser.parse(fields[SpendProviderCredentialField.manualResetAt])
        let budgetUSD = ProviderMonthlyBudgetStore.nonisolatedBudgetUSD(for: .mistral)
        var windows: [QuotaWindow] = []
        var stats: [QuotaStat] = []
        var signals: [QuotaSignal] = []

        if let admin, admin.totalSpendIsComplete {
            let total = admin.currency == "USD" ? (manualAllowance ?? budgetUSD) : manualAllowance
            windows.append(
                QuotaWindow(
                    label: "This billing period",
                    windowKind: .monthly,
                    used: admin.totalSpend,
                    total: total,
                    resetDate: admin.periodEnd,
                    unit: admin.currency,
                    subtitle: "Official Mistral Admin API"
                )
            )
        } else if let manualSpend {
            if let manualReset, manualReset <= now {
                signals.append(
                    QuotaSignal(
                        kind: .scheduledReset,
                        title: "Billing anchor expired",
                        message: "Update the Mistral console reading for the new billing cycle.",
                        severity: .info,
                        confidence: 1,
                        windowLabel: "This billing period",
                        detectedAt: now
                    )
                )
            } else {
                let signature = fields[SpendProviderCredentialField.anchorUpdatedAt]
                    ?? "\(manualSpend)|\(manualAllowance ?? 0)|\(manualReset?.timeIntervalSince1970 ?? 0)"
                let anchorUpdatedAt = ProviderDateParser.parse(
                    fields[SpendProviderCredentialField.anchorUpdatedAt]
                )
                let adjustment = MistralAnchorWatermarkStore.adjustment(
                    anchoredSpend: manualSpend,
                    currentLocalSpendUSD: local?.currentMonthCostUSD,
                    currency: manualCurrency,
                    signature: signature,
                    initialLocalIncrementUSD: anchorUpdatedAt.map {
                        local?.costUSD(since: $0) ?? 0
                    } ?? 0,
                    now: now
                )
                windows.append(
                    QuotaWindow(
                        label: "This billing period",
                        windowKind: .monthly,
                        used: adjustment.spend,
                        total: manualAllowance,
                        resetDate: manualReset,
                        unit: manualCurrency,
                        subtitle: adjustment.localIncrement > 0
                            ? "Manual console anchor plus tracked local Vibe spend"
                            : "Manual console anchor"
                    )
                )
            }
        } else if let admin, let vibeSpend = admin.vibeSpend {
            windows.append(
                QuotaWindow(
                    label: "Vibe this billing period",
                    windowKind: .monthly,
                    used: vibeSpend,
                    unit: admin.currency,
                    subtitle: "Official Mistral Admin API; shared-pool total unavailable"
                )
            )
        }

        if let admin, let vibeSpend = admin.vibeSpend {
            stats.append(
                QuotaStat(
                    label: admin.totalSpendIsComplete ? "Vibe portion" : "Vibe usage",
                    value: vibeSpend,
                    unit: admin.currency,
                    subtitle: "Official Admin API"
                )
            )
        }

        if let local {
            if windows.isEmpty {
                windows.append(
                    QuotaWindow(
                        label: "Local Vibe this month",
                        windowKind: .monthly,
                        used: local.currentMonthCostUSD,
                        total: budgetUSD,
                        unit: "USD",
                        subtitle: "Exact local Vibe meta.json cost"
                    )
                )
            }
            stats.append(contentsOf: [
                QuotaStat(label: "Local 30D cost", value: local.last30DaysCostUSD, unit: "USD", subtitle: "First-party Vibe metadata"),
                QuotaStat(label: "Input tokens", value: local.inputTokens, unit: "tokens"),
                QuotaStat(label: "Output tokens", value: local.outputTokens, unit: "tokens")
            ])
        }

        guard !windows.isEmpty || local != nil else { throw ProviderFetchError.notConfigured }
        return QuotaSnapshot(
            providerID: .mistral,
            displayName: ProviderID.mistral.snapshotDisplayName,
            planName: fields[SpendProviderCredentialField.manualPlanName] ?? (admin == nil ? "Vibe" : "Admin API"),
            windows: windows,
            stats: stats,
            signals: signals,
            events: local?.events ?? [],
            analyticsBuckets: local?.analyticsBuckets ?? [],
            fetchState: .success,
            fetchedAt: now
        )
    }
}

private struct DeepSeekBalanceResponse: Decodable {
    struct Balance: Decodable {
        let currency: String
        let totalBalance: String
        let grantedBalance: String
        let toppedUpBalance: String

        enum CodingKeys: String, CodingKey {
            case currency
            case totalBalance = "total_balance"
            case grantedBalance = "granted_balance"
            case toppedUpBalance = "topped_up_balance"
        }
    }

    let isAvailable: Bool
    let balanceInfos: [Balance]

    enum CodingKeys: String, CodingKey {
        case isAvailable = "is_available"
        case balanceInfos = "balance_infos"
    }
}

struct DeepSeekBalanceObservation: Equatable {
    let isAvailable: Bool
    let currency: String
    let totalBalance: Double
    let grantedBalance: Double
    let toppedUpBalance: Double
}

enum DeepSeekBalanceParser {
    static func parse(data: Data) -> DeepSeekBalanceObservation? {
        guard let decoded = try? JSONDecoder().decode(DeepSeekBalanceResponse.self, from: data),
              let selected = decoded.balanceInfos.first(where: { $0.currency.uppercased() == "USD" })
                ?? decoded.balanceInfos.first,
              let totalBalance = Double(selected.totalBalance),
              let grantedBalance = Double(selected.grantedBalance),
              let toppedUpBalance = Double(selected.toppedUpBalance) else {
            return nil
        }
        return DeepSeekBalanceObservation(
            isAvailable: decoded.isAvailable,
            currency: selected.currency.uppercased(),
            totalBalance: totalBalance,
            grantedBalance: grantedBalance,
            toppedUpBalance: toppedUpBalance
        )
    }
}

enum DeepSeekTopUpMeter {
    static func creditUsed(totalTopUp: Double?, currentBalance: Double) -> Double? {
        guard let totalTopUp, totalTopUp > 0, currentBalance >= 0 else { return nil }
        return min(max(totalTopUp - currentBalance, 0), totalTopUp)
    }
}

struct DeepSeekObservedSpendState: Codable, Equatable {
    var currency: String
    var monthKey: String
    var lastBalance: Double
    var observedSpend: Double
}

enum DeepSeekObservedSpendAccumulator {
    static func updated(
        previous: DeepSeekObservedSpendState?,
        balance: Double,
        currency: String,
        monthKey: String
    ) -> DeepSeekObservedSpendState {
        guard var state = previous,
              state.currency == currency,
              state.monthKey == monthKey else {
            return DeepSeekObservedSpendState(
                currency: currency,
                monthKey: monthKey,
                lastBalance: balance,
                observedSpend: 0
            )
        }
        if balance < state.lastBalance {
            state.observedSpend += state.lastBalance - balance
        }
        state.lastBalance = balance
        return state
    }
}

private enum DeepSeekObservedSpendStore {
    private static let appGroupID = "group.com.chrisizatt.LLMUsageCounter"
    private static let stateKey = "deepseek.observedSpend.state"

    static func record(balance: Double, currency: String, now: Date = Date()) -> Double {
        let defaults = UserDefaults(suiteName: appGroupID) ?? .standard
        let decoder = JSONDecoder()
        let encoder = JSONEncoder()
        let currentMonth = monthKey(for: now)
        let previous = defaults.data(forKey: stateKey).flatMap {
            try? decoder.decode(DeepSeekObservedSpendState.self, from: $0)
        }
        let state = DeepSeekObservedSpendAccumulator.updated(
            previous: previous,
            balance: balance,
            currency: currency,
            monthKey: currentMonth
        )
        if let data = try? encoder.encode(state) { defaults.set(data, forKey: stateKey) }
        return state.observedSpend
    }

    private static func monthKey(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM"
        return formatter.string(from: date)
    }
}

struct TaskWraithSpendSummary {
    let currentMonthCostUSD: Double
    let last35DaysCostUSD: Double
    let events: [UsageEvent]
    let analyticsBuckets: [UsageAnalyticsBucket]
}

enum TaskWraithSpendReader {
    private struct Record: Decodable {
        let provider: String?
        let model: String?
        let timestamp: Double?
        let inputTokens: Double?
        let outputTokens: Double?
        let cacheReadInputTokens: Double?
        let cacheCreationInputTokens: Double?

        enum CodingKeys: String, CodingKey {
            case provider, model, timestamp, inputTokens, outputTokens
            case cacheReadInputTokens, cacheCreationInputTokens
        }
    }

    private struct Rate {
        let input: Double
        let output: Double
        let cachedInput: Double
    }

    private struct DailyKey: Hashable {
        let date: Date
        let model: String
    }

    private struct DailyValue {
        var input = 0.0
        var output = 0.0
        var cached = 0.0
        var requests = 0.0
        var cost = 0.0
    }

    static func read(provider: ProviderID, now: Date = Date()) -> TaskWraithSpendSummary? {
        guard let scoped = AGBenchBookmarkStore.startAccess() else { return nil }
        defer { scoped.stop() }
        let fileURL = scoped.url.lastPathComponent == "usage.json"
            ? scoped.url
            : scoped.url.appendingPathComponent("usage.json")
        guard let data = boundedFileData(at: fileURL, maximumBytes: 32 * 1_024 * 1_024) else {
            return nil
        }
        return parse(data: data, provider: provider, now: now)
    }

    static func parse(data: Data, provider: ProviderID, now: Date = Date()) -> TaskWraithSpendSummary? {
        guard provider == .deepseek || provider == .cerebras,
              let records = try? JSONDecoder().decode([Record].self, from: data) else { return nil }

        let cutoff = now.addingTimeInterval(-35 * 86_400)
        var daily: [DailyKey: DailyValue] = [:]
        var events: [UsageEvent] = []
        for record in records {
            guard record.provider?.lowercased() == "pi",
                  let model = record.model?.lowercased(),
                  model.hasPrefix(provider == .deepseek ? "deepseek/" : "cerebras/"),
                  let timestampMs = record.timestamp else { continue }
            let timestamp = Date(timeIntervalSince1970: timestampMs / 1_000)
            guard timestamp >= cutoff, let rate = rate(for: model) else { continue }
            let input = max(record.inputTokens ?? 0, 0)
            let output = max(record.outputTokens ?? 0, 0)
            let cached = max(record.cacheReadInputTokens ?? 0, 0)
            let cacheCreation = max(record.cacheCreationInputTokens ?? 0, 0)
            let cost = (input + cacheCreation) / 1_000_000 * rate.input
                + output / 1_000_000 * rate.output
                + cached / 1_000_000 * rate.cachedInput
            let date = utcCalendar.startOfDay(for: timestamp)
            let key = DailyKey(date: date, model: model)
            var value = daily[key] ?? DailyValue()
            value.input += input + cacheCreation
            value.output += output
            value.cached += cached
            value.requests += 1
            value.cost += cost
            daily[key] = value
            events.append(
                UsageEvent(
                    timestamp: timestamp,
                    tokens: input + output + cached + cacheCreation > 0
                        ? input + output + cached + cacheCreation
                        : nil,
                    model: model,
                    type: .telemetry
                )
            )
        }

        guard !daily.isEmpty else { return nil }
        let buckets = daily.map { key, value in
            UsageAnalyticsBucket(
                startDate: key.date,
                endDate: utcCalendar.date(byAdding: .day, value: 1, to: key.date)
                    ?? key.date.addingTimeInterval(86_400),
                model: key.model,
                inputTokens: value.input,
                outputTokens: value.output,
                cachedInputTokens: value.cached,
                requests: value.requests,
                costUSD: value.cost,
                source: .localEstimate,
                note: "TaskWraith tokens priced with vendor rates checked 2026-08-01"
            )
        }.sorted { $0.startDate > $1.startDate }
        let monthStart = utcCalendar.date(
            from: utcCalendar.dateComponents([.year, .month], from: now)
        ) ?? utcCalendar.startOfDay(for: now)
        return TaskWraithSpendSummary(
            currentMonthCostUSD: buckets
                .filter { $0.startDate >= monthStart }
                .compactMap(\.costUSD)
                .reduce(0, +),
            last35DaysCostUSD: buckets.compactMap(\.costUSD).reduce(0, +),
            events: events.sorted { $0.timestamp > $1.timestamp },
            analyticsBuckets: buckets
        )
    }

    private static func rate(for model: String) -> Rate? {
        switch model {
        case "deepseek/deepseek-v4-flash":
            return Rate(input: 0.14, output: 0.28, cachedInput: 0.0028)
        case "deepseek/deepseek-v4-pro":
            return Rate(input: 0.435, output: 0.87, cachedInput: 0.003625)
        case "cerebras/gpt-oss-120b":
            return Rate(input: 0.35, output: 0.75, cachedInput: 0.35)
        case "cerebras/zai-glm-4.7":
            return Rate(input: 2.25, output: 2.75, cachedInput: 2.25)
        default:
            return nil
        }
    }

    private static var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        return calendar
    }
}

public struct DeepSeekProviderClient: ProviderClient {
    public let providerID: ProviderID = .deepseek
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func fetchSnapshot(credentials: ProviderCredential?) async throws -> QuotaSnapshot {
        guard let token = credentials?.normalizedAccessToken, !token.isEmpty else {
            throw ProviderFetchError.notConfigured
        }
        let endpoint = credentials?.normalizedCustomEndpoint ?? "https://api.deepseek.com/user/balance"
        guard let url = URL(string: endpoint) else {
            throw ProviderFetchError.parsingError("Invalid DeepSeek balance endpoint")
        }
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ProviderFetchError.networkError(underlying: URLError(.badServerResponse))
        }
        if http.statusCode == 401 || http.statusCode == 403 {
            throw ProviderFetchError.credentialExpired("DeepSeek rejected the API key.")
        }
        if http.statusCode == 429 {
            throw ProviderFetchError.rateLimited
        }
        guard (200..<300).contains(http.statusCode) else {
            throw ProviderFetchError.parsingError("DeepSeek returned HTTP \(http.statusCode).")
        }
        guard data.count <= 1_048_576 else {
            throw ProviderFetchError.parsingError("DeepSeek returned an unexpectedly large balance response.")
        }
        guard let balance = DeepSeekBalanceParser.parse(data: data) else {
            throw ProviderFetchError.parsingError("DeepSeek returned no readable balance.")
        }

        let currency = normalizedCurrency(balance.currency)
        let fields = credentials?.extraFields ?? [:]
        let totalTopUp = positiveDouble(fields[SpendProviderCredentialField.manualTopUpTotal])
        let creditUsed = DeepSeekTopUpMeter.creditUsed(
            totalTopUp: totalTopUp,
            currentBalance: balance.totalBalance
        )
        let observed = DeepSeekObservedSpendStore.record(balance: balance.totalBalance, currency: currency)
        let taskWraith = TaskWraithSpendReader.read(provider: .deepseek)
        let budget = currency == "USD"
            ? ProviderMonthlyBudgetStore.nonisolatedBudgetUSD(for: .deepseek)
            : nil
        var windows: [QuotaWindow] = []
        if let totalTopUp, let creditUsed {
            windows.append(
                QuotaWindow(
                    label: "Credit used",
                    windowKind: .custom,
                    used: creditUsed,
                    total: totalTopUp,
                    unit: currency,
                    subtitle: "Configured top-ups minus official remaining balance"
                )
            )
        } else {
            windows.append(
                QuotaWindow(
                    label: "Available balance",
                    windowKind: .custom,
                    used: balance.totalBalance,
                    unit: currency,
                    subtitle: "Official DeepSeek balance API"
                )
            )
        }
        if observed > 0 || budget != nil {
            windows.append(
                QuotaWindow(
                    label: "Observed this month",
                    windowKind: .monthly,
                    used: observed,
                    total: budget,
                    unit: currency,
                    subtitle: "Balance decreases observed by Limit Counter"
                )
            )
        }
        if observed == 0, let estimated = taskWraith?.currentMonthCostUSD, estimated > 0 {
            windows.append(
                QuotaWindow(
                    label: "TaskWraith estimate",
                    windowKind: .monthly,
                    used: estimated,
                    total: budget,
                    unit: "USD",
                    subtitle: "Optional local token-price estimate"
                )
            )
        }

        return QuotaSnapshot(
            providerID: .deepseek,
            displayName: ProviderID.deepseek.snapshotDisplayName,
            planName: balance.isAvailable ? "API Credits" : "Balance unavailable",
            windows: windows,
            stats: taskWraith.map {
                [QuotaStat(label: "TaskWraith 35D estimate", value: $0.last35DaysCostUSD, unit: "USD", subtitle: "Not vendor billing")]
            } ?? [],
            balances: [
                QuotaBalance(label: "Total available", amount: balance.totalBalance, unit: currency, subtitle: "Official API"),
                QuotaBalance(label: "Prepaid remaining", amount: balance.toppedUpBalance, unit: currency, subtitle: "Official API"),
                QuotaBalance(label: "Granted", amount: balance.grantedBalance, unit: currency, subtitle: "Official API")
            ] + (totalTopUp.map {
                [QuotaBalance(label: "Total topped up", amount: $0, unit: currency, subtitle: "Manual anchor")]
            } ?? []),
            events: taskWraith?.events ?? [],
            analyticsBuckets: taskWraith?.analyticsBuckets ?? [],
            fetchState: .success
        )
    }
}

struct CerebrasCSVUsageSummary {
    let cost: Double
    let currency: String
    let periodStart: Date?
    let periodEnd: Date?
    let analyticsBuckets: [UsageAnalyticsBucket]
}

enum CerebrasCSVUsageParser {
    private struct DailyKey: Hashable {
        let date: Date
        let model: String
    }

    private struct DailyValue {
        var input = 0.0
        var output = 0.0
        var requests = 0.0
        var cost = 0.0
    }

    static func parse(data: Data, now: Date = Date()) -> CerebrasCSVUsageSummary? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        let rows = CSVReader.rows(from: text)
        guard let header = rows.first, rows.count > 1 else { return nil }
        let names = header.map { normalizedHeader($0) }
        guard let costIndex = firstIndex(in: names, candidates: ["cost", "totalcost", "spend", "amount", "costusd"]) else {
            return nil
        }
        let dateIndex = firstIndex(
            in: names,
            candidates: [
                "date", "dateutc", "day", "time", "datetime", "datetimeutc",
                "timestamp", "timestamputc", "startdate", "startdateutc",
                "periodstart", "periodstartutc"
            ]
        )
        let modelIndex = firstIndex(in: names, candidates: ["model", "modelname", "modelid"])
        let inputIndex = firstIndex(in: names, candidates: ["inputtokens", "prompttokens"])
        let outputIndex = firstIndex(in: names, candidates: ["outputtokens", "completiontokens"])
        let requestIndex = firstIndex(in: names, candidates: ["requests", "requestcount", "calls"])
        let currencyIndex = firstIndex(in: names, candidates: ["currency"])
        var daily: [DailyKey: DailyValue] = [:]
        var total = 0.0
        var dates: [Date] = []
        var currency = "USD"

        for row in rows.dropFirst() where costIndex < row.count {
            let firstCell = row.isEmpty ? "" : normalizedHeader(row[0])
            let modelCell = modelIndex.flatMap { $0 < row.count ? normalizedHeader(row[$0]) : nil } ?? ""
            if ["total", "grandtotal", "summary"].contains(firstCell)
                || ["total", "grandtotal", "summary"].contains(modelCell) {
                continue
            }
            guard let cost = money(row[costIndex]), cost >= 0 else { continue }
            let date: Date
            if let dateIndex {
                guard dateIndex < row.count,
                      let parsed = ProviderDateParser.parse(row[dateIndex]) else { continue }
                date = parsed
            } else {
                date = utcCalendar.startOfDay(for: now)
            }
            let model = modelIndex.flatMap { $0 < row.count ? row[$0].trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty : nil }
                ?? "Cerebras"
            let key = DailyKey(date: utcCalendar.startOfDay(for: date), model: model)
            var value = daily[key] ?? DailyValue()
            value.cost += cost
            value.input += inputIndex.flatMap { $0 < row.count ? number(row[$0]) : nil } ?? 0
            value.output += outputIndex.flatMap { $0 < row.count ? number(row[$0]) : nil } ?? 0
            value.requests += requestIndex.flatMap { $0 < row.count ? number(row[$0]) : nil } ?? 0
            daily[key] = value
            total += cost
            if dateIndex != nil { dates.append(date) }
            if let currencyIndex, currencyIndex < row.count {
                currency = normalizedCurrency(row[currencyIndex])
            }
        }

        guard !daily.isEmpty else { return nil }
        let buckets = daily.map { key, value in
            UsageAnalyticsBucket(
                startDate: key.date,
                endDate: utcCalendar.date(byAdding: .day, value: 1, to: key.date)
                    ?? key.date.addingTimeInterval(86_400),
                model: key.model,
                inputTokens: value.input,
                outputTokens: value.output,
                requests: value.requests,
                costUSD: currency == "USD" ? value.cost : nil,
                source: .officialAPI,
                note: currency == "USD" ? "Cerebras Analytics CSV" : "Cerebras Analytics CSV - \(currency) \(value.cost)"
            )
        }.sorted { $0.startDate > $1.startDate }
        return CerebrasCSVUsageSummary(
            cost: total,
            currency: currency,
            periodStart: dates.min(),
            periodEnd: dates.max(),
            analyticsBuckets: buckets
        )
    }

    private static func normalizedHeader(_ value: String) -> String {
        value.lowercased().filter(\.isLetter)
    }

    private static func firstIndex(in names: [String], candidates: [String]) -> Int? {
        candidates.compactMap { names.firstIndex(of: $0) }.first
    }

    private static func money(_ value: String) -> Double? {
        number(value.replacingOccurrences(of: "$", with: "").replacingOccurrences(of: "GBP", with: "", options: .caseInsensitive).replacingOccurrences(of: "EUR", with: "", options: .caseInsensitive))
    }

    private static func number(_ value: String) -> Double? {
        Double(value.replacingOccurrences(of: ",", with: "").trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        return calendar
    }
}

private enum CSVReader {
    static func rows(from text: String) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var quoted = false
        var index = text.startIndex

        while index < text.endIndex {
            let character = text[index]
            if quoted {
                if character == "\"" {
                    let next = text.index(after: index)
                    if next < text.endIndex, text[next] == "\"" {
                        field.append("\"")
                        index = next
                    } else {
                        quoted = false
                    }
                } else {
                    field.append(character)
                }
            } else {
                switch character {
                case "\"": quoted = true
                case ",":
                    row.append(field)
                    field = ""
                case "\n":
                    row.append(field.trimmingCharacters(in: .newlines))
                    if !row.allSatisfy({ $0.isEmpty }) { rows.append(row) }
                    row = []
                    field = ""
                case "\r": break
                default: field.append(character)
                }
            }
            index = text.index(after: index)
        }
        row.append(field)
        if !row.allSatisfy({ $0.isEmpty }) { rows.append(row) }
        return rows
    }
}

public struct CerebrasProviderClient: ProviderClient {
    public let providerID: ProviderID = .cerebras

    public init() {}

    public func fetchSnapshot(credentials: ProviderCredential?) async throws -> QuotaSnapshot {
        let now = Date()
        let fields = credentials?.extraFields ?? [:]
        let access = SecurityScopedCredentialAccess.resolve(credentials: credentials)
        defer { access?.stop() }
        let csv = access.flatMap { access in
            latestCSV(at: access.url).flatMap { url in
                boundedFileData(at: url, maximumBytes: 16 * 1_024 * 1_024)
                    .flatMap { CerebrasCSVUsageParser.parse(data: $0) }
            }
        }
        let purchased = positiveDouble(credentials?.normalizedAccountIdentifier)
            ?? positiveDouble(fields[SpendProviderCredentialField.manualAllowance])
        let current = nonnegativeDouble(fields[SpendProviderCredentialField.manualCurrentBalance])
        let manualCurrency = normalizedCurrency(fields[SpendProviderCredentialField.manualCurrency])
        let taskWraith = TaskWraithSpendReader.read(provider: .cerebras)
        let budgetUSD = ProviderMonthlyBudgetStore.nonisolatedBudgetUSD(for: .cerebras)
        var windows: [QuotaWindow] = []
        var balances: [QuotaBalance] = []

        if let csv {
            let isCurrentMonth = isCurrentCalendarMonthReport(csv, now: now)
            let reportBudget = csv.currency == "USD" && isCurrentMonth ? budgetUSD : nil
            windows.append(
                QuotaWindow(
                    label: "Imported cost",
                    windowKind: isCurrentMonth ? .monthly : .custom,
                    used: csv.cost,
                    total: reportBudget,
                    unit: csv.currency,
                    subtitle: "Official Cerebras Analytics CSV"
                )
            )
        }
        if let purchased, let current {
            windows.append(
                QuotaWindow(
                    label: "Credit used",
                    windowKind: .custom,
                    used: max(purchased - current, 0),
                    total: purchased,
                    unit: manualCurrency,
                    subtitle: "Manual billing anchor"
                )
            )
            balances.append(
                QuotaBalance(label: "Current balance", amount: current, unit: manualCurrency, subtitle: "Manual billing anchor")
            )
        }
        if windows.isEmpty, let estimated = taskWraith?.currentMonthCostUSD, estimated > 0 {
            windows.append(
                QuotaWindow(
                    label: "TaskWraith estimate",
                    windowKind: .monthly,
                    used: estimated,
                    total: budgetUSD,
                    unit: "USD",
                    subtitle: "API-price estimate, not vendor billing"
                )
            )
        }

        guard !windows.isEmpty || taskWraith != nil else { throw ProviderFetchError.notConfigured }
        return QuotaSnapshot(
            providerID: .cerebras,
            displayName: ProviderID.cerebras.snapshotDisplayName,
            planName: fields[SpendProviderCredentialField.manualPlanName] ?? "Cloud",
            windows: windows,
            stats: taskWraith.map {
                [QuotaStat(label: "TaskWraith 35D estimate", value: $0.last35DaysCostUSD, unit: "USD", subtitle: "Not vendor billing")]
            } ?? [],
            balances: balances,
            events: taskWraith?.events ?? [],
            analyticsBuckets: csv?.analyticsBuckets ?? taskWraith?.analyticsBuckets ?? [],
            fetchState: .success
        )
    }

    private func latestCSV(at selectedURL: URL) -> URL? {
        if selectedURL.pathExtension.lowercased() == "csv" { return selectedURL }
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: selectedURL,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }
        return files
            .filter { $0.pathExtension.lowercased() == "csv" }
            .sorted {
                let lhs = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let rhs = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return lhs > rhs
            }
            .first
    }

    private func isCurrentCalendarMonthReport(_ report: CerebrasCSVUsageSummary, now: Date) -> Bool {
        guard let periodStart = report.periodStart, let periodEnd = report.periodEnd else { return false }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        guard let monthStart = calendar.date(
            from: calendar.dateComponents([.year, .month], from: now)
        ), let nextMonth = calendar.date(byAdding: .month, value: 1, to: monthStart) else {
            return false
        }
        return periodStart >= monthStart && periodEnd < nextMonth
    }
}

private func normalizedCurrency(_ value: String?) -> String {
    let normalized = value?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() ?? ""
    return normalized.isEmpty ? "USD" : normalized
}

private func boundedFileData(at url: URL, maximumBytes: Int) -> Data? {
    guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
          values.isRegularFile == true,
          let fileSize = values.fileSize,
          fileSize >= 0,
          fileSize <= maximumBytes else {
        return nil
    }
    return try? Data(contentsOf: url, options: .mappedIfSafe)
}

private func positiveDouble(_ value: String?) -> Double? {
    guard let result = nonnegativeDouble(value), result > 0 else { return nil }
    return result
}

private func nonnegativeDouble(_ value: String?) -> Double? {
    guard let value else { return nil }
    let cleaned = value
        .replacingOccurrences(of: "$", with: "")
        .replacingOccurrences(of: "GBP", with: "", options: .caseInsensitive)
        .replacingOccurrences(of: "EUR", with: "", options: .caseInsensitive)
        .replacingOccurrences(of: ",", with: "")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    guard let result = Double(cleaned), result.isFinite, result >= 0 else { return nil }
    return result
}
