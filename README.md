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
4. `CloudKitSyncService` publishes the latest normalized snapshots to CloudKit so iPhone can act as a viewer.
5. On iOS, the app reads the last synced CloudKit state, caches it locally, and renders the same snapshot model.

## Next Steps

1. Replace the remaining mock clients with one adapter per provider, each using a provider-approved token or first-party OAuth flow.
2. Add local Codex session analytics as explicitly labeled local estimates, with model and cost breakdowns derived only from user-granted `~/.codex` data.
3. Add a first-party in-app sign-in flow for Codex so iOS does not rely on a macOS-exported session import.
4. Add provider-specific refresh cadence, retry/backoff, and explicit revoked/expired credential handling.
5. Apply the Liquid Glass styling pass inspired by `PodcastPreview` and `AVCMeter`.
