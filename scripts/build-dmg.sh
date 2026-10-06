#!/bin/bash
#
# One-step script to build ImageOptim and produce the final DMG file.
# Run from project root: ./scripts/build-dmg.sh
#
# Prerequisites:
#   - Xcode
#   - Rust (via rustup)
#
# Output: build/Build/Products/Release/ImageOptim-<version>.dmg

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BUILD_DIR="$PROJECT_DIR/build"
RELEASE_APP="$BUILD_DIR/Build/Products/Release/ImageOptim.app"

cd "$PROJECT_DIR"

echo "=== Step 1: Initialize submodules ==="
git submodule update --init --recursive || true

echo ""
echo "=== Step 2: Build ImageOptim (Release) ==="
xcodebuild -project "$PROJECT_DIR/imageoptim/ImageOptim.xcodeproj" \
    -scheme ImageOptim \
    -configuration Release \
    -derivedDataPath "$BUILD_DIR" \
    CODE_SIGN_IDENTITY="-" \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGNING_ALLOWED=NO \
    build

if [ ! -d "$RELEASE_APP" ]; then
    echo "Error: Build succeeded but ImageOptim.app not found at $RELEASE_APP"
    exit 1
fi

echo ""
echo "=== Step 2b: Bundle standalone tools ==="
GPL_RES="$RELEASE_APP/Contents/Frameworks/ImageOptimGPL.framework/Versions/A/Resources"
if [ -d "$GPL_RES" ] && [ -f "$PROJECT_DIR/jpegli/cjpegli" ]; then
    cp -f "$PROJECT_DIR/jpegli/cjpegli" "$GPL_RES/cjpegli"
    chmod 755 "$GPL_RES/cjpegli"
    echo "Bundled cjpegli into ImageOptimGPL.framework"
fi

echo ""
echo "=== Step 3: Create DMG ==="
RELEASE_DIR="$BUILD_DIR/Build/Products/Release"
VERSION=$(plutil -extract CFBundleShortVersionString raw "$RELEASE_APP/Contents/Info.plist" 2>/dev/null) || VERSION="2.1.0"
DMG_NAME="ImageOptim-${VERSION}.dmg"

DMG_PATH="$RELEASE_DIR/$DMG_NAME"
hdiutil create -volname "ImageOptim $VERSION" \
    -srcfolder "$RELEASE_APP" \
    -ov -format UDZO \
    "$DMG_PATH"
echo "Created: $DMG_PATH"

if [ -f "$DMG_PATH" ]; then
    echo ""
    echo "=== Done ==="
    echo "DMG: $DMG_PATH"
    echo "Size: $(du -h "$DMG_PATH" | cut -f1)"
else
    echo "Error: DMG was not created"
    exit 1
fi
