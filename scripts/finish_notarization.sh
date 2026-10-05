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

APP_VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")
APP_BUILD=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist")
FINAL_ZIP="$ROOT_DIR/dist/LimitCounter-$APP_VERSION-$APP_BUILD-macOS26-notarized-$STAMP.zip"
mkdir -p "$ROOT_DIR/dist"
# --norsrc/--noextattr/--noacl matter. Without them ditto stores every extended
# attribute as an AppleDouble "._" entry *inside* the signed bundle — 27 of them
# in a 16 MB app. Archive Utility and `ditto -x -k` fold those back into xattrs
# and the bundle verifies, but a plain `unzip` materialises them as real files,
# which breaks the code seal ("a sealed resource is missing or invalid") and
# Gatekeeper refuses to launch. What is being dropped — com.apple.provenance and
# com.apple.macl — is added by macOS at runtime and is not part of the signature,
# so the CDHash is unchanged.
ditto -c -k --keepParent --norsrc --noextattr --noacl "$APP" "$FINAL_ZIP"
echo "$FINAL_ZIP" > build/.current-final-zip
# Keep the "latest" pointer authoritative. It existed long before this script
# wrote it and had drifted to an August build, which is worse than absent: it
# reads like the current release and quietly is not.
echo "$FINAL_ZIP" > "$ROOT_DIR/dist/latest-dist-zip.txt"
echo "Notarized and stapled: $FINAL_ZIP"

# Prove the artifact survives the extractor a user will actually reach for. A zip
# that only validates under `ditto` is how a download ends up reported as
# "damaged" by anyone who unzips it from a terminal, and the failure is invisible
# on the machine that built it.
VERIFY_DIR="$(mktemp -d "${TMPDIR:-/tmp}/limitcounter-verify-XXXXXX")"
trap 'rm -rf "$VERIFY_DIR"' EXIT
unzip -q "$FINAL_ZIP" -d "$VERIFY_DIR"
if find "$VERIFY_DIR" -name '._*' | grep -q .; then
  echo "error: AppleDouble entries leaked into the zip; the code seal will not survive an unzip." >&2
  exit 1
fi
codesign --verify --deep --strict --verbose=2 "$VERIFY_DIR/Limit Counter.app"
spctl --assess --type execute --verbose=4 "$VERIFY_DIR/Limit Counter.app"
xcrun stapler validate "$VERIFY_DIR/Limit Counter.app"
echo "Verified: the zip survives a plain unzip."

# Reinstall the stapled build over the running copy.
osascript -e 'quit app "Limit Counter"' 2>/dev/null || true
sleep 3
if [ -d "/Applications/Limit Counter.app" ]; then
  mv "/Applications/Limit Counter.app" "/Applications/Limit Counter.app.backup-$STAMP-stapled"
fi
ditto "$APP" "/Applications/Limit Counter.app"
open "/Applications/Limit Counter.app"
echo "Installed and relaunched the stapled build."
