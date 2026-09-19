#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUTPUT="${TMPDIR:-/tmp}/quota-period-grouping-tests"

cd "$ROOT_DIR"

xcrun --sdk macosx swiftc -enable-testing \
  Shared/Models/QuotaModels.swift \
  Shared/Storage/QuotaSnapshotStore.swift \
  Tests/QuotaPeriodGroupingTests.swift \
  -o "$OUTPUT" \
  -framework AppKit

"$OUTPUT"
