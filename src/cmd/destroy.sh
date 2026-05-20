#!/usr/bin/env bash
# destroy.sh — delete a key's pool directory.

set -euo pipefail
LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)"
# shellcheck disable=SC1091
source "$LIB_DIR/core.sh"
mc_require_jq

KEY="${1:?usage: destroy <key> [--yes]}"; shift || true
YES=0
[[ "${1:-}" == "--yes" ]] && YES=1

KEY_DIR=$(mc_key_dir "$KEY")
[[ -d "$KEY_DIR" ]] || { echo "memory-claude: key '$KEY' not found." >&2; exit 1; }

if (( ! YES )); then
  printf 'memory-claude: delete key "%s" and all its pool data? [y/N] ' "$KEY"
  read -r ans
  [[ "$ans" =~ ^[Yy]$ ]] || { echo "aborted."; exit 0; }
fi

rm -rf "$KEY_DIR"

# Remove from keys.json
keys_json="$MC_ROOT/keys.json"
if [[ -f "$keys_json" ]]; then
  tmp=$(mktemp)
  jq --arg k "$KEY" '.keys = ((.keys // []) | map(select(.key != $k)))' "$keys_json" > "$tmp" && mv "$tmp" "$keys_json"
fi

printf '\033[1;36m[memory-claude]\033[0m destroyed: %s\n' "$KEY"
