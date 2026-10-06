#!/bin/bash
# Double-clickable: resume notarisation for the build scripts/build_and_notarise.sh
# last archived and exported, by running scripts/finish_notarization.sh (notarise,
# staple, zip, verify) with its output in scratch/notary-run.log. It does not
# archive or build again; use run-release.command for a full run. Needs
# LIMITCOUNTER_TEAM_ID and LIMITCOUNTER_NOTARY_PROFILE in the environment.
# Arguments pass through, so `scripts/run-notary.command --install` also
# replaces the installed app.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
mkdir -p scratch
bash scripts/finish_notarization.sh "$@" 2>&1 | tee scratch/notary-run.log
