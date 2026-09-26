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
   prompt. Runs still pending when the session ends are recorded there
   too (see "Pending-run hooks" below).
6. **basic-memory is a hard, required dependency — not one option
   among several.** Every piece of information this system logs —
   decision/info entries, subagent-run output, both levels of
   `agent-use-tracking.md` — is written through the basic-memory MCP
   server, by whichever agent owns that file. `install.sh` ensures
   basic-memory is reachable one of two ways (see "basic-memory: CLI
   mode vs. Docker mode" below) and registers its Claude Code MCP
   server if needed — it does not just check and fail. The only files
   in this whole system that are plain filesystem files, not
   basic-memory-managed notes, are repo-local operational files that
   live outside the vault: `.claude/active-thread.json`,
   `.claude/asynthlogr.config.json`, and `failed-writes.log` (an ops
   dead-letter log, not a knowledge artifact — `install.sh` lists it
   in the project's `.gitignore`, which basic-memory honors, so it
   stays out of basic-memory's index).
7. **asynthlogr is itself a basic-memory project, not an arbitrary
   folder.** It does not get to pick an unrelated directory — its
   storage lives at `<basic-memory-root>/asynthlogr`
   (`~/basic-memory/asynthlogr` by default) and is registered with
   `basic-memory project add asynthlogr <path>`, exactly like any other
   project a basic-memory user might create. This means the vault this
   system writes to shows up naturally alongside the user's other
   basic-memory projects, not as a separate, disconnected store.

## basic-memory: CLI mode vs. Docker mode

basic-memory can be reached two ways, and `install.sh` detects both,
in this order:

1. **Docker mode** — an already-running container of the official
   `ghcr.io/basicmachines-co/basic-memory` image (see its
   [`docker-compose.yml`](https://github.com/basicmachines-co/basic-memory/blob/main/docker-compose.yml)).
   That image serves basic-memory's MCP server over **SSE on port
   8000** (`basic-memory mcp --transport sse --host 0.0.0.0 --port
   8000` — SSE only, not stdio, not HTTP-streamable), and bind-mounts
   the knowledge directory at `/app/data` inside the container.
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
`claude mcp add --transport sse basic-memory <http://localhost:PORT/sse>`
instead of the stdio form. Every later `basic-memory project ...` call
runs via `docker exec <container> basic-memory ...` rather than a bare
`basic-memory ...`, and is given the **container-side** path
(`/app/data/asynthlogr`), while `asynthlogr.config.json`'s
`basic_memory_dir` still records the **host-side** path (what a human
or Obsidian would open). `basic_memory_mode` (`"cli"` or `"docker"`)
is recorded in that same config file so any downstream tooling can
tell which one is in play; Docker mode additionally records
`basic_memory_docker_container` and `basic_memory_mcp_endpoint`.

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

## Pending-run hooks — warn, then record

**Problem:** a background subagent-run write depends on its completion
notification reaching the orchestrator in a later turn. If the session
ends first, that write never happens — silently, since it never
touches `failed-writes.log` either (that only catches write failures,
not "never attempted").

**Why not block the exit:** Claude Code's `Stop` event fires every
time Claude finishes a response, not only when the session is about
to end, and a blocking `Stop` hook sends its message to *Claude* and
forces it to keep going — the human never sees it. A blocking hook
would therefore interrupt the session mid-work whenever background
runs were in flight, breaking principle 1. `SessionEnd`, which does
fire on exit, can't block at all.

**Mitigation:** one script, `hooks/check-pending-subagents.sh`,
registered for both events, branching on `hook_event_name`:

```
Both events:
1. Read <target-repo>/.claude/active-thread.json for {vault_root, repo, thread}.
   If missing, do nothing — no active thread to check.
2. Scan <vault_root>/<repo>/<thread>/subagents/*/agent-use-tracking.md.
   Collect any with status: dispatched or status: running.
3. If none pending: do nothing.

Stop (end of every Claude response):
4. Exit 0 with {"systemMessage": "..."} — a warning shown to the human
   listing each pending run and saying that exiting now records them
   as abandoned. Never blocks, keeps no state, repeats each turn while
   runs stay pending.

SessionEnd (exit, /clear, /resume; can't block):
4. Append one line per pending run to <vault_root>/failed-writes.log:
   <timestamp> | <repo>/<thread> | subagent-run | abandoned: <run> still <status> at session end (reason: <reason>)
   A run already recorded as abandoned is not recorded again.
```

This turns "silently never logged" into a dead-letter entry, with no
blocking anywhere. `install.sh` gives the `SessionEnd` registration a
5-second `timeout`, which raises Claude Code's default 1.5-second
`SessionEnd` budget.

**Known residual limitation (accepted, not solvable in this design):**
a hard-killed session (container reclaimed, terminal closed without a
clean exit, crash) fires neither `Stop` nor `SessionEnd`, so its
pending runs leave no trace.

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
