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
Round 1: run-ccs-review.sh --uncommitted|--base <ref>|--commit <sha> \
           --focus "<Why/History/Scope framing>"
         -> fresh codex exec, thread created, diff collected BY THE WRAPPER
         -> threadId known (stderr signal, ~seconds in)
         -> (if tmux available) auto-open a pane tailing the rollout file,
            formatted as narration, not raw JSON
         -> round completes -> verdict + findings + coverage

Round 2+: run-ccs-review.sh --resume <threadId> \
            --focus "<rebuttal/new-scope text only, never the diff again>"
         -> same thread, no diff re-send
         -> same tmux pane keeps tailing (same rollout file)
         -> round completes -> verdict + findings

... repeat until CLEAN, NOT CONVERGED (20-round cap), or COULD NOT VERIFY ...

Terminal state: run-ccs-review.sh --cleanup <threadId>  [ALWAYS, automatic]
                close tmux pane (if opened)                [best-effort]
                final Korean report to user
```

The **caller-owns-cleanup contract that `codex-stream-review`'s raw
`stream-review` skill documents does not apply to `/ccs` callers** — `/ccs`
owns the thread's entire lifecycle itself (it's the only thing that ever
`--resume`s it), so it always calls `--cleanup` on every terminal path,
with no separate opt-in step a human needs to remember.

## Components

### 1. New file: `run-ccs-review.sh` — a merge of `run-codex-review.sh`'s collection logic and `run-stream-review.sh`'s resume dispatch

**The gap this closes:** `run-stream-review.sh` has no diff-gathering of
its own — `--focus` is forwarded verbatim to `codex exec`, entirely the
caller's responsibility (documented in `stream-review/SKILL.md`'s "Unlike
`codex-direct-review`'s `run-codex-review.sh`..." passage). `/cc`'s own
rigor depends on `run-codex-review.sh` collecting the diff itself
(tracked + untracked files, symlink/oversize/binary handling, `git diff
--no-ext-diff --no-textconv` safety, a dedicated Python subprocess —
`collect_untracked_files.py` — for TOCTOU-safe untracked-file reading) and
reporting a structured `coverage.source` object
(`complete`/`partial`+`omitted`). This is roughly 400 lines of logic that
has already absorbed several real, subtle bug fixes across past `/cc`
review rounds (a TOCTOU race between two separate git calls, a
regex-based binary-file detector that mis-parsed real filenames, an
unborn-HEAD git repo failing outright, a bash-3.2.57 empty-array
"unbound variable" quirk, command-substitution silently stripping a
file's genuine trailing newline). Re-deriving this from scratch for
`/ccs` risks reintroducing bugs `codex-direct-review` already paid to
fix once.

**The fix (revised from an earlier draft of this section that proposed
patching flags directly into `run-stream-review.sh` in place):** create a
**new file**, `codex-stream-review/scripts/run-ccs-review.sh`, used only
by `/ccs` — `run-stream-review.sh` and its existing `stream-review` skill
are untouched, since other usage may already depend on their current,
shipped contract. `run-ccs-review.sh` starts as a full copy of
`run-codex-review.sh` (plus its companion `collect_untracked_files.py`,
also copied verbatim into `codex-stream-review/scripts/`), then:

- **Keeps, unchanged:** the `--uncommitted`/`--base <ref>`/`--commit <sha>`
  flag parsing and validation, the tracked-diff collection (`git diff
  --no-ext-diff --no-textconv --patch --numstat`, the unborn-HEAD
  empty-tree fallback, the combined-call TOCTOU fix), the untracked-file
  collection (delegated to the copied `collect_untracked_files.py`), and
  the `coverage.source` JSON construction (`emit_final_output`'s
  coverage-splicing logic).
- **Removes:** the ephemeral single-shot `codex exec` dispatch and its
  PID-liveness watching — no longer needed, replaced by resume-capable
  dispatch (next bullet). Also removes/adapts whatever self-test and
  integration-test harness sections are specific to the old dispatch
  model, keeping (and adapting) whatever exercises the collection/coverage
  logic itself, since that logic is unchanged and still needs its own
  tests.
- **Replaces the dispatch layer with:** `run-stream-review.sh`'s
  already-proven resume-capable mechanism — fresh-round `codex exec`
  dispatch (`--sandbox read-only`, stdin from `/dev/null`, `--` before
  the prompt text), the stderr `THREAD_ID=` early signal, rollout-file
  resolution and `task_complete` tailing, `--resume <threadId>` for
  round 2+, and the leading-dash argument-injection guards. Ported the
  same way as the collection logic — copied from the proven source, not
  re-derived.
- **Adds:** a `--cleanup <threadId>` mode, identical to
  `run-stream-review.sh`'s own.

Net result: one new, purpose-built, self-contained script combining both
proven subsystems, with neither existing script modified. Two plugins,
two independent copies of the collection logic (`codex-direct-review`'s
own copy stays exactly as it is) — no cross-plugin runtime dependency,
matching the "independently installable" constraint.

`--focus` remains required on every call; when a scope flag is given, it
holds pure Why/History/Scope framing text (never the diff itself, which
the wrapper now collects on its own).

On `--resume`, the diff is never re-collected (Codex already has it in
thread context) — the three scope flags are only meaningful on a fresh
round; passing one alongside `--resume` is a `bad_args` error.

### 2. New skill: `codex-stream-review/skills/ccs/SKILL.md`

The orchestration logic Claude follows — structurally parallel to `/cc`'s
own SKILL.md (equal-partnership principles, the Why/History/Scope
`--focus` discipline, the re-verification requirement, the whole-flow
re-check step, the convergence/guard rules, the JSONL review history log)
but scoped down per the v1 decision below, and using `run-ccs-review.sh`
(component 1 above) for every round's dispatch instead of `/cc`'s
`run-codex-review.sh` — fresh round with a scope flag for round 1,
`--resume <threadId>` for every round after.

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

1. **`run-ccs-review.sh`'s collection logic:** a live scratch-repo test
   confirming `--uncommitted`/`--base <ref>` produce a diff+coverage
   result equivalent to `run-codex-review.sh`'s own output for the
   identical repo state (same files, same coverage status) — proving the
   copied collection logic behaves identically to its source, not
   subtly diverged during the copy/trim.
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
