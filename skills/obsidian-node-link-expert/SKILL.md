---
name: obsidian-node-link-expert
description: Use before writing or editing ANY file that lives in the basic-memory vault, whenever it references another note in that same vault — ensures notes are linked with real Obsidian wikilinks so they appear connected in Graph View, not just as plain text or broken paths.
---

# obsidian-node-link-expert

Obsidian's graph view draws an edge between two notes only when one contains a real wikilink to the other. A standard markdown link (`[text](path/to/file.md)`) opens the file fine inside Obsidian, but it is **not** tracked as a link for graph/backlink purposes. Getting this distinction right is the entire point of this skill.

## The one rule that matters
- **Note-to-note references (inside the vault): always `[[wikilink]]` syntax.**
- **References to anything outside the vault (source code files, GitHub, external URLs): always standard markdown `[text](url)` syntax.** These are not notes, cannot be wikilinked, and should not be — Obsidian has nothing to resolve them against.

Getting these swapped is the most common mistake: writing a plain markdown link between two vault notes silently produces a note with zero graph connections (an "orphan" in the graph), even though a human reading the raw text sees what looks like a working link.

## Wikilink syntax
- Basic: `[[Note name]]` — resolves by filename, vault-wide, no need for the full path if the name is unique.
- Full path (safer when names might collide across repos/threads): `[[repo-1/auth-token-refresh/auth-token-refresh]]`.
- Custom display text: `[[Note name|Display text]]`.
- Link to a heading within a note: `[[Note name#Heading]]`; a heading in the current note: `[[#Heading]]`; nested headings: `[[Note#Heading#Subheading]]`.
- Link to a specific block: give the block an identifier (`^block-id` at the end of the line/paragraph) and link with `[[Note#^block-id]]`.
- Embed instead of link (pulls the content inline): prefix with `!` — `![[Note name]]`, `![[Note#Heading]]`, `![[Note#^block-id]]`.
- Escape a pipe inside a table cell: `[[Note\|Alias]]`.

## Where this applies inside asynthlogr's vault structure

Every one of these is a note-to-note reference and MUST be a wikilink:
- A decision/info entry in `<thread>.md` linking to a supporting subagent run: use `[[subagents/<run>/output|<subagent-name> — <time>]]`, not a markdown relative link.
- A subagent's `output.md` linking back to its parent thread: `[[../../<thread-name>|<thread-name>]]`.
- Cross-references between two decision entries in the same or different threads (e.g. "this reverses an earlier decision"): `[[<thread-name>#<heading of the earlier entry>]]`.
- Any reference from a repo-level note to its threads, or from `reports/<date>.md` to the threads it summarizes.

Every one of these stays a standard markdown link, never a wikilink:
- Cursor: `[label](cursor://file/...)`, VS Code: `[label](vscode://file/...)`, GitHub: `[label](https://github.com/...)` — these point at source code and external web pages, not vault notes.

## Avoiding orphan notes
A note with zero incoming or outgoing wikilinks is invisible in the graph as anything but an isolated dot. Before finishing any write:
- Confirm the note links to at least one other vault note where a real relationship exists (a decision → its supporting runs, a run → its parent thread).
- Prefer linking "up" to the parent thread from every subagent-run note, even if nothing else references it — this guarantees no run note is ever a true orphan.
- Do not manufacture a link that isn't a real relationship just to avoid an orphan — an accurate sparse graph is more useful than a padded, misleading one.

## Applies to every asynthlogr writer
`decision-logger` (all three entry types it writes), and any subagent maintaining its own `agent-use-tracking.md` when that file references another vault note, must load this skill before writing and convert any note-to-note reference to wikilink syntax before the write goes out.
