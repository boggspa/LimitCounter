import Foundation

private enum UsageAlertBuilderTestFailure: Error, CustomStringConvertible {
    case failed(String)

    var description: String {
        switch self {
        case .failed(let message):
            return message
        }
    }
}

private func alertExpect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() {
        throw UsageAlertBuilderTestFailure.failed(message)
    }
}

private func alertExpectEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: String) throws {
    if actual != expected {
        throw UsageAlertBuilderTestFailure.failed("\(message): expected \(expected), got \(actual)")
    }
}

private func resetSignal(
    kind: QuotaSignalKind = .unexpectedRecovery,
    label: String,
    detectedAt: Date
) -> QuotaSignal {
    QuotaSignal(
        kind: kind,
        title: kind == .scheduledReset ? "\(label) reset" : "Usage window reset early",
        message: "\(label) reset from 28% to 0% about 1h earlier than the prior reset estimate.",
        severity: .info,
        confidence: 0.9,
        windowLabel: label,
        detectedAt: detectedAt
    )
}

private func snapshot(signals: [QuotaSignal]) -> QuotaSnapshot {
    QuotaSnapshot(
        providerID: .openai,
        displayName: "Codex",
        windows: [
            QuotaWindow(
                label: "Session",
                windowKind: .session,
                used: 0,
                total: 100,
                resetDate: Date().addingTimeInterval(60 * 60),
                unit: "%"
            )
        ],
        signals: signals,
        fetchedAt: Date()
    )
}

private func testResetSignalsAreGroupedIntoOneProviderAlert() throws {
    let noticedAt = Date(timeIntervalSince1970: 2_000)
    let current = snapshot(signals: [
        resetSignal(label: "Session", detectedAt: noticedAt),
        resetSignal(label: "Weekly", detectedAt: noticedAt.addingTimeInterval(-10))
    ])

    let alert = try UsageResetAlertBuilder
        .resetAlert(for: current, noticedAt: noticedAt)
        .orThrow("expected reset alert")

    try alertExpectEqual(alert.providerID, .openai, "provider")
    try alertExpectEqual(alert.kind, .unexpectedRecovery, "independent resets alert as unexpected recovery")
    try alertExpectEqual(alert.windowLabel, "Session and Weekly", "variant summary")
    try alertExpect(alert.body.contains("Noticed at"), "body includes noticed time")
    try alertExpect(alert.body.contains("Session"), "body includes first variant")
    try alertExpect(alert.body.contains("Weekly"), "body includes second variant")
}

private func testMetadataSignalsAreNotResetAlerts() throws {
    let current = snapshot(signals: [
        QuotaSignal(
            kind: .unexpectedRecovery,
            title: "Active Google Account",
            message: "Using Gemini CLI session for someone@example.com.",
            severity: .info,
            detectedAt: Date()
        )
    ])

    try alertExpect(
        UsageResetAlertBuilder.resetAlert(for: current, noticedAt: Date()) == nil,
        "metadata-style unexpectedRecovery signals should not notify as resets"
    )
}

private func testScheduledResetsDoNotNotify() throws {
    let noticedAt = Date(timeIntervalSince1970: 3_000)
    let current = snapshot(signals: [
        resetSignal(kind: .scheduledReset, label: "Weekly", detectedAt: noticedAt)
    ])

    try alertExpect(
        UsageResetAlertBuilder.resetAlert(for: current, noticedAt: noticedAt) == nil,
        "a provider's routine scheduled reset is expected and must not alert"
    )

    // A scheduled reset alongside an independent one must not widen the alert
    // to cover both windows.
    let mixed = snapshot(signals: [
        resetSignal(label: "Session", detectedAt: noticedAt),
        resetSignal(kind: .scheduledReset, label: "Weekly", detectedAt: noticedAt)
    ])
    let alert = try UsageResetAlertBuilder
        .resetAlert(for: mixed, noticedAt: noticedAt)
        .orThrow("independent reset still alerts when mixed with a scheduled one")
    try alertExpectEqual(alert.windowLabel, "Session", "scheduled window is left out of the summary")
}

private func testStaleCacheWarningDoesNotNotifyAsAReset() throws {
    // Devin's stale-cache diagnostic rides on `.scheduledReset` for want of a
    // closer kind; it must never surface as "Devin reset".
    let noticedAt = Date(timeIntervalSince1970: 4_000)
    let current = snapshot(signals: [
        QuotaSignal(
            kind: .scheduledReset,
            title: "Devin quota reading is stale",
            message: "Daily quota and Weekly quota covered a period that has already reset, so they are hidden rather than shown as current.",
            severity: .warning,
            detectedAt: noticedAt
        )
    ])

    try alertExpect(
        UsageResetAlertBuilder.resetAlert(for: current, noticedAt: noticedAt) == nil,
        "a staleness warning must not be announced as a quota reset"
    )
}

private func testRepeatedWindowResetGetsNewSignature() throws {
    let firstDate = Date(timeIntervalSince1970: 10_000)
    let secondDate = firstDate.addingTimeInterval(5 * 60 * 60)

    let firstAlert = try UsageResetAlertBuilder
        .resetAlert(for: snapshot(signals: [resetSignal(label: "Session", detectedAt: firstDate)]), noticedAt: firstDate)
        .orThrow("first alert")
    let secondAlert = try UsageResetAlertBuilder
        .resetAlert(for: snapshot(signals: [resetSignal(label: "Session", detectedAt: secondDate)]), noticedAt: secondDate)
        .orThrow("second alert")

    try alertExpect(firstAlert.signature != secondAlert.signature, "repeated resets need distinct signatures")
    try alertExpectEqual(
        CloudAlertPayload.parse(signature: firstAlert.signature).windowLabel,
        "Session",
        "new signature parses label"
    )
}

@main
private enum UsageAlertBuilderTestRunner {
    static func main() throws {
        try testResetSignalsAreGroupedIntoOneProviderAlert()
        try testMetadataSignalsAreNotResetAlerts()
        try testScheduledResetsDoNotNotify()
        try testStaleCacheWarningDoesNotNotifyAsAReset()
        try testRepeatedWindowResetGetsNewSignature()
        try testClassifiedSignalsDriveTheAlert()
        try testLegacySignalsStillReadAsEarlyResets()
        try testBankedAvailabilityRequiresCurrentCredits()
        try testAvailabilityReplayIsRetiredAfterRedemption()
        try testResetPublicationSurvivesUnrelatedAlerts()
        print("Usage alert builder tests passed")
    }
}

private func classifiedSignal(_ resetKind: QuotaResetKind, label: String, message: String, detectedAt: Date) -> QuotaSignal {
    QuotaSignal(
        kind: resetKind == .scheduled ? .scheduledReset : .unexpectedRecovery,
        title: resetKind.title,
        message: message,
        severity: .info,
        confidence: 0.9,
        windowLabel: label,
        detectedAt: detectedAt,
        resetKind: resetKind
    )
}

private func testClassifiedSignalsDriveTheAlert() throws {
    let noticedAt = Date(timeIntervalSince1970: 5_000)

    // A banked reset waiting to be redeemed: its own alert kind, announceable,
    // never counted as a reset that happened.
    let available = snapshot(signals: [
        classifiedSignal(.bankedAvailable, label: "Banked reset", message: "1 usage-limit reset is banked and expires in 2h.", detectedAt: noticedAt)
    ]).withResetCredits(QuotaResetCreditSummary(availableCount: 1, observedAt: noticedAt))
    let availableAlert = try UsageResetAlertBuilder.resetAlert(for: available, noticedAt: noticedAt).orThrow("available alert")
    try alertExpectEqual(availableAlert.kind, .resetAvailable, "available kind")
    try alertExpectEqual(availableAlert.resetKind, .bankedAvailable, "available reset kind")
    try alertExpect(availableAlert.isAnnounceable, "available is announceable")
    try alertExpect(!availableAlert.kind.isUsageReset, "available is not a reset")
    try alertExpectEqual(availableAlert.title, "Codex reset available", "available title")
    try alertExpect(availableAlert.body.contains("expires in 2h"), "body carries the signal message")
    try alertExpectEqual(CloudAlertPayload.parse(signature: availableAlert.signature).kind, .resetAvailable, "signature kind")

    // A redeemed banked reset: recorded, not announced.
    let redeemed = snapshot(signals: [
        classifiedSignal(.bankedRedeemed, label: "Weekly", message: "Weekly restarted at 0% after a banked reset was redeemed.", detectedAt: noticedAt),
        classifiedSignal(.bankedAvailable, label: "Banked reset", message: "stale", detectedAt: noticedAt.addingTimeInterval(-60))
    ])
    let redeemedAlert = try UsageResetAlertBuilder.resetAlert(for: redeemed, noticedAt: noticedAt).orThrow("redeemed alert")
    try alertExpectEqual(redeemedAlert.kind, .unexpectedRecovery, "redeemed kind")
    try alertExpectEqual(redeemedAlert.resetKind, .bankedRedeemed, "redeemed reset kind")
    try alertExpect(!redeemedAlert.isAnnounceable, "redeemed is quiet")
    try alertExpect(redeemedAlert.kind.isUsageReset, "redeemed counts in history")
    try alertExpectEqual(redeemedAlert.windowLabel, "Weekly", "the reset outranks the stale availability notice")
    try alertExpectEqual(redeemedAlert.badgeTitle, "Banked reset redeemed", "redeemed badge")

    // Provider-wide beats a solo gift in the same alert.
    let wide = snapshot(signals: [
        classifiedSignal(.providerWide, label: "Session", message: "Session fell from 40% to 0% together with 2 other Codex windows.", detectedAt: noticedAt),
        classifiedSignal(.providerWide, label: "Weekly", message: "Weekly fell from 32% to 0% together with 2 other Codex windows.", detectedAt: noticedAt)
    ])
    let wideAlert = try UsageResetAlertBuilder.resetAlert(for: wide, noticedAt: noticedAt).orThrow("wide alert")
    try alertExpectEqual(wideAlert.resetKind, .providerWide, "wide reset kind")
    try alertExpectEqual(wideAlert.title, "Codex quotas reset", "wide title")
    try alertExpectEqual(wideAlert.windowLabel, "Session and Weekly", "wide summary")
    try alertExpect(wideAlert.signature.hasSuffix("|providerWide"), "signature carries the kind")

    // A classified scheduled reset stays silent even though it is unexpectedRecovery-adjacent.
    let scheduled = snapshot(signals: [
        classifiedSignal(.scheduled, label: "Weekly", message: "Quota refreshed from 80% to 0%.", detectedAt: noticedAt)
    ])
    try alertExpect(UsageResetAlertBuilder.resetAlert(for: scheduled, noticedAt: noticedAt) == nil, "scheduled stays quiet")
}

private func testBankedAvailabilityRequiresCurrentCredits() throws {
    let date = Date(timeIntervalSince1970: 10_000)
    let stale = snapshot(signals: [classifiedSignal(.bankedAvailable, label: "Banked reset", message: "old availability", detectedAt: date)])
    try alertExpect(UsageResetAlertBuilder.resetAlert(for: stale, noticedAt: date) == nil, "missing current credits cannot re-announce a standing notice")
    try alertExpect(UsageResetAlertBuilder.resetAlert(for: stale.withResetCredits(.init(availableCount: 0)), noticedAt: date) == nil, "authoritative zero suppresses old availability")
    let history = [QuotaResetCreditEvent(id: "used", kind: .used, occurredAt: date.addingTimeInterval(10))]
    try alertExpect(UsageResetAlertBuilder.resetAlert(for: stale.withResetCredits(.init(availableCount: 1, history: history)), noticedAt: date.addingTimeInterval(20)) == nil, "remaining credits cannot make a pre-redemption announcement current again")
}

private func testAvailabilityReplayIsRetiredAfterRedemption() throws {
    let date = Date(timeIntervalSince1970: 20_000)
    let granted = snapshot(signals: [classifiedSignal(.bankedAvailable, label: "Banked reset", message: "available", detectedAt: date)])
        .withResetCredits(.init(availableCount: 1, observedAt: date))
    let alert = try UsageResetAlertBuilder.resetAlert(for: granted, noticedAt: date).orThrow("current banked alert")
    try alertExpect(alert.isRelevant(to: [granted]), "current availability remains relevant")
    try alertExpect(!alert.isRelevant(to: [granted.withResetCredits(.init(availableCount: 0))]), "replay is retired after count reaches zero")
    try alertExpect(!alert.isRelevant(to: []), "no account reading means no actionable old availability")
    let other = granted.withAccount(slot: "work", label: "Work", fingerprint: nil)
    try alertExpect(!alert.isRelevant(to: [other]), "another account's credits cannot keep an old alert alive")
    let consumed = granted.withResetCredits(.init(availableCount: 1, history: [.init(id: "used", kind: .used, occurredAt: date.addingTimeInterval(10))]))
    try alertExpect(!alert.isRelevant(to: [consumed]), "replay is retired after partial redemption too")
    let newGrant = consumed.withSignals([classifiedSignal(.bankedAvailable, label: "Banked reset", message: "new grant", detectedAt: date.addingTimeInterval(30))])
    let newAlert = try UsageResetAlertBuilder.resetAlert(for: newGrant, noticedAt: date.addingTimeInterval(30)).orThrow("new grant after use")
    try alertExpect(newAlert.isRelevant(to: [newGrant]), "a genuine later grant can still notify")
}

private func testResetPublicationSurvivesUnrelatedAlerts() throws {
    let first = "reset|openai|resetAvailable|1000|Banked reset|bankedAvailable"
    let reminder = "reset|openai|resetAvailable|2000|Banked reset|bankedAvailable"
    var history = ResetAlertPublication.remember(first, in: [])
    history = ResetAlertPublication.remember(reminder, in: history)
    try alertExpect(history.contains(first), "publishing a different notice cannot forget the grant")
    for latest in [nil, "error", "warning|Weekly", reminder] {
        try alertExpect(!ResetAlertPublication.shouldPublish(signature: first, kind: .resetAvailable, lastSignature: latest, resetHistory: history), "no alert, error, threshold or expiry notice cannot re-arm an already-published grant")
    }
    try alertExpect(ResetAlertPublication.shouldPublish(signature: "reset|openai|resetAvailable|3000|Banked reset|bankedAvailable", kind: .resetAvailable, lastSignature: reminder, resetHistory: history), "a genuine later grant publishes")
    try alertExpect(ResetAlertPublication.shouldPublish(signature: "warning|Weekly", kind: .threshold, lastSignature: nil, resetHistory: history), "reset dedup preserves recurring threshold transitions")
    try alertExpectEqual(ResetAlertPublication.remember(first, in: history).count, 2, "retry does not duplicate the saved signature")
    try alertExpectEqual(ResetAlertPublication.recordName(signature: first), ResetAlertPublication.recordName(signature: first), "retry/second publisher addresses the same cloud event")
    try alertExpect(ResetAlertPublication.recordName(signature: first) != ResetAlertPublication.recordName(signature: reminder), "the intentional expiry reminder remains a distinct event")
}

private func testLegacySignalsStillReadAsEarlyResets() throws {
    let noticedAt = Date(timeIntervalSince1970: 6_000)
    let legacy = snapshot(signals: [resetSignal(label: "Weekly", detectedAt: noticedAt)])
    let alert = try UsageResetAlertBuilder.resetAlert(for: legacy, noticedAt: noticedAt).orThrow("legacy alert")
    try alertExpectEqual(alert.resetKind, .gifted, "an unclassified early reset reads as a gift")
    try alertExpectEqual(alert.title, "Codex reset early", "legacy title unchanged")
    try alertExpect(alert.isAnnounceable, "legacy alerts still announce")
    let parsed = CloudAlertPayload.parse(signature: "reset|openai|unexpectedRecovery|1789000000|Weekly")
    try alertExpectEqual(parsed.kind, .unexpectedRecovery, "old signature kind")
    try alertExpectEqual(parsed.resetKind, nil, "old signature has no reset kind")
    try alertExpectEqual(parsed.windowLabel, "Weekly", "old signature label")
}

private extension Optional {
    func orThrow(_ message: String) throws -> Wrapped {
        guard let value = self else {
            throw UsageAlertBuilderTestFailure.failed(message)
        }
        return value
    }
}
