#!/bin/bash
# Keeps a cmux workspace's `linear` status pill pointing at the Linear PR review
# page while a PR is open, so finishing a run leaves the review one click away.
# Four triggers, all wired in settings.json:
#   PostToolUse(Bash)            - the agent just ran `gh pr create`; the PR url
#                                  is in the tool response. Opens the pane too.
#   PreToolUse(AskUserQuestion)  - the "Confirm PR ... request human reviewers?"
#                                  gate; covers a PR that predates this session.
#   SessionStart                 - a resumed workspace gets its pill (and pane)
#                                  back without waiting for a PR-shaped event.
#   Stop                         - end of every turn: refresh the pill, so the
#                                  link is right the moment the session is done.
#                                  Pill only — never moves panes.
# Always exits 0 with no stdout, so no tool call is blocked or altered, and the
# work runs detached so no turn ever waits on `gh` or the network.
set -uo pipefail
source "$HOME/.claude/cmux/config.sh"

INPUT=$(cat)
exit_ok() { exit 0; }

WS="${CMUX_WORKSPACE_ID:-}"
[ -n "$WS" ] || exit_ok
# derive-name.sh's haiku child runs with this set; it has no workspace of its own.
[ -z "${CMUX_NAMING_CHILD:-}" ] || exit_ok

EVENT=$(printf '%s' "$INPUT" | jq -r '.hook_event_name // empty' 2>/dev/null)
CWD=$(printf '%s' "$INPUT" | jq -r '.cwd // empty' 2>/dev/null)
[ -d "$CWD" ] || exit_ok

ARGS=(--workspace "$WS" --cwd "$CWD")

case "$EVENT" in
  PostToolUse)
    # Fires on every Bash call, so bail on the command before anything else.
    CMD=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)
    printf '%s' "$CMD" | grep -qE 'gh[[:space:]]+pr[[:space:]]+create' || exit_ok
    # gh prints the PR url on stdout; --web and stderr are covered by scanning
    # the whole response, and by asking gh directly if that finds nothing.
    URL=$(printf '%s' "$INPUT" | jq -r '.tool_response | tostring' 2>/dev/null \
          | grep -oE 'https://github\.com/[^ )>,"\\]+/pull/[0-9]+' | head -1)
    if [ -n "$URL" ]; then ARGS+=(--url "$URL"); else ARGS+=(--fresh); fi
    ARGS+=(--pane)
    ;;
  PreToolUse)
    # The gate: header "Confirm PR", or question text asking for reviewers.
    GATE=$(printf '%s' "$INPUT" | jq -r '
      [ .tool_input.questions[]?
        | select((.header? // "") == "Confirm PR"
                 or ((.question? // "") | test("request human reviewers"; "i")))
        | .question ] | first // empty' 2>/dev/null)
    [ -n "$GATE" ] || exit_ok
    URL=$(printf '%s' "$GATE" \
          | grep -oE 'https://github\.com/[^ )>,]+/pull/[0-9]+' | head -1)
    if [ -n "$URL" ]; then ARGS+=(--url "$URL"); else ARGS+=(--fresh); fi
    ARGS+=(--pane)
    ;;
  SessionStart)
    ARGS+=(--fresh --pane)
    ;;
  Stop)
    # Every turn ends here, so this one rides the 90s cache and never opens a
    # pane: the cost of being wrong is a stale pill for a minute, the cost of
    # being eager is a browser tab jumping while you read.
    :
    ;;
  *) exit_ok ;;
esac

nohup "$HOME/.claude/cmux/pr-status-worker.sh" "${ARGS[@]}" >/dev/null 2>&1 &
exit 0
