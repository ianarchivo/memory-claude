#!/usr/bin/env bash
# compact.sh — render pool.ndjson into pool.md, plus growth-bound rotation.
# usage:
#   compact.sh <key>            # write pool.md and emit it on stdout
#   compact.sh <key> --rotate   # rotate pool.ndjson if it has grown too large

set -euo pipefail

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$LIB_DIR/core.sh"

mc_require_jq

KEY="${1:?usage: compact.sh <key> [--rotate]}"
MODE="${2:-render}"

KEY_DIR=$(mc_key_dir "$KEY")
POOL="$KEY_DIR/pool.ndjson"
MD="$KEY_DIR/pool.md"
SESS="$KEY_DIR/sessions.json"

[[ -f "$POOL" ]] || : > "$POOL"

# --- rotation: when pool.ndjson > 256KB or > 500 entries, keep last 100 summaries verbatim
if [[ "$MODE" == "--rotate" ]]; then
  size=$(wc -c < "$POOL" | tr -d ' ')
  lines=$(wc -l < "$POOL" | tr -d ' ')
  if (( size > 262144 )) || (( lines > 500 )); then
    ts=$(date -u +%Y%m%dT%H%M%SZ)
    cp "$POOL" "$KEY_DIR/pool.ndjson.${ts}.bak"
    # Keep last 100 summary/automemory entries plus all from currently connected sessions
    active_sids=$(jq -r '.sessions[]?.session_id // empty' "$SESS" 2>/dev/null | sort -u)
    tmp=$(mktemp)
    # First pass: emit last 100 lines verbatim
    tail -n 100 "$POOL" > "$tmp"
    # Second pass: emit any entries from active sessions not already in tail
    if [[ -n "$active_sids" ]]; then
      while IFS= read -r sid; do
        [[ -z "$sid" ]] && continue
        grep -F "\"sid\":\"$sid\"" "$POOL" | tail -n 50 >> "$tmp" || true
      done <<< "$active_sids"
    fi
    # dedupe, keep order of last occurrence
    awk '!seen[$0]++' "$tmp" > "$POOL"
    rm -f "$tmp"
    # Prune backups beyond 3
    ls -1t "$KEY_DIR"/pool.ndjson.*.bak 2>/dev/null | tail -n +4 | xargs -r rm -f || true
  fi
fi

# --- render: pool.md
render() {
  local sess_count entry_count last_ts
  sess_count=$(jq '.sessions | length' "$SESS" 2>/dev/null || echo 0)
  entry_count=$(wc -l < "$POOL" | tr -d ' ')
  last_ts=$(tail -n1 "$POOL" 2>/dev/null | jq -r '.ts // empty' 2>/dev/null || true)
  [[ -z "$last_ts" ]] && last_ts="(empty)"

  printf '# Shared memory — %s\n' "$KEY"
  printf '*%s sessions connected · %s entries · last update %s*\n\n' \
    "$sess_count" "$entry_count" "$last_ts"

  # Recent findings (summary + note + automemory)
  printf '## Recent activity\n'
  tail -n 40 "$POOL" | jq -r '
    select(.kind == "summary" or .kind == "note") |
    "- [\(.ts[11:16]) \(.sid[0:4])] \(.text)"
  ' 2>/dev/null || true
  tail -n 40 "$POOL" | jq -r '
    select(.kind == "automemory") |
    "- [auto-memory · \(.sid[0:4]) in \(.cwd | split("/") | last)] (\(.type // "?")) \(.name): \(.description // .body_excerpt // "")"
  ' 2>/dev/null || true

  printf '\n## Connected now\n'
  jq -r '.sessions[]? | "- \(.session_id[0:8]) (pid \(.pid)) \(.cwd)"' "$SESS" 2>/dev/null || true
}

render | tee "$MD"
