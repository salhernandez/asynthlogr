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

2. **A hard-killed session leaves no trace** — only a clean exit
   fires `SessionEnd`, which records still-pending runs in
   `failed-writes.log` (see `docs/architecture.md`, "Pending-run
   hooks"). Relatedly, the `Stop`-hook warning goes to the human only;
   it can't make the session wait for in-flight runs, by design (a
   blocking `Stop` hook would interrupt Claude mid-session).

3. **Step 3/step 5 detection is a semantic judgment**, not a platform
   event — hooks cannot detect "a solution was proposed" or "a plan
   was finalized." The explicit 5-step checklist in `AGENTS.md` and
   the `agent-use-tracking.md` step-transition file are the best
   available mitigation, not a guarantee.

4. **Reporting (`reports/` — daily recap generation)** is referenced
   in the vault layout but not yet designed — see `docs/open-items.md`.

5. **Thread naming happens once per session; it isn't retroactively
   editable by decision-logger.**

6. **basic-memory-via-Docker detection only recognizes the official
   image's documented layout** — a container from
   `ghcr.io/basicmachines-co/basic-memory` with a real `/app/data`
   bind mount and a published port for its container port 8000. A
   customized deployment (locally-built image, different compose file,
   non-default mount path, non-default port mapping approach that
   `docker port` can't resolve) won't be recognized, and `install.sh`
   falls back to CLI mode rather than guessing at its layout. See
   `docs/architecture.md`'s "basic-memory: CLI mode vs. Docker mode"
   section and `docs/open-items.md` ("Still open" #4).
