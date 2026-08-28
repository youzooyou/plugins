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

echo "run-codex-review.sh: real invocation not implemented yet (Task 3)" >&2
exit 1
