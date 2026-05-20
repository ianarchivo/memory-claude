#!/usr/bin/env bash
# note.sh — append a manual note to the shared pool.
# usage: memory-claude <key> note "<text>" [--tag a,b,c]

set -euo pipefail

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)"
# shellcheck disable=SC1091
source "$LIB_DIR/core.sh"
# shellcheck disable=SC1091
source "$LIB_DIR/locking.sh"

mc_require_jq

KEY="${1:?usage: note <key> \"<text>\" [--tag a,b,c]}"; shift

# First positional after the key is the note text.
if [[ $# -eq 0 ]]; then
  echo "memory-claude: note text required." >&2
  echo "usage: memory-claude $KEY note \"<text>\" [--tag a,b,c]" >&2
  exit 1
fi

TEXT="$1"; shift

# Optional --tag a,b,c (supports both `--tag a,b` and `--tag=a,b`)
TAGS_CSV=""
while (( $# > 0 )); do
  case "$1" in
    --tag)
      TAGS_CSV="${2:-}"
      shift 2 || { echo "note: --tag needs a value" >&2; exit 1; }
      ;;
    --tag=*)
      TAGS_CSV="${1#--tag=}"
      shift
      ;;
    *)
      echo "note: unknown flag '$1'" >&2
      exit 1
      ;;
  esac
done

KEY_DIR=$(mc_key_dir "$KEY")
if [[ ! -d "$KEY_DIR" ]]; then
  echo "memory-claude: key '$KEY' not found at $KEY_DIR" >&2
  exit 1
fi

POOL="$KEY_DIR/pool.ndjson"
NOW="$(mc_now)"
CWD="$(pwd)"
AUTHOR="${USER:-unknown}@$(hostname -s 2>/dev/null || hostname)"

# Normalize tags: lowercase, strip whitespace, drop empties, dedupe, cap at 5.
TAGS_JSON='[]'
if [[ -n "$TAGS_CSV" ]]; then
  TAGS_JSON=$(printf '%s' "$TAGS_CSV" | jq -R '
    split(",")
    | map(ascii_downcase | gsub("^\\s+|\\s+$"; ""))
    | map(select(length > 0))
    | unique
    | .[0:5]
  ')
fi

# Best-effort git context. Detached HEAD -> "(detached)". Not a repo -> omit.
GIT_JSON='null'
if git -C "$CWD" rev-parse --git-dir >/dev/null 2>&1; then
  branch=$(git -C "$CWD" branch --show-current 2>/dev/null)
  [[ -n "$branch" ]] || branch="(detached)"
  sha=$(git -C "$CWD" rev-parse --short HEAD 2>/dev/null || echo "")
  GIT_JSON=$(jq -nc --arg b "$branch" --arg s "$sha" '{branch:$b, sha:$s}')
fi

json_line=$(jq -nc \
  --arg ts "$NOW" \
  --arg cwd "$CWD" \
  --arg text "$TEXT" \
  --arg author "$AUTHOR" \
  --argjson tags "$TAGS_JSON" \
  --argjson git "$GIT_JSON" '
    {ts:$ts, sid:"manual", kind:"note", cwd:$cwd, text:$text, author:$author}
    + (if ($tags | length) > 0 then {tags:$tags} else {} end)
    + (if $git != null then {git:$git} else {} end)
  ')

mc_append_locked "$POOL" "$json_line"

# Re-render pool.md so `show` reflects the new note immediately.
"$LIB_DIR/compact.sh" "$KEY" >/dev/null 2>&1 || true

# Stdout: a short confirmation. Keep terse so this can be piped/scripted.
printf 'memory-claude: note appended to %s\n' "$POOL"
if [[ "$TAGS_JSON" != "[]" ]]; then
  printf '  tags: %s\n' "$(printf '%s' "$TAGS_JSON" | jq -r 'join(", ")')"
fi
