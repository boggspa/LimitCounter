import Foundation

private struct Failure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

private func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !condition() { throw Failure(message) }
}

private let now = Date()
private func row(_ name: String = "general") -> [String: Any] {
    [
        "model_name": name,
        "start_time": (now.timeIntervalSince1970 - 3_600) * 1000,
        "end_time": (now.timeIntervalSince1970 + 14_400) * 1000,
        "weekly_end_time": (now.timeIntervalSince1970 + 345_600) * 1000,
        "current_interval_total_count": 1000,
        "current_interval_usage_count": 750,
        "current_weekly_total_count": 10_000,
        "current_weekly_usage_count": 4000
    ]
}

private func payload(_ rows: [[String: Any]], code: Int = 0) throws -> Data {
    try JSONSerialization.data(withJSONObject: [
        "base_resp": ["status_code": code, "status_msg": "fixture"], "model_remains": rows
    ])
}

private func snapshot(_ rows: [[String: Any]]) throws -> QuotaSnapshot {
    try MiniMaxQuotaParser.snapshot(data: payload(rows), fetchedAt: now)
}

private final class QuotaURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var status = 200
    nonisolated(unsafe) static var body = Data()
    nonisolated(unsafe) static var requests: [URLRequest] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requests.append(request)
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.status,
                                       httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@main
private enum MiniMaxUsageTests {
    static func main() async throws {
        let cases: [(String, () throws -> Void)] = [
            ("legacy counts mean remaining; reset timestamps are milliseconds", {
                let reading = try snapshot([row("MiniMax-M*")])
                try expect(reading.windows.map(\.used) == [25, 60], "legacy usage reversed")
                try expect(reading.windows.map(\.windowKind) == [.session, .weekly], "wrong period")
                try expect(reading.windows.allSatisfy { $0.unit == "%" && $0.total == 100 }, "invented token units")
                try expect(abs(reading.windows[0].resetDate!.timeIntervalSince(now) - 14_400) < 0.01, "wrong 5h reset")
                try expect(abs(reading.windows[1].resetDate!.timeIntervalSince(now) - 345_600) < 0.01, "wrong weekly reset")
            }),
            ("explicit remaining percentages cover new consumed counts", {
                var value = row()
                value["current_interval_usage_count"] = 150
                value["current_interval_remaining_percent"] = 85
                value["current_weekly_remaining_percent"] = 63.5
                try expect(try snapshot([value]).windows.map(\.used) == [15, 36.5], "percentage was inverted")
            }),
            ("zero usage stays zero with a fully remaining percentage", {
                var value = row()
                value["current_interval_usage_count"] = 0
                value["current_interval_remaining_percent"] = 100
                value["current_weekly_remaining_percent"] = 100
                try expect(try snapshot([value]).windows.map(\.used) == [0, 0], "fresh plan shown exhausted")
            }),
            ("the shared general bucket takes precedence over legacy model rows", {
                var shared = row()
                shared["current_interval_remaining_percent"] = 90
                let reading = try snapshot([row("speech-hd"), row("MiniMax-M*"), shared, row("MiniMax-M3")])
                try expect(reading.windows.count == 2 && reading.windows[0].used == 10, "duplicated shared allowance")
            }),
            ("wildcard text quota is not added to individual model quotas", {
                let reading = try snapshot([row("MiniMax-M*"), row("MiniMax-M2.7"), row("image-01")])
                try expect(reading.windows.count == 2, "duplicated legacy allowance")
            }),
            ("distinct legacy text buckets remain separately labelled", {
                let reading = try snapshot([row("MiniMax-M3"), row("MiniMax-M2.7")])
                try expect(reading.windows.count == 4, "lost distinct legacy quota")
                try expect(reading.windows[2].label.contains("MiniMax-M2.7"), "lost model label")
            }),
            ("unlimited weekly status does not become an exhausted quota", {
                var value = row()
                value["current_weekly_status"] = 3
                value["current_weekly_total_count"] = 0
                let weekly = try snapshot([value]).windows[1]
                try expect(weekly.total == nil && weekly.subtitle == "Unlimited", "invented weekly cap")
            }),
            ("no-plan sentinel is not unlimited access", {
                var value = row()
                for prefix in ["current_interval_", "current_weekly_"] {
                    value[prefix + "total_count"] = 0
                    value[prefix + "status"] = 3
                }
                do { _ = try snapshot([value]); throw Failure("no plan accepted") }
                catch ProviderFetchError.parsingError { }
            }),
            ("weekly boosts retain the allowance note and normalized fraction", {
                var value = row()
                value["weekly_boost_permille"] = 1500
                value["current_weekly_remaining_percent"] = 80
                let weekly = try snapshot([value]).windows[1]
                try expect(weekly.used == 20 && weekly.subtitle == "1.5× weekly allowance", "lost boost")
            }),
            ("missing legacy weekly allowance is omitted", {
                var value = row()
                value["current_weekly_total_count"] = 0
                try expect(try snapshot([value]).windows.count == 1, "invented weekly meter")
            }),
            ("invalid percentages never fall back to ambiguous counts", {
                var value = row()
                value["current_interval_remaining_percent"] = -1
                value["current_weekly_remaining_percent"] = 101
                do { _ = try snapshot([value]); throw Failure("invalid percentages accepted") }
                catch ProviderFetchError.parsingError { }
            }),
            ("relative resets are a milliseconds fallback", {
                var value = row()
                value.removeValue(forKey: "end_time")
                value["remains_time"] = 120_000
                let current = try snapshot([value]).windows[0]
                try expect(current.resetDate == now.addingTimeInterval(120), "wrong relative reset")
            }),
            ("auth errors and malformed payloads cannot become success", {
                do { _ = try MiniMaxQuotaParser.snapshot(data: payload([row()], code: 1004)); throw Failure("auth accepted") }
                catch ProviderFetchError.invalidCredential { }
                for data in [Data("<html>Login</html>".utf8), try payload([]), Data("{}".utf8)] {
                    do { _ = try MiniMaxQuotaParser.snapshot(data: data); throw Failure("bad response accepted") }
                    catch ProviderFetchError.parsingError { }
                }
            }),
            ("MiniMax identity, storage and setup preserve the dedicated key", {
                try expect(ProviderID.userFacingCases.contains(.minimax), "missing provider")
                try expect(ProviderID.minimax.accentColorHex == "#C044A4", "accent drift")
                let draft = ProviderSetupPolicy.Draft(accessToken: "sk-cp-fixture")
                let input = ProviderSetupPolicy.saveInput(for: draft, providerID: .minimax, now: now)
                try expect(input.bookmarkSourceURL == nil, "key treated as folder")
                let credential = ProviderSetupPolicy.credential(from: draft, providerID: .minimax, extraFields: input.extraFields)
                try expect(credential.accessToken == "sk-cp-fixture", "key was not retained")
                let reading = try snapshot([row()])
                let decoded = try JSONDecoder().decode(QuotaSnapshot.self, from: JSONEncoder().encode(reading))
                try expect(decoded.providerID == .minimax && decoded.windows == reading.windows, "snapshot cannot sync")
                try expect(ProviderAccountKey(providerID: .minimax, slot: "work") != ProviderAccountKey(providerID: .minimax), "account slots collapsed")
            })
        ]
        for (name, test) in cases {
            try test()
            print("PASS \(name)")
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [QuotaURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let client = MiniMaxProviderClient(session: session)
        QuotaURLProtocol.body = try payload([row()])
        let credentials = ProviderCredential(accessToken: " sk-cp-fixture ", accountIdentifier: nil,
                                             customEndpoint: "https://example.invalid")
        let reading = try await client.fetchSnapshot(credentials: credentials)
        try expect(reading.providerID == .minimax, "wrong HTTP snapshot identity")
        let request = QuotaURLProtocol.requests.last!
        try expect(request.url == MiniMaxProviderClient.quotaURL && request.url?.query == nil, "key endpoint changed")
        try expect(request.httpMethod == "GET" && request.httpBody == nil, "quota fetch sent inference")
        try expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer sk-cp-fixture", "wrong auth")
        try expect(!request.httpShouldHandleCookies, "unexpected browser session use")
        print("PASS dedicated quota request and subscription auth")
        for status in [401, 403, 429, 503] {
            QuotaURLProtocol.status = status
            do { _ = try await client.fetchSnapshot(credentials: credentials); throw Failure("HTTP \(status) accepted") }
            catch ProviderFetchError.invalidCredential where status == 401 || status == 403 { }
            catch ProviderFetchError.rateLimited where status == 429 { }
            catch ProviderFetchError.parsingError where status == 503 { }
        }
        print("PASS HTTP failure classification")
        let requestsBefore = QuotaURLProtocol.requests.count
        do { _ = try await client.fetchSnapshot(credentials: nil); throw Failure("missing key accepted") }
        catch ProviderFetchError.notConfigured { }
        try expect(QuotaURLProtocol.requests.count == requestsBefore, "request made without a key")
        print("PASS no network request before setup")
        print("MiniMax: \(cases.count + 3) tests passed")
    }
}
