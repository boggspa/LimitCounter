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
    case openaiAPI
    case chatgpt
    case codexTelemetry
    case devin
    case cursor
    case gemini
    case kimi
    case grok
    case antigravity
    case mistral
    case deepseek
    case cerebras
    case meta
    case ollama
    case openrouter
    case qwen
    case mimo
    case heatmap

    public static var userFacingCases: [ProviderID] {
        allCases.filter { $0.isUserFacingInProviderLists }
    }

    public var id: String { rawValue }

    public nonisolated var isUserFacingInProviderLists: Bool {
        self != .codexTelemetry && self != .heatmap
    }

    /// Every dashboard surface the user can drag to reorder.
    ///
    /// Deliberately wider than `isUserFacingInProviderLists`: the
    /// activity heatmap is not a provider in the settings/visibility
    /// lists, but it *is* a dashboard card that takes part in the
    /// drag-to-reorder order. Codex telemetry never renders its own
    /// card (it folds into the Codex card), so it stays out.
    public nonisolated var isOrderableDashboardCard: Bool {
        self != .codexTelemetry
    }

    public var displayName: String {
        switch self {
        case .claude:   return "Claude"
        case .openai:   return "Codex"
        case .openaiAPI:
            return "OpenAI API"
        case .chatgpt:  return "ChatGPT"
        case .codexTelemetry:
            return "Codex Telemetry"
        case .devin: return "Devin"
        case .cursor:   return "Cursor"
        case .gemini:   return "Gemini"
        case .kimi:     return "Kimi Code"
        case .grok:     return "Grok"
        case .antigravity:
            return "Antigravity"
        case .mistral:  return "Mistral"
        case .deepseek: return "DeepSeek"
        case .cerebras: return "Cerebras"
        case .meta:     return "Meta API"
        case .ollama:   return "Ollama"
        case .openrouter: return "OpenRouter"
        case .qwen:     return "Qwen Token Plan"
        case .mimo:     return "MiMo Token Plan"
        case .heatmap:  return "Activity Heatmap"
        }
    }

    public var snapshotDisplayName: String {
        switch self {
        case .openai:
            return "Codex"
        case .openaiAPI:
            return "OpenAI API"
        case .chatgpt:
            return "ChatGPT"
        case .codexTelemetry:
            return "Codex Telemetry"
        case .claude, .devin, .cursor, .gemini, .kimi, .grok,
                .antigravity, .mistral, .deepseek, .cerebras, .meta, .ollama, .openrouter, .qwen, .mimo, .heatmap:
            return displayName
        }
    }

    public var iconName: String {
        switch self {
        case .claude:   return "brain.head.profile.fill"
        case .openai:   return "terminal.fill"
        case .openaiAPI:
            return "chart.line.uptrend.xyaxis"
        case .chatgpt:  return "bubble.left.and.bubble.right.fill"
        case .codexTelemetry:
            return "cpu.fill"
        case .devin: return "wave.3.right"
        case .cursor:   return "cursorarrow.rays"
        case .gemini:   return "sparkles"
        case .kimi:     return "moon.stars.fill"
        case .grok:     return "bolt.fill"
        case .antigravity:
            return "a.circle.fill"
        case .mistral:  return "m.square.fill"
        case .deepseek: return "d.circle.fill"
        case .cerebras: return "c.circle.fill"
        case .meta:     return "infinity"
        case .ollama:   return "circle.grid.2x2.fill"
        case .openrouter: return "arrow.left.arrow.right.circle.fill"
        case .qwen:     return "q.circle.fill"
        case .mimo:     return "m.circle.fill"
        case .heatmap:  return "calendar.badge.clock"
        }
    }

    public var accentColorHex: String {
        switch self {
        case .claude:   return "#B85838" // Claude Rust
        case .openai:   return "#4D4DFF" // Electric Indigo — same hue family as the previous #6366F1 (~240°) but saturation maxed to 100% (was 84%) for stronger contrast against Gemini's Google Blue #4285F4
        case .openaiAPI:
            return "#10B981" // OpenAI Green
        case .chatgpt:  return "#10B981" // Emerald/OpenAI Green
        case .codexTelemetry:
            return "#4D4DFF" // Electric Indigo — same hue family as the previous #6366F1 (~240°) but saturation maxed to 100% (was 84%) for stronger contrast against Gemini's Google Blue #4285F4
        case .devin: return "#2D5AB2" // Deep Devin Blue
        case .cursor:   return "#EAB308" // Gold
        case .gemini:   return "#4285F4" // Google Blue
        case .kimi:     return "#1CA4FC" // Kimi Blue
        case .grok:     return "#C7CCD4" // Grok Silver — monochrome to match xAI's black/white brand. The meter severity gradient (orange ≥60%, red ≥90%) is applied by usageColor() independently of this accent, so escalation colors are preserved.
        case .antigravity:
            return "#308713"
        case .mistral:  return "#D44404"
        case .deepseek: return "#4E6AEE"
        case .cerebras: return "#BB584A"
        case .meta:     return "#0082FB" // Meta Blue
        case .ollama:   return "#976C52" // Ollama Walnut Brown — low-chroma warm brown for on-device inference. Sits at the equal-contrast point (relative luminance ~0.179, ~4.58:1 against both pure white and pure black), so it stays legible in light and dark appearances. The meter severity gradient (orange ≥60%, red ≥90%) is applied by usageColor() independently of this accent, so escalation colors are preserved.
        case .openrouter: return "#8B5CF6" // OpenRouter Purple
        case .qwen:     return "#615CED" // Qwen Purple
        case .mimo:     return "#008844" // Xiaomi Green
        case .heatmap:  return "#5B8AF5" // App Blue
        }
    }

    public var bundledLogoAssetName: String {
        switch self {
        case .claude:
            return "ProviderClaudeLogo"
        case .openai:
            return "ProviderCodexLogo"
        case .openaiAPI:
            return "ProviderChatGPTLogo"
        case .chatgpt:
            return "ProviderChatGPTLogo"
        case .codexTelemetry:
            return "ProviderCodexLogo"
        case .devin:
            return "ProviderDevinLogo"
        case .cursor:
            return "ProviderCursorLogo"
        case .gemini:
            return "ProviderGeminiLogo"
        case .kimi:
            return "ProviderKimiLogo"
        case .grok:
            return "ProviderGrokLogo"
        case .antigravity:
            return "ProviderAntigravityLogo"
        case .mistral:
            return "ProviderMistralLogo"
        case .deepseek:
            return "ProviderDeepSeekLogo"
        case .cerebras:
            return "ProviderCerebrasLogo"
        case .meta:
            return "ProviderMetaLogo"
        case .ollama:
            return "ProviderOllamaLogo"
        case .openrouter:
            return "ProviderOpenRouterLogo"
        case .qwen:
            return "ProviderQwenLogo"
        case .mimo:
            return "ProviderMiMoLogo"
        case .heatmap:
            return ""
        }
    }

    public var integrationStatus: ProviderIntegrationStatus {
        switch self {
        case .chatgpt, .codexTelemetry:
            return .prototype
        case .claude, .openai, .openaiAPI, .devin, .cursor, .gemini, .kimi,
                .grok, .antigravity, .mistral, .deepseek, .cerebras, .meta, .ollama, .openrouter, .qwen, .mimo:
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
        case .openaiAPI:
            return "OpenAI organization usage API"
        case .chatgpt:
            return "ChatGPT local desktop cache"
        case .codexTelemetry:
            return "Codex local telemetry folder"
        case .devin:
            return "Devin local quota cache"
        case .cursor:
            return "Cursor web session and local state"
        case .gemini:
            return "Gemini CLI local session"
        case .kimi:
            return "Kimi Code API or CLI session"
        case .grok:
            return "Grok CLI weekly quota"
        case .antigravity:
            return "Antigravity CLI quota"
        case .mistral:
            return "Mistral Vibe usage and allowance"
        case .deepseek:
            return "DeepSeek API credit balance and top-ups"
        case .cerebras:
            return "Cerebras usage import"
        case .meta:
            return "Meta API credits, Muse spend and subscription"
        case .ollama:
            return "Ollama Cloud session"
        case .openrouter:
            return "OpenRouter API usage tracking"
        case .qwen:
            return "Qwen Model Studio token plan"
        case .mimo:
            return "Xiaomi MiMo Token Plan"
        case .heatmap:
            return "Activity Heatmap"
        }
    }

    public var configurationDescription: String {
        switch self {
        case .claude:
            return "Reads local Claude Code transcripts under `~/.claude` for token stats. Uses a pasted OAuth token or Limit Counter's mirrored OAuth token for live 5-hour and 7-day quota meters."
        case .openai:
            return "Uses a ChatGPT-authorized Codex session to read the private 5-hour and 7-day usage surface. An optional `~/.codex` folder grant follows CLI token rotation without repeated prompts."
        case .openaiAPI:
            return "Uses an OpenAI admin API key and project ID to read official 30-day usage, request, and cost history from OpenAI organization APIs."
        case .chatgpt:
            return "Reads the local ChatGPT macOS app cache and turns recent conversation activity into local usage-style snapshots."
        case .codexTelemetry:
            return "Reads the local Codex store you point it at and turns event counts and token totals into snapshots."
        case .devin:
            return "Reads the local Devin quota cache or a user-provided export and normalizes the quota windows."
        case .cursor:
            return "Uses a Cursor web session or dashboard token for live usage, and can read local Cursor state for cached account metadata."
        case .gemini:
            return "Reads local Gemini CLI history and metadata from `~/.gemini` and turns it into usage snapshots."
        case .kimi:
            return "Uses a Kimi Code Console API key or imported CLI OAuth folder for 5-hour and weekly quota. An optional kimi.ai web session adds the shared monthly membership-credit meter."
        case .grok:
            return "Runs the local Grok CLI `/usage` screen from a user-granted `~/.grok` folder and parses the weekly quota meter. TaskWraith data remains optional for activity history."
        case .antigravity:
            return "Reads an explicitly granted Antigravity CLI session and requests the official 5-hour and 7-day quota summary on a looping cadence (4m → 7m → 16m → 3m → 21m), or immediately on manual refresh."
        case .mistral:
            return "Estimates Vibe spend under `~/.vibe` TaskWraith-style (unique payload chars÷4 × catalogue rates). The Vibe Code budget can be entered manually, or supplied by an Enterprise Admin API key."
        case .deepseek:
            return "Uses the official DeepSeek balance API for current credits. An optional cumulative top-up total derives a credit-used meter, while observed balance decreases remain a separate monthly estimate."
        case .cerebras:
            return "Imports an official Cerebras Analytics CSV or a manual balance anchor. Optional local telemetry is displayed as an API-price estimate."
        case .meta:
            return "Projects Muse session spend from a granted `~/.local/share/muse` folder using catalog rates (TaskWraith-compatible). Grant the local Muse CLI for live Muse Code subscription meters (Current usage and Weekly limit, refreshed every 10 minutes); an imported dev.meta.ai session is the fallback and also anchors billing-period spend. Preload/remaining still derive credit used. Soft monthly budget defaults to $15 and resets on the 1st."
        case .ollama:
            return "Uses your Ollama session cookie (`__Secure-session`) to read Session usage and Weekly usage meters, or the monthly included-usage dollar budget ($X of $Y), from ollama.com/settings."
        case .openrouter:
            return "Uses an OpenRouter API key to read usage tracking and spend from the official `https://openrouter.ai/api/v1/auth/key` endpoint."
        case .qwen:
            return "Uses an imported Alibaba Cloud Model Studio web session to read the personal token plan quota meter (monthly on current Standard plans, 7-day on older ones), plan metadata, and reset date. A manual percent anchor is used when no session is imported."
        case .mimo:
            return "Uses an imported Xiaomi MiMo console web session to read the plan quota meter and renewal metadata from platform.xiaomimimo.com."
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
        case .openaiAPI:
            return "OpenAI admin API key"
        case .chatgpt:
            return "ChatGPT app data folder"
        case .codexTelemetry:
            return "Codex telemetry folder"
        case .devin:
            return "Devin access token"
        case .cursor:
            return "Cursor web session cookie or dashboard token"
        case .gemini:
            return "Gemini CLI data root"
        case .kimi:
            return "Kimi Code API key"
        case .grok:
            return "Grok CLI data folder"
        case .antigravity:
            return "Antigravity CLI data folder"
        case .mistral:
            return "Mistral Admin API key (optional)"
        case .deepseek:
            return "DeepSeek API key"
        case .cerebras:
            return "Cerebras Analytics CSV or data folder"
        case .meta:
            return "Muse data folder"
        case .ollama:
            return "Session Cookie (__Secure-session)"
        case .openrouter:
            return "OpenRouter API key"
        case .qwen:
            return "Qwen Model Studio web session"
        case .mimo:
            return "Xiaomi MiMo web session"
        case .heatmap:
            return ""
         }
     }

    public var secondaryCredentialLabel: String? {
        switch self {
        case .claude:
            return "OAuth token (optional)"
        case .chatgpt, .gemini, .kimi, .grok, .antigravity, .deepseek,
              .codexTelemetry, .meta, .ollama, .openrouter, .qwen, .mimo, .heatmap:
            return nil
        case .mistral:
            return "Vibe Code budget (optional)"
        case .cerebras:
            return "Purchased credits (optional)"
        case .openaiAPI:
            return "Project ID"
        case .openai:
            return "ChatGPT account ID"
        case .devin:
            return "Team ID (optional)"
        case .cursor:
            return "Team slug or org ID"
        }
    }

    public var securityNote: String {
        switch self {
        case .openai:
            return "Use only a Codex session or `~/.codex` folder you intentionally grant from an account you control. Folder access is limited to following `auth.json` session rotation."
        case .openaiAPI:
            return "Use only an OpenAI admin key you intentionally create for usage reporting, and scope it to the organization/project you control."
        case .chatgpt:
            return "Use only the local ChatGPT desktop app data folder you intentionally select from an account you control."
        case .codexTelemetry:
            return "Use only local Codex log folders or exports you intentionally point the app at."
        case .claude:
            return "Use only Claude Code logs, OAuth tokens, or keychain access you intentionally provide."
        case .cursor:
            return "Use only a Cursor web credential you intentionally import. Local Cursor state is read only for cached metadata."
        case .devin:
            return "Use only credentials the user intentionally enters or exports."
        case .gemini:
            return "Use only local Gemini CLI log folders or history you intentionally point the app at."
        case .kimi:
            return "Use only a Kimi Code API key, CLI OAuth folder, or kimi.ai web session you intentionally provide. Web session tokens are stored in Keychain and used only for membership quota reporting."
        case .grok:
            return "Runs only the local Grok CLI `/usage` command against the `~/.grok` folder you grant. No prompts are sent and no xAI credentials are extracted."
        case .antigravity:
            return "Reads only the official CLI OAuth session file from the folder you grant, then requests quota summary on a 4→7→16→3→21 minute loop (or immediately on manual refresh). It does not send model prompts or read browser data."
        case .mistral:
            return "Reads Vibe `meta.json` and estimates character lengths from `messages.jsonl` (content is not stored) from a folder you grant. Admin keys and manual billing anchors are stored in Keychain."
        case .deepseek:
            return "Uses only the DeepSeek API key you enter to request the documented balance endpoint."
        case .cerebras:
            return "Reads only the Cerebras CSV or folder you explicitly select. It does not inspect browser sessions or private web APIs."
        case .meta:
            return "Reads Muse `session.jsonl` usage fields from a folder you grant. Subscription meters come from the granted local Muse CLI (run read-only with `--no-session-log`, every 10 minutes). An imported dev.meta.ai session is stored in Keychain and each console surface is read no more than hourly; manual billing anchors are also stored in Keychain. Meta has no documented balance API."
        case .ollama:
            return "Stores your Ollama `__Secure-session` cookie securely in macOS Keychain. Used only to read your usage meters from ollama.com/settings."
        case .openrouter:
            return "Uses only the OpenRouter API key you enter to request the documented usage tracking endpoint at `https://openrouter.ai/api/v1/auth/key`."
        case .qwen:
            return "Stores your imported Alibaba Cloud Model Studio web session securely in macOS Keychain. Used only to read your token plan quota meter from the Model Studio console."
        case .mimo:
            return "Stores your imported Xiaomi MiMo console web session securely in macOS Keychain. Used only to read your plan quota meter from platform.xiaomimimo.com."
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
        case .openaiAPI:
            return [
                AppIconCandidate(bundleIdentifier: "com.openai.chat", applicationNames: ["ChatGPT.app"])
            ]
        case .chatgpt:
            return [
                AppIconCandidate(bundleIdentifier: "com.openai.chat", applicationNames: ["ChatGPT.app"])
            ]
        case .devin:
            return [
                AppIconCandidate(bundleIdentifier: "com.cognition.devin", applicationNames: ["Devin.app"]),
                AppIconCandidate(bundleIdentifier: "com.cognition.devin", applicationNames: ["Devin.app"])
            ]
        case .cursor:
            return [
                AppIconCandidate(bundleIdentifier: "com.cursor.Cursor", applicationNames: ["Cursor.app"]),
                AppIconCandidate(bundleIdentifier: "com.anysphere.cursor", applicationNames: ["Cursor.app"])
            ]
        case .kimi:
            // Kimi 3.x ships a textured app icon whose fine detail aliases into
            // a corrupted-looking block at dashboard sizes. Use the bundled,
            // small-size official mark instead.
            return []
        case .grok:
            return [
                AppIconCandidate(bundleIdentifier: "ai.x.grok", applicationNames: ["Grok.app"]),
                AppIconCandidate(bundleIdentifier: "com.x.grok", applicationNames: ["Grok.app"])
            ]
        case .antigravity:
            // The installed Antigravity app icon aliases into an unreadable
            // raster tile at dashboard size. Use the bundled official mark.
            return []
        case .ollama:
            return [
                AppIconCandidate(bundleIdentifier: "com.electron.ollama", applicationNames: ["Ollama.app"]),
                AppIconCandidate(bundleIdentifier: "ai.ollama.ollama", applicationNames: ["Ollama.app"])
            ]
        case .gemini, .mistral, .deepseek, .cerebras, .meta, .codexTelemetry, .openrouter, .qwen, .mimo, .heatmap:
            return []
        }
    }
}
#elseif canImport(UIKit)
public extension ProviderID {
    var bundledLogoImage: UIImage? {
        let assetName = bundledLogoAssetName
        guard !assetName.isEmpty else { return nil }
        return UIImage(named: assetName)
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

// MARK: - Quota Pace

public enum QuotaPaceState: String, Codable, Hashable {
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

public struct QuotaPace: Codable, Equatable, Hashable {
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

    public var colorHex: String {
        switch state {
        case .ahead:
            return "#22C55E"
        case .onTrack:
            return "#3B82F6"
        case .behind:
            return "#F97316"
        }
    }
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
        case "gbp", "£":
            return "£"
        case "eur", "€":
            return "€"
        default:
            return unit
        }
    }

    public var isCurrencyMetric: Bool {
        let normalized = unit.trimmingCharacters(in: .whitespacesAndNewlines)
        if ["$", "£", "€"].contains(normalized) { return true }
        return Locale.commonISOCurrencyCodes.contains(normalized.uppercased())
    }

    public var measurementSummary: String {
        if let resetDate, resetDate < Date() {
            if let total {
                if isCurrencyMetric {
                    return "\(formattedMetricValue(0, unit: unit)) of \(formattedMetricValue(total, unit: unit))"
                }
                return "0 / \(total.compactString) \(displayUnit)"
            }
            return formattedMetricValue(0, unit: unit)
        }

        if let total {
            if isCurrencyMetric {
                return "\(formattedMetricValue(used, unit: unit)) of \(formattedMetricValue(total, unit: unit))"
            }
            return "\(used.compactString) / \(total.compactString) \(displayUnit)"
        }
        if let subtitle = subtitle?.trimmingCharacters(in: .whitespacesAndNewlines), !subtitle.isEmpty {
            return subtitle
        }
        return formattedMetricValue(used, unit: unit)
    }

    public var leadingValueText: String {
        if let resetDate, resetDate < Date() {
            if isCurrencyMetric { return formattedMetricValue(0, unit: unit) }
            return hasExplicitLimit ? "0%" : formattedMetricValue(0, unit: unit)
        }
        if isCurrencyMetric { return formattedMetricValue(used, unit: unit) }
        return hasExplicitLimit ? "\(percentageUsed)%" : formattedMetricValue(used, unit: unit)
    }

    public func leadingValueText(for providerID: ProviderID?) -> String {
        guard providerID == .mistral, isCurrencyMetric else { return leadingValueText }
        if let resetDate, resetDate < Date() {
            return formattedMetricValue(0, unit: unit)
        }
        return formattedMetricValue(used, unit: unit, maximumFractionDigits: 4)
    }

    public nonisolated init(
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

    public func pace(providerID: ProviderID? = nil, at date: Date = Date()) -> QuotaPace? {
        guard hasExplicitLimit, let total, total > 0 else { return nil }
        guard let resetDate, resetDate > date else { return nil }
        guard let duration = inferredPaceDuration(providerID: providerID), duration > 0 else { return nil }

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

    /// Best-effort length of this window's period, from its label, subtitle
    /// and kind. Shared by pace tracking and reset detection.
    public func inferredPeriodDuration(providerID: ProviderID? = nil) -> TimeInterval? {
        inferredPaceDuration(providerID: providerID)
    }

    private func inferredPaceDuration(providerID: ProviderID?) -> TimeInterval? {
        let descriptor = "\(label) \(subtitle ?? "")".lowercased()

        if descriptor.contains("5h") || descriptor.contains("5-hour") || descriptor.contains("5 hour") {
            return 5 * 60 * 60
        }

        if descriptor.contains("24h") || descriptor.contains("24-hour") || descriptor.contains("daily") {
            return 24 * 60 * 60
        }

        if descriptor.contains("7d") || descriptor.contains("7-day") || descriptor.contains("weekly") {
            return 7 * 24 * 60 * 60
        }

        switch windowKind {
        case .session:
            // Meta's only session window is Muse Code's rolling current-usage
            // meter, which shares the five-hour shape Codex and Claude use.
            if descriptor.contains("session")
                || providerID == .openai
                || providerID == .claude
                || providerID == .meta {
                return 5 * 60 * 60
            }
            return nil
        case .daily:
            return 24 * 60 * 60
        case .weekly:
            return 7 * 24 * 60 * 60
        case .monthly:
            return 30 * 24 * 60 * 60
        case .yearly:
            return 365 * 24 * 60 * 60
        case .sliding:
            return nil
        case .project, .custom:
            return nil
        }
    }

    public func segmentCount(for providerID: ProviderID?) -> Int? {
        guard let providerID = providerID else { return nil }
        
        let descriptor = label.lowercased()
        
        switch providerID {
        case .openai, .chatgpt, .openaiAPI:
            if descriptor.contains("5h") || descriptor.contains("5-hour") || descriptor.contains("5 hour") || descriptor.contains("session") { return 5 }
            if descriptor.contains("weekly") || descriptor.contains("luna") { return 7 }
        case .claude:
            if descriptor.contains("5h") || descriptor.contains("5-hour") || descriptor.contains("5 hour") || descriptor.contains("session") { return 5 }
            if descriptor.contains("weekly") || descriptor.contains("fable") { return 7 }
        case .gemini:
            if descriptor.contains("5h") || descriptor.contains("5-hour") || descriptor.contains("5 hour") || descriptor.contains("session") { return 5 }
            if descriptor.contains("weekly") { return 7 }
        case .kimi:
            if descriptor.contains("5h") || descriptor.contains("5-hour") || descriptor.contains("5 hour") || descriptor.contains("session") { return 5 }
            if descriptor.contains("weekly") { return 7 }
            if descriptor.contains("monthly") { return 4 }
        case .antigravity:
            if descriptor.contains("5h") || descriptor.contains("5-hour") || descriptor.contains("5 hour") || descriptor.contains("session") { return 5 }
            if descriptor.contains("weekly") { return 7 }
        case .mistral:
            if descriptor.contains("api") || descriptor.contains("vibe") { return 4 }
        case .cursor:
            if descriptor.contains("plan") || descriptor.contains("auto") || descriptor.contains("api") { return 4 }
        case .grok:
            if descriptor.contains("weekly") { return 7 }
        case .ollama:
            if descriptor.contains("5h") || descriptor.contains("5-hour") || descriptor.contains("5 hour") || descriptor.contains("session") { return 5 }
            if descriptor.contains("weekly") { return 7 }
            if descriptor.contains("free") || descriptor.contains("included") || descriptor.contains("month") { return 4 }
        case .devin:
            if descriptor.contains("daily") { return 6 }
            if descriptor.contains("weekly") { return 7 }
        case .mimo:
            if descriptor.contains("monthly") || descriptor.contains("plan") { return 4 }
        case .qwen:
            if descriptor.contains("5h") || descriptor.contains("5-hour") || descriptor.contains("5 hour") || descriptor.contains("session") { return 5 }
            if descriptor.contains("weekly") || descriptor.contains("7-day") { return 7 }
            if descriptor.contains("month") { return 4 }
        case .meta:
            if descriptor.contains("weekly") { return 7 }
            if descriptor.contains("credit") || descriptor.contains("monthly") { return 4 }
        case .deepseek, .cerebras, .openrouter:
            if descriptor.contains("credit") || descriptor.contains("monthly") { return 4 }
        default:
            return nil
        }
        
        return nil
    }
}

// MARK: - Period Grouping

/// The buckets the "Period" compact layout stacks meters into.
///
/// Providers name the same reset cadence a dozen different ways —
/// Claude calls its five-hour window "Session", Ollama "Session usage",
/// Meta "Current usage", Kimi just "5H" — so the grouping keys off the
/// window label first and falls back to `QuotaWindowKind` only when the
/// label carries no period word.
public enum QuotaPeriodGroup: String, Codable, CaseIterable, Identifiable, Hashable {
    case fiveHour
    case daily
    case weekly
    case monthlyAndAPI

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .fiveHour: return "5H"
        case .daily: return "Daily"
        case .weekly: return "Weekly"
        case .monthlyAndAPI: return "Monthly + API"
        }
    }
}

public extension QuotaWindow {
    /// An identity for this meter that survives a refresh.
    ///
    /// `id` is a fresh `UUID` every time a provider is read, so it cannot carry
    /// anything the user chose — a dragged rank would reset on the next sync,
    /// and a `ForEach` keyed on it rebuilds every row on every refresh. Label,
    /// window kind and unit are what actually distinguish one meter from
    /// another, which is the same triple `QuotaResetDetector.WindowKey` keys its
    /// ledger on; the provider goes in front so two providers' identically
    /// named meters stay distinct when they share a list.
    ///
    /// This assumes one meter per provider per triple, which is the same
    /// assumption `WindowKey` has always made. A provider that emitted two
    /// windows identical in all three would collapse to one identity here, in
    /// the reset ledger, and in `ForEach` — none of the shipping providers does,
    /// and the two Claude weekly windows differ by unit.
    ///
    /// `nonisolated` because the app target builds with
    /// `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` while the callers — the
    /// meter-order store's `key(providerID:window:)`, the widget target and the
    /// standalone test harnesses — are not main-actor isolated. It only reads
    /// `let` fields, so there is nothing to isolate.
    nonisolated func stableIdentity(for providerID: ProviderID) -> String {
        [
            providerID.rawValue,
            label.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
            windowKind.rawValue,
            unit.lowercased()
        ].joined(separator: "|")
    }

    /// Which period bucket this meter belongs in.
    ///
    /// `providerID` only matters for windows whose kind is `.custom`:
    /// Gemini CLI models its per-model free-tier caps that way even
    /// though they reset daily, while the spend providers (DeepSeek,
    /// Cerebras) use `.custom` for rolling credit balances.
    func periodGroup(for providerID: ProviderID? = nil) -> QuotaPeriodGroup {
        let descriptor = label.lowercased()

        if descriptor.contains("5h") || descriptor.contains("5-hour") || descriptor.contains("5 hour") {
            return .fiveHour
        }
        if descriptor.contains("7d") || descriptor.contains("7-day") || descriptor.contains("7 day")
            || descriptor.contains("week") {
            return .weekly
        }
        if descriptor.contains("24h") || descriptor.contains("24-hour") || descriptor.contains("daily") {
            return .daily
        }
        if descriptor.contains("30d") || descriptor.contains("monthly") || descriptor.contains("month") {
            return .monthlyAndAPI
        }

        switch windowKind {
        case .session:
            return .fiveHour
        case .daily:
            return .daily
        case .weekly:
            return .weekly
        case .monthly, .yearly, .sliding, .project:
            return .monthlyAndAPI
        case .custom:
            return providerID == .gemini ? .daily : .monthlyAndAPI
        }
    }
}

/// One meter row in the period layout. `window` is nil for a provider
/// that has no meters yet — it still gets a row so the user can see the
/// provider is connected but idle (OpenRouter, a freshly added key).
public struct QuotaPeriodRow: Identifiable, Equatable, Hashable {
    /// Stable across refreshes, unlike the window's own `id`. A `ForEach`
    /// keyed on a fresh UUID rebuilds every row whenever a provider refreshes,
    /// which is invisible until something is being dragged — then it cancels.
    public let id: String
    public let providerID: ProviderID
    public let label: String
    public let window: QuotaWindow?

    public init(id: String, providerID: ProviderID, label: String, window: QuotaWindow?) {
        self.id = id
        self.providerID = providerID
        self.label = label
        self.window = window
    }
}

public struct QuotaPeriodSection: Identifiable, Equatable, Hashable {
    public let group: QuotaPeriodGroup
    public let rows: [QuotaPeriodRow]

    public var id: String { group.rawValue }

    public init(group: QuotaPeriodGroup, rows: [QuotaPeriodRow]) {
        self.group = group
        self.rows = rows
    }

    /// Regroups already-ordered snapshots by reset period.
    ///
    /// Snapshots arrive in dashboard order, so within a period the rows
    /// keep the provider order the user dragged into place, and within a
    /// provider they keep the order the client emitted the windows in.
    /// Empty sections are dropped; providers with no meters land at the
    /// bottom of the last section.
    public static func sections(from snapshots: [QuotaSnapshot]) -> [QuotaPeriodSection] {
        var rowsByGroup: [QuotaPeriodGroup: [QuotaPeriodRow]] = [:]
        var idleRows: [QuotaPeriodRow] = []

        for snapshot in snapshots {
            let windows = snapshot.summaryWindows
            guard !windows.isEmpty else {
                idleRows.append(
                    QuotaPeriodRow(
                        id: "idle|\(snapshot.providerID.rawValue)",
                        providerID: snapshot.providerID,
                        label: snapshot.displayName,
                        window: nil
                    )
                )
                continue
            }

            for window in windows {
                let row = QuotaPeriodRow(
                    id: window.stableIdentity(for: snapshot.providerID),
                    providerID: snapshot.providerID,
                    label: snapshot.periodRowLabel(for: window),
                    window: window
                )
                rowsByGroup[window.periodGroup(for: snapshot.providerID), default: []].append(row)
            }
        }

        var sections = QuotaPeriodGroup.allCases.compactMap { group -> QuotaPeriodSection? in
            guard let rows = rowsByGroup[group], !rows.isEmpty else { return nil }
            return QuotaPeriodSection(group: group, rows: rows)
        }

        guard !idleRows.isEmpty else { return sections }

        if let last = sections.indices.last {
            sections[last] = QuotaPeriodSection(
                group: sections[last].group,
                rows: sections[last].rows + idleRows
            )
        } else {
            sections = [QuotaPeriodSection(group: .monthlyAndAPI, rows: idleRows)]
        }
        return sections
    }
}

public extension QuotaSnapshot {
    /// Row label for the period layout, which has no per-provider header
    /// to lean on: the provider name is prefixed to the window label,
    /// with any overlap between the two collapsed so "MiMo Token Plan" +
    /// "Plan Quota" reads "MiMo Token Plan Quota" rather than repeating
    /// "Plan".
    func periodRowLabel(for window: QuotaWindow) -> String {
        let providerWords = displayName.split(separator: " ").map(String.init)
        let labelWords = window.label.split(separator: " ").map(String.init)

        guard !labelWords.isEmpty else { return displayName }
        guard !providerWords.isEmpty else { return window.label }

        func lowered(_ words: [String]) -> [String] { words.map { $0.lowercased() } }

        var overlap = 0
        for count in stride(from: min(providerWords.count, labelWords.count), through: 1, by: -1)
        where lowered(Array(providerWords.suffix(count))) == lowered(Array(labelWords.prefix(count))) {
            overlap = count
            break
        }

        return (providerWords + labelWords.dropFirst(overlap)).joined(separator: " ")
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
    case scheduledReset
}

/// What kind of usage-limit reset a signal (or ledger entry) describes.
///
/// `QuotaSignalKind` stays a two-case enum so snapshots published to CloudKit
/// keep decoding on older iOS builds; this finer classification rides along
/// as an optional field that older decoders simply ignore.
public enum QuotaResetKind: String, Codable, Hashable, CaseIterable {
    /// The window's own reset time passed and the meter started over.
    case scheduled
    /// One window came back early, out of sequence — a provider gift, or a
    /// banked reset redeemed on a provider that does not report credits.
    case gifted
    /// Several windows of the same provider reset together: the "we've reset
    /// everyone's limits" celebration pattern.
    case providerWide
    /// A banked (earned) reset credit was consumed and the window restarted.
    case bankedRedeemed
    /// A banked reset credit is available to redeem.
    case bankedAvailable

    /// Whether this kind describes a reset that actually happened (as opposed
    /// to one that is merely available).
    public var isResetEvent: Bool {
        self != .bankedAvailable
    }

    /// Resets the user did not schedule or trigger themselves count toward the
    /// "N resets · 7d" tally and earn a celebration.
    public var isIndependentReset: Bool {
        switch self {
        case .gifted, .providerWide:
            return true
        case .scheduled, .bankedRedeemed, .bankedAvailable:
            return false
        }
    }

    public var title: String {
        switch self {
        case .scheduled: return "Scheduled reset"
        case .gifted: return "Gifted reset"
        case .providerWide: return "Provider-wide reset"
        case .bankedRedeemed: return "Banked reset redeemed"
        case .bankedAvailable: return "Reset available"
        }
    }

    public var systemImageName: String {
        switch self {
        case .scheduled: return "arrow.clockwise.circle"
        case .gifted: return "gift"
        case .providerWide: return "party.popper"
        case .bankedRedeemed: return "checkmark.seal"
        case .bankedAvailable: return "ticket"
        }
    }
}

// MARK: - Banked Reset Credits

/// A provider-issued usage-limit reset the user can redeem ("banked").
public struct QuotaResetCredit: Codable, Identifiable, Equatable, Hashable {
    public let id: String
    public let status: String?
    public let grantedAt: Date?
    public let expiresAt: Date?
    public let title: String?
    public let note: String?

    public init(
        id: String,
        status: String? = nil,
        grantedAt: Date? = nil,
        expiresAt: Date? = nil,
        title: String? = nil,
        note: String? = nil
    ) {
        self.id = id
        self.status = status
        self.grantedAt = grantedAt
        self.expiresAt = expiresAt
        self.title = title
        self.note = note
    }

    public var isAvailable: Bool {
        guard let status = status?.lowercased() else { return true }
        return status == "available" || status == "active" || status == "redeemable"
    }
}

public enum QuotaResetCreditEventKind: String, Codable, Hashable {
    case granted
    case used
    case expired
}

/// One entry of a provider's own reset-credit history ("Reset received",
/// "Reset used").
public struct QuotaResetCreditEvent: Codable, Identifiable, Equatable, Hashable {
    public let id: String
    public let kind: QuotaResetCreditEventKind
    public let occurredAt: Date

    public init(id: String, kind: QuotaResetCreditEventKind, occurredAt: Date) {
        self.id = id
        self.kind = kind
        self.occurredAt = occurredAt
    }
}

/// Provider-reported state of banked usage-limit resets. Codex reports this
/// directly; Qwen's console shows the available count on its plan page.
public struct QuotaResetCreditSummary: Codable, Equatable, Hashable {
    public let availableCount: Int
    public let earnedCount: Int?
    public let credits: [QuotaResetCredit]
    public let history: [QuotaResetCreditEvent]
    public let redeemHint: String?
    public let observedAt: Date

    public init(
        availableCount: Int,
        earnedCount: Int? = nil,
        credits: [QuotaResetCredit] = [],
        history: [QuotaResetCreditEvent] = [],
        redeemHint: String? = nil,
        observedAt: Date = Date()
    ) {
        self.availableCount = max(0, availableCount)
        self.earnedCount = earnedCount
        self.credits = credits
        self.history = history
        self.redeemHint = redeemHint
        self.observedAt = observedAt
    }

    /// Soonest expiry among the credits that can still be redeemed.
    public var nearestExpiry: Date? {
        credits.filter(\.isAvailable).compactMap(\.expiresAt).min()
    }

    public var hasAvailableReset: Bool {
        availableCount > 0
    }

    /// "1 reset banked · expires in 2h".
    public func statusLine(at now: Date = Date()) -> String? {
        guard availableCount > 0 else { return nil }
        let count = availableCount == 1 ? "1 reset banked" : "\(availableCount) resets banked"
        guard let expiry = nearestExpiry else { return count }
        let remaining = expiry.timeIntervalSince(now)
        if remaining <= 0 {
            return "\(count) · expiring"
        }
        return "\(count) · expires in \(compactDurationString(remaining))"
    }
}

/// "2h 05m", "3d 4h", "45m".
public func compactDurationString(_ interval: TimeInterval) -> String {
    let totalMinutes = max(Int(interval / 60), 0)
    let days = totalMinutes / (24 * 60)
    let hours = (totalMinutes % (24 * 60)) / 60
    let minutes = totalMinutes % 60
    if days > 0 {
        return hours > 0 ? "\(days)d \(hours)h" : "\(days)d"
    }
    if hours > 0 {
        return minutes > 0 ? "\(hours)h \(String(format: "%02d", minutes))m" : "\(hours)h"
    }
    return "\(max(minutes, 1))m"
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
    /// Finer reset classification; nil for signals that are not about resets
    /// or that came from a build predating the classification.
    public let resetKind: QuotaResetKind?

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
        detectedAt: Date = Date(),
        resetKind: QuotaResetKind? = nil
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.message = message
        self.severity = severity
        self.confidence = confidence
        self.windowLabel = windowLabel
        self.detectedAt = detectedAt
        self.resetKind = resetKind
    }
}

/// Content-based identity for a `QuotaSignal`, used to spot the same signal
/// arriving from two sources. `QuotaSignal`'s own `Hashable` conformance
/// includes `id` and `detectedAt`, so it treats re-reports as distinct.
struct QuotaSignalIdentity: Hashable {
    let kind: QuotaSignalKind
    let windowLabel: String?
    let title: String
    let message: String

    init(_ signal: QuotaSignal) {
        kind = signal.kind
        windowLabel = signal.windowLabel
        title = signal.title
        message = signal.message
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

/// Old Codex telemetry treated every diagnostic log line as activity. Those
/// records have no usage evidence and must not survive in either the telemetry
/// snapshot or its copy on the Codex quota card. Confirmed task events now use
/// `.activity`; imported runs use `.message`, including runs without tokens.
public enum CodexActivityHistory {
    public static func cleaned(_ snapshot: QuotaSnapshot, now: Date = Date()) -> QuotaSnapshot {
        guard snapshot.providerID == .codexTelemetry || snapshot.providerID == .openai else {
            return snapshot
        }
        let events = snapshot.events.filter { event in
            guard event.timestamp <= now else { return false }
            return event.type != .telemetry || (event.tokens ?? 0) > 0
        }
        return events == snapshot.events ? snapshot : snapshot.withEvents(events)
    }
}

/// Flattens the events carried by a set of snapshots into one list with
/// duplicates removed.
///
/// Two duplication modes reach this point and they need different keys:
///
///  - The same event surfacing under two providers. The `openai` and
///    `codexTelemetry` snapshots carry Codex events verbatim, sharing their
///    `UUID`s, so a global id filter collapses those.
///  - The same usage re-appended to one provider's own event list across
///    refreshes. `UsageEvent` mints a fresh `id` on every construction, so
///    those copies are identical in content yet distinct by id and slip
///    straight past an id filter. Comparing on the payload is what actually
///    detects a repeat — the same trap `QuotaSnapshot.mergingSignals`
///    documents for `QuotaSignal`.
///
/// The content key is deliberately scoped to the snapshot that supplied the
/// event, so two providers legitimately reporting identical totals in the same
/// second still both count.
public enum UsageEventDeduplicator {
    public static func flatten(_ snapshots: [QuotaSnapshot]) -> [UsageEvent] {
        var seenIDs = Set<UUID>()
        var events: [UsageEvent] = []

        for snapshot in snapshots {
            var seenContent = Set<ContentKey>()
            for event in snapshot.events {
                guard seenIDs.insert(event.id).inserted,
                      seenContent.insert(ContentKey(event)).inserted else { continue }
                events.append(event)
            }
        }

        return events
    }

    private struct ContentKey: Hashable {
        let timestamp: Date
        let model: String
        let tokens: Double?
        let type: UsageEvent.EventType

        init(_ event: UsageEvent) {
            timestamp = event.timestamp
            model = event.model ?? ""
            tokens = event.tokens
            type = event.type
        }
    }
}

// MARK: - Usage Analytics

public enum UsageAnalyticsSource: String, Codable, Hashable {
    case officialAPI
    case localEstimate
    case localTelemetry
    case manualAnchor
}

public struct UsageAnalyticsBucket: Codable, Identifiable, Equatable, Hashable {
    public let id: String
    public let startDate: Date
    public let endDate: Date
    public let model: String?
    public let projectID: String?
    public let inputTokens: Double
    public let outputTokens: Double
    public let cachedInputTokens: Double
    public let requests: Double
    public let costUSD: Double?
    public let source: UsageAnalyticsSource
    public let note: String?

    public var totalTokens: Double {
        inputTokens + outputTokens + cachedInputTokens
    }

    public var hasUsage: Bool {
        totalTokens > 0 || requests > 0 || (costUSD ?? 0) > 0
    }

    public init(
        id: String? = nil,
        startDate: Date,
        endDate: Date,
        model: String? = nil,
        projectID: String? = nil,
        inputTokens: Double = 0,
        outputTokens: Double = 0,
        cachedInputTokens: Double = 0,
        requests: Double = 0,
        costUSD: Double? = nil,
        source: UsageAnalyticsSource,
        note: String? = nil
    ) {
        self.startDate = startDate
        self.endDate = endDate
        self.model = model
        self.projectID = projectID
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cachedInputTokens = cachedInputTokens
        self.requests = requests
        self.costUSD = costUSD
        self.source = source
        self.note = note
        self.id = id ?? Self.stableID(
            startDate: startDate,
            endDate: endDate,
            model: model,
            projectID: projectID,
            source: source,
            note: note
        )
    }

    private static func stableID(
        startDate: Date,
        endDate: Date,
        model: String?,
        projectID: String?,
        source: UsageAnalyticsSource,
        note: String?
    ) -> String {
        [
            source.rawValue,
            String(Int(startDate.timeIntervalSince1970)),
            String(Int(endDate.timeIntervalSince1970)),
            model ?? "all-models",
            projectID ?? "all-projects",
            note ?? ""
        ].joined(separator: "|")
    }
}

public struct UsageAnalyticsPeriodTotals: Equatable, Hashable {
    public var tokens: Double
    public var requests: Double
    public var cost: Double

    public var hasUsage: Bool {
        tokens > 0 || requests > 0 || cost > 0
    }

    public init(tokens: Double = 0, requests: Double = 0, cost: Double = 0) {
        self.tokens = tokens
        self.requests = requests
        self.cost = cost
    }

    public mutating func add(_ bucket: UsageAnalyticsBucket) {
        tokens += bucket.totalTokens
        requests += bucket.requests
        cost += bucket.costUSD ?? 0
    }

    public func scaled(by factor: Double) -> UsageAnalyticsPeriodTotals {
        UsageAnalyticsPeriodTotals(
            tokens: tokens * factor,
            requests: requests * factor,
            cost: cost * factor
        )
    }
}

public struct UsageAnalyticsDailySummary: Identifiable, Equatable, Hashable {
    public let id: Date
    public let date: Date
    public let tokens: Double
    public let requests: Double
    public let cost: Double

    public init(date: Date, totals: UsageAnalyticsPeriodTotals) {
        self.id = date
        self.date = date
        self.tokens = totals.tokens
        self.requests = totals.requests
        self.cost = totals.cost
    }
}

public struct UsageAnalyticsModelSummary: Identifiable, Equatable, Hashable {
    public let id: String
    public let name: String
    public let tokens: Double
    public let requests: Double
    public let cost: Double
    public let fractionOfMax: Double
    public let fractionOfTotal: Double

    public init(
        name: String,
        tokens: Double,
        requests: Double = 0,
        cost: Double = 0,
        fractionOfMax: Double,
        fractionOfTotal: Double
    ) {
        self.id = name
        self.name = name
        self.tokens = tokens
        self.requests = requests
        self.cost = cost
        self.fractionOfMax = min(max(fractionOfMax, 0), 1)
        self.fractionOfTotal = min(max(fractionOfTotal, 0), 1)
    }
}

public enum UsageAnalyticsInsightKind: String, Codable, Hashable {
    case budgetStatus
    case projectedMonth
    case usageSpike
    case topModel
}

public struct UsageAnalyticsInsight: Identifiable, Equatable, Hashable {
    public let id: String
    public let kind: UsageAnalyticsInsightKind
    public let title: String
    public let message: String
    public let severity: QuotaSignalSeverity

    public init(
        id: String? = nil,
        kind: UsageAnalyticsInsightKind,
        title: String,
        message: String,
        severity: QuotaSignalSeverity
    ) {
        self.kind = kind
        self.title = title
        self.message = message
        self.severity = severity
        self.id = id ?? [kind.rawValue, title, message].joined(separator: "|")
    }
}

public enum UsageBudgetState: String, Codable, Hashable {
    case underBudget
    case halfUsed
    case approaching
    case overBudget
}

public struct UsageMonthlyBudgetStatus: Equatable, Hashable {
    public let budgetUSD: Double
    public let monthToDateUSD: Double
    public let projectedUSD: Double
    public let fractionUsed: Double
    public let projectedFraction: Double
    public let state: UsageBudgetState

    public var severity: QuotaSignalSeverity {
        switch state {
        case .underBudget, .halfUsed:
            return .info
        case .approaching:
            return .warning
        case .overBudget:
            return .critical
        }
    }

    public var statusTitle: String {
        switch state {
        case .underBudget:
            return "Budget on track"
        case .halfUsed:
            return "50% budget mark"
        case .approaching:
            return "Approaching budget"
        case .overBudget:
            return "Over monthly budget"
        }
    }

    public var projectedPercentageText: String {
        "\(Int((projectedFraction * 100).rounded()))%"
    }

    public var usedPercentageText: String {
        "\(Int((fractionUsed * 100).rounded()))%"
    }

    public var insightMessage: String {
        switch state {
        case .underBudget:
            return "Projected \(formattedMetricValue(projectedUSD, unit: "$")) is \(projectedPercentageText) of the \(formattedMetricValue(budgetUSD, unit: "$")) monthly budget."
        case .halfUsed:
            return "Projected \(formattedMetricValue(projectedUSD, unit: "$")) reaches \(projectedPercentageText) of the \(formattedMetricValue(budgetUSD, unit: "$")) monthly budget."
        case .approaching:
            return "Projected \(formattedMetricValue(projectedUSD, unit: "$")) is near the \(formattedMetricValue(budgetUSD, unit: "$")) monthly budget."
        case .overBudget:
            return "Projected \(formattedMetricValue(projectedUSD, unit: "$")) exceeds the \(formattedMetricValue(budgetUSD, unit: "$")) monthly budget."
        }
    }

    public init?(
        budgetUSD: Double?,
        monthToDate: UsageAnalyticsPeriodTotals,
        projectedMonth: UsageAnalyticsPeriodTotals
    ) {
        guard
            let budgetUSD,
            budgetUSD.isFinite,
            budgetUSD > 0,
            monthToDate.cost > 0 || projectedMonth.cost > 0
        else {
            return nil
        }

        self.budgetUSD = budgetUSD
        self.monthToDateUSD = monthToDate.cost
        self.projectedUSD = projectedMonth.cost
        self.fractionUsed = monthToDate.cost / budgetUSD
        self.projectedFraction = projectedMonth.cost / budgetUSD

        let strongestFraction = max(fractionUsed, projectedFraction)
        if strongestFraction >= 1 {
            self.state = .overBudget
        } else if strongestFraction >= 0.8 {
            self.state = .approaching
        } else if strongestFraction >= 0.5 {
            self.state = .halfUsed
        } else {
            self.state = .underBudget
        }
    }
}

public struct UsageAnalyticsIntelligence: Equatable, Hashable {
    public let daily: [UsageAnalyticsDailySummary]
    public let today: UsageAnalyticsPeriodTotals
    public let sevenDay: UsageAnalyticsPeriodTotals
    public let thirtyDay: UsageAnalyticsPeriodTotals
    public let monthToDate: UsageAnalyticsPeriodTotals
    public let projectedMonth: UsageAnalyticsPeriodTotals
    public let monthlyBudget: UsageMonthlyBudgetStatus?
    public let previousSevenDayAverage: UsageAnalyticsPeriodTotals
    public let topModels: [UsageAnalyticsModelSummary]
    public let insights: [UsageAnalyticsInsight]
    public let elapsedMonthDays: Int
    public let totalMonthDays: Int
    public let axisDates: [Date]

    public var hasCost: Bool {
        daily.contains { $0.cost > 0 } || today.cost > 0 || thirtyDay.cost > 0 || projectedMonth.cost > 0
    }

    public init(
        buckets: [UsageAnalyticsBucket],
        monthlyBudgetUSD: Double? = nil,
        now: Date = Date(),
        calendar: Calendar = .current
    ) {
        let usableBuckets = buckets.filter { $0.hasUsage && $0.startDate <= now }
        let dayStart = calendar.startOfDay(for: now)
        let sevenDayStart = calendar.date(byAdding: .day, value: -6, to: dayStart) ?? dayStart
        let thirtyDayStart = calendar.date(byAdding: .day, value: -29, to: dayStart) ?? dayStart
        let previousSevenDayStart = calendar.date(byAdding: .day, value: -7, to: dayStart) ?? dayStart
        let monthStart = calendar.date(from: calendar.dateComponents([.year, .month], from: now)) ?? dayStart
        let totalMonthDays = calendar.range(of: .day, in: .month, for: now)?.count ?? 30
        let elapsedMonthDays = min(
            max((calendar.dateComponents([.day], from: monthStart, to: dayStart).day ?? 0) + 1, 1),
            totalMonthDays
        )

        var dailyTotals: [Date: UsageAnalyticsPeriodTotals] = [:]
        var modelTotals: [String: UsageAnalyticsPeriodTotals] = [:]

        for bucket in usableBuckets where bucket.startDate >= thirtyDayStart {
            let day = calendar.startOfDay(for: bucket.startDate)
            var totals = dailyTotals[day] ?? UsageAnalyticsPeriodTotals()
            totals.add(bucket)
            dailyTotals[day] = totals

            if let model = bucket.model, bucket.totalTokens > 0 || bucket.requests > 0 || (bucket.costUSD ?? 0) > 0 {
                var modelTotal = modelTotals[model] ?? UsageAnalyticsPeriodTotals()
                modelTotal.add(bucket)
                modelTotals[model] = modelTotal
            }
        }

        let daily = dailyTotals
            .map { UsageAnalyticsDailySummary(date: $0.key, totals: $0.value) }
            .sorted { $0.date < $1.date }

        let today = Self.periodTotals(from: usableBuckets, since: dayStart)
        let sevenDay = Self.periodTotals(from: usableBuckets, since: sevenDayStart)
        let thirtyDay = Self.periodTotals(from: usableBuckets, since: thirtyDayStart)
        let monthToDate = Self.periodTotals(from: usableBuckets, since: monthStart)
        let projectedMonth = monthToDate.scaled(by: Double(totalMonthDays) / Double(elapsedMonthDays))
        let monthlyBudget = UsageMonthlyBudgetStatus(
            budgetUSD: monthlyBudgetUSD,
            monthToDate: monthToDate,
            projectedMonth: projectedMonth
        )

        let previousSevenBuckets = usableBuckets.filter {
            $0.startDate >= previousSevenDayStart && $0.startDate < dayStart
        }
        let previousSevenTotals = Self.periodTotals(from: previousSevenBuckets, since: previousSevenDayStart)
        let comparisonDays = Set(previousSevenBuckets.map { calendar.startOfDay(for: $0.startDate) })
        let comparisonDayCount = max(1, min(7, comparisonDays.count))
        let previousSevenDayAverage = previousSevenTotals.scaled(by: 1 / Double(comparisonDayCount))

        let maxTokens = max(modelTotals.values.map(\.tokens).max() ?? 0, 1)
        let totalModelTokens = max(modelTotals.values.reduce(0) { $0 + $1.tokens }, 1)
        let topModels = modelTotals
            .map {
                UsageAnalyticsModelSummary(
                    name: $0.key,
                    tokens: $0.value.tokens,
                    requests: $0.value.requests,
                    cost: $0.value.cost,
                    fractionOfMax: $0.value.tokens / maxTokens,
                    fractionOfTotal: $0.value.tokens / totalModelTokens
                )
            }
            .sorted {
                if $0.tokens == $1.tokens { return $0.name < $1.name }
                return $0.tokens > $1.tokens
            }

        self.daily = daily
        self.today = today
        self.sevenDay = sevenDay
        self.thirtyDay = thirtyDay
        self.monthToDate = monthToDate
        self.projectedMonth = projectedMonth
        self.monthlyBudget = monthlyBudget
        self.previousSevenDayAverage = previousSevenDayAverage
        self.topModels = topModels
        self.elapsedMonthDays = elapsedMonthDays
        self.totalMonthDays = totalMonthDays
        self.axisDates = Self.axisDates(for: daily, calendar: calendar)
        self.insights = Self.makeInsights(
            today: today,
            thirtyDay: thirtyDay,
            projectedMonth: projectedMonth,
            monthlyBudget: monthlyBudget,
            previousSevenDayAverage: previousSevenDayAverage,
            topModels: topModels,
            elapsedMonthDays: elapsedMonthDays
        )
    }

    private static func axisDates(for daily: [UsageAnalyticsDailySummary], calendar: Calendar) -> [Date] {
        guard let first = daily.first?.date, let last = daily.last?.date else { return [] }
        if calendar.isDate(first, inSameDayAs: last) {
            return [first]
        }
        return [first, last]
    }

    private static func periodTotals(
        from buckets: [UsageAnalyticsBucket],
        since startDate: Date
    ) -> UsageAnalyticsPeriodTotals {
        var totals = UsageAnalyticsPeriodTotals()
        for bucket in buckets where bucket.startDate >= startDate {
            totals.add(bucket)
        }
        return totals
    }

    private static func makeInsights(
        today: UsageAnalyticsPeriodTotals,
        thirtyDay: UsageAnalyticsPeriodTotals,
        projectedMonth: UsageAnalyticsPeriodTotals,
        monthlyBudget: UsageMonthlyBudgetStatus?,
        previousSevenDayAverage: UsageAnalyticsPeriodTotals,
        topModels: [UsageAnalyticsModelSummary],
        elapsedMonthDays: Int
    ) -> [UsageAnalyticsInsight] {
        var insights: [UsageAnalyticsInsight] = []

        if let monthlyBudget {
            insights.append(
                UsageAnalyticsInsight(
                    kind: .budgetStatus,
                    title: monthlyBudget.statusTitle,
                    message: monthlyBudget.insightMessage,
                    severity: monthlyBudget.severity
                )
            )
        }

        if projectedMonth.cost > 0 {
            let warningFloor = max(thirtyDay.cost * 1.35, thirtyDay.cost + 25)
            insights.append(
                UsageAnalyticsInsight(
                    kind: .projectedMonth,
                    title: "Projected month",
                    message: "At the current pace, this month lands near \(formattedMetricValue(projectedMonth.cost, unit: "$")) based on \(elapsedMonthDays) \(elapsedMonthDays == 1 ? "day" : "days") of usage.",
                    severity: projectedMonth.cost >= warningFloor ? .warning : .info
                )
            )
        } else if projectedMonth.tokens > 0 {
            insights.append(
                UsageAnalyticsInsight(
                    kind: .projectedMonth,
                    title: "Projected month",
                    message: "At the current pace, this month lands near \(projectedMonth.tokens.compactString) tokens.",
                    severity: .info
                )
            )
        }

        if today.cost > 0, previousSevenDayAverage.cost > 0 {
            let ratio = today.cost / previousSevenDayAverage.cost
            if ratio >= 1.5 && today.cost - previousSevenDayAverage.cost >= 1 {
                insights.append(
                    UsageAnalyticsInsight(
                        kind: .usageSpike,
                        title: "Today is above usual",
                        message: "Cost is \(Self.ratioText(ratio)) the recent daily average.",
                        severity: ratio >= 2.5 ? .critical : .warning
                    )
                )
            }
        } else if today.tokens > 0, previousSevenDayAverage.tokens > 0 {
            let ratio = today.tokens / previousSevenDayAverage.tokens
            if ratio >= 1.5 && today.tokens - previousSevenDayAverage.tokens >= 25_000 {
                insights.append(
                    UsageAnalyticsInsight(
                        kind: .usageSpike,
                        title: "Today is above usual",
                        message: "Tokens are \(Self.ratioText(ratio)) the recent daily average.",
                        severity: ratio >= 2.5 ? .critical : .warning
                    )
                )
            }
        }

        if let topModel = topModels.first, topModel.fractionOfTotal >= 0.5 {
            let percentage = Int((topModel.fractionOfTotal * 100).rounded())
            insights.append(
                UsageAnalyticsInsight(
                    kind: .topModel,
                    title: "Top model driver",
                    message: "\(topModel.name) accounts for \(percentage)% of 30-day token volume.",
                    severity: .info
                )
            )
        }

        return insights
    }

    private static func ratioText(_ ratio: Double) -> String {
        String(format: "%.1fx", ratio)
    }
}

// MARK: - Snapshot

public enum ProviderFetchState: String, Codable, Hashable {
    case success
    case error
    case notConfigured

    public nonisolated var isHealthy: Bool {
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
    public let analyticsBuckets: [UsageAnalyticsBucket]
    public let fetchState: ProviderFetchState
    public let fetchedAt: Date
    /// Provider-reported banked usage-limit resets, when the provider exposes them.
    public let resetCredits: QuotaResetCreditSummary?

    public var displayPlanName: String? {
        guard let name = planName, !name.isEmpty else { return nil }
        
        let parts = name.components(separatedBy: " / ")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.lowercased() != "free" }
        
        let cleaned = parts.joined(separator: " / ")
        return cleaned.isEmpty ? nil : cleaned
    }

    public var statsSectionTitle: String? {
        if stats.isEmpty { return nil }

        if providerID == .openai {
            return "Token Usage"
        }

        if providerID == .openaiAPI {
            return "API Usage"
        }

        if providerID == .codexTelemetry {
            return "Telemetry"
        }

        if providerID == .chatgpt {
            return "Local Activity"
        }

        if providerID == .devin {
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

        if providerID == .kimi {
            return "Membership Metadata"
        }

        if providerID == .mistral {
            return "Spend & Local Usage"
        }

        if providerID == .deepseek || providerID == .cerebras || providerID == .meta {
            return "Local Spend Estimate"
        }

        if providerID == .ollama {
            return "Usage & Cloud Quota"
        }

        return "Periodic Usage"
    }

    public var balancesSectionTitle: String? {
        guard !balances.isEmpty else { return nil }
        if providerID == .openai { return "Credits / Balance" }
        if providerID == .openaiAPI { return "API Costs" }
        if providerID == .kimi { return "Membership Quota" }
        if providerID == .deepseek || providerID == .cerebras || providerID == .meta { return "Credit Balance" }
        return "Extra Balance / Credits"
    }

    public var hasContent: Bool {
        !windows.isEmpty || !stats.isEmpty || !balances.isEmpty || !signals.isEmpty || !events.isEmpty
            || !analyticsBuckets.isEmpty
    }

    public var summaryWindows: [QuotaWindow] {
        guard providerID == .gemini else { return windows }

        var selected: [QuotaWindow] = []
        var selectedIDs = Set<UUID>()

        func normalized(_ label: String) -> String {
            label.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }

        func appendPreferred(exactLabel: String, fallbackMatches: (String) -> Bool) {
            if let exact = windows.first(where: { normalized($0.label) == normalized(exactLabel) }),
               selectedIDs.insert(exact.id).inserted {
                selected.append(exact)
                return
            }

            if let fallback = windows.first(where: { window in
                !selectedIDs.contains(window.id) && fallbackMatches(normalized(window.label))
            }) {
                selectedIDs.insert(fallback.id)
                selected.append(fallback)
            }
        }

        appendPreferred(exactLabel: "Pro 3.1 (preview)") { label in
            label.contains("pro") && !label.contains("flash")
        }
        appendPreferred(exactLabel: "Flash 3 (preview)") { label in
            label.contains("flash") && !label.contains("flash lite") && !label.contains("flash-lite")
        }
        appendPreferred(exactLabel: "Flash Lite 3.1 (preview)") { label in
            label.contains("flash lite") || label.contains("flash-lite")
        }

        return selected.isEmpty ? Array(windows.prefix(3)) : selected
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
            analyticsBuckets: analyticsBuckets,
            fetchState: fetchState,
            fetchedAt: fetchedAt,
            resetCredits: resetCredits
        )
    }

    /// Unions the signals a provider attached to this snapshot with signals
    /// the app's own cross-snapshot detector derived for the same provider.
    ///
    /// The two sources describe different things and both are legitimate: a
    /// provider signal reports something about the fetch that produced *this*
    /// snapshot (a stale local cache, a plan notice), while a detected signal
    /// reports a change observed *between* fetches. `withSignals` replaces,
    /// which silently discarded everything the provider supplied, so callers
    /// holding both lists must use this instead.
    ///
    /// Provider signals keep their original order and come first; detected
    /// signals are appended in the order given. A detected signal matching a
    /// provider signal on kind, window label, title and message is dropped as
    /// a duplicate — `QuotaSignal` is `Hashable` but carries a fresh `id` and
    /// its own `detectedAt`, so identity has to be compared on content.
    public func mergingSignals(_ detectedSignals: [QuotaSignal]) -> QuotaSnapshot {
        guard !detectedSignals.isEmpty else { return self }
        guard !signals.isEmpty else { return withSignals(detectedSignals) }

        var identities = Set(signals.map(QuotaSignalIdentity.init))
        var combined = signals
        for signal in detectedSignals where identities.insert(QuotaSignalIdentity(signal)).inserted {
            combined.append(signal)
        }

        return withSignals(combined)
    }

    public func withWindows(_ newWindows: [QuotaWindow]) -> QuotaSnapshot {
        QuotaSnapshot(
            id: id,
            providerID: providerID,
            displayName: displayName,
            planName: planName,
            windows: newWindows,
            stats: stats,
            balances: balances,
            signals: signals,
            events: events,
            analyticsBuckets: analyticsBuckets,
            fetchState: fetchState,
            fetchedAt: fetchedAt,
            resetCredits: resetCredits
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
            analyticsBuckets: analyticsBuckets,
            fetchState: fetchState,
            fetchedAt: fetchedAt,
            resetCredits: resetCredits
        )
    }

    public func withResetCredits(_ credits: QuotaResetCreditSummary?) -> QuotaSnapshot {
        QuotaSnapshot(
            id: id,
            providerID: providerID,
            displayName: displayName,
            planName: planName,
            windows: windows,
            stats: stats,
            balances: balances,
            signals: signals,
            events: events,
            analyticsBuckets: analyticsBuckets,
            fetchState: fetchState,
            fetchedAt: fetchedAt,
            resetCredits: credits
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
        case analyticsBuckets
        case fetchState
        case fetchedAt
        case resetCredits
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
        analyticsBuckets: [UsageAnalyticsBucket] = [],
        fetchState: ProviderFetchState = .success,
        fetchedAt: Date = Date(),
        resetCredits: QuotaResetCreditSummary? = nil
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
        self.analyticsBuckets = analyticsBuckets
        self.fetchState = fetchState
        self.fetchedAt = fetchedAt
        self.resetCredits = resetCredits
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
        analyticsBuckets = try container.decodeIfPresent([UsageAnalyticsBucket].self, forKey: .analyticsBuckets) ?? []

        // Resilient fetchState decoding
        if let stateString = try? container.decode(String.self, forKey: .fetchState) {
            fetchState = ProviderFetchState(rawValue: stateString) ?? .success
        } else {
            // Fallback for old associated-value format or missing key
            fetchState = .success
        }

        fetchedAt = try container.decodeIfPresent(Date.self, forKey: .fetchedAt) ?? Date()
        resetCredits = try? container.decodeIfPresent(QuotaResetCreditSummary.self, forKey: .resetCredits)
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

    /// Compact absolute reset timestamp suitable for the compact
    /// dashboard layout — "DD/MM HH:MM" in the user's local timezone.
    /// Reads dense-on-purpose so the whole row (label, reset, percent)
    /// fits on one line even on narrower windows.
    var absoluteResetString: String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar.current
        formatter.timeZone = TimeZone.current
        formatter.locale = Locale.current
        formatter.dateFormat = "dd/MM HH:mm"
        return formatter.string(from: self)
    }
}

public extension Double {
    var compactString: String {
        if self >= 1_000_000_000 {
            return String(format: "%.1fB", self / 1_000_000_000).replacingOccurrences(of: ".0", with: "")
        } else if self >= 1_000_000 {
            return String(format: "%.1fM", self / 1_000_000).replacingOccurrences(of: ".0", with: "")
        } else if self >= 1_000 {
            return String(format: "%.1fK", self / 1_000).replacingOccurrences(of: ".0", with: "")
        } else {
            return String(format: "%.0f", self)
        }
    }
}

public func formattedMetricValue(
    _ value: Double,
    unit: String,
    maximumFractionDigits: Int = 2
) -> String {
    let unitLower = unit.lowercased()
    switch unitLower {
    case "tokens", "tok":
        return "\(value.compactString) tokens"
    case "requests", "req":
        return "\(value.compactString) reqs"
    case "usd", "$":
        return "$\(adaptiveCurrencyNumber(value, maximumFractionDigits: maximumFractionDigits))"
    case "gbp", "£":
        return "£\(adaptiveCurrencyNumber(value, maximumFractionDigits: maximumFractionDigits))"
    case "eur", "€":
        return "€\(adaptiveCurrencyNumber(value, maximumFractionDigits: maximumFractionDigits))"
    case "msg", "msgs":
        return "\(value.compactString) msgs"
    case "hrs":
        return "\(value.compactString) hrs"
    case "credits":
        return "\(value.compactString) credits"
    case "":
        return value.compactString
    default:
        if Locale.commonISOCurrencyCodes.contains(unit.uppercased()) {
            return "\(adaptiveCurrencyNumber(value, maximumFractionDigits: maximumFractionDigits)) \(unit.uppercased())"
        }
        return "\(value.compactString) \(unit)"
    }
}

private func adaptiveCurrencyNumber(
    _ value: Double,
    maximumFractionDigits: Int
) -> String {
    let maximumDigits = min(max(maximumFractionDigits, 2), 6)
    guard maximumDigits > 2 else { return String(format: "%.2f", value) }

    let tolerance = 0.5 * pow(10, -Double(maximumDigits))
    let roundedToCents = (value * 100).rounded() / 100
    guard abs(value - roundedToCents) >= tolerance else {
        return String(format: "%.2f", value)
    }

    for digits in 3...maximumDigits {
        let scale = pow(10, Double(digits))
        let rounded = (value * scale).rounded() / scale
        if abs(value - rounded) < tolerance {
            return String(format: "%.*f", digits, value)
        }
    }
    return String(format: "%.*f", maximumDigits, value)
}
