#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
PROJECT_DIR="${SCRIPT_DIR:h}"
APP_NAME="CodexFuelGauge.app"
DIST_DIR="$PROJECT_DIR/dist"
APP_DIR="$DIST_DIR/$APP_NAME"

cd "$PROJECT_DIR"
mkdir -p "$PROJECT_DIR/.build/module-cache-compat"
export SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"
export SWIFT_EXEC="$PROJECT_DIR/scripts/swiftc_compat.sh"
export CLANG_MODULE_CACHE_PATH="$PROJECT_DIR/.build/module-cache-compat"
export SWIFTPM_MODULECACHE_OVERRIDE="$PROJECT_DIR/.build/module-cache-compat"
swift build -c release --disable-sandbox
BIN_DIR="$(swift build -c release --disable-sandbox --show-bin-path)"

rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$BIN_DIR/CodexFuelGauge" "$APP_DIR/Contents/MacOS/CodexFuelGauge"
cp "$PROJECT_DIR/Packaging/Info.plist" "$APP_DIR/Contents/Info.plist"

chmod 755 "$APP_DIR/Contents/MacOS/CodexFuelGauge"
codesign --force --deep --sign - "$APP_DIR"

echo "$APP_DIR"
