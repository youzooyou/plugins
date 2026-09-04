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
# resolve_rollout <threadId> -- rollout files live under
# ~/.codex/sessions/<Y>/<M>/<D>/, so a thread started "now" almost always
# resolves under today's date directory. Try that narrow, cheap lookup
# first; only fall back to a full recursive scan of the whole sessions
# tree (unbounded, grows with every session ever run) if today's
# directory doesn't have it yet -- e.g. a call right at a midnight
# rollover, or before the file has been created on disk. Always correct
# (the fallback covers every case the narrow path could miss), just
# cheaper in the common case.
resolve_rollout() {
  local tid="$1" f
  f="$(find "$HOME/.codex/sessions/$(date +%Y/%m/%d 2>/dev/null)" -maxdepth 1 -name "rollout-*-${tid}.jsonl" 2>/dev/null | head -1)"
  if [ -n "$f" ]; then
    printf '%s' "$f"
    return 0
  fi
  find "$HOME/.codex/sessions" -name "rollout-*-${tid}.jsonl" 2>/dev/null | head -1
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

# For --resume, the thread already exists: resolve its rollout file and
# snapshot how many task_complete events it already has BEFORE dispatching
# this round, so the completion check below can wait for a NEW one instead
# of matching a prior round's. For a fresh round the thread doesn't exist
# yet -- threadId (and therefore the rollout path) is only knowable once the
# process's own --json stdout emits thread.started (Step 5).
THREAD_ID=""
ROLLOUT=""
BASELINE_TASK_COMPLETE=0
if [ -n "$RESUME_THREAD_ID" ]; then
  THREAD_ID="$RESUME_THREAD_ID"
  THREAD_ID_JSON="$(printf '%s' "$THREAD_ID" | jq -Rs '.')"
  echo "THREAD_ID=$THREAD_ID" >&2
  ROLLOUT="$(resolve_rollout "$THREAD_ID")"
  if [ -z "$ROLLOUT" ] || [ ! -f "$ROLLOUT" ]; then
    printf '{"ok":false,"reason":"resume_thread_not_found","threadId":%s,"detail":"no rollout file found for this threadId"}\n' "$THREAD_ID_JSON"
    exit 1
  fi
  BASELINE_TASK_COMPLETE="$(jq -c 'select(.type=="event_msg" and .payload.type=="task_complete")' "$ROLLOUT" 2>/dev/null | wc -l | tr -d ' ')"
fi

mktemp_registered EVENTLOG

# Round dispatch (Step 4, finalized flags -- do not add --sandbox or
# model_reasoning_effort to resume: `codex exec resume --help` has no
# --sandbox flag at all; the resumed turn inherits its thread's original
# turn_context). `< /dev/null` on every invocation: codex exec otherwise
# tries to read stdin for a `<stdin>` block and hangs forever waiting on EOF.
(
  cd "$CWD" || exit 127
  if [ -n "$RESUME_THREAD_ID" ]; then
    codex exec resume "$RESUME_THREAD_ID" --json \
      ${SCHEMA:+--output-schema "$SCHEMA"} -- "$FOCUS" < /dev/null
  else
    codex exec --json --sandbox read-only \
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

# Step 6: resolve (fresh round) and tail the rollout file until a NEW
# task_complete appears, bounded by the same wall-clock timeout + PID
# liveness watchdog run-codex-review.sh already uses for its own codex exec
# call -- process-group TERM then KILL on timeout.
DEADLINE=$((SECONDS + DEFAULT_TIMEOUT_SECS))
TIMED_OUT=0
TASK_COMPLETE_SEEN=0
while kill -0 "$CODEX_PID" 2>/dev/null; do
  if [ -z "$ROLLOUT" ]; then
    ROLLOUT="$(resolve_rollout "$THREAD_ID")"
  fi
  if [ -n "$ROLLOUT" ] && [ -f "$ROLLOUT" ]; then
    CUR_COUNT="$(jq -c 'select(.type=="event_msg" and .payload.type=="task_complete")' "$ROLLOUT" 2>/dev/null | wc -l | tr -d ' ')"
    if [ "${CUR_COUNT:-0}" -gt "$BASELINE_TASK_COMPLETE" ]; then
      TASK_COMPLETE_SEEN=1
      break
    fi
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
wait "$CODEX_PID" 2>/dev/null
EXIT_CODE=$?
CODEX_PID=""

# task_complete can land ~250-330ms before the process itself exits (per the
# knowledge base's live measurement) -- the kill -0 loop above can exit the
# instant the process dies without one more poll ever running, so re-check
# once more now that the process is confirmed gone.
if [ "$TASK_COMPLETE_SEEN" -eq 0 ] && [ "$TIMED_OUT" -eq 0 ] && [ -n "$ROLLOUT" ] && [ -f "$ROLLOUT" ]; then
  CUR_COUNT="$(jq -c 'select(.type=="event_msg" and .payload.type=="task_complete")' "$ROLLOUT" 2>/dev/null | wc -l | tr -d ' ')"
  [ "${CUR_COUNT:-0}" -gt "$BASELINE_TASK_COMPLETE" ] && TASK_COMPLETE_SEEN=1
fi

rm -f "$EVENTLOG"

if [ "$TIMED_OUT" -eq 1 ]; then
  printf '{"ok":false,"reason":"timeout","threadId":%s,"detail":"round exceeded %ss"}\n' "$THREAD_ID_JSON" "$DEFAULT_TIMEOUT_SECS"
  exit 1
fi
if [ "$EXIT_CODE" -ne 0 ]; then
  printf '{"ok":false,"reason":"nonzero_exit","threadId":%s,"detail":"codex exec exited %s"}\n' "$THREAD_ID_JSON" "$EXIT_CODE"
  exit 1
fi
if [ "$TASK_COMPLETE_SEEN" -eq 0 ]; then
  printf '{"ok":false,"reason":"missing_task_complete","threadId":%s,"detail":"no task_complete event found in rollout file"}\n' "$THREAD_ID_JSON"
  exit 1
fi
if [ -z "$ROLLOUT" ] || [ ! -f "$ROLLOUT" ]; then
  printf '{"ok":false,"reason":"rollout_not_found","threadId":%s,"detail":"could not resolve rollout file for this threadId"}\n' "$THREAD_ID_JSON"
  exit 1
fi

# Step 7: last response_item with payload.type=="message" and
# payload.phase=="final_answer" (never "commentary" -- that is intermediate
# narration). Text lives at payload.content[].text (output_text items).
FINAL_TEXT="$(jq -n -r '
    [inputs | select(.type=="response_item" and .payload.type=="message" and .payload.phase=="final_answer")]
    | last
    | if . == null then empty else (.payload.content // [] | map(select(.type=="output_text") | .text) | join("")) end
  ' "$ROLLOUT" 2>/dev/null)"

if [ -z "$FINAL_TEXT" ]; then
  printf '{"ok":false,"reason":"no_final_answer","threadId":%s,"detail":"no final_answer message found in rollout file"}\n' "$THREAD_ID_JSON"
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
