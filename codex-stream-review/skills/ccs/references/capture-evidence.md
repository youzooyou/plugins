# Investigation evidence capture — reference

> Read this file in full because `--capture-evidence` was determined ON for this session (see
> `SKILL.md`'s Phase 0 Step 0). Everything below is required for at least four later points in
> this run: Phase 1 Step 0's `EVENTLOG_FILE` allocation, Step 1's `--capture-eventlog` flag, Phase
> 2's extraction step, and the Guards section's retry-time eventlog handling in `SKILL.md`.

## Investigation evidence capture (opt-in via `--capture-evidence`)

**Off by default.** A normal `codex-stream-review:ccs <task description>` invocation (no
`--capture-evidence` prefix) never touches anything in this section — no extra dispatch flag, no
extra JSONL field, zero behavior change from everything else this file documents. Adapted to this
skill's already-GROUP-aware temp-file conventions; no version-gating preflight is needed (see
"Scope" above — `run-ccs-review.sh` has supported `--capture-eventlog` since its first release).

**What turns it on:** the one-time Phase 0 Step 0 decision above.

**What it captures:** only the literal shell commands Codex actually ran during that round's
investigation (e.g. `grep -rn foo src/`, `cat package.json`, `npm test`) — never their output,
never file contents, never anything else from the raw event stream. This lets Claude's
re-verification step (Phase 2, "Re-verify EACH finding against facts/evidence") cross-check a
finding's self-reported "verification" narrative against what Codex actually ran, instead of
trusting the claim at face value.

**How it's captured, per (round, group) dispatch:**
1. When capture is ON for this session, allocate a 5th temp file alongside
   `PID_FILE`/`OUT_FILE`/`ERR_FILE`/`FOCUS_FILE` in Phase 1 Step 0, same template style, same
   `GROUP` segment:
   ```bash
   EVENTLOG_FILE=$(mktemp "/tmp/ccs-${SESSION_ID}-round-<R>-${GROUP}-eventlog.jsonl.XXXXXX")
   echo "EVENTLOG_FILE=$EVENTLOG_FILE"
   ```
   Then pass the exact literal resolved path as `--capture-eventlog "$EVENTLOG_FILE"` on THAT
   group's Phase 1 Step 1 dispatch call — fresh or resumed, every round, not just round 1 (each
   `run-ccs-review.sh` invocation is its own separate `codex exec`/`codex exec resume` process
   with its own event log, whether or not the underlying Codex thread is being resumed). **This
   applies to EVERY `run-ccs-review.sh` dispatch this file ever constructs, with no exception —
   Phase 1 Step 1's own fresh/resume examples, AND every retry variant in Guards below** (the
   no-threadId-yet fresh retry, the resume-safe bounded retry, the resume-retries-exhausted
   fallback fresh retry, and the non-resume-safe immediate fresh retry): each is its own separate
   process invocation and gets its own freshly-`mktemp`'d `EVENTLOG_FILE` the same way, never the
   original round's already-consumed one, when capture is ON — see the Guards section's
   resume-safe retry bullet for the one case (a genuine resume-retry succeeding) where more than
   one eventlog for the same (round, group) needs an explicit rule for which one actually gets
   extracted from.
2. **Extract the command list and wrap it into the JSONL schema's required object shape, in ONE
   `jq` call**, once that group's dispatch call has returned and its JSON stdout has been parsed.
   The `investigation_evidence` field (see "Review history log" below) is an OBJECT —
   `{"command_count": N, "commands": [...]}` — not a bare array. **First decide whether this
   group's dispatch ever actually invoked `codex exec`/`codex exec resume` as a subprocess at
   all — this is NOT the same question as whether `$EVENTLOG_FILE` is empty** (`mktemp`
   pre-creates it as 0 bytes before the round even dispatches, so a genuinely-ran process that
   issued zero commands and a process that never got that far look identical on disk). **`threadId`
   presence means two DIFFERENT things depending on whether this was a fresh or a `--resume`
   dispatch — never use one rule for both:**
   - **Fresh dispatch:** `threadId` is only ever set once a real `thread.started` event actually
     fires (confirmed from the wrapper's own fresh-dispatch code path) — its presence in the
     result IS a reliable "a process genuinely started" signal here. Skip extraction only for
     `bad_args`/`git_error`/`incomplete_collection`/`no_thread_started` (never carry a `threadId`
     at all) or for `interrupted` specifically WITHOUT a `threadId` in the result (the signal
     arrived before `thread.started` ever fired). Every other fresh-dispatch outcome — `ok:true`,
     or `ok:false` with `threadId` present — means extraction is meaningful; run it, even if it
     ends up reporting a real, honest zero.
   - **`--resume` dispatch: `threadId` is asymmetric, and this skill still classifies by `reason`
     alone rather than by `threadId` at all** — confirmed directly from the wrapper's own source:
     `THREAD_ID` starts empty, is assigned exactly once — `THREAD_ID="$RESUME_THREAD_ID"` (the
     caller's own input argument, echoed straight back), only after focus/scope validation has
     already passed — and is never reassigned or cleared afterward on this path; `codex exec
     resume` doesn't launch until later still. That makes an ABSENT `threadId` in a resume-dispatch
     result a reliable negative: it can only happen before that one assignment, meaning this
     invocation never reached the point of launching `codex exec resume` at all (a `bad_args`
     failure — always before the signal trap is even installed — or a pre-assignment
     `interrupted`). A PRESENT `threadId`, by contrast, is genuinely ambiguous — merely the echoed
     input, it is present whether the failure landed microseconds after that echo (nothing
     launched yet) or well after `codex exec resume` actually ran, so presence alone never confirms
     a launch. This asymmetry doesn't change any actual extraction decision here, so `threadId` is
     still never checked: `bad_args` and `resume_thread_not_found` are already skipped by `reason`
     name alone (the former is always ID-less by the above, the latter is always ID-present but by
     definition always pre-launch — see its own row in the reason table). `interrupted` is skipped
     as the conservative choice either way it occurs — an ID-less occurrence is a confirmed
     non-launch, and an ID-present occurrence is unresolvably ambiguous, so treating both alike
     avoids a `threadId`-shaped special case for this one reason: reporting a fabricated
     zero-command object for an investigation that may never have happened is worse than the
     (typically rare, narrow-window) case of omitting a real-but-brief one. Every other reason —
     `ok:true`,
     `timeout`, `nonzero_exit`, `missing_task_complete`, `rollout_not_found`, `no_final_answer`,
     `invalid_json`, `schema_mismatch` — can ONLY occur after `codex exec resume` genuinely
     launched (`rollout_not_found` specifically is a POST-launch rollout re-resolution failure,
     not the resume-only PRE-flight `resume_thread_not_found` check above — the two are separate
     reasons at separate points, never conflate them); extraction is meaningful and always runs
     for these.
   Either skip path means this group's contribution to `investigation_evidence` is simply absent
   (see step 3's merge behavior for what that means in parallel mode) — never a zero-command
   placeholder standing in for "nothing actually happened":
   ```bash
   EVENTLOG_FILE="<this group's literal path from step 1 above, same round>"
   if [ -s "$EVENTLOG_FILE" ]; then
     INVESTIGATION_EVIDENCE_JSON=$(jq -Rn -c '
       [inputs | fromjson? | select(.type == "item.completed" and .item.type == "command_execution") | .item.command]
       | {command_count: length, commands: .}
     ' "$EVENTLOG_FILE")
   else
     INVESTIGATION_EVIDENCE_JSON='{"command_count":0,"commands":[]}'
   fi
   ```
   The ONLY bash-level capture here is the well-formed, complete JSON object as `jq`'s own stdout
   via `$(...)` into `INVESTIGATION_EVIDENCE_JSON` — safe regardless of what characters the
   captured commands contain, since the object is never disassembled into and reassembled from an
   intermediate bash string; `jq` handles all JSON construction internally in one pass.
   `fromjson?` swallows any unparseable line rather than erroring the whole extraction, so a
   partial or malformed event log still yields whatever valid entries it contains. This group's own
   `$INVESTIGATION_EVIDENCE_JSON` (when extraction ran at all) is the final value used at step 4
   below for a single-reviewer round (see step 3 immediately below for the parallel-mode case).
3. **Merge multiple groups' evidence into one object — parallel mode only.** The review history
   log's schema has exactly ONE `investigation_evidence` object per ROUND, but a parallel round
   dispatches more than one group, each producing its own separate `INVESTIGATION_EVIDENCE_JSON`
   from step 2 — **or no value at all, for a group whose step 2 was skipped entirely** (its
   dispatch never meaningfully started `codex exec`, per step 2's `ok`/`reason` check above). A
   skipped group contributes NOTHING to the merge below — not a zero-value placeholder, simply
   excluded from the list of values combined — same principle as step 2 itself, applied across
   groups. **Common case — a single-reviewer round (`GROUP="main"`): nothing to merge**, use that
   group's own value directly, unchanged, or omit `investigation_evidence` entirely from this
   round's line if that one group's own step 2 was skipped. **Only when this round actually
   dispatched more than one group AND at least one of them has a real value:** combine every
   dispatched group's value into ONE merged object by summing `command_count` and concatenating
   `commands` across groups, in one `jq` call:
   ```bash
   MERGED_INVESTIGATION_EVIDENCE_JSON=$(jq -sc '{command_count: (map(.command_count) | add), commands: (map(.commands) | add)}' <<< "$GROUP1_JSON
   $GROUP2_JSON")
   ```
   (one heredoc line per group that actually produced a real value this round — a group whose
   step 2 was skipped simply isn't one of the lines). If EVERY dispatched group's step 2 was
   skipped this round, there is nothing to merge — omit `investigation_evidence` from that round's
   line entirely, the same as the single-reviewer skip case above. Use the merged object — never
   any single group's own value — as the one `investigation_evidence` field written into that
   round's single JSONL line. A failure in this merge step follows the same best-effort discipline
   as the rest of this section: note it once and omit `investigation_evidence` from that round's
   line rather than blocking the round.
4. **Delete the raw event-log copy right after extraction, best-effort:** `rm -f "$EVENTLOG_FILE"`
   (per group, if parallel mode dispatched more than one). The intent is a strong privacy
   contract — the raw event stream can echo back actual file contents Codex read during its
   investigation, so only the extracted command strings are meant to persist, and only into the
   existing review history log. A plain `rm -f` run after the fact has no atomicity or crash guard
   around it: if this session is interrupted between the dispatch call finishing and this `rm -f`
   executing, that round's raw event-log file is left behind — a real gap, bounded in practice by
   the unconditional Phase 0 Step 0 sweep above (removed no later than the start of the next `/ccs`
   invocation of any kind, at least 60 minutes later), not eliminated outright.

**Where it's stored:** no new file, no new format. When capture is ON for this session, add the
one optional `investigation_evidence` field to that round's existing JSONL line (see "Review
history log" below), using the (possibly group-merged) `$INVESTIGATION_EVIDENCE_JSON` from above
as that field's value. Same log, same append-only write, nothing new to create.

**Failure isolation:** exactly the same best-effort discipline as the rest of this log — a `jq`
failure in step 2/3's extraction/merge, a missing/empty event-log file, or a failed `rm` must
never abort or degrade the review round. Note it once in that round's narration and continue with
`investigation_evidence` simply omitted from that round's line.

---

## JSONL field: `investigation_evidence`

**With capture-evidence ON**, that same line gains one more sibling field, `investigation_evidence`
— the `{"command_count": N, "commands": [...]}` object "Investigation evidence capture" above
produces (group-merged first, for a parallel round):
```json
{"investigation_evidence": {"command_count": 3, "commands": ["grep -rn foo src/", "cat package.json", "npm test"]}}
```
(shown here as its own standalone object containing only the field being illustrated; in the
actual log line it is one sibling field alongside `session_id`/`round`/`target`/etc., exactly as
in the full example above.) Omitted entirely — never an empty `{"command_count":0,"commands":[]}`
placeholder — when capture-evidence is OFF for this session, so a plain `jq 'has
("investigation_evidence")'` on any line reliably tells whether that session had capture on.
