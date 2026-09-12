#!/bin/bash
# Point a cmux workspace's `linear` status pill at the Linear PR review page
# for the branch checked out in $CWD, and optionally open that page in a
# browser pane.
#
#   usage: pr-status-worker.sh --workspace <ws> --cwd <path>
#                              [--url <github-pr-url>] [--pane] [--fresh]
#
#     --url    skip the `gh pr view` lookup; use this PR url (from `gh pr create`
#              output, or from the "Confirm PR" gate's question text).
#     --pane   also open the review page in a browser surface, if the workspace
#              has no review tab yet. Off by default: the Stop hook runs on every
#              turn and must not shuffle panes under the reader.
#     --fresh  ignore the cached `gh pr view` answer.
#
# One pill, following the workflow: before a PR exists the pill is the Linear
# issue (cmux-autopilot sets it at launch); while a PR is open it becomes
# "VIN-1760 · PR #2302" pointing at the review page; once that PR merges or
# closes it falls back to the issue.
# Always exits 0: a workspace pill is never worth failing a hook over.
set -uo pipefail
source "$HOME/.claude/cmux/config.sh"

WS=""; CWD=""; PR_URL=""; WANT_PANE=0; FRESH=0
while [ $# -gt 0 ]; do
  case "$1" in
    --workspace) WS="${2:-}"; shift 2 ;;
    --cwd)       CWD="${2:-}"; shift 2 ;;
    --url)       PR_URL="${2:-}"; shift 2 ;;
    --pane)      WANT_PANE=1; shift ;;
    --fresh)     FRESH=1; shift ;;
    *) shift ;;
  esac
done
[ -n "$WS" ] && [ -d "$CWD" ] || exit 0

BRANCH=$(cd "$CWD" && timeout 5 git rev-parse --abbrev-ref HEAD 2>/dev/null)
TICKET=$(ticket_from_branch "$BRANCH")

# --- find the PR for this branch ------------------------------------------
# `gh pr view` is a network round trip and the Stop hook fires on every turn,
# so the answer is cached per cwd for CACHE_TTL seconds. --url callers
# (`gh pr create`, the gate) skip the lookup entirely and refresh the cache.
CACHE_TTL=90
CACHE="$STATE_DIR/pr-$(printf '%s' "$CWD" | shasum | cut -c1-12).json"
STATE=""; NUM=""

if [ -n "$PR_URL" ]; then
  STATE="OPEN"
  NUM=$(printf '%s' "$PR_URL" | grep -oE '[0-9]+$')
  printf '{"url":"%s","state":"OPEN","number":%s}' "$PR_URL" "${NUM:-0}" > "$CACHE" 2>/dev/null
else
  AGE=99999
  if [ -f "$CACHE" ]; then
    AGE=$(( $(date +%s) - $(stat -f %m "$CACHE" 2>/dev/null || echo 0) ))
  fi
  if [ "$FRESH" = "0" ] && [ "$AGE" -lt "$CACHE_TTL" ]; then
    JSON=$(cat "$CACHE" 2>/dev/null)
  else
    JSON=$(cd "$CWD" && timeout 15 gh pr view --json url,number,state 2>/dev/null)
    # An empty answer means "no PR for this branch" — cache that too, so a
    # workspace that will never have a PR does not re-query every 90s.
    [ -n "$JSON" ] || JSON='{}'
    printf '%s' "$JSON" > "$CACHE" 2>/dev/null
  fi
  PR_URL=$(printf '%s' "$JSON" | jq -r '.url // empty' 2>/dev/null)
  STATE=$(printf '%s' "$JSON" | jq -r '.state // empty' 2>/dev/null)
  NUM=$(printf '%s' "$JSON" | jq -r '.number // empty' 2>/dev/null)
fi

# --- no open PR: fall back to the issue, or leave the pill alone ----------
if [ -z "$PR_URL" ] || [ "$STATE" != "OPEN" ]; then
  ISSUE_URL=$(linear_issue_url "$TICKET")
  if [ -n "$ISSUE_URL" ]; then
    timeout 5 "$CMUX_BIN" set-status "$STATUS_KEY" "$TICKET" --url "$ISSUE_URL" \
      --workspace "$WS" >/dev/null 2>&1 \
      && log "pr-status: ws=$WS no open PR (state=${STATE:-none}) -> issue $TICKET"
  fi
  exit 0
fi

REVIEW_URL=$(pr_link_url "$PR_URL")
if [ -z "$REVIEW_URL" ]; then
  log "pr-status: ws=$WS '$PR_URL' is not a GitHub PR url"
  exit 0
fi

# --- the pill -------------------------------------------------------------
LABEL="PR #$NUM"
[ -n "$TICKET" ] && LABEL="$TICKET · PR #$NUM"
if timeout 5 "$CMUX_BIN" set-status "$STATUS_KEY" "$LABEL" --url "$REVIEW_URL" \
     --workspace "$WS" >/dev/null 2>&1; then
  log "pr-status: ws=$WS pill '$LABEL' -> $REVIEW_URL"
else
  log "pr-status: ws=$WS FAILED to set pill '$LABEL'"
fi

[ "$WANT_PANE" = "1" ] || exit 0

# --- the browser pane -----------------------------------------------------
# linear.review/... is a redirect: the tab settles on
# linear.app/<workspace>/review/<title-slug>-<slugId>, which carries neither the
# original url nor the PR number. So an existing review tab is recognised by
# either host form rather than by exact url, and is then left alone — the gate
# can re-fire while you are reading it, and re-navigating would yank the page
# out from under you.
TREE_JSON=$(timeout 8 "$CMUX_BIN" tree --workspace "$WS" --json 2>/dev/null)

EXISTING=$(printf '%s' "$TREE_JSON" | jq -r '
  [ .windows[].workspaces[]?.panes[]?.surfaces[]?
    | select(.type == "browser" and ((.url // "") | test("linear\\.review/|linear\\.app/[^/]+/review/")))
    | .ref ] | first // empty' 2>/dev/null)
if [ -n "$EXISTING" ]; then
  log "pr-status: ws=$WS review tab $EXISTING already open, left as is"
  exit 0
fi

# Prefer adding a tab to a browser pane that is already open (cmux-autopilot
# splits one off for the Linear issue) over splitting a brand new pane.
BROWSER_PANE=$(printf '%s' "$TREE_JSON" | jq -r '
  [ .windows[].workspaces[]?.panes[]?.surfaces[]?
    | select(.type == "browser")
    | .pane_ref ] | first // empty' 2>/dev/null)

if [ -n "$BROWSER_PANE" ]; then
  OUT=$(timeout 8 "$CMUX_BIN" new-surface --type browser --pane "$BROWSER_PANE" \
        --url "$REVIEW_URL" --workspace "$WS" --focus true 2>&1)
else
  OUT=$(timeout 8 "$CMUX_BIN" new-pane --type browser --url "$REVIEW_URL" \
        --workspace "$WS" --focus false 2>&1)
fi
SURFACE=$(printf '%s' "$OUT" | grep -oE 'surface:[0-9]+' | head -1)
if [ -n "$SURFACE" ]; then
  log "pr-status: ws=$WS opened $REVIEW_URL in $SURFACE"
else
  log "pr-status: ws=$WS FAILED to open $REVIEW_URL: $OUT"
fi
exit 0
