---
name: ccd
description: Claude executes a task then runs a Codex cross-review loop (max 20 iterations) until consensus. Both agents are equal peers — findings are evidence-based, not automatically accepted. Large scope = multiple parallel reviewers. Final report only after mutual agreement.
---

# codex-direct-review:ccd — Claude + Codex Cross-Review Skill

**Usage:** `codex-direct-review:ccd <task description>` — this skill is not invocable as a bare
`/cc` or `/ccd` slash command; it is invoked plugin-qualified, like every other plugin-supplied
skill (see `codex-stream-review:ccs`'s own SKILL.md for the same pattern). Leave the task
description empty to review the work just done in this session.
Optional prefix: `codex-direct-review:ccd --capture-evidence <task description>` — opt-in investigation-evidence capture
for every round of this session (see "Investigation evidence capture" below). Omit it and `codex-direct-review:ccd`
behaves exactly as documented everywhere else in this file, with zero added fields anywhere.

Execute the given task, then reach fact-based consensus with Codex before reporting to the user — or until a hard cap of 20 rounds is hit.

---

## Core Principles — Equal Partnership (non-negotiable)

Claude and Codex are **equal peers**. Neither agent's findings are automatically authoritative.

- Codex reviews Claude's work → Claude must **verify each finding with facts and evidence** before acting.
- If Claude disagrees with a Codex finding, Claude **rebuts with reasoning and evidence** — Codex must respond.
- A finding is only valid when **both agents agree** based on evidence.
- Codex can be wrong (wrong path, stale assumption, misread context) — Claude must catch this.
- Claude can miss things — Codex exists to catch what Claude overlooks.
- **Converge by negotiation, not concession.** Never fake agreement; if a real disagreement survives, surface it honestly.
- **Report only a clean result** — or, if the 20-round cap is hit first, report the remaining disagreements honestly instead.

**Consensus = both agents have examined the evidence and reached the same conclusion.**

> These principles are also injected into Codex globally via `~/.codex/AGENTS.md` (§ Multi-Agent Collaboration), so both sides operate under the same equal-footing contract.

Equal partnership is the *depth* axis (challenge every finding, both directions, until real
agreement). Phase 2 step 3.5's whole-flow re-check is the *breadth* axis (after any fix, look at the
whole affected flow, not just the isolated lines) — both are required for the same reason: a review
that only checks the narrow thing just discussed, from only one side, converges to a false clean.

---

## Hard rules

### Language
- Everything exchanged with Codex (review requests, fixes summary, rebuttals) and all internal review/verification notes are in **ENGLISH**.
- Only the **FINAL report to the user is Korean**. Mid-round progress narration is English.

### Codex invocation: direct wrapper call, no subagent

The `codex-direct-review` plugin's install path was already resolved once, in Phase 0 Step 0, and
captured into `INSTALL_PATH_FILE` — a session-constant tracking file, remembered by its exact literal
`mktemp`-resolved path for the rest of the run, exactly like `REPO_ROOT_FILE`. (One narrow, documented
exception: a `/plugins-update`-driven retry after the capture-eventlog "Version requirement" failure
explicitly re-resolves this file rather than reusing the stale path — see that callout under
"Investigation evidence capture" below.) Every round, call its
wrapper via a **backgrounded Bash call**, substituting the install path through that file — captured via
`$(cat "$INSTALL_PATH_FILE")` with the trailing `x` sentinel stripped (see "Why the write side appends a
trailing x sentinel" below) — no `Agent` tool call, no `codex:codex-rescue`, no subagent relay of any
kind (Claude or otherwise), no `--resume`/`--fresh` distinction (each call is already a fresh, ephemeral
process, so there is nothing to resume).

```bash
# INSTALL_PATH_FILE is resolved once in Phase 0 Step 0 (alongside REPO_ROOT_FILE) and never
# re-allocated — the install path doesn't change mid-run. Do not re-run the jq lookup here, and do not
# expect a shell variable to have survived from Phase 0 Step 0's separate tool call: write in the
# actual resolved mktemp FILE path by hand, every round, then read its content via $(cat ...) and strip
# the trailing "x" sentinel that was appended on write (see "Why the write side appends a trailing x
# sentinel" below) — never a hand-typed literal install-path string. See "Why the focus text goes
# through a file" immediately below for why this file-based indirection is required.
INSTALL_PATH_FILE="<the exact literal mktemp-resolved install-path-file path from Phase 0 Step 0>"
# REPO_ROOT_FILE is resolved once in Phase 0 Step 0 (alongside INSTALL_PATH_FILE) and never
# re-allocated — the repo root doesn't change mid-run. See "Why --cwd goes through a file too"
# immediately below.
REPO_ROOT_FILE="<the exact literal mktemp-resolved repo-root-file path from Phase 0 Step 0>"
# FOCUS_FILE is pre-allocated via mktemp in the Liveness watcher's step 0 below, then populated with
# this round's actual focus text PLUS a trailing "x" sentinel (no newline in between, none after) using
# the Write tool (no shell involved in that step) — see "Why the focus text goes through a file"
# immediately below for why this indirection is required, and "Why the write side appends a trailing x
# sentinel" below for why FOCUS_FILE needs the exact same sentinel treatment as
# INSTALL_PATH_FILE/REPO_ROOT_FILE.
FOCUS_FILE="<the exact literal mktemp-resolved focus-file path from Liveness watcher step 0>"
INSTALL_PATH="$(cat "$INSTALL_PATH_FILE")"; INSTALL_PATH="${INSTALL_PATH%x}"
REPO_ROOT="$(cat "$REPO_ROOT_FILE")"; REPO_ROOT="${REPO_ROOT%x}"
FOCUS_TEXT="$(cat "$FOCUS_FILE")"; FOCUS_TEXT="${FOCUS_TEXT%x}"
"$INSTALL_PATH/scripts/run-codex-review.sh" --cwd "$REPO_ROOT" --uncommitted --focus "$FOCUS_TEXT"
```

**Non-repo artifact round?** Substitute the exact literal `CLEAN_REPO_DIR` path for `$REPO_ROOT` in the
`--cwd` argument above instead — never `$REPO_ROOT` for a genuine non-repo-artifact review. See "Always
give Codex the actual material to review" under "Liveness watcher" below for the full mechanism and why.

**Why the focus text — and the repo root passed to `--cwd` — go through a file, never interpolated
directly.** Never build `--focus` by
writing the review-prompt text straight into the command string as `--focus "<round's review prompt
text>"` — that text can include material Claude assembled from prior Codex findings, file contents, or
user-provided context that is not fully within Claude's control character-by-character. A focus value
containing an embedded `"` followed by shell metacharacters (e.g.
`normal"; printf "injected\n" >&2; #`) breaks out of the intended argument boundary and gets parsed as
a second, separate shell statement that actually executes — confirmed directly via `bash -n`. The safe
idiom instead: write the exact focus content, followed immediately by a trailing `x` sentinel with no
newline anywhere in between (see "Why the write side appends a trailing x sentinel" below for why
`FOCUS_FILE` needs this exactly like `REPO_ROOT_FILE`/`INSTALL_PATH_FILE`), into `FOCUS_FILE` using the
Write tool (a plain text file, zero shell involved in that step), then read it back with the sentinel
stripped — `FOCUS_TEXT="$(cat "$FOCUS_FILE")"; FOCUS_TEXT="${FOCUS_TEXT%x}"` — and pass it to the
wrapper as `--focus "$FOCUS_TEXT"`. The underlying safety property is the same either way: command
substitution used **inside** an already-open double-quoted string. This is safe because `$(...)`'s
output, once substituted inside that open double quote, is used as a single literal argument value:
bash does not word-split or otherwise re-parse the substituted content as shell syntax, and critically,
an embedded `"` character in the file's content cannot terminate the quote early, because which
characters close a quote is decided by the shell's parser *before* the substitution ever runs, not
after.

The identical exposure applies to `--cwd`: a crafted repo root path (e.g.
`repo"; printf "INJECTED\n" >&2; #`) breaks out of a directly-interpolated `--cwd "<repo root>"` exactly
the same way — confirmed directly. The fix is the same idiom, with one difference: the repo root is a
session-constant value, like the install path (see Phase 0 Step 0 item 4, which resolves it the same way
into `INSTALL_PATH_FILE`), not a per-round one like the focus text — so it is resolved and written into
`REPO_ROOT_FILE` exactly ONCE, in Phase 0 Step 0, never re-allocated per round the way `FOCUS_FILE` is
(see Phase 0 Step 0 below). Substitute it via
`REPO_ROOT="$(cat "$REPO_ROOT_FILE")"; REPO_ROOT="${REPO_ROOT%x}"` then `--cwd "$REPO_ROOT"` everywhere
`--cwd` is constructed, and the install path via
`INSTALL_PATH="$(cat "$INSTALL_PATH_FILE")"; INSTALL_PATH="${INSTALL_PATH%x}"` everywhere the wrapper
script path is constructed, and `FOCUS_FILE` the same way —
`FOCUS_TEXT="$(cat "$FOCUS_FILE")"; FOCUS_TEXT="${FOCUS_TEXT%x}"` then `--focus "$FOCUS_TEXT"` — the
trailing `${VAR%x}` strip is required for all three (see "Why the write side appends a trailing x
sentinel" immediately below); none of the three keeps the bare `$(cat "$FILE")` form with no sentinel to
strip. Apply this exact idiom everywhere in this file
that constructs a `--focus`, `--cwd`, or wrapper-path argument with real content — including the Liveness
watcher's primary dispatch block below. This is also why none of the three values is ever hand-retyped as
a
`VAR="<value>"` literal anywhere in this file: only a resolving command's own output (or, for
`FOCUS_FILE`, Claude's own Write-tool content), captured via
redirection (or the Write tool) with the trailing `x` sentinel appended, ever reaches these tracking files
(see Phase 0 Step
0 items 4 and 6 above, and the Liveness watcher's step 0 below) — the `$(cat "$FILE")`-plus-`${VAR%x}` safe-read idiom only protects the CONSUMING
side, so the WRITING side must never embed the raw value as a hand-typed literal in the first place, and
must always append the sentinel.

**Why the write side appends a trailing `x` sentinel, and the read side strips exactly one trailing `x`
— and why the producing command must never emit its OWN trailing newline before that sentinel.**
The safe-read idiom above closes the shell-injection exposure, but by itself it does not protect the
VALUE's own trailing bytes: bash command substitution `$(...)` unconditionally strips **every** trailing
newline character from its output, with no way to opt out. A path is not guaranteed to end in a
newline-safe character: a POSIX path is legally allowed to end in a literal newline byte (unusual, but
not invalid), and if the actual resolved repo root or install path ever legitimately ended that way, a
bare `$(cat "$FILE")` would silently strip it off — silently resolving `--cwd` or the wrapper path to a
shorter, WRONG location, with no error, just quietly wrong behavior. The fix is the same "x-sentinel"
idiom this project's own `codex-direct-review` plugin's eval harness (`eval/run_recall_eval.sh`) already
uses for exactly this class of problem: append a literal `x` character immediately after the captured
value, before it is ever written to the file, then strip exactly one trailing `x` back off via bash's
`${VAR%x}` parameter expansion when reading it back. Since the sentinel `x` is never itself a newline, it
is never eaten by `$(...)`'s newline-stripping, so it always round-trips intact regardless of how many
(if any) real trailing newlines the true value contains; `${VAR%x}` then removes exactly that one
sentinel character, restoring the original value byte-for-byte — PROVIDED the sentinel is appended
directly after the true value with nothing else in between.

This is the exact point an earlier revision of this fix got wrong, and it is worth stating plainly so it
is never reintroduced: `jq -r` and plain `pwd` both normally emit their result terminated by exactly one
newline of their OWN, as a general line-oriented-tool convention — that newline is not part of the
resolved path value at all, it is just how the tool signals "end of this line of output." If the sentinel
is appended straight after that command's raw output (`{ jq -r '...'; printf 'x'; }` or `{ pwd; printf
'x'; }`), the file on disk ends up holding `<value>\nx` — the tool's own newline now sits BEFORE the
sentinel, in the middle of the file's content rather than at its very end, so `$(...)`'s trailing-newline
stripping (which only ever looks at the true end of the captured text) has nothing left to strip once the
sentinel is in place, and `${VAR%x}` only removes the `x` — leaving that tool-added newline permanently
stuck onto the end of the value once the sentinel is gone. The result: `INSTALL_PATH`/`REPO_ROOT` end up
one newline byte too long, `test -x "$INSTALL_PATH/scripts/run-codex-review.sh"` and `cd "$REPO_ROOT"`
both fail, and every ordinary `codex-direct-review:ccd` round breaks immediately — confirmed live. The fix is to ensure the
sentinel is appended to the RAW VALUE with no producing-tool newline in between at all — either by using
a tool mode that never appends one, or by passing the value through something that already strips it:
- For `jq`, use `-j` (join, no per-value newline) instead of `-r` (raw, WITH a per-value newline) — this
  matches `eval/run_recall_eval.sh`'s own established convention for exactly this reason, not just by
  coincidence. `{ jq -j '.plugins[...] | .installPath' ...; printf 'x'; } > "$INSTALL_PATH_FILE"`.
- For the current directory, use the shell's own `$PWD` variable directly — `printf '%s' "$PWD"` — NOT
  `printf '%s' "$(pwd)"`. This distinction matters and was itself the subject of a caught regression:
  wrapping the `pwd` COMMAND in a nested `$(pwd)` does strip pwd's own line-terminator newline, but
  `$(...)`'s stripping is blanket — it removes EVERY trailing newline byte in what it captured, with no
  way to tell "this is pwd's own terminator" apart from "this is a literal newline that happens to be the
  actual last byte of the directory name" (a legal, if bizarre, POSIX pathname). For a hypothetical
  directory whose real path ends in a literal newline byte, `pwd`'s raw output would be that path's own
  trailing newline immediately followed by pwd's own terminator newline — TWO consecutive newlines at
  the very end — and `$(pwd)` strips BOTH, silently losing the path's own genuine trailing byte along
  with pwd's terminator. `$PWD`, by contrast, is not text this file's shell ever serializes through a
  stream at all — bash maintains it internally as an ordinary string variable (updated on every `cd`,
  from the same underlying `getcwd()`-style resolution `pwd` itself uses), so reading `"$PWD"` never
  passes through any newline-stripping text-substitution step in the first place — `printf '%s' "$PWD"`
  reproduces the exact byte sequence with no ambiguity, closing this gap completely rather than just
  narrowing it. `jq -j`'s redirect-based approach above has never had this problem for the same
  underlying reason: it also never routes its value through `$(...)`, writing its raw stdout bytes
  straight into the file via `>` instead.
- For `FOCUS_FILE`, Claude controls the content directly via the Write tool — there is no producing
  shell command in the middle at all, so there is no line-terminator-newline problem to route around the
  way `jq -r`/`pwd` have. But `FOCUS_FILE` has its OWN version of the same underlying problem: Phase 2
  step 1 explicitly requires pasting non-repo artifact content verbatim into the focus text ("for
  non-repo artifacts (analysis, generated text, a plan), paste the produced content into `--focus`"), and
  such pasted content can legitimately end in one or more real trailing newlines that are part of its
  actual formatting (e.g. a paragraph followed by a blank line) — exactly the kind of value-ending bytes
  a bare `$(cat "$FOCUS_FILE")` would silently and unconditionally strip, altering the pasted material
  before it ever reaches the wrapper. The fix is the identical sentinel idiom, just applied at the Write
  tool instead of a shell redirect: when Claude uses the Write tool to populate `FOCUS_FILE`, the content
  written is the intended focus text with a single literal `x` character appended directly after it, with
  no newline anywhere in between and none after the `x` — i.e. the file's actual on-disk content is
  `<focus text>x`. This can be done as one Write tool call (compose the focus text with the trailing `x`
  already appended) or, if the focus text was already written, a small separate follow-up edit that
  appends the `x` — either way, nothing else may sit between the true focus text and the sentinel.

With any of these three fixes, the file on disk holds exactly `<value>x` with no newline anywhere in
between, so `${VAR%x}` alone correctly restores the true value byte-for-byte. This is why, from here on,
every consumption site — including `FOCUS_FILE`'s — captures the file's content into a plain variable and
strips the sentinel first, rather than substituting `$(cat "$FILE")` directly inline into a command the
way earlier revisions of this file did — the inline form has nowhere to apply the `${VAR%x}` strip.
`FOCUS_FILE` is not exempt from this treatment: an earlier revision of this file reasoned that because it
holds Claude-composed prompt text rather than a `pwd`/`jq`-resolved filesystem path, it couldn't lose a
meaningful trailing newline — that reasoning missed the pasted-non-repo-artifact case above, where a real,
meaningful trailing newline (or several) can legitimately be part of the content. `FOCUS_FILE` therefore
uses the exact same `FOCUS_TEXT="$(cat "$FOCUS_FILE")"; FOCUS_TEXT="${FOCUS_TEXT%x}"` read idiom as
`INSTALL_PATH`/`REPO_ROOT`, at every site that reads it.

Capture-evidence is a decision Claude makes ONCE in Phase 0 Step 0 and remembers for the rest of the
run — it is never a live shell variable a later, separately-dispatched tool call could read back (see
Phase 0 Step 0 for why: each Bash/Monitor call gets a fresh shell, so nothing exported in one call
survives into the next). If capture was determined ON for this session, literally include
`--capture-eventlog "<path>"` as concrete text in this same call — whichever invocation form is used
this round, including the mktemp-based form in the Liveness watcher section below — using the exact
`mktemp`-resolved literal path Claude captured once for this round (see "Investigation evidence
capture" further down). If capture was determined OFF, literally omit the flag entirely. Never write
this as a variable-gated bash branch that a later tool call is expected to evaluate — write the actual
resulting command, one way or the other, by hand. See "Investigation evidence capture" further down
for the full per-round (and per-group, in parallel mode) path convention, extraction step, and
mandatory cleanup.

Run this exact command via the Bash tool with `run_in_background: true`. It returns immediately
without blocking — a round can legitimately run up to the wrapper's own timeout (currently 1800s),
so stay available to the user in the meantime rather than sitting idle. When the background task
completes (a notification arrives, or you check it), its captured stdout is the wrapper's
single-line JSON — read it directly and verbatim. **Never route this call through a subagent**
(including `runner`): the wrapper already emits exactly one clean JSON line, so a relay layer adds
no value and only risks reintroducing the paraphrase/summarization failure class this whole design
exists to eliminate.

The install-path empty check (the sentinel-stripped `$(cat "$INSTALL_PATH_FILE")` read) already happened
once, in Phase 0 Step 0 — if it was empty, the run stopped there, before Phase 2 (or any round) ever started, and the user was told to
install the plugin rather than silently falling back to `codex:codex-rescue`. There is no per-round
re-check here.

Parse the wrapper's single-line JSON stdout (from the completed background task):
- `"ok":false` → this round's Codex call failed outright (see `reason`/`detail`). This is a failed
  round, not a clean round — retry once per the existing "Empty / failed review ≠ CLEAN" rule below,
  then report `⚠️ COULD NOT VERIFY` if it fails again.
- `"ok":true` → `verdict.verdict` and `verdict.findings` are this round's Codex output. Proceed to
  the existing re-verification step (Claude checks each finding against evidence) unchanged.
- **Check for a top-level `coverage.source` object and reconcile it against this round's scope** —
  present only for `--uncommitted` scope; legitimately absent for `--base`/`--commit` (mirrors how the
  sibling `codex-direct-review` plugin's own single-shot `codex-review` skill already handles this same
  field). For an `--uncommitted`-scope round specifically, there are three distinct cases:
  - `coverage.source.status` is `"complete"` — genuinely fine, satisfies the coverage requirement,
    nothing extra to do here.
  - `coverage.source.status` is `"partial"` — some uncommitted files were not fully reviewed (reasons:
    `symlink`, `not_regular_file`, `over_size_limit`, `binary`, `unreadable`) — record
    `coverage.source.omitted` (each entry's `path` + `reason`) as this round's `coverage_source` field
    in the JSONL log line verbatim (see "Review history log" below) and narrate it plainly this round
    (e.g. "⚠️ Source coverage partial: N file(s) not fully reviewed").
  - `coverage.source` is **absent entirely** from an otherwise-successful (`"ok":true`) `--uncommitted`
    response — this is NOT the same as "nothing to report." The installed wrapper normally emits
    `coverage.source` for `--uncommitted` scope; an absence here means its own internal
    coverage-collection sidecar failed or produced something malformed and it silently dropped the
    whole object — there is no error, just a missing field. Treat this the SAME way as `"partial"` for
    convergence-gating purposes (coverage status is UNKNOWN, not verified complete — see "Convergence =
    100% CLEAN" below), narrate it plainly this round (e.g. "⚠️ Source coverage unknown: wrapper omitted
    coverage.source for an --uncommitted round"), and record it as this round's `coverage_source` field
    using the explicit sentinel `{"status": "unknown", "omitted": []}` — deliberately distinct from a
    real `"partial"` value, so a later reader of the JSONL log can tell "genuinely absent from the
    wrapper" (`status: "unknown"`, empty `omitted`) apart from "wrapper reported partial with a real
    omitted list" (`status: "partial"`, populated `omitted`).

  **A `"CLEAN"` `verdict.verdict` on a round whose coverage is `"partial"` OR `"unknown"` does NOT by
  itself justify declaring `✅ CLEAN`** — a code-level clean verdict on a partial-or-unknown-coverage
  scope is not the same claim as a clean verdict on the full requested scope; see "Convergence = 100%
  CLEAN" below for the added gating condition.

  For `--base`/`--commit` scope, `coverage` is legitimately absent from the wrapper's response — that
  remains the sibling `codex-review` skill's own established convention, unchanged here: there is
  nothing extra to do, and no `coverage_source` field is written to the JSONL line for that round at
  all. The "absent = unknown, treat like partial" rule above applies specifically to `--uncommitted`
  scope, where coverage is normally expected — never to `--base`/`--commit`, where it never is.
- **Merging multiple groups' coverage into one value — parallel mode only.** Phase 1's parallel mode can
  dispatch more than one group within the same round (see Phase 1 below), each running its own separate
  `--uncommitted` wrapper call and therefore reporting its own separate `coverage.source` outcome per the
  three cases above. The review history log's schema (see "Review history log" below) has exactly ONE
  `coverage_source` field per ROUND — exactly the same one-field-per-round constraint the
  `investigation_evidence` merge rule in "Investigation evidence capture" step 3 below already handles for
  a different field — so this needs the identical two-case treatment. **Common case — a single-reviewer
  round (`GROUP="main"`): there is nothing to merge.** That group's own coverage outcome from the three
  cases above is used directly, unchanged, as this round's final `coverage_source` value — skip the rest
  of this bullet entirely. **Only when this round actually dispatched more than one group:** combine every
  dispatched group's own coverage outcome using the same worst-case-wins principle the `✅ CLEAN` gate
  itself requires (see "Convergence = 100% CLEAN" below) — the round's overall `coverage_source.status` is
  `"complete"` **only if every dispatched group's own status was `"complete"`**:
  - If every group reported `"complete"`, the merged result is `"complete"`.
  - Else if any group reported `"partial"` (with or without other groups also being `"unknown"`), the
    merged result is `"partial"`, with `omitted` set to the union of every `"partial"` group's own
    `omitted` list, **deduplicated by the `(path, reason)` pair** — e.g. in one `jq` call over each
    group's own `omitted` array:
    ```bash
    jq -s '[.[]] | flatten | unique_by(.path, .reason)' <<< "$GROUP1_OMITTED
    $GROUP2_OMITTED"
    ```
    (add one more line to the heredoc per additional `"partial"` group actually dispatched this round;
    equivalently, if the groups' `omitted` arrays are already concatenated into one array, a single
    `unique_by(.path, .reason)` over that array does the same thing.) This dedup step is required, not
    optional: since every group reviews the IDENTICAL full diff (see Phase 1 above — parallel mode
    varies only the review dimension, never the file subset), two or more groups skipping the exact same
    oversized/binary/symlink/unreadable file is the expected common case, not a rare edge case — a plain
    concatenation would then report that one skipped file once PER GROUP, inflating the round's reported
    omitted-file count by a multiple of the group count for no real reason. Dedup only collapses an entry
    that is IDENTICAL in both `path` and `reason` across groups; two groups reporting the same `path`
    with a genuinely different `reason` (not expected in practice, since a given file's
    skip-classification is deterministic, but not structurally impossible) are kept as two distinct
    entries. A concrete `"partial"` with real, deduplicated omitted paths is strictly more informative
    than the bare `"unknown"` sentinel, so `"partial"` wins whenever at least one group produced one.
  - Else (no group reported `"partial"`, but at least one reported `"unknown"` — including a group whose
    response omitted `coverage.source` entirely, see the third case above), the merged result is the
    `"unknown"` sentinel, `{"status": "unknown", "omitted": []}`.
  Never let one group's `"complete"` report stand in as the round's own `coverage_source` value while a
  sibling group in the SAME round was `"partial"` or `"unknown"` — that is precisely the silent-hiding gap
  this merge rule exists to close. A failure in this merge step follows the same best-effort discipline as
  the rest of this file (see "Investigation evidence capture" → "Failure isolation" below): note it once
  and record the merged `coverage_source` as the `{"status": "unknown", "omitted": []}` sentinel for that
  round rather than guessing — unlike the optional `investigation_evidence` field, `coverage_source` is
  always written for an `--uncommitted` round (see "Review history log" below), so a merge failure must
  still produce a value, and the honest one when the true combined coverage can't be determined is
  `"unknown"`, never a silently-assumed `"complete"`.
- If the capture-evidence flag is ON for this session (see Phase 0), immediately after parsing the JSON above —
  regardless of `"ok":true` or `"ok":false`, since even a failed round may have produced a partial
  event log worth extracting — run this round's investigation-evidence extraction and delete the raw
  event-log copy. See "Investigation evidence capture" below for the exact command and the privacy
  contract. Best-effort: an extraction failure or missing file is noted and skipped, never a reason to
  fail the round.

### Liveness watcher (defense in depth)

The background dispatch above relies on the harness's own "task finished" notification as the
primary channel. Add a second, fully independent detection channel — PID-plus-start-time liveness
polling, with zero dependency on that same notification mechanism — via a `Monitor` call started
right after dispatching each round.

0. **Pre-allocate this round's temp files first, via a quick, non-backgrounded Bash call.** `GROUP`
   is `main` for a single-reviewer round, or that group's short slug (`g1`, `g2`, ...) in parallel
   mode. Use `mktemp` — never a predictable path built with plain string interpolation — for every
   one of this round's temp files (see "why `mktemp`" in the path-convention note below):
   ```bash
   GROUP="main"  # or e.g. "g1" — fixed per concurrently-dispatched group in parallel mode
   PID_FILE=$(mktemp "/tmp/ccd-${SESSION_ID}-round-<R>-${GROUP}.pid.XXXXXX")
   OUT_FILE=$(mktemp "/tmp/ccd-${SESSION_ID}-round-<R>-${GROUP}-out.json.XXXXXX")
   FOCUS_FILE=$(mktemp "/tmp/ccd-${SESSION_ID}-round-<R>-${GROUP}-focus.txt.XXXXXX")
   echo "PID_FILE=$PID_FILE"
   echo "OUT_FILE=$OUT_FILE"
   echo "FOCUS_FILE=$FOCUS_FILE"
   # only run this next line when capture was determined ON for this session in Phase 0 Step 0 —
   # write the literal branch by hand, do not gate it on a variable read from a separate tool call:
   EVENTLOG_FILE=$(mktemp "/tmp/ccd-${SESSION_ID}-round-<R>-${GROUP}-eventlog.jsonl.XXXXXX")
   echo "EVENTLOG_FILE=$EVENTLOG_FILE"
   ```
   `${SESSION_ID}` here is the literal string Claude already determined and remembered in Phase 0
   Step 0 — write it in as concrete text (e.g. `2026-08-28T143000-54321`), not as a variable expected
   to survive from an earlier tool call. This call's own stdout is what actually matters: read back the
   printed `PID_FILE=`/`OUT_FILE=`/`FOCUS_FILE=`/`EVENTLOG_FILE=` lines and remember those EXACT
   literal paths (`mktemp`'s random suffix and all) for every remaining step of this round — the
   backgrounded dispatch below, the Monitor watcher, the extraction step (when capture is on), and the
   end-of-round cleanup all reuse these same literal paths verbatim, never the `XXXXXX` template.
   Immediately after allocating `FOCUS_FILE`, use the Write tool (not a shell redirect) to write this
   round's actual `--focus` text, followed directly by a trailing `x` sentinel with no newline anywhere
   in between, into that exact literal path — content on disk must be exactly `<focus text>x` — see "Why
   the focus text goes through a file" and "Why the write side appends a trailing x sentinel" in the
   Codex invocation section above.

1. **Primary channel:** the backgrounded command captures its own PID — and, to guard against PID
   reuse (see step 2), that process's start time — into the pre-allocated `.pid` file before waiting
   on it, so a second, separately-dispatched process can find both independently:
   ```bash
   PID_FILE="<the exact literal PID_FILE path from step 0>"
   OUT_FILE="<the exact literal OUT_FILE path from step 0>"
   FOCUS_FILE="<the exact literal FOCUS_FILE path from step 0, already populated via the Write tool>"
   INSTALL_PATH_FILE="<the exact literal INSTALL_PATH_FILE path resolved once in Phase 0 Step 0>"
   REPO_ROOT_FILE="<the exact literal REPO_ROOT_FILE path resolved once in Phase 0 Step 0>"
   # all three reads strip the trailing "x" sentinel appended on write — see "Why the write side appends
   # a trailing x sentinel" in the Codex invocation section above:
   INSTALL_PATH="$(cat "$INSTALL_PATH_FILE")"; INSTALL_PATH="${INSTALL_PATH%x}"
   REPO_ROOT="$(cat "$REPO_ROOT_FILE")"; REPO_ROOT="${REPO_ROOT%x}"
   FOCUS_TEXT="$(cat "$FOCUS_FILE")"; FOCUS_TEXT="${FOCUS_TEXT%x}"
   CAPTURE_ARGS=()
   # literal branch, written by hand: include this line only if capture was determined ON in Phase 0
   # Step 0 — never gate it on reading a shell variable from a separate tool call:
   CAPTURE_ARGS=(--capture-eventlog "<the exact literal EVENTLOG_FILE path from step 0>")
   "$INSTALL_PATH/scripts/run-codex-review.sh" --cwd "$REPO_ROOT" --uncommitted \
     --focus "$FOCUS_TEXT" \
     "${CAPTURE_ARGS[@]}" \
     > "$OUT_FILE" 2>&1 &
   CODEX_BG_PID=$!
   CODEX_START_TIME=$(ps -o lstart= -p "$CODEX_BG_PID" 2>/dev/null)
   { echo "$CODEX_BG_PID"; echo "$CODEX_START_TIME"; } > "$PID_FILE"
   wait "$CODEX_BG_PID"
   cat "$OUT_FILE"
   ```
   **Non-repo artifact round?** Substitute the exact literal `CLEAN_REPO_DIR` path for `$REPO_ROOT` in the
   `--cwd` argument above instead — never `$REPO_ROOT` for a genuine non-repo-artifact review. See "Always
   give Codex the actual material to review" further below (in this same "Liveness watcher" section's
   "Still true regardless of invocation mechanism" list) for the full mechanism and why.

   Dispatch this whole block via Bash with `run_in_background: true` — this is still the call whose
   completion notification and stdout you parse per the rules above. The `.pid` file now holds two
   lines: the PID, then that process's start time (`ps -o lstart=`) — the second line is what lets the
   secondary channel below tell a still-running wrapper apart from an unrelated process the OS later
   handed the same PID to.

2. **Secondary channel:** immediately after, dispatch an independent `Monitor` call (same `<R>`/
   `<GROUP>` round, reusing the same literal `PID_FILE` path from step 0):
   ```bash
   GROUP="<the same literal group value from step 0 — e.g. main or g1>"
   PID_FILE="<the exact literal PID_FILE path from step 0>"
   PID_WAIT_START=$(date +%s)
   PID_WAIT_TIMEOUT=1800  # matches the wrapper's own documented maximum round timeout (see "Codex invocation" above)
   until [ "$(wc -l < "$PID_FILE" 2>/dev/null || echo 0)" -ge 2 ]; do
     if [ $(( $(date +%s) - PID_WAIT_START )) -ge "$PID_WAIT_TIMEOUT" ]; then
       echo "Round <R> (${GROUP}): primary dispatch never wrote its PID record within ${PID_WAIT_TIMEOUT}s — treating this round as failed, go check the primary channel's own error output directly"
       exit 1
     fi
     sleep 1
   done
   PID=$(sed -n '1p' "$PID_FILE")
   START_TIME=$(sed -n '2p' "$PID_FILE")
   START=$(date +%s)
   still_running() {
     kill -0 "$PID" 2>/dev/null || return 1
     [ "$(ps -o lstart= -p "$PID" 2>/dev/null)" = "$START_TIME" ]
   }
   while still_running; do
     echo "Round <R> (${GROUP}): still running, $(( $(date +%s) - START ))s elapsed"
     sleep 180
   done
   echo "Round <R> (${GROUP}): process exited (PID $PID no longer alive, or reused by a different process)"
   ```
   **Why the initial wait now has a bounded timeout.** The `until` loop waits for the primary dispatch's
   `.pid` file to gain its 2-line PID-plus-start-time record (step 1 above writes it right before
   `wait`-ing on the process). If that primary dispatch never reaches that point — it errors out early,
   gets cancelled, or otherwise never writes the record — the loop previously had no escape hatch and
   would wait forever, since nothing else in this watcher would ever flip its condition true. It now caps
   the wait at `PID_WAIT_TIMEOUT` (1800s, matching the wrapper's own documented maximum round timeout —
   see "Codex invocation" above) via a simple elapsed-time check each iteration (`$(date +%s)` against the
   recorded `PID_WAIT_START`), the same style already used for the "still running, Ns elapsed" progress
   line further down — and exits with an explicit failure line instead of hanging indefinitely.

   **Why the wait condition checks line count, not mere existence.** Step 0 above allocates `PID_FILE`
   via `mktemp`, which means the file already exists — as an empty, 0-byte file — the moment step 0
   finishes, well before step 1 ever writes the PID/start-time record into it. A wait condition of
   `[ -f "$PID_FILE" ]` would therefore pass IMMEDIATELY, before step 1 has written anything: this
   watcher would then read two empty lines as `PID`/`START_TIME`, `kill -0 ""` would fail instantly, and
   the watcher would wrongly report "process exited" right at startup — defeating the entire point of
   this independent liveness channel. Waiting for at least 2 lines (`wc -l ... -ge 2`) instead of mere
   existence is what avoids this, since step 1 writes exactly two lines (the PID, then the start time) —
   do not regress this back to a plain `-f` check.

   `GROUP` and `PID_FILE` are both re-declared here as literal values in this fresh script — this is a
   separate, independently-dispatched `Monitor` call, so, exactly like `SESSION_ID`, neither survives
   from the earlier Bash call that set them; Claude writes in the same concrete strings by hand.
   This checks process liveness AND identity (PID plus recorded start time), not raw `kill -0` alone —
   it never touches the primary channel's own bookkeeping beyond reading the `.pid` file. The
   start-time comparison mitigates PID reuse: once the wrapper process exits, the OS can hand that same
   numeric PID to a completely unrelated process, and a bare `kill -0 "$PID"` would then misreport
   "still alive" for the wrong process. This is a defense-in-depth secondary signal, not the primary
   completion mechanism (the harness's own task-finished notification is primary and has no such race)
   — it mitigates, but does not claim to perfectly eliminate, the narrow theoretical race between
   reading the PID and the OS reusing it; no further engineering beyond this standard mitigation is
   needed. If the primary notification never arrives for any reason, this watcher's own "process
   exited" line is your independent signal to go read the literal `OUT_FILE` path yourself rather than
   waiting indefinitely on a notification that may never come.

**Why `mktemp`, not a predictable path.** `/tmp` is a shared, world-writable directory. A predictable
path — even one qualified with session/round/group — lets a local attacker (another process/user on
the same machine with write access to `/tmp`) pre-plant a symlink at that exact path pointing at a
file the current user can write to; a plain `> path` redirect or `echo ... > path` would then follow
the symlink and clobber that target instead of creating a fresh file. `mktemp` allocates the file
atomically and refuses to follow a pre-existing symlink, closing this vulnerability class — this is why
step 0 above allocates every one of this round's temp files with `mktemp` instead of building the path
directly.

Use a `<session-id>`-**and**-`<R>`-**and**-`<GROUP>`-specific `mktemp` TEMPLATE for every round's tmp
files — `.pid`, `-out.json`, `-focus.txt`, and (when capture is on) `-eventlog.jsonl` — never
`<R>`+`<GROUP>` alone:
e.g. the template `/tmp/ccd-${SESSION_ID}-round-3-main-out.json.XXXXXX` for a single-reviewer round, or
`/tmp/ccd-${SESSION_ID}-round-3-g1-out.json.XXXXXX` / `/tmp/ccd-${SESSION_ID}-round-3-g2-out.json.XXXXXX`
for two groups dispatched concurrently within round 3 of that session (`SESSION_ID` computed once in
Phase 0 Step 0, e.g. `2026-08-28T143000-54321` — see above). For a single-reviewer round (the common
case), fix `<GROUP>` to the literal constant `main` — do not omit the segment, so one unambiguous
convention covers both modes with the same code. In parallel mode (Phase 1), assign each concurrently
dispatched group its own short, stable slug and use it for that group's `.pid`, `-out.json`,
`-focus.txt`, and `-eventlog.jsonl` templates for the whole round.

This `<session-id>`+`<R>`+`<GROUP>` triple is what actually prevents cross-session collisions — keying
only on `<R>`+`<GROUP>` is not sufficient: any two separate `codex-direct-review:ccd` invocations (concurrent OR simply run
at different times) both start at `R=1`/`GROUP=main`, so without the session-id they would build
colliding path templates, and since `.pid`/`-out.json`/`-focus.txt` files are never deleted until the
cleanup step below, a brand-new session's Liveness watcher could otherwise find and poll a completely unrelated,
stale file left over from an earlier session. Keying on `<session-id>` as well makes that structurally
impossible, since two different `codex-direct-review:ccd` invocations cannot share the same timestamp-plus-PID session-id
(see Phase 0 Step 0). Within one round, `mktemp`'s random suffix is what prevents a DIFFERENT class of
collision — a local attacker guessing the exact path in advance — that the session/round/group prefix
alone does not address. Both liveness channels, and the extraction/cleanup steps in "Investigation
evidence capture" below, report on and operate on the SAME session-round-and-group's literal resolved
paths from step 0 above — this is intentional redundancy and reuse, not two unrelated signals.

Still true regardless of invocation mechanism:
- **Read-only reviewer.** Phrase every `--focus` prompt as *REVIEW / DIAGNOSIS ONLY — do not edit any files*. Codex stays read-only; Claude remains the sole editor and review owner. Apply small validated fixes directly when permitted; delegate validated substantial/multi-file fixes to the active Claude implementation agent, then inspect the resulting diff and tests yourself. Safety net (repo artifacts only): after each round, check `git status`/`git diff` and flag any unexpected Codex edit.
- **Always give Codex the actual material to review**, not just a description: for repo/code work, `--uncommitted` (or the equivalent branch/commit flag) already hands the wrapper the diff; for non-repo artifacts (analysis, generated text, a plan), paste the produced content into `--focus`.
  - **Non-repo artifact reviews must NOT dispatch against `$REPO_ROOT`.** Dispatching
    `--uncommitted --cwd "$REPO_ROOT"` for a non-repo artifact points the wrapper at the user's real
    working tree — if that tree happens to have ANY unrelated uncommitted changes (a dirty tree that has
    nothing to do with the artifact being reviewed), the installed wrapper's own prompt-construction logic
    reviews the ACTUAL DIFF whenever it is non-empty, using `--focus` only as context for that diff — it
    does NOT fall back to a focus-only review unless the diff is genuinely empty. So an artifact-only
    review would silently ALSO review those unrelated changes, contaminating findings, coverage, and
    parallel-mode sizing with material the user never asked to review. This is the identical, already-
    proven technique this very `codex-direct-review:ccd` review process itself relies on elsewhere in this codebase (a fresh,
    clean, isolated git repo forces an empty-diff/focus-only path) — not a new invention.
  - **The fix:** the first time a session determines a round is a genuine non-repo-artifact review (no
    actual code diff to review — just pasted content), create a throwaway clean git repo once and reuse it
    for every round of that same artifact-only session — never recreate it per round:
    ```bash
    CLEAN_REPO_DIR=$(mktemp -d "/tmp/ccd-${SESSION_ID}-artifact-repo.XXXXXX")
    git -C "$CLEAN_REPO_DIR" init -q
    echo "CLEAN_REPO_DIR=$CLEAN_REPO_DIR"
    ```
    That's the whole setup — no seed file, no `git add`, no `git commit`. Like `PID_FILE`/`OUT_FILE`/
    `FOCUS_FILE` (see the Liveness watcher's step 0 above), `CLEAN_REPO_DIR` is
    `mktemp`'s own output — a path Claude fully controls the template of, guaranteed free of shell
    metacharacters — so it is simply printed and remembered as an exact literal string for the rest of the
    session, the same way `PID_FILE`/`OUT_FILE` are, with no further file-plus-sentinel indirection needed
    (unlike `REPO_ROOT_FILE`/`INSTALL_PATH_FILE`, which hold externally-resolved values Claude does not
    fully control character-by-character — see "Why the focus text — and the repo root passed to `--cwd`
    — go through a file" above). Dispatch every artifact-only round's wrapper call with
    `--cwd "<the exact literal CLEAN_REPO_DIR path>" --uncommitted --focus "$FOCUS_TEXT"` in place of
    `--cwd "$REPO_ROOT"` — the pasted focus text and `--capture-eventlog` flag (if capture is on) are
    otherwise unchanged. `CLEAN_REPO_DIR` is left exactly as `git init -q` leaves it: an unborn-HEAD
    repository with zero commits and nothing ever staged. No seed commit is needed to make `--uncommitted`
    resolve to an empty diff there — this project's own established unborn-HEAD handling already covers
    it. The `DIFF_BASE` guard used in Phase 0's ARTIFACT-resolution fallback and in Phase 1's sizing
    command below (`if git rev-parse --verify -q HEAD ...; then DIFF_BASE="HEAD"; else
    DIFF_BASE="$(git hash-object -t tree /dev/null)"; fi`) exists precisely because "the installed
    wrapper's own real collection code...already special-cases an unborn HEAD the same way" (see Phase 1
    below) — i.e. the wrapper's `--uncommitted` collector diffs an unborn HEAD against the empty tree
    rather than failing outright. A freshly-`git init`'d `CLEAN_REPO_DIR` with zero files is therefore
    guaranteed to produce an empty `--uncommitted` diff the moment it is created, which is exactly the
    trigger for the wrapper's own documented "no diff → review the Context/focus material instead" prompt
    path — so the review genuinely and exclusively assesses the pasted artifact content, with nothing from
    the user's real working tree mixed in, and with no commit step (and therefore no hook) that could ever
    fail or leave stray state behind.

    **An earlier revision of this fix seeded an initial commit, and that was both unnecessary and unsafe.**
    It ran `printf 'placeholder\n' > "$CLEAN_REPO_DIR/.cc-placeholder"`, then `git add .cc-placeholder`,
    then `git commit -q -m "placeholder"`, reasoning that the repo needed a committed `HEAD` before
    `--uncommitted` could safely diff against it. That reasoning was already wrong given the unborn-HEAD
    handling above — the seed commit produced no state the wrapper actually needed. Worse, the `git
    commit` call's exit status was never checked: if a globally-configured `pre-commit`/`commit-msg` hook
    on the machine ever rejected that commit, `.cc-placeholder` was left STAGED but uncommitted, so
    `--uncommitted` against this "clean" repo would then show a non-empty diff — the staged placeholder
    itself — silently defeating the exact "guaranteed empty diff" property this whole mechanism exists to
    provide, with no error surfaced anywhere. Removing the seed commit removes this failure mode entirely:
    there is no `git commit` call left that could fail, and no placeholder file left to go stray.
    **Repo/code reviews are unaffected** — they keep dispatching `--cwd "$REPO_ROOT"` exactly as before;
    this throwaway repo exists only for the non-repo-artifact case.
  - **Cleanup:** `CLEAN_REPO_DIR` (when created this session) is removed at the same point
    `REPO_ROOT_FILE`/`INSTALL_PATH_FILE` are already cleaned up in Phase 3 — see "Final Report to User"
    below — via `rm -rf "<the exact literal CLEAN_REPO_DIR path>"` alongside the existing `rm -f` for those
    two files. It is created lazily (only if this session ever actually needs it), so Phase 3's cleanup
    only runs this `rm -rf` when a `CLEAN_REPO_DIR` was actually allocated this session.
- **State the collaboration frame in the Round-1 `--focus` text**: equal peers, evidence-based findings (file:line + why), goal is 100% clean mutual agreement.
- **A failed or empty Codex response is NOT a clean sign-off.** Never equate an empty/errored return with "no findings → converged".

### Review history log (JSONL) — persisted round history

Every `codex-direct-review:ccd` run appends one JSON line per round to a session log file, so cross-round continuity
comes from an actual queryable record instead of relying solely on prompt recap text kept in
context. Claude is the sole writer and reader of this log — Codex never sees or touches it.

**Location:** `~/.claude/logs/ccd/<repo-slug>/<session-id>.jsonl`
- `<repo-slug>`: the target repo's directory basename, lowercased, non-alnum chars → `-`.
- `<session-id>`: the exact `SESSION_ID` value Claude computed once in Phase 0 Step 0
  (`SESSION_ID="$(date +%Y-%m-%dT%H%M%S)-$$"`, e.g. `2026-08-28T143000-54321`) and remembers for the
  whole run — not a live shell variable read back by a later tool call, but a literal string Claude
  writes into this path (and every per-round/per-group temp-file path, see the Liveness watcher
  section above) every time it constructs a command that needs it.
- Create the directory once per session if missing, owner-only: `umask 077 && mkdir -p
  ~/.claude/logs/ccd/<repo-slug>`. This retained log holds the complete `target.focus` text
  indefinitely (see "Retention" below) — on this project's own ambient `umask 022`, that directory and
  its `.jsonl` files would otherwise end up group/world-readable (`drwxr-xr-x`/`-rw-r--r--`),
  letting any other local user on a shared machine read potentially sensitive pasted material.
  `umask 077` (owner-only 0700/0600) closes that specific gap, matching the exact same precaution
  this project's own `eval/run_recall_eval.sh` already applies to its own artifact storage under
  `$STATE_ROOT`, for the identical reason — see that file's own comment for the one caveat worth
  repeating here too: a restrictive `umask` does not (and cannot) stop a different process running as
  this SAME user/UID from reading these paths, only OTHER users/UIDs on a shared machine.
- **Retroactively tighten any pre-existing logs directory too, once per session, best-effort:**
  `umask` only governs the permissions of paths created AFTER it is set — it does nothing for a
  `<repo-slug>` directory (or `.jsonl` files inside it) that a session from BEFORE this fix existed
  already created with the old, ambient (group/world-readable) permissions. Immediately after the
  `mkdir -p` above, also run `chmod -R go-rwx ~/.claude/logs/ccd/<repo-slug> 2>/dev/null || true`
  once at the start of the session — best-effort, same discipline as every other cleanup/permissions
  step in this file (a failure here, e.g. from a permissions issue on a path owned by a different user,
  is never a reason to abort or block the round). This closes the gap for logs this exact `<repo-slug>`
  already has on disk from before; it does not (and cannot) reach back and re-tighten every OTHER
  `<repo-slug>` directory under `~/.claude/logs/ccd/` from every unrelated prior `codex-direct-review:ccd` session —
  narrowing this to the one directory this session is actually about to read from and write to keeps
  the fix targeted rather than attempting a broad, unrelated retroactive sweep.

**Line schema (one JSON object per round):** (the `investigation_evidence` field shown in the example
below is illustrative only — it appears ONLY on a round from a session where the capture-evidence
flag was ON, per Phase 0 and "Investigation evidence capture" above; a normal session's lines never
contain this key at all — see the bullet immediately below the example. The example below is also a
**single-reviewer round** (`GROUP="main"`) — the common case, and UNCHANGED by anything in this section.
A **parallel round** (more than one group dispatched, see Phase 1) adds one more field, `groups`, and
gives different meaning to the top-level `target.focus`/`codex_review` fields shown here — see the
`groups` bullet below the example for the full parallel-round schema.)
```json
{
  "session_id": "2026-08-28T143000-54321",
  "round": 1,
  "ts": "2026-08-28T14:31:05+09:00",
  "target": {"repo": "<repo root>", "scope": "uncommitted", "focus": "<the --focus text sent this round>"},
  "codex_review": {"ok": true, "verdict": "ISSUES", "findings": [
    {"id": "f1", "file": "...", "line": 42, "severity": "high", "summary": "...", "evidence": "...", "linked_finding_id": null}
  ]},
  "coverage_source": {"status": "partial", "omitted": [{"path": "assets/large.bin", "reason": "over_size_limit"}]},
  "claude_verification": [
    {"finding_id": "f1", "action": "accept|reject_with_rationale|request_rereview|parked", "rationale": "..."}
  ],
  "round_outcome": "continue|converged|not_converged",
  "investigation_evidence": {"command_count": 3, "commands": ["grep -rn foo src/", "cat package.json", "npm test"]}
}
```
- `coverage_source`: value depends on this round's scope (see "Codex invocation" above for the full
  three-case breakdown):
  - **`--uncommitted` scope:** always written for this round — either the `coverage.source` object
    verbatim when the wrapper actually returned one (`{"status": "complete"}` or `{"status": "partial",
    "omitted": [...]}`), or the explicit sentinel `{"status": "unknown", "omitted": []}` when
    `coverage.source` was absent entirely from an otherwise-`"ok":true` response for this scope.
    **When this round dispatched more than one group (parallel mode), this field is the MERGED value**
    computed per "Codex invocation" → "Merging multiple groups' coverage into one value" above (worst-case
    wins: `"complete"` only if every dispatched group's own status was `"complete"`) — never an arbitrary
    single group's own value. A single-reviewer round (`GROUP="main"`) has nothing to merge and writes
    that group's own reported value directly, exactly like every other single-reviewer round.
  - **`--base`/`--commit` scope:** omit this field entirely — `coverage` is legitimately absent from
    the wrapper's response for these scopes (the sibling `codex-review` skill's own established
    convention), so do not invent a `"complete"`/`"unknown"` placeholder for a scope that never reports
    coverage at all.
- `groups`: **added only for a parallel round — more than one group dispatched this round (see Phase
  1).** `investigation_evidence` and `coverage_source` each have their own one-field-per-round merge rule
  for the parallel case (see "Investigation evidence capture" step 3 and "Codex invocation" → "Merging
  multiple groups' coverage into one value" above), but neither of those merges the CORE review data
  itself — each dispatched group runs its own separate wrapper call with its own separate `--focus` text
  and produces its own separate `codex_review` result, and without this field only one group's result (or
  an undefined amalgamation) would ever be recorded, silently losing every other group's real findings.
  **Common case — a single-reviewer round (`GROUP="main"`): omit this field entirely.** `target.focus`
  stays a single string and `codex_review` stays a single verdict+findings object, exactly as shown in the
  example above — no new field, no behavior change, for the case that is actually common.
  **Only when this round actually dispatched more than one group:** `groups` is an array with exactly one
  element per dispatched group, each capturing that group's OWN distinct focus and OWN distinct review
  result in full, with nothing lost or conflated:
  ```json
  "groups": [
    {"group": "g1", "focus": "<g1's exact --focus text>", "codex_review": {"ok": true, "verdict": "ISSUES", "findings": [{"id": "f1", "file": "...", "line": 42, "severity": "high", "summary": "...", "evidence": "...", "linked_finding_id": null}]}},
    {"group": "g2", "focus": "<g2's exact --focus text>", "codex_review": {"ok": true, "verdict": "CLEAN", "findings": []}},
    {"group": "g3", "focus": "<g3's exact --focus text>", "codex_review": {"ok": false, "reason": "timeout", "detail": "..."}}
  ]
  ```
  **What the top-level `target.focus`/`codex_review` fields hold for a parallel round** — so a consumer
  reading only the top-level fields, without knowing to look for `groups`, still gets a reasonable,
  non-misleading summary rather than an arbitrary single group's value standing in for the whole round:
  - `target.focus` is a short synthesized description noting this was a multi-group parallel round, e.g.
    `"(parallel round, 2 groups — see groups[] for each group's actual focus)"` — never any one group's
    real focus text presented as if it were the round's only focus.
  - `codex_review` is an AGGREGATED verdict/findings, following the exact same "worst case wins" principle
    already established for `coverage_source`'s own parallel merge (see "Codex invocation" → "Merging
    multiple groups' coverage into one value" above): `verdict` is `"ISSUES"` if ANY group's own
    `codex_review.verdict` was `"ISSUES"` or that group's own `findings` array was non-empty; `verdict` is
    `"CLEAN"` only if EVERY group's own verdict was `"CLEAN"` with a zero-length `findings` array. The
    aggregated `findings` array is the concatenation of every group's own `findings` array, with each
    finding object additionally tagged with a `"group"` field naming which group produced it (e.g.
    `"group": "g1"`) so a reader of the flattened top-level list can still trace each finding back to its
    source group. A single-reviewer round's `findings` never carry this `"group"` tag — it is
    omitted/absent, exactly as in the unchanged example above, since there is only one group to attribute
    findings to and tagging it would be meaningless noise.
  - **A group that returned `"ok":false`** (e.g. a timeout — see "Known Failure Patterns" below) carries
    no `verdict`/`findings` at all; its `groups[]` entry is the raw wrapper failure shape verbatim, exactly
    as shown for `g3` above — `{"group": "...", "focus": "...", "codex_review": {"ok": false, "reason":
    "...", "detail": "..."}}`, with no `verdict`/`findings` key expected or invented. Such a group
    contributes nothing to the aggregated `findings` concatenation (there is nothing to concatenate) and
    does **not** count as `"CLEAN"` for the aggregated `verdict` either — the aggregated
    `codex_review.verdict` can only be `"CLEAN"` once every dispatched group has actually returned
    `"ok":true` with a `"CLEAN"` verdict. This mirrors the exact same worst-case-wins principle already
    used for `coverage_source` (a `"partial"`/`"unknown"` group blocks `"complete"` — see "Codex
    invocation" → "Merging multiple groups' coverage into one value" above) and extends the single-
    reviewer `"ok":false` handling (see "Empty / failed review ≠ CLEAN" under Guards below) to the
    per-group case: a round with any `"ok":false` group retries JUST that group once, keeping every other
    group's already-collected real result untouched, and the round is not eligible for `✅ CLEAN` until the
    failed group succeeds on that retry.
  A failure while building `groups` or the aggregated top-level summary follows the same best-effort
  discipline as the rest of this log (see "Failure isolation" below): note it once in that round's
  narration, and fall back to recording whatever groups' results were actually collected rather than
  silently dropping the whole round's write.
- `investigation_evidence`: **optional, added only when the capture-evidence flag is ON for this
  session** (determined once in Phase 0 Step 0 — see "Investigation evidence capture" below). Omit
  this field entirely
  for a normal (non-capturing) `codex-direct-review:ccd` run; every existing session's logs, and every round of a
  non-capturing session, keep exactly the schema documented above with no new field and no migration
  required.
- `finding_id`: stable per finding for the whole session — assign `f<n>` incrementing across ALL
  rounds (never per-round), so an ID never collides or gets reused.
- `linked_finding_id`: when a finding in round R is Codex's re-review of a finding Claude sent back
  via `request_rereview` in round R-1, set this to that earlier finding's `id`. `null` for a
  genuinely new finding. This is how a disputed finding's multi-round thread stays traceable.
- `claude_verification[].action`:
  - `accept` — valid, fixed (or delegated and verified fixed).
  - `reject_with_rationale` — false positive, rebutted with concrete evidence; treated as resolved
    unless Codex reopens it next round.
  - `request_rereview` — Claude's rebuttal is **not final** — it is being sent back to Codex for
    another cold, sharp pass, not silently treated as a win. Use this instead of `accept`/
    `reject_with_rationale` whenever the disagreement should genuinely go another round.
  - `parked` — deferred, out of scope for this session (not the same as accepted or rejected).

**Write:** at the end of step 5 (narrate progress) below, append the round's line via `jq -nc` with
the round's actual values, redirected with `>>` to the session log file. Never overwrite or
truncate — append only. Set `umask 077` immediately before this append too, every round, not only at
the directory's initial `mkdir` — a `>>` redirect to a file that does not exist yet CREATES it (and
that creation is what a shell's current umask governs), and since each round's write is typically its
own separately-dispatched Bash call, the earlier `mkdir`'s umask setting does not carry over (the same
"shell state does not persist between commands" reasoning already established throughout this file for
`SESSION_ID`/`CAPTURE_EVIDENCE`/etc.). Restating `umask 077` before every append is harmless once the
file already exists (an append to an existing file doesn't change its permissions), and is what
actually guarantees the FIRST round's write — the one that creates the file — gets it right regardless
of which round that turns out to be.

**Read (continuity):** at the start of round R > 1, before building the `--focus` recap text, query
this session's own log instead of relying on memory of the conversation so far. `R` here is the literal
current round number Claude already knows at this point in Phase 2 (it is iterating "for each round
R") — substitute the actual number by hand, e.g. `select(.round < 3)` for round 3, exactly like
`SESSION_ID`/`INSTALL_PATH_FILE` elsewhere in this file: this is a fresh, separately-dispatched Bash tool
call, and shell state does not persist between separate Bash calls, so there is no live `$R` shell
variable to expand here. Writing `select(.round < '"$R"')` literally into the command would expand to
`select(.round < )` — a `jq` syntax error, since nothing carries `R` over from an earlier tool call
into this one:
```bash
jq -c 'select(.round < 3)' ~/.claude/logs/ccd/<repo-slug>/<session-id>.jsonl
```
Use the result — not recollection alone — as the source of truth for what was found, what Claude's
stance was, and what's still open (any `finding_id` whose latest `action` is `request_rereview` with
no later resolution) when constructing the recap. Cross-session lookback (a later `codex-direct-review:ccd` run on the
same repo) is optional and manual: `jq` across all `<repo-slug>/*.jsonl` files if the user asks
"did we see this before."

**Failure isolation:** a failure to write the log (disk full, bad path, `jq` error) must never abort
or degrade the review round itself. Log writes are best-effort — if `mkdir`/`jq`/append fails, note
it once in that round's narration and continue without the log for that round; do not retry
mid-round or block the loop on it.

**Retention: kept indefinitely, no automatic cleanup.** This is deliberate, not an oversight — the
log's whole purpose is a durable, cross-session audit trail ("did we see this before" lookback), and
plain-text JSONL accumulates negligible disk usage even over many sessions. Never auto-delete these
files. If cleanup is ever wanted, it is a manual `rm` under `~/.claude/logs/ccd/`, not a
built-in behavior.

**Reconciling this with "Investigation evidence capture"'s privacy stance — this is two different,
deliberate policies for two different classes of data, not an inconsistency to fix.** Every line in
this log persists `target.focus` — the complete `--focus` text sent that round — indefinitely, per the
retention policy above. Per Phase 2 step 1's own instruction, `--focus` can legitimately contain
arbitrary pasted content: for a non-repo artifact (analysis, generated text, a plan), "paste the
produced content into `--focus`". That means this log can retain, forever, whatever a user or Claude
chose to paste there — potentially just as sensitive as anything in a raw command-output stream. This
is intentional, not an oversight to close: this log's entire reason for existing is to durably record
what was reviewed and why, so `target.focus` — including any pasted non-repo content — IS the audit
trail, by design. That is a fundamentally different case from the capture-evidence section's raw
event-log privacy contract (see "Investigation evidence capture" above), where the raw event stream is
deliberately EXCLUDED from durable storage precisely because it can incidentally echo back much
broader, less-intentional content — arbitrary file reads, full command output — that nobody
deliberately chose to persist; only the extracted command strings survive into this same log. In short:
`target.focus` is retained because a human or Claude deliberately put it there as the thing being
reviewed; a raw event log is deleted because it echoes back things nobody deliberately chose to record.
Practical implication for anyone pasting into `--focus`: treat it as retained indefinitely in this log,
exactly like every other part of the round's audit record — this is informed-consent documentation of
existing, unchanged behavior, not a new behavior or a policy change.

### Investigation evidence capture (opt-in via `--capture-evidence`)

**Off by default.** A normal `codex-direct-review:ccd <task description>` invocation (no `--capture-evidence` prefix)
never touches anything in this section — no extra wrapper flag, no extra JSONL field, zero behavior
change from everything else this file documents.

> ⚠️ **Version requirement.** `--capture-eventlog` is a `run-codex-review.sh` wrapper flag that ships
> in a newer release of the `codex-direct-review` plugin than the one this section was written
> against (`~/.claude/plugins/installed_plugins.json` recorded `1.3.0` at the time) — the flag needs
> `codex-direct-review@youzooyou-plugins` **1.4.0 or later** (treat this as the best current estimate,
> not a guaranteed exact number; if in doubt, check the installed version, or run the Phase 0 Step 0
> item 5 probe below directly — the wrapper has no `--help` mode, so that probe, not `--help` output, is
> the reliable way to tell). Phase 0 Step 0 now checks this proactively, before the
> TASK ever runs, whenever capture is ON for the session (see Phase 0 Step 0's capture-eventlog support
> preflight) — the reactive handling below is a fallback for the rare case that check was somehow
> skipped or the wrapper's behavior changed between the preflight and a later round's actual call. If a
> round's wrapper call fails with an error to the
> effect of `unknown argument: --capture-eventlog`, that means the installed plugin predates this
> feature. Do not silently drop the flag and retry, and do not treat this as an ordinary failed round
> either — stop, tell the user to run `/plugins-update` to pick up a wrapper version that supports
> `--capture-eventlog`. **Before retrying that round — not simply after the user reports the update is
> done — re-resolve `INSTALL_PATH_FILE` first:** re-run the identical Phase 0 Step 0 item 4 `jq` lookup,
> trailing `x` sentinel and all (`{ jq -j '.plugins["codex-direct-review@youzooyou-plugins"][] |
> select(.scope=="user") | .installPath' ~/.claude/plugins/installed_plugins.json; printf 'x'; }`),
> redirecting its output into either the same already-allocated `INSTALL_PATH_FILE` path or a freshly
> `mktemp`-allocated one — either is fine, just be explicit about which one this retry actually uses from
> here on. Applying the same sentinel here is not optional: this is the identical write idiom as item 4's
> original resolution (see "Why the write side appends a trailing x sentinel" under "Codex invocation"
> above), and every later `$(cat "$INSTALL_PATH_FILE")` read site still unconditionally strips one
> trailing `x` via `${VAR%x}` — a re-resolution that wrote the raw `jq` output without the sentinel would
> then have its own last character silently eaten by the very next read. This mid-session case is exactly
> why re-resolution can't be skipped here the way it is for the Phase 0 Step 0 preflight failure above:
> that failure ends the entire run, so any retry is necessarily a brand-new `codex-direct-review:ccd` invocation that
> naturally re-runs item 4 from scratch — but THIS failure happens INSIDE an already-running session
> that still holds the OLD, stale `INSTALL_PATH_FILE` value. Plugin updates typically install a new
> versioned cache directory (e.g. `.../codex-direct-review/1.3.0/` becomes
> `.../codex-direct-review/1.4.0/`), and `installed_plugins.json`'s recorded path changes accordingly —
> simply retrying the round with the unchanged, already-captured `INSTALL_PATH_FILE` content re-invokes
> the exact same outdated wrapper binary a `/plugins-update` just replaced, and hits the identical
> `unknown argument` error again. Only after this re-resolution should the round actually be retried.
> This is a deliberate, narrow exception to this file's general "`INSTALL_PATH_FILE` is resolved once
> and never re-allocated" rule (see "Codex invocation" above and Phase 0 Step 0 item 4) — that rule
> assumes the installed plugin version doesn't change mid-session, which a `/plugins-update` explicitly
> violates; re-resolving here is the correct response to that specific trigger, not a general pattern to
> apply anywhere else in this file.

**What turns it on:** a one-time decision Claude makes at the very start of Phase 0 Step 0 (see
"Resolve the ARTIFACT" below) by checking whether `$ARGUMENTS` starts with the literal
`--capture-evidence` prefix — capture is ON for this session if the prefix is present, OFF otherwise.
This is deliberately NOT a shell variable carried between tool calls (see Phase 0 Step 0's opening note
on why that can't work) — it is a fact Claude determines once and remembers for the rest of the run,
writing the concrete literal branch (include or omit `--capture-eventlog "<path>"`, include or omit the
`investigation_evidence` JSONL field, etc.) into every command it constructs from here on, in every
separately-dispatched tool call. Once capture is ON for a session, it applies to every round of that
session's loop — there is no per-round opt-in/out within one `codex-direct-review:ccd` run. Every other place in this file
that says "the capture-evidence flag is on/requested for this session" means: Claude already knows the
answer from this Phase 0 Step 0 determination and must act on it literally, never by referencing a
variable a later tool call is expected to still see.

**What it captures:** only the literal shell commands Codex actually ran during that round's
investigation (e.g. `grep -rn foo src/`, `cat package.json`, `npm test`) — never their output, never
file contents, never anything else from the raw event stream. This lets Claude's re-verification step
(Phase 2 step 3) cross-check a finding's self-reported "verification" narrative (e.g. "I checked every
caller of X") against what Codex actually ran, instead of trusting the claim at face value.

**Stale-eventlog cleanup:** moved to Phase 0 Step 0 (see above) — it now runs unconditionally at the
very start of EVERY `codex-direct-review:ccd` invocation, not only when this session's own capture-evidence flag happens to
be ON. This closes a real gap in the previous design: a capture-enabled session that gets interrupted,
with no LATER capture-enabled session ever run again, would otherwise leave its orphaned raw event log
in `/tmp` forever. Running the sweep unconditionally on every invocation means the honest bound is "no
later than the start of the next `codex-direct-review:ccd` invocation of any kind, at least 60 minutes after being
orphaned" — not a mathematically absolute guarantee (a user who never runs `codex-direct-review:ccd` again, ever, would
still have an orphan sit forever), but materially broader and more honestly described than a bound tied
to a future capture-enabled session specifically. See Phase 0 Step 0 for the exact command and glob
(now also matching the `mktemp`-suffixed filenames introduced below), and see the privacy note in step
4 below for why this sweep exists. (This sweep is scoped to eventlog files only — the two unrelated
session-level tracking files, `REPO_ROOT_FILE`/`INSTALL_PATH_FILE`, are cleaned up via LOCAL, immediate
`rm -f` calls at each of Phase 0's own early-exit points instead; see Step 0 items 1, 4, and 5, the
ARTIFACT-resolution bullet right after item 6, and "Final Report to User" below for why a shared
cross-session sweep is wrong for that file class.)

**How it's captured, per round:**
1. When capture is ON for this session, the eventlog path is one of the four `mktemp`-allocated paths
   Claude pre-allocates and remembers for the round (see the Liveness watcher section's step 0 above) —
   template `/tmp/ccd-${SESSION_ID}-round-<R>-<GROUP>-eventlog.jsonl.XXXXXX`, with `<GROUP>` fixed to
   `main` for a single-reviewer round or that group's short slug (`g1`, `g2`, ...) in parallel mode, so
   concurrent dispatches within the same round never collide, and `SESSION_ID` (computed once in
   Phase 0 Step 0) so this session's file is never confused with one from a different `codex-direct-review:ccd` run. Pass
   the EXACT literal path `mktemp` resolved and printed in step 0 (never the `XXXXXX` template) as
   `--capture-eventlog "<that literal path>"` to that round's `run-codex-review.sh` call (alongside
   `--cwd`/`--uncommitted`/`--focus`, see "Codex invocation" above).
2. **Extract the command list and wrap it into the JSONL schema's required object shape, in ONE `jq`
   call.** After that round's wrapper call returns and its JSON stdout has been parsed (see "Codex
   invocation" above), reuse the same literal eventlog path from step 1 — guard for a missing/empty file
   so a failed or short-circuited round never breaks this step. The `investigation_evidence` field in
   the review history log's schema (see the line-schema example and "Where it's stored" below) is an
   OBJECT — `{"command_count": N, "commands": [...]}` — not a bare array, so extraction and wrapping are
   done together, directly from the event-log file, in a single `jq` invocation:
   ```bash
   EVENTLOG="<the exact literal mktemp-resolved eventlog path from step 1 — same round, same group>"
   if [ -s "$EVENTLOG" ]; then
     INVESTIGATION_EVIDENCE_JSON=$(jq -Rn -c '
       [inputs | fromjson? | select(.type == "item.completed" and .item.type == "command_execution") | .item.command]
       | {command_count: length, commands: .}
     ' "$EVENTLOG")
   else
     INVESTIGATION_EVIDENCE_JSON='{"command_count":0,"commands":[]}'
   fi
   ```
   The ONLY bash-level capture here is the well-formed, complete JSON object as `jq`'s own stdout via
   `$(...)` into `INVESTIGATION_EVIDENCE_JSON` — this is safe regardless of what characters the captured
   commands contain (single quotes, double quotes, escaped apostrophes, anything), because the object is
   never disassembled into and reassembled from an intermediate bash string; `jq` handles all the JSON
   construction internally in one pass. This replaces an earlier two-step design (extract to a bare
   array, then wrap it by re-embedding that array's text inside a single-quoted bash literal
   `COMMANDS_JSON='<array>'`) that was not shell-safe and could corrupt or lose captured commands
   containing quote characters — confirmed directly via `bash -n`: a captured command like
   `grep -rn 'foo' src/` (containing single quotes) had those quotes silently altered/lost when embedded
   that way, and a captured command containing an escaped apostrophe (e.g. from a JSON string like
   `"git commit -m \"don't\""`) could produce unbalanced shell quoting that failed to parse outright.
   `fromjson?` swallows any unparseable line rather than erroring the whole extraction, so a partial or
   malformed event log still yields whatever valid entries it contains. This step is meant to run in the
   same Bash tool call as step 1 and step 4 below, so `$EVENTLOG` set here stays valid through step 4's
   cleanup; if ever split across separate tool calls, restate the same literal path in each rather than
   relying on the variable to carry over. `$INVESTIGATION_EVIDENCE_JSON` — never an intermediate bare
   array or a separately-wrapped variable — is this GROUP's own evidence object; for a single-reviewer
   round it is also the final value used at step 5 (see step 3 immediately below for the parallel-mode
   case). It is what actually gets spliced into that round's JSONL line
   as the `investigation_evidence` field's value at the existing step-5 write point (see "Review history
   log" above and "Where it's stored" below).
3. **Merge multiple groups' evidence into one object — parallel mode only.** The review history log's
   schema (see "Review history log" above) has exactly ONE `investigation_evidence` object per ROUND,
   but Phase 1's parallel mode can dispatch more than one group within the same round — each running its
   own separate wrapper call, its own separate `$EVENTLOG`, and therefore producing its own separate
   `INVESTIGATION_EVIDENCE_JSON` from step 2 above. **Common case — a single-reviewer round
   (`GROUP="main"`): there is nothing to merge.** That group's own `INVESTIGATION_EVIDENCE_JSON` from
   step 2 is used directly, unchanged, as this round's final value — skip the rest of this step entirely.
   **Only when this round actually dispatched more than one group:** after every group has finished its
   own step 2 extraction, combine all of their `INVESTIGATION_EVIDENCE_JSON` values into ONE merged
   object by summing `command_count` and concatenating `commands` across groups, in one `jq` call:
   ```bash
   MERGED_INVESTIGATION_EVIDENCE_JSON=$(jq -sc '{command_count: (map(.command_count) | add), commands: (map(.commands) | add)}' <<< "$GROUP1_JSON
   $GROUP2_JSON")
   ```
   (add one more line to the heredoc per additional group actually dispatched this round). Use this
   merged object — never any single group's own value — as the one `investigation_evidence` field
   written into that round's single JSONL line at step 5 (see "Review history log" above and Phase 2
   step 5 below). A failure in this merge step follows the same best-effort discipline as the rest of
   this section (see "Failure isolation" below): note it once and omit `investigation_evidence` from
   that round's line rather than blocking the round.
4. **Delete the raw event-log copy right after extraction, best-effort:** `rm -f "$EVENTLOG"` (per
   group, if parallel mode dispatched more than one). The
   intent is a strong privacy contract — the raw event stream can echo back actual file contents Codex
   read during its investigation, so it is meant to be deleted immediately once step 2's combined
   extraction-and-wrap is done, and
   only the extracted command strings are meant to persist, and only into the existing review history
   log. Be honest, though, about what a plain `rm -f` run after the fact can actually guarantee: it has
   no atomicity or crash guard around it, so if this session is interrupted (killed, crashes, or the
   user Ctrl-Cs) in the window between the wrapper call finishing and this `rm -f` executing, that
   round's raw event-log file is left behind at its `/tmp/...` path rather than deleted — this is a
   real gap, not a hypothetical one, and this file does not claim otherwise. The unconditional Phase 0
   Step 0 sweep (see above) is what bounds that gap in practice: it cannot prevent a mid-session
   interrupt from leaving a file behind, but because it now runs at the start of EVERY `codex-direct-review:ccd`
   invocation — not only a future capture-enabled one — it guarantees any such orphan is removed no
   later than the start of the next `codex-direct-review:ccd` invocation of any kind, at least 60 minutes after it was left
   behind. That is a materially broader bound than depending on another capture-enabled session ever
   running again, though still not a mathematically absolute guarantee (a user who never runs `codex-direct-review:ccd`
   again, ever, would still have an orphan sit forever) — orphaned raw captures simply cannot
   accumulate indefinitely across ordinary usage, even though a mid-session interrupt itself can't be
   perfectly guarded against.

**Where it's stored:** no new file, no new format. When the capture-evidence flag is ON for this
session, add the one optional `investigation_evidence` field to that round's existing JSONL line (see
"Review history log" above), using `$INVESTIGATION_EVIDENCE_JSON` — the
`{"command_count": N, "commands": [...]}` object produced directly by step 2's single `jq` call above —
as that field's value. Same log, same append-only write at step 5, nothing new to create.

**Failure isolation:** exactly the same best-effort discipline as the rest of this log — a `jq` failure
in step 2's combined extraction-and-wrap call, a missing/empty event-log file, or a failed `rm` must
never abort or degrade the review round. Note it once in that round's narration (step 5) and continue
with `investigation_evidence` simply omitted from that round's line.

---

## Phase 0 — Resolve the ARTIFACT (the thing to be reviewed)

- **Step 0 — determine the capture-evidence decision, the session id, and the Codex plugin install
  path, before anything else. These are facts Claude works out ONCE, right now, and REMEMBERS for the
  rest of this `codex-direct-review:ccd` run — exactly like `<repo-slug>` elsewhere in this file, they are NOT live shell
  variables that a later, separately-dispatched Bash/Monitor tool call could read back. Claude Code's own
  documented Bash tool behavior is: "The working directory persists between commands, but shell state
  does NOT persist between commands" — each tool call gets a fresh shell, so anything set with
  `export`/`FOO=bar` in one Bash call is simply gone in the next, separate Bash call. Every later section
  of this file that shows `"$CAPTURE_EVIDENCE"` or `"${SESSION_ID}"` inside a bash code block is
  illustrative pseudocode for a value Claude already knows from this step — Claude must write the
  concrete literal text into the actual command it constructs for that step, never rely on a shell
  variable a later tool call is expected to inherit. `INSTALL_PATH` and the repo root are handled
  differently, precisely because — unlike `SESSION_ID` and `CAPTURE_EVIDENCE`, which are short,
  Claude-generated strings with no realistic risk of containing shell metacharacters — they are resolved
  values that could in principle contain a literal `"`. Re-verified here: that reasoning still holds for
  `SESSION_ID` (a generated timestamp-plus-PID string) and for `GROUP`/`CAPTURE_EVIDENCE` (fixed literal
  words Claude itself chooses), so those remain safe to hand-type as literals; `INSTALL_PATH` and the
  repo root do not have that guarantee, since they come from `jq`/`pwd` output Claude does not fully
  control character-by-character. So neither is ever hand-retyped as a `VAR="<value>"` literal anywhere
  in this file — each is captured directly into its own tracking file via output redirection, with a
  trailing `x` sentinel appended (see item 4 and item 6 below, and "Why the write side appends a trailing
  x sentinel" under "Codex invocation" above), and consumed everywhere as `$(cat "$INSTALL_PATH_FILE")` /
  `$(cat "$REPO_ROOT_FILE")` with that trailing `x` stripped via `${VAR%x}` — the exact same safe idiom
  `FOCUS_FILE` uses too (`FOCUS_TEXT="$(cat "$FOCUS_FILE")"; FOCUS_TEXT="${FOCUS_TEXT%x}"` then
  `--focus "$FOCUS_TEXT"`), for the same trailing-newline-loss reason (see "Why the write side appends a
  trailing x sentinel" under "Codex invocation" above).**

  1. **Unconditional stale-eventlog sweep (best-effort, every invocation, run first):** before
     anything else — regardless of whether this session uses `--capture-evidence` at all — run a
     best-effort sweep for orphaned raw event-log files left behind by a past, interrupted
     `--capture-evidence` session:
     ```bash
     find /tmp -maxdepth 1 -name 'cc-*-round-*-eventlog.jsonl*' -mmin +60 -delete
     ```
     The trailing `*` matches both the old fully-predictable filename and the `mktemp`-suffixed
     `...eventlog.jsonl.XXXXXX` names produced from this revision forward (see "Investigation evidence
     capture" below). Running this on EVERY `codex-direct-review:ccd` invocation — capture-enabled or not — is what makes
     the cleanup bound honest: an orphaned eventlog is removed no later than the start of the very next
     `codex-direct-review:ccd` invocation of any kind, at least 60 minutes after being orphaned. A 60-minute threshold is
     safe here specifically because an eventlog is only ever in use for one round's wrapper call, which
     is capped at 1800s (30 min — see "Codex invocation" above) — a genuinely in-use eventlog file can
     never reach the 60-minute mark, so this sweep can never delete a file another running session still
     needs. Whether it deletes something, deletes nothing, or fails outright, proceed without noting it.

     **This sweep does NOT match `REPO_ROOT_FILE`/`INSTALL_PATH_FILE` — that was tried in an earlier
     revision of this file and was wrong.** An earlier fix folded `cc-*-repo-root.txt.*` and
     `cc-*-install-path.txt.*` into this same 60-minute age-based sweep as a "backstop" for an early
     Phase 0 abort. That was unsafe: unlike an eventlog, `REPO_ROOT_FILE`/`INSTALL_PATH_FILE` are meant
     to stay alive for a session's ENTIRE multi-round run — which can legitimately span up to 20 rounds
     and exceed 60 minutes of real elapsed time — so a different, still-legitimately-running `codex-direct-review:ccd`
     session (a separate, concurrently-started invocation with its own `SESSION_ID`) that had simply
     been going for over an hour could have its own still-in-use tracking files swept up by a
     DIFFERENT session's Phase 0 Step 0 startup sweep, since the `find` pattern matched any session's
     files, not only the invoking session's own. Confirmed directly as a real functional break, not a
     narrow theoretical edge case: that session's later wrapper calls would then read an EMPTY string
     via `$(cat "$FILE")` on the now-deleted file, producing `--cwd ""` or an empty wrapper-path
     invocation, which the wrapper rejects as `bad_args`. The fix is to not share a cross-session sweep
     for a file class whose legitimate lifetime is unpredictable and session-scoped in a way eventlog
     files are not — see items 4 and 6 below for the LOCAL, immediate cleanup that replaces it.

  2. **Capture-evidence decision:** check whether `$ARGUMENTS` starts with the literal prefix
     `--capture-evidence ` (note the trailing space), or is exactly the string `--capture-evidence`
     with nothing after it. If either is true, **capture is ON for this session** — this is "the
     capture-evidence flag is ON for this session" that every other reference in this file points back
     to (see "Investigation evidence capture" above for everything it controls) — and treat the
     remainder of `$ARGUMENTS` **after** that prefix as the effective `$ARGUMENTS` for every rule below
     and everywhere else in this file. If the prefix is not present, **capture is OFF for this
     session** — `$ARGUMENTS` is used exactly as given, and everything below proceeds precisely as
     documented with no added behavior. Either way, this is a one-time decision Claude makes now and
     remembers for the whole run: every later place in this file that gates on "capture is on/off"
     means Claude already knows the answer and must write the concrete literal branch (e.g. either
     include the `--capture-eventlog "<path>"` argument as literal text, or omit it entirely) into each
     command it actually constructs — there is no shell variable carrying this decision between tool
     calls, and no per-round re-check within one `codex-direct-review:ccd` run.

  3. **Session id:** compute **`SESSION_ID="$(date +%Y-%m-%dT%H%M%S)-$$"`** once — the timestamp this
     run started plus the invoking shell's PID (`$$`), fixed for the whole session. The PID suffix is
     required: a bare `date +%Y-%m-%dT%H%M%S` has only 1-second resolution and is NOT unique — two
     `codex-direct-review:ccd` invocations started within the same second produce the identical string (confirmed directly:
     three back-to-back calls returned the same timestamp) and would then collide on every path this id
     qualifies. `$$` is trivially available and always distinct per shell process, without resorting to
     a non-portable, GNU-only `date` flag like `%N` (this project's other tooling avoids those for
     portability). This is the same `<session-id>` the "Review history log" section below uses for its
     log file path, and the value that qualifies every per-round/per-group temp-file path in the
     Liveness watcher and Investigation evidence capture sections. Remember this exact literal string
     for the rest of the run and substitute it literally into every path Claude constructs in every
     later, separately-dispatched tool call — like the capture decision above, it is not carried by an
     exported shell variable, because it does not need to be: Claude already knows the string and writes
     it in by hand each time. (Note: this changes the on-disk JSONL log filename convention going
     forward — existing old-format `<timestamp-only>.jsonl` log files are unaffected; nothing reads or
     writes them differently, this only applies to new sessions from now on.)

  4. **Codex plugin install path:** resolve the `codex-direct-review` plugin's current install path
     once, right here, the same way the repo root is resolved in item 6 below — redirect the resolving
     command's OWN output directly into a `mktemp`-allocated tracking file, never through an intermediate
     bash variable that would then have to be hand-retyped as a quoted literal. This matters because the
     `$(cat "$FILE")`-plus-`${VAR%x}` safe-read idiom used everywhere else in this file only protects the
     CONSUMING side of a resolved value — it does nothing if the WRITING side already embedded the raw
     value unsafely as `VAR="<value>"`: if the resolved install path ever contained a literal `"`,
     hand-typing it that way would break out of the intended string exactly like the `--focus`/`--cwd`
     injection this file already fixes elsewhere. The write below also appends the trailing `x` sentinel
     (see "Why the write side appends a trailing x sentinel" under "Codex invocation" above) — without it,
     a resolved install path that happened to end in a literal newline byte would come back silently
     shortened every time it is later read via `$(cat "$INSTALL_PATH_FILE")`, since command substitution
     strips all trailing newlines unconditionally. (This file is allocated once and never re-allocated
     within a run — except for the one narrow, documented exception where a `/plugins-update`-driven
     mid-session retry explicitly re-runs this same lookup, sentinel included; see the "Version
     requirement" callout under "Investigation evidence capture" above, and item 5's own preflight-failure
     note below.)
     ```bash
     INSTALL_PATH_FILE=$(mktemp "/tmp/ccd-${SESSION_ID}-install-path.txt.XXXXXX")
     { jq -j '.plugins["codex-direct-review@youzooyou-plugins"][] | select(.scope=="user") | .installPath' ~/.claude/plugins/installed_plugins.json; printf 'x'; } > "$INSTALL_PATH_FILE"
     INSTALL_PATH="$(cat "$INSTALL_PATH_FILE")"; INSTALL_PATH="${INSTALL_PATH%x}"
     if [ -z "$INSTALL_PATH" ]; then
       echo "codex-direct-review@youzooyou-plugins is not installed — run /plugin install codex-direct-review@youzooyou-plugins first" >&2
       rm -f "$INSTALL_PATH_FILE"
       exit 1
     fi
     echo "INSTALL_PATH_FILE=$INSTALL_PATH_FILE"
     ```
     If the sentinel-stripped `$(cat "$INSTALL_PATH_FILE")` read comes back empty, **stop here — before
     Phase 2, or any round, ever starts** — and tell the user to install the plugin; never fall back to
     `codex:codex-rescue` silently. The `rm -f "$INSTALL_PATH_FILE"` immediately before that `exit 1` is a
     LOCAL, immediate cleanup, not the cross-session sweep item 1 above used to (mis)handle —
     `REPO_ROOT_FILE` does not exist yet at this point (it is resolved in item 6, after this item), so
     there is nothing else to clean up here. This is safe to write as a direct `rm -f "$INSTALL_PATH_FILE"`
     reference, not the `$(cat "$FILE")`-through-a-file idiom used for consuming the value elsewhere: this
     cleanup runs in the SAME Bash tool call/shell where `INSTALL_PATH_FILE` was just assigned moments
     earlier (Step 0 is one contiguous flow up to this exit), so the variable genuinely is still live here
     — this is not the cross-tool-call shell-state problem the rest of this file works around. Doing this
     check once, right now, means a missing-plugin error surfaces immediately at the start of the run
     rather than only after Phase 2 begins. Otherwise, read back this call's own printed
     `INSTALL_PATH_FILE=` line and remember that exact literal `INSTALL_PATH_FILE` path (`mktemp`'s random
     suffix and all) for the rest of the run — exactly like `REPO_ROOT_FILE` below, it is allocated ONCE
     here, never re-allocated, and never assumed to survive as a shell variable into the "Codex invocation"
     section's own call, the Liveness watcher's primary dispatch block, or any other later,
     separately-dispatched tool call. Every place later in this file that shows
     `"$INSTALL_PATH/scripts/run-codex-review.sh"` means: read `INSTALL_PATH_FILE`'s content via
     `$(cat "$INSTALL_PATH_FILE")`, strip the trailing `x` sentinel via `${VAR%x}` into a plain
     `INSTALL_PATH` variable, then use `"$INSTALL_PATH/scripts/run-codex-review.sh"` — substitute through
     the file, with the sentinel stripped, every time, exactly like `REPO_ROOT`/`--cwd` below, never a
     hand-typed literal path string. This file is best-effort cleaned up in Phase 3 at the end of the run
     (see "Final Report to User" below).

  5. **Capture-eventlog support preflight — only when capture was determined ON in item 2 above, and
     only right here, before the TASK below ever runs.** Without this, an outdated wrapper's rejection of
     `--capture-eventlog` would only surface reactively, on Phase 2's first round — meaning a user who
     explicitly asked for `--capture-evidence` on an outdated plugin would waste an entire Review → Plan
     → Research → Implement → Verify TASK execution first, before ever learning capture can't happen.
     Using the `INSTALL_PATH_FILE` just resolved in item 4, do one cheap, side-effect-free check — reading
     it back the same sentinel-stripped way as every other consumption site. **The wrapper has no `--help`
     mode at all** — any unrecognized flag (including `--help` itself) hits its generic
     `unknown argument: <flag>` rejection path, so a `--help | grep` probe (an earlier revision of this
     check) would report "NOT supported" unconditionally, even against a wrapper that fully implements
     `--capture-eventlog` — confirmed directly against the real installed wrapper. The reliable,
     side-effect-free probe instead calls the wrapper with `--capture-eventlog` and **no value and no
     other arguments**: the wrapper's own arg parser checks "is this flag recognized" before "is a value
     present", so an unrecognized flag still reports `unknown argument: --capture-eventlog`, while a
     recognized one instead reports its distinct `--capture-eventlog requires a value` message — and either
     way the process exits immediately on that missing-value check, before reaching any diff collection or
     Codex invocation, so nothing is actually reviewed:
     ```bash
     INSTALL_PATH="$(cat "$INSTALL_PATH_FILE")"; INSTALL_PATH="${INSTALL_PATH%x}"
     if "$INSTALL_PATH/scripts/run-codex-review.sh" --capture-eventlog 2>&1 | grep -q '"detail":"--capture-eventlog requires a value"'; then
       echo "capture-eventlog: supported"
     else
       echo "capture-eventlog: NOT supported — run /plugins-update" >&2
       rm -f "$INSTALL_PATH_FILE"
       exit 1
     fi
     ```
     If that exact `"detail":"--capture-eventlog requires a value"` message is not present in the wrapper's
     output, **stop here — before the TASK below runs, before Phase 1, before Phase 2** — and tell the user
     to run `/plugins-update` to pick up a wrapper version that supports it (see the "Version requirement"
     caveat under "Investigation evidence capture" above). The `rm -f "$INSTALL_PATH_FILE"` immediately
     before that `exit 1` is the same LOCAL, immediate cleanup as item 4's own early exit above, for the
     same reason (this is still the same contiguous Step 0 flow, and `REPO_ROOT_FILE` still does not exist
     yet — it is resolved in item 6, after this item). Skip this item entirely when capture is OFF for this
     session — no extra wrapper call, no added latency, matching the "Off by default" behavior documented
     there.

     **After the user runs `/plugins-update`: re-resolve, don't just retry in place.** This preflight's
     own `exit 1` ends the entire run, so there is no live process left to "retry" — the only way to
     proceed is a brand-new `codex-direct-review:ccd` invocation. Make this explicit rather than assumed: once the user
     confirms `/plugins-update` has completed, tell them to re-run `codex-direct-review:ccd` itself (not some other kind of
     retry) — a fresh invocation is what actually re-runs Step 0 from item 4 onward, including a new `jq`
     lookup into a freshly `mktemp`-allocated `INSTALL_PATH_FILE`, which is what picks up
     `installed_plugins.json`'s now-updated entry and the new version's install path before re-attempting
     this same preflight check. (Contrast this with the reactive per-round fallback in the "Version
     requirement" callout under "Investigation evidence capture" above, where the process does NOT exit
     and a stale `INSTALL_PATH_FILE` really would persist without an explicit re-resolution step — that
     case needs the re-resolution spelled out because there is no natural fresh-invocation reset to rely
     on.)

  6. **Repo root:** resolve the repo root Claude is reviewing — via `pwd`, or however Phase 0's own
     ARTIFACT-resolution below otherwise determines the target directory — once, right here, and remember
     it exactly like `INSTALL_PATH_FILE` above: a session-constant value, resolved ONCE, never re-resolved
     per round. Because it is handed to `run-codex-review.sh` as the `--cwd` argument in every round (see
     "Codex invocation" above), and a raw path interpolated directly into a double-quoted argument has the
     identical shell-injection exposure already fixed for `--focus` (see "Why the focus text — and the
     repo root passed to `--cwd` — go through a file" above), write it into a small file once, via
     `mktemp`, and substitute it through that file from here on — never inline, and never via an
     intermediate `printf '%s' "<value>"` step that would require re-typing the already-resolved path as
     a quoted literal (the identical unsafe pattern this fix eliminates for `INSTALL_PATH` in item 4
     above: if the resolved path ever contained a literal `"`, hand-retyping it that way would break out
     of the intended string). Instead, redirect the resolving command's OWN stdout directly into
     `REPO_ROOT_FILE`, with the same trailing `x` sentinel appended as `INSTALL_PATH_FILE` above (see "Why
     the write side appends a trailing x sentinel" under "Codex invocation" above) — without it, a repo
     root that happened to end in a literal newline byte would come back silently shortened every time it
     is later read via `$(cat "$REPO_ROOT_FILE")`:
     ```bash
     REPO_ROOT_FILE=$(mktemp "/tmp/ccd-${SESSION_ID}-repo-root.txt.XXXXXX")
     { printf '%s' "$PWD"; printf 'x'; } > "$REPO_ROOT_FILE"   # or whatever command actually determined the target directory above
     echo "REPO_ROOT_FILE=$REPO_ROOT_FILE"
     ```
     Remember this exact literal `REPO_ROOT_FILE` path (`mktemp`'s random suffix and all) for the rest of
     the run. Every place later in this file that constructs a `--cwd` argument — the "Codex invocation"
     section's example and the Liveness watcher's primary dispatch block — must read it back as
     `REPO_ROOT="$(cat "$REPO_ROOT_FILE")"; REPO_ROOT="${REPO_ROOT%x}"` and then use `--cwd "$REPO_ROOT"`
     — the exact same sentinel-stripping idiom `FOCUS_FILE` uses for `--focus`
     (`FOCUS_TEXT="$(cat "$FOCUS_FILE")"; FOCUS_TEXT="${FOCUS_TEXT%x}"` then `--focus "$FOCUS_TEXT"`) —
     never `--cwd "<repo root>"` with the path interpolated
     directly, and never a bare `--cwd "$(cat "$REPO_ROOT_FILE")"` or `--focus "$(cat "$FOCUS_FILE")"`
     with the sentinel left unstripped.
     This file is best-effort cleaned up in Phase 3 at the end of the run (see "Final Report to User"
     below), alongside `INSTALL_PATH_FILE`.
- **If `$ARGUMENTS` (after stripping the prefix in Step 0, if it was present) is non-empty:** it is the TASK. Perform it now, end-to-end (Review → Plan → Research → Implement → Verify). The result is the **ARTIFACT**.
- **If `$ARGUMENTS` (after stripping the prefix in Step 0, if it was present) is empty:** the ARTIFACT is the work **just completed in THIS session**. If none is identifiable, fall back to current uncommitted git changes — collect them **without mutating the index**: `git status --short --untracked-files=all` + a `git diff --no-ext-diff --no-textconv` against `$DIFF_BASE` (see the unborn-HEAD guard immediately below) + read untracked files directly, subject to the defensive discipline below (do NOT use `git add -N`, which writes intent-to-add entries into the index). If still nothing concrete, run
  `rm -f "<the exact literal REPO_ROOT_FILE path from Step 0 item 6>" "<the exact literal INSTALL_PATH_FILE path from Step 0 item 4>"`
  — both are already allocated by this point, unlike at items 4/5's own earlier exits above — then ask
  the user what to review and stop. Unlike items 4 and 5's own inline `rm -f` (each still inside Step
  0's own contiguous shell), this ARTIFACT-resolution bullet can easily be a later, separately-dispatched
  tool call — so, exactly like every other cross-tool-call reference to these two files in this file
  (e.g. the "Codex invocation" section's own `INSTALL_PATH_FILE="<the exact literal ...>"`), write in the
  exact literal `mktemp`-resolved paths Claude already remembers from Step 0 by hand here, never a bare
  `"$REPO_ROOT_FILE"`/`"$INSTALL_PATH_FILE"` expecting a shell variable to have survived. This is still a
  LOCAL, immediate cleanup at the point of use — not the cross-session sweep item 1 used to (mis)handle —
  it just uses the file's standard literal-value idiom rather than a live bash variable, since this exit
  point is not guaranteed to share Step 0's own shell.
  - **Unborn-HEAD guard (identical to Phase 1's own `DIFF_BASE`).** A brand-new repo with no commits yet
    has no `HEAD` to diff against, so a plain `git diff ... HEAD` fails outright, and without this guard
    this fallback would wrongly collect zero diff content even when there are real staged-but-uncommitted
    changes to review. Apply the exact same guard Phase 1 already established below — this is the same
    guard reused, not a separate one, so both places handle a brand-new, unborn-HEAD repo consistently:
    ```bash
    if git rev-parse --verify -q HEAD >/dev/null 2>&1; then DIFF_BASE="HEAD"; else DIFF_BASE="$(git hash-object -t tree /dev/null)"; fi
    git diff --no-ext-diff --no-textconv "$DIFF_BASE"
    ```
  - **Why `--no-ext-diff --no-textconv` on the `git diff ... $DIFF_BASE` call.** A plain `git diff HEAD`
    can be configured — via the repo's `.gitattributes`/`.git/config`, or an inherited
    `GIT_EXTERNAL_DIFF` environment variable — to invoke an arbitrary external diff program or textconv
    filter for certain files, which would then execute before the review even starts. Confirmed directly:
    setting `GIT_EXTERNAL_DIFF` and running a plain `git diff HEAD` actually invoked it. The installed
    wrapper's own real diff-collection code already always passes `--no-ext-diff --no-textconv` for
    exactly this reason — this fallback must match it. (`git status --short --untracked-files=all` needs
    no such flags; only the `git diff ... $DIFF_BASE` invocation does.)
  - **Defensive discipline for reading untracked files directly.** Before reading any untracked file's
    content, verify it is a genuine regular file — not a symlink (which could point outside the repo to
    something sensitive) and not a FIFO/device/other special file (which could hang a blocking read).
    Skip and note (never silently ignore, never crash on) anything that fails this check. This is not
    optional caution for "only" a fallback path: this exact project's own "Known Failure Patterns"
    section (near the end of this file) documents having been bitten by precisely this chain before — a
    fix for missing untracked-file coverage introduced a symlink-dereference leak, the fix for that leak
    introduced a TOCTOU race between the check and the read, and the fix for that race reintroduced a
    FIFO-hang the original naive code had accidentally avoided.

    Be honest about what this check-then-read sequence can actually guarantee, though: it is a genuine
    TOCTOU race — the file could in principle be swapped for a symlink in the window between the
    regular-file check and the actual read — and plain shell/prose instructions executed via the Read
    tool have no way to close it. Bash has no equivalent of an atomic `O_NOFOLLOW`-at-open-time syscall
    flag; that requires real syscall-level control over the open, not a shell test followed by a separate
    read. This is a real gap, not a hypothetical one, and this file does not claim otherwise — matching
    how this file already describes the `rm -f` privacy contract's own residual risk elsewhere (see
    "Investigation evidence capture" step 4 above). The regular-file/not-symlink check above is kept as a
    best-effort, non-atomic mitigation: it narrows the window and catches the common case, even though it
    cannot close the race.

    What actually bounds the risk is scope: this fallback's file-reading feeds only Claude's own
    PRELIMINARY judgment in Phase 0 — deciding whether there is "anything concrete" to review at all,
    before Phase 1/2 ever start. It is NOT the material that actually gets sent to and reviewed by Codex.
    The REAL review material, once Phase 2 dispatches a round via `--uncommitted`, is independently
    re-collected by the installed `codex-direct-review` wrapper's own real untracked-file collector, which
    DOES have the atomic `O_NOFOLLOW | O_NONBLOCK` protection for exactly this learned reason. So the
    residual, non-atomic risk here is narrowly scoped to a preliminary scoping judgment Claude makes for
    itself — Phase 0's fallback must still apply the best-effort check above just because it is Claude
    reading the files directly rather than the wrapper, but it does not need to, and cannot in pure shell,
    match the wrapper's atomicity guarantee to be safe enough for that narrow purpose.

## Phase 1 — Determine Review Mode (Parallel vs Single)

**Non-repo artifact round? Skip this Phase's sizing logic entirely — always single-reviewer, never
parallel.** This is the exact same non-repo-artifact case the `CLEAN_REPO_DIR` throwaway-repo isolation
mechanism handles (see "Always give Codex the actual material to review" → "The fix" under "Liveness
watcher" above): a round where there is no actual code diff to review, just pasted content (analysis,
generated text, a plan). For such a round, `CLEAN_REPO_DIR` is by construction a freshly-`git init`'d,
unborn-HEAD repo with zero commits and nothing ever staged — so the sizing command below, if run against
it, would always trivially return `0` files. Running it would not be wrong exactly, but it would be
pointless: there is no diff to size and nothing to split BY FILE COUNT in the first place, since Phase
1's whole heuristic below measures file count and this case has none. Do not attempt to redirect the
sizing command at `$CLEAN_REPO_DIR` (it would always report empty) and do not run it against the real
working tree either (per the artifact-isolation fix above, that would size unrelated dirty files in the
user's actual repo and could wrongly trigger parallel mode for a review that has nothing to do with
those files). Instead: **a non-repo-artifact round always and unconditionally uses single-reviewer
mode, never parallel mode** — skip the sizing command, the table, and the splitting guidance below
entirely, and dispatch exactly one group (`GROUP="main"`) against `CLEAN_REPO_DIR`. The actual "size" of
an artifact-only review is the length/complexity of the pasted focus text, not something this Phase's
file-counting heuristic was ever built to measure or split by — there is no diff to size and no file set
to partition by review dimension in the first place, so the parallel-mode machinery below (the table, the
splitting guidance, the multi-group dispatch) simply does not apply to this case at all. **Genuine
repo/code-diff rounds are unaffected** — everything below this note applies to them exactly as before.

**Before sending to Codex, assess the review scope (repo/code-diff rounds only — see the exception
above for a non-repo-artifact round):**

```bash
if git rev-parse --verify -q HEAD >/dev/null 2>&1; then DIFF_BASE="HEAD"; else DIFF_BASE="$(git hash-object -t tree /dev/null)"; fi
{ git diff --name-only "$DIFF_BASE"; git ls-files --others --exclude-standard; } | sort -u | wc -l  # or count the files/items to review
```

This counts both tracked-modified files (`git diff --name-only "$DIFF_BASE"`) and untracked files
(`git ls-files --others --exclude-standard`), deduplicated — a `git diff --name-only HEAD | wc -l`-only
count would miss untracked files entirely, undercounting the real review scope (e.g. a repo with many
new untracked files but no tracked-modified ones would wrongly size as "0 files / small"). This matches
Phase 0's own fallback artifact-collection rule and the installed wrapper's actual `--uncommitted`
behavior, both of which already include untracked files. The `DIFF_BASE` guard handles a brand-new repo
with an unborn `HEAD` (no commits yet): `git diff ... HEAD` fails outright when there is no `HEAD` to
diff against, so without this guard a new repo with many STAGED-but-uncommitted files would be
undercounted here even though those files are real review scope. Falling back to the empty-tree SHA
(`git hash-object -t tree /dev/null`) as the diff base in that case mirrors the installed wrapper's own
real collection code, which already special-cases an unborn `HEAD` the same way.

**What "parallel mode" actually is — read this before the table below.** The installed wrapper accepts
only `--uncommitted`/`--base`/`--commit` as review-scope selectors — there is no `--paths`/file-filter
flag (confirmed directly: passing `--paths` returns
`{"ok":false,"reason":"bad_args","detail":"unknown argument: --paths"}`), and `--uncommitted`'s collector
always reviews the ENTIRE working-tree diff plus all untracked files, every time, no matter what
`--focus` text accompanies it. So every parallel "group" dispatched this way receives the IDENTICAL full
diff — the groups differ ONLY in their `--focus` review-angle prompt, never in the actual material
reviewed. Parallel mode is therefore multiple concurrent reviewers each given the SAME full diff but a
DIFFERENT dimensional focus (e.g. one call's `--focus` emphasizes correctness, another's emphasizes
security, a third's emphasizes performance/reuse) — genuinely useful for broader, more attentive
coverage of a large or many-concerned diff via diverse reviewer attention, and for getting several
review angles back within one wall-clock window via concurrent dispatch. **It is NOT a way to shrink any
single call's context size or avoid a timeout risk from sheer diff size** — every group's Codex process
still has to read the same full diff regardless of how many groups are running. A genuinely oversized
diff still needs the existing "Known Failure Patterns" timeout-handling guidance (a narrower `--focus`
in the sense of a narrower TOPICAL concern, not a narrower file set) or manual review — not more
parallel dispatches of the same full material.

| Scope | Strategy |
|-------|----------|
| Small (< 20 files, single concern) | **Single Codex agent** — standard flow |
| Medium (20–50 files, or multiple concerns) | **2–3 parallel Codex agents** — same full diff, one review dimension/concern each |
| Large (> 50 files, or large skill/doc files, or broad audit) | **3+ parallel Codex agents** — same full diff, one focused review dimension/concern each |

**When to use multiple reviewers (flexible judgment) — grouped BY REVIEW DIMENSION/CONCERN, since that
is the only thing a group's `--focus` can actually vary:**
- The task spans multiple unrelated concerns worth distinct reviewer attention (e.g., path correctness +
  workflow quality + consistency + security)
- A large or many-concerned diff benefits from several reviewers' independent, differently-focused
  passes, even though each one reads everything
- Wanting several review angles back within the same wall-clock window (concurrent dispatch, not
  sequential rounds)
- Codex reviewers have died silently in previous iterations (idle without output) — running several
  concurrently improves the odds at least one produces usable output this round, though it does not fix
  the underlying cause of a stall (see "Codex stalls without producing output" below)

Do NOT reach for parallel mode believing it reduces what any one reviewer has to read, or that "review
content is voluminous" or "one agent may exhaust context" are, by themselves, reasons a SPLIT helps —
every group still gets the full diff, so a single reviewer's context exhaustion on that diff will recur
in every parallel group just the same.

**How to split (parallel mode):** group BY REVIEW DIMENSION/CONCERN — e.g. one group's `--focus`
emphasizes correctness, another's emphasizes security, a third's emphasizes performance/reuse, a fourth's
emphasizes path correctness or workflow consistency for a doc/skill review. There is no file-count
partition to make: every group calls `run-codex-review.sh --uncommitted` against the SAME repo diff,
differing only in `--focus` text, since the wrapper has no path-filtering flag and always reviews the
entire uncommitted diff plus all untracked files regardless of `--focus` (see above). Run each group's
call at the same time (e.g. one Bash `run_in_background` invocation per group, each with its own
`--focus`) → wait for all → synthesize. If a call times out or fails (`"ok":false`) → re-run that group
with a narrower FOCUS scope — a narrower topical/dimensional concern, not a smaller file set, since the
wrapper cannot filter files — or fall back to manual review for that concern.

## Phase 2 — Converge loop (R = 1 … 20)

For each round R:

1. **Call the Codex wrapper** (see the Codex invocation contract above) for adversarial review (English, read-only). Ask Codex to find real defects AND challenge questionable design/assumptions, reporting each concern with evidence (file:line + why it is wrong/risky) so it can be verified.
   - Every round — R == 1 and R > 1 alike — is an independent, fresh `run-codex-review.sh` call. There is no `--fresh`/`--resume`/`--wait` distinction (those were `Agent`-tool-call semantics, not wrapper flags): each call is its own ephemeral process, and there is no session to resume into.
   - **`--focus` is a briefing, not a nitpick list — required every round, not just round 1.** The wrapper's own prompt template labels this content "Context: why this review is being requested" and tells Codex to review WITH that intent in mind, not judge the diff as isolated text. Never send just the diff and a generic "review this" — that is exactly the shallow, context-blind review this requirement exists to prevent. Every round's `--focus` must cover:
     - **Why** — the actual underlying problem/task this change addresses, not merely a restatement of what changed. If you don't know why, that is itself a sign to find out (read the surrounding conversation/history) before dispatching, not to send a context-free diff.
     - **History** (R > 1) — fixes applied since last round and findings REJECTED last round with evidence, built from the **review history log** (see below), not from memory alone. Ask Codex to label each prior rebuttal accepted/rejected/unresolved, and either confirm clean or raise only substantiated remaining concerns.
     - **Scope** — what to specifically verify THIS round given the nature of THIS change (e.g. "this touches signal handling — trace the actual process tree, don't just read the diff text"; "this changes a function signature — grep every caller"). Tailor this to what actually changed; a generic scope note that would apply to any diff is not this.
   - Note: proactive investigation (reading full files, checking callers, tracing control flow, verifying claims against real state) and the narrow→wide→narrow review methodology (Known Failure Patterns' whole-flow principle, applied to Codex's own initial review, not only Claude's post-fix check) are ALREADY baked into the wrapper's fixed prompt template — do not re-explain those in `--focus`; use the space for the specific Why/History/Scope content above instead.
   - Always fold the ⚠️ SCOPE CONSTRAINT block's content into that same `--focus` text (it is no longer a separate Agent-tool prompt section — it's just more text in the one string you pass to the wrapper):
     ```
     ⚠️ SCOPE CONSTRAINT:
     - Do NOT open or read files under node_modules/, .pnpm/, or any generated/vendor directory
     - Limit reads to source directories (e.g. packages/*/src/, apps/*/src/) and git diff output
     - For type/API questions, grep source files or check the git diff — not installed package types
     ```
   - First, pre-allocate this round's temp files via the quick foreground `mktemp` call (Liveness watcher step 0), write this round's composed focus text (Why/History/Scope plus the SCOPE CONSTRAINT block below) plus a trailing `x` sentinel with no newline in between into the pre-allocated `FOCUS_FILE` using the Write tool, then dispatch the wrapper via a backgrounded Bash call using those exact literal paths (reading it back as `FOCUS_TEXT="$(cat "$FOCUS_FILE")"; FOCUS_TEXT="${FOCUS_TEXT%x}"` and passing `--focus "$FOCUS_TEXT"`, never the focus text interpolated inline and never the sentinel left unstripped — see the Codex invocation contract above), then start the paired `Monitor` liveness watcher — remain free to converse with the user while both run, do not block the turn on it. Resume this round's steps 2-5 once a result arrives from either channel.
   - **Parallel mode (more than one group dispatched this round):** each group gets its own `FOCUS_FILE`,
     its own dispatch, and its own `codex_review` result — dispatched per Phase 1's splitting guidance,
     one group's own `--focus` text emphasizing one review dimension/concern, another's emphasizing a
     different one. As each group's call completes, keep that group's own exact `--focus` text and its own
     parsed `codex_review` result (verdict + findings) around, tagged by that group's slug — these are what
     step 5 below assembles into the round's `groups` array and the aggregated top-level `target.focus`/
     `codex_review` summary (see "Review history log" → the `groups` bullet above). A single-reviewer round
     has only one group's result to carry forward, which becomes the round's own `target.focus`/
     `codex_review` directly, unchanged.

2. **Receive Codex's findings. DO NOT blindly accept them.** For a parallel round, this means every
   dispatched group's own findings — step 3's re-verification below must go through EACH group's findings
   individually, not just a merged/aggregated view of them.

3. **Re-verify EACH finding against facts/evidence** — Read the actual file, run the actual command, check tests/official docs. Never rely on a single tool result alone (e.g., if a grep returns empty, verify the glob pattern covers the right paths before treating it as counter-evidence). Default posture: treat every finding as *possibly a false positive*, but be equally willing to be proven wrong. Symmetric skepticism.
   - **VALID** → fix it directly when permitted, or delegate a validated substantial/multi-file fix to the active Claude implementation agent, then verify the resulting diff and tests yourself.
   - **FALSE POSITIVE** → do not change; rebut with the actual observed output/evidence (file/line/command) — never rebut without concrete evidence.
   - **PARTIAL** → fix the valid part, rebut the rest.

3.5. **Whole-flow re-check (narrow → wide → narrow) — for any fix applied this round.** Before moving
   on, zoom OUT from the isolated fix to the whole affected file/function's control flow (not just the
   new lines), then zoom back IN:
   - Does the fix introduce the same class of problem it just fixed, in a new form?
   - Is it consistent with how the rest of the file already handles similar cases (e.g. do sibling
     exit paths all clean up the same resources; do sibling checks use the same safe pattern)?
   - Does a sibling code path need the identical fix and not yet have it?
   This exists because a narrow, line-scoped fix is exactly the kind of change that shifts or
   reintroduces a bug rather than resolving it. Confirmed pattern from this project's own history: a
   fix for missing untracked-file coverage introduced a symlink-dereference leak; the fix for that
   leak introduced a TOCTOU race between the check and the read; the fix for that race (open before
   checking type) reintroduced a FIFO-hang the original naive code had accidentally avoided by
   checking the file type before ever opening it. Catching this yourself here, before dispatching the
   next round, converges faster than waiting for Codex to catch it — see also "A fix introduces the
   same class of bug it fixed" under Known Failure Patterns.

4. **Convergence check** (below).

5. **Narrate progress** — one English line: `Round R/20: Codex N findings → accepted A / rebutted B — <clean | continuing>`. If this round dispatched more than one group (parallel mode), first merge each group's own `INVESTIGATION_EVIDENCE_JSON` into one `MERGED_INVESTIGATION_EVIDENCE_JSON` per "Investigation evidence capture" step 3 above, and use that merged object as this round's single `investigation_evidence` value; a single-reviewer round has nothing to merge and uses its own extraction directly. Likewise, merge each group's own coverage outcome into one `MERGED_COVERAGE_SOURCE_JSON` per "Codex invocation" → "Merging multiple groups' coverage into one value" above (worst-case wins: any group's `"partial"` or `"unknown"` forces the round's overall `coverage_source` to non-`"complete"`), and use that merged value as this round's single `coverage_source` field; a single-reviewer round again has nothing to merge and uses its own reported value directly. **Also at this same point, construct this round's `groups` field and its top-level `target.focus`/`codex_review` values** per "Review history log" → the `groups` bullet above: for a single-reviewer round, `target.focus`/`codex_review` are just that one group's own values and `groups` is omitted, exactly as before; for a parallel round, assemble the `groups` array from each dispatched group's own `--focus` text and `codex_review` result kept from step 1 above, then derive the synthesized `target.focus` summary string and the worst-case-wins aggregated `codex_review` (verdict + group-tagged `findings`) from that same array. Then append this round's line to the review history log (see below) — best-effort, never blocks the loop. Right after that, also best-effort clean up this round's now-unneeded `.pid`, `-out.json`, and `-focus.txt` temp files — nothing needs to read them again once this round is done: `rm -f "<the exact literal PID_FILE path>" "<the exact literal OUT_FILE path>" "<the exact literal FOCUS_FILE path>"`, reusing the same literal paths remembered from the Liveness watcher's step 0 (per group, if parallel mode dispatched more than one). Same discipline as the log write — a failed `rm` is noted at most, never a reason to stop or retry.

### Convergence = 100% CLEAN (ALL must hold)
- Codex has no substantiated open findings in its latest review (it signs off / returns nothing new), **AND**
- Claude has no open items (no pending fixes; Codex accepted Claude's rebuttals, or Claude accepted Codex's counter), **AND**
- **For a round that dispatched more than one group (parallel mode): the above two conditions hold for
  EVERY dispatched group's OWN findings individually, not merely for the aggregated top-level
  `codex_review` summary.** The aggregated top-level verdict (see "Review history log" → the `groups`
  bullet above) already reports `"ISSUES"` if any group had one, so an aggregated `"CLEAN"` is a necessary
  signal — but it is not sufficient by itself: Phase 2 step 3's re-verification (and step 3.5's whole-flow
  re-check) must have gone through EACH group's own `findings` array from its own `codex_review` result,
  exactly the same way a single-reviewer round's findings are individually re-verified, not skipped in
  favor of glancing at the merged view. A single-reviewer round has only one group's findings to begin
  with, so this adds no extra work there — it only matters once `groups` is actually populated. A group
  that returned `"ok":false` has no `findings` array to re-verify at all — per the Guards' extended
  "Empty / failed review ≠ CLEAN" rule below, such a round is not eligible for `✅ CLEAN` until that group
  is successfully retried, regardless of how clean every other group's own findings turned out to be.
  **AND**
- For a round whose scope is `--uncommitted`: the latest round's `coverage_source.status` (see "Review
  history log" above) is EXPLICITLY `"complete"` — never assumed. **For a round that dispatched more than
  one group (parallel mode), this means the MERGED `coverage_source` value** computed per "Codex
  invocation" → "Merging multiple groups' coverage into one value" above — i.e. `"complete"` only if
  EVERY dispatched group's own coverage was `"complete"` — never any single group's own value in
  isolation; a single-reviewer round has nothing to merge and its own reported value is used directly, as
  always. `"partial"` and `"unknown"` (the sentinel recorded when the wrapper omitted `coverage.source`
  entirely on an `--uncommitted` round — see "Codex invocation" above) fail this condition identically,
  whether that status came from a single reviewer or from the merge, unless every path in a `"partial"`
  round's `omitted` list — or, for `"unknown"`, the change as a whole — has since been explicitly
  reviewed some other way (Claude manually inspected it and says so) or explicitly accepted as
  out-of-scope by the user, with that decision recorded in the round's narration/log. A code-level
  `"CLEAN"` `verdict.verdict` on a round whose (possibly merged) coverage is still `"partial"` or
  `"unknown"` and unresolved does NOT satisfy this condition by itself. For `--base`/`--commit` scope,
  this condition is automatically satisfied — coverage is legitimately never reported for those scopes
  (see "Codex invocation" above), so its absence there is not a gating condition at all.
→ Stop the loop, go to Phase 3 as **✅ CLEAN**.

### Guards
- **Never fake-clean.** If Claude and Codex genuinely disagree and neither side yields on evidence, that is NOT convergence.
- **Cap:** if R reaches 20 without convergence, stop and report **⚠️ NOT CONVERGED**, listing every open disagreement (the finding, Codex's position, Claude's evidence-based counter, and why it stayed unresolved). Do not overstate the result.
- Codex raising new issues in later rounds is fine (the cap bounds it) — act only on substantiated ones.
- If a round makes **zero progress twice in a row** (same open-disagreement set, no new evidence, no accepted rebuttal/counter, no artifact change — check the last two rounds' `action` fields in the review history log rather than relying on memory alone), stop early and report NOT CONVERGED rather than burning the remaining rounds.
- **Empty / failed review ≠ CLEAN.** If a round's wrapper call returns `"ok":false` (see the Codex invocation contract above), do not treat it as convergence. Retry once; if it still fails, stop and report **⚠️ COULD NOT VERIFY** (Codex review unavailable) — never declare CLEAN off a missing review.
  - **Parallel mode — the same rule applies per group, not just to a single-reviewer round.** If ANY
    dispatched group in a parallel round returns `"ok":false` (see "Review history log" → the `groups`
    bullet above for that group's raw-failure `groups[]` entry shape), the ROUND overall is not eligible
    for `✅ CLEAN` — worst-case-wins, the same principle already used for the `codex_review`/
    `coverage_source` parallel merges (see "Codex invocation" → "Merging multiple groups' coverage into
    one value" and "Review history log" → the `groups` bullet above). Retry JUST that failed group once —
    the other groups' real, already-collected results are kept, not thrown away and re-dispatched. If that
    group still fails after one retry, the round-level status is `⚠️ COULD NOT VERIFY`, exactly like the
    single-reviewer case — do not report `✅ CLEAN` for a round where any group never produced a real
    verdict, and do not fold this into `⚠️ NOT CONVERGED`/`⚠️ PARTIAL COVERAGE` instead (those cover a
    genuine Claude/Codex disagreement or an unresolved coverage gap, not a group that never returned a
    review at all).
- **Partial or unknown source coverage ≠ CLEAN, and is not the same failure as NOT CONVERGED/COULD NOT
  VERIFY.** If everything else above would otherwise say converged, but the latest `--uncommitted`-scope
  round's `coverage_source.status` — the MERGED value when that round dispatched more than one group, per
  "Codex invocation" → "Merging multiple groups' coverage into one value" above, or the single reviewer's
  own value otherwise — is still `"partial"` (with unresolved `omitted` paths) or `"unknown"`
  (the wrapper omitted `coverage.source` entirely that round — see "Codex invocation" above), and neither
  has been explicitly reviewed another way nor explicitly accepted as out-of-scope by the user, stop the
  loop and report **⚠️ PARTIAL COVERAGE** instead of `✅ CLEAN` — list every omitted path and its reason
  for a `"partial"` status, or state plainly that the wrapper never reported coverage at all for an
  `"unknown"` status. Both fall under this same terminal status: the key correctness requirement is that
  neither a known-partial nor an unknown/absent coverage result is allowed to silently pass as satisfying
  full coverage. This is a scope-completeness gap, not a disagreement between Claude and Codex, so it
  gets its own status rather than being folded into `NOT CONVERGED`. If the cap (R = 20) is hit while a
  genuine Claude/Codex disagreement AND unresolved partial-or-unknown coverage both remain open, report
  `⚠️ NOT CONVERGED` and list the unresolved coverage gap alongside the open disagreements — the
  disagreement is the more severe unresolved condition in that case.

## Phase 3 — Final Report to User

Deliver the final report **in Korean** (the only Korean output — everything above stays English). Cover:

- **Task / artifact summary** — what was done / what the artifact is.
- **Final deliverable** — for code: what changed (files/behavior); for analysis/generation: the conclusion/deliverable.
- **Review mode** — single / parallel (N groups), and number of rounds.
- **Convergence table** — per round: `[Codex finding → re-verification verdict (accepted/rebutted + evidence) → action taken]`.
- **Consensus status** — exactly one of `✅ CLEAN (N rounds)` / `⚠️ NOT CONVERGED (20-round cap reached, K open disagreements)` / `⚠️ COULD NOT VERIFY (Codex review unavailable)` / `⚠️ PARTIAL COVERAGE (source coverage never fully resolved)`, plus a summary of each open disagreement. Keep the four distinct.
- **Source coverage** — if ANY `--uncommitted`-scope round's `coverage_source.status` was ever
  `"partial"` or `"unknown"` (see "Codex invocation" and "Convergence = 100% CLEAN" above), surface this
  prominently regardless of the final outcome, the same way the sibling `codex-review` skill already does
  for its own single-shot reviews: for `"partial"`, list the omitted paths and reasons; for `"unknown"`,
  state plainly that the wrapper omitted `coverage.source` entirely that round and coverage could not be
  confirmed. Either way, state whether it was later resolved (re-reviewed as complete, manually inspected
  by Claude, or explicitly accepted as out-of-scope by the user) or remains unresolved (→ the
  `⚠️ PARTIAL COVERAGE` status above). Never let a `✅ CLEAN` headline imply every changed file was
  actually inspected when some were skipped as binary, oversized, a symlink, or unreadable, or when
  coverage status simply was never reported that round — say plainly that some source was not inspected
  or confirmed rather than letting "CLEAN" imply nothing was missed.
- **Verified / not verified / remaining risks & assumptions** — honestly (never claim "done" for something only written and not exercised).

Before or after delivering the report (order doesn't matter — this is best-effort and never blocks the
report), clean up this session's session-level temp resources: `REPO_ROOT_FILE`/`INSTALL_PATH_FILE`,
allocated once in Phase 0 Step 0, plus `CLEAN_REPO_DIR` (see "Always give Codex the actual material to
review" above), allocated lazily the first time this session actually needed a non-repo-artifact review —
all used across every round of this run. This is a fresh, separately-dispatched Bash tool call — exactly
like every other place in this file that consumes `REPO_ROOT_FILE`/`INSTALL_PATH_FILE`, there is no live
shell variable surviving from Phase 0 Step 0's own tool call (or from whichever round first allocated
`CLEAN_REPO_DIR`), so write in the exact literal paths Claude remembered from there by hand, never a bare
`"$REPO_ROOT_FILE"`/`"$INSTALL_PATH_FILE"`/`"$CLEAN_REPO_DIR"` expecting a shell to have carried them
forward:
```bash
rm -f "<the exact literal REPO_ROOT_FILE path from Phase 0 Step 0 item 6>" "<the exact literal INSTALL_PATH_FILE path from Phase 0 Step 0 item 4>"
# only if this session ever actually allocated one (most sessions never do — see "Always give Codex the
# actual material to review" above):
rm -rf "<the exact literal CLEAN_REPO_DIR path, if one was allocated this session>"
```
Unlike the per-round `.pid`/`-out.json`/`-focus.txt` files already cleaned up in Phase 2 step 5, these
are session-scoped and have no earlier cleanup point — this is the fast-path removal for the common
case (a session that reaches Phase 3 normally). Same discipline as every other cleanup in this file: a
failed `rm` is not worth noting to the user.

**This fast path alone doesn't cover an early abort — that gap is closed locally, not by a shared
sweep.** If Phase 0 itself exits before ever reaching Phase 3 — e.g. the `$INSTALL_PATH_FILE`
empty-path check in item 4 fails, or the capture-eventlog preflight in item 5 fails, or Phase 0's own
ARTIFACT-resolution step finds nothing concrete to review — `REPO_ROOT_FILE` and/or `INSTALL_PATH_FILE`
may already have been allocated and are then never reached by this Phase 3 `rm -f`. An earlier revision
of this file tried to close that gap with a shared, cross-session `find ... -mmin +60 -delete` sweep in
Phase 0 Step 0 — reusing the same mechanism already used for orphaned eventlog files. That was wrong:
unlike an eventlog, `REPO_ROOT_FILE`/`INSTALL_PATH_FILE` are meant to stay alive for a session's ENTIRE
multi-round run (which can legitimately exceed 60 minutes across up to 20 rounds), so that sweep could
delete another CONCURRENTLY-RUNNING session's still-in-use tracking files out from under it — a real
functional break (that session's next `$(cat "$FILE")` read comes back empty, producing `--cwd ""` or
an empty wrapper-path invocation, which the wrapper rejects as `bad_args`), not a narrow, merely
theoretical edge case. The fix: each of Phase 0's own early-exit points now runs its own LOCAL,
immediate `rm -f` for whichever of the two files was actually allocated by that point — items 4 and 5's
own exits do it inline, in the SAME Bash tool call/shell where `INSTALL_PATH_FILE` was just assigned
moments earlier (`REPO_ROOT_FILE` isn't allocated until item 6, so there is nothing else to clean up at
those two exits); the ARTIFACT-resolution bullet right after item 6 does it via the same literal-value
idiom used everywhere else in this file for a later, separately-dispatched tool call, since both files
are allocated by then — see Step 0 items 1, 4, and 5, and the bullet right after item 6, above. There is
no longer a shared cross-session sweep for these two file types, precisely because their legitimate
lifetime is unpredictable and session-scoped in a way eventlog files are not.
This Phase 3 `rm -f` remains the cleanup path for a session that completes normally; each Phase 0
early-exit point's own local cleanup now covers the abort case that this fast path can't reach.

---

## Rules

- Never skip Phase 2 (the converge loop).
- Never accept a Codex finding without verifying the evidence yourself.
- Never dismiss a Codex finding without reading the actual file or running the actual command.
- Always include the `⚠️ SCOPE CONSTRAINT` block in every Codex prompt.
- Keep prompts concise — summaries and evidence pointers, not full file contents.
- Do not report to the user until Phase 3.
- Every round appends one line to the review history log (JSONL) — a failed write is best-effort
  and never blocks the round, but skipping the write on purpose is not allowed.

---

## Known Failure Patterns

### "Empty grep = finding is wrong" (learned 2026-07-14)

An empty search result is **inconclusive**, not counter-evidence. Before rebutting:
1. Verify the glob pattern is correct (`packages/*/tsconfig.json` vs `find . -name tsconfig.json`)
2. Try an alternative search to confirm
3. Only rebut after the alternative search also returns empty AND scope is confirmed correct

### "Codex reads node_modules and runs out of context" (learned 2026-07-15)

When reviewing large changesets, Codex opens type declaration files in node_modules (e.g., `nl -ba packages/common/node_modules/@mui/...`) and silently terminates before producing a final report.

**Prevention:** The `⚠️ SCOPE CONSTRAINT` block in every prompt.
**Detection:** If Codex log shows `node_modules/` reads → constraint was not applied → re-run.

### "Codex stalls without producing output" (learned 2026-07-21)

When review content is too large (long skill files, many files), Codex may stall or exhaust context before finishing. The wrapper call runs in the background; when its completion notification arrives, this surfaces as the wrapper returning `{"ok":false,"reason":"timeout",...}` (the closest match to "Codex stalled"), or occasionally `"reason":"nonzero_exit"` / `"missing_turn_completed"` if it dies or is cut off mid-run instead of cleanly timing out — the wrapper's own internal wall-clock timeout still fires and produces this JSON regardless of how it was dispatched.

**Detection:** the wrapper call returns `"ok":false` with one of those `reason` values, not a `"verdict"` object.
**Response:**
1. Re-run the wrapper with a narrower `--focus` scope — a narrower TOPICAL/dimensional concern (e.g. just
   the auth changes, just the new error-handling paths), not a smaller file set: `--uncommitted` always
   reviews the full diff regardless of `--focus`, since the wrapper has no file-filtering flag (see Phase
   1 above)
2. Split into multiple parallel wrapper calls, one focused review dimension per call (see Phase 1) — this
   spreads reviewer attention across concerns and wall-clock time, but every call still gets the SAME
   full diff, so it does not by itself fix a timeout caused by sheer diff size
3. Do NOT retry with the same large scope — it will time out again
4. If 2+ parallel calls fail on the same scope → manually review that section as Claude

### "A fix introduces the same class of bug it fixed" (learned 2026-08-29)

Fixing a narrow, line-scoped finding often adds new branches/logic with their own edge cases.
Confirmed directly across a real chain of rounds in this project: a fix for missing untracked-file
coverage introduced a symlink-dereference leak → the fix for that leak introduced a TOCTOU race
between the check and the read → the fix for that race (open-before-checking-type) reintroduced a
FIFO-hang the original naive code had accidentally avoided (it checked the file type before ever
opening it). Each fix was individually correct for the finding it addressed and still shifted the
bug sideways rather than closing it.

**Prevention:**
1. Do the whole-flow re-check (Phase 2 step 3.5) after every fix, not only at the end of a round.
2. For a security-sensitive operation (symlink handling, file-type checks, external command
   execution, signal handling), look for the established safe idiom first rather than iterating
   toward safety through review rounds — e.g. `O_NOFOLLOW | O_NONBLOCK` for "open, don't follow
   links, don't block on a FIFO" is a known POSIX pattern, not something to discover by trial and
   error across three rounds.
3. When Codex confirms an earlier fix now conflicts with or reopens an even earlier one, treat that
   as informative, not embarrassing — log it plainly (`linked_finding_id` chains this naturally in
   the review history) and keep converging rather than treating it as a setback.

**Detection:** a later round's finding sits on lines a previous round's fix just touched.
