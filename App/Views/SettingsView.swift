import SwiftUI
import WidgetKit
#if os(macOS)
import AppKit
import UniformTypeIdentifiers
#elseif os(iOS)
import UIKit
#endif

struct SettingsView: View {
    /// True when hosted as the setup sheet's Preferences page. The sheet
    /// supplies the window chrome and the glass, so this drops its own
    /// `NavigationStack` and backdrop rather than stacking a second set.
    var isEmbedded: Bool = false

    @StateObject private var visibilityStore = ProviderVisibilityStore.shared
    @StateObject private var monthlyBudgetStore = ProviderMonthlyBudgetStore.shared
    @AppStorage("dashboardRefreshIntervalSeconds") private var dashboardRefreshIntervalSeconds: Int = 60
    @State private var requestedRefreshIntervalMinutes = UsageRefreshCadence.requestedRefreshIntervalMinutes
    @State private var cloudSyncDebug = CloudSyncDebugInfo.placeholder
    @State private var isRefreshingCloudSync = false
    @State private var isRepairingSubscriptions = false
    @State private var cloudSyncActionMessage: String?
    @State private var showRawDataDebug = false

    private var monthlyBudgetRows: [SettingsProviderRowIdentity] {
        ProviderID.userFacingCases.map { SettingsProviderRowIdentity(section: "budget", providerID: $0) }
    }

    @ViewBuilder
    var body: some View {
        if isEmbedded {
            if showRawDataDebug {
                RawDataDebugView(onClose: { showRawDataDebug = false })
            } else {
                settingsList
            }
        } else {
            NavigationStack {
                ZStack {
                    LiquidGlassBackdrop(intensity: .settings)
                    settingsList
                }
            }
        }
    }

    private var settingsList: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Use only credentials you intentionally enter or export yourself.")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.primary)

                    Text("The app caches normalized quota snapshots for widgets, but it should not read browser cookies, hidden sessions, or credentials belonging to other apps.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
                .listRowBackground(Color.white.opacity(0.04))
            }

            #if os(iOS)
            Section("Sync") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("This iPhone is a viewer.")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.primary)

                    Text("Configure providers and read local quota sources on the Mac app. iPhone reads the last status the Mac published through iCloud.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 4)
            }
            .listRowBackground(Color.white.opacity(0.04))
            #endif

            Section("iCloud Sync") {
                CloudSyncDebugRow(title: "Role", value: cloudSyncDebug.roleTitle)
                CloudSyncDebugRow(
                    title: "iCloud",
                    value: cloudSyncDebug.accountStatusTitle,
                    valueColor: cloudSyncDebug.accountHealthy ? .green : .secondary
                )
                CloudSyncDebugRow(title: "Cached snapshots", value: "\(cloudSyncDebug.cachedSnapshotCount)")

                #if os(iOS)
                if let notificationsStatusTitle = cloudSyncDebug.notificationsStatusTitle {
                    CloudSyncDebugRow(title: "Alerts", value: notificationsStatusTitle)
                }
                CloudSyncDebugRow(
                    title: "Subscriptions",
                    value: cloudSyncDebug.subscriptionVersion > 0
                        ? "Installed (v\(cloudSyncDebug.subscriptionVersion))"
                        : "Not installed"
                )
                CloudSyncOperationStateView(title: "Last fetch", state: cloudSyncDebug.fetchState)
                CloudSyncOperationStateView(title: "Subscription check", state: cloudSyncDebug.subscriptionState)
                CloudSyncDebugRow(
                    title: "Last push",
                    value: cloudSyncDebug.lastRemoteNotificationAt.map(formatCloudSyncDebugDate) ?? "Not yet received"
                )
                #else
                CloudSyncOperationStateView(title: "Last publish", state: cloudSyncDebug.publishState)
                #endif

                if let cloudSyncActionMessage {
                    Text(cloudSyncActionMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: 12) {
                    Button {
                        Task {
                            await refreshCloudSyncDebug()
                        }
                    } label: {
                        if isRefreshingCloudSync {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Text("Refresh Sync Status")
                        }
                    }
                    .disabled(isRefreshingCloudSync || isRepairingSubscriptions)

                    #if os(iOS)
                    Button {
                        Task {
                            await repairViewerSubscriptions()
                        }
                    } label: {
                        if isRepairingSubscriptions {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Text("Repair Subscriptions")
                        }
                    }
                    .disabled(isRefreshingCloudSync || isRepairingSubscriptions)
                    #endif
                }

                Text(cloudSyncHelpText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            .listRowBackground(Color.white.opacity(0.04))

            Section("Refresh") {
                Picker("Dashboard refresh", selection: $dashboardRefreshIntervalSeconds) {
                    Text("15 seconds").tag(15)
                    Text("30 seconds").tag(30)
                    Text("60 seconds").tag(60)
                    Text("90 seconds").tag(90)
                    Text("120 seconds").tag(120)
                }
                .pickerStyle(.menu)

                Text("This controls how often the dashboard refreshes visible status while the app is open.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Picker(requestedRefreshPickerTitle, selection: $requestedRefreshIntervalMinutes) {
                    ForEach(UsageRefreshCadence.allowedIntervalMinutes, id: \.self) { minutes in
                        Text(UsageRefreshCadence.intervalLabel(for: minutes)).tag(minutes)
                    }
                }
                .pickerStyle(.menu)
                .onChange(of: requestedRefreshIntervalMinutes) { newValue in
                    updateRequestedRefreshInterval(to: newValue)
                }

                Text(requestedRefreshHelpText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .listRowBackground(Color.white.opacity(0.04))

            #if os(iOS)
            Section("Dashboard Services") {
                ForEach(ProviderID.userFacingCases) { providerID in
                    ProviderVisibilitySettingsRow(
                        providerID: providerID,
                        isVisible: visibilityStore.binding(for: providerID)
                    )
                }
            }
            .listRowBackground(Color.white.opacity(0.04))
            #endif

            Section("Dashboard Extras") {
                ProviderVisibilitySettingsRow(
                    providerID: .heatmap,
                    isVisible: visibilityStore.binding(for: .heatmap)
                )
            }
            .listRowBackground(Color.white.opacity(0.04))

            Section("Monthly Budgets") {
                ForEach(monthlyBudgetRows) { row in
                    ProviderMonthlyBudgetSettingsRow(
                        providerID: row.providerID,
                        budgetStore: monthlyBudgetStore
                    )
                }

                Text("Budgets are local monthly USD targets used for projected spend and threshold callouts.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .listRowBackground(Color.white.opacity(0.04))

            Section("Debug") {
                Button {
                    showRawDataDebug = true
                } label: {
                    Text("Show Raw Snapshot Data")
                        .foregroundStyle(.primary)
                }

                Text("Inspect the raw data being counted for each provider, including events and timestamps.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .listRowBackground(Color.white.opacity(0.04))

            #if os(macOS)
            // Providers themselves live in the setup sheet's rail. What
            // remains here is the one grant that belongs to no single
            // provider: four of them read it.
            Section("Shared Data Sources") {
                AGBenchDataSourceRow()
                    .listRowBackground(Color.white.opacity(0.03))
            }
            #endif
        }
        .scrollContentBackground(.hidden)
        .navigationTitle("Settings")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task {
            await refreshCloudSyncDebug()
        }
        // Only the standalone (iOS) presentation raises this as a sheet; inside
        // the setup sheet it is a page, so nothing stacks.
        .sheet(isPresented: Binding(
            get: { !isEmbedded && showRawDataDebug },
            set: { showRawDataDebug = $0 }
        )) {
            RawDataDebugView()
        }
    }

    private var requestedRefreshPickerTitle: String {
        #if os(iOS)
        "Background/widget refresh"
        #else
        "Widget timeline refresh"
        #endif
    }

    private var requestedRefreshHelpText: String {
        #if os(iOS)
        "CloudKit pushes still update the iPhone as soon as iOS delivers them. This is the requested fallback cadence for iPhone background fetch and widget timeline reloads; iOS may throttle it."
        #else
        "Widgets request fresh timelines at this cadence. The Mac app still reloads widgets immediately after local data refreshes."
        #endif
    }

    private func updateRequestedRefreshInterval(to minutes: Int) {
        UsageRefreshCadence.setRequestedRefreshIntervalMinutes(minutes)
        WidgetCenter.shared.reloadAllTimelines()

        #if os(iOS)
        (UIApplication.shared.delegate as? IOSAppDelegate)?.scheduleBackgroundRefresh()
        #endif
    }

    private func refreshCloudSyncDebug() async {
        guard !isRefreshingCloudSync else { return }
        isRefreshingCloudSync = true
        defer { isRefreshingCloudSync = false }

        cloudSyncActionMessage = nil
        cloudSyncDebug = await CloudKitSyncService.shared.loadDebugInfo()
    }

    private func repairViewerSubscriptions() async {
        guard !isRepairingSubscriptions else { return }
        isRepairingSubscriptions = true
        defer { isRepairingSubscriptions = false }

        do {
            try await CloudKitSyncService.shared.reinstallViewerSubscriptions()
            cloudSyncActionMessage = "Viewer subscriptions reinstalled."
        } catch {
            cloudSyncActionMessage = error.localizedDescription
        }

        cloudSyncDebug = await CloudKitSyncService.shared.loadDebugInfo()
    }

    private var cloudSyncHelpText: String {
        #if os(iOS)
        "Use this section to confirm the iPhone can see iCloud, has viewer subscriptions installed, and has fetched at least one Mac-published snapshot."
        #else
        "Use this section to confirm the Mac can see iCloud and is successfully publishing normalized status snapshots after local refreshes."
        #endif
    }
}

private struct SettingsProviderRowIdentity: Identifiable {
    let id: String
    let providerID: ProviderID

    init(section: String, providerID: ProviderID) {
        self.id = "\(section).\(providerID.rawValue)"
        self.providerID = providerID
    }
}

// MARK: - Raw Data Debug View

struct RawDataDebugView: View {
    /// Set when hosted as a page inside the setup sheet, where `dismiss` would
    /// tear the whole sheet down instead of returning to Preferences.
    var onClose: (() -> Void)?

    @Environment(\.dismiss) private var dismiss
    @State private var selectedProvider: ProviderID?

    private func close() {
        if let onClose { onClose() } else { dismiss() }
    }

    private let store = QuotaSnapshotStore.shared
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    var body: some View {
        NavigationStack {
                      List {
                if let selectedProvider {
                    providerDetailSection(selectedProvider)
                } else {
                    providerListSection
                }
            }
            .navigationTitle(selectedProvider?.rawValue ?? "Raw Snapshot Data")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                if selectedProvider != nil {
                    Button("Back") {
                        selectedProvider = nil
                    }
                }
                Button("Done") {
                    close()
                }
            }
        }
        .frame(minWidth: 600, minHeight: 400)
    }

    private var providerListSection: some View {
        Section {
            ForEach(ProviderID.allCases, id: \.self) { providerID in
                Button {
                    selectedProvider = providerID
                } label: {
                    HStack {
                        Text(providerID.rawValue)
                            .foregroundStyle(.primary)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .foregroundStyle(.secondary)
                            .font(.caption)
                    }
                }
            }
        } header: {
            Text("Select a provider to inspect")
        }
    }

    private func providerDetailSection(_ providerID: ProviderID) -> some View {
        let snapshot = store.snapshot(for: providerID)

        return Group {
            Section(header: Text("Overview")) {
                if let snapshot {
                    InfoRow(label: "Provider", value: snapshot.providerID.rawValue)
                    InfoRow(label: "Display Name", value: snapshot.displayName)
                    InfoRow(label: "Plan", value: snapshot.displayPlanName ?? "N/A")
                    InfoRow(label: "Fetch State", value: snapshot.fetchState.rawValue)
                    InfoRow(label: "Fetched At", value: formatDate(snapshot.fetchedAt))
                    InfoRow(label: "Windows", value: "\(snapshot.windows.count)")
                    InfoRow(label: "Stats", value: "\(snapshot.stats.count)")
                    InfoRow(label: "Analytics Buckets", value: "\(snapshot.analyticsBuckets.count)")
                    InfoRow(label: "Events", value: "\(snapshot.events.count)")
                    InfoRow(label: "Signals", value: "\(snapshot.signals.count)")
                } else {
                    Text("No snapshot data available")
                        .foregroundStyle(.secondary)
                }
            }

            if let snapshot, !snapshot.events.isEmpty {
                Section(header: Text("Events (Recent 50)")) {
                    ForEach(Array(snapshot.events.prefix(50)), id: \.id) { event in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(formatDate(event.timestamp))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Spacer()
                                if let tokens = event.tokens {
                                    Text("\(Int(tokens)) tokens")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            if let model = event.model {
                                Text(model)
                                    .font(.caption2)
                                    .foregroundStyle(.primary)
                            }
                            Text(event.type.rawValue)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.vertical, 2)
                    }
                }
            }

            if let snapshot, !snapshot.analyticsBuckets.isEmpty {
                Section(header: Text("Analytics Buckets (Recent 50)")) {
                    ForEach(Array(snapshot.analyticsBuckets.prefix(50)), id: \.id) { bucket in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(formatDate(bucket.startDate))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Text(bucket.source.rawValue)
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                            Text(bucket.model ?? bucket.note ?? "All usage")
                                .font(.caption2)
                                .foregroundStyle(.primary)
                            Text("\(bucket.totalTokens.compactString) tokens - \(bucket.requests.compactString) requests - \(formattedMetricValue(bucket.costUSD ?? 0, unit: "$"))")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 2)
                    }
                }
            }

            if let snapshot, !snapshot.stats.isEmpty {
                Section(header: Text("Stats")) {
                    ForEach(snapshot.stats, id: \.label) { stat in
                        InfoRow(label: stat.label, value: "\(stat.value) \(stat.unit)")
                    }
                }
            }

            if let snapshot, !snapshot.windows.isEmpty {
                Section(header: Text("Windows")) {
                    ForEach(snapshot.windows, id: \.self) { window in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(window.label)
                                .font(.caption)
                                .foregroundStyle(.primary)
                            if let total = window.total {
                                Text("\(Int(window.used)) / \(Int(total)) \(window.unit)")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            } else {
                                Text("\(Int(window.used)) \(window.unit)")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            if let resetDate = window.resetDate {
                                Text("Resets: \(formatDate(resetDate))")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
            }

            Section(header: Text("Raw JSON")) {
                if let snapshot, let data = try? encoder.encode(snapshot),
                   let jsonString = String(data: data, encoding: .utf8) {
                    Text(jsonString)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxHeight: 300, alignment: .topLeading)
                }
            }
        }
    }

    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .medium
        return formatter.string(from: date)
    }
}

private struct InfoRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .foregroundStyle(.primary)
        }
    }
}

private struct CloudSyncDebugRow: View {
    let title: String
    let value: String
    var valueColor: Color = .primary

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(title)
                .foregroundStyle(.secondary)

            Spacer(minLength: 12)

            Text(value)
                .foregroundStyle(valueColor)
                .multilineTextAlignment(.trailing)
        }
        .padding(.vertical, 2)
    }
}

private struct CloudSyncOperationStateView: View {
    let title: String
    let state: CloudSyncOperationDebugState

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            CloudSyncDebugRow(title: title, value: summaryText)

            if let error = state.lastErrorDescription {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 2)
    }

    private var summaryText: String {
        if let lastSuccessAt = state.lastSuccessAt {
            return "OK · \(formatCloudSyncDebugDate(lastSuccessAt))"
        }

        if let lastAttemptAt = state.lastAttemptAt {
            return "Attempted · \(formatCloudSyncDebugDate(lastAttemptAt))"
        }

        return "Not yet"
    }
}

private func formatCloudSyncDebugDate(_ date: Date) -> String {
    date.formatted(date: .abbreviated, time: .shortened)
}

// MARK: - Row

private struct ProviderVisibilitySettingsRow: View {
    let providerID: ProviderID
    let isVisible: Binding<Bool>

    private var accent: Color { Color(hex: providerID.accentColorHex) }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            ProviderBrandIconView(providerID: providerID, size: 24)

            VStack(alignment: .leading, spacing: 3) {
                Text(providerID.displayName)
                    .foregroundStyle(.primary)

                Text(providerID.configurationDescription)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 12)

            Toggle(isOn: isVisible) {
                Text("Shown on Dashboard")
                    .font(.caption2.weight(.semibold))
            }
            .labelsHidden()
            .toggleStyle(.switch)
            .tint(accent)
        }
        .padding(.vertical, 4)
    }
}

private struct ProviderMonthlyBudgetSettingsRow: View {
    let providerID: ProviderID
    @ObservedObject var budgetStore: ProviderMonthlyBudgetStore
    @State private var budgetText = ""

    private var accent: Color { Color(hex: providerID.accentColorHex) }
    private var storedBudget: Double? { budgetStore.budgetUSD(for: providerID) }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            ProviderBrandIconView(providerID: providerID, size: 24)

            VStack(alignment: .leading, spacing: 3) {
                Text(providerID.displayName)
                    .foregroundStyle(.primary)

                Text(storedBudget.map { "\(formattedMetricValue($0, unit: "$")) monthly target" } ?? "No monthly target")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 12)

            HStack(spacing: 5) {
                Text("$")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                TextField("None", text: $budgetText)
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .monospacedDigit()
                    .frame(width: 86)
                    #if os(iOS)
                    .keyboardType(.decimalPad)
                    #endif

                if storedBudget != nil || !budgetText.isEmpty {
                    Button {
                        budgetText = ""
                        budgetStore.setBudgetUSD(nil, for: providerID)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Clear monthly budget")
                }
            }
        }
        .padding(.vertical, 4)
        .onAppear {
            budgetText = budgetStore.formattedBudgetText(for: providerID)
        }
        .onChange(of: budgetText) { _, newValue in
            commitBudgetText(newValue)
        }
    }

    private func commitBudgetText(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            budgetStore.setBudgetUSD(nil, for: providerID)
            return
        }

        guard let parsed = ProviderMonthlyBudgetStore.parsedBudgetUSD(from: trimmed) else { return }
        budgetStore.setBudgetUSD(parsed, for: providerID)
    }
}

/// TaskWraith telemetry source row. Lets the user grant the app sandboxed
/// access to the TaskWraith app-support folder so providers can read
/// `usage.json` and surface TaskWraith-driven runs on the activity heatmap.
private struct AGBenchDataSourceRow: View {
    @State private var hasBookmark: Bool = AGBenchBookmarkStore.hasBookmark
    @State private var lastErrorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: hasBookmark ? "checkmark.seal.fill" : "shippingbox")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(hasBookmark ? Color.green : Color.secondary)

                VStack(alignment: .leading, spacing: 2) {
                    Text("TaskWraith")
                        .font(.system(size: 14, weight: .semibold))
                    Text(hasBookmark
                         ? "Connected - usage.json enriches activity and optional API spend estimates."
                         : "Not configured. Grant access for optional activity and spend-estimate enrichment.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
            }

            HStack(spacing: 8) {
                Button(hasBookmark ? "Re-grant Access" : "Grant Access") {
                    grantAccess()
                }
                .buttonStyle(.bordered)

                if hasBookmark {
                    Button("Remove") {
                        AGBenchBookmarkStore.clear()
                        hasBookmark = false
                        lastErrorMessage = nil
                    }
                    .buttonStyle(.bordered)
                    .tint(.red)
                }
            }

            if let lastErrorMessage {
                Text(lastErrorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            Text("Pick the folder at: ~/Library/Application Support/taskwraith")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
    }

    private func grantAccess() {
        #if os(macOS)
        let panel = NSOpenPanel()
        panel.title = "Grant access to TaskWraith data"
        panel.message = "Select the TaskWraith data folder under ~/Library/Application Support/"
        panel.prompt = "Grant"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        // Default to the typical location so the user only has to click "Grant".
        let defaultURL = AGBenchBookmarkStore.suggestedDataDirectory
        if FileManager.default.fileExists(atPath: defaultURL.path) {
            panel.directoryURL = defaultURL
        }

        // `begin` rather than `runModal`: a modal run loop started from inside a
        // sheet freezes the sheet's layout and animation, and the Powerbox panel
        // orders relative to the app rather than to the sheet. Window-less
        // `begin` floats the panel above either host and blocks nothing.
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            if AGBenchBookmarkStore.save(url: url) {
                hasBookmark = true
                lastErrorMessage = nil
            } else {
                lastErrorMessage = "Failed to save bookmark. Try selecting the folder again."
            }
        }
        #endif
    }
}


// MARK: - Credential Form

/// Which of the embedded browser sign-ins a provider's form has handed its
/// surface to. Each one is a page, not a sheet.
enum ProviderWebImportKind: String, Hashable {
    case cursor
    case kimi
    case ollama
    case mistral
    case metaWeb
    case museSubscription
    case cerebras
    case qwen
    case mimo
}

struct ProviderCredentialView: View {
    /// Which account this form edits. The primary account's key is the
    /// provider itself, which is what every pre-account caller passes.
    let account: ProviderAccountKey
    var providerID: ProviderID { account.providerID }

    @ObservedObject private var accountRegistry = ProviderAccountRegistry.shared
    @State private var accountLabelDraft = ""

    init(providerID: ProviderID) {
        self.init(account: .primary(providerID))
    }

    init(account: ProviderAccountKey) {
        self.account = account
    }

    @State private var accessToken = ""
    @State private var accountIdentifier = ""
    @State private var customEndpoint = ""
    @State private var isSaved = false
    @State private var importError: String?
    @State private var showImportError = false
    @State private var detectedCredentials: [CredentialImportService.DetectedCredential] = []
    @State private var cursorSessionImported = false
    @State private var kimiWebSessionImported = false
    @State private var ollamaSessionImported = false
    @State private var mistralSessionImported = false
    @State private var metaWebSessionImported = false
    @State private var museSubscriptionImported = false
    @State private var museCliGranted = false
    @State private var museCliProbeStatus: String?
    @State private var isProbingMuseCli = false
    @State private var cerebrasWebSessionImported = false
    @State private var qwenWebSessionImported = false
    @State private var mimoWebSessionImported = false
    /// Which embedded browser sign-in has taken over the form, if any.
    @State private var activeWebImport: ProviderWebImportKind?
    @State private var storedExtraFields: [String: String] = [:]
    @State private var codexTelemetryEndpoint = ""
    @State private var codexTelemetryHasCredential = false
    @State private var codexTelemetrySaved = false
    @State private var loadedBillingAnchorSignature = ""

    private var accent: Color { Color(hex: providerID.accentColorHex) }
    private var providerDetectedCredentials: [CredentialImportService.DetectedCredential] {
        detectedCredentials.filter { $0.providerID == providerID }
    }
    private var codexTelemetryDetectedCredentials: [CredentialImportService.DetectedCredential] {
        guard providerID == .openai else { return [] }
        return detectedCredentials.filter { $0.providerID == .codexTelemetry }
    }

    private var usesLocalPathAsPrimaryCredential: Bool {
        ProviderSetupPolicy.localPathPrimaryProviders.contains(providerID)
    }

    private var importCopy: ProviderSetupPolicy.ImportCopy {
        ProviderSetupPolicy.importCopy(for: providerID, account: account)
    }

    private var importSectionTitle: String { importCopy.sectionTitle }
    private var importButtonTitle: String { importCopy.buttonTitle }
    private var importHelpText: String { importCopy.helpText }

    private var selectedGeminiLimitPreset: GeminiLimitPreset {
        GeminiLimitPreset(
            rawValue: storedExtraFields[GeminiLimitPreset.storageKey] ?? GeminiLimitPreset.automatic.rawValue
        ) ?? .automatic
    }

    private var geminiLimitPresetSelection: Binding<String> {
        Binding(
            get: { selectedGeminiLimitPreset.rawValue },
            set: { newValue in
                if newValue == GeminiLimitPreset.automatic.rawValue {
                    storedExtraFields.removeValue(forKey: GeminiLimitPreset.storageKey)
                } else {
                    storedExtraFields[GeminiLimitPreset.storageKey] = newValue
                }
            }
        )
    }

    private var claudeCodeKeychainFallbackEnabled: Binding<Bool> {
        Binding(
            get: {
                ClaudeOAuthCredentialPolicy.isClaudeCodeKeychainFallbackEnabled(extraFields: storedExtraFields)
            },
            set: { isEnabled in
                ClaudeOAuthCredentialPolicy.setClaudeCodeKeychainFallbackEnabled(isEnabled, in: &storedExtraFields)
            }
        )
    }

    private var minimaxBalanceAPIKey: Binding<String> {
        Binding(
            get: { storedExtraFields[MiniMaxProviderClient.balanceAPIKeyField] ?? "" },
            set: { value in
                let key = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if key.isEmpty {
                    storedExtraFields.removeValue(forKey: MiniMaxProviderClient.balanceAPIKeyField)
                } else {
                    storedExtraFields[MiniMaxProviderClient.balanceAPIKeyField] = key
                }
            }
        )
    }

    private func webSessionImportButton(
        _ title: String,
        systemImage: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .tint(accent)
        .fixedSize(horizontal: true, vertical: false)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    var body: some View {
        Group {
            // A sign-in takes the surface over rather than stacking a sheet on
            // top of it. Sheet-over-sheet means two backing windows, two
            // dismiss actions and two size negotiations — the exact fragility
            // this redesign exists to remove — and the form's state survives,
            // because this is the same view instance either way.
            if let activeWebImport {
                webImportPage(activeWebImport)
            } else {
                standardConfigBody
            }
        }
        // Attached out here so an import failure is reported on whichever
        // surface is showing, not only once the form comes back.
        .alert("Import Failed", isPresented: $showImportError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(importError ?? "Could not import credentials from file.")
        }
    }

    private func webImportPage(_ kind: ProviderWebImportKind) -> some View {
        let back: () -> Void = { activeWebImport = nil }
        // A failed import leaves the browser open, so the user can retry
        // without signing in again.
        let handle: (Result<CredentialImportService.ImportedCredential, Error>) -> Void = { result in
            switch result {
            case .success(let imported):
                _ = applyImportedCredential(imported)
            case .failure(let error):
                importError = error.localizedDescription
                showImportError = true
            }
        }

        return Group {
            switch kind {
            case .cursor:
                CursorSessionImportView(onImport: handle, onClose: back)
            case .kimi:
                KimiWebSessionImportView(onImport: handle, onClose: back)
            case .ollama:
                OllamaSessionImportView(onImport: handle, onClose: back)
            case .mistral:
                MistralSessionImportView(account: account, onImport: handle, onClose: back)
            case .metaWeb:
                MetaWebSessionImportView(onImport: handle, onClose: back)
            case .museSubscription:
                MuseSubscriptionImportView(onImport: handle, onClose: back)
            case .cerebras:
                CerebrasWebSessionImportView(onImport: handle, onClose: back)
            case .qwen:
                QwenWebSessionImportView(onImport: handle, onClose: back)
            case .mimo:
                MimoWebSessionImportView(onImport: handle, onClose: back)
            }
        }
        // Stable identity per importer, so a re-render of the enclosing form
        // cannot rebuild the web view and throw a half-finished sign-in back to
        // the login page.
        .id(kind)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var standardConfigBody: some View {
        // No backdrop of its own: the setup sheet paints the glass, and a
        // second one on top only muddies the first.
        Form {
            if !account.isPrimary {
                Section("Account") {
                    TextField("Label", text: $accountLabelDraft)
                        .onSubmit(commitAccountLabel)
                    Text(ProviderSetupPolicy.additionalAccountHint(for: providerID))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 12)
                .listRowBackground(Color.white.opacity(0.04))
            }

            Section("Connection") {
                VStack(alignment: .leading, spacing: 10) {
                    Text(providerID.integrationStatus.badgeTitle)
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(accent.opacity(0.16), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                        .foregroundStyle(accent)

                    Text(providerID.configurationDescription)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
                .padding(.horizontal, 12)
                .listRowBackground(Color.white.opacity(0.04))
            }

            // Show auto-detected credential files. They are the primary
            // account's: a second account is, by definition, somewhere else.
            if account.isPrimary, !providerDetectedCredentials.isEmpty {
                Section("Auto-Detected (\(providerDetectedCredentials.count) files found)") {
                    ForEach(providerDetectedCredentials) { detected in
                        Button(action: { importDetectedCredential(detected) }) {
                            HStack(spacing: 10) {
                                Image(systemName: "doc.badge.arrow.up")
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(detected.description)
                                        .font(.subheadline)
                                    Text(detected.fileURL.lastPathComponent)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                Spacer(minLength: 8)
                                Image(systemName: "arrow.right.circle.fill")
                                    .foregroundStyle(accent)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .foregroundStyle(.primary)
                    }
                }
                .padding(.horizontal, 12)
                .listRowBackground(Color.white.opacity(0.04))
            }

            // Import from file button (all providers)
            Section(importSectionTitle) {
                Button(action: importFromFile) {
                    HStack {
                        Image(systemName: "folder.badge.person.crop")
                        Text(importButtonTitle)
                        Spacer()
                    }
                }
                .foregroundStyle(accent)

                Text(importHelpText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .listRowBackground(Color.white.opacity(0.04))

            if providerID == .openai, account.isPrimary {
                codexTelemetrySection
            }

            #if DEBUG
            Section("Debug Info") {
                Text("Account: \(account.rawValue)")
                    .font(.caption)
                Text("Detected files: \(providerDetectedCredentials.count)")
                    .font(.caption)
                ForEach(providerDetectedCredentials) { cred in
                    Text("- \(cred.providerID.rawValue): \(cred.fileURL.lastPathComponent)")
                        .font(.caption2)
                }
            }
            .listRowBackground(Color.white.opacity(0.04))
            #endif

            Section("Credentials You Control") {
                if providerID == .cursor {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Sign in to Cursor in the embedded browser to capture your current cursor.com session. The app stores only a normalized cookie header in Keychain.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        webSessionImportButton(
                            "Import Cursor web session...",
                            systemImage: "cursorarrow.rays"
                        ) {
                            activeWebImport = .cursor
                        }

                        if cursorSessionImported {
                            Label("Web session stored", systemImage: "checkmark.circle.fill")
                                .font(.caption)
                                .foregroundStyle(.green)
                        }
                    }
                } else if providerID == .kimi {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Import a kimi.ai web session to add the shared monthly membership-credit meter and read the 5-hour meter as the kimi.ai account page shows it. Kimi Code API keys and CLI OAuth folders continue to provide the weekly meter, and the 5-hour meter when no web session answers.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        webSessionImportButton(
                            "Import Kimi web session...",
                            systemImage: "moon.stars.fill"
                        ) {
                            activeWebImport = .kimi
                        }

                        if kimiWebSessionImported {
                            Label("Web session stored", systemImage: "checkmark.circle.fill")
                                .font(.caption)
                                .foregroundStyle(.green)
                        }

                        SecureField(providerID.primaryCredentialLabel, text: $accessToken)
                            .autocorrectionDisabled()
                        #if os(iOS)
                            .textInputAutocapitalization(.never)
                        #endif
                    }
                } else if providerID == .ollama {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Sign into ollama.com in the embedded browser, or paste your `__Secure-session` cookie directly below:")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        webSessionImportButton(
                            "Import Ollama web session...",
                            systemImage: "circle.grid.2x2.fill"
                        ) {
                            activeWebImport = .ollama
                        }

                        if ollamaSessionImported {
                            Label("Web session stored", systemImage: "checkmark.circle.fill")
                                .font(.caption)
                                .foregroundStyle(.green)
                        }

                        SecureField(providerID.primaryCredentialLabel, text: $accessToken)
                            .autocorrectionDisabled()
                        #if os(iOS)
                            .textInputAutocapitalization(.never)
                        #endif
                    }
                } else if providerID == .mistral {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Sign into admin.mistral.ai in the embedded browser to automatically track live API usage & Vibe Code usage quotas, or enter an Admin API key:")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        webSessionImportButton(
                            "Import Mistral web session...",
                            systemImage: "m.square.fill"
                        ) {
                            activeWebImport = .mistral
                        }

                        if mistralSessionImported {
                            Label("Web session stored", systemImage: "checkmark.circle.fill")
                                .font(.caption)
                                .foregroundStyle(.green)
                        }

                        SecureField(providerID.primaryCredentialLabel, text: $accessToken)
                            .autocorrectionDisabled()
                        #if os(iOS)
                            .textInputAutocapitalization(.never)
                        #endif
                    }
                 } else if providerID == .meta {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Sign into dev.meta.ai in the embedded browser to automatically track your Meta API current balance and billing-period spend, or enter a manual billing anchor below:")
                             .font(.caption)
                             .foregroundStyle(.secondary)
                             .fixedSize(horizontal: false, vertical: true)

                        webSessionImportButton(
                             "Import Meta web session...",
                            systemImage: "infinity"
                         ) {
                            activeWebImport = .metaWeb
                         }

                        if metaWebSessionImported {
                            Label("Web session stored", systemImage: "checkmark.circle.fill")
                                 .font(.caption)
                                 .foregroundStyle(.green)
                         }

                        Text("Subscribed to Muse Code? Grant the Muse CLI so Limit Counter can read the subscription meters locally every 10 minutes — no browser session and no rate-limit risk:")
                             .font(.caption)
                             .foregroundStyle(.secondary)
                             .fixedSize(horizontal: false, vertical: true)

                        webSessionImportButton(
                             "Grant Muse CLI...",
                            systemImage: "terminal"
                         ) {
                            grantMuseCliAccess()
                         }

                        if museCliGranted {
                            Label("Muse CLI granted", systemImage: "checkmark.circle.fill")
                                 .font(.caption)
                                 .foregroundStyle(.green)
                         }

                        if let museCliProbeStatus {
                            HStack(spacing: 6) {
                                if isProbingMuseCli {
                                    ProgressView()
                                         .progressViewStyle(.circular)
                                         .controlSize(.small)
                                 }
                                Text(museCliProbeStatus)
                                     .font(.caption)
                                     .foregroundStyle(.secondary)
                                     .fixedSize(horizontal: false, vertical: true)
                             }
                         }

                        Text("An imported browser session supplies the subscription meters when configured (checked at most hourly). The CLI remains available without a browser import:")
                             .font(.caption)
                             .foregroundStyle(.secondary)
                             .fixedSize(horizontal: false, vertical: true)

                        webSessionImportButton(
                             "Import Muse Code subscription...",
                            systemImage: "speedometer"
                         ) {
                            activeWebImport = .museSubscription
                         }

                        if museSubscriptionImported {
                            Label("Subscription meters stored", systemImage: "checkmark.circle.fill")
                                 .font(.caption)
                                 .foregroundStyle(.green)
                         }

                        TextField(providerID.primaryCredentialLabel, text: $customEndpoint)
                             .autocorrectionDisabled()
                         #if os(iOS)
                             .textInputAutocapitalization(.never)
                         #endif
                     }
                 } else if providerID == .cerebras {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Sign into cloud.cerebras.ai in the embedded browser to automatically track your Cerebras current balance, or enter a manual billing anchor below:")
                             .font(.caption)
                             .foregroundStyle(.secondary)
                             .fixedSize(horizontal: false, vertical: true)

                        webSessionImportButton(
                             "Import Cerebras web session...",
                            systemImage: "cpu"
                         ) {
                            activeWebImport = .cerebras
                         }

                        if cerebrasWebSessionImported {
                            Label("Web session stored", systemImage: "checkmark.circle.fill")
                                 .font(.caption)
                                 .foregroundStyle(.green)
                         }

                        TextField(providerID.primaryCredentialLabel, text: $customEndpoint)
                             .autocorrectionDisabled()
                         #if os(iOS)
                             .textInputAutocapitalization(.never)
                         #endif
                     }
                  } else if providerID == .qwen {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Sign into Alibaba Cloud Model Studio in the embedded browser to automatically track your Qwen token plan quota, or enter a manual percent anchor below:")
                              .font(.caption)
                              .foregroundStyle(.secondary)
                              .fixedSize(horizontal: false, vertical: true)

                        webSessionImportButton(
                              "Import Qwen web session...",
                            systemImage: "q.circle.fill"
                          ) {
                            activeWebImport = .qwen
                          }

                        if qwenWebSessionImported {
                            Label("Web session stored", systemImage: "checkmark.circle.fill")
                                  .font(.caption)
                                  .foregroundStyle(.green)
                          }

                        TextField(providerID.primaryCredentialLabel, text: $customEndpoint)
                              .autocorrectionDisabled()
                          #if os(iOS)
                              .textInputAutocapitalization(.never)
                          #endif
                      }
                  } else if providerID == .mimo {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Sign into the Xiaomi MiMo console in the embedded browser to automatically track your plan quota meter, or enter a manual weekly-percent anchor below:")
                              .font(.caption)
                              .foregroundStyle(.secondary)
                              .fixedSize(horizontal: false, vertical: true)

                        webSessionImportButton(
                              "Import MiMo web session...",
                            systemImage: "m.circle.fill"
                          ) {
                            activeWebImport = .mimo
                          }

                        if mimoWebSessionImported {
                            Label("Web session stored", systemImage: "checkmark.circle.fill")
                                  .font(.caption)
                                  .foregroundStyle(.green)
                          }

                        TextField(providerID.primaryCredentialLabel, text: $customEndpoint)
                              .autocorrectionDisabled()
                          #if os(iOS)
                              .textInputAutocapitalization(.never)
                          #endif
                      }
                  } else if providerID == .minimax {
                    SecureField(providerID.primaryCredentialLabel, text: $accessToken)
                        .autocorrectionDisabled()
                    #if os(iOS)
                        .textInputAutocapitalization(.never)
                    #endif
                    Link("Open MiniMax Plan Details", destination: URL(string: "https://platform.minimax.io/console/plan")!)
                    Text("Copy the Subscription Key (sk-cp) from Plan Details. The 5-hour and weekly meters share your Token Plan quota across tools and models. A pay-as-you-go API key does not report subscription usage.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    SecureField("API key for Usage Credits (optional)", text: minimaxBalanceAPIKey)
                        .autocorrectionDisabled()
                    #if os(iOS)
                        .textInputAutocapitalization(.never)
                    #endif
                    Text("Add a pay-as-you-go API key (sk-api) to show your available account balance alongside the Token Plan meters. It is stored in Keychain and used only to read MiniMax's account balance. Leave the Subscription Key empty to monitor only the balance.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                  } else if providerID == .claude {
                    TextField(providerID.primaryCredentialLabel, text: $accessToken)
                         .autocorrectionDisabled()
                     #if os(iOS)
                         .textInputAutocapitalization(.never)
                     #endif
                 } else if usesLocalPathAsPrimaryCredential {
                    TextField(providerID.primaryCredentialLabel, text: $customEndpoint)
                        .autocorrectionDisabled()
                    #if os(iOS)
                        .textInputAutocapitalization(.never)
                    #endif
                } else {
                    SecureField(providerID.primaryCredentialLabel, text: $accessToken)
                        .autocorrectionDisabled()
                    #if os(iOS)
                        .textInputAutocapitalization(.never)
                    #endif
                }

                if let secondaryCredentialLabel = providerID.secondaryCredentialLabel {
                    if providerID == .claude {
                        SecureField(secondaryCredentialLabel, text: $accountIdentifier)
                            .autocorrectionDisabled()
                        #if os(iOS)
                            .textInputAutocapitalization(.never)
                        #endif
                    } else {
                        TextField(secondaryCredentialLabel, text: $accountIdentifier)
                            .autocorrectionDisabled()
                        #if os(iOS)
                            .textInputAutocapitalization(.never)
                        #endif
                    }
                }

                if providerID == .claude || providerID == .openai {
                    apiUsageReportingFields
                }
            }
            .padding(.horizontal, 12)
            .listRowBackground(Color.white.opacity(0.04))

            if providerID == .mistral || providerID == .deepseek || providerID == .cerebras
                 || providerID == .meta || providerID == .qwen || providerID == .mimo
                 || providerID == .openrouter {
                billingAnchorSection
             }

            Section("Advanced") {
                if providerID == .claude {
                    Toggle("Read Claude Code's sign-in from the Keychain", isOn: claudeCodeKeychainFallbackEnabled)
                    Text("Reads the token Claude Code already holds so the dashboard can show live 5-hour and weekly meters. Limit Counter only ever reads that Keychain item — Claude Code stays the only thing that renews or writes it, because writing it makes the CLI ask for your login password on every read. If macOS asks for authorization, click Refresh and choose Always Allow. The meters go quiet when Claude Code has not run for over 8 hours; running it brings them back.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else if providerID == .openai {
                    Text("Grant the full `~/.codex` folder above. The app rereads only `auth.json` inside that persistent sandbox grant, so token rotation and CLI updates do not require another file-level permission prompt.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else if providerID == .chatgpt {
                    Text("Use the import button to grant access to `~/Library/Application Support/com.openai.chat`. The app reads local ChatGPT desktop cache activity like recent chats, drafts, and projects.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else if providerID == .codexTelemetry {
                    Text("Use the import button to grant access to the full `~/.codex` folder for reliable Codex activity. Selecting only `logs_2.sqlite` works as a limited fallback, but it cannot discover session files.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else if providerID == .openaiAPI {
                    Text("Use an OpenAI admin API key plus a project ID. This provider reads official organization usage and costs endpoints only; it does not inspect browser sessions or local app credentials.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    TextField("Custom Endpoint (optional)", text: $customEndpoint)
                        .autocorrectionDisabled()
                    #if os(iOS)
                        .textInputAutocapitalization(.never)
                    #endif
                } else if providerID == .cursor {
                    Text("Use the in-app Cursor session import flow above for live usage meters. You can also import Cursor's `globalStorage` folder or `state.vscdb` for cached account metadata and local AI activity stats.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    TextField("Custom Endpoint (optional)", text: $customEndpoint)
                        .autocorrectionDisabled()
                    #if os(iOS)
                        .textInputAutocapitalization(.never)
                    #endif
                } else if providerID == .gemini {
                    Text("Use the import button to grant access to `~/.gemini`. The app reads local Gemini CLI session history and turns it into token-based usage snapshots.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Picker("Limit preset", selection: geminiLimitPresetSelection) {
                        ForEach(GeminiLimitPreset.allCases) { preset in
                            Text(preset.title).tag(preset.rawValue)
                        }
                    }
                    .pickerStyle(.menu)
                    Text(selectedGeminiLimitPreset.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else if providerID == .grok {
                    Text("Use the import button to grant access to `~/.grok`. Limit Counter runs the local `grok` CLI with `/usage`, parses the weekly quota screen, and keeps TaskWraith data optional for activity enrichment.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else if providerID == .antigravity {
                    Text("After granting access, Limit Counter reads the official CLI session and requests Antigravity 5-hour and 7-day quota windows on a looping cadence: 4m → 7m → 16m → 3m → 21m. Manual refresh always fetches immediately. Background refreshes never send model prompts.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else if providerID == .mistral {
                    TextField("Vibe data folder", text: $customEndpoint)
                        .autocorrectionDisabled()
                    #if os(iOS)
                        .textInputAutocapitalization(.never)
                    #endif
                    Text(providerID.securityNote)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else if providerID == .meta {
                    Text(providerID.securityNote)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else if providerID == .cerebras {
                    Text(providerID.securityNote)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else if providerID == .kimi {
                    Text("Paste a Kimi Code Console API key above, or import `~/.kimi-code` for the current CLI OAuth session and local activity. Limit Counter renews and safely persists Kimi's rotating OAuth token; an old `~/.kimi` grant must be replaced through the folder picker.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else if providerID == .ollama {
                    Text("Paste your `__Secure-session` cookie from ollama.com (found in browser DevTools → Storage/Application → Cookies → ollama.com → `__Secure-session`). Limit Counter securely saves it to macOS Keychain and reads your 5-hour, Weekly, or monthly included-usage budget from ollama.com/settings.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else if providerID == .openrouter {
                    Text("Paste your OpenRouter API key (`sk-or-v1-...`) above. Limit Counter securely saves it to macOS Keychain and requests `https://openrouter.ai/api/v1/auth/key` to track live spend and any spending cap on the key. Add your loaded credit or a management key under Billing Anchor for a credit meter.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    TextField("Custom Endpoint (optional)", text: $customEndpoint)
                        .autocorrectionDisabled()
                    #if os(iOS)
                        .textInputAutocapitalization(.never)
                    #endif
                } else {
                    TextField("Custom Endpoint (optional)", text: $customEndpoint)
                        .autocorrectionDisabled()
                    #if os(iOS)
                        .textInputAutocapitalization(.never)
                    #endif

                    Text(providerID.securityNote)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 12)
            .listRowBackground(Color.white.opacity(0.04))

            Section {
                Button(action: saveCredential) {
                    HStack {
                        Spacer()
                        Text(isSaved ? "Saved!" : "Save")
                            .fontWeight(.semibold)
                            .foregroundStyle(isSaved ? .green : accent)
                        Spacer()
                    }
                }

                Button(role: .destructive, action: deleteCredential) {
                    HStack {
                        Spacer()
                        Text("Remove Credentials")
                        Spacer()
                    }
                }
            }
            .padding(.horizontal, 12)
            .listRowBackground(Color.white.opacity(0.04))
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 6)
        .scrollContentBackground(.hidden)
        // The grouped style is the one that actually compresses to the width it
        // is given. The default `.columns` style sizes itself from its widest
        // row and overflows instead, which is what pushed this form out past
        // both edges of the sheet.
        .formStyle(.grouped)
        .navigationTitle(
            accountRegistry.label(for: account).map { "\(providerID.displayName) · \($0)" } ?? providerID.displayName
        )
        .onDisappear(perform: commitAccountLabel)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .onAppear(perform: loadExisting)
    }

    @ViewBuilder
    private var billingAnchorSection: some View {
        Section("Billing Anchor") {
            if providerID == .mistral {
                TextField(
                    "Vibe spend to date",
                    text: extraFieldBinding(SpendProviderCredentialField.manualSpent)
                )
                TextField(
                    "API & Studio spend to date (optional)",
                    text: extraFieldBinding(SpendProviderCredentialField.mistralApiSpent)
                )
                TextField(
                    "API & Studio budget (optional)",
                    text: extraFieldBinding(SpendProviderCredentialField.mistralApiAllowance)
                )
                TextField(
                    "Currency (USD, GBP, EUR)",
                    text: extraFieldBinding(SpendProviderCredentialField.manualCurrency, defaultValue: "EUR")
                )
                TextField(
                    "Billing reset (ISO date, optional)",
                    text: extraFieldBinding(SpendProviderCredentialField.manualResetAt)
                )
                TextField(
                    "Plan name (optional)",
                    text: extraFieldBinding(SpendProviderCredentialField.manualPlanName)
                )
                Text("Enter your current web readings for Vibe Code and API & Studio. Vibe Code spend will automatically track new local ~/.vibe sessions; leave spend blank for purely automatic estimates.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if providerID == .meta {
                TextField(
                    "Meta console spend to date",
                    text: extraFieldBinding(SpendProviderCredentialField.manualSpent)
                )
                TextField(
                    "Preload credit",
                    text: extraFieldBinding(SpendProviderCredentialField.manualTopUpTotal)
                )
                TextField(
                    "Remaining balance",
                    text: extraFieldBinding(SpendProviderCredentialField.manualCurrentBalance)
                )
                TextField(
                    "Currency (USD, GBP, EUR)",
                    text: extraFieldBinding(SpendProviderCredentialField.manualCurrency, defaultValue: "USD")
                )
                TextField(
                    "Billing reset (ISO date, optional)",
                    text: extraFieldBinding(SpendProviderCredentialField.manualResetAt)
                )
                TextField(
                    "Plan name (optional)",
                    text: extraFieldBinding(SpendProviderCredentialField.manualPlanName)
                )
                Text("Console spend is optional. If unset, Limit Counter uses threshold−remaining when both are set, otherwise Muse-only from £0/$0. GBP/EUR remaining auto-decrements using Muse USD×FX. Enter the console Spend reading for best Mistral-style parity. Preload minus remaining is credit used.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
             } else if providerID == .deepseek {
                TextField(
                    "Total topped up",
                    text: extraFieldBinding(SpendProviderCredentialField.manualTopUpTotal)
                 )
                Text("Limit Counter subtracts the official live remaining balance from this cumulative top-up total to derive the credit-used meter. Update it whenever you add more credit.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
             } else if providerID == .openrouter {
                TextField(
                    "Total credit loaded (USD)",
                    text: extraFieldBinding(OpenRouterCredentialField.creditLoaded)
                )
                SecureField(
                    "Management key (optional)",
                    text: extraFieldBinding(OpenRouterCredentialField.managementKey)
                )
                Text("Enter the total credit you have loaded to see this key's spend as a credit meter, and update it after each top-up. A management key (OpenRouter → Settings → Management Keys) makes the meter exact and account-wide instead: Limit Counter reads your credits from `/api/v1/credits` and ignores the figure above. The management key stays in Keychain and is only sent to openrouter.ai.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
             } else if providerID == .qwen || providerID == .mimo {
                TextField(
                    "Quota used (%)",
                    text: extraFieldBinding(SpendProviderCredentialField.manualWeeklyUsedPercent)
                 )
                TextField(
                    "Plan reset (ISO date, optional)",
                    text: extraFieldBinding(SpendProviderCredentialField.manualResetAt)
                 )
                TextField(
                    "Plan name (optional)",
                    text: extraFieldBinding(SpendProviderCredentialField.manualPlanName)
                 )
                Text("Import the web session above for automatic tracking. Otherwise enter the dashboard's \"% Used\" reading as a manual anchor and update it after each check.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
             } else {
                TextField(
                    "Current balance",
                    text: extraFieldBinding(SpendProviderCredentialField.manualCurrentBalance)
                )
                TextField(
                    "Currency (USD, GBP, EUR)",
                    text: extraFieldBinding(SpendProviderCredentialField.manualCurrency, defaultValue: "USD")
                )
                TextField(
                    "Plan name (optional)",
                    text: extraFieldBinding(SpendProviderCredentialField.manualPlanName)
                )
                Text("Purchased credits are the optional field above. This manual balance is kept distinct from CSV-reported cost and TaskWraith price estimates.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 12)
        .listRowBackground(Color.white.opacity(0.04))
    }

    /// The admin key that reads a Console / organisation API bill. It is a
    /// separate credential from the seat's own token: it reads spend, never
    /// runs anything, and stays in Keychain beside the account's fields.
    @ViewBuilder
    private var apiUsageReportingFields: some View {
        if providerID == .claude {
            SecureField(
                "Anthropic Admin API key (usage reporting, optional)",
                text: extraFieldBinding(APIUsageCredentialField.anthropicAdminKey)
            )
                .autocorrectionDisabled()
            #if os(iOS)
                .textInputAutocapitalization(.never)
            #endif
            Text("Reads the Console organisation's month-to-date cost report so API spend shows under Usage Credits as \"Claude · Console API\". Use an Admin API key (`sk-ant-admin01-…`) from Console → Settings → Organization, not the OAuth token above. It is stored in Keychain and sent only to api.anthropic.com. Individual accounts and workspace-scoped keys cannot read the report.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            SecureField(
                "OpenAI admin API key (usage reporting, optional)",
                text: extraFieldBinding(APIUsageCredentialField.openAIAdminKey)
            )
                .autocorrectionDisabled()
            #if os(iOS)
                .textInputAutocapitalization(.never)
            #endif
            TextField(
                "OpenAI project ID (optional, proj_…)",
                text: extraFieldBinding(APIUsageCredentialField.openAIProjectID)
            )
                .autocorrectionDisabled()
            #if os(iOS)
                .textInputAutocapitalization(.never)
            #endif
            Text("Reads the organisation's month-to-date costs so API spend shows under Usage Credits as \"Codex · OpenAI API\". Use an admin key from platform.openai.com → Settings → Organization → Admin keys; a project key cannot read costs. Leave the project ID blank for the whole organisation. The key is stored in Keychain and sent only to api.openai.com.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func extraFieldBinding(_ key: String, defaultValue: String = "") -> Binding<String> {
        Binding(
            get: { storedExtraFields[key] ?? defaultValue },
            set: { value in
                ProviderSetupPolicy.setExtraField(key, to: value, in: &storedExtraFields)
            }
        )
    }

    @ViewBuilder
    private var codexTelemetrySection: some View {
        Section("Codex Local Activity") {
            VStack(alignment: .leading, spacing: 6) {
                Text("Local Codex logs supply the expanded card details and activity heatmap entries for Codex. Grant the `~/.codex` folder for the most reliable heatmap history.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if codexTelemetryHasCredential {
                    Label(codexTelemetrySaved ? "Local activity access saved" : "Local activity access configured", systemImage: "checkmark.circle.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.green)

                    if !codexTelemetryEndpoint.isEmpty {
                        Text(codexTelemetryEndpoint)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .truncationMode(.middle)
                    }
                }
            }
            .padding(.vertical, 2)

            if !codexTelemetryDetectedCredentials.isEmpty {
                ForEach(codexTelemetryDetectedCredentials) { detected in
                    Button(action: { importCodexTelemetryCredential(detected) }) {
                        HStack(spacing: 10) {
                            Image(systemName: "doc.badge.arrow.up")
                            VStack(alignment: .leading, spacing: 2) {
                                Text(detected.description)
                                    .font(.subheadline)
                                Text(detected.fileURL.lastPathComponent)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer(minLength: 8)
                            Image(systemName: "arrow.right.circle.fill")
                                .foregroundStyle(accent)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .foregroundStyle(.primary)
                }
            }

            Button(action: importCodexTelemetryFromFile) {
                HStack {
                    Image(systemName: "folder.badge.plus")
                    Text("Select Codex log folder...")
                    Spacer()
                }
            }
            .foregroundStyle(accent)

            if codexTelemetryHasCredential {
                Button(role: .destructive, action: deleteCodexTelemetryCredential) {
                    HStack {
                        Spacer()
                        Text("Remove Local Activity Access")
                        Spacer()
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .listRowBackground(Color.white.opacity(0.04))
    }

    private func importFromFile() {
        #if os(macOS)
        CredentialImportService.showImportPanel(for: providerID, account: account) { result in
            DispatchQueue.main.async {
                switch result {
                case .success(let credential):
                    self.applyImportedCredential(credential)
                case .failure(let error):
                    if let importError = error as? CredentialImportService.ImportError,
                       case .userCancelled = importError {
                        return
                    }
                    if let importError = error as? CredentialImportService.ImportError {
                        self.importError = importError.errorDescription
                    } else {
                        self.importError = error.localizedDescription
                    }
                    self.showImportError = true
                }
            }
        }
        #else
        importError = "File import not supported on this platform."
        showImportError = true
        #endif
    }

    private func importDetectedCredential(_ detected: CredentialImportService.DetectedCredential) {
        if detected.providerID == .openai || detected.providerID == .kimi || detected.providerID == .antigravity
            || detected.providerID == .mistral || detected.providerID == .cerebras
            || detected.providerID == .meta {
            // Auto-detection can suggest the path, but only NSOpenPanel can
            // issue a persistent sandbox grant for this folder.
            importFromFile()
            return
        }

        do {
            let credential = try CredentialImportService.importFromURL(detected.fileURL, for: detected.providerID)
            applyImportedCredential(credential)
        } catch {
            importError = (error as? CredentialImportService.ImportError)?.errorDescription
                ?? error.localizedDescription
            showImportError = true
        }
    }

    private func importCodexTelemetryFromFile() {
        #if os(macOS)
        CredentialImportService.showImportPanel(for: .codexTelemetry) { result in
            DispatchQueue.main.async {
                switch result {
                case .success(let credential):
                    self.saveCodexTelemetryCredential(credential)
                case .failure(let error):
                    if let importError = error as? CredentialImportService.ImportError {
                        self.importError = importError.errorDescription
                    } else {
                        self.importError = error.localizedDescription
                    }
                    self.showImportError = true
                }
            }
        }
        #else
        importError = "File import not supported on this platform."
        showImportError = true
        #endif
    }

    private func importCodexTelemetryCredential(_ detected: CredentialImportService.DetectedCredential) {
        _ = detected
        importCodexTelemetryFromFile()
    }

    private func saveCodexTelemetryCredential(_ imported: CredentialImportService.ImportedCredential) {
        var extraFields = imported.extraFields ?? [:]
        if let bookmarkData = imported.bookmarkData {
            extraFields["bookmarkData"] = bookmarkData.base64EncodedString()
        }

        let credential = ProviderCredential(
            accessToken: imported.accessToken,
            accountIdentifier: imported.accountIdentifier,
            customEndpoint: imported.customEndpoint,
            extraFields: extraFields.isEmpty ? nil : extraFields,
            bookmarkData: imported.bookmarkData
        )

        if credential.isEmpty {
            KeychainService.shared.delete(for: .codexTelemetry)
        } else if !KeychainService.shared.save(credential, for: .codexTelemetry) {
            showKeychainSaveFailure(for: .codexTelemetry)
            return
        }

        loadCodexTelemetryCredential()
        loadedBillingAnchorSignature = ProviderSetupPolicy.billingAnchorSignature(
            currentDraft,
            providerID: providerID
        )
        codexTelemetrySaved = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { codexTelemetrySaved = false }
    }

    private func deleteCodexTelemetryCredential() {
        KeychainService.shared.delete(for: .codexTelemetry)
        loadCodexTelemetryCredential()
        codexTelemetrySaved = false
    }

    private func loadCodexTelemetryCredential() {
        guard providerID == .openai else { return }

        if let credential = KeychainService.shared.credential(for: .codexTelemetry) {
            codexTelemetryEndpoint = credential.customEndpoint ?? ""
            codexTelemetryHasCredential = true
        } else {
            codexTelemetryEndpoint = ""
            codexTelemetryHasCredential = false
        }
    }

    /// The form's editable state as a value, so the shared policy can act on it.
    private var currentDraft: ProviderSetupPolicy.Draft {
        ProviderSetupPolicy.Draft(
            accessToken: accessToken,
            accountIdentifier: accountIdentifier,
            customEndpoint: customEndpoint,
            extraFields: storedExtraFields,
            loadedBillingAnchorSignature: loadedBillingAnchorSignature
        )
    }

    private func apply(_ draft: ProviderSetupPolicy.Draft) {
        accessToken = draft.accessToken
        accountIdentifier = draft.accountIdentifier
        customEndpoint = draft.customEndpoint
        storedExtraFields = draft.extraFields
        loadedBillingAnchorSignature = draft.loadedBillingAnchorSignature
    }

    private func applySessionFlags(from draft: ProviderSetupPolicy.Draft) {
        let flags = ProviderSetupPolicy.sessionFlags(draft, providerID: providerID)
        cursorSessionImported = flags.cursor
        kimiWebSessionImported = flags.kimiWeb
        ollamaSessionImported = flags.ollama
        mistralSessionImported = flags.mistral
        metaWebSessionImported = flags.metaWeb
        cerebrasWebSessionImported = flags.cerebras
        qwenWebSessionImported = flags.qwen
        mimoWebSessionImported = flags.mimo
        museSubscriptionImported = flags.museSubscription
        museCliGranted = flags.museCli
    }

    private func loadExisting() {
        let credential = KeychainService.shared.credential(for: account)
        let draft = ProviderSetupPolicy.draft(from: credential, providerID: providerID)
        apply(draft)
        applySessionFlags(from: draft)
        accountLabelDraft = accountRegistry.label(for: account) ?? ""

        // A second Claude account exists for its live meters, and those come
        // from that account's own Claude Code sign-in, so the read starts on.
        // The primary keeps its explicit opt-in.
        if !account.isPrimary, providerID == .claude, credential == nil {
            ClaudeOAuthCredentialPolicy.setClaudeCodeKeychainFallbackEnabled(true, in: &storedExtraFields)
        }

        // Scan for available credential files
        detectedCredentials = CredentialImportService.detectAvailableCredentials()
        print("[SettingsView] Loaded \(detectedCredentials.count) credentials for \(providerID)")
        for cred in detectedCredentials {
            print("  - \(cred.providerID): \(cred.fileURL.path)")
        }

        loadCodexTelemetryCredential()
    }

    private func saveCredential() {
        _ = persistDraft(extraFieldsOverride: nil)
    }

    /// The single save path. `extraFieldsOverride` is how an import writes a
    /// freshly merged field set instead of whatever the form currently holds.
    private func persistDraft(extraFieldsOverride: [String: String]?) -> Bool {
        let draft = currentDraft
        var input = ProviderSetupPolicy.saveInput(
            for: draft,
            providerID: providerID,
            now: Date(),
            suppliedExtraFields: extraFieldsOverride
        )

        // Creating the bookmark is I/O and stays here, inside whatever grant the
        // user has just handed over.
        if let bookmarkURL = input.bookmarkSourceURL {
            #if os(macOS)
            do {
                let bookmarkData = try bookmarkURL.bookmarkData(
                    options: .withSecurityScope,
                    includingResourceValuesForKeys: nil,
                    relativeTo: nil
                )
                input.extraFields["bookmarkData"] = bookmarkData.base64EncodedString()
                print("[SettingsView] Created security-scoped folder-grant bookmark for \(providerID.rawValue)")
            } catch {
                print("[SettingsView] Failed to create bookmark: \(error)")
            }
            #endif
        }

        let credential = ProviderSetupPolicy.credential(
            from: draft,
            providerID: providerID,
            extraFields: input.extraFields
        )
        if credential.isEmpty {
            deleteCredential()
            return true
        }

        guard KeychainService.shared.save(credential, for: account) else {
            showKeychainSaveFailure(for: providerID)
            return false
        }

        storedExtraFields = input.extraFields
        var saved = draft
        saved.extraFields = input.extraFields
        loadedBillingAnchorSignature = ProviderSetupPolicy.billingAnchorSignature(
            saved,
            providerID: providerID
        )
        applySessionFlags(from: saved)
        isSaved = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { isSaved = false }
        return true
    }

    @discardableResult
    /// Grants the sandboxed app permission to run the Muse launcher. The
    /// bookmark must cover the containing folder, not just the launcher: the
    /// `muse` script execs the versioned `muse-bin-*` binary beside it.
    private func grantMuseCliAccess() {
        #if os(macOS)
        let panel = NSOpenPanel()
        panel.title = "Grant access to the Muse CLI"
        panel.message = "Select the folder containing the `muse` launcher (usually ~/.local/bin) so Limit Counter can read your subscription meters locally."
        panel.prompt = "Grant"
        // Folders only. The `muse` script execs the versioned `muse-bin-*`
        // binary beside it, so a file-scoped bookmark could not run it — and
        // allowing files lets a stray selection be granted instead of the
        // folder the user is browsing.
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true

        let defaultURL = MuseCliBinaryLocator.defaultBinaryURL().deletingLastPathComponent()
        if FileManager.default.fileExists(atPath: defaultURL.path) {
            panel.directoryURL = defaultURL
        }

        // `begin`, never `runModal`: this view is hosted inside a sheet, and a
        // nested modal run loop there freezes SwiftUI layout and strands the
        // Powerbox panel behind the app. The security-scope dance stays inside
        // the completion handler so validation runs within the grant the panel
        // has just handed over.
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            // The panel returns the folder itself; a file only arrives if the
            // user dragged one in, in which case its folder is what we need.
            let folderURL = url.hasDirectoryPath ? url : url.deletingLastPathComponent()
            let didStartScope = folderURL.startAccessingSecurityScopedResource()
            defer { if didStartScope { folderURL.stopAccessingSecurityScopedResource() } }
            guard MuseCliBinaryLocator.binaryURL(within: folderURL) != nil else {
                importError = "No `muse` launcher was found in \(folderURL.lastPathComponent). Open the folder that contains the `muse` command (usually ~/.local/bin) and click Grant without selecting a file."
                showImportError = true
                return
            }
            guard let bookmarkData = try? folderURL.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            ) else {
                importError = "Could not create a security-scoped bookmark for that folder."
                showImportError = true
                return
            }

            var extraFields = storedExtraFields
            extraFields[SpendProviderCredentialField.museCliBookmark] = bookmarkData.base64EncodedString()
            guard saveCredentialWithExtraFields(extraFields) else { return }
            museCliGranted = true
            verifyMuseCliGrant(fields: extraFields)
        }
        #endif
    }

    /// Runs the probe straight after granting so the result is visible now
    /// rather than at the next ten-minute refresh — and so a sandbox or
    /// sign-in problem is reported instead of silently falling back.
    private func verifyMuseCliGrant(fields: [String: String]) {
        #if os(macOS)
        isProbingMuseCli = true
        museCliProbeStatus = "Reading subscription meters from the Muse CLI…"
        Task {
            let reading = await MetaProviderClient.probeMuseCli(
                fields: fields,
                now: Date(),
                userInitiated: true
            )
            await MainActor.run {
                isProbingMuseCli = false
                guard let reading else {
                    museCliProbeStatus = "The CLI ran but reported no meters. Check that `muse` starts in Terminal and is signed in, then try again."
                    return
                }
                let current = reading.currentUsedPercent.map { "\(Int($0.rounded()))%" } ?? "—"
                let weekly = reading.weeklyUsedPercent.map { "\(Int($0.rounded()))%" } ?? "—"
                let plan = reading.planName ?? "Muse Code"
                museCliProbeStatus = "\(plan): current \(current), weekly \(weekly)"
            }
        }
        #endif
    }

    private func saveCredentialWithExtraFields(
        _ suppliedExtraFields: [String: String]
    ) -> Bool {
        persistDraft(extraFieldsOverride: suppliedExtraFields)
    }

    @discardableResult
    private func applyImportedCredential(
        _ credential: CredentialImportService.ImportedCredential
    ) -> Bool {
        var merged = providerID == .cursor
            ? ProviderSetupPolicy.mergingCursor(
                currentDraft,
                imported: credential,
                existing: KeychainService.shared.credential(for: account)
            )
            : ProviderSetupPolicy.merging(
                currentDraft,
                imported: credential,
                providerID: providerID
            )
        // The folder grant is what makes a second Claude account readable at
        // all; an import that cleared the opt-in would leave it meterless.
        if providerID == .claude, !account.isPrimary {
            ClaudeOAuthCredentialPolicy.setClaudeCodeKeychainFallbackEnabled(true, in: &merged.extraFields)
        }
        // A new session may be a different Mistral account, whose meters the
        // previous session's last reading must not stand in for.
        if providerID == .mistral {
            MistralWebReadingCache.clear(for: account)
        }
        apply(merged)
        return saveCredentialWithExtraFields(merged.extraFields)
    }

    private func commitAccountLabel() {
        guard !account.isPrimary else { return }
        accountRegistry.rename(account, to: accountLabelDraft)
        accountLabelDraft = accountRegistry.label(for: account) ?? accountLabelDraft
    }

    private func showKeychainSaveFailure(for targetProviderID: ProviderID) {
        isSaved = false
        importError = "Limit Counter could not save \(targetProviderID.displayName) credentials to Keychain. Unlock the login keychain, check the permission prompt, and try again."
        showImportError = true
    }

    private func deleteCredential() {
        if providerID == .cursor {
            CursorSessionImportModel.clearStoredWebsiteData()
        } else if providerID == .qwen {
            QwenWebSessionImportModel.clearStoredWebsiteData()
        } else if providerID == .mimo {
            MimoWebSessionImportModel.clearStoredWebsiteData()
        } else if providerID == .mistral {
            MistralWebReadingCache.clear(for: account)
        }
        KeychainService.shared.delete(for: account)
        accessToken = ""
        accountIdentifier = ""
        customEndpoint = ""
        cursorSessionImported = false
        kimiWebSessionImported = false
        qwenWebSessionImported = false
        mimoWebSessionImported = false
        storedExtraFields = [:]
        loadedBillingAnchorSignature = ""
    }
}

struct SettingsView_Previews: PreviewProvider {
    static var previews: some View {
        NavigationStack {
            SettingsView()
        }
        .preferredColorScheme(.dark)
    }
}
