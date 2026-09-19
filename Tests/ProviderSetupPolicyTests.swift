import Foundation

// Pins the credential value logic extracted from `ProviderCredentialView` so the
// setup-sheet refactor cannot change behaviour for any provider. Written against
// the old view as the reference implementation, before the new UI exists.

private enum SetupPolicyTestError: Error, CustomStringConvertible {
    case failure(String)

    var description: String {
        switch self {
        case .failure(let message):
            return message
        }
    }
}

private func setupExpect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() {
        throw SetupPolicyTestError.failure(message)
    }
}

private func setupExpectEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: String) throws {
    if actual != expected {
        throw SetupPolicyTestError.failure("\(message): expected \(expected), got \(actual)")
    }
}

/// Stands in for the login keychain.
private final class FakeCredentialStore: ProviderCredentialStoring, @unchecked Sendable {
    var stored: [ProviderID: ProviderCredential] = [:]
    var saveSucceeds = true
    private(set) var saveCount = 0
    private(set) var deleteCount = 0

    func credential(for providerID: ProviderID) -> ProviderCredential? {
        stored[providerID]
    }

    func hasCredential(for providerID: ProviderID) -> Bool {
        stored[providerID] != nil
    }

    @discardableResult
    func save(_ credential: ProviderCredential, for providerID: ProviderID) -> Bool {
        saveCount += 1
        guard saveSucceeds else { return false }
        stored[providerID] = credential
        return true
    }

    func delete(for providerID: ProviderID) {
        deleteCount += 1
        stored.removeValue(forKey: providerID)
    }
}

private let fixedNow = Date(timeIntervalSince1970: 1_760_000_000)

// MARK: - Field mapping

private func testClaudeFieldsRoundTripInverted() throws {
    // Claude stores the token in `customEndpoint` and the account in
    // `accessToken`. Both directions must keep that inversion.
    let stored = ProviderCredential(
        accessToken: "account-value",
        accountIdentifier: "account-value",
        customEndpoint: "token-value"
    )
    let draft = ProviderSetupPolicy.draft(from: stored, providerID: .claude)
    try setupExpectEqual(draft.accessToken, "token-value", "Claude token loads from customEndpoint")
    try setupExpectEqual(draft.accountIdentifier, "account-value", "Claude account loads from accountIdentifier")

    let input = ProviderSetupPolicy.saveInput(for: draft, providerID: .claude, now: fixedNow)
    let written = ProviderSetupPolicy.credential(
        from: draft,
        providerID: .claude,
        extraFields: input.extraFields
    )
    try setupExpectEqual(written.customEndpoint, "token-value", "Claude token saves back into customEndpoint")
    try setupExpectEqual(written.accessToken, "account-value", "Claude accessToken carries the account")
}

private func testNonClaudeFieldsRoundTripStraight() throws {
    let stored = ProviderCredential(
        accessToken: "sk-live",
        accountIdentifier: "acct-1",
        customEndpoint: "https://example.test"
    )
    let draft = ProviderSetupPolicy.draft(from: stored, providerID: .openrouter)
    try setupExpectEqual(draft.accessToken, "sk-live", "token loads straight")
    try setupExpectEqual(draft.customEndpoint, "https://example.test", "endpoint loads straight")

    let input = ProviderSetupPolicy.saveInput(for: draft, providerID: .openrouter, now: fixedNow)
    let written = ProviderSetupPolicy.credential(
        from: draft,
        providerID: .openrouter,
        extraFields: input.extraFields
    )
    try setupExpectEqual(written.accessToken, "sk-live", "token saves straight")
    try setupExpectEqual(written.customEndpoint, "https://example.test", "endpoint saves straight")
}

private func testEmptyDraftProducesEmptyCredential() throws {
    let written = ProviderSetupPolicy.credential(
        from: ProviderSetupPolicy.Draft(),
        providerID: .openrouter,
        extraFields: [:]
    )
    try setupExpect(written.isEmpty, "a blank draft is an empty credential, which the caller deletes")
}

// MARK: - Billing anchors

private func testAnchorUpdatedAtStampedOnlyWhenSignatureChanges() throws {
    let anchored: [ProviderID] = [.mistral, .deepseek, .cerebras, .meta, .qwen, .mimo]
    for providerID in anchored {
        var draft = ProviderSetupPolicy.Draft()
        draft.extraFields[SpendProviderCredentialField.manualSpent] = "10"
        draft.extraFields[SpendProviderCredentialField.manualTopUpTotal] = "10"
        draft.extraFields[SpendProviderCredentialField.manualCurrentBalance] = "10"
        draft.extraFields[SpendProviderCredentialField.manualWeeklyUsedPercent] = "10"
        draft.loadedBillingAnchorSignature = ProviderSetupPolicy.billingAnchorSignature(
            draft,
            providerID: providerID
        )

        let unchanged = ProviderSetupPolicy.saveInput(for: draft, providerID: providerID, now: fixedNow)
        try setupExpect(
            unchanged.extraFields[SpendProviderCredentialField.anchorUpdatedAt] == nil,
            "\(providerID.rawValue): an unchanged anchor must not restamp anchorUpdatedAt"
        )

        var moved = draft
        moved.extraFields[SpendProviderCredentialField.manualSpent] = "25"
        moved.extraFields[SpendProviderCredentialField.manualTopUpTotal] = "25"
        moved.extraFields[SpendProviderCredentialField.manualCurrentBalance] = "25"
        moved.extraFields[SpendProviderCredentialField.manualWeeklyUsedPercent] = "25"
        let changed = ProviderSetupPolicy.saveInput(for: moved, providerID: providerID, now: fixedNow)
        try setupExpectEqual(
            changed.extraFields[SpendProviderCredentialField.anchorUpdatedAt],
            ISO8601DateFormatter().string(from: fixedNow),
            "\(providerID.rawValue): a moved anchor stamps anchorUpdatedAt once"
        )
    }
}

private func testProvidersWithoutAnchorsNeverStamp() throws {
    var draft = ProviderSetupPolicy.Draft()
    draft.accessToken = "sk-live"
    let input = ProviderSetupPolicy.saveInput(for: draft, providerID: .openrouter, now: fixedNow)
    try setupExpect(
        input.extraFields[SpendProviderCredentialField.anchorUpdatedAt] == nil,
        "a provider with no manual anchor has an empty signature and never stamps"
    )
}

private func testBillingAnchorSignaturePerProvider() throws {
    var draft = ProviderSetupPolicy.Draft()
    draft.accountIdentifier = "acct-9"
    draft.extraFields = [
        SpendProviderCredentialField.manualSpent: "5",
        SpendProviderCredentialField.mistralApiSpent: "6",
        SpendProviderCredentialField.manualCurrency: "GBP",
        SpendProviderCredentialField.manualResetAt: "2026-09-07",
        SpendProviderCredentialField.manualCurrentBalance: "40",
        SpendProviderCredentialField.manualTopUpTotal: "80",
        SpendProviderCredentialField.manualWeeklyUsedPercent: "33",
        SpendProviderCredentialField.manualPlanName: "Pro"
    ]

    try setupExpectEqual(
        ProviderSetupPolicy.billingAnchorSignature(draft, providerID: .mistral),
        "5|6|GBP|2026-09-07",
        "mistral signature"
    )
    try setupExpectEqual(
        ProviderSetupPolicy.billingAnchorSignature(draft, providerID: .cerebras),
        "40|GBP|acct-9",
        "cerebras signature uniquely folds in the account"
    )
    try setupExpectEqual(
        ProviderSetupPolicy.billingAnchorSignature(draft, providerID: .deepseek),
        "80",
        "deepseek signature"
    )
    try setupExpectEqual(
        ProviderSetupPolicy.billingAnchorSignature(draft, providerID: .meta),
        "5|GBP|2026-09-07",
        "meta signature"
    )
    try setupExpectEqual(
        ProviderSetupPolicy.billingAnchorSignature(draft, providerID: .qwen),
        "33|2026-09-07|Pro",
        "qwen signature"
    )
    try setupExpectEqual(
        ProviderSetupPolicy.billingAnchorSignature(draft, providerID: .mimo),
        "33|2026-09-07|Pro",
        "mimo shares qwen's signature shape"
    )
    try setupExpectEqual(
        ProviderSetupPolicy.billingAnchorSignature(draft, providerID: .openai),
        "",
        "providers without a manual anchor have no signature"
    )

    // Cerebras is the only provider where editing the account moves the anchor.
    var renamed = draft
    renamed.accountIdentifier = "acct-10"
    try setupExpect(
        ProviderSetupPolicy.billingAnchorSignature(renamed, providerID: .cerebras)
            != ProviderSetupPolicy.billingAnchorSignature(draft, providerID: .cerebras),
        "changing the Cerebras account moves its anchor"
    )
    try setupExpectEqual(
        ProviderSetupPolicy.billingAnchorSignature(renamed, providerID: .meta),
        ProviderSetupPolicy.billingAnchorSignature(draft, providerID: .meta),
        "changing the account does not move Meta's anchor"
    )
}

// MARK: - Extra fields

private func testExtraFieldEmptyValueRemovesKey() throws {
    var fields = ["manualSpent": "12"]
    ProviderSetupPolicy.setExtraField("manualSpent", to: "  ", in: &fields)
    try setupExpect(fields["manualSpent"] == nil, "a blank value removes the key rather than storing \"\"")

    ProviderSetupPolicy.setExtraField("manualSpent", to: "18", in: &fields)
    try setupExpectEqual(fields["manualSpent"], "18", "a real value is stored")
}

// MARK: - Imports

private func testImportPreservesExistingFieldsForPreservingProviders() throws {
    let preserving: [ProviderID] = [.antigravity, .mistral, .deepseek, .cerebras, .meta, .qwen, .mimo]
    for providerID in preserving {
        var draft = ProviderSetupPolicy.Draft()
        draft.accessToken = "kept-token"
        draft.extraFields = ["existing": "kept"]

        let merged = ProviderSetupPolicy.merging(
            draft,
            imported: CredentialImportService.ImportedCredential(
                accessToken: nil,
                accountIdentifier: nil,
                extraFields: ["fresh": "new"]
            ),
            providerID: providerID
        )
        try setupExpectEqual(merged.accessToken, "kept-token", "\(providerID.rawValue) keeps its token")
        try setupExpectEqual(merged.extraFields["existing"], "kept", "\(providerID.rawValue) keeps prior fields")
        try setupExpectEqual(merged.extraFields["fresh"], "new", "\(providerID.rawValue) takes the imported field")
    }

    // A non-preserving provider is reset by an import that omits a field.
    var draft = ProviderSetupPolicy.Draft()
    draft.accessToken = "stale-token"
    draft.extraFields = ["existing": "dropped"]
    let cleared = ProviderSetupPolicy.merging(
        draft,
        imported: CredentialImportService.ImportedCredential(
            accessToken: nil,
            accountIdentifier: nil,
            extraFields: ["fresh": "new"]
        ),
        providerID: .openai
    )
    try setupExpectEqual(cleared.accessToken, "", "a non-preserving provider clears an omitted token")
    try setupExpect(cleared.extraFields["existing"] == nil, "a non-preserving provider clears prior fields")
}

private func testKimiWebImportPreservesButFolderImportDoesNot() throws {
    var draft = ProviderSetupPolicy.Draft()
    draft.accessToken = "cli-token"

    let webImport = ProviderSetupPolicy.merging(
        draft,
        imported: CredentialImportService.ImportedCredential(
            accessToken: nil,
            accountIdentifier: nil,
            extraFields: ["kimiWebAccessToken": "web-token"]
        ),
        providerID: .kimi
    )
    try setupExpectEqual(webImport.accessToken, "cli-token", "a Kimi web import keeps the CLI token")

    let folderImport = ProviderSetupPolicy.merging(
        draft,
        imported: CredentialImportService.ImportedCredential(
            accessToken: nil,
            accountIdentifier: nil,
            extraFields: ["other": "value"]
        ),
        providerID: .kimi
    )
    try setupExpectEqual(folderImport.accessToken, "", "a plain Kimi import does not preserve")
}

private func testGeminiLimitPresetSurvivesImport() throws {
    var draft = ProviderSetupPolicy.Draft()
    draft.extraFields = [GeminiLimitPreset.storageKey: GeminiLimitPreset.allCases.last!.rawValue]
    let merged = ProviderSetupPolicy.merging(
        draft,
        imported: CredentialImportService.ImportedCredential(
            accessToken: "token",
            accountIdentifier: nil,
            extraFields: ["fresh": "new"]
        ),
        providerID: .gemini
    )
    try setupExpectEqual(
        merged.extraFields[GeminiLimitPreset.storageKey],
        GeminiLimitPreset.allCases.last!.rawValue,
        "the Gemini limit preset is a user choice and survives an import"
    )
}

private func testImportedBookmarkLandsInExtraFields() throws {
    let bookmark = Data([0x01, 0x02, 0x03, 0x04])
    let merged = ProviderSetupPolicy.merging(
        ProviderSetupPolicy.Draft(),
        imported: CredentialImportService.ImportedCredential(
            accessToken: nil,
            accountIdentifier: nil,
            bookmarkData: bookmark
        ),
        providerID: .openai
    )
    try setupExpectEqual(
        merged.extraFields["bookmarkData"],
        bookmark.base64EncodedString(),
        "the bookmark is carried base64-encoded in extraFields"
    )

    // The credential itself never sets `bookmarkData:` — only the extra field.
    // Codex telemetry is the sole path that sets both, and it is separate.
    let written = ProviderSetupPolicy.credential(
        from: merged,
        providerID: .openai,
        extraFields: merged.extraFields
    )
    try setupExpect(
        written.bookmarkData == nil,
        "the standard save leaves ProviderCredential.bookmarkData unset"
    )
    try setupExpectEqual(
        written.extraFields?["bookmarkData"],
        bookmark.base64EncodedString(),
        "the bookmark persists via extraFields"
    )
}

private func testCursorAuthModeDerivation() throws {
    let cookie = ProviderSetupPolicy.mergingCursor(
        ProviderSetupPolicy.Draft(),
        imported: CredentialImportService.ImportedCredential(
            accessToken: nil,
            accountIdentifier: nil,
            extraFields: ["cursorCookieHeader": "session=abc"]
        ),
        existing: nil
    )
    try setupExpectEqual(cookie.extraFields["cursorAuthMode"], "cookie", "a cookie import is cookie mode")

    let localState = ProviderSetupPolicy.mergingCursor(
        ProviderSetupPolicy.Draft(),
        imported: CredentialImportService.ImportedCredential(
            accessToken: nil,
            accountIdentifier: nil,
            customEndpoint: "/Users/test/Library/Application Support/Cursor"
        ),
        existing: nil
    )
    try setupExpectEqual(localState.extraFields["cursorAuthMode"], "localState", "a folder import is localState mode")

    let neither = ProviderSetupPolicy.mergingCursor(
        ProviderSetupPolicy.Draft(),
        imported: CredentialImportService.ImportedCredential(accessToken: nil, accountIdentifier: nil),
        existing: nil
    )
    try setupExpect(neither.extraFields["cursorAuthMode"] == nil, "neither source leaves the mode untouched")
}

private func testCursorImportFallsBackToStoredCredential() throws {
    let existing = ProviderCredential(
        accessToken: "stored-token",
        accountIdentifier: "stored-account",
        customEndpoint: "/stored/path",
        extraFields: ["storedKey": "storedValue"]
    )
    let merged = ProviderSetupPolicy.mergingCursor(
        ProviderSetupPolicy.Draft(),
        imported: CredentialImportService.ImportedCredential(
            accessToken: nil,
            accountIdentifier: nil,
            extraFields: ["cursorCookieHeader": "session=abc"]
        ),
        existing: existing
    )
    try setupExpectEqual(merged.accessToken, "stored-token", "an empty draft falls back to the stored token")
    try setupExpectEqual(merged.accountIdentifier, "stored-account", "and the stored account")
    try setupExpectEqual(merged.extraFields["storedKey"], "storedValue", "and the stored extra fields")
}

// MARK: - Session flags

private func testSessionFlagsMatchLegacyDerivation() throws {
    var cursor = ProviderSetupPolicy.Draft()
    cursor.extraFields = ["cursorAuthMode": "cookie"]
    try setupExpect(
        ProviderSetupPolicy.sessionFlags(cursor, providerID: .cursor).cursor,
        "cursorAuthMode alone marks Cursor as imported"
    )
    var cursorHeader = ProviderSetupPolicy.Draft()
    cursorHeader.extraFields = ["cursorCookieHeader": "session=abc"]
    try setupExpect(
        ProviderSetupPolicy.sessionFlags(cursorHeader, providerID: .cursor).cursor,
        "a cookie header alone also marks Cursor as imported"
    )

    var ollama = ProviderSetupPolicy.Draft()
    ollama.accessToken = "key"
    try setupExpect(
        ProviderSetupPolicy.sessionFlags(ollama, providerID: .ollama).ollama,
        "Ollama counts a pasted key as an import"
    )

    var mistral = ProviderSetupPolicy.Draft()
    mistral.extraFields = ["mistralCookie": "abc"]
    try setupExpect(
        ProviderSetupPolicy.sessionFlags(mistral, providerID: .mistral).mistral,
        "Mistral accepts either cookie key"
    )

    var muse = ProviderSetupPolicy.Draft()
    muse.extraFields = [SpendProviderCredentialField.museCachedWeeklyPercent: "38"]
    let museFlags = ProviderSetupPolicy.sessionFlags(muse, providerID: .meta)
    try setupExpect(museFlags.museSubscription, "a cached weekly percent marks the Muse import done")
    try setupExpect(!museFlags.museCli, "no bookmark means the CLI grant is not done")

    var museCli = ProviderSetupPolicy.Draft()
    museCli.extraFields = [SpendProviderCredentialField.museCliBookmark: "AAAA"]
    try setupExpect(
        ProviderSetupPolicy.sessionFlags(museCli, providerID: .meta).museCli,
        "a stored bookmark marks the Muse CLI grant done"
    )

    // Meta and Cerebras derive their "session stored" tick from the stored
    // cookie, so it survives closing and reopening the form.
    var metaWeb = ProviderSetupPolicy.Draft()
    metaWeb.extraFields = [SpendProviderCredentialField.metaCookieHeader: "session=abc"]
    try setupExpect(
        ProviderSetupPolicy.sessionFlags(metaWeb, providerID: .meta).metaWeb,
        "a stored Meta cookie marks its web session imported"
    )
    try setupExpect(
        !ProviderSetupPolicy.sessionFlags(ProviderSetupPolicy.Draft(), providerID: .meta).metaWeb,
        "no Meta cookie means no web session"
    )

    var cerebras = ProviderSetupPolicy.Draft()
    cerebras.extraFields = [SpendProviderCredentialField.cerebrasCookieHeader: "session=abc"]
    try setupExpect(
        ProviderSetupPolicy.sessionFlags(cerebras, providerID: .cerebras).cerebras,
        "a stored Cerebras cookie marks its web session imported"
    )

    // Flags are provider-scoped: the same fields on another provider read false.
    try setupExpect(
        !ProviderSetupPolicy.sessionFlags(cursor, providerID: .kimi).cursor,
        "flags never fire for the wrong provider"
    )
    try setupExpect(
        !ProviderSetupPolicy.sessionFlags(metaWeb, providerID: .cerebras).metaWeb,
        "the Meta flag never fires for another provider"
    )
}

// MARK: - Auto-discovery

private func testCanAutoDiscoverPerProvider() throws {
    let home = URL(fileURLWithPath: "/Users/tester")

    func probes(existing: Set<String> = [], readable: Set<String> = [], contents: [URL]? = nil)
        -> ProviderSetupPolicy.FileProbes {
        ProviderSetupPolicy.FileProbes(
            fileExists: { existing.contains($0) },
            isReadableFile: { readable.contains($0) },
            contentsOfDirectory: { _ in contents }
        )
    }

    try setupExpect(
        ProviderSetupPolicy.canAutoDiscover(
            .claude,
            home: home,
            probes: probes(existing: ["/Users/tester/.claude", "/Users/tester/.claude/projects"])
        ),
        "Claude needs both .claude and its projects directory"
    )
    try setupExpect(
        !ProviderSetupPolicy.canAutoDiscover(
            .claude,
            home: home,
            probes: probes(existing: ["/Users/tester/.claude"])
        ),
        "Claude without a projects directory is not discoverable"
    )

    try setupExpect(
        ProviderSetupPolicy.canAutoDiscover(
            .codexTelemetry,
            home: home,
            probes: probes(existing: ["/Users/tester/.codex", "/Users/tester/.codex/logs_2.sqlite"])
        ),
        "Codex telemetry accepts any one of its three sources"
    )

    try setupExpect(
        ProviderSetupPolicy.canAutoDiscover(
            .chatgpt,
            home: home,
            probes: probes(
                existing: ["/Users/tester/Library/Application Support/com.openai.chat"],
                contents: [URL(fileURLWithPath: "/conv.json")]
            )
        ),
        "ChatGPT needs a non-empty conversations directory"
    )
    try setupExpect(
        !ProviderSetupPolicy.canAutoDiscover(
            .chatgpt,
            home: home,
            probes: probes(
                existing: ["/Users/tester/Library/Application Support/com.openai.chat"],
                contents: []
            )
        ),
        "an empty ChatGPT directory is not discoverable"
    )

    try setupExpect(
        ProviderSetupPolicy.canAutoDiscover(
            .devin,
            home: home,
            probes: probes(readable: ["/Users/tester/Library/Application Support/Devin/User/globalStorage/state.vscdb.backup"])
        ),
        "Devin accepts the backup database alone"
    )

    try setupExpect(
        ProviderSetupPolicy.canAutoDiscover(
            .gemini,
            home: home,
            probes: probes(existing: ["/Users/tester/.gemini", "/Users/tester/.gemini/tmp"])
        ),
        "Gemini needs .gemini and its tmp directory"
    )

    try setupExpect(
        !ProviderSetupPolicy.canAutoDiscover(
            .grok,
            home: home,
            probes: probes(existing: ["/Users/tester/.grok"])
        ),
        "Grok always needs an explicit grant, even when its folder is present"
    )

    try setupExpect(
        !ProviderSetupPolicy.canAutoDiscover(.openrouter, home: home, probes: probes()),
        "a token-only provider is never auto-discoverable"
    )
}

private func testStatusPrefersStoredCredential() throws {
    try setupExpectEqual(
        ProviderSetupPolicy.status(hasCredential: true, canAutoDiscover: false),
        .configured,
        "a stored credential means configured"
    )
    try setupExpectEqual(
        ProviderSetupPolicy.status(hasCredential: false, canAutoDiscover: true),
        .autoDiscoverable,
        "a readable local source means no setup is required"
    )
    try setupExpectEqual(
        ProviderSetupPolicy.status(hasCredential: false, canAutoDiscover: false),
        .needsSetup,
        "neither means setup is needed"
    )
}

// MARK: - Folder grants

private func testBookmarkSourceResolvesToContainingFolder() throws {
    var fileDraft = ProviderSetupPolicy.Draft()
    fileDraft.customEndpoint = "/Users/tester/.codex/auth.json"
    let fileInput = ProviderSetupPolicy.saveInput(for: fileDraft, providerID: .openai, now: fixedNow)
    try setupExpectEqual(
        fileInput.bookmarkSourceURL?.path,
        "/Users/tester/.codex",
        "a file path is bookmarked as its containing folder"
    )

    var tokenDraft = ProviderSetupPolicy.Draft()
    tokenDraft.customEndpoint = "/Users/tester/.codex"
    tokenDraft.accessToken = "sk-live"
    let tokenInput = ProviderSetupPolicy.saveInput(for: tokenDraft, providerID: .openrouter, now: fixedNow)
    try setupExpect(
        tokenInput.bookmarkSourceURL == nil,
        "a provider that takes no folder grant is never bookmarked"
    )
}

// MARK: - Copy

private func testImportCopyIsProviderSpecificWithASharedDefault() throws {
    try setupExpectEqual(
        ProviderSetupPolicy.importCopy(for: .openai).sectionTitle,
        "Grant Codex Session Access",
        "Codex has bespoke copy"
    )
    try setupExpectEqual(
        ProviderSetupPolicy.importCopy(for: .openrouter).buttonTitle,
        "Select credential file...",
        "providers without bespoke copy share the default"
    )
    try setupExpect(
        ProviderSetupPolicy.importCopy(for: .grok).buttonTitle.contains("Grok"),
        "Grok names its own folder"
    )
}

// MARK: - Store round trip

private func testDraftRoundTripsThroughAFakeStore() throws {
    let store = FakeCredentialStore()
    var draft = ProviderSetupPolicy.Draft()
    draft.accessToken = "token"
    draft.accountIdentifier = "account"
    draft.extraFields = ["k": "v"]

    let input = ProviderSetupPolicy.saveInput(for: draft, providerID: .openrouter, now: fixedNow)
    let credential = ProviderSetupPolicy.credential(
        from: draft,
        providerID: .openrouter,
        extraFields: input.extraFields
    )
    try setupExpect(store.save(credential, for: .openrouter), "the fake store accepts the save")

    let reloaded = ProviderSetupPolicy.draft(
        from: store.credential(for: .openrouter),
        providerID: .openrouter
    )
    try setupExpectEqual(reloaded.accessToken, "token", "token survives the round trip")
    try setupExpectEqual(reloaded.accountIdentifier, "account", "account survives the round trip")
    try setupExpectEqual(reloaded.extraFields["k"], "v", "extra fields survive the round trip")
}

private func testSaveFailureIsReportedAndLeavesTheStoreUntouched() throws {
    let store = FakeCredentialStore()
    store.saveSucceeds = false
    var draft = ProviderSetupPolicy.Draft()
    draft.accessToken = "token"

    let credential = ProviderSetupPolicy.credential(
        from: draft,
        providerID: .openrouter,
        extraFields: [:]
    )
    try setupExpect(!store.save(credential, for: .openrouter), "a failing store reports failure")
    try setupExpect(
        store.credential(for: .openrouter) == nil,
        "a failed save must not appear to have persisted"
    )
}

@main
private enum ProviderSetupPolicyTestRunner {
    static func main() throws {
        try testClaudeFieldsRoundTripInverted()
        try testNonClaudeFieldsRoundTripStraight()
        try testEmptyDraftProducesEmptyCredential()
        try testAnchorUpdatedAtStampedOnlyWhenSignatureChanges()
        try testProvidersWithoutAnchorsNeverStamp()
        try testBillingAnchorSignaturePerProvider()
        try testExtraFieldEmptyValueRemovesKey()
        try testImportPreservesExistingFieldsForPreservingProviders()
        try testKimiWebImportPreservesButFolderImportDoesNot()
        try testGeminiLimitPresetSurvivesImport()
        try testImportedBookmarkLandsInExtraFields()
        try testCursorAuthModeDerivation()
        try testCursorImportFallsBackToStoredCredential()
        try testSessionFlagsMatchLegacyDerivation()
        try testCanAutoDiscoverPerProvider()
        try testStatusPrefersStoredCredential()
        try testBookmarkSourceResolvesToContainingFolder()
        try testImportCopyIsProviderSpecificWithASharedDefault()
        try testDraftRoundTripsThroughAFakeStore()
        try testSaveFailureIsReportedAndLeavesTheStoreUntouched()
        print("Provider setup policy tests passed")
    }
}
