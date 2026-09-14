#!/bin/zsh
set -euo pipefail

# The current macOS 26 Command Line Tools can occasionally ship a compiler
# one patch newer than the bundled SDK. This frontend flag downgrades that
# textual-interface version mismatch to a warning without changing codegen.
exec /Library/Developer/CommandLineTools/usr/bin/swiftc \
    -Xfrontend -downgrade-typecheck-interface-error \
    "$@"
