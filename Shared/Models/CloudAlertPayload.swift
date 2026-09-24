import Foundation

public enum CloudAlertKind: String, Codable, Hashable {
    case scheduledReset
    case unexpectedRecovery
    /// A banked usage-limit reset can be redeemed. Not a reset that happened,
    /// so it never counts toward reset history.
    case resetAvailable
    case threshold
    case error

    public nonisolated var isUsageReset: Bool {
        switch self {
        case .scheduledReset, .unexpectedRecovery:
            return true
        case .resetAvailable, .threshold, .error:
            return false
        }
    }

    /// Whether the alert earns a banner. A scheduled reset is the provider
    /// refreshing every account on the plan at once — expected, already visible
    /// on the card, and not worth interrupting for. It is still recorded in
    /// reset history, so this is narrower than `isUsageReset`: it also suppresses
    /// scheduled-reset payloads published by older builds and replayed from
    /// CloudKit on the next launch.
    public nonisolated var isAnnounceable: Bool {
        switch self {
        case .scheduledReset:
            return false
        case .unexpectedRecovery, .resetAvailable, .threshold, .error:
            return true
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
    /// Finer reset classification carried alongside `kind`; nil for alerts
    /// published by builds that predate it.
    public let resetKind: QuotaResetKind?
    /// Which account of the provider the alert is about. Empty (the primary)
    /// for alerts published before accounts existed.
    public let accountSlot: String
    public let accountLabel: String?

    public nonisolated init(
        providerID: ProviderID,
        title: String,
        body: String,
        signature: String,
        createdAt: Date,
        windowLabel: String?,
        kind: CloudAlertKind,
        resetKind: QuotaResetKind? = nil,
        accountSlot: String = ProviderAccountKey.primarySlot,
        accountLabel: String? = nil
    ) {
        self.providerID = providerID
        self.title = title
        self.body = body
        self.signature = signature
        self.createdAt = createdAt
        self.windowLabel = windowLabel
        self.kind = kind
        self.resetKind = resetKind
        self.accountSlot = ProviderAccountKey.normalizedSlot(accountSlot)
        self.accountLabel = accountLabel
    }

    public nonisolated var accountKey: ProviderAccountKey {
        ProviderAccountKey(providerID: providerID, slot: accountSlot)
    }

    private enum CodingKeys: String, CodingKey {
        case providerID, title, body, signature, createdAt, windowLabel, kind, resetKind
        case accountSlot, accountLabel
    }

    public nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        providerID = try container.decode(ProviderID.self, forKey: .providerID)
        title = try container.decode(String.self, forKey: .title)
        body = try container.decode(String.self, forKey: .body)
        signature = try container.decode(String.self, forKey: .signature)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        windowLabel = try container.decodeIfPresent(String.self, forKey: .windowLabel)
        kind = try container.decode(CloudAlertKind.self, forKey: .kind)
        resetKind = try container.decodeIfPresent(QuotaResetKind.self, forKey: .resetKind)
        accountSlot = ProviderAccountKey.normalizedSlot(
            try container.decodeIfPresent(String.self, forKey: .accountSlot) ?? ProviderAccountKey.primarySlot
        )
        accountLabel = try container.decodeIfPresent(String.self, forKey: .accountLabel)
    }

    /// Whether the alert earns a banner and a notification. A banked reset the
    /// user redeemed themselves is recorded in reset history but needs no
    /// interruption: they pressed the button.
    public nonisolated var isAnnounceable: Bool {
        guard kind.isAnnounceable else { return false }
        return resetKind != .bankedRedeemed
    }

    /// Short badge text for the toast and the notification subtitle.
    public nonisolated var badgeTitle: String {
        if let resetKind {
            return resetKind.title
        }
        switch kind {
        case .scheduledReset:
            return "Quota reset"
        case .unexpectedRecovery:
            return "Early quota reset"
        case .resetAvailable:
            return "Reset available"
        case .threshold:
            return "Limit"
        case .error:
            return "Sync"
        }
    }
}

public extension CloudAlertPayload {
    /// Derive `kind` and `windowLabel` from the signature string produced by
    /// `CloudKitSyncService.alertDescriptor(for:)`.
    ///
    /// Signature shapes:
    /// - `"reset|<provider>|<kind>|<detectedAt>|<label>|<resetKind>"` (the
    ///   trailing reset kind is optional; older builds omit it)
    /// - `"signal|scheduledReset|<label>"`
    /// - `"signal|unexpectedRecovery|<label>"`
    /// - `"error"`
    /// - `"exhausted|<label>"`
    /// - `"critical|<label>"`
    /// - `"warning|<label>"`
    nonisolated static func parse(
        signature: String
    ) -> (kind: CloudAlertKind, windowLabel: String?, resetKind: QuotaResetKind?) {
        let parts = signature.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        guard let first = parts.first else { return (.threshold, nil, nil) }
        switch first {
        case "reset":
            guard parts.count >= 4 else { return (.threshold, nil, nil) }
            let label = parts.count >= 5 ? parts[4] : nil
            let resetKind = parts.count >= 6 ? QuotaResetKind(rawValue: parts[5]) : nil
            switch parts[2] {
            case "scheduledReset": return (.scheduledReset, label, resetKind ?? .scheduled)
            case "unexpectedRecovery": return (.unexpectedRecovery, label, resetKind)
            case "resetAvailable": return (.resetAvailable, label, resetKind ?? .bankedAvailable)
            default: return (.threshold, label, resetKind)
            }
        case "signal":
            guard parts.count >= 2 else { return (.threshold, nil, nil) }
            let label = parts.count >= 3 ? String(parts[2]) : nil
            switch parts[1] {
            case "scheduledReset": return (.scheduledReset, label, .scheduled)
            case "unexpectedRecovery": return (.unexpectedRecovery, label, nil)
            default: return (.threshold, label, nil)
            }
        case "error":
            return (.error, nil, nil)
        case "exhausted", "critical", "warning":
            let label = parts.count >= 2 ? String(parts[1]) : nil
            return (.threshold, label, nil)
        default:
            return (.threshold, nil, nil)
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

        let freshSignals = snapshot.signals.filter { signal in
            guard let freshnessWindow else { return true }
            return abs(noticedAt.timeIntervalSince(signal.detectedAt)) <= freshnessWindow
        }

        let resetSignals = freshSignals
            .filter(isUsageResetSignal)
            .sorted { lhs, rhs in
                if lhs.detectedAt == rhs.detectedAt {
                    return resetSignalRank(lhs.kind) < resetSignalRank(rhs.kind)
                }
                return lhs.detectedAt > rhs.detectedAt
            }

        if !resetSignals.isEmpty {
            let labels = uniqueWindowLabels(from: resetSignals)
            let labelSummary = listSummary(labels)
            let kind: CloudAlertKind = resetSignals.contains { $0.kind == .unexpectedRecovery }
                ? .unexpectedRecovery
                : .scheduledReset
            let resetKind = dominantResetKind(of: resetSignals, alertKind: kind)
            let newestSignalDate = resetSignals.map(\.detectedAt).max() ?? noticedAt
            let title = resetAlertTitle(displayName: snapshot.accountDisplayName, resetKind: resetKind)
            let body = resetAlertBody(
                labels: labels,
                signals: resetSignals,
                noticedAt: noticedAt
            )
            // The account key sits where the provider raw value used to: the
            // primary account's signatures are unchanged, and a secondary
            // account's reset can never be deduplicated away as the primary's.
            let signature = [
                "reset",
                snapshot.accountKey.rawValue,
                kind.rawValue,
                String(Int(newestSignalDate.timeIntervalSince1970)),
                labelSummary,
                resetKind.rawValue
            ].joined(separator: "|")

            return CloudAlertPayload(
                providerID: snapshot.providerID,
                title: title,
                body: body,
                signature: signature,
                createdAt: noticedAt,
                windowLabel: labelSummary,
                kind: kind,
                resetKind: resetKind,
                accountSlot: snapshot.accountSlot,
                accountLabel: snapshot.accountBadgeText
            )
        }

        // No reset happened, but a banked one may be waiting to be redeemed.
        let availableSignals = freshSignals
            .filter { $0.resetKind == .bankedAvailable }
            .sorted { $0.detectedAt > $1.detectedAt }
        guard let available = availableSignals.first else { return nil }

        let label = available.windowLabel?.trimmingCharacters(in: .whitespacesAndNewlines)
        let labelSummary = (label?.isEmpty == false ? label : nil) ?? "Banked reset"
        let signature = [
            "reset",
            snapshot.accountKey.rawValue,
            CloudAlertKind.resetAvailable.rawValue,
            String(Int(available.detectedAt.timeIntervalSince1970)),
            labelSummary,
            QuotaResetKind.bankedAvailable.rawValue
        ].joined(separator: "|")

        return CloudAlertPayload(
            providerID: snapshot.providerID,
            title: "\(snapshot.accountDisplayName) reset available",
            body: "\(available.message) Noticed at \(clockString(for: noticedAt)).",
            signature: signature,
            createdAt: noticedAt,
            windowLabel: labelSummary,
            kind: .resetAvailable,
            resetKind: .bankedAvailable,
            accountSlot: snapshot.accountSlot,
            accountLabel: snapshot.accountBadgeText
        )
    }

    /// The single classification an alert carries when its signals disagree:
    /// a provider-wide reset outranks a solo gift, and either outranks a
    /// banked redemption, so the loudest true thing wins.
    private nonisolated static func dominantResetKind(
        of signals: [QuotaSignal],
        alertKind: CloudAlertKind
    ) -> QuotaResetKind {
        guard alertKind == .unexpectedRecovery else { return .scheduled }
        let kinds = Set(signals.compactMap(\.resetKind))
        if kinds.contains(.providerWide) { return .providerWide }
        if kinds.contains(.gifted) { return .gifted }
        if kinds.contains(.bankedRedeemed), kinds.count == 1 { return .bankedRedeemed }
        // Legacy signals (no classification) read as an early, independent reset.
        return kinds.isEmpty ? .gifted : (kinds.first ?? .gifted)
    }

    private nonisolated static func resetAlertTitle(displayName: String, resetKind: QuotaResetKind) -> String {
        switch resetKind {
        case .scheduled:
            return "\(displayName) reset"
        case .gifted:
            return "\(displayName) reset early"
        case .providerWide:
            return "\(displayName) quotas reset"
        case .bankedRedeemed:
            return "\(displayName) banked reset redeemed"
        case .bankedAvailable:
            return "\(displayName) reset available"
        }
    }

    /// Only an *independent* reset is worth interrupting for — a window that came
    /// back early or off-schedule says something about this account. A scheduled
    /// reset is the provider refreshing everyone on the same plan at the same
    /// time; it is expected, it is already on the card, and alerting on it is
    /// noise. `.scheduledReset` is also the closest kind for a few non-reset
    /// diagnostics (Devin's stale-cache warning), which must never read as
    /// "your quota reset".
    private nonisolated static func isUsageResetSignal(_ signal: QuotaSignal) -> Bool {
        // Classified signals (from the reset detector) say exactly what they
        // are; the text heuristics below only remain for signals published by
        // builds that predate the classification.
        if let resetKind = signal.resetKind {
            return resetKind.isResetEvent && resetKind != .scheduled
        }
        switch signal.kind {
        case .scheduledReset:
            return false
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
