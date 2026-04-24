import SwiftUI
#if os(macOS)
import AppKit
import UniformTypeIdentifiers
#endif

struct SettingsView: View {
    @StateObject private var visibilityStore = ProviderVisibilityStore.shared
    @AppStorage("dashboardRefreshIntervalSeconds") private var dashboardRefreshIntervalSeconds: Int = 60
    @State private var cloudSyncDebug = CloudSyncDebugInfo.placeholder
    @State private var isRefreshingCloudSync = false
    @State private var isRepairingSubscriptions = false
    @State private var cloudSyncActionMessage: String?
    @State private var showRawDataDebug = false

    var body: some View {
        NavigationStack {
            ZStack {
                LiquidGlassBackdrop(style: .ultraThinMaterial)

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
                        ForEach(ProviderID.userFacingCases) { providerID in
                            ProviderSettingsRow(
                                providerID: providerID,
                                onConfigure: { openProviderConfiguration(providerID) },
                                isVisible: visibilityStore.binding(for: providerID)
                            )
                            .listRowBackground(Color.white.opacity(0.03))
                        }
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
                    InfoRow(label: "Plan", value: snapshot.planName ?? "N/A")
                    InfoRow(label: "Fetch State", value: snapshot.fetchState.rawValue)
                    InfoRow(label: "Fetched At", value: formatDate(snapshot.fetchedAt))
                    InfoRow(label: "Windows", value: "\(snapshot.windows.count)")
                    InfoRow(label: "Stats", value: "\(snapshot.stats.count)")
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
        if providerID == .windsurf {
            let stateDB = home.appendingPathComponent("Library/Application Support/Windsurf/User/globalStorage/state.vscdb")
            let backupDB = home.appendingPathComponent("Library/Application Support/Windsurf/User/globalStorage/state.vscdb.backup")
            return FileManager.default.isReadableFile(atPath: stateDB.path)
                || FileManager.default.isReadableFile(atPath: backupDB.path)
        }
        if providerID == .gemini {
            let geminiRoot = home.appendingPathComponent(".gemini")
            let tmpDir = geminiRoot.appendingPathComponent("tmp")
            return FileManager.default.fileExists(atPath: geminiRoot.path)
                && FileManager.default.fileExists(atPath: tmpDir.path)
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
    @State private var storedExtraFields: [String: String] = [:]
    @State private var codexTelemetryEndpoint = ""
    @State private var codexTelemetryHasCredential = false
    @State private var codexTelemetrySaved = false

    private var accent: Color { Color(hex: providerID.accentColorHex) }
    private var providerDetectedCredentials: [CredentialImportService.DetectedCredential] {
        detectedCredentials.filter { $0.providerID == providerID }
    }
    private var codexTelemetryDetectedCredentials: [CredentialImportService.DetectedCredential] {
        guard providerID == .openai else { return [] }
        return detectedCredentials.filter { $0.providerID == .codexTelemetry }
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

    var body: some View {
        ZStack {
            LiquidGlassBackdrop(style: .ultraThinMaterial)

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
                Section("Import from File") {
                    Button(action: importFromFile) {
                        HStack {
                            Image(systemName: "folder.badge.person.crop")
                            Text("Select credential file...")
                            Spacer()
                        }
                    }
                    .foregroundStyle(accent)

                    Text("Import credentials from a JSON or text file you exported from the provider.")
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
                    } else if providerID == .claude {
                        TextField(providerID.primaryCredentialLabel, text: $accessToken)
                            .autocorrectionDisabled()
                        #if os(iOS)
                            .textInputAutocapitalization(.never)
                        #endif
                    } else if providerID == .codexTelemetry || providerID == .chatgpt || providerID == .gemini {
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
                        TextField(secondaryCredentialLabel, text: $accountIdentifier)
                            .autocorrectionDisabled()
                        #if os(iOS)
                            .textInputAutocapitalization(.never)
                        #endif
                    }
                }
                .padding(.horizontal, 12)
                .listRowBackground(Color.white.opacity(0.04))

                Section("Advanced") {
                    if providerID == .claude {
                        Text("This provider reads the local `~/.claude` workspace folder. Leave the field above pointed at that folder, or choose a different Claude Code root if you keep it elsewhere.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else if providerID == .chatgpt {
                        Text("Use the import button to grant access to `~/Library/Application Support/com.openai.chat`. The app reads local ChatGPT desktop cache activity like recent chats, drafts, and projects.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else if providerID == .codexTelemetry {
                        Text("Use the import button to grant access to `~/.codex` or a Codex log subfolder. The app reads the local SQLite log store and text logs, then turns them into activity counts.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else if providerID == .cursor {
                        Text("Use the in-app Cursor session import flow above for live usage meters. You can still import `state.vscdb` with the file picker for cached account metadata and local AI activity stats.")
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
        .alert("Import Failed", isPresented: $showImportError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(importError ?? "Could not import credentials from file.")
        }
    }

    @ViewBuilder
    private var codexTelemetrySection: some View {
        Section("Codex Local Activity") {
            VStack(alignment: .leading, spacing: 6) {
                Text("Local Codex logs supply the expanded card details and activity heatmap entries for Codex.")
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
        do {
            let credential = try CredentialImportService.importFromURL(detected.fileURL, for: .codexTelemetry)
            saveCodexTelemetryCredential(credential)
        } catch {
            importError = (error as? CredentialImportService.ImportError)?.errorDescription
                ?? error.localizedDescription
            showImportError = true
        }
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
                accessToken = cred.customEndpoint ?? cred.accessToken ?? ""
            } else {
                accessToken = cred.accessToken ?? ""
            }
            accountIdentifier = cred.accountIdentifier ?? ""
            storedExtraFields = cred.extraFields ?? [:]

        if providerID == .windsurf, let restoredEndpoint = restoredWindsurfEndpoint(from: cred) {
            customEndpoint = restoredEndpoint
        } else {
            customEndpoint = cred.customEndpoint ?? ""
        }

            cursorSessionImported = providerID == .cursor && (
                cred.extraFields?["cursorAuthMode"] == "cookie"
                || (cred.extraFields?["cursorCookieHeader"]?.isEmpty == false)
            )
        } else {
            accessToken = ""
            accountIdentifier = ""
            customEndpoint = ""
            cursorSessionImported = false
            storedExtraFields = [:]
        }
        // Scan for available credential files
        detectedCredentials = CredentialImportService.detectAvailableCredentials()
        print("[SettingsView] Loaded \(detectedCredentials.count) credentials for \(providerID)")
        for cred in detectedCredentials {
            print("  - \(cred.providerID): \(cred.fileURL.path)")
        }

        loadCodexTelemetryCredential()
    }

    private func restoredWindsurfEndpoint(from credential: ProviderCredential) -> String? {
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
            print("[SettingsView] Failed to restore Windsurf bookmark: \(error)")
            return credential.customEndpoint
        }
    }

    private func saveCredential() {
        let resolvedCustomEndpoint = providerID == .claude
            ? (accessToken.isEmpty ? nil : accessToken)
            : (customEndpoint.isEmpty ? nil : customEndpoint)

        // For local providers, create a security-scoped bookmark if a path is provided
        var extraFields = storedExtraFields
        if let path = resolvedCustomEndpoint,
           providerID == .gemini || providerID == .claude || providerID == .codexTelemetry || providerID == .chatgpt || providerID == .windsurf {
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
            accessToken: providerID == .claude ? nil : (accessToken.isEmpty ? nil : accessToken),
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
        cursorSessionImported = providerID == .cursor && (
            storedExtraFields["cursorAuthMode"] == "cookie"
            || (storedExtraFields["cursorCookieHeader"]?.isEmpty == false)
        )
        isSaved = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { isSaved = false }
    }

    private func saveCredentialWithExtraFields(_ extraFields: [String: String]) {
        let resolvedCustomEndpoint = providerID == .claude
            ? (accessToken.isEmpty ? nil : accessToken)
            : (customEndpoint.isEmpty ? nil : customEndpoint)
        let credential = ProviderCredential(
            accessToken: providerID == .claude ? nil : (accessToken.isEmpty ? nil : accessToken),
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
        cursorSessionImported = providerID == .cursor && (
            extraFields["cursorAuthMode"] == "cookie"
            || (extraFields["cursorCookieHeader"]?.isEmpty == false)
        )
        isSaved = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { isSaved = false }
    }

    private func applyImportedCredential(_ credential: CredentialImportService.ImportedCredential) {
        accessToken = credential.accessToken ?? ""
        accountIdentifier = credential.accountIdentifier ?? ""
        customEndpoint = credential.customEndpoint ?? ""

        var extraFields = credential.extraFields ?? [:]
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

    private func deleteCredential() {
        KeychainService.shared.delete(for: providerID)
        accessToken = ""
        accountIdentifier = ""
        customEndpoint = ""
        cursorSessionImported = false
        storedExtraFields = [:]
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
