#!/usr/bin/env bash
# Build an unsigned (ad-hoc signed) Release DMG — no Apple Developer license needed.
#
# Output: build/TrackNotch-<version>.dmg + SHA-256 printed to stdout.
#
# Requirements:
#   - Xcode + command line tools
#   - create-dmg (auto-installed via Homebrew if missing)

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

VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$PROJECT_DIR/TrackNotch/Resources/Info.plist" 2>/dev/null || echo "0.0.0")"
DMG_NAME="TrackNotch-${VERSION}.dmg"
DMG_PATH="$BUILD_DIR/$DMG_NAME"

echo "==> TrackNotch release build"
echo "    Version : $VERSION"
echo "    Project : $PROJECT"
echo

# Ensure create-dmg is available.
if ! command -v create-dmg >/dev/null 2>&1; then
    echo "==> Installing create-dmg via Homebrew..."
    brew install create-dmg
fi

# Clean prior build artifacts.
echo "==> Cleaning $BUILD_DIR"
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

# Archive Release — ad-hoc signed, no team required.
echo "==> Archiving ($CONFIG)"
xcodebuild \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration "$CONFIG" \
    -archivePath "$ARCHIVE_PATH" \
    -destination "platform=macOS" \
    CODE_SIGN_IDENTITY="-" \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGNING_ALLOWED=NO \
    archive 2>&1 | grep -E "error:|warning:|BUILD SUCCEEDED|BUILD FAILED|^==" || true

# Export the .app from the archive.
echo "==> Exporting .app"
xcodebuild \
    -exportArchive \
    -archivePath "$ARCHIVE_PATH" \
    -exportOptionsPlist "$EXPORT_OPTIONS" \
    -exportPath "$EXPORT_DIR" \
    CODE_SIGN_IDENTITY="-" \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGNING_ALLOWED=NO \
    2>&1 | grep -E "error:|warning:|succeeded|failed|^==" || true

APP_PATH="$EXPORT_DIR/TrackNotch.app"

# Fallback: grab .app directly from archive if export step didn't produce it.
if [[ ! -d "$APP_PATH" ]]; then
    ARCHIVE_APP="$ARCHIVE_PATH/Products/Applications/TrackNotch.app"
    if [[ -d "$ARCHIVE_APP" ]]; then
        echo "==> Export step skipped — using .app directly from archive"
        mkdir -p "$EXPORT_DIR"
        cp -R "$ARCHIVE_APP" "$APP_PATH"
    else
        echo "!! Build failed — TrackNotch.app not found"
        exit 1
    fi
fi

echo "==> App built at $APP_PATH"

# Strip Gatekeeper quarantine from the app bundle so it opens cleanly.
xattr -cr "$APP_PATH" 2>/dev/null || true

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

echo
echo "==> Build complete"
echo "    DMG    : $DMG_PATH"
echo "    Size   : $(du -h "$DMG_PATH" | cut -f1)"
echo "    SHA256 : $(shasum -a 256 "$DMG_PATH" | awk '{print $1}')"
