#!/usr/bin/env bash
# What CI checks, on this computer: packages, analysis (warnings fail it) and every test.
#   ./tool/check.sh           analyze + test
#   ./tool/check.sh --build   also build the desktop app for this computer
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
F="$ROOT/flutterw"
"$F" pub get
echo "==> Analyze"
"$F" analyze --no-fatal-infos
echo "==> Test"
"$F" test
if [[ "${1:-}" == "--build" ]]; then
  case "$(uname -s)" in Darwin) T=macos ;; *) T=linux ;; esac
  echo "==> Build $T"
  "$F" build "$T" --debug
fi
echo "==> All good"
