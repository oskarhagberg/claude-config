#!/bin/bash
# Detached worker: derive a name, then apply it to BOTH the cmux workspace title
# and the Claude Code session's display name (kebab-cased). Never blocks a prompt.
#
#   usage: rename-worker.sh --workspace <ws> --text <text> [--raw]
#                           [--session <id> | --find-cwd <path> --after <epoch_ms>]
set -uo pipefail
source "$HOME/.claude/cmux/config.sh"

WS=""; TEXT=""; RAW=0; SESSION=""; FIND_CWD=""; AFTER=""
while [ $# -gt 0 ]; do
  case "$1" in
    --workspace) WS="${2:-}"; shift 2 ;;
    --text)      TEXT="${2:-}"; shift 2 ;;
    --raw)       RAW=1; shift ;;
    --session)   SESSION="${2:-}"; shift 2 ;;
    --find-cwd)  FIND_CWD="${2:-}"; shift 2 ;;
    --after)     AFTER="${2:-}"; shift 2 ;;
    *) shift ;;
  esac
done
[ -n "$WS" ] && [ -n "$TEXT" ] || exit 0

if [ "$RAW" = "1" ]; then
  NAME=$("$HOME/.claude/cmux/derive-name.sh" --raw "$TEXT" 2>/dev/null)
else
  NAME=$("$HOME/.claude/cmux/derive-name.sh" "$TEXT" 2>/dev/null)
fi
if [ -z "$NAME" ]; then log "rename-worker: no name derived for '$TEXT'"; exit 0; fi

# 1. cmux workspace title (human readable)
if "$CMUX_BIN" workspace rename "$WS" --title "$NAME" >/dev/null 2>&1; then
  log "rename-worker: ws=$WS -> '$NAME'"
else
  log "rename-worker: FAILED ws=$WS -> '$NAME'"
fi

# 2. Claude Code session display name (kebab identifier)
AGENT_NAME=$(kebab "$NAME")
if [ -n "$AGENT_NAME" ]; then
  if [ -n "$SESSION" ]; then
    "$HOME/.claude/cmux/set-agent-name.sh" --name "$AGENT_NAME" --session "$SESSION"
  elif [ -n "$FIND_CWD" ]; then
    "$HOME/.claude/cmux/set-agent-name.sh" --name "$AGENT_NAME" \
      --cwd "$FIND_CWD" --after "${AFTER:-0}"
  fi
fi
