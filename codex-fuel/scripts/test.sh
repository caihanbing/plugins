#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
PROJECT_DIR="${SCRIPT_DIR:h}"

cd "$PROJECT_DIR"
mkdir -p "$PROJECT_DIR/.build/module-cache-compat"
export SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"
export SWIFT_EXEC="$PROJECT_DIR/scripts/swiftc_compat.sh"
export CLANG_MODULE_CACHE_PATH="$PROJECT_DIR/.build/module-cache-compat"
export SWIFTPM_MODULECACHE_OVERRIDE="$PROJECT_DIR/.build/module-cache-compat"

swift test --disable-sandbox
