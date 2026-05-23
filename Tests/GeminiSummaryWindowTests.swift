import Foundation

private enum TestError: Error, CustomStringConvertible {
    case failure(String)

    var description: String {
        switch self {
        case .failure(let message):
            return message
        }
    }
}

private func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ label: String) throws {
    guard actual == expected else {
        throw TestError.failure("\(label): expected \(expected), got \(actual)")
    }
}

private func window(_ label: String) -> QuotaWindow {
    QuotaWindow(
        label: label,
        windowKind: .daily,
        used: label.contains("Pro") ? 2 : 0,
        total: 100,
        resetDate: Date().addingTimeInterval(24 * 60 * 60),
        unit: "%",
        subtitle: "test"
    )
}

private func testGeminiLiveSummaryWindows() throws {
    let snapshot = QuotaSnapshot(
        providerID: .gemini,
        displayName: "Gemini CLI",
        windows: [
            window("Pro 3.1 (preview)"),
            window("Flash Lite 3.1 (preview)"),
            window("Pro 3 (preview)"),
            window("Flash 3 (preview)"),
            window("Pro 2.5"),
            window("Flash 2.5"),
            window("Flash Lite 2.5")
        ]
    )

    try expectEqual(snapshot.windows.count, 7, "full window count")
    try expectEqual(
        snapshot.summaryWindows.map(\.label),
        ["Pro 3.1 (preview)", "Flash 3 (preview)", "Flash Lite 3.1 (preview)"],
        "Gemini live summary labels"
    )
}

private func testGeminiLocalFallbackSummaryWindows() throws {
    let snapshot = QuotaSnapshot(
        providerID: .gemini,
        displayName: "Gemini CLI",
        windows: [
            window("Flash"),
            window("Flash Lite"),
            window("Pro"),
            window("Daily Requests"),
            window("Weekly Requests")
        ]
    )

    try expectEqual(
        snapshot.summaryWindows.map(\.label),
        ["Pro", "Flash", "Flash Lite"],
        "Gemini local fallback summary labels"
    )
}

private func testNonGeminiSummaryWindowsAreUnchanged() throws {
    let snapshot = QuotaSnapshot(
        providerID: .claude,
        displayName: "Claude Code",
        windows: [window("Session"), window("Weekly"), window("Other")]
    )

    try expectEqual(snapshot.summaryWindows.map(\.label), snapshot.windows.map(\.label), "non-Gemini summary labels")
}

@main
private enum GeminiSummaryWindowTestRunner {
    static func main() throws {
        try testGeminiLiveSummaryWindows()
        try testGeminiLocalFallbackSummaryWindows()
        try testNonGeminiSummaryWindowsAreUnchanged()
        print("Gemini summary window tests passed")
    }
}
