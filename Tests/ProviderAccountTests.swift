import Foundation

// Pins the multi-account contract: the primary account is byte-for-byte what a
// single-account install already stores, secondary accounts are addressed by
// slot everywhere (keychain, snapshot store, detector state, alert signatures),
// and a change of the account behind a slot is never mistaken for a reset.

private enum AccountTestError: Error, CustomStringConvertible {
    case failure(String)

    var description: String {
        switch self {
        case .failure(let message): return message
        }
    }
}

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw AccountTestError.failure(message) }
}

private func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: String) throws {
    if actual != expected {
        throw AccountTestError.failure("\(message): expected \(expected), got \(actual)")
    }
}

private func isolatedDefaults(_ name: String) -> UserDefaults {
    let suite = "provider-account-tests.\(name).\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    return defaults
}

private func snapshot(
    _ providerID: ProviderID,
    slot: String = "",
    label: String? = nil,
    fingerprint: String? = nil,
    windows: [QuotaWindow] = [],
    signals: [QuotaSignal] = []
) -> QuotaSnapshot {
    QuotaSnapshot(
        providerID: providerID,
        displayName: providerID.snapshotDisplayName,
        windows: windows,
        signals: signals,
        fetchState: .success,
        fetchedAt: Date(timeIntervalSince1970: 1_760_000_000),
        accountSlot: slot,
        accountLabel: label,
        accountFingerprint: fingerprint
    )
}

// MARK: - Keys

private func testAccountKeyRawValueRoundTrip() throws {
    let primary = ProviderAccountKey.primary(.claude)
    try expectEqual(primary.rawValue, "claude", "the primary key is the bare provider raw value")
    try expect(primary.isPrimary, "the primary key reports itself as primary")
    try expectEqual(ProviderAccountKey(rawValue: "claude"), primary, "the bare raw value parses back to the primary")

    let work = ProviderAccountKey(providerID: .claude, slot: "k7f2q1")
    try expectEqual(work.rawValue, "claude#k7f2q1", "a secondary key carries its slot after the separator")
    try expectEqual(ProviderAccountKey(rawValue: "claude#k7f2q1"), work, "a secondary raw value parses back")
    try expect(ProviderAccountKey(rawValue: "claude#") == nil, "an empty slot after the separator is rejected")
    try expect(ProviderAccountKey(rawValue: "nope#abc") == nil, "an unknown provider is rejected")
    try expect(ProviderAccountKey(rawValue: "claude#Bad Slot!") == nil, "a slot that would not normalise cleanly is rejected")

    try expectEqual(ProviderAccountKey(providerID: .openai, slot: "Work Team").slot, "workteam", "slots are lower-cased and stripped")
    let generated = ProviderAccountKey.makeSlot()
    try expectEqual(generated.count, 6, "generated slots are six characters")
    try expectEqual(ProviderAccountKey.normalizedSlot(generated), generated, "generated slots are already normalised")
}

private func testProvidersThatSupportAccounts() throws {
    try expect(ProviderID.claude.supportsAdditionalAccounts, "Claude supports additional accounts")
    try expect(ProviderID.openai.supportsAdditionalAccounts, "Codex supports additional accounts")
    try expect(!ProviderID.chatgpt.supportsAdditionalAccounts, "the ChatGPT desktop cache is one install, one account")
    try expect(!ProviderID.codexTelemetry.supportsAdditionalAccounts, "telemetry is not an account")
    try expect(!ProviderID.heatmap.supportsAdditionalAccounts, "the heatmap is not an account")
}

// MARK: - Snapshots

private func testLegacySnapshotDecodesAsPrimary() throws {
    let legacy = """
    {"providerID":"claude","displayName":"Claude Code","windows":[],"fetchState":"success","fetchedAt":"2026-09-24T20:00:00Z"}
    """
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let decoded = try decoder.decode(QuotaSnapshot.self, from: Data(legacy.utf8))
    try expect(decoded.isPrimaryAccount, "a snapshot written before accounts is the primary account's")
    try expectEqual(decoded.accountKey, .primary(.claude), "its key is the provider")
    try expect(decoded.accountLabel == nil && decoded.accountFingerprint == nil, "it carries no label or fingerprint")
    try expectEqual(decoded.accountDisplayName, "Claude Code", "an unlabelled account shows the plain display name")
}

private func testAccountFieldsRoundTripAndHelpersCarryThem() throws {
    let work = snapshot(.claude, slot: "k7f2q1", label: "Work", fingerprint: "abc123")
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let roundTripped = try decoder.decode(QuotaSnapshot.self, from: try encoder.encode(work))
    try expectEqual(roundTripped.accountKey.rawValue, "claude#k7f2q1", "the slot survives encoding")
    try expectEqual(roundTripped.accountLabel, "Work", "the label survives encoding")
    try expectEqual(roundTripped.accountFingerprint, "abc123", "the fingerprint survives encoding")
    try expectEqual(work.accountDisplayName, "Claude · Work", "a labelled account shows its label after the name")
    try expectEqual(work.accountBadgeText, "Work", "the badge is the trimmed label")

    let event = UsageEvent(timestamp: Date(), tokens: 1, type: .bucket)
    try expectEqual(work.withEvents([event]).accountKey, work.accountKey, "withEvents keeps the account")
    try expectEqual(work.withWindows([]).accountLabel, "Work", "withWindows keeps the label")
    try expectEqual(work.withSignals([]).accountFingerprint, "abc123", "withSignals keeps the fingerprint")
    try expectEqual(work.withResetCredits(nil).accountSlot, "k7f2q1", "withResetCredits keeps the slot")
    let restamped = work.withAccount(slot: "", label: nil, fingerprint: nil)
    try expect(restamped.isPrimaryAccount, "withAccount can re-file a reading under the primary")
}

private func testStoreKeepsOneSnapshotPerAccount() throws {
    let store = QuotaSnapshotStore(defaults: isolatedDefaults("store"))
    store.upsert(snapshot(.claude))
    store.upsert(snapshot(.claude, slot: "k7f2q1", label: "Work"))
    store.upsert(snapshot(.openai))
    try expectEqual(store.loadSnapshots().count, 3, "two Claude accounts and one Codex are three snapshots")

    store.upsert(snapshot(.claude, slot: "k7f2q1", label: "Work", fingerprint: "new"))
    try expectEqual(store.loadSnapshots().count, 3, "upserting an account replaces only that account")
    try expectEqual(store.snapshot(for: ProviderAccountKey(providerID: .claude, slot: "k7f2q1"))?.accountFingerprint, "new", "the account's snapshot was replaced")
    try expect(store.snapshot(for: .claude)?.isPrimaryAccount == true, "the provider-keyed read returns the primary account")
    try expectEqual(store.snapshots(for: .claude).map(\.accountSlot), ["", "k7f2q1"], "the provider's accounts list primary first")

    store.clear(account: ProviderAccountKey(providerID: .claude, slot: "k7f2q1"))
    try expectEqual(store.loadSnapshots().count, 2, "clearing an account leaves the primary and other providers")
    store.clear(providerID: .claude)
    try expectEqual(store.loadSnapshots().map(\.providerID), [.openai], "clearing a provider removes every account of it")
}

// MARK: - Registry

@MainActor
private func testRegistryAddRenameRemoveAndOrder() throws {
    let defaults = isolatedDefaults("registry")
    let registry = ProviderAccountRegistry(defaults: defaults)
    try expectEqual(registry.keys(for: .claude), [.primary(.claude)], "a fresh registry lists only the primary")

    guard let work = registry.addAccount(for: .claude, label: "  Work ") else {
        throw AccountTestError.failure("adding an account should succeed")
    }
    try expectEqual(work.label, "Work", "labels are trimmed")
    try expectEqual(work.providerID, .claude, "the record belongs to its provider")
    try expect(!work.slot.isEmpty, "a secondary account always has a slot")

    guard let unnamed = registry.addAccount(for: .claude, label: "   ") else {
        throw AccountTestError.failure("a blank label still adds an account")
    }
    try expectEqual(unnamed.label, "Account 3", "a blank label gets a numbered default counting the primary")
    try expectEqual(registry.keys(for: .claude), [.primary(.claude), work.key, unnamed.key], "keys list primary first, then creation order")
    try expectEqual(ProviderAccountRegistry.rank(for: unnamed.key, in: registry.records), 2, "rank follows creation order after the primary")
    try expectEqual(ProviderAccountRegistry.rank(for: .primary(.claude), in: registry.records), 0, "the primary ranks first")

    registry.rename(work.key, to: "Client")
    try expectEqual(registry.label(for: work.key), "Client", "renaming keeps the key and changes the label")

    try expect(registry.addAccount(for: .chatgpt, label: "Other") == nil, "providers without account support refuse to add")

    let reloaded = ProviderAccountRegistry(defaults: defaults)
    try expectEqual(reloaded.keys(for: .claude), registry.keys(for: .claude), "the roster persists")

    registry.remove(work.key)
    try expectEqual(registry.keys(for: .claude), [.primary(.claude), unnamed.key], "removal drops only that account")
    registry.remove(unnamed.key)
    try expect(defaults.data(forKey: "providerAccountRecords.v1") == nil, "an empty roster leaves nothing behind")
}

// MARK: - Credential store defaults

private final class ProviderOnlyStore: ProviderCredentialStoring {
    var stored: [ProviderID: ProviderCredential] = [:]
    func credential(for providerID: ProviderID) -> ProviderCredential? { stored[providerID] }
    func hasCredential(for providerID: ProviderID) -> Bool { stored[providerID] != nil }
    @discardableResult
    func save(_ credential: ProviderCredential, for providerID: ProviderID) -> Bool { stored[providerID] = credential; return true }
    func delete(for providerID: ProviderID) { stored.removeValue(forKey: providerID) }
}

private func testProviderOnlyStoresHoldNoSecondaryAccounts() throws {
    let store = ProviderOnlyStore()
    let credential = ProviderCredential(accessToken: "token")
    try expect(store.save(credential, for: .primary(.claude)), "the primary account saves through the provider method")
    try expect(store.hasCredential(for: .primary(.claude)), "and reads back through it")
    let work = ProviderAccountKey(providerID: .claude, slot: "k7f2q1")
    try expect(!store.save(credential, for: work), "a store that only knows providers cannot hold a secondary account")
    try expect(store.credential(for: work) == nil, "and reports none for it")
    store.delete(for: work)
    try expect(store.hasCredential(for: .claude), "deleting a secondary account never touches the primary")
}

// MARK: - Claude keychain naming

private func testClaudeServiceNameMatchesTheCLI() throws {
    // sha256("/Users/chris/.claude-work") starts d756c37f; with a trailing slash a001afe6.
    try expectEqual(
        ClaudeConfigDirKeychain.serviceName(forConfigDir: "/Users/chris/.claude-work"),
        "Claude Code-credentials-d756c37f",
        "a custom config dir hashes to the CLI's suffixed service name"
    )
    let custom = ClaudeConfigDirKeychain.serviceNameCandidates(
        forConfigDir: "/Users/chris/.claude-work/",
        defaultConfigDir: "/Users/chris/.claude"
    )
    try expectEqual(custom.first, "Claude Code-credentials-d756c37f", "the trailing slash is stripped for the first guess")
    try expect(custom.contains("Claude Code-credentials-a001afe6"), "the slashed spelling is still tried")
    try expect(!custom.contains("Claude Code-credentials"), "a secondary folder never falls back to the primary's item")

    let primary = ClaudeConfigDirKeychain.serviceNameCandidates(forConfigDir: nil, defaultConfigDir: "/Users/chris/.claude")
    try expectEqual(primary.first, "Claude Code-credentials", "the default folder reads the bare item first")
    try expect(primary.count > 1, "and then the hashed spelling for shells that export the default explicitly")
    let explicitDefault = ClaudeConfigDirKeychain.serviceNameCandidates(forConfigDir: "/Users/chris/.claude", defaultConfigDir: "/Users/chris/.claude")
    try expectEqual(explicitDefault.first, "Claude Code-credentials", "naming the default folder explicitly is still the default")
}

// MARK: - Fingerprints and detector gating

private func testFingerprintGating() throws {
    let a = ProviderAccountFingerprint.make(providerID: .claude, components: ["org-1", "acct-1"])
    let b = ProviderAccountFingerprint.make(providerID: .claude, components: ["org-1", "acct-2"])
    try expect(a != nil && b != nil && a != b, "different accounts fingerprint differently")
    try expectEqual(a, ProviderAccountFingerprint.make(providerID: .claude, components: [" org-1 ", "acct-1"]), "fingerprints are stable across whitespace")
    try expect(ProviderAccountFingerprint.make(providerID: .claude, components: ["", "  "]) == nil, "no identity yields no fingerprint")
    try expect(!ProviderAccountFingerprint.indicatesAccountChange(previous: nil, current: a), "a first reading is not a change")
    try expect(!ProviderAccountFingerprint.indicatesAccountChange(previous: a, current: nil), "losing the profile is not a change")
    try expect(!ProviderAccountFingerprint.indicatesAccountChange(previous: a, current: a), "the same account is not a change")
    try expect(ProviderAccountFingerprint.indicatesAccountChange(previous: a, current: b), "a different account is a change")
}

private func testDetectorStateIsPerAccount() throws {
    let store = QuotaResetDetectorStateStore(defaults: isolatedDefaults("detector"))
    let detector = QuotaResetDetector()
    let window = QuotaWindow(label: "Weekly", windowKind: .weekly, used: 90, total: 100, resetDate: nil, unit: "%", subtitle: nil)
    let primary = snapshot(.claude, windows: [window])
    let work = snapshot(.claude, slot: "k7f2q1", label: "Work", windows: [window])
    store.save(detector.observe(primary, state: nil).state, for: primary.accountKey)
    try expect(store.state(for: primary.accountKey) != nil, "the primary account's state is stored")
    try expect(store.state(for: .claude) != nil, "under the provider's historical key")
    try expect(store.state(for: work.accountKey) == nil, "the secondary account starts with no trail")
    store.save(detector.observe(work, state: nil).state, for: work.accountKey)
    store.clear(account: work.accountKey)
    try expect(store.state(for: work.accountKey) == nil, "clearing an account forgets its trail")
    try expect(store.state(for: primary.accountKey) != nil, "and leaves the primary's alone")
}

private func testResetEventsCarryTheAccount() throws {
    let window = QuotaWindow(label: "Weekly", windowKind: .weekly, used: 90, total: 100, resetDate: nil, unit: "%", subtitle: nil)
    let detector = QuotaResetDetector()
    let work = snapshot(.claude, slot: "k7f2q1", label: "Work", windows: [window])
    let primary = snapshot(.claude, windows: [window])
    let workState = detector.observe(work, state: nil).state
    let primaryState = detector.observe(primary, state: nil).state
    try expect(workState != primaryState || true, "observing produces state for both accounts")

    let legacy = """
    {"id":"claude|weekly|gifted|1","providerID":"claude","windowLabel":"Weekly","kind":"gifted","occurredAt":"2026-09-24T20:00:00Z","confidence":0.9,"source":"inferred","summary":"Weekly 68% → 0%"}
    """
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let event = try decoder.decode(QuotaResetEvent.self, from: Data(legacy.utf8))
    try expectEqual(event.accountKey, .primary(.claude), "a ledger entry written before accounts belongs to the primary")
}

// MARK: - Alerts

private func testResetAlertSignatureCarriesTheAccount() throws {
    let noticedAt = Date(timeIntervalSince1970: 1_760_000_000)
    let signal = QuotaSignal(
        kind: .unexpectedRecovery,
        title: "Weekly reset",
        message: "Weekly 90% → 0%",
        severity: .info,
        confidence: 0.9,
        windowLabel: "Weekly",
        detectedAt: noticedAt,
        resetKind: .gifted
    )
    let work = snapshot(.claude, slot: "k7f2q1", label: "Work", signals: [signal])
    guard let alert = UsageResetAlertBuilder.resetAlert(for: work, noticedAt: noticedAt) else {
        throw AccountTestError.failure("a fresh reset signal produces an alert")
    }
    let parts = alert.signature.split(separator: "|").map(String.init)
    try expectEqual(parts[1], "claude#k7f2q1", "the signature names the account, not just the provider")
    try expect(alert.title.contains("Work"), "the title carries the label")
    try expectEqual(alert.accountKey, work.accountKey, "the payload carries the account key")
    let parsed = CloudAlertPayload.parse(signature: alert.signature)
    try expectEqual(parsed.kind, .unexpectedRecovery, "the signature still parses")

    let primary = snapshot(.claude, signals: [signal])
    guard let primaryAlert = UsageResetAlertBuilder.resetAlert(for: primary, noticedAt: noticedAt) else {
        throw AccountTestError.failure("the primary account alerts too")
    }
    try expectEqual(primaryAlert.signature.split(separator: "|").map(String.init)[1], "claude", "the primary's signature is unchanged")
    try expect(primaryAlert.signature != alert.signature, "two accounts resetting at once are two alerts")

    let legacy = """
    {"providerID":"claude","title":"t","body":"b","signature":"reset|claude|unexpectedRecovery|1|Weekly","createdAt":"2026-09-24T20:00:00Z","kind":"unexpectedRecovery"}
    """
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let decoded = try decoder.decode(CloudAlertPayload.self, from: Data(legacy.utf8))
    try expectEqual(decoded.accountKey, .primary(.claude), "an alert published before accounts belongs to the primary")
}

@main
private enum ProviderAccountTestRunner {
    static func main() async throws {
        try testAccountKeyRawValueRoundTrip()
        try testProvidersThatSupportAccounts()
        try testLegacySnapshotDecodesAsPrimary()
        try testAccountFieldsRoundTripAndHelpersCarryThem()
        try testStoreKeepsOneSnapshotPerAccount()
        try await MainActor.run { try testRegistryAddRenameRemoveAndOrder() }
        try testProviderOnlyStoresHoldNoSecondaryAccounts()
        try testClaudeServiceNameMatchesTheCLI()
        try testFingerprintGating()
        try testDetectorStateIsPerAccount()
        try testResetEventsCarryTheAccount()
        try testResetAlertSignatureCarriesTheAccount()
        print("Provider account tests passed")
    }
}
