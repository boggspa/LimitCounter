import CloudKit
import CryptoKit
import Foundation
#if os(iOS)
import UserNotifications
#endif

enum CloudKitSyncError: LocalizedError {
    case accountUnavailable
    case statusPublishFailed(String)
    case statusFetchFailed(String)

    var errorDescription: String? {
        switch self {
        case .accountUnavailable:
            return "iCloud is unavailable for CloudKit sync."
        case .statusPublishFailed(let message), .statusFetchFailed(let message):
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
    var resetKind: QuotaResetKind? = nil
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
    private let publishedResetSignaturesKey = "cloudkit.publishedResetSignatures.v1"
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
    private let modelUsageRecordType = "ModelUsageArchive"
    /// Schema 1 subset (Codex and Claude only) for builds that attribute every other
    /// source to Claude; current builds read the schema 2 record first.
    private let modelUsageRecordID = CKRecord.ID(recordName: "model-usage-rollups-v1")
    private let modelUsageV2RecordID = CKRecord.ID(recordName: "model-usage-rollups-v2")

    init() {
        database = container.privateCloudDatabase
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
    }

    /// Separate asset: never put a year's rollups into the quota/widget snapshot.
    /// The latest collecting Mac is the publisher, matching the existing status model.
    func publishModelUsage(_ archive: ModelUsageArchive) async throws {
        try await publishModelUsage(archive, recordID: modelUsageV2RecordID, hashKey: "cloudkit.modelUsage.publishedHash.v2")
        try await publishModelUsage(archive.legacySubset, recordID: modelUsageRecordID, hashKey: "cloudkit.modelUsage.publishedHash.v1")
    }

    private func publishModelUsage(_ archive: ModelUsageArchive, recordID: CKRecord.ID, hashKey: String) async throws {
        let payload = try archive.cloudEncoded()
        let hash = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
        guard defaults.string(forKey: hashKey) != hash else { return }
        guard try await container.accountStatus() == .available else { throw CloudKitSyncError.accountUnavailable }
        let record: CKRecord
        do {
            record = try await database.record(for: recordID)
            if let date = record["generatedAt"] as? Date, date > archive.generatedAt { return }
        } catch let error as CKError where error.code == .unknownItem {
            record = CKRecord(recordType: modelUsageRecordType, recordID: recordID)
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("model-usage-\(UUID().uuidString).lzfse")
        try payload.write(to: url, options: .atomic)
        defer { try? FileManager.default.removeItem(at: url) }
        record["archive"] = CKAsset(fileURL: url)
        record["generatedAt"] = archive.generatedAt as NSDate
        record["schemaVersion"] = archive.version as NSNumber
        record["rateVersion"] = archive.rateVersion as NSString
        _ = try await database.save(record)
        // Only record success: a failed publication remains eligible for the next refresh.
        defaults.set(hash, forKey: hashKey)
    }

    /// Prefers the schema 2 record; falls back to schema 1 until a current Mac publishes.
    func fetchModelUsage() async throws -> ModelUsageArchive? {
        guard try await container.accountStatus() == .available else { throw CloudKitSyncError.accountUnavailable }
        for recordID in [modelUsageV2RecordID, modelUsageRecordID] {
            do {
                let record = try await database.record(for: recordID)
                guard let asset = record["archive"] as? CKAsset, let url = asset.fileURL else { continue }
                let data = try Data(contentsOf: url)
                return try ModelUsageArchive.decodeCloud(data)
            } catch let error as CKError where error.code == .unknownItem { continue }
        }
        return nil
    }

    func ensureModelUsageSubscription() async throws {
        let id = "model-usage-rollups-silent-v1"
        guard !defaults.bool(forKey: "cloudkit.\(id)") else { return }
        let subscription = CKQuerySubscription(recordType: modelUsageRecordType, predicate: NSPredicate(value: true),
            subscriptionID: id, options: [.firesOnRecordCreation, .firesOnRecordUpdate])
        let info = CKSubscription.NotificationInfo(); info.shouldSendContentAvailable = true
        subscription.notificationInfo = info
        _ = try await database.modifySubscriptions(saving: [subscription], deleting: [])
        defaults.set(true, forKey: "cloudkit.\(id)")
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

    func fetchRemoteSnapshots(retaining cachedSnapshots: [QuotaSnapshot] = []) async throws -> [QuotaSnapshot] {
        recordOperationAttempt(.fetch)

        do {
            guard try await container.accountStatus() == .available else {
                throw CloudKitSyncError.accountUnavailable
            }

            var payloads: [CloudSnapshotPayload] = []
            var failures: [String] = []

            for providerID in ProviderID.allCases {
                // Skip the heatmap virtual provider
                guard providerID != .heatmap else { continue }

                let recordID = CKRecord.ID(recordName: statusRecordName(for: providerID))

                do {
                    let record = try await database.record(for: recordID)
                    guard let payloadData = record["payloadData"] as? Data else {
                        throw CloudSnapshotPayload.PayloadError.invalidRoster
                    }
                    let payload = try decoder.decode(CloudSnapshotPayload.self, from: payloadData)
                    try payload.validate(providerID: providerID)
                    payloads.append(payload)
                } catch let error as CKError where error.code == .unknownItem {
                    continue
                } catch {
                    failures.append(providerID.displayName)
                    print("[CloudKitSync] Failed to decode record for \(providerID.rawValue): \(error.localizedDescription)")
                    continue
                }
            }

            if failures.isEmpty {
                recordOperationSuccess(.fetch)
            } else {
                recordOperationFailure(.fetch, error: CloudKitSyncError.statusFetchFailed(
                    "Kept cached accounts for providers that could not be refreshed: \(failures.joined(separator: ", "))."
                ))
            }
            return CloudSnapshotPayload.merging(payloads, into: cachedSnapshots)
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
            var publishedResetSignatures = defaults.stringArray(forKey: publishedResetSignaturesKey) ?? []
            for signature in lastAlertSignatures.values where signature.hasPrefix("reset|") {
                publishedResetSignatures = ResetAlertPublication.remember(signature, in: publishedResetSignatures)
            }
            var emittedAlerts: [CloudAlertPayload] = []
            var statusFailures: [String] = []
            var alertFailures: [String] = []

            let snapshotsByProvider = Dictionary(grouping: snapshots.filter { $0.providerID != .heatmap }, by: \.providerID)
            var failedProviders = Set<ProviderID>()
            for providerID in ProviderID.allCases {
                guard let accounts = snapshotsByProvider[providerID] else { continue }
                let providerKey = providerID.rawValue
                let statusSnapshots = accounts.map { cloudStatusSnapshot(for: $0) }
                // Version forces an upgrade publication even when readings have
                // not changed. Account order, labels and membership also matter.
                let currentHash = CloudSnapshotPayload.statusHash(for: statusSnapshots)
                let previousHash = publishedHashes[providerKey]

                if previousHash != currentHash {
                    do {
                        try await saveStatusRecord(CloudSnapshotPayload(snapshots: statusSnapshots), statusHash: currentHash)
                        publishedHashes[providerKey] = currentHash
                    } catch {
                        let detail = cloudKitErrorDescription(error)
                        statusFailures.append("\(providerKey): \(detail)")
                        failedProviders.insert(providerID)
                        print("[CloudKitSync] Status publish failed for \(providerKey): \(detail)")
                        continue
                    }
                }
            }

            for snapshot in snapshots where !failedProviders.contains(snapshot.providerID) {
                let providerKey = snapshot.accountKey.rawValue
                let alertDescriptor = alertDescriptor(for: snapshot)

                if let alertDescriptor {
                    let isReset = alertDescriptor.kind.isUsageReset || alertDescriptor.kind == .resetAvailable
                    if ResetAlertPublication.shouldPublish(
                        signature: alertDescriptor.signature, kind: alertDescriptor.kind,
                        lastSignature: lastAlertSignatures[providerKey], resetHistory: publishedResetSignatures
                    ) {
                        let createdAt = Date()
                        do {
                            let created = try await saveAlertRecord(snapshot, descriptor: alertDescriptor, createdAt: createdAt)
                            lastAlertSignatures[providerKey] = alertDescriptor.signature
                            if isReset {
                                publishedResetSignatures = ResetAlertPublication.remember(alertDescriptor.signature, in: publishedResetSignatures)
                                defaults.set(publishedResetSignatures, forKey: publishedResetSignaturesKey)
                            }
                            guard created else { continue }
                            emittedAlerts.append(
                                CloudAlertPayload(
                                    providerID: snapshot.providerID,
                                    title: alertDescriptor.title,
                                    body: alertDescriptor.body,
                                    signature: alertDescriptor.signature,
                                    createdAt: createdAt,
                                    windowLabel: alertDescriptor.windowLabel,
                                    kind: alertDescriptor.kind,
                                    resetKind: alertDescriptor.resetKind,
                                    accountSlot: snapshot.accountSlot,
                                    accountLabel: snapshot.accountLabel
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
            defaults.set(publishedResetSignatures, forKey: publishedResetSignaturesKey)

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

    func accountKey(fromNotificationUserInfo userInfo: [AnyHashable: Any]) -> ProviderAccountKey? {
        if let payload = extractAlertPayloads(from: userInfo).first { return payload.accountKey }
        guard let raw = userInfo["providerID"] as? String, let providerID = ProviderID(rawValue: raw) else { return nil }
        let metadata = CloudAlertPayload.cloudAccount(from: userInfo["signature"] as? String ?? "", providerID: providerID)
        return ProviderAccountKey(providerID: providerID, slot: userInfo["accountSlot"] as? String ?? metadata.slot)
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
        let account = CloudAlertPayload.cloudAccount(from: signature, providerID: providerID)
        let createdAt = (fields["createdAt"] as? Date) ?? Date()
        let fieldLabel = (fields["windowLabel"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let fieldKind = (fields["kind"] as? String).flatMap(CloudAlertKind.init(rawValue:))
        let fieldResetKind = (fields["resetKind"] as? String).flatMap(QuotaResetKind.init(rawValue:))
        return CloudAlertPayload(
            providerID: providerID,
            title: title,
            body: body,
            signature: signature,
            createdAt: createdAt,
            windowLabel: fieldLabel?.isEmpty == false ? fieldLabel : parsed.windowLabel,
            kind: fieldKind ?? parsed.kind,
            resetKind: fieldResetKind ?? parsed.resetKind,
            accountSlot: account.slot,
            accountLabel: account.label ?? QuotaSnapshotStore.shared.snapshot(
                for: ProviderAccountKey(providerID: providerID, slot: account.slot)
            )?.accountLabel
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

    private func saveStatusRecord(_ payload: CloudSnapshotPayload, statusHash: String) async throws {
        let snapshot = payload.primary
        let recordID = CKRecord.ID(recordName: statusRecordName(for: snapshot.providerID))
        let record = CKRecord(recordType: statusRecordType, recordID: recordID)

        record["providerID"] = snapshot.providerID.rawValue as NSString
        record["displayName"] = snapshot.displayName as NSString
        if let planName = snapshot.planName, !planName.isEmpty {
            record["planName"] = planName as NSString
        }
        record["fetchedAt"] = (payload.snapshots.map(\.fetchedAt).max() ?? snapshot.fetchedAt) as NSDate
        record["summary"] = snapshotSummary(for: snapshot) as NSString
        record["statusHash"] = statusHash as NSString
        let payloadData = try payload.encoded(maxBytes: maxCloudStatusPayloadBytes)
        record["payloadVersion"] = CloudSnapshotPayload.currentVersion as NSNumber
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

    private func saveAlertRecord(_ snapshot: QuotaSnapshot, descriptor: CloudAlertDescriptor, createdAt: Date) async throws -> Bool {
        let isReset = descriptor.kind.isUsageReset || descriptor.kind == .resetAvailable
        let recordID = CKRecord.ID(recordName: isReset
            ? ResetAlertPublication.recordName(signature: descriptor.signature)
            : "alert.\(UUID().uuidString)")
        let record = CKRecord(recordType: alertRecordType, recordID: recordID)

        record["providerID"] = snapshot.providerID.rawValue as NSString
        record["title"] = descriptor.title as NSString
        record["body"] = descriptor.body as NSString
        record["signature"] = descriptor.signature as NSString
        record["kind"] = descriptor.kind.rawValue as NSString
        if let resetKind = descriptor.resetKind {
            record["resetKind"] = resetKind.rawValue as NSString
        }
        if let windowLabel = descriptor.windowLabel, !windowLabel.isEmpty {
            record["windowLabel"] = windowLabel as NSString
        }
        record["createdAt"] = createdAt as NSDate
        record["statusRecordName"] = statusRecordName(for: snapshot.providerID) as NSString

        do {
            _ = try await database.save(record)
            return true
        } catch let error as CKError where isReset && error.code == .serverRecordChanged {
            // Creation raced, or a prior successful response was lost. Never
            // rewrite its createdAt or emit another notification locally.
            guard let existing = error.userInfo[CKRecordChangedErrorServerRecordKey] as? CKRecord,
                  existing["signature"] as? String == descriptor.signature else { throw error }
            return false
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

    private func copySnapshot(
        _ snapshot: QuotaSnapshot,
        events: [UsageEvent],
        analyticsBuckets: [UsageAnalyticsBucket]
    ) -> QuotaSnapshot {
        CloudSnapshotPayload.replacingActivity(in: snapshot, events: events, analyticsBuckets: analyticsBuckets)
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

    private func alertDescriptor(for snapshot: QuotaSnapshot) -> CloudAlertDescriptor? {
        guard let descriptor = baseAlertDescriptor(for: snapshot) else { return nil }
        return CloudAlertDescriptor(
            title: descriptor.title, body: descriptor.body,
            signature: CloudAlertPayload.cloudSignature(descriptor.signature, account: snapshot.accountKey, label: snapshot.accountLabel),
            windowLabel: descriptor.windowLabel, kind: descriptor.kind, resetKind: descriptor.resetKind
        )
    }

    private func baseAlertDescriptor(for snapshot: QuotaSnapshot) -> CloudAlertDescriptor? {
        guard snapshot.providerID != .heatmap,
              snapshot.providerID != .codexTelemetry else {
            return nil
        }

        if let resetAlert = UsageResetAlertBuilder.resetAlert(
            for: snapshot,
            noticedAt: Date(),
            freshnessWindow: 30 * 60
        ) {
            guard resetAlert.isAnnounceable else { return nil }
            return CloudAlertDescriptor(
                title: resetAlert.title,
                body: resetAlert.body,
                signature: resetAlert.signature,
                windowLabel: resetAlert.windowLabel,
                kind: resetAlert.kind,
                resetKind: resetAlert.resetKind
            )
        }

        switch snapshot.fetchState {
        case .error:
            return CloudAlertDescriptor(
                title: "\(snapshot.accountDisplayName) sync issue",
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
                title: "\(snapshot.accountDisplayName) — 100% used",
                body: "\(exhausted.label): \(exhausted.measurementSummary). Resets in \(resetCountdown(for: exhausted.resetDate)).",
                signature: "exhausted|\(exhausted.label)",
                windowLabel: exhausted.label,
                kind: .threshold
            )
        }

        if let critical = snapshot.windows.first(where: { $0.hasExplicitLimit && $0.fractionUsed >= 0.95 }) {
            return CloudAlertDescriptor(
                title: "\(snapshot.accountDisplayName) — 95% used",
                body: "\(critical.label): \(critical.measurementSummary). Resets in \(resetCountdown(for: critical.resetDate)).",
                signature: "critical|\(critical.label)",
                windowLabel: critical.label,
                kind: .threshold
            )
        }

        if let warning = snapshot.windows.first(where: { $0.hasExplicitLimit && $0.fractionUsed >= 0.90 }) {
            return CloudAlertDescriptor(
                title: "\(snapshot.accountDisplayName) — 90% used",
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
