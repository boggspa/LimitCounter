import CoreFoundation
import Foundation

/// Token Plan quota uses a Subscription Key and is independent of inference.
/// Endpoint and response semantics follow MiniMax-AI/cli's quota SDK:
/// https://github.com/MiniMax-AI/cli/tree/main/src/sdk/quota
public struct MiniMaxProviderClient: ProviderClient {
    public let providerID: ProviderID = .minimax
    private let session: URLSession
    static let quotaURL = URL(string: "https://api.minimax.io/v1/token_plan/remains")!
    static let balanceURL = URL(string: "https://api.minimax.io/account/query_balance")!
    static let balanceAPIKeyField = "minimaxBalanceAPIKey"

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func fetchSnapshot(credentials: ProviderCredential?) async throws -> QuotaSnapshot {
        let key = credentials?.accessToken?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let balanceKey = credentials?.extraFields?[Self.balanceAPIKeyField]?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !key.isEmpty || !balanceKey.isEmpty else {
            throw ProviderFetchError.notConfigured
        }

        // MiniMax's official CLI selects account/query_balance for sk-api keys.
        // A Subscription Key continues to read only its Token Plan allowance.
        if key.hasPrefix("sk-api-") || key.isEmpty {
            let data = try await fetchData(url: Self.balanceURL, key: key.isEmpty ? balanceKey : key)
            let balance = try MiniMaxQuotaParser.balance(data: data)
            return QuotaSnapshot(providerID: .minimax, displayName: ProviderID.minimax.displayName,
                                 planName: "API Credits", balances: [balance])
        }

        let data = try await fetchData(url: Self.quotaURL, key: key)
        let quota = try MiniMaxQuotaParser.snapshot(data: data)
        guard !balanceKey.isEmpty else { return quota }
        do {
            // Leave room inside the provider refresh deadline to return the
            // successful quota reading when this supplemental request stalls.
            let balanceData = try await fetchData(url: Self.balanceURL, key: balanceKey, timeout: 3)
            let balance = try MiniMaxQuotaParser.balance(data: balanceData)
            return QuotaSnapshot(providerID: quota.providerID, displayName: quota.displayName,
                                 planName: quota.planName, windows: quota.windows,
                                 balances: [balance], fetchedAt: quota.fetchedAt)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // A missing paid-credit reading must never hide valid plan meters.
            // Leaving the balance absent lets the Usage Credits row show unknown.
            return quota
        }
    }

    private func fetchData(url: URL, key: String, timeout: TimeInterval = 15) async throws -> Data {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData,
                                 timeoutInterval: timeout)
        request.httpMethod = "GET"
        request.httpShouldHandleCookies = false
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request, delegate: MiniMaxQuotaRedirectPolicy())
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw ProviderFetchError.networkError(underlying: error)
        }
        guard let http = response as? HTTPURLResponse else {
            throw ProviderFetchError.unknown
        }
        switch http.statusCode {
        case 200...299: break
        case 401, 403: throw ProviderFetchError.invalidCredential
        case 429: throw ProviderFetchError.rateLimited
        default:
            throw ProviderFetchError.parsingError("MiniMax quota request returned HTTP \(http.statusCode).")
        }
        return data
    }
}

private final class MiniMaxQuotaRedirectPolicy: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

enum MiniMaxQuotaParser {
    static func snapshot(data: Data, fetchedAt: Date = Date()) throws -> QuotaSnapshot {
        let root = try validatedRoot(data: data)
        guard let rows = root["model_remains"] as? [[String: Any]] else {
            throw ProviderFetchError.parsingError("MiniMax did not return Token Plan quota data.")
        }

        // Upgraded plans use one general bucket across capabilities. Legacy
        // plans expose MiniMax-M* or individual text-model buckets. Never add
        // duplicate rows together or label these allowance units as tokens.
        let general = rows.first { name($0) == "general" }
        let wildcard = rows.first { name($0) == "minimax-m*" }
        let selected = (general ?? wildcard).map { [$0] }
            ?? rows.filter { name($0).hasPrefix("minimax-") }
        var windows: [QuotaWindow] = []
        for row in selected {
            let noBucket = number(row["current_interval_total_count"]) == 0
                && number(row["current_weekly_total_count"]) == 0
                && number(row["current_interval_status"]) == 3
                && number(row["current_weekly_status"]) == 3
            if noBucket { continue }
            let prefix = selected.count > 1 ? "\(row["model_name"] as? String ?? "MiniMax") · " : ""
            let start = number(row["start_time"])
            let end = number(row["end_time"])
            let duration = start.flatMap { first in end.map { $0 - first } }
            let daily = duration == 86_400_000
            if let current = window(row, weekly: false, label: prefix + (daily ? "Daily" : "5-hour"),
                                    kind: daily ? .daily : .session, fetchedAt: fetchedAt) {
                windows.append(current)
            }
            if let weekly = window(row, weekly: true, label: prefix + "Weekly",
                                   kind: .weekly, fetchedAt: fetchedAt) {
                windows.append(weekly)
            }
        }
        guard !windows.isEmpty else {
            throw ProviderFetchError.parsingError("No usable MiniMax Token Plan quota was returned. Check your Subscription Key and plan in the MiniMax console.")
        }
        return QuotaSnapshot(providerID: .minimax, displayName: ProviderID.minimax.displayName,
                             planName: "Token Plan", windows: windows, fetchedAt: fetchedAt)
    }

    /// `available_amount` is the provider's total, not a sum of the overlapping
    /// cash/voucher/credit fields. The API does not identify its currency.
    static func balance(data: Data) throws -> QuotaBalance {
        let root = try validatedRoot(data: data)
        guard root["base_resp"] is [String: Any],
              let raw = root["available_amount"] as? String,
              let amount = Double(raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              amount.isFinite else {
            throw ProviderFetchError.parsingError("MiniMax did not return a readable account balance.")
        }
        return QuotaBalance(label: "Usage Credits", amount: amount, unit: "",
                            subtitle: "Available account balance · MiniMax API")
    }

    private static func validatedRoot(data: Data) throws -> [String: Any] {
        guard data.count <= 1_048_576,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ProviderFetchError.parsingError("MiniMax returned an invalid quota response.")
        }
        if let base = root["base_resp"] as? [String: Any] {
            guard let status = number(base["status_code"]) else {
                throw ProviderFetchError.parsingError("MiniMax omitted its quota response status.")
            }
            if status == 1004 { throw ProviderFetchError.invalidCredential }
            if status == 1002 { throw ProviderFetchError.rateLimited }
            guard status == 0 else {
                throw ProviderFetchError.parsingError("MiniMax quota request failed (code \(status)).")
            }
        }
        return root
    }

    private static func window(_ row: [String: Any], weekly: Bool, label: String,
                               kind: QuotaWindowKind, fetchedAt: Date) -> QuotaWindow? {
        let prefix = weekly ? "current_weekly_" : "current_interval_"
        let status = number(row[prefix + "status"])
        let end = number(row[weekly ? "weekly_end_time" : "end_time"])
        let remainingTime = number(row[weekly ? "weekly_remains_time" : "remains_time"])
        let reset = end.flatMap { $0 > 0 ? Date(timeIntervalSince1970: $0 / 1000) : nil }
            ?? remainingTime.flatMap { $0 >= 0 ? fetchedAt.addingTimeInterval($0 / 1000) : nil }
        if status == 3 {
            return QuotaWindow(label: label, windowKind: kind, used: 0, resetDate: reset,
                               unit: "%", subtitle: "Unlimited")
        }

        let remaining: Double
        if let percent = number(row[prefix + "remaining_percent"]), (0...100).contains(percent) {
            // The explicit percentage is authoritative across both versions
            // of *_usage_count (remaining in legacy responses; used in newer ones).
            remaining = percent
        } else if status == 2 {
            remaining = 0
        } else if row[prefix + "remaining_percent"] != nil
                    && !(row[prefix + "remaining_percent"] is NSNull) {
            return nil
        } else if let total = number(row[prefix + "total_count"]), total > 0,
                  let count = number(row[prefix + "usage_count"]), (0...total).contains(count) {
            remaining = count / total * 100
        } else {
            return nil
        }
        var subtitle: String? = nil
        if weekly, let boost = number(row["weekly_boost_permille"]), boost > 0, boost != 1000 {
            subtitle = String(format: "%.3g× weekly allowance", boost / 1000)
        }
        return QuotaWindow(label: label, windowKind: kind, used: 100 - remaining, total: 100,
                           resetDate: reset, unit: "%", subtitle: subtitle)
    }

    private static func name(_ row: [String: Any]) -> String {
        (row["model_name"] as? String ?? "").lowercased()
    }

    private static func number(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite else { return nil }
        return number.doubleValue
    }
}
