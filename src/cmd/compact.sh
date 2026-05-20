#!/usr/bin/env bash
# compact.sh — manually trigger rotation + render for a key.

set -euo pipefail
LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)"

KEY="${1:?usage: compact <key>}"
"$LIB_DIR/compact.sh" "$KEY" --rotate >/dev/null
"$LIB_DIR/compact.sh" "$KEY"
