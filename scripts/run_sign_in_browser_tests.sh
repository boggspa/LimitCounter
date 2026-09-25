#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUTPUT="${TMPDIR:-/tmp}/sign-in-browser-tests"

cd "$ROOT_DIR"

xcrun --sdk macosx swiftc -enable-testing \
  App/Views/SignInBrowser.swift \
  Tests/SignInBrowserTests.swift \
  -o "$OUTPUT" \
  -framework AppKit \
  -framework WebKit

"$OUTPUT"
