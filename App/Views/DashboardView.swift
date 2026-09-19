import SwiftUI
import UniformTypeIdentifiers
#if canImport(UIKit)
import UIKit
#endif

struct DashboardView: View {
    @EnvironmentObject private var appState: AppStateStore
    @StateObject private var visibilityStore = ProviderVisibilityStore.shared
    @StateObject private var orderStore = ProviderCardOrderStore.shared
    @StateObject private var layoutModeStore = DashboardLayoutModeStore.shared
    @State private var showSettings = false
    @State private var draggedProviderID: ProviderID?
    @State private var navigationPath = NavigationPath()
    @AppStorage("dashboardRefreshIntervalSeconds") private var dashboardRefreshIntervalSeconds: Int = 60

    var body: some View {
        NavigationStack(path: $navigationPath) {
            ZStack {
                LiquidGlassBackdrop()

#if os(macOS)
                TransparentWindowConfigurator(cornerRadius: 18)
                    .frame(width: 0, height: 0)
#endif

                dashboardSurface

                usageAlertToastHost
            }
            .refreshable {
                await appState.refresh(userInitiated: true)
            }
            .task(id: dashboardRefreshIntervalSeconds) {
                await appState.refresh()
                while !Task.isCancelled {
                    let delay = appState.suggestedRefreshDelay(defaultIntervalSeconds: dashboardRefreshIntervalSeconds)
                    try? await Task.sleep(for: .seconds(delay))
                    if Task.isCancelled { break }
                    await appState.refresh()
                }
            }
            .navigationTitle("")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .navigationDestination(for: DashboardRoute.self) { route in
                switch route {
                case .provider(let snapshot):
                    ProviderDetailView(snapshot: snapshot)
                case .codexCombined(let usageSnapshot, let telemetrySnapshot):
                    CodexDetailView(usageSnapshot: usageSnapshot, telemetrySnapshot: telemetrySnapshot)
                }
            }
        }
        .tint(ProGlassTheme.accent)
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
        .onChange(of: appState.pendingDeepLinkProviderID) { newValue in
            guard let providerID = newValue else { return }
            if let route = routeForProvider(providerID) {
                navigationPath = NavigationPath()
                navigationPath.append(route)
            }
            appState.pendingDeepLinkProviderID = nil
        }
    }

    @ViewBuilder
    private var usageAlertToastHost: some View {
        if let alert = appState.usageAlerts.first {
            UsageAlertToastView(
                alert: alert,
                pendingCount: appState.usageAlerts.count,
                onOpen: {
                    appState.openUsageAlert(alert)
                },
                onDismiss: {
                    appState.dismissUsageAlert(alert)
                }
            )
            .padding(.horizontal, 12)
            .padding(.top, 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            .transition(.move(edge: .top).combined(with: .opacity))
            .zIndex(10)
            .animation(.spring(response: 0.28, dampingFraction: 0.86), value: appState.usageAlerts)
        }
    }

    private func openSettings() {
        #if os(macOS)
        SettingsWindowManager.shared.showSettingsWindow()
        #else
        showSettings = true
        #endif
    }

    private var dashboardTopBar: some View {
        HStack {
            Spacer(minLength: 0)
            sharedControlPill
        }
    }

    @ViewBuilder
    private var dashboardSurface: some View {
        #if os(macOS)
        GeometryReader { proxy in
            if proxy.size.width >= 720 && proxy.size.height >= 500 {
                desktopDashboardShell
            } else {
                compactDashboardShell
            }
        }
        #else
        GeometryReader { proxy in
            if layoutModeStore.mode == .compact {
                compactDashboardShell
            } else if shouldUseIPadDashboard(size: proxy.size) {
                iPadDashboardShell(size: proxy.size)
            } else {
                compactDashboardShell
            }
        }
        #endif
    }

    private var compactDashboardShell: some View {
        VStack(spacing: 0) {
            dashboardTopBar
                .padding(.horizontal, 12)
                .padding(.top, 8)
                .padding(.bottom, 4)

            ScrollView {
                dashboardCardList(isDesktop: false)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
            }
        }
    }

    #if os(macOS)
    private var desktopDashboardShell: some View {
        HStack(spacing: 0) {
            dashboardSidebar
                .frame(width: 252)

            Rectangle()
                .fill(Color.white.opacity(0.07))
                .frame(width: 1)
                .blendMode(.screen)

            dashboardWorkspace
        }
    }

    private var dashboardSidebar: some View {
        VStack(alignment: .leading, spacing: 14) {
            sidebarBrandLockup
                .padding(.top, 42)

            sidebarSectionTitle("Control")

            VStack(spacing: 6) {
                SidebarUtilityRow(
                    title: "Dashboard",
                    subtitle: "\(visibleSnapshots.count) visible providers",
                    systemImage: "gauge",
                    accent: ProGlassTheme.accent,
                    isActive: true
                )

                SidebarUtilityRow(
                    title: appState.isSyncing ? "Refreshing" : "Refresh",
                    subtitle: lastSyncText,
                    systemImage: appState.isSyncing ? "arrow.triangle.2.circlepath" : "arrow.clockwise",
                    accent: ProGlassTheme.accent,
                    isActive: appState.isSyncing
                ) {
                    Task { await appState.refresh(userInitiated: true) }
                }
            }

            sidebarSectionTitle("Providers")

            VStack(spacing: 5) {
                ForEach(ProviderID.userFacingCases) { providerID in
                    if let route = routeForProvider(providerID) {
                        NavigationLink(value: route) {
                            ProviderSidebarRow(
                                providerID: providerID,
                                snapshot: snapshotFor(providerID),
                                isVisible: visibilityStore.isVisible(providerID)
                            )
                        }
                        .buttonStyle(.plain)
                    } else {
                        ProviderSidebarRow(
                            providerID: providerID,
                            snapshot: snapshotFor(providerID),
                            isVisible: visibilityStore.isVisible(providerID)
                        )
                        .opacity(0.72)
                    }
                }
            }

            Spacer(minLength: 10)

            sidebarStatusPanel
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 14)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(
            GlassPanel(
                style: .darkPanel,
                accent: ProGlassTheme.accent,
                shape: Rectangle()
            )
        )
    }

    private var sidebarBrandLockup: some View {
        HStack(alignment: .center, spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(ProGlassTheme.accent.opacity(0.14))
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(ProGlassTheme.accent.opacity(0.24), lineWidth: 1)
                Image(systemName: "chart.bar.xaxis")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(ProGlassTheme.accent)
            }
            .frame(width: 34, height: 34)

            VStack(alignment: .leading, spacing: 1) {
                Text("Limit Counter")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white)
                Text("Quota monitor")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func sidebarSectionTitle(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: 9, weight: .bold))
            .tracking(0.9)
            .foregroundStyle(.tertiary)
            .padding(.top, 2)
    }

    private var sidebarStatusPanel: some View {
        GlassCardContainer(style: .hud, accent: ProGlassTheme.accent, cornerRadius: 14) {
            VStack(alignment: .leading, spacing: 9) {
                Text("Sync Monitor")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white.opacity(0.88))

                StatusReadoutRow(title: "State", value: appState.isSyncing ? "Active" : "Idle", color: appState.isSyncing ? ProGlassTheme.accent : .secondary)
                StatusReadoutRow(title: "Errors", value: "\(appState.syncErrors.count)", color: appState.syncErrors.isEmpty ? .secondary : .red)
                StatusReadoutRow(title: "Interval", value: "\(dashboardRefreshIntervalSeconds)s", color: .secondary)

                Button {
                    openSettings()
                } label: {
                    Label("Open Settings", systemImage: "slider.horizontal.3")
                        .font(.caption.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 7)
                        .foregroundStyle(.white)
                        .background(ProGlassTheme.accent.opacity(0.20), in: Capsule(style: .continuous))
                }
                .buttonStyle(.plain)
                .padding(.top, 2)
            }
        }
    }

    private var dashboardWorkspace: some View {
        ZStack(alignment: .bottom) {
            ScrollView {
                VStack(alignment: .center, spacing: 18) {
                    desktopNavigationPill
                    workspaceHeader
                    dashboardCardList(isDesktop: true)
                }
                .frame(maxWidth: 850)
                .padding(.horizontal, 28)
                .padding(.top, 28)
                .padding(.bottom, 112)
                .frame(maxWidth: .infinity, alignment: .top)
            }

            bottomControlDock
                .padding(.horizontal, 28)
                .padding(.bottom, 24)
        }
        .background(cinematicWorkspaceBackground)
    }

    private var desktopNavigationPill: some View {
        HStack(spacing: 2) {
            navigationPillItem(title: "Dashboard", systemImage: "rectangle.grid.2x2", isActive: true) {}
            navigationPillItem(title: "Activity", systemImage: "waveform.path.ecg", isActive: false) {}
            navigationPillItem(title: "Providers", systemImage: "square.stack.3d.up", isActive: false) {
                openSettings()
            }
            navigationPillItem(title: "Settings", systemImage: "gearshape", isActive: false) {
                openSettings()
            }
        }
        .padding(4)
        .background(
            GlassPanel(style: .hud, accent: ProGlassTheme.accent, shape: Capsule(style: .continuous))
        )
    }

    private func navigationPillItem(
        title: String,
        systemImage: String,
        isActive: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.system(size: 11, weight: .bold))
                .labelStyle(.titleAndIcon)
                .foregroundStyle(isActive ? .white : .secondary)
                .padding(.horizontal, 10)
                .frame(height: 28)
                .background(
                    Capsule(style: .continuous)
                        .fill(isActive ? ProGlassTheme.accent.opacity(0.18) : Color.clear)
                )
                .overlay(
                    Capsule(style: .continuous)
                        .strokeBorder(isActive ? ProGlassTheme.accent.opacity(0.30) : Color.clear, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }

    private var workspaceHeader: some View {
        GlassCardContainer(style: .header, accent: ProGlassTheme.accent, cornerRadius: 20) {
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Usage Command Center")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(.white)

                    Text("Live quota, local telemetry, and provider health in one low-noise glass workspace.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 12)

                HStack(spacing: 8) {
                    HeaderMetricPill(title: "Visible", value: "\(visibleSnapshots.count)", accent: ProGlassTheme.accent)
                    HeaderMetricPill(title: "Sources", value: "\(appState.snapshots.count)", accent: ProGlassTheme.panelAccent)
                }
            }
        }
    }

    private var bottomControlDock: some View {
        HStack(spacing: 12) {
            dockButton(systemImage: appState.isSyncing ? "arrow.triangle.2.circlepath" : "arrow.clockwise", title: "Refresh") {
                Task { await appState.refresh(userInitiated: true) }
            }
            .disabled(appState.isSyncing)

            dockButton(systemImage: "gearshape.fill", title: "Settings") {
                openSettings()
            }

            dockButton(systemImage: appState.isHeadlessMode ? "eye.slash.fill" : "eye.fill", title: "Headless") {
                appState.isHeadlessMode.toggle()
            }

            Rectangle()
                .fill(Color.white.opacity(0.10))
                .frame(width: 1, height: 26)

            VStack(alignment: .leading, spacing: 1) {
                Text(lastSyncText)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(appState.syncErrors.isEmpty ? "All visible sources are monitored locally" : "\(appState.syncErrors.count) source errors")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(appState.syncErrors.isEmpty ? Color.secondary.opacity(0.62) : Color.red.opacity(0.85))
            }

            Spacer(minLength: 12)

            Text(appState.isSyncing ? "SYNC" : "IDLE")
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .tracking(1.2)
                .foregroundStyle(appState.isSyncing ? ProGlassTheme.accent : .secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(maxWidth: 720)
        .background(
            GlassPanel(
                style: .hud,
                accent: ProGlassTheme.accent,
                shape: RoundedRectangle(cornerRadius: 18, style: .continuous)
            )
        )
    }

    private func dockButton(systemImage: String, title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(title == "Refresh" && appState.isSyncing ? ProGlassTheme.accent : .white.opacity(0.88))
                .frame(width: 32, height: 28)
                .background(Color.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.10), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }

    private var cinematicWorkspaceBackground: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(hex: "#070A12").opacity(0.18),
                    Color(hex: "#0B111D").opacity(0.30),
                    Color.black.opacity(0.20)
                ],
                startPoint: .top,
                endPoint: .bottom
            )

            RadialGradient(
                colors: [
                    ProGlassTheme.accent.opacity(0.10),
                    Color.clear
                ],
                center: UnitPoint(x: 0.58, y: 0.10),
                startRadius: 20,
                endRadius: 520
            )
            .blendMode(.screen)
        }
    }
    #endif

    #if os(iOS)
    private func shouldUseIPadDashboard(size: CGSize) -> Bool {
        UIDevice.current.userInterfaceIdiom == .pad && size.width >= 860 && size.height >= 560
    }

    private func iPadDashboardShell(size: CGSize) -> some View {
        let rightColumnWidth = min(max(size.width * 0.34, 360), 470)

        return VStack(spacing: 0) {
            iPadDashboardHeader
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 10)

            HStack(alignment: .top, spacing: 14) {
                iPadUsageColumn
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                iPadInsightColumn
                    .frame(width: rightColumnWidth)
                    .frame(maxHeight: .infinity)
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 14)
        }
        .background(iPadWorkspaceBackground)
    }

    private var iPadDashboardHeader: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Dashboard")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(.white)

                Text(lastSyncText)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 16)

            iPadStatusTiles

            sharedControlPill
        }
    }

    private var iPadStatusTiles: some View {
        HStack(spacing: 8) {
            iPadStatusTile(title: "Meters", value: "\(usageMeterCards.count)", accent: ProGlassTheme.accent)
            iPadStatusTile(title: "Signals", value: "\(appState.syncErrors.count)", accent: appState.syncErrors.isEmpty ? ProGlassTheme.panelAccent : .red)
        }
    }

    private func iPadStatusTile(title: String, value: String, accent: Color) -> some View {
        VStack(alignment: .trailing, spacing: 1) {
            Text(title.uppercased())
                .font(.system(size: 8, weight: .bold))
                .tracking(0.7)
                .foregroundStyle(.tertiary)
            Text(value)
                .font(.system(size: 16, weight: .bold, design: .monospaced))
                .foregroundStyle(accent)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(accent.opacity(0.09), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(accent.opacity(0.18), lineWidth: 1)
        )
    }

    private var iPadUsageColumn: some View {
        GlassCardContainer(style: .bare, accent: ProGlassTheme.accent, cornerRadius: 22) {
            VStack(alignment: .leading, spacing: 10) {
                iPadColumnHeader(
                    title: "Meters",
                    subtitle: "\(usageMeterCards.count) active cards",
                    systemImage: "gauge.with.dots.needle.50percent",
                    accent: ProGlassTheme.accent
                )
                .padding(.horizontal, 2)

                ScrollView {
                    LazyVStack(spacing: 12) {
                        if usageMeterCards.isEmpty {
                            GlassCardContainer(style: .panel, accent: ProGlassTheme.accent, cornerRadius: 16) {
                                emptyDashboardState
                            }
                        } else {
                            ForEach(usageMeterCards) { item in
                                dashboardCard(item)
                            }
                        }
                    }
                    .padding(.bottom, 8)
                }
            }
        }
    }

    private var iPadInsightColumn: some View {
        VStack(alignment: .leading, spacing: 10) {
            iPadColumnHeader(
                title: "Telemetry",
                subtitle: "\(iPadInsightSnapshots.count) sources",
                systemImage: "waveform.path.ecg.rectangle",
                accent: ProGlassTheme.panelAccent
            )

            ScrollView {
                VStack(spacing: 12) {
                    LLMActivityHeatmapView(snapshots: appState.snapshots)
                        .frame(height: 232)

                    ForEach(iPadInsightSnapshots) { snapshot in
                        iPadInsightCard(snapshot)
                    }

                    if iPadInsightSnapshots.isEmpty {
                        GlassCardContainer(style: .panel, accent: ProGlassTheme.panelAccent, cornerRadius: 16) {
                            Text("No telemetry yet")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .padding(.bottom, 8)
            }
        }
    }

    private func iPadColumnHeader(title: String, subtitle: String, systemImage: String, accent: Color) -> some View {
        HStack(spacing: 9) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(accent)
                .frame(width: 28, height: 28)
                .background(accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 9, style: .continuous))

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white.opacity(0.92))
                Text(subtitle)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            GlassPanel(
                style: .hud,
                accent: accent,
                shape: RoundedRectangle(cornerRadius: 16, style: .continuous)
            )
        )
    }

    private func iPadInsightCard(_ snapshot: QuotaSnapshot) -> some View {
        let accent = iPadAccent(for: snapshot)
        let metricItems = iPadMetricItems(for: snapshot)
        let balanceItems = iPadBalanceItems(for: snapshot)

        return GlassCardContainer(style: .panel, accent: accent, cornerRadius: 16) {
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 8) {
                    ProviderBrandIconView(providerID: iPadDisplayProvider(for: snapshot), size: 22)

                    VStack(alignment: .leading, spacing: 1) {
                        Text(iPadInsightTitle(for: snapshot))
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.white.opacity(0.92))
                            .lineLimit(1)

                        Text(snapshot.statsSectionTitle ?? snapshot.balancesSectionTitle ?? "Local telemetry")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 8)

                    Text(snapshot.fetchedAt.relativeString)
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }

                if !snapshot.signals.isEmpty {
                    VStack(spacing: 6) {
                        ForEach(snapshot.signals.prefix(2)) { signal in
                            iPadSignalRow(signal, accent: accent)
                        }
                    }
                }

                if !metricItems.isEmpty {
                    SnapshotMetricListView(items: Array(metricItems.prefix(6)), accentColor: accent)
                }

                if !balanceItems.isEmpty {
                    SnapshotMetricListView(items: Array(balanceItems.prefix(3)), accentColor: accent)
                }
            }
        }
    }

    private func iPadSignalRow(_ signal: QuotaSignal, accent: Color) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "sparkles.rectangle.stack")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(accent)
                .frame(width: 20, height: 20)
                .background(accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 6, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(signal.title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(signal.message)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(8)
        .background(Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var usageMeterCards: [DashboardCardItem] {
        dashboardCards.filter { item in
            if case .heatmap = item { return false }
            return true
        }
    }

    private var iPadInsightSnapshots: [QuotaSnapshot] {
        appState.snapshots
            .filter { snapshot in
                snapshot.fetchState == .success
                    && (snapshot.providerID == .codexTelemetry || visibilityStore.isVisible(snapshot.providerID))
                    && (!snapshot.stats.isEmpty || !snapshot.balances.isEmpty || !snapshot.signals.isEmpty)
            }
            .sorted {
                iPadInsightRank(for: $0.providerID) < iPadInsightRank(for: $1.providerID)
            }
    }

    private func iPadInsightRank(for providerID: ProviderID) -> Int {
        if providerID == .codexTelemetry { return ProviderCardOrderStore.nonisolatedRank(for: .openai) - 1 }
        return ProviderCardOrderStore.nonisolatedRank(for: providerID)
    }

    private func iPadDisplayProvider(for snapshot: QuotaSnapshot) -> ProviderID {
        snapshot.providerID == .codexTelemetry ? .openai : snapshot.providerID
    }

    private func iPadAccent(for snapshot: QuotaSnapshot) -> Color {
        Color(hex: iPadDisplayProvider(for: snapshot).accentColorHex)
    }

    private func iPadInsightTitle(for snapshot: QuotaSnapshot) -> String {
        snapshot.providerID == .codexTelemetry ? "Codex Telemetry" : snapshot.displayName
    }

    private func iPadMetricItems(for snapshot: QuotaSnapshot) -> [SnapshotMetricItem] {
        snapshot.stats.map {
            SnapshotMetricItem(id: $0.id, title: $0.label, value: $0.valueText, subtitle: $0.subtitle)
        }
    }

    private func iPadBalanceItems(for snapshot: QuotaSnapshot) -> [SnapshotMetricItem] {
        snapshot.balances.map {
            SnapshotMetricItem(
                id: $0.id,
                title: $0.label,
                value: $0.valueText,
                subtitle: $0.subtitle ?? $0.resetDate.map { "Resets \($0.countdownString)" }
            )
        }
    }

    private var iPadWorkspaceBackground: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(hex: "#070A12").opacity(0.20),
                    Color(hex: "#0B111D").opacity(0.30),
                    Color.black.opacity(0.20)
                ],
                startPoint: .top,
                endPoint: .bottom
            )

            RadialGradient(
                colors: [
                    ProGlassTheme.accent.opacity(0.05),
                    Color.clear
                ],
                center: UnitPoint(x: 0.58, y: 0.10),
                startRadius: 20,
                endRadius: 620
            )
            .blendMode(.screen)
        }
    }
    #endif

    private var visibleSnapshots: [QuotaSnapshot] {
        appState.visibleSnapshots.filter { visibilityStore.isVisible($0.providerID) }
    }

    private var dashboardCards: [DashboardCardItem] {
        let snapshots = visibleSnapshots
        let allSnapshots = appState.snapshots

        var cards: [DashboardCardItem] = []
        var consumedProviders = Set<ProviderID>()

        if visibilityStore.isVisible(.heatmap) {
            cards.append(.heatmap(snapshots: appState.snapshots))
        }

        let usageSnapshot = snapshots.first(where: { $0.providerID == .openai })
        let telemetrySnapshot = allSnapshots.first {
            $0.providerID == .codexTelemetry && $0.fetchState == .success && $0.hasContent
        }

        if let usageSnapshot {
            if let telemetrySnapshot {
                cards.append(.combinedCodex(usageSnapshot: usageSnapshot, telemetrySnapshot: telemetrySnapshot))
                consumedProviders.insert(.openai)
                consumedProviders.insert(.codexTelemetry)
            } else {
                cards.append(.snapshot(usageSnapshot))
                consumedProviders.insert(.openai)
            }
        }

        for snapshot in snapshots where !consumedProviders.contains(snapshot.providerID) && snapshot.providerID != .codexTelemetry {
            cards.append(.snapshot(snapshot))
        }

        return cards.sorted { lhs, rhs in
            let lhsRank = orderStore.rank(for: lhs.orderProviderID)
            let rhsRank = orderStore.rank(for: rhs.orderProviderID)
            if lhsRank == rhsRank {
                return lhs.orderProviderID.rawValue < rhs.orderProviderID.rawValue
            }
            return lhsRank < rhsRank
        }
    }

    private func snapshotFor(_ providerID: ProviderID) -> QuotaSnapshot? {
        appState.snapshots.first { $0.providerID == providerID }
    }

    private func routeForProvider(_ providerID: ProviderID) -> DashboardRoute? {
        guard let snapshot = snapshotFor(providerID) else { return nil }

        if providerID == .openai,
           let telemetrySnapshot = appState.snapshots.first(where: { $0.providerID == .codexTelemetry && $0.fetchState == .success && $0.hasContent }) {
            return .codexCombined(usageSnapshot: snapshot, telemetrySnapshot: telemetrySnapshot)
        }

        return .provider(snapshot)
    }

    private var lastSyncText: String {
        if appState.isSyncing {
            return "Refreshing now"
        }
        if let lastSyncDate = appState.lastSyncDate {
            return "Updated \(lastSyncDate.relativeString)"
        }
        return "Awaiting first refresh"
    }

    @ViewBuilder
    private func dashboardCardList(isDesktop: Bool) -> some View {
        // Wrapping the card stack in `GlassEffectContainer` lets the
        // OS render all of the per-card Liquid Glass surfaces in a
        // single shared pass — they share specular lighting, edge
        // lensing, and can morph together during scroll. The default
        // spacing parameter controls how closely-stacked glass blobs
        // start visually merging; the dashboard's 10-12pt gap is wide
        // enough that we don't need a tighter value.
        if #available(macOS 26.0, iOS 26.0, *) {
            GlassEffectContainer {
                dashboardCardLazyStack(isDesktop: isDesktop)
            }
        } else {
            dashboardCardLazyStack(isDesktop: isDesktop)
        }
    }

    private func dashboardCardLazyStack(isDesktop: Bool) -> some View {
        LazyVStack(spacing: isDesktop ? 12 : 10) {
            if layoutModeStore.mode == .compact {
                compactLayoutBody(isDesktop: isDesktop)
            } else if dashboardCards.isEmpty {
                GlassCardContainer(style: .panel, accent: ProGlassTheme.accent, cornerRadius: 16) {
                    emptyDashboardState
                }
            } else {
                ForEach(dashboardCards) { item in
                    dashboardCard(item)
                }
            }
        }
        .frame(maxWidth: isDesktop ? 760 : .infinity, alignment: .topLeading)
    }

    /// Compact layout: a single tall card lists every visible
    /// provider's meters back-to-back, with the activity heatmap kept
    /// as its own card below. The provider order matches the standard
    /// layout's `dashboardCards` (so user reordering carries over).
    @ViewBuilder
    private func compactLayoutBody(isDesktop: Bool) -> some View {
        let snapshots = orderedCompactSnapshots()
        if snapshots.isEmpty {
            GlassCardContainer(style: .panel, accent: ProGlassTheme.accent, cornerRadius: 16) {
                emptyDashboardState
            }
        } else {
            let showsHeatmap = visibilityStore.isVisible(.heatmap)
            let heatmapLeads = showsHeatmap && heatmapSortsAboveCompactStack(snapshots)

            if heatmapLeads {
                compactHeatmapCard
            }

            CompactDashboardCardView(
                snapshots: snapshots,
                sevenDayResetCounts: appState.sevenDayResetCounts,
                reorderableProviderIDs: reorderableProviderIDs,
                draggedProviderID: $draggedProviderID,
                orderStore: orderStore
            )

            if showsHeatmap && !heatmapLeads {
                compactHeatmapCard
            }
        }
    }

    private var compactHeatmapCard: some View {
        LLMActivityHeatmapView(snapshots: appState.snapshots)
            .dashboardReorderable(
                providerID: .heatmap,
                reorderableProviderIDs: reorderableProviderIDs,
                draggedProviderID: $draggedProviderID,
                orderStore: orderStore
            )
    }

    /// Compact mode folds every provider into a single card, so the
    /// heatmap can only sit above or below that stack. It leads when the
    /// user has dragged it above the first visible provider in the
    /// standard layout.
    private func heatmapSortsAboveCompactStack(_ snapshots: [QuotaSnapshot]) -> Bool {
        guard let first = snapshots.first else { return false }
        return orderStore.rank(for: .heatmap) < orderStore.rank(for: first.providerID)
    }

    /// Returns visible snapshots in the same order the standard layout
    /// produces — respecting `ProviderCardOrderStore` ranks and the
    /// alphabetical tiebreaker.
    private func orderedCompactSnapshots() -> [QuotaSnapshot] {
        visibleSnapshots
            .filter { $0.providerID != .codexTelemetry }
            .sorted { lhs, rhs in
                let lhsRank = orderStore.rank(for: lhs.providerID)
                let rhsRank = orderStore.rank(for: rhs.providerID)
                if lhsRank == rhsRank {
                    return lhs.providerID.rawValue < rhs.providerID.rawValue
                }
                return lhsRank < rhsRank
            }
    }

    @ViewBuilder
    private func dashboardCard(_ item: DashboardCardItem) -> some View {
        Group {
            if let route = item.navigationRoute {
                NavigationLink(value: route) {
                    item.cardView(isRefreshing: appState.isSyncing)
                }
            } else {
                item.cardView(isRefreshing: appState.isSyncing)
            }
        }
        .buttonStyle(.plain)
        .dashboardReorderable(
            providerID: item.orderProviderID,
            reorderableProviderIDs: reorderableProviderIDs,
            draggedProviderID: $draggedProviderID,
            orderStore: orderStore
        )
    }

    /// Every card currently on screen, so a drop only reorders cards
    /// that belong to the same visible stack.
    private var reorderableProviderIDs: Set<ProviderID> {
        var ids = Set(visibleSnapshots.map { $0.providerID == .codexTelemetry ? .openai : $0.providerID })
        if visibilityStore.isVisible(.heatmap) {
            ids.insert(.heatmap)
        }
        return ids
    }

    private var emptyDashboardState: some View {
        VStack(alignment: .leading, spacing: 6) {
            if appState.snapshots.isEmpty {
                Text("No synced data yet")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                Text("Open the Mac app and refresh it once while both devices are online to publish the first status snapshot.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("No providers visible")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                Text("Turn one or more providers back on in Settings to show their cards here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 6)
    }

    private var sharedControlPill: some View {
        HStack(spacing: 0) {
            controlPillButton(
                accessibilityLabel: appState.isSyncing ? "Refreshing dashboard" : "Refresh dashboard"
            ) {
                Task { await appState.refresh(userInitiated: true) }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .foregroundStyle(.white)
            }
            .disabled(appState.isSyncing)

            Rectangle()
                .fill(Color.white.opacity(0.12))
                .frame(width: 1, height: 18)
                .padding(.vertical, 6)

            controlPillButton(
                accessibilityLabel: "Open settings"
            ) {
                openSettings()
            } label: {
                Image(systemName: "gearshape.fill")
                    .foregroundStyle(.white)
            }

            Rectangle()
                .fill(Color.white.opacity(0.12))
                .frame(width: 1, height: 18)
                .padding(.vertical, 6)

            controlPillButton(
                accessibilityLabel: layoutModeStore.mode == .compact
                    ? "Switch to standard layout"
                    : "Switch to compact layout"
            ) {
                layoutModeStore.toggle()
            } label: {
                // SF symbols: `rectangle.compress.vertical` while in
                // standard mode (the action would compress), and
                // `rectangle.expand.vertical` while in compact mode
                // (the action would expand).
                Image(systemName: layoutModeStore.mode == .compact
                      ? "rectangle.expand.vertical"
                      : "rectangle.compress.vertical")
                    .foregroundStyle(layoutModeStore.mode == .compact ? ProGlassTheme.accent : .white)
            }

            #if os(iOS)
            Rectangle()
                .fill(Color.white.opacity(0.12))
                .frame(width: 1, height: 18)
                .padding(.vertical, 6)

            controlPillButton(
                accessibilityLabel: "Take screenshot of quota card"
            ) {
                takeQuotaCardScreenshot()
            } label: {
                Image(systemName: "camera.fill")
                    .foregroundStyle(.white)
            }
            #endif

            #if os(macOS)
            Rectangle()
                .fill(Color.white.opacity(0.12))
                .frame(width: 1, height: 18)
                .padding(.vertical, 6)

            controlPillButton(
                accessibilityLabel: appState.isHeadlessMode ? "Disable Headless Mode" : "Enable Headless Mode"
            ) {
                appState.isHeadlessMode.toggle()
            } label: {
                Image(systemName: appState.isHeadlessMode ? "eye.slash.fill" : "eye.fill")
                    .foregroundStyle(appState.isHeadlessMode ? ProGlassTheme.accent : .white)
            }
            #endif
        }
        .padding(4)
        .background(
            GlassPanel(style: .hud, accent: ProGlassTheme.accent, shape: Capsule(style: .continuous))
        )
    }

    private func controlPillButton<Label: View>(
        accessibilityLabel: String,
        action: @escaping () -> Void,
        @ViewBuilder label: () -> Label
    ) -> some View {
        Button(action: action) {
            label()
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 34, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
    }

    #if os(iOS)
    @MainActor private func takeQuotaCardScreenshot() {
        // Create a sample quota card view for screenshot
        // Using the first available snapshot or a mock one
        let sampleSnapshot = appState.snapshots.first ?? MockData.claudeSnapshot
        let quotaCard = QuotaCardView(snapshot: sampleSnapshot)
            .frame(width: 320) // Fixed width for consistent screenshot
            .environmentObject(appState)

        // Convert SwiftUI view to UIImage
        let hostingController = UIHostingController(rootView: quotaCard)
        hostingController.view.frame = CGRect(x: 0, y: 0, width: 320, height: 200)
        hostingController.view.layoutIfNeeded()

        let renderer = UIGraphicsImageRenderer(size: hostingController.view.bounds.size)
        let image = renderer.image { ctx in
            hostingController.view.drawHierarchy(in: hostingController.view.bounds, afterScreenUpdates: true)
        }

        // Save to photo library
        UIImageWriteToSavedPhotosAlbum(image, nil, nil, nil)
    }
    #endif
}

private struct UsageAlertToastView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var celebrationIsActive = false

    let alert: CloudAlertPayload
    let pendingCount: Int
    let onOpen: () -> Void
    let onDismiss: () -> Void

    private var accent: Color {
        Color(hex: alert.providerID.accentColorHex)
    }

    private var badgeTitle: String {
        alert.badgeTitle
    }

    var body: some View {
        GlassCardContainer(style: .hud, accent: accent, cornerRadius: 16) {
            HStack(alignment: .top, spacing: 10) {
                ProviderBrandIconView(providerID: alert.providerID, size: 28)

                Button(action: onOpen) {
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(alert.title)
                                .font(.caption.weight(.bold))
                                .foregroundStyle(.white.opacity(0.94))
                                .lineLimit(1)
                                .minimumScaleFactor(0.82)

                            Spacer(minLength: 8)

                            Text(badgeTitle)
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(accent)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(accent.opacity(0.14), in: Capsule(style: .continuous))
                        }

                        if let windowLabel = alert.windowLabel, !windowLabel.isEmpty {
                            Text(windowLabel)
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(accent)
                                .lineLimit(1)
                        }

                        Text(alert.body)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                            .fixedSize(horizontal: false, vertical: true)

                        HStack(spacing: 7) {
                            Image(systemName: "clock")
                                .font(.system(size: 9, weight: .semibold))
                            Text("Noticed \(alert.createdAt.relativeString)")
                                .font(.system(size: 10, weight: .semibold))

                            if pendingCount > 1 {
                                Text("+\(pendingCount - 1)")
                                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1)
                                    .background(accent.opacity(0.24), in: Capsule(style: .continuous))
                            }
                        }
                        .foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 24, height: 24)
                        .background(Color.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss reset alert")
            }
        }
        .frame(maxWidth: 360, alignment: .topTrailing)
        .overlay {
            if alert.kind.isUsageReset {
                ResetCelebrationEffect(
                    accent: accent,
                    reduceMotion: reduceMotion,
                    isAnimated: celebrationIsActive
                )
            }
        }
        .shadow(color: accent.opacity(0.30), radius: 22, y: 8)
        .task(id: alert.signature) {
            let remaining = 12 - Date().timeIntervalSince(alert.createdAt)
            guard !reduceMotion, remaining > 0 else {
                celebrationIsActive = false
                return
            }

            celebrationIsActive = true
            try? await Task.sleep(for: .seconds(remaining))
            guard !Task.isCancelled else { return }
            celebrationIsActive = false
        }
    }
}

private struct ResetCelebrationEffect: View {
    let accent: Color
    let reduceMotion: Bool
    let isAnimated: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 24.0, paused: reduceMotion || !isAnimated)) { timeline in
            let phase = reduceMotion || !isAnimated
                ? 0.0
                : timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 3) / 3

            ResetCelebrationFrame(
                accent: accent,
                phase: phase,
                reduceMotion: reduceMotion || !isAnimated
            )
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct ResetCelebrationFrame: View {
    let accent: Color
    let phase: Double
    let reduceMotion: Bool

    private let sparkCount = 7

    private var rainbow: AngularGradient {
        AngularGradient(
            colors: [accent, .cyan, .blue, .purple, .pink, .orange, .yellow, .green, accent],
            center: .center,
            angle: .degrees(phase * 360)
        )
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(rainbow, lineWidth: 2)
                    .shadow(color: accent.opacity(0.55), radius: 7)

                ForEach(0..<sparkCount, id: \.self) { index in
                    ResetOrbitingSpark(
                        index: index,
                        count: sparkCount,
                        phase: phase,
                        reduceMotion: reduceMotion,
                        containerSize: proxy.size
                    )
                }
            }
        }
    }
}

private struct ResetOrbitingSpark: View {
    let index: Int
    let count: Int
    let phase: Double
    let reduceMotion: Bool
    let containerSize: CGSize

    private var angle: Double {
        (Double(index) / Double(count) + phase) * Double.pi * 2
    }

    private var pulse: Double {
        guard !reduceMotion else { return 0.72 }
        return 0.45 + 0.55 * ((sin(phase * Double.pi * 6 + Double(index)) + 1) / 2)
    }

    private var sparkPosition: CGPoint {
        CGPoint(
            x: containerSize.width / 2 + cos(angle) * max(0, containerSize.width / 2 - 7),
            y: containerSize.height / 2 + sin(angle) * max(0, containerSize.height / 2 - 7)
        )
    }

    var body: some View {
        Image(systemName: index.isMultiple(of: 2) ? "sparkle" : "bolt.fill")
            .font(.system(size: index.isMultiple(of: 2) ? 8 : 6, weight: .bold))
            .foregroundStyle(sparkColor)
            .shadow(color: sparkColor.opacity(0.85), radius: 4)
            .scaleEffect(0.82 + pulse * 0.38)
            .opacity(pulse)
            .position(sparkPosition)
    }

    private var sparkColor: Color {
        switch index % 6 {
        case 0: return .cyan
        case 1: return .blue
        case 2: return .purple
        case 3: return .pink
        case 4: return .orange
        default: return .green
        }
    }
}

#if os(macOS)
private struct SidebarUtilityRow: View {
    let title: String
    let subtitle: String
    let systemImage: String
    let accent: Color
    let isActive: Bool
    var action: (() -> Void)? = nil

    var body: some View {
        Group {
            if let action {
                Button(action: action) {
                    rowContent
                }
                .buttonStyle(.plain)
            } else {
                rowContent
            }
        }
    }

    private var rowContent: some View {
        HStack(spacing: 9) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(isActive ? accent : .secondary)
                .frame(width: 24, height: 24)
                .background(Color.white.opacity(isActive ? 0.075 : 0.035), in: RoundedRectangle(cornerRadius: 7, style: .continuous))

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(isActive ? .white : .secondary)
                Text(subtitle)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }

            Spacer(minLength: 6)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(isActive ? accent.opacity(0.105) : Color.white.opacity(0.028))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(isActive ? accent.opacity(0.20) : Color.white.opacity(0.055), lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
    }
}

private struct ProviderSidebarRow: View {
    let providerID: ProviderID
    let snapshot: QuotaSnapshot?
    let isVisible: Bool

    private var accent: Color { Color(hex: providerID.accentColorHex) }

    var body: some View {
        HStack(spacing: 9) {
            ProviderBrandIconView(providerID: providerID, size: 20)

            VStack(alignment: .leading, spacing: 1) {
                Text(providerID.displayName)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(isVisible ? .white.opacity(0.88) : .secondary)

                Text(statusText)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }

            Spacer(minLength: 6)

            Circle()
                .fill(statusColor)
                .frame(width: 6, height: 6)
                .shadow(color: statusColor.opacity(isVisible ? 0.45 : 0), radius: 4)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(Color.white.opacity(isVisible ? 0.032 : 0.018), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(Color.white.opacity(isVisible ? 0.075 : 0.035), lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
    }

    private var statusText: String {
        guard isVisible else { return "Hidden" }
        guard let snapshot else { return "No snapshot" }

        switch snapshot.fetchState {
        case .success:
            return snapshot.hasContent ? "Live data" : "No data"
        case .error:
            return "Update failed"
        case .notConfigured:
            return "Setup required"
        }
    }

    private var statusColor: Color {
        guard isVisible else { return .secondary.opacity(0.55) }
        guard let snapshot else { return .secondary.opacity(0.65) }

        switch snapshot.fetchState {
        case .success:
            return snapshot.hasContent ? accent : .secondary.opacity(0.70)
        case .error:
            return .red
        case .notConfigured:
            return Color(hex: "#F59E0B")
        }
    }
}

private struct StatusReadoutRow: View {
    let title: String
    let value: String
    let color: Color

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.tertiary)
            Spacer(minLength: 8)
            Text(value)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(color)
        }
    }
}

private struct HeaderMetricPill: View {
    let title: String
    let value: String
    let accent: Color

    var body: some View {
        VStack(alignment: .trailing, spacing: 1) {
            Text(title.uppercased())
                .font(.system(size: 8, weight: .bold))
                .tracking(0.8)
                .foregroundStyle(.tertiary)
            Text(value)
                .font(.system(size: 17, weight: .bold, design: .monospaced))
                .foregroundStyle(accent)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(accent.opacity(0.20), lineWidth: 1)
        )
    }
}
#endif

private enum DashboardCardItem: Identifiable {
    case snapshot(QuotaSnapshot)
    case combinedCodex(usageSnapshot: QuotaSnapshot, telemetrySnapshot: QuotaSnapshot)
    case heatmap(snapshots: [QuotaSnapshot])

    var id: String {
        orderProviderID.rawValue
    }

    var navigationRoute: DashboardRoute? {
        switch self {
        case .snapshot(let snapshot):
            return .provider(snapshot)
        case .combinedCodex(let usageSnapshot, let telemetrySnapshot):
            return .codexCombined(usageSnapshot: usageSnapshot, telemetrySnapshot: telemetrySnapshot)
        case .heatmap:
            return nil
        }
    }

    var orderProviderID: ProviderID {
        switch self {
        case .snapshot(let snapshot):
            return snapshot.providerID == .codexTelemetry ? .openai : snapshot.providerID
        case .combinedCodex:
            return .openai
        case .heatmap:
            return .heatmap
        }
    }

    @ViewBuilder
    func cardView(isRefreshing: Bool) -> some View {
        switch self {
        case .snapshot(let snapshot):
            QuotaCardView(snapshot: snapshot, isRefreshing: isRefreshing)
        case .combinedCodex(let usageSnapshot, let telemetrySnapshot):
            CodexOverviewCardView(
                usageSnapshot: usageSnapshot,
                telemetrySnapshot: telemetrySnapshot,
                isRefreshing: isRefreshing
            )
        case .heatmap(let snapshots):
            LLMActivityHeatmapView(snapshots: snapshots)
        }
    }
}

private enum DashboardRoute: Hashable {
    case provider(_ snapshot: QuotaSnapshot)
    case codexCombined(usageSnapshot: QuotaSnapshot, telemetrySnapshot: QuotaSnapshot)
}

private struct DashboardCardDropDelegate: DropDelegate {
    let targetProviderID: ProviderID
    let reorderableProviderIDs: Set<ProviderID>
    @Binding var draggedProviderID: ProviderID?
    let orderStore: ProviderCardOrderStore

    func dropEntered(info: DropInfo) {
        guard
            let draggedProviderID,
            draggedProviderID != targetProviderID,
            reorderableProviderIDs.contains(draggedProviderID)
        else {
            return
        }

        withAnimation(.easeInOut(duration: 0.18)) {
            orderStore.move(draggedProviderID, toward: targetProviderID)
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        draggedProviderID = nil
        return true
    }
}

/// Shared drag-to-reorder plumbing for every dashboard surface — the
/// standard card stack, the compact stacked-meters rows, and the
/// activity heatmap card.
private struct DashboardReorderModifier: ViewModifier {
    let providerID: ProviderID
    let reorderableProviderIDs: Set<ProviderID>
    @Binding var draggedProviderID: ProviderID?
    let orderStore: ProviderCardOrderStore

    func body(content: Content) -> some View {
        content
            .opacity(draggedProviderID == providerID ? 0.5 : 1)
            .onDrag {
                draggedProviderID = providerID
                return NSItemProvider(object: providerID.rawValue as NSString)
            }
            .onDrop(
                of: [UTType.text],
                delegate: DashboardCardDropDelegate(
                    targetProviderID: providerID,
                    reorderableProviderIDs: reorderableProviderIDs,
                    draggedProviderID: $draggedProviderID,
                    orderStore: orderStore
                )
            )
    }
}

extension View {
    fileprivate func dashboardReorderable(
        providerID: ProviderID,
        reorderableProviderIDs: Set<ProviderID>,
        draggedProviderID: Binding<ProviderID?>,
        orderStore: ProviderCardOrderStore
    ) -> some View {
        modifier(
            DashboardReorderModifier(
                providerID: providerID,
                reorderableProviderIDs: reorderableProviderIDs,
                draggedProviderID: draggedProviderID,
                orderStore: orderStore
            )
        )
    }
}

// MARK: - macOS Settings Window Manager

#if os(macOS)
import AppKit

/// Manages a floating settings window on macOS
class SettingsWindowManager: NSObject {
    static let shared = SettingsWindowManager()
    private var window: NSWindow?

    func showSettingsWindow() {
        if let existingWindow = window {
            existingWindow.makeKeyAndOrderFront(nil)
            NSApplication.shared.activate(ignoringOtherApps: true)
            return
        }

        let hostingController = NSHostingController(
            rootView: SettingsView()
                .frame(minWidth: 320, minHeight: 380)
        )

        let window = NSWindow(
            contentViewController: hostingController
        )
        window.title = "Settings"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.isOpaque = false
        window.backgroundColor = NSColor(calibratedWhite: 0.06, alpha: 0.34)
        window.titlebarAppearsTransparent = true
        window.toolbarStyle = .unifiedCompact
        window.minSize = NSSize(width: 320, height: 380)
        window.setFrameAutosaveName("SettingsWindow")

        // Center on screen
        if let screen = NSScreen.main {
            let screenFrame = screen.visibleFrame
            let windowFrame = window.frame
            let x = screenFrame.midX - windowFrame.width / 2
            let y = screenFrame.midY - windowFrame.height / 2
            window.setFrameOrigin(NSPoint(x: x, y: y))
        }

        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)

        self.window = window
        window.delegate = self
    }

    func closeSettingsWindow() {
        window?.close()
        window = nil
    }
}

extension SettingsWindowManager: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        window = nil
    }
}
#endif

// MARK: - Compact Layout

/// Single-card dashboard view that stacks every visible provider's
/// meters back-to-back. Each provider gets a small header (logo +
/// name) followed by one row per meter:
///
/// ```
/// Label                 Resets DD/MM HH:MM                XX%
/// [============== progress bar ==============]
/// ```
///
/// The reset countdown is shown as an absolute timestamp via
/// `Date.absoluteResetString` to keep the row to a single line — the
/// rolling "in 2h 44m" phrasing would re-flow as numbers wobble.
struct CompactDashboardCardView: View {
    let snapshots: [QuotaSnapshot]
    let sevenDayResetCounts: [ProviderID: Int]
    let reorderableProviderIDs: Set<ProviderID>
    @Binding var draggedProviderID: ProviderID?
    let orderStore: ProviderCardOrderStore

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(snapshots) { snapshot in
                providerBlock(snapshot)
                    .contentShape(Rectangle())
                    .dashboardReorderable(
                        providerID: snapshot.providerID,
                        reorderableProviderIDs: reorderableProviderIDs,
                        draggedProviderID: $draggedProviderID,
                        orderStore: orderStore
                    )
                if snapshot.id != snapshots.last?.id {
                    Divider().overlay(Color.white.opacity(0.08))
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCardBackground(accent: ProGlassTheme.accent, cornerRadius: 16)
    }

    @ViewBuilder
    private func providerBlock(_ snapshot: QuotaSnapshot) -> some View {
        let accent = Color(hex: snapshot.providerID.accentColorHex)
        let windows = snapshot.summaryWindows
        let resetCount = sevenDayResetCounts[snapshot.providerID, default: 0]

        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                ProviderBrandIconView(providerID: snapshot.providerID, size: 18)
                    .frame(width: 22, height: 22)

                Text(snapshot.displayName)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.primary)

                if let plan = snapshot.displayPlanName, !plan.isEmpty, plan != snapshot.displayName {
                    Text(plan)
                         .font(.system(size: 10, weight: .semibold))
                         .foregroundStyle(.secondary)
                 }

                Spacer(minLength: 4)

                if let banked = snapshot.resetCredits, banked.hasAvailableReset {
                    BankedResetPill(text: banked.statusLine() ?? "Reset banked", accent: accent, compact: true)
                }

                Text(resetCount == 1 ? "1 reset · 7d" : "\(resetCount) resets · 7d")
                    .font(.system(size: 9, weight: .semibold, design: .rounded))
                    .foregroundStyle(resetCount > 0 ? accent : Color.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .accessibilityLabel("\(resetCount) quota resets in the last 7 days")
            }
            .padding(.bottom, 1)

            if windows.isEmpty {
                Text("No usage data yet")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            } else {
                ForEach(windows) { window in
                    compactMeterRow(
                        window: window,
                        accent: accent,
                        providerID: snapshot.providerID
                    )
                }
            }
        }
    }

    @ViewBuilder
    private func compactMeterRow(
        window: QuotaWindow,
        accent: Color,
        providerID: ProviderID
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(window.label)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Spacer(minLength: 6)

                if let resetDate = window.resetDate {
                    Text("Resets \(resetDate.absoluteResetString)")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Text(percentageText(for: window, providerID: providerID))
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(usageColor(for: window.fractionUsed, accentColor: accent))
                    .lineLimit(1)
                    .monospacedDigit()
                    .frame(minWidth: 38, alignment: .trailing)
            }

            if window.hasExplicitLimit {
                QuotaProgressBar(
                    fraction: window.fractionUsed,
                    accentColor: accent,
                    height: 4,
                    pace: window.pace(providerID: nil)
                )
            }
        }
    }

    private func percentageText(for window: QuotaWindow, providerID: ProviderID) -> String {
        if window.isCurrencyMetric {
            return window.leadingValueText(for: providerID)
        }
        if window.hasExplicitLimit {
            return "\(window.percentageUsed)%"
        }
        return window.leadingValueText
    }
}

struct DashboardView_Previews: PreviewProvider {
    static var previews: some View {
        DashboardView()
            .environmentObject(AppStateStore())
            .preferredColorScheme(.dark)
    }
}
