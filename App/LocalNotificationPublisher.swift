#if os(iOS)
import Foundation
import UserNotifications

@MainActor
final class LocalNotificationPublisher {
    static let shared = LocalNotificationPublisher()

    private let defaults = UserDefaults.standard
    private let postedSignaturesKey = "ios.postedAlertSignatures"
    private let initialWindowKey = "ios.hasProcessedInitialAlertWindow"
    private let maxRetention = 200
    private let coldStartCutoff: TimeInterval = 5 * 60

    private init() {}

    func processIncomingAlerts(_ alerts: [CloudAlertPayload]) async {
        guard !alerts.isEmpty else { return }

        let firstRun = !defaults.bool(forKey: initialWindowKey)
        if firstRun {
            defaults.set(true, forKey: initialWindowKey)
            let cutoff = Date().addingTimeInterval(-coldStartCutoff)
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

        var posted = (defaults.array(forKey: postedSignaturesKey) as? [String]) ?? []
        guard !posted.contains(alert.signature) else { return }

        let content = AlertNotificationContent.makeContent(for: alert)
        let request = UNNotificationRequest(
            identifier: alert.signature,
            content: content,
            trigger: nil
        )

        do {
            try await UNUserNotificationCenter.current().add(request)
            posted.append(alert.signature)
            if posted.count > maxRetention {
                posted.removeFirst(posted.count - maxRetention)
            }
            defaults.set(posted, forKey: postedSignaturesKey)
        } catch {
            print("[LocalNotificationPublisher] post failed: \(error.localizedDescription)")
        }
    }
}
#endif
