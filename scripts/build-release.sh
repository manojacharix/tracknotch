#!/usr/bin/env bash
# Build a Release .app and package it into an unsigned (ad-hoc signed) DMG.
#
# Output: build/TrackNotch-<version>.dmg + SHA-256 printed to stdout.
#
# Requirements:
#   - Xcode + command line tools
#   - xcodegen   (brew install xcodegen)
#   - create-dmg (brew install create-dmg)  [auto-installed if missing]

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_DIR="$ROOT_DIR/TrackNotch"
PROJECT="$PROJECT_DIR/TrackNotch.xcodeproj"
SCHEME="TrackNotch"
CONFIG="Release"
BUILD_DIR="$ROOT_DIR/build"
ARCHIVE_PATH="$BUILD_DIR/TrackNotch.xcarchive"
EXPORT_DIR="$BUILD_DIR/export"
EXPORT_OPTIONS="$ROOT_DIR/scripts/ExportOptions.plist"

# Pull version from the generated Info.plist (post-xcodegen).
VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$PROJECT_DIR/TrackNotch/Resources/Info.plist" 2>/dev/null || echo "0.0.0")"
DMG_NAME="TrackNotch-${VERSION}.dmg"
DMG_PATH="$BUILD_DIR/$DMG_NAME"

echo "==> TrackNotch release build"
echo "    Version: $VERSION"
echo "    Project: $PROJECT"
echo

# Ensure create-dmg is available.
if ! command -v create-dmg >/dev/null 2>&1; then
    echo "==> Installing create-dmg via Homebrew..."
    brew install create-dmg
fi

# Regenerate Xcode project from project.yml (idempotent).
if command -v xcodegen >/dev/null 2>&1; then
    echo "==> Regenerating Xcode project from project.yml"
    (cd "$PROJECT_DIR" && xcodegen generate)
else
    echo "!! xcodegen not found — skipping project regeneration. Install with: brew install xcodegen"
fi

# Clean prior build artifacts.
echo "==> Cleaning $BUILD_DIR"
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

# Run unit tests as a release gate.
echo "==> Running unit tests"
xcodebuild \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration Debug \
    -destination "platform=macOS" \
    test | xcpretty || {
        echo "!! Tests failed — aborting release build."
        exit 1
    }

# Archive Release configuration.
echo "==> Archiving ($CONFIG)"
xcodebuild \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration "$CONFIG" \
    -archivePath "$ARCHIVE_PATH" \
    -destination "platform=macOS" \
    archive | xcpretty

# Export the .app from the archive.
echo "==> Exporting .app"
xcodebuild \
    -exportArchive \
    -archivePath "$ARCHIVE_PATH" \
    -exportOptionsPlist "$EXPORT_OPTIONS" \
    -exportPath "$EXPORT_DIR" | xcpretty

APP_PATH="$EXPORT_DIR/TrackNotch.app"
if [[ ! -d "$APP_PATH" ]]; then
    echo "!! Export failed — TrackNotch.app not found at $APP_PATH"
    exit 1
fi

# Verify ad-hoc signature is present (so the binary at least has a signature blob).
echo "==> Verifying ad-hoc signature"
codesign -dv "$APP_PATH" 2>&1 | grep -E "Signature=|Identifier=" || true

# Build the DMG.
echo "==> Packaging DMG"
create-dmg \
    --volname "TrackNotch $VERSION" \
    --window-pos 200 120 \
    --window-size 600 380 \
    --icon-size 96 \
    --icon "TrackNotch.app" 160 180 \
    --app-drop-link 440 180 \
    --no-internet-enable \
    "$DMG_PATH" \
    "$APP_PATH"

# Print SHA-256 for release notes.
echo
echo "==> Build complete"
echo "    DMG:    $DMG_PATH"
echo "    Size:   $(du -h "$DMG_PATH" | cut -f1)"
echo "    SHA256: $(shasum -a 256 "$DMG_PATH" | awk '{print $1}')"
