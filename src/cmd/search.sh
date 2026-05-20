#!/usr/bin/env bash
# search.sh — full-text search the shared pool with optional filters.
# usage: memory-claude <key> search "<query>" [--kind X] [--tag Y] [--since 1h|1d|...]

set -euo pipefail

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)"
# shellcheck disable=SC1091
source "$LIB_DIR/core.sh"

mc_require_jq

KEY="${1:?usage: search <key> \"<query>\" [--kind X] [--tag Y] [--since 1h|1d]}"; shift

if [[ $# -eq 0 ]]; then
  echo "memory-claude: search query required." >&2
  echo "usage: memory-claude $KEY search \"<query>\" [--kind X] [--tag Y] [--since 1h|1d]" >&2
  exit 1
fi

QUERY="$1"; shift

KIND_FILTER=""
TAG_FILTER=""
SINCE=""

while (( $# > 0 )); do
  case "$1" in
    --kind)    KIND_FILTER="${2:-}"; shift 2 ;;
    --kind=*)  KIND_FILTER="${1#--kind=}"; shift ;;
    --tag)     TAG_FILTER="${2:-}"; shift 2 ;;
    --tag=*)   TAG_FILTER="${1#--tag=}"; shift ;;
    --since)   SINCE="${2:-}"; shift 2 ;;
    --since=*) SINCE="${1#--since=}"; shift ;;
    *) echo "search: unknown flag '$1'" >&2; exit 1 ;;
  esac
done

KEY_DIR=$(mc_key_dir "$KEY")
if [[ ! -d "$KEY_DIR" ]]; then
  echo "memory-claude: key '$KEY' not found at $KEY_DIR" >&2
  exit 1
fi

# Resolve --since (h/m/d/w) into an ISO threshold. Empty -> no threshold.
SINCE_ISO=""
if [[ -n "$SINCE" ]]; then
  num="${SINCE%[hmdw]}"
  unit="${SINCE: -1}"
  if ! [[ "$num" =~ ^[0-9]+$ ]]; then
    echo "search: --since must be Nh, Nm, Nd, or Nw (e.g. 1h, 30m, 2d)" >&2
    exit 1
  fi
  case "$unit" in
    m) flag="-${num}M" ; gnu="${num} minutes ago" ;;
    h) flag="-${num}H" ; gnu="${num} hours ago" ;;
    d) flag="-${num}d" ; gnu="${num} days ago" ;;
    w) flag="-$((num * 7))d" ; gnu="$((num * 7)) days ago" ;;
    *) echo "search: --since unit must be m/h/d/w" >&2; exit 1 ;;
  esac
  # macOS BSD date first; fall back to GNU date.
  SINCE_ISO=$(date -u -v "$flag" +%FT%TZ 2>/dev/null || date -u -d "$gnu" +%FT%TZ 2>/dev/null || true)
  if [[ -z "$SINCE_ISO" ]]; then
    echo "search: could not compute --since threshold (need BSD or GNU date)" >&2
    exit 1
  fi
fi

# Glob pool.ndjson + any rotated backups. Sort newest-first so output is
# chronologically ordered with most recent last (handled by sort -r per file
# then per-line scanning).
shopt -s nullglob
POOLS=("$KEY_DIR"/pool.ndjson*)
shopt -u nullglob

if (( ${#POOLS[@]} == 0 )); then
  echo "memory-claude: no pool files for key '$KEY'." >&2
  exit 1
fi

# Pre-filter with rg (or grep) for the query, then refine with jq. The rg
# step is a fast literal pre-filter; jq does the structural filtering.
# `|| true` keeps no-match (exit 1) from killing the script under pipefail.
# Rotated backups have ISO timestamps with colons (e.g. pool.ndjson.2026-...bak),
# so strip the filename prefix conservatively up to and including ".ndjson"
# plus any non-colon suffix, then the first colon.
prefilter() {
  if command -v rg >/dev/null 2>&1; then
    rg --line-buffered -i -F --no-filename -- "$QUERY" "${POOLS[@]}" 2>/dev/null || true
  else
    grep -i -F -h -- "$QUERY" "${POOLS[@]}" 2>/dev/null || true
  fi
}

prefilter | jq -r \
  --arg kind "$KIND_FILTER" \
  --arg tag "$TAG_FILTER" \
  --arg since "$SINCE_ISO" '
  select(. != null and (.kind // "") != "")
  | select($kind == "" or .kind == $kind)
  | select($tag == "" or ((.tags // []) | index($tag | ascii_downcase)))
  | select($since == "" or (.ts // "") >= $since)
  | if .kind == "summary" then
      "[\(.ts[0:19]) \(.sid[0:4])] SUMMARY: \(.text)"
      + (if .prompt then "\n    Q: \(.prompt[0:140])" else "" end)
      + (if (.tags // []) | length > 0 then "  #\((.tags // []) | join(" #"))" else "" end)
    elif .kind == "note" then
      "[\(.ts[0:19]) MANUAL] NOTE: \(.text)"
      + (if .author then "  (\(.author))" else "" end)
      + (if (.tags // []) | length > 0 then "  #\((.tags // []) | join(" #"))" else "" end)
    elif .kind == "automemory" then
      "[\(.ts[0:19]) \(.sid[0:4])] AUTOMEM (\(.type // "?")) \(.name): \(.description // "")"
      + (if (.tags // []) | length > 0 then "  #\((.tags // []) | join(" #"))" else "" end)
    else
      "[\(.ts[0:19]) \(.sid[0:4])] \(.kind | ascii_upcase) \(.cwd // "")"
    end
'
