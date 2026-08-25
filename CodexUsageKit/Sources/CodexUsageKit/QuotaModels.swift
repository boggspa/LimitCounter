import Foundation

public enum QuotaProviderID: String, Codable, Hashable, Sendable {
    case codex
    case codexTelemetry
    case qwen
    case xiaomiMimo
}

public enum QuotaWindowKind: String, Codable, Hashable, Sendable {
    case session
    case daily
    case weekly
    case monthly
    case yearly
    case sliding
    case project
    case custom
}

public enum QuotaPaceState: String, Codable, Hashable, Sendable {
    case ahead
    case onTrack
    case behind

    public var title: String {
        switch self {
        case .ahead:
            return "Ahead"
        case .onTrack:
            return "On track"
        case .behind:
            return "Behind"
        }
    }
}

public struct QuotaPace: Codable, Equatable, Hashable, Sendable {
    public let expectedFraction: Double
    public let actualFraction: Double
    public let deltaFraction: Double
    public let state: QuotaPaceState

    public var shouldSurface: Bool {
        true
    }

    public var compactStatusText: String {
        let value = max(1, Int((abs(deltaFraction) * 100).rounded()))
        return "\(state.title) \(value)%"
    }
}

public struct QuotaWindow: Codable, Identifiable, Equatable, Hashable, Sendable {
    public let id: UUID
    public let label: String
    public let windowKind: QuotaWindowKind
    public let used: Double
    public let total: Double?
    public let resetDate: Date?
    public let unit: String
    public let subtitle: String?

    public var fractionUsed: Double {
        if let resetDate, resetDate < Date() {
            return 0
        }
        guard let total, total > 0 else { return 0 }
        return min(used / total, 1.0)
    }

    public var hasExplicitLimit: Bool {
        total != nil && total! > 0
    }

    public var percentageUsed: Int {
        Int((fractionUsed * 100).rounded())
    }

    public init(
        id: UUID = UUID(),
        label: String,
        windowKind: QuotaWindowKind,
        used: Double,
        total: Double? = nil,
        resetDate: Date? = nil,
        unit: String,
        subtitle: String? = nil
    ) {
        self.id = id
        self.label = label
        self.windowKind = windowKind
        self.used = used
        self.total = total
        self.resetDate = resetDate
        self.unit = unit
        self.subtitle = subtitle
    }

    public func pace(at date: Date = Date()) -> QuotaPace? {
        guard hasExplicitLimit, let total, total > 0 else { return nil }
        guard let resetDate, resetDate > date else { return nil }
        guard let duration = inferredPaceDuration(), duration > 0 else { return nil }

        let remaining = resetDate.timeIntervalSince(date)
        let elapsed = min(max(duration - remaining, 0), duration)
        let expectedFraction = min(max(elapsed / duration, 0), 1)

        let actualFraction = min(max(used / total, 0), 1)

        let delta = actualFraction - expectedFraction
        let tolerance = 0.02
        let state: QuotaPaceState
        if delta > tolerance {
            state = .behind
        } else if delta < -tolerance {
            state = .ahead
        } else {
            state = .onTrack
        }

        return QuotaPace(
            expectedFraction: expectedFraction,
            actualFraction: actualFraction,
            deltaFraction: delta,
            state: state
        )
    }

    private func inferredPaceDuration() -> TimeInterval? {
        let descriptor = "\(label) \(subtitle ?? "")".lowercased()

        if descriptor.contains("5h") || descriptor.contains("5-hour") || descriptor.contains("5 hour") || descriptor.contains("session") {
            return 5 * 60 * 60
        }

        if descriptor.contains("24h") || descriptor.contains("24-hour") || descriptor.contains("daily") {
            return 24 * 60 * 60
        }

        if descriptor.contains("7d") || descriptor.contains("7-day") || descriptor.contains("weekly") {
            return 7 * 24 * 60 * 60
        }

        switch windowKind {
        case .daily:
            return 24 * 60 * 60
        case .weekly:
            return 7 * 24 * 60 * 60
        case .monthly:
            return 30 * 24 * 60 * 60
        case .yearly:
            return 365 * 24 * 60 * 60
        case .session, .sliding, .project, .custom:
            return nil
        }
    }
}

public struct QuotaStat: Codable, Identifiable, Equatable, Hashable, Sendable {
    public let id: UUID
    public let label: String
    public let value: Double
    public let unit: String
    public let subtitle: String?

    public init(
        id: UUID = UUID(),
        label: String,
        value: Double,
        unit: String,
        subtitle: String? = nil
    ) {
        self.id = id
        self.label = label
        self.value = value
        self.unit = unit
        self.subtitle = subtitle
    }
}

public struct QuotaBalance: Codable, Identifiable, Equatable, Hashable, Sendable {
    public let id: UUID
    public let label: String
    public let amount: Double
    public let unit: String
    public let subtitle: String?
    public let resetDate: Date?

    public init(
        id: UUID = UUID(),
        label: String,
        amount: Double,
        unit: String,
        subtitle: String? = nil,
        resetDate: Date? = nil
    ) {
        self.id = id
        self.label = label
        self.amount = amount
        self.unit = unit
        self.subtitle = subtitle
        self.resetDate = resetDate
    }
}

public enum QuotaSignalKind: String, Codable, Hashable, Sendable {
    case unexpectedRecovery
}

public enum QuotaSignalSeverity: String, Codable, Hashable, Sendable {
    case info
    case warning
    case critical
}

public struct QuotaSignal: Codable, Identifiable, Equatable, Hashable, Sendable {
    public let id: UUID
    public let kind: QuotaSignalKind
    public let title: String
    public let message: String
    public let severity: QuotaSignalSeverity
    public let confidence: Double?
    public let windowLabel: String?
    public let detectedAt: Date

    public init(
        id: UUID = UUID(),
        kind: QuotaSignalKind,
        title: String,
        message: String,
        severity: QuotaSignalSeverity,
        confidence: Double? = nil,
        windowLabel: String? = nil,
        detectedAt: Date = Date()
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.message = message
        self.severity = severity
        self.confidence = confidence
        self.windowLabel = windowLabel
        self.detectedAt = detectedAt
    }
}

public struct UsageEvent: Codable, Identifiable, Equatable, Hashable, Sendable {
    public let id: UUID
    public let timestamp: Date
    public let tokens: Double?
    public let model: String?
    public let type: EventType

    public enum EventType: String, Codable, Hashable, Sendable {
        case message
        case telemetry
        case activity
        case bucket
    }

    public init(
        id: UUID = UUID(),
        timestamp: Date,
        tokens: Double? = nil,
        model: String? = nil,
        type: EventType = .message
    ) {
        self.id = id
        self.timestamp = timestamp
        self.tokens = tokens
        self.model = model
        self.type = type
    }
}

public enum ProviderFetchState: String, Codable, Hashable, Sendable {
    case success
    case error
    case notConfigured

    public var isHealthy: Bool {
        self == .success
    }
}

public struct QuotaSnapshot: Codable, Identifiable, Equatable, Hashable, Sendable {
    public let id: UUID
    public let providerID: QuotaProviderID
    public let displayName: String
    public let planName: String?
    public let windows: [QuotaWindow]
    public let stats: [QuotaStat]
    public let balances: [QuotaBalance]
    public let signals: [QuotaSignal]
    public let events: [UsageEvent]
    public let fetchState: ProviderFetchState
    public let fetchedAt: Date

    public var hasContent: Bool {
        !windows.isEmpty || !stats.isEmpty || !balances.isEmpty || !signals.isEmpty || !events.isEmpty
    }

    public var primaryWindow: QuotaWindow? {
        windows.first
    }

    public init(
        id: UUID = UUID(),
        providerID: QuotaProviderID,
        displayName: String,
        planName: String? = nil,
        windows: [QuotaWindow] = [],
        stats: [QuotaStat] = [],
        balances: [QuotaBalance] = [],
        signals: [QuotaSignal] = [],
        events: [UsageEvent] = [],
        fetchState: ProviderFetchState = .success,
        fetchedAt: Date = Date()
    ) {
        self.id = id
        self.providerID = providerID
        self.displayName = displayName
        self.planName = planName
        self.windows = windows
        self.stats = stats
        self.balances = balances
        self.signals = signals
        self.events = events
        self.fetchState = fetchState
        self.fetchedAt = fetchedAt
    }

    public func withSignals(_ newSignals: [QuotaSignal]) -> QuotaSnapshot {
        QuotaSnapshot(
            id: id,
            providerID: providerID,
            displayName: displayName,
            planName: planName,
            windows: windows,
            stats: stats,
            balances: balances,
            signals: newSignals,
            events: events,
            fetchState: fetchState,
            fetchedAt: fetchedAt
        )
    }

    public func withEvents(_ newEvents: [UsageEvent]) -> QuotaSnapshot {
        QuotaSnapshot(
            id: id,
            providerID: providerID,
            displayName: displayName,
            planName: planName,
            windows: windows,
            stats: stats,
            balances: balances,
            signals: signals,
            events: newEvents,
            fetchState: fetchState,
            fetchedAt: fetchedAt
        )
    }
}

public extension Date {
    var codexUsageCountdownString: String {
        let interval = timeIntervalSinceNow
        guard interval > 0 else { return "now" }
        if interval < 60 { return "in <1m" }

        let totalMinutes = Int(interval / 60)
        let days = totalMinutes / 1_440
        let hours = (totalMinutes % 1_440) / 60
        let minutes = totalMinutes % 60

        var parts: [String] = []
        if days > 0 {
            parts.append("\(days)d")
        }
        if hours > 0 || days > 0 {
            parts.append("\(hours)h")
        }
        if minutes > 0 || parts.isEmpty {
            parts.append("\(minutes)m")
        }

        return "in \(parts.joined(separator: " "))"
    }
}
