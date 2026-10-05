#!/usr/bin/env bash
# Prepare native iOS/macOS App Store Connect artifacts using Xcode's signed-in
# account. This is separate from the Developer ID notarization/install workflow.
set -euo pipefail
umask 077

usage() {
    cat <<'EOF'
Usage: scripts/archive_testflight.sh [all|ios|macos] --output-dir PATH [options]

Archives and locally exports Release builds for App Store Connect/TestFlight.
The output directory must not already exist; previous artifacts are preserved.
Uses the developer account already configured in Xcode for automatic signing.

Options:
  --output-dir PATH    New local directory for archives, exports, and build logs.
  --build-number N     Override CURRENT_PROJECT_VERSION for app and widget.
  --dry-run            Print the plan without creating files or invoking Xcode.
  -h, --help           Show this help.

Examples:
  scripts/archive_testflight.sh all --output-dir build/testflight-build-2
  scripts/archive_testflight.sh ios --output-dir build/testflight-ios-3 --build-number 3

No builds are uploaded or installed. Inspect the artifacts before uploading the
archives through Xcode Organizer or the exported packages through Transporter.
EOF
}

fail() {
    printf 'Error: %s\n' "$*" >&2
    exit 1
}

platform=all
platform_set=false
output_dir=
build_number=
dry_run=false
while (($#)); do
    case "$1" in
        all|ios|macos)
            [[ "$platform_set" == false ]] || fail 'Specify only one platform.'
            platform=$1
            platform_set=true
            shift
            ;;
        --output-dir|--build-number)
            (($# >= 2)) || fail "$1 requires a value."
            [[ -n "$2" && "$2" != --* ]] || fail "$1 requires a value."
            if [[ "$1" == --output-dir ]]; then
                [[ -z "$output_dir" ]] || fail 'Specify --output-dir only once.'
                output_dir=$2
            else
                [[ -z "$build_number" ]] || fail 'Specify --build-number only once.'
                build_number=$2
            fi
            shift 2
            ;;
        --dry-run) dry_run=true; shift ;;
        -h|--help) usage; exit 0 ;;
        *) fail "Unknown argument: $1 (use --help)." ;;
    esac
done

[[ -n "$output_dir" ]] || fail '--output-dir is required (use --help).'
if [[ -n "$build_number" && ! "$build_number" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]]; then
    fail '--build-number must contain one to three dot-separated integers.'
fi

repo_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
project_path="$repo_dir/LLMUsageCounter.xcodeproj"
[[ -d "$project_path" ]] || fail "Project not found: $project_path"
# Resolve relative output paths against the caller's directory, not the repo.
[[ "$output_dir" == /* ]] || output_dir="$PWD/$output_dir"
[[ ! -e "$output_dir" && ! -L "$output_dir" ]] || fail "Output already exists: $output_dir"

platforms=()
case "$platform" in
    all) platforms=(ios macos) ;;
    *) platforms=("$platform") ;;
esac

print_command() {
    printf '  '
    printf '%q ' "$@"
    printf '\n'
}

run_logged() {
    local log_path=$1
    shift
    if ! "$@" >"$log_path" 2>&1; then
        printf 'Xcode failed. Preserved log and artifacts: %s\n' "$log_path" >&2
        tail -n 40 "$log_path" >&2
        exit 1
    fi
}

if [[ "$dry_run" == false ]]; then
    command -v xcodebuild >/dev/null || fail 'xcodebuild is required.'
    # mkdir (without -p for the final directory) also rejects concurrent reuse.
    mkdir -p -- "$(dirname -- "$output_dir")"
    mkdir -- "$output_dir"
fi

for selected_platform in "${platforms[@]}"; do
    case "$selected_platform" in
        ios) destination='generic/platform=iOS' ;;
        macos) destination='generic/platform=macOS' ;;
    esac
    platform_dir="$output_dir/$selected_platform"
    archive_path="$platform_dir/LimitCounter.xcarchive"
    options_path="$platform_dir/ExportOptions.plist"
    archive_command=(
        xcodebuild archive
        -project "$project_path"
        -scheme LLMUsageCounter
        -configuration Release
        -destination "$destination"
        -archivePath "$archive_path"
        -derivedDataPath "$platform_dir/DerivedData"
        -allowProvisioningUpdates
        CODE_SIGN_STYLE=Automatic
        ONLY_ACTIVE_ARCH=NO
    )
    if [[ -n "$build_number" ]]; then
        archive_command+=("CURRENT_PROJECT_VERSION=$build_number")
    fi
    export_command=(
        xcodebuild -exportArchive
        -archivePath "$archive_path"
        -exportOptionsPlist "$options_path"
        -exportPath "$platform_dir/export"
        -allowProvisioningUpdates
    )

    printf '%s: archive and local App Store Connect export\n' "$selected_platform"
    if [[ "$dry_run" == true ]]; then
        print_command "${archive_command[@]}"
        printf '  Export options: app-store-connect, destination=export, automatic signing, CloudKit Production, unchanged build number; archive team.\n'
        print_command "${export_command[@]}"
        continue
    fi

    mkdir -- "$platform_dir"
    # teamID intentionally defaults to the archive's team. Keep signing
    # entitlements in the project; do not substitute the Developer ID profiles.
    # Omit testFlightInternalTestingOnly to retain external-testing eligibility.
    cat >"$options_path" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>app-store-connect</string>
    <key>destination</key>
    <string>export</string>
    <key>signingStyle</key>
    <string>automatic</string>
    <key>iCloudContainerEnvironment</key>
    <string>Production</string>
    <key>manageAppVersionAndBuildNumber</key>
    <false/>
    <key>generateAppStoreInformation</key>
    <true/>
    <key>uploadSymbols</key>
    <true/>
</dict>
</plist>
EOF
    plutil -lint "$options_path" >/dev/null
    run_logged "$platform_dir/archive.log" "${archive_command[@]}"
    run_logged "$platform_dir/export.log" "${export_command[@]}"
    printf '  Archive: %s\n  Export: %s\n' "$archive_path" "$platform_dir/export"
done

if [[ "$dry_run" == true ]]; then
    printf 'Dry run complete. No files created or Xcode operations performed.\n'
else
    printf 'Local preparation complete: %s\nNo builds were uploaded or installed.\n' "$output_dir"
fi
