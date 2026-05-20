#!/usr/bin/env bash
# monitor.sh — live view of sessions + pool tail for a key.

set -euo pipefail

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)"
# shellcheck disable=SC1091
source "$LIB_DIR/core.sh"

mc_require_jq
KEY="${1:?usage: monitor <key>}"
KEY_DIR=$(mc_key_dir "$KEY")

if [[ ! -d "$KEY_DIR" ]]; then
  echo "memory-claude: key '$KEY' not found at $KEY_DIR" >&2
  exit 1
fi

trap 'tput cnorm 2>/dev/null; printf "\n"; exit 0' INT TERM
tput civis 2>/dev/null || true

while true; do
  clear
  printf '\033[1;36mmemory-claude\033[0m · \033[1m%s\033[0m   (%s)\n' "$KEY" "$(date +%H:%M:%S)"
  printf '────────────────────────────────────────────────────────────────────\n\n'

  printf '\033[1mCONNECTED SESSIONS\033[0m\n'
  if [[ -f "$KEY_DIR/sessions.json" ]]; then
    count=$(jq '.sessions | length' "$KEY_DIR/sessions.json" 2>/dev/null || echo 0)
    if (( count > 0 )); then
      jq -r '.sessions[]? | "  \(.session_id[0:8])  pid=\(.pid)  cwd=\(.cwd)  heartbeat=\(.last_heartbeat)"' \
        "$KEY_DIR/sessions.json" 2>/dev/null
    else
      echo "  (none)"
    fi
  else
    echo "  (no sessions.json)"
  fi

  printf '\n\033[1mPOOL TAIL (last 25)\033[0m\n'
  if [[ -f "$KEY_DIR/pool.ndjson" ]] && [[ -s "$KEY_DIR/pool.ndjson" ]]; then
    tail -n 25 "$KEY_DIR/pool.ndjson" | jq -r '
      if .kind == "summary" or .kind == "note" then
        "  [\(.ts[11:19]) \(.sid[0:4])] \(.kind | ascii_upcase): \(.text)"
      elif .kind == "automemory" then
        "  [\(.ts[11:19]) \(.sid[0:4])] AUTOMEM (\(.type // "?")) \(.name): \(.description // "" | .[0:120])"
      elif .kind == "join" then
        "  [\(.ts[11:19]) \(.sid[0:4])] JOIN \(.cwd // "")"
      elif .kind == "leave" then
        "  [\(.ts[11:19]) \(.sid[0:4])] LEAVE"
      else
        "  [\(.ts[11:19]) \(.sid[0:4])] \(.kind | ascii_upcase)"
      end
    ' 2>/dev/null
  else
    echo "  (pool empty)"
  fi

  printf '\n\033[2m(ctrl-c to exit · refreshes every 1s)\033[0m\n'
  sleep 1
done
