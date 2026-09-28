import SwiftUI

#if os(macOS)

/// The right-hand pane: one decision at a time, centred, with generous air.
/// It never shows a form dump — anything dense lives behind `Advanced`.
struct ProviderSetupCanvas: View {
    @ObservedObject var model: ProviderSetupModel
    var onRefresh: () -> Void
    var lastSyncDate: Date?

    var body: some View {
        ZStack {
            switch model.page {
            case .overview:
                ProviderSetupOverviewPage(
                    model: model,
                    onRefresh: onRefresh,
                    lastSyncDate: lastSyncDate
                )
            case .provider(let providerID):
                ProviderSetupProviderPage(
                    model: model,
                    providerID: providerID,
                    onConfigure: { model.page = .credential(.primary(providerID)) }
                )
                // A stable identity per provider, so switching pages does not
                // re-run onAppear work against the wrong provider.
                .id(providerID)
            case .credential(let account):
                // The existing configuration form, hosted as a page. It used to
                // get an `NSWindow` of its own, one per provider, pinned above
                // every other app.
                ProviderCredentialView(account: account)
                    .id(account)
                    .onDisappear { model.refreshHealth(for: account.providerID) }
            case .preferences:
                ProviderSetupPreferencesPage(model: model)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.easeInOut(duration: 0.16), value: model.page)
    }
}

// MARK: - Overview

struct ProviderSetupOverviewPage: View {
    @ObservedObject var model: ProviderSetupModel
    var onRefresh: () -> Void
    var lastSyncDate: Date?

    private var attention: [ProviderID] { model.attentionProviderIDs }
    private var notSetUp: [ProviderID] { model.notSetUpProviderIDs }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if attention.isEmpty && notSetUp.isEmpty {
                    allClear
                } else {
                    header

                    ForEach(attention, id: \.self) { providerID in
                        attentionCard(providerID)
                    }

                    if !notSetUp.isEmpty {
                        if !attention.isEmpty {
                            Divider().opacity(0.16)
                        }
                        moreToTrack
                    }
                }
            }
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollContentBackground(.hidden)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Setup")
                .font(.title2.weight(.semibold))
            Text(statusLine)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private var statusLine: String {
        var parts: [String] = ["\(model.connectedProviderIDs.count) connected"]
        if !attention.isEmpty { parts.append("\(attention.count) need attention") }
        if !notSetUp.isEmpty { parts.append("\(notSetUp.count) not set up") }
        return parts.joined(separator: " · ")
    }

    /// The state most people see most of the time. It should feel like an empty
    /// inbox, not a dashboard.
    private var allClear: some View {
        VStack(spacing: 10) {
            Spacer(minLength: 60)
            Image(systemName: "checkmark.circle")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.secondary)
            Text("Everything's connected.")
                .font(.title3.weight(.medium))
            if let lastSyncDate {
                Text("Last checked \(relative(lastSyncDate)).")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Button("Check now", action: onRefresh)
                .buttonStyle(.borderless)
                .font(.subheadline)
                .padding(.top, 4)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
    }

    private func attentionCard(_ providerID: ProviderID) -> some View {
        let accent = Color(hex: providerID.accentColorHex)
        return GlassCardContainer(style: .panel, accent: accent, cornerRadius: 16) {
            HStack(alignment: .top, spacing: 12) {
                ProviderBrandIconView(providerID: providerID, size: 24)
                VStack(alignment: .leading, spacing: 4) {
                    Text(providerID.displayName)
                        .font(.subheadline.weight(.semibold))
                    if case .needsAttention(let message) = model.health(for: providerID) {
                        Text(message)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 12)
                Button("Fix") { model.page = .provider(providerID) }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .tint(accent)
            }
            .padding(6)
        }
    }

    private var moreToTrack: some View {
        HStack {
            Text("\(notSetUp.count) more \(notSetUp.count == 1 ? "tool" : "tools") can be tracked.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer(minLength: 12)
            if let first = notSetUp.first {
                Button("Set them up") { model.page = .provider(first) }
                    .buttonStyle(.borderless)
                    .font(.subheadline)
            }
        }
    }

    private func relative(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

// MARK: - Provider page

/// A configured provider answers one question — "is it working?" — in three
/// lines. Everything else is reachable but invisible until asked for.
struct ProviderSetupProviderPage: View {
    @ObservedObject var model: ProviderSetupModel
    let providerID: ProviderID
    var onConfigure: () -> Void

    @State private var showAddAccount = false
    @State private var accountPendingRemoval: ProviderAccountKey?
    @State private var showRemoveProvider = false

    private var accent: Color { Color(hex: providerID.accentColorHex) }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 0) {
                    Spacer(minLength: 24)

                    ProviderBrandIconView(providerID: providerID, size: 52)
                        .padding(.bottom, 24)

                    Text(headline)
                        .font(.title2.weight(.semibold))
                        .multilineTextAlignment(.center)
                        .padding(.bottom, 16)

                    Text(bodyCopy)
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 380)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.bottom, 24)

                    Button(primaryLabel, action: onConfigure)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .tint(accent)

                    if let banner = model.banner, bannerBelongsHere(banner) {
                        bannerView(banner)
                            .padding(.top, 16)
                    }

                    if providerID.supportsAdditionalAccounts {
                        accountsBlock
                            .padding(.top, 32)
                    }

                    Spacer(minLength: 24)
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 28)
            }
            .scrollContentBackground(.hidden)

            Divider().opacity(0.16)

            HStack {
                if model.health(for: providerID).isConnected {
                    Button("Reconnect", action: onConfigure)
                        .buttonStyle(.plain)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                // Offered in every state: a provider that needs attention is
                // the one most likely to be unwanted.
                Button("Remove…") { showRemoveProvider = true }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .confirmationDialog(
            "Remove \(providerID.displayName)?",
            isPresented: $showRemoveProvider,
            titleVisibility: .visible
        ) {
            Button("Remove", role: .destructive) { model.removeProvider(providerID) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Its stored credentials, extra accounts and browser sign-in on this Mac are deleted, and it leaves the dashboard. Add it back any time from Add provider.")
        }
    }

    // MARK: Additional accounts

    /// The provider's other accounts, one row each, and the way to add one.
    /// Tracking only: nothing here switches which account a CLI uses.
    private var accountsBlock: some View {
        let records = model.accounts(for: providerID)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Text("ACCOUNTS")
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.6)
                    .foregroundStyle(.secondary)
                Text("\(records.count + 1)")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.tertiary)
                Spacer(minLength: 0)
                Button {
                    showAddAccount = true
                } label: {
                    Label("Add account", systemImage: "plus")
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.borderless)
                .disabled(!model.canAddAccount(for: providerID))
                .popover(isPresented: $showAddAccount, arrowEdge: .bottom) {
                    AddAccountPopover(model: model, providerID: providerID, isPresented: $showAddAccount)
                }
            }

            Text(ProviderSetupPolicy.additionalAccountHint(for: providerID))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 4) {
                accountRow(
                    label: "Primary",
                    health: model.health(for: providerID),
                    open: onConfigure,
                    remove: nil
                )
                ForEach(records) { record in
                    accountRow(
                        label: record.label,
                        health: model.accountHealth(for: record.key),
                        open: { model.page = .credential(record.key) },
                        remove: { accountPendingRemoval = record.key }
                    )
                }
            }
        }
        .frame(maxWidth: 420)
        .confirmationDialog(
            "Remove \(pendingRemovalLabel)?",
            isPresented: Binding(
                get: { accountPendingRemoval != nil },
                set: { if !$0 { accountPendingRemoval = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Remove account", role: .destructive) {
                if let key = accountPendingRemoval {
                    model.removeAccount(key)
                }
                accountPendingRemoval = nil
            }
            Button("Cancel", role: .cancel) { accountPendingRemoval = nil }
        } message: {
            Text("Its stored credential and cached readings on this Mac are deleted. The account itself is untouched.")
        }
    }

    private var pendingRemovalLabel: String {
        accountPendingRemoval.flatMap { model.accountLabel(for: $0) } ?? "account"
    }

    private func accountRow(
        label: String,
        health: ProviderSetupHealth,
        open: @escaping () -> Void,
        remove: (() -> Void)?
    ) -> some View {
        HStack(spacing: 8) {
            Group {
                switch health {
                case .connected, .autoDetected:
                    Circle().fill(accent).frame(width: 8, height: 8)
                case .needsAttention:
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(Color(hex: "#F59E0B"))
                case .notSetUp:
                    Circle().strokeBorder(Color.secondary.opacity(0.6), lineWidth: 1.4).frame(width: 8, height: 8)
                }
            }
            .frame(width: 14)

            Text(label)
                .font(.subheadline)
                .lineLimit(1)

            Text(health.word)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Spacer(minLength: 8)

            Button(health.isConnected || health.isAttention ? "Open" : "Set up", action: open)
                .buttonStyle(.borderless)
                .font(.system(size: 11, weight: .medium))

            if let remove {
                Button(action: remove) {
                    Image(systemName: "minus.circle")
                        .font(.system(size: 12))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Remove this account from Limit Counter")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.white.opacity(0.05))
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label), \(health.word)")
    }

    private var headline: String {
        switch model.health(for: providerID) {
        case .connected:
            return "\(providerID.displayName) is connected"
        case .autoDetected:
            return "\(providerID.displayName) is on this Mac"
        case .needsAttention:
            return "\(providerID.displayName) needs attention"
        case .notSetUp:
            return "Set up \(providerID.displayName)"
        }
    }

    private var bodyCopy: String {
        switch model.health(for: providerID) {
        case .connected:
            return "Limit Counter is reading your usage. Nothing else is needed."
        case .autoDetected:
            return "Limit Counter can read your usage straight from files already on this Mac. Nothing leaves your Mac."
        case .needsAttention(let message):
            return message
        case .notSetUp:
            return ProviderSetupPolicy.importCopy(for: providerID).helpText
        }
    }

    private var primaryLabel: String {
        switch model.health(for: providerID) {
        case .connected: return "Open settings"
        case .autoDetected: return "Allow access"
        case .needsAttention: return "Reconnect"
        case .notSetUp: return "Set up"
        }
    }

    private func bannerBelongsHere(_ banner: ProviderSetupBanner) -> Bool {
        switch banner {
        case .saved(let id): return id == providerID
        case .error(let id, _): return id == nil || id == providerID
        }
    }

    @ViewBuilder
    private func bannerView(_ banner: ProviderSetupBanner) -> some View {
        switch banner {
        case .saved:
            Label("Saved", systemImage: "checkmark.circle.fill")
                .font(.footnote)
                .foregroundStyle(.green)
        case .error(_, let message):
            Text(message)
                .font(.footnote)
                .foregroundStyle(Color(hex: "#F87171"))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Names the new account and opens its form. The label is presentation only —
/// see `ProviderAccountKey` — so it can be changed later without consequence.
private struct AddAccountPopover: View {
    @ObservedObject var model: ProviderSetupModel
    let providerID: ProviderID
    @Binding var isPresented: Bool
    @State private var label = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Add \(providerID.displayName) account")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            TextField("Label, e.g. Work", text: $label)
                .textFieldStyle(.roundedBorder)
                .onSubmit(add)
            Text("Use a name, not an email: the label appears on the card, in the menu bar and in the widget.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel") { isPresented = false }
                    .keyboardShortcut(.cancelAction)
                Button("Add", action: add)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(14)
        .frame(width: 260)
    }

    private func add() {
        model.addAccount(for: providerID, label: label)
        isPresented = false
    }
}

// MARK: - Preferences

/// Everything that is not a provider: refresh cadence, budgets, iCloud sync,
/// the shared TaskWraith grant and the raw-data inspector. It used to have a
/// window of its own.
struct ProviderSetupPreferencesPage: View {
    @ObservedObject var model: ProviderSetupModel

    var body: some View {
        SettingsView(isEmbedded: true)
    }
}

#endif
