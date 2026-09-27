# Tests

Two layers, both verified to actually pass before this repo was
shipped — not just written and assumed to work. Both run in CI on
every push via `.github/workflows/test.yml`: Linux (debian:bookworm-slim,
Docker), Windows (`windows-latest`, bats via Git Bash), and macOS
(`macos-latest`, bats natively) — all free, since GitHub Actions
standard runners are unlimited on public repos regardless of OS.

## Layer 1 — bats unit tests (no Docker needed)

```
bats tests/unit/
```

76 tests total (37 for `install.sh`, 13 for the pending-run hook's
`Stop` and `SessionEnd` branches, 5 for the session/agent ID hook, 16
for the daily report generator, 5 static checks on the agent/skill
definitions in
`definitions_test.bats`), run
directly against fixtures under `tests/fixtures/` and stubbed external
CLIs under `tests/stubs/bin/` (`claude`, `uv`, `basic-memory`, `docker`,
`curl` — fake, deterministic, no network/auth, no real Docker daemon
needed). basic-memory is only ever reached over MCP: `mcp-stub-respond`
plays its MCP server for both the stdio stub (`basic-memory mcp`) and
the `curl` stub (the SSE/HTTP endpoint), and the `basic-memory` stub
rejects every CLI subcommand, so a regression to CLI use fails loudly.
Real `jq`/`git`/coreutils are used as-is since they're deterministic
and don't touch anything external.

The `docker` stub exercises `install.sh`'s basic-memory-via-Docker
detection (daemon absent/not-running, no container up, and a container
matching the official image's documented layout) without a real Docker
daemon — see the "basic-memory-via-Docker detection" section of
`tests/unit/install_test.bats`. It's a separate, narrower thing from
layer 2 below, which runs the *whole test suite* inside a Docker
container — the stub is used *by* layer 1 (and inside layer 2) to fake
*install.sh's own* Docker calls.

Confirmed passing on Ubuntu 24.04 with `bats` 1.10.0 when the suite
was first written, and on Debian bookworm (layer 2) since. The
`timeout`-less Docker-detection test is skipped under Git Bash, where
building its symlinked PATH isn't practical; macOS CI covers it.

## Layer 2 — Docker, debian:bookworm-slim

```
tests/docker/run.sh
```

Builds `tests/docker/Dockerfile.debian-bookworm-slim` (Debian
bookworm-slim + `bash`, `bats`, `jq`, `git`, `ca-certificates` — the
`bats` package is confirmed present in Debian bookworm's repos) and
runs the same bats files inside it. This layer exists to catch
anything that's specific to a clean, minimal Debian environment rather
than whatever machine you happen to be developing on.

Confirmed working: `tests/docker/run.sh` builds the image and the
full suite passes inside it (run on Docker 29.2 from Git Bash on
Windows 11). CI runs this layer on `ubuntu-latest`.

## What's NOT covered here

Both layers test `install.sh`, the pending-run hook, the report
generator, and the static
wiring of the agent/skill definitions — deterministic
bash logic. Neither tests whether `decision-logger` actually writes
valid Obsidian syntax, correct wikilinks, or whether the async
dispatch genuinely doesn't block a real Claude Code session. That's a
harder, separate layer (see the "runtime/behavioral tests" discussion
in project history) — not built yet.
