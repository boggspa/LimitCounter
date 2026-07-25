import Foundation
import XCTest
@testable import CodexUsageKit

final class CodexSnapshotSignalDetectorTests: XCTestCase {
    private let observedAt = Date(timeIntervalSince1970: 2_000_000_000)

    func testDetectsManualResetOnTheNextPoll() throws {
        let previous = snapshot(
            used: 42,
            resetDate: observedAt.addingTimeInterval(3 * 24 * 60 * 60),
            fetchedAt: observedAt
        )
        let current = snapshot(
            used: 0,
            resetDate: observedAt.addingTimeInterval(7 * 24 * 60 * 60),
            fetchedAt: observedAt.addingTimeInterval(30)
        )

        let signal = try XCTUnwrap(
            CodexSnapshotSignalDetector().signals(current: current, previous: previous).first
        )

        XCTAssertEqual(signal.kind, .unexpectedRecovery)
        XCTAssertEqual(signal.title, "Usage window reset early")
        XCTAssertEqual(signal.windowLabel, "Weekly")
        XCTAssertEqual(signal.detectedAt, current.fetchedAt)
    }

    func testDetectsRestartedResetWindowAfterFreshUsage() throws {
        let previous = snapshot(
            used: 0,
            resetDate: observedAt.addingTimeInterval(2 * 24 * 60 * 60),
            fetchedAt: observedAt
        )
        let current = snapshot(
            used: 3,
            resetDate: observedAt.addingTimeInterval(7 * 24 * 60 * 60),
            fetchedAt: observedAt.addingTimeInterval(30)
        )

        let signal = try XCTUnwrap(
            CodexSnapshotSignalDetector().signals(current: current, previous: previous).first
        )

        XCTAssertTrue(signal.message.contains("reset window restarted"))
        XCTAssertEqual(signal.confidence, 0.95)
    }

    func testDoesNotSignalForUnchangedZeroUsageWindow() {
        let resetDate = observedAt.addingTimeInterval(7 * 24 * 60 * 60)
        let previous = snapshot(used: 0, resetDate: resetDate, fetchedAt: observedAt)
        let current = snapshot(
            used: 0,
            resetDate: resetDate,
            fetchedAt: observedAt.addingTimeInterval(30)
        )

        XCTAssertTrue(
            CodexSnapshotSignalDetector().signals(current: current, previous: previous).isEmpty
        )
    }

    private func snapshot(
        used: Double,
        resetDate: Date,
        fetchedAt: Date
    ) -> QuotaSnapshot {
        QuotaSnapshot(
            providerID: .codex,
            displayName: "Codex",
            planName: "Pro",
            windows: [
                QuotaWindow(
                    label: "Weekly",
                    windowKind: .weekly,
                    used: used,
                    total: 100,
                    resetDate: resetDate,
                    unit: "hrs",
                    subtitle: "7-day rolling window"
                )
            ],
            fetchState: .success,
            fetchedAt: fetchedAt
        )
    }
}
