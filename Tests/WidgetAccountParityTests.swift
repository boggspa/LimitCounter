import Foundation

private enum TestFailure: Error {
    case failed(String)
}

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else { throw TestFailure.failed(message) }
}

private func snapshot(_ provider: ProviderID, slot: String = "", label: String? = nil) -> QuotaSnapshot {
    QuotaSnapshot(
        providerID: provider,
        displayName: provider.snapshotDisplayName,
        windows: [QuotaWindow(label: "Weekly", windowKind: .weekly, used: slot.isEmpty ? 25 : 75, total: 100, unit: "%")],
        accountSlot: slot,
        accountLabel: label
    )
}

@main
private enum WidgetAccountParityTestRunner {
    static func main() throws {
        let primary = snapshot(.openai)
        let work = snapshot(.openai, slot: "work1", label: "Work")
        let telemetry = snapshot(.codexTelemetry)
        let snapshots = [work, primary, telemetry]

        try expect(
            QuotaTimelineProvider.telemetrySnapshot(for: primary, from: snapshots)?.providerID == .codexTelemetry,
            "primary Codex keeps its local telemetry"
        )
        try expect(
            QuotaTimelineProvider.telemetrySnapshot(for: work, from: snapshots) == nil,
            "secondary Codex must not show the primary account's telemetry"
        )
        try expect(
            QuotaTimelineProvider.telemetrySnapshot(for: snapshot(.claude), from: snapshots) == nil,
            "other providers never receive Codex telemetry"
        )

        let rows = SelectQuotaTrioRowBuilder.rows(
            from: snapshots,
            selectedMetricIDs: ["openai:Weekly", "openai#work1:Weekly"],
            at: Date()
        )
        try expect(rows.count == 2, "both selected accounts produce a row")
        try expect(Set(rows.map(\.id)).count == 2, "same-label meters from different accounts have distinct row identities")
        try expect(rows.map(\.id) == ["openai:Weekly", "openai#work1:Weekly"], "row identity retains the primary's existing key and secondary slot")
        try expect(rows.map(\.title) == ["Weekly", "Work · Weekly"], "secondary meter title identifies its account")
        try expect(rows.map(\.fraction) == [0.25, 0.75], "each row retains its own account's usage")

        let renamed = snapshot(.openai, slot: "work1", label: "Client")
        let renamedRows = SelectQuotaTrioRowBuilder.rows(
            from: [primary, renamed],
            selectedMetricIDs: ["openai#work1:Weekly"],
            at: Date()
        )
        try expect(renamedRows.first?.id == rows.last?.id, "renaming preserves the widget's saved selection")
        try expect(renamedRows.first?.title == "Client · Weekly", "renaming updates the account label")
        print("Widget account parity tests passed")
    }
}
