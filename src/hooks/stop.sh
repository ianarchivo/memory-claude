#!/usr/bin/env bash
# Stop hook — capture last assistant turn AND mirror new auto-memory entries.

set -euo pipefail

[[ -z "${MEMORY_CLAUDE_KEY:-}" ]] && { echo '{}'; exit 0; }

LIB_DIR="${MC_INSTALL_ROOT:-$HOME/.memory-claude}/lib"
# shellcheck disable=SC1091
source "$LIB_DIR/core.sh"
# shellcheck disable=SC1091
source "$LIB_DIR/locking.sh"
# tags.sh is newer than the original install — degrade gracefully for users
# who upgraded without re-running install.sh. When missing, we stub the
# extractor so the Stop hook keeps writing summaries (just without tags).
if [[ -f "$LIB_DIR/tags.sh" ]]; then
  # shellcheck disable=SC1091
  source "$LIB_DIR/tags.sh"
else
  mc_extract_tags() { :; }
fi

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
# Track the byte offset of the transcript we last summarized so we never
# emit a duplicate summary for the same assistant turn (re-runs, polls, etc.)
TR_CURSOR_FILE="$KEY_DIR/seen/$SID.transcript.cursor"
TR_LAST_OFFSET=$(cat "$TR_CURSOR_FILE" 2>/dev/null || echo 0)

LAST_TEXT=""
LAST_ASSISTANT_LINE=""
# Poll up to ~3 seconds (15 × 200ms) for a NEW assistant entry beyond our
# cursor. claude in -p mode flushes the assistant turn close to Stop firing,
# and on macOS reading a being-written file can also race.
for _attempt in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
  if [[ -f "$TRANSCRIPT" ]]; then
    cur_size=$(wc -c < "$TRANSCRIPT" 2>/dev/null | tr -d ' ' || echo 0)
    if (( cur_size > TR_LAST_OFFSET )); then
      # Read only bytes past the cursor; grep for assistant lines; take last.
      LAST_ASSISTANT_LINE=$(tail -c +$((TR_LAST_OFFSET + 1)) "$TRANSCRIPT" 2>/dev/null \
        | grep '"type":"assistant"' \
        | tail -n 1 || true)
      if [[ -n "$LAST_ASSISTANT_LINE" ]]; then
        # Extract concatenated text content blocks
        LAST_TEXT=$(printf '%s' "$LAST_ASSISTANT_LINE" \
          | jq -r '[.message.content[]? | select(.type=="text") | .text] | join(" ")' 2>/dev/null \
          | tr -d '\000' || true)
        if [[ -n "${LAST_TEXT// /}" ]]; then
          break
        fi
      fi
    fi
  fi
  sleep 0.2
done

# Advance transcript cursor to current EOF either way, so we never re-scan
# the same bytes on subsequent Stop invocations.
if [[ -f "$TRANSCRIPT" ]]; then
  wc -c < "$TRANSCRIPT" 2>/dev/null | tr -d ' ' > "$TR_CURSOR_FILE" || true
fi

# Git context, captured once per Stop, used by both summary and automemory
# branches. branch/sha can change mid-session (commits, checkouts), so we
# refresh each Stop. Cache to seen/<sid>.git for any downstream consumer.
GIT_BRANCH=""
GIT_SHA=""
if git -C "$CWD" rev-parse --git-dir >/dev/null 2>&1; then
  GIT_BRANCH=$(git -C "$CWD" branch --show-current 2>/dev/null)
  [[ -n "$GIT_BRANCH" ]] || GIT_BRANCH="(detached)"
  GIT_SHA=$(git -C "$CWD" rev-parse --short HEAD 2>/dev/null || echo "")
  printf '%s\t%s\n' "$GIT_BRANCH" "$GIT_SHA" > "$KEY_DIR/seen/$SID.git" 2>/dev/null || true
fi

if [[ -n "${LAST_TEXT// /}" ]]; then
  # Capture the user prompt that produced this turn. Walk the transcript
  # for type:"user" entries whose .message.content is a string (i.e. real
  # prompts — tool_result messages have array content and would otherwise
  # pollute this field). Take the last surviving entry.
  LAST_PROMPT=""
  if [[ -f "$TRANSCRIPT" ]]; then
    # Capture real user prompts: strings (not tool_result arrays), not
    # interrupt markers, length-bounded. Slash-command preambles like
    # `<command-name>/init</command-name>actual text` get the leading
    # `<...>` blocks stripped rather than rejected, so the user's real
    # prompt survives. After stripping, require non-empty content.
    LAST_PROMPT=$(jq -r '
      select(.type == "user"
             and (.message.content | type) == "string"
             and (.message.content | startswith("[Request interrupted") | not)
             and (.message.content | length) < 8192)
      | .message.content
      | sub("^(<[a-zA-Z][a-zA-Z0-9_-]*>[^<]*</[a-zA-Z][a-zA-Z0-9_-]*>)+"; "")
      | select(length > 0)
    ' "$TRANSCRIPT" 2>/dev/null | tail -n 1 || true)
  fi

  # Tags from cheap keyword extraction over the assistant text. Decoupled
  # from compression so all modes (rule-based, haiku, auto) get tags.
  TAGS_RAW=$(printf '%s' "$LAST_TEXT" | mc_extract_tags 2>/dev/null || true)
  TAGS_JSON=$(printf '%s' "$TAGS_RAW" | jq -R -s '
    split("\n") | map(select(length > 0))
  ' 2>/dev/null || echo '[]')

  SUMMARY=$(printf '%s' "$LAST_TEXT" | "$LIB_DIR/compress.sh" 2>/dev/null || true)
  if [[ -n "${SUMMARY// /}" ]]; then
    while IFS= read -r line; do
      [[ -z "${line// /}" ]] && continue
      clean=$(printf '%s' "$line" | sed -E 's/^[[:space:]]*[-*•][[:space:]]*//')
      json_line=$(jq -nc \
        --arg ts "$NOW" \
        --arg sid "$SID" \
        --arg cwd "$CWD" \
        --arg text "$clean" \
        --arg prompt "$LAST_PROMPT" \
        --argjson tags "$TAGS_JSON" \
        --arg branch "$GIT_BRANCH" \
        --arg sha "$GIT_SHA" '
          {ts:$ts, sid:$sid, kind:"summary", text:$text, cwd:$cwd}
          + (if $prompt != "" then {prompt:$prompt} else {} end)
          + (if ($tags | length) > 0 then {tags:$tags} else {} end)
          + (if $branch != "" then {git:{branch:$branch, sha:$sha}} else {} end)
        ')
      mc_append_locked "$POOL" "$json_line"
    done <<< "$SUMMARY"
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

      # Extract tags from frontmatter. Supports inline `tags: [a, b, c]`.
      # Falls back to [type] when type is set; empty otherwise.
      tags_line=$(awk '/^[[:space:]]*tags:/{print; exit}' "$file" 2>/dev/null || true)
      tags_csv=""
      if [[ "$tags_line" =~ tags:[[:space:]]*\[(.*)\] ]]; then
        tags_csv="${BASH_REMATCH[1]}"
      fi
      if [[ -n "$tags_csv" ]]; then
        am_tags_json=$(printf '%s' "$tags_csv" | jq -R '
          split(",")
          | map(ascii_downcase | gsub("^\\s+|\\s+$|\""; ""))
          | map(select(length > 0))
          | unique | .[0:5]
        ')
      elif [[ -n "$type" ]]; then
        am_tags_json=$(jq -nc --arg t "$type" '[$t | ascii_downcase]')
      else
        am_tags_json='[]'
      fi

      # Reuse the per-Stop git context captured above (if any).
      json_line=$(jq -nc --arg ts "$NOW" --arg sid "$SID" --arg cwd "$CWD" \
        --arg path "$file" --arg name "$name" --arg type "$type" \
        --arg desc "$desc" --arg body "$body" \
        --argjson tags "$am_tags_json" \
        --arg branch "${GIT_BRANCH:-}" --arg sha "${GIT_SHA:-}" '
        {ts:$ts, sid:$sid, kind:"automemory", cwd:$cwd, path:$path,
         name:$name, type:$type, description:$desc, body_excerpt:$body}
        + (if ($tags | length) > 0 then {tags:$tags} else {} end)
        + (if $branch != "" then {git:{branch:$branch, sha:$sha}} else {} end)')
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
