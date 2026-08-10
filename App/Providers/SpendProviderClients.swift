import Foundation

enum SpendProviderCredentialField {
    static let manualSpent = "manualSpent"
    static let manualAllowance = "manualAllowance"
    static let manualCurrency = "manualCurrency"
    static let manualResetAt = "manualResetAt"
    static let manualCurrentBalance = "manualCurrentBalance"
    static let manualTopUpTotal = "manualTopUpTotal"
    static let manualPaymentThreshold = "manualPaymentThreshold"
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

/// TaskWraith / AGBench Mistral catalogue rates (Vibe CLI DEFAULT_MODELS).
struct MistralModelRate: Equatable {
    let inputUsdPerMillion: Double
    let outputUsdPerMillion: Double

    static let medium = MistralModelRate(inputUsdPerMillion: 1.5, outputUsdPerMillion: 7.5)
    static let devstralSmall = MistralModelRate(inputUsdPerMillion: 0.1, outputUsdPerMillion: 0.3)

    /// Pricing lookup: aliases first, then exact seat ids, else fail-safe **medium**.
    static func lookup(_ model: String?) -> MistralModelRate {
        let trimmed = model?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        guard !trimmed.isEmpty, !trimmed.contains("/") else { return .medium }
        switch trimmed {
        case "devstral-small", "devstral-small-latest":
            return .devstralSmall
        case "mistral-medium-3.5", "mistral-vibe-cli-latest":
            return .medium
        default:
            return .medium
        }
    }

    func estimateUSD(inputTokens: Int, outputTokens: Int) -> Double {
        Double(max(inputTokens, 0)) / 1_000_000 * inputUsdPerMillion
            + Double(max(outputTokens, 0)) / 1_000_000 * outputUsdPerMillion
    }
}

enum MistralTokenEstimate {
    static let approxCharsPerToken = 4

    /// Matches TaskWraith `estimateTokensFromChars` / Vibe `approx_token_count`.
    static func estimateTokensFromChars(_ charCount: Int) -> Int {
        guard charCount > 0 else { return 0 }
        return Int(ceil(Double(charCount) / Double(approxCharsPerToken)))
    }

    static func estimateUsage(
        model: String?,
        promptChars: Int,
        responseChars: Int,
        extraOutputChars: Int = 0
    ) -> (inputTokens: Int, outputTokens: Int, totalTokens: Int, costUSD: Double) {
        let rate = MistralModelRate.lookup(model)
        let inputTokens = estimateTokensFromChars(promptChars)
        let outputTokens = estimateTokensFromChars(responseChars + max(extraOutputChars, 0))
        return (
            inputTokens,
            outputTokens,
            inputTokens + outputTokens,
            rate.estimateUSD(inputTokens: inputTokens, outputTokens: outputTokens)
        )
    }
}

/// Offline TaskWraith doctrine: unique message payload chars÷4 × catalogue rates.
///
/// Live TaskWraith cannot see ACP usage, so it projects `ceil(chars/4)` over the
/// host prompt + assistant/tool stream (not Vibe system/tools config). After the
/// fact, replaying every growing API context turn overcounts (~7× vs TW). Counting
/// each unique `messages.jsonl` payload char once empirically tracks TW's cycle
/// local spend. `session_cost` is ignored — it bills cumulative API prompt tokens
/// at full input price (including cache).
enum MistralSessionCostEstimator {
    struct Estimate {
        let inputTokens: Double
        let outputTokens: Double
        let costUSD: Double
        let source: UsageAnalyticsSource
        let note: String
    }

    private static let jsonlMaximumBytes = 2 * 1_048_576

    static func estimate(
        activeModel: String?,
        sessionPromptTokens: Double?,
        sessionCompletionTokens: Double?,
        sessionDirectory: URL
    ) -> Estimate {
        let rate = MistralModelRate.lookup(activeModel)
        let jsonlURL = sessionDirectory.appendingPathComponent("messages.jsonl", isDirectory: false)
        if let chars = uniqueMessageCharCounts(jsonlURL: jsonlURL) {
            let inputTokens = MistralTokenEstimate.estimateTokensFromChars(chars.input)
            let outputTokens = MistralTokenEstimate.estimateTokensFromChars(chars.output)
            return Estimate(
                inputTokens: Double(inputTokens),
                outputTokens: Double(outputTokens),
                costUSD: rate.estimateUSD(inputTokens: inputTokens, outputTokens: outputTokens),
                source: .localEstimate,
                note: "TaskWraith-style chars÷4 × catalogue"
            )
        }

        // Fallback when messages.jsonl is missing/too large: reprice vendor tokens
        // with the catalogue (never trust opaque session_cost / meta $/M).
        let input = Int(max(sessionPromptTokens ?? 0, 0))
        let output = Int(max(sessionCompletionTokens ?? 0, 0))
        return Estimate(
            inputTokens: Double(input),
            outputTokens: Double(output),
            costUSD: rate.estimateUSD(inputTokens: input, outputTokens: output),
            source: .localEstimate,
            note: "Catalogue × Vibe session tokens"
        )
    }

    /// UTF-16 code unit counts (JS `.length` / TaskWraith doctrine). Content is never retained.
    /// System prompt / tools_available are excluded — live TW meters host prompt + stream only.
    private static func uniqueMessageCharCounts(
        jsonlURL: URL
    ) -> (input: Int, output: Int)? {
        let values = try? jsonlURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values?.isRegularFile == true,
              let fileSize = values?.fileSize,
              fileSize >= 0,
              fileSize <= jsonlMaximumBytes else { return nil }

        var inputChars = 0
        var outputChars = 0

        guard let handle = try? FileHandle(forReadingFrom: jsonlURL) else { return nil }
        defer { try? handle.close() }

        var buffer = Data()
        let chunkSize = 256 * 1_024
        var parsedAnyLine = false
        while true {
            let chunk = handle.readData(ofLength: chunkSize)
            if chunk.isEmpty { break }
            buffer.append(chunk)
            while let newline = buffer.firstIndex(of: 0x0A) {
                let lineData = buffer.subdata(in: buffer.startIndex..<newline)
                buffer.removeSubrange(buffer.startIndex...newline)
                guard !lineData.isEmpty,
                      let object = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                      let role = (object["role"] as? String)?.lowercased() else { continue }
                parsedAnyLine = true
                accumulate(role: role, object: object, inputChars: &inputChars, outputChars: &outputChars)
            }
            if buffer.count > jsonlMaximumBytes { return nil }
        }
        if !buffer.isEmpty,
           let object = try? JSONSerialization.jsonObject(with: buffer) as? [String: Any],
           let role = (object["role"] as? String)?.lowercased() {
            parsedAnyLine = true
            accumulate(role: role, object: object, inputChars: &inputChars, outputChars: &outputChars)
        }

        guard parsedAnyLine || inputChars > 0 || outputChars > 0 else { return nil }
        return (inputChars, outputChars)
    }

    private static func accumulate(
        role: String,
        object: [String: Any],
        inputChars: inout Int,
        outputChars: inout Int
    ) {
        switch role {
        case "assistant":
            outputChars += utf16Count(object["content"])
            outputChars += utf16Count(object["reasoning_content"])
            outputChars += toolCallChars(object["tool_calls"])
        case "tool":
            inputChars += toolResultChars(object)
        default:
            // user / system / unknown → input lane
            inputChars += utf16Count(object["content"])
        }
    }

    private static func utf16Count(_ value: Any?) -> Int {
        guard let value else { return 0 }
        if let string = value as? String { return string.utf16.count }
        if let number = value as? NSNumber { return "\(number)".utf16.count }
        if JSONSerialization.isValidJSONObject(value),
           let data = try? JSONSerialization.data(withJSONObject: value),
           let text = String(data: data, encoding: .utf8) {
            return text.utf16.count
        }
        return 0
    }

    private static func toolCallChars(_ value: Any?) -> Int {
        guard let calls = value as? [Any] else { return utf16Count(value) }
        var total = 0
        for call in calls {
            guard let object = call as? [String: Any] else {
                total += utf16Count(call)
                continue
            }
            let function = object["function"] as? [String: Any]
            total += utf16Count(function?["name"] ?? object["name"])
            total += utf16Count(function?["arguments"] ?? object["arguments"] ?? object["input"])
        }
        return total
    }

    private static func toolResultChars(_ object: [String: Any]) -> Int {
        let content = utf16Count(object["content"])
        if content > 0 { return content }
        return utf16Count(object["tool_result"] ?? object["output"])
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
        var note = "TaskWraith-style chars÷4 × catalogue"
    }

    /// Bump when local cost doctrine changes so watermarked manual anchors rebase.
    static let estimateDoctrineVersion = "tw-est-v1"

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

            let activeModel = meta.config?.activeModel?.trimmingCharacters(in: .whitespacesAndNewlines)
                .nilIfEmpty
            let estimate = MistralSessionCostEstimator.estimate(
                activeModel: activeModel,
                sessionPromptTokens: stats.sessionPromptTokens,
                sessionCompletionTokens: stats.sessionCompletionTokens,
                sessionDirectory: candidate.url.deletingLastPathComponent()
            )
            let input = estimate.inputTokens
            let output = estimate.outputTokens
            let cost = max(estimate.costUSD, 0)
            let model = activeModel ?? "Mistral Vibe"
            let day = utcCalendar.startOfDay(for: timestamp)
            let key = DailyKey(start: day, model: model)
            var value = daily[key] ?? DailyValue()
            value.inputTokens += input
            value.outputTokens += output
            value.costUSD += cost
            value.requests += 1
            value.note = estimate.note
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
                source: .localEstimate,
                note: value.note
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

/// Resolves the subscription pool that Vibe Code actually consumes.
///
/// Mistral's subscription page now exposes the shared "Included monthly usage"
/// pool and a separate Vibe Code budget. Older Limit Counter credentials stored
/// the shared Pro allowance (EUR 25.50) as the Mistral meter's ceiling. Keep the
/// migration narrow: only the known legacy Pro/Team figure is rewritten, while
/// any other user-entered allowance remains authoritative.
enum MistralVibeBudgetResolver {
    private static let unitsPerUSD: [String: Double] = [
        "USD": 1,
        "EUR": 0.92,
        "GBP": 0.79
    ]

    private static let legacySharedPoolUSD = 27.8
    private static let legacySharedPoolEUR = 25.5
    private static let legacyTolerance = 0.05

    static func effectiveAllowance(
        rawAllowance: Double?,
        currency: String,
        planName: String?,
        configuredBudgetUSD: Double?
    ) -> Double? {
        if isLegacySharedPoolAllowance(rawAllowance, currency: currency, planName: planName) {
            return defaultAllowance(currency: currency, planName: planName, configuredBudgetUSD: configuredBudgetUSD)
        }
        if let rawAllowance, rawAllowance > 0 { return rawAllowance }
        return defaultAllowance(currency: currency, planName: planName, configuredBudgetUSD: configuredBudgetUSD)
    }

    /// The old anchor's spend belongs to the shared pool, not the new Vibe bar.
    /// Keep a larger manual value because it is likely a fresh Vibe-console
    /// reading entered after the budget split.
    static func shouldDiscardLegacyAnchor(
        rawAllowance: Double?,
        rawSpent: Double?,
        currency: String,
        planName: String?
    ) -> Bool {
        guard isLegacySharedPoolAllowance(rawAllowance, currency: currency, planName: planName) else {
            return false
        }
        guard let rawSpent else { return true }
        return rawSpent <= legacySharedPoolAllowance(currency: currency) + legacyTolerance
    }

    static func convert(_ amount: Double, from sourceCurrency: String, to targetCurrency: String) -> Double? {
        guard let sourceRate = unitsPerUSD[sourceCurrency.uppercased()],
              let targetRate = unitsPerUSD[targetCurrency.uppercased()] else {
            return nil
        }
        return amount / sourceRate * targetRate
    }

    static func amountInCurrency(_ usd: Double, currency: String) -> Double? {
        guard let rate = unitsPerUSD[currency.uppercased()] else { return nil }
        return usd * rate
    }

    private static func defaultAllowance(
        currency: String,
        planName: String?,
        configuredBudgetUSD: Double?
    ) -> Double? {
        if let configuredBudgetUSD, configuredBudgetUSD > 0,
           let configured = amountInCurrency(configuredBudgetUSD, currency: currency) {
            return configured
        }

        let normalizedPlan = planName?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        let isProOrTeam = normalizedPlan.contains("pro") || normalizedPlan.contains("team")
        let isFree = normalizedPlan.contains("free")
        let usdBudget = isProOrTeam ? 278.0 : 9.25

        switch currency.uppercased() {
        case "EUR":
            return isProOrTeam ? 255 : (isFree || normalizedPlan.isEmpty ? 8.5 : usdBudget * 0.92)
        case "USD":
            return usdBudget
        case "GBP":
            return amountInCurrency(usdBudget, currency: "GBP")
        default:
            return nil
        }
    }

    private static func isLegacySharedPoolAllowance(
        _ rawAllowance: Double?,
        currency: String,
        planName: String?
    ) -> Bool {
        guard let rawAllowance, rawAllowance > 0 else { return false }
        let normalizedPlan = planName?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        guard normalizedPlan.contains("pro") || normalizedPlan.contains("team") else { return false }
        let expected = legacySharedPoolAllowance(currency: currency)
        return abs(rawAllowance - expected) <= max(legacyTolerance, expected * 0.01)
    }

    private static func legacySharedPoolAllowance(currency: String) -> Double {
        switch currency.uppercased() {
        case "EUR": return legacySharedPoolEUR
        case "USD": return legacySharedPoolUSD
        default: return legacySharedPoolUSD * (unitsPerUSD[currency.uppercased()] ?? 1)
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

        let rawManualAllowance = positiveDouble(fields[SpendProviderCredentialField.manualAllowance])
            ?? positiveDouble(credentials?.normalizedAccountIdentifier)
        let rawManualSpend = nonnegativeDouble(fields[SpendProviderCredentialField.manualSpent])
        let manualCurrency = normalizedCurrency(fields[SpendProviderCredentialField.manualCurrency])
        let manualReset = ProviderDateParser.parse(fields[SpendProviderCredentialField.manualResetAt])
        let budgetUSD = ProviderMonthlyBudgetStore.nonisolatedBudgetUSD(for: .mistral)
        let planName = fields[SpendProviderCredentialField.manualPlanName]
        let manualAllowance = MistralVibeBudgetResolver.effectiveAllowance(
            rawAllowance: rawManualAllowance,
            currency: manualCurrency,
            planName: planName,
            configuredBudgetUSD: budgetUSD
        )
        let discardedLegacyAnchor = MistralVibeBudgetResolver.shouldDiscardLegacyAnchor(
            rawAllowance: rawManualAllowance,
            rawSpent: rawManualSpend,
            currency: manualCurrency,
            planName: planName
        )
        let manualSpend = discardedLegacyAnchor ? nil : rawManualSpend
        var windows: [QuotaWindow] = []
        var stats: [QuotaStat] = []
        var signals: [QuotaSignal] = []

        if let admin {
            let adminSpend = admin.vibeSpend ?? (admin.totalSpendIsComplete ? admin.totalSpend : nil)
            let adminAllowance = manualAllowance.flatMap {
                MistralVibeBudgetResolver.convert($0, from: manualCurrency, to: admin.currency)
            } ?? (admin.currency == "USD" ? budgetUSD : nil)
            if let adminSpend {
                let isVibeSpecific = admin.vibeSpend != nil
                windows.append(
                    QuotaWindow(
                        label: isVibeSpecific ? "Vibe Code this billing period" : "Mistral usage this billing period",
                        windowKind: .monthly,
                        used: adminSpend,
                        total: adminAllowance,
                        resetDate: admin.periodEnd,
                        unit: admin.currency,
                        subtitle: isVibeSpecific
                            ? "Official Mistral Admin API Vibe usage"
                            : "Official Mistral Admin API total; Vibe breakdown unavailable"
                    )
                )
            }
        }

        if windows.isEmpty, let manualSpend {
            if let manualReset, manualReset <= now {
                signals.append(
                    QuotaSignal(
                        kind: .scheduledReset,
                        title: "Billing anchor expired",
                        message: "Update the Mistral Vibe Code reading for the new billing cycle.",
                        severity: .info,
                        confidence: 1,
                        windowLabel: "Vibe Code this billing period",
                        detectedAt: now
                    )
                )
            } else {
                let baseSignature = fields[SpendProviderCredentialField.anchorUpdatedAt]
                    ?? "\(manualSpend)|\(rawManualAllowance ?? 0)|\(manualReset?.timeIntervalSince1970 ?? 0)"
                // Doctrine version forces a watermark rebase when local cost math changes.
                let signature = "\(MistralVibeUsageReader.estimateDoctrineVersion)|\(baseSignature)"
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
                        label: "Vibe Code this billing period",
                        windowKind: .monthly,
                        used: adjustment.spend,
                        total: manualAllowance,
                        resetDate: manualReset,
                        unit: manualCurrency,
                        subtitle: adjustment.localIncrement > 0
                            ? "Manual Vibe reading plus TaskWraith-style local estimate"
                            : "Manual Vibe reading"
                    )
                )
            }
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
                let localCurrency = manualCurrency
                let localSpend = MistralVibeBudgetResolver.amountInCurrency(
                    local.currentMonthCostUSD,
                    currency: localCurrency
                ) ?? local.currentMonthCostUSD
                windows.append(
                    QuotaWindow(
                        label: "Vibe Code this billing period",
                        windowKind: .monthly,
                        used: localSpend,
                        total: manualAllowance,
                        unit: localCurrency,
                        subtitle: discardedLegacyAnchor
                            ? "TaskWraith-style local estimate; legacy shared-pool anchor ignored"
                            : "TaskWraith-style local estimate"
                    )
                )
            }
            stats.append(contentsOf: [
                QuotaStat(
                    label: "Local 30D cost",
                    value: local.last30DaysCostUSD,
                    unit: "USD",
                    subtitle: "TaskWraith-style chars÷4 × catalogue"
                ),
                QuotaStat(label: "Input tokens", value: local.inputTokens, unit: "tokens", subtitle: "Estimated"),
                QuotaStat(label: "Output tokens", value: local.outputTokens, unit: "tokens", subtitle: "Estimated")
            ])
        }

        guard !windows.isEmpty || local != nil else { throw ProviderFetchError.notConfigured }
        return QuotaSnapshot(
            providerID: .mistral,
            displayName: ProviderID.mistral.snapshotDisplayName,
            planName: planName ?? (admin == nil ? "Vibe" : "Admin API"),
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
        let usageKind: String?

        enum CodingKeys: String, CodingKey {
            case provider, model, timestamp, inputTokens, outputTokens
            case cacheReadInputTokens, cacheCreationInputTokens, usageKind
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
        guard provider == .deepseek || provider == .cerebras || provider == .meta,
              let records = try? JSONDecoder().decode([Record].self, from: data) else { return nil }

        let cutoff = now.addingTimeInterval(-35 * 86_400)
        var daily: [DailyKey: DailyValue] = [:]
        var events: [UsageEvent] = []
        let isMeta = provider == .meta
        for record in records {
            let timestampMs = record.timestamp
            let timestamp: Date
            let model: String
            let input: Double
            let output: Double
            let cached: Double
            let cacheCreation: Double
            let cost: Double

            if isMeta {
                guard record.provider?.lowercased() == "muse",
                      let timestampMs else { continue }
                if record.usageKind?.lowercased() == "reset_hint" { continue }
                timestamp = Date(timeIntervalSince1970: timestampMs / 1_000)
                guard timestamp >= cutoff else { continue }
                model = record.model?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
                    ?? "muse-spark-1.2"
                input = max(record.inputTokens ?? 0, 0)
                output = max(record.outputTokens ?? 0, 0)
                cached = max(record.cacheReadInputTokens ?? 0, 0)
                cacheCreation = max(record.cacheCreationInputTokens ?? 0, 0)
                let home = museDefaultDataHomeURL()
                let rate = MuseModelCatalogRateLoader.load(from: home, modelId: model)
                    ?? MuseModelRate.defaultRate(for: model)
                cost = MuseCostEstimator.estimateUSD(
                    input: input,
                    output: output,
                    cacheRead: cached,
                    cacheCreation: cacheCreation,
                    rate: rate
                )
            } else {
                guard record.provider?.lowercased() == "pi",
                      let lowered = record.model?.lowercased(),
                      lowered.hasPrefix(provider == .deepseek ? "deepseek/" : "cerebras/"),
                      let timestampMs,
                      let rate = rate(for: lowered) else { continue }
                timestamp = Date(timeIntervalSince1970: timestampMs / 1_000)
                guard timestamp >= cutoff else { continue }
                model = lowered
                input = max(record.inputTokens ?? 0, 0)
                output = max(record.outputTokens ?? 0, 0)
                cached = max(record.cacheReadInputTokens ?? 0, 0)
                cacheCreation = max(record.cacheCreationInputTokens ?? 0, 0)
                cost = (input + cacheCreation) / 1_000_000 * rate.input
                    + output / 1_000_000 * rate.output
                    + cached / 1_000_000 * rate.cachedInput
            }

            let dayCalendar = isMeta ? Calendar.current : utcCalendar
            let date = dayCalendar.startOfDay(for: timestamp)
            let key = DailyKey(date: date, model: model)
            var value = daily[key] ?? DailyValue()
            value.input += isMeta ? input : input + cacheCreation
            value.output += output
            value.cached += cached
            value.requests += 1
            value.cost += cost
            daily[key] = value
            let tokenTotal = input + output + cached + (isMeta ? 0 : cacheCreation)
            events.append(
                UsageEvent(
                    timestamp: timestamp,
                    tokens: tokenTotal > 0 ? tokenTotal : nil,
                    model: model,
                    type: .telemetry
                )
            )
        }

        guard !daily.isEmpty else { return nil }
        let bucketCalendar = isMeta ? Calendar.current : utcCalendar
        let note = isMeta
            ? "Muse session tokens × catalog rates"
            : "TaskWraith tokens priced with vendor rates checked 2026-08-01"
        let buckets = daily.map { key, value in
            UsageAnalyticsBucket(
                startDate: key.date,
                endDate: bucketCalendar.date(byAdding: .day, value: 1, to: key.date)
                    ?? key.date.addingTimeInterval(86_400),
                model: key.model,
                inputTokens: value.input,
                outputTokens: value.output,
                cachedInputTokens: value.cached,
                requests: value.requests,
                costUSD: value.cost,
                source: .localEstimate,
                note: note
            )
        }.sorted { $0.startDate > $1.startDate }
        // Meta soft $15 budget matches TaskWraith: local calendar month, not UTC.
        let monthCalendar = isMeta ? Calendar.current : utcCalendar
        let monthStart = monthCalendar.date(
            from: monthCalendar.dateComponents([.year, .month], from: now)
        ) ?? monthCalendar.startOfDay(for: now)
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

// MARK: - Meta / Muse local metering

struct MuseModelRate: Equatable {
    let inputUsdPerMillion: Double
    let outputUsdPerMillion: Double
    let cachedUsdPerMillion: Double
    let currency: String

    static let sparkDefault = MuseModelRate(
        inputUsdPerMillion: 1.25,
        outputUsdPerMillion: 4.25,
        cachedUsdPerMillion: 0.15,
        currency: "USD"
    )

    /// Baked-in rates for muse-spark-1.2 / muse-default / any muse-* id.
    static func defaultRate(for modelId: String?) -> MuseModelRate {
        let id = modelId?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        if id.isEmpty || id.hasPrefix("muse-") || id == "muse-default" || id == "muse-spark-1.2" {
            return .sparkDefault
        }
        return .sparkDefault
    }
}

enum MuseCostEstimator {
    /// Muse billable formula matching MuseUsage.ts session.jsonl metering:
    /// cache-read is priced at the cached rate and subtracted from billable input
    /// when cache-read is known.
    ///
    /// `cacheCreation` is for TaskWraith journaled Muse rows
    /// (`estimateUsageRecordCostUsd` / RemoteModelUsageProjection). When > 0 it adds
    /// `cacheCreation/1e6 * rate.inputUsdPerMillion` on top of the Muse session formula.
    /// Live Muse session metering should pass 0 (MuseUsage.ts does not price cache write).
    static func estimateUSD(
        input: Double,
        output: Double,
        cacheRead: Double,
        cacheCreation: Double = 0,
        rate: MuseModelRate
    ) -> Double {
        let inputTokens = nonNegative(input)
        let outputTokens = nonNegative(output)
        let cacheReadTokens = nonNegative(cacheRead)
        let cacheCreationTokens = nonNegative(cacheCreation)
        let billableInput = cacheReadTokens > 0
            ? max(0, inputTokens - cacheReadTokens)
            : inputTokens
        var usd = billableInput / 1_000_000 * rate.inputUsdPerMillion
            + cacheReadTokens / 1_000_000 * rate.cachedUsdPerMillion
            + outputTokens / 1_000_000 * rate.outputUsdPerMillion
        if cacheCreationTokens > 0 {
            usd += cacheCreationTokens / 1_000_000 * rate.inputUsdPerMillion
        }
        return usd.isFinite ? usd : 0
    }

    private static func nonNegative(_ value: Double) -> Double {
        value.isFinite && value > 0 ? value : 0
    }
}

enum MuseModelCatalogRateLoader {
    static func load(from dataHomeURL: URL, modelId: String) -> MuseModelRate? {
        let id = modelId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return nil }
        let root = normalizedMuseDataHomeURL(dataHomeURL)
        let catalogDir = root.appendingPathComponent("model-catalog", isDirectory: true)
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: catalogDir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return nil }

        for fileURL in entries where fileURL.pathExtension.lowercased() == "json" {
            guard let data = boundedFileData(at: fileURL, maximumBytes: 4 * 1_024 * 1_024),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let rows = json["rows"] as? [Any] else { continue }
            for row in rows {
                guard let record = row as? [String: Any] else { continue }
                let mid = stringValue(record["model_id"])
                    ?? stringValue(record["id"])
                    ?? stringValue(record["model"])
                guard mid == id, let rate = parseCost(record["cost"]) else { continue }
                return rate
            }
        }
        return nil
    }

    static func parseCost(_ cost: Any?) -> MuseModelRate? {
        guard let record = cost as? [String: Any] else { return nil }
        guard let input = finiteNumber(record["input"]),
              let output = finiteNumber(record["output"]),
              let cached = finiteNumber(record["cached"]),
              input >= 0, output >= 0, cached >= 0 else { return nil }
        let currency = stringValue(record["currency"])?.uppercased() ?? "USD"
        return MuseModelRate(
            inputUsdPerMillion: input,
            outputUsdPerMillion: output,
            cachedUsdPerMillion: cached,
            currency: currency
        )
    }

    private static func finiteNumber(_ value: Any?) -> Double? {
        switch value {
        case let number as Double:
            return number.isFinite ? number : nil
        case let number as Int:
            return Double(number)
        case let number as NSNumber:
            let double = number.doubleValue
            return double.isFinite ? double : nil
        case let text as String:
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let double = Double(trimmed), double.isFinite else { return nil }
            return double
        default:
            return nil
        }
    }

    private static func stringValue(_ value: Any?) -> String? {
        guard let text = value as? String else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

struct MuseMeterSnapshot: Equatable {
    var museSessionId: String
    var model: String?
    var inputTokens: Double
    var outputTokens: Double
    var cacheReadInputTokens: Double
    var cacheCreationInputTokens: Double
    var reasoningTokens: Double
    var totalTokens: Double
    var durationMs: Double
    var estimatedCostUSD: Double?
    var usageIds: [String]
    var latestRecordedAt: Date?
}

struct MuseSessionUsageReducer {
    private struct RunAccum {
        var inputTokens = 0.0
        var outputTokens = 0.0
        var cachedTokens = 0.0
        var reasoningTokens = 0.0
        var cacheReadTokens = 0.0
        var cacheWriteTokens = 0.0
        var durationMs = 0.0
        var model: String?
        var usageIds: [String] = []
        var hasCompletedCache = false
    }

    let museSessionId: String
    let logPath: String
    private var seenEnvelopeKeys = Set<String>()
    private var seenUsageKeys = Set<String>()
    private var byRunId: [String: RunAccum] = [:]
    private(set) var latestRecordedAt: Date?

    init(museSessionId: String, logPath: String) {
        self.museSessionId = museSessionId
        self.logPath = logPath
    }

    mutating func ingestLine(_ line: String) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let data = trimmed.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }
        ingestEnvelope(object)
    }

    mutating func ingestEnvelope(_ envelope: [String: Any]) {
        let stream = envelope["stream"] as? [String: Any]
        let streamId = stringValue(stream?["id"]) ?? ""
        let sequence = finiteNumber(envelope["sequence"]).map { String(Int($0)) } ?? "0"
        let envelopeId = stringValue(envelope["id"])
        let dedupeKey = envelopeId ?? "\(streamId):\(sequence)"
        if seenEnvelopeKeys.contains(dedupeKey) { return }
        seenEnvelopeKeys.insert(dedupeKey)

        if let recorded = museRecordedAtDate(envelope["recorded_at"]) {
            if let previous = latestRecordedAt {
                latestRecordedAt = max(previous, recorded)
            } else {
                latestRecordedAt = recorded
            }
        }

        guard stringValue(envelope["payload_type"]) == "runtime.session",
              let payload = envelope["payload"] as? [String: Any],
              let event = payload["event"] as? [String: Any] else { return }

        let kind = stringValue(event["kind"])
        let runId = stringValue(payload["run_id"]) ?? "unknown"

        if kind == "goal_usage_attribution" {
            guard let record = event["record"] as? [String: Any],
                  stringValue(record["usage_family"]) == "provider",
                  let quantity = record["quantity"] as? [String: Any],
                  boolValue(quantity["reported"]) == true else { return }
            let usageId = stringValue(record["usage_id"]) ?? dedupeKey
            let usageKey = "\(logPath)::\(usageId)"
            if seenUsageKeys.contains(usageKey) { return }
            seenUsageKeys.insert(usageKey)

            var row = byRunId[runId] ?? RunAccum()
            row.inputTokens += nonNegative(finiteNumber(quantity["input_tokens"]))
            row.outputTokens += nonNegative(finiteNumber(quantity["output_tokens"]))
            row.cachedTokens += nonNegative(finiteNumber(quantity["cached_tokens"]))
            row.reasoningTokens += nonNegative(finiteNumber(quantity["reasoning_tokens"]))
            row.usageIds.append(usageId)
            byRunId[runId] = row
            return
        }

        if kind == "model_completed" {
            var row = byRunId[runId] ?? RunAccum()
            if let usage = event["usage"] as? [String: Any] {
                // Enrich only — tokens already counted from goal_usage_attribution.
                row.cacheReadTokens += nonNegative(finiteNumber(usage["cache_read_tokens"]))
                row.cacheWriteTokens += nonNegative(finiteNumber(usage["cache_write_tokens"]))
                row.hasCompletedCache = true
                if row.reasoningTokens <= 0 {
                    row.reasoningTokens = nonNegative(finiteNumber(usage["reasoning_tokens"]))
                }
            }
            row.durationMs += nonNegative(finiteNumber(event["duration_ms"]))
            if let model = stringValue(event["model"]) {
                row.model = model
            }
            byRunId[runId] = row
        }
    }

    func snapshot(rate: MuseModelRate? = nil) -> MuseMeterSnapshot {
        var inputTokens = 0.0
        var outputTokens = 0.0
        var cacheReadInputTokens = 0.0
        var cacheCreationInputTokens = 0.0
        var reasoningTokens = 0.0
        var durationMs = 0.0
        var model: String?
        var usageIds: [String] = []
        var anyCompletedCache = false
        var cachedTokensFallback = 0.0

        for row in byRunId.values {
            inputTokens += row.inputTokens
            outputTokens += row.outputTokens
            reasoningTokens += row.reasoningTokens
            durationMs += row.durationMs
            usageIds.append(contentsOf: row.usageIds)
            if let rowModel = row.model { model = rowModel }
            if row.hasCompletedCache {
                anyCompletedCache = true
                cacheReadInputTokens += row.cacheReadTokens
                cacheCreationInputTokens += row.cacheWriteTokens
            } else {
                cachedTokensFallback += row.cachedTokens
            }
        }
        if !anyCompletedCache, cachedTokensFallback > 0 {
            cacheReadInputTokens = cachedTokensFallback
        }

        let hasReported = !usageIds.isEmpty
        let estimatedCostUSD: Double? = {
            guard hasReported, let rate else { return nil }
            // Live Muse session metering: cacheCreation stays 0 (MuseUsage.ts).
            return MuseCostEstimator.estimateUSD(
                input: inputTokens,
                output: outputTokens,
                cacheRead: cacheReadInputTokens,
                cacheCreation: 0,
                rate: rate
            )
        }()

        return MuseMeterSnapshot(
            museSessionId: museSessionId,
            model: model,
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            cacheReadInputTokens: cacheReadInputTokens,
            cacheCreationInputTokens: cacheCreationInputTokens,
            reasoningTokens: reasoningTokens,
            totalTokens: inputTokens + outputTokens,
            durationMs: durationMs,
            estimatedCostUSD: estimatedCostUSD,
            usageIds: usageIds,
            latestRecordedAt: latestRecordedAt
        )
    }

    private func stringValue(_ value: Any?) -> String? {
        guard let text = value as? String else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func finiteNumber(_ value: Any?) -> Double? {
        switch value {
        case let number as Double:
            return number.isFinite ? number : nil
        case let number as Int:
            return Double(number)
        case let number as NSNumber:
            let double = number.doubleValue
            return double.isFinite ? double : nil
        case let text as String:
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let double = Double(trimmed), double.isFinite else { return nil }
            return double
        default:
            return nil
        }
    }

    private func boolValue(_ value: Any?) -> Bool? {
        switch value {
        case let flag as Bool:
            return flag
        case let number as NSNumber:
            return number.boolValue
        default:
            return nil
        }
    }

    private func nonNegative(_ value: Double?) -> Double {
        guard let value, value.isFinite, value > 0 else { return 0 }
        return value
    }

    /// Muse `recorded_at` is microseconds since epoch.
    private func museRecordedAtDate(_ value: Any?) -> Date? {
        guard let raw = finiteNumber(value), raw > 0 else { return nil }
        return Date(timeIntervalSince1970: raw / 1_000_000)
    }
}

struct MuseLocalUsageSummary {
    struct CostObservation {
        let timestamp: Date
        let costUSD: Double
    }

    let currentMonthCostUSD: Double
    let last30DaysCostUSD: Double
    let inputTokens: Double
    let outputTokens: Double
    let cachedTokens: Double
    let events: [UsageEvent]
    let analyticsBuckets: [UsageAnalyticsBucket]
    let costObservations: [CostObservation]
    /// True when the Muse data home folder exists (even with zero sessions).
    let dataHomeConfigured: Bool

    func costUSD(since date: Date) -> Double {
        costObservations
            .filter { $0.timestamp > date }
            .reduce(0) { $0 + $1.costUSD }
    }
}

enum MuseLocalUsageReader {
    private static let maxSessionFiles = 5_000
    /// Full-file read / streaming prefix budget.
    private static let maxPrefixBytes = 8 * 1_024 * 1_024
    /// Skip session files larger than this entirely.
    private static let maxHardSkipBytes = 32 * 1_024 * 1_024

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

    /// UTF-8 session.jsonl text, fully for files ≤ `maximumBytes`, otherwise the leading
    /// `maximumBytes` with any incomplete trailing line dropped.
    static func sessionJSONLText(at url: URL, maximumBytes: Int) -> String? {
        if let data = boundedFileData(at: url, maximumBytes: maximumBytes),
           let text = String(data: data, encoding: .utf8) {
            return text
        }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let data = handle.readData(ofLength: maximumBytes)
        guard !data.isEmpty else { return nil }
        var text = String(decoding: data, as: UTF8.self)
        // Only drop a trailing incomplete line when this is a truncated prefix read.
        if data.count >= maximumBytes {
            if let lastNewline = text.lastIndex(of: "\n") {
                text = String(text[..<lastNewline])
            } else {
                // Prefix ended mid-line with no complete JSONL record.
                return nil
            }
        }
        return text.isEmpty ? nil : text
    }

    static func read(rootURL: URL, now: Date = Date()) -> MuseLocalUsageSummary? {
        let dataHome = normalizedMuseDataHomeURL(rootURL)
        let sessionsRoot = dataHome.appendingPathComponent("sessions", isDirectory: true)
        let dataHomeConfigured = FileManager.default.fileExists(atPath: dataHome.path)
        guard dataHomeConfigured else { return nil }

        // Soft Meta / TaskWraith $15 budget resets on the local calendar month.
        let calendar = Calendar.current
        let monthStart = calendar.date(from: calendar.dateComponents([.year, .month], from: now))
            ?? calendar.startOfDay(for: now)
        let thirtyDayCutoff = now.addingTimeInterval(-30 * 86_400)
        let scanCutoff = now.addingTimeInterval(-40 * 86_400)

        var candidates: [(url: URL, modified: Date)] = []
        if FileManager.default.fileExists(atPath: sessionsRoot.path),
           let enumerator = FileManager.default.enumerator(
            at: sessionsRoot,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
           ) {
            for case let fileURL as URL in enumerator {
                guard fileURL.lastPathComponent == "session.jsonl" else { continue }
                let values = try? fileURL.resourceValues(
                    forKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]
                )
                guard values?.isRegularFile == true else { continue }
                if let size = values?.fileSize, size > maxHardSkipBytes { continue }
                let modified = values?.contentModificationDate ?? .distantPast
                if modified < scanCutoff { continue }
                candidates.append((fileURL, modified))
            }
        }

        candidates.sort { $0.modified > $1.modified }
        var daily: [DailyKey: DailyValue] = [:]
        var events: [UsageEvent] = []
        var costObservations: [MuseLocalUsageSummary.CostObservation] = []

        for candidate in candidates.prefix(maxSessionFiles) {
            guard let text = sessionJSONLText(at: candidate.url, maximumBytes: maxPrefixBytes) else {
                continue
            }

            let sessionId = candidate.url.deletingLastPathComponent().lastPathComponent
            var reducer = MuseSessionUsageReducer(
                museSessionId: sessionId,
                logPath: candidate.url.path
            )
            for line in text.split(whereSeparator: \.isNewline) {
                reducer.ingestLine(String(line))
            }

            let provisional = reducer.snapshot(rate: nil)
            guard !provisional.usageIds.isEmpty else { continue }
            let model = provisional.model ?? "muse-spark-1.2"
            let rate = MuseModelCatalogRateLoader.load(from: dataHome, modelId: model)
                ?? MuseModelRate.defaultRate(for: model)
            let snap = reducer.snapshot(rate: rate)
            let timestamp = snap.latestRecordedAt ?? candidate.modified
            guard timestamp >= scanCutoff else { continue }

            let cost = snap.estimatedCostUSD ?? 0
            let day = calendar.startOfDay(for: timestamp)
            let key = DailyKey(date: day, model: model)
            var value = daily[key] ?? DailyValue()
            value.input += snap.inputTokens
            value.output += snap.outputTokens
            value.cached += snap.cacheReadInputTokens
            value.requests += 1
            value.cost += cost
            daily[key] = value
            costObservations.append(.init(timestamp: timestamp, costUSD: cost))
            let tokens = snap.totalTokens
            events.append(
                UsageEvent(
                    timestamp: timestamp,
                    tokens: tokens > 0 ? tokens : nil,
                    model: model,
                    type: .telemetry
                )
            )
        }

        let buckets = daily.map { key, value in
            UsageAnalyticsBucket(
                startDate: key.date,
                endDate: calendar.date(byAdding: .day, value: 1, to: key.date)
                    ?? key.date.addingTimeInterval(86_400),
                model: key.model,
                inputTokens: value.input,
                outputTokens: value.output,
                cachedInputTokens: value.cached,
                requests: value.requests,
                costUSD: value.cost,
                source: .localEstimate,
                note: "Muse session tokens × catalog rates"
            )
        }.sorted { $0.startDate > $1.startDate }

        return MuseLocalUsageSummary(
            currentMonthCostUSD: buckets
                .filter { $0.startDate >= monthStart }
                .compactMap(\.costUSD)
                .reduce(0, +),
            last30DaysCostUSD: buckets
                .filter { $0.endDate >= thirtyDayCutoff }
                .compactMap(\.costUSD)
                .reduce(0, +),
            inputTokens: buckets.reduce(0) { $0 + $1.inputTokens },
            outputTokens: buckets.reduce(0) { $0 + $1.outputTokens },
            cachedTokens: buckets.reduce(0) { $0 + $1.cachedInputTokens },
            events: events.sorted { $0.timestamp > $1.timestamp },
            analyticsBuckets: buckets,
            costObservations: costObservations,
            dataHomeConfigured: true
        )
    }
}

enum MetaBillingReset {
    /// First instant of the next local calendar month (TaskWraith soft-budget reset).
    static func nextResetDate(from now: Date, calendar: Calendar = .current) -> Date {
        let monthStart = calendar.date(from: calendar.dateComponents([.year, .month], from: now))
            ?? calendar.startOfDay(for: now)
        return calendar.date(byAdding: .month, value: 1, to: monthStart)
            ?? now.addingTimeInterval(30 * 86_400)
    }
}

/// Accumulates post-anchor Muse projected spend on top of a Meta console "Spend to date" reading.
enum MetaSpendWatermarkStore {
    struct Adjustment {
        let spend: Double
        let localIncrement: Double
    }

    private static let appGroupID = "group.com.chrisizatt.LLMUsageCounter"
    private static let signatureKey = "meta.spendWatermark.signature"
    private static let localCostKey = "meta.spendWatermark.localCostUSD"
    private static let localMonthKey = "meta.spendWatermark.localCostMonth"
    private static let accumulatedCostKey = "meta.spendWatermark.accumulatedLocalCostUSD"
    private static let hasBaselineKey = "meta.spendWatermark.hasLocalBaseline"

    private static let unitsPerUSD: [String: Double] = [
        "USD": 1,
        "EUR": 0.92,
        "GBP": 0.79
    ]

    /// Converts a USD amount into the user's billing currency using the same rates as spend accumulation.
    static func amountInCurrency(_ usd: Double, currency: String) -> Double? {
        guard let rate = unitsPerUSD[currency.uppercased()] else { return nil }
        return usd * rate
    }

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

    /// Soft Meta budget resets on the local calendar month.
    private static func monthKey(for date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month], from: date)
        return String(format: "%04d-%02d", parts.year ?? 0, parts.month ?? 0)
    }
}

/// Auto-decrements a manual Meta remaining-balance anchor by post-anchor Muse observed spend.
enum MetaRemainingWatermarkStore {
    struct Adjustment {
        let effectiveRemaining: Double
        /// Amount subtracted from remaining in billing currency (USD/EUR/GBP) due to local Muse spend since the anchor.
        let localDecrementUSD: Double
    }

    private static let appGroupID = "group.com.chrisizatt.LLMUsageCounter"
    private static let signatureKey = "meta.remainingWatermark.signature"
    private static let observedKey = "meta.remainingWatermark.observedMonthUSD"
    private static let monthKeyName = "meta.remainingWatermark.localMonth"
    private static let accumulatedKey = "meta.remainingWatermark.accumulatedDecrementUSD"

    /// Same FX table as `MetaSpendWatermarkStore` (USD=1, EUR=0.92, GBP=0.79).
    private static let unitsPerUSD: [String: Double] = [
        "USD": 1,
        "EUR": 0.92,
        "GBP": 0.79
    ]

    static func adjustment(
        anchoredRemaining: Double,
        currentObservedMonthUSD: Double?,
        currency: String,
        signature: String,
        now: Date = Date(),
        defaults overrideDefaults: UserDefaults? = nil
    ) -> Adjustment {
        // Unknown billing currency: keep the console remaining as-is (no auto-decrement).
        guard let conversionRate = unitsPerUSD[currency.uppercased()] else {
            return Adjustment(effectiveRemaining: max(0, anchoredRemaining), localDecrementUSD: 0)
        }
        let defaults = overrideDefaults ?? UserDefaults(suiteName: appGroupID) ?? .standard
        guard defaults.string(forKey: signatureKey) == signature else {
            defaults.set(signature, forKey: signatureKey)
            defaults.set(0.0, forKey: accumulatedKey)
            if let currentObservedMonthUSD {
                defaults.set(currentObservedMonthUSD, forKey: observedKey)
                defaults.set(monthKey(for: now), forKey: monthKeyName)
            } else {
                defaults.removeObject(forKey: observedKey)
                defaults.removeObject(forKey: monthKeyName)
            }
            return result(
                anchoredRemaining: anchoredRemaining,
                accumulatedUSD: 0,
                conversionRate: conversionRate
            )
        }

        var accumulated = max(defaults.double(forKey: accumulatedKey), 0)
        guard let currentObservedMonthUSD else {
            return result(
                anchoredRemaining: anchoredRemaining,
                accumulatedUSD: accumulated,
                conversionRate: conversionRate
            )
        }

        let currentMonth = monthKey(for: now)
        guard defaults.string(forKey: monthKeyName) == currentMonth else {
            // Local month-to-date restarted. Preserve previously accumulated drain and
            // treat the new month's observed MTD as a fresh increment from zero.
            accumulated += max(currentObservedMonthUSD, 0)
            defaults.set(accumulated, forKey: accumulatedKey)
            defaults.set(currentObservedMonthUSD, forKey: observedKey)
            defaults.set(currentMonth, forKey: monthKeyName)
            return result(
                anchoredRemaining: anchoredRemaining,
                accumulatedUSD: accumulated,
                conversionRate: conversionRate
            )
        }

        if defaults.object(forKey: observedKey) == nil {
            defaults.set(currentObservedMonthUSD, forKey: observedKey)
            return result(
                anchoredRemaining: anchoredRemaining,
                accumulatedUSD: accumulated,
                conversionRate: conversionRate
            )
        }

        let previousObserved = defaults.double(forKey: observedKey)
        accumulated += max(currentObservedMonthUSD - previousObserved, 0)
        let storedObserved = max(currentObservedMonthUSD, previousObserved)
        defaults.set(storedObserved, forKey: observedKey)
        defaults.set(currentMonth, forKey: monthKeyName)
        defaults.set(accumulated, forKey: accumulatedKey)
        return result(
            anchoredRemaining: anchoredRemaining,
            accumulatedUSD: accumulated,
            conversionRate: conversionRate
        )
    }

    private static func result(
        anchoredRemaining: Double,
        accumulatedUSD: Double,
        conversionRate: Double
    ) -> Adjustment {
        // Accumulated Muse deltas stay in USD; convert to billing currency for display.
        let localDecrementInCurrency = max(accumulatedUSD, 0) * conversionRate
        return Adjustment(
            effectiveRemaining: max(0, anchoredRemaining - localDecrementInCurrency),
            localDecrementUSD: localDecrementInCurrency
        )
    }

    private static func monthKey(for date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month], from: date)
        return String(format: "%04d-%02d", parts.year ?? 0, parts.month ?? 0)
    }
}

public struct MetaProviderClient: ProviderClient {
    public let providerID: ProviderID = .meta

    public init() {}

    public func fetchSnapshot(credentials: ProviderCredential?) async throws -> QuotaSnapshot {
        let now = Date()
        let fields = credentials?.extraFields ?? [:]
        let access = resolveMuseAccess(credentials: credentials)
        defer { access?.stop() }

        let local = access.flatMap { MuseLocalUsageReader.read(rootURL: $0.url, now: now) }
        let taskWraith = TaskWraithSpendReader.read(provider: .meta, now: now)

        let preload = positiveDouble(fields[SpendProviderCredentialField.manualTopUpTotal])
            ?? positiveDouble(fields[SpendProviderCredentialField.manualAllowance])
        let remaining = nonnegativeDouble(fields[SpendProviderCredentialField.manualCurrentBalance])
        let threshold = positiveDouble(fields[SpendProviderCredentialField.manualPaymentThreshold])
        let manualSpent = nonnegativeDouble(fields[SpendProviderCredentialField.manualSpent])
        let currency = normalizedCurrency(fields[SpendProviderCredentialField.manualCurrency])
        let manualResetAt = ProviderDateParser.parse(fields[SpendProviderCredentialField.manualResetAt])
        let resetAt = manualResetAt ?? MetaBillingReset.nextResetDate(from: now)
        let softBudget = ProviderMonthlyBudgetStore.nonisolatedBudgetUSD(for: .meta) ?? 15.0
        let convertedSoftBudget = MetaSpendWatermarkStore.amountInCurrency(softBudget, currency: currency)
        let planName = fields[SpendProviderCredentialField.manualPlanName]?.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).nilIfEmpty ?? "API Credits"

        let observedMonth = observedMonthCostUSD(local: local, taskWraith: taskWraith)
        let remainingAdjustment: MetaRemainingWatermarkStore.Adjustment? = remaining.map { anchored in
            // Include currency + doctrine so GBP/EUR FX enablement rebases stale USD-only state.
            let signature = [
                "fx-v1",
                currency,
                fields[SpendProviderCredentialField.manualTopUpTotal]
                    ?? fields[SpendProviderCredentialField.manualAllowance]
                    ?? "",
                fields[SpendProviderCredentialField.manualCurrentBalance] ?? ""
            ].joined(separator: "|")
            return MetaRemainingWatermarkStore.adjustment(
                anchoredRemaining: anchored,
                currentObservedMonthUSD: observedMonth,
                currency: currency,
                signature: signature,
                now: now
            )
        }
        let displayRemaining = remainingAdjustment?.effectiveRemaining
        let remainingLocalDecrement = remainingAdjustment?.localDecrementUSD ?? 0
        let remainingDrivenSubtitle = remainingLocalDecrement > 0
            ? "Manual remaining minus tracked Muse spend since anchor"
            : nil

        let impliedSpendFromBalance: Double? = {
            guard let threshold, let remaining else { return nil }
            return max(0, threshold - remaining)
        }()
        let spendAnchor = manualSpent ?? impliedSpendFromBalance

        var windows: [QuotaWindow] = []
        var balances: [QuotaBalance] = []
        var signals: [QuotaSignal] = []
        var spendPeriodUsesThreshold = false

        // Always drive a cumulative spend window when we have a console spend
        // reading, a payment threshold to accumulate toward, or Muse observations.
        let shouldDriveSpendWindow = manualSpent != nil
            || threshold != nil
            || local != nil
            || observedMonth != nil
        if shouldDriveSpendWindow {
            if let manualResetAt, manualResetAt <= now {
                signals.append(
                    QuotaSignal(
                        kind: .scheduledReset,
                        title: "Billing anchor expired",
                        message: "Update the Meta console Spend reading for the new billing cycle.",
                        severity: .info,
                        confidence: 1,
                        windowLabel: "Spend this billing period",
                        detectedAt: now
                    )
                )
            }

            let anchoredSpend = spendAnchor ?? 0
            let signature: String = {
                if let anchorUpdatedAt = fields[SpendProviderCredentialField.anchorUpdatedAt],
                   !anchorUpdatedAt.isEmpty {
                    return anchorUpdatedAt
                }
                var parts = ["\(manualSpent ?? -1)", "\(threshold ?? -1)"]
                // Include remaining only when it contributes to implied spend.
                if manualSpent == nil, impliedSpendFromBalance != nil {
                    parts.append("\(remaining ?? -1)")
                }
                parts.append(currency)
                parts.append("\(manualResetAt?.timeIntervalSince1970 ?? 0)")
                return parts.joined(separator: "|")
            }()
            let anchorUpdatedAt = ProviderDateParser.parse(
                fields[SpendProviderCredentialField.anchorUpdatedAt]
            )
            let currentLocalSpendUSD = observedMonth ?? local?.currentMonthCostUSD
            let initialLocalIncrementUSD: Double = {
                if let anchorUpdatedAt {
                    return local?.costUSD(since: anchorUpdatedAt) ?? 0
                }
                // Muse-only / zero-anchor: seed with current MTD so the first card
                // isn't stuck at zero until the next scan delta.
                if spendAnchor == nil {
                    return currentLocalSpendUSD ?? 0
                }
                return 0
            }()
            let adjustment = MetaSpendWatermarkStore.adjustment(
                anchoredSpend: anchoredSpend,
                currentLocalSpendUSD: currentLocalSpendUSD,
                currency: currency,
                signature: signature,
                initialLocalIncrementUSD: initialLocalIncrementUSD,
                now: now
            )
            let spendTotal = threshold ?? convertedSoftBudget ?? preload
            spendPeriodUsesThreshold = threshold != nil && spendTotal == threshold
            let spendSubtitle: String = {
                if adjustment.localIncrement > 0 {
                    if manualSpent != nil {
                        return "Meta console reading plus tracked Muse spend"
                    }
                    if impliedSpendFromBalance != nil {
                        return "Threshold minus remaining, plus tracked Muse spend"
                    }
                    return "Tracked Muse spend since billing period start"
                }
                if manualSpent != nil {
                    return "Meta console reading"
                }
                if impliedSpendFromBalance != nil {
                    return "Threshold minus remaining balance"
                }
                return "Muse projected spend"
            }()
            windows.append(
                QuotaWindow(
                    label: "Spend this billing period",
                    windowKind: .monthly,
                    used: adjustment.spend,
                    total: spendTotal,
                    resetDate: resetAt,
                    unit: currency,
                    subtitle: spendSubtitle
                )
            )
        }

        if let preload, let displayRemaining,
           let creditUsed = DeepSeekTopUpMeter.creditUsed(
            totalTopUp: preload,
            currentBalance: displayRemaining
           ) {
            windows.append(
                QuotaWindow(
                    label: "Credit used",
                    windowKind: .custom,
                    used: creditUsed,
                    total: preload,
                    unit: currency,
                    subtitle: remainingLocalDecrement > 0
                        ? "Preload minus remaining, auto-advanced by Muse spend"
                        : "Configured preload minus remaining Meta balance"
                )
            )
        }

        // Prefer an Observed card whenever the Muse data home is readable (even at $0).
        // Kept as a USD Muse projection secondary meter (not converted to billing currency).
        if local != nil {
            windows.append(
                QuotaWindow(
                    label: "Observed this month",
                    windowKind: .monthly,
                    used: observedMonth ?? 0,
                    total: softBudget,
                    resetDate: resetAt,
                    unit: "USD",
                    subtitle: "Muse projected spend from session tokens × catalog rates — not a Meta invoice"
                )
            )
        }

        // Skip a separate Payment threshold window when the spend window already
        // uses the threshold as its total (avoids mislabeling USD Muse as GBP).
        if let threshold, !spendPeriodUsesThreshold {
            windows.append(
                QuotaWindow(
                    label: "Payment threshold",
                    windowKind: .custom,
                    used: observedMonth ?? local?.currentMonthCostUSD ?? taskWraith?.currentMonthCostUSD ?? 0,
                    total: threshold,
                    unit: currency,
                    subtitle: "Advisory vs Meta auto-charge threshold"
                )
            )
        }

        if local == nil, let estimated = taskWraith?.currentMonthCostUSD, estimated > 0 {
            windows.append(
                QuotaWindow(
                    label: "TaskWraith estimate",
                    windowKind: .monthly,
                    used: estimated,
                    total: softBudget,
                    resetDate: resetAt,
                    unit: "USD",
                    subtitle: "Muse session tokens × catalog rates"
                )
            )
        }

        if let preload {
            balances.append(
                QuotaBalance(label: "Preload credit", amount: preload, unit: currency, subtitle: "Manual billing anchor")
            )
        }
        if let displayRemaining {
            balances.append(
                QuotaBalance(
                    label: "Remaining balance",
                    amount: displayRemaining,
                    unit: currency,
                    subtitle: remainingDrivenSubtitle ?? "Manual billing anchor"
                )
            )
        }
        if let threshold {
            balances.append(
                QuotaBalance(label: "Payment threshold", amount: threshold, unit: currency, subtitle: "Manual billing anchor")
            )
        }

        var stats: [QuotaStat] = []
        if let local {
            stats.append(
                QuotaStat(
                    label: "Local 30D cost",
                    value: local.last30DaysCostUSD,
                    unit: "USD",
                    subtitle: "Muse session projection"
                )
            )
            if local.inputTokens > 0 {
                stats.append(
                    QuotaStat(label: "Input tokens", value: local.inputTokens, unit: "tokens", subtitle: "Muse sessions")
                )
            }
            if local.outputTokens > 0 {
                stats.append(
                    QuotaStat(label: "Output tokens", value: local.outputTokens, unit: "tokens", subtitle: "Muse sessions")
                )
            }
        }
        if let taskWraith {
            stats.append(
                QuotaStat(
                    label: "TaskWraith 35D estimate",
                    value: taskWraith.last35DaysCostUSD,
                    unit: "USD",
                    subtitle: "Not vendor billing"
                )
            )
        }

        let hasAnchors = preload != nil || remaining != nil || threshold != nil || manualSpent != nil
        guard !windows.isEmpty || local != nil || hasAnchors || taskWraith != nil else {
            throw ProviderFetchError.notConfigured
        }

        return QuotaSnapshot(
            providerID: .meta,
            displayName: ProviderID.meta.snapshotDisplayName,
            planName: planName,
            windows: windows,
            stats: stats,
            balances: balances,
            signals: signals,
            events: local?.events ?? taskWraith?.events ?? [],
            analyticsBuckets: local?.analyticsBuckets.isEmpty == false
                ? (local?.analyticsBuckets ?? [])
                : (taskWraith?.analyticsBuckets ?? []),
            fetchState: .success
        )
    }

    private func observedMonthCostUSD(
        local: MuseLocalUsageSummary?,
        taskWraith: TaskWraithSpendSummary?
    ) -> Double? {
        switch (local?.currentMonthCostUSD, taskWraith?.currentMonthCostUSD) {
        case let (local?, tw?):
            return max(local, tw)
        case let (local?, nil):
            return local
        case let (nil, tw?):
            return tw
        default:
            return nil
        }
    }

    /// Prefer security-scoped bookmark, then customEndpoint, then ~/.local/share/muse.
    private func resolveMuseAccess(credentials: ProviderCredential?) -> SecurityScopedCredentialAccess? {
        if let access = SecurityScopedCredentialAccess.resolve(
            credentials: credentials,
            fallbackURL: nil
        ) {
            return access
        }
        let fallback = museDefaultDataHomeURL()
        let sessionsURL = fallback.appendingPathComponent("sessions", isDirectory: true)
        guard FileManager.default.fileExists(atPath: sessionsURL.path) else { return nil }
        return SecurityScopedCredentialAccess(url: fallback, stop: {})
    }
}

/// Default Muse data home (`~/.local/share/muse`), unwrapping macOS container home paths.
private func museDefaultDataHomeURL() -> URL {
    let homePath = NSHomeDirectory()
    let realHome: String
    if let range = homePath.range(of: "/Library/Containers/") {
        realHome = String(homePath[..<range.lowerBound])
    } else {
        realHome = homePath
    }
    return URL(fileURLWithPath: realHome, isDirectory: true)
        .appendingPathComponent(".local/share/muse", isDirectory: true)
}

private func normalizedMuseDataHomeURL(_ selectedURL: URL) -> URL {
    var url = selectedURL.standardizedFileURL
    if url.lastPathComponent == "session.jsonl" {
        url = url.deletingLastPathComponent()
    }
    if url.path.contains("/sessions/") || url.lastPathComponent == "sessions" {
        while url.lastPathComponent != "sessions", url.pathComponents.count > 1 {
            url = url.deletingLastPathComponent()
        }
        if url.lastPathComponent == "sessions" {
            return url.deletingLastPathComponent()
        }
    }
    if url.lastPathComponent == "muse" {
        return url
    }
    let fm = FileManager.default
    if fm.fileExists(atPath: url.appendingPathComponent("sessions", isDirectory: true).path)
        || fm.fileExists(atPath: url.appendingPathComponent("model-catalog", isDirectory: true).path) {
        return url
    }
    return url.appendingPathComponent("muse", isDirectory: true)
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
