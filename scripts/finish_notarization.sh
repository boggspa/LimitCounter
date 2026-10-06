#!/usr/bin/env bash
# Notarise, staple, zip and verify the build that scripts/build_and_notarise.sh
# last archived and exported (recorded in build/.current-notary-dir), so a run
# can be resumed after a notarisation failure without archiving again.
# Configuration comes from the environment; scripts/release_env.sh documents
# LIMITCOUNTER_TEAM_ID and LIMITCOUNTER_NOTARY_PROFILE. Store the notary
# credentials once, with an app-specific password for your Apple ID:
#
#   xcrun notarytool store-credentials "$LIMITCOUNTER_NOTARY_PROFILE" --team-id "$LIMITCOUNTER_TEAM_ID"
#
# Writes only under the repository (build/, dist/) and ends by printing the path
# of the finished zip. Replacing /Applications/Limit Counter.app is opt-in: pass
# --install or set LIMITCOUNTER_INSTALL=1.
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: scripts/finish_notarization.sh [--install]

Submits the zip recorded by scripts/build_and_notarise.sh to Apple's notary
service, staples the ticket, zips the stapled bundle into dist/ and proves the
zip still verifies after a plain unzip. Requires LIMITCOUNTER_TEAM_ID and
LIMITCOUNTER_NOTARY_PROFILE in the environment (see scripts/release_env.sh).

Options:
  --install     After verification, quit Limit Counter, keep the existing
                /Applications/Limit Counter.app as a stamped backup, copy the
                new build in and relaunch it (same as LIMITCOUNTER_INSTALL=1).
                Without it nothing outside the repository is touched.
  -h, --help    Show this help.
USAGE
}

fail() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}

INSTALL=false
while (($#)); do
  case "$1" in
    --install) INSTALL=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) fail "Unknown argument: $1 (use --help)." ;;
  esac
done

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
# shellcheck source=scripts/release_env.sh
source "$ROOT_DIR/scripts/release_env.sh"

[[ -f build/.current-notary-dir && -f build/.current-notary-zip ]] ||
  fail 'No build to finish: build/.current-notary-dir is missing. Run scripts/build_and_notarise.sh first.'
NOTARY_DIR="$(cat build/.current-notary-dir)"
NOTARY_ZIP="$(cat build/.current-notary-zip)"
[[ -d "$NOTARY_DIR" && -f "$NOTARY_ZIP" && -f "$NOTARY_DIR/.stamp" ]] ||
  fail "The recorded build is gone ($NOTARY_DIR). Run scripts/build_and_notarise.sh again."
STAMP="$(cat "$NOTARY_DIR/.stamp")"
APP="$NOTARY_DIR/export/Limit Counter.app"

install_app() {
  local installed="/Applications/Limit Counter.app"
  local backup="/Applications/Limit Counter.app.backup-$STAMP-stapled"
  echo "Installing into /Applications, as requested..."
  osascript -e 'quit app "Limit Counter"' 2>/dev/null || true
  sleep 3
  if [ -d "$installed" ]; then
  mv "$installed" "$backup"
  echo "Previous install kept at: $backup"
  fi
  ditto "$APP" "$installed"
  open "$installed"
  echo "Installed and relaunched the stapled build."
}

xcrun notarytool submit "$NOTARY_ZIP" \
  --keychain-profile "$NOTARY_PROFILE" \
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
echo "Notarized and stapled: $FINAL_ZIP"

# Prove the artifact survives the extractor a user will actually reach for. A zip
# that only validates under `ditto` is how a download ends up reported as
# "damaged" by anyone who unzips it from a terminal, and the failure is invisible
# on the machine that built it.
VERIFY_DIR="$(mktemp -d "$NOTARY_DIR/verify-XXXXXX")"
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

# Record the zip only now that it has verified, so these pointers never name a
# build that failed. Keep the "latest" pointer authoritative: it existed long
# before this script wrote it and had drifted to an August build, which is worse
# than absent, because it reads like the current release and quietly is not.
echo "$FINAL_ZIP" > build/.current-final-zip
echo "$FINAL_ZIP" > "$ROOT_DIR/dist/latest-dist-zip.txt"

if [[ "$INSTALL" == true ]]; then
  install_app
fi
echo "Release complete: $FINAL_ZIP"
