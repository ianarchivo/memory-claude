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
- copies hook scripts to `~/.memory-claude/bin/`
- copies shared libs to `~/.memory-claude/lib/`
- symlinks `~/.local/bin/memory-claude` → `<repo>/bin/memory-claude`

Make sure `~/.local/bin` is on your PATH.

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
appending. Two modes:

- **Rule-based** (default, free): strips code fences, takes the first short
  informative sentences.
- **Haiku** (opt-in): set `MEMORY_CLAUDE_COMPRESS=haiku` and
  `ANTHROPIC_API_KEY=...`. Produces actual caveman-lite bullets at ~$0.0001/turn.

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
