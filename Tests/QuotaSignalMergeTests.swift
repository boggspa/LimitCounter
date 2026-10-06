import Foundation
import SQLite3

private enum SignalMergeTestError: Error, CustomStringConvertible {
    case failure(String)

    var description: String {
        switch self {
        case .failure(let message): return message
        }
    }
}

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw SignalMergeTestError.failure(message) }
}

private func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: String) throws {
    if actual != expected {
        throw SignalMergeTestError.failure("\(message): expected \(expected), got \(actual)")
    }
}

private func expectClose(_ actual: Double, _ expected: Double, _ tolerance: Double, _ message: String) throws {
    if abs(actual - expected) > tolerance {
        throw SignalMergeTestError.failure("\(message): expected \(expected), got \(actual)")
    }
}

private func signal(
    _ title: String,
    kind: QuotaSignalKind = .scheduledReset,
    windowLabel: String? = nil,
    message: String = "body",
    detectedAt: Date = Date()
) -> QuotaSignal {
    QuotaSignal(
        kind: kind,
        title: title,
        message: message,
        severity: .warning,
        windowLabel: windowLabel,
        detectedAt: detectedAt
    )
}

private func snapshot(signals: [QuotaSignal]) -> QuotaSnapshot {
    QuotaSnapshot(
        providerID: .devin,
        displayName: "Devin",
        signals: signals,
        fetchState: .success
    )
}

// MARK: - QuotaSnapshot.mergingSignals

/// The regression this whole file exists for: `SnapshotSignalDetector`
/// used to call `withSignals(detected)`, which replaced — and therefore
/// discarded — everything the provider client had attached.
private func testMergingSignalsKeepsProviderAndDetectedSignals() throws {
    let providerSignal = signal("Devin quota reading is stale")
    let detected = signal("Daily quota reset", windowLabel: "Daily quota (live)")

    let merged = snapshot(signals: [providerSignal]).mergingSignals([detected])

    try expectEqual(merged.signals.count, 2, "merged signal count")
    try expect(
        merged.signals.contains { $0.title == "Devin quota reading is stale" },
        "provider-supplied signal must survive the detector"
    )
    try expect(
        merged.signals.contains { $0.title == "Daily quota reset" },
        "detected signal must survive alongside the provider's"
    )
    try expectEqual(
        merged.signals.first?.title,
        "Devin quota reading is stale",
        "provider signals keep their order and lead"
    )
}

private func testMergingSignalsDropsContentDuplicateDetectedSignal() throws {
    let providerSignal = signal("Weekly quota reset", windowLabel: "Weekly quota (live)")
    // Same content, different `id` and `detectedAt` — `QuotaSignal`'s own
    // Hashable conformance would treat this as a distinct value, so the
    // merge has to compare content or the card shows the notice twice.
    let detected = signal(
        "Weekly quota reset",
        windowLabel: "Weekly quota (live)",
        detectedAt: Date().addingTimeInterval(-3600)
    )

    let merged = snapshot(signals: [providerSignal]).mergingSignals([detected])

    try expectEqual(merged.signals.count, 1, "duplicate signal must collapse")
    try expectEqual(merged.signals.first?.id, providerSignal.id, "provider copy wins on duplicate")
}

private func testMergingSignalsPreservesEachSideAlone() throws {
    let providerSignal = signal("Devin quota reading is stale")
    let detected = signal("Daily quota reset", windowLabel: "Daily quota (live)")

    // Provider signals, no detected signals: previously became `[]`.
    let providerOnly = snapshot(signals: [providerSignal]).mergingSignals([])
    try expectEqual(providerOnly.signals.count, 1, "provider signals survive with no detections")

    // No provider signals: the pre-existing behaviour for most providers.
    let detectedOnly = snapshot(signals: []).mergingSignals([detected])
    try expectEqual(detectedOnly.signals.count, 1, "detected signals still land unchanged")
    try expectEqual(detectedOnly.signals.first?.title, "Daily quota reset", "detected signal identity")

    let neither = snapshot(signals: []).mergingSignals([])
    try expect(neither.signals.isEmpty, "empty in, empty out")
}

/// `withSignals` is still the replace-everything primitive, and other
/// callers (including the CodexUsageKit copy) rely on that.
private func testWithSignalsStillReplaces() throws {
    let replaced = snapshot(signals: [signal("provider")]).withSignals([signal("detected")])
    try expectEqual(replaced.signals.count, 1, "withSignals replaces rather than merges")
    try expectEqual(replaced.signals.first?.title, "detected", "withSignals keeps the argument")
}

// MARK: - Devin state.vscdb fixture

private func devinPlanJSON(
    identity: String,
    dailyRemainingPercent: Int,
    weeklyRemainingPercent: Int,
    dailyResetAtUnix: Int,
    weeklyResetAtUnix: Int,
    overageBalanceMicros: Int,
    hasBillingWritePermissions: Bool,
    endTimestampMilliseconds: Int
) -> String {
    """
    {"planName":"Devin Team","startTimestamp":0,"endTimestamp":\(endTimestampMilliseconds),\
    "hideDailyQuota":false,"hideWeeklyQuota":false,"accountIdentityText":"\(identity)",\
    "hasBillingWritePermissions":\(hasBillingWritePermissions),\
    "quotaUsage":{"dailyRemainingPercent":\(dailyRemainingPercent),\
    "weeklyRemainingPercent":\(weeklyRemainingPercent),\
    "overageBalanceMicros":\(overageBalanceMicros),\
    "dailyResetAtUnix":\(dailyResetAtUnix),"weeklyResetAtUnix":\(weeklyResetAtUnix)}}
    """
}

private func seedDevinDatabase(at url: URL, rows: [(key: String, value: String)]) throws {
    var handle: OpaquePointer?
    guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK,
          let db = handle else {
        if let handle { sqlite3_close(handle) }
        throw SignalMergeTestError.failure("could not create \(url.path)")
    }
    defer { sqlite3_close(db) }

    var sql = "CREATE TABLE ItemTable (key TEXT PRIMARY KEY, value TEXT);"
    for row in rows {
        let escaped = row.value.replacingOccurrences(of: "'", with: "''")
        sql += "INSERT INTO ItemTable (key, value) VALUES ('\(row.key)', '\(escaped)');"
    }

    var errorPointer: UnsafeMutablePointer<CChar>?
    guard sqlite3_exec(db, sql, nil, nil, &errorPointer) == SQLITE_OK else {
        let detail = errorPointer.map { String(cString: $0) } ?? "unknown error"
        sqlite3_free(errorPointer)
        throw SignalMergeTestError.failure("failed to seed ItemTable: \(detail)")
    }
}

/// Builds a two-account `state.vscdb` matching the shape the Devin/Windsurf
/// editor writes, and back-dates it so `cachedAt` is meaningfully stale.
private func makeDevinState(cacheAge: TimeInterval) throws -> (url: URL, root: URL, cachedAt: Date) {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("limit-counter-devin-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let url = root.appendingPathComponent("state.vscdb")

    let now = Date()
    let past = Int(now.addingTimeInterval(-11 * 86_400).timeIntervalSince1970)
    let future = Int(now.addingTimeInterval(6 * 3_600).timeIntervalSince1970)
    let futureWeekly = Int(now.addingTimeInterval(4 * 86_400).timeIntervalSince1970)
    let endTimestamp = Int(now.addingTimeInterval(20 * 86_400).timeIntervalSince1970) * 1_000

    try seedDevinDatabase(
        at: url,
        rows: [
            (
                // Signed-out second account: both reset dates are long past,
                // and the cache reports a tiny negative overage balance.
                key: "reactSettings.cachedPlanInfoData:user-stale",
                value: devinPlanJSON(
                    identity: "stale@example.com - Former Teammate",
                    dailyRemainingPercent: 0,
                    weeklyRemainingPercent: 0,
                    dailyResetAtUnix: past,
                    weeklyResetAtUnix: past,
                    overageBalanceMicros: -250_000,
                    hasBillingWritePermissions: false,
                    endTimestampMilliseconds: endTimestamp
                )
            ),
            (
                key: "reactSettings.cachedPlanInfoData:user-live",
                value: devinPlanJSON(
                    identity: "live@example.com - Jane Doe",
                    dailyRemainingPercent: 65,
                    weeklyRemainingPercent: 80,
                    dailyResetAtUnix: future,
                    weeklyResetAtUnix: futureWeekly,
                    overageBalanceMicros: 4_500_000,
                    hasBillingWritePermissions: true,
                    endTimestampMilliseconds: endTimestamp
                )
            )
        ]
    )

    let cachedAt = now.addingTimeInterval(-cacheAge)
    try FileManager.default.setAttributes([.modificationDate: cachedAt], ofItemAtPath: url.path)
    return (url, root, cachedAt)
}

private func fetchDevinSnapshot(databaseURL: URL) async throws -> QuotaSnapshot {
    try await DevinProviderClient().fetchSnapshot(
        credentials: ProviderCredential(customEndpoint: databaseURL.path)
    )
}

/// A one-account `state.vscdb` with both meters live.
private func makeSingleAccountDevinState(identity: String) throws -> (url: URL, root: URL) {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("limit-counter-devin-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let url = root.appendingPathComponent("state.vscdb")

    let now = Date()
    try seedDevinDatabase(
        at: url,
        rows: [
            (
                key: "reactSettings.cachedPlanInfoData:user-solo",
                value: devinPlanJSON(
                    identity: identity,
                    dailyRemainingPercent: 65,
                    weeklyRemainingPercent: 80,
                    dailyResetAtUnix: Int(now.addingTimeInterval(6 * 3_600).timeIntervalSince1970),
                    weeklyResetAtUnix: Int(now.addingTimeInterval(4 * 86_400).timeIntervalSince1970),
                    overageBalanceMicros: 4_500_000,
                    hasBillingWritePermissions: false,
                    endTimestampMilliseconds: Int(now.addingTimeInterval(20 * 86_400).timeIntervalSince1970) * 1_000
                )
            )
        ]
    )
    return (url, root)
}

// MARK: - Devin behaviour

private func testDevinDropsExpiredWindowsAndKeepsFutureDatedOnes() async throws {
    let state = try makeDevinState(cacheAge: 11 * 86_400)
    defer { try? FileManager.default.removeItem(at: state.root) }

    let snapshot = try await fetchDevinSnapshot(databaseURL: state.url)

    // The stale account's meters are dropped (and reported through the
    // signal tested below), so only the live account's two survive.
    try expectEqual(
        snapshot.windows.count,
        2,
        "expired windows must be dropped and future-dated ones kept, got \(snapshot.windows.map(\.label))"
    )
    try expect(
        snapshot.windows.contains { $0.label.hasPrefix("Weekly quota") },
        "missing live weekly window in \(snapshot.windows.map(\.label))"
    )

    guard let daily = snapshot.windows.first(where: { $0.label.hasPrefix("Daily quota") }) else {
        throw SignalMergeTestError.failure("missing live daily window in \(snapshot.windows.map(\.label))")
    }
    try expectClose(daily.used, 35, 0.000_001, "daily used percent")

    // A negative micro-balance would read as credit the user does not have.
    for balance in snapshot.balances {
        try expect(balance.amount >= 0, "balance \(balance.label) must be clamped at zero, got \(balance.amount)")
    }
    try expect(
        snapshot.balances.contains { abs($0.amount - 4.5) < 0.000_001 },
        "a real positive balance must still come through"
    )
}

private func testDevinReportsStaleCacheSignalAndCacheTimestamp() async throws {
    let state = try makeDevinState(cacheAge: 11 * 86_400)
    defer { try? FileManager.default.removeItem(at: state.root) }

    let snapshot = try await fetchDevinSnapshot(databaseURL: state.url)

    guard let stale = snapshot.signals.first(where: { $0.title == "Devin quota reading is stale" }) else {
        throw SignalMergeTestError.failure(
            "expected a stale-cache warning, got \(snapshot.signals.map(\.title))"
        )
    }
    try expectEqual(stale.severity, .warning, "stale-cache signal severity")
    try expect(stale.message.contains("Daily quota (account "), "stale signal names the dropped daily window, got: \(stale.message)")
    try expect(stale.message.contains("Weekly quota (account "), "stale signal names the dropped weekly window, got: \(stale.message)")
    // The dropped meters belong to the other account; the warning must not
    // read as though the live meters on the card were the stale ones.
    for window in snapshot.windows {
        try expect(
            !stale.message.contains(window.label),
            "stale signal must not name the live meter \"\(window.label)\", got: \(stale.message)"
        )
    }
    try expect(stale.message.contains("11 days ago"), "stale signal reports cache age, got: \(stale.message)")

    // Both accounts are merged, so a signal raised for the *other* account
    // has to survive `mergeSnapshots` too.
    try expect(
        snapshot.signals.contains { $0.title == "Billing write permissions enabled" },
        "signals from every merged account must be collected, got \(snapshot.signals.map(\.title))"
    )

    // The merged multi-account snapshot must report the editor's last write,
    // not the moment the snapshot was assembled.
    try expectClose(
        snapshot.fetchedAt.timeIntervalSince1970,
        state.cachedAt.timeIntervalSince1970,
        2,
        "merged snapshot must report the state.vscdb modification time"
    )

    // Every Devin signal describes the cache's contents, so each is stamped
    // with the cache's own timestamp. Stamping them with `now` made the
    // snapshot differ on every sync, which republished its CloudKit status
    // record and pushed a background APNs update to every device.
    for signal in snapshot.signals {
        try expectClose(
            signal.detectedAt.timeIntervalSince1970,
            state.cachedAt.timeIntervalSince1970,
            2,
            "signal \"\(signal.title)\" must be stamped with the cache timestamp, not the clock"
        )
    }
}

/// Two fetches of an unchanged cache must produce byte-identical signals, or
/// the CloudKit status hash churns and every device gets woken each cycle.
private func testDevinSignalsAreStableAcrossRepeatedFetches() async throws {
    let state = try makeDevinState(cacheAge: 11 * 86_400)
    defer { try? FileManager.default.removeItem(at: state.root) }

    let first = try await fetchDevinSnapshot(databaseURL: state.url)
    let second = try await fetchDevinSnapshot(databaseURL: state.url)

    func fingerprint(_ snapshot: QuotaSnapshot) -> [String] {
        snapshot.signals
            .map { signal in
                [
                    signal.kind.rawValue,
                    signal.windowLabel ?? "",
                    signal.title,
                    signal.message,
                    signal.severity.rawValue,
                    String(Int(signal.detectedAt.timeIntervalSince1970))
                ].joined(separator: "|")
            }
            .sorted()
    }

    try expect(!first.signals.isEmpty, "the fixture must raise at least one signal to be worth comparing")
    try expectEqual(
        fingerprint(first),
        fingerprint(second),
        "an unchanged cache must produce identical signals on every fetch"
    )
    try expectClose(
        first.fetchedAt.timeIntervalSince1970,
        second.fetchedAt.timeIntervalSince1970,
        1,
        "an unchanged cache must report the same fetchedAt"
    )
    try expectEqual(
        first.windows.map(\.label),
        second.windows.map(\.label),
        "an unchanged cache must number its accounts the same way on every fetch"
    )
    try expectEqual(
        first.accountFingerprint,
        second.accountFingerprint,
        "an unchanged cache must hash to the same account fingerprint, or every fetch reads as an account switch"
    )
}

/// The end of the pipeline: provider signals must still be present after the
/// detector stage runs and after the app-group store's JSON round trip.
private func testDevinStaleSignalSurvivesDetectionAndPersistence() async throws {
    let state = try makeDevinState(cacheAge: 11 * 86_400)
    defer { try? FileManager.default.removeItem(at: state.root) }

    let fetched = try await fetchDevinSnapshot(databaseURL: state.url)
    let providerTitles = Set(fetched.signals.map(\.title))
    try expect(providerTitles.contains("Devin quota reading is stale"), "precondition: provider emitted the signal")

    guard let liveDaily = fetched.windows.first(where: { $0.label.hasPrefix("Daily quota") }) else {
        throw SignalMergeTestError.failure("precondition: a live daily window, got \(fetched.windows.map(\.label))")
    }

    // Stands in for `SnapshotSignalDetector.enrichedSnapshot`, which merges the
    // signals it derived from the previous snapshot into the fetched one.
    let detected = [signal("\(liveDaily.label) reset", windowLabel: liveDaily.label)]
    let enriched = fetched.mergingSignals(detected)

    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let persisted = try decoder.decode(QuotaSnapshot.self, from: encoder.encode(enriched))

    try expect(
        persisted.signals.contains { $0.title == "Devin quota reading is stale" },
        "the stale warning must reach the persisted snapshot, got \(persisted.signals.map(\.title))"
    )
    try expect(
        persisted.signals.contains { $0.title == "\(liveDaily.label) reset" },
        "the detected signal must reach the persisted snapshot too"
    )
    try expectEqual(
        persisted.signals.count,
        fetched.signals.count + 1,
        "merging must add the detected signal without dropping or duplicating provider ones"
    )
}

/// Window labels, balances and signals ride in the App Group cache the widget
/// reads and in the CloudKit payload, and `QuotaSnapshot` promises that neither
/// ever carries an email or a display name. Devin's identity text has exactly
/// one destination: the hashed `accountFingerprint`.
private func testDevinKeepsAccountIdentityOutOfTheSnapshot() async throws {
    let state = try makeDevinState(cacheAge: 11 * 86_400)
    defer { try? FileManager.default.removeItem(at: state.root) }

    let snapshot = try await fetchDevinSnapshot(databaseURL: state.url)

    var stored = snapshot.windows.map(\.label)
    stored += snapshot.balances.map(\.label)
    stored += snapshot.stats.map(\.label)
    stored += snapshot.signals.flatMap { [$0.title, $0.message, $0.windowLabel ?? ""] }
    stored += [snapshot.planName ?? "", snapshot.accountFingerprint ?? ""]
    for fragment in ["example.com", "live@", "stale@", "Jane", "Teammate"] {
        try expect(
            !stored.contains { $0.localizedCaseInsensitiveContains(fragment) },
            "\"\(fragment)\" must not appear anywhere in the stored snapshot, got \(stored)"
        )
    }

    // The accounts' meters still have to be told apart, because the period
    // layout and the reset detector key a window on its label, so the merged
    // reading numbers them instead.
    try expectEqual(
        Set(snapshot.windows.map(\.label)).count,
        snapshot.windows.count,
        "merged window labels must stay distinct, got \(snapshot.windows.map(\.label))"
    )
    for window in snapshot.windows {
        try expect(
            window.label.hasSuffix(" (account 1)") || window.label.hasSuffix(" (account 2)"),
            "a merged meter is qualified by an ordinal and nothing else, got \"\(window.label)\""
        )
    }

    guard let fingerprint = snapshot.accountFingerprint, !fingerprint.isEmpty else {
        throw SignalMergeTestError.failure("the reading must carry a hashed account fingerprint")
    }
    try expectEqual(
        snapshot.accountFingerprint,
        ProviderAccountFingerprint.make(providerID: .devin, components: ["live@example.com", "stale@example.com"]),
        "the fingerprint hashes every account's address, lowercased and in a fixed order, and nothing else"
    )
}

/// One account in the cache gets plain labels, and its fingerprint follows the
/// address alone: a renamed profile is the same account, a different address
/// is not.
private func testDevinSingleAccountUsesPlainLabelsAndHashesTheAddress() async throws {
    func reading(identity: String) async throws -> QuotaSnapshot {
        let state = try makeSingleAccountDevinState(identity: identity)
        defer { try? FileManager.default.removeItem(at: state.root) }
        return try await fetchDevinSnapshot(databaseURL: state.url)
    }

    let original = try await reading(identity: "Solo@Example.com - Solo Person")
    try expectEqual(original.windows.map(\.label), ["Daily quota", "Weekly quota"], "single-account window labels")
    try expectEqual(original.balances.map(\.label), ["Extra usage balance"], "single-account balance label")
    try expect(original.accountFingerprint != nil, "a single account still reports a fingerprint")

    let renamed = try await reading(identity: "solo@example.com - Renamed Person")
    try expectEqual(original.accountFingerprint, renamed.accountFingerprint, "a renamed profile is the same account")

    let other = try await reading(identity: "other@example.com - Solo Person")
    try expect(original.accountFingerprint != other.accountFingerprint, "a different address is a different account")

    let anonymous = try await reading(identity: "")
    try expect(anonymous.accountFingerprint == nil, "no identity yields no fingerprint rather than a hash of nothing")
}

@main
private enum QuotaSignalMergeTestRunner {
    static func main() async throws {
        try testMergingSignalsKeepsProviderAndDetectedSignals()
        try testMergingSignalsDropsContentDuplicateDetectedSignal()
        try testMergingSignalsPreservesEachSideAlone()
        try testWithSignalsStillReplaces()
        try await testDevinDropsExpiredWindowsAndKeepsFutureDatedOnes()
        try await testDevinReportsStaleCacheSignalAndCacheTimestamp()
        try await testDevinSignalsAreStableAcrossRepeatedFetches()
        try await testDevinStaleSignalSurvivesDetectionAndPersistence()
        try await testDevinKeepsAccountIdentityOutOfTheSnapshot()
        try await testDevinSingleAccountUsesPlainLabelsAndHashesTheAddress()
        print("Quota signal merge tests passed")
    }
}
