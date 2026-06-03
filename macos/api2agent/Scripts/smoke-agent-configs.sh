#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TIMEOUT_SECONDS=120

usage() {
  cat <<USAGE
Usage: $0 [--timeout SECONDS]

Verify all supported one-click agent config writers in isolated temporary homes.
This does not touch user configs. It exercises OpenCode, Codex, VS Code,
Cline, Kilo Code, pi, Continue, Aider, and Roo Code provisioning/status logic.

  --timeout N   Seconds to allow for the isolated config smoke. Default: 120.
USAGE
}

while [ "$#" -gt 0 ]; do
  case "$1" in
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
  echo "Agent config smoke check failed: $*" >&2
  exit 1
}

run_with_timeout() {
  local seconds="$1"
  shift
  "$@" &
  local pid=$!
  local deadline=$((SECONDS + seconds))
  while kill -0 "$pid" >/dev/null 2>&1; do
    if [ "$SECONDS" -ge "$deadline" ]; then
      kill "$pid" >/dev/null 2>&1 || true
      wait "$pid" >/dev/null 2>&1 || true
      return 124
    fi
    sleep 0.5
  done
  wait "$pid"
}

run_with_timeout "$TIMEOUT_SECONDS" swift test --package-path "$ROOT_DIR" --filter AgentProvisionerTests \
  || fail "isolated AgentProvisionerTests did not pass"

echo "Verified isolated one-click config provisioning for every supported agent."
