# Reports — design

Status: **implemented** in `bin/asynthlogr-report.sh`, run manually
through the `/asynthlogr-report` skill. Decided: one note per day with
a section per repo, and manual generation only.

## Goal

One note per day that answers, without opening every thread: *what
was decided, where, and what got lost.* It covers every repo that
logs into the shared `asynthlogr` vault (the cross-repo rollup), with
a section per repo (the per-repo view). Both were requested.

Not a goal: judging decision quality, summarizing subagent output, or
tracking whether open questions were later resolved. None of that can
be read reliably out of the vault.

## Inputs (all already in the vault)

| Source | What the report reads | How a day is matched |
|---|---|---|
| `<repo>/<thread>/<thread>.md` | Decision/info entry headers `## <ts> — <summary>` and their `**Type:**` line; items under `### Open questions` (or its `> [!question]` callout form) | date prefix of `<ts>` |
| `<repo>/<thread>/agent-use-tracking.md` | `current_step`, `current_step_name`; step-log lines | date prefix of each step-log line |
| `<repo>/<thread>/subagents/<run>/agent-use-tracking.md` | `subagent_name`, `status` | `<run>` folder name starts with the ISO date |
| `<vault-root>/failed-writes.log` | failed and abandoned writes | date prefix of each line |

The generator only *reads* these as files, the same way the
pending-run hooks already do. Its one write, the report itself, goes
through basic-memory (principle 6).

### Prerequisite: pin the timestamp format

Bucketing by day needs every timestamp in one known form. Today:
- Decision/info headers say only `<timestamp>`. **Change:** pin them
  to local ISO 8601 with offset, `## 2026-09-26T11:21:00-07:00 — …`,
  in `docs/decision-entry-format.md` and `decision-logger.md`.
- `failed-writes.log` lines use UTC (`…Z`) while everything else uses
  local time, so a failure just before midnight would land on the
  wrong day. **Change:** have the hook and `decision-logger` write
  local time with an offset (`date +%Y-%m-%dT%H:%M:%S%z`).

**Rule:** a day is the literal `YYYY-MM-DD` prefix of each timestamp,
in the writer's local time. The generator never converts time zones.
That keeps it portable, since GNU and BSD `date` parse differently,
and it's correct as long as the vault is written from one time zone.
A vault shared across time zones buckets each entry by its writer's
local day, which is documented rather than fixed.

## Output

### Where (decided)

**One note per day**, `reports/<YYYY-MM-DD>.md`, with a
cross-repo summary at the top and one `##` section per repo. The
per-repo view is then a heading link, `[[reports/2026-09-26#repo-1]]`.

Rejected: separate per-repo notes
(`reports/<repo>/<date>.md`) plus a rollup that links to them. That
triples the notes and writes for no new information. Revisit it only
if daily notes get unwieldy, say more than about 10 repos a day.

A day with no activity in any repo gets **no** note: no empty
placeholder notes cluttering the graph.

### Format

```markdown
---
title: 2026-09-26
type: report
report_date: 2026-09-26
generated_at: 2026-09-27T09:02:11-07:00
complete: true            # false when generated for today (day still in progress)
repos: [repo-1, repo-2]
tags: [asynthlogr-report]
---

# asynthlogr — 2026-09-26

| Repo | Threads | Decisions | Info | Subagent runs | Failed / abandoned |
| :--- | --: | --: | --: | --: | --: |
| [[#repo-1]] | 2 | 3 | 1 | 7 | 1 |
| [[#repo-2]] | 1 | 0 | 2 | 2 | 0 |

> [!warning] 1 log write failed or was abandoned
> Details in the repo sections below; raw lines in `failed-writes.log`.

## repo-1

### [[repo-1/auth-token-refresh/auth-token-refresh|auth-token-refresh]] · step 3 (propose)

**Decisions**
- 11:21 — Use a sliding refresh window
- 15:40 — Retry refresh once, then force re-login

**Info**
- 12:05 — Rate limits documented in config/limits.yml

**Subagent runs:** 5 (research-agent ×3, planning-agent ×2) · 1 still running

> [!question]- Open questions raised (2)
> - Should refresh also rotate the device key?
> - Does the mobile client share this path?

**Failed / abandoned writes**
- 23:10 — subagent-run — abandoned: 2026-09-26T22-58-01_planning-agent-retry-policy still running at session end

### [[repo-1/ci-flake-hunt/ci-flake-hunt|ci-flake-hunt]] · step 1 (research)
…

## repo-2
…
```

Format choices and why:
- **The counts table comes first.** It answers "anything happening?"
  at a glance. The report is vault content, so it uses a structured
  template, not the conversational style used in chat (spec §10). It
  should still be quick to scan.
- **Each thread heading links to its thread note** with a full-path
  wikilink, so the report connects to every active thread in Graph
  View. The `asynthlogr-report` tag lets you filter reports out of the
  graph when they're noise.
- **Decisions show time + summary as plain text, not heading links.**
  The entry headings contain `:` and `—`, which Obsidian heading links
  and basic-memory don't handle reliably. The thread link is one
  click away. (A v2 could add block IDs to entries if deep links turn
  out to matter.)
- **Open questions are only those *raised* that day**, in a folded
  callout. Whether they were later resolved can't be read out of the
  vault.
- **Failures are listed per repo**, taken from `failed-writes.log`'s
  `<repo>/<thread>` field.

## Generator

### Deterministic script, not an agent

`bin/asynthlogr-report.sh`, installed to
`.claude/asynthlogr/bin/asynthlogr-report.sh`. Plain bash +
`grep`/`awk`/`sed`, the same toolset as the pending-run hook (POSIX
awk only, so it runs under mawk, gawk and BSD awk), plus `jq` to read
the config.

Why not an LLM agent: every piece of the format above can be pulled
out mechanically; an agent would add cost, run-to-run variation, and
invented content; and a script can be tested with bats against
fixture vaults, like the rest of the repo. A written narrative
summary ("today the auth work settled on…") is the one thing a script
can't do. See "Later" below.

### Interface

```
asynthlogr-report.sh [--date YYYY-MM-DD | --today] [--catch-up] [--since YYYY-MM-DD]
```

- `--date D`: generate (or regenerate) the report for day D.
- `--today`: today's report, marked `complete: false`.
- `--catch-up`: generate every *finished* day that has activity and
  no report yet, optionally only from `--since` onward. The first
  catch-up backfills every past day with activity; days are compared
  as `YYYY-MM-DD` strings, so no date arithmetic (which differs
  between GNU and BSD `date`) is needed.
- No arguments means `--today`.
- The vault root, mode (`cli`/`docker`) and container come from
  `.claude/asynthlogr.config.json`, so the script works from any
  installed repo and always covers **every** repo in the vault.

### Algorithm

1. Find each active thread: a thread is active on day D if its thread
   note has a `## D` header, its step log has a `- D` line, or it has
   a run folder starting with `D`.
2. For each active thread, pull the day's entries, runs, open
   questions and failures (the table under "Inputs").
3. Render in a fixed order (repos, then threads, then entries, each
   sorted), so a rerun on unchanged data produces the same body.
4. Write through basic-memory, `project asynthlogr`, folder `reports`,
   title `<D>`:
   - CLI mode: `basic-memory tool write-note … --overwrite`
   - Docker mode: the same command through `docker exec -i <container>`
   - basic-memory 0.18.x has no `--overwrite` and replaces by default:
     if the flag is rejected, retry without it (the same fallback
     approach `install.sh` uses for `project list --json`).
5. If the write fails, append a `report` line to `failed-writes.log`
   and exit 0. Never retry, never block (principle 5).

Two repos catching up at the same moment can write the same day's
report twice. Both write the same body, so the only difference is
`generated_at` and the race is harmless. No lock needed.

## Trigger (decided): manual only

Reports are generated only when asked for: the `/asynthlogr-report`
skill (installed with the others, `disable-model-invocation: true` so
Claude never runs it on its own) runs the script with whatever
arguments were typed, or run the script directly. `--catch-up` fills
in every finished day that's missing a report in one go.

Considered and not taken:
- **Background catch-up at session start** (an `async` `SessionStart`
  hook): would never block, but writes reports nobody asked for.
  Adding it later is one hook registration.
- **At session end:** there's a 1.5s budget (60s at most) shared with
  the pending-run hook, and a Python CLI start plus a vault scan could
  overrun it. It would also run at every exit, not once a day.
- **OS scheduler (cron, launchd, Task Scheduler):** the installer
  would have to create persistent system configuration, per OS.
- **Claude Code cloud routines:** they can't see a local vault.

Only `--today` (the default) writes a report for a day still in
progress, and flags it `complete: false`.

## Implementation notes

- Tests: `tests/unit/report_test.bats` (14 tests, inline fixture vault)
  covers day bucketing, both open-question forms, the step as of a
  given day, failure-only threads, a day with no activity, `--today`,
  identical reruns, `--catch-up`/`--since`, the 0.18.x no-`--overwrite`
  fallback, Docker mode, and a failed write.
- Checked live against basic-memory 0.18.4 in Docker: the report is
  written and replaced through `tool write-note`, and catch-up skips
  days that already have a report. basic-memory rewrites the report's
  frontmatter in its own style (quoted title, block lists, a space
  instead of `T` in `generated_at`); the body is stored as rendered.
- Prerequisite done: entry headers, `**Timestamp:**` lines, and
  `failed-writes.log` lines are all local ISO 8601 with offset.

## Later (not in v1)

- **Written narrative summary:** an optional background agent that
  reads the finished day's report plus the linked threads and adds a
  `## Summary` section with `edit_note`. The deterministic body stays
  the source of truth.
- **Weekly and monthly rollups:** built from the daily notes, not from
  rescanning the whole vault.
- **Deep links to individual entries:** needs block IDs on entries,
  a format change for `decision-logger`.
