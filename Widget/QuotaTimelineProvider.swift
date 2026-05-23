import WidgetKit
import SwiftUI
import AppIntents

private struct WidgetLiquidGlassBackground: View {
    var body: some View {
        #if os(macOS)
        LiquidGlassBackdrop(style: .darkGlass, intensity: .widget)
        #else
        LiquidGlassBackdrop(intensity: .widget)
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

        // Refresh policy: at the next reset date, or at the user-requested widget cadence.
        let nextReset = snapshots
            .flatMap(\.windows)
            .compactMap(\.resetDate)
            .filter { $0 > Date() }
            .min()

        let requestedRefresh = Date().addingTimeInterval(UsageRefreshCadence.requestedRefreshInterval)
        let nextUpdate = min(nextReset ?? requestedRefresh, requestedRefresh)

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
               let window = first.summaryWindows.first {
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
            snapshot.summaryWindows.map { window in
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
                    height: 3,
                    pace: metric.window.pace(providerID: metric.snapshot.providerID)
                )
            }
        }
    }

    private func lockScreenTitle(for metrics: [LockScreenMetric]) -> String {
        let providers = Set(metrics.map(\.snapshot.providerID))
        guard providers.count == 1, let first = metrics.first else {
            return "Limit Counter"
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
               let window = first.summaryWindows.first {
                Text("\(first.displayName): \(window.leadingValueText)")
            } else {
                Text("Limit Counter")
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
        .configurationDisplayName("Limit Counter - All Sizes")
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
        .configurationDisplayName("Limit Counter - Single")
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
        .configurationDisplayName("Limit Counter - Double")
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
        .configurationDisplayName("Limit Counter - Wide")
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
    private var windows: [QuotaWindow] { Array(snapshot.summaryWindows.prefix(4)) }

    public var body: some View {
        GlassCardContainer(style: style, accent: accent, cornerRadius: 16) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    ProviderBrandIconView(providerID: snapshot.providerID, size: 28)
                    VStack(alignment: .leading, spacing: 1) {
                        ProviderCardTitleText(title: snapshot.displayName, accentColor: accent)
                        Text("Updated \(snapshot.fetchedAt.relativeString)")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.78)
                    }
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
                QuotaProgressBar(
                    fraction: window.fractionUsed,
                    accentColor: accent,
                    height: 8,
                    pace: window.pace(providerID: snapshot.providerID)
                )
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

// MARK: - Activity Heatmap Widget

public struct ActivityHeatmapWidgetEntryView: View {
    @Environment(\.widgetFamily) private var family
    let entry: QuotaWidgetEntry

    public init(entry: QuotaWidgetEntry) {
        self.entry = entry
    }

    public var body: some View {
        Group {
            switch family {
            case .systemSmall:
                systemHeatmapView(columns: 14, rows: 6, showsSubtitle: false)
            case .systemMedium:
                systemHeatmapView(columns: 21, rows: 8, showsSubtitle: true)
            case .systemLarge:
                systemHeatmapView(columns: 30, rows: 12, showsSubtitle: true)
            #if os(iOS)
            case .accessoryCircular:
                accessoryCircularView
            case .accessoryRectangular:
                accessoryRectangularView
            case .accessoryInline:
                accessoryInlineView
            #endif
            default:
                systemHeatmapView(columns: 14, rows: 6, showsSubtitle: false)
            }
        }
        .preferredColorScheme(.dark)
    }

    private func systemHeatmapView(columns: Int, rows: Int, showsSubtitle: Bool) -> some View {
        VStack(alignment: .leading, spacing: showsSubtitle ? 8 : 6) {
            systemHeader(columns: columns, showsSubtitle: showsSubtitle)

            ActivityHeatmapGrid(
                snapshots: entry.snapshots,
                columns: columns,
                rows: rows
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(showsSubtitle ? 14 : 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .containerBackground(for: .widget) {
            WidgetLiquidGlassBackground()
        }
    }

    private func systemHeader(columns: Int, showsSubtitle: Bool) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: ProviderID.heatmap.iconName)
                .font(.system(size: showsSubtitle ? 16 : 13, weight: .bold))
                .foregroundStyle(ProGlassTheme.accent)

            VStack(alignment: .leading, spacing: 1) {
                Text("Activity")
                    .font(showsSubtitle ? .headline.weight(.bold) : .caption.weight(.bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)

                if showsSubtitle {
                    Text("Last \(columns) days")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 6)

            Text(todaySummary)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(ProGlassTheme.accent)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
    }

    #if os(iOS)
    private var accessoryCircularView: some View {
        Gauge(value: todayGaugeValue) {
            Image(systemName: ProviderID.heatmap.iconName)
        } currentValueLabel: {
            Text(shortTodayValue)
                .font(.system(size: 10, weight: .bold))
                .minimumScaleFactor(0.7)
        }
        .gaugeStyle(.accessoryCircular)
        .containerBackground(for: .widget) {
            Color.clear
        }
    }

    private var accessoryRectangularView: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Image(systemName: ProviderID.heatmap.iconName)
                    .font(.system(size: 10, weight: .bold))

                Text("Activity")
                    .font(.system(size: 11, weight: .bold))
                    .lineLimit(1)

                Spacer(minLength: 4)

                Text(shortTodayValue)
                    .font(.system(size: 10, weight: .bold))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }

            ActivityHeatmapGrid(
                snapshots: entry.snapshots,
                columns: 12,
                rows: 4,
                cellSpacing: 1
            )
            .frame(height: 22)
        }
        .containerBackground(for: .widget) {
            Color.clear
        }
    }

    private var accessoryInlineView: some View {
        Text("Activity \(todaySummary)")
    }
    #endif

    private var dedupedEvents: [UsageEvent] {
        var seen = Set<UUID>()
        return entry.snapshots
            .flatMap(\.events)
            .filter { seen.insert($0.id).inserted }
    }

    private var todayEvents: [UsageEvent] {
        let startOfToday = Calendar.current.startOfDay(for: Date())
        return dedupedEvents.filter { $0.timestamp >= startOfToday }
    }

    private var todayTokens: Double {
        todayEvents.compactMap(\.tokens).reduce(0, +)
    }

    private var todaySummary: String {
        if todayTokens > 0 {
            return "\(todayTokens.compactString) today"
        }

        if !todayEvents.isEmpty {
            return "\(todayEvents.count) today"
        }

        return "No activity"
    }

    private var shortTodayValue: String {
        if todayTokens > 0 {
            return todayTokens.compactString
        }

        return "\(todayEvents.count)"
    }

    private var todayGaugeValue: Double {
        if todayTokens > 0 {
            return min(todayTokens / 10_000, 1)
        }

        return min(Double(todayEvents.count) / 24, 1)
    }
}

private struct ActivityHeatmapGrid: View {
    let columns: Int
    let rows: Int
    let cellSpacing: CGFloat

    private let referenceDayStart: Date
    private let bucketMap: [ActivityHeatmapBucketKey: [UsageEvent]]
    private let providerByEventID: [UUID: ProviderID]

    init(
        snapshots: [QuotaSnapshot],
        columns: Int,
        rows: Int,
        cellSpacing: CGFloat = 2
    ) {
        self.columns = columns
        self.rows = rows
        self.cellSpacing = cellSpacing

        let calendar = Calendar.current
        let referenceDayStart = calendar.startOfDay(for: Date())
        self.referenceDayStart = referenceDayStart

        let cutoff = calendar.date(byAdding: .day, value: -(columns - 1), to: referenceDayStart) ?? referenceDayStart
        var seen = Set<UUID>()
        var events: [UsageEvent] = []
        var providerByEventID: [UUID: ProviderID] = [:]

        for snapshot in snapshots {
            let providerID = snapshot.providerID == .codexTelemetry ? ProviderID.openai : snapshot.providerID

            for event in snapshot.events where event.timestamp >= cutoff {
                providerByEventID[event.id] = providerID
                if seen.insert(event.id).inserted {
                    events.append(event)
                }
            }
        }

        self.providerByEventID = providerByEventID
        self.bucketMap = Dictionary(grouping: events) { event in
            Self.bucketKey(for: event.timestamp, rows: rows, calendar: calendar)
        }
    }

    var body: some View {
        GeometryReader { proxy in
            let cellWidth = max(2, (proxy.size.width - CGFloat(columns - 1) * cellSpacing) / CGFloat(columns))
            let cellHeight = max(2, (proxy.size.height - CGFloat(rows - 1) * cellSpacing) / CGFloat(rows))
            let cellSize = min(cellWidth, cellHeight)

            HStack(alignment: .top, spacing: cellSpacing) {
                ForEach(0..<columns, id: \.self) { column in
                    VStack(spacing: cellSpacing) {
                        ForEach(0..<rows, id: \.self) { row in
                            heatmapCell(events: eventsFor(column: column, row: row))
                                .frame(width: cellSize, height: cellSize)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
    }

    private func dateFor(column: Int) -> Date {
        Calendar.current.date(
            byAdding: .day,
            value: -(columns - 1 - column),
            to: referenceDayStart
        ) ?? referenceDayStart
    }

    private func eventsFor(column: Int, row: Int) -> [UsageEvent] {
        let dayStart = Calendar.current.startOfDay(for: dateFor(column: column))
        return bucketMap[ActivityHeatmapBucketKey(dayStart: dayStart, row: row)] ?? []
    }

    private func heatmapCell(events: [UsageEvent]) -> some View {
        RoundedRectangle(cornerRadius: 1.8, style: .continuous)
            .fill(colorForEvents(events).opacity(intensityForEvents(events)))
            .overlay(
                RoundedRectangle(cornerRadius: 1.8, style: .continuous)
                    .stroke(Color.white.opacity(events.isEmpty ? 0.025 : 0.10), lineWidth: 0.4)
            )
    }

    private func intensityForEvents(_ events: [UsageEvent]) -> Double {
        guard !events.isEmpty else { return 0.08 }

        let tokenTotal = events.compactMap(\.tokens).reduce(0, +)
        if tokenTotal > 0 {
            if tokenTotal < 100 { return 0.35 }
            if tokenTotal < 500 { return 0.50 }
            if tokenTotal < 2_000 { return 0.72 }
            return 1.0
        }

        if events.count < 2 { return 0.28 }
        if events.count < 4 { return 0.46 }
        if events.count < 8 { return 0.66 }
        return 0.90
    }

    private func colorForEvents(_ events: [UsageEvent]) -> Color {
        guard !events.isEmpty else { return Color.white.opacity(0.28) }

        var providerWeights: [ProviderID: Double] = [:]

        for event in events {
            let provider = providerByEventID[event.id] ?? guessProviderFromModel(event.model)
            let weight = event.tokens ?? 100

            if let provider {
                providerWeights[provider, default: 0] += weight
            }
        }

        guard !providerWeights.isEmpty else { return ProGlassTheme.accent }

        let sorted = providerWeights.sorted { $0.value > $1.value }
        let primary = Color(hex: sorted[0].key.accentColorHex)
        return primary
    }

    private func guessProviderFromModel(_ model: String?) -> ProviderID? {
        guard let model = model?.lowercased() else { return nil }
        if model.contains("claude") { return .claude }
        if model.contains("gemini") { return .gemini }
        if model.contains("codex") { return .openai }
        if model.contains("gpt") { return .chatgpt }
        if model.contains("kimi") { return .kimi }
        if model.contains("cursor") { return .cursor }
        if model.contains("windsurf") { return .windsurf }
        return nil
    }

    private static func bucketKey(for date: Date, rows: Int, calendar: Calendar) -> ActivityHeatmapBucketKey {
        let dayStart = calendar.startOfDay(for: date)
        let hour = calendar.component(.hour, from: date)
        let row = max(0, min(rows - 1, hour * rows / 24))
        return ActivityHeatmapBucketKey(dayStart: dayStart, row: row)
    }
}

private struct ActivityHeatmapBucketKey: Hashable {
    let dayStart: Date
    let row: Int
}

public struct AIUsageHeatmapWidget: Widget {
    public static let kind = "AIUsageHeatmapWidget"

    public init() {}

    public var body: some WidgetConfiguration {
        StaticConfiguration(kind: Self.kind, provider: QuotaTimelineProvider()) { entry in
            ActivityHeatmapWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("Limit Counter - Activity")
        .description("Activity heatmap for recent local and synced usage.")
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

#if os(iOS)
// MARK: - Lock Screen Meter Stack Widget

public enum LockScreenMeterMode: String, AppEnum {
    case session5h
    case weekly

    public static var typeDisplayRepresentation: TypeDisplayRepresentation = "Meter Group"
    public static var caseDisplayRepresentations: [LockScreenMeterMode: DisplayRepresentation] = [
        .session5h: "5H",
        .weekly: "Weekly"
    ]

    var title: String {
        switch self {
        case .session5h:
            return "5H"
        case .weekly:
            return "Weekly"
        }
    }

    var shortTag: String {
        switch self {
        case .session5h:
            return "5H"
        case .weekly:
            return "W"
        }
    }
}

public struct LockScreenMetersIntent: WidgetConfigurationIntent {
    public static var title: LocalizedStringResource = "Meter Stack"
    public static var description = IntentDescription("Show a compact 5H or weekly quota stack on the Lock Screen.")

    @Parameter(title: "Meters")
    public var mode: LockScreenMeterMode?

    @Parameter(title: "Fill Weekly with Codex Submeters")
    public var fillWithCodexSubmeters: Bool?

    public init() {
        self.mode = .session5h
        self.fillWithCodexSubmeters = true
    }

    public static var parameterSummary: some ParameterSummary {
        Summary("Show \(\.$mode)")
    }
}

public struct LockScreenMetersEntry: TimelineEntry {
    public let date: Date
    public let mode: LockScreenMeterMode
    public let rows: [LockScreenMeterStackRow]

    public static var placeholder: LockScreenMetersEntry {
        LockScreenMetersEntry(
            date: .now,
            mode: .session5h,
            rows: LockScreenMeterStackSelector.rows(from: MockData.allSnapshots, mode: .session5h, at: .now)
        )
    }
}

public struct LockScreenMetersTimelineProvider: AppIntentTimelineProvider {
    private let store = QuotaSnapshotStore.shared

    public func placeholder(in context: Context) -> LockScreenMetersEntry {
        .placeholder
    }

    public func snapshot(for configuration: LockScreenMetersIntent, in context: Context) async -> LockScreenMetersEntry {
        let snapshots = context.isPreview ? MockData.allSnapshots : store.loadSnapshots()
        return entry(
            from: snapshots,
            mode: configuration.mode ?? .session5h,
            fillWithCodexSubmeters: configuration.fillWithCodexSubmeters ?? true,
            at: .now
        )
    }

    public func timeline(for configuration: LockScreenMetersIntent, in context: Context) async -> Timeline<LockScreenMetersEntry> {
        let now = Date()
        let snapshots = store.loadSnapshots()
        let entry = entry(
            from: snapshots,
            mode: configuration.mode ?? .session5h,
            fillWithCodexSubmeters: configuration.fillWithCodexSubmeters ?? true,
            at: now
        )
        return Timeline(entries: [entry], policy: .after(now.addingTimeInterval(UsageRefreshCadence.requestedRefreshInterval)))
    }

    private func entry(
        from snapshots: [QuotaSnapshot],
        mode: LockScreenMeterMode,
        fillWithCodexSubmeters: Bool,
        at date: Date
    ) -> LockScreenMetersEntry {
        LockScreenMetersEntry(
            date: date,
            mode: mode,
            rows: LockScreenMeterStackSelector.rows(
                from: snapshots,
                mode: mode,
                fillWithCodexSubmeters: fillWithCodexSubmeters,
                at: date
            )
        )
    }
}

public struct LockScreenMetersEntryView: View {
    let entry: LockScreenMetersEntry

    public init(entry: LockScreenMetersEntry) {
        self.entry = entry
    }

    public var body: some View {
        GeometryReader { proxy in
            let maxRows = proxy.size.height >= 74 ? 6 : 5
            let rows = Array(entry.rows.prefix(maxRows))

            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                    LockScreenMeterStackRowView(
                        row: row,
                        modeTag: index == 0 ? entry.mode.shortTag : nil
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .containerBackground(for: .widget) {
            Color.clear
        }
        .preferredColorScheme(.dark)
    }
}

public struct AIUsageLockScreenMetersWidget: Widget {
    public static let kind = "AIUsageLockScreenMetersWidget"

    public init() {}

    public var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: Self.kind, intent: LockScreenMetersIntent.self, provider: LockScreenMetersTimelineProvider()) { entry in
            LockScreenMetersEntryView(entry: entry)
        }
        .configurationDisplayName("Limit Counter - Meter Stack")
        .description("Lock Screen stack for 5H or weekly AI quota meters.")
        .supportedFamilies([.accessoryRectangular])
        .contentMarginsDisabled()
    }
}

public struct LockScreenMeterStackRow: Identifiable, Hashable {
    public let id: String
    public let providerID: ProviderID
    public let title: String
    public let valueText: String
    public let fraction: Double
    public let accentHex: String
    public let pace: QuotaPace?
}

private struct LockScreenMeterStackRowView: View {
    let row: LockScreenMeterStackRow
    var modeTag: String? = nil

    private var accent: Color {
        Color(hex: row.accentHex)
    }

    var body: some View {
        HStack(spacing: 4) {
            ProviderBrandIconView(providerID: row.providerID, size: 9)
                .frame(width: 10, height: 10)

            VStack(alignment: .leading, spacing: 0.5) {
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(row.title)
                        .font(.system(size: 8.5, weight: .semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)

                    Spacer(minLength: 2)

                    if let modeTag {
                        Text(modeTag)
                            .font(.system(size: 7, weight: .bold, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    Text(row.valueText)
                        .font(.system(size: 8.5, weight: .bold))
                        .foregroundStyle(usageColor(for: row.fraction, accentColor: accent))
                        .lineLimit(1)
                        .minimumScaleFactor(0.65)
                        .monospacedDigit()
                        .widgetAccentable(true)
                }

                QuotaProgressBar(
                    fraction: row.fraction,
                    accentColor: accent,
                    height: 2.2,
                    pace: row.pace
                )
                .widgetAccentable(true)
            }
        }
        .frame(height: 11.5)
    }
}

private enum LockScreenMeterStackSelector {
    static func rows(
        from snapshots: [QuotaSnapshot],
        mode: LockScreenMeterMode,
        fillWithCodexSubmeters: Bool = true,
        at date: Date
    ) -> [LockScreenMeterStackRow] {
        let visible = filteredSnapshots(snapshots)
        var rows: [LockScreenMeterStackRow] = []
        var selectedWindowIDs = Set<UUID>()

        for snapshot in visible {
            guard let window = primaryWindow(for: snapshot, mode: mode) else { continue }
            rows.append(row(for: snapshot, window: window, mode: mode, date: date, isSupplementalCodex: false))
            selectedWindowIDs.insert(window.id)
        }

        if mode == .weekly, fillWithCodexSubmeters, rows.count < 6, let codex = visible.first(where: { $0.providerID == .openai }) {
            let supplemental = codex.windows
                .filter { !selectedWindowIDs.contains($0.id) && isWeeklyWindow($0) }
                .prefix(6 - rows.count)

            for window in supplemental {
                rows.append(row(for: codex, window: window, mode: mode, date: date, isSupplementalCodex: true))
            }
        }

        return rows
    }

    private static func filteredSnapshots(_ snapshots: [QuotaSnapshot]) -> [QuotaSnapshot] {
        let defaults = UserDefaults(suiteName: "group.com.chrisizatt.LLMUsageCounter") ?? .standard
        let stored = defaults.array(forKey: "hiddenProviderIDs") as? [String] ?? []
        let hidden = Set(stored.compactMap(ProviderID.init(rawValue:)))

        return snapshots
            .filter { snapshot in
                snapshot.providerID.isUserFacingInProviderLists
                    && snapshot.providerID != .chatgpt
                    && snapshot.providerID != .cursor
                    && !hidden.contains(snapshot.providerID)
                    && snapshot.fetchState != .notConfigured
            }
            .sorted {
                ProviderCardOrderStore.nonisolatedRank(for: $0.providerID) < ProviderCardOrderStore.nonisolatedRank(for: $1.providerID)
            }
    }

    private static func primaryWindow(for snapshot: QuotaSnapshot, mode: LockScreenMeterMode) -> QuotaWindow? {
        switch mode {
        case .session5h:
            if let exact = snapshot.windows.first(where: isFiveHourWindow) {
                return exact
            }

            if snapshot.providerID == .gemini {
                return snapshot.summaryWindows.first
            }

            if snapshot.providerID == .windsurf {
                return snapshot.windows.first(where: { $0.windowKind == .daily || normalized($0.label).contains("daily") })
                    ?? snapshot.summaryWindows.first
            }

            return nil

        case .weekly:
            return snapshot.windows.first(where: isWeeklyWindow)
        }
    }

    private static func row(
        for snapshot: QuotaSnapshot,
        window: QuotaWindow,
        mode: LockScreenMeterMode,
        date: Date,
        isSupplementalCodex: Bool
    ) -> LockScreenMeterStackRow {
        let title = compactTitle(for: snapshot, window: window, mode: mode, isSupplementalCodex: isSupplementalCodex)
        return LockScreenMeterStackRow(
            id: "\(snapshot.providerID.rawValue)-\(window.id.uuidString)",
            providerID: snapshot.providerID,
            title: title,
            valueText: window.leadingValueText,
            fraction: window.fractionUsed,
            accentHex: snapshot.providerID.accentColorHex,
            pace: window.pace(providerID: snapshot.providerID, at: date)
        )
    }

    private static func compactTitle(
        for snapshot: QuotaSnapshot,
        window: QuotaWindow,
        mode: LockScreenMeterMode,
        isSupplementalCodex: Bool
    ) -> String {
        guard isSupplementalCodex else {
            if snapshot.providerID == .gemini {
                return "Gemini CLI"
            }
            return snapshot.displayName
        }

        var label = window.label
        label = label.replacingOccurrences(of: "GPT-5.3-Codex-Spark", with: "Spark")
        label = label.replacingOccurrences(of: "Codex", with: "")
        label = label.replacingOccurrences(of: "Weekly", with: "")
        label = label.trimmingCharacters(in: .whitespacesAndNewlines)
        return label.isEmpty ? "Codex Extra" : "Codex \(label)"
    }

    private static func isFiveHourWindow(_ window: QuotaWindow) -> Bool {
        let descriptor = normalized("\(window.label) \(window.subtitle ?? "")")
        return descriptor.contains("5h")
            || descriptor.contains("5-hour")
            || descriptor.contains("5 hour")
            || (window.windowKind == .session && descriptor.contains("session"))
            || (window.windowKind == .sliding && descriptor.contains("5"))
    }

    private static func isWeeklyWindow(_ window: QuotaWindow) -> Bool {
        let descriptor = normalized("\(window.label) \(window.subtitle ?? "")")
        return window.windowKind == .weekly
            || descriptor.contains("weekly")
            || descriptor.contains("7d")
            || descriptor.contains("7-day")
            || descriptor.contains("7 day")
    }

    private static func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
#endif

// MARK: - Control Center Support (iOS 18+)

@available(iOS 18.0, macOS 15.0, *)
public struct AIUsageControl: ControlWidget {
    public static let kind = "AIUsageControl"

    public init() {}

    public var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: Self.kind) {
            ControlWidgetButton(action: OpenAppIntent()) {
                Label("Limit Counter", systemImage: "chart.bar.fill")
            }
            .tint(ProGlassTheme.accent)
        }
        .displayName("Limit Counter")
        .description("Quickly open Limit Counter to check quotas.")
    }
}

@available(iOS 18.0, macOS 15.0, *)
public struct AIUsageRefreshControl: ControlWidget {
    public static let kind = "AIUsageRefreshControl"

    public init() {}

    public var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: Self.kind) {
            ControlWidgetButton(action: RefreshAIUsageIntent()) {
                Label("Refresh Usage", systemImage: "arrow.clockwise")
            }
            .tint(ProGlassTheme.accent)
        }
        .displayName("Refresh Limit Counter")
        .description("Refresh cached Limit Counter snapshots for widgets and controls.")
    }
}

public struct OpenAppIntent: ControlConfigurationIntent {
    public static let title: LocalizedStringResource = "Open Limit Counter"
    public static let isDiscoverable = true
    public static let opensApp = true
    @available(iOS 26.0, macOS 26.0, *)
    public static let supportedModes: IntentModes = [.foreground(.immediate)]

    public init() {}

    public func perform() async throws -> some IntentResult {
        .result()
    }
}

public struct RefreshAIUsageIntent: AppIntent {
    public static let title: LocalizedStringResource = "Refresh Limit Counter"
    public static let description = IntentDescription("Reloads widgets and controls from the shared Limit Counter cache.")
    public static let isDiscoverable = true
    public static let openAppWhenRun = false
    @available(iOS 26.0, macOS 26.0, *)
    public static let supportedModes: IntentModes = [.background]

    public init() {}

    public func perform() async throws -> some IntentResult {
        WidgetCenter.shared.reloadAllTimelines()
        if #available(iOS 18.0, macOS 15.0, *) {
            ControlCenter.shared.reloadAllControls()
        }
        return .result(dialog: "Limit Counter refreshed")
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

        return Timeline(entries: [entry], policy: .after(.now.addingTimeInterval(UsageRefreshCadence.requestedRefreshInterval)))
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

// MARK: - User-Selectable Trio (Lock Screen)

#if os(iOS)

/// Configuration intent for the user-selectable 3-meter Lock Screen widget.
/// Same shape as `SelectQuotaIntent` (a free-form metrics array) so the
/// existing `QuotaWindowEntity` picker UI is reused as-is — but kept as a
/// separate intent type so the widget gallery shows it as its own entry
/// (distinct title/description from the 2-meter version).
public struct SelectQuotaTrioIntent: WidgetConfigurationIntent {
    public static var title: LocalizedStringResource = "Custom Trio"
    public static var description = IntentDescription("Pick three meters to monitor on your Lock Screen.")

    @Parameter(title: "Selected Metrics")
    public var metrics: [QuotaWindowEntity]?

    public init() {}

    public static var parameterSummary: some ParameterSummary {
        Summary("Show \(\.$metrics)")
    }
}

/// One row in the trio. Carries everything the row view needs to render
/// without poking back at the original snapshot — including the raw
/// `resetDate` so the row view can show an inline countdown like
/// "5d 7h 18m" alongside the percentage (matching the 2-meter widget's
/// visual style).
public struct SelectQuotaTrioMeterRow: Identifiable, Hashable {
    public let id: String
    public let providerID: ProviderID
    /// Window label — "Session", "Weekly", "Sonnet", "Pro 3.1 (preview)" etc.
    /// We deliberately use the window label (not the provider's display
    /// name) so a user picking three Claude meters sees "Session / Weekly
    /// / Sonnet" rather than "Claude Code" three times. The provider icon
    /// disambiguates when rows span multiple providers.
    public let title: String
    public let valueText: String
    public let fraction: Double
    public let accentHex: String
    public let resetDate: Date?
    public let hasExplicitLimit: Bool
    public let pace: QuotaPace?
}

/// Entry payload for the trio widget — a pre-built array of stack rows.
public struct SelectQuotaTrioEntry: TimelineEntry {
    public let date: Date
    public let rows: [SelectQuotaTrioMeterRow]

    public static var placeholder: SelectQuotaTrioEntry {
        SelectQuotaTrioEntry(
            date: .now,
            rows: SelectQuotaTrioRowBuilder.rows(
                from: MockData.allSnapshots,
                selectedMetricIDs: nil,
                at: .now
            )
        )
    }
}

@available(iOS 16.0, macOS 13.0, *)
public struct SelectQuotaTrioTimelineProvider: AppIntentTimelineProvider {
    private let store = QuotaSnapshotStore.shared

    public init() {}

    public func placeholder(in context: Context) -> SelectQuotaTrioEntry {
        .placeholder
    }

    public func snapshot(for configuration: SelectQuotaTrioIntent, in context: Context) async -> SelectQuotaTrioEntry {
        let snapshots = context.isPreview ? MockData.allSnapshots : store.loadSnapshots()
        return SelectQuotaTrioEntry(
            date: .now,
            rows: SelectQuotaTrioRowBuilder.rows(
                from: snapshots,
                selectedMetricIDs: configuration.metrics?.map(\.id),
                at: .now
            )
        )
    }

    public func timeline(for configuration: SelectQuotaTrioIntent, in context: Context) async -> Timeline<SelectQuotaTrioEntry> {
        let now = Date()
        let snapshots = store.loadSnapshots()
        let entry = SelectQuotaTrioEntry(
            date: now,
            rows: SelectQuotaTrioRowBuilder.rows(
                from: snapshots,
                selectedMetricIDs: configuration.metrics?.map(\.id),
                at: now
            )
        )
        return Timeline(entries: [entry], policy: .after(now.addingTimeInterval(UsageRefreshCadence.requestedRefreshInterval)))
    }
}

/// Builds `SelectQuotaTrioMeterRow` items from the user's selected metric
/// IDs. The ID format mirrors `SelectQuotaTimelineProvider.filteredSnapshots`
/// (`"<providerID>:<windowLabel>"`) so the existing `QuotaWindowEntity`
/// picker continues to work unchanged.
private enum SelectQuotaTrioRowBuilder {
    /// Hard cap: this widget renders exactly 3 rows. Anything the user
    /// picks beyond that is silently dropped (matches how the 2-meter
    /// variant truncates with `prefix(2)`).
    static let maxRows = 3

    static func rows(
        from snapshots: [QuotaSnapshot],
        selectedMetricIDs: [String]?,
        at date: Date
    ) -> [SelectQuotaTrioMeterRow] {
        var built: [SelectQuotaTrioMeterRow] = []

        if let selectedMetricIDs, !selectedMetricIDs.isEmpty {
            // Honour the user's explicit selection, in the order they
            // chose them.
            for metricID in selectedMetricIDs {
                guard built.count < maxRows else { break }
                let parts = metricID.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
                guard parts.count == 2 else { continue }
                let providerRaw = String(parts[0])
                let windowLabel = String(parts[1])
                guard let snapshot = snapshots.first(where: { $0.providerID.rawValue == providerRaw }),
                      let window = snapshot.windows.first(where: { $0.label == windowLabel }) else {
                    continue
                }
                built.append(row(snapshot: snapshot, window: window, at: date))
            }
        } else {
            // Sensible fallback: first 3 summary windows across visible
            // providers, so the widget shows something coherent before
            // the user opens the configuration sheet.
            for snapshot in snapshots {
                for window in snapshot.summaryWindows {
                    guard built.count < maxRows else { break }
                    built.append(row(snapshot: snapshot, window: window, at: date))
                }
                if built.count >= maxRows { break }
            }
        }

        return built
    }

    private static func row(snapshot: QuotaSnapshot, window: QuotaWindow, at date: Date) -> SelectQuotaTrioMeterRow {
        SelectQuotaTrioMeterRow(
            id: "\(snapshot.providerID.rawValue):\(window.label)",
            providerID: snapshot.providerID,
            title: window.label,
            valueText: window.leadingValueText,
            fraction: window.fractionUsed,
            accentHex: snapshot.providerID.accentColorHex,
            resetDate: window.resetDate,
            hasExplicitLimit: window.hasExplicitLimit,
            pace: window.pace(providerID: snapshot.providerID, at: date)
        )
    }
}

public struct SelectQuotaTrioEntryView: View {
    let entry: SelectQuotaTrioEntry

    public init(entry: SelectQuotaTrioEntry) {
        self.entry = entry
    }

    public var body: some View {
        GeometryReader { proxy in
            // accessoryRectangular is ~74pt tall on most devices; split
            // evenly across 3 rows. Use a small inter-row gap so bars
            // don't visually merge into adjacent text. Clamp to a sane
            // minimum so we degrade gracefully on smaller chrome.
            let interRowGap: CGFloat = 2
            let rowHeight = max(
                (proxy.size.height - interRowGap * CGFloat(SelectQuotaTrioRowBuilder.maxRows - 1)) / CGFloat(SelectQuotaTrioRowBuilder.maxRows),
                18
            )

            VStack(alignment: .leading, spacing: interRowGap) {
                ForEach(entry.rows.prefix(SelectQuotaTrioRowBuilder.maxRows)) { row in
                    SelectQuotaTrioMeterRowView(row: row)
                        .frame(height: rowHeight)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .containerBackground(for: .widget) {
            Color.clear
        }
        .preferredColorScheme(.dark)
    }
}

/// Per-row view for the trio widget. Sized to match the 2-meter widget's
/// look: 10pt label/value, 3pt progress bar, small provider icon for
/// disambiguation since rows can come from different providers. The row
/// stretches vertically to fill whatever frame its parent gives it, with
/// the content top-aligned so bars sit consistently across rows.
private struct SelectQuotaTrioMeterRowView: View {
    let row: SelectQuotaTrioMeterRow

    private var accent: Color {
        Color(hex: row.accentHex)
    }

    /// Compact countdown string: "5d 7h 18m", "3h 11m", "now". Returns
    /// nil when there's no reset date so the row collapses cleanly.
    private var resetText: String? {
        guard let resetDate = row.resetDate else { return nil }
        let text = resetDate.countdownString
        return text.hasPrefix("in ") ? String(text.dropFirst(3)) : text
    }

    var body: some View {
        HStack(spacing: 4) {
            ProviderBrandIconView(providerID: row.providerID, size: 11)
                .frame(width: 12, height: 12)

            VStack(alignment: .leading, spacing: 1.5) {
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(row.title)
                        .font(.system(size: 10, weight: .semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)

                    Spacer(minLength: 3)

                    if let resetText {
                        Text(resetText)
                            .font(.system(size: 8.5, weight: .medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    }

                    Text(row.valueText)
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(usageColor(for: row.fraction, accentColor: accent))
                        .lineLimit(1)
                        .minimumScaleFactor(0.65)
                        .monospacedDigit()
                        .widgetAccentable(true)
                }

                if row.hasExplicitLimit {
                    QuotaProgressBar(
                        fraction: row.fraction,
                        accentColor: accent,
                        height: 3,
                        pace: row.pace
                    )
                    .widgetAccentable(true)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

public struct AIUsageLockScreenTrioWidget: Widget {
    public static let kind = "AIUsageLockScreenTrioWidget"

    public init() {}

    public var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: Self.kind, intent: SelectQuotaTrioIntent.self, provider: SelectQuotaTrioTimelineProvider()) { entry in
            SelectQuotaTrioEntryView(entry: entry)
        }
        .configurationDisplayName("Limit Counter - Custom Trio")
        .description("Lock Screen stack of three user-selected meters.")
        .supportedFamilies([.accessoryRectangular])
        .contentMarginsDisabled()
    }
}

#endif

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
        AIUsageHeatmapWidget()
        #if os(iOS)
        AIUsageLockScreenMetersWidget()
        AIUsageLockScreenTrioWidget()
        #endif
        if #available(iOS 18.0, macOS 15.0, *) {
            AIUsageControl()
            AIUsageRefreshControl()
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
