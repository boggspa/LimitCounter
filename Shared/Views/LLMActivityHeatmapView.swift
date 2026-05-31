import SwiftUI

public struct LLMActivityHeatmapView: View {
    private let columns = 30 // Days
    private let rows = 12    // 2-hour blocks

    // Processed data to avoid O(N^2) lookups in render loop
    private let allEvents: [UsageEvent]
    private let eventToProvider: [UUID: ProviderID]
    private let bucketMap: [HeatmapBucketKey: [UsageEvent]]

    public init(snapshots: [QuotaSnapshot]) {
        // 1. De-duplicate and extract all events once
        var seen = Set<UUID>()
        let events = snapshots.flatMap(\.events)
            .filter { seen.insert($0.id).inserted }
        self.allEvents = events

        // 2. Create a fast lookup for event -> provider
        var providerMap: [UUID: ProviderID] = [:]
        for snapshot in snapshots {
            for event in snapshot.events {
                // Coalesce telemetry
                providerMap[event.id] = (snapshot.providerID == .codexTelemetry ? .openai : snapshot.providerID)
            }
        }
        self.eventToProvider = providerMap

        // 3. Pre-bucket the events by local day + 2-hour row.
        let calendar = Calendar.current
        self.bucketMap = Dictionary(grouping: events) { event in
            Self.bucketKey(for: event.timestamp, calendar: calendar)
        }
    }

    private func dateFor(column: Int) -> Date {
        let now = Calendar.current.startOfDay(for: Date())
        return Calendar.current.date(byAdding: .day, value: -(columns - 1 - column), to: now)!
    }

    private func eventsFor(column: Int, row: Int) -> [UsageEvent] {
        let dayStart = Calendar.current.startOfDay(for: dateFor(column: column))
        let key = HeatmapBucketKey(dayStart: dayStart, row: row)
        return bucketMap[key] ?? []
    }

    public var body: some View {
        GlassCardContainer(style: .panel, accent: ProGlassTheme.accent, cornerRadius: 16) {
            VStack(alignment: .leading, spacing: 8) {
                summaryHeader

                HStack(alignment: .top, spacing: 6) {
                    timeLabels

                    ScrollViewReader { proxy in
                        ScrollView(.horizontal, showsIndicators: false) {
                            gridContent
                                .id("grid")
                                .onAppear {
                                    proxy.scrollTo("grid", anchor: .trailing)
                                }
                        }
                    }
                }
            }
            .padding(4)
        }
    }

    private var summaryHeader: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Activity")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.white)

                Text("Last 30 days • 2h intervals")
                    .font(.system(size: 8))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            let totals = tokenTotals()
            if totals.thirtyDay > 0 {
                HStack(spacing: 4) {
                    tokenPill(value: totals.today, label: "today")
                    tokenPill(value: totals.sevenDay, label: "7D")
                    tokenPill(value: totals.thirtyDay, label: "30D")
                }
            }
        }
    }

    private func tokenPill(value: Double, label: String) -> some View {
        Text("\(value.compactString) \(label)")
            .font(.system(size: 9, weight: .semibold))
            .lineLimit(1)
            .minimumScaleFactor(0.82)
            .foregroundStyle(ProGlassTheme.accent)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(ProGlassTheme.accent.opacity(0.12), in: Capsule())
    }

    private var timeLabels: some View {
        VStack(alignment: .trailing, spacing: 2) {
            ForEach(0..<rows, id: \.self) { row in
                Text("\(row * 2)h")
                    .font(.system(size: 6))
                    .foregroundStyle(.tertiary)
                    .frame(height: 7)
            }
        }
        .padding(.top, 2)
    }

    private var gridContent: some View {
        HStack(spacing: 2) {
            ForEach(0..<columns, id: \.self) { col in
                VStack(spacing: 2) {
                    ForEach(0..<rows, id: \.self) { row in
                        heatmapCell(events: eventsFor(column: col, row: row))
                    }

                    if col % 5 == 0 || col == columns - 1 {
                        Text(dayAbbreviation(for: dateFor(column: col)))
                            .font(.system(size: 5))
                            .foregroundStyle(.tertiary)
                            .padding(.top, 1)
                    } else {
                        Spacer().frame(height: 6)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func heatmapCell(events: [UsageEvent]) -> some View {
        let color = colorForEvents(events)
        let intensity = intensityForEvents(events)

        RoundedRectangle(cornerRadius: 1.5, style: .continuous)
            .fill(color.opacity(intensity))
            .frame(width: 7, height: 7)
            .overlay(
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .stroke(Color.white.opacity(0.03), lineWidth: 0.3)
            )
    }

    private func intensityForEvents(_ events: [UsageEvent]) -> Double {
        guard !events.isEmpty else { return 0.04 }
        let totalTokens = events.compactMap(\.tokens).reduce(0, +)

        if totalTokens == 0 {
            // For providers that only emit "activity" buckets without token estimates,
            // fall back to event density so the heatmap still shows meaningful intensity.
            if events.count < 2 { return 0.2 }
            if events.count < 4 { return 0.35 }
            if events.count < 8 { return 0.5 }
            if events.count < 16 { return 0.65 }
            return 0.8
        }
        if totalTokens < 100 { return 0.4 }
        if totalTokens < 500 { return 0.6 }
        if totalTokens < 2000 { return 0.8 }
        return 1.0
    }

    private func colorForEvents(_ events: [UsageEvent]) -> Color {
        guard !events.isEmpty else { return Color.white.opacity(0.1) }

        var providerWeights: [ProviderID: Double] = [:]
        for event in events {
            let weight = event.tokens ?? 100
            if let provider = eventToProvider[event.id] {
                providerWeights[provider, default: 0] += weight
            } else if let provider = guessProviderFromModel(event.model) {
                providerWeights[provider, default: 0] += weight
            }
        }

        guard !providerWeights.isEmpty else { return ProGlassTheme.accent }
        let totalWeight = providerWeights.values.reduce(0, +)

        let sorted = providerWeights.sorted { $0.value > $1.value }
        let c1 = Color(hex: sorted[0].key.accentColorHex)

        if sorted.count > 1 && (sorted[1].value / totalWeight) > 0.2 {
            let c2 = Color(hex: sorted[1].key.accentColorHex)
            let ratio = sorted[1].value / (sorted[0].value + sorted[1].value)
            return c1.lerp(to: c2, amount: CGFloat(ratio))
        }

        return c1
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
        if model.contains("grok") { return .grok }
        return nil
    }

    private func tokenTotals() -> HeatmapTokenTotals {
        let calendar = Calendar.current
        let todayStart = calendar.startOfDay(for: Date())
        let sevenDayStart = calendar.date(byAdding: .day, value: -6, to: todayStart) ?? todayStart
        let thirtyDayStart = calendar.date(byAdding: .day, value: -(columns - 1), to: todayStart) ?? todayStart

        var today = 0.0
        var sevenDay = 0.0
        var thirtyDay = 0.0

        for event in allEvents {
            guard let tokens = event.tokens, tokens > 0, event.timestamp >= thirtyDayStart else {
                continue
            }

            thirtyDay += tokens
            if event.timestamp >= sevenDayStart {
                sevenDay += tokens
            }
            if event.timestamp >= todayStart {
                today += tokens
            }
        }

        return HeatmapTokenTotals(today: today, sevenDay: sevenDay, thirtyDay: thirtyDay)
    }

    private func dayAbbreviation(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "d/M"
        return formatter.string(from: date)
    }

    private static func bucketKey(for date: Date, calendar: Calendar) -> HeatmapBucketKey {
        let dayStart = calendar.startOfDay(for: date)
        let hour = calendar.component(.hour, from: date)
        let row = max(0, min(11, hour / 2))
        return HeatmapBucketKey(dayStart: dayStart, row: row)
    }
}

private struct HeatmapBucketKey: Hashable {
    let dayStart: Date
    let row: Int
}

private struct HeatmapTokenTotals {
    let today: Double
    let sevenDay: Double
    let thirtyDay: Double
}

// MARK: - Color Interpolation Helper

extension Color {
    func lerp(to color: Color, amount: CGFloat) -> Color {
        #if os(macOS)
        let c1 = NSColor(self).usingColorSpace(.deviceRGB) ?? .white
        let c2 = NSColor(color).usingColorSpace(.deviceRGB) ?? .white

        return Color(nsColor: NSColor(
            red: c1.redComponent + (c2.redComponent - c1.redComponent) * amount,
            green: c1.greenComponent + (c2.greenComponent - c1.greenComponent) * amount,
            blue: c1.blueComponent + (c2.blueComponent - c1.blueComponent) * amount,
            alpha: c1.alphaComponent + (c2.alphaComponent - c1.alphaComponent) * amount
        ))
        #else
        var r1: CGFloat = 0, g1: CGFloat = 0, b1: CGFloat = 0, a1: CGFloat = 0
        var r2: CGFloat = 0, g2: CGFloat = 0, b2: CGFloat = 0, a2: CGFloat = 0

        UIColor(self).getRed(&r1, green: &g1, blue: &b1, alpha: &a1)
        UIColor(color).getRed(&r2, green: &g2, blue: &b2, alpha: &a2)

        return Color(uiColor: UIColor(
            red: r1 + (r2 - r1) * amount,
            green: g1 + (g2 - g1) * amount,
            blue: b1 + (b2 - b1) * amount,
            alpha: a1 + (a2 - a1) * amount
        ))
        #endif
    }
}
