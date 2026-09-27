# Subagent-run formats

Three related pieces: the delegation message the orchestrator sends to
`decision-logger`, the distilled `output.md` `decision-logger` writes
back, and the two tracking-file formats (thread-level and per-run)
that orchestrator/subagents write directly.

## Delegation message template (orchestrator → decision-logger)

This is the de facto schema for every `decision-logger` dispatch,
since subagents receive natural-language delegation text only (no
structured payload passing). Send this as the task/prompt text,
verbatim structure:

```
DECISION LOG ENTRY

repo: <repo name>
thread: <thread name — always already resolved, never invented here>
vault_root: <basic_memory_dir from .claude/asynthlogr.config.json — where failed-writes.log lives>
thread_note: <permalink of <thread>.md, returned by write_note at session start>
entry_type: <"decision" | "info" | "subagent-run">
trigger: <"solution-proposed" | "plan-finalized" | "manual" | "subagent-call">

# --- entry_type: decision only ---
context: >
  <what problem/area prompted this decision>
options_considered:
  - option: <option A>
    outcome: chosen | discarded
    why: <reason>
  - option: <option B>
    outcome: chosen | discarded
    why: <reason>
decision: >
  <what was actually chosen>
rationale: >
  <why, if not fully covered above>
decision_maker: <"user" | "agent-suggested, user-approved">

# --- entry_type: info only ---
content: >
  <freeform information being captured>

# --- entry_type: subagent-run only ---
run_id: <orchestrator-generated timestamp>
subagent_name: <e.g. "research-agent">
topic_slug: <orchestrator-generated>
run_folder: <run_id>_<subagent_name>-<topic_slug>
agent_id: <the subagent's agent ID, as Claude Code returned it — for resuming it>
parent_session_id: <this session's ID>
prompt_used: >
  <exact prompt/task text sent to the subagent>
questions_asked:
  - <clarifying question the subagent asked, if any>
final_output: >
  <the subagent's full, undistilled final report>

# --- common to all types ---
agent: <name of the agent/subagent that did the work being logged>
tools_used:
  - <tool name>
qa:
  - q: <clarifying question asked>
    a: <answer given>
open_questions:
  - <unresolved thing, if any>
files_touched:
  - path: <repo-relative path>
    lines: <optional>
commit: <sha, if applicable>
pr: <PR number or URL, if applicable>
related_runs:
  - <run_folder>      # links a decision/info entry to supporting subagent-run(s)
model_reported: <orchestrator's best-guess current model — ALWAYS labeled unverified, omit if unknown>
```

## `subagents/<run>/output.md` placeholder (written by the orchestrator)

Written right after the dispatch returns the subagent's `agent_id`,
long before the run finishes. Nothing waits on the subagent: if its
result is never logged (the session ends first, the logger fails),
this note still says where the output lives.

```markdown
# Subagent run — <subagent name>
**Status:** not logged yet. If this note still says so, the run's final output was never written here — resume the subagent, or read its transcript, below.
**Timestamp:** <ISO8601, at dispatch>
**Invoked by:** orchestrator (main)
**Thread:** [[<repo>/<thread-name>/<thread-name>|<thread-name>]]
**Agent ID:** `<agent_id>`
**Parent session:** `<session_id>`
**Resume:** `claude --resume <session_id>`, then ask Claude to continue agent `<agent_id>`
**Transcript:** `<directory of session_transcript>/<session_id>/subagents/agent-<agent_id>.jsonl`
```

Leave out the **Agent ID**, **Parent session**, **Resume** and
**Transcript** lines when the dispatch returned no `agent_id` (built-in
Explore and Plan agents return none and can't be resumed).

Written with `write_note(title: "output", directory:
"<repo>/<thread>/subagents/<run_folder>", ..., tags: ["subagent-run",
"subagent-run-pending"], project: "asynthlogr")`. The
`subagent-run-pending` tag is how the daily report counts runs whose
output was never logged.

## `subagents/<run>/output.md` format (written by decision-logger)

```markdown
# Subagent run — <subagent name>
**Timestamp:** <ISO8601>
**Invoked by:** orchestrator (main)
**Thread:** [[<repo>/<thread-name>/<thread-name>|<thread-name>]]
**Agent ID:** `<agent_id>`
**Parent session:** `<parent_session_id>`
**Resume:** `claude --resume <parent_session_id>`, then ask Claude to continue agent `<agent_id>`

## Prompt used
<the exact prompt/task text the orchestrator sent to this subagent>

## Additional questions asked by subagent
- <question 1>
(omit this section if none)

## Tools used
`Grep`, `Read`, `WebFetch`

## Final output
<the subagent's full, undistilled final report>
```

The `**Thread:**` line is a wikilink back to the parent thread note —
per `skills/obsidian-node-link-expert/`, this guarantees no run note
is ever an orphan in Graph View. It uses the full path from the vault
root, not a relative `../../` path: every run folder holds notes with
the same names (`output`, `agent-use-tracking`), and basic-memory
resolves links by title or permalink, never relative to the linking
note.

Written with `write_note(title: "output", directory:
"<repo>/<thread>/subagents/<run_folder>", ..., tags: "subagent-run",
project: "asynthlogr")`, which replaces the orchestrator's placeholder
(same title and directory) and drops its `subagent-run-pending` tag.

## `subagents/<run>/agent-use-tracking.md` (written live by the subagent itself)

Created by the orchestrator with `status: dispatched` just before
dispatch; the subagent then sets `running` as its first action and
`completed`/`failed` as its last. basic-memory's tools take no
`metadata` argument: `write_note` reads frontmatter from a YAML block
at the top of `content`, and later changes are `read_note` +
`edit_note`'s `find_replace` on lines copied verbatim from what
`read_note` returned (basic-memory reformats stored values, e.g.
timestamps, and adds its own `title`, `type`, and `permalink` fields).
The daily report reads `status` directly from this file.

```markdown
---
run_id: 2026-09-26T11-14-51
subagent_name: research-agent
topic_slug: rate-limit-handling
status: running        # dispatched | running | completed | failed
agent_id: agent-a1b2c3d4            # set by the subagent from its SubagentStart note
parent_session_id: 00893aaf-19fa-41d2-8238-13269b9b3ca0
started_at: 2026-09-26T11:14:51-07:00
updated_at: 2026-09-26T11:15:40-07:00
---

# Run log
- 11:14:51 — dispatched
- 11:14:52 — running
- 11:14:53 — tool call: WebSearch
- 11:15:10 — tool call: Read
- 11:15:40 — asked clarifying question: "should this cover the retry path too?"
```

## Thread-level `agent-use-tracking.md` (written by the orchestrator)

```markdown
---
repo: repo-1
thread: auth-token-refresh
session_id: 00893aaf-19fa-41d2-8238-13269b9b3ca0   # from the SessionStart hook
session_transcript: /Users/.../.claude/projects/.../00893aaf-19fa-41d2-8238-13269b9b3ca0.jsonl
current_step: 3
current_step_name: proposing-solution
updated_at: 2026-09-26T11:21:00-07:00
---

# Step log
- 2026-09-26T10:58:02 — step 1 (research) started
- 2026-09-26T11:02:03 — step 1 — subagent run: 2026-09-26T11-02-03_research-agent-auth-token-refresh
- 2026-09-26T11:05:00 — step 2 (clarifying questions) started
- 2026-09-26T11:14:51 — step 2 — subagent run: 2026-09-26T11-14-51_research-agent-rate-limit-handling
- 2026-09-26T11:20:10 — step 3 (proposing solution) started — dispatched planning-agent
```
