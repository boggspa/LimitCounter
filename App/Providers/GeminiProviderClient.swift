import Foundation

/// Reads local Gemini CLI history and metadata from the user's machine.
/// This is a no-API, user-controlled source that turns session files into
/// normalized usage snapshots.
///
/// Request Quotas (based on Gemini CLI documentation):
/// - OAuth Personal (Google account): 1,000 requests/day
/// - API Key (free tier): 250 requests/day (Flash model only)
/// - Vertex AI Express: varies by account
public struct GeminiProviderClient: ProviderClient {
    public let providerID: ProviderID = .gemini

    private let fileManager: FileManager

    // Throttling for CLI-based quota fetch (e.g. 1 minute)
    private static var lastCLIFetch: Date?
    private static var cachedCLIQuota: GeminiCLIQuota?
    private static let cliFetchInterval: TimeInterval = 60

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    public func fetchSnapshot(credentials: ProviderCredential?) async throws -> QuotaSnapshot {
        let rootURL = resolvedGeminiRootURL(credentials: credentials)
        let bookmarkData = geminiBookmarkData(from: credentials)

        // Resolve security-scoped bookmark up front; both the live OAuth read
        // (oauth_creds.json) and the local history scan share it.
        var accessURL = rootURL
        var didStartAccessing = false
        if let bookmarkData,
           let bookmarkedURL = Self.resolvedSecurityScopedURL(from: bookmarkData) {
            accessURL = bookmarkedURL
            didStartAccessing = accessURL.startAccessingSecurityScopedResource()
            print("[GeminiProvider] Using security-scoped bookmark: \(accessURL.path)")
        }
        defer {
            if didStartAccessing {
                accessURL.stopAccessingSecurityScopedResource()
            }
        }

        // Try the live Code Assist quota endpoint first — same source the CLI
        // uses for its `/model` view, so what we render matches `gemini` exactly.
        var liveWindows: [QuotaWindow]? = nil
        if let token = await GeminiOAuthTokenManager.shared.currentAccessToken(geminiRootURL: accessURL) {
            liveWindows = await GeminiLiveQuotaFetcher.fetchWindows(accessToken: token)
        }

        // Always run the local reader so we still surface events, stats,
        // signals, and balances even when the live API is reachable. The local
        // reader's CLI-spawn path is no-op'd in sandbox; we keep its other work.
        let reader = GeminiLocalStateReader(fileManager: fileManager, cliQuota: nil)
        print("[GeminiProvider] Reading local Gemini CLI data from: \(accessURL.path)")

        let local: QuotaSnapshot
        do {
            local = try await runOffMain {
                try reader.loadSnapshot(rootURL: accessURL, credentials: credentials)
            }
        } catch {
            // If the local read fails AND we have live windows, return a
            // synthetic snapshot using only the live data. Otherwise rethrow.
            if let liveWindows, !liveWindows.isEmpty {
                return QuotaSnapshot(
                    providerID: .gemini,
                    displayName: "Gemini CLI",
                    planName: "Google Account",
                    windows: liveWindows,
                    fetchState: .success,
                    fetchedAt: Date()
                )
            }
            throw error
        }

        // Merge: live windows replace the heuristic ones when available;
        // everything else (events, stats, balances, signals) comes from local.
        if let liveWindows, !liveWindows.isEmpty {
            return QuotaSnapshot(
                id: local.id,
                providerID: local.providerID,
                displayName: local.displayName,
                planName: local.planName,
                windows: liveWindows,
                stats: local.stats,
                balances: local.balances,
                signals: local.signals,
                events: local.events,
                fetchState: .success,
                fetchedAt: Date()
            )
        }

        // No live data → fall back to the existing local-only snapshot.
        return local
    }

    /// Hops to a background queue without using `withCheckedThrowingContinuation`
    /// at the call site, so the security-scoped access bracketing stays clean.
    private func runOffMain<T>(_ work: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    continuation.resume(returning: try work())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func fetchCLIQuotaIfNecessary() async -> GeminiCLIQuota? {
        let now = Date()

        var shouldFetch = true
        if let last = Self.lastCLIFetch, now.timeIntervalSince(last) < Self.cliFetchInterval {
            shouldFetch = false
        }

        // Even if within interval, if we have a resetDate that has passed, we should re-fetch
        if let cached = Self.cachedCLIQuota, let resetDate = cached.resetDate, resetDate < now {
            print("[GeminiProvider] Cached resetDate \(resetDate) has passed, forcing re-fetch.")
            shouldFetch = true
        }

        if !shouldFetch, let last = Self.lastCLIFetch {
            print("[GeminiProvider] Using cached CLI quota from \(last)")
            return Self.cachedCLIQuota
        }

        print("[GeminiProvider] Invoking Gemini CLI for real-time quota...")
        let quota = await GeminiCLIExecutor.fetchRealTimeQuota()

        if quota != nil {
            Self.lastCLIFetch = now
            Self.cachedCLIQuota = quota
        }

        return quota
    }

    private func resolvedGeminiRootURL(credentials: ProviderCredential?) -> URL {
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
        return URL(fileURLWithPath: realHomePath).appendingPathComponent(".gemini")
    }

    private func geminiBookmarkData(from credentials: ProviderCredential?) -> Data? {
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

struct GeminiLocalStateReader {
    private let fileManager: FileManager
    private let decoder: JSONDecoder
    private let cliQuota: GeminiCLIQuota?

    private static let cacheKey = "gemini_snapshot_cache"
    private static let cacheDateKey = "gemini_snapshot_cache_date"
    private let cacheValidityInterval: TimeInterval = 5 * 60 // 5 minutes

    init(fileManager: FileManager, cliQuota: GeminiCLIQuota? = nil) {
        self.fileManager = fileManager
        self.decoder = JSONDecoder()
        // Gemini CLI stamps every session line with JavaScript's
        // `toISOString()`, which always carries milliseconds. `.iso8601`
        // rejected those before Foundation's ISO 8601 parsing became lenient
        // in Swift 6.2, skipping every message line; parse them explicitly
        // so the reader never depends on that behaviour.
        self.decoder.dateDecodingStrategy = ISO8601Timestamp.decodingStrategy
        self.cliQuota = cliQuota
    }

    func loadSnapshot(rootURL: URL, credentials: ProviderCredential?) throws -> QuotaSnapshot {
        let latestFileDate = getLatestFileModificationDate(rootURL: rootURL)

        if let cached = loadCachedSnapshot(latestFileDate: latestFileDate) {
            print("[GeminiProvider] Using cached snapshot (latest file: \(latestFileDate))")
            return cached
        }

        let snapshot = try loadSnapshotUncached(rootURL: rootURL, credentials: credentials, latestFileDate: latestFileDate)
        cacheSnapshot(snapshot, latestFileDate: latestFileDate)
        return snapshot
    }

    /// Modern Gemini CLI writes session files as `.jsonl` (line-delimited
    /// JSON: one session-metadata line followed by per-message lines).
    /// Older versions wrote a single `.json` object. We accept both so
    /// the cache invalidates correctly when new sessions land — without
    /// this, only `.json` mtimes were tracked and the cache stuck on the
    /// last `.json` file's date indefinitely once the CLI switched
    /// formats.
    private static func isGeminiSessionFile(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return ext == "json" || ext == "jsonl"
    }

    private func getLatestFileModificationDate(rootURL: URL) -> Date {
        let tmpRoot = rootURL.appendingPathComponent("tmp")
        guard fileManager.fileExists(atPath: tmpRoot.path) else {
            return .distantPast
        }

        var latestDate = Date.distantPast
        let projectDirs = (try? fileManager.contentsOfDirectory(at: tmpRoot, includingPropertiesForKeys: nil)) ?? []

        for projectDir in projectDirs {
            let chatsDir = projectDir.appendingPathComponent("chats")
            guard fileManager.fileExists(atPath: chatsDir.path) else { continue }

            let sessionFiles = (try? fileManager.contentsOfDirectory(at: chatsDir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            for fileURL in sessionFiles where Self.isGeminiSessionFile(fileURL) {
                if let fileDate = try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate {
                    latestDate = max(latestDate, fileDate)
                }
            }
        }

        return latestDate
    }

    /// Parses a single Gemini session file, transparently handling both
    /// the legacy `.json` (one-object-per-file) and modern `.jsonl`
    /// (one-line-per-record) formats. Returns nil if the file is neither
    /// parseable nor recoverable.
    func parseGeminiSessionFile(at fileURL: URL) -> GeminiSessionFile? {
        guard let data = try? Data(contentsOf: fileURL) else {
            return nil
        }

        // Try the legacy single-object format first; cheapest case.
        if let session = try? decoder.decode(GeminiSessionFile.self, from: data) {
            return session
        }

        // Fall back to line-delimited JSONL. First line is session
        // metadata `{sessionId, projectHash, startTime, lastUpdated,
        // kind}`; subsequent lines are individual messages whose schema
        // matches `GeminiMessage`. Lines that fail to decode as either
        // are skipped — the format includes occasional non-message
        // records (tool calls, etc.) that we don't need to count.
        guard let text = String(data: data, encoding: .utf8) else {
            return nil
        }

        var sessionId: String?
        var messages: [GeminiMessage] = []

        for line in text.split(whereSeparator: \.isNewline) {
            guard let lineData = line.data(using: .utf8) else { continue }

            if let message = try? decoder.decode(GeminiMessage.self, from: lineData) {
                messages.append(message)
                continue
            }

            if sessionId == nil,
               let metadata = try? decoder.decode(GeminiSessionMetadata.self, from: lineData) {
                sessionId = metadata.sessionId
            }
        }

        // Treat the file as a session only if we got at least one
        // message — otherwise downstream counters would be misled by a
        // "session with zero messages" that we couldn't actually parse.
        guard !messages.isEmpty else { return nil }
        return GeminiSessionFile(sessionId: sessionId ?? fileURL.lastPathComponent, messages: messages)
    }

    private func loadCachedSnapshot(latestFileDate: Date) -> QuotaSnapshot? {
        let defaults = UserDefaults.standard

        guard let cachedDate = defaults.object(forKey: Self.cacheDateKey) as? Date else {
            return nil
        }

        guard cachedDate == latestFileDate else {
            return nil
        }

        guard let data = defaults.data(forKey: Self.cacheKey) else {
            return nil
        }

        guard let cached = try? decoder.decode(QuotaSnapshot.self, from: data) else {
            return nil
        }

        return cached
    }

    private func cacheSnapshot(_ snapshot: QuotaSnapshot, latestFileDate: Date) {
        let defaults = UserDefaults.standard
        guard let data = try? encoder().encode(snapshot) else {
            return
        }

        defaults.set(data, forKey: Self.cacheKey)
        defaults.set(latestFileDate, forKey: Self.cacheDateKey)
    }

    private func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    func loadSnapshotUncached(rootURL: URL, credentials: ProviderCredential?, latestFileDate: Date) throws -> QuotaSnapshot {
        guard fileManager.fileExists(atPath: rootURL.path) else {
            throw ProviderFetchError.notConfigured
        }

        let metadata = loadMetadata(rootURL: rootURL)
        let limitPreset = resolvedGeminiLimitPreset(from: credentials)
        let limitProfile = resolvedGeminiLimitProfile(
            for: limitPreset,
            authType: metadata.authType,
            activeEmail: metadata.activeEmail
        )

        let now = Date()
        let dayStart = now.addingTimeInterval(-24 * 60 * 60)
        let weekStart = now.addingTimeInterval(-7 * 24 * 60 * 60)
        let monthStart = now.addingTimeInterval(-30 * 24 * 60 * 60)

        var totalInput: Double = 0
        var totalOutput: Double = 0
        var totalThoughts: Double = 0
        var totalCached: Double = 0

        var dayInput: Double = 0
        var dayOutput: Double = 0
        var weekInput: Double = 0
        var weekOutput: Double = 0
        var monthInput: Double = 0
        var monthOutput: Double = 0

        var latestSessionDate = Date.distantPast

        var conversationCount = 0
        var latestActivity = Date.distantPast

        // Request counting for quota meters
        var dailyRequests: Double = 0
        var weeklyRequests: Double = 0
        var totalRequests: Double = 0
        var oldestDailyRequestAt: Date?
        var oldestWeeklyRequestAt: Date?

        // Per-model quota tracking from error messages
        var modelQuotas: [String: ModelQuotaInfo] = [:]
        var events: [UsageEvent] = []

        // Gemini CLI stores active session history in tmp/<project>/chats/
        let tmpRoot = rootURL.appendingPathComponent("tmp")

        if fileManager.fileExists(atPath: tmpRoot.path) {
            let projectDirs = (try? fileManager.contentsOfDirectory(at: tmpRoot, includingPropertiesForKeys: nil)) ?? []

            for projectDir in projectDirs {
                let chatsDir = projectDir.appendingPathComponent("chats")
                guard fileManager.fileExists(atPath: chatsDir.path) else { continue }

                let sessionFiles = (try? fileManager.contentsOfDirectory(at: chatsDir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []

                for fileURL in sessionFiles where Self.isGeminiSessionFile(fileURL) {
                    guard let session = parseGeminiSessionFile(at: fileURL) else {
                        continue
                    }

                    conversationCount += 1
                    let fileDate = (try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast

                    if fileDate > latestSessionDate {
                        latestSessionDate = fileDate
                    }

                    // Parse per-model quota errors from messages
                    // First, build a timeline of models used in this session
                    var modelTimeline: [(timestamp: Date, model: String)] = []
                    for message in session.messages {
                        if let modelName = message.model, let timestamp = message.timestamp {
                            modelTimeline.append((timestamp: timestamp, model: modelName))
                        }
                    }

                    for message in session.messages {
                        guard let timestamp = message.timestamp else {
                            continue
                        }

                        if timestamp > latestActivity {
                            latestActivity = timestamp
                        }

                        // Each message in a Gemini session file includes tokens for that specific turn.
                        // We must accumulate tokens from all turns to get the total API usage.
                        if let tokens = message.tokens {
                            totalInput += tokens.input
                            totalOutput += tokens.output
                            totalThoughts += tokens.thoughts ?? 0
                            totalCached += tokens.cached ?? 0

                            events.append(UsageEvent(
                                timestamp: timestamp,
                                tokens: tokens.input + tokens.output,
                                model: message.model,
                                type: .message
                            ))

                            if timestamp >= dayStart {
                                dayInput += tokens.input
                                dayOutput += tokens.output
                            }
                            if timestamp >= weekStart {
                                weekInput += tokens.input
                                weekOutput += tokens.output
                            }
                            if timestamp >= monthStart {
                                monthInput += tokens.input
                                monthOutput += tokens.output
                            }
                        }

                        if message.type == "gemini", let modelName = message.model {
                            let displayModel = formatModelName(modelName)
                            recordRequest(
                                at: timestamp,
                                modelName: displayModel,
                                dayStart: dayStart,
                                weekStart: weekStart,
                                modelQuotas: &modelQuotas,
                                totalRequests: &totalRequests,
                                dailyRequests: &dailyRequests,
                                weeklyRequests: &weeklyRequests,
                                oldestDailyRequestAt: &oldestDailyRequestAt,
                                oldestWeeklyRequestAt: &oldestWeeklyRequestAt
                            )
                        }

                        // Check for quota errors
                        guard let content = message.content else { continue }
                        if message.type == "error", let resetInfo = parseQuotaReset(from: content, referenceDate: timestamp) {
                                let resolvedModel = message.model
                                    ?? findMostRecentModel(before: timestamp, in: modelTimeline)
                                    ?? metadata.defaultModel
                                    ?? "unknown"
                                let displayModel = formatModelName(resolvedModel)
                                recordRequest(
                                    at: timestamp,
                                    modelName: displayModel,
                                    dayStart: dayStart,
                                    weekStart: weekStart,
                                    modelQuotas: &modelQuotas,
                                    totalRequests: &totalRequests,
                                    dailyRequests: &dailyRequests,
                                    weeklyRequests: &weeklyRequests,
                                    oldestDailyRequestAt: &oldestDailyRequestAt,
                                    oldestWeeklyRequestAt: &oldestWeeklyRequestAt
                                )
                                let existingInfo = modelQuotas[displayModel] ?? ModelQuotaInfo(modelName: displayModel)
                                var updatedInfo = existingInfo

                                if let existingReset = updatedInfo.resetDate {
                                    updatedInfo.resetDate = max(existingReset, resetInfo.resetDate)
                                } else {
                                    updatedInfo.resetDate = resetInfo.resetDate
                                }
                                updatedInfo.isExhausted = resetInfo.isExhausted
                                updatedInfo.errorCount += 1
                                if updatedInfo.firstErrorDate == nil {
                                    updatedInfo.firstErrorDate = timestamp
                                }
                                modelQuotas[displayModel] = updatedInfo
                        }
                    }
                }
            }
        }

        print("[GeminiProvider] Final counts: conversations=\(conversationCount), totalInput=\(totalInput), totalRequests=\(totalRequests), modelQuotas=\(modelQuotas.count)")

        guard conversationCount > 0 || totalInput > 0 || !modelQuotas.isEmpty else {
            throw ProviderFetchError.notConfigured
        }

        // Apply CLI-sourced authoritative quota data if available
        let dailyLimit = cliQuota?.dailyLimit ?? limitProfile.dailyRequestLimit
        let remainingRequests = cliQuota?.remainingRequests
        let authoritativeResetDate = cliQuota?.resetDate

        var windows: [QuotaWindow] = []

        let targetModels = ["Flash", "Flash Lite", "Pro"]
        var processedModels = Set<String>()

        for targetModel in targetModels {
            let info = modelQuotas[targetModel] ?? ModelQuotaInfo(modelName: targetModel)
            processedModels.insert(targetModel)

            let perModelLimit = limitProfile.modelRequestLimit(for: targetModel)
            let modelResetDate = info.isExhausted
                ? (info.resetDate ?? rollingResetDate(from: info.oldestDailyRequestAt ?? Date(), duration: 24 * 60 * 60))
                : rollingResetDate(from: info.oldestDailyRequestAt ?? Date(), duration: 24 * 60 * 60)

            windows.append(QuotaWindow(
                label: targetModel,
                windowKind: .custom,
                used: info.dailyRequests,
                total: perModelLimit,
                resetDate: modelResetDate,
                unit: "req",
                subtitle: nil
            ))
        }

        // Add any other models we saw
        let otherModels = modelQuotas.values.filter {
            !processedModels.contains($0.modelName)
            && ($0.dailyRequests > 0 || $0.weeklyRequests > 0 || $0.isExhausted)
        }.sorted {
            if $0.isExhausted != $1.isExhausted { return $0.isExhausted && !$1.isExhausted }
            return $0.modelName < $1.modelName
        }

        for info in otherModels {
            let perModelLimit = limitProfile.modelRequestLimit(for: info.modelName)
            let modelResetDate = info.isExhausted
                ? (info.resetDate ?? rollingResetDate(from: info.oldestDailyRequestAt ?? Date(), duration: 24 * 60 * 60))
                : rollingResetDate(from: info.oldestDailyRequestAt ?? Date(), duration: 24 * 60 * 60)

            windows.append(QuotaWindow(
                label: info.modelName,
                windowKind: .custom,
                used: info.dailyRequests,
                total: perModelLimit,
                resetDate: modelResetDate,
                unit: "req",
                subtitle: nil
            ))
        }

        // Used vs Remaining adjustment: If we have authoritative "remaining",
        // we can calculate a more accurate "used" if our local counting is behind.
        let correctedDailyUsed: Double
        if let remaining = remainingRequests, dailyLimit > 0 {
            correctedDailyUsed = max(dailyRequests, dailyLimit - remaining)
        } else {
            correctedDailyUsed = dailyRequests
        }

        // Always show generic daily/weekly request windows
        windows.append(contentsOf: [
            QuotaWindow(
                label: "Daily Requests",
                windowKind: .daily,
                used: correctedDailyUsed,
                total: dailyLimit,
                resetDate: authoritativeResetDate ?? rollingResetDate(from: oldestDailyRequestAt, duration: 24 * 60 * 60),
                unit: "req",
                subtitle: cliQuota != nil ? "Auth. CLI Data" : nil
            ),
            QuotaWindow(
                label: "Weekly Requests",
                windowKind: .weekly,
                used: weeklyRequests,
                total: limitProfile.weeklyRequestLimit,
                resetDate: rollingResetDate(from: oldestWeeklyRequestAt, duration: 7 * 24 * 60 * 60),
                unit: "req",
                subtitle: nil
            )
        ])

        var stats = [
            QuotaStat(label: "24H Tokens", value: dayInput + dayOutput, unit: "tok"),
            QuotaStat(label: "7D Tokens", value: weekInput + weekOutput, unit: "tok"),
            QuotaStat(label: "30D Tokens", value: monthInput + monthOutput, unit: "tok"),
            QuotaStat(label: "Total Input", value: totalInput, unit: "tok"),
            QuotaStat(label: "Total Output", value: totalOutput, unit: "tok")
        ]

        if totalThoughts > 0 {
            stats.append(QuotaStat(label: "Thinking Tokens", value: totalThoughts, unit: "tok"))
        }

        if totalCached > 0 {
            stats.append(QuotaStat(label: "Cached Tokens", value: totalCached, unit: "tok"))
        }

        stats.append(QuotaStat(label: "Sessions", value: Double(conversationCount), unit: "chats"))
        stats.append(QuotaStat(label: "24H Requests", value: correctedDailyUsed, unit: "req"))
        stats.append(QuotaStat(label: "Total Requests", value: totalRequests, unit: "req"))

        // Add per-model stats if available
        if !modelQuotas.isEmpty {
            for (modelName, quotaInfo) in modelQuotas {
                let displayName = formatModelName(modelName)
                stats.append(QuotaStat(
                    label: "\(displayName) Status",
                    value: Double(quotaInfo.errorCount),
                    unit: quotaInfo.isExhausted ? "errors" : "ok"
                ))
            }
        }

        var signals: [QuotaSignal] = []
        if let email = metadata.activeEmail {
            signals.append(
                QuotaSignal(
                    kind: .unexpectedRecovery,
                    title: "Active Google Account",
                    // Not the address. `QuotaSignal` is not a local-only type:
                    // it rides inside `QuotaSnapshot.signals` into the App Group
                    // cache the widget reads and into the CloudKit payload, so an
                    // email interpolated here left the machine. What actually
                    // changes the user's expectations is which ceiling set
                    // applies, and the workspace test already derives that from
                    // the address without repeating it.
                    message: isLikelyWorkspaceEmail(email)
                        ? "Using a Gemini CLI session signed in to a Google Workspace account, so Workspace ceilings apply."
                        : "Using a Gemini CLI session signed in to a personal Google account, so Google Account ceilings apply.",
                    severity: .info,
                    detectedAt: now
                )
            )
        }

        // Add signals for exhausted models
        for (modelName, quotaInfo) in modelQuotas where quotaInfo.isExhausted {
            let displayName = formatModelName(modelName)
            signals.append(
                QuotaSignal(
                    kind: .unexpectedRecovery,
                    title: "\(displayName) Quota Exhausted",
                    message: "\(displayName) model quota has been reached. Usage will be limited until reset.",
                    severity: .warning,
                    windowLabel: displayName,
                    detectedAt: quotaInfo.firstErrorDate ?? now
                )
            )
        }

        // Determine plan name based on auth type and email
        let planName: String
        switch metadata.authType {
        case "oauth-personal", "oauth":
            planName = isLikelyWorkspaceEmail(metadata.activeEmail) ? "Google Workspace" : "Google Account"
        case "api-key":
            planName = "API Key (Free)"
        case "vertex-express":
            planName = "Vertex Express"
        default:
            planName = metadata.authType != nil ? "Personal" : "Local"
        }

        // AGBench's unified `usage.json` records every run including
        // Gemini CLI invocations. Merging them in lets the heatmap
        // reflect TaskWraith-driven activity even where the local CLI
        // session file might be incomplete.
        let agbenchEvents = AGBenchUsageReader.loadEvents(forProviderKey: "gemini")
        let combinedEvents = events + agbenchEvents

        // Collapse per-message events to 2-hour heatmap buckets — same
        // shape Claude and Kimi use. The previous `prefix(1000)` cap let
        // dense recent days monopolize the quota and silently discarded
        // older April activity from the heatmap, even though those events
        // were parsed from disk. Bucketing caps at 12 buckets/day × 30 days
        // = 360 events max, comfortably representing the full window
        // without truncation.
        let bucketedEvents = bucketGeminiHeatmapEvents(from: combinedEvents, now: now)

        return QuotaSnapshot(
            providerID: .gemini,
            displayName: "Gemini CLI",
            planName: planName,
            windows: windows,
            stats: stats,
            balances: [],
            signals: signals,
            events: bucketedEvents,
            fetchState: .success,
            fetchedAt: latestActivity > .distantPast ? latestActivity : now
        )
    }

    /// Aggregates per-message events into 2-hour heatmap buckets. One
    /// `.bucket` event per (date, 2-hour) window where any activity was
    /// observed, with summed tokens. Bounded at 12 × 30 = 360 events for
    /// the heatmap window — naturally fits within downstream caps. The
    /// model field is set to the most-represented model in the bucket so
    /// `guessProviderFromModel` resolves correctly when the heatmap
    /// renders. Same pattern as `ClaudeHeatmapEventBucketer`.
    private func bucketGeminiHeatmapEvents(from events: [UsageEvent], now: Date) -> [UsageEvent] {
        let calendar = Calendar.current
        let horizon = now.addingTimeInterval(-30 * 24 * 60 * 60)

        struct BucketAcc {
            var tokens: Double = 0
            // Track per-model contributions so the dominant model wins
            // when the heatmap picks a representative event for the cell.
            var modelTokens: [String: Double] = [:]
        }

        var buckets: [Date: BucketAcc] = [:]

        for event in events where event.timestamp >= horizon {
            let bucketStart = geminiBucketStart(for: event.timestamp, calendar: calendar)
            var acc = buckets[bucketStart] ?? BucketAcc()
            let tokens = event.tokens ?? 0
            acc.tokens += tokens
            if let model = event.model, !model.isEmpty {
                acc.modelTokens[model, default: 0] += max(tokens, 1)
            }
            buckets[bucketStart] = acc
        }

        return buckets
            .map { bucketStart, acc -> UsageEvent in
                let dominantModel = acc.modelTokens.max(by: { $0.value < $1.value })?.key ?? "Gemini"
                return UsageEvent(
                    timestamp: bucketStart,
                    tokens: acc.tokens > 0 ? acc.tokens : nil,
                    model: dominantModel,
                    type: .bucket
                )
            }
            .sorted { $0.timestamp > $1.timestamp }
    }

    private func geminiBucketStart(for date: Date, calendar: Calendar) -> Date {
        let dayStart = calendar.startOfDay(for: date)
        let hour = calendar.component(.hour, from: date)
        let bucketIndex = max(0, min(11, hour / 2))
        return calendar.date(byAdding: .hour, value: bucketIndex * 2, to: dayStart)
            ?? dayStart.addingTimeInterval(Double(bucketIndex * 2 * 3600))
    }

    private func loadMetadata(rootURL: URL) -> GeminiMetadata {
        var metadata = GeminiMetadata()

        let accountsURL = rootURL.appendingPathComponent("google_accounts.json")
        if let data = try? Data(contentsOf: accountsURL),
           let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            metadata.activeEmail = json["active"] as? String
        }

        let settingsURL = rootURL.appendingPathComponent("settings.json")
        if let data = try? Data(contentsOf: settingsURL),
           let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            // Read auth type
            if let security = json["security"] as? [String: Any],
               let auth = security["auth"] as? [String: Any] {
                metadata.authType = auth["selectedType"] as? String
            }
            // Read default model
            if let model = json["model"] as? [String: Any],
               let modelName = model["name"] as? String {
                metadata.defaultModel = modelName
            }
        }

        return metadata
    }

    private func findMostRecentModel(before timestamp: Date, in timeline: [(timestamp: Date, model: String)]) -> String? {
        timeline
            .filter { $0.timestamp <= timestamp }
            .max { $0.timestamp < $1.timestamp }?
            .model
    }

    private func recordRequest(
        at timestamp: Date,
        modelName: String,
        dayStart: Date,
        weekStart: Date,
        modelQuotas: inout [String: ModelQuotaInfo],
        totalRequests: inout Double,
        dailyRequests: inout Double,
        weeklyRequests: inout Double,
        oldestDailyRequestAt: inout Date?,
        oldestWeeklyRequestAt: inout Date?
    ) {
        totalRequests += 1

        guard timestamp >= weekStart || modelQuotas[modelName] != nil else {
            return
        }

        var info = modelQuotas[modelName] ?? ModelQuotaInfo(modelName: modelName)
        if timestamp >= dayStart {
            dailyRequests += 1
            info.dailyRequests += 1
            if let existing = info.oldestDailyRequestAt {
                info.oldestDailyRequestAt = min(existing, timestamp)
            } else {
                info.oldestDailyRequestAt = timestamp
            }
            if let existing = oldestDailyRequestAt {
                oldestDailyRequestAt = min(existing, timestamp)
            } else {
                oldestDailyRequestAt = timestamp
            }
        }
        if timestamp >= weekStart {
            weeklyRequests += 1
            info.weeklyRequests += 1
            if let existing = info.oldestWeeklyRequestAt {
                info.oldestWeeklyRequestAt = min(existing, timestamp)
            } else {
                info.oldestWeeklyRequestAt = timestamp
            }
            if let existing = oldestWeeklyRequestAt {
                oldestWeeklyRequestAt = min(existing, timestamp)
            } else {
                oldestWeeklyRequestAt = timestamp
            }
        }
        modelQuotas[modelName] = info
    }

    private func rollingResetDate(from oldestRequestAt: Date?, duration: TimeInterval) -> Date? {
        guard let oldestRequestAt else { return nil }
        return oldestRequestAt.addingTimeInterval(duration)
    }

    private func resolvedGeminiLimitPreset(from credentials: ProviderCredential?) -> GeminiLimitPreset {
        guard let rawValue = credentials?.extraFields?[GeminiLimitPreset.storageKey],
              let preset = GeminiLimitPreset(rawValue: rawValue) else {
            return .automatic
        }
        return preset
    }

    private func resolvedGeminiLimitProfile(
        for preset: GeminiLimitPreset,
        authType: String?,
        activeEmail: String?
    ) -> GeminiLimitProfile {
        switch preset {
        case .automatic:
            switch authType {
            case "vertex-express":
                return .highThroughput
            case "api-key":
                return .conservative
            case "oauth-personal", "oauth":
                return isLikelyWorkspaceEmail(activeEmail) ? .highThroughput : .standard
            default:
                return .standard
            }
        case .conservative:
            return .conservative
        case .standard:
            return .standard
        case .highThroughput:
            return .highThroughput
        }
    }

    private func isLikelyWorkspaceEmail(_ email: String?) -> Bool {
        guard let email else { return false }
        let emailLower = email.lowercased()

        // Consumer email domains (definitely not workspace)
        let consumerDomains = [
            "gmail.com", "googlemail.com",
            "hotmail.com", "hotmail.co.uk", "live.com", "outlook.com", "msn.com",
            "yahoo.com", "yahoo.co.uk", "yahoo.co.in",
            "aol.com", "icloud.com", "me.com", "mac.com",
            "protonmail.com", "proton.me",
            "mail.com", "gmx.com", "gmx.net"
        ]

        // Check if it's a consumer domain
        for domain in consumerDomains {
            if emailLower.hasSuffix("@\(domain)") {
                return false
            }
        }

        // Positive detection for enterprise/education domains
        // .edu, .org, .gov, .mil are almost always institutional
        let institutionalTLDs = ["edu", "org", "gov", "mil"]
        for tld in institutionalTLDs {
            if emailLower.hasSuffix(".\(tld)") {
                return true
            }
        }

        // Company domains (non-consumer, non-institutional) are likely workspace
        // This is a reasonable default heuristic
        return true
    }
}

// MARK: - CLI Quota Fetching

struct GeminiCLIQuota {
    let dailyLimit: Double
    let remainingRequests: Double
    let resetDate: Date?
}

private enum GeminiCLIExecutor {
    /// Runs `echo "/stats model" | gemini` and parses the output
    static func fetchRealTimeQuota() async -> GeminiCLIQuota? {
        #if os(macOS)
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        task.arguments = ["bash", "-c", "echo \"/stats model\" | gemini --raw-output --accept-raw-output-risk"]

        let outputPipe = Pipe()
        task.standardOutput = outputPipe
        task.standardError = Pipe() // Silence errors

        do {
            try task.run()
            task.waitUntilExit()

            let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
            guard let output = String(data: data, encoding: .utf8) else { return nil }

            return parseCLIStats(output)
        } catch {
            print("[GeminiProvider] CLI execution failed: \(error)")
            return nil
        }
        #else
        return nil
        #endif
    }

    private static func parseCLIStats(_ output: String) -> GeminiCLIQuota? {
        var dailyLimit: Double?
        var remaining: Double?
        var resetDate: Date?

        let lines = output.components(separatedBy: .newlines)
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.contains("Daily Limit:"),
               let value = extractDouble(from: trimmed) {
                dailyLimit = value
            } else if trimmed.contains("Remaining:"),
                      let value = extractDouble(from: trimmed) {
                remaining = value
            } else if trimmed.contains("Reset after:") {
                resetDate = parseResetDate(from: trimmed)
            }
        }

        guard let dailyLimit, let remaining else { return nil }
        return GeminiCLIQuota(dailyLimit: dailyLimit, remainingRequests: remaining, resetDate: resetDate)
    }

    private static func extractDouble(from text: String) -> Double? {
        let pattern = "([\\d,]+)"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []),
              let match = regex.firstMatch(in: text, options: [], range: NSRange(text.startIndex..., in: text)) else {
            return nil
        }
        let valueStr = (text as NSString).substring(with: match.range(at: 1)).replacingOccurrences(of: ",", with: "")
        return Double(valueStr)
    }

    private static func parseResetDate(from text: String) -> Date? {
        // reuse existing parseQuotaReset logic or similar
        let pattern = "(\\d+)h\\s*(\\d+)m\\s*(\\d+)s"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []),
              let match = regex.firstMatch(in: text, options: [], range: NSRange(text.startIndex..., in: text)) else {
            return nil
        }

        let hours = Int((text as NSString).substring(with: match.range(at: 1))) ?? 0
        let minutes = Int((text as NSString).substring(with: match.range(at: 2))) ?? 0
        let seconds = Int((text as NSString).substring(with: match.range(at: 3))) ?? 0

        let totalSeconds = hours * 3600 + minutes * 60 + seconds
        return Date().addingTimeInterval(TimeInterval(totalSeconds))
    }
}

private struct GeminiMetadata {
    var activeEmail: String?
    var authType: String?
    var defaultModel: String?
}

struct GeminiSessionFile: Decodable {
    let sessionId: String
    let messages: [GeminiMessage]
}

/// First line of a `.jsonl` session file. The CLI writes a small metadata
/// record before any messages — we only need the sessionId to satisfy
/// `GeminiSessionFile`'s shape; the rest is for the Gemini CLI's own use.
private struct GeminiSessionMetadata: Decodable {
    let sessionId: String
}

struct GeminiMessage: Decodable {
    let id: String?
    let timestamp: Date?
    let type: String
    let tokens: GeminiTokens?
    let model: String?
    let content: String?

    // Custom init to handle polymorphic content (String or array of text objects)
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        id = try container.decodeIfPresent(String.self, forKey: .id)
        timestamp = try container.decodeIfPresent(Date.self, forKey: .timestamp)
        type = try container.decode(String.self, forKey: .type)
        tokens = try container.decodeIfPresent(GeminiTokens.self, forKey: .tokens)
        model = try container.decodeIfPresent(String.self, forKey: .model)

        // Content can be String or Array of text objects
        if let stringContent = try? container.decode(String.self, forKey: .content) {
            content = stringContent
        } else if let arrayContent = try? container.decode([GeminiContentItem].self, forKey: .content) {
            content = arrayContent.compactMap { $0.text }.joined(separator: "\n")
        } else {
            content = nil
        }
    }

    private enum CodingKeys: String, CodingKey {
        case id, timestamp, type, tokens, model, content
    }
}

private struct GeminiContentItem: Decodable {
    let text: String?
}

struct GeminiTokens: Decodable {
    let input: Double
    let output: Double
    let cached: Double?
    let thoughts: Double?
    let total: Double
}

// MARK: - Per-Model Quota Tracking

private struct ModelQuotaInfo {
    var modelName: String = ""
    var resetDate: Date?
    var isExhausted: Bool = false
    var errorCount: Int = 0
    var firstErrorDate: Date?
    var dailyRequests: Double = 0
    var weeklyRequests: Double = 0
    var oldestDailyRequestAt: Date?
    var oldestWeeklyRequestAt: Date?
}

private struct QuotaResetInfo {
    let resetDate: Date
    let isExhausted: Bool
}

/// Parses quota error messages to extract reset time
/// Example: "Your quota will reset after 20h36m33s" -> Date
private func parseQuotaReset(from content: String, referenceDate: Date) -> QuotaResetInfo? {
    let patterns = [
        "Your quota will reset after",
        "quota will reset after",
        "exhausted your capacity"
    ]

    // Check if this is a quota error
    let isQuotaError = patterns.contains { content.contains($0) }
    guard isQuotaError || content.contains("TerminalQuotaError") else {
        return nil
    }

    // Parse time duration from message using regex (e.g., "20h36m33s" or "20h 36m 33s")
    let pattern = "(\\d+)h\\s*(\\d+)m\\s*(\\d+)s"
    guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
        return nil
    }

    let range = NSRange(content.startIndex..., in: content)
    if let match = regex.firstMatch(in: content, options: [], range: range) {
        let hourRange = match.range(at: 1)
        let minuteRange = match.range(at: 2)
        let secondRange = match.range(at: 3)

        guard let hours = Int(content[Range(hourRange, in: content)!]),
              let minutes = Int(content[Range(minuteRange, in: content)!]),
              let seconds = Int(content[Range(secondRange, in: content)!]) else {
            return nil
        }

        let totalSeconds = hours * 3600 + minutes * 60 + seconds
        let resetDate = referenceDate.addingTimeInterval(TimeInterval(totalSeconds))

        return QuotaResetInfo(resetDate: resetDate, isExhausted: true)
    }

    return nil
}

/// Formats a model name for display (e.g., "gemini-3.1-flash-lite-preview" -> "Flash Lite")
private func formatModelName(_ modelName: String) -> String {
    let lowercased = modelName.lowercased()

    if lowercased.contains("flash-lite") {
        return "Flash Lite"
    } else if lowercased.contains("flash") {
        return "Flash"
    } else if lowercased.contains("pro") {
        return "Pro"
    } else if lowercased.contains("ultra") {
        return "Ultra"
    } else {
        // Extract version number if present
        let components = modelName.split(separator: "-")
        if let lastComponent = components.last {
            return String(lastComponent).capitalized
        }
        return modelName
    }
}

struct GeminiLimitProfile {
    let dailyRequestLimit: Double
    let weeklyRequestLimit: Double
    let flashRequestLimit: Double
    let flashLiteRequestLimit: Double
    let proRequestLimit: Double

    func modelRequestLimit(for modelName: String) -> Double {
        switch formatModelName(modelName) {
        case "Flash Lite":
            return flashLiteRequestLimit
        case "Pro", "Ultra":
            return proRequestLimit
        default:
            return flashRequestLimit
        }
    }

    static let conservative = GeminiLimitProfile(
        dailyRequestLimit: 1000,
        weeklyRequestLimit: 7000,
        flashRequestLimit: 1000,
        flashLiteRequestLimit: 1000,
        proRequestLimit: 50
    )

    static let standard = GeminiLimitProfile(
        dailyRequestLimit: 1500,
        weeklyRequestLimit: 10500,
        flashRequestLimit: 1500,
        flashLiteRequestLimit: 1500,
        proRequestLimit: 50
    )

    static let highThroughput = GeminiLimitProfile(
        dailyRequestLimit: 3000,
        weeklyRequestLimit: 21000,
        flashRequestLimit: 3000,
        flashLiteRequestLimit: 3000,
        proRequestLimit: 300
    )
}

enum GeminiLimitPreset: String, CaseIterable, Identifiable {
    case automatic
    case standard
    case highThroughput
    case conservative

    static let storageKey = "geminiLimitPreset"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .automatic:
            return "Automatic"
        case .standard:
            return "Google Account"
        case .highThroughput:
            return "Google Workspace / Vertex"
        case .conservative:
            return "API Key / Free Tier"
        }
    }

    var detail: String {
        switch self {
        case .automatic:
            return "Uses detected Gemini auth and email domain. Personal Google accounts default to Google Account ceilings, workspace domains default to Google Workspace / Vertex ceilings, and API key auth defaults to API Key / Free Tier ceilings."
        case .standard:
            return "Google Account ceilings: Flash + Flash Lite 1.5K/day, Pro 50/day, Weekly 10.5K."
        case .highThroughput:
            return "Google Workspace / Vertex ceilings: Flash + Flash Lite 3.0K/day, Pro 300/day, Weekly 21.0K."
        case .conservative:
            return "API Key / Free Tier ceilings: Flash + Flash Lite 1.0K/day, Pro 50/day, Weekly 7.0K."
        }
    }
}

// MARK: - Gemini Code Assist Live Quota
//
// Replaces the prior heuristic (counting local history files) with the same
// authoritative source that `gemini /model` shows in the terminal: Google's
// internal Code Assist endpoint, called by the CLI as `retrieveUserQuota`.
// The response includes one bucket per model with a real `remainingFraction`.
//
// Endpoint:  POST https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuota
// Body:      {"project": "default"}
// Auth:      Authorization: Bearer <google_oauth_access_token>
// Identifiers and refresh endpoint extracted from the shipped Gemini CLI bundle.

/// Snapshot of `~/.gemini/oauth_creds.json` after parsing.
private struct GeminiOAuthCredentials {
    let accessToken: String
    let refreshToken: String?
    let expiryDateMillis: Double?  // ms since epoch (Google's format)

    var expiresAt: Date? {
        expiryDateMillis.map { Date(timeIntervalSince1970: $0 / 1000) }
    }

    func needsRefresh(buffer: TimeInterval) -> Bool {
        guard let expiresAt else { return false }
        return Date().addingTimeInterval(buffer) >= expiresAt
    }
}

/// Decodes the response from Google's OAuth refresh endpoint.
private struct GeminiOAuthRefreshResponse: Decodable {
    let accessToken: String
    let expiresIn: Int?
    let refreshToken: String?

    enum CodingKeys: String, CodingKey {
        case accessToken  = "access_token"
        case expiresIn    = "expires_in"
        case refreshToken = "refresh_token"
    }
}

/// One quota bucket returned by `retrieveUserQuota`.
private struct GeminiQuotaBucket: Decodable {
    let modelId: String
    let remainingFraction: Double?
    let remainingAmount: String?
    let resetTime: Date?
    let tokenType: String?

    enum CodingKeys: String, CodingKey {
        case modelId          = "modelId"
        case remainingFraction = "remainingFraction"
        case remainingAmount  = "remainingAmount"
        case resetTime        = "resetTime"
        case tokenType        = "tokenType"
    }
}

private struct GeminiQuotaResponse: Decodable {
    let buckets: [GeminiQuotaBucket]
}

/// Coalesces concurrent token reads, refreshes the Google access token when
/// it's near expiry, and serves a usable bearer token to live-quota calls.
/// Tokens are persisted only in memory — the user's `~/.gemini/oauth_creds.json`
/// file is read-only for our purposes (Gemini CLI rewrites it when run).
private actor GeminiOAuthTokenManager {
    static let shared = GeminiOAuthTokenManager()

    // Refresh slightly before the stored expiry so the live API call never
    // races a token going invalid mid-flight.
    private let refreshBuffer: TimeInterval = 5 * 60     // 5 min
    private let minRetryInterval: TimeInterval = 60      // post-failure backoff

    /// OAuth identifiers extracted verbatim from `chunk-B2OARGJJ.js` in the
    /// shipped Gemini CLI bundle (variables `OAUTH_CLIENT_ID` / `OAUTH_CLIENT_SECRET`).
    /// They are embedded in the public CLI binary; treating them as public
    /// "installed app" client identifiers is the standard Google pattern.
    private let clientID     = "681255809395-oo8ft2oprdrnp9e3aqf6av3hmdib135j.apps.googleusercontent.com"
    private let clientSecret = "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"

    /// In-memory override that survives the access-token expiry until the user
    /// next runs the Gemini CLI (which re-writes the file).
    private var refreshedAccessToken: String?
    private var refreshedExpiresAt: Date?
    private var inflight: Task<String?, Never>?
    private var lastFailureAt: Date?

    func currentAccessToken(geminiRootURL: URL) async -> String? {
        // Prefer our in-memory refreshed token if still valid.
        if let refreshedAccessToken,
           let refreshedExpiresAt,
           Date().addingTimeInterval(refreshBuffer) < refreshedExpiresAt {
            return refreshedAccessToken
        }

        guard let creds = Self.readOAuthCredsFile(geminiRootURL: geminiRootURL) else {
            return nil
        }

        if !creds.needsRefresh(buffer: refreshBuffer) {
            return creds.accessToken
        }

        // Refresh-error backoff.
        if let lastFailureAt, Date().timeIntervalSince(lastFailureAt) < minRetryInterval {
            return creds.accessToken
        }

        if let inflight {
            return await inflight.value
        }

        let task = Task { [creds] in
            await self.performRefresh(creds: creds)
        }
        inflight = task
        let result = await task.value
        inflight = nil

        if result == nil {
            lastFailureAt = Date()
            return creds.accessToken  // Stale but maybe still usable
        }
        lastFailureAt = nil
        return result
    }

    private func performRefresh(creds: GeminiOAuthCredentials) async -> String? {
        guard let refreshToken = creds.refreshToken, !refreshToken.isEmpty else {
            print("[GeminiOAuth] No refresh_token available — cannot refresh")
            return nil
        }

        let url = URL(string: "https://oauth2.googleapis.com/token")!
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        // Google's refresh request is x-www-form-urlencoded.
        let params = [
            "client_id":     clientID,
            "client_secret": clientSecret,
            "refresh_token": refreshToken,
            "grant_type":    "refresh_token"
        ]
        request.httpBody = params
            .map { "\($0.key)=\(Self.urlEncode($0.value))" }
            .joined(separator: "&")
            .data(using: .utf8)

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                let status = (response as? HTTPURLResponse)?.statusCode ?? -1
                let bodyStr = String(data: data, encoding: .utf8)?.prefix(300) ?? ""
                print("[GeminiOAuth] Refresh HTTP \(status): \(bodyStr)")
                return nil
            }
            let parsed = try JSONDecoder().decode(GeminiOAuthRefreshResponse.self, from: data)
            refreshedAccessToken = parsed.accessToken
            refreshedExpiresAt = parsed.expiresIn.map { Date().addingTimeInterval(TimeInterval($0)) }
            print("[GeminiOAuth] Refresh OK. New token expires in \(parsed.expiresIn ?? -1)s")
            return parsed.accessToken
        } catch {
            print("[GeminiOAuth] Refresh failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// Reads and parses `oauth_creds.json` at `<geminiRootURL>/oauth_creds.json`.
    /// Caller must already hold security-scoped access on `geminiRootURL`.
    private static func readOAuthCredsFile(geminiRootURL: URL) -> GeminiOAuthCredentials? {
        let credsURL = geminiRootURL.appendingPathComponent("oauth_creds.json")
        guard let data = try? Data(contentsOf: credsURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accessToken = json["access_token"] as? String,
              !accessToken.isEmpty else {
            return nil
        }
        let refreshToken = json["refresh_token"] as? String
        let expiry = (json["expiry_date"] as? NSNumber)?.doubleValue
        return GeminiOAuthCredentials(
            accessToken: accessToken,
            refreshToken: refreshToken,
            expiryDateMillis: expiry
        )
    }

    private static func urlEncode(_ value: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=+/?")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}

/// Per-cycle cache for the live quota response so we don't hammer Google's
/// endpoint at the dashboard's refresh interval. 90s fresh, 30 min stale fallback.
private final class GeminiQuotaCache: @unchecked Sendable {
    static let shared = GeminiQuotaCache()
    private let freshTTL: TimeInterval = 90
    private let staleTTL: TimeInterval = 30 * 60
    private let lock = NSLock()
    private var stored: (windows: [QuotaWindow], fetchedAt: Date)?

    func fresh() -> [QuotaWindow]? {
        lock.lock(); defer { lock.unlock() }
        guard let stored, Date().timeIntervalSince(stored.fetchedAt) < freshTTL else { return nil }
        return stored.windows
    }
    func staleFallback() -> [QuotaWindow]? {
        lock.lock(); defer { lock.unlock() }
        guard let stored, Date().timeIntervalSince(stored.fetchedAt) < staleTTL else { return nil }
        return stored.windows
    }
    func store(_ windows: [QuotaWindow]) {
        lock.lock(); defer { lock.unlock() }
        stored = (windows, Date())
    }
}

enum GeminiLiveQuotaFetcher {
    /// Calls the Code Assist quota endpoint and returns one `QuotaWindow` per
    /// bucket. Returns nil on auth/network failure (caller falls back to the
    /// local heuristic).
    static func fetchWindows(accessToken: String) async -> [QuotaWindow]? {
        if let cached = GeminiQuotaCache.shared.fresh() {
            return cached
        }
        let url = URL(string: "https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuota")!
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["project": "default"])

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                let status = (response as? HTTPURLResponse)?.statusCode ?? -1
                print("[GeminiLiveQuota] HTTP \(status) — falling back to stale cache if any")
                return GeminiQuotaCache.shared.staleFallback()
            }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = ISO8601Timestamp.decodingStrategy
            let parsed = try decoder.decode(GeminiQuotaResponse.self, from: data)

            let windows = buildWindows(from: parsed.buckets)
            GeminiQuotaCache.shared.store(windows)
            return windows
        } catch {
            print("[GeminiLiveQuota] Fetch error: \(error.localizedDescription)")
            return GeminiQuotaCache.shared.staleFallback()
        }
    }

    /// Maps each bucket into a `QuotaWindow`. Order matches what Gemini CLI
    /// shows: current-generation Pro / Flash / Flash Lite first, previews last;
    /// most-used at the top of each tier.
    private static func buildWindows(from buckets: [GeminiQuotaBucket]) -> [QuotaWindow] {
        // Sort: highest "used" first within priority tiers.
        let sorted = buckets.sorted { a, b in
            let aUsed = 1.0 - (a.remainingFraction ?? 1.0)
            let bUsed = 1.0 - (b.remainingFraction ?? 1.0)
            if (priority(a.modelId) != priority(b.modelId)) {
                return priority(a.modelId) < priority(b.modelId)
            }
            return aUsed > bUsed
        }

        return sorted.compactMap { bucket -> QuotaWindow? in
            guard let remaining = bucket.remainingFraction else { return nil }
            let usedPercent = max(0.0, min(100.0, (1.0 - remaining) * 100.0))
            return QuotaWindow(
                label: displayName(for: bucket.modelId),
                windowKind: .daily,
                used: usedPercent,
                total: 100,
                resetDate: bucket.resetTime,
                unit: "%",
                subtitle: "Live from Code Assist: \(bucket.modelId)"
            )
        }
    }

    /// Lower number = shown earlier. Groups by family then generation.
    private static func priority(_ modelId: String) -> Int {
        let id = modelId.lowercased()
        // Newest generation first.
        let genWeight = id.contains("3.1") ? 0 :
                        id.contains("3-") || id.hasSuffix("-3") ? 10 :
                        id.contains("2.5") ? 20 : 30
        let famWeight = id.contains("flash-lite") ? 2 :
                        id.contains("flash")      ? 1 :
                        id.contains("pro")        ? 0 : 3
        return genWeight + famWeight
    }

    /// Friendly label like "Pro 3.1 (preview)" or "Flash 2.5".
    private static func displayName(for modelId: String) -> String {
        let id = modelId.lowercased()
        let family: String =
            id.contains("flash-lite") ? "Flash Lite" :
            id.contains("flash")      ? "Flash" :
            id.contains("pro")        ? "Pro" : modelId
        let generation: String =
            id.contains("3.1") ? "3.1" :
            id.contains("3-")  || id.hasSuffix("-3") ? "3" :
            id.contains("2.5") ? "2.5" : ""
        let isPreview = id.contains("preview")
        let parts = [family, generation].filter { !$0.isEmpty }
        let base = parts.joined(separator: " ")
        return isPreview ? "\(base) (preview)" : base
    }
}
