import Foundation
import Security
import SQLite3
#if os(macOS)
import Darwin
#endif

// MARK: - TaskWraith Unified Telemetry Source

/// Reads TaskWraith's unified usage telemetry (`usage.json`) and emits
/// per-provider `UsageEvent` records.
///
/// TaskWraith maintains a JSON array at
/// `~/Library/Application Support/taskwraith/usage.json` that records every
/// chat/run across providers — Kimi, Gemini, Codex, Claude — in a clean
/// structured form. This is a richer signal than per-provider local
/// scanners for users who drive activity through TaskWraith, since one
/// file aggregates everything.
enum AGBenchUsageReader {
    private static let usageFileRelativePath = "usage.json"
    private static let maximumUsageFileBytes = 32 * 1_024 * 1_024

    /// Returns recent `UsageEvent`s drawn from `usage.json` for the
    /// given provider key. Provider keys match TaskWraith's internal naming
    /// (`"kimi"`, `"gemini"`, `"codex"`, `"claude"`), not our
    /// `ProviderID.rawValue`.
    ///
    /// Returns `[]` on any failure (file missing, JSON malformed,
    /// sandbox denial). Failures log to console so they surface without
    /// breaking the calling provider's fetch.
    static func events(
        forProviderKey providerKey: String,
        rootURL: URL,
        retentionDays: Int = 35,
        now: Date = Date()
    ) -> [UsageEvent] {
        let fileURL = resolveUsageFileURL(rootURL: rootURL)
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            print("[AGBenchReader] usage.json not found at \(fileURL.path)")
            return []
        }

        guard let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
              values.isRegularFile == true,
              let fileSize = values.fileSize,
              fileSize >= 0,
              fileSize <= maximumUsageFileBytes,
              let data = try? Data(contentsOf: fileURL, options: .mappedIfSafe) else {
            print("[AGBenchReader] Read failed for \(fileURL.path) (sandbox / permissions?)")
            return []
        }

        guard let records = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            print("[AGBenchReader] usage.json had unexpected shape (not a top-level array)")
            return []
        }

        let horizon = now.addingTimeInterval(-Double(retentionDays) * 24 * 60 * 60)
        let normalizedKey = providerKey.lowercased()
        var events: [UsageEvent] = []
        events.reserveCapacity(records.count)

        for record in records {
            guard let recordProvider = (record["provider"] as? String)?.lowercased(),
                  recordProvider == normalizedKey else { continue }

            // Timestamps are Unix epoch milliseconds.
            guard let timestampMs = numericValue(record["timestamp"]) else { continue }
            let timestamp = Date(timeIntervalSince1970: timestampMs / 1000)
            guard timestamp >= horizon else { continue }

            let totalTokens = numericValue(record["totalTokens"]) ?? 0
            // Some records carry tokens == 0 (e.g. a run that failed
            // before producing output); we still emit the event with
            // tokens=nil so it shows up on the heatmap as an activity
            // marker without inflating token totals.
            let tokens: Double? = totalTokens > 0 ? totalTokens : nil
            let model = (record["model"] as? String) ?? providerKey

            events.append(
                UsageEvent(
                    timestamp: timestamp,
                    tokens: tokens,
                    model: model,
                    type: .message
                )
            )
        }

        print("[AGBenchReader] Loaded \(events.count) events for provider '\(providerKey)' from \(fileURL.lastPathComponent)")
        return events
    }

    /// Resolves the user-bookmarked root URL into the actual
    /// `usage.json` path. Accepts either:
    ///   - A bookmark on the TaskWraith app-support directory (we append
    ///     `usage.json`).
    ///   - A bookmark directly on `usage.json`.
    private static func resolveUsageFileURL(rootURL: URL) -> URL {
        if rootURL.lastPathComponent == usageFileRelativePath {
            return rootURL
        }
        return rootURL.appendingPathComponent(usageFileRelativePath)
    }

    private static func numericValue(_ value: Any?) -> Double? {
        if let v = value as? Double { return v }
        if let v = value as? Int { return Double(v) }
        if let v = value as? NSNumber { return v.doubleValue }
        if let v = value as? String { return Double(v) }
        return nil
    }

    /// Convenience wrapper: resolves the bookmark, opens scoped access,
    /// parses events, tears scoped access down. Most callers should
    /// use this rather than stitching the pieces together.
    static func loadEvents(forProviderKey providerKey: String) -> [UsageEvent] {
        guard let scoped = AGBenchBookmarkStore.startAccess() else {
            return []
        }
        defer { scoped.stop() }
        return events(forProviderKey: providerKey, rootURL: scoped.url)
    }
}

/// Persists a single user-granted security-scoped bookmark to the
/// TaskWraith data directory. Stored in `UserDefaults` under the legacy fixed
/// key so existing grants continue to work
/// rather than the per-provider `ProviderCredential` keychain because
/// the same bookmark is consumed by multiple providers (Kimi, Codex,
/// Gemini, Claude).
enum AGBenchBookmarkStore {
    private static let defaultsKey = "agbenchBookmarkData"

    static var hasBookmark: Bool {
        UserDefaults.standard.data(forKey: defaultsKey) != nil
    }

    static var suggestedDataDirectory: URL {
        #if os(macOS)
        let applicationSupport = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        let taskWraith = applicationSupport.appendingPathComponent("taskwraith", isDirectory: true)
        if FileManager.default.fileExists(atPath: taskWraith.path) {
            return taskWraith
        }
        return applicationSupport.appendingPathComponent("agbench", isDirectory: true)
        #else
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        #endif
    }

    @discardableResult
    static func save(url: URL) -> Bool {
        #if os(macOS)
        do {
            let bookmark = try url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            UserDefaults.standard.set(bookmark, forKey: defaultsKey)
            print("[AGBenchBookmark] Saved bookmark for \(url.path)")
            return true
        } catch {
            print("[AGBenchBookmark] Failed to create bookmark for \(url.path): \(error)")
            return false
        }
        #else
        return false
        #endif
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: defaultsKey)
    }

    /// Resolves the saved bookmark and starts security-scoped access.
    /// Returns the URL plus a closure to release access (caller MUST
    /// invoke). Returns `nil` if no bookmark or unresolvable.
    static func startAccess() -> (url: URL, stop: () -> Void)? {
        guard let bookmark = UserDefaults.standard.data(forKey: defaultsKey) else {
            return nil
        }

        #if os(macOS)
        var isStale = false
        guard let url = try? URL(
            resolvingBookmarkData: bookmark,
            options: .withSecurityScope,
            bookmarkDataIsStale: &isStale
        ) else {
            print("[AGBenchBookmark] Failed to resolve bookmark — user may need to re-grant access")
            return nil
        }

        if isStale {
            print("[AGBenchBookmark] Bookmark is stale (path moved?) — events may still load but a re-grant is recommended")
        }

        let didStart = url.startAccessingSecurityScopedResource()
        return (url, {
            if didStart { url.stopAccessingSecurityScopedResource() }
        })
        #else
        return nil
        #endif
    }
}

// MARK: - Grok Provider

/// Mirrors TaskWraith's `GrokUsageSnapshot` bridge shape.
///
/// The bridge originally reported the older SuperGrok subscription-credit
/// meter (`creditsUsedPercent`). Grok's `/usage` screen now reports a weekly
/// quota, so the decoder accepts both the new weekly fields and the legacy
/// credit fields until every installed TaskWraith build has moved over.
struct GrokUsageSnapshot: Decodable {
    let usageKind: String?
    let weeklyLimitUsedPercent: Double?
    let weeklyUsedPercent: Double?
    let limitUsedPercent: Double?
    let usedPercent: Double?
    let weeklyLimitUsedDisplay: String?
    let weeklyUsedDisplay: String?
    let weeklyLimitLeftPercent: Double?
    let weeklyLeftPercent: Double?
    let limitLeftPercent: Double?
    let remainingPercent: Double?
    let weeklyLimitLeftDisplay: String?
    let weeklyLeftDisplay: String?
    let creditsUsedPercent: Double?
    let creditsUsedDisplay: String?
    let resetAtText: String?
    let weeklyResetAtText: String?
    let nextResetText: String?
    let resetAt: String?
    let weeklyResetAt: String?
    let nextResetAt: String?
    let limitWindowSeconds: Double?
    let planLabel: String?
    let payAsYouGoEnabled: Bool?
    let refreshedAt: String?
    let confidence: String?

    init(
        usageKind: String?,
        weeklyLimitUsedPercent: Double? = nil,
        weeklyUsedPercent: Double? = nil,
        limitUsedPercent: Double? = nil,
        usedPercent: Double? = nil,
        weeklyLimitUsedDisplay: String? = nil,
        weeklyUsedDisplay: String? = nil,
        weeklyLimitLeftPercent: Double? = nil,
        weeklyLeftPercent: Double? = nil,
        limitLeftPercent: Double? = nil,
        remainingPercent: Double? = nil,
        weeklyLimitLeftDisplay: String? = nil,
        weeklyLeftDisplay: String? = nil,
        creditsUsedPercent: Double? = nil,
        creditsUsedDisplay: String? = nil,
        resetAtText: String? = nil,
        weeklyResetAtText: String? = nil,
        nextResetText: String? = nil,
        resetAt: String? = nil,
        weeklyResetAt: String? = nil,
        nextResetAt: String? = nil,
        limitWindowSeconds: Double? = nil,
        planLabel: String? = nil,
        payAsYouGoEnabled: Bool? = nil,
        refreshedAt: String? = nil,
        confidence: String? = nil
    ) {
        self.usageKind = usageKind
        self.weeklyLimitUsedPercent = weeklyLimitUsedPercent
        self.weeklyUsedPercent = weeklyUsedPercent
        self.limitUsedPercent = limitUsedPercent
        self.usedPercent = usedPercent
        self.weeklyLimitUsedDisplay = weeklyLimitUsedDisplay
        self.weeklyUsedDisplay = weeklyUsedDisplay
        self.weeklyLimitLeftPercent = weeklyLimitLeftPercent
        self.weeklyLeftPercent = weeklyLeftPercent
        self.limitLeftPercent = limitLeftPercent
        self.remainingPercent = remainingPercent
        self.weeklyLimitLeftDisplay = weeklyLimitLeftDisplay
        self.weeklyLeftDisplay = weeklyLeftDisplay
        self.creditsUsedPercent = creditsUsedPercent
        self.creditsUsedDisplay = creditsUsedDisplay
        self.resetAtText = resetAtText
        self.weeklyResetAtText = weeklyResetAtText
        self.nextResetText = nextResetText
        self.resetAt = resetAt
        self.weeklyResetAt = weeklyResetAt
        self.nextResetAt = nextResetAt
        self.limitWindowSeconds = limitWindowSeconds
        self.planLabel = planLabel
        self.payAsYouGoEnabled = payAsYouGoEnabled
        self.refreshedAt = refreshedAt
        self.confidence = confidence
    }

    private enum CodingKeys: String, CodingKey {
        case usageKind
        case weeklyLimitUsedPercent
        case weeklyUsedPercent
        case limitUsedPercent
        case usedPercent
        case weeklyLimitUsedDisplay
        case weeklyUsedDisplay
        case weeklyLimitLeftPercent
        case weeklyLeftPercent
        case limitLeftPercent
        case remainingPercent
        case weeklyLimitLeftDisplay
        case weeklyLeftDisplay
        case creditsUsedPercent
        case creditsUsedDisplay
        case resetAtText
        case weeklyResetAtText
        case nextResetText
        case resetAt
        case weeklyResetAt
        case nextResetAt
        case limitWindowSeconds
        case planLabel
        case payAsYouGoEnabled
        case refreshedAt
        case confidence
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        usageKind = try container.decodeIfPresent(String.self, forKey: .usageKind)
        weeklyLimitUsedPercent = Self.decodeFlexibleDouble(container, .weeklyLimitUsedPercent)
        weeklyUsedPercent = Self.decodeFlexibleDouble(container, .weeklyUsedPercent)
        limitUsedPercent = Self.decodeFlexibleDouble(container, .limitUsedPercent)
        usedPercent = Self.decodeFlexibleDouble(container, .usedPercent)
        weeklyLimitUsedDisplay = try container.decodeIfPresent(String.self, forKey: .weeklyLimitUsedDisplay)
        weeklyUsedDisplay = try container.decodeIfPresent(String.self, forKey: .weeklyUsedDisplay)
        weeklyLimitLeftPercent = Self.decodeFlexibleDouble(container, .weeklyLimitLeftPercent)
        weeklyLeftPercent = Self.decodeFlexibleDouble(container, .weeklyLeftPercent)
        limitLeftPercent = Self.decodeFlexibleDouble(container, .limitLeftPercent)
        remainingPercent = Self.decodeFlexibleDouble(container, .remainingPercent)
        weeklyLimitLeftDisplay = try container.decodeIfPresent(String.self, forKey: .weeklyLimitLeftDisplay)
        weeklyLeftDisplay = try container.decodeIfPresent(String.self, forKey: .weeklyLeftDisplay)
        creditsUsedPercent = Self.decodeFlexibleDouble(container, .creditsUsedPercent)
        creditsUsedDisplay = try container.decodeIfPresent(String.self, forKey: .creditsUsedDisplay)
        resetAtText = try container.decodeIfPresent(String.self, forKey: .resetAtText)
        weeklyResetAtText = try container.decodeIfPresent(String.self, forKey: .weeklyResetAtText)
        nextResetText = try container.decodeIfPresent(String.self, forKey: .nextResetText)
        resetAt = try container.decodeIfPresent(String.self, forKey: .resetAt)
        weeklyResetAt = try container.decodeIfPresent(String.self, forKey: .weeklyResetAt)
        nextResetAt = try container.decodeIfPresent(String.self, forKey: .nextResetAt)
        limitWindowSeconds = Self.decodeFlexibleDouble(container, .limitWindowSeconds)
        planLabel = try container.decodeIfPresent(String.self, forKey: .planLabel)
        payAsYouGoEnabled = Self.decodeFlexibleBool(container, .payAsYouGoEnabled)
        refreshedAt = try container.decodeIfPresent(String.self, forKey: .refreshedAt)
        confidence = try container.decodeIfPresent(String.self, forKey: .confidence)
    }

    var isObserved: Bool {
        (confidence ?? "observed").lowercased() == "observed"
    }

    var resolvedPlanName: String {
        guard let plan = planLabel?.trimmingCharacters(in: .whitespacesAndNewlines),
              !plan.isEmpty else {
            return "SuperGrok"
        }
        return plan
    }

    private static func decodeFlexibleDouble(
        _ container: KeyedDecodingContainer<CodingKeys>,
        _ key: CodingKeys
    ) -> Double? {
        if let value = try? container.decodeIfPresent(Double.self, forKey: key) {
            return value
        }
        guard let string = try? container.decodeIfPresent(String.self, forKey: key) else {
            return nil
        }
        let normalized = string
            .replacingOccurrences(of: ",", with: "")
            .replacingOccurrences(of: "%", with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "<> ").union(.whitespacesAndNewlines))
        return Double(normalized)
    }

    private static func decodeFlexibleBool(
        _ container: KeyedDecodingContainer<CodingKeys>,
        _ key: CodingKeys
    ) -> Bool? {
        if let value = try? container.decodeIfPresent(Bool.self, forKey: key) {
            return value
        }
        guard let string = try? container.decodeIfPresent(String.self, forKey: key) else {
            return nil
        }
        switch string.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "true", "enabled", "on", "yes":
            return true
        case "false", "disabled", "off", "no":
            return false
        default:
            return nil
        }
    }
}

nonisolated enum GrokUsageWindowMapper {
    static func quotaWindow(from snapshot: GrokUsageSnapshot, now: Date = Date()) -> QuotaWindow? {
        guard snapshot.isObserved else { return nil }
        if let weeklyWindow = weeklyQuotaWindow(from: snapshot, now: now) {
            return weeklyWindow
        }
        return legacyCreditWindow(from: snapshot, now: now)
    }

    static func weeklyQuotaWindow(from snapshot: GrokUsageSnapshot, now: Date = Date()) -> QuotaWindow? {
        let usageKind = snapshot.usageKind?.lowercased() ?? ""
        let resetText = firstNonEmpty(
            snapshot.weeklyResetAtText,
            snapshot.nextResetText,
            snapshot.resetAtText
        )
        let hasWeeklySignal = usageKind.contains("weekly")
            || snapshot.weeklyLimitUsedPercent != nil
            || snapshot.weeklyUsedPercent != nil
            || snapshot.limitUsedPercent != nil
            || snapshot.usedPercent != nil
            || snapshot.weeklyLimitUsedDisplay?.isEmpty == false
            || snapshot.weeklyUsedDisplay?.isEmpty == false
            || snapshot.weeklyLimitLeftPercent != nil
            || snapshot.weeklyLeftPercent != nil
            || snapshot.limitLeftPercent != nil
            || snapshot.remainingPercent != nil
            || snapshot.weeklyLimitLeftDisplay?.isEmpty == false
            || snapshot.weeklyLeftDisplay?.isEmpty == false
            || resetText?.localizedCaseInsensitiveContains("weekly") == true
        guard hasWeeklySignal else { return nil }

        let directUsed = firstFinite(
            snapshot.weeklyLimitUsedPercent,
            snapshot.weeklyUsedPercent,
            snapshot.limitUsedPercent,
            snapshot.usedPercent,
            parsePercent(firstNonEmpty(snapshot.weeklyLimitUsedDisplay, snapshot.weeklyUsedDisplay))
        )
        let left = firstFinite(
            snapshot.weeklyLimitLeftPercent,
            snapshot.weeklyLeftPercent,
            snapshot.limitLeftPercent,
            snapshot.remainingPercent,
            parsePercent(firstNonEmpty(snapshot.weeklyLimitLeftDisplay, snapshot.weeklyLeftDisplay))
        )

        let usedPercent: Double
        if let directUsed {
            usedPercent = clampedPercent(directUsed)
        } else if let left {
            usedPercent = clampedPercent(100 - left)
        } else {
            return nil
        }

        let resetDate = parseResetDate(
            iso: firstNonEmpty(snapshot.weeklyResetAt, snapshot.nextResetAt, snapshot.resetAt),
            text: resetText,
            refreshedAt: snapshot.refreshedAt,
            now: now
        )
        if let resetDate, resetDate < now.addingTimeInterval(-5 * 60) {
            return nil
        }

        return QuotaWindow(
            label: "Weekly",
            windowKind: .weekly,
            used: usedPercent,
            total: 100,
            resetDate: resetDate,
            unit: "%",
            subtitle: resetText.map { "Weekly limit resets \(formatResetText($0))" } ?? "Grok weekly usage limit"
        )
    }

    static func legacyCreditWindow(from snapshot: GrokUsageSnapshot, now: Date = Date()) -> QuotaWindow? {
        guard let percent = firstFinite(
            snapshot.creditsUsedPercent,
            parsePercent(snapshot.creditsUsedDisplay)
        ) else {
            return nil
        }

        let resetText = snapshot.resetAtText
        let resetDate = parseResetDate(
            iso: snapshot.resetAt,
            text: resetText,
            refreshedAt: snapshot.refreshedAt,
            now: now
        )

        // The old monthly credit snapshot can remain on disk after Grok has
        // switched to weekly quota output. Avoid rendering an expired legacy
        // "Credits" row as if it were current data.
        if let resetDate, resetDate < now {
            return nil
        }

        return QuotaWindow(
            label: "Credits",
            windowKind: .sliding,
            used: clampedPercent(percent),
            total: 100,
            resetDate: resetDate,
            unit: "%",
            subtitle: resetText.map { "Resets \(formatResetText($0))" } ?? "Legacy Grok credit meter"
        )
    }

    static func parseResetDate(
        iso: String?,
        text: String?,
        refreshedAt: String?,
        now: Date = Date()
    ) -> Date? {
        if let iso = firstNonEmpty(iso),
           let date = parseISODate(iso) {
            return date
        }

        guard let text = firstNonEmpty(text) else { return nil }
        let reference: Date
        if let refreshedAt, let parsedRefreshedAt = parseISODate(refreshedAt) {
            reference = parsedRefreshedAt
        } else {
            reference = now
        }
        return parsePacificResetText(text, reference: reference)
    }

    static func parsePercent(_ value: String?) -> Double? {
        guard var value = firstNonEmpty(value) else { return nil }
        value = value.replacingOccurrences(of: ",", with: "")
        guard let match = value.range(
            of: #"[<>]?\s*([0-9]+(?:\.[0-9]+)?)\s*%"#,
            options: .regularExpression
        ) else {
            return nil
        }
        let raw = String(value[match])
            .replacingOccurrences(of: "<", with: "")
            .replacingOccurrences(of: ">", with: "")
            .replacingOccurrences(of: "%", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return Double(raw)
    }

    private static func parseISODate(_ value: String) -> Date? {
        let withFractional = ISO8601DateFormatter()
        withFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFractional.date(from: value) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: value)
    }

    private static func parsePacificResetText(_ value: String, reference: Date) -> Date? {
        let cleaned = formatResetText(value)
            .replacingOccurrences(
                of: #"(?i)^(next\s+reset|resets?)\s*:?\s*"#,
                with: "",
                options: .regularExpression
            )
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let regex = try? NSRegularExpression(
            pattern: #"^([A-Za-z]+)\s+(\d{1,2}),?\s+(\d{1,2}):(\d{2})\s*(PT|PST|PDT)$"#,
            options: [.caseInsensitive]
        ) else {
            return nil
        }
        let nsRange = NSRange(cleaned.startIndex..<cleaned.endIndex, in: cleaned)
        guard let match = regex.firstMatch(in: cleaned, range: nsRange),
              match.numberOfRanges == 6,
              let monthRange = Range(match.range(at: 1), in: cleaned),
              let dayRange = Range(match.range(at: 2), in: cleaned),
              let hourRange = Range(match.range(at: 3), in: cleaned),
              let minuteRange = Range(match.range(at: 4), in: cleaned),
              let month = monthNumber(String(cleaned[monthRange])),
              let day = Int(cleaned[dayRange]),
              let hour = Int(cleaned[hourRange]),
              let minute = Int(cleaned[minuteRange]) else {
            return nil
        }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles") ?? .gmt
        let referenceYear = calendar.component(.year, from: reference)

        func makeDate(year: Int) -> Date? {
            var components = DateComponents()
            components.calendar = calendar
            components.timeZone = calendar.timeZone
            components.year = year
            components.month = month
            components.day = day
            components.hour = hour
            components.minute = minute
            return calendar.date(from: components)
        }

        guard var date = makeDate(year: referenceYear) else { return nil }
        if date <= reference.addingTimeInterval(-60 * 60),
           let nextYear = makeDate(year: referenceYear + 1) {
            date = nextYear
        }
        return date
    }

    private static func monthNumber(_ value: String) -> Int? {
        let key = value.prefix(3).lowercased()
        let months = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]
        guard let index = months.firstIndex(of: String(key)) else { return nil }
        return index + 1
    }

    private static func formatResetText(_ value: String) -> String {
        value
            .replacingOccurrences(
                of: #"([A-Za-z])(\d)"#,
                with: "$1 $2",
                options: .regularExpression
            )
            .replacingOccurrences(
                of: #"(\d)([A-Za-z]{2,})"#,
                with: "$1 $2",
                options: .regularExpression
            )
            .replacingOccurrences(
                of: #",(?=\S)"#,
                with: ", ",
                options: .regularExpression
            )
            .replacingOccurrences(
                of: #"\s+"#,
                with: " ",
                options: .regularExpression
            )
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func firstNonEmpty(_ values: String?...) -> String? {
        for value in values {
            guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !trimmed.isEmpty else {
                continue
            }
            return trimmed
        }
        return nil
    }

    private static func firstFinite(_ values: Double?...) -> Double? {
        for value in values {
            guard let value, value.isFinite else { continue }
            return value
        }
        return nil
    }

    private static func clampedPercent(_ value: Double) -> Double {
        min(max(value, 0), 100)
    }
}

nonisolated enum GrokCLIUsageParser {
    private struct RegexMatch {
        let values: [String?]

        subscript(_ index: Int) -> String? {
            guard values.indices.contains(index) else { return nil }
            return values[index]
        }
    }

    static func parse(_ rawText: String, refreshedAt: Date = Date()) -> GrokUsageSnapshot {
        let text = stripANSI(rawText)
        let refreshedAtText = isoString(refreshedAt)

        if let weeklySnapshot = parseWeeklySnapshot(text, refreshedAt: refreshedAt, refreshedAtText: refreshedAtText) {
            return weeklySnapshot
        }

        if let legacySnapshot = parseLegacyCreditSnapshot(text, refreshedAt: refreshedAt, refreshedAtText: refreshedAtText) {
            return legacySnapshot
        }

        return GrokUsageSnapshot(
            usageKind: nil,
            refreshedAt: refreshedAtText,
            confidence: "unavailable"
        )
    }

    static func stripANSI(_ input: String) -> String {
        let scalars = Array(input.unicodeScalars)
        var output = String.UnicodeScalarView()
        var index = 0

        while index < scalars.count {
            let scalar = scalars[index]

            if scalar.value == 0x1B {
                index += 1
                guard index < scalars.count else { break }

                let marker = scalars[index].value
                switch marker {
                case 0x5B: // CSI
                    index += 1
                    while index < scalars.count {
                        let value = scalars[index].value
                        index += 1
                        if value >= 0x40 && value <= 0x7E {
                            break
                        }
                    }
                case 0x5D: // OSC
                    index += 1
                    while index < scalars.count {
                        if scalars[index].value == 0x07 {
                            index += 1
                            break
                        }
                        if scalars[index].value == 0x1B,
                           index + 1 < scalars.count,
                           scalars[index + 1].value == 0x5C {
                            index += 2
                            break
                        }
                        index += 1
                    }
                case 0x50: // DCS
                    index += 1
                    while index < scalars.count {
                        if scalars[index].value == 0x1B,
                           index + 1 < scalars.count,
                           scalars[index + 1].value == 0x5C {
                            index += 2
                            break
                        }
                        index += 1
                    }
                default:
                    index += 1
                }
                continue
            }

            switch scalar.value {
            case 0x0D:
                output.append(UnicodeScalar(0x0A)!)
            case 0x08:
                if !output.isEmpty {
                    output.removeLast()
                }
            case 0x00...0x07, 0x0B...0x1F, 0x7F:
                break
            default:
                output.append(scalar)
            }
            index += 1
        }

        return String(output)
    }

    private static func parseWeeklySnapshot(
        _ text: String,
        refreshedAt: Date,
        refreshedAtText: String
    ) -> GrokUsageSnapshot? {
        let usedMatch = firstMatch(
            #"Weekly\s*limit\s*:\s*(<\s*)?([0-9]+(?:\.[0-9]+)?)\s*%"#,
            in: text
        )
        let leftMatch = firstMatch(
            #"Weekly\s*limit\s*left\s*:\s*(<\s*)?([0-9]+(?:\.[0-9]+)?)\s*%"#,
            in: text
        )

        guard usedMatch != nil || leftMatch != nil else {
            return nil
        }

        let directUsed = usedMatch.flatMap { percentValue(lessThanPrefix: $0[1], rawValue: $0[2]) }
        let left = leftMatch.flatMap { percentValue(lessThanPrefix: $0[1], rawValue: $0[2]) }
        let used = directUsed ?? left.map { 100 - $0 }
        let resetText = resetText(from: text)
        let resetAt = resetText.flatMap {
            GrokUsageWindowMapper.parseResetDate(
                iso: nil,
                text: $0,
                refreshedAt: refreshedAtText,
                now: refreshedAt
            )
        }

        return GrokUsageSnapshot(
            usageKind: "weekly_limit",
            weeklyLimitUsedPercent: used.map(clampedPercent),
            weeklyLimitUsedDisplay: usedMatch.map { percentDisplay(lessThanPrefix: $0[1], rawValue: $0[2]) }
                ?? used.map(usedDisplayFromInvertedLeft),
            weeklyLimitLeftPercent: left.map(clampedPercent),
            weeklyLimitLeftDisplay: leftMatch.map { percentDisplay(lessThanPrefix: $0[1], rawValue: $0[2]) },
            resetAtText: resetText,
            weeklyResetAtText: resetText,
            nextResetText: resetText,
            resetAt: resetAt.map(isoString),
            weeklyResetAt: resetAt.map(isoString),
            nextResetAt: resetAt.map(isoString),
            limitWindowSeconds: 7 * 24 * 60 * 60,
            planLabel: "SuperGrok",
            refreshedAt: refreshedAtText,
            confidence: "observed"
        )
    }

    private static func parseLegacyCreditSnapshot(
        _ text: String,
        refreshedAt: Date,
        refreshedAtText: String
    ) -> GrokUsageSnapshot? {
        let creditsMatch = firstMatch(
            #"Credits\s*used\s*:\s*(<\s*)?([0-9]+(?:\.[0-9]+)?)\s*%"#,
            in: text
        )
        let fallbackUsedMatch = creditsMatch == nil
            ? firstMatch(#"\b([0-9]+(?:\.[0-9]+)?)\s*%\s+used\b"#, in: text)
            : nil

        let creditsUsed = creditsMatch.flatMap { percentValue(lessThanPrefix: $0[1], rawValue: $0[2]) }
            ?? fallbackUsedMatch.flatMap { percentValue(lessThanPrefix: nil, rawValue: $0[1]) }

        guard let creditsUsed else {
            return nil
        }

        let resetText = resetText(from: text)
        let resetAt = resetText.flatMap {
            GrokUsageWindowMapper.parseResetDate(
                iso: nil,
                text: $0,
                refreshedAt: refreshedAtText,
                now: refreshedAt
            )
        }

        return GrokUsageSnapshot(
            usageKind: "subscription_credits",
            creditsUsedPercent: clampedPercent(creditsUsed),
            creditsUsedDisplay: creditsMatch.map { percentDisplay(lessThanPrefix: $0[1], rawValue: $0[2]) }
                ?? "\(compactPercent(creditsUsed))%",
            resetAtText: resetText,
            resetAt: resetAt.map(isoString),
            limitWindowSeconds: 30 * 24 * 60 * 60,
            planLabel: "SuperGrok",
            refreshedAt: refreshedAtText,
            confidence: "observed"
        )
    }

    private static func resetText(from text: String) -> String? {
        guard let match = firstMatch(
            #"\b(?:Next\s*reset|Resets?)\s*:?\s*([A-Za-z]+)\s*(\d{1,2}),?\s*(\d{1,2}):(\d{2})\s*(PT|PST|PDT)"#,
            in: text
        ) else {
            return nil
        }

        guard let month = match[1],
              let day = match[2],
              let hour = match[3],
              let minute = match[4],
              let timeZone = match[5] else {
            return nil
        }
        return "\(month) \(day), \(hour):\(minute) \(timeZone)"
    }

    private static func firstMatch(_ pattern: String, in text: String) -> RegexMatch? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range) else {
            return nil
        }

        var values: [String?] = []
        values.reserveCapacity(match.numberOfRanges)
        for index in 0..<match.numberOfRanges {
            let range = match.range(at: index)
            guard range.location != NSNotFound,
                  let swiftRange = Range(range, in: text) else {
                values.append(nil)
                continue
            }
            values.append(String(text[swiftRange]))
        }
        return RegexMatch(values: values)
    }

    private static func percentValue(lessThanPrefix: String?, rawValue: String?) -> Double? {
        guard let rawValue, let value = Double(rawValue) else { return nil }
        if lessThanPrefix?.contains("<") == true {
            return min(value, 0.5)
        }
        return value
    }

    private static func percentDisplay(lessThanPrefix: String?, rawValue: String?) -> String {
        let prefix = lessThanPrefix?.contains("<") == true ? "<" : ""
        return "\(prefix)\(rawValue ?? "0")%"
    }

    private static func usedDisplayFromInvertedLeft(_ value: Double) -> String {
        if value >= 99.5 {
            return ">99%"
        }
        return "\(compactPercent(value))%"
    }

    private static func compactPercent(_ value: Double) -> String {
        let rounded = value.rounded()
        if abs(value - rounded) < 0.005 {
            return String(Int(rounded))
        }
        return String(format: "%.1f", value)
    }

    private static func clampedPercent(_ value: Double) -> Double {
        min(max(value, 0), 100)
    }

    private static func isoString(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}

enum GrokCLIUsageProbe {
    static func fetchSnapshot(credentials: ProviderCredential?) async -> GrokUsageSnapshot? {
        #if os(macOS)
        guard let access = GrokCLIUsageAccess.resolve(credentials: credentials) else {
            return nil
        }
        defer { access.stop() }
        if let snapshot = runGrokUsageProbe(binaryURL: access.binaryURL, grokHomeURL: access.rootURL) {
            return snapshot
        }
        return GrokLocalBillingLogReader.latestSnapshot(rootURL: access.rootURL)
        #else
        return nil
        #endif
    }
}

#if os(macOS)
private struct GrokCLIUsageAccess {
    let rootURL: URL
    let binaryURL: URL
    let stop: () -> Void

    static func resolve(credentials: ProviderCredential?) -> GrokCLIUsageAccess? {
        if let bookmarkData = credentialBookmarkData(credentials),
           let scoped = resolveBookmark(bookmarkData) {
            let rootURL = normalizedGrokRootURL(from: scoped.url)
            if let binaryURL = findGrokBinary(in: rootURL) {
                return GrokCLIUsageAccess(rootURL: rootURL, binaryURL: binaryURL, stop: scoped.stop)
            }
            scoped.stop()
        }

        if let endpoint = credentials?.normalizedCustomEndpoint {
            let rootURL = normalizedGrokRootURL(from: URL(fileURLWithPath: endpoint))
            let didStart = rootURL.startAccessingSecurityScopedResource()
            if let binaryURL = findGrokBinary(in: rootURL) {
                return GrokCLIUsageAccess(rootURL: rootURL, binaryURL: binaryURL) {
                    if didStart {
                        rootURL.stopAccessingSecurityScopedResource()
                    }
                }
            }
            if didStart {
                rootURL.stopAccessingSecurityScopedResource()
            }
        }

        if let home = detectedHomeDirectory() {
            let rootURL = home.appendingPathComponent(".grok")
            if let binaryURL = findGrokBinary(in: rootURL) {
                return GrokCLIUsageAccess(rootURL: rootURL, binaryURL: binaryURL, stop: {})
            }
        }

        return nil
    }

    private static func credentialBookmarkData(_ credentials: ProviderCredential?) -> Data? {
        if let bookmarkData = credentials?.bookmarkData {
            return bookmarkData
        }
        guard let bookmarkBase64 = credentials?.extraFields?["bookmarkData"] else {
            return nil
        }
        return Data(base64Encoded: bookmarkBase64)
    }

    private static func resolveBookmark(_ bookmarkData: Data) -> (url: URL, stop: () -> Void)? {
        var isStale = false
        guard let url = try? URL(
            resolvingBookmarkData: bookmarkData,
            options: .withSecurityScope,
            bookmarkDataIsStale: &isStale
        ) else {
            return nil
        }

        if isStale {
            print("[GrokCLIUsage] Grok folder bookmark is stale; re-importing ~/.grok is recommended")
        }

        let didStart = url.startAccessingSecurityScopedResource()
        return (url, {
            if didStart {
                url.stopAccessingSecurityScopedResource()
            }
        })
    }

    private static func normalizedGrokRootURL(from selectedURL: URL) -> URL {
        let fileManager = FileManager.default
        let resourceValues = try? selectedURL.resourceValues(forKeys: [.isDirectoryKey])
        let isDirectory = resourceValues?.isDirectory ?? selectedURL.hasDirectoryPath

        if isDirectory {
            if selectedURL.lastPathComponent == "bin" || selectedURL.lastPathComponent == "downloads" {
                return selectedURL.deletingLastPathComponent()
            }
            return selectedURL
        }

        let parent = selectedURL.deletingLastPathComponent()
        if parent.lastPathComponent == "bin" || parent.lastPathComponent == "downloads" {
            return parent.deletingLastPathComponent()
        }

        if fileManager.fileExists(atPath: parent.appendingPathComponent("bin/grok").path) {
            return parent
        }
        return parent
    }

    private static func findGrokBinary(in rootURL: URL) -> URL? {
        let fileManager = FileManager.default
        let binURL = rootURL.appendingPathComponent("bin/grok")
        if fileManager.fileExists(atPath: binURL.path) || fileManager.isExecutableFile(atPath: binURL.path) {
            return binURL
        }

        let downloadsURL = rootURL.appendingPathComponent("downloads")
        guard let candidates = try? fileManager.contentsOfDirectory(
            at: downloadsURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        return candidates
            .filter { $0.lastPathComponent.hasPrefix("grok-") }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
            .first { fileManager.isExecutableFile(atPath: $0.path) }
    }

    private static func detectedHomeDirectory() -> URL? {
        if let pw = getpwuid(getuid())?.pointee,
           let homeCString = pw.pw_dir {
            return URL(fileURLWithPath: String(cString: homeCString), isDirectory: true)
        }
        return URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
    }
}

private struct GrokTerminalQueryState {
    var answeredCursorPosition = false
    var answeredXtermVersion = false
    var answeredPrimaryAttributes = false
    var answeredSecondaryAttributes = false
}

private func runGrokUsageProbe(binaryURL: URL, grokHomeURL: URL) -> GrokUsageSnapshot? {
    let fileManager = FileManager.default
    let tempURL = fileManager.temporaryDirectory
        .appendingPathComponent("limit-counter-grok-\(UUID().uuidString)", isDirectory: true)
    try? fileManager.createDirectory(at: tempURL, withIntermediateDirectories: true)
    defer { try? fileManager.removeItem(at: tempURL) }

    var masterFD: Int32 = -1
    var slaveFD: Int32 = -1
    var terminalSize = winsize(ws_row: 24, ws_col: 80, ws_xpixel: 0, ws_ypixel: 0)
    guard openpty(&masterFD, &slaveFD, nil, nil, &terminalSize) == 0 else {
        print("[GrokCLIUsage] openpty failed")
        return nil
    }
    defer {
        if masterFD >= 0 {
            close(masterFD)
        }
    }

    let process = Process()
    process.executableURL = binaryURL
    process.arguments = ["--no-auto-update", "--no-alt-screen"]
    process.currentDirectoryURL = tempURL
    process.environment = ProcessInfo.processInfo.environment.merging([
        "GROK_HOME": grokHomeURL.path,
        "TERM": "xterm-256color",
        "NO_COLOR": "1",
        "GROK_DISABLE_AUTOUPDATER": "1"
    ]) { _, new in new }

    let slaveHandle = FileHandle(fileDescriptor: slaveFD, closeOnDealloc: true)
    process.standardInput = slaveHandle
    process.standardOutput = slaveHandle
    process.standardError = slaveHandle

    do {
        try process.run()
        slaveHandle.closeFile()
    } catch {
        print("[GrokCLIUsage] Failed to launch grok CLI: \(error.localizedDescription)")
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
    var queryState = GrokTerminalQueryState()
    let startedAt = Date()
    let deadline = startedAt.addingTimeInterval(12)
    var sentUsageCommand = false
    var sentFallbackEnter = false

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
        respondToGrokTerminalQueries(in: rawText, masterFD: masterFD, state: &queryState)

        let elapsed = Date().timeIntervalSince(startedAt)
        let cleanText = GrokCLIUsageParser.stripANSI(rawText)

        if !sentUsageCommand, elapsed >= 1.8 {
            writePTYString("/usage\r", to: masterFD)
            sentUsageCommand = true
        }

        if sentUsageCommand,
           !sentFallbackEnter,
           elapsed >= 4.0,
           !hasFullGrokUsageScreen(cleanText) {
            writePTYString("\r", to: masterFD)
            sentFallbackEnter = true
        }

        if hasFullGrokUsageScreen(cleanText) {
            let snapshot = GrokCLIUsageParser.parse(rawText)
            if GrokUsageWindowMapper.quotaWindow(from: snapshot) != nil {
                return snapshot
            }
        }

        usleep(100_000)
    }

    let snapshot = GrokCLIUsageParser.parse(String(decoding: data, as: UTF8.self))
    if GrokUsageWindowMapper.quotaWindow(from: snapshot) != nil {
        return snapshot
    }
    return nil
}

private func hasFullGrokUsageScreen(_ text: String) -> Bool {
    let compact = text
        .lowercased()
        .replacingOccurrences(of: #"[\s\u{00A0}]"#, with: "", options: .regularExpression)
    return compact.contains("weeklylimit:")
        || compact.contains("creditsused:")
        || compact.contains("nextreset:")
}

private func respondToGrokTerminalQueries(
    in rawText: String,
    masterFD: Int32,
    state: inout GrokTerminalQueryState
) {
    if !state.answeredCursorPosition, rawText.contains("\u{001B}[6n") {
        writePTYString("\u{001B}[1;1R", to: masterFD)
        state.answeredCursorPosition = true
    }

    if !state.answeredXtermVersion,
       (rawText.contains("\u{001B}[>q") || rawText.contains("\u{001B}[>0q")) {
        writePTYString("\u{001B}P>|LimitCounter 1.0\u{001B}\\", to: masterFD)
        state.answeredXtermVersion = true
    }

    if !state.answeredSecondaryAttributes, rawText.contains("\u{001B}[>c") {
        writePTYString("\u{001B}[>0;276;0c", to: masterFD)
        state.answeredSecondaryAttributes = true
    }

    if !state.answeredPrimaryAttributes, rawText.contains("\u{001B}[c") {
        writePTYString("\u{001B}[?1;2c", to: masterFD)
        state.answeredPrimaryAttributes = true
    }
}

private func writePTYString(_ string: String, to fd: Int32) {
    let bytes = Array(string.utf8)
    bytes.withUnsafeBufferPointer { pointer in
        guard let baseAddress = pointer.baseAddress else { return }
        _ = write(fd, baseAddress, pointer.count)
    }
}
#endif

nonisolated enum GrokLocalBillingLogReader {
    private static let maxTailBytes: UInt64 = 1_000_000

    static func latestSnapshot(rootURL: URL, now: Date = Date()) -> GrokUsageSnapshot? {
        let logURL = rootURL.appendingPathComponent("logs/unified.jsonl")
        guard let text = readTailText(from: logURL) else {
            return nil
        }

        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        let decoder = JSONDecoder()

        for line in lines.reversed() {
            guard let data = String(line).data(using: .utf8),
                  let entry = try? decoder.decode(BillingLogEntry.self, from: data),
                  entry.messageContainsBillingConfig,
                  let snapshot = snapshot(from: entry, now: now) else {
                continue
            }
            return snapshot
        }

        return nil
    }

    private static func readTailText(from url: URL) -> String? {
        guard FileManager.default.fileExists(atPath: url.path),
              let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber,
              let handle = try? FileHandle(forReadingFrom: url) else {
            return nil
        }
        defer { try? handle.close() }

        let fileSize = size.uint64Value
        let offset = fileSize > maxTailBytes ? fileSize - maxTailBytes : 0
        do {
            try handle.seek(toOffset: offset)
            let data = handle.readDataToEndOfFile()
            guard !data.isEmpty else { return nil }
            var text = String(decoding: data, as: UTF8.self)
            if offset > 0, let firstNewline = text.firstIndex(of: "\n") {
                text = String(text[text.index(after: firstNewline)...])
            }
            return text
        } catch {
            return nil
        }
    }

    private static func snapshot(from entry: BillingLogEntry, now: Date) -> GrokUsageSnapshot? {
        guard let config = entry.ctx?.config,
              let used = config.creditUsagePercent else {
            return nil
        }

        let periodType = config.currentPeriod?.type?.uppercased() ?? ""
        let periodStart = firstNonEmpty(config.currentPeriod?.start, config.billingPeriodStart)
        let periodEnd = firstNonEmpty(config.currentPeriod?.end, config.billingPeriodEnd)
        let periodStartDate = periodStart.flatMap(parseISODate)
        let periodEndDate = periodEnd.flatMap(parseISODate)
        let isWeekly = periodType.contains("WEEKLY")
            || periodDurationSeconds(start: periodStartDate, end: periodEndDate).map { $0 <= 8 * 24 * 60 * 60 } == true
        let refreshedAtDate = entry.ts.flatMap(parseISODate) ?? now
        let refreshedAt = isoString(refreshedAtDate)
        let resetAt = periodEndDate.map(isoString) ?? periodEnd
        let windowSeconds = periodDurationSeconds(start: periodStartDate, end: periodEndDate)

        if isWeekly {
            return GrokUsageSnapshot(
                usageKind: "weekly_limit",
                weeklyLimitUsedPercent: clampedPercent(used),
                weeklyLimitUsedDisplay: "\(compactPercent(used))%",
                resetAt: resetAt,
                weeklyResetAt: resetAt,
                nextResetAt: resetAt,
                limitWindowSeconds: windowSeconds ?? 7 * 24 * 60 * 60,
                planLabel: entry.ctx?.subscriptionTier,
                refreshedAt: refreshedAt,
                confidence: "observed"
            )
        }

        return GrokUsageSnapshot(
            usageKind: "subscription_credits",
            creditsUsedPercent: clampedPercent(used),
            creditsUsedDisplay: "\(compactPercent(used))%",
            resetAt: resetAt,
            limitWindowSeconds: windowSeconds ?? 30 * 24 * 60 * 60,
            planLabel: entry.ctx?.subscriptionTier,
            refreshedAt: refreshedAt,
            confidence: "observed"
        )
    }

    private static func periodDurationSeconds(start: Date?, end: Date?) -> Double? {
        guard let start, let end, end > start else { return nil }
        return end.timeIntervalSince(start)
    }

    private static func parseISODate(_ value: String) -> Date? {
        let withFractional = ISO8601DateFormatter()
        withFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFractional.date(from: value) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: value)
    }

    private static func isoString(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private static func compactPercent(_ value: Double) -> String {
        let rounded = value.rounded()
        if abs(value - rounded) < 0.005 {
            return String(Int(rounded))
        }
        return String(format: "%.1f", value)
    }

    private static func clampedPercent(_ value: Double) -> Double {
        min(max(value, 0), 100)
    }

    private static func firstNonEmpty(_ values: String?...) -> String? {
        for value in values {
            guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !trimmed.isEmpty else {
                continue
            }
            return trimmed
        }
        return nil
    }

    private struct BillingLogEntry: Decodable {
        let ts: String?
        let msg: String?
        let ctx: BillingContext?

        var messageContainsBillingConfig: Bool {
            msg?.localizedCaseInsensitiveContains("billing: fetched credits config") == true
        }
    }

    private struct BillingContext: Decodable {
        let config: BillingConfig?
        let subscriptionTier: String?
    }

    private struct BillingConfig: Decodable {
        let creditUsagePercent: Double?
        let currentPeriod: BillingPeriod?
        let billingPeriodStart: String?
        let billingPeriodEnd: String?

        private enum CodingKeys: String, CodingKey {
            case creditUsagePercent
            case currentPeriod
            case billingPeriodStart
            case billingPeriodEnd
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            creditUsagePercent = Self.decodeFlexibleDouble(container, .creditUsagePercent)
            currentPeriod = try container.decodeIfPresent(BillingPeriod.self, forKey: .currentPeriod)
            billingPeriodStart = try container.decodeIfPresent(String.self, forKey: .billingPeriodStart)
            billingPeriodEnd = try container.decodeIfPresent(String.self, forKey: .billingPeriodEnd)
        }

        private static func decodeFlexibleDouble(
            _ container: KeyedDecodingContainer<CodingKeys>,
            _ key: CodingKeys
        ) -> Double? {
            if let value = try? container.decodeIfPresent(Double.self, forKey: key) {
                return value
            }
            guard let string = try? container.decodeIfPresent(String.self, forKey: key) else {
                return nil
            }
            return Double(string.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    private struct BillingPeriod: Decodable {
        let type: String?
        let start: String?
        let end: String?
    }
}

/// Surfaces xAI Grok usage by running the local `grok` CLI against a
/// user-granted `~/.grok` folder and parsing the interactive `/usage` screen.
/// TaskWraith remains an optional activity/bridge fallback, but the weekly
/// quota meter no longer depends on another app writing `grok-usage-snapshot`.
public struct GrokProviderClient: ProviderClient {
    public let providerID: ProviderID = .grok

    public init() {}

    public func fetchSnapshot(credentials: ProviderCredential?) async throws -> QuotaSnapshot {
        let agbenchData = readTaskWraithGrokData()
        var windows: [QuotaWindow] = []
        var planName = "SuperGrok"

        if let cliSnapshot = await GrokCLIUsageProbe.fetchSnapshot(credentials: credentials),
           let cliWindow = GrokUsageWindowMapper.quotaWindow(from: cliSnapshot) {
            planName = cliSnapshot.resolvedPlanName
            windows.append(cliWindow)
        } else if let bridgeSnapshot = agbenchData.snapshot,
                  let bridgeWindow = GrokUsageWindowMapper.quotaWindow(from: bridgeSnapshot) {
            planName = bridgeSnapshot.resolvedPlanName
            windows.append(bridgeWindow)
        }

        if windows.isEmpty && agbenchData.events.isEmpty {
            throw ProviderFetchError.notConfigured
        }

        if windows.isEmpty {
            windows.append(
                QuotaWindow(
                    label: "Weekly",
                    windowKind: .weekly,
                    used: 0,
                    total: 100,
                    resetDate: nil,
                    unit: "%",
                    subtitle: "Import ~/.grok to read Grok weekly usage directly"
                )
            )
        }

        return QuotaSnapshot(
            providerID: .grok,
            displayName: "Grok",
            planName: planName,
            windows: windows,
            stats: [],
            balances: [],
            signals: [],
            events: agbenchData.events.sorted { $0.timestamp > $1.timestamp },
            fetchState: .success,
            fetchedAt: Date()
        )
    }

    private func readTaskWraithGrokData() -> (events: [UsageEvent], snapshot: GrokUsageSnapshot?) {
        guard let scoped = AGBenchBookmarkStore.startAccess() else {
            return ([], nil)
        }
        defer { scoped.stop() }

        let events = AGBenchUsageReader.events(forProviderKey: "grok", rootURL: scoped.url)
        let snapshot = readGrokSnapshot(at: grokSnapshotURL(rootURL: scoped.url))
        return (events, snapshot)
    }

    private func grokSnapshotURL(rootURL: URL) -> URL {
        if rootURL.lastPathComponent == "grok-usage-snapshot.json" {
            return rootURL
        }
        return rootURL.appendingPathComponent("grok-usage-snapshot.json")
    }

    private func readGrokSnapshot(at url: URL) -> GrokUsageSnapshot? {
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url) else {
            return nil
        }
        return try? JSONDecoder().decode(GrokUsageSnapshot.self, from: data)
    }
}

/// Every provider implements this protocol.
/// Receives credentials from KeychainService, returns a normalized QuotaSnapshot.
/// Never writes to storage directly — SyncCoordinator does that.
public protocol ProviderClient {
    var providerID: ProviderID { get }
    func fetchSnapshot(credentials: ProviderCredential?) async throws -> QuotaSnapshot
}

/// Providers that distinguish manual vs timer-driven refreshes. Callers pass
/// `userInitiated` so the client can apply its own cadence (for example
/// Antigravity's looping quota poll) while still serving cache between polls.
public protocol UserInitiatedProviderClient: ProviderClient {
    func fetchSnapshot(
        credentials: ProviderCredential?,
        userInitiated: Bool
    ) async throws -> QuotaSnapshot
}

// MARK: - Heatmap event preservation

/// Content-based key used to dedupe `UsageEvent`s across fetches.
///
/// Crucial detail #1: `UsageEvent.id` is a fresh `UUID()` on every
/// construction, with no provider passing an explicit id. So an
/// id-based dedupe would treat the *same underlying message* as
/// distinct events between (a) what we stored on the previous fetch
/// and (b) what the current fetch re-scanned — leading to silent
/// double-counting on the heatmap that grows on every refresh.
///
/// Crucial detail #2: `tokens` is part of the key for `.message` and
/// `.activity` events, but NOT for `.bucket` events. The two event
/// types have opposite semantics:
///
///   - `.message`: per-API-call delta. Stable across fetches. Helps
///     distinguish two legitimately distinct calls that happen to
///     fall on the same second-resolution timestamp (which can occur
///     during a busy turn). Excluding tokens would silently collapse
///     those into one event.
///
///   - `.bucket`: cumulative daily total (e.g. Gemini's daily-usage
///     endpoint). Grows on every refresh — 5M, 6M, 7M throughout the
///     day. If tokens were in the key each refresh would mint a NEW
///     event and the heatmap's "tokens today" would balloon over the
///     course of a day. Excluding tokens means each daily bucket has
///     a stable key — the fresh event simply replaces the historical
///     one in the merge.
///
/// `.activity` events typically have `tokens == nil` so the choice
/// doesn't matter there; tokens is included only for consistency with
/// `.message`.
private nonisolated struct UsageEventContentKey: Hashable {
    let timestamp: Date
    let type: UsageEvent.EventType
    let model: String?
    let tokens: Double?

    init(_ event: UsageEvent) {
        self.timestamp = event.timestamp
        self.type = event.type
        self.model = event.model
        // See doc comment above for why bucket events drop tokens.
        self.tokens = (event.type == .bucket) ? nil : event.tokens
    }
}

/// Preserves heatmap events across fetches when a provider's data
/// source has a time-window filter that would otherwise drop them.
///
/// Providers like Claude and Kimi scan local transcript files filtered
/// by modification date (typically a 30-day window), so the moment a
/// project goes untouched its events disappear from subsequent
/// snapshots even though they'd still fall within the heatmap's
/// display window. Devin reads only a single `lastSessionDate`
/// pseudo-event that gets overwritten on the next session boundary —
/// same problem, different cause.
///
/// This helper merges the events from the previously-persisted
/// snapshot for the same provider into the freshly-built snapshot,
/// deduped by content key. Trimmed to `lookbackDays` so the array
/// stays bounded — the heatmap displays 30 days but we keep 60 to
/// absorb DST edges and provide buffer if the heatmap window ever
/// grows.
///
/// Everything else on the snapshot (windows, stats, fetchState,
/// fetchedAt, planName) passes through unchanged so the card keeps
/// reflecting the latest live data.
private func enrichEventsWithHistory(
    _ snapshot: QuotaSnapshot,
    lookbackDays: Int = 60
) -> QuotaSnapshot {
    let horizon = Date().addingTimeInterval(-Double(lookbackDays) * 24 * 60 * 60)
    guard let previous = QuotaSnapshotStore.shared.loadSnapshots()
        .first(where: { $0.providerID == snapshot.providerID }) else {
        return snapshot
    }

    var seen = Set(snapshot.events.map(UsageEventContentKey.init))
    var combined = snapshot.events
    for event in previous.events where event.timestamp >= horizon {
        if seen.insert(UsageEventContentKey(event)).inserted {
            combined.append(event)
        }
    }

    guard combined.count != snapshot.events.count else {
        return snapshot
    }

    return QuotaSnapshot(
        id: snapshot.id,
        providerID: snapshot.providerID,
        displayName: snapshot.displayName,
        planName: snapshot.planName,
        windows: snapshot.windows,
        stats: snapshot.stats,
        balances: snapshot.balances,
        signals: snapshot.signals,
        events: combined,
        fetchState: snapshot.fetchState,
        fetchedAt: snapshot.fetchedAt
    )
}

/// Opaque credential bag — actual shape varies per provider.
/// These values are entered or imported explicitly by the user and stored in
/// Keychain under providerID.rawValue. The app should not inspect browser
/// cookies or third-party app storage on the user's behalf.
public struct ProviderCredential: Codable {
    public let accessToken: String?
    public let accountIdentifier: String?
    public let customEndpoint: String?
    public let extraFields: [String: String]?
    public let bookmarkData: Data?

    public var normalizedAccessToken: String? {
        accessToken?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var normalizedAccountIdentifier: String? {
        accountIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public init(
        accessToken: String? = nil,
        accountIdentifier: String? = nil,
        customEndpoint: String? = nil,
        extraFields: [String: String]? = nil,
        bookmarkData: Data? = nil
    ) {
        self.accessToken = accessToken
        self.accountIdentifier = accountIdentifier
        self.customEndpoint = customEndpoint
        self.extraFields = extraFields
        self.bookmarkData = bookmarkData
    }

    private enum CodingKeys: String, CodingKey {
        case accessToken
        case accountIdentifier
        case customEndpoint
        case extraFields
        case bearerToken
        case bookmarkData
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        accessToken = try container.decodeIfPresent(String.self, forKey: .accessToken)
            ?? container.decodeIfPresent(String.self, forKey: .bearerToken)
        accountIdentifier = try container.decodeIfPresent(String.self, forKey: .accountIdentifier)
        customEndpoint = try container.decodeIfPresent(String.self, forKey: .customEndpoint)
        extraFields = try container.decodeIfPresent([String: String].self, forKey: .extraFields)
        bookmarkData = try container.decodeIfPresent(Data.self, forKey: .bookmarkData)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(accessToken, forKey: .accessToken)
        try container.encodeIfPresent(accountIdentifier, forKey: .accountIdentifier)
        try container.encodeIfPresent(customEndpoint, forKey: .customEndpoint)
        try container.encodeIfPresent(extraFields, forKey: .extraFields)
        try container.encodeIfPresent(bookmarkData, forKey: .bookmarkData)
    }

    public var normalizedCustomEndpoint: String? {
        Self.normalized(customEndpoint)
    }

    public var isEmpty: Bool {
        normalizedAccessToken == nil
            && normalizedAccountIdentifier == nil
            && normalizedCustomEndpoint == nil
            && (extraFields?.isEmpty ?? true)
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

// MARK: - Mock Client

/// Returns static mock data. Used in Phase 1 and for Xcode Previews.
public struct MockProviderClient: ProviderClient {
    public let providerID: ProviderID
    private let snapshot: QuotaSnapshot

    public init(snapshot: QuotaSnapshot) {
        self.providerID = snapshot.providerID
        self.snapshot = snapshot
    }

    public func fetchSnapshot(credentials: ProviderCredential?) async throws -> QuotaSnapshot {
        // Simulate a brief network delay for realism
        try await Task.sleep(for: .milliseconds(400))
        return snapshot
    }
}

// MARK: - OpenAI Usage Client

/// Real adapter for OpenAI's official organization usage and project rate limit APIs.
/// Requires an OpenAI admin API key plus a project ID entered by the user.
public struct OpenAIUsageProviderClient: ProviderClient {
    public let providerID: ProviderID = .openaiAPI

    private let session: URLSession
    private let decoder = JSONDecoder()
    private let utcCalendar: Calendar

    public init(session: URLSession = .shared) {
        self.session = session
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        self.utcCalendar = calendar
    }

    public func fetchSnapshot(credentials: ProviderCredential?) async throws -> QuotaSnapshot {
        guard let credentials else { throw ProviderFetchError.notConfigured }
        guard let adminKey = credentials.normalizedAccessToken else { throw ProviderFetchError.notConfigured }
        guard let projectID = credentials.normalizedAccountIdentifier else {
            throw ProviderFetchError.notConfigured
        }

        let baseURL = try resolvedBaseURL(customEndpoint: credentials.normalizedCustomEndpoint)
        let now = Date()
        let startOfDay = utcCalendar.startOfDay(for: now)
        let startOfMinute = utcCalendar.date(
            from: utcCalendar.dateComponents([.year, .month, .day, .hour, .minute], from: now)
        ) ?? now
        let thirtyDayStart = utcCalendar.date(byAdding: .day, value: -29, to: startOfDay) ?? startOfDay

        async let rateLimits = fetchRateLimits(
            baseURL: baseURL,
            adminKey: adminKey,
            projectID: projectID
        )

        async let dailyUsagePage = fetchCompletionsUsage(
            baseURL: baseURL,
            adminKey: adminKey,
            startTime: startOfDay,
            endTime: now,
            bucketWidth: "1d",
            limit: 1,
            projectID: projectID
        )

        async let minuteUsagePage = fetchCompletionsUsage(
            baseURL: baseURL,
            adminKey: adminKey,
            startTime: startOfMinute,
            endTime: now,
            bucketWidth: "1m",
            limit: 1,
            projectID: projectID
        )

        async let analyticsBuckets = fetchAnalyticsBuckets(
            baseURL: baseURL,
            adminKey: adminKey,
            projectID: projectID,
            startTime: thirtyDayStart,
            endTime: now,
            now: now
        )

        let (fetchedRateLimits, fetchedDailyUsagePage, fetchedMinuteUsagePage) = try await (
            rateLimits,
            dailyUsagePage,
            minuteUsagePage
        )
        let fetchedAnalyticsBuckets = await analyticsBuckets

        guard !fetchedRateLimits.data.isEmpty else {
            throw ProviderFetchError.parsingError("No project rate limits were returned for this OpenAI project.")
        }

        let dailyUsageByModel = usageByModel(from: fetchedDailyUsagePage.data)
        let minuteUsageByModel = usageByModel(from: fetchedMinuteUsagePage.data)

        let selectedRateLimit = chooseDisplayRateLimit(
            from: fetchedRateLimits.data,
            dailyUsageByModel: dailyUsageByModel,
            minuteUsageByModel: minuteUsageByModel
        )

        let dailyUsage = dailyUsageByModel[selectedRateLimit.model] ?? .zero
        let minuteUsage = minuteUsageByModel[selectedRateLimit.model] ?? .zero

        let nextUTCDay = utcCalendar.date(byAdding: .day, value: 1, to: startOfDay)
        let nextUTCMinute = utcCalendar.date(byAdding: .minute, value: 1, to: startOfMinute)
        let projectSubtitle = "Project \(shortProjectID(projectID))"
        var windows: [QuotaWindow] = []
        let stats = analyticsStats(from: fetchedAnalyticsBuckets, now: now)
        let events = analyticsEvents(from: fetchedAnalyticsBuckets)

        if let dailyLimit = selectedRateLimit.maxRequestsPer1Day {
            windows.append(
                QuotaWindow(
                    label: "Requests / Day",
                    windowKind: .daily,
                    used: dailyUsage.requests,
                    total: dailyLimit,
                    resetDate: nextUTCDay,
                    unit: "req",
                    subtitle: "\(displayModelName(selectedRateLimit.model)) • \(projectSubtitle)"
                )
            )
        }

        windows.append(
            QuotaWindow(
                label: "Requests / Min",
                windowKind: .custom,
                used: minuteUsage.requests,
                total: selectedRateLimit.maxRequestsPer1Minute,
                resetDate: nextUTCMinute,
                unit: "req",
                subtitle: "\(displayModelName(selectedRateLimit.model)) • current UTC minute"
            )
        )

        windows.append(
            QuotaWindow(
                label: "Tokens / Min",
                windowKind: .custom,
                used: minuteUsage.tokens,
                total: selectedRateLimit.maxTokensPer1Minute,
                resetDate: nextUTCMinute,
                unit: "tok",
                subtitle: "\(displayModelName(selectedRateLimit.model)) • current UTC minute"
            )
        )

        let sortedEvents = events.sorted { $0.timestamp > $1.timestamp }
        let cappedEvents = Array(sortedEvents.prefix(1000))

        return QuotaSnapshot(
            providerID: .openaiAPI,
            displayName: "OpenAI API",
            planName: displayModelName(selectedRateLimit.model),
            windows: windows,
            stats: stats,
            events: cappedEvents,
            analyticsBuckets: fetchedAnalyticsBuckets,
            fetchState: .success,
            fetchedAt: now
        )
    }

    private func fetchRateLimits(
        baseURL: URL,
        adminKey: String,
        projectID: String
    ) async throws -> OpenAIRateLimitListResponse {
        let requestURL = makeURL(
            baseURL: baseURL,
            pathComponents: ["organization", "projects", projectID, "rate_limits"],
            queryItems: [URLQueryItem(name: "limit", value: "100")]
        )
        let data = try await fetchData(from: requestURL, bearerToken: adminKey)

        do {
            return try decoder.decode(OpenAIRateLimitListResponse.self, from: data)
        } catch {
            throw ProviderFetchError.parsingError("Unable to decode OpenAI rate limits response.")
        }
    }

    private func fetchCompletionsUsage(
        baseURL: URL,
        adminKey: String,
        startTime: Date,
        endTime: Date,
        bucketWidth: String,
        limit: Int,
        projectID: String,
        page: String? = nil
    ) async throws -> OpenAIUsageBucketPage {
        var queryItems = [
            URLQueryItem(name: "start_time", value: String(Int(startTime.timeIntervalSince1970))),
            URLQueryItem(name: "end_time", value: String(Int(endTime.timeIntervalSince1970))),
            URLQueryItem(name: "bucket_width", value: bucketWidth),
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "project_ids", value: projectID),
            URLQueryItem(name: "group_by", value: "model")
        ]
        if let page {
            queryItems.append(URLQueryItem(name: "page", value: page))
        }
        let requestURL = makeURL(
            baseURL: baseURL,
            pathComponents: ["organization", "usage", "completions"],
            queryItems: queryItems
        )
        let data = try await fetchData(from: requestURL, bearerToken: adminKey)

        do {
            return try decoder.decode(OpenAIUsageBucketPage.self, from: data)
        } catch {
            throw ProviderFetchError.parsingError("Unable to decode OpenAI completions usage response.")
        }
    }

    private func fetchAllCompletionsUsageBuckets(
        baseURL: URL,
        adminKey: String,
        startTime: Date,
        endTime: Date,
        bucketWidth: String,
        limit: Int,
        projectID: String
    ) async throws -> [OpenAIUsageBucket] {
        var allBuckets: [OpenAIUsageBucket] = []
        var nextPage: String?

        repeat {
            let page = try await fetchCompletionsUsage(
                baseURL: baseURL,
                adminKey: adminKey,
                startTime: startTime,
                endTime: endTime,
                bucketWidth: bucketWidth,
                limit: limit,
                projectID: projectID,
                page: nextPage
            )
            allBuckets.append(contentsOf: page.data)
            nextPage = page.hasMore ? page.nextPage : nil
        } while nextPage != nil

        return allBuckets
    }

    private func fetchCosts(
        baseURL: URL,
        adminKey: String,
        startTime: Date,
        endTime: Date,
        bucketWidth: String,
        limit: Int,
        projectID: String,
        page: String? = nil
    ) async throws -> OpenAICostBucketPage {
        var queryItems = [
            URLQueryItem(name: "start_time", value: String(Int(startTime.timeIntervalSince1970))),
            URLQueryItem(name: "end_time", value: String(Int(endTime.timeIntervalSince1970))),
            URLQueryItem(name: "bucket_width", value: bucketWidth),
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "project_ids", value: projectID)
        ]
        if let page {
            queryItems.append(URLQueryItem(name: "page", value: page))
        }

        let requestURL = makeURL(
            baseURL: baseURL,
            pathComponents: ["organization", "costs"],
            queryItems: queryItems
        )
        let data = try await fetchData(from: requestURL, bearerToken: adminKey)

        do {
            return try decoder.decode(OpenAICostBucketPage.self, from: data)
        } catch {
            throw ProviderFetchError.parsingError("Unable to decode OpenAI costs response.")
        }
    }

    private func fetchAllCostBuckets(
        baseURL: URL,
        adminKey: String,
        startTime: Date,
        endTime: Date,
        bucketWidth: String,
        limit: Int,
        projectID: String
    ) async throws -> [OpenAICostBucket] {
        var allBuckets: [OpenAICostBucket] = []
        var nextPage: String?

        repeat {
            let page = try await fetchCosts(
                baseURL: baseURL,
                adminKey: adminKey,
                startTime: startTime,
                endTime: endTime,
                bucketWidth: bucketWidth,
                limit: limit,
                projectID: projectID,
                page: nextPage
            )
            allBuckets.append(contentsOf: page.data)
            nextPage = page.hasMore ? page.nextPage : nil
        } while nextPage != nil

        return allBuckets
    }

    private func fetchAnalyticsBuckets(
        baseURL: URL,
        adminKey: String,
        projectID: String,
        startTime: Date,
        endTime: Date,
        now: Date
    ) async -> [UsageAnalyticsBucket] {
        async let usageResult: Result<[OpenAIUsageBucket], Error> = {
            do {
                let buckets = try await fetchAllCompletionsUsageBuckets(
                    baseURL: baseURL,
                    adminKey: adminKey,
                    startTime: startTime,
                    endTime: endTime,
                    bucketWidth: "1d",
                    limit: 30,
                    projectID: projectID
                )
                return .success(buckets)
            } catch {
                return .failure(error)
            }
        }()

        async let costResult: Result<[OpenAICostBucket], Error> = {
            do {
                let buckets = try await fetchAllCostBuckets(
                    baseURL: baseURL,
                    adminKey: adminKey,
                    startTime: startTime,
                    endTime: endTime,
                    bucketWidth: "1d",
                    limit: 30,
                    projectID: projectID
                )
                return .success(buckets)
            } catch {
                return .failure(error)
            }
        }()

        let (usageOutcome, costOutcome) = await (usageResult, costResult)

        let usageBuckets: [OpenAIUsageBucket]
        switch usageOutcome {
        case .success(let buckets):
            usageBuckets = buckets
        case .failure(let error):
            print("[OpenAIUsageProvider] Usage analytics fetch skipped: \(error.localizedDescription)")
            usageBuckets = []
        }

        let costBuckets: [OpenAICostBucket]
        switch costOutcome {
        case .success(let buckets):
            costBuckets = buckets
        case .failure(let error):
            print("[OpenAIUsageProvider] Cost analytics fetch skipped: \(error.localizedDescription)")
            costBuckets = []
        }

        return analyticsBuckets(
            usageBuckets: usageBuckets,
            costBuckets: costBuckets,
            fallbackProjectID: projectID,
            now: now
        )
    }

    private func fetchData(from url: URL, bearerToken: String) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let data: Data
        let response: URLResponse

        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw ProviderFetchError.networkError(underlying: error)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ProviderFetchError.unknown
        }

        switch httpResponse.statusCode {
        case 200..<300:
            return data
        case 401, 403:
            throw ProviderFetchError.invalidCredential
        case 429:
            throw ProviderFetchError.rateLimited
        default:
            let message = (try? decoder.decode(OpenAIErrorEnvelope.self, from: data).error.message)
                ?? HTTPURLResponse.localizedString(forStatusCode: httpResponse.statusCode)
            throw ProviderFetchError.parsingError(message)
        }
    }

    private func resolvedBaseURL(customEndpoint: String?) throws -> URL {
        let rawValue = customEndpoint ?? "https://api.openai.com/v1"
        guard var url = URL(string: rawValue) else {
            throw ProviderFetchError.parsingError("Custom OpenAI endpoint is not a valid URL.")
        }
        if url.path.isEmpty || url.path == "/" {
            url.appendPathComponent("v1")
        }
        return url
    }

    private func makeURL(
        baseURL: URL,
        pathComponents: [String],
        queryItems: [URLQueryItem]
    ) -> URL {
        var url = baseURL
        for component in pathComponents {
            url.appendPathComponent(component)
        }

        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.queryItems = queryItems
        return components?.url ?? url
    }

    private func usageByModel(from buckets: [OpenAIUsageBucket]) -> [String: OpenAIUsageTotals] {
        var aggregated: [String: OpenAIUsageTotals] = [:]

        for bucket in buckets {
            for result in bucket.results {
                let model = result.model ?? "All models"
                var current = aggregated[model] ?? .zero
                current.requests += result.numModelRequests
                current.tokens += result.totalTokens
                aggregated[model] = current
            }
        }

        return aggregated
    }

    private func analyticsBuckets(
        usageBuckets: [OpenAIUsageBucket],
        costBuckets: [OpenAICostBucket],
        fallbackProjectID: String,
        now: Date
    ) -> [UsageAnalyticsBucket] {
        var buckets: [UsageAnalyticsBucket] = []

        for bucket in usageBuckets {
            let startDate = Date(timeIntervalSince1970: bucket.startTime)
            let endDate = Date(timeIntervalSince1970: bucket.endTime)

            for result in bucket.results {
                let model = normalizedModelName(result.model)
                let projectID = result.projectID ?? fallbackProjectID
                let cachedTokens = result.inputCachedTokens ?? 0
                let uncachedInput = max(0, result.inputTokens - cachedTokens)
                let analyticsBucket = UsageAnalyticsBucket(
                    startDate: startDate,
                    endDate: endDate,
                    model: model,
                    projectID: projectID,
                    inputTokens: uncachedInput,
                    outputTokens: result.outputTokens + (result.outputAudioTokens ?? 0),
                    cachedInputTokens: cachedTokens + (result.inputAudioTokens ?? 0),
                    requests: result.numModelRequests,
                    costUSD: nil,
                    source: .officialAPI
                )
                if analyticsBucket.hasUsage {
                    buckets.append(analyticsBucket)
                }
            }
        }

        for bucket in costBuckets {
            let startDate = Date(timeIntervalSince1970: bucket.startTime)
            let endDate = Date(timeIntervalSince1970: bucket.endTime)
            let totalCost = bucket.results.reduce(0.0) { $0 + $1.amount.value }
            guard totalCost > 0 else { continue }

            buckets.append(
                UsageAnalyticsBucket(
                    startDate: startDate,
                    endDate: endDate,
                    model: nil,
                    projectID: fallbackProjectID,
                    costUSD: totalCost,
                    source: .officialAPI,
                    note: "Cost"
                )
            )
        }

        return buckets
            .filter { $0.startDate <= now }
            .sorted {
                if $0.startDate == $1.startDate {
                    return ($0.model ?? $0.note ?? "") < ($1.model ?? $1.note ?? "")
                }
                return $0.startDate > $1.startDate
            }
    }

    private func analyticsStats(from buckets: [UsageAnalyticsBucket], now: Date) -> [QuotaStat] {
        guard !buckets.isEmpty else { return [] }

        let dayStart = utcCalendar.startOfDay(for: now)
        let sevenDayStart = utcCalendar.date(byAdding: .day, value: -6, to: dayStart) ?? dayStart
        let thirtyDayStart = utcCalendar.date(byAdding: .day, value: -29, to: dayStart) ?? dayStart

        let today = analyticsTotals(from: buckets, since: dayStart)
        let sevenDay = analyticsTotals(from: buckets, since: sevenDayStart)
        let thirtyDay = analyticsTotals(from: buckets, since: thirtyDayStart)

        var stats: [QuotaStat] = [
            QuotaStat(label: "Today Tokens", value: today.tokens, unit: "tok", subtitle: "Official usage API"),
            QuotaStat(label: "7D Tokens", value: sevenDay.tokens, unit: "tok", subtitle: "Official usage API"),
            QuotaStat(label: "30D Tokens", value: thirtyDay.tokens, unit: "tok", subtitle: "Official usage API"),
            QuotaStat(label: "Today Requests", value: today.requests, unit: "req", subtitle: "Official usage API"),
            QuotaStat(label: "7D Requests", value: sevenDay.requests, unit: "req", subtitle: "Official usage API")
        ]

        if thirtyDay.cost > 0 {
            stats.append(QuotaStat(label: "Today Cost", value: today.cost, unit: "$", subtitle: "Official costs API"))
            stats.append(QuotaStat(label: "7D Cost", value: sevenDay.cost, unit: "$", subtitle: "Official costs API"))
            stats.append(QuotaStat(label: "30D Cost", value: thirtyDay.cost, unit: "$", subtitle: "Official costs API"))
        }

        return stats
    }

    private func analyticsEvents(from buckets: [UsageAnalyticsBucket]) -> [UsageEvent] {
        let grouped = Dictionary(grouping: buckets.filter { $0.totalTokens > 0 }, by: { $0.startDate })

        return grouped.map { date, dayBuckets in
            let tokens = dayBuckets.reduce(0) { $0 + $1.totalTokens }
            let model = topModelName(in: dayBuckets)
            return UsageEvent(timestamp: date, tokens: tokens, model: model, type: .bucket)
        }
        .sorted { $0.timestamp > $1.timestamp }
        .prefix(1_000)
        .map { $0 }
    }

    private func analyticsTotals(from buckets: [UsageAnalyticsBucket], since startDate: Date) -> OpenAIAnalyticsTotals {
        var totals = OpenAIAnalyticsTotals()
        for bucket in buckets where bucket.startDate >= startDate {
            totals.tokens += bucket.totalTokens
            totals.requests += bucket.requests
            totals.cost += bucket.costUSD ?? 0
        }
        return totals
    }

    private func topModelName(in buckets: [UsageAnalyticsBucket]) -> String? {
        let totalsByModel = buckets.reduce(into: [String: Double]()) { partial, bucket in
            guard let model = bucket.model else { return }
            partial[model, default: 0] += bucket.totalTokens
        }
        return totalsByModel.max { lhs, rhs in
            if lhs.value == rhs.value { return lhs.key > rhs.key }
            return lhs.value < rhs.value
        }?.key
    }

    private func chooseDisplayRateLimit(
        from rateLimits: [OpenAIRateLimit],
        dailyUsageByModel: [String: OpenAIUsageTotals],
        minuteUsageByModel: [String: OpenAIUsageTotals]
    ) -> OpenAIRateLimit {
        rateLimits.max { lhs, rhs in
            let leftScore = utilizationScore(
                for: lhs,
                dailyUsage: dailyUsageByModel[lhs.model] ?? .zero,
                minuteUsage: minuteUsageByModel[lhs.model] ?? .zero
            )
            let rightScore = utilizationScore(
                for: rhs,
                dailyUsage: dailyUsageByModel[rhs.model] ?? .zero,
                minuteUsage: minuteUsageByModel[rhs.model] ?? .zero
            )

            if leftScore == rightScore {
                let leftActivity = activityScore(
                    dailyUsage: dailyUsageByModel[lhs.model] ?? .zero,
                    minuteUsage: minuteUsageByModel[lhs.model] ?? .zero
                )
                let rightActivity = activityScore(
                    dailyUsage: dailyUsageByModel[rhs.model] ?? .zero,
                    minuteUsage: minuteUsageByModel[rhs.model] ?? .zero
                )

                if leftActivity == rightActivity {
                    return lhs.model < rhs.model
                }

                return leftActivity < rightActivity
            }

            return leftScore < rightScore
        } ?? rateLimits[0]
    }

    private func utilizationScore(
        for rateLimit: OpenAIRateLimit,
        dailyUsage: OpenAIUsageTotals,
        minuteUsage: OpenAIUsageTotals
    ) -> Double {
        var score = 0.0

        if let dailyLimit = rateLimit.maxRequestsPer1Day, dailyLimit > 0 {
            score = max(score, dailyUsage.requests / dailyLimit)
        }

        if rateLimit.maxRequestsPer1Minute > 0 {
            score = max(score, minuteUsage.requests / rateLimit.maxRequestsPer1Minute)
        }

        if rateLimit.maxTokensPer1Minute > 0 {
            score = max(score, minuteUsage.tokens / rateLimit.maxTokensPer1Minute)
        }

        return score
    }

    private func activityScore(
        dailyUsage: OpenAIUsageTotals,
        minuteUsage: OpenAIUsageTotals
    ) -> Double {
        (dailyUsage.requests * 10_000) + (minuteUsage.requests * 100) + minuteUsage.tokens
    }

    private func displayModelName(_ model: String) -> String {
        model
    }

    private func normalizedModelName(_ model: String?) -> String? {
        guard let model = model?.trimmingCharacters(in: .whitespacesAndNewlines),
              !model.isEmpty else {
            return nil
        }
        return model
    }

    private func shortProjectID(_ projectID: String) -> String {
        guard projectID.count > 18 else { return projectID }
        return "\(projectID.prefix(10))…\(projectID.suffix(4))"
    }
}

private struct OpenAIErrorEnvelope: Decodable {
    let error: OpenAIErrorDetail
}

private struct OpenAIErrorDetail: Decodable {
    let message: String
}

private struct OpenAIUsageBucketPage: Decodable {
    let object: String
    let data: [OpenAIUsageBucket]
    let hasMore: Bool
    let nextPage: String?

    private enum CodingKeys: String, CodingKey {
        case object
        case data
        case hasMore = "has_more"
        case nextPage = "next_page"
    }
}

private struct OpenAIUsageBucket: Decodable {
    let object: String
    let startTime: TimeInterval
    let endTime: TimeInterval
    let results: [OpenAICompletionsUsageResult]

    private enum CodingKeys: String, CodingKey {
        case object
        case startTime = "start_time"
        case endTime = "end_time"
        case results
    }
}

private struct OpenAICompletionsUsageResult: Decodable {
    let inputTokens: Double
    let outputTokens: Double
    let inputCachedTokens: Double?
    let inputAudioTokens: Double?
    let outputAudioTokens: Double?
    let numModelRequests: Double
    let model: String?
    let projectID: String?

    var totalTokens: Double {
        inputTokens + outputTokens + (inputAudioTokens ?? 0) + (outputAudioTokens ?? 0)
    }

    private enum CodingKeys: String, CodingKey {
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
        case inputCachedTokens = "input_cached_tokens"
        case inputAudioTokens = "input_audio_tokens"
        case outputAudioTokens = "output_audio_tokens"
        case numModelRequests = "num_model_requests"
        case model
        case projectID = "project_id"
    }
}

private struct OpenAIRateLimitListResponse: Decodable {
    let object: String
    let data: [OpenAIRateLimit]
    let firstID: String?
    let lastID: String?
    let hasMore: Bool

    private enum CodingKeys: String, CodingKey {
        case object
        case data
        case firstID = "first_id"
        case lastID = "last_id"
        case hasMore = "has_more"
    }
}

private struct OpenAIRateLimit: Decodable {
    let id: String
    let model: String
    let maxRequestsPer1Minute: Double
    let maxTokensPer1Minute: Double
    let maxRequestsPer1Day: Double?
    let maxImagesPer1Minute: Double?
    let maxAudioMegabytesPer1Minute: Double?
    let batch1DayMaxInputTokens: Double?

    private enum CodingKeys: String, CodingKey {
        case id
        case model
        case maxRequestsPer1Minute = "max_requests_per_1_minute"
        case maxTokensPer1Minute = "max_tokens_per_1_minute"
        case maxRequestsPer1Day = "max_requests_per_1_day"
        case maxImagesPer1Minute = "max_images_per_1_minute"
        case maxAudioMegabytesPer1Minute = "max_audio_megabytes_per_1_minute"
        case batch1DayMaxInputTokens = "batch_1_day_max_input_tokens"
    }
}

private struct OpenAIUsageTotals {
    var requests: Double
    var tokens: Double

    static let zero = OpenAIUsageTotals(requests: 0, tokens: 0)
}

private struct OpenAIAnalyticsTotals {
    var tokens: Double = 0
    var requests: Double = 0
    var cost: Double = 0
}

private struct OpenAICostBucketPage: Decodable {
    let object: String?
    let data: [OpenAICostBucket]
    let hasMore: Bool
    let nextPage: String?

    private enum CodingKeys: String, CodingKey {
        case object
        case data
        case hasMore = "has_more"
        case nextPage = "next_page"
    }
}

private struct OpenAICostBucket: Decodable {
    let object: String?
    let startTime: TimeInterval
    let endTime: TimeInterval
    let results: [OpenAICostResult]

    private enum CodingKeys: String, CodingKey {
        case object
        case startTime = "start_time"
        case endTime = "end_time"
        case results
    }
}

private struct OpenAICostResult: Decodable {
    let amount: OpenAIMoneyAmount
    let projectID: String?
    let lineItem: String?

    private enum CodingKeys: String, CodingKey {
        case amount
        case projectID = "project_id"
        case lineItem = "line_item"
    }
}

private struct OpenAIMoneyAmount: Decodable {
    let value: Double
    let currency: String?
}

// MARK: - Unified Credential Import Service

/// Unified credential import service for all providers.
/// Supports auto-detection of known credential files and manual file import.
public enum CredentialImportService {

    public struct ImportedCredential {
        public let accessToken: String?
        public let accountIdentifier: String?
        public let customEndpoint: String?
        public let extraFields: [String: String]?
        /// Security-scoped bookmark data for accessing files outside sandbox
        public let bookmarkData: Data?

        public init(accessToken: String?, accountIdentifier: String?, customEndpoint: String? = nil, extraFields: [String: String]? = nil, bookmarkData: Data? = nil) {
            self.accessToken = accessToken
            self.accountIdentifier = accountIdentifier
            self.customEndpoint = customEndpoint
            self.extraFields = extraFields
            self.bookmarkData = bookmarkData
        }
    }

    public enum ImportError: LocalizedError {
        case userCancelled
        case fileNotFound
        case fileUnreadable
        case invalidFormat
        case unsupportedProvider
        case missingRequiredField(String)

        public var errorDescription: String? {
            switch self {
            case .userCancelled:
                return "Import cancelled."
            case .fileNotFound:
                return "File not found."
            case .fileUnreadable:
                return "Could not read file. Check permissions."
            case .invalidFormat:
                return "Invalid file format."
            case .unsupportedProvider:
                return "Unsupported provider format."
            case .missingRequiredField(let field):
                return "Missing required field: \(field)"
            }
        }
    }

    // MARK: - Known Credential Locations

    public struct DetectedCredential: Identifiable {
        public let id = UUID()
        public let providerID: ProviderID
        public let fileURL: URL
        public let description: String
    }

    /// Auto-detect known credential files
    public static func detectAvailableCredentials() -> [DetectedCredential] {
        var detected: [DetectedCredential] = []

        guard let home = detectedHomeDirectory() else {
            return detected
        }

        // Codex: ~/.codex/auth.json
        let codexPath = home.appendingPathComponent(".codex/auth.json")
        if FileManager.default.fileExists(atPath: codexPath.path) {
            detected.append(DetectedCredential(
                providerID: .openai,
                fileURL: codexPath,
                description: "Codex CLI session"
            ))
        }

        // Codex telemetry: ~/.codex
        let codexRoot = home.appendingPathComponent(".codex")
        let codexLogRoot = codexRoot.appendingPathComponent("log")
        let codexSQLite = codexRoot.appendingPathComponent("logs_2.sqlite")
        let codexSessionIndex = codexRoot.appendingPathComponent("session_index.jsonl")
        if FileManager.default.fileExists(atPath: codexLogRoot.path)
            || FileManager.default.fileExists(atPath: codexSQLite.path)
            || FileManager.default.fileExists(atPath: codexSessionIndex.path) {
            detected.append(DetectedCredential(
                providerID: .codexTelemetry,
                fileURL: codexRoot,
                description: "Codex telemetry logs"
            ))
        }

        // ChatGPT desktop app cache: ~/Library/Application Support/com.openai.chat
        let chatGPTRoot = home.appendingPathComponent("Library/Application Support/com.openai.chat")
        if FileManager.default.fileExists(atPath: chatGPTRoot.path) {
            detected.append(DetectedCredential(
                providerID: .chatgpt,
                fileURL: chatGPTRoot,
                description: "ChatGPT desktop cache"
            ))
        }

        // Claude: Check for any session export
        let claudeRoot = home.appendingPathComponent(".claude")
        let claudeProjects = claudeRoot.appendingPathComponent("projects")
        if FileManager.default.fileExists(atPath: claudeRoot.path)
            || FileManager.default.fileExists(atPath: claudeProjects.path) {
            detected.append(DetectedCredential(
                providerID: .claude,
                fileURL: claudeRoot,
                description: "Claude Code local logs"
            ))
        }

        // Cursor: Check for state.vscdb which contains local editor auth state.
        // This is useful for discovery, but not sufficient for dashboard usage.
        let cursorStateDBPath = home.appendingPathComponent("Library/Application Support/Cursor/User/globalStorage/state.vscdb")
        if FileManager.default.fileExists(atPath: cursorStateDBPath.path) {
            detected.append(DetectedCredential(
                providerID: .cursor,
                fileURL: cursorStateDBPath,
                description: "Cursor local state"
            ))
        }

        // Devin: Check for state.vscdb which contains cached quota and auth state
        let devinStateDBPath = home.appendingPathComponent("Library/Application Support/Devin/User/globalStorage/state.vscdb")
        if FileManager.default.fileExists(atPath: devinStateDBPath.path) {
            detected.append(DetectedCredential(
                providerID: .devin,
                fileURL: devinStateDBPath,
                description: "Devin local state"
            ))
        }

        // Gemini: ~/.gemini
        let geminiRoot = home.appendingPathComponent(".gemini")
        if FileManager.default.fileExists(atPath: geminiRoot.path) {
            detected.append(DetectedCredential(
                providerID: .gemini,
                fileURL: geminiRoot,
                description: "Gemini CLI local session"
            ))
        }

        // Kimi Code 0.26+ migrated from ~/.kimi to ~/.kimi-code.
        let kimiRoots = [".kimi-code", ".kimi"]
        let detectedKimiRoot = kimiRoots
            .map { home.appendingPathComponent($0, isDirectory: true) }
            .first(where: {
                FileManager.default.fileExists(
                    atPath: $0.appendingPathComponent("credentials/kimi-code.json").path
                )
            })
        if let kimiRoot = detectedKimiRoot {
            detected.append(DetectedCredential(
                providerID: .kimi,
                fileURL: kimiRoot,
                description: "Kimi Code CLI session"
            ))
        }

        // Grok CLI: ~/.grok/bin/grok
        let grokRoot = home.appendingPathComponent(".grok")
        if grokRootContainsExecutable(grokRoot) {
            detected.append(DetectedCredential(
                providerID: .grok,
                fileURL: grokRoot,
                description: "Grok CLI data folder"
            ))
        }

        let antigravityRoot = home
            .appendingPathComponent(".gemini", isDirectory: true)
            .appendingPathComponent("antigravity-cli", isDirectory: true)
        if FileManager.default.fileExists(
            atPath: antigravityRoot.appendingPathComponent("antigravity-oauth-token").path
        ) {
            detected.append(DetectedCredential(
                providerID: .antigravity,
                fileURL: antigravityRoot,
                description: "Antigravity CLI session"
            ))
        }

        let mistralRoot = home.appendingPathComponent(".vibe", isDirectory: true)
        if FileManager.default.fileExists(
            atPath: mistralRoot.appendingPathComponent("logs/session", isDirectory: true).path
        ) {
            detected.append(DetectedCredential(
                providerID: .mistral,
                fileURL: mistralRoot,
                description: "Mistral Vibe usage estimates"
            ))
        }

        let museRoot = home
            .appendingPathComponent(".local", isDirectory: true)
            .appendingPathComponent("share", isDirectory: true)
            .appendingPathComponent("muse", isDirectory: true)
        if FileManager.default.fileExists(
            atPath: museRoot.appendingPathComponent("sessions", isDirectory: true).path
        ) {
            detected.append(DetectedCredential(
                providerID: .meta,
                fileURL: museRoot,
                description: "Meta Muse session usage"
            ))
        }

        return detected
    }

    // MARK: - Import from URL

    /// Import credentials from a user-selected file URL
    public static func importFromURL(_ url: URL, for providerID: ProviderID) throws -> ImportedCredential {
        guard url.isFileURL else { throw ImportError.fileNotFound }
        let selectedIsDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory)
            ?? url.hasDirectoryPath

        if providerID == .codexTelemetry {
            let selectedURL = url
            return ImportedCredential(
                accessToken: nil,
                accountIdentifier: nil,
                customEndpoint: selectedURL.path,
                extraFields: [
                    "codexTelemetrySource": url.hasDirectoryPath ? "directory" : "file"
                ],
                bookmarkData: makeSecurityScopedBookmarkData(for: selectedURL)
            )
        }

        if providerID == .chatgpt {
            let resolvedRoot = url.hasDirectoryPath ? url : url.deletingLastPathComponent()
            return ImportedCredential(
                accessToken: nil,
                accountIdentifier: nil,
                customEndpoint: resolvedRoot.path,
                extraFields: [
                    "chatgptLocalSource": url.hasDirectoryPath ? "directory" : "file"
                ],
                bookmarkData: makeSecurityScopedBookmarkData(for: resolvedRoot)
            )
        }

        if providerID == .cursor, url.hasDirectoryPath {
            let stateDBURL = url.appendingPathComponent("state.vscdb")
            let backupDBURL = url.appendingPathComponent("state.vscdb.backup")
            guard FileManager.default.fileExists(atPath: stateDBURL.path)
                    || FileManager.default.fileExists(atPath: backupDBURL.path) else {
                throw ImportError.missingRequiredField("state.vscdb")
            }

            return ImportedCredential(
                accessToken: nil,
                accountIdentifier: nil,
                customEndpoint: stateDBURL.path,
                extraFields: [
                    "cursorAuthMode": "localState",
                    "cursorLocalStateSource": "directory"
                ],
                bookmarkData: makeSecurityScopedBookmarkData(for: url)
            )
        }

        // Special handling for SQLite databases (Devin and Cursor)
        if url.lastPathComponent == "state.vscdb" {
            print("[CredentialImportService] Reading SQLite database immediately: \(url.path)")

            // For Cursor: capture the selected DB path with a security-scoped
            // bookmark. The local editor token is useful for cached metadata,
            // but it is not enough for cursor.com live usage on its own.
            if providerID == .cursor {
                let bookmarkData = makeSecurityScopedBookmarkData(for: url)
                return ImportedCredential(
                    accessToken: nil,
                    accountIdentifier: nil,
                    customEndpoint: url.path,
                    extraFields: [
                        "cursorAuthMode": "localState",
                        "cursorLocalStateSource": "file"
                    ],
                    bookmarkData: bookmarkData
                )
            }

            if providerID == .devin {
                // Bookmark the FILE itself, not the parent directory.
                // NSOpenPanel grants security-scoped access only to the user-selected URL;
                // bookmarking the parent directory produces an invalid bookmark that fails
                // to resolve on the next launch, forcing the user to re-import every time.
                let bookmarkData = makeSecurityScopedBookmarkData(for: url)
                let authStatus = readDevinAuthStatus(from: url)

                return ImportedCredential(
                    accessToken: authStatus?.apiKey,
                    accountIdentifier: authStatus?.accountIdentifier,
                    customEndpoint: url.path,
                    extraFields: authStatus?.extraFields,
                    bookmarkData: bookmarkData
                )
            }

            // For other providers, store the file path for future local reads.
            return ImportedCredential(
                accessToken: nil,
                accountIdentifier: nil,
                customEndpoint: url.path,
                extraFields: nil,
                bookmarkData: nil
            )
        }

        if providerID == .claude || providerID == .gemini {
            let selectedRoot = url.hasDirectoryPath ? url : url.deletingLastPathComponent()
            let bookmarkData = makeSecurityScopedBookmarkData(for: selectedRoot)

            return ImportedCredential(
                accessToken: nil,
                accountIdentifier: nil,
                customEndpoint: selectedRoot.path,
                extraFields: nil,
                bookmarkData: bookmarkData
            )
        }

        if providerID == .kimi, url.hasDirectoryPath {
            let credentialsFile = kimiOAuthFileURL(fromSelectedDirectory: url)
            guard FileManager.default.fileExists(atPath: credentialsFile.path) else {
                throw ImportError.missingRequiredField("credentials/kimi-code.json")
            }

            return ImportedCredential(
                accessToken: nil,
                accountIdentifier: nil,
                customEndpoint: credentialsFile.path,
                extraFields: [
                    "kimiAuthMode": "oauthFile",
                    "kimiCredentialSource": "directory"
                ],
                bookmarkData: makeSecurityScopedReadWriteBookmarkData(for: url)
            )
        }

        if providerID == .grok {
            let selectedRoot = grokRootURL(fromSelectedURL: url)
            guard grokRootContainsExecutable(selectedRoot) else {
                throw ImportError.missingRequiredField("bin/grok")
            }

            return ImportedCredential(
                accessToken: nil,
                accountIdentifier: nil,
                customEndpoint: selectedRoot.path,
                extraFields: [
                    "grokSource": "directory"
                ],
                bookmarkData: makeSecurityScopedReadWriteBookmarkData(for: selectedRoot)
            )
        }

        if providerID == .antigravity {
            let rootURL = antigravityRootURL(fromSelectedURL: url)
            guard FileManager.default.fileExists(
                atPath: rootURL.appendingPathComponent("antigravity-oauth-token").path
            ) else {
                throw ImportError.missingRequiredField("antigravity-oauth-token")
            }
            return ImportedCredential(
                accessToken: nil,
                accountIdentifier: nil,
                customEndpoint: rootURL.path,
                extraFields: ["antigravitySource": "officialCLIData"],
                bookmarkData: makeSecurityScopedBookmarkData(for: rootURL)
            )
        }

        if providerID == .mistral, selectedIsDirectory {
            let sessionsURL: URL
            switch url.lastPathComponent {
            case "session":
                sessionsURL = url
            case "logs":
                sessionsURL = url.appendingPathComponent("session", isDirectory: true)
            default:
                sessionsURL = url.appendingPathComponent("logs/session", isDirectory: true)
            }
            guard FileManager.default.fileExists(atPath: sessionsURL.path) else {
                throw ImportError.missingRequiredField("logs/session")
            }
            return ImportedCredential(
                accessToken: nil,
                accountIdentifier: nil,
                customEndpoint: url.path,
                extraFields: ["mistralSource": "vibeMetadata"],
                bookmarkData: makeSecurityScopedBookmarkData(for: url)
            )
        }

        if providerID == .meta, selectedIsDirectory {
            let museRoot: URL
            switch url.lastPathComponent {
            case "sessions":
                museRoot = url.deletingLastPathComponent()
            case "muse":
                museRoot = url
            default:
                museRoot = url
            }
            let sessionsURL = url.lastPathComponent == "sessions"
                ? url
                : museRoot.appendingPathComponent("sessions", isDirectory: true)
            guard FileManager.default.fileExists(atPath: sessionsURL.path) else {
                throw ImportError.missingRequiredField("sessions")
            }
            // Bookmark the Powerbox-selected URL (often `sessions`), not only the parent
            // muse root — sandbox grants apply to the selection. customEndpoint stays
            // museRoot.path for display / normalized data-home resolution.
            return ImportedCredential(
                accessToken: nil,
                accountIdentifier: nil,
                customEndpoint: museRoot.path,
                extraFields: ["metaSource": "museDataHome"],
                bookmarkData: makeSecurityScopedBookmarkData(for: url)
            )
        }

        if providerID == .cerebras {
            let isCSV = url.pathExtension.lowercased() == "csv"
            let hasCSV = selectedIsDirectory && ((try? FileManager.default.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ))?.contains(where: { $0.pathExtension.lowercased() == "csv" }) == true)
            guard isCSV || hasCSV else {
                throw ImportError.missingRequiredField("Cerebras Analytics CSV")
            }
            return ImportedCredential(
                accessToken: nil,
                accountIdentifier: nil,
                customEndpoint: url.path,
                extraFields: ["cerebrasSource": isCSV ? "analyticsCSV" : "analyticsFolder"],
                bookmarkData: makeSecurityScopedBookmarkData(for: url)
            )
        }

        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw ImportError.fileUnreadable
        }

        // Try to parse as JSON first
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return try parseJSON(json, for: providerID, sourceURL: url)
        }

        // Try to parse as plain text (single token)
        if let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) {
            if !text.isEmpty && !text.contains("{") {
                // Single line token
                return ImportedCredential(
                    accessToken: text,
                    accountIdentifier: nil,
                    customEndpoint: nil,
                    extraFields: nil,
                    bookmarkData: nil
                )
            }
        }

        throw ImportError.invalidFormat
    }

    // MARK: - SQLite Helpers

    private struct DevinAuthState {
        let apiKey: String?
        let accountIdentifier: String?
        let extraFields: [String: String]?
    }

    private static func readDevinAuthStatus(from url: URL) -> DevinAuthState? {
        guard FileManager.default.isReadableFile(atPath: url.path) else {
            print("[CredentialImportService] Devin state.vscdb not readable at path: \(url.path)")
            return nil
        }

        guard let db = openSQLiteSnapshotDatabase(at: url) else {
            print("[CredentialImportService] Failed to open Devin state.vscdb")
            return nil
        }
        defer { sqlite3_close(db) }

        guard let rawValue = readSQLiteValue(
            from: db,
            query: """
            SELECT value FROM ItemTable 
            WHERE key IN ('devinAuthStatus', 'windsurfAuthStatus', 'codeiumAuthStatus', 'authStatus')
            OR key LIKE '%AuthStatus%'
            ORDER BY CASE 
                WHEN key LIKE 'devin%' THEN 1 
                WHEN key LIKE 'windsurf%' THEN 2 
                WHEN key LIKE 'codeium%' THEN 3 
                ELSE 4 
            END 
            LIMIT 1;
            """
        ),
        let data = rawValue.data(using: .utf8),
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            print("[CredentialImportService] No Devin auth status found in database")
            return nil
        }

        let apiKey = json["apiKey"] as? String
            ?? json["api_key"] as? String
            ?? json["access_token"] as? String
        let accountIdentifier = inferredDevinAccountIdentifier(from: json)

        var extraFields: [String: String] = [:]
        if let userStatus = json["userStatusProtoBinaryBase64"] as? String, !userStatus.isEmpty {
            extraFields["devinUserStatusProtoBinaryBase64"] = userStatus
        }

        return DevinAuthState(
            apiKey: apiKey,
            accountIdentifier: accountIdentifier,
            extraFields: extraFields.isEmpty ? nil : extraFields
        )
    }

    private static func inferredDevinAccountIdentifier(from json: [String: Any]) -> String? {
        guard let encoded = json["userStatusProtoBinaryBase64"] as? String,
              let data = Data(base64Encoded: encoded),
              let decoded = String(data: data, encoding: .utf8) else {
            return nil
        }

        let uuidPattern = #"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"#
        guard let regex = try? NSRegularExpression(pattern: uuidPattern) else {
            return nil
        }

        let range = NSRange(decoded.startIndex..., in: decoded)
        guard let match = regex.firstMatch(in: decoded, options: [], range: range),
              let foundRange = Range(match.range, in: decoded) else {
            return nil
        }

        return String(decoded[foundRange])
    }

    private static func readSQLiteValue(from db: OpaquePointer, query: String) -> String? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK, let statement else {
            return nil
        }
        defer { sqlite3_finalize(statement) }

        guard sqlite3_step(statement) == SQLITE_ROW,
              let textPointer = sqlite3_column_text(statement, 0) else {
            return nil
        }

        return String(cString: textPointer)
    }

    private static func openSQLiteSnapshotDatabase(at url: URL) -> OpaquePointer? {
        let candidates = sqliteSnapshotCandidates(for: url)

        for candidate in candidates {
            guard FileManager.default.isReadableFile(atPath: candidate.path) else { continue }

            var db: OpaquePointer?
            let uri = candidate.absoluteString + "?mode=ro&immutable=1"
            if sqlite3_open_v2(uri, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK, let db {
                return db
            }

            if let db {
                sqlite3_close(db)
            }
        }

        return nil
    }

    private static func sqliteSnapshotCandidates(for url: URL) -> [URL] {
        guard url.lastPathComponent == "state.vscdb" else {
            return [url]
        }

        return [
            url,
            url.deletingLastPathComponent().appendingPathComponent("state.vscdb.backup")
        ]
    }

    // MARK: - Provider-Specific Parsers

    private static func parseJSON(_ json: [String: Any], for providerID: ProviderID, sourceURL: URL) throws -> ImportedCredential {
        switch providerID {
        case .openai:
            return try parseCodexJSON(json)
        case .openaiAPI:
            return try parseOpenAIAPIJSON(json)
        case .chatgpt:
            return ImportedCredential(
                accessToken: nil,
                accountIdentifier: nil,
                customEndpoint: sourceURL.hasDirectoryPath ? sourceURL.path : sourceURL.deletingLastPathComponent().path,
                extraFields: [
                    "chatgptLocalSource": "json"
                ],
                bookmarkData: makeSecurityScopedBookmarkData(for: sourceURL.hasDirectoryPath ? sourceURL : sourceURL.deletingLastPathComponent())
            )
        case .codexTelemetry:
            let selectedURL = sourceURL
            return ImportedCredential(
                accessToken: nil,
                accountIdentifier: nil,
                customEndpoint: selectedURL.path,
                extraFields: [
                    "codexTelemetrySource": "json"
                ],
                bookmarkData: makeSecurityScopedBookmarkData(for: selectedURL)
            )
        case .claude:
            return try parseClaudeJSON(json, sourceURL: sourceURL)
        case .cursor:
            return try parseCursorJSON(json)
        case .devin:
            return try parseDevinJSON(json, sourceURL: sourceURL)
        case .gemini:
            let selectedRoot = sourceURL.hasDirectoryPath ? sourceURL : sourceURL.deletingLastPathComponent()
            return ImportedCredential(
                accessToken: nil,
                accountIdentifier: nil,
                customEndpoint: selectedRoot.path,
                extraFields: nil,
                bookmarkData: makeSecurityScopedBookmarkData(for: selectedRoot)
            )
        case .kimi:
            return try parseKimiJSON(json, sourceURL: sourceURL)
        case .mistral:
            guard let token = json["admin_api_key"] as? String
                ?? json["api_key"] as? String
                ?? json["access_token"] as? String else {
                throw ImportError.missingRequiredField("admin_api_key")
            }
            return ImportedCredential(
                accessToken: token,
                accountIdentifier: nil,
                extraFields: ["mistralSource": "adminAPI"]
            )
        case .deepseek:
            guard let token = json["api_key"] as? String
                ?? json["access_token"] as? String
                ?? json["token"] as? String else {
                throw ImportError.missingRequiredField("api_key")
            }
            return ImportedCredential(accessToken: token, accountIdentifier: nil)
        case .grok, .antigravity, .cerebras, .meta, .ollama, .heatmap:
            throw ImportError.unsupportedProvider
        }
    }

    private static func parseCodexJSON(_ json: [String: Any]) throws -> ImportedCredential {
        // Codex: { "tokens": { "access_token": "...", "account_id": "..." } }
        guard let tokens = json["tokens"] as? [String: Any] else {
            // Also try direct format
            if let accessToken = json["access_token"] as? String {
                return ImportedCredential(
                    accessToken: accessToken,
                    accountIdentifier: json["account_id"] as? String,
                    customEndpoint: nil,
                    extraFields: nil,
                    bookmarkData: nil
                )
            }
            throw ImportError.missingRequiredField("tokens or access_token")
        }

        guard let accessToken = tokens["access_token"] as? String else {
            throw ImportError.missingRequiredField("access_token")
        }

        return ImportedCredential(
            accessToken: accessToken,
            accountIdentifier: tokens["account_id"] as? String,
            customEndpoint: nil,
            extraFields: nil,
            bookmarkData: nil
        )
    }

    private static func parseOpenAIAPIJSON(_ json: [String: Any]) throws -> ImportedCredential {
        let accessToken = json["admin_api_key"] as? String
            ?? json["api_key"] as? String
            ?? json["apiKey"] as? String
            ?? json["access_token"] as? String
            ?? json["token"] as? String

        guard let token = accessToken else {
            throw ImportError.missingRequiredField("admin_api_key or api_key")
        }

        let projectID = json["project_id"] as? String
            ?? json["projectID"] as? String
            ?? json["project"] as? String

        return ImportedCredential(
            accessToken: token,
            accountIdentifier: projectID,
            customEndpoint: nil,
            extraFields: nil,
            bookmarkData: nil
        )
    }

    private static func parseClaudeJSON(_ json: [String: Any], sourceURL: URL) throws -> ImportedCredential {
        // Claude might export in various formats
        // Try common field names
        let accessToken = json["api_key"] as? String
            ?? json["session_token"] as? String
            ?? json["access_token"] as? String
            ?? json["token"] as? String

        guard let token = accessToken else {
            throw ImportError.missingRequiredField("api_key or session_token")
        }

        return ImportedCredential(
            accessToken: token,
            accountIdentifier: json["workspace_id"] as? String ?? json["account_id"] as? String,
            customEndpoint: nil,
            extraFields: nil,
            bookmarkData: nil
        )
    }

    private static func parseCursorJSON(_ json: [String: Any]) throws -> ImportedCredential {
        let accessToken = json["accessToken"] as? String
            ?? json["access_token"] as? String
            ?? json["token"] as? String
            ?? json["api_key"] as? String

        guard let token = accessToken else {
            throw ImportError.missingRequiredField("accessToken or token")
        }

        return ImportedCredential(
            accessToken: token,
            accountIdentifier: json["team_id"] as? String ?? json["user_id"] as? String,
            customEndpoint: nil,
            extraFields: [
                "cursorAuthMode": "bearer"
            ],
            bookmarkData: nil
        )
    }

    private static func parseDevinJSON(_ json: [String: Any], sourceURL: URL) throws -> ImportedCredential {
        // If the selected file is state.vscdb, store its path as customEndpoint
        // so the provider can read quota data directly from it
        if sourceURL.lastPathComponent == "state.vscdb" {
            print("[CredentialImportService] Creating bookmark in parseDevinJSON for: \(sourceURL.path)")
            let bookmarkData = makeSecurityScopedBookmarkData(for: sourceURL)
            if let bookmarkData {
                print("[CredentialImportService] Created bookmark in parseDevinJSON (length: \(bookmarkData.count))")
            }
            return ImportedCredential(
                accessToken: nil,
                accountIdentifier: nil,
                customEndpoint: sourceURL.path,
                extraFields: nil,
                bookmarkData: bookmarkData
            )
        }

        let accessToken = json["api_key"] as? String
            ?? json["token"] as? String
            ?? json["access_token"] as? String

        guard let token = accessToken else {
            throw ImportError.missingRequiredField("api_key or token")
        }

        return ImportedCredential(
            accessToken: token,
            accountIdentifier: json["team_id"] as? String,
            customEndpoint: nil,
            extraFields: nil,
            bookmarkData: nil
        )
    }

    private static func parseKimiJSON(_ json: [String: Any], sourceURL: URL) throws -> ImportedCredential {
        if json["refresh_token"] is String || json["expires_at"] != nil || json["scope"] as? String == "kimi-code" {
            guard sourceURL.isFileURL else { throw ImportError.fileNotFound }
            return ImportedCredential(
                accessToken: nil,
                accountIdentifier: nil,
                customEndpoint: sourceURL.path,
                extraFields: [
                    "kimiAuthMode": "oauthFile"
                ],
                bookmarkData: makeSecurityScopedReadWriteBookmarkData(for: sourceURL)
            )
        }

        let accessToken = json["api_key"] as? String
            ?? json["apiKey"] as? String
            ?? json["token"] as? String
            ?? json["access_token"] as? String

        guard let token = accessToken else {
            throw ImportError.missingRequiredField("api_key or access_token")
        }

        return ImportedCredential(
            accessToken: token,
            accountIdentifier: nil,
            customEndpoint: nil,
            extraFields: [
                "kimiAuthMode": "apiKey"
            ],
            bookmarkData: nil
        )
    }

    private static func kimiOAuthFileURL(fromSelectedDirectory url: URL) -> URL {
        if url.lastPathComponent == "credentials" {
            return url.appendingPathComponent("kimi-code.json")
        }

        return url
            .appendingPathComponent("credentials", isDirectory: true)
            .appendingPathComponent("kimi-code.json")
    }

    private static func detectedHomeDirectory() -> URL? {
        #if os(macOS)
        let homePath = NSHomeDirectory()
        let realHomePath: String
        if let containerRange = homePath.range(of: "/Library/Containers/") {
            realHomePath = String(homePath[..<containerRange.lowerBound])
        } else {
            realHomePath = homePath
        }
        return URL(fileURLWithPath: realHomePath)
        #else
        nil
        #endif
    }

    private static func makeSecurityScopedBookmarkData(for url: URL) -> Data? {
        #if os(macOS)
        do {
            let didStartAccessing = url.startAccessingSecurityScopedResource()
            defer {
                if didStartAccessing {
                    url.stopAccessingSecurityScopedResource()
                }
            }

            return try url.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess])
        } catch {
            print("[CredentialImportService] Failed to create bookmark: \(error)")
            return nil
        }
        #else
        return nil
        #endif
    }

    private static func makeSecurityScopedReadWriteBookmarkData(for url: URL) -> Data? {
        #if os(macOS)
        do {
            let didStartAccessing = url.startAccessingSecurityScopedResource()
            defer {
                if didStartAccessing {
                    url.stopAccessingSecurityScopedResource()
                }
            }

            return try url.bookmarkData(options: [.withSecurityScope])
        } catch {
            print("[CredentialImportService] Failed to create read-write bookmark: \(error)")
            return nil
        }
        #else
        return nil
        #endif
    }

    private static func grokRootURL(fromSelectedURL url: URL) -> URL {
        let resourceValues = try? url.resourceValues(forKeys: [.isDirectoryKey])
        let isDirectory = resourceValues?.isDirectory ?? url.hasDirectoryPath

        if isDirectory {
            if url.lastPathComponent == "bin" || url.lastPathComponent == "downloads" {
                return url.deletingLastPathComponent()
            }
            return url
        }

        let parent = url.deletingLastPathComponent()
        if parent.lastPathComponent == "bin" || parent.lastPathComponent == "downloads" {
            return parent.deletingLastPathComponent()
        }
        return parent
    }

    private static func grokRootContainsExecutable(_ rootURL: URL) -> Bool {
        let fileManager = FileManager.default
        let binURL = rootURL.appendingPathComponent("bin/grok")
        if fileManager.fileExists(atPath: binURL.path) || fileManager.isExecutableFile(atPath: binURL.path) {
            return true
        }

        let downloadsURL = rootURL.appendingPathComponent("downloads")
        guard let candidates = try? fileManager.contentsOfDirectory(
            at: downloadsURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return false
        }

        return candidates.contains { candidate in
            candidate.lastPathComponent.hasPrefix("grok-")
                && fileManager.isExecutableFile(atPath: candidate.path)
        }
    }

    private static func antigravityRootURL(fromSelectedURL url: URL) -> URL {
        if url.lastPathComponent == "antigravity-oauth-token" {
            return url.deletingLastPathComponent()
        }
        if url.lastPathComponent == ".gemini" {
            return url.appendingPathComponent("antigravity-cli", isDirectory: true)
        }
        return url
    }
}

// MARK: - macOS File Picker Extension

#if os(macOS)
import AppKit
import UniformTypeIdentifiers

public extension CredentialImportService {
    /// Shows a file picker and imports credentials for the specified provider
    static func showImportPanel(
        for providerID: ProviderID,
        completion: @escaping (Result<ImportedCredential, Error>) -> Void
    ) {
        DispatchQueue.main.async {
            let panel = NSOpenPanel()
            panel.message = {
                switch providerID {
                case .codexTelemetry:
                    return "Select the ~/.codex folder for complete Codex activity, or one log file for limited access."
                case .cursor:
                    return "Select Cursor's globalStorage folder or state.vscdb for local metadata. Use the web session import for live usage."
                case .grok:
                    return "Select your ~/.grok folder so Limit Counter can run /usage locally."
                case .antigravity:
                    return "Select ~/.gemini/antigravity-cli. Limit Counter reads the official CLI session and requests Antigravity quota summary on a 4→7→16→3→21 minute loop (manual refresh is immediate)."
                case .mistral:
                    return "Select ~/.vibe so Limit Counter can estimate Vibe spend from session metadata and message lengths."
                case .meta:
                    return "Select ~/.local/share/muse so Limit Counter can project Muse session spend."
                case .cerebras:
                    return "Select a Cerebras Analytics CSV or a folder containing exported CSV reports."
                default:
                    return "Select credential file for \(providerID.displayName)"
                }
            }()
            panel.prompt = "Import"
            if providerID == .kimi || providerID == .mistral || providerID == .antigravity
                || providerID == .meta {
                panel.allowedContentTypes = [.folder]
            } else if providerID == .cerebras {
                panel.allowedContentTypes = [.folder, .commaSeparatedText, .plainText, .data]
            } else if providerID == .codexTelemetry || providerID == .claude
                        || providerID == .chatgpt || providerID == .cursor
                        || providerID == .gemini || providerID == .grok {
                panel.allowedContentTypes = [.folder, .json, .plainText, .data]
            } else {
                panel.allowedContentTypes = [.json, .plainText, .data]
            }
            panel.allowsMultipleSelection = false
            panel.canChooseDirectories = providerID == .codexTelemetry || providerID == .claude
                || providerID == .chatgpt || providerID == .cursor || providerID == .gemini
                || providerID == .kimi || providerID == .grok || providerID == .antigravity
                || providerID == .mistral || providerID == .cerebras || providerID == .meta
            panel.canChooseFiles = providerID != .kimi
                && providerID != .mistral
                && providerID != .antigravity
                && providerID != .meta

            // Suggest starting directory based on provider
            let home = FileManager.default.homeDirectoryForCurrentUser
            switch providerID {
            case .openai:
                panel.directoryURL = home.appendingPathComponent(".codex")
            case .openaiAPI:
                panel.directoryURL = home
            case .chatgpt:
                panel.directoryURL = home.appendingPathComponent("Library/Application Support/com.openai.chat")
            case .codexTelemetry:
                panel.directoryURL = home.appendingPathComponent(".codex")
            case .claude:
                panel.directoryURL = home.appendingPathComponent(".claude")
            case .cursor:
                // Point to the directory containing state.vscdb
                panel.directoryURL = home.appendingPathComponent("Library/Application Support/Cursor/User/globalStorage")
            case .devin:
                // Point to the directory containing state.vscdb
                panel.directoryURL = home.appendingPathComponent("Library/Application Support/Devin/User/globalStorage")
            case .gemini:
                panel.directoryURL = home.appendingPathComponent(".gemini")
            case .kimi:
                let currentRoot = home.appendingPathComponent(".kimi-code")
                panel.message = "Select ~/.kimi-code so Limit Counter can follow the Kimi CLI OAuth session and local activity."
                panel.prompt = "Grant Access"
                // Do not gate this on `fileExists`: before Powerbox grants the
                // new folder, the sandbox can report false and incorrectly
                // redirect migrated users back into the old ~/.kimi scope.
                panel.directoryURL = currentRoot
            case .grok:
                panel.directoryURL = home.appendingPathComponent(".grok")
            case .antigravity:
                panel.directoryURL = home.appendingPathComponent(".gemini", isDirectory: true)
                panel.prompt = "Grant Access"
            case .mistral:
                panel.directoryURL = home.appendingPathComponent(".vibe")
                panel.prompt = "Grant Access"
            case .meta:
                // Prefer the real user home over a sandboxed container home so the
                // panel opens on ~/.local/share/muse when that path exists.
                let homePath = NSHomeDirectory()
                let realHome: String
                if let range = homePath.range(of: "/Library/Containers/") {
                    realHome = String(homePath[..<range.lowerBound])
                } else {
                    realHome = homePath
                }
                panel.directoryURL = URL(fileURLWithPath: realHome, isDirectory: true)
                    .appendingPathComponent(".local/share/muse", isDirectory: true)
                panel.prompt = "Grant Access"
            case .deepseek:
                panel.directoryURL = home
            case .cerebras:
                panel.directoryURL = home.appendingPathComponent("Downloads")
            case .ollama, .heatmap:
                break
            }

            panel.begin { result in
                guard result == .OK, let url = panel.url else {
                    completion(.failure(ImportError.userCancelled))
                    return
                }

                // Start the Powerbox grant before validating the selection.
                // Sandboxed file metadata checks can otherwise fail even though
                // the user selected the folder explicitly.
                let didStartAccess = url.startAccessingSecurityScopedResource()
                defer {
                    if didStartAccess {
                        url.stopAccessingSecurityScopedResource()
                    }
                }

                do {
                    let credential = try importFromURL(url, for: providerID)
                    completion(.success(credential))
                } catch {
                    completion(.failure(error))
                }
            }
        }
    }
}
#endif

// MARK: - Kimi Code Provider Client

public struct KimiProviderClient: ProviderClient {
    public let providerID: ProviderID = .kimi

    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func fetchSnapshot(credentials: ProviderCredential?) async throws -> QuotaSnapshot {
        guard let credentials else { throw ProviderFetchError.notConfigured }

        let accessToken = try await resolvedAccessToken(from: credentials)
        guard !accessToken.isEmpty else { throw ProviderFetchError.notConfigured }

        let usageURL = try resolvedUsageURL(from: credentials)
        var request = URLRequest(url: usageURL)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        request.setValue("no-cache", forHTTPHeaderField: "Pragma")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw ProviderFetchError.networkError(underlying: error)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ProviderFetchError.unknown
        }

        switch httpResponse.statusCode {
        case 200..<300:
            let apiSnapshot = try KimiUsageNormalizer.snapshot(from: data, fetchedAt: Date())
            // Best-effort augmentation: read local Kimi CLI session logs.
            // so per-turn activity events surface on the heatmap. Returns [] if
            // the sandbox denies the read (typical when the user only granted a
            // bookmark to `kimi-code.json` itself).
            let cliEvents = loadLocalKimiEvents(credentials: credentials)
            // Additional source: AGBench's unified usage.json tracks every
            // run the user invokes through TaskWraith, including Kimi runs.
            // For users who drive activity through AGBench this is the
            // richer signal (61 records vs whatever wire.jsonl has on its
            // own). No-op when the user hasn't granted the bookmark.
            let agbenchEvents = AGBenchUsageReader.loadEvents(forProviderKey: "kimi")
            let combinedEvents = cliEvents + agbenchEvents
            let merged = mergeEvents(into: apiSnapshot, events: combinedEvents)
            // Preserve historical events whose source `wire.jsonl` has aged
            // past the 30-day modification-date window in
            // `KimiLocalTranscriptReader`. Same fix as Claude.
            return enrichEventsWithHistory(merged)
        case 401, 403:
            throw ProviderFetchError.invalidCredential
        case 429:
            throw ProviderFetchError.rateLimited
        default:
            throw ProviderFetchError.parsingError("Kimi usage endpoint returned HTTP \(httpResponse.statusCode).")
        }
    }

    private func loadLocalKimiEvents(credentials: ProviderCredential) -> [UsageEvent] {
        let kimiRootURL = resolvedKimiRoot(from: credentials)
        let bookmarkData = credentials.kimiBookmarkData
            ?? credentials.extraFields?["bookmarkData"].flatMap { Data(base64Encoded: $0) }

        var accessURL = kimiRootURL
        var didStartAccessing = false

        if let bookmarkData {
            #if os(macOS)
            var isStale = false
            if let resolved = try? URL(
                resolvingBookmarkData: bookmarkData,
                options: .withSecurityScope,
                bookmarkDataIsStale: &isStale
            ) {
                // If the bookmark was for `kimi-code.json`, walk up to the
                // Kimi config root so `sessions/` is reachable when (and only
                // when) the sandbox grants enclosing-directory access.
                if resolved.lastPathComponent.hasSuffix(".json") {
                    accessURL = resolved.deletingLastPathComponent().deletingLastPathComponent()
                } else if resolved.lastPathComponent == "credentials" {
                    accessURL = resolved.deletingLastPathComponent()
                } else {
                    accessURL = resolved
                }
                didStartAccessing = accessURL.startAccessingSecurityScopedResource()
            }
            #endif
        }

        defer {
            if didStartAccessing {
                accessURL.stopAccessingSecurityScopedResource()
            }
        }

        return KimiLocalTranscriptReader.loadEvents(kimiRootURL: accessURL)
    }

    /// Resolves the Kimi config root in a sandbox-aware way.
    /// Used as the fallback path before/after attempting bookmark resolution.
    private func resolvedKimiRoot(from credentials: ProviderCredential) -> URL {
        if let endpoint = credentials.normalizedCustomEndpoint, !endpoint.isEmpty {
            let url = URL(fileURLWithPath: endpoint)
            // If the credential points to `kimi-code.json`, navigate up to
            // the selected Kimi config root.
            return url.lastPathComponent.hasSuffix(".json")
                ? url.deletingLastPathComponent().deletingLastPathComponent()
                : url
        }

        let homePath = NSHomeDirectory()
        let realHome: String
        if let r = homePath.range(of: "/Library/Containers/") {
            realHome = String(homePath[..<r.lowerBound])
        } else {
            realHome = homePath
        }
        let home = URL(fileURLWithPath: realHome)
        let currentRoot = home.appendingPathComponent(".kimi-code")
        return FileManager.default.fileExists(atPath: currentRoot.path)
            ? currentRoot
            : home.appendingPathComponent(".kimi")
    }

    /// Returns a copy of `snapshot` with `events` attached (no-op when empty).
    private func mergeEvents(into snapshot: QuotaSnapshot, events: [UsageEvent]) -> QuotaSnapshot {
        guard !events.isEmpty else { return snapshot }
        let sorted = events.sorted { $0.timestamp > $1.timestamp }
        let capped = Array(sorted.prefix(1000))
        return QuotaSnapshot(
            id: snapshot.id,
            providerID: snapshot.providerID,
            displayName: snapshot.displayName,
            planName: snapshot.planName,
            windows: snapshot.windows,
            stats: snapshot.stats,
            balances: snapshot.balances,
            signals: snapshot.signals,
            events: capped,
            fetchState: snapshot.fetchState,
            fetchedAt: snapshot.fetchedAt
        )
    }

    private func resolvedAccessToken(from credentials: ProviderCredential) async throws -> String {
        if shouldUseOAuthFile(credentials),
           let token = try await accessTokenFromOAuthFile(credentials) {
            return token
        }

        guard let token = credentials.normalizedAccessToken else {
            throw ProviderFetchError.notConfigured
        }
        return token
    }

    private func shouldUseOAuthFile(_ credentials: ProviderCredential) -> Bool {
        if credentials.extraFields?["kimiAuthMode"] == "oauthFile" {
            return true
        }

        guard credentials.normalizedAccessToken == nil,
              let endpoint = credentials.normalizedCustomEndpoint else {
            return false
        }

        return endpoint.hasSuffix("kimi-code.json")
    }

    private func accessTokenFromOAuthFile(_ credentials: ProviderCredential) async throws -> String? {
        guard let access = resolvedOAuthFileAccess(from: credentials) else {
            throw ProviderFetchError.notConfigured
        }

        let didStartAccessing = access.scopeURL.startAccessingSecurityScopedResource()
        defer {
            if didStartAccessing {
                access.scopeURL.stopAccessingSecurityScopedResource()
            }
        }

        let migratedURL = migratedOAuthFileURL(from: access.fileURL)
        let url: URL
        if credentials.kimiBookmarkData == nil,
           let migratedURL,
           FileManager.default.isReadableFile(atPath: migratedURL.path) {
            url = migratedURL
        } else {
            url = access.fileURL
        }

        return try await KimiOAuthRefreshCoordinator.shared.accessToken(
            fileURL: url,
            session: session,
            refreshDisabledMessage: migratedURL != nil && url == access.fileURL
                ? "Kimi Code moved its live session to ~/.kimi-code. Import ~/.kimi-code in Kimi settings so Limit Counter can resume refreshes."
                : nil
        )
    }

    private func migratedOAuthFileURL(from selectedURL: URL) -> URL? {
        let selectedRoot = selectedURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        guard selectedRoot.lastPathComponent == ".kimi" else { return nil }

        return selectedRoot
            .deletingLastPathComponent()
            .appendingPathComponent(".kimi-code", isDirectory: true)
            .appendingPathComponent("credentials", isDirectory: true)
            .appendingPathComponent("kimi-code.json")
    }

    private func resolvedOAuthFileAccess(from credentials: ProviderCredential) -> KimiOAuthFileAccess? {
        if let bookmarkData = credentials.kimiBookmarkData {
            #if os(macOS)
            var isStale = false
            if let resolvedURL = try? URL(
                resolvingBookmarkData: bookmarkData,
                options: .withSecurityScope,
                bookmarkDataIsStale: &isStale
            ) {
                if resolvedURL.hasDirectoryPath {
                    if resolvedURL.lastPathComponent == "credentials" {
                        return KimiOAuthFileAccess(
                            fileURL: resolvedURL.appendingPathComponent("kimi-code.json"),
                            scopeURL: resolvedURL
                        )
                    }

                    return KimiOAuthFileAccess(
                        fileURL: resolvedURL
                            .appendingPathComponent("credentials", isDirectory: true)
                            .appendingPathComponent("kimi-code.json"),
                        scopeURL: resolvedURL
                    )
                }

                return KimiOAuthFileAccess(fileURL: resolvedURL, scopeURL: resolvedURL)
            }
            #endif
        }

        guard let path = credentials.normalizedCustomEndpoint else {
            return nil
        }
        let fileURL = URL(fileURLWithPath: path)
        return KimiOAuthFileAccess(fileURL: fileURL, scopeURL: fileURL)
    }

    private func resolvedUsageURL(from credentials: ProviderCredential) throws -> URL {
        if !shouldUseOAuthFile(credentials),
           let customEndpoint = credentials.normalizedCustomEndpoint,
           customEndpoint.hasPrefix("http") {
            guard let baseURL = URL(string: customEndpoint) else {
                throw ProviderFetchError.parsingError("Custom Kimi endpoint is not a valid URL.")
            }

            if baseURL.lastPathComponent == "usages" {
                return baseURL
            }
            return baseURL.appendingPathComponent("usages")
        }

        return URL(string: "https://api.kimi.com/coding/v1/usages")!
    }
}

private extension ProviderCredential {
    var kimiBookmarkData: Data? {
        if let bookmarkData {
            return bookmarkData
        }
        guard let bookmarkBase64 = extraFields?["bookmarkData"] else {
            return nil
        }
        return Data(base64Encoded: bookmarkBase64)
    }
}

private nonisolated struct KimiOAuthFileAccess {
    let fileURL: URL
    let scopeURL: URL
}

private nonisolated struct KimiOAuthFile: Decodable {
    let accessToken: String
    let refreshToken: String?
    let expiresAt: TimeInterval
    let expiresIn: TimeInterval?
    let scope: String?
    let tokenType: String?

    private enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresAt = "expires_at"
        case expiresIn = "expires_in"
        case scope
        case tokenType = "token_type"
    }
}

private nonisolated struct KimiOAuthRefreshResponse: Decodable {
    let accessToken: String
    let refreshToken: String
    let expiresIn: TimeInterval
    let scope: String?
    let tokenType: String?

    private enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
        case scope
        case tokenType = "token_type"
    }
}

private nonisolated enum KimiOAuthRefreshFailure: Error {
    case rejected
}

private actor KimiOAuthRefreshCoordinator {
    static let shared = KimiOAuthRefreshCoordinator()

    private static let oauthHost = URL(string: "https://auth.kimi.com/api/oauth/token")!
    private static let clientID = "17e5f671-d194-4dfb-9706-5516cb48c098"
    private static let minimumRefreshLeeway: TimeInterval = 5 * 60
    private static let lockWaitTimeout: TimeInterval = 15

    func accessToken(
        fileURL: URL,
        session: URLSession,
        refreshDisabledMessage: String?
    ) async throws -> String {
        let initial = try loadOAuthFile(at: fileURL)
        guard !initial.accessToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ProviderFetchError.invalidCredential
        }

        if !shouldRefresh(initial) {
            return initial.accessToken.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        if let refreshDisabledMessage {
            throw ProviderFetchError.credentialExpired(refreshDisabledMessage)
        }

        guard let refreshToken = initial.refreshToken?.trimmingCharacters(in: .whitespacesAndNewlines),
              !refreshToken.isEmpty else {
            throw ProviderFetchError.credentialExpired(
                "Kimi CLI OAuth token is expired and has no refresh token. Run `/login` in Kimi CLI, then import `~/.kimi-code` again."
            )
        }

        let configRoot = configRootURL(for: fileURL)
        let lockURL = try await acquireRefreshLock(configRoot: configRoot)
        let heartbeat = heartbeatLock(at: lockURL)
        defer {
            heartbeat.cancel()
            try? FileManager.default.removeItem(at: lockURL)
        }
        try verifyCredentialDirectoryIsWritable(fileURL: fileURL)

        // Another Kimi process may have refreshed while this app waited.
        let afterLock = try loadOAuthFile(at: fileURL)
        if !shouldRefresh(afterLock) {
            return afterLock.accessToken.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        guard let activeRefreshToken = afterLock.refreshToken?.trimmingCharacters(in: .whitespacesAndNewlines),
              !activeRefreshToken.isEmpty else {
            throw ProviderFetchError.credentialExpired(
                "Kimi CLI OAuth token is expired and has no refresh token. Run `/login` in Kimi CLI, then import `~/.kimi-code` again."
            )
        }

        let refreshed: KimiOAuthRefreshResponse
        do {
            refreshed = try await refresh(
                refreshToken: activeRefreshToken,
                configRoot: configRoot,
                session: session
            )
        } catch KimiOAuthRefreshFailure.rejected {
            // A different Kimi process may have completed rotation despite a
            // stale or ignored lock. Prefer its newly persisted token before
            // asking the user to authenticate again.
            let recovered = try loadOAuthFile(at: fileURL)
            if recovered.refreshToken != activeRefreshToken,
               !shouldRefresh(recovered) {
                return recovered.accessToken.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            throw ProviderFetchError.credentialExpired(
                "Kimi rejected the saved refresh token. Run `/login` in Kimi CLI, then import `~/.kimi-code` again."
            )
        }
        try persist(refreshed, preserving: afterLock, at: fileURL)
        return refreshed.accessToken.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func shouldRefresh(_ oauthFile: KimiOAuthFile, now: Date = Date()) -> Bool {
        let dynamicLeeway = max(
            Self.minimumRefreshLeeway,
            (oauthFile.expiresIn ?? 0) * 0.5
        )
        return oauthFile.expiresAt - now.timeIntervalSince1970 < dynamicLeeway
    }

    private func loadOAuthFile(at url: URL) throws -> KimiOAuthFile {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw ProviderFetchError.networkError(underlying: error)
        }

        do {
            return try JSONDecoder().decode(KimiOAuthFile.self, from: data)
        } catch {
            throw ProviderFetchError.parsingError("Unable to read Kimi CLI OAuth file.")
        }
    }

    private func configRootURL(for fileURL: URL) -> URL {
        let parent = fileURL.deletingLastPathComponent()
        return parent.lastPathComponent == "credentials"
            ? parent.deletingLastPathComponent()
            : parent
    }

    private func acquireRefreshLock(configRoot: URL) async throws -> URL {
        let fileManager = FileManager.default
        let oauthDirectory = configRoot.appendingPathComponent("oauth", isDirectory: true)
        let lockTarget = oauthDirectory.appendingPathComponent("kimi-code")
        let lockURL = oauthDirectory.appendingPathComponent("kimi-code.lock", isDirectory: true)

        do {
            try fileManager.createDirectory(
                at: oauthDirectory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            if !fileManager.fileExists(atPath: lockTarget.path) {
                guard fileManager.createFile(
                    atPath: lockTarget.path,
                    contents: Data(),
                    attributes: [.posixPermissions: 0o600]
                ) else {
                    throw CocoaError(.fileWriteUnknown)
                }
            }
        } catch {
            throw ProviderFetchError.credentialExpired(
                "Limit Counter needs read/write access to `~/.kimi-code` to renew Kimi's rotating OAuth token. Import the folder again in Kimi settings."
            )
        }

        let deadline = Date().addingTimeInterval(Self.lockWaitTimeout)
        while true {
            do {
                try fileManager.createDirectory(
                    at: lockURL,
                    withIntermediateDirectories: false,
                    attributes: [.posixPermissions: 0o700]
                )
                return lockURL
            } catch {
                guard fileManager.fileExists(atPath: lockURL.path) else {
                    throw ProviderFetchError.networkError(underlying: error)
                }

                if let modifiedAt = try? lockURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                   Date().timeIntervalSince(modifiedAt) > 10 {
                    try? fileManager.removeItem(at: lockURL)
                    continue
                }

                guard Date() < deadline else {
                    if fileManager.fileExists(atPath: lockURL.path) {
                        throw ProviderFetchError.networkError(
                            underlying: CocoaError(.fileLocking)
                        )
                    }
                    continue
                }
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
        }
    }

    private func heartbeatLock(at lockURL: URL) -> Task<Void, Never> {
        Task {
            while !Task.isCancelled {
                try? FileManager.default.setAttributes(
                    [.modificationDate: Date()],
                    ofItemAtPath: lockURL.path
                )
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    private func verifyCredentialDirectoryIsWritable(fileURL: URL) throws {
        let probeURL = fileURL.deletingLastPathComponent()
            .appendingPathComponent(".limit-counter-write-probe-\(UUID().uuidString)")
        do {
            try Data().write(to: probeURL, options: .withoutOverwriting)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: probeURL.path
            )
            try FileManager.default.removeItem(at: probeURL)
        } catch {
            try? FileManager.default.removeItem(at: probeURL)
            throw ProviderFetchError.credentialExpired(
                "Limit Counter needs read/write access to `~/.kimi-code` to renew Kimi's rotating OAuth token. Import the folder again in Kimi settings."
            )
        }
    }

    private func refresh(
        refreshToken: String,
        configRoot: URL,
        session: URLSession
    ) async throws -> KimiOAuthRefreshResponse {
        var request = URLRequest(url: Self.oauthHost)
        request.httpMethod = "POST"
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.timeoutInterval = 30
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        addDeviceHeaders(to: &request, configRoot: configRoot)

        var components = URLComponents()
        components.queryItems = [
            URLQueryItem(name: "client_id", value: Self.clientID),
            URLQueryItem(name: "grant_type", value: "refresh_token"),
            URLQueryItem(name: "refresh_token", value: refreshToken)
        ]
        request.httpBody = components.percentEncodedQuery?.data(using: .utf8)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw ProviderFetchError.networkError(underlying: error)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ProviderFetchError.unknown
        }

        let oauthErrorCode = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["error"] as? String
        if httpResponse.statusCode == 401
            || httpResponse.statusCode == 403
            || oauthErrorCode == "invalid_grant" {
            throw KimiOAuthRefreshFailure.rejected
        }

        switch httpResponse.statusCode {
        case 200..<300:
            do {
                let refreshed = try JSONDecoder().decode(KimiOAuthRefreshResponse.self, from: data)
                guard !refreshed.accessToken.isEmpty,
                      !refreshed.refreshToken.isEmpty,
                      refreshed.expiresIn > 0 else {
                    throw ProviderFetchError.parsingError("Kimi OAuth refresh returned incomplete credentials.")
                }
                return refreshed
            } catch let error as ProviderFetchError {
                throw error
            } catch {
                throw ProviderFetchError.parsingError("Unable to parse Kimi OAuth refresh response.")
            }
        case 429:
            throw ProviderFetchError.rateLimited
        default:
            throw ProviderFetchError.parsingError(
                "Kimi OAuth refresh returned HTTP \(httpResponse.statusCode)."
            )
        }
    }

    private func addDeviceHeaders(to request: inout URLRequest, configRoot: URL) {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? "1.0"
        let deviceIDURL = configRoot.appendingPathComponent("device_id")
        let deviceID = (try? String(contentsOf: deviceIDURL, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        request.setValue("kimi_code_cli", forHTTPHeaderField: "X-Msh-Platform")
        request.setValue(asciiHeader(version), forHTTPHeaderField: "X-Msh-Version")
        request.setValue(asciiHeader(ProcessInfo.processInfo.hostName), forHTTPHeaderField: "X-Msh-Device-Name")
        #if os(macOS)
        let platformName = "macOS"
        #else
        let platformName = "iOS"
        #endif
        request.setValue(asciiHeader("\(platformName) \(ProcessInfo.processInfo.operatingSystemVersionString)"), forHTTPHeaderField: "X-Msh-Device-Model")
        request.setValue(asciiHeader(ProcessInfo.processInfo.operatingSystemVersionString), forHTTPHeaderField: "X-Msh-Os-Version")
        if let deviceID, !deviceID.isEmpty {
            request.setValue(asciiHeader(deviceID), forHTTPHeaderField: "X-Msh-Device-Id")
        }
    }

    private func asciiHeader(_ value: String) -> String {
        let scalars = value.unicodeScalars.filter { $0.value >= 0x20 && $0.value <= 0x7e }
        let sanitized = String(String.UnicodeScalarView(scalars))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return sanitized.isEmpty ? "unknown" : sanitized
    }

    private func persist(
        _ refreshed: KimiOAuthRefreshResponse,
        preserving previous: KimiOAuthFile,
        at fileURL: URL,
        now: Date = Date()
    ) throws {
        let data: Data
        do {
            let currentData = try Data(contentsOf: fileURL)
            guard var json = try JSONSerialization.jsonObject(with: currentData) as? [String: Any] else {
                throw CocoaError(.fileReadCorruptFile)
            }
            json["access_token"] = refreshed.accessToken
            json["refresh_token"] = refreshed.refreshToken
            json["expires_at"] = floor(now.timeIntervalSince1970 + refreshed.expiresIn)
            json["expires_in"] = refreshed.expiresIn
            json["scope"] = refreshed.scope ?? previous.scope ?? "kimi-code"
            json["token_type"] = refreshed.tokenType ?? previous.tokenType ?? "Bearer"
            data = try JSONSerialization.data(
                withJSONObject: json,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            )
        } catch {
            throw ProviderFetchError.parsingError("Unable to update Kimi CLI OAuth credentials.")
        }

        do {
            try data.write(to: fileURL, options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: fileURL.path
            )
        } catch {
            throw ProviderFetchError.credentialExpired(
                "Limit Counter needs read/write access to `~/.kimi-code` to save Kimi's rotated OAuth token. Import the folder again in Kimi settings."
            )
        }
    }
}

/// Reads Kimi CLI's local transcript files (`wire.jsonl`) and emits one
/// `UsageEvent` per assistant turn so the activity heatmap can render Kimi
/// activity alongside the API-fetched quota meters. Best-effort: returns []
/// when the sandbox denies access to the transcripts root.
private enum KimiLocalTranscriptReader {
    /// Heatmap window — only files modified within this lookback are scanned.
    private static let lookback: TimeInterval = 30 * 24 * 60 * 60
    /// Cap to keep parse time bounded on heavy users.
    private static let maxFiles = 80
    private static let maxEventsPerFile = 500
    /// Heatmap rows are 2-hour wide, matching `ClaudeHeatmapEventBucketer`.
    /// Aggregating per-turn events into per-bucket totals (a) avoids
    /// crowding 50+ messages into one cell with no visible benefit and
    /// (b) gives us a stable cross-fetch content fingerprint via the
    /// bucket's wall-clock start time. Same shape Claude uses.
    private static let bucketHours = 2

    /// Returns recent `UsageEvent`s found under `kimiRootURL/sessions/**/wire.jsonl`,
    /// aggregated into 2-hour heatmap buckets for visual consistency with Claude.
    /// Caller is responsible for any security-scoped access bracketing.
    static func loadEvents(kimiRootURL: URL) -> [UsageEvent] {
        let sessionsRoot = kimiRootURL.lastPathComponent == "sessions"
            ? kimiRootURL
            : kimiRootURL.appendingPathComponent("sessions")

        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: sessionsRoot.path) else {
            print("[KimiProvider] Local scan: sessions root not found at \(sessionsRoot.path)")
            return []
        }

        let cutoff = Date().addingTimeInterval(-lookback)
        guard let enumerator = fileManager.enumerator(
            at: sessionsRoot,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            print("[KimiProvider] Local scan: enumeration failed for \(sessionsRoot.path) (sandbox/permission?)")
            return []
        }

        var wireFiles: [(URL, Date)] = []
        for case let url as URL in enumerator where url.lastPathComponent == "wire.jsonl" {
            guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey]),
                  values.isRegularFile == true else { continue }
            let mtime = values.contentModificationDate ?? .distantPast
            guard mtime >= cutoff else { continue }
            wireFiles.append((url, mtime))
        }
        wireFiles.sort { $0.1 > $1.1 }
        let scanList = wireFiles.prefix(maxFiles)

        if wireFiles.isEmpty {
            print("[KimiProvider] Local scan: 0 wire.jsonl files under \(sessionsRoot.path) within 30-day window")
            return []
        }

        var perTurnEvents: [UsageEvent] = []
        for (url, _) in scanList {
            perTurnEvents.append(contentsOf: parseWireJSONL(at: url))
        }

        let bucketed = bucketEvents(perTurnEvents)

        if let oldest = bucketed.map(\.timestamp).min(),
           let newest = bucketed.map(\.timestamp).max() {
            print("[KimiProvider] Local scan: \(scanList.count) file(s), \(perTurnEvents.count) turns -> \(bucketed.count) heatmap buckets (oldest=\(oldest) newest=\(newest))")
        } else {
            print("[KimiProvider] Local scan: \(scanList.count) file(s) scanned but produced 0 heatmap buckets (no parseable StatusUpdate lines)")
        }

        return bucketed
    }

    /// Collapses per-turn `.message` events into 2-hour `.bucket` events
    /// keyed by local-time bucket start. Sums token counts within each
    /// bucket. Mirrors `ClaudeHeatmapEventBucketer`. The model field
    /// stays "Kimi" so `guessProviderFromModel` resolves correctly when
    /// the heatmap renders.
    private static func bucketEvents(_ events: [UsageEvent]) -> [UsageEvent] {
        guard !events.isEmpty else { return [] }
        let calendar = Calendar.current
        var totals: [Date: Double] = [:]

        for event in events {
            let bucketStart = bucketStart(for: event.timestamp, calendar: calendar)
            totals[bucketStart, default: 0] += event.tokens ?? 0
        }

        return totals
            .compactMap { bucketStart, tokens -> UsageEvent? in
                guard tokens > 0 else {
                    // Zero-token bucket: still surface as an activity
                    // marker so the heatmap shows Kimi was used in that
                    // window, even when token counts weren't reported.
                    return UsageEvent(
                        timestamp: bucketStart,
                        tokens: nil,
                        model: "Kimi",
                        type: .bucket
                    )
                }
                return UsageEvent(
                    timestamp: bucketStart,
                    tokens: tokens,
                    model: "Kimi",
                    type: .bucket
                )
            }
            .sorted { $0.timestamp > $1.timestamp }
    }

    private static func bucketStart(for date: Date, calendar: Calendar) -> Date {
        let dayStart = calendar.startOfDay(for: date)
        let hour = calendar.component(.hour, from: date)
        let bucketIndex = max(0, min(11, hour / bucketHours))
        return calendar.date(byAdding: .hour, value: bucketIndex * bucketHours, to: dayStart)
            ?? dayStart.addingTimeInterval(Double(bucketIndex * bucketHours * 3600))
    }

    /// Parses one `wire.jsonl` file. Emits a single `UsageEvent` per
    /// `StatusUpdate` line — that's the message Kimi CLI writes once per
    /// completed turn, and it contains the authoritative token counts.
    private static func parseWireJSONL(at url: URL) -> [UsageEvent] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        guard let text = String(data: data, encoding: .utf8) else { return [] }

        var events: [UsageEvent] = []
        events.reserveCapacity(64)

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: true) {
            if events.count >= maxEventsPerFile { break }
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty,
                  let lineData = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
                continue
            }

            guard let tsValue = json["timestamp"],
                  let timestampSec = numericValue(tsValue) else { continue }

            guard let message = json["message"] as? [String: Any],
                  let type = message["type"] as? String,
                  type == "StatusUpdate",
                  let payload = message["payload"] as? [String: Any] else {
                continue
            }

            let tokenUsage = payload["token_usage"] as? [String: Any]
            let inputOther     = numericValue(tokenUsage?["input_other"]) ?? 0
            let output         = numericValue(tokenUsage?["output"]) ?? 0
            let cacheRead      = numericValue(tokenUsage?["input_cache_read"]) ?? 0
            let cacheCreation  = numericValue(tokenUsage?["input_cache_creation"]) ?? 0
            let totalTokens    = inputOther + output + cacheRead + cacheCreation

            events.append(UsageEvent(
                timestamp: Date(timeIntervalSince1970: timestampSec),
                tokens: totalTokens > 0 ? totalTokens : nil,
                model: "Kimi",
                type: .message
            ))
        }
        return events
    }

    private static func numericValue(_ value: Any?) -> Double? {
        if let v = value as? Double { return v }
        if let v = value as? Int { return Double(v) }
        if let v = value as? NSNumber { return v.doubleValue }
        if let v = value as? String { return Double(v) }
        return nil
    }
}

enum KimiUsageNormalizer {
    static func snapshot(from data: Data, fetchedAt: Date = Date()) throws -> QuotaSnapshot {
        guard let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ProviderFetchError.parsingError("Kimi usage response was not a JSON object.")
        }
        return try snapshot(from: payload, fetchedAt: fetchedAt)
    }

    static func snapshot(from payload: [String: Any], fetchedAt: Date = Date()) throws -> QuotaSnapshot {
        var windows: [QuotaWindow] = []

        if let limits = payload["limits"] as? [[String: Any]] {
            for limit in limits {
                let detail = (limit["detail"] as? [String: Any]) ?? limit
                let window = limit["window"] as? [String: Any]
                let label = labelForLimitWindow(window)
                let subtitle = subtitleForLimitWindow(window)
                if let quotaWindow = quotaWindow(
                    label: label,
                    kind: .sliding,
                    detail: detail,
                    subtitle: subtitle
                ) {
                    windows.append(quotaWindow)
                }
            }
        }

        if let usage = payload["usage"] as? [String: Any],
           let weeklyWindow = quotaWindow(
                label: "Weekly",
                kind: .weekly,
                detail: usage,
                subtitle: "Kimi Code membership quota"
           ) {
            windows.append(weeklyWindow)
        }

        guard !windows.isEmpty else {
            throw ProviderFetchError.parsingError("Kimi usage response did not contain quota windows.")
        }

        var stats: [QuotaStat] = []
        if let parallel = payload["parallel"] as? [String: Any],
           let parallelLimit = number(parallel["limit"]) {
            stats.append(
                QuotaStat(
                    label: "Parallel Limit",
                    value: parallelLimit,
                    unit: "tasks",
                    subtitle: "Concurrent Kimi Code requests"
                )
            )
        }

        var balances: [QuotaBalance] = []
        if let totalQuota = payload["totalQuota"] as? [String: Any],
           let remaining = number(totalQuota["remaining"]) {
            let limit = number(totalQuota["limit"])
            balances.append(
                QuotaBalance(
                    label: "Total Quota",
                    amount: remaining,
                    unit: "quota",
                    subtitle: limit.map { "\($0.compactString) total membership quota" },
                    resetDate: nil
                )
            )
        }

        return QuotaSnapshot(
            providerID: .kimi,
            displayName: "Kimi Code",
            planName: planName(from: payload),
            windows: windows,
            stats: stats,
            balances: balances,
            fetchState: .success,
            fetchedAt: fetchedAt
        )
    }

    private static func quotaWindow(
        label: String,
        kind: QuotaWindowKind,
        detail: [String: Any],
        subtitle: String?
    ) -> QuotaWindow? {
        let limit = number(detail["limit"])
        let remaining = number(detail["remaining"])
        let explicitUsed = number(detail["used"])
        let resetDate = date(detail["resetTime"] ?? detail["reset_time"] ?? detail["resetAt"] ?? detail["reset_at"])

        guard limit != nil || remaining != nil || explicitUsed != nil else {
            return nil
        }

        let used: Double
        if let explicitUsed {
            if let limit {
                used = min(max(explicitUsed, 0), limit)
            } else {
                used = max(explicitUsed, 0)
            }
        } else if let limit, let remaining {
            used = min(max(limit - remaining, 0), limit)
        } else {
            used = 0
        }

        return QuotaWindow(
            label: label,
            windowKind: kind,
            used: used,
            total: limit,
            resetDate: resetDate,
            unit: "quota",
            subtitle: subtitle
        )
    }

    private static func labelForLimitWindow(_ window: [String: Any]?) -> String {
        guard let duration = number(window?["duration"]),
              let unit = string(window?["timeUnit"] ?? window?["time_unit"]) else {
            return "Rolling"
        }

        return durationLabel(duration: duration, timeUnit: unit) ?? "Rolling"
    }

    private static func subtitleForLimitWindow(_ window: [String: Any]?) -> String {
        guard let duration = number(window?["duration"]),
              let unit = string(window?["timeUnit"] ?? window?["time_unit"]),
              let label = durationLabel(duration: duration, timeUnit: unit)?.lowercased() else {
            return "Rolling quota window"
        }

        return "Rolling \(label) quota"
    }

    private static func durationLabel(duration: Double, timeUnit: String) -> String? {
        let unit = timeUnit.uppercased()
        let rounded = Int(duration.rounded())

        if unit.contains("MINUTE") {
            if rounded % 60 == 0 {
                return "\(rounded / 60)H"
            }
            return "\(rounded)M"
        }

        if unit.contains("HOUR") {
            return "\(rounded)H"
        }

        if unit.contains("DAY") {
            return "\(rounded)D"
        }

        return nil
    }

    private static func planName(from payload: [String: Any]) -> String? {
        let user = payload["user"] as? [String: Any]
        let membership = user?["membership"] as? [String: Any]
        if let level = string(membership?["level"]) {
            return membershipName(for: level)
        }
        if let subType = string(payload["subType"]) {
            return prettyRawName(subType, droppingPrefix: "TYPE_")
        }
        return nil
    }

    private static func membershipName(for rawLevel: String) -> String {
        switch rawLevel.uppercased() {
        case "LEVEL_FREE":
            return "Adagio"
        case "LEVEL_BEGINNER", "BEGINNER",
             "LEVEL_BASIC", "BASIC",
             "LEVEL_MODERATO", "MODERATO":
            return "Moderato"
        case "LEVEL_INTERMEDIATE", "INTERMEDIATE",
             "LEVEL_PRO", "PRO",
             "LEVEL_ALLEGRETTO", "ALLEGRETTO":
            return "Allegretto"
        case "LEVEL_ADVANCED", "ADVANCED",
             "LEVEL_MAX", "MAX",
             "LEVEL_ALLEGRO", "ALLEGRO":
            return "Allegro"
        case "LEVEL_ULTRA", "ULTRA",
             "LEVEL_VIVACE", "VIVACE":
            return "Vivace"
        default:
            return prettyRawName(rawLevel, droppingPrefix: "LEVEL_")
        }
    }

    private static func prettyRawName(_ raw: String, droppingPrefix prefix: String) -> String {
        let trimmed = raw.uppercased().hasPrefix(prefix) ? String(raw.dropFirst(prefix.count)) : raw
        return trimmed
            .split(separator: "_")
            .map { part in
                let lower = part.lowercased()
                return lower.prefix(1).uppercased() + lower.dropFirst()
            }
            .joined(separator: " ")
    }

    private static func number(_ value: Any?) -> Double? {
        if let value = value as? Double { return value }
        if let value = value as? Int { return Double(value) }
        if let value = value as? NSNumber { return value.doubleValue }
        if let value = value as? String { return Double(value.trimmingCharacters(in: .whitespacesAndNewlines)) }
        return nil
    }

    private static func string(_ value: Any?) -> String? {
        guard let value else { return nil }
        if let value = value as? String {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        return String(describing: value)
    }

    private static func date(_ value: Any?) -> Date? {
        guard var value = string(value) else { return nil }

        let fractionalPattern = #"(\.\d{6})\d+(Z|[+-]\d{2}:\d{2})$"#
        if let regex = try? NSRegularExpression(pattern: fractionalPattern),
           let match = regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)),
           match.numberOfRanges == 3,
           let fractionRange = Range(match.range(at: 1), in: value),
           let suffixRange = Range(match.range(at: 2), in: value) {
            value = String(value[..<fractionRange.lowerBound])
                + String(value[fractionRange])
                + String(value[suffixRange])
        }

        let fractionalFormatter = ISO8601DateFormatter()
        fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractionalFormatter.date(from: value) {
            return date
        }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }
}

// Legacy CodexImportService kept for backward compatibility
public enum CodexImportService {
    public typealias ImportError = CredentialImportService.ImportError
}

// MARK: - Codex Session Client

/// Fetches Codex usage via the ChatGPT-authenticated session (the "wham/usage" endpoint).
/// Returns 5-hour and 7-day rolling windows used by the Codex CLI.
public struct CodexSessionProviderClient: ProviderClient {
    public let providerID: ProviderID = .openai

    private let session: URLSession
    private let decoder = JSONDecoder()
    private let endpointURL = URL(string: "https://chatgpt.com/backend-api/wham/usage")!

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func fetchSnapshot(credentials: ProviderCredential?) async throws -> QuotaSnapshot {
        guard let credentials else { throw ProviderFetchError.notConfigured }
        guard let accessToken = credentials.normalizedAccessToken else {
            print("[CodexSessionProvider] Missing access token")
            throw ProviderFetchError.notConfigured
        }
        guard let accountID = credentials.normalizedAccountIdentifier else {
            print("[CodexSessionProvider] Missing account ID")
            throw ProviderFetchError.notConfigured
        }

        print("[CodexSessionProvider] Fetching usage for account: \(accountID.prefix(8))...")

        let request = makeRequest(accessToken: accessToken, accountID: accountID)
        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            print("[CodexSessionProvider] Invalid response type")
            throw ProviderFetchError.unknown
        }

        print("[CodexSessionProvider] HTTP status: \(httpResponse.statusCode)")

        switch httpResponse.statusCode {
        case 200..<300:
            break
        case 401, 403:
            print("[CodexSessionProvider] Authentication failed (\(httpResponse.statusCode))")
            throw ProviderFetchError.invalidCredential
        case 429:
            print("[CodexSessionProvider] Rate limited")
            throw ProviderFetchError.rateLimited
        default:
            print("[CodexSessionProvider] Unexpected status: \(httpResponse.statusCode)")
            if let responseBody = String(data: data, encoding: .utf8) {
                print("[CodexSessionProvider] Response: \(responseBody.prefix(500))")
            }
            throw ProviderFetchError.parsingError("HTTP \(httpResponse.statusCode)")
        }

        if let responseBody = String(data: data, encoding: .utf8) {
            print("[CodexSessionProvider] Response body (first 500 chars): \(responseBody.prefix(500))")
        }

        do {
            let payload = try decoder.decode(CodexUsagePayload.self, from: data)
            print("[CodexSessionProvider] Decoded payload - primary: \(payload.primaryWindow != nil), secondary: \(payload.secondaryWindow != nil)")
            return normalize(payload: payload, accountID: accountID)
        } catch {
            print("[CodexSessionProvider] Decode error: \(error)")
            throw ProviderFetchError.parsingError("Unable to decode Codex usage: \(error.localizedDescription)")
        }
    }

    private func makeRequest(accessToken: String, accountID: String) -> URLRequest {
        var request = URLRequest(url: endpointURL)
        request.httpMethod = "GET"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(accountID, forHTTPHeaderField: "chatgpt-account-id")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    private func normalize(payload: CodexUsagePayload, accountID: String) -> QuotaSnapshot {
        let now = Date()
        var aggregateWindows: [QuotaWindow] = []
        var additionalWindows: [QuotaWindow] = []
        var balances: [QuotaBalance] = []

        // The API's primary/secondary positions are not semantic. In the
        // current quota shape, the account-wide weekly allowance arrives as
        // primary_window; older payloads placed the same duration second.
        if let weekly = aggregateWeeklyWindow(in: payload) {
            aggregateWindows.append(
                quotaWindow(
                    from: weekly,
                    label: "Weekly",
                    windowKind: .weekly,
                    subtitle: "7-day rolling window"
                )
            )
        }

        for additionalLimit in payload.additionalRateLimits {
            guard let rateLimit = additionalLimit.rateLimit else { continue }
            let name = additionalLimit.displayName

            if isCodexSparkLimit(name), let weekly = weeklyWindow(in: rateLimit) {
                additionalWindows.append(
                    quotaWindow(
                        from: weekly,
                        label: "\(name) Weekly",
                        windowKind: .weekly,
                        subtitle: "7-day usage limit"
                    )
                )
            }

        }

        if let credits = payload.credits,
           let balance = credits.balance {
            balances.append(
                QuotaBalance(
                    label: "Credits Remaining",
                    amount: balance,
                    unit: "credits",
                    subtitle: "Use credits beyond plan limits"
                )
            )
        }

        return QuotaSnapshot(
            providerID: .openai,
            displayName: "Codex",
            planName: chatGPTPlanName(from: payload.planType),
            windows: aggregateWindows + additionalWindows,
            balances: balances,
            fetchState: .success,
            fetchedAt: now
        )
    }

    private func quotaWindow(
        from window: CodexWindow,
        label: String,
        windowKind: QuotaWindowKind,
        subtitle: String
    ) -> QuotaWindow {
        let totalSeconds = Double(window.limitWindowSeconds)
        let usedSeconds = totalSeconds * (window.usedPercent / 100.0)
        let resetDate = Date(timeIntervalSince1970: Double(window.resetAt))

        return QuotaWindow(
            label: label,
            windowKind: windowKind,
            used: usedSeconds / 3600.0,
            total: totalSeconds / 3600.0,
            resetDate: resetDate,
            unit: "hrs",
            subtitle: subtitle
        )
    }

    private func isCodexSparkLimit(_ name: String) -> Bool {
        let normalizedName = name.lowercased().filter { $0.isLetter || $0.isNumber }
        return normalizedName.contains("53codexspark")
    }

    private func aggregateWeeklyWindow(in payload: CodexUsagePayload) -> CodexWindow? {
        [payload.primaryWindow, payload.secondaryWindow]
            .compactMap { $0 }
            .first { $0.limitWindowSeconds >= 6 * 24 * 60 * 60 }
    }

    private func weeklyWindow(in rateLimit: CodexRateLimit) -> CodexWindow? {
        [rateLimit.primaryWindow, rateLimit.secondaryWindow]
            .compactMap { $0 }
            .first { $0.limitWindowSeconds >= 6 * 24 * 60 * 60 }
    }

    private func chatGPTPlanName(from planType: String?) -> String {
        guard let planType = planType?.trimmingCharacters(in: .whitespacesAndNewlines),
              !planType.isEmpty else {
            return "Plan"
        }

        switch planType.lowercased() {
        case "plus":
            return "Plus"
        case "pro":
            return "Pro"
        case "go":
            return "Go"
        case "free":
            return "Free"
        default:
            return planType.capitalized
        }
    }
}

// MARK: - Codex Usage Payload Models

private struct CodexUsagePayload: Decodable {
    let rateLimit: CodexRateLimit?
    let additionalRateLimits: [CodexAdditionalRateLimit]
    let credits: CodexCredits?
    let planType: String?

    enum CodingKeys: String, CodingKey {
        case rateLimit = "rate_limit"
        case additionalRateLimits = "additional_rate_limits"
        case credits
        case planType = "plan_type"
    }

    var primaryWindow: CodexWindow? { rateLimit?.primaryWindow }
    var secondaryWindow: CodexWindow? { rateLimit?.secondaryWindow }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        rateLimit = try container.decodeIfPresent(CodexRateLimit.self, forKey: .rateLimit)
        additionalRateLimits = try container.decodeIfPresent([CodexAdditionalRateLimit].self, forKey: .additionalRateLimits) ?? []
        credits = try container.decodeIfPresent(CodexCredits.self, forKey: .credits)
        planType = try container.decodeIfPresent(String.self, forKey: .planType)
    }
}

private struct CodexRateLimit: Decodable {
    let primaryWindow: CodexWindow?
    let secondaryWindow: CodexWindow?

    enum CodingKeys: String, CodingKey {
        case primaryWindow = "primary_window"
        case secondaryWindow = "secondary_window"
    }
}

private struct CodexAdditionalRateLimit: Decodable {
    let limitName: String?
    let meteredFeature: String?
    let rateLimit: CodexRateLimit?

    enum CodingKeys: String, CodingKey {
        case limitName = "limit_name"
        case meteredFeature = "metered_feature"
        case rateLimit = "rate_limit"
    }

    var displayName: String {
        let rawName = limitName ?? meteredFeature ?? "Additional Codex"
        let trimmed = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Additional Codex" : trimmed
    }
}

private struct CodexWindow: Decodable {
    let usedPercent: Double
    let limitWindowSeconds: Int
    let resetAfterSeconds: Int
    let resetAt: Int

    enum CodingKeys: String, CodingKey {
        case usedPercent = "used_percent"
        case limitWindowSeconds = "limit_window_seconds"
        case resetAfterSeconds = "reset_after_seconds"
        case resetAt = "reset_at"
    }
}

private struct CodexCredits: Decodable {
    let balance: Double?

    enum CodingKeys: String, CodingKey {
        case balance
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let numericBalance = try? container.decodeIfPresent(Double.self, forKey: .balance) {
            balance = numericBalance
        } else if let stringBalance = try? container.decodeIfPresent(String.self, forKey: .balance) {
            balance = Double(stringBalance)
        } else {
            balance = nil
        }
    }
}

// MARK: - Devin Provider Client

public struct DevinProviderClient: ProviderClient {
    public let providerID: ProviderID = .devin

    public init() {}

    public func fetchSnapshot(credentials: ProviderCredential?) async throws -> QuotaSnapshot {
        print("[DevinProvider] Reading cached plan info from local state DB...")

        // Check if user has configured a custom file path
        var customPath: URL?
        var bookmarkData: Data?
        if let path = credentials?.customEndpoint, !path.isEmpty {
            customPath = URL(fileURLWithPath: path)
            print("[DevinProvider] Using configured file path: \(path)")
        }
        // Check for bookmark data in extraFields
        if let bookmarkBase64 = credentials?.extraFields?["bookmarkData"],
           let data = Data(base64Encoded: bookmarkBase64) {
            bookmarkData = data
            print("[DevinProvider] Found security-scoped bookmark data")
        }

        do {
            let states = try DevinLocalStateReader.loadCachedPlanInfo(customPath: customPath, bookmarkData: bookmarkData)
            // Each fetch produces at most one `lastSessionDate` activity
            // marker, and the underlying SQLite value is overwritten when
            // a new session starts — so without enrichment the heatmap
            // only ever shows the most recent session. Merging in prior
            // snapshots' events lets us accumulate session markers over
            // time (content-deduped, so repeating the same lastSessionDate
            // across many fetches collapses to a single marker).
            let multiUser = states.count > 1
            let merged = mergeSnapshots(states, multiUser: multiUser)
            return enrichEventsWithHistory(merged)
        } catch {
            print("[DevinProvider] Failed to read cached plan info: \(error.localizedDescription)")
            throw error as? ProviderFetchError ?? .parsingError(error.localizedDescription)
        }
    }

    private func mergeSnapshots(_ states: [DevinStateSnapshot], multiUser: Bool) -> QuotaSnapshot {
        guard let first = states.first else {
            return QuotaSnapshot(
                providerID: .devin,
                displayName: "Devin",
                planName: "Unknown",
                windows: [],
                stats: [],
                balances: [],
                signals: [],
                events: [],
                fetchState: .success,
                fetchedAt: Date()
            )
        }
        if states.count == 1 {
            return makeSnapshot(from: first, userLabel: nil)
        }
        // Multiple accounts: merge all windows/balances/stats/signals/events
        var allWindows: [QuotaWindow] = []
        var allBalances: [QuotaBalance] = []
        var allStats: [QuotaStat] = []
        var allSignals: [QuotaSignal] = []
        var allEvents: [UsageEvent] = []
        var planNames: [String] = []
        for state in states {
            let label = Self.shortUserLabel(from: state.planInfo.accountIdentityText)
            let snap = makeSnapshot(from: state, userLabel: label)
            allWindows.append(contentsOf: snap.windows)
            allBalances.append(contentsOf: snap.balances)
            allStats.append(contentsOf: snap.stats)
            allSignals.append(contentsOf: snap.signals)
            allEvents.append(contentsOf: snap.events)
            if let pName = snap.planName, !planNames.contains(pName) {
                planNames.append(pName)
            }
        }
        return QuotaSnapshot(
            providerID: .devin,
            displayName: "Devin",
            planName: planNames.joined(separator: " / "),
            windows: allWindows,
            stats: allStats,
            balances: allBalances,
            signals: allSignals,
            events: allEvents,
            fetchState: .success,
            fetchedAt: Date()
        )
    }

    private static func shortUserLabel(from accountIdentityText: String?) -> String {
        guard let text = accountIdentityText, !text.isEmpty else { return "Unknown" }
        // Format is "email - Display Name" or "email - email"
        let parts = text.components(separatedBy: " - ")
        if parts.count >= 2 {
            let name = parts[1].trimmingCharacters(in: .whitespaces)
            // If the name is the same as the email, use the local part
            if name.contains("@") {
                return String(name.prefix(while: { $0 != "@" }))
            }
            return name
        }
        // Fallback: use local part of email
        if text.contains("@") {
            return String(text.prefix(while: { $0 != "@" }))
        }
        return text
    }

    private func makeSnapshot(from state: DevinStateSnapshot, userLabel: String?) -> QuotaSnapshot {
        let planInfo = state.planInfo
        let localMetadata = state.localMetadata
        let now = Date()
        var windows: [QuotaWindow] = []
        var balances: [QuotaBalance] = []
        var stats: [QuotaStat] = []
        var signals: [QuotaSignal] = []

        var dailyUsedPercent: Double? = nil
        var dailyResetDate: Date? = nil

        if let remaining = planInfo.quotaUsage?.dailyRemainingPercent {
            dailyUsedPercent = max(0, 100 - Double(remaining))
            dailyResetDate = planInfo.quotaUsage?.dailyResetAtUnix.map { Date(timeIntervalSince1970: TimeInterval($0)) }
        } else if let usage = planInfo.usage, usage.messages > 0 {
            dailyUsedPercent = (Double(usage.usedMessages) / Double(usage.messages)) * 100
        }

        if !planInfo.hideDailyQuota, let used = dailyUsedPercent {
            let resetDate = dailyResetDate ?? Date(timeIntervalSince1970: TimeInterval(planInfo.endTimestamp / 1000))
            windows.append(
                QuotaWindow(
                    label: userLabel.map { "Daily quota (\($0))" } ?? "Daily quota usage",
                    windowKind: .session,
                    used: used,
                    total: 100,
                    resetDate: resetDate,
                    unit: "%",
                    subtitle: "Resets daily"
                )
            )
        }

        var weeklyUsedPercent: Double? = nil
        var weeklyResetDate: Date? = nil

        if let remaining = planInfo.quotaUsage?.weeklyRemainingPercent {
            weeklyUsedPercent = max(0, 100 - Double(remaining))
            weeklyResetDate = planInfo.quotaUsage?.weeklyResetAtUnix.map { Date(timeIntervalSince1970: TimeInterval($0)) }
        } else if let usage = planInfo.usage, usage.flowActions > 0 {
            weeklyUsedPercent = (Double(usage.usedFlowActions) / Double(usage.flowActions)) * 100
        }

        if !planInfo.hideWeeklyQuota, let used = weeklyUsedPercent {
            let resetDate = weeklyResetDate ?? Date(timeIntervalSince1970: TimeInterval(planInfo.endTimestamp / 1000))
            windows.append(
                QuotaWindow(
                    label: userLabel.map { "Weekly quota (\($0))" } ?? "Weekly quota usage",
                    windowKind: .weekly,
                    used: used,
                    total: 100,
                    resetDate: resetDate,
                    unit: "%",
                    subtitle: "Resets weekly"
                )
            )
        }

        if let overageBalanceMicros = planInfo.quotaUsage?.overageBalanceMicros {
            let balance = Double(overageBalanceMicros) / 1_000_000.0
            balances.append(
                QuotaBalance(
                    label: userLabel.map { "Extra usage (\($0))" } ?? "Extra usage balance",
                    amount: balance,
                    unit: "$",
                    subtitle: "Extra usage balance",
                    resetDate: Date(timeIntervalSince1970: TimeInterval(planInfo.endTimestamp / 1000))
                )
            )
        }

        if let usage = planInfo.usage {
            stats.append(
                QuotaStat(
                    label: "Messages Allowed",
                    value: Double(usage.messages),
                    unit: "msgs",
                    subtitle: "Plan limit"
                )
            )
            stats.append(
                QuotaStat(
                    label: "Messages Used",
                    value: Double(usage.usedMessages),
                    unit: "msgs",
                    subtitle: "Consumed so far"
                )
            )
            stats.append(
                QuotaStat(
                    label: "Messages Remaining",
                    value: Double(usage.remainingMessages ?? 0),
                    unit: "msgs",
                    subtitle: "Still available"
                )
            )
            stats.append(
                QuotaStat(
                    label: "Flow Actions Allowed",
                    value: Double(usage.flowActions),
                    unit: "actions",
                    subtitle: "Plan limit"
                )
            )
            stats.append(
                QuotaStat(
                    label: "Flow Actions Used",
                    value: Double(usage.usedFlowActions),
                    unit: "actions",
                    subtitle: "Consumed so far"
                )
            )
            stats.append(
                QuotaStat(
                    label: "Flow Actions Remaining",
                    value: Double(usage.remainingFlowActions ?? 0),
                    unit: "actions",
                    subtitle: "Still available"
                )
            )
            stats.append(
                QuotaStat(
                    label: "Flex Credits Allowed",
                    value: Double(usage.flexCredits),
                    unit: "credits",
                    subtitle: "Plan limit"
                )
            )
            stats.append(
                QuotaStat(
                    label: "Flex Credits Used",
                    value: Double(usage.usedFlexCredits),
                    unit: "credits",
                    subtitle: "Consumed so far"
                )
            )
            stats.append(
                QuotaStat(
                    label: "Flex Credits Remaining",
                    value: Double(usage.remainingFlexCredits ?? 0),
                    unit: "credits",
                    subtitle: "Still available"
                )
            )
        }

        if let teamsTier = planInfo.teamsTier {
            stats.append(
                QuotaStat(
                    label: "Team Tier",
                    value: Double(teamsTier),
                    unit: "tier",
                    subtitle: "Plan tier"
                )
            )
        }

        if let spaceCount = localMetadata?.spaceCount {
            stats.append(
                QuotaStat(
                    label: "Workspace Spaces",
                    value: Double(spaceCount),
                    unit: "spaces",
                    subtitle: "Cached cascade/workspace entries"
                )
            )
        }

        if let resourceLinkCount = localMetadata?.resourceLinkCount {
            stats.append(
                QuotaStat(
                    label: "Resource Links",
                    value: Double(resourceLinkCount),
                    unit: "links",
                    subtitle: "Local resources mapped to spaces"
                )
            )
        }

        if let latestSpaceAccessDate = localMetadata?.latestSpaceAccessDate {
            let daysSinceAccess = max(0, Date().timeIntervalSince(latestSpaceAccessDate) / 86_400)
            stats.append(
                QuotaStat(
                    label: "Space Activity Age",
                    value: daysSinceAccess,
                    unit: "days",
                    subtitle: "Since the newest tracked access"
                )
            )
        }

        if let lastSessionDate = localMetadata?.lastSessionDate {
            let daysSinceSession = max(0, Date().timeIntervalSince(lastSessionDate) / 86_400)
            stats.append(
                QuotaStat(
                    label: "Session Age",
                    value: daysSinceSession,
                    unit: "days",
                    subtitle: "Since Devin telemetry last recorded activity"
                )
            )
        }

        if planInfo.hasBillingWritePermissions == true {
            signals.append(
                QuotaSignal(
                    kind: .unexpectedRecovery,
                    title: "Billing write permissions enabled",
                    message: "The local Devin cache reports billing write access is available.",
                    severity: .info,
                    detectedAt: now
                )
            )
        }

        if let gracePeriodStatus = planInfo.gracePeriodStatus, gracePeriodStatus != 0 {
            signals.append(
                QuotaSignal(
                    kind: .unexpectedRecovery,
                    title: "Grace period state \(gracePeriodStatus)",
                    message: "The local cache reports a non-zero grace period status.",
                    severity: .info,
                    detectedAt: now
                )
            )
        }

        var events: [UsageEvent] = []
        if let lastSessionDate = localMetadata?.lastSessionDate {
            events.append(UsageEvent(timestamp: lastSessionDate, type: .activity))
        }

        return QuotaSnapshot(
            providerID: .devin,
            displayName: "Devin",
            planName: planInfo.planName,
            windows: windows,
            stats: stats,
            balances: balances,
            signals: signals,
            events: events,
            fetchState: .success,
            fetchedAt: now
        )
    }
}

private enum DevinLocalStateReader {
    static func loadCachedPlanInfo(customPath: URL? = nil, bookmarkData: Data? = nil) throws -> [DevinStateSnapshot] {
        print("[DevinLocalStateReader] Searching for state.vscdb...")

        // If we have bookmark data, resolve it first (this gives us sandbox access)
        if let bookmarkData = bookmarkData {
            print("[DevinLocalStateReader] Resolving security-scoped bookmark...")
            do {
                let resolvedURL = try resolveSecurityScopedURL(from: bookmarkData)
                print("[DevinLocalStateReader] Resolved bookmark to: \(resolvedURL.path)")

                // Start accessing the security-scoped resource
                let accessGranted = resolvedURL.startAccessingSecurityScopedResource()
                defer {
                    if accessGranted {
                        resolvedURL.stopAccessingSecurityScopedResource()
                        print("[DevinLocalStateReader] Stopped accessing security-scoped resource")
                    }
                }

                if accessGranted {
                    print("[DevinLocalStateReader] Security-scoped access granted")
                    let bookmarkLoadURL = resolvedDatabaseURL(
                        bookmarkURL: resolvedURL,
                        customPath: customPath
                    )
                    let states = try loadAllCachedPlanInfos(from: bookmarkLoadURL)
                    if !states.isEmpty {
                        print("[DevinLocalStateReader] Successfully loaded \(states.count) account(s) from bookmark")
                        return states
                    }
                } else {
                    print("[DevinLocalStateReader] Failed to get security-scoped access")
                }
            } catch {
                print("[DevinLocalStateReader] Failed to resolve bookmark: \(error)")
            }
        }

        // If user provided a custom path, try that next
        if let customPath = customPath {
            print("[DevinLocalStateReader] Trying user-provided path: \(customPath.path)")
            print("[DevinLocalStateReader] Exists: \(FileManager.default.fileExists(atPath: customPath.path))")
            print("[DevinLocalStateReader] Readable: \(FileManager.default.isReadableFile(atPath: customPath.path))")

            let states = try loadAllCachedPlanInfos(from: customPath)
            if !states.isEmpty {
                print("[DevinLocalStateReader] Successfully loaded \(states.count) account(s) from user-provided path")
                return states
            }
            print("[DevinLocalStateReader] Failed to load from user-provided path, will try auto-discovery")
        }

        // Fall back to auto-discovery (won't work in sandboxed apps, but useful for non-sandboxed builds)
        for url in possibleStateDatabaseURLs() {
            print("[DevinLocalStateReader] Checking: \(url.path)")
            print("[DevinLocalStateReader] Exists: \(FileManager.default.fileExists(atPath: url.path))")
            print("[DevinLocalStateReader] Readable: \(FileManager.default.isReadableFile(atPath: url.path))")

            let states = try loadAllCachedPlanInfos(from: url)
            if !states.isEmpty {
                print("[DevinLocalStateReader] Successfully loaded \(states.count) account(s) from: \(url.path)")
                return states
            }
        }

        print("[DevinLocalStateReader] Could not find or read state.vscdb from any location")
        throw ProviderFetchError.notConfigured
    }

    private static func resolvedDatabaseURL(bookmarkURL: URL, customPath: URL?) -> URL {
        if isDirectory(bookmarkURL), let customPath {
            return customPath
        }
        return bookmarkURL
    }

    private static func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            return false
        }
        return isDirectory.boolValue
    }

    private static func possibleStateDatabaseURLs() -> [URL] {
        // In sandboxed apps, these paths won't work - user must provide file via picker
        // But we keep this for non-sandboxed builds or if the user has granted permanent access
        var paths: [URL] = []

        // Primary location (real user home, not container)
        // Note: In sandboxed apps, homeDirectoryForCurrentUser returns the container path
        let realHome = URL(fileURLWithPath: NSHomeDirectory().replacingOccurrences(of: "/Library/Containers/", with: "").components(separatedBy: "/").dropLast(3).joined(separator: "/"))
        paths.append(realHome.appendingPathComponent("Library/Application Support/Devin/User/globalStorage/state.vscdb"))
        paths.append(realHome.appendingPathComponent("Library/Application Support/Devin/User/globalStorage/state.vscdb.backup"))

        return paths
    }

    private static func loadAllCachedPlanInfos(from url: URL) throws -> [DevinStateSnapshot] {
        guard FileManager.default.isReadableFile(atPath: url.path) else {
            print("[DevinLocalStateReader] File not readable: \(url.path)")
            return []
        }

        var db: OpaquePointer?
        let result = sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil)
        guard result == SQLITE_OK, let db else {
            print("[DevinLocalStateReader] Failed to open DB: \(result)")
            if let db { sqlite3_close(db) }
            return []
        }
        defer { sqlite3_close(db) }

        // First try to get all per-user reactSettings entries (new Devin format)
        let reactQuery = """
        SELECT value FROM ItemTable
        WHERE key LIKE '%reactSettings.cachedPlanInfoData:user-%'
        ORDER BY LENGTH(value) DESC;
        """
        var snapshots = try decodeAllRows(db: db, query: reactQuery)
        if !snapshots.isEmpty {
            print("[DevinLocalStateReader] Found \(snapshots.count) reactSettings user account(s)")
            // Load shared local metadata once
            let localMetadata = try loadLocalMetadata(from: db)
            return snapshots.map { DevinStateSnapshot(planInfo: $0, localMetadata: localMetadata) }
        }

        // Fallback: try legacy keys
        let legacyQuery = """
        SELECT value FROM ItemTable 
        WHERE key IN ('devin.settings.cachedPlanInfo', 'windsurf.settings.cachedPlanInfo', 'codeium.settings.cachedPlanInfo', 'cachedPlanInfo')
        OR key LIKE '%PlanInfo%' 
        ORDER BY CASE 
            WHEN key LIKE 'devin.%' THEN 1 
            WHEN key LIKE 'windsurf.%' THEN 2 
            WHEN key LIKE 'codeium.%' THEN 3 
            ELSE 4 
        END
        LIMIT 1;
        """
        snapshots = try decodeAllRows(db: db, query: legacyQuery)
        if !snapshots.isEmpty {
            let localMetadata = try loadLocalMetadata(from: db)
            return snapshots.map { DevinStateSnapshot(planInfo: $0, localMetadata: localMetadata) }
        }

        print("[DevinLocalStateReader] No plan info rows found")
        return []
    }

    private static func decodeAllRows(db: OpaquePointer, query: String) throws -> [DevinCachedPlanInfo] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK, let statement else {
            print("[DevinLocalStateReader] Failed to prepare statement")
            return []
        }
        defer { sqlite3_finalize(statement) }

        var results: [DevinCachedPlanInfo] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let textPointer = sqlite3_column_text(statement, 0) else {
                print("[DevinLocalStateReader] No text in column, skipping row")
                continue
            }
            let jsonString = String(cString: textPointer)
            print("[DevinLocalStateReader] Got JSON (first 200 chars): \(jsonString.prefix(200))")

            guard let data = jsonString.data(using: .utf8) else {
                print("[DevinLocalStateReader] Failed to convert to data, skipping row")
                continue
            }
            do {
                let planInfo = try JSONDecoder().decode(DevinCachedPlanInfo.self, from: data)
                print("[DevinLocalStateReader] Successfully decoded plan: \(planInfo.planName) (\(planInfo.accountIdentityText ?? "no identity"))")
                results.append(planInfo)
            } catch {
                print("[DevinLocalStateReader] JSON decode error for row: \(error)")
            }
        }
        return results
    }

    private static func loadLocalMetadata(from db: OpaquePointer) throws -> DevinLocalMetadata {
        let spaceMetadata = try loadJSONDictionary(from: db, keys: ["devinSpace.metadata", "windsurfSpace.metadata"])
        let resourceToSpace = try loadJSONObject(from: db, keys: ["devinSpace.resourceToSpace", "windsurfSpace.resourceToSpace"])
        let lastSessionDate = try loadDate(from: db, key: "telemetry.lastSessionDate")

        let latestSpaceAccessDate = spaceMetadata?.values
            .compactMap { $0["lastAccessed"] as? Double }
            .map { Date(timeIntervalSince1970: $0 / 1000) }
            .max()

        return DevinLocalMetadata(
            spaceCount: spaceMetadata?.count,
            resourceLinkCount: resourceToSpace?.count,
            latestSpaceAccessDate: latestSpaceAccessDate,
            lastSessionDate: lastSessionDate
        )
    }

    private static func loadJSONObject(from db: OpaquePointer, keys: [String]) throws -> [String: Any]? {
        guard let text = try loadTextValue(from: db, keys: keys),
              let data = text.data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return object
    }

    private static func loadJSONDictionary(from db: OpaquePointer, keys: [String]) throws -> [String: [String: Any]]? {
        guard let object = try loadJSONObject(from: db, keys: keys) else {
            return nil
        }

        var result: [String: [String: Any]] = [:]
        for (key, value) in object {
            if let nested = value as? [String: Any] {
                result[key] = nested
            }
        }
        return result
    }

    private static func loadTextValue(from db: OpaquePointer, key: String) throws -> String? {
        return try loadTextValue(from: db, keys: [key])
    }

    private static func loadTextValue(from db: OpaquePointer, keys: [String]) throws -> String? {
        let placeholders = keys.map { _ in "?" }.joined(separator: ", ")
        let caseClauses = keys.enumerated().map { "WHEN key = ? THEN \($0.offset)" }.joined(separator: " ")
        let query = "SELECT value FROM ItemTable WHERE key IN (\(placeholders)) ORDER BY CASE \(caseClauses) ELSE \(keys.count) END LIMIT 1;"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw ProviderFetchError.parsingError("Failed to prepare Devin metadata query.")
        }
        defer { sqlite3_finalize(statement) }

        let transientDestructor = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        var bindIndex: Int32 = 1
        
        // Bind for the IN clause
        for key in keys {
            key.withCString { cString in
                sqlite3_bind_text(statement, bindIndex, cString, -1, transientDestructor)
            }
            bindIndex += 1
        }
        
        // Bind for the ORDER BY CASE clause
        for key in keys {
            key.withCString { cString in
                sqlite3_bind_text(statement, bindIndex, cString, -1, transientDestructor)
            }
            bindIndex += 1
        }

        guard sqlite3_step(statement) == SQLITE_ROW else {
            return nil
        }

        guard let textPointer = sqlite3_column_text(statement, 0) else {
            return nil
        }

        return String(cString: textPointer)
    }

    private static func loadDate(from db: OpaquePointer, key: String) throws -> Date? {
        guard let text = try loadTextValue(from: db, key: key)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else {
            return nil
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter.date(from: text)
    }

    private static func resolveSecurityScopedURL(from bookmarkData: Data) throws -> URL {
        #if os(macOS)
        var isStale = false
        return try URL(
            resolvingBookmarkData: bookmarkData,
            options: .withSecurityScope,
            bookmarkDataIsStale: &isStale
        )
        #else
        throw ProviderFetchError.notConfigured
        #endif
    }
}

private struct DevinCachedPlanInfo: Decodable {
    let planName: String
    let startTimestamp: Int
    let endTimestamp: Int
    let usage: DevinUsageSummary?
    let quotaUsage: DevinQuotaUsage?
    let hasBillingWritePermissions: Bool?
    let gracePeriodStatus: Int?
    let teamsTier: Int?
    let hideDailyQuota: Bool
    let hideWeeklyQuota: Bool
    let accountIdentityText: String?

    enum CodingKeys: String, CodingKey {
        case planName
        case startTimestamp
        case endTimestamp
        case usage
        case quotaUsage
        case hasBillingWritePermissions
        case gracePeriodStatus
        case teamsTier
        case hideDailyQuota
        case hideWeeklyQuota
        case accountIdentityText
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        planName = (try? container.decodeIfPresent(String.self, forKey: .planName)) ?? "Unknown"
        startTimestamp = (try? container.decodeIfPresent(Int.self, forKey: .startTimestamp)) ?? 0
        endTimestamp = (try? container.decodeIfPresent(Int.self, forKey: .endTimestamp)) ?? 0
        hasBillingWritePermissions = try? container.decodeIfPresent(Bool.self, forKey: .hasBillingWritePermissions)
        gracePeriodStatus = try? container.decodeIfPresent(Int.self, forKey: .gracePeriodStatus)
        teamsTier = try? container.decodeIfPresent(Int.self, forKey: .teamsTier)
        accountIdentityText = try? container.decodeIfPresent(String.self, forKey: .accountIdentityText)
        hideDailyQuota = (try? container.decodeIfPresent(Bool.self, forKey: .hideDailyQuota)) ?? false
        hideWeeklyQuota = (try? container.decodeIfPresent(Bool.self, forKey: .hideWeeklyQuota)) ?? false
        
        if let qUsage = try? container.decodeIfPresent(DevinQuotaUsage.self, forKey: .quotaUsage) {
            quotaUsage = qUsage
        } else {
            quotaUsage = try? DevinQuotaUsage(from: decoder)
        }
        
        if let u = try? container.decodeIfPresent(DevinUsageSummary.self, forKey: .usage) {
            usage = u
        } else {
            usage = try? DevinUsageSummary(from: decoder)
        }
    }
}

private struct DevinStateSnapshot {
    let planInfo: DevinCachedPlanInfo
    let localMetadata: DevinLocalMetadata?
}

private struct DevinLocalMetadata {
    let spaceCount: Int?
    let resourceLinkCount: Int?
    let latestSpaceAccessDate: Date?
    let lastSessionDate: Date?
}

private struct DevinUsageSummary: Decodable {
    let duration: Int
    let messages: Int
    let flowActions: Int
    let flexCredits: Int
    let usedMessages: Int
    let usedFlowActions: Int
    let usedFlexCredits: Int
    let remainingMessages: Int?
    let remainingFlowActions: Int?
    let remainingFlexCredits: Int?
}

private struct DevinQuotaUsage: Decodable {
    let dailyRemainingPercent: Int?
    let weeklyRemainingPercent: Int?
    let overageBalanceMicros: Int?
    let dailyResetAtUnix: Int?
    let weeklyResetAtUnix: Int?

    enum CodingKeys: String, CodingKey {
        case dailyRemainingPercent = "dailyRemainingPercent"
        case weeklyRemainingPercent = "weeklyRemainingPercent"
        case overageBalanceMicros = "overageBalanceMicros"
        case dailyResetAtUnix = "dailyResetAtUnix"
        case weeklyResetAtUnix = "weeklyResetAtUnix"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        
        // Try camelCase first, fallback to snake_case equivalent manually if needed
        // (If the JSON happens to use snake_case keys in newer builds)
        if let val = try? container.decodeIfPresent(Int.self, forKey: .dailyRemainingPercent) { dailyRemainingPercent = val }
        else {
            let dynamic = try decoder.container(keyedBy: DynamicKey.self)
            dailyRemainingPercent = try dynamic.decodeIfPresent(Int.self, forKey: DynamicKey(stringValue: "daily_remaining_percent")!)
        }
        
        if let val = try? container.decodeIfPresent(Int.self, forKey: .weeklyRemainingPercent) { weeklyRemainingPercent = val }
        else {
            let dynamic = try decoder.container(keyedBy: DynamicKey.self)
            weeklyRemainingPercent = try dynamic.decodeIfPresent(Int.self, forKey: DynamicKey(stringValue: "weekly_remaining_percent")!)
        }
        
        if let val = try? container.decodeIfPresent(Int.self, forKey: .overageBalanceMicros) { overageBalanceMicros = val }
        else {
            let dynamic = try decoder.container(keyedBy: DynamicKey.self)
            overageBalanceMicros = try dynamic.decodeIfPresent(Int.self, forKey: DynamicKey(stringValue: "overage_balance_micros")!)
        }
        
        if let val = try? container.decodeIfPresent(Int.self, forKey: .dailyResetAtUnix) { dailyResetAtUnix = val }
        else {
            let dynamic = try decoder.container(keyedBy: DynamicKey.self)
            dailyResetAtUnix = try dynamic.decodeIfPresent(Int.self, forKey: DynamicKey(stringValue: "daily_reset_at_unix")!)
        }
        
        if let val = try? container.decodeIfPresent(Int.self, forKey: .weeklyResetAtUnix) { weeklyResetAtUnix = val }
        else {
            let dynamic = try decoder.container(keyedBy: DynamicKey.self)
            weeklyResetAtUnix = try dynamic.decodeIfPresent(Int.self, forKey: DynamicKey(stringValue: "weekly_reset_at_unix")!)
        }
    }
}

private struct DynamicKey: CodingKey {
    var stringValue: String
    init?(stringValue: String) { self.stringValue = stringValue }
    var intValue: Int? { return nil }
    init?(intValue: Int) { return nil }
}

private struct CursorLocalStateSnapshot {
    let accessToken: String?
    let cachedEmail: String?
    let membershipType: String?
    let signUpType: String?
    let authSubject: String?
    let sessionExpiry: Date?
    let uniqueCursorUserID: String?
    let aiTrackingDayCount30d: Int
    let composerSuggestedLines30d: Int
    let composerAcceptedLines30d: Int
    let tabSuggestedLines30d: Int
    let tabAcceptedLines30d: Int
    let dailyStats: [CursorDailyStat]
    let recentCommit: CursorRecentCommitMetadata?
}

private struct CursorDailyStat {
    let date: Date
    let tabSuggestedLines: Int
    let tabAcceptedLines: Int
    let composerSuggestedLines: Int
    let composerAcceptedLines: Int

    var numRequests: Double {
        Double(tabSuggestedLines + composerSuggestedLines)
    }

    init?(json: [String: Any]) {
        guard let rawDate = json["date"] as? String else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        guard let date = formatter.date(from: rawDate) else { return nil }

        self.date = date
        self.tabSuggestedLines = CursorRecentCommitMetadata.intValue(json["tabSuggestedLines"])
        self.tabAcceptedLines = CursorRecentCommitMetadata.intValue(json["tabAcceptedLines"])
        self.composerSuggestedLines = CursorRecentCommitMetadata.intValue(json["composerSuggestedLines"])
        self.composerAcceptedLines = CursorRecentCommitMetadata.intValue(json["composerAcceptedLines"])
    }
}

private struct CursorRecentCommitMetadata {
    let aiPercentage: Double?

    init?(json: [String: Any]) {
        self.aiPercentage = CursorRecentCommitMetadata.doubleValue(json["aiPercentage"])
        if aiPercentage == nil {
            return nil
        }
    }

    static func intValue(_ value: Any?) -> Int {
        if let value = value as? Int { return value }
        if let value = value as? Double { return Int(value) }
        if let value = value as? NSNumber { return value.intValue }
        if let value = value as? String, let parsed = Int(value) { return parsed }
        return 0
    }

    static func doubleValue(_ value: Any?) -> Double? {
        if let value = value as? Double { return value }
        if let value = value as? Int { return Double(value) }
        if let value = value as? NSNumber { return value.doubleValue }
        if let value = value as? String { return Double(value) }
        return nil
    }
}

// MARK: - Cursor Provider Client

/// Reads a Cursor web session cookie or local state token and fetches usage.
public struct CursorProviderClient: ProviderClient {
    public let providerID: ProviderID = .cursor

    private let session: URLSession
    private let decoder = JSONDecoder()
    private let cursorUsageAuthRequirementMessage = "Cursor live usage needs a real web session cookie or dashboard-auth token. The local editor DB can still provide cached metadata."

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func fetchSnapshot(credentials: ProviderCredential?) async throws -> QuotaSnapshot {
        print("[CursorProvider] Starting fetch...")
        let localState = try? await loadLocalStateSnapshot(credentials: credentials)

        // PRIMARY: modern dashboard usage endpoint (percentage model).
        // Cursor migrated from the legacy per-model request counts to a
        // spend/percentage model (Included-in-Pro / Auto+Composer / API).
        // The legacy `GET /api/usage` now returns zeros, which is why the
        // card only showed the placeholder. The modern data lives behind
        // a Connect-RPC endpoint authenticated with the access token that
        // the Cursor editor stores in `state.vscdb`.
        if let accessToken = localState?.accessToken, !accessToken.isEmpty {
            do {
                let modern = try await fetchModernCursorUsage(accessToken: accessToken, localState: localState)
                print("[CursorProvider] Modern usage endpoint succeeded")
                return modern
            } catch {
                print("[CursorProvider] Modern usage endpoint failed (\(error.localizedDescription)) — falling back to legacy path")
            }
        }

        // Try to get a real web credential first. The local editor DB remains a
        // metadata source unless the user explicitly imports a web session or
        // dashboard token.
        let auth = try await getAuthMaterial(credentials: credentials, localState: localState)

        if case .localMetadataOnly = auth {
            return cursorLocalMetadataSnapshot(
                localState: localState,
                now: Date(),
                authNote: cursorUsageAuthRequirementMessage
            )
        }

        print("[CursorProvider] Got auth material, making API call...")

        // Cursor API endpoint for usage
        let url = URL(string: "https://cursor.com/api/usage")!
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        switch auth {
        case .cookie(let cookieHeader):
            request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
            request.setValue("https://cursor.com", forHTTPHeaderField: "Origin")
            request.setValue("https://cursor.com", forHTTPHeaderField: "Referer")
        case .bearer(let token):
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        case .localMetadataOnly:
            break
        }

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ProviderFetchError.networkError(underlying: NSError(domain: "CursorProvider", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid response"]))
        }

        print("[CursorProvider] HTTP status: \(httpResponse.statusCode)")

        guard httpResponse.statusCode == 200 else {
            if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
                if localState != nil {
                    return cursorLocalMetadataSnapshot(
                        localState: localState,
                        now: Date(),
                        authNote: cursorUsageAuthRequirementMessage
                    )
                }

                throw ProviderFetchError.parsingError(
                    cursorUsageAuthRequirementMessage
                )
            }
            throw ProviderFetchError.networkError(underlying: NSError(domain: "CursorProvider", code: httpResponse.statusCode, userInfo: [NSLocalizedDescriptionKey: "HTTP \(httpResponse.statusCode)"]))
        }

        return try parseUsageResponse(data: data, localState: localState)
    }

    /// Modern Cursor usage via the dashboard Connect-RPC endpoint.
    /// Returns the same percentage model the cursor.com/dashboard UI
    /// shows: Included-in-Pro total %, Auto+Composer %, API %, billing
    /// cycle reset date, and on-demand spend limits.
    ///
    /// This is a reverse-engineered, undocumented endpoint (the same
    /// one the dashboard itself calls). It can change without notice —
    /// callers fall back to the legacy `/api/usage` path on any error.
    private func fetchModernCursorUsage(
        accessToken: String,
        localState: CursorLocalStateSnapshot?
    ) async throws -> QuotaSnapshot {
        guard let url = URL(string: "https://api2.cursor.sh/aiserver.v1.DashboardService/GetCurrentPeriodUsage") else {
            throw ProviderFetchError.networkError(underlying: URLError(.badURL))
        }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
        request.httpBody = Data("{}".utf8)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ProviderFetchError.networkError(underlying: URLError(.badServerResponse))
        }
        guard http.statusCode == 200 else {
            throw ProviderFetchError.parsingError("Cursor dashboard usage HTTP \(http.statusCode)")
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ProviderFetchError.parsingError("Cursor dashboard usage: invalid JSON")
        }

        return try parseModernCursorUsage(json: json, localState: localState)
    }

    private func parseModernCursorUsage(
        json: [String: Any],
        localState: CursorLocalStateSnapshot?
    ) throws -> QuotaSnapshot {
        func number(_ value: Any?) -> Double? {
            if let v = value as? Double { return v }
            if let v = value as? Int { return Double(v) }
            if let v = value as? NSNumber { return v.doubleValue }
            if let v = value as? String { return Double(v) }
            return nil
        }

        let planUsage = json["planUsage"] as? [String: Any] ?? [:]

        // billingCycleEnd is a unix-millisecond timestamp (string or num).
        let resetDate: Date? = number(json["billingCycleEnd"]).map {
            Date(timeIntervalSince1970: $0 / 1000.0)
        }

        var windows: [QuotaWindow] = []

        if let total = number(planUsage["totalPercentUsed"]) {
            windows.append(
                QuotaWindow(
                    label: "Included in Pro",
                    windowKind: .monthly,
                    used: total,
                    total: 100,
                    resetDate: resetDate,
                    unit: "%",
                    subtitle: "Total plan usage this cycle"
                )
            )
        }
        if let auto = number(planUsage["autoPercentUsed"]) {
            windows.append(
                QuotaWindow(
                    label: "Auto + Composer",
                    windowKind: .monthly,
                    used: auto,
                    total: 100,
                    resetDate: resetDate,
                    unit: "%",
                    subtitle: "Agent / Composer usage"
                )
            )
        }
        if let api = number(planUsage["apiPercentUsed"]) {
            windows.append(
                QuotaWindow(
                    label: "API",
                    windowKind: .monthly,
                    used: api,
                    total: 100,
                    resetDate: resetDate,
                    unit: "%",
                    subtitle: "API model usage"
                )
            )
        }

        // On-demand spend (cents → dollars) as a balance, if present.
        var balances: [QuotaBalance] = []
        if let spend = json["spendLimitUsage"] as? [String: Any] {
            let individualLimit = number(spend["individualLimit"]) ?? 0
            let individualRemaining = number(spend["individualRemaining"]) ?? 0
            if individualLimit > 0 {
                let usedCents = max(0, individualLimit - individualRemaining)
                balances.append(
                    QuotaBalance(
                        label: "On-Demand Spend",
                        amount: individualRemaining / 100.0,
                        unit: "USD",
                        subtitle: "\((usedCents / 100).compactString) of \((individualLimit / 100).compactString) USD on-demand used",
                        resetDate: resetDate
                    )
                )
            }
        }

        // If the endpoint returned a healthy 200 but no usable windows
        // (e.g. brand-new account), fall back to a zero placeholder so
        // the card still reads "connected".
        if windows.isEmpty {
            windows.append(
                QuotaWindow(
                    label: "Included in Pro",
                    windowKind: .monthly,
                    used: 0,
                    total: 100,
                    resetDate: resetDate,
                    unit: "%",
                    subtitle: "No usage yet this cycle"
                )
            )
        }

        let planName = cursorPlanName(from: nil, localMembershipType: localState?.membershipType)
        let supplemental = cursorSupplementalContent(localState: localState, now: Date())
        let events = cursorActivityEvents(from: localState)

        return QuotaSnapshot(
            providerID: .cursor,
            displayName: "Cursor",
            planName: planName,
            windows: windows,
            stats: supplemental.stats,
            balances: balances,
            signals: supplemental.signals,
            events: events.sorted { $0.timestamp > $1.timestamp },
            fetchState: .success,
            fetchedAt: Date()
        )
    }

    private enum AuthMaterial {
        case cookie(String)
        case bearer(String)
        case localMetadataOnly
    }

    private func getAuthMaterial(credentials: ProviderCredential?, localState: CursorLocalStateSnapshot?) async throws -> AuthMaterial {
        // Prefer an explicit web-session cookie imported from an in-app sign-in flow.
        if credentials?.extraFields?["cursorAuthMode"] == "cookie" {
            if let cookieHeader = credentials?.extraFields?["cursorCookieHeader"]?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !cookieHeader.isEmpty {
                return .cookie(cookieHeader)
            }

            if let cookieHeader = credentials?.normalizedAccessToken {
                return .cookie(cookieHeader)
            }
        }

        if let cookieHeader = credentials?.extraFields?["cursorCookieHeader"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !cookieHeader.isEmpty {
            return .cookie(cookieHeader)
        }

        if credentials?.extraFields?["cursorAuthMode"] == "bearer",
           let token = credentials?.normalizedAccessToken,
           !token.isEmpty {
            return .bearer(token)
        }

        if let token = credentials?.normalizedAccessToken,
           !token.isEmpty,
           !shouldTreatCredentialTokenAsLocalMetadataOnly(token, credentials: credentials) {
            return .bearer(token)
        }

        if localState != nil {
            return .localMetadataOnly
        }

        throw ProviderFetchError.notConfigured
    }

    #if os(macOS)
    private func loadLocalStateSnapshot(credentials: ProviderCredential?) async throws -> CursorLocalStateSnapshot? {
        var bookmarkData: Data?
        if let bookmarkBase64 = credentials?.extraFields?["bookmarkData"],
           let data = Data(base64Encoded: bookmarkBase64) {
            bookmarkData = data
        }

        return try readLocalStateSnapshot(
            bookmarkData: bookmarkData,
            customPath: credentials?.normalizedCustomEndpoint
        )
    }

    private func shouldTreatCredentialTokenAsLocalMetadataOnly(
        _ token: String,
        credentials: ProviderCredential?
    ) -> Bool {
        if credentials?.extraFields?["cursorAuthMode"] == "localState" {
            return true
        }

        guard looksLikeJWT(token) else { return false }

        let hasLocalStatePath = credentials?.normalizedCustomEndpoint?.hasSuffix("state.vscdb") == true
        let hasBookmark = credentials?.extraFields?["bookmarkData"]?.isEmpty == false
        let hasExplicitWebCredential = credentials?.extraFields?["cursorCookieHeader"]?.isEmpty == false
            || credentials?.extraFields?["cursorAuthMode"] == "cookie"
            || credentials?.extraFields?["cursorAuthMode"] == "bearer"

        return (hasLocalStatePath || hasBookmark) && !hasExplicitWebCredential
    }

    private func looksLikeJWT(_ token: String) -> Bool {
        token.split(separator: ".").count == 3
    }

    private func readLocalStateSnapshot(
        bookmarkData: Data? = nil,
        customPath: String? = nil
    ) throws -> CursorLocalStateSnapshot? {
        let context = cursorStateAccessContext(bookmarkData: bookmarkData, customPath: customPath)
        let stateDBURL = context.stateDBURL

        let isAccessing = (context.accessScopeURL ?? stateDBURL).startAccessingSecurityScopedResource()
        defer {
            if isAccessing {
                (context.accessScopeURL ?? stateDBURL).stopAccessingSecurityScopedResource()
            }
        }

        guard FileManager.default.isReadableFile(atPath: stateDBURL.path) else {
            return nil
        }

        guard let db = openCursorSnapshotDatabase(at: stateDBURL) else {
            return nil
        }
        defer { sqlite3_close(db) }

        let accessToken = readCursorStateValue(from: db, key: "cursorAuth/accessToken")
        let refreshToken = readCursorStateValue(from: db, key: "cursorAuth/refreshToken")
        let cachedEmail = readCursorStateValue(from: db, key: "cursorAuth/cachedEmail")
        let membershipType = readCursorStateValue(from: db, key: "cursorAuth/stripeMembershipType")
            ?? readCursorStateValue(from: db, key: "cursorAuth/cachedMembershipType")
        let signUpType = readCursorStateValue(from: db, key: "cursorAuth/cachedSignUpType")

        let jwtPayload = decodeJWTPayload(accessToken ?? refreshToken)
        let sessionExpiry = cursorSessionExpiry(from: jwtPayload)
        let authSubject = jwtPayload?["sub"] as? String

        let uniqueCursorUserID: String?
        if let rawAlwaysLocal = readCursorStateValue(from: db, key: "anysphere.cursor-always-local"),
           let data = rawAlwaysLocal.data(using: .utf8),
           let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            uniqueCursorUserID = json["unique_cpp_user_id"] as? String
        } else {
            uniqueCursorUserID = nil
        }

        let dailyStats = readCursorDailyStats(from: db)
        let now = Date()
        let monthStart = Calendar.current.date(byAdding: .day, value: -30, to: now) ?? now
        let recentStats = dailyStats.filter { $0.date >= monthStart }

        let recentCommit: CursorRecentCommitMetadata?
        if let rawRecentCommit = readCursorStateValue(from: db, key: "aiCodeTracking.recentCommit"),
           let data = rawRecentCommit.data(using: .utf8),
           let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            recentCommit = CursorRecentCommitMetadata(json: json)
        } else {
            recentCommit = nil
        }

        if accessToken == nil,
           cachedEmail == nil,
           membershipType == nil,
           dailyStats.isEmpty,
           recentCommit == nil,
           uniqueCursorUserID == nil {
            return nil
        }

        return CursorLocalStateSnapshot(
            accessToken: accessToken,
            cachedEmail: cachedEmail,
            membershipType: membershipType,
            signUpType: signUpType,
            authSubject: authSubject,
            sessionExpiry: sessionExpiry,
            uniqueCursorUserID: uniqueCursorUserID,
            aiTrackingDayCount30d: recentStats.count,
            composerSuggestedLines30d: recentStats.reduce(0) { $0 + $1.composerSuggestedLines },
            composerAcceptedLines30d: recentStats.reduce(0) { $0 + $1.composerAcceptedLines },
            tabSuggestedLines30d: recentStats.reduce(0) { $0 + $1.tabSuggestedLines },
            tabAcceptedLines30d: recentStats.reduce(0) { $0 + $1.tabAcceptedLines },
            dailyStats: dailyStats,
            recentCommit: recentCommit
        )
    }

    private func readCursorDailyStats(from db: OpaquePointer) -> [CursorDailyStat] {
        let query = """
        SELECT value
        FROM ItemTable
        WHERE key LIKE 'aiCodeTracking.dailyStats.%'
        ORDER BY key ASC;
        """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK, let statement else {
            return []
        }
        defer { sqlite3_finalize(statement) }

        var stats: [CursorDailyStat] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let textPointer = sqlite3_column_text(statement, 0) else { continue }
            let rawValue = String(cString: textPointer)
            guard let data = rawValue.data(using: .utf8),
                  let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let stat = CursorDailyStat(json: json) else {
                continue
            }
            stats.append(stat)
        }

        return stats
    }

    private func readCursorStateValue(from db: OpaquePointer, key: String) -> String? {
        let query = "SELECT value FROM ItemTable WHERE key = ? LIMIT 1;"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK, let statement else {
            return nil
        }
        defer { sqlite3_finalize(statement) }

        let transientDestructor = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        _ = key.withCString { cString in
            sqlite3_bind_text(statement, 1, cString, -1, transientDestructor)
        }

        guard sqlite3_step(statement) == SQLITE_ROW,
              let textPointer = sqlite3_column_text(statement, 0) else {
            return nil
        }

        return String(cString: textPointer)
    }

    private func decodeJWTPayload(_ token: String?) -> [String: Any]? {
        guard let token else { return nil }
        let parts = token.split(separator: ".")
        guard parts.count == 3 else { return nil }

        var payload = String(parts[1])
        let remainder = payload.count % 4
        if remainder != 0 {
            payload.append(String(repeating: "=", count: 4 - remainder))
        }

        let normalized = payload
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")

        guard let data = Data(base64Encoded: normalized),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return nil
        }

        return json
    }

    private func cursorSessionExpiry(from payload: [String: Any]?) -> Date? {
        if let exp = payload?["exp"] as? Double {
            return Date(timeIntervalSince1970: exp)
        }
        if let exp = payload?["exp"] as? Int {
            return Date(timeIntervalSince1970: Double(exp))
        }
        if let exp = payload?["exp"] as? NSNumber {
            return Date(timeIntervalSince1970: exp.doubleValue)
        }
        return nil
    }

    private func cursorStateAccessContext(
        bookmarkData: Data?,
        customPath: String?
    ) -> (accessScopeURL: URL?, stateDBURL: URL) {
        let fallbackStateDBURL = resolvedStateDBURL(customPath: customPath)

        if let bookmarkData {
            print("[CursorProvider] Resolving security-scoped bookmark...")
            do {
                let resolvedURL = try resolveSecurityScopedURL(from: bookmarkData)
                print("[CursorProvider] Resolved bookmark to: \(resolvedURL.path)")
                if isDirectory(resolvedURL) {
                    return (resolvedURL, cursorStateDBURL(for: resolvedURL))
                }
                return (resolvedURL, cursorStateDBURL(for: resolvedURL))
            } catch {
                print("[CursorProvider] Failed to resolve bookmark: \(error), falling back to configured path")
            }
        }

        if let customPath, !customPath.isEmpty {
            print("[CursorProvider] Using configured file path: \(customPath)")
            let url = cursorStateDBURL(for: URL(fileURLWithPath: customPath))
            return (nil, url)
        }

        print("[CursorProvider] No bookmark data, using direct path")
        return (nil, fallbackStateDBURL)
    }

    private func openCursorSnapshotDatabase(at url: URL) -> OpaquePointer? {
        for candidate in cursorDatabaseCandidates(for: url) {
            guard FileManager.default.isReadableFile(atPath: candidate.path) else { continue }

            var db: OpaquePointer?
            let uri = candidate.absoluteString + "?mode=ro&immutable=1"
            if sqlite3_open_v2(uri, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK,
               let db {
                return db
            }

            if let db {
        sqlite3_close(db)
    }

}

        return nil
    }

    private func cursorDatabaseCandidates(for url: URL) -> [URL] {
        let stateDBURL = cursorStateDBURL(for: url)

        if stateDBURL.lastPathComponent == "state.vscdb.backup" {
            return [
                stateDBURL,
                stateDBURL.deletingLastPathComponent().appendingPathComponent("state.vscdb")
            ]
        }

        guard stateDBURL.lastPathComponent == "state.vscdb" else {
            return [stateDBURL]
        }

        return [
            stateDBURL,
            stateDBURL.deletingLastPathComponent().appendingPathComponent("state.vscdb.backup")
        ]
    }

    private func resolvedStateDBURL(customPath: String?) -> URL {
        if let customPath, !customPath.isEmpty {
            return cursorStateDBURL(for: URL(fileURLWithPath: customPath))
        }

        let homePath = NSHomeDirectory()
        let realHomePath: String
        if let containerRange = homePath.range(of: "/Library/Containers/") {
            realHomePath = String(homePath[..<containerRange.lowerBound])
        } else {
            realHomePath = homePath
        }
        let realHome = URL(fileURLWithPath: realHomePath)

        return realHome.appendingPathComponent("Library/Application Support/Cursor/User/globalStorage/state.vscdb")
    }

    private func cursorStateDBURL(for url: URL) -> URL {
        if url.lastPathComponent == "state.vscdb" || url.lastPathComponent == "state.vscdb.backup" {
            return url
        }

        if isDirectory(url) || url.hasDirectoryPath || url.pathExtension.isEmpty {
            return url.appendingPathComponent("state.vscdb")
        }

        return url
    }

    private func resolveSecurityScopedURL(from bookmarkData: Data) throws -> URL {
        var isStale = false
        let resolvedURL = try URL(
            resolvingBookmarkData: bookmarkData,
            options: .withSecurityScope,
            bookmarkDataIsStale: &isStale
        )
        print("[CursorProvider] Bookmark is stale: \(isStale)")
        return resolvedURL
    }

    private func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            return false
        }
        return isDirectory.boolValue
    }
    #else
    private func loadLocalStateSnapshot(credentials: ProviderCredential?) async throws -> CursorLocalStateSnapshot? {
        _ = credentials
        return nil
    }

    private func shouldTreatCredentialTokenAsLocalMetadataOnly(
        _ token: String,
        credentials: ProviderCredential?
    ) -> Bool {
        _ = token
        // iOS builds don't read local Cursor state, so the token is treated as web auth.
        return credentials?.extraFields?["cursorAuthMode"] == "localState"
    }
    #endif

    private func parseUsageResponse(data: Data, localState: CursorLocalStateSnapshot?) throws -> QuotaSnapshot {
        let now = Date()

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ProviderFetchError.parsingError("Invalid JSON response")
        }

        print("[CursorProvider] Response JSON: \(json)")

        var windows: [QuotaWindow] = []
        let monthStart = parseResetDate(from: json["startOfMonth"] as? String) ?? {
            if let dateString = json["start_of_month"] as? String {
                return parseResetDate(from: dateString)
            }
            return nil
        }()

        let planName = cursorPlanName(
            from: json["plan"] as? String ?? json["tier"] as? String ?? json["plan_type"] as? String,
            localMembershipType: localState?.membershipType
        )
        let supplemental = cursorSupplementalContent(localState: localState, now: now)
        let stats = supplemental.stats
        let signals = supplemental.signals

        if let modelBlock = firstUsageBlock(in: json) {
            let fastUsed = number(in: modelBlock, keys: ["numRequests", "requestsUsed", "fastRequestsUsed", "premiumRequestsUsed"])
            let fastTotal = number(in: modelBlock, keys: ["numRequestsTotal", "requestLimit", "fastRequestsLimit", "premiumRequestsLimit"])

            if fastUsed > 0 || fastTotal > 0 {
                windows.append(
                    QuotaWindow(
                        label: "Fast Requests",
                        windowKind: .monthly,
                        used: fastUsed,
                        total: fastTotal > 0 ? fastTotal : nil,
                        resetDate: monthStart,
                        unit: "requests",
                        subtitle: "Premium model requests"
                    )
                )
            }

            let tokenUsed = number(in: modelBlock, keys: ["numTokens", "tokensUsed"])
            let tokenTotal = number(in: modelBlock, keys: ["maxTokenUsage", "tokenLimit"])
            if tokenUsed > 0 || tokenTotal > 0 {
                windows.append(
                    QuotaWindow(
                        label: "Token Usage",
                        windowKind: .monthly,
                        used: tokenUsed,
                        total: tokenTotal > 0 ? tokenTotal : nil,
                        resetDate: monthStart,
                        unit: "tokens",
                        subtitle: "Model token usage"
                    )
                )
            }
        }

        if windows.isEmpty {
            // Backward-compatible fallback for older payload shapes.
            let fastUsed = number(in: json, keys: ["fastRequestsUsed", "premiumRequestsUsed"])
            let fastTotal = number(in: json, keys: ["fastRequestsLimit", "premiumRequestsLimit"])
            let fastReset = parseResetDate(from: json["resetDate"] as? String)

            if fastUsed > 0 || fastTotal > 0 {
                windows.append(
                    QuotaWindow(
                        label: "Fast Requests",
                        windowKind: .monthly,
                        used: fastUsed,
                        total: fastTotal > 0 ? fastTotal : nil,
                        resetDate: fastReset,
                        unit: "requests",
                        subtitle: "Premium model requests"
                    )
                )
            }

            let slowUsed = number(in: json, keys: ["slowRequestsUsed", "requestsUsed"])
            if slowUsed > 0 {
                windows.append(
                    QuotaWindow(
                        label: "Slow Requests",
                        windowKind: .monthly,
                        used: slowUsed,
                        total: nil,
                        resetDate: nil,
                        unit: "requests",
                        subtitle: "Unlimited with Pro plan"
                    )
                )
            }
        }

        // Zero-usage placeholder. The API returned success but the user
        // hasn't burned any requests this month (numRequests=0,
        // numTokens=0, and limits often null too on Pro). Without this,
        // the card renders empty under the header — visually
        // indistinguishable from a broken integration. Emit a single
        // labelled window so the user can see "Cursor is connected,
        // just unused yet". We only show this on a recognised plan so
        // we don't paper over genuine misconfigurations.
        if windows.isEmpty, !planName.isEmpty {
            windows.append(
                QuotaWindow(
                    label: "Fast Requests",
                    windowKind: .monthly,
                    used: 0,
                    total: nil,
                    resetDate: monthStart,
                    unit: "requests",
                    subtitle: "No usage yet this month"
                )
            )
        }

        let events = cursorActivityEvents(from: localState)

        return QuotaSnapshot(
            providerID: .cursor,
            displayName: "Cursor",
            planName: planName,
            windows: windows,
            stats: stats,
            signals: signals,
            events: events.sorted { $0.timestamp > $1.timestamp },
            fetchState: .success,
            fetchedAt: now
        )
    }

    private func cursorLocalMetadataSnapshot(
        localState: CursorLocalStateSnapshot?,
        now: Date,
        authNote: String
    ) -> QuotaSnapshot {
        let supplemental = cursorSupplementalContent(
            localState: localState,
            now: now,
            authNote: authNote
        )

        return QuotaSnapshot(
            providerID: .cursor,
            displayName: "Cursor",
            planName: cursorPlanName(from: nil, localMembershipType: localState?.membershipType),
            windows: [],
            stats: supplemental.stats,
            signals: supplemental.signals,
            events: cursorActivityEvents(from: localState),
            fetchState: .success,
            fetchedAt: now
        )
    }

    private func cursorActivityEvents(from localState: CursorLocalStateSnapshot?) -> [UsageEvent] {
        guard let dailyStats = localState?.dailyStats else { return [] }
        return dailyStats
            .sorted { $0.date > $1.date }
            .map { stat in
                UsageEvent(
                    timestamp: stat.date,
                    // Cursor dailyStats is request-count based. Treat as activity, not tokens, so
                    // the heatmap "today" token total doesn't get wildly inflated.
                    tokens: nil,
                    model: "Cursor",
                    type: .bucket
                )
            }
    }

    private func cursorSupplementalContent(
        localState: CursorLocalStateSnapshot?,
        now: Date,
        authNote: String? = nil
    ) -> (stats: [QuotaStat], signals: [QuotaSignal]) {
        var stats: [QuotaStat] = []
        var signals: [QuotaSignal] = []

        if let authNote {
            signals.append(
                QuotaSignal(
                    kind: .unexpectedRecovery,
                    title: "Live usage needs a web session",
                    message: authNote,
                    severity: .warning,
                    detectedAt: now
                )
            )
        }

        guard let localState else {
            return (stats, signals)
        }

        if let sessionExpiry = localState.sessionExpiry {
            let daysLeft = max(0, sessionExpiry.timeIntervalSince(now) / 86_400)
            stats.append(
                QuotaStat(
                    label: "Session Days Left",
                    value: daysLeft,
                    unit: "days",
                    subtitle: "Based on the locally cached Cursor session token"
                )
            )
        }

        if localState.aiTrackingDayCount30d > 0 {
            stats.append(
                QuotaStat(
                    label: "Tracked AI Days",
                    value: Double(localState.aiTrackingDayCount30d),
                    unit: "days",
                    subtitle: "Local AI coding history rows from the last 30 days"
                )
            )
        }

        if localState.composerSuggestedLines30d > 0 || localState.composerAcceptedLines30d > 0 {
            stats.append(
                QuotaStat(
                    label: "30D Composer Suggested",
                    value: Double(localState.composerSuggestedLines30d),
                    unit: "lines",
                    subtitle: "Cursor composer lines suggested locally"
                )
            )
            stats.append(
                QuotaStat(
                    label: "30D Composer Accepted",
                    value: Double(localState.composerAcceptedLines30d),
                    unit: "lines",
                    subtitle: "Cursor composer lines accepted locally"
                )
            )
        }

        if localState.tabSuggestedLines30d > 0 || localState.tabAcceptedLines30d > 0 {
            stats.append(
                QuotaStat(
                    label: "30D Tab Suggested",
                    value: Double(localState.tabSuggestedLines30d),
                    unit: "lines",
                    subtitle: "Cursor tab lines suggested locally"
                )
            )
            stats.append(
                QuotaStat(
                    label: "30D Tab Accepted",
                    value: Double(localState.tabAcceptedLines30d),
                    unit: "lines",
                    subtitle: "Cursor tab lines accepted locally"
                )
            )
        }

        if let aiPercentage = localState.recentCommit?.aiPercentage {
            stats.append(
                QuotaStat(
                    label: "Recent Commit AI %",
                    value: aiPercentage,
                    unit: "%",
                    subtitle: "AI share reported on the most recent tracked commit"
                )
            )
        }

        if let cachedEmail = localState.cachedEmail, !cachedEmail.isEmpty {
            signals.append(
                QuotaSignal(
                    kind: .unexpectedRecovery,
                    title: "Local Cursor account detected",
                    message: "Using locally cached Cursor account metadata for \(cachedEmail).",
                    severity: .info,
                    detectedAt: now
                )
            )
        }

        if authNote == nil,
           let membershipType = localState.membershipType,
           !membershipType.isEmpty {
            let membershipPlanName = cursorPlanName(
                from: membershipType,
                localMembershipType: nil
            )
            signals.append(
                QuotaSignal(
                    kind: .unexpectedRecovery,
                    title: "Membership cached as \(membershipPlanName)",
                    message: "Cursor's local state reports the cached membership tier as `\(membershipType)`.",
                    severity: .info,
                    detectedAt: now
                )
            )
        }

        return (stats, signals)
    }

    private func parseResetDate(from string: String?) -> Date? {
        guard let string = string else { return nil }
        let formatter = ISO8601DateFormatter()
        return formatter.date(from: string)
    }

    private func firstUsageBlock(in json: [String: Any]) -> [String: Any]? {
        let prioritizedKeys = [
            "gpt-4",
            "gpt-4o",
            "claude-3.5-sonnet",
            "sonnet",
            "fast",
            "usage"
        ]

        for key in prioritizedKeys {
            if let block = json[key] as? [String: Any] {
                return block
            }
        }

        return json.values.compactMap { $0 as? [String: Any] }.first
    }

    private func number(in json: [String: Any], keys: [String]) -> Double {
        for key in keys {
            if let value = json[key] as? Double { return value }
            if let value = json[key] as? Int { return Double(value) }
            if let value = json[key] as? NSNumber { return value.doubleValue }
            if let value = json[key] as? String, let number = Double(value) { return number }
        }
        return 0
    }

    private func cursorPlanName(from rawValue: String?, localMembershipType: String?) -> String {
        let normalized = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallback = localMembershipType?.trimmingCharacters(in: .whitespacesAndNewlines)

        guard let rawValue = (normalized?.isEmpty == false ? normalized : fallback),
              !rawValue.isEmpty else {
            return "Plan"
        }

        switch rawValue.lowercased() {
        case "pro":
            return "Pro"
        case "pro_plus", "pro plus", "pro-plus", "pro+":
            return "Pro +"
        case "free":
            return "Free"
        case "business":
            return "Business"
        default:
            return rawValue.capitalized
        }
    }
}

// MARK: - ChatGPT Local Provider Client

/// Reads local ChatGPT macOS app cache activity and turns it into
/// usage-style snapshots without depending on private consumer APIs.
public struct ChatGPTLocalProviderClient: ProviderClient {
    public let providerID: ProviderID = .chatgpt

    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    public func fetchSnapshot(credentials: ProviderCredential?) async throws -> QuotaSnapshot {
        let rootURL = resolvedChatGPTRootURL(credentials: credentials)
        let bookmarkData = chatGPTBookmarkData(from: credentials)
        let reader = ChatGPTDesktopLocalStateReader(fileManager: fileManager)

        print("[ChatGPTLocalProvider] Reading local ChatGPT cache from: \(rootURL.path)")
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                var accessURL = rootURL
                var didStartAccessing = false

                if let bookmarkData,
                   let bookmarkedURL = Self.resolvedSecurityScopedURL(from: bookmarkData) {
                    accessURL = bookmarkedURL
                    didStartAccessing = accessURL.startAccessingSecurityScopedResource()
                    print("[ChatGPTLocalProvider] Using security-scoped bookmark: \(accessURL.path)")
                }

                defer {
                    if didStartAccessing {
                        accessURL.stopAccessingSecurityScopedResource()
                    }
                }

                do {
                    continuation.resume(returning: try reader.loadSnapshot(rootURL: accessURL))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func resolvedChatGPTRootURL(credentials: ProviderCredential?) -> URL {
        if let customPath = credentials?.normalizedCustomEndpoint, !customPath.isEmpty {
            return URL(fileURLWithPath: customPath)
        }

        let homePath = NSHomeDirectory()
        let realHomePath: String
        if let containerRange = homePath.range(of: "/Library/Containers/") {
            realHomePath = String(homePath[..<containerRange.lowerBound])
        } else {
            realHomePath = homePath
        }

        return URL(fileURLWithPath: realHomePath)
            .appendingPathComponent("Library/Application Support/com.openai.chat")
    }

    private func chatGPTBookmarkData(from credentials: ProviderCredential?) -> Data? {
        guard let encoded = credentials?.extraFields?["bookmarkData"],
              let data = Data(base64Encoded: encoded) else {
            return nil
        }

        return data
    }

    private static func resolvedSecurityScopedURL(from bookmarkData: Data) -> URL? {
        var isStale = false
        #if os(macOS)
        let options: URL.BookmarkResolutionOptions = [.withSecurityScope]
        #else
        let options: URL.BookmarkResolutionOptions = []
        #endif
        return try? URL(
            resolvingBookmarkData: bookmarkData,
            options: options,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )
    }
}

private struct ChatGPTDesktopLocalStateReader: @unchecked Sendable {
    private let fileManager: FileManager

    init(fileManager: FileManager) {
        self.fileManager = fileManager
    }

    func loadSnapshot(rootURL: URL) throws -> QuotaSnapshot {
        guard fileManager.fileExists(atPath: rootURL.path) else {
            throw ProviderFetchError.notConfigured
        }

        let metadata = loadMetadata(rootURL: rootURL)
        let totalChats = metadata.cachedConversationCount + metadata.projectConversationCount
        guard totalChats > 0 || metadata.draftCount > 0 || metadata.projectCount > 0 else {
            throw ProviderFetchError.notConfigured
        }

        let now = Date()
        let windows = [
            QuotaWindow(
                label: "24H Active Chats",
                windowKind: .daily,
                used: Double(metadata.activeConversationCount24h),
                total: nil,
                resetDate: nil,
                unit: "chats",
                subtitle: "Local conversation caches updated in the last 24 hours"
            ),
            QuotaWindow(
                label: "7D Active Chats",
                windowKind: .weekly,
                used: Double(metadata.activeConversationCount7d),
                total: nil,
                resetDate: nil,
                unit: "chats",
                subtitle: "Chats updated in the last 7 days"
            ),
            QuotaWindow(
                label: "30D Active Chats",
                windowKind: .monthly,
                used: Double(metadata.activeConversationCount30d),
                total: nil,
                resetDate: nil,
                unit: "chats",
                subtitle: "Chats updated in the last 30 days"
            )
        ]

        var stats = [
            QuotaStat(
                label: "Cached Chats",
                value: Double(totalChats),
                unit: "chats",
                subtitle: "Local ChatGPT conversation cache files"
            ),
            QuotaStat(
                label: "Drafts",
                value: Double(metadata.draftCount),
                unit: "drafts",
                subtitle: "Local unsent or in-progress drafts"
            ),
            QuotaStat(
                label: "Projects",
                value: Double(metadata.projectCount),
                unit: "projects",
                subtitle: "Project folders cached by the ChatGPT desktop app"
            )
        ]

        if metadata.projectConversationCount > 0 {
            stats.append(
                QuotaStat(
                    label: "Project Chats",
                    value: Double(metadata.projectConversationCount),
                    unit: "chats",
                    subtitle: "Cached chats inside ChatGPT Projects"
                )
            )
        }

        if let messageSendCount = metadata.messageSendCount {
            stats.append(
                QuotaStat(
                    label: "Local Sends",
                    value: Double(messageSendCount),
                    unit: "msg",
                    subtitle: "Desktop app local send counter"
                )
            )
        }

        if let voiceSessionCount = metadata.voiceSessionCount {
            stats.append(
                QuotaStat(
                    label: "Voice Sessions",
                    value: Double(voiceSessionCount),
                    unit: "sessions",
                    subtitle: "Voice sessions recorded in local ChatGPT prefs"
                )
            )
        }

        if let latestConversationDate = metadata.latestConversationDate {
            let ageDays = max(0, now.timeIntervalSince(latestConversationDate) / 86_400)
            stats.append(
                QuotaStat(
                    label: "Last Activity Age",
                    value: ageDays,
                    unit: "days",
                    subtitle: "Since the newest cached chat activity on this Mac"
                )
            )
        }

        var signals: [QuotaSignal] = []
        if let lastSelectedModel = metadata.lastSelectedModel, !lastSelectedModel.isEmpty {
            signals.append(
                QuotaSignal(
                    kind: .unexpectedRecovery,
                    title: "Last selected model cached locally",
                    message: "The local ChatGPT app preferences show `\(lastSelectedModel)` as the most recent model used on this Mac.",
                    severity: .info,
                    detectedAt: now
                )
            )
        }

        return QuotaSnapshot(
            providerID: .chatgpt,
            displayName: "ChatGPT",
            planName: metadata.planName,
            windows: windows,
            stats: stats,
            signals: signals,
            events: metadata.events.sorted { $0.timestamp > $1.timestamp },
            fetchState: .success,
            fetchedAt: now
        )
    }

    private func loadMetadata(rootURL: URL) -> ChatGPTLocalMetadata {
        var metadata = ChatGPTLocalMetadata()
        metadata.accountID = discoverAccountID(in: rootURL)

        var allConversationInfos: [ChatGPTConversationInfo] = []

        if let conversationsRoot = firstMatchingDirectory(in: rootURL, prefix: "conversations-v3-") {
            let infos = conversationInfos(in: conversationsRoot)
            metadata.cachedConversationCount = infos.count
            allConversationInfos.append(contentsOf: infos)
        }

        let projectDirectories = projectDirectories(in: rootURL)
        metadata.projectCount = projectDirectories.count

        for projectDirectory in projectDirectories {
            guard let conversationsRoot = firstMatchingDirectory(in: projectDirectory, prefix: "conversations-v3-") else {
                continue
            }

            let infos = conversationInfos(in: conversationsRoot)
            metadata.projectConversationCount += infos.count
            allConversationInfos.append(contentsOf: infos)
        }

        if let draftsRoot = firstMatchingDirectory(in: rootURL, prefix: "drafts-v2-") {
            metadata.draftCount = dataFileCount(in: draftsRoot)
        }

        if let latestConversationDate = allConversationInfos.map(\.modificationDate).max() {
            metadata.latestConversationDate = latestConversationDate
        }

        let now = Date()
        let dayStart = now.addingTimeInterval(-24 * 60 * 60)
        let weekStart = now.addingTimeInterval(-7 * 24 * 60 * 60)
        let monthStart = now.addingTimeInterval(-30 * 24 * 60 * 60)

        metadata.activeConversationCount24h = allConversationInfos.filter { $0.modificationDate >= dayStart }.count
        metadata.activeConversationCount7d = allConversationInfos.filter { $0.modificationDate >= weekStart }.count
        metadata.activeConversationCount30d = allConversationInfos.filter { $0.modificationDate >= monthStart }.count

        metadata.events = allConversationInfos.filter { $0.modificationDate >= monthStart }.map {
            UsageEvent(timestamp: $0.modificationDate, type: .activity)
        }

        loadPreferenceMetadata(rootURL: rootURL, into: &metadata)
        return metadata
    }

    private func discoverAccountID(in rootURL: URL) -> String? {
        let prefixes = [
            "conversations-v3-",
            "drafts-v2-",
            "models-",
            "gizmos-",
            "system-hints-"
        ]

        guard let contents = try? fileManager.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        for url in contents {
            let name = url.lastPathComponent
            for prefix in prefixes where name.hasPrefix(prefix) {
                let suffix = String(name.dropFirst(prefix.count))
                if !suffix.isEmpty {
                    return suffix
                }
            }
        }

        return nil
    }

    private func firstMatchingDirectory(in rootURL: URL, prefix: String) -> URL? {
        guard let contents = try? fileManager.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        return contents.first { url in
            guard let isDirectory = try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory else {
                return false
            }
            return isDirectory == true && url.lastPathComponent.hasPrefix(prefix)
        }
    }

    private func projectDirectories(in rootURL: URL) -> [URL] {
        guard let contents = try? fileManager.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return contents.filter { url in
            guard let isDirectory = try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory else {
                return false
            }
            return isDirectory == true && url.lastPathComponent.hasPrefix("project-")
        }
    }

    private func conversationInfos(in rootURL: URL) -> [ChatGPTConversationInfo] {
        guard let contents = try? fileManager.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return contents.compactMap { url in
            guard url.pathExtension.lowercased() == "data" else { return nil }
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey]),
                  values.isRegularFile == true else {
                return nil
            }

            return ChatGPTConversationInfo(
                url: url,
                modificationDate: values.contentModificationDate ?? .distantPast
            )
        }
    }

    private func dataFileCount(in rootURL: URL) -> Int {
        guard let contents = try? fileManager.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return 0
        }

        return contents.filter { url in
            guard url.pathExtension.lowercased() == "data" else { return false }
            return (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        }.count
    }

    private func loadPreferenceMetadata(rootURL: URL, into metadata: inout ChatGPTLocalMetadata) {
        let libraryURL = rootURL.deletingLastPathComponent().deletingLastPathComponent()
        let prefsURL = libraryURL.appendingPathComponent("Preferences/com.openai.chat.plist")
        let statsigURL = libraryURL.appendingPathComponent("Preferences/com.openai.chat.StatsigService.plist")

        if let statsig = propertyListDictionary(at: statsigURL) {
            if let accountID = nonEmptyString(statsig["accountID"]) {
                metadata.accountID = metadata.accountID ?? accountID
            }

            if let planType = nonEmptyString(statsig["planType"]) {
                metadata.planName = chatGPTPlanName(from: planType)
            }
        }

        guard let prefs = propertyListDictionary(at: prefsURL) else {
            return
        }

        if metadata.accountID == nil {
            metadata.accountID = accountIdentifier(fromPreferences: prefs)
        }

        if let accountID = metadata.accountID {
            metadata.messageSendCount = integerValue(prefs["messageSendCount_\(accountID)"])
            metadata.voiceSessionCount = integerValue(prefs["voiceTrainingPromptVoiceSessionCount_\(accountID)"])

            if let settingsResponse = nonEmptyString(prefs["lastAccountSettingsResponse_\(accountID)"]),
               let json = jsonDictionary(from: settingsResponse),
               let settings = json["settings"] as? [String: Any],
               let lastUsedModelConfig = settings["lastUsedModelConfig"] as? [String: Any],
               let slugs = lastUsedModelConfig["slugs"] as? [String: Any] {
                metadata.lastSelectedModel = nonEmptyString(slugs["macosApp"])
                    ?? nonEmptyString(slugs["default"])
                    ?? metadata.lastSelectedModel
            }
        }

        if let lastSelectedConversation = nonEmptyString(prefs["lastSelectedConversation"]),
           let json = jsonDictionary(from: lastSelectedConversation) {
            metadata.lastSelectedModel = nonEmptyString(json["modelSlug"]) ?? metadata.lastSelectedModel
        }
    }

    private func propertyListDictionary(at url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url),
              let value = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let dict = value as? [String: Any] else {
            return nil
        }

        return dict
    }

    private func jsonDictionary(from string: String) -> [String: Any]? {
        guard let data = string.data(using: .utf8),
              let value = try? JSONSerialization.jsonObject(with: data),
              let dict = value as? [String: Any] else {
            return nil
        }

        return dict
    }

    private func accountIdentifier(fromPreferences preferences: [String: Any]) -> String? {
        for key in preferences.keys where key.hasPrefix("messageSendCount_") {
            return String(key.dropFirst("messageSendCount_".count))
        }
        return nil
    }

    private func integerValue(_ value: Any?) -> Int? {
        if let intValue = value as? Int { return intValue }
        if let number = value as? NSNumber { return number.intValue }
        if let doubleValue = value as? Double { return Int(doubleValue) }
        return nil
    }

    private func nonEmptyString(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func chatGPTPlanName(from rawValue: String) -> String {
        switch rawValue.lowercased() {
        case "plus":
            return "ChatGPT Plus"
        case "pro":
            return "ChatGPT Pro"
        case "go":
            return "ChatGPT Go"
        case "free":
            return "ChatGPT Free"
        default:
            return "ChatGPT \(rawValue.capitalized)"
        }
    }
}

private struct ChatGPTConversationInfo {
    let url: URL
    let modificationDate: Date
}

private struct ChatGPTLocalMetadata {
    var accountID: String?
    var cachedConversationCount: Int = 0
    var projectConversationCount: Int = 0
    var draftCount: Int = 0
    var projectCount: Int = 0
    var activeConversationCount24h: Int = 0
    var activeConversationCount7d: Int = 0
    var activeConversationCount30d: Int = 0
    var latestConversationDate: Date?
    var planName: String?
    var messageSendCount: Int?
    var voiceSessionCount: Int?
    var lastSelectedModel: String?
    var events: [UsageEvent] = []
}

// MARK: - Claude OAuth Response

struct ClaudeOAuthWindow: Decodable {
    let utilization: Double?
    let resetAt: Date?

    enum CodingKeys: String, CodingKey {
        case utilization
        case resetAt = "resets_at"
    }
}

enum ClaudeOAuthModelWindowMapper {
    static func quotaWindow(
        label: String,
        subtitle: String,
        from window: ClaudeOAuthWindow?
    ) -> QuotaWindow? {
        guard let window, let utilization = window.utilization else {
            return nil
        }

        return QuotaWindow(
            label: label,
            windowKind: .weekly,
            used: utilization,
            total: 100,
            resetDate: window.resetAt,
            unit: "%",
            subtitle: subtitle
        )
    }

    static func fableQuotaWindow(from window: ClaudeOAuthWindow?) -> QuotaWindow? {
        quotaWindow(
            label: "Fable",
            subtitle: fableSubtitle(for: window?.utilization),
            from: window
        )
    }

    private static func fableSubtitle(for utilization: Double?) -> String {
        guard let utilization, utilization <= 0 else {
            return "Fable 7-day rolling window"
        }
        return "You haven't used Fable yet"
    }
}

struct ClaudeOAuthLimit: Decodable {
    let group: String?
    let kind: String?
    let percent: Double?
    let resetAt: Date?
    let scope: String?

    enum CodingKeys: String, CodingKey {
        case group
        case kind
        case percent
        case resetAt = "resets_at"
        case scope
    }

    init(group: String?, kind: String?, percent: Double?, resetAt: Date?, scope: String?) {
        self.group = group
        self.kind = kind
        self.percent = percent
        self.resetAt = resetAt
        self.scope = scope
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        group = try container.decodeIfPresent(String.self, forKey: .group)
        kind = try container.decodeIfPresent(String.self, forKey: .kind)
        percent = try container.decodeIfPresent(Double.self, forKey: .percent)
        resetAt = try container.decodeIfPresent(Date.self, forKey: .resetAt)
        scope = try? container.decodeIfPresent(String.self, forKey: .scope)
    }

    var isFableWeeklyLimit: Bool {
        let normalizedGroup = group?.lowercased()
        let normalizedKind = kind?.lowercased()
        let normalizedScope = scope?.lowercased()

        return normalizedGroup == "weekly"
            && (
                normalizedKind == "weekly_scoped"
                    || normalizedKind?.contains("fable") == true
                    || normalizedScope?.contains("fable") == true
            )
    }

    var oauthWindow: ClaudeOAuthWindow? {
        guard let percent else { return nil }
        return ClaudeOAuthWindow(utilization: percent, resetAt: resetAt)
    }
}

struct ClaudeOAuthExtraUsage: Decodable {
    let isEnabled: Bool
    let monthlyLimit: Double?
    let usedCredits: Double?
    let utilization: Double?
    let currency: String?

    enum CodingKeys: String, CodingKey {
        case isEnabled = "is_enabled"
        case monthlyLimit = "monthly_limit"
        case usedCredits = "used_credits"
        case utilization
        case currency
    }
}

struct ClaudeOAuthUsageResponse: Decodable {
    let fiveHour: ClaudeOAuthWindow?
    let sevenDay: ClaudeOAuthWindow?
    let sevenDayOpus: ClaudeOAuthWindow?
    let sevenDayFable: ClaudeOAuthWindow?
    let sevenDaySonnet: ClaudeOAuthWindow?
    let sevenDayOAuthApps: ClaudeOAuthWindow?
    let limits: [ClaudeOAuthLimit]?
    let extraUsage: ClaudeOAuthExtraUsage?

    enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
        case sevenDayOpus = "seven_day_opus"
        case sevenDayFable = "seven_day_fable"
        case sevenDaySonnet = "seven_day_sonnet"
        case sevenDayOAuthApps = "seven_day_oauth_apps"
        case limits
        case extraUsage = "extra_usage"
    }

    var fableWeeklyWindow: ClaudeOAuthWindow? {
        sevenDayFable
            ?? limits?.first { $0.isFableWeeklyLimit }?.oauthWindow
            ?? sevenDaySonnet
    }
}

struct ClaudeOAuthProfileResponse: Decodable {
    struct Organization: Decodable {
        let rateLimitTier: String?
        let organizationType: String?

        enum CodingKeys: String, CodingKey {
            case rateLimitTier = "rate_limit_tier"
            case organizationType = "organization_type"
        }
    }

    let organization: Organization?

    var planInfo: ClaudePlanInfo? {
        ClaudePlanResolver.resolve(
            subscriptionType: nil,
            rateLimitTier: organization?.rateLimitTier,
            organizationType: organization?.organizationType
        )
    }
}

// MARK: - Claude Provider Client

/// Source-aware cache for the Anthropic OAuth usage endpoint.
/// The endpoint is aggressively rate-limited (HTTP 429 after only a couple of
/// requests per minute), so we serve a recent successful response if the
/// dashboard refreshes faster than `freshTTL`, and we fall back to the most
/// recent successful response whenever the live call fails transiently.
///
/// OAuth quota and local transcript snapshots intentionally share the Claude
/// provider ID, so the general snapshot store cannot identify their source.
/// This cache persists quota-only snapshots under its own key and validates
/// every candidate before use. That prevents transcript token totals from
/// contaminating the last-known-good quota path.
final class ClaudeOAuthResponseCache: @unchecked Sendable {
    static let shared = ClaudeOAuthResponseCache()

    private static let appGroupID = "group.com.chrisizatt.LLMUsageCounter"
    private static let defaultPersistenceKey = "claude.oauthQuotaSnapshot.v1"

    /// Serve cached snapshot without touching the network if newer than this.
    private let freshTTL: TimeInterval
    /// Serve in-memory stale snapshot on transient failure within this window.
    /// Beyond it we hop to the disk-persisted snapshot via QuotaSnapshotStore.
    private let staleTTL: TimeInterval
    /// Hard cap on how old a disk-persisted snapshot can be before we give
    /// up and let the error surface. 24h is generous enough to ride out
    /// extended Anthropic outages while still surfacing a problem when
    /// something is genuinely broken for the user (expired creds, deleted
    /// keychain entry, etc.).
    private let diskMaxAge: TimeInterval
    private let defaults: UserDefaults
    private let persistenceKey: String
    private let legacySnapshotLoader: () -> QuotaSnapshot?

    private let lock = NSLock()
    private var stored: (snapshot: QuotaSnapshot, fetchedAt: Date)?

    init(
        freshTTL: TimeInterval = 120,                  // 2 min
        staleTTL: TimeInterval = 4 * 60 * 60,          // 4 hours
        diskMaxAge: TimeInterval = 24 * 60 * 60,       // 24 hours
        defaults: UserDefaults? = nil,
        persistenceKey: String = ClaudeOAuthResponseCache.defaultPersistenceKey,
        legacySnapshotLoader: @escaping () -> QuotaSnapshot? = {
            QuotaSnapshotStore.shared.loadSnapshots()
                .first { $0.providerID == .claude && $0.fetchState == .success }
        }
    ) {
        self.freshTTL = freshTTL
        self.staleTTL = staleTTL
        self.diskMaxAge = diskMaxAge
        self.defaults = defaults
            ?? UserDefaults(suiteName: Self.appGroupID)
            ?? .standard
        self.persistenceKey = persistenceKey
        self.legacySnapshotLoader = legacySnapshotLoader
    }

    func fresh(now: Date = Date()) -> QuotaSnapshot? {
        lock.lock(); defer { lock.unlock() }
        guard let stored, now.timeIntervalSince(stored.fetchedAt) < freshTTL else {
            return nil
        }
        return stored.snapshot
    }

    /// Last-known-good snapshot to serve when the live fetch fails for a
    /// transient reason. Layered fallback:
    ///   1. In-memory: most recent successful response from this process.
    ///   2. Disk: dedicated OAuth quota snapshot, stripped of bulky events.
    ///   3. Legacy disk: a validated OAuth snapshot from QuotaSnapshotStore,
    ///      used only to migrate installs that predate the dedicated cache.
    func staleFallback(now: Date = Date()) -> QuotaSnapshot? {
        lock.lock()
        if let stored, now.timeIntervalSince(stored.fetchedAt) < staleTTL {
            let snapshot = stored.snapshot
            lock.unlock()
            return snapshot
        }
        lock.unlock()

        if let disk = loadPersistedSnapshot(),
           now.timeIntervalSince(disk.fetchedAt) < diskMaxAge {
            return disk
        }

        guard let legacy = legacySnapshotLoader(),
              Self.isOAuthQuotaSnapshot(legacy),
              now.timeIntervalSince(legacy.fetchedAt) < diskMaxAge else {
            return nil
        }

        persist(Self.quotaOnlySnapshot(from: legacy))
        return legacy
    }

    func store(_ snapshot: QuotaSnapshot, now: Date = Date()) {
        guard Self.isOAuthQuotaSnapshot(snapshot) else { return }

        lock.lock()
        stored = (snapshot, now)
        lock.unlock()

        persist(Self.quotaOnlySnapshot(from: snapshot))
    }

    static func isOAuthQuotaSnapshot(_ snapshot: QuotaSnapshot) -> Bool {
        snapshot.providerID == .claude
            && snapshot.fetchState == .success
            && snapshot.windows.contains { window in
                window.hasExplicitLimit
                    && window.unit.trimmingCharacters(in: .whitespacesAndNewlines) == "%"
            }
    }

    private func loadPersistedSnapshot() -> QuotaSnapshot? {
        guard let data = defaults.data(forKey: persistenceKey) else { return nil }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let snapshot = try? decoder.decode(QuotaSnapshot.self, from: data),
              Self.isOAuthQuotaSnapshot(snapshot) else {
            defaults.removeObject(forKey: persistenceKey)
            return nil
        }
        return snapshot
    }

    private func persist(_ snapshot: QuotaSnapshot) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(snapshot) else { return }
        defaults.set(data, forKey: persistenceKey)
    }

    private static func quotaOnlySnapshot(from snapshot: QuotaSnapshot) -> QuotaSnapshot {
        QuotaSnapshot(
            id: snapshot.id,
            providerID: snapshot.providerID,
            displayName: snapshot.displayName,
            planName: snapshot.planName,
            windows: snapshot.windows,
            stats: snapshot.stats,
            balances: snapshot.balances,
            fetchState: snapshot.fetchState,
            fetchedAt: snapshot.fetchedAt
        )
    }
}

private final class ClaudeTimeoutRaceState<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Never>?

    init(_ continuation: CheckedContinuation<Value, Never>) {
        self.continuation = continuation
    }

    func resume(with value: Value) -> Bool {
        lock.lock()
        guard let continuation else {
            lock.unlock()
            return false
        }
        self.continuation = nil
        lock.unlock()

        continuation.resume(returning: value)
        return true
    }
}

private actor ClaudeLocalEventScanCoordinator {
    static let shared = ClaudeLocalEventScanCoordinator()

    private var activeTask: Task<[UsageEvent], Never>?
    private var cachedEvents: [UsageEvent] = []
    private var cachedAt: Date?

    func cachedEvents(maxAge: TimeInterval, now: Date = Date()) -> [UsageEvent]? {
        guard let cachedAt, now.timeIntervalSince(cachedAt) < maxAge else {
            return nil
        }
        return cachedEvents
    }

    func startIfIdle(_ operation: @escaping @Sendable () async -> [UsageEvent]) -> Task<[UsageEvent], Never>? {
        guard activeTask == nil else {
            return nil
        }

        let task = Task {
            await operation()
        }
        activeTask = task

        Task {
            let events = await task.value
            finish(events: events)
        }

        return task
    }

    private func finish(events: [UsageEvent]) {
        cachedEvents = events
        cachedAt = Date()
        activeTask = nil
    }
}

// MARK: - Claude OAuth Token Management

/// Resolved Claude subscription tier, preferably derived from the live OAuth
/// profile and backed by the mirrored keychain metadata when profile lookup
/// is unavailable.
nonisolated struct ClaudePlanInfo: Equatable {
    /// Human-readable label for the card subtitle (e.g. "Pro", "Max x20").
    let displayName: String
    /// True for any flavour of Max plan — gates Max-only supplemental meters.
    let isMax: Bool
}

nonisolated enum ClaudePlanResolver {
    static func resolve(
        subscriptionType: String?,
        rateLimitTier: String?,
        organizationType: String? = nil
    ) -> ClaudePlanInfo? {
        let subscription = normalized(subscriptionType)
        let tier = normalized(rateLimitTier)
        let organization = normalized(organizationType)
        let combined = [subscription, tier, organization]
            .compactMap { $0 }
            .joined(separator: " ")

        guard !combined.isEmpty else { return nil }

        if combined.contains("max") {
            if combined.contains("20") {
                return ClaudePlanInfo(displayName: "Max x20", isMax: true)
            }
            if combined.contains("5") {
                return ClaudePlanInfo(displayName: "Max x5", isMax: true)
            }
            return ClaudePlanInfo(displayName: "Max", isMax: true)
        }

        if combined.contains("pro") {
            return ClaudePlanInfo(displayName: "Pro", isMax: false)
        }

        if combined.contains("team") {
            return ClaudePlanInfo(displayName: "Team", isMax: false)
        }

        if combined.contains("enterprise") {
            return ClaudePlanInfo(displayName: "Enterprise", isMax: false)
        }

        guard let fallback = subscription ?? organization ?? tier else {
            return nil
        }
        let displayName = fallback
            .replacingOccurrences(of: "claude_", with: "")
            .replacingOccurrences(of: "_", with: " ")
            .capitalized
        return ClaudePlanInfo(displayName: displayName, isMax: false)
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized.isEmpty ? nil : normalized
    }
}

/// One-shot diagnostic — prints the resolved plan info
/// alongside live Fable / Sonnet / Opus usage fields from the
/// /api/oauth/usage response, so we can confirm on any build whether the
/// model-specific meter gate sees what we expect. Fires at most once per
/// process launch to avoid log spam.
private final class ClaudeModelLimitDiagnostics: @unchecked Sendable {
    static let shared = ClaudeModelLimitDiagnostics()
    private let lock = NSLock()
    private var logged = false

    func logOnce(plan: ClaudePlanInfo?, fable: ClaudeOAuthWindow?, sonnet: ClaudeOAuthWindow?, opus: ClaudeOAuthWindow?) {
        lock.lock(); defer { lock.unlock() }
        guard !logged else { return }
        logged = true

        let planSummary: String = plan.map { "displayName=\($0.displayName) isMax=\($0.isMax)" } ?? "<nil>"
        let fableSummary = Self.summarize(fable)
        let sonnetSummary = Self.summarize(sonnet)
        let opusSummary = Self.summarize(opus)
        print("[ClaudeOAuth-Diag] plan=\(planSummary) fable=\(fableSummary) sonnetLegacy=\(sonnetSummary) opus=\(opusSummary)")
    }

    private static func summarize(_ window: ClaudeOAuthWindow?) -> String {
        guard let window else { return "<nil>" }
        let util = window.utilization.map { String($0) } ?? "<nil>"
        let resetsAt = window.resetAt.map { ISO8601DateFormatter().string(from: $0) } ?? "<nil>"
        return "{utilization=\(util), resets_at=\(resetsAt)}"
    }
}

/// Maps the raw `subscriptionType` / `rateLimitTier` fields out of the
/// `claudeAiOauth` keychain dict into a `ClaudePlanInfo`. Returns nil if
/// the keychain entry doesn't exist or doesn't carry a subscription type
/// (older Claude Code CLI builds) — in which case the caller falls back
/// to the generic "Claude Code" label.
///
/// Important caveat: these fields are baked into the OAuth credential at
/// the moment Claude Code CLI authorized, and Anthropic doesn't refresh
/// them on token rotation. If a user upgrades from Pro to Max but never
/// re-runs `/login` in the CLI, the keychain still reads "pro". The
/// `/api/oauth/usage` response itself is the live source of truth for
/// which model-specific meters actually exist for this token — see
/// `fetchOAuthQuota` for that gate.
private nonisolated func resolveClaudePlanInfo(allowKeychainLookup: Bool) -> ClaudePlanInfo? {
    guard allowKeychainLookup,
          let (creds, _) = ClaudeKeychainStore.readBest(allowClaudeCodeFallback: false) else {
        return nil
    }
    let raw = creds.rawOAuthDict

    return ClaudePlanResolver.resolve(
        subscriptionType: raw["subscriptionType"] as? String,
        rateLimitTier: raw["rateLimitTier"] as? String
    )
}

/// Holds the parsed payload of Claude Code's keychain entry. We carry the raw
/// `claudeAiOauth` dictionary alongside the typed fields so the access-token
/// mirror can retain non-secret metadata (subscriptionType, rateLimitTier,
/// scopes, etc.).
private nonisolated struct ClaudeOAuthCredentials {
    let accessToken: String
    let refreshToken: String?
    /// `expiresAt` from the keychain — milliseconds since the Unix epoch.
    let expiresAtMillis: Double?
    let scopes: [String]
    /// Full original `claudeAiOauth` dictionary for round-tripping.
    let rawOAuthDict: [String: Any]

    var expiresAt: Date? {
        guard let ms = expiresAtMillis else { return nil }
        return Date(timeIntervalSince1970: ms / 1000)
    }

    /// Returns true when the access token will expire within `buffer`.
    /// Treated as `false` when we have no expiry info (assume still valid; the
    /// API call itself will surface a 401 if it's actually dead).
    func needsRefresh(buffer: TimeInterval) -> Bool {
        guard let expiresAt else { return false }
        return Date().addingTimeInterval(buffer) >= expiresAt
    }
}

enum ClaudeOAuthCredentialPolicy {
    static let keychainAccessEnabledKey = "claudeKeychainOAuthEnabled"

    static func isClaudeCodeKeychainFallbackEnabled(in credentials: ProviderCredential?) -> Bool {
        isClaudeCodeKeychainFallbackEnabled(extraFields: credentials?.extraFields)
    }

    static func isClaudeCodeKeychainFallbackEnabled(extraFields: [String: String]?) -> Bool {
        guard let rawValue = extraFields?[keychainAccessEnabledKey] else {
            return false
        }

        switch rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "1", "true", "yes", "enabled":
            return true
        default:
            return false
        }
    }

    static func setClaudeCodeKeychainFallbackEnabled(_ enabled: Bool, in extraFields: inout [String: String]) {
        if enabled {
            extraFields[keychainAccessEnabledKey] = "true"
        } else {
            extraFields.removeValue(forKey: keychainAccessEnabledKey)
        }
    }
}

/// Reads the two keychain entries we treat as token stores:
///   1. Claude Code CLI's own entry  (service "Claude Code-credentials")
///   2. Our backup entry             (service "...ClaudeOAuthMirror")
///
/// Limit Counter only writes its own backup entry. Claude Code owns and
/// refreshes its item independently, and writing it from the background can
/// trigger repeat macOS password prompts.
private nonisolated enum ClaudeKeychainStore {
    static let claudeCodeService = "Claude Code-credentials"
    static let backupService = "com.chrisizatt.LLMUsageCounter.ClaudeOAuthMirror"

    private static var account: String { NSUserName() }

    static func readClaudeCode() -> ClaudeOAuthCredentials? { read(service: claudeCodeService) }
    static func readBackup() -> ClaudeOAuthCredentials? { read(service: backupService) }

    /// Returns the best available credential.
    ///
    /// **Reads the mirror first** and only falls back to Claude Code
    /// CLI's keychain entry when our mirror is empty. This avoids the
    /// macOS permission prompt that fires every time the CLI rewrites
    /// its own `Claude Code-credentials` entry (which it does roughly
    /// hourly when its OAuth token refreshes): the keychain ACL on
    /// that item is content-bound, so any rewrite by another process
    /// invalidates our trust list and macOS prompts again on next
    /// read.
    ///
    /// Once we've successfully read the CLI entry once (one prompt),
    /// we copy its access token and plan metadata into our own mirror
    /// so steady-state reads do not touch the CLI's entry. Claude Code
    /// remains the sole owner of refresh-token rotation; Limit Counter
    /// re-reads the CLI entry through the explicit recovery path.
    static func readBest(allowClaudeCodeFallback: Bool) -> (ClaudeOAuthCredentials, source: String)? {
        if let backup = readBackup() {
            // Migrate mirrors created by older builds, which retained Claude
            // Code's rotating refresh token. `write` strips it from backups.
            if backup.refreshToken != nil {
                _ = write(backup, service: backupService)
            }
            return (backup, backupService)
        }

        guard allowClaudeCodeFallback else {
            return nil
        }

        // Mirror missing (first launch, or user cleared keychain) —
        // fall back to the CLI's entry, which may prompt the user
        // exactly once for permission. Immediately mirror what we
        // get so future reads stay silent.
        if let cc = readClaudeCode() {
            _ = write(cc, service: backupService)
            print("[ClaudeKeychain] Mirrored Claude Code credentials to backup store — future reads will avoid CLI entry")
            return (cc, claudeCodeService)
        }

        return nil
    }

    /// Escape hatch for when the mirrored access token is rejected or near
    /// expiry. This can prompt, but it is only used by the explicit recovery
    /// path rather than during steady-state reads.
    static func readClaudeCodeAsFallback() -> ClaudeOAuthCredentials? {
        guard let cc = readClaudeCode() else { return nil }
        _ = write(cc, service: backupService)
        return cc
    }

    private static func read(service: String) -> ClaudeOAuthCredentials? {
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String:  true,
            kSecMatchLimit as String:  kSecMatchLimitOne
        ]
        var item: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = json["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String,
              !token.isEmpty else {
            return nil
        }

        return ClaudeOAuthCredentials(
            accessToken: token,
            refreshToken: oauth["refreshToken"] as? String,
            expiresAtMillis: (oauth["expiresAt"] as? NSNumber)?.doubleValue,
            scopes: (oauth["scopes"] as? [String]) ?? [],
            rawOAuthDict: oauth
        )
    }

    /// Writes the credentials back to the named service. Returns true on success.
    @discardableResult
    static func write(_ creds: ClaudeOAuthCredentials, service: String) -> Bool {
        // Re-serialize: preserve unknown keys and override the access-token
        // metadata we mirror. Never retain Claude Code's rotating refresh
        // token in Limit Counter's backup keychain item.
        var oauthDict = creds.rawOAuthDict
        oauthDict["accessToken"] = creds.accessToken
        if service == backupService {
            oauthDict.removeValue(forKey: "refreshToken")
        } else if let refreshToken = creds.refreshToken {
            oauthDict["refreshToken"] = refreshToken
        }
        if let ms = creds.expiresAtMillis {
            // Match Claude Code's storage format: integer milliseconds.
            oauthDict["expiresAt"] = NSNumber(value: Int64(ms))
        }

        let payload: [String: Any] = ["claudeAiOauth": oauthDict]
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else {
            return false
        }

        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]

        // Try update first; if the item doesn't exist (only true for our
        // backup service on first write), add it.
        let updateStatus = SecItemUpdate(query as CFDictionary, [kSecValueData: data] as CFDictionary)
        if updateStatus == errSecSuccess {
            return true
        }
        if updateStatus == errSecItemNotFound {
            var addQuery = query
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            return addStatus == errSecSuccess
        }
        print("[ClaudeKeychainStore] SecItemUpdate for \(service) failed: OSStatus \(updateStatus)")
        return false
    }
}

/// Resolves Anthropic OAuth access tokens without participating in Claude
/// Code's rotating refresh-token lineage. Claude Code is the sole refresh
/// client; Limit Counter only mirrors its current access token when the user
/// explicitly enables keychain recovery.
private actor ClaudeOAuthTokenManager {
    static let shared = ClaudeOAuthTokenManager()

    /// Re-read Claude Code's current credential this far ahead of expiry when
    /// the user explicitly enabled keychain recovery.
    private let refreshBuffer: TimeInterval = 5 * 60     // 5 min

    /// Returns the mirrored access token and, when permitted, replaces a
    /// near-expiry mirror with Claude Code's current access token.
    func currentAccessTokenFromKeychain(allowClaudeCodeFallback: Bool) -> String? {
        guard let (creds, source) = ClaudeKeychainStore.readBest(
            allowClaudeCodeFallback: allowClaudeCodeFallback
        ) else {
            return nil
        }

        if !creds.needsRefresh(buffer: refreshBuffer) {
            return creds.accessToken
        }

        if allowClaudeCodeFallback, source != ClaudeKeychainStore.claudeCodeService,
           let current = recoverFromClaudeCodeKeychain(
               rejectedToken: nil,
               reason: "mirrored access token near expiry"
           ) {
            return current
        }

        print("[ClaudeOAuth] Access token near expiry (source: \(source)); Claude Code owns token refresh")
        return creds.accessToken
    }

    /// Recovery path for when our mirrored OAuth token was invalidated or
    /// endpoint-throttled after Claude Code rewrote its own keychain item.
    /// This can prompt, so callers use it only after the mirror already failed.
    func accessTokenAfterOAuthFailure(
        rejectedToken: String?,
        reason: String,
        allowClaudeCodeFallback: Bool
    ) -> String? {
        guard allowClaudeCodeFallback else {
            return nil
        }

        return recoverFromClaudeCodeKeychain(
            rejectedToken: rejectedToken,
            reason: reason
        )
    }

    private func recoverFromClaudeCodeKeychain(
        rejectedToken: String?,
        reason: String
    ) -> String? {
        guard let fallback = ClaudeKeychainStore.readClaudeCodeAsFallback() else {
            return nil
        }

        if let rejectedToken, fallback.accessToken == rejectedToken {
            return nil
        }

        print("[ClaudeOAuth] \(reason) — retrying with current Claude Code keychain token")
        return fallback.accessToken
    }
}

/// Reads local Claude Code transcript metadata and usage snapshots.
/// If an OAuth token is supplied, fetches live 5-hour/7-day quota meters instead.
public struct ClaudeProviderClient: ProviderClient {
    public let providerID: ProviderID = .claude

    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    public func fetchSnapshot(credentials: ProviderCredential?) async throws -> QuotaSnapshot {
        // Resolution order:
        //   1. Token typed/pasted in Settings (always honored as-is)
        //   2. Limit Counter's mirrored OAuth token, if available
        //   3. Claude Code's own keychain item, only when explicitly enabled
        //   4. ~/.claude/.oauth_token file (headless / CI installs)
        let manualToken = credentials?.normalizedAccessToken
        let claudeCodeKeychainFallbackEnabled = ClaudeOAuthCredentialPolicy.isClaudeCodeKeychainFallbackEnabled(in: credentials)
        var oauthToken = manualToken
        var tokenAllowsKeychainRecovery = false
        var tokenAllowsKeychainPlanLookup = false

        if oauthToken == nil {
            oauthToken = await ClaudeOAuthTokenManager.shared.currentAccessTokenFromKeychain(
                allowClaudeCodeFallback: claudeCodeKeychainFallbackEnabled
            )
            tokenAllowsKeychainRecovery = oauthToken != nil && claudeCodeKeychainFallbackEnabled
            tokenAllowsKeychainPlanLookup = oauthToken != nil
        }
        if oauthToken == nil {
            oauthToken = Self.autoDetectedOAuthTokenFile()
        }
        if let token = oauthToken, !token.isEmpty {
            // 1) Serve fresh cached snapshot if we hit the endpoint very recently.
            if let cached = ClaudeOAuthResponseCache.shared.fresh() {
                print("[ClaudeProvider] Serving cached OAuth snapshot (fresh)")
                // Do not re-store cache hits here. The dashboard can refresh
                // every 15-60s; renewing the cache on read would keep old
                // OAuth meter values alive indefinitely.
                return cached
            }
            print("[ClaudeProvider] OAuth token found — fetching live quota")
            do {
                return try await fetchOAuthSnapshotAndMerge(
                    token: token,
                    credentials: credentials,
                    allowKeychainPlanLookup: tokenAllowsKeychainPlanLookup
                )
            } catch let error as ProviderFetchError {
                var effectiveError = error
                if tokenAllowsKeychainRecovery,
                   error.shouldRecoverClaudeOAuthFromKeychain,
                   let recoveredToken = await ClaudeOAuthTokenManager.shared.accessTokenAfterOAuthFailure(
                    rejectedToken: token,
                    reason: "OAuth usage fetch failed (\(error.localizedDescription))",
                    allowClaudeCodeFallback: claudeCodeKeychainFallbackEnabled
                   ) {
                    do {
                        return try await fetchOAuthSnapshotAndMerge(
                            token: recoveredToken,
                            credentials: credentials,
                            allowKeychainPlanLookup: true
                        )
                    } catch let retryError as ProviderFetchError {
                        print("[ClaudeProvider] Claude Code keychain recovery retry failed (\(retryError.localizedDescription))")
                        effectiveError = retryError
                    }
                }

                if let stale = ClaudeOAuthResponseCache.shared.staleFallback() {
                    print("[ClaudeProvider] OAuth fetch failure (\(effectiveError)) — serving last successful OAuth snapshot to preserve meters")
                    let events = await eventsForOAuthEnrichment(credentials: credentials)
                    let agbenchEvents = AGBenchUsageReader.loadEvents(forProviderKey: "claude")
                    return mergeEvents(into: stale, events: events + agbenchEvents)
                }

                if let localSnapshot = await loadLocalSnapshotIfAvailable(
                    credentials: credentials,
                    context: "OAuth fetch failure (\(effectiveError.localizedDescription))"
                ) {
                    print("[ClaudeProvider] OAuth fetch failed and no cached OAuth snapshot available; falling back to local Claude transcript snapshot")
                    return localSnapshot
                }

                throw effectiveError
            }
        }

        if let stale = ClaudeOAuthResponseCache.shared.staleFallback() {
            print("[ClaudeProvider] OAuth token unavailable — serving last successful OAuth snapshot to preserve meters")
            let events = await eventsForOAuthEnrichment(credentials: credentials)
            let agbenchEvents = AGBenchUsageReader.loadEvents(forProviderKey: "claude")
            return mergeEvents(into: stale, events: events + agbenchEvents)
        }

        // Fall back to local JSONL transcript parsing.
        let localSnapshot = try await loadLocalSnapshot(credentials: credentials, qos: .userInitiated)
        // Inject AGBench events here too so the local fallback path is
        // symmetric with the OAuth path above.
        let agbenchEvents = AGBenchUsageReader.loadEvents(forProviderKey: "claude")
        guard !agbenchEvents.isEmpty else { return localSnapshot }
        return mergeEvents(into: localSnapshot, events: localSnapshot.events + agbenchEvents)
    }

    private func fetchOAuthSnapshotAndMerge(
        token: String,
        credentials: ProviderCredential?,
        allowKeychainPlanLookup: Bool
    ) async throws -> QuotaSnapshot {
        let oauthSnapshot = try await fetchOAuthQuota(
            token: token,
            allowKeychainPlanLookup: allowKeychainPlanLookup
        )
        // Seed the source-aware fallback immediately. Local transcript scans
        // can be slow on large histories and must never make a successful
        // quota response disappear if the coordinator timeout wins the race.
        let immediatelyCached = mergeEvents(
            into: oauthSnapshot,
            events: previousClaudeEvents()
        )
        ClaudeOAuthResponseCache.shared.store(immediatelyCached)

        // Augment OAuth quota meters with locally-captured 2-hour buckets so
        // the activity heatmap still shows Claude usage even when the OAuth
        // path has no per-event data.
        let events = await eventsForOAuthEnrichment(credentials: credentials)
        // Plus AGBench's unified usage.json for any Claude runs driven
        // through TaskWraith. No-op without the bookmark.
        let agbenchEvents = AGBenchUsageReader.loadEvents(forProviderKey: "claude")
        let merged = mergeEvents(into: oauthSnapshot, events: events + agbenchEvents)
        ClaudeOAuthResponseCache.shared.store(merged)
        return merged
    }

    private func loadLocalSnapshot(
        credentials: ProviderCredential?,
        qos: DispatchQoS.QoSClass
    ) async throws -> QuotaSnapshot {
        let rootURL = resolvedClaudeRootURL(credentials: credentials)
        let bookmarkData = claudeBookmarkData(from: credentials)
        let reader = ClaudeCodeLocalStateReader(fileManager: fileManager)

        print("[ClaudeProvider] Reading local Claude Code logs from: \(rootURL.path)")
        let rawSnapshot: QuotaSnapshot = try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: qos).async {
                var accessURL = rootURL
                var didStartAccessing = false

                if let bookmarkData,
                   let bookmarkedURL = Self.resolvedSecurityScopedURL(from: bookmarkData) {
                    accessURL = bookmarkedURL
                    didStartAccessing = accessURL.startAccessingSecurityScopedResource()
                    print("[ClaudeProvider] Using security-scoped bookmark: \(accessURL.path)")
                }

                defer {
                    if didStartAccessing {
                        accessURL.stopAccessingSecurityScopedResource()
                    }
                }

                do {
                    continuation.resume(returning: try reader.loadSnapshot(rootURL: accessURL))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }

        let events = ClaudeHeatmapEventHistory.merged(
            current: rawSnapshot.events,
            previous: previousClaudeEvents()
        )
        return rawSnapshot.withEvents(events)
    }

    private func loadLocalSnapshotIfAvailable(
        credentials: ProviderCredential?,
        context: String
    ) async -> QuotaSnapshot? {
        do {
            let snapshot = try await loadLocalSnapshot(credentials: credentials, qos: .utility)
            logLocalSnapshotOutcome(snapshot, context: context)
            return snapshot
        } catch {
            print("[ClaudeProvider] Local scan FAILED during \(context) (\(error.localizedDescription))")
            return nil
        }
    }

    /// Best-effort local JSONL event extraction. Returns 2-hour bucketed
    /// `UsageEvent`s seen in `~/.claude/projects/**` so the activity heatmap
    /// still shows Claude even when the OAuth path supplies the quota meters.
    /// Returns `[]` for any error (no bookmark, no transcripts, sandbox denial).
    private func loadLocalEvents(credentials: ProviderCredential?) async -> [UsageEvent] {
        guard let snapshot = await loadLocalSnapshotIfAvailable(credentials: credentials, context: "OAuth enrichment") else {
            return []
        }
        return snapshot.events
    }

    private func eventsForOAuthEnrichment(credentials: ProviderCredential?) async -> [UsageEvent] {
        // Keep local enrichment comfortably inside SyncCoordinator's 15s
        // provider timeout. Long scans continue in the background and persist
        // their buckets for the next refresh, so quota availability never
        // depends on transcript size.
        if let localEvents = await loadLocalEventsWithinTimeout(
            credentials: credentials,
            timeoutSeconds: 4
        ), !localEvents.isEmpty {
            return localEvents
        }

        let previousEvents = previousClaudeEvents()
        if !previousEvents.isEmpty {
            print("[ClaudeProvider] Reusing \(previousEvents.count) previous Claude heatmap buckets for live OAuth snapshot")
        }
        return previousEvents
    }

    private func loadLocalEventsWithinTimeout(
        credentials: ProviderCredential?,
        timeoutSeconds: TimeInterval
    ) async -> [UsageEvent]? {
        if let cached = await ClaudeLocalEventScanCoordinator.shared.cachedEvents(maxAge: 5 * 60) {
            print("[ClaudeProvider] Reusing \(cached.count) locally-scanned Claude heatmap buckets")
            return cached
        }

        guard let loadTask = await ClaudeLocalEventScanCoordinator.shared.startIfIdle({
            await loadLocalEvents(credentials: credentials)
        }) else {
            print("[ClaudeProvider] Local heatmap enrichment scan already in progress; reusing previous Claude heatmap buckets")
            return nil
        }

        return await withCheckedContinuation { continuation in
            let state = ClaudeTimeoutRaceState<[UsageEvent]?>(continuation)
            Task {
                let events = await loadTask.value
                // If the timeout won the race we still finish the scan
                // and persist its results so the NEXT fetch sees fresh
                // buckets rather than reusing the same stale cache
                // forever. The current fetch already returned with the
                // cached fallback, but the heatmap will catch up on the
                // next refresh.
                if !state.resume(with: events) {
                    if !events.isEmpty {
                        persistLateClaudeScan(events: events)
                    }
                }
            }

            Task {
                let nanoseconds = UInt64(max(0, timeoutSeconds) * 1_000_000_000)
                try? await Task.sleep(nanoseconds: nanoseconds)
                if state.resume(with: nil) {
                    print("[ClaudeProvider] Local heatmap enrichment timed out after \(timeoutSeconds.compactString)s; scan will finish in background and persist for the next fetch")
                    // Do NOT cancel the load task — let it finish so its
                    // events get persisted for the next refresh.
                }
            }
        }
    }

    /// Updates the persisted Claude snapshot with freshly-scanned events
    /// when a scan finishes after the OAuth fetch already returned with
    /// cached fallback buckets. The card meters were already correct
    /// (they come from the live OAuth response); only the heatmap events
    /// need to be refreshed.
    private func persistLateClaudeScan(events: [UsageEvent]) {
        let store = QuotaSnapshotStore.shared
        guard let existing = store.loadSnapshots().first(where: { $0.providerID == .claude }) else {
            return
        }
        let updated = QuotaSnapshot(
            id: existing.id,
            providerID: existing.providerID,
            displayName: existing.displayName,
            planName: existing.planName,
            windows: existing.windows,
            stats: existing.stats,
            balances: existing.balances,
            signals: existing.signals,
            events: events,
            fetchState: existing.fetchState,
            fetchedAt: existing.fetchedAt
        )
        store.upsert(updated)
        print("[ClaudeProvider] Persisted \(events.count) late-arriving Claude heatmap buckets for next refresh")
    }

    private func logLocalSnapshotOutcome(_ snapshot: QuotaSnapshot, context: String) {
        if snapshot.events.isEmpty {
            print("[ClaudeProvider] Local scan during \(context) produced 0 heatmap buckets")
        } else {
            let oldest = snapshot.events.map(\.timestamp).min().map { String(describing: $0) } ?? "<unknown>"
            let newest = snapshot.events.map(\.timestamp).max().map { String(describing: $0) } ?? "<unknown>"
            print("[ClaudeProvider] Local scan during \(context) produced \(snapshot.events.count) heatmap buckets (oldest=\(oldest) newest=\(newest))")
        }
    }

    private func previousClaudeEvents(lookbackDays: Int = ClaudeHeatmapEventBucketer.defaultRetentionDays) -> [UsageEvent] {
        let horizon = Date().addingTimeInterval(-Double(lookbackDays) * 24 * 60 * 60)
        return QuotaSnapshotStore.shared.loadSnapshots()
            .first { $0.providerID == .claude && $0.fetchState == .success }?
            .events
            .filter { $0.timestamp >= horizon } ?? []
    }

    /// Returns a copy of `snapshot` with `events` attached. All other fields
    /// preserved verbatim. Used to graft local-disk activity events onto the
    /// server-provided OAuth quota snapshot.
    private func mergeEvents(into snapshot: QuotaSnapshot, events: [UsageEvent]) -> QuotaSnapshot {
        guard !events.isEmpty else { return snapshot }
        return QuotaSnapshot(
            id: snapshot.id,
            providerID: snapshot.providerID,
            displayName: snapshot.displayName,
            planName: snapshot.planName,
            windows: snapshot.windows,
            stats: snapshot.stats,
            balances: snapshot.balances,
            signals: snapshot.signals,
            events: events,
            fetchState: snapshot.fetchState,
            fetchedAt: snapshot.fetchedAt
        )
    }

    // Claude rebuilds bounded heatmap buckets from local transcripts on each
    // successful scan, so it does not use the raw-event history merge above.

    private func resolvedClaudeRootURL(credentials: ProviderCredential?) -> URL {
        if let customPath = credentials?.normalizedCustomEndpoint, !customPath.isEmpty {
            return URL(fileURLWithPath: customPath)
        }

        let homePath = NSHomeDirectory()
        let realHomePath: String
        if let containerRange = homePath.range(of: "/Library/Containers/") {
            realHomePath = String(homePath[..<containerRange.lowerBound])
        } else {
            realHomePath = homePath
        }
        return URL(fileURLWithPath: realHomePath).appendingPathComponent(".claude")
    }

    private func claudeBookmarkData(from credentials: ProviderCredential?) -> Data? {
        guard let encoded = credentials?.extraFields?["bookmarkData"],
              let data = Data(base64Encoded: encoded) else {
            return nil
        }

        return data
    }

    private static func resolvedSecurityScopedURL(from bookmarkData: Data) -> URL? {
        var isStale = false
        #if os(macOS)
        let options: URL.BookmarkResolutionOptions = [.withSecurityScope]
        #else
        let options: URL.BookmarkResolutionOptions = []
        #endif
        return try? URL(
            resolvingBookmarkData: bookmarkData,
            options: options,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )
    }

    /// Plain-text token file fallback used in headless / CI setups where
    /// `claude auth login --claudeai` is impractical. Keychain-based lookup
    /// and read-only Claude Code recovery are handled by
    /// `ClaudeOAuthTokenManager`.
    private static func autoDetectedOAuthTokenFile() -> String? {
        let homePath = NSHomeDirectory()
        let realHome: String
        if let r = homePath.range(of: "/Library/Containers/") {
            realHome = String(homePath[..<r.lowerBound])
        } else {
            realHome = homePath
        }
        let configDir = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"]
            ?? (realHome + "/.claude")
        guard let raw = try? String(contentsOfFile: configDir + "/.oauth_token", encoding: .utf8) else {
            return nil
        }
        let token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return token.isEmpty ? nil : token
    }

    // MARK: - OAuth Live Quota

    private func fetchOAuthQuota(
        token: String,
        allowKeychainPlanLookup: Bool
    ) async throws -> QuotaSnapshot {
        guard let url = URL(string: "https://api.anthropic.com/api/oauth/usage") else {
            throw ProviderFetchError.networkError(underlying: URLError(.badURL))
        }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw ProviderFetchError.networkError(underlying: error)
        }

        if let http = response as? HTTPURLResponse {
            switch http.statusCode {
            case 200: break
            case 401, 403: throw ProviderFetchError.invalidCredential
            case 429: throw ProviderFetchError.rateLimited
            default: throw ProviderFetchError.parsingError("HTTP \(http.statusCode)")
            }
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let string = try container.decode(String.self)
            let withFractional = ISO8601DateFormatter()
            withFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = withFractional.date(from: string) { return date }
            let plain = ISO8601DateFormatter()
            plain.formatOptions = [.withInternetDateTime]
            if let date = plain.date(from: string) { return date }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unparseable date: \(string)")
        }

        let usage: ClaudeOAuthUsageResponse
        do {
            usage = try decoder.decode(ClaudeOAuthUsageResponse.self, from: data)
        } catch {
            throw ProviderFetchError.parsingError("OAuth decode failed: \(error.localizedDescription)")
        }

        // The profile endpoint shares Anthropic's tight OAuth request budget.
        // Credential metadata is normally sufficient, so only issue the
        // second authenticated request when no plan information exists.
        let credentialPlan = resolveClaudePlanInfo(allowKeychainLookup: allowKeychainPlanLookup)
        let plan: ClaudePlanInfo?
        if let credentialPlan {
            plan = credentialPlan
        } else {
            plan = await fetchOAuthPlanInfo(token: token)
        }

        let fableWeeklyWindow = usage.fableWeeklyWindow

        // Targeted diagnostic: one-shot dump of plan + per-model field state
        // so we can tell, on any build, exactly why the Fable/Opus meters
        // do or don't render. Prints once per process launch.
        ClaudeModelLimitDiagnostics.shared.logOnce(
            plan: plan,
            fable: fableWeeklyWindow,
            sonnet: usage.sevenDaySonnet,
            opus: usage.sevenDayOpus
        )

        var windows: [QuotaWindow] = []
        if let w = usage.fiveHour, let utilization = w.utilization {
            windows.append(QuotaWindow(
                label: "Session",
                windowKind: .session,
                used: utilization,
                total: 100,
                resetDate: w.resetAt,
                unit: "%",
                subtitle: "5-hour rolling window"
            ))
        }
        if let w = usage.sevenDay, let utilization = w.utilization {
            windows.append(QuotaWindow(
                label: "Weekly",
                windowKind: .weekly,
                used: utilization,
                total: 100,
                resetDate: w.resetAt,
                unit: "%",
                subtitle: "7-day rolling window"
            ))
        }
        // Max-plan tokens get additional weekly caps for specific models.
        // The live response shape is the source of truth: if Anthropic sends
        // utilization, show the meter even when `resets_at` is absent.
        if let fableWindow = ClaudeOAuthModelWindowMapper.fableQuotaWindow(
            from: fableWeeklyWindow
        ) {
            windows.append(fableWindow)
        }
        if let opusWindow = ClaudeOAuthModelWindowMapper.quotaWindow(
            label: "Opus",
            subtitle: "Opus 7-day rolling window",
            from: usage.sevenDayOpus
        ) {
            windows.append(opusWindow)
        }

        var stats: [QuotaStat] = []
        let modelWindows: [(String, ClaudeOAuthWindow?)] = [
            ("Opus 7d", usage.sevenDayOpus),
            ("Fable 7d", fableWeeklyWindow),
            ("OAuth Apps 7d", usage.sevenDayOAuthApps)
        ]
        for (label, window) in modelWindows {
            if let w = window, let utilization = w.utilization {
                stats.append(QuotaStat(
                    label: label,
                    value: utilization,
                    unit: "%",
                    subtitle: "Model-specific weekly utilization"
                ))
            }
        }

        var balances: [QuotaBalance] = []
        if let extra = usage.extraUsage, extra.isEnabled {
            let unit = extra.currency ?? "credits"
            if let used = extra.usedCredits, let limit = extra.monthlyLimit {
                balances.append(QuotaBalance(
                    label: "Extra Usage",
                    amount: max(0, limit - used),
                    unit: unit,
                    subtitle: "\(used.compactString) of \(limit.compactString) \(unit) used this month",
                    resetDate: nil
                ))
            } else if let used = extra.usedCredits {
                balances.append(QuotaBalance(
                    label: "Extra Usage",
                    amount: used,
                    unit: unit,
                    subtitle: "Additional usage this month",
                    resetDate: nil
                ))
            }
        }

        return QuotaSnapshot(
            providerID: .claude,
            displayName: "Claude Code",
            planName: plan?.displayName ?? "Claude Code",
            windows: windows,
            stats: stats,
            balances: balances,
            fetchState: .success,
            fetchedAt: Date()
        )
    }

    private func fetchOAuthPlanInfo(token: String) async -> ClaudePlanInfo? {
        guard let url = URL(string: "https://api.anthropic.com/api/oauth/profile") else {
            return nil
        }

        var request = URLRequest(url: url, timeoutInterval: 3)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                print("[ClaudeProvider] OAuth profile unavailable; retaining credential plan metadata")
                return nil
            }

            let profile = try JSONDecoder().decode(ClaudeOAuthProfileResponse.self, from: data)
            return profile.planInfo
        } catch {
            print("[ClaudeProvider] OAuth profile lookup failed; retaining credential plan metadata")
            return nil
        }
    }
}

struct ClaudeHeatmapEventBucketer {
    static let defaultRetentionDays = 35

    static func events(
        from records: [ClaudeUsageRecord],
        now: Date = Date(),
        calendar: Calendar = .current,
        retentionDays: Int = defaultRetentionDays
    ) -> [UsageEvent] {
        let horizon = now.addingTimeInterval(-Double(retentionDays) * 24 * 60 * 60)
        var tokenTotals: [ClaudeHeatmapBucketKey: Double] = [:]
        var bucketStarts: [ClaudeHeatmapBucketKey: Date] = [:]

        for record in records where record.timestamp >= horizon {
            let key = ClaudeHeatmapBucketKey(date: record.timestamp, calendar: calendar)
            tokenTotals[key, default: 0] += record.tokens
            bucketStarts[key] = key.bucketStart(calendar: calendar)
        }

        return tokenTotals.compactMap { key, tokens in
            guard let bucketStart = bucketStarts[key], tokens > 0 else { return nil }
            return UsageEvent(
                timestamp: bucketStart,
                tokens: tokens,
                model: "Claude",
                type: .bucket
            )
        }
        .sorted { $0.timestamp > $1.timestamp }
    }
}

struct ClaudeHeatmapEventHistory {
    static func merged(
        current: [UsageEvent],
        previous: [UsageEvent],
        now: Date = Date(),
        retentionDays: Int = ClaudeHeatmapEventBucketer.defaultRetentionDays
    ) -> [UsageEvent] {
        let cutoff = now.addingTimeInterval(-Double(retentionDays) * 24 * 60 * 60)
        var eventsByBucket: [ClaudeHeatmapHistoryKey: UsageEvent] = [:]

        for event in previous where event.timestamp >= cutoff {
            eventsByBucket[ClaudeHeatmapHistoryKey(event: event)] = event
        }

        for event in current where event.timestamp >= cutoff {
            let key = ClaudeHeatmapHistoryKey(event: event)
            guard let existing = eventsByBucket[key] else {
                eventsByBucket[key] = event
                continue
            }

            if (event.tokens ?? 0) >= (existing.tokens ?? 0) {
                eventsByBucket[key] = event
            }
        }

        return eventsByBucket.values.sorted { $0.timestamp > $1.timestamp }
    }
}

private struct ClaudeHeatmapHistoryKey: Hashable {
    let timestamp: Date
    let model: String
    let type: UsageEvent.EventType

    init(event: UsageEvent) {
        timestamp = event.timestamp
        model = event.model ?? ""
        type = event.type
    }
}

private struct ClaudeHeatmapBucketKey: Hashable {
    let dayStart: Date
    let row: Int

    init(date: Date, calendar: Calendar) {
        dayStart = calendar.startOfDay(for: date)
        let hour = calendar.component(.hour, from: date)
        row = max(0, min(11, hour / 2))
    }

    func bucketStart(calendar: Calendar) -> Date {
        calendar.date(byAdding: .hour, value: row * 2, to: dayStart)
            ?? dayStart.addingTimeInterval(Double(row * 2) * 60 * 60)
    }
}

private struct ClaudeCodeLocalStateReader: @unchecked Sendable {
    private let fileManager: FileManager
    // These caps bounded the cost of re-parsing every transcript on every
    // refresh. TelemetryParseCache removes that cost — an unchanged transcript
    // is never parsed twice — so they can be set for accuracy instead.
    //
    // They were expensive: a 512 KB tail dropped the early turns of any long
    // session, and selecting 64 newest + 3/day up to 160 files silently
    // excluded in-window transcripts once enough newer chats existed, which
    // made long-window totals drift down as new chats arrived. `nil` reads the
    // whole file; `nil` scan cap keeps every transcript in the window.
    private static let newestTranscriptFilesPerScan: Int? = nil
    private static let historicalTranscriptFilesPerDay = 3
    private static let maxTranscriptFilesPerScan: Int? = nil
    private static let maxTranscriptBytesPerFile: Int? = nil
    private static let parseCacheProvider = "claude"

    private static let iso8601WithFractionalSeconds: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    init(fileManager: FileManager) {
        self.fileManager = fileManager
    }

    func loadSnapshot(rootURL: URL) throws -> QuotaSnapshot {
        let projectsRoot = rootURL.appendingPathComponent("projects")
        let rootExists = fileManager.fileExists(atPath: rootURL.path)
        let projectsExists = fileManager.fileExists(atPath: projectsRoot.path)
        guard rootExists || projectsExists else {
            throw ProviderFetchError.notConfigured
        }

        let transcriptInfos = discoverTranscriptURLs(in: projectsExists ? projectsRoot : rootURL)
        guard !transcriptInfos.isEmpty else {
            throw ProviderFetchError.notConfigured
        }

        let now = Date()
        let dayStart = now.addingTimeInterval(-24 * 60 * 60)
        let weekStart = now.addingTimeInterval(-7 * 24 * 60 * 60)
        let monthStart = now.addingTimeInterval(-30 * 24 * 60 * 60)
        let heatmapStart = now.addingTimeInterval(-Double(ClaudeHeatmapEventBucketer.defaultRetentionDays) * 24 * 60 * 60)
        let recentTranscriptInfos = transcriptInfos.filter { $0.modificationDate >= heatmapStart }
        let eligibleInfos = recentTranscriptInfos.isEmpty ? [transcriptInfos[0]] : recentTranscriptInfos
        let scanInfos = plannedTranscriptScan(from: eligibleInfos)
        let byteBudget = Self.maxTranscriptBytesPerFile.map { "max \($0 / 1024) KB each" } ?? "whole file"
        print(
            "[ClaudeProvider] Scanning \(scanInfos.count) of \(eligibleInfos.count) eligible transcripts "
                + "(\(byteBudget))"
        )

        var latestSessionURL: URL?
        var latestSessionDate = Date.distantPast
        var currentSessionTokens: Double = 0
        var dayTokens: Double = 0
        var weekTokens: Double = 0
        var monthTokens: Double = 0
        var latestActivity = Date.distantPast
        var heatmapRecords: [ClaudeUsageRecord] = []
        let metadata = loadMetadata(rootURL: rootURL)

        // Resuming or forking a chat rewrites the whole prior transcript into a
        // new file, so the same API call legitimately appears in several of
        // them. Per-file dedupe cannot see that; this can. It matters more now
        // that the scan covers every transcript rather than a recent subset.
        var seenCallsAcrossTranscripts = Set<String>()

        // Bounded to the transcripts actually in the scan window; chats that
        // rotate out of it stop being looked up.
        TelemetryParseCache.shared.prune(
            provider: Self.parseCacheProvider,
            keepingNewest: max(scanInfos.count * 2, 512)
        )

        for transcriptInfo in scanInfos {
            let transcriptURL = transcriptInfo.url
            let fileDate = transcriptInfo.modificationDate
            let allRecords = (try? readUsageRecords(from: transcriptURL)) ?? []
            let records = allRecords.filter { record in
                guard let identity = record.callIdentity else { return true }
                return seenCallsAcrossTranscripts.insert(identity).inserted
            }
            guard !records.isEmpty else { continue }

            let transcriptTokens = records.reduce(0.0) { $0 + $1.tokens }
            if fileDate > latestSessionDate {
                latestSessionDate = fileDate
                latestSessionURL = transcriptURL
                currentSessionTokens = transcriptTokens
            }

            for record in records {
                heatmapRecords.append(record)

                if record.timestamp >= dayStart {
                    dayTokens += record.tokens
                }
                if record.timestamp >= weekStart {
                    weekTokens += record.tokens
                }
                if record.timestamp >= monthStart {
                    monthTokens += record.tokens
                }
            }

            if let recordDate = records.map(\.timestamp).max(), recordDate > latestActivity {
                latestActivity = recordDate
            }
        }

        // No-op unless this scan parsed a transcript it hadn't seen before.
        TelemetryParseCache.shared.persist()

        guard latestSessionURL != nil else {
            throw ProviderFetchError.notConfigured
        }

        let windows = [
            QuotaWindow(
                label: "Session",
                windowKind: .session,
                used: currentSessionTokens,
                total: nil,
                resetDate: nil,
                unit: "tok",
                subtitle: "Local Claude Code transcript"
            ),
            QuotaWindow(
                label: "Weekly",
                windowKind: .weekly,
                used: weekTokens,
                total: nil,
                resetDate: nil,
                unit: "tok",
                subtitle: "Aggregated local Claude Code usage"
            )
        ]

        var stats = [
            QuotaStat(label: "24H Tokens", value: dayTokens, unit: "tok"),
            QuotaStat(label: "7D Tokens", value: weekTokens, unit: "tok"),
            QuotaStat(label: "30D Tokens", value: monthTokens, unit: "tok")
        ]
        var signals: [QuotaSignal] = []

        if let metadata {
            if let firstStartTime = metadata.firstStartTime {
                let ageDays = max(0, now.timeIntervalSince(firstStartTime) / 86_400)
                stats.append(
                    QuotaStat(
                        label: "Claude Install Age",
                        value: ageDays,
                        unit: "days",
                        subtitle: "Since local Claude setup was first recorded"
                    )
                )
            }

            if let projectCount = metadata.projectCount {
                stats.append(
                    QuotaStat(
                        label: "Tracked Projects",
                        value: Double(projectCount),
                        unit: "projects",
                        subtitle: "Projects remembered in local Claude config"
                    )
                )
            }

            if let trustedProjectCount = metadata.trustedProjectCount {
                stats.append(
                    QuotaStat(
                        label: "Trusted Projects",
                        value: Double(trustedProjectCount),
                        unit: "projects",
                        subtitle: "Projects with trust already granted"
                    )
                )
            }

            if let mcpContextCount = metadata.mcpContextCount {
                stats.append(
                    QuotaStat(
                        label: "MCP Context URIs",
                        value: Double(mcpContextCount),
                        unit: "uris",
                        subtitle: "Context URIs cached across Claude projects"
                    )
                )
            }

            if let enabledMCPServerCount = metadata.enabledMCPServerCount {
                stats.append(
                    QuotaStat(
                        label: "Enabled MCP Servers",
                        value: Double(enabledMCPServerCount),
                        unit: "servers",
                        subtitle: "Locally enabled project MCP entries"
                    )
                )
            }

            if let planDocumentCount = metadata.planDocumentCount {
                stats.append(
                    QuotaStat(
                        label: "Saved Plans",
                        value: Double(planDocumentCount),
                        unit: "docs",
                        subtitle: "Markdown planning docs under `.claude/plans`"
                    )
                )
            }

            if let backupCount = metadata.backupCount {
                stats.append(
                    QuotaStat(
                        label: "Config Backups",
                        value: Double(backupCount),
                        unit: "files",
                        subtitle: "Backups of local Claude config"
                    )
                )
            }

            if let userID = metadata.userID, !userID.isEmpty {
                signals.append(
                    QuotaSignal(
                        kind: .unexpectedRecovery,
                        title: "Local Claude profile detected",
                        message: "Using local Claude profile ID \(userID.prefix(8))... from the user-controlled config on disk.",
                        severity: .info,
                        detectedAt: now
                    )
                )
            }

            if let disabledReason = metadata.cachedExtraUsageDisabledReason, !disabledReason.isEmpty {
                signals.append(
                    QuotaSignal(
                        kind: .unexpectedRecovery,
                        title: "Extra usage currently disabled",
                        message: "Claude's local config reports the cached reason `\(disabledReason)`.",
                        severity: .info,
                        detectedAt: now
                    )
                )
            }
        }

        let planName = rootURL.lastPathComponent.isEmpty ? "Claude Code" : "Claude Code"
        let fetchedAt = latestActivity > .distantPast ? latestActivity : now
        let heatmapEvents = ClaudeHeatmapEventBucketer.events(from: heatmapRecords, now: now)

        return QuotaSnapshot(
            providerID: .claude,
            displayName: "Claude Code",
            planName: planName,
            windows: windows,
            stats: stats,
            signals: signals,
            events: heatmapEvents,
            fetchState: .success,
            fetchedAt: fetchedAt
        )
    }

    private func loadMetadata(rootURL: URL) -> ClaudeLocalMetadata? {
        let configURL = rootURL.deletingLastPathComponent().appendingPathComponent("\(rootURL.lastPathComponent).json")
        let plansURL = rootURL.appendingPathComponent("plans")
        let backupsURL = rootURL.appendingPathComponent("backups")

        var metadata = ClaudeLocalMetadata()
        var hasMetadata = false

        if let configData = try? Data(contentsOf: configURL),
           let json = (try? JSONSerialization.jsonObject(with: configData)) as? [String: Any] {
            metadata.userID = nonEmptyString(json["userID"])
            metadata.firstStartTime = parseTimestamp(nonEmptyString(json["firstStartTime"]))
            metadata.cachedExtraUsageDisabledReason = nonEmptyString(json["cachedExtraUsageDisabledReason"])

            if let projects = json["projects"] as? [String: Any] {
                metadata.projectCount = projects.count
                metadata.trustedProjectCount = projects.values.reduce(into: 0) { partialResult, value in
                    guard let project = value as? [String: Any] else { return }
                    if (project["hasTrustDialogAccepted"] as? Bool) == true {
                        partialResult += 1
                    }
                }
                metadata.mcpContextCount = projects.values.reduce(into: 0) { partialResult, value in
                    guard let project = value as? [String: Any],
                          let contexts = project["mcpContextUris"] as? [Any] else { return }
                    partialResult += contexts.count
                }
                metadata.enabledMCPServerCount = projects.values.reduce(into: 0) { partialResult, value in
                    guard let project = value as? [String: Any],
                          let servers = project["enabledMcpjsonServers"] as? [Any] else { return }
                    partialResult += servers.count
                }
            }

            hasMetadata = true
        }

        if let planDocumentCount = countFiles(in: plansURL, matchingExtension: "md") {
            metadata.planDocumentCount = planDocumentCount
            hasMetadata = true
        }

        if let backupCount = countFiles(in: backupsURL, matchingPrefix: ".claude.json.backup") {
            metadata.backupCount = backupCount
            hasMetadata = true
        }

        return hasMetadata ? metadata : nil
    }

    private func discoverTranscriptURLs(in root: URL) -> [ClaudeTranscriptInfo] {
        var urls: [ClaudeTranscriptInfo] = []
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return urls
        }

        for case let url as URL in enumerator {
            if url.pathExtension.lowercased() == "jsonl" {
                let fileDate = (try? fileManager.attributesOfItem(atPath: url.path)[.modificationDate] as? Date) ?? .distantPast
                urls.append(ClaudeTranscriptInfo(url: url, modificationDate: fileDate))
            }
        }

        return urls.sorted { lhs, rhs in
            lhs.modificationDate > rhs.modificationDate
        }
    }

    private func plannedTranscriptScan(from infos: [ClaudeTranscriptInfo]) -> [ClaudeTranscriptInfo] {
        guard let maxFiles = Self.maxTranscriptFilesPerScan,
              let newestFiles = Self.newestTranscriptFilesPerScan,
              infos.count > maxFiles else {
            return infos
        }

        var selected = Array(infos.prefix(newestFiles))
        var selectedPaths = Set(selected.map { $0.url.path })
        let calendar = Calendar.current
        var selectedPerDay: [Date: Int] = [:]

        for info in selected {
            selectedPerDay[calendar.startOfDay(for: info.modificationDate), default: 0] += 1
        }

        for info in infos {
            guard selected.count < maxFiles else { break }
            guard !selectedPaths.contains(info.url.path) else { continue }

            let day = calendar.startOfDay(for: info.modificationDate)
            guard selectedPerDay[day, default: 0] < Self.historicalTranscriptFilesPerDay else {
                continue
            }

            selected.append(info)
            selectedPaths.insert(info.url.path)
            selectedPerDay[day, default: 0] += 1
        }

        return selected
    }

    /// Transcripts are append-only, so a parsed one stays valid until its mtime
    /// or size moves. Caching per file is what makes reading them whole — and
    /// reading all of them — affordable on a periodic refresh.
    private func readUsageRecords(from url: URL) throws -> [ClaudeUsageRecord] {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let modifiedAt = (attributes?[.modificationDate] as? Date) ?? .distantPast
        let size = (attributes?[.size] as? Int) ?? 0

        if let payload = TelemetryParseCache.shared.payload(
            provider: Self.parseCacheProvider,
            path: url.path,
            modifiedAt: modifiedAt,
            size: size
        ), let cached = try? JSONDecoder().decode([ClaudeUsageRecord].self, from: payload) {
            return cached
        }

        let records = try ClaudeJSONLUsageRecordReader.readUsageRecords(
            from: url,
            maxBytes: Self.maxTranscriptBytesPerFile,
            parseTimestamp: parseTimestamp(_:)
        )
        if let payload = try? JSONEncoder().encode(records) {
            TelemetryParseCache.shared.store(
                provider: Self.parseCacheProvider,
                path: url.path,
                modifiedAt: modifiedAt,
                size: size,
                payload: payload
            )
        }
        return records
    }

    private func parseTimestamp(_ string: String?) -> Date? {
        guard let string else { return nil }
        if let date = Self.iso8601WithFractionalSeconds.date(from: string) {
            return date
        }
        let fallback = ISO8601DateFormatter()
        fallback.formatOptions = [.withInternetDateTime]
        return fallback.date(from: string)
    }

    private func nonEmptyString(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func countFiles(in directoryURL: URL, matchingExtension pathExtension: String) -> Int? {
        guard let contents = try? fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        return contents.filter { $0.pathExtension.lowercased() == pathExtension.lowercased() }.count
    }

    private func countFiles(in directoryURL: URL, matchingPrefix prefix: String) -> Int? {
        guard let contents = try? fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: []
        ) else {
            return nil
        }

        return contents.filter { $0.lastPathComponent.hasPrefix(prefix) }.count
    }
}

struct ClaudeJSONLUsageRecordReader {
    private static let defaultChunkSize = 1024 * 1024

    static func readUsageRecords(
        from url: URL,
        chunkSize: Int = defaultChunkSize,
        maxBytes: Int? = nil,
        parseTimestamp: (String?) -> Date?
    ) throws -> [ClaudeUsageRecord] {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        let endOffset = try handle.seekToEnd()
        let byteLimit = maxBytes.map { UInt64(max(1, $0)) }
        let startOffset = byteLimit.map { endOffset > $0 ? endOffset - $0 : 0 } ?? 0
        try handle.seek(toOffset: startOffset)

        var records: [ClaudeUsageRecord] = []
        var seenUsageKeys = Set<String>()
        var buffer = Data()
        let readSize = max(4096, chunkSize)
        var discardLeadingPartialLine = startOffset > 0

        while let chunk = try handle.read(upToCount: readSize), !chunk.isEmpty {
            buffer.append(chunk)
            if discardLeadingPartialLine {
                guard let newline = buffer.firstIndex(of: 0x0A) else {
                    continue
                }
                buffer.removeSubrange(buffer.startIndex...newline)
                discardLeadingPartialLine = false
            }
            consumeCompleteLines(
                from: &buffer,
                records: &records,
                seenUsageKeys: &seenUsageKeys,
                parseTimestamp: parseTimestamp
            )
        }

        if !discardLeadingPartialLine, !buffer.isEmpty {
            autoreleasepool {
                appendUsageRecord(
                    from: buffer,
                    records: &records,
                    seenUsageKeys: &seenUsageKeys,
                    parseTimestamp: parseTimestamp
                )
            }
        }

        return records
    }

    private static func consumeCompleteLines(
        from buffer: inout Data,
        records: inout [ClaudeUsageRecord],
        seenUsageKeys: inout Set<String>,
        parseTimestamp: (String?) -> Date?
    ) {
        var lineStart = buffer.startIndex

        while lineStart < buffer.endIndex,
              let newline = buffer[lineStart..<buffer.endIndex].firstIndex(of: 0x0A) {
            let lineData = Data(buffer[lineStart..<newline])
            autoreleasepool {
                appendUsageRecord(
                    from: lineData,
                    records: &records,
                    seenUsageKeys: &seenUsageKeys,
                    parseTimestamp: parseTimestamp
                )
            }
            lineStart = buffer.index(after: newline)
        }

        if lineStart > buffer.startIndex {
            buffer.removeSubrange(buffer.startIndex..<lineStart)
        }
    }

    private static func appendUsageRecord(
        from lineData: Data,
        records: inout [ClaudeUsageRecord],
        seenUsageKeys: inout Set<String>,
        parseTimestamp: (String?) -> Date?
    ) {
        guard !lineData.isEmpty,
              let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
              let timestamp = parseTimestamp(json["timestamp"] as? String) else {
            return
        }

        let usageObject = (json["usage"] as? [String: Any]) ?? (json["message"] as? [String: Any])?["usage"] as? [String: Any]
        guard let usageObject else { return }

        let tokens = tokenCount(from: usageObject)
        guard tokens > 0 else { return }

        // One assistant message spanning several content blocks is written as
        // one row per block, and every row repeats the SAME usage object — a
        // 12-tool-call turn writes 12 rows each restating the whole turn's
        // tokens. requestId + messageId identifies the single API call behind
        // them. The timestamp must stay OUT of the key: those rows differ by
        // sub-second write time, so including it meant the key never matched
        // and each block was billed in full (~2.2x over-count measured against
        // this machine's transcripts).
        let requestID = (json["requestId"] as? String) ?? ""
        let messageID = ((json["message"] as? [String: Any])?["id"] as? String) ?? ""
        let callIdentity = requestID.isEmpty && messageID.isEmpty
            ? "ts:\(timestamp.timeIntervalSince1970)"
            : "\(requestID)|\(messageID)"
        let dedupeKey = "\(callIdentity)|\(Int(tokens))"
        guard seenUsageKeys.insert(dedupeKey).inserted else { return }

        records.append(
            ClaudeUsageRecord(timestamp: timestamp, tokens: tokens, callIdentity: dedupeKey)
        )
    }

    private static func tokenCount(from usage: [String: Any]) -> Double {
        func number(_ key: String) -> Double {
            if let value = usage[key] as? Double { return value }
            if let value = usage[key] as? Int { return Double(value) }
            if let value = usage[key] as? NSNumber { return value.doubleValue }
            return 0
        }

        // Each JSONL line is a single API call, so cache fields are safe to include:
        // they are not repeated across lines and they do count toward Claude Code's rate limits.
        return number("input_tokens")
            + number("output_tokens")
            + number("cache_creation_input_tokens")
            + number("cache_read_input_tokens")
            + number("input_audio_tokens")
            + number("output_audio_tokens")
    }
}

struct ClaudeUsageRecord: Codable {
    let timestamp: Date
    let tokens: Double
    /// requestId+messageId of the API call this row came from, used to dedupe
    /// the same call across transcripts. Nil when the row carried neither id.
    let callIdentity: String?

    init(timestamp: Date, tokens: Double, callIdentity: String? = nil) {
        self.timestamp = timestamp
        self.tokens = tokens
        self.callIdentity = callIdentity
    }

    enum CodingKeys: String, CodingKey {
        case timestamp = "t"
        case tokens = "k"
        case callIdentity = "c"
    }
}

private struct ClaudeTranscriptInfo {
    let url: URL
    let modificationDate: Date
}

private struct ClaudeLocalMetadata {
    var userID: String?
    var firstStartTime: Date?
    var cachedExtraUsageDisabledReason: String?
    var projectCount: Int?
    var trustedProjectCount: Int?
    var mcpContextCount: Int?
    var enabledMCPServerCount: Int?
    var planDocumentCount: Int?
    var backupCount: Int?
}

// MARK: - Fetch Error

public enum ProviderFetchError: LocalizedError {
    case notConfigured
    case invalidCredential
    case credentialExpired(String)
    case networkError(underlying: Error)
    case parsingError(String)
    case rateLimited
    case unknown

    public var errorDescription: String? {
        switch self {
        case .notConfigured:          return "Provider not configured."
        case .invalidCredential:      return "Invalid API key or session."
        case .credentialExpired(let msg):
            return msg
        case .networkError(let e):    return "Network error: \(e.localizedDescription)"
        case .parsingError(let msg):  return "Parse error: \(msg)"
        case .rateLimited:            return "Rate limited. Try again later."
        case .unknown:                return "An unknown error occurred."
        }
    }
}

private extension ProviderFetchError {
    var shouldRecoverClaudeOAuthFromKeychain: Bool {
        switch self {
        case .invalidCredential, .rateLimited:
            return true
        case .notConfigured, .credentialExpired, .networkError, .parsingError, .unknown:
            return false
        }
    }
}

// MARK: - Ollama Cloud Provider Client

/// Keeps the Ollama weekly reset date stable across syncs. The settings page
/// only exposes a coarse relative countdown ("Sessions resume in 5 days"), so
/// recomputing `now + N days` on every sync would creep the displayed reset
/// forward; within one limit episode the first computed date wins.
enum OllamaWeeklyResetStore {
    private static let appGroupID = "group.com.chrisizatt.LLMUsageCounter"
    private static let resetDateKey = "ollama.weeklyReset.date"
    private static let sameEpisodeTolerance: TimeInterval = 1.5 * 86_400

    static func stabilizedResetDate(
        candidate: Date,
        now: Date = Date(),
        defaults overrideDefaults: UserDefaults? = nil
    ) -> Date {
        let defaults = overrideDefaults ?? UserDefaults(suiteName: appGroupID) ?? .standard
        if let stored = defaults.object(forKey: resetDateKey) as? Date,
           stored > now,
           abs(stored.timeIntervalSince(candidate)) <= sameEpisodeTolerance {
            return stored
        }
        defaults.set(candidate, forKey: resetDateKey)
        return candidate
    }
}

public struct OllamaProviderClient: ProviderClient {
    public let providerID: ProviderID = .ollama

    public init() {}

    public func fetchSnapshot(credentials: ProviderCredential?) async throws -> QuotaSnapshot {
        guard let credentials, !credentials.isEmpty else {
            throw ProviderFetchError.notConfigured
        }

        let rawCookie = credentials.normalizedAccessToken
            ?? credentials.extraFields?["ollamaCookie"]
            ?? credentials.accountIdentifier

        guard let rawCookie = rawCookie?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawCookie.isEmpty else {
            throw ProviderFetchError.notConfigured
        }

        let sessionCookie = normalizeCookie(rawCookie)
        let customURLString = credentials.customEndpoint?.trimmingCharacters(in: .whitespacesAndNewlines)
        let endpointURL = (customURLString?.isEmpty == false ? URL(string: customURLString!) : nil)
            ?? URL(string: "https://ollama.com/settings")!

        var request = URLRequest(url: endpointURL, timeoutInterval: 15)
        request.httpMethod = "GET"
        request.setValue(sessionCookie, forHTTPHeaderField: "Cookie")
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125.0.0.0 Safari/537.36",
            forHTTPHeaderField: "User-Agent"
        )
        request.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw ProviderFetchError.networkError(underlying: error)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ProviderFetchError.networkError(underlying: NSError(domain: "OllamaProvider", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid response from ollama.com"]))
        }

        if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 || httpResponse.url?.path.contains("/login") == true {
            throw ProviderFetchError.credentialExpired("Ollama session cookie expired or invalid. Please update in settings.")
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            throw ProviderFetchError.parsingError("HTTP \(httpResponse.statusCode) from ollama.com")
        }

        guard let html = String(data: data, encoding: .utf8) else {
            throw ProviderFetchError.parsingError("Unable to decode Ollama response HTML")
        }

        return try parseOllamaSettingsHTML(html, fetchedAt: Date())
    }

    private func normalizeCookie(_ input: String) -> String {
        var trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("Cookie:") {
            trimmed = trimmed.replacingOccurrences(of: "Cookie:", with: "").trimmingCharacters(in: .whitespaces)
        }
        if trimmed.contains("__Secure-session=") {
            return trimmed
        }
        return "__Secure-session=\(trimmed)"
    }

    private struct ExtractedMetric {
        let percent: Double
        let resetDate: Date?
        let resetDescription: String?
    }

    private struct WeeklyLimitBanner {
        let resumeDate: Date?
    }

    func parseOllamaSettingsHTML(
        _ html: String,
        fetchedAt: Date,
        defaults: UserDefaults? = nil
    ) throws -> QuotaSnapshot {
        if html.contains("Sign in to Ollama") || (html.contains("/login") && !html.contains("Session usage") && !html.contains("Weekly usage")) {
            throw ProviderFetchError.credentialExpired("Ollama session cookie expired or invalid. Please update in settings.")
        }

        var windows: [QuotaWindow] = []

        let (sessionChunk, weeklyChunk) = extractSections(from: html)
        // The weekly-limit banner sits between the two usage headings, so it is
        // detected once against the whole usage region and attributed to the
        // weekly window rather than whichever chunk it happens to land in.
        let banner = parseWeeklyLimitBanner(in: (sessionChunk ?? "") + (weeklyChunk ?? ""), now: fetchedAt)

        if let sessionChunk {
            let cleanedChunk = banner == nil ? sessionChunk : removingWeeklyBannerPhrases(from: sessionChunk)
            if let sessionMetric = parseMetricFromChunk(cleanedChunk, isWeekly: false, now: fetchedAt) {
                var resetDate = sessionMetric.resetDate
                var resetDescription = sessionMetric.resetDescription
                if banner != nil, let candidate = resetDate, candidate.timeIntervalSince(fetchedAt) >= 86_400 {
                    resetDate = nil
                    resetDescription = nil
                }
                windows.append(
                    QuotaWindow(
                        label: "Session usage",
                        windowKind: .session,
                        used: sessionMetric.percent,
                        total: 100,
                        resetDate: resetDate,
                        unit: "%",
                        subtitle: resetDescription ?? (banner == nil ? "5-hour sliding window" : "Blocked until weekly reset")
                    )
                )
            }
        }

        if let weeklyChunk {
            let weeklyMetric = parseMetricFromChunk(weeklyChunk, isWeekly: true, now: fetchedAt)
            if let percent = weeklyMetric?.percent ?? (banner == nil ? nil : 100) {
                var resetDate = weeklyMetric?.resetDate
                var subtitle = weeklyMetric?.resetDescription ?? "Weekly rolling window"
                if let banner {
                    resetDate = banner.resumeDate ?? resetDate
                    subtitle = "Weekly limit reached"
                }
                if let candidate = resetDate {
                    resetDate = OllamaWeeklyResetStore.stabilizedResetDate(candidate: candidate, now: fetchedAt, defaults: defaults)
                }
                windows.append(
                    QuotaWindow(
                        label: "Weekly usage",
                        windowKind: .weekly,
                        used: percent,
                        total: 100,
                        resetDate: resetDate,
                        unit: "%",
                        subtitle: subtitle
                    )
                )
            }
        }

        guard !windows.isEmpty else {
            if html.contains("Sign in") || html.contains("Log in") {
                throw ProviderFetchError.credentialExpired("Ollama session cookie expired. Please update in settings.")
            }
            throw ProviderFetchError.parsingError("Could not find Session or Weekly usage on ollama.com/settings")
        }

        return QuotaSnapshot(
            providerID: .ollama,
            displayName: "Ollama",
            planName: nil,
            windows: windows,
            stats: [],
            balances: [],
            signals: [],
            events: [],
            fetchState: .success,
            fetchedAt: fetchedAt
        )
    }

    private func extractSections(from html: String) -> (session: String?, weekly: String?) {
        let sessionRange = html.range(of: "Session usage", options: .caseInsensitive)
        let weeklyRange = html.range(of: "Weekly usage", options: .caseInsensitive)

        func forwardChunk(from start: String.Index) -> String {
            var end = html.index(start, offsetBy: min(1000, html.distance(from: start, to: html.endIndex)))
            if let modelsRange = html.range(of: "Models used", options: .caseInsensitive, range: start..<html.endIndex) {
                end = min(end, modelsRange.lowerBound)
            }
            return String(html[start..<end])
        }

        var sessionChunk: String? = nil
        var weeklyChunk: String? = nil

        if let sRange = sessionRange {
            if let wRange = weeklyRange, wRange.lowerBound > sRange.lowerBound {
                sessionChunk = String(html[sRange.lowerBound..<wRange.lowerBound])
            } else {
                sessionChunk = forwardChunk(from: sRange.lowerBound)
            }
        }

        if let wRange = weeklyRange {
            weeklyChunk = forwardChunk(from: wRange.lowerBound)
        }

        return (sessionChunk, weeklyChunk)
    }

    private func parseWeeklyLimitBanner(in usageRegion: String, now: Date) -> WeeklyLimitBanner? {
        var resumeDate: Date? = nil
        var resumeIsMultiDay = false
        if let groups = firstMatchGroups(in: usageRegion, pattern: #"[Ss]essions?\s+resume\s+in\s+([0-9]+)\s*(days?|d\b|hours?|hrs?|h\b)"#),
           groups.count == 2,
           let value = Double(groups[0]) {
            let interval = value * (groups[1].lowercased().hasPrefix("d") ? 86_400 : 3_600)
            resumeDate = now.addingTimeInterval(interval)
            resumeIsMultiDay = interval >= 86_400
        }
        if usageRegion.localizedCaseInsensitiveContains("Weekly limit reached") {
            return WeeklyLimitBanner(resumeDate: resumeDate)
        }
        // A "session" that resumes in a day or more is the weekly block; the
        // real session window is a 5-hour slide.
        return resumeIsMultiDay ? WeeklyLimitBanner(resumeDate: resumeDate) : nil
    }

    private func removingWeeklyBannerPhrases(from chunk: String) -> String {
        var cleaned = chunk
        for pattern in [
            #"[Ww]eekly\s+limit\s+reached"#,
            #"[Ss]essions?\s+resume\s+in\s+[0-9]+\s*(?:days?|d\b|hours?|hrs?|h\b)"#
        ] {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            let range = NSRange(cleaned.startIndex..<cleaned.endIndex, in: cleaned)
            cleaned = regex.stringByReplacingMatches(in: cleaned, options: [], range: range, withTemplate: "")
        }
        return cleaned
    }

    private func parseMetricFromChunk(_ chunk: String, isWeekly: Bool, now: Date) -> ExtractedMetric? {
        var percent: Double? = nil

        if isWeekly && (chunk.localizedCaseInsensitiveContains("Limit reached") || chunk.localizedCaseInsensitiveContains("100% used")) {
            percent = 100.0
        } else if let ariaNow = firstMatch(in: chunk, pattern: #"aria-valuenow="([0-9]+(?:\.[0-9]+)?)""#) {
            percent = Double(ariaNow)
        } else if let ariaMatch = firstMatch(in: chunk, pattern: #"aria-label="[^"]*?([0-9]+(?:\.[0-9]+)?)\s*%[^"]*""#) {
            percent = Double(ariaMatch)
        } else if let widthStr = firstMatch(in: chunk, pattern: #"(?<![-\w])width:\s*([0-9]+(?:\.[0-9]+)?)\s*%"#) {
            percent = Double(widthStr)
        } else if let pctStr = firstMatch(in: chunk, pattern: #"([0-9]+(?:\.[0-9]+)?)\s*%\s*used"#) {
            percent = Double(pctStr)
        } else if let pctStr = firstMatch(in: String(chunk.prefix(300)), pattern: #"(?<=[>\s])([0-9]+(?:\.[0-9]+)?)\s*%"#) {
            // Last resort: a bare percentage, and only near the usage heading
            // the chunk starts with — never from deep, unrelated markup.
            percent = Double(pctStr)
        }

        guard let percent else { return nil }

        var resetDate: Date? = nil
        var resetDesc: String? = nil

        if let resumeMatch = firstMatch(in: chunk, pattern: #"(?:[Ss]essions?\s+resume\s+in\s+([0-9]+)\s*(?:days?|d))"#) {
            if let days = Double(resumeMatch) {
                resetDate = now.addingTimeInterval(days * 86400)
                resetDesc = "Resumes in \(Int(days))d"
            }
        } else if let resumeMatch = firstMatch(in: chunk, pattern: #"(?:[Ss]essions?\s+resume\s+in\s+([0-9]+)\s*(?:hours?|hrs?|h))"#) {
            if let hours = Double(resumeMatch) {
                resetDate = now.addingTimeInterval(hours * 3600)
                resetDesc = "Resumes in \(Int(hours))h"
            }
        } else if let resetMatch = firstMatch(in: chunk, pattern: #"(?:[Rr]esets?\s+in\s+([0-9]+)\s*(?:hours?|hrs?|h))"#) {
            if let hours = Double(resetMatch) {
                resetDate = now.addingTimeInterval(hours * 3600)
                resetDesc = "Resets in \(Int(hours))h"
            }
        } else if let resetMatch = firstMatch(in: chunk, pattern: #"(?:[Rr]esets?\s+in\s+([0-9]+)\s*(?:days?|d))"#) {
            if let days = Double(resetMatch) {
                resetDate = now.addingTimeInterval(days * 86400)
                resetDesc = "Resets in \(Int(days))d"
            }
        }

        return ExtractedMetric(
            percent: min(max(percent, 0), 100),
            resetDate: resetDate,
            resetDescription: resetDesc
        )
    }

    private func firstMatch(in text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: nsRange) else {
            return nil
        }
        if match.numberOfRanges > 1, let range = Range(match.range(at: 1), in: text) {
            return String(text[range])
        } else if let range = Range(match.range(at: 0), in: text) {
            return String(text[range])
        }
        return nil
    }

    private func firstMatchGroups(in text: String, pattern: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: nsRange) else {
            return nil
        }
        var groups: [String] = []
        for index in 1..<match.numberOfRanges {
            guard let range = Range(match.range(at: index), in: text) else { return nil }
            groups.append(String(text[range]))
        }
        return groups
    }
}
