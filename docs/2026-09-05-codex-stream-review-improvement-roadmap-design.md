# codex-stream-review Improvement Roadmap — Negotiated Plan

> Status: **negotiated to CLEAN with Codex** via `/ccs` non-repo-artifact review, thread
> `01a071e1-e91e-7a23-b2d6-cc50dcc4adb3` (cleaned up after convergence), 4 rounds, 0 unresolved
> disagreements. Not yet implemented — this document is the design input for a future
> `superpowers:writing-plans` implementation plan, taken phase by phase. Current plugin version:
> 0.5.7 (still pre-1.0.0 by design: the SKILL.md structure, script contracts, and supported feature
> set are still actively changing release to release, so a 1.0.0 tag would falsely signal a frozen
> interface).
>
> **Convergence summary (4 rounds, all findings verified by Claude, none rebutted — every finding
> was valid):** R1 — 4 findings (rollout-tailing dependency should be replaced by the CLI's own
> `-o`/`--output-last-message`; evidence-retention-on-failure needed a real design; a concrete
> answer to the Phase 2 convergence-gate question; a roadmap-governance disposition rule). R2 — 3
> findings, all "make R1's accepted fixes concrete" (per-dispatch output-file lifecycle; a
> defined hash/mismatch contract; an actual stdin transport, not just "use stdin" in principle). R3
> — 1 finding (R2's hash-based revalidation was internally self-contradictory) plus confirmation
> that every other item was now resolved. R4 — **CLEAN**, no further findings. See "Round N
> negotiation outcome" sections below for full detail per round.

## Why this document exists

The plugin author asked for a broad audit of `codex-stream-review` (gaps, edge cases, stability,
competitive positioning) to plan a push toward 1.0.0 readiness. Two research passes were run:

1. An internal gap analysis (direct reading of `plugin.json`, `run-ccs-review.sh`,
   `run-stream-review.sh`, `lib/git-safe.sh`, `collect_untracked_files.py`,
   `review-verdict.schema.json`, `ccs/SKILL.md` + all `references/*.md`, `stream-review/SKILL.md`,
   CI workflow, fixture tests, README, ~40 commits of git log, and the prior closed backlog
   memory).
2. An external competitive/ecosystem research pass (competing AI code-review tools, multi-agent
   LLM debate literature, Claude Code plugin ecosystem norms, Codex CLI internals/known bugs).

Both are summarized below, followed by a proposed four-phase roadmap. **The open questions at the
end of each phase are the actual negotiation agenda for the Codex round** — this doc is not asking
Codex to just rubber-stamp it.

## Internal gap analysis (verified against current source)

### Highest-impact
1. **Automatic thread cleanup destroys the one diagnostic artifact needed to debug a failure.**
   `ccs/SKILL.md` Phase 3 Step 1 runs `--cleanup` (deletes the Codex thread + its rollout file) on
   **every** terminal outcome, including `⚠️ COULD NOT VERIFY` and `⚠️ NOT CONVERGED`. Even with
   `--capture-evidence` on, only command strings are kept (never output text), and the raw
   eventlog is deleted immediately after extraction. Net effect: for `invalid_json` /
   `schema_mismatch` / `no_final_answer` failures there is no way, ever, to see the actual
   non-conforming model output.
2. **README.md documents a feature that was explicitly removed** (tmux live-pane; removed in
   commit `e2f81c5`, but README still describes "an auto-opening tmux pane").
3. **`--focus` content is exposed via process argv for up to 30 minutes** — for non-repo-artifact
   reviews this includes the entire pasted design doc/plan. Visible to any other local user via
   `ps -ef`/`/proc/<pid>/cmdline` on a shared host.
4. **No orphaned-thread recovery path if the top-level Claude Code session dies mid-run.**
   `LEAKED_THREAD_IDS` lives only in Claude's in-context memory, never logged durably; no
   plugin-provided command to list/clean orphaned `~/.codex/sessions/**` threads.

### Stability / correctness
5. The entire Phase 1/2/3 orchestration "brain" (retry classification, thread bookkeeping,
   convergence gate) is unenforced natural-language prose interpreted fresh by an LLM every run,
   with zero automated test coverage — only the deterministic shell/Python layer is tested.
6. `kill_process_group`'s `kill -TERM/-KILL -"$pid"` assumes Codex never `setsid()`s a child out of
   its process group; unverified against real Codex subprocess behavior.
7. `$PROMPT_FILE` deferred-deletion ordering (must outlive `wait "$CODEX_PID"`) is reasoned
   correctly but untested under real scheduling delay (fixture stand-ins are synchronous).
8. `resolve_rollout`'s `find ... | head -1` has no multiplicity check — a silent wrong-file read on
   a hypothetical duplicate match would be indistinguishable from success.
9. `timeout`'s "resume-safe" classification is empirically tested only for `nonzero_exit`; other
   rows (including `timeout` itself) are "inferred safe by identical reasoning," self-disclosed as
   untested in SKILL.md's own table.

### Edge cases
10. No diff-size preflight / no guard against context-window overflow on a huge diff.
11. Large pasted non-repo artifacts risk OS `ARG_MAX` (E2BIG) at `execve`, a failure mode invisible
    to the documented reason table.
12. No per-round re-validation that a diff is still non-empty (mainly a round-1 concern, since
    round 2+ never re-collects).
13. Only "zero progress twice in a row" is detected — a finding that gets rebutted/re-raised across
    non-consecutive rounds with no new evidence each time is not caught as non-convergent.
14. No compaction strategy for Claude's own accumulating conversational context across up to 20
    rounds (Codex's context stays light via resumable threads; Claude's does not).
15. Shallow clones (`--depth 1`) as a `--base <ref>` diff source are an unaddressed known limitation.

### Security / trust boundary
16. Codex's own past-round output (folded into the next round's History/`--focus`) has no explicit
    "treat as data, not instruction" framing, unlike the diff/`--focus` boundary — a theoretical
    second-order injection vector.
17. `codex exec --sandbox read-only` is trusted with no independent plugin-level verification (e.g.
    a `git status` sanity check before/after a round).
18. `resolve_rollout` trusts `~/.codex/sessions/` content implicitly with no ownership/permission
    check.

### UX / operability
19. No cost/token visibility anywhere in the final report; `model_reasoning_effort=xhigh` is
    hardcoded with no caller-facing knob.
20. Parallel-mode per-group narration has no aggregated "X of N groups done" summary line.

### Scope / feature gaps
21. No incremental/delta review mode.
22. No numeric/aggregate severity scoring across rounds.
23. No structured, machine-readable final verdict artifact (only the JSONL log + prose report).
24. No headless/CI-gateable entry point — `/ccs` is structurally an interactive skill invocation;
    the plugin's own CI doesn't dogfood `/ccs`.
25. No `--paths`/file-filter flag — confirmed in `references/parallel-mode.md`.
26. No model/effort selection or adaptive low-effort-first strategy.
27. No support for reviewing a remote PR diff without a local clone, or format-aware review of
    notebook/schema diffs.

### Already fixed — explicitly out of scope for this roadmap
SKILL.md size/reload restructure (PR #53, v0.5.6); disclosure-ordering fix (PR #54, v0.5.7); git
environment sanitization / `core.fsmonitor` / external-diff-driver injection (`git_safe()`);
`SAFE_GIT_HOME` leak in the collector; zsh word-splitting bug in fallback env-var unset; non-repo
isolation + parallel mode (allowlist redesign); `coverage.source` splicing on failure/interrupted
responses; stale-install detection; leaked round-1 threads now tracked via `LEAKED_THREAD_IDS`
(though see #4 above — tracking exists, durable recovery does not); resume-safety classification
table itself (candor gap in #9 is new, the table isn't); binary/symlink/TOCTOU/FIFO/oversized-file
handling in the untracked-file collector; `--coverage-out` write-failure handling; CI (ShellCheck +
`bash -n` + fixtures + collector selftest); `codex-direct-review` removal; dangling
cross-references from the SKILL.md split.

## External research

### Competitive landscape
No confirmed direct competitor combines: two different model vendors, resumable per-round threads,
N-way parallel dimension-focused reviewers, and non-repo-artifact support via a throwaway repo.
CodeRabbit/Sourcery/Qodo/Greptile/Cursor Bugbot/GitHub Copilot code review are all single-model,
single-pass (per push/PR), SaaS-integrated tools — none do genuine cross-vendor adversarial
consensus. Greptile/Qodo differentiate on whole-repo semantic indexing, which `/ccs` lacks (it
works from diffs/artifacts, not a persistent repo-wide index). **This section is weaker than
ideal**: the research sub-agent tasked with it did not return a fully source-verified answer in
time, so treat "no direct competitor found" as "not found in this pass," not as a confirmed
negative.

### Multi-agent / adversarial LLM review literature
Multi-agent debate improves factuality/reasoning (Du et al. 2305.14325) but has real, documented
failure modes directly relevant to `/ccs`'s design:
- **Sycophancy** (Sharma et al./Anthropic, 2310.13548): a "reach consensus" loop risks converging
  on a mutually agreeable wrong answer.
- **More rounds ≠ better** (Smit et al., "Should We Be Going MAD?", 2311.17371): multi-agent debate
  does not reliably beat cheaper alternatives without careful tuning of agreement thresholds.
- **Judge gameability** (Wang et al., 2305.17926): LLM judges are gameable by response order alone.
- Best practice from the literature: distinct roles/personas per agent (already true for `/ccs` —
  Claude vs. Codex are different vendors, not the same model twice) and a separate, less-informed
  judge rather than self-declared consensus (not currently how `/ccs` decides convergence).
- No paper in this literature uses code review as the task domain specifically; OpenAI's CriticGPT
  is the closest code-specific prior art (noted from general knowledge, not independently
  re-verified this session).

### Claude Code plugin ecosystem norms
`claude plugin validate --strict` and `claude plugin eval` (eval cases with graders, ablation
runs, CI-gateable exit codes) exist but appear essentially unused industry-wide, including by
well-known repos. Adopting them would be a real, currently-rare differentiator. Even prominent
community plugin repos are inconsistent on LICENSE/CHANGELOG/CONTRIBUTING, so the ecosystem bar is
not uniformly high.

### Codex CLI internals (2025–2026)
- `codex exec fork` exists as an official subcommand to branch an existing session into a new
  thread — a possible alternative to `resume` for spinning up parallel-mode reviewer threads.
- Rollout files (`rollout-<timestamp>-<thread_id>.jsonl`) under `$CODEX_HOME/sessions/` **can be
  transparently gzip-compressed on disk**, and session lookup is now backed by an internal SQLite
  index — none of this is a documented stable public contract. Two real, currently-open upstream
  bugs exist in exactly this subsystem: **openai/codex#40630** (thread-store ordinal mismatch) and
  **#35746** (paginated history drops flattened rollout records, reuses ordinals). This directly
  elevates internal finding #8 (`resolve_rollout`'s naive `find | head -1`) from theoretical to
  "coupled to a subsystem with known, open corruption bugs."
- Usage/quota accounting has multiple open 2026 issues (**#41220**, **#42282**, **#39167**,
  **#38116**, **#35226**) — directly elevates internal finding #19 (no cost visibility, hardcoded
  `xhigh` effort): a 20-round, N-group parallel run at max effort has no exposed cost estimate and
  no way to trade off thoroughness vs. spend, against a backdrop of Codex's own quota accounting
  being unreliable right now.
- OpenAI shipped its own plugin/marketplace system inside Codex CLI (0.153.0) — a strategic risk
  that first-party tooling could absorb wrapper-style orchestration.

## Proposed roadmap (four phases, in priority order)

Plugin author has confirmed all four phases should eventually happen; this doc sequences them and
opens phase 1 for concrete design. Phases 2–4 are listed at roadmap depth only (not yet
fully designed) so the Codex round can react to the sequencing itself, not just phase 1's details.

### Phase 1 — Stability/correctness emergency fixes (items A, F above)
- **F**: Fix README.md's stale tmux-pane description (2 locations) to match the actual, already-
  shipped removal.
- **A**: Stop automatically destroying diagnostic evidence on failure/inconclusive terminal
  outcomes. Draft approach: classify Phase 3's terminal outcomes into "clean success" (converged /
  consensus reached) vs. "failure or inconclusive" (`COULD NOT VERIFY`, `NOT CONVERGED`, any
  post-dispatch failure state); run automatic `--cleanup` only for the former; for the latter,
  skip cleanup, surface the thread ID(s) and rollout file path(s) explicitly in the final report,
  and tell the user to clean up manually once they've inspected them. For `--capture-evidence`
  mode specifically, skip the raw-eventlog deletion step under the same failure conditions instead
  of always deleting immediately after extraction.
  - **Open question for Codex**: is "skip cleanup on failure, surface paths" sufficient, or does
    leaving live Codex threads around on failure create its own resource-leak/security concern
    that needs a bound (e.g., a TTL, or an explicit `--keep-evidence` opt-in flag instead of making
    it the unconditional default for all failure states)?
  - **Open question for Codex**: should the raw eventlog's retention-on-failure also need a
    redaction pass (in case the diff/focus content itself contains secrets), or is "same trust
    level as the rollout file we already leave behind on failure" an acceptable equivalence?

### Phase 2 — Convergence-logic hardening (item B above)
Goal: address the literature-confirmed sycophancy and "more rounds ≠ better" failure modes, and
close internal finding #13 (oscillation across non-consecutive rounds not detected as
non-convergent). Not yet designed in detail — this is the headline open question for the Codex
round: **what concrete, checkable signal should replace or augment "zero new findings for two
consecutive rounds" as the convergence gate, given that (a) a rebut/re-raise cycle with no new
evidence should count as non-convergent even if it isn't literally static, and (b) the gate must
stay cheap enough to evaluate every round without itself becoming a third LLM call?**

### Phase 3 — Upstream-risk hardening (items C, D above)
- **C**: Make `resolve_rollout` gzip-aware and add a multiplicity guard (fail loudly instead of
  silently taking `head -1` on >1 match), given the confirmed-open upstream rollout-corruption
  bugs (#40630, #35746).
- **D**: Surface cost/token usage in the final report; make `model_reasoning_effort` a caller-facing
  flag instead of hardcoded `xhigh`, given Codex's own open quota-accounting bugs.
- Not yet designed in detail beyond this — open to Codex on feasibility/scope.

### Phase 4 — Structural/strategic expansion (items E, H above)
- **E**: Evaluate replacing/supplementing `resume` with `codex exec fork` for parallel multi-
  reviewer mode's thread-spinning mechanism.
- **H**: A headless/CI-gateable entry point, given that every direct competitor automates at the
  PR level and this plugin's own CI doesn't dogfood `/ccs`.
- This phase is architectural-scale and will get its own full brainstorming/design-doc pass later,
  not folded into this document's negotiation.

## Round 1 negotiation outcome (Codex thread `01a071e1-e91e-7a23-b2d6-cc50dcc4adb3`)

Codex returned 4 findings, all independently verified by Claude and **ACCEPTED** (no rebuttal
needed — see verification notes per finding):

1. **[HIGH, ACCEPTED] Rollout-file tailing is the wrong correctness dependency; use the CLI's own
   supported output channel instead of hardening the fragile one.** Verified directly: `codex
   --version` on this machine reports `codex-cli 0.153.0`; `codex exec --help` / `resume --help` /
   `fork --help` all confirm `--json` (JSONL events on stdout), `-o/--output-last-message <FILE>`,
   and `--output-schema <FILE>` are real, documented flags on `exec`, `resume`, AND `fork`. A grep
   of the actual installed `run-stream-review.sh` confirms it already passes `--json` and
   `--output-schema` to `codex exec`/`codex exec resume`, but **never uses `-o`** — it still
   extracts the final answer by calling `resolve_rollout()` (`find ~/.codex/sessions/**/rollout-*-
   ${tid}.jsonl | head -1`) and parsing that file for a `final_answer` message. This is exactly the
   subsystem the external research flagged as having open upstream corruption bugs (openai/codex
   #40630, #35746). **This supersedes and absorbs old Phase 3 item C** (gzip-awareness +
   multiplicity guard for `resolve_rollout`) — Codex's own recommendation, which Claude accepts:
   "avoid gzip rollout parsing entirely" rather than hardening it. New Phase 1 scope: add
   `-o "$LAST_MESSAGE_FILE"` to every fresh/resume dispatch and read the final answer from that
   file; rollout-file access, if kept at all, becomes a secondary/best-effort live-progress signal
   only, never the correctness-critical path for the actual verdict.
2. **[HIGH, ACCEPTED] Phase 1-A's evidence-retention-on-failure design was underspecified and
   didn't fix the argv-exposure gap it depends on.** Verified directly: `codex exec --help`'s own
   `[PROMPT]` argument description confirms stdin delivery is officially supported ("If not
   provided as an argument (or if `-` is used), instructions are read from stdin"). Revised Phase 1
   design (folds in old gap #3 and #11 together, per Codex's own cross-reference): (a) switch
   `--focus`/prompt delivery from argv to stdin at BOTH boundaries — Claude→`run-ccs-review.sh` and
   the wrapper→`codex exec` — closing the argv-exposure gap (old #3) and the `ARG_MAX` risk for
   large pasted artifacts (old #11) in one fix, not two; (b) retention of a failed round's
   thread/rollout is an explicit opt-in (`--keep-evidence`), never the unconditional default fallback
   for every failure state; (c) retained artifacts get a durable manifest entry (not just in-context
   memory), an explicit cleanup command, and start-of-run pruning in the same best-effort style as
   the existing Phase 0 Step 0 stale-eventlog sweep — never described as a "guaranteed TTL"; (d) no
   generic redaction pass on retained raw data (can miss secrets, can destroy the exact malformed
   output needed for diagnosis) — instead treat retained data as sensitive, store it in a
   private/owner-only directory, matching this project's existing `umask 077` convention for the
   review-history log.
3. **[MEDIUM, ACCEPTED] Concrete answer to Phase 2's open question.** Deterministic convergence
   ledger: every claim gets a stable `claim_id` (location/subject/rule), a `state` enum (`asserted`
   / `rebutted` / `accepted` / `retracted` / `deferred`), and a hash of its cited evidence.
   Convergence requires every active claim to reach a mutually-recorded terminal state with no new
   claim/evidence introduced that round. A claim that revisits a previously-seen
   `(claim_id, state, evidence-hash-set)` tuple after a rebut/re-raise cycle is explicitly
   `NOT CONVERGED` — directly closes old gap #13 (oscillation across non-consecutive rounds). Pure
   local map/set comparison, no third LLM call needed — satisfies the open question's own
   constraint. This becomes Phase 2's actual design, replacing "zero new findings for two
   consecutive rounds."
4. **[MEDIUM, ACCEPTED] Roadmap governance gap: several material items (old #5, #10/#11, #16, #17,
   #18) had no explicit disposition.** New cross-cutting rule for this roadmap: before declaring it
   complete/1.0-ready, EVERY one of the 27 internal gap-list items must have one of: a phase
   assignment, an explicit accepted-residual-risk statement, or an explicit non-goal — never silent
   omission. Specific dispositions Codex proposed and Claude accepts: old #16 (Codex's own
   past-round output needs the same untrusted-data framing as `--focus` content, not exempted) →
   Phase 1, folded into the stdin-delivery work in finding 2 above (the same trust-boundary
   discipline, applied to history-construction text too); old #17 (`git status` before/after a round
   is defense-in-depth only, never proof of sandbox enforcement) → keep as-is, but the roadmap must
   say so explicitly rather than implying it's a real guarantee; old #12 (per-round diff
   re-validation) → revise to hash the immutable review input rather than re-collecting a live diff
   every round, avoiding both linear I/O growth and review-subject drift mid-run.

**Also resolved directly by Codex, self-reported as its own tool's authoritative behavior (per this
doc's "Note on authority" — independently verified by Claude via `--help` output where checked):**
`codex exec fork` is real and available in the installed 0.153.0 CLI, supports the same
`--json`/`-o`/`--output-schema` output contract as `exec`/`resume`. Codex's own recommendation,
accepted: do NOT pull it into Phase 1 — no cross-version stability guarantee is established, so it
stays a version-gated Phase 4 canary (test parent-session immutability, concurrent children, and
resume/fork history integrity before adopting it for parallel-mode thread-spinning). Cost/effort
visibility (old #19, Phase 3-D): report selected model/effort, elapsed time, and any
process-emitted usage figures as best-effort only — never framed as authoritative billing/quota
data, and no extra quota-lookup call added.

**Revised phase scope after round 1:**
- **Phase 1** now includes: F (README fix), the `-o`/`--output-last-message` switch (absorbs old
  Phase 3-C), stdin-based `--focus` delivery (closes old #3 and #11 together), untrusted-data
  framing extended to Codex's own prior-round output (old #16), and the opt-in
  `--keep-evidence` + durable manifest + start-of-run pruning design for failure-state evidence
  retention (the original "item A," now fully specified).
- **Phase 2**: the claim_id/state/evidence-hash convergence ledger above — no longer an open
  question, a concrete design ready for an implementation plan.
- **Phase 3**: shrinks to just old item D (best-effort cost/effort reporting) plus the per-round
  hash-based revalidation refinement (old #12) — gzip-awareness (old item C) is dropped, superseded
  by Phase 1's `-o` switch.
- **Phase 4**: unchanged in spirit (headless/CI entry point), plus the specific fork-canary test
  criteria above once Phase 1's `-o`-based protocol is in place and stable.
- **New standing rule**: no phase is "done" for 1.0.0 purposes until every one of the 27 gap-list
  items has an explicit disposition (phase/accepted-risk/non-goal).

## Round 2 negotiation outcome (same thread, resumed)

Codex reviewed the round-1 revision and returned 3 more findings (all medium, all led with an
explicit "not verified beyond the supplied revision summary" disclosure per this skill's own
ordering rule). Claude reviewed all 3 as sound engineering-completeness critiques of the round-1
revision (not factual claims needing external verification) and **ACCEPTED all 3**, concretized
using patterns that already exist elsewhere in this same codebase rather than inventing new ones:

5. **[MEDIUM, ACCEPTED] `-o`/`--output-last-message` needs an explicit per-dispatch file-lifecycle
   contract, or a failed run can be read as a stale prior success.** Concretized: allocate a fresh
   `mktemp`'d `LAST_MESSAGE_FILE` for every single dispatch attempt (fresh, resume, AND every
   Guards-section retry attempt — never reused across attempts, same discipline this file's Phase 1
   Step 0 already uses for `PID_FILE`/`OUT_FILE`/`ERR_FILE`/`FOCUS_FILE`). Only trust its content
   when ALL of: the wrapper's own `codex exec` exit code was 0, the `--json` stdout stream actually
   emitted its completion/success event for this attempt, and the file was written during this
   attempt's own lifetime — never fall back to a leftover file from an earlier attempt. Delete it
   after use; retain only under `--keep-evidence` (same opt-in as the round-1 evidence-retention
   design).
6. **[MEDIUM, ACCEPTED] Hash-based revalidation needs a defined canonical subject, a frozen
   snapshot, and an explicit mismatch action — not just "compute a hash."** Concretized: the
   canonical subject (the collected diff bytes for a repo review, or the pasted artifact bytes for
   a non-repo-artifact review) is fixed and hashed exactly once, at round 1, before any dispatch —
   never recomputed against a live, possibly-since-changed workspace. If a mismatch is ever
   detected (including a deliberately amended artifact/diff): **do not resume the existing
   thread(s)** — terminate that review (run Phase 3 cleanup on its threads), start an entirely new
   review with a new session id and new threads. Never let one thread's history argue across two
   different review subjects.
7. **[MEDIUM, ACCEPTED] "Switch to stdin" needed an actual transport, or the fix is nominal only.**
   Concretized, reusing this file's OWN existing `$PROMPT_FILE` deferred-deletion invariant (already
   documented for the wrapper's internal prompt handling) rather than inventing a new mechanism: at
   the Claude→wrapper boundary, the already-existing sentinel-file `FOCUS_FILE` (mktemp'd, written
   via the Write tool, already private-by-default via `mktemp`'s own permissions) is redirected
   directly into the wrapper's stdin — never `printf | wrapper`, never embedded in a `sh -c` string,
   never a `--focus "$FOCUS_TEXT"` argv value. At the wrapper→`codex exec` boundary, replace the
   current `-- "$FOCUS"` positional-argv pattern (confirmed present in the installed
   `run-stream-review.sh`: `codex exec resume "$RESUME_THREAD_ID" --json ... -- "$FOCUS" < /dev/null`)
   with the CLI's own documented `-` PROMPT convention to force stdin reading, sourced from the same
   private file, deleted only after the child process exits — exactly `$PROMPT_FILE`'s existing
   ordering rule (old gap #7), just applied to this new call shape too. `set -x`/xtrace stays off
   for this whole call chain.

**Codex's own summary for this round**: the round-1 direction is sound, but not yet CLEAN without
these three concrete contracts — explicitly including that stdin is only a real fix "when raw focus
bytes enter through an actual stdin/file-descriptor transport and never through a parent command
string, environment, trace, or world-readable temporary file," and that an artifact genuinely
changed between rounds "should always start a new review from a new immutable snapshot" rather than
resuming. Both points are folded into findings 6/7 above.

**Revised Phase 1 scope after round 2** (supersedes the round-1 revision's Phase 1 description):
Phase 1 now specifies, concretely: (a) the `-o` file-lifecycle contract (finding 5); (b) the
canonical-subject hash + mismatch-restarts-review rule, which also answers round 2's own open
question about intentional artifact changes (finding 6, folds in old #12's revalidation refinement);
(c) the exact stdin transport at both boundaries, reusing the existing `$PROMPT_FILE`
deferred-deletion pattern rather than a new one (finding 7, closes old #3/#11 concretely, not just
in principle).

## Round 3 negotiation outcome (same thread, resumed)

Codex confirmed findings 1–5 and 7 are now fully resolved by the round-2 concretization, and
raised exactly **one** remaining finding: item 6 (hash-based revalidation) was internally
self-contradictory — "hashed once, never recomputed from the live source" cannot coexist with
"detect a mismatch and restart," since detecting a mismatch against the *original* artifact
requires re-observing that live source, which the same sentence says never happens. Codex offered
two coherent resolutions and recommended one, consistent with this roadmap's own stated goal of
avoiding per-round live-diff recollection:

8. **[MEDIUM, ACCEPTED — Codex's recommended option]** "Mismatch" is redefined to mean **snapshot
   corruption/tampering of Claude's own private copy**, never a changed original artifact. Concretely:
   round 1 collects the diff/artifact bytes once into a private snapshot file and hashes it. Every
   later round verifies only that the SNAPSHOT FILE ON DISK still matches that original digest
   before dispatch (catches accidental deletion/corruption/TOCTOU on our own temp file) — it never
   re-observes the real working tree or the original pasted text. An intentionally amended
   artifact/diff is **out of scope for an active review by design**: reviewing new changes requires
   an explicit new `/ccs` invocation (a new review, new session id, new threads), never something
   the running review auto-detects and pivots on mid-flight. This matches how the resumed-round
   mechanism already behaves today (round 2+ never re-collects the diff either way) — it closes the
   contradiction without adding the live-recollection cost the design was trying to avoid in the
   first place.

**Revised Phase 1 scope after round 3** (final refinement to item 6 from round 2): "hash-based
revalidation" in Phase 1 now specifically means integrity-checking Claude's own private snapshot
file against corruption/deletion between rounds — not change-detection against the original source.
Reviewing a changed artifact/diff is an explicit non-goal for a single active review; the roadmap
should say so plainly rather than implying auto-detection.

## Final consolidated plan (post-negotiation, ready for implementation planning)

This section is the single source of truth for what to actually build; everything above is the
negotiation record that produced it.

### Phase 1 — Stability/correctness/security (implement first)
1. **F**: Fix README.md's two stale tmux-pane references.
2. **Replace rollout-file tailing as the correctness-critical path.** Add
   `-o "$LAST_MESSAGE_FILE"` to every dispatch (fresh, resume, and every Guards-section retry
   attempt). `LAST_MESSAGE_FILE` is a fresh `mktemp`'d file per attempt, never reused. Trust its
   content only when: exit code 0 AND the `--json` stdout stream emitted this attempt's own
   completion event AND the file was written during this attempt's lifetime. Rollout-file access,
   if kept at all, is a secondary best-effort live-progress signal only — never the source of the
   actual verdict. Delete `LAST_MESSAGE_FILE` after use; retain only under `--keep-evidence`.
3. **Stdin transport for `--focus`/prompt content, both boundaries, reusing the existing
   `$PROMPT_FILE` deferred-deletion pattern:**
   - Claude → `run-ccs-review.sh`: redirect the existing sentinel-file `FOCUS_FILE` directly into
     the wrapper's stdin. Never `printf | wrapper`, never embedded in a `sh -c` string, never a
     `--focus "$TEXT"` argv value.
   - wrapper → `codex exec`: replace the current `-- "$FOCUS"` positional-argv pattern with the
     CLI's documented `-` PROMPT convention, reading from a private file, deleted only after the
     child process exits (same ordering rule as `$PROMPT_FILE` today). `xtrace` stays off for the
     whole chain.
   - This closes the argv-exposure gap and the large-non-repo-artifact `ARG_MAX` risk together.
4. **Evidence retention on failure, explicit opt-in:** `--keep-evidence` flag (not the unconditional
   default) preserves a failed round's thread/`LAST_MESSAGE_FILE`/rollout; retained artifacts get a
   durable manifest entry, an explicit cleanup command, and best-effort start-of-run pruning (same
   style as the existing Phase 0 stale-eventlog sweep — never described as a guaranteed TTL). No
   generic redaction pass; store retained data in a private, owner-only directory.
5. **Untrusted-data framing extended to Codex's own prior-round output** — the same "data, not
   instruction" discipline the diff/`--focus` boundary already gets, applied to History-construction
   text built from earlier rounds' findings.
6. **Snapshot-integrity-only revalidation** (final, non-contradictory form): round 1 collects the
   diff/artifact bytes once into a private snapshot file and hashes it. Every later round verifies
   only that this snapshot file on disk still matches its original digest before dispatch — it
   never re-observes the real working tree or original pasted text again. Reviewing a genuinely
   changed artifact/diff is explicitly **out of scope for an active review** — that requires a new
   `/ccs` invocation (new session id, new threads), never an auto-detected mid-review pivot.

### Phase 2 — Convergence-logic hardening
Deterministic ledger: every claim gets a stable `claim_id` (location/subject/rule), a `state` enum
(`asserted`/`rebutted`/`accepted`/`retracted`/`deferred`), and a hash of its cited evidence.
Convergence requires every active claim to reach a mutually-recorded terminal state with no new
claim/evidence introduced that round. A claim revisiting a previously-seen
`(claim_id, state, evidence-hash-set)` tuple after a rebut/re-raise cycle is explicitly
`NOT CONVERGED`. Pure local map/set comparison — no extra LLM call.

### Phase 3 — Upstream-risk hardening (shrunk after negotiation)
Gzip-awareness for `resolve_rollout` is **dropped** — superseded by Phase 1's `-o` switch, which
removes the correctness dependency on rollout parsing entirely. Remaining scope: best-effort
cost/effort reporting (selected model/effort, elapsed time, any process-emitted usage figures —
never framed as authoritative billing/quota data, no extra quota-lookup call).

### Phase 4 — Structural/strategic expansion (unchanged in spirit, refined criteria)
- `codex exec fork` (confirmed available in the installed 0.153.0 CLI, same `--json`/`-o`/
  `--output-schema` contract as `exec`/`resume`) stays out of Phase 1 — no established
  cross-version stability guarantee. Adopt only after a version-gated canary test covering parent-
  session immutability, concurrent children, and resume/fork history integrity.
- Headless/CI-gateable entry point, as originally scoped.

### Standing rule
Before calling this roadmap 1.0-ready, every one of the 27 internal gap-list items must have an
explicit disposition: a phase assignment, an accepted-residual-risk statement, or an explicit
non-goal — never silent omission.

### Next step
Take Phase 1 (the most concretely specified) through `superpowers:writing-plans` for an actual
implementation plan; Phases 2–4 follow the same path once Phase 1 ships.

---

## Appendix: original round-1 negotiation brief (historical)

This is **no longer live guidance** — it's the brief that opened round 1, kept for the negotiation
record. See "Final consolidated plan" above for what was actually agreed.

This is a **non-repo-artifact** review: there is no diff. Negotiate the plan itself — sequencing,
Phase 1's two open questions above, Phase 2's convergence-gate design question, and anything in the
internal/external research that seems wrong, overstated, or missing a risk. The goal is a
concretized, mutually-agreed Phase 1 design (ready to turn into an implementation plan) plus a
sanity-checked sequencing for Phases 2–4.

The plugin author additionally asked these four questions to be answered explicitly in the review,
not just implicitly covered:
1. **Is the plan itself sound?** Does the phase ordering and the specific Phase 1 design actually
   solve the stated problems, or does it just look plausible?
2. **Is the tech/approach used valid and current?** In particular: is depending on `codex exec`
   `resume`/rollout-file tailing, given the confirmed-open upstream corruption bugs (#40630,
   #35746), still the right foundation, or should Phase 1/3 reconsider it now rather than patch
   around it? Is `codex exec fork` (Phase 4 candidate) actually available/stable enough to pull
   forward, or premature?
3. **What holes remain?** Anything in the 27-item internal list, the roadmap, or the two Phase 1
   open questions that is underspecified, wrong, or missing.
4. **What could make this worse, not better?** Specifically: could keeping Codex threads/rollout
   files alive on failure (Phase 1 item A) increase disk usage, leak sensitive diff content for
   longer, or degrade performance/latency for the *next* review (e.g. `~/.codex/sessions/`
   directory growth slowing `resolve_rollout`'s glob, or accumulated undeleted threads slowing
   `codex` CLI's own session listing)? Any other proposed change (gzip-aware rollout reading,
   cost/effort surfacing, per-round re-validation) that could add latency or fragility rather than
   remove it?

**Note on authority**: this plugin wraps Codex's own CLI, so on questions about `codex exec`'s
*current* actual behavior — rollout file format/compression, `resume` vs. `fork` semantics,
sandbox mode guarantees, current rate-limit/quota accounting behavior — Codex is the more
authoritative source (it is reporting on its own tool), not merely an equal debate partner. Claude
should actively solicit Codex's direct knowledge on these specific points rather than only
defending the external research above, while still independently verifying any such claim before
it changes the plan (same equal-partnership/disclosure-ordering discipline this skill already
applies everywhere else — a claim of self-knowledge is not exempt from evidence).
