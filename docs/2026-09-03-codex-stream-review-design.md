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
   - Round 1: run `codex exec --json --sandbox workspace-write
     --ask-for-approval on-request -c model_reasoning_effort=<level>
     "<review prompt: diff + instructions>"` in the target repo, in the
     background (matches /cc's existing backgrounded-Bash + PID-liveness-
     watcher pattern — reuse that machinery, don't reinvent it).
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
6. If the safety model requires approval and the round produced an
   approval-request event (see "Safety model" — exact event shape is an
   open verification item, not yet observed live), the plugin must answer
   it before the round can complete; this is the first thing to spike
   during implementation, not assumed here.
```

## Safety model — approval-based, not blanket read-only (per user decision)

Chosen direction: `--sandbox workspace-write --ask-for-approval on-request`
instead of `/cc`'s blanket `--sandbox read-only`. This is a deliberate,
finer-grained alternative: rather than a static yes/no on ALL writes,
each individual write/exec attempt outside the sandbox becomes a discrete
event Claude evaluates in real time — strictly more capable than
`read-only`, but **only as safe as the actual approval logic that gets
implemented**. A policy that auto-approves everything is worse than
today's `read-only`, not better; this must not ship with a rubber-stamp
default.

**Explicitly unresolved, first implementation spike required**: this
session confirmed the `queue`/`resume`/rollout-file mechanism end-to-end
for a round with no approval-requiring actions. It did **not** confirm
what an approval-request looks like in the rollout file for a **headless
`codex exec`/`codex exec resume` call specifically** (as opposed to the
interactive TUI, where a human sees a prompt), nor how to answer one
programmatically. `--approve-for-me` ("Route approval requests through
automatic review using the workspace-write sandbox") exists as a flag but
its exact semantics need live verification — it may or may not be
suitable depending on whether "automatic review" means an LLM-side
self-check (acceptable) or a rubber-stamp (not acceptable for this
design's stated safety goal). **Do not proceed past this spike with an
assumed-safe answer** — if headless approval-handling turns out to be
unreliable or unobservable, fall back to `--sandbox read-only` for v1
and revisit the approval-based model once the mechanism is actually
verified.

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

## Open items to spike first (in implementation order)

1. **Approval-request event shape + answer mechanism** for a headless
   `codex exec`/`resume` call (see "Safety model" — this can invalidate
   the chosen safety model if it doesn't pan out; spike before writing
   the rest of the plugin).
2. Confirm `codex exec resume <threadId>` reuses context correctly (no
   diff re-send needed) and measure the actual token savings vs. today's
   `/cc` round.
3. ~~Confirm `--output-schema` behavior when combined with `--json` +
   `resume`~~ — **CONFIRMED 2026-09-03**: yes, it survives both cleanly,
   and the live rollout file already contains structured JSON before
   process exit (see "Structured output" above and the knowledge base's
   Task 3 spike result).
4. ~~Confirm thread deletion/archival CLI semantics for the retention
   cleanup step.~~ — **CONFIRMED 2026-09-03**: `codex delete <threadId>
   --force` is the chosen default; see "Data retention" above and the
   knowledge base's "Task 4 spike result" section.
5. Only after 1-4 are confirmed: write the actual implementation plan
   (`superpowers:writing-plans`) and build.
