import CloudKit
import CryptoKit
import Foundation
#if os(iOS)
import UserNotifications
#endif

enum CloudKitSyncError: LocalizedError {
    case accountUnavailable
    case statusPublishFailed(String)

    var errorDescription: String? {
        switch self {
        case .accountUnavailable:
            return "iCloud is unavailable for CloudKit sync."
        case .statusPublishFailed(let message):
            return message
        }
    }
}

private struct CloudAlertDescriptor {
    let title: String
    let body: String
    let signature: String
    let windowLabel: String?
    let kind: CloudAlertKind
}

struct CloudSyncOperationDebugState: Codable, Equatable {
    var lastAttemptAt: Date?
    var lastSuccessAt: Date?
    var lastErrorDescription: String?

    static let empty = CloudSyncOperationDebugState()
}

struct CloudSyncDebugInfo: Equatable {
    let roleTitle: String
    let accountStatusTitle: String
    let accountHealthy: Bool
    let cachedSnapshotCount: Int
    let subscriptionVersion: Int
    let publishState: CloudSyncOperationDebugState
    let fetchState: CloudSyncOperationDebugState
    let subscriptionState: CloudSyncOperationDebugState
    let lastRemoteNotificationAt: Date?
    let notificationsStatusTitle: String?

    static let placeholder = CloudSyncDebugInfo(
        roleTitle: {
            #if os(macOS)
            "Mac publisher"
            #else
            "iPhone viewer"
            #endif
        }(),
        accountStatusTitle: "Checking…",
        accountHealthy: false,
        cachedSnapshotCount: 0,
        subscriptionVersion: 0,
        publishState: .empty,
        fetchState: .empty,
        subscriptionState: .empty,
        lastRemoteNotificationAt: nil,
        notificationsStatusTitle: nil
    )
}

private enum CloudDebugOperation: String {
    case publish
    case fetch
    case subscriptions
}

@MainActor
final class CloudKitSyncService {
    static let shared = CloudKitSyncService()

    private let container = CKContainer.default()
    private let database: CKDatabase

    private let statusRecordType = "UsageStatus"
    private let alertRecordType = "UsageAlertEvent"
    private let statusSubscriptionID = "usage-status-silent-v1"
    private let alertSubscriptionID = "usage-alert-visible-v1"
    private let viewerSubscriptionVersion = 5
    private let alertPayloadKeys = ["providerID", "title", "body", "signature", "createdAt", "windowLabel", "kind"]
    private let alertTitleLocalizationKey = "CLOUD_USAGE_ALERT_TITLE"
    private let alertBodyLocalizationKey = "CLOUD_USAGE_ALERT_BODY"

    private let subscriptionVersionKey = "cloudkit.viewerSubscriptionVersion"
    private let publishedHashKey = "cloudkit.publishedStatusHashes"
    private let lastAlertSignatureKey = "cloudkit.lastAlertSignatures"
    private let publishDebugStateKey = "cloudkit.debug.publish"
    private let fetchDebugStateKey = "cloudkit.debug.fetch"
    private let subscriptionDebugStateKey = "cloudkit.debug.subscriptions"
    private let lastRemoteNotificationDateKey = "cloudkit.debug.lastRemoteNotification"

    private let defaults = UserDefaults.standard
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let cloudStatusEventRetention: TimeInterval = 31 * 24 * 60 * 60
    private let maxCloudStatusEventBuckets = 30 * 12
    private let cloudStatusAnalyticsRetention: TimeInterval = 60 * 24 * 60 * 60
    private let maxCloudStatusAnalyticsBuckets = 120
    private let maxCloudStatusPayloadBytes = 750_000

    init() {
        database = container.privateCloudDatabase
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
    }

    func ensureViewerSubscriptions() async throws {
        recordOperationAttempt(.subscriptions)

        do {
            guard try await container.accountStatus() == .available else {
                throw CloudKitSyncError.accountUnavailable
            }

            let installedVersion = defaults.integer(forKey: subscriptionVersionKey)
            if installedVersion < viewerSubscriptionVersion {
                let statusSubscription = CKQuerySubscription(
                    recordType: statusRecordType,
                    predicate: NSPredicate(value: true),
                    subscriptionID: statusSubscriptionID,
                    options: [.firesOnRecordCreation, .firesOnRecordUpdate, .firesOnRecordDeletion]
                )
                let statusInfo = CKSubscription.NotificationInfo()
                statusInfo.shouldSendContentAvailable = true
                statusSubscription.notificationInfo = statusInfo

                let alertSubscription = CKQuerySubscription(
                    recordType: alertRecordType,
                    predicate: NSPredicate(value: true),
                    subscriptionID: alertSubscriptionID,
                    options: [.firesOnRecordCreation]
                )
                let alertInfo = CKSubscription.NotificationInfo()
                alertInfo.shouldSendContentAvailable = true
                alertInfo.titleLocalizationKey = alertTitleLocalizationKey
                alertInfo.titleLocalizationArgs = ["title"]
                alertInfo.alertLocalizationKey = alertBodyLocalizationKey
                alertInfo.alertLocalizationArgs = ["body"]
                alertInfo.subtitle = "Usage update"
                alertInfo.soundName = "default"
                alertInfo.category = AlertNotificationContent.categoryIdentifier
                alertInfo.desiredKeys = alertPayloadKeys
                alertSubscription.notificationInfo = alertInfo

                _ = try await database.modifySubscriptions(
                    saving: [statusSubscription, alertSubscription],
                    deleting: []
                )

                defaults.set(viewerSubscriptionVersion, forKey: subscriptionVersionKey)
            }

            recordOperationSuccess(.subscriptions)
        } catch {
            recordOperationFailure(.subscriptions, error: error)
            throw error
        }
    }

    func fetchRemoteSnapshots() async throws -> [QuotaSnapshot] {
        recordOperationAttempt(.fetch)

        do {
            guard try await container.accountStatus() == .available else {
                throw CloudKitSyncError.accountUnavailable
            }

            var snapshotsByProvider: [ProviderID: QuotaSnapshot] = [:]

            for providerID in ProviderID.allCases {
                // Skip the heatmap virtual provider
                guard providerID != .heatmap else { continue }

                let recordID = CKRecord.ID(recordName: statusRecordName(for: providerID))

                do {
                    let record = try await database.record(for: recordID)
                    guard let payloadData = record["payloadData"] as? Data else { continue }
                    let snapshot = try decoder.decode(QuotaSnapshot.self, from: payloadData)
                    snapshotsByProvider[providerID] = snapshot
                } catch let error as CKError where error.code == .unknownItem {
                    continue
                } catch {
                    print("[CloudKitSync] Failed to decode record for \(providerID.rawValue): \(error.localizedDescription)")
                    continue
                }
            }

            recordOperationSuccess(.fetch)
            return ProviderID.allCases.compactMap { snapshotsByProvider[$0] }
        } catch {
            recordOperationFailure(.fetch, error: error)
            throw error
        }
    }

    @discardableResult
    func publishSnapshots(_ snapshots: [QuotaSnapshot]) async throws -> [CloudAlertPayload] {
        recordOperationAttempt(.publish)

        do {
            guard try await container.accountStatus() == .available else {
                throw CloudKitSyncError.accountUnavailable
            }

            let shouldForceStatusRepublish = loadOperationState(.publish).lastErrorDescription != nil
            var publishedHashes = defaults.dictionary(forKey: publishedHashKey) as? [String: String] ?? [:]
            if shouldForceStatusRepublish {
                publishedHashes = [:]
                print("[CloudKitSync] Previous publish failed — forcing full status republish")
            }
            var lastAlertSignatures = defaults.dictionary(forKey: lastAlertSignatureKey) as? [String: String] ?? [:]
            var emittedAlerts: [CloudAlertPayload] = []
            var statusFailures: [String] = []
            var alertFailures: [String] = []

            for snapshot in snapshots {
                let statusSnapshot = cloudStatusSnapshot(for: snapshot)
                let providerKey = snapshot.providerID.rawValue
                let currentHash = statusHash(for: statusSnapshot)
                let previousHash = publishedHashes[providerKey]

                if previousHash != currentHash {
                    do {
                        try await saveStatusRecord(statusSnapshot, statusHash: currentHash)
                        publishedHashes[providerKey] = currentHash
                    } catch {
                        let detail = cloudKitErrorDescription(error)
                        statusFailures.append("\(providerKey): \(detail)")
                        print("[CloudKitSync] Status publish failed for \(providerKey): \(detail)")
                        continue
                    }
                }

                let alertDescriptor = alertDescriptor(for: snapshot)

                if let alertDescriptor {
                    if lastAlertSignatures[providerKey] != alertDescriptor.signature {
                        let createdAt = Date()
                        do {
                            try await saveAlertRecord(snapshot, descriptor: alertDescriptor, createdAt: createdAt)
                            lastAlertSignatures[providerKey] = alertDescriptor.signature
                            emittedAlerts.append(
                                CloudAlertPayload(
                                    providerID: snapshot.providerID,
                                    title: alertDescriptor.title,
                                    body: alertDescriptor.body,
                                    signature: alertDescriptor.signature,
                                    createdAt: createdAt,
                                    windowLabel: alertDescriptor.windowLabel,
                                    kind: alertDescriptor.kind
                                )
                            )
                        } catch {
                            let detail = cloudKitErrorDescription(error)
                            alertFailures.append("\(providerKey): \(detail)")
                            print("[CloudKitSync] Alert publish failed for \(providerKey): \(detail)")
                        }
                    }
                } else {
                    lastAlertSignatures.removeValue(forKey: providerKey)
                }
            }

            defaults.set(publishedHashes, forKey: publishedHashKey)
            defaults.set(lastAlertSignatures, forKey: lastAlertSignatureKey)

            if !statusFailures.isEmpty {
                let message = "Failed to publish CloudKit status records: \(statusFailures.joined(separator: "; "))"
                throw CloudKitSyncError.statusPublishFailed(message)
            }

            if !alertFailures.isEmpty {
                print("[CloudKitSync] Status records published; alert publish failures ignored: \(alertFailures.joined(separator: "; "))")
            }

            recordOperationSuccess(.publish)
            return emittedAlerts
        } catch {
            recordOperationFailure(.publish, error: error)
            throw error
        }
    }

    func isCloudKitNotification(_ userInfo: [AnyHashable: Any]) -> Bool {
        CKNotification(fromRemoteNotificationDictionary: userInfo) != nil
    }

    func markRemoteNotificationReceived() {
        defaults.set(Date(), forKey: lastRemoteNotificationDateKey)
    }

    func hasVisibleAlertPayload(_ userInfo: [AnyHashable: Any]) -> Bool {
        guard let aps = userInfo["aps"] as? [AnyHashable: Any],
              let alert = aps["alert"] else {
            return false
        }

        if let text = alert as? String {
            return !text.isEmpty
        }

        if let fields = alert as? [AnyHashable: Any] {
            return !fields.isEmpty
        }

        return false
    }

    func providerID(fromNotificationUserInfo userInfo: [AnyHashable: Any]) -> ProviderID? {
        if let raw = userInfo["providerID"] as? String,
           let providerID = ProviderID(rawValue: raw) {
            return providerID
        }

        return extractAlertPayloads(from: userInfo).first?.providerID
    }

    func extractAlertPayloads(from userInfo: [AnyHashable: Any]) -> [CloudAlertPayload] {
        guard let notification = CKNotification(fromRemoteNotificationDictionary: userInfo) as? CKQueryNotification,
              notification.subscriptionID == alertSubscriptionID,
              let fields = notification.recordFields else {
            return []
        }
        guard let payload = decodeAlertFields(fields) else { return [] }
        return [payload]
    }

    func fetchRecentAlerts(since: Date?, limit: Int = 20) async throws -> [CloudAlertPayload] {
        guard try await container.accountStatus() == .available else {
            throw CloudKitSyncError.accountUnavailable
        }

        let predicate: NSPredicate
        if let since {
            predicate = NSPredicate(format: "createdAt > %@", since as NSDate)
        } else {
            predicate = NSPredicate(value: true)
        }

        let query = CKQuery(recordType: alertRecordType, predicate: predicate)
        query.sortDescriptors = [NSSortDescriptor(key: "createdAt", ascending: false)]

        let operation = CKQueryOperation(query: query)
        operation.resultsLimit = limit
        operation.qualityOfService = .userInitiated
        operation.desiredKeys = alertPayloadKeys

        var collected: [CloudAlertPayload] = []
        operation.recordMatchedBlock = { _, result in
            if case .success(let record) = result {
                var fields: [String: Any] = [:]
                for key in record.allKeys() {
                    if let value = record[key] {
                        fields[key] = value
                    }
                }
                if let payload = self.decodeAlertFields(fields) {
                    collected.append(payload)
                }
            }
        }

        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[CloudAlertPayload], Error>) in
            operation.queryResultBlock = { result in
                switch result {
                case .success:
                    continuation.resume(returning: collected)
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }
            self.database.add(operation)
        }
    }

    private func decodeAlertFields(_ fields: [String: Any]) -> CloudAlertPayload? {
        guard let providerRaw = fields["providerID"] as? String,
              let providerID = ProviderID(rawValue: providerRaw),
              let title = fields["title"] as? String,
              let body = fields["body"] as? String,
              let signature = fields["signature"] as? String else {
            return nil
        }
        let parsed = CloudAlertPayload.parse(signature: signature)
        let createdAt = (fields["createdAt"] as? Date) ?? Date()
        let fieldLabel = (fields["windowLabel"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let fieldKind = (fields["kind"] as? String).flatMap(CloudAlertKind.init(rawValue:))
        return CloudAlertPayload(
            providerID: providerID,
            title: title,
            body: body,
            signature: signature,
            createdAt: createdAt,
            windowLabel: fieldLabel?.isEmpty == false ? fieldLabel : parsed.windowLabel,
            kind: fieldKind ?? parsed.kind
        )
    }

    func reinstallViewerSubscriptions() async throws {
        defaults.removeObject(forKey: subscriptionVersionKey)
        try await ensureViewerSubscriptions()
    }

    func loadDebugInfo() async -> CloudSyncDebugInfo {
        let accountStatus = await loadAccountStatus()
        let cachedSnapshotCount = QuotaSnapshotStore.shared.loadSnapshots().count

        #if os(iOS)
        let notificationSettings = await UNUserNotificationCenter.current().notificationSettings()
        let notificationsStatusTitle = notificationAuthorizationTitle(notificationSettings.authorizationStatus)
        #else
        let notificationsStatusTitle: String? = nil
        #endif

        return CloudSyncDebugInfo(
            roleTitle: {
                #if os(macOS)
                "Mac publisher"
                #else
                "iPhone viewer"
                #endif
            }(),
            accountStatusTitle: accountStatusTitle(accountStatus),
            accountHealthy: accountStatus == .available,
            cachedSnapshotCount: cachedSnapshotCount,
            subscriptionVersion: defaults.integer(forKey: subscriptionVersionKey),
            publishState: loadOperationState(.publish),
            fetchState: loadOperationState(.fetch),
            subscriptionState: loadOperationState(.subscriptions),
            lastRemoteNotificationAt: defaults.object(forKey: lastRemoteNotificationDateKey) as? Date,
            notificationsStatusTitle: notificationsStatusTitle
        )
    }

    private func saveStatusRecord(_ snapshot: QuotaSnapshot, statusHash: String) async throws {
        let recordID = CKRecord.ID(recordName: statusRecordName(for: snapshot.providerID))
        let record = CKRecord(recordType: statusRecordType, recordID: recordID)

        record["providerID"] = snapshot.providerID.rawValue as NSString
        record["displayName"] = snapshot.displayName as NSString
        if let planName = snapshot.planName, !planName.isEmpty {
            record["planName"] = planName as NSString
        }
        record["fetchedAt"] = snapshot.fetchedAt as NSDate
        record["summary"] = snapshotSummary(for: snapshot) as NSString
        record["statusHash"] = statusHash as NSString
        var payloadSnapshot = snapshot
        var payloadData = try encoder.encode(payloadSnapshot)
        if payloadData.count > maxCloudStatusPayloadBytes {
            payloadSnapshot = statusOnlySnapshot(from: payloadSnapshot)
            payloadData = try encoder.encode(payloadSnapshot)
            print("[CloudKitSync] Reduced \(snapshot.providerID.rawValue) status payload to status-only (\(payloadData.count) bytes)")
        }
        record["payloadVersion"] = 2 as NSNumber
        record["payloadData"] = payloadData as NSData

        let operation = CKModifyRecordsOperation(recordsToSave: [record], recordIDsToDelete: [])
        operation.savePolicy = .changedKeys
        operation.qualityOfService = .userInitiated

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            operation.modifyRecordsCompletionBlock = { _, _, error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
            database.add(operation)
        }
    }

    private func saveAlertRecord(_ snapshot: QuotaSnapshot, descriptor: CloudAlertDescriptor, createdAt: Date) async throws {
        let recordID = CKRecord.ID(recordName: "alert.\(UUID().uuidString)")
        let record = CKRecord(recordType: alertRecordType, recordID: recordID)

        record["providerID"] = snapshot.providerID.rawValue as NSString
        record["title"] = descriptor.title as NSString
        record["body"] = descriptor.body as NSString
        record["signature"] = descriptor.signature as NSString
        record["kind"] = descriptor.kind.rawValue as NSString
        if let windowLabel = descriptor.windowLabel, !windowLabel.isEmpty {
            record["windowLabel"] = windowLabel as NSString
        }
        record["createdAt"] = createdAt as NSDate
        record["statusRecordName"] = statusRecordName(for: snapshot.providerID) as NSString

        let operation = CKModifyRecordsOperation(recordsToSave: [record], recordIDsToDelete: [])
        operation.savePolicy = .changedKeys
        operation.qualityOfService = .userInitiated

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            operation.modifyRecordsCompletionBlock = { _, _, error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
            database.add(operation)
        }
    }

    private func statusRecordName(for providerID: ProviderID) -> String {
        "status.\(providerID.rawValue)"
    }

    private func cloudStatusSnapshot(for snapshot: QuotaSnapshot) -> QuotaSnapshot {
        let now = Date()
        let eventCutoff = now.addingTimeInterval(-cloudStatusEventRetention)
        let analyticsCutoff = now.addingTimeInterval(-cloudStatusAnalyticsRetention)
        let compactEvents = compactCloudStatusEvents(
            snapshot.events,
            cutoff: eventCutoff,
            maxBuckets: maxCloudStatusEventBuckets
        )
        let compactAnalytics = snapshot.analyticsBuckets
            .filter { $0.endDate >= analyticsCutoff }
            .sorted { lhs, rhs in
                if lhs.endDate == rhs.endDate {
                    return lhs.id > rhs.id
                }
                return lhs.endDate > rhs.endDate
            }
            .prefix(maxCloudStatusAnalyticsBuckets)

        return copySnapshot(
            snapshot,
            events: Array(compactEvents),
            analyticsBuckets: Array(compactAnalytics)
        )
    }

    private func statusOnlySnapshot(from snapshot: QuotaSnapshot) -> QuotaSnapshot {
        copySnapshot(snapshot, events: [], analyticsBuckets: [])
    }

    private func copySnapshot(
        _ snapshot: QuotaSnapshot,
        events: [UsageEvent],
        analyticsBuckets: [UsageAnalyticsBucket]
    ) -> QuotaSnapshot {
        QuotaSnapshot(
            id: snapshot.id,
            providerID: snapshot.providerID,
            displayName: snapshot.displayName,
            planName: snapshot.planName,
            windows: snapshot.windows,
            stats: snapshot.stats,
            balances: snapshot.balances,
            signals: snapshot.signals,
            events: events,
            analyticsBuckets: analyticsBuckets,
            fetchState: snapshot.fetchState,
            fetchedAt: snapshot.fetchedAt
        )
    }

    private func compactCloudStatusEvents(
        _ events: [UsageEvent],
        cutoff: Date,
        maxBuckets: Int
    ) -> [UsageEvent] {
        guard !events.isEmpty, maxBuckets > 0 else { return [] }

        let calendar = Calendar.current
        let recentEvents = events.filter { $0.timestamp >= cutoff }
        let grouped = Dictionary(grouping: recentEvents) { event in
            cloudStatusEventBucketStart(for: event.timestamp, calendar: calendar)
        }

        return grouped.map { bucketStart, bucketEvents in
            let tokenTotal = bucketEvents.compactMap(\.tokens).reduce(0, +)
            return UsageEvent(
                timestamp: bucketStart,
                tokens: tokenTotal > 0 ? tokenTotal : nil,
                model: dominantModel(in: bucketEvents),
                type: .bucket
            )
        }
        .sorted { $0.timestamp > $1.timestamp }
        .prefix(maxBuckets)
        .map { $0 }
    }

    private func cloudStatusEventBucketStart(for date: Date, calendar: Calendar) -> Date {
        let dayStart = calendar.startOfDay(for: date)
        let hour = calendar.component(.hour, from: date)
        return calendar.date(byAdding: .hour, value: (hour / 2) * 2, to: dayStart) ?? date
    }

    private func dominantModel(in events: [UsageEvent]) -> String? {
        var weights: [String: Double] = [:]
        for event in events {
            guard let model = event.model?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !model.isEmpty else {
                continue
            }
            weights[model, default: 0] += event.tokens ?? 1
        }
        return weights.max { lhs, rhs in
            if lhs.value == rhs.value {
                return lhs.key > rhs.key
            }
            return lhs.value < rhs.value
        }?.key
    }

    private func snapshotSummary(for snapshot: QuotaSnapshot) -> String {
        if let primaryWindow = snapshot.primaryWindow {
            return "\(snapshot.displayName): \(primaryWindow.measurementSummary)"
        }

        switch snapshot.fetchState {
        case .success:
            return "\(snapshot.displayName): available"
        case .error:
            return "\(snapshot.displayName): update failed"
        case .notConfigured:
            return "\(snapshot.displayName): not configured"
        }
    }

    private func statusHash(for snapshot: QuotaSnapshot) -> String {
        var parts: [String] = [
            snapshot.providerID.rawValue,
            snapshot.displayName,
            snapshot.planName ?? "",
            fetchStateSignature(snapshot.fetchState)
        ]

        let sortedWindows = snapshot.windows.sorted {
            ($0.label, $0.windowKind.rawValue, $0.unit) < ($1.label, $1.windowKind.rawValue, $1.unit)
        }
        for window in sortedWindows {
            parts.append(
                [
                    "window",
                    window.label,
                    window.windowKind.rawValue,
                    formatMetric(window.used),
                    formatMetric(window.total ?? -1),
                    window.resetDate.map { String(Int($0.timeIntervalSince1970)) } ?? "",
                    window.unit,
                    window.subtitle ?? ""
                ].joined(separator: "|")
            )
        }

        let sortedStats = snapshot.stats.sorted { ($0.label, $0.unit) < ($1.label, $1.unit) }
        for stat in sortedStats {
            parts.append(
                [
                    "stat",
                    stat.label,
                    formatMetric(stat.value),
                    stat.unit,
                    stat.subtitle ?? ""
                ].joined(separator: "|")
            )
        }

        let sortedBalances = snapshot.balances.sorted { ($0.label, $0.unit) < ($1.label, $1.unit) }
        for balance in sortedBalances {
            parts.append(
                [
                    "balance",
                    balance.label,
                    formatMetric(balance.amount),
                    balance.unit,
                    balance.subtitle ?? "",
                    balance.resetDate.map { String(Int($0.timeIntervalSince1970)) } ?? ""
                ].joined(separator: "|")
            )
        }

        let sortedSignals = snapshot.signals.sorted {
            ($0.kind.rawValue, $0.windowLabel ?? "", $0.title) < ($1.kind.rawValue, $1.windowLabel ?? "", $1.title)
        }
        for signal in sortedSignals {
            parts.append(
                [
                    "signal",
                    signal.kind.rawValue,
                    signal.windowLabel ?? "",
                    signal.title,
                    signal.message,
                    signal.severity.rawValue,
                    signal.confidence.map { formatMetric($0) } ?? "",
                    String(Int(signal.detectedAt.timeIntervalSince1970))
                ].joined(separator: "|")
            )
        }

        // Include events in hash to detect new activity
        parts.append("events:\(snapshot.events.count)")
        if let latest = snapshot.events.map(\.timestamp).max() {
            parts.append("latestEvent:\(Int(latest.timeIntervalSince1970))")
        }
        let eventTokenTotal = snapshot.events.compactMap(\.tokens).reduce(0, +)
        if eventTokenTotal > 0 {
            parts.append("eventTokens:\(formatMetric(eventTokenTotal))")
        }
        parts.append("analytics:\(snapshot.analyticsBuckets.count)")
        if let latestAnalytics = snapshot.analyticsBuckets.map(\.endDate).max() {
            parts.append("latestAnalytics:\(Int(latestAnalytics.timeIntervalSince1970))")
        }

        let digest = SHA256.hash(data: Data(parts.joined(separator: "\n").utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func fetchStateSignature(_ fetchState: ProviderFetchState) -> String {
        switch fetchState {
        case .success:
            return "success"
        case .error:
            return "error"
        case .notConfigured:
            return "notConfigured"
        }
    }

    private func alertDescriptor(for snapshot: QuotaSnapshot) -> CloudAlertDescriptor? {
        guard snapshot.providerID != .heatmap,
              snapshot.providerID != .codexTelemetry else {
            return nil
        }

        if let resetAlert = UsageResetAlertBuilder.resetAlert(
            for: snapshot,
            noticedAt: Date(),
            freshnessWindow: 30 * 60
        ) {
            return CloudAlertDescriptor(
                title: resetAlert.title,
                body: resetAlert.body,
                signature: resetAlert.signature,
                windowLabel: resetAlert.windowLabel,
                kind: resetAlert.kind
            )
        }

        switch snapshot.fetchState {
        case .error:
            return CloudAlertDescriptor(
                title: "\(snapshot.displayName) sync issue",
                body: "Check your local credentials and logs.",
                signature: "error",
                windowLabel: nil,
                kind: .error
            )
        case .success, .notConfigured:
            break
        }

        if let exhausted = snapshot.windows.first(where: { $0.hasExplicitLimit && $0.fractionUsed >= 1.0 }) {
            return CloudAlertDescriptor(
                title: "\(snapshot.displayName) — 100% used",
                body: "\(exhausted.label): \(exhausted.measurementSummary). Resets in \(resetCountdown(for: exhausted.resetDate)).",
                signature: "exhausted|\(exhausted.label)",
                windowLabel: exhausted.label,
                kind: .threshold
            )
        }

        if let critical = snapshot.windows.first(where: { $0.hasExplicitLimit && $0.fractionUsed >= 0.95 }) {
            return CloudAlertDescriptor(
                title: "\(snapshot.displayName) — 95% used",
                body: "\(critical.label): \(critical.measurementSummary). Resets in \(resetCountdown(for: critical.resetDate)).",
                signature: "critical|\(critical.label)",
                windowLabel: critical.label,
                kind: .threshold
            )
        }

        if let warning = snapshot.windows.first(where: { $0.hasExplicitLimit && $0.fractionUsed >= 0.90 }) {
            return CloudAlertDescriptor(
                title: "\(snapshot.displayName) — 90% used",
                body: "\(warning.label): \(warning.measurementSummary). Resets in \(resetCountdown(for: warning.resetDate)).",
                signature: "warning|\(warning.label)",
                windowLabel: warning.label,
                kind: .threshold
            )
        }

        return nil
    }

    private func resetCountdown(for date: Date?) -> String {
        guard let date else { return "soon" }
        let seconds = date.timeIntervalSinceNow
        guard seconds > 0 else { return "now" }
        let totalMinutes = max(Int(seconds / 60), 1)
        let h = totalMinutes / 60
        let m = totalMinutes % 60
        if h > 0 && m > 0 { return "\(h)h \(m)m" }
        if h > 0 { return "\(h)h" }
        return "\(m)m"
    }

    private func formatMetric(_ value: Double) -> String {
        String(format: "%.6f", value)
    }

    private func loadAccountStatus() async -> CKAccountStatus {
        do {
            return try await container.accountStatus()
        } catch {
            return .couldNotDetermine
        }
    }

    private func debugStateKey(for operation: CloudDebugOperation) -> String {
        switch operation {
        case .publish:
            return publishDebugStateKey
        case .fetch:
            return fetchDebugStateKey
        case .subscriptions:
            return subscriptionDebugStateKey
        }
    }

    private func loadOperationState(_ operation: CloudDebugOperation) -> CloudSyncOperationDebugState {
        guard let data = defaults.data(forKey: debugStateKey(for: operation)),
              let state = try? decoder.decode(CloudSyncOperationDebugState.self, from: data) else {
            return .empty
        }

        return state
    }

    private func saveOperationState(_ state: CloudSyncOperationDebugState, for operation: CloudDebugOperation) {
        guard let data = try? encoder.encode(state) else { return }
        defaults.set(data, forKey: debugStateKey(for: operation))
    }

    private func cloudKitErrorDescription(_ error: Error, depth: Int = 0) -> String {
        guard let ckError = error as? CKError else {
            return error.localizedDescription
        }

        var parts = [
            "\(ckError.localizedDescription) [\(ckError.code)]"
        ]

        if depth < 2,
           let partialErrors = ckError.userInfo[CKPartialErrorsByItemIDKey] as? [CKRecord.ID: Error],
           !partialErrors.isEmpty {
            let partialSummary = partialErrors
                .sorted { $0.key.recordName < $1.key.recordName }
                .map { recordID, partialError in
                    "\(recordID.recordName)=\(cloudKitErrorDescription(partialError, depth: depth + 1))"
                }
                .joined(separator: ", ")
            parts.append("partialErrors{\(partialSummary)}")
        }

        return parts.joined(separator: " ")
    }

    private func recordOperationAttempt(_ operation: CloudDebugOperation) {
        var state = loadOperationState(operation)
        state.lastAttemptAt = Date()
        saveOperationState(state, for: operation)
    }

    private func recordOperationSuccess(_ operation: CloudDebugOperation) {
        var state = loadOperationState(operation)
        let now = Date()
        state.lastAttemptAt = state.lastAttemptAt ?? now
        state.lastSuccessAt = now
        state.lastErrorDescription = nil
        saveOperationState(state, for: operation)
    }

    private func recordOperationFailure(_ operation: CloudDebugOperation, error: Error) {
        var state = loadOperationState(operation)
        state.lastAttemptAt = Date()
        state.lastErrorDescription = cloudKitErrorDescription(error)
        saveOperationState(state, for: operation)
    }

    private func accountStatusTitle(_ status: CKAccountStatus) -> String {
        switch status {
        case .available:
            return "Connected"
        case .noAccount:
            return "No iCloud account"
        case .restricted:
            return "Restricted"
        case .couldNotDetermine:
            return "Could not determine"
        case .temporarilyUnavailable:
            return "Temporarily unavailable"
        @unknown default:
            return "Unknown"
        }
    }

    #if os(iOS)
    private func notificationAuthorizationTitle(_ status: UNAuthorizationStatus) -> String {
        switch status {
        case .authorized, .provisional, .ephemeral:
            return "Allowed"
        case .denied:
            return "Denied"
        case .notDetermined:
            return "Not requested"
        @unknown default:
            return "Unknown"
        }
    }
    #endif
}
