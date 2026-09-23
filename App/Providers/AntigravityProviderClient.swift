import Foundation

struct AntigravityUsageObservation: Equatable {
    let planName: String?
    let windows: [QuotaWindow]
}

struct AntigravityOAuthSession: Equatable {
    let accessToken: String
    let refreshToken: String?
    let expiry: Date?
}

nonisolated enum AntigravityOAuthSessionParser {
    private struct Envelope: Decodable {
        let token: Token
    }

    private struct Token: Decodable {
        let accessToken: String
        let refreshToken: String?
        let expiry: String?

        private enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case refreshToken = "refresh_token"
            case expiry
        }
    }

    static func parse(_ data: Data) throws -> AntigravityOAuthSession {
        let envelope = try JSONDecoder().decode(Envelope.self, from: data)
        let accessToken = envelope.token.accessToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !accessToken.isEmpty else { throw ProviderFetchError.invalidCredential }

        let refreshToken = envelope.token.refreshToken?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty

        return AntigravityOAuthSession(
            accessToken: accessToken,
            refreshToken: refreshToken,
            expiry: envelope.token.expiry.flatMap(parseDate)
        )
    }

    private static func parseDate(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }
}

nonisolated enum AntigravityQuotaSummaryParser {
    private struct Response: Decodable {
        let groups: [Group]
    }

    private struct Group: Decodable {
        let buckets: [Bucket]
    }

    private struct Bucket: Decodable {
        let bucketId: String
        let displayName: String?
        let remainingFraction: Double
        let resetTime: String?
    }

    static func parse(
        _ data: Data,
        planName: String?
    ) throws -> AntigravityUsageObservation? {
        let response = try JSONDecoder().decode(Response.self, from: data)
        let buckets = response.groups.flatMap(\.buckets)

        let trackedBuckets = buckets.compactMap(AntigravityBucketCandidate.init)

        guard trackedBuckets.contains(where: { $0.family == .gemini && $0.windowKind == .session }),
              trackedBuckets.contains(where: { $0.family == .gemini && $0.windowKind == .weekly }) else {
            return nil
        }

        let hasDedicatedClaudeOrGPTBuckets = trackedBuckets.contains {
            $0.family == .claude || $0.family == .gpt
        }
        let activeCandidates = trackedBuckets.filter {
            $0.family != .combined3P || !hasDedicatedClaudeOrGPTBuckets
        }

        let windows = activeCandidates.compactMap { candidate in
            makeWindow(
                from: candidate.bucket,
                label: candidate.label,
                kind: candidate.windowKind
            ).map { candidate.windowOrdered($0) }
        }
        .sorted { lhs, rhs in
            if lhs.order != rhs.order { return lhs.order < rhs.order }
            return lhs.window.label < rhs.window.label
        }
        .map(\.window)

        let ordered = windows
        guard ordered.count >= 2 else { return nil }

        return AntigravityUsageObservation(
            planName: planName?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
            windows: ordered
        )
    }

    private struct AntigravityBucketCandidate {
        enum Family {
            case gemini
            case claude
            case gpt
            case combined3P
        }

        let bucket: Bucket
        let label: String
        let family: Family
        let windowKind: QuotaWindowKind
        let familyOrder: Int
        let windowOrder: Int

        init?(bucket: Bucket) {
            let normalized = bucket.bucketId.lowercased()
            guard let delimiter = normalized.firstIndex(of: "-") else { return nil }
            let family = String(normalized[..<delimiter])
            let window = String(normalized[normalized.index(after: delimiter)...])
            let isFiveHour = window == "5h"
            let isWeekly = window == "weekly"
            guard isFiveHour || isWeekly else { return nil }

            let windowKind: QuotaWindowKind = isFiveHour ? .session : .weekly
            let windowOrder = isFiveHour ? 0 : 1

            let (familyType, familyOrder, familyLabel): (Family, Int, String)
            switch family {
            case "gemini":
                (familyType, familyOrder, familyLabel) = (.gemini, 0, "Gemini")
            case "claude":
                (familyType, familyOrder, familyLabel) = (.claude, 1, "Claude")
            case "gpt":
                (familyType, familyOrder, familyLabel) = (.gpt, 2, "GPT")
            case "3p":
                (familyType, familyOrder, familyLabel) = (.combined3P, 3, "Claude/GPT")
            default:
                return nil
            }

            self.bucket = bucket
            self.label = "\(familyLabel) \(isFiveHour ? "5H" : "Weekly")"
            self.family = familyType
            self.windowKind = windowKind
            self.familyOrder = familyOrder
            self.windowOrder = windowOrder
        }

        func windowOrdered(_ window: QuotaWindow) -> OrderedWindow {
            OrderedWindow(window: window, order: familyOrder * 2 + windowOrder)
        }
    }

    private struct OrderedWindow {
        let window: QuotaWindow
        let order: Int
    }

    private static func makeWindow(
        from bucket: Bucket,
        label: String,
        kind: QuotaWindowKind
    ) -> QuotaWindow? {
        guard bucket.remainingFraction.isFinite,
              (-0.000_001...1.000_001).contains(bucket.remainingFraction) else {
            return nil
        }

        let remaining = min(max(bucket.remainingFraction, 0), 1)
        let usedPercent = (1 - remaining) * 100
        let resetDate = bucket.resetTime.flatMap { ISO8601DateFormatter().date(from: $0) }

        return QuotaWindow(
            label: label,
            windowKind: kind,
            used: usedPercent,
            total: 100,
            resetDate: resetDate,
            unit: "%",
            subtitle: "Official Antigravity quota - \(compactPercent(remaining * 100))% remaining"
        )
    }

    private static func compactPercent(_ value: Double) -> String {
        value.rounded() == value ? String(Int(value)) : String(format: "%.1f", value)
    }
}

/// Autonomous Antigravity quota refresh cadence (minutes): 4 → 7 → 16 → 3 → 21 → loop.
enum AntigravityRefreshCadence {
    static let intervalsMinutes: [Int] = [4, 7, 16, 3, 21]

    static var intervals: [TimeInterval] {
        intervalsMinutes.map { TimeInterval($0 * 60) }
    }

    static func interval(at index: Int) -> TimeInterval {
        let steps = intervals
        guard !steps.isEmpty else { return 4 * 60 }
        let normalized = ((index % steps.count) + steps.count) % steps.count
        return steps[normalized]
    }

    static func nextIndex(after index: Int) -> Int {
        let count = max(intervals.count, 1)
        return (index + 1) % count
    }

    /// Whether an autonomous refresh is due given the current cadence step.
    static func isDue(
        now: Date,
        cadenceIndex: Int,
        fetchedAt: Date?,
        lastAttemptAt: Date?
    ) -> Bool {
        let required = interval(at: cadenceIndex)
        guard let reference = fetchedAt ?? lastAttemptAt else { return true }
        return now.timeIntervalSince(reference) >= required
    }
}

private actor AntigravityUsageCache {
    static let shared = AntigravityUsageCache()

    private var observation: AntigravityUsageObservation?
    private var fetchedAt: Date?
    private var lastAttemptAt: Date?
    private var cadenceIndex = 0

    func cachedObservation() -> AntigravityUsageObservation? {
        observation
    }

    /// Manual refreshes always proceed. Autonomous refreshes follow the
    /// 4→7→16→3→21 minute cadence loop.
    func beginFetch(userInitiated: Bool, now: Date = Date()) -> Bool {
        if !userInitiated {
            guard AntigravityRefreshCadence.isDue(
                now: now,
                cadenceIndex: cadenceIndex,
                fetchedAt: fetchedAt,
                lastAttemptAt: lastAttemptAt
            ) else {
                return false
            }
        }
        lastAttemptAt = now
        return true
    }

    func store(_ value: AntigravityUsageObservation, at date: Date = Date()) {
        observation = value
        fetchedAt = date
        cadenceIndex = AntigravityRefreshCadence.nextIndex(after: cadenceIndex)
    }
}

public struct AntigravityProviderClient: UserInitiatedProviderClient {
    public let providerID: ProviderID = .antigravity

    private static let clientID = "1071006060591-tmhssin2h21lcre235vtolojh4g403ep.apps.googleusercontent.com"
    // Installed-app OAuth secrets are public client identifiers, not user credentials.
    private static let clientSecret = "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"
    /// The CLI's own user agent, which names the architecture.
    ///
    /// This is a universal binary, so the process runs whichever slice the OS
    /// picked and the agent has to describe that slice rather than assert
    /// `arm64`. Hardcoding it made every Intel Mac lie to Google's endpoint —
    /// harmless while the app was arm64-only in practice, and a real
    /// misidentification the moment an Intel build ships. A compile-time branch
    /// is the correct source of truth here: each slice reports its own
    /// architecture, which is exactly what the running process is.
    private static let userAgent: String = {
        #if arch(arm64)
        let arch = "arm64"
        #elseif arch(x86_64)
        let arch = "x86_64"
        #else
        let arch = "unknown"
        #endif
        return "antigravity/cli/1.1.9 (aidev_client; os_type=darwin; arch=\(arch); auth_method=consumer)"
    }()
    private static let tokenURL = URL(string: "https://oauth2.googleapis.com/token")!
    private static let loadCodeAssistURL = URL(
        string: "https://daily-cloudcode-pa.googleapis.com/v1internal:loadCodeAssist"
    )!
    private static let quotaSummaryURL = URL(
        string: "https://daily-cloudcode-pa.googleapis.com/v1internal:retrieveUserQuotaSummary"
    )!

    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func fetchSnapshot(credentials: ProviderCredential?) async throws -> QuotaSnapshot {
        try await fetchSnapshot(credentials: credentials, userInitiated: false)
    }

    public func fetchSnapshot(
        credentials: ProviderCredential?,
        userInitiated: Bool
    ) async throws -> QuotaSnapshot {
        let taskWraithEvents = AGBenchUsageReader.loadEvents(forProviderKey: "antigravity")
        var observation = await AntigravityUsageCache.shared.cachedObservation()
        var fetchError: Error?

        if await AntigravityUsageCache.shared.beginFetch(userInitiated: userInitiated) {
            guard let access = AntigravitySessionAccess.resolve(credentials: credentials) else {
                throw ProviderFetchError.notConfigured
            }
            defer { access.stop() }

            do {
                let fetched = try await fetchObservation(tokenFileURL: access.tokenFileURL)
                await AntigravityUsageCache.shared.store(fetched)
                observation = fetched
            } catch {
                fetchError = error
            }
        }

        if let observation {
            return QuotaSnapshot(
                providerID: .antigravity,
                displayName: ProviderID.antigravity.snapshotDisplayName,
                planName: observation.planName,
                windows: observation.windows,
                events: taskWraithEvents,
                fetchState: .success,
                fetchedAt: Date()
            )
        }

        if let providerError = fetchError as? ProviderFetchError {
            throw providerError
        }
        if let fetchError {
            throw ProviderFetchError.networkError(underlying: fetchError)
        }
        throw ProviderFetchError.notConfigured
    }

    private func fetchObservation(tokenFileURL: URL) async throws -> AntigravityUsageObservation {
        let values = try tokenFileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true,
              let fileSize = values.fileSize,
              fileSize > 0,
              fileSize <= 1_048_576 else {
            throw ProviderFetchError.invalidCredential
        }

        let tokenData = try Data(contentsOf: tokenFileURL, options: .mappedIfSafe)
        let oauthSession: AntigravityOAuthSession
        do {
            oauthSession = try AntigravityOAuthSessionParser.parse(tokenData)
        } catch let providerError as ProviderFetchError {
            throw providerError
        } catch {
            throw ProviderFetchError.parsingError("Antigravity CLI session has an unexpected format.")
        }

        let accessToken = try await usableAccessToken(from: oauthSession)
        let metadata = try await loadCodeAssist(accessToken: accessToken)
        guard let project = metadata.cloudaicompanionProject?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty else {
            throw ProviderFetchError.parsingError("Antigravity did not return a quota project.")
        }

        let summaryData = try await postJSON(
            to: Self.quotaSummaryURL,
            accessToken: accessToken,
            body: ["project": project]
        )
        guard let observation = try AntigravityQuotaSummaryParser.parse(
            summaryData,
            planName: metadata.planName
        ) else {
            throw ProviderFetchError.parsingError("Gemini 5-hour and weekly quota buckets were not present.")
        }
        return observation
    }

    private func usableAccessToken(from oauthSession: AntigravityOAuthSession) async throws -> String {
        if let expiry = oauthSession.expiry,
           expiry.timeIntervalSinceNow > 5 * 60 {
            return oauthSession.accessToken
        }

        guard let refreshToken = oauthSession.refreshToken else {
            throw ProviderFetchError.credentialExpired(
                "The Antigravity CLI session expired. Sign in with agy again, then refresh Limit Counter."
            )
        }

        var request = URLRequest(url: Self.tokenURL, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var form = URLComponents()
        form.queryItems = [
            URLQueryItem(name: "client_id", value: Self.clientID),
            URLQueryItem(name: "client_secret", value: Self.clientSecret),
            URLQueryItem(name: "grant_type", value: "refresh_token"),
            URLQueryItem(name: "refresh_token", value: refreshToken)
        ]
        request.httpBody = form.percentEncodedQuery?.data(using: .utf8)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw ProviderFetchError.networkError(underlying: error)
        }

        guard let http = response as? HTTPURLResponse else {
            throw ProviderFetchError.unknown
        }
        guard http.statusCode == 200 else {
            if http.statusCode == 400 || http.statusCode == 401 {
                throw ProviderFetchError.credentialExpired(
                    "The Antigravity CLI session could not be refreshed. Sign in with agy again."
                )
            }
            if http.statusCode == 429 { throw ProviderFetchError.rateLimited }
            throw ProviderFetchError.parsingError("Antigravity OAuth returned HTTP \(http.statusCode).")
        }

        struct RefreshResponse: Decodable {
            let accessToken: String

            private enum CodingKeys: String, CodingKey {
                case accessToken = "access_token"
            }
        }

        guard let token = try? JSONDecoder().decode(RefreshResponse.self, from: data).accessToken,
              let normalized = token.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty else {
            throw ProviderFetchError.parsingError("Antigravity OAuth response omitted an access token.")
        }
        return normalized
    }

    private func loadCodeAssist(accessToken: String) async throws -> AntigravityCodeAssistMetadata {
        let data = try await postJSON(
            to: Self.loadCodeAssistURL,
            accessToken: accessToken,
            body: ["metadata": ["ideType": "ANTIGRAVITY"]]
        )
        do {
            return try JSONDecoder().decode(AntigravityCodeAssistMetadata.self, from: data)
        } catch {
            throw ProviderFetchError.parsingError("Antigravity account metadata had an unexpected format.")
        }
    }

    private func postJSON(
        to url: URL,
        accessToken: String,
        body: [String: Any]
    ) async throws -> Data {
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw ProviderFetchError.networkError(underlying: error)
        }

        guard let http = response as? HTTPURLResponse else {
            throw ProviderFetchError.unknown
        }
        switch http.statusCode {
        case 200:
            return data
        case 401, 403:
            throw ProviderFetchError.invalidCredential
        case 429:
            throw ProviderFetchError.rateLimited
        default:
            throw ProviderFetchError.parsingError("Antigravity quota service returned HTTP \(http.statusCode).")
        }
    }
}

private struct AntigravityCodeAssistMetadata: Decodable {
    struct Tier: Decodable {
        let name: String?
    }

    let cloudaicompanionProject: String?
    let currentTier: Tier?
    let paidTier: Tier?

    var planName: String? {
        paidTier?.name?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            ?? currentTier?.name?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }
}

#if os(macOS)
private struct AntigravitySessionAccess {
    static let tokenFileName = "antigravity-oauth-token"

    let tokenFileURL: URL
    let stop: () -> Void

    static func resolve(credentials: ProviderCredential?) -> AntigravitySessionAccess? {
        guard let bookmark = bookmarkData(from: credentials) else { return nil }
        var stale = false
        guard let selectedURL = try? URL(
            resolvingBookmarkData: bookmark,
            options: .withSecurityScope,
            bookmarkDataIsStale: &stale
        ) else { return nil }

        if stale {
            print("[AntigravityUsage] CLI session bookmark is stale; re-grant data-folder access.")
        }

        let didStart = selectedURL.startAccessingSecurityScopedResource()
        let rootURL = normalizedRoot(from: selectedURL)
        let tokenFileURL = rootURL.appendingPathComponent(tokenFileName)
        guard FileManager.default.fileExists(atPath: tokenFileURL.path) else {
            if didStart { selectedURL.stopAccessingSecurityScopedResource() }
            return nil
        }

        return AntigravitySessionAccess(tokenFileURL: tokenFileURL) {
            if didStart { selectedURL.stopAccessingSecurityScopedResource() }
        }
    }

    private static func bookmarkData(from credentials: ProviderCredential?) -> Data? {
        if let value = credentials?.bookmarkData { return value }
        return credentials?.extraFields?["bookmarkData"].flatMap { Data(base64Encoded: $0) }
    }

    private static func normalizedRoot(from selectedURL: URL) -> URL {
        switch selectedURL.lastPathComponent {
        case tokenFileName:
            return selectedURL.deletingLastPathComponent()
        case ".gemini":
            return selectedURL.appendingPathComponent("antigravity-cli", isDirectory: true)
        default:
            return selectedURL
        }
    }
}
#else
private struct AntigravitySessionAccess {
    static func resolve(credentials: ProviderCredential?) -> AntigravitySessionAccess? { nil }
    let tokenFileURL = URL(fileURLWithPath: "/dev/null")
    let stop: () -> Void = {}
}
#endif

private extension String {
    nonisolated var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
