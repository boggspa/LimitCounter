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
        resetSignal(kind: .scheduledReset, label: "Weekly", detectedAt: noticedAt.addingTimeInterval(-10))
    ])

    let alert = try UsageResetAlertBuilder
        .resetAlert(for: current, noticedAt: noticedAt)
        .orThrow("expected reset alert")

    try alertExpectEqual(alert.providerID, .openai, "provider")
    try alertExpectEqual(alert.kind, .unexpectedRecovery, "mixed reset kind favors unexpected recovery")
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
        try testRepeatedWindowResetGetsNewSignature()
        print("Usage alert builder tests passed")
    }
}

private extension Optional {
    func orThrow(_ message: String) throws -> Wrapped {
        guard let value = self else {
            throw UsageAlertBuilderTestFailure.failed(message)
        }
        return value
    }
}
