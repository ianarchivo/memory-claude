#!/usr/bin/env bash
# install.sh — set up ~/.memory-claude/ and symlink ~/.local/bin/memory-claude

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MC_ROOT="${MC_ROOT:-$HOME/.memory-claude}"

echo "memory-claude installer"
echo "repo:      $REPO_ROOT"
echo "install:   $MC_ROOT"

# Check deps
for cmd in jq; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "error: missing dependency '$cmd'. Install with: brew install $cmd" >&2
    exit 1
  fi
done

# Create install dirs
mkdir -p "$MC_ROOT"/{bin,lib}

# Copy libs (so hook paths don't depend on repo location)
cp "$REPO_ROOT/src/lib/"*.sh "$MC_ROOT/lib/"
chmod +x "$MC_ROOT/lib/"*.sh

# Copy hooks with hook-<name>.sh naming
cp "$REPO_ROOT/src/hooks/session-start.sh"  "$MC_ROOT/bin/hook-session-start.sh"
cp "$REPO_ROOT/src/hooks/user-prompt.sh"    "$MC_ROOT/bin/hook-user-prompt.sh"
cp "$REPO_ROOT/src/hooks/stop.sh"           "$MC_ROOT/bin/hook-stop.sh"
cp "$REPO_ROOT/src/hooks/session-end.sh"    "$MC_ROOT/bin/hook-session-end.sh"
chmod +x "$MC_ROOT/bin/"*.sh

# Make entrypoint executable
chmod +x "$REPO_ROOT/bin/memory-claude"

# Symlink into ~/.local/bin
mkdir -p "$HOME/.local/bin"
LINK="$HOME/.local/bin/memory-claude"
if [[ -L "$LINK" ]] || [[ -e "$LINK" ]]; then
  echo "note: $LINK already exists. Overwriting symlink."
  rm -f "$LINK"
fi
ln -s "$REPO_ROOT/bin/memory-claude" "$LINK"

# Init keys.json if absent
[[ -f "$MC_ROOT/keys.json" ]] || echo '{"keys":[]}' > "$MC_ROOT/keys.json"

echo
echo "installed: $LINK -> $REPO_ROOT/bin/memory-claude"
echo "hooks:     $MC_ROOT/bin/"
echo "libs:      $MC_ROOT/lib/"
echo
echo "next steps:"
echo "  memory-claude doctor    # verify"
echo "  memory-claude            # mint a key and start"
