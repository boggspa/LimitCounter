import Foundation

public struct CodexUsageClient: Sendable {
    private let session: URLSession
    private let endpointURL: URL
    private let decoder: JSONDecoder

    public init(
        session: URLSession = .shared,
        endpointURL: URL = URL(string: "https://chatgpt.com/backend-api/wham/usage")!
    ) {
        self.session = session
        self.endpointURL = endpointURL
        self.decoder = JSONDecoder()
    }

    public func fetchSnapshot(credential: CodexUsageCredential) async throws -> QuotaSnapshot {
        let request = makeRequest(credential: credential)
        let data: Data
        let response: URLResponse

        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw CodexUsageError.networkFailed
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw CodexUsageError.invalidResponse
        }

        switch httpResponse.statusCode {
        case 200..<300:
            break
        case 401, 403:
            throw CodexUsageError.invalidCredential
        case 429:
            throw CodexUsageError.rateLimited
        default:
            throw CodexUsageError.unexpectedStatusCode(httpResponse.statusCode)
        }

        do {
            let payload = try decoder.decode(CodexUsagePayload.self, from: data)
            guard payload.hasUsableContent else {
                throw CodexUsageError.decodingFailed
            }
            return normalize(payload: payload)
        } catch let error as CodexUsageError {
            throw error
        } catch {
            throw CodexUsageError.decodingFailed
        }
    }

    private func makeRequest(credential: CodexUsageCredential) -> URLRequest {
        var request = URLRequest(url: endpointURL)
        request.httpMethod = "GET"
        request.setValue("Bearer \(credential.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(credential.accountID, forHTTPHeaderField: "chatgpt-account-id")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    private func normalize(payload: CodexUsagePayload) -> QuotaSnapshot {
        let now = Date()
        var aggregateWindows: [QuotaWindow] = []
        var additionalWindows: [QuotaWindow] = []
        var balances: [QuotaBalance] = []

        if let primary = payload.primaryWindow {
            aggregateWindows.append(
                quotaWindow(
                    from: primary,
                    label: "Session",
                    windowKind: .session,
                    subtitle: "5-hour rolling window"
                )
            )
        }

        if let secondary = payload.secondaryWindow {
            aggregateWindows.append(
                quotaWindow(
                    from: secondary,
                    label: "Weekly",
                    windowKind: .weekly,
                    subtitle: "7-day rolling window"
                )
            )
        }

        for additionalLimit in payload.additionalRateLimits {
            guard let rateLimit = additionalLimit.rateLimit else { continue }
            let name = additionalLimit.displayName

            if let primary = rateLimit.primaryWindow {
                additionalWindows.append(
                    quotaWindow(
                        from: primary,
                        label: "\(name) 5h",
                        windowKind: .session,
                        subtitle: "5-hour usage limit"
                    )
                )
            }

            if let secondary = rateLimit.secondaryWindow {
                additionalWindows.append(
                    quotaWindow(
                        from: secondary,
                        label: "\(name) Weekly",
                        windowKind: .weekly,
                        subtitle: "7-day usage limit"
                    )
                )
            }
        }

        if let balance = payload.credits?.balance {
            balances.append(
                QuotaBalance(
                    label: "Credits Remaining",
                    amount: balance,
                    unit: "credits",
                    subtitle: "Use credits beyond plan limits"
                )
            )
        }

        return QuotaSnapshot(
            providerID: .codex,
            displayName: "Codex",
            planName: chatGPTPlanName(from: payload.planType),
            windows: reconciledCodexWindows(
                aggregateWindows: aggregateWindows,
                additionalWindows: additionalWindows
            ),
            balances: balances,
            fetchState: .success,
            fetchedAt: now
        )
    }

    private func quotaWindow(
        from window: CodexWindow,
        label: String,
        windowKind: QuotaWindowKind,
        subtitle: String
    ) -> QuotaWindow {
        let totalSeconds = Double(window.limitWindowSeconds)
        let usedSeconds = totalSeconds * (window.usedPercent / 100.0)
        let resetDate = Date(timeIntervalSince1970: Double(window.resetAt))

        return QuotaWindow(
            label: label,
            windowKind: windowKind,
            used: usedSeconds / 3_600.0,
            total: totalSeconds / 3_600.0,
            resetDate: resetDate,
            unit: "hrs",
            subtitle: subtitle
        )
    }

    private func reconciledCodexWindows(
        aggregateWindows: [QuotaWindow],
        additionalWindows: [QuotaWindow]
    ) -> [QuotaWindow] {
        let activeAggregateWindows = aggregateWindows.filter {
            !isStaleAggregateWindow($0, comparedTo: additionalWindows)
        }
        return activeAggregateWindows + additionalWindows
    }

    private func isStaleAggregateWindow(
        _ aggregateWindow: QuotaWindow,
        comparedTo additionalWindows: [QuotaWindow]
    ) -> Bool {
        guard let aggregateTotal = aggregateWindow.total,
              aggregateTotal > 0,
              let aggregateResetDate = aggregateWindow.resetDate,
              usageFraction(for: aggregateWindow) >= 0.98 else {
            return false
        }

        let resetShiftThreshold = staleAggregateResetShiftThreshold(for: aggregateWindow)

        return additionalWindows.contains { additionalWindow in
            guard additionalWindow.windowKind == aggregateWindow.windowKind,
                  let additionalTotal = additionalWindow.total,
                  additionalTotal > 0,
                  let additionalResetDate = additionalWindow.resetDate,
                  abs(additionalTotal - aggregateTotal) <= max(0.01, aggregateTotal * 0.05),
                  usageFraction(for: additionalWindow) <= 0.20 else {
                return false
            }

            return additionalResetDate.timeIntervalSince(aggregateResetDate) >= resetShiftThreshold
        }
    }

    private func usageFraction(for window: QuotaWindow) -> Double {
        guard let total = window.total, total > 0 else { return 0 }
        return min(max(window.used / total, 0), 1)
    }

    private func staleAggregateResetShiftThreshold(for window: QuotaWindow) -> TimeInterval {
        guard let totalHours = window.total, totalHours > 0 else {
            return 30 * 60
        }

        let duration = totalHours * 3_600
        return min(max(duration * 0.05, 30 * 60), 12 * 60 * 60)
    }

    private func chatGPTPlanName(from planType: String?) -> String {
        guard let planType = planType?.trimmingCharacters(in: .whitespacesAndNewlines),
              !planType.isEmpty else {
            return "Plan"
        }

        switch planType.lowercased() {
        case "plus":
            return "Plus"
        case "pro":
            return "Pro"
        case "go":
            return "Go"
        case "free":
            return "Free"
        default:
            return planType.capitalized
        }
    }
}

private struct CodexUsagePayload: Decodable {
    let rateLimit: CodexRateLimit?
    let additionalRateLimits: [CodexAdditionalRateLimit]
    let credits: CodexCredits?
    let planType: String?

    enum CodingKeys: String, CodingKey {
        case rateLimit = "rate_limit"
        case additionalRateLimits = "additional_rate_limits"
        case credits
        case planType = "plan_type"
    }

    var primaryWindow: CodexWindow? { rateLimit?.primaryWindow }
    var secondaryWindow: CodexWindow? { rateLimit?.secondaryWindow }
    var hasUsableContent: Bool {
        primaryWindow != nil
            || secondaryWindow != nil
            || !additionalRateLimits.isEmpty
            || credits != nil
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        rateLimit = try container.decodeIfPresent(CodexRateLimit.self, forKey: .rateLimit)
        additionalRateLimits = try container.decodeIfPresent([CodexAdditionalRateLimit].self, forKey: .additionalRateLimits) ?? []
        credits = try container.decodeIfPresent(CodexCredits.self, forKey: .credits)
        planType = try container.decodeIfPresent(String.self, forKey: .planType)
    }
}

private struct CodexRateLimit: Decodable {
    let primaryWindow: CodexWindow?
    let secondaryWindow: CodexWindow?

    enum CodingKeys: String, CodingKey {
        case primaryWindow = "primary_window"
        case secondaryWindow = "secondary_window"
    }
}

private struct CodexAdditionalRateLimit: Decodable {
    let limitName: String?
    let meteredFeature: String?
    let rateLimit: CodexRateLimit?

    enum CodingKeys: String, CodingKey {
        case limitName = "limit_name"
        case meteredFeature = "metered_feature"
        case rateLimit = "rate_limit"
    }

    var displayName: String {
        let rawName = limitName ?? meteredFeature ?? "Additional Codex"
        let trimmed = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Additional Codex" : trimmed
    }
}

private struct CodexWindow: Decodable {
    let usedPercent: Double
    let limitWindowSeconds: Int
    let resetAfterSeconds: Int
    let resetAt: Int

    enum CodingKeys: String, CodingKey {
        case usedPercent = "used_percent"
        case limitWindowSeconds = "limit_window_seconds"
        case resetAfterSeconds = "reset_after_seconds"
        case resetAt = "reset_at"
    }
}

private struct CodexCredits: Decodable {
    let balance: Double?

    enum CodingKeys: String, CodingKey {
        case balance
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let numericBalance = try? container.decodeIfPresent(Double.self, forKey: .balance) {
            balance = numericBalance
        } else if let stringBalance = try? container.decodeIfPresent(String.self, forKey: .balance) {
            balance = Double(stringBalance)
        } else {
            balance = nil
        }
    }
}
