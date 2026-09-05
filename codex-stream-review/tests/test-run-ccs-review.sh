#!/usr/bin/env bash
# Regression fixtures for run-ccs-review.sh -- covers exactly the bug
# classes that have already shipped once in this plugin's own history
# (a bypassable --focus gate, a bad --resume contract) plus the
# git-environment/config isolation gap fixed alongside this suite, PLUS
# (see the "post-dispatch reason fixtures" section near the bottom) the 7
# `reason` values that can only occur AFTER a `codex exec` subprocess has
# actually started (no_thread_started, timeout, nonzero_exit,
# missing_task_complete, no_final_answer, invalid_json, schema_mismatch --
# NOT `interrupted`, which can fire at any point in the wrapper's own
# execution, including before a subprocess is ever launched).
# The first set of fixtures fails or short-circuits before the wrapper
# would ever dispatch to Codex; the post-dispatch set substitutes
# tests/fixtures/fake-codex for the real `codex` binary (via a PATH
# override) so the wrapper genuinely spawns and observes a subprocess
# without ever reaching a real Codex backend. This PATH override is
# installed here, at the very top of the file, before ANY fixture below
# runs -- including the pre-existing --cleanup fixtures further down,
# which call the wrapper's own `--cleanup` mode and therefore
# `codex delete --force` (scripts/run-ccs-review.sh:232) via a bare
# `codex` lookup. An earlier revision of this file left that PATH
# override installed only inside the post-dispatch section, so those
# --cleanup fixtures resolved whatever real `codex` binary happened to be
# on $PATH -- on a machine with an authenticated Codex CLI, that silently
# made a real network call every time this suite ran, contradicting this
# very comment's own "no API calls" claim. Installing the override this
# early, for the whole file, closes that gap: no line below can ever
# reach a real `codex` binary.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WRAPPER="$SCRIPT_DIR/../scripts/run-ccs-review.sh"
LIB_GIT_SAFE="$SCRIPT_DIR/../scripts/lib/git-safe.sh"
FAKE_CODEX="$SCRIPT_DIR/fixtures/fake-codex"
FAKE_BIN_DIR="$(mktemp -d)"
ln -s "$FAKE_CODEX" "$FAKE_BIN_DIR/codex" || { echo "SETUP FAILED: linking fake codex" >&2; exit 1; }
PATH="$FAKE_BIN_DIR:$PATH"

FAILURES=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; FAILURES=$((FAILURES + 1)); }
must() { "$@" || { echo "SETUP FAILED: $*" >&2; exit 1; }; }

# --- wrapper contract regressions (arg parsing, no git/codex involved) ---

OUT="$("$WRAPPER" --cwd /tmp --uncommitted --focus '' 2>&1)"
if printf '%s' "$OUT" | grep -q '"reason":"bad_args"' && printf '%s' "$OUT" | grep -q 'require --focus'; then
  pass "empty --focus is rejected"
else
  fail "empty --focus should be rejected with bad_args, got: $OUT"
fi

OUT="$("$WRAPPER" --resume some-thread-id --focus 'x' 2>&1)"
if printf '%s' "$OUT" | grep -q '"reason":"bad_args"'; then
  pass "--resume without --cwd is rejected"
else
  fail "--resume without --cwd should be rejected with bad_args, got: $OUT"
fi

OUT1="$("$WRAPPER" --cleanup definitely-not-a-real-thread-id 2>&1)"
OUT2="$("$WRAPPER" --cleanup definitely-not-a-real-thread-id 2>&1)"
if printf '%s' "$OUT1" | grep -q '"ok":false' && printf '%s' "$OUT2" | grep -q '"ok":false'; then
  pass "--cleanup on the same (nonexistent) threadId fails cleanly twice, no hang"
else
  fail "--cleanup idempotency check failed: [$OUT1] / [$OUT2]"
fi

# --- git isolation fixtures -- exercise git_safe() directly, no codex exec ---

TMP_REPO="$(mktemp -d)"
must git -C "$TMP_REPO" init -q
must git -C "$TMP_REPO" -c user.email=test@example.com -c user.name=test commit --allow-empty -q -m init
echo "content" > "$TMP_REPO/file.txt" || { echo "SETUP FAILED: writing file.txt (content)" >&2; exit 1; }
must git -C "$TMP_REPO" add file.txt
must git -C "$TMP_REPO" -c user.email=test@example.com -c user.name=test commit -q -m "add file"
echo "changed" > "$TMP_REPO/file.txt" || { echo "SETUP FAILED: writing file.txt (changed)" >&2; exit 1; }

DECOY_REPO="$(mktemp -d)"
must git -C "$DECOY_REPO" init -q

CWD="$TMP_REPO"
SAFE_GIT_HOME="$(mktemp -d)"
# shellcheck source=../scripts/lib/git-safe.sh
source "$LIB_GIT_SAFE"

# (a) hostile GIT_DIR/GIT_WORK_TREE/GIT_CONFIG_* must not redirect git_safe
# to the decoy repo, or change how git interprets the target repo.
ACTUAL="$(GIT_DIR="$DECOY_REPO/.git" GIT_WORK_TREE="$DECOY_REPO" \
  GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.bare GIT_CONFIG_VALUE_0=true \
  git_safe rev-parse --show-toplevel 2>/dev/null)"
GIT_SAFE_STATUS=$?
ACTUAL_RESOLVED="$(cd "$ACTUAL" 2>/dev/null && pwd -P)"
EXPECTED_RESOLVED="$(cd "$TMP_REPO" && pwd -P)"
if [ "$GIT_SAFE_STATUS" -eq 0 ] && [ -n "$ACTUAL_RESOLVED" ] && [ "$ACTUAL_RESOLVED" = "$EXPECTED_RESOLVED" ]; then
  pass "git_safe ignores hostile GIT_DIR/GIT_WORK_TREE/GIT_CONFIG_* and resolves the real target repo"
else
  fail "git_safe should resolve to $TMP_REPO regardless of hostile env, got: $ACTUAL (exit $GIT_SAFE_STATUS)"
fi

# (b) a hostile PATH set AFTER GIT_BIN was already resolved must not divert
# execution to a decoy `git` placed earlier on it.
DECOY_BIN_DIR="$(mktemp -d)"
MARKER_FILE="$(mktemp -u)"
cat > "$DECOY_BIN_DIR/git" <<EOF || { echo "SETUP FAILED: writing decoy git script" >&2; exit 1; }
#!/bin/sh
touch "$MARKER_FILE"
exit 1
EOF
must chmod +x "$DECOY_BIN_DIR/git"
PATH="$DECOY_BIN_DIR:$PATH" git_safe diff --no-ext-diff --no-textconv >/dev/null 2>&1
GIT_SAFE_STATUS=$?
if [ "$GIT_SAFE_STATUS" -eq 0 ] && [ ! -e "$MARKER_FILE" ]; then
  pass "git_safe ignores a hostile PATH decoy git executable"
else
  fail "git_safe executed a decoy git binary from a hostile PATH, or failed outright (exit $GIT_SAFE_STATUS)"
  rm -f "$MARKER_FILE"
fi
rm -rf "$DECOY_BIN_DIR"

# (c) a repo-local core.fsmonitor hook must never fire during a real diff --
# the one thing env-var sanitization alone cannot reach, since it lives in
# the target repo's own tracked .git/config.
FSMON_MARKER="$(mktemp -u)"
must git -C "$TMP_REPO" config core.fsmonitor "touch $FSMON_MARKER; true"
git_safe diff --no-ext-diff --no-textconv >/dev/null 2>&1
GIT_SAFE_STATUS=$?
if [ "$GIT_SAFE_STATUS" -eq 0 ] && [ ! -e "$FSMON_MARKER" ]; then
  pass "git_safe disables a repo-local core.fsmonitor hook"
else
  fail "git_safe let a repo-local core.fsmonitor hook execute, or failed outright (exit $GIT_SAFE_STATUS)"
  rm -f "$FSMON_MARKER"
fi
must git -C "$TMP_REPO" config --unset core.fsmonitor

# (d) collect_untracked_files.py's OWN git subprocess (the actual vulnerable
# path Issue 2 fixed) must also resist hostile core.fsmonitor config plus
# GIT_CONFIG_* env-var injection -- the 3 fixtures above only exercise
# git_safe() directly, never this separate subprocess the collector runs,
# invoked here the same way run-ccs-review.sh now invokes it post-fix.
COLLECT_PY="$SCRIPT_DIR/../scripts/collect_untracked_files.py"
COLLECT_FSMON_MARKER="$(mktemp -u)"
must git -C "$TMP_REPO" config core.fsmonitor "touch $COLLECT_FSMON_MARKER; true"
COLLECT_COVERAGE_OUT="$(mktemp)"
GIT_SAFE_BIN="$GIT_BIN" GIT_SAFE_HOME="$SAFE_GIT_HOME" \
  GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.fsmonitor GIT_CONFIG_VALUE_0="touch $COLLECT_FSMON_MARKER; true" \
  python3 "$COLLECT_PY" "$TMP_REPO" --deadline-secs 5 --max-bytes 65536 --coverage-out "$COLLECT_COVERAGE_OUT" \
  >/dev/null 2>&1
COLLECT_STATUS=$?
if [ "$COLLECT_STATUS" -eq 0 ] && [ ! -e "$COLLECT_FSMON_MARKER" ]; then
  pass "collect_untracked_files.py's own git subprocess ignores hostile core.fsmonitor + GIT_CONFIG_* injection"
else
  fail "collect_untracked_files.py should exit 0 without firing the fsmonitor hook (exit $COLLECT_STATUS, marker exists: $([ -e "$COLLECT_FSMON_MARKER" ] && echo yes || echo no))"
fi
must git -C "$TMP_REPO" config --unset core.fsmonitor
rm -f "$COLLECT_FSMON_MARKER" "$COLLECT_COVERAGE_OUT"

rm -rf "$TMP_REPO" "$DECOY_REPO" "$SAFE_GIT_HOME"

# --- post-dispatch reason fixtures (fake codex, no real API calls) ---
# tests/fixtures/fake-codex stands in for the real `codex` binary -- wired
# into $PATH once, for the whole file, at the top -- so run-ccs-review.sh
# genuinely spawns and observes a subprocess, exercising the 7 `reason`
# values that can only be produced after that subprocess has actually
# started. Only $FAKE_HOME (an isolated $HOME, so this suite never touches
# the real Codex CLI's own state) is specific to this section.

FAKE_HOME="$(mktemp -d)"

PD_REPO="$(mktemp -d)"
must git -C "$PD_REPO" init -q
must git -C "$PD_REPO" -c user.email=test@example.com -c user.name=test commit --allow-empty -q -m init
echo "line" > "$PD_REPO/f.txt" || { echo "SETUP FAILED: writing PD_REPO/f.txt" >&2; exit 1; }

# pd_new_tid -> a fresh unique id for a --resume fixture to pass as its
# threadId. Doesn't need to look like a real Codex thread id, or correspond
# to anything the wrapper or fake-codex actually look up (the wrapper no
# longer preflight-checks --resume against anything) -- just unique text.
pd_new_tid() {
  python3 -c 'import uuid; print(uuid.uuid4())' 2>/dev/null || echo "pd-$$-${RANDOM}"
}

# pd_run fresh [ARGS...]              -- fresh dispatch against $PD_REPO
# pd_run resume THREAD_ID [ARGS...]   -- resume dispatch against THREAD_ID
# Scenario env vars (FAKE_CODEX_SCENARIO/_EXIT_CODE/_SLEEP_SECS/
# _FINAL_ANSWER/_MARKER_FILE) are read from whatever the caller already
# exported -- each call site below sets them inline right before calling
# this, rather than threading them through as parameters.
pd_run() {
  local mode="$1"; shift
  if [ "$mode" = "resume" ]; then
    local tid="$1"; shift
    # --cwd is required on every invocation, even --resume (the wrapper's
    # own arg validation checks CWD unconditionally, and the dispatch
    # subshell always does `cd "$CWD"` before running codex).
    PATH="$FAKE_BIN_DIR:$PATH" HOME="$FAKE_HOME" "$WRAPPER" --cwd "$PD_REPO" --resume "$tid" --focus x "$@" 2>&1
  else
    PATH="$FAKE_BIN_DIR:$PATH" HOME="$FAKE_HOME" "$WRAPPER" --cwd "$PD_REPO" --uncommitted --focus x "$@" 2>&1
  fi
}

# pd_reason OUTPUT -> the wrapper's own JSON is always the LAST line of
# combined stdout+stderr (the wrapper's occasional "THREAD_ID=..." debug
# line, when present, is always printed to stderr before it).
pd_reason() { printf '%s' "$1" | tail -1 | jq -r '.reason // empty' 2>/dev/null; }
pd_threadid() { printf '%s' "$1" | tail -1 | jq -r '.threadId // empty' 2>/dev/null; }

pd_assert_reason() {
  local out="$1" expected="$2" label="$3" got
  got="$(pd_reason "$out")"
  if [ "$got" = "$expected" ]; then
    pass "$label: reason=$expected"
  else
    fail "$label: expected reason=$expected, got reason=$got (full: $out)"
  fi
}
pd_assert_threadid_present() {
  local out="$1" label="$2" got
  got="$(pd_threadid "$out")"
  if [ -n "$got" ]; then
    pass "$label: threadId present ($got)"
  else
    fail "$label: expected a threadId, got none (full: $out)"
  fi
}

PD_VALID_VERDICT='{"verdict":"CLEAN","findings":[],"summary":null,"dimensions":{"correctness":{"status":"not_applicable","evidence":"e"},"security":{"status":"not_applicable","evidence":"e"},"performance":{"status":"not_applicable","evidence":"e"},"reuse":{"status":"not_applicable","evidence":"e"},"contracts":{"status":"not_applicable","evidence":"e"},"resources_concurrency":{"status":"not_applicable","evidence":"e"},"intent":{"status":"not_applicable","evidence":"e"}}}'

# --- sanity: the fake codex itself, on a scenario meant to succeed,
# actually produces ok:true (fresh and resume) -- every case below relies
# on this fixture behaving correctly, so it gets its own direct check.
export FAKE_CODEX_SCENARIO=normal
OUT="$(pd_run fresh)"
if [ "$(printf '%s' "$OUT" | tail -1 | jq -r '.ok')" = "true" ]; then
  pass "sanity: fresh normal-success dispatch returns ok:true"
else
  fail "sanity: fresh normal-success dispatch should return ok:true, got: $OUT"
fi

TID="$(pd_new_tid)"
OUT="$(pd_run resume "$TID")"
if [ "$(printf '%s' "$OUT" | tail -1 | jq -r '.ok')" = "true" ]; then
  pass "sanity: resume normal-success dispatch returns ok:true"
else
  fail "sanity: resume normal-success dispatch should return ok:true, got: $OUT"
fi
unset FAKE_CODEX_SCENARIO

# --- interrupted: the WRAPPER's own signal trap, not anything fake-codex
# does -- fake-codex just hangs (FAKE_CODEX_SCENARIO=hang) so there's a
# real window to send SIGTERM to the wrapper's own process into.
pd_test_interrupted() {
  # Only 3 call shapes are actually used below (fresh, resume, fresh +
  # capture-eventlog) -- handled as separate branches rather than an
  # optional-args array, since this project's bash 3.2 floor raises
  # "unbound variable" under `set -u` when expanding "${ARR[@]}" on an
  # array that was ever assigned empty (see run-ccs-review.sh's own note
  # on TRACKED_BINARY_PATHS for the identical constraint).
  # check_coverage (4th, optional): when non-empty, also asserts the
  # captured output's .coverage.source.status is a real value -- the
  # on_signal coverage regression check. Off by default so the 3 existing
  # call sites below keep their original, unchanged assertions.
  local mode="$1" tid="${2:-}" capture_path="${3:-}" check_coverage="${4:-}"
  local label="$mode"
  local marker outfile wrapper_pid
  marker="$(mktemp -u)"
  outfile="$(mktemp)"
  export FAKE_CODEX_SCENARIO=hang FAKE_CODEX_SLEEP_SECS=30 FAKE_CODEX_MARKER_FILE="$marker"
  # Deliberately NOT routed through pd_run here: backgrounding a shell
  # FUNCTION call (`pd_run ... &`) forks an extra supervisor process for
  # the job, so $! captures THAT process, never the actual $WRAPPER
  # process running on_signal's trap -- a SIGTERM sent to $! would then
  # kill the supervisor while the real wrapper (reparented to init) keeps
  # running unsignaled. Invoking "$WRAPPER" directly as the backgrounded
  # command keeps $! pointing at the real process.
  if [ "$mode" = "resume" ]; then
    PATH="$FAKE_BIN_DIR:$PATH" HOME="$FAKE_HOME" "$WRAPPER" --cwd "$PD_REPO" --resume "$tid" --focus x \
      > "$outfile" 2>&1 &
  elif [ -n "$capture_path" ]; then
    PATH="$FAKE_BIN_DIR:$PATH" HOME="$FAKE_HOME" "$WRAPPER" --cwd "$PD_REPO" --uncommitted --focus x \
      --capture-eventlog "$capture_path" > "$outfile" 2>&1 &
  else
    PATH="$FAKE_BIN_DIR:$PATH" HOME="$FAKE_HOME" "$WRAPPER" --cwd "$PD_REPO" --uncommitted --focus x \
      > "$outfile" 2>&1 &
  fi
  wrapper_pid=$!
  # Wait for fake-codex to genuinely start (marker file) -- if it never
  # does, fail loudly instead of silently falling through to a SIGTERM
  # that would then race an already-broken dispatch and produce a
  # confusing, unrelated assertion failure below.
  local waited=0
  while [ ! -e "$marker" ] && [ "$waited" -lt 50 ]; do sleep 0.1; waited=$((waited + 1)); done
  if [ ! -e "$marker" ]; then
    fail "interrupted ($label): fake-codex never started (marker not seen within 5s)"
    kill -TERM "$wrapper_pid" 2>/dev/null
    wait "$wrapper_pid" 2>/dev/null
    rm -f "$marker" "$outfile"
    unset FAKE_CODEX_SCENARIO FAKE_CODEX_SLEEP_SECS FAKE_CODEX_MARKER_FILE
    return
  fi
  # Then wait for the WRAPPER's own "THREAD_ID=..." line in $outfile
  # (scripts/run-ccs-review.sh echoes this to stderr, captured here,
  # immediately once it assigns $THREAD_ID -- for a fresh dispatch, only
  # after its own thread.started poll succeeds; for --resume, almost
  # immediately, since THREAD_ID is just the echoed --resume argument).
  # Polling this exact signal, rather than a fixed sleep after the
  # marker, is what actually closes the race: the marker fires as
  # fake-codex's very FIRST action, before it even emits thread.started,
  # so a fixed delay after it is a guess, not a guarantee, that the
  # wrapper has caught up.
  waited=0
  while ! grep -q '^THREAD_ID=' "$outfile" 2>/dev/null && [ "$waited" -lt 50 ]; do sleep 0.1; waited=$((waited + 1)); done
  kill -TERM "$wrapper_pid" 2>/dev/null
  wait "$wrapper_pid" 2>/dev/null
  OUT="$(cat "$outfile")"
  pd_assert_reason "$OUT" "interrupted" "interrupted ($label)"
  pd_assert_threadid_present "$OUT" "interrupted ($label)"
  if [ -n "$check_coverage" ]; then
    local cov_status
    cov_status="$(printf '%s' "$OUT" | tail -1 | jq -r '.coverage.source.status // empty')"
    if [ "$cov_status" = "complete" ] || [ "$cov_status" = "partial" ]; then
      pass "interrupted ($label): coverage.source is spliced in on this signal path (status=$cov_status)"
    else
      fail "interrupted ($label): expected a real coverage.source.status, got: $OUT"
    fi
  fi
  rm -f "$marker" "$outfile"
  unset FAKE_CODEX_SCENARIO FAKE_CODEX_SLEEP_SECS FAKE_CODEX_MARKER_FILE
}
pd_test_interrupted fresh
TID="$(pd_new_tid)"
pd_test_interrupted resume "$TID"

# --- interrupted coverage regression: a fresh dispatch interrupted AFTER
# thread.started has already fired (proven by the wrapper's own
# "THREAD_ID=..." wait inside pd_test_interrupted, which only happens once
# diff collection -- and therefore $SOURCE_COVERAGE_JSON -- is already
# populated, since collection runs before `codex exec` is even launched)
# must still carry coverage.source. on_signal() used to build its JSON with
# a bare `printf` instead of routing through emit_final_output, silently
# dropping already-collected coverage data on every SIGINT/SIGTERM.
pd_test_interrupted fresh "" "" check_coverage

# on_signal() exits before ever reaching the --capture-eventlog copy step
# that the normal (non-signal) code path uses -- so a signal-interrupted
# round never populates the requested capture path. Worth locking in
# explicitly rather than leaving it an unverified assumption.
CAPTURE_DIR="$(mktemp -d)"; CAPTURE_PATH="$CAPTURE_DIR/eventlog.jsonl"
pd_test_interrupted fresh "" "$CAPTURE_PATH"
if [ ! -e "$CAPTURE_PATH" ]; then
  pass "interrupted: --capture-eventlog is NOT populated (on_signal skips the copy step)"
else
  fail "interrupted: expected no eventlog capture, but $CAPTURE_PATH was created"
fi
rm -rf "$CAPTURE_DIR"

# --- timeout: the wrapper's own --timeout deadline, not a fake-codex exit.
export FAKE_CODEX_SCENARIO=hang FAKE_CODEX_SLEEP_SECS=5
OUT="$(pd_run fresh --timeout 1)"
pd_assert_reason "$OUT" "timeout" "timeout (fresh)"
pd_assert_threadid_present "$OUT" "timeout (fresh)"

TID="$(pd_new_tid)"
OUT="$(pd_run resume "$TID" --timeout 1)"
pd_assert_reason "$OUT" "timeout" "timeout (resume)"
pd_assert_threadid_present "$OUT" "timeout (resume)"
unset FAKE_CODEX_SCENARIO FAKE_CODEX_SLEEP_SECS

# --- no_thread_started: fresh dispatch only (--resume has no thread.started
# concept) -- fake-codex never emits thread.started, forcing the wrapper's
# own real (hardcoded) THREAD_WAIT_SECS=10s poll to genuinely time out. This
# is also a coverage regression check: diff collection (which populates
# $SOURCE_COVERAGE_JSON) happens BEFORE `codex exec` is ever launched, so by
# the time this branch fires, real coverage data is already available -- the
# fix (scripts/run-ccs-review.sh's no_thread_started branch) must route
# through emit_final_output rather than a bare printf for that data to
# survive into the response. Real wall-clock cost: this case takes slightly
# over 10s, same as the timeout fixture above.
export FAKE_CODEX_NO_THREAD_STARTED=1
OUT="$(pd_run fresh)"
pd_assert_reason "$OUT" "no_thread_started" "no_thread_started (fresh)"
COV_STATUS="$(printf '%s' "$OUT" | tail -1 | jq -r '.coverage.source.status // empty')"
if [ "$COV_STATUS" = "complete" ] || [ "$COV_STATUS" = "partial" ]; then
  pass "no_thread_started (fresh): coverage.source is spliced in on this post-dispatch failure (status=$COV_STATUS)"
else
  fail "no_thread_started (fresh): expected a real coverage.source.status, got: $OUT"
fi
unset FAKE_CODEX_NO_THREAD_STARTED

# --- nonzero_exit: codex exec/exec resume itself exits nonzero.
for CODE in 1 3; do
  export FAKE_CODEX_SCENARIO=exit_nonzero FAKE_CODEX_EXIT_CODE="$CODE"
  OUT="$(pd_run fresh)"
  pd_assert_reason "$OUT" "nonzero_exit" "nonzero_exit (fresh, exit=$CODE)"
  pd_assert_threadid_present "$OUT" "nonzero_exit (fresh, exit=$CODE)"

  TID="$(pd_new_tid)"
  OUT="$(pd_run resume "$TID")"
  pd_assert_reason "$OUT" "nonzero_exit" "nonzero_exit (resume, exit=$CODE)"
  pd_assert_threadid_present "$OUT" "nonzero_exit (resume, exit=$CODE)"
done

# --capture-eventlog must contain fake-codex's own raw stdout for a
# non-signal failure path (unlike interrupted above).
CAPTURE_DIR="$(mktemp -d)"; CAPTURE_PATH="$CAPTURE_DIR/eventlog.jsonl"
export FAKE_CODEX_SCENARIO=exit_nonzero FAKE_CODEX_EXIT_CODE=1
OUT="$(pd_run fresh --capture-eventlog "$CAPTURE_PATH")"
pd_assert_reason "$OUT" "nonzero_exit" "nonzero_exit (fresh, --capture-eventlog)"
if [ -f "$CAPTURE_PATH" ] && grep -q '"type":"thread.started"' "$CAPTURE_PATH"; then
  pass "nonzero_exit: --capture-eventlog captured fake-codex's raw stdout"
else
  fail "nonzero_exit: --capture-eventlog should contain thread.started, file: $([ -f "$CAPTURE_PATH" ] && cat "$CAPTURE_PATH" || echo MISSING)"
fi
rm -rf "$CAPTURE_DIR"
unset FAKE_CODEX_SCENARIO FAKE_CODEX_EXIT_CODE

# --- missing_task_complete: process exits 0, task_complete never appears.
export FAKE_CODEX_SCENARIO=no_task_complete
OUT="$(pd_run fresh)"
pd_assert_reason "$OUT" "missing_task_complete" "missing_task_complete (fresh)"
pd_assert_threadid_present "$OUT" "missing_task_complete (fresh)"

TID="$(pd_new_tid)"
OUT="$(pd_run resume "$TID")"
pd_assert_reason "$OUT" "missing_task_complete" "missing_task_complete (resume)"
pd_assert_threadid_present "$OUT" "missing_task_complete (resume)"
unset FAKE_CODEX_SCENARIO

# --- no_final_answer: turn.completed appears, but -o never gets a final message.
export FAKE_CODEX_SCENARIO=no_final_answer
OUT="$(pd_run fresh)"
pd_assert_reason "$OUT" "no_final_answer" "no_final_answer (fresh)"
pd_assert_threadid_present "$OUT" "no_final_answer (fresh)"

TID="$(pd_new_tid)"
OUT="$(pd_run resume "$TID")"
pd_assert_reason "$OUT" "no_final_answer" "no_final_answer (resume)"
pd_assert_threadid_present "$OUT" "no_final_answer (resume)"
unset FAKE_CODEX_SCENARIO

# --- invalid_json: final_answer text exists but isn't valid JSON at all.
PD_INVALID_JSON_VARIANTS=(
  "not json at all"
  "{not even close to json"
  "<<<garbled response>>>"
)
i=0
for VARIANT in "${PD_INVALID_JSON_VARIANTS[@]}"; do
  i=$((i + 1))
  export FAKE_CODEX_SCENARIO=invalid_json FAKE_CODEX_FINAL_ANSWER="$VARIANT"
  OUT="$(pd_run fresh)"
  pd_assert_reason "$OUT" "invalid_json" "invalid_json (fresh, variant $i)"
  pd_assert_threadid_present "$OUT" "invalid_json (fresh, variant $i)"

  TID="$(pd_new_tid)"
  OUT="$(pd_run resume "$TID")"
  pd_assert_reason "$OUT" "invalid_json" "invalid_json (resume, variant $i)"
  pd_assert_threadid_present "$OUT" "invalid_json (resume, variant $i)"
done

CAPTURE_DIR="$(mktemp -d)"; CAPTURE_PATH="$CAPTURE_DIR/eventlog.jsonl"
export FAKE_CODEX_SCENARIO=invalid_json FAKE_CODEX_FINAL_ANSWER="${PD_INVALID_JSON_VARIANTS[0]}"
OUT="$(pd_run fresh --capture-eventlog "$CAPTURE_PATH")"
pd_assert_reason "$OUT" "invalid_json" "invalid_json (fresh, --capture-eventlog)"
if [ -f "$CAPTURE_PATH" ] && grep -q '"type":"thread.started"' "$CAPTURE_PATH"; then
  pass "invalid_json: --capture-eventlog captured fake-codex's raw stdout"
else
  fail "invalid_json: --capture-eventlog should contain thread.started, file: $([ -f "$CAPTURE_PATH" ] && cat "$CAPTURE_PATH" || echo MISSING)"
fi
rm -rf "$CAPTURE_DIR"
unset FAKE_CODEX_SCENARIO FAKE_CODEX_FINAL_ANSWER

# --- schema_mismatch: valid JSON, but fails the wrapper's own semantic
# cross-field rules (search run-ccs-review.sh for where invalid_json and
# schema_mismatch are emitted -- each variant below violates exactly one
# rule from that jq check).
pd_variant() {
  # pd_variant NAME JQ_FILTER -> starts from PD_VALID_VERDICT and applies
  # one jq mutation, so each variant only names the ONE rule it breaks
  # instead of restating the whole JSON blob per case.
  printf '%s' "$PD_VALID_VERDICT" | jq -c "$1"
}

PD_SCHEMA_MISMATCH_NAMES=(
  "CLEAN-with-nonempty-findings"
  "ISSUES-with-empty-findings"
  "missing-dimension-key"
  "blank-dimension-evidence"
  "finding-blank-verification"
  "extra-top-level-key"
  "finding-line-zero"
  "invalid-severity-value"
  "invalid-verdict-value"
  "finding-missing-required-key"
)
PD_SCHEMA_MISMATCH_JSON=(
  "$(pd_variant '.findings += [{"file":"a.txt","line":1,"severity":"low","summary":"s","evidence":"e","verification":"v"}]')"
  "$(pd_variant '.verdict = "ISSUES"')"
  "$(pd_variant 'del(.dimensions.intent)')"
  "$(pd_variant '.dimensions.correctness.evidence = "   "')"
  "$(pd_variant '.verdict = "ISSUES" | .findings = [{"file":"a.txt","line":1,"severity":"low","summary":"s","evidence":"e","verification":"   "}]')"
  "$(pd_variant '. + {"extra_field": true}')"
  "$(pd_variant '.verdict = "ISSUES" | .findings = [{"file":"a.txt","line":0,"severity":"low","summary":"s","evidence":"e","verification":"v"}]')"
  "$(pd_variant '.verdict = "ISSUES" | .findings = [{"file":"a.txt","line":1,"severity":"critical","summary":"s","evidence":"e","verification":"v"}]')"
  # Also sets findings to a valid nonempty array: the wrapper's
  # CLEAN/ISSUES-vs-findings cross-field clause branches on `.verdict ==
  # "CLEAN"`, so changing verdict alone to a non-CLEAN, non-ISSUES value
  # would ALSO flip that clause to its non-CLEAN branch (needs
  # findings.length > 0) while findings is still the empty baseline --
  # failing two independent clauses at once instead of isolating the
  # allowed-verdict-values check this variant is named for.
  "$(pd_variant '.verdict = "PASS" | .findings = [{"file":"a.txt","line":1,"severity":"low","summary":"s","evidence":"e","verification":"v"}]')"
  "$(pd_variant '.verdict = "ISSUES" | .findings = [{"line":1,"severity":"low","summary":"s","evidence":"e","verification":"v"}]')"
)
for i in "${!PD_SCHEMA_MISMATCH_NAMES[@]}"; do
  NAME="${PD_SCHEMA_MISMATCH_NAMES[$i]}"
  JSON="${PD_SCHEMA_MISMATCH_JSON[$i]}"
  export FAKE_CODEX_SCENARIO=schema_mismatch FAKE_CODEX_FINAL_ANSWER="$JSON"
  OUT="$(pd_run fresh)"
  pd_assert_reason "$OUT" "schema_mismatch" "schema_mismatch (fresh, $NAME)"
  pd_assert_threadid_present "$OUT" "schema_mismatch (fresh, $NAME)"
done

# A couple of the same variants, also exercised over --resume.
for NAME_IDX in 0 1; do
  NAME="${PD_SCHEMA_MISMATCH_NAMES[$NAME_IDX]}"
  JSON="${PD_SCHEMA_MISMATCH_JSON[$NAME_IDX]}"
  TID="$(pd_new_tid)"
  export FAKE_CODEX_SCENARIO=schema_mismatch FAKE_CODEX_FINAL_ANSWER="$JSON"
  OUT="$(pd_run resume "$TID")"
  pd_assert_reason "$OUT" "schema_mismatch" "schema_mismatch (resume, $NAME)"
  pd_assert_threadid_present "$OUT" "schema_mismatch (resume, $NAME)"
done

CAPTURE_DIR="$(mktemp -d)"; CAPTURE_PATH="$CAPTURE_DIR/eventlog.jsonl"
export FAKE_CODEX_SCENARIO=schema_mismatch FAKE_CODEX_FINAL_ANSWER="${PD_SCHEMA_MISMATCH_JSON[0]}"
OUT="$(pd_run fresh --capture-eventlog "$CAPTURE_PATH")"
pd_assert_reason "$OUT" "schema_mismatch" "schema_mismatch (fresh, --capture-eventlog)"
if [ -f "$CAPTURE_PATH" ] && grep -q '"type":"thread.started"' "$CAPTURE_PATH"; then
  pass "schema_mismatch: --capture-eventlog captured fake-codex's raw stdout"
else
  fail "schema_mismatch: --capture-eventlog should contain thread.started, file: $([ -f "$CAPTURE_PATH" ] && cat "$CAPTURE_PATH" || echo MISSING)"
fi
rm -rf "$CAPTURE_DIR"
unset FAKE_CODEX_SCENARIO FAKE_CODEX_FINAL_ANSWER

# --- coverage regression: a post-dispatch failure on a fresh --uncommitted
# round must still carry coverage.source, exactly like an ok:true round on
# the identical scope. emit_final_output's own header comment claims it is
# "shared by both the empty-diff fast path and the normal result path so
# both always get a coverage object" -- but the dispatch epilogue used to
# call emit_final_output only when RESULT was 0, falling through to a bare
# `printf` for every one of the 7 post-dispatch failure reasons instead,
# silently dropping already-collected coverage data on all of them. Picking
# schema_mismatch here (not nonzero_exit/etc.) is arbitrary -- the fix lives
# in the shared epilogue after JUDGE_OUTPUT is set, not in any
# reason-specific branch, so one representative post-dispatch failure
# reason is sufficient to catch a regression in that shared code path.
export FAKE_CODEX_SCENARIO=schema_mismatch FAKE_CODEX_FINAL_ANSWER="${PD_SCHEMA_MISMATCH_JSON[0]}"
OUT="$(pd_run fresh)"
pd_assert_reason "$OUT" "schema_mismatch" "schema_mismatch coverage regression: reason"
COV_STATUS="$(printf '%s' "$OUT" | tail -1 | jq -r '.coverage.source.status // empty')"
if [ "$COV_STATUS" = "complete" ] || [ "$COV_STATUS" = "partial" ]; then
  pass "schema_mismatch (fresh, --uncommitted): coverage.source is still spliced in on a post-dispatch failure (status=$COV_STATUS)"
else
  fail "schema_mismatch (fresh, --uncommitted): expected a real coverage.source.status, got: $OUT"
fi
unset FAKE_CODEX_SCENARIO FAKE_CODEX_FINAL_ANSWER

# --- investigation_evidence extraction fixtures (capture-evidence, no real API calls) ---
# Exercises the two jq filters documented in skills/ccs/SKILL.md's
# "Investigation evidence capture" section, copied VERBATIM from that file
# below (never paraphrased/simplified) -- step 2's per-(round,group)
# extraction filter and step 3's parallel-mode merge filter. fake-codex's
# FAKE_CODEX_COMMANDS/FAKE_CODEX_GARBAGE_LINE env vars (see
# tests/fixtures/fake-codex) make its own stdout -- which --capture-eventlog
# copies verbatim, per the nonzero_exit/invalid_json/schema_mismatch
# fixtures above -- contain real item.completed/command_execution events (or
# a deliberately unparseable line) without ever touching a real Codex
# backend.

# ccs_extract_evidence EVENTLOG_FILE -> sets (global) INVESTIGATION_EVIDENCE_JSON.
# Verbatim body of SKILL.md step 2's extraction snippet, including its own
# [ -s ... ] guard -- only the surrounding function wrapper and the
# parameter name are test scaffolding.
ccs_extract_evidence() {
  local EVENTLOG_FILE="$1"
  if [ -s "$EVENTLOG_FILE" ]; then
    INVESTIGATION_EVIDENCE_JSON=$(jq -Rn -c '
      [inputs | fromjson? | select(.type == "item.completed" and .item.type == "command_execution") | .item.command]
      | {command_count: length, commands: .}
    ' "$EVENTLOG_FILE")
  else
    INVESTIGATION_EVIDENCE_JSON='{"command_count":0,"commands":[]}'
  fi
}

# 1. Basic extraction, nonzero commands (fresh dispatch). One command
# embeds a double quote, a "$", and a space together, to prove the
# extraction is JSON-safe rather than string-concatenation-safe.
IE_CMD1='grep -rn "foo $HOME" src/dir'
IE_CMD2='cat package.json'
IE_CMD3='npm test -- --watch=false'
CAPTURE_DIR="$(mktemp -d)"; CAPTURE_PATH="$CAPTURE_DIR/eventlog.jsonl"
export FAKE_CODEX_SCENARIO=normal FAKE_CODEX_COMMANDS="$IE_CMD1
$IE_CMD2
$IE_CMD3"
OUT="$(pd_run fresh --capture-eventlog "$CAPTURE_PATH")"
if [ "$(printf '%s' "$OUT" | tail -1 | jq -r '.ok')" = "true" ]; then
  pass "investigation_evidence: fresh dispatch with 3 commands returns ok:true"
else
  fail "investigation_evidence: fresh dispatch with 3 commands should return ok:true, got: $OUT"
fi
ccs_extract_evidence "$CAPTURE_PATH"
IE_EXPECTED_COMMANDS="$(jq -nc --arg c1 "$IE_CMD1" --arg c2 "$IE_CMD2" --arg c3 "$IE_CMD3" '[$c1,$c2,$c3]')"
IE_ACTUAL_COUNT="$(printf '%s' "$INVESTIGATION_EVIDENCE_JSON" | jq -r '.command_count')"
IE_ACTUAL_COMMANDS="$(printf '%s' "$INVESTIGATION_EVIDENCE_JSON" | jq -c '.commands')"
if [ "$IE_ACTUAL_COUNT" = "3" ] && [ "$IE_ACTUAL_COMMANDS" = "$IE_EXPECTED_COMMANDS" ]; then
  pass "investigation_evidence: extraction filter yields command_count=3 and the exact commands, special characters intact"
else
  fail "investigation_evidence: expected command_count=3 commands=$IE_EXPECTED_COMMANDS, got: $INVESTIGATION_EVIDENCE_JSON"
fi
rm -rf "$CAPTURE_DIR"
unset FAKE_CODEX_SCENARIO FAKE_CODEX_COMMANDS

# 2. Zero commands, but a genuinely non-empty/successful round (ok:true) --
# the extraction filter must report a real, honest zero here, distinct from
# the (separately-decided, not tested here) skip-extraction-entirely case.
CAPTURE_DIR="$(mktemp -d)"; CAPTURE_PATH="$CAPTURE_DIR/eventlog.jsonl"
export FAKE_CODEX_SCENARIO=normal
OUT="$(pd_run fresh --capture-eventlog "$CAPTURE_PATH")"
if [ "$(printf '%s' "$OUT" | tail -1 | jq -r '.ok')" = "true" ]; then
  pass "investigation_evidence: fresh dispatch with zero commands returns ok:true"
else
  fail "investigation_evidence: fresh dispatch with zero commands should return ok:true, got: $OUT"
fi
ccs_extract_evidence "$CAPTURE_PATH"
if [ "$INVESTIGATION_EVIDENCE_JSON" = '{"command_count":0,"commands":[]}' ]; then
  pass "investigation_evidence: a genuinely-ran zero-command round extracts a real, honest zero"
else
  fail "investigation_evidence: expected {\"command_count\":0,\"commands\":[]}, got: $INVESTIGATION_EVIDENCE_JSON"
fi
rm -rf "$CAPTURE_DIR"
unset FAKE_CODEX_SCENARIO

# 3. Malformed/garbage line tolerance: fromjson? must silently skip an
# unparseable line -- not count it, not error the whole jq invocation --
# while still extracting the real commands around it.
IE_CMD_A='echo hello'
IE_CMD_B='ls -la /tmp'
CAPTURE_DIR="$(mktemp -d)"; CAPTURE_PATH="$CAPTURE_DIR/eventlog.jsonl"
export FAKE_CODEX_SCENARIO=normal FAKE_CODEX_GARBAGE_LINE=1 FAKE_CODEX_COMMANDS="$IE_CMD_A
$IE_CMD_B"
OUT="$(pd_run fresh --capture-eventlog "$CAPTURE_PATH")"
if [ "$(printf '%s' "$OUT" | tail -1 | jq -r '.ok')" = "true" ]; then
  pass "investigation_evidence: fresh dispatch with garbage line + 2 commands returns ok:true"
else
  fail "investigation_evidence: fresh dispatch with garbage line + 2 commands should return ok:true, got: $OUT"
fi
if [ -f "$CAPTURE_PATH" ] && grep -qxF "not valid json at all" "$CAPTURE_PATH"; then
  pass "investigation_evidence: eventlog genuinely contains the injected garbage line"
else
  fail "investigation_evidence: expected the injected garbage line in the eventlog, file: $([ -f "$CAPTURE_PATH" ] && cat "$CAPTURE_PATH" || echo MISSING)"
fi
IE_MALFORMED_JSON=$(jq -Rn -c '
  [inputs | fromjson? | select(.type == "item.completed" and .item.type == "command_execution") | .item.command]
  | {command_count: length, commands: .}
' "$CAPTURE_PATH")
IE_JQ_STATUS=$?
IE_EXPECTED="$(jq -nc --arg a "$IE_CMD_A" --arg b "$IE_CMD_B" '{command_count:2, commands:[$a,$b]}')"
if [ "$IE_JQ_STATUS" -eq 0 ] && [ "$IE_MALFORMED_JSON" = "$IE_EXPECTED" ]; then
  pass "investigation_evidence: fromjson? swallows the garbage line (jq exit 0), extracts exactly the 2 real commands"
else
  fail "investigation_evidence: expected jq exit 0 and $IE_EXPECTED, got exit=$IE_JQ_STATUS value=$IE_MALFORMED_JSON"
fi
rm -rf "$CAPTURE_DIR"
unset FAKE_CODEX_SCENARIO FAKE_CODEX_GARBAGE_LINE FAKE_CODEX_COMMANDS

# 4. Parallel-mode merge filter -- SKILL.md step 3, verbatim, including its
# own heredoc-style two-line input. No wrapper dispatch needed: this filter
# operates purely on two already-produced INVESTIGATION_EVIDENCE_JSON-shaped
# objects.
IE_GROUP1_JSON='{"command_count":2,"commands":["a","b"]}'
IE_GROUP2_JSON='{"command_count":1,"commands":["c"]}'
MERGED_INVESTIGATION_EVIDENCE_JSON=$(jq -sc '{command_count: (map(.command_count) | add), commands: (map(.commands) | add)}' <<< "$IE_GROUP1_JSON
$IE_GROUP2_JSON")
IE_EXPECTED_MERGE='{"command_count":3,"commands":["a","b","c"]}'
if [ "$MERGED_INVESTIGATION_EVIDENCE_JSON" = "$IE_EXPECTED_MERGE" ]; then
  pass "investigation_evidence: parallel-mode merge filter sums command_count and concatenates commands in order"
else
  fail "investigation_evidence: expected $IE_EXPECTED_MERGE, got: $MERGED_INVESTIGATION_EVIDENCE_JSON"
fi

# 5. Resume-dispatch extraction: same nonzero-commands case as #1, but via
# --resume, confirming the extraction filter itself has no fresh/resume
# distinction (that distinction lives entirely in the separate
# should-extraction-run decision, not in this filter's logic).
IE_CMD1R='grep -rn "foo $HOME" src/dir'
IE_CMD2R='cat package.json'
IE_CMD3R='npm test -- --watch=false'
TID="$(pd_new_tid)"
CAPTURE_DIR="$(mktemp -d)"; CAPTURE_PATH="$CAPTURE_DIR/eventlog.jsonl"
export FAKE_CODEX_SCENARIO=normal FAKE_CODEX_COMMANDS="$IE_CMD1R
$IE_CMD2R
$IE_CMD3R"
OUT="$(pd_run resume "$TID" --capture-eventlog "$CAPTURE_PATH")"
if [ "$(printf '%s' "$OUT" | tail -1 | jq -r '.ok')" = "true" ]; then
  pass "investigation_evidence: resume dispatch with 3 commands returns ok:true"
else
  fail "investigation_evidence: resume dispatch with 3 commands should return ok:true, got: $OUT"
fi
ccs_extract_evidence "$CAPTURE_PATH"
IE_EXPECTED_COMMANDS="$(jq -nc --arg c1 "$IE_CMD1R" --arg c2 "$IE_CMD2R" --arg c3 "$IE_CMD3R" '[$c1,$c2,$c3]')"
IE_ACTUAL_COUNT="$(printf '%s' "$INVESTIGATION_EVIDENCE_JSON" | jq -r '.command_count')"
IE_ACTUAL_COMMANDS="$(printf '%s' "$INVESTIGATION_EVIDENCE_JSON" | jq -c '.commands')"
if [ "$IE_ACTUAL_COUNT" = "3" ] && [ "$IE_ACTUAL_COMMANDS" = "$IE_EXPECTED_COMMANDS" ]; then
  pass "investigation_evidence: resume-dispatch extraction works identically to fresh (command_count=3, commands intact)"
else
  fail "investigation_evidence: expected command_count=3 commands=$IE_EXPECTED_COMMANDS, got: $INVESTIGATION_EVIDENCE_JSON"
fi
rm -rf "$CAPTURE_DIR"
unset FAKE_CODEX_SCENARIO FAKE_CODEX_COMMANDS

rm -rf "$FAKE_HOME" "$FAKE_BIN_DIR" "$PD_REPO"

echo ""
if [ "$FAILURES" -eq 0 ]; then
  echo "All fixtures passed."
  exit 0
else
  echo "$FAILURES fixture(s) failed."
  exit 1
fi
