#!/usr/bin/env bash
# Builds the App Store version for iPhone and iPad on this Mac, signed with your team (set once in Xcode), see
# docs/DEPLOY.md. STORE=appstore turns off the GitHub update check, as the App Store requires.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
./flutterw build ipa --release --dart-define=STORE=appstore --obfuscate --split-debug-info=build/symbols/ios
echo
echo "Upload this with the Transporter app (or xcrun altool --upload-app):"
ls build/ios/ipa/*.ipa
echo "Keep build/symbols/ios: it turns crash stacks back into readable ones."
