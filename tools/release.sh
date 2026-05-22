#!/usr/bin/env bash
# Build a Release .app for Apptivator and package it as a .dmg.
#
# Ad-hoc signed; suitable for personal distribution. Recipients will see a
# Gatekeeper warning the first time they open it (right-click → Open to bypass).
#
# Requirements:
#   - Xcode (xcodebuild on PATH, or DEVELOPER_DIR pointed at an Xcode install)
#   - create-dmg: `brew install create-dmg` or `npm install -g create-dmg`

set -euo pipefail

cd "$(dirname "$0")/.."

PROJECT="Apptivator.xcodeproj"
SCHEME="Apptivator"
CONFIG="Release"
BUILD_DIR="build"
ARCHIVE_PATH="${BUILD_DIR}/${SCHEME}.xcarchive"
APP_PATH="${BUILD_DIR}/${SCHEME}.app"

if ! command -v xcodebuild >/dev/null 2>&1; then
    echo "error: xcodebuild not found. If Command Line Tools is selected, run:" >&2
    echo "  sudo xcode-select -s /Applications/Xcode.app/Contents/Developer" >&2
    echo "or set DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer" >&2
    exit 1
fi

if ! command -v create-dmg >/dev/null 2>&1; then
    echo "error: create-dmg not found. Install with:" >&2
    echo "  brew install create-dmg" >&2
    exit 1
fi

rm -rf "${BUILD_DIR}"
mkdir -p "${BUILD_DIR}"

echo "==> Archiving ${SCHEME} (${CONFIG})"
xcodebuild \
    -project "${PROJECT}" \
    -scheme "${SCHEME}" \
    -configuration "${CONFIG}" \
    -archivePath "${ARCHIVE_PATH}" \
    -destination "generic/platform=macOS" \
    archive

# Ad-hoc signed archive: just lift the .app out — no exportArchive ceremony.
ARCHIVED_APP="${ARCHIVE_PATH}/Products/Applications/${SCHEME}.app"
if [[ ! -d "${ARCHIVED_APP}" ]]; then
    echo "error: expected ${ARCHIVED_APP} after archive but did not find it" >&2
    exit 1
fi
cp -R "${ARCHIVED_APP}" "${APP_PATH}"

# Re-sign ad-hoc with a stable identifier matching the bundle ID. xcodebuild's archive
# defaults the codesign identifier to the product name ("Apptivator"), which makes TCC
# treat the app as a different identity each rebuild and prompts for Accessibility again.
BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "${APP_PATH}/Contents/Info.plist")"
echo "==> Re-signing ad-hoc with identifier ${BUNDLE_ID}"
codesign --force --deep --sign - --identifier "${BUNDLE_ID}" "${APP_PATH}"

# Pull the marketing version out of the built Info.plist for a friendlier .dmg name.
VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' \
    "${APP_PATH}/Contents/Info.plist" 2>/dev/null || echo "")"
DMG_NAME="${SCHEME}${VERSION:+-${VERSION}}.dmg"
DMG_PATH="${BUILD_DIR}/${DMG_NAME}"

echo "==> Building ${DMG_NAME}"
STAGING="$(mktemp -d "${BUILD_DIR}/dmg-staging.XXXXXX")"
trap 'rm -rf "${STAGING}"' EXIT
cp -R "${APP_PATH}" "${STAGING}/"

# brew's create-dmg (andreyvit) — usage: create-dmg <output.dmg> <source_folder>
create-dmg \
    --volname "${SCHEME}" \
    --window-size 480 300 \
    --icon-size 96 \
    --icon "${SCHEME}.app" 130 150 \
    --app-drop-link 350 150 \
    "${DMG_PATH}" \
    "${STAGING}"

echo
echo "==> Done"
ls -lh "${DMG_PATH}"
