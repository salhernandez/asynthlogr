#!/usr/bin/env bash
#
# asynthlogr session/agent ID hook. Registered for two events, branching
# on hook_event_name, so the IDs that get logged always come from Claude
# Code itself, never from a model's guess:
#
#   SessionStart   — prints this session's ID and transcript path as plain
#                    text, which Claude Code adds to the orchestrator's
#                    context. AGENTS.md tells it to record them (resume
#                    later with `claude --resume <session_id>`).
#   SubagentStart  — for subagents that keep an asynthlogr tracking note
#                    (their definition carries a "## Tracking Contract"),
#                    injects the subagent's own agent_id and its parent
#                    session's ID via additionalContext, for the subagent
#                    to record in its tracking note. A subagent is resumed
#                    from inside its parent session, by agent_id.
#
# Never blocks and never writes anything itself.

set -euo pipefail

command -v jq >/dev/null 2>&1 || exit 0

INPUT_JSON="$(cat)"
EVENT="$(echo "$INPUT_JSON" | jq -r '.hook_event_name // empty')"
SESSION_ID="$(echo "$INPUT_JSON" | jq -r '.session_id // empty')"
CWD="$(echo "$INPUT_JSON" | jq -r '.cwd // empty')"
PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$CWD}"

# Only in repos where asynthlogr is installed.
[ -f "$PROJECT_DIR/.claude/asynthlogr.config.json" ] || exit 0
[ -n "$SESSION_ID" ] || exit 0

case "$EVENT" in
  SessionStart)
    transcript="$(echo "$INPUT_JSON" | jq -r '.transcript_path // empty')"
    source="$(echo "$INPUT_JSON" | jq -r '.source // "startup"')"
    echo "asynthlogr: this Claude Code session's ID is $SESSION_ID (source: $source)."
    [ -z "$transcript" ] || echo "asynthlogr: its transcript is $transcript"
    echo "asynthlogr: record these as described in AGENTS.md (\"At session start\"); resume later with: claude --resume $SESSION_ID"
    ;;

  SubagentStart)
    agent_id="$(echo "$INPUT_JSON" | jq -r '.agent_id // empty')"
    agent_type="$(echo "$INPUT_JSON" | jq -r '.agent_type // empty')"
    [ -n "$agent_id" ] && [ -n "$agent_type" ] || exit 0
    definition="$PROJECT_DIR/.claude/agents/$agent_type.md"
    grep -q '^## Tracking Contract' "$definition" 2>/dev/null || exit 0
    jq -n --arg ctx "asynthlogr: your agent_id is $agent_id and your parent session's ID is $SESSION_ID. When you first update your tracking note (status: running), also set agent_id: \"$agent_id\" and parent_session_id: \"$SESSION_ID\" in its metadata." \
      '{hookSpecificOutput: {hookEventName: "SubagentStart", additionalContext: $ctx}}'
    ;;
esac

exit 0
