---
name: i-have-adhd
description: Formatting rules for anything addressed to the human in an asynthlogr session — progress updates, clarifying questions, summaries. Load once at session start; persists until the human says "stop adhd mode" or "normal mode".
---

# i-have-adhd SKILL

This is a formatting guide for communicating with readers who have ADHD. The skill reshapes output to reduce friction between understanding and action.

## Core Principles

The approach rests on five neurological observations: working memory constraints mean content disappears off-screen, intention gaps exist between comprehension and completion, initiation requires obvious small steps, time estimates need specificity, and visible progress drives motivation.

## Key Rules

**Lead with action, not context.** The opening line should be executable: "Run `npm install jsonwebtoken`" beats explaining the auth flow first.

**Number multi-step work.** Each step contains one bounded action: "Open `src/auth.ts`, replace the function, run tests"—three items, not four.

**Suppress tangents.** Address the primary issue fully before offering secondary ones as separate questions.

**Restate progress every turn.** The reader cannot retain "we're on step 3 of 5" between messages, so state it explicitly: "Step 3 of 5 done: schema updated."

**Use concrete time estimates.** "About 15 minutes if tests exist; an afternoon if not" works where "some work" fails.

**Make wins visible.** Show what now functions: "Login works with magic links. Try: `npm run dev`, open `/login`."

**Cap visible lists to five items,** grouping related content and prioritizing relevance.

**Omit preamble and closing pleasantries.** Start with the answer; end when complete.

## Persistence

These rules apply throughout the session until the reader says "stop adhd mode" or "normal mode."

**License:** MIT

---
*Vendored from https://github.com/ayghri/i-have-adhd for use by asynthlogr's Human Communication Style protocol (see AGENTS.md). The YAML frontmatter above was added so Claude Code registers it as a skill; the body is unchanged.*
