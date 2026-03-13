#!/bin/sh
input=$(cat)

cwd=$(echo "$input" | jq -r '.cwd // .workspace.current_dir // empty')
model=$(echo "$input" | jq -r '.model.display_name // empty')
used=$(echo "$input" | jq -r '.context_window.used_percentage // empty')

# Shorten the path: replace $HOME with ~
home="$HOME"
short_cwd="${cwd/#$home/~}"

# Get git branch (skip optional locks to avoid blocking)
git_branch=""
if [ -n "$cwd" ] && git -C "$cwd" rev-parse --git-dir > /dev/null 2>&1; then
    git_branch=$(git -C "$cwd" symbolic-ref --short HEAD 2>/dev/null || git -C "$cwd" rev-parse --short HEAD 2>/dev/null)
fi

# Build the status line using ANSI colors (dimmed-friendly)
reset='\033[0m'
blue='\033[0;34m'
green='\033[0;32m'
cyan='\033[0;36m'
yellow='\033[0;33m'

parts=""

# Directory
parts="${parts}$(printf "${blue}${short_cwd}${reset}")"

# Git branch
if [ -n "$git_branch" ]; then
    parts="${parts} $(printf "${green}(${git_branch})${reset}")"
fi

# Model
if [ -n "$model" ]; then
    parts="${parts} $(printf "${cyan}[${model}]${reset}")"
fi

# Context usage
if [ -n "$used" ]; then
    used_int=$(printf "%.0f" "$used")
    if [ "$used_int" -ge 80 ]; then
        ctx_color="$yellow"
    else
        ctx_color="$cyan"
    fi
    parts="${parts} $(printf "${ctx_color}ctx:${used_int}%%${reset}")"
fi

printf "%b\n" "$parts"
