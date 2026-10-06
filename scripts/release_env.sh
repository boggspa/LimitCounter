#!/usr/bin/env bash
# Sourced by build_and_notarise.sh and finish_notarization.sh. Resolves the
# notarised-release configuration from the environment and stops with a clear
# message when it is missing, so a long archive never runs for nothing. Nothing
# here is machine-specific: a cloner sets the variables for their own team and
# keychain. The values this repository has been released with so far, for
# reference: LIMITCOUNTER_TEAM_ID=8CZML8FK2D (the DEVELOPMENT_TEAM in
# LLMUsageCounter.xcodeproj) and LIMITCOUNTER_NOTARY_PROFILE="Taskwraith Notary".
#
#   LIMITCOUNTER_TEAM_ID         Ten-character Apple Developer team ID written
#                                into the Developer ID export options. It must
#                                match the team the archive is signed with.
#   LIMITCOUNTER_NOTARY_PROFILE  Name of the notarytool keychain profile created
#                                once, with an app-specific password, by
#                                xcrun notarytool store-credentials "<profile>" \
#                                    --team-id "$LIMITCOUNTER_TEAM_ID"
#   LIMITCOUNTER_INSTALL         1 to replace /Applications/Limit Counter.app with
#                                the verified build and relaunch it, the same as
#                                passing --install. Unset or 0 leaves the
#                                installed app alone.
#
# Neither value is a credential: the team ID is in every signed binary and the
# profile name only labels a login-keychain item on the machine that runs this.
# Sets TEAM_ID and NOTARY_PROFILE, and sets INSTALL=true when the environment
# asks for installation (a caller may already have set it from --install).

release_env_fail() {
    printf 'Error: %s\n' "$*" >&2
    exit 1
}

TEAM_ID=${LIMITCOUNTER_TEAM_ID-}
NOTARY_PROFILE=${LIMITCOUNTER_NOTARY_PROFILE-}

[[ -n "$TEAM_ID" ]] ||
    release_env_fail 'LIMITCOUNTER_TEAM_ID is not set. Export your ten-character Apple Developer team ID (the DEVELOPMENT_TEAM in LLMUsageCounter.xcodeproj) and run again.'
[[ "$TEAM_ID" =~ ^[A-Z0-9]{10}$ ]] ||
    release_env_fail "LIMITCOUNTER_TEAM_ID must be a ten-character Apple Developer team ID, got: $TEAM_ID"
[[ -n "$NOTARY_PROFILE" ]] ||
    release_env_fail "LIMITCOUNTER_NOTARY_PROFILE is not set. Export the name of the notarytool keychain profile you stored with: xcrun notarytool store-credentials \"<profile>\" --team-id $TEAM_ID"

: "${INSTALL:=false}"
case "${LIMITCOUNTER_INSTALL-}" in
    1) INSTALL=true ;;
    ''|0) ;;
    *) release_env_fail "LIMITCOUNTER_INSTALL must be 1 (install) or 0/unset (do not install), got: $LIMITCOUNTER_INSTALL" ;;
esac
