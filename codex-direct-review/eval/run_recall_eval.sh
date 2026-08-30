#!/usr/bin/env bash
set -u

# Never trust inherited GIT_DIR/GIT_WORK_TREE/GIT_INDEX_FILE -- every git
# call in this script assumes `-C <dir>` fully controls which repository and
# worktree it operates on, but these env vars silently override that.
# Live-confirmed: `GIT_WORK_TREE=/ git -C eval/corpus rev-parse
# --show-toplevel` returns "/" (not eval/corpus) -- `-C` does NOT override an
# inherited GIT_WORK_TREE -- and an inherited GIT_DIR breaks `-C`-based
# discovery entirely (`GIT_DIR=/dev/null git -C eval/corpus rev-parse
# --git-dir` fails outright). A parent process (a git hook, a wrapper
# script) that leaves these set in the environment could otherwise make this
# script's git calls -- especially the mutating init/add/commit in the
# isolation-snapshot section further down -- operate on a completely
# different repository/worktree than the mktemp directory intended.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE

# Also neutralize git's "command scope" config-injection mechanism
# (GIT_CONFIG_COUNT + dynamically-numbered GIT_CONFIG_KEY_N/GIT_CONFIG_VALUE_N
# pairs, plus the older GIT_CONFIG_PARAMETERS) -- these let arbitrary
# inherited environment variables override ANY git config value, including
# core.hooksPath. Live-confirmed: `env GIT_CONFIG_COUNT=1
# GIT_CONFIG_KEY_0=core.hooksPath GIT_CONFIG_VALUE_0=/tmp/inherited-hooks
# git config --show-scope --get core.hooksPath` reports that value at
# "command" scope -- meaning an inherited core.hooksPath could make the
# isolation-snapshot's `git commit` further down execute an attacker/parent-
# controlled hook script entirely outside the intended isolated snapshot
# (and other injected config keys could alter add/commit behavior in other
# ways). The KEY_N/VALUE_N indices are dynamic (however many pairs
# GIT_CONFIG_COUNT claims), so they're discovered via bash's `${!prefix@}`
# indirect-expansion rather than unset by a fixed name list. Live-confirmed
# the fix actually closes the hole: after this block, the same
# `git config --show-scope --get core.hooksPath` call that previously
# reported the injected path now reports nothing (exit 1).
unset GIT_CONFIG_COUNT GIT_CONFIG_PARAMETERS
for _git_config_var in "${!GIT_CONFIG_KEY_@}" "${!GIT_CONFIG_VALUE_@}"; do
  unset "$_git_config_var"
done
unset _git_config_var

# Also unset GIT_CONFIG_GLOBAL/GIT_CONFIG_SYSTEM (redirect which global/
# system config FILE git reads -- live-confirmed via git-config(1): setting
# either to /dev/zero makes git fail with "bad config line 1", proving it
# reads from that path) and GIT_TEMPLATE_DIR (files there are copied into a
# newly-init'd .git per git-init(1)). These three cover every remaining
# script-wide git call (the mutating isolation-snapshot git calls further
# down use a stronger `env -i` allowlist instead of a denylist, precisely
# because this kind of incremental denylist enumeration doesn't converge on
# its own -- see that section's own comment for why); this unset block is
# defense-in-depth for the OTHER, read-only git calls in this script
# (CORPUS_VERSION's computation above, snapshot_sha's rev-parse below).
unset GIT_CONFIG_GLOBAL GIT_CONFIG_SYSTEM GIT_TEMPLATE_DIR

# Recall/false-positive eval harness for codex-direct-review.
#
# Fixture layout (see corpus/*/): each fixture directory holds `expected.json`
# plus a `before/` subdirectory of plain files (the buggy, or for control-
# group fixtures the clean, state -- no `.git` of its own). Corpus fixtures
# used to be nested git repos (their own `repo/`, each with a "before"/
# "after" commit pair), but that format made the corpus itself impossible to
# version with git tags: committing a directory containing nested `.git`
# repos only records a gitlink (a pointer/commit-hash), not the actual
# objects, so a tag on the parent repo could never actually reproduce a
# fixture's content later. Converted (see git history/plan doc for the
# conversion procedure, which byte/tree-hash-verified each fixture before
# deleting its original nested repo) to plain files instead: the harness
# itself now synthesizes a throwaway single-commit git repo from `before/`
# at RUN TIME (see the "Isolation snapshot" comment in the fixture loop
# below), giving the wrapper something to `git show`/`--commit` against
# without the corpus itself needing to carry any git history. The "after"
# (fixed) state is no longer preserved anywhere in the corpus -- the harness
# never read it even in the old format, so this is not a functional loss.
#
# bash 3.2 (macOS system bash) compatibility note: no associative arrays, no
# mapfile/readarray -- per-fixture results are tracked in parallel indexed
# arrays instead.
#
# expected.json fields beyond the original spec:
#   - "difficulty": "easy" | "subtle" (bug fixtures) | null (control group).
#     Scored separately below so a corpus skewed toward easy, pattern-
#     matchable bugs can't quietly inflate the headline recall number.
#   - "focus": optional. When present, that fixture's review calls pass
#     --focus "<text>" to the wrapper (used by the 20/21 context-intent
#     pair to compare blind vs briefed recall on the identical bug).
#   - "severity_floor": present in every fixture's expected.json but
#     DELIBERATELY NOT READ OR ENFORCED here -- scoring a run as a hit
#     already requires a specific file+keyword match (see the hit-detection
#     jq below); additionally requiring the reported severity to meet a
#     floor would introduce a second, currently-uncalibrated source of
#     noise (severity grading itself has never been validated as reliable).
#     Left in the schema as a documented no-op field for potential future
#     use once severity-grading reliability has actually been checked.
#   - "safeguard_assertion": REQUIRED for every control-group fixture
#     (should_flag == false), validated before that fixture's runs execute
#     (see the pre-validation check below). A plain-English description of
#     the specific protection must_mention_file provides (e.g. "concurrent
#     writes ... are serialized by a mutex ..."). Used only by judge_finding
#     to phrase each control-group finding's yes/no judgment call -- never
#     read for bug fixtures (should_flag == true), which score primarily via
#     the file+keyword match instead (see "defect_assertion" immediately
#     below for the one additional case where a bug fixture's assertion IS
#     read).
#   - "defect_assertion": REQUIRED for every bug fixture (should_flag ==
#     true), validated before that fixture's runs execute (see the
#     pre-validation check below) -- the should_flag==true counterpart to
#     "safeguard_assertion" above. A plain-English description of the
#     specific defect must_mention_file contains (e.g. "the check-then-act
#     sequence ... has no lock, so two threads can both pass the membership
#     check before either updates it"). The lexical file+keyword check (see
#     the should_flag==true scoring branch below) runs FIRST and is never
#     skipped; defect_assertion is read only as a semantic fallback, via
#     judge_finding, when a finding names must_mention_file but no keyword
#     matched -- covering the case (found via manual review of a full 63-run
#     sweep: fixture 07's toctou bug described as "check-then-process"
#     instead of the required "check-then-act"; fixture 11's reordered-params
#     bug described via backtick-formatted `quantity`/`tax_rate` instead of
#     the required literal substring "quantity and tax_rate") where the model
#     genuinely identified the seeded defect but phrased it with a synonym
#     the keyword list didn't anticipate. Never read for control-group
#     fixtures, which use safeguard_assertion instead.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORPUS_DIR="$SCRIPT_DIR/corpus"
REVIEW_SCRIPT="$SCRIPT_DIR/../scripts/run-codex-review.sh"
DEFAULT_RUNS_PER_FIXTURE=3

# Raw per-run artifacts (full wrapper JSON + a small manifest) are saved for
# post-hoc audit -- e.g. distinguishing "the reviewer genuinely missed this"
# from "the scoring keywords were wrong" on an ambiguous miss (verdict=ISSUES
# but no scored hit). These are saved PERMANENTLY OUTSIDE the git checkout
# tree and are NEVER copied back into it: codex's --sandbox read-only blocks
# writes but not reads, so a result file sitting inside (or later copied
# into) the reviewed repo tree would be readable by a LATER sweep's live
# review -- the same class of leak the fixture isolation snapshot below
# exists to prevent. Keeping results permanently under $HOME/.local/state
# (a path with no directory relationship to any fixture snapshot) is a
# structural mitigation, not a hard guarantee: a process running as the same
# user can in principle read anywhere the OS permits. Closing that
# completely would need real filesystem sandboxing (container/chroot),
# which is out of scope here.
# Restrict to owner-only (0700 dirs / 0600 files) for everything created
# below -- narrows exposure of the saved verdict JSON to other accounts on
# the same machine. This does NOT (and cannot, from a plain umask) stop a
# process running as this same user/UID from reading these paths -- that
# residual limitation is inherent to the "no reads confined to --cwd"
# property of --sandbox read-only, and is accepted above.
umask 077

STATE_ROOT="$HOME/.local/state/codex-review-eval"
SUITE_ID="$(date +%Y%m%dT%H%M%S)-$$"
SUITE_DIR="$STATE_ROOT/$SUITE_ID"
mkdir -p "$STATE_ROOT" || { echo "error: cannot create $STATE_ROOT" >&2; exit 1; }
# Plain `mkdir` (no -p) IS the atomic collision check: it fails outright if
# $SUITE_DIR already exists, rather than a separate check-then-create pair
# that could race. A collision here (same second + same PID) is not
# something to silently retry past -- something's already wrong.
mkdir "$SUITE_DIR" || { echo "error: suite-id collision at $SUITE_DIR" >&2; exit 1; }
echo "Raw per-run results for this sweep: $SUITE_DIR" >&2

ONLY=""
CORPUS_DIR_OVERRIDE=""
PAIR_A=""
PAIR_B=""
RUNS_OVERRIDE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --only)
      [ $# -ge 2 ] || { echo "error: --only requires a fixture slug (directory name under corpus/)" >&2; exit 1; }
      ONLY="$2"; shift 2 ;;
    --corpus-dir)
      # Lets a specific corpus version/tag (e.g. a separate checkout or
      # worktree at eval-corpus-v1 vs eval-corpus-v2) be selected for a
      # sweep -- without this, CORPUS_DIR was hardcoded to $SCRIPT_DIR/corpus
      # with no way to point at a different tree at all.
      [ $# -ge 2 ] || { echo "error: --corpus-dir requires a path" >&2; exit 1; }
      CORPUS_DIR_OVERRIDE="$2"; shift 2 ;;
    --pair)
      # Runs a blind/focused fixture PAIR interleaved (member-A run 1,
      # member-B run 1, member-A run 2, ...) sharing ONE isolation snapshot,
      # instead of the main loop's sequential all-runs-then-next-fixture
      # order -- see run_pair_mode below for why interleaving and a shared
      # snapshot both matter for this specific comparison.
      [ $# -ge 3 ] || { echo "error: --pair requires two fixture slugs (blind then focused)" >&2; exit 1; }
      # An empty "$2"/"$3" (e.g. --pair "" foo) would otherwise satisfy the
      # count check above yet leave PAIR_A/PAIR_B empty -- every later
      # dispatch check in this script is `[ -n "$PAIR_A" ]`, so an empty
      # PAIR_A doesn't error at all, it silently skips run_pair_mode
      # entirely and runs the normal full-corpus sweep instead. Caught here
      # (not inside run_pair_mode, which would never even be reached).
      if [ -z "$2" ] || [ -z "$3" ]; then
        echo "error: --pair requires two NON-EMPTY fixture slugs" >&2
        exit 1
      fi
      PAIR_A="$2"; PAIR_B="$3"; shift 3 ;;
    --runs)
      # Overrides the default 3 runs/fixture -- needed for (a) cheaply
      # smoke-testing --pair/--only with 1 run instead of spending a full
      # 3, and (b) the higher-N (15-20) single-fixture sampling an
      # ensemble/variance probe needs, which 3 runs can't support at all.
      [ $# -ge 2 ] || { echo "error: --runs requires a positive integer" >&2; exit 1; }
      # A `case`/glob pattern is the WRONG tool here and was tried twice:
      # the negation '*[!0-9]*|0' only rejected a literal "0", not "00"/
      # "007" (both fed straight to `seq 1 000`, which this host's Apple
      # `seq` live-confirmed prints as TWO lines, "1" then "0" -- silently
      # running 2 iterations instead of rejecting); the follow-up accept-
      # list '[1-9]|[1-9][0-9]*' looked like "no leading zero" but a glob's
      # trailing `*` matches ANY character, not "more digits" -- live-
      # confirmed it also accepted "12abc", "12 34", and "12;3", which then
      # break `seq` in the same silent-zero-iterations way. `[[ =~ ]]`
      # (true regex, available since bash 3.0) is the actual fix: `$` anchors
      # the match so nothing after the digits can sneak through unchecked.
      if ! [[ "$2" =~ ^[1-9][0-9]*$ ]]; then
        echo "error: --runs must be a positive integer with no leading zero, got: $2" >&2
        exit 1
      fi
      RUNS_OVERRIDE="$2"; shift 2 ;;
    *)
      echo "error: unknown argument: $1" >&2
      exit 1 ;;
  esac
done
if [ -n "$PAIR_A" ] && [ -n "$ONLY" ]; then
  echo "error: --pair and --only are mutually exclusive" >&2
  exit 1
fi
RUNS_PER_FIXTURE="$DEFAULT_RUNS_PER_FIXTURE"
if [ -n "$RUNS_OVERRIDE" ]; then
  RUNS_PER_FIXTURE="$RUNS_OVERRIDE"
fi
if [ -n "$CORPUS_DIR_OVERRIDE" ]; then
  CORPUS_DIR="$CORPUS_DIR_OVERRIDE"
fi
if [ ! -d "$CORPUS_DIR" ]; then
  echo "error: corpus directory not found: $CORPUS_DIR" >&2
  exit 1
fi

# Best-effort corpus version label for manifest.json (see the per-run
# manifest write below) -- lets a saved result be traced back to which
# corpus content actually produced it. Deliberately conservative: reports
# "uncommitted" unless the corpus directory has ZERO uncommitted changes
# (git status --porcelain, which -- unlike `git describe --dirty` -- also
# catches untracked files, not just modified tracked ones) AND at least one
# file under it is actually tracked. Before eval/'s first commit (see the
# corpus-format-conversion plan item), this always resolves to "uncommitted"
# -- accurate, since there is genuinely no committed version yet to name.
#
# Every git call below runs with `-C "$CORPUS_DIR"` and a "." pathspec, NOT
# `-C "$SCRIPT_DIR"` with $CORPUS_DIR as an external pathspec argument --
# the whole point of --corpus-dir is to allow pointing at a DIFFERENT
# checkout/worktree (e.g. one checked out at the eval-corpus-v1 tag) that
# isn't necessarily inside this same repo at all. An earlier version used
# `-C "$SCRIPT_DIR" -- "$CORPUS_DIR"`, which fails outright for exactly that
# case -- live-confirmed: `git -C eval status --porcelain -- /etc/passwd`
# errors with "outside repository" when the path isn't under that repo.
# Rooting every git call directly at $CORPUS_DIR itself works for both the
# default (corpus/ inside this repo) and override (a separate worktree)
# cases uniformly.
CORPUS_VERSION="uncommitted"
if git -C "$CORPUS_DIR" rev-parse HEAD >/dev/null 2>&1 \
  && [ -z "$(git -C "$CORPUS_DIR" status --porcelain -- . 2>/dev/null)" ] \
  && [ -n "$(git -C "$CORPUS_DIR" ls-files -- . 2>/dev/null)" ]; then
  CORPUS_VERSION="$(git -C "$CORPUS_DIR" describe --tags --always 2>/dev/null)"
  [ -z "$CORPUS_VERSION" ] && CORPUS_VERSION="uncommitted"
fi

if [ ! -x "$REVIEW_SCRIPT" ]; then
  echo "error: review script not found or not executable at $REVIEW_SCRIPT" >&2
  exit 1
fi

CURRENT_TMP_REPO=""
REVIEW_OUT=""
JUDGE_PROMPT_FILE=""
JUDGE_EVENT_FILE=""
JUDGE_MSG_FILE=""
FAKE_GIT_HOME=""

cleanup_tmp_repo() {
  rm -rf "${CURRENT_TMP_REPO:-}"
  rm -rf "${FAKE_GIT_HOME:-}"
  # REVIEW_OUT (the per-run mktemp capturing the review call's stdout) has
  # no other cleanup path on a signal -- its only removal was the normal-path
  # `rm -f "$REVIEW_OUT"` right after being read, which an INT/TERM skips
  # entirely since on_signal exits before reaching it. Removing it here too
  # means every exit path (normal fall-through or a signal) cleans it up.
  rm -f "${REVIEW_OUT:-}"
  # Same reasoning for judge_finding's own temp files (see that function) --
  # its normal-path cleanup is skipped the same way on a signal mid-call.
  rm -f "${JUDGE_PROMPT_FILE:-}" "${JUDGE_EVENT_FILE:-}" "${JUDGE_MSG_FILE:-}"
}
trap cleanup_tmp_repo EXIT
# A separate INT/TERM trap that actually exits -- an EXIT-only trap runs its
# cleanup on a signal too, but then falls through and lets the script keep
# running (live-confirmed: `trap '...; ' EXIT INT TERM` with no `exit` inside
# resumes after cleanup instead of terminating). Matching
# scripts/run-codex-review.sh's own on_signal/cleanup split for the same
# reason. Also kills the in-flight review call (see below) -- without this,
# a signal arriving while synchronously waiting on that subprocess would
# otherwise not even reach this trap until the review call finishes on its
# own (up to its own 1800s timeout).
#
# Deliberately does NOT track the review PID in its own variable (an earlier
# revision did, as REVIEW_PID) -- that variable is live only between the
# `&` and the following `wait`, and killing it directly, unconditionally,
# whenever it's nonempty is unsafe: a signal arriving AFTER `wait` has
# already reaped the job but BEFORE the variable is reset back to empty
# would send TERM to that now-stale PID number, which the OS may have
# already recycled for an unrelated process by then -- live-confirmed on
# this machine's Bash 3.2.57 (`sleep 0.05 &`; `pid=$!`; `wait "$pid"` still
# leaves `$pid` holding the dead job's number with nothing to indicate it
# was already reaped). `jobs -p` avoids this entirely: it reads bash's own
# job table, which already reflects a just-backgrounded job before `$!` is
# even read (no gap to rely on manual tracking for) and is already emptied
# the moment `wait` reaps that job (no stale value can ever linger) --
# matching the exact mitigation scripts/run-codex-review.sh uses for its own
# CODEX_PID race (see its on_signal).
#
# Negative-PID (process-group) kill, not a plain same-PID kill: the main
# review call's job is $REVIEW_SCRIPT itself, which has its own INT/TERM
# trap that cleans up its own children, so a plain TERM to IT would be
# enough on its own -- but judge_finding's job is a DIRECT `codex exec`
# invocation (see that function) with no such wrapper of its own protecting
# it. `codex` is a Node wrapper that spawns the real review process (and an
# MCP host) as children -- a plain same-PID kill would leave those orphaned
# and still running a live API call, exactly the class of gap
# scripts/run-codex-review.sh's own kill_process_group() exists to close for
# ITS OWN direct codex exec call. `set -m` (enabled once, right after this
# trap, before anything is ever backgrounded) gives every job here its own
# process group, matching that wrapper's exact mechanism.
on_signal() {
  local job_pid
  for job_pid in $(jobs -p 2>/dev/null); do
    kill -TERM -"$job_pid" 2>/dev/null
  done
  cleanup_tmp_repo
  exit 130
}
trap on_signal INT TERM
# Must come after the trap above and before the FIRST background job
# anywhere in this script (the main review call, further down) -- see the
# on_signal comment above for why every backgrounded job here needs its own
# process group.
set -m

# A single, dedicated, always-empty directory used ONLY as a fake HOME for
# the isolation-snapshot's mutating git calls (see that section below) --
# NOT reused for anything else, and never containing fixture content, so a
# fixture that happened to include a file literally named ".gitconfig"
# couldn't inject config that way. Created once here (not per-fixture) since
# it's never written to and has no per-fixture state. Created AFTER both
# traps above are already installed (a round-5 review round caught an
# earlier version creating it BEFORE the traps existed -- a signal in that
# narrow window would leak this one empty directory, since the default
# signal disposition applies until a trap is actually registered).
FAKE_GIT_HOME="$(mktemp -d)"
if [ -z "$FAKE_GIT_HOME" ] || [ ! -d "$FAKE_GIT_HOME" ]; then
  echo "error: mktemp -d failed for isolated git HOME" >&2
  exit 1
fi

JUDGE_VERDICT=""
# A plain yes/no classification should never take anywhere near this long --
# generous but bounded, so a hung/stuck judge call can't block the sweep
# indefinitely the way it could with no ceiling at all (unlike the main
# review call, which relies on $REVIEW_SCRIPT's own internal 1800s timeout).
JUDGE_TIMEOUT_SECS=120

# judge_finding CONTEXT_LABEL ASSERTION QUESTION FINDING_TEXT PROMPT_AUDIT_PATH RESPONSE_AUDIT_PATH
# Neither control-group nor bug-fixture scoring can rely on keyword matching
# alone (three straight rounds of design review each found a control-group
# keyword set that either flagged a safe sentence describing the safeguard,
# or missed a genuinely bug-claiming one phrased differently; a full 63-run
# sweep separately found the SAME class of gap on the bug-fixture side --
# a model that correctly identified and even live-verified the exact seeded
# bug but phrased it with a synonym not in keywords_any was scored as a
# miss). Instead, each finding is judged individually by a separate,
# lightweight codex exec call asking only whether THAT finding matches the
# fixture's known assertion (a safeguard for control-group fixtures, a
# defect for bug fixtures) -- CONTEXT_LABEL and QUESTION let the same
# mechanics serve both framings without duplicating them.
# Sets the global JUDGE_VERDICT to exactly one of: yes | no | error. Also
# writes the exact prompt sent and codex's raw last-message response to
# PROMPT_AUDIT_PATH/RESPONSE_AUDIT_PATH (inside the run's own leak-safe
# result directory, alongside result.json/manifest.json) so a judge call
# can be audited after the fact instead of just trusted. A failure to write
# either audit file increments the shared ARTIFACT_WRITE_FAILURES counter,
# same as a result.json/manifest.json write failure -- the judgment is still
# used for scoring even if its audit trail couldn't be saved, but the final
# summary's "INCOMPLETE" note will say so.
#
# Called as a plain statement, never via $(...) -- capturing a whole
# function's output via command substitution forks it into a subshell, so
# JUDGE_PROMPT_FILE/JUDGE_EVENT_FILE/JUDGE_MSG_FILE (read by cleanup_tmp_repo
# on a signal arriving mid-call) would only ever be set in that subshell's
# own copy, never reaching the parent shell's copies that cleanup_tmp_repo
# actually looks at. Matches the same reasoning already documented for
# scripts/run-codex-review.sh's own mktemp_registered() helper.
judge_finding() {
  local context_label="$1" assertion="$2" question="$3" finding_text="$4" prompt_audit_path="$5" response_audit_path="$6"
  JUDGE_PROMPT_FILE="$(mktemp)"
  JUDGE_EVENT_FILE="$(mktemp)"
  JUDGE_MSG_FILE="$(mktemp)"
  # Same class of unchecked-mktemp gap fixed in the isolation-snapshot
  # section -- an empty path here would redirect into "" instead of a real
  # temp file. Never proceed to a real codex exec call on that basis.
  #
  # Clean up (and clear the globals) on this early-return path too, not just
  # the normal-path cleanup further down -- a PARTIAL failure (e.g. the
  # first two mktemp calls succeed, the third doesn't) would otherwise leak
  # the ones that DID succeed: this function is called once per finding, so
  # if the caller judges another finding afterward, the next call's mktemp
  # results overwrite these globals before cleanup_tmp_repo's EXIT-time
  # sweep ever sees the earlier, now-orphaned paths. `rm -f` on an empty
  # string argument is a harmless no-op, so this is safe to call
  # unconditionally regardless of which of the three actually succeeded.
  if [ -z "$JUDGE_PROMPT_FILE" ] || [ -z "$JUDGE_EVENT_FILE" ] || [ -z "$JUDGE_MSG_FILE" ]; then
    rm -f "$JUDGE_PROMPT_FILE" "$JUDGE_EVENT_FILE" "$JUDGE_MSG_FILE"
    JUDGE_PROMPT_FILE=""
    JUDGE_EVENT_FILE=""
    JUDGE_MSG_FILE=""
    JUDGE_VERDICT="error"
    return
  fi

  {
    echo "This code $context_label:"
    echo "\"$assertion\""
    echo ""
    echo "A code review produced this finding about the same code:"
    echo "---"
    printf '%s\n' "$finding_text"
    echo "---"
    echo ""
    echo "$question"
    echo "Reply with exactly one word, lowercase, no punctuation: yes or no."
  } > "$JUDGE_PROMPT_FILE"
  if ! cp "$JUDGE_PROMPT_FILE" "$prompt_audit_path" 2>/dev/null; then
    ARTIFACT_WRITE_FAILURES=$((ARTIFACT_WRITE_FAILURES + 1))
  fi

  # Backgrounded, with an explicit deadline-polling loop (mirroring
  # scripts/run-codex-review.sh's own CODEX_PID deadline loop) rather than a
  # bare `wait` -- this direct `codex exec` call has no wrapper of its own
  # imposing a ceiling, unlike the main review call. On timeout, negative-PID
  # TERM then KILL (process group, via the `set -m` enabled above) reaches
  # codex's own spawned children too, not just its top-level Node process --
  # the same reasoning as kill_process_group() in that wrapper. No
  # repository access or deep reasoning needed for a plain yes/no
  # classification -- read-only sandbox and low effort keep this call cheap;
  # --skip-git-repo-check since there's nothing to check out.
  codex exec --ephemeral --sandbox read-only --skip-git-repo-check --json \
    -c model_reasoning_effort="low" \
    --output-last-message "$JUDGE_MSG_FILE" \
    < "$JUDGE_PROMPT_FILE" > "$JUDGE_EVENT_FILE" 2>&1 &
  local judge_pid=$!
  local deadline=$((SECONDS + JUDGE_TIMEOUT_SECS))
  local timed_out=0
  while kill -0 "$judge_pid" 2>/dev/null; do
    if [ "$SECONDS" -ge "$deadline" ]; then
      timed_out=1
      kill -TERM -"$judge_pid" 2>/dev/null
      sleep 2
      kill -KILL -"$judge_pid" 2>/dev/null
      break
    fi
    sleep 1
  done
  wait "$judge_pid" 2>/dev/null
  local exit_code=$?

  local raw=""
  [ -s "$JUDGE_MSG_FILE" ] && raw="$(cat "$JUDGE_MSG_FILE")"
  if ! printf '%s' "$raw" > "$response_audit_path" 2>/dev/null; then
    ARTIFACT_WRITE_FAILURES=$((ARTIFACT_WRITE_FAILURES + 1))
  fi

  rm -f "$JUDGE_PROMPT_FILE" "$JUDGE_EVENT_FILE" "$JUDGE_MSG_FILE"
  JUDGE_PROMPT_FILE=""
  JUDGE_EVENT_FILE=""
  JUDGE_MSG_FILE=""

  if [ "$timed_out" -eq 1 ] || [ "$exit_code" -ne 0 ]; then
    JUDGE_VERDICT="error"
    return
  fi
  # Trim ONLY leading/trailing whitespace -- no case-folding, no internal
  # punctuation/whitespace stripping. The prompt above explicitly demands
  # EXACTLY one lowercase unpunctuated word; two earlier, progressively
  # stricter versions of this check each still fell short of that stated
  # contract (round 1: stripping all whitespace/punctuation let "yes." and
  # "y e s" collapse into a match; this round: case-folding via `tr` let
  # "YES"/"Yes" collapse into a match too -- live-confirmed both variants
  # normalize to "yes" before this fix). Never guess at a response that
  # doesn't match the requested format byte-for-byte (after only trimming
  # incidental leading/trailing whitespace) -- treat it as an error, same
  # principle as the timeout/exit-code checks above.
  local normalized
  normalized="$(printf '%s' "$raw" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
  case "$normalized" in
    yes) JUDGE_VERDICT="yes" ;;
    no) JUDGE_VERDICT="no" ;;
    *) JUDGE_VERDICT="error" ;;
  esac
}

FIXTURE_NAMES=()
FIXTURE_CATEGORIES=()
FIXTURE_DIFFICULTY=()
FIXTURE_SHOULD_FLAG=()
FIXTURE_HITS=()
# Lexical-only hit count, parallel to FIXTURE_HITS -- see the lexical_hits
# local variable's own comment in the should_flag=="true" scoring branch
# below for what distinguishes the two.
FIXTURE_LEXICAL_HITS=()
FIXTURE_VALID=()
# Lexical metric's OWN denominator, parallel to FIXTURE_VALID -- a /cc
# round-2 finding disproved this array's original comment here, which had
# claimed lexical scoring could safely share FIXTURE_VALID with the
# semantic metric ("a run is either scoreable or it isn't"). That's false:
# lexical scoring is pure jq and always completes the moment the review
# call itself succeeds, but the semantic judge fallback can independently
# fail (timeout, non-yes/no response) on a run that was ALREADY a fully-
# computed, genuine lexical miss -- decrementing the shared FIXTURE_VALID
# in that case silently erased that miss from the lexical denominator too,
# inflating lexical recall. See the lexical_valid local variable's own
# comment for the fix.
FIXTURE_LEXICAL_VALID=()
FIXTURE_ERRORS=()
MATCHED=0
ARTIFACT_WRITE_FAILURES=0
# Counts fixtures skipped entirely due to a configuration error (currently:
# a control-group fixture missing/invalid safeguard_assertion) -- distinct
# from FIXTURE_ERRORS (per-run wrapper/judge failures on a fixture that DID
# run). A skipped fixture never gets a FIXTURE_* array entry at all, so it
# would otherwise vanish from every denominator above with only an easy-to-
# miss stderr `skip:` line during a long sweep as the only trace. Surfaced
# prominently in the final summary below so a partially-successful sweep
# (some fixtures scored, this one silently absent) can't be mistaken for a
# complete one.
CONFIG_ERROR_COUNT=0

# score_pair_member SLUG MUST_FILE DEFECT_ASSERTION FOCUS SNAPSHOT_REPO SNAPSHOT_SHA RUN_N [KEYWORD ...]
# Runs ONE review call for one blind/focused pair member against the
# SHARED snapshot built by run_pair_mode, saves the same result.json/
# manifest.json artifacts the main loop saves, scores it via the same
# bug-fixture (file+keyword, falling back to judge_finding against
# DEFECT_ASSERTION when the lexical check misses but a finding still names
# MUST_FILE) logic as the main loop's should_flag=="true" branch -- a /cc
# round-1 finding caught that this function had been left lexical-only
# after R5 added the semantic fallback to the main loop but not here.
# run_pair_mode has already asserted should_flag=="true" for both members
# before this is ever called, so the control-group judge_finding branch
# never applies here. Sets the global PAIR_RUN_OUTCOME to exactly one of:
# hit | miss | error. Any keywords are trailing positional args (possibly
# zero of them), NOT a global array like judge_finding's JUDGE_VERDICT --
# unlike a single scalar result (which bash 3.2, this script's stated
# compatibility floor, has no `local -n`/nameref to return by reference),
# an array of caller-owned strings passes through "$@" natively and needs
# no such workaround.
score_pair_member() {
  local slug="$1" must_file="$2" defect_assertion="$3" focus="$4" snapshot_repo="$5" snapshot_sha="$6" run_n="$7"
  shift 7

  REVIEW_OUT="$(mktemp)"
  if [ -z "$REVIEW_OUT" ]; then
    echo "  [$slug] run $run_n: ERROR (mktemp failed) -- excluded from scoring" >&2
    PAIR_RUN_OUTCOME="error"
    return
  fi
  if [ -n "$focus" ]; then
    "$REVIEW_SCRIPT" --cwd "$snapshot_repo" --commit "$snapshot_sha" --focus "$focus" > "$REVIEW_OUT" 2>&1 &
  else
    "$REVIEW_SCRIPT" --cwd "$snapshot_repo" --commit "$snapshot_sha" > "$REVIEW_OUT" 2>&1 &
  fi
  wait "$!"
  local result
  result="$(cat "$REVIEW_OUT")"
  rm -f "$REVIEW_OUT"
  REVIEW_OUT=""

  local run_id run_dir
  run_id="${slug}-run${run_n}"
  run_dir="$SUITE_DIR/$run_id"
  mkdir "$run_dir" || { echo "error: run-id collision at $run_dir" >&2; exit 1; }
  if ! printf '%s' "$result" > "$run_dir/result.json"; then
    echo "  warning: failed to write raw result artifact for $run_id (disk full/permission?)" >&2
    ARTIFACT_WRITE_FAILURES=$((ARTIFACT_WRITE_FAILURES + 1))
  fi
  local focus_sha256=""
  if [ -n "$focus" ]; then
    focus_sha256="$(printf '%s' "$focus" | shasum -a 256 | awk '{print $1}')"
  fi
  if ! jq -n \
    --arg fixture "$slug" \
    --argjson run "$run_n" \
    --arg snapshot_sha "$snapshot_sha" \
    --arg corpus_version "$CORPUS_VERSION" \
    --arg focus_sha256 "$focus_sha256" \
    --arg timestamp_utc "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg reasoning_effort "xhigh (fixed by run-codex-review.sh, not configurable from here)" \
    '{fixture: $fixture, run: $run, snapshot_sha: $snapshot_sha, corpus_version: $corpus_version,
      focus_sha256: (if $focus_sha256 == "" then null else $focus_sha256 end),
      timestamp_utc: $timestamp_utc, reasoning_effort: $reasoning_effort}' \
    > "$run_dir/manifest.json"; then
    echo "  warning: failed to write manifest for $run_id (disk full/permission?)" >&2
    ARTIFACT_WRITE_FAILURES=$((ARTIFACT_WRITE_FAILURES + 1))
  fi

  local ok
  ok="$(printf '%s' "$result" | jq -r '.ok')"
  if [ "$ok" != "true" ]; then
    local reason
    reason="$(printf '%s' "$result" | jq -r '.reason // "unknown"')"
    echo "  [$slug] run $run_n: ERROR (wrapper failure: $reason) -- excluded from scoring"
    PAIR_RUN_OUTCOME="error"
    return
  fi

  local verdict
  verdict="$(printf '%s' "$result" | jq -r '.verdict.verdict')"
  local file_hit
  file_hit="$(printf '%s' "$result" | jq -r --arg f "$must_file" '
    [.verdict.findings[] | select(.file | contains($f))] | length > 0
  ')"
  local is_hit="false"
  if [ "$file_hit" = "true" ]; then
    if [ "$#" -eq 0 ]; then
      is_hit="true"
    else
      local kw match
      for kw in "$@"; do
        match="$(printf '%s' "$result" | jq -r --arg f "$must_file" --arg kw "$kw" '
          [.verdict.findings[]
           | select(.file | contains($f))
           | select(((.summary // "") + " " + (.evidence // "")) | ascii_downcase | contains($kw | ascii_downcase))
          ] | length > 0
        ')"
        if [ "$match" = "true" ]; then
          is_hit="true"
          break
        fi
      done
    fi
  fi

  if [ "$file_hit" = "true" ] && [ "$is_hit" != "true" ]; then
    # Semantic fallback, mirroring the main loop's should_flag=="true"
    # branch exactly (see its own comment for the full reasoning): the
    # lexical keyword check above already ran and missed, but a finding
    # still names must_file, so judge each such finding individually
    # against defect_assertion rather than scoring this run a flat miss.
    local matching_findings judge_idx any_yes any_error finding_json finding_text
    matching_findings="$(printf '%s' "$result" | jq -c --arg f "$must_file" '
      [.verdict.findings[] | select(.file | contains($f))]
    ')"
    judge_idx=0
    any_yes="false"
    any_error="false"
    while IFS= read -r finding_json; do
      judge_idx=$((judge_idx + 1))
      finding_text="$(printf '%s' "$finding_json" | jq -r '(.summary // "") + "\n" + (.evidence // "")')"
      judge_finding "has the following known defect" \
        "$defect_assertion" \
        "Does this finding identify the defect described above, even if phrased differently or using different terminology?" \
        "$finding_text" \
        "$run_dir/semantic-judge-${judge_idx}.prompt.txt" "$run_dir/semantic-judge-${judge_idx}.response.txt"
      case "$JUDGE_VERDICT" in
        yes) any_yes="true" ;;
        error) any_error="true" ;;
      esac
    done < <(printf '%s' "$matching_findings" | jq -c '.[]')

    if [ "$any_error" = "true" ]; then
      echo "  [$slug] run $run_n: ERROR (semantic judge call failed or gave a non-yes/no response) -- excluded from scoring"
      PAIR_RUN_OUTCOME="error"
      return
    elif [ "$any_yes" = "true" ]; then
      is_hit="true"
    fi
  fi

  if [ "$is_hit" = "true" ]; then
    echo "  [$slug] run $run_n: HIT (verdict=$verdict)"
    PAIR_RUN_OUTCOME="hit"
  else
    echo "  [$slug] run $run_n: miss (verdict=$verdict)"
    PAIR_RUN_OUTCOME="miss"
  fi
}

# run_pair_mode SLUG_A SLUG_B
# Compares a blind/focused fixture pair under two controls the main loop's
# per-fixture-in-isolation execution can't provide: (1) both members share
# ONE isolation snapshot (same --cwd, same commit SHA, same fixed commit
# metadata) instead of each building its own -- this eliminates a spurious
# extra variable in the comparison (the plan's own round-12 finding: with
# separate mktemp -d snapshots the two calls' CWD path strings differ, which
# a sufficiently thorough --sandbox read-only review could in principle
# notice, however unlikely). (2) runs are INTERLEAVED (member-A run 1,
# member-B run 1, member-A run 2, ...) rather than all-of-A-then-all-of-B,
# reducing any time-based confound (model/backend state drift between the
# two members' full run sequences).
#
# Exits non-zero on any pair-invariant violation (missing fixture, a nested
# .git under before/, before/ content differing between members, or
# must_mention_file/keywords_any/should_flag differing between members) --
# a broken pair produces a meaningless comparison, so this refuses to run
# rather than silently scoring one anyway.
run_pair_mode() {
  local slug_a="$1" slug_b="$2"
  # A slug is a bare corpus/ directory NAME, never a path -- reject anything
  # containing a "/" (which would let a value like "../../etc" resolve
  # dir_a/before_a OUTSIDE $CORPUS_DIR below) or "." / ".." themselves
  # (which resolve to CORPUS_DIR itself or its parent). Also blocks the
  # same characters from later reaching run_id ("$slug-run$run_n") and
  # escaping $SUITE_DIR when score_pair_member creates its run_dir.
  local s
  for s in "$slug_a" "$slug_b"; do
    case "$s" in
      */*|.|..)
        echo "error: --pair argument must be a bare fixture directory name, not a path: $s" >&2
        exit 1 ;;
    esac
  done
  local dir_a="$CORPUS_DIR/$slug_a" dir_b="$CORPUS_DIR/$slug_b"
  local exp_a="$dir_a/expected.json" exp_b="$dir_b/expected.json"
  local before_a="$dir_a/before" before_b="$dir_b/before"

  local d
  for d in "$dir_a" "$dir_b"; do
    # `[ -d ]` alone FOLLOWS a symlink -- the slug-shape check above blocks
    # a lexical path-escape ("../etc") but not a fixture-root name that is
    # itself a symlink pointing outside $CORPUS_DIR (relevant mainly with
    # --corpus-dir pointing at an arbitrary tree, not this repo's own
    # hand-authored corpus/, which has no such symlinks). `-L` rejects that
    # case outright rather than silently following it.
    if [ -L "$d" ]; then
      echo "error: --pair fixture directory is a symlink, refusing to follow: $d" >&2
      exit 1
    fi
    [ -d "$d" ] || { echo "error: --pair fixture not found: $d" >&2; exit 1; }
  done
  local f
  for f in "$exp_a" "$exp_b"; do
    # Same reasoning as the fixture-root check above -- the root itself
    # being a real directory doesn't guarantee expected.json inside it
    # isn't ITSELF a symlink to something outside $CORPUS_DIR.
    if [ -L "$f" ]; then
      echo "error: --pair fixture's expected.json is a symlink, refusing to follow: $f" >&2
      exit 1
    fi
    [ -f "$f" ] || { echo "error: --pair fixture missing expected.json: $f" >&2; exit 1; }
  done
  local b
  for b in "$before_a" "$before_b"; do
    if [ -L "$b" ]; then
      echo "error: --pair fixture's before/ is a symlink, refusing to follow: $b" >&2
      exit 1
    fi
    [ -d "$b" ] || { echo "error: --pair fixture missing before/: $b" >&2; exit 1; }
    # Same corpus-format invariant the main loop enforces (see its own
    # comment for the two distinct gitlink-related risks this closes).
    local found_nested_git
    found_nested_git="$(find "$b" -name '.git' -print -quit 2>/dev/null)"
    if [ -n "$found_nested_git" ]; then
      echo "error: --pair fixture before/ contains a .git at '$found_nested_git'" >&2
      exit 1
    fi
  done

  for f in "$exp_a" "$exp_b"; do
    # must_mention_file: trimmed non-empty (gsub("\\s";"") | length > 0), not
    # plain length > 0 -- matches safeguard_assertion's existing whitespace-
    # only guard below, closing the same class of gap for this field: a
    # value that is JSON-valid and non-empty (e.g. a lone "\n") but decodes
    # via `jq -r`+command-substitution to bash as an EMPTY variable (command
    # substitution silently strips trailing newlines) would otherwise slip
    # through as must_file="", and `contains("")` matches every string --
    # turning "any finding on any file" into a fabricated hit for every run.
    # Also NUL-free (same codepoint check as keywords_any below) -- a value
    # with an embedded NUL would decode to a shorter, different bash string
    # than the fixture author wrote, and could fabricate a hit the same way.
    if ! jq -e '(.category | type == "string" and ((gsub("\\s"; "")) | length > 0)) and (.difficulty == null or .difficulty == "easy" or .difficulty == "subtle") and (.should_flag | type == "boolean") and (.must_mention_file | type == "string" and (explode | any(. == 0) | not) and ((gsub("\\s"; "")) | length > 0))' "$f" >/dev/null 2>&1; then
      echo "error: --pair fixture expected.json malformed or missing required fields: $f" >&2
      exit 1
    fi
    # keywords_any: each entry must be a string with real (non-whitespace)
    # content, same reasoning as must_mention_file above, AND must not
    # contain a NUL byte -- Bash variables cannot represent NUL at all
    # (live-confirmed: a NUL inside a captured string is silently dropped,
    # not preserved or erred on), so a keyword whose JSON value is
    # "a" + NUL + "b" would reach scoring as plain "ab" -- a keyword the
    # fixture author never actually wrote.
    if ! jq -e '.keywords_any == null or (.keywords_any | type == "array" and all(.[]; type == "string" and ((explode | any(. == 0) | not)) and ((gsub("\\s"; "")) | length > 0)))' "$f" >/dev/null 2>&1; then
      echo "error: --pair fixture expected.json keywords_any must be null or an array of non-empty, NUL-free strings: $f" >&2
      exit 1
    fi
    # Pair mode's blind/focused labeling is a stronger contract than the
    # main loop's plain optional-context use of "focus" -- a non-string
    # value here (e.g. JSON `true`) would still be silently coerced to
    # text by `jq -r '.focus // empty'` below and pass the later non-
    # whitespace role check, mislabeling a malformed fixture as a valid
    # "focused" member. Caught here instead, before that coercion happens.
    # Also NUL-free (same codepoint check as must_mention_file/keywords_any)
    # -- Bash's command-substitution capture below truncates at a NUL, so a
    # fixture could specify one briefing while the reviewer actually
    # receives a shorter, silently different one.
    if ! jq -e '.focus == null or (.focus | type == "string" and (explode | any(. == 0) | not))' "$f" >/dev/null 2>&1; then
      echo "error: --pair fixture expected.json focus must be null or a NUL-free string: $f" >&2
      exit 1
    fi
    # defect_assertion: required for --pair too -- a /cc round-1 finding
    # caught that this validation (and the semantic fallback it feeds) had
    # been added to the main loop's should_flag=="true" scoring but never
    # to run_pair_mode/score_pair_member, which also scores should_flag==
    # true fixtures and had silently stayed lexical-only. Same contract as
    # the main loop's own defect_assertion check (see its comment for why:
    # type/NUL/whitespace-only guards).
    if ! jq -e '.defect_assertion | (type == "string" and (explode | any(. == 0) | not) and ((gsub("\\s"; "")) | length > 0))' "$f" >/dev/null 2>&1; then
      echo "error: --pair fixture expected.json missing/invalid defect_assertion: $f" >&2
      exit 1
    fi
  done

  # Pair invariant #1: before/ must be byte-identical -- otherwise a recall
  # difference could come from the code differing, not from --focus.
  if ! diff -rq "$before_a" "$before_b" >/dev/null 2>&1; then
    echo "error: --pair fixtures' before/ directories differ -- this pair is not a valid blind/focused" >&2
    echo "comparison (recall differences would be confounded with code differences). diff -rq:" >&2
    diff -rq "$before_a" "$before_b" >&2
    exit 1
  fi

  # Pair invariant #2: the scoring contract itself must be identical -- a
  # `diff -rq` above only proves the SOURCE is identical, not that both
  # members would be scored the same way (round-9 plan finding).
  local fields_a fields_b
  fields_a="$(jq -Sc '{must_mention_file, keywords_any, should_flag, defect_assertion}' "$exp_a")"
  fields_b="$(jq -Sc '{must_mention_file, keywords_any, should_flag, defect_assertion}' "$exp_b")"
  if [ "$fields_a" != "$fields_b" ]; then
    echo "error: --pair fixtures' must_mention_file/keywords_any/should_flag/defect_assertion differ:" >&2
    echo "  $slug_a: $fields_a" >&2
    echo "  $slug_b: $fields_b" >&2
    exit 1
  fi

  local should_flag must_file defect_assertion focus_a focus_b
  should_flag="$(jq -r '.should_flag' "$exp_a")"
  must_file="$(jq -r '.must_mention_file' "$exp_a")"
  defect_assertion="$(jq -r '.defect_assertion' "$exp_a")"
  focus_a="$(jq -r '.focus // empty' "$exp_a")"
  focus_b="$(jq -r '.focus // empty' "$exp_b")"
  if [ "$should_flag" != "true" ]; then
    echo "error: --pair mode only supports should_flag==true (bug) fixture pairs; got should_flag=$should_flag" >&2
    exit 1
  fi
  # Pair invariant #3: the CLI's own contract is "--pair BLIND FOCUSED" (see
  # its own help text above and the "blind"/"focused" labels in the
  # scorecard below) -- nothing enforced that ordering until now, so
  # --pair X X (same fixture twice) or two focused/two blind members would
  # have silently passed every check above and produced a meaningless
  # comparison mislabeled as blind-vs-focused. focus_b's side additionally
  # requires at least one NON-whitespace character (`[^[:space:]]`), not
  # just "non-empty" (`-n`) -- a whitespace-only focus like "   " passes
  # `-n` (live-confirmed) despite supplying no actual briefing, which would
  # have let a focused member with a blank/whitespace focus still pass this
  # guard and be scored as a real blind-vs-focused comparison. focus_a's
  # side needs no matching whitespace-only case: `-n` on "   " is already
  # true (any non-empty string, whitespace or not), so a whitespace-only
  # focus_a already correctly fails "must have no focus" via the same `-n`
  # check used today.
  if [ -n "$focus_a" ] || ! [[ "$focus_b" =~ [^[:space:]] ]]; then
    echo "error: --pair requires the FIRST fixture ($slug_a) to have no focus (blind) and the" >&2
    echo "SECOND ($slug_b) to have a non-empty, non-whitespace focus (focused); got focus_a=$([ -n "$focus_a" ] && echo "set" || echo "empty"), focus_b=$([[ "$focus_b" =~ [^[:space:]] ]] && echo "set" || echo "empty/whitespace-only")" >&2
    exit 1
  fi

  # Keywords are passed to score_pair_member as TRAILING positional args
  # (after its six fixed params), not a global array -- unlike JUDGE_VERDICT
  # (a genuinely scalar per-call result judge_finding has no other way to
  # return under bash 3.2, which lacks nameref/`local -n`), an array of
  # keyword strings passes through "$@"/"${@:N}" natively, live-confirmed on
  # this host's bash 3.2.57 to preserve each keyword (including ones
  # containing spaces) as a distinct argument.
  # `jq -c` (compact JSON, one array element per line), not `jq -r` (raw
  # unescaped text) -- a keyword string containing a literal embedded
  # newline would print as a raw newline under `-r`, which `read` (line-
  # delimited) then splits into two shorter keywords instead of one. `-c`
  # keeps the JSON string escaping (embedded "\n" stays as the two
  # characters backslash-n, never a real line break) so each array element
  # is guaranteed to occupy exactly one line regardless of its content.
  #
  # Decoding that one line back to the real string needs `jq -j` (no
  # trailing newline of its own), NOT `jq -r` (which DOES append one) --
  # `$(...)` unconditionally strips ALL trailing newlines from a command
  # substitution's output, live-confirmed to silently: (a) drop a keyword
  # that is nothing but a newline down to an empty string (which
  # `[ -n "$kw" ]` then discards entirely -- if that were the fixture's
  # ONLY keyword, the whole array goes empty, which this scoring treats as
  # "any file match is a hit"), and (b) strip a real trailing newline off
  # the END of an otherwise-normal keyword. Appending a literal "x" right
  # after jq's (newline-free, via -j) output and stripping it back off
  # with `${raw%x}` works around this: the substitution's last character is
  # always "x", never a newline, so nothing gets silently eaten regardless
  # of how many (if any) real newlines the decoded string starts or ends
  # with. Live-confirmed exact round-trip for a plain keyword, one ending
  # in "\n", one that IS "\n", and one with an embedded "\n" in the middle.
  local pair_keywords=()
  local kw_json_line kw_raw kw
  while IFS= read -r kw_json_line; do
    kw_raw="$(jq -j '.' <<< "$kw_json_line"; printf 'x')"
    kw="${kw_raw%x}"
    [ -n "$kw" ] && pair_keywords+=("$kw")
  done < <(jq -c '(.keywords_any // [])[]' "$exp_a")

  # Shared isolation snapshot, built once from before_a (already verified
  # byte-identical to before_b above). Reuses the exact same construction
  # the main loop uses (see its own "Isolation snapshot" comment for the
  # reasoning behind each step) via the same FAKE_GIT_HOME/traps already
  # set up before this function is ever called -- GIT_ISOLATED_ENV itself
  # is redefined locally rather than shared with the main loop's copy since
  # the main loop only ever defines it INSIDE its own per-fixture iteration
  # (never before it, so there is nothing global to reuse here) and this
  # function's dispatch site runs before that loop even starts.
  local git_isolated_env
  git_isolated_env=(env -i "PATH=$PATH" "HOME=$FAKE_GIT_HOME" "GIT_CONFIG_NOSYSTEM=1")

  CURRENT_TMP_REPO="$(mktemp -d)"
  if [ -z "$CURRENT_TMP_REPO" ] || [ ! -d "$CURRENT_TMP_REPO" ]; then
    echo "error: --pair mktemp -d failed, refusing to build isolation snapshot" >&2
    CURRENT_TMP_REPO=""
    exit 1
  fi
  if ! cp -R "${before_a}/." "$CURRENT_TMP_REPO/"; then
    echo "error: --pair failed to copy before/ into isolation snapshot" >&2
    rm -rf "$CURRENT_TMP_REPO"
    CURRENT_TMP_REPO=""
    exit 1
  fi
  "${git_isolated_env[@]}" git -C "$CURRENT_TMP_REPO" init -q -b main
  "${git_isolated_env[@]}" git -C "$CURRENT_TMP_REPO" config user.email "eval@example.com"
  "${git_isolated_env[@]}" git -C "$CURRENT_TMP_REPO" config user.name "Eval Corpus"
  "${git_isolated_env[@]}" git -C "$CURRENT_TMP_REPO" add -A -f
  if ! env -i "PATH=$PATH" "HOME=$FAKE_GIT_HOME" "GIT_CONFIG_NOSYSTEM=1" \
    "GIT_AUTHOR_DATE=2026-01-01T00:00:00+0000" "GIT_COMMITTER_DATE=2026-01-01T00:00:00+0000" \
    git -C "$CURRENT_TMP_REPO" commit -q --no-verify -m "fixture snapshot"; then
    echo "error: --pair git commit failed -- before/ may be empty" >&2
    rm -rf "$CURRENT_TMP_REPO"
    CURRENT_TMP_REPO=""
    exit 1
  fi
  local snapshot_sha
  snapshot_sha="$(git -C "$CURRENT_TMP_REPO" rev-parse HEAD)"

  echo "=== PAIR: $slug_a (blind) vs $slug_b (focused) -- shared snapshot $snapshot_sha ==="

  local hits_a=0 valid_a=0 errors_a=0
  local hits_b=0 valid_b=0 errors_b=0
  local run_n
  for run_n in $(seq 1 "$RUNS_PER_FIXTURE"); do
    # Built as an array (rather than expanding "${pair_keywords[@]}" inline
    # at each call site) so a fixture with keywords_any==null -- valid per
    # this function's own validation above, which leaves pair_keywords
    # empty -- never reaches a bare "${pair_keywords[@]}" expansion under
    # this script's `set -u`/bash-3.2 floor: a /cc round-1 finding live-
    # confirmed that exact expansion crashes with "unbound variable" (exit
    # 127) on an explicitly-empty array, the same class of gap fixed once
    # already in scripts/run-codex-review.sh's TRACKED_BINARY_PATHS.
    local score_args
    score_args=("$slug_a" "$must_file" "$defect_assertion" "$focus_a" "$CURRENT_TMP_REPO" "$snapshot_sha" "$run_n")
    [ "${#pair_keywords[@]}" -gt 0 ] && score_args+=("${pair_keywords[@]}")
    score_pair_member "${score_args[@]}"
    case "$PAIR_RUN_OUTCOME" in
      hit) hits_a=$((hits_a + 1)); valid_a=$((valid_a + 1)) ;;
      miss) valid_a=$((valid_a + 1)) ;;
      error) errors_a=$((errors_a + 1)) ;;
    esac
    score_args=("$slug_b" "$must_file" "$defect_assertion" "$focus_b" "$CURRENT_TMP_REPO" "$snapshot_sha" "$run_n")
    [ "${#pair_keywords[@]}" -gt 0 ] && score_args+=("${pair_keywords[@]}")
    score_pair_member "${score_args[@]}"
    case "$PAIR_RUN_OUTCOME" in
      hit) hits_b=$((hits_b + 1)); valid_b=$((valid_b + 1)) ;;
      miss) valid_b=$((valid_b + 1)) ;;
      error) errors_b=$((errors_b + 1)) ;;
    esac
  done

  rm -rf "$CURRENT_TMP_REPO"
  CURRENT_TMP_REPO=""

  echo ""
  echo "=== PAIR SCORECARD: $slug_a vs $slug_b ==="
  printf '  %-40s %d/%d hits (%d errors)\n' "$slug_a (blind)" "$hits_a" "$valid_a" "$errors_a"
  printf '  %-40s %d/%d hits (%d errors)\n' "$slug_b (focused)" "$hits_b" "$valid_b" "$errors_b"
  echo ""
  if [ "$ARTIFACT_WRITE_FAILURES" -eq 0 ]; then
    echo "Raw per-run results and manifests saved to: $SUITE_DIR"
  else
    echo "Raw per-run results saved to: $SUITE_DIR (INCOMPLETE -- $ARTIFACT_WRITE_FAILURES artifact write(s) failed, see warnings above)"
  fi
}

if [ -n "$PAIR_A" ]; then
  run_pair_mode "$PAIR_A" "$PAIR_B"
  exit $?
fi

for fixture_dir in "$CORPUS_DIR"/*/; do
  slug="$(basename "$fixture_dir")"
  if [ -n "$ONLY" ] && [ "$slug" != "$ONLY" ]; then
    continue
  fi

  expected_file="${fixture_dir}expected.json"
  before_dir="${fixture_dir}before"
  # `[ -f ]`/`[ -d ]` alone FOLLOW a symlink -- relevant only with
  # --corpus-dir pointing at an arbitrary tree (this repo's own corpus/ has
  # no such symlinks), matching run_pair_mode's identical defense (same
  # file, its own comment has the full reasoning).
  if [ -L "$expected_file" ] || [ -L "$before_dir" ]; then
    echo "skip: $slug (expected.json or before/ is a symlink, refusing to follow)" >&2
    CONFIG_ERROR_COUNT=$((CONFIG_ERROR_COUNT + 1))
    continue
  fi
  if [ ! -f "$expected_file" ] || [ ! -d "$before_dir" ]; then
    echo "skip: $slug (missing expected.json or before/)" >&2
    continue
  fi

  # before/ must not contain a .git ANYWHERE under it (not just at its own
  # top level) -- a corpus format invariant (see the header comment)
  # enforced here, not just assumed. Two distinct risks, both closed by one
  # recursive check: (a) a top-level `.git` could be a "gitfile" (a plain
  # text file containing `gitdir: <path>`, per gitrepository-layout(5))
  # pointing at a repository OUTSIDE this fixture entirely -- `git init` on
  # top of one reinitializes/reuses whatever it points to instead of
  # creating a fresh one; (b) a NESTED `.git` (e.g. before/subdir/.git,
  # which an earlier, top-level-only version of this check missed -- a /cc
  # review round caught that gap) makes `git add` treat that subdirectory as
  # an embedded repository and stage it as a gitlink (a bare commit-hash
  # pointer) instead of committing its actual file contents -- silently
  # dropping that subtree's real source from the snapshot the model reviews.
  # This is the EXACT SAME gitlink problem the whole corpus-format
  # conversion (nested-git-repo -> before/) exists to eliminate; missing it
  # for a nested case would let it resurface one directory level down. The
  # corpus is presently trusted/hand-authored with no fixture triggering
  # this, but --corpus-dir accepts an arbitrary tree, so this invariant is
  # worth checking rather than only documenting.
  found_nested_git="$(find "$before_dir" -name '.git' -print -quit 2>/dev/null)"
  if [ -n "$found_nested_git" ]; then
    echo "skip: $slug (before/ contains a .git at '$found_nested_git' -- corpus format invariant violated)" >&2
    CONFIG_ERROR_COUNT=$((CONFIG_ERROR_COUNT + 1))
    continue
  fi

  # A malformed or wrong-typed expected.json is a configuration error, not
  # something to score through: `jq -r` on a parse failure emits an empty
  # string with no exit-status check downstream (live-confirmed: `printf
  # '{' | jq -r '.should_flag'` yields an empty value), which would
  # otherwise fall through into the should_flag=="false" control-group
  # branch with an EMPTY must_file -- and `contains("")` is true for every
  # string (live-confirmed), so every finding would spuriously "match" and
  # get fabricated scoring instead of the fixture being rejected outright.
  # must_mention_file: trimmed non-empty, not plain length > 0 -- see
  # run_pair_mode's identical check (same file) for why: a JSON-valid,
  # non-empty value (e.g. a lone newline) can still decode to an EMPTY bash
  # variable further down (command substitution strips trailing newlines),
  # and `contains("")` matches every string -- silently fabricating a hit
  # on every file for a fixture that should have been rejected outright.
  if ! jq -e '(.category | type == "string" and ((gsub("\\s"; "")) | length > 0)) and (.difficulty == null or .difficulty == "easy" or .difficulty == "subtle") and (.should_flag | type == "boolean") and (.must_mention_file | type == "string" and (explode | any(. == 0) | not) and ((gsub("\\s"; "")) | length > 0))' "$expected_file" >/dev/null 2>&1; then
    echo "skip: $slug (expected.json malformed or missing required fields: category/difficulty/should_flag/must_mention_file)" >&2
    CONFIG_ERROR_COUNT=$((CONFIG_ERROR_COUNT + 1))
    continue
  fi
  # keywords_any specifically: a wrong-typed value (e.g. a plain string
  # instead of an array) passes the check above (that check doesn't touch
  # this field at all) but silently breaks the keyword-reading loop further
  # down, which runs inside unchecked process substitution -- live-confirmed
  # a string value there produces a jq iteration failure that the loop
  # simply swallows, leaving `keywords` empty. An empty `keywords` array is
  # legitimate when the field is genuinely absent (every keyword vacuously
  # matches, by design), but here it would be a MISCONFIGURED fixture
  # masquerading as one with no keyword requirement, silently turning any
  # file-only match into a hit for a bug fixture that was supposed to be
  # keyword-checked. Each entry additionally requires trimmed non-empty
  # content (same must_mention_file reasoning) and must contain no NUL
  # character (checked via character codepoints, not a literal NUL/escape
  # in this source file) -- Bash cannot represent NUL in a variable at all,
  # so a keyword containing one would silently score as a shorter, different
  # string than the fixture author actually wrote.
  if ! jq -e '.keywords_any == null or (.keywords_any | type == "array" and all(.[]; type == "string" and ((explode | any(. == 0) | not)) and ((gsub("\\s"; "")) | length > 0)))' "$expected_file" >/dev/null 2>&1; then
    echo "skip: $slug (expected.json keywords_any must be null or an array of non-empty, NUL-free strings)" >&2
    CONFIG_ERROR_COUNT=$((CONFIG_ERROR_COUNT + 1))
    continue
  fi
  # focus: unlike pair mode's stronger blind/focused-role contract, the
  # main loop treats focus as purely optional context, so a malformed
  # (non-string) value doesn't misrepresent a comparison the way it would
  # in --pair -- but it should still be rejected outright rather than
  # silently coerced (JSON `true` becoming the literal briefing text
  # "true") or silently treated as absent (JSON `false` becoming empty).
  if ! jq -e '.focus == null or (.focus | type == "string" and (explode | any(. == 0) | not))' "$expected_file" >/dev/null 2>&1; then
    echo "skip: $slug (expected.json focus must be null or a string)" >&2
    CONFIG_ERROR_COUNT=$((CONFIG_ERROR_COUNT + 1))
    continue
  fi

  MATCHED=$((MATCHED + 1))
  category="$(jq -r '.category' "$expected_file")"
  difficulty="$(jq -r '.difficulty // "n/a"' "$expected_file")"
  should_flag="$(jq -r '.should_flag' "$expected_file")"
  must_file="$(jq -r '.must_mention_file // empty' "$expected_file")"
  # Optional: a fixture may carry a rich --focus briefing (see the
  # 20/21 context-intent pair) to test whether context actually helps catch
  # a bug that looks locally correct without it. Absent for every other
  # fixture, which keeps their review calls identical to plain --commit use.
  focus="$(jq -r '.focus // empty' "$expected_file")"

  safeguard_assertion=""
  if [ "$should_flag" = "false" ]; then
    # Required for every control-group fixture (see judge_finding above) --
    # validated as an actual non-empty string, not just "key present", since
    # `jq -r` silently returns "" or "null" for a missing/wrong-typed field
    # rather than erroring, which would otherwise let a misconfigured
    # fixture's judge calls run against an empty or garbage assertion and
    # get silently mis-scored instead of caught. Trims whitespace before the
    # length check (via gsub) -- `length > 0` alone accepts a whitespace-only
    # string like "   " (live-confirmed: `jq -en '"   " | (type == "string"
    # and length > 0)'` returns true), which is not a meaningful assertion
    # and would otherwise be fed as-is into every judge_finding prompt below.
    # Also NUL-free (same codepoint check used elsewhere in this file) --
    # Bash's capture of this value a few lines down truncates at a NUL, so
    # judge_finding would silently receive a different, shorter assertion
    # than the fixture actually specifies.
    if ! jq -e '.safeguard_assertion | (type == "string" and (explode | any(. == 0) | not) and ((gsub("\\s"; "")) | length > 0))' "$expected_file" >/dev/null 2>&1; then
      echo "skip: $slug (control-group fixture missing/invalid safeguard_assertion in expected.json)" >&2
      CONFIG_ERROR_COUNT=$((CONFIG_ERROR_COUNT + 1))
      continue
    fi
    safeguard_assertion="$(jq -r '.safeguard_assertion' "$expected_file")"
  fi

  defect_assertion=""
  if [ "$should_flag" = "true" ]; then
    # Required for every bug fixture (see judge_finding and the
    # defect_assertion header comment above) -- validated with the exact
    # same non-empty/whitespace-trimmed/NUL-free contract as
    # safeguard_assertion above, and for the same reasons: `jq -r` silently
    # returns "" or "null" for a missing/wrong-typed field rather than
    # erroring, a whitespace-only string like "   " would otherwise pass a
    # plain `length > 0` check, and a NUL byte would silently truncate to a
    # shorter string than the fixture author wrote once captured into this
    # bash variable. Only actually READ later when the lexical file+keyword
    # check misses but a finding still names must_mention_file (see the
    # should_flag=="true" scoring branch below) -- validated here regardless,
    # before any runs execute, so a misconfigured fixture is caught up front
    # rather than only failing partway through a sweep on whichever run
    # happens to need the semantic fallback first.
    if ! jq -e '.defect_assertion | (type == "string" and (explode | any(. == 0) | not) and ((gsub("\\s"; "")) | length > 0))' "$expected_file" >/dev/null 2>&1; then
      echo "skip: $slug (bug fixture missing/invalid defect_assertion in expected.json)" >&2
      CONFIG_ERROR_COUNT=$((CONFIG_ERROR_COUNT + 1))
      continue
    fi
    defect_assertion="$(jq -r '.defect_assertion' "$expected_file")"
  fi

  keywords=()
  # `jq -c` + a `jq -j` (not `jq -r`) decode per line -- see run_pair_mode's
  # identical fix (same file, its own comment has the full reasoning) for
  # why both matter: `-c` keeps an embedded newline JSON-escaped so `read`
  # never splits one keyword into two on it, and `-j` (rather than `-r`,
  # which appends its own trailing newline) plus the "x"-sentinel/strip
  # trick works around `$(...)` unconditionally eating trailing newlines --
  # without it, a keyword ending in (or consisting only of) a newline
  # would be silently truncated or dropped entirely.
  while IFS= read -r kw_json_line; do
    kw_raw="$(jq -j '.' <<< "$kw_json_line"; printf 'x')"
    kw="${kw_raw%x}"
    [ -n "$kw" ] && keywords+=("$kw")
  done < <(jq -c '(.keywords_any // [])[]' "$expected_file")

  # Isolation snapshot: codex's --sandbox read-only blocks writes but NOT
  # reads -- it can read anywhere on disk, not just $CWD. `before/` itself
  # has no `.git` (see the corpus-format-conversion note at the top of this
  # file) and no sibling files worth reading other than `expected.json` one
  # directory up -- copying it into a fresh, isolated tmp directory (rather
  # than pointing the wrapper at `before/` in place) still removes that one
  # relative-path leak path (no `../expected.json` to `cat` from inside the
  # snapshot) and gives the wrapper a git repo to `git show`/`--commit`
  # against, since `before/` alone has no commit history at all.
  # This does NOT achieve true confinement, and is not claimed to: the
  # review prompt itself tells the model it has read-only shell access and
  # to actually use it (grep/cat/find, etc.), and --sandbox read-only really
  # does permit reading anywhere on disk the OS permits for this user --
  # confirmed multiple times this session. A sufficiently curious/thorough
  # review process could in principle run something like `find / -iname
  # expected.json` and locate this repo's real eval/corpus/ answer keys
  # elsewhere on disk, which the snapshot directory has no relationship to
  # and cannot hide. This is the exact same class of same-user-read residual
  # risk already accepted below for the raw-result-logging state directory,
  # just applying to the corpus's answer keys instead of a sweep's saved
  # verdicts -- closing it for real needs actual filesystem sandboxing
  # (container/chroot), out of scope for a personal-project-scale tool.
  CURRENT_TMP_REPO="$(mktemp -d)"
  # Checked BEFORE the cp below, not after: an unchecked `mktemp -d` failure
  # (e.g. ENOSPC, a bad TMPDIR) leaves CURRENT_TMP_REPO empty, and
  # `cp -R "${before_dir}/." "$CURRENT_TMP_REPO/"` with an empty variable
  # becomes `cp -R "${before_dir}/." "/"` -- a destructive write into the
  # filesystem root, not merely a failed one. `set -u` alone does not catch
  # this (the variable IS set, just to an empty string), and this script has
  # no `set -e`. A real /cc review round caught this as a live-plausible P1.
  if [ -z "$CURRENT_TMP_REPO" ] || [ ! -d "$CURRENT_TMP_REPO" ]; then
    echo "skip: $slug (mktemp -d failed, refusing to build isolation snapshot)" >&2
    CURRENT_TMP_REPO=""
    continue
  fi
  if ! cp -R "${before_dir}/." "$CURRENT_TMP_REPO/"; then
    echo "skip: $slug (failed to copy before/ into isolation snapshot)" >&2
    rm -rf "$CURRENT_TMP_REPO"
    CURRENT_TMP_REPO=""
    continue
  fi
  # Three prior review rounds each found ANOTHER inherited git-related
  # environment variable that could redirect these mutating calls
  # (GIT_DIR/GIT_WORK_TREE/GIT_INDEX_FILE, then GIT_CONFIG_COUNT/KEY_N/
  # VALUE_N/PARAMETERS, then GIT_CONFIG_GLOBAL/GIT_CONFIG_SYSTEM/
  # GIT_TEMPLATE_DIR) -- continuing to enumerate individual dangerous
  # variables one discovery at a time doesn't converge. Switched to an
  # ALLOWLIST instead: `env -i` clears the ENTIRE environment, then only
  # PATH (to find the git binary), a dedicated always-empty FAKE_GIT_HOME
  # (so no real or injected ~/.gitconfig is ever read -- see its own
  # declaration above for why it's a SEPARATE directory from the fixture
  # content), and GIT_CONFIG_NOSYSTEM=1 (so /etc/gitconfig is never read
  # either, regardless of any GIT_CONFIG_SYSTEM trickery) are explicitly let
  # through. This covers every variable enumerated across all three prior
  # rounds AND any not yet discovered, since nothing not on this explicit
  # list survives `env -i` at all.
  GIT_ISOLATED_ENV=(env -i "PATH=$PATH" "HOME=$FAKE_GIT_HOME" "GIT_CONFIG_NOSYSTEM=1")
  "${GIT_ISOLATED_ENV[@]}" git -C "$CURRENT_TMP_REPO" init -q -b main
  "${GIT_ISOLATED_ENV[@]}" git -C "$CURRENT_TMP_REPO" config user.email "eval@example.com"
  "${GIT_ISOLATED_ENV[@]}" git -C "$CURRENT_TMP_REPO" config user.name "Eval Corpus"
  # `-f`/--force: a fixture-provided `.gitignore` would otherwise make
  # `git add -A` SILENTLY skip any matching file (git-add(1): ignored files
  # reached by directory recursion are silently ignored unless forced) --
  # the commit would still succeed, just missing that file, with no error
  # anywhere. This tool's whole purpose is to commit and review EVERY file
  # in before/, not to honor gitignore semantics, so -f makes that
  # unconditional rather than silently dependent on whether a fixture
  # happens to include a .gitignore (none currently do, but nothing enforces
  # that the way the .git-invariant check above does for gitfiles).
  "${GIT_ISOLATED_ENV[@]}" git -C "$CURRENT_TMP_REPO" add -A -f
  # Fixed author/committer timestamps (explicit +0000 UTC offset -- omitting
  # it makes the actually-interpreted instant depend on the runtime TZ,
  # live-confirmed to differ between UTC and America/New_York for the same
  # literal string) and a fixed, content-independent commit message: every
  # fixture, every run, produces byte-identical commit metadata. Needed so
  # the blind/focused pair (fixtures 20/21) differ ONLY in whether --focus
  # is passed -- `git show` includes AuthorDate/CommitDate/message in what
  # the model sees, so unpinned metadata would be an extra, uncontrolled
  # variable in that comparison. `--no-verify` additionally skips pre-commit/
  # commit-msg hooks explicitly and unconditionally, as a second, git-
  # documented layer on top of the env-var isolation above (belt-and-
  # suspenders, not a substitute for it -- --no-verify does not cover
  # post-commit hooks, which the env-var isolation above is what actually
  # prevents from being configured via an injected core.hooksPath).
  if ! env -i "PATH=$PATH" "HOME=$FAKE_GIT_HOME" "GIT_CONFIG_NOSYSTEM=1" \
    "GIT_AUTHOR_DATE=2026-01-01T00:00:00+0000" "GIT_COMMITTER_DATE=2026-01-01T00:00:00+0000" \
    git -C "$CURRENT_TMP_REPO" commit -q --no-verify -m "fixture snapshot"; then
    echo "skip: $slug (git commit failed -- before/ may be empty)" >&2
    rm -rf "$CURRENT_TMP_REPO"
    CURRENT_TMP_REPO=""
    continue
  fi
  snapshot_sha="$(git -C "$CURRENT_TMP_REPO" rev-parse HEAD)"

  hits=0
  lexical_hits=0
  valid=0
  # Separate denominator for the lexical metric -- a /cc round-2 finding
  # caught that lexical_hits was being divided by the SAME `valid` the
  # semantic judge-error branch below decrements, so a judge timeout on a
  # run that was ALREADY a genuine, fully-computed lexical miss silently
  # removed that miss from the lexical denominator too -- inflating lexical
  # recall and contradicting this file's own stated claim that lexical_hits
  # is "COMPLETELY unaffected by the semantic judge fallback". lexical_valid
  # increments in lockstep with `valid` on every wrapper success (lexical
  # scoring is pure jq -- it always completes, unlike the semantic
  # fallback), but is NEVER decremented by a judge error.
  lexical_valid=0
  errors=0

  echo "=== $slug ($category) ==="
  for run_n in $(seq 1 "$RUNS_PER_FIXTURE"); do
    # Backgrounded via `&` + `wait`, never plain `$(...)` -- a signal arriving
    # while synchronously waiting on a command substitution's child is
    # deferred by bash until that child exits (live-confirmed: a trapped
    # parent blocked on `$(sleep 2)` did not run its trap until the full 2s
    # elapsed), whereas `wait` on a backgrounded job is itself interruptible.
    # Matches the exact pattern (and the reason for it) already used in
    # scripts/run-codex-review.sh for its own nested `codex exec` call.
    REVIEW_OUT="$(mktemp)"
    # Same class of unchecked-mktemp gap the isolation-snapshot fix above
    # addresses -- an empty REVIEW_OUT here would redirect the review call's
    # output to an empty filename instead of writing into a destructive
    # target (there's no cp involved on this path), but it's still an
    # unhandled failure that should stop this run rather than proceed with
    # a redirect to "".
    if [ -z "$REVIEW_OUT" ]; then
      echo "  run $run_n: ERROR (mktemp failed) -- excluded from scoring" >&2
      errors=$((errors + 1))
      continue
    fi
    if [ -n "$focus" ]; then
      "$REVIEW_SCRIPT" --cwd "$CURRENT_TMP_REPO" --commit "$snapshot_sha" --focus "$focus" > "$REVIEW_OUT" 2>&1 &
    else
      "$REVIEW_SCRIPT" --cwd "$CURRENT_TMP_REPO" --commit "$snapshot_sha" > "$REVIEW_OUT" 2>&1 &
    fi
    # `wait "$!"` rather than capturing the PID into a variable first --
    # see on_signal's comment above for why: a variable holding this PID
    # would go stale (and unsafely killable) the instant `wait` reaps it.
    wait "$!"
    result="$(cat "$REVIEW_OUT")"
    rm -f "$REVIEW_OUT"
    # Save the raw result + a small manifest before scoring it, regardless of
    # ok true/false -- this is what lets an ambiguous miss be diagnosed later
    # without re-running. run_id is deterministic (slug+run number), which is
    # already unique within a single suite by construction (the fixture loop
    # never revisits the same slug/run_n pair), so plain `mkdir` doubles as
    # the collision check.
    run_id="${slug}-run${run_n}"
    run_dir="$SUITE_DIR/$run_id"
    mkdir "$run_dir" || { echo "error: run-id collision at $run_dir" >&2; exit 1; }
    if ! printf '%s' "$result" > "$run_dir/result.json"; then
      echo "  warning: failed to write raw result artifact for $run_id (disk full/permission?)" >&2
      ARTIFACT_WRITE_FAILURES=$((ARTIFACT_WRITE_FAILURES + 1))
    fi
    focus_sha256=""
    if [ -n "$focus" ]; then
      focus_sha256="$(printf '%s' "$focus" | shasum -a 256 | awk '{print $1}')"
    fi
    if ! jq -n \
      --arg fixture "$slug" \
      --argjson run "$run_n" \
      --arg snapshot_sha "$snapshot_sha" \
      --arg corpus_version "$CORPUS_VERSION" \
      --arg focus_sha256 "$focus_sha256" \
      --arg timestamp_utc "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      --arg reasoning_effort "xhigh (fixed by run-codex-review.sh, not configurable from here)" \
      '{fixture: $fixture, run: $run, snapshot_sha: $snapshot_sha, corpus_version: $corpus_version,
        focus_sha256: (if $focus_sha256 == "" then null else $focus_sha256 end),
        timestamp_utc: $timestamp_utc, reasoning_effort: $reasoning_effort}' \
      > "$run_dir/manifest.json"; then
      echo "  warning: failed to write manifest for $run_id (disk full/permission?)" >&2
      ARTIFACT_WRITE_FAILURES=$((ARTIFACT_WRITE_FAILURES + 1))
    fi

    ok="$(printf '%s' "$result" | jq -r '.ok')"
    if [ "$ok" != "true" ]; then
      reason="$(printf '%s' "$result" | jq -r '.reason // "unknown"')"
      echo "  run $run_n: ERROR (wrapper failure: $reason) -- excluded from scoring"
      errors=$((errors + 1))
      continue
    fi
    valid=$((valid + 1))
    lexical_valid=$((lexical_valid + 1))
    verdict="$(printf '%s' "$result" | jq -r '.verdict.verdict')"

    if [ "$should_flag" = "true" ]; then
      # Hit requires: some finding names must_file AND at least one keyword
      # appears (case-insensitively) in THAT SAME finding's summary/evidence
      # -- not just anywhere in the whole verdict -- so a lucky keyword match
      # on an unrelated finding can't count. Computed exactly as before and
      # NEVER skipped -- this is "lexical_hits" below (R5's new parallel
      # metric), and the ONLY check run at all when it already hits, since a
      # semantic judge_finding call costs a real API call this scoring
      # should never spend when the cheap lexical check already succeeded.
      file_hit="$(printf '%s' "$result" | jq -r --arg f "$must_file" '
        [.verdict.findings[] | select(.file | contains($f))] | length > 0
      ')"
      lexical_hit="false"
      if [ "$file_hit" = "true" ]; then
        if [ "${#keywords[@]}" -eq 0 ]; then
          lexical_hit="true"
        else
          for kw in "${keywords[@]}"; do
            match="$(printf '%s' "$result" | jq -r --arg f "$must_file" --arg kw "$kw" '
              [.verdict.findings[]
               | select(.file | contains($f))
               | select(((.summary // "") + " " + (.evidence // "")) | ascii_downcase | contains($kw | ascii_downcase))
              ] | length > 0
            ')"
            if [ "$match" = "true" ]; then
              lexical_hit="true"
              break
            fi
          done
        fi
      fi

      if [ "$lexical_hit" = "true" ]; then
        lexical_hits=$((lexical_hits + 1))
        hits=$((hits + 1))
        echo "  run $run_n: HIT (verdict=$verdict, lexical keyword match)"
      elif [ "$file_hit" = "true" ]; then
        # Lexical check missed, but at least one finding still named the
        # right file -- the model was looking in the right place but didn't
        # happen to use a keyword from keywords_any. Manual review of a full
        # 63-run sweep found this produces FALSE misses: the model correctly
        # identified (and in one case live-verified) the exact seeded bug,
        # just phrased with a synonym (see the defect_assertion header
        # comment above for the two concrete examples). Every finding on
        # must_file is judged individually here, exactly mirroring the
        # control-group loop's own per-finding pattern below -- the judge
        # sees ONLY defect_assertion and that ONE finding's own
        # summary+evidence, never keywords_any, never the other findings,
        # never any other fixture metadata, so it is deciding narrowly
        # "does this one finding identify this one described defect" and
        # nothing broader (e.g. not "is this a good review overall").
        matching_findings="$(printf '%s' "$result" | jq -c --arg f "$must_file" '
          [.verdict.findings[] | select(.file | contains($f))]
        ')"
        judge_idx=0
        any_yes="false"
        any_error="false"
        while IFS= read -r finding_json; do
          judge_idx=$((judge_idx + 1))
          finding_text="$(printf '%s' "$finding_json" | jq -r '(.summary // "") + "\n" + (.evidence // "")')"
          judge_finding "has the following known defect" \
            "$defect_assertion" \
            "Does this finding identify the defect described above, even if phrased differently or using different terminology?" \
            "$finding_text" \
            "$run_dir/semantic-judge-${judge_idx}.prompt.txt" "$run_dir/semantic-judge-${judge_idx}.response.txt"
          case "$JUDGE_VERDICT" in
            yes) any_yes="true" ;;
            error) any_error="true" ;;
          esac
        done < <(printf '%s' "$matching_findings" | jq -c '.[]')

        if [ "$any_error" = "true" ]; then
          # A judge-call failure/ambiguous-response is excluded from scoring
          # entirely -- same treatment as an ok:false wrapper failure above
          # and as the control-group path's own judge-error handling below --
          # never silently folded into either "hit" (which would inflate
          # recall) or "miss" (which would understate it). `valid` was
          # already incremented above on the assumption this run would be
          # scoreable; undo that now that a judge error has made it not so.
          echo "  run $run_n: ERROR (semantic judge call failed or gave a non-yes/no response) -- excluded from scoring"
          errors=$((errors + 1))
          valid=$((valid - 1))
        elif [ "$any_yes" = "true" ]; then
          # Semantic-only hit: counts toward the combined hits/FIXTURE_HITS
          # metric (lexical-or-semantic) but deliberately NOT toward
          # lexical_hits/FIXTURE_LEXICAL_HITS, which must stay unaffected by
          # this adjudication path.
          hits=$((hits + 1))
          echo "  run $run_n: HIT (verdict=$verdict, semantic judge confirmed a differently-phrased match)"
        else
          echo "  run $run_n: miss (verdict=$verdict)"
        fi
      else
        echo "  run $run_n: miss (verdict=$verdict)"
      fi
    else
      # Control group ("seeded-bug false-report rate", not a generic
      # "no findings at all" bar): a finding on must_file is only a false
      # report if it specifically claims safeguard_assertion is missing or
      # broken -- an xhigh review can legitimately raise OTHER, unrelated
      # hardening notes about genuinely clean code (e.g. "no timeout set")
      # without that being a false report about the ONE safeguard this
      # fixture tests. Keyword matching could not reliably tell these apart
      # (three straight design-review rounds each found either a safe
      # sentence that matched, or a bug-claiming one that didn't), so each
      # finding on must_file is instead judged individually via
      # judge_finding's separate codex exec call.
      matching_findings="$(printf '%s' "$result" | jq -c --arg f "$must_file" '
        [.verdict.findings[] | select(.file | contains($f))]
      ')"
      match_count="$(printf '%s' "$matching_findings" | jq 'length')"
      if [ "$match_count" -eq 0 ]; then
        hits=$((hits + 1))
        echo "  run $run_n: OK (verdict=$verdict, no findings on $must_file)"
      else
        judge_idx=0
        any_yes="false"
        any_error="false"
        while IFS= read -r finding_json; do
          judge_idx=$((judge_idx + 1))
          finding_text="$(printf '%s' "$finding_json" | jq -r '(.summary // "") + "\n" + (.evidence // "")')"
          judge_finding "is protected by the following safeguard, already verified correct" \
            "$safeguard_assertion" \
            "Does this finding claim that the stated safeguard is missing, broken, or ineffective?" \
            "$finding_text" \
            "$run_dir/judge-${judge_idx}.prompt.txt" "$run_dir/judge-${judge_idx}.response.txt"
          case "$JUDGE_VERDICT" in
            yes) any_yes="true" ;;
            error) any_error="true" ;;
          esac
        done < <(printf '%s' "$matching_findings" | jq -c '.[]')

        if [ "$any_error" = "true" ]; then
          # A judge-call failure/ambiguous-response is excluded from scoring
          # the same way a wrapper "ok":false is -- never silently folded
          # into "not a false report" (which would understate the false-
          # report rate) or "false report" (which would overstate it).
          # `valid` was already incremented above on the assumption this run
          # would be scoreable; undo that now that a judge error has made it
          # not so.
          echo "  run $run_n: ERROR (judge call failed or gave a non-yes/no response) -- excluded from scoring"
          errors=$((errors + 1))
          valid=$((valid - 1))
        elif [ "$any_yes" = "true" ]; then
          echo "  run $run_n: false-positive (verdict=$verdict, a finding claims the safeguard is missing)"
        else
          hits=$((hits + 1))
          echo "  run $run_n: OK (verdict=$verdict, $match_count finding(s) on $must_file, none dispute the safeguard)"
        fi
      fi
    fi
  done

  echo "  -> $hits/$valid hits ($errors errors)"
  echo ""

  rm -rf "$CURRENT_TMP_REPO"
  CURRENT_TMP_REPO=""

  FIXTURE_NAMES+=("$slug")
  FIXTURE_CATEGORIES+=("$category")
  FIXTURE_DIFFICULTY+=("$difficulty")
  FIXTURE_SHOULD_FLAG+=("$should_flag")
  FIXTURE_HITS+=("$hits")
  FIXTURE_LEXICAL_HITS+=("$lexical_hits")
  FIXTURE_VALID+=("$valid")
  FIXTURE_LEXICAL_VALID+=("$lexical_valid")
  FIXTURE_ERRORS+=("$errors")
done

if [ "$MATCHED" -eq 0 ]; then
  echo "error: no fixtures matched (--only '$ONLY'?)" >&2
  exit 1
fi

# Distinct from the MATCHED check above: MATCHED counts fixtures whose
# directory + expected.json + before/ existed, but every one of them can
# still end up `continue`d past afterward for other reasons (a copy/commit
# failure building the isolation snapshot, or a missing/invalid
# safeguard_assertion on a control-group fixture) -- leaving every
# FIXTURE_* array with zero elements even though MATCHED > 0.
# Caught live: running `--only` on a single fixture that got skipped this
# way crashed several lines below with "FIXTURE_CATEGORIES[@]: unbound
# variable" -- this machine's Bash 3.2 treats a bare `"${arr[@]}"` on an
# array that was declared but never had any element assigned as unset under
# `set -u` (fixed in later bash versions, but this script targets 3.2). The
# `:-` fallbacks added to the three `${FIXTURE_*[@]}` uses below hedge
# against that same crash class regardless of how the arrays end up empty;
# this check additionally gives a clear, specific error message instead of
# an all-"N/A" scorecard when NOTHING was actually scored.
if [ "${#FIXTURE_NAMES[@]}" -eq 0 ]; then
  echo "error: no fixtures were successfully scored (all matched fixtures were skipped -- see skip/error messages above)" >&2
  exit 1
fi

echo "===================== SCORECARD ====================="

echo ""
echo "Per-fixture:"
for i in "${!FIXTURE_NAMES[@]}"; do
  printf '  %-40s %d/%d hits (%d errors)\n' \
    "${FIXTURE_NAMES[$i]}" "${FIXTURE_HITS[$i]}" "${FIXTURE_VALID[$i]}" "${FIXTURE_ERRORS[$i]}"
done

total_hits=0
total_lexical_hits=0
total_valid=0
total_lexical_valid=0
for i in "${!FIXTURE_NAMES[@]}"; do
  if [ "${FIXTURE_SHOULD_FLAG[$i]}" = "true" ]; then
    total_hits=$((total_hits + FIXTURE_HITS[i]))
    total_lexical_hits=$((total_lexical_hits + FIXTURE_LEXICAL_HITS[i]))
    total_valid=$((total_valid + FIXTURE_VALID[i]))
    total_lexical_valid=$((total_lexical_valid + FIXTURE_LEXICAL_VALID[i]))
  fi
done
echo ""
# "Semantic target recall": fed by hits/FIXTURE_HITS, which count a run as a
# hit if EITHER the lexical file+keyword check matched OR (when it didn't,
# but a finding still named must_mention_file) the semantic judge_finding
# fallback confirmed a differently-phrased match against defect_assertion --
# see the should_flag=="true" scoring branch above. This is the more
# complete picture (a model that identified the seeded defect but phrased it
# with an unanticipated synonym still counts), and was previously labeled
# "Overall recall" before this line was fed by lexical-only scoring.
echo "Semantic target recall (bug fixtures, lexical + judge-confirmed, excludes control group):"
if [ "$total_valid" -gt 0 ]; then
  pct="$(awk -v h="$total_hits" -v v="$total_valid" 'BEGIN { printf "%.1f", (h / v) * 100 }')"
  echo "  $total_hits/$total_valid ($pct%)"
else
  echo "  N/A (no valid runs)"
fi

echo ""
# Lexical-only counterpart: fed by lexical_hits/FIXTURE_LEXICAL_HITS over
# its OWN denominator lexical_valid/FIXTURE_LEXICAL_VALID -- NOT the shared
# total_valid above. A /cc round-2 finding caught that reusing total_valid
# here let a semantic judge-call failure (on a run that was ALREADY a
# genuine, fully-computed lexical miss) silently vanish from the lexical
# denominator too, inflating this metric and contradicting the very claim
# this comment makes. lexical_valid is immune to that: it increments
# whenever the review call itself succeeds and is never decremented by a
# judge error (lexical scoring is pure jq and always completes). This is
# exactly what the scorer would have reported before R5 (the file+keyword
# check alone). Shown side by side with the semantic metric above so a
# future reader can see both numbers, matching the diagnosis document's own
# reported pair (74.1% lexical vs 83.3% semantic on a full 63-run sweep).
echo "Lexical recall (bug fixtures, keyword-match only, excludes control group):"
if [ "$total_lexical_valid" -gt 0 ]; then
  pct="$(awk -v h="$total_lexical_hits" -v v="$total_lexical_valid" 'BEGIN { printf "%.1f", (h / v) * 100 }')"
  echo "  $total_lexical_hits/$total_lexical_valid ($pct%)"
else
  echo "  N/A (no valid runs)"
fi

echo ""
echo "Recall by category (semantic, lexical + judge-confirmed):"
categories="$(printf '%s\n' "${FIXTURE_CATEGORIES[@]:-}" | sort -u)"
while IFS= read -r cat; do
  [ "$cat" = "control_clean" ] && continue
  [ -z "$cat" ] && continue
  cat_hits=0
  cat_valid=0
  for i in "${!FIXTURE_NAMES[@]}"; do
    # Gated on should_flag=="true" (not just category != "control_clean"
    # above) -- a /cc round-1 finding caught that category is an unenforced
    # free-text field (nothing ties its value to should_flag), so a future
    # --corpus-dir fixture using a non-"control_clean" category on a
    # control-group fixture would otherwise silently pollute this bug-
    # fixture recall breakdown. Matches the total_hits/total_valid gate
    # above, which already filters this way.
    if [ "${FIXTURE_CATEGORIES[$i]}" = "$cat" ] && [ "${FIXTURE_SHOULD_FLAG[$i]}" = "true" ]; then
      cat_hits=$((cat_hits + FIXTURE_HITS[i]))
      cat_valid=$((cat_valid + FIXTURE_VALID[i]))
    fi
  done
  if [ "$cat_valid" -gt 0 ]; then
    pct="$(awk -v h="$cat_hits" -v v="$cat_valid" 'BEGIN { printf "%.1f", (h / v) * 100 }')"
    echo "  $cat: $cat_hits/$cat_valid ($pct%)"
  else
    echo "  $cat: N/A (no valid runs)"
  fi
done <<< "$categories"

echo ""
echo "Recall by category (lexical, keyword-match only):"
while IFS= read -r cat; do
  [ "$cat" = "control_clean" ] && continue
  [ -z "$cat" ] && continue
  cat_lexical_hits=0
  cat_lexical_valid=0
  for i in "${!FIXTURE_NAMES[@]}"; do
    # Same should_flag gate as the semantic breakdown above -- see its
    # comment for why category alone isn't a reliable filter. Uses its own
    # FIXTURE_LEXICAL_VALID denominator, not FIXTURE_VALID -- see that
    # array's own comment (a /cc round-2 finding) for why sharing it with
    # the semantic denominator lets a judge-call failure inflate this
    # lexical metric.
    if [ "${FIXTURE_CATEGORIES[$i]}" = "$cat" ] && [ "${FIXTURE_SHOULD_FLAG[$i]}" = "true" ]; then
      cat_lexical_hits=$((cat_lexical_hits + FIXTURE_LEXICAL_HITS[i]))
      cat_lexical_valid=$((cat_lexical_valid + FIXTURE_LEXICAL_VALID[i]))
    fi
  done
  if [ "$cat_lexical_valid" -gt 0 ]; then
    pct="$(awk -v h="$cat_lexical_hits" -v v="$cat_lexical_valid" 'BEGIN { printf "%.1f", (h / v) * 100 }')"
    echo "  $cat: $cat_lexical_hits/$cat_lexical_valid ($pct%)"
  else
    echo "  $cat: N/A (no valid runs)"
  fi
done <<< "$categories"

# Recall by difficulty (easy vs subtle) -- the point of this split per
# research on leaky/easy benchmarks (PrimeVul): a corpus dominated by
# "easy" bugs inflates recall in a way that doesn't reflect real review
# value. Watching easy vs subtle drift apart here is the actual signal.
echo ""
echo "Recall by difficulty (semantic, lexical + judge-confirmed):"
difficulties="$(printf '%s\n' "${FIXTURE_DIFFICULTY[@]:-}" | sort -u)"
while IFS= read -r diff; do
  [ "$diff" = "n/a" ] && continue
  [ -z "$diff" ] && continue
  diff_hits=0
  diff_valid=0
  for i in "${!FIXTURE_NAMES[@]}"; do
    # Gated on should_flag=="true" for the same reason as the category
    # breakdown above -- difficulty is likewise an unenforced free-text/
    # enum field with no validator link to should_flag. Currently every
    # control-group fixture uses difficulty:null (-> "n/a", already
    # skipped above), so this is defense-in-depth rather than a live fix.
    if [ "${FIXTURE_DIFFICULTY[$i]}" = "$diff" ] && [ "${FIXTURE_SHOULD_FLAG[$i]}" = "true" ]; then
      diff_hits=$((diff_hits + FIXTURE_HITS[i]))
      diff_valid=$((diff_valid + FIXTURE_VALID[i]))
    fi
  done
  if [ "$diff_valid" -gt 0 ]; then
    pct="$(awk -v h="$diff_hits" -v v="$diff_valid" 'BEGIN { printf "%.1f", (h / v) * 100 }')"
    echo "  $diff: $diff_hits/$diff_valid ($pct%)"
  else
    echo "  $diff: N/A (no valid runs)"
  fi
done <<< "$difficulties"

echo ""
echo "Recall by difficulty (lexical, keyword-match only):"
while IFS= read -r diff; do
  [ "$diff" = "n/a" ] && continue
  [ -z "$diff" ] && continue
  diff_lexical_hits=0
  diff_lexical_valid=0
  for i in "${!FIXTURE_NAMES[@]}"; do
    # Same should_flag gate as the semantic breakdown above. Uses its own
    # FIXTURE_LEXICAL_VALID denominator -- see that array's own comment
    # (a /cc round-2 finding) for why.
    if [ "${FIXTURE_DIFFICULTY[$i]}" = "$diff" ] && [ "${FIXTURE_SHOULD_FLAG[$i]}" = "true" ]; then
      diff_lexical_hits=$((diff_lexical_hits + FIXTURE_LEXICAL_HITS[i]))
      diff_lexical_valid=$((diff_lexical_valid + FIXTURE_LEXICAL_VALID[i]))
    fi
  done
  if [ "$diff_lexical_valid" -gt 0 ]; then
    pct="$(awk -v h="$diff_lexical_hits" -v v="$diff_lexical_valid" 'BEGIN { printf "%.1f", (h / v) * 100 }')"
    echo "  $diff: $diff_lexical_hits/$diff_lexical_valid ($pct%)"
  else
    echo "  $diff: N/A (no valid runs)"
  fi
done <<< "$difficulties"

fp_bad=0
fp_valid=0
for i in "${!FIXTURE_NAMES[@]}"; do
  if [ "${FIXTURE_SHOULD_FLAG[$i]}" = "false" ]; then
    fp_valid=$((fp_valid + FIXTURE_VALID[i]))
    fp_bad=$((fp_bad + (FIXTURE_VALID[i] - FIXTURE_HITS[i])))
  fi
done
echo ""
echo "False-positive rate (control group):"
if [ "$fp_valid" -gt 0 ]; then
  pct="$(awk -v b="$fp_bad" -v v="$fp_valid" 'BEGIN { printf "%.1f", (b / v) * 100 }')"
  echo "  $fp_bad/$fp_valid runs incorrectly flagged ($pct%)"
else
  echo "  N/A (no valid runs)"
fi

total_errors=0
for e in "${FIXTURE_ERRORS[@]:-}"; do
  total_errors=$((total_errors + e))
done
echo ""
echo "Wrapper-level errors (excluded from all scoring above): $total_errors"
echo ""
if [ "$CONFIG_ERROR_COUNT" -gt 0 ]; then
  # Deliberately does not name a single cause -- CONFIG_ERROR_COUNT is
  # incremented for SEVEN distinct validation failures (a symlinked
  # expected.json/before/, a nested .git corpus-format violation, malformed
  # required fields, invalid keywords_any, invalid focus,
  # invalid/missing safeguard_assertion, invalid/missing defect_assertion --
  # the last one added by R5); this message has fallen behind the actual
  # increment-site count more than once already as new validation checks
  # were added elsewhere in this file. Keep this list in sync whenever a new
  # CONFIG_ERROR_COUNT increment site is added.
  echo "WARNING: $CONFIG_ERROR_COUNT fixture(s) skipped entirely due to a configuration error"
  echo "(a symlinked expected.json/before/, a nested .git under before/, malformed expected.json,"
  echo "invalid keywords_any, invalid focus, missing/invalid safeguard_assertion, or missing/invalid"
  echo "defect_assertion -- see the skip: messages earlier in this output for which one) -- NOT"
  echo "counted in any denominator above."
  echo ""
fi
if [ "$ARTIFACT_WRITE_FAILURES" -eq 0 ]; then
  echo "Raw per-run results and manifests saved to: $SUITE_DIR"
else
  echo "Raw per-run results saved to: $SUITE_DIR (INCOMPLETE -- $ARTIFACT_WRITE_FAILURES artifact write(s) failed, see warnings above)"
fi
