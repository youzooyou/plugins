#!/usr/bin/env bash
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCHEMA="$SCRIPT_DIR/../schemas/review-verdict.schema.json"
DEFAULT_TIMEOUT_SECS=300

# judge_result: given a finished run's exit code and output files, decide
# ok/not-ok. Prints exactly one JSON line to stdout. Returns 0 if ok, 1 if not.
judge_result() {
  local exit_code="$1" eventlog="$2" outfile="$3"

  if [ "$exit_code" -ne 0 ]; then
    printf '{"ok":false,"reason":"nonzero_exit","detail":"codex exec exited %s"}\n' "$exit_code"
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
  out="$(judge_result 0 "$tmp/good.jsonl" "$tmp/good.json")"
  echo "$out" | jq -e '.ok == true' >/dev/null 2>&1 || { echo "FAIL: good case: $out"; fail=1; }

  # Case 2: nonzero exit
  out="$(judge_result 1 "$tmp/good.jsonl" "$tmp/good.json")"
  echo "$out" | jq -e '.reason == "nonzero_exit"' >/dev/null 2>&1 || { echo "FAIL: nonzero_exit case: $out"; fail=1; }

  # Case 3: missing turn.completed
  echo '{"type":"turn.started"}' > "$tmp/no_complete.jsonl"
  out="$(judge_result 0 "$tmp/no_complete.jsonl" "$tmp/good.json")"
  echo "$out" | jq -e '.reason == "missing_turn_completed"' >/dev/null 2>&1 || { echo "FAIL: missing_turn_completed case: $out"; fail=1; }

  # Case 4: empty output file
  : > "$tmp/empty.json"
  out="$(judge_result 0 "$tmp/good.jsonl" "$tmp/empty.json")"
  echo "$out" | jq -e '.reason == "empty_output"' >/dev/null 2>&1 || { echo "FAIL: empty_output case: $out"; fail=1; }

  # Case 5: invalid JSON
  echo 'not json' > "$tmp/bad.json"
  out="$(judge_result 0 "$tmp/good.jsonl" "$tmp/bad.json")"
  echo "$out" | jq -e '.reason == "invalid_json"' >/dev/null 2>&1 || { echo "FAIL: invalid_json case: $out"; fail=1; }

  # Case 6: valid JSON, wrong shape (Codex's own flagged risk)
  echo '{"verdict":"MAYBE","findings":"not-an-array"}' > "$tmp/wrong_shape.json"
  out="$(judge_result 0 "$tmp/good.jsonl" "$tmp/wrong_shape.json")"
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

CWD=""
SCOPE=""
SCOPE_VALUE=""
FOCUS=""
TIMEOUT_SECS="$DEFAULT_TIMEOUT_SECS"

while [ $# -gt 0 ]; do
  case "$1" in
    --cwd)
      [ $# -ge 2 ] || { printf '{"ok":false,"reason":"bad_args","detail":"--cwd requires a value"}\n'; exit 1; }
      CWD="$2"; shift 2 ;;
    --uncommitted)
      if [ -n "$SCOPE" ]; then
        printf '{"ok":false,"reason":"bad_args","detail":"only one of --uncommitted/--base/--commit allowed, already set to %s"}\n' "$SCOPE"
        exit 1
      fi
      SCOPE="uncommitted"; shift ;;
    --base)
      [ $# -ge 2 ] || { printf '{"ok":false,"reason":"bad_args","detail":"--base requires a value"}\n'; exit 1; }
      if [ -n "$SCOPE" ]; then
        printf '{"ok":false,"reason":"bad_args","detail":"only one of --uncommitted/--base/--commit allowed, already set to %s"}\n' "$SCOPE"
        exit 1
      fi
      SCOPE="base"; SCOPE_VALUE="$2"; shift 2 ;;
    --commit)
      [ $# -ge 2 ] || { printf '{"ok":false,"reason":"bad_args","detail":"--commit requires a value"}\n'; exit 1; }
      if [ -n "$SCOPE" ]; then
        printf '{"ok":false,"reason":"bad_args","detail":"only one of --uncommitted/--base/--commit allowed, already set to %s"}\n' "$SCOPE"
        exit 1
      fi
      SCOPE="commit"; SCOPE_VALUE="$2"; shift 2 ;;
    --focus)
      [ $# -ge 2 ] || { printf '{"ok":false,"reason":"bad_args","detail":"--focus requires a value"}\n'; exit 1; }
      FOCUS="$2"; shift 2 ;;
    --timeout)
      [ $# -ge 2 ] || { printf '{"ok":false,"reason":"bad_args","detail":"--timeout requires a value"}\n'; exit 1; }
      TIMEOUT_SECS="$2"; shift 2 ;;
    *)
      ESCAPED_ARG="$(printf '%s' "$1" | sed 's/"/\\"/g')"
      printf '{"ok":false,"reason":"bad_args","detail":"unknown argument: %s"}\n' "$ESCAPED_ARG"
      exit 1 ;;
  esac
done

if [ -z "$CWD" ] || [ -z "$SCOPE" ]; then
  printf '{"ok":false,"reason":"bad_args","detail":"require --cwd and exactly one of --uncommitted/--base/--commit"}\n'
  exit 1
fi

# Gather the diff ourselves. codex exec review does not honor --output-schema
# (see design doc's Revision section) -- so we never call the review
# subcommand; we build the diff and the JSON-shape instruction ourselves and
# send both to generic `codex exec`, which DOES follow an explicit in-prompt
# instruction (live-verified earlier in this project).
case "$SCOPE" in
  uncommitted) DIFF_TEXT="$(cd "$CWD" 2>/dev/null && git diff HEAD 2>&1)" ;;
  base)        DIFF_TEXT="$(cd "$CWD" 2>/dev/null && git diff "${SCOPE_VALUE}...HEAD" 2>&1)" ;;
  commit)      DIFF_TEXT="$(cd "$CWD" 2>/dev/null && git show "$SCOPE_VALUE" 2>&1)" ;;
esac
GIT_STATUS=$?

if [ "$GIT_STATUS" -ne 0 ]; then
  FIRST_LINE="$(printf '%s' "$DIFF_TEXT" | head -1 | sed 's/"/\\"/g')"
  printf '{"ok":false,"reason":"git_error","detail":"git command failed for scope %s: %s"}\n' "$SCOPE" "$FIRST_LINE"
  exit 1
fi

if [ -z "$DIFF_TEXT" ]; then
  printf '{"ok":true,"verdict":{"verdict":"CLEAN","findings":[]}}\n'
  exit 0
fi

PROMPT_FILE="$(mktemp)"
{
  echo "Review the following git diff for correctness bugs, security issues, and reuse/simplification opportunities."
  if [ -n "$FOCUS" ]; then
    echo "Additional focus: $FOCUS"
  fi
  echo ""
  echo "Respond with ONLY valid JSON matching this exact shape, no prose, no markdown code fences:"
  echo '{"verdict": "CLEAN or ISSUES", "findings": [{"file": "path", "line": optional integer, "severity": "optional string", "summary": "string", "evidence": "string"}], "summary": "optional string"}'
  echo ""
  echo "Diff:"
  echo "$DIFF_TEXT"
} > "$PROMPT_FILE"

EVENTLOG="$(mktemp)"
OUTFILE="$(mktemp)"

set -m
(
  cd "$CWD" || exit 127
  codex exec --ephemeral --sandbox read-only --skip-git-repo-check --json \
    --output-schema "$SCHEMA" --output-last-message "$OUTFILE" \
    < "$PROMPT_FILE" > "$EVENTLOG" 2>&1
) &
CODEX_PID=$!

DEADLINE=$((SECONDS + TIMEOUT_SECS))
TIMED_OUT=0
while kill -0 "$CODEX_PID" 2>/dev/null; do
  if [ "$SECONDS" -ge "$DEADLINE" ]; then
    TIMED_OUT=1
    # Negative PID kills the whole process group, not just the top PID --
    # `codex` is a Node wrapper that spawns the real review process (and an
    # MCP host) as children, so a single-PID kill leaves them orphaned and
    # still running a live API call. `set -m` above gives the backgrounded
    # job its own process group so this works.
    kill -TERM -"$CODEX_PID" 2>/dev/null
    sleep 2
    kill -KILL -"$CODEX_PID" 2>/dev/null
    break
  fi
  sleep 1
done
wait "$CODEX_PID" 2>/dev/null
EXIT_CODE=$?

rm -f "$PROMPT_FILE"

if [ "$TIMED_OUT" -eq 1 ]; then
  printf '{"ok":false,"reason":"timeout","detail":"codex exec exceeded %ss"}\n' "$TIMEOUT_SECS"
  rm -f "$EVENTLOG" "$OUTFILE"
  exit 1
fi

judge_result "$EXIT_CODE" "$EVENTLOG" "$OUTFILE"
RESULT=$?
rm -f "$EVENTLOG" "$OUTFILE"
exit $RESULT
