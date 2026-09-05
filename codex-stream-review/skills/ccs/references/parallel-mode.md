# Parallel multi-reviewer mode — reference

> Read this file in full because Phase 1's sizing step concluded this round warrants more than one
> concurrent reviewer group.

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

## Round-1 focus text — the parallel-mode dimension sub-bullet

  - **Parallel mode (more than one group this round):** every group's Round-1 `--focus` shares the
    same Why and the same `⚠️ SCOPE CONSTRAINT`/collaboration-frame text, but each group's Scope
    additionally states its own review dimension/concern (e.g. one group's Scope emphasizes
    correctness, another's security, another's performance/reuse) — this dimension text is the
    ONLY thing that varies between groups' Round-1 `--focus`, since every group reviews the
    IDENTICAL full diff (see "Determine review mode" above).

## Round-2+ focus text — per-group history construction

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

## JSONL field: `groups`

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
  `GROUP_THREADS` (see `codex-stream-review/skills/ccs/SKILL.md`'s own Phase 1 Step 1) —
  `jq '.groups[] | {group, thread_id}'` on the
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
  Each dispatched group produces its own `INVESTIGATION_EVIDENCE_JSON` (see
  `codex-stream-review/skills/ccs/references/capture-evidence.md`'s "Investigation evidence
  capture" section), but the round's single `investigation_evidence` field is always the
  one, already-merged-across-groups value from that file's step 3 — the same merge-once
  pattern already used for `coverage_source` above, not a second, independently-invented merge
  rule.
