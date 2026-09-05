# `ccs/SKILL.md` Core+References Restructure — Design

> Status: approved by plugin author (2026-09-05), reviewed by Codex as a non-repo-artifact `/ccs`
> round (single round, converged with 3 findings accepted — see "Codex review" below), not yet
> implemented.
> Companion reading: `docs/2026-09-03-ccs-design.md` (original `/ccs` design),
> `docs/2026-09-04-ccs-parallel-mode-design.md` (parallel multi-reviewer mode, whose content this
> restructure partially relocates).

## Goal

`codex-stream-review/skills/ccs/SKILL.md` is 1,902 lines (confirmed via `wc -l`, 2026-09-05).
Every `/ccs` invocation loads this entire file into context regardless of which features that
invocation actually needs, imposing a fixed token/latency cost on even the smallest,
single-reviewer, capture-off, plain-repo-diff review — almost certainly the most common real
usage shape. This design splits the file into a lean, always-loaded core plus three
conditionally-loaded `references/*.md` files, without changing any documented behavior.

**Precedent, not invention.** `superpowers/skills/using-superpowers/SKILL.md` (a sibling skill in
a different plugin, same author ecosystem) already keeps its own core file to 63 lines and defers
all platform/harness-specific detail into `references/*.md`, loaded only via a plain instruction:
"If your harness appears here, read its reference file for special instructions" followed by a
short list (`Codex: references/codex-tools.md`, etc.). This is not a special harness capability —
it is an ordinary instruction to Read a specific file under a specific condition. This design
reuses that exact mechanism.

## Codex review (design-stage, non-repo-artifact `/ccs` round)

Before writing this spec, the plugin author and Claude ran the approach below past Codex directly
(one round, `/ccs` dispatched against the real repo with an empty working tree so Codex could read
actual `SKILL.md`/`scripts/` content for grounding). Verdict: ISSUES, 3 findings, all independently
re-verified and accepted — folded into the design below rather than left as a follow-up:

1. **Size target was wrong.** The original ~900–1,000-line core target (45–50% reduction) is not
   achievable given the content map below. Codex computed a lower bound of ~1,129 lines even under
   optimistic removal assumptions. **Corrected target: ~1,100–1,200 lines (35–40% reduction).**
2. **"Triggered by X decision" is too weak.** The wrapper (`run-ccs-review.sh`) has no way to
   detect whether Claude actually read a reference file before proceeding — `--capture-eventlog`
   is just an optional flag, not a capability negotiation. Each of the three trigger points must
   carry an explicit, mandatory-read instruction ("your very next action is to Read
   `references/X.md` in full, before proceeding to \[next step]"), not an implicit association.
3. **The non-repo-artifact reference must not duplicate the sanitization block.** This file has a
   documented history (commits `b0eb3f3`, `9b87341`) of breaking when a git-environment
   sanitization block is retyped/reflowed instead of referenced verbatim (a zsh word-splitting
   regression, among others). `references/non-repo-artifact.md`'s own dispatch instructions must
   point back at the ONE canonical sanitization block that stays in core (Phase 1 Step 1), never
   reproduce a second rendering of it.

## 1. Corrected content map

**Stays in core `SKILL.md` (~1,100–1,200 lines target):**
- Frontmatter, usage intro, Scope, Core Principles, Hard rules
- `run-ccs-review.sh` interface reference in full (dispatch shapes, reason table, resume-safety
  table, cleanup mode) — every feature combination depends on this wrapper contract
- Sentinel-file safe-read idiom
- Phase 0: session id / install path / repo root resolution, and the artifact-determination
  decision tree (task? prior session work? uncommitted diff? non-repo artifact? nothing?) — **the
  `CLEAN_REPO_DIR` mechanism body is excluded**, replaced by a mandatory-read pointer (see §2
  below)
- Phase 1: the sizing/mode-selection heuristic in full (must always run, single-reviewer or
  parallel, to decide which) including its git-sanitization command blocks — this is the ONE
  canonical copy `references/non-repo-artifact.md` will point back to; Step 1's single-group
  dispatch form (ditto, the canonical sanitization copy for parallel-mode's own pointer); Step 2
  liveness watcher; Step 3 single-group `THREAD_ID` signal; Step 4 **single-pane** tmux logic only
- Phase 2 in full, Guards included — Codex's own review confirmed keeping this whole section
  intact is correct: its parallel-mode asides are compact one-sentence extensions of
  already-present single-reviewer rules, not self-contained separable blocks, so extracting them
  would either duplicate the base rule in two files or leave core's own Guards silently incomplete
  for a reader who hasn't also read the parallel reference
- Review history log: the base single-reviewer, capture-off JSONL schema only
- Phase 3 cleanup, closing Rules

**`references/capture-evidence.md`:** the entire "Investigation evidence capture" section (153
lines) plus the `investigation_evidence` JSONL field spec.

**`references/parallel-mode.md`:** the "what parallel mode actually is" / splitting-strategy prose
and scope table (the sizing heuristic's git commands stay in core, per above — only the prose
built on top of an already-computed size defers), Step 0's `GROUP`-templating rationale, Step 1's
N-group concurrent dispatch loop mechanics, Step 4's N-pane tmux mechanics, "Per-group History
construction", the `groups[]` JSONL schema.

**`references/non-repo-artifact.md`:** the `CLEAN_REPO_DIR` mechanism in full (~150 lines).

## 2. Mandatory-read trigger instructions (Codex finding 2)

Each of the three existing Phase-0/Phase-1 decision points gets a concrete, non-optional
instruction appended at the point of decision, not merely a cross-reference in prose elsewhere.
Pattern (exact wording to be finalized during implementation, meaning fixed now):

> Once capture is determined ON for this session, **your very next action, before proceeding to
> Phase 1 Step 0, is to Read `references/capture-evidence.md` in full.** That file's procedure is
> required at no fewer than four later points in this run (Step 0's `EVENTLOG_FILE` allocation,
> Step 1's `--capture-eventlog` flag, Phase 2's extraction step, Guards' retry-time eventlog
> handling) — proceeding without having read it first will leave those points undocumented for
> this session.

Applied identically (with the matching file name and downstream-dependency list) at: the
capture-evidence decision (Phase 0 Step 0), the parallel-mode decision (Phase 1, immediately after
sizing concludes parallel is warranted), and the non-repo-artifact decision (Phase 0 step 4).

## 3. Cross-file sanitization reference (Codex finding 3)

`references/non-repo-artifact.md`'s dispatch instructions never re-render the git-environment
sanitization block. Instead, verbatim pattern:

> Every `references/non-repo-artifact.md` dispatch reuses the EXACT git-environment sanitization
> block from this session's own `SKILL.md`, Phase 1 Step 1's dispatch section — by reference only.
> Never retype, abbreviate, or reproduce any piece of that block's shell syntax here. If you have
> not already read that section this run, read it now before constructing this dispatch call.

Core `SKILL.md`'s own Phase 1 Step 1 sanitization block gets a matching backward pointer comment
noting that `references/non-repo-artifact.md` also depends on this exact block, so a future editor
touching it knows to check that the reference file's own pointer text still makes sense.

## 4. Validation plan (required before this work is considered done)

`SKILL.md` is a prompt, not code — no unit test can confirm Claude actually reads the correct
reference file at the correct trigger point post-split. Live validation, exercising all three
deferred paths, is part of this work's definition of done, not a follow-up:
1. Plain single-reviewer, capture-off, real-repo-diff happy path — compare behavior against the
   pre-restructure baseline.
2. `--capture-evidence` case — confirm the mandatory-read instruction is followed and downstream
   steps behave identically to today.
3. A diff sized to trigger parallel mode — confirm the same for `references/parallel-mode.md`.
4. A non-repo-artifact review — confirm the same for `references/non-repo-artifact.md`, including
   that the cross-file sanitization pointer is actually followed (no reflowed second copy appears).
5. Any gap found in 1–4 gets a boundary/wording fix, then re-validation of the affected path — not
   a deferred follow-up.

## 5. Explicitly out of scope

- No behavior change to `run-ccs-review.sh`, `scripts/lib/git-safe.sh`, or any other script.
- No change to what `/ccs` documents as supported (capture-evidence, parallel mode, non-repo
  artifacts all continue exactly as specified) — this is a token-cost restructure, not a feature
  change.
- No further size-reduction pass on the resulting core file beyond what this content map already
  removes — if the corrected ~1,100–1,200-line target is still felt to be too large after this
  lands, that is a separate future design, not scope creep on this one.
