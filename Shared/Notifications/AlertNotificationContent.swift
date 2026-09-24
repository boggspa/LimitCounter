import Foundation
import UserNotifications

public enum AlertNotificationContent {
    public static let categoryIdentifier = "PROVIDER_ALERT"
    public static let openActionIdentifier = "OPEN_PROVIDER"
    public static let dismissActionIdentifier = "DISMISS_ALERT"

    public static func makeContent(for alert: CloudAlertPayload) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = alert.title
        content.subtitle = alert.windowLabel ?? "Usage update"
        content.body = alert.body
        content.sound = .default
        content.categoryIdentifier = categoryIdentifier
        // One thread per account, so a Work reset does not collapse into the
        // Personal thread. The primary account's thread id is unchanged.
        content.threadIdentifier = alert.accountKey.rawValue
        content.interruptionLevel = .timeSensitive
        content.userInfo = [
            "providerID": alert.providerID.rawValue,
            "accountSlot": alert.accountSlot,
            "signature": alert.signature,
            "kind": alert.kind.rawValue,
            "windowLabel": alert.windowLabel ?? ""
        ]
        return content
    }

    public static func makeCategory() -> UNNotificationCategory {
        let openAction = UNNotificationAction(
            identifier: openActionIdentifier,
            title: "Open",
            options: [.foreground]
        )
        let dismissAction = UNNotificationAction(
            identifier: dismissActionIdentifier,
            title: "Dismiss",
            options: [.destructive]
        )
        return UNNotificationCategory(
            identifier: categoryIdentifier,
            actions: [openAction, dismissAction],
            intentIdentifiers: [],
            options: [.customDismissAction]
        )
    }
}
