#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUTPUT="${TMPDIR:-/tmp}/widget-asset-tests"

cd "$ROOT_DIR"

xcrun --sdk macosx swiftc -enable-testing \
  Shared/Models/QuotaModels.swift \
  Tests/WidgetAssetCatalogTests.swift \
  -o "$OUTPUT" \
  -framework AppKit

"$OUTPUT" "$ROOT_DIR"
