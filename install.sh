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
#                  to Claude Code over SSE (see
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

TARGET=""
BASIC_MEMORY_ROOT=""
FORCE=false

# basic-memory reachability, filled in by steps 1-2:
#   BM_MODE                 "docker" or "cli"
#   BM_DOCKER_CONTAINER      container id, docker mode only
#   BM_DOCKER_URL            SSE endpoint URL, docker mode only
#   BM_DOCKER_HOST_DATA_DIR  host path bind-mounted into the container
#                            at /app/data, docker mode only
BM_MODE=""
BM_DOCKER_CONTAINER=""
BM_DOCKER_URL=""
BM_DOCKER_HOST_DATA_DIR=""
BM_DOCKER_CONTAINER_DATA_DIR="/app/data"

usage() {
  echo "Usage: $0 /path/to/target-repo [--basic-memory-root /path/to/dir] [--force]"
  exit 1
}

# Runs a `basic-memory` subcommand against whichever deployment was
# detected — the local CLI, or `docker exec` into the running container.
# Every later step that needs to talk to basic-memory's CLI goes through
# this instead of calling `basic-memory` directly.
bm() {
  if [ "$BM_MODE" = "docker" ]; then
    docker exec "$BM_DOCKER_CONTAINER" basic-memory "$@"
  else
    basic-memory "$@"
  fi
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

# True if basic-memory already has a project named exactly "asynthlogr".
# `project list --json` ({"projects": [{"name": ...}]}) only exists in
# newer basic-memory; older releases (e.g. 0.18.x, still the cached
# `latest` in many Docker setups) print only a table.
bm_has_asynthlogr_project() {
  local out
  if out="$(bm project list --json 2>/dev/null)"; then
    echo "$out" | grep -qE '"name"[[:space:]]*:[[:space:]]*"asynthlogr"'
  else
    # Table rows look like "│ asynthlogr │ /asynthlogr │ │"; match the
    # whole first cell so "asynthlogr-old" doesn't count. "│" is multibyte,
    # so use alternation, not a bracket expression (which breaks under
    # the C locale).
    bm project list 2>/dev/null | grep -qE '^(│|\|)[[:space:]]*asynthlogr[[:space:]]*(│|\|)'
  fi
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
      # The image's Dockerfile/docker-compose.yml both run
      # `basic-memory mcp --transport sse --host 0.0.0.0 --port 8000` —
      # SSE only, no HTTP-streamable — so we register with --transport sse.
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
          BM_DOCKER_URL="http://localhost:${host_port}/sse"
          BM_DOCKER_HOST_DATA_DIR="$host_data_dir"
          echo "  found running basic-memory container ($candidate)"
          echo "  MCP endpoint:            $BM_DOCKER_URL"
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
    echo "  Registering basic-memory MCP server (SSE, Docker) with Claude Code..."
    (cd "$TARGET" && claude mcp add --transport sse basic-memory "$BM_DOCKER_URL")
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
echo "[5/13] Ensuring basic-memory is initialized..."
# basic-memory has no explicit init command — it creates its config
# (~/.basic-memory/config.json) and default project on first use.
# Running `project list` once is enough to trigger that if it hasn't
# happened yet. In Docker mode the container already did this on its
# own first start, but the check is harmless and confirms it's alive.
if ! bm project list >/dev/null 2>&1; then
  echo "ERROR: 'basic-memory project list' failed"
  if [ "$BM_MODE" = "docker" ]; then
    echo "(via docker exec into $BM_DOCKER_CONTAINER)."
    echo "The container is up but basic-memory inside it isn't responding —"
    echo "check 'docker logs $BM_DOCKER_CONTAINER' before re-running this installer."
  else
    echo ". basic-memory does not appear to be working correctly even after"
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
# The path passed to `basic-memory project add` must be a path *as
# basic-memory itself sees it* — in Docker mode that's the container-side
# path under /app/data, not the host path, even though ASYNTHLOGR_DIR
# above (used for config.json and for humans/Obsidian) is the host path.
if [ "$BM_MODE" = "docker" ]; then
  ASYNTHLOGR_PROJECT_PATH="$BM_DOCKER_CONTAINER_DATA_DIR/asynthlogr"
else
  ASYNTHLOGR_PROJECT_PATH="$ASYNTHLOGR_DIR"
fi
if bm_has_asynthlogr_project; then
  echo "  'asynthlogr' project already registered."
else
  bm project add asynthlogr "$ASYNTHLOGR_PROJECT_PATH"
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
  "$TARGET/.claude/asynthlogr/formats"

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

# ---- step 9: copy Stop hook script + skills ----
echo "[9/13] Installing Stop hook script and skills..."
cp "$SCRIPT_DIR/hooks/check-pending-subagents.sh" "$TARGET/.claude/hooks/check-pending-subagents.sh"
chmod +x "$TARGET/.claude/hooks/check-pending-subagents.sh"
for skill in i-have-adhd obsidian-notation-expert obsidian-node-link-expert; do
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
  "basic_memory_mode": "docker",
  "basic_memory_docker_container": "$BM_DOCKER_CONTAINER",
  "basic_memory_mcp_endpoint": "$BM_DOCKER_URL"
}
EOF
else
  cat > "$TARGET/.claude/asynthlogr.config.json" <<EOF
{
  "basic_memory_dir": "$ASYNTHLOGR_DIR",
  "basic_memory_project": "asynthlogr",
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
echo "                        .claude/asynthlogr/formats/*, .claude/asynthlogr.config.json"
echo ""
echo "Note: .claude/active-thread.json is NOT created here — the orchestrator"
echo "writes it itself at the start of each session (see AGENTS.md)."
