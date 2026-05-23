# CodexUsageKit

Reusable Swift package for reading Codex usage status from user-controlled credentials and local telemetry.

## What It Does

- Imports a user-selected Codex auth JSON file.
- Fetches live Codex usage from `https://chatgpt.com/backend-api/wham/usage`.
- Normalizes 5-hour, weekly, additional rate-limit, and credits data into `QuotaSnapshot`.
- Reads optional local Codex telemetry folders for activity history and audit views.
- Provides quota recovery signals without owning persistence.

## Safety Boundary

- No Keychain, App Group, CloudKit, widget, or UI dependency.
- No raw response-body logging.
- No token logging.
- The package never imports `refresh_token`, `id_token`, or `OPENAI_API_KEY`.
- Calling apps own credential storage, snapshot storage, task policy, and all resume decisions.

## Basic Usage

```swift
import CodexUsageKit

let credential = try CodexAuthFileImporter.importCredential(from: authJSONURL)
let snapshot = try await CodexUsageClient().fetchSnapshot(credential: credential)

let telemetry = try await CodexTelemetryReader().readSnapshot(rootURL: codexRootURL)
```

If fetching fails, treat usage as unknown and stop for review. Do not use this package to bypass usage limits.
