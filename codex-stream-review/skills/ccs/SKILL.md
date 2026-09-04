---
name: ccs
description: Claude executes a task then runs a Claude+Codex adversarial cross-review loop (max 20 rounds) until fact-based consensus — the same outcome as codex-direct-review:ccd, but built on a single resumable Codex thread per reviewer instead of a fresh process per round, so follow-up rounds are cheaper (no diff re-send after round 1) and, in a tmux-capable environment, a live progress pane opens automatically per reviewer. Supports both single-reviewer and parallel multi-reviewer (N concurrent, dimension-focused reviewers, each on its own resumable thread) modes. codex-direct-review:ccd is unaffected and remains the other available option: reach for codex-direct-review:ccd for its further-proven ephemeral-process-per-round mechanism; reach for /ccs for cheap multi-round follow-up, a live view into what Codex is doing, and parallel review on resumable threads.
---

# /ccs — Claude + Codex Cross-Review on a Resumable Thread

**Usage:** `codex-stream-review:ccs <task description>` — this skill is not invocable as a bare
`/ccs` slash command; it is invoked plugin-qualified, like every other plugin-supplied skill. Leave
the task description empty to review the work just done in this session. There is no
`--capture-evidence` prefix in v1 (see "v1 scope" below) — any other free text is the TASK.

Execute the given task, then reach fact-based consensus with Codex — on a resumable Codex thread
per reviewer for the whole run (one thread for a single-reviewer round, one independent thread per
group for a parallel round — see "Determine review mode" below) — before reporting to the user, or
until a hard cap of 20 rounds is hit. The review target is not limited to a diff: it can be a real
repo diff (`--uncommitted`/`--base`/`--commit` — note `--base <ref>` diffs the merge-base of `ref`
and `HEAD` to `HEAD`, a three-dot diff, not every file in the tree; it does NOT by itself provide a
"whole codebase" review) or a non-repo artifact (a design doc, a plan, pasted analysis/review text)
— give Codex the actual
material to review in every case, exactly like `codex-direct-review:ccd` (see Phase 0 step 4 below
for how a non-repo artifact is handled, via the `CLEAN_REPO_DIR` mechanism).

This skill is structurally parallel to `/Users/hmc7279235/Work/Develop/plugins/codex-direct-review/skills/ccd/SKILL.md` (equal-partnership
principles, the Why/History/Scope `--focus` discipline, the sentinel-file safe-read idiom, the
PID-plus-start-time liveness watcher, the JSONL review-history log, the convergence/guard rules,
the Korean-only final report) — read that file for the full reasoning behind any pattern only
summarized here. `/ccs` differs in three deliberate ways: it dispatches through
`run-ccs-review.sh` (a resumable-thread wrapper) instead of `run-codex-review.sh` (an ephemeral
one-shot wrapper), it opens a live tmux pane on the round's rollout file when possible, and it
**always cleans up its Codex thread on every terminal path** — never left to the user, unlike
`stream-review`'s own caller-owns-cleanup contract.

`/ccs` also supports parallel multi-reviewer mode — N concurrent, dimension-focused reviewers
dispatched within the same round (see Phase 1 below for the sizing/mode-selection logic and the
per-group dispatch mechanics). Unlike `ccd`'s ephemeral-process-per-round-per-group model, each
group here keeps its own persistent, resumable Codex thread for the whole run — `GROUP="main"`
(the single-reviewer case) is simply the N=1 special case of the exact same mechanism, not a
separate code path.

**`codex-direct-review:ccd` is unaffected by this skill.** It remains exactly as it is, still backed by
`codex-direct-review`. `/ccs` is a separate, additional option, not a replacement or migration
path.

---

## v1 scope — what this skill does NOT do

- **No `--capture-evidence` / investigation-evidence extraction.** `codex-direct-review:ccd`'s opt-in raw-command-
  extraction feature and its `investigation_evidence` JSONL field are not ported. `run-ccs-
  review.sh` does expose a lower-level `--capture-eventlog <path>` flag (best-effort raw event-
  log dump) — this skill does not use it; it is unused v1 surface, not a hidden replacement for
  `--capture-evidence`.

This is a deferred, addable-later feature per the design doc, not an abandoned idea. **Parallel
multi-reviewer mode IS in scope** (see Phase 1 below): unlike `codex-direct-review:ccd`'s
ephemeral-process-per-round-per-group model, every group here — including the single-reviewer
case, `GROUP="main"` — keeps its own persistent, resumable Codex thread for the whole run,
created once at round 1 and `--resume`d every round after; `GROUP="main"`/N=1 is simply the
special case of the same mechanism, not a separate construct. The review target itself is NOT
scoped down: exactly like `codex-direct-review:ccd`, it can be a real repo diff
(`--uncommitted` / `--base <ref>` / `--commit <sha>` — `--base <ref>` diffs `ref`'s merge-base
with `HEAD` to `HEAD`, a three-dot diff, not a review of every file in the tree) or a non-repo
artifact — pasted analysis, generated text, a plan — via the `CLEAN_REPO_DIR` mechanism ported
from `codex-direct-review:ccd` (see Phase 0 step 4 below).

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

The wrapper itself is unchanged by parallel mode — it has no group/dimension concept of its own
and no file-filter flag. Parallel mode is purely a calling-convention on top of it: this skill
simply invokes it N times concurrently within the same round, once per group, each with its own
`--cwd`/scope-or-`--resume`/`--focus` and its own resulting thread (see Phase 1 below). Everything
in this section applies identically to each of those N invocations.

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
- `--timeout <secs>` — optional, positive integer, default `1800` (30 min, same default `codex-direct-review:ccd`'s
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
entirely). This mirrors `codex-direct-review:ccd`'s own established coverage convention exactly — see "Coverage is a
Round-1-only property" below for what this means for `/ccs`'s multi-round convergence check.
`verdict` matches the shared review-verdict schema (`verdict`/`findings[]`/`summary`/
`dimensions`) — same shape `codex-direct-review:ccd` already parses, do not re-derive it.

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
| `schema_mismatch` | The final answer was valid JSON but failed the semantic verdict rules (CLEAN/findings cross-field consistency, nonblank evidence, complete dimension set) | Yes |

An `ok:false` round is a **failed round, never a clean sign-off** — see Guards below.

### Resume-safety by failure reason (empirically tested, not assumed)

A live crash-simulation test (killing a thread hard mid-flight, then `--resume`ing it) plus 4 real
production `nonzero_exit` occurrences confirmed that resuming a failed round's thread is safe to
attempt and never corrupts state — it just cannot fix a still-ongoing backend outage. The table
below classifies a `reason` only for occurrences where a `threadId` was actually captured; see
Guards below (the "No `threadId` was ever captured..." bullet) for how to tell whether a group
still has a thread to resume when a specific failure carries none.

| `reason` | Resume-safe? (when a `threadId` was actually captured for this occurrence) | Basis |
|---|---|---|
| `bad_args`, `git_error`, `incomplete_collection`, `no_thread_started` | N/A — never carries a `threadId` at all, nothing to resume | Table above: `threadId` never present |
| `resume_thread_not_found`, `rollout_not_found` | **No** — the thread/rollout itself is confirmed or likely gone; resuming the same id will fail the same way again | The failure IS the absence of the very artifact `--resume` needs |
| `interrupted`, `timeout`, `nonzero_exit`, `missing_task_complete`, `no_final_answer`, `invalid_json`, `schema_mismatch` | **Yes** — the underlying Codex thread's own conversational state survives; only THIS wrapper invocation failed to extract a valid final answer from it | `nonzero_exit` empirically confirmed live (crash simulation + 4 real production occurrences, see above); the other six reasons in this row share the same property (a thread that genuinely started and has an intact rollout, or exited zero but the wrapper couldn't parse a valid final answer from it) and are inferred safe by the identical reasoning, not separately live-tested one by one |

**What this changes for retry logic (see Guards below):** a failure in the "Yes" row is worth a
bounded `--resume` retry with a short backoff BEFORE falling back to a fresh restart (round 1) or
declaring that group `⚠️ COULD NOT VERIFY` (any round) — resuming costs nothing extra in
correctness risk, and recovers automatically once a transient condition (a backend blip, a
one-off process hiccup) has passed, without losing the thread's already-established context. A
failure in the "No" row gets no such retry — attempting `--resume` on a thread reason already
known to be terminal for that specific thread only wastes a `--timeout`-length wait for a result
already known in advance.

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

## Sentinel-file safe-read idiom (adapted from `codex-direct-review:ccd`)

`--focus`, `--cwd`, and the resolved plugin install path all get built into a shell command
string from values Claude does not fully control character-by-character (pasted content, a
resolved filesystem path). Interpolating any of them directly into a double-quoted argument is
exploitable — a value containing an embedded `"` followed by shell metacharacters breaks out of
the intended argument and executes as a second statement. The fix is a file-plus-sentinel idiom
(shared with `codex-direct-review:ccd`); apply the **exact same idiom** here, unchanged:

- Resolve/compose the value, then write it to a `mktemp`-allocated file with a trailing literal
  `x` sentinel appended directly after it, no newline in between: `{ <producing-command>; printf
  'x'; } > "$FILE"` for a shell-resolved value (using `jq -j`, never `jq -r`, and `printf '%s'
  "$PWD"`, never `$(pwd)`, for the same trailing-newline-loss reasons `codex-direct-review:ccd` documents), or the
  Write tool for Claude-composed text (`--focus`) — content on disk is exactly `<value>x`.
- Read it back everywhere it's consumed as `VALUE="$(cat "$FILE")"; VALUE="${VALUE%x}"`, never a
  bare `$(cat "$FILE")` inlined directly into a command.

Apply this to exactly three values in this skill: the resolved plugin install path
(`INSTALL_PATH_FILE`), the resolved repo root (`REPO_ROOT_FILE`), and each round's `--focus` text
(`FOCUS_FILE`) — see Phase 0 and Phase 1 below for where each is allocated. `INSTALL_PATH_FILE`/
`REPO_ROOT_FILE` are session-scoped (one each, for the whole run); `FOCUS_FILE` is scoped per
`(round, GROUP)` — a parallel round allocates one `FOCUS_FILE` per dispatched group, each holding
that group's own distinct `--focus` text (see Phase 1 Step 0 below). None of the three is ever
hand-retyped as a `VAR="<value>"` literal anywhere in this skill.

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
   shell's PID, exactly `codex-direct-review:ccd`'s own scheme (the PID suffix is required: a bare-second-resolution
   timestamp collides across two invocations started in the same second). Qualifies every
   temp-file path and the review-history log path for the rest of the run.

2. **Resolve this plugin's own install path**, the same way `codex-direct-review:ccd` resolves
   `codex-direct-review`'s, keyed `codex-stream-review@youzooyou-plugins`:
   ```bash
   INSTALL_PATH_FILE=$(mktemp "/tmp/ccs-${SESSION_ID}-install-path.txt.XXXXXX")
   { jq -j '.plugins["codex-stream-review@youzooyou-plugins"][] | select(.scope=="user") | .installPath' ~/.claude/plugins/installed_plugins.json; printf 'x'; } > "$INSTALL_PATH_FILE"
   INSTALL_PATH="$(cat "$INSTALL_PATH_FILE")"; INSTALL_PATH="${INSTALL_PATH%x}"
   if [ -z "$INSTALL_PATH" ] || [ ! -x "$INSTALL_PATH/scripts/run-ccs-review.sh" ]; then
     echo "codex-stream-review@youzooyou-plugins is not installed, or is missing run-ccs-review.sh (a stale/incomplete install) — run /plugin install codex-stream-review@youzooyou-plugins (or update it), or use codex-direct-review:ccd instead" >&2
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

4. **Determine the ARTIFACT** — same as `codex-direct-review:ccd`'s own Phase 0:
   - If `$ARGUMENTS` is non-empty: it is the TASK. Perform it end-to-end (Review → Plan →
     Research → Implement → Verify). The result is the ARTIFACT.
   - If empty: the ARTIFACT is the work just completed in **this** session. If none is
     identifiable, fall back to current uncommitted changes in `$REPO_ROOT` — anchored and
     sanitized exactly like every other git call in this file (see Phase 1's "Determine review
     mode" below for the full reasoning; this is the earliest git-touching step in the whole run,
     so it needs the identical protection, not a lighter version of it, applied here first):
     ```bash
     REPO_ROOT_FILE="<literal REPO_ROOT_FILE path resolved in Phase 0 step 3 above>"
     REPO_ROOT="$(cat "$REPO_ROOT_FILE")"; REPO_ROOT="${REPO_ROOT%x}"
     for _v in $(git rev-parse --local-env-vars 2>/dev/null || printf '%s\n' GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_CONFIG GIT_CONFIG_PARAMETERS GIT_CONFIG_COUNT GIT_OBJECT_DIRECTORY GIT_DIR GIT_WORK_TREE GIT_IMPLICIT_WORK_TREE GIT_GRAFT_FILE GIT_INDEX_FILE GIT_NO_REPLACE_OBJECTS GIT_REPLACE_REF_BASE GIT_PREFIX GIT_SHALLOW_FILE GIT_COMMON_DIR) GIT_CONFIG_GLOBAL GIT_CONFIG_SYSTEM GIT_TEMPLATE_DIR; do
       unset "$_v"
     done
     git -C "$REPO_ROOT" status --short --untracked-files=all
     if git -C "$REPO_ROOT" rev-parse --verify -q HEAD >/dev/null 2>&1; then DIFF_BASE="HEAD"; else DIFF_BASE="$(git -C "$REPO_ROOT" hash-object -t tree /dev/null)"; fi
     git -C "$REPO_ROOT" diff --no-ext-diff --no-textconv "$DIFF_BASE"
     ```
     Never `git add -N`, which mutates the index. Confirmed the anchor/sanitize step is genuinely
     needed even this early: `env GIT_DIR="<real-repo>/.git" GIT_WORK_TREE="<real-repo>" bash -c
     'cd /tmp; git status --short'` reports the REAL repository's changes despite running from an
     unrelated directory — an unsanitized artifact-detection step could therefore review, or
     silently conclude there is nothing to review in, the wrong repository entirely, before Phase 1
     or any later protection ever runs.
   - **If the material to review isn't a repo diff at all, but there IS real content to review
     (a pasted plan, generated text, analysis text that actually exists — just with no git diff to
     point to): this is a genuine non-repo-artifact review** — ported from `codex-direct-review:ccd`'s
     own `CLEAN_REPO_DIR` mechanism (full operational detail below).
   - **If there is still nothing concrete at all** — no task, no identifiable prior-session work,
     no uncommitted changes, AND no other real content to paste as a non-repo artifact either —
     **do NOT create `CLEAN_REPO_DIR` and do NOT dispatch a round with nothing to review.** Clean
     up and stop instead, exactly like `codex-direct-review:ccd`'s own no-artifact path: run
     `rm -f "<literal REPO_ROOT_FILE>" "<literal INSTALL_PATH_FILE>"`, then ask the user what to
     review. `CLEAN_REPO_DIR` exists to isolate a review of REAL pasted content from an unrelated
     dirty working tree — it is never a substitute for having no content at all; dispatching an
     empty `CLEAN_REPO_DIR` round with no actual material pasted into `--focus` would silently
     review nothing while looking like a real review.

     **Why a non-repo-artifact round must NOT dispatch against `$REPO_ROOT`.** Dispatching
     `--uncommitted --cwd "$REPO_ROOT"` for a non-repo artifact points the wrapper at the user's
     real working tree — if that tree has ANY unrelated uncommitted changes, the wrapper reviews
     the ACTUAL DIFF whenever it is non-empty, using `--focus` only as context for it; it does
     NOT fall back to a focus-only review unless the diff is genuinely empty. So an artifact-only
     review dispatched against `$REPO_ROOT` would silently ALSO review those unrelated changes,
     contaminating findings and coverage with material the user never asked to review.

     **The fix:** the first time this session determines a round is a genuine non-repo-artifact
     review, create a throwaway clean git repo once and reuse it for every round of that same
     session — never recreate it per round:
     ```bash
     FAKE_GIT_HOME=$(mktemp -d "/tmp/ccs-${SESSION_ID}-fake-git-home.XXXXXX")
     CLEAN_REPO_DIR=$(mktemp -d "/tmp/ccs-${SESSION_ID}-artifact-repo.XXXXXX")
     env -i "PATH=$PATH" "HOME=$FAKE_GIT_HOME" "GIT_CONFIG_NOSYSTEM=1" \
       git -C "$CLEAN_REPO_DIR" init -q
     echo "CLEAN_REPO_DIR=$CLEAN_REPO_DIR"
     echo "FAKE_GIT_HOME=$FAKE_GIT_HOME"
     ```
     **This is an ALLOWLIST, not a denylist — deliberately: a denylist enumeration approach was
     tried here first and repeatedly bypassed.** `git`'s own repository/worktree discovery honors
     several environment variables OVER `-C`/`cd` (confirmed directly), and each successive
     hand-picked-then-dynamically-queried unset list was defeated by another variable or by a
     bootstrap failure in the query itself — a denylist cannot converge on "every variable,
     including ones that can break the very discovery mechanism used to build the list." `env -i`
     sidesteps this entirely by clearing the ENTIRE environment unconditionally and re-admitting
     only `PATH` (to find the `git` binary at all), a dedicated `FAKE_GIT_HOME` (so no real or
     attacker-controlled `HOME` can supply a `.gitconfig`), and `GIT_CONFIG_NOSYSTEM=1` (so
     `/etc/gitconfig` is never read) — the identical, already-battle-tested pattern this codebase
     already uses in `codex-direct-review/eval/run_recall_eval.sh`'s own "Isolation snapshot"
     section, copied verbatim here rather than reinvented.

     `FAKE_GIT_HOME` is session-scoped exactly like `CLEAN_REPO_DIR` — allocated once, lazily, the
     first time this session needs it, remembered as an exact literal for the rest of the run, and
     cleaned up in Phase 3 alongside `CLEAN_REPO_DIR` (`rm -rf`, not just `CLEAN_REPO_DIR`'s own
     cleanup — see Phase 3 below). It must be a genuinely SEPARATE directory from `CLEAN_REPO_DIR`
     itself (never reuse one for the other) — `HOME` and the git worktree being initialized are
     different concerns, and collapsing them risks `git init` writing `.gitconfig`-adjacent state
     into the same directory whose content is supposed to be exactly what `CLEAN_REPO_DIR` isolates.

     **Two separate isolation mechanisms exist for two separate call sites — keep them distinct.**
     The allowlist above protects Claude's own pre-flight `git init` call for `CLEAN_REPO_DIR`.
     Every round's actual review dispatch (Phase 1 Step 1 below) invokes `run-ccs-review.sh`, a
     different call site with its own, separate isolation: the wrapper sources
     `scripts/lib/git-safe.sh` and routes all of its internal git calls (diff/show/rev-parse/
     hash-object) through its `git_safe()` helper — a pre-resolved, absolute `git` binary run under
     `env -i` with a fixed `PATH`, an isolated `HOME`, `GIT_CONFIG_NOSYSTEM=1`, `-C "$CWD"` (never a
     bare `cd`), and `-c core.fsmonitor=` to close the repo-local-config execution gap an
     environment-only allowlist can't reach on its own. See `scripts/lib/git-safe.sh` for the full
     mechanism and rationale — the two-front gap this paragraph used to describe (no wrapper-side
     isolation, plus an uncovered `core.fsmonitor` execution path) is closed; nothing further is
     needed at the SKILL.md layer for this call site.

     That's otherwise the whole setup — no seed file, no `git add`, no `git commit`. `CLEAN_REPO_DIR` is
     left exactly as `git init -q` leaves it: an unborn-HEAD repository with zero commits and
     nothing ever staged. No seed commit is needed to make `--uncommitted` resolve to an empty
     diff there — an earlier revision of this fix (in `codex-direct-review:ccd`) seeded a placeholder commit,
     reasoning `--uncommitted` needed a committed `HEAD` to diff against safely; that reasoning
     was wrong (a freshly-`git init`'d repo's unborn HEAD already makes `--uncommitted` resolve
     to an empty diff against git's own empty-tree object — this project's own unborn-HEAD
     handling, `git rev-parse --verify -q HEAD` then either `HEAD` or `git hash-object -t tree
     /dev/null`, already covers it), and the seed commit was also unsafe: its exit status was
     never checked, so a globally-configured `pre-commit`/`commit-msg` hook could reject it and
     leave the placeholder file STAGED but uncommitted — `--uncommitted` against this "clean"
     repo would then show a non-empty diff (the staged placeholder itself), silently defeating
     the exact "guaranteed empty diff" property this mechanism exists to provide. Removing the
     seed commit removes this failure mode entirely: there is no `git commit` call left that
     could fail, and no placeholder file left to go stray. Like `PID_FILE`/`OUT_FILE`/`FOCUS_FILE`
     (see Phase 1 step 0 below), `CLEAN_REPO_DIR` is `mktemp -d`'s own output — a path Claude
     fully controls the template of, guaranteed free of shell metacharacters — so it is simply
     printed and remembered as an exact literal string for the rest of the session, with no
     file-plus-sentinel indirection needed (unlike `REPO_ROOT_FILE`/`INSTALL_PATH_FILE`, which
     hold externally-resolved values Claude does not fully control character-by-character).

     **A non-repo-artifact round is always single-group `main`, never parallel — full stop.**
     Phase 1's sizing/mode-selection logic (below) measures review scope by counting files in a
     real diff; run against a freshly-`git init`'d, zero-file `CLEAN_REPO_DIR` it would trivially
     return `0` and there is nothing to partition by file count in the first place, so the
     parallel-mode machinery simply does not apply to this case — skip it entirely and dispatch
     exactly one group (`GROUP="main"`) against `CLEAN_REPO_DIR`, same as `codex-direct-review:ccd`'s
     own Phase 1 handles this identical case.

     Dispatch every artifact-only round's wrapper call with `--cwd "<the exact literal
     CLEAN_REPO_DIR path>" --uncommitted --focus "$FOCUS_TEXT"` in place of `--cwd "$REPO_ROOT"`
     — see Phase 1 Step 1 below for exactly where this substitution applies. **A non-repo-
     artifact round always uses `--uncommitted` against `CLEAN_REPO_DIR`, never `--base`/
     `--commit`** — there is no commit in `CLEAN_REPO_DIR` to diff against, and round 2+ still
     uses `--resume` exactly as normal (the resumed thread already has the pasted artifact
     content in its own context, same as any other round 2+).

     **Cleanup:** `CLEAN_REPO_DIR` (when created this session) is removed in Phase 3 alongside
     `REPO_ROOT_FILE`/`INSTALL_PATH_FILE` — see Phase 3 below. It is created lazily (only if this
     session ever actually needs it, i.e. only in the genuine-non-repo-artifact branch above, never
     in the still-nothing-concrete-at-all branch), so Phase 3's cleanup only runs when one was
     actually allocated. (The still-nothing-concrete-at-all early exit's own `rm -f` for
     `REPO_ROOT_FILE`/`INSTALL_PATH_FILE` is already covered in that bullet above — nothing further
     to clean up there, since `CLEAN_REPO_DIR` is never allocated on that path.)

---

## Phase 1 — Round dispatch

This phase covers both the single-reviewer case (`GROUP="main"`, N=1) and parallel multi-reviewer
mode (`GROUP` = `g1`/`g2`/…, N>1) with one code path — they differ only in how many groups are
dispatched concurrently this round and each group's own `--focus` text. `R` is the current round
number (1, 2, 3, …), written literally.

### Determine review mode (parallel vs single) — decided once, before round 1

**Non-repo artifact round? Skip this entirely — always single-group `main`, never parallel.** See
Phase 0 step 4 above for why: there is no diff to size and nothing to partition by file count
against a freshly-`git init`'d, zero-file `CLEAN_REPO_DIR`.

**Genuine repo/code-diff round — before round 1 ever dispatches, assess the review scope**
(ported from `codex-direct-review:ccd`'s own "Phase 1 — Determine Review Mode" — the sizing
heuristic is identical since neither wrapper has a file-filter flag):

```bash
REPO_ROOT_FILE="<literal REPO_ROOT_FILE path resolved once in Phase 0>"
REPO_ROOT="$(cat "$REPO_ROOT_FILE")"; REPO_ROOT="${REPO_ROOT%x}"
for _v in $(git rev-parse --local-env-vars 2>/dev/null || printf '%s\n' GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_CONFIG GIT_CONFIG_PARAMETERS GIT_CONFIG_COUNT GIT_OBJECT_DIRECTORY GIT_DIR GIT_WORK_TREE GIT_IMPLICIT_WORK_TREE GIT_GRAFT_FILE GIT_INDEX_FILE GIT_NO_REPLACE_OBJECTS GIT_REPLACE_REF_BASE GIT_PREFIX GIT_SHALLOW_FILE GIT_COMMON_DIR) GIT_CONFIG_GLOBAL GIT_CONFIG_SYSTEM GIT_TEMPLATE_DIR; do
  unset "$_v"
done
if git -C "$REPO_ROOT" rev-parse --verify -q HEAD >/dev/null 2>&1; then DIFF_BASE="HEAD"; else DIFF_BASE="$(git -C "$REPO_ROOT" hash-object -t tree /dev/null)"; fi
{ git -C "$REPO_ROOT" diff --name-only "$DIFF_BASE"; git -C "$REPO_ROOT" ls-files --others --exclude-standard; } | sort -u | wc -l
```

**Always anchor with `git -C "$REPO_ROOT"` AND sanitize the git environment first — `-C` alone is
not a repository-isolation boundary, confirmed directly (see Phase 0 step 4's own reproduction of
the identical class of bypass).** This sizing step is its own separately-dispatched call — the
ambient directory it happens to run in is not guaranteed to be `$REPO_ROOT` (Phase 0 may have
resolved a different target root than wherever this call's shell starts), and inherited
`GIT_DIR`/`GIT_WORK_TREE` (or any other variable `git rev-parse --local-env-vars` enumerates)
override `-C` regardless — so both the explicit `-C "$REPO_ROOT"` AND the sanitization loop are
required together, never `-C` alone. **The `|| printf '%s\n' ...` fallback inside the SAME command
substitution is itself load-bearing, not decorative — and its exact shape matters, not just its
presence.** The bootstrap `git rev-parse --local-env-vars` call can be broken by an inherited
`GIT_CONFIG_GLOBAL` pointing at an invalid file (confirmed: exits with `fatal: bad config
line...`), which would otherwise make the command substitution return empty and silently skip
sanitizing anything at all — the literal fallback list (captured from an actual healthy run of the
same command) is what still gets unset when the dynamic query itself is the thing being attacked.
**The fallback must stay INSIDE the same command substitution as the primary query — never
resolved into a separate named variable first and iterated over afterward as a plain variable
reference.** An earlier revision of this fix did exactly that two-step split, and it broke
silently under `zsh` specifically: this project's own harness executes shell tool calls via
`/bin/zsh` (not bash, despite being called a "Bash" tool — confirmed directly, `ps -p $$ -o comm=`
inside a tool call prints `zsh`), and zsh does NOT word-split a bare unquoted variable reference by
default the way bash does — iterating a multi-word value stored in a plain variable treats the
whole thing as ONE token in zsh, not many — even though zsh DOES word-split a direct, unquoted
command substitution the same way bash does (confirmed both behaviors directly, side by side, in
the same shell). Keeping the whole query-plus-fallback expression inside one command substitution
sidesteps the difference entirely, since the iteration then only ever sees a genuine command
substitution, never an intermediate plain variable — this is why every sanitization loop in this
file uses that exact shape and none stores
the list into a named variable first. The actual round-1 dispatch immediately below
rehydrates and passes `--cwd "$REPO_ROOT"` explicitly, so sizing must resolve the identical root or
it can silently size a different repository than the one actually reviewed, picking the wrong
single-vs-parallel mode for the real target — and, in the worst case, disclose a different
repository's file list to whatever narrates this round's sizing decision.

This counts both tracked-modified files (`git diff --name-only "$DIFF_BASE"`) and untracked files
(`git ls-files --others --exclude-standard`), deduplicated — a `git diff --name-only HEAD | wc -l`-
only count would miss untracked files entirely, undercounting the real review scope (e.g. a repo
with many new untracked files but no tracked-modified ones would wrongly size as "0 files /
small"). This matches Phase 0's own fallback artifact-collection rule and `run-ccs-review.sh`'s
actual `--uncommitted` behavior, both of which already include untracked files. The `DIFF_BASE`
guard handles a brand-new repo with an unborn `HEAD` the same way Phase 0's own fallback does.

**This sizing command illustrates the `--uncommitted` case specifically — for `--base`/`--commit`,
mirror the wrapper's OWN collection command exactly, never a plausible-looking approximation.**
Confirmed directly from `run-ccs-review.sh`'s source: `--base <ref>` collects
`git diff --no-ext-diff --no-textconv "${ref}...HEAD"` (a three-dot merge-base diff, NOT
`git diff "$ref"`, which is a completely different two-dot ref-vs-working-tree diff — the two
forms can report entirely different file sets, including picking up unrelated dirty-working-tree
noise the wrapper's own three-dot form never sees); `--commit <sha>` diffs against the commit's
first parent only when it has 2+ parents (a merge — `git diff "${sha}^1" "$sha"`), or shows the
commit's own patch otherwise (`git show "$sha"`, equivalent to a one-parent diff). Untracked files
are never part of either scope, so the `git ls-files --others` half never applies to them. Size
each scope with the matching command:
```bash
REPO_ROOT_FILE="<literal REPO_ROOT_FILE path resolved once in Phase 0>"
REPO_ROOT="$(cat "$REPO_ROOT_FILE")"; REPO_ROOT="${REPO_ROOT%x}"
for _v in $(git rev-parse --local-env-vars 2>/dev/null || printf '%s\n' GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_CONFIG GIT_CONFIG_PARAMETERS GIT_CONFIG_COUNT GIT_OBJECT_DIRECTORY GIT_DIR GIT_WORK_TREE GIT_IMPLICIT_WORK_TREE GIT_GRAFT_FILE GIT_INDEX_FILE GIT_NO_REPLACE_OBJECTS GIT_REPLACE_REF_BASE GIT_PREFIX GIT_SHALLOW_FILE GIT_COMMON_DIR) GIT_CONFIG_GLOBAL GIT_CONFIG_SYSTEM GIT_TEMPLATE_DIR; do
  unset "$_v"
done

# --base <ref>:
git -C "$REPO_ROOT" diff --no-ext-diff --no-textconv --name-only "<ref>...HEAD" | wc -l

# --commit <sha>: mirror the wrapper's own merge-vs-non-merge branch, never just one or the other
PARENT_COUNT="$(git -C "$REPO_ROOT" show -s --format=%P --no-ext-diff --no-textconv "<sha>" 2>/dev/null | wc -w | tr -d ' ')"
if [ "$PARENT_COUNT" -ge 2 ]; then
  git -C "$REPO_ROOT" diff --no-ext-diff --no-textconv --name-only "<sha>^1" "<sha>" | wc -l
else
  git -C "$REPO_ROOT" show --no-ext-diff --no-textconv --name-only --format= "<sha>" | wc -l
fi
```
Same `-C "$REPO_ROOT"` anchoring AND sanitization loop as the `--uncommitted` sizing command above, for the identical
reason — never a bare `git` call in these either.
Sizing must reflect whatever scope was actually selected, using the wrapper's own exact collection
logic for that scope — never silently default to counting the uncommitted working-tree diff (or
any other approximation) for a review that was never scoped to it.

**What "parallel mode" actually is — read this before the table below.** `run-ccs-review.sh`
accepts only `--uncommitted`/`--base`/`--commit` as review-scope selectors — there is no
`--paths`/file-filter flag (confirmed directly from the wrapper's arg parser: an unrecognized
flag falls through to `{"ok":false,"reason":"bad_args","detail":"unknown argument: ..."}`), and
`--uncommitted`'s collector always reviews the ENTIRE working-tree diff plus all untracked files,
every time, no matter what `--focus` text accompanies it. So every parallel group dispatched this
way receives the IDENTICAL full diff — the groups differ ONLY in their `--focus` review-angle
prompt, never in the actual material reviewed. Parallel mode is therefore multiple concurrent
reviewers each given the SAME full diff but a DIFFERENT dimensional focus (e.g. one group's
`--focus` emphasizes correctness, another's emphasizes security, a third's emphasizes
performance/reuse) — genuinely useful for broader, more attentive coverage of a large or
many-concerned diff via diverse reviewer attention, and for getting several review angles back
within one wall-clock window via concurrent dispatch. **It is NOT a way to shrink any single
call's context size or avoid a timeout risk from sheer diff size** — every group's Codex process
still has to read the same full diff regardless of how many groups are running. A genuinely
oversized diff still needs a narrower `--focus` in the sense of a narrower TOPICAL concern, or
manual review — not more parallel dispatches of the same full material.

| Scope | Strategy |
|-------|----------|
| Small (< 20 files, single concern) | **Single reviewer** (`GROUP="main"`) — standard flow |
| Medium (20–50 files, or multiple concerns) | **2–3 parallel groups** — same full diff/scope, one review dimension/concern each |
| Large (> 50 files, or large skill/doc files, or broad audit) | **3+ parallel groups** — same full diff/scope, one focused review dimension/concern each |

**When to use multiple reviewers (flexible judgment) — grouped BY REVIEW DIMENSION/CONCERN, since
that is the only thing a group's `--focus` can actually vary:**
- The task spans multiple unrelated concerns worth distinct reviewer attention (e.g., path
  correctness + workflow quality + consistency + security)
- A large or many-concerned diff benefits from several reviewers' independent, differently-focused
  passes, even though each one reads everything
- Wanting several review angles back within the same wall-clock window (concurrent dispatch, not
  sequential rounds)

Do not reach for parallel mode to cope with diff size or context exhaustion — every group still
reads the identical full diff (see above), so a single reviewer's exhaustion on it recurs in every
parallel group just the same.

**How to split:** group BY REVIEW DIMENSION/CONCERN — one group's `--focus` emphasizes
correctness, another's security, another's performance/reuse, another's path correctness or
workflow consistency for a doc/skill review, etc. (every group still calls `run-ccs-review.sh` with
the identical scope flag, differing only in `--focus` text — see above).

**This decision is made once, before round 1, and holds for the whole run.** Convergence in this
skill is round-level and all-groups-together (see "Convergence = 100% CLEAN" below): every group
dispatched at round 1 keeps being resumed at every subsequent round — with its own lightweight
"nothing new from your dimension, here's what changed elsewhere" `--focus` when it has nothing new
to raise — until the whole round converges together. A group is never added or dropped mid-run,
and never exits the loop on its own separate cadence.

### Step 0 — pre-allocate this round's temp files

`GROUP` is `main` for a single-reviewer round, or that group's short slug (`g1`, `g2`, …) in
parallel mode — fixed per concurrently-dispatched group this round, exactly `codex-direct-review:ccd`'s own
convention (see its "Liveness watcher" step 0). Run this block once per group (once, for
`GROUP="main"`, in the common single-reviewer case):

```bash
GROUP="main"   # or e.g. "g1" — fixed per concurrently-dispatched group this round
PID_FILE=$(mktemp   "/tmp/ccs-${SESSION_ID}-round-<R>-${GROUP}.pid.XXXXXX")
OUT_FILE=$(mktemp   "/tmp/ccs-${SESSION_ID}-round-<R>-${GROUP}-out.json.XXXXXX")
ERR_FILE=$(mktemp   "/tmp/ccs-${SESSION_ID}-round-<R>-${GROUP}-err.log.XXXXXX")
FOCUS_FILE=$(mktemp "/tmp/ccs-${SESSION_ID}-round-<R>-${GROUP}-focus.txt.XXXXXX")
echo "PID_FILE=$PID_FILE"
echo "OUT_FILE=$OUT_FILE"
echo "ERR_FILE=$ERR_FILE"
echo "FOCUS_FILE=$FOCUS_FILE"
```

`GROUP` is baked into the `mktemp` *template* (not just the random suffix) — the
session+round+group triple prevents cross-session/cross-group confusion; `mktemp`'s own suffix
prevents same-round-same-group path guessing. Applies identically to fresh (round 1) and resumed
(round 2+) dispatch — only the wrapper flags at Step 1 differ. This is a cosmetic behavior change
to the single-reviewer path too (`main` now appears in every temp-file path where it didn't
before) — harmless, since these are ephemeral per-run files cleaned up at the end of each round
(Phase 2 step 6) regardless of naming.

**Why `ERR_FILE` is separate from `OUT_FILE`, unlike `codex-direct-review:ccd`'s own watcher (which merges
stdout+stderr into one file).** `run-ccs-review.sh` prints the early `THREAD_ID=<uuid>` signal
on **stderr** the moment a thread starts (or immediately, on a resumed round) — well before the
round's final JSON appears on stdout. `codex-direct-review:ccd`'s wrapper has no such signal to exploit, so it merges
the two channels; `/ccs` needs the early signal for the tmux pane and for holding onto a
threadId even if the round later fails, so the two streams are kept apart, exactly as
`stream-review`'s own SKILL.md documents ("redirect stdout and stderr to SEPARATE files"). This
reasoning applies identically per group — each dispatched group has its own `OUT_FILE`/`ERR_FILE`
pair (Step 0 above), so each group's early `THREAD_ID` signal and final JSON are separated from
every other group's, never just from each other within one group's own pair.

Then, using the Write tool (never a shell redirect — see the sentinel idiom above), write this
round's `--focus` text plus a trailing `x` sentinel into that group's own `FOCUS_FILE`:
- **Round 1:** Why (the actual problem this task addresses) / Scope (what to specifically verify
  given what this diff touches) — there is no History yet. Fold in the same `⚠️ SCOPE
  CONSTRAINT` block `codex-direct-review:ccd` always includes (do not open `node_modules/`/`.pnpm/`/vendor
  directories; limit reads to source dirs and the diff itself) — this is caller-supplied text,
  `run-ccs-review.sh`'s own prompt template does not add it for you. **State the collaboration
  frame in this same Round-1 `--focus` text too**, mirroring `codex-direct-review:ccd`'s own requirement: Claude
  and Codex are equal peers, findings must be evidence-based (file:line + why), and the goal is
  100% clean mutual agreement.
  - **Parallel mode (more than one group this round):** every group's Round-1 `--focus` shares the
    same Why and the same `⚠️ SCOPE CONSTRAINT`/collaboration-frame text, but each group's Scope
    additionally states its own review dimension/concern (e.g. one group's Scope emphasizes
    correctness, another's security, another's performance/reuse) — this dimension text is the
    ONLY thing that varies between groups' Round-1 `--focus`, since every group reviews the
    IDENTICAL full diff (see "Determine review mode" above).
  - **Non-repo artifact round — the Round-1 `--focus` text MUST also contain the actual material
    being reviewed, not merely Why/Scope describing it.** Paste the produced content — the design
    doc, plan, or analysis text itself — directly into this same `--focus` text, exactly like
    `codex-direct-review:ccd`'s own requirement ("for non-repo artifacts ... paste the produced
    content into `--focus`"). `CLEAN_REPO_DIR` (Phase 0 step 4) guarantees an empty diff
    specifically so the wrapper's own no-diff branch falls back to reviewing the `--focus`/Context
    text instead — if the actual artifact content is never pasted in here, there is nothing left
    for Codex to review at all. This is a genuine non-repo-artifact round only; a real repo-diff
    round never pastes content this way, since `--uncommitted`/`--base`/`--commit` already hands
    the wrapper the diff.
- **Round 2+:** History (fixes applied and findings rejected last round, built from the review
  history log below, not memory alone) / Scope for this round's rebuttal — **never the diff
  again**. Same `⚠️ SCOPE CONSTRAINT` block, every round.
  - **Per-group History construction (parallel mode subtlety).** A group's round-2+ `--focus`
    must recap two DISTINCT things, kept separate rather than blended into one summary: (a) any
    diff/code changes made since THIS group's last round, *including* fixes prompted by a
    *different* group's finding — a fix for one review dimension can regress another, this is the
    whole-flow principle (Phase 2 below) applied ACROSS dimensions, not only within one; and (b)
    this specific group's own prior findings and Claude's response to them (accepted/rebutted),
    distinct from (a). Build this from the review history log's full round history, filtered/
    tagged by this group's own `group` value in `groups[]` (see "Review history log" below), not
    from the round's aggregated top-level summary alone — the aggregated summary is a worst-case-
    wins synthesis across all groups and does not preserve which finding came from which group. A
    group with nothing new to raise about its own dimension still gets a lightweight History
    noting "nothing new from your dimension this round; here is what changed elsewhere" — it is
    still resumed and re-checked, never dropped from the round (see "Convergence = 100% CLEAN"
    below).

### Step 1 — dispatch (primary channel)

For each group dispatched this round (one, for the common `GROUP="main"` single-reviewer case; N
concurrent backgrounded dispatches for a parallel round — one per group, each with its own temp
files from Step 0 and its own entry in `GROUP_THREADS`, below):

```bash
GROUP="<literal from step 0 — e.g. main or g1>"
PID_FILE="<this group's literal from step 0>"; OUT_FILE="<this group's literal from step 0>"; ERR_FILE="<this group's literal from step 0>"; FOCUS_FILE="<this group's literal from step 0>"
INSTALL_PATH_FILE="<literal from Phase 0>"; REPO_ROOT_FILE="<literal from Phase 0>"
INSTALL_PATH="$(cat "$INSTALL_PATH_FILE")"; INSTALL_PATH="${INSTALL_PATH%x}"
REPO_ROOT="$(cat "$REPO_ROOT_FILE")"; REPO_ROOT="${REPO_ROOT%x}"
FOCUS_TEXT="$(cat "$FOCUS_FILE")"; FOCUS_TEXT="${FOCUS_TEXT%x}"
# Same git-environment sanitization as the sizing step above (see "Determine review mode" and
# Phase 0 step 4 for the full reasoning) — the wrapper's own internal `git diff`/`git status`
# calls (fresh scopes only; a --resume round collects nothing) run after a plain `cd "$CWD"`,
# never `-C`, so they inherit whatever this dispatching shell hands them:
for _v in $(git rev-parse --local-env-vars 2>/dev/null || printf '%s\n' GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_CONFIG GIT_CONFIG_PARAMETERS GIT_CONFIG_COUNT GIT_OBJECT_DIRECTORY GIT_DIR GIT_WORK_TREE GIT_IMPLICIT_WORK_TREE GIT_GRAFT_FILE GIT_INDEX_FILE GIT_NO_REPLACE_OBJECTS GIT_REPLACE_REF_BASE GIT_PREFIX GIT_SHALLOW_FILE GIT_COMMON_DIR) GIT_CONFIG_GLOBAL GIT_CONFIG_SYSTEM GIT_TEMPLATE_DIR; do
  unset "$_v"
done

# Round 1 (fresh — pick the one matching scope flag actually decided in Phase 0; identical scope
# flag for every group this round, since every group reviews the SAME diff, see "Determine review
# mode" above). Shown below for --uncommitted, the common case — substitute
# --base "<the actual ref decided in Phase 0>" or --commit "<the actual sha decided in Phase 0>"
# in its place instead when that was the scope actually selected; never dispatch --uncommitted
# here when a different scope was chosen:
"$INSTALL_PATH/scripts/run-ccs-review.sh" --cwd "$REPO_ROOT" --uncommitted \
  --focus "$FOCUS_TEXT" \
  > "$OUT_FILE" 2>"$ERR_FILE" &

# Round 2+ (resume — same REPO_ROOT, same INSTALL_PATH; THREAD_ID is THIS GROUP's own captured id
# from GROUP_THREADS, looked up by this group's slug — never another group's threadId):
# "$INSTALL_PATH/scripts/run-ccs-review.sh" --cwd "$REPO_ROOT" --resume "<this group's literal THREAD_ID from GROUP_THREADS>" \
#   --focus "$FOCUS_TEXT" \
#   > "$OUT_FILE" 2>"$ERR_FILE" &

CODEX_BG_PID=$!
CODEX_START_TIME=$(ps -o lstart= -p "$CODEX_BG_PID" 2>/dev/null)
{ echo "$CODEX_BG_PID"; echo "$CODEX_START_TIME"; } > "$PID_FILE"
wait "$CODEX_BG_PID"
cat "$OUT_FILE"
```

Each group's dispatch is issued as its own separate backgrounded Bash call, all issued within the
same turn — one Bash `run_in_background: true` invocation per group, exactly `codex-direct-review:ccd`'s own
parallel-dispatch pattern ("Run each group's call at the same time → wait for all → synthesize").
The single-reviewer case is simply N=1 of this same loop, not a separate branch.

**Residual gap shared with the `CLEAN_REPO_DIR` case (see Phase 0 step 4's own fuller writeup) —
applies here too, not only to artifact reviews.** The `unset`-based sanitization just above
protects against redirected repository/worktree discovery and command-scope config injection, but
it does not disable ambient default global/system git config: a legitimately-configured
`core.fsmonitor` hook (a real, common developer setting, not just an attacker scenario) still
executes when the wrapper's own `git diff --no-ext-diff --no-textconv` collection runs — confirmed
live. Fully closing this for a NORMAL `$REPO_ROOT` review is a real tension, not a simple copy of
`CLEAN_REPO_DIR`'s `env -i` allowlist fix: a normal review's `git diff` is expected to reflect the
user's actual configured repository behavior, so a `GIT_CONFIG_NOSYSTEM=1`/fake-`HOME` allowlist
appropriate for an isolated throwaway repo is not obviously the right default for the user's real
one. Flagged here as an open question for a future `run-ccs-review.sh` change, not resolved by
this SKILL.md-only fix.

**`GROUP_THREADS` — the ordered set of `(GROUP, THREAD_ID)` pairs.** Established once, right after
round 1's dispatched groups each independently signal their own `THREAD_ID` via Step 3 below (run
once per group). Remembered by Claude as a literal fact for the rest of the run, the same way a
single `THREAD_ID` is already remembered today — just N instances of an already-accepted pattern.
Carried forward by hand into every group's `--resume` dispatch at round 2+ (each group resumes
ONLY its own thread, never another group's). Durable backstop, not the primary carrier: each
round's log line also records the thread id — as a top-level `thread_id` field for the common
single-reviewer case, or per-entry in `groups[].thread_id` for a parallel round (see "Review
history log" below for both) — so `jq '.thread_id // (.groups[] | {group, thread_id})'` on the
latest round's log line re-derives the mapping if memory is ever in doubt, for either mode.

**Non-repo artifact round?** Substitute the exact literal `CLEAN_REPO_DIR` path (see Phase 0 step
4) for `$REPO_ROOT` in the `--cwd` argument above instead — never `$REPO_ROOT` for a genuine
non-repo-artifact review — and always keep `--uncommitted` (never `--base`/`--commit`, since
`CLEAN_REPO_DIR` has no commits to diff against). **Also run the git-environment sanitization
loop defined in Step 1's dispatch section above, immediately before that section's own "Round 1
(fresh ...)" comment.** Reuse that one fenced code block by reference only — never retype it, never
abbreviate it, and never reproduce any piece of its actual shell syntax as a separate backtick-
quoted span anywhere in this file, including here. Multiple earlier revisions of this exact
instruction each tried to show a shortened or reflowed copy directly in prose, and each one turned
out broken in its own way once actually executed (a line break landing mid-command; an abbreviated
placeholder that parses as valid shell but silently does nothing) — this is a real,
repeatedly-reintroduced bug, not a hypothetical one, and the only fix that has actually held is
naming the one canonical block instead of ever showing a second rendering of it. **In this same
dispatch call, every round, before invoking the wrapper** — this is a separately-dispatched call and an
unset environment variable does not carry over between calls any more than a literal value does;
skipping it here would silently reopen the exact bypass Phase 0 step 4 already fixed at creation
time, on every round after the first — the wrapper's own internal `git diff`/`git status` calls
(run after a plain `cd "$CWD"`, never `-C`) inherit whatever environment this dispatching shell
hands them, so sanitizing here is what actually protects them, not a change to the wrapper itself.
**This substitution applies to EVERY round of a
non-repo-artifact session, round 2+ included — never revert to `$REPO_ROOT` on a resume.** The
wrapper still `cd`s into whatever `--cwd` names immediately before running `codex exec resume`,
even though diff collection itself is skipped on resume — passing `$REPO_ROOT` on a resumed
artifact round would silently hand Codex's tool context back to the user's real, unrelated working
tree for that round, defeating the whole point of the isolation `CLEAN_REPO_DIR` exists to
guarantee. Only the diff-collection scope flag changes between round 1 (`--uncommitted`) and round
2+ (`--resume <threadId>`) — `--cwd "$CLEAN_REPO_DIR"` stays constant across every round of the
session. (A non-repo-artifact round is always single-group `main` — see Phase 0 step 4 and
"Determine review mode" above — so this substitution never applies to more than one group.)

Dispatch via Bash with `run_in_background: true` — a round can legitimately take up to the
wrapper's own timeout (1800s default). Never route this through a subagent (including `runner`):
the wrapper emits exactly one clean JSON line, so a relay layer adds no value and risks
paraphrasing it.

### Step 2 — liveness watcher (secondary channel, defense in depth)

Identical to `codex-direct-review:ccd`'s own PID-plus-start-time watcher, reusing that group's own `PID_FILE`,
dispatched as an independent `Monitor` call right after that group's Step 1 dispatch. **One
independent `(GROUP, PID_FILE)` `Monitor` call per group** this round — N concurrent watchers for a
parallel round, direct replication of `codex-direct-review:ccd`'s already-solved parallel-dispatch pattern; the
`GROUP` segment baked into each `PID_FILE`'s `mktemp` template (Step 0) is what prevents one
group's watcher from ever reading another group's PID record:

```bash
GROUP="<literal from step 0 — e.g. main or g1>"
PID_FILE="<this group's literal from step 0>"
PID_WAIT_TIMEOUT=1800  # matches --timeout's default
PID_WAIT_START=$(date +%s)
until [ "$(wc -l < "$PID_FILE" 2>/dev/null || echo 0)" -ge 2 ]; do
  [ $(( $(date +%s) - PID_WAIT_START )) -ge "$PID_WAIT_TIMEOUT" ] && { echo "Round <R> (${GROUP}): primary dispatch never wrote its PID record"; exit 1; }
  sleep 1
done
PID=$(sed -n '1p' "$PID_FILE"); START_TIME=$(sed -n '2p' "$PID_FILE")
START=$(date +%s)
still_running() { kill -0 "$PID" 2>/dev/null || return 1; [ "$(ps -o lstart= -p "$PID" 2>/dev/null)" = "$START_TIME" ]; }
while still_running; do echo "Round <R> (${GROUP}): still running, $(( $(date +%s) - START ))s elapsed"; sleep 180; done
echo "Round <R> (${GROUP}): process exited"
```

Checks PID **plus** recorded start time (mitigates PID reuse after the process exits) — a
defense-in-depth secondary signal, not the primary completion mechanism. See `codex-direct-review:ccd`'s own
"Liveness watcher" section for the full reasoning; nothing about the mechanism itself changes here
beyond the `GROUP` segment now always being present (`main` in the common case).

**Wait for ALL N groups' PRIMARY results before proceeding to Phase 2 — confirmed, not react-as-
completed.** Do not begin Phase 2 processing on any group's result until every dispatched group
this round has completed **its primary channel** (Step 1's own backgrounded dispatch — the
harness's own task-finished notification, or reading that group's `OUT_FILE` once available).
This is structurally required, not just a style preference: the convergence gate (below) requires
CLEAN to hold for EVERY dispatched group, and re-verification must go through EACH group's
findings — both presuppose every group's result is already in hand. Reacting to a subset would
mean re-verifying/gating on an incomplete picture, only to redo that work once a straggler group
lands. A single-reviewer round trivially satisfies this (N=1, nothing to wait on beyond that one
group). **Do not additionally wait on that group's own watcher to print its "process exited"
line once the primary result has already arrived** — the watcher is a defense-in-depth secondary
signal only (see immediately above), consulted when a group's primary notification is delayed or
never arrives, not a second gate stacked on top of an already-available primary result. The
watcher's own poll interval (`sleep 180` above) means treating it as a required gate could stall
an already-finished round by up to ~180s for no benefit, compounding across up to 20 rounds — stop
that group's watcher (it has no further purpose) as soon as its primary result is in hand, exactly
as done for every group in this same round.

### Step 3 — early `THREAD_ID` signal (ccs-specific; drives the tmux pane)

**Round 1 only, per group — skip entirely on that group's round 2+.** On a resume round, that
group's `THREAD_ID` is already known (it's the literal value passed to `--resume`, looked up from
`GROUP_THREADS`), so this poll would be redundant work; same skip-on-resume logic as step 4's tmux
pane below. **One independent poll per group dispatched at round 1** — N concurrent polls for a
parallel round's first round, one per group's own `ERR_FILE`.

A third, independent, bounded poll per group — this is a genuine "notify me once" case, so use
Bash with `run_in_background: true` and an `until` loop that exits on its own, not `Monitor`
(which is for repeated/indefinite events):

```bash
GROUP="<literal from step 0 — e.g. main or g1>"
ERR_FILE="<this group's literal from step 0>"
DEADLINE=$(( $(date +%s) + 30 ))
until grep -q '^THREAD_ID=' "$ERR_FILE" 2>/dev/null; do
  [ "$(date +%s)" -ge "$DEADLINE" ] && { echo "${GROUP}: no THREAD_ID signal within 30s — round likely failed before/during dispatch"; exit 1; }
  sleep 0.5
done
grep '^THREAD_ID=' "$ERR_FILE" | head -1
```

30s is generous: the wrapper's own internal "no thread.started" timeout is 10s, and a live,
timestamped test of this exact mechanism (see the design doc) measured a 5.46s real
dispatch→signal gap. This poll is **purely informational** — it exists only to decide whether/
when to open that group's tmux pane below. If it times out for a given group (a genuine
`bad_args`/`no_thread_started` failure for that group, or just an unusually slow start), skip the
pane for that group this round; nothing about the review's correctness depends on it ever
succeeding — the primary channel (step 1) and its JSON `ok:false` remain the actual source of
truth for that group's round failure.

Once this fires for a group, parse `<uuid>` out of the `THREAD_ID=<uuid>` line and remember it as
that group's literal `THREAD_ID`, adding `(GROUP, THREAD_ID)` to `GROUP_THREADS` (needed for that
group's tmux pane immediately below, for that group's `--resume` next round, and for that group's
`--cleanup` at the terminal path — capture it from here or from that group's round-1 final JSON,
whichever arrives; either source is the same value).

**Per-group retry-leaks-a-thread case.** A round-1 retry (see Guards below) after a
post-`thread.started` failure abandons that group's first, still-real thread the moment it
dispatches fresh again with a new `threadId`. Append that abandoned id to that group's entry in
`LEAKED_THREAD_IDS` — now a set of `(GROUP, threadId)` pairs rather than a flat list, since a
round-1 retry is scoped to the ONE failed group only (mirroring `codex-direct-review:ccd`'s own per-group retry
rule: "retry just that failed group once") — so only that group's old thread ever leaks, never
another group's. Cleaned up at the terminal path (Phase 3 below), never here.

**`GROUP_THREADS` must hold exactly one entry per group at all times — a retry REPLACES, never
adds alongside.** If this failed group already had an earlier `(GROUP, THREAD_ID)` pair in
`GROUP_THREADS` from a prior attempt this same round (the one that just failed and got leaked
above), remove that stale pair before — or atomically with — adding the retry's new
`(GROUP, THREAD_ID)` pair once its own Step 3 signal succeeds. Never leave both the leaked and the
retry's `THREAD_ID` present for the same `GROUP` key: `GROUP_THREADS` is looked up by group slug
for every later `--resume` dispatch and for terminal-path `--cleanup`, so two candidate values for
one group makes both non-deterministic.

### Step 4 — tmux auto-pane(s) (Round 1 only; best-effort, never fatal)

Only on the round that first obtains a `THREAD_ID` for a given group (in practice, usually that
group's round 1 — round 2+ resumes the same thread and therefore the same rollout file, so the
pane already open from round 1 keeps tailing it with no action needed). Track "did I already open
a pane for this group this session" the same way `SESSION_ID` is tracked — a fact Claude itself
remembers per group, not a live shell variable. `PANE_IDS` is the per-group set of opened pane
ids, parallel to `GROUP_THREADS`.

**Retry case — retarget the existing pane, don't open a second one and don't leave it stale.** A
round-1 retry after a post-`thread.started` failure (see "Per-group retry-leaks-a-thread case"
above) obtains a genuinely NEW `THREAD_ID` for that same group, while that group's pane (if one was
already opened for the now-abandoned first attempt) is still tailing the OLD thread's rollout file
— left alone, it would keep showing stale/dead progress for a thread that was already abandoned.
If that group already has a `PANE_ID` in `PANE_IDS` when its retry succeeds, do not open a new pane
for it — interrupt the pane's current `watch-rollout.sh` foreground process first
(`tmux send-keys -t "$PANE_ID" C-c` then `Enter`, since typing a new command into a pane whose
shell is still occupied by a running foreground process just becomes that process's stdin, not a
new shell command) and then re-run the same rollout-lookup-and-tail command shown below with the
retry's new `THREAD_ID` substituted in. The pane's identity (`PANE_ID`) does not change — only
which rollout file it tails.

**N panes, one per dispatched group.** Create the first group's pane with the existing
`tmux split-window -h -P -F '#{pane_id}'` (no `-t`, splitting the current window) and remember its
printed pane id as `FIRST_PANE_ID`. For every additional group (parallel mode only), target that
same pane id — `tmux -t` accepts a pane id as a target and splits the WINDOW that pane belongs to,
which is exactly "the same window" every additional split needs, with no separate window-capture
step required: `tmux split-window -h -t "$FIRST_PANE_ID" -P -F '#{pane_id}'`. Once ALL panes for
this round's groups exist, run `tmux select-layout tiled 2>/dev/null || true` **once** — tmux's own
auto-balancing grid layout, no hand-computed split geometry needed per N. A single-reviewer round
(N=1) creates exactly one pane and skips `select-layout` (nothing to tile).

Before ever creating a pane, guard — **per group** — against either value containing anything
outside a strict path-safe charset — `$INSTALL_PATH` and that group's own `$THREAD_ID` are
interpolated directly into a string that the *pane's own separate shell* re-parses as its command
line, which is a different trust boundary than the sentinel-file idiom above (that idiom only
protects a value passed as one already-quoted shell argument, not a value re-interpolated into a
second string a different shell re-parses). A quote-only check is not enough here: a value
containing `$(...)` or a backtick needs no quote character to run a command when the pane's shell
parses the double-quoted segment it ends up inside — so the guard denies everything except
letters, digits, `_./-`, and a literal space (a real install path can live under a directory whose
name contains one, e.g. a macOS home directory like `/Users/John Doe/...` — a space is inert
inside the double-quoted segment both values land in, so allowing it costs nothing while widening
legitimate coverage), checked *before* that group's pane exists so a rejected value never leaves
an orphaned blank pane behind:

```bash
GROUP="<literal from step 0 — e.g. main or g1>"
THIS_IS_FIRST_PANE_THIS_ROUND="<true for the first group whose pane is opened this round, else false>"
GROUP_COUNT="<the number of groups dispatched this round — 1 for single-reviewer, N for parallel>"
# Separately-dispatched call -- rehydrate INSTALL_PATH/THREAD_ID by hand (see Phase 0's opening
# note). THREAD_ID is a Codex-generated UUID (safe as a direct literal, per the safe-charset guard
# above); INSTALL_PATH is externally resolved `jq` output and MUST go through the sentinel-file
# safe-read idiom, never a hand-typed `VAR="<value>"` literal:
INSTALL_PATH_FILE="<literal INSTALL_PATH_FILE path resolved once in Phase 0>"
INSTALL_PATH="$(cat "$INSTALL_PATH_FILE")"; INSTALL_PATH="${INSTALL_PATH%x}"
THREAD_ID="<this group's own literal THREAD_ID, already captured into GROUP_THREADS by Step 3
above before Step 4 ever runs>"
PANE_ID=""
case "$INSTALL_PATH$THREAD_ID" in
  *[!-A-Za-z0-9_./\ ]*)
    :  # unsafe to interpolate into the pane's send-keys command; skip this group's pane
       # without ever creating one
    ;;
  *)
    if [ -n "${TMUX:-}" ]; then
      if [ "$THIS_IS_FIRST_PANE_THIS_ROUND" = "true" ]; then
        PANE_ID=$(tmux split-window -h -P -F '#{pane_id}' 2>/dev/null)
        # Remember this printed PANE_ID as the literal fact "FIRST_PANE_ID" for the rest of the
        # round (added to PANE_IDS below) -- every later branch rehydrates it from that literal,
        # never from a live "$FIRST_PANE_ID" shell variable.
      else
        # FIRST_PANE_ID is rehydrated the same way -- substitute that group's own remembered
        # literal pane id directly:
        FIRST_PANE_ID="<the literal PANE_ID printed by the first group's own split above, already
        remembered by Claude in PANE_IDS>"
        PANE_ID=$(tmux split-window -h -t "$FIRST_PANE_ID" -P -F '#{pane_id}' 2>/dev/null)
      fi
    fi
    ;;
esac
```

After every group this round has attempted its split (the block above runs once per group), run
this as a separate, final step — never inline inside the per-group loop, since it needs every
group's own outcome first:

```bash
# CREATED_PANE_COUNT is likewise a literal Claude computes by hand from PANE_IDS (the per-group set
# of opened pane ids, one entry per group whose split above actually returned a non-empty PANE_ID).
# Only retile when this was actually a
# parallel round (GROUP_COUNT > 1) AND more than one pane was actually created (a per-group
# unsafe-charset skip, or TMUX being unset partway through, can leave fewer real panes than
# GROUP_COUNT would suggest) — never for a single-reviewer round (nothing to tile), and never off
# a bare $TMUX check alone, which would fire even with zero or one real pane and could retile
# unrelated panes already in the user's window.
GROUP_COUNT="<the same literal from the per-group block above>"
CREATED_PANE_COUNT="<count of non-empty PANE_ID entries in PANE_IDS after every group's split attempt this round>"
if [ "$GROUP_COUNT" -gt 1 ] && [ "$CREATED_PANE_COUNT" -gt 1 ]; then
  tmux select-layout tiled 2>/dev/null || true
fi
```

`tmux split-window -h` with **no command argument** spawns the pane's normal interactive shell —
this is the load-bearing detail: a pane whose command argument directly runs a foreground
process (e.g. `tmux split-window -h "codex ..."`) closes the instant that process exits, which is
exactly the real, live-learned lesson this session's own design doc records. Typing a command
into an already-running shell via `send-keys` instead means the shell survives even if the typed
command (or the `tail -F` inside `watch-rollout.sh`) ever exits.

If a group's `PANE_ID` is non-empty, resolve that group's round-1 rollout file and start watching
it, all inside that pane's own shell. The rollout file can genuinely not exist on disk yet at the
instant this runs — the `THREAD_ID` stderr signal (Step 3) fires before Codex is guaranteed to
have created the file — so the pane's own command retries the lookup itself for up to ~10s rather
than passing a possibly-empty path straight to `watch-rollout.sh`, which would otherwise exit
immediately on its own required-argument check and never reach its unrelated file-wait loop:

```bash
tmux send-keys -t "$PANE_ID" 'R=""; for _i in $(seq 1 20); do R=$(find "$HOME/.codex/sessions/'"$(date +%Y/%m/%d)"'" -maxdepth 1 -name "rollout-*-'"$THREAD_ID"'.jsonl" 2>/dev/null | head -1); [ -z "$R" ] && R=$(find "$HOME/.codex/sessions" -name "rollout-*-'"$THREAD_ID"'.jsonl" 2>/dev/null | head -1); [ -n "$R" ] && break; sleep 0.5; done; "'"$INSTALL_PATH"'/scripts/watch-rollout.sh" "$R"' Enter
```

This directly interpolates that group's `$THREAD_ID` and `$INSTALL_PATH` rather than going through
the sentinel-file idiom above — deliberately: `THREAD_ID` is a UUID Codex itself generated (not
attacker-influenced) and, per the guard above, neither value reaching this point contains
anything outside the safe charset. `INSTALL_PATH` was already safely resolved through the
sentinel idiom earlier for its own purpose (passing it as one shell argument), and this command
is a best-effort convenience typed into a pane for a human to watch, not an argument to the
review wrapper itself — a malformed or skipped pane command only costs the live view for that
group, never the round's correctness.

`watch-rollout.sh` narrates `investigating: <command>` (from `custom_tool_call` events) and
`round complete` (from `task_complete`) reliably; it may also print `reasoning: ...` lines
depending on the provider/model configuration — don't rely on those appearing.

If `TMUX` is unset, or `split-window`/`send-keys` fail for any reason (for one group or all), that
group proceeds without a pane — narrate its progress through ordinary English text updates only,
exactly as `codex-direct-review:ccd` already does with no pane at all. One group's pane failure never blocks
another group's pane from being created.

**UX note (not a hard limit):** past roughly 3–4 simultaneous panes, N concurrent narration
streams get harder to usefully watch than one. This skill does not enforce a hard cap on live-pane
creation — every dispatched group still gets a pane attempt regardless of N — but treat this as a
known, human-watchability tradeoff of a large parallel run, not a defect.

---

## Phase 2 — Converge loop (R = 1 … 20)

For each round, after Phase 1 delivers a result:

1. **Parse each dispatched group's own single-line JSON** (recall: N=1, `GROUP="main"`, is the
   common single-reviewer case — one JSON to parse; a parallel round has one JSON per group,
   collected once ALL groups' Phase 1 dispatches have completed, per Step 2's "wait for ALL N"
   rule above). A group's `ok:false` → that group's round failed, not a clean sign-off for it (see
   Guards). `ok:true` → that group's `verdict.verdict`/`verdict.findings` are its own Codex output.
2. **Receive Codex's findings — do not blindly accept them.** For a parallel round, this means
   EVERY dispatched group's own findings — step 3 below must go through EACH group's findings
   individually, not merely a merged/aggregated view of them.
3. **Re-verify EACH finding against facts/evidence, group by group.** Read the actual file, run
   the actual command, check tests. Treat every finding as *possibly* a false positive, but be
   equally willing to be proven wrong.
   - **VALID** → fix directly (or delegate a substantial/multi-file fix, then verify the diff).
   - **FALSE POSITIVE** → rebut with concrete observed evidence, never without it.
   - **PARTIAL** → fix the valid part, rebut the rest.
4. **Whole-flow re-check (narrow → wide → narrow), for any fix applied this round.** Zoom out to
   the whole affected file/function's control flow, not just the new lines — does the fix
   introduce the same class of problem it just fixed, in a new form; is it consistent with how
   sibling code paths already handle the same case; does a sibling path need the identical fix.
   For a parallel round, this includes checking whether a fix prompted by one group's finding
   could regress a DIFFERENT group's dimension (e.g. a security fix that changes a hot code path
   performance group is watching) — this is exactly why each group's round-2+ History must recap
   changes made since its last round even when those changes were prompted by another group's
   finding (see "Per-group History construction" above).
5. **Convergence check** (below) — evaluated across all dispatched groups together, not per group
   independently (see "Convergence = 100% CLEAN" below).
6. **Narrate progress** — one English line: `Round R/20: Codex N findings → accepted A /
   rebutted B — <clean | continuing>` (aggregated across all groups this round, worst-case-wins,
   for a parallel round). **Construct this round's `groups[]` field** (parallel round only — see
   "Review history log" below) from each dispatched group's own `--focus` text, `codex_review`
   result, and `thread_id` kept from Step 1/3 above; a single-reviewer round has only one group's
   result to carry forward, which becomes the round's own `target.focus`/`codex_review` directly,
   unchanged, with `groups[]` omitted entirely. Then append this round's line to the review
   history log (below), best-effort. Clean up this round's now-unneeded `.pid`/`-out.json`/
   `-err.log`/`-focus.txt` temp files for EVERY dispatched group — nothing needs to read any of
   them again once the round is logged.

### Coverage is a Round-1-only property

Since only a fresh `--uncommitted` round ever reports `coverage.source` (see the interface
reference above), and only round 1 is ever a fresh round in `/ccs` (round 2+ is always
`--resume`), the coverage-completeness gate below is a property of **round 1's own log line**,
not "the latest round's," unlike `codex-direct-review:ccd` (where every round is independently scope-flagged).
Record round 1's `coverage_source` once and carry that determination forward through the rest of
the loop — it is never re-collected on a resumed round.

**A round-1 `CLEAN_REPO_DIR` round needs no special-casing here.** Reasoning from the wrapper's
own source (`run-ccs-review.sh`'s `--uncommitted` branch): even against a freshly-`git init`'d,
zero-file `CLEAN_REPO_DIR`, the untracked-file collector still runs and reports
`{"reviewed_file_count": 0, "omitted": []}`; the wrapper's own coverage-splicing logic derives
`status` from `omitted`'s length, so a zero-length `omitted` array yields `status: "complete"`
regardless of `reviewed_file_count` being `0`. A `CLEAN_REPO_DIR` round therefore reports
`coverage.source.status: "complete"` exactly like any other clean `--uncommitted` round with no
omissions — the convergence gate below evaluates it identically, with no separate rule needed.
(A `CLEAN_REPO_DIR` round is always single-group `main` anyway — see Phase 0 step 4 and "Determine
review mode" above — so this case never interacts with the N-group merge immediately below.)

**Round-1 N-group merge (parallel mode) — worst-case-wins, computed once.** When round 1 dispatches
more than one group (see "Determine review mode" above), each group runs its own separate
`--uncommitted` call and reports its own separate `coverage.source` outcome. Combine every
dispatched group's own outcome the same way `codex-direct-review:ccd` merges its own parallel-mode
groups: the round's overall `coverage_source.status` is `"complete"` **only if every dispatched
group's own status was `"complete"`** — else `"partial"` (with `omitted` set to the union of every
`"partial"` group's own `omitted` list, deduplicated by the `(path, reason)` pair, since every
group reviews the IDENTICAL full diff and would otherwise report the same skipped file once PER
GROUP) if any group reported `"partial"`, else the `"unknown"` sentinel if the rest reported
`"unknown"`. This merge happens **exactly once, at round 1**, and that single merged value is what
gets carried forward through the rest of the loop — never re-merged on a resumed round, since no
group's round 2+ ever reports `coverage.source` at all (confirmed from the wrapper: it is only
ever populated inside the `--uncommitted` branch, which every `--resume` call skips entirely,
regardless of how many groups' threads are being resumed concurrently). A single-reviewer round
(`GROUP="main"`) has nothing to merge and uses its own reported value directly, exactly as
described above.

### Convergence = 100% CLEAN (ALL must hold)
- Codex has no substantiated open findings in its latest review, **AND**
- Claude has no open items (no pending fixes; Codex accepted Claude's rebuttals, or Claude
  accepted Codex's counter), **AND**
- **For a round that dispatched more than one group (parallel mode): the above two conditions
  hold for EVERY dispatched group's OWN findings individually, not merely for an aggregated
  top-level summary.** Ported verbatim from `codex-direct-review:ccd`'s own parallel-mode convergence rule. A
  single-reviewer round has only one group's findings to begin with, so this adds no extra work
  there — it only matters once more than one group is actually dispatched. A group that returned
  `"ok":false` has no `findings` array to re-verify at all — per the Guards' extended "Empty /
  failed review ≠ CLEAN" rule below, such a round is not eligible for `✅ CLEAN` until that group is
  successfully retried, regardless of how clean every other group's own findings turned out to be.
  **This holds every round, not only round 1** — see "Convergence logic across groups" below for
  why an individually-clean group does not exit the loop on its own cadence. **AND**
- **If round 1's scope was `--uncommitted`:** round 1's `coverage_source.status` (the ROUND-1
  N-group merged value when round 1 dispatched more than one group — see "Coverage is a
  Round-1-only property" above) — the wrapper's own `coverage.source` object verbatim, or the
  sentinel `{"status":"unknown","omitted":[]}` when the wrapper's `ok:true` response omitted
  `coverage.source` entirely — is explicitly `"complete"`, never assumed. `"partial"` (real
  omitted files) or `"unknown"` fail this condition unless every omitted path has since been
  explicitly reviewed another way or explicitly accepted as out-of-scope by the user. For round 1
  scoped `--base`/`--commit`, this condition is automatically satisfied — those scopes never
  report coverage at all.
→ Stop the loop, go to Phase 3 as **✅ CLEAN**.

### Convergence logic across groups — round-level, all-groups-together (confirmed decision)

**A round converges only if every dispatched group is independently clean in that SAME round.**
An individually-clean group does **not** exit the loop early on its own cadence; it keeps being
resumed — with a lightweight "nothing new from your dimension, here's what changed elsewhere"
`--focus` (see "Per-group History construction" above) — until the WHOLE round converges. This is
approved, round-level, all-groups-together convergence (see the design doc's "Confirmed
decisions"), ported verbatim from `codex-direct-review:ccd`'s own rule.

**Why:** N dimensional groups exist to give N angles on the *same evolving diff*. If group g1
(security) signs off at round 2 but g2 (performance) keeps finding things through round 5, g1's
round-2 signoff describes a diff state that no longer exists by round 5 — every fix Claude makes
in rounds 3–5 (prompted by g2, or by g1's own earlier finding) can silently affect g1's dimension
too, the whole-flow principle applied across dimensions rather than only within one. An early-exit
design would let a stale signoff stand in for a re-check that never happens.

The round counter `R` still counts *rounds*, not group-dispatches — a round is one synchronized
wave of N concurrent calls (or 1, in single-reviewer mode); the 20-round cap is unchanged in
meaning.

### Guards
- **Never fake-clean.** A genuine, evidence-unresolved disagreement is not convergence.
- **Cap:** R = 20 without convergence → stop, report **⚠️ NOT CONVERGED**, listing every open
  disagreement (finding, Codex's position, Claude's evidence-based counter, why unresolved).
- **Zero progress twice in a row.** For a single-reviewer round: same open-disagreement set, no
  new evidence, no accepted rebuttal/counter — check the last two rounds'
  `claude_verification[].action` in the log rather than memory — stop early, report NOT CONVERGED
  rather than burning remaining rounds. **For a parallel round, this check generalizes to the
  UNION of all dispatched groups' open items**: no new state machine, just a union check — if the
  combined set of every group's own open disagreements shows no movement across the last two
  rounds (checking each group's own `claude_verification[].action` entries in that round's
  `groups[]` log entry), stop early and report NOT CONVERGED the same way.
- **Empty / failed review ≠ CLEAN.** `ok:false` for a group → retry that group before accepting
  failure, reusing the exact dispatch shape appropriate to whether a thread actually exists for
  it — the shape of that retry depends on the failure reason (below), it is not always the same
  single fresh retry the wrapper's own reason table alone might suggest:
  - **Per-group retry (parallel mode) — the same rule applies per group, not just to a
    single-reviewer round.** If ANY dispatched group in a parallel round returns `"ok":false`, the
    ROUND overall is not eligible for `✅ CLEAN` — worst-case-wins, the same principle used for the
    `coverage_source`/`codex_review` parallel merges above. Retry JUST that failed group — the
    other groups' real, already-collected results are kept, not thrown away and re-dispatched.
  - **No `threadId` was ever captured for THIS failure response** (`bad_args`, `git_error`,
    `incomplete_collection`, `no_thread_started`, or `interrupted`/`timeout` on the rare occasion
    either fires before a thread ever started — see the reason table's `threadId` column, which
    is per-OCCURRENCE, not a blanket guarantee for every reason in the "resume-safe" row below).
    **A missing `threadId` in the failure response is not the same claim as "no thread exists for
    this group" — check `GROUP_THREADS` directly, never infer this from the round number.** The
    two only coincide for a group's very first-ever dispatch attempt; they do NOT coincide for a
    no-`threadId` failure encountered *during* one of the bounded resume-retries below (still round
    1, but by definition already past a first attempt that DID obtain a real `threadId`), nor for
    any round-2+ attempt (which always starts from an existing `GROUP_THREADS` entry). Handle by
    whether `GROUP_THREADS` already has an entry for this group, checked at the moment of this
    specific failure — not by which round counter value happens to be current:
    - **This group has NO entry in `GROUP_THREADS` yet** (its true first-ever attempt — only
      possible on round 1, before that round's own first dispatch has ever returned a `threadId`):
      nothing exists to resume — retry the same scope flag fresh, exactly once. If it fails again,
      stop — report **⚠️ COULD NOT VERIFY**.
    - **This group ALREADY has an entry in `GROUP_THREADS`** (a real, persistent thread from an
      earlier successful dispatch — whether that was this same round's own original attempt,
      before a subsequent resume-retry hit a no-`threadId` failure, or an earlier round entirely):
      a `--resume` call CAN still fail with no `threadId` in its own failure JSON (e.g. `bad_args`
      from a malformed `--focus`, caught during argument validation *before* the wrapper ever
      touches the resumed thread — confirmed directly from the wrapper's own argument-parsing
      order). That existing thread is untouched, not abandoned, by this kind of failure — retry
      the exact same `--resume "<this group's existing threadId from GROUP_THREADS>"` call again
      (correcting whatever caused the bad response, e.g. a genuinely non-empty `--focus` this
      time), never a "fresh" scope flag (there is none to use once a group has ever been resumed)
      and never anything added to `LEAKED_THREAD_IDS` (nothing was actually abandoned). If the
      retry also fails, stop — report **⚠️ COULD NOT VERIFY**.
  - **A `threadId` WAS captured, and the reason is resume-safe** (`interrupted`, `timeout`,
    `nonzero_exit`, `missing_task_complete`, `no_final_answer`, `invalid_json`, `schema_mismatch`
    — see "Resume-safety by failure reason" above): prefer a bounded `--resume` retry over
    abandoning the thread. Wait 5s, then — using the SAME sentinel-file `--focus` idiom every other
    dispatch in this file already uses, never a value interpolated directly:
    ```
    FOCUS_FILE="<a fresh mktemp'd path, written via the Write tool exactly like Phase 1 Step 0 --
    content is the SAME ⚠️ SCOPE CONSTRAINT block every round's --focus already requires, plus a
    short note: retrying after a <reason> failure -- please provide your review, plus the trailing
    x sentinel>"
    FOCUS_TEXT="$(cat "$FOCUS_FILE")"; FOCUS_TEXT="${FOCUS_TEXT%x}"
    "$INSTALL_PATH/scripts/run-ccs-review.sh" --cwd "$REPO_ROOT_OR_CLEAN_REPO_DIR" \
      --resume "<that threadId>" --timeout 300 \
      --focus "$FOCUS_TEXT"
    ```
    **`--timeout 300` (5 min) is required on both retry attempts, never the wrapper's 1800s
    default** — without an explicit shorter timeout, a genuinely stuck retry can silently consume
    the full default window per attempt, turning a "bounded, short backoff" retry into a
    worst-case multi-hour stall across the original call plus two full-length retries; 300s is
    ample for a normal review turn and still fails fast on a truly stuck one. **The retry focus
    text still needs the full `⚠️ SCOPE CONSTRAINT` block**, same as every other round's `--focus`
    (see "Hard rules" and the `## Rules` section) — losing that requirement just because this is a
    retry, not a "real" round, would be inconsistent with the rest of this file; only the diff
    itself is never re-sent, matching every other resumed call. If this also fails with a
    resume-safe reason, wait 15s and retry once more (2 resume attempts total, each with its own
    5-minute cap) before giving up on that thread. **This applies to a failed round 1 as much as
    to round 2+** — the empirical finding this section is based on specifically tested a ROUND-1
    failure (the crash-simulation thread had only ever seen its first prompt) and confirmed the
    original diff-bearing prompt is already present in the thread's own rollout, so a resume-retry
    needs no diff re-sent even here.
    - If both resume-retries are exhausted and this was **round 1**: fall back to one fresh retry
      of the original scope flag, for that group, abandoning the now-unrecoverable thread.
      **Append that abandoned `(GROUP, threadId)` pair to `LEAKED_THREAD_IDS`** — Claude remembers
      this set for the rest of the run, the same way `GROUP_THREADS`/`SESSION_ID` are remembered —
      so Phase 3's terminal path (below) can clean it up alongside the run's final threads; it is
      never cleaned up here, only recorded. Only that ONE failed group's thread leaks — every
      other group's real, already-live thread is untouched. If this fresh retry also fails, stop —
      report **⚠️ COULD NOT VERIFY** for that group.
    - If both resume-retries are exhausted and this was **round 2+**: there is no fresh scope left
      to fall back to on an already-resumed group — stop directly, report
      **⚠️ COULD NOT VERIFY** for that group. No new threadId was ever created by either
      resume-retry, so nothing is added to `LEAKED_THREAD_IDS` on this path.
  - **A `threadId` WAS captured, but the reason is NOT resume-safe** (`resume_thread_not_found`,
    `rollout_not_found` — the thread/rollout itself is confirmed or likely gone; a `--resume`
    attempt would just fail the same way again, wasting up to a full timeout for a result already
    known in advance): skip the resume-retry step entirely.
    - **Round 1:** retry the original scope flag fresh, exactly once, for that group — append the
      now-confirmed-dead `(GROUP, threadId)` to `LEAKED_THREAD_IDS` (its rollout is already gone or
      unreachable, but the thread record itself may still need explicit `--cleanup` at the
      terminal path). If the fresh retry also fails, stop — report **⚠️ COULD NOT VERIFY**.
    - **Round 2+:** there is no fresh scope to fall back to — stop directly, report
      **⚠️ COULD NOT VERIFY** for that group.
  - Whenever a group ends in **⚠️ COULD NOT VERIFY**, the round-level status is
    **⚠️ COULD NOT VERIFY**, regardless of how clean every other group's own findings turned out to
    be — never fold this into `⚠️ NOT CONVERGED`/`⚠️ PARTIAL COVERAGE` instead (those cover a
    genuine Claude/Codex disagreement or an unresolved coverage gap, not a group that never
    produced a real verdict). Never declare CLEAN off a missing review from any group. Still run
    the terminal-path cleanup (below) using whatever `threadId`s are known for every group, even
    from a failed response.
- **Partial or unknown source coverage ≠ CLEAN, and is not the same failure as NOT
  CONVERGED/COULD NOT VERIFY.** If round 1's `coverage_source.status` (the N-group merged value
  for a parallel round — see "Coverage is a Round-1-only property" above) is unresolved `"partial"`
  or `"unknown"` while everything else would otherwise say converged, stop and report
  **⚠️ PARTIAL COVERAGE** instead of CLEAN — list every omitted path and reason (or state
  plainly the wrapper never reported coverage at all, for `"unknown"`). If the R=20 cap is hit
  while a genuine disagreement AND unresolved coverage both remain open, report NOT CONVERGED
  and list the coverage gap alongside the disagreements — the disagreement is the more severe
  condition in that case.

---

## Review history log (JSONL)

Same purpose and mechanism as `codex-direct-review:ccd`'s own log — Claude is the sole writer/reader, Codex never
sees it — at a plugin-appropriate path instead of `codex-direct-review:ccd`'s command-local one:

**Location:** `~/.claude/plugins/data/codex-stream-review/ccs-logs/<repo-slug>/<session-id>.jsonl`
- `<repo-slug>`: the target repo's directory basename, lowercased, non-alnum → `-`.
- `<session-id>`: the literal `SESSION_ID` from Phase 0.
- Create owner-only, once per session: `umask 077 && mkdir -p ~/.claude/plugins/data/codex-stream-review/ccs-logs/<repo-slug>`
  — same reasoning `codex-direct-review:ccd` documents (this log retains full `target.focus` text indefinitely; the
  ambient `umask` on this machine would otherwise leave it group/world-readable). Best-effort
  also retighten any pre-existing directory once per session:
  `chmod -R go-rwx ~/.claude/plugins/data/codex-stream-review/ccs-logs/<repo-slug> 2>/dev/null || true`.

**Line schema (one JSON object per round)** — exactly `codex-direct-review:ccd`'s own schema shape (`target`,
`codex_review`, `coverage_source`, `claude_verification`, `round_outcome`), minus
`investigation_evidence` (v1 has no capture-evidence concept at all — see "v1 scope") but now
including `groups`, for a parallel round only, ported from `codex-direct-review:ccd`'s own `groups[]` bookkeeping
with one `ccs`-specific addition (`thread_id`). `target.scope` also gains one more legal value
(`"resume"`) to describe what `/ccs` rounds 2+ actually do. **The common case — a single-reviewer
round (`GROUP="main"`) — is completely unchanged from before:** `target.focus`/`codex_review` stay
single string/object values and `groups` is omitted entirely, exactly as shown below:

```json
{
  "session_id": "2026-09-03T143000-54321",
  "round": 1,
  "ts": "2026-09-03T14:31:05+09:00",
  "thread_id": "<this round's own threadId>",
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

- `thread_id`: the single-reviewer round's own `THREAD_ID` (`GROUP="main"`'s entry in
  `GROUP_THREADS`) — the exact same durable-backstop purpose the parallel case's `groups[].thread_id`
  serves (see below), just at the top level here since there is only ever one thread to track for
  a single-reviewer round. Without this field, a single-reviewer session's log would have no way to
  recover a lost/forgotten `THREAD_ID` at all — unlike the parallel case, which always had this
  backstop via `groups[]`.

- `target.scope`: `"uncommitted"` / `"base"` / `"commit"` for round 1 (whichever fresh scope flag
  was used); `"resume"` for every round 2+ — no scope flag is ever sent on those, so logging the
  original scope value would misrepresent what actually happened that round. **A single value per
  round, never per group** — all groups advance in lockstep with the round counter (round 1
  dispatches every group fresh, round 2+ resumes every group), so a per-group `scope` field would
  be redundant state with no current use.
- `coverage_source`: written only for a round-1 `--uncommitted` scope (per "Coverage is a
  Round-1-only property" above, including its N-group merge for a parallel round); omitted
  entirely for round-1 `--base`/`--commit` and for every `--resume` round — the wrapper never
  reports it for those, so no field is invented. **A single top-level value, merged once at round
  1** — never per group, never re-merged on a resumed round.
- `finding_id`/`linked_finding_id`/`claude_verification[].action`: identical meaning to `codex-direct-review:ccd`'s
  own schema — stable `f<n>` IDs incrementing across all rounds, `linked_finding_id` traces a
  disputed finding's multi-round thread, actions are `accept` / `reject_with_rationale` /
  `request_rereview` / `parked`.
- `groups`: **added only for a parallel round — more than one group dispatched this round (see
  "Determine review mode" above).** Each dispatched group runs its own separate wrapper call with
  its own `--focus` text and produces its own separate `codex_review` result, and without this
  field only one group's result (or an undefined amalgamation) would ever be recorded, silently
  losing every other group's real findings. **Common case — a single-reviewer round: omit this
  field entirely**, exactly as shown in the example above. **Only when this round actually
  dispatched more than one group:** `groups` is an array with exactly one element per dispatched
  group:
  ```json
  {
    "groups": [
      {"group": "g1", "thread_id": "<g1's own threadId>", "focus": "<g1's exact --focus text>", "codex_review": {"ok": true, "verdict": "ISSUES", "findings": [{"id": "f1", "file": "...", "line": 42, "severity": "high", "summary": "...", "evidence": "...", "linked_finding_id": null}]}},
      {"group": "g2", "thread_id": "<g2's own threadId>", "focus": "<g2's exact --focus text>", "codex_review": {"ok": true, "verdict": "CLEAN", "findings": []}},
      {"group": "g3", "thread_id": "<g3's own threadId, if one was ever obtained>", "focus": "<g3's exact --focus text>", "codex_review": {"ok": false, "reason": "timeout", "detail": "..."}}
    ]
  }
  ```
  (shown here as its own standalone valid JSON object containing only the `groups` field being
  illustrated; in the actual log line it is one sibling field alongside `session_id`/`round`/
  `target`/etc., exactly as in the full single-reviewer example above.)
  `thread_id` is `ccs`-specific — `codex-direct-review:ccd`'s own `groups[]` has no analog since its groups are
  ephemeral (a fresh process per round, nothing to persist); here it is the durable backstop for
  `GROUP_THREADS` (see Phase 1 Step 1 above) — `jq '.groups[] | {group, thread_id}'` on the
  latest round's log line re-derives the group→thread mapping if memory is ever in doubt.
  What the top-level `target.focus`/`codex_review` fields hold for a parallel round, so a consumer
  reading only the top-level fields still gets a reasonable, non-misleading summary: `target.focus`
  is a short synthesized note, e.g. `"(parallel round, 3 groups — see groups[] for each group's
  actual focus)"` — never any one group's real focus text presented as the round's only focus.
  `codex_review` is an AGGREGATED verdict/findings, worst-case-wins exactly like the
  `coverage_source` merge above: `verdict` is `"ISSUES"` if ANY group's own verdict was `"ISSUES"`
  or had a non-empty `findings` array; `"CLEAN"` only if EVERY group's own verdict was `"CLEAN"`
  with zero findings. The aggregated `findings` array concatenates every group's own `findings`,
  each additionally tagged with a `"group"` field naming its source group. **A group that returned
  `"ok":false` also forces the aggregate `verdict` to `"ISSUES"`** — its `groups[]` entry is the
  raw wrapper failure shape verbatim (see `g3` above), it contributes nothing to the aggregated
  `findings` concatenation, and it does not count as `"CLEAN"` for the aggregated verdict; `"ISSUES"`
  here is a mechanical non-`"CLEAN"` placeholder value only, never a claim that real code defects
  were found — the actual reason (a group's review never completed) lives in that group's own raw
  `groups[]` entry, and the round as a whole is never eligible for `✅ CLEAN` in this state anyway
  (it is `⚠️ COULD NOT VERIFY` once retries are exhausted, per the Guards below) regardless of what
  this aggregate field says.
  **`ccs` v1 never adds an `investigation_evidence` field, in parallel mode or otherwise** — `ccs`
  has no `--capture-evidence` concept at all (see "v1 scope" above), so there is no per-group
  evidence JSON to merge; do not port `codex-direct-review:ccd`'s evidence-merge machinery as if it were a
  missing piece here.

**Write:** append via `jq -nc` redirected with `>>`, `umask 077` restated immediately before
every append (a fresh Bash call each time — the earlier `mkdir`'s umask doesn't carry over).
Never overwrite or truncate.

**Read (continuity):** at the start of round R > 1, before building this round's History text,
query the log rather than relying on memory:
```bash
jq -c 'select(.round < 3)' ~/.claude/plugins/data/codex-stream-review/ccs-logs/<repo-slug>/<session-id>.jsonl
```
(substitute the actual current round number by hand, same reason `codex-direct-review:ccd` does — no live `$R` shell
variable survives into a separately-dispatched call).

**Failure isolation:** a log-write failure never aborts or degrades the round — note it once and
continue.

**Retention: kept indefinitely, no automatic cleanup — this is a completely separate policy from
the automatic Codex-thread cleanup below.** "Automatic cleanup" throughout this skill refers only
to deleting the ephemeral Codex thread and its rollout file under `~/.codex/sessions/` — never to
this JSONL audit log, which persists exactly like `codex-direct-review:ccd`'s own, for the same durable-record reason.

---

## Phase 3 — Terminal path

On **every** terminal outcome — `✅ CLEAN`, `⚠️ NOT CONVERGED`, `⚠️ COULD NOT VERIFY`, or
`⚠️ PARTIAL COVERAGE` — do all of the following before reporting to the user. None of these is
ever left to the user to remember; this is the deliberate difference from `stream-review`'s own
caller-owns-cleanup contract (see "Mode 2 — cleanup" above).

1. **Clean up every group's final Codex thread**, for every group slug that ever obtained a real
   `THREAD_ID` this run (i.e. every entry in `GROUP_THREADS` — one entry for the common
   `GROUP="main"` single-reviewer case, N entries for a parallel run). Phase 3 is its own
   separately-dispatched call — rehydrate `INSTALL_PATH` here first (see Phase 0's opening note):
   ```bash
   INSTALL_PATH_FILE="<literal INSTALL_PATH_FILE path resolved once in Phase 0>"
   INSTALL_PATH="$(cat "$INSTALL_PATH_FILE")"; INSTALL_PATH="${INSTALL_PATH%x}"
   "$INSTALL_PATH/scripts/run-ccs-review.sh" --cleanup "<that group's literal threadId from GROUP_THREADS>"
   ```
   Loop over every `GROUP_THREADS` entry — a `cleanup_failed` on one group's thread is surfaced
   per-item and **never skips cleaning up the rest**. If `GROUP_THREADS` is empty (every group's
   every round failed before a thread ever started — `bad_args`/`no_thread_started` on every
   attempt, for every group), there is nothing to clean up here; skip silently. **Every
   `cleanup_failed` result is surfaced plainly in the final report** (which group, which thread,
   why) — never hidden behind a clean-looking headline result. An undeleted thread means that
   group's full diff/code content is still sitting on disk under `~/.codex/sessions/`.

2. **Clean up every `(GROUP, leaked-threadId)` pair in `LEAKED_THREAD_IDS`** (see Guards → "Empty
   / failed review ≠ CLEAN" above) — a group's round-1 retry after a post-`thread.started` failure
   abandons that group's first, still-real thread the moment it dispatches fresh again, and
   nothing before this point ever deletes it. This set is almost always empty (it only gains an
   entry when some group's round 1 itself both fails post-`thread.started` AND gets retried), but
   when it isn't, skipping this step is exactly how a thread ends up permanently orphaned despite
   this skill's own cleanup guarantee. This step may run in its own separately-dispatched call,
   distinct from step 1's — rehydrate `INSTALL_PATH` here too, the same sentinel-file idiom as step 1:
   ```bash
   INSTALL_PATH_FILE="<literal INSTALL_PATH_FILE path resolved once in Phase 0>"
   INSTALL_PATH="$(cat "$INSTALL_PATH_FILE")"; INSTALL_PATH="${INSTALL_PATH%x}"
   # for each (group, id) pair in LEAKED_THREAD_IDS:
   "$INSTALL_PATH/scripts/run-ccs-review.sh" --cleanup "<literal leaked threadId>"
   ```
   Same treatment as step 1's `cleanup_failed` handling — surface it plainly in the final report
   (naming which group it belonged to), never hide it, and **a `cleanup_failed` on one pair never
   skips cleaning up any other pair still in the set**.

3. **Close every group's tmux pane**, for every `PANE_ID` opened in Phase 1 step 4 (one pane for
   the common single-reviewer case, N panes for a parallel run):
   ```bash
   tmux kill-pane -t "<that group's literal PANE_ID>" 2>/dev/null || true
   ```
   Loop over every group's `PANE_ID` — best-effort per pane, same as today; a failure closing one
   group's pane never skips closing any other group's pane, and no pane-close failure here is ever
   worth surfacing to the user.

4. **Clean up session-level temp files**, same fast path `codex-direct-review:ccd` uses:
   ```bash
   rm -f "<literal REPO_ROOT_FILE>" "<literal INSTALL_PATH_FILE>"
   # only if this session ever actually allocated them (most sessions never do — see Phase 0 step 4):
   rm -rf "<the exact literal CLEAN_REPO_DIR path, if one was allocated this session>"
   rm -rf "<the exact literal FAKE_GIT_HOME path, if one was allocated this session>"
   ```
   `FAKE_GIT_HOME` is allocated in the same lazy, one-time-per-session way as `CLEAN_REPO_DIR` (see
   Phase 0 step 4) and cleaned up alongside it here — never left behind once `CLEAN_REPO_DIR` no
   longer needs it.

### Final report (Korean — the only Korean output)

Same structure `codex-direct-review:ccd` uses:
- **작업/대상 요약** — what was done / what the artifact is.
- **최종 결과물** — what changed (files/behavior).
- **리뷰 방식** — 단일 리뷰어인지 병렬 다중 리뷰어(그룹 수 N, 각 그룹의 리뷰 관점)인지, 총 라운드 수,
  그리고 **사용한 모든 스레드 ID를 그룹별로** 명시 (단일 리뷰어는 스레드 1개, 병렬 모드는 그룹별로
  `g1: <threadId>`, `g2: <threadId>`, … 형식으로 전부 나열 — 하나만 대표로 보고하지 않는다).
- **라운드별 수렴 표** — 라운드마다 `[Codex 발견 → 재검증 결과(수용/반박 + 근거) → 조치]`. 병렬
  모드였다면 라운드마다 어느 그룹(관점)이 무엇을 발견했는지 구분해서 표기.
- **합의 상태** — 정확히 하나: `✅ CLEAN (N라운드)` / `⚠️ NOT CONVERGED (20라운드 한도 도달, 미해결 K건)` /
  `⚠️ COULD NOT VERIFY (Codex 리뷰 불가)` / `⚠️ PARTIAL COVERAGE (소스 커버리지 미해결)`. 병렬 모드에서
  `COULD NOT VERIFY`라면 어느 그룹이 검증 불가였는지 명시.
- **소스 커버리지** — round 1이 `--uncommitted`였고 그 `coverage_source.status`(병렬 모드면 N개 그룹을
  병합한 값)가 한 번이라도 `"partial"`/`"unknown"`이었다면, 결과와 무관하게 반드시 언급 — 어떤 파일이
  왜 빠졌는지, 이후 해결되었는지.
- **스레드 정리 결과 (그룹별)** — 각 그룹의 최종 스레드마다 `--cleanup`이 성공했는지, 그리고
  `LEAKED_THREAD_IDS`에 담긴 `(그룹, 스레드)` 쌍(어느 그룹의 라운드 1이 실패 후 재시도되며 남긴 것)이
  있었다면 그것들도 각각 정리에 성공했는지 — 그룹별로 빠짐없이 정리 결과를 나열하고, 실패한
  threadId가 있다면 어느 그룹의 어떤 것이 왜 정리되지 않았는지 명시 (ccs 고유 항목 — `codex-direct-review:ccd`에는 없는, 매
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
- **Always run `--cleanup` on every terminal path, for every group** — this is not optional, not
  user-prompted, and not something a future round can undo by mistake (the wrapper's own
  `--cleanup`/dispatch mode split already prevents cleaning up a thread a caller is still trying
  to `--resume`).
- Do not report to the user until Phase 3.
- A non-repo-artifact review is in scope (see Phase 0 step 4's `CLEAN_REPO_DIR` mechanism) — it is
  always single-group `main`, never parallel (see "Determine review mode" in Phase 1 above).
- **Parallel multi-reviewer mode is native to `/ccs`** (see "Determine review mode" in Phase 1
  above) — do not reach for `codex-direct-review:ccd` just to get N concurrent reviewers; every group here still gets
  its own persistent, resumable thread, unlike `ccd`'s ephemeral-process-per-round-per-group
  model. Reach for `codex-direct-review:ccd` instead when its further-proven ephemeral-process-per-round mechanism
  is specifically what's wanted, not for parallel coverage alone.
- **Before committing a change to `scripts/run-ccs-review.sh`, `scripts/lib/git-safe.sh`, or
  `scripts/collect_untracked_files.py`, run `shellcheck` (the two `.sh` files) and the repo's own
  `tests/test-run-ccs-review.sh` fixture suite.** This project has no CI pipeline defined for this
  plugin — these checks are manual, not automatic, so they only catch anything if actually run:
  `shellcheck scripts/run-ccs-review.sh scripts/lib/git-safe.sh` (pin a specific installed
  version with `shellcheck --version` in the commit/PR description when reporting a clean run, so
  a later regression against a newer ShellCheck release is distinguishable from a real
  reintroduced bug) plus `bash tests/test-run-ccs-review.sh`. Neither replaces the other:
  ShellCheck catches quoting/expansion/control-flow hazards `bash -n` (syntax-only) cannot, while
  the fixture suite is the only thing that actually exercises the git-isolation behavior
  (`git_safe()`'s `env -i` allowlist, the collector's own isolated subprocess call) end to end —
  a lint-clean script can still be behaviorally wrong, and a behaviorally-passing script can still
  have a real quoting hazard ShellCheck would have caught on an input the fixture suite doesn't
  happen to exercise.
