import Foundation
import CryptoKit
#if os(macOS)
import AppKit
import Darwin
import WebKit
#endif

enum SpendProviderCredentialField {
    static let manualSpent = "manualSpent"
    static let manualAllowance = "manualAllowance"
    static let mistralApiSpent = "mistralApiSpent"
    static let mistralApiAllowance = "mistralApiAllowance"
    static let manualCurrency = "manualCurrency"
    static let manualResetAt = "manualResetAt"
    static let manualCurrentBalance = "manualCurrentBalance"
    static let manualTopUpTotal = "manualTopUpTotal"
    static let manualPlanName = "manualPlanName"
    static let manualWeeklyUsedPercent = "manualWeeklyUsedPercent"
    static let anchorUpdatedAt = "anchorUpdatedAt"
    static let metaCookieHeader = "metaCookieHeader"
    static let museCliBookmark = "museCliBookmark"
    static let museCachedCurrentPercent = "museCachedCurrentPercent"
    static let museCachedCurrentResetAt = "museCachedCurrentResetAt"
    static let museCachedWeeklyPercent = "museCachedWeeklyPercent"
    static let museCachedWeeklyResetAt = "museCachedWeeklyResetAt"
    static let museCachedPlanName = "museCachedPlanName"
    static let museCachedAt = "museCachedAt"
    static let cerebrasCookieHeader = "cerebrasCookieHeader"
    static let cerebrasCachedBalance = "cerebrasCachedBalance"
    static let cerebrasCachedSpend = "cerebrasCachedSpend"
    static let cerebrasCachedCurrency = "cerebrasCachedCurrency"
    static let cerebrasCachedResetAt = "cerebrasCachedResetAt"
    static let browserSessionID = "browserSessionID"
    static let browserSessionURL = "browserSessionURL"
    static let cerebrasCachedAt = "cerebrasCachedAt"
    static let qwenCookieHeader = "qwenCookieHeader"
    static let mimoCookieHeader = "mimoCookieHeader"
    static let tokenPlanCachedUsedPercent = "tokenPlanCachedUsedPercent"
    static let tokenPlanCachedPlanName = "tokenPlanCachedPlanName"
    static let tokenPlanCachedResetAt = "tokenPlanCachedResetAt"
    static let tokenPlanCachedAt = "tokenPlanCachedAt"
    /// The period the meter reported at import time, so a cached reading keeps
    /// its label and its reset window instead of reverting to the default.
    static let tokenPlanCachedMeterPeriod = "tokenPlanCachedMeterPeriod"
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

    static func defaultApiAllowance(
        rawAllowance: Double?,
        currency: String,
        planName: String?
    ) -> Double? {
        if let rawAllowance, rawAllowance > 0 { return rawAllowance }
        let normalizedPlan = planName?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        let isProOrTeam = normalizedPlan.contains("pro") || normalizedPlan.contains("team")
        let isFree = normalizedPlan.contains("free")
        let usdBudget = isProOrTeam ? 27.8 : (isFree || normalizedPlan.isEmpty ? 0.0 : 5.0)

        switch currency.uppercased() {
        case "EUR":
            return isProOrTeam ? 25.5 : (isFree || normalizedPlan.isEmpty ? 0.0 : 5.0 * 0.92)
        case "USD":
            return usdBudget
        case "GBP":
            return amountInCurrency(usdBudget, currency: "GBP")
        default:
            return amountInCurrency(usdBudget, currency: currency)
        }
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

// MARK: - Mistral Web Subscription Client

public struct MistralWebSubscriptionResult: Sendable {
    public let planName: String?
    public let apiSpent: Double?
    public let apiAllowance: Double?
    public let vibeSpent: Double?
    public let vibeAllowance: Double?
    public let currency: String
    public let periodEnd: Date?

    public init(
        planName: String?,
        apiSpent: Double?,
        apiAllowance: Double?,
        vibeSpent: Double?,
        vibeAllowance: Double?,
        currency: String,
        periodEnd: Date?
    ) {
        self.planName = planName
        self.apiSpent = apiSpent
        self.apiAllowance = apiAllowance
        self.vibeSpent = vibeSpent
        self.vibeAllowance = vibeAllowance
        self.currency = currency
        self.periodEnd = periodEnd
    }
}

nonisolated enum ImportedCookieHeaderMerger {
    static func mergedHeader(
        existingHeader: String,
        response: HTTPURLResponse,
        requestURL: URL,
        allowedDomains: [String],
        now: Date = Date()
    ) -> String? {
        let fields = response.allHeaderFields.reduce(into: [String: String]()) { result, entry in
            result[String(describing: entry.key)] = entry.value as? String
                ?? String(describing: entry.value)
        }
        return mergedHeader(
            existingHeader: existingHeader,
            responseHeaderFields: fields,
            requestURL: requestURL,
            allowedDomains: allowedDomains,
            now: now
        )
    }

    static func mergedHeader(
        existingHeader: String,
        responseHeaderFields: [String: String],
        requestURL: URL,
        allowedDomains: [String],
        now: Date = Date()
    ) -> String? {
        guard let setCookie = responseHeaderFields.first(where: {
            $0.key.caseInsensitiveCompare("Set-Cookie") == .orderedSame
        })?.value else {
            return nil
        }

        let cookies = HTTPCookie.cookies(
            withResponseHeaderFields: ["Set-Cookie": setCookie],
            for: requestURL
        )
        guard !cookies.isEmpty else { return nil }

        var order: [String] = []
        var values: [String: String] = [:]
        for component in existingHeader.split(separator: ";", omittingEmptySubsequences: true) {
            let pair = component.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard let rawName = pair.first else { continue }
            let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { continue }
            if values[name] == nil {
                order.append(name)
            }
            values[name] = pair.count == 2
                ? String(pair[1]).trimmingCharacters(in: .whitespacesAndNewlines)
                : ""
        }

        let host = requestURL.host?.lowercased() ?? ""
        let requestPath = requestURL.path.isEmpty ? "/" : requestURL.path
        var didApplyCookie = false

        for cookie in cookies {
            let cookieDomain = cookie.domain
                .trimmingCharacters(in: CharacterSet(charactersIn: "."))
                .lowercased()
            guard domain(host, matches: cookieDomain),
                  allowedDomains.isEmpty || allowedDomains.contains(where: {
                      domain(cookieDomain, matches: $0.lowercased())
                          || domain(host, matches: $0.lowercased())
                  }),
                  path(requestPath, matches: cookie.path) else {
                continue
            }

            didApplyCookie = true
            if let expiresDate = cookie.expiresDate, expiresDate <= now {
                values.removeValue(forKey: cookie.name)
                order.removeAll { $0 == cookie.name }
                continue
            }

            if values[cookie.name] == nil {
                order.append(cookie.name)
            }
            values[cookie.name] = cookie.value
        }

        guard didApplyCookie else { return nil }
        return order.compactMap { name in
            values[name].map { "\(name)=\($0)" }
        }.joined(separator: "; ")
    }

    private static func domain(_ host: String, matches allowedDomain: String) -> Bool {
        let normalizedHost = host.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
        let normalizedDomain = allowedDomain.trimmingCharacters(
            in: CharacterSet(charactersIn: ".")
        ).lowercased()
        return normalizedHost == normalizedDomain
            || normalizedHost.hasSuffix("." + normalizedDomain)
    }

    private static func path(_ requestPath: String, matches cookiePath: String) -> Bool {
        let normalizedCookiePath = cookiePath.isEmpty ? "/" : cookiePath
        guard normalizedCookiePath != "/" else { return true }
        guard requestPath.hasPrefix(normalizedCookiePath) else { return false }
        return requestPath.count == normalizedCookiePath.count
            || normalizedCookiePath.hasSuffix("/")
            || requestPath.dropFirst(normalizedCookiePath.count).first == "/"
    }
}

private nonisolated func persistImportedCookieHeader(
    _ cookieHeader: String,
    providerID: ProviderID,
    field: String
) async -> Bool {
    let didPersist = await MainActor.run {
        KeychainService.shared.updateExtraFields(
            [field: cookieHeader],
            for: providerID
        )
    }
    if !didPersist {
        print("[ImportedCookieHeader] Failed to persist rotated cookies for \(providerID.rawValue)")
    }
    return didPersist
}

public struct MistralWebSubscriptionClient: Sendable {
    public init() {}

    public func fetch(
        cookieHeader: String,
        now: Date,
        persistCookieHeader: ((String) async -> Bool)? = nil
    ) async -> MistralWebSubscriptionResult? {
        guard let url = URL(string: "https://admin.mistral.ai/subscription") else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.httpMethod = "GET"
        request.httpShouldHandleCookies = false
        request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125.0.0.0 Safari/537.36",
            forHTTPHeaderField: "User-Agent"
        )
        request.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")

        // Cookie-inert session: admin.mistral.ai rotates session cookies via
        // Set-Cookie, and the shared cookie jar would override the imported
        // Keychain header on every fetch after the first.
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpCookieStorage = nil
        configuration.timeoutIntervalForRequest = 15
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }

        guard let (data, response) = try? await session.data(for: request),
              let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode),
              let html = String(data: data, encoding: .utf8) else {
            return nil
        }

        if let rotatedHeader = ImportedCookieHeaderMerger.mergedHeader(
            existingHeader: cookieHeader,
            response: httpResponse,
            requestURL: url,
            allowedDomains: ["mistral.ai"]
        ), rotatedHeader != cookieHeader {
            guard let persistCookieHeader,
                  await persistCookieHeader(rotatedHeader) else {
                print("[MistralWebSubscriptionClient] Rotated cookies were received but could not be persisted")
                return nil
            }
        }

        return Self.parse(html: html, now: now)
    }

    // MARK: Parsing

    struct MeterReading {
        let spent: Double
        let allowance: Double?
        let resetDate: Date?
        let currency: String?
    }

    /// Landmarks that end a meter block. Only searched forward from a section
    /// occurrence, so the same words appearing elsewhere in the document
    /// (tooltips, navigation, RSC payload duplicates) cannot clip a block that
    /// has not started yet. Deliberately not plain "pay-as-you-go": that phrase
    /// shows up in tooltip copy inside the meter blocks themselves.
    private static let sectionStopLabels = [
        "api usage",
        "vibe code usage",
        "pay-as-you-go & spending limit",
        "estimated price",
        "estimated total",
        "current plan"
    ]

    /// Normalized meter blocks are ~200 characters; the cap bounds the scan
    /// when no stop label follows an occurrence.
    private static let maximumBlockLength = 800

    public static func parse(html: String, now: Date) -> MistralWebSubscriptionResult? {
        let renderedText = normalizedRenderedText(from: html)
        if renderedText.range(of: "Sign in to your account", options: .caseInsensitive) != nil {
            return nil
        }

        let payloadText = normalizedScriptPayloadText(from: html)

        let apiReading = meterReading(labeled: "API usage", in: renderedText, now: now)
            ?? meterReading(labeled: "API usage", in: payloadText, now: now)
        let vibeReading = meterReading(labeled: "Vibe Code usage", in: renderedText, now: now)
            ?? meterReading(labeled: "Vibe Code usage", in: payloadText, now: now)

        guard apiReading != nil || vibeReading != nil else { return nil }

        return MistralWebSubscriptionResult(
            planName: planName(in: renderedText) ?? planName(in: payloadText),
            apiSpent: apiReading?.spent,
            apiAllowance: apiReading?.allowance,
            vibeSpent: vibeReading?.spent,
            vibeAllowance: vibeReading?.allowance,
            currency: apiReading?.currency ?? vibeReading?.currency ?? fallbackCurrency(in: renderedText),
            periodEnd: vibeReading?.resetDate ?? apiReading?.resetDate
        )
    }

    /// Returns the first occurrence of `label` that is followed by at least one
    /// currency amount before the next section landmark. Iterating occurrences
    /// keeps duplicated strings in navigation or embedded payloads harmless.
    static func meterReading(labeled label: String, in text: String, now: Date) -> MeterReading? {
        guard !text.isEmpty else { return nil }
        let normalizedLabel = label.lowercased()
        var searchStart = text.startIndex
        while searchStart < text.endIndex,
              let labelRange = text.range(of: label, options: .caseInsensitive, range: searchStart..<text.endIndex) {
            let blockStart = labelRange.upperBound
            var blockEnd = text.index(blockStart, offsetBy: maximumBlockLength, limitedBy: text.endIndex) ?? text.endIndex
            for stop in sectionStopLabels where stop != normalizedLabel {
                if let stopRange = text.range(of: stop, options: .caseInsensitive, range: blockStart..<blockEnd) {
                    blockEnd = stopRange.lowerBound
                }
            }
            let block = String(text[blockStart..<blockEnd])
            let amounts = extractCurrencyAmounts(from: block)
            if let spent = amounts.first {
                return MeterReading(
                    spent: spent,
                    allowance: amounts.count >= 2 ? amounts[1] : nil,
                    resetDate: extractResetDate(from: block, now: now),
                    currency: detectedCurrency(in: block)
                )
            }
            searchStart = labelRange.upperBound
        }
        return nil
    }

    // MARK: Text normalization

    /// Text the way a browser renders it: comments removed (React SSR inserts
    /// `<!-- -->` between text segments), scripts/styles dropped, tags
    /// collapsed to spaces (amounts can be split across inline elements),
    /// entities decoded, whitespace collapsed.
    static func normalizedRenderedText(from html: String) -> String {
        var text = replacingPattern(#"<!--[\s\S]*?-->"#, in: html, with: "")
        text = replacingPattern(#"<script\b[^>]*>[\s\S]*?</script>"#, in: text, with: " ")
        text = replacingPattern(#"<style\b[^>]*>[\s\S]*?</style>"#, in: text, with: " ")
        text = replacingPattern(#"<[^>]+>"#, in: text, with: " ")
        text = decodedHTMLEntities(text)
        return collapsedWhitespace(text)
    }

    /// Script bodies (Next.js RSC flight payload and similar) decoded into
    /// searchable text, for pages that do not server-render the meters.
    static func normalizedScriptPayloadText(from html: String) -> String {
        let bodies = capturedGroups(#"<script\b[^>]*>([\s\S]*?)</script>"#, in: html)
        guard !bodies.isEmpty else { return "" }
        var text = decodedJavaScriptEscapes(bodies.joined(separator: " "))
        text = replacingPattern(#"<!--[\s\S]*?-->"#, in: text, with: "")
        text = replacingPattern(#"<[^>]+>"#, in: text, with: " ")
        text = decodedHTMLEntities(text)
        return collapsedWhitespace(text)
    }

    private static func replacingPattern(_ pattern: String, in text: String, with template: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return text }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: template)
    }

    private static func capturedGroups(_ pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, options: [], range: range).compactMap { match in
            guard match.numberOfRanges > 1, let captured = Range(match.range(at: 1), in: text) else { return nil }
            return String(text[captured])
        }
    }

    private static func replacingMatches(
        pattern: String,
        in text: String,
        transform: (NSString, NSTextCheckingResult) -> String?
    ) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let nsText = text as NSString
        let matches = regex.matches(in: text, options: [], range: NSRange(location: 0, length: nsText.length))
        guard !matches.isEmpty else { return text }
        var result = ""
        var cursor = 0
        for match in matches {
            result += nsText.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            result += transform(nsText, match) ?? nsText.substring(with: match.range)
            cursor = match.range.location + match.range.length
        }
        result += nsText.substring(from: cursor)
        return result
    }

    private static func decodedHTMLEntities(_ text: String) -> String {
        var result = replacingMatches(pattern: #"&#(x[0-9a-fA-F]+|[0-9]+);"#, in: text) { nsText, match in
            let token = nsText.substring(with: match.range(at: 1))
            let value: UInt32? = token.lowercased().hasPrefix("x")
                ? UInt32(token.dropFirst(), radix: 16)
                : UInt32(token)
            guard let value, let scalar = UnicodeScalar(value) else { return nil }
            return String(Character(scalar))
        }
        // &amp; decodes last so double-encoded entities stay literal text.
        let named: [(String, String)] = [
            ("&nbsp;", " "), ("&euro;", "€"), ("&pound;", "£"),
            ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""),
            ("&apos;", "'"), ("&amp;", "&")
        ]
        for (entity, replacement) in named {
            result = result.replacingOccurrences(of: entity, with: replacement, options: .caseInsensitive)
        }
        return result
    }

    private static func decodedJavaScriptEscapes(_ text: String) -> String {
        var result = replacingMatches(pattern: #"\\u([0-9a-fA-F]{4})"#, in: text) { nsText, match in
            guard let value = UInt32(nsText.substring(with: match.range(at: 1)), radix: 16),
                  let scalar = UnicodeScalar(value) else { return nil }
            return String(Character(scalar))
        }
        // Backslash-backslash decodes last so it cannot manufacture new escapes.
        let simple: [(String, String)] = [
            ("\\\"", "\""), ("\\/", "/"), ("\\n", " "), ("\\t", " "), ("\\r", " "), ("\\\\", "\\")
        ]
        for (escapeSequence, replacement) in simple {
            result = result.replacingOccurrences(of: escapeSequence, with: replacement)
        }
        return result
    }

    private static func collapsedWhitespace(_ text: String) -> String {
        text.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    // MARK: Field extraction

    static func extractCurrencyAmounts(from chunk: String) -> [Double] {
        guard let regex = try? NSRegularExpression(
            pattern: #"(?:€|\$|£|EUR|USD|GBP)\s*([0-9][0-9,]*(?:\.[0-9]+)?)"#,
            options: [.caseInsensitive]
        ) else {
            return []
        }
        let nsRange = NSRange(chunk.startIndex..<chunk.endIndex, in: chunk)
        let matches = regex.matches(in: chunk, options: [], range: nsRange)
        return matches.compactMap { match -> Double? in
            guard match.numberOfRanges > 1, let range = Range(match.range(at: 1), in: chunk) else { return nil }
            return Double(chunk[range].replacingOccurrences(of: ",", with: ""))
        }
    }

    /// The currency of the first symbol-plus-number match. A lone symbol is
    /// not evidence: RSC flight payloads use `"$"` as an element marker.
    static func detectedCurrency(in block: String) -> String? {
        guard let regex = try? NSRegularExpression(
            pattern: #"(€|\$|£|EUR|USD|GBP)\s*[0-9]"#,
            options: [.caseInsensitive]
        ) else {
            return nil
        }
        let nsRange = NSRange(block.startIndex..<block.endIndex, in: block)
        guard let match = regex.firstMatch(in: block, options: [], range: nsRange),
              match.numberOfRanges > 1,
              let symbolRange = Range(match.range(at: 1), in: block) else {
            return nil
        }
        switch block[symbolRange].uppercased() {
        case "€", "EUR": return "EUR"
        case "£", "GBP": return "GBP"
        default: return "USD"
        }
    }

    static func fallbackCurrency(in text: String) -> String {
        if text.contains("€") { return "EUR" }
        if text.contains("$") { return "USD" }
        if text.contains("£") { return "GBP" }
        return "EUR"
    }

    private static func planName(in text: String) -> String? {
        if let plan = firstMatch(in: text, pattern: #"current plan\s+(pro|team|enterprise|free)\b"#) {
            return plan.capitalized
        }
        if let plan = firstMatch(in: text, pattern: #"\b(pro|team|enterprise|free)\b\s+active\b"#) {
            return plan.capitalized
        }
        return nil
    }

    static func extractResetDate(from chunk: String, now: Date) -> Date? {
        if let daysMatch = firstMatch(in: chunk, pattern: #"(?:[Rr]esets?\s+in\s+([0-9]+)\s*(?:days?|d))"#),
           let days = Double(daysMatch) {
            return now.addingTimeInterval(days * 86400)
        }
        if let hoursMatch = firstMatch(in: chunk, pattern: #"(?:[Rr]esets?\s+in\s+([0-9]+)\s*(?:hours?|hrs?|h))"#),
           let hours = Double(hoursMatch) {
            return now.addingTimeInterval(hours * 3600)
        }
        return nil
    }

    private static func firstMatch(in text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
         }
        let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: nsRange) else {
            return nil
         }
        if match.numberOfRanges > 1, let range = Range(match.range(at: 1), in: text) {
            return String(text[range])
         }
        return nil
     }
}

// MARK: - Persistent imported browser sessions

nonisolated struct BrowserMeterResult<Value: Codable & Sendable>: Sendable {
    let value: Value?
    let fetchedAt: Date?
    let failure: String?
    /// Whether `failure` was a rejected credential rather than a page that
    /// loaded but did not parse. The store persists failures as text, so the
    /// kind has to travel with it or every session problem gets reported as a
    /// parse error.
    let failureIsCredential: Bool

    var sourceDescription: String {
        guard let fetchedAt else { return failure ?? "Browser reading unavailable" }
        let stamp = ISO8601DateFormatter().string(from: fetchedAt)
        return failure.map { "Last browser reading \(stamp). \($0)" } ?? "Browser reading \(stamp)"
    }

    /// The stored failure, re-thrown as the kind of error it actually was.
    /// A rejected session has to reach the user as a credential problem so the
    /// card asks them to reconnect; labelling it a parse error implies the page
    /// layout changed and there is nothing to do but wait.
    var failureError: ProviderFetchError? {
        guard let failure else { return nil }
        if failureIsCredential { return ProviderFetchError.credentialExpired(failure) }
        // `failure` holds a localized description, so a parsing error already
        // carries the prefix and wrapping it again would read
        // "Parse error: Parse error: …".
        let prefix = "Parse error: "
        return ProviderFetchError.parsingError(
            failure.hasPrefix(prefix) ? String(failure.dropFirst(prefix.count)) : failure
        )
    }
}

nonisolated enum BrowserSessionRefreshPolicy {
    static func allowsNavigation(to url: URL, dashboardHost: String) -> Bool {
        guard url.scheme == "https", let host = url.host?.lowercased() else { return false }
        if host == dashboardHost { return true }
        // The console obtains a short-lived ticket through Alibaba's own
        // account service even when its Google/GitHub SSO is still valid.
        if dashboardHost == "modelstudio.console.alibabacloud.com" {
            return ["alibabacloud.com", "aliyun.com"].contains {
                host == $0 || host.hasSuffix("." + $0)
            }
        }
        return false
    }

    static func validatedURL(_ value: String?, fallback: URL) -> URL {
        guard let value, let url = URL(string: value),
              url.scheme == "https", url.host == fallback.host,
              url.user == nil, url.password == nil,
              url.port == nil || url.port == 443 else { return fallback }
        return url
    }

    static func cacheKey(url: URL, sessionID: String) -> String {
        let digest = SHA256.hash(data: Data("\(url.absoluteString)|\(sessionID)".utf8))
        return "browserMeter.v1." + digest.map { String(format: "%02x", $0) }.joined()
    }

    static func shouldSeedCookies(existing: [HTTPCookie], host: String, now: Date = Date()) -> Bool {
        !existing.contains {
            let domain = $0.domain.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
            return (host == domain || host.hasSuffix("." + domain))
                && ($0.expiresDate.map { $0 > now } ?? true)
        }
    }
}

/// Caches parsed readings, never browser HTML or cookies. The in-flight task
/// belongs to the store so overlapping refreshes share one browser navigation.
@MainActor
final class BrowserMeterRefreshStore {
    static let shared = BrowserMeterRefreshStore()
    private nonisolated struct Entry: Codable, Sendable {
        var value: Data?
        var fetchedAt: Date?
        var nextAttemptAt: Date
        var failure: String?
        /// Optional so entries cached before the kind was recorded still decode.
        var failureIsCredential: Bool?
    }
    private let defaults: UserDefaults
    private var inFlight: [String: Task<Entry, Never>] = [:]

    init(defaults: UserDefaults? = nil) {
        self.defaults = defaults ?? UserDefaults(suiteName: "group.com.chrisizatt.LLMUsageCounter") ?? .standard
    }

    func read<Value: Codable & Sendable>(
        url: URL,
        sessionID: String,
        initial: Value?,
        initialAt: Date?,
        interval: TimeInterval,
        failureInterval: TimeInterval,
        now: Date = Date(),
        fetch: @escaping @MainActor () async throws -> Value
    ) async -> BrowserMeterResult<Value> {
        let key = BrowserSessionRefreshPolicy.cacheKey(url: url, sessionID: sessionID)
        func result(_ entry: Entry) -> BrowserMeterResult<Value> {
            BrowserMeterResult(
                value: entry.value.flatMap { try? JSONDecoder().decode(Value.self, from: $0) },
                fetchedAt: entry.fetchedAt,
                failure: entry.failure,
                failureIsCredential: entry.failureIsCredential ?? false
            )
        }
        if let task = inFlight[key] { return result(await task.value) }
        var entry = defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(Entry.self, from: $0) }
            ?? Entry(value: nil, fetchedAt: nil, nextAttemptAt: .distantPast, failure: nil, failureIsCredential: nil)
        if let initial, let initialAt, initialAt > (entry.fetchedAt ?? .distantPast) {
            entry.value = try? JSONEncoder().encode(initial)
            entry.fetchedAt = initialAt
            entry.nextAttemptAt = max(entry.nextAttemptAt, initialAt.addingTimeInterval(interval))
        }
        if now < entry.nextAttemptAt { return result(entry) }

        entry.nextAttemptAt = now.addingTimeInterval(failureInterval)
        defaults.set(try? JSONEncoder().encode(entry), forKey: key)
        let previous = entry
        let task = Task { @MainActor in
            var next = previous
            do {
                let value = try await fetch()
                next.value = try JSONEncoder().encode(value)
                next.fetchedAt = now
                next.nextAttemptAt = now.addingTimeInterval(interval)
                next.failure = nil
                next.failureIsCredential = nil
            } catch {
                next.failure = error.localizedDescription
                next.failureIsCredential = (error as? ProviderFetchError)?.isCredentialFailure ?? false
            }
            defaults.set(try? JSONEncoder().encode(next), forKey: key)
            return next
        }
        inFlight[key] = task
        let completed = await task.value
        inFlight[key] = nil
        return result(completed)
    }
}

#if os(macOS)
/// Renders with the importer's WebKit store. Its current cookies and local
/// storage are authoritative; an old imported Cookie header must not replace them.
@MainActor
private final class ImportedSessionPageReader: NSObject, WKNavigationDelegate {
    private let webView: WKWebView
    private let panel: NSPanel
    private var continuation: CheckedContinuation<String, Error>?
    private var polling: Task<Void, Never>?
    private var deadline: Task<Void, Never>?
    private let host: String
    private let isReady: (String) -> Bool

    private init(url: URL, isReady: @escaping (String) -> Bool) {
        host = url.host ?? ""
        self.isReady = isReady
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 1100, height: 800), configuration: configuration)
        panel = NSPanel(
            contentRect: NSRect(x: -20_000, y: -20_000, width: 1100, height: 800),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false
        )
        super.init()
        webView.navigationDelegate = self
        panel.contentView = webView
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.alphaValue = 0.01
    }

    static func read(url: URL, cookieHeader: String, isReady: @escaping (String) -> Bool) async throws -> String {
        let reader = ImportedSessionPageReader(url: url, isReady: isReady)
        try await reader.seedMissingSession(cookieHeader)
        try Task.checkCancellation()
        return try await reader.load(url)
    }

    private func seedMissingSession(_ header: String) async throws {
        let store = webView.configuration.websiteDataStore.httpCookieStore
        let cookies = await store.allCookies()
        guard BrowserSessionRefreshPolicy.shouldSeedCookies(existing: cookies, host: host) else { return }
        for part in header.split(separator: ";") {
            let pair = part.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard pair.count == 2, !pair[0].isEmpty,
                  let cookie = HTTPCookie(properties: [
                    .name: pair[0], .value: pair[1], .domain: host, .path: "/", .secure: "TRUE"
                  ]) else { continue }
            await store.setCookie(cookie)
        }
    }

    private func load(_ url: URL) async throws -> String {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                guard !Task.isCancelled else {
                    finish(.failure(CancellationError()))
                    return
                }
                panel.orderFrontRegardless()
                deadline = Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .seconds(18))
                    guard !Task.isCancelled else { return }
                    self?.finish(.failure(ProviderFetchError.parsingError("Browser meters did not load. Open the provider's session import to check its sign-in.")))
                }
                webView.load(URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 18))
                polling = Task { @MainActor [weak self] in
                    while !Task.isCancelled {
                        guard let self else { return }
                        if self.webView.url?.host == self.host,
                           let value = try? await self.webView.evaluateJavaScript("document.body ? document.body.innerText.slice(0, 250000) : ''"),
                           let text = value as? String {
                            if text.localizedCaseInsensitiveContains("temporarily blocked") {
                                self.finish(.failure(ProviderFetchError.rateLimited))
                                return
                            }
                            if self.isReady(text) {
                                self.finish(.success(text))
                                return
                            }
                        }
                        try? await Task.sleep(for: .milliseconds(500))
                    }
                }
            }
        } onCancel: {
            Task { @MainActor in self.finish(.failure(CancellationError())) }
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if action.targetFrame?.isMainFrame == true, let url = action.request.url,
           !BrowserSessionRefreshPolicy.allowsNavigation(to: url, dashboardHost: host) {
            decisionHandler(.cancel)
            finish(.failure(ProviderFetchError.credentialExpired("Browser sign-in expired. Open the session import to reconnect.")))
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        finish(.failure(error))
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finish(.failure(error))
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        finish(.failure(ProviderFetchError.parsingError("Browser session process ended; retry after the refresh cooldown.")))
    }
    private func finish(_ result: Result<String, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        polling?.cancel()
        deadline?.cancel()
        polling = nil
        deadline = nil
        webView.stopLoading()
        webView.navigationDelegate = nil
        panel.orderOut(nil)
        panel.contentView = nil
        continuation.resume(with: result)
    }
}
#endif

// MARK: - Generic Web Billing Client (Meta / Cerebras)

/// A balance reading scraped from a provider's billing page. `balance` is the
/// current available credit; `spend` is the billing-period spend when the page
/// exposes it; `periodEnd` is the next reset when the page exposes it.
public nonisolated struct WebBillingReading: Sendable, Codable {
    public let balance: Double?
    public let spend: Double?
    public let currency: String
    public let periodEnd: Date?

    public init(
        balance: Double?,
        spend: Double?,
        currency: String,
        periodEnd: Date?
     ) {
        self.balance = balance
        self.spend = spend
        self.currency = currency
        self.periodEnd = periodEnd
     }

    public var isEmpty: Bool {
        balance == nil && spend == nil
    }
}

/// Meta's browser billing surface is not a public API and applies aggressive
/// anti-abuse controls. Keep dashboard refreshes from repeatedly navigating an
/// authenticated browser-equivalent request while retaining the last reading.
enum MetaWebBillingRefreshCadence {
    static let successfulFetchInterval: TimeInterval = 60 * 60
    static let failedFetchRetryInterval: TimeInterval = 6 * 60 * 60

    static func isDue(
        now: Date,
        lastSuccessfulFetchAt: Date?,
        lastAttemptAt: Date?
    ) -> Bool {
        guard let lastAttemptAt else { return true }

        if let lastSuccessfulFetchAt, lastSuccessfulFetchAt >= lastAttemptAt {
            return now.timeIntervalSince(lastSuccessfulFetchAt) >= successfulFetchInterval
        }

        return now.timeIntervalSince(lastAttemptAt) >= failedFetchRetryInterval
    }
}

private actor MetaWebBillingRefreshCache {
    enum FetchDecision {
        case fetch
        case cached(WebBillingReading?)
    }

    private struct PersistedReading: Codable {
        let balance: Double?
        let spend: Double?
        let currency: String
        let periodEnd: Date?

        init(_ reading: WebBillingReading) {
            balance = reading.balance
            spend = reading.spend
            currency = reading.currency
            periodEnd = reading.periodEnd
        }

        var webBillingReading: WebBillingReading {
            WebBillingReading(
                balance: balance,
                spend: spend,
                currency: currency,
                periodEnd: periodEnd
            )
        }
    }

    private struct PersistedState: Codable {
        let sessionFingerprint: String
        var reading: PersistedReading?
        var lastSuccessfulFetchAt: Date?
        var lastAttemptAt: Date?
    }

    static let shared = MetaWebBillingRefreshCache()

    private static let appGroupID = "group.com.chrisizatt.LLMUsageCounter"
    private static let defaultPersistenceKey = "meta.webBillingRefreshCache.v1"

    private let defaults: UserDefaults
    private let persistenceKey: String
    private var state: PersistedState?

    init(
        defaults: UserDefaults? = nil,
        persistenceKey: String = MetaWebBillingRefreshCache.defaultPersistenceKey
    ) {
        self.defaults = defaults
            ?? UserDefaults(suiteName: Self.appGroupID)
            ?? .standard
        self.persistenceKey = persistenceKey
        state = self.defaults.data(forKey: persistenceKey).flatMap {
            try? JSONDecoder().decode(PersistedState.self, from: $0)
        }
    }

    func decision(for cookieHeader: String, now: Date) -> FetchDecision {
        let fingerprint = Self.fingerprint(for: cookieHeader)
        guard let state, state.sessionFingerprint == fingerprint else {
            return .fetch
        }
        guard !MetaWebBillingRefreshCadence.isDue(
            now: now,
            lastSuccessfulFetchAt: state.lastSuccessfulFetchAt,
            lastAttemptAt: state.lastAttemptAt
        ) else {
            return .fetch
        }
        return .cached(state.reading?.webBillingReading)
    }

    @discardableResult
    func recordResult(
        _ reading: WebBillingReading?,
        for cookieHeader: String,
        now: Date
    ) -> WebBillingReading? {
        let fingerprint = Self.fingerprint(for: cookieHeader)
        var next = state?.sessionFingerprint == fingerprint
            ? state!
            : PersistedState(
                sessionFingerprint: fingerprint,
                reading: nil,
                lastSuccessfulFetchAt: nil,
                lastAttemptAt: nil
            )

        next.lastAttemptAt = now
        if let reading {
            next.reading = PersistedReading(reading)
            next.lastSuccessfulFetchAt = now
        }
        state = next
        persist()

        return reading ?? next.reading?.webBillingReading
    }

    private func persist() {
        guard let state, let data = try? JSONEncoder().encode(state) else { return }
        defaults.set(data, forKey: persistenceKey)
    }

    /// Cache partitioning only: this prevents cross-session readings without
    /// persisting the imported cookie header outside Keychain.
    private static func fingerprint(for value: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x100000001b3
        }
        return String(hash, radix: 16)
    }
}

/// Scrapes a provider billing page with an imported cookie header and extracts
/// the current balance / billing-period spend. Mirrors the Ollama/Mistral
/// web-session pattern: the user signs in inside the embedded browser, the
/// normalized cookie header is stored in Keychain, and this client re-reads the
/// page on each refresh.
public struct WebBillingClient: Sendable {
    public let baseURL: URL
    public let cookieDomains: [String]

    public init(baseURL: URL, cookieDomains: [String]) {
        self.baseURL = baseURL
        self.cookieDomains = cookieDomains
     }

    public func fetch(
        cookieHeader: String,
        now: Date,
        persistCookieHeader: ((String) async -> Bool)? = nil
    ) async -> WebBillingReading? {
        guard !cookieHeader.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
         }

        var request = URLRequest(url: baseURL, timeoutInterval: 15)
        request.httpMethod = "GET"
        request.httpShouldHandleCookies = false
        request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        request.setValue(
             "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125.0.0.0 Safari/537.36",
            forHTTPHeaderField: "User-Agent"
         )
        request.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")

         // Cookie-inert session: billing pages rotate session cookies via
         // Set-Cookie, and the shared cookie jar would override the imported
         // Keychain header on every fetch after the first.
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpCookieStorage = nil
        configuration.timeoutIntervalForRequest = 15
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }

        guard let (data, response) = try? await session.data(for: request),
              let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode),
              let html = String(data: data, encoding: .utf8) else {
            return nil
         }

        if let rotatedHeader = ImportedCookieHeaderMerger.mergedHeader(
            existingHeader: cookieHeader,
            response: httpResponse,
            requestURL: baseURL,
            allowedDomains: cookieDomains
        ), rotatedHeader != cookieHeader {
            guard let persistCookieHeader,
                  await persistCookieHeader(rotatedHeader) else {
                print("[WebBillingClient] Rotated cookies were received but could not be persisted")
                return nil
            }
        }

        return Self.parse(html: html, now: now)
     }

     // MARK: Parsing

     /// Parses a billing page into a balance reading. The parser is
      /// provider-agnostic: it scans the rendered text and any embedded
      /// script/RSC payload for currency amounts near balance/spend labels,
      /// so it survives React comment splitting, tag splitting, and
      /// flight-payload-only pages the same way the Mistral parser does.
    public static func parse(html: String, now: Date) -> WebBillingReading? {
        let renderedText = MistralWebSubscriptionClient.normalizedRenderedText(from: html)
        let payloadText = MistralWebSubscriptionClient.normalizedScriptPayloadText(from: html)

         // A signed-out page renders a login form and no balance.
        if renderedText.range(of: "Sign in", options: .caseInsensitive) != nil
            || renderedText.range(of: "Log in", options: .caseInsensitive) != nil {
            if renderedText.range(of: "balance", options: .caseInsensitive) == nil
                 && renderedText.range(of: "spend", options: .caseInsensitive) == nil {
                return nil
             }
         }

        let balance = balanceReading(in: renderedText, now: now)
             ?? balanceReading(in: payloadText, now: now)
        let spend = spendReading(in: renderedText, now: now)
             ?? spendReading(in: payloadText, now: now)
        let periodEnd = balance?.periodEnd ?? spend?.periodEnd
        let currency = balance?.currency ?? spend?.currency ?? MistralWebSubscriptionClient.fallbackCurrency(in: renderedText)

        guard balance != nil || spend != nil else { return nil }

        return WebBillingReading(
            balance: balance?.amount,
            spend: spend?.amount,
            currency: currency,
            periodEnd: periodEnd
         )
     }

     /// A labeled currency amount. `labels` are the phrases that introduce the
      /// value (e.g. "current balance", "available credit"). The first currency
      /// amount after a label wins; a second amount in the same block is the
      /// allowance/limit.
    private struct LabeledAmount {
        let amount: Double
        let allowance: Double?
        let currency: String?
        let periodEnd: Date?
     }

    private static func balanceReading(in text: String, now: Date) -> LabeledAmount? {
        labeledAmount(
            labels: ["current balance", "available balance", "available credit", "balance", "credit balance", "remaining balance"],
            in: text,
            now: now
         )
     }

    private static func spendReading(in text: String, now: Date) -> LabeledAmount? {
        labeledAmount(
            labels: ["spend this billing period", "spend to date", "billing period spend", "spend", "total spend", "used this period"],
            in: text,
            now: now
         )
     }

    private static func labeledAmount(labels: [String], in text: String, now: Date) -> LabeledAmount? {
        guard !text.isEmpty else { return nil }
        for label in labels {
            if let reading = firstLabeledAmount(label: label, in: text, now: now) {
                return reading
             }
         }
        return nil
     }

    private static func firstLabeledAmount(label: String, in text: String, now: Date) -> LabeledAmount? {
        var searchStart = text.startIndex
        while searchStart < text.endIndex,
              let labelRange = text.range(of: label, options: .caseInsensitive, range: searchStart..<text.endIndex) {
            let blockStart = labelRange.upperBound
            var blockEnd = text.index(blockStart, offsetBy: 400, limitedBy: text.endIndex) ?? text.endIndex
            for stop in ["current balance", "available balance", "available credit", "spend this billing period", "spend to date", "billing period spend", "total spend"] where stop != label {
                if let stopRange = text.range(of: stop, options: .caseInsensitive, range: blockStart..<blockEnd) {
                    blockEnd = stopRange.lowerBound
                 }
             }
            let block = String(text[blockStart..<blockEnd])
            let amounts = MistralWebSubscriptionClient.extractCurrencyAmounts(from: block)
            if let amount = amounts.first {
                return LabeledAmount(
                    amount: amount,
                    allowance: amounts.count >= 2 ? amounts[1] : nil,
                    currency: MistralWebSubscriptionClient.detectedCurrency(in: block),
                    periodEnd: MistralWebSubscriptionClient.extractResetDate(from: block, now: now)
                  )
             }
            searchStart = labelRange.upperBound
         }
        return nil
     }
}

public struct MistralProviderClient: ProviderClient {
    public let providerID: ProviderID = .mistral

    public init() {}

    struct MeterAssembly {
        let windows: [QuotaWindow]
        let signals: [QuotaSignal]
        let planName: String?
    }

    /// Builds the API and Vibe meters, choosing the best source per meter:
    /// web subscription page, then Admin API split, then the manual anchor or
    /// local estimate. Each meter falls back independently so a partial web
    /// parse (one meter missing) cannot suppress the other meter's fallback.
    static func assembleMeters(
        webResult: MistralWebSubscriptionResult?,
        admin: MistralAdminUsageResult?,
        local: MistralLocalUsageSummary?,
        fields: [String: String],
        fallbackManualAllowance: Double? = nil,
        budgetUSD: Double? = nil,
        now: Date,
        watermarkDefaults: UserDefaults? = nil
    ) -> MeterAssembly {
        let rawManualVibeAllowance = positiveDouble(fields[SpendProviderCredentialField.manualAllowance])
            ?? fallbackManualAllowance
        let rawManualVibeSpend = nonnegativeDouble(fields[SpendProviderCredentialField.manualSpent])
        let rawManualApiSpend = nonnegativeDouble(fields[SpendProviderCredentialField.mistralApiSpent])
        let rawManualApiAllowance = positiveDouble(fields[SpendProviderCredentialField.mistralApiAllowance])
        let manualCurrency = normalizedCurrency(fields[SpendProviderCredentialField.manualCurrency])
        let manualReset = ProviderDateParser.parse(fields[SpendProviderCredentialField.manualResetAt])
        let planName = fields[SpendProviderCredentialField.manualPlanName]

        let manualVibeAllowance = MistralVibeBudgetResolver.effectiveAllowance(
            rawAllowance: rawManualVibeAllowance,
            currency: manualCurrency,
            planName: planName,
            configuredBudgetUSD: budgetUSD
        )
        let manualApiAllowance = MistralVibeBudgetResolver.defaultApiAllowance(
            rawAllowance: rawManualApiAllowance,
            currency: manualCurrency,
            planName: planName
        )
        let discardedLegacyAnchor = MistralVibeBudgetResolver.shouldDiscardLegacyAnchor(
            rawAllowance: rawManualVibeAllowance,
            rawSpent: rawManualVibeSpend,
            currency: manualCurrency,
            planName: planName
        )
        let manualVibeSpend = discardedLegacyAnchor ? nil : rawManualVibeSpend

        var windows: [QuotaWindow] = []
        var signals: [QuotaSignal] = []

        // The Admin API only splits into two meters when it itemizes Vibe
        // spend. Its opaque-but-complete total still beats manual estimates,
        // but only when no web reading exists at all.
        let useAdminCombinedTotal = webResult == nil
            && admin?.vibeSpend == nil
            && admin?.totalSpendIsComplete == true

        if useAdminCombinedTotal, let admin {
            let adminVibeAllowance = manualVibeAllowance.flatMap {
                MistralVibeBudgetResolver.convert($0, from: manualCurrency, to: admin.currency)
            } ?? (admin.currency == "USD" ? budgetUSD : nil)
            windows.append(
                QuotaWindow(
                    label: "Mistral usage this billing period",
                    windowKind: .monthly,
                    used: admin.totalSpend,
                    total: adminVibeAllowance,
                    resetDate: admin.periodEnd ?? manualReset,
                    unit: admin.currency,
                    subtitle: "Official Mistral Admin API total"
                )
            )
            return MeterAssembly(windows: windows, signals: signals, planName: planName)
        }

        // API meter: web page, then Admin API split, then manual anchor.
        if let webResult, let apiSpent = webResult.apiSpent {
            let apiAllowance = webResult.apiAllowance
                ?? manualApiAllowance
                ?? MistralVibeBudgetResolver.defaultApiAllowance(rawAllowance: nil, currency: webResult.currency, planName: webResult.planName ?? planName)
            windows.append(
                QuotaWindow(
                    label: "API usage",
                    windowKind: .monthly,
                    used: apiSpent,
                    total: apiAllowance,
                    resetDate: webResult.periodEnd ?? manualReset,
                    unit: webResult.currency,
                    subtitle: "Available via the API and Studio"
                )
            )
        } else if let admin, let vibeSpend = admin.vibeSpend {
            let adminApiAllowance = manualApiAllowance.flatMap {
                MistralVibeBudgetResolver.convert($0, from: manualCurrency, to: admin.currency)
            } ?? MistralVibeBudgetResolver.defaultApiAllowance(rawAllowance: nil, currency: admin.currency, planName: planName)
            windows.append(
                QuotaWindow(
                    label: "API usage",
                    windowKind: .monthly,
                    used: max(0, admin.totalSpend - vibeSpend),
                    total: adminApiAllowance,
                    resetDate: admin.periodEnd ?? manualReset,
                    unit: admin.currency,
                    subtitle: "Available via the API and Studio"
                )
            )
        } else if let apiSpend = rawManualApiSpend {
            windows.append(
                QuotaWindow(
                    label: "API usage",
                    windowKind: .monthly,
                    used: apiSpend,
                    total: manualApiAllowance,
                    resetDate: manualReset,
                    unit: manualCurrency,
                    subtitle: "Available via the API and Studio"
                )
            )
        }

        // Vibe meter: web page, then Admin API split, then the manual anchor
        // advanced by the local watermark, then the pure local estimate.
        if let webResult, let vibeSpent = webResult.vibeSpent {
            let vibeAllowance = webResult.vibeAllowance
                ?? manualVibeAllowance
                ?? MistralVibeBudgetResolver.effectiveAllowance(rawAllowance: nil, currency: webResult.currency, planName: webResult.planName ?? planName, configuredBudgetUSD: budgetUSD)
            windows.append(
                QuotaWindow(
                    label: "Vibe Code usage",
                    windowKind: .monthly,
                    used: vibeSpent,
                    total: vibeAllowance,
                    resetDate: webResult.periodEnd ?? manualReset,
                    unit: webResult.currency,
                    subtitle: "Vibe Code includes extra monthly usage"
                )
            )
        } else if let admin, let vibeSpend = admin.vibeSpend {
            let adminVibeAllowance = manualVibeAllowance.flatMap {
                MistralVibeBudgetResolver.convert($0, from: manualCurrency, to: admin.currency)
            } ?? (admin.currency == "USD" ? budgetUSD : nil)
            windows.append(
                QuotaWindow(
                    label: "Vibe Code usage",
                    windowKind: .monthly,
                    used: vibeSpend,
                    total: adminVibeAllowance,
                    resetDate: admin.periodEnd ?? manualReset,
                    unit: admin.currency,
                    subtitle: "Vibe Code includes extra monthly usage"
                )
            )
        } else if let manualSpend = manualVibeSpend {
            if let manualReset, manualReset <= now {
                signals.append(
                    QuotaSignal(
                        kind: .scheduledReset,
                        title: "Billing anchor expired",
                        message: "Update the Mistral Vibe Code reading for the new billing cycle.",
                        severity: .info,
                        confidence: 1,
                        windowLabel: "Vibe Code usage",
                        detectedAt: now
                    )
                )
            } else {
                let baseSignature = fields[SpendProviderCredentialField.anchorUpdatedAt]
                    ?? "\(manualSpend)|\(rawManualVibeAllowance ?? 0)|\(manualReset?.timeIntervalSince1970 ?? 0)"
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
                    now: now,
                    defaults: watermarkDefaults
                )
                windows.append(
                    QuotaWindow(
                        label: "Vibe Code usage",
                        windowKind: .monthly,
                        used: adjustment.spend,
                        total: manualVibeAllowance,
                        resetDate: manualReset,
                        unit: manualCurrency,
                        subtitle: adjustment.localIncrement > 0
                            ? "Manual Vibe reading plus TaskWraith-style local estimate"
                            : "Vibe Code includes extra monthly usage"
                    )
                )
            }
        } else if let local {
            let localCurrency = manualCurrency
            let localSpend = MistralVibeBudgetResolver.amountInCurrency(
                local.currentMonthCostUSD,
                currency: localCurrency
            ) ?? local.currentMonthCostUSD
            windows.append(
                QuotaWindow(
                    label: "Vibe Code usage",
                    windowKind: .monthly,
                    used: localSpend,
                    total: manualVibeAllowance,
                    resetDate: manualReset,
                    unit: localCurrency,
                    subtitle: discardedLegacyAnchor
                        ? "TaskWraith-style local estimate; legacy shared-pool anchor ignored"
                        : "TaskWraith-style local estimate"
                )
            )
        }

        return MeterAssembly(
            windows: windows,
            signals: signals,
            planName: webResult?.planName ?? planName
        )
    }

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
        let webSessionCookie = fields["mistralCookieHeader"] ?? fields["mistralCookie"]
        let webResult: MistralWebSubscriptionResult? = if let webSessionCookie, !webSessionCookie.isEmpty {
            await MistralWebSubscriptionClient().fetch(
                cookieHeader: webSessionCookie,
                now: now,
                persistCookieHeader: {
                    await persistImportedCookieHeader(
                        $0,
                        providerID: .mistral,
                        field: "mistralCookieHeader"
                    )
                }
            )
        } else {
            nil
        }

        if let webSessionCookie, !webSessionCookie.isEmpty {
            if let webResult {
                print("[MistralProvider] Web parse api=\(webResult.apiSpent.map { String($0) } ?? "nil") vibe=\(webResult.vibeSpent.map { String($0) } ?? "nil")")
            } else {
                print("[MistralProvider] Web parse yielded no meters (signed out, network failure, or page layout change)")
            }
        }

        let assembly = Self.assembleMeters(
            webResult: webResult,
            admin: admin,
            local: local,
            fields: fields,
            fallbackManualAllowance: positiveDouble(credentials?.normalizedAccountIdentifier),
            budgetUSD: ProviderMonthlyBudgetStore.nonisolatedBudgetUSD(for: .mistral),
            now: now
        )
        let windows = assembly.windows
        let signals = assembly.signals
        var stats: [QuotaStat] = []

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
            planName: assembly.planName ?? (admin == nil ? "Vibe" : "Admin API"),
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
        let totalBalance: Double
        let grantedBalance: Double
        let toppedUpBalance: Double

        enum CodingKeys: String, CodingKey {
            case currency
            case totalBalance = "total_balance"
            case grantedBalance = "granted_balance"
            case toppedUpBalance = "topped_up_balance"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            currency = try container.decode(String.self, forKey: .currency)
            totalBalance = try Self.decodeAmount(container, forKey: .totalBalance)
            grantedBalance = try Self.decodeAmount(container, forKey: .grantedBalance)
            toppedUpBalance = try Self.decodeAmount(container, forKey: .toppedUpBalance)
        }

        private static func decodeAmount(
            _ container: KeyedDecodingContainer<CodingKeys>,
            forKey key: CodingKeys
        ) throws -> Double {
            if try container.decodeNil(forKey: key) {
                return 0
            }
            if let value = try? container.decode(Double.self, forKey: key) {
                return value
            }
            if let value = try? container.decode(Int.self, forKey: key) {
                return Double(value)
            }
            if let value = try? container.decode(String.self, forKey: key),
               let parsed = Double(value.trimmingCharacters(in: .whitespacesAndNewlines)) {
                return parsed
            }
            if let value = try? container.decode(String.self, forKey: key),
               let parsed = Double(value.replacingOccurrences(of: ",", with: "")),
               parsed.isFinite {
                return parsed
            }
            throw DecodingError.typeMismatch(
                Double.self,
                .init(
                    codingPath: container.codingPath + [key],
                    debugDescription: "Expected numeric balance value for \(key.rawValue)"
                )
            )
        }
    }

    let isAvailable: Bool
    let balanceInfos: [Balance]

    enum CodingKeys: String, CodingKey {
        case isAvailable = "is_available"
        case balanceInfos = "balance_infos"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        isAvailable = try container.decodeIfPresent(Bool.self, forKey: .isAvailable) ?? true
        balanceInfos = try container.decodeIfPresent([Balance].self, forKey: .balanceInfos) ?? []
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
                ?? decoded.balanceInfos.first else {
            return nil
        }
        return DeepSeekBalanceObservation(
            isAvailable: decoded.isAvailable,
            currency: selected.currency.uppercased(),
            totalBalance: selected.totalBalance,
            grantedBalance: selected.grantedBalance,
            toppedUpBalance: selected.toppedUpBalance
        )
    }
}

enum DeepSeekTopUpMeter {
    static func creditUsed(totalTopUp: Double?, currentBalance: Double) -> Double? {
        guard let totalTopUp, totalTopUp > 0 else { return nil }
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
            planName: "API Credits",
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

private func cachedCerebrasWebBillingReading(from fields: [String: String]) -> WebBillingReading? {
    let balance = nonnegativeDouble(fields[SpendProviderCredentialField.cerebrasCachedBalance])
    let spend = nonnegativeDouble(fields[SpendProviderCredentialField.cerebrasCachedSpend])
    guard balance != nil || spend != nil else { return nil }

    return WebBillingReading(
        balance: balance,
        spend: spend,
        currency: normalizedCurrency(fields[SpendProviderCredentialField.cerebrasCachedCurrency]),
        periodEnd: ProviderDateParser.parse(fields[SpendProviderCredentialField.cerebrasCachedResetAt])
    )
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
        let webCookie = fields[SpendProviderCredentialField.cerebrasCookieHeader]
        let browserResult: BrowserMeterResult<WebBillingReading>?
        if let webCookie, !webCookie.isEmpty {
            let endpoint = BrowserSessionRefreshPolicy.validatedURL(
                fields[SpendProviderCredentialField.browserSessionURL],
                // Org-agnostic on purpose: the fallback used to embed the
                // maintainer's own org id, so a user without an override was
                // pointed at someone else's account. `validatedURL` matches on
                // host only, so an override saved before this change still wins.
                fallback: URL(string: "https://cloud.cerebras.ai/platform/billing")!
            )
            browserResult = await BrowserMeterRefreshStore.shared.read(
                url: endpoint,
                sessionID: fields[SpendProviderCredentialField.browserSessionID] ?? webCookie,
                initial: cachedCerebrasWebBillingReading(from: fields),
                initialAt: ProviderDateParser.parse(fields[SpendProviderCredentialField.cerebrasCachedAt]),
                interval: 5 * 60,
                failureInterval: 15 * 60,
                now: now,
                fetch: {
                    #if os(macOS)
                    let text = try await ImportedSessionPageReader.read(url: endpoint, cookieHeader: webCookie) {
                        WebBillingClient.parse(html: $0, now: now)?.balance != nil
                    }
                    guard let reading = WebBillingClient.parse(html: text, now: now) else {
                        throw ProviderFetchError.parsingError("Cerebras billing balance unavailable.")
                    }
                    return reading
                    #else
                    throw ProviderFetchError.credentialExpired("Reconnect Cerebras in the browser on your Mac.")
                    #endif
                }
            )
        } else {
            browserResult = nil
        }
        if let failure = browserResult?.failureError { throw failure }
        let webReading = browserResult?.value ?? cachedCerebrasWebBillingReading(from: fields)

        let purchased = positiveDouble(credentials?.normalizedAccountIdentifier)
             ?? positiveDouble(fields[SpendProviderCredentialField.manualAllowance])
         // Web reading overrides manual current balance when present.
        let current = webReading?.balance
             ?? nonnegativeDouble(fields[SpendProviderCredentialField.manualCurrentBalance])
        let manualCurrency = webReading?.currency
             ?? normalizedCurrency(fields[SpendProviderCredentialField.manualCurrency])
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
                    subtitle: browserResult?.sourceDescription ?? "Manual billing anchor"
                )
            )
        }
        if let current {
            balances.append(
                QuotaBalance(
                    label: "Current balance",
                    amount: current,
                    unit: manualCurrency,
                    subtitle: browserResult?.sourceDescription
                        ?? (webReading?.balance != nil ? "Captured at import" : "Manual billing anchor")
                )
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

        guard !windows.isEmpty || !balances.isEmpty || taskWraith != nil else {
            throw ProviderFetchError.notConfigured
        }
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
            fetchState: .success,
            fetchedAt: browserResult?.fetchedAt ?? (webCookie == nil ? now
                : ProviderDateParser.parse(fields[SpendProviderCredentialField.cerebrasCachedAt]) ?? .distantPast)
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
                // Muse reports cache reads inside input. Analytics buckets use
                // disjoint categories so cached tokens are counted only once.
                inputTokens: max(0, value.input - value.cached),
                outputTokens: value.output,
                cachedInputTokens: value.cached,
                requests: value.requests,
                costUSD: value.cost,
                source: .localEstimate,
                note: "Muse session tokens (cache separated) × catalog rates"
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
            // Keep this legacy summary's input total cache-inclusive.
            inputTokens: buckets.reduce(0) { $0 + $1.inputTokens + $1.cachedInputTokens },
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

// MARK: - Token Plan web metering (Qwen Model Studio / Xiaomi MiMo)

/// The rolling period a token-plan console's single quota meter covers.
///
/// Model Studio moved its Standard plan from a 7-day rolling quota to a
/// monthly one, and serves both vintages from the same Plan Quota card with
/// the same layout — only the heading and the reset date differ. The period
/// therefore has to be read rather than assumed, because it decides the
/// meter's label, which period bucket it lands in, and how far ahead its
/// reset may legitimately fall.
public enum TokenPlanMeterPeriod: String, Sendable, Codable, Equatable {
    case weekly
    case monthly

    /// How far ahead a reset for this period can fall and still be believed.
    ///
    /// The bound is a guard against a subscription *end* date — potentially
    /// years out — being mistaken for the next usage reset, so it sits just
    /// past one full period rather than at a round number.
    var maximumResetLeadTime: TimeInterval {
        switch self {
        case .weekly:  return 8 * 24 * 60 * 60
        case .monthly: return 40 * 24 * 60 * 60
        }
    }
}

/// How a token-plan meter is presented for one period. The label drives both
/// the card's wording and the period bucket it is grouped into, so the two
/// have to agree — a meter labelled "Monthly" but keyed `.weekly` would be
/// filed under Weekly.
public struct TokenPlanWindow: Equatable {
    public let label: String
    public let kind: QuotaWindowKind

    public init(label: String, kind: QuotaWindowKind) {
        self.label = label
        self.kind = kind
    }
}

/// A percent-based plan-quota reading scraped from a token-plan dashboard.
/// These consoles render "Monthly Usage — N% Used" style meters rather than
/// currency balances, so the generic WebBillingClient currency parser does not
/// apply. `meterPeriod` says which rolling window the meter covers, because the
/// same card layout serves both a 7-day and a monthly plan.
public nonisolated struct TokenPlanWebReading: Sendable, Codable {
    public let quotaUsedPercent: Double?
    public let planName: String?
    public let remainingDays: Int?
    public let periodEnd: Date?
    /// Banked usage-limit resets the console offers to redeem ("Reset ⓘ 1
    /// available"); nil when the source did not show the figure.
    public let resetAvailableCount: Int?
    /// The period the meter itself reports, or nil when the source gave no
    /// signal — callers then fall back to the provider's default.
    public let meterPeriod: TokenPlanMeterPeriod?

    public init(
        quotaUsedPercent: Double?,
        planName: String?,
        remainingDays: Int?,
        periodEnd: Date?,
        resetAvailableCount: Int? = nil,
        meterPeriod: TokenPlanMeterPeriod? = nil
    ) {
        self.quotaUsedPercent = quotaUsedPercent
        self.planName = planName
        self.remainingDays = remainingDays
        self.periodEnd = periodEnd
        self.resetAvailableCount = resetAvailableCount
        self.meterPeriod = meterPeriod
    }

    public var isEmpty: Bool {
        quotaUsedPercent == nil && planName == nil && remainingDays == nil && periodEnd == nil
    }
}

public enum TokenPlanResetDatePolicy: Sendable, Equatable {
    case usageResetOnly
    case planEndFallback
}

/// Fetches and renders a token-plan console page with the imported browser
/// session, then parses the visible quota meter. Qwen and MiMo are client-side
/// applications: a plain URLSession request only receives their JavaScript
/// shell and cannot see the values shown in the browser.
/// The rendered path also preserves WebKit local-storage authentication.
public struct TokenPlanWebClient: Sendable {
    public let baseURL: URL
    public let resetDatePolicy: TokenPlanResetDatePolicy

    public init(
        baseURL: URL,
        resetDatePolicy: TokenPlanResetDatePolicy = .planEndFallback
    ) {
        self.baseURL = baseURL
        self.resetDatePolicy = resetDatePolicy
    }

    public func fetch(cookieHeader: String) async -> TokenPlanWebReading? {
        guard !cookieHeader.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }

        #if os(macOS)
        return await TokenPlanRenderedPageReader.read(
            url: baseURL,
            cookieHeader: cookieHeader,
            resetDatePolicy: resetDatePolicy
        )
        #else
        var request = URLRequest(url: baseURL, timeoutInterval: 15)
        request.httpMethod = "GET"
        request.httpShouldHandleCookies = false
        request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125.0.0.0 Safari/537.36",
            forHTTPHeaderField: "User-Agent"
        )
        request.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")

        // Cookie-inert session: console pages rotate session cookies via
        // Set-Cookie, and the shared cookie jar would override the imported
        // Keychain header on every fetch after the first.
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpCookieStorage = nil
        configuration.timeoutIntervalForRequest = 15
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }

        guard let (data, response) = try? await session.data(for: request),
              let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode),
              let html = String(data: data, encoding: .utf8) else {
            return nil
        }

        return Self.parse(html: html, resetDatePolicy: resetDatePolicy)
        #endif
    }

    // MARK: Parsing

    static func parse(
        html: String,
        resetDatePolicy: TokenPlanResetDatePolicy = .planEndFallback
    ) -> TokenPlanWebReading? {
        let renderedText = MistralWebSubscriptionClient.normalizedRenderedText(from: html)
        let payloadText = MistralWebSubscriptionClient.normalizedScriptPayloadText(from: html)

        return parse(
            renderedText: renderedText,
            payloadText: payloadText,
            resetDatePolicy: resetDatePolicy
        )
    }

    static func parse(renderedText: String) -> TokenPlanWebReading? {
        return parse(
            renderedText: MistralWebSubscriptionClient.normalizedRenderedText(from: renderedText),
            payloadText: "",
            resetDatePolicy: .planEndFallback
        )
    }

    static func parseQwen(renderedText: String) -> TokenPlanWebReading? {
        return parse(
            renderedText: MistralWebSubscriptionClient.normalizedRenderedText(from: renderedText),
            payloadText: "",
            resetDatePolicy: .usageResetOnly
        )
    }

    private static func parse(
        renderedText: String,
        payloadText: String,
        resetDatePolicy: TokenPlanResetDatePolicy
    ) -> TokenPlanWebReading? {
        let quotaUsedPercent = firstMatch(pattern: "(\\d+(?:\\.\\d+)?)\\s*%\\s*Used", in: renderedText)
            .flatMap { Double($0) }
            ?? firstMatch(pattern: "(\\d+(?:\\.\\d+)?)\\s*%\\s*Used", in: payloadText).flatMap { Double($0) }
            ?? firstMatch(pattern: "Used[^0-9%]{0,40}(\\d+(?:\\.\\d+)?)\\s*%", in: renderedText).flatMap { Double($0) }
            ?? firstMatch(pattern: "Used[^0-9%]{0,40}(\\d+(?:\\.\\d+)?)\\s*%", in: payloadText).flatMap { Double($0) }
            ?? firstMatch(pattern: Self.percentAfterResetRowPattern, in: renderedText).flatMap { Double($0) }
            ?? firstMatch(pattern: Self.percentAfterResetRowPattern, in: payloadText).flatMap { Double($0) }
        let remainingDays = firstMatch(pattern: "Remaining\\s*Days?\\s*:?\\s*(\\d+)", in: renderedText)
            .flatMap { Int($0) }
            ?? firstMatch(pattern: "Remaining\\s*Days?\\s*:?\\s*(\\d+)", in: payloadText).flatMap { Int($0) }
        let planName = planName(in: renderedText) ?? planName(in: payloadText)
        let periodEnd = periodEnd(in: renderedText, resetDatePolicy: resetDatePolicy)
            ?? periodEnd(in: payloadText, resetDatePolicy: resetDatePolicy)
        let resetAvailableCount = resetAvailableCount(in: renderedText)
            ?? resetAvailableCount(in: payloadText)
        let meterPeriod = meterPeriod(in: renderedText)

        let reading = TokenPlanWebReading(
            quotaUsedPercent: quotaUsedPercent.flatMap { (0...100).contains($0) ? $0 : nil },
            planName: planName,
            remainingDays: remainingDays,
            periodEnd: periodEnd,
            resetAvailableCount: resetAvailableCount,
            meterPeriod: meterPeriod
        )
        return reading.isEmpty ? nil : reading
    }

    /// Model Studio's Plan Quota card shows the banked resets beside its
    /// Reset button — "Reset ⓘ 1 available". The gap allows the icon and a
    /// line break but not a percent sign, so the meter's own "Will reset at
    /// … 100%" row can never supply the number.
    static func resetAvailableCount(in text: String) -> Int? {
        firstMatch(pattern: #"\bReset\b[^%]{0,40}?(\d{1,2})\s*available"#, in: text)
            .flatMap(Int.init)
    }

    /// Reads the period from the meter's own heading.
    ///
    /// Only the rendered text is consulted, never the script payload. The
    /// payload carries the console's whole i18n table, which names both meters,
    /// so it could only ever answer "monthly" and would drown out the heading
    /// actually on screen.
    static func meterPeriod(in text: String) -> TokenPlanMeterPeriod? {
        // The heading that owns the reset row is authoritative; see below.
        if let anchored = anchoredMeterPeriod(in: text) { return anchored }
        // Otherwise fall back to any heading, monthly first. Monthly is the
        // current Standard plan, and a false monthly is the cheap mistake: a
        // false *weekly* also narrows the accepted reset window to eight days
        // and silently drops a monthly boundary.
        if anyMatch(monthlyHeadingRegexes, in: text) { return .monthly }
        if anyMatch(weeklyHeadingRegexes, in: text) { return .weekly }
        return nil
    }

    /// The period named by the heading immediately before the meter's reset row.
    ///
    /// `normalizedRenderedText` flattens the whole card onto a single line, so
    /// proximity proves nothing on its own — after flattening, every word is
    /// next to every other and a "Billing Month" row three blocks up sits
    /// directly beside an "Usage Statistics" heading. Order still proves
    /// something, though: the heading is the last thing before "Will reset at",
    /// and this pattern has to reach that row crossing nothing but whitespace,
    /// so an earlier "Month" cannot claim it and the word that can is the one
    /// the meter is actually wearing.
    private static func anchoredMeterPeriod(in text: String) -> TokenPlanMeterPeriod? {
        guard let heading = firstMatch(pattern: anchoredPeriodPattern, in: text) else { return nil }
        return heading.lowercased().hasPrefix("month") ? .monthly : .weekly
    }

    private static let anchoredPeriodPattern =
        "(Month(?:ly)?|(?:7|Seven)[\\s-]*Days?|Week(?:ly)?|30[\\s-]*Days?)"
        + "\\s*(?:Usage|Used|Quota|Limit|Allowance)?\\s*Will\\s+reset\\s+at"

    /// The meter's heading, which is the only text on the Plan Quota card that
    /// names its period — the reset row, the progress bar and the percent are
    /// identical for both.
    ///
    /// These are the fallback for a card whose reset row did not render. The
    /// noun is what keeps a "Standard Monthly Plan" tier out of it — "Plan" is
    /// not one. The gap covers U+00A0 as well as spaces and tabs, because
    /// `innerText` keeps `&nbsp;` and the heading is markup that can produce
    /// one; it deliberately excludes line breaks so a heading cannot reach the
    /// next block when this runs against text that has *not* been flattened.
    private static func headingRegexes(_ phrases: [String]) -> [NSRegularExpression] {
        let noun = "(?:Usage|Used|Quota|Limit|Allowance)\\b"
        let gap = "[ \t\u{00A0}]"
        let dayGap = "[- \t\u{00A0}]"
        // A literal that failed to compile would silently disable detection,
        // so the heading tests below double as a check on these patterns.
        return phrases.compactMap { phrase in
            let pattern = phrase
                .replacingOccurrences(of: "{noun}", with: noun)
                .replacingOccurrences(of: "{gap}", with: gap)
                .replacingOccurrences(of: "{dayGap}", with: dayGap)
            return try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        }
    }

    private static let monthlyHeadingRegexes = headingRegexes([
        "\\bMonth(?:ly)?{gap}*{noun}",
        "\\b(?:30|Thirty){dayGap}*Days?{gap}*{noun}"
    ])

    private static let weeklyHeadingRegexes = headingRegexes([
        "\\b(?:7|Seven){dayGap}*Days?{gap}*{noun}",
        "\\bWeek(?:ly)?{gap}*{noun}"
    ])

    /// Whether any of `regexes` matches somewhere in `text`.
    ///
    /// `firstMatch(pattern:in:)` cannot answer this: it returns nil whenever
    /// its capture group did not participate in the match, so a heading with an
    /// optional noun would read as no match at all.
    private static func anyMatch(_ regexes: [NSRegularExpression], in text: String) -> Bool {
        guard !text.isEmpty else { return false }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regexes.contains { $0.firstMatch(in: text, options: [], range: range) != nil }
    }

    /// Reads Model Studio's plan-quota meter.
    ///
    /// The meter used to render its value against its label ("0% Used"), which
    /// the two patterns above match. It now renders that value at the far end
    /// of the reset row instead —
    /// "7-Day Used … Will reset at 2026-09-16 10:03:00 (UTC+8) 100%" — and both
    /// of those patterns stop at the first digit of the timestamp, so the meter
    /// stopped parsing and neither the session import nor the background
    /// refresh could see a quota at all.
    ///
    /// The monthly meter the Standard plan moved to renders identically apart
    /// from its heading — "Monthly Usage … Will reset at 2026-09-26 00:00:00
    /// (UTC+8) 0%" — so this pattern serves both and only `meterPeriod(in:)`
    /// has to tell them apart.
    ///
    /// Anchoring on the reset row steps over the timestamp while staying
    /// specific to the row that owns the number. Barring `%` from the gap stops
    /// the match running past the meter into the progress bar's "0% / 100%"
    /// axis labels below it.
    ///
    /// Keying off the axis labels instead — take every percentage in the card,
    /// drop one "0%" and one "100%", keep the survivor — looks more robust and
    /// is not: the import sheet's embedded browser is narrow enough to scroll
    /// the axis out of the rendered text entirely, so that rule finds nothing
    /// there. Only the value itself is reliably present in both callers' text.
    private static let percentAfterResetRowPattern =
        "Will\\s*reset\\s*at[^%()]{0,60}\\(UTC[^)]{0,10}\\)\\s*(\\d+(?:\\.\\d+)?)\\s*%"

    private static func firstMatch(pattern: String, in text: String) -> String? {
        guard !text.isEmpty else { return nil }
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range),
              match.numberOfRanges > 1,
              let capture = Range(match.range(at: 1), in: text) else {
            return nil
        }
        return String(text[capture])
    }

    private static func planName(in text: String) -> String? {
        // MiMo renders "Lite Monthly Plan" before the renewal and validity labels.
        if let namedTier = firstMatch(
            pattern: "\\b((?:Lite|Free|Pro|Team|Enterprise|Personal|Basic|Standard|Premium)(?:\\s+[A-Za-z0-9+._-]+){0,3}\\s+Plan)\\b",
            in: text
        ) {
            return normalizedTokenPlanName(namedTier)
        }

        // Filter out generic phrases so "Token Plan" chrome never becomes
        // the plan name.
        let blacklist: Set<String> = ["token", "the", "your", "a", "an", "this", "subscription", "upgrade"]
        var searchStart = text.startIndex
        while searchStart < text.endIndex,
              let range = text.range(of: "Plan", options: .caseInsensitive, range: searchStart..<text.endIndex) {
            let lineStart = text[..<range.lowerBound].lastIndex(of: "\n") ?? text.startIndex
            let prefix = String(text[lineStart..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
            let words = prefix.split(separator: " ")
            if let last = words.last {
                let candidate = last.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
                let lowered = candidate.lowercased()
                if candidate.count >= 2, candidate.count <= 24, !blacklist.contains(lowered) {
                    return normalizedTokenPlanName(candidate + " Plan")
                }
            }
            searchStart = range.upperBound
        }
        return nil
    }

    private static func periodEnd(
        in text: String,
        resetDatePolicy: TokenPlanResetDatePolicy
    ) -> Date? {
        if let usageReset = timestamp(after: "Will\\s*reset\\s*at", in: text) {
            return usageReset
        }
        guard resetDatePolicy == .planEndFallback else { return nil }
        return timestamp(after: "(?:End\\s*Time|Valid\\s*until)", in: text)
    }

    private static func timestamp(after labelPattern: String, in text: String) -> Date? {
        let datePart = firstMatch(
            pattern: "\(labelPattern)\\s*:?\\s*(\\d{4}-\\d{2}-\\d{2})",
            in: text
        )
        guard let datePart else {
            return nil
        }
        let timePart = firstMatch(
            pattern: "\(labelPattern)\\s*:?\\s*\\d{4}-\\d{2}-\\d{2}\\s+(\\d{2}:\\d{2}(?::\\d{2})?)",
            in: text
        )
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let utcOffsetHours = firstMatch(
            pattern: "\(labelPattern)[^\\n]{0,96}\\(\\s*UTC\\s*([+-]\\d{1,2})\\s*\\)",
            in: text
        ).flatMap(Int.init)
        formatter.timeZone = utcOffsetHours.flatMap { TimeZone(secondsFromGMT: $0 * 3_600) }
            ?? TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = timePart != nil ? "yyyy-MM-dd HH:mm:ss" : "yyyy-MM-dd"
        if timePart?.count == 5 { formatter.dateFormat = "yyyy-MM-dd HH:mm" }
        return formatter.date(from: timePart != nil ? "\(datePart) \(timePart!)" : datePart)
    }
}

#if os(macOS)
/// Loads the same browser session used during import.
@MainActor
private enum TokenPlanRenderedPageReader {
    static func read(url: URL, cookieHeader: String, resetDatePolicy: TokenPlanResetDatePolicy) async -> TokenPlanWebReading? {
        guard let text = try? await ImportedSessionPageReader.read(url: url, cookieHeader: cookieHeader, isReady: {
            TokenPlanWebClient.parse(html: $0, resetDatePolicy: resetDatePolicy)?.quotaUsedPercent != nil
        }) else { return nil }
        return TokenPlanWebClient.parse(html: text, resetDatePolicy: resetDatePolicy)
    }
}
#endif

public struct QwenProviderClient: ProviderClient {
    public let providerID: ProviderID = .qwen

    public init() {}

    public func fetchSnapshot(credentials: ProviderCredential?) async throws -> QuotaSnapshot {
        try await tokenPlanSnapshot(
            providerID: .qwen,
            credentials: credentials,
            dashboardURL: URL(string: "https://modelstudio.console.alibabacloud.com/ap-southeast-1?tab=plan&productCode=p_efm#/efm/subscription/token-plan/personal")!,
            cookieField: SpendProviderCredentialField.qwenCookieHeader,
            resetDatePolicy: .usageResetOnly,
            // The Standard plan's quota is monthly now, so that is the default;
            // an account still on the old rolling window is detected and
            // labelled from the console instead.
            windowLabel: "Monthly Usage",
            windowKind: .monthly,
            defaultPlanName: "Token Plan",
            consoleUsageAPI: .qwenPersonalUsage,
            periodWindows: [
                .monthly: TokenPlanWindow(label: "Monthly Usage", kind: .monthly),
                .weekly: TokenPlanWindow(label: "7-Day Quota", kind: .weekly)
            ]
        )
    }
}

public struct MimoProviderClient: ProviderClient {
    public let providerID: ProviderID = .mimo

    public init() {}

    public func fetchSnapshot(credentials: ProviderCredential?) async throws -> QuotaSnapshot {
        try await tokenPlanSnapshot(
            providerID: .mimo,
            credentials: credentials,
            dashboardURL: URL(string: "https://platform.xiaomimimo.com/console/plan-manage")!,
            cookieField: SpendProviderCredentialField.mimoCookieHeader,
            resetDatePolicy: .planEndFallback,
            windowLabel: "Plan Quota",
            windowKind: .monthly,
            defaultPlanName: "MiMo Plan"
        )
    }
}

/// Coordinates for one Model Studio console-gateway API.
///
/// The console reaches its own backend through a CLI gateway that takes the
/// target API as an RPC name. Region and site pick the gateway host and action:
/// `ap-southeast-1` on the international site answers on
/// `bailian-singapore-cs.alibabacloud.com` / `IntlBroadScopeAspnGateway`.
struct TokenPlanConsoleAPI {
    let host: String
    let action: String
    let region: String
    let api: String
    let referer: String

    static let qwenPersonalUsage = TokenPlanConsoleAPI(
        host: "bailian-singapore-cs.alibabacloud.com",
        action: "IntlBroadScopeAspnGateway",
        region: "ap-southeast-1",
        api: "zeldaHttp.apikeyMgr./tokenplan/personal/api/v2/usage",
        referer: "https://modelstudio.console.alibabacloud.com/"
    )

    /// The personal plan's subscription record on the same gateway; the
    /// console's Plan Quota card draws its reset allowance from here.
    static let qwenPersonalSubscription = TokenPlanConsoleAPI(
        host: "bailian-singapore-cs.alibabacloud.com",
        action: "IntlBroadScopeAspnGateway",
        region: "ap-southeast-1",
        api: "zeldaHttp.apikeyMgr./tokenplan/personal/api/v2/subscription",
        referer: "https://modelstudio.console.alibabacloud.com/"
    )

    /// The banked reset cards the Plan Quota card's "{n} available" badge
    /// counts. The badge is the length of this list, not a field on the
    /// subscription record, so this is the authoritative source for it.
    static let qwenPersonalResetCards = TokenPlanConsoleAPI(
        host: "bailian-singapore-cs.alibabacloud.com",
        action: "IntlBroadScopeAspnGateway",
        region: "ap-southeast-1",
        api: "zeldaHttp.apikeyMgr./tokenplan/personal/api/v2/reset-card/list",
        referer: "https://modelstudio.console.alibabacloud.com/"
    )

    var subscriptionSibling: TokenPlanConsoleAPI? {
        api == Self.qwenPersonalUsage.api ? Self.qwenPersonalSubscription : nil
    }

    /// The reset-card list sits beside the usage API the same way.
    var resetCardSibling: TokenPlanConsoleAPI? {
        api == Self.qwenPersonalUsage.api ? Self.qwenPersonalResetCards : nil
    }
}

/// Chooses which failure to report when both token-plan sources missed.
///
/// The kind decides, not the order the sources ran in. A rejected credential is
/// the more useful verdict because the user can act on it, so it wins whichever
/// side it came from; when neither side has one, the page's own error is more
/// specific, since the page is what the user is being asked to look at. Getting
/// this backwards is the bug this replaced: the API's credential rejection used
/// to be thrown from inside the fetch, so the scrape never ran and a readable
/// page was reported as "Parse error: Qwen console session expired".
enum TokenPlanFailureChoice {
    static func preferred(scrape: Error, api: Error?) -> Error {
        if (scrape as? ProviderFetchError)?.isCredentialFailure == true { return scrape }
        if let api, (api as? ProviderFetchError)?.isCredentialFailure == true { return api }
        return scrape
    }
}

/// Reads the Token Plan quota as data instead of scraping the rendered console.
///
/// The console draws its quota meter from this API, and the same session cookie
/// the app already imports authenticates it. Scraping the page for the same
/// number was fragile in a way that could not be fixed by better patterns: the
/// value's position relative to the progress bar's "0% / 100%" axis labels is
/// not stable in flat `innerText`, and the readiness poll driving the refresh
/// would accept an axis label the moment it painted — reporting a confident 0%
/// against a page showing 100%. This returns the figure the console itself uses.
enum TokenPlanConsoleAPIClient {
    /// The `*Percentage` fields are 0-1 fractions, not percentages: the console
    /// renders them as `percentage * 100`, and this account read `1.0` while the
    /// page displayed 100%. The `*ResetTime` fields are epoch milliseconds.
    /// Standard plans report the `per1Month*` pair; older weekly plans report
    /// `per1Week*`. Both live on the same response.
    static func usageReading(
        _ config: TokenPlanConsoleAPI = .qwenPersonalUsage,
        cookieHeader: String
    ) async throws -> TokenPlanWebReading? {
        guard let data = try await requestData(config, cookieHeader: cookieHeader) else { return nil }
        return try parseUsage(data)
    }

    /// Best-effort read of the banked reset count from the subscription
    /// record. The field is undocumented, so the payload is scanned for a key
    /// that pairs "reset" with a count-like word and holds a small integer;
    /// its top-level keys are logged so a renamed field is easy to spot.
    static func resetAvailableCount(
        _ config: TokenPlanConsoleAPI = .qwenPersonalSubscription,
        cookieHeader: String
    ) async throws -> Int? {
        guard let data = try await requestData(config, cookieHeader: cookieHeader) else { return nil }
        return parseResetAvailableCount(data)
    }

    /// Counts the banked resets from the console's own reset-card list, which
    /// is where its "{n} available" badge actually comes from.
    static func resetCardCount(
        _ config: TokenPlanConsoleAPI = .qwenPersonalResetCards,
        cookieHeader: String
    ) async throws -> Int? {
        guard let data = try await requestData(config, cookieHeader: cookieHeader) else { return nil }
        return parseResetCardCount(data)
    }

    static func parseResetAvailableCount(_ data: Data) -> Int? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let envelope = root["data"] as? [String: Any] else { return nil }
        if let succeeded = envelope["success"] as? Bool, !succeeded { return nil }
        guard let dataV2 = envelope["DataV2"] as? [String: Any],
              let body = dataV2["data"] as? [String: Any] else { return nil }
        let payload = (body["data"] as? [String: Any]) ?? body
        print("[TokenPlanConsoleAPI] subscription payload keys: \(payload.keys.sorted())")
        return resetAvailableCount(in: payload)
    }

    /// `insideResetObject` relaxes the key test for the children of an
    /// object that was itself named for resets (`resetInfo.availableTimes`).
    static func resetAvailableCount(
        in payload: [String: Any],
        depth: Int = 0,
        insideResetObject: Bool = false
    ) -> Int? {
        let countWords = ["count", "times", "remain", "avail", "num", "quantity", "left"]
        for key in payload.keys.sorted() {
            let lowered = key.lowercased()
            guard insideResetObject || lowered.contains("reset"),
                  countWords.contains(where: { lowered.contains($0) }),
                  let number = numericValue(payload[key]),
                  number >= 0, number <= 50, number == number.rounded() else {
                continue
            }
            return Int(number)
        }
        guard depth < 2 else { return nil }
        for key in payload.keys.sorted() {
            if let nested = payload[key] as? [String: Any],
               let count = resetAvailableCount(
                   in: nested,
                   depth: depth + 1,
                   insideResetObject: insideResetObject || key.lowercased().contains("reset")
               ) {
                return count
            }
        }
        return nil
    }

    private static func requestData(
        _ config: TokenPlanConsoleAPI,
        cookieHeader: String
    ) async throws -> Data? {
        var components = URLComponents()
        components.scheme = "https"
        components.host = config.host
        components.path = "/cli/api.json"
        components.queryItems = [
            URLQueryItem(name: "action", value: config.action),
            URLQueryItem(name: "product", value: "sfm_bailian"),
            URLQueryItem(name: "api", value: config.api)
        ]
        guard let url = components.url else { return nil }

        let params: [String: Any] = [
            "Api": config.api,
            "V": "1.0",
            "Data": [
                "cornerstoneParam": [
                    "protocol": "V2",
                    "console": "ONE_CONSOLE",
                    "productCode": "p_efm",
                    "switchUserType": 3,
                    "consoleSite": "BAILIAN_ALIYUN"
                ]
            ]
        ]
        guard let paramsData = try? JSONSerialization.data(withJSONObject: params),
              let paramsJSON = String(data: paramsData, encoding: .utf8) else { return nil }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        // The gateway is a different host from the console page that normally
        // calls it, so it sees these as cross-origin and expects both.
        request.setValue("https://modelstudio.console.alibabacloud.com", forHTTPHeaderField: "Origin")
        request.setValue(config.referer, forHTTPHeaderField: "Referer")
        request.httpBody = formEncodedBody(["params": paramsJSON, "region": config.region])

        // Cookie-inert: the console rotates session cookies, and the shared jar
        // would shadow the imported Keychain header on every later request.
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpCookieStorage = nil
        configuration.timeoutIntervalForRequest = 15
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }

        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse else { return nil }
        guard (200...299).contains(http.statusCode) else {
            if http.statusCode == 401 || http.statusCode == 403 {
                throw ProviderFetchError.credentialExpired("Qwen console session expired. Reconnect the browser session.")
            }
            return nil
        }

        return data
    }

    static func parseUsage(_ data: Data) throws -> TokenPlanWebReading? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let envelope = root["data"] as? [String: Any] else { return nil }

        if let succeeded = envelope["success"] as? Bool, !succeeded {
            let code = (envelope["errorCode"] as? String) ?? ""
            // The gateway reports an expired console session in the body, not
            // the status code.
            if code.localizedCaseInsensitiveContains("NotLogined") {
                throw ProviderFetchError.credentialExpired("Qwen console session expired. Reconnect the browser session.")
            }
            throw ProviderFetchError.parsingError("Model Studio console API error\(code.isEmpty ? "" : ": \(code)")")
        }

        guard let dataV2 = envelope["DataV2"] as? [String: Any],
              let body = dataV2["data"] as? [String: Any],
              let payload = body["data"] as? [String: Any] else { return nil }

        // One response carries every period the plan has ever used, and the
        // console renders exactly one of them: the weekly pair when
        // `per1WeekPercentage` is a number, the monthly pair otherwise. Mirror
        // that rather than preferring whichever key is present, so a reset
        // timestamp left behind by an older plan shape cannot drag a monthly
        // account back onto the weekly meter — and so the app and the page
        // can never disagree about which figure is being shown.
        let weeklyFraction = numericValue(payload["per1WeekPercentage"])
        let period: TokenPlanMeterPeriod = weeklyFraction != nil ? .weekly : .monthly
        let fraction = weeklyFraction ?? numericValue(payload["per1MonthPercentage"])
        let resetMilliseconds = numericValue(
            payload[period == .weekly ? "per1WeekResetTime" : "per1MonthResetTime"]
        )

        let usedPercent = fraction.map { min(max($0 * 100, 0), 100) }
        let periodEnd = resetMilliseconds.map { Date(timeIntervalSince1970: $0 / 1000) }

        guard usedPercent != nil || periodEnd != nil else { return nil }
        return TokenPlanWebReading(
            quotaUsedPercent: usedPercent,
            planName: nil,
            remainingDays: nil,
            periodEnd: periodEnd,
            meterPeriod: period
        )
    }

    /// Counts the banked resets the console's "{n} available" badge is drawn
    /// from. The badge is the length of the `result` array on `reset-card/list`
    /// — not a field on the subscription record — so a missing or renamed
    /// count there is expected rather than a parse failure.
    static func parseResetCardCount(_ data: Data) -> Int? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let envelope = root["data"] as? [String: Any] else { return nil }
        if let succeeded = envelope["success"] as? Bool, !succeeded { return nil }
        guard let dataV2 = envelope["DataV2"] as? [String: Any],
              let body = dataV2["data"] as? [String: Any] else { return nil }
        let payload = (body["data"] as? [String: Any]) ?? body
        if let cards = payload["result"] as? [Any] { return cards.count }
        if let cards = body["result"] as? [Any] { return cards.count }
        if let cards = payload["result"] as? [String: Any], let total = numericValue(cards["total"]) {
            return Int(total)
        }
        print("[TokenPlanConsoleAPI] reset-card payload keys: \(payload.keys.sorted())")
        return nil
    }

    private static func numericValue(_ value: Any?) -> Double? {
        if let v = value as? Double { return v }
        if let v = value as? Int { return Double(v) }
        if let v = value as? NSNumber { return v.doubleValue }
        if let v = value as? String { return Double(v) }
        return nil
    }

    private static func formEncodedBody(_ fields: [String: String]) -> Data {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let encoded = fields
            .map { key, value in
                let k = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
                let v = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
                return "\(k)=\(v)"
            }
            .sorted()
            .joined(separator: "&")
        return Data(encoded.utf8)
    }
}

/// Shared assembly for percent-based token-plan consoles: the console's own API
/// first, then the rendered page, then the manual percent anchor entered in
/// Settings.
private func tokenPlanSnapshot(
    providerID: ProviderID,
    credentials: ProviderCredential?,
    dashboardURL: URL,
    cookieField: String,
    resetDatePolicy: TokenPlanResetDatePolicy,
    windowLabel: String,
    windowKind: QuotaWindowKind,
    defaultPlanName: String,
    consoleUsageAPI: TokenPlanConsoleAPI? = nil,
    /// Per-period presentation, consulted when the console reports which
    /// period its meter covers. Empty means the meter keeps `windowLabel` and
    /// `windowKind` whatever the console says — the right behaviour for a
    /// console with only one period, and what MiMo relies on.
    periodWindows: [TokenPlanMeterPeriod: TokenPlanWindow] = [:]
) async throws -> QuotaSnapshot {
    let now = Date()
    let fields = credentials?.extraFields ?? [:]
    let webCookie = fields[cookieField]
    let defaultMeterPeriod: TokenPlanMeterPeriod = windowKind == .monthly ? .monthly : .weekly
    let cachedReading = cachedTokenPlanReading(
        from: fields,
        resetDatePolicy: resetDatePolicy,
        defaultMeterPeriod: defaultMeterPeriod,
        now: now
    )
    let endpoint = BrowserSessionRefreshPolicy.validatedURL(fields[SpendProviderCredentialField.browserSessionURL], fallback: dashboardURL)
    let browserResult: BrowserMeterResult<TokenPlanWebReading>?
    if let webCookie, !webCookie.isEmpty {
        browserResult = await BrowserMeterRefreshStore.shared.read(
            url: endpoint,
            sessionID: fields[SpendProviderCredentialField.browserSessionID] ?? webCookie,
            initial: cachedReading,
            initialAt: ProviderDateParser.parse(fields[SpendProviderCredentialField.tokenPlanCachedAt]),
            interval: 5 * 60,
            failureInterval: 15 * 60,
            now: now
        ) {
            // Prefer the console's own API. It returns the same figure the
            // page renders, without depending on where the meter's value sits
            // in the rendered text.
            //
            // A rejection here must not be fatal, though. The gateway drops
            // the imported cookie long before the browser session it was
            // taken from does, and throwing used to end the fetch outright —
            // so the scrape below never ran and a page that still read fine
            // surfaced as "Parse error: Qwen console session expired". The
            // API's verdict is kept and rethrown only if the scrape fails too.
            var apiFailure: Error?
            if let consoleUsageAPI {
                do {
                    if let apiReading = try await TokenPlanConsoleAPIClient.usageReading(
                        consoleUsageAPI,
                        cookieHeader: webCookie
                    ) {
                        // The API carries the quota and its reset, not the
                        // plan metadata, so keep whatever the last page read
                        // established. The banked reset count is read
                        // separately, and rarely.
                        let resetAvailableCount = await TokenPlanResetAvailabilityReader.availableCount(
                            providerID: providerID,
                            pageURL: endpoint,
                            cookieHeader: webCookie,
                            subscriptionAPI: consoleUsageAPI.subscriptionSibling,
                            resetCardAPI: consoleUsageAPI.resetCardSibling,
                            now: now
                        )
                        return TokenPlanWebReading(
                            quotaUsedPercent: apiReading.quotaUsedPercent,
                            planName: cachedReading?.planName,
                            remainingDays: cachedReading?.remainingDays,
                            periodEnd: apiReading.periodEnd ?? cachedReading?.periodEnd,
                            resetAvailableCount: resetAvailableCount,
                            meterPeriod: apiReading.meterPeriod ?? cachedReading?.meterPeriod
                        )
                    }
                    // A nil reading is not a failure worth rethrowing: the API
                    // simply had nothing to say, and the scrape is the better
                    // source.
                } catch {
                    apiFailure = error
                    print("[TokenPlanConsoleAPI] usage read failed, falling back to the rendered page: \(error.localizedDescription)")
                }
            }

            do {
                #if os(macOS)
                let text = try await ImportedSessionPageReader.read(url: endpoint, cookieHeader: webCookie) {
                    TokenPlanWebClient.parse(html: $0, resetDatePolicy: resetDatePolicy)?.quotaUsedPercent != nil
                }
                guard let reading = TokenPlanWebClient.parse(html: text, resetDatePolicy: resetDatePolicy) else {
                    throw ProviderFetchError.parsingError("No token-plan meters found.")
                }
                return reading
                #else
                guard let reading = await TokenPlanWebClient(baseURL: endpoint, resetDatePolicy: resetDatePolicy).fetch(cookieHeader: webCookie) else {
                    throw ProviderFetchError.credentialExpired("Reconnect the browser session on your Mac.")
                }
                return reading
                #endif
            } catch {
                throw TokenPlanFailureChoice.preferred(scrape: error, api: apiFailure)
            }
        }
    } else {
        browserResult = nil
    }
    if let failure = browserResult?.failureError { throw failure }
    let webReading = browserResult?.value

    // The period is read from the console rather than assumed. Model Studio
    // serves both its old 7-day meter and its current monthly one from the
    // same Plan Quota card, and the two belong in different period buckets —
    // a monthly meter filed under Weekly also gets its reset rejected, because
    // next month's boundary is further out than a weekly reset may be.
    let meterPeriod = webReading?.meterPeriod
        ?? cachedReading?.meterPeriod
        ?? defaultMeterPeriod
    let meterWindow = periodWindows[meterPeriod]
        ?? TokenPlanWindow(label: windowLabel, kind: windowKind)

    let usedPercent = webReading?.quotaUsedPercent
        ?? cachedReading?.quotaUsedPercent
        ?? nonnegativePercent(fields[SpendProviderCredentialField.manualWeeklyUsedPercent])
    let planName = webReading?.planName
        ?? cachedReading?.planName
        ?? fields[SpendProviderCredentialField.manualPlanName]?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        ?? defaultPlanName
    let resetAt = acceptedTokenPlanResetDate(
        webReading?.periodEnd,
        policy: resetDatePolicy,
        meterPeriod: meterPeriod,
        now: now
    ) ?? acceptedTokenPlanResetDate(
        cachedReading?.periodEnd,
        policy: resetDatePolicy,
        meterPeriod: meterPeriod,
        now: now
    ) ?? acceptedTokenPlanResetDate(
        ProviderDateParser.parse(fields[SpendProviderCredentialField.manualResetAt]),
        policy: resetDatePolicy,
        meterPeriod: meterPeriod,
        now: now
    )

    var windows: [QuotaWindow] = []
    var stats: [QuotaStat] = []
    if let usedPercent {
        windows.append(
            QuotaWindow(
                label: meterWindow.label,
                windowKind: meterWindow.kind,
                used: usedPercent,
                total: 100,
                resetDate: resetAt,
                unit: "%",
                subtitle: webReading?.quotaUsedPercent != nil
                    ? browserResult?.sourceDescription
                    : cachedReading?.quotaUsedPercent != nil
                        ? "Captured from the imported browser session"
                        : "Manual anchor — update after each dashboard check"
            )
        )
    }
    if let remainingDays = webReading?.remainingDays {
        stats.append(
            QuotaStat(
                label: "Remaining days",
                value: Double(remainingDays),
                unit: "days",
                subtitle: "Plan renewal countdown"
            )
        )
    }

    if webCookie?.isEmpty == true || (webCookie == nil && usedPercent == nil) {
        throw ProviderFetchError.notConfigured
    }
    if windows.isEmpty {
        throw ProviderFetchError.parsingError(
            "Signed-in token plan page loaded but no quota meter was found (page layout may have changed, or the session expired)."
        )
    }

    let observedAt = browserResult?.fetchedAt ?? now
    let resetCredits = webReading?.resetAvailableCount.map { count in
        QuotaResetCreditSummary(
            availableCount: count,
            redeemHint: "Redeem it from the Plan Quota card in the Model Studio console.",
            observedAt: observedAt
        )
    }

    return QuotaSnapshot(
        providerID: providerID,
        displayName: providerID.snapshotDisplayName,
        planName: planName,
        windows: windows,
        stats: stats,
        fetchState: .success,
        fetchedAt: browserResult?.fetchedAt
            ?? (webCookie == nil ? now : ProviderDateParser.parse(fields[SpendProviderCredentialField.tokenPlanCachedAt]) ?? .distantPast),
        resetCredits: resetCredits
    )
}

/// Reads the banked reset count Model Studio shows on its Plan Quota card
/// ("Reset ⓘ 1 available") at a slower cadence than the meter itself: the
/// reset-card list first, then the subscription record, then the rendered
/// page. A successful read is good for half an hour, a miss is retried after
/// ten minutes.
enum TokenPlanResetAvailabilityReader {
    private static let refreshInterval: TimeInterval = 30 * 60
    private static let retryInterval: TimeInterval = 10 * 60
    private static let appGroupID = "group.com.chrisizatt.LLMUsageCounter"

    private struct Cache: Codable {
        let count: Int?
        let checkedAt: Date
    }

    static func availableCount(
        providerID: ProviderID,
        pageURL: URL,
        cookieHeader: String,
        subscriptionAPI: TokenPlanConsoleAPI?,
        resetCardAPI: TokenPlanConsoleAPI? = nil,
        now: Date = Date()
    ) async -> Int? {
        let key = "\(providerID.rawValue).resetAvailability.v1"
        let defaults = UserDefaults(suiteName: appGroupID) ?? .standard
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let cached = defaults.data(forKey: key).flatMap { try? decoder.decode(Cache.self, from: $0) }
        if let cached {
            let interval = cached.count == nil ? retryInterval : refreshInterval
            if now.timeIntervalSince(cached.checkedAt) < interval {
                return cached.count
            }
        }

        var count: Int?
        // The badge counts the reset-card list, so ask for that first. The
        // subscription scan stays as a fallback because its field name was
        // never confirmed against the live payload.
        if let resetCardAPI {
            let cards = try? await TokenPlanConsoleAPIClient.resetCardCount(resetCardAPI, cookieHeader: cookieHeader)
            // Only a positive count is trusted. This endpoint's request shape
            // has not been confirmed against a live capture, so an empty list
            // may mean "no params" rather than "no banked resets" — and a
            // confident zero would skip the two sources that do work and hide
            // the pill for the next half hour.
            count = (cards ?? 0) > 0 ? cards : nil
        }
        if count == nil, let subscriptionAPI {
            count = try? await TokenPlanConsoleAPIClient.resetAvailableCount(subscriptionAPI, cookieHeader: cookieHeader)
        }
        #if os(macOS)
        if count == nil {
            let text = try? await ImportedSessionPageReader.read(url: pageURL, cookieHeader: cookieHeader) { html in
                let reading = TokenPlanWebClient.parse(html: html, resetDatePolicy: .usageResetOnly)
                return reading?.resetAvailableCount != nil || reading?.quotaUsedPercent != nil
            }
            count = text.flatMap { TokenPlanWebClient.parse(html: $0, resetDatePolicy: .usageResetOnly)?.resetAvailableCount }
        }
        #endif

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(Cache(count: count, checkedAt: now)) {
            defaults.set(data, forKey: key)
        }
        print("[TokenPlanResetAvailability] \(providerID.rawValue): \(count.map(String.init) ?? "unknown") banked reset(s)")
        return count ?? cached?.count
    }
}

private func cachedTokenPlanReading(
    from fields: [String: String],
    resetDatePolicy: TokenPlanResetDatePolicy,
    defaultMeterPeriod: TokenPlanMeterPeriod,
    now: Date
) -> TokenPlanWebReading? {
    let usedPercent = nonnegativePercent(fields[SpendProviderCredentialField.tokenPlanCachedUsedPercent])
    let planName = normalizedTokenPlanName(
        fields[SpendProviderCredentialField.tokenPlanCachedPlanName]
    )
    // The recorded period, if the import saw one. A reading cached before the
    // period was recorded keeps nil rather than being stamped with the
    // provider's default: that default can change — Qwen's just did — and a
    // fabricated period is indistinguishable from an observed one downstream.
    // The reset window below still falls back to the default, because capping a
    // monthly plan's cached reset at eight days would silently drop it.
    let recordedPeriod = fields[SpendProviderCredentialField.tokenPlanCachedMeterPeriod]
        .flatMap(TokenPlanMeterPeriod.init(rawValue:))
    let periodEnd = acceptedTokenPlanResetDate(
        ProviderDateParser.parse(fields[SpendProviderCredentialField.tokenPlanCachedResetAt]),
        policy: resetDatePolicy,
        meterPeriod: recordedPeriod ?? defaultMeterPeriod,
        now: now
    )
    let reading = TokenPlanWebReading(
        quotaUsedPercent: usedPercent,
        planName: planName,
        remainingDays: nil,
        periodEnd: periodEnd,
        meterPeriod: recordedPeriod
    )
    return reading.isEmpty ? nil : reading
}

private func acceptedTokenPlanResetDate(
    _ candidate: Date?,
    policy: TokenPlanResetDatePolicy,
    meterPeriod: TokenPlanMeterPeriod,
    now: Date
) -> Date? {
    guard let candidate else { return nil }
    guard policy == .usageResetOnly else { return candidate }
    let latestBelievableReset = now.addingTimeInterval(meterPeriod.maximumResetLeadTime)
    return candidate > now && candidate <= latestBelievableReset ? candidate : nil
}

private func normalizedTokenPlanName(_ value: String?) -> String? {
    guard var name = value?.trimmingCharacters(in: .whitespacesAndNewlines),
          !name.isEmpty else {
        return nil
    }
    while name.range(
        of: #"\bPlan\s+Plan$"#,
        options: [.regularExpression, .caseInsensitive]
    ) != nil {
        name = name.replacingOccurrences(
            of: #"\s+Plan$"#,
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )
    }
    return name.isEmpty ? nil : name
}

private func nonnegativePercent(_ value: String?) -> Double? {
    guard let result = nonnegativeDouble(value), result <= 100 else { return nil }
    return result
}

// MARK: - Muse Code subscription CLI metering (`muse` → /usage)

/// The Muse Code subscription meters as reported by the local CLI. The CLI
/// talks to Meta's own API with the user's OAuth session, so unlike the
/// console scrape it carries no anti-abuse risk and can be polled far more
/// often. It also reports a reset for the rolling *current* window, which the
/// console page does not expose.
public struct MuseCliSubscriptionReading: Sendable, Equatable, Codable {
    public let planName: String?
    public let currentUsedPercent: Double?
    public let currentResetAt: Date?
    public let weeklyUsedPercent: Double?
    public let weeklyResetAt: Date?

    public init(
        planName: String?,
        currentUsedPercent: Double?,
        currentResetAt: Date?,
        weeklyUsedPercent: Double?,
        weeklyResetAt: Date?
    ) {
        self.planName = planName
        self.currentUsedPercent = currentUsedPercent
        self.currentResetAt = currentResetAt
        self.weeklyUsedPercent = weeklyUsedPercent
        self.weeklyResetAt = weeklyResetAt
    }

    public var isEmpty: Bool {
        currentUsedPercent == nil && weeklyUsedPercent == nil
    }
}

/// Parses the `/usage` screen of the Muse TUI.
///
/// The TUI paints with cursor positioning rather than spaces, so a partial
/// redraw arrives as `Subscription·MuseCodeHighUsageCurrent14%used·Resets…`
/// while a full redraw keeps the spacing. Every match therefore runs against
/// the *whitespace-stripped* text, which is identical in both cases.
nonisolated enum MuseCliUsageParser {
    /// ESC is embedded as a Swift escape rather than a regex escape: ICU
    /// understands `\\uHHHH` but not Swift's `\\u{...}`, and a literal control
    /// byte in source would be invisible to the next reader.
    private static let escape = "\u{001B}"

    static func stripANSI(_ text: String) -> String {
        var result = text
        for pattern in [
            "\(escape)\\][^\u{0007}\u{001B}]*(\u{0007}|\(escape)\\\\)",  // OSC
            "\(escape)P[\\s\\S]*?\(escape)\\\\",                          // DCS
            "\(escape)\\[[0-9;?<>=]*[ -/]*[@-~]",                       // CSI
            "\(escape)[()][0-9A-B]",                                    // charset
            "\(escape)[=>NOM78]"                                        // single-char
        ] {
            result = result.replacingOccurrences(
                of: pattern,
                with: "",
                options: .regularExpression
            )
        }
        return result
    }

    /// ANSI-stripped and whitespace-free, the form every pattern matches on.
    static func compacted(_ rawText: String) -> String {
        stripANSI(rawText).replacingOccurrences(
            of: #"\s+"#,
            with: "",
            options: .regularExpression
        )
    }

    /// True once the weekly meter has painted, i.e. the screen is complete
    /// enough to parse. The probe stops reading at this point.
    static func hasSubscriptionScreen(_ compacted: String) -> Bool {
        firstMatch(pattern: #"weekly\d+(?:\.\d+)?%used"#, in: compacted) != nil
    }

    static func parse(
        rawText: String,
        now: Date,
        calendar: Calendar = .current
    ) -> MuseCliSubscriptionReading? {
        parse(compacted: compacted(rawText), now: now, calendar: calendar)
    }

    static func parse(
        compacted text: String,
        now: Date,
        calendar: Calendar = .current
    ) -> MuseCliSubscriptionReading? {
        guard !text.isEmpty else { return nil }

        let currentPercent = capture(
            pattern: #"current(\d+(?:\.\d+)?)%used"#,
            group: 1,
            in: text
        ).flatMap(Double.init)
        let weeklyPercent = capture(
            pattern: #"weekly(\d+(?:\.\d+)?)%used"#,
            group: 1,
            in: text
        ).flatMap(Double.init)

        guard currentPercent != nil || weeklyPercent != nil else { return nil }

        // "Current 14% used · Resets at 9:18 PM" — a clock time only, so the
        // reset is the next occurrence of that time.
        let currentReset = capture(
            pattern: #"current\d+(?:\.\d+)?%used[·•]?resetsat(\d{1,2}:\d{2})(am|pm)?"#,
            group: 1,
            in: text
        ).flatMap { clock in
            nextOccurrence(
                clock: clock,
                meridiem: capture(
                    pattern: #"current\d+(?:\.\d+)?%used[·•]?resetsat\d{1,2}:\d{2}(am|pm)"#,
                    group: 1,
                    in: text
                ),
                now: now,
                calendar: calendar
            )
        }

        // "Weekly 30% used · Resets Sep 7 at 1:00 AM" — month/day plus a time.
        let weeklyReset = weeklyResetDate(in: text, now: now, calendar: calendar)

        let reading = MuseCliSubscriptionReading(
            planName: planName(in: text),
            currentUsedPercent: clampedPercent(currentPercent),
            currentResetAt: currentReset,
            weeklyUsedPercent: clampedPercent(weeklyPercent),
            weeklyResetAt: weeklyReset
        )
        return reading.isEmpty ? nil : reading
    }

    private static func clampedPercent(_ value: Double?) -> Double? {
        guard let value, (0...100).contains(value) else { return nil }
        return value
    }

    /// `Subscription·MuseCodeHighUsageCurrent14%used` → "Muse Code High Usage".
    /// Whitespace is already gone, so the CamelCase run is re-spaced.
    private static func planName(in text: String) -> String? {
        // Bounded gap: an unbounded lazy group could bridge the label of one
        // painted frame to the meters of the next.
        guard let raw = capture(
            pattern: #"subscription[·•]?(.{1,48}?)current\d+(?:\.\d+)?%used"#,
            group: 1,
            in: text
        ), !raw.isEmpty else {
            return nil
        }
        let spaced = raw.replacingOccurrences(
            of: #"(?<=[a-z0-9])(?=[A-Z])"#,
            with: " ",
            options: .regularExpression
        )
        let trimmed = spaced.trimmingCharacters(in: CharacterSet(charactersIn: " ·•-"))
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func weeklyResetDate(
        in text: String,
        now: Date,
        calendar: Calendar
    ) -> Date? {
        let block = #"weekly\d+(?:\.\d+)?%used[·•]?resets"#
        guard let month = capture(pattern: block + #"([a-z]{3})[a-z]*\d{1,2}"#, group: 1, in: text),
              let monthNumber = monthNumber(month),
              let day = capture(pattern: block + #"[a-z]{3}[a-z]*(\d{1,2})"#, group: 1, in: text)
                  .flatMap(Int.init) else {
            // No date component: fall back to the next occurrence of the time.
            guard let clock = capture(pattern: block + #"at(\d{1,2}:\d{2})"#, group: 1, in: text) else {
                return nil
            }
            return nextOccurrence(
                clock: clock,
                meridiem: capture(pattern: block + #"at\d{1,2}:\d{2}(am|pm)"#, group: 1, in: text),
                now: now,
                calendar: calendar
            )
        }

        let clock = capture(pattern: block + #"[a-z]{3}[a-z]*\d{1,2}at(\d{1,2}:\d{2})"#, group: 1, in: text)
        let meridiem = capture(
            pattern: block + #"[a-z]{3}[a-z]*\d{1,2}at\d{1,2}:\d{2}(am|pm)"#,
            group: 1,
            in: text
        )
        let time = clockComponents(clock, meridiem: meridiem)

        var components = DateComponents()
        components.month = monthNumber
        components.day = day
        components.hour = time.hour
        components.minute = time.minute
        components.second = 0

        // The CLI prints no year: choose the nearest candidate that has not
        // already passed by more than a day, so a December→January weekly
        // reset rolls forward correctly.
        let nowYear = calendar.component(.year, from: now)
        let tolerance = now.addingTimeInterval(-24 * 60 * 60)
        for candidateYear in [nowYear - 1, nowYear, nowYear + 1] {
            components.year = candidateYear
            if let candidate = calendar.date(from: components), candidate >= tolerance {
                return candidate
            }
        }
        return nil
    }

    /// The next time the clock reads `clock` — today if still ahead, else tomorrow.
    private static func nextOccurrence(
        clock: String,
        meridiem: String?,
        now: Date,
        calendar: Calendar
    ) -> Date? {
        let time = clockComponents(clock, meridiem: meridiem)
        guard let today = calendar.date(
            bySettingHour: time.hour,
            minute: time.minute,
            second: 0,
            of: now
        ) else {
            return nil
        }
        if today > now { return today }
        return calendar.date(byAdding: .day, value: 1, to: today)
    }

    private static func clockComponents(
        _ clock: String?,
        meridiem: String?
    ) -> (hour: Int, minute: Int) {
        let parts = (clock ?? "").split(separator: ":")
        var hour = parts.first.flatMap { Int($0) } ?? 0
        let minute = parts.count > 1 ? (Int(parts[1]) ?? 0) : 0
        switch meridiem?.lowercased() {
        case "pm": hour = hour == 12 ? 12 : hour + 12
        case "am": hour = hour == 12 ? 0 : hour
        default: break
        }
        return (min(max(hour, 0), 23), min(max(minute, 0), 59))
    }

    private static func monthNumber(_ name: String) -> Int? {
        let months = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]
        guard let index = months.firstIndex(of: name.lowercased()) else { return nil }
        return index + 1
    }

    /// Returns the capture from the **last** match, not the first.
    ///
    /// The probe accumulates every frame the TUI paints, so the buffer holds a
    /// history of renders. The final match is the most recently painted — and
    /// taking the first would both report stale percentages and let a lazy
    /// group span two frames.
    private static func capture(pattern: String, group: Int, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        let matches = regex.matches(in: text, options: [], range: range)
        guard let match = matches.last,
              match.numberOfRanges > group,
              let captured = Range(match.range(at: group), in: text) else {
            return nil
        }
        return String(text[captured])
    }

    private static func firstMatch(pattern: String, in text: String) -> String? {
        capture(pattern: pattern, group: 0, in: text)
    }
}

#if os(macOS)
/// Drives the Muse TUI under a pty and reads its `/usage` screen, mirroring
/// the Grok CLI probe. `--no-session-log` keeps the probe from writing session
/// records, so polling leaves the user's Muse session history untouched.
enum MuseCliUsageProbe {
    /// Measured cold-start to a parsed reading is ~6s; the deadline leaves
    /// headroom for a slow network without stalling a dashboard refresh.
    static let deadlineSeconds: TimeInterval = 20

    static func probe(binaryURL: URL, now: Date = Date()) -> MuseCliSubscriptionReading? {
        var masterFD: Int32 = -1
        var slaveFD: Int32 = -1
        var terminalSize = winsize(ws_row: 45, ws_col: 130, ws_xpixel: 0, ws_ypixel: 0)
        guard openpty(&masterFD, &slaveFD, nil, nil, &terminalSize) == 0 else {
            print("[MuseCliUsage] openpty failed")
            return nil
        }
        defer {
            if masterFD >= 0 { close(masterFD) }
        }

        let fileManager = FileManager.default
        let workingURL = fileManager.temporaryDirectory
            .appendingPathComponent("limit-counter-muse-\(UUID().uuidString)", isDirectory: true)
        try? fileManager.createDirectory(at: workingURL, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: workingURL) }

        let process = Process()
        process.executableURL = binaryURL
        // An empty scratch workspace keeps the probe hermetic: there are no
        // project-local skills, rules or hooks to load, and `--trust-workspace`
        // (this run only, never saved) stops the CLI blocking on its trust
        // prompt. `--no-session-log` keeps it out of the session history.
        process.arguments = ["--no-session-log", "--trust-workspace"]
        process.currentDirectoryURL = workingURL
        var environment = ProcessInfo.processInfo.environment
        // The CLI resolves its config/data roots and keychain from HOME; the
        // app's own HOME is its sandbox container, which holds neither.
        if let realHome = realHomeDirectoryPath() {
            environment["HOME"] = realHome
        }
        environment["MUSE_NO_AUTO_UPDATE"] = "1"
        environment["TERM"] = "xterm-256color"
        environment["NO_COLOR"] = "1"
        process.environment = environment

        let slaveHandle = FileHandle(fileDescriptor: slaveFD, closeOnDealloc: true)
        process.standardInput = slaveHandle
        process.standardOutput = slaveHandle
        process.standardError = slaveHandle

        do {
            try process.run()
            slaveHandle.closeFile()
        } catch {
            print("[MuseCliUsage] Failed to launch muse CLI: \(error.localizedDescription)")
            slaveHandle.closeFile()
            return nil
        }
        defer {
            if process.isRunning {
                process.terminate()
                usleep(200_000)
                if process.isRunning {
                    kill(process.processIdentifier, SIGKILL)
                }
            }
        }

        let flags = fcntl(masterFD, F_GETFL)
        if flags >= 0 {
            _ = fcntl(masterFD, F_SETFL, flags | O_NONBLOCK)
        }

        var data = Data()
        var queryState = MuseTerminalQueryState()
        let startedAt = Date()
        let deadline = startedAt.addingTimeInterval(deadlineSeconds)
        var typedCommand = false
        var typedAt: Date?
        var submittedAt: Date?
        var sentSecondReturn = false

        while Date() < deadline {
            var buffer = [UInt8](repeating: 0, count: 4096)
            let bufferCount = buffer.count
            let bytesRead = buffer.withUnsafeMutableBytes { rawBuffer in
                read(masterFD, rawBuffer.baseAddress, bufferCount)
            }
            if bytesRead > 0 {
                data.append(contentsOf: buffer.prefix(Int(bytesRead)))
            }

            let rawText = String(decoding: data, as: UTF8.self)
            respondToMuseTerminalQueries(in: rawText, masterFD: masterFD, state: &queryState)

            let compacted = MuseCliUsageParser.compacted(rawText)
            if MuseCliUsageParser.hasSubscriptionScreen(compacted),
               let reading = MuseCliUsageParser.parse(compacted: compacted, now: now) {
                return reading
            }

            // Never answer a trust prompt on the user's behalf: if one appears
            // the scratch workspace was not accepted, and blindly sending keys
            // would be answering a security question for them.
            if compacted.range(of: "doyoutrustthisworkspace", options: .caseInsensitive) != nil {
                print("[MuseCliUsage] The CLI asked for workspace trust; leaving that decision to the user")
                return nil
            }

            let elapsed = Date().timeIntervalSince(startedAt)
            if !typedCommand, elapsed >= 4.0 {
                // Typed as keystrokes: the TUI's editor drops a pasted burst
                // while it is still hydrating.
                for character in "/usage" {
                    writeMusePTYString(String(character), to: masterFD)
                    usleep(100_000)
                }
                typedCommand = true
                typedAt = Date()
            } else if let typedAt, submittedAt == nil,
                      Date().timeIntervalSince(typedAt) >= 1.0 {
                // The slash-command menu needs a beat to settle before it will
                // accept the return that runs the command.
                writeMusePTYString("\r", to: masterFD)
                submittedAt = Date()
            } else if let submittedAt,
                      !sentSecondReturn,
                      Date().timeIntervalSince(submittedAt) >= 2.0 {
                // Second return runs the command when the first only dismissed
                // the menu.
                writeMusePTYString("\r", to: masterFD)
                sentSecondReturn = true
            }

            usleep(100_000)
        }

        print("[MuseCliUsage] Timed out before the subscription screen rendered")
        return nil
    }

    private static func realHomeDirectoryPath() -> String? {
        let homePath = NSHomeDirectory()
        guard let range = homePath.range(of: "/Library/Containers/") else {
            return homePath
        }
        return String(homePath[..<range.lowerBound])
    }
}

private struct MuseTerminalQueryState {
    var answeredCursorPosition = false
    var answeredPrimaryAttributes = false
    var answeredSecondaryAttributes = false
    var answeredXtermVersion = false
    var answeredKittyKeyboard = false
    var answeredBackgroundColor = false
}

/// The TUI blocks its first paint until these capability queries are answered.
private func respondToMuseTerminalQueries(
    in rawText: String,
    masterFD: Int32,
    state: inout MuseTerminalQueryState
) {
    if !state.answeredCursorPosition, rawText.contains("\u{001B}[6n") {
        writeMusePTYString("\u{001B}[45;130R", to: masterFD)
        state.answeredCursorPosition = true
    }
    if !state.answeredXtermVersion,
       rawText.contains("\u{001B}[>q") || rawText.contains("\u{001B}[>0q") {
        writeMusePTYString("\u{001B}P>|LimitCounter 1.0\u{001B}\\", to: masterFD)
        state.answeredXtermVersion = true
    }
    if !state.answeredSecondaryAttributes, rawText.contains("\u{001B}[>c") {
        writeMusePTYString("\u{001B}[>41;351;0c", to: masterFD)
        state.answeredSecondaryAttributes = true
    }
    if !state.answeredPrimaryAttributes, rawText.contains("\u{001B}[c") {
        writeMusePTYString("\u{001B}[?62;1;2;6;9;15;22c", to: masterFD)
        state.answeredPrimaryAttributes = true
    }
    if !state.answeredKittyKeyboard, rawText.contains("\u{001B}[?u") {
        writeMusePTYString("\u{001B}[?0u", to: masterFD)
        state.answeredKittyKeyboard = true
    }
    if !state.answeredBackgroundColor, rawText.contains("\u{001B}]11;?") {
        writeMusePTYString("\u{001B}]11;rgb:1e1e/1e1e/1e1e\u{001B}\\", to: masterFD)
        state.answeredBackgroundColor = true
    }
}

private func writeMusePTYString(_ string: String, to fd: Int32) {
    let bytes = Array(string.utf8)
    bytes.withUnsafeBufferPointer { pointer in
        guard let baseAddress = pointer.baseAddress else { return }
        _ = write(fd, baseAddress, pointer.count)
    }
}
#endif

/// Locates the `muse` launcher. A user-granted bookmark wins; otherwise the
/// standard install path is tried, which works when the app is not sandboxed.
enum MuseCliBinaryLocator {
    static let defaultRelativePath = ".local/bin/muse"

    static func resolve(fields: [String: String]) -> (url: URL, stop: () -> Void)? {
        #if os(macOS)
        if let bookmarkBase64 = fields[SpendProviderCredentialField.museCliBookmark],
           let bookmarkData = Data(base64Encoded: bookmarkBase64) {
            var isStale = false
            if let url = try? URL(
                resolvingBookmarkData: bookmarkData,
                options: .withSecurityScope,
                bookmarkDataIsStale: &isStale
            ) {
                if isStale {
                    print("[MuseCliUsage] Muse CLI bookmark is stale; re-grant it in Settings")
                }
                let didStart = url.startAccessingSecurityScopedResource()
                if let binary = binaryURL(within: url) {
                    return (binary, { if didStart { url.stopAccessingSecurityScopedResource() } })
                }
                if didStart { url.stopAccessingSecurityScopedResource() }
            }
        }

        // Fall back to the standard install path when it is genuinely
        // runnable, the same way the Grok CLI probe resolves `~/.grok`. The
        // explicit grant above stays the preferred route and is how to point
        // the app at a launcher installed elsewhere.
        let fallback = defaultBinaryURL()
        if FileManager.default.fileExists(atPath: fallback.path) {
            return (fallback, {})
        }
        #endif
        return nil
    }

    /// Accepts either the launcher itself or a folder that contains it.
    ///
    /// Existence, not `isExecutableFile`: the sandbox denies the execute-bit
    /// check (`access(X_OK)`) even for a folder the user just granted through
    /// the open panel, so testing executability here rejects a launcher that
    /// is plainly present. Whether it actually runs is settled by launching
    /// it, which reports a real error.
    static func binaryURL(within url: URL) -> URL? {
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return nil }
        if !isDirectory.boolValue {
            return url
        }
        for candidate in ["muse", "bin/muse", ".local/bin/muse"] {
            let candidateURL = url.appendingPathComponent(candidate)
            var candidateIsDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: candidateURL.path, isDirectory: &candidateIsDirectory),
               !candidateIsDirectory.boolValue {
                return candidateURL
            }
        }
        return nil
    }

    static func defaultBinaryURL() -> URL {
        let homePath = NSHomeDirectory()
        let realHome: String
        if let range = homePath.range(of: "/Library/Containers/") {
            realHome = String(homePath[..<range.lowerBound])
        } else {
            realHome = homePath
        }
        return URL(fileURLWithPath: realHome, isDirectory: true)
            .appendingPathComponent(defaultRelativePath)
    }
}

/// The CLI carries no anti-abuse risk, so it refreshes on a normal dashboard
/// cadence rather than the console scrape's hourly cap. The probe still costs
/// a few seconds of process time, so successive refreshes reuse the cache.
enum MuseCliRefreshCadence {
    static let successfulFetchInterval: TimeInterval = 10 * 60
    static let failedFetchRetryInterval: TimeInterval = 30 * 60

    static func isDue(
        now: Date,
        lastSuccessfulFetchAt: Date?,
        lastAttemptAt: Date?,
        userInitiated: Bool = false
    ) -> Bool {
        // A manual refresh always re-probes: the user is asking for now.
        if userInitiated { return true }
        guard let lastAttemptAt else { return true }

        if let lastSuccessfulFetchAt, lastSuccessfulFetchAt >= lastAttemptAt {
            return now.timeIntervalSince(lastSuccessfulFetchAt) >= successfulFetchInterval
        }
        return now.timeIntervalSince(lastAttemptAt) >= failedFetchRetryInterval
    }
}

actor MuseCliRefreshCache {
    enum FetchDecision {
        case fetch
        case cached(MuseCliSubscriptionReading?)
    }

    private struct PersistedState: Codable {
        var reading: MuseCliSubscriptionReading?
        var lastSuccessfulFetchAt: Date?
        var lastAttemptAt: Date?
    }

    static let shared = MuseCliRefreshCache()

    private static let appGroupID = "group.com.chrisizatt.LLMUsageCounter"
    private static let defaultPersistenceKey = "meta.museCliRefreshCache.v1"

    private let defaults: UserDefaults
    private let persistenceKey: String
    private var state: PersistedState?

    init(
        defaults: UserDefaults? = nil,
        persistenceKey: String = MuseCliRefreshCache.defaultPersistenceKey
    ) {
        self.defaults = defaults
            ?? UserDefaults(suiteName: Self.appGroupID)
            ?? .standard
        self.persistenceKey = persistenceKey
        state = self.defaults.data(forKey: persistenceKey).flatMap {
            try? JSONDecoder().decode(PersistedState.self, from: $0)
        }
    }

    func decision(now: Date, userInitiated: Bool) -> FetchDecision {
        guard let state else { return .fetch }
        guard !MuseCliRefreshCadence.isDue(
            now: now,
            lastSuccessfulFetchAt: state.lastSuccessfulFetchAt,
            lastAttemptAt: state.lastAttemptAt,
            userInitiated: userInitiated
        ) else {
            return .fetch
        }
        return .cached(state.reading)
    }

    @discardableResult
    func recordResult(_ reading: MuseCliSubscriptionReading?, now: Date) -> MuseCliSubscriptionReading? {
        var next = state ?? PersistedState(reading: nil, lastSuccessfulFetchAt: nil, lastAttemptAt: nil)
        next.lastAttemptAt = now
        if let reading {
            next.reading = reading
            next.lastSuccessfulFetchAt = now
        }
        state = next
        if let data = try? JSONEncoder().encode(next) {
            defaults.set(data, forKey: persistenceKey)
        }
        return reading ?? next.reading
    }
}

// MARK: - Muse Code subscription web metering (dev.meta.ai/usage)

/// A subscription-quota reading scraped from the Meta Model API usage page.
/// Muse Code subscriptions surface "Current usage" and "Weekly limit" percent
/// meters (plus the weekly reset time) that the CLI does not expose yet.
public nonisolated struct MuseSubscriptionWebReading: Sendable, Equatable, Codable {
    public let planName: String?
    public let currentUsedPercent: Double?
    /// The rolling current-window reset. The console renders it as a bare
    /// clock time ("Resets at 9:18 PM") because the window is hours long.
    public let currentResetAt: Date?
    public let weeklyUsedPercent: Double?
    public let weeklyResetAt: Date?

    public init(
        planName: String?,
        currentUsedPercent: Double?,
        currentResetAt: Date? = nil,
        weeklyUsedPercent: Double?,
        weeklyResetAt: Date?
    ) {
        self.planName = planName
        self.currentUsedPercent = currentUsedPercent
        self.currentResetAt = currentResetAt
        self.weeklyUsedPercent = weeklyUsedPercent
        self.weeklyResetAt = weeklyResetAt
    }

    /// A reading with no meter is not a successful scrape: the plan name also
    /// appears on upsell chrome for accounts without a subscription.
    public var isEmpty: Bool {
        currentUsedPercent == nil && weeklyUsedPercent == nil
    }
}

/// Scrapes the Meta usage console for the Muse Code subscription meters using
/// the same imported dev.meta.ai session as the billing reader. A plain
/// request is tried first (it can see server-rendered markup and RSC
/// payloads); on macOS a hidden rendered load is the fallback for
/// client-side-only rollouts of the console.
public struct MuseSubscriptionWebClient: Sendable {
    public let baseURL: URL
    public let cookieDomains: [String]

    public init(baseURL: URL, cookieDomains: [String]) {
        self.baseURL = baseURL
        self.cookieDomains = cookieDomains
    }

    public func fetch(
        cookieHeader: String,
        now: Date,
        persistCookieHeader: ((String) async -> Bool)? = nil
    ) async -> MuseSubscriptionWebReading? {
        guard !cookieHeader.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }

        if let reading = await fetchViaURLSession(
            cookieHeader: cookieHeader,
            now: now,
            persistCookieHeader: persistCookieHeader
        ) {
            return reading
        }

        #if os(macOS)
        return await MuseSubscriptionRenderedPageReader.read(
            url: baseURL,
            cookieHeader: cookieHeader,
            now: now
        )
        #else
        return nil
        #endif
    }

    private func fetchViaURLSession(
        cookieHeader: String,
        now: Date,
        persistCookieHeader: ((String) async -> Bool)?
    ) async -> MuseSubscriptionWebReading? {
        var request = URLRequest(url: baseURL, timeoutInterval: 15)
        request.httpMethod = "GET"
        request.httpShouldHandleCookies = false
        request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125.0.0.0 Safari/537.36",
            forHTTPHeaderField: "User-Agent"
        )
        request.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")

        // Cookie-inert session: the console rotates session cookies via
        // Set-Cookie, and the shared cookie jar would override the imported
        // Keychain header on every fetch after the first.
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpCookieStorage = nil
        configuration.timeoutIntervalForRequest = 15
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }

        guard let (data, response) = try? await session.data(for: request),
              let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode),
              let html = String(data: data, encoding: .utf8) else {
            return nil
        }

        if let rotatedHeader = ImportedCookieHeaderMerger.mergedHeader(
            existingHeader: cookieHeader,
            response: httpResponse,
            requestURL: baseURL,
            allowedDomains: cookieDomains
        ), rotatedHeader != cookieHeader {
            guard let persistCookieHeader,
                  await persistCookieHeader(rotatedHeader) else {
                print("[MuseSubscriptionWebClient] Rotated cookies were received but could not be persisted")
                return nil
            }
        }

        return Self.parse(html: html, now: now)
    }

    // MARK: Parsing

    static func parse(html: String, now: Date, calendar: Calendar = .current) -> MuseSubscriptionWebReading? {
        parse(
            renderedText: MistralWebSubscriptionClient.normalizedRenderedText(from: html),
            payloadText: MistralWebSubscriptionClient.normalizedScriptPayloadText(from: html),
            now: now,
            calendar: calendar
        )
    }

    /// Entry point for already-rendered `document.body.innerText` (used by the
    /// import sheet and the hidden rendered reader).
    static func parse(renderedText: String, now: Date, calendar: Calendar = .current) -> MuseSubscriptionWebReading? {
        parse(
            renderedText: MistralWebSubscriptionClient.normalizedRenderedText(from: renderedText),
            payloadText: "",
            now: now,
            calendar: calendar
        )
    }

    static func parse(
        renderedText: String,
        payloadText: String,
        now: Date,
        calendar: Calendar = .current
    ) -> MuseSubscriptionWebReading? {
        for text in [renderedText, payloadText] where !text.isEmpty {
            if let reading = parseText(text, now: now, calendar: calendar) {
                return reading
            }
        }
        return nil
    }

    private static func parseText(
        _ text: String,
        now: Date,
        calendar: Calendar
    ) -> MuseSubscriptionWebReading? {
        // A signed-out console renders a login form and no meters.
        let hasMeterLabels = text.range(of: "Current usage", options: .caseInsensitive) != nil
            || text.range(of: "Weekly limit", options: .caseInsensitive) != nil
        guard hasMeterLabels else { return nil }

        let currentUsedPercent = labeledUsedPercent(
            label: "Current usage",
            stops: ["Weekly limit", "Pay as you go"],
            in: text
        )
        let currentBlock = labeledBlock(
            label: "Current usage",
            stops: ["Weekly limit", "Pay as you go"],
            in: text
        )
        let currentResetAt = currentBlock.flatMap {
            resetDate(in: $0, now: now, calendar: calendar)
        }
        let weeklyBlock = labeledBlock(
            label: "Weekly limit",
            stops: ["Current usage", "Pay as you go"],
            in: text
        )
        let weeklyUsedPercent = weeklyBlock.flatMap { usedPercent(in: $0) }
            ?? labeledUsedPercent(label: "Weekly limit", stops: ["Current usage", "Pay as you go"], in: text)
        // The whole-page fallback must not pick up the current window's bare
        // clock time and present it as the weekly reset.
        let weeklyResetAt = weeklyBlock.flatMap {
            resetDate(in: $0, now: now, calendar: calendar)
        } ?? resetDate(in: text, now: now, calendar: calendar, allowClockOnly: false)

        let reading = MuseSubscriptionWebReading(
            planName: subscriptionPlanName(in: text),
            currentUsedPercent: currentUsedPercent,
            currentResetAt: currentResetAt,
            weeklyUsedPercent: weeklyUsedPercent,
            weeklyResetAt: weeklyResetAt
        )
        return reading.isEmpty ? nil : reading
    }

    /// The block of text following `label`, truncated at the earliest `stop`
    /// label so one card's values never bleed into the next card's parse.
    private static func labeledBlock(label: String, stops: [String], in text: String) -> String? {
        guard let labelRange = text.range(of: label, options: .caseInsensitive) else { return nil }
        let blockStart = labelRange.upperBound
        var blockEnd = text.index(blockStart, offsetBy: 240, limitedBy: text.endIndex) ?? text.endIndex
        for stop in stops {
            if let stopRange = text.range(of: stop, options: .caseInsensitive, range: blockStart..<blockEnd) {
                blockEnd = stopRange.lowerBound
            }
        }
        return String(text[blockStart..<blockEnd])
    }

    private static func labeledUsedPercent(label: String, stops: [String], in text: String) -> Double? {
        if let block = labeledBlock(label: label, stops: stops, in: text),
           let percent = usedPercent(in: block) {
            return percent
        }
        // Some DOM orders render the value element before its label; scan a
        // short window backwards as a fallback.
        guard let labelRange = text.range(of: label, options: .caseInsensitive) else { return nil }
        let backStart = text.index(labelRange.lowerBound, offsetBy: -80, limitedBy: text.startIndex)
            ?? text.startIndex
        return usedPercent(in: String(text[backStart..<labelRange.lowerBound]), requireUsedSuffix: true)
    }

    private static func usedPercent(in block: String, requireUsedSuffix: Bool = false) -> Double? {
        let candidate = firstMatch(pattern: "(\\d+(?:\\.\\d+)?)\\s*%\\s*used", in: block)
            ?? (requireUsedSuffix ? nil : firstMatch(pattern: "(\\d+(?:\\.\\d+)?)\\s*%", in: block))
        guard let value = candidate.flatMap(Double.init), (0...100).contains(value) else { return nil }
        return value
    }

    private static func subscriptionPlanName(in text: String) -> String? {
        // Upstream normalization collapses all whitespace, so the page heading
        // ("Usage") and the plan title share one line. Anchor on the product
        // name first so page chrome cannot leak into the captured plan.
        var candidate = firstMatch(
            pattern: "\\b(Muse(?:\\s+[A-Za-z0-9+.-]+){0,5})\\s+subscription\\b",
            in: text
        )
        if candidate == nil {
            candidate = firstMatch(
                pattern: "\\b([A-Z][A-Za-z0-9+.-]*(?:\\s+[A-Za-z0-9+.-]+){0,5}?)\\s+subscription\\b",
                in: text
            )
        }
        guard let candidate else { return nil }

        var words = candidate
            .split(separator: " ")
            .map(String.init)
        let chromeTokens: Set<String> = ["usage", "billing", "dashboard", "overview", "your"]
        while let first = words.first, chromeTokens.contains(first.lowercased()) {
            words.removeFirst()
        }
        let name = words.joined(separator: " ")
        guard !name.isEmpty, name.count <= 48 else { return nil }
        return name
    }

    /// Parses "Resets 7 Sep at 01:00" style labels (also "Sep 7", 12-hour
    /// clocks, "today"/"tomorrow", and "in N days"). The console renders the
    /// reset in local time without a year, so the year is inferred as the
    /// nearest occurrence that is not far in the past.
    static func resetDate(
        in block: String,
        now: Date,
        calendar: Calendar = .current,
        allowClockOnly: Bool = true
    ) -> Date? {
        if let dayFirst = matchGroups(
            pattern: "Resets\\s+(?:on\\s+)?(\\d{1,2})(?:st|nd|rd|th)?\\s+([A-Za-z]{3,9})\\.?(?:\\s+(\\d{4}))?(?:\\s+at\\s+(\\d{1,2}):(\\d{2})(?:\\s*([AaPp])\\.?[Mm]\\.?)?)?",
            in: block
        ), let month = monthNumber(dayFirst[2]) {
            return assembledResetDate(
                day: Int(dayFirst[1] ?? ""),
                month: month,
                year: Int(dayFirst[3] ?? ""),
                hour: Int(dayFirst[4] ?? ""),
                minute: Int(dayFirst[5] ?? ""),
                meridiem: dayFirst[6],
                now: now,
                calendar: calendar
            )
        }

        if let monthFirst = matchGroups(
            pattern: "Resets\\s+(?:on\\s+)?([A-Za-z]{3,9})\\.?\\s+(\\d{1,2})(?:st|nd|rd|th)?(?:,?\\s+(\\d{4}))?(?:\\s+at\\s+(\\d{1,2}):(\\d{2})(?:\\s*([AaPp])\\.?[Mm]\\.?)?)?",
            in: block
        ), let month = monthNumber(monthFirst[1]) {
            return assembledResetDate(
                day: Int(monthFirst[2] ?? ""),
                month: month,
                year: Int(monthFirst[3] ?? ""),
                hour: Int(monthFirst[4] ?? ""),
                minute: Int(monthFirst[5] ?? ""),
                meridiem: monthFirst[6],
                now: now,
                calendar: calendar
            )
        }

        if let relativeDay = matchGroups(
            pattern: "Resets\\s+(today|tomorrow)(?:\\s+at\\s+(\\d{1,2}):(\\d{2})(?:\\s*([AaPp])\\.?[Mm]\\.?)?)?",
            in: block
        ) {
            let dayOffset = relativeDay[1]?.lowercased() == "tomorrow" ? 1 : 0
            guard let base = calendar.date(byAdding: .day, value: dayOffset, to: calendar.startOfDay(for: now)) else {
                return nil
            }
            let hour = adjustedHour(Int(relativeDay[2] ?? ""), meridiem: relativeDay[4])
            return calendar.date(
                bySettingHour: hour ?? 0,
                minute: Int(relativeDay[3] ?? "") ?? 0,
                second: 0,
                of: base
            )
        }

        if let inDays = firstMatch(pattern: "Resets\\s+in\\s+(\\d+)\\s+day", in: block)
            .flatMap(Int.init) {
            return calendar.date(byAdding: .day, value: inDays, to: now)
        }

        // "Resets at 9:18 PM" — a bare clock time, used for the rolling
        // current-usage window. Resolve to the next time that clock reads.
        if allowClockOnly, let clockOnly = matchGroups(
            pattern: "Resets\\s+at\\s+(\\d{1,2}):(\\d{2})(?:\\s*([AaPp])\\.?[Mm]\\.?)?",
            in: block
        ), let hour = Int(clockOnly[1] ?? "") {
            let adjusted = adjustedHour(hour, meridiem: clockOnly[3]) ?? hour
            guard let today = calendar.date(
                bySettingHour: adjusted,
                minute: Int(clockOnly[2] ?? "") ?? 0,
                second: 0,
                of: now
            ) else {
                return nil
            }
            return today > now ? today : calendar.date(byAdding: .day, value: 1, to: today)
        }

        return nil
    }

    private static func assembledResetDate(
        day: Int?,
        month: Int,
        year: Int?,
        hour: Int?,
        minute: Int?,
        meridiem: String?,
        now: Date,
        calendar: Calendar
    ) -> Date? {
        guard let day, (1...31).contains(day) else { return nil }
        var components = DateComponents()
        components.day = day
        components.month = month
        components.hour = adjustedHour(hour, meridiem: meridiem) ?? 0
        components.minute = minute ?? 0
        components.second = 0

        if let year {
            components.year = year
            return calendar.date(from: components)
        }

        // No explicit year: pick the nearest candidate that is not more than
        // two days in the past, so a slightly stale page reading survives while
        // a December "Resets 2 Jan" lands in the next year.
        let nowYear = calendar.component(.year, from: now)
        let pastTolerance = now.addingTimeInterval(-2 * 24 * 60 * 60)
        for candidateYear in [nowYear - 1, nowYear, nowYear + 1] {
            components.year = candidateYear
            if let candidate = calendar.date(from: components), candidate >= pastTolerance {
                return candidate
            }
        }
        return nil
    }

    private static func adjustedHour(_ hour: Int?, meridiem: String?) -> Int? {
        guard let hour else { return nil }
        guard let meridiem = meridiem?.lowercased() else { return hour }
        if meridiem == "p" { return hour == 12 ? 12 : hour + 12 }
        return hour == 12 ? 0 : hour
    }

    private static func monthNumber(_ name: String?) -> Int? {
        guard let prefix = name?.lowercased().prefix(3), prefix.count == 3 else { return nil }
        let months = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]
        guard let index = months.firstIndex(of: String(prefix)) else { return nil }
        return index + 1
    }

    private static func firstMatch(pattern: String, in text: String) -> String? {
        matchGroups(pattern: pattern, in: text)?[1]
    }

    /// 1-indexed capture groups of the first match; nil entries for
    /// unmatched optional groups. Index 0 is unused.
    private static func matchGroups(pattern: String, in text: String) -> [String?]? {
        guard !text.isEmpty,
              let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range) else { return nil }
        var groups: [String?] = [nil]
        for index in 1..<match.numberOfRanges {
            if let captureRange = Range(match.range(at: index), in: text) {
                groups.append(String(text[captureRange]))
            } else {
                groups.append(nil)
            }
        }
        return groups
    }
}

#if os(macOS)
/// Uses the persistent console session, including refreshed cookies and local storage.
@MainActor
private enum MuseSubscriptionRenderedPageReader {
    static func read(url: URL, cookieHeader: String, now: Date) async -> MuseSubscriptionWebReading? {
        guard let text = try? await ImportedSessionPageReader.read(url: url, cookieHeader: cookieHeader, isReady: {
            let reading = MuseSubscriptionWebClient.parse(renderedText: $0, now: now)
            return reading?.currentUsedPercent != nil && reading?.weeklyUsedPercent != nil
        }) else { return nil }
        return MuseSubscriptionWebClient.parse(renderedText: text, now: now)
    }
}
#endif

/// Same anti-abuse posture as the billing cache: the usage console is an
/// authenticated browser surface, so live fetches are capped at
/// `MetaWebBillingRefreshCadence` (hourly on success, 6-hourly after a
/// failure) and the last reading is persisted across launches.
actor MuseSubscriptionRefreshCache {
    enum FetchDecision {
        case fetch
        case cached(MuseSubscriptionWebReading?)
    }

    private struct PersistedState: Codable {
        let sessionFingerprint: String
        var reading: MuseSubscriptionWebReading?
        var lastSuccessfulFetchAt: Date?
        var lastAttemptAt: Date?
    }

    static let shared = MuseSubscriptionRefreshCache()

    private static let appGroupID = "group.com.chrisizatt.LLMUsageCounter"
    private static let defaultPersistenceKey = "meta.museSubscriptionRefreshCache.v1"

    private let defaults: UserDefaults
    private let persistenceKey: String
    private var state: PersistedState?

    init(
        defaults: UserDefaults? = nil,
        persistenceKey: String = MuseSubscriptionRefreshCache.defaultPersistenceKey
    ) {
        self.defaults = defaults
            ?? UserDefaults(suiteName: Self.appGroupID)
            ?? .standard
        self.persistenceKey = persistenceKey
        state = self.defaults.data(forKey: persistenceKey).flatMap {
            try? JSONDecoder().decode(PersistedState.self, from: $0)
        }
    }

    func decision(for cookieHeader: String, now: Date) -> FetchDecision {
        let fingerprint = Self.fingerprint(for: cookieHeader)
        guard let state, state.sessionFingerprint == fingerprint else {
            return .fetch
        }
        guard !MetaWebBillingRefreshCadence.isDue(
            now: now,
            lastSuccessfulFetchAt: state.lastSuccessfulFetchAt,
            lastAttemptAt: state.lastAttemptAt
        ) else {
            return .fetch
        }
        return .cached(state.reading)
    }

    @discardableResult
    func recordResult(
        _ reading: MuseSubscriptionWebReading?,
        for cookieHeader: String,
        now: Date
    ) -> MuseSubscriptionWebReading? {
        let fingerprint = Self.fingerprint(for: cookieHeader)
        var next = state?.sessionFingerprint == fingerprint
            ? state!
            : PersistedState(
                sessionFingerprint: fingerprint,
                reading: nil,
                lastSuccessfulFetchAt: nil,
                lastAttemptAt: nil
            )

        next.lastAttemptAt = now
        if let reading {
            next.reading = reading
            next.lastSuccessfulFetchAt = now
        }
        state = next
        persist()

        return reading ?? next.reading
    }

    private func persist() {
        guard let state, let data = try? JSONEncoder().encode(state) else { return }
        defaults.set(data, forKey: persistenceKey)
    }

    /// Cache partitioning only: this prevents cross-session readings without
    /// persisting the imported cookie header outside Keychain.
    private static func fingerprint(for value: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x100000001b3
        }
        return String(hash, radix: 16)
    }
}

public struct MetaProviderClient: UserInitiatedProviderClient {

    public let providerID: ProviderID = .meta

    /// Injectable so tests never spawn the real CLI (which would make them
    /// depend on the machine's live Muse subscription).
    private let museCliProbe: @Sendable ([String: String], Date, Bool) async -> MuseCliSubscriptionReading?

    public init() {
        museCliProbe = { fields, now, userInitiated in
            await MetaProviderClient.probeMuseCli(
                fields: fields,
                now: now,
                userInitiated: userInitiated
            )
        }
    }

    init(
        museCliProbe: @escaping @Sendable ([String: String], Date, Bool) async -> MuseCliSubscriptionReading?
    ) {
        self.museCliProbe = museCliProbe
    }

    public func fetchSnapshot(credentials: ProviderCredential?) async throws -> QuotaSnapshot {
        try await fetchSnapshot(credentials: credentials, userInitiated: false)
    }

    public func fetchSnapshot(
        credentials: ProviderCredential?,
        userInitiated: Bool
    ) async throws -> QuotaSnapshot {
        let now = Date()
        let fields = credentials?.extraFields ?? [:]
        let access = resolveMuseAccess(credentials: credentials)
        defer { access?.stop() }

        let local = access.flatMap { MuseLocalUsageReader.read(rootURL: $0.url, now: now) }
        let taskWraith = TaskWraithSpendReader.read(provider: .meta, now: now)

        // Meta's authenticated billing page applies browser-level abuse controls,
        // so never poll it at the dashboard's cadence. A cached reading remains
        // useful while local Muse telemetry continues to update in real time.
        let webCookie = fields[SpendProviderCredentialField.metaCookieHeader]
        let hasSubscriptionImport = fields[SpendProviderCredentialField.museCachedAt] != nil
            || fields[SpendProviderCredentialField.museCachedWeeklyPercent] != nil
        let webReading: WebBillingReading?
        if let webCookie, !webCookie.isEmpty, !hasSubscriptionImport {
            let cache = MetaWebBillingRefreshCache.shared
            switch await cache.decision(for: webCookie, now: now) {
            case .cached(let reading):
                webReading = reading
            case .fetch:
                let liveReading = await WebBillingClient(
                    // Honour the user's own configured URL like every other
                    // browser-meter site does. This one went straight at a
                    // fallback that embedded the maintainer's project and team
                    // ids, so a Meta user who had not set an override was
                    // navigated — carrying their own session cookies — to the
                    // maintainer's project billing page rather than their own.
                    // The fallback is now the bare console page and lets Meta
                    // resolve the signed-in account; if that page turns out not
                    // to select a project on its own, the read fails visibly and
                    // the user sets an override, which beats silently reading
                    // somebody else's.
                    baseURL: BrowserSessionRefreshPolicy.validatedURL(
                        fields[SpendProviderCredentialField.browserSessionURL],
                        fallback: URL(string: "https://dev.meta.ai/billing/")!
                    ),
                    cookieDomains: ["meta.ai", "meta.com"]
                ).fetch(
                    cookieHeader: webCookie,
                    now: now,
                    persistCookieHeader: {
                        await persistImportedCookieHeader(
                            $0,
                            providerID: .meta,
                            field: SpendProviderCredentialField.metaCookieHeader
                        )
                    }
                )
                webReading = await cache.recordResult(
                    liveReading,
                    for: webCookie,
                    now: now
                )
            }
        } else {
            webReading = nil
        }

        // One rendered subscription request fits within the provider timeout.
        // Avoid an extra billing navigation or CLI probe when this source exists.
        let museBrowserResult: BrowserMeterResult<MuseSubscriptionWebReading>?
        if let webCookie, !webCookie.isEmpty, hasSubscriptionImport {
            let endpoint = BrowserSessionRefreshPolicy.validatedURL(
                fields[SpendProviderCredentialField.browserSessionURL],
                // Bare console page, as above: no maintainer project or team id.
                fallback: URL(string: "https://dev.meta.ai/usage/")!
            )
            museBrowserResult = await BrowserMeterRefreshStore.shared.read(
                url: endpoint,
                sessionID: fields[SpendProviderCredentialField.browserSessionID] ?? webCookie,
                initial: Self.cachedMuseSubscriptionReading(from: fields),
                initialAt: ProviderDateParser.parse(fields[SpendProviderCredentialField.museCachedAt]),
                interval: 60 * 60,
                failureInterval: 6 * 60 * 60,
                now: now
            ) {
                #if os(macOS)
                let text = try await ImportedSessionPageReader.read(url: endpoint, cookieHeader: webCookie) {
                    let reading = MuseSubscriptionWebClient.parse(renderedText: $0, now: now)
                    return reading?.currentUsedPercent != nil && reading?.weeklyUsedPercent != nil
                }
                guard let reading = MuseSubscriptionWebClient.parse(renderedText: text, now: now) else {
                    throw ProviderFetchError.parsingError("Muse subscription meters unavailable.")
                }
                return reading
                #else
                throw ProviderFetchError.credentialExpired("Reconnect Muse in the browser on your Mac.")
                #endif
            }
        } else {
            museBrowserResult = nil
        }
        if let failure = museBrowserResult?.failureError { throw failure }
        let museCliReading = museBrowserResult != nil ? nil : await museCliProbe(fields, now, userInitiated)
        let museSubscription = Self.museSubscriptionMeters(
            cli: museCliReading,
            live: museBrowserResult?.value,
            cached: Self.cachedMuseSubscriptionReading(from: fields),
            now: now
        )

        let preload = positiveDouble(fields[SpendProviderCredentialField.manualTopUpTotal])
             ?? positiveDouble(fields[SpendProviderCredentialField.manualAllowance])
        // Web reading overrides manual remaining when present.
        let remaining = webReading?.balance
             ?? nonnegativeDouble(fields[SpendProviderCredentialField.manualCurrentBalance])
        // Web reading overrides manual spend when present.
        let manualSpent = webReading?.spend
             ?? nonnegativeDouble(fields[SpendProviderCredentialField.manualSpent])
        let currency = webReading?.currency
             ?? normalizedCurrency(fields[SpendProviderCredentialField.manualCurrency])
        let manualResetAt = webReading?.periodEnd
             ?? ProviderDateParser.parse(fields[SpendProviderCredentialField.manualResetAt])
        let resetAt = manualResetAt ?? MetaBillingReset.nextResetDate(from: now)
        let softBudget = ProviderMonthlyBudgetStore.nonisolatedBudgetUSD(for: .meta) ?? 15.0
        let planName = museSubscription.planName
             ?? fields[SpendProviderCredentialField.manualPlanName]?.trimmingCharacters(
                in: .whitespacesAndNewlines
             ).nilIfEmpty
             ?? "API Credits"

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

        // Subscription meters lead the card: they are the live quota story,
        // while the credit/spend windows below are billing anchors.
        var windows: [QuotaWindow] = museSubscription.windows.map { window in
            guard let museBrowserResult else { return window }
            return QuotaWindow(
                label: window.label, windowKind: window.windowKind,
                used: window.used, total: window.total, resetDate: window.resetDate,
                unit: window.unit, subtitle: museBrowserResult.sourceDescription
            )
        }
        var balances: [QuotaBalance] = []
        var signals: [QuotaSignal] = []

        if let preload, let displayRemaining,
           let creditUsed = DeepSeekTopUpMeter.creditUsed(
            totalTopUp: preload,
            currentBalance: displayRemaining
           ) {
            windows.append(
                QuotaWindow(
                    label: "Credit used",
                    windowKind: .monthly,
                    used: creditUsed,
                    total: preload,
                    resetDate: resetAt,
                    unit: currency,
                    subtitle: remainingLocalDecrement > 0
                        ? "Preload minus remaining, auto-advanced by Muse spend"
                        : "Configured preload minus remaining Meta balance"
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

        let hasAnchors = preload != nil || remaining != nil || manualSpent != nil
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
            fetchState: .success,
            fetchedAt: museBrowserResult?.fetchedAt ?? now
        )
    }

    struct MuseSubscriptionMeterAssembly {
        let windows: [QuotaWindow]
        let planName: String?
    }

    /// Builds the subscription meters from the best source available per
    /// field: the local CLI first, then the live (or cadence-cached) web
    /// reading, then the values captured by the import sheet — so a partial
    /// parse from any one source cannot blank a meter.
    static func museSubscriptionMeters(
        cli: MuseCliSubscriptionReading?,
        live: MuseSubscriptionWebReading?,
        cached: MuseSubscriptionWebReading?,
        now: Date
    ) -> MuseSubscriptionMeterAssembly {
        let currentPercent = cli?.currentUsedPercent
            ?? live?.currentUsedPercent
            ?? cached?.currentUsedPercent
        let weeklyPercent = cli?.weeklyUsedPercent
            ?? live?.weeklyUsedPercent
            ?? cached?.weeklyUsedPercent
        let planName = cli?.planName ?? live?.planName ?? cached?.planName

        let currentFromCli = cli?.currentUsedPercent != nil
        let weeklyFromCli = cli?.weeklyUsedPercent != nil

        // Each reset belongs to whichever source supplied that meter.
        let webCurrentReset = live?.currentUsedPercent != nil ? live?.currentResetAt : nil
        let currentReset = acceptedCurrentReset(
            currentFromCli
                ? cli?.currentResetAt
                : (webCurrentReset ?? cached?.currentResetAt ?? live?.currentResetAt),
            now: now
        )
        let webWeeklyReset = live?.weeklyUsedPercent != nil ? live?.weeklyResetAt : nil
        let weeklyReset = acceptedWeeklyReset(
            weeklyFromCli
                ? cli?.weeklyResetAt
                : (webWeeklyReset ?? cached?.weeklyResetAt ?? live?.weeklyResetAt),
            now: now
        )

        func subtitle(fromCli: Bool, live liveValue: Double?) -> String {
            if fromCli { return "Muse Code subscription — local CLI" }
            if liveValue != nil { return "Muse Code subscription — dev.meta.ai/usage" }
            return "Muse Code subscription — captured at import"
        }

        var windows: [QuotaWindow] = []
        if let currentPercent {
            windows.append(
                QuotaWindow(
                    label: "Current usage",
                    windowKind: .session,
                    used: currentPercent,
                    total: 100,
                    resetDate: currentReset,
                    unit: "%",
                    subtitle: subtitle(fromCli: currentFromCli, live: live?.currentUsedPercent)
                )
            )
        }
        if let weeklyPercent {
            windows.append(
                QuotaWindow(
                    label: "Weekly limit",
                    windowKind: .weekly,
                    used: weeklyPercent,
                    total: 100,
                    resetDate: weeklyReset,
                    unit: "%",
                    subtitle: subtitle(fromCli: weeklyFromCli, live: live?.weeklyUsedPercent)
                )
            )
        }
        return MuseSubscriptionMeterAssembly(windows: windows, planName: planName)
    }

    /// The current window rolls in hours; a reset beyond a day is a misparse,
    /// and an expired one would zero the meter's fraction.
    private static func acceptedCurrentReset(_ candidate: Date?, now: Date) -> Date? {
        guard let candidate,
              candidate > now,
              candidate <= now.addingTimeInterval(25 * 60 * 60) else {
            return nil
        }
        return candidate
    }

    /// Runs the local CLI probe behind its own cadence cache. A manual refresh
    /// re-probes immediately; otherwise the last reading is reused.
    static func probeMuseCli(
        fields: [String: String],
        now: Date,
        userInitiated: Bool
    ) async -> MuseCliSubscriptionReading? {
        #if os(macOS)
        let cache = MuseCliRefreshCache.shared
        switch await cache.decision(now: now, userInitiated: userInitiated) {
        case .cached(let reading):
            return reading
        case .fetch:
            guard let resolved = MuseCliBinaryLocator.resolve(fields: fields) else {
                print("[MuseCliUsage] No runnable `muse` launcher: grant the Muse CLI folder in Settings")
                // Records the attempt so a missing CLI backs off rather than
                // re-resolving on every refresh.
                return await cache.recordResult(nil, now: now)
            }
            print("[MuseCliUsage] Probing subscription meters via \(resolved.url.path)")
            // The probe blocks on a pty read loop; keep it off the cooperative
            // executor so it cannot stall other provider refreshes.
            let reading = await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    let value = MuseCliUsageProbe.probe(binaryURL: resolved.url, now: now)
                    resolved.stop()
                    continuation.resume(returning: value)
                }
            }
            if let reading {
                print("[MuseCliUsage] Read current=\(reading.currentUsedPercent.map { "\($0)%" } ?? "—") weekly=\(reading.weeklyUsedPercent.map { "\($0)%" } ?? "—")")
            }
            return await cache.recordResult(reading, now: now)
        }
        #else
        return nil
        #endif
    }

    /// Weekly resets more than 8 days out are misparses; expired resets would
    /// zero the meter's fraction, so both render as a meter without a date.
    private static func acceptedWeeklyReset(_ candidate: Date?, now: Date) -> Date? {
        guard let candidate,
              candidate > now,
              candidate <= now.addingTimeInterval(8 * 24 * 60 * 60) else {
            return nil
        }
        return candidate
    }

    static func cachedMuseSubscriptionReading(from fields: [String: String]) -> MuseSubscriptionWebReading? {
        let reading = MuseSubscriptionWebReading(
            planName: fields[SpendProviderCredentialField.museCachedPlanName]?
                .trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
            currentUsedPercent: nonnegativePercent(fields[SpendProviderCredentialField.museCachedCurrentPercent]),
            currentResetAt: ProviderDateParser.parse(fields[SpendProviderCredentialField.museCachedCurrentResetAt]),
            weeklyUsedPercent: nonnegativePercent(fields[SpendProviderCredentialField.museCachedWeeklyPercent]),
            weeklyResetAt: ProviderDateParser.parse(fields[SpendProviderCredentialField.museCachedWeeklyResetAt])
        )
        return reading.isEmpty ? nil : reading
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
