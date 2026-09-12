#!/bin/bash
# Set a running Claude Code session's display name (the kebab identifier shown
# in ListAgents / SendMessage / the /resume picker).
#
#   usage: set-agent-name.sh --name <kebab> --session <session-id>
#          set-agent-name.sh --name <kebab> --cwd <path> --after <epoch_ms> [--timeout <s>]
#
# `claude --name` is launch-only and there is no runtime rename command, so this
# writes the session's own state file (~/.claude/sessions/<pid>.json). Verified:
# the owning process preserves an edited name across its status rewrites, and the
# new name shows up as the addressable peer name. The in-session prompt box keeps
# its original label until the session restarts (that UI is in-memory).
set -uo pipefail
source "$HOME/.claude/cmux/config.sh"

NAME=""; SESSION=""; FIND_CWD=""; AFTER=""; TIMEOUT=45
while [ $# -gt 0 ]; do
  case "$1" in
    --name)    NAME="${2:-}"; shift 2 ;;
    --session) SESSION="${2:-}"; shift 2 ;;
    --cwd)     FIND_CWD="${2:-}"; shift 2 ;;
    --after)   AFTER="${2:-}"; shift 2 ;;
    --timeout) TIMEOUT="${2:-45}"; shift 2 ;;
    *) shift ;;
  esac
done

[ -n "$NAME" ] || { log "set-agent-name: no --name given"; exit 0; }
[ -n "$SESSION" ] || [ -n "$FIND_CWD" ] || { log "set-agent-name: no target"; exit 0; }

SESS_DIR="$HOME/.claude/sessions"
[ -d "$SESS_DIR" ] || { log "set-agent-name: no $SESS_DIR"; exit 0; }

python3 - "$SESS_DIR" "$NAME" "$SESSION" "$FIND_CWD" "$AFTER" "$TIMEOUT" <<'PY'
import json, os, sys, time, glob
sess_dir, name, session, find_cwd, after, timeout = sys.argv[1:7]
after = int(after) if after.strip() else 0
deadline = time.time() + float(timeout)

def load(p):
    try:
        with open(p) as f: return json.load(f)
    except Exception: return None

def pick():
    best = None
    for p in glob.glob(os.path.join(sess_dir, "*.json")):
        d = load(p)
        if not d: continue
        if session:
            if d.get("sessionId") == session: return p, d
            continue
        # Resolve by cwd: newest session rooted there that started after `after`.
        cwd = d.get("cwd") or ""
        if os.path.realpath(cwd) != os.path.realpath(find_cwd): continue
        if int(d.get("startedAt") or 0) < after: continue
        if best is None or int(d.get("startedAt") or 0) > int(best[1].get("startedAt") or 0):
            best = (p, d)
    return best if best else (None, None)

path = doc = None
while True:
    path, doc = pick()
    if path or time.time() > deadline: break
    time.sleep(1.5)

if not path:
    print("MISS", file=sys.stderr); sys.exit(3)
if doc.get("name") == name:
    print("ALREADY " + path); sys.exit(0)

doc["name"] = name
doc["nameSource"] = "explicit"
tmp = path + ".tmp"
with open(tmp, "w") as f: json.dump(doc, f)
os.replace(tmp, path)
print("OK %s (was %s)" % (path, doc.get("name")))
PY
RC=$?
if [ "$RC" = "0" ]; then log "set-agent-name: '$NAME' (session=${SESSION:-cwd:$FIND_CWD})"
else log "set-agent-name: FAILED rc=$RC name='$NAME' session='$SESSION' cwd='$FIND_CWD'"; fi
exit 0
