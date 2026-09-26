#!/usr/bin/env bats
#
# Static checks on the shipped agent and skill definitions — the
# mistakes here don't fail loudly at runtime, they just leave an agent
# silently unable to do its job.

REPO_ROOT="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../.." && pwd)"

# Prints the YAML frontmatter of $1 (between the first two --- lines).
frontmatter() {
  awk 'NR==1 && $0=="---" {inside=1; next} inside && $0=="---" {exit} inside {print}' "$1"
}

@test "every agent that lists an MCP server also grants that server's tools" {
  # A `tools:` allowlist removes every MCP tool not named in it, even
  # when the server is listed under `mcpServers:`.
  for agent in "$REPO_ROOT"/agents/*.md; do
    fm="$(frontmatter "$agent")"
    tools="$(echo "$fm" | sed -n 's/^tools: *//p')"
    [ -n "$tools" ] || continue
    for server in $(echo "$fm" | awk '/^mcpServers:/ {on=1; next} on && /^  - / {print $2; next} on {exit}'); do
      if [[ ",$tools," != *"mcp__${server}"* ]]; then
        echo "$(basename "$agent"): lists mcpServers '$server' but tools lacks mcp__$server" >&2
        return 1
      fi
    done
  done
}

@test "every preloaded skill exists and has name/description frontmatter" {
  for agent in "$REPO_ROOT"/agents/*.md; do
    for skill in $(frontmatter "$agent" | awk '/^skills:/ {on=1; next} on && /^  - / {print $2; next} on {exit}'); do
      file="$REPO_ROOT/skills/$skill/SKILL.md"
      [ -f "$file" ] || { echo "$(basename "$agent"): missing skill $skill" >&2; return 1; }
    done
  done
  for file in "$REPO_ROOT"/skills/*/SKILL.md; do
    fm="$(frontmatter "$file")"
    echo "$fm" | grep -q '^name: ' || { echo "$file: no name" >&2; return 1; }
    echo "$fm" | grep -q '^description: ' || { echo "$file: no description" >&2; return 1; }
  done
}

@test "agents point at format docs that install.sh actually installs" {
  for ref in $(grep -oh '\.claude/asynthlogr/formats/[a-z-]*\.md' "$REPO_ROOT"/agents/*.md "$REPO_ROOT"/templates/AGENTS.md.snippet | sort -u); do
    [ -f "$REPO_ROOT/docs/$(basename "$ref")" ] || { echo "no docs/ source for $ref" >&2; return 1; }
    grep -q "$(basename "$ref" .md)" "$REPO_ROOT/install.sh" || { echo "install.sh doesn't copy $ref" >&2; return 1; }
  done
}
