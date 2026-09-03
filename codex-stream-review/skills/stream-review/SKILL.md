---
name: stream-review
description: Use when you want live progress visibility into a Codex review and cheap multi-round follow-up on the same reviewer thread (no diff re-send) — an experimental, separate alternative to /cc and codex-direct-review's ephemeral-process-per-round design. Not a replacement for /cc's equal-partnership adversarial-review loop, which stays exactly as it is.
---

# Stream Review (experimental)

## Overview

Runs a Codex review as a **persisted, resumable thread** via this plugin's
`run-stream-review.sh`, instead of a fresh ephemeral process per round.
Round 1 starts the thread with `codex exec --sandbox read-only`; every
follow-up round resumes that same thread with `codex exec resume`, so Codex
already has the diff and prior findings in its own context — a follow-up
`--focus` should carry only the new question, never the diff again. This is
the opposite tradeoff from `codex-direct-review`/`/cc`, which re-run
everything fresh each round and never leave anything on disk; this plugin
leaves a real thread + rollout file behind on purpose (that's what makes
resume possible), which is why cleanup below is a real caller obligation,
not a formality.

This is **experimental and separate** from `/cc` and `codex-direct-review`.
It does not replace either — `/cc`'s multi-round Claude+Codex adversarial
consensus loop stays exactly as it is for cross-verification work. Reach for
this plugin instead when you specifically want to watch a single reviewer's
progress live or run a multi-round follow-up on one thread cheaply; reach
for `/cc`/`codex-review` for everything else. Running several reviews at
once is just invoking the wrapper multiple times with different `--cwd`
values — each gets its own independent thread and rollout file, no shared
state between them.

## When invoked

### 1. Start a review (round 1)

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/run-stream-review.sh" \
  --cwd "<the project directory>" \
  --focus "<what to review and what to check for>" \
  [--output-schema <path to a JSON Schema file>]
```

A round can legitimately take up to 30 minutes, so don't assume a fast
reply — run it in the background and wait for it rather than treating a
long pause as a hang.

Unlike `codex-direct-review`'s `run-codex-review.sh`, this wrapper has no
`--uncommitted`/`--base`/`--commit` flags and gathers no diff itself — it
forwards `--focus` verbatim as the prompt to `codex exec`. Scope is entirely
the caller's responsibility: either embed the actual diff content in
`--focus` directly, or give Codex explicit instructions for finding it
itself (e.g. "review the uncommitted diff in this repo") and let it run
`git diff` on its own — `--sandbox read-only` permits reads and shell exec,
just not writes.

The wrapper prints exactly one line of JSON:

- `{"ok":false,"reason":"...","threadId":"...","detail":"..."}` — the run
  itself failed (bad arguments, no thread ever started, timeout, nonzero
  exit, missing task-complete event, an unresolvable rollout file, no final
  answer found, or an invalid-JSON final answer). Report this as a failed
  run, never as a clean verdict. `threadId` may be present even on failure —
  hang onto it when it is, since a failed round can still have left a
  thread on disk that needs `--cleanup`.
- `{"ok":true,"threadId":"...","verdict":...}` — `verdict` is a parsed JSON
  object when `--output-schema` was given, otherwise the raw answer text as
  a JSON string. Present it to the user; nothing here is auto-fixed.

Always hold onto `threadId` from the response — it's what makes `--resume`
and `--cleanup` possible.

### 2. Continue a review (round 2+, `--resume`)

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/run-stream-review.sh" \
  --cwd "<the same project directory>" \
  --resume "<threadId from the prior round>" \
  --focus "<only the new follow-up/rebuttal question>" \
  [--output-schema <path to a JSON Schema file>]
```

Put only the new question in `--focus` — the diff and every prior finding
are already in the thread's own context, and re-sending them defeats the
entire point of resuming instead of starting fresh. An unknown or
already-cleaned-up `threadId` fails fast (`"reason":"resume_thread_not_found"`)
before any Codex call is dispatched, so a mistaken `--resume` after cleanup
is cheap to notice.

### 3. Clean up — the caller's job, not automatic

Nothing about a round auto-deletes anything: the thread and its rollout
file (which can contain the full diff/code content under review) are left
on disk on purpose, because `--resume` needs the thread to still exist for
the next round. Once the whole multi-round review is actually finished —
no more `--resume` calls coming for this thread — clean it up exactly once:

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/run-stream-review.sh" --cleanup "<threadId>"
```

Call this **only after the last round of a given review**, never after an
intermediate one — cleaning up after round 1 and then trying to `--resume`
for round 2 will fail with `resume_thread_not_found`, because the thread and
its rollout file are already gone. If cleanup itself fails
(`{"ok":false,"reason":"cleanup_failed",...}`), surface that to the user
rather than swallowing it — an undeleted thread means that review's full
diff/code content is still sitting on disk under `~/.codex/sessions/`.

### 4. Safety model — plain read-only, no approval flow

Every fresh round runs with `--sandbox read-only`: Codex cannot write
anywhere, inside or outside the repo under review — same boundary `/cc`
already uses. A resumed round passes no `--sandbox` flag at all (`codex exec
resume` doesn't have one) and simply inherits whatever sandbox mode the
thread started with.

There is no approval-gated write capability here, and none is coming later
for this design: an earlier plan explored letting Codex ask before writing
and Claude decide per-action, but headless `codex exec`/`codex exec resume`
has no approval-request mechanism to answer on the installed CLI version at
all — this was investigated and confirmed dropped, not merely unbuilt yet.
Don't tell a user this plugin can grant Codex supervised write access; it
can only ever be fully read-only or fully blocked, exactly like `/cc`.
