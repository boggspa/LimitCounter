# Limit Counter

SwiftUI prototype for a cross-platform quota tracker covering Codex, Claude, Devin, and Cursor.

## Current Shape

- Shared quota models and card views live in `Shared/`.
- The main app shell lives in `App/`.
- A real WidgetKit extension target is wired in `Widget/` and embedded into the app target with shared App Group storage.
- The Codex provider now has a real session-backed adapter that reads ChatGPT-plan 5-hour and 7-day usage from the same private usage surface used by Codex clients. OpenAI API has a separate official Admin API provider for project rate limits, 30-day token/request/cost analytics, projected monthly spend, per-provider budget thresholds, spike callouts, and top-model drivers. Claude, Devin, and Cursor still use mock adapters while their real integrations are designed.
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

## Safety Boundary

This project is intentionally designed around credentials the user explicitly provides.

- Store user-entered credentials in Keychain.
- Store only normalized quota snapshots in the shared cache.
- Do not scrape browser cookies.
- Do not read hidden auth state from Safari, Chrome, Keychain items owned by other apps, or CLI caches without an explicit user-driven import flow and a clear provider policy basis.

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

**What is uploaded.** One record per provider, holding the normalized snapshot:
provider, display name, plan name, meter values and totals, reset dates, fetch
timestamps, a status hash, a payload version, and any alert title/body text. No
credentials of any kind — no API keys, OAuth tokens, cookies or session headers,
and no raw provider API responses. Those stay in the macOS Keychain, which the
widget extension has no entitlement to reach.

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

## Next Steps

1. Replace the remaining mock clients with one adapter per provider, each using a provider-approved token or first-party OAuth flow.
2. Add local Codex session analytics as explicitly labeled local estimates, with model and cost breakdowns derived only from user-granted `~/.codex` data.
3. Add a first-party in-app sign-in flow for Codex so iOS does not rely on a macOS-exported session import.
4. Add provider-specific refresh cadence, retry/backoff, and explicit revoked/expired credential handling.
5. Apply the Liquid Glass styling pass inspired by `PodcastPreview` and `AVCMeter`.
