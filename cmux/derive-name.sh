#!/bin/bash
# Derive a cmux workspace name from a skill invocation or a freeform prompt.
#   usage: derive-name.sh [--raw] "<skill args | prompt>"
#     --raw  the text is a freeform prompt, not "/skill args", so do not strip
#            a leading command token off it.
#   prints: "VIN-1234 three word slug"  (or just the slug when no ticket)
# Never fails: on any error it degrades to the ticket alone, then to nothing.
set -uo pipefail
source "$HOME/.claude/cmux/config.sh"

STRIP_CMD=1
if [ "${1:-}" = "--raw" ]; then STRIP_CMD=0; shift; fi

TEXT="${1:-}"
[ -n "$TEXT" ] || exit 0

# --- ticket ---------------------------------------------------------------
TICKET=$(find_ticket "$TEXT")

# --- source text for the slug --------------------------------------------
TITLE=""
if [ -n "$TICKET" ] && command -v linear >/dev/null 2>&1; then
  # `linear issue view` prints "# VIN-1234: <title>" as its first heading.
  # Skipped entirely when the CLI is absent, which is the normal state on a
  # machine that does not track work in Linear.
  TITLE=$(timeout 20 linear issue view "$TICKET" 2>/dev/null \
          | grep -m1 '^# ' | sed -E 's/^# ([A-Z]+-[0-9]+: )?//')
fi
if [ -z "$TITLE" ]; then
  # No ticket, or no Linear issue behind it: describe from the text itself.
  TITLE=$(strip_tickets "$TEXT")
  [ "$STRIP_CMD" = "1" ] && TITLE=$(printf '%s' "$TITLE" | sed -E 's#^/?[a-z0-9-]+ ##')
  TITLE=$(printf '%s' "$TITLE" | tr -s ' ' | cut -c1-300)
fi
TITLE=$(printf '%s' "$TITLE" | tr -d '\r' | sed -E 's/^ +| +$//g')

if [ -z "$TITLE" ]; then
  [ -n "$TICKET" ] && printf '%s\n' "$TICKET"
  exit 0
fi

# --- compress to ~3 words ------------------------------------------------
# CMUX_WORKSPACE_ID is blanked and CMUX_NAMING_CHILD set so the cmux hooks
# (hook-name-workspace.sh, hook-pr-pane.sh) treat this child as not-a-workspace
# and do not re-enter the naming flow from its own prompt.
SLUG=$(CLAUDECODE= CLAUDE_CODE_ENTRYPOINT= CMUX_WORKSPACE_ID= CMUX_NAMING_CHILD=1 timeout 25 claude -p \
  "Compress this software task into exactly 3 lowercase words naming the thing being worked on. No punctuation, no quotes, no filler words like 'fix' or 'add', no explanation. Output only the 3 words.

Task: $TITLE" \
  --model "$SLUG_MODEL" 2>/dev/null \
  | tr -d '\r' | head -1 \
  | tr '[:upper:]' '[:lower:]' \
  | sed -E 's/[^a-z0-9 -]//g' | tr -s ' ' | sed -E 's/^ +| +$//g' \
  | cut -c1-40)

# Reject junk (empty, or the model returning a sentence).
WORDS=$(printf '%s' "$SLUG" | wc -w | tr -d ' ')
if [ -z "$SLUG" ] || [ "$WORDS" -gt 5 ]; then
  log "derive-name: slug rejected (words=$WORDS) for '$TITLE'"
  SLUG=""
fi

if [ -n "$TICKET" ] && [ -n "$SLUG" ]; then printf '%s %s\n' "$TICKET" "$SLUG"
elif [ -n "$TICKET" ];                 then printf '%s\n' "$TICKET"
elif [ -n "$SLUG" ];                   then printf '%s\n' "$SLUG"
fi
