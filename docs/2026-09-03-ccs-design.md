# `/ccs` — Design Spec

> Companion reading: `docs/2026-09-03-codex-stream-review-design.md` (the
> plugin this builds on) and `~/.claude/commands/cc/SKILL.md` (the sibling
> command this parallels — read-only reference, never modified by this
> work).

## Goal

Build `/ccs` ("cc-stream"), a new skill shipped **inside the
`codex-stream-review` plugin**, that gives the same outcome as `/cc` —
Claude and Codex reach fact-based, evidence-verified consensus (CLEAN) on
a piece of work through an adversarial, multi-round review loop — but
built on `codex-stream-review`'s persisted-thread mechanism instead of
`codex-direct-review`'s ephemeral-process-per-round mechanism.

**`/cc` is explicitly untouched by this work.** It remains exactly as it
is, at `~/.claude/commands/cc/SKILL.md`, a personal, non-version-controlled
command backed by `codex-direct-review`. `/ccs` is a separate, additional
option — version-controlled, installable via the `codex-stream-review`
plugin — not a replacement, migration path, or deprecation notice for
`/cc`. A user picks whichever fits: `/cc` for the existing, further-proven
mechanism; `/ccs` for cheaper multi-round follow-up (no diff re-send after
round 1) and, in a tmux-capable environment, an automatically-opened live
progress view.

### Why headless, not the interactive `codex` TUI

An earlier exploration this same day considered driving Codex's actual
interactive TUI (via tmux `send-keys`/`capture-pane`) as `/ccs`'s
underlying mechanism, specifically because it would let a human type
directly into the same live session mid-review. This was explicitly
decided against: screen-scraping a TUI's rendered output is inherently
less reliable for the structured, evidence-based finding/verdict parsing
this adversarial loop depends on, than the headless `codex exec`/`codex
exec resume --json` mechanism `codex-stream-review` already uses and has
proven (3-round `/cc` review to CLEAN convergence, plus a live
end-to-end timestamped test showing a 5.46s dispatch→signal gap and a
41.21s signal→completion live-progress window). `/ccs` uses the headless
mechanism throughout. The tmux pane it opens is a **read-only live view**
for a human to watch — not an interactive session a human types into.

## Architecture

```
Round 1: run-stream-review.sh --uncommitted|--base <ref>|--commit <sha> \
           --focus "<Why/History/Scope framing>"
         -> fresh codex exec, thread created, diff collected BY THE WRAPPER
         -> threadId known (stderr signal, ~seconds in)
         -> (if tmux available) auto-open a pane tailing the rollout file,
            formatted as narration, not raw JSON
         -> round completes -> verdict + findings + coverage

Round 2+: run-stream-review.sh --resume <threadId> \
            --focus "<rebuttal/new-scope text only, never the diff again>"
         -> same thread, no diff re-send
         -> same tmux pane keeps tailing (same rollout file)
         -> round completes -> verdict + findings

... repeat until CLEAN, NOT CONVERGED (20-round cap), or COULD NOT VERIFY ...

Terminal state: run-stream-review.sh --cleanup <threadId>  [ALWAYS, automatic]
                close tmux pane (if opened)                [best-effort]
                final Korean report to user
```

The **caller-owns-cleanup contract that `codex-stream-review`'s raw
`stream-review` skill documents does not apply to `/ccs` callers** — `/ccs`
owns the thread's entire lifecycle itself (it's the only thing that ever
`--resume`s it), so it always calls `--cleanup` on every terminal path,
with no separate opt-in step a human needs to remember.

## Components

### 1. `run-stream-review.sh` gains `--uncommitted` / `--base <ref>` / `--commit <sha>`

**The gap this closes:** the wrapper currently has no diff-gathering of
its own — `--focus` is forwarded verbatim to `codex exec`, entirely the
caller's responsibility (documented in `stream-review/SKILL.md`'s "Unlike
`codex-direct-review`'s `run-codex-review.sh`..." passage). `/cc`'s own
rigor depends on `run-codex-review.sh` collecting the diff itself
(tracked + untracked files, symlink/oversize/binary handling, `git diff
--no-ext-diff --no-textconv` safety) and reporting a structured
`coverage.source` object (`complete`/`partial`+`omitted`). Without an
equivalent, `/ccs` would either re-implement this collection logic
independently (real risk of missing an edge case `/cc`'s own "Known
Failure Patterns" section already learned the hard way — see that
section's symlink-dereference/TOCTOU-race/FIFO-hang history) or ship
without structured coverage tracking at all.

**The fix:** add the same three scope flags `run-codex-review.sh` already
has, **porting its collection + coverage logic verbatim** — not calling
into it at runtime. `codex-direct-review` and `codex-stream-review` are
two independently-installable plugins (a user may have either without
the other), so `run-stream-review.sh` cannot take a runtime dependency on
`codex-direct-review`'s own script being present. "Reuse" here means:
copy the proven collection logic (tracked+untracked file gathering,
symlink/oversize/binary classification, the `--no-ext-diff --no-textconv`
safety, the `coverage.source` object construction) directly into
`run-stream-review.sh` as its own self-contained code, byte-identical in
behavior to `run-codex-review.sh`'s own — not re-derived from scratch,
but also not a shared library or cross-plugin call. Two copies of the
same proven logic, each plugin fully self-contained. When one of these
flags is given, `run-stream-review.sh` collects the diff itself and
folds it into the prompt sent to `codex exec` (alongside `--focus`'s
Why/History/Scope framing text, which becomes pure instructions/context
now, never the diff itself), and includes a `coverage` object in its
JSON result matching `run-codex-review.sh`'s existing shape exactly.
`--focus` remains required in all cases; providing one of the three
scope flags does not make `--focus` optional, it just changes what
`--focus` is for.

On `--resume`, the diff is never re-collected (Codex already has it in
thread context) — the three scope flags are only meaningful on a fresh
round; passing one alongside `--resume` is a `bad_args` error.

### 2. New skill: `codex-stream-review/skills/ccs/SKILL.md`

The orchestration logic Claude follows — structurally parallel to `/cc`'s
own SKILL.md (equal-partnership principles, the Why/History/Scope
`--focus` discipline, the re-verification requirement, the whole-flow
re-check step, the convergence/guard rules, the JSONL review history log)
but scoped down per the v1 decision below, and swapping every
`run-codex-review.sh --uncommitted` round-dispatch for `run-stream-review.sh`
fresh-then-resume dispatch.

**v1 scope — core loop only, explicitly deferred:**
- **No parallel multi-reviewer mode.** `/cc`'s parallel mode dispatches
  several concurrent `--uncommitted` calls with different `--focus`
  dimensions against the *same* diff. This composes awkwardly with a
  single resumable thread (which dimension's thread does round 2 resume?)
  and adds real design surface. v1 is always single-reviewer.
- **No `--capture-evidence` investigation-evidence capture.** `/cc`'s
  opt-in raw-command-extraction feature is a meaningful chunk of that
  file's own complexity: deferred, can be added later following the same
  pattern if wanted.
- Both are real, addable-later features, not abandoned ideas — v1 is
  scoped for YAGNI, not because either lacks value.

### 3. tmux auto-pane: `codex-stream-review/scripts/watch-rollout.sh <rollout-file>`

A small, separate companion script (not inlined into the skill's own
prose each time it's needed) that tails a rollout file and formats its
events as human-readable narration — extracting `reasoning` text,
`custom_tool_call`/`custom_tool_call_output` commands (e.g. "investigating:
`git diff --unified=80`"), and `task_complete` — rather than dumping raw
JSONL. `/ccs`'s skill instructions: detect tmux (`[ -n "${TMUX:-}" ]`),
and if present, split the current window (`tmux split-window -h`) and run
this script against the round's resolved rollout file, *inside a shell*
(not as the pane's sole foreground command) so the pane survives even if
the tail process ever exits unexpectedly — the exact lesson learned
live earlier this same day, when a pane running `codex` directly closed
the instant that process exited. If tmux is unavailable, or pane creation
fails for any reason, this is entirely best-effort: the loop proceeds
identically, narrating only through Claude's own text updates, exactly
as `/cc` already behaves without any pane at all.

### 4. Review history log (JSONL)

Same one-line-per-round, session-scoped design `/cc` already uses, at a
plugin-appropriate local path instead of `/cc`'s own command-local one:
`~/.claude/plugins/data/codex-stream-review/ccs-logs/<repo-slug>/<session-id>.jsonl`.
Same schema shape (`target`, `codex_review`, `coverage_source`,
`claude_verification`, `round_outcome`) minus the fields that only apply
to `/cc`'s deferred-for-v1 features (`investigation_evidence`, `groups`).

### 5. Automatic cleanup

`--cleanup <threadId>` is called on every terminal path (CLEAN, NOT
CONVERGED, COULD NOT VERIFY, PARTIAL COVERAGE) — never left to the human.
A cleanup failure is surfaced in the final report, never silently
swallowed, matching the wrapper's own `cleanup_failed` contract.

## Data Flow

```
Round 1 dispatch (scope flag + Why/History/Scope focus)
  -> wrapper collects diff + coverage, dispatches codex exec fresh
  -> stderr THREAD_ID= signal (~seconds)
  -> tmux available? open watch-rollout.sh pane on the resolved rollout file
  -> wait for round completion (same PID-liveness watcher /cc uses)
  -> parse {ok, verdict, findings, coverage}
  -> Claude re-verifies each finding against evidence (accept/reject/rebut)
  -> whole-flow re-check for any fix applied this round
  -> append round to JSONL log
  -> convergence check
  -> converged or capped? -> terminal path (see below)
  -> else: Round 2+ via --resume, --focus = rebuttal/new-scope text only
Terminal path (any exit): --cleanup <threadId> (always) -> close tmux pane
  (best-effort) -> final Korean report (task summary, convergence table,
  consensus status, source coverage, verified/not-verified/risks)
```

## Error Handling

Mirrors `/cc`'s existing guards exactly, applied to `/ccs`'s own rounds:
- `ok:false` on any round -> retry once -> `COULD NOT VERIFY` if it still fails.
- `coverage.status` `partial` (with real omitted paths) or `unknown`
  (wrapper omitted the field) on a scope-flagged round -> `PARTIAL
  COVERAGE` unless explicitly resolved another way.
- Zero progress twice in a row -> stop early, report `NOT CONVERGED`
  rather than burning the remaining round budget.
- tmux pane creation failure -> best-effort, non-fatal, no different from
  running in a non-tmux environment.
- `--cleanup` failure at the terminal path -> surfaced plainly in the
  final report (which thread, why), never hidden behind a clean-looking
  headline result.

## Testing

1. **`run-stream-review.sh`'s new scope flags:** a live scratch-repo test
   confirming `--uncommitted`/`--base <ref>` produce a diff+coverage
   result equivalent to `run-codex-review.sh`'s own output for the
   identical repo state (same files, same coverage status) — proving the
   ported collection logic behaves identically to its source, not
   subtly diverged during the port.
2. **`/ccs` end-to-end:** a real small diff with an intentional, findable
   bug — confirm round 1 finds it, a resumed rebuttal round answers
   without re-investigating the diff (rollout inspection, zero new
   `custom_tool_call` events in the resumed portion — the same check
   already proven for raw `run-stream-review.sh --resume` earlier this
   session), convergence reached, `--cleanup` genuinely removes the
   thread (independent `find ~/.codex` sweep), and — in a tmux
   environment — the pane appears, survives the round, and shows real
   narrated progress.
3. **`/cc` cross-review** of this entire branch's diff before merge,
   following this project's established convention for every prior
   change.

## Open Items

- **Invocation form.** Whether `/ccs` is literally invocable as a bare
  slash command from inside a plugin skill, or requires a
  plugin-qualified form (e.g. `/codex-stream-review:ccs`, matching how
  `stream-review` currently lists as `codex-stream-review:stream-review`
  in this session's own available-skills listing), needs to be confirmed
  during implementation — this affects the skill's own frontmatter/naming
  but not this design's substance. Whichever form the harness actually
  supports, "ccs" is the skill's own short name either way.
