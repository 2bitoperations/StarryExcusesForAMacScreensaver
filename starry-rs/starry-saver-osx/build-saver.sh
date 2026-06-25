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
SWIFT_SRCS=(
    "$SCRIPT_DIR/RustDefaultsManager.swift"
    "$SCRIPT_DIR/StarryConfigPanel.swift"
    "$SCRIPT_DIR/StarrySaverView.swift"
)
PLIST_SRC="$SCRIPT_DIR/Info.plist"

# Embed the current git commit so the options panel shows build identity.
COMMIT=$(git -C "$WORKSPACE_DIR" rev-parse --short HEAD 2>/dev/null || echo "unknown")
BUILD_INFO_SWIFT="$TARGET_DIR/BuildInfo.swift"
printf 'let buildCommit = "%s"
' "$COMMIT" > "$BUILD_INFO_SWIFT"

# Cargo bakes the absolute build-tree path into the dylib's LC_ID_DYLIB.
# If swiftc links against it before we fix this, it copies that absolute path
# into LC_LOAD_DYLIB — the screensaver engine then can't find the dylib at
# runtime and the Swift binary silently fails to load.  Fix the install name
# FIRST so swiftc records @rpath/libstarry_saver.dylib instead.
echo "→ Fixing Rust dylib install name → @rpath/libstarry_saver.dylib"
install_name_tool -id "@rpath/libstarry_saver.dylib" "$DYLIB"

echo "→ Assembling bundle: $SAVER_DIR"
rm -rf "$SAVER_DIR"
mkdir -p "$SAVER_DIR/Contents/MacOS"
mkdir -p "$SAVER_DIR/Contents/Frameworks"

echo "→ Compiling Swift wrapper (commit $COMMIT)…"
swiftc "${SWIFT_SRCS[@]}" "$BUILD_INFO_SWIFT" \
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

# Ad-hoc sign the whole bundle so the screensaver engine will load it.
# --deep signs the Frameworks dylib and the main executable in one pass.
echo "→ Ad-hoc signing bundle…"
codesign --force --deep --sign - "$SAVER_DIR"

echo ""
echo "✓ Built $SAVER_DIR"
echo "  Install: open \"$SAVER_DIR\""
