# memory-claude event schema

All shared-memory state lives in `~/.memory-claude/<key>/pool.ndjson`, an append-only newline-delimited JSON log. Every line is one event.

## Common fields (every kind)

| Field | Type | Required | Notes |
|-------|------|----------|-------|
| `ts` | string | yes | ISO-8601 UTC timestamp, e.g. `2026-05-19T14:32:01Z`. |
| `sid` | string | yes | Session UUID, or the literal `"manual"` for events authored by the `note` CLI. Renderers use `sid[0:4]` for the short prefix. |
| `kind` | string | yes | One of `summary | note | automemory | join | leave`. |
| `cwd` | string | yes | Absolute working directory of the writer at append time. |

## Kind: `summary`

Auto-compressed assistant turn. One event per surviving bullet from `src/lib/compress.sh`.

| Field | Type | Required | Notes |
|-------|------|----------|-------|
| `text` | string | yes | One bullet from the compressed turn. No leading dash. |
| `prompt` | string | no | The user prompt that produced this turn, captured from the transcript. Full text stored; renderers truncate. |
| `tags` | string[] | no | Lowercase, whitespace-stripped. Cap depends on source: keyword-frequency extraction (rule-based path) emits up to 2; Haiku response is unbounded by code but capped at 3 by the prompt; manual notes allow up to 5. |
| `git` | object | no | `{branch, sha}`. Branch is `"(detached)"` for detached HEAD. Omitted entirely if not in a git repo. |

Example:
```json
{"ts":"2026-05-19T14:32:01Z","sid":"1d51c6f3","kind":"summary","cwd":"/Users/iancolin/Documents/github/snappr.web","text":"Hooks are wired via --settings flag at launch, not registered globally","prompt":"how does the injector on the memory-claude repo work?","tags":["hooks","memory-claude"],"git":{"branch":"main","sha":"a1b2c3d"}}
```

## Kind: `note`

Manually authored. Producer: `memory-claude <key> note "<text>" [--tag a,b,c]`.

| Field | Type | Required | Notes |
|-------|------|----------|-------|
| `text` | string | yes | The note body. Free-form. |
| `author` | string | yes | `$USER@$(hostname)` at write time. |
| `tags` | string[] | no | From `--tag` CLI flag. |
| `git` | object | no | Best-effort; omitted if not in a git repo. |

The injector treats notes specially: **notes are always visible to all sessions including the writer's own** (the `sid != own_sid` filter is relaxed for `kind == "note"`). This is so manual annotations are reliably propagated regardless of which session wrote them.

Example:
```json
{"ts":"2026-05-19T14:35:00Z","sid":"manual","kind":"note","cwd":"/Users/iancolin/Documents/github/snappr.web","text":"auth refactor blocked by legal; do not merge before review","author":"iancolin@Ians-MBP.local","tags":["auth","compliance"],"git":{"branch":"feat/auth-rework","sha":"deadbee"}}
```

## Kind: `automemory`

Mirrored from the cwd's native Claude auto-memory at `~/.claude/projects/<cwd-slug>/memory/*.md`. One event per new `.md` file detected by the `Stop` hook.

| Field | Type | Required | Notes |
|-------|------|----------|-------|
| `path` | string | yes | Absolute path to the source `.md`. |
| `name` | string | yes | From `name:` frontmatter, or basename if absent. |
| `type` | string | no | From `metadata.type:` frontmatter (`user`, `feedback`, `project`, `reference`). |
| `description` | string | no | From `description:` frontmatter. |
| `body_excerpt` | string | no | First ~300 chars of the body after frontmatter, single-spaced. |
| `tags` | string[] | no | From `metadata.tags:` frontmatter if present; falls back to `[type]` as a single-tag default. |

Example:
```json
{"ts":"2026-05-19T14:40:00Z","sid":"1d51c6f3","kind":"automemory","cwd":"/Users/iancolin/Documents/github/snappr.web","path":"/Users/iancolin/.claude/projects/-Users-iancolin-Documents-github-snappr-web/memory/feedback_no_mocks.md","name":"feedback-no-mocks","type":"feedback","description":"integration tests must hit a real database","body_excerpt":"Don't mock the database in these tests — we got burned last quarter when …","tags":["feedback","testing"]}
```

## Kind: `join`

Emitted by `SessionStart` when a session registers. Filtered out by the injector and most renderers — exists for presence/audit only.

| Field | Type | Required |
|-------|------|----------|
| `pid` | number | yes |

## Kind: `leave`

Emitted by `SessionEnd`. Symmetric counterpart to `join`. Filtered out by the injector.

(No extra fields beyond the common ones.)

---

## Writing good entries

The compressor and tag extractor will do their best, but they're working from one assistant turn at a time and don't know what's load-bearing across the session. **If you've reached a non-obvious conclusion, ruled out an approach, or made a decision you want a future session to inherit, write it explicitly** instead of relying on the auto-summary:

```bash
memory-claude <key> note "We're keeping the old auth middleware for now — the new one breaks legacy mobile clients on iOS < 16. Revisit after mobile EOL in Q3." --tag auth,mobile,decision
```

Good notes:
- State the conclusion or decision, not the conversation that led to it.
- Include the reason (the *why*) — that's what makes the entry useful when reasons get questioned later.
- Tag with 2-3 stable topic words (`auth`, `billing`, `infra`) so other sessions can subscribe.

Avoid:
- Restating what's visible from `git log` or the codebase (the entry will drift while the code is authoritative).
- Notes about in-progress work — use a TODO comment or task tracker instead. Pool entries are for durable signals.
- Tags that name a single function or file (`getUserById`); tag by domain (`users`, `auth`) instead.

---

## Field deprecation policy

Backwards-compatible additions only. Renderers must tolerate missing fields with `// empty` or `// ""` defaults. Once published, no field is renamed or repurposed. New event `kind` values are allowed; injectors filter unknown kinds out by default.
