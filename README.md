# Limit Counter

SwiftUI quota tracker covering Claude, Codex, Cursor, Devin, Kimi, Qwen, MiniMax, Mistral, Gemini, Grok, OpenRouter, Ollama, and more.

## Current Shape

- Shared quota models and card views live in `Shared/`.
- The main app shell lives in `App/`.
- A real WidgetKit extension target is wired in `Widget/` and embedded into the app target with shared App Group storage.
- The Codex provider now has a real session-backed adapter that reads ChatGPT-plan 5-hour and 7-day usage from the same private usage surface used by Codex clients. OpenAI API has a separate official Admin API provider for project rate limits, 30-day token/request/cost analytics, projected monthly spend, per-provider budget thresholds, spike callouts, and top-model drivers. Claude, Devin, and Cursor each have real adapters; mocks remain only for Xcode previews and widget placeholders.
- A Codex Telemetry provider can read local Codex log folders and turn structured event logs into activity counts and token summaries.

## Usage Limit Resets

Providers hand out two kinds of out-of-schedule resets, and the app tracks both.

- **Banked resets** are credits the user redeems themselves. Codex reports them directly (`wham/usage` carries `rate_limit_reset_credits`; `wham/rate-limit-reset-credits` lists the credits and `…/history` the granted/used events behind the Codex app's "Usage limit resets" panel). Qwen shows the count on its Plan Quota card ("Reset ⓘ 1 available"), which the app reads every half hour. A banked reset shows as a pill on the provider card, a "Reset available" alert (repeated once when it is about to expire), and a "Reset used" entry in the provider detail view once redeemed.
- **Gifted resets** are the celebratory ones ("we've reset everyone's weekly limits"). `QuotaResetDetector` (`Shared/Models/QuotaResetDetector.swift`) infers them from successive meter readings: a drop is held as *pending* until the next reading confirms it, reset-date drift on a rolling window never counts on its own, a five-hour window only resets early alongside a sibling window or a consumed credit, several windows dropping together become one *provider-wide* reset, and each window reports at most one inferred reset per day. Confirmed resets land in a 60-day ledger, feed the "N resets · 7d" tally, and play the celebration.

## Multiple Accounts

One person can hold more than one account with the same provider (a personal
Claude Max and a work one, two Codex subscriptions). Limit Counter tracks them
side by side; it never switches, rotates or pools them.

- **What an account is.** The primary account of every provider is the provider
  itself — everything a single-account install already stores. Each additional
  account is an opaque slot under the provider with a label you choose ("Work",
  never an email), kept in the App Group so the widget can label rows too.
- **Where a second account comes from.** For Claude it is a second Claude Code
  config folder — the one you launch that account with via `CLAUDE_CONFIG_DIR`,
  such as `~/.claude-work`. Claude Code names that folder's Keychain item
  `Claude Code-credentials-<first 8 hex of sha256(folder path)>`; Limit Counter
  derives the same name, reads it (never writes it) and reads the folder's
  transcripts. For Codex it is a second `CODEX_HOME` folder with its own
  `auth.json`. Web-session and API-key providers (Cursor, Kimi, Qwen, MiMo,
  Ollama, Mistral, Meta, OpenRouter and the rest) take a second session or key
  exactly as the first. ChatGPT's local desktop cache is one install, one
  account, so it takes no extra accounts.
- **How it is stored.** Credentials, cached snapshots, reset-detector state,
  CloudKit status records and alert signatures are keyed by account. The primary
  account's keys are the bare provider keys, so nothing on disk or in iCloud
  moved when accounts arrived.
- **Account changes are not resets.** Every Claude reading carries a hashed
  fingerprint of the signed-in organisation and account (from the profile the
  app already fetches). When the fingerprint behind a slot changes — a `/login`
  to another account in the same config folder — the reset detector starts that
  slot's trail again instead of celebrating a "gifted reset" for a meter that
  merely belongs to someone else now. Codex and the API providers fingerprint
  from their account, project or team identifiers.
- **Where it shows.** Each account is its own card, right after its provider's
  primary card and carrying the label as a chip; the menu bar stacks a
  provider's accounts under one provider chip; the widget shows one card per
  account; notifications thread per account.

Set an account up from a provider's page in Setup: *Add account*, give it a
label, then grant its folder or import its session.

## Claude Code's Keychain item

Live Claude meters come from the OAuth token Claude Code keeps in the login
keychain (`Claude Code-credentials`, or `Claude Code-credentials-<hash>` for a
custom config folder). Reading it is opt-in: *Setup → Claude → Advanced → Read
Claude Code's sign-in from the Keychain*. How it is read matters, because it
used to put up "Limit Counter wants to access key …" every few hours, and
"Always Allow" never stuck.

- **Why the prompt kept coming back.** Claude Code rewrites its item with
  `security add-generic-password -U` every time it renews the token (verified
  against 2.1.295). macOS keeps two lists on a login-keychain item: the decrypt
  ACL (which executables are trusted) and the partition list (which code-signing
  partitions may use that trust without a password). The rewrite leaves the ACL
  entry "Always Allow" added for Limit Counter in place but resets the partition
  list to `apple-tool:` — so the next read needed the password again. CodexBar's
  issue tracker traced the same thing (steipete/CodexBar#3798, #367).
- **How it is read now.** The item is read the way Claude Code reads it: by
  running macOS's own `/usr/bin/security find-generic-password`. The tool is the
  item's creator, so every rewrite keeps trusting it, and nothing it does needs
  a prompt. Before the tool runs, Limit Counter inspects the item's access list
  (attributes only, never the secret) to confirm that trust; it never runs the
  tool blind.
- **Nothing in the background can prompt.** When the tool cannot be used, a
  background refresh reads in-process with Security.framework flagged
  non-interactive (`kSecUseAuthenticationUIFail`), which fails instead of
  asking — `LAContext.interactionNotAllowed` alone does not stop the legacy
  dialog. The card then keeps its last meters and says that a manual Refresh
  (the only read allowed to show the macOS dialog) will re-grant access.
- **Limit Counter never writes Claude Code's item.** A cross-app write would
  reset the CLI's own grant and make *it* ask for the password on every read.
  The one copy Limit Counter keeps is its own mirror item, without the refresh
  token, and it is replaced rather than prompted for if another build of the
  app wrote it.
- **What the tool is not.** It is not a way around the opt-in: the toggle above
  is the consent, and the log line `Read Claude Code's credential through
  /usr/bin/security` (subsystem `com.chrisizatt.LLMUsageCounter`, category
  `claude-oauth`) shows every such read.

## Safety Boundary

This project is intentionally designed around credentials the user explicitly provides.

- Store user-entered credentials in Keychain.
- Store only normalized quota snapshots in the shared cache.
- Do not scrape browser cookies.
- Do not read hidden auth state from Safari, Chrome, Keychain items owned by other apps, or CLI caches without an explicit user-driven import flow and a clear provider policy basis. Claude Code's keychain item is read only behind its opt-in, only ever read, and read the way the CLI itself reads it (see above).

## Codex Telemetry Setup

If you want to collect local Codex telemetry without enterprise billing:

1. Add this to `~/.codex/config.toml`:

```toml
[otel]
environment = "home"
exporter = "none"
log_user_prompt = false

[analytics]
enabled = true
```

2. Open the app on macOS and configure `Codex Telemetry`.
3. Point it at `~/.codex` or another Codex folder you control.

The app reads the local SQLite log store and local text logs only. OpenAI’s OTel export is optional and separate from any collector or hosting cost you choose to add later.

## Architecture

1. On macOS, `ProviderClient` fetches provider-specific usage data from local sources the user controls.
2. `SyncCoordinator` normalizes results into `QuotaSnapshot`.
3. `QuotaSnapshotStore` writes sanitized snapshots to App Group `UserDefaults` for the local app and widget.
4. `CloudKitSyncService` publishes the latest normalized snapshots to the user's own iCloud private database so iPhone can act as a viewer. See *iCloud sync* below for what that does and does not include.
5. On iOS, the app reads the last synced CloudKit state, caches it locally, and renders the same snapshot model.

## iCloud sync

Stated plainly, including the parts that are limitations rather than features.

**Where it goes.** Your own iCloud private database, in the container
`iCloud.com.chrisizatt.LLMUsageCounter` (`CloudKitSync.swift` uses
`container.privateCloudDatabase` and nothing else — no public or shared database,
no `CKShare`). There is no maintainer-operated server anywhere in the app, and
the maintainer cannot read what you sync.

**What is uploaded.** One record per provider holds its primary snapshot and
complete secondary-account list. Each account retains its label, opaque slot,
hashed identity, meter values, credit balances, banked resets, and fetch time.
Payload version 3 keeps the primary at the JSON root so older viewers can still
read it. New viewers replace an account list only after that provider's payload
has downloaded and validated; a failed fetch preserves its cached accounts. A
legacy primary-only payload cannot remove cached secondary accounts. Credentials
and raw provider responses stay on the Mac: no API keys, OAuth tokens, cookies,
session headers or folder grants are included. Account-aware alerts use the
existing signature field, so this upgrade needs no new CloudKit schema fields.

**Code updates and data updates are separate.** New sections and widget layouts
require a new iOS app/extension build as well as the Mac publisher build. The
shared dashboard already provides Usage Credits and Resets Available on both
platforms; iCloud supplies their values and account labels. Compact-layout
selection, visibility and drag ordering remain local to each device. iOS refreshes
on foreground entry, pull-to-refresh, its foreground timer, and system-granted
background opportunities. The app and Mac must use the same iCloud account and
CloudKit environment; a Mac notarisation does not install new code on iPhone.

**Push notifications.** Alert text can reach the iOS viewer through Apple Push
Notification service. The macOS app carries no `aps-environment` entitlement, so
its alerts are raised locally and never transit APNs.

**Deletion — a real limitation.** The app only ever writes. Both of its CloudKit
operations pass `recordIDsToDelete: []`, so nothing in the app deletes a record.
Removing a provider, clearing the local cache, or deleting your credentials does
*not* remove what has already been synced; those records stay in your iCloud
until you delete them yourself through iCloud's own storage management. There is
no in-app deletion path.

**Opt-out — a real limitation.** There is no switch. Sync runs whenever
`container.accountStatus()` reports an iCloud account is available, which is the
only gate in the code. To stop it, turn off iCloud for this app in System
Settings, or sign out of iCloud. Settings exposes sync *diagnostics* and a
subscription reinstall, not a disable control.

Both limitations are documented rather than fixed here on purpose: closing them
means adding a deletion path and an opt-out toggle, which is product work, not a
wording change.

## Releasing

The release scripts under `scripts/` run from a fresh clone on macOS and write
only inside the repository: `build/` for archives and exports, `dist/` for the
finished zip, `scratch/` for logs, all gitignored. Nothing is installed, tagged
or published unless you ask for it.

### Notarised macOS build

```sh
export LIMITCOUNTER_TEAM_ID=XXXXXXXXXX          # your Apple Developer team ID
export LIMITCOUNTER_NOTARY_PROFILE="My Notary"  # your notarytool keychain profile
scripts/build_and_notarise.sh
```

`build_and_notarise.sh` archives the `LLMUsageCounter` scheme for macOS,
exports it with Developer ID signing, submits the zip to Apple's notary
service, staples the ticket, zips the stapled bundle into `dist/` and proves
that the zip still verifies after a plain `unzip`. Its last line is the path
of the finished zip. Both variables are required; the script stops with a
message naming the missing one before anything is built. The team ID must
match the `DEVELOPMENT_TEAM` the project signs with. Store the notary
credentials once, with an app-specific password for your Apple ID:

```sh
xcrun notarytool store-credentials "$LIMITCOUNTER_NOTARY_PROFILE" --team-id "$LIMITCOUNTER_TEAM_ID"
```

- **Installing is opt-in.** `--install` (or `LIMITCOUNTER_INSTALL=1`) on either
  script quits Limit Counter after verification, keeps the existing
  `/Applications/Limit Counter.app` as a stamped backup, copies the verified
  build in and relaunches it. Without it the installed app is never touched.
- `scripts/finish_notarization.sh` resumes from the build recorded in
  `build/.current-notary-dir` (notarise, staple, zip, verify) without archiving
  again, for example after fixing the keychain profile.
- `scripts/run-release.command` and `scripts/run-notary.command` are
  double-clickable wrappers for the two scripts above; they log to
  `scratch/release-run.log` and `scratch/notary-run.log`. Set the two variables
  in your shell profile so Terminal passes them on.
- `scripts/watch_release.sh` follows `scratch/release-run.log` and prints one
  `DONE`, `FAILED` or `ACTION_REQUIRED` line when the run ends; its own trace
  goes to `scratch/`.
- `scripts/com.chrisizatt.limitcounter.release.plist.template` is a launchd
  job that runs one release build when loaded. The comment at its top shows how
  to fill in the checkout path and both variables.

### TestFlight archives

`scripts/archive_testflight.sh` prepares App Store Connect archives for iOS
and macOS into a new directory of your choice (`--help` lists the options). It
uploads nothing; upload through Xcode Organizer or Transporter after inspecting
the artifacts.

## Next Steps

1. Add local Codex session analytics as explicitly labeled local estimates, with model and cost breakdowns derived only from user-granted `~/.codex` data.
2. Add a first-party in-app sign-in flow for Codex so iOS does not rely on a macOS-exported session import.
3. Add provider-specific refresh cadence, retry/backoff, and explicit revoked/expired credential handling.
4. Apply the Liquid Glass styling pass inspired by `PodcastPreview` and `AVCMeter`.
