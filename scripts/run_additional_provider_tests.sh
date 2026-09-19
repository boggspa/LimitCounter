#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUTPUT="${TMPDIR:-/tmp}/additional-provider-usage-tests"

cd "$ROOT_DIR"

xcrun --sdk macosx swiftc -enable-testing \
  Shared/Models/QuotaModels.swift \
  Shared/Storage/QuotaSnapshotStore.swift \
  Shared/Storage/TelemetryParseCache.swift \
  App/Keychain/KeychainService.swift \
  App/Providers/ProviderClient.swift \
  App/Providers/AntigravityProviderClient.swift \
  App/Providers/SpendProviderClients.swift \
  Tests/AdditionalProviderUsageTests.swift \
  -o "$OUTPUT" \
  -framework Security \
  -framework AppKit \
  -framework WebKit \
  -framework UniformTypeIdentifiers \
  -lsqlite3

"$OUTPUT"
