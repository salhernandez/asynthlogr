# Open items for the coding agent to resolve during implementation

1. **Real `basic-memory` MCP tool names/signatures** — every
   instruction in this repo currently says "via the basic-memory MCP
   tools" generically, and this applies to *every* subagent
   (decision-logger, research-agent, planning-agent, and any added
   later), not just decision-logger. Check the actual connected MCP
   server's tool list (append vs. write, how it addresses
   notes/folders/frontmatter) and rewrite every such reference to call
   real tool names. This is the single most load-bearing unresolved
   detail in this repo, since basic-memory is a hard dependency for
   nearly every write in the system.

2. **Stop hook block/allow contract** — `hooks/check-pending-subagents.sh`
   currently assumes `exit 2` + stderr message blocks a `Stop` hook and
   shows the message, mirroring the general Claude Code hook
   convention. Confirm this is also how a `Stop` hook specifically
   signals "block the stop and show this message" against current
   Claude Code hooks documentation before relying on this script — if
   `Stop` uses a different (e.g. JSON decision) contract, rewrite the
   block path.

3. **`background: true` frontmatter field and `mcpServers:`
   inline/reference syntax** — confirm current exact syntax against
   live Claude Code subagent docs; the agent definitions in
   `agents/*.md` assume the frontmatter shapes used there, which
   should be spot-checked against whatever Claude Code version is
   actually in use.

4. **Reporting system (`reports/`)** — not designed yet. Needs: how it
   walks the vault (per-repo vs. cross-repo rollup, both were
   requested), what triggers a run (manual command vs. scheduled), and
   its own file/output format. Treat as a separate follow-up design
   pass, not part of this initial build.

5. **Vault-directory existence check** — `install.sh` prompts to
   create the basic-memory directory if missing; confirm this is the
   right behavior vs. requiring it pre-exist (basic-memory itself may
   need to "adopt"/initialize a directory before treating it as a
   valid project).

6. **`install.sh`'s basic-memory install/init/project commands are
   unverified against the live tool.** Specifically:
   - `claude mcp list` / `claude mcp add basic-memory -- uvx basic-memory mcp`
     — confirm these are the right Claude Code commands/flags for the
     version in use.
   - `uv tool install basic-memory` — confirmed from the
     [basic-memory README](https://github.com/basicmachines-co/basic-memory)
     at design time; re-check nothing has changed.
   - `basic-memory project list` as an "is it initialized" probe, and
     `basic-memory project add asynthlogr <path>` to register the
     project — confirmed commands exist, but the exact output format
     of `project list` (used by `install.sh` to check whether
     `asynthlogr` is already registered, via a `grep -qi asynthlogr`)
     was not confirmed — verify the real output and make that check
     exact rather than a substring grep, which could false-match.
   - Whether `basic-memory project list` genuinely triggers first-use
     initialization (creating `~/.basic-memory/config.json` and the
     default project) as the README implies, or whether some other
     command is actually needed.

7. **Whether `failed-writes.log` living inside `basic_memory_dir` but
   written as a plain (non-indexed) file causes any friction with
   basic-memory itself** — confirm basic-memory tolerates a stray
   non-managed file in its directory tree, or relocate this log
   outside `basic_memory_dir` entirely if not.

8. **`tests/docker/run.sh` was not actually executed** in the
   environment this repo was built in (no Docker daemon access there)
   — the `bats` unit tests (layer 1) WERE run for real and pass; the
   Dockerfile was syntax-checked and its `bats` package presence in
   Debian bookworm was confirmed against Debian's package pages, but
   run it yourself once to fully confirm layer 2 before trusting it in
   CI.

9. **`install.sh`'s basic-memory-via-Docker detection (added later) is
   verified against the *documented* deployment, not a live container.**
   The image name, port, SSE-only transport, and `/app/data` mount
   point were all confirmed directly from
   [basic-memory's `Dockerfile`](https://github.com/basicmachines-co/basic-memory/blob/main/Dockerfile)
   and
   [`docker-compose.yml`](https://github.com/basicmachines-co/basic-memory/blob/main/docker-compose.yml)
   at design time (not guessed), and the detection logic (`docker ps`
   by ancestor/name, `docker port`, `docker inspect` for the mount,
   `docker exec` for `basic-memory project ...`) is covered by real,
   passing bats tests against a stubbed `docker` CLI
   (`tests/unit/install_test.bats`, "basic-memory-via-Docker
   detection" section). What's still unverified: this was never run
   against an actual `docker run`/`docker compose up` basic-memory
   container in this environment (no Docker daemon access here either
   — same limitation as item 8). Before relying on Docker mode for
   real, bring up the official image yourself once
   (`docker compose up` from basic-memory's own repo, or equivalent)
   and confirm `install.sh` hooks onto it as described in
   `docs/architecture.md`'s "basic-memory: CLI mode vs. Docker mode"
   section. Also worth confirming: whether a custom deployment (a
   locally-built image, a different compose file, a non-default mount
   path) is common enough in practice to warrant recognizing more than
   the one documented layout this installer currently understands.
