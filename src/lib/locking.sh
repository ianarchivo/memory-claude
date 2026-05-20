#!/usr/bin/env bash
# locking — mkdir-based, macOS-safe. flock not standard on macOS.

mc_lock_acquire() {
  local lock="$1" max_tries="${2:-200}" tries=0
  while ! mkdir "$lock" 2>/dev/null; do
    (( ++tries > max_tries )) && return 1
    sleep 0.02
  done
  return 0
}

mc_lock_release() {
  rmdir "$1" 2>/dev/null || true
}

mc_with_lock() {
  local lock="$1"; shift
  mc_lock_acquire "$lock" || { echo "memory-claude: lock timeout: $lock" >&2; return 1; }
  trap 'mc_lock_release "$lock"' EXIT INT TERM
  "$@"
  local rc=$?
  mc_lock_release "$lock"
  trap - EXIT INT TERM
  return $rc
}

# Append a line to a file under lock.
mc_append_locked() {
  local file="$1" line="$2"
  local lock="${file}.lock"
  mc_lock_acquire "$lock" || return 1
  printf '%s\n' "$line" >> "$file"
  mc_lock_release "$lock"
}
