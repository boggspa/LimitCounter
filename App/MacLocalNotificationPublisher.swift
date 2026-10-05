#if os(macOS)
import Foundation
import UserNotifications

@MainActor
final class MacLocalNotificationPublisher {
    static let shared = MacLocalNotificationPublisher()

    private let defaults: UserDefaults
    private let deliver: (UNNotificationRequest) async throws -> Void
    private let currentSnapshots: () -> [QuotaSnapshot]
    private var inFlightSignatures: Set<String> = []
    private let postedSignaturesKey = "mac.postedAlertSignatures"
    private let maxRetention = 200

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

    func requestAuthorizationIfNeeded() async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .notDetermined else { return }
        do {
            _ = try await center.requestAuthorization(options: [.alert, .sound, .badge])
        } catch {
            print("[MacLocalNotificationPublisher] authorization skipped: \(error.localizedDescription)")
        }
    }

    func processEmittedAlerts(_ alerts: [CloudAlertPayload]) async {
        guard !alerts.isEmpty else { return }
        for alert in alerts {
            await post(alert)
        }
    }

    private func post(_ alert: CloudAlertPayload) async {
        guard alert.providerID != .heatmap, alert.providerID != .codexTelemetry else { return }
        // Belt and braces: the builder no longer emits scheduled resets, but a
        // payload published by an older build can still arrive from CloudKit.
        guard alert.isAnnounceable else { return }
        guard alert.isRelevant(to: currentSnapshots()) else { return }

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
            // A local refresh and its cloud publication can interleave while
            // delivery awaits. Merge with the latest successful deliveries.
            var posted = (defaults.array(forKey: postedSignaturesKey) as? [String]) ?? []
            if !posted.contains(alert.signature) { posted.append(alert.signature) }
            if posted.count > maxRetention {
                posted.removeFirst(posted.count - maxRetention)
            }
            defaults.set(posted, forKey: postedSignaturesKey)
        } catch {
            print("[MacLocalNotificationPublisher] post failed: \(error.localizedDescription)")
        }
    }
}
#endif
