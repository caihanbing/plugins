#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
PROJECT_DIR="${SCRIPT_DIR:h}"
SOURCE_APP="$PROJECT_DIR/dist/CodexFuelGauge.app"
INSTALL_DIR="$HOME/Applications"
INSTALLED_APP="$INSTALL_DIR/CodexFuelGauge.app"

if [[ ! -d "$SOURCE_APP" ]]; then
    "$SCRIPT_DIR/package_app.sh"
fi

mkdir -p "$INSTALL_DIR"
rm -rf "$INSTALLED_APP"
ditto "$SOURCE_APP" "$INSTALLED_APP"
codesign --verify --deep --strict "$INSTALLED_APP"

echo "$INSTALLED_APP"
