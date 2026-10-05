import Combine
import Foundation

// MARK: - Reset ledger

public enum QuotaResetEventSource: String, Codable, Hashable {
    /// Derived by comparing successive meter readings.
    case inferred
    /// Stated by the provider (a consumed reset credit, a history entry).
    case providerReported
}

/// One usage-limit reset the app is confident happened, kept in a rolling
/// ledger so cards can count them and the provider detail view can list them.
public struct QuotaResetEvent: Codable, Identifiable, Equatable, Hashable {
    public let id: String
    public let providerID: ProviderID
    /// Which account of the provider reset. Empty (the primary) for events
    /// recorded before accounts existed.
    public let accountSlot: String
    public let windowLabel: String?
    public let kind: QuotaResetKind
    public let occurredAt: Date
    public let fromFraction: Double?
    public let toFraction: Double?
    public let previousResetDate: Date?
    public let newResetDate: Date?
    public let confidence: Double
    public let source: QuotaResetEventSource
    public let summary: String

    public init(
        id: String,
        providerID: ProviderID,
        accountSlot: String = ProviderAccountKey.primarySlot,
        windowLabel: String?,
        kind: QuotaResetKind,
        occurredAt: Date,
        fromFraction: Double? = nil,
        toFraction: Double? = nil,
        previousResetDate: Date? = nil,
        newResetDate: Date? = nil,
        confidence: Double,
        source: QuotaResetEventSource,
        summary: String
    ) {
        self.id = id
        self.providerID = providerID
        self.accountSlot = ProviderAccountKey.normalizedSlot(accountSlot)
        self.windowLabel = windowLabel
        self.kind = kind
        self.occurredAt = occurredAt
        self.fromFraction = fromFraction
        self.toFraction = toFraction
        self.previousResetDate = previousResetDate
        self.newResetDate = newResetDate
        self.confidence = confidence
        self.source = source
        self.summary = summary
    }

    public var accountKey: ProviderAccountKey {
        ProviderAccountKey(providerID: providerID, slot: accountSlot)
    }

    private enum CodingKeys: String, CodingKey {
        case id, providerID, accountSlot, windowLabel, kind, occurredAt
        case fromFraction, toFraction, previousResetDate, newResetDate
        case confidence, source, summary
    }

    /// Ledger entries written before accounts existed have no slot and belong
    /// to the primary account.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        providerID = try container.decode(ProviderID.self, forKey: .providerID)
        accountSlot = ProviderAccountKey.normalizedSlot(
            try container.decodeIfPresent(String.self, forKey: .accountSlot) ?? ProviderAccountKey.primarySlot
        )
        windowLabel = try container.decodeIfPresent(String.self, forKey: .windowLabel)
        kind = try container.decode(QuotaResetKind.self, forKey: .kind)
        occurredAt = try container.decode(Date.self, forKey: .occurredAt)
        fromFraction = try container.decodeIfPresent(Double.self, forKey: .fromFraction)
        toFraction = try container.decodeIfPresent(Double.self, forKey: .toFraction)
        previousResetDate = try container.decodeIfPresent(Date.self, forKey: .previousResetDate)
        newResetDate = try container.decodeIfPresent(Date.self, forKey: .newResetDate)
        confidence = try container.decode(Double.self, forKey: .confidence)
        source = try container.decode(QuotaResetEventSource.self, forKey: .source)
        summary = try container.decode(String.self, forKey: .summary)
    }
}

/// Historical reset signals can stay on a card for a while, but availability
/// is current state: replaying it after redemption would offer a spent reset.
enum QuotaResetSignalRetention {
    static func merging(_ detected: [QuotaSignal], with previous: [QuotaSignal]) -> [QuotaSignal] {
        var merged = previous.filter { $0.resetKind != .bankedAvailable }
        for signal in detected {
            merged.removeAll {
                $0.kind == signal.kind
                    && $0.windowLabel == signal.windowLabel
                    && $0.resetKind == signal.resetKind
            }
            merged.append(signal)
        }
        return merged.sorted { $0.detectedAt > $1.detectedAt }
    }
}

// MARK: - Detector

/// Turns successive quota readings into classified reset events.
///
/// The previous detector compared one reading with the one before it and
/// fired on anything that looked like a drop. Two things made that noisy:
/// a rolling window whose reset estimate drifts forward while usage is low
/// read as "reset window restarted" on every refresh (six Codex Spark
/// "early resets" in five days), and a scraped meter that flapped between
/// 0% and 100% produced a fresh alert per flap (five Qwen "resets" in an
/// hour). This detector keeps a short observation trail per window, treats
/// a drop as *pending* until the next reading confirms it held, never counts
/// reset-date movement as a reset on its own, requires a sibling window or a
/// provider-reported credit before believing a five-hour window reset
/// early, and rate-limits confirmed resets to one per window per day.
///
/// Provider-reported reset credits (Codex today, Qwen's console count) are
/// diffed first, so a weekly window that restarts in the same sweep a credit
/// disappears is classified as a redeemed banked reset rather than a gift.
///
/// Pure: `observe` maps (snapshot, state) to (state, signals, events) and
/// keeps no storage of its own, which is what makes it testable.
public struct QuotaResetDetector {
    public struct Configuration: Equatable {
        /// Readings closer together than this are not compared for new drops.
        public var minimumObservationGap: TimeInterval = 90
        /// A drop counts as "early" only if the window still had this long to run.
        public var minimumEarlyLead: TimeInterval = 20 * 60
        /// Slack around the previous reset estimate when deciding a drop was scheduled.
        public var scheduledTolerance: TimeInterval = 15 * 60
        /// A clean reset: at least this much used before, ...
        public var cleanResetFloor: Double = 0.30
        /// ... at most this much after, ...
        public var cleanResetCeiling: Double = 0.15
        /// ... and a drop of at least this much.
        public var minimumDrop: Double = 0.25
        /// A strong recovery that never quite reached zero.
        public var strongRecoveryFloor: Double = 0.50
        public var strongRecoveryDrop: Double = 0.35
        public var strongRecoveryCeiling: Double = 0.20
        /// A pending drop is judged against the next reading at least this much later.
        public var confirmationGap: TimeInterval = 60
        /// A pending drop that no reading confirms within this long is forgotten.
        public var pendingExpiry: TimeInterval = 6 * 60 * 60
        /// After a confirmed reset the window must climb back above this before
        /// another reset can be believed.
        public var rearmFraction: Double = 0.20
        /// At most one inferred reset per window in this period.
        public var perWindowCooldown: TimeInterval = 24 * 60 * 60
        /// Windows this short (five-hour allowances) only reset early alongside
        /// a sibling window or a consumed credit.
        public var shortWindowMaximumPeriod: TimeInterval = 6 * 60 * 60
        /// A reset estimate that moves forward by this share of the period
        /// corroborates a restart (it is never sufficient on its own).
        public var resetDateJumpShare: Double = 0.40
        /// Windows resetting together in one sweep for a provider-wide reset.
        public var providerWideMinimumWindows: Int = 2
        public var maxObservations: Int = 12
        /// A banked credit due to expire within this long earns a reminder.
        public var expiringSoonLead: TimeInterval = 3 * 60 * 60
        /// Providers whose meter can read as empty while the account is locked
        /// out; a solo weekly drop there must also show usage resuming, or a
        /// reset-date jump, before it is believed.
        public var lockoutProneProviders: Set<ProviderID> = [.kimi]
        public var lockoutPendingExpiry: TimeInterval = 24 * 60 * 60

        public init() {}
    }

    public struct Observation: Codable, Equatable {
        public let at: Date
        public let fraction: Double
        public let used: Double
        public let total: Double
        public let resetDate: Date?

        public init(at: Date, fraction: Double, used: Double, total: Double, resetDate: Date?) {
            self.at = at
            self.fraction = fraction
            self.used = used
            self.total = total
            self.resetDate = resetDate
        }
    }

    public struct PendingReset: Codable, Equatable {
        public let observedAt: Date
        public let fromFraction: Double
        public let toFraction: Double
        public let previousResetDate: Date?
        public let newResetDate: Date?
        public let resetDateJumped: Bool
        public let needsUsageResumption: Bool
    }

    public struct WindowTrack: Codable, Equatable {
        public let key: String
        public var label: String
        public var observations: [Observation]
        public var pending: PendingReset?
        public var lastConfirmedAt: Date?
        public var armed: Bool

        public init(key: String, label: String) {
            self.key = key
            self.label = label
            self.observations = []
            self.pending = nil
            self.lastConfirmedAt = nil
            self.armed = true
        }
    }

    public struct CreditTrack: Codable, Equatable {
        public var lastAvailableCount: Int
        public var seenEventIDs: [String]
        public var announcedAvailableAt: Date?
        public var announcedExpiringAt: Date?
        public var lastRedeemedAt: Date?
    }

    public struct ProviderState: Codable, Equatable {
        public var windows: [String: WindowTrack]
        public var credits: CreditTrack?

        public init(windows: [String: WindowTrack] = [:], credits: CreditTrack? = nil) {
            self.windows = windows
            self.credits = credits
        }
    }

    public struct Outcome {
        public let state: ProviderState
        public let signals: [QuotaSignal]
        public let events: [QuotaResetEvent]
    }

    public static let bankedResetWindowLabel = "Banked reset"

    public let configuration: Configuration

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    // MARK: Observe

    public func observe(_ snapshot: QuotaSnapshot, state previousState: ProviderState?) -> Outcome {
        var state = previousState ?? ProviderState()
        guard snapshot.fetchState.isHealthy else {
            return Outcome(state: state, signals: [], events: [])
        }

        let now = snapshot.fetchedAt
        var signals: [QuotaSignal] = []
        var events: [QuotaResetEvent] = []

        let creditOutcome = observeCredits(snapshot, state: &state, now: now)
        signals += creditOutcome.signals
        events += creditOutcome.events

        var confirmations: [WindowConfirmation] = []
        var candidates: [WindowCandidate] = []

        for window in snapshot.windows {
            guard window.hasExplicitLimit,
                  let total = window.total,
                  total > 0,
                  !window.isCurrencyMetric else {
                continue
            }

            let key = WindowKey(window: window).string
            var track = state.windows[key] ?? WindowTrack(key: key, label: window.label)
            track.label = window.label

            let observation = Observation(
                at: now,
                fraction: min(max(window.used / total, 0), 1),
                used: window.used,
                total: total,
                resetDate: window.resetDate
            )

            // A cached reading served again carries the same timestamp; it
            // says nothing new.
            if let last = track.observations.last, now <= last.at {
                state.windows[key] = track
                continue
            }

            let previous = track.observations.last
            let period = window.inferredPeriodDuration(providerID: snapshot.providerID)
                ?? previous.flatMap { prior in
                    prior.resetDate.map { max($0.timeIntervalSince(prior.at), 60 * 60) }
                }
                ?? 7 * 24 * 60 * 60

            // 1. Judge any pending drop against this reading.
            if let pending = track.pending {
                let age = now.timeIntervalSince(pending.observedAt)
                let expiry = pending.needsUsageResumption
                    ? configuration.lockoutPendingExpiry
                    : configuration.pendingExpiry
                if age > expiry {
                    track.pending = nil
                } else if age >= configuration.confirmationGap {
                    let bounceLine = pending.fromFraction - 0.5 * (pending.fromFraction - pending.toFraction)
                    let held = observation.fraction <= bounceLine
                    let jumpedNow = pending.resetDateJumped
                        || resetDateJumped(from: pending.previousResetDate, to: observation.resetDate, period: period)
                    let usageResumed = observation.fraction > pending.toFraction + 0.005
                    let lockoutSatisfied = !pending.needsUsageResumption || jumpedNow || usageResumed

                    if held && lockoutSatisfied {
                        confirmations.append(
                            WindowConfirmation(
                                key: key,
                                window: window,
                                pending: pending,
                                period: period,
                                confirmedAt: now,
                                resetDateJumped: jumpedNow
                            )
                        )
                        track.pending = nil
                    } else if !held {
                        // It bounced back: a flapping source, not a reset.
                        track.pending = nil
                    }
                    // Otherwise the drop held but the lockout guard still
                    // waits for usage to resume; keep it pending.
                }
            }

            // 2. Compare with the previous reading for a new drop.
            if track.pending == nil,
               let previous,
               now.timeIntervalSince(previous.at) >= configuration.minimumObservationGap,
               abs(previous.total - total) <= max(1, previous.total * 0.05) {
                if !track.armed, observation.fraction >= configuration.rearmFraction {
                    track.armed = true
                }

                let drop = previous.fraction - observation.fraction
                let scheduledPassed = previous.resetDate.map {
                    $0 <= now.addingTimeInterval(configuration.scheduledTolerance)
                } ?? false

                if scheduledPassed, previous.fraction >= 0.15, observation.fraction <= 0.15, drop >= 0.10 {
                    let (signal, event) = scheduledReset(
                        snapshot: snapshot,
                        window: window,
                        previous: previous,
                        current: observation
                    )
                    signals.append(signal)
                    events.append(event)
                    track.armed = true
                } else if track.armed,
                          let previousResetDate = previous.resetDate,
                          previousResetDate.timeIntervalSince(now) >= configuration.minimumEarlyLead {
                    let clean = previous.fraction >= configuration.cleanResetFloor
                        && observation.fraction <= configuration.cleanResetCeiling
                        && drop >= configuration.minimumDrop
                    let strong = previous.fraction >= configuration.strongRecoveryFloor
                        && drop >= configuration.strongRecoveryDrop
                        && observation.fraction <= configuration.strongRecoveryCeiling
                    let cooledDown = track.lastConfirmedAt.map {
                        now.timeIntervalSince($0) >= configuration.perWindowCooldown
                    } ?? true

                    if (clean || strong) && cooledDown {
                        candidates.append(
                            WindowCandidate(
                                key: key,
                                window: window,
                                period: period,
                                pending: PendingReset(
                                    observedAt: now,
                                    fromFraction: previous.fraction,
                                    toFraction: observation.fraction,
                                    previousResetDate: previousResetDate,
                                    newResetDate: observation.resetDate,
                                    resetDateJumped: resetDateJumped(
                                        from: previousResetDate,
                                        to: observation.resetDate,
                                        period: period
                                    ),
                                    needsUsageResumption: configuration.lockoutProneProviders.contains(snapshot.providerID)
                                )
                            )
                        )
                    }
                }
            }

            track.observations.append(observation)
            if track.observations.count > configuration.maxObservations {
                track.observations.removeFirst(track.observations.count - configuration.maxObservations)
            }
            state.windows[key] = track
        }

        // 3. Resolve this sweep's candidates.
        let redeemedNow = creditOutcome.redeemedNow
        let siblingCount = candidates.count + confirmations.count
        for candidate in candidates {
            let isShort = candidate.period <= configuration.shortWindowMaximumPeriod
            if isShort && siblingCount < configuration.providerWideMinimumWindows && !redeemedNow {
                continue
            }
            if redeemedNow {
                // Provider-reported corroboration: no need to wait a sweep.
                confirmations.append(
                    WindowConfirmation(
                        key: candidate.key,
                        window: candidate.window,
                        pending: candidate.pending,
                        period: candidate.period,
                        confirmedAt: now,
                        resetDateJumped: candidate.pending.resetDateJumped
                    )
                )
            } else if var track = state.windows[candidate.key] {
                // A sibling dropping alongside is corroboration enough to
                // skip the lockout guard: a lockout empties one meter, a
                // celebration empties them all.
                let pending = candidate.pending
                track.pending = PendingReset(
                    observedAt: pending.observedAt,
                    fromFraction: pending.fromFraction,
                    toFraction: pending.toFraction,
                    previousResetDate: pending.previousResetDate,
                    newResetDate: pending.newResetDate,
                    resetDateJumped: pending.resetDateJumped,
                    needsUsageResumption: pending.needsUsageResumption
                        && siblingCount < configuration.providerWideMinimumWindows
                )
                state.windows[candidate.key] = track
            }
        }

        // 4. Classify and emit the confirmed resets.
        let confirmedCount = confirmations.count
        let kind: QuotaResetKind
        if redeemedNow {
            kind = .bankedRedeemed
        } else if confirmedCount >= configuration.providerWideMinimumWindows {
            kind = .providerWide
        } else {
            kind = .gifted
        }

        for confirmation in confirmations {
            let isShort = confirmation.period <= configuration.shortWindowMaximumPeriod
            if isShort && kind == .gifted {
                // A five-hour window on its own: nothing to report, and
                // nothing to disarm.
                continue
            }
            guard var track = state.windows[confirmation.key] else { continue }
            track.lastConfirmedAt = confirmation.confirmedAt
            track.armed = false
            state.windows[confirmation.key] = track

            let (signal, event) = confirmedReset(
                snapshot: snapshot,
                confirmation: confirmation,
                kind: kind,
                siblingCount: confirmedCount
            )
            signals.append(signal)
            events.append(event)
        }

        return Outcome(state: state, signals: signals, events: events)
    }

    // MARK: Credits

    private struct CreditOutcome {
        let signals: [QuotaSignal]
        let events: [QuotaResetEvent]
        let redeemedNow: Bool
    }

    private func observeCredits(
        _ snapshot: QuotaSnapshot,
        state: inout ProviderState,
        now: Date
    ) -> CreditOutcome {
        guard let summary = snapshot.resetCredits else {
            return CreditOutcome(signals: [], events: [], redeemedNow: false)
        }

        var signals: [QuotaSignal] = []
        var events: [QuotaResetEvent] = []
        var redeemedNow = false
        let historyIDs = summary.history.map(\.id)

        guard var track = state.credits else {
            // First sighting: nothing to diff against, but an already-banked
            // reset is worth announcing.
            var fresh = CreditTrack(
                lastAvailableCount: summary.availableCount,
                seenEventIDs: Array(historyIDs.prefix(200)),
                announcedAvailableAt: nil,
                announcedExpiringAt: nil,
                lastRedeemedAt: nil
            )
            if summary.availableCount > 0 {
                fresh.announcedAvailableAt = now
                fresh.announcedExpiringAt = isExpiringSoon(summary, now: now) ? now : nil
                signals.append(availableSignal(snapshot: snapshot, summary: summary, detectedAt: now, now: now))
            }
            state.credits = fresh
            return CreditOutcome(signals: signals, events: events, redeemedNow: false)
        }

        let seen = Set(track.seenEventIDs)
        let newEvents = summary.history.filter { !seen.contains($0.id) }
        let recentCutoff = now.addingTimeInterval(-24 * 60 * 60)
        let usedEventNow = newEvents.contains { $0.kind == .used && $0.occurredAt >= recentCutoff }
        let grantedEventNow = newEvents.contains {
            $0.kind == .granted && $0.occurredAt >= recentCutoff
                && $0.occurredAt > (track.announcedAvailableAt ?? .distantPast)
        }

        if summary.availableCount < track.lastAvailableCount || usedEventNow {
            redeemedNow = true
            track.lastRedeemedAt = now
            let usedAt = newEvents.filter { $0.kind == .used }.map(\.occurredAt).max() ?? now
            let remaining = summary.availableCount
            let message = remaining > 0
                ? "A banked usage-limit reset was redeemed. \(remaining == 1 ? "1 reset" : "\(remaining) resets") still banked."
                : "A banked usage-limit reset was redeemed."
            signals.append(
                QuotaSignal(
                    kind: .unexpectedRecovery,
                    title: "Banked reset redeemed",
                    message: message,
                    severity: .info,
                    confidence: 0.98,
                    windowLabel: Self.bankedResetWindowLabel,
                    detectedAt: usedAt,
                    resetKind: .bankedRedeemed
                )
            )
            events.append(
                QuotaResetEvent(
                    id: "credit|\(snapshot.accountKey.rawValue)|used|\(Int(usedAt.timeIntervalSince1970))",
                    providerID: snapshot.providerID,
                    accountSlot: snapshot.accountSlot,
                    windowLabel: nil,
                    kind: .bankedRedeemed,
                    occurredAt: usedAt,
                    confidence: 0.98,
                    source: .providerReported,
                    summary: "Banked reset redeemed"
                )
            )
        }

        if summary.availableCount > 0 {
            let newlyAvailable = summary.availableCount > track.lastAvailableCount
                || grantedEventNow
                || track.announcedAvailableAt == nil
            if newlyAvailable {
                track.announcedAvailableAt = now
                // A grant first seen inside the reminder window has already
                // announced its expiry. Do not announce it again next sweep.
                track.announcedExpiringAt = isExpiringSoon(summary, now: now) ? now : nil
                signals.append(availableSignal(snapshot: snapshot, summary: summary, detectedAt: now, now: now))
            } else if let expiry = summary.nearestExpiry,
                      expiry.timeIntervalSince(now) <= configuration.expiringSoonLead,
                      expiry > now,
                      track.announcedExpiringAt == nil {
                track.announcedExpiringAt = now
                signals.append(availableSignal(snapshot: snapshot, summary: summary, detectedAt: now, now: now))
            } else if let announcedAt = track.announcedExpiringAt ?? track.announcedAvailableAt {
                // Keep the standing notice visible without re-alerting.
                signals.append(availableSignal(snapshot: snapshot, summary: summary, detectedAt: announcedAt, now: now))
            }
        } else {
            track.announcedAvailableAt = nil
            track.announcedExpiringAt = nil
        }

        track.lastAvailableCount = summary.availableCount
        track.seenEventIDs = Array((historyIDs + track.seenEventIDs).reduce(into: [String]()) { list, id in
            if !list.contains(id) { list.append(id) }
        }.prefix(200))
        state.credits = track

        return CreditOutcome(signals: signals, events: events, redeemedNow: redeemedNow)
    }

    private func isExpiringSoon(_ summary: QuotaResetCreditSummary, now: Date) -> Bool {
        guard let expiry = summary.nearestExpiry else { return false }
        return expiry > now && expiry.timeIntervalSince(now) <= configuration.expiringSoonLead
    }

    private func availableSignal(
        snapshot: QuotaSnapshot,
        summary: QuotaResetCreditSummary,
        detectedAt: Date,
        now: Date
    ) -> QuotaSignal {
        var message = summary.availableCount == 1
            ? "1 usage-limit reset is banked"
            : "\(summary.availableCount) usage-limit resets are banked"
        if let expiry = summary.nearestExpiry {
            let remaining = expiry.timeIntervalSince(now)
            if remaining > 0 {
                message += " and expires in \(compactDurationString(remaining)) (\(Self.clockString(expiry)))"
            } else {
                message += " and is expiring"
            }
        }
        message += "."
        if let hint = summary.redeemHint, !hint.isEmpty {
            message += " \(hint)"
        }
        let expiringSoon = summary.nearestExpiry.map { $0.timeIntervalSince(now) <= configuration.expiringSoonLead } ?? false
        return QuotaSignal(
            kind: .unexpectedRecovery,
            title: expiringSoon ? "Banked reset expiring soon" : "Usage-limit reset available",
            message: message,
            severity: expiringSoon ? .warning : .info,
            confidence: nil,
            windowLabel: Self.bankedResetWindowLabel,
            detectedAt: detectedAt,
            resetKind: .bankedAvailable
        )
    }

    // MARK: Windows

    private struct WindowCandidate {
        let key: String
        let window: QuotaWindow
        let period: TimeInterval
        let pending: PendingReset
    }

    private struct WindowConfirmation {
        let key: String
        let window: QuotaWindow
        let pending: PendingReset
        let period: TimeInterval
        let confirmedAt: Date
        let resetDateJumped: Bool
    }

    private func resetDateJumped(from previous: Date?, to current: Date?, period: TimeInterval) -> Bool {
        guard let previous, let current else { return false }
        return current.timeIntervalSince(previous) >= configuration.resetDateJumpShare * period
    }

    private func scheduledReset(
        snapshot: QuotaSnapshot,
        window: QuotaWindow,
        previous: Observation,
        current: Observation
    ) -> (QuotaSignal, QuotaResetEvent) {
        let previousPercent = Self.percent(previous.fraction)
        let currentPercent = Self.percent(current.fraction)
        var message = "Quota refreshed from \(previousPercent)% to \(currentPercent)%."
        if let next = current.resetDate, next > current.at {
            message += " Next reset in \(compactDurationString(next.timeIntervalSince(current.at)))."
        }
        let signal = QuotaSignal(
            kind: .scheduledReset,
            title: "\(window.label) reset",
            message: message,
            severity: .info,
            confidence: 0.95,
            windowLabel: window.label,
            detectedAt: current.at,
            resetKind: .scheduled
        )
        let event = QuotaResetEvent(
            id: Self.eventID(snapshot.accountKey, window.label, .scheduled, current.at),
            providerID: snapshot.providerID,
            accountSlot: snapshot.accountSlot,
            windowLabel: window.label,
            kind: .scheduled,
            occurredAt: current.at,
            fromFraction: previous.fraction,
            toFraction: current.fraction,
            previousResetDate: previous.resetDate,
            newResetDate: current.resetDate,
            confidence: 0.95,
            source: .inferred,
            summary: "\(window.label) reset on schedule (\(previousPercent)% → \(currentPercent)%)"
        )
        return (signal, event)
    }

    private func confirmedReset(
        snapshot: QuotaSnapshot,
        confirmation: WindowConfirmation,
        kind: QuotaResetKind,
        siblingCount: Int
    ) -> (QuotaSignal, QuotaResetEvent) {
        let pending = confirmation.pending
        let window = confirmation.window
        let fromPercent = Self.percent(pending.fromFraction)
        let toPercent = Self.percent(pending.toFraction)
        let lead = pending.previousResetDate.map { $0.timeIntervalSince(pending.observedAt) } ?? 0
        let leadText = lead > 0 ? compactDurationString(lead) : "shortly"

        let confidence: Double
        let title: String
        var message: String
        switch kind {
        case .bankedRedeemed:
            confidence = 0.98
            title = "Banked reset redeemed"
            message = "\(window.label) restarted at \(toPercent)% after a banked reset was redeemed (was \(fromPercent)%, \(leadText) before the scheduled reset)."
        case .providerWide:
            confidence = 0.92
            title = "Provider-wide quota reset"
            let others = siblingCount - 1
            let siblingText = others == 1 ? "1 other \(snapshot.displayName) window" : "\(others) other \(snapshot.displayName) windows"
            message = "\(window.label) fell from \(fromPercent)% to \(toPercent)% together with \(siblingText), \(leadText) before the scheduled reset."
        default:
            confidence = confirmation.resetDateJumped ? 0.90 : 0.75
            title = "Usage window reset early"
            message = "\(window.label) reset early: \(fromPercent)% to \(toPercent)%, \(leadText) before the scheduled reset."
        }
        if confirmation.resetDateJumped, let newReset = pending.newResetDate {
            message += " The window restarted; next reset \(Self.dateString(newReset))."
        }

        let signal = QuotaSignal(
            kind: .unexpectedRecovery,
            title: title,
            message: message,
            severity: confidence >= 0.8 ? .warning : .info,
            confidence: confidence,
            windowLabel: window.label,
            detectedAt: confirmation.confirmedAt,
            resetKind: kind
        )
        let event = QuotaResetEvent(
            id: Self.eventID(snapshot.accountKey, window.label, kind, pending.observedAt),
            providerID: snapshot.providerID,
            accountSlot: snapshot.accountSlot,
            windowLabel: window.label,
            kind: kind,
            occurredAt: pending.observedAt,
            fromFraction: pending.fromFraction,
            toFraction: pending.toFraction,
            previousResetDate: pending.previousResetDate,
            newResetDate: pending.newResetDate,
            confidence: confidence,
            source: kind == .bankedRedeemed ? .providerReported : .inferred,
            summary: "\(window.label) \(fromPercent)% → \(toPercent)%"
        )
        return (signal, event)
    }

    // MARK: Helpers

    private struct WindowKey {
        let string: String

        init(window: QuotaWindow) {
            string = [
                window.label.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
                window.windowKind.rawValue,
                window.unit.lowercased()
            ].joined(separator: "|")
        }
    }

    /// Keyed by account, not provider: two accounts of one provider resetting
    /// in the same second are two events, and the primary account's ids are
    /// exactly what they were before accounts existed.
    private static func eventID(_ account: ProviderAccountKey, _ label: String, _ kind: QuotaResetKind, _ at: Date) -> String {
        "\(account.rawValue)|\(label.lowercased())|\(kind.rawValue)|\(Int(at.timeIntervalSince1970))"
    }

    private static func percent(_ fraction: Double) -> Int {
        Int((min(max(fraction, 0), 1) * 100).rounded())
    }

    private static func clockString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    private static func dateString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}

// MARK: - Persistence

/// Detector state per provider, kept in the app group so a relaunch does not
/// forget which drops are pending or which windows are cooling down.
public struct QuotaResetDetectorStateStore {
    private let defaults: UserDefaults
    private let key: String
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(defaults: UserDefaults, key: String = "quotaResetDetector.state.v1") {
        self.defaults = defaults
        self.key = key
        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
    }

    public func state(for providerID: ProviderID) -> QuotaResetDetector.ProviderState? {
        state(for: .primary(providerID))
    }

    public func save(_ state: QuotaResetDetector.ProviderState, for providerID: ProviderID) {
        save(state, for: .primary(providerID))
    }

    /// Detector state is per account: the primary account keeps the key the
    /// provider always had, so nothing pending is forgotten on upgrade.
    public func state(for account: ProviderAccountKey) -> QuotaResetDetector.ProviderState? {
        loadAll()[account.rawValue]
    }

    public func save(_ state: QuotaResetDetector.ProviderState, for account: ProviderAccountKey) {
        var all = loadAll()
        all[account.rawValue] = state
        guard let data = try? encoder.encode(all) else { return }
        defaults.set(data, forKey: key)
    }

    /// Forgets one account's trail. Used when the slot changes hands: the new
    /// account's first reading must be a baseline, never a "drop".
    public func clear(account: ProviderAccountKey) {
        var all = loadAll()
        guard all.removeValue(forKey: account.rawValue) != nil else { return }
        guard let data = try? encoder.encode(all) else { return }
        defaults.set(data, forKey: key)
    }

    public func clear() {
        defaults.removeObject(forKey: key)
    }

    private func loadAll() -> [String: QuotaResetDetector.ProviderState] {
        guard let data = defaults.data(forKey: key),
              let decoded = try? decoder.decode([String: QuotaResetDetector.ProviderState].self, from: data) else {
            return [:]
        }
        return decoded
    }
}

/// Rolling ledger of confirmed resets, shared by the dashboard tally and the
/// provider detail view.
@MainActor
public final class QuotaResetLedgerStore: ObservableObject {
    public static let shared = QuotaResetLedgerStore()

    @Published public private(set) var events: [QuotaResetEvent] = []

    private let defaults: UserDefaults
    private let key: String
    private let retention: TimeInterval
    private let maxEntries: Int
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(
        defaults: UserDefaults? = nil,
        key: String = "quotaResetLedger.v1",
        retention: TimeInterval = 60 * 24 * 60 * 60,
        maxEntries: Int = 400
    ) {
        self.defaults = defaults
            ?? UserDefaults(suiteName: "group.com.chrisizatt.LLMUsageCounter")
            ?? .standard
        self.key = key
        self.retention = retention
        self.maxEntries = maxEntries
        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        events = load()
    }

    public func record(_ newEvents: [QuotaResetEvent], now: Date = Date()) {
        guard !newEvents.isEmpty else { return }
        var merged = events
        var ids = Set(merged.map(\.id))
        for event in newEvents where ids.insert(event.id).inserted {
            merged.append(event)
        }
        let cutoff = now.addingTimeInterval(-retention)
        merged = Array(
            merged
                .filter { $0.occurredAt >= cutoff }
                .sorted { $0.occurredAt > $1.occurredAt }
                .prefix(maxEntries)
        )
        guard merged != events else { return }
        events = merged
        if let data = try? encoder.encode(merged) {
            defaults.set(data, forKey: key)
        }
    }

    /// Every account of the provider.
    public func events(for providerID: ProviderID) -> [QuotaResetEvent] {
        events.filter { $0.providerID == providerID }
    }

    public func events(for account: ProviderAccountKey) -> [QuotaResetEvent] {
        events.filter { $0.accountKey == account }
    }

    /// Resets the user did not schedule or trigger, per provider, since `since`.
    public func independentResetCounts(since: Date) -> [ProviderID: Int] {
        Dictionary(
            grouping: events.filter { $0.occurredAt >= since && $0.kind.isIndependentReset },
            by: \.providerID
        )
        .mapValues { $0.count }
    }

    private func load() -> [QuotaResetEvent] {
        guard let data = defaults.data(forKey: key),
              let decoded = try? decoder.decode([QuotaResetEvent].self, from: data) else {
            return []
        }
        return decoded.sorted { $0.occurredAt > $1.occurredAt }
    }
}
