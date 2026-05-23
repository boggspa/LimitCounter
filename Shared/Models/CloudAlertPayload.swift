import Foundation

public enum CloudAlertKind: String, Codable, Hashable {
    case scheduledReset
    case unexpectedRecovery
    case threshold
    case error

    public nonisolated var isUsageReset: Bool {
        switch self {
        case .scheduledReset, .unexpectedRecovery:
            return true
        case .threshold, .error:
            return false
        }
    }
}

public struct CloudAlertPayload: Codable, Hashable {
    public let providerID: ProviderID
    public let title: String
    public let body: String
    public let signature: String
    public let createdAt: Date
    public let windowLabel: String?
    public let kind: CloudAlertKind

    public nonisolated init(
        providerID: ProviderID,
        title: String,
        body: String,
        signature: String,
        createdAt: Date,
        windowLabel: String?,
        kind: CloudAlertKind
    ) {
        self.providerID = providerID
        self.title = title
        self.body = body
        self.signature = signature
        self.createdAt = createdAt
        self.windowLabel = windowLabel
        self.kind = kind
    }
}

public extension CloudAlertPayload {
    /// Derive `kind` and `windowLabel` from the signature string produced by
    /// `CloudKitSyncService.alertDescriptor(for:)`.
    ///
    /// Signature shapes:
    /// - `"reset|<provider>|<kind>|<detectedAt>|<label>"`
    /// - `"signal|scheduledReset|<label>"`
    /// - `"signal|unexpectedRecovery|<label>"`
    /// - `"error"`
    /// - `"exhausted|<label>"`
    /// - `"critical|<label>"`
    /// - `"warning|<label>"`
    nonisolated static func parse(signature: String) -> (kind: CloudAlertKind, windowLabel: String?) {
        let parts = signature.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        guard let first = parts.first else { return (.threshold, nil) }
        switch first {
        case "reset":
            guard parts.count >= 4 else { return (.threshold, nil) }
            let label = parts.count >= 5 ? parts[4] : nil
            switch parts[2] {
            case "scheduledReset": return (.scheduledReset, label)
            case "unexpectedRecovery": return (.unexpectedRecovery, label)
            default: return (.threshold, label)
            }
        case "signal":
            guard parts.count >= 2 else { return (.threshold, nil) }
            let label = parts.count >= 3 ? String(parts[2]) : nil
            switch parts[1] {
            case "scheduledReset": return (.scheduledReset, label)
            case "unexpectedRecovery": return (.unexpectedRecovery, label)
            default: return (.threshold, label)
            }
        case "error":
            return (.error, nil)
        case "exhausted", "critical", "warning":
            let label = parts.count >= 2 ? String(parts[1]) : nil
            return (.threshold, label)
        default:
            return (.threshold, nil)
        }
    }
}

public enum UsageResetAlertBuilder {
    public nonisolated static let defaultFreshnessWindow: TimeInterval = 15 * 60

    public nonisolated static func resetAlerts(
        from snapshots: [QuotaSnapshot],
        noticedAt: Date = Date(),
        freshnessWindow: TimeInterval? = defaultFreshnessWindow
    ) -> [CloudAlertPayload] {
        snapshots.compactMap {
            resetAlert(for: $0, noticedAt: noticedAt, freshnessWindow: freshnessWindow)
        }
    }

    public nonisolated static func resetAlert(
        for snapshot: QuotaSnapshot,
        noticedAt: Date = Date(),
        freshnessWindow: TimeInterval? = defaultFreshnessWindow
    ) -> CloudAlertPayload? {
        guard snapshot.providerID != .heatmap,
              snapshot.providerID != .codexTelemetry,
              snapshot.fetchState.isHealthy else {
            return nil
        }

        let resetSignals = snapshot.signals
            .filter(isUsageResetSignal)
            .filter { signal in
                guard let freshnessWindow else { return true }
                return abs(noticedAt.timeIntervalSince(signal.detectedAt)) <= freshnessWindow
            }
            .sorted { lhs, rhs in
                if lhs.detectedAt == rhs.detectedAt {
                    return resetSignalRank(lhs.kind) < resetSignalRank(rhs.kind)
                }
                return lhs.detectedAt > rhs.detectedAt
            }

        guard !resetSignals.isEmpty else { return nil }

        let labels = uniqueWindowLabels(from: resetSignals)
        let labelSummary = listSummary(labels)
        let kind: CloudAlertKind = resetSignals.contains { $0.kind == .unexpectedRecovery }
            ? .unexpectedRecovery
            : .scheduledReset
        let newestSignalDate = resetSignals.map(\.detectedAt).max() ?? noticedAt
        let title = kind == .unexpectedRecovery
            ? "\(snapshot.displayName) reset early"
            : "\(snapshot.displayName) reset"
        let body = resetAlertBody(
            labels: labels,
            signals: resetSignals,
            noticedAt: noticedAt
        )
        let signature = [
            "reset",
            snapshot.providerID.rawValue,
            kind.rawValue,
            String(Int(newestSignalDate.timeIntervalSince1970)),
            labelSummary
        ].joined(separator: "|")

        return CloudAlertPayload(
            providerID: snapshot.providerID,
            title: title,
            body: body,
            signature: signature,
            createdAt: noticedAt,
            windowLabel: labelSummary,
            kind: kind
        )
    }

    private nonisolated static func isUsageResetSignal(_ signal: QuotaSignal) -> Bool {
        switch signal.kind {
        case .scheduledReset:
            return true
        case .unexpectedRecovery:
            let text = "\(signal.title) \(signal.message)".lowercased()
            return text.contains("fell from")
                || text.contains("quota recovery")
                || text.contains("appears refreshed")
                || text.contains("refreshed early")
                || text.contains("reset early")
                || text.contains("reset estimate")
        }
    }

    private nonisolated static func resetSignalRank(_ kind: QuotaSignalKind) -> Int {
        switch kind {
        case .unexpectedRecovery:
            return 0
        case .scheduledReset:
            return 1
        }
    }

    private nonisolated static func uniqueWindowLabels(from signals: [QuotaSignal]) -> [String] {
        var seen = Set<String>()
        var labels: [String] = []

        for signal in signals {
            let rawLabel = signal.windowLabel ?? signal.title
            let label = rawLabel.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !label.isEmpty else { continue }
            let key = label.lowercased()
            guard seen.insert(key).inserted else { continue }
            labels.append(label)
        }

        return labels.isEmpty ? ["Usage limit"] : labels
    }

    private nonisolated static func resetAlertBody(
        labels: [String],
        signals: [QuotaSignal],
        noticedAt: Date
    ) -> String {
        let prefix = labels.count == 1
            ? "\(labels[0]) reset"
            : "\(listSummary(labels)) reset"
        let noticed = "Noticed at \(clockString(for: noticedAt))."
        let details = signals.prefix(2)
            .map { signal -> String in
                if let label = signal.windowLabel, !label.isEmpty {
                    return "\(label): \(signal.message)"
                }
                return signal.message
            }
            .joined(separator: " ")

        if details.isEmpty {
            return "\(prefix). \(noticed)"
        }

        return "\(prefix). \(noticed) \(details)"
    }

    private nonisolated static func listSummary(_ labels: [String]) -> String {
        switch labels.count {
        case 0:
            return "Usage limit"
        case 1:
            return labels[0]
        case 2:
            return "\(labels[0]) and \(labels[1])"
        default:
            return labels.dropLast().joined(separator: ", ") + ", and \(labels.last ?? "")"
        }
    }

    private nonisolated static func clockString(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter.string(from: date)
    }
}
