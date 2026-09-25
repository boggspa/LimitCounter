import SwiftUI
import UniformTypeIdentifiers
#if canImport(UIKit)
import UIKit
#endif
#if os(iOS)
import Photos
#endif

struct DashboardView: View {
    @EnvironmentObject private var appState: AppStateStore
    @StateObject private var visibilityStore = ProviderVisibilityStore.shared
    @StateObject private var orderStore = ProviderCardOrderStore.shared
    @StateObject private var layoutModeStore = DashboardLayoutModeStore.shared
    @State private var showSettings = false
    #if os(macOS)
    @StateObject private var setupModel = ProviderSetupModel()
    @ObservedObject private var setupPresenter = ProviderSetupPresenter.shared
    #endif
    @State private var navigationPath = NavigationPath()
    @AppStorage("dashboardRefreshIntervalSeconds") private var dashboardRefreshIntervalSeconds: Int = 60
    #if os(iOS)
    @State private var screenshotSaveAlert: ScreenshotSaveAlert?
    #endif

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
                case .modelUsage:
                    ModelUsageDashboardView()
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
        #if os(macOS)
        .sheet(isPresented: $setupPresenter.isPresented) {
            ProviderSetupSheet(
                model: setupModel,
                onRefresh: { Task { await appState.refresh(userInitiated: true) } },
                lastSyncDate: appState.lastSyncDate,
                onClose: { setupPresenter.isPresented = false }
            )
            .environmentObject(appState)
            .preferredColorScheme(.dark)
        }
        .onChange(of: setupPresenter.isPresented) { isPresented in
            // The menu-bar popover reaches the presenter directly, so it never
            // passes through `openSettings()`.
            if isPresented { setupModel.load(syncErrors: appState.syncErrors) }
        }
        #endif
        #if os(iOS)
        .alert(
            screenshotSaveAlert?.title ?? "Screenshot",
            isPresented: Binding(
                get: { screenshotSaveAlert != nil },
                set: { isPresented in
                    if !isPresented {
                        screenshotSaveAlert = nil
                    }
                }
            )
        ) {
            if screenshotSaveAlert?.offersSettings == true {
                Button("Open Settings") {
                    openAppSettings()
                }
            }
            Button("OK", role: .cancel) {
                screenshotSaveAlert = nil
            }
        } message: {
            Text(screenshotSaveAlert?.message ?? "")
        }
        #endif
        .onChange(of: appState.pendingDeepLinkProviderID) { newValue in
            guard let providerID = newValue else { return }
            if let route = routeForProvider(providerID) {
                navigationPath = NavigationPath()
                navigationPath.append(route)
            }
            appState.pendingDeepLinkProviderID = nil
        }
        .onChange(of: appState.pendingModelUsageNavigation) { pending in
            if pending { openModelUsage() }
        }
        .onAppear {
            if appState.pendingModelUsageNavigation { openModelUsage() }
        }
    }

    private func openModelUsage() {
        navigationPath = NavigationPath()
        navigationPath.append(DashboardRoute.modelUsage)
        appState.pendingModelUsageNavigation = false
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
        // Load before presenting, not in the sheet's `onAppear`: otherwise the
        // rail's first render sees an empty health map, every row builds itself
        // as "Not set up", and the accessibility labels stay that way even
        // after the visuals correct themselves a frame later.
        setupModel.load(syncErrors: appState.syncErrors)
        // One surface on macOS: providers and preferences are both pages in the
        // setup sheet, so there is no settings window to raise any more.
        setupPresenter.present()
        #else
        showSettings = true
        #endif
    }

    private var dashboardTopBar: some View {
        HStack(spacing: 0) {
            #if os(macOS)
            // Keep the traffic lights clear and let only the unused portion
            // of this bar move the window; the control pill stays clickable.
            Color.clear.frame(width: 110, height: 32)
                .allowsHitTesting(false)
            Color.clear
                .frame(maxWidth: .infinity)
                .frame(height: 32)
                .contentShape(Rectangle())
                .gesture(WindowDragGesture())
            #else
            Spacer(minLength: 0)
            #endif
            sharedControlPill
        }
    }

    @ViewBuilder
    private var dashboardSurface: some View {
        #if os(macOS)
        GeometryReader { proxy in
            if proxy.size.width >= 720 && proxy.size.height >= 500 {
                desktopDashboardShell
                    .frame(width: proxy.size.width, height: proxy.size.height, alignment: .top)
                    .overlay(alignment: .top) {
                        HStack(spacing: 0) {
                            Color.clear.frame(width: 110, height: 24)
                                .allowsHitTesting(false)
                            Color.clear
                                .frame(height: 24)
                                .contentShape(Rectangle())
                                .gesture(WindowDragGesture())
                        }
                    }
            } else {
                compactDashboardShell
            }
        }
        #else
        GeometryReader { proxy in
            if layoutModeStore.mode.isCompact {
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
        HStack(alignment: .top, spacing: 0) {
            dashboardSidebar
                .frame(width: 252)

            Rectangle()
                .fill(Color.white.opacity(0.07))
                .frame(width: 1)
                .blendMode(.screen)

            dashboardWorkspace
                .frame(maxHeight: .infinity, alignment: .top)
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

            ScrollView {
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
                    ModelUsageSummaryCard { navigationPath.append(DashboardRoute.modelUsage) }
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
            navigationPillItem(title: "Activity", systemImage: "waveform.path.ecg", isActive: false) {
                navigationPath.append(DashboardRoute.modelUsage)
            }
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
                    ModelUsageSummaryCard { navigationPath.append(DashboardRoute.modelUsage) }
                    LLMActivityHeatmapView(snapshots: appState.snapshots, modelUsage: appState.modelUsage)
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

    /// One card per account. Codex's local telemetry belongs to its primary
    /// account, so only that card combines the two; any other Codex account
    /// gets a card of its own rather than being dropped.
    private var dashboardCards: [DashboardCardItem] {
        let snapshots = visibleSnapshots
        let allSnapshots = appState.snapshots

        var cards: [DashboardCardItem] = []

        if visibilityStore.isVisible(.heatmap) {
            cards.append(.heatmap(snapshots: appState.snapshots, modelUsage: appState.modelUsage))
        }

        let usageSnapshot = snapshots.first { $0.providerID == .openai && $0.isPrimaryAccount }
        let telemetrySnapshot = allSnapshots.first {
            $0.providerID == .codexTelemetry && $0.fetchState == .success && $0.hasContent
        }
        var combinedAccount: ProviderAccountKey?
        if let usageSnapshot, let telemetrySnapshot {
            cards.append(.combinedCodex(usageSnapshot: usageSnapshot, telemetrySnapshot: telemetrySnapshot))
            combinedAccount = usageSnapshot.accountKey
        }

        for snapshot in snapshots
        where snapshot.providerID != .codexTelemetry && snapshot.accountKey != combinedAccount {
            cards.append(.snapshot(snapshot))
        }

        let cardsByKey = Dictionary(cards.map { ($0.orderKey, $0) }, uniquingKeysWith: { first, _ in first })
        return orderStore.sortedCards(Array(cardsByKey.keys)).compactMap { cardsByKey[$0] }
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
            if layoutModeStore.mode.isCompact {
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
        if !isDesktop {
            ModelUsageSummaryCard { navigationPath.append(DashboardRoute.modelUsage) }
        }
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

            if layoutModeStore.mode == .compactPeriod {
                PeriodCompactDashboardCardView(snapshots: snapshots)
            } else {
                CompactDashboardCardView(
                    snapshots: snapshots,
                    reorderableProviderIDs: reorderableProviderIDs,
                    orderStore: orderStore
                )
            }

            if showsHeatmap && !heatmapLeads {
                compactHeatmapCard
            }
        }
    }

    private var compactHeatmapCard: some View {
        LLMActivityHeatmapView(snapshots: appState.snapshots, modelUsage: appState.modelUsage)
            .dashboardReorderable(
                providerID: .heatmap,
                reorderableProviderIDs: reorderableProviderIDs,
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
        let snapshots = visibleSnapshots.filter { $0.providerID != .codexTelemetry }
        let snapshotsByKey = Dictionary(
            snapshots.map { ($0.accountKey, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        return orderStore.sortedCards(Array(snapshotsByKey.keys)).compactMap { snapshotsByKey[$0] }
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
                accessibilityLabel: "Model usage"
            ) {
                navigationPath.append(DashboardRoute.modelUsage)
            } label: {
                Image(systemName: "chart.xyaxis.line")
                    .foregroundStyle(.white)
            }

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

            compactLayoutMenu

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

    /// The compact-layout control: a three-way picker between compact
    /// off, the provider-grouped ("Standard") compact card, and the
    /// period-grouped ("Period") one. Rendered as a menu rather than a
    /// toggle so all three styles are one click away.
    private var compactLayoutMenu: some View {
        Menu {
            // Plain buttons rather than a `Picker`: a button action only
            // ever runs on a real click, so the stored layout can't be
            // rewritten as a side effect of the menu being built.
            Section("Compact layout") {
                ForEach(DashboardLayoutMode.allCases, id: \.self) { mode in
                    Button {
                        layoutModeStore.setMode(mode)
                    } label: {
                        Label(
                            mode.pickerTitle,
                            systemImage: layoutModeStore.mode == mode ? "checkmark" : mode.pickerIconName
                        )
                    }
                }
            }
        } label: {
            // SF symbols: `rectangle.compress.vertical` while compact is
            // off (the action would compress), `rectangle.expand.vertical`
            // in the provider-grouped style (the action would expand), and
            // a clock for the period-grouped style.
            Image(systemName: compactLayoutIconName)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(layoutModeStore.mode.isCompact ? ProGlassTheme.accent : .white)
                .frame(width: 34, height: 30)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("Compact layout: \(layoutModeStore.mode.pickerTitle)")
    }

    private var compactLayoutIconName: String {
        switch layoutModeStore.mode {
        case .standard: return "rectangle.compress.vertical"
        case .compact: return "rectangle.expand.vertical"
        case .compactPeriod: return "clock.arrow.circlepath"
        }
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

        saveQuotaCardScreenshot(image)
    }

    @MainActor private func saveQuotaCardScreenshot(_ image: UIImage) {
        handlePhotoLibraryAuthorization(
            PHPhotoLibrary.authorizationStatus(for: .addOnly),
            image: image
        )
    }

    @MainActor private func handlePhotoLibraryAuthorization(
        _ status: PHAuthorizationStatus,
        image: UIImage
    ) {
        switch status {
        case .authorized, .limited:
            writeQuotaCardScreenshot(image)
        case .notDetermined:
            PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
                Task { @MainActor in
                    handlePhotoLibraryAuthorization(status, image: image)
                }
            }
        case .denied, .restricted:
            screenshotSaveAlert = ScreenshotSaveAlert(
                title: "Photos Access Needed",
                message: "Allow Limit Counter to add photos in Settings before saving a quota-card screenshot.",
                offersSettings: true
            )
        @unknown default:
            screenshotSaveAlert = ScreenshotSaveAlert(
                title: "Could Not Save Screenshot",
                message: "Photos access is unavailable on this device.",
                offersSettings: false
            )
        }
    }

    @MainActor private func writeQuotaCardScreenshot(_ image: UIImage) {
        PHPhotoLibrary.shared().performChanges({
            PHAssetChangeRequest.creationRequestForAsset(from: image)
        }) { success, error in
            Task { @MainActor in
                screenshotSaveAlert = ScreenshotSaveAlert(
                    title: success ? "Screenshot Saved" : "Could Not Save Screenshot",
                    message: success
                        ? "The quota-card screenshot was added to your photo library."
                        : error?.localizedDescription ?? "Photos could not save the quota-card screenshot.",
                    offersSettings: false
                )
            }
        }
    }

    @MainActor private func openAppSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
    #endif
}

#if os(iOS)
private struct ScreenshotSaveAlert {
    let title: String
    let message: String
    let offersSettings: Bool
}
#endif

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
    case heatmap(snapshots: [QuotaSnapshot], modelUsage: ModelUsageArchive)

    /// Per account: two accounts of one provider are two cards, and a
    /// shared id made SwiftUI draw one account's card in both places.
    var id: String {
        orderKey.rawValue
    }

    /// The account the card belongs to, which is also its place in the order.
    var orderKey: ProviderAccountKey {
        switch self {
        case .snapshot(let snapshot):
            return snapshot.providerID == .codexTelemetry ? .primary(.openai) : snapshot.accountKey
        case .combinedCodex(let usageSnapshot, _):
            return usageSnapshot.accountKey
        case .heatmap:
            return .primary(.heatmap)
        }
    }

    var navigationRoute: DashboardRoute? {
        switch self {
        case .snapshot(let snapshot):
            return .provider(snapshot)
        case .combinedCodex(let usageSnapshot, let telemetrySnapshot):
            return .codexCombined(usageSnapshot: usageSnapshot, telemetrySnapshot: telemetrySnapshot)
        case .heatmap:
            return .modelUsage
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
        case .heatmap(let snapshots, let modelUsage):
            LLMActivityHeatmapView(snapshots: snapshots, modelUsage: modelUsage)
        }
    }
}

private enum DashboardRoute: Hashable {
    case modelUsage
    case provider(_ snapshot: QuotaSnapshot)
    case codexCombined(usageSnapshot: QuotaSnapshot, telemetrySnapshot: QuotaSnapshot)
}

private enum DashboardProviderDrag {
    // Encode the source in the drag itself. Native drags have no SwiftUI end
    // callback, so keeping it in view state leaves canceled drags selected.
    static let type = UTType(exportedAs: "com.chrisizatt.limitcounter.provider-reorder", conformingTo: .data)

    static func item(for providerID: ProviderID) -> NSItemProvider {
        let provider = NSItemProvider()
        provider.registerDataRepresentation(forTypeIdentifier: type.identifier, visibility: .ownProcess) { completion in
            completion(Data(providerID.rawValue.utf8), nil)
            return nil
        }
        return provider
    }
}

private struct DashboardCardDropDelegate: DropDelegate {
    let targetProviderID: ProviderID
    let reorderableProviderIDs: Set<ProviderID>
    let orderStore: ProviderCardOrderStore

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        guard let provider = info.itemProviders(for: [DashboardProviderDrag.type.identifier]).first else {
            return false
        }
        provider.loadDataRepresentation(forTypeIdentifier: DashboardProviderDrag.type.identifier) { data, _ in
            guard
                let data,
                let rawValue = String(data: data, encoding: .utf8),
                let sourceID = ProviderID(rawValue: rawValue)
            else {
                return
            }
            Task { @MainActor in
                guard sourceID != targetProviderID, reorderableProviderIDs.contains(sourceID) else { return }
                withAnimation(.easeInOut(duration: 0.18)) {
                    orderStore.move(sourceID, toward: targetProviderID)
                }
            }
        }
        return true
    }
}

/// Shared drag-to-reorder plumbing for every dashboard surface — the
/// standard card stack, the compact stacked-meters rows, and the
/// activity heatmap card.
private struct DashboardReorderModifier: ViewModifier {
    let providerID: ProviderID
    let reorderableProviderIDs: Set<ProviderID>
    let orderStore: ProviderCardOrderStore

    func body(content: Content) -> some View {
        content
            .onDrag { DashboardProviderDrag.item(for: providerID) }
            .onDrop(
                of: [DashboardProviderDrag.type],
                delegate: DashboardCardDropDelegate(
                    targetProviderID: providerID,
                    reorderableProviderIDs: reorderableProviderIDs,
                    orderStore: orderStore
                )
            )
    }
}

extension View {
    fileprivate func dashboardReorderable(
        providerID: ProviderID,
        reorderableProviderIDs: Set<ProviderID>,
        orderStore: ProviderCardOrderStore
    ) -> some View {
        modifier(
            DashboardReorderModifier(
                providerID: providerID,
                reorderableProviderIDs: reorderableProviderIDs,
                orderStore: orderStore
            )
        )
    }
}

/// A compact meter row paired with an identity that survives a refresh.
///
/// `QuotaWindow.id` is a fresh UUID every time a provider is read, and
/// `ForEach` needs a KeyPath rather than a closure, so the stable key is
/// carried beside the window instead of being derived inside the loop. Keying
/// on the per-fetch UUID would rebuild every row on every refresh, which is
/// invisible right up until it tears down a drag mid-gesture.
private struct OrderedMeter: Identifiable {
    let id: String
    let window: QuotaWindow
}

/// The frames are measured in the same global coordinates as the handle's
/// gesture. Each compact card keeps its own copy, so identical meter keys in
/// the provider and period layouts cannot interfere with one another.
private struct MeterRowFramePreferenceKey: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]

    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, latest in latest })
    }
}

private struct MeterReorderTargetModifier: ViewModifier {
    let meterKey: String

    func body(content: Content) -> some View {
        content
            .background {
                GeometryReader { geometry in
                    Color.clear.preference(
                        key: MeterRowFramePreferenceKey.self,
                        value: [meterKey: geometry.frame(in: .global)]
                    )
                }
            }
    }
}

extension View {
    fileprivate func meterReorderTarget(_ meterKey: String) -> some View {
        modifier(MeterReorderTargetModifier(meterKey: meterKey))
    }
}

/// A gesture on a small handle leaves scrolling and other row hit testing
/// alone. Gesture state resets on both completion and cancellation, so a drag
/// cannot leave a meter looking selected when it misses a drop target.
private struct MeterDragHandle: View {
    /// The handle's slot in a row. On iOS the touch area reaches past the slot,
    /// over the meter's own bar, so a finger-sized target doesn't make compact
    /// rows taller than their macOS twins.
    #if os(iOS)
    static let slot = CGSize(width: 22, height: 18)
    static let touchArea = CGSize(width: 44, height: 32)
    #else
    static let slot = CGSize(width: 15, height: 18)
    static let touchArea = slot
    #endif

    let meterKey: String
    let scope: String
    let reorderableKeys: [String]
    let rowFrames: [String: CGRect]
    let orderStore: MeterOrderStore
    let accessibilityName: String
    @GestureState private var isDragging = false

    var body: some View {
        Image(systemName: "line.3.horizontal")
            .font(.system(size: 8, weight: .semibold))
            .foregroundStyle(isDragging ? Color.primary : Color.secondary.opacity(0.65))
            .frame(width: Self.slot.width, height: Self.slot.height)
            .contentShape(
                Rectangle()
                    .size(Self.touchArea)
                    .offset(x: (Self.slot.width - Self.touchArea.width) / 2, y: (Self.slot.height - Self.touchArea.height) / 2)
            )
            .accessibilityLabel("Reorder \(accessibilityName)")
            .gesture(
                DragGesture(minimumDistance: 4, coordinateSpace: .global)
                    .updating($isDragging) { _, state, _ in state = true }
                    .onEnded { value in
                        guard let targetKey = target(at: value.location), targetKey != meterKey else { return }
                        withAnimation(.easeInOut(duration: 0.18)) {
                            orderStore.move(meterKey, toward: targetKey, scope: scope, natural: reorderableKeys)
                        }
                    }
            )
    }

    private func target(at location: CGPoint) -> String? {
        let candidates = reorderableKeys.compactMap { key -> (String, CGRect)? in
            guard let frame = rowFrames[key] else { return nil }
            return (key, frame)
        }
        guard let first = candidates.first else { return nil }
        let bounds = candidates.dropFirst().reduce(first.1) { $0.union($1.1) }
        guard bounds.insetBy(dx: -16, dy: -16).contains(location) else { return nil }
        return candidates.min {
            abs($0.1.midY - location.y) < abs($1.1.midY - location.y)
        }?.0
    }
}


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
    let reorderableProviderIDs: Set<ProviderID>
    let orderStore: ProviderCardOrderStore
    @ObservedObject private var meterOrderStore = MeterOrderStore.shared
    @State private var meterRowFrames: [String: CGRect] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(snapshots, id: \.accountKey.rawValue) { snapshot in
                providerBlock(snapshot)
                    .contentShape(Rectangle())
                    .onDrop(
                        of: [DashboardProviderDrag.type],
                        delegate: DashboardCardDropDelegate(
                            targetProviderID: snapshot.providerID,
                            reorderableProviderIDs: reorderableProviderIDs,
                            orderStore: orderStore
                        )
                    )
                if snapshot.accountKey != snapshots.last?.accountKey {
                    Divider().overlay(Color.white.opacity(0.08))
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCardBackground(accent: ProGlassTheme.accent, cornerRadius: 16)
        .onPreferenceChange(MeterRowFramePreferenceKey.self) { meterRowFrames = $0 }
    }

    @ViewBuilder
    private func providerBlock(_ snapshot: QuotaSnapshot) -> some View {
        let accent = Color(hex: snapshot.providerID.accentColorHex)
        // Keyed and scoped per account: two Codex accounts' "Weekly" rows
        // are different meters, with orders of their own.
        let scope = MeterOrderStore.scopeForProvider(snapshot.accountKey)
        let naturalMeters = snapshot.summaryWindows.map {
            OrderedMeter(
                id: MeterOrderStore.key(account: snapshot.accountKey, window: $0),
                window: $0
            )
        }
        let meterKeys = naturalMeters.map(\.id)
        let meters = meterOrderStore.ordered(naturalMeters, scope: scope, key: \.id)

        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                ProviderBrandIconView(providerID: snapshot.providerID, size: 18)
                    .frame(width: 22, height: 22)

                Text(snapshot.accountDisplayName)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                if let plan = snapshot.displayPlanName, !plan.isEmpty, plan != snapshot.displayName {
                    Text(plan)
                         .font(.system(size: 10, weight: .semibold))
                         .foregroundStyle(.secondary)
                 }

                Spacer(minLength: 4)

                if let banked = snapshot.resetCredits, banked.hasAvailableReset {
                    BankedResetPill(text: banked.statusLine() ?? "Reset banked", accent: accent, compact: true)
                }
            }
            .padding(.bottom, 1)
            .contentShape(Rectangle())
            .onDrag { DashboardProviderDrag.item(for: snapshot.providerID) }

            if meters.isEmpty {
                Text("No usage data yet")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            } else {
                ForEach(meters) { meter in
                    compactMeterRow(
                        window: meter.window,
                        accent: accent,
                        providerID: snapshot.providerID,
                        meterKey: meter.id,
                        scope: scope,
                        reorderableKeys: meterKeys
                    )
                    .contentShape(Rectangle())
                    .meterReorderTarget(meter.id)
                }
            }
        }
    }

    @ViewBuilder
    private func compactMeterRow(
        window: QuotaWindow,
        accent: Color,
        providerID: ProviderID,
        meterKey: String,
        scope: String,
        reorderableKeys: [String]
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                MeterDragHandle(
                    meterKey: meterKey,
                    scope: scope,
                    reorderableKeys: reorderableKeys,
                    rowFrames: meterRowFrames,
                    orderStore: meterOrderStore,
                    accessibilityName: window.label
                )

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
                    pace: window.pace(providerID: providerID),
                    segmentCount: window.segmentCount(for: providerID)
                )
            }
        }
    }

    private func percentageText(for window: QuotaWindow, providerID: ProviderID) -> String {
        compactMeterValueText(for: window, providerID: providerID)
    }
}

/// Trailing value for a compact meter row: currency meters show the
/// amount, capped meters the percentage, and uncapped meters whatever
/// raw total the provider reported.
private func compactMeterValueText(for window: QuotaWindow, providerID: ProviderID) -> String {
    if window.isCurrencyMetric {
        return window.leadingValueText(for: providerID)
    }
    if window.hasExplicitLimit {
        return "\(window.percentageUsed)%"
    }
    return window.leadingValueText
}

/// Compact layout, "Period" style: the same stacked meter rows as
/// `CompactDashboardCardView`, but regrouped under the reset period they
/// belong to (5H / Daily / Weekly / Monthly + API) instead of under
/// their provider. Rows keep the provider accent on the bar, and name
/// their provider inline since there is no per-provider header.
struct PeriodCompactDashboardCardView: View {
    let snapshots: [QuotaSnapshot]
    @ObservedObject private var meterOrderStore = MeterOrderStore.shared
    @State private var meterRowFrames: [String: CGRect] = [:]

    private var sections: [QuotaPeriodSection] {
        QuotaPeriodSection.sections(from: snapshots)
    }

    var body: some View {
        let orderedSections = sections
        VStack(alignment: .leading, spacing: 14) {
            ForEach(orderedSections) { section in
                sectionBlock(section)
                if section.id != orderedSections.last?.id {
                    Divider().overlay(Color.white.opacity(0.08))
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCardBackground(accent: ProGlassTheme.accent, cornerRadius: 16)
        .onPreferenceChange(MeterRowFramePreferenceKey.self) { meterRowFrames = $0 }
    }

    @ViewBuilder
    private func sectionBlock(_ section: QuotaPeriodSection) -> some View {
        let scope = MeterOrderStore.scopeForPeriod(section.group)
        // Keyed per account, as the rows' own ids are. A provider-only key
        // gave two accounts' "Weekly" rows one name, and the saved order then
        // showed the first account's row in both places.
        let naturalMeterRows = section.rows.filter { $0.window != nil }
        let meterKeys = naturalMeterRows.compactMap(MeterOrderStore.key(for:))
        let orderedMeterRows = meterOrderStore.ordered(
            naturalMeterRows,
            scope: scope,
            key: { MeterOrderStore.key(for: $0) ?? $0.id }
        )
        let idleRows = section.rows.filter { $0.window == nil }
        let rows = orderedMeterRows + idleRows

        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(section.group.title)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.primary)

                Spacer(minLength: 4)

                Text(section.rows.count == 1 ? "1 meter" : "\(section.rows.count) meters")
                    .font(.system(size: 9, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
            }
            .padding(.bottom, 1)

            ForEach(rows) { row in
                if let meterKey = MeterOrderStore.key(for: row) {
                    meterRow(row, scope: scope, reorderableKeys: meterKeys)
                        .contentShape(Rectangle())
                        .meterReorderTarget(meterKey)
                } else {
                    meterRow(row, scope: scope, reorderableKeys: meterKeys)
                }
            }
        }
    }

    @ViewBuilder
    private func meterRow(_ row: QuotaPeriodRow, scope: String, reorderableKeys: [String]) -> some View {
        let accent = Color(hex: row.providerID.accentColorHex)

        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                if let meterKey = MeterOrderStore.key(for: row) {
                    MeterDragHandle(
                        meterKey: meterKey,
                        scope: scope,
                        reorderableKeys: reorderableKeys,
                        rowFrames: meterRowFrames,
                        orderStore: meterOrderStore,
                        accessibilityName: row.label
                    )
                } else {
                    Color.clear.frame(width: MeterDragHandle.slot.width, height: MeterDragHandle.slot.height)
                }

                ProviderBrandIconView(providerID: row.providerID, size: 13)
                    .frame(width: 16, height: 16)

                Text(row.label)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)

                Spacer(minLength: 6)

                if let window = row.window {
                    if let resetDate = window.resetDate {
                        Text("Resets \(resetDate.absoluteResetString)")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    Text(compactMeterValueText(for: window, providerID: row.providerID))
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(usageColor(for: window.fractionUsed, accentColor: accent))
                        .lineLimit(1)
                        .monospacedDigit()
                        .frame(minWidth: 38, alignment: .trailing)
                } else {
                    Text("No usage data yet")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }

            if let window = row.window, window.hasExplicitLimit {
                QuotaProgressBar(
                    fraction: window.fractionUsed,
                    accentColor: accent,
                    height: 4,
                    pace: window.pace(providerID: row.providerID),
                    segmentCount: window.segmentCount(for: row.providerID)
                )
            }
        }
    }
}

struct DashboardView_Previews: PreviewProvider {
    static var previews: some View {
        DashboardView()
            .environmentObject(AppStateStore())
            .preferredColorScheme(.dark)
    }
}
