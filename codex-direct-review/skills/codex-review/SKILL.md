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

2. **Determine focus text.** If the user gave specific instructions ("check for security issues",
   "just look at the auth logic"), use that as the focus text. Otherwise use a generic instruction:
   "Review this diff for correctness bugs, security issues, and reuse/simplification opportunities."

3. **Run the wrapper.** Construct and run via Bash:
   ```bash
   "${CLAUDE_PLUGIN_ROOT}/scripts/run-codex-review.sh" \
     --cwd "<the project directory>" \
     --uncommitted \
     --focus "<focus text>"
   ```
   (swap `--uncommitted` for `--base <branch>` or `--commit <sha>` per the resolved scope).

4. **Parse the JSON result from stdout:**
   - `"ok":false` → tell the user the review run itself failed, and show the `reason`/`detail`
     fields plainly. **Never** describe a failed run as "no issues found" — those are different
     things and must not be conflated.
   - `"ok":true` → present `verdict.verdict` and `verdict.findings` (file, line if present,
     severity if present, summary, evidence), most severe first. If `findings` is empty, say so
     explicitly.

5. **Stop after presenting findings.** Do not make any code changes. Ask the user which findings,
   if any, they want fixed before touching a single file — the same rule the existing
   `codex-result-handling` skill applies to `codex:codex-rescue` output applies here too, even
   though this path doesn't go through that subagent.
