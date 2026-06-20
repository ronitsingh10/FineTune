#!/bin/bash
set -e

# FineTune DMG Build Script
# Requires: Xcode, Node.js 18+, GraphicsMagick, ImageMagick
# Install dependencies: brew install graphicsmagick imagemagick

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="$PROJECT_DIR/build"

echo "==> Cleaning build directory..."
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

echo "==> Building release archive..."
if grep -q "TEAM_ID_PLACEHOLDER" "$PROJECT_DIR/ExportOptions.plist"; then
    echo "==> [Local/Ad-hoc Build] ExportOptions.plist has placeholder Team ID."
    xcodebuild -project "$PROJECT_DIR/FineTune.xcodeproj" \
        -scheme FineTune \
        -configuration Release \
        -archivePath "$BUILD_DIR/FineTune.xcarchive" \
        CODE_SIGN_IDENTITY="-" \
        archive

    echo "==> Copying and signing app with ad-hoc identity..."
    cp -R "$BUILD_DIR/FineTune.xcarchive/Products/Applications/FineTune.app" "$BUILD_DIR/"
    codesign --force --deep --sign - --timestamp=none "$BUILD_DIR/FineTune.app"
    CREATE_DMG_FLAGS="--no-code-sign"
else
    xcodebuild -project "$PROJECT_DIR/FineTune.xcodeproj" \
        -scheme FineTune \
        -configuration Release \
        -archivePath "$BUILD_DIR/FineTune.xcarchive" \
        archive

    echo "==> Exporting notarized app..."
    xcodebuild -exportArchive \
        -archivePath "$BUILD_DIR/FineTune.xcarchive" \
        -exportPath "$BUILD_DIR" \
        -exportOptionsPlist "$PROJECT_DIR/ExportOptions.plist"
    CREATE_DMG_FLAGS=""
fi

echo "==> Creating DMG..."
# create-dmg auto-generates professional layout with:
# - App icon composited onto disk icon
# - "Drag to Applications" layout
# - Code signing
npx create-dmg "$BUILD_DIR/FineTune.app" "$BUILD_DIR" --overwrite $CREATE_DMG_FLAGS

echo "==> Done!"
echo "DMG created at: $BUILD_DIR/"
ls -la "$BUILD_DIR"/*.dmg

