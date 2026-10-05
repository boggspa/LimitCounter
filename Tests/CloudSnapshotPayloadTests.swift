import Foundation

private enum CloudSnapshotTestError: Error, CustomStringConvertible {
    case failure(String)

    var description: String {
        switch self {
        case .failure(let message): return message
        }
    }
}

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw CloudSnapshotTestError.failure(message) }
}

private func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: String) throws {
    if actual != expected { throw CloudSnapshotTestError.failure(message) }
}

private func expectFailure(_ message: String, _ body: () throws -> Void) throws {
    do {
        try body()
    } catch {
        return
    }
    throw CloudSnapshotTestError.failure(message)
}

private func encode<T: Encodable>(_ value: T) throws -> Data {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    return try encoder.encode(value)
}

private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode(type, from: data)
}

private let readingDate = Date(timeIntervalSince1970: 1_791_208_800)

private func snapshot(
    _ providerID: ProviderID = .claude,
    slot: String = "",
    label: String? = nil,
    balance: Double = 12.75,
    resetCount: Int = 2,
    activityCount: Int = 1
) -> QuotaSnapshot {
    QuotaSnapshot(
        providerID: providerID,
        displayName: providerID.snapshotDisplayName,
        planName: "Test Plan",
        windows: [QuotaWindow(
            label: "Weekly", windowKind: .weekly, used: 42, total: 100,
            resetDate: readingDate.addingTimeInterval(86_400), unit: "%"
        )],
        stats: [QuotaStat(label: "Tokens", value: 4_200, unit: "tokens")],
        balances: [QuotaBalance(
            label: "Credits Remaining", amount: balance, unit: "USD",
            subtitle: "Provider reported", resetDate: readingDate.addingTimeInterval(172_800)
        )],
        signals: [QuotaSignal(
            kind: .unexpectedRecovery, title: "Reset available", message: "A reset was banked",
            severity: .info, confidence: 1, windowLabel: "Weekly", detectedAt: readingDate,
            resetKind: .bankedAvailable
        )],
        events: (0..<activityCount).map { index in
            UsageEvent(
                timestamp: readingDate.addingTimeInterval(Double(-index * 60)),
                tokens: Double(index + 100), model: "Test model", type: .message
            )
        },
        analyticsBuckets: (0..<activityCount).map { index in
            UsageAnalyticsBucket(
                startDate: readingDate.addingTimeInterval(Double(-index * 3_600)),
                endDate: readingDate.addingTimeInterval(Double((1 - index) * 3_600)),
                model: "Test model", inputTokens: 50, outputTokens: 25, requests: 1,
                costUSD: 0.01, source: .localTelemetry
            )
        },
        fetchState: .success,
        fetchedAt: readingDate,
        resetCredits: QuotaResetCreditSummary(
            availableCount: resetCount, earnedCount: resetCount + 1,
            credits: [QuotaResetCredit(
                id: "synthetic-reset", status: "available", grantedAt: readingDate,
                expiresAt: readingDate.addingTimeInterval(7_200), title: "Usage reset", note: "Test"
            )],
            history: [QuotaResetCreditEvent(id: "grant", kind: .granted, occurredAt: readingDate)],
            redeemHint: "Redeem in provider app", observedAt: readingDate
        ),
        accountSlot: slot,
        accountLabel: label,
        accountFingerprint: "synthetic-\(providerID.rawValue)-\(slot)"
    )
}

private func modifiedJSON(
    _ payload: CloudSnapshotPayload,
    _ change: (inout [String: Any]) -> Void
) throws -> Data {
    var object = try JSONSerialization.jsonObject(with: encode(payload)) as! [String: Any]
    change(&object)
    return try JSONSerialization.data(withJSONObject: object)
}

private func testLegacyReaderKeepsPrimarySnapshot() throws {
    let primary = snapshot(.openai, balance: 14_000)
    let secondary = snapshot(.openai, slot: "work", label: "Work", balance: 250)
    let payload = try CloudSnapshotPayload(snapshots: [secondary, primary])
    let data = try payload.encoded(maxBytes: 1_000_000)
    let legacyReader = try decode(QuotaSnapshot.self, from: data)
    try expectEqual(legacyReader, primary, "an older viewer must read the actual primary with every field intact")

    let object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
    try expectEqual(object["accountPayloadVersion"] as? Int, 3, "the transport announces the account roster version")
    try expectEqual(object["providerID"] as? String, "openai", "the primary stays at the existing JSON root")
}

private func testFullRosterRoundTripPreservesCreditsAndIdentity() throws {
    let primary = snapshot()
    let work = snapshot(slot: "work", label: "Work", balance: 98.12, resetCount: 0)
    let client = snapshot(slot: "client", label: "Client", balance: 0, resetCount: 3)
    let payload = try CloudSnapshotPayload(snapshots: [primary, work, client])
    let decoded = try decode(CloudSnapshotPayload.self, from: payload.encoded(maxBytes: 1_000_000))
    try expectEqual(decoded.snapshots, [primary, work, client], "the complete roster and every account field survive transport")
    try expectEqual(decoded.additionalAccounts?.map(\.accountSlot), ["work", "client"], "secondary account order survives")
    try expectEqual(decoded.additionalAccounts?.first?.balances.first?.amount, 98.12, "secondary credits are independent of the primary")
    try expectEqual(decoded.additionalAccounts?.first?.resetCredits?.availableCount, 0, "a reported zero banked-reset count survives")
    try decoded.validate(providerID: .claude)
    try expectFailure("a payload cannot be accepted for a different CloudKit provider record") {
        try decoded.validate(providerID: .grok)
    }
}

private func testSecondaryOnlyDoesNotBecomePrimary() throws {
    let work = snapshot(.grok, slot: "work", label: "Work")
    let payload = try CloudSnapshotPayload(snapshots: [work])
    try expect(payload.primary.isPrimaryAccount, "secondary-only rosters synthesize a primary placeholder")
    try expectEqual(payload.primary.fetchState, .notConfigured, "the placeholder does not pretend the primary is configured")
    try expect(payload.primary.windows.isEmpty && payload.primary.balances.isEmpty, "the placeholder must not inherit a secondary account's usage or credits")
    try expect(payload.primary.resetCredits == nil && payload.primary.accountFingerprint == nil, "the placeholder must not inherit secondary reset state or identity")
    try expectEqual(payload.additionalAccounts, [work], "the secondary keeps its exact slot and data")
    let legacy = try decode(QuotaSnapshot.self, from: payload.encoded(maxBytes: 1_000_000))
    try expectEqual(legacy, payload.primary, "older viewers see an unconfigured primary rather than mislabeled secondary usage")
}

private func testInvalidConstructedRostersAreRejected() throws {
    let primary = snapshot()
    let work = snapshot(slot: "work", label: "Work")
    for (name, snapshots) in [
        ("empty", []),
        ("duplicate primary", [primary, primary]),
        ("duplicate secondary slot", [primary, work, work]),
        ("mixed providers", [primary, snapshot(.grok, slot: "work")])
    ] {
        try expectFailure("\(name) roster must be rejected") {
            _ = try CloudSnapshotPayload(snapshots: snapshots)
        }
    }
}

private func testMalformedAndFutureJSONRostersAreRejected() throws {
    let payload = try CloudSnapshotPayload(snapshots: [snapshot(), snapshot(slot: "work")])
    let changes: [(String, (inout [String: Any]) -> Void)] = [
        ("missing roster", { $0.removeValue(forKey: "additionalAccounts") }),
        ("null roster", { $0["additionalAccounts"] = NSNull() }),
        ("wrong roster type", { $0["additionalAccounts"] = "work" }),
        ("malformed account", { $0["additionalAccounts"] = [["accountSlot": "work"]] }),
        ("unversioned roster", { $0.removeValue(forKey: "accountPayloadVersion") }),
        ("future roster version", { $0["accountPayloadVersion"] = CloudSnapshotPayload.currentVersion + 1 }),
        ("wrong version type", { $0["accountPayloadVersion"] = "3" }),
        ("secondary at root", { $0["accountSlot"] = "other" }),
        ("primary in additional accounts", {
            var account = ($0["additionalAccounts"] as! [[String: Any]])[0]
            account["accountSlot"] = ""
            $0["additionalAccounts"] = [account]
        }),
        ("duplicate secondary", {
            let account = ($0["additionalAccounts"] as! [[String: Any]])[0]
            $0["additionalAccounts"] = [account, account]
        }),
        ("mixed provider account", {
            var account = ($0["additionalAccounts"] as! [[String: Any]])[0]
            account["providerID"] = "grok"
            $0["additionalAccounts"] = [account]
        })
    ]
    for (name, change) in changes {
        let data = try modifiedJSON(payload, change)
        try expectFailure("\(name) must fail without partially accepting the roster") {
            _ = try decode(CloudSnapshotPayload.self, from: data)
        }
    }
}

private func testMalformedRawSlotsCannotChangeAccountIdentity() throws {
    let payload = try CloudSnapshotPayload(snapshots: [snapshot(), snapshot(slot: "work")])
    let malformedSlots: [Any] = ["Work", "work team", "work#other", "ümlaut", String(repeating: "a", count: 17), 7, NSNull()]
    for slot in malformedSlots {
        let data = try modifiedJSON(payload) {
            var account = ($0["additionalAccounts"] as! [[String: Any]])[0]
            account["accountSlot"] = slot
            $0["additionalAccounts"] = [account]
        }
        try expectFailure("a malformed slot must fail instead of silently becoming a different identity: \(slot)") {
            _ = try decode(CloudSnapshotPayload.self, from: data)
        }
    }
    for slot: Any in ["!!!", 7, NSNull()] {
        let data = try modifiedJSON(payload) { $0["accountSlot"] = slot }
        try expectFailure("a malformed root slot cannot silently become the primary") {
            _ = try decode(CloudSnapshotPayload.self, from: data)
        }
    }

    let oldPrimary = try modifiedJSON(CloudSnapshotPayload(snapshots: [snapshot()])) {
        $0.removeValue(forKey: "accountSlot")
        $0.removeValue(forKey: "accountPayloadVersion")
        $0.removeValue(forKey: "additionalAccounts")
    }
    let legacy = try decode(CloudSnapshotPayload.self, from: oldPrimary)
    try expect(legacy.primary.isPrimaryAccount, "a legacy primary may still omit the accountSlot key")
}

private func testSizeCompactionPreservesAllAccountStatus() throws {
    let snapshots = [snapshot(activityCount: 120), snapshot(slot: "work", label: "Work", activityCount: 120)]
    let payload = try CloudSnapshotPayload(snapshots: snapshots)
    let full = try payload.encoded(maxBytes: 1_000_000)
    let fullDecoded = try decode(CloudSnapshotPayload.self, from: full)
    try expectEqual(fullDecoded.snapshots, snapshots, "activity is retained while the full bundle fits")

    let statusOnly = snapshots.map { CloudSnapshotPayload.replacingActivity(in: $0, events: [], analyticsBuckets: []) }
    let compactLimit = try encode(CloudSnapshotPayload(snapshots: statusOnly)).count
    try expect(full.count > compactLimit, "the test forces the provider bundle above its budget")
    let compact = try payload.encoded(maxBytes: compactLimit)
    try expect(compact.count <= compactLimit, "the entire encoded provider bundle fits the byte budget")
    let decoded = try decode(CloudSnapshotPayload.self, from: compact)
    try expectEqual(decoded.snapshots, statusOnly, "compaction trims both accounts' activity and retains all identity, credits, reset credits, windows, stats, signals, and timestamps")
    try expect(decoded.snapshots.allSatisfy { $0.events.isEmpty && $0.analyticsBuckets.isEmpty }, "both types of activity are trimmed for every account")

    do {
        _ = try payload.encoded(maxBytes: compactLimit - 1)
        throw CloudSnapshotTestError.failure("an oversized status-only bundle must throw instead of truncating the roster")
    } catch CloudSnapshotPayload.PayloadError.tooLarge {
        // Expected: no account or current balance may be dropped to fit.
    }
}

private func testCurrentRosterReplacesAccountsAtomically() throws {
    let primary = snapshot()
    let work = snapshot(slot: "work", label: "Work")
    let deleted = snapshot(slot: "deleted", label: "Old")
    let otherProvider = snapshot(.minimax)
    let updated = snapshot(slot: "work", label: "Renamed", balance: 5, resetCount: 1)
    let payload = try CloudSnapshotPayload(snapshots: [primary, updated])
    let merged = CloudSnapshotPayload.merging([payload], into: [primary, work, deleted, otherProvider])
    try expectEqual(merged.filter { $0.providerID == .claude }, [primary, updated], "a complete roster replaces changed accounts and removes deleted secondaries")
    try expectEqual(merged.filter { $0.providerID == .minimax }, [otherProvider], "another provider is untouched")

    let primaryOnly = try CloudSnapshotPayload(snapshots: [primary])
    let removedAll = CloudSnapshotPayload.merging([primaryOnly], into: merged)
    try expectEqual(removedAll.filter { $0.providerID == .claude }, [primary], "an explicit empty v3 roster removes all secondaries")
}

private func testLegacyPrimaryOnlyMergeRetainsSecondaries() throws {
    let previous = snapshot()
    let work = snapshot(slot: "work", label: "Work")
    let updatedPrimary = snapshot(balance: 4, resetCount: 1)
    let legacy = try decode(CloudSnapshotPayload.self, from: encode(updatedPrimary))
    try expect(legacy.additionalAccounts == nil, "the legacy transport does not assert an empty roster")
    try expectEqual(legacy.primary, updatedPrimary, "legacy balances and banked resets still decode")
    let merged = CloudSnapshotPayload.merging([legacy], into: [previous, work])
    try expectEqual(merged, [updatedPrimary, work], "a primary-only old publisher cannot erase the cached secondary roster")
}

private func testMissingOrFailedProvidersRetainCachedAccounts() throws {
    let claude = snapshot()
    let claudeWork = snapshot(slot: "work", label: "Work")
    let grok = snapshot(.grok)
    let grokWork = snapshot(.grok, slot: "work", label: "Work")
    let miniMax = snapshot(.minimax)
    let cached = [claude, claudeWork, grok, grokWork, miniMax]
    let updatedMiniMax = snapshot(.minimax, balance: 7)
    let success = try CloudSnapshotPayload(snapshots: [updatedMiniMax])
    let malformed = try modifiedJSON(CloudSnapshotPayload(snapshots: [grok, grokWork])) {
        $0["additionalAccounts"] = "invalid"
    }
    let failed = try? decode(CloudSnapshotPayload.self, from: malformed)
    try expect(failed == nil, "a corrupt provider read is omitted from the successful payload set")
    let merged = CloudSnapshotPayload.merging([success], into: cached)
    try expectEqual(merged.filter { $0.providerID == .claude }, [claude, claudeWork], "a missing provider keeps all its cached accounts")
    try expectEqual(merged.filter { $0.providerID == .grok }, [grok, grokWork], "a failed provider keeps all its cached accounts")
    try expectEqual(merged.filter { $0.providerID == .minimax }, [updatedMiniMax], "successful provider data still advances")
    try expectEqual(CloudSnapshotPayload.merging([], into: cached), cached, "no successful reads leave the cache intact")
}

private func testStatusHashPublishesChangesInEveryAccount() throws {
    let primary = snapshot()
    let work = snapshot(slot: "work", label: "Work")
    let client = snapshot(slot: "client", label: "Client")
    let payload = try CloudSnapshotPayload(snapshots: [primary, work, client])
    let originalHash = payload.statusHash
    try expectEqual(originalHash, CloudSnapshotPayload.statusHash(for: payload.snapshots), "publisher and payload use the same status identity")
    let changes: [(String, [QuotaSnapshot])] = [
        ("rename", [primary, work.withAccount(slot: "work", label: "Renamed", fingerprint: work.accountFingerprint), client]),
        ("remove", [primary, work]),
        ("add", [primary, work, client, snapshot(slot: "other", label: "Other")]),
        ("order", [primary, client, work]),
        ("secondary balance", [primary, snapshot(slot: "work", label: "Work", balance: 1), client]),
        ("secondary resets", [primary, snapshot(slot: "work", label: "Work", resetCount: 0), client]),
        ("account identity", [primary, work.withAccount(slot: "work", label: "Work", fingerprint: "replacement"), client])
    ]
    for (name, snapshots) in changes {
        try expect(CloudSnapshotPayload.statusHash(for: snapshots) != originalHash, "a \(name) change must trigger publication even when the primary is unchanged")
    }

    let recreated = snapshot(slot: "work", label: "Work")
    try expect(recreated.id != work.id && recreated.windows[0].id != work.windows[0].id, "fresh fixture readings regenerate their transient UUIDs")
    try expectEqual(CloudSnapshotPayload.statusHash(for: recreated), CloudSnapshotPayload.statusHash(for: work), "regenerated UUIDs do not trigger a redundant cloud update")
    let observedAgain = try modifiedJSON(CloudSnapshotPayload(snapshots: [primary])) {
        $0["fetchedAt"] = "2026-10-05T20:00:00Z"
        var resets = $0["resetCredits"] as! [String: Any]
        resets["observedAt"] = "2026-10-05T20:00:00Z"
        $0["resetCredits"] = resets
    }
    let refreshed = try decode(CloudSnapshotPayload.self, from: observedAgain).primary
    try expect(primary.fetchedAt != refreshed.fetchedAt, "the test changes observation time")
    try expectEqual(CloudSnapshotPayload.statusHash(for: refreshed), CloudSnapshotPayload.statusHash(for: primary), "fetchedAt and reset observedAt alone do not churn cloud status")
}

private func testStatusHashIncludesResetCreditDetails() throws {
    let original = snapshot(slot: "work", label: "Work")
    let signal = original.signals[0]
    let reclassified = original.withSignals([QuotaSignal(
        id: signal.id, kind: signal.kind, title: signal.title, message: signal.message,
        severity: signal.severity, confidence: signal.confidence, windowLabel: signal.windowLabel,
        detectedAt: signal.detectedAt, resetKind: .bankedRedeemed
    )])
    try expect(CloudSnapshotPayload.statusHash(for: reclassified) != CloudSnapshotPayload.statusHash(for: original),
               "a refined reset classification must propagate even when text and counts do not change")
    let summary = original.resetCredits!
    let credit = summary.credits[0]
    let changedCredit = QuotaResetCredit(
        id: credit.id, status: credit.status, grantedAt: credit.grantedAt,
        expiresAt: credit.expiresAt, title: credit.title, note: "Updated redemption instruction"
    )
    let summaries = [
        QuotaResetCreditSummary(
            availableCount: summary.availableCount, earnedCount: summary.earnedCount,
            credits: [changedCredit], history: summary.history, redeemHint: summary.redeemHint,
            observedAt: summary.observedAt
        ),
        QuotaResetCreditSummary(
            availableCount: summary.availableCount, earnedCount: summary.earnedCount,
            credits: summary.credits,
            history: [QuotaResetCreditEvent(id: "grant", kind: .used, occurredAt: readingDate)],
            redeemHint: summary.redeemHint, observedAt: summary.observedAt
        ),
        QuotaResetCreditSummary(
            availableCount: summary.availableCount, earnedCount: summary.earnedCount,
            credits: summary.credits, history: summary.history, redeemHint: "Redeem on the provider website",
            observedAt: summary.observedAt
        )
    ]
    for updatedSummary in summaries {
        let updated = original.withResetCredits(updatedSummary)
        try expectEqual(updatedSummary.availableCount, summary.availableCount, "the detail-only case keeps the available count")
        try expectEqual(updatedSummary.nearestExpiry, summary.nearestExpiry, "the detail-only case keeps the nearest expiry")
        try expect(CloudSnapshotPayload.statusHash(for: updated) != CloudSnapshotPayload.statusHash(for: original), "credit details, history content and redemption hints must sync even when count and expiry are unchanged")
    }
}

@MainActor
private func testSyncedAccountRegistryReconciliationAndPersistence() throws {
    let suiteName = "cloud-snapshot-payload-tests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let registry = ProviderAccountRegistry(defaults: defaults)
    let store = QuotaSnapshotStore(defaults: defaults)
    let primary = snapshot()
    let work = snapshot(slot: "work", label: "Work")
    let client = snapshot(slot: "client", label: "Client")
    let grok = snapshot(.grok)
    let grokWork = snapshot(.grok, slot: "work", label: "Grok Work")
    let firstRoster = [primary, work, client, grok, grokWork]
    store.replaceAll(firstRoster)
    registry.reconcileSyncedAccounts(from: store.loadSnapshots())
    try expectEqual(registry.keys(for: .claude), [primary.accountKey, work.accountKey, client.accountKey], "the receiver recreates remote secondary account order after the primary")
    try expectEqual(registry.accounts(for: .claude).map(\.label), ["Work", "Client"], "remote account labels populate the registry")
    try expectEqual(registry.accounts(for: .grok).map(\.label), ["Grok Work"], "the same secondary slot is independent across providers")
    let persisted = ProviderAccountRegistry(defaults: defaults)
    try expectEqual(persisted.records, registry.records, "the synced roster survives reloading from shared storage")

    let firstWorkCreatedAt = registry.record(for: work.accountKey)?.createdAt
    let renamed = work.withAccount(slot: "work", label: "Team", fingerprint: work.accountFingerprint)
    let reordered = try CloudSnapshotPayload(snapshots: [primary, client, renamed])
    let merged = CloudSnapshotPayload.merging([reordered], into: store.loadSnapshots())
    store.replaceAll(merged)
    registry.reconcileSyncedAccounts(from: store.loadSnapshots())
    try expectEqual(registry.accounts(for: .claude).map(\.slot), ["client", "work"], "remote order changes update local account ranks")
    try expectEqual(registry.label(for: work.accountKey), "Team", "remote renames replace the previous label")
    try expectEqual(registry.record(for: work.accountKey)?.createdAt, firstWorkCreatedAt, "reconciliation keeps stable account creation metadata")
    try expectEqual(registry.accounts(for: .grok).map(\.slot), ["work"], "the merged cache preserves a provider omitted from this sync")
    let unchangedRecords = registry.records
    let unchangedData = defaults.data(forKey: "providerAccountRecords.v1")
    registry.reconcileSyncedAccounts(from: store.loadSnapshots())
    try expectEqual(registry.records, unchangedRecords, "reconciliation is idempotent")
    try expectEqual(defaults.data(forKey: "providerAccountRecords.v1"), unchangedData, "an unchanged roster does not rewrite its stored bytes")

    let removed = try CloudSnapshotPayload(snapshots: [primary, renamed])
    store.replaceAll(CloudSnapshotPayload.merging([removed], into: store.loadSnapshots()))
    registry.reconcileSyncedAccounts(from: store.loadSnapshots())
    try expect(registry.record(for: client.accountKey) == nil, "remote deletions disappear from the receiver registry")
    try expectEqual(ProviderAccountRegistry(defaults: defaults).records, registry.records, "renames, ordering, and removal remain correct after another launch")
}

@main
private struct CloudSnapshotPayloadTestRunner {
    @MainActor
    static func main() throws {
        let tests: [(String, @MainActor () throws -> Void)] = [
            ("legacy reader primary compatibility", testLegacyReaderKeepsPrimarySnapshot),
            ("complete roster credits and account identity", testFullRosterRoundTripPreservesCreditsAndIdentity),
            ("secondary-only primary placeholder", testSecondaryOnlyDoesNotBecomePrimary),
            ("invalid constructed rosters", testInvalidConstructedRostersAreRejected),
            ("malformed and future JSON rosters", testMalformedAndFutureJSONRostersAreRejected),
            ("strict raw account identity validation", testMalformedRawSlotsCannotChangeAccountIdentity),
            ("bounded payload activity compaction", testSizeCompactionPreservesAllAccountStatus),
            ("atomic roster replacement and account removal", testCurrentRosterReplacesAccountsAtomically),
            ("legacy primary-only merge", testLegacyPrimaryOnlyMergeRetainsSecondaries),
            ("missing and failed provider retention", testMissingOrFailedProvidersRetainCachedAccounts),
            ("account-aware status publication", testStatusHashPublishesChangesInEveryAccount),
            ("reset credit detail publication", testStatusHashIncludesResetCreditDetails),
            ("synced account registry persistence", testSyncedAccountRegistryReconciliationAndPersistence)
        ]
        for (name, test) in tests {
            try test()
            print("PASS: \(name)")
        }
        print("Cloud snapshot payload tests passed (\(tests.count) cases).")
    }
}
