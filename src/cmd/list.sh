#!/usr/bin/env bash
# list.sh —  list all keys, or sessions on a given key.

set -euo pipefail

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)"
# shellcheck disable=SC1091
source "$LIB_DIR/core.sh"

mc_require_jq

KEY="${1:-}"

if [[ -z "$KEY" ]]; then
  # List all keys
  keys_json="$MC_ROOT/keys.json"
  if [[ ! -f "$keys_json" ]]; then
    echo "memory-claude: no keys yet."; exit 0
  fi
  printf '%-32s  %-22s  %s\n' "KEY" "LAST ACTIVE" "POOL DIR"
  jq -r '.keys[]? | "\(.key)\t\(.last_active)\t\(.key)"' "$keys_json" \
    | while IFS=$'\t' read -r k la _; do
        printf '%-32s  %-22s  %s\n' "$k" "$la" "$MC_ROOT/$k"
      done
  exit 0
fi

# List sessions on this key
KEY_DIR=$(mc_key_dir "$KEY")
if [[ ! -d "$KEY_DIR" ]]; then
  echo "memory-claude: key '$KEY' not found." >&2; exit 1
fi

printf '\033[1mActive sessions on %s:\033[0m\n' "$KEY"
if [[ -s "$KEY_DIR/sessions.json" ]]; then
  jq -r '.sessions[]? | "  \(.session_id)  pid=\(.pid)  cwd=\(.cwd)  joined=\(.joined_at)"' \
    "$KEY_DIR/sessions.json" 2>/dev/null
fi

printf '\n\033[1mHistorical sessions on %s:\033[0m\n' "$KEY"
if [[ -s "$KEY_DIR/pool.ndjson" ]]; then
  jq -r 'select(.kind == "join") | "  \(.sid)  cwd=\(.cwd)  joined=\(.ts)"' \
    "$KEY_DIR/pool.ndjson" 2>/dev/null \
    | awk '!seen[$0]++'
fi
