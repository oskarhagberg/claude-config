#!/bin/bash
# Restore a saved crex (cmux-resurrect) layout once per cmux launch.
#
# Called from ~/.zshrc, which runs in the shell of every terminal cmux spawns:
#
#   [ -x ~/.claude/cmux/crex-autorestore.sh ] && ~/.claude/cmux/crex-autorestore.sh
#
# EXECUTED, NOT SOURCED, on purpose: it needs nothing from the interactive shell
# beyond the environment cmux exports, and sourcing would pull config.sh's whole
# namespace — plus its bash 3.2 idioms — into every zsh prompt.
#
# Off unless CREX_LAYOUT names a layout `crex save` has written. A machine with
# no saved layout restores nothing, rather than resurrecting crex's shipped
# `demo` grid.
set -uo pipefail
# shellcheck disable=SC1091
. "$HOME/.claude/cmux/config.sh"

[ -n "${CMUX_SOCKET_PATH:-}" ] || exit 0     # only inside a cmux terminal
[ -n "$CREX_LAYOUT" ] || exit 0              # feature off
command -v "$CREX_BIN" >/dev/null 2>&1 || {
  log "crex-autorestore: $CREX_BIN not on PATH"; exit 0; }

# 'ask' is crex's default restore mode and opens an interactive picker, which a
# detached job cannot answer. Always pass an explicit mode; anything but the two
# crex accepts becomes 'add', because 'replace' CLOSES live workspaces — agent
# worktrees included — and is not a safe fallback.
case "$CREX_RESTORE_MODE" in add|replace) ;; *) CREX_RESTORE_MODE="add" ;; esac

# Restore only on the launch's first pane. `list-workspaces` still works but is
# now an alias that prints a deprecation notice on stderr — which would land on
# the terminal of every new pane, so use the modern form and count the workspace
# lines rather than every line.
#
# Exactly 1, not "1 or fewer": an unreachable cmux prints nothing, and treating
# that as "first pane" restores a layout into every shell that opens.
COUNT=$("$CMUX_BIN" workspace list 2>/dev/null | grep -c 'workspace:')
[ "$COUNT" = "1" ] || exit 0

# One restore per cmux launch, not per pane. The restore creates workspaces
# whose shells run this script again, and two panes opening together would both
# see a single workspace. mkdir is the atomic test-and-set. The key is the
# socket's birth time, so the next cmux launch takes a fresh lock and an old
# lock is never mistaken for this launch's. A key we cannot read degrades to 0,
# which at worst skips a restore — never duplicates one.
LAUNCH=$(stat -f %B "$CMUX_SOCKET_PATH" 2>/dev/null || echo 0)
mkdir "$STATE_DIR/crex-restored-$LAUNCH" 2>/dev/null || exit 0

# Logged, not discarded: `crex restore --force` was silently rejected as an
# unknown flag on every launch for as long as the /dev/null version existed.
# </dev/null keeps a crex that decides to prompt from stopping on SIGTTIN.
log "crex-autorestore: restoring '$CREX_LAYOUT' --mode $CREX_RESTORE_MODE"
nohup "$CREX_BIN" restore "$CREX_LAYOUT" --mode "$CREX_RESTORE_MODE" \
  >>"$LOG_FILE" 2>&1 </dev/null &
exit 0
