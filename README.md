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
- **`codex-direct-review:ccd`** (bundled in this plugin, see `skills/ccd/SKILL.md`) is this plugin's
  own multi-round Claude+Codex adversarial cross-review skill — the same review loop `codex-review`
  above runs once, but iterated to consensus.

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
the caller must explicitly clean up. It does not replace `codex-direct-review:ccd` or `codex-direct-review`, which stay
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
- Every fresh round runs `--sandbox read-only`, the same boundary `codex-direct-review:ccd`/`codex-direct-review` use —
  there is no approval-gated write capability in this plugin.
- **`codex-stream-review:ccs`** — a full Claude+Codex adversarial cross-review loop built on top of this plugin's
  resumable-thread dispatch: same consensus outcome as `codex-direct-review:ccd`, but on a resumable thread per
  reviewer, so follow-up rounds are cheap (no diff re-send after round 1) and, in a tmux-capable
  environment, a live progress pane opens automatically per reviewer. It also owns its threads'
  entire lifecycle, cleaning them up on every terminal path instead of leaving that to the caller.
  Supports both single-reviewer and parallel multi-reviewer (N concurrent, dimension-focused
  reviewers, each on its own resumable thread) modes, and can review a non-repo artifact (a design
  doc, a plan, pasted analysis text) via a throwaway isolated repo, not just a live diff. A sibling
  option to `codex-direct-review:ccd`, not a replacement — no `--capture-evidence` in v1; see
  `skills/ccs/SKILL.md`.

#### How it works

- `scripts/run-stream-review.sh` — dispatches `codex exec`/`codex exec resume --json`, captures the
  thread ID from the process's own stdout stream and immediately echoes it to stderr as
  `THREAD_ID=<uuid>` (the signal a caller uses for live tailing), then internally polls that
  thread's rollout file under `~/.codex/sessions/` for its own `task_complete` event and extracts
  the final answer directly from that file once the round is done. `--cleanup <threadId>` is a
  separate mode that deletes the thread via `codex delete --force`. Used directly by the raw
  `stream-review` skill below.
- `skills/stream-review/SKILL.md` — how to start, continue, and clean up a review, and the current
  safety-model status.
- `scripts/run-ccs-review.sh` — a separate wrapper `/ccs` dispatches through instead of
  `run-stream-review.sh` above: combines `run-codex-review.sh`'s diff-collection/coverage logic
  with the resumable-thread dispatch mechanism, since `run-stream-review.sh` itself has no
  diff-collection capability.
- `skills/ccs/SKILL.md` — the `codex-stream-review:ccs` command: a resumable-thread version of `codex-direct-review:ccd`'s
  adversarial consensus loop (max 20 rounds), with automatic thread cleanup and an auto-opening
  tmux pane — single-reviewer or parallel multi-reviewer (each group on its own persistent
  resumable thread), and non-repo-artifact reviews via a throwaway isolated repo.

## Contributing

`main` is protected — changes go through a pull request.
