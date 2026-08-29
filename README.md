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

## Contributing

`main` is protected — changes go through a pull request.
