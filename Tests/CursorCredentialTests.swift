import Foundation
import SQLite3

enum CursorTestFailure: Error, CustomStringConvertible {
    case failed(String)

    var description: String {
        switch self {
        case .failed(let message):
            return message
        }
    }
}

func cursorExpect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() {
        throw CursorTestFailure.failed(message)
    }
}

func cursorExpectEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: String) throws {
    if actual != expected {
        throw CursorTestFailure.failed("\(message): expected \(expected), got \(actual)")
    }
}

@main
enum CursorCredentialTestRunner {
    static func main() async throws {
        try testImportsCursorStateDirectory()
        try testImportsCursorStateFile()
        try await testCursorProviderReadsDirectoryState()
        try await testCursorProviderNormalizesProPlusPlan()
        try await testUnifiedXSubscriptionHasOneWeeklyPool()
        try await testCursorKeepsLegacyMonthlyAndBotWeeklyMeters()
        try await testUnifiedCursorDirectsSharedAllowanceToX()
        try await testXRejectsLegacyAndMissingMeasurements()
        try testXImportsTheSelectedCursorAccount()
        print("Cursor credential tests passed")
    }

    private static func dashboardClient(
        provider: ProviderID,
        usage: [String: Any],
        plan: [String: Any]?,
        bot: [String: Any]?,
        cookie: Bool = false
    ) async throws -> QuotaSnapshot {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        // If the client accidentally follows ambient/local auth instead of the
        // explicit session, this fixture sends the wrong token to the mock.
        let dbURL = directory.appendingPathComponent("state.vscdb")
        try createCursorStateDatabase(at: dbURL, membershipType: "wrong-local-account")
        var db: OpaquePointer?
        try cursorExpectEqual(sqlite3_open(dbURL.path, &db), SQLITE_OK, "fixture database opens")
        if let db {
            try insert(key: "cursorAuth/accessToken", value: "wrong-local-token", db: db)
            sqlite3_close(db)
        }
        CursorDashboardMockURLProtocol.handler = { request in
            try cursorExpectEqual(request.url?.host, "api2.cursor.sh", "Dashboard calls stay on Cursor's service")
            try cursorExpectEqual(request.httpMethod, "POST", "Dashboard reads use Connect RPC")
            try cursorExpectEqual(request.value(forHTTPHeaderField: "Connect-Protocol-Version"), "1", "Connect protocol")
            if cookie {
                try cursorExpectEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-dashboard-token", "Unwraps this account's web session for Connect RPC")
                try cursorExpect(request.value(forHTTPHeaderField: "Cookie") == nil, "Unrelated browser cookies are not forwarded")
            } else {
                try cursorExpectEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-dashboard-token", "Explicit account wins over local token")
            }
            let body: [String: Any]?
            switch request.url?.lastPathComponent {
            case "GetCurrentPeriodUsage": body = usage
            case "GetPlanInfo": body = plan
            case "GetSandUsageStatus": body = bot
            default: throw CursorTestFailure.failed("Unexpected dashboard method")
            }
            let response = HTTPURLResponse(url: request.url!, statusCode: body == nil ? 404 : 200, httpVersion: nil, headerFields: nil)!
            return (response, try JSONSerialization.data(withJSONObject: body ?? [:]))
        }
        defer { CursorDashboardMockURLProtocol.handler = nil }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CursorDashboardMockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let credential = ProviderCredential(
            accessToken: cookie ? nil : "fixture-dashboard-token",
            customEndpoint: directory.path,
            extraFields: cookie
                ? ["cursorAuthMode": "cookie", "cursorCookieHeader": "theme=dark; WorkosCursorSessionToken=fixture-user%3A%3Afixture-dashboard-token"]
                : ["cursorAuthMode": "bearer"]
        )
        if provider == .x {
            return try await XSubscriptionProviderClient(session: session).fetchSnapshot(credentials: credential)
        }
        return try await CursorProviderClient(session: session).fetchSnapshot(credentials: credential)
    }

    private static func testUnifiedXSubscriptionHasOneWeeklyPool() async throws {
        let weeklyReset = Date().addingTimeInterval(7 * 24 * 60 * 60)
        let monthlyReset = Date().addingTimeInterval(30 * 24 * 60 * 60)
        let snapshot = try await dashboardClient(
            provider: .x,
            usage: ["billingCycleEnd": monthlyReset.timeIntervalSince1970 * 1000,
                    "planUsage": ["includedSpend": 250, "limit": 1000,
                                  "totalPercentUsed": 0, "autoPercentUsed": 0, "apiPercentUsed": 0],
                    "spendLimitUsage": ["individualLimit": 2000, "individualRemaining": 1500]],
            plan: ["isMerged": true, "planInfo": ["planName": "Premium",
                   "includedUsagePeriod": "INCLUDED_USAGE_PERIOD_WEEKLY",
                   "includedUsageResetsAt": String(weeklyReset.timeIntervalSince1970 * 1000)]],
            bot: ["isUnified": true, "usagePercent": 25,
                  "nextResetTimestampUtc": ISO8601DateFormatter().string(from: weeklyReset)],
            cookie: true
        )
        try cursorExpectEqual(snapshot.providerID, .x, "The shared subscription has its own provider")
        try cursorExpect(snapshot.events.isEmpty, "The shared allowance does not duplicate Cursor's activity history")
        try cursorExpect(snapshot.stats.isEmpty, "Cursor activity stats stay on the Cursor card")
        try cursorExpectEqual(snapshot.planName, "Premium", "Plan info overrides stale local membership")
        try cursorExpectEqual(snapshot.windows.map(\.label), ["Shared Weekly"], "Shared pool is never split or duplicated")
        try cursorExpectEqual(snapshot.windows.first?.windowKind, .weekly, "Included usage is weekly")
        try cursorExpectEqual(snapshot.windows.first?.used, 25, "Uses measured included spend rather than stale CLI zeros")
        try cursorExpect(abs((snapshot.windows.first?.resetDate ?? .distantPast).timeIntervalSince(weeklyReset)) < 0.01,
                         "Uses the included-usage reset rather than monthly billing")
        try cursorExpectEqual(snapshot.balances.first?.amount, 15, "Spend-limit cents convert to dollars")
        try cursorExpect(abs((snapshot.balances.first?.resetDate ?? .distantPast).timeIntervalSince(monthlyReset)) < 0.01,
                         "Additional usage cap keeps the monthly reset after timestamp conversion")

        let newAccount = try await dashboardClient(
            provider: .x, usage: ["planUsage": ["totalPercentUsed": 27]],
            plan: ["isMerged": false, "planInfo": ["planName": "Premium", "includedUsagePeriod": 2]], bot: nil
        )
        try cursorExpectEqual(newAccount.windows.first?.windowKind, .weekly, "New weekly accounts do not need a historical account merge")
        try cursorExpectEqual(newAccount.windows.first?.used, 27, "New weekly accounts retain their measured usage")
    }

    private static func testCursorKeepsLegacyMonthlyAndBotWeeklyMeters() async throws {
        let snapshot = try await dashboardClient(
            provider: .cursor,
            usage: ["planUsage": ["totalPercentUsed": 35, "autoPercentUsed": 20, "apiPercentUsed": 15]],
            plan: ["isMerged": false, "planInfo": ["planName": "pro_plus", "includedUsagePeriod": 1]],
            bot: ["isUnified": false, "usagePercent": 62,
                  "nextResetTimestampUtc": ["seconds": String(Int(Date().addingTimeInterval(3600).timeIntervalSince1970))]]
        )
        try cursorExpectEqual(snapshot.planName, "Pro +", "Legacy plan name survives")
        try cursorExpectEqual(snapshot.windows.map(\.windowKind), [.monthly, .monthly, .monthly, .weekly], "Legacy monthly and Bot weekly stay independent")
        try cursorExpectEqual(snapshot.windows.last?.label, "Grok Bot Weekly", "The Bot meter is clearly identified")
        try cursorExpectEqual(snapshot.windows.last?.used, 62, "Bot consumption is not the Cursor monthly percentage")
        try cursorExpect(snapshot.windows.last?.resetDate != nil, "Accepts protobuf timestamp objects")

        let withoutBot = try await dashboardClient(
            provider: .cursor, usage: ["planUsage": ["totalPercentUsed": 12]], plan: nil, bot: nil
        )
        try cursorExpectEqual(withoutBot.windows.count, 1, "Old endpoint support survives unavailable auxiliary methods")
        try cursorExpectEqual(withoutBot.windows.first?.used, 12, "Legacy data is preserved")
    }

    private static func testUnifiedCursorDirectsSharedAllowanceToX() async throws {
        let snapshot = try await dashboardClient(
            provider: .cursor, usage: ["planUsage": ["totalPercentUsed": 42]],
            plan: ["isMerged": true, "planInfo": ["planName": "Premium", "includedUsagePeriod": 2]],
            bot: ["isUnified": true, "usagePercent": 42]
        )
        try cursorExpect(snapshot.windows.isEmpty, "The Cursor card does not duplicate the unified pool")
        try cursorExpect(snapshot.signals.contains { $0.title == "Shared allowance is under X" }, "Explains where to connect the shared meter")
    }

    private static func testXRejectsLegacyAndMissingMeasurements() async throws {
        for (plan, bot) in [
            (["isMerged": false, "planInfo": ["planName": "Premium"]] as [String: Any], ["usagePercent": 5] as [String: Any]),
            (["isMerged": true] as [String: Any], ["isUnified": true] as [String: Any]),
            (["isMerged": true] as [String: Any], ["isUnified": true, "usagePercent": -1] as [String: Any]),
            (["isMerged": true] as [String: Any], ["isUnified": true, "usagePercent": 0, "includedLimitZero": true] as [String: Any])
        ] {
            do {
                _ = try await dashboardClient(provider: .x, usage: [:], plan: plan, bot: bot)
                throw CursorTestFailure.failed("X fabricated a shared quota without a unified measured reading")
            } catch ProviderFetchError.parsingError {}
        }
        let measuredZero = try await dashboardClient(
            provider: .x, usage: [:], plan: nil,
            bot: ["isUnified": true, "usagePercent": 0, "nextResetTimestampUtc": "2027-01-01T00:00:00Z"]
        )
        try cursorExpectEqual(measuredZero.windows.first?.used, 0, "An explicitly observed zero remains valid")
    }

    private static func testXImportsTheSelectedCursorAccount() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        FileManager.default.createFile(atPath: directory.appendingPathComponent("state.vscdb").path, contents: Data())
        let imported = try CredentialImportService.importFromURL(directory, for: .x)
        try cursorExpectEqual(imported.customEndpoint, directory.appendingPathComponent("state.vscdb").path, "X follows the selected Cursor account")
        try cursorExpectEqual(imported.extraFields?["cursorAuthMode"], "localState", "X supports the existing folder import")
        try cursorExpectEqual(ProviderID.x.bundledLogoAssetName, "ProviderXLogo", "X uses its own PNG asset")
    }

    private static func testImportsCursorStateDirectory() throws {
        let directory = try temporaryDirectory()
        let stateDB = directory.appendingPathComponent("state.vscdb")
        FileManager.default.createFile(atPath: stateDB.path, contents: Data())

        let imported = try CredentialImportService.importFromURL(directory, for: .cursor)

        try cursorExpectEqual(imported.customEndpoint, stateDB.path, "directory import endpoint")
        try cursorExpectEqual(imported.extraFields?["cursorAuthMode"], "localState", "directory auth mode")
        try cursorExpectEqual(imported.extraFields?["cursorLocalStateSource"], "directory", "directory source")
    }

    private static func testImportsCursorStateFile() throws {
        let directory = try temporaryDirectory()
        let stateDB = directory.appendingPathComponent("state.vscdb")
        FileManager.default.createFile(atPath: stateDB.path, contents: Data())

        let imported = try CredentialImportService.importFromURL(stateDB, for: .cursor)

        try cursorExpectEqual(imported.customEndpoint, stateDB.path, "file import endpoint")
        try cursorExpectEqual(imported.extraFields?["cursorAuthMode"], "localState", "file auth mode")
        try cursorExpectEqual(imported.extraFields?["cursorLocalStateSource"], "file", "file source")
    }

    private static func testCursorProviderReadsDirectoryState() async throws {
        let directory = try temporaryDirectory()
        let stateDB = directory.appendingPathComponent("state.vscdb")
        try createCursorStateDatabase(at: stateDB)

        let credential = ProviderCredential(
            customEndpoint: directory.path,
            extraFields: [
                "cursorAuthMode": "localState"
            ]
        )

        let snapshot = try await CursorProviderClient().fetchSnapshot(credentials: credential)

        try cursorExpectEqual(snapshot.providerID, .cursor, "provider")
        try cursorExpectEqual(snapshot.planName, "Pro", "local membership plan")
        try cursorExpect(snapshot.stats.contains { $0.label == "Tracked AI Days" && $0.value == 1 }, "tracked day stat")
        try cursorExpectEqual(snapshot.events.count, 1, "local daily activity events")
    }

    private static func testCursorProviderNormalizesProPlusPlan() async throws {
        let directory = try temporaryDirectory()
        let stateDB = directory.appendingPathComponent("state.vscdb")
        try createCursorStateDatabase(at: stateDB, membershipType: "pro_plus")

        let credential = ProviderCredential(
            customEndpoint: directory.path,
            extraFields: [
                "cursorAuthMode": "localState"
            ]
        )

        let snapshot = try await CursorProviderClient().fetchSnapshot(credentials: credential)

        try cursorExpectEqual(snapshot.planName, "Pro +", "Pro Plus membership plan")
    }

    private static func createCursorStateDatabase(
        at url: URL,
        membershipType: String = "pro"
    ) throws {
        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK, let db else {
            throw CursorTestFailure.failed("could not create sqlite database")
        }
        defer { sqlite3_close(db) }

        let trackedDate = recentCursorDailyStatDateString()

        try exec("CREATE TABLE ItemTable (key TEXT PRIMARY KEY, value TEXT);", db: db)
        try insert(key: "cursorAuth/cachedEmail", value: "cursor@example.com", db: db)
        try insert(key: "cursorAuth/cachedMembershipType", value: membershipType, db: db)
        try insert(
            key: "aiCodeTracking.dailyStats.\(trackedDate)",
            value: """
            {"date":"\(trackedDate)","tabSuggestedLines":7,"tabAcceptedLines":3,"composerSuggestedLines":11,"composerAcceptedLines":5}
            """,
            db: db
        )
    }

    private static func recentCursorDailyStatDateString() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date())
    }

    private static func insert(key: String, value: String, db: OpaquePointer) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "INSERT INTO ItemTable (key, value) VALUES (?, ?);", -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw CursorTestFailure.failed("could not prepare insert")
        }
        defer { sqlite3_finalize(statement) }

        let transientDestructor = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(statement, 1, key, -1, transientDestructor)
        sqlite3_bind_text(statement, 2, value, -1, transientDestructor)

        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw CursorTestFailure.failed("could not insert \(key)")
        }
    }

    private static func exec(_ sql: String, db: OpaquePointer) throws {
        var errorMessage: UnsafeMutablePointer<CChar>?
        defer {
            if let errorMessage {
                sqlite3_free(errorMessage)
            }
        }

        guard sqlite3_exec(db, sql, nil, nil, &errorMessage) == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) } ?? "unknown sqlite error"
            throw CursorTestFailure.failed(message)
        }
    }

    private static func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}

private final class CursorDashboardMockURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            guard let handler = Self.handler else { throw URLError(.unsupportedURL) }
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
