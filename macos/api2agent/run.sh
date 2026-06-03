#!/bin/bash
# Run api2agent as a proper macOS app bundle so the window/UI shows.
# Launching the raw binary directly makes macOS treat the process as a
# background-only CLI tool and the activation policy cannot promote to
# `.regular`, so the window never appears.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUNDLE="$SCRIPT_DIR/dist/API2Agent.app"
SPM_BINARY="$SCRIPT_DIR/.build/arm64-apple-macosx/debug/api2agent"

if [ -d "$BUNDLE" ]; then
    open -a "$BUNDLE"
    exit 0
fi

if [ -f "$SPM_BINARY" ]; then
    echo "No .app bundle at $BUNDLE; using SPM debug binary directly."
    echo "NOTE: a bare executable without an .app wrapper may run as a background-only"
    echo "process and never show a window. Build a .app via Scripts/package-app.sh for"
    echo "the full UI."
    exec "$SPM_BINARY"
fi

DERIVED_DATA="$HOME/Library/Developer/Xcode/DerivedData"
XC_BUILD=$(find "$DERIVED_DATA" -name "api2agent" -path "*/Build/Products/Debug/api2agent" -type f 2>/dev/null | head -1)
if [ -n "$XC_BUILD" ]; then
    XC_BUILD_DIR=$(dirname "$XC_BUILD")
    export DYLD_FRAMEWORK_PATH="$XC_BUILD_DIR:$XC_BUILD_DIR/PackageFrameworks"
    exec "$XC_BUILD"
fi

echo "Error: Could not find api2agent .app or binary" >&2
exit 1
