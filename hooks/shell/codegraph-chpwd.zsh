#!/usr/bin/env zsh
# codegraph-chpwd.zsh — Auto-init CodeGraph index when entering a git repo.
# Source this file from ~/.zshrc (the install.sh installer does this for you).
#
# Config (env vars, set in ~/.zshrc before sourcing):
#   AGENT_GATES_CODEGRAPH_AUTO_INIT=1   — opt-in (required)
#   AGENT_GATES_CODEGRAPH_DIRS           — colon-separated allowed roots
#                                          (default: ~/Projects:~/wb/projects)
#   AGENT_GATES_CODEGRAPH_LOCKDIR        — lock file dir (default: /tmp)

# Decision function: returns 0 if codegraph init should run, 1 otherwise.
# Designed to be testable from bash (no zsh-specific syntax inside).
_agent_gates_codegraph_should_init() {
  [[ "${AGENT_GATES_CODEGRAPH_AUTO_INIT:-0}" == "1" ]] || return 1

  command -v codegraph &>/dev/null || return 1

  [[ -d .git || -f .git ]] || return 1

  [[ -d .codegraph ]] && return 1

  local allowed_dirs="${AGENT_GATES_CODEGRAPH_DIRS:-$HOME/Projects:$HOME/wb/projects}"
  local pwd_resolved
  pwd_resolved="$(pwd -P)"
  local in_allowed=0
  local remaining="$allowed_dirs"
  while [[ -n "$remaining" ]]; do
    local dir="${remaining%%:*}"
    if [[ "$remaining" == *:* ]]; then
      remaining="${remaining#*:}"
    else
      remaining=""
    fi
    local dir_resolved
    dir_resolved="$(cd "$dir" 2>/dev/null && pwd -P)" || continue
    case "$pwd_resolved" in
      "$dir_resolved"/*|"$dir_resolved") in_allowed=1; break ;;
    esac
  done
  [[ "$in_allowed" -eq 1 ]] || return 1

  local lockdir="${AGENT_GATES_CODEGRAPH_LOCKDIR:-/tmp}"
  local repo_hash
  repo_hash=$(echo -n "$pwd_resolved" | md5 2>/dev/null || echo -n "$pwd_resolved" | md5sum 2>/dev/null | cut -d' ' -f1)
  local lockpath="$lockdir/codegraph-init-${repo_hash}.lock"
  mkdir "$lockpath" 2>/dev/null || return 1

  return 0
}

_agent_gates_codegraph_chpwd() {
  _agent_gates_codegraph_should_init || return

  local pwd_resolved lockdir repo_hash lockpath
  pwd_resolved="$(pwd -P)"
  lockdir="${AGENT_GATES_CODEGRAPH_LOCKDIR:-/tmp}"
  repo_hash=$(echo -n "$pwd_resolved" | md5 2>/dev/null || echo -n "$pwd_resolved" | md5sum 2>/dev/null | cut -d' ' -f1)
  lockpath="$lockdir/codegraph-init-${repo_hash}.lock"

  (
    codegraph init -i 2>/dev/null
    rmdir "$lockpath" 2>/dev/null
  ) &>/dev/null &
  disown 2>/dev/null
}

autoload -Uz add-zsh-hook
add-zsh-hook chpwd _agent_gates_codegraph_chpwd
