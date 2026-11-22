#!/usr/bin/env bash
# Runs SmartHomeKJ on this computer (a Mac or Linux), setting everything up the first time.
# Extra arguments go to "flutter run", e.g. ./run.sh --release
ROOT="$(cd "$(dirname "$0")" && pwd)"
case "$(uname -s)" in Darwin) DEVICE=macos ;; *) DEVICE=linux ;; esac
exec "$ROOT/flutterw" run -d "$DEVICE" "$@"
