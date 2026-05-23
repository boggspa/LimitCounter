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
                  "limit_name": "GPT-5.5",
                  "rate_limit": {
                    "primary_window": {
                      "used_percent": 10,
                      "limit_window_seconds": 18000,
                      "reset_after_seconds": 1800,
                      "reset_at": 1893459600
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
        XCTAssertEqual(snapshot.windows.count, 3)
        XCTAssertEqual(snapshot.windows[0].label, "Session")
        XCTAssertEqual(snapshot.windows[0].windowKind, .session)
        XCTAssertEqual(snapshot.windows[0].used, 2.1, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(snapshot.windows[0].total), 5, accuracy: 0.0001)
        XCTAssertEqual(snapshot.windows[0].percentageUsed, 42)
        XCTAssertEqual(snapshot.windows[0].resetDate, Date(timeIntervalSince1970: 1_893_456_000))
        XCTAssertEqual(snapshot.windows[1].label, "Weekly")
        XCTAssertEqual(snapshot.windows[2].label, "GPT-5.5 5h")
        XCTAssertEqual(snapshot.balances.first?.label, "Credits Remaining")
        XCTAssertEqual(snapshot.balances.first?.amount, 12.5)
    }

    func testSuppressesStaleAggregateWindowWhenNamedLimitHasReset() async throws {
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
                  "limit_name": "GPT-5.5",
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

        XCTAssertFalse(labels.contains("Weekly"))
        XCTAssertEqual(labels, ["GPT-5.5 Weekly"])
        XCTAssertEqual(snapshot.windows.first?.percentageUsed, 0)
    }

    func testKeepsSaturatedAggregateWindowWithoutFreshNamedReset() async throws {
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
                  "limit_name": "GPT-5.5",
                  "rate_limit": {
                    "secondary_window": {
                      "used_percent": 80,
                      "limit_window_seconds": 604800,
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

        XCTAssertEqual(labels, ["Weekly", "GPT-5.5 Weekly"])
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
