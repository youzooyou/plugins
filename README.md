# youzooyou/plugins

Personal Claude Code plugins.

## Plugins

### clear-prep

Backs up durable memory and in-progress session state before `/clear` wipes context, then automatically restores the handoff note right after.

**Why:** `/clear` can't be triggered programmatically — only a literal keystroke fires it — so "backup then clear" can't be a single command. This plugin closes the gap: you run the backup, then `/clear` yourself, and a bundled hook silently re-surfaces what you backed up the moment the new session starts.

#### Install

```
/plugin marketplace add youzooyou/plugins
/plugin install clear-prep
```

#### Usage

1. Run `/clear-prep` before you plan to `/clear`. It reviews the session and:
   - Saves anything durable/reusable (facts, preferences, lessons) into Claude's existing memory system
   - Writes a short-lived handoff note (in-progress work, key decisions, next steps) to `<project-root>/.claude/handoff/latest.md`
2. Run `/clear` yourself — no skill or hook can do this step for you.
3. The next session picks the handoff note back up automatically via a bundled `SessionStart` hook — no need to ask for it.

To get a fully blank context with no auto-restore, delete `.claude/handoff/latest.md` before running `/clear`.

#### How it works

- `skills/clear-prep/SKILL.md` — the skill that drives the backup pass
- `hooks/hooks.json` + `hooks/session-resume-handoff.py` — a `SessionStart` hook (matcher: `clear`) that, only when the session started because of `/clear`, reads `.claude/handoff/latest.md` from the project you were in and re-injects it

### codex-direct-review

Runs a Codex CLI review as a fresh, one-shot process — no shared broker, no silent failures. Every
review call spawns a brand-new `codex exec` process, judges its result strictly (exit code, event
log, schema-valid output), and never returns silence: a failure always comes back as a structured
`{"ok":false,"reason":"...","detail":"..."}` you can act on.

**Why:** the alternative (a long-lived shared broker process behind Codex-invoking subagents) can
silently fail, finish a turn early on an ambiguous message, or stall under context pressure with no
error at all. This plugin trades that shared, stateful path for a wrapper script where every call is
independently fresh, bounded by a wall-clock timeout, and validated against a JSON schema before
being trusted.

#### Install

```
/plugin marketplace add youzooyou/plugins
/plugin install codex-direct-review
```

#### Usage

- **`/codex-review`** — a single, one-shot review of uncommitted changes, a base-branch diff, or a
  specific commit. No cross-verification, just one Codex pass with findings presented for you to act
  on (nothing is auto-fixed).
- **`/cc`** (a separate personal command, not bundled in this plugin) resolves this plugin's install
  path dynamically and calls the same wrapper directly for its multi-round Claude+Codex adversarial
  review loop.

#### How it works

- `scripts/run-codex-review.sh` — the wrapper: gathers the diff itself (`--uncommitted` / `--base` /
  `--commit`), builds a hand-written prompt (not the `codex exec review` subcommand, which does not
  honor `--output-schema`), and runs generic `codex exec --ephemeral --sandbox read-only` with a
  wall-clock timeout and process-group cleanup on both timeout and interrupt.
- `schemas/review-verdict.schema.json` — the JSON Schema every verdict is validated against before
  the wrapper reports success.
- `skills/codex-review/SKILL.md` — the standalone `/codex-review` command.

### codex-stream-review

**Experimental.** Runs a Codex CLI review as a persisted thread and signals its threadId early (on
stderr, before the round finishes) so the CALLER can resolve and tail that thread's own rollout
file for live progress narration; lets a follow-up round `codex exec resume` that same thread so it
reuses the diff/prior-findings already in its own context instead of re-sending them.

**Why:** `codex-direct-review`'s ephemeral-process-per-round design has no way to see what Codex is
doing until the whole call finishes, and every round re-sends the full diff and prior findings from
scratch. This plugin trades that for a persisted, resumable thread — live progress visibility and
cheaper multi-round follow-up — at the cost of leaving a real thread and rollout file on disk that
the caller must explicitly clean up. It does not replace `/cc` or `codex-direct-review`, which stay
exactly as they are.

#### Install

```
/plugin marketplace add youzooyou/plugins
/plugin install codex-stream-review
```

#### Usage

- Start a review with `--cwd` and `--focus`; continue it with `--resume <threadId>` and a
  follow-up-only `--focus` (never the diff again); clean up with `--cleanup <threadId>` once the
  whole review is done, not after every round — see `skills/stream-review/SKILL.md` for the full
  contract.
- Every fresh round runs `--sandbox read-only`, the same boundary `/cc`/`codex-direct-review` use —
  there is no approval-gated write capability in this plugin.

#### How it works

- `scripts/run-stream-review.sh` — dispatches `codex exec`/`codex exec resume --json`, captures the
  thread ID from the process's own stdout stream and immediately echoes it to stderr as
  `THREAD_ID=<uuid>` (the signal a caller uses for live tailing), then internally polls that
  thread's rollout file under `~/.codex/sessions/` for its own `task_complete` event and extracts
  the final answer directly from that file once the round is done. `--cleanup <threadId>` is a
  separate mode that deletes the thread via `codex delete --force`.
- `skills/stream-review/SKILL.md` — how to start, continue, and clean up a review, and the current
  safety-model status.

## Contributing

`main` is protected — changes go through a pull request.
