#!/bin/bash
# Double-clickable: run scripts/build_and_notarise.sh (archive, export, notarise,
# staple, zip, verify) and keep its output in scratch/release-run.log, which
# scripts/watch_release.sh follows. Needs LIMITCOUNTER_TEAM_ID and
# LIMITCOUNTER_NOTARY_PROFILE in the environment. Arguments pass through, so
# `scripts/run-release.command --install` also replaces the installed app.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
mkdir -p scratch
bash scripts/build_and_notarise.sh "$@" 2>&1 | tee scratch/release-run.log
