import SwiftUI
import WidgetKit
#if os(macOS)
import AppKit
import UniformTypeIdentifiers
#elseif os(iOS)
import UIKit
#endif

struct SettingsView: View {
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

    private var providerConfigurationRows: [SettingsProviderRowIdentity] {
        ProviderID.userFacingCases.map { SettingsProviderRowIdentity(section: "provider", providerID: $0) }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                LiquidGlassBackdrop(intensity: .settings)

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
                    Section("Providers") {
                        ForEach(providerConfigurationRows) { row in
                            ProviderSettingsRow(
                                providerID: row.providerID,
                                onConfigure: { openProviderConfiguration(row.providerID) },
                                isVisible: visibilityStore.binding(for: row.providerID)
                            )
                            .listRowBackground(Color.white.opacity(0.03))
                        }
                    }

                    Section("TaskWraith Data Source") {
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
                .sheet(isPresented: $showRawDataDebug) {
                    RawDataDebugView()
                }
            }
        }
    }

    private func openProviderConfiguration(_ providerID: ProviderID) {
        #if os(macOS)
        ProviderConfigurationWindowManager.shared.show(providerID: providerID)
        #endif
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
    @Environment(\.dismiss) private var dismiss
    @State private var selectedProvider: ProviderID?

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
                    dismiss()
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

        if panel.runModal() == .OK, let url = panel.url {
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

private struct ProviderSettingsRow: View {
    let providerID: ProviderID
    let onConfigure: () -> Void
    let isVisible: Binding<Bool>
    private var hasCredential: Bool { KeychainService.shared.hasCredential(for: providerID) }
    private var canAutoDiscoverUsableQuotaSource: Bool {
        #if os(macOS)
        let home = FileManager.default.homeDirectoryForCurrentUser
        if providerID == .claude {
            let claudeRoot = home.appendingPathComponent(".claude")
            let projectsDir = claudeRoot.appendingPathComponent("projects")
            return FileManager.default.fileExists(atPath: claudeRoot.path)
                && FileManager.default.fileExists(atPath: projectsDir.path)
        }
        if providerID == .codexTelemetry {
            let telemetryRoot = home.appendingPathComponent(".codex")
            let telemetryLog = telemetryRoot.appendingPathComponent("log")
            let telemetrySQLite = telemetryRoot.appendingPathComponent("logs_2.sqlite")
            let telemetrySessions = telemetryRoot.appendingPathComponent("session_index.jsonl")
            return FileManager.default.fileExists(atPath: telemetryRoot.path)
                && (FileManager.default.fileExists(atPath: telemetryLog.path)
                    || FileManager.default.fileExists(atPath: telemetrySQLite.path)
                    || FileManager.default.fileExists(atPath: telemetrySessions.path))
        }
        if providerID == .chatgpt {
            let chatGPTRoot = home.appendingPathComponent("Library/Application Support/com.openai.chat")
            let conversations = try? FileManager.default.contentsOfDirectory(
                at: chatGPTRoot,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
            return FileManager.default.fileExists(atPath: chatGPTRoot.path)
                && !(conversations?.isEmpty ?? true)
        }
        if providerID == .devin {
            let stateDB = home.appendingPathComponent("Library/Application Support/Devin/User/globalStorage/state.vscdb")
            let backupDB = home.appendingPathComponent("Library/Application Support/Devin/User/globalStorage/state.vscdb.backup")
            return FileManager.default.isReadableFile(atPath: stateDB.path)
                || FileManager.default.isReadableFile(atPath: backupDB.path)
        }
        if providerID == .gemini {
            let geminiRoot = home.appendingPathComponent(".gemini")
            let tmpDir = geminiRoot.appendingPathComponent("tmp")
            return FileManager.default.fileExists(atPath: geminiRoot.path)
                && FileManager.default.fileExists(atPath: tmpDir.path)
        }
        if providerID == .grok {
            return false
        }
        #endif
        return false
    }
    private var isConfigured: Bool { hasCredential || canAutoDiscoverUsableQuotaSource }
    private var accent: Color { Color(hex: providerID.accentColorHex) }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            ProviderBrandIconView(providerID: providerID, size: 24)

            VStack(alignment: .leading, spacing: 4) {
                Text(providerID.displayName)
                    .foregroundStyle(.primary)

                Text(providerID.configurationTitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                Text(providerID.integrationStatus.badgeTitle)
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(accent.opacity(0.14), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                    .foregroundStyle(accent)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 6) {
                Button(action: onConfigure) {
                    Text("Configure")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(accent.opacity(0.14), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                        .foregroundStyle(accent)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Configure \(providerID.displayName)")
                .accessibilityIdentifier("configure-\(providerID.rawValue)")

                Toggle(isOn: isVisible) {
                    Text("Shown on Dashboard")
                        .font(.caption2.weight(.semibold))
                }
                .labelsHidden()
                .toggleStyle(.switch)
                .frame(maxWidth: 70, alignment: .trailing)

                HStack(spacing: 4) {
                    Image(systemName: isConfigured ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(isConfigured ? .green : .secondary)

                    Text(isConfigured ? "Configured" : "Setup required")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
        .accessibilityAction {
            onConfigure()
        }
        .accessibilityAction(named: Text("Configure \(providerID.displayName)")) {
            onConfigure()
        }
    }
}

// MARK: - Credential Form

struct ProviderCredentialView: View {
    let providerID: ProviderID

    @State private var accessToken = ""
    @State private var accountIdentifier = ""
    @State private var customEndpoint = ""
    @State private var isSaved = false
    @State private var importError: String?
    @State private var showImportError = false
    @State private var detectedCredentials: [CredentialImportService.DetectedCredential] = []
    @State private var showCursorSessionImport = false
    @State private var cursorSessionImported = false
    @State private var showOllamaSessionImport = false
    @State private var ollamaSessionImported = false
    @State private var showMistralSessionImport = false
    @State private var mistralSessionImported = false
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
        switch providerID {
        case .codexTelemetry, .chatgpt, .gemini, .grok, .antigravity, .cerebras, .meta:
            return true
        default:
            return false
        }
    }

    private var importSectionTitle: String {
        switch providerID {
        case .kimi:
            return "Import Kimi CLI Folder"
        case .antigravity:
            return "Grant Antigravity CLI Session Access"
        case .mistral:
            return "Grant Vibe Metadata Access"
        case .meta:
            return "Grant Muse Data Access"
        case .cerebras:
            return "Import Analytics Report"
        default:
            return "Import from File"
        }
    }

    private var importButtonTitle: String {
        switch providerID {
        case .grok:
            return "Select Grok folder..."
        case .kimi:
            return "Select ~/.kimi-code..."
        case .antigravity:
            return "Select Antigravity data folder..."
        case .mistral:
            return "Select ~/.vibe..."
        case .meta:
            return "Select ~/.local/share/muse..."
        case .cerebras:
            return "Select Cerebras CSV..."
        default:
            return "Select credential file..."
        }
    }

    private var importHelpText: String {
        switch providerID {
        case .grok:
            return "Grant access to your local `~/.grok` folder so Limit Counter can run the Grok CLI usage screen."
        case .kimi:
            return "Select the folder in the macOS picker so Limit Counter receives persistent read/write access for Kimi's rotating OAuth session."
        case .antigravity:
            return "Grant read-only access to `~/.gemini/antigravity-cli`. Limit Counter requests the Antigravity quota summary on a 4→7→16→3→21 minute loop (or immediately on manual refresh)."
        case .mistral:
            return "Grant access to `~/.vibe`. Limit Counter estimates Vibe spend TaskWraith-style from `meta.json` plus character lengths in `messages.jsonl` (content is not stored)."
        case .meta:
            return "Grant access to `~/.local/share/muse`. Limit Counter projects spend from Muse `session.jsonl` tokens × catalog rates. Meta has no balance API."
        case .cerebras:
            return "Import a report downloaded from Cerebras Console Analytics. The latest CSV in a selected folder is used."
        default:
            return "Import credentials from a JSON or text file you exported from the provider."
        }
    }

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

    var body: some View {
        standardConfigBody
    }

    private var standardConfigBody: some View {
        ZStack {
            LiquidGlassBackdrop(intensity: .settings)

            Form {
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

                // Show auto-detected credential files
                if !providerDetectedCredentials.isEmpty {
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

                if providerID == .openai {
                    codexTelemetrySection
                }

                #if DEBUG
                Section("Debug Info") {
                    Text("Provider: \(providerID.rawValue)")
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

                            Button {
                                showCursorSessionImport = true
                            } label: {
                                HStack {
                                    Image(systemName: "cursorarrow.rays")
                                    Text("Import Cursor web session...")
                                    Spacer()
                                }
                            }
                            .foregroundStyle(accent)

                            if cursorSessionImported {
                                Label("Web session stored", systemImage: "checkmark.circle.fill")
                                    .font(.caption)
                                    .foregroundStyle(.green)
                            }
                        }
                    } else if providerID == .ollama {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Sign into ollama.com in the embedded browser, or paste your `__Secure-session` cookie directly below:")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)

                            Button {
                                showOllamaSessionImport = true
                            } label: {
                                HStack {
                                    Image(systemName: "circle.grid.2x2.fill")
                                    Text("Import Ollama web session...")
                                    Spacer()
                                }
                            }
                            .foregroundStyle(accent)

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

                            Button {
                                showMistralSessionImport = true
                            } label: {
                                HStack {
                                    Image(systemName: "m.square.fill")
                                    Text("Import Mistral web session...")
                                    Spacer()
                                }
                            }
                            .foregroundStyle(accent)

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
                }
                .padding(.horizontal, 12)
                .listRowBackground(Color.white.opacity(0.04))

                if providerID == .mistral || providerID == .deepseek || providerID == .cerebras
                    || providerID == .meta {
                    billingAnchorSection
                }

                Section("Advanced") {
                    if providerID == .claude {
                        Toggle("Recover from Claude Code Keychain", isOn: claudeCodeKeychainFallbackEnabled)
                        Text("Limit Counter uses its own mirrored OAuth token for live quota meters when available. Leave this off to avoid reading Claude Code's keychain item; enable it only to import or recover the mirror from Claude Code.")
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
                        Text("Paste your `__Secure-session` cookie from ollama.com (found in browser DevTools → Storage/Application → Cookies → ollama.com → `__Secure-session`). Limit Counter securely saves it to macOS Keychain and reads your 5-hour and Weekly usage meters from ollama.com/settings.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
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
        }
        .navigationTitle(providerID.displayName)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .onAppear(perform: loadExisting)
        .sheet(isPresented: $showCursorSessionImport) {
            CursorSessionImportView { result in
                switch result {
                case .success(let imported):
                    applyImportedCredential(imported)
                case .failure(let error):
                    importError = error.localizedDescription
                    showImportError = true
                }
            }
        }
        .sheet(isPresented: $showOllamaSessionImport) {
            OllamaSessionImportView { result in
                switch result {
                case .success(let imported):
                    applyImportedCredential(imported)
                    ollamaSessionImported = true
                case .failure(let error):
                    importError = error.localizedDescription
                    showImportError = true
                }
            }
        }
        .sheet(isPresented: $showMistralSessionImport) {
            MistralSessionImportView { result in
                switch result {
                case .success(let imported):
                    applyImportedCredential(imported)
                    mistralSessionImported = true
                case .failure(let error):
                    importError = error.localizedDescription
                    showImportError = true
                }
            }
        }
        .alert("Import Failed", isPresented: $showImportError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(importError ?? "Could not import credentials from file.")
        }
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
                    "Payment threshold (optional)",
                    text: extraFieldBinding(SpendProviderCredentialField.manualPaymentThreshold)
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
                Text("Console spend is optional. If unset, Limit Counter uses threshold−remaining when both are set, otherwise Muse-only from £0/$0. GBP/EUR remaining auto-decrements using Muse USD×FX. Enter the console Spend reading for best Mistral-style parity. Payment threshold is the £15 / $15 auto-pay ceiling; preload minus remaining is credit used.")
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

    private func extraFieldBinding(_ key: String, defaultValue: String = "") -> Binding<String> {
        Binding(
            get: { storedExtraFields[key] ?? defaultValue },
            set: { value in
                if value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    storedExtraFields.removeValue(forKey: key)
                } else {
                    storedExtraFields[key] = value
                }
            }
        )
    }

    private var billingAnchorSignature: String {
        switch providerID {
        case .mistral:
            return [
                storedExtraFields[SpendProviderCredentialField.manualSpent] ?? "",
                storedExtraFields[SpendProviderCredentialField.mistralApiSpent] ?? "",
                storedExtraFields[SpendProviderCredentialField.manualCurrency] ?? "",
                storedExtraFields[SpendProviderCredentialField.manualResetAt] ?? ""
            ].joined(separator: "|")
        case .cerebras:
            return [
                storedExtraFields[SpendProviderCredentialField.manualCurrentBalance] ?? "",
                storedExtraFields[SpendProviderCredentialField.manualCurrency] ?? "",
                accountIdentifier
            ].joined(separator: "|")
        case .deepseek:
            return storedExtraFields[SpendProviderCredentialField.manualTopUpTotal] ?? ""
        case .meta:
            return [
                storedExtraFields[SpendProviderCredentialField.manualSpent] ?? "",
                storedExtraFields[SpendProviderCredentialField.manualCurrency] ?? "",
                storedExtraFields[SpendProviderCredentialField.manualResetAt] ?? ""
            ].joined(separator: "|")
        default:
            return ""
        }
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
        CredentialImportService.showImportPanel(for: providerID) { result in
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
        if detected.providerID == .kimi || detected.providerID == .antigravity
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
        } else {
            KeychainService.shared.save(credential, for: .codexTelemetry)
        }

        loadCodexTelemetryCredential()
        loadedBillingAnchorSignature = billingAnchorSignature
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

    private func loadExisting() {
        if let cred = KeychainService.shared.credential(for: providerID) {
            if providerID == .claude {
                accessToken = cred.customEndpoint ?? ""
                accountIdentifier = cred.accessToken ?? ""
            } else {
                accessToken = cred.accessToken ?? ""
            }
            accountIdentifier = cred.accountIdentifier ?? ""
            storedExtraFields = cred.extraFields ?? [:]

        if providerID == .devin, let restoredEndpoint = restoredDevinEndpoint(from: cred) {
            customEndpoint = restoredEndpoint
        } else {
            customEndpoint = cred.customEndpoint ?? ""
        }

            cursorSessionImported = providerID == .cursor && (
                cred.extraFields?["cursorAuthMode"] == "cookie"
                || (cred.extraFields?["cursorCookieHeader"]?.isEmpty == false)
            )
            ollamaSessionImported = providerID == .ollama && (
                !(cred.accessToken ?? "").isEmpty
                || (cred.extraFields?["ollamaCookie"]?.isEmpty == false)
            )
            mistralSessionImported = providerID == .mistral && (
                cred.extraFields?["mistralCookieHeader"]?.isEmpty == false
                || cred.extraFields?["mistralCookie"]?.isEmpty == false
            )
        } else {
            accessToken = ""
            accountIdentifier = ""
            customEndpoint = ""
            cursorSessionImported = false
            ollamaSessionImported = false
            mistralSessionImported = false
            storedExtraFields = [:]
        }
        // Scan for available credential files
        detectedCredentials = CredentialImportService.detectAvailableCredentials()
        print("[SettingsView] Loaded \(detectedCredentials.count) credentials for \(providerID)")
        for cred in detectedCredentials {
            print("  - \(cred.providerID): \(cred.fileURL.path)")
        }

        loadCodexTelemetryCredential()
        loadedBillingAnchorSignature = billingAnchorSignature
    }

    private func restoredDevinEndpoint(from credential: ProviderCredential) -> String? {
        guard let bookmarkBase64 = credential.extraFields?["bookmarkData"],
              let bookmarkData = Data(base64Encoded: bookmarkBase64) else {
            return nil
        }

        var isStale = false
        do {
            #if os(macOS)
            let options: URL.BookmarkResolutionOptions = .withSecurityScope
            #else
            let options: URL.BookmarkResolutionOptions = []
            #endif
            let resolvedURL = try URL(
                resolvingBookmarkData: bookmarkData,
                options: options,
                bookmarkDataIsStale: &isStale
            )
            if resolvedURL.hasDirectoryPath, let customEndpoint = credential.customEndpoint {
                return customEndpoint
            }
            return resolvedURL.path
        } catch {
            print("[SettingsView] Failed to restore Devin bookmark: \(error)")
            return credential.customEndpoint
        }
    }

    private func saveCredential() {
        let resolvedCustomEndpoint = providerID == .claude
            ? (accessToken.isEmpty ? nil : accessToken)
            : (customEndpoint.isEmpty ? nil : customEndpoint)

        // For local providers, create a security-scoped bookmark if a path is provided
        var extraFields = storedExtraFields
        if billingAnchorSignature != loadedBillingAnchorSignature {
            extraFields[SpendProviderCredentialField.anchorUpdatedAt] = ISO8601DateFormatter().string(from: Date())
        }
        if let path = resolvedCustomEndpoint,
           providerID == .gemini || providerID == .claude || providerID == .codexTelemetry
                || providerID == .chatgpt || providerID == .devin || providerID == .grok
                || providerID == .antigravity || providerID == .mistral || providerID == .cerebras
                || providerID == .meta {
            let url = URL(fileURLWithPath: path)
            if url.isFileURL {
                #if os(macOS)
                do {
                    let bookmarkData = try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
                    extraFields["bookmarkData"] = bookmarkData.base64EncodedString()
                    print("[SettingsView] Created security-scoped bookmark for \(providerID.rawValue)")
                } catch {
                    print("[SettingsView] Failed to create bookmark: \(error)")
                }
                #endif
            }
        }

        let credential = ProviderCredential(
            accessToken: providerID == .claude ? (accountIdentifier.isEmpty ? nil : accountIdentifier) : (accessToken.isEmpty ? nil : accessToken),
            accountIdentifier: accountIdentifier.isEmpty ? nil : accountIdentifier,
            customEndpoint: resolvedCustomEndpoint,
            extraFields: extraFields.isEmpty ? nil : extraFields
        )
        if credential.isEmpty {
            deleteCredential()
            return
        }

        KeychainService.shared.save(credential, for: providerID)
        storedExtraFields = extraFields
        loadedBillingAnchorSignature = billingAnchorSignature
        cursorSessionImported = providerID == .cursor && (
            storedExtraFields["cursorAuthMode"] == "cookie"
            || (storedExtraFields["cursorCookieHeader"]?.isEmpty == false)
        )
        isSaved = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { isSaved = false }
    }

    private func saveCredentialWithExtraFields(_ suppliedExtraFields: [String: String]) {
        var extraFields = suppliedExtraFields
        if billingAnchorSignature != loadedBillingAnchorSignature {
            extraFields[SpendProviderCredentialField.anchorUpdatedAt] = ISO8601DateFormatter().string(from: Date())
        }
        let resolvedCustomEndpoint = providerID == .claude
            ? (accessToken.isEmpty ? nil : accessToken)
            : (customEndpoint.isEmpty ? nil : customEndpoint)
        let credential = ProviderCredential(
            accessToken: providerID == .claude ? (accountIdentifier.isEmpty ? nil : accountIdentifier) : (accessToken.isEmpty ? nil : accessToken),
            accountIdentifier: accountIdentifier.isEmpty ? nil : accountIdentifier,
            customEndpoint: resolvedCustomEndpoint,
            extraFields: extraFields.isEmpty ? nil : extraFields
        )
        if credential.isEmpty {
            deleteCredential()
            return
        }

        KeychainService.shared.save(credential, for: providerID)
        storedExtraFields = extraFields
        loadedBillingAnchorSignature = billingAnchorSignature
        cursorSessionImported = providerID == .cursor && (
            extraFields["cursorAuthMode"] == "cookie"
            || (extraFields["cursorCookieHeader"]?.isEmpty == false)
        )
        isSaved = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { isSaved = false }
    }

    private func applyImportedCredential(_ credential: CredentialImportService.ImportedCredential) {
        if providerID == .cursor {
            applyImportedCursorCredential(credential)
            return
        }

        let preservesExistingFields = providerID == .antigravity || providerID == .mistral
            || providerID == .deepseek || providerID == .cerebras || providerID == .meta
        accessToken = credential.accessToken ?? (preservesExistingFields ? accessToken : "")
        accountIdentifier = credential.accountIdentifier ?? (preservesExistingFields ? accountIdentifier : "")
        customEndpoint = credential.customEndpoint ?? (preservesExistingFields ? customEndpoint : "")

        var extraFields = preservesExistingFields ? storedExtraFields : [:]
        for (key, value) in credential.extraFields ?? [:] {
            extraFields[key] = value
        }
        if providerID == .gemini,
           let preservedPreset = storedExtraFields[GeminiLimitPreset.storageKey] {
            extraFields[GeminiLimitPreset.storageKey] = preservedPreset
        }

        if let bookmarkData = credential.bookmarkData {
            let bookmarkBase64 = bookmarkData.base64EncodedString()
            print("[SettingsView] Got bookmark data (length: \(bookmarkData.count), base64 length: \(bookmarkBase64.count))")
            extraFields["bookmarkData"] = bookmarkBase64
            saveCredentialWithExtraFields(extraFields)
        } else {
            saveCredentialWithExtraFields(extraFields)
        }
    }

    private func applyImportedCursorCredential(_ credential: CredentialImportService.ImportedCredential) {
        let existing = KeychainService.shared.credential(for: .cursor)

        let resolvedAccessToken = credential.accessToken
            ?? (accessToken.isEmpty ? existing?.accessToken : accessToken)
        let resolvedAccountIdentifier = credential.accountIdentifier
            ?? (accountIdentifier.isEmpty ? existing?.accountIdentifier : accountIdentifier)
        let resolvedCustomEndpoint = credential.customEndpoint
            ?? (customEndpoint.isEmpty ? existing?.customEndpoint : customEndpoint)

        accessToken = resolvedAccessToken ?? ""
        accountIdentifier = resolvedAccountIdentifier ?? ""
        customEndpoint = resolvedCustomEndpoint ?? ""

        var extraFields = existing?.extraFields ?? storedExtraFields
        for (key, value) in credential.extraFields ?? [:] {
            extraFields[key] = value
        }
        if let bookmarkData = credential.bookmarkData {
            let bookmarkBase64 = bookmarkData.base64EncodedString()
            print("[SettingsView] Got Cursor bookmark data (length: \(bookmarkData.count), base64 length: \(bookmarkBase64.count))")
            extraFields["bookmarkData"] = bookmarkBase64
        }

        let hasCookie = extraFields["cursorCookieHeader"]?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        let hasLocalState = !(customEndpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            || extraFields["bookmarkData"]?.isEmpty == false
        if hasCookie {
            extraFields["cursorAuthMode"] = "cookie"
        } else if hasLocalState {
            extraFields["cursorAuthMode"] = "localState"
        }

        saveCredentialWithExtraFields(extraFields)
    }

    private func deleteCredential() {
        if providerID == .cursor {
            CursorSessionImportModel.clearStoredWebsiteData()
        }
        KeychainService.shared.delete(for: providerID)
        accessToken = ""
        accountIdentifier = ""
        customEndpoint = ""
        cursorSessionImported = false
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

#if os(macOS)
final class ProviderConfigurationWindowManager: NSObject {
    static let shared = ProviderConfigurationWindowManager()

    private var windows: [ProviderID: NSWindow] = [:]

    func show(providerID: ProviderID) {
        if let existing = windows[providerID] {
            existing.makeKeyAndOrderFront(nil)
            NSApplication.shared.activate(ignoringOtherApps: true)
            return
        }

        let hostingController = NSHostingController(
            rootView: ProviderCredentialView(providerID: providerID)
                .frame(minWidth: 680, minHeight: 720)
        )

        let window = NSWindow(contentViewController: hostingController)
        window.title = "\(providerID.displayName) Settings"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.isOpaque = false
        window.backgroundColor = .clear
        window.titlebarAppearsTransparent = true
        window.toolbarStyle = .unifiedCompact
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.minSize = NSSize(width: 680, height: 720)
        window.setFrameAutosaveName("ProviderConfig-\(providerID.rawValue)")
        window.delegate = self

        windows[providerID] = window
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
}

extension ProviderConfigurationWindowManager: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        if let providerID = windows.first(where: { $0.value === window })?.key {
            windows.removeValue(forKey: providerID)
        }
    }
}
#endif
