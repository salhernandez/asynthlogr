# Tests

Two layers, both verified to actually pass before this repo was
shipped — not just written and assumed to work. Both run in CI on
every push via `.github/workflows/test.yml`: Linux (debian:bookworm-slim,
Docker), Windows (`windows-latest`, bats via Git Bash), and macOS
(`macos-latest`, bats natively) — all free, since GitHub Actions
standard runners are unlimited on public repos regardless of OS.

## Layer 1 — bats unit tests (no Docker needed)

```
bats tests/unit/install_test.bats
bats tests/unit/stop_hook_test.bats
```

30 tests total (23 for `install.sh`, 7 for the Stop hook), run
directly against fixtures under `tests/fixtures/` and stubbed external
CLIs under `tests/stubs/bin/` (`claude`, `uv`, `basic-memory`, `docker`
— fake, deterministic, no network/auth, no real Docker daemon needed).
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

Confirmed passing on Ubuntu 24.04 with `bats` 1.10.0 at the time this
suite was written.

## Layer 2 — Docker, debian:bookworm-slim

```
tests/docker/run.sh
```

Builds `tests/docker/Dockerfile.debian-bookworm-slim` (Debian
bookworm-slim + `bash`, `bats`, `jq`, `git`, `ca-certificates` — the
`bats` package is confirmed present in Debian bookworm's repos) and
runs the same two bats files inside it. This layer exists to catch
anything that's specific to a clean, minimal Debian environment rather
than whatever machine you happen to be developing on.

**Honesty note:** this Dockerfile and run script were written and
syntax-checked, and the `bats` package's presence in Debian bookworm
was confirmed against Debian's own package pages, but the actual
`docker build && docker run` could not be executed in the environment
this repo was assembled in (no Docker daemon access there). Run
`tests/docker/run.sh` yourself once to confirm before relying on it in
CI — it should work as written, but "should" isn't "verified" for this
one layer specifically, unlike layer 1 above.

## What's NOT covered here

Both layers test `install.sh` and the Stop hook script — deterministic
bash logic. Neither tests whether `decision-logger` actually writes
valid Obsidian syntax, correct wikilinks, or whether the async
dispatch genuinely doesn't block a real Claude Code session. That's a
harder, separate layer (see the "runtime/behavioral tests" discussion
in project history) — not built yet.
