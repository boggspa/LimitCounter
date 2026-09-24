#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUTPUT="${TMPDIR:-/tmp}/provider-account-tests"

cd "$ROOT_DIR"

xcrun --sdk macosx swiftc -enable-testing \
  Shared/Models/QuotaModels.swift \
  Shared/Models/CloudAlertPayload.swift \
  Shared/Models/QuotaResetDetector.swift \
  Shared/Storage/QuotaSnapshotStore.swift \
  Shared/Storage/TelemetryParseCache.swift \
  App/Keychain/KeychainService.swift \
  App/Providers/ProviderClient.swift \
  App/Providers/GeminiProviderClient.swift \
  App/Providers/AntigravityProviderClient.swift \
  App/Providers/SpendProviderClients.swift \
  App/Providers/ProviderSetupPolicy.swift \
  Tests/ProviderAccountTests.swift \
  -o "$OUTPUT" \
  -framework Security \
  -framework AppKit \
  -framework WebKit \
  -framework UniformTypeIdentifiers \
  -lsqlite3

"$OUTPUT"
