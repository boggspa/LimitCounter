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

func expectNil<T>(_ value: T?, _ message: String) throws {
    if let value {
        throw TestFailure.failed("\(message): expected nil, got \(value)")
    }
}

@main
enum KimiUsageTestRunner {
    static func main() async throws {
        try testParsesWeeklyAndFiveHourStringQuota()
        try testParsesMissingOptionalFieldsAndUnknownMembership()
        try testParsesExhaustedWeeklyAndUnusedFiveHourQuota()
        try testImportsPlainTextAPIKey()
        try testImportsCLIOAuthJSONAsFileReference()
        try testImportsCLIOAuthDirectory()
        try await testMigratedCLIOAuthUsesCurrentKimiCodeFile()
        try await testBookmarkedLegacyOAuthRequiresCurrentFolderImport()
        try await testExpiredCLIOAuthRefreshesAndPersistsRotatedToken()
        try await testExternalRotationRecoversFromInvalidGrant()
        try await testRejectedRefreshThrowsCredentialExpired()
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

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let requestHandler = Self.requestHandler else {
            client?.urlProtocol(self, didFailWithError: TestFailure.failed("missing Kimi request handler"))
            return
        }

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

    override func stopLoading() {}
}
