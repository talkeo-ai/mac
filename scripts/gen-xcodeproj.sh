#!/usr/bin/env bash
# Regenerate Talkeo.xcodeproj from project.yml (the source of truth).
# The .xcodeproj is gitignored — run this after cloning/pulling, or whenever
# project.yml changes. Requires XcodeGen: `brew install xcodegen`.
set -euo pipefail

cd "$(dirname "$0")/.."

if ! command -v xcodegen >/dev/null 2>&1; then
    echo "[gen] ERROR: xcodegen not found. Install with: brew install xcodegen" >&2
    exit 1
fi

echo "[gen] xcodegen generate"
xcodegen generate

echo "[done] Talkeo.xcodeproj ready. Open with: open Talkeo.xcodeproj"
