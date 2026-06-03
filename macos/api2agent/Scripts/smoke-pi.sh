#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_PATH="$ROOT_DIR/dist/API for Cursor.app"
TIMEOUT_SECONDS=25
TEMP_DIRS=()
TEMP_FILES=()

usage() {
  cat <<USAGE
Usage: $0 [--app PATH] [--timeout SECONDS]

Launch the packaged macOS app, create an isolated pi config for API for Cursor,
verify pi can read both Composer models, and verify pi surfaces the local API's
locked-key response without touching user configs.

  --app PATH    App bundle to launch. Defaults to dist/API for Cursor.app.
  --timeout N   Seconds to wait for app and pi checks. Default: 25.
USAGE
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --app)
      APP_PATH="${2:-}"
      [ -n "$APP_PATH" ] || { echo "--app requires a path" >&2; exit 64; }
      shift
      ;;
    --timeout)
      TIMEOUT_SECONDS="${2:-}"
      [ -n "$TIMEOUT_SECONDS" ] || { echo "--timeout requires seconds" >&2; exit 64; }
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 64
      ;;
  esac
  shift
done

fail() {
  echo "pi smoke check failed: $*" >&2
  exit 1
}

cleanup() {
  for file in "${TEMP_FILES[@]+"${TEMP_FILES[@]}"}"; do
    rm -f "$file"
  done
  for dir in "${TEMP_DIRS[@]+"${TEMP_DIRS[@]}"}"; do
    rm -rf "$dir"
  done
  osascript -e 'tell application id "ai.standardagents.api2agent" to quit' >/dev/null 2>&1 || true
}
trap cleanup EXIT

if ! command -v pi >/dev/null 2>&1; then
  echo "Skipping pi smoke check; pi is not installed."
  exit 0
fi

smoke_output="$(mktemp "${TMPDIR:-/tmp}/api-for-cursor-pi-app.XXXXXX")"
TEMP_FILES+=("$smoke_output")

"$ROOT_DIR/Scripts/smoke-app.sh" --app "$APP_PATH" --require-server --keep-running --timeout "$TIMEOUT_SECONDS" >"$smoke_output"
cat "$smoke_output"

port="$(sed -nE 's/.*http:\/\/127\.0\.0\.1:([0-9]+)\/health.*/\1/p' "$smoke_output" | head -1)"
[ -n "$port" ] || fail "could not determine local API port from app smoke output"
status="$(sed -nE 's/.*\(([^()]*)\)\.*/\1/p' "$smoke_output" | head -1)"

temp_home="$(mktemp -d "${TMPDIR:-/tmp}/api-for-cursor-pi-home.XXXXXX")"
agent_dir="$temp_home/.pi/agent"
TEMP_DIRS+=("$temp_home")
mkdir -p "$agent_dir"

cat > "$agent_dir/models.json" <<JSON
{
  "providers": {
    "api2agent": {
      "baseUrl": "http://127.0.0.1:$port/v1",
      "apiKey": "cursor-local",
      "authHeader": true,
      "api": "openai-completions",
      "models": [
        {
          "id": "composer-2.5",
          "name": "Composer 2.5",
          "api": "openai-completions",
          "reasoning": false,
          "input": ["text"],
          "contextWindow": 200000,
          "maxTokens": 65536,
          "cost": { "input": 0.5, "output": 2.5, "cacheRead": 0, "cacheWrite": 0 },
          "limit": { "context": 200000, "output": 65536 },
          "compat": {
            "supportsUsageInStreaming": true,
            "maxTokensField": "max_tokens",
            "requiresAssistantAfterToolResult": false
          }
        },
        {
          "id": "composer-2.5-fast",
          "name": "Composer 2.5 Fast",
          "api": "openai-completions",
          "reasoning": false,
          "input": ["text"],
          "contextWindow": 200000,
          "maxTokens": 65536,
          "cost": { "input": 3, "output": 15, "cacheRead": 0, "cacheWrite": 0 },
          "limit": { "context": 200000, "output": 65536 },
          "compat": {
            "supportsUsageInStreaming": true,
            "maxTokensField": "max_tokens",
            "requiresAssistantAfterToolResult": false
          }
        }
      ]
    }
  }
}
JSON

models_output="$(HOME="$temp_home" PI_CODING_AGENT_DIR="$agent_dir" pi --list-models api2agent 2>&1)"
printf '%s\n' "$models_output"
grep -F "api2agent  composer-2.5" <<<"$models_output" >/dev/null || fail "pi did not list composer-2.5"
grep -F "api2agent  composer-2.5-fast" <<<"$models_output" >/dev/null || fail "pi did not list composer-2.5-fast"

if [ "$status" = "needs_unlock" ]; then
  run_output="$(mktemp "${TMPDIR:-/tmp}/api-for-cursor-pi-run.XXXXXX")"
  TEMP_FILES+=("$run_output")
  (
    HOME="$temp_home" PI_CODING_AGENT_DIR="$agent_dir" pi --provider api2agent --model composer-2.5 --no-session -p "say hello" >"$run_output" 2>&1
  ) &
  run_pid=$!
  deadline=$((SECONDS + TIMEOUT_SECONDS))
  while kill -0 "$run_pid" >/dev/null 2>&1; do
    if [ "$SECONDS" -ge "$deadline" ]; then
      kill "$run_pid" >/dev/null 2>&1 || true
      wait "$run_pid" >/dev/null 2>&1 || true
      fail "pi run did not finish before timeout"
    fi
    sleep 0.5
  done
  wait "$run_pid" >/dev/null 2>&1 || true
  cat "$run_output"
  grep -F "Saved Cursor API key is locked" "$run_output" >/dev/null || fail "pi did not surface the local locked-key response"
else
  echo "Skipping locked-key pi run check because local API status is $status."
fi

echo "Verified pi can use the isolated API for Cursor provider config."
