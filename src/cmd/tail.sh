#!/usr/bin/env bash
# tail.sh — tail pool.ndjson for a key, decoded.

set -euo pipefail
LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)"
# shellcheck disable=SC1091
source "$LIB_DIR/core.sh"
mc_require_jq

KEY="${1:?usage: tail <key> [-n N] [-f]}"; shift
N=50
FOLLOW=0
while (( $# > 0 )); do
  case "$1" in
    -n) N="$2"; shift 2 ;;
    -f) FOLLOW=1; shift ;;
    *) echo "tail: unknown flag $1" >&2; exit 1 ;;
  esac
done

KEY_DIR=$(mc_key_dir "$KEY")
POOL="$KEY_DIR/pool.ndjson"
[[ -f "$POOL" ]] || { echo "memory-claude: pool not found." >&2; exit 1; }

render() {
  jq -r '
    if .kind == "summary" or .kind == "note" then
      "[\(.ts[11:19]) \(.sid[0:4])] \(.kind | ascii_upcase): \(.text)"
    elif .kind == "automemory" then
      "[\(.ts[11:19]) \(.sid[0:4])] AUTOMEM (\(.type // "?")) \(.name): \(.description // "" | .[0:160])"
    else
      "[\(.ts[11:19]) \(.sid[0:4])] \(.kind | ascii_upcase) \(.cwd // "")"
    end
  '
}

if (( FOLLOW )); then
  tail -n "$N" -f "$POOL" | render
else
  tail -n "$N" "$POOL" | render
fi
