import SwiftUI
#if os(macOS)
import AppKit

@MainActor
final class MenuBarController: NSObject {
    private var statusItem: NSStatusItem?
    private let popover = NSPopover()
    private let appState: AppStateStore

    init(appState: AppStateStore) {
        self.appState = appState
        super.init()
        setupStatusItem()
        setupPopover()
        FloatingPanelManager.shared.configure(appState: appState)
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem?.button {
            if let image = NSImage(named: "MenuBarIcon") {
                image.size = NSSize(width: 18, height: 18)
                image.isTemplate = false
                button.image = image
            } else {
                button.image = NSImage(systemSymbolName: "chart.bar.fill", accessibilityDescription: "Limit Counter")
            }
            button.imagePosition = .imageOnly
            button.imageScaling = .scaleProportionallyDown
            button.toolTip = "Limit Counter"
            button.action = #selector(togglePopover)
            button.target = self
        }
    }

    private func setupPopover() {
        popover.behavior = .semitransient
        popover.animates = true
        popover.contentSize = NSSize(width: 376, height: 560)
        popover.contentViewController = NSHostingController(
            rootView: MenuBarPopoverView(appState: appState)
                .environmentObject(appState)
                .frame(width: 376, height: 560)
        )
    }

    func updateMenu() {
        FloatingPanelManager.shared.reconcile()
    }

    @objc private func togglePopover() {
        guard let button = statusItem?.button else { return }

        if popover.isShown {
            popover.performClose(nil)
        } else {
            FloatingPanelManager.shared.reconcile()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }
}

private struct MenuBarPopoverView: View {
    @ObservedObject var appState: AppStateStore
    @StateObject private var panelStore = PinnedPanelStore.shared
    @State private var selectedProviderID: ProviderID?

    private var visibleSnapshots: [QuotaSnapshot] {
        appState.visibleSnapshots
            .filter { $0.providerID.isUserFacingInProviderLists && $0.hasContent }
            .sorted {
                ProviderCardOrderStore.nonisolatedRank(for: $0.providerID) < ProviderCardOrderStore.nonisolatedRank(for: $1.providerID)
            }
    }

    private var selectedSnapshot: QuotaSnapshot? {
        if let selectedProviderID,
           let match = visibleSnapshots.first(where: { $0.providerID == selectedProviderID }) {
            return match
        }
        return visibleSnapshots.first
    }

    var body: some View {
        ZStack {
            LiquidGlassBackdrop(style: .liquidGlass, intensity: .popover)

            VStack(spacing: 12) {
                header
                providerSwitcher

                ScrollView {
                    VStack(spacing: 12) {
                        overviewSection

                        if let selectedSnapshot {
                            focusedProviderSection(selectedSnapshot)
                        } else {
                            emptyState
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 12)
                }

                footerActions
            }
            .padding(.top, 12)
        }
        .preferredColorScheme(.dark)
        .onAppear {
            selectedProviderID = selectedSnapshot?.providerID
            FloatingPanelManager.shared.reconcile()
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "chart.bar.xaxis")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(ProGlassTheme.accent)
                .frame(width: 30, height: 30)
                .background(ProGlassTheme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 9, style: .continuous))

            VStack(alignment: .leading, spacing: 1) {
                Text("Limit Counter")
                    .font(.system(size: 15, weight: .bold))
                Text(appState.isSyncing ? "Refreshing" : lastUpdatedText)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                panelStore.toggle(kind: .overview)
                FloatingPanelManager.shared.reconcile()
            } label: {
                Image(systemName: panelStore.isVisible(kind: .overview) ? "pin.fill" : "pin")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(.glass)
            .help("Pin overview panel")
        }
        .padding(.horizontal, 12)
    }

    private var providerSwitcher: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 7) {
                ForEach(visibleSnapshots) { snapshot in
                    let isSelected = selectedSnapshot?.providerID == snapshot.providerID
                    Button {
                        selectedProviderID = snapshot.providerID
                    } label: {
                        HStack(spacing: 5) {
                            ProviderBrandIconView(providerID: snapshot.providerID, size: 15)
                            Text(snapshot.providerID.displayName)
                                .font(.caption.weight(.semibold))
                                .lineLimit(1)
                        }
                        .padding(.horizontal, 9)
                        .padding(.vertical, 6)
                        .foregroundStyle(isSelected ? .white : .secondary)
                        .background(
                            Capsule(style: .continuous)
                                .fill((isSelected ? Color(hex: snapshot.providerID.accentColorHex) : Color.white).opacity(isSelected ? 0.22 : 0.055))
                        )
                        .overlay(
                            Capsule(style: .continuous)
                                .strokeBorder(Color.white.opacity(isSelected ? 0.16 : 0.07), lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
        }
        .frame(height: 32)
    }

    private var overviewSection: some View {
        GlassCardContainer(style: .panel, accent: ProGlassTheme.accent, cornerRadius: 18, intensity: .popover) {
            VStack(alignment: .leading, spacing: 9) {
                HStack {
                    Text("Overview")
                        .font(.caption.weight(.bold))
                    Spacer()
                    Text("\(visibleSnapshots.count) providers")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }

                VStack(spacing: 6) {
                    ForEach(visibleSnapshots.prefix(5)) { snapshot in
                        MenuBarOverviewRow(snapshot: snapshot)
                    }
                }
            }
        }
    }

    private func focusedProviderSection(_ snapshot: QuotaSnapshot) -> some View {
        let accent = Color(hex: snapshot.providerID.accentColorHex)

        return GlassCardContainer(style: .panel, accent: accent, cornerRadius: 18, intensity: .popover) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    ProviderBrandIconView(providerID: snapshot.providerID, size: 22)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(snapshot.displayName)
                            .font(.caption.weight(.bold))
                        MiniMetadataLine(plan: snapshot.displayPlanName, updatedAt: snapshot.fetchedAt)
                    }

                    Spacer()

                    Button {
                        panelStore.toggle(kind: .provider, providerID: snapshot.providerID)
                        FloatingPanelManager.shared.reconcile()
                    } label: {
                        Image(systemName: panelStore.isVisible(kind: .provider, providerID: snapshot.providerID) ? "pin.fill" : "pin")
                            .font(.system(size: 12, weight: .semibold))
                            .frame(width: 28, height: 28)
                    }
                    .buttonStyle(.glass)
                    .help("Pin provider panel")
                }

                if snapshot.fetchState == .error {
                    MiniStatusRow(title: "Update failed", systemImage: "exclamationmark.triangle.fill", color: .red)
                } else if snapshot.summaryWindows.isEmpty && snapshot.analyticsBuckets.isEmpty {
                    MiniStatusRow(title: "No usage windows", systemImage: "chart.bar", color: .secondary)
                } else {
                    VStack(spacing: 7) {
                        ForEach(snapshot.summaryWindows.prefix(4)) { window in
                            MiniQuotaWindowRow(window: window, providerID: snapshot.providerID, accent: accent)
                        }

                        if !snapshot.analyticsBuckets.isEmpty {
                            MiniUsageIntelligenceView(providerID: snapshot.providerID, buckets: snapshot.analyticsBuckets, accent: accent)
                        }
                    }
                }
            }
        }
    }

    private var emptyState: some View {
        GlassCardContainer(style: .panel, accent: ProGlassTheme.accent, cornerRadius: 18, intensity: .popover) {
            MiniStatusRow(title: "No usage data available", systemImage: "chart.bar", color: .secondary)
                .padding(.vertical, 18)
        }
    }

    private var footerActions: some View {
        HStack(spacing: 8) {
            Button {
                Task { await appState.refresh(userInitiated: true) }
            } label: {
                Label("Refresh", systemImage: appState.isSyncing ? "arrow.triangle.2.circlepath" : "arrow.clockwise")
            }
            .buttonStyle(.glass)

            Button {
                ProviderSetupPresenter.shared.present()
            } label: {
                Label("Settings", systemImage: "gearshape")
            }
            .buttonStyle(.glass)

            Button {
                appState.isHeadlessMode.toggle()
            } label: {
                Image(systemName: appState.isHeadlessMode ? "eye.slash.fill" : "eye.fill")
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.glass)
            .help("Toggle headless mode")
        }
        .font(.caption.weight(.semibold))
        .padding(.horizontal, 12)
        .padding(.bottom, 12)
    }

    private var lastUpdatedText: String {
        guard let lastSyncDate = appState.lastSyncDate else { return "Waiting for first refresh" }
        return "Updated \(lastSyncDate.relativeString)"
    }
}

private struct MenuBarOverviewRow: View {
    let snapshot: QuotaSnapshot

    private var accent: Color { Color(hex: snapshot.providerID.accentColorHex) }
    private var window: QuotaWindow? { snapshot.summaryWindows.first }
    @ObservedObject private var budgetStore = ProviderMonthlyBudgetStore.shared
    private var intelligence: UsageAnalyticsIntelligence? {
        guard !snapshot.analyticsBuckets.isEmpty else { return nil }
        return UsageAnalyticsIntelligence(
            buckets: snapshot.analyticsBuckets,
            monthlyBudgetUSD: budgetStore.budgetUSD(for: snapshot.providerID)
        )
    }

    var body: some View {
        let intelligence = intelligence

        HStack(spacing: 8) {
            ProviderBrandIconView(providerID: snapshot.providerID, size: 18)

            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(snapshot.displayName)
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                    Spacer()
                    Text(window?.leadingValueText ?? analyticsValueText(intelligence) ?? statusText)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(snapshot.fetchState == .error ? .red : rowValueColor(intelligence))
                        .monospacedDigit()
                }

                if let window {
                    QuotaProgressBar(
                        fraction: window.fractionUsed,
                        accentColor: accent,
                        height: 4,
                        pace: window.pace(providerID: snapshot.providerID),
                        segmentCount: window.segmentCount(for: snapshot.providerID)
                    )
                } else if let intelligence {
                    HStack(spacing: 4) {
                        Text("Projected month")
                        Spacer(minLength: 8)
                        Text(analyticsTodayText(intelligence))
                            .monospacedDigit()
                    }
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                } else {
                    QuotaProgressBar(
                        fraction: 0,
                        accentColor: accent,
                        height: 4,
                        pace: nil
                    )
                    .opacity(0.35)
                }
            }
        }
    }

    private func rowValueColor(_ intelligence: UsageAnalyticsIntelligence?) -> Color {
        if let window {
            return usageColor(for: window.fractionUsed, accentColor: accent)
        }

        if intelligence != nil {
            return accent
        }

        return usageColor(for: 0, accentColor: accent)
    }

    private func analyticsValueText(_ intelligence: UsageAnalyticsIntelligence?) -> String? {
        guard let intelligence else { return nil }
        if intelligence.projectedMonth.cost > 0 {
            return formattedMetricValue(intelligence.projectedMonth.cost, unit: "$")
        }
        if intelligence.projectedMonth.tokens > 0 {
            return intelligence.projectedMonth.tokens.compactString
        }
        return nil
    }

    private func analyticsTodayText(_ intelligence: UsageAnalyticsIntelligence) -> String {
        if intelligence.today.cost > 0 {
            return "\(formattedMetricValue(intelligence.today.cost, unit: "$")) today"
        }
        return "\(intelligence.today.tokens.compactString) today"
    }

    private var statusText: String {
        switch snapshot.fetchState {
        case .success:
            return "Ready"
        case .error:
            return "Error"
        case .notConfigured:
            return "Setup"
        }
    }
}

private struct MiniMetadataLine: View {
    let plan: String?
    let updatedAt: Date

    var body: some View {
        HStack(spacing: 4) {
            if let plan, !plan.isEmpty {
                Text(plan)
                    .lineLimit(1)
                Text("-")
            }
            Text("Updated \(updatedAt.relativeString)")
                .lineLimit(1)
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(.secondary)
        .minimumScaleFactor(0.75)
    }
}

private struct FloatingOverviewPanelView: View {
    @ObservedObject var appState: AppStateStore
    @StateObject private var panelStore = PinnedPanelStore.shared

    private var snapshots: [QuotaSnapshot] {
        let selected = panelStore.state(kind: .overview).selectedOverviewProviderIDs
        let candidates = appState.visibleSnapshots
            .filter { $0.providerID.isUserFacingInProviderLists && $0.hasContent }
            .sorted {
                ProviderCardOrderStore.nonisolatedRank(for: $0.providerID) < ProviderCardOrderStore.nonisolatedRank(for: $1.providerID)
            }

        let preferred = selected.compactMap { id in candidates.first { $0.providerID == id } }
        return Array((preferred.isEmpty ? candidates : preferred).prefix(4))
    }

    var body: some View {
        FloatingPanelShell(accent: ProGlassTheme.accent) {
            VStack(alignment: .leading, spacing: 10) {
                FloatingPanelHeader(title: "Limit Counter", subtitle: appState.isSyncing ? "Refreshing" : lastUpdatedText, providerID: nil)

                VStack(spacing: 8) {
                    ForEach(snapshots) { snapshot in
                        MenuBarOverviewRow(snapshot: snapshot)
                    }
                }
            }
        }
    }

    private var lastUpdatedText: String {
        guard let lastSyncDate = appState.lastSyncDate else { return "Waiting for refresh" }
        return "Updated \(lastSyncDate.relativeString)"
    }
}

private struct FloatingProviderPanelView: View {
    @ObservedObject var appState: AppStateStore
    let providerID: ProviderID

    private var snapshot: QuotaSnapshot? {
        appState.visibleSnapshots.first { $0.providerID == providerID }
    }

    private var accent: Color {
        Color(hex: providerID.accentColorHex)
    }

    var body: some View {
        FloatingPanelShell(accent: accent) {
            VStack(alignment: .leading, spacing: 10) {
                if let snapshot {
                    FloatingPanelHeader(
                        title: snapshot.displayName,
                        subtitle: [snapshot.displayPlanName, "Updated \(snapshot.fetchedAt.relativeString)"].compactMap { $0 }.joined(separator: " - "),
                        providerID: snapshot.providerID
                    )

                    if snapshot.fetchState == .error {
                        MiniStatusRow(title: "Update failed", systemImage: "exclamationmark.triangle.fill", color: .red)
                    } else {
                        VStack(spacing: 8) {
                            ForEach(snapshot.summaryWindows.prefix(4)) { window in
                                MiniQuotaWindowRow(window: window, providerID: snapshot.providerID, accent: accent)
                            }

                            if !snapshot.analyticsBuckets.isEmpty {
                                MiniUsageIntelligenceView(providerID: snapshot.providerID, buckets: snapshot.analyticsBuckets, accent: accent)
                            }
                        }
                    }
                } else {
                    FloatingPanelHeader(title: providerID.displayName, subtitle: "No usage data", providerID: providerID)
                }
            }
        }
    }
}

private struct FloatingPanelShell<Content: View>: View {
    let accent: Color
    @ViewBuilder let content: Content

    var body: some View {
        ZStack {
            LiquidGlassBackdrop(style: .liquidGlass, intensity: .floatingPanel)
            content
                .padding(12)
                .background(
                    GlassPanel(
                        style: .panel,
                        accent: accent,
                        shape: RoundedRectangle(cornerRadius: 18, style: .continuous),
                        intensity: .floatingPanel
                    )
                )
                .padding(8)
        }
        .preferredColorScheme(.dark)
    }
}

private struct FloatingPanelHeader: View {
    let title: String
    let subtitle: String
    let providerID: ProviderID?

    var body: some View {
        HStack(spacing: 8) {
            if let providerID {
                ProviderBrandIconView(providerID: providerID, size: 22)
            } else {
                Image(systemName: "chart.bar.xaxis")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(ProGlassTheme.accent)
                    .frame(width: 22, height: 22)
            }

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 13, weight: .bold))
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }
}

private struct MiniQuotaWindowRow: View {
    let window: QuotaWindow
    let providerID: ProviderID
    let accent: Color

    var body: some View {
        let pace = window.pace(providerID: providerID)

        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(window.label)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(window.leadingValueText)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(usageColor(for: window.fractionUsed, accentColor: accent))
                    .monospacedDigit()
            }

            if window.hasExplicitLimit {
                QuotaProgressBar(fraction: window.fractionUsed, accentColor: accent, height: 5, pace: pace, segmentCount: window.segmentCount(for: providerID))
            }

            HStack {
                Text(window.measurementSummary)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                if let pace, pace.shouldSurface {
                    Text(pace.compactStatusText)
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(Color(hex: pace.colorHex))
                        .lineLimit(1)
                }
                if let resetDate = window.resetDate {
                    Text("Resets \(resetDate.countdownString)")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
    }
}

private struct MiniUsageIntelligenceView: View {
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

        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                metricPill(title: "Today", value: valueText(model.today), subtitle: subtitleText(model.today))
                metricPill(title: "Projected", value: valueText(model.projectedMonth), subtitle: projectedSubtitle(model))
            }

            if let insight = model.insights.first {
                HStack(alignment: .top, spacing: 7) {
                    Image(systemName: iconName(for: insight))
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(color(for: insight))
                        .frame(width: 16, height: 16)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(insight.title)
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.primary)
                        Text(insight.message)
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.top, 1)
            }
        }
        .padding(8)
        .background(accent.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.white.opacity(0.065), lineWidth: 1)
        )
    }

    private func metricPill(title: String, value: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title.uppercased())
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(.tertiary)
            Text(value)
                .font(.caption.weight(.bold))
                .foregroundStyle(accent)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.72)
            Text(subtitle)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }

    private func valueText(_ totals: UsageAnalyticsPeriodTotals) -> String {
        if totals.cost > 0 {
            return formattedMetricValue(totals.cost, unit: "$")
        }
        return totals.tokens.compactString
    }

    private func subtitleText(_ totals: UsageAnalyticsPeriodTotals) -> String {
        if totals.cost > 0, totals.tokens > 0 {
            return "\(totals.tokens.compactString) tokens"
        }
        return "\(totals.requests.compactString) reqs"
    }

    private func projectedSubtitle(_ model: UsageAnalyticsIntelligence) -> String {
        if let budget = model.monthlyBudget {
            return "\(budget.projectedPercentageText) budget"
        }
        return "month"
    }

    private func color(for insight: UsageAnalyticsInsight) -> Color {
        switch insight.severity {
        case .info:
            return accent
        case .warning:
            return .yellow
        case .critical:
            return .red
        }
    }

    private func iconName(for insight: UsageAnalyticsInsight) -> String {
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
}

private struct MiniStatusRow: View {
    let title: String
    let systemImage: String
    let color: Color

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: systemImage)
                .foregroundStyle(color)
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(8)
        .background(Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

@MainActor
final class FloatingPanelManager: NSObject {
    static let shared = FloatingPanelManager()

    private weak var appState: AppStateStore?
    private var panels: [String: NSPanel] = [:]
    private var delegates: [String: FloatingPanelDelegate] = [:]
    private let panelStore = PinnedPanelStore.shared

    func configure(appState: AppStateStore) {
        self.appState = appState
        reconcile()
    }

    func reconcile() {
        guard let appState else { return }

        let visibleStates = panelStore.visibleStates
        let visibleIDs = Set(visibleStates.map(\.id))

        for state in visibleStates {
            showPanel(for: state, appState: appState)
        }

        let staleIDs = panels.keys.filter { !visibleIDs.contains($0) }
        for id in staleIDs {
            panels[id]?.close()
            panels[id] = nil
            delegates[id] = nil
        }
    }

    private func showPanel(for state: PinnedPanelState, appState: AppStateStore) {
        if let panel = panels[state.id] {
            panel.orderFront(nil)
            return
        }

        let panel = NSPanel(
            contentRect: defaultFrame(for: state),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = panelTitle(for: state)
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = NSColor(calibratedWhite: 0.02, alpha: 0.22)
        panel.hasShadow = true
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.setFrameAutosaveName(state.frameAutosaveName)

        switch state.kind {
        case .overview:
            panel.contentViewController = NSHostingController(
                rootView: FloatingOverviewPanelView(appState: appState)
                    .environmentObject(appState)
            )
            panel.minSize = NSSize(width: 260, height: 220)
        case .provider:
            let providerID = state.providerID ?? .openai
            panel.contentViewController = NSHostingController(
                rootView: FloatingProviderPanelView(appState: appState, providerID: providerID)
                    .environmentObject(appState)
            )
            panel.minSize = NSSize(width: 250, height: 180)
        }

        let delegate = FloatingPanelDelegate { [weak self] in
            self?.panelStore.setVisible(false, kind: state.kind, providerID: state.providerID)
            self?.panels[state.id] = nil
            self?.delegates[state.id] = nil
        }
        panel.delegate = delegate
        panels[state.id] = panel
        delegates[state.id] = delegate

        panel.orderFrontRegardless()
    }

    private func defaultFrame(for state: PinnedPanelState) -> NSRect {
        let size: NSSize = state.kind == .overview
            ? NSSize(width: 300, height: 300)
            : NSSize(width: 292, height: 244)
        let origin = NSScreen.main.map { screen in
            NSPoint(
                x: screen.visibleFrame.maxX - size.width - 24,
                y: screen.visibleFrame.maxY - size.height - 48
            )
        } ?? NSPoint(x: 120, y: 120)
        return NSRect(origin: origin, size: size)
    }

    private func panelTitle(for state: PinnedPanelState) -> String {
        switch state.kind {
        case .overview:
            return "Limit Counter Overview"
        case .provider:
            return "\(state.providerID?.displayName ?? "Provider") Usage"
        }
    }
}

private final class FloatingPanelDelegate: NSObject, NSWindowDelegate {
    private let onClose: () -> Void

    init(onClose: @escaping () -> Void) {
        self.onClose = onClose
    }

    func windowWillClose(_ notification: Notification) {
        onClose()
    }
}
#endif
