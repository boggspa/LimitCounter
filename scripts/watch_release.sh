#!/usr/bin/env bash
# Watch the mac release pipeline started through scripts/run-release.command or
# the launchd job (both log to scratch/release-run.log) until it finishes with a
# verified zip in dist/, has also installed and relaunched when --install was
# requested, or fails. Its own trace stays in scratch/ too.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
mkdir -p "$ROOT/scratch"
TRACE="$ROOT/scratch/watch_release_$$.log"
RUNLOG="$ROOT/scratch/release-run.log"
APP="/Applications/Limit Counter.app"
START_MTIME=$(stat -f %m "$APP" 2>/dev/null || echo 0)
WATCH_START=$(date +%s)
DEADLINE=$((SECONDS + 2700))
WARNED_START=0

why() { tail -40 "$RUNLOG" 2>/dev/null | tr -d '\r' | tr '\n' ' '; }

fresh_dir() {
  local n=$1
  [ -n "$n" ] || return 1
  local m
  m=$(stat -f %m "$n" 2>/dev/null || echo 0)
  [ "$m" -ge "$WATCH_START" ]
}

while :; do
  {
    date
    echo "runlog_bytes=$(wc -c < "$RUNLOG" 2>/dev/null || echo 0)"
    echo -n 'current_dir='
    cat "$ROOT/build/.current-notary-dir" 2>/dev/null || echo
    echo -n 'final_zip='
    cat "$ROOT/build/.current-final-zip" 2>/dev/null || echo
    ls -ld "$APP" 2>/dev/null || echo 'app missing'
  } >>"$TRACE" 2>&1

  NDIR=$(cat "$ROOT/build/.current-notary-dir" 2>/dev/null || true)

  if fresh_dir "$NDIR" && [ -f "$NDIR/archive.log" ] && grep -q 'ARCHIVE FAILED' "$NDIR/archive.log"; then
    echo "FAILED: archive failed: $(why)"
    exit 1
  fi
  if fresh_dir "$NDIR" && [ -f "$NDIR/export.log" ] && grep -q 'EXPORT FAILED' "$NDIR/export.log"; then
    echo "FAILED: export failed: $(why)"
    exit 1
  fi
  if grep -q '^Release complete: ' "$RUNLOG" 2>/dev/null; then
    if grep -q 'Installed and relaunched the stapled build.' "$RUNLOG"; then
      echo 'DONE: installed and relaunched'
    else
      echo 'DONE: notarized zip verified (not installed; --install does that)'
    fi
    exit 0
  fi
  # Without a live run log (the pipeline was started directly rather than through
  # run-release.command or the launchd job) fall back to the artifacts: the
  # final-zip pointer is only written once the zip has verified.
  RUNLOG_MTIME=$(stat -f %m "$RUNLOG" 2>/dev/null || echo 0)
  FINAL=$(cat "$ROOT/build/.current-final-zip" 2>/dev/null || true)
  FINAL_MTIME=$(stat -f %m "$FINAL" 2>/dev/null || echo 0)
  if [ "$RUNLOG_MTIME" -lt "$WATCH_START" ] && [ -n "${FINAL:-}" ] && [ -f "$FINAL" ] && [ "$FINAL_MTIME" -ge "$WATCH_START" ]; then
    APP_MTIME=$(stat -f %m "$APP" 2>/dev/null || echo 0)
    if [ "$APP_MTIME" -gt "$START_MTIME" ]; then
      echo "DONE: final zip verified and Applications bundle updated: $FINAL"
    else
      echo "DONE: final zip verified: $FINAL"
    fi
    exit 0
  fi
  if [ "$SECONDS" -ge 90 ] && [ "$WARNED_START" -eq 0 ] && ! fresh_dir "$NDIR"; then
    echo 'ACTION_REQUIRED: pipeline has not created a new build directory after 90s'
    WARNED_START=1
  fi
  if [ "$SECONDS" -ge "$DEADLINE" ]; then
    echo "FAILED: timed out after 45m: $(why)"
    exit 1
  fi
  sleep 30
done
