#!/usr/bin/env bash
#
# asynthlogr pending-subagent hook. Registered for two events, and
# branches on the input's hook_event_name:
#
#   Stop        — fires every time Claude finishes a response. If any
#                 subagent run is still dispatched/running, shows the
#                 user a non-blocking warning (JSON `systemMessage`).
#                 Never blocks: a blocking Stop hook would force Claude
#                 to keep going mid-session, breaking the fire-and-forget
#                 principle.
#   SessionEnd  — fires when the session ends (exit, /clear, /resume).
#                 Can't block. Appends one line per still-pending run to
#                 <vault_root>/failed-writes.log, so a run whose log
#                 write never happened is recorded instead of silently
#                 lost.
#
# See docs/architecture.md ("Pending-run hooks") for the design rationale.

set -euo pipefail

# jq is required to read the hook input; without it there's nothing
# safe to do, and a hook error on every turn would be worse than silence.
command -v jq >/dev/null 2>&1 || exit 0

# Hook input JSON arrives on stdin.
INPUT_JSON="$(cat)"
EVENT="$(echo "$INPUT_JSON" | jq -r '.hook_event_name // empty')"
CWD="$(echo "$INPUT_JSON" | jq -r '.cwd // empty')"
END_REASON="$(echo "$INPUT_JSON" | jq -r '.reason // "unknown"')"

ACTIVE_THREAD_FILE="$CWD/.claude/active-thread.json"

# No active thread recorded -> nothing to check.
if [ ! -f "$ACTIVE_THREAD_FILE" ]; then
  exit 0
fi

VAULT_ROOT="$(jq -r '.vault_root // empty' "$ACTIVE_THREAD_FILE")"
REPO="$(jq -r '.repo // empty' "$ACTIVE_THREAD_FILE")"
THREAD="$(jq -r '.thread // empty' "$ACTIVE_THREAD_FILE")"

if [ -z "$VAULT_ROOT" ] || [ -z "$REPO" ] || [ -z "$THREAD" ]; then
  exit 0
fi

SUBAGENTS_DIR="$VAULT_ROOT/$REPO/$THREAD/subagents"
if [ ! -d "$SUBAGENTS_DIR" ]; then
  exit 0
fi

# Collect any run whose agent-use-tracking.md is still dispatched/running.
PENDING_RUNS=()
PENDING_STATUSES=()
for tracking_file in "$SUBAGENTS_DIR"/*/agent-use-tracking.md; do
  [ -f "$tracking_file" ] || continue
  # basic-memory may quote YAML values, and a hand-written note may carry
  # a trailing comment; strip both.
  status="$(sed -n 's/^status: *//p' "$tracking_file" | head -n1 | sed 's/#.*//' | tr -d "[:space:]'\"")"
  if [ "$status" = "dispatched" ] || [ "$status" = "running" ]; then
    PENDING_RUNS+=("$(basename "$(dirname "$tracking_file")")")
    PENDING_STATUSES+=("$status")
  fi
done

if [ "${#PENDING_RUNS[@]}" -eq 0 ]; then
  exit 0
fi

case "$EVENT" in
  Stop)
    msg="asynthlogr: ${#PENDING_RUNS[@]} subagent run(s) haven't finished logging:"
    for i in "${!PENDING_RUNS[@]}"; do
      msg+=$'\n'"  - ${PENDING_RUNS[$i]} (${PENDING_STATUSES[$i]})"
    done
    msg+=$'\n'"If you exit before they finish, they'll be recorded as abandoned in failed-writes.log."
    jq -n --arg msg "$msg" '{systemMessage: $msg}'
    ;;

  SessionEnd)
    FAILED_LOG="$VAULT_ROOT/failed-writes.log"
    now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    for i in "${!PENDING_RUNS[@]}"; do
      run="${PENDING_RUNS[$i]}"
      # A resumed-then-ended session would otherwise record the same
      # run again; one abandoned line per run is enough.
      if [ -f "$FAILED_LOG" ] && grep -qF "| abandoned: $run " "$FAILED_LOG"; then
        continue
      fi
      echo "$now | $REPO/$THREAD | subagent-run | abandoned: $run still ${PENDING_STATUSES[$i]} at session end (reason: $END_REASON)" >> "$FAILED_LOG"
    done
    ;;
esac

exit 0
