#if os(iOS)
import Foundation
import UserNotifications

@MainActor
final class LocalNotificationPublisher {
    static let shared = LocalNotificationPublisher()

    private let defaults: UserDefaults
    private let deliver: (UNNotificationRequest) async throws -> Void
    private let currentSnapshots: () -> [QuotaSnapshot]
    private var inFlightSignatures: Set<String> = []
    private let postedSignaturesKey = "ios.postedAlertSignatures"
    private let initialWindowKey = "ios.hasProcessedInitialAlertWindow"
    private let maxRetention = 200
    private let coldStartCutoff: TimeInterval = 5 * 60

    init(
        defaults: UserDefaults = .standard,
        currentSnapshots: @escaping () -> [QuotaSnapshot] = { QuotaSnapshotStore.shared.loadSnapshots() },
        deliver: @escaping (UNNotificationRequest) async throws -> Void = {
            try await UNUserNotificationCenter.current().add($0)
        }
    ) {
        self.defaults = defaults
        self.currentSnapshots = currentSnapshots
        self.deliver = deliver
    }

    /// Visible CloudKit pushes have already been delivered by the system.
    /// Remember them before a silent refresh can rediscover the same record.
    func markDelivered(_ alerts: [CloudAlertPayload]) {
        var posted = (defaults.array(forKey: postedSignaturesKey) as? [String]) ?? []
        for alert in alerts where !posted.contains(alert.signature) {
            posted.append(alert.signature)
        }
        if posted.count > maxRetention {
            posted.removeFirst(posted.count - maxRetention)
        }
        defaults.set(posted, forKey: postedSignaturesKey)
    }

    func processIncomingAlerts(_ alerts: [CloudAlertPayload]) async {
        guard !alerts.isEmpty else { return }

        let firstRun = !defaults.bool(forKey: initialWindowKey)
        if firstRun {
            defaults.set(true, forKey: initialWindowKey)
            let cutoff = Date().addingTimeInterval(-coldStartCutoff)
            // Skipped history stays skipped when a later silent push fetches
            // it again; otherwise the second pass announces the cold backlog.
            markDelivered(alerts.filter { $0.createdAt < cutoff })
            for alert in alerts where alert.createdAt >= cutoff {
                await post(alert)
            }
            return
        }

        for alert in alerts {
            await post(alert)
        }
    }

    private func post(_ alert: CloudAlertPayload) async {
        guard alert.providerID != .heatmap, alert.providerID != .codexTelemetry else { return }
        guard alert.isAnnounceable, alert.isRelevant(to: currentSnapshots()) else { return }

        let posted = (defaults.array(forKey: postedSignaturesKey) as? [String]) ?? []
        guard !posted.contains(alert.signature),
              inFlightSignatures.insert(alert.signature).inserted else { return }
        defer { inFlightSignatures.remove(alert.signature) }

        let content = AlertNotificationContent.makeContent(for: alert)
        let request = UNNotificationRequest(
            identifier: alert.signature,
            content: content,
            trigger: nil
        )

        do {
            try await deliver(request)
            markDelivered([alert])
        } catch {
            print("[LocalNotificationPublisher] post failed: \(error.localizedDescription)")
        }
    }
}
#endif
