import Foundation

public struct CodexSnapshotSignalDetector {
    private let minimumObservationGap: TimeInterval
    private let minimumRemainingWindow: TimeInterval
    private let minimumEarlyLead: TimeInterval
    private let maximumElapsedShare: Double
    private let minimumFractionDrop: Double
    private let strongRecoveryFloor: Double

    public init(
        minimumObservationGap: TimeInterval = 0,
        minimumRemainingWindow: TimeInterval = 30 * 60,
        minimumEarlyLead: TimeInterval = 20 * 60,
        maximumElapsedShare: Double = 0.5,
        minimumFractionDrop: Double = 0.35,
        strongRecoveryFloor: Double = 0.55
    ) {
        self.minimumObservationGap = minimumObservationGap
        self.minimumRemainingWindow = minimumRemainingWindow
        self.minimumEarlyLead = minimumEarlyLead
        self.maximumElapsedShare = maximumElapsedShare
        self.minimumFractionDrop = minimumFractionDrop
        self.strongRecoveryFloor = strongRecoveryFloor
    }

    public func enrichedSnapshot(current: QuotaSnapshot, previous: QuotaSnapshot?) -> QuotaSnapshot {
        guard current.fetchState.isHealthy else {
            return current.withSignals([])
        }
        return current.withSignals(signals(current: current, previous: previous))
    }

    public func signals(current: QuotaSnapshot, previous: QuotaSnapshot?) -> [QuotaSignal] {
        guard current.fetchState.isHealthy,
              let previous,
              previous.fetchState.isHealthy,
              current.providerID == previous.providerID else {
            return []
        }

        let elapsed = current.fetchedAt.timeIntervalSince(previous.fetchedAt)
        guard elapsed > 0, elapsed >= minimumObservationGap else {
            return []
        }

        let previousWindows: [WindowComparisonKey: QuotaWindow] = Dictionary(
            uniqueKeysWithValues: previous.windows.compactMap { window -> (WindowComparisonKey, QuotaWindow)? in
                guard window.hasExplicitLimit, let total = window.total, total > 0 else { return nil }
                return (WindowComparisonKey(window: window), window)
            }
        )

        return current.windows.compactMap { currentWindow in
            let key = WindowComparisonKey(window: currentWindow)
            guard let previousWindow = previousWindows[key] else { return nil }
            return unexpectedRecoverySignal(
                currentWindow: currentWindow,
                previousWindow: previousWindow,
                currentDate: current.fetchedAt,
                previousDate: previous.fetchedAt
            )
        }
    }

    private func unexpectedRecoverySignal(
        currentWindow: QuotaWindow,
        previousWindow: QuotaWindow,
        currentDate: Date,
        previousDate: Date
    ) -> QuotaSignal? {
        guard currentWindow.hasExplicitLimit,
              previousWindow.hasExplicitLimit,
              let currentTotal = currentWindow.total,
              let previousTotal = previousWindow.total,
              currentTotal > 0,
              previousTotal > 0 else {
            return nil
        }

        let totalDelta = abs(currentTotal - previousTotal)
        guard totalDelta <= max(1, previousTotal * 0.05) else {
            return nil
        }

        guard let previousResetDate = previousWindow.resetDate else {
            return nil
        }

        let elapsed = currentDate.timeIntervalSince(previousDate)
        let previousRemaining = previousResetDate.timeIntervalSince(previousDate)

        guard previousRemaining >= minimumRemainingWindow else {
            return nil
        }

        let elapsedShare = elapsed / previousRemaining
        guard elapsedShare < maximumElapsedShare else {
            return nil
        }

        let previousFraction = recordedFractionUsed(previousWindow)
        let currentFraction = recordedFractionUsed(currentWindow)
        let fractionDrop = previousFraction - currentFraction
        let resetToZeroEarly = currentFraction <= 0.01
            && currentWindow.used <= max(1, currentTotal * 0.01)
            && previousFraction >= 0.08
            && fractionDrop >= 0.08
        let strongRecovery = currentFraction <= 0.20
            || fractionDrop >= strongRecoveryFloor
            || currentWindow.used <= previousWindow.used * 0.4

        let strongDropRecovery = previousFraction >= 0.50
            && fractionDrop >= minimumFractionDrop
            && strongRecovery

        let resetWindowRestarted: Bool
        if let currentResetDate = currentWindow.resetDate {
            resetWindowRestarted = currentFraction <= 0.10
                && currentResetDate.timeIntervalSince(previousResetDate) >= minimumEarlyLead
                && currentResetDate > currentDate
        } else {
            resetWindowRestarted = false
        }

        guard resetToZeroEarly || strongDropRecovery || resetWindowRestarted else {
            return nil
        }

        let earlyLead = previousRemaining - elapsed
        guard earlyLead >= minimumEarlyLead else {
            return nil
        }

        let confidence = signalConfidence(
            fractionDrop: fractionDrop,
            elapsedShare: elapsedShare,
            currentFraction: currentFraction,
            resetWindowRestarted: resetWindowRestarted
        )
        let recoveryTitle: String
        let message: String
        if resetWindowRestarted {
            recoveryTitle = "Usage window reset early"
            message = "\(currentWindow.label) reset window restarted at \(percentageUsed(currentFraction))% used about \(durationDescription(earlyLead)) earlier than the prior reset estimate."
        } else if resetToZeroEarly {
            recoveryTitle = "Usage window reset early"
            message = "\(currentWindow.label) reset from \(percentageUsed(previousFraction))% to 0% about \(durationDescription(earlyLead)) earlier than the prior reset estimate."
        } else {
            recoveryTitle = currentFraction <= 0.10
                ? "Usage window appears refreshed early"
                : "Unexpected quota recovery detected"
            message = "\(currentWindow.label) fell from \(percentageUsed(previousFraction))% to \(percentageUsed(currentFraction))% about \(durationDescription(earlyLead)) earlier than the prior reset estimate."
        }

        return QuotaSignal(
            kind: .unexpectedRecovery,
            title: recoveryTitle,
            message: message,
            severity: confidence >= 0.8 ? .warning : .info,
            confidence: confidence,
            windowLabel: currentWindow.label,
            detectedAt: currentDate
        )
    }

    private func signalConfidence(
        fractionDrop: Double,
        elapsedShare: Double,
        currentFraction: Double,
        resetWindowRestarted: Bool
    ) -> Double {
        if resetWindowRestarted {
            return 0.95
        }

        let recoveryScore = min(max(fractionDrop / 0.75, 0), 1)
        let earlinessScore = min(max(1 - elapsedShare, 0), 1)
        let freshnessScore = currentFraction <= 0.10 ? 1.0 : 0.7

        return min(0.95, max(0.55, 0.30 + recoveryScore * 0.35 + earlinessScore * 0.25 + freshnessScore * 0.10))
    }

    private func recordedFractionUsed(_ window: QuotaWindow) -> Double {
        guard let total = window.total, total > 0 else { return 0 }
        return min(max(window.used / total, 0), 1)
    }

    private func percentageUsed(_ fraction: Double) -> Int {
        Int((min(max(fraction, 0), 1) * 100).rounded())
    }

    private func durationDescription(_ interval: TimeInterval) -> String {
        let totalMinutes = max(Int(interval / 60), 1)
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60

        if hours > 0 && minutes > 0 {
            return "\(hours)h \(minutes)m"
        }
        if hours > 0 {
            return "\(hours)h"
        }
        return "\(minutes)m"
    }
}

private struct WindowComparisonKey: Hashable {
    let label: String
    let kind: QuotaWindowKind
    let unit: String

    init(window: QuotaWindow) {
        label = window.label.lowercased()
        kind = window.windowKind
        unit = window.unit.lowercased()
    }
}
