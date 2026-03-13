# Claude Code Team Setup

This guide explains how to manage your personal Claude Code environment as a git repo, stay in sync with the team's shared skills, and understand how configuration layers interact.

---

## Overview

Claude Code reads configuration, skills from `~/.claude/` (global) and from `.claude/` inside any project you open. By turning `~/.claude/` into a git repository, your entire Claude environment becomes versioned, reproducible, and easy to sync.

We maintain a shared team repo with common skills. You connect it as a second remote and pull from it selectively — no forking, no manual copying.

---

## Initial Setup

### 1. Initialise your personal repo

```bash
cd ~/.claude
# Add a .gitignore file described below
git init
git add .
git commit -m "chore: initial claude environment"
```

Create a repo on GitHub (e.g. `your-name/claude-config`) and push:

```bash
git remote add origin git@github.com:your-name/claude-config.git
git push -u origin main
```

### 2. Connect the team remote

```bash
git remote add team git@github.com:humly/claude-skills.git
git fetch team
```

To pull in team skills for the first time:

```bash
git merge team/main --allow-unrelated-histories
```

After that, picking up new team skills is just:

```bash
git fetch team
git checkout team/main -- skills/some-new-skill/
git checkout team/main -- commands/some-new-command.md
git commit -m "chore: add team skill some-new-skill"
```

You decide what you adopt and when. Nothing syncs automatically.

---

## Folder Structure

```
~/.claude/
├── CLAUDE.md                    # Your global instructions (all projects)
├── settings.json                # Global config (committed)
├── settings.local.json          # Personal secrets — gitignored
│
├── skills/                      # Flat list — one directory per skill
│   ├── address-review/
│   │   └── SKILL.md
│   ├── code-review/
│   │   └── SKILL.md
│   └── get-api-docs/
│       └── SKILL.md
│
└── skills-disabled/             # Skills parked outside the scanned directory
    └── experimental-skill/
        └── SKILL.md
```

> **Critical:** `skills/` must stay flat. Claude Code only scans one level deep and treats subdirectories as plugin namespaces, causing duplicate namespaced entries like `personal:skill-name` alongside the real ones. Never create subdirectories inside `skills/`.

> **On commands:** The `commands/` folder is supported for legacy compatibility — it predates skills. For all new work, use skills instead. A skill invoked only by the user (see Naming Conventions below) is functionally identical to a command, but you gain the ability to add supporting files and auto-invocation later if needed.

---

## Naming Conventions

Consistent naming keeps the flat structure readable and avoids collisions between personal and team skills.

### Skills

- Directory name: `kebab-case`, descriptive verb-noun where possible
- Must match the `name` field in frontmatter exactly
- Examples: `address-review`, `get-api-docs`, `seed-test-data`

Each skill directory contains a `SKILL.md` with frontmatter:

```markdown
---
name: address-review
description: Reviews open PR comments and implements fixes. Use when resolving review feedback on a pull request.
---

# Instructions
...
```

- `name` — must match the directory name exactly. This becomes the `/slash-command`.
- `description` — one sharp sentence. This is what Claude reads to decide whether to auto-invoke the skill. Write it as: *what it does + when to use it*.

By default, Claude may auto-invoke a skill when it judges the description matches the current task. If you want a skill that only runs when you explicitly call `/skill-name`, add `invocation: user` to the frontmatter:

```markdown
---
name: seed-test-data
description: Seeds the local database with test fixtures.
invocation: user
---

# Instructions
...
```

Use `invocation: user` for anything destructive, slow, or that should only run on explicit intent — deployments, database operations, code generation scaffolds.

### General rules

- If two skills would have the same name, the names are too generic — make them more specific
- Disabled skills live in `skills-disabled/`, preserving their original name

---

## Toggling a Skill On/Off

Skills are disabled by moving them to `skills-disabled/` — a sibling directory that sits outside the path Claude scans. The folder name `disabled` inside `skills/` would have no effect; Claude doesn't understand naming conventions, only directory boundaries.

```bash
# Disable
mv ~/.claude/skills/some-skill ~/.claude/skills-disabled/
git add -A && git commit -m "chore: disable some-skill"

# Re-enable
mv ~/.claude/skills-disabled/some-skill ~/.claude/skills/
git add -A && git commit -m "chore: re-enable some-skill"
```

---

## .gitignore

```gitignore
# Session & conversation history (can grow to 1.5 GB+)
projects/
history.jsonl

# Runtime / cache
plugins/cache/
statsig/
local/

# Per-session state (ephemeral)
shell-snapshots/
session-env/
plans/

# Debug & telemetry
debug/
telemetry/

# File edit snapshots
file-history/

# Personal secrets — never commit
settings.local.json
```

---

## Project-Level `.claude/` Setup

Each repository can have its own `.claude/` folder committed to version control. This is how you share Claude context with the team without anyone needing to configure anything manually — it just works when they open the project.

### Recommended structure

```
your-repo/
└── .claude/
    ├── CLAUDE.md               # Project instructions — committed, shared
    ├── CLAUDE.local.md         # Personal overrides — gitignored
    ├── settings.json           # Project permissions & tool config — committed
    ├── settings.local.json     # Personal settings — gitignored
    └── skills/
        └── some-skill/
            └── SKILL.md
```

The same flat structure and naming conventions apply here. Project-level skills are available to everyone who opens the repo — no setup required.

### What to commit

**`CLAUDE.md`** — the most important file. Include things Claude can't infer from the code itself:

- What this service does and where it fits in the system
- How to run, test, and build locally
- Conventions the team has agreed on (naming, patterns, error handling)
- What to avoid (common mistakes, deprecated approaches)
- Links to relevant ADRs or docs

Keep it under ~100 lines. Beyond that, context window costs outweigh the benefits — use subdirectory CLAUDE.md files for deeper specifics.

**`settings.json`** — project-level permissions scoped to this repo:

```json
{
  "permissions": {
    "allow": [
      "Bash(npm run test:*)",
      "Bash(npm run lint)"
    ],
    "deny": [
      "Read(.env)",
      "Read(.env.*)"
    ]
  }
}
```

**Skills and commands** — anything workflow-specific to this repo: a deploy command, a migration helper, a code review skill tailored to your stack.

### What to gitignore

Add this to the repo's `.gitignore`:

```gitignore
.claude/CLAUDE.local.md
.claude/settings.local.json
```

---

## How Configuration Layers Work

Claude Code merges configuration from multiple locations. Understanding the priority order helps you know where to put things and what wins when there's a conflict.

### CLAUDE.md — all layers loaded, most specific wins

Every CLAUDE.md in the chain is loaded and concatenated into context at session start. They don't replace each other — you get all of them. When instructions conflict, the most specific file wins.

Load order, from lowest to highest priority:

| Priority | Location | When loaded | Use it for |
|---|---|---|---|
| 1 (lowest) | `~/.claude/CLAUDE.md` | Always, every project | Personal preferences: language, commit style, general coding standards |
| 2 | `~/project/CLAUDE.md` | When opening this project | Team conventions: architecture notes, repo-specific commands, stack context |
| 3 | `~/project/CLAUDE.local.md` | When opening this project | Personal overrides for this repo — gitignored, not shared |
| 4 (highest) | `~/project/src/CLAUDE.md` | When Claude navigates into that directory | Subdirectory-specific rules: testing conventions, component patterns, DB constraints |

The subdirectory loading is lazy — a `src/db/CLAUDE.md` only enters context when Claude actually works in that directory. This keeps the context window lean.

**Practical split:**
- Global: things that are always true about how *you* work
- Project root: things that are always true about *this repo* — commit this
- `CLAUDE.local.md`: your personal tweaks to the project that the team doesn't need
- Subdirectory: rules specific to one layer of the codebase

### Skills and Commands — both loaded, project overrides on name collision

Global skills (`~/.claude/skills/`) and project skills (`.claude/skills/`) are both available in any session. They form a merged registry. When a global and project skill share the same name, the project-level skill wins.

Full precedence: **enterprise > personal (global) > project**

One known caveat: sub-agents spawned via the Task tool currently load global skills only, ignoring project-level overrides. This is a reported bug. If you rely on project-specific skills in agent workflows, test this in your setup.

For commands: same rules apply. If a skill and a command share the same name, the skill takes precedence.
