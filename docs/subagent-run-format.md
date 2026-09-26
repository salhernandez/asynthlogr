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
  - <run_id>          # links a decision/info entry to supporting subagent-run(s)
model_reported: <orchestrator's best-guess current model — ALWAYS labeled unverified, omit if unknown>
```

## `subagents/<run>/output.md` format (written by decision-logger)

```markdown
# Subagent run — <subagent name>
**Timestamp:** <ISO8601>
**Invoked by:** orchestrator (main)
**Thread:** [[../../<thread-name>|<thread-name>]]

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
is ever an orphan in Graph View.

## `subagents/<run>/agent-use-tracking.md` (written live by the subagent itself)

```markdown
---
run_id: 2026-09-26T11-14-51
subagent_name: research-agent
topic_slug: rate-limit-handling
status: running        # dispatched | running | completed | failed
started_at: 2026-09-26T11:14:51-07:00
updated_at: 2026-09-26T11:15:40-07:00
---

# Run log
- 11:14:51 — dispatched
- 11:14:52 — tool call: WebSearch
- 11:15:10 — tool call: Read
- 11:15:40 — asked clarifying question: "should this cover the retry path too?"
```

## Thread-level `agent-use-tracking.md` (written by the orchestrator)

```markdown
---
repo: repo-1
thread: auth-token-refresh
current_step: 3
current_step_name: proposing-solution
updated_at: 2026-09-26T11:21:00-07:00
---

# Step log
- 2026-09-26T10:58:02 — step 1 (research) started
- 2026-09-26T11:02:03 — step 1 — subagent run: research-agent-auth-token-refresh
- 2026-09-26T11:05:00 — step 2 (clarifying questions) started
- 2026-09-26T11:14:51 — step 2 — subagent run: research-agent-rate-limit-handling
- 2026-09-26T11:20:10 — step 3 (proposing solution) started — dispatched planning-agent
```
