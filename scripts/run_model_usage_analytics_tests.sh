#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUTPUT="$ROOT_DIR/.build/model-usage-analytics-tests"
mkdir -p "$(dirname "$OUTPUT")"
xcrun --sdk macosx swiftc -default-isolation MainActor \
  "$ROOT_DIR/Shared/Models/QuotaModels.swift" \
  "$ROOT_DIR/Shared/Models/ModelUsageAnalytics.swift" \
  "$ROOT_DIR/Shared/Models/ModelRateCatalog.swift" \
  "$ROOT_DIR/Shared/Storage/ModelUsageLedger.swift" \
  "$ROOT_DIR/App/Providers/ModelUsageLogScanner.swift" \
  "$ROOT_DIR/App/Views/ModelUsageDashboardData.swift" \
  "$ROOT_DIR/Tests/ModelUsageAnalyticsTests.swift" \
  -lsqlite3 -o "$OUTPUT"
"$OUTPUT"
