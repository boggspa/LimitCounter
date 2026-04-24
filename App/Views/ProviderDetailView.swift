import SwiftUI

struct ProviderDetailView: View {
    let snapshot: QuotaSnapshot

    private var accent: Color { Color(hex: snapshot.providerID.accentColorHex) }

    var body: some View {
        ZStack {
            LiquidGlassBackdrop(style: .ultraThinMaterial)

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
                    QuotaWindowRow(window: window, accentColor: accent)
                }
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

struct ProviderDetailView_Previews: PreviewProvider {
    static var previews: some View {
        NavigationStack {
            ProviderDetailView(snapshot: MockData.codexSnapshot)
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
            LiquidGlassBackdrop(style: .ultraThinMaterial)

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
                    QuotaWindowRow(window: window, accentColor: accent)
                }
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
