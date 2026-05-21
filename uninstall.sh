#!/usr/bin/env bash
# agent-gates uninstaller
# Removes hooks, skill files, and platform registrations.
# Usage: ./uninstall.sh [--keep-skills] [--purge-backups]

set -euo pipefail

INSTALL_DIR="$HOME/.agent-gates"
KEEP_SKILLS=0
PURGE_BACKUPS=0

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

info()  { echo -e "${GREEN}✓${NC} $1"; }
warn()  { echo -e "${YELLOW}⚠${NC} $1"; }
section() { echo -e "\n${BLUE}━━━${NC} $1"; }

SKILLS=(init-project-gates agent-workflow-rules agent-review-protocol)
SKILL_DIRS=(
  "$HOME/.cc-switch/skills"
  "$HOME/.claude/skills"
  "$HOME/.config/opencode/skills"
  "$HOME/.codex/skills"
)

remove_hook_entry() {
  local hooks_file="$1"
  local platform="$2"

  [[ -f "$hooks_file" ]] || return

  if ! grep -q "memory-reminder.mjs" "$hooks_file" 2>/dev/null; then
    info "$platform: no agent-gates hook found"
    return
  fi

  if command -v jq &>/dev/null; then
    jq '
      .PostToolUse = [.PostToolUse[] | select(.hooks | all(.command | test("memory-reminder") | not))]
      | if .PostToolUse | length == 0 then del(.PostToolUse) else . end
    ' "$hooks_file" > "${hooks_file}.tmp" && mv "${hooks_file}.tmp" "$hooks_file"

    if jq -e 'keys | length == 0' "$hooks_file" &>/dev/null; then
      rm -f "$hooks_file"
      info "$platform: removed empty $hooks_file"
    else
      info "$platform: removed hook entry from $hooks_file"
    fi
  else
    warn "$platform: jq not found. Manually remove memory-reminder entry from $hooks_file"
  fi
}

remove_skills() {
  section "Removing skills"
  local removed=0

  for dir in "${SKILL_DIRS[@]}"; do
    [[ -d "$dir" ]] || continue
    for skill in "${SKILLS[@]}"; do
      local target="$dir/$skill"
      if [[ -L "$target" ]]; then
        rm -f "$target"
        info "Removed symlink: $target"
        ((removed++))
      elif [[ -d "$target" ]]; then
        rm -rf "$target"
        info "Removed: $target"
        ((removed++))
      fi
    done
  done
  info "Removed $removed skill entries"
}

purge_backups() {
  section "Purging SKILL.md.bak.* backups"
  local removed=0

  for dir in "${SKILL_DIRS[@]}"; do
    [[ -d "$dir" ]] || continue
    for skill in "${SKILLS[@]}"; do
      local skill_dir="$dir/$skill"
      [[ -d "$skill_dir" ]] || continue
      while IFS= read -r -d '' bak; do
        rm -f "$bak"
        info "Removed: $bak"
        ((removed++))
      done < <(find "$skill_dir" -maxdepth 1 -name 'SKILL.md.bak.*' -print0 2>/dev/null)
    done
  done

  if (( removed == 0 )); then
    info "No backup files found"
  else
    info "Purged $removed backup file(s)"
  fi
}

main() {
  echo -e "${BLUE}╔══════════════════════════════════╗${NC}"
  echo -e "${BLUE}║${NC}   Agent Gates Uninstaller v1.1   ${BLUE}║${NC}"
  echo -e "${BLUE}╚══════════════════════════════════╝${NC}"
  echo ""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --keep-skills) KEEP_SKILLS=1; shift ;;
      --purge-backups) PURGE_BACKUPS=1; shift ;;
      -h|--help)
        echo "Usage: uninstall.sh [--keep-skills] [--purge-backups]"
        echo "  --keep-skills     Keep installed skills, remove only hooks"
        echo "  --purge-backups   Also remove SKILL.md.bak.* files created during upgrades"
        exit 0
        ;;
      *) echo "Unknown option: $1"; exit 1 ;;
    esac
  done

  section "Removing platform hook registrations"
  remove_hook_entry "$HOME/.claude/hooks.json" "OMC (Claude Code)"
  remove_hook_entry "$HOME/.config/opencode/hooks.json" "OMO (OpenCode)"
  remove_hook_entry "$HOME/.codex/hooks.json" "OMX (Codex)"

  if [[ "$PURGE_BACKUPS" -eq 1 ]]; then
    purge_backups
  fi

  if [[ "$KEEP_SKILLS" -eq 0 ]]; then
    remove_skills
  else
    warn "Keeping skills (--keep-skills)"
  fi

  section "Removing hook files"
  if [[ -d "$INSTALL_DIR" ]]; then
    rm -rf "$INSTALL_DIR"
    info "Removed: $INSTALL_DIR"
  else
    info "Not found: $INSTALL_DIR (already clean)"
  fi

  section "Done!"
  echo ""
  echo "  agent-gates has been removed."
  if [[ "$PURGE_BACKUPS" -eq 0 ]]; then
    echo "  SKILL.md.bak.* files (if any) are preserved; pass --purge-backups to also remove them."
  fi
  echo "  Project-level .agent/ directories are preserved (remove manually if needed)."
  echo ""
}

main "$@"
