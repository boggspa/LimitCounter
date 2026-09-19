#!/bin/bash
cd "$(dirname "$0")/.." || exit 1
set -o pipefail
bash scripts/build_and_notarise.sh 2>&1 | tee scratch/release-run.log
