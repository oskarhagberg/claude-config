#!/bin/bash
# UserPromptSubmit hook: rename the current cmux workspace to
# "<TICKET> <3 word slug>" when a prompt looks like real work on a ticket.
#
# Two triggers, either sufficient, both configurable:
#   NAMING_SKILLS     a prompt invoking one of these skills (regex). Empty on a
#                     machine with no such skills.
#   NAMING_ON_TICKET  a prompt merely mentioning a ticket. This is what carries
#                     naming where there are no autopilot-style skills.
# Returns immediately; the slug (linear + haiku, ~15s) is derived detached.
set -uo pipefail
source "$HOME/.claude/cmux/config.sh"

INPUT=$(cat)
exit_ok() { exit 0; }

# Only meaningful inside a cmux terminal.
WS="${CMUX_WORKSPACE_ID:-}"
[ -n "$WS" ] || exit_ok

CWD=$(printf '%s' "$INPUT" | jq -r '.cwd // empty' 2>/dev/null)
PROMPT=$(printf '%s' "$INPUT" | jq -r '.prompt // empty' 2>/dev/null)
SESSION=$(printf '%s' "$INPUT" | jq -r '.session_id // empty' 2>/dev/null)
[ -n "$PROMPT" ] || exit_ok
# Never recurse: derive-name.sh runs `claude -p "Compress this software task …"`
# and that prompt is itself a UserPromptSubmit carrying the skill name. Bail on
# the child marker env and on the prompt shape, so one naming run cannot spawn
# another (this loop produced ~560 nested haiku runs before the guard existed).
[ -z "${CMUX_NAMING_CHILD:-}" ] || exit_ok
case "$PROMPT" in "Compress this software task"*) exit_ok ;; esac
in_managed_repo "$CWD" || exit_ok

# Must match a naming skill, or mention a ticket when that trigger is on.
# Take only the matching line, so a long prose prompt does not become the slug.
LINE=""
if [ -n "$NAMING_SKILLS" ] && printf '%s' "$PROMPT" | grep -qiE "$NAMING_SKILLS"; then
  LINE=$(printf '%s' "$PROMPT" | grep -iE -m1 "$NAMING_SKILLS" | cut -c1-400)
elif [ "$NAMING_ON_TICKET" = "1" ] && [ -n "$TICKET_RE" ] \
     && printf '%s' "$PROMPT" | grep -qiE "$TICKET_RE-[0-9]+"; then
  LINE=$(printf '%s' "$PROMPT" | grep -iE -m1 "$TICKET_RE-[0-9]+" | cut -c1-400)
fi
[ -n "$LINE" ] || exit_ok

# Never rename a workspace that already carries "<TICKET> <text>": that name was
# set deliberately (by an earlier derivation or by hand) and owns the workspace.
CURRENT_TITLE=$(ws_custom_title "$WS")
if titled_with_ticket "$CURRENT_TITLE"; then
  log "name-workspace: ws=$WS keeps existing title '$CURRENT_TITLE'"
  exit_ok
fi

# Dedupe: skip when this workspace was already named from the same invocation.
KEY=$(printf '%s' "$LINE" | shasum | cut -c1-12)
MARKER="$STATE_DIR/ws-${WS}.named"
[ -f "$MARKER" ] && [ "$(cat "$MARKER" 2>/dev/null)" = "$KEY" ] && exit_ok
printf '%s' "$KEY" > "$MARKER"

log "name-workspace: ws=$WS session=$SESSION line='$LINE'"
nohup "$HOME/.claude/cmux/rename-worker.sh" \
  --workspace "$WS" --text "$LINE" --session "$SESSION" >/dev/null 2>&1 &
exit 0
