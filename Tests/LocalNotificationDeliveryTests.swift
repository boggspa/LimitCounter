import Foundation
import UserNotifications

private enum DeliveryTestFailure: Error, CustomStringConvertible {
    case failed(String)
    var description: String {
        switch self { case .failed(let message): return message }
    }
}

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw DeliveryTestFailure.failed(message) }
}

private func alert(
    _ suffix: String,
    kind: CloudAlertKind = .resetAvailable,
    resetKind: QuotaResetKind = .bankedAvailable,
    createdAt: Date = Date()
) -> CloudAlertPayload {
    CloudAlertPayload(
        providerID: .openai,
        title: "Codex reset available",
        body: "A reset is available.",
        signature: "reset|openai|\(kind.rawValue)|\(suffix)|Banked reset|\(resetKind.rawValue)",
        createdAt: createdAt,
        windowLabel: "Banked reset",
        kind: kind,
        resetKind: resetKind
    )
}

@MainActor
private final class SuspendedDelivery {
    var requests: [UNNotificationRequest] = []
    var pending: [String: CheckedContinuation<Void, Error>] = [:]

    func deliver(_ request: UNNotificationRequest) async throws {
        requests.append(request)
        try await withCheckedThrowingContinuation { continuation in
            pending[request.identifier] = continuation
        }
    }

    func finish(_ signature: String, error: Error? = nil) {
        guard let continuation = pending.removeValue(forKey: signature) else { return }
        if let error { continuation.resume(throwing: error) }
        else { continuation.resume() }
    }

    func waitForCount(_ count: Int) async throws {
        for _ in 0..<1_000 {
            if requests.count >= count { return }
            await Task.yield()
        }
        throw DeliveryTestFailure.failed("delivery did not start")
    }
}

private enum Platform: String, CaseIterable {
    case mac, ios
    var key: String { "\(rawValue).postedAlertSignatures" }
}

private func availableSnapshots() -> [QuotaSnapshot] {
    [QuotaSnapshot(
        providerID: .openai, displayName: "Codex", windows: [], fetchedAt: Date(),
        resetCredits: QuotaResetCreditSummary(availableCount: 1)
    )]
}

@MainActor
private func publisher(
    _ platform: Platform,
    defaults: UserDefaults,
    snapshots: @escaping () -> [QuotaSnapshot] = { availableSnapshots() },
    deliver: @escaping (UNNotificationRequest) async throws -> Void
) -> ([CloudAlertPayload]) async -> Void {
    switch platform {
    case .mac:
        let publisher = MacLocalNotificationPublisher(defaults: defaults, currentSnapshots: snapshots, deliver: deliver)
        return { await publisher.processEmittedAlerts($0) }
    case .ios:
        let publisher = LocalNotificationPublisher(defaults: defaults, currentSnapshots: snapshots, deliver: deliver)
        return { await publisher.processIncomingAlerts($0) }
    }
}

@MainActor
private func withDefaults(_ body: (UserDefaults) async throws -> Void) async throws {
    let suite = "local-notification-delivery-tests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    try await body(defaults)
}

@MainActor
private func testConcurrentDuplicate(_ platform: Platform) async throws {
    try await withDefaults { defaults in
        let delivery = SuspendedDelivery()
        let process = publisher(platform, defaults: defaults, deliver: delivery.deliver)
        let payload = alert("concurrent")
        let first = Task { await process([payload]) }
        try await delivery.waitForCount(1)
        // The same event arriving via a second path while add() awaits must
        // stop before calling the notification center a second time.
        await process([payload])
        try expect(delivery.requests.count == 1, "\(platform): concurrent duplicate was delivered")
        delivery.finish(payload.signature)
        await first.value
        await process([payload])
        try expect(delivery.requests.count == 1, "\(platform): completed duplicate was delivered")
    }
}

@MainActor
private func testIndependentCompletionOrder(_ platform: Platform) async throws {
    try await withDefaults { defaults in
        let delivery = SuspendedDelivery()
        let process = publisher(platform, defaults: defaults, deliver: delivery.deliver)
        let firstPayload = alert("first")
        let secondPayload = alert("second")
        let first = Task { await process([firstPayload]) }
        try await delivery.waitForCount(1)
        let second = Task { await process([secondPayload]) }
        try await delivery.waitForCount(2)
        delivery.finish(secondPayload.signature)
        await second.value
        delivery.finish(firstPayload.signature)
        await first.value
        let posted = defaults.stringArray(forKey: platform.key) ?? []
        try expect(Set(posted) == Set([firstPayload.signature, secondPayload.signature]), "\(platform): the later completion lost another successful signature")
        await process([firstPayload, secondPayload])
        try expect(delivery.requests.count == 2, "\(platform): one successful delivery was forgotten")
    }
}

@MainActor
private func testFailureCanRetry(_ platform: Platform) async throws {
    try await withDefaults { defaults in
        var attempts = 0
        let process = publisher(platform, defaults: defaults) { _ in
            attempts += 1
            if attempts == 1 { throw DeliveryTestFailure.failed("expected delivery failure") }
        }
        let payload = alert("retry")
        await process([payload])
        try expect((defaults.stringArray(forKey: platform.key) ?? []).isEmpty, "\(platform): failed delivery persisted as successful")
        await process([payload])
        await process([payload])
        try expect(attempts == 2, "\(platform): failed delivery did not retry exactly once")
    }
}

@MainActor
private func testQuietResetKinds(_ platform: Platform) async throws {
    try await withDefaults { defaults in
        var attempts = 0
        let process = publisher(platform, defaults: defaults) { _ in attempts += 1 }
        await process([
            alert("redeemed", kind: .unexpectedRecovery, resetKind: .bankedRedeemed),
            alert("scheduled", kind: .scheduledReset, resetKind: .scheduled),
            alert("gifted", kind: .unexpectedRecovery, resetKind: .gifted)
        ])
        try expect(attempts == 1, "\(platform): expected only the gifted reset to announce")
    }
}

@MainActor
private func testRedeemedAvailabilityIsSuppressed(_ platform: Platform) async throws {
    try await withDefaults { defaults in
        let payload = alert("stale")
        let now = Date().addingTimeInterval(1)
        let snapshot = QuotaSnapshot(
            providerID: .openai, displayName: "Codex", windows: [], fetchedAt: now,
            resetCredits: QuotaResetCreditSummary(availableCount: 0, observedAt: now)
        )
        var attempts = 0
        let process = publisher(platform, defaults: defaults, snapshots: { [snapshot] }) { _ in attempts += 1 }
        await process([payload])
        try expect(attempts == 0, "\(platform): availability replayed after an authoritative zero reading")
    }
}

@MainActor
private func testVisibleRemoteDeliveryIsRemembered() async throws {
    try await withDefaults { defaults in
        let delivery = SuspendedDelivery()
        let publisher = LocalNotificationPublisher(defaults: defaults, currentSnapshots: { availableSnapshots() }, deliver: delivery.deliver)
        let local = alert("in-flight-local")
        let remote = alert("already-visible-remote")
        let localTask = Task { await publisher.processIncomingAlerts([local]) }
        try await delivery.waitForCount(1)
        publisher.markDelivered([remote])
        delivery.finish(local.signature)
        await localTask.value
        await publisher.processIncomingAlerts([remote, local])
        try expect(delivery.requests.count == 1, "iOS: visible APNs or interleaved local delivery replayed")
        try expect(Set(defaults.stringArray(forKey: "ios.postedAlertSignatures") ?? []) == Set([local.signature, remote.signature]), "iOS: remote signature was overwritten after an await")
    }
}

@MainActor
private func testColdHistoryStaysQuiet() async throws {
    try await withDefaults { defaults in
        var attempts = 0
        let publisher = LocalNotificationPublisher(defaults: defaults, currentSnapshots: { availableSnapshots() }) { _ in attempts += 1 }
        let old = alert("historical", createdAt: Date().addingTimeInterval(-10 * 60))
        let fresh = alert("fresh")
        await publisher.processIncomingAlerts([old, fresh])
        await publisher.processIncomingAlerts([old, fresh])
        try expect(attempts == 1, "iOS: cold history was announced on a later silent refresh")
    }
}

@main
struct LocalNotificationDeliveryTests {
    @MainActor static func main() async throws {
        var count = 0
        for platform in Platform.allCases {
            try await testConcurrentDuplicate(platform)
            try await testIndependentCompletionOrder(platform)
            try await testFailureCanRetry(platform)
            try await testQuietResetKinds(platform)
            try await testRedeemedAvailabilityIsSuppressed(platform)
            count += 5
        }
        try await testVisibleRemoteDeliveryIsRemembered()
        try await testColdHistoryStaysQuiet()
        count += 2
        print("Passed \(count) local notification delivery tests")
    }
}
