---
name: ccs
description: Claude executes a task then runs a Claude+Codex adversarial cross-review loop (max 20 rounds) until fact-based consensus, built on a single resumable Codex thread per reviewer instead of a fresh process per round, so follow-up rounds are cheaper (no diff re-send after round 1). Supports both single-reviewer and parallel multi-reviewer (N concurrent, dimension-focused reviewers, each on its own resumable thread) modes.
---

# /ccs — Claude + Codex Cross-Review on a Resumable Thread

**Usage:** `codex-stream-review:ccs <task description>` — this skill is not invocable as a bare
`/ccs` slash command; it is invoked plugin-qualified, like every other plugin-supplied skill. Leave
the task description empty to review the work just done in this session. Optional prefix:
`codex-stream-review:ccs --capture-evidence <task description>` — opt-in investigation-evidence
capture for every round of this session (see `references/capture-evidence.md`, read only when this
flag is used). Omit it and
`/ccs` behaves exactly as documented everywhere else in this file, with zero added fields anywhere.
Any other free text is the TASK.

Execute the given task, then reach fact-based consensus with Codex — on a resumable Codex thread
per reviewer for the whole run (one thread for a single-reviewer round, one independent thread per
group for a parallel round — see "Determine review mode" below) — before reporting to the user, or
until a hard cap of 20 rounds is hit. The review target is not limited to a diff: it can be a real
repo diff (`--uncommitted`/`--base`/`--commit` — note `--base <ref>` diffs the merge-base of `ref`
and `HEAD` to `HEAD`, a three-dot diff, not every file in the tree; it does NOT by itself provide a
"whole codebase" review) or a non-repo artifact (a design doc, a plan, pasted analysis/review text)
— give Codex the actual material to review in every case (see Phase 0 step 4 below for how a
non-repo artifact is handled, via the `CLEAN_REPO_DIR` mechanism).

`/ccs` dispatches every review round through `run-ccs-review.sh`, a resumable-thread wrapper — one
persistent Codex thread per reviewer for the whole run, `--resume`d every round after the first
rather than re-sent the diff each time. It **always cleans up its Codex thread on every terminal path** — never left to the
user, unlike `stream-review`'s own caller-owns-cleanup contract.

`/ccs` also supports parallel multi-reviewer mode — N concurrent, dimension-focused reviewers
dispatched within the same round (see Phase 1 below for the sizing/mode-selection logic and the
per-group dispatch mechanics). Each group keeps its own persistent, resumable Codex thread for the
whole run — `GROUP="main"` (the single-reviewer case) is simply the N=1 special case of the exact
same mechanism, not a separate code path.

---

## Scope

`--capture-evidence` is supported — see `references/capture-evidence.md` for its full mechanics,
read only when this flag is used. No version-gating
preflight is needed for it: `run-ccs-review.sh` has supported `--capture-eventlog <path>` since
this wrapper's first release (confirmed directly — `grep -n capture-eventlog
scripts/run-ccs-review.sh` finds it in the argument parser and the terminal-copy step both), so
there is no "installed plugin predates this flag" migration case for `/ccs` to guard against.

**Parallel multi-reviewer mode is supported** (see Phase 1 below): every group — including the
single-reviewer case, `GROUP="main"` — keeps its own persistent, resumable Codex thread for the
whole run, created once at round 1 and `--resume`d every round after; `GROUP="main"`/N=1 is simply
the special case of the same mechanism, not a separate construct. The review target can be a real
repo diff (`--uncommitted` / `--base <ref>` / `--commit <sha>` — `--base <ref>` diffs `ref`'s
merge-base with `HEAD` to `HEAD`, a three-dot diff, not a review of every file in the tree) or a
non-repo artifact — pasted analysis, generated text, a plan — via the `CLEAN_REPO_DIR` mechanism
(see Phase 0 step 4 below).

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
- `--timeout <secs>` — optional, positive integer, default `1800` (30 min). This skill does not
  pass it explicitly unless a round genuinely needs longer; the PID-liveness watcher's own wait
  bound (below) matches whatever value is actually used.
- `--capture-eventlog <path>` — optional, best-effort raw event-log dump. Used by this skill only
  when `--capture-evidence` was given for this session (see `references/capture-evidence.md`)
  — omitted entirely otherwise.
- A `--base`/`--commit` value starting with `-` is rejected (`bad_args`) as a git-option-
  injection guard; a `--resume` threadId starting with `-` is rejected the same way.

**Success:** `{"ok":true,"threadId":"<uuid>","verdict":{...}}`.
`verdict` matches the shared review-verdict schema (`verdict`/`findings[]`/`summary`/
`dimensions`) — do not re-derive it.

**Coverage:** both the `ok:true` success response above AND a failure response below whose
`reason` is one of the 8 post-dispatch reasons (`timeout`, `nonzero_exit`,
`missing_task_complete`, `rollout_not_found`, `no_final_answer`, `invalid_json`,
`schema_mismatch`, `no_thread_started` — see the reason table immediately below) can carry an
additional spliced-in `"coverage":{"source":{...}}` object. **Present whenever this round's
dispatch was a fresh `--uncommitted` dispatch that got far enough to collect the diff —
regardless of whether that dispatch attempt ultimately succeeded or hit one of those 8
post-dispatch failures.** All 8 are structurally guaranteed to occur only after a fresh
dispatch's diff collection has already completed and `codex exec` has already been launched
(`no_thread_started` fires while polling for a `thread.started` event, itself a step that only
happens after that same launch) — so all 8 are unconditionally eligible for `coverage.source`
whenever this was a fresh `--uncommitted` dispatch, regardless of whether that attempt ultimately
succeeded.

`interrupted` is different, and deliberately not part of that unconditionally-eligible set: the
wrapper's own SIGINT/SIGTERM trap handler also splices in `coverage.source` when it can, but a
signal can land at ANY point in the wrapper's execution — before collection ever starts,
mid-collection, or after collection but before `codex exec` is ever launched — not only after
collection has finished the way the 8 reasons above are guaranteed to. So `interrupted` carries
`coverage.source` only CONDITIONALLY, depending on whether the signal happened to land after
collection had already populated `SOURCE_COVERAGE_JSON`. This is a real, permanent,
timing-dependent property of this one reason, not a bug and not further fixable — `/ccs` cannot
know in advance whether a given `interrupted` failure will carry it and must check the actual
response.

It is absent for `--base`/`--commit` scope, absent for every `--resume` round (success or failure
alike), and absent for `bad_args`/`git_error`/`incomplete_collection`/`resume_thread_not_found` —
confirmed directly by reading the wrapper: `SOURCE_COVERAGE_JSON` is only ever populated inside
the `--uncommitted` diff-collection branch (which a `--resume` call and a `--base`/`--commit`
call both skip entirely), and these four reasons each `printf`s its own JSON directly and exits
without ever reaching the shared `emit_final_output` helper that splices `coverage` into the
final JSON whenever `SOURCE_COVERAGE_JSON` is well-typed — `bad_args`/`git_error`/
`incomplete_collection` occur before or during collection itself, `resume_thread_not_found` on a
`--resume` call that skips the `--uncommitted` branch entirely — so none of these four can ever
carry `coverage` regardless of scope — see "Coverage is a Round-1-only property" below for what
this means for `/ccs`'s multi-round convergence check.

**Failure:** `{"ok":false,"reason":"<reason>","threadId":"<uuid or absent>","detail":"..."}`
— see "Coverage" just above for the 8 reasons among these that unconditionally can carry a
spliced-in `coverage.source` object, plus `interrupted`, which can carry one conditionally. Every
distinct `reason` this wrapper can emit, and whether `threadId`
is present (capture it whenever it is — it is what makes cleanup of a partially-started thread
possible even after a failed round):

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

## Investigation evidence capture (opt-in via `--capture-evidence`)

**Off by default.** Full mechanics live in `references/capture-evidence.md`, read only when this
session actually uses `--capture-evidence`.

**Once Phase 0 Step 0 determines capture is ON for this session, your very next action — before
doing anything else in this run — is to Read `codex-stream-review/skills/ccs/references/capture-evidence.md`
in full.** That file's procedure is required at no fewer than four later points in this run (Phase
1 Step 0's `EVENTLOG_FILE` allocation, Step 1's `--capture-eventlog` flag, Phase 2's extraction
step, Guards' retry-time eventlog handling) — proceeding without having read it first will leave
those points undocumented for this session. If capture is OFF for this session, never read this
file and never touch anything it describes — zero behavior change from every other place in this
skill.

---

## Sentinel-file safe-read idiom

`--focus`, `--cwd`, and the resolved plugin install path all get built into a shell command
string from values Claude does not fully control character-by-character (pasted content, a
resolved filesystem path). Interpolating any of them directly into a double-quoted argument is
exploitable — a value containing an embedded `"` followed by shell metacharacters breaks out of
the intended argument and executes as a second statement. The fix is a file-plus-sentinel idiom —
apply it consistently, everywhere in this file:

- Resolve/compose the value, then write it to a `mktemp`-allocated file with a trailing literal
  `x` sentinel appended directly after it, no newline in between: `{ <producing-command>; printf
  'x'; } > "$FILE"` for a shell-resolved value (using `jq -j`, never `jq -r`, and `printf '%s'
  "$PWD"`, never `$(pwd)`, since `$(...)` unconditionally strips every trailing newline from its
  output — a bare `$(jq -r ...)`/`$(pwd)` could silently lose a real trailing newline that's part
  of the actual value, e.g. a path that legitimately ends in one), or the
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

**Step 0 (run first, before item 1, on every invocation — regardless of whether this session ends
up using `--capture-evidence` at all):**

- **Unconditional stale-eventlog sweep (best-effort):** a best-effort sweep for orphaned raw
  event-log files left behind by a past, interrupted `--capture-evidence` session:
  ```bash
  find /tmp -maxdepth 1 -name 'ccs-*-round-*-eventlog.jsonl*' -mmin +60 -delete
  ```
  Running this on EVERY `/ccs` invocation — capture-enabled or not — is what makes the cleanup
  bound honest: an orphaned eventlog is removed no later than the start of the very next `/ccs`
  invocation of any kind, at least 60 minutes after being orphaned. 60 minutes is safe because an
  eventlog is only ever in use for one round's wrapper call, capped at 1800s (30 min, the
  wrapper's own default `--timeout`) — a genuinely in-use eventlog can never reach the 60-minute
  mark, so this sweep can never delete a file another running session still needs. Whether it
  deletes something, deletes nothing, or fails outright, proceed without noting it. **This sweep
  does NOT match `REPO_ROOT_FILE`/`INSTALL_PATH_FILE`** — those are meant to stay alive for a
  session's entire multi-round run (which can exceed 60 minutes of real elapsed time), so a
  shared cross-session age-based sweep would risk deleting a different, still-running session's
  own tracking files; those are cleaned up via LOCAL, immediate `rm -f` calls at Phase 3 and at
  each of Phase 0's own early-exit points instead.
- **Capture-evidence decision:** check whether the task text this skill was actually invoked with
  (or empty, to review the work just done, per "Usage" above) starts with the literal prefix
  `--capture-evidence `
  (note the trailing space), or is exactly the string `--capture-evidence` with nothing after it.
  If either is true, **capture is ON for this session** — treat the remainder after that prefix as
  the effective task text for every rule below and everywhere else in this file. If the prefix is
  not present, **capture is OFF for this session** — the task text is used exactly as given, and
  everything below proceeds precisely as documented elsewhere in this file with no added behavior.
  Either way, this is a one-time decision Claude makes now and remembers for the whole run — every
  later place in this file that gates on "capture is on/off" means Claude already knows the answer
  and must write the concrete literal branch (e.g. either include the `--capture-eventlog "<path>"`
  argument as literal text on every dispatch, or omit it entirely; either include or omit the
  `investigation_evidence` JSONL field) into each command it actually constructs — there is no
  shell variable carrying this decision between tool calls, and no per-round re-check within one
  `/ccs` run.

1. **Session id:** `SESSION_ID="$(date +%Y-%m-%dT%H%M%S)-$$"` — timestamp plus the invoking
   shell's PID (the PID suffix is required: a bare-second-resolution
   timestamp collides across two invocations started in the same second). Qualifies every
   temp-file path and the review-history log path for the rest of the run.

2. **Resolve this plugin's own install path**, keyed `codex-stream-review@youzooyou-plugins`:
   ```bash
   INSTALL_PATH_FILE=$(mktemp "/tmp/ccs-${SESSION_ID}-install-path.txt.XXXXXX")
   { jq -j '.plugins["codex-stream-review@youzooyou-plugins"][] | select(.scope=="user") | .installPath' ~/.claude/plugins/installed_plugins.json; printf 'x'; } > "$INSTALL_PATH_FILE"
   INSTALL_PATH="$(cat "$INSTALL_PATH_FILE")"; INSTALL_PATH="${INSTALL_PATH%x}"
   if [ -z "$INSTALL_PATH" ] || [ ! -x "$INSTALL_PATH/scripts/run-ccs-review.sh" ]; then
     echo "codex-stream-review@youzooyou-plugins is not installed, or is missing run-ccs-review.sh (a stale/incomplete install) — run /plugin install codex-stream-review@youzooyou-plugins (or update it)" >&2
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

4. **Determine the ARTIFACT:**
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
     GIT_BIN="$(command -v git)"
     SANITIZE_HOME=$(mktemp -d)
     env -i "PATH=/usr/bin:/bin" "HOME=$SANITIZE_HOME" "GIT_CONFIG_NOSYSTEM=1" \
       "$GIT_BIN" -C "$REPO_ROOT" -c core.fsmonitor= status --short --untracked-files=all
     if env -i "PATH=/usr/bin:/bin" "HOME=$SANITIZE_HOME" "GIT_CONFIG_NOSYSTEM=1" \
       "$GIT_BIN" -C "$REPO_ROOT" -c core.fsmonitor= rev-parse --verify -q HEAD >/dev/null 2>&1; then
       DIFF_BASE="HEAD"
     else
       DIFF_BASE="$(env -i "PATH=/usr/bin:/bin" "HOME=$SANITIZE_HOME" "GIT_CONFIG_NOSYSTEM=1" \
         "$GIT_BIN" -C "$REPO_ROOT" -c core.fsmonitor= hash-object -t tree /dev/null)"
     fi
     env -i "PATH=/usr/bin:/bin" "HOME=$SANITIZE_HOME" "GIT_CONFIG_NOSYSTEM=1" \
       "$GIT_BIN" -C "$REPO_ROOT" -c core.fsmonitor= diff --no-ext-diff --no-textconv "$DIFF_BASE"
     rm -rf "$SANITIZE_HOME"
     ```
     Never `git add -N`, which mutates the index. Confirmed the anchor/sanitize step is genuinely
     needed even this early: `env GIT_DIR="<real-repo>/.git" GIT_WORK_TREE="<real-repo>" bash -c
     'cd /tmp; git status --short'` reports the REAL repository's changes despite running from an
     unrelated directory — an unsanitized artifact-detection step could therefore review, or
     silently conclude there is nothing to review in, the wrong repository entirely, before Phase 1
     or any later protection ever runs. **The `env -i`/`-c core.fsmonitor=` wrapping around each
     call is the same isolation `git_safe()` already uses inside `run-ccs-review.sh`** (see
     `scripts/lib/git-safe.sh`) — applied here because this step runs directly in Claude's own
     dispatched shell, outside the wrapper, so it cannot call that internal bash function and must
     replicate the same pattern by hand. `GIT_BIN` is resolved via `command -v git` in this same
     trusted call, before anything else runs, so a hostile `PATH` introduced later in the same
     process (e.g. by something reachable from repo content) cannot redirect execution to a decoy
     `git` — exactly `git_safe()`'s own reasoning for pre-resolving its binary path once, up front.
     `SANITIZE_HOME` is a throwaway directory scoped to this one command only — created and removed
     within the same call, never a session-scoped fact like `FAKE_GIT_HOME`/`CLEAN_REPO_DIR`, since
     nothing later needs to reuse it.
   - **If the material to review isn't a repo diff at all, but there IS real content to review
     (a pasted plan, generated text, analysis text that actually exists — just with no git diff to
     point to): this is a genuine non-repo-artifact review**, handled via the `CLEAN_REPO_DIR`
     mechanism (full operational detail below).
   - **If there is still nothing concrete at all** — no task, no identifiable prior-session work,
     no uncommitted changes, AND no other real content to paste as a non-repo artifact either —
     **do NOT create `CLEAN_REPO_DIR` and do NOT dispatch a round with nothing to review.** Clean
     up and stop instead: run
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
     `/etc/gitconfig` is never read) — the same `env -i` allowlist pattern this project's own
     git-isolation code already uses elsewhere (see `scripts/lib/git-safe.sh`'s `git_safe()`
     helper, referenced again below).

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
     diff there — an earlier revision of this fix seeded a placeholder commit,
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
     exactly one group (`GROUP="main"`) against `CLEAN_REPO_DIR`.

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
(the sizing heuristic below is needed because `run-ccs-review.sh` has no file-filter flag of its
own):

```bash
REPO_ROOT_FILE="<literal REPO_ROOT_FILE path resolved once in Phase 0>"
REPO_ROOT="$(cat "$REPO_ROOT_FILE")"; REPO_ROOT="${REPO_ROOT%x}"
for _v in $(git rev-parse --local-env-vars 2>/dev/null || printf '%s\n' GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_CONFIG GIT_CONFIG_PARAMETERS GIT_CONFIG_COUNT GIT_OBJECT_DIRECTORY GIT_DIR GIT_WORK_TREE GIT_IMPLICIT_WORK_TREE GIT_GRAFT_FILE GIT_INDEX_FILE GIT_NO_REPLACE_OBJECTS GIT_REPLACE_REF_BASE GIT_PREFIX GIT_SHALLOW_FILE GIT_COMMON_DIR) GIT_CONFIG_GLOBAL GIT_CONFIG_SYSTEM GIT_TEMPLATE_DIR; do
  unset "$_v"
done
GIT_BIN="$(command -v git)"
SANITIZE_HOME=$(mktemp -d)
if env -i "PATH=/usr/bin:/bin" "HOME=$SANITIZE_HOME" "GIT_CONFIG_NOSYSTEM=1" \
  "$GIT_BIN" -C "$REPO_ROOT" -c core.fsmonitor= rev-parse --verify -q HEAD >/dev/null 2>&1; then
  DIFF_BASE="HEAD"
else
  DIFF_BASE="$(env -i "PATH=/usr/bin:/bin" "HOME=$SANITIZE_HOME" "GIT_CONFIG_NOSYSTEM=1" \
    "$GIT_BIN" -C "$REPO_ROOT" -c core.fsmonitor= hash-object -t tree /dev/null)"
fi
{ env -i "PATH=/usr/bin:/bin" "HOME=$SANITIZE_HOME" "GIT_CONFIG_NOSYSTEM=1" \
    "$GIT_BIN" -C "$REPO_ROOT" -c core.fsmonitor= diff --name-only "$DIFF_BASE"
  env -i "PATH=/usr/bin:/bin" "HOME=$SANITIZE_HOME" "GIT_CONFIG_NOSYSTEM=1" \
    "$GIT_BIN" -C "$REPO_ROOT" -c core.fsmonitor= ls-files --others --exclude-standard
} | sort -u | wc -l
rm -rf "$SANITIZE_HOME"
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

**Every git invocation above is also wrapped in `env -i "PATH=/usr/bin:/bin" "HOME=$SANITIZE_HOME"
"GIT_CONFIG_NOSYSTEM=1" ... -c core.fsmonitor=`** — the same isolation `git_safe()` already
applies inside `run-ccs-review.sh` (see `scripts/lib/git-safe.sh`), replicated here by hand because
this sizing step runs directly in Claude's own dispatched shell, outside the wrapper, and cannot
call that internal bash function. This closes a real gap the `unset`-based sanitization alone
cannot: it removes redirected repository/worktree discovery and command-scope config injection,
but does nothing about a repo-local `.git/config` declaring `core.fsmonitor` — a real, common
developer setting (not just an attacker scenario) that git will still execute as a subprocess
regardless of how clean the surrounding environment is. Confirmed directly: a plain `git diff`
against a repo with `core.fsmonitor` configured executes that hook; the same call wrapped in this
`env -i`/`-c core.fsmonitor=` pattern does not. `GIT_BIN` is resolved via `command -v git` before
any of this runs, exactly like `git_safe()`'s own reasoning, so a hostile `PATH` introduced later
in this same process cannot redirect execution to a decoy `git`. `SANITIZE_HOME` is scoped to this
one command only (created and removed within it), never a session-scoped fact.

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
GIT_BIN="$(command -v git)"
SANITIZE_HOME=$(mktemp -d)

# --base <ref>:
env -i "PATH=/usr/bin:/bin" "HOME=$SANITIZE_HOME" "GIT_CONFIG_NOSYSTEM=1" \
  "$GIT_BIN" -C "$REPO_ROOT" -c core.fsmonitor= diff --no-ext-diff --no-textconv --name-only "<ref>...HEAD" | wc -l

# --commit <sha>: mirror the wrapper's own merge-vs-non-merge branch, never just one or the other
PARENT_COUNT="$(env -i "PATH=/usr/bin:/bin" "HOME=$SANITIZE_HOME" "GIT_CONFIG_NOSYSTEM=1" \
  "$GIT_BIN" -C "$REPO_ROOT" -c core.fsmonitor= show -s --format=%P --no-ext-diff --no-textconv "<sha>" 2>/dev/null | wc -w | tr -d ' ')"
if [ "$PARENT_COUNT" -ge 2 ]; then
  env -i "PATH=/usr/bin:/bin" "HOME=$SANITIZE_HOME" "GIT_CONFIG_NOSYSTEM=1" \
    "$GIT_BIN" -C "$REPO_ROOT" -c core.fsmonitor= diff --no-ext-diff --no-textconv --name-only "<sha>^1" "<sha>" | wc -l
else
  env -i "PATH=/usr/bin:/bin" "HOME=$SANITIZE_HOME" "GIT_CONFIG_NOSYSTEM=1" \
    "$GIT_BIN" -C "$REPO_ROOT" -c core.fsmonitor= show --no-ext-diff --no-textconv --name-only --format= "<sha>" | wc -l
fi
rm -rf "$SANITIZE_HOME"
```
Same `-C "$REPO_ROOT"` anchoring, sanitization loop, AND `env -i`/`-c core.fsmonitor=` isolation as
the `--uncommitted` sizing command above, for the identical reason — never a bare `git` call in
these either.
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
parallel mode — fixed per concurrently-dispatched group this round. Run this block once per group
(once, for `GROUP="main"`, in the common single-reviewer case):

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

**A 5th temp file, `EVENTLOG_FILE`, joins this same block only when capture-evidence is ON for
this session** (Phase 0 Step 0's decision) — see `references/capture-evidence.md` for its
exact template and how it's consumed; omitted entirely, every round, when capture is OFF.

`GROUP` is baked into the `mktemp` *template* (not just the random suffix) — the
session+round+group triple prevents cross-session/cross-group confusion; `mktemp`'s own suffix
prevents same-round-same-group path guessing. Applies identically to fresh (round 1) and resumed
(round 2+) dispatch — only the wrapper flags at Step 1 differ. This is a cosmetic behavior change
to the single-reviewer path too (`main` now appears in every temp-file path where it didn't
before) — harmless, since these are ephemeral per-run files cleaned up at the end of each round
(Phase 2 step 6) regardless of naming.

**Why `ERR_FILE` is separate from `OUT_FILE`.** `run-ccs-review.sh` prints the early
`THREAD_ID=<uuid>` signal on **stderr** the moment a thread starts (or immediately, on a resumed
round) — well before the round's final JSON appears on stdout. `/ccs` keeps this stream separate from stdout's clean JSON, exactly as `stream-review`'s
own SKILL.md documents ("redirect stdout and stderr to SEPARATE files") — any wrapper-emitted
stderr noise (there is none in normal operation today, but the separation costs nothing and
matches the sibling skill's own convention) never contaminates the JSON parse. This
reasoning applies identically per group — each dispatched group has its own `OUT_FILE`/`ERR_FILE`
pair (Step 0 above), so each group's early `THREAD_ID` signal and final JSON are separated from
every other group's, never just from each other within one group's own pair.

Then, using the Write tool (never a shell redirect — see the sentinel idiom above), write this
round's `--focus` text plus a trailing `x` sentinel into that group's own `FOCUS_FILE`:
- **Round 1:** Why (the actual problem this task addresses) / Scope (what to specifically verify
  given what this diff touches) — there is no History yet. Fold in a `⚠️ SCOPE
  CONSTRAINT` block (do not open `node_modules/`/`.pnpm/`/vendor
  directories; limit reads to source dirs and the diff itself) — this is caller-supplied text,
  `run-ccs-review.sh`'s own prompt template does not add it for you. **State the collaboration
  frame in this same Round-1 `--focus` text too**: Claude
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
    doc, plan, or analysis text itself — directly into this same `--focus` text.
    `CLEAN_REPO_DIR` (Phase 0 step 4) guarantees an empty diff
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
# Phase 0 step 4 for the full reasoning). This does NOT protect the wrapper's own internal
# diff/show/rev-parse/hash-object calls -- those already run through git_safe() (see
# scripts/lib/git-safe.sh), which is immune to whatever this dispatching shell hands it (its own
# env -i wipes the inherited environment before git ever runs). What this sanitization actually
# protects is different: run-ccs-review.sh launches `codex exec`/`codex exec resume` itself inside
# a plain `cd "$CWD"` subshell with no isolation of its own (confirmed directly,
# scripts/run-ccs-review.sh's dispatch subshell) -- so that subprocess, and any git command Codex
# runs during its own investigation inside it, inherits whatever environment this dispatching
# shell passes down. A leaked GIT_DIR/GIT_WORK_TREE here would not corrupt the wrapper's own
# collection, but it could redirect Codex's own investigation-time git commands to the wrong
# repository:
for _v in $(git rev-parse --local-env-vars 2>/dev/null || printf '%s\n' GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_CONFIG GIT_CONFIG_PARAMETERS GIT_CONFIG_COUNT GIT_OBJECT_DIRECTORY GIT_DIR GIT_WORK_TREE GIT_IMPLICIT_WORK_TREE GIT_GRAFT_FILE GIT_INDEX_FILE GIT_NO_REPLACE_OBJECTS GIT_REPLACE_REF_BASE GIT_PREFIX GIT_SHALLOW_FILE GIT_COMMON_DIR) GIT_CONFIG_GLOBAL GIT_CONFIG_SYSTEM GIT_TEMPLATE_DIR; do
  unset "$_v"
done

# Capture-evidence is a Phase 0 Step 0 decision Claude already knows, not a live variable (see
# that section and references/capture-evidence.md) -- if ON for this session, literally
# include --capture-eventlog "<this group's literal EVENTLOG_FILE from Step 0>" as concrete text
# in this same dispatch call (both the fresh and the resume form below); if OFF, literally omit
# the flag entirely. Never write this as a variable-gated bash branch for a later call to
# evaluate -- write the actual resulting command, one way or the other, by hand, every round.

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
same turn — one Bash `run_in_background: true` invocation per group ("run each group's call at the
same time → wait for all → synthesize"). The single-reviewer case is simply N=1 of this same loop,
not a separate branch.

**Why this dispatch call itself needs no additional `core.fsmonitor` guard.** The `unset`-based
sanitization just above protects against redirected repository/worktree discovery and
command-scope config injection for this dispatching shell — but it does not need to also disable
`core.fsmonitor`, because the actual diff/show collection this dispatch triggers happens INSIDE
`run-ccs-review.sh`, not in this shell: the wrapper sources `scripts/lib/git-safe.sh` and routes
every one of its own internal git calls (diff/show/rev-parse/hash-object) through that file's
`git_safe()` helper, which already runs under `env -i` with an isolated `HOME`,
`GIT_CONFIG_NOSYSTEM=1`, and `-c core.fsmonitor=` — confirmed directly (`scripts/lib/git-safe.sh`)
and live (a repo-local `core.fsmonitor` hook does not execute when collected through `git_safe()`,
though it does execute under a plain, unwrapped `git diff` against the same repo). An earlier
revision of this section conflated this dispatch's own sanitization with the wrapper's internal
collection and incorrectly described the wrapper's collection as still vulnerable — it is not; see
`scripts/lib/git-safe.sh` for the current mechanism. **The real gap this file used to leave open
was two OTHER git call sites that run directly in Claude's own dispatched shell, never through
`run-ccs-review.sh` at all** — the sizing commands in "Determine review mode" above and the
fallback-artifact-detection commands in Phase 0 step 4 — since those cannot invoke `git_safe()`
(a bash function local to the wrapper's own process). Both now carry the identical
`env -i`/`-c core.fsmonitor=` isolation applied by hand; see those two sections for the exact
commands and the live confirmation that a repo-local `core.fsmonitor` hook does not fire through
them either.

**`GROUP_THREADS` — the ordered set of `(GROUP, THREAD_ID)` pairs.** Established once, right after round 1's dispatched groups' results are each parsed in
Phase 2 step 1 below — every group's own JSON response carries its `threadId` whenever one exists
(the reason table above shows exactly which failure reasons do), whether that round succeeded or
failed, so no earlier capture step is needed. Remembered by Claude as a literal fact for the rest of the run, the same way a
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
time, on every round after the first. As explained in Phase 1 Step 1's own dispatch block above,
this does not protect the wrapper's internal collection (already safe via `git_safe()`) — it
protects `codex exec`/`codex exec resume` itself, which the wrapper launches inside a plain
`cd "$CWD"` subshell with no isolation of its own, so a leaked `GIT_DIR`/`GIT_WORK_TREE` here could
redirect Codex's own investigation-time git commands to the wrong repository (the user's real one,
not `CLEAN_REPO_DIR`) instead.
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

A PID-plus-start-time watcher, reusing that group's own `PID_FILE`,
dispatched as an independent `Monitor` call right after that group's Step 1 dispatch. **One
independent `(GROUP, PID_FILE)` `Monitor` call per group** this round — N concurrent watchers for a
parallel round; the
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
defense-in-depth secondary signal, not the primary completion mechanism.

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
   unchanged, with `groups[]` omitted entirely. **If capture-evidence is ON for this session**,
   also run `references/capture-evidence.md`'s steps 2-4 now, per dispatched group (extract via
   `jq`, merge across groups if this was a parallel round, delete the raw eventlog) — the
   resulting `investigation_evidence` object is one more field on this same round's line. Then
   append this round's line to the review history log (below), best-effort. Clean up this round's
   now-unneeded `.pid`/`-out.json`/`-err.log`/`-focus.txt` temp files for EVERY dispatched group —
   nothing needs to read any of them again once the round is logged. (The `-eventlog.jsonl` temp
   file, when one was allocated, is already gone by this point — deleted as part of the capture
   steps just run, not part of this cleanup list.)

### Coverage is a Round-1-only property

Since only a fresh `--uncommitted` dispatch ever reports `coverage.source` — regardless of
whether that particular dispatch attempt resulted in `ok:true`, one of the 8 unconditionally-
eligible post-dispatch failure reasons, or a conditionally-eligible `interrupted` (see "Coverage"
in the interface reference above) — and only round 1 is ever a
fresh round in `/ccs` (round 2+ is always `--resume`, which never reports it either way), the
coverage-completeness gate below is a property of **round 1's own log line**, not "the latest
round's." Record round 1's `coverage_source` once — captured from whichever of round 1's dispatch
attempts for that group actually carried it (ordinarily its one successful attempt, but see the
Guards' resume-safe-retry capture note below for the case where an earlier FAILED attempt is the
one that carried it) — and carry that determination forward through the rest of the loop; it is
never re-collected on a resumed round.

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
`--uncommitted` call and reports its own separate `coverage.source` outcome — from whichever of
that group's round-1 attempts actually carried it, per the capture note above. Combine every
dispatched group's own outcome: the round's overall `coverage_source.status` is `"complete"`
**only if every dispatched
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
  top-level summary.** A
  single-reviewer round has only one group's findings to begin with, so this adds no extra work
  there — it only matters once more than one group is actually dispatched. A group that returned
  `"ok":false` has no `findings` array to re-verify at all — per the Guards' extended "Empty /
  failed review ≠ CLEAN" rule below, such a round is not eligible for `✅ CLEAN` until that group is
  successfully retried, regardless of how clean every other group's own findings turned out to be.
  **This holds every round, not only round 1** — see "Convergence logic across groups" below for
  why an individually-clean group does not exit the loop on its own cadence. **AND**
- **If round 1's scope was `--uncommitted`:** round 1's `coverage_source.status` (the ROUND-1
  N-group merged value when round 1 dispatched more than one group — see "Coverage is a
  Round-1-only property" above) — the wrapper's own `coverage.source` object verbatim, captured
  from whichever of round 1's dispatch attempts for that group actually carried it (ordinarily its
  `ok:true` response, but see the Guards' resume-safe-retry capture note below for the case where
  an earlier failed attempt is the one that carried it), or the sentinel
  `{"status":"unknown","omitted":[]}` only when NONE of round 1's dispatch attempts for that group
  ever carried `coverage.source` at all — is explicitly `"complete"`, never assumed. `"partial"`
  (real omitted files) or `"unknown"` fail this condition unless every omitted path has since been
  explicitly reviewed another way or explicitly accepted as out-of-scope by the user. For round 1
  scoped `--base`/`--commit`, this condition is automatically satisfied — those scopes never
  report coverage at all.
→ Stop the loop, go to Phase 3 as **✅ CLEAN**.

### Convergence logic across groups — round-level, all-groups-together (confirmed decision)

**A round converges only if every dispatched group is independently clean in that SAME round.**
An individually-clean group does **not** exit the loop early on its own cadence; it keeps being
resumed — with a lightweight "nothing new from your dimension, here's what changed elsewhere"
`--focus` (see "Per-group History construction" above) — until the WHOLE round converges. This is
round-level, all-groups-together convergence.

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
      nothing exists to resume — retry the same scope flag fresh, exactly once (include
      `--capture-eventlog` with its own fresh `EVENTLOG_FILE` when capture is ON, same as every
      dispatch — see `references/capture-evidence.md`). **If this is round 1 and the reason
      is `no_thread_started`, capture coverage from the failing attempt BEFORE dispatching that
      retry** — see the "Round 1 only — capture coverage from the failing attempt BEFORE
      retrying" note below; it applies here identically, even though `no_thread_started` never
      carries a `threadId` and so is always handled by this bullet rather than the
      threadId-captured one below it. If it fails again, stop — report **⚠️ COULD NOT VERIFY**.
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
    abandoning the thread.
    **Round 1 only — capture coverage from the failing attempt BEFORE retrying.** If this failure
    is for a group's round-1 attempt (the one dispatched with `--uncommitted`/`--base`/`--commit`,
    not an already-resumed round 2+ attempt) and the reason is one of the 8 post-dispatch reasons
    that unconditionally carry `coverage.source` whenever it was a fresh `--uncommitted` dispatch
    (`timeout`, `nonzero_exit`, `missing_task_complete`, `rollout_not_found`, `no_final_answer`,
    `invalid_json`, `schema_mismatch`, `no_thread_started` — see "Coverage" in the interface
    reference above), or the reason is `interrupted` (which carries it only conditionally,
    depending on signal timing — see that same section), check this failed response for a
    `coverage.source` object now, before dispatching the retry below. If present, capture that
    value as this group's round-1 `coverage_source` determination (per "Coverage is a
    Round-1-only property" above) and keep it — the `--resume` retry that follows never reports
    `coverage.source` itself (no `--resume` call ever does), so this failed response is the ONLY
    place this round's real coverage data can come from once a retry is needed. For `interrupted`
    specifically, `coverage.source` may genuinely be absent — if so, there is nothing to capture;
    proceed to the retry below and let the round-1 `coverage_source` determination fall back to
    the `{"status":"unknown","omitted":[]}` sentinel exactly as it would for any other
    coverage-absent round 1 (see "Coverage is a Round-1-only property" above). Skipping this
    capture for a failure that DID carry it would force the convergence gate to fall back to that
    same sentinel and block a clean `✅ CLEAN` verdict (see "Partial or unknown source coverage ≠
    CLEAN" below) even though the diff was, in fact, already fully collected on this first
    attempt — the eventual `ok:true` result coming from the `--resume` retry does not change that.
    (For a round-2+ resume-safe failure, there is nothing to capture here: that attempt was itself
    already a `--resume` call, so it never carried `coverage.source` in the first place.)
    Wait 5s, then — using the SAME sentinel-file `--focus` idiom every other
    dispatch in this file already uses, never a value interpolated directly:
    ```
    FOCUS_FILE="<a fresh mktemp'd path, written via the Write tool exactly like Phase 1 Step 0 --
    content is the SAME ⚠️ SCOPE CONSTRAINT block every round's --focus already requires, plus a
    short note: retrying after a <reason> failure -- please provide your review, plus the trailing
    x sentinel>"
    FOCUS_TEXT="$(cat "$FOCUS_FILE")"; FOCUS_TEXT="${FOCUS_TEXT%x}"
    # If capture-evidence is ON for this session, literally include --capture-eventlog "<a
    # freshly-mktemp'd EVENTLOG_FILE, same template as Phase 1 Step 0 -- NOT the original round's
    # already-consumed one>" here too -- this retry is its own separate codex exec process with
    # its own event log, exactly like every other dispatch call in this file (see
    # references/capture-evidence.md, including its multi-attempt handling note); omit the flag entirely
    # when capture is OFF, same rule as Step 1.
    "$INSTALL_PATH/scripts/run-ccs-review.sh" --cwd "$REPO_ROOT_OR_CLEAN_REPO_DIR" \
      --resume "<that threadId>" --timeout 300 \
      --focus "$FOCUS_TEXT"
    ```
    **Multi-attempt evidence handling (general rule, only relevant with capture-evidence ON —
    applies identically to every retry variant in this Guards section, resume or fresh):** when
    ANY retry for the same (round, group) ultimately succeeds (or is itself what a group's final
    `⚠️ COULD NOT VERIFY` outcome is based on), extract `investigation_evidence` from that LAST
    attempt's own `EVENTLOG_FILE` only — never an earlier, now-discarded failed attempt's — since
    the last attempt's result is what the round's own JSONL line actually reports. `rm -f` every
    EARLIER attempt's `EVENTLOG_FILE` too, without extracting from it, once the round concludes —
    a disclosed, deliberate simplification: any commands Codex ran during an earlier failed
    attempt before it failed are not merged into that round's evidence, only the final attempt's
    are. This keeps the merge model in `references/capture-evidence.md` to exactly one value
    per (round, group) rather than needing a second, attempt-level merge layer on top of the
    existing group-level one — and still closes the privacy contract (every allocated eventlog
    this session ever creates is deleted, extracted from or not), just narrows what gets reported
    into the log.
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
      of the original scope flag, for that group, abandoning the now-unrecoverable thread (this
      fresh retry gets its own new `--capture-eventlog`/`EVENTLOG_FILE` too, when capture is ON,
      same as every dispatch — see `references/capture-evidence.md`).
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
    - **Round 1:** retry the original scope flag fresh, exactly once, for that group (its own new
      `--capture-eventlog`/`EVENTLOG_FILE` too, when capture is ON — see
      `references/capture-evidence.md`) — append the now-confirmed-dead `(GROUP, threadId)` to `LEAKED_THREAD_IDS`
      (its rollout is already gone or unreachable, but the thread record itself may still need
      explicit `--cleanup` at the terminal path). If the fresh retry also fails, stop — report
      **⚠️ COULD NOT VERIFY**.
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

Claude is the sole writer/reader of this log — Codex never sees it.

**Location:** `~/.claude/plugins/data/codex-stream-review/ccs-logs/<repo-slug>/<session-id>.jsonl`
- `<repo-slug>`: the target repo's directory basename, lowercased, non-alnum → `-`.
- `<session-id>`: the literal `SESSION_ID` from Phase 0.
- Create owner-only, once per session: `umask 077 && mkdir -p ~/.claude/plugins/data/codex-stream-review/ccs-logs/<repo-slug>`
  — this log retains full `target.focus` text indefinitely; the
  ambient `umask` on this machine would otherwise leave it group/world-readable. Best-effort
  also retighten any pre-existing directory once per session:
  `chmod -R go-rwx ~/.claude/plugins/data/codex-stream-review/ccs-logs/<repo-slug> 2>/dev/null || true`.

**Line schema (one JSON object per round)** — `target`,
`codex_review`, `coverage_source`, `claude_verification`, `round_outcome`, and
`investigation_evidence` when capture-evidence is ON for this session (see
`references/capture-evidence.md`), plus `groups`, for a parallel round only, with one
`ccs`-specific addition (`thread_id`). `target.scope` also gains
one more legal value (`"resume"`) to describe what `/ccs` rounds 2+ actually do. **The common
case — a single-reviewer round (`GROUP="main"`), capture-evidence OFF — is completely unchanged
from before:** `target.focus`/`codex_review` stay single string/object values, `groups` is
omitted entirely, and so is `investigation_evidence`, exactly as shown below:

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

**With capture-evidence ON**, that same line gains one more sibling field,
`investigation_evidence` — see `references/capture-evidence.md`'s JSONL field section (you already
read this file per this session's capture-evidence decision above) for its exact shape and
omission rule.

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
- `finding_id`/`linked_finding_id`/`claude_verification[].action`: stable `f<n>` IDs incrementing
  across all rounds, `linked_finding_id` traces a
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
  `thread_id` is the durable backstop for
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
  **`investigation_evidence`, when capture-evidence is ON for this session, is still a single
  top-level sibling field on the round's line — never nested per-group inside `groups[]` itself.**
  Each dispatched group produces its own `INVESTIGATION_EVIDENCE_JSON` (see "Investigation
  evidence capture" above), but the round's single `investigation_evidence` field is always the
  one, already-merged-across-groups value from that section's step 3 — the same merge-once
  pattern already used for `coverage_source` above, not a second, independently-invented merge
  rule.

**Write:** append via `jq -nc` redirected with `>>`, `umask 077` restated immediately before
every append (a fresh Bash call each time — the earlier `mkdir`'s umask doesn't carry over).
Never overwrite or truncate.

**Read (continuity):** at the start of round R > 1, before building this round's History text,
query the log rather than relying on memory:
```bash
jq -c 'select(.round < 3)' ~/.claude/plugins/data/codex-stream-review/ccs-logs/<repo-slug>/<session-id>.jsonl
```
(substitute the actual current round number by hand — no live `$R` shell
variable survives into a separately-dispatched call).

**Failure isolation:** a log-write failure never aborts or degrades the round — note it once and
continue.

**Retention: kept indefinitely, no automatic cleanup — this is a completely separate policy from
the automatic Codex-thread cleanup below.** "Automatic cleanup" throughout this skill refers only
to deleting the ephemeral Codex thread and its rollout file under `~/.codex/sessions/` — never to
this JSONL audit log, which persists as a durable record.

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

3. **Clean up session-level temp files:**
   ```bash
   rm -f "<literal REPO_ROOT_FILE>" "<literal INSTALL_PATH_FILE>"
   # only if this session ever actually allocated them (most sessions never do — see Phase 0 step 4):
   rm -rf "<the exact literal CLEAN_REPO_DIR path, if one was allocated this session>"
   rm -rf "<the exact literal FAKE_GIT_HOME path, if one was allocated this session>"
   ```
   `FAKE_GIT_HOME` is allocated in the same lazy, one-time-per-session way as `CLEAN_REPO_DIR` (see
   Phase 0 step 4) and cleaned up alongside it here — never left behind once `CLEAN_REPO_DIR` no
   longer needs it.

### Final report (deliver this in Korean to the user — the only Korean output)

The section labels and content below are specified in English, per this project's rule that
documents injected into an agent stay English — translate every label and its content into
Korean when actually producing the report; none of the English text below is meant to reach the
user verbatim.

Structure:
- **Task/target summary** — what was done / what the artifact is.
- **Final artifact** — what changed (files/behavior).
- **Review method** — whether this was a single reviewer or parallel multi-reviewer (N groups,
  each group's review angle), the total round count, and **every thread ID used, broken out per
  group** (a single-reviewer run has one thread; parallel mode lists every group's own thread as
  `g1: <threadId>`, `g2: <threadId>`, … — never report just one as representative).
- **Round-by-round convergence table** — per round, `[Codex finding → re-verification result
  (accepted/rebutted + evidence) → action taken]`. For a parallel round, break out which group
  (dimension) found what.
- **Consensus status** — exactly one of: `✅ CLEAN (N rounds)` / `⚠️ NOT CONVERGED (hit the
  20-round cap, K unresolved)` / `⚠️ COULD NOT VERIFY (Codex review unavailable)` /
  `⚠️ PARTIAL COVERAGE (source coverage unresolved)`. If `COULD NOT VERIFY` in parallel mode, name
  which group.
- **Source coverage** — if round 1 was `--uncommitted` and its `coverage_source.status` (the
  N-group merged value in parallel mode) was ever `"partial"`/`"unknown"`, mention it regardless
  of the final outcome — which files were omitted, why, and whether it was resolved afterward.
- **Thread cleanup results (per group)** — for every group's final thread, whether `--cleanup`
  succeeded, and whether every `(group, thread)` pair in `LEAKED_THREAD_IDS` (left behind when a
  group's round-1 retry abandoned an earlier thread) was also successfully cleaned up — list every
  group's cleanup outcome with nothing omitted, and if any threadId failed to clean up, name which
  group's, which one, and why (this reflects `/ccs`'s own automatic thread cleanup at the end of
  every run).
- **Verified / unverified / remaining risks and assumptions** — be honest; never dress up
  something written but not run/verified as "done."

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
  above) — every group gets its own persistent, resumable thread for the whole run.
- **A change to any of `scripts/run-ccs-review.sh`, `scripts/lib/git-safe.sh`,
  `scripts/run-stream-review.sh`, or `scripts/collect_untracked_files.py` is automatically checked
  by `.github/workflows/codex-stream-review-ci.yml`** on every pull request touching
  `codex-stream-review/**` (any source branch) and on every push directly to `main` — ShellCheck (`--severity=warning`; two info-level findings, an SC1091
  relative-source-path note and an SC2329 false-positive on trap-invoked functions, are confirmed
  harmless and filtered out, real warnings/errors still fail the build), a `bash -n` syntax check,
  the `tests/test-run-ccs-review.sh` fixture suite, and `collect_untracked_files.py --selftest`.
  Reproduce the same checks locally before pushing:
  `shellcheck --severity=warning scripts/run-ccs-review.sh scripts/lib/git-safe.sh
  scripts/run-stream-review.sh` plus `bash tests/test-run-ccs-review.sh`. Neither ShellCheck nor
  the fixture suite replaces the other: ShellCheck catches quoting/expansion/control-flow hazards
  `bash -n` (syntax-only) cannot, while the fixture suite is the only thing that actually exercises
  the git-isolation behavior (`git_safe()`'s `env -i` allowlist, the collector's own isolated
  subprocess call) end to end — a lint-clean script can still be behaviorally wrong, and a
  behaviorally-passing script can still have a real quoting hazard ShellCheck would have caught on
  an input the fixture suite doesn't happen to exercise.
