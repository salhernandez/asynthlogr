# Decision & info entry format

Written into `<thread>.md` by `decision-logger`, appended chronologically,
mixed types in one file. Both formats follow
`skills/obsidian-notation-expert/` (rendering) and
`skills/obsidian-node-link-expert/` (linking) — note the "Related
subagent runs" section uses a wikilink, while "Files" uses standard
markdown links, since those point outside the vault.

`decision-logger` appends each entry to the thread note with
`edit_note(identifier: <thread_note>, operation: "append", ...,
project: "asynthlogr")`. The orchestrator creates that note at session
start, so the logger never has to create it.

## Decision entry

```markdown
## <timestamp> — <one-line decision summary>

**Type:** Decision
**Trigger:** solution-proposed
**Decision-maker:** agent-suggested, user-approved
**Agent:** orchestrator (main)
**Model (self-reported):** claude-sonnet-5 *(unverified)*

### Context
<context text>

### Options considered
- **Option A** — chosen. <why>
- **Option B** — discarded. <why>

### Decision
<decision text>

### Rationale
<rationale text>

### Tools used
`Grep`, `Read`, `git log`

### Q&A
- **Q:** <question>
  **A:** <answer>

### Open questions
- <item>

### Related subagent runs
- [[repo-1/auth-token-refresh/subagents/2026-09-26T11-14-51_research-agent-rate-limit-handling/output|research-agent — 11:14:51]]

### Files
- [auth/token.ts:42](cursor://file/...) · [VS Code](vscode://file/...) · [GitHub](https://github.com/.../blob/<sha>/auth/token.ts#L42)

**Commit:** `<sha>` · **PR:** [#123](<url>)

---
```

## Info entry

```markdown
## <timestamp> — <one-line summary>

**Type:** Info
**Trigger:** manual
**Agent:** orchestrator (main)
**Model (self-reported):** claude-sonnet-5 *(unverified)*

### Content
<freeform content text>

### Tools used
`WebSearch`, `Read`

### Files
- [config/settings.yml:10](cursor://file/...) · [VS Code](vscode://file/...) · [GitHub](...)

---
```

## Optional callout rendering

Per `skills/obsidian-notation-expert/`, `decision-logger` may render
"Open questions" as `> [!question]`, "Rationale" as `> [!info]`,
discarded options as `> [!failure]`, and the chosen option as
`> [!success]`, in place of the plain `###` headers shown above, where
doing so materially improves readability. This is a rendering choice,
not a schema change — section content and meaning stay as specified.
