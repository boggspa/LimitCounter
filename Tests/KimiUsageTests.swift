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
        try testImportsPlainTextAPIKey()
        try testImportsCLIOAuthJSONAsFileReference()
        try testImportsCLIOAuthDirectory()
        try await testExpiredCLIOAuthThrowsCredentialExpired()
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
        let root = try temporaryDirectory()
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

    private static func testExpiredCLIOAuthThrowsCredentialExpired() async throws {
        let url = try temporaryFile(
            named: "kimi-code.json",
            contents: """
            {
              "access_token": "expired-access-token",
              "refresh_token": "redacted-refresh-token",
              "expires_at": 1,
              "scope": "kimi-code",
              "token_type": "Bearer"
            }
            """
        )

        let credential = ProviderCredential(
            customEndpoint: url.path,
            extraFields: ["kimiAuthMode": "oauthFile"]
        )

        do {
            _ = try await KimiProviderClient().fetchSnapshot(credentials: credential)
            throw TestFailure.failed("expired CLI OAuth should throw")
        } catch ProviderFetchError.credentialExpired(let message) {
            try expect(message.contains("Kimi CLI OAuth token is expired"), "expired credential message")
        }
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
}
