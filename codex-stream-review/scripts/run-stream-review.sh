#!/usr/bin/env bash
set -u

DEFAULT_TIMEOUT_SECS=1800
THREAD_WAIT_SECS=10

# --- temp-file registry ---
register_temp_file() {
  [ -n "${TEMP_FILE_REGISTRY:-}" ] && printf '%s\0' "$1" >> "$TEMP_FILE_REGISTRY"
}
mktemp_registered() {
  local __mktemp_registered_var="$1" f
  f="$(mktemp)"
  register_temp_file "$f"
  printf -v "$__mktemp_registered_var" '%s' "$f"
}
cleanup_temp_files() {
  if [ -n "${TEMP_FILE_REGISTRY:-}" ] && [ -f "$TEMP_FILE_REGISTRY" ]; then
    while IFS= read -r -d '' reg_path || [ -n "$reg_path" ]; do
      [ -n "$reg_path" ] && rm -f "$reg_path"
    done < "$TEMP_FILE_REGISTRY"
    rm -f "$TEMP_FILE_REGISTRY"
  fi
}
# kill_process_group PID -> TERM, brief wait, then KILL, targeting the whole
# process group (codex is a Node wrapper that spawns real child processes).
kill_process_group() {
  local pid="$1"
  [ -n "$pid" ] || return 0
  kill -TERM -"$pid" 2>/dev/null
  sleep 1
  kill -KILL -"$pid" 2>/dev/null
}
on_signal() {
  kill_process_group "${CODEX_PID:-}"
  local job_pid
  for job_pid in $(jobs -p 2>/dev/null); do
    kill -KILL -"$job_pid" 2>/dev/null
  done
  if [ -n "${THREAD_ID:-}" ]; then
    local tid_json
    tid_json="$(printf '%s' "$THREAD_ID" | jq -Rs '.')"
    printf '{"ok":false,"reason":"interrupted","threadId":%s,"detail":"wrapper received a termination signal"}\n' "$tid_json"
  else
    printf '{"ok":false,"reason":"interrupted","detail":"wrapper received a termination signal"}\n'
  fi
  exit 1
}

# --cleanup <threadId>: the CALLER's explicit end-of-review step (Task 5's
# retention decision) -- run only once the whole multi-round review is done,
# never automatically after a single round, since `resume` needs the thread
# to still exist for the next round. Deliberately its own tiny mode rather
# than a flag combined with a round dispatch, so a caller cannot accidentally
# clean up the very thread it just asked to `--resume`.
if [ "${1:-}" = "--cleanup" ]; then
  if [ $# -lt 2 ] || [ -z "$2" ]; then
    printf '{"ok":false,"reason":"bad_args","detail":"--cleanup requires a threadId"}\n'
    exit 1
  fi
  THREAD_ID="$2"
  case "$THREAD_ID" in
    -*)
      DETAIL_JSON="$(printf '%s' "$THREAD_ID" | jq -Rs '"--cleanup threadId must not start with -: " + .')"
      printf '{"ok":false,"reason":"bad_args","detail":%s}\n' "$DETAIL_JSON"
      exit 1 ;;
  esac
  THREAD_ID_JSON="$(printf '%s' "$THREAD_ID" | jq -Rs '.')"
  DELETE_OUT="$(codex delete --force -- "$THREAD_ID" 2>&1)"
  DELETE_STATUS=$?
  if [ "$DELETE_STATUS" -ne 0 ]; then
    DETAIL_JSON="$(printf '%s' "$DELETE_OUT" | jq -Rs '.')"
    printf '{"ok":false,"reason":"cleanup_failed","threadId":%s,"detail":%s}\n' "$THREAD_ID_JSON" "$DETAIL_JSON"
    exit 1
  fi
  printf '{"ok":true,"threadId":%s,"deleted":true}\n' "$THREAD_ID_JSON"
  exit 0
fi

CWD=""
FOCUS=""
RESUME_THREAD_ID=""
SCHEMA=""

while [ $# -gt 0 ]; do
  case "$1" in
    --cwd)
      [ $# -ge 2 ] || { printf '{"ok":false,"reason":"bad_args","detail":"--cwd requires a value"}\n'; exit 1; }
      CWD="$2"; shift 2 ;;
    --focus)
      [ $# -ge 2 ] || { printf '{"ok":false,"reason":"bad_args","detail":"--focus requires a value"}\n'; exit 1; }
      FOCUS="$2"; shift 2 ;;
    --resume)
      [ $# -ge 2 ] || { printf '{"ok":false,"reason":"bad_args","detail":"--resume requires a value"}\n'; exit 1; }
      case "$2" in
        -*)
          DETAIL_JSON="$(printf '%s' "$2" | jq -Rs '"--resume threadId must not start with -: " + .')"
          printf '{"ok":false,"reason":"bad_args","detail":%s}\n' "$DETAIL_JSON"
          exit 1 ;;
      esac
      RESUME_THREAD_ID="$2"; shift 2 ;;
    --output-schema)
      [ $# -ge 2 ] || { printf '{"ok":false,"reason":"bad_args","detail":"--output-schema requires a value"}\n'; exit 1; }
      SCHEMA="$2"; shift 2 ;;
    *)
      DETAIL_JSON="$(printf '%s' "$1" | jq -Rs '"unknown argument: " + .')"
      printf '{"ok":false,"reason":"bad_args","detail":%s}\n' "$DETAIL_JSON"
      exit 1 ;;
  esac
done

if [ -z "$CWD" ] || [ -z "$FOCUS" ]; then
  printf '{"ok":false,"reason":"bad_args","detail":"require --cwd and --focus"}\n'
  exit 1
fi

TEMP_FILE_REGISTRY="$(mktemp)"
trap cleanup_temp_files EXIT
trap on_signal INT TERM
set -m

# For --resume, the thread already exists -- nothing to pre-check: unlike
# the removed rollout-file preflight, a genuinely dead/unknown threadId now
# simply surfaces as a `nonzero_exit` from the actual dispatch below (never
# `no_thread_started` -- that reason's only branch below is gated on a
# FRESH dispatch's empty THREAD_ID, structurally unreachable once
# RESUME_THREAD_ID has already been assigned to it), the same as any other
# dispatch failure. For a fresh round
# the thread doesn't exist yet -- threadId is only knowable once the
# process's own --json stdout emits thread.started (Step 5).
THREAD_ID=""
if [ -n "$RESUME_THREAD_ID" ]; then
  THREAD_ID="$RESUME_THREAD_ID"
  THREAD_ID_JSON="$(printf '%s' "$THREAD_ID" | jq -Rs '.')"
  echo "THREAD_ID=$THREAD_ID" >&2
fi

mktemp_registered EVENTLOG
# LAST_MESSAGE_FILE: codex exec's own `-o/--output-last-message` writes the
# agent's final message text directly to this file -- the CLI's documented,
# process-owned output channel, used here INSTEAD OF locating and parsing
# this thread's rollout file under ~/.codex/sessions (removed: that
# subsystem's on-disk format/compression is not a documented stable public
# contract, and is unrelated to what this wrapper actually needs -- the
# final answer text this same process already produced).
mktemp_registered LAST_MESSAGE_FILE

# Round dispatch (Step 4, finalized flags -- do not add --sandbox or
# model_reasoning_effort to resume: `codex exec resume --help` has no
# --sandbox flag at all; the resumed turn inherits its thread's original
# turn_context). `< /dev/null` on every invocation: codex exec otherwise
# tries to read stdin for a `<stdin>` block and hangs forever waiting on EOF.
(
  cd "$CWD" || exit 127
  if [ -n "$RESUME_THREAD_ID" ]; then
    codex exec resume "$RESUME_THREAD_ID" --json -o "$LAST_MESSAGE_FILE" \
      ${SCHEMA:+--output-schema "$SCHEMA"} -- "$FOCUS" < /dev/null
  else
    codex exec --json --sandbox read-only -o "$LAST_MESSAGE_FILE" \
      -c model_reasoning_effort=xhigh ${SCHEMA:+--output-schema "$SCHEMA"} \
      -- "$FOCUS" < /dev/null
  fi
) > "$EVENTLOG" 2>&1 &
CODEX_PID=$!

# Step 5: capture threadId from the live stdout stream (bounded 10s wait) --
# only needed for a fresh round; --resume already knows it.
if [ -z "$THREAD_ID" ]; then
  WAIT_DEADLINE=$((SECONDS + THREAD_WAIT_SECS))
  while [ -z "$THREAD_ID" ]; do
    if grep -q '"type":"thread.started"' "$EVENTLOG" 2>/dev/null; then
      THREAD_ID="$(grep -m1 '"type":"thread.started"' "$EVENTLOG" | jq -r '.thread_id // empty' 2>/dev/null)"
    fi
    [ -n "$THREAD_ID" ] && break
    kill -0 "$CODEX_PID" 2>/dev/null || break
    [ "$SECONDS" -ge "$WAIT_DEADLINE" ] && break
    sleep 0.5
  done
  if [ -z "$THREAD_ID" ]; then
    kill_process_group "$CODEX_PID"
    wait "$CODEX_PID" 2>/dev/null
    CODEX_PID=""
    printf '{"ok":false,"reason":"no_thread_started","detail":"no thread.started event within %ss"}\n' "$THREAD_WAIT_SECS"
    exit 1
  fi
  THREAD_ID_JSON="$(printf '%s' "$THREAD_ID" | jq -Rs '.')"
  echo "THREAD_ID=$THREAD_ID" >&2
fi

# Step 6: wait for THIS dispatch's own `turn.completed` event in $EVENTLOG
# (the --json stdout stream this attempt itself produced -- confirmed
# directly, live, to emit exactly one `turn.completed` per dispatch,
# distinct from the OLDER `event_msg`/`task_complete` shape rollout files
# use, which this stdout stream does NOT share), bounded by the same
# wall-clock timeout + PID liveness watchdog run-ccs-review.sh already uses
# for its own codex exec call -- process-group TERM then KILL on timeout.
# No baseline/counter needed (unlike the removed rollout-based check): this
# $EVENTLOG is a fresh file for this one dispatch attempt only, fresh or
# resumed, never a shared growing history across rounds -- a single match
# always means THIS attempt's own turn, never a prior round's.
DEADLINE=$((SECONDS + DEFAULT_TIMEOUT_SECS))
TIMED_OUT=0
TASK_COMPLETE_SEEN=0
while kill -0 "$CODEX_PID" 2>/dev/null; do
  if grep -q '"type":"turn.completed"' "$EVENTLOG" 2>/dev/null; then
    TASK_COMPLETE_SEEN=1
    break
  fi
  if [ "$SECONDS" -ge "$DEADLINE" ]; then
    TIMED_OUT=1
    kill -TERM -"$CODEX_PID" 2>/dev/null
    sleep 2
    kill -KILL -"$CODEX_PID" 2>/dev/null
    break
  fi
  sleep 1
done
if [ "$TASK_COMPLETE_SEEN" -eq 1 ]; then
  # turn.completed is written to this process's own stdout, but observing it
  # says nothing about whether the process is actually about to exit. Give
  # it a bounded grace period to exit on its own before falling back to the
  # same kill sequence the deadline branch above uses; without this, a
  # process that emits turn.completed but then hangs turns the unconditional
  # `wait` below into an unbounded block, defeating this round's own
  # DEFAULT_TIMEOUT_SECS guarantee entirely (mirrors run-ccs-review.sh's
  # identical grace-period handling for the same underlying race).
  GRACE_DEADLINE=$((SECONDS + 10))
  while kill -0 "$CODEX_PID" 2>/dev/null && [ "$SECONDS" -lt "$GRACE_DEADLINE" ]; do
    sleep 0.5
  done
  if kill -0 "$CODEX_PID" 2>/dev/null; then
    TIMED_OUT=1
    kill -TERM -"$CODEX_PID" 2>/dev/null
    sleep 2
    kill -KILL -"$CODEX_PID" 2>/dev/null
  fi
fi
wait "$CODEX_PID" 2>/dev/null
EXIT_CODE=$?
CODEX_PID=""

# turn.completed can land shortly before the process itself exits -- the
# kill -0 loop above can exit the instant the process dies without one more
# poll ever running, so re-check once more now that the process is
# confirmed gone.
if [ "$TASK_COMPLETE_SEEN" -eq 0 ] && [ "$TIMED_OUT" -eq 0 ]; then
  grep -q '"type":"turn.completed"' "$EVENTLOG" 2>/dev/null && TASK_COMPLETE_SEEN=1
fi

rm -f "$EVENTLOG"

if [ "$TIMED_OUT" -eq 1 ]; then
  rm -f "$LAST_MESSAGE_FILE"
  printf '{"ok":false,"reason":"timeout","threadId":%s,"detail":"round exceeded %ss"}\n' "$THREAD_ID_JSON" "$DEFAULT_TIMEOUT_SECS"
  exit 1
fi
if [ "$EXIT_CODE" -ne 0 ]; then
  rm -f "$LAST_MESSAGE_FILE"
  printf '{"ok":false,"reason":"nonzero_exit","threadId":%s,"detail":"codex exec exited %s"}\n' "$THREAD_ID_JSON" "$EXIT_CODE"
  exit 1
fi
if [ "$TASK_COMPLETE_SEEN" -eq 0 ]; then
  rm -f "$LAST_MESSAGE_FILE"
  printf '{"ok":false,"reason":"missing_task_complete","threadId":%s,"detail":"no turn.completed event found in this dispatch'"'"'s own event stream"}\n' "$THREAD_ID_JSON"
  exit 1
fi

# Step 7: read the final answer directly from codex exec's own -o file --
# no parsing of a rollout's response_item/final_answer structure needed,
# since -o already contains exactly that text.
FINAL_TEXT="$(cat "$LAST_MESSAGE_FILE" 2>/dev/null; printf 'x')"
FINAL_TEXT="${FINAL_TEXT%x}"
rm -f "$LAST_MESSAGE_FILE"

if [ -z "$FINAL_TEXT" ]; then
  printf '{"ok":false,"reason":"no_final_answer","threadId":%s,"detail":"codex exec exited 0 with turn.completed but -o produced no final message"}\n' "$THREAD_ID_JSON"
  exit 1
fi

if [ -n "$SCHEMA" ]; then
  if ! printf '%s' "$FINAL_TEXT" | jq -e . >/dev/null 2>&1; then
    printf '{"ok":false,"reason":"invalid_json","threadId":%s,"detail":"final answer is not valid JSON despite --output-schema"}\n' "$THREAD_ID_JSON"
    exit 1
  fi
  printf '{"ok":true,"threadId":%s,"verdict":%s}\n' "$THREAD_ID_JSON" "$(printf '%s' "$FINAL_TEXT" | jq -c .)"
else
  printf '{"ok":true,"threadId":%s,"verdict":%s}\n' "$THREAD_ID_JSON" "$(printf '%s' "$FINAL_TEXT" | jq -Rs .)"
fi
exit 0
