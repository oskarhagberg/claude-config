#!/bin/bash
# Install the cmux <-> Claude Code integration on this machine.
#
#   ~/.claude/cmux/install.sh              interactive: ask, then install
#   ~/.claude/cmux/install.sh --doctor     check only, change nothing
#   ~/.claude/cmux/install.sh --yes        non-interactive, keep existing config
#
# Idempotent: safe to re-run after every `git pull`. It never overwrites an
# existing config.local.sh without asking, and never touches settings.json keys
# other than the five hook entries it owns.
set -uo pipefail

# shellcheck disable=SC1091
. "$HOME/.claude/cmux/config.sh"

CMUX_DIR="$HOME/.claude/cmux"
SETTINGS="$HOME/.claude/settings.json"
LOCAL="$CMUX_DIR/config.local.sh"
BIN_DIR="$HOME/.local/bin"
HOOK="~/.claude/cmux/hook-pr-pane.sh"
NAME_HOOK="~/.claude/cmux/hook-name-workspace.sh"

MODE="interactive"
case "${1:-}" in
  --doctor) MODE="doctor" ;;
  --yes|-y) MODE="yes" ;;
  --help|-h) sed -n '2,9p' "$0"; exit 0 ;;
  "") ;;
  *) echo "unknown option: $1" >&2; exit 2 ;;
esac

ok()   { printf '  \033[32m✓\033[0m %s\n' "$*"; }
warn() { printf '  \033[33m!\033[0m %s\n' "$*"; }
bad()  { printf '  \033[31m✗\033[0m %s\n' "$*"; }
hdr()  { printf '\n\033[1m%s\033[0m\n' "$*"; }

# Where to read answers from. Checking `[ -r /dev/tty ]` is not enough: the
# device node can exist while the process has no controlling terminal, and the
# read then fails silently and every answer falls back to its default — which
# writes a plausible-looking but wrong config. So prove the source opens.
#   CMUX_INSTALL_STDIN=1 forces stdin (scripted installs, CI, tests).
if [ "${CMUX_INSTALL_STDIN:-0}" = "1" ]; then INPUT_SRC="stdin"
elif [ -t 0 ]; then INPUT_SRC="stdin"
elif ( : </dev/tty ) 2>/dev/null; then INPUT_SRC="tty"
else INPUT_SRC="none"; fi

if [ "$MODE" = "interactive" ] && [ "$INPUT_SRC" = "none" ]; then
  echo "error: no terminal to ask questions on, and stdin is not readable." >&2
  echo "       Re-run with --yes to install without prompting," >&2
  echo "       or CMUX_INSTALL_STDIN=1 to feed answers on stdin." >&2
  exit 2
fi

read_answer() { # read_answer <varname>
  local __v="$1" __r=""
  if [ "$INPUT_SRC" = "tty" ]; then IFS= read -r __r </dev/tty || __r=""
  else IFS= read -r __r || __r=""; fi
  eval "$__v=\$__r"
}

ask() { # ask <prompt> <default> -> echoes the answer
  local prompt="$1" def="${2:-}" reply
  if [ "$MODE" != "interactive" ]; then printf '%s' "$def"; return; fi
  if [ -n "$def" ]; then printf '%s [%s]: ' "$prompt" "$def" >&2
  else printf '%s: ' "$prompt" >&2; fi
  read_answer reply
  printf '%s' "${reply:-$def}"
}

set_local_knob() { # set_local_knob <name> <value> -> rewrite config.local.sh in place
  [ -f "$LOCAL" ] || return 1
  cp "$LOCAL" "$LOCAL.bak-$(date +%Y%m%d-%H%M%S)"
  python3 - "$LOCAL" "$1" "$2" <<'PYK'
import re, sys
path, name, value = sys.argv[1], sys.argv[2], sys.argv[3]
s = open(path).read()
line = '%s="%s"' % (name, value.replace('"', ''))
s, n = re.subn(r'(?m)^%s=.*$' % re.escape(name), line.replace('\\', '\\\\'), s, count=1)
if not n:
    s = s.rstrip('\n') + '\n\n' + line + '\n'
open(path, 'w').write(s)
PYK
}

confirm() { # confirm <prompt> <default y|n>
  local prompt="$1" def="${2:-n}" reply
  if [ "$MODE" != "interactive" ]; then [ "$def" = "y" ]; return; fi
  printf '%s [%s/%s]: ' "$prompt" \
    "$([ "$def" = y ] && echo Y || echo y)" "$([ "$def" = y ] && echo n || echo N)" >&2
  read_answer reply
  reply="${reply:-$def}"
  case "$reply" in [Yy]*) return 0 ;; *) return 1 ;; esac
}

# ── 1. dependencies ─────────────────────────────────────────────────────────
hdr "Dependencies"
MISSING=0
for tool in gh jq python3 git; do
  if command -v "$tool" >/dev/null 2>&1; then ok "$tool"
  else bad "$tool — required"; MISSING=1; fi
done

# cmux is special: its CLI is on PATH only inside terminals cmux spawns, so a
# plain login shell legitimately has no `cmux` while cmux is installed fine.
# config.sh resolves the app bundle; report which one we got.
if command -v cmux >/dev/null 2>&1; then
  ok "cmux (on PATH)"
elif [ -x "$CMUX_BIN" ]; then
  ok "cmux (bundled CLI at $CMUX_BIN)"
  warn "  not on PATH — add this to your shell profile to use it by hand:"
  warn "    export PATH=\"$(dirname "$CMUX_BIN"):\$PATH\""
else
  bad "cmux — required, and no bundle at /Applications/cmux.app"; MISSING=1
fi

if gh auth status >/dev/null 2>&1; then ok "gh is authenticated"
else warn "gh is not authenticated — PR lookups will find nothing. Run: gh auth login"; fi

# linear is optional, but it is the difference between a workspace called
# "ALI-42" and one called "ALI-42 export path logic": derive-name.sh only looks
# up an issue title when this CLI is on PATH. The tap matters — plain
# `brew install linear` is the Linear desktop app, an entirely different thing.
LINEAR_FORMULA="schpet/tap/linear"
if command -v linear >/dev/null 2>&1; then
  ok "linear (optional: names workspaces from the issue title)"
else
  warn "linear not found (optional) — names fall back to your prompt text, so"
  warn "  \`cmux-agent ALI-42\` with no prose becomes the bare ticket \"ALI-42\""
  warn "  note: plain \`brew install linear\` is a different thing — the desktop app"
  if [ "$MODE" = "interactive" ] && command -v brew >/dev/null 2>&1; then
    if confirm "    Install it now with \`brew install $LINEAR_FORMULA\`?" n; then
      brew install "$LINEAR_FORMULA" && ok "linear installed"
    fi
  elif ! command -v brew >/dev/null 2>&1; then
    warn "  (no Homebrew here, so it cannot be offered automatically)"
  fi
fi

# Installed but not logged in is the quiet failure mode: `linear issue view`
# returns nothing, derive-name.sh degrades to the ticket, and nothing says why.
if command -v linear >/dev/null 2>&1; then
  if timeout 15 linear auth whoami >/dev/null 2>&1; then ok "linear is authenticated"
  else warn "linear is not authenticated — run: linear auth login"; fi
fi

[ "$MISSING" = "0" ] || { echo; bad "Install the required tools above, then re-run."; exit 1; }

# ── 2. per-machine config ───────────────────────────────────────────────────
hdr "Per-machine config  ($LOCAL)"
WRITE_CONFIG=1
if [ ! -f "$LOCAL" ] && [ "$MODE" = "doctor" ]; then
  bad "no config.local.sh — run install.sh (without --doctor) to create it"
elif [ ! -f "$LOCAL" ]; then
  ok "no config.local.sh yet — creating one"
fi
if [ -f "$LOCAL" ]; then
  ok "config.local.sh already exists"
  if [ "$MODE" = "interactive" ]; then
    confirm "    Reconfigure it? (a timestamped backup is kept)" n || WRITE_CONFIG=0
  else
    WRITE_CONFIG=0
  fi
fi

if [ "$WRITE_CONFIG" = "1" ] && [ "$MODE" != "doctor" ]; then
  # Seed the prompts from whatever is already configured.
  D_REPOS=""; D_TICKET=""; D_LINEAR=""; D_TARGET="linear"
  D_SKILLS=""; D_WT=1; D_MODEL=""; D_EFFORT=""; D_CREX=""
  # shellcheck disable=SC1090
  [ -f "$LOCAL" ] && . "$LOCAL" 2>/dev/null && {
    D_REPOS="${MANAGED_REPOS:-}"; D_TICKET="${TICKET_RE:-}"
    D_LINEAR="${LINEAR_WORKSPACE:-}"; D_TARGET="${PR_LINK_TARGET:-linear}"
    D_SKILLS="${NAMING_SKILLS:-}"; D_WT="${AGENT_WORKTREE:-1}"
    D_MODEL="${AGENT_MODEL:-}"; D_EFFORT="${AGENT_EFFORT:-}"
    D_CREX="${CREX_LAYOUT:-}"
  }
  [ -n "$D_REPOS" ] || D_REPOS="$PWD"

  cat >&2 <<'INTRO'

  Answer these to generate config.local.sh. Everything is editable afterwards,
  and every answer may be left empty to disable that feature.
INTRO

  echo >&2
  echo "  Repo roots whose sessions get workspace naming." >&2
  echo "  Separate several with a comma. Worktrees beneath a root are included." >&2
  R_REPOS=$(ask "  Managed repos" "$(printf '%s' "$D_REPOS" | tr '\n' ',')")

  echo >&2
  echo "  Issue-key prefixes, as a regex alternation, e.g. (VIN|CORP)." >&2
  echo "  Leave empty if you do not track work in tickets. Avoid [A-Z]{2,6}:" >&2
  echo "  it also matches GAP-16, UTF-8 and PR-2302." >&2
  R_TICKET=$(ask "  Ticket prefixes" "$D_TICKET")

  echo >&2
  echo "  Linear workspace slug from your urls: linear.app/<slug>/issue/abc-1." >&2
  echo "  Leave empty if you do not use Linear." >&2
  R_LINEAR=$(ask "  Linear workspace" "$D_LINEAR")

  echo >&2
  echo "  Where should the PR status pill point?" >&2
  echo "    linear  the Linear review page (needs Linear's GitHub integration)" >&2
  echo "    github  the pull request itself" >&2
  R_TARGET=$(ask "  PR link target" "$([ -n "$R_LINEAR" ] && echo "$D_TARGET" || echo github)")

  echo >&2
  echo "  Skills whose invocation renames the workspace (regex), e.g." >&2
  echo "  (cr-autopilot|write-cr). Leave empty if this machine has none —" >&2
  echo "  a prompt mentioning a ticket still triggers naming." >&2
  R_SKILLS=$(ask "  Naming skills regex" "$D_SKILLS")

  echo >&2
  echo "  Give each agent its own git worktree? claude creates it at" >&2
  echo "  <repo>/.claude/worktrees/<slug> and locks it to the session." >&2
  R_WT=0
  confirm "  Per-agent worktree" "$([ "$D_WT" = "1" ] && echo y || echo n)" && R_WT=1

  echo >&2
  echo "  Skill for the \`cmux-autopilot <TICKET>\` shortcut, e.g. cr-autopilot." >&2
  echo "  Leave empty if this machine has no such skill." >&2
  R_AUTO=$(ask "  Autopilot skill" "${AUTOPILOT_SKILL:-}")

  echo >&2
  echo "  Saved crex layout to restore on the first pane of a cmux launch." >&2
  echo "  Leave empty unless \`crex save <name>\` has written one — crex ships a" >&2
  echo "  \`demo\` layout and restoring that on every launch is not what you want." >&2
  R_CREX=$(ask "  crex layout" "$D_CREX")

  R_MODEL=$(ask "  Model for cmux-agent sessions (empty = claude's default)" "$D_MODEL")
  R_EFFORT=$(ask "  Effort for cmux-agent sessions (empty = claude's default)" "$D_EFFORT")

  [ -f "$LOCAL" ] && cp "$LOCAL" "$LOCAL.bak-$(date +%Y%m%d-%H%M%S)"

  {
    echo '#!/bin/bash'
    echo '# Per-machine config — GITIGNORED. See config.local.example.sh for every knob.'
    printf '# Generated by install.sh on %s\n\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'MANAGED_REPOS="%s"\n\n' \
      "$(printf '%s' "$R_REPOS" | tr ',' '\n' | sed 's/^ *//;s/ *$//' | sed '/^$/d')"
    printf "TICKET_RE='%s'\n\n" "$R_TICKET"
    printf 'LINEAR_WORKSPACE="%s"\n' "$R_LINEAR"
    printf 'PR_LINK_TARGET="%s"\n' "$R_TARGET"
    printf 'STATUS_KEY="linear"\n\n'
    printf "NAMING_SKILLS='%s'\n" "$R_SKILLS"
    printf 'NAMING_ON_TICKET=1\n'
    printf 'SLUG_MODEL="claude-haiku-4-5-20251001"\n\n'
    printf 'AGENT_WORKTREE=%s\n' "$R_WT"
    printf 'AGENT_MODEL="%s"\n' "$R_MODEL"
    printf 'AGENT_EFFORT="%s"\n' "$R_EFFORT"
    printf 'AGENT_REMOTE_CONTROL=1\n'
    printf 'AGENT_OPEN_ISSUE=1\n'
    printf 'AUTOPILOT_SKILL="%s"\n' "$R_AUTO"
    printf 'AGENT_SKILL_DIRS="%s"\n\n' "$HOME/.claude/skills"
    printf 'CREX_LAYOUT="%s"\n' "$R_CREX"
    printf 'CREX_RESTORE_MODE="add"\n'
  } > "$LOCAL"
  ok "wrote $LOCAL"
fi

# Validate whatever config is now in place.
if [ -f "$LOCAL" ]; then
  # shellcheck disable=SC1090
  ( set -uo pipefail; . "$HOME/.claude/cmux/config.sh"
    while IFS= read -r r; do
      [ -n "$r" ] || continue
      [ -d "$r" ] && ok "managed repo exists: $r" || bad "managed repo MISSING: $r"
    done <<< "$MANAGED_REPOS"
    [ -n "$TICKET_RE" ] || warn "TICKET_RE empty — no ticket detection"
    [ -n "$LINEAR_WORKSPACE" ] || warn "LINEAR_WORKSPACE empty — no issue links"
  )
fi

# ── 3b. statusLine path ──────────────────────────────────────────────────────
# The statusLine command is an absolute path, because `~` expansion there is not
# something we could verify the way we could for hooks. An absolute path does
# not survive a different username, so normalise it to THIS machine's $HOME
# whenever the current one does not resolve.
hdr "Status line"
python3 - "$SETTINGS" "$MODE" <<'PY2'
import json, os, sys, collections
path, mode = sys.argv[1], sys.argv[2]
if not os.path.exists(path): sys.exit(0)
d = json.load(open(path), object_pairs_hook=collections.OrderedDict)
sl = d.get("statusLine") or {}
cmd = sl.get("command", "")
want = os.path.expanduser("~/.claude/statusline-command.sh")
if not cmd:
    print("  \033[33m!\033[0m no statusLine configured"); sys.exit(0)
ref = cmd.split()[-1]
if os.path.exists(os.path.expanduser(ref)):
    print("  \033[32m\u2713\033[0m statusLine command resolves"); sys.exit(0)
if os.path.exists(want):
    if mode == "doctor":
        print("  \033[33m!\033[0m statusLine points at a path that does not exist here")
        print("       run install.sh (without --doctor) to repoint it")
        sys.exit(0)
    sl["command"] = "bash " + want
    json.dump(d, open(path, "w"), indent=2); open(path, "a").write("\n")
    print("  \033[32m\u2713\033[0m statusLine repointed at " + want)
else:
    print("  \033[31m\u2717\033[0m statusline-command.sh is missing")
PY2

# statusline-command.sh and statusline-config.txt are generated by
# Claude Usage.app and are no longer tracked. A `git reset --hard` on a machine
# where they WERE tracked deletes them, so say so plainly rather than leaving a
# blank status line to be puzzled over.
if [ ! -f "$HOME/.claude/statusline-command.sh" ]; then
  bad "statusline-command.sh is missing"
  warn "  it is generated by Claude Usage.app, not by this repo"
  warn "  open Claude Usage.app to have it reinstall the script"
elif ! grep -q "fetch-claude-usage" "$HOME/.claude/statusline-command.sh" 2>/dev/null; then
  warn "statusline-command.sh has been edited away from the app's version"
  warn "  (its swift fallback is gone) — reopen Claude Usage.app to restore it"
else
  ok "statusline-command.sh matches the app's shape"
fi

# The usage segment needs a producer for ~/.claude/.statusline-usage-cache.
if [ -f "$HOME/.claude/.statusline-usage-cache" ]; then
  age=$(( $(date +%s) - $(stat -f %m "$HOME/.claude/.statusline-usage-cache" 2>/dev/null || echo 0) ))
  if [ "$age" -lt 300 ]; then ok "usage cache is fresh (${age}s)"
  else warn "usage cache is ${age}s stale — the statusline will show 'Usage: ~'"; fi
elif [ -d "/Applications/Claude Usage.app" ]; then
  warn "Claude Usage.app is installed but has not written the cache yet"
else
  warn "no usage cache and no Claude Usage.app — the statusline will show 'Usage: ~'"
  warn "  the old fetch-claude-usage.swift fallback was dropped (it embedded a token)"
fi

# ── 3c. workspace trust ─────────────────────────────────────────────────────
# A repo Claude Code has never been trusted in kills `cmux-agent` on its first
# run — claude exits 1 before doing anything. Nothing here can accept the dialog
# on your behalf, so say which repos need one, while there is still a terminal
# to read it in.
hdr "Claude Code workspace trust"
# shellcheck disable=SC1091
. "$CMUX_DIR/config.sh"   # pick up a config.local.sh written earlier in this run
if [ -z "${MANAGED_REPOS:-}" ]; then
  warn "MANAGED_REPOS is empty — nothing to check"
else
  untrusted=0
  while IFS= read -r repo; do
    [ -n "$repo" ] || continue
    if [ ! -d "$repo" ]; then
      warn "$repo does not exist on this machine"
    elif trust_accepted "$repo"; then
      ok "trusted: $repo"
    else
      bad "not trusted: $repo"
      untrusted=$((untrusted+1))
    fi
  done <<< "$MANAGED_REPOS"
  [ "$untrusted" -gt 0 ] && \
    warn "run \`claude\` once in each and accept the trust dialog, or cmux-agent will exit 1 there"
fi

# ── 3d. crex layout auto-restore ────────────────────────────────────────────
# Three separate things, each reported before it is offered, and none of them
# done behind your back in --doctor: the binary, the two ~/.zshrc lines, and a
# saved layout to point at. `crex` is an ALIAS of the cmux-resurrect formula in
# a third-party tap, so `brew install crex` alone fails on a machine that has
# not tapped it.
hdr "crex layout auto-restore"
ZSHRC="$HOME/.zshrc"
CREX_FORMULA="drolosoft/tap/cmux-resurrect"
LOADER='[ -x ~/.claude/cmux/crex-autorestore.sh ] && ~/.claude/cmux/crex-autorestore.sh'
POP_BIND="bindkey -s '^G' 'crex pop\\n'"

if command -v "$CREX_BIN" >/dev/null 2>&1; then
  ok "crex installed ($(command -v "$CREX_BIN"))"
elif [ "$MODE" = "doctor" ]; then
  warn "crex not installed — auto-restore is off. brew install $CREX_FORMULA"
elif ! command -v brew >/dev/null 2>&1; then
  warn "crex not installed, and no Homebrew here to offer it"
else
  warn "crex not installed — layout auto-restore is off"
  if confirm "    Install it now with \`brew install $CREX_FORMULA\`?" y; then
    brew install "$CREX_FORMULA" && ok "crex installed" || bad "brew install failed"
  fi
fi

# crex's own config, not this repo's: `auto_accept` rewrites every `claude` it
# restores into `claude --dangerously-skip-permissions`. `crex setup` offers to
# set it, so a second machine can acquire it quietly — and a layout restore is
# the last place you want a permission prompt skipped without being asked.
CREX_CONF="${XDG_CONFIG_HOME:-$HOME/.config}/crex/config.toml"
if grep -qE "^auto_accept[^#]*claude" "$CREX_CONF" 2>/dev/null; then
  warn "crex auto_accept is on — restored panes start \`claude --dangerously-skip-permissions\`"
  warn "  remove the auto_accept line from $CREX_CONF for plain \`claude\`"
fi

# The two ~/.zshrc lines: the Ctrl+G layout picker and the auto-restore loader.
# Only the missing ones are appended, under one marker, after a backup — this
# file is personal and may already carry either line from `crex setup`.
if [ ! -f "$ZSHRC" ]; then
  warn "no $ZSHRC — add these to whatever your shell reads:"
  printf '      %s\n      %s\n' "$POP_BIND" "$LOADER"
else
  ZADD=""
  grep -qF 'crex pop' "$ZSHRC"            || ZADD="$POP_BIND"
  grep -qF 'crex-autorestore.sh' "$ZSHRC" || ZADD="${ZADD:+$ZADD
}$LOADER"
  if [ -z "$ZADD" ]; then
    ok "$ZSHRC has the Ctrl+G picker and the auto-restore loader"
  elif [ "$MODE" = "doctor" ]; then
    warn "$ZSHRC is missing:"
    printf '%s\n' "$ZADD" | sed 's/^/      /'
  else
    warn "$ZSHRC is missing:"
    printf '%s\n' "$ZADD" | sed 's/^/      /'
    if confirm "    Append it? (a timestamped backup is kept)" y; then
      cp "$ZSHRC" "$ZSHRC.bak-$(date +%Y%m%d-%H%M%S)"
      {
        printf '\n# ── crex, via ~/.claude/cmux/install.sh ─────────────────────────────────\n'
        printf '%s\n' "$ZADD"
      } >> "$ZSHRC"
      ok "appended to $ZSHRC — new shells pick it up"
    fi
  fi
fi

# A layout to restore. `crex save` snapshots the LIVE cmux session, so it only
# works from inside one, and it overwrites an existing name without asking.
if ! command -v "$CREX_BIN" >/dev/null 2>&1; then
  : # nothing to say about layouts without crex
elif [ -n "$CREX_LAYOUT" ] && "$CREX_BIN" show "$CREX_LAYOUT" >/dev/null 2>&1; then
  ok "layout '$CREX_LAYOUT' exists, mode $CREX_RESTORE_MODE"
elif [ "$MODE" = "doctor" ]; then
  if [ -z "$CREX_LAYOUT" ]; then
    warn "CREX_LAYOUT empty — nothing is restored. \`crex save my-day\`, then set it in config.local.sh"
  else
    bad "CREX_LAYOUT='$CREX_LAYOUT' is not a saved layout — \`crex list\` shows what is"
  fi
else
  if [ -z "$CREX_LAYOUT" ]; then
    warn "no layout configured — nothing is restored yet"
  else
    bad "CREX_LAYOUT='$CREX_LAYOUT' is not a saved layout"
  fi
  echo "  \`crex save <name>\` snapshots the cmux session you are in right now —" >&2
  echo "  every workspace, pane split and cwd — and that name goes in CREX_LAYOUT." >&2
  echo "  Arrange the session you want back before answering yes." >&2
  # Asked as yes/no first, then the name. One prompt with an "empty skips"
  # default cannot do both: ask() returns the default on an empty answer, so
  # "just press enter to skip" would in fact save a layout called my-day.
  R_SAVE=""
  confirm "    Save this cmux session as a layout now?" y \
    && R_SAVE=$(ask "    Name it" "${CREX_LAYOUT:-my-day}")
  if [ -z "$R_SAVE" ]; then
    warn "skipped — later: \`crex save my-day\`, then CREX_LAYOUT=\"my-day\" in config.local.sh"
  elif [ -z "${CMUX_SOCKET_PATH:-}" ]; then
    bad "not inside a cmux terminal — crex has no live session to snapshot. Re-run from one."
  elif "$CREX_BIN" save "$R_SAVE" >/dev/null 2>&1; then
    if set_local_knob CREX_LAYOUT "$R_SAVE"; then
      ok "saved layout '$R_SAVE' and set CREX_LAYOUT in config.local.sh"
    else
      warn "saved layout '$R_SAVE' — set CREX_LAYOUT=\"$R_SAVE\" in config.local.sh by hand"
    fi
  else
    bad "crex save '$R_SAVE' failed — run it by hand to see why"
  fi
fi

[ "$MODE" = "doctor" ] && { hdr "Doctor only — nothing changed."; exit 0; }

# ── 3. executables + symlink ────────────────────────────────────────────────
hdr "Executables"
chmod +x "$CMUX_DIR"/*.sh "$CMUX_DIR/cmux-agent" 2>/dev/null
ok "chmod +x on $CMUX_DIR"

mkdir -p "$BIN_DIR"
if [ -L "$BIN_DIR/cmux-agent" ] && [ "$(readlink "$BIN_DIR/cmux-agent")" = "$CMUX_DIR/cmux-agent" ]; then
  ok "$BIN_DIR/cmux-agent already linked"
else
  [ -e "$BIN_DIR/cmux-agent" ] && mv "$BIN_DIR/cmux-agent" "$BIN_DIR/cmux-agent.bak-$(date +%Y%m%d-%H%M%S)"
  ln -sf "$CMUX_DIR/cmux-agent" "$BIN_DIR/cmux-agent" && ok "linked $BIN_DIR/cmux-agent"
fi
if [ -n "$(. "$CMUX_DIR/config.sh" 2>/dev/null; echo "${AUTOPILOT_SKILL:-}")" ]; then
  if [ -L "$BIN_DIR/cmux-autopilot" ] && [ "$(readlink "$BIN_DIR/cmux-autopilot")" = "$CMUX_DIR/cmux-autopilot" ]; then
    ok "$BIN_DIR/cmux-autopilot already linked"
  else
    [ -e "$BIN_DIR/cmux-autopilot" ] && mv "$BIN_DIR/cmux-autopilot" "$BIN_DIR/cmux-autopilot.bak-$(date +%Y%m%d-%H%M%S)"
    ln -sf "$CMUX_DIR/cmux-autopilot" "$BIN_DIR/cmux-autopilot" && ok "linked $BIN_DIR/cmux-autopilot"
  fi
else
  warn "AUTOPILOT_SKILL unset — skipping the cmux-autopilot shortcut"
fi
case ":$PATH:" in *":$BIN_DIR:"*) ok "$BIN_DIR is on PATH" ;;
  *) warn "$BIN_DIR is NOT on PATH — add it to your shell profile" ;; esac

# ── 4. settings.json hooks ──────────────────────────────────────────────────
hdr "Claude Code hooks  ($SETTINGS)"
python3 - "$SETTINGS" "$HOOK" "$NAME_HOOK" <<'PY'
import json, os, sys, shutil, datetime
path, cmd, name_cmd = sys.argv[1], sys.argv[2], sys.argv[3]
d = json.load(open(path)) if os.path.exists(path) else {}
hooks = d.setdefault("hooks", {})
# (event, matcher, command). The first four are the PR-pane triggers; the fifth
# is workspace naming, which README documents but nothing registered until
# 2026-09-18 — so naming had never once fired outside its own tests.
spec = [("PostToolUse", "Bash", cmd), ("PreToolUse", "AskUserQuestion", cmd),
        ("Stop", None, cmd), ("SessionStart", None, cmd),
        ("UserPromptSubmit", None, name_cmd)]
added = []
for event, matcher, cmd in spec:
    entries = hooks.setdefault(event, [])
    if any(h.get("command") == cmd for e in entries for h in e.get("hooks", [])):
        continue
    entry = {"hooks": [{"type": "command", "command": cmd, "timeout": 15}]}
    if matcher:
        entry = {"matcher": matcher, "hooks": entry["hooks"]}
    entries.append(entry)
    added.append(event)
if added:
    if os.path.exists(path):
        shutil.copy(path, path + ".bak-" + datetime.datetime.now().strftime("%Y%m%d-%H%M%S"))
    json.dump(d, open(path, "w"), indent=2)
    open(path, "a").write("\n")
    print("  \033[32m✓\033[0m added hooks: " + ", ".join(added))
else:
    print("  \033[32m✓\033[0m all five hooks already wired")
PY

# ── 5. cmux GUI settings ────────────────────────────────────────────────────
hdr "cmux GUI settings"
if [ -f "$CMUX_DIR/cmux-settings.json" ]; then
  # The summary line is "<n> unchanged, <n> differing, <n> not set here", and
  # only all-zero on the last two means there is nothing to do. An earlier
  # `^0 unchanged` alternative here matched the exact opposite case — zero keys
  # agreeing — and reported a machine that shared no settings at all as already
  # in sync.
  if "$CMUX_DIR/cmux-settings.sh" diff 2>/dev/null | tail -1 | grep -q ', 0 differing, 0 not set'; then
    ok "cmux settings already match cmux-settings.json"
  else
    "$CMUX_DIR/cmux-settings.sh" diff 2>/dev/null | sed 's/^/  /'
    if confirm "    Apply these to cmux? (requires cmux to be quit)" n; then
      "$CMUX_DIR/cmux-settings.sh" import && ok "cmux settings imported"
    else
      warn "skipped — run \`$CMUX_DIR/cmux-settings.sh import\` later, with cmux quit"
    fi
  fi
else
  warn "no cmux-settings.json — run \`$CMUX_DIR/cmux-settings.sh export\` on your configured machine"
fi

hdr "Done"
cat <<DONE
  Restart any running Claude session for the hooks to load.
  Try it:   cmux-agent --help
  Log:      ~/.claude/logs/cmux-integration.log
  Recheck:  ~/.claude/cmux/install.sh --doctor
DONE
