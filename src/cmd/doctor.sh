#!/usr/bin/env bash
# doctor.sh — sanity-check the install: deps, hook scripts, real claude resolution.

set -euo pipefail
LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)"
# shellcheck disable=SC1091
source "$LIB_DIR/core.sh"

pass() { printf '\033[1;32mOK\033[0m  %s\n' "$1"; }
fail() { printf '\033[1;31mFAIL\033[0m %s\n' "$1"; failed=1; }
warn() { printf '\033[1;33mWARN\033[0m %s\n' "$1"; }

failed=0

# Deps
for cmd in jq uuidgen find stat awk sed; do
  if command -v "$cmd" >/dev/null 2>&1; then pass "dep: $cmd"; else fail "dep missing: $cmd"; fi
done

# Real claude
if real=$(mc_resolve_real_claude) && [[ -x "$real" ]]; then
  pass "claude binary: $real"
else
  fail "claude binary not resolvable (looked at ~/.local/bin/claude and PATH)"
fi

# MC_ROOT
if [[ -d "$MC_ROOT" ]]; then
  pass "install root: $MC_ROOT"
else
  warn "install root missing: $MC_ROOT (run install.sh)"
fi

# Hooks installed
for h in session-start user-prompt stop session-end; do
  hp="$MC_ROOT/bin/hook-${h}.sh"
  if [[ -x "$hp" ]]; then pass "hook installed: hook-${h}.sh"; else warn "hook missing: $hp"; fi
done

# Smoke-test each hook: pipe empty JSON, check it returns valid JSON.
if [[ -x "$MC_ROOT/bin/hook-session-start.sh" ]]; then
  export MEMORY_CLAUDE_KEY="__doctor__"
  export MEMORY_CLAUDE_SESSION_ID="00000000-0000-0000-0000-000000000000"
  export MEMORY_CLAUDE_DIR="$MC_ROOT/__doctor__"
  mc_ensure_key_dir "$MEMORY_CLAUDE_KEY"

  for h in session-start user-prompt stop session-end; do
    out=$(echo '{}' | "$MC_ROOT/bin/hook-${h}.sh" 2>/dev/null || true)
    if printf '%s' "$out" | jq empty >/dev/null 2>&1; then
      pass "hook smoke: $h emits valid JSON"
    else
      fail "hook smoke: $h emitted invalid JSON: $out"
    fi
  done

  # Cleanup
  rm -rf "$MC_ROOT/__doctor__"
  # Remove __doctor__ from keys.json
  if [[ -f "$MC_ROOT/keys.json" ]]; then
    tmp=$(mktemp)
    jq '.keys = ((.keys // []) | map(select(.key != "__doctor__")))' "$MC_ROOT/keys.json" > "$tmp" && mv "$tmp" "$MC_ROOT/keys.json"
  fi
fi

if (( failed )); then
  echo
  echo "memory-claude doctor: FAIL"
  exit 1
fi
echo
echo "memory-claude doctor: OK"
