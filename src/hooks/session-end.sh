#!/usr/bin/env bash
# SessionEnd hook — deregister session, append leave event.

set -euo pipefail

[[ -z "${MEMORY_CLAUDE_KEY:-}" ]] && { echo '{}'; exit 0; }

cat >/dev/null

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
SESS="$KEY_DIR/sessions.json"
SESS_LOCK="$KEY_DIR/.sessions.lock"

if mc_lock_acquire "$SESS_LOCK"; then
  tmp=$(mktemp)
  jq --arg sid "$SID" '
    .sessions = ((.sessions // []) | map(select(.session_id != $sid)))
  ' "$SESS" > "$tmp" 2>/dev/null && mv "$tmp" "$SESS" || rm -f "$tmp"
  mc_lock_release "$SESS_LOCK"
fi

leave_line=$(jq -nc --arg ts "$NOW" --arg sid "$SID" '{ts:$ts, sid:$sid, kind:"leave"}')
mc_append_locked "$KEY_DIR/pool.ndjson" "$leave_line"

echo '{}'
