import SwiftUI

public struct LLMActivityHeatmapView: View {
    private let columns = 30 // Days
    private let rows = 12    // 2-hour blocks

    // Processed data to avoid O(N^2) lookups in render loop
    private let allEvents: [UsageEvent]
    private let eventToProvider: [UUID: ProviderID]
    private let bucketMap: [HeatmapBucketKey: [UsageEvent]]

    public init(snapshots: [QuotaSnapshot]) {
        self.init(snapshots: snapshots, modelUsage: nil)
    }

    init(snapshots: [QuotaSnapshot], modelUsage: ModelUsageArchive?) {
        // 1. Extract all events once, dropping duplicates. See
        // `UsageEventDeduplicator` for the two duplication modes this covers.
        var events = UsageEventDeduplicator.flatten(snapshots)

        // 2. Create a fast lookup for event -> provider
        var providerMap: [UUID: ProviderID] = [:]
        for snapshot in snapshots {
            for event in snapshot.events {
                // Coalesce telemetry
                providerMap[event.id] = (snapshot.providerID == .codexTelemetry ? .openai : snapshot.providerID)
            }
        }
        // Prefer model-aware ledger rows once available. This replaces the host's
        // total-only event copy instead of adding a second view of the same calls.
        // Other ledger sources (TaskWraith runs, provider CLIs) already reach this map
        // through their cards' events, so they are never added a second time.
        let cutoff = Date().addingTimeInterval(-31 * 86400)
        let rollups = modelUsage?.buckets.filter { row in
            row.start >= cutoff && row.start <= Date() && ModelUsageSourceIdentity.replacedSnapshotHost(row.source) != nil
        } ?? []
        let hosts = Set(rollups.compactMap { ModelUsageSourceIdentity.replacedSnapshotHost($0.source) })
        events.removeAll { event in
            guard let host = providerMap[event.id] else { return false }
            return hosts.contains(host)
        }
        // Ledger rows are five-minute buckets per model, tens of thousands a month, and this
        // runs on every dashboard redraw. Cells need only tokens per host and routed vendor,
        // so rows merge per 15-minute slot: every zone offset and 2-hour row boundary falls
        // on one, so no row changes cell.
        var merged: [String: (host: ProviderID, start: Date, model: String, tokens: Double)] = [:]
        for row in rollups {
            guard let host = ModelUsageSourceIdentity.replacedSnapshotHost(row.source) else { continue }
            let slot = floor(row.start.timeIntervalSince1970 / 900) * 900
            let key = "\(host.rawValue)|\(ModelUsageDisplayIdentity.provider(model: row.model, source: host.rawValue))|\(slot)"
            var value = merged[key] ?? (host, Date(timeIntervalSince1970: slot), row.model, 0)
            value.tokens += row.tokens.total
            merged[key] = value
        }
        for value in merged.values {
            let event = UsageEvent(timestamp: value.start, tokens: value.tokens, model: value.model, type: .bucket)
            providerMap[event.id] = value.host
            events.append(event)
        }
        self.allEvents = events
        self.eventToProvider = providerMap

        // 3. Pre-bucket the events by local day + 2-hour row, resolving each 15-minute
        // slot's calendar position once.
        let calendar = Calendar.current
        var keys: [Int: HeatmapBucketKey] = [:]
        self.bucketMap = Dictionary(grouping: events) { event in
            let slot = Int(floor(event.timestamp.timeIntervalSince1970 / 900))
            if let key = keys[slot] { return key }
            let key = Self.bucketKey(for: event.timestamp, calendar: calendar)
            keys[slot] = key
            return key
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

        // Cells wear the TaskWraith catalogue accent of the brand behind their tokens,
        // the same one the model usage page shows for those models.
        var providerWeights: [String: Double] = [:]
        for event in events {
            let weight = event.tokens ?? 100
            let host = eventToProvider[event.id] ?? .openai
            providerWeights[ModelUsageDisplayIdentity.provider(model: event.model, source: host.rawValue), default: 0] += weight
        }

        guard !providerWeights.isEmpty else { return ProGlassTheme.accent }
        let totalWeight = providerWeights.values.reduce(0, +)
        let accent = { (brand: String) in TaskWraithBranding.hex(for: brand).map { Color(hex: $0) } ?? Color.white.opacity(0.55) }

        let sorted = providerWeights.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
        let c1 = accent(sorted[0].key)

        if sorted.count > 1 && (sorted[1].value / totalWeight) > 0.2 {
            let c2 = accent(sorted[1].key)
            let ratio = sorted[1].value / (sorted[0].value + sorted[1].value)
            return c1.lerp(to: c2, amount: CGFloat(ratio))
        }

        return c1
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
