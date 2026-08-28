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
FOCUS_FILE="$(mktemp)"
printf '%s' "$FOCUS" > "$FOCUS_FILE"

# Job control (set -m) puts the backgrounded job below in its own process
# group, so `kill -TERM -"$CODEX_PID"` (negative PID = kill the whole group)
# reaches every descendant. Without this, `codex` is a node wrapper that
# spawns the actual review binary (and it, in turn, an MCP tool-mode host) as
# child processes rather than exec'ing into them, so killing only the direct
# PID leaves the real work (and the API call driving it) running orphaned.
set -m

(
  cd "$CWD" || exit 127
  # shellcheck disable=SC2086
  # --sandbox is a top-level `codex exec` flag, not a `review` subcommand flag;
  # it must precede the `review` subcommand or codex exits 2 (clap parse error).
  # FOCUS is fed via stdin redirection (not a positional PROMPT arg, and not a
  # pipe): codex's clap parser rejects any positional PROMPT (even "") when a
  # scope flag (--uncommitted/--base/--commit) is present, and a `|` pipe here
  # would spawn a second process outside this job's group.
  codex exec --sandbox read-only review --ephemeral --skip-git-repo-check --json \
    --output-schema "$SCHEMA" --output-last-message "$OUTFILE" \
    $SCOPE_FLAGS < "$FOCUS_FILE" > "$EVENTLOG" 2>&1
) &
CODEX_PID=$!

DEADLINE=$((SECONDS + TIMEOUT_SECS))
TIMED_OUT=0
while kill -0 "$CODEX_PID" 2>/dev/null; do
  if [ "$SECONDS" -ge "$DEADLINE" ]; then
    TIMED_OUT=1
    kill -TERM -"$CODEX_PID" 2>/dev/null
    sleep 2
    kill -KILL -"$CODEX_PID" 2>/dev/null
    break
  fi
  sleep 1
done
wait "$CODEX_PID" 2>/dev/null
EXIT_CODE=$?

if [ "$TIMED_OUT" -eq 1 ]; then
  printf '{"ok":false,"reason":"timeout","detail":"codex exec review exceeded %ss"}\n' "$TIMEOUT_SECS"
  rm -f "$EVENTLOG" "$OUTFILE" "$FOCUS_FILE"
  exit 1
fi

judge_result "$EXIT_CODE" "$EVENTLOG" "$OUTFILE"
RESULT=$?
rm -f "$EVENTLOG" "$OUTFILE" "$FOCUS_FILE"
exit $RESULT
