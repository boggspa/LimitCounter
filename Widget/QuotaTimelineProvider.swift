import WidgetKit
import SwiftUI
import AppIntents

private struct WidgetLiquidGlassBackground: View {
    var body: some View {
        #if os(macOS)
        LiquidGlassBackdrop(style: .darkGlass)
        #else
        LiquidGlassBackdrop()
        #endif
    }
}

// MARK: - Timeline Entry

public struct QuotaWidgetEntry: TimelineEntry {
    public let date: Date
    public let snapshots: [QuotaSnapshot]
    public let allSnapshots: [QuotaSnapshot]
    public let allEvents: [UsageEvent]

    public static var placeholder: QuotaWidgetEntry {
        QuotaWidgetEntry(date: .now, snapshots: [MockData.claudeSnapshot], allSnapshots: MockData.allSnapshots, allEvents: [])
    }
}

// MARK: - Timeline Provider

public struct QuotaTimelineProvider: TimelineProvider {

    private let store = QuotaSnapshotStore.shared
    private let appGroupID = "group.com.chrisizatt.LLMUsageCounter"

    public func placeholder(in context: Context) -> QuotaWidgetEntry {
        .placeholder
    }

    public func getSnapshot(in context: Context, completion: @escaping (QuotaWidgetEntry) -> Void) {
        let rawSnapshots = context.isPreview ? MockData.allSnapshots : store.loadSnapshots()
        let snapshots = widgetSnapshots(from: rawSnapshots, at: .now)
        let events = rawSnapshots.flatMap(\.events).sorted { $0.timestamp > $1.timestamp }
        completion(QuotaWidgetEntry(date: .now, snapshots: snapshots, allSnapshots: rawSnapshots, allEvents: events))
    }

    public func getTimeline(in context: Context, completion: @escaping (Timeline<QuotaWidgetEntry>) -> Void) {
        let now = Date()
        let rawSnapshots = store.loadSnapshots()
        let snapshots = widgetSnapshots(from: rawSnapshots, at: now)
        let events = rawSnapshots.flatMap(\.events).sorted { $0.timestamp > $1.timestamp }
        let entry = QuotaWidgetEntry(date: now, snapshots: snapshots, allSnapshots: rawSnapshots, allEvents: events)

        // Refresh policy: at the next reset date, or in 15 min — whichever is sooner
        let nextReset = snapshots
            .flatMap(\.windows)
            .compactMap(\.resetDate)
            .filter { $0 > Date() }
            .min()

        let fifteenMinutes = Date().addingTimeInterval(900)
        let thirtyMinutes = Date().addingTimeInterval(1800)
        let nextUpdate = min(nextReset ?? thirtyMinutes, fifteenMinutes)

        let timeline = Timeline(entries: [entry], policy: .after(nextUpdate))
        completion(timeline)
    }

    private func widgetSnapshots(from snapshots: [QuotaSnapshot], at date: Date) -> [QuotaSnapshot] {
        let visible = filteredSnapshots(snapshots)

        // Find special cases like Codex (usage + telemetry are shown together in one card)
        let usageSnapshot = visible.first(where: { $0.providerID == .openai })
        let telemetrySnapshot = visible.first(where: { $0.providerID == .codexTelemetry })

        var items: [QuotaSnapshot] = []
        var consumed = Set<ProviderID>()

        // If usage is visible, show it and keep telemetry attached to it (rather than as a separate card).
        if let usage = usageSnapshot {
            items.append(usage)
            consumed.insert(.openai)
            if telemetrySnapshot != nil {
                consumed.insert(.codexTelemetry)
            }
        }

        for snap in visible where !consumed.contains(snap.providerID) {
            items.append(snap)
            consumed.insert(snap.providerID)
        }

        let ordered = items.sorted {
            ProviderCardOrderStore.nonisolatedRank(for: $0.providerID) < ProviderCardOrderStore.nonisolatedRank(for: $1.providerID)
        }

        guard ordered.count > 1 else { return ordered }

        let refreshBucket = max(Int(date.timeIntervalSinceReferenceDate / 900), 0)
        let offset = refreshBucket % ordered.count
        return Array(ordered[offset...]) + Array(ordered[..<offset])
    }

    private func filteredSnapshots(_ snapshots: [QuotaSnapshot]) -> [QuotaSnapshot] {
        let defaults = UserDefaults(suiteName: appGroupID) ?? .standard
        let stored = defaults.array(forKey: "hiddenProviderIDs") as? [String] ?? []
        let hidden = Set(stored.compactMap(ProviderID.init(rawValue:)))
        var visible = snapshots.filter { !hidden.contains($0.providerID) }

        // The Codex telemetry card is not meant to surface independently in the widget.
        // Keep it paired with usage only, matching dashboard behavior.
        if !visible.contains(where: { $0.providerID == .openai }) {
            visible.removeAll { $0.providerID == .codexTelemetry }
        }

        return visible
    }
}

// MARK: - Widget Entry View (dispatcher)

public struct QuotaWidgetEntryView: View {
    @Environment(\.widgetFamily) private var family
    let entry: QuotaWidgetEntry

    public init(entry: QuotaWidgetEntry) {
        self.entry = entry
    }

    public var body: some View {
        Group {
            switch family {
            case .systemSmall:
                smallView
            case .systemMedium:
                mediumView
            case .systemLarge:
                largeView
            #if os(iOS)
            case .accessoryCircular:
                accessoryCircularView
            case .accessoryRectangular:
                accessoryRectangularView
            case .accessoryInline:
                accessoryInlineView
            #endif
            default:
                smallView
            }
        }
        .preferredColorScheme(.dark)
    }

    #if os(iOS)
    private var accessoryCircularView: some View {
        Group {
            if let first = entry.snapshots.first,
               let window = first.windows.first {
                Gauge(value: window.fractionUsed) {
                    ProviderBrandIconView(providerID: first.providerID, size: 12)
                } currentValueLabel: {
                    Text(window.leadingValueText)
                        .font(.system(size: 10, weight: .bold))
                }
                .gaugeStyle(.accessoryCircular)
            } else {
                Image(systemName: "chart.bar.fill")
            }
        }
        .containerBackground(for: .widget) {
            Color.clear
        }
    }

    private var accessoryRectangularView: some View {
        let metrics = Array(lockScreenMetrics.prefix(2))

        return VStack(alignment: .leading, spacing: 2) {
            if let firstMetric = metrics.first {
                HStack(spacing: 4) {
                    ProviderBrandIconView(providerID: firstMetric.snapshot.providerID, size: 11)
                    Text(lockScreenTitle(for: metrics))
                        .font(.system(size: 11, weight: .bold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                }

                ForEach(metrics) { metric in
                    lockScreenMeterRow(metric)
                }
            }
        }
        .containerBackground(for: .widget) {
            Color.clear
        }
    }

    private struct LockScreenMetric: Identifiable {
        let id: String
        let snapshot: QuotaSnapshot
        let window: QuotaWindow
    }

    private var lockScreenMetrics: [LockScreenMetric] {
        entry.snapshots.flatMap { snapshot in
            snapshot.windows.map { window in
                LockScreenMetric(
                    id: "\(snapshot.providerID.rawValue)-\(window.id.uuidString)",
                    snapshot: snapshot,
                    window: window
                )
            }
        }
    }

    private func lockScreenMeterRow(_ metric: LockScreenMetric) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(compactLockScreenLabel(for: metric))
                    .font(.system(size: 10, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.65)

                Spacer(minLength: 4)

                if let resetText = compactResetText(for: metric.window) {
                    Text(resetText)
                        .font(.system(size: 8, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }

                Text(metric.window.leadingValueText)
                    .font(.system(size: 10, weight: .bold))
                    .lineLimit(1)
                    .monospacedDigit()
            }

            if metric.window.hasExplicitLimit {
                QuotaProgressBar(
                    fraction: metric.window.fractionUsed,
                    accentColor: Color(hex: metric.snapshot.providerID.accentColorHex),
                    height: 3
                )
            }
        }
    }

    private func lockScreenTitle(for metrics: [LockScreenMetric]) -> String {
        let providers = Set(metrics.map(\.snapshot.providerID))
        guard providers.count == 1, let first = metrics.first else {
            return "AI Usage"
        }
        return first.snapshot.displayName
    }

    private func compactLockScreenLabel(for metric: LockScreenMetric) -> String {
        var label = metric.window.label
        if metric.snapshot.providerID == .openai {
            label = label.replacingOccurrences(of: "GPT-5.3-Codex-Spark", with: "5.3 Spark")
            label = label.replacingOccurrences(of: "Codex Spark", with: "Spark")
            label = label.replacingOccurrences(of: " Weekly", with: " Wk")
        }
        return label
    }

    private func compactResetText(for window: QuotaWindow) -> String? {
        guard let resetDate = window.resetDate else { return nil }
        let text = resetDate.countdownString
        return text.hasPrefix("in ") ? String(text.dropFirst(3)) : text
    }

    private var accessoryInlineView: some View {
        Group {
            if let first = entry.snapshots.first,
               let window = first.windows.first {
                Text("\(first.displayName): \(window.leadingValueText)")
            } else {
                Text("AI Usage")
            }
        }
        .containerBackground(for: .widget) {
            Color.clear
        }
    }
    #endif

    private var smallView: some View {
        Group {
            if let first = entry.snapshots.first {
                QuotaCardSmallView(snapshot: first, style: .bare)
                    .padding(10)
            } else {
                emptyState
            }
        }
        .containerBackground(for: .widget) {
            WidgetLiquidGlassBackground()
        }
    }

    private var mediumView: some View {
        GeometryReader { geo in
            HStack(spacing: 0) {
                if let first = entry.snapshots.first {
                    QuotaCardSmallView(snapshot: first, style: .bare)
                        .padding(10)
                        .frame(maxWidth: .infinity)
                }

                if entry.snapshots.count > 1 {
                    Divider().overlay(Color.white.opacity(0.12))
                        .padding(.vertical, 8)

                    QuotaCardSmallView(snapshot: entry.snapshots[1], style: .bare)
                        .padding(10)
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .containerBackground(for: .widget) {
            WidgetLiquidGlassBackground()
        }
    }

    private var largeView: some View {
        GeometryReader { geo in
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    if entry.snapshots.count > 0 {
                        QuotaCardSmallView(snapshot: entry.snapshots[0], style: .bare)
                            .padding(10)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    if entry.snapshots.count > 1 {
                        Divider().overlay(Color.white.opacity(0.12))
                            .padding(.vertical, 12)
                        QuotaCardSmallView(snapshot: entry.snapshots[1], style: .bare)
                            .padding(10)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }

                if entry.snapshots.count > 2 {
                    Divider().overlay(Color.white.opacity(0.12))
                        .padding(.horizontal, 12)

                    HStack(spacing: 0) {
                        QuotaCardSmallView(snapshot: entry.snapshots[2], style: .bare)
                            .padding(10)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)

                        if entry.snapshots.count > 3 {
                            Divider().overlay(Color.white.opacity(0.12))
                                .padding(.vertical, 12)
                            QuotaCardSmallView(snapshot: entry.snapshots[3], style: .bare)
                                .padding(10)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    }
                }
            }
        }
        .containerBackground(for: .widget) {
            WidgetLiquidGlassBackground()
        }
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "chart.bar.fill")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text("Open app to configure")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .containerBackground(for: .widget) {
            WidgetLiquidGlassBackground()
        }
    }
}

// MARK: - Widget Definitions

public struct AIUsageWidget: Widget {
    public static let kind = "AIUsageWidget"

    public init() {}

    public var body: some WidgetConfiguration {
        StaticConfiguration(kind: Self.kind, provider: QuotaTimelineProvider()) { entry in
            QuotaWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("AI Usage - All Sizes")
        .description("Small (1), Medium (2), Large (4), or Lock Screen.")
        .supportedFamilies({
            #if os(iOS)
            return [.systemSmall, .systemMedium, .systemLarge, .accessoryCircular, .accessoryRectangular, .accessoryInline]
            #else
            return [.systemSmall, .systemMedium, .systemLarge]
            #endif
        }())
        .contentMarginsDisabled()
    }
}

public struct AIUsageWidgetSingle: Widget {
    public static let kind = "AIUsageWidgetSingle"

    public init() {}

    public var body: some WidgetConfiguration {
        StaticConfiguration(kind: Self.kind, provider: QuotaTimelineProvider()) { entry in
            SingleProviderWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("AI Usage - Single")
        .description("One provider in Medium or Large size.")
        .supportedFamilies([.systemMedium, .systemLarge])
        .contentMarginsDisabled()
    }
}

public struct AIUsageWidgetDouble: Widget {
    public static let kind = "AIUsageWidgetDouble"

    public init() {}

    public var body: some WidgetConfiguration {
        StaticConfiguration(kind: Self.kind, provider: QuotaTimelineProvider()) { entry in
            DoubleProviderWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("AI Usage - Double")
        .description("Two providers side-by-side in Medium or Large.")
        .supportedFamilies([.systemMedium, .systemLarge])
        .contentMarginsDisabled()
    }
}

public struct AIUsageWidgetWide: Widget {
    public static let kind = "AIUsageWidgetWide"

    public init() {}

    public var body: some WidgetConfiguration {
        StaticConfiguration(kind: Self.kind, provider: QuotaTimelineProvider()) { entry in
            WideWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("AI Usage - Wide")
        .description("Large 2x4 grid showing up to 8 providers.")
        .supportedFamilies([.systemLarge])
        .contentMarginsDisabled()
    }
}

// MARK: - Single Provider Entry View

public struct SingleProviderWidgetEntryView: View {
    @Environment(\.widgetFamily) private var family
    let entry: QuotaWidgetEntry

    public init(entry: QuotaWidgetEntry) {
        self.entry = entry
    }

    private var telemetrySnapshot: QuotaSnapshot? {
        entry.allSnapshots.first(where: { $0.providerID == .codexTelemetry })
    }

    public var body: some View {
        Group {
            if let first = entry.snapshots.first(where: { $0.providerID != .codexTelemetry }) {
                switch family {
                case .systemMedium:
                    QuotaCardSmallView(snapshot: first, style: .bare)
                        .padding(10)
                case .systemLarge:
                    LargeSingleProviderView(
                        snapshot: first,
                        telemetrySnapshot: first.providerID == .openai ? telemetrySnapshot : nil,
                        style: .bare
                    )
                    .padding(10)
                default:
                    QuotaCardSmallView(snapshot: first, style: .bare)
                        .padding(10)
                }
            } else if let first = entry.snapshots.first {
                // If only telemetry is available for some reason
                QuotaCardSmallView(snapshot: first, style: .bare)
                    .padding(10)
            } else {
                emptyState
            }
        }
        .containerBackground(for: .widget) {
            WidgetLiquidGlassBackground()
        }
        .preferredColorScheme(.dark)
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "chart.bar.fill")
                .font(.title2)
                .foregroundStyle(.white)
            Text("Open app to configure")
                .font(.caption)
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Large single provider view with bigger text
public struct LargeSingleProviderView: View {
    let snapshot: QuotaSnapshot
    var telemetrySnapshot: QuotaSnapshot? = nil
    var style: AppChromeStyle = .panel

    private var accent: Color { Color(hex: snapshot.providerID.accentColorHex) }
    private var windows: [QuotaWindow] { Array(snapshot.windows.prefix(4)) }

    public var body: some View {
        GlassCardContainer(style: style, accent: accent, cornerRadius: 16) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    ProviderBrandIconView(providerID: snapshot.providerID, size: 28)
                    ProviderCardTitleText(title: snapshot.displayName, accentColor: accent)
                    Spacer()
                    if let plan = snapshot.planName {
                        Text(plan)
                            .font(.caption.weight(.bold))
                            .foregroundStyle(accent)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(accent.opacity(0.12), in: Capsule(style: .continuous))
                    }
                }

                if !windows.isEmpty {
                    VStack(spacing: 10) {
                        ForEach(windows) { window in
                            largeWindowView(window)
                        }
                    }
                } else {
                    Text("No usage data available")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 20)
                }

                if let telemetrySnapshot, !telemetrySnapshot.stats.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(telemetrySnapshot.statsSectionTitle ?? "Telemetry")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.secondary)
                            .textCase(.uppercase)

                        VStack(spacing: 4) {
                            ForEach(telemetrySnapshot.stats.prefix(2)) { stat in
                                HStack {
                                    Text(stat.label)
                                        .font(.caption.weight(.medium))
                                        .foregroundStyle(.primary)
                                    Spacer()
                                    Text(stat.valueText)
                                        .font(.caption.weight(.bold))
                                        .foregroundStyle(accent)
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                            }
                        }
                    }
                    .padding(.top, 4)
                }

                Spacer(minLength: 0)

                HStack {
                    Spacer()
                    Text("Updated \(snapshot.fetchedAt.relativeString)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(6)
        }
    }

    private func largeWindowView(_ window: QuotaWindow) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(window.label)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)

                Spacer(minLength: 6)

                if let resetText = compactResetText(for: window) {
                    Text(resetText)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }

                Text(window.leadingValueText)
                    .font(.title3.weight(.bold))
                    .foregroundStyle(usageColor(for: window.fractionUsed, accentColor: accent))
                    .lineLimit(1)
                    .monospacedDigit()
            }

            if window.hasExplicitLimit {
                QuotaProgressBar(fraction: window.fractionUsed, accentColor: accent, height: 8)
            }

            Text(window.measurementSummary)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private func compactResetText(for window: QuotaWindow) -> String? {
        guard let resetDate = window.resetDate else { return nil }
        let text = resetDate.countdownString
        return text.hasPrefix("in ") ? String(text.dropFirst(3)) : text
    }
}

// MARK: - Double Provider Entry View

public struct DoubleProviderWidgetEntryView: View {
    @Environment(\.widgetFamily) private var family
    let entry: QuotaWidgetEntry

    public init(entry: QuotaWidgetEntry) {
        self.entry = entry
    }

    public var body: some View {
        HStack(spacing: 0) {
            if entry.snapshots.count > 0 {
                QuotaCardSmallView(snapshot: entry.snapshots[0], style: .bare)
                    .padding(10)
                    .frame(maxWidth: .infinity)
            }

            if entry.snapshots.count > 1 {
                Divider().overlay(Color.white.opacity(0.12))
                    .padding(.vertical, 12)

                QuotaCardSmallView(snapshot: entry.snapshots[1], style: .bare)
                    .padding(10)
                    .frame(maxWidth: .infinity)
            } else if entry.snapshots.count == 1 {
                Color.clear
                    .frame(maxWidth: .infinity)
            }
        }
        .containerBackground(for: .widget) {
            WidgetLiquidGlassBackground()
        }
        .preferredColorScheme(.dark)
    }
}

// MARK: - Wide Widget Entry View (2x4 grid for up to 8 providers)

public struct WideWidgetEntryView: View {
    let entry: QuotaWidgetEntry

    public init(entry: QuotaWidgetEntry) {
        self.entry = entry
    }

    public var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ForEach(0..<4) { index in
                    if entry.snapshots.count > index {
                        QuotaCardSmallView(snapshot: entry.snapshots[index], style: .bare)
                            .padding(8)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)

                        if index < 3 {
                            Divider().overlay(Color.white.opacity(0.12))
                                .padding(.vertical, 8)
                        }
                    } else {
                        Color.clear
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        if index < 3 {
                            Spacer().frame(width: 1)
                        }
                    }
                }
            }

            if entry.snapshots.count > 4 {
                Divider().overlay(Color.white.opacity(0.12))
                    .padding(.horizontal, 8)

                HStack(spacing: 0) {
                    ForEach(4..<8) { index in
                        if entry.snapshots.count > index {
                            QuotaCardSmallView(snapshot: entry.snapshots[index], style: .bare)
                                .padding(8)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)

                            if index < 7 {
                                Divider().overlay(Color.white.opacity(0.12))
                                    .padding(.vertical, 8)
                            }
                        } else {
                            Color.clear
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                            if index < 7 {
                                Spacer().frame(width: 1)
                            }
                        }
                    }
                }
            }
        }
        .padding(8)
        .containerBackground(for: .widget) {
            WidgetLiquidGlassBackground()
        }
        .preferredColorScheme(.dark)
    }
}

// MARK: - Control Center Support (iOS 18+)

@available(iOS 18.0, macOS 15.0, *)
public struct AIUsageControl: ControlWidget {
    public static let kind = "AIUsageControl"

    public init() {}

    public var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: Self.kind) {
            ControlWidgetButton(action: OpenAppIntent()) {
                Label("AI Usage", systemImage: "chart.bar.fill")
            }
        }
        .displayName("AI Usage")
        .description("Quickly open AI Usage to check quotas.")
    }
}

public struct OpenAppIntent: ControlConfigurationIntent {
    public static let title: LocalizedStringResource = "Open AI Usage"
    public static let isDiscoverable = true
    public static let opensApp = true

    public init() {}

    public func perform() async throws -> some IntentResult {
        .result()
    }
}

// MARK: - App Entities for Configuration

@available(iOS 16.0, macOS 13.0, *)
public struct ProviderEntity: AppEntity {
    public let id: String
    public let displayName: String

    public static var typeDisplayRepresentation: TypeDisplayRepresentation = "Provider"
    public static var defaultQuery = ProviderQuery()

    public var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(displayName)")
    }

    public init(id: String, displayName: String) {
        self.id = id
        self.displayName = displayName
    }
}

@available(iOS 16.0, macOS 13.0, *)
public struct ProviderQuery: EntityQuery {
    public init() {}

    public func entities(for identifiers: [String]) async throws -> [ProviderEntity] {
        let store = QuotaSnapshotStore.shared
        let snapshots = store.loadSnapshots()
        return snapshots
            .filter { identifiers.contains($0.providerID.rawValue) }
            .map { ProviderEntity(id: $0.providerID.rawValue, displayName: $0.displayName) }
    }

    public func suggestedEntities() async throws -> [ProviderEntity] {
        let store = QuotaSnapshotStore.shared
        return store.loadSnapshots()
            .map { ProviderEntity(id: $0.providerID.rawValue, displayName: $0.displayName) }
    }
}

@available(iOS 16.0, macOS 13.0, *)
public struct QuotaWindowEntity: AppEntity {
    public let id: String
    public let displayName: String
    public let providerID: String

    public static var typeDisplayRepresentation: TypeDisplayRepresentation = "Quota Window"
    public static var defaultQuery = QuotaWindowQuery()

    public var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(displayName)")
    }

    public init(id: String, displayName: String, providerID: String) {
        self.id = id
        self.displayName = displayName
        self.providerID = providerID
    }
}

@available(iOS 16.0, macOS 13.0, *)
public struct QuotaWindowQuery: EntityQuery {
    public init() {}

    public func entities(for identifiers: [String]) async throws -> [QuotaWindowEntity] {
        let store = QuotaSnapshotStore.shared
        let snapshots = store.loadSnapshots()
        var results: [QuotaWindowEntity] = []
        for snapshot in snapshots {
            for window in snapshot.windows {
                let compositeID = "\(snapshot.providerID.rawValue):\(window.label)"
                if identifiers.contains(compositeID) {
                    results.append(QuotaWindowEntity(id: compositeID, displayName: "\(snapshot.displayName): \(window.label)", providerID: snapshot.providerID.rawValue))
                }
            }
        }
        return results
    }

    public func suggestedEntities() async throws -> [QuotaWindowEntity] {
        let store = QuotaSnapshotStore.shared
        let snapshots = store.loadSnapshots()
        var results: [QuotaWindowEntity] = []
        for snapshot in snapshots {
            for window in snapshot.windows {
                let compositeID = "\(snapshot.providerID.rawValue):\(window.label)"
                results.append(QuotaWindowEntity(id: compositeID, displayName: "\(snapshot.displayName): \(window.label)", providerID: snapshot.providerID.rawValue))
            }
        }
        return results
    }
}

@available(iOS 16.0, macOS 13.0, *)
public struct SelectQuotaIntent: WidgetConfigurationIntent {
    public static var title: LocalizedStringResource = "Custom Dashboard"
    public static var description = IntentDescription("Cherry-pick specific models or windows to monitor.")

    @Parameter(title: "Selected Metrics")
    public var metrics: [QuotaWindowEntity]?

    public init() {}

    public static var parameterSummary: some ParameterSummary {
        Summary("Show \(\.$metrics)")
    }
}

// MARK: - Configurable Selective Provider

@available(iOS 16.0, macOS 13.0, *)
public struct SelectQuotaTimelineProvider: AppIntentTimelineProvider {
    private let store = QuotaSnapshotStore.shared

    public func placeholder(in context: Context) -> QuotaWidgetEntry {
        .placeholder
    }

    public func snapshot(for configuration: SelectQuotaIntent, in context: Context) async -> QuotaWidgetEntry {
        let snapshots = store.loadSnapshots()
        let filtered = filteredSnapshots(snapshots, for: configuration)
        let events = snapshots.flatMap(\.events).sorted { $0.timestamp > $1.timestamp }
        return QuotaWidgetEntry(date: .now, snapshots: filtered, allSnapshots: snapshots, allEvents: events)
    }

    public func timeline(for configuration: SelectQuotaIntent, in context: Context) async -> Timeline<QuotaWidgetEntry> {
        let snapshots = store.loadSnapshots()
        let filtered = filteredSnapshots(snapshots, for: configuration)
        let events = snapshots.flatMap(\.events).sorted { $0.timestamp > $1.timestamp }
        let entry = QuotaWidgetEntry(date: .now, snapshots: filtered, allSnapshots: snapshots, allEvents: events)

        return Timeline(entries: [entry], policy: .after(.now.addingTimeInterval(900)))
    }

    private func filteredSnapshots(_ snapshots: [QuotaSnapshot], for configuration: SelectQuotaIntent) -> [QuotaSnapshot] {
        guard let selectedMetrics = configuration.metrics, !selectedMetrics.isEmpty else {
            // Default behavior if nothing selected: show first few providers
            return Array(snapshots.prefix(4))
        }

        var results: [QuotaSnapshot] = []

        for metric in selectedMetrics {
            let components = metric.id.split(separator: ":")
            guard components.count >= 2 else { continue }

            let providerID = String(components[0])
            let windowLabel = String(components[1])

            if let snapshot = snapshots.first(where: { $0.providerID.rawValue == providerID }),
               let targetWindow = snapshot.windows.first(where: { $0.label == windowLabel }) {

                // Create a single-window snapshot for this specific metric
                let synthetic = QuotaSnapshot(
                    id: UUID(), // unique for this widget instance
                    providerID: snapshot.providerID,
                    displayName: snapshot.displayName,
                    planName: snapshot.planName,
                    windows: [targetWindow],
                    stats: [],
                    balances: [],
                    signals: [],
                    fetchState: snapshot.fetchState,
                    fetchedAt: snapshot.fetchedAt
                )
                results.append(synthetic)
            }
        }

        return results
    }
}

// MARK: - Selective Widget Definition

public struct SelectQuotaWidget: Widget {
    public static let kind = "SelectQuotaWidget"

    public init() {}

    public var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: Self.kind, intent: SelectQuotaIntent.self, provider: SelectQuotaTimelineProvider()) { entry in
            QuotaWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("Custom Dashboard")
        .description("Choose exactly which models and metrics to show (e.g., Gemini Pro, Codex Weekly).")
        .supportedFamilies({
            #if os(iOS)
            return [.accessoryCircular, .accessoryRectangular, .accessoryInline, .systemSmall, .systemMedium, .systemLarge]
            #else
            return [.systemSmall, .systemMedium, .systemLarge]
            #endif
        }())
    }
}

// MARK: - Widget Bundle

@main
public struct AIUsageTrackerWidgetBundle: WidgetBundle {
    public init() {}

    public var body: some Widget {
        AIUsageWidget()
        SelectQuotaWidget()
        AIUsageWidgetSingle()
        AIUsageWidgetDouble()
        AIUsageWidgetWide()
        if #available(iOS 18.0, macOS 15.0, *) {
            AIUsageControl()
        }
    }
}

// MARK: - Preview

struct AIUsageWidget_Previews: PreviewProvider {
    static var previews: some View {
        Group {
            QuotaWidgetEntryView(
                entry: QuotaWidgetEntry(date: .now, snapshots: [MockData.claudeSnapshot], allSnapshots: MockData.allSnapshots, allEvents: [])
            )
            .previewContext(WidgetPreviewContext(family: .systemSmall))

            QuotaWidgetEntryView(
                entry: QuotaWidgetEntry(date: .now, snapshots: MockData.allSnapshots, allSnapshots: MockData.allSnapshots, allEvents: [])
            )
            .previewContext(WidgetPreviewContext(family: .systemMedium))

            QuotaWidgetEntryView(
                entry: QuotaWidgetEntry(date: .now, snapshots: MockData.allSnapshots, allSnapshots: MockData.allSnapshots, allEvents: [])
            )
            .previewContext(WidgetPreviewContext(family: .systemLarge))

            SingleProviderWidgetEntryView(
                entry: QuotaWidgetEntry(date: .now, snapshots: [MockData.codexSnapshot], allSnapshots: MockData.allSnapshots, allEvents: [])
            )
            .previewContext(WidgetPreviewContext(family: .systemMedium))

            SingleProviderWidgetEntryView(
                entry: QuotaWidgetEntry(date: .now, snapshots: [MockData.codexSnapshot], allSnapshots: MockData.allSnapshots, allEvents: [])
            )
            .previewContext(WidgetPreviewContext(family: .systemLarge))

            DoubleProviderWidgetEntryView(
                entry: QuotaWidgetEntry(date: .now, snapshots: Array(MockData.allSnapshots.prefix(2)), allSnapshots: MockData.allSnapshots, allEvents: [])
            )
            .previewContext(WidgetPreviewContext(family: .systemMedium))

            DoubleProviderWidgetEntryView(
                entry: QuotaWidgetEntry(date: .now, snapshots: Array(MockData.allSnapshots.prefix(2)), allSnapshots: MockData.allSnapshots, allEvents: [])
            )
            .previewContext(WidgetPreviewContext(family: .systemLarge))

            WideWidgetEntryView(
                entry: QuotaWidgetEntry(date: .now, snapshots: MockData.allSnapshots + MockData.allSnapshots, allSnapshots: MockData.allSnapshots + MockData.allSnapshots, allEvents: [])
            )
            .previewContext(WidgetPreviewContext(family: .systemLarge))
        }
    }
}
