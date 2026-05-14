#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

APP_NAME="Talkeo"
BUILD_CONFIG="release"
BIN_PATH=".build/$BUILD_CONFIG/$APP_NAME"
APP_BUNDLE="$APP_NAME.app"

echo "[build] swift build -c $BUILD_CONFIG"
swift build -c "$BUILD_CONFIG"

if [[ ! -x "$BIN_PATH" ]]; then
    echo "[build] ERROR: binary not found at $BIN_PATH" >&2
    exit 1
fi

echo "[bundle] assembling $APP_BUNDLE"
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

cp "$BIN_PATH" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
cp "Resources/Info.plist" "$APP_BUNDLE/Contents/Info.plist"

# Bundle image/audio resources
shopt -s nullglob
for asset in Resources/*.png Resources/*.icns Resources/*.jpg; do
    cp "$asset" "$APP_BUNDLE/Contents/Resources/"
done
shopt -u nullglob

# Ad-hoc sign so macOS lets it run + remembers AX permission per build
codesign --force --deep --sign - "$APP_BUNDLE"

echo "[done] $APP_BUNDLE ready. Run with: open ./$APP_BUNDLE"
