#!/usr/bin/env bash
# core helpers — paths, logging, key generation, json helpers.
# sourced by bin/memory-claude and hook scripts.

set -euo pipefail

MC_ROOT="${MC_ROOT:-$HOME/.memory-claude}"
MC_INSTALL_ROOT="${MC_INSTALL_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"

mc_now() { date -u +%FT%TZ; }
mc_now_epoch() { date -u +%s; }

mc_log() {
  local key="${MEMORY_CLAUDE_KEY:-}"
  [[ -z "$key" ]] && return 0
  local logfile="$MC_ROOT/$key/log"
  mkdir -p "$(dirname "$logfile")"
  printf '[%s] %s\n' "$(mc_now)" "$*" >> "$logfile"
}

mc_key_dir() { printf '%s/%s' "$MC_ROOT" "$1"; }

mc_require_jq() {
  command -v jq >/dev/null 2>&1 || {
    echo "memory-claude: 'jq' is required. Install with: brew install jq" >&2
    exit 1
  }
}

# Encode a cwd to the dir name Claude uses under ~/.claude/projects/
# /Users/iancolin/Documents/github -> -Users-iancolin-Documents-github
mc_encode_cwd() {
  local cwd="${1:-$PWD}"
  printf '%s' "$cwd" | sed 's|/|-|g'
}

mc_automemory_dir_for_cwd() {
  printf '%s/.claude/projects/%s/memory' "$HOME" "$(mc_encode_cwd "${1:-$PWD}")"
}

# Generate a 3-word slug, retrying on collision with keys.json.
mc_gen_key() {
  mc_require_jq
  local adj_file="$MC_INSTALL_ROOT/wordlist/adjectives.txt"
  local n1_file="$MC_INSTALL_ROOT/wordlist/nouns-a.txt"
  local n2_file="$MC_INSTALL_ROOT/wordlist/nouns-b.txt"

  local keys_json="$MC_ROOT/keys.json"
  [[ -f "$keys_json" ]] || echo '{"keys":[]}' > "$keys_json"

  local try key adj n1 n2
  for try in 1 2 3 4 5; do
    adj=$(shuf -n1 "$adj_file" 2>/dev/null || awk 'BEGIN{srand()} {a[NR]=$0} END{print a[int(rand()*NR)+1]}' "$adj_file")
    n1=$(shuf -n1 "$n1_file" 2>/dev/null || awk 'BEGIN{srand()} {a[NR]=$0} END{print a[int(rand()*NR)+1]}' "$n1_file")
    n2=$(shuf -n1 "$n2_file" 2>/dev/null || awk 'BEGIN{srand()} {a[NR]=$0} END{print a[int(rand()*NR)+1]}' "$n2_file")
    key="${adj}-${n1}-${n2}"
    if ! jq -e --arg k "$key" '.keys[]? | select(.key == $k)' "$keys_json" >/dev/null 2>&1; then
      printf '%s' "$key"
      return 0
    fi
  done
  # Fallback: append a 4-char hex suffix
  printf '%s-%s' "$key" "$(head /dev/urandom | LC_ALL=C tr -dc 'a-z0-9' | head -c4)"
}

mc_register_key() {
  mc_require_jq
  local key="$1" now="$(mc_now)"
  local keys_json="$MC_ROOT/keys.json"
  [[ -f "$keys_json" ]] || echo '{"keys":[]}' > "$keys_json"
  local tmp; tmp=$(mktemp)
  jq --arg k "$key" --arg now "$now" '
    if (.keys // []) | map(.key) | index($k) then
      .keys |= map(if .key == $k then .last_active = $now else . end)
    else
      .keys = ((.keys // []) + [{key:$k, created_at:$now, last_active:$now}])
    end
  ' "$keys_json" > "$tmp" && mv "$tmp" "$keys_json"
}

mc_uuid() {
  if command -v uuidgen >/dev/null 2>&1; then
    uuidgen | tr 'A-Z' 'a-z'
  else
    # Fallback: pseudo-uuid from /dev/urandom
    local b
    b=$(head -c 16 /dev/urandom | xxd -p)
    printf '%s-%s-4%s-%s-%s' "${b:0:8}" "${b:8:4}" "${b:13:3}" "${b:16:4}" "${b:20:12}"
  fi
}

# Resolve the real claude binary, not the cmux wrapper.
mc_resolve_real_claude() {
  local local_bin="$HOME/.local/bin/claude"
  if [[ -L "$local_bin" ]]; then
    # follow one level (readlink is BSD on macOS, no -f)
    local target
    target=$(readlink "$local_bin")
    if [[ "$target" = /* ]]; then
      printf '%s' "$target"
      return 0
    else
      printf '%s/%s' "$(dirname "$local_bin")" "$target"
      return 0
    fi
  fi
  # Last resort: which claude (may resolve to cmux wrapper)
  command -v claude
}

# Init a key dir if missing.
mc_ensure_key_dir() {
  local key="$1"
  local kd; kd=$(mc_key_dir "$key")
  mkdir -p "$kd"/{seen,snapshots}
  [[ -f "$kd/pool.ndjson" ]] || : > "$kd/pool.ndjson"
  [[ -f "$kd/sessions.json" ]] || echo '{"sessions":[]}' > "$kd/sessions.json"
  if [[ ! -f "$kd/meta.json" ]]; then
    jq -n --arg now "$(mc_now)" --arg key "$key" \
      '{key:$key, created_at:$now, version:"0.1.0"}' > "$kd/meta.json"
  fi
}
