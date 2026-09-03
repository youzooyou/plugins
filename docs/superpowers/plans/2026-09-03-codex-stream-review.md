# Codex Stream Review Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build `codex-stream-review`, a new, separate, experimental Claude Code plugin that runs Codex reviews via persisted `codex exec`/`codex exec resume` threads, streams live progress by tailing each thread's own rollout JSONL file, and (pending Task 1's spike result) uses an approval-based safety model instead of a blanket read-only sandbox — without touching `/cc` or `codex-direct-review`, which remain exactly as they are today.

**Architecture:** A new plugin directory (`codex-stream-review/`) in the `youzooyou/plugins` marketplace repo bundles a wrapper script (`run-stream-review.sh`) that: starts or resumes a Codex thread via `codex exec`/`codex exec resume --json`, captures the `threadId` from the process's own stdout stream, locates and tails that thread's rollout file (`~/.codex/sessions/<Y>/<M>/<D>/rollout-*-<threadId>.jsonl`) for live progress, waits for the `task_complete` event, extracts the `final_answer`-phase message, and deletes/archives the thread afterward per the data-retention rule. A companion skill documents when/how to invoke it. Tasks 1-5 are verification spikes (see the design doc's own "Open items to spike first") that must each produce a recorded, reproducible finding — appended to the knowledge base doc — before Task 6 (the actual wrapper) is written, because the wrapper's exact shape (sandbox flags, approval-handling code path) depends on what Tasks 1-4 find.

**Tech Stack:** Bash (wrapper script, matching `codex-direct-review`'s own convention — no new language runtime), `jq` (already installed), `codex` CLI (npm/nvm-installed, the exact one already in use this session — no new install), Claude Code plugin/marketplace conventions (`.claude-plugin/plugin.json`, `skills/<name>/SKILL.md`, `${CLAUDE_PLUGIN_ROOT}`).

**Spec:** `docs/2026-09-03-codex-stream-review-design.md` (this plan implements that design — read it first, and its companion `docs/superpowers/plans/2026-09-03-codex-appserver-streaming-knowledge.md` for the full evidence trail behind every claim below).

## Global Constraints

- This plugin is additive only. Never modify `codex-direct-review/` or `~/.claude/commands/cc/SKILL.md` as part of this plan.
- Every thread this plugin creates is **not** ephemeral (persistence is required for `resume`) — every task that creates a thread must also account for deleting/archiving it afterward (see Task 5 and Task 7's cleanup step). No task may leave an orphaned persisted thread as a silent side effect.
- No blind trust of an assumed-safe mechanism: Tasks 1-4 must each produce actual command output/log evidence appended to `docs/superpowers/plans/2026-09-03-codex-appserver-streaming-knowledge.md`, not a "should work" assumption. Task 6 (the wrapper) is blocked on Tasks 1-4's actual recorded outcomes, not their intended outcomes.
- If Task 1 (approval-event spike) fails to find a workable programmatic approval-answering mechanism, the wrapper (Task 6) uses `--sandbox read-only` (no `--ask-for-approval`) instead of the approval-based model — this is an explicit, planned fallback, not a blocker to stop work — record which path was taken in the design doc before proceeding to Task 6.
- `main` branch of `youzooyou/plugins` is protected (PR required). Every task's commit goes to a feature branch; merging via PR is its own explicit step, never silently bundled into a task.
- File paths below are relative to the `youzooyou/plugins` repo root (`~/Work/Develop/plugins`) unless given as an absolute `~/.claude/...` or `~/.codex/...` path.

---

### Task 1: Spike — approval-request event shape and programmatic answer mechanism

**Files:** None (investigation only). Findings recorded in `docs/superpowers/plans/2026-09-03-codex-appserver-streaming-knowledge.md`.

**Interfaces:**
- Produces: a recorded, evidence-backed answer to "can a headless `codex exec`/`codex exec resume` call's approval requests be observed and answered programmatically, and if so, exactly how" — this gates Task 6's sandbox/approval flags.

- [ ] **Step 1: Construct a scratch repo that forces an approval-requiring action**

Create a throwaway git repo (`mktemp -d`, `git init -q`) with one committed file. This spike needs Codex to attempt something `workspace-write` alone wouldn't need approval for but `on-request` policy would still gate (e.g., a network call, or a write outside the repo root) — start with the simplest case: a file write **inside** the repo under `workspace-write` first (should need NO approval — establishes the baseline), then a write attempt **outside** the repo root (should trigger an approval request).

- [ ] **Step 2: Run with `--sandbox workspace-write --ask-for-approval on-request --json`, capture full stdout**

```bash
cd <scratch-repo>
codex exec --sandbox workspace-write --ask-for-approval on-request --json \
  "Write the text hello to a file at /tmp/codex-stream-review-approval-spike.txt (outside this repo)." \
  > /tmp/approval-spike-out.jsonl 2>&1
```

Run this **backgrounded** with the same PID+start-time liveness-watcher pattern `/cc` already uses (don't block synchronously — this may hang waiting on an approval that never comes, which is itself a finding).

- [ ] **Step 3: Inspect the captured stdout and the thread's rollout file for an approval-related event**

```bash
grep -o '"type":"[a-zA-Z._]*"' /tmp/approval-spike-out.jsonl | sort -u
```

Also check the resolved rollout file (via the `threadId` from `thread.started`) for anything matching `approval`, `exec_approval`, `patch_approval`, or similar. Record every event type name observed, verbatim.

- [ ] **Step 4: Determine outcome and record it**

Three possible outcomes, each with a different consequence for Task 6 — record which one actually happened, with the literal captured JSON as evidence:

- **(a) An approval-request event appears in the stream/rollout file, and there is a documented/discoverable way to answer it (e.g., another `codex queue`-style command, or a specific JSON line written back to some file)** → Task 6 implements approval-handling using that exact mechanism.
- **(b) The call simply hangs indefinitely with no approval-request event ever surfacing anywhere observable** → headless approval-on-request is not usable; Task 6 falls back to `--sandbox read-only` (record this explicitly in the design doc as the reason).
- **(c) `--approve-for-me` (routes approval through automatic review) produces a *different*, observable behavior** — test this as a follow-up if (a) is inconclusive: run the same Step 2 command with `--approve-for-me` substituted for `--ask-for-approval on-request` and record whether the write outside the repo actually happens (i.e., whether "automatic review" is a real check or a rubber stamp — inspect whether the file at `/tmp/codex-stream-review-approval-spike.txt` was actually created, and whether the rollout file shows any reasoning about *why* it was or wasn't approved). **If it's a rubber stamp (file created with no recorded justification), do not use `--approve-for-me` for this plugin's stated safety goal** — that would be worse than `--sandbox read-only`, not better.

- [ ] **Step 5: Append findings to the knowledge base doc**

Add a new dated section to `docs/superpowers/plans/2026-09-03-codex-appserver-streaming-knowledge.md` (below the existing "BREAKTHROUGH" section) titled `## Task 1 spike result: approval-request handling`, with the exact commands run, exact event types observed, and which of outcomes (a)/(b)/(c) actually occurred. This is the evidence Task 6 depends on — do not proceed to Task 6 without this section existing and containing real captured output.

- [ ] **Step 6: Clean up scratch artifacts**

`rm -rf` the scratch repo; `rm -f /tmp/approval-spike-out.jsonl /tmp/codex-stream-review-approval-spike.txt` (only if outcome (c) actually created it). Delete/archive the spike's own Codex thread (see Task 5 for the exact delete/archive command once that spike is done — if Task 5 hasn't run yet, note the thread ID here to clean up retroactively once it has).

---

### Task 2: Spike — `codex exec resume` context reuse and token savings

**Files:** None (investigation only). Findings recorded in the knowledge base doc.

**Interfaces:**
- Consumes: nothing from Task 1.
- Produces: a recorded, evidence-backed confirmation (or refutation) of the design doc's core "token efficiency" claim.

- [ ] **Step 1: Start a real thread with a non-trivial diff as context**

Create a scratch repo with a committed baseline file, then a real uncommitted diff (reuse one of this session's own eval-corpus-style fixtures if convenient, e.g. a small function with an off-by-one bug, to have something concrete to ask follow-up questions about). Run:

```bash
cd <scratch-repo>
codex exec --json --sandbox read-only -c model_reasoning_effort=low \
  "Review the uncommitted diff in this repo for correctness bugs. Do not fix anything." \
  > /tmp/resume-spike-round1.jsonl 2>&1
```

Capture the `threadId` from `thread.started`, and note the `token_count` event's reported total for this round (grep the rollout file for `"type":"token_count"` and inspect the payload for a cumulative or per-turn count field — record the exact field name found).

- [ ] **Step 2: Send a follow-up that requires the same context, without re-sending the diff**

```bash
codex exec resume <threadId> --json \
  "Which specific line number is the bug on, and why exactly does it cause a wrong result for an empty input?" \
  > /tmp/resume-spike-round2.jsonl 2>&1
```

- [ ] **Step 3: Verify Codex actually answered using round-1 context, not by re-reading the diff from scratch**

Check the round-2 rollout events: did Codex run any `custom_tool_call` (e.g., `git diff`, `cat`) to re-read the file, or did it answer directly from its own prior turn's context with no new investigation? Either is a valid design outcome, but record which one actually happened — if it always re-investigates via fresh tool calls anyway, the token-savings claim is weaker than assumed (the savings would only be in NOT re-sending Claude's own prompt-side diff text, not in Codex skipping re-investigation) and the design doc's claim should be revised accordingly.

- [ ] **Step 4: Compare token counts**

Record round 1's and round 2's `token_count` figures side by side, and compare round 2's figure against what a **fresh, non-resumed** `codex exec` call re-sending the full diff + the same follow-up question would report (run that as a third, separate comparison call). This is the actual evidence for or against the "token/speed efficiency" goal — record the real numbers, not an assumption that resume is cheaper.

- [ ] **Step 5: Append findings and clean up**

Add `## Task 2 spike result: resume context reuse` to the knowledge base doc with the real token figures and the tool-call-reinvestigation finding. Delete/archive both spike threads (pending Task 5) and remove scratch files/repo.

---

### Task 3: Spike — `--output-schema` behavior under `--json` + `resume`

**Files:** None (investigation only). Findings recorded in the knowledge base doc.

**Interfaces:**
- Consumes: the scratch repo pattern from Task 2 (can reuse or create fresh).
- Produces: a recorded answer to whether structured output survives the resume flow, informing whether the "Structured output — accepted limitation" section of the design doc needs revising.

- [ ] **Step 1: Run round 1 with `--output-schema` and `--json` together**

```bash
cat > /tmp/stream-review-schema.json <<'EOF'
{"type":"object","properties":{"verdict":{"type":"string","enum":["CLEAN","ISSUES"]},"summary":{"type":"string"}},"required":["verdict","summary"],"additionalProperties":false}
EOF
codex exec --json --sandbox read-only --output-schema /tmp/stream-review-schema.json \
  --output-last-message /tmp/stream-review-round1-final.json \
  "Review the uncommitted diff. Reply only in the given JSON shape." \
  > /tmp/schema-spike-round1.jsonl 2>&1
```

Check `/tmp/stream-review-round1-final.json` — does it validate against the schema (`jq -e . < file` plus a manual required-fields check, matching the style already used elsewhere in this project rather than adding a new JSON-schema-validation dependency)?

- [ ] **Step 2: Run round 2 (resume) with the same `--output-schema` flags**

```bash
codex exec resume <threadId> --json --output-schema /tmp/stream-review-schema.json \
  --output-last-message /tmp/stream-review-round2-final.json \
  "Reply again in the same JSON shape, updating the verdict if the first answer missed anything." \
  > /tmp/schema-spike-round2.jsonl 2>&1
```

Check whether `--output-last-message` is produced and schema-valid for the resumed round too, and whether the corresponding `response_item`/`message`/`final_answer` entry in the rollout file ALSO contains the structured JSON (i.e., whether reading the rollout file live during a schema-constrained round gives you the structured answer before the process even exits, which would be a genuine win over today's `/cc` — it currently only gets the structured answer after full process exit via `--output-last-message`).

- [ ] **Step 3: Append findings and clean up**

Add `## Task 3 spike result: --output-schema under resume` to the knowledge base doc. If both rounds validate cleanly, revise the design doc's "Structured output — accepted limitation" section to note that schema enforcement is NOT actually lost in this design (a strict improvement over the current draft's assumption) — do this revision as part of this task, not deferred. If it breaks (e.g., `resume` silently ignores `--output-schema`, or the rollout file's copy of the message is the free-text pre-schema-formatting version), keep the design doc's current "accepted limitation" framing and record exactly what broke. Clean up scratch files/threads (pending Task 5).

---

### Task 4: Spike — thread deletion/archival CLI semantics

**Files:** None (investigation only). Findings recorded in the knowledge base doc.

**Interfaces:**
- Produces: the exact, confirmed command Task 6's cleanup step and Task 7 (the wrapper's retention behavior) must use.

- [ ] **Step 1: Enumerate the candidate commands**

```bash
codex --help 2>&1 | grep -E "^\s+(delete|archive|unarchive)\s"
codex delete --help 2>&1
codex archive --help 2>&1
```

- [ ] **Step 2: Create a throwaway thread, then delete it, then verify**

```bash
codex exec --json "say hello, nothing else" > /tmp/delete-spike.jsonl 2>&1
# capture threadId from thread.started
codex delete <threadId> 2>&1
ls ~/.codex/sessions/*/*/*/*<threadId>* 2>&1   # expect: gone, or moved somewhere
```

Record the exact observed behavior: does `codex delete` remove the rollout file entirely, move it to an archive location, or just mark it in the session index without touching the file? This determines whether Task 6's cleanup step should call `codex delete` alone, or also needs an explicit `rm` of the rollout file as a belt-and-suspenders step (matching this project's existing "best-effort cleanup, never silently skip it" convention).

- [ ] **Step 3: Repeat for `codex archive` if it behaves differently**

Record whether `archive` is the better default for this plugin (keeps a record, matching `/cc`'s own "retain the review-history log indefinitely" precedent) versus `delete` (matches `run-codex-review.sh`'s "delete the raw eventlog immediately" precedent for the more sensitive raw-content case). The design doc currently says "delete or archive" without picking one — this task's finding should make that choice concretely and update the design doc's "Data retention" section to state which one and why.

- [ ] **Step 4: Append findings and clean up**

Add `## Task 4 spike result: thread cleanup command` to the knowledge base doc with the exact confirmed command and behavior.

---

### Task 5: Consolidate spike findings into a go/no-go decision

**Files:**
- Modify: `docs/2026-09-03-codex-stream-review-design.md` (update "Safety model", "Structured output", and "Data retention" sections per Tasks 1, 3, and 4's actual findings — replace the "not yet verified" language with the confirmed outcome in each case).

**Interfaces:**
- Consumes: Tasks 1-4's recorded findings.
- Produces: an unambiguous, written decision for Task 6 to build against — no task past this point may say "assuming X works" if Task 1-4 already determined whether X works.

- [ ] **Step 1: Re-read all four spike-result sections just added to the knowledge base doc**

- [ ] **Step 2: Update the design doc's three affected sections**

For "Safety model": state definitively whether Task 6 uses `--ask-for-approval on-request` with a real answering mechanism, or falls back to `--sandbox read-only`. For "Structured output": state definitively whether `--output-schema` survives `resume` (revise "accepted limitation" language if Task 3 found it works). For "Data retention": name the exact chosen command (`delete` or `archive`) from Task 4.

- [ ] **Step 3: Commit this design-doc update on its own small branch/PR**

This is a documentation-only change to a design doc already in the repo — small, low-risk, reviewable on its own before Task 6's actual code lands. Follow this project's existing commit → push → PR → merge → branch cleanup flow.

---

### Task 6: Build `run-stream-review.sh` — single-round wrapper

**Files:**
- Create: `codex-stream-review/.claude-plugin/plugin.json`
- Create: `codex-stream-review/scripts/run-stream-review.sh`
- Modify: `.claude-plugin/marketplace.json` (register the new plugin, following the exact pattern already used for `codex-direct-review`'s own entry)

**Interfaces:**
- Consumes: Task 5's finalized design-doc decisions (exact sandbox/approval flags, exact cleanup command).
- Produces: `run-stream-review.sh --cwd <dir> --focus <text> [--resume <threadId>] [--output-schema <file>]`, printing a single-line JSON result to stdout in the same `{"ok":true/false,...}` envelope style `run-codex-review.sh` already uses (matching conventions, not inventing a new result shape) — plus, unlike `run-codex-review.sh`, this wrapper ALSO prints the resolved `threadId` in its result object so a caller can `--resume` it for a follow-up round.

- [ ] **Step 1: Scaffold the plugin manifest**

Create `codex-stream-review/.claude-plugin/plugin.json`:

```json
{
  "name": "codex-stream-review",
  "version": "0.1.0",
  "description": "Experimental: stream live Codex review progress by tailing a persisted thread's rollout file, with multi-round follow-up via codex exec resume (no diff re-send). Separate from and does not replace codex-direct-review.",
  "author": {
    "name": "youzooyou",
    "url": "https://github.com/youzooyou"
  }
}
```

- [ ] **Step 2: Register it in the marketplace manifest**

Read `.claude-plugin/marketplace.json` first, then add a third entry (after `clear-prep` and `codex-direct-review`) following the exact same field structure as the existing `codex-direct-review` entry.

- [ ] **Step 3: Write the wrapper's argument parsing**

`run-stream-review.sh` accepts: `--cwd <dir>` (required), `--focus <text>` (required — the review prompt, or the follow-up question if `--resume` is given), `--resume <threadId>` (optional — if absent, starts a new thread), `--output-schema <file>` (optional), matching `run-codex-review.sh`'s existing argument-parsing style (a `case`/`shift` loop, `bad_args` JSON error on anything unrecognized — copy that file's exact pattern rather than inventing a new one).

- [ ] **Step 4: Write the round-dispatch core**

**Finalized by Task 5 (2026-09-03):** no approval flag exists on `codex
exec` at all (Task 1's finding) — the safety model is plain `--sandbox
read-only`, matching `/cc`. `--cwd` is **not** a real `codex exec` flag
(confirmed: the actual flag is `-C`/`--cd`, and `run-codex-review.sh`
doesn't even use that — it just `cd`s into the target directory in the
shell before invoking `codex exec`; match that exact, already-working
convention here too, don't invent a different one). `< /dev/null` is
required on every invocation per Task 3's stdin-hang gotcha.

Based on whether `--resume` was given, construct either:
```bash
cd "$CWD"
codex exec --json --sandbox read-only \
  -c model_reasoning_effort=xhigh ${SCHEMA:+--output-schema "$SCHEMA"} \
  "$FOCUS_TEXT" < /dev/null
```
or
```bash
cd "$CWD"
codex exec resume "$RESUME_THREAD_ID" --json \
  ${SCHEMA:+--output-schema "$SCHEMA"} "$FOCUS_TEXT" < /dev/null
```
Run it exactly the way `run-codex-review.sh` runs its own `codex exec` call (background dispatch + the same wall-clock timeout poll-loop pattern already implemented there — reuse that code, don't reimplement a timeout mechanism from scratch).

- [ ] **Step 5: Capture `threadId` from the live stdout stream**

Read the backgrounded process's stdout incrementally (not just after exit) far enough to find the `thread.started` event and extract `threadId` via `jq` — needed before Step 6 can resolve the rollout file path. If `thread.started` never appears within a short bound (e.g. 10s), that's a wrapper-level error case (`{"ok":false,"reason":"no_thread_started",...}`).

- [ ] **Step 6: Resolve and tail the rollout file for the round's duration**

```bash
ROLLOUT=$(find ~/.codex/sessions -name "rollout-*-${THREAD_ID}.jsonl" 2>/dev/null | head -1)
```
Tail it (this can be surfaced as live progress output by a caller using `Monitor`, matching this session's own established pattern — the wrapper itself just needs to know when `task_complete` appears to know the round is done, exactly mirroring `run-codex-review.sh`'s existing `turn.completed` check, just sourced from a different file).

- [ ] **Step 7: Extract the final answer and emit the wrapper's result JSON**

Find the last `response_item` with `payload.type=="message"` and `payload.phase=="final_answer"` in the rollout file; if `--output-schema` was given, this should already be schema-shaped text (per Task 3's finding) — parse and re-emit it as the `verdict` field; otherwise wrap the raw text. Always include `"threadId"` in the result so a caller can resume.

- [ ] **Step 8: Cleanup**

Call the exact command Task 4 determined (`delete` or `archive`) on the thread **only when the caller does not intend to `--resume` it further** — i.e., cleanup is the CALLER's responsibility (a separate, explicit flag or a documented "call this when you're done with the whole multi-round review, not after every round" contract), not something this wrapper does unconditionally after every single round (that would break `--resume` for the very next round). Document this clearly in the skill (Task 8).

- [ ] **Step 9: Commit on a feature branch**

```bash
git checkout -b feat/codex-stream-review-wrapper
git add codex-stream-review/ .claude-plugin/marketplace.json
git commit -m "feat: add codex-stream-review plugin with rollout-file-based live streaming"
```

---

### Task 7: Smoke-test the wrapper end-to-end

**Files:** None (verification only, may reveal bugs to fix back in Task 6's files).

**Interfaces:**
- Consumes: Task 6's wrapper.
- Produces: confirmation the whole chain (start → stream → complete → resume → complete → cleanup) works via the actual shipped script, not the ad-hoc spike scripts from Tasks 1-4.

- [ ] **Step 1: Round 1 against a real small diff** (reuse a scratch repo pattern from earlier tasks), confirm `{"ok":true,...,"threadId":"..."}` and a sane verdict.
- [ ] **Step 2: Round 2 via `--resume <threadId-from-step-1>`** with a follow-up question, confirm it answers using prior context (spot-check against Task 2's finding).
- [ ] **Step 3: Confirm cleanup** — after telling the wrapper the review is done, confirm the thread's rollout file is actually gone/archived per Task 4's chosen command, not left behind.
- [ ] **Step 4: Sensitive-info check** on the diff before committing (grep for the standing rule's usual patterns — home paths, tokens, secrets) — this task itself produces no new commits, but flag anything found for Task 6/8 to fix before their own commits.

---

### Task 8: Write the companion skill and finish the branch

**Files:**
- Create: `codex-stream-review/skills/stream-review/SKILL.md`

**Interfaces:**
- Produces: the user-facing (and Claude-facing) documentation for when/how to invoke this experimental plugin, explicitly distinguishing it from `/cc`/`codex-review`.

- [ ] **Step 1: Write the skill**, covering: this is experimental and separate from `/cc`; how to start a review, how to continue one (`--resume`), the explicit caller-responsibility cleanup contract from Task 6 Step 8, and the current safety-model status (per Task 5's decision — state plainly if it's running `--sandbox read-only` because Task 1's approval spike didn't pan out, so a user isn't surprised by a capability the design originally hoped for but didn't ship).
- [ ] **Step 2: Update the top-level `README.md`** (marketplace repo root) to list the new plugin alongside the existing ones, matching its existing per-plugin entry format.
- [ ] **Step 3: Run this project's own `/cc` cross-review** against the full branch diff (dogfooding — this is exactly the kind of change `/cc` already knows how to review) to convergence before requesting merge.
- [ ] **Step 4: Use `superpowers:finishing-a-development-branch`** to push, open a PR, and merge once `/cc` converges CLEAN and the user gives explicit merge approval — matching this project's established pattern for every prior change this session.
