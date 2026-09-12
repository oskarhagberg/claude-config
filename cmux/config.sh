#!/bin/bash
# Shared config for the local cmux <-> Claude Code integration.
#
# LAYERING. This file is tracked in git and holds portable defaults plus every
# helper. Machine-specific values live in config.local.sh, which is gitignored
# and sourced over these defaults. Helpers are defined *after* that source, and
# read their variables at call time, so an override reaches them for free.
#
#   ~/.claude/cmux/install.sh      creates config.local.sh interactively
#   ~/.claude/cmux/config.local.example.sh   annotated template
#
# LISTS ARE NEWLINE-SEPARATED STRINGS, NOT ARRAYS. macOS ships bash 3.2, where
# "${arr[@]}" on an empty array under `set -u` aborts the script — and every
# hook here runs `set -uo pipefail`. A string costs one `while read` and cannot
# take a hook down.

# ── defaults: override in config.local.sh, never here ───────────────────────

# Repo roots whose sessions get workspace naming, one per line. Anything beneath
# a listed root counts, so worktrees under <root>/.claude/worktrees/<branch> are
# covered. Empty disables naming everywhere.
MANAGED_REPOS=""

# Ticket prefixes as a bare regex alternation, e.g. '(VIN|CORP)'.
# Empty disables ticket detection: names fall back to a plain slug, pills to
# "PR #123". Deliberately NOT defaulted to something permissive like
# [A-Z]{2,6} — that also matches GAP-16, UTF-8 and PR-2302.
TICKET_RE=""

# Linear workspace slug, for issue urls (https://linear.app/<slug>/issue/vin-1).
# Empty disables issue links. PR review links do NOT need it.
LINEAR_WORKSPACE=""

# Where a PR pill points: 'linear' for the Linear review page, 'github' for the
# pull request itself.
PR_LINK_TARGET="linear"

# cmux status pill key that the PR / issue link is written to.
STATUS_KEY="linear"

# Skills whose invocation triggers workspace naming (regex, case-insensitive).
# Empty means no skill ever triggers naming.
NAMING_SKILLS=""

# 1 = a prompt that merely mentions a ticket also triggers naming. This is what
# carries naming on a machine with no autopilot-style skills.
NAMING_ON_TICKET=1

# Model used to compress an issue title into a ~3 word slug.
SLUG_MODEL="claude-haiku-4-5-20251001"

# ── cmux-agent launcher ─────────────────────────────────────────────────────
AGENT_WORKTREE=1        # `wt switch --create <slug>` before starting claude
AGENT_MODEL=""          # --model;  empty = claude's own default
AGENT_EFFORT=""         # --effort; empty = claude's own default
AGENT_REMOTE_CONTROL=1  # --remote-control <slug>
AGENT_SKILL_DIRS=""     # dirs searched for `cmux-agent /<skill>`, one per line
AGENT_OPEN_ISSUE=1      # open the ticket in a browser split when launching

# Skill that the `cmux-autopilot <TICKET>` shortcut runs. Empty = the shortcut
# refuses rather than guessing.
AUTOPILOT_SKILL=""

# The cmux CLI. cmux puts its bundled binary on PATH only for terminals it
# spawns itself — a plain login shell has no `cmux`, and there is no symlink in
# /usr/local/bin — so resolve the bundle directly rather than requiring PATH.
# Order: an explicit CMUX_BIN, then PATH, then the env var cmux exports, then
# the standard install location.
if [ -z "${CMUX_BIN:-}" ]; then
  if command -v cmux >/dev/null 2>&1; then
    CMUX_BIN="cmux"
  elif [ -x "${CMUX_BUNDLED_CLI_PATH:-}" ]; then
    CMUX_BIN="$CMUX_BUNDLED_CLI_PATH"
  elif [ -x "/Applications/cmux.app/Contents/Resources/bin/cmux" ]; then
    CMUX_BIN="/Applications/cmux.app/Contents/Resources/bin/cmux"
  else
    CMUX_BIN="cmux"   # not found; callers report it
  fi
fi
STATE_DIR="/tmp/claude/cmux-integration"
LOG_FILE="$HOME/.claude/logs/cmux-integration.log"

# ── per-machine overrides ───────────────────────────────────────────────────
CMUX_CONFIG_LOCAL="${CMUX_CONFIG_LOCAL:-$HOME/.claude/cmux/config.local.sh}"
[ -f "$CMUX_CONFIG_LOCAL" ] && . "$CMUX_CONFIG_LOCAL"

[ -n "$AGENT_SKILL_DIRS" ] || AGENT_SKILL_DIRS="$HOME/.claude/skills"

mkdir -p "$STATE_DIR" "$(dirname "$LOG_FILE")" 2>/dev/null

log() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >> "$LOG_FILE" 2>/dev/null; }

# ── repos ───────────────────────────────────────────────────────────────────

# True when $1 is a managed repo root or anything beneath one.
in_managed_repo() {
  local dir="${1:-}" root
  [ -n "$dir" ] || return 1
  while IFS= read -r root; do
    [ -n "$root" ] || continue
    [ "$dir" = "$root" ] && return 0
    case "$dir" in "$root"/*) return 0 ;; esac
  done <<< "$MANAGED_REPOS"
  return 1
}

# ── tickets ─────────────────────────────────────────────────────────────────
# All four degrade to "no ticket" when TICKET_RE is empty, which is what makes
# the package usable on a machine that does not track work in tickets at all.

# First ticket anywhere in $1: "look at vin-1760 please" -> "VIN-1760".
find_ticket() {
  [ -n "$TICKET_RE" ] || return 0
  printf '%s' "${1:-}" | grep -oiE "(^|[^A-Za-z0-9])$TICKET_RE-[0-9]+" | head -1 \
    | grep -oiE "$TICKET_RE-[0-9]+" | tr '[:lower:]' '[:upper:]'
}

# Ticket at the START of a branch name: "vin-1760-financial-baseline" -> "VIN-1760".
ticket_from_branch() {
  [ -n "$TICKET_RE" ] || return 0
  printf '%s' "${1:-}" | grep -oiE "^$TICKET_RE-[0-9]+" | head -1 \
    | tr '[:lower:]' '[:upper:]'
}

# $1 with every ticket removed, for slugging prose that names one.
strip_tickets() {
  if [ -n "$TICKET_RE" ]; then
    printf '%s' "${1:-}" | sed -E "s/($TICKET_RE)-[0-9]+//gi"
  else
    printf '%s' "${1:-}"
  fi
}

# True when a title is already "<TICKET> <text>", i.e. named by hand or by an
# earlier derivation. Such a workspace must never be renamed again.
titled_with_ticket() {
  [ -n "$TICKET_RE" ] || return 1
  printf '%s' "${1:-}" | grep -qiE "^$TICKET_RE-[0-9]+[[:space:]]+[^[:space:]]"
}

# ── urls ────────────────────────────────────────────────────────────────────

# Linear's review page for a GitHub PR url. Linear documents a redirect:
# swapping the host for linear.review resolves to that PR's review page in
# whichever Linear workspace owns the repo, so no Linear API call and no slug id
# is needed — https://linear.app/docs/diffs, "Open GitHub PR URLs in Linear".
#   https://github.com/humlytech/vinga/pull/2302
#   -> https://linear.review/humlytech/vinga/pull/2302
# Never fails: prints nothing for anything that is not a GitHub PR url.
linear_review_url() {
  printf '%s' "${1:-}" \
    | grep -oE '^https://github\.com/[^/]+/[^/]+/pull/[0-9]+$' \
    | sed -E 's#^https://github\.com/#https://linear.review/#'
}

# Where the PR pill should point, per PR_LINK_TARGET.
pr_link_url() {
  case "$PR_LINK_TARGET" in
    github) printf '%s' "${1:-}" \
              | grep -oE '^https://github\.com/[^/]+/[^/]+/pull/[0-9]+$' ;;
    *)      linear_review_url "${1:-}" ;;
  esac
}

# Linear issue url for a ticket ("VIN-1760" -> https://linear.app/humly/issue/vin-1760).
# Lowercased to match the form Linear itself uses. Empty when no workspace is
# configured, which is the signal to leave a pill alone rather than link nowhere.
linear_issue_url() {
  local t
  [ -n "$LINEAR_WORKSPACE" ] || return 0
  t=$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')
  [ -n "$t" ] || return 0
  printf 'https://linear.app/%s/issue/%s' "$LINEAR_WORKSPACE" "$t"
}

# ── misc ────────────────────────────────────────────────────────────────────

# Kebab-case a display string: "VIN-1414 envelope causation scope"
# -> "vin-1414-envelope-causation-scope"
kebab() {
  printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]' \
    | sed -E 's/[^a-z0-9]+/-/g' | sed -E 's/^-+//' | sed -E 's/-+$//' \
    | cut -c1-60
}

# Deliberate (custom) cmux title of workspace $1, empty when it only has the
# auto-derived one. Never fails: prints nothing when cmux or jq cannot answer.
ws_custom_title() {
  local id="${1:-}"
  [ -n "$id" ] || return 0
  "$CMUX_BIN" workspace list --json 2>/dev/null \
    | jq -r --arg id "$id" '
        .workspaces[]?
        | select(((.id // "") | ascii_downcase) == ($id | ascii_downcase))
        | .custom_title // ""' 2>/dev/null \
    | head -1 | sed -E 's/^ +| +$//g'
}

# Workspace handle ("workspace:3", or a UUID) out of a cmux command's output.
# Never positionally cut a handle out: several verbs print more than one field
# (`cmux send` answers "OK surface:5 workspace:3"), and $(...) around a helper
# script captures every line that helper writes, so `cut -f2` silently welds
# fields from different lines into one bogus multi-line handle.
parse_workspace_id() {
  printf '%s\n' "${1:-}" \
    | grep -oiE 'workspace:[0-9]+|[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' \
    | head -1 || true
}
