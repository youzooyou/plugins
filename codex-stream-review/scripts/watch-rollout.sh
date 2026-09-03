#!/usr/bin/env bash
set -u
ROLLOUT="${1:?usage: watch-rollout.sh <rollout-file>}"

# Wait for the file to exist -- it may not be created yet the instant this
# script starts (the caller races this against the THREAD_ID stderr signal,
# which fires before the rollout file is guaranteed to be on disk).
while [ ! -f "$ROLLOUT" ]; do sleep 0.5; done

tail -n +1 -F "$ROLLOUT" 2>/dev/null | while IFS= read -r line; do
  TYPE="$(printf '%s' "$line" | jq -r '.type // empty' 2>/dev/null)"
  case "$TYPE" in
    response_item)
      PTYPE="$(printf '%s' "$line" | jq -r '.payload.type // empty' 2>/dev/null)"
      case "$PTYPE" in
        reasoning)
          TEXT="$(printf '%s' "$line" | jq -r '.payload.content // [] | map(.text // empty) | join(" ")' 2>/dev/null)"
          [ -n "$TEXT" ] && printf 'reasoning: %s\n' "$TEXT"
          ;;
        custom_tool_call)
          CMD="$(printf '%s' "$line" | jq -r '.payload.arguments // empty' 2>/dev/null)"
          [ -n "$CMD" ] && printf 'investigating: %s\n' "$CMD"
          ;;
      esac
      ;;
    event_msg)
      PTYPE="$(printf '%s' "$line" | jq -r '.payload.type // empty' 2>/dev/null)"
      [ "$PTYPE" = "task_complete" ] && printf 'round complete\n'
      ;;
  esac
done
