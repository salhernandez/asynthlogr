# Open items

Status of every item raised during design. Resolved items stay listed
with how they were resolved, since the reasoning is still useful when
something changes upstream.

## Still open

1. **Reports: optional extras** — a written narrative summary,
   weekly/monthly rollups, and deep links to individual entries (see
   "Later" in `docs/reports-design.md`). The daily report itself is
   done.

2. **Live run inside a real Claude Code session.** Checked live against
   the official basic-memory image (0.18.4): `write_note(title,
   folder)` saves `<folder>/<title>.md` with `metadata`-style fields as
   plain top-level frontmatter (`status: dispatched`, unquoted), so the
   hooks read it as designed; full-path wikilinks resolve in *both*
   directions (run → thread and thread → run, including run folders
   with uppercase `T` and `_`, which basic-memory maps to the lowercased
   permalink); `project add` works and a duplicate add exits 0 with
   "already exists". Still unobserved: a real Claude Code session
   driving the whole flow — whether a haiku-model `decision-logger`
   follows the templates reliably, and how Obsidian renders the vault
   (open the `asynthlogr` project directory as the vault).

3. **basic-memory's Docker image serves MCP over SSE only**, and
   Claude Code now marks the SSE transport as deprecated. It still
   works; if basic-memory's image moves to HTTP-streamable, switch
   `install.sh`'s Docker-mode registration to `--transport http` and
   the `/sse` endpoint accordingly.

4. **Docker-mode detection only recognizes the official image's
   documented layout** (see `docs/known-limitations.md` #6) — confirm
   whether custom deployments are common enough to recognize more.

## Resolved

- **Reporting system (`reports/`)** — designed and implemented:
  `docs/reports-design.md`, `bin/asynthlogr-report.sh`, run manually
  with `/asynthlogr-report`. One note per day with a section per repo.

- **Real basic-memory MCP tool names** — checked against basic-memory's
  source (`src/basic_memory/mcp/tools/`, v0.23.x): notes are created
  with `write_note(title, content, directory, project, tags, metadata,
  overwrite)`, saved as `<directory>/<title>.md`; appended to and
  frontmatter-merged with `edit_note(identifier, operation: "append",
  content, metadata, project)`, where `identifier` is the permalink
  `write_note` returns. Every call passes `project: "asynthlogr"`,
  since omitting it writes to the session's last-used project. All
  agent definitions and `templates/AGENTS.md.snippet` now use these.

- **Stop hook block/allow contract** — checked against the Claude Code
  hooks docs: `Stop` fires at the end of *every* Claude response, and
  blocking it (exit 2 or `decision: "block"`) sends the message to
  Claude and forces it to continue, never showing it to the human.
  Redesigned: `Stop` shows a non-blocking `systemMessage` warning, and
  a `SessionEnd` registration of the same script records still-pending
  runs in `failed-writes.log`. See `docs/architecture.md`,
  "Pending-run hooks".

- **Subagent frontmatter (`background`, `mcpServers`, tools)** —
  checked against the Claude Code subagent docs. `background: true`
  and `mcpServers:` (a list of already-configured server names) are
  correct. But a `tools:` allowlist removes every MCP tool not named
  in it, so each agent now also lists `mcp__basic-memory` in `tools`.
  The Obsidian skills are preloaded with the `skills:` field rather
  than loaded through a Skill tool the agents weren't granted.
  `tests/unit/definitions_test.bats` guards both.

- **Vault-directory existence** — `install.sh` never prompts; it runs
  `mkdir -p <basic-memory-root>/asynthlogr` and then `basic-memory
  project add asynthlogr <path>`, which registers an existing
  directory.

- **`install.sh`'s CLI-mode commands** — `claude mcp add basic-memory
  -- uvx basic-memory mcp` and `claude mcp add --transport sse <name>
  <url>` match the Claude Code MCP docs. `claude mcp add`'s default
  local scope is stored per project path, so the installer now runs it
  from inside the target repo. `basic-memory project list --json`
  prints `{"projects": [{"name": ...}]}`, and the installer matches
  the `asynthlogr` name exactly.

- **`failed-writes.log` inside the project directory** — basic-memory
  indexes non-hidden files unless a project `.gitignore` excludes
  them, so `install.sh` adds `failed-writes.log` to
  `<basic-memory-root>/asynthlogr/.gitignore`.

- **Docker-mode detection against a live container** — run read-only
  against a real `ghcr.io/basicmachines-co/basic-memory` container on
  Docker Desktop for Windows. Found and fixed two bugs the stubs
  couldn't show: Docker Desktop reports bind-mount sources as VM paths
  (`/run/desktop/mnt/host/c/...`), now mapped back to `/c/...` (Git
  Bash) or `/mnt/c/...` (WSL), with a CLI-mode fallback when the mount
  isn't visible from the host; and basic-memory 0.18.x has no
  `project list --json`, so the installer falls back to matching the
  name cell of its table.

- **Layer-2 Docker tests never executed** — now run: the
  `debian:bookworm-slim` image builds and the full bats suite passes
  inside it.
