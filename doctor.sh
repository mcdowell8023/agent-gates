#!/usr/bin/env bash
# agent-gates doctor — verify deployment health.
# Usage: ./doctor.sh [--quiet] [--no-network]
#   exit 0 if no FAIL (WARN allowed), exit 1 if any FAIL.

set -euo pipefail

INSTALL_DIR="$HOME/.agent-gates"
REPO_URL="https://github.com/mcdowell8023/agent-gates"
QUIET=0
NO_NETWORK=0

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
DIM='\033[0;90m'
NC='\033[0m'

PASS=()
WARN=()
FAIL=()

pass() { PASS+=("$1"); }
warn() { WARN+=("$1"); }
fail() { FAIL+=("$1"); }
note() { [[ "$QUIET" -eq 0 ]] && echo -e "${DIM}  …$1${NC}"; }

# --- Checks ---

check_node() {
  if ! command -v node &>/dev/null; then
    fail "node not in PATH. memory-reminder.mjs cannot execute. Install: https://nodejs.org/"
    return
  fi
  local v major
  v=$(node -v 2>/dev/null)
  major=$(echo "$v" | sed -E 's/^v([0-9]+).*/\1/')
  if [[ ! "$major" =~ ^[0-9]+$ ]]; then
    warn "node version unparseable ($v) — continuing"
    return
  fi
  if (( major < 18 )); then
    fail "node ${v} < 18. memory-reminder.mjs uses ES modules + node:fs."
  else
    pass "node ${v}"
  fi
}

check_jq() {
  if command -v jq &>/dev/null; then
    pass "jq $(jq --version 2>/dev/null)"
  else
    warn "jq not in PATH. install.sh hooks.json merging falls back to manual instructions."
  fi
}

check_memory_skill() {
  local dirs=(
    "$HOME/.claude/skills"
    "$HOME/.config/opencode/skills"
    "$HOME/.codex/skills"
    "$HOME/.cc-switch/skills"
    "$HOME/.agents/skills"
  )
  local found=""
  for d in "${dirs[@]}"; do
    [[ -d "$d" ]] || continue
    while IFS= read -r -d '' entry; do
      found="$entry"
      break 2
    done < <(find "$d" -maxdepth 1 -mindepth 1 -type d -iname 'memory*' -print0 2>/dev/null)
  done
  if [[ -n "$found" ]]; then
    pass "Memory skill detected: $found"
  else
    warn "no Memory skill found in agent skills dirs — reminder will be informational only"
  fi
}

check_version_local() {
  if [[ ! -f "$INSTALL_DIR/.version" ]]; then
    fail "$INSTALL_DIR/.version missing — run install.sh first"
    return
  fi
  local v
  v=$(tr -d '[:space:]' < "$INSTALL_DIR/.version")
  pass "installed version: $v"
}

check_version_remote() {
  if [[ "$NO_NETWORK" -eq 1 ]]; then
    note "skipping remote version check (--no-network)"
    return
  fi
  if ! command -v curl &>/dev/null; then
    warn "curl not in PATH — skipping remote version check"
    return
  fi
  # macOS bash 3.2: `set -e` is NOT suppressed by `local` assignment from a
  # command substitution, so a failed curl would abort the whole script and
  # hide all prior check results. The trailing `|| true` ensures graceful WARN.
  local remote=""
  remote=$(curl -fsSL --max-time 5 "$REPO_URL/raw/main/.version" 2>/dev/null | tr -d '[:space:]' || true)
  if [[ -z "$remote" ]]; then
    warn "could not fetch remote .version (offline or repo unreachable)"
    return
  fi
  local local_v=""
  [[ -f "$INSTALL_DIR/.version" ]] && local_v=$(tr -d '[:space:]' < "$INSTALL_DIR/.version")
  if [[ "$local_v" == "$remote" ]]; then
    pass "up to date with remote ($remote)"
  else
    warn "remote main is $remote (local: $local_v) — consider: $REPO_URL — install.sh --upgrade"
  fi
}

check_hook_files() {
  local mjs="$INSTALL_DIR/hooks/platform/memory-reminder.mjs"
  local gate="$INSTALL_DIR/hooks/git/agent-quality-gate.sh"
  if [[ -f "$mjs" ]]; then
    pass "memory-reminder.mjs present"
  else
    fail "memory-reminder.mjs missing at $mjs"
  fi
  if [[ -f "$gate" ]]; then
    if [[ -x "$gate" ]]; then
      pass "agent-quality-gate.sh present (executable)"
    else
      warn "agent-quality-gate.sh present but not executable — fix: chmod +x \"$gate\""
    fi
  else
    fail "agent-quality-gate.sh missing at $gate"
  fi
}

check_omc_registration() {
  local s="$HOME/.claude/settings.json"
  if [[ ! -f "$s" ]]; then
    warn "$s missing — Claude Code not initialized? Start Claude Code once then re-run install.sh"
    return
  fi
  if ! command -v jq &>/dev/null; then
    warn "cannot precisely inspect $s without jq"
    return
  fi
  if ! jq -e '.hooks.PostToolUse[]?.hooks[]? | select(.command | test("memory-reminder"))' \
       "$s" &>/dev/null; then
    fail "OMC hook NOT registered in $s — run install.sh"
    return
  fi
  local matcher
  matcher=$(jq -r '.hooks.PostToolUse[]
                     | select(.hooks[].command | test("memory-reminder"))
                     | .matcher // ""' "$s" | head -1)
  if [[ "$matcher" == *"TaskUpdate"* ]]; then
    pass "OMC settings.json hook registered (matcher contains TaskUpdate)"
  else
    warn "OMC matcher \"$matcher\" lacks TaskUpdate — Claude Code current tool name won't trigger; re-run install.sh"
  fi
}

check_omx_registration() {
  if [[ ! -d "$HOME/.codex" ]]; then
    note "OMX (Codex) not installed, skipping"
    return
  fi
  local h="$HOME/.codex/hooks.json"
  if [[ ! -f "$h" ]]; then
    warn "OMX hooks.json missing at $h — run install.sh"
    return
  fi
  if ! command -v jq &>/dev/null; then
    warn "cannot inspect $h without jq"
    return
  fi
  if jq -e '.hooks.PostToolUse[]?.hooks[]? | select(.command | test("memory-reminder"))' \
       "$h" &>/dev/null; then
    pass "OMX hooks.json hook registered"
  else
    warn "OMX hook NOT registered in $h — run install.sh"
  fi
}

check_hook_output_schema() {
  local mjs="$INSTALL_DIR/hooks/platform/memory-reminder.mjs"
  [[ -f "$mjs" ]] || return  # already FAILed in check_hook_files
  command -v node &>/dev/null || return
  command -v jq &>/dev/null || { warn "cannot validate hook output schema without jq"; return; }

  local out event reminder
  out=$(echo '{"tool_name":"TaskUpdate","tool_input":{"todos":[{"status":"completed"}]}}' \
        | node "$mjs" 2>/dev/null) || {
    fail "memory-reminder.mjs crashed when invoked"
    return
  }
  event=$(echo "$out" | jq -r '.hookSpecificOutput.hookEventName // ""' 2>/dev/null)
  reminder=$(echo "$out" | jq -r '(.hookSpecificOutput.additionalContext // "") | contains("AGENT-GATES")' 2>/dev/null)

  if [[ "$event" == "PostToolUse" && "$reminder" == "true" ]]; then
    pass "hook output schema valid (hookEventName=PostToolUse, reminder included)"
  elif [[ "$event" != "PostToolUse" ]]; then
    fail "hook output missing hookEventName=PostToolUse — Claude Code validator will reject. install.sh --upgrade"
  else
    fail "hook output present but reminder body missing AGENT-GATES tag"
  fi
}

check_transcript_errors() {
  local proj_dir="$HOME/.claude/projects"
  if [[ ! -d "$proj_dir" ]]; then
    note "$proj_dir missing — no transcripts to inspect"
    return
  fi
  local count
  count=$(find "$proj_dir" -name "*.jsonl" -mtime -7 -print0 2>/dev/null \
         | xargs -0 grep -l "hook_non_blocking_error" 2>/dev/null \
         | xargs grep -l "memory-reminder" 2>/dev/null \
         | wc -l | tr -d ' ')
  if [[ "$count" == "0" ]]; then
    pass "no memory-reminder hook errors in last-7d transcripts"
  else
    warn "$count session(s) in last 7d had hook_non_blocking_error for memory-reminder — check the affected jsonl files"
  fi
}

# --- Main ---
main() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --quiet) QUIET=1; shift ;;
      --no-network) NO_NETWORK=1; shift ;;
      -h|--help)
        echo "Usage: doctor.sh [--quiet] [--no-network]"
        echo "  --quiet       Suppress dim/info lines, show only PASS/WARN/FAIL summary"
        echo "  --no-network  Skip remote version check (offline mode)"
        echo ""
        echo "Exit code: 0 if no FAIL (WARN allowed), 1 if any FAIL."
        exit 0
        ;;
      *) echo "Unknown option: $1" >&2; exit 2 ;;
    esac
  done

  echo -e "${BLUE}╔══════════════════════════════════╗${NC}"
  echo -e "${BLUE}║${NC}     Agent Gates Doctor v1.3      ${BLUE}║${NC}"
  echo -e "${BLUE}╚══════════════════════════════════╝${NC}"
  echo ""

  check_node
  check_jq
  check_memory_skill
  check_version_local
  check_version_remote
  check_hook_files
  check_omc_registration
  check_omx_registration
  check_hook_output_schema
  check_transcript_errors

  echo ""
  if (( ${#PASS[@]} > 0 )); then
    for x in "${PASS[@]}"; do echo -e "  ${GREEN}✓${NC} $x"; done
  fi
  if (( ${#WARN[@]} > 0 )); then
    for x in "${WARN[@]}"; do echo -e "  ${YELLOW}⚠${NC} $x"; done
  fi
  if (( ${#FAIL[@]} > 0 )); then
    for x in "${FAIL[@]}"; do echo -e "  ${RED}✗${NC} $x"; done
  fi

  echo ""
  echo -e "  ${GREEN}${#PASS[@]} pass${NC} · ${YELLOW}${#WARN[@]} warn${NC} · ${RED}${#FAIL[@]} fail${NC}"

  if (( ${#FAIL[@]} > 0 )); then
    echo ""
    echo "Issues found. See messages above; refer to README Troubleshooting for fix recipes."
    exit 1
  fi

  echo ""
  if [[ ${#WARN[@]} -gt 0 ]]; then
    echo "Healthy with warnings."
  else
    echo "All checks passed."
  fi
  exit 0
}

main "$@"
