---
name: stream-review
description: Use when you want live progress visibility into a single Codex reviewer and cheap multi-round follow-up on the same reviewer thread (no diff re-send). A lower-level, single-reviewer utility — for a full Claude+Codex adversarial cross-review consensus loop, use this plugin's own codex-stream-review:ccs skill instead.
---

# Stream Review (experimental)

## Overview

Runs a Codex review as a **persisted, resumable thread** via this plugin's
`run-stream-review.sh`, instead of a fresh ephemeral process per round.
Round 1 starts the thread with `codex exec --sandbox read-only`; every
follow-up round resumes that same thread with `codex exec resume`, so Codex
already has the diff and prior findings in its own context — a follow-up
round's stdin focus text should carry only the new question, never the diff again. Unlike a
fresh-process-per-round design, which re-runs everything from scratch each
round and never leaves anything on disk, this plugin leaves a real thread +
rollout file behind on purpose (that's what makes resume possible), which is
why cleanup below is a real caller obligation, not a formality.

This is a **lower-level, single-reviewer utility** — direct control over one
resumable Codex thread with no consensus loop of its own. Reach for this
wrapper directly when you specifically want to watch a single reviewer's
progress live or run a multi-round follow-up on one thread cheaply; reach
for this plugin's own `codex-stream-review:ccs` skill instead for a full
Claude+Codex adversarial cross-review consensus loop. Running several
reviews at once is just invoking this wrapper multiple times with different
`--cwd` values — each gets its own independent thread and rollout file, no
shared state between them.

## When invoked

### 1. Start a review (round 1)

```bash
printf '%s' "<what to review and what to check for>" | \
"${CLAUDE_PLUGIN_ROOT}/scripts/run-stream-review.sh" \
  --cwd "<the project directory>" \
  [--output-schema <path to a JSON Schema file>]
```

A round can legitimately take up to 30 minutes, so don't assume a fast
reply — run it in the background and wait for it rather than treating a
long pause as a hang.

**Getting live progress:** the wrapper's own final verdict only ever
appears on stdout once the whole round is done, but it signals the
threadId early — on **stderr**, as its own line (`THREAD_ID=<uuid>`) — as
soon as the thread starts, well before the round completes. To see live
progress, redirect stdout and stderr to SEPARATE files (never combine them
with `2>&1` if you want this):

```bash
printf '%s' "<prompt>" | \
"${CLAUDE_PLUGIN_ROOT}/scripts/run-stream-review.sh" \
  --cwd "<dir>" \
  > result.json 2>stderr.log &
```

Watch `stderr.log` for the `THREAD_ID=` line (e.g. with the `Monitor`
tool). Once it appears, resolve `~/.codex/sessions/**/rollout-*-<uuid>.jsonl`
and tail that file for genuine live progress narration — the wrapper itself
does not tail or narrate anything; that is entirely the caller's job, using
this early signal. A caller who doesn't care about live progress and just
redirects everything together (`> out.json 2>&1`) will see one harmless
extra `THREAD_ID=` line mixed into that combined file alongside the final
JSON verdict.

This wrapper has no `--uncommitted`/`--base`/`--commit` flags and gathers no
diff itself — it reads its own stdin, in full, and forwards it verbatim as
the prompt to `codex exec` (no positional PROMPT argument is passed; per
`codex exec --help`, omitting it makes the CLI read its instructions from
stdin instead). Scope is entirely the caller's responsibility: either embed
the actual diff content in that stdin text directly, or give Codex explicit
instructions for finding it itself (e.g. "review the uncommitted diff in
this repo") and let it run `git diff` on its own — `--sandbox read-only`
permits reads and shell exec, just not writes.

The wrapper prints exactly one line of JSON:

- `{"ok":false,"reason":"...","threadId":"...","detail":"..."}` — the run
  itself failed (bad arguments, no thread ever started, timeout, nonzero
  exit, missing `turn.completed` event, no final answer written, or an
  invalid-JSON final answer). Report this as a failed
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
printf '%s' "<only the new follow-up/rebuttal question>" | \
"${CLAUDE_PLUGIN_ROOT}/scripts/run-stream-review.sh" \
  --cwd "<the same project directory>" \
  --resume "<threadId from the prior round>" \
  [--output-schema <path to a JSON Schema file>]
```

Put only the new question on stdin — the diff and every prior finding
are already in the thread's own context, and re-sending them defeats the
entire point of resuming instead of starting fresh. There is no preflight
check on `--resume`'s `threadId` before dispatch (this wrapper does not look
up or validate it against anything of its own): an unknown or
already-cleaned-up `threadId` is instead discovered by actually attempting
the dispatch, and surfaces as whatever that real attempt produces —
`"reason":"nonzero_exit"` (never `"reason":"no_thread_started"`, whose only
branch requires a FRESH dispatch's empty threadId, structurally unreachable
once a `--resume` call has already assigned it from the given threadId).

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
for round 2 will fail (`nonzero_exit`), because the thread and its rollout
file are already gone. If cleanup itself fails
(`{"ok":false,"reason":"cleanup_failed",...}`), surface that to the user
rather than swallowing it — an undeleted thread means that review's full
diff/code content is still sitting on disk under `~/.codex/sessions/`.

### 4. Safety model — plain read-only, no approval flow

Every fresh round runs with `--sandbox read-only`: Codex cannot write
anywhere, inside or outside the repo under review — the same read-only
boundary this plugin's own `run-ccs-review.sh` also uses. A resumed round
passes no `--sandbox` flag at all (`codex exec
resume` doesn't have one) and simply inherits whatever sandbox mode the
thread started with.

There is no approval-gated write capability here, and none is coming later
for this design: an earlier plan explored letting Codex ask before writing
and Claude decide per-action, but headless `codex exec`/`codex exec resume`
has no approval-request mechanism to answer on the installed CLI version at
all — this was investigated and confirmed dropped, not merely unbuilt yet.
Don't tell a user this plugin can grant Codex supervised write access; it
can only ever be fully read-only or fully blocked.
