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
SKILLS=(init-project-gates agent-workflow-rules agent-review-protocol init-deep-fallback)
MEMORY_SKILL_CANDIDATES=(
  "$HOME/.claude/skills"
  "$HOME/.config/opencode/skills"
  "$HOME/.codex/skills"
  "$HOME/.cc-switch/skills"
  "$HOME/.agents/skills"
)
SKIP_HOOKS=0
FORCE=0
WITH_OPENSPEC=0
CODEGRAPH_HOOK=0
SKIP_DEPS=0
BACKED_UP_SKILLS=()

# v1.5.2: external dependency sources
MEMORY_SKILL_REPO="https://github.com/clawic/skills"
MEMORY_SKILL_SUBPATH="skills/memory"
SUPERPOWERS_REPO="https://github.com/obra/superpowers"
SUPERPOWERS_HARDCORE=(
  test-driven-development
  brainstorming
  verification-before-completion
  writing-plans
  executing-plans
)

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

# --- v1.5.2: External dependency installation (default ON, opt-out via --skip-deps) ---

# Locate the first existing platform skill directory (where to install external skills).
# Priority: ~/.cc-switch/skills (multi-platform mirror) → ~/.claude/skills → opencode → codex → agents
detect_skill_dir() {
  local d
  for d in \
    "$HOME/.cc-switch/skills" \
    "$HOME/.claude/skills" \
    "$HOME/.config/opencode/skills" \
    "$HOME/.codex/skills" \
    "$HOME/.agents/skills"; do
    if [[ -d "$d" ]]; then
      echo "$d"
      return 0
    fi
  done
  # No platform dir exists yet — default to ~/.claude/skills (will be created)
  echo "$HOME/.claude/skills"
  return 0
}

# Returns 0 if any memory* skill is installed in any candidate dir, 1 otherwise.
check_memory_skill_installed() {
  local cand entry
  for cand in "${MEMORY_SKILL_CANDIDATES[@]}"; do
    [[ -d "$cand" ]] || continue
    while IFS= read -r -d '' entry; do
      [[ -n "$entry" ]] && return 0
    done < <(find "$cand" -maxdepth 1 -mindepth 1 -type d -iname 'memory*' -print0 2>/dev/null)
  done
  return 1
}

# Returns 0 if all 5 hardcore superpowers skills are installed (any platform), 1 if any missing.
check_superpowers_installed() {
  local skill d found
  for skill in "${SUPERPOWERS_HARDCORE[@]}"; do
    found=0
    for d in "${MEMORY_SKILL_CANDIDATES[@]}"; do
      if [[ -d "$d/$skill" ]]; then
        found=1
        break
      fi
    done
    [[ "$found" -eq 0 ]] && return 1
  done
  return 0
}

# Sparse-clone clawic/skills and copy skills/memory/ to target.
install_memory_skill() {
  local target="$1"
  local tmp
  tmp=$(mktemp -d) || { warn "cannot create temp dir for Memory skill clone"; return 1; }
  if ! command -v git &>/dev/null; then
    warn "git not in PATH — cannot install Memory skill automatically"
    rm -rf "$tmp"; return 1
  fi
  (
    cd "$tmp" || exit 1
    git clone --depth 1 --filter=blob:none --no-checkout "$MEMORY_SKILL_REPO" clawic-skills 2>/dev/null || exit 1
    cd clawic-skills || exit 1
    git sparse-checkout init --cone 2>/dev/null || exit 1
    git sparse-checkout set "$MEMORY_SKILL_SUBPATH" 2>/dev/null || exit 1
    git checkout 2>/dev/null || exit 1
  ) || { warn "Memory skill clone failed (network? repo unavailable?)"; rm -rf "$tmp"; return 1; }

  if [[ -d "$tmp/clawic-skills/$MEMORY_SKILL_SUBPATH" ]]; then
    mkdir -p "$target"
    cp -R "$tmp/clawic-skills/$MEMORY_SKILL_SUBPATH" "$target/memory"
    rm -rf "$tmp"
    info "Memory skill installed → $target/memory"
    return 0
  else
    warn "Memory skill: sparse-checkout produced no files"
    rm -rf "$tmp"; return 1
  fi
}

# Full clone obra/superpowers, copy all skills/* to target.
install_superpowers() {
  local target="$1"
  local tmp
  tmp=$(mktemp -d) || { warn "cannot create temp dir for Superpowers clone"; return 1; }
  if ! command -v git &>/dev/null; then
    warn "git not in PATH — cannot install Superpowers automatically"
    rm -rf "$tmp"; return 1
  fi
  if ! git clone --depth 1 "$SUPERPOWERS_REPO" "$tmp/superpowers" 2>/dev/null; then
    warn "Superpowers clone failed (network? repo unavailable?)"
    rm -rf "$tmp"; return 1
  fi
  if [[ ! -d "$tmp/superpowers/skills" ]]; then
    warn "Superpowers: cloned repo has no skills/ directory"
    rm -rf "$tmp"; return 1
  fi
  mkdir -p "$target"
  local count=0 skill
  for skill in "$tmp/superpowers/skills"/*/; do
    [[ -d "$skill" ]] || continue
    cp -R "$skill" "$target/"
    count=$((count + 1))
  done
  rm -rf "$tmp"
  info "Superpowers installed: $count skill(s) → $target/"
  return 0
}

# Ask user before npm install -g (global env mutation per red line #2).
install_openspec_with_prompt() {
  if command -v openspec &>/dev/null; then
    info "OpenSpec CLI already on PATH: $(openspec --version 2>/dev/null || echo 'version unknown')"
    return 0
  fi
  if ! command -v npm &>/dev/null; then
    warn "npm not in PATH — cannot install OpenSpec CLI automatically"
    echo "    Install Node.js first (npm comes with it): https://nodejs.org/"
    return 1
  fi

  echo ""
  echo "━━━ OpenSpec CLI 依赖检测 ━━━"
  echo ""
  echo "OpenSpec CLI 用于 Path A（团队/规范驱动）项目的 explore/propose/apply/archive 流程。"
  echo "agent-gates 将它列为可选依赖（Path B 项目不需要）。"
  echo ""
  echo "如要启用：执行 'npm install -g @openspec/cli'"
  echo ""
  echo "⚠️  注意：这是 npm 全局安装命令，会："
  echo "   - 在 npm 全局 prefix 写入新包（通常 /usr/local/lib 或 ~/.nvm/...）"
  echo "   - 在 PATH 中暴露 'openspec' 命令"
  echo "   - 涉及全局环境改动"
  echo ""

  # Non-interactive (CI / piped install) defaults to N
  if [[ ! -t 0 ]]; then
    warn "Non-interactive shell — skipping OpenSpec CLI install. To install manually: npm install -g @openspec/cli"
    return 1
  fi

  read -r -p "是否现在自动执行? [y/N]: " reply
  if [[ ! "$reply" =~ ^[Yy]$ ]]; then
    info "Skipped OpenSpec CLI install (manual: npm install -g @openspec/cli)"
    return 1
  fi
  if npm install -g @openspec/cli 2>&1; then
    info "OpenSpec CLI installed"
    return 0
  else
    warn "OpenSpec CLI install failed — see npm output above"
    return 1
  fi
}

# Orchestrator: install Memory + Superpowers + OpenSpec (default-on, opt-out via --skip-deps).
install_external_deps() {
  [[ "$SKIP_DEPS" -eq 1 ]] && { info "Skipping external deps (--skip-deps)"; return 0; }

  section "Installing external dependencies"

  local target
  target=$(detect_skill_dir)

  # 1. Memory skill
  if check_memory_skill_installed; then
    info "Memory skill already installed — skip"
  else
    install_memory_skill "$target" || warn "Memory skill install failed — agent-gates still functional but memory-reminder hook output less useful"
  fi

  # 2. Superpowers
  if check_superpowers_installed; then
    info "Superpowers (5 hardcore skills) already installed — skip"
  else
    install_superpowers "$target" || warn "Superpowers install failed — workflow rules SKILL.md references will not resolve at runtime"
  fi

  # 3. OpenSpec
  #    --with-openspec: detect-only path (back-compat with v1.5.0). Does NOT auto-install.
  #    default:        interactive y/N prompt to run `npm install -g @openspec/cli`.
  if [[ "$WITH_OPENSPEC" -eq 1 ]]; then
    check_openspec || true
  else
    install_openspec_with_prompt || true
  fi
}

# --- OpenSpec CLI check (--with-openspec) ---
check_openspec() {
  if ! command -v openspec &>/dev/null; then
    warn "openspec CLI not found on PATH."
    echo "    Install: npm install -g @openspec/cli"
    echo "    Source:  https://github.com/Fission-AI/OpenSpec"
    return 1
  fi
  local ver
  ver=$(openspec --version 2>/dev/null || echo "unknown")
  info "openspec CLI detected ($ver)"
  return 0
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

  if [[ -f "$REPO_DIR/doctor.sh" ]]; then
    cp "$REPO_DIR/doctor.sh" "$INSTALL_DIR/doctor.sh"
    chmod +x "$INSTALL_DIR/doctor.sh"
    info "Installed: doctor.sh"
  fi

  if [[ -f "$REPO_DIR/hooks/shell/codegraph-chpwd.zsh" ]]; then
    mkdir -p "$INSTALL_DIR/hooks/shell"
    cp "$REPO_DIR/hooks/shell/codegraph-chpwd.zsh" "$INSTALL_DIR/hooks/shell/codegraph-chpwd.zsh"
    info "Installed: codegraph-chpwd.zsh (opt-in; see --codegraph-hook)"
  fi
}

# --- Hook configuration constants ---
HOOK_MATCHER="TodoWrite|todowrite|TaskUpdate|TaskCreate"

# --- Register platform hooks ---
# All supported platforms use schema { "hooks": { "<Event>": [...] } }.
# OMC reads from ~/.claude/settings.json, OMX from ~/.codex/hooks.json.
# OMO has no documented per-user hook entrypoint — handled in v1.2.0+.
register_platform_hooks() {
  [[ "$SKIP_HOOKS" -eq 1 ]] && { warn "Skipping platform hook registration (--skip-hooks)"; return; }

  section "Registering platform hooks"

  # OMC: ~/.claude/settings.json (.hooks.PostToolUse)
  if [[ -d "$HOME/.claude" ]]; then
    if [[ -f "$HOME/.claude/settings.json" ]]; then
      register_hook "$HOME/.claude/settings.json" "OMC (Claude Code)"
    else
      warn "OMC: ~/.claude/settings.json missing — start Claude Code once to initialize, then re-run."
    fi
  fi

  # OMO: ~/.config/opencode/hooks.json (.hooks.PostToolUse, nested schema, identical to OMC/OMX).
  # v1.5.2 F2: auto-registration enabled — schema equivalence confirmed in docs/platform-hooks.md L85
  if [[ -d "$HOME/.config/opencode" ]]; then
    register_hook "$HOME/.config/opencode/hooks.json" "OMO (OpenCode)"
  fi

  # OMX: ~/.codex/hooks.json (.hooks.PostToolUse, nested schema)
  if [[ -d "$HOME/.codex" ]]; then
    register_hook "$HOME/.codex/hooks.json" "OMX (Codex)"
  fi
}

# --- Register hook into a Claude-style config file ---
# Writes to .hooks.PostToolUse[] using jq. Idempotent. Never overwrites
# unrelated top-level keys (model, permissions, theme, etc. in settings.json).
register_hook() {
  local config_file="$1"
  local platform="$2"
  local hook_cmd="node $INSTALL_DIR/hooks/platform/memory-reminder.mjs"

  # Skip if our hook is already in .hooks.PostToolUse (jq exact-match).
  # Without jq the merge step below cannot proceed regardless, so this guard
  # is intentionally a no-op when jq is absent.
  if [[ -f "$config_file" ]] && command -v jq &>/dev/null \
     && jq -e '.hooks.PostToolUse[]?.hooks[]? | select(.command | test("memory-reminder"))' \
          "$config_file" &>/dev/null; then
    info "$platform: already registered"
    return
  fi

  if [[ ! -f "$config_file" ]]; then
    cat > "$config_file" << EOF
{
  "hooks": {
    "PostToolUse": [
      {
        "matcher": "$HOOK_MATCHER",
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
}
EOF
    info "$platform: created $config_file"
    return
  fi

  if ! command -v jq &>/dev/null; then
    warn "$platform: $config_file exists but jq not found for safe merge."
    local jq_cmd
    jq_cmd=$(detect_jq_install_cmd)
    [[ -n "$jq_cmd" ]] && echo "    Install jq with: $jq_cmd"
    echo "    Or add manually under .hooks.PostToolUse:"
    echo "      matcher: \"$HOOK_MATCHER\""
    echo "      command: \"$hook_cmd\""
    echo "    See: docs/platform-hooks.md"
    return
  fi

  if jq --arg cmd "$hook_cmd" --arg m "$HOOK_MATCHER" '
    .hooks = (.hooks // {}) |
    .hooks.PostToolUse = ((.hooks.PostToolUse // []) + [{
      "matcher": $m,
      "hooks": [{"type": "command", "command": $cmd, "timeout": 5}]
    }])
  ' "$config_file" > "${config_file}.tmp"; then
    mv "${config_file}.tmp" "$config_file"
    info "$platform: merged into $config_file"
  else
    rm -f "${config_file}.tmp"
    warn "$platform: jq failed to parse $config_file — file may be malformed."
    echo "    Inspect or rename the file, then re-run the installer."
  fi
}

# --- CodeGraph chpwd hook registration ---
register_codegraph_hook() {
  local hook_src="$INSTALL_DIR/hooks/shell/codegraph-chpwd.zsh"
  if [[ ! -f "$hook_src" ]]; then
    warn "codegraph-chpwd.zsh not found at $hook_src — skipping"
    return
  fi

  local zshrc="$HOME/.zshrc"
  local marker="# agent-gates: codegraph auto-init"
  local source_line="$marker"$'\n'"[[ -f \"$hook_src\" ]] && source \"$hook_src\""

  if grep -qF "$marker" "$zshrc" 2>/dev/null; then
    info "CodeGraph chpwd hook already registered in ~/.zshrc"
  else
    section "Registering CodeGraph chpwd hook"
    {
      echo ""
      echo "$source_line"
      echo "export AGENT_GATES_CODEGRAPH_AUTO_INIT=1"
      echo "export AGENT_GATES_CODEGRAPH_DIRS=\"\$HOME/Projects:\$HOME/wb/projects\""
    } >> "$zshrc"
    info "Added source + env vars to ~/.zshrc"
    info "Allowed dirs: ~/Projects:~/wb/projects (edit AGENT_GATES_CODEGRAPH_DIRS to change)"
    info "To disable: unset AGENT_GATES_CODEGRAPH_AUTO_INIT (or remove block from ~/.zshrc)"
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
  echo -e "${BLUE}║${NC}    Agent Gates Installer v1.5    ${BLUE}║${NC}"
  echo -e "${BLUE}╚══════════════════════════════════╝${NC}"
  echo ""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --target) TARGET_DIR="$2"; shift 2 ;;
      --skip-hooks) SKIP_HOOKS=1; shift ;;
      --force|--upgrade) FORCE=1; shift ;;
      --with-openspec) WITH_OPENSPEC=1; shift ;;
      --codegraph-hook) CODEGRAPH_HOOK=1; shift ;;
      --skip-deps) SKIP_DEPS=1; shift ;;
      -h|--help)
        echo "Usage: install.sh [--target DIR] [--skip-hooks] [--force | --upgrade] [--with-openspec] [--codegraph-hook] [--skip-deps]"
        echo "  --target DIR       Override skills target directory"
        echo "  --skip-hooks       Skip platform hook registration"
        echo "  --force            Reinstall even if version matches"
        echo "  --upgrade          Alias of --force"
        echo "  --with-openspec    Check for OpenSpec CLI availability (no auto-install)"
        echo "  --codegraph-hook   Register CodeGraph auto-init chpwd hook in ~/.zshrc"
        echo "  --skip-deps        Skip external dependency install (Memory / Superpowers / OpenSpec)"
        exit 0
        ;;
      *) fail "Unknown option: $1" ;;
    esac
  done

  check_dependencies
  check_optional_deps
  [[ "$WITH_OPENSPEC" -eq 1 ]] && { check_openspec || true; }
  detect_platform
  fetch_repo
  check_version
  install_skills
  create_symlinks
  install_hook_files
  register_platform_hooks
  [[ "$CODEGRAPH_HOOK" -eq 1 ]] && register_codegraph_hook
  install_external_deps

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
  if [[ -f "$INSTALL_DIR/doctor.sh" ]]; then
    echo ""
    echo "  Verify:  $INSTALL_DIR/doctor.sh   (run anytime to check deployment health)"
  fi
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
  echo "    agent-quality-gate.sh into .githooks/ — the per-project copy"
  echo "    is NOT auto-upgraded."
  echo ""
}

main "$@"
