#!/usr/bin/env bash
# Stop hook — capture last assistant turn AND mirror new auto-memory entries.

set -euo pipefail

[[ -z "${MEMORY_CLAUDE_KEY:-}" ]] && { echo '{}'; exit 0; }

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
CWD="$(pwd)"
POOL="$KEY_DIR/pool.ndjson"

# Read hook stdin for transcript_path
HOOK_INPUT="$(cat || true)"
TRANSCRIPT=""
if [[ -n "$HOOK_INPUT" ]]; then
  TRANSCRIPT=$(printf '%s' "$HOOK_INPUT" | jq -r '.transcript_path // empty' 2>/dev/null || true)
fi
if [[ -z "$TRANSCRIPT" ]]; then
  CWD_SLUG=$(mc_encode_cwd "$CWD")
  TRANSCRIPT="$HOME/.claude/projects/$CWD_SLUG/$SID.jsonl"
fi

# --- 1) Turn summary
if [[ -f "$TRANSCRIPT" ]]; then
  if command -v tac >/dev/null 2>&1; then
    REV_CAT="tac"
  else
    REV_CAT="tail -r"
  fi

  LAST_TEXT=$($REV_CAT "$TRANSCRIPT" 2>/dev/null \
    | grep -m1 '"type":"assistant"' \
    | jq -r '.. | objects | select(.type == "text") | .text' 2>/dev/null \
    | tr -d '\000' || true)

  if [[ -n "${LAST_TEXT// /}" ]]; then
    SUMMARY=$(printf '%s' "$LAST_TEXT" | "$LIB_DIR/compress.sh" 2>/dev/null || true)
    if [[ -n "${SUMMARY// /}" ]]; then
      while IFS= read -r line; do
        [[ -z "${line// /}" ]] && continue
        # Strip leading bullet glyphs if Haiku output included them
        clean=$(printf '%s' "$line" | sed -E 's/^[[:space:]]*[-*•][[:space:]]*//')
        json_line=$(jq -nc --arg ts "$NOW" --arg sid "$SID" --arg cwd "$CWD" --arg text "$clean" \
          '{ts:$ts, sid:$sid, kind:"summary", text:$text, cwd:$cwd}')
        mc_append_locked "$POOL" "$json_line"
      done <<< "$SUMMARY"
    fi
  fi
fi

# --- 2) Auto-memory mirror
AUTOMEM_DIR=$(mc_automemory_dir_for_cwd "$CWD")
if [[ -d "$AUTOMEM_DIR" ]]; then
  MTIME_FILE="$KEY_DIR/seen/$SID.automemory-mtime"
  LAST_MTIME=$(cat "$MTIME_FILE" 2>/dev/null || echo 0)
  NEW_MAX="$LAST_MTIME"
  count=0

  # Find files modified after LAST_MTIME. Use stat for portability on macOS.
  while IFS= read -r -d '' file; do
    mtime=$(stat -f '%m' "$file" 2>/dev/null || stat -c '%Y' "$file" 2>/dev/null || echo 0)
    if (( mtime > LAST_MTIME )); then
      # Parse frontmatter
      name=$(awk '/^name:/{print substr($0,index($0,":")+2); exit}' "$file" | tr -d '"' | sed 's/[[:space:]]*$//')
      desc=$(awk '/^description:/{print substr($0,index($0,":")+2); exit}' "$file" | tr -d '"' | sed 's/[[:space:]]*$//')
      type=$(awk '/^[[:space:]]*type:/{print substr($0,index($0,":")+2); exit}' "$file" | tr -d '"' | sed 's/[[:space:]]*$//')
      [[ -z "$name" ]] && name=$(basename "$file" .md)

      # Body excerpt: skip frontmatter
      body=$(awk 'BEGIN{infm=0; seen=0}
                  /^---[[:space:]]*$/ { if (!seen) { infm=1; seen=1; next } else if (infm) { infm=0; next } }
                  !infm { print }' "$file" \
             | tr '\n' ' ' \
             | sed -E 's/  +/ /g' \
             | head -c 300)

      json_line=$(jq -nc --arg ts "$NOW" --arg sid "$SID" --arg cwd "$CWD" \
        --arg path "$file" --arg name "$name" --arg type "$type" \
        --arg desc "$desc" --arg body "$body" '
        {ts:$ts, sid:$sid, kind:"automemory", cwd:$cwd, path:$path,
         name:$name, type:$type, description:$desc, body_excerpt:$body}')
      mc_append_locked "$POOL" "$json_line"

      (( mtime > NEW_MAX )) && NEW_MAX=$mtime
      (( ++count >= 10 )) && break
    fi
  done < <(find "$AUTOMEM_DIR" -name '*.md' -type f -print0 2>/dev/null)

  echo "$NEW_MAX" > "$MTIME_FILE"
fi

# Advance own cursor so we don't re-inject our own writes via UserPromptSubmit
wc -c < "$POOL" | tr -d ' ' > "$KEY_DIR/seen/$SID.cursor"

# Trigger rotation if needed
"$LIB_DIR/compact.sh" "$KEY" --rotate >/dev/null 2>&1 || true

echo '{}'
