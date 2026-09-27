#!/usr/bin/env bats
#
# Unit tests for install.sh. Runs against fixture target repos and
# stubbed external CLIs (claude, uv, basic-memory) — never touches a
# real Claude Code install, real basic-memory, or the real network.
#
# Run with: bats tests/unit/install_test.bats
# (or via tests/docker/run.sh for the containerized version)

REPO_ROOT="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../.." && pwd)"
INSTALL_SH="$REPO_ROOT/install.sh"
STUBS_SRC="$REPO_ROOT/tests/stubs/bin"

setup() {
  TEST_TMP="$(mktemp -d)"
  export HOME="$TEST_TMP/home"          # isolate ~/basic-memory default
  mkdir -p "$HOME"

  BIN_DIR="$TEST_TMP/bin"               # writable, per-test PATH dir
  mkdir -p "$BIN_DIR"
  cp "$STUBS_SRC/claude" "$BIN_DIR/claude"
  cp "$STUBS_SRC/uv" "$BIN_DIR/uv"
  cp "$STUBS_SRC/basic-memory" "$BIN_DIR/basic-memory"
  cp "$STUBS_SRC/mcp-stub-respond" "$BIN_DIR/mcp-stub-respond"
  chmod +x "$BIN_DIR"/*

  export ASYNTHLOGR_TESTS_ROOT="$REPO_ROOT/tests"
  export CLAUDE_STUB_STATE_DIR="$TEST_TMP/claude-state"
  export BM_STUB_STATE_DIR="$TEST_TMP/bm-state"
  # Real jq/git/mkdir/cp/grep are used from the host — no stub needed,
  # they're deterministic and don't touch network or external accounts.
  export PATH="$BIN_DIR:$PATH"

  TARGET="$TEST_TMP/target-repo"
  mkdir -p "$TARGET"
}

teardown() {
  rm -rf "$TEST_TMP"
}

copy_fixture_target() {
  # $1 = fixture name under tests/fixtures/target-repos/
  rm -rf "$TARGET"
  cp -r "$REPO_ROOT/tests/fixtures/target-repos/$1" "$TARGET"
}

@test "fresh install into an empty target repo succeeds and creates every expected file" {
  copy_fixture_target empty

  run "$INSTALL_SH" "$TARGET"
  [ "$status" -eq 0 ]

  [ -f "$TARGET/AGENTS.md" ]
  [ -f "$TARGET/CLAUDE.md" ]
  [ -f "$TARGET/.claude/settings.json" ]
  [ -f "$TARGET/.claude/asynthlogr.config.json" ]
  [ -f "$TARGET/.claude/agents/decision-logger.md" ]
  [ -f "$TARGET/.claude/agents/research-agent.md" ]
  [ -f "$TARGET/.claude/agents/planning-agent.md" ]
  [ -x "$TARGET/.claude/hooks/check-pending-subagents.sh" ]
  [ -x "$TARGET/.claude/hooks/session-ids.sh" ]
  [ -f "$TARGET/.claude/skills/i-have-adhd/SKILL.md" ]
  [ -f "$TARGET/.claude/skills/obsidian-notation-expert/SKILL.md" ]
  [ -f "$TARGET/.claude/skills/obsidian-node-link-expert/SKILL.md" ]
  [ -f "$TARGET/.claude/asynthlogr/formats/decision-entry-format.md" ]
  [ -f "$TARGET/.claude/asynthlogr/formats/subagent-run-format.md" ]
  [ -x "$TARGET/.claude/asynthlogr/bin/asynthlogr-report.sh" ]
  [ -f "$TARGET/.claude/skills/asynthlogr-report/SKILL.md" ]
}

@test "keeps failed-writes.log out of basic-memory's index, without duplicating the ignore line on re-run" {
  copy_fixture_target empty

  "$INSTALL_SH" "$TARGET"
  "$INSTALL_SH" "$TARGET"

  ignore_file="$HOME/basic-memory/asynthlogr/.gitignore"
  [ "$(grep -cxF 'failed-writes.log' "$ignore_file")" -eq 1 ]
}

@test "defaults basic_memory_dir to <HOME>/basic-memory/asynthlogr when --basic-memory-root is omitted" {
  copy_fixture_target empty

  run "$INSTALL_SH" "$TARGET"
  [ "$status" -eq 0 ]

  expected="$HOME/basic-memory/asynthlogr"
  actual="$(jq -r '.basic_memory_dir' "$TARGET/.claude/asynthlogr.config.json")"
  [ "$actual" = "$expected" ]
  [ -d "$expected" ]
}

@test "honors an explicit --basic-memory-root" {
  copy_fixture_target empty
  CUSTOM_ROOT="$TEST_TMP/custom-bm-root"

  run "$INSTALL_SH" "$TARGET" --basic-memory-root "$CUSTOM_ROOT"
  [ "$status" -eq 0 ]

  expected="$CUSTOM_ROOT/asynthlogr"
  actual="$(jq -r '.basic_memory_dir' "$TARGET/.claude/asynthlogr.config.json")"
  [ "$actual" = "$expected" ]
}

@test "installs basic-memory via uv when it isn't already on PATH" {
  copy_fixture_target empty
  rm -f "$BIN_DIR/basic-memory"          # simulate: not installed yet
  ! command -v basic-memory >/dev/null 2>&1

  run "$INSTALL_SH" "$TARGET"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Installing via uv"* ]]
  [ -x "$BIN_DIR/basic-memory" ]         # uv stub "installed" it
}

@test "skips the uv install when basic-memory is already present" {
  copy_fixture_target empty

  run "$INSTALL_SH" "$TARGET"
  [ "$status" -eq 0 ]
  [[ "$output" == *"basic-memory found"* ]]
  [[ "$output" != *"Installing via uv"* ]]
}

@test "registers basic-memory as an MCP server with claude when not already registered" {
  copy_fixture_target empty

  run "$INSTALL_SH" "$TARGET"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Registering basic-memory MCP server"* ]]
  grep -qi 'basic-memory' "$CLAUDE_STUB_STATE_DIR/claude-mcp-registered.txt"
  # local scope is per-directory: must be registered from the target repo
  [ "$(cat "$CLAUDE_STUB_STATE_DIR/claude-mcp-add-cwd.txt")" = "$(cd "$TARGET" && pwd -P)" ]
}

@test "does not re-register basic-memory with claude when already registered" {
  copy_fixture_target empty
  mkdir -p "$CLAUDE_STUB_STATE_DIR"
  echo "basic-memory" > "$CLAUDE_STUB_STATE_DIR/claude-mcp-registered.txt"

  run "$INSTALL_SH" "$TARGET"
  [ "$status" -eq 0 ]
  [[ "$output" == *"already registered"* ]]
}

@test "registers the asynthlogr basic-memory project when not already registered" {
  copy_fixture_target empty

  run "$INSTALL_SH" "$TARGET"
  [ "$status" -eq 0 ]
  [[ "$output" == *"registered 'asynthlogr'"* ]]
  grep -qi 'asynthlogr' "$BM_STUB_STATE_DIR/projects.txt"
}

@test "does not re-register the asynthlogr project when it already exists" {
  copy_fixture_target empty
  mkdir -p "$BM_STUB_STATE_DIR"
  echo "asynthlogr $HOME/basic-memory/asynthlogr" > "$BM_STUB_STATE_DIR/projects.txt"

  run "$INSTALL_SH" "$TARGET"
  [ "$status" -eq 0 ]
  [[ "$output" == *"already registered"* ]]
  [ "$(grep -c '^asynthlogr ' "$BM_STUB_STATE_DIR/projects.txt")" -eq 1 ]
}

@test "a project whose name merely contains 'asynthlogr' doesn't count as registered" {
  copy_fixture_target empty
  mkdir -p "$BM_STUB_STATE_DIR"
  echo "asynthlogr-old /somewhere/else" > "$BM_STUB_STATE_DIR/projects.txt"

  run "$INSTALL_SH" "$TARGET"
  [ "$status" -eq 0 ]
  [[ "$output" == *"registered 'asynthlogr'"* ]]
  grep -q "^asynthlogr $HOME/basic-memory/asynthlogr$" "$BM_STUB_STATE_DIR/projects.txt"
}

@test "registers the project over MCP (list, then create), never through the basic-memory CLI" {
  copy_fixture_target empty

  run "$INSTALL_SH" "$TARGET"
  [ "$status" -eq 0 ]
  # the stub rejects every CLI subcommand, so success already rules the
  # CLI out; this pins down the MCP calls that did the work
  [ "$(cat "$BM_STUB_STATE_DIR/mcp-calls.txt")" = "$(printf 'list_memory_projects\ncreate_memory_project\nlist_memory_projects')" ]
  [ "$(jq -r '.basic_memory_project_path' "$TARGET/.claude/asynthlogr.config.json")" = "$HOME/basic-memory/asynthlogr" ]
}

@test "fails cleanly when basic-memory's project list is broken (simulated init failure)" {
  copy_fixture_target empty
  export BM_STUB_FAIL_LIST=1

  run "$INSTALL_SH" "$TARGET"
  [ "$status" -ne 0 ]
  [[ "$output" == *"does not"*"appear to be working"* ]] || [[ "$output" == *"failed"* ]]
}

@test "merges the Stop hook into an existing settings.json without losing other content" {
  copy_fixture_target existing-settings

  run "$INSTALL_SH" "$TARGET"
  [ "$status" -eq 0 ]

  # original unrelated content survives
  [ "$(jq -r '.unrelatedSetting' "$TARGET/.claude/settings.json")" = "true" ]
  [ "$(jq -r '.hooks.Stop | length' "$TARGET/.claude/settings.json")" -eq 2 ]
  jq -e '.hooks.Stop[] | select(.hooks[0].command | contains("some-other-hook.sh"))' "$TARGET/.claude/settings.json" >/dev/null
  jq -e '.hooks.Stop[] | select(.hooks[0].command | contains("check-pending-subagents.sh"))' "$TARGET/.claude/settings.json" >/dev/null
  [ "$(jq -r '.hooks.SessionEnd | length' "$TARGET/.claude/settings.json")" -eq 1 ]
}

@test "a fresh settings.json registers the hook for both Stop and SessionEnd" {
  copy_fixture_target empty

  run "$INSTALL_SH" "$TARGET"
  [ "$status" -eq 0 ]

  settings="$TARGET/.claude/settings.json"
  jq -e '.hooks.Stop[0].hooks[0].command | endswith("/.claude/hooks/check-pending-subagents.sh")' "$settings" >/dev/null
  jq -e '.hooks.SessionEnd[0].hooks[0].command | endswith("/.claude/hooks/check-pending-subagents.sh")' "$settings" >/dev/null
  # raises Claude Code's default 1.5s SessionEnd budget
  [ "$(jq -r '.hooks.SessionEnd[0].hooks[0].timeout' "$settings")" -ge 2 ]
  # session/agent IDs for resuming
  jq -e '.hooks.SessionStart[0].hooks[0].command | endswith("/.claude/hooks/session-ids.sh")' "$settings" >/dev/null
  jq -e '.hooks.SubagentStart[0].hooks[0].command | endswith("/.claude/hooks/session-ids.sh")' "$settings" >/dev/null
}

@test "re-running the installer does not duplicate hook registrations" {
  copy_fixture_target existing-settings

  "$INSTALL_SH" "$TARGET"
  "$INSTALL_SH" "$TARGET"

  settings="$TARGET/.claude/settings.json"
  [ "$(jq '[.hooks.Stop[].hooks[] | select(.command | contains("check-pending-subagents.sh"))] | length' "$settings")" -eq 1 ]
  [ "$(jq '[.hooks.SessionEnd[].hooks[] | select(.command | contains("check-pending-subagents.sh"))] | length' "$settings")" -eq 1 ]
  [ "$(jq '[.hooks.SessionStart[].hooks[] | select(.command | contains("session-ids.sh"))] | length' "$settings")" -eq 1 ]
  [ "$(jq '[.hooks.SubagentStart[].hooks[] | select(.command | contains("session-ids.sh"))] | length' "$settings")" -eq 1 ]
  [ "$(jq -r '.hooks.Stop | length' "$settings")" -eq 2 ]
}

@test "refuses to touch a malformed existing settings.json" {
  copy_fixture_target malformed-settings
  original="$(cat "$TARGET/.claude/settings.json")"

  run "$INSTALL_SH" "$TARGET"
  [ "$status" -ne 0 ]
  [ "$(cat "$TARGET/.claude/settings.json")" = "$original" ]
}

@test "appends the logging protocol to an existing AGENTS.md and preserves prior content" {
  copy_fixture_target existing-agents

  run "$INSTALL_SH" "$TARGET"
  [ "$status" -eq 0 ]
  grep -q "Do not touch this." "$TARGET/AGENTS.md"
  grep -q "## Decision & Activity Logging Protocol" "$TARGET/AGENTS.md"
}

@test "appending AGENTS.md is idempotent across two runs" {
  copy_fixture_target existing-agents

  "$INSTALL_SH" "$TARGET"
  "$INSTALL_SH" "$TARGET"

  count="$(grep -c "## Decision & Activity Logging Protocol" "$TARGET/AGENTS.md")"
  [ "$count" -eq 1 ]
}

@test "--force refreshes the protocol between its markers and keeps the rest of AGENTS.md" {
  copy_fixture_target existing-agents
  "$INSTALL_SH" "$TARGET"
  # simulate an outdated protocol inside the block, plus user content after it
  sed -i.bak 's/Follow this exactly\./OLD PROTOCOL TEXT/' "$TARGET/AGENTS.md" && rm -f "$TARGET/AGENTS.md.bak"
  echo "## My notes after the block" >> "$TARGET/AGENTS.md"

  run "$INSTALL_SH" "$TARGET" --force
  [ "$status" -eq 0 ]
  [[ "$output" == *"refreshed the logging protocol in AGENTS.md"* ]]
  ! grep -q "OLD PROTOCOL TEXT" "$TARGET/AGENTS.md"
  grep -q "Do not touch this." "$TARGET/AGENTS.md"
  grep -qx "## My notes after the block" "$TARGET/AGENTS.md"
  [ "$(grep -c "## Decision & Activity Logging Protocol" "$TARGET/AGENTS.md")" -eq 1 ]
}

@test "without --force, an existing protocol block is left as is" {
  copy_fixture_target existing-agents
  "$INSTALL_SH" "$TARGET"
  sed -i.bak 's/Follow this exactly\./OLD PROTOCOL TEXT/' "$TARGET/AGENTS.md" && rm -f "$TARGET/AGENTS.md.bak"

  run "$INSTALL_SH" "$TARGET"
  [ "$status" -eq 0 ]
  grep -q "OLD PROTOCOL TEXT" "$TARGET/AGENTS.md"
}

@test "--force replaces an unmarked AGENTS.md the installer created before markers existed" {
  copy_fixture_target empty
  { echo "## Decision & Activity Logging Protocol"; echo ""; echo "OLD PROTOCOL TEXT"; } > "$TARGET/AGENTS.md"

  run "$INSTALL_SH" "$TARGET" --force
  [ "$status" -eq 0 ]
  ! grep -q "OLD PROTOCOL TEXT" "$TARGET/AGENTS.md"
  grep -q "^<!-- asynthlogr:begin" "$TARGET/AGENTS.md"
  grep -qx "<!-- asynthlogr:end -->" "$TARGET/AGENTS.md"
}

@test "appends the AGENTS.md pointer to an existing CLAUDE.md" {
  copy_fixture_target existing-agents

  run "$INSTALL_SH" "$TARGET"
  [ "$status" -eq 0 ]
  grep -q "AGENTS.md" "$TARGET/CLAUDE.md"
}

@test "does not overwrite an existing subagent definition without --force" {
  copy_fixture_target empty
  mkdir -p "$TARGET/.claude/agents"
  echo "MY CUSTOM VERSION" > "$TARGET/.claude/agents/decision-logger.md"

  run "$INSTALL_SH" "$TARGET"
  [ "$status" -eq 0 ]
  grep -q "MY CUSTOM VERSION" "$TARGET/.claude/agents/decision-logger.md"
}

@test "overwrites an existing subagent definition when --force is passed" {
  copy_fixture_target empty
  mkdir -p "$TARGET/.claude/agents"
  echo "MY CUSTOM VERSION" > "$TARGET/.claude/agents/decision-logger.md"

  run "$INSTALL_SH" "$TARGET" --force
  [ "$status" -eq 0 ]
  ! grep -q "MY CUSTOM VERSION" "$TARGET/.claude/agents/decision-logger.md"
}

# ---- basic-memory-via-Docker detection ----
# These enable the `docker` stub (absent by default in every test above,
# which is itself the "Docker not installed" case and already covered).

enable_docker_stub() {
  # Docker mode talks to the container's MCP endpoint over HTTP, so the
  # curl stub (which plays that endpoint) comes along.
  cp "$STUBS_SRC/docker" "$STUBS_SRC/curl" "$BIN_DIR/"
  chmod +x "$BIN_DIR/docker" "$BIN_DIR/curl"
}

@test "falls back to the CLI when every docker call fails" {
  copy_fixture_target empty
  # Shadow whatever real `docker` the test host has with one that always
  # fails, so a real running daemon (or basic-memory container) on the
  # host can't change this test's outcome.
  printf '#!/usr/bin/env bash\nexit 1\n' > "$BIN_DIR/docker"
  chmod +x "$BIN_DIR/docker"

  run "$INSTALL_SH" "$TARGET"
  [ "$status" -eq 0 ]
  [[ "$output" == *"daemon isn't running"* ]]
  [[ "$output" == *"basic-memory found"* ]]
  actual_mode="$(jq -r '.basic_memory_mode' "$TARGET/.claude/asynthlogr.config.json")"
  [ "$actual_mode" = "cli" ]
}

@test "detects Docker mode even without a 'timeout' command (stock macOS)" {
  case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*) skip "builds a symlinked PATH; not practical under Git Bash" ;;
  esac
  copy_fixture_target empty
  enable_docker_stub
  DOCKER_DATA_DIR="$TEST_TMP/docker-knowledge"
  mkdir -p "$DOCKER_DATA_DIR"
  export DOCKER_STUB_DAEMON_RUNNING=1
  export DOCKER_STUB_CONTAINER_ID=abc123
  export DOCKER_STUB_HOST_PORT=32768
  export DOCKER_STUB_HOST_DATA_DIR="$DOCKER_DATA_DIR"

  # A PATH with every system tool except timeout/gtimeout.
  SYS_BIN="$TEST_TMP/sysbin"
  mkdir -p "$SYS_BIN"
  for dir in /usr/local/bin /usr/bin /bin; do
    [ -d "$dir" ] || continue
    for tool in "$dir"/*; do
      name="$(basename "$tool")"
      case "$name" in timeout|gtimeout) continue ;; esac
      [ -e "$SYS_BIN/$name" ] || ln -s "$tool" "$SYS_BIN/$name"
    done
  done

  PATH="$BIN_DIR:$SYS_BIN" run "$INSTALL_SH" "$TARGET"
  [ "$status" -eq 0 ]
  [[ "$output" == *"found running basic-memory container (abc123)"* ]]
  [ "$(jq -r '.basic_memory_mode' "$TARGET/.claude/asynthlogr.config.json")" = "docker" ]
}

@test "falls back to the CLI when Docker is installed but its daemon isn't running" {
  copy_fixture_target empty
  enable_docker_stub
  export DOCKER_STUB_DAEMON_RUNNING=0

  run "$INSTALL_SH" "$TARGET"
  [ "$status" -eq 0 ]
  [[ "$output" == *"daemon isn't running"* ]]
  actual_mode="$(jq -r '.basic_memory_mode' "$TARGET/.claude/asynthlogr.config.json")"
  [ "$actual_mode" = "cli" ]
}

@test "falls back to the CLI when Docker is running but no basic-memory container is up" {
  copy_fixture_target empty
  enable_docker_stub
  export DOCKER_STUB_DAEMON_RUNNING=1
  # DOCKER_STUB_CONTAINER_ID left unset -> `docker ps` reports nothing

  run "$INSTALL_SH" "$TARGET"
  [ "$status" -eq 0 ]
  [[ "$output" == *"no basic-memory container currently running"* ]]
  actual_mode="$(jq -r '.basic_memory_mode' "$TARGET/.claude/asynthlogr.config.json")"
  [ "$actual_mode" = "cli" ]
}

@test "never calls docker run/start/compose: detection is read-only" {
  copy_fixture_target empty
  enable_docker_stub
  export DOCKER_STUB_DAEMON_RUNNING=1

  run "$INSTALL_SH" "$TARGET"
  [ "$status" -eq 0 ]
  # the stub only implements info/ps/port/inspect/exec — any attempt to
  # `docker run`, `docker start`, or `docker compose up` would hit the
  # stub's `unhandled command` branch and fail the whole install.
}

@test "hooks onto an already-running basic-memory Docker container instead of installing the CLI" {
  copy_fixture_target empty
  enable_docker_stub
  # NOTE: the host-side basic-memory stub file is deliberately left in
  # place here — the docker stub's `exec` case forwards into it to
  # simulate "the basic-memory binary running inside the container",
  # which is a different, independent thing from "the local CLI
  # installed on the host". What this test actually proves is that the
  # uv/CLI install path is never triggered when Docker mode is active.
  DOCKER_DATA_DIR="$TEST_TMP/docker-knowledge"
  mkdir -p "$DOCKER_DATA_DIR"
  export DOCKER_STUB_DAEMON_RUNNING=1
  export DOCKER_STUB_CONTAINER_ID=abc123
  export DOCKER_STUB_HOST_PORT=32768
  export DOCKER_STUB_HOST_DATA_DIR="$DOCKER_DATA_DIR"

  run "$INSTALL_SH" "$TARGET"
  [ "$status" -eq 0 ]
  [[ "$output" == *"found running basic-memory container (abc123)"* ]]
  [[ "$output" != *"Installing via uv"* ]]

  # storage root came from the container's /app/data mount, not $HOME
  expected_dir="$DOCKER_DATA_DIR/asynthlogr"
  actual_dir="$(jq -r '.basic_memory_dir' "$TARGET/.claude/asynthlogr.config.json")"
  [ "$actual_dir" = "$expected_dir" ]
  [ -d "$expected_dir" ]

  actual_mode="$(jq -r '.basic_memory_mode' "$TARGET/.claude/asynthlogr.config.json")"
  [ "$actual_mode" = "docker" ]
  actual_endpoint="$(jq -r '.basic_memory_mcp_endpoint' "$TARGET/.claude/asynthlogr.config.json")"
  [ "$actual_endpoint" = "http://localhost:32768/mcp" ]

  # registered with claude using the SSE transport at basic-memory's
  # default --path (/mcp), not stdio
  grep -qx "basic-memory http://localhost:32768/mcp sse" "$CLAUDE_STUB_STATE_DIR/claude-mcp-registered.txt"

  # the asynthlogr project was registered via `docker exec ... basic-memory project add`,
  # using the CONTAINER-side path, not the host path
  grep -q "asynthlogr /app/data/asynthlogr" "$BM_STUB_STATE_DIR/projects.txt"
  # ...over the container's MCP endpoint, not docker exec
  grep -qx "http://localhost:32768/mcp" "$BM_STUB_STATE_DIR/curl-urls.txt"
  [ "$(jq -r '.basic_memory_project_path' "$TARGET/.claude/asynthlogr.config.json")" = "/app/data/asynthlogr" ]
}

@test "Docker mode: a server that already has the project isn't asked to create it again" {
  copy_fixture_target empty
  enable_docker_stub
  DOCKER_DATA_DIR="$TEST_TMP/docker-knowledge"
  mkdir -p "$DOCKER_DATA_DIR" "$BM_STUB_STATE_DIR"
  echo "asynthlogr /app/data/asynthlogr" > "$BM_STUB_STATE_DIR/projects.txt"
  export DOCKER_STUB_DAEMON_RUNNING=1
  export DOCKER_STUB_CONTAINER_ID=abc123
  export DOCKER_STUB_HOST_PORT=32768
  export DOCKER_STUB_HOST_DATA_DIR="$DOCKER_DATA_DIR"

  run "$INSTALL_SH" "$TARGET"
  [ "$status" -eq 0 ]
  [[ "$output" == *"'asynthlogr' project already registered"* ]]
  ! grep -qx create_memory_project "$BM_STUB_STATE_DIR/mcp-calls.txt"
}

@test "Docker mode: fails clearly when the container's MCP endpoint doesn't answer" {
  copy_fixture_target empty
  enable_docker_stub
  DOCKER_DATA_DIR="$TEST_TMP/docker-knowledge"
  mkdir -p "$DOCKER_DATA_DIR"
  export DOCKER_STUB_DAEMON_RUNNING=1
  export DOCKER_STUB_CONTAINER_ID=abc123
  export DOCKER_STUB_HOST_PORT=32768
  export DOCKER_STUB_HOST_DATA_DIR="$DOCKER_DATA_DIR"
  export CURL_STUB_FAIL=1

  run "$INSTALL_SH" "$TARGET"
  [ "$status" -ne 0 ]
  [[ "$output" == *"didn't answer list_memory_projects"* ]]
  [[ "$output" == *"docker logs abc123"* ]]
}

@test "maps a Docker Desktop VM mount path (/run/desktop/mnt/host/...) back to the host path" {
  copy_fixture_target empty
  enable_docker_stub
  DOCKER_DATA_DIR="$TEST_TMP/docker-knowledge"
  mkdir -p "$DOCKER_DATA_DIR"
  export DOCKER_STUB_DAEMON_RUNNING=1
  export DOCKER_STUB_CONTAINER_ID=abc123
  export DOCKER_STUB_HOST_PORT=8011
  # What Docker Desktop on Windows reports for a C:\Users\... bind mount
  # is /run/desktop/mnt/host/c/Users/...; here the "drive" is the first
  # component of the test's real temp path, so the mapping lands on it.
  export DOCKER_STUB_HOST_DATA_DIR="/run/desktop/mnt/host${DOCKER_DATA_DIR}"

  run "$INSTALL_SH" "$TARGET"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.basic_memory_mode' "$TARGET/.claude/asynthlogr.config.json")" = "docker" ]
  [ "$(jq -r '.basic_memory_dir' "$TARGET/.claude/asynthlogr.config.json")" = "$DOCKER_DATA_DIR/asynthlogr" ]
  [ -d "$DOCKER_DATA_DIR/asynthlogr" ]
  [ ! -e "/run/desktop/mnt/host${DOCKER_DATA_DIR}" ]   # never mkdir'd the VM path
}

@test "falls back to the CLI when the container's mount isn't visible from this host" {
  copy_fixture_target empty
  enable_docker_stub
  export DOCKER_STUB_DAEMON_RUNNING=1
  export DOCKER_STUB_CONTAINER_ID=abc123
  export DOCKER_STUB_HOST_PORT=8011
  export DOCKER_STUB_HOST_DATA_DIR="$TEST_TMP/does-not-exist"

  run "$INSTALL_SH" "$TARGET"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Falling back to the local basic-memory CLI"* ]]
  [ "$(jq -r '.basic_memory_mode' "$TARGET/.claude/asynthlogr.config.json")" = "cli" ]
  [ ! -e "$TEST_TMP/does-not-exist" ]
}

@test "registers the transport and path the container actually runs with" {
  copy_fixture_target empty
  enable_docker_stub
  DOCKER_DATA_DIR="$TEST_TMP/docker-knowledge"
  mkdir -p "$DOCKER_DATA_DIR"
  export DOCKER_STUB_DAEMON_RUNNING=1
  export DOCKER_STUB_CONTAINER_ID=abc123
  export DOCKER_STUB_HOST_PORT=8011
  export DOCKER_STUB_HOST_DATA_DIR="$DOCKER_DATA_DIR"
  export DOCKER_STUB_CMD="basic-memory mcp --transport streamable-http --host 0.0.0.0 --port 8000 --path /bm"

  run "$INSTALL_SH" "$TARGET"
  [ "$status" -eq 0 ]
  grep -qx "basic-memory http://localhost:8011/bm http" "$CLAUDE_STUB_STATE_DIR/claude-mcp-registered.txt"
  [ "$(jq -r '.basic_memory_mcp_transport' "$TARGET/.claude/asynthlogr.config.json")" = "http" ]
}

@test "ignores a mismatched --basic-memory-root in Docker mode and uses the container's real mount" {
  copy_fixture_target empty
  enable_docker_stub
  DOCKER_DATA_DIR="$TEST_TMP/docker-knowledge"
  mkdir -p "$DOCKER_DATA_DIR"
  export DOCKER_STUB_DAEMON_RUNNING=1
  export DOCKER_STUB_CONTAINER_ID=abc123
  export DOCKER_STUB_HOST_PORT=32768
  export DOCKER_STUB_HOST_DATA_DIR="$DOCKER_DATA_DIR"

  run "$INSTALL_SH" "$TARGET" --basic-memory-root "$TEST_TMP/some-other-dir"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Using the container's actual mount instead"* ]]
  expected_dir="$DOCKER_DATA_DIR/asynthlogr"
  actual_dir="$(jq -r '.basic_memory_dir' "$TARGET/.claude/asynthlogr.config.json")"
  [ "$actual_dir" = "$expected_dir" ]
}
