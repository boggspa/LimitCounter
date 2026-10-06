#!/usr/bin/env bash
# Build the notarised macOS release: archive, export with Developer ID signing,
# then hand over to scripts/finish_notarization.sh to notarise, staple, zip into
# dist/ and verify. Writes only under the repository (build/, dist/) and ends by
# printing the path of the finished zip. Replacing /Applications/Limit Counter.app
# is opt-in: pass --install or set LIMITCOUNTER_INSTALL=1. Configuration comes
# from the environment; scripts/release_env.sh documents LIMITCOUNTER_TEAM_ID and
# LIMITCOUNTER_NOTARY_PROFILE.
set -euo pipefail

usage() {
    cat <<'USAGE'
Usage: scripts/build_and_notarise.sh [--install]

Archives the LLMUsageCounter scheme for macOS, exports it with Developer ID
signing, then runs scripts/finish_notarization.sh to notarise, staple, zip into
dist/ and verify the result. Requires LIMITCOUNTER_TEAM_ID and
LIMITCOUNTER_NOTARY_PROFILE in the environment (see scripts/release_env.sh).

Options:
  --install     After verification, replace /Applications/Limit Counter.app with
                the new build and relaunch it (same as LIMITCOUNTER_INSTALL=1).
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
command -v xcodebuild >/dev/null || fail 'xcodebuild is required.'

STAMP=$(date "+%Y%m%d-%H%M%S")
NOTARY_DIR="$ROOT_DIR/build/notary-$STAMP"
mkdir -p "$NOTARY_DIR"

cat <<EOP > "$NOTARY_DIR/ExportOptions.plist"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>destination</key>
	<string>export</string>
	<key>iCloudContainerEnvironment</key>
	<string>Production</string>
	<key>method</key>
	<string>developer-id</string>
	<key>signingStyle</key>
	<string>automatic</string>
	<key>teamID</key>
	<string>$TEAM_ID</string>
</dict>
</plist>
EOP

echo "$STAMP" > "$NOTARY_DIR/.stamp"
echo "$NOTARY_DIR" > "$ROOT_DIR/build/.current-notary-dir"

run_logged() {
    local log_path=$1
    shift
    if ! "$@" > "$log_path" 2>&1; then
        printf 'xcodebuild failed; the full log is %s\n' "$log_path" >&2
        tail -n 40 "$log_path" >&2
        exit 1
    fi
}

echo "Archiving..."
run_logged "$NOTARY_DIR/archive.log" xcodebuild archive \
    -project "$ROOT_DIR/LLMUsageCounter.xcodeproj" \
    -scheme LLMUsageCounter \
    -configuration Release \
    -allowProvisioningUpdates \
    -destination "generic/platform=macOS" \
    -archivePath "$NOTARY_DIR/LimitCounter.xcarchive" \
    -derivedDataPath "$NOTARY_DIR/derived"

echo "Exporting..."
run_logged "$NOTARY_DIR/export.log" xcodebuild -exportArchive \
    -allowProvisioningUpdates \
    -archivePath "$NOTARY_DIR/LimitCounter.xcarchive" \
    -exportOptionsPlist "$NOTARY_DIR/ExportOptions.plist" \
    -exportPath "$NOTARY_DIR/export"

echo "Zipping..."
NOTARY_ZIP="$NOTARY_DIR/LimitCounter.zip"
# Strip resource forks, extended attributes and ACLs so the submitted archive has
# the same shape as the one published to users: no AppleDouble entries inside the
# signed bundle. See finish_notarization.sh for why those break a plain `unzip`.
ditto -c -k --keepParent --norsrc --noextattr --noacl "$NOTARY_DIR/export/Limit Counter.app" "$NOTARY_ZIP"
echo "$NOTARY_ZIP" > "$ROOT_DIR/build/.current-notary-zip"

echo "Running finish_notarization.sh..."
if [[ "$INSTALL" == true ]]; then
    "$ROOT_DIR/scripts/finish_notarization.sh" --install
else
    "$ROOT_DIR/scripts/finish_notarization.sh"
fi
