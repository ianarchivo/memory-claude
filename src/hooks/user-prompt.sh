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

# Build tag filter args. Empty env -> empty arrays (no filtering).
if [[ -n "${MEMORY_CLAUDE_TAGS:-}" ]]; then
  ALLOW_TAGS=$(printf '%s' "$MEMORY_CLAUDE_TAGS" | jq -R '
    split(",") | map(ascii_downcase | gsub("^\\s+|\\s+$"; "")) | map(select(length > 0))')
else
  ALLOW_TAGS='[]'
fi
if [[ -n "${MEMORY_CLAUDE_EXCLUDE_TAGS:-}" ]]; then
  EXCLUDE_TAGS=$(printf '%s' "$MEMORY_CLAUDE_EXCLUDE_TAGS" | jq -R '
    split(",") | map(ascii_downcase | gsub("^\\s+|\\s+$"; "")) | map(select(length > 0))')
else
  EXCLUDE_TAGS='[]'
fi
STRICT="${MEMORY_CLAUDE_TAGS_STRICT:-0}"

# Common jq program: visibility filter (self vs note relaxation) + tag filter.
# Reused across the summary/note and automemory renders.
JQ_VISIBILITY='
  def matches_tags($allow; $exclude; $strict):
    (.tags // []) as $t |
    if ($exclude | length) > 0
       and (any($t[]; . as $x | $exclude | index($x)))
      then false
    elif ($allow | length) == 0 then true
    elif ($t | length) == 0 then ($strict != "1")
    else any($t[]; . as $x | $allow | index($x))
    end;
  select(. != null)
  | select((.sid != $sid) or (.kind == "note"))
  | select(matches_tags($allow; $exclude; $strict))
'

# Filter to other sessions summary/note entries.
# Notes are always visible (filter relaxation in JQ_VISIBILITY above).
# Concatenate JQ_VISIBILITY (double-quoted to expand) with a single-quoted
# tail (so jq's $branch/$tagstr aren't mistaken for bash variables).
RENDERED_SUMMARY=$(printf '%s\n' "$DELTA" | jq -r \
  --arg sid "$SID" \
  --argjson allow "$ALLOW_TAGS" \
  --argjson exclude "$EXCLUDE_TAGS" \
  --arg strict "$STRICT" \
  "$JQ_VISIBILITY"'
  | select(.kind == "summary" or .kind == "note")
  | (if .git then " @\(.git.branch)" else "" end) as $branch
  | (if (.tags // []) | length > 0
     then "  #\(((.tags // []) | join(" #")))"
     else "" end) as $tagstr
  | if .kind == "note" then
      "- [\(.ts[11:16]) NOTE\($branch)] \(.text)\($tagstr)"
    else
      "- [\(.ts[11:16]) \(.sid[0:4])\($branch)] \(.text)"
      + (if .prompt then "\n  Q: \(.prompt[0:140])" else "" end)
      + $tagstr
    end
' 2>/dev/null || true)

RENDERED_AUTOMEM=$(printf '%s\n' "$DELTA" | jq -r \
  --arg sid "$SID" \
  --argjson allow "$ALLOW_TAGS" \
  --argjson exclude "$EXCLUDE_TAGS" \
  --arg strict "$STRICT" \
  "$JQ_VISIBILITY"'
  | select(.kind == "automemory")
  | "- [auto-memory · \(.sid[0:4]) in \(.cwd | split("/") | last)] (\(.type // "?")) \(.name): \(.description // "") — \(.body_excerpt // "" | .[0:200])"
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

# Opt-in: persist the injected delta to disk for forensic review.
if [[ "${MEMORY_CLAUDE_DEBUG:-0}" == "1" ]]; then
  ts_epoch="$(mc_now_epoch)"
  mkdir -p "$KEY_DIR/snapshots"
  printf '%s\n' "$CTX" > "$KEY_DIR/snapshots/${SID}-turn-${ts_epoch}.md" 2>/dev/null || true
fi

jq -n --arg ctx "$CTX" '{
  hookSpecificOutput: {
    hookEventName: "UserPromptSubmit",
    additionalContext: $ctx
  }
}'
