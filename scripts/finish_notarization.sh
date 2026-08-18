#!/usr/bin/env bash
# Resumes notarization for the build already archived, exported and zipped by the
# release run recorded in build/.current-notary-dir. Run after the "Taskwraith
# Notary" keychain profile holds a valid app-specific password:
#
#   xcrun notarytool store-credentials "Taskwraith Notary" --team-id 8CZML8FK2D
#
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

PROFILE="Taskwraith Notary"
NOTARY_DIR="$(cat build/.current-notary-dir)"
NOTARY_ZIP="$(cat build/.current-notary-zip)"
STAMP="$(cat "$NOTARY_DIR/.stamp")"
APP="$NOTARY_DIR/export/Limit Counter.app"

xcrun notarytool submit "$NOTARY_ZIP" \
  --keychain-profile "$PROFILE" \
  --wait --timeout 30m \
  --output-format json | tee "$NOTARY_DIR/notary-submit.json"

xcrun stapler staple "$APP" 2>&1 | tee "$NOTARY_DIR/staple.log"
xcrun stapler validate "$APP"
spctl --assess --type execute --verbose=4 "$APP"

FINAL_ZIP="$ROOT_DIR/dist/LimitCounter-1.0-1-macOS26-notarized-$STAMP.zip"
mkdir -p "$ROOT_DIR/dist"
ditto -c -k --keepParent "$APP" "$FINAL_ZIP"
echo "$FINAL_ZIP" > build/.current-final-zip
echo "Notarized and stapled: $FINAL_ZIP"

# Reinstall the stapled build over the running copy.
osascript -e 'quit app "Limit Counter"' 2>/dev/null || true
sleep 3
if [ -d "/Applications/Limit Counter.app" ]; then
  mv "/Applications/Limit Counter.app" "/Applications/Limit Counter.app.backup-$STAMP-stapled"
fi
ditto "$APP" "/Applications/Limit Counter.app"
open "/Applications/Limit Counter.app"
echo "Installed and relaunched the stapled build."
