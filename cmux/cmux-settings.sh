#!/bin/bash
# Carry cmux's own GUI settings between machines.
#
#   cmux-settings.sh export   # live prefs  -> cmux-settings.json  (tracked)
#   cmux-settings.sh import   # that file   -> live prefs
#   cmux-settings.sh diff     # what import would change
#
# WHY NOT ~/.config/cmux/cmux.json? Because it is not where your settings are.
# cmux writes what you set in its GUI to the macOS preferences domain
# com.cmuxterm.app; cmux.json is an opt-in override file that ships as an
# all-commented-out template, and it does not expose every key the GUI does
# (sidebarPreset, sidebarMaterial, rightSidebar.mode and the fileExplorer keys
# have no cmux.json equivalent). Exporting the domain captures what you actually
# configured. Set anything in cmux.json by hand and it still wins over this —
# the two do not fight, cmux.json is simply higher precedence.
#
# WHY AN ALLOWLIST, NOT A DUMP. That same domain also holds this machine's
# identity: auth tokens (cmux.auth.*), iroh device and broker credentials
# (cmux.iroh.*, mobileHost.deviceID), browser profile ids, telemetry counters
# and window geometry. Copying those to a second laptop is at best useless and
# at worst forks your device identity. So keys are named explicitly below and
# nothing else is ever read — a key cmux adds in a future release cannot leak
# into the export by accident.
set -uo pipefail
source "$HOME/.claude/cmux/config.sh"

DOMAIN="com.cmuxterm.app"
STORE="${CMUX_SETTINGS_FILE:-$HOME/.claude/cmux/cmux-settings.json}"

# Portable preferences, one per line. Everything absent from this list stays on
# the machine it was set on.
ALLOWLIST='
appIconMode
appearanceMode
cmuxDisableBundleIconPersistence
fileExplorer.isVisible
fileExplorer.width
newWorkspacePlacement
notificationPaneFlashEnabled
preferredEditorCommand
rightSidebar.mode
sidebarAppearanceDefaultsVersion
sidebarBlendMode
sidebarBlurOpacity
sidebarBranchDirectoryStacked
sidebarBranchVerticalLayout
sidebarCornerRadius
sidebarHideAllDetails
sidebarMakePullRequestClickable
sidebarMatchTerminalBackground
sidebarMaterial
sidebarNotificationMessageLineLimit
sidebarPathLastSegmentOnly
sidebarPreset
sidebarShowBranchDirectory
sidebarShowLog
sidebarShowPorts
sidebarShowProgress
sidebarShowPullRequest
sidebarShowSSH
sidebarShowWorkspaceDescription
sidebarState
sidebarTintHex
sidebarTintOpacity
sidebarWatchGitStatus
sidebarWrapWorkspaceTitles
terminal.copyOnSelect
workspaceAutoReorderOnNotification
workspacePresentationMode
'
# sidebarAppearanceDefaultsVersion is a migration marker, not identity: carrying
# it stops cmux re-applying its stock sidebar appearance over what we imported.

cmux_running() { pgrep -x cmux >/dev/null 2>&1; }

# Read one key as {type,value}; prints nothing when the key is unset.
read_key() {
  local k="$1" t v
  t=$(defaults read-type "$DOMAIN" "$k" 2>/dev/null | sed -E 's/^Type is //') || return 0
  [ -n "$t" ] || return 0
  v=$(defaults read "$DOMAIN" "$k" 2>/dev/null) || return 0
  python3 -c '
import json,sys
k,t,v=sys.argv[1],sys.argv[2],sys.argv[3]
if t=="boolean": val = v.strip() in ("1","true","YES")
elif t=="integer": val = int(v)
elif t=="float": val = float(v)
else: val = v
print(json.dumps({"key":k,"type":t,"value":val}))' "$k" "$t" "$v"
}

do_export() {
  local k out="[]"
  out=$(while IFS= read -r k; do
          [ -n "$k" ] || continue
          read_key "$k"
        done <<< "$ALLOWLIST" | python3 -c '
import json,sys
rows=[json.loads(l) for l in sys.stdin if l.strip()]
print(json.dumps({"domain":"com.cmuxterm.app","settings":rows}, indent=2, sort_keys=True))')
  printf '%s\n' "$out" > "$STORE"
  printf 'exported %s of %s allowlisted keys -> %s\n' \
    "$(printf '%s' "$out" | python3 -c 'import json,sys;print(len(json.load(sys.stdin)["settings"]))')" \
    "$(printf '%s' "$ALLOWLIST" | grep -c '[^[:space:]]')" "$STORE"
}

do_import() {
  [ -f "$STORE" ] || { echo "no $STORE to import" >&2; return 1; }
  if cmux_running; then
    cat >&2 <<'WARN'
cmux is running. It keeps preferences in memory and flushes them on quit, which
would overwrite anything written now. Quit cmux, re-run this, then start it.
WARN
    return 1
  fi
  local n=0 k t v
  while IFS=$'\t' read -r k t v; do
    [ -n "$k" ] || continue
    case "$t" in
      boolean) defaults write "$DOMAIN" "$k" -bool "$v" ;;
      integer) defaults write "$DOMAIN" "$k" -int "$v" ;;
      float)   defaults write "$DOMAIN" "$k" -float "$v" ;;
      *)       defaults write "$DOMAIN" "$k" -string "$v" ;;
    esac && n=$((n+1))
  done < <(python3 -c '
import json,sys
d=json.load(open(sys.argv[1]))
for r in d["settings"]:
    v=r["value"]
    if isinstance(v,bool): v="true" if v else "false"
    print("%s\t%s\t%s" % (r["key"], r["type"], v))' "$STORE")
  killall cfprefsd >/dev/null 2>&1 || true
  printf 'imported %s settings into %s\n' "$n" "$DOMAIN"
}

do_diff() {
  [ -f "$STORE" ] || { echo "no $STORE" >&2; return 1; }
  python3 -c '
import json,subprocess,sys
store=json.load(open(sys.argv[1]))
same=diff=new=0
for r in store["settings"]:
    k=r["key"]
    p=subprocess.run(["defaults","read","com.cmuxterm.app",k],
                     capture_output=True,text=True)
    if p.returncode!=0:
        print("  + %-40s (unset here) -> %s" % (k, r["value"])); new+=1; continue
    cur=p.stdout.strip()
    want=r["value"]
    wants = ("1" if want else "0") if isinstance(want,bool) else str(want)
    # Compare numbers numerically: `defaults read` prints 276 for a float the
    # import writes as 276.0, which is the same value, not a difference.
    equal = cur==wants
    if not equal and r["type"] in ("float","integer"):
        try: equal = float(cur)==float(wants)
        except ValueError: pass
    if equal: same+=1
    else:
        print("  ~ %-40s %s -> %s" % (k, cur, wants)); diff+=1
print("%d unchanged, %d differing, %d not set here" % (same,diff,new))' "$STORE"
}

case "${1:-}" in
  export) do_export ;;
  import) do_import ;;
  diff)   do_diff ;;
  *) cat >&2 <<'USAGE'
usage: cmux-settings.sh <export|import|diff>
  export  live cmux preferences -> cmux-settings.json (commit this)
  import  cmux-settings.json -> live preferences (quit cmux first)
  diff    show what import would change
USAGE
     exit 2 ;;
esac
