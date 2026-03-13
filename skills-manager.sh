#!/usr/bin/env bash
# skills — Claude Code skills manager
# Usage: skills <command>
#   skills list              List all active skills
#   skills list-disabled     List all disabled skills
#   skills list-team         List skills available from the team remote
#   skills add <name>        Pull a skill from the team remote
#   skills share <name>      Propose a personal skill to the team remote (opens PR)
#   skills disable <name>    Move a skill to skills-disabled/
#   skills enable <name>     Move a skill back from skills-disabled/

set -euo pipefail

CLAUDE_DIR="${HOME}/.claude"
SKILLS_DIR="${CLAUDE_DIR}/skills"
DISABLED_DIR="${CLAUDE_DIR}/skills-disabled"
TEAM_REMOTE="team"
TEAM_BRANCH="main"

# ── Helpers ──────────────────────────────────────────────────────────────────

die() { echo "error: $*" >&2; exit 1; }

require_claude_dir() {
  [[ -d "$CLAUDE_DIR" ]] || die "~/.claude not found"
  [[ -d "$SKILLS_DIR" ]] || mkdir -p "$SKILLS_DIR"
  [[ -d "$DISABLED_DIR" ]] || mkdir -p "$DISABLED_DIR"
}

require_git() {
  git -C "$CLAUDE_DIR" rev-parse --git-dir &>/dev/null \
    || die "~/.claude is not a git repository"
}

require_team_remote() {
  git -C "$CLAUDE_DIR" remote get-url "$TEAM_REMOTE" &>/dev/null \
    || die "No remote named '${TEAM_REMOTE}'. Add it with: git remote add team <url>"
}

skill_name() {
  local skill_dir="$1"
  local frontmatter_name
  frontmatter_name=$(grep -m1 '^name:' "${skill_dir}/SKILL.md" 2>/dev/null \
    | sed 's/^name:[[:space:]]*//' | tr -d '[:space:]')
  echo "${frontmatter_name:-$(basename "$skill_dir")}"
}

# ── Commands ─────────────────────────────────────────────────────────────────

cmd_list() {
  require_claude_dir
  echo "Active skills:"
  local found=0
  for dir in "${SKILLS_DIR}"/*/; do
    [[ -f "${dir}SKILL.md" ]] || continue
    echo "  $(skill_name "$dir")"
    found=1
  done
  [[ $found -eq 1 ]] || echo "  (none)"
}

cmd_list_disabled() {
  require_claude_dir
  echo "Disabled skills:"
  local found=0
  for dir in "${DISABLED_DIR}"/*/; do
    [[ -f "${dir}SKILL.md" ]] || continue
    echo "  $(skill_name "$dir")"
    found=1
  done
  [[ $found -eq 1 ]] || echo "  (none)"
}

cmd_list_team() {
  require_claude_dir
  require_git
  require_team_remote

  echo "Fetching from team remote..."
  git -C "$CLAUDE_DIR" fetch "$TEAM_REMOTE" --quiet

  echo ""
  echo "Team skills (${TEAM_REMOTE}/${TEAM_BRANCH}):"

  local team_skills
  team_skills=$(git -C "$CLAUDE_DIR" ls-tree --name-only "${TEAM_REMOTE}/${TEAM_BRANCH}" skills/ \
    2>/dev/null | sed 's|skills/||')

  [[ -n "$team_skills" ]] || { echo "  (none found)"; return; }

  while IFS= read -r name; do
    [[ -z "$name" ]] && continue
    if [[ -d "${SKILLS_DIR}/${name}" ]]; then
      echo "  ${name}  (already added)"
    elif [[ -d "${DISABLED_DIR}/${name}" ]]; then
      echo "  ${name}  (disabled)"
    else
      echo "  ${name}"
    fi
  done <<< "$team_skills"
}

cmd_add() {
  local name="${1:-}"
  [[ -n "$name" ]] || die "Usage: skills add <name>"

  require_claude_dir
  require_git
  require_team_remote

  [[ -d "${SKILLS_DIR}/${name}" ]] && die "'${name}' is already in your skills"

  echo "Fetching from team remote..."
  git -C "$CLAUDE_DIR" fetch "$TEAM_REMOTE" --quiet

  git -C "$CLAUDE_DIR" ls-tree --name-only "${TEAM_REMOTE}/${TEAM_BRANCH}" "skills/${name}/" \
    &>/dev/null || die "'${name}' not found on ${TEAM_REMOTE}/${TEAM_BRANCH}"

  echo "Adding skill '${name}'..."
  git -C "$CLAUDE_DIR" checkout "${TEAM_REMOTE}/${TEAM_BRANCH}" -- "skills/${name}/"
  git -C "$CLAUDE_DIR" add "skills/${name}/"
  git -C "$CLAUDE_DIR" commit -m "chore: add team skill ${name}"

  echo "Done. '${name}' is now active."
}

cmd_share() {
  local name="${1:-}"
  [[ -n "$name" ]] || die "Usage: skills share <name>"

  require_claude_dir
  require_git
  require_team_remote

  [[ -d "${SKILLS_DIR}/${name}" ]] || die "'${name}' not found in skills/"
  [[ -f "${SKILLS_DIR}/${name}/SKILL.md" ]] || die "'${name}/SKILL.md' not found"

  local branch="skill/${name}"
  local current_branch
  current_branch=$(git -C "$CLAUDE_DIR" rev-parse --abbrev-ref HEAD)

  echo "Fetching from team remote..."
  git -C "$CLAUDE_DIR" fetch "$TEAM_REMOTE" --quiet

  if git -C "$CLAUDE_DIR" ls-tree --name-only "${TEAM_REMOTE}/${TEAM_BRANCH}" "skills/${name}/" \
      &>/dev/null; then
    die "'${name}' already exists on ${TEAM_REMOTE}/${TEAM_BRANCH}"
  fi

  echo "Creating branch '${branch}' from ${TEAM_REMOTE}/${TEAM_BRANCH}..."
  git -C "$CLAUDE_DIR" checkout -b "$branch" "${TEAM_REMOTE}/${TEAM_BRANCH}"

  cp -r "${SKILLS_DIR}/${name}" "${CLAUDE_DIR}/skills/${name}"
  git -C "$CLAUDE_DIR" add "skills/${name}/"
  git -C "$CLAUDE_DIR" commit -m "chore: add skill ${name}"

  echo "Pushing branch to team remote..."
  git -C "$CLAUDE_DIR" push "$TEAM_REMOTE" "$branch"

  git -C "$CLAUDE_DIR" checkout "$current_branch"

  if command -v gh &>/dev/null; then
    local team_repo
    team_repo=$(git -C "$CLAUDE_DIR" remote get-url "$TEAM_REMOTE" \
      | sed 's/.*github.com[:/]//' | sed 's/\.git$//')
    echo ""
    echo "Opening PR on ${team_repo}..."
    gh pr create \
      --repo "$team_repo" \
      --head "$branch" \
      --base "$TEAM_BRANCH" \
      --title "Add skill: ${name}" \
      --body "Sharing the \`${name}\` skill from personal config."
  else
    echo ""
    echo "Push complete. Open a PR on the team repo to get it merged:"
    local team_url
    team_url=$(git -C "$CLAUDE_DIR" remote get-url "$TEAM_REMOTE" | sed 's/\.git$//')
    echo "  ${team_url}/compare/${branch}"
  fi
}

cmd_disable() {
  local name="${1:-}"
  [[ -n "$name" ]] || die "Usage: skills disable <name>"

  require_claude_dir
  require_git

  [[ -d "${SKILLS_DIR}/${name}" ]] || die "'${name}' not found in skills/"
  [[ -d "${DISABLED_DIR}/${name}" ]] && die "'${name}' is already in skills-disabled/"

  mv "${SKILLS_DIR}/${name}" "${DISABLED_DIR}/${name}"
  git -C "$CLAUDE_DIR" add -A
  git -C "$CLAUDE_DIR" commit -m "chore: disable skill ${name}"

  echo "Disabled '${name}'."
}

cmd_enable() {
  local name="${1:-}"
  [[ -n "$name" ]] || die "Usage: skills enable <name>"

  require_claude_dir
  require_git

  [[ -d "${DISABLED_DIR}/${name}" ]] || die "'${name}' not found in skills-disabled/"
  [[ -d "${SKILLS_DIR}/${name}" ]] && die "'${name}' already exists in skills/"

  mv "${DISABLED_DIR}/${name}" "${SKILLS_DIR}/${name}"
  git -C "$CLAUDE_DIR" add -A
  git -C "$CLAUDE_DIR" commit -m "chore: enable skill ${name}"

  echo "Enabled '${name}'."
}

cmd_help() {
  echo "Usage: skills <command>"
  echo ""
  echo "Commands:"
  echo "  list              List active skills"
  echo "  list-disabled     List disabled skills"
  echo "  list-team         List skills available from the team remote"
  echo "  add <name>        Pull a skill from the team remote"
  echo "  share <name>      Propose a personal skill to the team remote (opens PR)"
  echo "  disable <name>    Move a skill to skills-disabled/"
  echo "  enable <name>     Move a skill back from skills-disabled/"
}

# ── Dispatch ─────────────────────────────────────────────────────────────────

case "${1:-}" in
  list)           cmd_list ;;
  list-disabled)  cmd_list_disabled ;;
  list-team)      cmd_list_team ;;
  add)            cmd_add "${2:-}" ;;
  share)          cmd_share "${2:-}" ;;
  disable)        cmd_disable "${2:-}" ;;
  enable)         cmd_enable "${2:-}" ;;
  help|--help|-h) cmd_help ;;
  *)              cmd_help; exit 1 ;;
esac
