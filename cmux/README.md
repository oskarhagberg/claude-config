# cmux ↔ Claude Code integration

Portable glue between [cmux](https://cmux.com) workspaces and Claude Code
sessions. Lives in `~/.claude/cmux`, which is tracked in the `claude-config`
repo, so a second machine gets it with `git pull` + `install.sh`.

Four things it does:

1. **PR review link.** While a PR is open, the workspace's status pill points at
   the **Linear review page** for it — `VIN-1760 · PR #2302` →
   `linear.review/humlytech/vinga/pull/2302` — and that page opens in a browser
   pane. Before a PR exists the pill is the ticket; once the PR merges or closes
   it falls back to the ticket. One pill, following the workflow.
2. **Workspace / agent naming.** A prompt that invokes a configured skill, or
   merely mentions a ticket, renames the cmux workspace to
   `VIN-1414 envelope causation scope` and sets the Claude session's display
   name to the kebab form (`vin-1414-envelope-causation-scope`) — the identifier
   in `ListAgents`, `/resume` and `SendMessage`.
3. **`cmux-agent`.** Opens a new workspace, optionally its own git worktree, and
   starts Claude on a skill and/or a prompt in it.
4. **crex layout auto-restore.** On the first pane of a cmux launch, restores a
   layout saved with [crex](https://github.com/cmux/cmux-resurrect)
   (`cmux-resurrect`) — once per launch, never on top of a session already
   under way. Off until `CREX_LAYOUT` names a saved layout.

Everything machine-specific lives in one gitignored file, `config.local.sh`.

---

## Install

```bash
git clone git@github.com:oskarhagberg/claude-config.git ~/.claude   # or: git pull
~/.claude/cmux/install.sh
```

`install.sh` is interactive and idempotent — re-run it after every pull. It:

- checks `cmux`, `gh`, `jq`, `python3`, `git` (required) and `linear` (optional),
  **offers to `brew install schpet/tap/linear`** when it is missing, and reports
  whether it is logged in — installed-but-unauthenticated is a silent failure,
  since `linear issue view` then returns nothing and names quietly degrade;
- asks for your repos, ticket prefixes, Linear workspace and agent preferences,
  then writes `config.local.sh` (backing up any existing one);
- symlinks `~/.local/bin/cmux-agent`, and `cmux-autopilot` too when
  `AUTOPILOT_SKILL` is set;
- merges its five hook entries into `~/.claude/settings.json` without touching
  anything else in that file;
- repoints `statusLine.command` at this machine's `$HOME` if the configured path
  does not resolve here, and reports whether anything is still writing the usage
  cache (see [the statusline section](#the-statusline-is-owned-by-claude-usageapp--do-not-track-it));
- offers to import the shared cmux GUI settings.

Other modes: `--doctor` (check only, change nothing), `--yes` (non-interactive,
keeps existing config). For a scripted install, `CMUX_INSTALL_STDIN=1` forces it
to read answers from stdin:

```bash
printf '%s\n' ~/code/thing '(ABC|DEF)' humly linear '' n '' '' n \
  | CMUX_INSTALL_STDIN=1 ~/.claude/cmux/install.sh
```

It refuses rather than guessing when it has no terminal and no readable stdin —
proving the input source beats trusting `[ -r /dev/tty ]`, which passes on a
machine with no controlling terminal and silently writes a config of defaults.

Restart running Claude sessions afterwards so the hooks load.

### Requirements

| Tool | Needed for | Install |
|---|---|---|
| `cmux` | everything | the app. **Its CLI is on PATH only inside terminals cmux spawns** — a plain login shell has none, and there is no symlink in `/usr/local/bin`. The scripts resolve `/Applications/cmux.app/Contents/Resources/bin/cmux` directly, so they do not care; add that directory to your PATH to run `cmux` by hand. |
| `gh` (authenticated) | finding the PR for a branch | `brew install gh && gh auth login` |
| `jq`, `python3`, `git` | everywhere | preinstalled or `brew` |
| `crex` | *optional* — layout auto-restore only. A normal PATH install, unlike cmux's CLI. | `brew install crex` |
| `linear` | *optional* — names workspaces from the issue title instead of the prompt text: `cmux-agent ALI-42` becomes `ALI-42 web docker file` rather than the bare ticket | `brew install schpet/tap/linear && linear auth login` (install.sh offers it). Plain `brew install linear` is the Linear **desktop app**, not this. Check with `linear auth whoami`. |

---

## Files

| File | Role | Tracked |
|---|---|---|
| `config.sh` | Defaults + every helper. Sources `config.local.sh` over the defaults. | yes |
| `config.local.sh` | **The only per-machine file.** | **no** |
| `config.local.example.sh` | Annotated template for every knob. | yes |
| `install.sh` | Interactive installer, doctor, dependency check. | yes |
| `hook-pr-pane.sh` | Dispatcher for the four PR-review triggers. | yes |
| `pr-status-worker.sh` | Detached worker: resolves the PR, sets the pill, opens the pane. | yes |
| `hook-name-workspace.sh` | `UserPromptSubmit` hook; validates, dispatches detached. | yes |
| `rename-worker.sh` | Detached worker: derives the name, renames workspace + agent. | yes |
| `derive-name.sh` | `[--raw] <text>` → `VIN-1234 three word slug`. | yes |
| `set-agent-name.sh` | Writes a running session's display name. | yes |
| `cmux-agent` | The launcher. Symlinked into `~/.local/bin`. | yes |
| `cmux-autopilot` | Shortcut: `cmux-autopilot VIN-1760` → `cmux-agent /$AUTOPILOT_SKILL VIN-1760`. | yes |
| `cmux-settings.sh` | `export`/`import`/`diff` cmux's own GUI settings. | yes |
| `cmux-settings.json` | Those settings, as data. | yes |
| `crex-autorestore.sh` | Restores the crex layout once per cmux launch. Run from `~/.zshrc`. | yes |

Log: `~/.claude/logs/cmux-integration.log`. State: `/tmp/claude/cmux-integration`.

---

## Configuration

`config.sh` holds portable defaults; `config.local.sh` states only what differs
on this machine. Helpers are defined *after* the local file is sourced and read
their variables at call time, so an override reaches them for free.

**Every feature degrades to nothing when its knob is empty**, which is what
makes the package usable on a machine that has no tickets, no Linear, or no
skills.

| Knob | Meaning | Empty means |
|---|---|---|
| `MANAGED_REPOS` | Repo roots that get naming, one per line. Worktrees beneath a root are included. | naming off everywhere |
| `TICKET_RE` | Issue-key prefixes as a regex alternation, `(VIN\|CORP)`. | no ticket detection; plain slugs, `PR #123` pills |
| `LINEAR_WORKSPACE` | Slug from `linear.app/<slug>/issue/...`. | no issue links (review links still work) |
| `PR_LINK_TARGET` | `linear` (review page) or `github` (the PR). | — |
| `STATUS_KEY` | cmux pill key the link is written to. | — |
| `NAMING_SKILLS` | Skills whose invocation renames the workspace (regex). | no skill ever triggers naming |
| `NAMING_ON_TICKET` | `1` = a prompt merely mentioning a ticket also renames. | — |
| `SLUG_MODEL` | Model that compresses an issue title to ~3 words. | — |
| `AGENT_WORKTREE` | `1` = `claude --worktree <slug>` per agent → `<repo>/.claude/worktrees/<slug>`, branch `worktree-<slug>`, locked to the pid. | — |
| `AGENT_MODEL` / `AGENT_EFFORT` | Passed to `claude`. | claude's own defaults |
| `AGENT_REMOTE_CONTROL` | `1` = `--remote-control <slug>`. | — |
| `AGENT_OPEN_ISSUE` | `1` = open the ticket in a browser split at launch. | — |
| `AGENT_SKILL_DIRS` | Dirs searched for `cmux-agent /<skill>`, one per line, after the workspace cwd's own `.claude/skills`. | `~/.claude/skills` |
| `AUTOPILOT_SKILL` | Skill the `cmux-autopilot` shortcut runs. | the shortcut refuses rather than guessing |
| `CREX_LAYOUT` | Saved crex layout restored on the first pane of a launch. | auto-restore off |
| `CREX_RESTORE_MODE` | `add` (never closes a workspace) or `replace`. | — |

**Do not set `TICKET_RE` to something permissive** like `[A-Z]{2,6}`. It also
matches `GAP-16`, `UTF-8` and `PR-2302`, and you get workspaces named after a
typo.

### Two machines, one repo

```bash
# primary                                 # second laptop
MANAGED_REPOS="$HOME/humly/vinga"         MANAGED_REPOS="$HOME/code/thing"
TICKET_RE='(VIN|CORP)'                    TICKET_RE='(ABC)'
LINEAR_WORKSPACE="humly"                  LINEAR_WORKSPACE="humly"
NAMING_SKILLS='(cr-autopilot|write-cr…)'  NAMING_SKILLS=''      # no such skills
AUTOPILOT_SKILL="cr-autopilot"            AUTOPILOT_SKILL=''    # no such skill
CREX_LAYOUT="my-day"                      CREX_LAYOUT=''        # nothing saved yet
AGENT_WORKTREE=1                          AGENT_WORKTREE=0      # no worktrees
```

That is the whole diff between machines.

---

## `cmux-agent`

```bash
cmux-agent /cr-autopilot VIN-1760                  # a skill
cmux-agent why is staging timing out               # a prompt
cmux-agent /code-review also check the migration   # a skill plus prose
cmux-agent --cwd ~/code/other fix the flaky test
```

The first word decides the mode. A `/`-prefixed first word is strict: unknown
means exit 2 with the list of skill dirs, never a silent fall-through to prompt
mode. Working directory is `$PWD` when it is inside a managed repo, else the
first `MANAGED_REPOS` entry, else `$PWD`. It is resolved *before* the skill
lookup, which searches every `.claude/skills` from that directory up to `$HOME`
(project skills, e.g. `<repo>/.claude/skills/refine`) and then
`AGENT_SKILL_DIRS`.

`cmux-autopilot VIN-1760 [extra prompt]` is a one-line shortcut for
`cmux-agent /$AUTOPILOT_SKILL VIN-1760 [extra prompt]` — the skill it means is
config, not code, so a machine that has no such skill just leaves
`AUTOPILOT_SKILL` empty and the shortcut refuses rather than guessing.

Together these replace the older `launch.sh` + `cmux-agent` + `cmux-autopilot`
trio with one code path. The name is derived **synchronously** (~15s: a `linear issue
view` plus a haiku call) rather than refined in the background, because it also
becomes the worktree and therefore the branch that carries the PR — a stub
branch name is not worth the saved seconds.

### Two preconditions, checked before the workspace opens

Both of these used to fail *inside* the new workspace, where the shell exited
immediately afterwards and took the error off the screen with it — a launch that
failed looked exactly like a workspace that flickered and vanished.

- **Trust.** `claude` refuses to start in a directory whose "do you trust this
  folder?" dialog has not been accepted, and exits 1. `cmux-agent` checks
  `~/.claude.json` first and tells you which directory needs it; `install.sh`
  and `--doctor` check every `MANAGED_REPOS` entry. Nothing accepts it for you.
- **worktrunk.** No longer a dependency at all — see below.

And when the session itself exits non-zero, the workspace **stays open** with
`[cmux-agent] exited <rc>` under the error. It closes on a clean exit only.

### One worktree, owned by claude

`AGENT_WORKTREE=1` passes `--worktree <slug>` to claude, which creates
`<repo>/.claude/worktrees/<slug>` on branch `worktree-<slug>` and locks it to the
session's pid for as long as that session runs.

**Worktrunk is deliberately not used here**, though it was at first. `wt switch
--create <slug>` puts its worktree in a *sibling* directory, `<repo>.<slug>` —
which is outside `MANAGED_REPOS`, so `in_managed_repo()` says no and
`hook-name-workspace.sh` switches itself off for the whole session. Running both
tools (the original code did) produced two worktrees and two branches per launch
with worktrunk's left orphaned. Under `.claude/worktrees` the worktree stays
inside the repo and everything keyed to `MANAGED_REPOS` keeps working.

The cost is the branch name: claude prefixes it `worktree-` and that is not
configurable, so `ticket_from_branch()` strips a leading `worktree-` before
matching `TICKET_RE`. Without that the anchor never matches inside an agent
worktree and every pill there degrades to a bare `PR #123`.

---

## How each trigger fires

- **Naming** — `UserPromptSubmit`. Requires `CMUX_WORKSPACE_ID` (we are in
  cmux), `cwd` inside a managed repo, and either a `NAMING_SKILLS` match or —
  with `NAMING_ON_TICKET=1` — a ticket mention. Derivation takes ~15s, so the
  hook returns instantly and `rename-worker.sh` does the work detached; a prompt
  is never delayed.

  Its `settings.json` entry is the fifth hook `install.sh` merges, and it was
  missing until 2026-09-18: `install.sh` registered only the four PR-pane
  triggers, so on a machine installed from this repo naming was documented,
  implemented, tested — and never once fired. If the log holds `pr-status:`
  lines but no `name-workspace:` lines, that is this bug; re-run `install.sh`.
- **PR review link** — four triggers, all into `hook-pr-pane.sh`, all requiring
  `CMUX_WORKSPACE_ID`. None of them gate on `MANAGED_REPOS`: an open PR is its
  own qualification, so any repo with a GitHub remote gets a pill.

  | Trigger | Fires on | PR URL from | Opens a pane? |
  |---|---|---|---|
  | `PostToolUse(Bash)` | the command matches `gh pr create` | the tool response | yes |
  | `PreToolUse(AskUserQuestion)` | header `Confirm PR`, or the text `request human reviewers` | the question text, else `gh pr view` | yes |
  | `SessionStart` | every session start / resume | `gh pr view` (uncached) | yes |
  | `Stop` | every turn end | `gh pr view` (90s cache) | **no** |

  All four exit 0 with no stdout and hand off to `pr-status-worker.sh` detached,
  so no tool call is blocked or altered and no turn waits on `gh`.
- **crex layout auto-restore** — not a Claude hook at all: `~/.zshrc` runs
  `crex-autorestore.sh` in the shell of every terminal cmux spawns, and the
  script decides in three cheap tests whether this is a launch's first pane.

---

## crex layout auto-restore

[crex](https://github.com/cmux/cmux-resurrect) saves and restores cmux layouts.
`crex-autorestore.sh` brings one back on the first pane of a launch. One line in
`~/.zshrc` loads it:

```bash
[ -x ~/.claude/cmux/crex-autorestore.sh ] && ~/.claude/cmux/crex-autorestore.sh
```

Then, once per machine:

```bash
crex save my-day                     # there is nothing to restore until this
# config.local.sh
CREX_LAYOUT="my-day"
```

`install.sh` reports all of it — crex on PATH, whether `CREX_LAYOUT` names a
layout that exists, whether `~/.zshrc` loads the script — but never edits
`~/.zshrc`, which is a personal file whose ordering is yours.

**Executed, not sourced.** It needs nothing from the interactive shell but the
environment cmux exports, and sourcing would drag `config.sh`'s whole namespace,
and its bash 3.2 idioms, into every zsh prompt.

**Empty `CREX_LAYOUT` is off, and that is the right default.** crex ships a
`demo` layout (`🏠 home`, `📁 files`), so a nameless `crex restore` on a machine
that has saved nothing resurrects an example grid of Documents and Downloads
panes at every launch.

**`--mode` is always passed.** crex's own default restore mode is `ask`, which
opens an interactive picker — and a detached job cannot answer one. An invalid
value falls back to `add` rather than `replace`, because `replace` *closes* live
workspaces, agent worktrees included; it is not a safe guess.

**Exactly one workspace, not "one or fewer".** The first-pane test is
`cmux workspace list`, and an unreachable cmux prints nothing at all. Treating
that zero as "first pane" restores the layout into every shell that ever opens.
It also uses `workspace list`, not `list-workspaces`: the old form still works,
but now prints a deprecation notice on stderr, which would land on the terminal
of every new pane.

**One restore per launch, enforced with `mkdir`.** The restore creates
workspaces whose shells run this script again, and two panes opening together
would both see a single workspace. `mkdir` is the atomic test-and-set; the lock
is keyed on the socket's birth time, so the next launch takes a fresh lock and a
stale one is never mistaken for this launch's.

**Output goes to the log, never `/dev/null`.** The first version of this ran
`crex restore --force`, and crex has no `--force` flag: it exited 1 on every
single launch, in silence, and the layout never came back once. Anything worth
running in the background is worth logging.

## cmux's own GUI settings

`cmux-settings.sh` carries the cmux app's preferences between machines, so a new
laptop does not mean redoing the GUI.

```bash
cmux-settings.sh export   # live prefs -> cmux-settings.json   (commit this)
cmux-settings.sh diff     # what an import would change
cmux-settings.sh import   # cmux-settings.json -> live prefs   (quit cmux first)
```

**Not `~/.config/cmux/cmux.json`**, because that is not where your settings are.
cmux writes GUI settings to the macOS preferences domain `com.cmuxterm.app`;
`cmux.json` is an opt-in override file shipped as an all-commented-out template,
and it does not expose every key the GUI does (`sidebarPreset`,
`sidebarMaterial`, `rightSidebar.mode` and the `fileExplorer` keys have no
equivalent there). Anything you do put in `cmux.json` by hand still wins — the
two do not fight, `cmux.json` is simply higher precedence.

**An explicit allowlist, not a dump.** That same domain holds this machine's
identity: auth tokens (`cmux.auth.*`), iroh device and broker credentials
(`cmux.iroh.*`, `mobileHost.deviceID`), browser profile ids, telemetry counters
and window geometry. Copying those to a second laptop is at best useless and at
worst forks your device identity. The 37 portable keys are named explicitly in
the script, and nothing else is ever read — so a key cmux adds in a future
release cannot leak into the export by accident.

**Import needs cmux quit.** It keeps preferences in memory and flushes them on
exit, which would overwrite anything written underneath it. The script refuses
to run while cmux is up.

**`pgrep` cannot see cmux, and that guard was a no-op until 2026-09-12.** macOS
records a bundled app's accounting name as its executable *path* truncated to 16
characters — `ps -o comm` prints `/Applications/cm`, not `cmux` — so `pgrep cmux`
matches nothing while cmux is running, with or without `-f`. The refusal above
therefore never fired: `import` wrote all 37 keys underneath a live cmux, printed
`imported 37 settings`, and cmux flushed its in-memory copy over every one of
them on quit. A clean install looked successful and changed nothing.

The check now matches the bundle path in full `ps` output, and short-circuits on
`CMUX_PANEL_ID` when the script is itself running inside a cmux terminal — which
it usually is, since cmux's CLI is only on PATH there. It is deliberately *not*
`ps … | grep -q`: this file runs under `set -o pipefail`, and `grep -q` exits at
the first match, SIGPIPEs `ps`, and fails the pipeline on success.

Adjacent to this, `install.sh`'s "already in sync" test read
`^0 unchanged\|, 0 differing, 0 not set` — whose first alternative matches the
exact opposite case, a machine where *zero* keys agree. A fresh laptop could be
told its settings already matched and never be offered the import at all.

---

## Two machines, one identity boundary

This checkout is a **Humly** machine; the other is not. The split is enforced by
where config lives, not by remembering to edit things:

| Lives in | Carries | Reaches the other laptop? |
|---|---|---|
| `~/.claude/settings.json` (tracked) | hooks, statusLine, plugins, editor/tui prefs | yes — nothing org-specific in it |
| `<repo>/.claude/settings.local.json` (gitignored in that repo) | `autoMode` (environment, allow, soft_deny) and tracey permissions | no |
| `~/.claude/cmux/config.local.sh` (gitignored) | repo roots, ticket prefixes, Linear workspace, autopilot skill | no |
| `<repo>/.claude/skills/` | org tooling skills (vinga: `tracey-annotate`, `tracey-requirement`) | no |

The settings cascade is
`~/.claude/settings.json` → `<repo>/.claude/settings.json` → `<repo>/.claude/settings.local.json`
→ managed policy. **There is no user-level `settings.local.json`** — that file is
project-scoped only, so org config cannot be hidden that way; it has to live in
the repo it describes. Verified: an `env` var set only in a project's
`settings.local.json` reached the Bash tool of a session started there.

One key must stay in the user file: `permissions.defaultMode: "auto"` is
deliberately ignored from project settings as repo-controllable, so moving it
would silently drop auto mode.

## Design notes

- **The review URL needs no Linear API call.** Linear documents a redirect: swap
  `github.com` for `linear.review` and you land on that PR's review page in
  whichever Linear workspace owns the repo. The GraphQL API exposes no
  PR-by-URL lookup and the canonical review URL ends in an opaque slug id
  (`…-9fa316d34f44`) that cannot be derived, so the redirect is the only cheap
  route — and it is a pure string substitution in `linear_review_url()`.
- **The review pane is idempotent, and matched by host, not URL.** The tab
  settles on `linear.app/<ws>/review/<title-slug>-<slugid>` after the redirect,
  which carries back neither the URL we opened nor the PR number. So reuse is
  decided from the live `cmux tree` on *either* host form. A tab already there is
  left strictly alone rather than reloaded: one workspace is one branch is one
  PR, the gate can re-fire while you are reading, and re-navigating would yank
  the page out from under you.
- **`Stop` is pill-only and cached.** It fires at the end of every turn, so it
  rides a 90s per-cwd cache of `gh pr view` (93ms warm vs 647ms cold) and never
  touches panes. Being a minute stale costs nothing; a browser tab moving while
  you read costs a lot.
- **Config lists are newline-separated strings, not arrays.** macOS ships bash
  3.2, where `"${arr[@]}"` on an *empty* array under `set -u` aborts the
  script — and every hook here runs `set -uo pipefail`. A string costs one
  `while read` and cannot take a hook down.
- **`kebab()` is the single definition of the identifier form**: lowercase,
  non-alphanumerics collapsed to `-`, trimmed, capped at 60 chars.
  `VIN-1414 envelope causation scope` → `vin-1414-envelope-causation-scope`,
  matching the usual branch convention.
- **Naming is deduped** per workspace on a hash of the invocation line
  (`ws-<uuid>.named`), and never overwrites a title already shaped
  `<TICKET> <text>`. A title you set by hand survives.
- **`--raw` distinguishes a prompt from a skill invocation** in
  `derive-name.sh`: without it a leading command token is stripped before
  slugging, which is right for `/skill args` and wrong for prose.
- **Naming cannot recurse.** `derive-name.sh` runs `claude -p "Compress this
  software task …"`, and that prompt is itself a `UserPromptSubmit` carrying the
  skill name. The hooks bail on the `CMUX_NAMING_CHILD` marker env and on the
  prompt shape. This loop produced ~560 nested haiku runs before the guard
  existed.
- **Never positionally cut a cmux handle out of output.** Several verbs print
  more than one field (`cmux send` answers `OK surface:5 workspace:3`), and
  `$(...)` around a helper captures every line it writes, so `cut -f2` silently
  welds fields from different lines into one bogus multi-line handle. Use
  `parse_workspace_id()`.

## Agent (session) naming

`claude --name` is **launch-only** — there is no runtime rename command and no
`/name` slash command. So the two paths differ:

- **In-session (the naming hook).** `set-agent-name.sh` writes the session's own
  state file, `~/.claude/sessions/<pid>.json` (`name`, `nameSource: explicit`),
  located from the hook's `session_id`. Verified rather than assumed: the owning
  process **preserves** an edited name across its own status rewrites, and the
  new name shows up as the addressable peer name in `ListAgents`. Caveat: the
  running session's prompt box keeps its original label until restart, since
  that UI is held in memory.
- **`cmux-agent` launches.** The name is known before `claude` starts, so it is
  passed as `--name` and needs no fixing up.

Both fail soft: a miss logs `set-agent-name: FAILED rc=3` and leaves the
workspace title correct. A brand-new directory is the usual cause — `claude`
blocks on its "do you trust this folder?" prompt and does not register a session
until that is answered.

## Troubleshooting

| Symptom | Cause |
|---|---|
| Nothing happens at all | `install.sh --doctor`. Most likely `MANAGED_REPOS` does not contain this checkout — the exact bug that silently disabled every hook here until 2026-09-11, when the path still pointed at another machine's home directory. |
| Pill never appears | `gh auth status`. An unauthenticated `gh pr view` returns nothing and the worker correctly does nothing. |
| Pill shows `PR #123` with no ticket | `TICKET_RE` does not match your branch prefix. |
| Pill links to GitHub, not Linear | `PR_LINK_TARGET=github`, or the repo is not in a Linear workspace with the GitHub integration. |
| Workspace not renamed | It already has a `<TICKET> <text>` title (deliberate), or the dedupe marker is set for that prompt, or `cwd` is outside `MANAGED_REPOS`. Before 2026-09-18, also: the `UserPromptSubmit` hook was never registered at all — `install.sh` fixes that. |
| Layout never restored | `install.sh --doctor`. Usually `CREX_LAYOUT` is empty or names a layout `crex list` does not have, or `~/.zshrc` does not load `crex-autorestore.sh`. The log carries crex's own error now; a `--force` flag it never had is what made the original version fail in silence. |
| Layout restored twice, or over a live session | Only possible with a stale lock in `/tmp/claude/cmux-integration` or `CREX_RESTORE_MODE=replace`. `add` never closes a workspace. |
| cmux settings did not import | cmux was running. Quit it and re-run `cmux-settings.sh import`. Until 2026-09-12 the guard that detects this was broken (see below) and the import reported success while landing nothing. |
| `cmux-agent` workspace appears then vanishes | The launch failed and the old unconditional `; exit` closed the pane over the error. Fixed: failures keep the workspace. The usual underlying cause is an untrusted directory — `install.sh --doctor` names it. |
| Statusline shows `Usage: ~` | Nothing is writing `.statusline-usage-cache`, or the script's swift fallback is gone or has no `fetch-claude-usage.swift` to call. All of it belongs to **Claude Usage.app**. See below. |
| Statusline has no colours | `COLOR_MODE=monochrome` in `statusline-config.txt`. Change it in the app's "Statusline Colors" panel, not by editing the file — the app overwrites it. |
| Statusline is blank | `statusLine.command` points at a path that does not exist on this machine. `install.sh` repoints it; `--doctor` reports it. |

Everything logs to `~/.claude/logs/cmux-integration.log`.

### The statusline is owned by Claude Usage.app — do not track it

`statusline-command.sh`, `statusline-config.txt`, `fetch-claude-usage.swift` and
`.statusline-usage-cache` are **generated and rewritten by
/Applications/Claude Usage.app**, not by this repo. Proof: 57 of 60 distinctive
code lines from `statusline-command.sh` appear verbatim inside the app binary,
which embeds the whole script twice.

All four are gitignored, because committing an app-generated file means a later
`git checkout` silently overwrites what the app just wrote — which is how the app
gets broken. `fetch-claude-usage.swift` additionally embeds an `sk-ant-sid…`
session token, so it must never reach a remote (verified absent from every blob
in this repo's history).

The usage percentage is not computed by the statusline. The script only *reads*
`.statusline-usage-cache` and shows `Usage: ~` when it is missing or older than
300s; the app writes that cache every 30s, and the script's
`fetch-claude-usage.swift` fallback covers the gap when the app is not running.
Leave that fallback in place — removing it is what makes usage disappear.

**Pulling onto a machine where these were still tracked will delete them**, since
git removes files that a commit untracks. Keep them across the pull:

```bash
cp ~/.claude/statusline-command.sh ~/.claude/statusline-config.txt /tmp/
git fetch && git reset --hard origin/main
cp /tmp/statusline-command.sh /tmp/statusline-config.txt ~/.claude/
~/.claude/cmux/install.sh
```

**Reopening Claude Usage.app does NOT reinstall them.** Its `StatuslineService`
installs on demand, not on launch, and it tracks that it already did
(`notch.hooks.status_installed`). If the files are lost, either:

- **change any option in the app's "Statusline Colors" settings panel** — the app
  then rewrites both files, and reinstalls `fetch-claude-usage.swift` with a fresh
  session key. This is the better path: git cannot restore that swift file, since
  it is gitignored and never committed; and edits you make to
  `statusline-config.txt` by hand are overwritten the next time the app writes it.
- or recover the script from this repo's history, which still holds the last
  tracked copy:

  ```bash
  git fetch origin
  git show origin/backup/other-laptop-20260912^:statusline-command.sh > ~/.claude/statusline-command.sh
  chmod +x ~/.claude/statusline-command.sh
  git show origin/backup/other-laptop-20260912^:statusline-config.txt  > ~/.claude/statusline-config.txt
  ```

A missing script leaves the status line blank, which is easy to misread as a
Claude Code problem. Do not reach for `/statusline` to fill the gap — it builds an
unrelated starship-based line and repoints `statusLine.command` at it, and
`install.sh` will not correct that, because it only repoints a path that fails to
resolve. Restore the app's script and set the command back by hand.

The same reset also deletes `skills/humly-intro` and `skills/tracey` on a machine
that still tracks them. That one is intentional — they were Humly-only, `tracey`
is covered by the vinga project skills `tracey-annotate` and `tracey-requirement`,
and nothing needs preserving.
`install.sh --doctor` reports a missing or hand-edited script.

`statusLine.command` is an absolute path on purpose. `~` expansion is verified to
work for `hooks`, but not for `statusLine`, so `install.sh` normalises the path
to the local `$HOME` at install time instead of relying on it.
