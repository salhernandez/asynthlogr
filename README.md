# asynthlogr

![Tests](../../actions/workflows/test.yml/badge.svg)

Async logging of synthetic thought — the reasoning behind AI-agent
decisions, captured without slowing anything down.

## What it does
- Logs decisions (ADR-style: context, options considered, options
  discarded and why, final decision, rationale, decision-maker) and
  freeform info notes, per chat thread.
- Logs every subagent call's raw prompt/tools/output separately from
  the distilled decision log.
- Non-blocking: nothing you or your agents do waits on a log write.
- Organized per repo, per chat thread, in a basic-memory vault.
- Links straight back to the code: Cursor, VS Code, and GitHub links
  per file reference, resolved automatically via git/gh.
- Tracks which step of your research → clarify → propose → discuss →
  plan flow you're on, per thread.
- Warns you (without ever blocking) while subagent runs are still in
  flight, and if you exit anyway, records them as abandoned in
  `failed-writes.log` instead of losing them silently.
- Talks to you like a human (ADHD-optimized formatting, see
  `skills/i-have-adhd/`) for anything addressed to you; strict machine
  templates for everything agent-to-agent.
- Writes vault notes as correct, properly-wikilinked Obsidian markdown
  (see `skills/obsidian-notation-expert/`, `skills/obsidian-node-link-expert/`)
  — the vault is meant to be browsed in Obsidian, Graph View included,
  not just read as flat text files.

## Requirements
- Claude Code with subagent + hooks support
- **basic-memory — REQUIRED.** Every piece of information this tool
  logs is written through basic-memory; there is no fallback storage
  mode. `install.sh` detects it one of two ways, preferring an
  already-running Docker deployment:
  - **Docker mode:** if the official
    [`ghcr.io/basicmachines-co/basic-memory`](https://github.com/basicmachines-co/basic-memory/blob/main/docker-compose.yml)
    image is already up, `install.sh` hooks onto it — registering its
    SSE MCP endpoint with Claude Code and running `basic-memory
    project ...` commands via `docker exec`. It never starts Docker
    and never starts a container itself.
  - **CLI mode:** otherwise, it installs the `basic-memory` CLI (via
    `uv`) and registers its MCP server with Claude Code automatically,
    same as before — see
    [basicmachines-co/basic-memory](https://github.com/basicmachines-co/basic-memory).
- `uv` (needed to install basic-memory if it isn't already present and
  no Docker deployment is found)
- git + gh CLI (for resolving commit/PR links)
- `jq` — used by the pending-run hooks at runtime, and by `install.sh`
  to merge into an existing `.claude/settings.json`
- Obsidian is an optional viewer on the same directory basic-memory
  manages — not itself a requirement.

## Install
```
./install.sh /path/to/your/repo
# hooks onto an already-running basic-memory Docker container if one
# exists; otherwise installs the CLI if missing and registers its MCP
# server if needed. Defaults to basic-memory's own storage root
# (~/basic-memory), or the running container's actual mount in Docker
# mode, if you don't pass one:
./install.sh /path/to/your/repo --basic-memory-root /path/to/basic-memory
```
See `docs/architecture.md`'s "basic-memory: CLI mode vs. Docker mode"
section for exactly how detection works and what it does in each mode.

asynthlogr does not get an arbitrary directory of its own — it lives
at `<basic-memory-root>/asynthlogr` and is registered as its own
basic-memory **project** named `asynthlogr`, alongside whatever other
projects you already have in basic-memory.

See `docs/architecture.md` for exactly what the installer does and
which files it creates vs. appends to.

## Usage
Nothing to invoke manually most of the time — logging happens as you
work through your normal research → clarify → propose → discuss →
plan flow. To log something that isn't a decision: just say "log
this: ...".

Vault layout produced — see `docs/vault-layout.md` for full detail:
```
<vault>/<repo>/<thread>/<thread>.md
<vault>/<repo>/<thread>/agent-use-tracking.md
<vault>/<repo>/<thread>/subagents/<run>/output.md
<vault>/<repo>/<thread>/subagents/<run>/agent-use-tracking.md
```

## Testing
```
bats tests/unit/          # layer 1
tests/docker/run.sh       # layer 2 (debian:bookworm-slim)
```
See `tests/README.md` for what each layer covers and what it doesn't.

## Documentation
- `docs/architecture.md` — problem statement, the 5-step flow this
  observes, core architectural principles, the race-condition fix, the
  pending-run hooks, the human/machine communication boundary
- `docs/vault-layout.md` — full vault directory structure
- `docs/decision-entry-format.md` — the decision/info entry templates
- `docs/subagent-run-format.md` — the delegation template, output.md,
  and both tracking-file formats
- `docs/known-limitations.md` — what this system cannot guarantee
- `docs/open-items.md` — unresolved implementation details a coding
  agent should verify before/while building this

## Known limitations
- Model name / context-window % are self-reported by the orchestrator,
  not measured — Claude Code has no API for this. Always labeled
  unverified in the log.
- A hard-killed session (not a clean exit) fires no hooks, so a
  subagent run still in flight leaves no trace in `failed-writes.log`.
- Thread naming happens once per session; it isn't retroactively
  editable by decision-logger.

See `docs/known-limitations.md` for the full list with explanations.

## Files this installer touches
- Creates or appends to: `AGENTS.md`, `CLAUDE.md`, `.claude/settings.json`
- Creates: `.claude/agents/*.md`, `.claude/hooks/*`, `.claude/skills/*/`,
  `.claude/asynthlogr/formats/*`, `.claude/asynthlogr.config.json`
- Created later by the orchestrator, not the installer:
  `.claude/active-thread.json` (at the start of each session)
- Registers basic-memory as a Claude Code MCP server (local scope, for
  the target repo)

## License
MIT (includes vendored `i-have-adhd` skill, MIT,
https://github.com/ayghri/i-have-adhd)
