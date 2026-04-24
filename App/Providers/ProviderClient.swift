import Foundation
import SQLite3

/// Every provider implements this protocol.
/// Receives credentials from KeychainService, returns a normalized QuotaSnapshot.
/// Never writes to storage directly — SyncCoordinator does that.
public protocol ProviderClient {
    var providerID: ProviderID { get }
    func fetchSnapshot(credentials: ProviderCredential?) async throws -> QuotaSnapshot
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
    public let providerID: ProviderID = .openai

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

        let (fetchedRateLimits, fetchedDailyUsagePage, fetchedMinuteUsagePage) = try await (
            rateLimits,
            dailyUsagePage,
            minuteUsagePage
        )

        guard !fetchedRateLimits.data.isEmpty else {
            throw ProviderFetchError.parsingError("No project rate limits were returned for this OpenAI project.")
        }

        let dailyUsageByModel = usageByModel(from: fetchedDailyUsagePage)
        let minuteUsageByModel = usageByModel(from: fetchedMinuteUsagePage)

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
        var events: [UsageEvent] = []

        // Extract usage events from daily buckets for heatmap
        for bucket in fetchedDailyUsagePage.data {
            let timestamp = Date(timeIntervalSince1970: bucket.startTime)
            let totalTokens = bucket.results.reduce(0) { $0 + $1.totalTokens }
            let model = bucket.results.first?.model

            events.append(UsageEvent(
                timestamp: timestamp,
                tokens: totalTokens,
                model: model,
                type: .bucket
            ))
        }

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
            providerID: .openai,
            displayName: "OpenAI Project",
            planName: displayModelName(selectedRateLimit.model),
            windows: windows,
            events: cappedEvents,
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
        projectID: String
    ) async throws -> OpenAIUsageBucketPage {
        let queryItems = [
            URLQueryItem(name: "start_time", value: String(Int(startTime.timeIntervalSince1970))),
            URLQueryItem(name: "end_time", value: String(Int(endTime.timeIntervalSince1970))),
            URLQueryItem(name: "bucket_width", value: bucketWidth),
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "project_ids", value: projectID),
            URLQueryItem(name: "group_by", value: "model")
        ]
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

    private func usageByModel(from page: OpenAIUsageBucketPage) -> [String: OpenAIUsageTotals] {
        var aggregated: [String: OpenAIUsageTotals] = [:]

        for bucket in page.data {
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
                fileURL: FileManager.default.fileExists(atPath: codexSQLite.path) ? codexSQLite : codexRoot,
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

        // Windsurf: Check for state.vscdb which contains cached quota and auth state
        let windsurfStateDBPath = home.appendingPathComponent("Library/Application Support/Windsurf/User/globalStorage/state.vscdb")
        if FileManager.default.fileExists(atPath: windsurfStateDBPath.path) {
            detected.append(DetectedCredential(
                providerID: .windsurf,
                fileURL: windsurfStateDBPath,
                description: "Windsurf local state"
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

        return detected
    }

    // MARK: - Import from URL

    /// Import credentials from a user-selected file URL
    public static func importFromURL(_ url: URL, for providerID: ProviderID) throws -> ImportedCredential {
        guard url.isFileURL else { throw ImportError.fileNotFound }

        if providerID == .codexTelemetry {
            let resolvedRoot = url.hasDirectoryPath ? url : url.deletingLastPathComponent()
            return ImportedCredential(
                accessToken: nil,
                accountIdentifier: nil,
                customEndpoint: resolvedRoot.path,
                extraFields: [
                    "codexTelemetrySource": url.hasDirectoryPath ? "directory" : "file"
                ],
                bookmarkData: makeSecurityScopedBookmarkData(for: resolvedRoot)
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

        // Special handling for SQLite databases (Windsurf and Cursor)
        if url.lastPathComponent == "state.vscdb" {
            print("[CredentialImportService] Reading SQLite database immediately: \(url.path)")

            // For Cursor: capture the selected DB path with a security-scoped
            // bookmark. The local editor token is useful for cached metadata,
            // but it is not enough for cursor.com live usage on its own.
            if providerID == .cursor {
                let bookmarkData = makeSecurityScopedBookmarkData(for: url.deletingLastPathComponent())
                return ImportedCredential(
                    accessToken: nil,
                    accountIdentifier: nil,
                    customEndpoint: url.path,
                    extraFields: [
                        "cursorAuthMode": "localState"
                    ],
                    bookmarkData: bookmarkData
                )
            }

            if providerID == .windsurf {
                let bookmarkData = makeSecurityScopedBookmarkData(for: url.deletingLastPathComponent())
                let authStatus = readWindsurfAuthStatus(from: url)

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

    private struct WindsurfAuthState {
        let apiKey: String?
        let accountIdentifier: String?
        let extraFields: [String: String]?
    }

    private static func readWindsurfAuthStatus(from url: URL) -> WindsurfAuthState? {
        guard FileManager.default.isReadableFile(atPath: url.path) else {
            print("[CredentialImportService] Windsurf state.vscdb not readable at path: \(url.path)")
            return nil
        }

        guard let db = openSQLiteSnapshotDatabase(at: url) else {
            print("[CredentialImportService] Failed to open Windsurf state.vscdb")
            return nil
        }
        defer { sqlite3_close(db) }

        guard let rawValue = readSQLiteValue(
            from: db,
            query: "SELECT value FROM ItemTable WHERE key = 'windsurfAuthStatus' LIMIT 1;"
        ),
        let data = rawValue.data(using: .utf8),
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            print("[CredentialImportService] No Windsurf auth status found in database")
            return nil
        }

        let apiKey = json["apiKey"] as? String
            ?? json["api_key"] as? String
            ?? json["access_token"] as? String
        let accountIdentifier = inferredWindsurfAccountIdentifier(from: json)

        var extraFields: [String: String] = [:]
        if let userStatus = json["userStatusProtoBinaryBase64"] as? String, !userStatus.isEmpty {
            extraFields["windsurfUserStatusProtoBinaryBase64"] = userStatus
        }

        return WindsurfAuthState(
            apiKey: apiKey,
            accountIdentifier: accountIdentifier,
            extraFields: extraFields.isEmpty ? nil : extraFields
        )
    }

    private static func inferredWindsurfAccountIdentifier(from json: [String: Any]) -> String? {
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
            return ImportedCredential(
                accessToken: nil,
                accountIdentifier: nil,
                customEndpoint: sourceURL.hasDirectoryPath ? sourceURL.path : sourceURL.deletingLastPathComponent().path,
                extraFields: [
                    "codexTelemetrySource": "json"
                ],
                bookmarkData: makeSecurityScopedBookmarkData(for: sourceURL.hasDirectoryPath ? sourceURL : sourceURL.deletingLastPathComponent())
            )
        case .claude:
            return try parseClaudeJSON(json, sourceURL: sourceURL)
        case .cursor:
            return try parseCursorJSON(json)
        case .windsurf:
            return try parseWindsurfJSON(json, sourceURL: sourceURL)
        case .gemini:
            let selectedRoot = sourceURL.hasDirectoryPath ? sourceURL : sourceURL.deletingLastPathComponent()
            return ImportedCredential(
                accessToken: nil,
                accountIdentifier: nil,
                customEndpoint: selectedRoot.path,
                extraFields: nil,
                bookmarkData: makeSecurityScopedBookmarkData(for: selectedRoot)
            )
        case .heatmap:
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

    private static func parseWindsurfJSON(_ json: [String: Any], sourceURL: URL) throws -> ImportedCredential {
        // If the selected file is state.vscdb, store its path as customEndpoint
        // so the provider can read quota data directly from it
        if sourceURL.lastPathComponent == "state.vscdb" {
            print("[CredentialImportService] Creating bookmark in parseWindsurfJSON for: \(sourceURL.path)")
            let bookmarkData = makeSecurityScopedBookmarkData(for: sourceURL)
            if let bookmarkData {
                print("[CredentialImportService] Created bookmark in parseWindsurfJSON (length: \(bookmarkData.count))")
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
            panel.message = "Select credential file for \(providerID.displayName)"
            panel.prompt = "Import"
            panel.allowedContentTypes = providerID == .codexTelemetry || providerID == .claude || providerID == .chatgpt || providerID == .gemini
                ? [UTType.folder, UTType.json, UTType.plainText, UTType.data]
                : [UTType.json, UTType.plainText, UTType.data]
            panel.allowsMultipleSelection = false
            panel.canChooseDirectories = providerID == .codexTelemetry || providerID == .claude || providerID == .chatgpt || providerID == .gemini

            // Suggest starting directory based on provider
            let home = FileManager.default.homeDirectoryForCurrentUser
            switch providerID {
            case .openai:
                panel.directoryURL = home.appendingPathComponent(".codex")
            case .chatgpt:
                panel.directoryURL = home.appendingPathComponent("Library/Application Support/com.openai.chat")
            case .codexTelemetry:
                panel.directoryURL = home.appendingPathComponent(".codex")
            case .claude:
                panel.directoryURL = home.appendingPathComponent(".claude")
            case .cursor:
                // Point to the directory containing state.vscdb
                panel.directoryURL = home.appendingPathComponent("Library/Application Support/Cursor/User/globalStorage")
            case .windsurf:
                // Point to the directory containing state.vscdb
                panel.directoryURL = home.appendingPathComponent("Library/Application Support/Windsurf/User/globalStorage")
            case .gemini:
                panel.directoryURL = home.appendingPathComponent(".gemini")
            case .heatmap:
                break
            }

            panel.begin { result in
                guard result == .OK, let url = panel.url else {
                    completion(.failure(ImportError.userCancelled))
                    return
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
        var windows: [QuotaWindow] = []
        var balances: [QuotaBalance] = []

        // Primary window: typically the 5-hour rolling window
        if let primary = payload.primaryWindow {
            windows.append(
                quotaWindow(
                    from: primary,
                    label: "Session",
                    windowKind: .session,
                    subtitle: "5-hour rolling window"
                )
            )
        }

        // Secondary window: typically the 7-day rolling window
        if let secondary = payload.secondaryWindow {
            windows.append(
                quotaWindow(
                    from: secondary,
                    label: "Weekly",
                    windowKind: .weekly,
                    subtitle: "7-day rolling window"
                )
            )
        }

        for additionalLimit in payload.additionalRateLimits {
            guard let rateLimit = additionalLimit.rateLimit else { continue }
            let name = additionalLimit.displayName

            if let primary = rateLimit.primaryWindow {
                windows.append(
                    quotaWindow(
                        from: primary,
                        label: "\(name) 5h",
                        windowKind: .session,
                        subtitle: "5-hour usage limit"
                    )
                )
            }

            if let secondary = rateLimit.secondaryWindow {
                windows.append(
                    quotaWindow(
                        from: secondary,
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
            windows: windows,
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

// MARK: - Windsurf Provider Client

public struct WindsurfProviderClient: ProviderClient {
    public let providerID: ProviderID = .windsurf

    public init() {}

    public func fetchSnapshot(credentials: ProviderCredential?) async throws -> QuotaSnapshot {
        print("[WindsurfProvider] Reading cached plan info from local state DB...")

        // Check if user has configured a custom file path
        var customPath: URL?
        var bookmarkData: Data?
        if let path = credentials?.customEndpoint, !path.isEmpty {
            customPath = URL(fileURLWithPath: path)
            print("[WindsurfProvider] Using configured file path: \(path)")
        }
        // Check for bookmark data in extraFields
        if let bookmarkBase64 = credentials?.extraFields?["bookmarkData"],
           let data = Data(base64Encoded: bookmarkBase64) {
            bookmarkData = data
            print("[WindsurfProvider] Found security-scoped bookmark data")
        }

        do {
            let state = try WindsurfLocalStateReader.loadCachedPlanInfo(customPath: customPath, bookmarkData: bookmarkData)
            return makeSnapshot(from: state)
        } catch {
            print("[WindsurfProvider] Failed to read cached plan info: \(error.localizedDescription)")
            throw error as? ProviderFetchError ?? .parsingError(error.localizedDescription)
        }
    }

    private func makeSnapshot(from state: WindsurfStateSnapshot) -> QuotaSnapshot {
        let planInfo = state.planInfo
        let localMetadata = state.localMetadata
        let now = Date()
        var windows: [QuotaWindow] = []
        var balances: [QuotaBalance] = []
        var stats: [QuotaStat] = []
        var signals: [QuotaSignal] = []

        if !planInfo.hideDailyQuota, let remaining = planInfo.quotaUsage?.dailyRemainingPercent {
            let resetDate = Date(timeIntervalSince1970: TimeInterval(planInfo.quotaUsage?.dailyResetAtUnix ?? planInfo.endTimestamp / 1000))
            windows.append(
                QuotaWindow(
                    label: "Daily Quota",
                    windowKind: .session,
                    used: max(0, 100 - Double(remaining)),
                    total: 100,
                    resetDate: resetDate,
                    unit: "%",
                    subtitle: "Resets daily"
                )
            )
        }

        if !planInfo.hideWeeklyQuota, let remaining = planInfo.quotaUsage?.weeklyRemainingPercent {
            let resetDate = Date(timeIntervalSince1970: TimeInterval(planInfo.quotaUsage?.weeklyResetAtUnix ?? planInfo.endTimestamp / 1000))
            windows.append(
                QuotaWindow(
                    label: "Weekly Quota",
                    windowKind: .weekly,
                    used: max(0, 100 - Double(remaining)),
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
                    label: "Extra Balance",
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
                    value: Double(usage.remainingMessages),
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
                    value: Double(usage.remainingFlowActions),
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
                    value: Double(usage.remainingFlexCredits),
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
                    subtitle: "Since Windsurf telemetry last recorded activity"
                )
            )
        }

        if planInfo.hasBillingWritePermissions == true {
            signals.append(
                QuotaSignal(
                    kind: .unexpectedRecovery,
                    title: "Billing write permissions enabled",
                    message: "The local Windsurf cache reports billing write access is available.",
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
            providerID: .windsurf,
            displayName: "Windsurf",
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

private enum WindsurfLocalStateReader {
    static func loadCachedPlanInfo(customPath: URL? = nil, bookmarkData: Data? = nil) throws -> WindsurfStateSnapshot {
        print("[WindsurfLocalStateReader] Searching for state.vscdb...")

        // If we have bookmark data, resolve it first (this gives us sandbox access)
        if let bookmarkData = bookmarkData {
            print("[WindsurfLocalStateReader] Resolving security-scoped bookmark...")
            do {
                let resolvedURL = try resolveSecurityScopedURL(from: bookmarkData)
                print("[WindsurfLocalStateReader] Resolved bookmark to: \(resolvedURL.path)")

                // Start accessing the security-scoped resource
                let accessGranted = resolvedURL.startAccessingSecurityScopedResource()
                defer {
                    if accessGranted {
                        resolvedURL.stopAccessingSecurityScopedResource()
                        print("[WindsurfLocalStateReader] Stopped accessing security-scoped resource")
                    }
                }

                if accessGranted {
                    print("[WindsurfLocalStateReader] Security-scoped access granted")
                    let bookmarkLoadURL = resolvedDatabaseURL(
                        bookmarkURL: resolvedURL,
                        customPath: customPath
                    )
                    if let state = try loadCachedPlanInfo(from: bookmarkLoadURL) {
                        print("[WindsurfLocalStateReader] Successfully loaded from bookmark")
                        return state
                    }
                } else {
                    print("[WindsurfLocalStateReader] Failed to get security-scoped access")
                }
            } catch {
                print("[WindsurfLocalStateReader] Failed to resolve bookmark: \(error)")
            }
        }

        // If user provided a custom path, try that next
        if let customPath = customPath {
            print("[WindsurfLocalStateReader] Trying user-provided path: \(customPath.path)")
            print("[WindsurfLocalStateReader] Exists: \(FileManager.default.fileExists(atPath: customPath.path))")
            print("[WindsurfLocalStateReader] Readable: \(FileManager.default.isReadableFile(atPath: customPath.path))")

            if let state = try loadCachedPlanInfo(from: customPath) {
                print("[WindsurfLocalStateReader] Successfully loaded from user-provided path")
                return state
            }
            print("[WindsurfLocalStateReader] Failed to load from user-provided path, will try auto-discovery")
        }

        // Fall back to auto-discovery (won't work in sandboxed apps, but useful for non-sandboxed builds)
        for url in possibleStateDatabaseURLs() {
            print("[WindsurfLocalStateReader] Checking: \(url.path)")
            print("[WindsurfLocalStateReader] Exists: \(FileManager.default.fileExists(atPath: url.path))")
            print("[WindsurfLocalStateReader] Readable: \(FileManager.default.isReadableFile(atPath: url.path))")

            if let state = try loadCachedPlanInfo(from: url) {
                print("[WindsurfLocalStateReader] Successfully loaded from: \(url.path)")
                return state
            }
        }

        print("[WindsurfLocalStateReader] Could not find or read state.vscdb from any location")
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
        paths.append(realHome.appendingPathComponent("Library/Application Support/Windsurf/User/globalStorage/state.vscdb"))
        paths.append(realHome.appendingPathComponent("Library/Application Support/Windsurf/User/globalStorage/state.vscdb.backup"))

        return paths
    }

    private static func loadCachedPlanInfo(from url: URL) throws -> WindsurfStateSnapshot? {
        guard FileManager.default.isReadableFile(atPath: url.path) else {
            print("[WindsurfLocalStateReader] File not readable: \(url.path)")
            return nil
        }

        var db: OpaquePointer?
        let result = sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil)
        guard result == SQLITE_OK, let db else {
            print("[WindsurfLocalStateReader] Failed to open DB: \(result)")
            if let db { sqlite3_close(db) }
            return nil
        }
        defer { sqlite3_close(db) }

        let query = "SELECT value FROM ItemTable WHERE key = 'windsurf.settings.cachedPlanInfo' LIMIT 1;"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK, let statement else {
            print("[WindsurfLocalStateReader] Failed to prepare statement")
            return nil
        }
        defer { sqlite3_finalize(statement) }

        let stepResult = sqlite3_step(statement)
        guard stepResult == SQLITE_ROW else {
            print("[WindsurfLocalStateReader] No row found, step result: \(stepResult)")
            return nil
        }

        guard let textPointer = sqlite3_column_text(statement, 0) else {
            print("[WindsurfLocalStateReader] No text in column")
            return nil
        }

        let jsonString = String(cString: textPointer)
        print("[WindsurfLocalStateReader] Got JSON (first 200 chars): \(jsonString.prefix(200))")

        guard let data = jsonString.data(using: .utf8) else {
            print("[WindsurfLocalStateReader] Failed to convert to data")
            return nil
        }

        do {
            let planInfo = try JSONDecoder().decode(WindsurfCachedPlanInfo.self, from: data)
            print("[WindsurfLocalStateReader] Successfully decoded plan: \(planInfo.planName)")
            let localMetadata = try loadLocalMetadata(from: db)
            return WindsurfStateSnapshot(planInfo: planInfo, localMetadata: localMetadata)
        } catch {
            print("[WindsurfLocalStateReader] JSON decode error: \(error)")
            throw error
        }
    }

    private static func loadLocalMetadata(from db: OpaquePointer) throws -> WindsurfLocalMetadata {
        let spaceMetadata = try loadJSONDictionary(from: db, key: "windsurfSpace.metadata")
        let resourceToSpace = try loadJSONObject(from: db, key: "windsurfSpace.resourceToSpace")
        let lastSessionDate = try loadDate(from: db, key: "telemetry.lastSessionDate")

        let latestSpaceAccessDate = spaceMetadata?.values
            .compactMap { $0["lastAccessed"] as? Double }
            .map { Date(timeIntervalSince1970: $0 / 1000) }
            .max()

        return WindsurfLocalMetadata(
            spaceCount: spaceMetadata?.count,
            resourceLinkCount: resourceToSpace?.count,
            latestSpaceAccessDate: latestSpaceAccessDate,
            lastSessionDate: lastSessionDate
        )
    }

    private static func loadJSONObject(from db: OpaquePointer, key: String) throws -> [String: Any]? {
        guard let text = try loadTextValue(from: db, key: key),
              let data = text.data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return object
    }

    private static func loadJSONDictionary(from db: OpaquePointer, key: String) throws -> [String: [String: Any]]? {
        guard let object = try loadJSONObject(from: db, key: key) else {
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
        let query = "SELECT value FROM ItemTable WHERE key = ? LIMIT 1;"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw ProviderFetchError.parsingError("Failed to prepare Windsurf metadata query.")
        }
        defer { sqlite3_finalize(statement) }

        let transientDestructor = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        _ = key.withCString { cString in
            sqlite3_bind_text(statement, 1, cString, -1, transientDestructor)
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

private struct WindsurfCachedPlanInfo: Decodable {
    let planName: String
    let startTimestamp: Int
    let endTimestamp: Int
    let usage: WindsurfUsageSummary?
    let quotaUsage: WindsurfQuotaUsage?
    let hasBillingWritePermissions: Bool?
    let gracePeriodStatus: Int?
    let teamsTier: Int?
    let hideDailyQuota: Bool
    let hideWeeklyQuota: Bool

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
    }
}

private struct WindsurfStateSnapshot {
    let planInfo: WindsurfCachedPlanInfo
    let localMetadata: WindsurfLocalMetadata?
}

private struct WindsurfLocalMetadata {
    let spaceCount: Int?
    let resourceLinkCount: Int?
    let latestSpaceAccessDate: Date?
    let lastSessionDate: Date?
}

private struct WindsurfUsageSummary: Decodable {
    let duration: Int
    let messages: Int
    let flowActions: Int
    let flexCredits: Int
    let usedMessages: Int
    let usedFlowActions: Int
    let usedFlexCredits: Int
    let remainingMessages: Int
    let remainingFlowActions: Int
    let remainingFlexCredits: Int
}

private struct WindsurfQuotaUsage: Decodable {
    let dailyRemainingPercent: Int?
    let weeklyRemainingPercent: Int?
    let overageBalanceMicros: Int?
    let dailyResetAtUnix: Int?
    let weeklyResetAtUnix: Int?
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
                    return (resolvedURL, fallbackStateDBURL)
                }
                return (resolvedURL, resolvedURL)
            } catch {
                print("[CursorProvider] Failed to resolve bookmark: \(error), falling back to configured path")
            }
        }

        if let customPath, !customPath.isEmpty {
            print("[CursorProvider] Using configured file path: \(customPath)")
            let url = URL(fileURLWithPath: customPath)
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
        guard url.lastPathComponent == "state.vscdb" else {
            return [url]
        }

        return [
            url,
            url.deletingLastPathComponent().appendingPathComponent("state.vscdb.backup")
        ]
    }

    private func resolvedStateDBURL(customPath: String?) -> URL {
        if let customPath, !customPath.isEmpty {
            return URL(fileURLWithPath: customPath)
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

        var events: [UsageEvent] = []
        if let dailyStats = localState?.dailyStats {
            for stat in dailyStats {
                events.append(UsageEvent(
                    timestamp: stat.date,
                    // Cursor dailyStats is request-count based. Treat as activity, not tokens, so
                    // the heatmap "today" token total doesn't get wildly inflated.
                    tokens: nil,
                    model: "Cursor",
                    type: .bucket
                ))
            }
        }

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
            fetchState: .success,
            fetchedAt: now
        )
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
            signals.append(
                QuotaSignal(
                    kind: .unexpectedRecovery,
                    title: "Membership cached as \(membershipType.capitalized)",
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

private struct ChatGPTDesktopLocalStateReader {
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

// MARK: - Claude Provider Client

/// Reads local Claude Code transcript metadata and usage snapshots.
/// This is a no-API, user-controlled local source.
public struct ClaudeProviderClient: ProviderClient {
    public let providerID: ProviderID = .claude

    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    public func fetchSnapshot(credentials: ProviderCredential?) async throws -> QuotaSnapshot {
        let rootURL = resolvedClaudeRootURL(credentials: credentials)
        let bookmarkData = claudeBookmarkData(from: credentials)
        let reader = ClaudeCodeLocalStateReader(fileManager: fileManager)

        print("[ClaudeProvider] Reading local Claude Code logs from: \(rootURL.path)")
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
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
    }

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
}

private struct ClaudeCodeLocalStateReader {
    private let fileManager: FileManager

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
        let recentTranscriptInfos = transcriptInfos.filter { $0.modificationDate >= monthStart }
        let scanInfos = recentTranscriptInfos.isEmpty ? [transcriptInfos[0]] : recentTranscriptInfos

        var latestSessionURL: URL?
        var latestSessionDate = Date.distantPast
        var currentSessionTokens: Double = 0
        var dayTokens: Double = 0
        var weekTokens: Double = 0
        var monthTokens: Double = 0
        var latestActivity = Date.distantPast
        var events: [UsageEvent] = []
        let metadata = loadMetadata(rootURL: rootURL)

        for transcriptInfo in scanInfos {
            let transcriptURL = transcriptInfo.url
            let fileDate = transcriptInfo.modificationDate
            let records = (try? readUsageRecords(from: transcriptURL)) ?? []
            guard !records.isEmpty else { continue }

            let transcriptTokens = records.reduce(0.0) { $0 + $1.tokens }
            if fileDate > latestSessionDate {
                latestSessionDate = fileDate
                latestSessionURL = transcriptURL
                currentSessionTokens = transcriptTokens
            }

            for record in records {
                events.append(UsageEvent(
                    timestamp: record.timestamp,
                    tokens: record.tokens,
                    model: "Claude",
                    type: .message
                ))

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
        let sortedEvents = events.sorted { $0.timestamp > $1.timestamp }
        let cappedEvents = Array(sortedEvents.prefix(1000))

        return QuotaSnapshot(
            providerID: .claude,
            displayName: "Claude Code",
            planName: planName,
            windows: windows,
            stats: stats,
            signals: signals,
            events: cappedEvents,
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

    private func readUsageRecords(from url: URL) throws -> [ClaudeUsageRecord] {
        let data = try Data(contentsOf: url)
        guard let text = String(data: data, encoding: .utf8) else {
            return []
        }

        var records: [ClaudeUsageRecord] = []
        var seenUsageKeys = Set<String>()
        for line in text.split(whereSeparator: \.isNewline) {
            guard
                let lineData = line.data(using: .utf8),
                let json = try JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                let timestamp = parseTimestamp(json["timestamp"] as? String)
            else {
                continue
            }

            let usageObject = (json["usage"] as? [String: Any]) ?? (json["message"] as? [String: Any])?["usage"] as? [String: Any]
            guard let usageObject else { continue }

            let tokens = tokenCount(from: usageObject)
            guard tokens > 0 else { continue }

            let requestID = (json["requestId"] as? String) ?? ""
            let messageID = ((json["message"] as? [String: Any])?["id"] as? String) ?? ""
            let dedupeKey = "\(requestID)|\(messageID)|\(Int(timestamp.timeIntervalSince1970))|\(Int(tokens))"
            guard seenUsageKeys.insert(dedupeKey).inserted else { continue }

            records.append(ClaudeUsageRecord(timestamp: timestamp, tokens: tokens))
        }

        return records
    }

    private func tokenCount(from usage: [String: Any]) -> Double {
        func number(_ key: String) -> Double {
            if let value = usage[key] as? Double { return value }
            if let value = usage[key] as? Int { return Double(value) }
            if let value = usage[key] as? NSNumber { return value.doubleValue }
            return 0
        }

        // Cache fields can be extremely large and are often repeated across
        // incremental transcript entries, which inflates usage snapshots.
        // Track direct model IO tokens for stable, human-expected totals.
        return number("input_tokens")
            + number("output_tokens")
            + number("input_audio_tokens")
            + number("output_audio_tokens")
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

private struct ClaudeUsageRecord {
    let timestamp: Date
    let tokens: Double
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
    case networkError(underlying: Error)
    case parsingError(String)
    case rateLimited
    case unknown

    public var errorDescription: String? {
        switch self {
        case .notConfigured:          return "Provider not configured."
        case .invalidCredential:      return "Invalid API key or session."
        case .networkError(let e):    return "Network error: \(e.localizedDescription)"
        case .parsingError(let msg):  return "Parse error: \(msg)"
        case .rateLimited:            return "Rate limited. Try again later."
        case .unknown:                return "An unknown error occurred."
        }
    }
}
