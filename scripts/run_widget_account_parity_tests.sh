#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUTPUT="$ROOT_DIR/.build/widget-account-parity-tests"
mkdir -p "$(dirname "$OUTPUT")"

xcrun --sdk macosx swiftc -D WIDGET_ACCOUNT_PARITY_TESTS \
  -target "$(uname -m)-apple-macosx26.0" \
  "$ROOT_DIR/Shared/Models/QuotaModels.swift" \
  "$ROOT_DIR/Shared/Models/MockData.swift" \
  "$ROOT_DIR/Shared/Models/ModelRateCatalog.swift" \
  "$ROOT_DIR/Shared/Models/ModelUsageAnalytics.swift" \
  "$ROOT_DIR/Shared/Storage/QuotaSnapshotStore.swift" \
  "$ROOT_DIR/Shared/Storage/ModelUsageLedger.swift" \
  "$ROOT_DIR/Shared/Views/GlassChrome.swift" \
  "$ROOT_DIR/Shared/Views/QuotaCardView.swift" \
  "$ROOT_DIR/Shared/Views/LLMActivityHeatmapView.swift" \
  "$ROOT_DIR/Widget/QuotaTimelineProvider.swift" \
  "$ROOT_DIR/Tests/WidgetAccountParityTests.swift" \
  -o "$OUTPUT"

"$OUTPUT"
