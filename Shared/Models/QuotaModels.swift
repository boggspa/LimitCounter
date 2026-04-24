import Foundation
import WidgetKit
#if os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

// MARK: - Provider Identity

public enum ProviderID: String, Codable, CaseIterable, Identifiable, Hashable {
    case claude
    case openai
    case chatgpt
    case codexTelemetry
    case windsurf
    case cursor
    case gemini
    case heatmap

    public static var userFacingCases: [ProviderID] {
        allCases.filter { $0.isUserFacingInProviderLists }
    }

    public var id: String { rawValue }

    public nonisolated var isUserFacingInProviderLists: Bool {
        self != .codexTelemetry && self != .heatmap
    }

    public var displayName: String {
        switch self {
        case .claude:   return "Claude"
        case .openai:   return "Codex"
        case .chatgpt:  return "ChatGPT"
        case .codexTelemetry:
            return "Codex Telemetry"
        case .windsurf: return "Windsurf"
        case .cursor:   return "Cursor"
        case .gemini:   return "Gemini"
        case .heatmap:  return "Activity Heatmap"
        }
    }

    public var snapshotDisplayName: String {
        switch self {
        case .openai:
            return "Codex"
        case .chatgpt:
            return "ChatGPT"
        case .codexTelemetry:
            return "Codex Telemetry"
        case .claude, .windsurf, .cursor, .gemini, .heatmap:
            return displayName
        }
    }

    public var iconName: String {
        switch self {
        case .claude:   return "brain.head.profile.fill"
        case .openai:   return "terminal.fill"
        case .chatgpt:  return "bubble.left.and.bubble.right.fill"
        case .codexTelemetry:
            return "cpu.fill"
        case .windsurf: return "wave.3.right"
        case .cursor:   return "cursorarrow.rays"
        case .gemini:   return "sparkles"
        case .heatmap:  return "calendar.badge.clock"
        }
    }

    public var accentColorHex: String {
        switch self {
        case .claude:   return "#F59E0B" // Amber
        case .openai:   return "#6366F1" // Indigo
        case .chatgpt:  return "#10B981" // Emerald/OpenAI Green
        case .codexTelemetry:
            return "#6366F1" // Indigo
        case .windsurf: return "#2D5AB2" // Deep Windsurf Blue
        case .cursor:   return "#EAB308" // Gold
        case .gemini:   return "#4285F4" // Google Blue
        case .heatmap:  return "#5B8AF5" // App Blue
        }
    }

    public var bundledLogoAssetName: String {
        switch self {
        case .claude:
            return "ProviderClaudeLogo"
        case .openai:
            return "ProviderCodexLogo"
        case .chatgpt:
            return "ProviderChatGPTLogo"
        case .codexTelemetry:
            return "ProviderCodexLogo"
        case .windsurf:
            return "ProviderWindsurfLogo"
        case .cursor:
            return "ProviderCursorLogo"
        case .gemini:
            return "ProviderGeminiLogo"
        case .heatmap:
            return ""
        }
    }

    public var integrationStatus: ProviderIntegrationStatus {
        switch self {
        case .chatgpt, .codexTelemetry:
            return .prototype
        case .claude, .openai, .windsurf, .cursor, .gemini:
            return .session
        case .heatmap:
            return .session
        }
    }

    public var configurationTitle: String {
        switch self {
        case .claude:
            return "Claude Code local session"
        case .openai:
            return "Codex ChatGPT session"
        case .chatgpt:
            return "ChatGPT local desktop cache"
        case .codexTelemetry:
            return "Codex local telemetry folder"
        case .windsurf:
            return "Windsurf local quota cache"
        case .cursor:
            return "Cursor web session and local state"
        case .gemini:
            return "Gemini CLI local session"
        case .heatmap:
            return "Activity Heatmap"
        }
    }

    public var configurationDescription: String {
        switch self {
        case .claude:
            return "Reads local Claude Code transcripts under `~/.claude` and turns them into token-based usage snapshots."
        case .openai:
            return "Uses a ChatGPT-authorized Codex session to read the private 5-hour and 7-day usage surface."
        case .chatgpt:
            return "Reads the local ChatGPT macOS app cache and turns recent conversation activity into local usage-style snapshots."
        case .codexTelemetry:
            return "Reads the local Codex store you point it at and turns event counts and token totals into snapshots."
        case .windsurf:
            return "Reads the local Windsurf quota cache or a user-provided export and normalizes the quota windows."
        case .cursor:
            return "Uses a Cursor web session or dashboard token for live usage, and can read local Cursor state for cached account metadata."
        case .gemini:
            return "Reads local Gemini CLI history and metadata from `~/.gemini` and turns it into usage snapshots."
        case .heatmap:
            return "Aggregated usage activity across all enabled services."
        }
    }

    public var primaryCredentialLabel: String {
        switch self {
        case .claude:
            return "Claude Code data root"
        case .openai:
            return "Codex session access token"
        case .chatgpt:
            return "ChatGPT app data folder"
        case .codexTelemetry:
            return "Codex telemetry folder"
        case .windsurf:
            return "Windsurf access token"
        case .cursor:
            return "Cursor web session cookie or dashboard token"
        case .gemini:
            return "Gemini CLI data root"
        case .heatmap:
            return ""
        }
    }

    public var secondaryCredentialLabel: String? {
        switch self {
        case .claude, .chatgpt, .gemini, .codexTelemetry, .heatmap:
            return nil
        case .openai:
            return "ChatGPT account ID"
        case .windsurf:
            return "Team ID (optional)"
        case .cursor:
            return "Team slug or org ID"
        }
    }

    public var securityNote: String {
        switch self {
        case .openai:
            return "Use only a Codex session you intentionally import or paste from an account you control."
        case .chatgpt:
            return "Use only the local ChatGPT desktop app data folder you intentionally select from an account you control."
        case .codexTelemetry:
            return "Use only local Codex log folders or exports you intentionally point the app at."
        case .claude:
            return "Use only Claude Code logs or settings you intentionally export or select yourself."
        case .cursor:
            return "Use only a Cursor web credential you intentionally import. Local Cursor state is read only for cached metadata."
        case .windsurf:
            return "Use only credentials the user intentionally enters or exports."
        case .gemini:
            return "Use only local Gemini CLI log folders or history you intentionally point the app at."
        case .heatmap:
            return "Aggregates only locally available data."
        }
    }
}

#if os(macOS)
public struct AppIconCandidate {
    let bundleIdentifier: String
    let applicationNames: [String]
}

public extension ProviderID {
    var appIconImage: NSImage? {
        for candidate in appIconCandidates {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: candidate.bundleIdentifier) {
                return NSWorkspace.shared.icon(forFile: url.path)
            }
        }

        let fileManager = FileManager.default
        let searchRoots: [URL] = [
            URL(fileURLWithPath: "/Applications"),
            fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Applications")
        ]

        for root in searchRoots {
            for candidate in appIconCandidates {
                for appName in candidate.applicationNames {
                    let appURL = root.appendingPathComponent(appName)
                    if fileManager.fileExists(atPath: appURL.path) {
                        return NSWorkspace.shared.icon(forFile: appURL.path)
                    }
                }
            }
        }

        return nil
    }

    private var appIconCandidates: [AppIconCandidate] {
        switch self {
        case .claude:
            return [
                AppIconCandidate(bundleIdentifier: "com.anthropic.Claude", applicationNames: ["Claude.app", "Claude Code.app"]),
                AppIconCandidate(bundleIdentifier: "com.anthropic.claude", applicationNames: ["Claude.app", "Claude Code.app"])
            ]
        case .openai:
            return [
                AppIconCandidate(bundleIdentifier: "com.openai.codex", applicationNames: ["Codex.app"]),
                AppIconCandidate(bundleIdentifier: "com.openai.chat", applicationNames: ["ChatGPT.app"])
            ]
        case .chatgpt:
            return [
                AppIconCandidate(bundleIdentifier: "com.openai.chat", applicationNames: ["ChatGPT.app"])
            ]
        case .windsurf:
            return [
                AppIconCandidate(bundleIdentifier: "com.codeium.windsurf", applicationNames: ["Windsurf.app"]),
                AppIconCandidate(bundleIdentifier: "com.windsurf", applicationNames: ["Windsurf.app"])
            ]
        case .cursor:
            return [
                AppIconCandidate(bundleIdentifier: "com.cursor.Cursor", applicationNames: ["Cursor.app"]),
                AppIconCandidate(bundleIdentifier: "com.anysphere.cursor", applicationNames: ["Cursor.app"])
            ]
        case .gemini, .codexTelemetry, .heatmap:
            return []
        }
    }
}
#elseif canImport(UIKit)
public extension ProviderID {
    var bundledLogoImage: UIImage? {
        UIImage(named: bundledLogoAssetName)
    }
}
#endif

public enum ProviderIntegrationStatus: String, Codable, Hashable {
    case prototype
    case session
    case enterprise

    public var badgeTitle: String {
        switch self {
        case .prototype: return "Prototype"
        case .session:   return "Local Session"
        case .enterprise: return "Enterprise"
        }
    }
}

// MARK: - Quota Window Kind

public enum QuotaWindowKind: String, Codable, Hashable {
    case session
    case daily
    case weekly
    case monthly
    case yearly
    case sliding
    case project
    case custom
}

// MARK: - Quota Window

public struct QuotaWindow: Codable, Identifiable, Equatable, Hashable {
    public let id: UUID
    public let label: String
    public let windowKind: QuotaWindowKind
    public let used: Double
    public let total: Double?
    public let resetDate: Date?        // nil = rolling or unavailable
    public let unit: String            // "tokens", "requests", "USD"
    public let subtitle: String?       // optional extra context line

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

    public var displayUnit: String {
        switch unit.lowercased() {
        case "tokens", "tok":
            return "tokens"
        case "requests", "req":
            return "requests"
        case "usd", "$":
            return "$"
        default:
            return unit
        }
    }

    public var measurementSummary: String {
        if let resetDate, resetDate < Date() {
            if let total {
                return "0 / \(total.compactString) \(displayUnit)"
            }
            return formattedMetricValue(0, unit: unit)
        }

        let usedText = used.compactString
        if let total {
            return "\(usedText) / \(total.compactString) \(displayUnit)"
        }
        return formattedMetricValue(used, unit: unit)
    }

    public var leadingValueText: String {
        if let resetDate, resetDate < Date() {
            return hasExplicitLimit ? "0%" : formattedMetricValue(0, unit: unit)
        }
        return hasExplicitLimit ? "\(percentageUsed)%" : formattedMetricValue(used, unit: unit)
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
}

// MARK: - Supplemental Stats

public struct QuotaStat: Codable, Identifiable, Equatable, Hashable {
    public let id: UUID
    public let label: String
    public let value: Double
    public let unit: String
    public let subtitle: String?

    public var valueText: String {
        formattedMetricValue(value, unit: unit)
    }

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

public struct QuotaBalance: Codable, Identifiable, Equatable, Hashable {
    public let id: UUID
    public let label: String
    public let amount: Double
    public let unit: String
    public let subtitle: String?
    public let resetDate: Date?

    public var valueText: String {
        formattedMetricValue(amount, unit: unit)
    }

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

// MARK: - Recent Signals

public enum QuotaSignalKind: String, Codable, Hashable {
    case unexpectedRecovery
}

public enum QuotaSignalSeverity: String, Codable, Hashable {
    case info
    case warning
    case critical
}

public struct QuotaSignal: Codable, Identifiable, Equatable, Hashable {
    public let id: UUID
    public let kind: QuotaSignalKind
    public let title: String
    public let message: String
    public let severity: QuotaSignalSeverity
    public let confidence: Double?
    public let windowLabel: String?
    public let detectedAt: Date

    public var confidenceText: String? {
        guard let confidence else { return nil }
        return "\(Int((confidence * 100).rounded()))% confidence"
    }

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

// MARK: - Usage Event (Heatmap source)

public struct UsageEvent: Codable, Identifiable, Equatable, Hashable {
    public let id: UUID
    public let timestamp: Date
    public let tokens: Double?
    public let model: String?
    public let type: EventType

    public enum EventType: String, Codable, Hashable {
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

// MARK: - Snapshot

public enum ProviderFetchState: String, Codable, Hashable {
    case success
    case error
    case notConfigured

    public var isHealthy: Bool {
        self == .success
    }
}

public struct QuotaSnapshot: Codable, Identifiable, Equatable, Hashable {
    public let id: UUID
    public let providerID: ProviderID
    public let displayName: String
    public let planName: String?
    public let windows: [QuotaWindow]
    public let stats: [QuotaStat]
    public let balances: [QuotaBalance]
    public let signals: [QuotaSignal]
    public let events: [UsageEvent]
    public let fetchState: ProviderFetchState
    public let fetchedAt: Date

    public var statsSectionTitle: String? {
        if stats.isEmpty { return nil }

        if providerID == .openai {
            return "Token Usage"
        }

        if providerID == .codexTelemetry {
            return "Telemetry"
        }

        if providerID == .chatgpt {
            return "Local Activity"
        }

        if providerID == .windsurf {
            return "Plan & Workspace Metadata"
        }

        if providerID == .claude {
            return "Usage & Local Metadata"
        }

        if providerID == .cursor {
            return "Usage & Local Metadata"
        }

        if providerID == .gemini {
            return "CLI Session & Tokens"
        }

        return "Periodic Usage"
    }

    public var balancesSectionTitle: String? {
        guard !balances.isEmpty else { return nil }
        if providerID == .openai { return "Credits / Balance" }
        return "Extra Balance / Credits"
    }

    public var hasContent: Bool {
        !windows.isEmpty || !stats.isEmpty || !balances.isEmpty || !signals.isEmpty || !events.isEmpty
    }

    public var primaryWindow: QuotaWindow? {
        windows.first
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

    private enum CodingKeys: String, CodingKey {
        case id
        case providerID
        case displayName
        case planName
        case windows
        case stats
        case balances
        case signals
        case events
        case fetchState
        case fetchedAt
    }

    public init(
        id: UUID = UUID(),
        providerID: ProviderID,
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

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        providerID = try container.decode(ProviderID.self, forKey: .providerID)
        displayName = try container.decode(String.self, forKey: .displayName)
        planName = try container.decodeIfPresent(String.self, forKey: .planName)
        windows = try container.decodeIfPresent([QuotaWindow].self, forKey: .windows) ?? []
        stats = try container.decodeIfPresent([QuotaStat].self, forKey: .stats) ?? []
        balances = try container.decodeIfPresent([QuotaBalance].self, forKey: .balances) ?? []
        signals = try container.decodeIfPresent([QuotaSignal].self, forKey: .signals) ?? []
        events = try container.decodeIfPresent([UsageEvent].self, forKey: .events) ?? []

        // Resilient fetchState decoding
        if let stateString = try? container.decode(String.self, forKey: .fetchState) {
            fetchState = ProviderFetchState(rawValue: stateString) ?? .success
        } else {
            // Fallback for old associated-value format or missing key
            fetchState = .success
        }

        fetchedAt = try container.decodeIfPresent(Date.self, forKey: .fetchedAt) ?? Date()
    }
}

// MARK: - Date Helpers

public extension Date {
    var relativeString: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: self, relativeTo: Date())
    }

    var countdownString: String {
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

public extension Double {
    var compactString: String {
        if self >= 1_000_000 {
            return String(format: "%.1fM", self / 1_000_000).replacingOccurrences(of: ".0", with: "")
        } else if self >= 1_000 {
            return String(format: "%.1fK", self / 1_000).replacingOccurrences(of: ".0", with: "")
        } else {
            return String(format: "%.0f", self)
        }
    }
}

public func formattedMetricValue(_ value: Double, unit: String) -> String {
    let unitLower = unit.lowercased()
    switch unitLower {
    case "tokens", "tok":
        return "\(value.compactString) tokens"
    case "requests", "req":
        return "\(value.compactString) reqs"
    case "usd", "$":
        return "$\(String(format: "%.2f", value))"
    case "msg", "msgs":
        return "\(value.compactString) msgs"
    case "hrs":
        return "\(value.compactString) hrs"
    case "credits":
        return "\(value.compactString) credits"
    case "":
        return value.compactString
    default:
        return "\(value.compactString) \(unit)"
    }
}
