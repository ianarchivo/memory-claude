# memory-claude

**Keyed shared memory across multiple concurrent Claude Code sessions.**

`memory-claude` is a thin wrapper around the `claude` CLI that lets two or
more sessions — typically in different repos or terminals — share the same
working context for as long as they share a key. Findings, decisions, and
auto-memory writes from one session reach the others live, on the next
prompt, without restart.

```bash
# Terminal 1, in your backend repo — pick the feature name yourself
$ cd ~/code/snappr.server
$ memory-claude new tours-launch
[memory-claude] minted new key: tours-launch
[memory-claude] launching claude...

# Terminal 2, in your frontend repo — join the same key
$ cd ~/code/snappr.web
$ memory-claude tours-launch
[memory-claude] joining key: tours-launch
```

Both sessions now share a key-scoped pool. Whatever the backend session
learns about the new `/v1/tours` endpoint is visible to the frontend session
on its next message — even though the two repos are completely independent.

---

## Why this exists

Claude Code already has auto-memory at
`~/.claude/projects/<cwd-slug>/memory/`. It's scoped to a single working
directory. That's the right default for most work — but it leaves three gaps:

1. **No way to share context across repos.** A feature that touches both
   `snappr.server` and `snappr.web` needs context flowing both ways: the
   API shape decided in the backend session should reach the frontend
   session without you re-explaining it.
2. **No way to group sessions.** Two terminals in the same repo each get
   their own independent native memory; they can't see each other's
   discoveries.
3. **No way to scope an investigation.** Everything gets persisted into the
   single per-cwd pile. You can't say "for this debugging session only,
   keep memory separate from the rest of my work."

`memory-claude` adds a **second layer** that's keyed instead of
cwd-scoped. The native per-cwd memory is **untouched** — both layers
co-exist. You decide per launch whether a session participates in a
shared pool.

```
┌─────────────────────────┐        ┌─────────────────────────┐
│  snappr.server session  │        │   snappr.web session    │
│                         │        │                         │
│  ~/.claude/projects/    │        │  ~/.claude/projects/    │
│  -snappr-server/memory/ │        │  -snappr-web/memory/    │
│  (native, repo-scoped)  │        │  (native, repo-scoped)  │
└────────────┬────────────┘        └────────────┬────────────┘
             │                                  │
             │  both join key: copper-otter-... │
             └──────────────┬───────────────────┘
                            ▼
            ┌─────────────────────────────┐
            │  ~/.memory-claude/          │
            │  copper-otter-canyon/       │
            │  pool.ndjson                │
            │  (shared, key-scoped, live) │
            └─────────────────────────────┘
```

---

## Use cases

### 1. Cross-repo feature work

You're shipping a feature that spans backend and frontend. Today the
contract is loose ("we'll figure out the API shape as we go"). Without
shared memory, you either:
- copy-paste context between two Claude windows, or
- pick one repo to "own" the work and lose nuance from the other side.

With `memory-claude`:

```bash
# Pick a memorable key name for the feature, mint it explicitly:
cd ~/code/snappr.server && memory-claude new tours-launch

# In the other repo, join the same key:
cd ~/code/snappr.web    && memory-claude tours-launch
```

`memory-claude new <key>` mints with a name you choose (errors if the key
already exists, so you can't accidentally inherit a stale pool).
`memory-claude <key>` joins the key.

Now when the backend session decides the response shape, the frontend
session sees it on the next prompt and can write the client code against
the real schema instead of guessing. The native memory in each repo stays
clean of cross-cutting noise.

### 2. Per-feature isolation, no cross-pollination

Different features get different keys. Memory from feature A never leaks
into feature B's context.

```bash
# Monday: spin up a key for virtual tours
memory-claude new tours-launch

# Tuesday: spin up a separate key for an unrelated billing change
memory-claude new billing-prorations
```

The two pools never see each other. Each lives at
`~/.memory-claude/<key>/`. When the tours feature ships, you can
`memory-claude tours-launch destroy` without affecting anything else.

### 3. Multi-session debugging in one repo

Sometimes you want two terminals on the same codebase — one digging into
the bug, one verifying the fix doesn't regress unrelated code. Without
shared memory, each session re-discovers the same things. With a shared
key, the second session inherits the first's findings.

```bash
# Window 1: hunting the bug
cd ~/code/snappr.server && memory-claude jwt-rotation-bug

# Window 2: same repo, second angle (e.g. testing a fix)
cd ~/code/snappr.server && memory-claude jwt-rotation-bug
```

### 4. Long-running investigations across days

Mint a key, work, exit. Come back a week later, run
`memory-claude <key>`, and pick up where you left off — every prior
summary and note is still in the pool, surfaced as the SessionStart
snapshot.

### 5. Locking in durable decisions

The auto-compressor catches the highlights of each turn, but for things
you genuinely want a future session to inherit, write them explicitly:

```bash
memory-claude tours-launch note \
  "API decided: /v1/tours returns {id, listing_id, hls_url, poster_url}. \
   hls_url is presigned, expires in 1h. Frontend must request fresh on 403." \
  --tag api,tours
```

Manual notes are **always visible** to every session on the key, including
the writer's own future sessions.

### 6. Tag-scoped subscriptions

For long-lived keys with mixed topics, a session can subscribe to only
certain tags so noise from unrelated work doesn't pollute its context:

```bash
# Only inject auth-tagged and billing-tagged entries
MEMORY_CLAUDE_TAGS=auth,billing memory-claude long-running-key

# Hide all UI-tagged churn
MEMORY_CLAUDE_EXCLUDE_TAGS=ui memory-claude long-running-key
```

---

## Install

```bash
cd /path/to/memory-claude
./install.sh
memory-claude doctor
```

Requires `jq` (`brew install jq` on macOS).

The installer:
- symlinks hook scripts into `~/.memory-claude/bin/`
- symlinks shared libs into `~/.memory-claude/lib/`
- symlinks `~/.local/bin/memory-claude` → `<repo>/bin/memory-claude`

Make sure `~/.local/bin` is on your PATH.

**Upgrading.** Symlinks mean repo edits go live without reinstall — but
**new files** in `src/lib/` (e.g. `tags.sh` added in a later version)
won't have symlinks until you re-run `./install.sh`. Re-running is
idempotent and safe. If hooks start silently no-opping after a pull,
check `~/.memory-claude/lib/` against `src/lib/` and re-run the
installer.

---

## Quickstart

```bash
# Option A: mint a random key
memory-claude
# → [memory-claude] minted new key: space-cat-hunter

# Option B: mint a key with a name you choose
memory-claude new tours-launch
# → [memory-claude] minted new key: tours-launch
# Errors if 'tours-launch' already exists.

# Join from another terminal, any cwd
memory-claude tours-launch
# → [memory-claude] joining key: tours-launch

# Watch what's in the pool, live
memory-claude tours-launch monitor
```

That's the full happy path. Everything below is reference.

---

## Command reference

### Launch / join

```bash
# Mint a RANDOM key (three-word slug) and start
memory-claude

# Mint a SPECIFIC key name (errors if it already exists)
memory-claude new my-feature-key

# Join an existing key — if the key doesn't exist yet, it's also minted
memory-claude my-feature-key

# Resume a specific past session under a key
memory-claude my-feature-key --resume <session-uuid>

# Pass extra args through to claude unchanged
memory-claude my-feature-key --model sonnet --add-dir ../other-repo
```

The banner tells you which path ran:

```
[memory-claude] minted new key: my-feature-key    ← brand new
[memory-claude] joining key: my-feature-key       ← already existed
```

Key-name rules: 2–64 chars, lowercase, start with a letter, contain only
`a-z 0-9` and dashes.

Any flag `memory-claude` doesn't recognize is forwarded to `claude`
verbatim.

**`new` vs bare `<key>`.** Both can create a key, but `new` is the
safety-first form: it refuses to launch if the key already exists, so
you don't accidentally join a stale or someone-else's pool when you
meant to start fresh. Use `new` when you're spinning up a brand-new
feature; use the bare form when you're (probably) joining one.

### Inspect

```bash
memory-claude list                       # all keys you have
memory-claude <key> list                 # sessions on this key
memory-claude <key> monitor              # live TUI: sessions + pool tail
memory-claude <key> show                 # render and print pool.md
memory-claude <key> tail [-n N] [-f]     # tail pool.ndjson, decoded
memory-claude <key> search "<query>" [--kind X] [--tag Y] [--since 1h|1d]
                                         # full-text + filters
```

### Write

```bash
memory-claude <key> note "<text>" [--tag a,b,c]
                                         # append a manual note (sid:"manual")
```

Manual notes are preferred over auto-compression for findings you want
future sessions to inherit reliably. They carry your username, the cwd,
and (if you're in a git repo) the current branch and commit SHA.

### Manage

```bash
memory-claude <key> compact              # rotate + render pool.md
memory-claude <key> destroy [--yes]      # delete a key and its pool
memory-claude doctor                     # smoke-test the install
```

---

## How layering with native auto-memory works

`memory-claude` does **not** replace or modify Claude's built-in
auto-memory at `~/.claude/projects/<cwd-slug>/memory/`. Each repo's native
memory stays intact and is loaded by Claude on session start as usual.

What's new: when a session writes a new entry to its cwd's native
auto-memory during the conversation, the `Stop` hook detects the change
(file mtime vs. a per-session cursor) and **mirrors** that entry into the
shared pool as a `kind:"automemory"` event. Other sessions on the same
key see the mirrored entry in their next `UserPromptSubmit` delta.

So a session in `snappr.web` can see what a session in `snappr.server`
just learned, even though their native auto-memories are completely
independent and remain so.

---

## What gets shared, what doesn't

| | Native auto-memory | memory-claude pool |
|---|---|---|
| Location | `~/.claude/projects/<cwd>/memory/` | `~/.memory-claude/<key>/pool.ndjson` |
| Scope | one working directory | one key |
| Visible to | only sessions in that cwd | every session that joins the key |
| Survives session exit | yes | yes |
| Cross-repo | no | yes |
| Modified by memory-claude | **no** (read-only mirror) | yes (append-only writes) |

Anything you didn't deliberately share stays where it is. Repos you
aren't using for the feature don't get touched.

---

## Compression

The `Stop` hook compresses each assistant turn into 1–3 short bullets
before appending. Three modes via `MEMORY_CLAUDE_COMPRESS`:

- **`rule-based`** (default, $0): strips code fences and takes the last
  1–3 informative sentences of the turn — the conclusion, not the
  opener. Drops filler-start sentences (`Good`, `Sure`, `Let me`,
  `I'll`, etc.), markdown headings, and colon-trailing lines.
- **`auto`** (opt-in): uses Haiku when `ANTHROPIC_API_KEY` is set,
  silently falls back to rule-based otherwise. Best for users who keep
  an API key set for unrelated reasons and want better summaries when
  available.
- **`haiku`** (opt-in, forced): same as `auto` but documents intent.
  ~$0.0001/turn.

Tags are extracted independently of compression (top-2 keyword-frequency
from the assistant text), so rule-based summaries still carry usable
filtering tags.

---

## Tag filtering and subscription

Every `summary`, `note`, and `automemory` event may carry a
`tags: [...]` array. Sessions opt into filtering via env vars:

```bash
# Only inject delta entries tagged auth or billing (untagged still included)
MEMORY_CLAUDE_TAGS=auth,billing memory-claude my-key

# As above, but also exclude untagged entries (strict mode)
MEMORY_CLAUDE_TAGS=auth MEMORY_CLAUDE_TAGS_STRICT=1 memory-claude my-key

# Hide all ui-tagged entries
MEMORY_CLAUDE_EXCLUDE_TAGS=ui memory-claude my-key
```

Unset → no filtering (default). `MEMORY_CLAUDE_EXCLUDE_TAGS` takes
precedence over the allowlist.

---

## Debug: persist injected deltas

```bash
MEMORY_CLAUDE_DEBUG=1 memory-claude my-key
```

Writes every per-turn injection to
`~/.memory-claude/<key>/snapshots/<sid>-turn-<epoch>.md` for audit. Off
by default (no write amplification). Useful when a session "should have"
seen something and you want to know whether the injector actually fed
it.

---

## Event schema

See [SCHEMA.md](SCHEMA.md) for the full event format, required and
optional fields per `kind`, and guidance on writing good entries.

Quick reference:

| Kind | Producer | Visible in delta |
|---|---|---|
| `summary` | Stop hook (compressed assistant turn) | other sessions |
| `note` | `memory-claude <key> note ...` CLI | **all sessions including writer** |
| `automemory` | Stop hook mirroring `~/.claude/projects/<cwd>/memory/*.md` | other sessions |
| `join` | SessionStart hook | nobody (presence only) |
| `leave` | SessionEnd hook | nobody (presence only) |

---

## How it works under the hood

For each launch, the wrapper:

1. Pre-allocates a session UUID and exports `MEMORY_CLAUDE_KEY`,
   `MEMORY_CLAUDE_SESSION_ID`, `MEMORY_CLAUDE_DIR` to the child process.
2. Builds a pool snapshot from `~/.memory-claude/<key>/pool.ndjson` and
   passes it via `--append-system-prompt`.
3. Injects four hooks via `--settings '<json>'` (one-off, no global
   config mutation):
   - `SessionStart` — register the session, emit the bootstrap snapshot.
   - `UserPromptSubmit` — read the delta of new pool events since this
     session last spoke and inject it as `additionalContext`. This is
     the **live propagation mechanism**.
   - `Stop` — compress the assistant turn and append it. Also mirror any
     new files in the cwd's native auto-memory.
   - `SessionEnd` — deregister and append a `leave` event.
4. Resolves the **real** `claude` binary (`~/.local/bin/claude`),
   bypassing cmux's wrapper.

### Pool layout

```
~/.memory-claude/<key>/
├── pool.ndjson        append-only event log (source of truth)
├── pool.md            rendered view (regenerated on demand)
├── sessions.json      live presence (connected sessions)
├── meta.json          key metadata
├── seen/
│   ├── <sid>.cursor              per-session byte offset into pool.ndjson
│   ├── <sid>.automemory-mtime    last mtime seen in cwd's native memory/
│   ├── <sid>.transcript.cursor   last transcript offset summarized
│   └── <sid>.git                 last git context captured for this session
├── snapshots/
│   ├── <sid>-init.md             SessionStart injection (one per session)
│   └── <sid>-turn-<epoch>.md     per-turn deltas (only if DEBUG=1)
└── log                           hook stderr
```

### Delta propagation

Each session maintains a **byte cursor** into `pool.ndjson`. On every
`UserPromptSubmit`, the hook:

1. Reads bytes from `cursor` to EOF.
2. Filters to `summary | note | automemory` events whose `sid` isn't
   the current session (except `note`s, which are always visible).
3. Applies tag filters from `MEMORY_CLAUDE_TAGS` / `EXCLUDE_TAGS` /
   `TAGS_STRICT`.
4. Renders the survivors as `additionalContext` and feeds them to Claude
   for that turn.
5. Advances the cursor unconditionally so the same bytes aren't re-read.

This keeps each session's view of the pool deterministic and
incremental — no scanning the whole log every turn.

---

## Caveats

- **macOS-only out of the box** (uses `stat -f`, `tail -r`). Linux works
  with minor tweaks (`stat -c`, `tac`).
- **Sessions launched through cmux** bypass cmux by default and exec the
  real `claude`. cmux's own features (notifications, etc.) won't apply
  to those sessions. A `--via-cmux` merge mode is on the roadmap.
- **Pool grows over time.** Auto-rotation at 256 KB / 500 entries keeps
  it bounded; older entries spill into `pool.ndjson.<ts>.bak` files,
  which `search` includes by default.
- **Headless `claude -p` invocations** launched outside the wrapper are
  unaffected — hooks no-op when `MEMORY_CLAUDE_KEY` is unset.
- **Manual notes have a literal `sid:"manual"`.** If you need
  per-author attribution, read the `author` field
  (`$USER@$(hostname)`).
- **Compression is lossy by design.** For load-bearing decisions, write
  a `note` instead of trusting the auto-summary of an assistant turn.

---

## License

MIT. Personal project — no warranty.
