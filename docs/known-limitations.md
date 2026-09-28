# Known limitations

Ship with these documented, not silently.

1. **Model name / context-window % are not programmatically
   obtainable** anywhere in Claude Code — no hook, env var, or CLI
   surface exposes context-window usage at all, and model name is
   only observable via `PreModelSwitch`/`PostModelSwitch` hook events,
   which fire on switches, not on-demand. `model_reported` in every
   entry is therefore always a self-reported guess from the
   orchestrator, always labeled `*(unverified)*` in the rendered
   entry — never presented as measured.

2. **A run whose output was never logged is only flagged, not
   recovered** — if the session ends (or `decision-logger` fails)
   before a run's result is written, its `output.md` stays the
   orchestrator's placeholder: it says the output is missing and names
   the agent ID, resume command and transcript path, and the daily
   report counts the run as "not finished". Nothing copies the output
   in automatically, and nothing writes to `failed-writes.log` for it
   (see `docs/architecture.md`, "Placeholder output notes"). Built-in
   Explore and Plan agents return no agent ID, so their placeholder
   has no way back to the output.

3. **Step 3/step 5 detection is a semantic judgment**, not a platform
   event — hooks cannot detect "a solution was proposed" or "a plan
   was finalized." The explicit 5-step checklist in `AGENTS.md` and
   the `agent-use-tracking.md` step-transition file are the best
   available mitigation, not a guarantee.

4. **Daily reports are generated only on request** (`/asynthlogr-report`,
   or `--catch-up` for every missing day) — nothing writes them
   automatically. Days are bucketed by each timestamp's local date
   prefix, so a vault written from several time zones puts each entry
   on its writer's local day (see `docs/reports-design.md`).

5. **Thread naming happens once per session; it isn't retroactively
   editable by decision-logger.**

6. **Resuming a subagent needs its parent session.** Its `agent_id`
   is only meaningful inside the session that spawned it, so resume
   that session first (`claude --resume <parent_session_id>`), then
   ask Claude to continue the agent. Built-in Explore and Plan agents
   can't be resumed at all. The IDs come from hooks, but a model still
   copies them into the notes; a note may say `unknown` if a hook's
   message was missing.

7. **basic-memory-via-Docker detection only recognizes the official
   image's documented layout** — a container from
   `ghcr.io/basicmachines-co/basic-memory` with a real `/app/data`
   bind mount and a published port for its container port 8000. A
   customized deployment (locally-built image, different compose file,
   non-default mount path, non-default port mapping approach that
   `docker port` can't resolve) won't be recognized, and `install.sh`
   falls back to CLI mode rather than guessing at its layout. See
   `docs/architecture.md`'s "basic-memory: CLI mode vs. Docker mode"
   section and `docs/open-items.md` ("Still open" #4).
