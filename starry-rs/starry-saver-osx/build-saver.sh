#!/usr/bin/env bash
# Assembles StarryNight.saver — an installable macOS screensaver bundle.
#
# Usage (from any directory):
#   starry-rs/starry-saver-osx/build-saver.sh
#
# Output: starry-rs/target/release/StarryNight.saver
# Install: open  starry-rs/target/release/StarryNight.saver
#          (System Settings → Screen Saver picks it up automatically)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TARGET_DIR="$WORKSPACE_DIR/target/release"
BUNDLE_NAME="StarryNight"
SAVER_DIR="$TARGET_DIR/$BUNDLE_NAME.saver"

echo "→ Building Rust cdylib (starry-saver)…"
cargo build --release --locked -p starry-saver --manifest-path "$WORKSPACE_DIR/Cargo.toml"

DYLIB="$TARGET_DIR/libstarry_saver.dylib"
SWIFT_SRC="$SCRIPT_DIR/StarrySaverView.swift"
PLIST_SRC="$SCRIPT_DIR/Info.plist"

echo "→ Assembling bundle: $SAVER_DIR"
rm -rf "$SAVER_DIR"
mkdir -p "$SAVER_DIR/Contents/MacOS"
mkdir -p "$SAVER_DIR/Contents/Frameworks"

echo "→ Compiling Swift wrapper…"
swiftc "$SWIFT_SRC" \
    -module-name StarryNightSaver \
    -emit-library \
    -o "$SAVER_DIR/Contents/MacOS/$BUNDLE_NAME" \
    -framework ScreenSaver \
    -framework QuartzCore \
    -framework Metal \
    -framework Cocoa \
    -L "$TARGET_DIR" \
    -lstarry_saver \
    -Xlinker -rpath -Xlinker @loader_path/../Frameworks

echo "→ Copying Rust dylib into Frameworks/…"
cp "$DYLIB" "$SAVER_DIR/Contents/Frameworks/libstarry_saver.dylib"

echo "→ Copying Info.plist…"
cp "$PLIST_SRC" "$SAVER_DIR/Contents/Info.plist"

echo ""
echo "✓ Built $SAVER_DIR"
echo "  Install: open \"$SAVER_DIR\""
