import Foundation

private enum ResetDetectorTestError: Error, CustomStringConvertible {
    case failure(String)

    var description: String {
        switch self {
        case .failure(let message): return message
        }
    }
}

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw ResetDetectorTestError.failure(message) }
}

private func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: String) throws {
    if actual != expected {
        throw ResetDetectorTestError.failure("\(message): expected \(expected), got \(actual)")
    }
}

// MARK: - Fixtures

private let t0 = Date(timeIntervalSince1970: 1_789_000_000)
private let day: Double = 24 * 60

private func at(_ minutes: Double) -> Date {
    t0.addingTimeInterval(minutes * 60)
}

private func meter(
    _ label: String,
    kind: QuotaWindowKind = .weekly,
    used: Double,
    reset: Date?,
    subtitle: String? = nil,
    total: Double = 100,
    unit: String = "%"
) -> QuotaWindow {
    QuotaWindow(label: label, windowKind: kind, used: used, total: total, resetDate: reset, unit: unit, subtitle: subtitle)
}

private func snapshot(
    _ providerID: ProviderID,
    _ name: String,
    at date: Date,
    windows: [QuotaWindow],
    credits: QuotaResetCreditSummary? = nil
) -> QuotaSnapshot {
    QuotaSnapshot(
        providerID: providerID,
        displayName: name,
        windows: windows,
        fetchState: .success,
        fetchedAt: date,
        resetCredits: credits
    )
}

/// Feeds sweeps through the detector the way the sync coordinator does,
/// carrying state forward and collecting everything it emitted.
private final class Harness {
    let detector = QuotaResetDetector()
    var state: QuotaResetDetector.ProviderState?
    var signals: [QuotaSignal] = []
    var events: [QuotaResetEvent] = []

    @discardableResult
    func sweep(_ snapshot: QuotaSnapshot) -> QuotaResetDetector.Outcome {
        let outcome = detector.observe(snapshot, state: state)
        state = outcome.state
        signals += outcome.signals
        events += outcome.events
        return outcome
    }

    func resetSignals() -> [QuotaSignal] {
        signals.filter { $0.resetKind?.isResetEvent == true && $0.resetKind != .scheduled }
    }
}

// MARK: - The two false positives this detector exists to stop

/// Six "Spark Weekly reset early" alerts in five days came from a rolling
/// window whose reset estimate drifts forward while usage sits under 10%.
private func testRollingResetDriftIsNotAReset() throws {
    let harness = Harness()
    for step in 0..<7 {
        let minutes = Double(step) * 5
        let outcome = harness.sweep(
            snapshot(.openai, "Codex", at: at(minutes), windows: [
                meter("⚡ Spark Weekly", used: 8.4, reset: at(5 * day + Double(step) * 30), subtitle: "7-day usage limit", total: 168, unit: "hrs")
            ])
        )
        try expect(outcome.signals.isEmpty, "drift sweep \(step) must not signal, got \(outcome.signals.map(\.title))")
    }
    try expect(harness.events.isEmpty, "drift must not reach the ledger")
}

/// Five Qwen "resets" in one hour came from a scraped meter flapping
/// between 0% and 100%; a drop must hold on the next reading to count.
private func testFlappingMeterNeverConfirms() throws {
    let harness = Harness()
    let reset = at(5 * day)
    for (step, used) in [100.0, 0, 100, 0, 100, 0, 100].enumerated() {
        harness.sweep(
            snapshot(.qwen, "Qwen Token Plan", at: at(Double(step) * 5), windows: [
                meter("7-Day Quota", used: used, reset: reset)
            ])
        )
    }
    try expect(harness.signals.isEmpty, "flapping must never signal, got \(harness.signals.map(\.title))")
    try expect(harness.events.isEmpty, "flapping must never reach the ledger")
}

// MARK: - Scheduled, gifted, provider-wide

private func testScheduledResetIsRecordedQuietly() throws {
    let harness = Harness()
    harness.sweep(snapshot(.openai, "Codex", at: at(0), windows: [
        meter("Weekly", used: 80, reset: at(10))
    ]))
    let outcome = harness.sweep(snapshot(.openai, "Codex", at: at(15), windows: [
        meter("Weekly", used: 0, reset: at(15 + 7 * day))
    ]))

    try expectEqual(outcome.signals.count, 1, "one scheduled signal")
    try expectEqual(outcome.signals.first?.kind, .scheduledReset, "scheduled kind")
    try expectEqual(outcome.signals.first?.resetKind, .scheduled, "scheduled reset kind")
    try expectEqual(outcome.events.map(\.kind), [.scheduled], "ledger records the scheduled reset")

    let enriched = snapshot(.openai, "Codex", at: at(15), windows: []).withSignals(outcome.signals)
    try expect(
        UsageResetAlertBuilder.resetAlert(for: enriched, noticedAt: at(15)) == nil,
        "a scheduled reset must not alert"
    )
}

private func testGiftedWeeklyResetConfirmsOnTheNextSweep() throws {
    let harness = Harness()
    harness.sweep(snapshot(.claude, "Claude", at: at(0), windows: [
        meter("Weekly", used: 68, reset: at(4 * day), subtitle: "7-day rolling window")
    ]))
    let pending = harness.sweep(snapshot(.claude, "Claude", at: at(5), windows: [
        meter("Weekly", used: 0, reset: at(5 + 7 * day), subtitle: "7-day rolling window")
    ]))
    try expect(pending.signals.isEmpty, "the drop is pending until the next reading confirms it")

    let confirmed = harness.sweep(snapshot(.claude, "Claude", at: at(10), windows: [
        meter("Weekly", used: 2, reset: at(5 + 7 * day), subtitle: "7-day rolling window")
    ]))
    try expectEqual(confirmed.signals.count, 1, "one confirmed signal")
    let signal = try confirmed.signals.first.orThrow("signal")
    try expectEqual(signal.kind, .unexpectedRecovery, "kind")
    try expectEqual(signal.resetKind, .gifted, "reset kind")
    try expectEqual(signal.windowLabel, "Weekly", "window label")
    try expect((signal.confidence ?? 0) >= 0.85, "a restarted window is high confidence, got \(signal.confidence ?? 0)")
    try expect(signal.message.contains("reset early"), "message keeps the phrase older builds alert on: \(signal.message)")
    try expectEqual(confirmed.events.count, 1, "one ledger event")
    try expectEqual(confirmed.events.first?.kind, .gifted, "ledger kind")
    try expectEqual(confirmed.events.first?.occurredAt, at(5), "the event is dated when the drop was first seen")

    let enriched = snapshot(.claude, "Claude", at: at(10), windows: []).withSignals(confirmed.signals)
    let alert = try UsageResetAlertBuilder.resetAlert(for: enriched, noticedAt: at(10)).orThrow("alert")
    try expectEqual(alert.kind, .unexpectedRecovery, "alert kind")
    try expectEqual(alert.resetKind, .gifted, "alert reset kind")
    try expect(alert.isAnnounceable, "a gifted reset earns a banner")
    try expectEqual(alert.title, "Claude reset early", "alert title")
    try expect(alert.signature.hasSuffix("|gifted"), "signature carries the reset kind: \(alert.signature)")
    try expectEqual(CloudAlertPayload.parse(signature: alert.signature).resetKind, .gifted, "signature round-trips the kind")
}

private func testProviderWideResetAcrossWindows() throws {
    let harness = Harness()
    let session = "5-hour rolling window"
    harness.sweep(snapshot(.claude, "Claude", at: at(0), windows: [
        meter("Session", kind: .session, used: 40, reset: at(180), subtitle: session),
        meter("Weekly", used: 32, reset: at(6 * day)),
        meter("🪐 Fable", used: 62, reset: at(6 * day))
    ]))
    let pending = harness.sweep(snapshot(.claude, "Claude", at: at(5), windows: [
        meter("Session", kind: .session, used: 0, reset: at(305), subtitle: session),
        meter("Weekly", used: 0, reset: at(5 + 7 * day)),
        meter("🪐 Fable", used: 0, reset: at(5 + 7 * day))
    ]))
    try expect(pending.signals.isEmpty, "all three drops wait for confirmation")

    let confirmed = harness.sweep(snapshot(.claude, "Claude", at: at(10), windows: [
        meter("Session", kind: .session, used: 0, reset: at(305), subtitle: session),
        meter("Weekly", used: 1, reset: at(5 + 7 * day)),
        meter("🪐 Fable", used: 1, reset: at(5 + 7 * day))
    ]))
    try expectEqual(confirmed.signals.count, 3, "every window reports, including the five-hour one")
    try expect(confirmed.signals.allSatisfy { $0.resetKind == .providerWide }, "all classified provider-wide")
    try expect(confirmed.signals.contains { $0.windowLabel == "Session" }, "the session window rides along")

    let enriched = snapshot(.claude, "Claude", at: at(10), windows: []).withSignals(confirmed.signals)
    let alert = try UsageResetAlertBuilder.resetAlert(for: enriched, noticedAt: at(10)).orThrow("alert")
    try expectEqual(alert.resetKind, .providerWide, "alert kind")
    try expectEqual(alert.title, "Claude quotas reset", "alert title")
    try expectEqual(alert.badgeTitle, "Provider-wide reset", "badge")
    for label in ["Session", "Weekly", "Fable"] {
        try expect(alert.windowLabel?.contains(label) == true, "alert lists \(label): \(alert.windowLabel ?? "nil")")
    }
}

private func testSoloFiveHourDropIsIgnored() throws {
    let harness = Harness()
    let spark = "5-hour rolling window"
    harness.sweep(snapshot(.openai, "Codex", at: at(0), windows: [
        meter("⚡ Spark 5H", kind: .session, used: 30, reset: at(180), subtitle: spark),
        meter("Weekly", used: 60, reset: at(3 * day))
    ]))
    harness.sweep(snapshot(.openai, "Codex", at: at(5), windows: [
        meter("⚡ Spark 5H", kind: .session, used: 0, reset: at(305), subtitle: spark),
        meter("Weekly", used: 60, reset: at(3 * day))
    ]))
    harness.sweep(snapshot(.openai, "Codex", at: at(10), windows: [
        meter("⚡ Spark 5H", kind: .session, used: 0, reset: at(305), subtitle: spark),
        meter("Weekly", used: 60, reset: at(3 * day))
    ]))
    try expect(harness.signals.isEmpty, "a five-hour window on its own never counts, got \(harness.signals.map(\.title))")
}

// MARK: - Banked credits

private func testBankedCreditLifecycle() throws {
    let harness = Harness()
    let weekly = { (used: Double, reset: Date) in meter("Weekly", used: used, reset: reset, total: 168, unit: "hrs") }

    let none = QuotaResetCreditSummary(availableCount: 0, earnedCount: 0, observedAt: at(0))
    let first = harness.sweep(snapshot(.openai, "Codex", at: at(0), windows: [weekly(168, at(3 * day))], credits: none))
    try expect(first.signals.isEmpty, "nothing to say with no credits")

    let banked = QuotaResetCreditSummary(
        availableCount: 1,
        earnedCount: 1,
        credits: [QuotaResetCredit(id: "c1", status: "available", grantedAt: at(4), expiresAt: at(360))],
        redeemHint: "Redeem it in the Codex app.",
        observedAt: at(5)
    )
    let granted = harness.sweep(snapshot(.openai, "Codex", at: at(5), windows: [weekly(168, at(3 * day))], credits: banked))
    let available = try granted.signals.first { $0.resetKind == .bankedAvailable }.orThrow("available signal")
    try expect(available.message.contains("expires in"), "message carries the expiry: \(available.message)")
    try expect(available.message.contains("Redeem it in the Codex app."), "message carries the redeem hint")

    let availableAlert = try UsageResetAlertBuilder
        .resetAlert(for: snapshot(.openai, "Codex", at: at(5), windows: [], credits: banked).withSignals(granted.signals), noticedAt: at(5))
        .orThrow("available alert")
    try expectEqual(availableAlert.kind, .resetAvailable, "available alert kind")
    try expect(availableAlert.isAnnounceable, "an expiring banked reset is worth a notification")
    try expect(!availableAlert.kind.isUsageReset, "availability is not a reset that happened")
    try expectEqual(availableAlert.title, "Codex reset available", "available title")
    try expectEqual(availableAlert.badgeTitle, "Reset available", "available badge")

    // Redeemed: the count drops and the weekly window restarts in the same sweep.
    let redeemed = QuotaResetCreditSummary(
        availableCount: 0,
        earnedCount: 1,
        history: [
            QuotaResetCreditEvent(id: "c1:used", kind: .used, occurredAt: at(9)),
            QuotaResetCreditEvent(id: "c1:granted", kind: .granted, occurredAt: at(4))
        ],
        observedAt: at(10)
    )
    let used = harness.sweep(snapshot(.openai, "Codex", at: at(10), windows: [weekly(0, at(10 + 7 * day))], credits: redeemed))
    let windowSignal = try used.signals.first { $0.resetKind == .bankedRedeemed && $0.windowLabel == "Weekly" }.orThrow("window redeemed signal")
    try expect(windowSignal.message.contains("banked reset was redeemed"), "message: \(windowSignal.message)")
    try expect(used.signals.contains { $0.resetKind == .bankedRedeemed && $0.windowLabel == QuotaResetDetector.bankedResetWindowLabel }, "credit redeemed signal")
    try expect(!used.signals.contains { $0.resetKind == .bankedAvailable }, "nothing left to redeem")
    try expect(used.events.contains { $0.kind == .bankedRedeemed && $0.windowLabel == "Weekly" }, "ledger has the redeemed window")
    try expectEqual(harness.state?.credits?.lastAvailableCount, 0, "count tracked")

    let redeemedAlert = try UsageResetAlertBuilder
        .resetAlert(for: snapshot(.openai, "Codex", at: at(10), windows: []).withSignals(used.signals), noticedAt: at(10))
        .orThrow("redeemed alert")
    try expectEqual(redeemedAlert.resetKind, .bankedRedeemed, "redeemed alert kind")
    try expect(!redeemedAlert.isAnnounceable, "the user pressed the button; no banner")
    try expect(redeemedAlert.kind.isUsageReset, "but it still counts as a reset in history")

    let quiet = harness.sweep(snapshot(.openai, "Codex", at: at(15), windows: [weekly(2, at(10 + 7 * day))], credits: redeemed))
    try expect(quiet.signals.filter { $0.resetKind?.isResetEvent == true }.isEmpty, "no second report of the same reset")
}

// MARK: - Guards

private func testBankedAvailabilityStopsAfterRedemptionAndUnknownReadings() throws {
    let harness = Harness()
    var retained: [QuotaSignal] = []
    func sweep(_ minutes: Double, count: Int?) -> [QuotaSignal] {
        let credits = count.map { QuotaResetCreditSummary(availableCount: $0, observedAt: at(minutes)) }
        let result = harness.sweep(snapshot(.openai, "Codex", at: at(minutes), windows: [], credits: credits))
        retained = QuotaResetSignalRetention.merging(result.signals, with: retained)
        return retained
    }

    let grant = try sweep(0, count: 1).first.orThrow("grant")
    let polled = try sweep(5, count: 1).first.orThrow("standing notice")
    try expectEqual(polled.detectedAt, grant.detectedAt, "polling keeps the original availability identity")
    let redeemed = sweep(10, count: 0)
    try expect(!redeemed.contains { $0.resetKind == .bankedAvailable }, "redemption retires the persisted availability notice")
    try expect(redeemed.contains { $0.resetKind == .bankedRedeemed }, "redemption history stays visible")
    try expect(!sweep(15, count: 0).contains { $0.resetKind == .bankedAvailable }, "following polls cannot replay the spent reset")

    let newGrant = try sweep(20, count: 1).first { $0.resetKind == .bankedAvailable }.orThrow("new grant")
    try expectEqual(newGrant.detectedAt, at(20), "a genuinely new reset gets a new announcement")
    try expect(!sweep(25, count: nil).contains { $0.resetKind == .bankedAvailable }, "a missing credit reading must not replay cached availability")
    let restored = try sweep(30, count: 1).first { $0.resetKind == .bankedAvailable }.orThrow("restored reading")
    try expectEqual(restored.detectedAt, newGrant.detectedAt, "availability returning after an outage is the same grant")

    // Older builds persisted a standing availability for twelve hours. The
    // first empty detector result must clean it up even without a new event.
    let upgraded = QuotaResetSignalRetention.merging([], with: [grant])
    try expect(upgraded.isEmpty, "legacy persisted availability is retired on the next healthy observation")
}

private func testBankedExpiryReminderHasOneIdentityAcrossPollingAndRestart() throws {
    let harness = Harness()
    func sweep(_ minutes: Double) -> QuotaSignal {
        harness.sweep(snapshot(.openai, "Codex", at: at(minutes), windows: [], credits:
            QuotaResetCreditSummary(
                availableCount: 1,
                credits: [QuotaResetCredit(id: "expiry-credit", status: "available", expiresAt: at(360))],
                observedAt: at(minutes)
            )
        )).signals.first!
    }
    let granted = sweep(0)
    try expectEqual(granted.detectedAt, at(0), "initial grant is announced")
    try expectEqual(sweep(5).detectedAt, at(0), "ordinary polling does not announce it again")
    let reminder = sweep(180)
    try expectEqual(reminder.detectedAt, at(180), "crossing into the expiry window earns one reminder")
    try expectEqual(reminder.severity, .warning, "expiry reminder remains visible as a warning")
    try expectEqual(sweep(185).detectedAt, reminder.detectedAt, "countdown changes do not create another reminder")

    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    harness.state = try decoder.decode(QuotaResetDetector.ProviderState.self, from: encoder.encode(harness.state!))
    try expectEqual(sweep(190).detectedAt, reminder.detectedAt, "relaunch preserves the reminder identity")
}

private func testBankedFirstSightingNearExpiryDoesNotRemindTwice() throws {
    for initiallyEmpty in [false, true] {
        let harness = Harness()
        if initiallyEmpty {
            harness.sweep(snapshot(.openai, "Codex", at: at(-5), windows: [], credits:
                QuotaResetCreditSummary(availableCount: 0, observedAt: at(-5))))
        }
        func sweep(_ minutes: Double) -> QuotaSignal {
            harness.sweep(snapshot(.openai, "Codex", at: at(minutes), windows: [], credits:
                QuotaResetCreditSummary(
                    availableCount: 1,
                    credits: [QuotaResetCredit(id: "late-credit", status: "available", expiresAt: at(90))],
                    observedAt: at(minutes)
                )
            )).signals.first!
        }
        let first = sweep(0)
        try expectEqual(first.severity, .warning, "an already urgent grant includes the expiry warning")
        try expectEqual(sweep(5).detectedAt, first.detectedAt, "first sight and later grants inside the expiry window do not remind twice")
    }
}

private func testDelayedGrantHistoryDoesNotReannounceExistingCredit() throws {
    let harness = Harness()
    let first = harness.sweep(snapshot(.openai, "Codex", at: at(0), windows: [], credits:
        QuotaResetCreditSummary(availableCount: 1, observedAt: at(0))))
    let firstSignal = try first.signals.first.orThrow("grant without history")
    let delayed = harness.sweep(snapshot(.openai, "Codex", at: at(5), windows: [], credits:
        QuotaResetCreditSummary(
            availableCount: 1,
            history: [QuotaResetCreditEvent(id: "grant-one", kind: .granted, occurredAt: at(-1))],
            observedAt: at(5)
        )))
    try expectEqual(delayed.signals.first?.detectedAt, firstSignal.detectedAt, "history arriving later describes the credit already announced")
    let genuinelyNew = harness.sweep(snapshot(.openai, "Codex", at: at(10), windows: [], credits:
        QuotaResetCreditSummary(
            availableCount: 1,
            history: [
                QuotaResetCreditEvent(id: "grant-two", kind: .granted, occurredAt: at(9)),
                QuotaResetCreditEvent(id: "used-one", kind: .used, occurredAt: at(8)),
                QuotaResetCreditEvent(id: "grant-one", kind: .granted, occurredAt: at(-1))
            ],
            observedAt: at(10)
        )))
    try expectEqual(genuinelyNew.signals.first { $0.resetKind == .bankedAvailable }?.detectedAt, at(10), "a used-then-granted credit with unchanged count is still a new grant")
}

private func testWindowCooldownAllowsOneGiftPerDay() throws {
    let harness = Harness()
    func sweep(_ minutes: Double, _ used: Double, reset: Date) {
        harness.sweep(snapshot(.meta, "Meta API", at: at(minutes), windows: [meter("Weekly limit", used: used, reset: reset)]))
    }
    sweep(0, 70, reset: at(4 * day))
    sweep(5, 0, reset: at(5 + 7 * day))
    sweep(10, 1, reset: at(5 + 7 * day))
    try expectEqual(harness.resetSignals().count, 1, "first gift confirmed")

    sweep(120, 60, reset: at(5 + 7 * day))
    sweep(125, 0, reset: at(125 + 7 * day))
    sweep(130, 1, reset: at(125 + 7 * day))
    try expectEqual(harness.resetSignals().count, 1, "a second drop within a day is not believed")

    sweep(26 * 60, 55, reset: at(125 + 7 * day))
    sweep(26 * 60 + 5, 0, reset: at(26 * 60 + 5 + 7 * day))
    sweep(26 * 60 + 10, 1, reset: at(26 * 60 + 5 + 7 * day))
    try expectEqual(harness.resetSignals().count, 2, "the next day's gift counts again")
}

private func testKimiSoloWeeklyDropWaitsForUsageToResume() throws {
    let harness = Harness()
    func sweep(_ minutes: Double, _ used: Double) -> QuotaResetDetector.Outcome {
        harness.sweep(snapshot(.kimi, "Kimi Code", at: at(minutes), windows: [
            meter("Weekly", used: used, reset: at(5 * day), unit: "quota")
        ]))
    }
    _ = sweep(0, 41)
    try expect(sweep(5, 0).signals.isEmpty, "pending")
    try expect(sweep(10, 0).signals.isEmpty, "an empty meter that stays empty could be a lockout")
    let resumed = sweep(15, 3)
    try expectEqual(resumed.signals.map(\.resetKind), [.gifted], "usage resuming at a low level confirms the reset")

    let lockout = Harness()
    func lock(_ minutes: Double, _ used: Double) {
        lockout.sweep(snapshot(.kimi, "Kimi Code", at: at(minutes), windows: [
            meter("Weekly", used: used, reset: at(5 * day), unit: "quota")
        ]))
    }
    lock(0, 41)
    lock(5, 0)
    lock(10, 41)
    lock(15, 41)
    try expect(lockout.signals.isEmpty, "a meter that bounces back was a lockout, got \(lockout.signals.map(\.title))")
}

private func testCurrencyMetersAreLeftAlone() throws {
    let harness = Harness()
    harness.sweep(snapshot(.mistral, "Mistral", at: at(0), windows: [
        meter("API usage", kind: .monthly, used: 25.5, reset: at(20 * day), total: 25.5, unit: "EUR")
    ]))
    harness.sweep(snapshot(.mistral, "Mistral", at: at(5), windows: [
        meter("API usage", kind: .monthly, used: 0, reset: at(20 * day), total: 25.5, unit: "EUR")
    ]))
    harness.sweep(snapshot(.mistral, "Mistral", at: at(10), windows: [
        meter("API usage", kind: .monthly, used: 0, reset: at(20 * day), total: 25.5, unit: "EUR")
    ]))
    try expect(harness.signals.isEmpty, "a spend anchor being edited is not a quota reset")
}

private func testStateRoundTripsThroughJSON() throws {
    let harness = Harness()
    harness.sweep(snapshot(.openai, "Codex", at: at(0), windows: [meter("Weekly", used: 50, reset: at(day))],
                           credits: QuotaResetCreditSummary(availableCount: 1, observedAt: at(0))))
    harness.sweep(snapshot(.openai, "Codex", at: at(5), windows: [meter("Weekly", used: 0, reset: at(5 + 7 * day))],
                           credits: QuotaResetCreditSummary(availableCount: 1, observedAt: at(5))))
    let state = try harness.state.orThrow("state")
    try expect(state.windows.values.contains { $0.pending != nil }, "a pending drop is part of the state")

    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let restored = try decoder.decode(QuotaResetDetector.ProviderState.self, from: encoder.encode(state))
    try expectEqual(restored, state, "state survives persistence")

    let event = try harness.sweep(snapshot(.openai, "Codex", at: at(10), windows: [meter("Weekly", used: 1, reset: at(5 + 7 * day))],
                                           credits: QuotaResetCreditSummary(availableCount: 1, observedAt: at(10)))).events.first.orThrow("event")
    let restoredEvent = try decoder.decode(QuotaResetEvent.self, from: encoder.encode(event))
    try expectEqual(restoredEvent, event, "ledger events survive persistence")
}

@MainActor
private func testLedgerStoreDedupesAndCounts() throws {
    let suite = "reset-ledger-tests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = QuotaResetLedgerStore(defaults: defaults, key: "ledger")

    let gift = QuotaResetEvent(id: "a", providerID: .claude, windowLabel: "Weekly", kind: .gifted, occurredAt: at(0), confidence: 0.9, source: .inferred, summary: "Weekly 68% → 0%")
    let scheduled = QuotaResetEvent(id: "b", providerID: .claude, windowLabel: "Session", kind: .scheduled, occurredAt: at(1), confidence: 0.95, source: .inferred, summary: "Session reset on schedule")
    let banked = QuotaResetEvent(id: "c", providerID: .openai, windowLabel: nil, kind: .bankedRedeemed, occurredAt: at(2), confidence: 0.98, source: .providerReported, summary: "Banked reset redeemed")
    store.record([gift, scheduled, banked], now: at(3))
    store.record([gift], now: at(4))

    try expectEqual(store.events.count, 3, "duplicates collapse")
    try expectEqual(store.events(for: .claude).count, 2, "per-provider lookup")
    let counts = store.independentResetCounts(since: at(-1))
    try expectEqual(counts[.claude], 1, "only the gift counts as independent")
    try expectEqual(counts[.openai], nil, "a redeemed banked reset is not independent")

    let reloaded = QuotaResetLedgerStore(defaults: defaults, key: "ledger")
    try expectEqual(reloaded.events, store.events, "the ledger persists")
}

@main
private enum QuotaResetDetectorTestRunner {
    static func main() async throws {
        try testRollingResetDriftIsNotAReset()
        try testFlappingMeterNeverConfirms()
        try testScheduledResetIsRecordedQuietly()
        try testGiftedWeeklyResetConfirmsOnTheNextSweep()
        try testProviderWideResetAcrossWindows()
        try testSoloFiveHourDropIsIgnored()
        try testBankedCreditLifecycle()
        try testBankedAvailabilityStopsAfterRedemptionAndUnknownReadings()
        try testBankedExpiryReminderHasOneIdentityAcrossPollingAndRestart()
        try testBankedFirstSightingNearExpiryDoesNotRemindTwice()
        try testDelayedGrantHistoryDoesNotReannounceExistingCredit()
        try testUseThenNewGrantBetweenPollsStillAnnouncesOnce()
        try testWindowCooldownAllowsOneGiftPerDay()
        try testKimiSoloWeeklyDropWaitsForUsageToResume()
        try testCurrencyMetersAreLeftAlone()
        try testStateRoundTripsThroughJSON()
        try await testLedgerStoreDedupesAndCounts()
        print("Quota reset detector tests passed")
    }
}

private func testUseThenNewGrantBetweenPollsStillAnnouncesOnce() throws {
    let detector = QuotaResetDetector()
    let initial = snapshot(.openai, "Codex", at: at(0), windows: [], credits: .init(availableCount: 1, observedAt: at(0)))
    let first = detector.observe(initial, state: nil)
    let replacement = snapshot(.openai, "Codex", at: at(30), windows: [], credits: .init(
        availableCount: 1,
        history: [.init(id: "use-first", kind: .used, occurredAt: at(10)), .init(id: "grant-next", kind: .granted, occurredAt: at(20))],
        observedAt: at(30)
    ))
    let next = detector.observe(replacement, state: first.state)
    let retained = QuotaResetSignalRetention.merging(next.signals, with: first.signals)
    let sameSweep = QuotaSignal(kind: .unexpectedRecovery, title: "Banked reset redeemed", message: "used", severity: .info, detectedAt: at(30).addingTimeInterval(0.25), resetKind: .bankedRedeemed)
    let availability = try retained.first { $0.resetKind == .bankedAvailable }.orThrow("replacement signal")
    let fractional = QuotaSignal(kind: availability.kind, title: availability.title, message: availability.message, severity: availability.severity, windowLabel: availability.windowLabel, detectedAt: at(30).addingTimeInterval(0.25), resetKind: .bankedAvailable)
    let fractionalReading = replacement.withSignals([sameSweep, fractional])
    let fractionalAlert = try UsageResetAlertBuilder.resetAlert(for: fractionalReading, noticedAt: at(30).addingTimeInterval(0.25)).orThrow("same-sweep replacement")
    try expect(fractionalAlert.isRelevant(to: [fractionalReading]), "integer signature dates preserve live subsecond use/grant ordering")
    let current = replacement.withSignals(retained)
    let alert = try UsageResetAlertBuilder.resetAlert(for: current, noticedAt: at(30)).orThrow("replacement credit announcement")
    try expectEqual(alert.kind, .resetAvailable, "quiet redemption must not mask a later genuine grant")
    try expect(alert.isRelevant(to: [current]), "the replacement grant remains actionable")

    let poll = snapshot(.openai, "Codex", at: at(35), windows: [], credits: replacement.resetCredits)
    let repeated = detector.observe(poll, state: next.state)
    let polled = poll.withSignals(QuotaResetSignalRetention.merging(repeated.signals, with: retained))
    let repeatedAlert = try UsageResetAlertBuilder.resetAlert(for: polled, noticedAt: at(35)).orThrow("standing replacement credit")
    try expectEqual(repeatedAlert.signature, alert.signature, "polling must not turn the replacement grant into another notification")
}

private extension Optional {
    func orThrow(_ message: String) throws -> Wrapped {
        guard let value = self else {
            throw ResetDetectorTestError.failure("missing \(message)")
        }
        return value
    }
}
