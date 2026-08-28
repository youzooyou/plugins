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

## Contributing

`main` is protected — changes go through a pull request.
