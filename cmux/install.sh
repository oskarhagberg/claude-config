#!/bin/bash
# Install the cmux <-> Claude Code integration on this machine.
#
#   ~/.claude/cmux/install.sh              interactive: ask, then install
#   ~/.claude/cmux/install.sh --doctor     check only, change nothing
#   ~/.claude/cmux/install.sh --yes        non-interactive, keep existing config
#
# Idempotent: safe to re-run after every `git pull`. It never overwrites an
# existing config.local.sh without asking, and never touches settings.json keys
# other than the four hook entries it owns.
set -uo pipefail

CMUX_DIR="$HOME/.claude/cmux"
SETTINGS="$HOME/.claude/settings.json"
LOCAL="$CMUX_DIR/config.local.sh"
BIN_DIR="$HOME/.local/bin"
HOOK="~/.claude/cmux/hook-pr-pane.sh"

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
for tool in cmux gh jq python3 git; do
  if command -v "$tool" >/dev/null 2>&1; then ok "$tool"
  else bad "$tool — required"; MISSING=1; fi
done

if gh auth status >/dev/null 2>&1; then ok "gh is authenticated"
else warn "gh is not authenticated — PR lookups will find nothing. Run: gh auth login"; fi

if command -v linear >/dev/null 2>&1; then ok "linear (optional: better slugs from issue titles)"
else warn "linear not found (optional) — slugs fall back to the prompt text"; fi

# worktrunk provides `wt`, used only when AGENT_WORKTREE=1.
WT_OK=0
if [ -x /opt/homebrew/bin/wt ] || [ -x /usr/local/bin/wt ] || command -v wt >/dev/null 2>&1; then
  WT_OK=1; ok "wt / worktrunk (optional: one git worktree per agent)"
else
  warn "worktrunk not found (optional) — needed only for AGENT_WORKTREE=1"
  if [ "$MODE" = "interactive" ] && command -v brew >/dev/null 2>&1; then
    if confirm "    Install it now with \`brew install worktrunk\`?" n; then
      brew install worktrunk && WT_OK=1 && ok "worktrunk installed"
    fi
  elif ! command -v brew >/dev/null 2>&1; then
    warn "  (no Homebrew here, so it cannot be offered automatically)"
  fi
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
  D_SKILLS=""; D_WT="$WT_OK"; D_MODEL=""; D_EFFORT=""
  # shellcheck disable=SC1090
  [ -f "$LOCAL" ] && . "$LOCAL" 2>/dev/null && {
    D_REPOS="${MANAGED_REPOS:-}"; D_TICKET="${TICKET_RE:-}"
    D_LINEAR="${LINEAR_WORKSPACE:-}"; D_TARGET="${PR_LINK_TARGET:-linear}"
    D_SKILLS="${NAMING_SKILLS:-}"; D_WT="${AGENT_WORKTREE:-$WT_OK}"
    D_MODEL="${AGENT_MODEL:-}"; D_EFFORT="${AGENT_EFFORT:-}"
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
  R_WT=0
  if [ "$WT_OK" = "1" ]; then
    confirm "  Give each agent its own git worktree (wt switch --create)?" \
      "$([ "$D_WT" = "1" ] && echo y || echo n)" && R_WT=1
  else
    echo "  Worktrees disabled (worktrunk is not installed)." >&2
  fi

  echo >&2
  echo "  Skill for the \`cmux-autopilot <TICKET>\` shortcut, e.g. cr-autopilot." >&2
  echo "  Leave empty if this machine has no such skill." >&2
  R_AUTO=$(ask "  Autopilot skill" "${AUTOPILOT_SKILL:-}")

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
    printf 'AGENT_SKILL_DIRS="%s"\n' "$HOME/.claude/skills"
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
python3 - "$SETTINGS" "$HOOK" <<'PY'
import json, os, sys, shutil, datetime
path, cmd = sys.argv[1], sys.argv[2]
d = json.load(open(path)) if os.path.exists(path) else {}
hooks = d.setdefault("hooks", {})
spec = {"PostToolUse": "Bash", "PreToolUse": "AskUserQuestion", "Stop": None, "SessionStart": None}
added = []
for event, matcher in spec.items():
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
    print("  \033[32m✓\033[0m all four hooks already wired")
PY

# ── 5. cmux GUI settings ────────────────────────────────────────────────────
hdr "cmux GUI settings"
if [ -f "$CMUX_DIR/cmux-settings.json" ]; then
  if "$CMUX_DIR/cmux-settings.sh" diff 2>/dev/null | tail -1 | grep -q '^0 unchanged\|, 0 differing, 0 not set'; then
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
