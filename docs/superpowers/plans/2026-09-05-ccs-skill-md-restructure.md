# `ccs/SKILL.md` Core+References Restructure Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Shrink `codex-stream-review/skills/ccs/SKILL.md` from 1,902 lines (loaded in full on
every `/ccs` invocation) to roughly 1,300–1,350 lines by (a) removing the tmux live-pane feature
entirely (no longer needed — its verification purpose is satisfied) and (b) relocating three
genuinely optional features' full documentation into `references/*.md` files that Claude reads
only when that session actually uses the feature, with zero change to any documented behavior for
those three features.

**Architecture:** One skill file (`SKILL.md`) stays the single always-loaded entry point and
covers the single-reviewer/capture-off/real-repo-diff path completely and correctly on its own.
Three new files under `codex-stream-review/skills/ccs/references/` hold the full mechanics for
`--capture-evidence`, parallel multi-reviewer mode, and non-repo-artifact reviews — each is Read
in full by Claude at the exact point in `SKILL.md` where that session already decides to use that
feature, per a mandatory (not optional) instruction. This reuses the identical pattern already
proven in `superpowers/skills/using-superpowers/SKILL.md`.

**Tech Stack:** Markdown prompt files only — no code, no build step, no test framework. "Tests" in
this plan mean: (1) mechanical verification (diff/grep confirming extracted content is byte-exact,
no dangling cross-references, code-fence balance) and (2) live-agent validation (an actual `/ccs`
invocation shaped to exercise a given path, confirming Claude reads the correct reference file at
the correct point and produces the documented result) — `SKILL.md` is a prompt, not code, so no
automated test can substitute for actually running it.

**Spec:** `docs/2026-09-05-ccs-skill-md-restructure-design.md` (read this in full before starting —
it records the Codex design review and two mid-planning corrections that already changed the scope
below from what was originally approved).

## Global Constraints

- Every extraction/deletion in this plan must leave `SKILL.md` internally consistent: no
  cross-reference (e.g. "see X above/below") may point at a section that has moved to a different
  file or been deleted, without being updated to name the new location.
- Never retype, abbreviate, or reproduce a second rendering of the git-environment sanitization
  code blocks (Phase 1's sizing commands, Phase 1 Step 1's dispatch sanitization) — this file has
  a documented history (commits `b0eb3f3`, `9b87341`) of real bugs from exactly this. Every task
  below that needs to reference one of these blocks from a different file does so by pointing back
  at the ONE copy that stays in core `SKILL.md`, never by copying it.
- Every extraction task locates its target content by searching for the EXACT unique marker text
  quoted in that task's steps (via grep or the Read tool), never by trusting a hardcoded absolute
  line number — earlier tasks in this plan shift every line number after their own edits, so a
  stale line number from this planning session will not match by the time a later task runs.
- Use `mcp__plugin_serena_serena__replace_content` (mode: `regex`, with `.*?` wildcards spanning
  from a short, unique opening anchor to a short, unique closing anchor) for every deletion/
  replacement in `SKILL.md` — this avoids needing to retype multi-hundred-line blocks into this
  plan or into a tool call, and an ambiguous-match error is safer than a silent wrong edit.
- Read a block's exact current content with the Read tool (using line numbers freshly confirmed
  via grep in that same step) before writing it into a new `references/*.md` file — never
  paraphrase or reconstruct content from memory of this plan's own description of it.
- No behavior change to `run-ccs-review.sh`, `scripts/lib/git-safe.sh`, or any other script in this
  plan, except deleting `scripts/watch-rollout.sh` (Task 1 — confirmed dead code once the tmux
  feature it exclusively serves is removed).
- Bump `codex-stream-review`'s version in `codex-stream-review/.claude-plugin/plugin.json` by one
  patch level as the final step of this plan (after all tasks pass), matching this project's own
  established versioning practice for every merged `ccs`-affecting change this session.

---

### Task 1: Remove the tmux live-pane feature entirely

**Files:**
- Modify: `codex-stream-review/skills/ccs/SKILL.md`
- Delete: `codex-stream-review/scripts/watch-rollout.sh`

**Interfaces:**
- Consumes: nothing from other tasks (this is the first task).
- Produces: a `SKILL.md` with zero references to tmux, panes, `PANE_ID`/`PANE_IDS`, or
  `watch-rollout.sh` — later tasks' extractions operate on the file AFTER this task's deletions,
  so their own boundary searches (Tasks 2–4) must be run fresh against the post-Task-1 file, not
  against line numbers from before this task.

- [ ] **Step 1: Confirm every current tmux/pane reference**

Run:
```bash
grep -n -i "tmux\|PANE_ID\|pane\b\|watch-rollout" codex-stream-review/skills/ccs/SKILL.md
```
Expected: matches in the frontmatter description, the intro paragraph, Step 0's `ERR_FILE`
rationale, all of Step 3's header/body, all of Step 4's header/body, Step 1's `GROUP_THREADS`
paragraph (references "via Step 3 below"), and Phase 3's "Close every group's tmux pane" step.
This confirms nothing has moved since this plan was written; if the grep finds materially
different line ranges than described below, stop and re-derive the boundaries by reading the
surrounding context before proceeding.

- [ ] **Step 2: Delete Phase 1 Step 3 and Step 4 in full**

Use `mcp__plugin_serena_serena__replace_content` on
`codex-stream-review/skills/ccs/SKILL.md`, mode `regex`:
- `needle`: `### Step 3 — early .THREAD_ID. signal \(ccs-specific; drives the tmux pane\).*?(?=## Phase 2 — Converge loop)`
- `repl`: `` (empty string)

This regex spans from the Step 3 header through everything up to (not including) the
`## Phase 2 — Converge loop` header, which deletes Step 3 and Step 4 together (Step 4 immediately
follows Step 3 with no other content between them and Phase 2). Run with `allow_multiple_occurrences: false` (the default) — if this reports more than one match, stop and inspect before proceeding.

- [ ] **Step 3: Fix the frontmatter description's tmux mention**

The frontmatter `description:` field (first ~5 lines of the file) currently reads in part:
"...so follow-up rounds are cheaper (no diff re-send after round 1) and, in a tmux-capable
environment, a live progress pane opens automatically per reviewer. Supports both..."

Use `mcp__plugin_serena_serena__replace_content`, mode `literal`:
- `needle`: ` and, in a tmux-capable environment, a live progress pane opens automatically per reviewer.`
- `repl`: `.`

- [ ] **Step 4: Fix the intro paragraph's tmux mention**

The intro paragraph (below the frontmatter) currently reads in part: "...rather than re-sent the
diff each time. It opens a live tmux pane on the round's rollout file when possible, and always
cleans up its Codex thread on every terminal path..."

Use `mcp__plugin_serena_serena__replace_content`, mode `regex`:
- `needle`: ` It opens a live tmux pane on the round's rollout file when possible, and \*\*always`
- `repl`: ` It \*\*always`

- [ ] **Step 5: Fix Step 0's `ERR_FILE` rationale**

Find the paragraph starting "**Why `ERR_FILE` is separate from `OUT_FILE`.**" (grep for that exact
string to confirm it still exists post-Steps-2–4). It currently reads in part: "`/ccs` needs the
early signal for the tmux pane and for holding onto a threadId even if the round later fails, so
the two streams are kept apart..."

Use `mcp__plugin_serena_serena__replace_content`, mode `literal`:
- `needle`: `/ccs` needs the early signal for
the tmux pane and for holding onto a threadId even if the round later fails, so the two streams
are kept apart, exactly as `stream-review`'s own SKILL.md documents ("redirect stdout and stderr
to SEPARATE files").`
- `repl`: `/ccs` keeps this stream separate from stdout's clean JSON, exactly as `stream-review`'s
own SKILL.md documents ("redirect stdout and stderr to SEPARATE files") — any wrapper-emitted
stderr noise (there is none in normal operation today, but the separation costs nothing and
matches the sibling skill's own convention) never contaminates the JSON parse.`

(This preserves the file-separation practice — which is independently justified by the
stream-review convention, not solely by tmux — while removing the now-false claim that anything
still reads the early signal.)

- [ ] **Step 6: Fix Step 1's `GROUP_THREADS` paragraph**

Find the paragraph starting "**`GROUP_THREADS` — the ordered set of `(GROUP, THREAD_ID)` pairs.**"
It currently reads in part: "Established once, right after round 1's dispatched groups each
independently signal their own `THREAD_ID` via Step 3 below (run once per group)."

Use `mcp__plugin_serena_serena__replace_content`, mode `literal`:
- `needle`: `Established once, right after
round 1's dispatched groups each independently signal their own `THREAD_ID` via Step 3 below (run
once per group).`
- `repl`: `Established once, right after round 1's dispatched groups' results are each parsed in
Phase 2 step 1 below — every group's own JSON response carries its `threadId` whenever one exists
(the reason table above shows exactly which failure reasons do), whether that round succeeded or
failed, so no earlier capture step is needed.`

Also check the same paragraph for the phrase "the same way a single `THREAD_ID` is already
remembered today" and any other Step-3-specific wording later in that paragraph or the "Per-group
retry-leaks-a-thread case" / "`GROUP_THREADS` must hold exactly one entry per group" paragraphs
that follow it (these currently live inside old Step 3's body per Step 2 above, so they are
already deleted — but re-grep for `Step 3` after Step 2 above to confirm no dangling reference
survived elsewhere in Step 1's own text before this step, since Step 1 sits earlier in the file
than Step 3 did and could plausibly reference it forward).

- [ ] **Step 7: Delete Phase 3's tmux-pane-cleanup step and renumber**

Find the paragraph starting "3. **Close every group's tmux pane**" inside Phase 3 — Terminal path
(it is currently the 3rd numbered step in that section, with step 4 "Clean up session-level temp
files" immediately after it).

Use `mcp__plugin_serena_serena__replace_content`, mode `regex`:
- `needle`: `3\. \*\*Close every group's tmux pane\*\*.*?(?=4\. \*\*Clean up session-level temp files)`
- `repl`: `` (empty string)

Then rename the now-orphaned step 4 to step 3:
- `needle`: `4\. \*\*Clean up session-level temp files:\*\*`
- `repl`: `3. **Clean up session-level temp files:**`

- [ ] **Step 8: Delete `scripts/watch-rollout.sh`**

Confirm it is genuinely unreferenced anywhere else first:
```bash
grep -rln "watch-rollout" codex-stream-review/ --exclude=SKILL.md
```
Expected: only `codex-stream-review/scripts/watch-rollout.sh` itself (no other file references
it — `SKILL.md` no longer does either, after Step 2 above). If anything else references it, stop
and investigate before deleting.

Then:
```bash
rm codex-stream-review/scripts/watch-rollout.sh
```

- [ ] **Step 9: Verify no dangling tmux/pane/watch-rollout references remain**

```bash
grep -n -i "tmux\|PANE_ID\|watch-rollout" codex-stream-review/skills/ccs/SKILL.md
```
Expected: no output (zero matches). If anything remains, read the surrounding context and decide
whether it is a genuine leftover (fix it) or an unrelated false-positive match (e.g. the word
"pane" appearing in unrelated prose — unlikely, but check).

- [ ] **Step 10: `bash -n`-equivalent sanity — confirm every remaining code fence is still balanced**

```bash
grep -c '^```' codex-stream-review/skills/ccs/SKILL.md
```
Expected: an even number. An odd number means one of the regex deletions above ate a fence marker
it shouldn't have — if so, read the diff (`git diff codex-stream-review/skills/ccs/SKILL.md`) and
find exactly where the fence count broke before proceeding.

- [ ] **Step 11: Commit**

```bash
git add codex-stream-review/skills/ccs/SKILL.md codex-stream-review/scripts/watch-rollout.sh
git commit -m "$(cat <<'EOF'
refactor(ccs): remove tmux live-pane feature

Removes Phase 1 Step 3 (early THREAD_ID signal) and Step 4 (tmux
auto-pane) from ccs/SKILL.md, and the now-dead watch-rollout.sh
script. This was a plugin-development-time visual-verification aid
for confirming live Claude+Codex round communication -- that
verification purpose is satisfied and the feature is no longer
needed. GROUP_THREADS is unaffected: it was always authoritatively
established from each round's own JSON response (Phase 2 step 1),
Step 3 was only ever a redundant early-arriving convenience for
deciding when to open the pane.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: Extract `--capture-evidence` content into `references/capture-evidence.md`

**Files:**
- Create: `codex-stream-review/skills/ccs/references/capture-evidence.md`
- Modify: `codex-stream-review/skills/ccs/SKILL.md`

**Interfaces:**
- Consumes: the post-Task-1 `SKILL.md` (tmux content already removed; this task's own target
  content is unaffected by Task 1's edits, since it all sits before Phase 1 Step 3 in the
  original file, but re-verify boundaries by marker text regardless, per Global Constraints).
- Produces: `references/capture-evidence.md` (a new file, read by Claude only when a session's
  Phase 0 Step 0 decision determines `--capture-evidence` is ON) and a `SKILL.md` whose Phase 0
  Step 0 capture-evidence decision carries a mandatory-read instruction naming this file.

- [ ] **Step 1: Confirm the two extraction boundaries**

```bash
grep -n '^## Investigation evidence capture\|^## Sentinel-file safe-read idiom\|^\*\*With capture-evidence ON\*\*\|^\*\*Write:\*\* append via' codex-stream-review/skills/ccs/SKILL.md
```
Expected: four matches. The first two bound the "Investigation evidence capture" section (from its
own header down to, but not including, the "Sentinel-file safe-read idiom" header — there is a
blank line and a `---` separator between them that stays in `SKILL.md`, marking the section
boundary). The second two bound the `investigation_evidence` JSONL field description (from "With
capture-evidence ON" down to, but not including, "Write: append via" — the field description ends
with the `- \`investigation_evidence\`, when capture-evidence is ON...` bullet, which is nested
inside the `groups` bullet's own text; leave that nested bullet where it is for Task 4 to handle,
since it also references `groups[]` and is genuinely about the parallel-mode merge behavior, not
this section — only extract the standalone paragraph-plus-JSON-example between the two headers
found above).

- [ ] **Step 2: Read and save the "Investigation evidence capture" section verbatim**

Use the Read tool on `codex-stream-review/skills/ccs/SKILL.md` with the line range confirmed in
Step 1 (from the `## Investigation evidence capture` header line through the last content line
before the blank-line-plus-`---` separator that precedes `## Sentinel-file safe-read idiom`).

Write that exact content to `codex-stream-review/skills/ccs/references/capture-evidence.md`,
preceded by this one-line header (new content, not extracted):

```markdown
# Investigation evidence capture — reference

> Read this file in full because `--capture-evidence` was determined ON for this session (see
> `SKILL.md`'s Phase 0 Step 0). Everything below is required for at least four later points in
> this run: Phase 1 Step 0's `EVENTLOG_FILE` allocation, Step 1's `--capture-eventlog` flag, Phase
> 2's extraction step, and the Guards section's retry-time eventlog handling in `SKILL.md`.

```

Then append the verbatim section content read above.

- [ ] **Step 3: Read and append the `investigation_evidence` JSONL field description**

Use the Read tool on `SKILL.md` with the second line range confirmed in Step 1 (from "**With
capture-evidence ON**" through the paragraph ending "...so a plain `jq 'has
(\"investigation_evidence\")'` on any line reliably tells whether that session had capture on.").

Append that exact content to the end of `references/capture-evidence.md` (below a `---`
separator you add), under a new subheading `## JSONL field: \`investigation_evidence\`` (new
content).

- [ ] **Step 4: Replace the extracted content in `SKILL.md` with a pointer and mandatory-read trigger**

Use `mcp__plugin_serena_serena__replace_content` on `SKILL.md`, mode `regex`:
- `needle`: `## Investigation evidence capture \(opt-in via .--capture-evidence.\).*?(?=## Sentinel-file safe-read idiom)`
- `repl`:
```
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

```

- [ ] **Step 5: Replace the `investigation_evidence` JSONL field description in `SKILL.md` with a pointer**

Use `mcp__plugin_serena_serena__replace_content` on `SKILL.md`, mode `regex`:
- `needle`: `\*\*With capture-evidence ON\*\*.*?\("investigation_evidence"\)\`' on any line reliably tells whether that session had capture on\.`
- `repl`: `**With capture-evidence ON**, that same line gains one more sibling field,
`investigation_evidence` — see `references/capture-evidence.md`'s JSONL field section (you already
read this file per this session's capture-evidence decision above) for its exact shape and
omission rule.`

- [ ] **Step 6: Verify byte-exact extraction**

```bash
wc -l codex-stream-review/skills/ccs/references/capture-evidence.md
git diff --stat codex-stream-review/skills/ccs/SKILL.md
```
Confirm the reference file is non-trivially sized (should be well over 100 lines) and the
`SKILL.md` diff shows a net line reduction. Then spot-check byte-exactness on one distinctive
line — e.g.:
```bash
grep -c 'fromjson? swallows any unparseable line rather than erroring the whole extraction' codex-stream-review/skills/ccs/references/capture-evidence.md
```
Expected: `1` (this exact sentence must appear verbatim in the extracted file).

- [ ] **Step 7: Verify no dangling same-file cross-references were left behind in `SKILL.md`**

```bash
grep -n 'see "Investigation evidence capture"' codex-stream-review/skills/ccs/SKILL.md
```
Expected: no output. Any match means a cross-reference elsewhere in `SKILL.md` still points at a
section that no longer exists in this file — read that context and fix it to point at
`references/capture-evidence.md` instead.

- [ ] **Step 8: Commit**

```bash
git add codex-stream-review/skills/ccs/SKILL.md codex-stream-review/skills/ccs/references/capture-evidence.md
git commit -m "$(cat <<'EOF'
refactor(ccs): extract investigation-evidence capture into references/capture-evidence.md

Full mechanics for the opt-in --capture-evidence feature now live in
a reference file, read by Claude only when a session actually
enables it -- zero behavior change, but the ~160-line section no
longer costs tokens on every /ccs invocation that doesn't use it.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: Extract non-repo-artifact content into `references/non-repo-artifact.md`

**Files:**
- Create: `codex-stream-review/skills/ccs/references/non-repo-artifact.md`
- Modify: `codex-stream-review/skills/ccs/SKILL.md`

**Interfaces:**
- Consumes: the post-Task-2 `SKILL.md`.
- Produces: `references/non-repo-artifact.md` (read only when Phase 0 step 4 determines this is a
  non-repo-artifact round) and a `SKILL.md` whose Phase 0 step 4 carries a mandatory-read
  instruction, plus a corrected Phase 1 Step 1 pointer.

- [ ] **Step 1: Confirm the two extraction boundaries**

```bash
grep -n '\*\*Why a non-repo-artifact round must NOT dispatch against .\$REPO_ROOT\..\*\*\|^---$\|^## Phase 1 — Round dispatch\|\*\*Non-repo artifact round?\*\* Substitute the exact literal\|^Dispatch via Bash with .run_in_background: true.' codex-stream-review/skills/ccs/SKILL.md
```
Expected matches include: the start of the CLEAN_REPO_DIR mechanism ("Why a non-repo-artifact
round must NOT dispatch..."), the `---` separator immediately before `## Phase 1 — Round
dispatch` (this bounds the FIRST block — extract from "Why a non-repo-artifact..." through the
paragraph ending "...since `CLEAN_REPO_DIR` is never allocated on that path.)", stopping before
the blank line and `---` that precede `## Phase 1`), the start of the SECOND block ("Non-repo
artifact round? Substitute the exact literal..." inside Phase 1 Step 1), and the line where Step 1
resumes with core content ("Dispatch via Bash with `run_in_background: true`" — this bounds the
second block, extract everything between the two).

- [ ] **Step 2: Read and save the `CLEAN_REPO_DIR` mechanism verbatim**

Use the Read tool on `SKILL.md` with the first line range confirmed in Step 1.

Write that exact content to `codex-stream-review/skills/ccs/references/non-repo-artifact.md`,
preceded by this header (new content):

```markdown
# Non-repo-artifact review — reference

> Read this file in full because Phase 0 step 4 determined the material to review is not a repo
> diff at all (a pasted plan, generated text, or analysis text with no git diff to point to).

```

Then append the verbatim content read above.

- [ ] **Step 3: Read and append the Step 1 non-repo-artifact dispatch substitution, with a corrected reference**

Use the Read tool on `SKILL.md` with the second line range confirmed in Step 1 (from "**Non-repo
artifact round?** Substitute..." through the paragraph ending "...so this substitution never
applies to more than one group.)").

Append that exact content to `references/non-repo-artifact.md` below a `---` separator, EXCEPT:
this block's own text says "Reuse that one fenced code block by reference only... naming the one
canonical block instead of ever showing a second rendering of it" — referring to the git-
environment sanitization block in Phase 1 Step 1, which STAYS in `SKILL.md` (per Global
Constraints). Since this paragraph now lives in a different file than that block, sharpen the
existing "immediately before that section's own 'Round 1 (fresh ...)' comment" phrase to also name
the file: append the clause "— in `codex-stream-review/skills/ccs/SKILL.md`'s own Phase 1 Step 1
dispatch section, not reproduced in this file" immediately after "Reuse that one fenced code block
by reference only" in the copied text before writing it.

- [ ] **Step 4: Replace both extracted blocks in `SKILL.md` with pointers**

For the first block, use `mcp__plugin_serena_serena__replace_content` on `SKILL.md`, mode `regex`:
- `needle`: `\*\*Why a non-repo-artifact round must NOT dispatch against .\$REPO_ROOT\.\.\*\*.*?since .CLEAN_REPO_DIR. is never allocated on that path\.\)`
- `repl`:
```
Full mechanics — why a non-repo-artifact round must not dispatch against `$REPO_ROOT`, the
`CLEAN_REPO_DIR`/`FAKE_GIT_HOME` allocation, the allowlist-not-denylist reasoning, and cleanup —
live in `references/non-repo-artifact.md`.

**Once you reach this branch (real content to review, but no git diff), your very next action —
before creating anything or dispatching any round — is to Read
`codex-stream-review/skills/ccs/references/non-repo-artifact.md` in full.**
```

For the second block, use `mcp__plugin_serena_serena__replace_content` on `SKILL.md`, mode `regex`:
- `needle`: `\*\*Non-repo artifact round\?\*\* Substitute the exact literal.*?so this substitution never\napplies to more than one group\.\)`
- `repl`: `**Non-repo artifact round?** You already read `references/non-repo-artifact.md` in full
per Phase 0 step 4's mandatory-read instruction — follow its own Step-1-dispatch-substitution
section now (it points back at this exact dispatch block for the sanitization loop, never a
retyped copy).`

- [ ] **Step 5: Verify byte-exact extraction and no dangling references**

```bash
wc -l codex-stream-review/skills/ccs/references/non-repo-artifact.md
grep -n 'full operational detail below' codex-stream-review/skills/ccs/SKILL.md
grep -c 'never checked, so a globally-configured' codex-stream-review/skills/ccs/references/non-repo-artifact.md
```
Expected: the reference file is over 80 lines; the first grep returns no output (this phrase, from
the original "(full operational detail below)" pointer in the artifact-determination decision
tree, must have been updated — if it still says "below" with nothing below it anymore, fix it to
name `references/non-repo-artifact.md` instead); the second grep returns `1` (confirms the seed-
commit-safety paragraph transferred verbatim).

- [ ] **Step 6: Commit**

```bash
git add codex-stream-review/skills/ccs/SKILL.md codex-stream-review/skills/ccs/references/non-repo-artifact.md
git commit -m "$(cat <<'EOF'
refactor(ccs): extract non-repo-artifact review into references/non-repo-artifact.md

Full CLEAN_REPO_DIR mechanics now live in a reference file, read by
Claude only when a session's review target isn't a repo diff at all
-- zero behavior change. The reference file's own dispatch section
points back at SKILL.md's one canonical git-sanitization block by
reference, never a second rendering of it.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 4: Extract parallel-mode content into `references/parallel-mode.md`

**Files:**
- Create: `codex-stream-review/skills/ccs/references/parallel-mode.md`
- Modify: `codex-stream-review/skills/ccs/SKILL.md`

**Interfaces:**
- Consumes: the post-Task-3 `SKILL.md`.
- Produces: `references/parallel-mode.md` (read only when Phase 1's sizing step concludes parallel
  mode is warranted) and a `SKILL.md` with three pointer replacements (the "what parallel mode is"
  prose, and Step 0's two parallel-specific sub-bullets) plus a corrected `groups[]` JSONL bullet.

- [ ] **Step 1: Confirm the four extraction boundaries**

```bash
grep -n '\*\*What "parallel mode" actually is\|and never exits the loop on its own separate cadence\.\|^### Step 0 — pre-allocate\|\*\*Parallel mode \(more than one group this round\):\*\*\|correctness, another'"'"'s security, another'"'"'s performance/reuse\)\.\|\*\*Per-group History construction \(parallel mode subtlety\)\.\*\*\|below\)\.$\|^- .groups.: \*\*added only for a parallel round\|^\*\*Write:\*\* append via' codex-stream-review/skills/ccs/SKILL.md
```
This is intentionally broad — read the surrounding context around each match to identify:
1. Block A: from `**What "parallel mode" actually is` through `and never exits the loop on its own
   separate cadence.` (ends the "Determine review mode" section, right before `### Step 0`).
2. Block B: the `- **Parallel mode (more than one group this round):**` sub-bullet inside Step 0's
   Round-1 focus-writing instructions (ends where its own indented text ends, at "...emphasizes
   correctness, another's security, another's performance/reuse)." — check indentation carefully,
   this is a nested sub-bullet, not a top-level one).
3. Block C: the `- **Per-group History construction (parallel mode subtlety).**` sub-bullet
   (ends at "...never dropped from the round (see 'Convergence = 100% CLEAN' below).").
4. Block D: the `- \`groups\`: **added only for a parallel round...**` bullet in the Review
   history log section (ends right before `**Write:** append via`).

- [ ] **Step 2: Read and save Block A (what parallel mode is / scope table / splitting strategy)**

Use the Read tool with Block A's confirmed range. Write to
`codex-stream-review/skills/ccs/references/parallel-mode.md`, preceded by this header:

```markdown
# Parallel multi-reviewer mode — reference

> Read this file in full because Phase 1's sizing step concluded this round warrants more than one
> concurrent reviewer group.

```

- [ ] **Step 3: Read and append Blocks B and C**

Use the Read tool with Block B's confirmed range; append to `parallel-mode.md` under a new
subheading `## Round-1 focus text — the parallel-mode dimension sub-bullet` (new content), then
the verbatim Block B text.

Use the Read tool with Block C's confirmed range; append under a new subheading `##
Round-2+ focus text — per-group history construction` (new content), then the verbatim Block C
text.

- [ ] **Step 4: Read and append Block D (the `groups[]` JSONL schema)**

Use the Read tool with Block D's confirmed range; append under a new subheading `## JSONL field:
\`groups\`` (new content), then the verbatim Block D text.

- [ ] **Step 5: Replace Block A in `SKILL.md` with a pointer**

Use `mcp__plugin_serena_serena__replace_content`, mode `regex`:
- `needle`: `\*\*What "parallel mode" actually is.*?and never exits the loop on its own separate cadence\.`
- `repl`: `Full mechanics — what parallel mode actually is, the scope-sizing table, when to use
multiple reviewers, and how convergence works across groups — live in `references/parallel-mode.md`.

**Once the sizing step above concludes this round warrants more than one concurrent reviewer group,
your very next action — before Step 0 below — is to Read
`codex-stream-review/skills/ccs/references/parallel-mode.md` in full.** This decision is made once,
before round 1, and holds for the whole run.`

- [ ] **Step 6: Replace Block B in `SKILL.md` with a pointer**

Use `mcp__plugin_serena_serena__replace_content`, mode `regex`:
- `needle`: `- \*\*Parallel mode \(more than one group this round\):\*\*.*?correctness, another's security, another's performance/reuse\)\.`
- `repl`: `- **Parallel mode:** see `references/parallel-mode.md`'s "Round-1 focus text" section
  (you already read this file per the parallel-mode decision above) for how each group's Scope
  text differs.`

- [ ] **Step 7: Replace Block C in `SKILL.md` with a pointer**

Use `mcp__plugin_serena_serena__replace_content`, mode `regex`:
- `needle`: `- \*\*Per-group History construction \(parallel mode subtlety\)\.\*\*.*?never dropped from the round \(see "Convergence = 100% CLEAN"\n    below\)\.`
- `repl`: `- **Per-group History construction:** see `references/parallel-mode.md`'s "Round-2+
  focus text" section (already read per the parallel-mode decision above).`

- [ ] **Step 8: Replace Block D in `SKILL.md` with a pointer**

Use `mcp__plugin_serena_serena__replace_content`, mode `regex`:
- `needle`: `- \`groups\`: \*\*added only for a parallel round.*?(?=\n\n\*\*Write:\*\* append via)`
- `repl`: `- \`groups\`: added only for a parallel round — see `references/parallel-mode.md`'s
  "JSONL field: \`groups\`" section (already read per this session's parallel-mode decision) for
  the full schema, the worst-case-wins aggregation rule, and the `investigation_evidence`
  interaction.`

- [ ] **Step 9: Verify byte-exact extraction and no dangling references**

```bash
wc -l codex-stream-review/skills/ccs/references/parallel-mode.md
grep -n 'see "Determine review mode" above\|see "Convergence = 100% CLEAN"\|(see below)' codex-stream-review/skills/ccs/SKILL.md
```
Confirm the reference file is a reasonable size (60–120 lines expected). For the grep: any match
inside content that has itself moved to `parallel-mode.md` is fine (same-file reference within the
new file is not checked by this grep against `SKILL.md`); read each match still inside `SKILL.md`
and confirm it still points at a section that genuinely still exists in `SKILL.md` (e.g.
"Convergence = 100% CLEAN" is a core Phase 2 section that is NOT moving, so references to it from
core content remain valid unchanged — only fix a reference if the section it names has actually
relocated).

- [ ] **Step 10: Commit**

```bash
git add codex-stream-review/skills/ccs/SKILL.md codex-stream-review/skills/ccs/references/parallel-mode.md
git commit -m "$(cat <<'EOF'
refactor(ccs): extract parallel-mode prose into references/parallel-mode.md

The "what parallel mode is" explanation, the two Step-0 parallel-
specific sub-bullets, and the groups[] JSONL schema now live in a
reference file, read by Claude only when a session's sizing step
concludes parallel mode is warranted -- zero behavior change. The
sizing heuristic itself (which must always run to make that
decision) and Guards' parallel-specific asides stay in core, per the
design doc's Codex-reviewed reasoning.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 5: Post-extraction consistency verification

**Files:**
- Read-only: `codex-stream-review/skills/ccs/SKILL.md`, all three `references/*.md` files.

**Interfaces:**
- Consumes: the post-Task-4 state of all four files.
- Produces: a pass/fail confirmation gating Task 6 (live validation) — do not proceed to Task 6
  until every check below passes.

- [ ] **Step 1: Confirm the final core line count**

```bash
wc -l codex-stream-review/skills/ccs/SKILL.md
```
Expected: roughly 1,300–1,350 lines (per the design doc's corrected estimate). If it is wildly
different (e.g. still over 1,600, or under 1,100), something in Tasks 1–4 did not apply as
expected — re-check each task's diffs before proceeding.

- [ ] **Step 2: Confirm code-fence balance across all four files**

```bash
for f in codex-stream-review/skills/ccs/SKILL.md codex-stream-review/skills/ccs/references/*.md; do
  echo "$f: $(grep -c '^```' "$f")"
done
```
Expected: an even number for every file.

- [ ] **Step 3: Confirm no file references a section by name that no longer exists where claimed**

```bash
grep -n '^## \|^### ' codex-stream-review/skills/ccs/SKILL.md
```
Read the resulting list of headers. Then, for each of the following phrases, grep `SKILL.md` and
confirm every match's surrounding context still makes sense against that header list: `"see
Phase 0 step 4"`, `"see Phase 1 Step 1"`, `"see \"Investigation evidence capture\""` (should be
zero matches — this section name no longer exists in `SKILL.md`), `"see the Guards"`, `"see
\"Coverage is a Round-1-only property\""`.

- [ ] **Step 4: Confirm the three reference files are each internally self-sufficient**

Read each of the three `references/*.md` files in full, fresh eyes. For each one, confirm: (a) it
never assumes the reader has ALSO read one of the other two reference files (each is triggered
independently by its own decision point, and a session can use one feature without the others),
and (b) every cross-reference it makes to a "core `SKILL.md`" concept (e.g. `GROUP_THREADS`,
`SESSION_ID`, the sentinel-file idiom, `REPO_ROOT`) is phrased as "already established in this
session's Phase 0/1" rather than assuming the reader is currently mid-read of `SKILL.md` itself.

- [ ] **Step 5: Diff review**

```bash
git log --oneline -5
git diff main -- codex-stream-review/skills/ccs/ codex-stream-review/scripts/watch-rollout.sh
```
Read the full cumulative diff across Tasks 1–4 end to end. Confirm nothing looks wrong (an
accidental duplicate block, a broken nested-list indentation left behind by a pointer
replacement, a stray leftover blank-line run). Fix inline if anything is found, with its own small
follow-up commit.

---

### Task 6: Live validation — single-reviewer happy path (baseline comparison)

**Files:** none modified — this is a live `/ccs` invocation, not a code change.

**Interfaces:**
- Consumes: the fully-restructured `SKILL.md` from Tasks 1–5.
- Produces: a pass/fail confirmation that the plain default path (no `--capture-evidence`, no
  parallel mode, a real repo diff) behaves identically to how it did before this restructure.

- [ ] **Step 1: Make a small, real, throwaway uncommitted change**

In this repo (or a scratch repo), make a trivial one-line uncommitted change to any file not part
of `codex-stream-review/` (to avoid any risk of this validation's own diff being confused with
this plan's real work).

- [ ] **Step 2: Invoke `codex-stream-review:ccs` with no special prefix**

Run the skill with a plain task description (or empty, to review "the work just done"). Observe:
- Phase 0 Step 0's stale-eventlog sweep and capture-evidence OFF decision fire as documented.
- No mention of `--capture-evidence`, parallel mode, or any `references/*.md` file appears
  anywhere in Claude's own narration or tool calls for this round — the plain path must never Read
  any of the three new reference files.
- The round dispatches, converges (or reports its real status), and Phase 3 cleanup runs, exactly
  as documented in core `SKILL.md` alone.

- [ ] **Step 3: Confirm success criteria**

Pass: the round completes with a real Codex verdict, thread cleanup succeeds, and at no point did
Claude Read any file under `codex-stream-review/skills/ccs/references/`. Fail: anything else —
if a reference file was read unnecessarily, or the round behaved differently from this session's
own prior `/ccs` invocations earlier in this project's history, stop and diagnose the SKILL.md
wording (likely a pointer text that reads as unconditional rather than gated) before proceeding
to Task 7.

---

### Task 7: Live validation — `--capture-evidence` path

**Files:** none modified.

**Interfaces:**
- Consumes: the fully-restructured `SKILL.md` and `references/capture-evidence.md`.
- Produces: a pass/fail confirmation that the mandatory-read trigger works and the feature
  behaves identically to before this restructure.

- [ ] **Step 1: Invoke `codex-stream-review:ccs --capture-evidence <a small real task>`**

Use the same kind of trivial throwaway change as Task 6, this time with the `--capture-evidence`
prefix.

- [ ] **Step 2: Confirm the mandatory-read instruction is followed**

Observe that, immediately after Phase 0 Step 0 determines capture is ON, Claude's very next
action is Reading `codex-stream-review/skills/ccs/references/capture-evidence.md` in full —
before any temp-file allocation or dispatch happens. If Claude instead proceeds directly to Phase
1 Step 0 without reading the reference file first, this is a fail — the trigger wording in
`SKILL.md` needs strengthening.

- [ ] **Step 3: Confirm downstream behavior matches the reference file's documented procedure**

Confirm: a 5th temp file (`EVENTLOG_FILE`) is allocated in Phase 1 Step 0; `--capture-eventlog` is
passed on the dispatch call; after the round, the `investigation_evidence` extraction jq filter
runs and the field appears in that round's JSONL log line (or is validly omitted per the
documented skip conditions); the raw eventlog file is deleted after extraction.

- [ ] **Step 4: Confirm success criteria**

Pass: all of Step 3's behaviors match `references/capture-evidence.md`'s documented procedure
exactly, and the mandatory-read fired at the right point. Fail: any deviation — fix the relevant
wording in `SKILL.md` or the reference file and re-run this task before proceeding to Task 8.

---

### Task 8: Live validation — parallel-mode trigger

**Files:** none modified.

**Interfaces:**
- Consumes: the fully-restructured `SKILL.md` and `references/parallel-mode.md`.
- Produces: a pass/fail confirmation that the mandatory-read trigger fires when sizing concludes
  parallel mode, and that the resulting N-group round behaves identically to before this
  restructure.

- [ ] **Step 1: Construct or identify a diff sized to trigger parallel mode**

Per the (unmoved, core) scope table, this needs roughly 20+ changed/untracked files, or an
explicit multi-concern task description that calls for it. Use a real diff already available in
this project's history if one of appropriate size exists, or construct a throwaway one in a
scratch repo.

- [ ] **Step 2: Invoke `codex-stream-review:ccs <task describing multiple review concerns>`**

Observe Phase 1's sizing step (still in core, unchanged) run and conclude parallel mode is
warranted.

- [ ] **Step 3: Confirm the mandatory-read instruction is followed**

Confirm Claude's very next action after that sizing conclusion is Reading
`codex-stream-review/skills/ccs/references/parallel-mode.md` in full, before Step 0's temp-file
allocation for any group.

- [ ] **Step 4: Confirm downstream behavior matches**

Confirm: each group gets its own `GROUP`-templated temp files and its own Round-1 `--focus` text
with a distinct dimension (using the pointer-restored "Parallel mode" sub-bullet content from
`references/parallel-mode.md`); `GROUP_THREADS` correctly tracks one `(GROUP, THREAD_ID)` pair per
group (established via Phase 2 step 1's JSON parsing, per Task 1's correction — confirm this still
works correctly with NO Step 3 poll involved); round-level convergence requires every group
independently clean in the same round; the JSONL log's `groups[]` field is correctly populated per
`references/parallel-mode.md`'s schema.

- [ ] **Step 5: Confirm success criteria**

Pass: all of Step 4's behaviors match documented procedure, the mandatory-read fired correctly,
and — importantly — confirm no tmux pane was ever attempted (Task 1 removed that entirely; a
parallel round must narrate progress via plain English text only, per whatever remains of Step 1's
own narration guidance, never attempt `tmux split-window`). Fail: any deviation — fix and re-run
before proceeding to Task 9.

---

### Task 9: Live validation — non-repo-artifact trigger

**Files:** none modified.

**Interfaces:**
- Consumes: the fully-restructured `SKILL.md` and `references/non-repo-artifact.md`.
- Produces: a pass/fail confirmation that the mandatory-read trigger fires, the cross-file
  sanitization pointer is actually followed (no reflowed second copy of the git-isolation block
  appears anywhere), and the feature behaves identically to before this restructure.

- [ ] **Step 1: Invoke `codex-stream-review:ccs <task with a pasted design/analysis, no diff>`**

Provide real pasted content (a short design note or analysis paragraph is sufficient) with the
working tree otherwise clean, so Phase 0 step 4 genuinely concludes this is a non-repo-artifact
review.

- [ ] **Step 2: Confirm the mandatory-read instruction is followed**

Confirm Claude's very next action after that Phase 0 step 4 conclusion is Reading
`codex-stream-review/skills/ccs/references/non-repo-artifact.md` in full, before creating
`CLEAN_REPO_DIR`/`FAKE_GIT_HOME`.

- [ ] **Step 3: Confirm the cross-file sanitization pointer is genuinely followed, not reflowed**

This is the specific risk Codex's design-review finding 3 was about. Confirm directly: when Claude
constructs the actual dispatch call for this round, it uses the EXACT git-environment
sanitization block already present in `SKILL.md`'s own Phase 1 Step 1 (read it fresh from that
file at dispatch time, per that file's own "reuse by reference only" instruction) — not a
retyped, abbreviated, or otherwise reflowed copy typed out under the influence of
`references/non-repo-artifact.md`'s own (now cross-file) pointer text.

- [ ] **Step 4: Confirm downstream behavior matches**

Confirm: `CLEAN_REPO_DIR` and `FAKE_GIT_HOME` are each created once and reused for every round of
this session; the round is always single-group `main`; `--uncommitted` is used every round
(never `--base`/`--commit`); the pasted content actually reaches Codex via `--focus`; cleanup at
Phase 3 removes both directories.

- [ ] **Step 5: Confirm success criteria**

Pass: all of Step 4's behaviors match, the mandatory-read fired correctly, and Step 3's
sanitization-block check confirms no second rendering was ever produced. Fail: any deviation —
fix and re-run.

---

### Task 10: Final version bump and wrap-up

**Files:**
- Modify: `codex-stream-review/.claude-plugin/plugin.json`

**Interfaces:**
- Consumes: successful completion of Tasks 1–9.

- [ ] **Step 1: Bump the version**

Read the current `version` field, bump the patch component by 1 (matching this session's
established pattern for every merged `ccs`-affecting change).

- [ ] **Step 2: Commit**

```bash
git add codex-stream-review/.claude-plugin/plugin.json
git commit -m "$(cat <<'EOF'
chore: bump codex-stream-review for ccs/SKILL.md core+references restructure

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
EOF
)"
```

- [ ] **Step 3: Report final line counts**

```bash
wc -l codex-stream-review/skills/ccs/SKILL.md codex-stream-review/skills/ccs/references/*.md
```
Report this final breakdown to the user alongside the design doc's original 1,902-line baseline.
