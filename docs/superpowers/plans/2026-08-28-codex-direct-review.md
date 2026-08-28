# Codex Direct Review Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace `/cc`'s Codex invocation (currently `Agent(codex:codex-rescue)` → the `openai-codex` plugin's shared app-server broker) with a new, independently-shareable `codex-direct-review` plugin that runs `codex exec review` as a one-shot, ephemeral process per call — eliminating the broker's silent-failure, premature-completion, and idle-stall failure modes.

**Architecture:** A new plugin in the `youzooyou/plugins` marketplace repo bundles a Bash wrapper (`run-codex-review.sh`) that invokes `codex exec review` with strict, hand-checked success criteria (exit code + `turn.completed` event + schema-valid output), a JSON Schema for the verdict shape, and a standalone `/codex-review` skill for direct use. `/cc` (a separate personal command, not part of this plugin) resolves the plugin's install path dynamically via `jq` against `~/.claude/plugins/installed_plugins.json` and calls the same wrapper directly via Bash — no subagent layer.

**Tech Stack:** Bash (wrapper script — no new language runtime), `jq` (already installed, used for all JSON parsing/validation — no new dependency), `codex` CLI 0.146.0+ (`codex exec review` subcommand), Claude Code plugin/marketplace conventions (`.claude-plugin/plugin.json`, `skills/<name>/SKILL.md`, `${CLAUDE_PLUGIN_ROOT}`).

**Spec:** `docs/2026-08-28-codex-direct-review-design.md` (this plan implements that design; read both — the spec has the full rationale and the live-verification evidence this plan builds on).

## Global Constraints

- No new external dependencies (no `ajv`, no `python-jsonschema`, no `timeout`/`gtimeout`) — use `jq` (already present) and portable Bash for everything, including the wall-clock timeout (macOS has no built-in `timeout`/`gtimeout`; implement via a background-PID poll loop).
- The wrapper script must **never print nothing** on failure — every failure path prints a `{"ok":false,"reason":"...","detail":"..."}` JSON object to stdout and exits non-zero.
- `--sandbox read-only` is used on every `codex exec review` invocation — this plugin never edits files.
- Default timeout: 300 seconds per review round (per the spec's Codex-recommended value).
- `main` branch of `youzooyou/plugins` is protected (PR required, 0 approvals needed — see repo settings). Every task's commit goes to a feature branch; merging via PR happens as its own explicit step, not silently bundled into a task.
- File paths below are all relative to the `youzooyou/plugins` repo root (`/Users/hmc7279235/Work/Develop/plugins`) unless given as an absolute `~/.claude/...` path.

---

### Task 1: Scaffold the `codex-direct-review` plugin skeleton and marketplace entry

**Files:**
- Create: `codex-direct-review/.claude-plugin/plugin.json`
- Modify: `.claude-plugin/marketplace.json`

**Interfaces:**
- Produces: the plugin name `codex-direct-review`, referenced by every later task and by `/cc`'s `jq` lookup as `codex-direct-review@youzooyou-plugins`.

- [ ] **Step 1: Create the plugin manifest**

Create `codex-direct-review/.claude-plugin/plugin.json`:

```json
{
  "name": "codex-direct-review",
  "version": "1.0.0",
  "description": "Run a Codex CLI review as a fresh, one-shot process (codex exec review) instead of a shared long-lived app-server session. Bundles a standalone /codex-review command.",
  "author": {
    "name": "youzooyou",
    "url": "https://github.com/youzooyou"
  }
}
```

No `hooks` field — this plugin has no hooks (see the `clear-prep` lesson in `mem:reference-claude-code-plugin-authoring`: only declare `hooks` for a non-standard path, and this plugin has no `hooks/hooks.json` at all).

- [ ] **Step 2: Register it in the marketplace manifest**

Read `.claude-plugin/marketplace.json` first (it currently lists only `clear-prep`). Add a second entry to the `"plugins"` array so the file reads:

```json
{
  "$schema": "https://anthropic.com/claude-code/marketplace.schema.json",
  "name": "youzooyou-plugins",
  "description": "Personal Claude Code plugins.",
  "owner": {
    "name": "youzooyou",
    "url": "https://github.com/youzooyou"
  },
  "plugins": [
    {
      "name": "clear-prep",
      "description": "Back up durable memory and in-progress session state before /clear, then auto-restore the handoff note right after.",
      "source": "./clear-prep",
      "category": "productivity"
    },
    {
      "name": "codex-direct-review",
      "description": "Run a Codex CLI review as a fresh, one-shot process (codex exec review) — no shared broker, no silent failures.",
      "source": "./codex-direct-review",
      "category": "productivity"
    }
  ]
}
```

- [ ] **Step 3: Create the empty directory skeleton**

```bash
mkdir -p /Users/hmc7279235/Work/Develop/plugins/codex-direct-review/scripts
mkdir -p /Users/hmc7279235/Work/Develop/plugins/codex-direct-review/schemas
mkdir -p /Users/hmc7279235/Work/Develop/plugins/codex-direct-review/skills/codex-review
```

- [ ] **Step 4: Validate JSON syntax**

Run:
```bash
cd /Users/hmc7279235/Work/Develop/plugins
jq empty codex-direct-review/.claude-plugin/plugin.json && echo "plugin.json OK"
jq empty .claude-plugin/marketplace.json && echo "marketplace.json OK"
jq '.plugins | length' .claude-plugin/marketplace.json
```
Expected: both print `OK`, and the length query prints `2`.

- [ ] **Step 5: Commit**

```bash
cd /Users/hmc7279235/Work/Develop/plugins
git checkout -b feat/codex-direct-review-scaffold
git add codex-direct-review/.claude-plugin/plugin.json .claude-plugin/marketplace.json
git commit -m "Scaffold codex-direct-review plugin"
```

(Do not push/PR yet — later tasks add to this same branch. Pushing and merging happens once, after Task 5.)

---

### Task 2: Write the verdict schema and the wrapper script's judging logic, with a dependency-free selftest

**Files:**
- Create: `codex-direct-review/schemas/review-verdict.schema.json`
- Create: `codex-direct-review/scripts/run-codex-review.sh`

**Interfaces:**
- Produces: `judge_result(exit_code, eventlog_path, outfile_path, schema_path)` — a Bash function inside `run-codex-review.sh` that prints one JSON line to stdout (`{"ok":true,"verdict":{...}}` or `{"ok":false,"reason":"...","detail":"..."}`) and returns 0/1 accordingly, given an *already-finished* run's exit code and output files. `judge_result` itself only ever sets `reason` to one of: `nonzero_exit`, `missing_turn_completed`, `empty_output`, `invalid_json`, `schema_mismatch` — it has no concept of wall-clock time. `timeout` (Task 3) and `bad_args` (Task 3) are reasons the *wrapper script* prints directly, before/without calling `judge_result` at all, since a timed-out or never-started run has no finished exit code or output files to judge.
- Consumes: nothing from earlier tasks (this is the first real logic).

- [ ] **Step 1: Write the schema file**

Create `codex-direct-review/schemas/review-verdict.schema.json`:

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

- [ ] **Step 2: Write the script with `judge_result` and a `--selftest` mode (no real `codex` invocation yet)**

Create `codex-direct-review/scripts/run-codex-review.sh`:

```bash
#!/usr/bin/env bash
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCHEMA="$SCRIPT_DIR/../schemas/review-verdict.schema.json"
DEFAULT_TIMEOUT_SECS=300

# judge_result: given a finished run's exit code and output files, decide
# ok/not-ok. Prints exactly one JSON line to stdout. Returns 0 if ok, 1 if not.
judge_result() {
  local exit_code="$1" eventlog="$2" outfile="$3" schema="$4"

  if [ "$exit_code" -ne 0 ]; then
    printf '{"ok":false,"reason":"nonzero_exit","detail":"codex exec review exited %s"}\n' "$exit_code"
    return 1
  fi

  if ! grep -q '"type":"turn.completed"' "$eventlog" 2>/dev/null; then
    printf '{"ok":false,"reason":"missing_turn_completed","detail":"no turn.completed event in event log"}\n'
    return 1
  fi

  if [ ! -s "$outfile" ]; then
    printf '{"ok":false,"reason":"empty_output","detail":"output-last-message file is empty or missing"}\n'
    return 1
  fi

  if ! jq -e . "$outfile" >/dev/null 2>&1; then
    printf '{"ok":false,"reason":"invalid_json","detail":"output is not valid JSON"}\n'
    return 1
  fi

  if ! jq -e '
        (.verdict == "CLEAN" or .verdict == "ISSUES") and
        (.findings | type == "array") and
        (.findings | all(has("file") and has("summary") and has("evidence")))
      ' "$outfile" >/dev/null 2>&1; then
    printf '{"ok":false,"reason":"schema_mismatch","detail":"output JSON does not match review-verdict schema"}\n'
    return 1
  fi

  printf '{"ok":true,"verdict":%s}\n' "$(cat "$outfile")"
  return 0
}

run_selftest() {
  local tmp
  tmp="$(mktemp -d)"
  local fail=0

  # Case 1: good result -> ok:true
  echo '{"type":"turn.completed","usage":{}}' > "$tmp/good.jsonl"
  echo '{"verdict":"CLEAN","findings":[]}' > "$tmp/good.json"
  out="$(judge_result 0 "$tmp/good.jsonl" "$tmp/good.json" "$SCHEMA")"
  echo "$out" | jq -e '.ok == true' >/dev/null 2>&1 || { echo "FAIL: good case: $out"; fail=1; }

  # Case 2: nonzero exit
  out="$(judge_result 1 "$tmp/good.jsonl" "$tmp/good.json" "$SCHEMA")"
  echo "$out" | jq -e '.reason == "nonzero_exit"' >/dev/null 2>&1 || { echo "FAIL: nonzero_exit case: $out"; fail=1; }

  # Case 3: missing turn.completed
  echo '{"type":"turn.started"}' > "$tmp/no_complete.jsonl"
  out="$(judge_result 0 "$tmp/no_complete.jsonl" "$tmp/good.json" "$SCHEMA")"
  echo "$out" | jq -e '.reason == "missing_turn_completed"' >/dev/null 2>&1 || { echo "FAIL: missing_turn_completed case: $out"; fail=1; }

  # Case 4: empty output file
  : > "$tmp/empty.json"
  out="$(judge_result 0 "$tmp/good.jsonl" "$tmp/empty.json" "$SCHEMA")"
  echo "$out" | jq -e '.reason == "empty_output"' >/dev/null 2>&1 || { echo "FAIL: empty_output case: $out"; fail=1; }

  # Case 5: invalid JSON
  echo 'not json' > "$tmp/bad.json"
  out="$(judge_result 0 "$tmp/good.jsonl" "$tmp/bad.json" "$SCHEMA")"
  echo "$out" | jq -e '.reason == "invalid_json"' >/dev/null 2>&1 || { echo "FAIL: invalid_json case: $out"; fail=1; }

  # Case 6: valid JSON, wrong shape (Codex's own flagged risk)
  echo '{"verdict":"MAYBE","findings":"not-an-array"}' > "$tmp/wrong_shape.json"
  out="$(judge_result 0 "$tmp/good.jsonl" "$tmp/wrong_shape.json" "$SCHEMA")"
  echo "$out" | jq -e '.reason == "schema_mismatch"' >/dev/null 2>&1 || { echo "FAIL: schema_mismatch case: $out"; fail=1; }

  rm -rf "$tmp"

  if [ "$fail" -eq 0 ]; then
    echo "run-codex-review.sh: selftest OK"
    return 0
  else
    echo "run-codex-review.sh: selftest FAILED"
    return 1
  fi
}

if [ "${1:-}" = "--selftest" ]; then
  run_selftest
  exit $?
fi

echo "run-codex-review.sh: real invocation not implemented yet (Task 3)" >&2
exit 1
```

- [ ] **Step 3: Make it executable and run the selftest**

```bash
chmod +x /Users/hmc7279235/Work/Develop/plugins/codex-direct-review/scripts/run-codex-review.sh
/Users/hmc7279235/Work/Develop/plugins/codex-direct-review/scripts/run-codex-review.sh --selftest
```
Expected: `run-codex-review.sh: selftest OK` and exit code 0. If any `FAIL:` lines print, fix `judge_result` (not the test) until all six cases pass — the six cases encode the exact failure modes from the spec's "Problem" section plus Codex's own flagged "valid JSON, wrong shape" risk, so don't loosen them.

- [ ] **Step 4: Commit**

```bash
cd /Users/hmc7279235/Work/Develop/plugins
git add codex-direct-review/schemas/review-verdict.schema.json codex-direct-review/scripts/run-codex-review.sh
git commit -m "Add review-verdict schema and judge_result logic with selftest"
```

---

### Task 3: Implement the real `codex exec review` invocation with timeout enforcement

**Files:**
- Modify: `codex-direct-review/scripts/run-codex-review.sh`

**Interfaces:**
- Consumes: `judge_result` from Task 2 (unchanged signature).
- Produces: the script's real CLI surface: `run-codex-review.sh --cwd <dir> (--uncommitted | --base <branch> | --commit <sha>) [--focus <text>] [--timeout <seconds>]`.

- [ ] **Step 1: Replace the placeholder "not implemented yet" block with argument parsing and the real run**

In `codex-direct-review/scripts/run-codex-review.sh`, replace this block:
```bash
if [ "${1:-}" = "--selftest" ]; then
  run_selftest
  exit $?
fi

echo "run-codex-review.sh: real invocation not implemented yet (Task 3)" >&2
exit 1
```
with:
```bash
if [ "${1:-}" = "--selftest" ]; then
  run_selftest
  exit $?
fi

CWD=""
SCOPE_FLAGS=""
FOCUS=""
TIMEOUT_SECS="$DEFAULT_TIMEOUT_SECS"

while [ $# -gt 0 ]; do
  case "$1" in
    --cwd) CWD="$2"; shift 2 ;;
    --uncommitted) SCOPE_FLAGS="--uncommitted"; shift ;;
    --base) SCOPE_FLAGS="--base $2"; shift 2 ;;
    --commit) SCOPE_FLAGS="--commit $2"; shift 2 ;;
    --focus) FOCUS="$2"; shift 2 ;;
    --timeout) TIMEOUT_SECS="$2"; shift 2 ;;
    *) printf '{"ok":false,"reason":"bad_args","detail":"unknown argument: %s"}\n' "$1"; exit 1 ;;
  esac
done

if [ -z "$CWD" ] || [ -z "$SCOPE_FLAGS" ]; then
  printf '{"ok":false,"reason":"bad_args","detail":"require --cwd and exactly one of --uncommitted/--base/--commit"}\n'
  exit 1
fi

EVENTLOG="$(mktemp)"
OUTFILE="$(mktemp)"

(
  cd "$CWD" || exit 127
  # shellcheck disable=SC2086
  codex exec review --ephemeral --sandbox read-only --skip-git-repo-check --json \
    --output-schema "$SCHEMA" --output-last-message "$OUTFILE" \
    $SCOPE_FLAGS "$FOCUS" < /dev/null > "$EVENTLOG" 2>&1
) &
CODEX_PID=$!

DEADLINE=$((SECONDS + TIMEOUT_SECS))
TIMED_OUT=0
while kill -0 "$CODEX_PID" 2>/dev/null; do
  if [ "$SECONDS" -ge "$DEADLINE" ]; then
    TIMED_OUT=1
    kill -TERM "$CODEX_PID" 2>/dev/null
    sleep 2
    kill -KILL "$CODEX_PID" 2>/dev/null
    break
  fi
  sleep 1
done
wait "$CODEX_PID" 2>/dev/null
EXIT_CODE=$?

if [ "$TIMED_OUT" -eq 1 ]; then
  printf '{"ok":false,"reason":"timeout","detail":"codex exec review exceeded %ss"}\n' "$TIMEOUT_SECS"
  rm -f "$EVENTLOG" "$OUTFILE"
  exit 1
fi

judge_result "$EXIT_CODE" "$EVENTLOG" "$OUTFILE" "$SCHEMA"
RESULT=$?
rm -f "$EVENTLOG" "$OUTFILE"
exit $RESULT
```

- [ ] **Step 2: Re-run the selftest to make sure argument parsing didn't break it**

```bash
/Users/hmc7279235/Work/Develop/plugins/codex-direct-review/scripts/run-codex-review.sh --selftest
```
Expected: `run-codex-review.sh: selftest OK` (the `--selftest` branch still returns before touching any of the new argument-parsing code).

- [ ] **Step 3: Live smoke test against a real `codex exec review` call**

This costs a real Codex API call — run it once to prove the whole pipeline works end-to-end, not as part of the automated selftest.

```bash
cd /Users/hmc7279235/Work/Develop/plugins
/Users/hmc7279235/Work/Develop/plugins/codex-direct-review/scripts/run-codex-review.sh \
  --cwd /Users/hmc7279235/Work/Develop/plugins \
  --uncommitted \
  --focus "This is a smoke test. If there are no staged/unstaged changes, just return verdict CLEAN with an empty findings array." \
  --timeout 120
```
Expected: exit code 0, stdout is one line of JSON: `{"ok":true,"verdict":{"verdict":"CLEAN","findings":[]}}` (or `ISSUES` with real findings, if the working tree happens to have uncommitted changes at test time — either is a pass, as long as `"ok":true` and the shape matches). If it prints `"ok":false`, read the `reason`/`detail` field — it tells you exactly which of the six failure modes fired; fix the underlying cause (not the check) before moving on.

- [ ] **Step 4: Confirm no lingering process**

```bash
ps aux | grep -i codex | grep -v grep
```
Expected: no output (matches the same check done manually earlier in this project — a fresh, ephemeral run leaves nothing behind).

- [ ] **Step 5: Commit**

```bash
cd /Users/hmc7279235/Work/Develop/plugins
git add codex-direct-review/scripts/run-codex-review.sh
git commit -m "Implement real codex exec review invocation with wall-clock timeout"
```

---

### Task 4: Write the standalone `/codex-review` command

**Files:**
- Create: `codex-direct-review/skills/codex-review/SKILL.md`

**Interfaces:**
- Consumes: `codex-direct-review/scripts/run-codex-review.sh`'s CLI surface from Task 3, referenced as `"${CLAUDE_PLUGIN_ROOT}/scripts/run-codex-review.sh"`.

- [ ] **Step 1: Write the skill**

Create `codex-direct-review/skills/codex-review/SKILL.md`:

```markdown
---
name: codex-review
description: Use when you want a single, one-shot Codex CLI review run directly — no multi-round cross-verification, no dependency on the codex:codex-rescue subagent. Reviews uncommitted changes, a branch diff, or a specific commit.
---

# Codex Review (direct)

## Overview

Runs exactly one Codex review as a fresh, ephemeral `codex exec review` process via this plugin's
`run-codex-review.sh`, and presents the result. Unlike `/cc`, there is no round loop or
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
```

- [ ] **Step 2: Validate the frontmatter parses**

```bash
cd /Users/hmc7279235/Work/Develop/plugins
head -4 codex-direct-review/skills/codex-review/SKILL.md
```
Expected: the three-dash-delimited YAML block with `name: codex-review` and a `description:` line — confirms no stray characters broke the frontmatter block before it reaches the closing `---`.

- [ ] **Step 3: Commit**

```bash
git add codex-direct-review/skills/codex-review/SKILL.md
git commit -m "Add standalone /codex-review command"
```

---

### Task 5: Publish the plugin and verify it installs cleanly

**Files:** none (this task is push/PR/install verification, no new files)

- [ ] **Step 1: Push the branch and open a PR**

```bash
cd /Users/hmc7279235/Work/Develop/plugins
git push -u origin feat/codex-direct-review-scaffold
```
Open the PR at the URL git prints, then merge it on GitHub (repo requires a PR — direct push to `main` is blocked by the branch protection ruleset set up earlier in this project).

- [ ] **Step 2: Sync local `main` after merge**

```bash
cd /Users/hmc7279235/Work/Develop/plugins
git checkout main
git pull origin main
git log --oneline -5
```
Expected: the merge commit for `feat/codex-direct-review-scaffold` is at the top.

- [ ] **Step 3: Refresh the marketplace and install the new plugin**

Run in a live Claude Code session (these are interactive slash commands, not Bash):
```
/plugin marketplace update
/plugin install codex-direct-review@youzooyou-plugins
```
Expected: `✓ Installed codex-direct-review.` with **no** "couldn't be loaded" error (this plugin has
no `hooks` field at all, so the `clear-prep`-style "duplicate hooks file" failure cannot recur —
but confirm it anyway).

- [ ] **Step 4: Confirm via `/plugin`**

```
/plugin
```
Find `codex-direct-review @ youzooyou-plugins` in the list, confirm `Status: Enabled`, no errors,
and `Skills: codex-review` listed under "Installed components".

- [ ] **Step 5: Confirm the `jq` lookup Task 7 will depend on actually resolves**

```bash
jq -r '.plugins["codex-direct-review@youzooyou-plugins"][] | select(.scope=="user") | .installPath' \
  ~/.claude/plugins/installed_plugins.json
```
Expected: prints a real path like
`/Users/hmc7279235/.claude/plugins/cache/youzooyou-plugins/codex-direct-review/1.0.0`. If empty,
the plugin isn't actually installed at `user` scope — re-run Step 3.

- [ ] **Step 6: Live end-to-end test of `/codex-review`**

In a live Claude Code session, in any git repo (e.g. `~/Work/Develop/plugins` itself), run:
```
/codex-review
```
When asked for scope, choose uncommitted changes. Expected: a real Codex review runs, and you see
either "no findings" or a findings list — not a silent failure, not raw JSON dumped at you
unexplained.

---

### Task 6: Rewrite `/cc`'s Phase 2 to call the new wrapper instead of `codex:codex-rescue`

**Files:**
- Modify: `~/.claude/commands/cc/SKILL.md`

**Interfaces:**
- Consumes: `codex-direct-review@youzooyou-plugins`'s installed `run-codex-review.sh` (Task 3's CLI
  surface), located via the `jq` lookup from Task 5 Step 5.

**Note:** `~/.claude/commands/cc/` is not part of the `youzooyou/plugins` git repo — it's a local,
untracked personal command file. This task has no git commit step of its own; there's nothing to
version here (unless the user has separately git-tracked `~/.claude`, in which case follow whatever
that repo's normal commit flow is).

- [ ] **Step 1: Read the current `/cc` SKILL.md and find the Codex invocation contract section**

```bash
grep -n "Codex invocation contract" -A 20 ~/.claude/commands/cc/SKILL.md
```
This locates the block starting with `### Codex invocation contract` (covers the `Agent` tool call,
`codex:codex-rescue`, `--fresh`/`--resume`/`--wait`, and the "Never pass `--model`" note) — the
entire block from that heading down to the next `---` or `##` heading is what gets replaced.

- [ ] **Step 2: Replace the invocation contract**

Replace that entire section with:

```markdown
### Codex invocation: direct `codex exec review`, no subagent

Every round, resolve the `codex-direct-review` plugin's current install path and call its wrapper
directly via Bash — no `Agent` tool call, no `codex:codex-rescue`, no `--resume`/`--fresh`
distinction (each call is already a fresh, ephemeral process, so there is nothing to resume).

```bash
INSTALL_PATH=$(jq -r '.plugins["codex-direct-review@youzooyou-plugins"][] | select(.scope=="user") | .installPath' ~/.claude/plugins/installed_plugins.json)
if [ -z "$INSTALL_PATH" ]; then
  echo "codex-direct-review@youzooyou-plugins is not installed — run /plugin install codex-direct-review@youzooyou-plugins first" >&2
  exit 1
fi
"$INSTALL_PATH/scripts/run-codex-review.sh" --cwd "<repo root>" --uncommitted --focus "<round's review prompt, including prior-round recap for round > 1>"
```

If `$INSTALL_PATH` is empty, **stop Phase 2 and tell the user to install the plugin** — never fall
back to `codex:codex-rescue` silently.

Parse the wrapper's single-line JSON stdout:
- `"ok":false` → this round's Codex call failed outright (see `reason`/`detail`). This is a failed
  round, not a clean round — retry once per the existing "Empty / failed review ≠ CLEAN" rule below,
  then report `⚠️ COULD NOT VERIFY` if it fails again.
- `"ok":true` → `verdict.verdict` and `verdict.findings` are this round's Codex output. Proceed to
  the existing re-verification step (Claude checks each finding against evidence) unchanged.
```

- [ ] **Step 3: Remove now-stale references elsewhere in the file**

```bash
grep -n "codex:codex-rescue\|codex-cli-runtime\|--resume-last\|Never pass \`--model\`" ~/.claude/commands/cc/SKILL.md
```
For each remaining match outside the section already replaced in Step 2 (for example, a mention in
the "Known Failure Patterns" section referring to the old subagent path), update the wording to
describe the new direct-call path instead of deleting the surrounding lesson — the underlying
lessons (idle stalls, `node_modules` context exhaustion, empty-grep-isn't-counter-evidence) are
still real and still apply; only the "how Codex gets invoked" description needs to change.

- [ ] **Step 4: Manual verification — run `/cc` end-to-end**

In a live Claude Code session, inside a git repo with at least one real change (e.g. make a trivial
edit in `~/Work/Develop/plugins`), run:
```
/cc
```
Expected: the round narration shows the new direct-call path being used (no "Agent tool" call to
`codex:codex-rescue` in the transcript), and Phase 3's final report renders normally with a real
`✅ CLEAN` / `⚠️ NOT CONVERGED` / `⚠️ COULD NOT VERIFY` verdict — confirming the swap didn't break
the surrounding round/convergence logic.

---

## Self-Review Notes (for whoever executes this plan)

- **Spec coverage:** Task 1 covers "Final repo layout"; Task 2+3 cover Component 1 (wrapper) and
  Component 2 (schema); Task 4 covers Component 4 (standalone command); Task 6 covers Component 3
  (`/cc` Phase 2 rewrite). Task 5 (publish + install) isn't a named spec component but is required
  for Task 6 to have anything to call.
- **No placeholders:** every step above has literal, complete code — none of it is descriptive
  prose standing in for real content.
- **Type/name consistency:** `judge_result`'s five failure `reason` values (`nonzero_exit`,
  `missing_turn_completed`, `empty_output`, `invalid_json`, `schema_mismatch`) plus the two the
  wrapper prints directly without calling `judge_result` (`timeout`, `bad_args`) are used
  identically in the selftest (Task 2), the real invocation (Task 3), and `/cc`'s parsing logic
  (Task 6) — don't rename one without updating the other two.
