#!/usr/bin/env bash
# show.sh — print pool.md for a key.

set -euo pipefail
LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)"
# shellcheck disable=SC1091
source "$LIB_DIR/core.sh"

KEY="${1:?usage: show <key>}"
KEY_DIR=$(mc_key_dir "$KEY")
[[ -d "$KEY_DIR" ]] || { echo "memory-claude: key '$KEY' not found." >&2; exit 1; }

# Rebuild pool.md fresh before showing
"$LIB_DIR/compact.sh" "$KEY"
