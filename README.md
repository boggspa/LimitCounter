# LLM Usage Counter

SwiftUI prototype for a cross-platform quota tracker covering Codex, Claude, Windsurf, and Cursor.

## Current Shape

- Shared quota models and card views live in `Shared/`.
- The main app shell lives in `App/`.
- A real WidgetKit extension target is wired in `Widget/` and embedded into the app target with shared App Group storage.
- The Codex provider now has a real session-backed adapter that reads ChatGPT-plan 5-hour and 7-day usage from the same private usage surface used by Codex clients. Claude, Windsurf, and Cursor still use mock adapters while their real integrations are designed.
- A Codex Telemetry provider can read local Codex log folders and turn structured event logs into activity counts and token summaries.

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
2. Add a first-party in-app sign-in flow for Codex so iOS does not rely on a macOS-exported session import.
3. Add provider-specific refresh cadence, retry/backoff, and explicit revoked/expired credential handling.
4. Apply the Liquid Glass styling pass inspired by `PodcastPreview` and `AVCMeter`.
