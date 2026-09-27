# Architecture

## Problem statement

When working with AI coding agents in a multiagent flow (research →
clarify → propose → discuss → plan), the *decisions* made along the
way — what was chosen, what was discarded and why, who decided, what
was asked and answered — are normally lost. Code comments capture
"what," never "why." asynthlogr captures the why, automatically,
without adding latency or blocking to the workflow it's observing.

## The 5-step flow this system observes

```
1. research  — ask a subagent to research a specific area of the code
2. clarify   — ask specific questions about how it works
3. propose   — ask for a suggested solution to X, using what was learned
4. discuss   — ask questions about the proposed solution(s)
5. plan      — ask for an implementation plan
```

Steps 3 and 5 are decision-logging checkpoints. Steps 1, 2, 3, 5 (any
subagent call) are subagent-run logging checkpoints. Step 4 is
conversational and not itself instrumented (its Q&A gets folded into
whichever decision entry follows).

## Core architectural principles (non-negotiable)

1. **Non-blocking / fire-and-forget.** No logging operation ever makes
   the orchestrator or the human wait. UDP semantics: send it, don't
   wait for an ack, don't consume the result, no retries.
2. **One thread = one chat session.** A "thread" in the vault
   corresponds 1:1 to one Claude Code session. Thread naming happens
   exactly once, synchronously, at session start — never invented
   inside a background dispatch (avoids a race condition — see
   "Race condition and its fix" below).
3. **Separation of distilled vs. raw.** The main thread file
   (`thread.md`) holds distilled ADR-style decision/info entries. A
   `subagents/` subfolder holds the raw, undistilled prompt/tools/
   output for every subagent call.
4. **Machine-to-machine communication stays structured; human-facing
   communication is ADHD-optimized.** See "Human vs. machine
   communication" below.
5. **Silent failure is not acceptable, but blocking is also not
   acceptable.** Failures land in a dead-letter log
   (`failed-writes.log`), never in a retry loop, never in a blocking
   prompt. A run whose output was never logged keeps a placeholder
   note pointing at the subagent (see "Placeholder output notes"
   below).
6. **basic-memory is a hard, required dependency — not one option
   among several.** Every piece of information this system logs —
   decision/info entries, subagent-run output, both levels of
   `agent-use-tracking.md` — is written through the basic-memory MCP
   server, by whichever agent owns that file. So is everything
   asynthlogr's own scripts do: `install.sh` creates and checks the
   `asynthlogr` project, and the report script writes its notes, with
   MCP tools (`bin/mcp-client.sh`, a curl-only MCP client), never the
   basic-memory CLI. Besides keeping one writer, this matters in Docker
   mode: a long-running server keeps the config it loaded at startup
   and, on its next project sync, deletes any project it doesn't know
   ("deleted from config, source of truth"), including one a separate
   CLI process just added. `install.sh` ensures
   basic-memory is reachable one of two ways (see "basic-memory: CLI
   mode vs. Docker mode" below) and registers its Claude Code MCP
   server if needed — it does not just check and fail. The only files
   in this whole system that are plain filesystem files, not
   basic-memory-managed notes, are repo-local operational files that
   live outside the vault: `.claude/asynthlogr.config.json` and
   `failed-writes.log` (an ops
   dead-letter log, not a knowledge artifact — `install.sh` lists it
   in the project's `.gitignore`, which basic-memory honors, so it
   stays out of basic-memory's index).
7. **asynthlogr is itself a basic-memory project, not an arbitrary
   folder.** It does not get to pick an unrelated directory — its
   storage lives at `<basic-memory-root>/asynthlogr`
   (`~/basic-memory/asynthlogr` by default) and is registered with the
   `create_memory_project` MCP tool, exactly like any other project a
   basic-memory user might create. The orchestrator re-checks it with
   `list_memory_projects` at every session start and recreates it if a
   server has lost it. This means the vault this
   system writes to shows up naturally alongside the user's other
   basic-memory projects, not as a separate, disconnected store.

## basic-memory: CLI mode vs. Docker mode

basic-memory can be reached two ways, and `install.sh` detects both,
in this order:

1. **Docker mode** — an already-running container of the official
   `ghcr.io/basicmachines-co/basic-memory` image (see its
   [`docker-compose.yml`](https://github.com/basicmachines-co/basic-memory/blob/main/docker-compose.yml)).
   That image serves basic-memory's MCP server over **SSE on port
   8000** by default (`basic-memory mcp --transport sse --host 0.0.0.0
   --port 8000`), at basic-memory's `--path`, which defaults to `/mcp`
   (not `/sse`), and bind-mounts the knowledge directory at
   `/app/data` inside the container.
2. **CLI mode** — the `basic-memory` binary installed locally (via
   `uv`), talking to Claude Code over stdio. This is the original,
   still-default path when no Docker deployment is found.

**Detection is strictly read-only.** `install.sh` never runs `docker
run`, `docker start`, `docker compose up`, or anything else that would
start Docker itself or start a basic-memory container itself. If
Docker isn't installed, isn't running, or has no basic-memory
container currently up, it silently falls back to CLI mode — same
behavior as before this feature existed. Concretely, it checks:

```
1. `docker` on PATH at all?
2. `docker info` succeeds within 5 seconds (daemon reachable)? Uses
   `timeout`, else `gtimeout`, else a background job + kill, since
   stock macOS ships no `timeout`.
3. `docker ps` finds a container from the official image (matched by
   ancestor image first, falling back to the compose file's documented
   container_name `basic-memory-server` in case of a locally-built
   image)?
4. That container has a published host port for its container port
   8000, and a real bind mount at `/app/data` (found via
   `docker inspect`, not guessed)?
```

If all four hold, Docker mode is used: the storage root
(`BASIC_MEMORY_ROOT`) becomes the container's *actual* `/app/data`
host-side mount — not `--basic-memory-root` if one was passed and
disagrees, and not basic-memory's own local-CLI default — since
asynthlogr's files have to land somewhere the running container can
actually see. MCP registration uses
`claude mcp add --transport <sse|http> basic-memory http://localhost:<PORT><path>`
instead of the stdio form, with the transport and path read from the
container's own command (`docker inspect … .Config.Cmd`:
`--transport sse` → `sse`, `streamable-http` → `http`; `--path`,
default `/mcp`). The installer then talks to that same endpoint over
MCP (`list_memory_projects`, `create_memory_project`) and gives it the
**container-side** path (`/app/data/asynthlogr`), while
`asynthlogr.config.json`'s
`basic_memory_dir` still records the **host-side** path (what a human
or Obsidian would open). `basic_memory_mode` (`"cli"` or `"docker"`)
is recorded in that same config file so any downstream tooling can
tell which one is in play, along with `basic_memory_project_path` (the
path as basic-memory sees it); Docker mode additionally records
`basic_memory_docker_container`, `basic_memory_mcp_endpoint` and
`basic_memory_mcp_transport`. In CLI mode the installer speaks MCP over
stdio to `basic-memory mcp`, the same server Claude Code launches.

If a basic-memory container exists but doesn't match this exact,
documented layout (no recognizable `/app/data` mount, or no reachable
published port), `install.sh` says so and falls back to CLI mode
rather than guessing at a custom deployment's layout.

## Race condition and its fix

**Problem:** subagent-run logging fires on every subagent call (steps
1/2/3/5), constantly, in the background. If thread naming were
invented lazily on "first write" inside `decision-logger`, two
near-simultaneous background dispatches early in a session could each
invent a different name for what should be one thread, creating two
folders.

**Fix:** thread naming is never delegated to `decision-logger`. The
orchestrator computes `thread` once, synchronously, at session start
(see `templates/AGENTS.md.snippet`, "At session start"), before any
dispatch happens. Every dispatch after that just passes the
already-decided name. Same principle applies to `run_id`/`topic_slug`
— always orchestrator-generated, synchronously, immediately before
each dispatch, never invented by the subagent or by `decision-logger`.

## Placeholder output notes — no waiting on a run

**Problem:** a run's `output.md` is written by `decision-logger` only
after the subagent's result reaches the orchestrator, in some later
turn. If the session ends first, or the logger's write fails, the run
has no output note at all.

**Why not wait for it:** Claude Code's `Stop` event fires every time
Claude finishes a response, and a blocking `Stop` hook forces Claude to
keep going without the human seeing why; `SessionEnd` can't block at
all. An earlier design used a non-blocking `Stop` warning plus a
`SessionEnd` "abandoned" line in `failed-writes.log`, but it depended
on each subagent setting `status` in its tracking note, which
basic-memory's `metadata`-less tools never allowed, so it warned about
every run, finished or not. It is gone, and `install.sh` removes it
from older installs.

**Design:** the output can always be recovered from the subagent
itself, so the orchestrator records where to find it up front. As soon
as a dispatch returns the subagent's `agent_id`, the orchestrator
writes the run's `output.md` as a placeholder (template in
`docs/subagent-run-format.md`), tagged `subagent-run-pending`, with the
agent ID, the resume command and the subagent's transcript path
(`<session dir>/<session_id>/subagents/agent-<agent_id>.jsonl`). When
the result arrives, `decision-logger` writes the real output over it
(same title and directory) with only the `subagent-run` tag.

A run whose output was never logged therefore stays visible: its note
says so and points at the subagent, and the daily report counts it as
"not finished" (subagent still running, `output.md` missing, or still
tagged `subagent-run-pending`). Nothing writes an "abandoned" line to
`failed-writes.log` for it anymore; that log is only for failed writes.

**Residual limitation:** a run whose dispatch never returned an
`agent_id` (built-in Explore and Plan agents) gets a placeholder with
no resume or transcript lines, since those agents can't be resumed.

## Session and subagent IDs (for resuming)

Every thread records the Claude Code session it ran in, and every
subagent run records its agent ID, so either conversation can be
picked up again later. The IDs always come from Claude Code itself,
through `hooks/session-ids.sh`, never from a model's guess:

- **SessionStart** prints the session's ID and transcript path as
  plain text, which Claude Code adds to the orchestrator's context.
  The orchestrator writes them into the thread tracking note
  (`session_id`, `session_transcript`) and into the thread note's
  header: `**Session:** <id> · resume with claude --resume <id>`.
- **SubagentStart** injects, via `additionalContext`, the subagent's
  own `agent_id` and its parent `session_id` — only for subagents whose
  definition carries a "## Tracking Contract". The subagent records
  both in its tracking note when it sets `status: running`.
  The orchestrator puts them in the run's placeholder `output.md` as
  soon as the dispatch returns the `agent_id`, and `decision-logger`
  keeps them when it writes the real output over it.

To resume: `claude --resume <session_id>` for a session. A subagent is
resumed from inside its parent session: resume the parent, then ask
Claude to continue that agent (it sends a message to the `agent_id`).
Built-in Explore and Plan agents return no agent ID and can't be
resumed. The daily report shows each thread's session ID with its
resume command.

## Reports

`/asynthlogr-report` runs `bin/asynthlogr-report.sh`, which reads the
vault as plain files and writes one note per day,
`reports/<YYYY-MM-DD>.md`, through basic-memory: a cross-repo summary
table, then a section per repo and per active thread. Generation is
manual only. See `docs/reports-design.md`.

## Human vs. machine communication (scope boundary)

- **Applies ADHD-style formatting** (`skills/i-have-adhd/`) — lead
  with action, numbered steps, restate progress each turn, concrete
  time estimates, cap lists to 5, no preamble/pleasantries — to:
  progress updates, clarifying questions, pre-question context,
  summaries. Anything addressed to the human.
- **Does NOT apply to:** delegation messages to subagents,
  decision/info/subagent-run entries written to the vault,
  `agent-use-tracking.md` contents. These stay in the structured
  formats specified in `docs/decision-entry-format.md` and
  `docs/subagent-run-format.md`, regardless — they are not addressed
  to a human reader, and reformatting them would break
  `decision-logger`'s parsing contract.
- Loaded via the Skill tool at session start; persists per the skill's
  own rule until the user says "stop adhd mode" or "normal mode."

Separately, all vault content (a different axis — content correctness,
not tone) follows `skills/obsidian-notation-expert/` and
`skills/obsidian-node-link-expert/`, since the vault is meant to be
browsed directly in Obsidian, Graph View included.

## Known limitations

See `docs/known-limitations.md`.

## Open implementation items

See `docs/open-items.md`.
