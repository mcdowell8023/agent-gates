#!/usr/bin/env bash
# agent-toolkit installer
# Detects agent platform and installs skills to the correct location.
# Usage: curl -fsSL https://raw.githubusercontent.com/mcdowell8023/agent-toolkit/main/install.sh | bash
# Or: ./install.sh [--target DIR]

set -euo pipefail

REPO_URL="https://github.com/mcdowell8023/agent-toolkit"
REPO_DIR=""
TARGET_DIR=""
SKILLS=(init-project-gates agent-workflow-rules agent-review-protocol)

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info()  { echo -e "${GREEN}✓${NC} $1"; }
warn()  { echo -e "${YELLOW}⚠${NC} $1"; }
fail()  { echo -e "${RED}✗${NC} $1" >&2; exit 1; }

# --- Detect platform ---
detect_platform() {
  # Priority: explicit --target > cc-switch > Claude Code > OpenCode > Codex

  if [[ -n "$TARGET_DIR" ]]; then
    info "Using explicit target: $TARGET_DIR"
    return
  fi

  if [[ -d "$HOME/.cc-switch/skills" ]]; then
    TARGET_DIR="$HOME/.cc-switch/skills"
    info "Detected: cc-switch ($TARGET_DIR)"
    return
  fi

  if [[ -d "$HOME/.claude/skills" ]]; then
    TARGET_DIR="$HOME/.claude/skills"
    info "Detected: Claude Code ($TARGET_DIR)"
    return
  fi

  if [[ -d "$HOME/.config/opencode/skills" ]]; then
    TARGET_DIR="$HOME/.config/opencode/skills"
    info "Detected: OpenCode ($TARGET_DIR)"
    return
  fi

  if [[ -d "$HOME/.codex/skills" ]]; then
    TARGET_DIR="$HOME/.codex/skills"
    info "Detected: Codex ($TARGET_DIR)"
    return
  fi

  # Fallback: create Claude Code skills dir
  TARGET_DIR="$HOME/.claude/skills"
  warn "No agent platform detected. Using default: $TARGET_DIR"
  mkdir -p "$TARGET_DIR"
}

# --- Clone or update repo ---
fetch_repo() {
  local tmp_dir
  tmp_dir=$(mktemp -d)
  REPO_DIR="$tmp_dir/agent-toolkit"

  if command -v git &>/dev/null; then
    git clone --depth 1 "$REPO_URL.git" "$REPO_DIR" 2>/dev/null || \
      fail "Failed to clone $REPO_URL. Check network and permissions."
  else
    # Fallback: download tarball
    curl -fsSL "$REPO_URL/archive/refs/heads/main.tar.gz" | tar -xz -C "$tmp_dir"
    REPO_DIR="$tmp_dir/agent-toolkit-main"
  fi

  [[ -d "$REPO_DIR/skills" ]] || fail "Invalid repo structure: skills/ not found"
}

# --- Install skills ---
install_skills() {
  local installed=0
  local skipped=0

  for skill in "${SKILLS[@]}"; do
    local src="$REPO_DIR/skills/$skill"
    local dst="$TARGET_DIR/$skill"

    if [[ ! -d "$src" ]]; then
      warn "Skill not found in repo: $skill (skipped)"
      ((skipped++))
      continue
    fi

    if [[ -d "$dst" ]]; then
      # Update: overwrite SKILL.md, preserve custom files
      cp "$src/SKILL.md" "$dst/SKILL.md"
      # Copy templates if they exist
      if [[ -d "$src/templates" ]]; then
        mkdir -p "$dst/templates"
        cp -R "$src/templates/"* "$dst/templates/" 2>/dev/null || true
      fi
      info "Updated: $skill"
    else
      cp -R "$src" "$dst"
      info "Installed: $skill"
    fi
    ((installed++))
  done

  echo ""
  info "Done! $installed skills installed/updated, $skipped skipped."
  echo ""
  echo "  Target: $TARGET_DIR"
  echo ""
  echo "  Skills installed:"
  for skill in "${SKILLS[@]}"; do
    [[ -d "$TARGET_DIR/$skill" ]] && echo "    - $skill"
  done
}

# --- Symlink to other platforms (cc-switch mode) ---
create_symlinks() {
  # Only if installed to cc-switch, also symlink to other platforms
  if [[ "$TARGET_DIR" == "$HOME/.cc-switch/skills" ]]; then
    local dirs=("$HOME/.claude/skills" "$HOME/.config/opencode/skills" "$HOME/.codex/skills")
    for dir in "${dirs[@]}"; do
      [[ -d "$dir" ]] || continue
      for skill in "${SKILLS[@]}"; do
        local src="$TARGET_DIR/$skill"
        local dst="$dir/$skill"
        [[ -d "$src" ]] || continue
        [[ -L "$dst" || ! -e "$dst" ]] && ln -sf "$src" "$dst" 2>/dev/null && \
          info "Symlinked: $dst → $src"
      done
    done
  fi
}

# --- Cleanup ---
cleanup() {
  [[ -n "$REPO_DIR" ]] && rm -rf "$(dirname "$REPO_DIR")" 2>/dev/null || true
}
trap cleanup EXIT

# --- Main ---
main() {
  echo "🛠  Agent Toolkit Installer"
  echo ""

  # Parse args
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --target) TARGET_DIR="$2"; shift 2 ;;
      *) fail "Unknown option: $1" ;;
    esac
  done

  detect_platform
  fetch_repo
  install_skills
  create_symlinks

  echo ""
  echo "  Next steps:"
  echo "    1. Open a project and tell your agent: '初始化项目' or 'init project gates'"
  echo "    2. The agent will load init-project-gates and set up .agent/ + hooks"
  echo "    3. agent-workflow-rules auto-loads when writing code (TDD, verification, etc.)"
  echo ""
}

main "$@"
