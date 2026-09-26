#!/usr/bin/env bats
#
# Unit tests for hooks/check-pending-subagents.sh, which is registered
# for two events and branches on hook_event_name:
#   Stop       — exit 0 always; a JSON `systemMessage` warning on stdout
#                when runs are pending, nothing otherwise. Never blocks.
#   SessionEnd — exit 0 always; appends one "abandoned" line per pending
#                run to <vault_root>/failed-writes.log.

REPO_ROOT="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../.." && pwd)"
HOOK="$REPO_ROOT/hooks/check-pending-subagents.sh"

setup() {
  TEST_TMP="$(mktemp -d)"
  TARGET="$TEST_TMP/target-repo"
  mkdir -p "$TARGET/.claude"
  VAULT="$TEST_TMP/vault"
  mkdir -p "$VAULT"
  FAILED_LOG="$VAULT/failed-writes.log"
}

teardown() {
  rm -rf "$TEST_TMP"
}

write_active_thread() {
  cat > "$TARGET/.claude/active-thread.json" <<EOF
{ "vault_root": "$VAULT", "repo": "repo-1", "thread": "thread-a" }
EOF
}

copy_run() {
  # $1 = fixture run folder name under tests/fixtures/vault/repo-1/thread-a/subagents/
  mkdir -p "$VAULT/repo-1/thread-a/subagents"
  cp -r "$REPO_ROOT/tests/fixtures/vault/repo-1/thread-a/subagents/$1" \
        "$VAULT/repo-1/thread-a/subagents/$1"
}

# $1 = hook_event_name, $2 = SessionEnd reason (optional)
run_hook() {
  jq -n --arg event "$1" --arg cwd "$TARGET" --arg reason "${2:-prompt_input_exit}" \
    '{session_id: "test-session", cwd: $cwd, hook_event_name: $event, reason: $reason, stop_hook_active: false}' \
    | "$HOOK"
}

# ---- Stop ----

@test "Stop: silent when there is no active-thread.json" {
  run run_hook Stop
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "Stop: silent when the thread has no subagent runs at all" {
  write_active_thread
  mkdir -p "$VAULT/repo-1/thread-a/subagents"

  run run_hook Stop
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "Stop: silent when every subagent run is completed" {
  write_active_thread
  copy_run run-completed

  run run_hook Stop
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "Stop: warns via systemMessage, listing each pending run, without blocking" {
  write_active_thread
  copy_run run-running
  copy_run run-dispatched
  copy_run run-completed

  run run_hook Stop
  [ "$status" -eq 0 ]
  msg="$(echo "$output" | jq -r '.systemMessage')"
  [[ "$msg" == *"run-running (running)"* ]]
  [[ "$msg" == *"run-dispatched (dispatched)"* ]]
  [[ "$msg" != *"run-completed"* ]]
  # nothing that would keep Claude from stopping
  [ "$(echo "$output" | jq 'has("decision") or has("continue")')" = "false" ]
}

@test "Stop: recognizes a quoted status, as basic-memory may write it" {
  write_active_thread
  run_dir="$VAULT/repo-1/thread-a/subagents/run-quoted"
  mkdir -p "$run_dir"
  printf -- "---\ntitle: agent-use-tracking\nstatus: 'running'\n---\n\n# Run log\n" > "$run_dir/agent-use-tracking.md"

  run run_hook Stop
  [ "$status" -eq 0 ]
  [[ "$(echo "$output" | jq -r '.systemMessage')" == *"run-quoted (running)"* ]]
}

@test "Stop: warns again on every turn while runs stay pending (no marker state)" {
  write_active_thread
  copy_run run-running

  run run_hook Stop
  [ "$status" -eq 0 ]
  [[ "$output" == *"run-running"* ]]

  run run_hook Stop
  [ "$status" -eq 0 ]
  [[ "$output" == *"run-running"* ]]
}

@test "Stop: never writes failed-writes.log" {
  write_active_thread
  copy_run run-running

  run run_hook Stop
  [ "$status" -eq 0 ]
  [ ! -e "$FAILED_LOG" ]
}

# ---- SessionEnd ----

@test "SessionEnd: does nothing when there is no active-thread.json" {
  run run_hook SessionEnd
  [ "$status" -eq 0 ]
  [ ! -e "$FAILED_LOG" ]
}

@test "SessionEnd: does not create failed-writes.log when nothing is pending" {
  write_active_thread
  copy_run run-completed

  run run_hook SessionEnd
  [ "$status" -eq 0 ]
  [ ! -e "$FAILED_LOG" ]
}

@test "SessionEnd: records one abandoned line per pending run, in the dead-letter format" {
  write_active_thread
  copy_run run-running
  copy_run run-dispatched
  copy_run run-completed

  run run_hook SessionEnd other
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ "$(wc -l < "$FAILED_LOG")" -eq 2 ]
  grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z \| repo-1/thread-a \| subagent-run \| abandoned: run-running still running at session end \(reason: other\)$' "$FAILED_LOG"
  grep -qF "abandoned: run-dispatched still dispatched" "$FAILED_LOG"
  ! grep -qF "run-completed" "$FAILED_LOG"
}

@test "SessionEnd: appends to an existing failed-writes.log without touching earlier lines" {
  write_active_thread
  copy_run run-running
  echo "2026-09-26T10:00:00Z | repo-1/thread-a | decision | earlier failure" > "$FAILED_LOG"

  run run_hook SessionEnd
  [ "$status" -eq 0 ]
  [ "$(head -n1 "$FAILED_LOG")" = "2026-09-26T10:00:00Z | repo-1/thread-a | decision | earlier failure" ]
  [ "$(wc -l < "$FAILED_LOG")" -eq 2 ]
}

@test "SessionEnd: a second session end does not record the same run twice" {
  write_active_thread
  copy_run run-running

  run_hook SessionEnd
  run_hook SessionEnd resume

  [ "$(grep -c "abandoned: run-running " "$FAILED_LOG")" -eq 1 ]
}

@test "ignores events it isn't registered for" {
  write_active_thread
  copy_run run-running

  run run_hook PreToolUse
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ ! -e "$FAILED_LOG" ]
}
