#!/bin/bash
# Per-machine config for the cmux <-> Claude Code integration.
#
# This file is GITIGNORED. config.sh holds the defaults and every helper and is
# tracked; this file states only what differs on this machine. Run install.sh to
# generate it interactively, or copy it by hand:
#
#   cp config.local.example.sh config.local.sh && $EDITOR config.local.sh
#
# Lists are newline-separated strings, not arrays — macOS bash 3.2 aborts on an
# empty array under `set -u`, and every hook runs `set -u`.

# ── repos ───────────────────────────────────────────────────────────────────
# Repo roots whose sessions get workspace naming, one per line. Anything beneath
# a root counts, so worktrees under <root>/.claude/worktrees/<branch> are
# covered. Leave empty to disable naming on this machine.
MANAGED_REPOS="$HOME/code/your-repo"

# ── tickets ─────────────────────────────────────────────────────────────────
# Your issue-key prefixes as a regex alternation. Leave EMPTY if you do not
# track work in tickets: names then fall back to a plain slug and PR pills to
# "PR #123".
#
# Do not be tempted by something permissive like '[A-Z]{2,6}' — it also matches
# GAP-16, UTF-8 and PR-2302, and you will get workspaces named after a typo.
TICKET_RE='(ABC|DEF)'

# ── linear ──────────────────────────────────────────────────────────────────
# Workspace slug from your Linear urls: https://linear.app/<slug>/issue/abc-1.
# Leave empty if you do not use Linear — PR review links do not need it, only
# the issue-link fallback does.
LINEAR_WORKSPACE=""

# Where a PR status pill points: 'linear' for the Linear review page (needs the
# Linear GitHub integration), 'github' for the pull request itself.
PR_LINK_TARGET="github"

# cmux status pill key the PR / issue link is written to. Change it only if it
# collides with a pill something else on this machine sets.
STATUS_KEY="linear"

# ── naming ──────────────────────────────────────────────────────────────────
# Skills whose invocation renames the workspace (regex, case-insensitive).
# Leave empty when this machine has no such skills.
NAMING_SKILLS=''

# 1 = a prompt that merely mentions a ticket also renames the workspace. This is
# what carries naming where there are no autopilot-style skills.
NAMING_ON_TICKET=1

# Model that compresses an issue title into a ~3 word slug.
SLUG_MODEL="claude-haiku-4-5-20251001"

# ── cmux-agent launcher ─────────────────────────────────────────────────────
# 1 = run `wt switch --create <slug>` so each agent gets its own git worktree.
# Needs worktrunk (`brew install worktrunk`); install.sh offers to install it.
AGENT_WORKTREE=0

AGENT_MODEL=""          # --model  passed to claude; empty = claude's default
AGENT_EFFORT=""         # --effort passed to claude; empty = claude's default
AGENT_REMOTE_CONTROL=1  # --remote-control <slug>, so you can SendMessage it
AGENT_OPEN_ISSUE=1      # open the ticket in a browser split at launch
                        # (no effect without LINEAR_WORKSPACE + TICKET_RE)

# Directories searched for `cmux-agent /<skill> args`, one per line.
AGENT_SKILL_DIRS="$HOME/.claude/skills"

# Skill that the `cmux-autopilot <TICKET>` shortcut runs. Leave empty on a
# machine that has no such skill — the shortcut then refuses rather than guessing.
AUTOPILOT_SKILL=""
