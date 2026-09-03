# codex-stream-review — Design Spec

> Status: draft, pending user review. Companion knowledge base:
> `docs/superpowers/plans/2026-09-03-codex-appserver-streaming-knowledge.md`
> (raw research notes — read that first if anything here seems to assume
> undocumented context).

## Goal

A **separate, experimental** Claude Code plugin (does not replace `/cc` /
`codex-direct-review`, which stay exactly as they are) that gives Codex
reviews three things the current ephemeral-`codex exec`-per-round design
cannot:

1. **Live, real-time progress visibility** — see what Codex is doing
   (reasoning, commands run, draft answer) as it happens, not only after
   the whole call finishes.
2. **Token/latency efficiency across multi-round follow-up** — reuse a
   single Codex thread's own persisted context across rounds instead of
   re-sending the full diff + prior findings every round.
3. **Parallel reviewer orchestration** — run several review threads
   concurrently and observe all of them live.

Explicitly **not** a goal for v1: replacing `/cc`'s equal-partnership
consensus loop. Unlike an earlier draft of this doc assumed, `--output-schema`
structured verdicts are NOT a limitation of this design — see "Structured
output" below, which is a strict improvement over `/cc`'s current
post-exit-only structured output.

An earlier draft of this doc also planned a fourth capability —
finer-grained, per-action approval control in place of `/cc`'s blanket
`read-only` sandbox — as part of the original three-goal framing's safety
model. **That capability does not exist to be gained on the installed CLI
version and has been dropped**; see "Safety model" below. This plugin
ships with the same `--sandbox read-only` boundary `/cc` already uses, no
better and no worse on that specific axis — the three goals above (live
streaming, token efficiency, parallel orchestration) are what it actually
delivers.

## Why not the app-server RPC / MCP paths (rejected alternatives)

Both investigated and rejected for v1 — see the knowledge base for the
full evidence trail:

- **`codex mcp-server`**: explicitly deprecated by the CLI itself
  (`warning: ... is deprecated and will be removed in a future release`),
  no public replacement documented, and its `content` field is free text
  with no `--output-schema`-equivalent enforcement. Do not build on it.
- **`codex app-server` RPC socket** (the officially "correct"-looking
  path, with a rich `ServerNotification` schema including token-level
  streaming deltas): the fully-managed daemon lifecycle
  (`codex app-server daemon start`) requires a "standalone" Codex install
  that is a **separate installation from this machine's npm/nvm-installed
  `codex`**, obtainable only via `curl -fsSL
  https://chatgpt.com/codex/install.sh | sh` — which is blocked at this
  organization's network/proxy level (redirects to an internal web-filter
  block page). A manually-started `--listen unix://<path>` instance does
  accept a raw connection, but the server silently closes it with zero
  response and zero server-side log trace for the request — strong
  evidence this ad-hoc path is talking to a narrow "control" endpoint,
  not the full session RPC surface, independent of any install/auth
  question. Revisit this path later only if the standalone install
  becomes available (would need an IT/network exception); not a
  prerequisite for v1.

## The mechanism this design actually uses (confirmed working, 2026-09-03)

No socket, no daemon, no new install, no auth changes. Three already-existing,
independently-proven primitives:

1. **`codex exec <prompt>`** (first round) / **`codex exec resume <threadId>
   <prompt>`** (follow-up rounds) — starts or continues a **persisted**
   thread (do **not** pass `--ephemeral` in this design — persistence is
   required so the thread can be resumed later; see "Data retention"
   below for the resulting privacy/cleanup obligation this creates).
   Capture the `threadId` from the `thread.started` event in the
   process's own `--json` stream on round 1.
2. **`~/.codex/sessions/YYYY/MM/DD/rollout-<timestamp>-<threadId>.jsonl`**
   — every thread's own live, append-only event log, one file per thread,
   updated in real time while the thread is processing a turn. Tail this
   file (`Monitor` with `tail -F`) for live progress, independent of
   whether the round was started via `codex exec` or `codex exec resume`.
   Confirmed live-tailed successfully today: new lines appeared within
   ~1s of a round starting, well before the round finished.
3. **Event vocabulary in the rollout file** (confirmed by direct
   observation of a real turn): `response_item` entries with `payload.type`
   of `message` (`payload.phase` distinguishes `commentary` — intermediate
   narration, discard for the "answer" — from `final_answer` — the actual
   text to surface), `reasoning`, `custom_tool_call` /
   `custom_tool_call_output` (a command actually run + its result — this
   is the same "did it actually investigate" evidence
   `--capture-eventlog` extracts elsewhere in this project, available here
   for free from the same file); `event_msg` entries with `payload.type`
   of `item_completed`, `token_count`, and **`task_complete`** — the
   definitive, unambiguous end-of-round signal (the same structural role
   `codex exec --json`'s `turn.completed` already plays for `/cc`).

## Round lifecycle (single reviewer)

```
1. Determine round number.
   - Round 1: run `codex exec --json --sandbox read-only
     -c model_reasoning_effort=<level>
     "<review prompt: diff + instructions>" < /dev/null` in the target
     repo, in the background (matches /cc's existing backgrounded-Bash +
     PID-liveness-watcher pattern — reuse that machinery, don't reinvent
     it; always redirect stdin from /dev/null — see the "Structured
     output" section's stdin-hang gotcha).
   - Round 2+: same, but `codex exec resume <threadId> --json ...
     "<follow-up prompt: just the new rebuttal/question, NOT the diff
     again>"` — this is where the token-efficiency goal is actually
     realized: Codex already has the diff and prior findings in its own
     persisted thread context.
2. Parse the FIRST few lines of the process's own --json stdout stream
   (not the rollout file) to capture `threadId` from `thread.started` —
   this is available immediately, before the rollout file path is known
   with certainty from the outside (the file is named using the thread's
   own start timestamp, which this process determines, not the caller).
3. Once threadId is known, resolve the rollout file path
   (`~/.codex/sessions/<Y>/<M>/<D>/rollout-*-<threadId>.jsonl` — glob by
   threadId suffix since the exact timestamp prefix isn't independently
   predictable) and start tailing it live via `Monitor` for progress
   narration (e.g., surface `custom_tool_call` commands as "investigating:
   <command>" progress lines).
4. Wait for `task_complete` in the tailed stream (defense in depth: also
   apply /cc's existing PID+start-time liveness watcher on the `codex
   exec`/`codex exec resume` process itself, exactly as today, in case the
   rollout-file signal is somehow missed).
5. Extract the final answer: last `response_item` with
   `payload.type=="message"` and `payload.phase=="final_answer"`.
6. No approval-request step exists in this lifecycle — see "Safety model"
   below for why: headless `codex exec`/`resume` has no such mechanism on
   this CLI version at all, confirmed by Task 1's live testing.
```

## Safety model — `--sandbox read-only`, matching `/cc` (DECIDED 2026-09-03, reversing the original approval-based direction)

**The originally-chosen "approval-based, not blanket read-only" direction
is not achievable and has been dropped.** Task 1's spike (full evidence
in the knowledge base's "Task 1 spike result" section) conclusively
found: headless `codex exec`/`codex exec resume` has **no
approval-requesting mode at all** on this CLI version (`0.151.0`) —
`-a/--ask-for-approval` doesn't exist on either entrypoint (only on the
interactive `codex` command), and the rollout file's own `turn_context`
confirms `approval_policy` is **hardcoded to `"never"`**, independently
confirmed for both a fresh and a resumed thread. `--approve-for-me`
exists and is a real (non-rubber-stamp) check, but it is not
interceptable or answerable by the calling process at all — the entire
review happens inside an opaque, currently-flaky external service, with
zero opportunity for Claude to apply its own judgment per action, which
was the whole point of choosing an approval model in the first place.
There is no approval-answering mechanism to build against.

**Decision: `--sandbox read-only`, not `--sandbox workspace-write`.**
Task 1's own report recommended `workspace-write` instead of the plan's
originally-stated outcome-(b) fallback (`read-only`), reasoning that
`workspace-write`'s small static writable-root allowlist (workspace root
+ `/tmp` + `$TMPDIR`) "costs nothing extra" since everything outside it
still hard-fails immediately, same as `read-only`. That framing only
weighs the *outside-the-repo* case, where the two sandbox modes are
indeed equivalent — it does not weigh the *inside-the-repo* case, which
is exactly where they differ and exactly where it matters: `read-only`
permits **zero** writes anywhere, including inside the repo under
review; `workspace-write` permits **silent, un-gated writes inside the
repo itself**, since `approval_policy` is hardcoded to `"never"`
regardless of sandbox mode — there is no confirmation step, and no event
in the stream distinguishes an in-repo write from any other completed
action. That is precisely the failure mode `/cc`'s own core principle
("Codex stays read-only; Claude remains the sole editor") exists to
prevent. Task 1's stated justification for wanting write access at all
— "allowing the reviewer to write findings/notes inside the repo... if
ever needed" — is not actually needed by this design: findings are
already extracted from the live-tailed rollout file's own event stream
(see "Structured output" below), never from a file Codex writes to disk.
There is no real benefit here to offset a real, unmitigated risk.
**`--sandbox read-only` is therefore the correct choice** — it matches
`/cc`'s own precedent exactly (zero regression in the reviewer-never-
edits-code guarantee), and costs nothing relative to `workspace-write`
for anything outside the repo, since both hard-fail identically there.

This is a genuine, accepted reduction in scope from the plan's original
three-goal framing: this plugin gains live streaming and token-efficient
multi-round follow-up, but not finer-grained per-action approval control
— that specific capability does not exist to be gained on this CLI
version. If a future CLI version adds a real headless approval-request
mechanism, revisit this section.

## Data retention (new obligation this design introduces) — DECIDED 2026-09-03

Because rounds are **not** `--ephemeral` (persistence is required for
`resume` to work), each review leaves a real, persisted thread + rollout
JSONL file under `~/.codex/sessions/`. `/cc`'s existing design deliberately
avoids exactly this kind of accumulation.

**Decision: use `codex delete <threadId> --force` at the end of every
review, not `codex archive`.** Confirmed exact semantics (Task 4 spike,
`codex-cli 0.151.0` — full embedded evidence in the knowledge base's "Task 4
spike result" section):

- `codex delete <id> --force` **permanently removes** the rollout JSONL file
  from disk entirely (verified gone via `find` under all of `~/.codex`, not
  just its origin directory) and deletes its rows from the
  `thread_history_1.sqlite` index (`thread_items`/`thread_turns` both go to
  0 rows). `--force` is required for any non-interactive/scripted caller —
  without it, `codex delete` fails fast with `Error: cannot confirm session
  deletion without an interactive terminal; rerun with --force and a
  session UUID` (exit 1, no hang) when stdin isn't a TTY.
- `codex archive <id>` (rejected as the default) only **moves** the rollout
  file from `~/.codex/sessions/<Y>/<M>/<D>/` to a flat
  `~/.codex/archived_sessions/` directory — full file content (all
  `response_item`s) stays intact and readable, and the sqlite index rows
  are **not** cleared. This does not reduce retention at all; it relocates
  the same sensitive content indefinitely.

**Reasoning, tied to this project's own precedents**: `/cc`'s
review-history JSONL log is a curated *summary* of findings (an audit
trail) — retaining it indefinitely is safe and useful. This plugin's
rollout file is the opposite case: it is closer to
`run-codex-review.sh`'s raw eventlog (deleted immediately after
extraction) because it can contain the **full diff/code content** under
review, not a curated summary — `archive` would leave that full content
sitting on disk indefinitely under a different path, which is the raw
eventlog's exact anti-pattern, not the audit-log's. `delete` is the
correct fit, and matches the "delete-by-default, explicit documented
exception only for what's deliberately kept" pattern already established
this session.

- The wrapper must call `codex delete <threadId> --force` as its cleanup
  step at the end of every review round sequence (final round only — not
  after each intermediate round, since `resume` needs the thread to still
  exist for the next round).
- Never leave a completed review's persisted thread lying around
  indefinitely as a silent default — if `codex delete` itself fails for
  any reason, that failure must be surfaced (not silently swallowed),
  matching this project's "best-effort cleanup, never silently skip it"
  convention.

## Structured output — confirmed working, a strict improvement over `/cc`

**Spiked and live-tested 2026-09-03 (see the knowledge base's "Task 3 spike
result" section for full embedded evidence)**: `--output-schema` composes
cleanly with both `--json` streaming and `codex exec resume`. A fresh round
and a resumed round both produced `--output-last-message` files that
validate against the schema (required fields present, enum respected, no
extra properties). More importantly, **the live rollout file's own
`response_item`/`message`/`final_answer` entry already contains the exact
same structured JSON for both rounds — not a free-text draft that only gets
shaped into schema form at process exit** — written to disk ~250-330ms
before that round's `task_complete` event, in both the fresh and the
resumed round.

This means a `codex-stream-review` implementation can read the
schema-valid verdict directly off the live-tailed rollout file the moment
the `final_answer` message entry appears, without waiting for
`--output-last-message` or process exit at all — a genuine capability
`/cc` does not have today (it only obtains structured output after full
process exit via `--output-last-message`). No prompt-engineered
free-text-parsing fallback is needed for this.

One operational gotcha found during this spike, relevant to any
implementation that shells out to `codex exec` non-interactively: **always
redirect stdin from `/dev/null` explicitly** (e.g. `codex exec ... < /dev/null`).
`codex exec`'s `[PROMPT]` argument handling also tries to read stdin to
append as a `<stdin>` block even when a prompt is supplied as an argument;
if the calling process's stdin is left open (not already closed/redirected),
`codex exec` hangs indefinitely waiting for EOF, with no error — only a
silent `Reading additional input from stdin...` line.

## Parallel reviewer orchestration

Multiple concurrent reviews = multiple concurrent `codex exec` processes
(different threads), each with its own tailed rollout file. No new
mechanism needed beyond running the single-reviewer lifecycle N times
concurrently (mirrors `/cc`'s existing Phase 1 parallel-group dispatch
pattern) — the file-per-thread design has no shared-state contention
between concurrent reviewers to worry about.

## Open items — all four spikes complete (2026-09-03), safety model finalized by the coordinator

1. ~~Approval-request event shape + answer mechanism for a headless `codex
   exec`/`resume` call~~ — **CONFIRMED 2026-09-03**: no such mechanism
   exists on this CLI version (`approval_policy` hardcoded to `"never"`
   for both fresh and resumed threads). The design's safety model has
   been revised to plain `--sandbox read-only`, matching `/cc` — see
   "Safety model" above for the full reasoning, including why the
   spike's own `workspace-write` recommendation was not adopted.
2. ~~Confirm `codex exec resume <threadId>` reuses context correctly and
   measure actual token savings~~ — **CONFIRMED 2026-09-03**: zero
   tool-call re-investigation in the resumed round, ~63% cheaper
   (21,611 vs. 58,683 tokens) than an equivalent fresh call. See the
   knowledge base's "Task 2 spike result" section.
3. ~~Confirm `--output-schema` behavior when combined with `--json` +
   `resume`~~ — **CONFIRMED 2026-09-03**: yes, it survives both cleanly,
   and the live rollout file already contains structured JSON before
   process exit (see "Structured output" above and the knowledge base's
   Task 3 spike result).
4. ~~Confirm thread deletion/archival CLI semantics for the retention
   cleanup step.~~ — **CONFIRMED 2026-09-03**: `codex delete <threadId>
   --force` is the chosen default; see "Data retention" above and the
   knowledge base's "Task 4 spike result" section.

All four items are resolved. Proceeding to the implementation plan's
Task 6 (build the wrapper) with the finalized decisions above: `--sandbox
read-only`, `codex delete --force` cleanup, and reading structured
answers directly off the live-tailed rollout file.
