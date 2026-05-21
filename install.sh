#!/usr/bin/env bash
# agent-gates installer
# Detects agent platforms, installs skills + registers platform hooks.
# Usage: curl -fsSL https://raw.githubusercontent.com/mcdowell8023/agent-gates/main/install.sh | bash
# Or: ./install.sh [--target DIR] [--skip-hooks]

set -euo pipefail

REPO_URL="https://github.com/mcdowell8023/agent-gates"
REPO_DIR=""
TARGET_DIR=""
INSTALL_DIR="$HOME/.agent-gates"

if [[ "$INSTALL_DIR" == *" "* ]]; then
  echo "Error: Install path contains spaces: $INSTALL_DIR" >&2
  echo "agent-gates requires a space-free \$HOME path." >&2
  exit 1
fi
SKILLS=(init-project-gates agent-workflow-rules agent-review-protocol)
SKIP_HOOKS=0
FORCE=0

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

info()  { echo -e "${GREEN}✓${NC} $1"; }
warn()  { echo -e "${YELLOW}⚠${NC} $1"; }
fail()  { echo -e "${RED}✗${NC} $1" >&2; exit 1; }
section() { echo -e "\n${BLUE}━━━${NC} $1"; }

# --- Version check ---
check_version() {
  [[ "$FORCE" -eq 1 ]] && return

  local installed_version=""
  if [[ -f "$INSTALL_DIR/.version" ]]; then
    installed_version=$(cat "$INSTALL_DIR/.version" | tr -d '[:space:]')
  fi

  if [[ -z "$installed_version" ]]; then
    return
  fi

  local repo_version=""
  if [[ -f "$REPO_DIR/.version" ]]; then
    repo_version=$(cat "$REPO_DIR/.version" | tr -d '[:space:]')
  fi

  if [[ "$installed_version" == "$repo_version" ]]; then
    info "Already at version $installed_version (use --force to reinstall)"
    exit 0
  fi

  info "Upgrading: $installed_version → $repo_version"
}

# --- Detect platform ---
detect_platform() {
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

  TARGET_DIR="$HOME/.claude/skills"
  warn "No agent platform detected. Using default: $TARGET_DIR"
  mkdir -p "$TARGET_DIR"
}

# --- Clone or update repo ---
fetch_repo() {
  local tmp_dir
  tmp_dir=$(mktemp -d)
  REPO_DIR="$tmp_dir/agent-gates"

  if command -v git &>/dev/null; then
    git clone --depth 1 "$REPO_URL.git" "$REPO_DIR" 2>/dev/null || \
      fail "Failed to clone $REPO_URL. Check network and permissions."
  else
    curl -fsSL "$REPO_URL/archive/refs/heads/main.tar.gz" | tar -xz -C "$tmp_dir"
    REPO_DIR="$tmp_dir/agent-gates-main"
  fi

  [[ -d "$REPO_DIR/skills" ]] || fail "Invalid repo structure: skills/ not found"
}

# --- Install skills ---
install_skills() {
  section "Installing skills → $TARGET_DIR"
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
      cp "$src/SKILL.md" "$dst/SKILL.md"
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

  info "$installed skills installed/updated, $skipped skipped"
}

# --- Symlink to other platforms (cc-switch mode) ---
create_symlinks() {
  if [[ "$TARGET_DIR" == "$HOME/.cc-switch/skills" ]]; then
    section "Creating platform symlinks"
    local dirs=("$HOME/.claude/skills" "$HOME/.config/opencode/skills" "$HOME/.codex/skills")
    for dir in "${dirs[@]}"; do
      [[ -d "$dir" ]] || continue
      for skill in "${SKILLS[@]}"; do
        local src="$TARGET_DIR/$skill"
        local dst="$dir/$skill"
        [[ -d "$src" ]] || continue
        [[ -L "$dst" || ! -e "$dst" ]] && ln -sf "$src" "$dst" 2>/dev/null && \
          info "Symlinked: $dst"
      done
    done
  fi
}

# --- Install hooks to ~/.agent-gates ---
install_hook_files() {
  section "Installing hook files → $INSTALL_DIR"
  mkdir -p "$INSTALL_DIR/hooks/platform" "$INSTALL_DIR/hooks/git"

  cp "$REPO_DIR/hooks/platform/memory-reminder.mjs" "$INSTALL_DIR/hooks/platform/memory-reminder.mjs"
  cp "$REPO_DIR/hooks/git/agent-quality-gate.sh" "$INSTALL_DIR/hooks/git/agent-quality-gate.sh"
  chmod +x "$INSTALL_DIR/hooks/git/agent-quality-gate.sh"
  cp "$REPO_DIR/.version" "$INSTALL_DIR/.version" 2>/dev/null || true

  info "Installed: memory-reminder.mjs"
  info "Installed: agent-quality-gate.sh"
}

# --- Register platform hooks ---
register_platform_hooks() {
  [[ "$SKIP_HOOKS" -eq 1 ]] && { warn "Skipping platform hook registration (--skip-hooks)"; return; }

  section "Registering platform hooks"

  local hook_cmd="node $INSTALL_DIR/hooks/platform/memory-reminder.mjs"
  local hook_entry="{\"type\":\"command\",\"command\":\"$hook_cmd\",\"timeout\":5}"
  local post_tool_entry="{\"matcher\":\"TodoWrite|todowrite\",\"hooks\":[$hook_entry]}"

  # OMC: ~/.claude/hooks.json (if Claude Code installed)
  if [[ -d "$HOME/.claude" ]]; then
    register_hook_json "$HOME/.claude/hooks.json" "OMC (Claude Code)"
  fi

  # OMO: OpenCode can read from ~/.claude/hooks.json (shared with OMC)
  # OR from its own override path ~/.config/opencode/hooks.json
  if [[ -d "$HOME/.config/opencode" ]]; then
    local omo_hooks="$HOME/.config/opencode/hooks.json"
    if [[ -f "$omo_hooks" ]]; then
      # Override exists — register there too
      register_hook_json "$omo_hooks" "OMO (OpenCode override)"
    elif [[ ! -d "$HOME/.claude" ]]; then
      # No OMC detected, OMO standalone — create OMO-specific hooks
      register_hook_json "$omo_hooks" "OMO (OpenCode)"
    fi
    # else: OMC hooks.json already handles OMO (shared path)
  fi

  # OMX: ~/.codex/hooks.json (if Codex installed)
  if [[ -d "$HOME/.codex" ]]; then
    register_hook_json "$HOME/.codex/hooks.json" "OMX (Codex)"
  fi
}

register_hook_json() {
  local hooks_file="$1"
  local platform="$2"
  local hook_cmd="node $INSTALL_DIR/hooks/platform/memory-reminder.mjs"

  # Check if already registered (idempotent)
  if [[ -f "$hooks_file" ]] && grep -q "memory-reminder.mjs" "$hooks_file" 2>/dev/null; then
    info "$platform: already registered"
    return
  fi

  if [[ ! -f "$hooks_file" ]]; then
    # Create new hooks.json
    cat > "$hooks_file" << EOF
{
  "PostToolUse": [
    {
      "matcher": "TodoWrite|todowrite",
      "hooks": [
        {
          "type": "command",
          "command": "$hook_cmd",
          "timeout": 5
        }
      ]
    }
  ]
}
EOF
    info "$platform: created $hooks_file"
  elif command -v jq &>/dev/null; then
    # Idempotent merge via jq: append our PostToolUse entry without clobbering existing hooks
    jq --arg cmd "$hook_cmd" '
      .PostToolUse = ((.PostToolUse // []) + [{
        "matcher": "TodoWrite|todowrite",
        "hooks": [{"type": "command", "command": $cmd, "timeout": 5}]
      }])
    ' "$hooks_file" > "${hooks_file}.tmp" && mv "${hooks_file}.tmp" "$hooks_file"
    info "$platform: merged into existing $hooks_file"
  else
    # No jq available — provide manual instructions
    warn "$platform: $hooks_file exists but jq not found for safe merge."
    echo "    Install jq and re-run, or add manually:"
    echo "    PostToolUse → matcher: \"TodoWrite|todowrite\" → command: \"$hook_cmd\""
    echo "    See: docs/platform-hooks.md"
  fi
}

# --- Cleanup ---
cleanup() {
  [[ -n "$REPO_DIR" ]] && rm -rf "$(dirname "$REPO_DIR")" 2>/dev/null || true
}
trap cleanup EXIT

# --- Main ---
main() {
  echo -e "${BLUE}╔══════════════════════════════════╗${NC}"
  echo -e "${BLUE}║${NC}    Agent Gates Installer v1.1    ${BLUE}║${NC}"
  echo -e "${BLUE}╚══════════════════════════════════╝${NC}"
  echo ""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --target) TARGET_DIR="$2"; shift 2 ;;
      --skip-hooks) SKIP_HOOKS=1; shift ;;
      --force) FORCE=1; shift ;;
      *) fail "Unknown option: $1" ;;
    esac
  done

  detect_platform
  fetch_repo
  check_version
  install_skills
  create_symlinks
  install_hook_files
  register_platform_hooks

  section "Done!"
  echo ""
  echo "  Skills:  $TARGET_DIR/"
  for skill in "${SKILLS[@]}"; do
    [[ -d "$TARGET_DIR/$skill" ]] && echo "           └─ $skill"
  done
  echo ""
  echo "  Hooks:   $INSTALL_DIR/hooks/"
  echo "           ├─ git/agent-quality-gate.sh"
  echo "           └─ platform/memory-reminder.mjs"
  echo ""
  echo "  Next steps:"
  echo "    1. In any project: tell agent '初始化项目' or 'init project gates'"
  echo "    2. Agent sets up .agent/ + hooks + AGENTS.md"
  echo "    3. agent-workflow-rules auto-loads during development"
  echo ""
}

main "$@"
