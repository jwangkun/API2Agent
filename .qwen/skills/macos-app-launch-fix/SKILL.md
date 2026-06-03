---
name: macos-app-launch-fix
description: Fix Sparkle framework rpath issue when launching debug macOS api2agent app
source: auto-skill
extracted_at: '2026-06-02T07:06:43.787Z'
---

## macOS Debug App Launch Fix for Sparkle Framework

When building and running the macOS api2agent app in debug mode, the Sparkle framework may not be found at runtime due to incorrect rpath configuration. This causes the app to crash immediately with:

```
Library not loaded: @rpath/Sparkle.framework/Versions/B/Sparkle
```

### Solution: Set DYLD_FRAMEWORK_PATH

When launching the debug build, you must set the `DYLD_FRAMEWORK_PATH` environment variable to include both the build output directory and the Sparkle framework location.

### For SPM Builds

```bash
# Build with Swift Package Manager
cd macos/api2agent && swift build

# Launch with correct framework path
DYLD_FRAMEWORK_PATH=/path/to/api2agent/.build/arm64-apple-macosx/debug:\
/path/to/api2agent/.build/checkouts/sparkle/Sparkle.framework \
  /path/to/api2agent/.build/arm64-apple-macosx/debug/api2agent
```

### For Xcode Builds

```bash
# Find the built app
XC_BUILD=$(find ~/Library/Developer/Xcode/DerivedData/api2agent-* \
  -name "api2agent" -path "*/Build/Products/Debug/api2agent" -type f | head -1)

XC_BUILD_DIR=$(dirname "$XC_BUILD")

# Launch with framework path
DYLD_FRAMEWORK_PATH="$XC_BUILD_DIR:$XC_BUILD_DIR/PackageFrameworks" "$XC_BUILD"
```

### Create a Run Script

Create `macos/api2agent/run.sh` for convenience:

```bash
#!/bin/bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="$SCRIPT_DIR/.build/arm64-apple-macosx/debug"

if [ -f "$BUILD_DIR/api2agent" ]; then
    export DYLD_FRAMEWORK_PATH="$BUILD_DIR:$SCRIPT_DIR/.build/checkouts/sparkle/Sparkle.framework"
    exec "$BUILD_DIR/api2agent"
fi

# Fall back to Xcode build
DERIVED_DATA="$HOME/Library/Developer/Xcode/DerivedData"
XC_BUILD=$(find "$DERIVED_DATA" -name "api2agent" -path "*/Build/Products/Debug/api2agent" -type f 2>/dev/null | head -1)

if [ -n "$XC_BUILD" ]; then
    XC_BUILD_DIR=$(dirname "$XC_BUILD")
    export DYLD_FRAMEWORK_PATH="$XC_BUILD_DIR:$XC_BUILD_DIR/PackageFrameworks"
    exec "$XC_BUILD"
fi

echo "Error: Could not find api2agent binary"
exit 1
```

### Settings Location

App settings are stored in:
- `~/Library/Application Support/api2agent/settings.json`

To force window mode (not menu-bar only), create the settings file:

```bash
mkdir -p ~/Library/Application\ Support/api2agent
echo '{"menuBarOnly":false,"port":8787}' > ~/Library/Application\ Support/api2agent/settings.json
```

### Verify App is Running

```bash
# Check process
ps aux | grep api2agent | grep -v grep

# Test local API server
curl -s http://127.0.0.1:8787/v1/models
```

### Common Issues

1. **App crashes immediately**: Missing `DYLD_FRAMEWORK_PATH`
2. **No window appears**: Check `menuBarOnly` setting or press `Cmd+Tab` to switch to the app
3. **Connection refused on port 8787**: Server hasn't started yet, wait for app initialization
4. **Input method errors**: `IMKCFRunLoopWakeUpReliable` errors are harmless, ignore them
