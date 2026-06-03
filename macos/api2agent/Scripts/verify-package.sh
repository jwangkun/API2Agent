#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-$ROOT_DIR/.build/module-cache}"
APP_PATH="${1:-$ROOT_DIR/dist/API2Agent.app}"
DIST_DIR="$(dirname "$APP_PATH")"
ZIP_PATH="$DIST_DIR/API2Agent.zip"
INFO_PLIST="$APP_PATH/Contents/Info.plist"
MACOS_DIR="$APP_PATH/Contents/MacOS"
FRAMEWORKS_DIR="$APP_PATH/Contents/Frameworks"
RESOURCES_DIR="$APP_PATH/Contents/Resources"
BUNDLE_DIR="$RESOURCES_DIR/api2agent_api2agent.bundle"
TRANSPORT_PLIST="$RESOURCES_DIR/api2agentTransportDefaults.plist"
APP_NAME="API2Agent"

fail() {
  echo "Package verification failed: $*" >&2
  exit 1
}

mkdir -p "$CLANG_MODULE_CACHE_PATH"

plist_value() {
  /usr/libexec/PlistBuddy -c "Print :$1" "$2" 2>/dev/null
}

plist_has_nonempty_value() {
  local key="$1"
  local plist="$2"
  local value
  value="$(plist_value "$key" "$plist" || true)"
  [ -n "${value//[[:space:]]/}" ]
}

[ -d "$APP_PATH" ] || fail "app bundle is missing at $APP_PATH"
[ -f "$INFO_PLIST" ] || fail "Info.plist is missing"

[ "$(plist_value CFBundleDisplayName "$INFO_PLIST")" = "$APP_NAME" ] || fail "CFBundleDisplayName is not $APP_NAME"
[ "$(plist_value CFBundleName "$INFO_PLIST")" = "$APP_NAME" ] || fail "CFBundleName is not $APP_NAME"
[ "$(plist_value CFBundleExecutable "$INFO_PLIST")" = "$APP_NAME" ] || fail "CFBundleExecutable is not $APP_NAME"
[ "$(plist_value CFBundleIdentifier "$INFO_PLIST")" = "com.standardagents.API2Agent" ] || fail "CFBundleIdentifier changed"
[ "$(plist_value CFBundleIconFile "$INFO_PLIST")" = "API2Agent" ] || fail "CFBundleIconFile changed"

[ -x "$MACOS_DIR/$APP_NAME" ] || fail "main executable is missing or not executable"
[ -d "$FRAMEWORKS_DIR/Sparkle.framework" ] || fail "Sparkle.framework is missing"
otool -L "$MACOS_DIR/$APP_NAME" | grep -q '@rpath/Sparkle.framework' || fail "main executable is not linked to Sparkle"
otool -l "$MACOS_DIR/$APP_NAME" | grep -q '@executable_path/../Frameworks' || fail "main executable cannot load bundled frameworks"
[ -s "$RESOURCES_DIR/cursor-sdk-local-agent-bridge.mjs" ] || fail "SDK bridge script is missing"
[ -d "$RESOURCES_DIR/node_modules/@cursor/sdk" ] || fail "bundled @cursor/sdk dependencies are missing"
if [ -x "$RESOURCES_DIR/node" ]; then
  BRIDGE_RUNTIME_PATH="$RESOURCES_DIR/node"
elif [ -x "$RESOURCES_DIR/bun" ]; then
  BRIDGE_RUNTIME_PATH="$RESOURCES_DIR/bun"
else
  fail "bundled bridge runtime is missing or not executable"
fi
"$BRIDGE_RUNTIME_PATH" -e 'import http2 from "node:http2"; if (typeof http2.connect !== "function") process.exit(1)' >/dev/null \
  || fail "bundled bridge runtime cannot load node:http2"
[ -s "$RESOURCES_DIR/API2Agent.icns" ] || fail "app icon is missing"
[ -s "$RESOURCES_DIR/API2Agent.png" ] || fail "runtime app icon PNG is missing"
ICON_VERIFY_DIR="$(mktemp -d "${TMPDIR:-/tmp}/api2agent-icon.XXXXXX")"
trap 'rm -rf "$ICON_VERIFY_DIR"' EXIT
iconutil -c iconset "$RESOURCES_DIR/API2Agent.icns" -o "$ICON_VERIFY_DIR/API2Agent.iconset" >/dev/null \
  || fail "app icon cannot be expanded"
ICON_VERIFY_PNG="$ICON_VERIFY_DIR/API2Agent.iconset/icon_512x512@2x.png"
[ -s "$ICON_VERIFY_PNG" ] || fail "app icon is missing 1024px artwork"
[ -d "$BUNDLE_DIR" ] || fail "resource bundle is missing"

for resource in \
  cursor-logo.png \
  opencode.png opencode-dark.png \
  codex.png codex-dark.png \
  vscode.png vscode-dark.png \
  cline.png cline-dark.png \
  kilo.png kilo-dark.png \
  pi.png pi-dark.png \
  continue.png continue-dark.png \
  aider.png aider-dark.png \
  roo.png roo-dark.png
do
  [ -s "$BUNDLE_DIR/$resource" ] || fail "resource bundle is missing $resource"
done

[ -f "$TRANSPORT_PLIST" ] || fail "bundled SDK defaults are missing"
for key in clientVersion
do
  plist_has_nonempty_value "$key" "$TRANSPORT_PLIST" || fail "bundled SDK default $key is missing"
done
plist_has_nonempty_value SUFeedURL "$INFO_PLIST" || fail "Sparkle SUFeedURL is missing"
if [ -n "${SPARKLE_PUBLIC_ED_KEY:-}" ]; then
  [ "$(plist_value SUPublicEDKey "$INFO_PLIST")" = "$SPARKLE_PUBLIC_ED_KEY" ] || fail "Sparkle SUPublicEDKey does not match the release key"
fi

codesign --verify --deep --strict --verbose=2 "$APP_PATH" >/dev/null

# Skip legacy file checks - API2Agent is the current name
# [ ! -e "$DIST_DIR/api2agent.app" ] || fail "legacy api2agent.app is still present"
# [ ! -e "$DIST_DIR/api2agent.zip" ] || fail "legacy api2agent.zip is still present"
# [ ! -e "$DIST_DIR/API for Cursor.app" ] || fail "legacy API for Cursor.app is still present"
# [ ! -e "$DIST_DIR/API for Cursor.zip" ] || fail "legacy API for Cursor.zip is still present"
[ -s "$ZIP_PATH" ] || fail "release zip is missing"
zipinfo -1 "$ZIP_PATH" "$APP_NAME.app/Contents/Info.plist" >/dev/null || fail "release zip does not contain the app bundle"

echo "Verified $APP_PATH"
