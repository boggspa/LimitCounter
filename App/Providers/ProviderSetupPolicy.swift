import Foundation

/// The value logic behind provider setup, lifted out of `ProviderCredentialView`
/// so it has exactly one implementation and can be tested.
///
/// Everything here is pure: no SwiftUI, no AppKit, no Keychain, and no ambient
/// filesystem access. The two genuinely I/O-shaped steps — resolving a
/// security-scoped bookmark and probing for auto-discoverable credentials —
/// either stay with the caller (`bookmarkSourceURL` names the folder to
/// bookmark, the caller creates it) or take injected probes.
///
/// Bodies were copied across verbatim, quirks included. Where a quirk looks like
/// a bug it is called out in a comment rather than tidied: several of them are
/// load-bearing for existing users' stored credentials.
enum ProviderSetupPolicy {

    // MARK: - Values

    /// The editable state of one provider's setup form.
    struct Draft: Equatable {
        var accessToken: String = ""
        var accountIdentifier: String = ""
        var customEndpoint: String = ""
        var extraFields: [String: String] = [:]
        /// The billing-anchor signature as loaded from the store. `anchorUpdatedAt`
        /// is stamped only when the current signature differs from this.
        var loadedBillingAnchorSignature: String = ""

        init(
            accessToken: String = "",
            accountIdentifier: String = "",
            customEndpoint: String = "",
            extraFields: [String: String] = [:],
            loadedBillingAnchorSignature: String = ""
        ) {
            self.accessToken = accessToken
            self.accountIdentifier = accountIdentifier
            self.customEndpoint = customEndpoint
            self.extraFields = extraFields
            self.loadedBillingAnchorSignature = loadedBillingAnchorSignature
        }
    }

    /// Which "already imported" affordances a provider page should show as done.
    struct SessionFlags: Equatable {
        var cursor = false
        var kimiWeb = false
        var ollama = false
        var mistral = false
        var metaWeb = false
        var cerebras = false
        var qwen = false
        var mimo = false
        var museSubscription = false
        var museCli = false
    }

    enum Status: Equatable {
        /// A credential is stored for this provider.
        case configured
        /// No credential, but a local source exists that the app can read unaided.
        case autoDiscoverable
        case needsSetup
    }

    /// The per-provider strings for the import section.
    struct ImportCopy: Equatable {
        let sectionTitle: String
        let buttonTitle: String
        let helpText: String
    }

    /// The half of a save that must happen before the credential is built.
    struct SaveInput: Equatable {
        /// Extra fields with `anchorUpdatedAt` stamped if the anchor moved.
        var extraFields: [String: String]
        /// The folder whose security-scoped bookmark belongs in
        /// `extraFields["bookmarkData"]`, or nil when this provider takes no
        /// folder grant. Creating the bookmark is the caller's job — it is I/O
        /// and it must run while the caller holds the Powerbox grant.
        var bookmarkSourceURL: URL?
    }

    // MARK: - Provider sets

    /// Providers whose primary credential is a local path rather than a token.
    static let localPathPrimaryProviders: Set<ProviderID> = [
        .codexTelemetry, .chatgpt, .gemini, .grok, .antigravity, .cerebras, .meta
    ]

    /// Providers whose `customEndpoint` is bookmarked as a folder grant on save.
    static let localFolderProviders: Set<ProviderID> = [
        .openai, .codexTelemetry, .claude, .chatgpt, .cursor, .gemini, .kimi,
        .grok, .antigravity, .mistral, .cerebras, .meta, .devin
    ]

    /// Providers that keep their existing fields when an import supplies nil.
    /// Everything else is cleared by an import, which is what makes a re-import
    /// a clean slate for those providers.
    private static let fieldPreservingProviders: Set<ProviderID> = [
        .antigravity, .mistral, .deepseek, .cerebras, .meta, .qwen, .mimo
    ]

    // MARK: - Loading

    /// Builds a form draft from the stored credential.
    static func draft(from credential: ProviderCredential?, providerID: ProviderID) -> Draft {
        guard let cred = credential else { return Draft() }

        var draft = Draft()
        if providerID == .claude {
            // Claude stores the two values swapped relative to every other
            // provider: the token lives in `customEndpoint` and the account in
            // `accessToken`. `credential(from:)` inverts it back on save. Do not
            // "fix" this — it would invalidate every existing Claude credential.
            draft.accessToken = cred.customEndpoint ?? ""
            draft.accountIdentifier = cred.accessToken ?? ""
        } else {
            draft.accessToken = cred.accessToken ?? ""
        }
        // Intentionally overwrites the Claude branch's `accountIdentifier` above,
        // which is therefore dead for Claude. Preserved as-is: the assignment
        // order is what existing credentials were written against.
        draft.accountIdentifier = cred.accountIdentifier ?? ""
        draft.extraFields = cred.extraFields ?? [:]

        if providerID == .devin, let restoredEndpoint = restoredDevinEndpoint(from: cred) {
            draft.customEndpoint = restoredEndpoint
        } else {
            draft.customEndpoint = cred.customEndpoint ?? ""
        }

        draft.loadedBillingAnchorSignature = billingAnchorSignature(draft, providerID: providerID)
        return draft
    }

    /// Devin's endpoint is displayed from its bookmark when one resolves, so the
    /// form shows the folder the user actually granted.
    static func restoredDevinEndpoint(from credential: ProviderCredential) -> String? {
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
            print("[ProviderSetupPolicy] Failed to restore Devin bookmark: \(error)")
            return credential.customEndpoint
        }
    }

    // MARK: - Saving

    /// The endpoint a credential is written with. Claude's token doubles as its
    /// endpoint (see `draft(from:)`).
    static func resolvedCustomEndpoint(_ draft: Draft, providerID: ProviderID) -> String? {
        providerID == .claude
            ? (draft.accessToken.isEmpty ? nil : draft.accessToken)
            : (draft.customEndpoint.isEmpty ? nil : draft.customEndpoint)
    }

    /// Stamps `anchorUpdatedAt` when the billing anchor moved and names the
    /// folder the caller should bookmark.
    ///
    /// - Parameter suppliedExtraFields: overrides the draft's own fields, which
    ///   is how the import path saves a freshly merged set.
    static func saveInput(
        for draft: Draft,
        providerID: ProviderID,
        now: Date,
        suppliedExtraFields: [String: String]? = nil
    ) -> SaveInput {
        var extraFields = suppliedExtraFields ?? draft.extraFields
        if billingAnchorSignature(draft, providerID: providerID) != draft.loadedBillingAnchorSignature {
            extraFields[SpendProviderCredentialField.anchorUpdatedAt] = ISO8601DateFormatter().string(from: now)
        }

        var bookmarkSourceURL: URL?
        if let path = resolvedCustomEndpoint(draft, providerID: providerID),
           localFolderProviders.contains(providerID) {
            let url = URL(fileURLWithPath: path)
            if url.isFileURL {
                // Folder grant: bookmark the directory, not the file inside it.
                bookmarkSourceURL = url.hasDirectoryPath ? url : url.deletingLastPathComponent()
            }
        }

        return SaveInput(extraFields: extraFields, bookmarkSourceURL: bookmarkSourceURL)
    }

    /// Builds the credential to persist. `extraFields` comes from `saveInput`,
    /// with any freshly created bookmark already folded in.
    ///
    /// Note this never populates `ProviderCredential.bookmarkData` — the bookmark
    /// travels in `extraFields["bookmarkData"]`. The Codex telemetry save path is
    /// the sole exception and sets both; it is kept separate for that reason.
    static func credential(
        from draft: Draft,
        providerID: ProviderID,
        extraFields: [String: String]
    ) -> ProviderCredential {
        ProviderCredential(
            accessToken: providerID == .claude
                ? (draft.accountIdentifier.isEmpty ? nil : draft.accountIdentifier)
                : (draft.accessToken.isEmpty ? nil : draft.accessToken),
            accountIdentifier: draft.accountIdentifier.isEmpty ? nil : draft.accountIdentifier,
            customEndpoint: resolvedCustomEndpoint(draft, providerID: providerID),
            extraFields: extraFields.isEmpty ? nil : extraFields
        )
    }

    // MARK: - Imports

    /// Folds an imported credential into the draft. Providers outside
    /// `fieldPreservingProviders` are reset by an import that omits a field.
    static func merging(
        _ draft: Draft,
        imported: CredentialImportService.ImportedCredential,
        providerID: ProviderID
    ) -> Draft {
        let isKimiWebSessionImport = providerID == .kimi
            && imported.extraFields?["kimiWebAccessToken"]?.isEmpty == false
        let preservesExistingFields = isKimiWebSessionImport
            || fieldPreservingProviders.contains(providerID)

        var merged = draft
        merged.accessToken = imported.accessToken ?? (preservesExistingFields ? draft.accessToken : "")
        merged.accountIdentifier = imported.accountIdentifier ?? (preservesExistingFields ? draft.accountIdentifier : "")
        merged.customEndpoint = imported.customEndpoint ?? (preservesExistingFields ? draft.customEndpoint : "")

        var extraFields = preservesExistingFields ? draft.extraFields : [:]
        for (key, value) in imported.extraFields ?? [:] {
            extraFields[key] = value
        }
        // The Gemini limit preset is a user choice, not a credential; an import
        // must not silently reset it.
        if providerID == .gemini,
           let preservedPreset = draft.extraFields[GeminiLimitPreset.storageKey] {
            extraFields[GeminiLimitPreset.storageKey] = preservedPreset
        }

        if let bookmarkData = imported.bookmarkData {
            let bookmarkBase64 = bookmarkData.base64EncodedString()
            print("[ProviderSetupPolicy] Got bookmark data (length: \(bookmarkData.count), base64 length: \(bookmarkBase64.count))")
            extraFields["bookmarkData"] = bookmarkBase64
        }
        merged.extraFields = extraFields
        return merged
    }

    /// Cursor falls back to the stored credential per field, then derives which
    /// of its two auth modes the result represents.
    static func mergingCursor(
        _ draft: Draft,
        imported: CredentialImportService.ImportedCredential,
        existing: ProviderCredential?
    ) -> Draft {
        let resolvedAccessToken = imported.accessToken
            ?? (draft.accessToken.isEmpty ? existing?.accessToken : draft.accessToken)
        let resolvedAccountIdentifier = imported.accountIdentifier
            ?? (draft.accountIdentifier.isEmpty ? existing?.accountIdentifier : draft.accountIdentifier)
        let resolvedCustomEndpoint = imported.customEndpoint
            ?? (draft.customEndpoint.isEmpty ? existing?.customEndpoint : draft.customEndpoint)

        var merged = draft
        merged.accessToken = resolvedAccessToken ?? ""
        merged.accountIdentifier = resolvedAccountIdentifier ?? ""
        merged.customEndpoint = resolvedCustomEndpoint ?? ""

        var extraFields = existing?.extraFields ?? draft.extraFields
        for (key, value) in imported.extraFields ?? [:] {
            extraFields[key] = value
        }
        if let bookmarkData = imported.bookmarkData {
            let bookmarkBase64 = bookmarkData.base64EncodedString()
            print("[ProviderSetupPolicy] Got Cursor bookmark data (length: \(bookmarkData.count), base64 length: \(bookmarkBase64.count))")
            extraFields["bookmarkData"] = bookmarkBase64
        }

        let hasCookie = extraFields["cursorCookieHeader"]?
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        let hasLocalState = !(merged.customEndpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            || extraFields["bookmarkData"]?.isEmpty == false
        if hasCookie {
            extraFields["cursorAuthMode"] = "cookie"
        } else if hasLocalState {
            extraFields["cursorAuthMode"] = "localState"
        }

        merged.extraFields = extraFields
        return merged
    }

    // MARK: - Derived state

    /// The signature that decides whether a manual billing anchor moved. Only
    /// providers with a manual anchor have one; everything else is "".
    static func billingAnchorSignature(_ draft: Draft, providerID: ProviderID) -> String {
        let fields = draft.extraFields
        switch providerID {
        case .mistral:
            return [
                fields[SpendProviderCredentialField.manualSpent] ?? "",
                fields[SpendProviderCredentialField.mistralApiSpent] ?? "",
                fields[SpendProviderCredentialField.manualCurrency] ?? "",
                fields[SpendProviderCredentialField.manualResetAt] ?? ""
            ].joined(separator: "|")
        case .cerebras:
            // Cerebras alone folds the account in: its balance is per-account.
            return [
                fields[SpendProviderCredentialField.manualCurrentBalance] ?? "",
                fields[SpendProviderCredentialField.manualCurrency] ?? "",
                draft.accountIdentifier
            ].joined(separator: "|")
        case .deepseek:
            return fields[SpendProviderCredentialField.manualTopUpTotal] ?? ""
        case .meta:
            return [
                fields[SpendProviderCredentialField.manualSpent] ?? "",
                fields[SpendProviderCredentialField.manualCurrency] ?? "",
                fields[SpendProviderCredentialField.manualResetAt] ?? ""
            ].joined(separator: "|")
        case .qwen, .mimo:
            return [
                fields[SpendProviderCredentialField.manualWeeklyUsedPercent] ?? "",
                fields[SpendProviderCredentialField.manualResetAt] ?? "",
                fields[SpendProviderCredentialField.manualPlanName] ?? ""
            ].joined(separator: "|")
        default:
            return ""
        }
    }

    /// Which session imports this draft already carries.
    static func sessionFlags(_ draft: Draft, providerID: ProviderID) -> SessionFlags {
        let fields = draft.extraFields
        var flags = SessionFlags()
        flags.cursor = providerID == .cursor && (
            fields["cursorAuthMode"] == "cookie"
            || (fields["cursorCookieHeader"]?.isEmpty == false)
        )
        flags.kimiWeb = providerID == .kimi
            && fields["kimiWebAccessToken"]?.isEmpty == false
        flags.ollama = providerID == .ollama && (
            !draft.accessToken.isEmpty
            || (fields["ollamaCookie"]?.isEmpty == false)
        )
        flags.mistral = providerID == .mistral && (
            fields["mistralCookieHeader"]?.isEmpty == false
            || fields["mistralCookie"]?.isEmpty == false
        )
        // Meta and Cerebras used to set their "session stored" tick only in the
        // window that performed the import, so reopening the form lost it.
        // Deriving both from the stored cookie makes the tick outlive the view.
        flags.metaWeb = providerID == .meta
            && fields[SpendProviderCredentialField.metaCookieHeader]?.isEmpty == false
        flags.cerebras = providerID == .cerebras
            && fields[SpendProviderCredentialField.cerebrasCookieHeader]?.isEmpty == false
        flags.qwen = providerID == .qwen
            && fields[SpendProviderCredentialField.qwenCookieHeader]?.isEmpty == false
        flags.mimo = providerID == .mimo
            && fields[SpendProviderCredentialField.mimoCookieHeader]?.isEmpty == false
        flags.museSubscription = providerID == .meta && (
            fields[SpendProviderCredentialField.museCachedCurrentPercent]?.isEmpty == false
            || fields[SpendProviderCredentialField.museCachedWeeklyPercent]?.isEmpty == false
        )
        flags.museCli = providerID == .meta
            && fields[SpendProviderCredentialField.museCliBookmark]?.isEmpty == false
        return flags
    }

    static func status(hasCredential: Bool, canAutoDiscover: Bool) -> Status {
        if hasCredential { return .configured }
        return canAutoDiscover ? .autoDiscoverable : .needsSetup
    }

    /// Filesystem probes, injected so this stays testable without a real home
    /// directory.
    struct FileProbes {
        var fileExists: (String) -> Bool
        var isReadableFile: (String) -> Bool
        var contentsOfDirectory: (URL) -> [URL]?

        static let live = FileProbes(
            fileExists: { FileManager.default.fileExists(atPath: $0) },
            isReadableFile: { FileManager.default.isReadableFile(atPath: $0) },
            contentsOfDirectory: { url in
                try? FileManager.default.contentsOfDirectory(
                    at: url,
                    includingPropertiesForKeys: nil,
                    options: [.skipsHiddenFiles]
                )
            }
        )
    }

    /// Whether the app can read this provider's usage without any credential —
    /// i.e. the local source is already inside the app's reach.
    static func canAutoDiscover(
        _ providerID: ProviderID,
        home: URL,
        probes: FileProbes = .live
    ) -> Bool {
        #if os(macOS)
        if providerID == .claude {
            let claudeRoot = home.appendingPathComponent(".claude")
            let projectsDir = claudeRoot.appendingPathComponent("projects")
            return probes.fileExists(claudeRoot.path)
                && probes.fileExists(projectsDir.path)
        }
        if providerID == .codexTelemetry {
            let telemetryRoot = home.appendingPathComponent(".codex")
            let telemetryLog = telemetryRoot.appendingPathComponent("log")
            let telemetrySQLite = telemetryRoot.appendingPathComponent("logs_2.sqlite")
            let telemetrySessions = telemetryRoot.appendingPathComponent("session_index.jsonl")
            return probes.fileExists(telemetryRoot.path)
                && (probes.fileExists(telemetryLog.path)
                    || probes.fileExists(telemetrySQLite.path)
                    || probes.fileExists(telemetrySessions.path))
        }
        if providerID == .chatgpt {
            let chatGPTRoot = home.appendingPathComponent("Library/Application Support/com.openai.chat")
            let conversations = probes.contentsOfDirectory(chatGPTRoot)
            return probes.fileExists(chatGPTRoot.path)
                && !(conversations?.isEmpty ?? true)
        }
        if providerID == .devin {
            let stateDB = home.appendingPathComponent("Library/Application Support/Devin/User/globalStorage/state.vscdb")
            let backupDB = home.appendingPathComponent("Library/Application Support/Devin/User/globalStorage/state.vscdb.backup")
            return probes.isReadableFile(stateDB.path)
                || probes.isReadableFile(backupDB.path)
        }
        if providerID == .gemini {
            let geminiRoot = home.appendingPathComponent(".gemini")
            let tmpDir = geminiRoot.appendingPathComponent("tmp")
            return probes.fileExists(geminiRoot.path)
                && probes.fileExists(tmpDir.path)
        }
        if providerID == .grok {
            // Grok needs an explicit folder grant to run its CLI; finding the
            // folder is not enough to read usage.
            return false
        }
        #endif
        return false
    }

    // MARK: - Copy

    static func importCopy(for providerID: ProviderID) -> ImportCopy {
        ImportCopy(
            sectionTitle: importSectionTitle(providerID),
            buttonTitle: importButtonTitle(providerID),
            helpText: importHelpText(providerID)
        )
    }

    private static func importSectionTitle(_ providerID: ProviderID) -> String {
        switch providerID {
        case .openai:
            return "Grant Codex Session Access"
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

    private static func importButtonTitle(_ providerID: ProviderID) -> String {
        switch providerID {
        case .openai:
            return "Select ~/.codex folder..."
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

    private static func importHelpText(_ providerID: ProviderID) -> String {
        switch providerID {
        case .openai:
            return "Grant access to the full `~/.codex` folder. Limit Counter can then follow `auth.json` token rotation inside that grant without another prompt after a Codex CLI update."
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

    // MARK: - Field editing

    /// Writing a blank value *removes* the key rather than storing "". Several
    /// providers treat a present-but-empty field differently from an absent one,
    /// so this distinction is load-bearing.
    static func setExtraField(
        _ key: String,
        to value: String,
        in extraFields: inout [String: String]
    ) {
        if value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            extraFields.removeValue(forKey: key)
        } else {
            extraFields[key] = value
        }
    }
}

/// The Keychain surface provider setup needs, so tests can substitute a fake
/// rather than writing to the real login keychain.
protocol ProviderCredentialStoring {
    func credential(for providerID: ProviderID) -> ProviderCredential?
    func hasCredential(for providerID: ProviderID) -> Bool
    @discardableResult
    func save(_ credential: ProviderCredential, for providerID: ProviderID) -> Bool
    func delete(for providerID: ProviderID)
}

extension KeychainService: ProviderCredentialStoring {}
