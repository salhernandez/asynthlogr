#!/usr/bin/env bats
#
# Unit tests for hooks/session-ids.sh, registered for SessionStart
# (prints the session's ID into the orchestrator's context) and
# SubagentStart (injects a tracked subagent's agent_id via
# additionalContext).

REPO_ROOT="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../.." && pwd)"
HOOK="$REPO_ROOT/hooks/session-ids.sh"

setup() {
  TEST_TMP="$(mktemp -d)"
  TARGET="$TEST_TMP/target-repo"
  mkdir -p "$TARGET/.claude/agents"
  echo '{"basic_memory_dir": "/vault/asynthlogr"}' > "$TARGET/.claude/asynthlogr.config.json"
  cp "$REPO_ROOT"/agents/*.md "$TARGET/.claude/agents/"
  export CLAUDE_PROJECT_DIR="$TARGET"
}

teardown() {
  rm -rf "$TEST_TMP"
}

session_start() {
  jq -n --arg cwd "$TARGET" \
    '{session_id: "00893aaf-19fa-41d2-8238-13269b9b3ca0", transcript_path: "/home/u/.claude/projects/p/00893aaf-19fa-41d2-8238-13269b9b3ca0.jsonl", cwd: $cwd, hook_event_name: "SessionStart", source: "startup"}' \
    | "$HOOK"
}

# $1 = agent_type
subagent_start() {
  jq -n --arg cwd "$TARGET" --arg type "$1" \
    '{session_id: "00893aaf-19fa-41d2-8238-13269b9b3ca0", cwd: $cwd, hook_event_name: "SubagentStart", agent_id: "agent-a1b2c3d4", agent_type: $type}' \
    | "$HOOK"
}

@test "SessionStart: tells the orchestrator its session ID, transcript, and how to resume" {
  run session_start
  [ "$status" -eq 0 ]
  [[ "$output" == *"this Claude Code session's ID is 00893aaf-19fa-41d2-8238-13269b9b3ca0 (source: startup)"* ]]
  [[ "$output" == *"its transcript is /home/u/.claude/projects/p/00893aaf-19fa-41d2-8238-13269b9b3ca0.jsonl"* ]]
  [[ "$output" == *"claude --resume 00893aaf-19fa-41d2-8238-13269b9b3ca0"* ]]
}

@test "SessionStart: silent in a repo without asynthlogr installed" {
  rm "$TARGET/.claude/asynthlogr.config.json"
  run session_start
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "SubagentStart: hands a tracked subagent its agent_id and parent session ID" {
  run subagent_start research-agent
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.hookSpecificOutput.hookEventName')" = "SubagentStart" ]
  ctx="$(echo "$output" | jq -r '.hookSpecificOutput.additionalContext')"
  [[ "$ctx" == *'agent_id: "agent-a1b2c3d4"'* ]]
  [[ "$ctx" == *'parent_session_id: "00893aaf-19fa-41d2-8238-13269b9b3ca0"'* ]]
}

@test "SubagentStart: leaves subagents without a Tracking Contract alone" {
  run subagent_start decision-logger
  [ "$status" -eq 0 ]
  [ -z "$output" ]

  run subagent_start Explore
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "ignores events it isn't registered for" {
  run bash -c "jq -n --arg cwd '$TARGET' '{session_id: \"s\", cwd: \$cwd, hook_event_name: \"Stop\"}' | '$HOOK'"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}
