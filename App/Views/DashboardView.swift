import SwiftUI
import UniformTypeIdentifiers

struct DashboardView: View {
    @EnvironmentObject private var appState: AppStateStore
    @StateObject private var visibilityStore = ProviderVisibilityStore.shared
    @StateObject private var orderStore = ProviderCardOrderStore.shared
    @State private var showSettings = false
    @State private var draggedProviderID: ProviderID?
    @AppStorage("dashboardRefreshIntervalSeconds") private var dashboardRefreshIntervalSeconds: Int = 60

    var body: some View {
        NavigationStack {
            ZStack {
                LiquidGlassBackdrop()

#if os(macOS)
                TransparentWindowConfigurator(cornerRadius: 14)
                    .frame(width: 0, height: 0)
#endif

                VStack(spacing: 0) {
                    dashboardTopBar
                        .padding(.horizontal, 12)
                        .padding(.top, 8)
                        .padding(.bottom, 4)

                    ScrollView {
                        LazyVStack(spacing: 10) {
                            if dashboardCards.isEmpty {
                                GlassCardContainer(style: .panel, accent: Color(hex: "#5B8AF5"), cornerRadius: 16) {
                                    emptyDashboardState
                                }
                            } else {
                                ForEach(dashboardCards) { item in
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
                                    .onDrag {
                                        draggedProviderID = item.orderProviderID
                                        return NSItemProvider(object: item.orderProviderID.rawValue as NSString)
                                    }
                                    .onDrop(
                                        of: [UTType.text],
                                        delegate: DashboardCardDropDelegate(
                                            target: item,
                                            orderedItems: dashboardCards,
                                            draggedProviderID: $draggedProviderID,
                                            orderStore: orderStore
                                        )
                                    )
                                }
                            }
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                    }
                }
                .refreshable {
                    await appState.refresh()
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
        .tint(Color(hex: "#5B8AF5"))
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
                Task { await appState.refresh() }
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
                    .foregroundStyle(appState.isHeadlessMode ? Color(hex: "#5B8AF5") : .white)
            }
            #endif
        }
        .padding(4)
        .background(
            Capsule(style: .continuous)
                .fill(.ultraThinMaterial)
        )
        .overlay(
            Capsule(style: .continuous)
                .strokeBorder(Color.white.opacity(0.10), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.12), radius: 12, x: 0, y: 8)
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
}

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
    let target: DashboardCardItem
    let orderedItems: [DashboardCardItem]
    @Binding var draggedProviderID: ProviderID?
    let orderStore: ProviderCardOrderStore

    func dropEntered(info: DropInfo) {
        guard
            let draggedProviderID,
            draggedProviderID != target.orderProviderID,
            orderedItems.contains(where: { $0.orderProviderID == draggedProviderID })
        else {
            return
        }

        orderStore.move(draggedProviderID, before: target.orderProviderID)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        draggedProviderID = nil
        return true
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

struct DashboardView_Previews: PreviewProvider {
    static var previews: some View {
        DashboardView()
            .environmentObject(AppStateStore())
            .preferredColorScheme(.dark)
    }
}
