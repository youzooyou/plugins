# codex-direct-review — design

Date: 2026-08-28
Status: approved (Claude + user + Codex technical validation), pending implementation plan

## Problem

`/cc` (this account's custom Claude+Codex cross-review command) currently calls Codex through the
`codex:codex-rescue` subagent, which forwards to the `openai-codex` plugin's `codex-companion.mjs`.
That path routes through a shared, long-lived "app-server broker" process wrapping `codex
app-server`. Traced live (2026-08-28) into three concrete reliability gaps:

1. **Silent failure by design** — `codex:codex-rescue`'s own contract says "If the Bash call fails
   or Codex cannot be invoked, return nothing." Any underlying crash/auth/network failure comes
   back as an empty result with no error text.
2. **Premature inferred completion** — `lib/codex.mjs`'s `scheduleInferredCompletion` finalizes a
   turn 250ms after seeing what looks like a final agent message, if no formal "turn complete"
   event arrived. An ambiguous mid-work message can get treated as the final answer.
3. **Genuine stalls** — under context pressure (huge diffs, wandering into `node_modules`), the
   agentic loop can go idle and emit only `{"type":"idle_notification"}` instead of a real result.
   Already documented as a known `/cc` failure pattern before this design.

Because the broker/app-server process is shared and long-lived (confirmed via `ps aux` — it was
running continuously since before this session started), a bad state from one review can carry
into the next.

## Revision (2026-08-28, during implementation — corrects a wrong claim below)

**`codex exec review` does not honor `--output-schema`.** This was discovered during Task 3's
implementation, via three real live `codex exec review` calls (two against an empty diff, one
against a real 845-insertion diff via `--base`). The third call proved codex genuinely performed a
thorough, correct review — it read repo files, ran `git diff`, even executed our own script to
reproduce a bug — but returned the result as **prose**, not JSON, regardless of `--output-schema`.
This directly contradicts the "Codex confirmed... it respects `--output-schema` correctly" claim in
the bullet list right below, which was Codex's own (wrong) answer to a design-validation question
asked before any live testing of the `review` subcommand specifically happened.

**Corrected decision:** use generic `codex exec` (no `review` subcommand) with a hand-built prompt
that (a) embeds a diff we gather ourselves via `git diff`/`git diff <base>...HEAD`/`git show <sha>`
and (b) explicitly instructs the model to respond with only JSON in the target shape. This exact
pattern — generic `codex exec` + an explicit in-prompt instruction of the desired JSON shape — was
live-verified working, twice, during this project's own initial research (see the "What I verified
live" section of this doc's history / the implementation plan's Task 3): a plain `"Reply with
exactly PONG"` prompt, and a `"Return verdict CLEAN with an empty findings array"` prompt against a
`{verdict, findings}` schema, both returned exactly the requested content. The `review` subcommand's
own diff-gathering convenience (`--uncommitted`/`--base`/`--commit`) is replaced by doing the
equivalent `git diff` ourselves — no new dependency, and it removes an entire class of arg-parsing
conflicts the `review` subcommand had (a positional prompt is unconditionally incompatible with its
scope flags in codex-cli 0.146.0, which was a separate bug found in the same investigation).

The wrapper's own CLI surface (`--cwd`, `--uncommitted`/`--base`/`--commit`, `--focus`, `--timeout`)
is unchanged — only what happens *inside* the wrapper changes. `/cc` and `/codex-review` (Components
3 and 4 below) are unaffected by this revision.

## Decision

Replace only `/cc`'s "call Codex" step with a direct, one-shot invocation of the Codex CLI —
bypassing the `openai-codex` plugin's broker entirely for this path. Everything else in `/cc`
(phases, round loop, convergence table, scope constraint, adversarial re-verification by Claude) is
unchanged.

### Why direct `codex exec`, not the broker

Verified live on this machine (codex-cli 0.146.0). The bullet below about `codex exec review` and
`--output-schema` was Codex's own answer to a design-validation question and turned out to be
**wrong** — see the Revision section above for the corrected mechanism (generic `codex exec` + a
hand-built prompt, not the `review` subcommand). The rest of this list still holds:

- ~~`codex exec review [--uncommitted | --base <branch> | --commit <sha>] "<focus text>"` is a
  purpose-built, non-interactive, one-shot review command — Codex confirmed this (not a hand-rolled
  `codex exec` prompt) is the correct subcommand, and that it respects `--output-schema` correctly.~~
  **Wrong — see Revision above.** `codex exec review` ignores `--output-schema` and returns prose.
- `--ephemeral` skips repo indexing/session persistence. Codex confirmed this doesn't degrade review
  quality (review doesn't depend on learned session state) — only a large-codebase indexing-cache
  speed tradeoff, not correctness.
- `--sandbox read-only` matches the existing "review/diagnosis only, never edit" contract.
- `--json` streams a well-defined event protocol: `thread.started` → `turn.started` →
  `item.completed` (carries the actual message) → `turn.completed` (unambiguous, carries token
  usage). No inferred-completion heuristic needed on our side.
- `--output-schema <file>` + `--output-last-message <file>` together give a deterministic, directly
  parseable final verdict — live-tested with a `{verdict: CLEAN|ISSUES, findings: []}` schema and
  got back exactly-matching JSON.
- After the process exits, `ps aux` showed **zero** lingering codex-related processes — genuinely
  fresh every run, which is the property this design exists to get.

### What we deliberately give up

No cross-round session resumption (no `--resume`/`--fresh` distinction at all — moot, since
`--ephemeral` never has a session to resume into). This is a simplification, not a loss: `/cc`
already carries cross-round context by writing a recap into each new prompt (what was found last
round, what was accepted/rejected) — that pattern continues unchanged, it just no longer has a
`--resume-last` fallback to lean on. Per Codex's own caveat, this is fine for `/cc`'s typical 1–3
round usage; if a workflow ever needed 10+ rounds, session-pooling would need revisiting (not a
concern for `/cc`'s actual usage pattern).

## Components

**Placement note (revised after user request):** an earlier draft of this spec colocated the
wrapper inside `/cc`'s own directory to dodge plugin install-path versioning
(`~/.claude/plugins/cache/<marketplace>/<name>/<version>/` changes on every version bump — observed
directly with `clear-prep` 1.0.0 → 1.0.1 earlier this session). The user then asked for this to be
shareable via the `youzooyou/plugins` marketplace too, plus a standalone command usable without
`/cc`. Final resolution: package it as its own plugin (`codex-direct-review`), and have `/cc` (which
stays a personal, non-plugin command) resolve the plugin's current install path **dynamically at
call time** instead of hardcoding it:

```bash
jq -r '.plugins["codex-direct-review@youzooyou-plugins"][]
       | select(.scope=="user") | .installPath' \
  ~/.claude/plugins/installed_plugins.json
```

This survives version bumps with no code change in `/cc` — the lookup always reflects whatever is
currently installed. If the lookup returns nothing (plugin not installed), `/cc`'s Phase 2 must fail
loudly with an actionable message ("install `codex-direct-review@youzooyou-plugins` first"), not
silently fall back to the old `codex:codex-rescue` path.

### Final repo layout

```
youzooyou/plugins/
  clear-prep/                        (existing, unchanged)
  codex-direct-review/                (new)
    .claude-plugin/plugin.json         (name, version, description — no hooks field, this plugin has no hooks)
    scripts/run-codex-review.sh
    schemas/review-verdict.schema.json
    skills/codex-review/SKILL.md       (standalone command: /codex-review, usable without /cc)
```

Within the plugin's own bundled skill (`skills/codex-review/SKILL.md`), the script path resolves
via `${CLAUDE_PLUGIN_ROOT}` as normal (that variable is valid there, unlike from `/cc`, because the
skill lives inside the plugin itself — same directory, same version, moves together).

### 1. `codex-direct-review/scripts/run-codex-review.sh`

Thin wrapper, single responsibility: run one Codex review, judge success strictly, never return
silence.

Inputs (CLI args): working directory, scope (`--uncommitted` | `--base <branch>` | `--commit <sha>`
— passed straight through to `codex exec review`), focus/prompt text, path to a JSON Schema file.

Behavior:
```
codex exec review --ephemeral --sandbox read-only --skip-git-repo-check --json \
  --output-schema "$SCHEMA" --output-last-message "$OUTFILE" \
  $SCOPE_FLAGS "$FOCUS_TEXT" < /dev/null > "$EVENTLOG" 2>&1 &
CODEX_PID=$!
```
- Enforce a **hard wall-clock timeout** (default 300s, per Codex's explicit recommendation — don't
  rely on `turn.completed` absence alone). On timeout: kill the process tree, report failure.
- On normal exit, success requires **all three**:
  1. exit code 0
  2. `$EVENTLOG` contains a `"type":"turn.completed"` line
  3. `$OUTFILE` is non-empty **and** validates against `$SCHEMA` (real schema validation, not just
     "is it parseable JSON" — Codex explicitly flagged "valid JSON, wrong shape" as a silent-failure
     risk of its own)
- On any failure (bad exit code, timeout, missing `turn.completed`, schema validation failure, empty
  output): print a structured `{"ok": false, "reason": "...", "detail": "..."}` to stdout and exit
  non-zero. Never print nothing.
- On success: print `{"ok": true, "verdict": <parsed JSON>}` to stdout and exit 0.

### 2. `codex-direct-review/schemas/review-verdict.schema.json`

```json
{
  "type": "object",
  "properties": {
    "verdict": { "type": "string", "enum": ["CLEAN", "ISSUES"] },
    "findings": {
      "type": "array",
      "items": {
        "type": "object",
        "properties": {
          "file": { "type": "string" },
          "line": { "type": "integer" },
          "severity": { "type": "string" },
          "summary": { "type": "string" },
          "evidence": { "type": "string" }
        },
        "required": ["file", "summary", "evidence"]
      }
    },
    "summary": { "type": "string" }
  },
  "required": ["verdict", "findings"],
  "additionalProperties": false
}
```

### 3. `~/.claude/commands/cc/SKILL.md` — Phase 2 rewrite

Replace the entire "Codex invocation contract" section (Agent tool, `codex:codex-rescue`,
`--fresh`/`--resume`, `model: haiku` forwarding) with: resolve
`codex-direct-review@youzooyou-plugins`'s current `installPath` via the `jq` lookup above, then run
`<installPath>/scripts/run-codex-review.sh` via Bash, passing the round's scope/focus text; parse
its stdout JSON (`ok`/`verdict`/`reason`) directly — no subagent layer at all. The round loop,
convergence rules, scope-constraint block, and adversarial self-verification (Claude re-checking
each finding) are unchanged text. If the path lookup comes back empty, stop Phase 2 and tell the
user to install the plugin — never fall back to `codex:codex-rescue` silently.

### 4. `codex-direct-review/skills/codex-review/SKILL.md` — standalone `/codex-review` command

For use independent of `/cc` (e.g. a quick one-shot review with no multi-round cross-verification).
Frontmatter: `name: codex-review`, description starting "Use when you want a single Codex CLI review
run directly...". Behavior:

1. Determine scope from the user's args or ask (uncommitted changes / against a base branch / a
   specific commit) and any focus text.
2. Run `"${CLAUDE_PLUGIN_ROOT}/scripts/run-codex-review.sh"` with that scope/focus (path resolves
   natively here — this skill lives inside the same plugin as the script, so no `jq` lookup needed,
   unlike `/cc`).
3. Parse the JSON result:
   - `ok: false` → report the `reason`/`detail` to the user plainly as a failed run. Do not
     characterize a failed run as "no issues found."
   - `ok: true` → present `verdict` and `findings` (file/line/severity/summary/evidence), most severe
     first.
4. Per the existing `codex-result-handling` convention (kept consistent even though this bypasses
   `codex:codex-rescue`): **stop after presenting findings.** Do not auto-fix anything. Ask the user
   which findings, if any, they want addressed before touching a single file.

## Non-goals

- Not touching `codex:codex-rescue`/`codex-cli-runtime`/`codex-result-handling` — those stay as-is
  for any other use (`/codex:rescue`, ad-hoc "delegate this to Codex" requests). This design only
  changes what `/cc` itself calls internally.
- Not building session pooling/reuse across rounds — explicitly out of scope per the "what we give
  up" section above.
- Not changing `/cc`'s Phase 0/1/3 (artifact resolution, review-mode sizing, final report) at all.

## Open risks (carried forward, not blocking)

- Codex flagged only MEDIUM confidence on "does a genuinely large diff review realistically finish
  within a normal process lifetime" — the 300s timeout is a judgment call, not a guarantee reviews
  never legitimately need longer. If real usage shows timeouts on large-but-legitimate reviews,
  raise the timeout rather than treating it as a design failure.
- `codex exec review`'s built-in scope flags (`--uncommitted`/`--base`/`--commit`) are being trusted
  to gather target context correctly, the same way the current plugin does internally — this
  wrapper does not re-implement diff collection.
