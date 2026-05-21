#!/usr/bin/env bash
# agent-gates installer
# Detects agent platforms, installs skills + registers platform hooks.
# Usage: curl -fsSL https://raw.githubusercontent.com/mcdowell8023/agent-gates/main/install.sh | bash
# Or: ./install.sh [--target DIR] [--skip-hooks] [--force | --upgrade]

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
MEMORY_SKILL_CANDIDATES=(
  "$HOME/.claude/skills"
  "$HOME/.config/opencode/skills"
  "$HOME/.codex/skills"
  "$HOME/.cc-switch/skills"
  "$HOME/.agents/skills"
)
SKIP_HOOKS=0
FORCE=0
BACKED_UP_SKILLS=()

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

info()  { echo -e "${GREEN}✓${NC} $1"; }
warn()  { echo -e "${YELLOW}⚠${NC} $1"; }
fail()  { echo -e "${RED}✗${NC} $1" >&2; exit 1; }
section() { echo -e "\n${BLUE}━━━${NC} $1"; }

# --- Hard dependency check ---
# memory-reminder.mjs uses ES modules + node:fs; requires node >= 18.
check_dependencies() {
  if ! command -v node &>/dev/null; then
    fail "node not found in PATH. Install Node.js ≥18 first: https://nodejs.org/"
  fi

  local node_major
  node_major=$(node -v 2>/dev/null | sed -E 's/^v([0-9]+).*/\1/')
  if [[ -z "$node_major" || ! "$node_major" =~ ^[0-9]+$ ]]; then
    warn "Unable to parse node version ($(node -v 2>/dev/null)) — continuing anyway"
  elif (( node_major < 18 )); then
    fail "node ≥18 required (found v${node_major}). memory-reminder.mjs uses ES modules."
  else
    info "node v${node_major} detected"
  fi
}

# --- Detect install command for jq based on OS/package manager ---
detect_jq_install_cmd() {
  if command -v brew &>/dev/null; then
    echo "brew install jq"
  elif command -v apt-get &>/dev/null; then
    echo "sudo apt-get install -y jq"
  elif command -v dnf &>/dev/null; then
    echo "sudo dnf install -y jq"
  elif command -v yum &>/dev/null; then
    echo "sudo yum install -y jq"
  elif command -v pacman &>/dev/null; then
    echo "sudo pacman -S --noconfirm jq"
  elif command -v apk &>/dev/null; then
    echo "sudo apk add jq"
  elif command -v port &>/dev/null; then
    echo "sudo port install jq"
  else
    echo ""
  fi
}

# --- Soft dependency checks (warn but continue) ---
# Prints platform-specific install commands when a soft dep is missing.
# Never invokes sudo/brew/apt on its own — user controls system mutations.
check_optional_deps() {
  section "Checking optional dependencies"

  if command -v jq &>/dev/null; then
    info "jq detected ($(jq --version 2>/dev/null || echo 'version unknown'))"
  else
    warn "jq not found — hooks.json merging will fall back to manual instructions."
    local jq_cmd
    jq_cmd=$(detect_jq_install_cmd)
    if [[ -n "$jq_cmd" ]]; then
      echo "    To install jq: $jq_cmd"
    else
      echo "    See: https://stedolan.github.io/jq/download/"
    fi
  fi

  local memory_found=""
  for cand in "${MEMORY_SKILL_CANDIDATES[@]}"; do
    [[ -d "$cand" ]] || continue
    while IFS= read -r -d '' entry; do
      memory_found="$entry"
      break 2
    done < <(find "$cand" -maxdepth 1 -mindepth 1 -type d -iname 'memory*' -print0 2>/dev/null)
  done

  if [[ -n "$memory_found" ]]; then
    info "Memory skill detected: $memory_found"
  else
    warn "No memory* skill found in your agent skills directories."
    echo "    memory-reminder.mjs will inject reminders, but the agent has no Memory"
    echo "    skill to call. Install a memory-management skill in one of:"
    for cand in "${MEMORY_SKILL_CANDIDATES[@]}"; do
      echo "      - $cand/"
    done
  fi
}

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
    info "Already at version $installed_version (use --force / --upgrade to reinstall)"
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

# --- Backup user-modified SKILL.md before overwrite ---
# Diffs src vs dst; if different, saves dst as SKILL.md.bak.<timestamp>.
# Tracks backups in BACKED_UP_SKILLS for the end-of-run summary.
backup_if_modified() {
  local skill="$1"
  local src_file="$2"
  local dst_file="$3"
  [[ -f "$dst_file" ]] || return 0
  [[ -f "$src_file" ]] || return 0
  if ! diff -q "$src_file" "$dst_file" &>/dev/null; then
    local ts backup
    ts=$(date +%Y%m%d-%H%M%S)
    backup="${dst_file}.bak.${ts}"
    cp "$dst_file" "$backup"
    BACKED_UP_SKILLS+=("$skill: $backup")
    warn "Backed up modified $(basename "$dst_file") → $backup"
  fi
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
      backup_if_modified "$skill" "$src/SKILL.md" "$dst/SKILL.md"
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

  # OMC: ~/.claude/hooks.json (if Claude Code installed)
  if [[ -d "$HOME/.claude" ]]; then
    register_hook_json "$HOME/.claude/hooks.json" "OMC (Claude Code)"
  fi

  # OMO: OpenCode can read from ~/.claude/hooks.json (shared with OMC)
  # OR from its own override path ~/.config/opencode/hooks.json
  if [[ -d "$HOME/.config/opencode" ]]; then
    local omo_hooks="$HOME/.config/opencode/hooks.json"
    if [[ -f "$omo_hooks" ]]; then
      register_hook_json "$omo_hooks" "OMO (OpenCode override)"
    elif [[ ! -d "$HOME/.claude" ]]; then
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

  if [[ -f "$hooks_file" ]] && grep -q "memory-reminder.mjs" "$hooks_file" 2>/dev/null; then
    info "$platform: already registered"
    return
  fi

  if [[ ! -f "$hooks_file" ]]; then
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
    jq --arg cmd "$hook_cmd" '
      .PostToolUse = ((.PostToolUse // []) + [{
        "matcher": "TodoWrite|todowrite",
        "hooks": [{"type": "command", "command": $cmd, "timeout": 5}]
      }])
    ' "$hooks_file" > "${hooks_file}.tmp" && mv "${hooks_file}.tmp" "$hooks_file"
    info "$platform: merged into existing $hooks_file"
  else
    warn "$platform: $hooks_file exists but jq not found for safe merge."
    local jq_cmd
    jq_cmd=$(detect_jq_install_cmd)
    [[ -n "$jq_cmd" ]] && echo "    Install jq with: $jq_cmd"
    echo "    Or add manually under PostToolUse:"
    echo "      matcher: \"TodoWrite|todowrite\""
    echo "      command: \"$hook_cmd\""
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
      --force|--upgrade) FORCE=1; shift ;;
      -h|--help)
        echo "Usage: install.sh [--target DIR] [--skip-hooks] [--force | --upgrade]"
        echo "  --target DIR    Override skills target directory"
        echo "  --skip-hooks    Skip platform hook registration"
        echo "  --force         Reinstall even if version matches"
        echo "  --upgrade       Alias of --force"
        exit 0
        ;;
      *) fail "Unknown option: $1" ;;
    esac
  done

  check_dependencies
  check_optional_deps
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

  if [[ ${#BACKED_UP_SKILLS[@]} -gt 0 ]]; then
    echo "  Backups of user-modified skill files:"
    for entry in "${BACKED_UP_SKILLS[@]}"; do
      echo "    - $entry"
    done
    echo "  Diff against the new SKILL.md to merge your changes back, then remove the .bak file."
    echo "  Or run: ./uninstall.sh --purge-backups (only after merging — backups will be gone)."
    echo ""
  fi

  echo "  Next steps:"
  echo "    1. In any project: tell agent '初始化项目' or 'init project gates'"
  echo "    2. Agent sets up .agent/ + hooks + AGENTS.md"
  echo "    3. agent-workflow-rules auto-loads during development"
  echo ""
  echo "  Already-initialized projects (have a .agent/ dir):"
  echo "    Re-run 'init project gates' in those repos to sync the latest"
  echo "    agent-quality-gate.sh into .git/hooks/ — the per-project copy"
  echo "    is NOT auto-upgraded."
  echo ""
}

main "$@"
