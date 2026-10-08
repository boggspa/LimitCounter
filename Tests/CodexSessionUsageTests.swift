import Foundation

private enum CodexSessionUsageTestError: Error, CustomStringConvertible {
    case failure(String)

    var description: String {
        switch self {
        case .failure(let message): return message
        }
    }
}

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw CodexSessionUsageTestError.failure(message) }
}

private func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: String) throws {
    if actual != expected {
        throw CodexSessionUsageTestError.failure("\(message): expected \(expected), got \(actual)")
    }
}

private func fixture(planType: String, additionalRateLimits: String = "") -> Data {
    """
    {
      "plan_type": "\(planType)",
      "rate_limit": {
        "primary_window": {
          "used_percent": 42,
          "limit_window_seconds": 18000,
          "reset_after_seconds": 10400,
          "reset_at": 4102444800
        },
        "secondary_window": {
          "used_percent": 64,
          "limit_window_seconds": 604800,
          "reset_after_seconds": 340000,
          "reset_at": 4102444800
        }
      }\(additionalRateLimits)
    }
    """.data(using: .utf8)!
}

private let lunaReserveAdditionalRateLimit = """
,
"additional_rate_limits": [
  {
    "limit_name": "gpt-reserve",
    "rate_limit": {
      "primary_window": {
        "used_percent": 0,
        "limit_window_seconds": 604800,
        "reset_after_seconds": 604800,
        "reset_at": 4102444800
      }
    }
  }
]
"""

private let sparkAdditionalRateLimit = """
,
"additional_rate_limits": [
  {
    "limit_name": "GPT-5.3-Codex-Spark",
    "rate_limit": {
      "primary_window": {
        "used_percent": 0,
        "limit_window_seconds": 18000,
        "reset_after_seconds": 10400,
        "reset_at": 4102444800
      },
      "secondary_window": {
        "used_percent": 97,
        "limit_window_seconds": 604800,
        "reset_after_seconds": 340000,
        "reset_at": 4102444800
      }
    }
  }
]
"""

private final class CodexMockURLProtocol: URLProtocol {
    static var responseData: Data?
    /// Bearer tokens sent to the usage endpoint, in order.
    static var usageTokens: [String] = []
    /// The organisation costs page, when a test stores an admin key; a
    /// request without one is answered 401 like OpenAI would.
    static var costsResponseData: Data?
    static var costsRequests: [URLRequest] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        if request.url?.path.hasSuffix("/organization/costs") == true {
            Self.costsRequests.append(request)
            let status = Self.costsResponseData == nil ? 401 : 200
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Self.costsResponseData ?? Data())
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        if request.url?.path.hasSuffix("/wham/usage") == true,
           let authorization = request.value(forHTTPHeaderField: "Authorization") {
            Self.usageTokens.append(String(authorization.dropFirst("Bearer ".count)))
        }
        guard let responseData = Self.responseData else {
            client?.urlProtocol(self, didFailWithError: CodexSessionUsageTestError.failure("missing fixture"))
            return
        }
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: responseData)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private func fetch(planType: String, additionalRateLimits: String = "") async throws -> QuotaSnapshot {
    CodexMockURLProtocol.responseData = fixture(
        planType: planType,
        additionalRateLimits: additionalRateLimits
    )
    defer { CodexMockURLProtocol.responseData = nil }

    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [CodexMockURLProtocol.self]
    return try await CodexSessionProviderClient(session: URLSession(configuration: configuration))
        .fetchSnapshot(credentials: ProviderCredential(accessToken: "test-token", accountIdentifier: "test-account"))
}

private func testPlusRendersFiveHourThenWeekly() async throws {
    let snapshot = try await fetch(planType: "plus")

    try expectEqual(snapshot.windows.map(\.label), ["5H", "Weekly"], "Plus window order")
    try expectEqual(snapshot.windows[0].windowKind, .session, "Plus 5H window kind")
    try expectEqual(snapshot.windows[0].percentageUsed, 42, "Plus 5H usage")
    try expectEqual(snapshot.windows[1].windowKind, .weekly, "Plus weekly window kind")
}

private func testProOmitsFiveHourAndKeepsWeekly() async throws {
    let snapshot = try await fetch(planType: "pro")

    try expectEqual(snapshot.windows.map(\.label), ["Weekly"], "Pro should not render a 5H window")
    try expectEqual(snapshot.windows[0].percentageUsed, 64, "Pro weekly usage")
}

private func testProLiteOmitsFiveHourAndNamesThePlan() async throws {
    // Pro Lite, like Pro, has no 5-hour allowance; only Plus and below do.
    let snapshot = try await fetch(planType: "prolite")

    try expectEqual(snapshot.windows.map(\.label), ["Weekly"], "Pro Lite should not render a 5H window")
    try expectEqual(snapshot.windows[0].percentageUsed, 64, "Pro Lite weekly usage")
    try expectEqual(snapshot.planName, "Pro Lite", "Pro Lite is named as two words, not \"Prolite\"")
}

private func testLunaReserveRendersFriendlyWeeklyAllowance() async throws {
    let snapshot = try await fetch(
        planType: "pro",
        additionalRateLimits: lunaReserveAdditionalRateLimit
    )

    try expectEqual(
        snapshot.windows.map(\.label),
        ["Weekly", "🌙 Luna Reserve Weekly"],
        "Luna Reserve window label"
    )
    try expectEqual(snapshot.windows[1].windowKind, .weekly, "Luna Reserve window kind")
    try expectEqual(snapshot.windows[1].percentageUsed, 0, "Luna Reserve usage")
    try expectEqual(
        snapshot.windows[1].subtitle,
        "Separate 7-day Luna Reserve allowance",
        "Luna Reserve window subtitle"
    )
}

private func testSparkRendersFriendlyWindowLabels() async throws {
    let snapshot = try await fetch(
        planType: "pro",
        additionalRateLimits: sparkAdditionalRateLimit
    )

    try expectEqual(
        snapshot.windows.map(\.label),
        ["Weekly", "⚡ Spark 5H", "⚡ Spark Weekly"],
        "Spark window labels"
    )
    try expectEqual(snapshot.windows[1].windowKind, .session, "Spark 5H window kind")
    try expectEqual(snapshot.windows[2].windowKind, .weekly, "Spark weekly window kind")
}

/// The two endpoints behind the Codex app's "Usage limit resets" panel, as
/// observed live on 2026-09-16 (with a credit added to the otherwise empty
/// list).
private func testResetCreditParsersReadDetailsAndHistory() throws {
    let details = """
    {
      "credits": [
        {
          "id": "RateLimitResetCredit_bb6b",
          "reset_type": "weekly",
          "status": "available",
          "granted_at": "2026-09-05T04:20:07.256813Z",
          "expires_at": "2026-09-05T12:20:07Z",
          "title": "Usage limit reset",
          "description": null
        }
      ],
      "available_count": 1,
      "total_earned_count": 3,
      "immediate_reset_purchase_eligible": false,
      "history_enabled": true
    }
    """.data(using: .utf8)!
    let parsed = try CodexResetCreditsParser.parseDetails(details)
    try expectEqual(parsed.availableCount, 1, "available count")
    try expectEqual(parsed.earnedCount, 3, "earned count")
    try expectEqual(parsed.credits.count, 1, "credit list")
    let credit = parsed.credits[0]
    try expectEqual(credit.id, "RateLimitResetCredit_bb6b", "credit id")
    try expect(credit.isAvailable, "status available")
    try expectEqual(credit.grantedAt, CodexResetCreditsParser.parseDate("2026-09-05T04:20:07.256813Z"), "granted date with fractional seconds")
    try expectEqual(credit.expiresAt, Date(timeIntervalSince1970: 1_788_610_807), "expiry date")
    try expectEqual(credit.note, "weekly", "reset type kept as the note when there is no description")

    let history = """
    {
      "events": [
        {"id": "RateLimitResetCredit_bb6b:used", "kind": "used", "occurred_at": "2026-09-05T11:11:31.367474Z"},
        {"id": "RateLimitResetCredit_bb6b:granted", "kind": "granted", "occurred_at": "2026-09-05T04:20:07.256813Z"},
        {"id": "RateLimitResetCredit_zzzz:unknown", "kind": "mystery", "occurred_at": "2026-09-05T04:20:07Z"}
      ],
      "window_start": "2026-08-17T04:14:39.218092Z",
      "as_of": "2026-09-16T04:14:39.218092Z",
      "next_cursor": null
    }
    """.data(using: .utf8)!
    let events = try CodexResetCreditsParser.parseHistory(history)
    try expectEqual(events.map(\.kind), [.used, .granted], "known kinds, newest first, unknown dropped")
    try expectEqual(events.first?.id, "RateLimitResetCredit_bb6b:used", "event id")

    let summary = QuotaResetCreditSummary(
        availableCount: parsed.availableCount,
        earnedCount: parsed.earnedCount,
        credits: parsed.credits,
        history: events,
        redeemHint: CodexResetCreditsFetcher.redeemHint,
        observedAt: Date(timeIntervalSince1970: 1_788_600_000)
    )
    try expectEqual(summary.nearestExpiry, credit.expiresAt, "nearest expiry")
    try expectEqual(
        summary.statusLine(at: Date(timeIntervalSince1970: 1_788_600_000)),
        "1 reset banked · expires in 3h",
        "status line"
    )

    let empty = try CodexResetCreditsParser.parseDetails(
        #"{"credits": [], "available_count": 0, "total_earned_count": 0, "history_enabled": true}"#.data(using: .utf8)!
    )
    try expectEqual(empty.availableCount, 0, "empty list")
    try expect(empty.credits.isEmpty, "no credits")
}

private func testResetCreditCacheIsFiledPerAccount() throws {
    // Two Codex accounts refresh through the same fetcher; one shared entry
    // let the second show the first's banked credits, then overwrite them.
    let personal = CodexResetCreditsFetcher.cacheKey(forAccountID: "acct-personal")
    let work = CodexResetCreditsFetcher.cacheKey(forAccountID: "acct-work")
    try expect(personal != work, "each ChatGPT account files its own reset-credit summary")
    try expectEqual(personal, "codex.resetCredits.cache.v1.acct-personal", "the key extends the original one with the account id")
    try expectEqual(
        CodexResetCreditsFetcher.cacheKey(forAccountID: "acct-work"),
        work,
        "the same account finds its own summary again"
    )
}

private final class CodexResetCreditURLProtocol: URLProtocol {
    static var statusCode = 500
    static var details = Data(#"{"credits":[],"available_count":1}"#.utf8)

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let body = request.url?.path.hasSuffix("/history") == true
            ? Data(#"{"events":[]}"#.utf8) : Self.details
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.statusCode, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private func testUsageResetCountSurvivesSupplementalOutageAndRelaunch() async throws {
    let suite = "codex-reset-outage-tests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let previous = QuotaResetCreditSummary(availableCount: 1, observedAt: now.addingTimeInterval(-60))
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    defaults.set(try encoder.encode(previous), forKey: CodexResetCreditsFetcher.cacheKey(forAccountID: "test-account"))

    CodexResetCreditURLProtocol.statusCode = 500
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [CodexResetCreditURLProtocol.self]
    let session = URLSession(configuration: configuration)
    defer { session.invalidateAndCancel() }
    let fetcher = CodexResetCreditsFetcher(session: session, defaults: defaults)
    let redeemed = await fetcher.summary(usageCount: 0, accessToken: "fixture", accountID: "test-account", now: now)
    try expectEqual(redeemed?.availableCount, 0, "usage count reports redemption while supplemental endpoints fail")
    try expectEqual(redeemed?.observedAt, previous.observedAt, "failed supplemental reads do not postpone their refresh")

    let relaunched = CodexResetCreditsFetcher(session: session, defaults: defaults)
    let missingUsageCount = await relaunched.summary(usageCount: nil, accessToken: "fixture", accountID: "test-account", now: now.addingTimeInterval(5))
    try expectEqual(missingUsageCount?.availableCount, 0, "cached pre-redemption credit cannot reappear when the next count is omitted")
}

private func testCurrentUsageResetCountOverridesLaggingDetails() async throws {
    let suite = "codex-reset-count-tests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    CodexResetCreditURLProtocol.statusCode = 200
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [CodexResetCreditURLProtocol.self]
    let session = URLSession(configuration: configuration)
    defer { session.invalidateAndCancel() }
    let fetcher = CodexResetCreditsFetcher(session: session, defaults: defaults)
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    let redeemed = await fetcher.summary(usageCount: 0, accessToken: "fixture", accountID: "redeemed", now: now)
    try expectEqual(redeemed?.availableCount, 0, "lagging available details cannot override a current zero quota count")
    let granted = await fetcher.summary(usageCount: 2, accessToken: "fixture", accountID: "granted", now: now)
    try expectEqual(granted?.availableCount, 2, "current nonzero quota count takes precedence too")
    let detailsOnly = await fetcher.summary(usageCount: nil, accessToken: "fixture", accountID: "details-only", now: now)
    try expectEqual(detailsOnly?.availableCount, 1, "details remain a fallback when the quota surface omits counts")
}

// MARK: - Account identity

/// An unsigned token carrying the ChatGPT claims the client reads.
private func jwt(account: String, user: String, expiresAt: Date) -> String {
    func encode(_ object: [String: Any]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: object)
        return data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
    let claims: [String: Any] = [
        "exp": Int(expiresAt.timeIntervalSince1970),
        "https://api.openai.com/auth": [
            "chatgpt_account_id": account,
            "chatgpt_account_user_id": "\(user)__\(account)"
        ]
    ]
    return "\(encode(["alg": "none"])).\(encode(claims)).sig"
}

private final class PersistedCredentials: CodexCredentialSaving, @unchecked Sendable {
    var saved: [(ProviderCredential, ProviderAccountKey)] = []

    func save(_ credential: ProviderCredential, for account: ProviderAccountKey) {
        saved.append((credential, account))
    }
}

private struct CodexAccountHarness {
    let folder: URL
    let defaults: UserDefaults
    let persisted = PersistedCredentials()

    init() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-identity-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let suite = "codex-identity-tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
    }

    func signIn(_ token: String, account: String) throws {
        try """
        {"tokens":{"access_token":"\(token)","account_id":"\(account)"}}
        """.write(to: folder.appendingPathComponent("auth.json"), atomically: true, encoding: .utf8)
    }

    func stored(_ token: String, account: String) -> ProviderCredential {
        ProviderCredential(
            accessToken: token,
            accountIdentifier: account,
            customEndpoint: folder.path,
            extraFields: ["codexAuthSource": "directory"]
        )
    }

    func fetch(_ credential: ProviderCredential, as account: ProviderAccountKey = .primary(.openai)) async throws -> QuotaSnapshot {
        CodexMockURLProtocol.responseData = fixture(planType: "plus")
        defer { CodexMockURLProtocol.responseData = nil }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CodexMockURLProtocol.self]
        return try await CodexSessionProviderClient(
            session: URLSession(configuration: configuration),
            readingDefaults: defaults,
            credentialSaver: persisted
        ).fetchSnapshot(credentials: credential, account: account, userInitiated: false)
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: folder)
    }
}

private let signalTitle = "Codex folder signed in to another account"

private func testRotationOfTheSameAccountIsFollowedAndSaved() async throws {
    let harness = try CodexAccountHarness()
    defer { harness.cleanUp() }
    let later = Date().addingTimeInterval(10 * 86_400)
    let original = jwt(account: "acct-a", user: "user-a", expiresAt: later)
    let rotated = jwt(account: "acct-a", user: "user-a", expiresAt: later.addingTimeInterval(3_600))
    try harness.signIn(rotated, account: "acct-a")
    CodexMockURLProtocol.usageTokens = []

    let snapshot = try await harness.fetch(harness.stored(original, account: "acct-a"))

    try expectEqual(CodexMockURLProtocol.usageTokens, [rotated], "the folder's newer token is used")
    try expect(!snapshot.signals.contains { $0.title == signalTitle }, "no warning for the same account")
    try expectEqual(harness.persisted.saved.count, 1, "the rotated token is saved as the account's own")
    let saved = harness.persisted.saved[0].0
    try expectEqual(saved.accessToken, rotated, "saved token")
    try expectEqual(saved.extraFields?[CodexAccountPin.accountIDKey], "acct-a", "the pin is written")
    try expectEqual(saved.extraFields?[CodexAccountPin.accountUserIDKey], "user-a__acct-a", "the per-person pin is written")
}

private func testSwitchedFolderFallsBackToTheSavedSession() async throws {
    let harness = try CodexAccountHarness()
    defer { harness.cleanUp() }
    let later = Date().addingTimeInterval(10 * 86_400)
    let own = jwt(account: "acct-a", user: "user-a", expiresAt: later)
    try harness.signIn(jwt(account: "acct-b", user: "user-b", expiresAt: later), account: "acct-b")
    CodexMockURLProtocol.usageTokens = []

    let snapshot = try await harness.fetch(harness.stored(own, account: "acct-a"))

    try expectEqual(CodexMockURLProtocol.usageTokens, [own], "only the account's own token is sent")
    try expect(!snapshot.windows.isEmpty, "the account keeps live meters")
    try expect(snapshot.signals.contains { $0.title == signalTitle && $0.severity == .warning }, "the switch is reported")
    try expect(harness.persisted.saved.isEmpty, "the other account's token is never saved")
}

private func testTeamWorkspaceMembersAreDifferentAccounts() async throws {
    let harness = try CodexAccountHarness()
    defer { harness.cleanUp() }
    let later = Date().addingTimeInterval(10 * 86_400)
    let own = jwt(account: "acct-team", user: "user-a", expiresAt: later)
    try harness.signIn(jwt(account: "acct-team", user: "user-b", expiresAt: later), account: "acct-team")
    CodexMockURLProtocol.usageTokens = []

    let snapshot = try await harness.fetch(harness.stored(own, account: "acct-team"))

    try expectEqual(CodexMockURLProtocol.usageTokens, [own], "a colleague in the same workspace is someone else")
    try expect(snapshot.signals.contains { $0.title == signalTitle }, "the switch is reported")
}

private func testSwitchedFolderWithAnExpiredSessionShowsTheLastReading() async throws {
    let harness = try CodexAccountHarness()
    defer { harness.cleanUp() }
    let expired = Date().addingTimeInterval(-60)
    let own = jwt(account: "acct-a", user: "user-a", expiresAt: expired)
    try harness.signIn(own, account: "acct-a")
    let verifiedReading = try await harness.fetch(harness.stored(own, account: "acct-a"))

    try harness.signIn(jwt(account: "acct-b", user: "user-b", expiresAt: Date().addingTimeInterval(86_400)), account: "acct-b")
    CodexMockURLProtocol.usageTokens = []
    let standIn = try await harness.fetch(harness.stored(own, account: "acct-a"))

    try expect(CodexMockURLProtocol.usageTokens.isEmpty, "nothing is fetched with another account's token")
    try expectEqual(standIn.fetchedAt, verifiedReading.fetchedAt, "the stand-in is dated to its own reading")
    try expectEqual(standIn.windows.map(\.percentageUsed), verifiedReading.windows.map(\.percentageUsed), "the account's own meters")
    try expectEqual(standIn.signals.map(\.title), [signalTitle], "the switch is reported")
}

private func testSwitchedFolderWithNothingOfItsOwnThrows() async throws {
    let harness = try CodexAccountHarness()
    defer { harness.cleanUp() }
    let own = jwt(account: "acct-a", user: "user-a", expiresAt: Date().addingTimeInterval(-60))
    try harness.signIn(jwt(account: "acct-b", user: "user-b", expiresAt: Date().addingTimeInterval(86_400)), account: "acct-b")
    CodexMockURLProtocol.usageTokens = []

    do {
        _ = try await harness.fetch(harness.stored(own, account: "acct-a"))
        throw CodexSessionUsageTestError.failure("expected CodexAccountSwitchedError")
    } catch let error as CodexAccountSwitchedError {
        try expect(error.message.contains("codex login"), "the error says how to fix it")
    }
    try expect(CodexMockURLProtocol.usageTokens.isEmpty, "nothing is fetched with another account's token")
}

private func testStandInDropsWindowsThatHaveReset() throws {
    let defaults = UserDefaults(suiteName: "codex-standin-\(UUID().uuidString)")!
    let now = Date()
    let identity = CodexAccountIdentity(accountID: "acct-a", accountUserID: "user-a__acct-a")
    let reading = QuotaSnapshot(
        providerID: .openai,
        displayName: "Codex",
        windows: [
            QuotaWindow(label: "5H", windowKind: .session, used: 1, total: 5, resetDate: now.addingTimeInterval(-60), unit: "hrs"),
            QuotaWindow(label: "Weekly", windowKind: .weekly, used: 50, total: 168, resetDate: now.addingTimeInterval(86_400), unit: "hrs")
        ],
        fetchState: .success,
        fetchedAt: now.addingTimeInterval(-7_200)
    )
    let account = ProviderAccountKey.primary(.openai)
    CodexVerifiedReadingCache.save(reading, identity: identity, for: account, defaults: defaults)

    let standIn = CodexVerifiedReadingCache.standIn(for: account, pinned: identity, now: now, defaults: defaults)
    try expectEqual(standIn?.windows.map(\.label), ["Weekly"], "a window that has reset is not shown")

    let someoneElse = CodexAccountIdentity(accountID: "acct-b", accountUserID: nil)
    try expect(
        CodexVerifiedReadingCache.standIn(for: account, pinned: someoneElse, now: now, defaults: defaults) == nil,
        "a reading of a different account never stands in"
    )
}

private func testTwoAppAccountsReadingOneChatGPTAccountAreFlagged() async throws {
    let harness = try CodexAccountHarness()
    defer { harness.cleanUp() }
    let token = jwt(account: "acct-a", user: "user-a", expiresAt: Date().addingTimeInterval(86_400))
    try harness.signIn(token, account: "acct-a")

    let first = try await harness.fetch(harness.stored(token, account: "acct-a"))
    let second = try await harness.fetch(
        harness.stored(token, account: "acct-a"),
        as: ProviderAccountKey(providerID: .openai, slot: "work")
    )

    try expect(first.signals.isEmpty, "the first account has nothing to compare against yet")
    try expect(
        second.signals.contains { $0.title == "Same ChatGPT account as another Codex meter" },
        "the second account says it reads the same ChatGPT account"
    )
}

private func testFolderPathsAreShownFromHome() throws {
    try expectEqual(CodexSessionProviderClient.abbreviatedHomePath("/Users/someone/.codex"), "~/.codex", "home folder")
    try expectEqual(CodexSessionProviderClient.abbreviatedHomePath("/opt/codex"), "/opt/codex", "other folders unchanged")
}

private func testOpenAICostPageParsesDollarsAndFailsClosed() throws {
    let page = Data(#"{"object":"page","data":[{"object":"bucket","start_time":1759276800,"end_time":1759363200,"results":[{"object":"organization.costs.result","amount":{"value":3.25,"currency":"usd"},"line_item":null,"project_id":"proj_test"},{"object":"organization.costs.result","amount":{"value":"2.42","currency":"USD"},"line_item":"gpt-5","project_id":"proj_test"}]},{"object":"bucket","start_time":1759363200,"end_time":1759449600,"results":[]}],"has_more":true,"next_page":"page_xyz"}"#.utf8)
    let parsed = APIUsageCostReportParser.openAIPage(page)
    try expect(parsed != nil, "documented costs page parses")
    try expectEqual(parsed!.total, 5.67, "amount values are whole dollars and are summed")
    try expectEqual(parsed!.currency, "USD", "currency normalised to upper case")
    try expectEqual(parsed!.bucketCount, 2, "daily buckets counted")
    try expectEqual(parsed!.lineItemCount, 2, "line items counted")
    try expectEqual(parsed!.nextPage, "page_xyz", "pagination cursor read")
    try expectEqual(APIUsageCostReportParser.openAIPage(Data(#"{"data":[]}"#.utf8))?.total, 0, "an empty month is a real zero")
    for body in [
        #"{"data":[{"results":[{"amount":{"value":"abc","currency":"USD"}}]}]}"#,
        #"{"data":[{"results":[{"amount":{"value":1,"currency":"USD"}},{"amount":{"value":1,"currency":"EUR"}}]}]}"#,
        #"{"data":[{"results":[{"amount":"1.00"}]}]}"#,
        #"{"data":[{"results":[{"amount":{"value":true}}]}]}"#
    ] {
        try expect(APIUsageCostReportParser.openAIPage(Data(body.utf8)) == nil,
                   "an unreadable or mixed-currency amount withholds the whole page: \(body)")
    }

    let iso = ISO8601DateFormatter()
    iso.formatOptions = [.withInternetDateTime]
    let period = APIUsagePeriod.utcMonthToDate(now: iso.date(from: "2026-10-08T01:48:41Z")!)
    let request = APIUsageReportClient.openAIRequest(adminKey: "sk-admin-test", projectID: "proj_test", period: period)
    let components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
    try expectEqual(components.host, "api.openai.com", "documented host")
    try expectEqual(components.path, "/v1/organization/costs", "documented costs endpoint")
    let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
    try expectEqual(query["start_time"], String(Int(period.start.timeIntervalSince1970)), "unix start")
    try expectEqual(query["end_time"], String(Int(period.end.timeIntervalSince1970)), "unix end")
    try expectEqual(query["bucket_width"], "1d", "daily buckets")
    try expectEqual(query["limit"], "31", "a whole month per page")
    try expectEqual(query["project_ids"], "proj_test", "project scope forwarded")
    try expectEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer sk-admin-test", "admin key as bearer")
    try expect(request.httpMethod == "GET" && !request.httpShouldHandleCookies, "read-only, cookie-free request")
    let wholeOrg = APIUsageReportClient.openAIRequest(adminKey: "k", projectID: nil, period: period)
    try expect(wholeOrg.url!.query!.contains("project_ids") == false, "no project filter without a project id")
}

private func testCodexSnapshotCarriesTheOpenAIAPIBill() async throws {
    CodexMockURLProtocol.responseData = fixture(planType: "plus")
    CodexMockURLProtocol.costsResponseData = Data(#"{"object":"page","data":[{"object":"bucket","start_time":1759276800,"end_time":1759363200,"results":[{"object":"organization.costs.result","amount":{"value":3.25,"currency":"usd"},"line_item":null,"project_id":"proj_test"},{"object":"organization.costs.result","amount":{"value":2.42,"currency":"USD"},"line_item":"gpt-5","project_id":"proj_test"}]}],"has_more":false,"next_page":null}"#.utf8)
    defer {
        CodexMockURLProtocol.responseData = nil
        CodexMockURLProtocol.costsResponseData = nil
    }
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [CodexMockURLProtocol.self]
    let session = URLSession(configuration: configuration)
    let suite = "codex-api-usage-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let lane = APIUsageReportLane(client: APIUsageReportClient(session: session))
    let client = CodexSessionProviderClient(
        session: session,
        readingDefaults: defaults,
        credentialSaver: CodexSessionUsageNoopSaver(),
        apiUsageLane: lane
    )

    let before = CodexMockURLProtocol.costsRequests.count
    let plain = try await client.fetchSnapshot(credentials: ProviderCredential(accessToken: "test-token", accountIdentifier: "test-account"))
    try expect(plain.apiUsage == nil && plain.apiUsageCredits == nil, "no admin key, no API row")
    try expectEqual(CodexMockURLProtocol.costsRequests.count, before, "no admin key, no costs request")
    try expectEqual(plain.windows.count, 2, "the subscription meters are untouched")

    let keyed = ProviderCredential(
        accessToken: "test-token",
        accountIdentifier: "test-account",
        extraFields: [
            APIUsageCredentialField.openAIAdminKey: "sk-admin-test",
            APIUsageCredentialField.openAIProjectID: "proj_test"
        ]
    )
    let billed = try await client.fetchSnapshot(credentials: keyed)
    try expectEqual(billed.windows.count, 2, "the subscription meters still lead the card")
    try expectEqual(billed.apiUsage?.amount, 5.67, "month-to-date OpenAI costs attached")
    try expectEqual(billed.apiUsage?.currency, "USD", "currency carried through")
    try expectEqual(billed.apiUsage?.detail, "Month to date (UTC) · OpenAI costs, project proj_test", "subtitle names the scope")
    try expectEqual(billed.apiUsageCredits?.label, "Codex · OpenAI API", "files under Usage Credits as the organisation's bill")
    try expectEqual(billed.apiUsageCredits?.id, "usage-credits|openai|api-usage", "its own meter identity")
    try expectEqual(
        billed.usageCreditRows.map(\.id),
        [billed.usageCredits?.id, billed.apiUsageCredits?.id].compactMap { $0 },
        "the API row follows the account's own credits row (absent on a plan that reports no credits)"
    )
    try expect(billed.usageCreditRows.last?.id == billed.apiUsageCredits?.id, "the API row files under Usage Credits")
    try expectEqual(CodexMockURLProtocol.costsRequests.count, before + 1, "one costs request")
    let costsRequest = CodexMockURLProtocol.costsRequests.last!
    try expectEqual(costsRequest.value(forHTTPHeaderField: "Authorization"), "Bearer sk-admin-test", "admin key only on the costs request")
    try expect(costsRequest.url!.query!.contains("project_ids=proj_test"), "project scope applied")
    try expect(CodexMockURLProtocol.usageTokens.last == "test-token", "the ChatGPT session token never changes")

    CodexMockURLProtocol.costsResponseData = nil
    let rejectedLane = APIUsageReportLane(client: APIUsageReportClient(session: session))
    let rejected = try await CodexSessionProviderClient(
        session: session, readingDefaults: defaults, credentialSaver: CodexSessionUsageNoopSaver(), apiUsageLane: rejectedLane
    ).fetchSnapshot(credentials: keyed)
    try expectEqual(rejected.windows.count, 2, "a rejected admin key never hides the subscription meters")
    try expect(rejected.apiUsage?.amount == nil, "a rejected key reports no figure")
    try expect(rejected.apiUsageCredits?.unavailableReason?.contains("organisation admin key") == true, "the row says a project key cannot read costs")
}

private struct CodexSessionUsageNoopSaver: CodexCredentialSaving {
    @MainActor func save(_ credential: ProviderCredential, for account: ProviderAccountKey) {}
}

@main
private enum CodexSessionUsageTestRunner {
    static func main() async throws {
        try testOpenAICostPageParsesDollarsAndFailsClosed()
        try await testCodexSnapshotCarriesTheOpenAIAPIBill()
        try await testPlusRendersFiveHourThenWeekly()
        try await testProOmitsFiveHourAndKeepsWeekly()
        try await testProLiteOmitsFiveHourAndNamesThePlan()
        try await testLunaReserveRendersFriendlyWeeklyAllowance()
        try await testSparkRendersFriendlyWindowLabels()
        try testResetCreditParsersReadDetailsAndHistory()
        try testResetCreditCacheIsFiledPerAccount()
        try await testUsageResetCountSurvivesSupplementalOutageAndRelaunch()
        try await testCurrentUsageResetCountOverridesLaggingDetails()
        try await testRotationOfTheSameAccountIsFollowedAndSaved()
        try await testSwitchedFolderFallsBackToTheSavedSession()
        try await testTeamWorkspaceMembersAreDifferentAccounts()
        try await testSwitchedFolderWithAnExpiredSessionShowsTheLastReading()
        try await testSwitchedFolderWithNothingOfItsOwnThrows()
        try testStandInDropsWindowsThatHaveReset()
        try await testTwoAppAccountsReadingOneChatGPTAccountAreFlagged()
        try testFolderPathsAreShownFromHome()
        print("Codex session usage tests passed")
    }
}
