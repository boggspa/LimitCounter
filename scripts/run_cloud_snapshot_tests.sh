#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUTPUT="$ROOT_DIR/.build/cloud-snapshot-tests"
mkdir -p "$(dirname "$OUTPUT")"

xcrun --sdk macosx swiftc \
  "$ROOT_DIR/Shared/Models/QuotaModels.swift" \
  "$ROOT_DIR/Shared/Storage/QuotaSnapshotStore.swift" \
  "$ROOT_DIR/Tests/CloudSnapshotPayloadTests.swift" \
  -o "$OUTPUT"

"$OUTPUT"
