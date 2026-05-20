#!/usr/bin/env bash
# SessionStart hook — register session in sessions.json, append join event,
# initialize seen cursors, emit pool snapshot as additionalContext.
#
# Invoked by Claude Code with JSON on stdin. We discard the input and emit
# a single JSON object on stdout.

set -euo pipefail

# No-op for any session that wasn't launched via memory-claude.
[[ -z "${MEMORY_CLAUDE_KEY:-}" ]] && { echo '{}'; exit 0; }

# Discard hook input
cat >/dev/null

LIB_DIR="${MC_INSTALL_ROOT:-$HOME/.memory-claude}/lib"
# shellcheck disable=SC1091
source "$LIB_DIR/core.sh"
# shellcheck disable=SC1091
source "$LIB_DIR/locking.sh"

# Redirect stderr to log so any diagnostic doesn't corrupt stdout
KEY="$MEMORY_CLAUDE_KEY"
KEY_DIR="$(mc_key_dir "$KEY")"
SID="${MEMORY_CLAUDE_SESSION_ID:-${CLAUDE_CODE_SESSION_ID:-unknown}}"
mkdir -p "$KEY_DIR"/{seen,snapshots}
exec 2>>"$KEY_DIR/log"

PID="${PPID:-$$}"
CWD="$(pwd)"
NOW="$(mc_now)"

mc_ensure_key_dir "$KEY"
mc_register_key "$KEY"

# 1) Register session in sessions.json
SESS="$KEY_DIR/sessions.json"
SESS_LOCK="$KEY_DIR/.sessions.lock"
mc_lock_acquire "$SESS_LOCK"
tmp=$(mktemp)
jq --arg sid "$SID" --argjson pid "$PID" --arg cwd "$CWD" --arg now "$NOW" '
  .sessions = ((.sessions // []) | map(select(.session_id != $sid))) +
              [{session_id:$sid, pid:$pid, cwd:$cwd, joined_at:$now, last_heartbeat:$now}]
' "$SESS" > "$tmp" && mv "$tmp" "$SESS"
mc_lock_release "$SESS_LOCK"

# 2) Append join event
JOIN_LINE=$(jq -nc --arg ts "$NOW" --arg sid "$SID" --arg cwd "$CWD" --argjson pid "$PID" \
  '{ts:$ts, sid:$sid, kind:"join", cwd:$cwd, pid:$pid}')
mc_append_locked "$KEY_DIR/pool.ndjson" "$JOIN_LINE"

# 3) Initialize seen cursors at EOF
wc -c < "$KEY_DIR/pool.ndjson" | tr -d ' ' > "$KEY_DIR/seen/$SID.cursor"

# Initialize automemory mtime cursor at the current max mtime in cwd's memory dir
AUTOMEM_DIR=$(mc_automemory_dir_for_cwd "$CWD")
if [[ -d "$AUTOMEM_DIR" ]]; then
  max_mtime=$(find "$AUTOMEM_DIR" -name '*.md' -type f -exec stat -f '%m' {} + 2>/dev/null | sort -n | tail -n1)
  [[ -z "$max_mtime" ]] && max_mtime=0
  echo "$max_mtime" > "$KEY_DIR/seen/$SID.automemory-mtime"
else
  echo 0 > "$KEY_DIR/seen/$SID.automemory-mtime"
fi

# 4) Build pool snapshot for additionalContext
SNAPSHOT_FILE="$KEY_DIR/snapshots/${SID}-init.md"
"$LIB_DIR/compact.sh" "$KEY" > "$SNAPSHOT_FILE" 2>>"$KEY_DIR/log"

CTX=$(cat <<EOF
# memory-claude shared memory — key: $KEY

You are part of a memory-claude shared session under key '$KEY'. Other Claude
sessions may be writing notes and auto-memory to a shared pool. At the start
of each user turn, NEW entries from other sessions will be injected as a delta.
Treat the pool as background knowledge — be concise, do not re-summarize it back.

When you reach a non-obvious conclusion, rule out an approach, or make a
decision a future session should inherit, run:
  memory-claude $KEY note "<finding>" --tag <topic>
to encode it intentionally. The auto-compressed Stop summary is a fallback,
not the primary memory channel — important decisions belong in explicit notes.

Current pool snapshot:

$(cat "$SNAPSHOT_FILE")
EOF
)

jq -n --arg ctx "$CTX" '{
  hookSpecificOutput: {
    hookEventName: "SessionStart",
    additionalContext: $ctx
  }
}'
