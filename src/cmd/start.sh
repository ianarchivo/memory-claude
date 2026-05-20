#!/usr/bin/env bash
# start.sh — mint or join a key and exec the real claude binary.
# usage: start.sh <key> [passthrough-args...]
#   - if key is empty, generate a new one
#   - passthrough args (e.g. --resume <uuid>, --model ...) forward to claude

set -euo pipefail

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)"
# shellcheck disable=SC1091
source "$LIB_DIR/core.sh"

mc_require_jq

KEY="${1:-}"; shift || true
PASS_ARGS=("$@")

# Detect --resume in passthrough args so we can reuse the same session id
RESUME_ID=""
i=0
while (( i < ${#PASS_ARGS[@]} )); do
  if [[ "${PASS_ARGS[$i]}" == "--resume" ]] && (( i + 1 < ${#PASS_ARGS[@]} )); then
    RESUME_ID="${PASS_ARGS[$((i+1))]}"
    break
  fi
  ((i++))
done

mkdir -p "$MC_ROOT"

# Decide whether this launch is minting a new key or joining an existing one.
# Track BEFORE mc_ensure_key_dir creates the directory.
WAS_NEW=0
if [[ -z "$KEY" ]]; then
  KEY=$(mc_gen_key)
  WAS_NEW=1
elif [[ ! -d "$MC_ROOT/$KEY" ]]; then
  WAS_NEW=1
fi

mc_ensure_key_dir "$KEY"
mc_register_key "$KEY"

KEY_DIR=$(mc_key_dir "$KEY")
if (( WAS_NEW )); then
  printf '\033[1;36m[memory-claude]\033[0m minted new key: \033[1m%s\033[0m\n' "$KEY" >&2
else
  printf '\033[1;36m[memory-claude]\033[0m joining key: \033[1m%s\033[0m\n' "$KEY" >&2
fi
printf '\033[1;36m[memory-claude]\033[0m pool: %s\n' "$KEY_DIR" >&2

# Validate --resume id belongs to this key
if [[ -n "$RESUME_ID" ]]; then
  if ! grep -F "\"sid\":\"$RESUME_ID\"" "$KEY_DIR/pool.ndjson" >/dev/null 2>&1; then
    echo "memory-claude: session $RESUME_ID was not started under key '$KEY'." >&2
    echo "Use 'memory-claude $KEY list' to see sessions, or omit --resume to start a new one." >&2
    exit 1
  fi
  SESSION_ID="$RESUME_ID"
else
  SESSION_ID="$(mc_uuid)"
fi

# Build pool snapshot for initial system prompt injection
SNAPSHOT_FILE="$KEY_DIR/snapshots/${SESSION_ID}-init.md"
mkdir -p "$KEY_DIR/snapshots"
"$LIB_DIR/compact.sh" "$KEY" > "$SNAPSHOT_FILE" 2>/dev/null || : > "$SNAPSHOT_FILE"

HEADER=$(cat <<EOF
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

# Build hook block
HOOK_BIN="$MC_ROOT/bin"
HOOKS_JSON=$(jq -n --arg hb "$HOOK_BIN" '{
  hooks: {
    SessionStart: [{matcher: "", hooks: [{type: "command", command: ($hb + "/hook-session-start.sh"), timeout: 5}]}],
    UserPromptSubmit: [{matcher: "", hooks: [{type: "command", command: ($hb + "/hook-user-prompt.sh"), timeout: 5}]}],
    Stop: [{matcher: "", hooks: [{type: "command", command: ($hb + "/hook-stop.sh"), timeout: 30}]}],
    SessionEnd: [{matcher: "", hooks: [{type: "command", command: ($hb + "/hook-session-end.sh"), timeout: 5}]}]
  }
}')

export MEMORY_CLAUDE_KEY="$KEY"
export MEMORY_CLAUDE_SESSION_ID="$SESSION_ID"
export MEMORY_CLAUDE_DIR="$KEY_DIR"
export MC_INSTALL_ROOT="$MC_ROOT"

REAL_CLAUDE=$(mc_resolve_real_claude)
if [[ -z "$REAL_CLAUDE" ]] || [[ ! -x "$REAL_CLAUDE" ]]; then
  echo "memory-claude: could not resolve a 'claude' binary." >&2
  echo "Looked at ~/.local/bin/claude and \$PATH." >&2
  exit 1
fi

printf '\033[1;36m[memory-claude]\033[0m session: %s\n' "$SESSION_ID" >&2
printf '\033[1;36m[memory-claude]\033[0m launching: %s\n' "$REAL_CLAUDE" >&2

# If user passed --resume, claude expects --resume <id>; we set --session-id ourselves only when not resuming.
EXTRA_FLAGS=()
if [[ -z "$RESUME_ID" ]]; then
  EXTRA_FLAGS+=(--session-id "$SESSION_ID")
fi

exec "$REAL_CLAUDE" \
  ${EXTRA_FLAGS[@]+"${EXTRA_FLAGS[@]}"} \
  --append-system-prompt "$HEADER" \
  --settings "$HOOKS_JSON" \
  --setting-sources user,local \
  ${PASS_ARGS[@]+"${PASS_ARGS[@]}"}
