#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUTPUT="$ROOT_DIR/.build/claude-usage-tests"
mkdir -p "$(dirname "$OUTPUT")"

xcrun --sdk macosx swiftc \
  "$ROOT_DIR/Shared/Models/QuotaModels.swift" \
  "$ROOT_DIR/Shared/Storage/QuotaSnapshotStore.swift" \
  "$ROOT_DIR/Shared/Storage/TelemetryParseCache.swift" \
  "$ROOT_DIR/App/Providers/ProviderClient.swift" \
  "$ROOT_DIR/Tests/ClaudeUsageTests.swift" \
  -framework Security \
  -framework AppKit \
  -framework UniformTypeIdentifiers \
  -lsqlite3 \
  -o "$OUTPUT"

"$OUTPUT"
