import Foundation

enum TestFailure: Error, CustomStringConvertible {
    case failed(String)

    var description: String {
        switch self {
        case .failed(let message):
            return message
        }
    }
}

func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() {
        throw TestFailure.failed(message)
    }
}

func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: String) throws {
    if actual != expected {
        throw TestFailure.failed("\(message): expected \(expected), got \(actual)")
    }
}

func expectClose(_ actual: Double?, _ expected: Double, _ message: String) throws {
    guard let actual, abs(actual - expected) < 0.000_001 else {
        throw TestFailure.failed("\(message): expected \(expected), got \(String(describing: actual))")
    }
}

func expectNil<T>(_ value: T?, _ message: String) throws {
    if let value {
        throw TestFailure.failed("\(message): expected nil, got \(value)")
    }
}

@main
enum KimiUsageTestRunner {
    static func main() async throws {
        try testParsesWeeklyAndFiveHourStringQuota()
        try testMapsCurrentAndLegacyMembershipLevels()
        try testParsesMissingOptionalFieldsAndUnknownMembership()
        try testParsesExhaustedWeeklyAndUnusedFiveHourQuota()
        try testParsesWebMonthlyMembershipQuota()
        try await testMergesWebMonthlyQuotaWithCodeWindows()
        try await testRefreshesAndPersistsWebSessionTokens()
        try await testPersistenceFailureStopsWebSessionRetry()
        try testImportsPlainTextAPIKey()
        try testImportsCLIOAuthJSONAsFileReference()
        try testImportsCLIOAuthDirectory()
        try await testMigratedCLIOAuthUsesCurrentKimiCodeFile()
        try await testBookmarkedLegacyOAuthRequiresCurrentFolderImport()
        try await testExpiredCLIOAuthRefreshesAndPersistsRotatedToken()
        try await testExternalRotationRecoversFromInvalidGrant()
        try await testRejectedRefreshThrowsCredentialExpired()
        try testParsesProPlanWithoutWeeklyWindow()
        try testParsesVivacePlanWithWeeklyWindow()
        try testEmptyUsagesFallBackToLegacyFields()
        try testReadsPlanNameFromUserInfo()
        try testDerivesCLICredentialSlots()
        try testReadsDeploymentFromCLIConfig()
        try testLocatesCurrentCLISignIn()
        try testImportsCLIFolderSignedInToGlobalDeployment()
        try await testGlobalSignInRefreshesWithItsOwnHostAndLock()
        try await testCodeMonthlyWinsOverBrowserSessionMonthly()
        try await testMissingCLISignInAsksForFolderImport()
        try testStaleUsagesFiveHourDefersToExhaustedLimits()
        try testStaleUsagesWeeklyDefersToExhaustedUsage()
        try testParsesWebFiveHourUsage()
        try await testWebFiveHourReplacesCodeFiveHour()
        try await testWebFiveHourFaultKeepsCodeFiveHour()
        try await testWebSessionRenewsOnceForBothReadings()
        try await testWebFaultStillWritesCodeSnapshot()
        try await testCodeFailureStillWritesWebSnapshot()
        try await testStalledSourceDoesNotHoldTheSnapshot()
        try await testWebRenewalIsReusedForTheMonthlyReading()
        print("Kimi usage tests passed")
    }

    private static func testParsesWeeklyAndFiveHourStringQuota() throws {
        let payload = """
        {
          "user": {
            "membership": {
              "level": "LEVEL_BASIC"
            }
          },
          "usage": {
            "limit": "2000",
            "remaining": "1580",
            "resetTime": "2026-05-16T12:00:00.123456789Z"
          },
          "limits": [
            {
              "window": {
                "duration": 300,
                "timeUnit": "TIME_UNIT_MINUTE"
              },
              "detail": {
                "limit": "200",
                "remaining": "139",
                "resetTime": "2026-05-12T23:00:00Z"
              }
            }
          ],
          "parallel": {
            "limit": "2"
          },
          "totalQuota": {
            "limit": "2000",
            "remaining": "1580"
          },
          "subType": "TYPE_PURCHASE"
        }
        """.data(using: .utf8)!

        let snapshot = try KimiUsageNormalizer.snapshot(from: payload, fetchedAt: Date(timeIntervalSince1970: 0))

        try expectEqual(snapshot.providerID, .kimi, "provider")
        try expectEqual(snapshot.displayName, "Kimi Code", "display name")
        try expectEqual(snapshot.planName, "Moderato", "plan name")
        try expectEqual(snapshot.windows.count, 2, "window count")

        guard let weekly = snapshot.windows.first(where: { $0.label == "Weekly" }) else {
            throw TestFailure.failed("weekly window missing")
        }
        try expectEqual(weekly.windowKind, .weekly, "weekly kind")
        try expectEqual(weekly.used, 420, "weekly used")
        try expectEqual(weekly.total, 2000, "weekly total")
        try expectEqual(weekly.unit, "quota", "weekly unit")

        guard let fiveHour = snapshot.windows.first(where: { $0.label == "5H" }) else {
            throw TestFailure.failed("5h window missing")
        }
        try expectEqual(fiveHour.windowKind, .sliding, "5h kind")
        try expectEqual(fiveHour.used, 61, "5h used")
        try expectEqual(fiveHour.total, 200, "5h total")

        try expectEqual(snapshot.stats.first?.label, "Parallel Limit", "parallel stat label")
        try expectEqual(snapshot.stats.first?.value, 2, "parallel stat value")
        try expectEqual(snapshot.balances.first?.amount, 1580, "total quota balance")
    }

    private static func testMapsCurrentAndLegacyMembershipLevels() throws {
        let expectedNames: [(String, String)] = [
            ("LEVEL_BEGINNER", "Moderato"),
            ("LEVEL_BASIC", "Moderato"),
            ("LEVEL_MODERATO", "Moderato"),
            ("LEVEL_INTERMEDIATE", "Allegretto"),
            ("LEVEL_PRO", "Allegretto"),
            ("LEVEL_ALLEGRETTO", "Allegretto"),
            ("LEVEL_ADVANCED", "Allegro"),
            ("LEVEL_MAX", "Allegro"),
            ("LEVEL_ALLEGRO", "Allegro"),
            ("LEVEL_ULTRA", "Vivace"),
            ("LEVEL_VIVACE", "Vivace"),
            ("LEVEL_STANDARD", "Vivace"),
            ("STANDARD", "Vivace")
        ]

        for (level, expectedName) in expectedNames {
            let payload: [String: Any] = [
                "user": [
                    "membership": [
                        "level": level
                    ]
                ],
                "usage": [
                    "limit": 100,
                    "remaining": 100
                ]
            ]

            let snapshot = try KimiUsageNormalizer.snapshot(from: payload)
            try expectEqual(snapshot.planName, expectedName, "\(level) plan name")
        }
    }

    private static func testParsesMissingOptionalFieldsAndUnknownMembership() throws {
        let payload = """
        {
          "user": {
            "membership": {
              "level": "LEVEL_CUSTOM_ENTERPRISE"
            }
          },
          "usage": {
            "limit": 100,
            "remaining": 25
          }
        }
        """.data(using: .utf8)!

        let snapshot = try KimiUsageNormalizer.snapshot(from: payload)

        try expectEqual(snapshot.planName, "Custom Enterprise", "unknown membership")
        try expectEqual(snapshot.windows.count, 1, "minimal window count")
        try expectEqual(snapshot.windows[0].used, 75, "minimal used")
        try expectNil(snapshot.windows[0].resetDate, "minimal reset date")
        try expect(snapshot.stats.isEmpty, "minimal stats should be empty")
        try expect(snapshot.balances.isEmpty, "minimal balances should be empty")
    }

    private static func testParsesExhaustedWeeklyAndUnusedFiveHourQuota() throws {
        let payload = """
        {
          "usage": {
            "limit": "100",
            "used": "100",
            "resetTime": "2099-07-13T14:03:53Z"
          },
          "limits": [
            {
              "window": {
                "duration": 300,
                "timeUnit": "TIME_UNIT_MINUTE"
              },
                "detail": {
                  "limit": "100",
                  "remaining": "100",
                  "resetTime": "2099-07-13T02:03:53Z"
              }
            }
          ]
        }
        """.data(using: .utf8)!

        let snapshot = try KimiUsageNormalizer.snapshot(from: payload)

        let weekly = try requiredWindow("Weekly", in: snapshot)
        try expectEqual(weekly.used, 100, "explicit weekly used")
        try expectEqual(weekly.percentageUsed, 100, "explicit weekly percentage")

        let fiveHour = try requiredWindow("5H", in: snapshot)
        try expectEqual(fiveHour.used, 0, "unused 5h quota")
        try expectEqual(fiveHour.percentageUsed, 0, "unused 5h percentage")
    }

    private static func testParsesWebMonthlyMembershipQuota() throws {
        let payload = """
        {
          "subscription_balance": {
            "amount_used_ratio": 0.4767,
            "kimi_code_used_ratio": 0.2,
            "expire_time": "2026-08-24T00:00:00Z"
          }
        }
        """.data(using: .utf8)!

        let reading = KimiWebMembershipParser.monthlyUsage(from: payload)
        try expectEqual(reading?.usedPercent, 47.67, "web monthly total usage")
        try expectEqual(
            reading?.resetDate,
            ISO8601DateFormatter().date(from: "2026-08-24T00:00:00Z"),
            "web monthly reset"
        )

        let freshCycle = KimiWebMembershipParser.monthlyUsage(
            from: #"{"subscription_balance":{"expire_time":"2026-09-24T00:00:00Z"}}"#
                .data(using: .utf8)!
        )
        try expectEqual(freshCycle?.usedPercent, 0, "omitted fresh-cycle ratio")
    }

    private static func testMergesWebMonthlyQuotaWithCodeWindows() async throws {
        KimiMockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            if request.url?.path.contains("GetSubscriptionStats") == true {
                try expectEqual(
                    request.value(forHTTPHeaderField: "Authorization"),
                    "Bearer web-access-token",
                    "web membership authorization"
                )
                return (
                    response,
                    #"{"subscription_balance":{"amount_used_ratio":1,"expire_time":"2099-08-24T00:00:00Z"}}"#
                        .data(using: .utf8)!
                )
            }
            return (
                response,
                #"{"usage":{"limit":100,"used":48,"resetTime":"2099-08-28T00:00:00Z"},"limits":[{"window":{"duration":300,"timeUnit":"TIME_UNIT_MINUTE"},"detail":{"limit":100,"used":0,"resetTime":"2099-08-22T05:43:00Z"}}]}"#
                    .data(using: .utf8)!
            )
        }
        defer { KimiMockURLProtocol.requestHandler = nil }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [KimiMockURLProtocol.self]
        let snapshot = try await KimiProviderClient(
            session: URLSession(configuration: configuration),
            persistWebSessionTokens: { _ in true }
        ).fetchSnapshot(
            credentials: ProviderCredential(
                accessToken: "code-access-token",
                extraFields: ["kimiWebAccessToken": "web-access-token"]
            )
        )

        let monthly = try requiredWindow("Monthly", in: snapshot)
        try expectEqual(monthly.windowKind, .monthly, "web monthly kind")
        try expectEqual(monthly.percentageUsed, 100, "web monthly percentage")
        try expectEqual(snapshot.windows.map(\.label), ["5H", "Weekly", "Monthly"], "Kimi window order")
    }

    private static func testRefreshesAndPersistsWebSessionTokens() async throws {
        var persisted: KimiWebSessionTokens?
        var statsRequests = 0
        KimiMockURLProtocol.requestHandler = { request in
            if request.url?.path.contains("RefreshToken") == true {
                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!
                return (
                    response,
                    #"{"access_token":"rotated-web-access","refresh_token":"rotated-web-refresh"}"#
                        .data(using: .utf8)!
                )
            }

            statsRequests += 1
            let authorization = request.value(forHTTPHeaderField: "Authorization")
            let status = authorization == "Bearer rotated-web-access" ? 200 : 401
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: status,
                httpVersion: nil,
                headerFields: nil
            )!
            let data = status == 200
                ? #"{"subscriptionBalance":{"amountUsedRatio":0.25,"expireTime":{"seconds":4102444800}}}"#.data(using: .utf8)!
                : Data()
            return (response, data)
        }
        defer { KimiMockURLProtocol.requestHandler = nil }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [KimiMockURLProtocol.self]
        let client = KimiWebMembershipClient(
            session: URLSession(configuration: configuration),
            persistTokens: {
                persisted = $0
                return true
            }
        )
        let reading = try await client.fetchMonthlyUsage(
            credentials: ProviderCredential(
                extraFields: [
                    "kimiWebAccessToken": "expired-web-access",
                    "kimiWebRefreshToken": "web-refresh"
                ]
            )
        )

        try expectEqual(reading?.usedPercent, 25, "refreshed web monthly percentage")
        try expectEqual(statsRequests, 2, "web stats retry count")
        try expectEqual(persisted?.accessToken, "rotated-web-access", "persisted web access token")
        try expectEqual(persisted?.refreshToken, "rotated-web-refresh", "persisted web refresh token")
    }

    private static func testPersistenceFailureStopsWebSessionRetry() async throws {
        var statsRequests = 0
        KimiMockURLProtocol.requestHandler = { request in
            if request.url?.path.contains("RefreshToken") == true {
                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!
                return (
                    response,
                    #"{"access_token":"rotated-web-access","refresh_token":"rotated-web-refresh"}"#
                        .data(using: .utf8)!
                )
            }

            statsRequests += 1
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 401,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Data())
        }
        defer { KimiMockURLProtocol.requestHandler = nil }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [KimiMockURLProtocol.self]
        let client = KimiWebMembershipClient(
            session: URLSession(configuration: configuration),
            persistTokens: { _ in false }
        )

        do {
            _ = try await client.fetchMonthlyUsage(
                credentials: ProviderCredential(
                    extraFields: [
                        "kimiWebAccessToken": "expired-web-access",
                        "kimiWebRefreshToken": "web-refresh"
                    ]
                )
            )
            throw TestFailure.failed("failed Kimi token persistence should throw")
        } catch ProviderFetchError.credentialExpired(let message) {
            try expect(
                message.contains("could not save the rotated tokens"),
                "Kimi persistence failure should explain the re-import requirement"
            )
        }

        try expectEqual(
            statsRequests,
            1,
            "Kimi must not retry usage with an unpersisted rotated token"
        )
    }

    private static func requiredWindow(_ label: String, in snapshot: QuotaSnapshot) throws -> QuotaWindow {
        guard let window = snapshot.windows.first(where: { $0.label == label }) else {
            throw TestFailure.failed("\(label) window missing")
        }
        return window
    }

    private static func testImportsPlainTextAPIKey() throws {
        let url = try temporaryFile(named: "kimi-api-key.txt", contents: "sk-kimi-test-key\n")

        let imported = try CredentialImportService.importFromURL(url, for: .kimi)

        try expectEqual(imported.accessToken, "sk-kimi-test-key", "plain API key")
        try expectNil(imported.customEndpoint, "plain API key custom endpoint")
    }

    private static func testImportsCLIOAuthJSONAsFileReference() throws {
        let url = try temporaryFile(
            named: "kimi-code.json",
            contents: """
            {
              "access_token": "redacted-access-token",
              "refresh_token": "redacted-refresh-token",
              "expires_at": 4102444800,
              "scope": "kimi-code",
              "token_type": "Bearer"
            }
            """
        )

        let imported = try CredentialImportService.importFromURL(url, for: .kimi)

        try expectNil(imported.accessToken, "CLI OAuth import should not store access token")
        try expectEqual(imported.customEndpoint, url.path, "CLI OAuth path")
        try expectEqual(imported.extraFields?["kimiAuthMode"], "oauthFile", "CLI OAuth auth mode")
    }

    private static func testImportsCLIOAuthDirectory() throws {
        let root = try temporaryDirectory().appendingPathComponent(".kimi-code", isDirectory: true)
        let credentials = root.appendingPathComponent("credentials", isDirectory: true)
        try FileManager.default.createDirectory(at: credentials, withIntermediateDirectories: true)
        let url = credentials.appendingPathComponent("kimi-code.json")
        try """
        {
          "access_token": "redacted-access-token",
          "refresh_token": "redacted-refresh-token",
          "expires_at": 4102444800,
          "scope": "kimi-code",
          "token_type": "Bearer"
        }
        """.data(using: .utf8)?.write(to: url)

        let imported = try CredentialImportService.importFromURL(root, for: .kimi)

        try expectNil(imported.accessToken, "CLI OAuth directory import should not store access token")
        try expectEqual(imported.customEndpoint, url.path, "CLI OAuth directory path")
        try expectEqual(imported.extraFields?["kimiAuthMode"], "oauthFile", "CLI OAuth directory auth mode")
        try expectEqual(imported.extraFields?["kimiCredentialSource"], "directory", "CLI OAuth directory source")
    }

    private static func testMigratedCLIOAuthUsesCurrentKimiCodeFile() async throws {
        let home = try temporaryDirectory()
        let legacyFile = home.appendingPathComponent(".kimi/credentials/kimi-code.json")
        let currentFile = home.appendingPathComponent(".kimi-code/credentials/kimi-code.json")
        try FileManager.default.createDirectory(
            at: legacyFile.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: currentFile.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try oauthJSON(accessToken: "expired-legacy-token", expiresAt: 1).write(to: legacyFile)
        try oauthJSON(accessToken: "current-access-token", expiresAt: 4_102_444_800).write(to: currentFile)

        KimiMockURLProtocol.requestHandler = { request in
            try expectEqual(
                request.value(forHTTPHeaderField: "Authorization"),
                "Bearer current-access-token",
                "migrated OAuth authorization"
            )
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            let data = """
            {
              "usage": {
                "limit": "100",
                "used": "12",
                "remaining": "88",
                "resetTime": "2099-07-21T20:56:55Z"
              }
            }
            """.data(using: .utf8)!
            return (response, data)
        }
        defer { KimiMockURLProtocol.requestHandler = nil }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [KimiMockURLProtocol.self]
        let credential = ProviderCredential(
            customEndpoint: legacyFile.path,
            extraFields: ["kimiAuthMode": "oauthFile"]
        )
        let snapshot = try await KimiProviderClient(
            session: URLSession(configuration: configuration)
        ).fetchSnapshot(credentials: credential)

        try expectEqual(try requiredWindow("Weekly", in: snapshot).percentageUsed, 12, "migrated weekly usage")
    }

    private static func testBookmarkedLegacyOAuthRequiresCurrentFolderImport() async throws {
        let home = try temporaryDirectory()
        let legacyFile = home.appendingPathComponent(".kimi/credentials/kimi-code.json")
        let currentFile = home.appendingPathComponent(".kimi-code/credentials/kimi-code.json")
        try FileManager.default.createDirectory(
            at: legacyFile.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: currentFile.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try oauthJSON(accessToken: "expired-legacy-token", expiresAt: 1).write(to: legacyFile)
        try oauthJSON(accessToken: "current-access-token", expiresAt: 4_102_444_800).write(to: currentFile)

        let credential = ProviderCredential(
            customEndpoint: legacyFile.path,
            extraFields: ["kimiAuthMode": "oauthFile"],
            // Invalid data intentionally models a bookmark that cannot resolve
            // outside the old folder's sandbox scope.
            bookmarkData: Data([0])
        )

        do {
            _ = try await KimiProviderClient().fetchSnapshot(credentials: credential)
            throw TestFailure.failed("legacy bookmark should require a current folder import")
        } catch ProviderFetchError.credentialExpired(let message) {
            try expect(message.contains("moved its live session to ~/.kimi-code"), "legacy bookmark migration message")
        }
    }

    private static func testExpiredCLIOAuthRefreshesAndPersistsRotatedToken() async throws {
        let root = try temporaryDirectory().appendingPathComponent(".kimi-code", isDirectory: true)
        let credentialsDirectory = root.appendingPathComponent("credentials", isDirectory: true)
        try FileManager.default.createDirectory(at: credentialsDirectory, withIntermediateDirectories: true)
        let url = credentialsDirectory.appendingPathComponent("kimi-code.json")
        try oauthJSON(
            accessToken: "expired-access-token",
            refreshToken: "original-refresh-token",
            expiresAt: 1,
            expiresIn: 900
        ).write(to: url)

        var requestCount = 0
        var refreshMethod: String?
        var refreshBody = ""
        var usageAuthorization: String?
        KimiMockURLProtocol.requestHandler = { request in
            requestCount += 1
            if request.url?.host == "auth.kimi.com" {
                refreshMethod = request.httpMethod
                refreshBody = requestBodyString(request)
                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!
                let data = """
                {
                  "access_token": "rotated-access-token",
                  "refresh_token": "rotated-refresh-token",
                  "expires_in": 900,
                  "scope": "kimi-code",
                  "token_type": "Bearer"
                }
                """.data(using: .utf8)!
                return (response, data)
            }

            usageAuthorization = request.value(forHTTPHeaderField: "Authorization")
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            let data = """
            {
              "usage": {
                "limit": "100",
                "used": "12",
                "remaining": "88",
                "resetTime": "2099-07-21T20:56:55Z"
              }
            }
            """.data(using: .utf8)!
            return (response, data)
        }
        defer { KimiMockURLProtocol.requestHandler = nil }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [KimiMockURLProtocol.self]
        let credential = ProviderCredential(
            customEndpoint: url.path,
            extraFields: ["kimiAuthMode": "oauthFile"]
        )
        let snapshot = try await KimiProviderClient(
            session: URLSession(configuration: configuration)
        ).fetchSnapshot(credentials: credential)

        try expectEqual(try requiredWindow("Weekly", in: snapshot).percentageUsed, 12, "refreshed weekly usage")
        try expectEqual(requestCount, 2, "refresh and usage request count")
        try expectEqual(refreshMethod, "POST", "refresh method")
        try expect(refreshBody.contains("client_id=17e5f671-d194-4dfb-9706-5516cb48c098"), "refresh client id")
        try expect(refreshBody.contains("grant_type=refresh_token"), "refresh grant type")
        try expect(refreshBody.contains("refresh_token=original-refresh-token"), "refresh token")
        try expectEqual(usageAuthorization, "Bearer rotated-access-token", "usage request should use refreshed token")

        let persisted = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        try expectEqual(persisted?["access_token"] as? String, "rotated-access-token", "persisted access token")
        try expectEqual(persisted?["refresh_token"] as? String, "rotated-refresh-token", "persisted refresh token")
        try expect((persisted?["expires_at"] as? Double ?? 0) > Date().timeIntervalSince1970, "persisted expiry")
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        try expectEqual(attributes[.posixPermissions] as? Int, 0o600, "OAuth file permissions")
    }

    private static func testRejectedRefreshThrowsCredentialExpired() async throws {
        let url = try temporaryFile(
            named: "kimi-code.json",
            contents: """
            {
              "access_token": "expired-access-token",
              "refresh_token": "rejected-refresh-token",
              "expires_at": 1,
              "expires_in": 900,
              "scope": "kimi-code",
              "token_type": "Bearer"
            }
            """
        )

        let credential = ProviderCredential(
            customEndpoint: url.path,
            extraFields: ["kimiAuthMode": "oauthFile"]
        )

        KimiMockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 401,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Data())
        }
        defer { KimiMockURLProtocol.requestHandler = nil }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [KimiMockURLProtocol.self]

        do {
            _ = try await KimiProviderClient(
                session: URLSession(configuration: configuration)
            ).fetchSnapshot(credentials: credential)
            throw TestFailure.failed("rejected refresh should throw")
        } catch ProviderFetchError.credentialExpired(let message) {
            try expect(message.contains("rejected the saved refresh token"), "rejected refresh message")
        }
    }

    private static func testExternalRotationRecoversFromInvalidGrant() async throws {
        let root = try temporaryDirectory().appendingPathComponent(".kimi-code", isDirectory: true)
        let credentialsDirectory = root.appendingPathComponent("credentials", isDirectory: true)
        try FileManager.default.createDirectory(at: credentialsDirectory, withIntermediateDirectories: true)
        let url = credentialsDirectory.appendingPathComponent("kimi-code.json")
        try oauthJSON(
            accessToken: "expired-access-token",
            refreshToken: "stale-refresh-token",
            expiresAt: 1,
            expiresIn: 900
        ).write(to: url)

        var usageAuthorization: String?
        KimiMockURLProtocol.requestHandler = { request in
            if request.url?.host == "auth.kimi.com" {
                try oauthJSON(
                    accessToken: "externally-rotated-access-token",
                    refreshToken: "externally-rotated-refresh-token",
                    expiresAt: Date().timeIntervalSince1970 + 900,
                    expiresIn: 900
                ).write(to: url, options: .atomic)
                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 400,
                    httpVersion: nil,
                    headerFields: nil
                )!
                return (response, #"{"error":"invalid_grant"}"#.data(using: .utf8)!)
            }

            usageAuthorization = request.value(forHTTPHeaderField: "Authorization")
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            let data = """
            {
              "usage": {
                "limit": "100",
                "used": "12",
                "remaining": "88",
                "resetTime": "2099-07-21T20:56:55Z"
              }
            }
            """.data(using: .utf8)!
            return (response, data)
        }
        defer { KimiMockURLProtocol.requestHandler = nil }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [KimiMockURLProtocol.self]
        let credential = ProviderCredential(
            customEndpoint: url.path,
            extraFields: ["kimiAuthMode": "oauthFile"]
        )
        let snapshot = try await KimiProviderClient(
            session: URLSession(configuration: configuration)
        ).fetchSnapshot(credentials: credential)

        try expectEqual(try requiredWindow("Weekly", in: snapshot).percentageUsed, 12, "race recovery usage")
        try expectEqual(
            usageAuthorization,
            "Bearer externally-rotated-access-token",
            "race recovery authorization"
        )
    }

    private static func testParsesProPlanWithoutWeeklyWindow() throws {
        // Shape of the live Pro reply (2026-09-25): no `limit_7d`, and the
        // legacy `limits` entry still sent beside `usages`.
        let payload = """
        {
          "limits": [
            {
              "detail": {
                "limit": "100",
                "remaining": "99",
                "resetTime": "2099-09-25T07:08:23.538306Z",
                "used": "1"
              },
              "window": {
                "duration": 300,
                "timeUnit": "TIME_UNIT_MINUTE"
              }
            }
          ],
          "usages": {
            "limit_5h": {
              "reset_time": "2099-09-25T07:08:22Z",
              "used_ratio": 0.25
            },
            "limit_month_code": {
              "reset_time": "2099-10-26T00:00:00Z",
              "used_ratio": 0.1
            },
            "limit_month_total": {
              "reset_time": "2099-10-26T00:00:00Z",
              "used_ratio": 0.4
            }
          }
        }
        """.data(using: .utf8)!

        let snapshot = try KimiUsageNormalizer.snapshot(from: payload, planName: "Pro")

        try expectEqual(snapshot.planName, "Pro", "Pro plan name")
        try expectEqual(snapshot.windows.map(\.label), ["5H", "Monthly"], "Pro windows")

        let fiveHour = try requiredWindow("5H", in: snapshot)
        try expectEqual(fiveHour.windowKind, .sliding, "Pro 5h kind")
        try expectEqual(fiveHour.percentageUsed, 25, "Pro 5h should use usages, not legacy limits")
        try expectEqual(fiveHour.unit, "%", "Pro 5h unit")
        try expectEqual(
            fiveHour.resetDate,
            ISO8601DateFormatter().date(from: "2099-09-25T07:08:22Z"),
            "Pro 5h reset"
        )

        let monthly = try requiredWindow("Monthly", in: snapshot)
        try expectEqual(monthly.windowKind, .monthly, "Pro monthly kind")
        try expectEqual(monthly.percentageUsed, 40, "Pro monthly percentage")
        try expectEqual(monthly.subtitle, "Kimi Code 10% · Kimi app 30%", "Pro monthly split")
        try expectEqual(
            monthly.resetDate,
            ISO8601DateFormatter().date(from: "2099-10-26T00:00:00Z"),
            "Pro monthly reset"
        )
    }

    private static func testParsesVivacePlanWithWeeklyWindow() throws {
        let payload = """
        {
          "usages": {
            "limit_5h": { "used_ratio": "0.5", "reset_time": "2099-09-25T07:00:00Z" },
            "limit_7d": { "used_ratio": 1, "reset_time": "2099-09-29T00:00:00Z" },
            "limit_month_total": { "used_ratio": 0.2, "reset_time": "2099-10-10T00:00:00Z" }
          }
        }
        """.data(using: .utf8)!

        let snapshot = try KimiUsageNormalizer.snapshot(from: payload)

        try expectEqual(snapshot.windows.map(\.label), ["5H", "Weekly", "Monthly"], "Vivace windows")
        try expectEqual(try requiredWindow("5H", in: snapshot).percentageUsed, 50, "string ratio")
        let weekly = try requiredWindow("Weekly", in: snapshot)
        try expectEqual(weekly.windowKind, .weekly, "Vivace weekly kind")
        try expectEqual(weekly.percentageUsed, 100, "Vivace weekly percentage")
        try expectEqual(
            try requiredWindow("Monthly", in: snapshot).subtitle,
            "Shared Kimi membership quota",
            "monthly without a code split"
        )
    }

    private static func testEmptyUsagesFallBackToLegacyFields() throws {
        let snapshot = try KimiUsageNormalizer.snapshot(
            from: #"{"usages":{},"usage":{"limit":100,"used":30}}"#.data(using: .utf8)!
        )

        try expectEqual(snapshot.windows.map(\.label), ["Weekly"], "legacy fallback windows")
        try expectEqual(try requiredWindow("Weekly", in: snapshot).percentageUsed, 30, "legacy fallback weekly")
    }

    private static func testReadsPlanNameFromUserInfo() throws {
        try expectEqual(
            KimiUsageNormalizer.planName(
                fromUserInfo: #"{"user_level":25,"user_level_name":"Pro","goods_version":2}"#.data(using: .utf8)!
            ),
            "Pro",
            "user info plan name"
        )
        try expectNil(
            KimiUsageNormalizer.planName(fromUserInfo: #"{"user_level_name":" "}"#.data(using: .utf8)!),
            "blank user info plan name"
        )
    }

    private static func testDerivesCLICredentialSlots() throws {
        try expectEqual(KimiCodeEnvironment.mainlandChina.slot, "kimi-code", "kimi.com slot")
        // Matches the file Kimi Code 2.1.1 wrote for its kimi.ai sign-in.
        try expectEqual(KimiCodeEnvironment.global.slot, "kimi-code-env-0e4f99c69cc27850", "kimi.ai slot")
        try expectEqual(
            KimiCodeEnvironment(oauthHost: " https://auth.kimi.ai/ ", baseURL: "https://api.kimi.ai/coding/v1//").slot,
            KimiCodeEnvironment.global.slot,
            "endpoints normalise before hashing"
        )
        // sha256 of {"oauthHost":"https://auth.kimi.com","baseUrl":"https://api.kimi.ai/coding/v1"}
        try expectEqual(
            KimiCodeEnvironment.slot(oauthHost: "https://auth.kimi.com", baseURL: "https://api.kimi.ai/coding/v1"),
            "kimi-code-env-d44abaad1d85681f",
            "mixed deployment slot"
        )
        try expectEqual(
            KimiCodeEnvironment.global.usageURL?.absoluteString,
            "https://api.kimi.ai/coding/v1/usages",
            "kimi.ai usage URL"
        )
        try expectEqual(
            KimiCodeEnvironment.global.tokenURL?.absoluteString,
            "https://auth.kimi.ai/api/oauth/token",
            "kimi.ai token URL"
        )
    }

    private static func testReadsDeploymentFromCLIConfig() throws {
        try expectEqual(
            KimiCodeEnvironment.configured(inConfigTOML: globalConfigTOML),
            KimiCodeEnvironment.global,
            "kimi.ai config"
        )

        let inlineTable = """
        [providers."managed:kimi-code"]
        type = "kimi"
        base_url = 'https://api.kimi.ai/coding/v1'
        oauth = { storage = "file", key = "oauth/kimi-code-env-0e4f99c69cc27850", oauth_host = "https://auth.kimi.ai" }
        """
        try expectEqual(
            KimiCodeEnvironment.configured(inConfigTOML: inlineTable),
            KimiCodeEnvironment.global,
            "inline oauth table"
        )

        let mainland = """
        [providers."managed:kimi-code"]
        type = "kimi"
        base_url = "https://api.kimi.com/coding/v1"

        [providers."managed:kimi-code".oauth]
        storage = "file"
        key = "oauth/kimi-code"
        """
        try expectEqual(
            KimiCodeEnvironment.configured(inConfigTOML: mainland),
            KimiCodeEnvironment.mainlandChina,
            "kimi.com config without oauth_host"
        )

        // The CLI derives the slot from the hosts and ignores a stored key
        // that disagrees.
        let staleKey = globalConfigTOML.replacingOccurrences(
            of: "oauth/kimi-code-env-0e4f99c69cc27850",
            with: "oauth/kimi-code"
        )
        try expectEqual(
            KimiCodeEnvironment.configured(inConfigTOML: staleKey)?.slot,
            KimiCodeEnvironment.global.slot,
            "stale stored key"
        )

        try expectNil(
            KimiCodeEnvironment.configured(inConfigTOML: "default_model = \"k3\"\n[thinking]\nenabled = true\n"),
            "config without the managed provider"
        )
    }

    private static func testLocatesCurrentCLISignIn() throws {
        let root = try temporaryDirectory().appendingPathComponent(".kimi-code", isDirectory: true)
        let credentials = root.appendingPathComponent("credentials", isDirectory: true)
        try FileManager.default.createDirectory(at: credentials, withIntermediateDirectories: true)
        try globalConfigTOML.data(using: .utf8)?.write(to: root.appendingPathComponent("config.toml"))
        let globalFile = credentials.appendingPathComponent("kimi-code-env-0e4f99c69cc27850.json")
        try oauthJSON(accessToken: "global-access-token", expiresAt: 4_102_444_800).write(to: globalFile)

        let fromFolder = KimiCodeSignIn.locate(from: root)
        try expectEqual(fromFolder.fileURL.lastPathComponent, globalFile.lastPathComponent, "folder sign-in")
        try expectEqual(fromFolder.environment, .global, "folder deployment")
        try expectEqual(fromFolder.configRoot.lastPathComponent, ".kimi-code", "folder config root")

        // A credential saved before the move still names kimi-code.json.
        let fromStaleFile = KimiCodeSignIn.locate(from: credentials.appendingPathComponent("kimi-code.json"))
        try expectEqual(fromStaleFile.fileURL.lastPathComponent, globalFile.lastPathComponent, "stale file follows the CLI")
        try expectEqual(fromStaleFile.environment, .global, "stale file deployment")

        let fromCredentialsFolder = KimiCodeSignIn.locate(from: credentials)
        try expectEqual(fromCredentialsFolder.environment, .global, "credentials folder deployment")

        // Without a readable config, the newest known sign-in decides.
        let bare = try temporaryDirectory().appendingPathComponent(".kimi-code", isDirectory: true)
        let bareCredentials = bare.appendingPathComponent("credentials", isDirectory: true)
        try FileManager.default.createDirectory(at: bareCredentials, withIntermediateDirectories: true)
        let bareGlobal = bareCredentials.appendingPathComponent("kimi-code-env-0e4f99c69cc27850.json")
        let bareMainland = bareCredentials.appendingPathComponent("kimi-code.json")
        try oauthJSON(accessToken: "global", expiresAt: 4_102_444_800).write(to: bareGlobal)
        try expectEqual(KimiCodeSignIn.locate(from: bare).environment, .global, "only the kimi.ai sign-in")

        try oauthJSON(accessToken: "mainland", expiresAt: 4_102_444_800).write(to: bareMainland)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: -3_600)],
            ofItemAtPath: bareGlobal.path
        )
        try expectEqual(KimiCodeSignIn.locate(from: bare).environment, .mainlandChina, "newer kimi.com sign-in")
    }

    private static func testImportsCLIFolderSignedInToGlobalDeployment() throws {
        let root = try temporaryDirectory().appendingPathComponent(".kimi-code", isDirectory: true)
        let credentials = root.appendingPathComponent("credentials", isDirectory: true)
        try FileManager.default.createDirectory(at: credentials, withIntermediateDirectories: true)
        try globalConfigTOML.data(using: .utf8)?.write(to: root.appendingPathComponent("config.toml"))
        let globalFile = credentials.appendingPathComponent("kimi-code-env-0e4f99c69cc27850.json")
        try oauthJSON(accessToken: "global-access-token", expiresAt: 4_102_444_800).write(to: globalFile)

        let imported = try CredentialImportService.importFromURL(root, for: .kimi)

        try expectNil(imported.accessToken, "global folder import should not store access token")
        try expectEqual(imported.customEndpoint, globalFile.path, "global folder import path")
        try expectEqual(imported.extraFields?["kimiAuthMode"], "oauthFile", "global folder auth mode")
        try expectEqual(imported.extraFields?["kimiCredentialSource"], "directory", "global folder source")
    }

    private static func testGlobalSignInRefreshesWithItsOwnHostAndLock() async throws {
        let root = try temporaryDirectory().appendingPathComponent(".kimi-code", isDirectory: true)
        let credentials = root.appendingPathComponent("credentials", isDirectory: true)
        try FileManager.default.createDirectory(at: credentials, withIntermediateDirectories: true)
        try globalConfigTOML.data(using: .utf8)?.write(to: root.appendingPathComponent("config.toml"))
        let globalFile = credentials.appendingPathComponent("kimi-code-env-0e4f99c69cc27850.json")
        try oauthJSON(
            accessToken: "expired-global-token",
            refreshToken: "global-refresh-token",
            expiresAt: 1,
            expiresIn: 900
        ).write(to: globalFile)
        let slotLock = root.appendingPathComponent("oauth/kimi-code-env-0e4f99c69cc27850.lock")

        var refreshURL: String?
        var lockHeldDuringRefresh = false
        var usageURL: String?
        var userInfoAuthorization: String?
        KimiMockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            if request.url?.path == "/api/oauth/token" {
                refreshURL = request.url?.absoluteString
                lockHeldDuringRefresh = FileManager.default.fileExists(atPath: slotLock.path)
                return (
                    response,
                    #"{"access_token":"rotated-global-token","refresh_token":"rotated-global-refresh","expires_in":900}"#
                        .data(using: .utf8)!
                )
            }
            usageURL = request.url?.absoluteString
            return (response, proUsagesJSON)
        }
        KimiMockURLProtocol.userInfoHandler = { request in
            userInfoAuthorization = request.value(forHTTPHeaderField: "Authorization")
            try expectEqual(request.url?.host, "api.kimi.ai", "user info host")
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, #"{"user_id":"redacted","user_level":25,"user_level_name":"Pro"}"#.data(using: .utf8)!)
        }
        defer {
            KimiMockURLProtocol.requestHandler = nil
            KimiMockURLProtocol.userInfoHandler = nil
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [KimiMockURLProtocol.self]
        // Saved before Kimi Code moved the sign-in to its kimi.ai slot.
        let credential = ProviderCredential(
            customEndpoint: credentials.appendingPathComponent("kimi-code.json").path,
            extraFields: ["kimiAuthMode": "oauthFile", "kimiCredentialSource": "directory"]
        )
        let snapshot = try await KimiProviderClient(
            session: URLSession(configuration: configuration)
        ).fetchSnapshot(credentials: credential)

        try expectEqual(refreshURL, "https://auth.kimi.ai/api/oauth/token", "kimi.ai refresh endpoint")
        try expect(lockHeldDuringRefresh, "refresh should hold the kimi.ai slot's lock")
        try expect(
            FileManager.default.fileExists(atPath: root.appendingPathComponent("oauth/kimi-code-env-0e4f99c69cc27850").path),
            "slot lock target"
        )
        try expect(!FileManager.default.fileExists(atPath: slotLock.path), "slot lock released")
        try expectEqual(usageURL, "https://api.kimi.ai/coding/v1/usages", "kimi.ai usage endpoint")
        try expectEqual(userInfoAuthorization, "Bearer rotated-global-token", "user info authorization")
        try expectEqual(snapshot.planName, "Pro", "plan from user info")
        try expectEqual(snapshot.windows.map(\.label), ["5H", "Monthly"], "Pro windows from the live fetch")

        let persisted = try JSONSerialization.jsonObject(with: Data(contentsOf: globalFile)) as? [String: Any]
        try expectEqual(persisted?["access_token"] as? String, "rotated-global-token", "persisted kimi.ai token")
        try expect(
            !FileManager.default.fileExists(atPath: credentials.appendingPathComponent("kimi-code.json").path),
            "the old slot should not be recreated"
        )
    }

    private static func testCodeMonthlyWinsOverBrowserSessionMonthly() async throws {
        var browserRequests = 0
        KimiMockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            if request.url?.path.contains("GetSubscriptionStats") == true {
                browserRequests += 1
                return (
                    response,
                    #"{"subscription_balance":{"amount_used_ratio":0.9,"expire_time":"2099-08-24T00:00:00Z"}}"#
                        .data(using: .utf8)!
                )
            }
            return (response, proUsagesJSON)
        }
        defer { KimiMockURLProtocol.requestHandler = nil }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [KimiMockURLProtocol.self]
        let snapshot = try await KimiProviderClient(
            session: URLSession(configuration: configuration),
            persistWebSessionTokens: { _ in true }
        ).fetchSnapshot(
            credentials: ProviderCredential(
                accessToken: "code-access-token",
                extraFields: ["kimiWebAccessToken": "web-access-token"]
            )
        )

        try expectEqual(browserRequests, 0, "browser session should not be asked when Kimi Code has a monthly window")
        try expectEqual(try requiredWindow("Monthly", in: snapshot).percentageUsed, 40, "Kimi Code monthly")
        try expectNil(snapshot.planName, "plan name without user info")
    }

    private static func testStaleUsagesFiveHourDefersToExhaustedLimits() throws {
        // Kimi Code's `/usages` has reported `used_ratio: 0` for a 5-hour
        // window its own `limits` entry (same reset) shows spent, while Kimi
        // answered 403 and the kimi.ai page read 100%.
        let payload = """
        {
          "limits": [
            {
              "detail": { "limit": "100", "remaining": "0", "resetTime": "2099-09-27T14:08:23.538306123Z", "used": "100" },
              "window": { "duration": 300, "timeUnit": "TIME_UNIT_MINUTE" }
            }
          ],
          "usages": {
            "limit_5h": { "reset_time": "2099-09-27T14:08:23Z", "used_ratio": 0 },
            "limit_month_total": { "reset_time": "2099-10-26T00:00:00Z", "used_ratio": 0.131 }
          }
        }
        """.data(using: .utf8)!

        let snapshot = try KimiUsageNormalizer.snapshot(from: payload, planName: "Pro")

        try expectEqual(snapshot.windows.map(\.label), ["5H", "Monthly"], "stale-ratio windows")
        let fiveHour = try requiredWindow("5H", in: snapshot)
        try expectEqual(fiveHour.percentageUsed, 100, "stale 5h ratio defers to the exhausted limits entry")
        try expectEqual(fiveHour.unit, "%", "reconciled 5h stays a percent window")
        try expectEqual(
            fiveHour.resetDate,
            ISO8601DateFormatter().date(from: "2099-09-27T14:08:23Z"),
            "reconciled 5h keeps its reset"
        )

        // `remaining` alone is enough, and hours count as well as minutes.
        let remainingOnly = try KimiUsageNormalizer.snapshot(
            from: """
            {
              "limits": [{ "detail": { "limit": 200, "remaining": 50 }, "window": { "duration": 5, "timeUnit": "TIME_UNIT_HOUR" } }],
              "usages": { "limit_5h": { "reset_time": "2099-09-27T14:08:23Z", "used_ratio": 0.1 } }
            }
            """.data(using: .utf8)!
        )
        try expectEqual(try requiredWindow("5H", in: remainingOnly).percentageUsed, 75, "remaining-only 5h entry")
    }

    private static func testStaleUsagesWeeklyDefersToExhaustedUsage() throws {
        let vivace = try KimiUsageNormalizer.snapshot(
            from: """
            {
              "usage": { "limit": "100", "used": "100", "resetTime": "2099-09-24T02:09:07Z" },
              "usages": {
                "limit_5h": { "used_ratio": 0.2, "reset_time": "2099-09-20T07:00:00Z" },
                "limit_7d": { "used_ratio": 0, "reset_time": "2099-09-24T02:09:06Z" }
              }
            }
            """.data(using: .utf8)!
        )
        try expectEqual(try requiredWindow("Weekly", in: vivace).percentageUsed, 100, "stale weekly ratio defers to usage")
        try expectEqual(try requiredWindow("5H", in: vivace).percentageUsed, 20, "5h without a limits twin")

        let pro = try KimiUsageNormalizer.snapshot(
            from: """
            {
              "usage": { "limit": "100", "used": "100" },
              "usages": { "limit_5h": { "used_ratio": 0.2 }, "limit_month_total": { "used_ratio": 0.3 } }
            }
            """.data(using: .utf8)!
        )
        try expectEqual(pro.windows.map(\.label), ["5H", "Monthly"], "a plan without weekly gains none from usage")
    }

    private static func testParsesWebFiveHourUsage() throws {
        // `BillingService/GetUsages` for scope FEATURE_CODING.
        let payload = """
        {
          "usages": [
            {
              "scope": "FEATURE_OTHER",
              "limits": [{ "window": { "duration": 300, "timeUnit": "TIME_UNIT_MINUTE" }, "detail": { "limit": "10", "used": "10" } }]
            },
            {
              "scope": "FEATURE_CODING",
              "detail": { "limit": "2048", "used": "214", "remaining": "1834", "resetTime": "2099-10-09T15:23:13.716839300Z" },
              "limits": [{
                "window": { "duration": 300, "timeUnit": "TIME_UNIT_MINUTE" },
                "detail": { "limit": "200", "used": "139", "remaining": "61", "resetTime": "2099-09-27T14:08:23.717479433Z" }
              }]
            }
          ]
        }
        """.data(using: .utf8)!

        let reading = KimiWebMembershipParser.fiveHourUsage(from: payload)
        try expectClose(reading?.usedPercent, 69.5, "web 5h percentage from the coding scope")
        let expectedReset = ISO8601DateFormatter.fractional.date(from: "2099-09-27T14:08:23.717479Z")
        try expectEqual(reading?.resetDate, expectedReset, "web 5h reset with nanoseconds")

        try expectNil(
            KimiWebMembershipParser.fiveHourUsage(
                from: #"{"usages":[{"scope":"FEATURE_CODING","detail":{"limit":"2048","used":"1"}}]}"#.data(using: .utf8)!
            ),
            "coding scope without a 5h limit"
        )
        try expectNil(
            KimiWebMembershipParser.fiveHourUsage(from: #"{"usages":{"limit_5h":{"used_ratio":1}}}"#.data(using: .utf8)!),
            "Kimi Code /usages payload is not a web reply"
        )
    }

    private static func testWebFiveHourReplacesCodeFiveHour() async throws {
        var statsRequests = 0
        var usagesBody = ""
        KimiMockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            if request.url?.path.contains("GetSubscriptionStats") == true {
                statsRequests += 1
                return (response, #"{"subscription_balance":{"amount_used_ratio":0.9}}"#.data(using: .utf8)!)
            }
            if request.url?.path.hasSuffix("BillingService/GetUsages") == true {
                try expectEqual(request.url?.host, "www.kimi.ai", "web usages host")
                try expectEqual(
                    request.value(forHTTPHeaderField: "Authorization"),
                    "Bearer web-access-token",
                    "web usages authorization"
                )
                usagesBody = requestBodyString(request)
                return (response, webFiveHourJSON(used: 200, limit: 200, reset: "2099-09-27T14:08:23Z"))
            }
            return (response, proUsagesJSON)
        }
        defer { KimiMockURLProtocol.requestHandler = nil }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [KimiMockURLProtocol.self]
        let snapshot = try await KimiProviderClient(
            session: URLSession(configuration: configuration),
            persistWebSessionTokens: { _ in true }
        ).fetchSnapshot(
            credentials: ProviderCredential(
                accessToken: "code-access-token",
                extraFields: ["kimiWebAccessToken": "web-access-token"]
            )
        )

        try expectEqual(usagesBody, #"{"scope":["FEATURE_CODING"]}"#, "web usages scope")
        try expectEqual(snapshot.windows.map(\.label), ["5H", "Monthly"], "web 5h keeps the window order")
        let fiveHour = try requiredWindow("5H", in: snapshot)
        try expectEqual(fiveHour.percentageUsed, 100, "web session 5h wins over Kimi Code's")
        try expectEqual(fiveHour.windowKind, .sliding, "web 5h kind")
        try expectEqual(fiveHour.unit, "%", "web 5h unit")
        try expectEqual(
            fiveHour.resetDate,
            ISO8601DateFormatter().date(from: "2099-09-27T14:08:23Z"),
            "web 5h reset"
        )
        try expectEqual(try requiredWindow("Monthly", in: snapshot).percentageUsed, 40, "Kimi Code monthly still wins")
        try expectEqual(statsRequests, 0, "monthly is not asked of the web session when Kimi Code has one")

        // The snapshot store keeps the window in the shape it always had.
        let encoded = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(QuotaSnapshot.self, from: encoded)
        try expectEqual(try requiredWindow("5H", in: decoded).percentageUsed, 100, "5h survives the snapshot store")
    }

    private static func testWebFiveHourFaultKeepsCodeFiveHour() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [KimiMockURLProtocol.self]
        let credentials = ProviderCredential(
            accessToken: "code-access-token",
            extraFields: ["kimiWebAccessToken": "web-access-token", "kimiWebRefreshToken": "web-refresh"]
        )
        defer { KimiMockURLProtocol.requestHandler = nil }

        // Kimi's billing gateway failing leaves Kimi Code's 5-hour window.
        KimiMockURLProtocol.requestHandler = { request in
            let failing = request.url?.path.contains("GetUsages") == true
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: failing ? 500 : 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, failing ? Data() : proUsagesJSON)
        }
        let unanswered = try await KimiProviderClient(
            session: URLSession(configuration: configuration),
            persistWebSessionTokens: { _ in true }
        ).fetchSnapshot(credentials: credentials)
        try expectEqual(try requiredWindow("5H", in: unanswered).percentageUsed, 5, "Kimi Code 5h when the web does not answer")

        // A renewal that cannot be saved must not blank the card either.
        KimiMockURLProtocol.requestHandler = { request in
            let path = request.url?.path ?? ""
            if path.contains("RefreshToken") {
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (response, #"{"access_token":"rotated","refresh_token":"rotated-refresh"}"#.data(using: .utf8)!)
            }
            let expired = path.contains("GetUsages")
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: expired ? 401 : 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, expired ? Data() : proUsagesJSON)
        }
        let unsaved = try await KimiProviderClient(
            session: URLSession(configuration: configuration),
            persistWebSessionTokens: { _ in false }
        ).fetchSnapshot(credentials: credentials)
        try expectEqual(try requiredWindow("5H", in: unsaved).percentageUsed, 5, "Kimi Code 5h when the renewal cannot be saved")
    }

    private static func testWebSessionRenewsOnceForBothReadings() async throws {
        var refreshRequests = 0
        var persisted: [KimiWebSessionTokens] = []
        KimiMockURLProtocol.requestHandler = { request in
            let path = request.url?.path ?? ""
            if path.contains("RefreshToken") {
                refreshRequests += 1
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (response, #"{"access_token":"rotated-web-access","refresh_token":"rotated-web-refresh"}"#.data(using: .utf8)!)
            }
            let fresh = request.value(forHTTPHeaderField: "Authorization") == "Bearer rotated-web-access"
            let response = HTTPURLResponse(url: request.url!, statusCode: fresh ? 200 : 401, httpVersion: nil, headerFields: nil)!
            guard fresh else { return (response, Data()) }
            if path.contains("GetSubscriptionStats") {
                return (response, #"{"subscription_balance":{"amount_used_ratio":0.131}}"#.data(using: .utf8)!)
            }
            return (response, webFiveHourJSON(used: 50, limit: 200, reset: "2099-09-27T14:08:23Z"))
        }
        defer { KimiMockURLProtocol.requestHandler = nil }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [KimiMockURLProtocol.self]
        let client = KimiWebMembershipClient(
            session: URLSession(configuration: configuration),
            persistTokens: {
                persisted.append($0)
                return true
            }
        )
        let reading = try await client.fetchUsage(
            credentials: ProviderCredential(
                extraFields: ["kimiWebAccessToken": "expired-web-access", "kimiWebRefreshToken": "web-refresh"]
            ),
            monthly: true,
            fiveHour: true
        )

        try expectEqual(refreshRequests, 1, "one renewal serves both web readings")
        try expectEqual(persisted.map(\.accessToken), ["rotated-web-access"], "renewed tokens saved once")
        try expectClose(reading?.monthly?.usedPercent, 13.1, "renewed web monthly")
        try expectEqual(reading?.fiveHour?.usedPercent, 25, "renewed web 5h")
    }

    /// The kimi.ai account page read "5-hour usage · Code 6.65%, resets
    /// 09-27 20:08" and "Total usage 13.28%" while this was written.
    private static func webAnswer(for request: URLRequest) -> (HTTPURLResponse, Data)? {
        let path = request.url?.path ?? ""
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        if path.hasSuffix("BillingService/GetUsages") {
            return (response, webFiveHourJSON(used: 133, limit: 2000, reset: "2099-09-27T19:08:23.717479433Z"))
        }
        if path.contains("GetSubscriptionStats") {
            return (
                response,
                #"{"subscription_balance":{"amount_used_ratio":0.1328,"expire_time":"2099-10-25T00:00:00Z"}}"#
                    .data(using: .utf8)!
            )
        }
        return nil
    }

    /// A failing kimi.ai read, in any form, still yields a fresh snapshot
    /// with Kimi Code's values, and says why beside it.
    private static func testWebFaultStillWritesCodeSnapshot() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [KimiMockURLProtocol.self]
        let credentials = ProviderCredential(
            accessToken: "code-access-token",
            extraFields: ["kimiWebAccessToken": "web-access-token", "kimiWebRefreshToken": "web-refresh"]
        )
        defer { KimiMockURLProtocol.requestHandler = nil }

        let faults: [(name: String, answer: (URLRequest) throws -> (HTTPURLResponse, Data), reason: String)] = [
            ("HTTP 500", { request in
                (HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!, Data())
            }, "GetUsages returned HTTP 500"),
            ("transport error", { _ in
                throw URLError(.cannotFindHost)
            }, "GetUsages did not answer"),
            ("unparseable reply", { request in
                (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                 #"{"usages":[{"scope":"FEATURE_CODING"}]}"#.data(using: .utf8)!)
            }, "without a FEATURE_CODING 5-hour window"),
            ("expired session that will not renew", { request in
                let renewing = request.url?.path.contains("RefreshToken") == true
                return (HTTPURLResponse(url: request.url!, statusCode: renewing ? 403 : 401, httpVersion: nil, headerFields: nil)!, Data())
            }, "refused to renew"),
        ]
        for fault in faults {
            KimiMockURLProtocol.requestHandler = { request in
                let path = request.url?.path ?? ""
                if path.contains("GetUsages") || path.contains("RefreshToken") {
                    return try fault.answer(request)
                }
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (response, proUsagesJSON)
            }
            let client = KimiProviderClient(
                session: URLSession(configuration: configuration),
                persistWebSessionTokens: { _ in true }
            )
            let started = Date()
            let snapshot = try await client.fetchSnapshot(credentials: credentials)
            try expectEqual(snapshot.fetchState, .success, "\(fault.name): snapshot state")
            try expect(snapshot.fetchedAt >= started.addingTimeInterval(-1), "\(fault.name): fetched_at is fresh")
            try expectEqual(try requiredWindow("5H", in: snapshot).percentageUsed, 5, "\(fault.name): Kimi Code 5h")
            try expectEqual(try requiredWindow("Monthly", in: snapshot).percentageUsed, 40, "\(fault.name): Kimi Code monthly")
            let warning = await client.takePartialRefreshWarning()
            try expect(warning?.contains("kimi.ai web session") == true, "\(fault.name): warning names the web session, got \(warning ?? "nil")")
            try expect(warning?.contains(fault.reason) == true, "\(fault.name): warning gives the reason, got \(warning ?? "nil")")
        }
    }

    /// The fault behind the 27 September stall: Kimi Code's sign-in failed
    /// before any request, which used to abort the whole refresh. The web
    /// session's readings now make the snapshot on their own.
    private static func testCodeFailureStillWritesWebSnapshot() async throws {
        let root = try temporaryDirectory().appendingPathComponent(".kimi-code", isDirectory: true)
        let credentialsDirectory = root.appendingPathComponent("credentials", isDirectory: true)
        try FileManager.default.createDirectory(at: credentialsDirectory, withIntermediateDirectories: true)
        let tokenFile = credentialsDirectory.appendingPathComponent("kimi-code.json")
        // Inside the renewal window, as the CLI token was from 12:59:43Z.
        try oauthJSON(
            accessToken: "code-access-token",
            refreshToken: "code-refresh-token",
            expiresAt: Date().timeIntervalSince1970 + 440,
            expiresIn: 900
        ).write(to: tokenFile)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [KimiMockURLProtocol.self]
        defer { KimiMockURLProtocol.requestHandler = nil }

        var codeRequests = 0
        KimiMockURLProtocol.requestHandler = { request in
            if let answer = webAnswer(for: request) { return answer }
            codeRequests += 1
            // Kimi Code's OAuth host rejects the renewal.
            return (HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!, Data())
        }

        let client = KimiProviderClient(
            session: URLSession(configuration: configuration),
            persistWebSessionTokens: { _ in true }
        )
        let credential = ProviderCredential(
            customEndpoint: tokenFile.path,
            extraFields: ["kimiAuthMode": "oauthFile", "kimiWebAccessToken": "web-access-token"]
        )
        let started = Date()
        let snapshot = try await client.fetchSnapshot(credentials: credential)
        try expectEqual(codeRequests, 1, "Kimi Code's renewal was attempted")
        try expectEqual(snapshot.fetchState, .success, "web-only snapshot state")
        try expect(snapshot.fetchedAt >= started.addingTimeInterval(-1), "web-only snapshot fetched_at is fresh")
        try expectEqual(snapshot.windows.map(\.label), ["5H", "Monthly"], "web-only windows")
        try expectClose(try requiredWindow("5H", in: snapshot).used, 6.65, "web 5h without Kimi Code")
        try expectEqual(
            try requiredWindow("5H", in: snapshot).resetDate,
            ISO8601DateFormatter.fractional.date(from: "2099-09-27T19:08:23.717479Z"),
            "web 5h reset without Kimi Code"
        )
        try expectClose(try requiredWindow("Monthly", in: snapshot).used, 13.28, "web monthly without Kimi Code")
        let warning = await client.takePartialRefreshWarning()
        try expect(warning?.contains("Kimi Code: Kimi rejected the saved refresh token") == true, "warning names Kimi Code's fault, got \(warning ?? "nil")")
        try expectNil(await client.takePartialRefreshWarning(), "a warning is collected once")

        // The same when the renewal fails before any request: the token
        // folder cannot be written, so the lock or the write probe throws.
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: credentialsDirectory.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: root.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: credentialsDirectory.path)
        }
        codeRequests = 0
        let beforeRequest = try await client.fetchSnapshot(credentials: credential)
        try expectEqual(codeRequests, 0, "the renewal failed before its request")
        try expectClose(try requiredWindow("5H", in: beforeRequest).used, 6.65, "web 5h after a pre-request renewal fault")
        let preRequestWarning = await client.takePartialRefreshWarning()
        try expect(preRequestWarning?.contains("~/.kimi-code") == true, "warning gives the renewal fault, got \(preRequestWarning ?? "nil")")

        // Without a web session the fault still reaches the coordinator,
        // which keeps the last snapshot and shows the message.
        do {
            _ = try await client.fetchSnapshot(
                credentials: ProviderCredential(customEndpoint: tokenFile.path, extraFields: ["kimiAuthMode": "oauthFile"])
            )
            throw TestFailure.failed("a Kimi Code fault without a web session should throw")
        } catch ProviderFetchError.credentialExpired {}
    }

    /// A source that never answers is waited for a bounded time, and the
    /// other one's reading is written without it.
    private static func testStalledSourceDoesNotHoldTheSnapshot() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [KimiMockURLProtocol.self]
        let credentials = ProviderCredential(
            accessToken: "code-access-token",
            extraFields: ["kimiWebAccessToken": "web-access-token"]
        )
        defer {
            KimiMockURLProtocol.requestHandler = nil
            KimiMockURLProtocol.delayHandler = nil
        }
        KimiMockURLProtocol.requestHandler = { request in
            if let answer = webAnswer(for: request) { return answer }
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, proUsagesJSON)
        }
        func client() -> KimiProviderClient {
            KimiProviderClient(
                session: URLSession(configuration: configuration),
                persistWebSessionTokens: { _ in true },
                codeWaitSeconds: 0.5,
                refreshBudgetSeconds: 1
            )
        }

        // kimi.ai stalls: Kimi Code's reading is written on time.
        KimiMockURLProtocol.delayHandler = { $0.url?.host == "www.kimi.ai" ? 5 : 0 }
        var started = Date()
        let webStalled = client()
        let codeOnly = try await webStalled.fetchSnapshot(credentials: credentials)
        try expect(Date().timeIntervalSince(started) < 3, "a stalled web session is not waited for")
        try expectEqual(try requiredWindow("5H", in: codeOnly).percentageUsed, 5, "Kimi Code 5h while kimi.ai stalls")
        let webWarning = await webStalled.takePartialRefreshWarning()
        try expect(webWarning?.contains("did not answer in time") == true, "stalled web warning, got \(webWarning ?? "nil")")

        // Kimi Code stalls: the web session's reading is written on time.
        KimiMockURLProtocol.delayHandler = { $0.url?.host == "www.kimi.ai" ? 0 : 5 }
        started = Date()
        let codeStalled = client()
        let webOnly = try await codeStalled.fetchSnapshot(credentials: credentials)
        try expect(Date().timeIntervalSince(started) < 3, "a stalled Kimi Code is not waited for")
        try expectClose(try requiredWindow("5H", in: webOnly).used, 6.65, "web 5h while Kimi Code stalls")
        try expectClose(try requiredWindow("Monthly", in: webOnly).used, 13.28, "web monthly while Kimi Code stalls")
        let codeWarning = await codeStalled.takePartialRefreshWarning()
        try expect(codeWarning?.contains("Kimi Code did not answer") == true, "stalled Kimi Code warning, got \(codeWarning ?? "nil")")
    }

    /// The monthly read comes after the 5-hour one; when the 5-hour read had
    /// to renew the session, the monthly read uses the renewed pair rather
    /// than presenting the spent one again.
    private static func testWebRenewalIsReusedForTheMonthlyReading() async throws {
        var refreshRequests = 0
        var staleMonthlyRequests = 0
        KimiMockURLProtocol.requestHandler = { request in
            let path = request.url?.path ?? ""
            let response = { (status: Int) in
                HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            }
            if path.contains("RefreshToken") {
                refreshRequests += 1
                return (response(200), #"{"access_token":"rotated-web-access","refresh_token":"rotated-web-refresh"}"#.data(using: .utf8)!)
            }
            let fresh = request.value(forHTTPHeaderField: "Authorization") == "Bearer rotated-web-access"
            if path.contains("GetUsages") || path.contains("GetSubscriptionStats") {
                if !fresh {
                    if path.contains("GetSubscriptionStats") { staleMonthlyRequests += 1 }
                    return (response(401), Data())
                }
                return webAnswer(for: request)!
            }
            // Kimi Code is signed out.
            return (response(401), Data())
        }
        defer { KimiMockURLProtocol.requestHandler = nil }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [KimiMockURLProtocol.self]
        let snapshot = try await KimiProviderClient(
            session: URLSession(configuration: configuration),
            persistWebSessionTokens: { _ in true }
        ).fetchSnapshot(
            credentials: ProviderCredential(
                accessToken: "code-access-token",
                extraFields: ["kimiWebAccessToken": "web-access-token", "kimiWebRefreshToken": "web-refresh"]
            )
        )
        try expectEqual(refreshRequests, 1, "one renewal serves both web reads")
        try expectEqual(staleMonthlyRequests, 0, "the monthly read presents the renewed token")
        try expectClose(try requiredWindow("Monthly", in: snapshot).used, 13.28, "web monthly after a renewal")
        try expectClose(try requiredWindow("5H", in: snapshot).used, 6.65, "web 5h after a renewal")
    }

    private static func webFiveHourJSON(used: Int, limit: Int, reset: String) -> Data {
        """
        {"usages":[{"scope":"FEATURE_CODING","detail":{"limit":"2048","used":"1"},"limits":[{"window":{"duration":300,"timeUnit":"TIME_UNIT_MINUTE"},"detail":{"limit":"\(limit)","used":"\(used)","remaining":"\(limit - used)","resetTime":"\(reset)"}}]}]}
        """.data(using: .utf8)!
    }

    private static func testMissingCLISignInAsksForFolderImport() async throws {
        let root = try temporaryDirectory().appendingPathComponent(".kimi-code", isDirectory: true)
        let credentials = root.appendingPathComponent("credentials", isDirectory: true)
        try FileManager.default.createDirectory(at: credentials, withIntermediateDirectories: true)
        try globalConfigTOML.data(using: .utf8)?.write(to: root.appendingPathComponent("config.toml"))

        let credential = ProviderCredential(
            customEndpoint: credentials.appendingPathComponent("kimi-code.json").path,
            extraFields: ["kimiAuthMode": "oauthFile"]
        )
        do {
            _ = try await KimiProviderClient().fetchSnapshot(credentials: credential)
            throw TestFailure.failed("a missing CLI sign-in should throw")
        } catch ProviderFetchError.credentialExpired(let message) {
            try expect(message.contains("kimi-code-env-0e4f99c69cc27850.json"), "missing sign-in names the slot")
            try expect(message.contains("import `~/.kimi-code`"), "missing sign-in asks for a folder import")
        }
    }

    /// The managed-provider part of the `config.toml` Kimi Code 2.1.1 wrote
    /// for a kimi.ai sign-in, with a multi-line array and a multi-line string
    /// that must not be read as tables.
    private static let globalConfigTOML = """
    # Kimi Code configuration
    default_model = "kimi-code/k3"
    system_prompt_suffix = \"\"\"
    [providers."managed:kimi-code"]
    base_url = "https://example.invalid"
    \"\"\"

    [providers."managed:kimi-code"]
    type = "kimi"
    api_key = ""
    base_url = "https://api.kimi.ai/coding/v1" # global

    [providers."managed:kimi-code".oauth]
    storage = "file"
    key = "oauth/kimi-code-env-0e4f99c69cc27850"
    oauth_host = "https://auth.kimi.ai"

    [models."kimi-code/k3"]
    provider = "managed:kimi-code"
    capabilities = [
      "thinking",
      ["nested", "]"],
    ]
    base_url = "https://example.invalid/not-the-provider"

    [services.moonshot_search]
    base_url = "https://api.kimi.ai/coding/v1/search"
    """

    private static let proUsagesJSON = """
    {
      "usages": {
        "limit_5h": { "reset_time": "2099-09-25T07:08:22Z", "used_ratio": 0.05 },
        "limit_month_code": { "reset_time": "2099-10-26T00:00:00Z", "used_ratio": 0.1 },
        "limit_month_total": { "reset_time": "2099-10-26T00:00:00Z", "used_ratio": 0.4 }
      }
    }
    """.data(using: .utf8)!

    private static func temporaryFile(named name: String, contents: String) throws -> URL {
        let directory = try temporaryDirectory()
        let url = directory.appendingPathComponent(name)
        try contents.data(using: .utf8)?.write(to: url)
        return url
    }

    private static func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private static func oauthJSON(
        accessToken: String,
        refreshToken: String = "refresh-token",
        expiresAt: TimeInterval,
        expiresIn: TimeInterval? = nil
    ) -> Data {
        """
        {
          "access_token": "\(accessToken)",
          "refresh_token": "\(refreshToken)",
          "expires_at": \(expiresAt),
          \(expiresIn.map { "\"expires_in\": \($0)," } ?? "")
          "scope": "kimi-code",
          "token_type": "Bearer"
        }
        """.data(using: .utf8)!
    }
}

private extension ISO8601DateFormatter {
    static var fractional: ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }
}

private func requestBodyString(_ request: URLRequest) -> String {
    if let body = request.httpBody {
        return String(data: body, encoding: .utf8) ?? ""
    }
    guard let stream = request.httpBodyStream else { return "" }

    stream.open()
    defer { stream.close() }
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 1024)
    while stream.hasBytesAvailable {
        let count = stream.read(&buffer, maxLength: buffer.count)
        guard count > 0 else { break }
        data.append(buffer, count: count)
    }
    return String(data: data, encoding: .utf8) ?? ""
}

private final class KimiMockURLProtocol: URLProtocol {
    static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?
    /// Seconds to hold a request's answer back, to stand in for a stalled
    /// endpoint without blocking the loading thread.
    static var delayHandler: ((URLRequest) -> TimeInterval)?
    /// Answers the `/me` request each usage fetch makes beside `/usages`;
    /// `nil` answers 404, like an endpoint without one.
    static var userInfoHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let handler = request.url?.lastPathComponent == "me"
            ? Self.userInfoHandler ?? { request in
                (HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!, Data())
            }
            : Self.requestHandler
        guard let requestHandler = handler else {
            client?.urlProtocol(self, didFailWithError: TestFailure.failed("missing Kimi request handler"))
            return
        }

        let delay = Self.delayHandler?(request) ?? 0
        let answer = { [self] in
            do {
                let (response, data) = try requestHandler(request)
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: data)
                client?.urlProtocolDidFinishLoading(self)
            } catch {
                print("Kimi mock request failed: \(error)")
                client?.urlProtocol(self, didFailWithError: error)
            }
        }
        if delay > 0 {
            DispatchQueue.global().asyncAfter(deadline: .now() + delay, execute: answer)
        } else {
            answer()
        }
    }

    override func stopLoading() {}
}
