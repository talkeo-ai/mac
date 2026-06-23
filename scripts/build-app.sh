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

# Sign with a stable identity so macOS keeps the Accessibility (TCC) grant
# across rebuilds. TCC keys on the code-signing designated requirement; an
# ad-hoc signature's hash changes every build, so each build looks like a new
# app and re-prompts for permission. Prefer a real Apple Development / Developer
# ID identity (override with TALKEO_SIGN_IDENTITY); fall back to ad-hoc only when
# no signing certificate is installed (contributors will then be re-prompted).
SIGN_IDENTITY="${TALKEO_SIGN_IDENTITY:-}"
if [[ -z "$SIGN_IDENTITY" ]]; then
    SIGN_IDENTITY=$(security find-identity -v -p codesigning \
        | awk -F'"' '/Apple Development|Developer ID Application/ {print $2; exit}')
fi

if [[ -n "$SIGN_IDENTITY" ]]; then
    echo "[sign] $SIGN_IDENTITY"
    codesign --force --deep --sign "$SIGN_IDENTITY" "$APP_BUNDLE"
else
    echo "[sign] WARNING: no signing identity found — ad-hoc signing." >&2
    echo "[sign] macOS will re-prompt for Accessibility on every build." >&2
    codesign --force --deep --sign - "$APP_BUNDLE"
fi

echo "[done] $APP_BUNDLE ready. Run with: open ./$APP_BUNDLE"
