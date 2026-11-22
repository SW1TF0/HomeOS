#!/usr/bin/env bash
# Runs SmartHomeKJ on this computer (a Mac or Linux), setting everything up the first time.
#   ./run.sh                    run it
#   ./run.sh --as windows       run it looking and behaving like Windows (or android, ios, macos, linux),
#                               to see and fix a Windows problem from a Mac
#   ./run.sh --release          any other arguments go to "flutter run"
ROOT="$(cd "$(dirname "$0")" && pwd)"
case "$(uname -s)" in Darwin) DEVICE=macos ;; *) DEVICE=linux ;; esac
ARGS=()
while [[ $# -gt 0 ]]; do
  if [[ "$1" == "--as" && -n "${2:-}" ]]; then
    ARGS+=("--dart-define=PRETEND_PLATFORM=$2"); shift 2
  else
    ARGS+=("$1"); shift
  fi
done
exec "$ROOT/flutterw" run -d "$DEVICE" ${ARGS[@]+"${ARGS[@]}"}
