#!/usr/bin/env bats
#
# Unit tests for bin/asynthlogr-report.sh against an inline fixture vault
# and the stubbed basic-memory/docker CLIs. The stub writes each report
# into the vault itself (BM_STUB_WRITE_ROOT), as real basic-memory would.

REPO_ROOT="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../.." && pwd)"
REPORT="$REPO_ROOT/bin/asynthlogr-report.sh"
STUBS_SRC="$REPO_ROOT/tests/stubs/bin"

setup() {
  TEST_TMP="$(mktemp -d)"
  BIN_DIR="$TEST_TMP/bin"
  mkdir -p "$BIN_DIR"
  cp "$STUBS_SRC/basic-memory" "$STUBS_SRC/curl" "$STUBS_SRC/mcp-stub-respond" "$BIN_DIR/"
  chmod +x "$BIN_DIR"/*
  export PATH="$BIN_DIR:$PATH"
  export BM_STUB_STATE_DIR="$TEST_TMP/bm-state"

  VAULT="$TEST_TMP/vault"
  export BM_STUB_WRITE_ROOT="$VAULT"
  CONFIG="$TEST_TMP/asynthlogr.config.json"
  write_config cli
  make_vault
}

teardown() {
  rm -rf "$TEST_TMP"
}

write_config() {
  if [ "$1" = "docker" ]; then
    printf '{"basic_memory_dir": "%s", "basic_memory_project": "asynthlogr", "basic_memory_mode": "docker", "basic_memory_docker_container": "abc123", "basic_memory_mcp_endpoint": "http://localhost:8011/mcp", "basic_memory_mcp_transport": "sse"}\n' "$VAULT" > "$CONFIG"
  else
    printf '{"basic_memory_dir": "%s", "basic_memory_project": "asynthlogr", "basic_memory_mode": "cli"}\n' "$VAULT" > "$CONFIG"
  fi
}

make_vault() {
  local t1="$VAULT/repo-1/auth-token-refresh" t2="$VAULT/repo-2/ci-flake"
  mkdir -p "$t1/subagents" "$t2"

  cat > "$t1/auth-token-refresh.md" <<'EOF'
---
title: auth-token-refresh
type: note
---
# auth-token-refresh

## 2026-09-24T11:21:00-07:00 — Use a sliding refresh window

**Type:** Decision
**Trigger:** solution-proposed

### Context
Tokens expire mid-session.

### Open questions
- Should refresh also rotate the device key?

### Related subagent runs
- [[repo-1/auth-token-refresh/subagents/2026-09-24T10-00-00_research-agent-a/output|research-agent — 10:00:00]]

---

## 2026-09-24T12:05:00-07:00 — Rate limits documented in config/limits.yml

**Type:** Info
**Trigger:** manual

### Content
Limits live in config/limits.yml.

---

## 2026-09-25T09:00:00-07:00 — Retry refresh once, then force re-login

**Type:** Decision

> [!question]- Open Questions
> - Does the mobile client share this path?

---
EOF

  cat > "$t1/agent-use-tracking.md" <<'EOF'
---
repo: repo-1
thread: auth-token-refresh
session_id: 00893aaf-19fa-41d2-8238-13269b9b3ca0
current_step: 5
current_step_name: plan
---

# Step log
- 2026-09-24T09:58:02-07:00 — step 1 (research) started
- 2026-09-24T10:00:00-07:00 — step 1 — subagent run: 2026-09-24T10-00-00_research-agent-a
- 2026-09-24T11:00:00-07:00 — step 3 (propose) started
- 2026-09-25T08:55:00-07:00 — step 5 (plan) started
EOF

  make_run "$t1" 2026-09-24T10-00-00_research-agent-a research-agent completed logged
  make_run "$t1" 2026-09-24T10-30-00_research-agent-b research-agent completed logged
  make_run "$t1" 2026-09-24T11-00-00_planning-agent-c planning-agent running placeholder

  cat > "$t2/ci-flake.md" <<'EOF'
# ci-flake

## 2026-09-24T16:00:00-07:00 — Flaky test is timing-dependent

**Type:** Info

### Content
Only fails under load.

---
EOF

  cat > "$VAULT/failed-writes.log" <<'EOF'
2026-09-24T23:10:00-07:00 | repo-1/auth-token-refresh | subagent-run | abandoned: 2026-09-24T11-00-00_planning-agent-c still running at session end (reason: other)
2026-09-25T08:00:00-07:00 | repo-3/gone-thread | decision | write failed: timeout
EOF
}

# $1 thread dir, $2 run folder, $3 subagent_name, $4 status,
# $5 output.md: logged (decision-logger wrote it), placeholder (the
# orchestrator's, still tagged pending), or none
make_run() {
  mkdir -p "$1/subagents/$2"
  printf -- '---\ntitle: agent-use-tracking\nsubagent_name: %s\nstatus: %s\n---\n\n# Run log\n' "$3" "$4" > "$1/subagents/$2/agent-use-tracking.md"
  case "$5" in
    logged) printf -- '---\ntitle: output\ntags:\n- subagent-run\n---\n\n# Subagent run - %s\n\nMentions subagent-run-pending in the body only.\n' "$3" > "$1/subagents/$2/output.md" ;;
    placeholder) printf -- '---\ntitle: output\ntags:\n- subagent-run\n- subagent-run-pending\n---\n\n# Subagent run - %s\n**Status:** not logged yet.\n' "$3" > "$1/subagents/$2/output.md" ;;
  esac
}

report_file() { echo "$VAULT/reports/$1.md"; }

@test "writes one note for the day through basic-memory, with a summary row per repo" {
  run "$REPORT" --config "$CONFIG" --date 2026-09-24
  [ "$status" -eq 0 ]
  [[ "$output" == *"wrote reports/2026-09-24.md (2 repo(s), 2 thread(s))"* ]]
  grep -qx 'title=2026-09-24 folder=reports project=asynthlogr overwrite=true' "$BM_STUB_STATE_DIR/write-note-calls.txt"

  f="$(report_file 2026-09-24)"
  grep -qx 'type: report' "$f"
  grep -qx 'complete: true' "$f"
  grep -qx 'repos: \[repo-1, repo-2\]' "$f"
  grep -qx '| \[\[#repo-1\]\] | 1 | 1 | 1 | 3 | 1 |' "$f"
  grep -qx '| \[\[#repo-2\]\] | 1 | 0 | 1 | 0 | 0 |' "$f"
  grep -qx '> \[!warning\] 1 log write(s) failed or were abandoned' "$f"
}

@test "renders each active thread with its step, entries, runs, open questions and failures" {
  "$REPORT" --config "$CONFIG" --date 2026-09-24
  f="$(report_file 2026-09-24)"

  grep -qx '## repo-1' "$f"
  grep -qx '### \[\[repo-1/auth-token-refresh/auth-token-refresh|auth-token-refresh\]\] · step 3 (propose)' "$f"
  grep -qx -- '- 11:21 — Use a sliding refresh window' "$f"
  grep -qx -- '- 12:05 — Rate limits documented in config/limits.yml' "$f"
  grep -qx -- '\*\*Subagent runs:\*\* 3 (planning-agent ×1, research-agent ×2) · 1 not finished' "$f"
  grep -qx '> \[!question\]- Open questions raised (1)' "$f"
  grep -qx -- '> - Should refresh also rotate the device key?' "$f"
  grep -qx -- '- 23:10 — subagent-run — abandoned: 2026-09-24T11-00-00_planning-agent-c still running at session end (reason: other)' "$f"
  grep -qx '### \[\[repo-2/ci-flake/ci-flake|ci-flake\]\]' "$f"
}

@test "counts a finished run whose output was never logged as not finished" {
  t1="$VAULT/repo-1/auth-token-refresh"
  make_run "$t1" 2026-09-24T12-00-00_research-agent-d research-agent completed placeholder
  make_run "$t1" 2026-09-24T12-30-00_research-agent-e research-agent completed none
  "$REPORT" --config "$CONFIG" --date 2026-09-24
  f="$(report_file 2026-09-24)"
  grep -qx -- '\*\*Subagent runs:\*\* 5 (planning-agent ×1, research-agent ×4) · 3 not finished' "$f"
}

@test "shows each thread's session ID with its resume command, when recorded" {
  "$REPORT" --config "$CONFIG" --date 2026-09-24
  f="$(report_file 2026-09-24)"
  grep -qxF '**Session:** `00893aaf-19fa-41d2-8238-13269b9b3ca0` · resume with `claude --resume 00893aaf-19fa-41d2-8238-13269b9b3ca0`' "$f"
  # repo-2's thread has no tracking note, so no session line
  [ "$(grep -c '^\*\*Session:\*\*' "$f")" -eq 1 ]
}

@test "only includes the requested day's entries" {
  "$REPORT" --config "$CONFIG" --date 2026-09-24
  ! grep -q 'Retry refresh once' "$(report_file 2026-09-24)"
}

@test "reads callout-form open questions, the step as of that day, and failure-only threads" {
  run "$REPORT" --config "$CONFIG" --date 2026-09-25
  [ "$status" -eq 0 ]
  f="$(report_file 2026-09-25)"
  grep -qx '### \[\[repo-1/auth-token-refresh/auth-token-refresh|auth-token-refresh\]\] · step 5 (plan)' "$f"
  grep -qx -- '> - Does the mobile client share this path?' "$f"
  # repo-3/gone-thread exists only in failed-writes.log
  grep -qx '## repo-3' "$f"
  grep -qx -- '- 08:00 — decision — write failed: timeout' "$f"
  ! grep -q 'ci-flake' "$f"
}

@test "writes no note for a day without activity" {
  run "$REPORT" --config "$CONFIG" --date 2026-09-20
  [ "$status" -eq 0 ]
  [[ "$output" == *"2026-09-20: no activity — no report written."* ]]
  [ ! -e "$(report_file 2026-09-20)" ]
  [ ! -e "$BM_STUB_STATE_DIR/write-note-calls.txt" ]
}

@test "--today marks the report incomplete" {
  today="$(date +%Y-%m-%d)"
  printf '\n## %sT10:00:00-07:00 — Something today\n\n**Type:** Info\n\n---\n' "$today" >> "$VAULT/repo-2/ci-flake/ci-flake.md"

  run "$REPORT" --config "$CONFIG" --today
  [ "$status" -eq 0 ]
  f="$(report_file "$today")"
  grep -qx 'complete: false' "$f"
  grep -qx '> \[!info\] Day still in progress' "$f"
}

@test "defaults to --today" {
  today="$(date +%Y-%m-%d)"
  run "$REPORT" --config "$CONFIG"
  [ "$status" -eq 0 ]
  [[ "$output" == *"$today: no activity"* ]]
}

@test "regenerating a day yields the same body apart from generated_at" {
  "$REPORT" --config "$CONFIG" --date 2026-09-24
  grep -v '^generated_at:' "$(report_file 2026-09-24)" > "$TEST_TMP/first"
  "$REPORT" --config "$CONFIG" --date 2026-09-24
  grep -v '^generated_at:' "$(report_file 2026-09-24)" > "$TEST_TMP/second"
  diff "$TEST_TMP/first" "$TEST_TMP/second"
}

@test "--catch-up writes every finished day with activity and no report, then nothing" {
  run "$REPORT" --config "$CONFIG" --catch-up
  [ "$status" -eq 0 ]
  [ -f "$(report_file 2026-09-24)" ]
  [ -f "$(report_file 2026-09-25)" ]
  [ ! -e "$(report_file "$(date +%Y-%m-%d)")" ]

  run "$REPORT" --config "$CONFIG" --catch-up
  [ "$status" -eq 0 ]
  [[ "$output" == *"Nothing to catch up on"* ]]
}

@test "--catch-up --since skips earlier days" {
  run "$REPORT" --config "$CONFIG" --catch-up --since 2026-09-25
  [ "$status" -eq 0 ]
  [ ! -e "$(report_file 2026-09-24)" ]
  [ -f "$(report_file 2026-09-25)" ]
}

@test "falls back to writing without --overwrite on basic-memory 0.18.x" {
  export BM_STUB_OLD_VERSION=1
  run "$REPORT" --config "$CONFIG" --date 2026-09-24
  [ "$status" -eq 0 ]
  grep -qx 'title=2026-09-24 folder=reports project=asynthlogr overwrite=false' "$BM_STUB_STATE_DIR/write-note-calls.txt"
  [ -f "$(report_file 2026-09-24)" ]
}

@test "writes the report with the write_note MCP tool, never the basic-memory CLI" {
  run "$REPORT" --config "$CONFIG" --date 2026-09-24
  [ "$status" -eq 0 ]
  grep -qx 'write_note' "$BM_STUB_STATE_DIR/mcp-calls.txt"
}

@test "in Docker mode, writes over the container's MCP endpoint from the config" {
  write_config docker
  run "$REPORT" --config "$CONFIG" --date 2026-09-24
  [ "$status" -eq 0 ]
  grep -qx 'http://localhost:8011/mcp' "$BM_STUB_STATE_DIR/curl-urls.txt"
  [ -f "$(report_file 2026-09-24)" ]
}

@test "a failed write exits non-zero and lands in failed-writes.log" {
  export BM_STUB_FAIL_WRITE=1
  run "$REPORT" --config "$CONFIG" --date 2026-09-24
  [ "$status" -ne 0 ]
  [[ "$output" == *"writing reports/2026-09-24.md failed"* ]]
  grep -q '| reports/2026-09-24 | report | stub basic-memory: simulated write failure' "$VAULT/failed-writes.log"
}

@test "fails clearly without a config" {
  run "$REPORT" --config "$TEST_TMP/nope.json" --date 2026-09-24
  [ "$status" -eq 1 ]
  [[ "$output" == *"no asynthlogr config"* ]]
}
