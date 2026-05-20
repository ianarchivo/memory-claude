#!/usr/bin/env bash
# UserPromptSubmit hook — heartbeat + emit pool delta as additionalContext.

set -euo pipefail

[[ -z "${MEMORY_CLAUDE_KEY:-}" ]] && { echo '{}'; exit 0; }

cat >/dev/null  # discard hook input

LIB_DIR="${MC_INSTALL_ROOT:-$HOME/.memory-claude}/lib"
# shellcheck disable=SC1091
source "$LIB_DIR/core.sh"
# shellcheck disable=SC1091
source "$LIB_DIR/locking.sh"

KEY="$MEMORY_CLAUDE_KEY"
KEY_DIR="$(mc_key_dir "$KEY")"
SID="${MEMORY_CLAUDE_SESSION_ID:-${CLAUDE_CODE_SESSION_ID:-unknown}}"
exec 2>>"$KEY_DIR/log"

NOW="$(mc_now)"
POOL="$KEY_DIR/pool.ndjson"
SESS="$KEY_DIR/sessions.json"

# Heartbeat
SESS_LOCK="$KEY_DIR/.sessions.lock"
if mc_lock_acquire "$SESS_LOCK" 50; then
  tmp=$(mktemp)
  jq --arg sid "$SID" --arg now "$NOW" '
    .sessions = (.sessions // []) | map(
      if .session_id == $sid then .last_heartbeat = $now else . end)
  ' "$SESS" > "$tmp" 2>/dev/null && mv "$tmp" "$SESS" || rm -f "$tmp"
  mc_lock_release "$SESS_LOCK"
fi

# Read delta
CURSOR_FILE="$KEY_DIR/seen/$SID.cursor"
LAST_OFFSET=$(cat "$CURSOR_FILE" 2>/dev/null || echo 0)
CUR_OFFSET=$(wc -c < "$POOL" | tr -d ' ')

if (( CUR_OFFSET <= LAST_OFFSET )); then
  echo '{}'; exit 0
fi

# Extract bytes from LAST_OFFSET+1 to EOF
DELTA=$(tail -c +$((LAST_OFFSET + 1)) "$POOL")

# Filter to other sessions' summary/note/automemory entries
RENDERED_SUMMARY=$(printf '%s\n' "$DELTA" | jq -r --arg sid "$SID" '
  select(. != null) |
  select(.sid != $sid) |
  select(.kind == "summary" or .kind == "note") |
  "- [\(.ts[11:16]) \(.sid[0:4])] \(.text)"
' 2>/dev/null || true)

RENDERED_AUTOMEM=$(printf '%s\n' "$DELTA" | jq -r --arg sid "$SID" '
  select(. != null) |
  select(.sid != $sid) |
  select(.kind == "automemory") |
  "- [auto-memory · \(.sid[0:4]) in \(.cwd | split("/") | last)] (\(.type // "?")) \(.name): \(.description // "") — \(.body_excerpt // "" | .[0:200])"
' 2>/dev/null || true)

# Always advance cursor (even if no relevant entries) so we don't re-read.
echo "$CUR_OFFSET" > "$CURSOR_FILE"

if [[ -z "${RENDERED_SUMMARY// /}" ]] && [[ -z "${RENDERED_AUTOMEM// /}" ]]; then
  echo '{}'; exit 0
fi

CTX="## memory-claude pool updates since your last turn"
if [[ -n "${RENDERED_SUMMARY// /}" ]]; then
  CTX=$'\n'"$CTX"$'\n\n### Findings from other sessions\n'"$RENDERED_SUMMARY"
fi
if [[ -n "${RENDERED_AUTOMEM// /}" ]]; then
  CTX="$CTX"$'\n\n### Auto-memory written by other sessions\n'"$RENDERED_AUTOMEM"
fi

jq -n --arg ctx "$CTX" '{
  hookSpecificOutput: {
    hookEventName: "UserPromptSubmit",
    additionalContext: $ctx
  }
}'
