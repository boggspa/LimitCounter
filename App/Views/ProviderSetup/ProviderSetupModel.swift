import Combine
import Foundation

#if os(macOS)

/// Which page the setup sheet's canvas is showing.
enum ProviderSetupPage: Hashable {
    case overview
    case provider(ProviderID)
    /// One account's full configuration form, hosted as a page in this sheet
    /// rather than in a window of its own. The primary account's key is the
    /// provider itself.
    case credential(ProviderAccountKey)
    case preferences
}

/// How a provider row reads in the rail, and what its page opens on.
enum ProviderSetupHealth: Hashable {
    /// Configured and last sync was fine.
    case connected
    /// Configured, but the last sync reported something the user must fix.
    case needsAttention(String)
    /// No credential and nothing auto-discoverable.
    case notSetUp
    /// No credential, but a local source is already readable.
    case autoDetected

    var isAttention: Bool {
        if case .needsAttention = self { return true }
        return false
    }

    /// Auto-detected providers count as set up: nothing is asked of the user.
    var isConnected: Bool {
        switch self {
        case .connected, .autoDetected: return true
        case .needsAttention, .notSetUp: return false
        }
    }

    /// The rail's colour-independent word, also used as the VoiceOver label.
    var word: String {
        switch self {
        case .connected: return "Connected"
        case .autoDetected: return "Found on this Mac"
        case .needsAttention: return "Needs attention"
        case .notSetUp: return "Not set up"
        }
    }
}

/// A short, transient result of the last action, rendered inline rather than as
/// a modal alert — an alert over a sheet is another window, which is the thing
/// this redesign is removing.
enum ProviderSetupBanner: Equatable {
    case saved(ProviderID)
    case error(providerID: ProviderID?, message: String)
}

/// One sheet session's state, owned by the dashboard and shared by every page.
///
/// This exists so the per-provider pages hold no credential state of their own.
/// The old design gave each provider window its own copy of 25 `@State`
/// variables, re-read the Keychain on every open, and re-walked the filesystem
/// on every render pass of every row.
@MainActor
final class ProviderSetupModel: ObservableObject {

    // MARK: Navigation

    @Published var page: ProviderSetupPage = .overview

    /// The provider whose page is showing, if any. Kept separate from `page` so
    /// a full-canvas step (a browser sign-in) can take over without losing the
    /// rail's selection.
    var selectedProviderID: ProviderID? {
        switch page {
        case .provider(let id): return id
        case .credential(let account): return account.providerID
        case .overview, .preferences: return nil
        }
    }

    // MARK: State

    @Published private(set) var health: [ProviderID: ProviderSetupHealth] = [:]
    /// Secondary accounts only; the primary account's health is `health`.
    @Published private(set) var accountHealth: [ProviderAccountKey: ProviderSetupHealth] = [:]
    @Published private(set) var detected: [CredentialImportService.DetectedCredential] = []
    @Published var banner: ProviderSetupBanner?

    /// In-flight edits, hydrated lazily and kept for the sheet's lifetime so
    /// switching pages does not silently discard them.
    @Published private(set) var drafts: [ProviderID: ProviderSetupPolicy.Draft] = [:]
    private var savedDrafts: [ProviderID: ProviderSetupPolicy.Draft] = [:]

    private let store: ProviderCredentialStoring
    private let visibility: ProviderVisibilityStore
    private let order: ProviderCardOrderStore
    private let accounts: ProviderAccountRegistry
    private let home: URL
    private var bannerDismissal: Task<Void, Never>?
    /// Held for the sheet's lifetime. Recomputing one provider's health must not
    /// silently drop the sync error that made it need attention in the first
    /// place — saving a credential does not prove the next fetch will parse.
    private var syncErrors: [ProviderID: String] = [:]

    init(
        store: ProviderCredentialStoring = KeychainService.shared,
        visibility: ProviderVisibilityStore = .shared,
        order: ProviderCardOrderStore = .shared,
        accounts: ProviderAccountRegistry = .shared,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        self.store = store
        self.visibility = visibility
        self.order = order
        self.accounts = accounts
        self.home = home
    }

    // MARK: Sheet lifecycle

    /// Called once when the sheet opens. Everything expensive happens here
    /// rather than per render.
    func load(syncErrors: [ProviderID: String] = [:]) {
        // Always open on Overview: the model outlives a single sheet session, so
        // without this the sheet reopens on whatever page was last visited.
        page = .overview
        clearBanner()
        self.syncErrors = syncErrors
        detected = CredentialImportService.detectAvailableCredentials()
        var computed: [ProviderID: ProviderSetupHealth] = [:]
        var computedAccounts: [ProviderAccountKey: ProviderSetupHealth] = [:]
        for providerID in enabledProviderIDs {
            computed[providerID] = resolvedHealth(for: providerID)
            for record in accounts.accounts(for: providerID) {
                computedAccounts[record.key] = resolvedAccountHealth(for: record.key)
            }
        }
        health = computed
        accountHealth = computedAccounts
    }

    /// Recomputes one provider, and every account under it, after a save,
    /// delete or import.
    func refreshHealth(for providerID: ProviderID) {
        health[providerID] = resolvedHealth(for: providerID)
        for record in accounts.accounts(for: providerID) {
            accountHealth[record.key] = resolvedAccountHealth(for: record.key)
        }
    }

    // MARK: Additional accounts

    func accounts(for providerID: ProviderID) -> [ProviderAccountRecord] {
        accounts.accounts(for: providerID)
    }

    func canAddAccount(for providerID: ProviderID) -> Bool {
        accounts.canAddAccount(for: providerID)
    }

    func accountHealth(for key: ProviderAccountKey) -> ProviderSetupHealth {
        accountHealth[key] ?? .notSetUp
    }

    func accountLabel(for key: ProviderAccountKey) -> String? {
        accounts.label(for: key)
    }

    /// Registers the account and opens its form: an account with nothing
    /// behind it yet is not worth a row of its own until it has been set up.
    @discardableResult
    func addAccount(for providerID: ProviderID, label: String) -> ProviderAccountKey? {
        guard let record = accounts.addAccount(for: providerID, label: label) else { return nil }
        accountHealth[record.key] = .notSetUp
        page = .credential(record.key)
        return record.key
    }

    func renameAccount(_ key: ProviderAccountKey, to label: String) {
        accounts.rename(key, to: label)
    }

    /// Removes the account's credential, its cached readings and its roster
    /// entry, in that order, so a crash midway leaves a labelled account with
    /// no secret rather than an orphaned secret.
    func removeAccount(_ key: ProviderAccountKey) {
        store.delete(for: key)
        QuotaSnapshotStore.shared.clear(account: key)
        accounts.remove(key)
        accountHealth.removeValue(forKey: key)
        if case .credential(let current) = page, current == key {
            page = .provider(key.providerID)
        }
        refreshHealth(for: key.providerID)
    }

    /// A secondary account is configured or it is not; the coordinator files
    /// its sync errors under the provider with the account's label in front.
    private func resolvedAccountHealth(for key: ProviderAccountKey) -> ProviderSetupHealth {
        guard store.hasCredential(for: key) else { return .notSetUp }
        if let label = accounts.label(for: key),
           let line = syncErrors[key.providerID]?
                .components(separatedBy: "\n")
                .first(where: { $0.hasPrefix("\(label): ") }) {
            let message = String(line.dropFirst(label.count + 2))
            if !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return .needsAttention(message)
            }
        }
        return .connected
    }

    /// Clears the stored error for one provider, for the cases where the user
    /// has demonstrably fixed it — a fresh credential or a successful import.
    /// A plain visit to the form is not one of those.
    private func clearSyncError(for providerID: ProviderID) {
        syncErrors.removeValue(forKey: providerID)
    }

    /// Re-scans for local credential files. Only worth doing after an import,
    /// not on every page change.
    func rescanDetectedCredentials() {
        detected = CredentialImportService.detectAvailableCredentials()
    }

    private func resolvedHealth(for providerID: ProviderID) -> ProviderSetupHealth {
        let hasCredential = store.hasCredential(for: providerID)
        let canAutoDiscover = ProviderSetupPolicy.canAutoDiscover(providerID, home: home)

        // A sync error only means "needs attention" once the provider is set up.
        // Before that it is just the provider not being configured yet.
        if hasCredential || canAutoDiscover,
           let message = syncErrors[providerID],
           !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .needsAttention(message)
        }

        switch ProviderSetupPolicy.status(hasCredential: hasCredential, canAutoDiscover: canAutoDiscover) {
        case .configured: return .connected
        case .autoDiscoverable: return .autoDetected
        case .needsSetup: return .notSetUp
        }
    }

    // MARK: Rail contents

    /// Disabled providers are absent from setup entirely — a greyed row is
    /// still a row you have to skip past.
    var enabledProviderIDs: [ProviderID] {
        visibility.allVisibleProviderIDs
    }

    var disabledProviderIDs: [ProviderID] {
        let enabled = Set(enabledProviderIDs)
        return ProviderID.userFacingCases.filter { !enabled.contains($0) }
    }

    func health(for providerID: ProviderID) -> ProviderSetupHealth {
        health[providerID] ?? .notSetUp
    }

    /// Attention first — the thing that just broke is what they came for.
    var attentionProviderIDs: [ProviderID] {
        dashboardOrdered(enabledProviderIDs.filter { health(for: $0).isAttention })
    }

    /// Mirrors the dashboard order the user already arranged, so the rail needs
    /// no second mental model.
    var connectedProviderIDs: [ProviderID] {
        dashboardOrdered(
            enabledProviderIDs.filter { health(for: $0).isConnected && !health(for: $0).isAttention }
        )
    }

    var notSetUpProviderIDs: [ProviderID] {
        dashboardOrdered(enabledProviderIDs.filter { health(for: $0) == .notSetUp })
    }

    private func dashboardOrdered(_ providerIDs: [ProviderID]) -> [ProviderID] {
        providerIDs.sorted { order.rank(for: $0) < order.rank(for: $1) }
    }

    // MARK: Enabling and disabling

    func enable(_ providerID: ProviderID) {
        visibility.setVisible(providerID, true)
        refreshHealth(for: providerID)
        page = .provider(providerID)
    }

    func disable(_ providerID: ProviderID) {
        visibility.setVisible(providerID, false)
        health.removeValue(forKey: providerID)
        drafts.removeValue(forKey: providerID)
        savedDrafts.removeValue(forKey: providerID)
        if selectedProviderID == providerID {
            page = .overview
        }
    }

    // MARK: Drafts

    /// Hydrated on first use and then kept, so moving between pages preserves
    /// unsaved edits.
    func draft(for providerID: ProviderID) -> ProviderSetupPolicy.Draft {
        if let existing = drafts[providerID] { return existing }
        let fresh = ProviderSetupPolicy.draft(
            from: store.credential(for: providerID),
            providerID: providerID
        )
        drafts[providerID] = fresh
        savedDrafts[providerID] = fresh
        return fresh
    }

    func updateDraft(for providerID: ProviderID, _ mutate: (inout ProviderSetupPolicy.Draft) -> Void) {
        var draft = draft(for: providerID)
        mutate(&draft)
        drafts[providerID] = draft
    }

    func isDirty(_ providerID: ProviderID) -> Bool {
        guard let current = drafts[providerID] else { return false }
        return current != savedDrafts[providerID]
    }

    var hasUnsavedEdits: Bool {
        drafts.keys.contains { isDirty($0) }
    }

    // MARK: Persisting

    /// The one save path. `bookmarkFactory` performs the security-scoped
    /// bookmark; it is injected so the model stays testable and so the real one
    /// runs while the caller still holds the Powerbox grant.
    @discardableResult
    func save(
        _ providerID: ProviderID,
        extraFieldsOverride: [String: String]? = nil,
        now: Date = Date(),
        bookmarkFactory: (URL) -> Data? = ProviderSetupModel.liveBookmarkFactory
    ) -> Bool {
        let draft = draft(for: providerID)
        var input = ProviderSetupPolicy.saveInput(
            for: draft,
            providerID: providerID,
            now: now,
            suppliedExtraFields: extraFieldsOverride
        )

        if let bookmarkURL = input.bookmarkSourceURL, let data = bookmarkFactory(bookmarkURL) {
            input.extraFields["bookmarkData"] = data.base64EncodedString()
        }

        let credential = ProviderSetupPolicy.credential(
            from: draft,
            providerID: providerID,
            extraFields: input.extraFields
        )
        if credential.isEmpty {
            delete(providerID)
            return true
        }

        guard store.save(credential, for: providerID) else {
            show(
                .error(
                    providerID: providerID,
                    message: "Limit Counter could not save \(providerID.displayName) credentials to Keychain. Unlock the login keychain, check the permission prompt, and try again."
                )
            )
            return false
        }

        var saved = draft
        saved.extraFields = input.extraFields
        saved.loadedBillingAnchorSignature = ProviderSetupPolicy.billingAnchorSignature(
            saved,
            providerID: providerID
        )
        drafts[providerID] = saved
        savedDrafts[providerID] = saved
        // The user has supplied a new credential, so the previous failure no
        // longer describes the current setup. The next sync re-adds it if the
        // provider is still unhappy.
        clearSyncError(for: providerID)
        refreshHealth(for: providerID)
        show(.saved(providerID))
        return true
    }

    func delete(_ providerID: ProviderID) {
        clearStoredWebsiteData(for: providerID)
        store.delete(for: providerID)
        let empty = ProviderSetupPolicy.Draft()
        drafts[providerID] = empty
        savedDrafts[providerID] = empty
        clearSyncError(for: providerID)
        refreshHealth(for: providerID)
    }

    /// Only these three clear their browser session on delete today. The
    /// asymmetry with kimi/ollama/mistral/meta/cerebras predates this refactor
    /// and is preserved deliberately rather than widened here.
    private func clearStoredWebsiteData(for providerID: ProviderID) {
        switch providerID {
        case .cursor: CursorSessionImportModel.clearStoredWebsiteData()
        case .qwen: QwenWebSessionImportModel.clearStoredWebsiteData()
        case .mimo: MimoWebSessionImportModel.clearStoredWebsiteData()
        default: break
        }
    }

    func applyImport(
        _ imported: CredentialImportService.ImportedCredential,
        for providerID: ProviderID
    ) -> Bool {
        let merged = providerID == .cursor
            ? ProviderSetupPolicy.mergingCursor(
                draft(for: providerID),
                imported: imported,
                existing: store.credential(for: .cursor)
            )
            : ProviderSetupPolicy.merging(
                draft(for: providerID),
                imported: imported,
                providerID: providerID
            )
        drafts[providerID] = merged
        let didSave = save(providerID, extraFieldsOverride: merged.extraFields)
        if didSave { rescanDetectedCredentials() }
        return didSave
    }

    // MARK: Banner

    /// The auto-dismiss lives on the model rather than the view, so closing a
    /// page inside the 2s window cannot strand it — and so a "Saved" badge
    /// cannot reappear over a different provider.
    func show(_ banner: ProviderSetupBanner) {
        bannerDismissal?.cancel()
        self.banner = banner
        guard case .saved = banner else { return }
        bannerDismissal = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            self?.banner = nil
        }
    }

    func clearBanner() {
        bannerDismissal?.cancel()
        bannerDismissal = nil
        banner = nil
    }

    static let liveBookmarkFactory: (URL) -> Data? = { url in
        do {
            return try url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
        } catch {
            print("[ProviderSetupModel] Failed to create bookmark: \(error)")
            return nil
        }
    }
}

#endif
