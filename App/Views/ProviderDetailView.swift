import Charts
import SwiftUI

struct ProviderDetailView: View {
    let snapshot: QuotaSnapshot

    private var accent: Color { Color(hex: snapshot.providerID.accentColorHex) }

    var body: some View {
        ZStack {
            LiquidGlassBackdrop(intensity: .settings)

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    GlassCardContainer(style: .header, accent: accent, cornerRadius: 18) {
                        providerHeader
                    }

                    Divider().overlay(Color.white.opacity(0.12))

                    if !snapshot.hasContent {
                        GlassCardContainer(style: .panel, accent: accent, cornerRadius: 14) {
                            emptyWindowsView
                        }
                    } else {
                        if !snapshot.signals.isEmpty {
                            signalsSection
                        }

                        if !snapshot.windows.isEmpty {
                            windowsSection
                        }

                        if !snapshot.analyticsBuckets.isEmpty {
                            analyticsSection
                        }

                        if snapshot.statsSectionTitle != nil {
                            statsSection
                        }

                        if snapshot.balancesSectionTitle != nil {
                            balancesSection
                        }
                    }

                    GlassCardContainer(style: .panel, accent: accent, cornerRadius: 14) {
                        integrationSection
                    }

                    GlassCardContainer(style: .hud, accent: accent, cornerRadius: 14) {
                        metaSection
                    }
                }
                .padding(10)
            }
        }
        .navigationTitle(snapshot.displayName)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    // MARK: - Header

    private var providerHeader: some View {
        HStack(spacing: 8) {
            ProviderBrandIconView(providerID: snapshot.providerID, size: 36)

            VStack(alignment: .leading, spacing: 2) {
                ProviderCardTitleText(title: snapshot.displayName, accentColor: accent)
                if let plan = snapshot.planName {
                    Text(plan)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
    }

    // MARK: - Windows

    private var statItems: [SnapshotMetricItem] {
        snapshot.stats.map {
            SnapshotMetricItem(
                id: $0.id,
                title: $0.label,
                value: $0.valueText,
                subtitle: $0.subtitle
            )
        }
    }

    private var balanceItems: [SnapshotMetricItem] {
        snapshot.balances.map {
            SnapshotMetricItem(
                id: $0.id,
                title: $0.label,
                value: $0.valueText,
                subtitle: $0.subtitle ?? $0.resetDate.map { "Resets \($0.countdownString)" }
            )
        }
    }

    private var windowsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Usage Windows")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.bottom, 4)

            ForEach(snapshot.windows) { window in
                GlassCardContainer(style: .panel, accent: accent, cornerRadius: 14) {
                    QuotaWindowRow(window: window, accentColor: accent, providerID: snapshot.providerID)
                }
            }
        }
    }

    private var analyticsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Analytics")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.bottom, 4)

            GlassCardContainer(style: .panel, accent: accent, cornerRadius: 14) {
                UsageAnalyticsOverviewView(providerID: snapshot.providerID, buckets: snapshot.analyticsBuckets, accent: accent)
            }
        }
    }

    private var signalsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Recent Changes")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.bottom, 4)

            GlassCardContainer(style: .panel, accent: accent, cornerRadius: 14) {
                VStack(spacing: 8) {
                    ForEach(snapshot.signals) { signal in
                        SnapshotSignalNotice(signal: signal, accentColor: accent)
                    }
                }
            }
        }
    }

    private var statsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(snapshot.statsSectionTitle ?? "Periodic Usage")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.bottom, 4)

            GlassCardContainer(style: .panel, accent: accent, cornerRadius: 14) {
                SnapshotMetricListView(items: statItems, accentColor: accent)
            }
        }
    }

    private var balancesSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(snapshot.balancesSectionTitle ?? "Extra Balance / Credits")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.bottom, 4)

            GlassCardContainer(style: .panel, accent: accent, cornerRadius: 14) {
                SnapshotMetricListView(items: balanceItems, accentColor: accent)
            }
        }
    }

    private var emptyWindowsView: some View {
        VStack(spacing: 10) {
            Image(systemName: "tray")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text("No usage data available")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
    }

    private var integrationSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Integration")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)

            HStack(spacing: 10) {
                Text(snapshot.providerID.integrationStatus.badgeTitle)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(accent.opacity(0.16), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                    .foregroundStyle(accent)

                Text(snapshot.providerID.configurationTitle)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.primary)
            }

            Text(snapshot.providerID.configurationDescription)
                .font(.caption)
                .foregroundStyle(.secondary)

            Text(snapshot.providerID.securityNote)
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Meta

    private var metaSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Last updated \(snapshot.fetchedAt.relativeString)", systemImage: "clock")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }
}

private struct UsageAnalyticsOverviewView: View {
    let providerID: ProviderID
    let buckets: [UsageAnalyticsBucket]
    let accent: Color
    @ObservedObject private var budgetStore = ProviderMonthlyBudgetStore.shared

    private var model: UsageAnalyticsIntelligence {
        UsageAnalyticsIntelligence(
            buckets: buckets,
            monthlyBudgetUSD: budgetStore.budgetUSD(for: providerID)
        )
    }

    var body: some View {
        let model = model
        VStack(alignment: .leading, spacing: 12) {
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                analyticsTile(title: "Today", value: model.today.tokens.compactString, subtitle: costSubtitle(model.today))
                analyticsTile(title: "7D", value: model.sevenDay.tokens.compactString, subtitle: costSubtitle(model.sevenDay))
                analyticsTile(title: "30D", value: model.thirtyDay.tokens.compactString, subtitle: costSubtitle(model.thirtyDay))
                analyticsTile(title: "Projected", value: projectedValue(model.projectedMonth), subtitle: projectedSubtitle(model))
            }

            if !model.insights.isEmpty {
                VStack(spacing: 7) {
                    ForEach(model.insights.prefix(3)) { insight in
                        UsageAnalyticsInsightRow(insight: insight, accent: accent)
                    }
                }
            }

            if !model.daily.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Tokens")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)

                    Chart(model.daily) { day in
                        BarMark(
                            x: .value("Day", day.date, unit: .day),
                            y: .value("Tokens", day.tokens)
                        )
                        .foregroundStyle(accent)
                        .opacity(day.tokens > 0 ? 0.82 : 0.16)
                    }
                    .chartYAxis(.hidden)
                    .chartXAxis {
                        AxisMarks(values: model.axisDates) { _ in
                            AxisGridLine().foregroundStyle(Color.clear)
                            AxisTick().foregroundStyle(Color.clear)
                            AxisValueLabel(format: .dateTime.month(.abbreviated).day())
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(height: 104)
                }
            }

            if model.hasCost {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Cost")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)

                    Chart(model.daily) { day in
                        BarMark(
                            x: .value("Day", day.date, unit: .day),
                            y: .value("USD", day.cost)
                        )
                        .foregroundStyle(Color(hex: "#22C55E"))
                        .opacity(day.cost > 0 ? 0.78 : 0.14)
                    }
                    .chartYAxis(.hidden)
                    .chartXAxis(.hidden)
                    .frame(height: 62)
                }
            }

            if !model.topModels.isEmpty {
                VStack(alignment: .leading, spacing: 7) {
                    Text("Top Models")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)

                    ForEach(model.topModels.prefix(4)) { item in
                        HStack(spacing: 8) {
                            Text(item.name)
                                .font(.caption.weight(.semibold))
                                .lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)

                            Text(item.tokens.compactString)
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        .overlay(alignment: .bottomLeading) {
                            GeometryReader { proxy in
                                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                                    .fill(accent.opacity(0.24))
                                    .frame(width: proxy.size.width * item.fractionOfMax, height: 2)
                                    .offset(y: 5)
                            }
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func analyticsTile(title: String, value: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title.uppercased())
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(.tertiary)
            Text(value)
                .font(.system(size: 15, weight: .bold, design: .monospaced))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.78)
            Text(subtitle)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.78)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(accent.opacity(0.075), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
        )
    }

    private func costSubtitle(_ totals: UsageAnalyticsPeriodTotals) -> String {
        if totals.cost > 0 {
            return formattedMetricValue(totals.cost, unit: "$")
        }
        return "\(totals.requests.compactString) reqs"
    }

    private func projectedValue(_ totals: UsageAnalyticsPeriodTotals) -> String {
        if totals.cost > 0 {
            return formattedMetricValue(totals.cost, unit: "$")
        }
        return totals.tokens.compactString
    }

    private func projectedSubtitle(_ model: UsageAnalyticsIntelligence) -> String {
        if let budget = model.monthlyBudget {
            return "\(budget.projectedPercentageText) of budget"
        }

        if model.projectedMonth.cost > 0, model.projectedMonth.tokens > 0 {
            return "\(model.projectedMonth.tokens.compactString) tokens"
        }
        return "\(model.projectedMonth.requests.compactString) reqs"
    }
}

private struct UsageAnalyticsInsightRow: View {
    let insight: UsageAnalyticsInsight
    let accent: Color

    private var color: Color {
        switch insight.severity {
        case .info:
            return accent
        case .warning:
            return .yellow
        case .critical:
            return .red
        }
    }

    private var iconName: String {
        switch insight.kind {
        case .budgetStatus:
            return "gauge.with.dots.needle.67percent"
        case .projectedMonth:
            return "calendar.badge.clock"
        case .usageSpike:
            return "exclamationmark.triangle.fill"
        case .topModel:
            return "cpu.fill"
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: iconName)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 20, height: 20)
                .background(color.opacity(0.14), in: RoundedRectangle(cornerRadius: 6, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                Text(insight.title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(insight.message)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .padding(8)
        .background(Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.white.opacity(0.065), lineWidth: 1)
        )
    }
}

struct ProviderDetailView_Previews: PreviewProvider {
    static var previews: some View {
        NavigationStack {
            ProviderDetailView(snapshot: MockData.openAIAPISnapshot)
        }
        .preferredColorScheme(.dark)
    }
}

// MARK: - Combined Codex Detail

struct CodexDetailView: View {
    let usageSnapshot: QuotaSnapshot
    let telemetrySnapshot: QuotaSnapshot?

    private var accent: Color { Color(hex: usageSnapshot.providerID.accentColorHex) }

    var body: some View {
        ZStack {
            LiquidGlassBackdrop(intensity: .settings)

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    GlassCardContainer(style: .header, accent: accent, cornerRadius: 18) {
                        header
                    }

                    Divider().overlay(Color.white.opacity(0.12))

                    if !usageSnapshot.hasContent && telemetrySnapshot?.hasContent != true {
                        GlassCardContainer(style: .panel, accent: accent, cornerRadius: 14) {
                            emptyView
                        }
                    } else {
                        if let telemetrySnapshot, !telemetrySnapshot.signals.isEmpty {
                            signalsSection(telemetrySnapshot.signals)
                        }

                        if !usageSnapshot.windows.isEmpty {
                            windowsSection
                        }

                        if !usageSnapshot.analyticsBuckets.isEmpty {
                            analyticsSection(usageSnapshot.analyticsBuckets)
                        }

                        if let telemetrySnapshot, telemetrySnapshot.statsSectionTitle != nil {
                            statsSection(
                                title: telemetrySnapshot.statsSectionTitle ?? "Telemetry",
                                stats: telemetrySnapshot.stats
                            )
                        }

                        if usageSnapshot.balancesSectionTitle != nil {
                            balancesSection(
                                title: usageSnapshot.balancesSectionTitle ?? "Credits / Balance",
                                balances: usageSnapshot.balances
                            )
                        }

                        if let telemetrySnapshot, telemetrySnapshot.balancesSectionTitle != nil {
                            balancesSection(
                                title: telemetrySnapshot.balancesSectionTitle ?? "Telemetry Balance",
                                balances: telemetrySnapshot.balances
                            )
                        }
                    }

                    GlassCardContainer(style: .panel, accent: accent, cornerRadius: 14) {
                        integrationSection
                    }

                    GlassCardContainer(style: .hud, accent: accent, cornerRadius: 14) {
                        metaSection
                    }
                }
                .padding(10)
            }
        }
        .navigationTitle(usageSnapshot.displayName)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    private var header: some View {
        HStack(spacing: 8) {
            ProviderBrandIconView(providerID: usageSnapshot.providerID, size: 36)

            VStack(alignment: .leading, spacing: 2) {
                ProviderCardTitleText(title: usageSnapshot.displayName, accentColor: accent)
                if let plan = usageSnapshot.planName {
                    Text(plan)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if telemetrySnapshot != nil {
                    Text("Usage + Telemetry")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer()
        }
    }

    private var windowsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Usage Windows")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.bottom, 4)

            ForEach(usageSnapshot.windows) { window in
                GlassCardContainer(style: .panel, accent: accent, cornerRadius: 14) {
                    QuotaWindowRow(window: window, accentColor: accent, providerID: usageSnapshot.providerID)
                }
            }
        }
    }

    private func analyticsSection(_ buckets: [UsageAnalyticsBucket]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Analytics")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.bottom, 4)

            GlassCardContainer(style: .panel, accent: accent, cornerRadius: 14) {
                UsageAnalyticsOverviewView(providerID: usageSnapshot.providerID, buckets: buckets, accent: accent)
            }
        }
    }

    private func signalsSection(_ signals: [QuotaSignal]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Recent Changes")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.bottom, 4)

            GlassCardContainer(style: .panel, accent: accent, cornerRadius: 14) {
                VStack(spacing: 8) {
                    ForEach(signals) { signal in
                        SnapshotSignalNotice(signal: signal, accentColor: accent)
                    }
                }
            }
        }
    }

    private func statsSection(title: String, stats: [QuotaStat]) -> some View {
        let items: [SnapshotMetricItem] = stats.map {
            SnapshotMetricItem(
                id: $0.id,
                title: $0.label,
                value: $0.valueText,
                subtitle: $0.subtitle
            )
        }

        return VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.bottom, 4)

            GlassCardContainer(style: .panel, accent: accent, cornerRadius: 14) {
                SnapshotMetricListView(items: items, accentColor: accent)
            }
        }
    }

    private func balancesSection(title: String, balances: [QuotaBalance]) -> some View {
        let items: [SnapshotMetricItem] = balances.map {
            SnapshotMetricItem(
                id: $0.id,
                title: $0.label,
                value: $0.valueText,
                subtitle: $0.subtitle ?? $0.resetDate.map { "Resets \($0.countdownString)" }
            )
        }

        return VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.bottom, 4)

            GlassCardContainer(style: .panel, accent: accent, cornerRadius: 14) {
                SnapshotMetricListView(items: items, accentColor: accent)
            }
        }
    }

    private var emptyView: some View {
        VStack(spacing: 10) {
            Image(systemName: "tray")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text("No usage data available")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
    }

    private var integrationSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Integration")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)

            HStack(spacing: 10) {
                Text(usageSnapshot.providerID.integrationStatus.badgeTitle)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(accent.opacity(0.16), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                    .foregroundStyle(accent)

                Text(usageSnapshot.providerID.configurationTitle)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.primary)
            }

            Text(usageSnapshot.providerID.configurationDescription)
                .font(.caption)
                .foregroundStyle(.secondary)

            Text(usageSnapshot.providerID.securityNote)
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var metaSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Last updated \(latestFetchedAt.relativeString)", systemImage: "clock")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    private var latestFetchedAt: Date {
        max(usageSnapshot.fetchedAt, telemetrySnapshot?.fetchedAt ?? usageSnapshot.fetchedAt)
    }
}

struct CodexDetailView_Previews: PreviewProvider {
    static var previews: some View {
        NavigationStack {
            CodexDetailView(usageSnapshot: MockData.codexSnapshot, telemetrySnapshot: MockData.codexTelemetrySnapshot)
        }
        .preferredColorScheme(.dark)
    }
}
