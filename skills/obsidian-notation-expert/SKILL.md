---
name: obsidian-notation-expert
description: Use before writing or editing ANY file that lives in the basic-memory vault (thread.md entries, agent-use-tracking.md, subagent output.md) — ensures the markdown uses syntax Obsidian actually renders correctly, not just generic markdown.
---

# obsidian-notation-expert

Obsidian renders a specific flavor of markdown. Generic markdown mostly works, but several things asynthlogr relies on (callouts, tags, math, table cells containing links) have exact syntax requirements. Get these wrong and the note either renders as broken/literal text, or silently fails to do the thing it was meant to do (e.g. a malformed tag doesn't register as a tag at all).

## Headings & basic text
- `# H1` through `###### H6` — standard.
- Bold: `**text**`, Italic: `*text*`, Bold+Italic: `***text***`, Strikethrough: `~~text~~`, Highlight: `==text==`.
- Line break within a paragraph: two trailing spaces before Enter, or Shift+Enter — a single Enter is not enough to force a visible break.

## Lists
- Unordered: `-`, `*`, or `+`. Ordered: `1.` or `1)`.
- Task lists: `- [ ]` / `- [x]`.
- Nest by indenting with spaces or a tab — inconsistent indentation breaks nesting.

## Callouts — use these instead of plain bold labels for structured sections
Syntax: `> [!type] Optional Title`, then quoted content on following `>` lines.

Supported types (case-insensitive), with aliases:
- `note` (default)
- `abstract` / `summary` / `tldr`
- `info`
- `todo`
- `tip` / `hint` / `important`
- `success` / `check` / `done`
- `question` / `help` / `faq`
- `warning` / `caution` / `attention`
- `failure` / `fail` / `missing`
- `danger` / `error`
- `bug`
- `example`
- `quote` / `cite`

Foldable: append `+` (expanded) or `-` (collapsed) to the type: `> [!question]- Open Questions`.
Nest by adding an extra `>` per level.

**Recommended mapping for asynthlogr entries** (apply when writing decision/info entries): render "Open questions" as `> [!question]`, "Rationale" as `> [!info]`, discarded options as `> [!failure]`, chosen option as `> [!success]`. This is a rendering improvement, not a schema change — the underlying section names and content stay as specified elsewhere; only the wrapping syntax changes from a plain `###` heading to a callout, where doing so materially improves readability in Obsidian's rendered view.

## Code
- Inline: `` `code` ``
- Block: triple backticks, with a language tag for syntax highlighting: ` ```bash `.

## Tables
```
| First name | Last name |
| :--------- | --------: |
| Max        | Planck    |
```
`:--` left, `:--:` center, `--:` right align. Basic formatting works inside cells. If a cell needs a link with an alias or a resized image, escape the pipe: `[[Note\|Alias]]` or `![[img.jpg\|200]]` — an unescaped `|` inside a cell breaks the column count.

## Math
- Inline: `$e^{2i\pi} = 1$`
- Block: `$$ ... $$` (or bare `$` on its own delimiting lines) for multi-line expressions.

## Diagrams
Mermaid via a fenced ` ```mermaid ` code block — useful for rendering a decision's option-space or a thread's step flow visually when that's clearer than prose.

## Tags
- `#tagname` inline, or as a YAML frontmatter list: `tags: [decision, auth]`.
- Allowed characters: letters, numbers, `_`, `-`, `/` (for hierarchy, e.g. `#repo/auth-token-refresh`), and common Unicode/emoji. **No spaces** — use kebab-case. Must contain at least one non-numeric character (`#1984` is invalid, `#y1984` isn't).
- Case-insensitive; nested tags (`#inbox/to-read`) are matched by searching the parent (`#inbox`).

## Escaping
Prefix with `\` to show a special character literally: `\*`, `\_`, `\#`, `` \` ``, `\|`, `\~`. A literal numbered-list-looking line needs `1\.` to avoid being parsed as a list item.

## Horizontal rules
`---`, `***`, or `___` — any of the three, consistently within one repo is fine.

## Applies to every asynthlogr writer
`decision-logger`, and any subagent maintaining its own `agent-use-tracking.md`, must load this skill before writing/appending vault content and verify the rendered syntax matches what's specified here — not just what looks plausible as generic markdown.
