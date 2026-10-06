#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUTPUT="$ROOT_DIR/.build/gemini-summary-tests"
mkdir -p "$(dirname "$OUTPUT")"

# The local-reader test drives `GeminiLocalStateReader`, which lives beside
# `GeminiProviderClient` and needs the provider protocol plus the stores
# `ProviderClient.swift` depends on.
xcrun --sdk macosx swiftc \
  "$ROOT_DIR/Shared/Models/QuotaModels.swift" \
  "$ROOT_DIR/Shared/Storage/QuotaSnapshotStore.swift" \
  "$ROOT_DIR/Shared/Storage/TelemetryParseCache.swift" \
  "$ROOT_DIR/App/Keychain/KeychainService.swift" \
  "$ROOT_DIR/App/Providers/ProviderClient.swift" \
  "$ROOT_DIR/App/Providers/GeminiProviderClient.swift" \
  "$ROOT_DIR/Tests/GeminiSummaryWindowTests.swift" \
  -lsqlite3 \
  -o "$OUTPUT"

"$OUTPUT"
