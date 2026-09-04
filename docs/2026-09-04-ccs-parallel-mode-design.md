# `ccs` Parallel Multi-Reviewer Mode — Design

> Status: approved (plugin author confirmed round-level synchronized convergence, 2026-09-04).
> Companion reading: `docs/2026-09-03-ccs-design.md` (the core `/ccs` design this extends) and
> `codex-direct-review/skills/ccd/SKILL.md` (the pattern this ports from, `ccd`'s own "Phase 1 —
> Determine Review Mode (Parallel vs Single)" section and `groups[]` bookkeeping throughout).

## Goal

Add parallel multi-reviewer mode to `codex-stream-review:ccs`, matching `codex-direct-review:ccd`'s
N-concurrent-dimension-reviewer capability, **without** degrading `ccs`'s core value proposition:
every group gets its own persistent, resumable Codex thread (created once, `--resume`d every
round after), never `ccd`'s ephemeral-process-per-round-per-group model. `ccs` remains a
resumable-thread review tool in every mode.

Grounded in a full read of `ccd/SKILL.md` (1623 lines), `ccs/SKILL.md` (773 lines, already
includes the `CLEAN_REPO_DIR` port), and `codex-stream-review/scripts/run-ccs-review.sh` (811
lines). Confirmed directly from the wrapper's arg parser (lines 265–359): it has no file-filter
flag, so — exactly like `ccd`'s wrapper — every parallel group necessarily reviews the IDENTICAL
full diff/artifact, differing only in `--focus`.

## 1. Thread lifecycle per group

No new tracking file. Extend `ccs`'s existing "Claude remembers this as a literal fact" convention
(already used for `SESSION_ID`, `THREAD_ID`, `LEAKED_THREAD_IDS`) to an ordered set of
`(GROUP, THREAD_ID)` pairs, `GROUP_THREADS` — established once, right after round 1's N groups
each independently signal their `THREAD_ID` via the existing Step 3 poll (run once per group).
Carried forward by hand into every group's `--resume` dispatch, mechanically identical to how a
single `THREAD_ID` is already carried today — just N instances of an already-accepted pattern.

Durable backstop, not primary carrier: add a `thread_id` field to each `groups[]` JSONL log entry
(new — `ccd`'s `groups[]` has no such field since `ccd` is ephemeral and has nothing to persist).
`jq '.groups[] | {group, thread_id}'` on the latest round's log line re-derives the mapping if
memory is ever in doubt — the same "query the log instead of relying on memory" pattern `ccs`
already uses for round continuity.

`LEAKED_THREAD_IDS` extends to `(GROUP, threadId)` pairs — a round-1 retry after a
post-`thread.started` failure is scoped to the ONE failed group (mirroring `ccd`'s per-group retry
rule: "retry just that failed group once"), so only that group's old thread leaks.

**Per-group `History` construction (subtlety):** a group's round-2+ resume `--focus` must recap
two distinct things: (a) any diff/code changes made since this group's last round, *including*
fixes prompted by a *different* group's finding — a fix for one dimension can regress another,
this is `ccd`'s whole-flow principle applied across dimensions; and (b) this specific group's own
prior findings and Claude's response to them, distinguished from (a). Build this from the log's
full round history, filtered/tagged by `group`, not from the round's aggregated summary alone.

## 2. File-naming / temp-file scheme

Insert a `GROUP` segment into all four of `ccs`'s existing Phase 1 Step 0 templates (currently
session+round-only), using `ccd`'s exact convention: `GROUP` fixed to `main` for a single-reviewer
round, `g1`/`g2`/`g3`… for a parallel round — one scheme covers both modes.

```bash
GROUP="g1"   # or "main" — fixed per concurrently-dispatched group this round
PID_FILE=$(mktemp   "/tmp/ccs-${SESSION_ID}-round-<R>-${GROUP}.pid.XXXXXX")
OUT_FILE=$(mktemp   "/tmp/ccs-${SESSION_ID}-round-<R>-${GROUP}-out.json.XXXXXX")
ERR_FILE=$(mktemp   "/tmp/ccs-${SESSION_ID}-round-<R>-${GROUP}-err.log.XXXXXX")
FOCUS_FILE=$(mktemp "/tmp/ccs-${SESSION_ID}-round-<R>-${GROUP}-focus.txt.XXXXXX")
```

`GROUP` is baked into the mktemp *template* (not just the random suffix) — the session+round+group
triple prevents cross-session/cross-group confusion; `mktemp`'s own suffix prevents same-round-
same-group path guessing. Applies identically to fresh (round 1) and resumed (round 2+) dispatch —
only the wrapper flags at Step 1 differ. Cosmetic behavior change to the single-reviewer path too
(`main` now appears in paths where it didn't before) — harmless, ephemeral per-run files.

## 3. tmux pane multiplication

N panes, one per group, opened once at that group's round 1 and persisting unchanged into round
2+ via that group's own rollout file (today's single-pane survival logic, replicated per group).

Layout: create pane 1 via the existing `tmux split-window -h -P -F '#{pane_id}'`, then for each
additional group `tmux split-window -h -t <window> -P -F '#{pane_id}'`, then once ALL N panes
exist, `tmux select-layout tiled 2>/dev/null || true` **once**. Native tmux auto-balancing grid —
no hand-computed split geometry per N needed. Best-effort, non-fatal, same as today.

Safe-charset guard applies per group exactly as today (same `INSTALL_PATH`, that group's own
`THREAD_ID`). Cleanup: Phase 3 loops over every group's `PANE_ID`, each `tmux kill-pane` best-
effort so one failure doesn't skip the rest.

**UX judgment call (not a hard limit, author may revisit):** consider capping live-pane creation
around 4–5 groups and falling back to narration-only beyond that — purely for human-watchability,
independent of how many groups are actually dispatched for review. N simultaneous narration
streams are harder to usefully watch than one past roughly 3 panes.

## 4. Liveness watcher multiplication

N independent `(GROUP, PID_FILE)` pairs this round, each with its own `Monitor` call — direct
replication of `ccd`'s already-solved parallel dispatch pattern. `GROUP` baked into the mktemp
template (point 2) prevents cross-group PID-file confusion.

**Wait for ALL N before Phase 2 processing — confirmed, not react-as-completed.** `ccd`'s own
splitting guidance: "Run each group's call at the same time → wait for all → synthesize."
Structurally forced anyway: the convergence gate requires CLEAN to hold for EVERY dispatched
group, and re-verification must go through EACH group's findings — both presuppose every group's
result is already in hand. Reacting to a subset would mean re-verifying/gating on an incomplete
picture, then redoing it when a straggler lands.

## 5. Result merging into ccs's schema

**a) `coverage_source` (worst-case-wins across groups)** — `ccd`'s merge rule ports directly,
composed with `ccs`'s existing "Coverage is a Round-1-only property" rule: the merge across N
groups happens exactly once, at round 1, carried forward through the rest of the loop — never
re-merged on a resumed round, since no group's round 2+ ever reports `coverage.source` at all
(confirmed: `SOURCE_COVERAGE_JSON` is only populated in the `--uncommitted` branch, entirely
skipped when `$RESUME_THREAD_ID` is set). This is an adaptation, not a verbatim port.

**b) `target.focus`/`codex_review` synthesized-summary + `groups[]`** — ports directly: a short
"(parallel round, N groups)" note plus worst-case-wins aggregate verdict with group-tagged
findings. Add one `ccs`-specific field per `groups[]` entry: `"thread_id"` (point 1) — `ccd` has
no analog since its groups are ephemeral.

**c) `INVESTIGATION_EVIDENCE_JSON` merge — confirmed dead weight, not a gap.** `ccs` v1 has no
`--capture-evidence`/`investigation_evidence` concept at all. Parallel mode doesn't create a new
need for this merge step; there is no per-group evidence JSON to combine. Do not port `ccd`'s
merge machinery for this as if it were a missing piece.

**d) `target.scope` — one value per round, not one per group.** All groups advance in lockstep
with the round counter (point 6: round-level synchronized convergence, confirmed): round 1
dispatches all N groups fresh, round 2+ resumes all N groups. A single top-level `target.scope`
remains sufficient; a per-group field would be redundant state with no current use. (This decision
is coupled to point 6 — if a future revision lets group cadences diverge, revisit this too.)

## 6. Convergence logic across groups — CONFIRMED: round-level, all-groups-together

**Decision (approved by plugin author 2026-09-04):** port `ccd`'s rule verbatim — a round
converges only if every dispatched group is independently clean *in that same round*. An
individually-clean group does **not** exit the loop early on its own cadence; it keeps being
resumed (with a lightweight "nothing new from your dimension, here's what changed elsewhere"
`--focus`) until the whole round converges.

**Why:** N dimensional groups exist to give N angles on the *same evolving diff*. If group g1
(security) signs off at round 2 but g2 (performance) keeps finding things through round 5, g1's
round-2 signoff is about a diff state that no longer exists by round 5 — every fix Claude makes in
rounds 3–5 (prompted by g2, or by g1's own earlier finding) can silently affect g1's dimension too
(the whole-flow principle, applied across dimensions, not only within one). An early-exit design
would let a stale signoff stand in for a re-check that never happens.

**Rejected alternative (named for the record):** let a clean group stop being resumed and only be
re-invoked once, right before the run reports CLEAN, for a final look. Marginal savings (a resume
dispatch is already cheap), but Phase 3 stops being a pure cleanup-and-report phase, and the
retry/cap/zero-progress bookkeeping gains a "how stale is this group's last real check" dimension
that risks a forgotten re-arm. Rejected: savings too small relative to added state-machine risk.

**Guards extended, mirroring `ccd`:**
- Per-group `"ok":false` retry: retry just that group once, keep every other group's already-
  collected result; round-level status is `⚠️ COULD NOT VERIFY` if that group still fails,
  regardless of other groups' cleanliness.
- "Zero progress twice in a row" generalizes to the **union** of all groups' open items showing no
  movement across the last two rounds — no new state machine, just a union check.
- The round counter `R` still counts *rounds*, not group-dispatches — a round is one synchronized
  wave of N concurrent calls (or 1, in single mode); the 20-round cap is unchanged in meaning.

## 7. Cleanup at every terminal path

Unconditional, automatic, multiplied by N — non-negotiable, stakes rise (N full rollout files, not
one, sitting on disk for the run's duration). Phase 3 becomes a loop: for every group slug that
ever obtained a real `THREAD_ID` (from `GROUP_THREADS`), `--cleanup <that group's threadId>`; then
loop over every `(GROUP, leaked-threadId)` pair. A `cleanup_failed` on any one group/thread is
surfaced per-item and never skips cleaning up the rest.

## 8. Sizing / mode-selection logic

Port `ccd`'s Phase 1 sizing table and heuristic verbatim — no `ccs`-specific adaptation needed,
since neither wrapper has a file-filter flag (confirmed from `run-ccs-review.sh`'s arg parser).
File-count sizing command, small/medium/large table, "group BY REVIEW DIMENSION/CONCERN" guidance
transfer with zero semantic change.

**`CLEAN_REPO_DIR` interaction carries over identically, and must.** A `CLEAN_REPO_DIR` round is
by construction a freshly-`git init`'d, unborn-HEAD, zero-file repo — any file-count sizing command
against it trivially returns 0, and there's nothing to partition by file count. **A non-repo-
artifact round is always single-group `main`, never parallel, full stop.**

## 9. Cost/complexity honesty check

- **Round-1 dispatch cost:** N × (one fresh `codex exec`, full diff read) — identical in kind and
  magnitude to `ccd`'s own parallel-mode cost. A wash.
- **Ongoing storage — a genuine, new-in-kind downside, not just "the same but ×N."** `ccd`'s
  parallel mode has zero persisted storage after each round (ephemeral by design). `ccs` parallel
  mode keeps N full rollout files under `~/.codex/sessions/` alive for the entire run — each
  containing the full diff plus every round's follow-up text. Abnormal session termination before
  Phase 3 multiplies the leaked-thread blast radius by N.
- **"No diff resend after round 1" fully realized per group — confirmed from the wrapper.** The
  diff-collection block is entirely skipped whenever `$RESUME_THREAD_ID` is set, regardless of how
  many other threads exist concurrently — per-process, per-thread, structurally independent of
  parallel dispatch.
- **What gets structurally worse: live-tmux-tail UX, not the mechanism.** N simultaneous narration
  streams are harder to usefully watch than one, past roughly 3 panes (see point 3's optional cap).
- **Interaction with point 6, stated explicitly:** because convergence is round-level and
  all-groups-together, an individually-clean group's thread keeps being resumed — and its rollout
  file keeps growing — every round until the *whole* round converges, even with nothing new since
  round 2. Real, modest cost that exists only from the *combination* of N persistent threads +
  uniform convergence, not either decision alone.
- **Bottom line:** not a strictly free win. Round-1 cost scales with N in both designs
  (unavoidable). The *ongoing* cost — disk-resident thread state across the run, reduced N-pane
  watchability — is real, `ccs`-specific, absent from `ccd`'s parallel mode. The per-group resume
  saving is real and fully preserved. State this tradeoff plainly in the shipped skill.

## SKILL.md sections requiring edits (current `ccs/SKILL.md` line numbers, approximate — re-locate before editing)

| Section | Current lines | Nature of edit |
|---|---|---|
| Frontmatter `description:` | 3 | Update — implies parallel mode is `ccd`-only |
| Top overview blurb | 22–34 | Update — line 32–34 says "reach for `ccd` for … parallel mode," now inaccurate |
| "v1 scope" | 38–55 | Remove/rewrite "No parallel multi-reviewer mode" bullet (40–43); keep `--capture-evidence` deferral unchanged |
| Wrapper interface reference | 94–181 | Minor note — wrapper unchanged, invoked N times |
| Sentinel-file idiom | 184–206 | Unchanged mechanism; note `FOCUS_FILE` now per-`(round, GROUP)` |
| Phase 0 step 4 (`CLEAN_REPO_DIR`) | 254–320 | Add: "always single-group `main`, never parallel" |
| New: sizing/mode selection | *(none today)* | Insert `ccd`'s Phase 1 (lines 1265–1358) near-verbatim, as a lead-in step inside `ccs`'s existing "Phase 1 — Round dispatch" (cheapest diff — see judgment call below, no renumbering) |
| "Phase 1 — Round dispatch" opening | 324–327 | Rewrite — currently states "no `GROUP` segment anywhere below" |
| Step 0 (temp files) | 329–340 | Add `GROUP` segment to all four templates; loop once per group |
| `ERR_FILE` rationale | 342–349 | Reframe as per-group |
| Round 1 / Round 2+ focus composition | 350–363 | Add per-group Why/Scope (round 1) and per-group History-from-log (round 2+) |
| Step 1 (dispatch) | 364–401 | N concurrent backgrounded dispatches, each with its own files + `GROUP_THREADS` lookup |
| Step 2 (liveness watcher) | 402–425 | N concurrent `Monitor` calls, "wait for all N" |
| Step 3 (THREAD_ID signal) | 427–458 | Per-group, round-1-per-group (incl. per-group retries) |
| Step 4 (tmux pane) | 460–530 | Rewrite: N panes, `select-layout tiled`, per-group `PANE_IDS` |
| "Coverage is a Round-1-only property" | 557–573 | Extend to N-group merge, still round-1-only overall |
| "Convergence = 100% CLEAN" | 575–586 | Add "EVERY dispatched group" clause |
| Guards | 588–620 | Per-group `ok:false` retry; union-across-groups zero-progress; per-group `LEAKED_THREAD_IDS` |
| Review history log schema | 624–691 | Add `groups[]` (with `thread_id`); document coverage/scope/evidence rules |
| Phase 3 steps 1–2 (thread cleanup) | 701–722 | Loop over N groups' `GROUP_THREADS` + per-group leaked lists |
| Phase 3 step 3 (tmux) | 724–728 | Loop over N `PANE_IDS` |
| Phase 3 step 4 (session temp files) | 730–735 | Unchanged — session-scoped, not per-group |
| Final Korean report — "리뷰 방식" | 742 | Report N and per-group thread IDs |
| Final Korean report — "스레드 정리 결과" | 749–752 | Per-group breakdown |
| "Rules" | 758–773 | Rewrite last bullet (770–772) — "only when parallel … use `ccd`" now obsolete |

## Judgment calls (author-reviewable, non-blocking defaults chosen)

1. **Phase insertion strategy:** insert sizing logic into existing "Phase 1 — Round dispatch"
   rather than a true new standalone phase + renumbering everything after it. Cheapest diff, no
   cascading cross-reference breaks.
2. **`GROUP_THREADS` tracking:** Claude's remembered literal facts + JSONL log backstop, not a
   dedicated tracking file. Mirrors existing single-`THREAD_ID` convention. (A dedicated file
   would be marginally more defensive against a long-context transcription slip, at the cost of
   one more file in every cleanup path — noted, not adopted.)
3. **Tiled-layout pane cap:** no hard cap enforced by default (matches `ccd`'s own uncapped "3+"
   sizing tier); optional 4–5 pane cap with narration-only fallback beyond that, for
   human-watchability only, left as an easy follow-up tweak rather than blocking this design.

## Confirmed decisions (author sign-off received)

- **Convergence cadence: round-level, all-groups-together** (point 6) — approved 2026-09-04.
