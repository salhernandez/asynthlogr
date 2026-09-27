#!/usr/bin/env bash
#
# asynthlogr installer
# Usage: ./install.sh /path/to/target-repo [--basic-memory-root /path/to/dir] [--force]
#
# --basic-memory-root points at basic-memory's own storage root (the
# folder it keeps ALL its projects under). If omitted, basic-memory's
# own default (~/basic-memory) is used. asynthlogr does NOT get its
# own arbitrary directory — it lives at <basic-memory-root>/asynthlogr
# and is registered as its own basic-memory project named "asynthlogr".
#
# basic-memory can be reached two ways, and this installer detects
# both, preferring an existing Docker deployment if one is already up:
#
#   - CLI mode:    the `basic-memory` binary installed locally (via uv),
#                  talking to Claude Code over stdio.
#   - Docker mode: an already-running container of the official
#                  ghcr.io/basicmachines-co/basic-memory image, talking
#                  to Claude Code over SSE or streamable HTTP at
#                  http://localhost:<port>/mcp (see
#                  https://github.com/basicmachines-co/basic-memory/blob/main/docker-compose.yml).
#
# IMPORTANT: this installer NEVER starts Docker itself and NEVER starts
# a basic-memory container itself. It only checks whether Docker is
# already installed and running, and whether a basic-memory container
# is already up — if so, it hooks onto that. If not, it falls back to
# the local CLI (installing it via uv if needed), exactly as before.
#
# See docs/architecture.md for what each step does and why, and
# docs/open-items.md for what is still unverified against live tools.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Every basic-memory interaction goes through its MCP server, never the
# basic-memory CLI (see bin/mcp-client.sh for why).
# shellcheck source=bin/mcp-client.sh
. "$SCRIPT_DIR/bin/mcp-client.sh"

TARGET=""
BASIC_MEMORY_ROOT=""
FORCE=false

# basic-memory reachability, filled in by steps 1-2:
#   BM_MODE                 "docker" or "cli"
#   BM_DOCKER_CONTAINER      container id, docker mode only
#   BM_DOCKER_URL            MCP endpoint URL, docker mode only
#   BM_DOCKER_TRANSPORT      "sse" or "http" (claude mcp add --transport)
#   BM_DOCKER_HOST_DATA_DIR  host path bind-mounted into the container
#                            at /app/data, docker mode only
BM_MODE=""
BM_DOCKER_CONTAINER=""
BM_DOCKER_URL=""
BM_DOCKER_TRANSPORT=""
BM_DOCKER_HOST_DATA_DIR=""
BM_DOCKER_CONTAINER_DATA_DIR="/app/data"

usage() {
  echo "Usage: $0 /path/to/target-repo [--basic-memory-root /path/to/dir] [--force]"
  exit 1
}

# Maps a bind-mount source reported by `docker inspect` to a path this
# shell can use. Docker Desktop on Windows reports sources as paths inside
# its VM (/run/desktop/mnt/host/c/Users/...), which exist nowhere on the
# host: map them to Git Bash's /c/... or WSL's /mnt/c/... form. Anything
# else (Linux, macOS) is already a real host path.
host_path_from_docker() {
  local src="$1" rest drive
  case "$src" in
    /run/desktop/mnt/host/*)
      rest="${src#/run/desktop/mnt/host/}"
      drive="${rest%%/*}"
      if [ -d "/$drive" ]; then
        echo "/$rest"
      elif [ -d "/mnt/$drive" ]; then
        echo "/mnt/$rest"
      else
        echo "$src"
      fi
      ;;
    *) echo "$src" ;;
  esac
}

# Runs "$@" with a time limit of $1 seconds. `timeout` is GNU coreutils,
# absent on stock macOS (Homebrew's coreutils installs it as `gtimeout`),
# so fall back to a background job that gets killed when time's up.
run_with_timeout() {
  local secs="$1"; shift
  if command -v timeout >/dev/null 2>&1; then
    timeout "$secs" "$@"
  elif command -v gtimeout >/dev/null 2>&1; then
    gtimeout "$secs" "$@"
  else
    "$@" &
    local pid=$!
    ( sleep "$secs"; kill "$pid" 2>/dev/null ) &
    local watcher=$!
    local rc=0
    wait "$pid" || rc=$?
    kill "$watcher" 2>/dev/null || true
    return "$rc"
  fi
}

# ---- parse args ----
[ $# -ge 1 ] || usage
TARGET="$1"; shift
while [ $# -gt 0 ]; do
  case "$1" in
    --basic-memory-root) BASIC_MEMORY_ROOT="$2"; shift 2 ;;
    --force) FORCE=true; shift ;;
    *) echo "Unknown argument: $1"; usage ;;
  esac
done

[ -d "$TARGET" ] || { echo "Target repo does not exist: $TARGET"; exit 1; }
TARGET="$(cd "$TARGET" && pwd)"

echo "== asynthlogr install -> $TARGET =="

# ---- step 1: look for an already-running basic-memory Docker deployment ----
# Read-only detection only. This installer never runs `docker start`,
# `docker run`, or `docker compose up` — if Docker isn't installed, isn't
# running, or has no basic-memory container up, it just falls through to
# the CLI path in step 2, same as before this feature existed.
echo "[1/13] Checking for an existing basic-memory Docker deployment..."
if command -v docker >/dev/null 2>&1; then
  if run_with_timeout 5 docker info >/dev/null 2>&1; then
    echo "  Docker is installed and running."
    # Prefer matching by image (catches a renamed container using the
    # official image), fall back to the compose file's documented
    # container_name for a locally-built image.
    candidate="$(docker ps --filter 'ancestor=ghcr.io/basicmachines-co/basic-memory' --format '{{.ID}}' 2>/dev/null | head -n1 || true)"
    if [ -z "$candidate" ]; then
      candidate="$(docker ps --filter 'name=basic-memory-server' --format '{{.ID}}' 2>/dev/null | head -n1 || true)"
    fi
    if [ -n "$candidate" ]; then
      # The container's own command says how it serves MCP. The official
      # image runs `basic-memory mcp --transport sse --host 0.0.0.0 --port
      # 8000`, and basic-memory mounts both its SSE and streamable-HTTP
      # transports at --path, which defaults to /mcp (not /sse).
      bm_cmd="$(docker inspect "$candidate" --format '{{range .Config.Cmd}}{{println .}}{{end}}' 2>/dev/null | tr -d '\r' || true)"
      bm_transport="$(echo "$bm_cmd" | awk 'prev == "--transport" { print; exit } { prev = $0 }')"
      bm_path="$(echo "$bm_cmd" | awk 'prev == "--path" { print; exit } { prev = $0 }')"
      [ -n "$bm_path" ] || bm_path="/mcp"
      case "$bm_transport" in
        streamable-http) bm_claude_transport="http" ;;
        *) bm_claude_transport="sse" ;;
      esac
      port_line="$(docker port "$candidate" 8000/tcp 2>/dev/null | head -n1 || true)"
      host_port="${port_line##*:}"
      if [ -n "$host_port" ] && [ "$host_port" != "$port_line" ]; then
        # The official image/compose file bind-mounts the knowledge
        # directory at /app/data. Find the real host path so we don't
        # guess at where basic-memory-root should live.
        host_data_dir="$(docker inspect "$candidate" \
          --format '{{range .Mounts}}{{if eq .Destination "/app/data"}}{{.Source}}{{"\n"}}{{end}}{{end}}' \
          2>/dev/null | head -n1 || true)"
        host_data_dir="$(host_path_from_docker "$host_data_dir")"
        if [ -n "$host_data_dir" ] && [ -d "$host_data_dir" ]; then
          BM_MODE="docker"
          BM_DOCKER_CONTAINER="$candidate"
          BM_DOCKER_URL="http://localhost:${host_port}${bm_path}"
          BM_DOCKER_TRANSPORT="$bm_claude_transport"
          BM_DOCKER_HOST_DATA_DIR="$host_data_dir"
          echo "  found running basic-memory container ($candidate)"
          echo "  MCP endpoint:            $BM_DOCKER_URL ($BM_DOCKER_TRANSPORT)"
          echo "  host data directory:     $BM_DOCKER_HOST_DATA_DIR  (mounted at /app/data in the container)"
        else
          echo "  found a basic-memory container ($candidate) but it has no"
          echo "  /app/data bind mount this installer recognizes, or its host"
          echo "  side isn't visible from here — this"
          echo "  installer only knows the official image's default layout"
          echo "  (see https://github.com/basicmachines-co/basic-memory/blob/main/docker-compose.yml)."
          echo "  Falling back to the local basic-memory CLI instead."
        fi
      else
        echo "  found a basic-memory container ($candidate) but couldn't"
        echo "  determine its published port-8000 mapping. Falling back to"
        echo "  the local basic-memory CLI instead."
      fi
    else
      echo "  no basic-memory container currently running."
    fi
  else
    echo "  Docker is installed but its daemon isn't running (or isn't"
    echo "  reachable) — not starting it. Falling back to the local"
    echo "  basic-memory CLI."
  fi
else
  echo "  Docker not found on PATH — skipping Docker detection."
fi

# ---- step 2: ensure basic-memory is reachable one way or the other ----
echo "[2/13] Ensuring basic-memory is reachable..."
if [ "$BM_MODE" = "docker" ]; then
  echo "  using the already-running Docker deployment detected in step 1."
else
  echo "  checking for the basic-memory CLI..."
  if ! command -v basic-memory >/dev/null 2>&1; then
    echo "  basic-memory CLI not found. Installing via uv..."
    if ! command -v uv >/dev/null 2>&1; then
      echo "ERROR: uv is required to install basic-memory but was not found on PATH."
      echo "Install uv first: https://docs.astral.sh/uv/getting-started/installation/"
      echo "(Or start your existing basic-memory Docker deployment and re-run —"
      echo "this installer will hook onto it instead.)"
      echo "basic-memory is a REQUIRED dependency for asynthlogr — install cannot continue."
      exit 1
    fi
    # Reference: https://github.com/basicmachines-co/basic-memory
    uv tool install basic-memory
    command -v basic-memory >/dev/null 2>&1 || {
      echo "ERROR: basic-memory install via uv appeared to succeed but the"
      echo "'basic-memory' command still isn't on PATH. Check your uv tool"
      echo "install location is on PATH, then re-run this installer."
      exit 1
    }
    echo "  basic-memory installed."
  else
    echo "  basic-memory found."
  fi
  BM_MODE="cli"
fi
# The MCP server the installer talks to: the running container's, or a
# stdio server from the local CLI (the same one Claude Code will launch).
if [ "$BM_MODE" = "docker" ]; then
  MCP_TRANSPORT="$BM_DOCKER_TRANSPORT"
  MCP_TARGET="$BM_DOCKER_URL"
else
  MCP_TRANSPORT="stdio"
  MCP_TARGET="basic-memory mcp"
fi

# ---- step 3: ensure basic-memory is registered as an MCP server for Claude Code ----
echo "[3/13] Checking basic-memory is registered as a Claude Code MCP server..."
# `claude mcp add` defaults to local scope, which is keyed to the current
# directory — so both commands run from inside the target repo, not from
# wherever this installer was launched.
if ! command -v claude >/dev/null 2>&1; then
  echo "ERROR: 'claude' CLI not found on PATH. Cannot register basic-memory as an MCP server."
  exit 1
fi
if ! (cd "$TARGET" && claude mcp list 2>/dev/null) | grep -qi 'basic-memory'; then
  if [ "$BM_MODE" = "docker" ]; then
    echo "  Registering basic-memory MCP server ($BM_DOCKER_TRANSPORT, Docker) with Claude Code..."
    (cd "$TARGET" && claude mcp add --transport "$BM_DOCKER_TRANSPORT" basic-memory "$BM_DOCKER_URL")
  else
    echo "  Registering basic-memory MCP server (stdio) with Claude Code..."
    (cd "$TARGET" && claude mcp add basic-memory -- uvx basic-memory mcp)
  fi
else
  echo "  basic-memory already registered."
fi

# ---- step 4: determine basic-memory's storage root ----
echo "[4/13] Determining basic-memory storage root..."
if [ "$BM_MODE" = "docker" ]; then
  if [ -n "$BASIC_MEMORY_ROOT" ] && [ "$BASIC_MEMORY_ROOT" != "$BM_DOCKER_HOST_DATA_DIR" ]; then
    echo "  NOTE: --basic-memory-root ($BASIC_MEMORY_ROOT) was given, but the"
    echo "  running container only sees $BM_DOCKER_HOST_DATA_DIR (its /app/data"
    echo "  mount). Using the container's actual mount instead, so asynthlogr's"
    echo "  files land somewhere basic-memory can actually see them."
  fi
  BASIC_MEMORY_ROOT="$BM_DOCKER_HOST_DATA_DIR"
  echo "  using the running container's /app/data mount: $BASIC_MEMORY_ROOT"
else
  if [ -z "$BASIC_MEMORY_ROOT" ]; then
    BASIC_MEMORY_ROOT="$HOME/basic-memory"
    echo "  no --basic-memory-root given, using basic-memory's own default: $BASIC_MEMORY_ROOT"
  fi
fi
mkdir -p "$BASIC_MEMORY_ROOT"
BASIC_MEMORY_ROOT="$(cd "$BASIC_MEMORY_ROOT" && pwd)"

# ---- step 5: ensure basic-memory itself is initialized ----
echo "[5/13] Ensuring basic-memory's MCP server answers..."
# Listing projects over MCP both confirms the server works and, on a
# fresh CLI install, lets basic-memory create its config and default
# project on first use.
if ! BM_PROJECTS="$(mcp_call "$MCP_TRANSPORT" "$MCP_TARGET" list_memory_projects '{}' 2>&1)"; then
  echo "ERROR: basic-memory's MCP server didn't answer list_memory_projects"
  echo "  ($MCP_TRANSPORT: $MCP_TARGET):"
  echo "  $BM_PROJECTS" | cut -c1-400
  if [ "$BM_MODE" = "docker" ]; then
    echo "The container is up but its MCP server isn't responding — check"
    echo "'docker logs $BM_DOCKER_CONTAINER' before re-running this installer."
  else
    echo "basic-memory does not appear to be working correctly even after"
    echo "install. Check the basic-memory installation manually before"
    echo "re-running this installer."
  fi
  exit 1
fi
echo "  basic-memory is initialized."

# ---- step 6: create + register the asynthlogr project inside basic-memory ----
echo "[6/13] Registering asynthlogr as its own basic-memory project..."
ASYNTHLOGR_DIR="$BASIC_MEMORY_ROOT/asynthlogr"
mkdir -p "$ASYNTHLOGR_DIR"
# The path passed to create_memory_project must be a path *as
# basic-memory itself sees it* — in Docker mode that's the container-side
# path under /app/data, not the host path, even though ASYNTHLOGR_DIR
# above (used for config.json and for humans/Obsidian) is the host path.
if [ "$BM_MODE" = "docker" ]; then
  ASYNTHLOGR_PROJECT_PATH="$BM_DOCKER_CONTAINER_DATA_DIR/asynthlogr"
else
  ASYNTHLOGR_PROJECT_PATH="$ASYNTHLOGR_DIR"
fi
# Through MCP in both modes. In Docker mode this matters beyond
# consistency: a long-running server keeps the config it loaded at
# startup, and on its next project sync deletes any project it doesn't
# know about ("deleted from config, source of truth") — including one a
# separate basic-memory CLI process just added. Creating the project
# through the server updates its in-memory config, config.json and its
# database together.
if mcp_lists_project "$BM_PROJECTS" asynthlogr; then
  echo "  'asynthlogr' project already registered."
else
  if ! mcp_result="$(mcp_call "$MCP_TRANSPORT" "$MCP_TARGET" create_memory_project       '{"project_name": "asynthlogr", "project_path": "'"$ASYNTHLOGR_PROJECT_PATH"'"}' 2>&1)"; then
    echo "ERROR: couldn't create the 'asynthlogr' basic-memory project over MCP"
    echo "  ($MCP_TRANSPORT: $MCP_TARGET):"
    echo "  $mcp_result" | cut -c1-400
    exit 1
  fi
  if ! BM_PROJECTS="$(mcp_call "$MCP_TRANSPORT" "$MCP_TARGET" list_memory_projects '{}' 2>&1)"      || ! mcp_lists_project "$BM_PROJECTS" asynthlogr; then
    echo "ERROR: basic-memory accepted the 'asynthlogr' project but doesn't list it."
    exit 1
  fi
  echo "  registered 'asynthlogr' -> $ASYNTHLOGR_PROJECT_PATH"
fi
# failed-writes.log is a plain ops log, not a note. basic-memory honors a
# project's own .gitignore, so this keeps the log out of its index.
IGNORE_FILE="$ASYNTHLOGR_DIR/.gitignore"
if ! grep -qxF 'failed-writes.log' "$IGNORE_FILE" 2>/dev/null; then
  echo 'failed-writes.log' >> "$IGNORE_FILE"
fi

# ---- step 7: validate target, create dirs ----
echo "[7/13] Preparing target directories..."
mkdir -p "$TARGET/.claude/agents" "$TARGET/.claude/hooks" "$TARGET/.claude/skills" \
  "$TARGET/.claude/asynthlogr/formats" "$TARGET/.claude/asynthlogr/bin"

# ---- step 8: copy subagent definitions ----
echo "[8/13] Installing subagent definitions..."
for f in "$SCRIPT_DIR"/agents/*.md; do
  base="$(basename "$f")"
  dest="$TARGET/.claude/agents/$base"
  if [ -f "$dest" ] && [ "$FORCE" != true ]; then
    echo "  skip (exists): .claude/agents/$base  (use --force to overwrite)"
  else
    cp "$f" "$dest"
    echo "  installed: .claude/agents/$base"
  fi
done

# ---- step 9: copy hook script, report script, skills, formats ----
echo "[9/13] Installing hook and report scripts, skills, and formats..."
cp "$SCRIPT_DIR/hooks/check-pending-subagents.sh" "$TARGET/.claude/hooks/check-pending-subagents.sh"
chmod +x "$TARGET/.claude/hooks/check-pending-subagents.sh"
# The daily report generator, run manually via the /asynthlogr-report skill.
cp "$SCRIPT_DIR/bin/asynthlogr-report.sh" "$TARGET/.claude/asynthlogr/bin/asynthlogr-report.sh"
cp "$SCRIPT_DIR/bin/mcp-client.sh" "$TARGET/.claude/asynthlogr/bin/mcp-client.sh"
chmod +x "$TARGET/.claude/asynthlogr/bin/asynthlogr-report.sh"
for skill in i-have-adhd obsidian-notation-expert obsidian-node-link-expert asynthlogr-report; do
  mkdir -p "$TARGET/.claude/skills/$skill"
  cp "$SCRIPT_DIR/skills/$skill/SKILL.md" "$TARGET/.claude/skills/$skill/SKILL.md"
done
# The entry/message templates decision-logger and the orchestrator follow.
for fmt in decision-entry-format subagent-run-format; do
  cp "$SCRIPT_DIR/docs/$fmt.md" "$TARGET/.claude/asynthlogr/formats/$fmt.md"
done

# ---- step 10: register the pending-run hook for Stop + SessionEnd ----
echo "[10/13] Registering Stop and SessionEnd hooks in .claude/settings.json..."
SETTINGS="$TARGET/.claude/settings.json"
# One script handles both events (it branches on hook_event_name):
# Stop shows a non-blocking warning, SessionEnd records abandoned runs
# in failed-writes.log. The SessionEnd timeout raises Claude Code's
# default 1.5s SessionEnd budget so the scan isn't cut short.
HOOK_SCRIPT='$CLAUDE_PROJECT_DIR/.claude/hooks/check-pending-subagents.sh'
STOP_ENTRY='{"hooks":[{"type":"command","command":"'"$HOOK_SCRIPT"'"}]}'
SESSION_END_ENTRY='{"hooks":[{"type":"command","command":"'"$HOOK_SCRIPT"'","timeout":5}]}'

if [ ! -f "$SETTINGS" ]; then
  cat > "$SETTINGS" <<EOF
{
  "hooks": {
    "Stop": [
      $STOP_ENTRY
    ],
    "SessionEnd": [
      $SESSION_END_ENTRY
    ]
  }
}
EOF
  echo "  created .claude/settings.json"
else
  if ! command -v jq >/dev/null 2>&1; then
    echo "ERROR: jq is required to safely merge into an existing .claude/settings.json."
    echo "Install jq, or merge these hook entries into $SETTINGS by hand:"
    echo "  hooks.Stop:       $STOP_ENTRY"
    echo "  hooks.SessionEnd: $SESSION_END_ENTRY"
    exit 1
  fi
  if ! jq empty "$SETTINGS" 2>/dev/null; then
    echo "ERROR: $SETTINGS is not valid JSON. Refusing to touch it — fix it by hand first."
    exit 1
  fi
  # Idempotent: an event that already runs check-pending-subagents.sh
  # is left alone, so re-running the installer never adds duplicates.
  tmp="$(mktemp)"
  jq --argjson stop "$STOP_ENTRY" --argjson session_end "$SESSION_END_ENTRY" '
    def add_once($event; $entry):
      if any(.hooks[$event][]?.hooks[]?; (.command // "") | contains("check-pending-subagents.sh"))
      then .
      else .hooks[$event] = ((.hooks[$event] // []) + [$entry])
      end;
    add_once("Stop"; $stop) | add_once("SessionEnd"; $session_end)
  ' "$SETTINGS" > "$tmp"
  mv "$tmp" "$SETTINGS"
  echo "  merged Stop and SessionEnd hooks into existing .claude/settings.json"
fi

# ---- step 11: write asynthlogr.config.json ----
echo "[11/13] Writing .claude/asynthlogr.config.json..."
if [ "$BM_MODE" = "docker" ]; then
  cat > "$TARGET/.claude/asynthlogr.config.json" <<EOF
{
  "basic_memory_dir": "$ASYNTHLOGR_DIR",
  "basic_memory_project": "asynthlogr",
  "basic_memory_project_path": "$ASYNTHLOGR_PROJECT_PATH",
  "basic_memory_mode": "docker",
  "basic_memory_docker_container": "$BM_DOCKER_CONTAINER",
  "basic_memory_mcp_endpoint": "$BM_DOCKER_URL",
  "basic_memory_mcp_transport": "$BM_DOCKER_TRANSPORT"
}
EOF
else
  cat > "$TARGET/.claude/asynthlogr.config.json" <<EOF
{
  "basic_memory_dir": "$ASYNTHLOGR_DIR",
  "basic_memory_project": "asynthlogr",
  "basic_memory_project_path": "$ASYNTHLOGR_PROJECT_PATH",
  "basic_memory_mode": "cli"
}
EOF
fi
echo "  basic_memory_dir -> $ASYNTHLOGR_DIR  (mode: $BM_MODE)"

# ---- step 12: write/append AGENTS.md and CLAUDE.md ----
echo "[12/13] Writing AGENTS.md and CLAUDE.md..."
AGENTS_MD="$TARGET/AGENTS.md"
MARKER="## Decision & Activity Logging Protocol"
if [ ! -f "$AGENTS_MD" ]; then
  cp "$SCRIPT_DIR/templates/AGENTS.md.snippet" "$AGENTS_MD"
  echo "  created AGENTS.md"
elif grep -qF "$MARKER" "$AGENTS_MD"; then
  echo "  skip: AGENTS.md already contains the logging protocol"
else
  {
    echo ""
    echo ""
    cat "$SCRIPT_DIR/templates/AGENTS.md.snippet"
  } >> "$AGENTS_MD"
  echo "  appended protocol to existing AGENTS.md"
fi

CLAUDE_MD="$TARGET/CLAUDE.md"
if [ ! -f "$CLAUDE_MD" ]; then
  cp "$SCRIPT_DIR/templates/CLAUDE.md.pointer" "$CLAUDE_MD"
  echo "  created CLAUDE.md"
elif grep -q "AGENTS.md" "$CLAUDE_MD"; then
  echo "  skip: CLAUDE.md already references AGENTS.md"
else
  echo "" >> "$CLAUDE_MD"
  echo "Agent instructions, including the decision/activity logging protocol, also live in @AGENTS.md — read that file." >> "$CLAUDE_MD"
  echo "  appended pointer to existing CLAUDE.md"
fi

# ---- step 13: summary ----
echo "[13/13] Done."
echo ""
echo "Summary:"
echo "  basic-memory mode:     $BM_MODE"
if [ "$BM_MODE" = "docker" ]; then
  echo "  basic-memory container: $BM_DOCKER_CONTAINER ($BM_DOCKER_URL)"
fi
echo "  basic-memory root:    $BASIC_MEMORY_ROOT"
echo "  asynthlogr project:   $ASYNTHLOGR_DIR  (basic-memory project 'asynthlogr')"
echo "  target repo:          $TARGET"
echo "  files touched:        AGENTS.md, CLAUDE.md, .claude/settings.json,"
echo "                        .claude/agents/*, .claude/hooks/*, .claude/skills/*,"
echo "                        .claude/asynthlogr/formats/*, .claude/asynthlogr/bin/*,"
echo "                        .claude/asynthlogr.config.json"
echo ""
echo "Daily reports: run /asynthlogr-report in Claude Code (manual only)."
echo ""
echo "Note: .claude/active-thread.json is NOT created here — the orchestrator"
echo "writes it itself at the start of each session (see AGENTS.md)."
