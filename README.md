# memory-claude

A thin wrapper around the `claude` CLI that adds **keyed shared memory across
multiple concurrent Claude Code sessions**. First invocation mints a random
three-word key (e.g. `space-cat-hunter`). Any later session that joins the
same key sees the others' findings — and their auto-memory writes — live,
without restart.

Claude Code's built-in auto-memory is scoped only by working directory; there
is no way to group sessions, share context across repos, or run an isolated
investigation pool that doesn't bleed into others. `memory-claude` adds that
second layer without touching the native auto-memory.

## Install

```bash
cd /path/to/memory-claude
./install.sh
memory-claude doctor
```

Requires `jq`. On macOS: `brew install jq`.

The installer:
- symlinks hook scripts into `~/.memory-claude/bin/`
- symlinks shared libs into `~/.memory-claude/lib/`
- symlinks `~/.local/bin/memory-claude` → `<repo>/bin/memory-claude`

Make sure `~/.local/bin` is on your PATH.

**Upgrading.** Symlinks mean repo edits go live without reinstall — but
**new files** in `src/lib/` (e.g. `tags.sh` added in a later version) won't
have symlinks until you re-run `./install.sh`. Re-running is idempotent
and safe. If hooks start silently no-opping after a pull, check
`~/.memory-claude/lib/` against `src/lib/` and re-run the installer.

## Usage

```bash
# Mint a new key and start a session
memory-claude
# → [memory-claude] new key: space-cat-hunter
# → [memory-claude] launching claude...

# Join from another terminal (any cwd)
memory-claude space-cat-hunter

# Live view of connected sessions and the pool
memory-claude space-cat-hunter monitor

# Resume a specific past session under this key
memory-claude space-cat-hunter --resume <session-uuid>

# List all keys you have
memory-claude list

# List sessions on a key (active + historical)
memory-claude space-cat-hunter list

# Print the current pool snapshot
memory-claude space-cat-hunter show

# Tail the raw event log
memory-claude space-cat-hunter tail -n 50 -f

# Append a manual note (preferred over auto-compression for important findings)
memory-claude space-cat-hunter note "auth refactor blocked by legal" --tag auth,compliance

# Full-text search across the pool (+ rotated backups)
memory-claude space-cat-hunter search "auth" --kind note --since 1d

# Clean up
memory-claude space-cat-hunter destroy
```

Any flag `memory-claude` doesn't recognize is forwarded to `claude`:

```bash
memory-claude space-cat-hunter --model sonnet --add-dir ../other-repo
```

## How it works

For each launch, the wrapper:

1. Pre-allocates a session UUID and exports `MEMORY_CLAUDE_KEY`,
   `MEMORY_CLAUDE_SESSION_ID`, `MEMORY_CLAUDE_DIR` to the child process.
2. Builds a pool snapshot from `~/.memory-claude/<key>/pool.ndjson` and
   passes it via `--append-system-prompt`.
3. Injects four hooks via `--settings '<json>'` (one-off, no global config
   mutation):
   - `SessionStart` — register session, emit snapshot.
   - `UserPromptSubmit` — read delta from other sessions, inject as
     `additionalContext`. This is the live-propagation mechanism.
   - `Stop` — summarize the last assistant turn AND mirror any new files
     written to the cwd's auto-memory (`~/.claude/projects/<cwd>/memory/`)
     into the shared pool.
   - `SessionEnd` — deregister and append a leave event.
4. Resolves the **real** `claude` binary (`~/.local/bin/claude`), bypassing
   cmux's wrapper.

The shared pool lives at `~/.memory-claude/<key>/`:

```
<key>/
├── pool.ndjson        append-only event log (source of truth)
├── pool.md            rendered view (regenerated)
├── sessions.json      live presence
├── meta.json          key metadata
├── seen/
│   ├── <sid>.cursor              per-session byte offset into pool.ndjson
│   └── <sid>.automemory-mtime    per-session max mtime seen in cwd memory/
├── snapshots/         SessionStart injections (debugging)
└── log                hook stderr
```

`pool.ndjson` events have `kind` ∈ `summary | note | automemory | join | leave`.

## Layering with native auto-memory

`memory-claude` does **not** replace Claude's built-in auto-memory at
`~/.claude/projects/<cwd>/memory/`. Claude continues to load it natively per
session. The key-scoped pool is purely additive.

What's new: when Claude writes a new entry to the cwd's auto-memory during a
session, the `Stop` hook detects the change (mtime vs. a per-session cursor)
and mirrors the entry into the shared pool as a `kind:"automemory"` event.
Other sessions on the same key see it in their next `UserPromptSubmit` delta.
So a session in `snappr.web` can see what a session in `snappr.server` just
learned, even though they have independent native auto-memories.

## Compression

The `Stop` hook compresses each assistant turn into 1–3 short bullets before
appending. Three modes via `MEMORY_CLAUDE_COMPRESS`:

- **`rule-based`** (default, $0): strips code fences and takes the last 1-3
  informative sentences of the turn — the conclusion, not the opener. Drops
  filler-start sentences (`Good`, `Sure`, `Let me`, `I'll`, etc.), markdown
  headings, and colon-trailing lines.
- **`auto`** (opt-in): use Haiku if `ANTHROPIC_API_KEY` is set, silently fall
  back to rule-based otherwise. Recommended for users who keep an API key set
  for unrelated reasons and want better summaries when available.
- **`haiku`** (opt-in, forced): same as `auto` but documents intent. ~$0.0001/turn.

Tags are extracted independently of compression (top-2 keyword-frequency from
the assistant text), so even rule-based summaries carry usable filtering tags.

## Tag filtering and subscription

Every `summary`, `note`, and `automemory` event may carry a `tags: [...]`
array. Sessions can subscribe via env vars:

```bash
# Only inject delta entries tagged auth or billing (untagged still included)
MEMORY_CLAUDE_TAGS=auth,billing memory-claude my-key

# As above, but also exclude untagged entries
MEMORY_CLAUDE_TAGS=auth MEMORY_CLAUDE_TAGS_STRICT=1 memory-claude my-key

# Hide all ui-tagged entries
MEMORY_CLAUDE_EXCLUDE_TAGS=ui memory-claude my-key
```

Unset → no filtering. `MEMORY_CLAUDE_EXCLUDE_TAGS` takes precedence over the
allowlist.

## Debug: persist injected deltas

```bash
MEMORY_CLAUDE_DEBUG=1 memory-claude my-key
```

Writes every per-turn injection to
`~/.memory-claude/<key>/snapshots/<sid>-turn-<epoch>.md` for audit. Off by
default (no write amplification).

## Event schema

See [SCHEMA.md](SCHEMA.md) for the full event format, required + optional
fields per kind, and guidance on writing good entries.

## Caveats

- macOS-only out of the box (`stat -f`, `tail -r`). Linux works with minor
  tweaks (`stat -c`, `tac`).
- Sessions launched through cmux: by default we bypass cmux and exec the real
  `claude`. cmux features (its own notifications, etc.) won't apply to those
  sessions. A `--via-cmux` merge mode is on the roadmap.
- Pool grows over time. Auto-rotation at 256 KB / 500 entries keeps it bounded.
- Headless `claude -p` invocations launched outside the wrapper are unaffected:
  hooks no-op when `MEMORY_CLAUDE_KEY` is unset.

## License

MIT. Personal project — no warranty.
