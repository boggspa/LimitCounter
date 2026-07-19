import Foundation
import XCTest
@testable import CodexUsageKit

final class CodexUsageClientTests: XCTestCase {
    override func tearDown() {
        super.tearDown()
        MockURLProtocol.requestHandler = nil
    }

    func testFetchesAndNormalizesUsageSnapshot() async throws {
        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.url?.absoluteString, "https://example.test/usage")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer access-token")
            XCTAssertEqual(request.value(forHTTPHeaderField: "chatgpt-account-id"), "account-id")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")

            let data = Data("""
            {
              "plan_type": "pro",
              "rate_limit": {
                "primary_window": {
                  "used_percent": 42,
                  "limit_window_seconds": 18000,
                  "reset_after_seconds": 3600,
                  "reset_at": 1893456000
                },
                "secondary_window": {
                  "used_percent": 20,
                  "limit_window_seconds": 604800,
                  "reset_after_seconds": 7200,
                  "reset_at": 1893542400
                }
              },
              "additional_rate_limits": [
                {
                  "limit_name": "GPT-5.3-Codex-Spark",
                  "rate_limit": {
                    "primary_window": {
                      "used_percent": 10,
                      "limit_window_seconds": 18000,
                      "reset_after_seconds": 1800,
                      "reset_at": 1893459600
                    },
                    "secondary_window": {
                      "used_percent": 80,
                      "limit_window_seconds": 604800,
                      "reset_after_seconds": 7200,
                      "reset_at": 1893542400
                    }
                  }
                }
              ],
              "credits": { "balance": 12.5 }
            }
            """.utf8)

            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, data)
        }

        let client = CodexUsageClient(session: makeMockSession(), endpointURL: URL(string: "https://example.test/usage")!)
        let credential = try CodexUsageCredential(accessToken: "access-token", accountID: "account-id")

        let snapshot = try await client.fetchSnapshot(credential: credential)

        XCTAssertEqual(snapshot.providerID, .codex)
        XCTAssertEqual(snapshot.displayName, "Codex")
        XCTAssertEqual(snapshot.planName, "Pro")
        XCTAssertEqual(snapshot.fetchState, .success)
        XCTAssertEqual(snapshot.windows.count, 2)
        XCTAssertEqual(snapshot.windows[0].label, "Weekly")
        XCTAssertEqual(snapshot.windows[0].windowKind, .weekly)
        XCTAssertEqual(snapshot.windows[0].percentageUsed, 20)
        XCTAssertEqual(snapshot.windows[1].label, "GPT-5.3-Codex-Spark Weekly")
        XCTAssertEqual(snapshot.windows[1].windowKind, .weekly)
        XCTAssertEqual(snapshot.windows[1].used, 134.4, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(snapshot.windows[1].total), 168, accuracy: 0.0001)
        XCTAssertEqual(snapshot.windows[1].percentageUsed, 80)
        XCTAssertEqual(snapshot.windows[1].resetDate, Date(timeIntervalSince1970: 1_893_542_400))
        XCTAssertEqual(snapshot.balances.first?.label, "Credits Remaining")
        XCTAssertEqual(snapshot.balances.first?.amount, 12.5)
    }

    func testIncludesNamedWeeklyWindowForSpark() async throws {
        MockURLProtocol.requestHandler = { request in
            let data = Data("""
            {
              "rate_limit": {
                "secondary_window": {
                  "used_percent": 100,
                  "limit_window_seconds": 604800,
                  "reset_after_seconds": 172800,
                  "reset_at": 1893628800
                }
              },
              "additional_rate_limits": [
                {
                  "limit_name": "GPT-5.3-Codex-Spark",
                  "rate_limit": {
                    "secondary_window": {
                      "used_percent": 0,
                      "limit_window_seconds": 604800,
                      "reset_after_seconds": 604800,
                      "reset_at": 1894060800
                    }
                  }
                }
              ]
            }
            """.utf8)

            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, data)
        }

        let client = CodexUsageClient(session: makeMockSession(), endpointURL: URL(string: "https://example.test/usage")!)
        let credential = try CodexUsageCredential(accessToken: "access-token", accountID: "account-id")

        let snapshot = try await client.fetchSnapshot(credential: credential)
        let labels = snapshot.windows.map(\.label)

        XCTAssertEqual(labels, ["Weekly", "GPT-5.3-Codex-Spark Weekly"])
        XCTAssertEqual(snapshot.windows.map(\.percentageUsed), [100, 0])
    }

    func testRecognizesWeeklyAggregateWhenReturnedAsPrimary() async throws {
        MockURLProtocol.requestHandler = { request in
            let data = Data("""
            {
              "plan_type": "pro",
              "rate_limit": {
                "primary_window": {
                  "used_percent": 33,
                  "limit_window_seconds": 604800,
                  "reset_after_seconds": 580000,
                  "reset_at": 1784492408
                }
              },
              "additional_rate_limits": [
                {
                  "limit_name": "GPT-5.3-Codex-Spark",
                  "metered_feature": "codex_bengalfox",
                  "rate_limit": {
                    "primary_window": {
                      "used_percent": 6,
                      "limit_window_seconds": 604800,
                      "reset_after_seconds": 580000,
                      "reset_at": 1784493835
                    }
                  }
                }
              ]
            }
            """.utf8)

            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, data)
        }

        let client = CodexUsageClient(session: makeMockSession(), endpointURL: URL(string: "https://example.test/usage")!)
        let credential = try CodexUsageCredential(accessToken: "access-token", accountID: "account-id")

        let snapshot = try await client.fetchSnapshot(credential: credential)

        XCTAssertEqual(snapshot.windows.map(\.label), ["Weekly", "GPT-5.3-Codex-Spark Weekly"])
        XCTAssertEqual(snapshot.windows.map(\.percentageUsed), [33, 6])
        XCTAssertEqual(snapshot.windows[0].windowKind, .weekly)
        XCTAssertEqual(snapshot.windows[1].windowKind, .weekly)
        XCTAssertEqual(try XCTUnwrap(snapshot.windows[0].total), 168, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(snapshot.windows[1].total), 168, accuracy: 0.0001)
    }

    func testIgnoresOtherNamedFiveHourLimits() async throws {
        MockURLProtocol.requestHandler = { request in
            let data = Data("""
            {
              "rate_limit": {
                "secondary_window": {
                  "used_percent": 35,
                  "limit_window_seconds": 604800,
                  "reset_after_seconds": 172800,
                  "reset_at": 1893628800
                }
              },
              "additional_rate_limits": [
                {
                  "limit_name": "GPT-5.5",
                  "rate_limit": {
                    "primary_window": {
                      "used_percent": 80,
                      "limit_window_seconds": 18000,
                      "reset_after_seconds": 176400,
                      "reset_at": 1893632400
                    }
                  }
                }
              ]
            }
            """.utf8)

            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, data)
        }

        let client = CodexUsageClient(session: makeMockSession(), endpointURL: URL(string: "https://example.test/usage")!)
        let credential = try CodexUsageCredential(accessToken: "access-token", accountID: "account-id")

        let snapshot = try await client.fetchSnapshot(credential: credential)
        let labels = snapshot.windows.map(\.label)

        XCTAssertEqual(labels, ["Weekly"])
    }

    func testDecodesStringCreditBalance() async throws {
        MockURLProtocol.requestHandler = { request in
            let data = Data("""
            {
              "rate_limit": {
                "primary_window": {
                  "used_percent": 1,
                  "limit_window_seconds": 18000,
                  "reset_after_seconds": 3600,
                  "reset_at": 1893456000
                }
              },
              "credits": { "balance": "7.25" }
            }
            """.utf8)

            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, data)
        }

        let client = CodexUsageClient(session: makeMockSession(), endpointURL: URL(string: "https://example.test/usage")!)
        let credential = try CodexUsageCredential(accessToken: "access-token", accountID: "account-id")

        let snapshot = try await client.fetchSnapshot(credential: credential)

        XCTAssertEqual(snapshot.balances.first?.amount, 7.25)
    }

    func testHTTPErrorMapping() async throws {
        let cases: [(Int, CodexUsageError)] = [
            (401, .invalidCredential),
            (403, .invalidCredential),
            (429, .rateLimited),
            (500, .unexpectedStatusCode(500))
        ]

        for (statusCode, expectedError) in cases {
            MockURLProtocol.requestHandler = { request in
                let data = Data("{}".utf8)
                return (HTTPURLResponse(url: request.url!, statusCode: statusCode, httpVersion: nil, headerFields: nil)!, data)
            }

            let client = CodexUsageClient(session: makeMockSession(), endpointURL: URL(string: "https://example.test/usage")!)
            let credential = try CodexUsageCredential(accessToken: "access-token", accountID: "account-id")

            do {
                _ = try await client.fetchSnapshot(credential: credential)
                XCTFail("Expected \(expectedError)")
            } catch {
                XCTAssertEqual(error as? CodexUsageError, expectedError)
            }
        }
    }

    func testNonJSONAndSchemaDriftReturnDecodingFailed() async throws {
        let fixtures = [
            "not-json",
            "{}"
        ]

        for fixture in fixtures {
            MockURLProtocol.requestHandler = { request in
                let data = Data(fixture.utf8)
                return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, data)
            }

            let client = CodexUsageClient(session: makeMockSession(), endpointURL: URL(string: "https://example.test/usage")!)
            let credential = try CodexUsageCredential(accessToken: "access-token", accountID: "account-id")

            do {
                _ = try await client.fetchSnapshot(credential: credential)
                XCTFail("Expected decoding failure")
            } catch {
                XCTAssertEqual(error as? CodexUsageError, .decodingFailed)
            }
        }
    }

    private func makeMockSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: configuration)
    }
}

private final class MockURLProtocol: URLProtocol {
    static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.requestHandler else {
            client?.urlProtocol(self, didFailWithError: CodexUsageError.networkFailed)
            return
        }

        do {
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
