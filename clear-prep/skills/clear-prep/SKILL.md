---
name: clear-prep
description: Use when about to run /clear and durable facts or in-progress session state should survive the wipe — captures reusable info into the existing memory system and writes a handoff note into the current project's .claude/handoff/latest.md before context is cleared.
---

# Clear Prep

## Overview

Backs up what matters from the current session before `/clear` wipes context. Two separate outputs, not one blob:

- **Durable memory** — reusable across future sessions (facts, preferences, lessons). Goes through the existing auto-memory system, unchanged.
- **Handoff note** — this specific work's current state (in progress, unresolved, next steps). Project-local, short-lived, overwritten each run.

No skill or hook can trigger the actual `/clear` reset — only a literal user keystroke can. This skill only prepares; the user still runs `/clear` themselves afterward.

## When invoked

**1. Durable memory pass**

Review the conversation for anything that fits the existing memory types (user/feedback/project/reference). Follow the existing memory system's own process: check `MEMORY.md` and existing files first, update or dedupe stale entries before adding new ones. Do not duplicate what's already recorded.

Examples — durable memory: a team convention, a bugfix root-cause lesson, a stated user preference. Handoff note (below): a PR still awaiting review, a debugging thread not yet resolved, a decision that only matters until this specific task is done.

**2. Handoff pass**

Write a project-local note capturing THIS work's state — not durable facts:

- What's in progress / unresolved
- Key decisions and why
- Concrete next steps
- Relevant file:line references

Target path: `<project-root>/.claude/handoff/latest.md`, where project-root is the current working directory. **Always overwrite** — this file holds only the latest state, and it's the exact path the `session-resume-handoff.py` hook reads after `/clear`. Never move it elsewhere. Run this skill (and `/clear` afterward) from that same project-root directory — the hook looks the file up by the exact `cwd` it's given. Before writing, check the path isn't a symlink (`.claude`, `.claude/handoff`, or `latest.md` itself) — the hook refuses to follow one on read, and writing through one would put the note somewhere other than the project-local location this whole mechanism assumes.

If the project already has an existing progress-doc convention (e.g. `.claude/plans/`), also copy the same content verbatim to `.claude/plans/handoff-<YYYY-MM-DD>.md` (dated, never overwritten) for human reference. Write the canonical `.claude/handoff/latest.md` first regardless — that's the only path the hook ever reads.

Use this template:

```markdown
# Handoff — <project name> (<date>)

## In progress
- ...

## Key decisions
- <decision> — why: <reason>

## Next steps
- ...

## Relevant files
- path/to/file.ts:42 — ...
```

**3. Confirm**

Tell the user the backup is done and it's now safe to run `/clear`.

## Related

The `clear-prep` plugin bundles a `SessionStart` hook (matcher `clear`) that automatically re-injects this handoff file's content right after the user runs `/clear`, so the fresh session picks up where this one left off without being asked. The hook is registered automatically when this plugin is installed — no manual `settings.json` editing needed.

Note: this means `/clear` no longer produces a fully blank context if a handoff file exists — it comes right back. For a true full wipe, delete `.claude/handoff/latest.md` before running `/clear`.
