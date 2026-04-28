#!/bin/bash
set -euo pipefail

PROJECT="StarryExcuseForAMacScreensaver.xcodeproj"
SCHEME="StarryExcuseForAMacScreensaver"
PRODUCT="StarryExcuseForAMacScreensaver.saver"
INSTALL_DIR="$HOME/Library/Screen Savers"
CONFIG="${1:-Debug}"

echo "Building $SCHEME ($CONFIG)..."
xcodebuild -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration "$CONFIG" \
  build -quiet

BUILD_DIR=$(xcodebuild -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration "$CONFIG" \
  -showBuildSettings 2>/dev/null \
  | grep ' TARGET_BUILD_DIR' | xargs | cut -d' ' -f3)

if [ ! -d "$BUILD_DIR/$PRODUCT" ]; then
  echo "Error: Build product not found at $BUILD_DIR/$PRODUCT"
  exit 1
fi

echo "Installing to $INSTALL_DIR..."
mkdir -p "$INSTALL_DIR"
rm -rf "$INSTALL_DIR/$PRODUCT"
cp -R "$BUILD_DIR/$PRODUCT" "$INSTALL_DIR/"

echo "Done! Open System Settings → Screen Saver to select it."
