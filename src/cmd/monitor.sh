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

POOL_MD="$KEY_DIR/pool.md"

# Build an OSC 8 clickable hyperlink: $1=absolute file path, $2=label text.
# Falls back to the path itself if the file doesn't exist.
mc_file_link() {
  local path="$1" label="$2"
  if [[ -f "$path" ]]; then
    printf '\033]8;;file://%s\033\\\033[4m%s\033[24m\033]8;;\033\\' "$path" "$label"
  else
    printf '%s' "(missing: $path)"
  fi
}

while true; do
  # Refresh the rendered global pool for this key so the link below opens
  # an up-to-date file. compact.sh is cheap (jq + tail).
  "$LIB_DIR/compact.sh" "$KEY" >/dev/null 2>&1 || true

  clear
  printf '\033[1;36mmemory-claude\033[0m · \033[1m%s\033[0m   (%s)\n' "$KEY" "$(date +%H:%M:%S)"
  shared_link=$(mc_file_link "$POOL_MD" "open shared memory (pool.md)")
  printf 'shared memory for this key → %s\n' "$shared_link"
  printf '────────────────────────────────────────────────────────────────────\n\n'

  printf '\033[1mCONNECTED SESSIONS\033[0m\n'
  if [[ -f "$KEY_DIR/sessions.json" ]]; then
    count=$(jq '.sessions | length' "$KEY_DIR/sessions.json" 2>/dev/null || echo 0)
    if (( count > 0 )); then
      jq -r '.sessions[]? | [.session_id, (.pid|tostring), .cwd, .last_heartbeat] | @tsv' \
        "$KEY_DIR/sessions.json" 2>/dev/null \
        | while IFS=$'\t' read -r sid pid cwd hb; do
            snap="$KEY_DIR/snapshots/${sid}-init.md"
            sid_short="${sid:0:8}"
            link=$(mc_file_link "$snap" "session start snapshot")
            printf '  %s  pid=%s  cwd=%s  heartbeat=%s  %s\n' \
              "$sid_short" "$pid" "$cwd" "$hb" "$link"
          done
    else
      echo "  (none)"
    fi
  else
    echo "  (no sessions.json)"
  fi

  printf '\n\033[1mPOOL TAIL (last 25)\033[0m\n'
  if [[ -f "$KEY_DIR/pool.ndjson" ]] && [[ -s "$KEY_DIR/pool.ndjson" ]]; then
    tail -n 25 "$KEY_DIR/pool.ndjson" | jq -r '
      (if .git then " @\(.git.branch)" else "" end) as $branch
      | (if (.tags // []) | length > 0
         then "  #\(((.tags // []) | join(" #")))"
         else "" end) as $tagstr
      | if .kind == "summary" then
          "  [\(.ts[11:19]) \(.sid[0:4])\($branch)] SUMMARY: \(.text)\($tagstr)"
        elif .kind == "note" then
          "  [\(.ts[11:19]) NOTE\($branch)] \(.text)\($tagstr)"
        elif .kind == "automemory" then
          "  [\(.ts[11:19]) \(.sid[0:4])] AUTOMEM (\(.type // "?")) \(.name): \(.description // "" | .[0:120])\($tagstr)"
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
