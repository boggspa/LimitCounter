#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUTPUT="${TMPDIR:-/tmp}/grok-usage-tests"

cd "$ROOT_DIR"

xcrun --sdk macosx swiftc -enable-testing \
  Shared/Models/QuotaModels.swift \
  Shared/Storage/QuotaSnapshotStore.swift \
  App/Providers/ProviderClient.swift \
  Tests/GrokUsageTests.swift \
  -o "$OUTPUT" \
  -framework Security \
  -framework AppKit \
  -framework UniformTypeIdentifiers \
  -lsqlite3

"$OUTPUT"
