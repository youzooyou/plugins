---
name: ccs
description: Claude executes a task then runs a Claude+Codex adversarial cross-review loop (max 20 rounds) until fact-based consensus — the same outcome as /cc, but built on a single resumable Codex thread instead of a fresh process per round, so follow-up rounds are cheaper (no diff re-send after round 1) and, in a tmux-capable environment, a live progress pane opens automatically. /cc is unaffected and remains the other available option: reach for /cc for its further-proven ephemeral-process-per-round mechanism and parallel multi-reviewer mode; reach for /ccs for cheap multi-round follow-up and a live view into what Codex is doing.
---

# /ccs — Claude + Codex Cross-Review on a Resumable Thread

**Usage:** `codex-stream-review:ccs <task description>` — this skill is not invocable as a bare
`/ccs` slash command; it is invoked plugin-qualified, like every other plugin-supplied skill (see
"Invocation form — CONFIRMED" in `docs/2026-09-03-ccs-design.md`'s Open Items). Leave the task
description empty to review the work just done in this session. There is no `--capture-evidence`
prefix in v1 (see "v1 scope" below) — any other free text is the TASK.

Execute the given task, then reach fact-based consensus with Codex — on a single resumable
Codex thread for the whole run — before reporting to the user, or until a hard cap of 20 rounds
is hit.

This skill is structurally parallel to `~/.claude/commands/cc/SKILL.md` (equal-partnership
principles, the Why/History/Scope `--focus` discipline, the sentinel-file safe-read idiom, the
PID-plus-start-time liveness watcher, the JSONL review-history log, the convergence/guard rules,
the Korean-only final report) — read that file for the full reasoning behind any pattern only
summarized here. `/ccs` differs in three deliberate ways: it dispatches through
`run-ccs-review.sh` (a resumable-thread wrapper) instead of `run-codex-review.sh` (an ephemeral
one-shot wrapper), it opens a live tmux pane on the round's rollout file when possible, and it
**always cleans up its Codex thread on every terminal path** — never left to the user, unlike
`stream-review`'s own caller-owns-cleanup contract.

**`/cc` is unaffected by this skill.** It remains exactly as it is, still backed by
`codex-direct-review`. `/ccs` is a separate, additional option, not a replacement or migration
path.

---

## v1 scope — what this skill does NOT do

- **No parallel multi-reviewer mode.** Always a single reviewer, one thread. `/cc`'s dimension-
  split parallel mode is not ported — it composes awkwardly with one resumable thread (which
  dimension's thread would round 2 resume?). Every `GROUP="main"`-only construct below reflects
  this: there is no `GROUP` segment in any path or log field.
- **No `--capture-evidence` / investigation-evidence extraction.** `/cc`'s opt-in raw-command-
  extraction feature and its `investigation_evidence` JSONL field are not ported. `run-ccs-
  review.sh` does expose a lower-level `--capture-eventlog <path>` flag (best-effort raw event-
  log dump) — this skill does not use it; it is unused v1 surface, not a hidden replacement for
  `--capture-evidence`.
- **No non-repo-artifact review.** `/cc`'s `CLEAN_REPO_DIR` throwaway-repo mechanism (for
  reviewing pasted analysis/plan text with no real git diff) is not ported. `/ccs` v1 only
  reviews a real repo's diff (`--uncommitted` / `--base <ref>` / `--commit <sha>`). If Phase 0
  below finds nothing concrete to diff, or the material to review isn't a repo diff at all, tell
  the user to use `/cc` instead — do not invent a workaround.

These are deferred, addable-later features per the design doc, not abandoned ideas.

---

## Core Principles — Equal Partnership (non-negotiable)

Claude and Codex are **equal peers**. Neither agent's findings are automatically authoritative.

- Codex reviews Claude's work → Claude **verifies each finding with facts and evidence** before acting.
- If Claude disagrees, Claude **rebuts with reasoning and evidence** — Codex must respond next round.
- A finding is valid only when **both agents agree** based on evidence.
- **Converge by negotiation, not concession.** Never fake agreement; a real surviving disagreement is reported honestly, not smoothed over.
- **Report only a clean result** — or, if the 20-round cap is hit first, report the remaining disagreements honestly.

> Codex is read-only for the whole run (`--sandbox read-only` on the fresh round; a resumed round
> inherits that same sandbox with no flag of its own — `codex exec resume` has none). Claude
> remains the sole editor.

---

## Hard rules

### Language
Everything exchanged with Codex, all internal review/verification notes, and all progress
narration are in **ENGLISH**. Only the **final report to the user (Phase 3) is Korean**.

### `--focus` is required on every call, fresh or resumed
`run-ccs-review.sh` rejects a call with empty/whitespace-only `--focus` with `bad_args`
regardless of whether a scope flag or `--resume` was given — there is no "no diff and no focus"
canned-CLEAN shortcut to fall back on in this wrapper. On a fresh round it frames the diff
(Why/History/Scope, below); on a resumed round it carries only the new rebuttal/follow-up text
— never the diff again, Codex already has it in the thread's own context.

### `--cwd` is required on every call too, including `--resume`
Unlike `--focus`, this is easy to miss: `run-ccs-review.sh` still requires `--cwd` on a resumed
call even though it never re-collects a diff — it uses `--cwd` only to `cd` into the repo before
running `codex exec resume`. Never omit it on a resume dispatch.

---

## `run-ccs-review.sh` — interface reference

Two mutually exclusive top-level modes:

### Mode 1 — a review round (fresh or resumed)

```
run-ccs-review.sh --cwd <dir> {--uncommitted | --base <ref> | --commit <sha>} --focus <text> [--timeout <secs>]
run-ccs-review.sh --cwd <dir> --resume <threadId> --focus <text> [--timeout <secs>]
```

- `--cwd <dir>` — **required**, every call.
- Exactly one of `--uncommitted` / `--base <ref>` / `--commit <sha>` **or** `--resume <threadId>`
  — never both a scope flag and `--resume` together (`bad_args`: "`--resume` cannot be combined
  with `--uncommitted`/`--base`/`--commit`"). A scope flag is only meaningful on a fresh round.
- `--focus <text>` — **required**, every call (see "Hard rules" above).
- `--timeout <secs>` — optional, positive integer, default `1800` (30 min, same default `/cc`'s
  own wrapper uses). This skill does not pass it explicitly unless a round genuinely needs
  longer; the PID-liveness watcher's own wait bound (below) matches whatever value is actually
  used.
- `--capture-eventlog <path>` — optional, exists on this wrapper but **not used by this skill**
  in v1 (see "v1 scope" above).
- A `--base`/`--commit` value starting with `-` is rejected (`bad_args`) as a git-option-
  injection guard; a `--resume` threadId starting with `-` is rejected the same way.

**Success:** `{"ok":true,"threadId":"<uuid>","verdict":{...}}`, optionally with a spliced-in
`"coverage":{"source":{...}}` object — **present only when this round was a fresh `--uncommitted`
round**, absent for `--base`/`--commit` and absent for every `--resume` round (confirmed directly
by reading the wrapper: `SOURCE_COVERAGE_JSON` is only ever populated inside the `--uncommitted`
diff-collection branch, which a `--resume` call and a `--base`/`--commit` call both skip
entirely). This mirrors `/cc`'s own established coverage convention exactly — see "Coverage is a
Round-1-only property" below for what this means for `/ccs`'s multi-round convergence check.
`verdict` matches the shared review-verdict schema (`verdict`/`findings[]`/`summary`/
`dimensions`) — same shape `/cc` already parses, do not re-derive it.

**Failure:** `{"ok":false,"reason":"<reason>","threadId":"<uuid or absent>","detail":"..."}`.
Every distinct `reason` this wrapper can emit, and whether `threadId` is present (capture it
whenever it is — it is what makes cleanup of a partially-started thread possible even after a
failed round):

| `reason` | When | `threadId` present? |
|---|---|---|
| `bad_args` | Malformed/missing/conflicting flags, or a leading-dash scope/resume value | No |
| `git_error` | The `git diff`/`git show` call for a scope flag failed, or the untracked-file collector exited with a non-2 nonzero status | No |
| `incomplete_collection` | The untracked-file collector exited status 2 | No |
| `no_thread_started` | No `thread.started` event within 10s of a fresh dispatch | No |
| `resume_thread_not_found` | No rollout file exists for the given `--resume` threadId (already cleaned up, or never valid) | Yes (the id given) |
| `interrupted` | The wrapper itself received SIGINT/SIGTERM mid-round | Yes, if a thread had already started |
| `timeout` | The round exceeded `--timeout` (default 1800s) | Yes |
| `nonzero_exit` | The underlying `codex exec`/`codex exec resume` process exited nonzero | Yes |
| `missing_task_complete` | No `task_complete` event ever appeared in the rollout | Yes |
| `rollout_not_found` | Could not resolve `~/.codex/sessions/**/rollout-*-<threadId>.jsonl` | Yes |
| `no_final_answer` | No `final_answer` message found in the rollout | Yes |
| `invalid_json` | The final answer wasn't valid JSON despite the schema | Yes |

An `ok:false` round is a **failed round, never a clean sign-off** — see Guards below.

### Mode 2 — cleanup

```
run-ccs-review.sh --cleanup <threadId>
```

Its own tiny mode (must be the very first argument) — deletes the Codex thread
(`codex delete --force -- <threadId>`), never combinable with a review dispatch, so a caller can
never accidentally clean up the very thread it just asked to `--resume`.

- Success: `{"ok":true,"threadId":"<uuid>","deleted":true}`
- Failure: `{"ok":false,"reason":"cleanup_failed","threadId":"<uuid>","detail":"..."}`, or
  `{"ok":false,"reason":"bad_args","detail":"..."}` if no threadId (or a leading-dash one) was
  given.

**This is the ONE deliberate difference from `stream-review`'s caller-owns-cleanup contract.**
`run-stream-review.sh` leaves a thread's cleanup entirely to the caller because a generic caller
might still want to `--resume` it later. `/ccs` owns a thread's entire lifecycle itself — it is
the only thing that ever `--resume`s it — so it calls `--cleanup` on **every** terminal path
(CLEAN, NOT CONVERGED, COULD NOT VERIFY, PARTIAL COVERAGE) automatically, with no separate opt-in
step a human needs to remember. See "Phase 3 — Terminal path" below.

> **Discrepancy note:** this project's `task-2-brief.md` (the brief for the task that built this
> wrapper) referenced an `--output-schema <path>` flag on it. The actual, current
> `run-ccs-review.sh` has no such caller-facing flag — its argument parser only accepts `--cwd`, `--uncommitted`, `--base`,
> `--commit`, `--focus`, `--resume`, `--timeout`, `--capture-eventlog`, and the separate
> `--cleanup` mode. The JSON output schema (`schemas/review-verdict.schema.json`) is applied
> internally and unconditionally to every `codex exec` call the wrapper itself makes — it is not
> a knob this skill or its caller ever sets. Trust the script: do not pass `--output-schema`.

---

## Sentinel-file safe-read idiom (adapted from `/cc`)

`--focus`, `--cwd`, and the resolved plugin install path all get built into a shell command
string from values Claude does not fully control character-by-character (pasted content, a
resolved filesystem path). Interpolating any of them directly into a double-quoted argument is
exploitable — a value containing an embedded `"` followed by shell metacharacters breaks out of
the intended argument and executes as a second statement. `/cc`'s own SKILL.md ("Codex
invocation" section) proves this in detail and fixes it with a file-plus-sentinel idiom; apply
the **exact same idiom** here, unchanged:

- Resolve/compose the value, then write it to a `mktemp`-allocated file with a trailing literal
  `x` sentinel appended directly after it, no newline in between: `{ <producing-command>; printf
  'x'; } > "$FILE"` for a shell-resolved value (using `jq -j`, never `jq -r`, and `printf '%s'
  "$PWD"`, never `$(pwd)`, for the same trailing-newline-loss reasons `/cc` documents), or the
  Write tool for Claude-composed text (`--focus`) — content on disk is exactly `<value>x`.
- Read it back everywhere it's consumed as `VALUE="$(cat "$FILE")"; VALUE="${VALUE%x}"`, never a
  bare `$(cat "$FILE")` inlined directly into a command.

Apply this to exactly three values in this skill: the resolved plugin install path
(`INSTALL_PATH_FILE`), the resolved repo root (`REPO_ROOT_FILE`), and each round's `--focus` text
(`FOCUS_FILE`) — see Phase 0 and Phase 1 below for where each is allocated. None of the three is
ever hand-retyped as a `VAR="<value>"` literal anywhere in this skill.

---

## Phase 0 — Setup

Work out these facts **once**, right now, and remember them as literal strings for the rest of
this run — each later Bash/Monitor call gets a fresh shell, so nothing exported here survives
into a separately-dispatched tool call (Claude Code's own documented behavior: "shell state does
not persist between commands"). Every later reference to `$SESSION_ID`, `$INSTALL_PATH`,
`$REPO_ROOT`, etc. in this skill is illustrative pseudocode for a value Claude already knows from
this step — write the concrete literal text into each actual command constructed later, never
assume a shell variable survived.

1. **Session id:** `SESSION_ID="$(date +%Y-%m-%dT%H%M%S)-$$"` — timestamp plus the invoking
   shell's PID, exactly `/cc`'s own scheme (the PID suffix is required: a bare-second-resolution
   timestamp collides across two invocations started in the same second). Qualifies every
   temp-file path and the review-history log path for the rest of the run.

2. **Resolve this plugin's own install path**, the same way `/cc` resolves
   `codex-direct-review`'s, keyed `codex-stream-review@youzooyou-plugins`:
   ```bash
   INSTALL_PATH_FILE=$(mktemp "/tmp/ccs-${SESSION_ID}-install-path.txt.XXXXXX")
   { jq -j '.plugins["codex-stream-review@youzooyou-plugins"][] | select(.scope=="user") | .installPath' ~/.claude/plugins/installed_plugins.json; printf 'x'; } > "$INSTALL_PATH_FILE"
   INSTALL_PATH="$(cat "$INSTALL_PATH_FILE")"; INSTALL_PATH="${INSTALL_PATH%x}"
   if [ -z "$INSTALL_PATH" ] || [ ! -x "$INSTALL_PATH/scripts/run-ccs-review.sh" ]; then
     echo "codex-stream-review@youzooyou-plugins is not installed, or is missing run-ccs-review.sh (a stale/incomplete install) — run /plugin install codex-stream-review@youzooyou-plugins (or update it), or use /cc instead" >&2
     rm -f "$INSTALL_PATH_FILE"
     exit 1
   fi
   echo "INSTALL_PATH_FILE=$INSTALL_PATH_FILE"
   ```
   **Check both an empty path AND the actual script's presence, not just emptiness** — an empty
   `INSTALL_PATH` means the plugin isn't installed at all, but a real, non-empty path can still be
   a stale or incomplete install (e.g. a cached install from before this plugin shipped
   `run-ccs-review.sh`) that would otherwise pass this check cleanly and fail confusingly much
   later, at the first round's dispatch, with a generic "command not found" instead of a clear,
   actionable message at the one point where the problem is actually diagnosable. If either check
   fails, **stop here** — before any round ever dispatches. Otherwise remember the exact literal
   `INSTALL_PATH_FILE` path (`mktemp`'s random suffix and all) for the rest of the run.

3. **Repo root:**
   ```bash
   REPO_ROOT_FILE=$(mktemp "/tmp/ccs-${SESSION_ID}-repo-root.txt.XXXXXX")
   { printf '%s' "$PWD"; printf 'x'; } > "$REPO_ROOT_FILE"   # or whatever command determined the target repo below
   echo "REPO_ROOT_FILE=$REPO_ROOT_FILE"
   ```
   Session-constant, resolved once, never re-resolved per round.

4. **Determine the ARTIFACT** — same as `/cc`'s own Phase 0:
   - If `$ARGUMENTS` is non-empty: it is the TASK. Perform it end-to-end (Review → Plan →
     Research → Implement → Verify). The result is the ARTIFACT.
   - If empty: the ARTIFACT is the work just completed in **this** session. If none is
     identifiable, fall back to current uncommitted changes in `$REPO_ROOT` (`git status
     --short --untracked-files=all` plus `git diff --no-ext-diff --no-textconv` against the
     unborn-HEAD-safe base — `git rev-parse --verify -q HEAD` then either `HEAD` or `git
     hash-object -t tree /dev/null` — never `git add -N`, which mutates the index).
   - **If still nothing concrete, or the material to review isn't a repo diff at all (a pasted
     plan, generated text, analysis with no git diff to point to): stop and tell the user to use
     `/cc` instead** (see "v1 scope" above — there is no `CLEAN_REPO_DIR` non-repo-artifact path
     in `/ccs` v1). Clean up before stopping:
     `rm -f "<literal REPO_ROOT_FILE>" "<literal INSTALL_PATH_FILE>"`.

---

## Phase 1 — Round dispatch

Every round is single-reviewer — there is no parallel-mode `GROUP` segment anywhere below (see
"v1 scope"). `R` is the current round number (1, 2, 3, …), written literally.

### Step 0 — pre-allocate this round's temp files

```bash
PID_FILE=$(mktemp "/tmp/ccs-${SESSION_ID}-round-<R>.pid.XXXXXX")
OUT_FILE=$(mktemp "/tmp/ccs-${SESSION_ID}-round-<R>-out.json.XXXXXX")
ERR_FILE=$(mktemp "/tmp/ccs-${SESSION_ID}-round-<R>-err.log.XXXXXX")
FOCUS_FILE=$(mktemp "/tmp/ccs-${SESSION_ID}-round-<R>-focus.txt.XXXXXX")
echo "PID_FILE=$PID_FILE"
echo "OUT_FILE=$OUT_FILE"
echo "ERR_FILE=$ERR_FILE"
echo "FOCUS_FILE=$FOCUS_FILE"
```

**Why `ERR_FILE` is separate from `OUT_FILE`, unlike `/cc`'s own watcher (which merges
stdout+stderr into one file).** `run-ccs-review.sh` prints the early `THREAD_ID=<uuid>` signal
on **stderr** the moment a thread starts (or immediately, on a resumed round) — well before the
round's final JSON appears on stdout. `/cc`'s wrapper has no such signal to exploit, so it merges
the two channels; `/ccs` needs the early signal for the tmux pane and for holding onto a
threadId even if the round later fails, so the two streams are kept apart, exactly as
`stream-review`'s own SKILL.md documents ("redirect stdout and stderr to SEPARATE files").

Then, using the Write tool (never a shell redirect — see the sentinel idiom above), write this
round's `--focus` text plus a trailing `x` sentinel into `FOCUS_FILE`:
- **Round 1:** Why (the actual problem this task addresses) / Scope (what to specifically verify
  given what this diff touches) — there is no History yet. Fold in the same `⚠️ SCOPE
  CONSTRAINT` block `/cc` always includes (do not open `node_modules/`/`.pnpm/`/vendor
  directories; limit reads to source dirs and the diff itself) — this is caller-supplied text,
  `run-ccs-review.sh`'s own prompt template does not add it for you.
- **Round 2+:** History (fixes applied and findings rejected last round, built from the review
  history log below, not memory alone) / Scope for this round's rebuttal — **never the diff
  again**. Same `⚠️ SCOPE CONSTRAINT` block, every round.

### Step 1 — dispatch (primary channel)

```bash
PID_FILE="<literal from step 0>"; OUT_FILE="<literal from step 0>"; ERR_FILE="<literal from step 0>"; FOCUS_FILE="<literal from step 0>"
INSTALL_PATH_FILE="<literal from Phase 0>"; REPO_ROOT_FILE="<literal from Phase 0>"
INSTALL_PATH="$(cat "$INSTALL_PATH_FILE")"; INSTALL_PATH="${INSTALL_PATH%x}"
REPO_ROOT="$(cat "$REPO_ROOT_FILE")"; REPO_ROOT="${REPO_ROOT%x}"
FOCUS_TEXT="$(cat "$FOCUS_FILE")"; FOCUS_TEXT="${FOCUS_TEXT%x}"

# Round 1 (fresh — pick the one matching scope flag actually decided in Phase 0):
"$INSTALL_PATH/scripts/run-ccs-review.sh" --cwd "$REPO_ROOT" --uncommitted \
  --focus "$FOCUS_TEXT" \
  > "$OUT_FILE" 2>"$ERR_FILE" &

# Round 2+ (resume — same REPO_ROOT, same INSTALL_PATH; THREAD_ID is round 1's captured id):
# "$INSTALL_PATH/scripts/run-ccs-review.sh" --cwd "$REPO_ROOT" --resume "<literal THREAD_ID>" \
#   --focus "$FOCUS_TEXT" \
#   > "$OUT_FILE" 2>"$ERR_FILE" &

CODEX_BG_PID=$!
CODEX_START_TIME=$(ps -o lstart= -p "$CODEX_BG_PID" 2>/dev/null)
{ echo "$CODEX_BG_PID"; echo "$CODEX_START_TIME"; } > "$PID_FILE"
wait "$CODEX_BG_PID"
cat "$OUT_FILE"
```

Dispatch via Bash with `run_in_background: true` — a round can legitimately take up to the
wrapper's own timeout (1800s default). Never route this through a subagent (including `runner`):
the wrapper emits exactly one clean JSON line, so a relay layer adds no value and risks
paraphrasing it.

### Step 2 — liveness watcher (secondary channel, defense in depth)

Identical to `/cc`'s own PID-plus-start-time watcher, reusing the same `PID_FILE`, dispatched as
an independent `Monitor` call right after step 1:

```bash
PID_FILE="<literal from step 0>"
PID_WAIT_TIMEOUT=1800  # matches --timeout's default
PID_WAIT_START=$(date +%s)
until [ "$(wc -l < "$PID_FILE" 2>/dev/null || echo 0)" -ge 2 ]; do
  [ $(( $(date +%s) - PID_WAIT_START )) -ge "$PID_WAIT_TIMEOUT" ] && { echo "Round <R>: primary dispatch never wrote its PID record"; exit 1; }
  sleep 1
done
PID=$(sed -n '1p' "$PID_FILE"); START_TIME=$(sed -n '2p' "$PID_FILE")
START=$(date +%s)
still_running() { kill -0 "$PID" 2>/dev/null || return 1; [ "$(ps -o lstart= -p "$PID" 2>/dev/null)" = "$START_TIME" ]; }
while still_running; do echo "Round <R>: still running, $(( $(date +%s) - START ))s elapsed"; sleep 180; done
echo "Round <R>: process exited"
```

Checks PID **plus** recorded start time (mitigates PID reuse after the process exits) — a
defense-in-depth secondary signal, not the primary completion mechanism. See `/cc`'s own
"Liveness watcher" section for the full reasoning; nothing about it changes here beyond dropping
the `GROUP` segment.

### Step 3 — early `THREAD_ID` signal (ccs-specific; drives the tmux pane)

**Round 1 only — skip entirely on round 2+.** On a resume round, `THREAD_ID` is already known
(it's the literal value passed to `--resume`), so this poll would be redundant work; same
skip-on-resume logic as step 4's tmux pane below.

A third, independent, bounded poll — this is a genuine "notify me once" case, so use Bash with
`run_in_background: true` and an `until` loop that exits on its own, not `Monitor` (which is for
repeated/indefinite events):

```bash
ERR_FILE="<literal from step 0>"
DEADLINE=$(( $(date +%s) + 30 ))
until grep -q '^THREAD_ID=' "$ERR_FILE" 2>/dev/null; do
  [ "$(date +%s)" -ge "$DEADLINE" ] && { echo "no THREAD_ID signal within 30s — round likely failed before/during dispatch"; exit 1; }
  sleep 0.5
done
grep '^THREAD_ID=' "$ERR_FILE" | head -1
```

30s is generous: the wrapper's own internal "no thread.started" timeout is 10s, and a live,
timestamped test of this exact mechanism (see the design doc) measured a 5.46s real
dispatch→signal gap. This poll is **purely informational** — it exists only to decide whether/
when to open the tmux pane below. If it times out (a genuine `bad_args`/`no_thread_started`
failure, or just an unusually slow start), skip the pane for this round; nothing about the
review's correctness depends on it ever succeeding — the primary channel (step 1) and its
JSON `ok:false` remain the actual source of truth for round failure.

Once this fires, parse `<uuid>` out of the `THREAD_ID=<uuid>` line and remember it as the literal
`THREAD_ID` for the rest of this round (needed for the tmux pane immediately below, for
`--resume` next round, and for `--cleanup` at the terminal path — capture it from here or from
the round's final JSON, whichever arrives; either source is the same value).

### Step 4 — tmux auto-pane (Round 1 only; best-effort, never fatal)

Only on the round that first obtains a `THREAD_ID` for this session (in practice, always round
1 — round 2+ resumes the same thread and therefore the same rollout file, so the pane already
open from round 1 keeps tailing it with no action needed). Track "did I already open a pane this
session" the same way `SESSION_ID` is tracked — a fact Claude itself remembers, not a live shell
variable.

Before ever creating the pane, guard against either value containing anything outside a strict
path-safe charset — `$INSTALL_PATH` and `$THREAD_ID` are interpolated directly into a string
that the *pane's own separate shell* re-parses as its command line, which is a different trust
boundary than the sentinel-file idiom above (that idiom only protects a value passed as one
already-quoted shell argument, not a value re-interpolated into a second string a different
shell re-parses). A quote-only check is not enough here: a value containing `$(...)` or a
backtick needs no quote character to run a command when the pane's shell parses the
double-quoted segment it ends up inside — so the guard denies everything except letters,
digits, and `_./-`, checked *before* the pane exists so a rejected value never leaves an
orphaned blank pane behind:

```bash
PANE_ID=""
case "$INSTALL_PATH$THREAD_ID" in
  *[!A-Za-z0-9_./-]*)
    :  # unsafe to interpolate into the pane's send-keys command; skip the pane this round
       # without ever creating one
    ;;
  *)
    if [ -n "${TMUX:-}" ]; then
      PANE_ID=$(tmux split-window -h -P -F '#{pane_id}' 2>/dev/null)
    fi
    ;;
esac
```

`tmux split-window -h` with **no command argument** spawns the pane's normal interactive shell —
this is the load-bearing detail: a pane whose command argument directly runs a foreground
process (e.g. `tmux split-window -h "codex ..."`) closes the instant that process exits, which is
exactly the real, live-learned lesson this session's own design doc records. Typing a command
into an already-running shell via `send-keys` instead means the shell survives even if the typed
command (or the `tail -F` inside `watch-rollout.sh`) ever exits.

If `PANE_ID` is non-empty, resolve the round's rollout file and start watching it, all inside
that pane's own shell. The rollout file can genuinely not exist on disk yet at the instant this
runs — the `THREAD_ID` stderr signal (Step 3) fires before Codex is guaranteed to have created
the file — so the pane's own command retries the lookup itself for up to ~10s rather than
passing a possibly-empty path straight to `watch-rollout.sh`, which would otherwise exit
immediately on its own required-argument check and never reach its unrelated file-wait loop:

```bash
tmux send-keys -t "$PANE_ID" 'R=""; for _i in $(seq 1 20); do R=$(find "$HOME/.codex/sessions/'"$(date +%Y/%m/%d)"'" -maxdepth 1 -name "rollout-*-'"$THREAD_ID"'.jsonl" 2>/dev/null | head -1); [ -z "$R" ] && R=$(find "$HOME/.codex/sessions" -name "rollout-*-'"$THREAD_ID"'.jsonl" 2>/dev/null | head -1); [ -n "$R" ] && break; sleep 0.5; done; "'"$INSTALL_PATH"'/scripts/watch-rollout.sh" "$R"' Enter
```

This directly interpolates `$THREAD_ID` and `$INSTALL_PATH` rather than going through the
sentinel-file idiom above — deliberately: `THREAD_ID` is a UUID Codex itself generated (not
attacker-influenced) and, per the guard above, neither value reaching this point contains
anything outside the safe charset. `INSTALL_PATH` was already safely resolved through the
sentinel idiom earlier for its own purpose (passing it as one shell argument), and this command
is a best-effort convenience typed into a pane for a human to watch, not an argument to the
review wrapper itself — a malformed or skipped pane command only costs the live view, never the
round's correctness.

`watch-rollout.sh` narrates `investigating: <command>` (from `custom_tool_call` events) and
`round complete` (from `task_complete`) reliably; it may also print `reasoning: ...` lines
depending on the provider/model configuration — don't rely on those appearing.

If `TMUX` is unset, or `split-window`/`send-keys` fail for any reason, proceed without a pane —
narrate progress through ordinary English text updates only, exactly as `/cc` already does with
no pane at all.

---

## Phase 2 — Converge loop (R = 1 … 20)

For each round, after Phase 1 delivers a result:

1. **Parse the wrapper's single-line JSON.** `ok:false` → failed round, not a clean sign-off (see
   Guards). `ok:true` → `verdict.verdict`/`verdict.findings` are this round's Codex output.
2. **Receive Codex's findings — do not blindly accept them.**
3. **Re-verify EACH finding against facts/evidence.** Read the actual file, run the actual
   command, check tests. Treat every finding as *possibly* a false positive, but be equally
   willing to be proven wrong.
   - **VALID** → fix directly (or delegate a substantial/multi-file fix, then verify the diff).
   - **FALSE POSITIVE** → rebut with concrete observed evidence, never without it.
   - **PARTIAL** → fix the valid part, rebut the rest.
4. **Whole-flow re-check (narrow → wide → narrow), for any fix applied this round.** Zoom out to
   the whole affected file/function's control flow, not just the new lines — does the fix
   introduce the same class of problem it just fixed, in a new form; is it consistent with how
   sibling code paths already handle the same case; does a sibling path need the identical fix.
5. **Convergence check** (below).
6. **Narrate progress** — one English line: `Round R/20: Codex N findings → accepted A /
   rebutted B — <clean | continuing>`. Then append this round's line to the review history log
   (below), best-effort. Clean up this round's now-unneeded `.pid`/`-out.json`/`-err.log`/
   `-focus.txt` temp files — nothing needs to read them again once the round is logged.

### Coverage is a Round-1-only property

Since only a fresh `--uncommitted` round ever reports `coverage.source` (see the interface
reference above), and only round 1 is ever a fresh round in `/ccs` (round 2+ is always
`--resume`), the coverage-completeness gate below is a property of **round 1's own log line**,
not "the latest round's," unlike `/cc` (where every round is independently scope-flagged).
Record round 1's `coverage_source` once and carry that determination forward through the rest of
the loop — it is never re-collected on a resumed round.

### Convergence = 100% CLEAN (ALL must hold)
- Codex has no substantiated open findings in its latest review, **AND**
- Claude has no open items (no pending fixes; Codex accepted Claude's rebuttals, or Claude
  accepted Codex's counter), **AND**
- **If round 1's scope was `--uncommitted`:** round 1's `coverage_source.status` — the wrapper's
  own `coverage.source` object verbatim, or the sentinel `{"status":"unknown","omitted":[]}`
  when the wrapper's `ok:true` response omitted `coverage.source` entirely — is explicitly
  `"complete"`, never assumed. `"partial"` (real omitted files) or `"unknown"` fail this
  condition unless every omitted path has since been explicitly reviewed another way or
  explicitly accepted as out-of-scope by the user. For round 1 scoped `--base`/`--commit`, this
  condition is automatically satisfied — those scopes never report coverage at all.
→ Stop the loop, go to Phase 3 as **✅ CLEAN**.

### Guards
- **Never fake-clean.** A genuine, evidence-unresolved disagreement is not convergence.
- **Cap:** R = 20 without convergence → stop, report **⚠️ NOT CONVERGED**, listing every open
  disagreement (finding, Codex's position, Claude's evidence-based counter, why unresolved).
- **Zero progress twice in a row** (same open-disagreement set, no new evidence, no accepted
  rebuttal/counter — check the last two rounds' `claude_verification[].action` in the log rather
  than memory) → stop early, report NOT CONVERGED rather than burning remaining rounds.
- **Empty / failed review ≠ CLEAN.** `ok:false` → retry **once**, reusing the exact same
  dispatch shape as the round that failed:
  - A failed **round 1** (fresh) retries the same scope flag fresh. Several failure reasons
    (`interrupted`, `timeout`, `nonzero_exit`, `missing_task_complete`, `rollout_not_found`,
    `no_final_answer`, `invalid_json` — see the reason table's `threadId` column) fire *after* a
    thread already started, so the failed attempt can leak a real, still-live thread even though
    the retry dispatches fresh and gets a **different** `threadId`. **Append any such leaked
    threadId to `LEAKED_THREAD_IDS`** — a literal list Claude remembers for the rest of the run,
    the same way `THREAD_ID`/`SESSION_ID` are remembered — so Phase 3's terminal path (below) can
    clean it up alongside the run's final thread; it is never cleaned up here, only recorded.
  - A failed **round 2+** (resume) retries the exact same `--resume <threadId> --focus <same
    text>` call — the thread persists across a failed round, so resume is still valid and no
    diff needs re-sending, and no new threadId is ever created (nothing to add to
    `LEAKED_THREAD_IDS`).
  - If the retry still fails, stop and report **⚠️ COULD NOT VERIFY** — never declare CLEAN off a
    missing review. Still run the terminal-path cleanup (below) using whatever `threadId` is
    known, even from a failed response.
- **Partial or unknown source coverage ≠ CLEAN, and is not the same failure as NOT
  CONVERGED/COULD NOT VERIFY.** If round 1's `coverage_source.status` is unresolved `"partial"`
  or `"unknown"` while everything else would otherwise say converged, stop and report
  **⚠️ PARTIAL COVERAGE** instead of CLEAN — list every omitted path and reason (or state
  plainly the wrapper never reported coverage at all, for `"unknown"`). If the R=20 cap is hit
  while a genuine disagreement AND unresolved coverage both remain open, report NOT CONVERGED
  and list the coverage gap alongside the disagreements — the disagreement is the more severe
  condition in that case.

---

## Review history log (JSONL)

Same purpose and mechanism as `/cc`'s own log — Claude is the sole writer/reader, Codex never
sees it — at a plugin-appropriate path instead of `/cc`'s command-local one:

**Location:** `~/.claude/plugins/data/codex-stream-review/ccs-logs/<repo-slug>/<session-id>.jsonl`
- `<repo-slug>`: the target repo's directory basename, lowercased, non-alnum → `-`.
- `<session-id>`: the literal `SESSION_ID` from Phase 0.
- Create owner-only, once per session: `umask 077 && mkdir -p ~/.claude/plugins/data/codex-stream-review/ccs-logs/<repo-slug>`
  — same reasoning `/cc` documents (this log retains full `target.focus` text indefinitely; the
  ambient `umask` on this machine would otherwise leave it group/world-readable). Best-effort
  also retighten any pre-existing directory once per session:
  `chmod -R go-rwx ~/.claude/plugins/data/codex-stream-review/ccs-logs/<repo-slug> 2>/dev/null || true`.

**Line schema (one JSON object per round)** — exactly `/cc`'s own schema shape (`target`,
`codex_review`, `coverage_source`, `claude_verification`, `round_outcome`), minus
`investigation_evidence` and `groups` (v1 has neither capture-evidence nor parallel mode — see
"v1 scope"). No new field is added; `target.scope` simply gains one more legal value (`"resume"`)
to describe what `/ccs` rounds 2+ actually do:

```json
{
  "session_id": "2026-09-03T143000-54321",
  "round": 1,
  "ts": "2026-09-03T14:31:05+09:00",
  "target": {"repo": "<repo root>", "scope": "uncommitted", "focus": "<the --focus text sent this round>"},
  "codex_review": {"ok": true, "verdict": "ISSUES", "findings": [
    {"id": "f1", "file": "...", "line": 42, "severity": "high", "summary": "...", "evidence": "...", "linked_finding_id": null}
  ]},
  "coverage_source": {"status": "complete"},
  "claude_verification": [
    {"finding_id": "f1", "action": "accept|reject_with_rationale|request_rereview|parked", "rationale": "..."}
  ],
  "round_outcome": "continue|converged|not_converged"
}
```

- `target.scope`: `"uncommitted"` / `"base"` / `"commit"` for round 1 (whichever fresh scope flag
  was used); `"resume"` for every round 2+ — no scope flag is ever sent on those, so logging the
  original scope value would misrepresent what actually happened that round.
- `coverage_source`: written only for a round-1 `--uncommitted` scope (per "Coverage is a
  Round-1-only property" above); omitted entirely for round-1 `--base`/`--commit` and for every
  `--resume` round — the wrapper never reports it for those, so no field is invented.
- `finding_id`/`linked_finding_id`/`claude_verification[].action`: identical meaning to `/cc`'s
  own schema — stable `f<n>` IDs incrementing across all rounds, `linked_finding_id` traces a
  disputed finding's multi-round thread, actions are `accept` / `reject_with_rationale` /
  `request_rereview` / `parked`.

**Write:** append via `jq -nc` redirected with `>>`, `umask 077` restated immediately before
every append (a fresh Bash call each time — the earlier `mkdir`'s umask doesn't carry over).
Never overwrite or truncate.

**Read (continuity):** at the start of round R > 1, before building this round's History text,
query the log rather than relying on memory:
```bash
jq -c 'select(.round < 3)' ~/.claude/plugins/data/codex-stream-review/ccs-logs/<repo-slug>/<session-id>.jsonl
```
(substitute the actual current round number by hand, same reason `/cc` does — no live `$R` shell
variable survives into a separately-dispatched call).

**Failure isolation:** a log-write failure never aborts or degrades the round — note it once and
continue.

**Retention: kept indefinitely, no automatic cleanup — this is a completely separate policy from
the automatic Codex-thread cleanup below.** "Automatic cleanup" throughout this skill refers only
to deleting the ephemeral Codex thread and its rollout file under `~/.codex/sessions/` — never to
this JSONL audit log, which persists exactly like `/cc`'s own, for the same durable-record reason.

---

## Phase 3 — Terminal path

On **every** terminal outcome — `✅ CLEAN`, `⚠️ NOT CONVERGED`, `⚠️ COULD NOT VERIFY`, or
`⚠️ PARTIAL COVERAGE` — do all of the following before reporting to the user. None of these is
ever left to the user to remember; this is the deliberate difference from `stream-review`'s own
caller-owns-cleanup contract (see "Mode 2 — cleanup" above).

1. **Clean up the run's final Codex thread**, if one was ever successfully obtained:
   ```bash
   "$INSTALL_PATH/scripts/run-ccs-review.sh" --cleanup "<literal THREAD_ID>"
   ```
   If no `THREAD_ID` was ever obtained at all (every round failed before a thread ever started —
   `bad_args`/`no_thread_started` on every attempt), there is nothing to clean up here; skip
   silently. **A `cleanup_failed` result is surfaced plainly in the final report** (which thread,
   why) — never hidden behind a clean-looking headline result. An undeleted thread means that
   review's full diff/code content is still sitting on disk under `~/.codex/sessions/`.

2. **Clean up every leaked thread in `LEAKED_THREAD_IDS`** (see Guards → "Empty / failed review ≠
   CLEAN" above) — a round-1 retry after a post-`thread.started` failure abandons its first,
   still-real thread the moment it dispatches fresh again, and nothing before this point ever
   deletes it. This list is almost always empty (it only gains an entry when round 1 itself both
   fails post-`thread.started` AND gets retried), but when it isn't, skipping this step is exactly
   how a thread ends up permanently orphaned despite this skill's own cleanup guarantee. For each
   `id` in `LEAKED_THREAD_IDS`:
   ```bash
   "$INSTALL_PATH/scripts/run-ccs-review.sh" --cleanup "<literal leaked threadId>"
   ```
   Same treatment as step 1's `cleanup_failed` handling — surface it plainly in the final report,
   never hide it, and never let a failure here skip cleaning up any other id still in the list.

3. **Close the tmux pane**, if one was opened in Phase 1 step 4:
   ```bash
   tmux kill-pane -t "$PANE_ID" 2>/dev/null || true
   ```
   Best-effort — a failure here is never worth surfacing to the user.

4. **Clean up session-level temp files**, same fast path `/cc` uses:
   ```bash
   rm -f "<literal REPO_ROOT_FILE>" "<literal INSTALL_PATH_FILE>"
   ```

### Final report (Korean — the only Korean output)

Same structure `/cc` uses:
- **작업/대상 요약** — what was done / what the artifact is.
- **최종 결과물** — what changed (files/behavior).
- **리뷰 방식** — 단일 리뷰어 (v1은 병렬 모드 없음), 총 라운드 수, 사용한 스레드 ID.
- **라운드별 수렴 표** — 라운드마다 `[Codex 발견 → 재검증 결과(수용/반박 + 근거) → 조치]`.
- **합의 상태** — 정확히 하나: `✅ CLEAN (N라운드)` / `⚠️ NOT CONVERGED (20라운드 한도 도달, 미해결 K건)` /
  `⚠️ COULD NOT VERIFY (Codex 리뷰 불가)` / `⚠️ PARTIAL COVERAGE (소스 커버리지 미해결)`.
- **소스 커버리지** — round 1이 `--uncommitted`였고 그 `coverage_source.status`가 한 번이라도
  `"partial"`/`"unknown"`이었다면, 결과와 무관하게 반드시 언급 — 어떤 파일이 왜 빠졌는지, 이후
  해결되었는지.
- **스레드 정리 결과** — 최종 스레드의 `--cleanup`이 성공했는지, 그리고 `LEAKED_THREAD_IDS`에 담긴
  스레드(라운드 1이 실패 후 재시도되며 남긴 것)가 있었다면 그것들도 각각 정리에 성공했는지 — 실패한
  threadId가 있다면 어떤 것이 왜 정리되지 않았는지 빠짐없이 언급 (ccs 고유 항목 — `/cc`에는 없는, 매
  실행 종료 시 자동 정리되는 스레드의 존재를 반영).
- **검증됨 / 미검증 / 남은 리스크·가정** — 정직하게, 작성만 하고 실행/검증하지 않은 것을 "완료"로
  포장하지 않는다.

---

## Rules

- Never skip Phase 2.
- Never accept a Codex finding without verifying the evidence yourself; never dismiss one without
  reading the actual file or running the actual command.
- Always include the `⚠️ SCOPE CONSTRAINT` block in every round's `--focus`.
- Every round appends one line to the review history log — best-effort on failure, but skipping
  the write on purpose is not allowed.
- **Always run `--cleanup` on every terminal path** — this is not optional, not user-prompted,
  and not something a future round can undo by mistake (the wrapper's own `--cleanup`/dispatch
  mode split already prevents cleaning up a thread a caller is still trying to `--resume`).
- Do not report to the user until Phase 3.
- For a non-repo-artifact review, or when parallel multi-reviewer coverage is actually needed,
  use `/cc` — do not attempt to bend `/ccs` v1 to cover either case.
