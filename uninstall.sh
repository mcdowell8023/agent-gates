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
  local config_file="$1"
  local platform="$2"

  # ⚠️ 必须 `return 0`：裸 `return` 沿用上一条 [[ ]] 的失败状态，set -e 下整个卸载在第一个
  #    不存在的配置文件处就退出了（没装 Claude Code 的机器上卸载什么都不做，v2.11.0 发现）。
  [[ -f "$config_file" ]] || return 0

  if ! grep -q "memory-reminder.mjs" "$config_file" 2>/dev/null; then
    info "$platform: no agent-gates hook found"
    return
  fi

  if ! command -v jq &>/dev/null; then
    warn "$platform: jq not found. Manually remove memory-reminder entry from $config_file"
    return
  fi

  # Remove our hook from both schemas:
  # 1. .hooks.PostToolUse[] — current schema (v1.1.2+) used by OMC settings.json + OMX hooks.json
  # 2. .PostToolUse[]       — legacy schema (v1.0.0–v1.1.1) at ~/.claude/hooks.json root level
  # Then collapse: empty arrays → del key; empty .hooks → del .hooks.
  # Never delete other top-level keys (settings.json may contain model/permissions/theme/etc.).
  if jq '
    (if .hooks.PostToolUse then
       .hooks.PostToolUse = [.hooks.PostToolUse[] | select(.hooks | all(.command | test("memory-reminder") | not))]
       | if .hooks.PostToolUse | length == 0 then .hooks |= del(.PostToolUse) else . end
     else . end)
    | (if .PostToolUse then
         .PostToolUse = [.PostToolUse[] | select(.hooks | all(.command | test("memory-reminder") | not))]
         | if .PostToolUse | length == 0 then del(.PostToolUse) else . end
       else . end)
    | (if (.hooks // {}) == {} then del(.hooks) else . end)
  ' "$config_file" > "${config_file}.tmp"; then
    mv "${config_file}.tmp" "$config_file"
  else
    rm -f "${config_file}.tmp"
    warn "$platform: jq failed to parse $config_file — manually remove memory-reminder entry"
    return
  fi

  # Only remove the file outright if it ended up completely empty (dedicated
  # hooks.json case). Settings.json with other keys is preserved.
  if jq -e 'keys | length == 0' "$config_file" &>/dev/null; then
    rm -f "$config_file"
    info "$platform: removed empty $config_file"
  else
    info "$platform: removed hook entry from $config_file"
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

  # v2.11.0：备份移到了 $INSTALL_DIR/backups/skills/（不再放在 skill 目录里）
  if [[ -d "$INSTALL_DIR/backups/skills" ]]; then
    while IFS= read -r -d '' bak; do
      rm -f "$bak"
      info "Removed: $bak"
      removed=$((removed + 1))
    done < <(find "$INSTALL_DIR/backups/skills" -type f -print0 2>/dev/null)
    rm -rf "$INSTALL_DIR/backups/skills"
  fi

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
  remove_hook_entry "$HOME/.claude/settings.json" "OMC (Claude Code)"
  remove_hook_entry "$HOME/.claude/hooks.json" "OMC (legacy hooks.json)"
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
  if [[ -d "$INSTALL_DIR" && "$PURGE_BACKUPS" -eq 0 && -n "$(find "$INSTALL_DIR/backups" -type f -print -quit 2>/dev/null)" ]]; then
    # v2.11.0：备份在 $INSTALL_DIR/backups/ 里，不带 --purge-backups 就要留住（说好了保留）。
    find "$INSTALL_DIR" -mindepth 1 -maxdepth 1 ! -name backups -exec rm -rf {} +
    info "Removed: $INSTALL_DIR (kept $INSTALL_DIR/backups/ — pass --purge-backups to remove it)"
  elif [[ -d "$INSTALL_DIR" ]]; then
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
