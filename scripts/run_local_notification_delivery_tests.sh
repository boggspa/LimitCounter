#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUTPUT_DIR="$ROOT_DIR/.build/local-notification-delivery-tests"
mkdir -p "$OUTPUT_DIR"

# The iOS publisher uses the same Foundation/UserNotifications APIs as macOS.
# Compile its real implementation here by removing only the platform wrapper.
sed '1s/^#if os(iOS)$/#if os(macOS)/' \
  "$ROOT_DIR/App/LocalNotificationPublisher.swift" \
  > "$OUTPUT_DIR/LocalNotificationPublisher.swift"

xcrun --sdk macosx swiftc \
  "$ROOT_DIR/Shared/Models/QuotaModels.swift" \
  "$ROOT_DIR/Shared/Models/CloudAlertPayload.swift" \
  "$ROOT_DIR/Shared/Storage/QuotaSnapshotStore.swift" \
  "$ROOT_DIR/Shared/Storage/TelemetryParseCache.swift" \
  "$ROOT_DIR/Shared/Notifications/AlertNotificationContent.swift" \
  "$ROOT_DIR/App/MacLocalNotificationPublisher.swift" \
  "$OUTPUT_DIR/LocalNotificationPublisher.swift" \
  "$ROOT_DIR/Tests/LocalNotificationDeliveryTests.swift" \
  -o "$OUTPUT_DIR/run"

"$OUTPUT_DIR/run"
