#!/usr/bin/env bash
set -e

osascript -e 'quit app "Limit Counter"' || true

STAMP=$(date "+%Y%m%d-%H%M%S")
NOTARY_DIR="build/notary-$STAMP"
mkdir -p "$NOTARY_DIR"

cat << 'INNER_EOF' > "$NOTARY_DIR/ExportOptions.plist"
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
	<string>8CZML8FK2D</string>
</dict>
</plist>
INNER_EOF

echo "$STAMP" > "$NOTARY_DIR/.stamp"
echo "$PWD/$NOTARY_DIR" > build/.current-notary-dir

echo "Archiving..."
xcodebuild archive \
    -project LLMUsageCounter.xcodeproj \
    -scheme LLMUsageCounter \
    -configuration Release \
    -allowProvisioningUpdates \
    -destination "generic/platform=macOS" \
    -archivePath "$NOTARY_DIR/LimitCounter.xcarchive" \
    -derivedDataPath "$NOTARY_DIR/derived" > "$NOTARY_DIR/archive.log"

echo "Exporting..."
xcodebuild -exportArchive \
    -allowProvisioningUpdates \
    -archivePath "$NOTARY_DIR/LimitCounter.xcarchive" \
    -exportOptionsPlist "$NOTARY_DIR/ExportOptions.plist" \
    -exportPath "$NOTARY_DIR/export" > "$NOTARY_DIR/export.log"

echo "Zipping..."
NOTARY_ZIP="$PWD/$NOTARY_DIR/LimitCounter.zip"
# Strip resource forks, extended attributes and ACLs so the submitted archive has
# the same shape as the one published to users: no AppleDouble entries inside the
# signed bundle. See finish_notarization.sh for why those break a plain `unzip`.
ditto -c -k --keepParent --norsrc --noextattr --noacl "$NOTARY_DIR/export/Limit Counter.app" "$NOTARY_ZIP"
echo "$NOTARY_ZIP" > build/.current-notary-zip

echo "Running finish_notarization.sh..."
./scripts/finish_notarization.sh
