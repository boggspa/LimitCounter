#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUTPUT="$ROOT_DIR/.build/usage-alert-builder-tests"
mkdir -p "$(dirname "$OUTPUT")"

xcrun --sdk macosx swiftc \
  "$ROOT_DIR/Shared/Models/QuotaModels.swift" \
  "$ROOT_DIR/Shared/Models/CloudAlertPayload.swift" \
  "$ROOT_DIR/Tests/UsageAlertBuilderTests.swift" \
  -o "$OUTPUT"

"$OUTPUT"
