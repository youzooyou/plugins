#!/usr/bin/env bash
# Regression fixtures for run-ccs-review.sh -- covers exactly the bug
# classes that have already shipped once in this plugin's own history
# (a bypassable --focus gate, a bad --resume contract) plus the
# git-environment/config isolation gap fixed alongside this suite. No
# `codex exec` call is ever made: every case here fails or short-circuits
# before the wrapper would dispatch to Codex, so this suite costs no API
# calls and runs in well under a second.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WRAPPER="$SCRIPT_DIR/../scripts/run-ccs-review.sh"
LIB_GIT_SAFE="$SCRIPT_DIR/../scripts/lib/git-safe.sh"

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

OUT="$("$WRAPPER" --cwd /tmp --resume definitely-not-a-real-thread-id --focus 'x' 2>&1)"
if printf '%s' "$OUT" | grep -q '"reason":"resume_thread_not_found"'; then
  pass "--resume on a nonexistent threadId returns resume_thread_not_found"
else
  fail "expected resume_thread_not_found, got: $OUT"
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

echo ""
if [ "$FAILURES" -eq 0 ]; then
  echo "All fixtures passed."
  exit 0
else
  echo "$FAILURES fixture(s) failed."
  exit 1
fi
