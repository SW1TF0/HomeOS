#!/usr/bin/env bash
# Sets up everything needed to run and build SmartHomeKJ on macOS or Linux, inside this repo.
#
#   ./tool/setup.sh            Flutter, the desktop tools for this computer, and the app's packages
#   ./tool/setup.sh --android  the same, plus Java and the Android SDK, to build the Android app
#
# Flutter goes into .sdk/flutter (ignored by Git), at exactly the version in pubspec.yaml, so it never clashes with
# another Flutter on this computer and every computer builds with the same one. Run it again any time: it only does
# what is missing.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SDK="$ROOT/.sdk"
FLUTTER_DIR="$SDK/flutter"
FLUTTER="$FLUTTER_DIR/bin/flutter"
VERSION="$(sed -n 's/^  flutter: *\([0-9.]*\).*/\1/p' "$ROOT/pubspec.yaml" | head -1)"
ANDROID=0
[[ "${1:-}" == "--android" ]] && ANDROID=1

say() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m!   %s\033[0m\n' "$*"; }
have() { command -v "$1" >/dev/null 2>&1; }

[[ -n "$VERSION" ]] || { echo "No 'flutter:' version under environment in pubspec.yaml"; exit 1; }
OS="$(uname -s)"

# ---- System tools ---------------------------------------------------------------------------------------------
if [[ "$OS" == "Darwin" ]]; then
  say "macOS: checking the Xcode command line tools"
  if ! xcode-select -p >/dev/null 2>&1; then
    warn "Installing the Xcode command line tools. Finish the window that opens, then run this script again."
    xcode-select --install || true
    exit 1
  fi
  if ! have xcodebuild || ! xcodebuild -version >/dev/null 2>&1; then
    warn "Building the Mac app needs the full Xcode (free, from the App Store). Everything else works without it."
  fi
elif [[ "$OS" == "Linux" ]]; then
  say "Linux: installing build tools (needs sudo)"
  PKGS="git curl unzip xz-utils zip clang cmake ninja-build pkg-config libgtk-3-dev liblzma-dev libstdc++-12-dev"
  if have apt-get; then
    sudo apt-get update -qq
    # shellcheck disable=SC2086
    sudo apt-get install -y -qq $PKGS
  elif have dnf; then
    sudo dnf install -y git curl unzip xz zip clang cmake ninja-build pkgconf-pkg-config gtk3-devel xz-devel libstdc++-devel
  elif have pacman; then
    sudo pacman -S --needed --noconfirm git curl unzip xz zip clang cmake ninja pkgconf gtk3
  else
    warn "Unknown package manager. Install these yourself: $PKGS"
  fi
fi
have git || { echo "Git is needed. Install it and run this again."; exit 1; }

# ---- Flutter, at the version in pubspec.yaml --------------------------------------------------------------------
mkdir -p "$SDK"
if [[ -x "$FLUTTER" ]] && [[ "$(git -C "$FLUTTER_DIR" describe --tags 2>/dev/null)" == "$VERSION" ]]; then
  say "Flutter $VERSION is already in .sdk/flutter"
else
  say "Downloading Flutter $VERSION into .sdk/flutter"
  rm -rf "$FLUTTER_DIR"
  # The official release archive: the stable channel at exactly this version.
  base="https://storage.googleapis.com/flutter_infra_release/releases/stable"
  tmp="$(mktemp -d)"
  if [[ "$OS" == "Darwin" ]]; then
    arch=$([[ "$(uname -m)" == "arm64" ]] && echo "_arm64" || echo "")
    curl -fL --progress-bar "$base/macos/flutter_macos${arch}_$VERSION-stable.zip" -o "$tmp/flutter.zip"
    unzip -q "$tmp/flutter.zip" -d "$SDK"
  else
    curl -fL --progress-bar "$base/linux/flutter_linux_$VERSION-stable.tar.xz" -o "$tmp/flutter.tar.xz"
    tar -xJf "$tmp/flutter.tar.xz" -C "$SDK"
  fi
  rm -rf "$tmp"
  # The archive is a Git checkout owned by someone else; tell Git it is fine.
  git config --global --add safe.directory "$FLUTTER_DIR" 2>/dev/null || true
fi
export PATH="$FLUTTER_DIR/bin:$PATH"
"$FLUTTER" config --no-analytics >/dev/null 2>&1 || true
"$FLUTTER" --disable-analytics >/dev/null 2>&1 || true

# ---- Android (only with --android) -------------------------------------------------------------------------------
if [[ $ANDROID == 1 ]]; then
  say "Android: Java 17 and the Android SDK into .sdk"
  JDK="$SDK/jdk"
  if [[ ! -x "$JDK/bin/java" && ! -x "$JDK/Contents/Home/bin/java" ]]; then
    arch="$(uname -m)"; [[ "$arch" == "arm64" || "$arch" == "aarch64" ]] && arch=aarch64 || arch=x64
    os=$([[ "$OS" == "Darwin" ]] && echo mac || echo linux)
    mkdir -p "$JDK"
    curl -fsSL "https://api.adoptium.net/v3/binary/latest/17/ga/$os/$arch/jdk/hotspot/normal/eclipse" | tar -xz -C "$JDK" --strip-components=1
  fi
  [[ -x "$JDK/Contents/Home/bin/java" ]] && JAVA_HOME="$JDK/Contents/Home" || JAVA_HOME="$JDK"
  export JAVA_HOME
  ASDK="$SDK/android"
  if [[ ! -x "$ASDK/cmdline-tools/latest/bin/sdkmanager" ]]; then
    os=$([[ "$OS" == "Darwin" ]] && echo mac || echo linux)
    tmp="$(mktemp -d)"
    curl -fsSL "https://dl.google.com/android/repository/commandlinetools-$os-11076708_latest.zip" -o "$tmp/tools.zip"
    unzip -q "$tmp/tools.zip" -d "$tmp"
    mkdir -p "$ASDK/cmdline-tools"
    mv "$tmp/cmdline-tools" "$ASDK/cmdline-tools/latest"
    rm -rf "$tmp"
  fi
  yes | "$ASDK/cmdline-tools/latest/bin/sdkmanager" --sdk_root="$ASDK" --licenses >/dev/null || true
  "$ASDK/cmdline-tools/latest/bin/sdkmanager" --sdk_root="$ASDK" "platform-tools" "platforms;android-35" "build-tools;35.0.0"
  "$FLUTTER" config --android-sdk "$ASDK" --jdk-dir "$JAVA_HOME"
fi

# ---- The app ---------------------------------------------------------------------------------------------------
say "Getting the app's packages"
cd "$ROOT"
"$FLUTTER" precache --universal $([[ "$OS" == "Darwin" ]] && echo --macos || echo --linux)
"$FLUTTER" pub get

say "What Flutter can build on this computer"
"$FLUTTER" doctor || true

cat <<EOF

Done. From the repo folder:
  ./run.sh              run the app on this computer
  ./tool/check.sh       analyze and run every test (what CI runs)
  ./flutterw <args>     any Flutter command with this repo's Flutter, e.g. ./flutterw build macos
EOF
