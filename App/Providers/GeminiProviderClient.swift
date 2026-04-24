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

        // Fetch real-time quota from CLI if not throttled
        let cliQuota = await fetchCLIQuotaIfNecessary()

        let reader = GeminiLocalStateReader(fileManager: fileManager, cliQuota: cliQuota)

        print("[GeminiProvider] Reading local Gemini CLI data from: \(rootURL.path)")
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
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

                do {
                    continuation.resume(returning: try reader.loadSnapshot(rootURL: accessURL, credentials: credentials))
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

private struct GeminiLocalStateReader {
    private let fileManager: FileManager
    private let decoder: JSONDecoder
    private let cliQuota: GeminiCLIQuota?

    private static let cacheKey = "gemini_snapshot_cache"
    private static let cacheDateKey = "gemini_snapshot_cache_date"
    private let cacheValidityInterval: TimeInterval = 5 * 60 // 5 minutes

    init(fileManager: FileManager, cliQuota: GeminiCLIQuota? = nil) {
        self.fileManager = fileManager
        self.decoder = JSONDecoder()
        self.decoder.dateDecodingStrategy = .iso8601
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
            for fileURL in sessionFiles where fileURL.pathExtension == "json" {
                if let fileDate = try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate {
                    latestDate = max(latestDate, fileDate)
                }
            }
        }

        return latestDate
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

    private func loadSnapshotUncached(rootURL: URL, credentials: ProviderCredential?, latestFileDate: Date) throws -> QuotaSnapshot {
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

                for fileURL in sessionFiles where fileURL.pathExtension == "json" {
                    guard let data = try? Data(contentsOf: fileURL) else {
                        continue
                    }
                    guard let session = try? decoder.decode(GeminiSessionFile.self, from: data) else {
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
                    message: "Using Gemini CLI session for \(email).",
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

        let sortedEvents = events.sorted { $0.timestamp > $1.timestamp }
        let cappedEvents = Array(sortedEvents.prefix(1000))

        return QuotaSnapshot(
            providerID: .gemini,
            displayName: "Gemini CLI",
            planName: planName,
            windows: windows,
            stats: stats,
            balances: [],
            signals: signals,
            events: cappedEvents,
            fetchState: .success,
            fetchedAt: latestActivity > .distantPast ? latestActivity : now
        )
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

private struct GeminiCLIQuota {
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

private struct GeminiSessionFile: Decodable {
    let sessionId: String
    let messages: [GeminiMessage]
}

private struct GeminiMessage: Decodable {
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

private struct GeminiTokens: Decodable {
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
