---
name: codex-review
description: Use when you want a single, one-shot Codex CLI review run directly — no multi-round cross-verification, no dependency on the codex:codex-rescue subagent. Reviews uncommitted changes, a branch diff, or a specific commit.
---

# Codex Review (direct)

## Overview

Runs exactly one Codex review as a fresh, ephemeral process — generic `codex exec` with a
hand-built prompt that embeds a self-gathered git diff (not the `review` subcommand) — via this
plugin's `run-codex-review.sh`, and presents the result. Unlike `/cc`, there is no round loop or
cross-verification — this is the lightweight, single-shot version.

## When invoked

1. **Determine scope.** Ask the user (or infer from their message) which of these applies:
   - Review uncommitted changes (staged + unstaged + untracked)
   - Review against a base branch (ask which branch if not stated)
   - Review a specific commit (ask for the SHA if not stated)

2. **Determine focus text.** If the user gave specific instructions or requirement/intent context
   ("check for security issues", "just look at the auth logic", "this changes how discounts are
   calculated for VIP accounts"), use that as the focus text. **If the user gave none, do not invent
   a generic one** — omit `--focus` entirely. The wrapper's own no-`--focus` prompt already covers
   the same generic ground (correctness, security, performance, reuse) AND explicitly instructs the
   model to disclose that no intent/requirement context was available, so a code-only `CLEAN` can't
   be mistaken for a full requirements review. Synthesizing filler focus text here would defeat that
   disclosure by making the wrapper think real context was supplied when none was.

3. **Run the wrapper.** Construct and run via Bash:
   ```bash
   "${CLAUDE_PLUGIN_ROOT}/scripts/run-codex-review.sh" \
     --cwd "<the project directory>" \
     --uncommitted \
     --focus "<focus text>"
   ```
   Omit the `--focus` flag entirely (not `--focus ""`) when step 2 found no real context to pass.
   (swap `--uncommitted` for `--base <branch>` or `--commit <sha>` per the resolved scope).

4. **Parse the JSON result from stdout:**
   - `"ok":false` → tell the user the review run itself failed, and show the `reason`/`detail`
     fields plainly. **Never** describe a failed run as "no issues found" — those are different
     things and must not be conflated.
   - `"ok":true` → present `verdict.verdict` and `verdict.findings` (file, line if present,
     severity if present, summary, evidence, verification), most severe first. If `findings` is
     empty, say so explicitly.
   - `verdict.dimensions` is a per-dimension review-completion ledger (correctness, security,
     performance, reuse, contracts, resources_concurrency, intent — each with a `status` of
     `checked`/`not_applicable`/`blocked` and an `evidence` string). Normally no need to surface
     this to the user unless something is `blocked` (the model tried to check that dimension but
     genuinely could not) — mention that explicitly, the same way a partial `coverage.source` gets
     flagged below, since it means the review has a known gap.
   - **Check for a top-level `coverage.source` object** (present only for `--uncommitted`; absent
     for `--base`/`--commit`). If `coverage.source.status` is `"partial"`, say so **prominently,
     before or alongside the verdict** — e.g. "⚠️ Source coverage partial: N file(s) were not fully
     reviewed" — and list each `coverage.source.omitted` entry (`path` + `reason`: `symlink`,
     `not_regular_file`, `over_size_limit`, `binary`, `unreadable`). **Never present a `CLEAN` verdict as if it
     were a complete review when `coverage.source.status` is `"partial"`** — a clean verdict only
     means no defects were found in the material that WAS reviewed; say plainly that some source
     was not inspected (e.g. an oversized or binary file) rather than letting "CLEAN" imply nothing
     was missed. If `coverage` is absent entirely (e.g. a `--base`/`--commit` scope, or the wrapper
     could not determine coverage for this run), do not claim either complete or partial coverage —
     just present the verdict normally, since there is nothing to report either way.

5. **Stop after presenting findings.** Do not make any code changes. Ask the user which findings,
   if any, they want fixed before touching a single file — the same rule the existing
   `codex-result-handling` skill applies to `codex:codex-rescue` output applies here too, even
   though this path doesn't go through that subagent.
