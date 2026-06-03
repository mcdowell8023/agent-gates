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
note() { if [[ "$QUIET" -eq 0 ]]; then echo -e "${DIM}  …$1${NC}"; fi; return 0; }

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

check_superpowers_install() {
  # v1.5.1: detect the 5 upstream "superpowers" skills across known agent
  # platform skill dirs. These skills back agent-gates' workflow guarantees
  # (TDD loop, brainstorming, plan→verify lifecycle). Missing them does not
  # break agent-gates itself, but downstream hooks/skills will degrade, so we
  # WARN rather than FAIL.
  local dirs=(
    "$HOME/.claude/skills"
    "$HOME/.config/opencode/skills"
    "$HOME/.codex/skills"
    "$HOME/.cc-switch/skills"
    "$HOME/.agents/skills"
  )
  local skills=(
    "test-driven-development"
    "brainstorming"
    "verification-before-completion"
    "writing-plans"
    "executing-plans"
  )
  local found=()
  local missing=()
  local skill d hit
  for skill in "${skills[@]}"; do
    hit=""
    for d in "${dirs[@]}"; do
      [[ -d "$d" ]] || continue
      if [[ -d "$d/$skill" ]]; then
        hit="$d/$skill"
        break
      fi
    done
    if [[ -n "$hit" ]]; then
      found+=("$skill")
    else
      missing+=("$skill")
    fi
  done

  if (( ${#missing[@]} == 0 )); then
    pass "Superpowers skills detected: ${found[*]}"
  elif (( ${#found[@]} == 0 )); then
    warn "no Superpowers skills found in agent skill dirs — install via: https://github.com/obra/superpowers (or cc-switch / opsx)"
  else
    warn "Superpowers partial: missing (${missing[*]}); install the rest via: https://github.com/obra/superpowers"
  fi
  return 0
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
  # v1.5.2 F1: skip when Claude Code not installed (align with OMO/OMX skip behavior)
  if [[ ! -d "$HOME/.claude" ]]; then
    note "OMC (Claude Code) not installed, skipping"
    return
  fi
  local s="$HOME/.claude/settings.json"
  if [[ ! -f "$s" ]]; then
    warn "$s missing — Claude Code installed but not initialized? Start Claude Code once then re-run install.sh"
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
  matcher=$(jq -r '[.hooks.PostToolUse[]
                     | select(.hooks[].command | test("memory-reminder"))
                     | .matcher // ""] | first' "$s")
  if [[ "$matcher" == *"TaskUpdate"* ]]; then
    pass "OMC settings.json hook registered (matcher contains TaskUpdate)"
  else
    fail "OMC matcher \"$matcher\" lacks TaskUpdate — Claude Code current tool name won't trigger; re-run install.sh"
  fi
}

check_omo_registration() {
  if [[ ! -d "$HOME/.config/opencode" ]]; then
    note "OMO (OpenCode) not installed, skipping"
    return
  fi
  local h="$HOME/.config/opencode/hooks.json"
  # Since v1.5.2, install.sh auto-registers the OMO hook via the same
  # register_hook() jq logic used for OMC/OMX. doctor still reports the
  # current state; the fix path is `install.sh --upgrade`, with manual
  # JSON insertion only as a fallback when jq is unavailable.
  if [[ ! -f "$h" ]]; then
    warn "OMO hooks.json missing at $h — run install.sh --upgrade to auto-register (v1.5.2+); see docs/platform-hooks.md for the manual fallback"
    return
  fi
  if ! command -v jq &>/dev/null; then
    warn "cannot inspect $h without jq"
    return
  fi
  if jq -e '.hooks.PostToolUse[]?.hooks[]? | select(.command | test("memory-reminder"))' \
       "$h" &>/dev/null; then
    pass "OMO hooks.json hook registered"
  else
    warn "OMO hook NOT registered in $h — run install.sh --upgrade to auto-register (v1.5.2+); see docs/platform-hooks.md for the manual fallback"
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
  # v1.5.5: explicit `return 0` to avoid set -e aborting when mjs missing
  # (preserves graceful skip in incomplete mock environments)
  local mjs="$INSTALL_DIR/hooks/platform/memory-reminder.mjs"
  [[ -f "$mjs" ]] || return 0  # already FAILed in check_hook_files
  command -v node &>/dev/null || return 0
  command -v jq &>/dev/null || { warn "cannot validate hook output schema without jq"; return 0; }

  local out event reminder
  out=$(echo '{"tool_name":"TaskUpdate","tool_input":{"todos":[{"status":"completed"}]}}' \
        | node "$mjs" 2>/dev/null) || {
    fail "memory-reminder.mjs crashed when invoked"
    return 0
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
  # Iterate with a while-read loop instead of `find | xargs | xargs` to avoid
  # two long-standing gotchas:
  #   1) BSD `xargs` (macOS) on empty stdin invokes the child with no args and
  #      blocks reading from stdin — looks like a hang.
  #   2) `set -o pipefail` + grep-returns-1-on-no-match would make the count
  #      assignment fail and (under `set -e`) abort the whole script silently.
  local count=0 f
  while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    if grep -q "hook_non_blocking_error" "$f" 2>/dev/null \
       && grep -q "memory-reminder" "$f" 2>/dev/null; then
      count=$((count + 1))
    fi
  done < <(find "$proj_dir" -name "*.jsonl" -mtime -7 2>/dev/null)
  if [[ "$count" == "0" ]]; then
    pass "no memory-reminder hook errors in last-7d transcripts"
  else
    warn "$count session(s) in last 7d had hook_non_blocking_error for memory-reminder — check the affected jsonl files"
  fi
}

check_openspec_install() {
  # Project-level check: detect OpenSpec presence in current working directory.
  # Skipped when cwd is not a git repo.
  # Detect git repo by directory marker (avoids depending on git binary,
  # which on macOS may fail when Xcode license is unaccepted).
  if [[ ! -d .git ]] && ! [[ -f .git ]]; then
    note "current directory is not a git repo — skipping project-level checks"
    return
  fi
  if [[ -d ".opencode/skills/openspec-propose" ]] \
     || [[ -d ".claude/skills/openspec-propose" ]] \
     || [[ -d "openspec/changes" ]]; then
    pass "OpenSpec installed in current project (Path A applies)"
  else
    note "OpenSpec not installed in current project (Path B; install via opsx for team projects)"
  fi
}

check_bdd_features_dir() {
  # Project-level check: detect features/ directory + .feature files.
  if [[ ! -d .git ]] && ! [[ -f .git ]]; then
    return  # already noted in check_openspec_install
  fi
  if [[ -d "features" ]]; then
    local count
    count=$(find features -maxdepth 2 -type f -name '*.feature' 2>/dev/null | wc -l | tr -d ' ')
    if [[ "$count" -gt 0 ]]; then
      pass "BDD features/ has $count .feature file(s)"
    else
      warn "features/ exists but no .feature files — Path A requires BDD scenarios"
    fi
  else
    note "no features/ directory — BDD not yet adopted in this project"
  fi
}

check_bdd_step_definitions() {
  if [[ ! -d .git ]] && ! [[ -f .git ]]; then
    return
  fi
  [[ -d "features" ]] || return 0
  local feature_count
  feature_count=$(find features -maxdepth 2 -name '*.feature' 2>/dev/null | wc -l | tr -d ' ')
  [[ "$feature_count" -gt 0 ]] || return 0

  if [[ -d "features/step_definitions" ]]; then
    local sd_count
    sd_count=$(find features/step_definitions -type f \( -name '*.ts' -o -name '*.js' -o -name '*.py' -o -name '*.java' -o -name '*.rb' \) 2>/dev/null | wc -l | tr -d ' ')
    if [[ "$sd_count" -gt 0 ]]; then
      pass "BDD step_definitions/ has $sd_count step file(s)"
    else
      warn "features/step_definitions/ exists but no step definition files found"
    fi
  else
    warn "features/ has .feature files but no step_definitions/ directory — step definitions needed to run BDD tests"
  fi
}

check_cross_review_capability() {
  # v1.6.0: detect heterogeneous cross-review tools, compute capability level,
  # persist to review-capability.json for downstream hook/skill consumption.
  local opencode_available=false opencode_path=""
  local codex_available=false codex_path="" codex_version=""
  local omc_codex_plugin=false
  local paseo_available=false
  local env_type="local"
  local level="L0"
  local preferred="" fallback=""

  # -- tool detection --
  if command -v opencode &>/dev/null; then
    opencode_available=true
    opencode_path=$(command -v opencode)
  fi

  if command -v codex &>/dev/null; then
    codex_available=true
    codex_path=$(command -v codex)
    codex_version=$(codex --version 2>/dev/null | head -1 || true)
  fi

  if [[ -d "$HOME/.claude/plugins/cache/openai-codex" ]]; then
    omc_codex_plugin=true
  fi

  if command -v paseo &>/dev/null || [[ -f "$HOME/.paseo/paseo.pid" ]]; then
    paseo_available=true
  fi

  # -- environment detection --
  if [[ -n "${CI:-}" ]]; then
    env_type="ci"
  elif [[ -f /.dockerenv ]]; then
    env_type="container"
  else
    local uname_out=""
    uname_out=$(uname -s 2>/dev/null || true)
    case "$uname_out" in
      CYGWIN*|MINGW*|MSYS*) env_type="windows" ;;
      Linux)
        if grep -qi microsoft /proc/version 2>/dev/null; then
          env_type="wsl"
        fi
        ;;
    esac
  fi

  # -- capability level --
  if [[ "$opencode_available" == "true" && "$codex_available" == "true" ]]; then
    level="L3"
    preferred="opencode"
    fallback="codex"
  elif [[ "$opencode_available" == "true" ]]; then
    level="L2"
    preferred="opencode"
    fallback="agent-tool"
  elif [[ "$codex_available" == "true" ]]; then
    level="L1"
    preferred="codex"
    fallback="agent-tool"
  elif [[ "$omc_codex_plugin" == "true" ]]; then
    level="L1"
    preferred="omc-codex-plugin"
    fallback="agent-tool"
  else
    level="L0"
    preferred="agent-tool"
    fallback=""
  fi

  # -- persist to JSON (atomic write, escaped values) --
  local detected_at out_file tmp_file
  detected_at=$(date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date +"%Y-%m-%dT%H:%M:%S" || true)
  out_file="$INSTALL_DIR/review-capability.json"
  tmp_file="${out_file}.tmp.$$"

  local esc_opencode_path esc_codex_path esc_codex_version
  esc_opencode_path=$(printf '%s' "$opencode_path" | sed 's/["\]/\\&/g')
  esc_codex_path=$(printf '%s' "$codex_path" | sed 's/["\]/\\&/g')
  esc_codex_version=$(printf '%s' "$codex_version" | sed 's/["\]/\\&/g')

  cat > "$tmp_file" <<RCEOF
{
  "detected_at": "${detected_at}",
  "detected_by": "doctor",
  "level": "${level}",
  "env": "${env_type}",
  "decision_tree": [
    { "route": "opencode", "available": ${opencode_available}, "path": "${esc_opencode_path}" },
    { "route": "codex", "available": ${codex_available}, "version": "${esc_codex_version}", "path": "${esc_codex_path}" },
    { "route": "omc-codex-plugin", "available": ${omc_codex_plugin} },
    { "route": "paseo", "available": ${paseo_available} },
    { "route": "agent-tool", "available": true, "note": "always available (L0 fallback)" }
  ],
  "preferred_route": "${preferred}",
  "fallback_route": "${fallback:-agent-tool}",
  "ultimate_fallback": "agent-tool"
}
RCEOF
  mv "$tmp_file" "$out_file"

  # -- report --
  if [[ "$level" == "L3" ]]; then
    pass "Cross-review capability: $level (opencode + codex)"
  elif [[ "$level" == "L2" ]]; then
    pass "Cross-review capability: $level (opencode)"
  elif [[ "$level" == "L1" ]]; then
    pass "Cross-review capability: $level (${preferred})"
  else
    warn "Cross-review capability: L0 (no heterogeneous review tools detected)"
    note "upgrade: install opencode (https://opencode.ai) or codex (npm i -g @openai/codex) for cross-model review"
  fi

  [[ "$paseo_available" == "true" ]] && note "Paseo orchestrator detected (does not affect review level)"
  [[ "$env_type" != "local" ]] && note "environment: $env_type"
  note "wrote $out_file"

  # -- check recent review files for REVIEW_LEVEL --
  if [[ -d .agent/reviews ]]; then
    local latest_review
    latest_review=$(find .agent/reviews/ -name "*.md" -mmin -10080 2>/dev/null | sort -r | head -1)
    if [[ -n "$latest_review" ]]; then
      if grep -q 'REVIEW_LEVEL: L0' "$latest_review" 2>/dev/null; then
        warn "Recent review ($latest_review) was L0 (single-model) — does not satisfy heterogeneous requirement"
      fi
    fi
  fi

  return 0
}

# v1.8.0: observe opencode serve leak (detect only — cleanup is oc-reaper's job).
check_opencode_health() {
  command -v opencode &>/dev/null || return 0
  command -v lsof &>/dev/null || { note "opencode serve health: lsof unavailable, skipping"; return 0; }
  local total orphans=0 pid port
  total=$(pgrep -f "opencode serve" 2>/dev/null | wc -l | tr -d ' ')
  if [[ "${total:-0}" -eq 0 ]]; then pass "opencode: no leaked serve processes"; return 0; fi
  local keep_port="${OC_REVIEW_PORT:-}"
  while IFS= read -r pid; do
    [[ -z "$pid" ]] && continue
    port=$(ps -o command= -p "$pid" 2>/dev/null | grep -oE 'port [0-9]+' | awk '{print $2}')
    [[ -z "$port" ]] && continue
    [[ -n "$keep_port" && "$port" == "$keep_port" ]] && continue           # shared server, not an orphan
    # only count as orphan if OLD (>2min; a just-started serve has no conn yet) AND no client
    local et secs
    et=$(ps -o etime= -p "$pid" 2>/dev/null | tr -d ' ')
    secs=$(awk -F'[:-]' '{n=NF; s=$n; if(n>=2)s+=$(n-1)*60; if(n>=3)s+=$(n-2)*3600; if(n>=4)s+=$(n-3)*86400; print s}' <<<"${et:-0}")
    [[ "${secs:-0}" -lt 120 ]] && continue
    lsof -nP -iTCP:"$port" -sTCP:ESTABLISHED >/dev/null 2>&1 || orphans=$((orphans + 1))
  done < <(pgrep -f "opencode serve" 2>/dev/null)
  if [[ "$orphans" -ge 1 ]]; then
    warn "opencode: $orphans/$total serve process(es) orphaned (no client) — run ~/.agent-gates/bin/oc-reaper --apply to clean"
  elif [[ "$total" -ge 3 ]]; then
    warn "opencode: $total serve processes stacking (none orphaned now) — watch for leaks; oc-reaper available"
  else
    pass "opencode serve health: $total active, 0 orphaned"
  fi
  return 0
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

  # v1.5.3: dynamic banner version (read from .version, auto-centered)
  local ver title inner_width=34 total_pad lpad rpad
  if [[ -f "$INSTALL_DIR/.version" ]]; then
    ver=$(tr -d '[:space:]' < "$INSTALL_DIR/.version")
  else
    ver="?"
  fi
  title="Agent Gates Doctor v${ver}"
  total_pad=$(( inner_width - ${#title} ))
  if (( total_pad < 0 )); then total_pad=0; fi
  lpad=$(( total_pad / 2 ))
  rpad=$(( total_pad - lpad ))

  echo -e "${BLUE}╔══════════════════════════════════╗${NC}"
  printf "${BLUE}║${NC}%${lpad}s%s%${rpad}s${BLUE}║${NC}\n" "" "$title" ""
  echo -e "${BLUE}╚══════════════════════════════════╝${NC}"
  echo ""

  check_node
  check_jq
  check_memory_skill
  check_superpowers_install
  check_version_local
  check_version_remote
  check_hook_files
  check_omc_registration
  check_omo_registration
  check_omx_registration
  check_hook_output_schema
  check_transcript_errors
  check_openspec_install
  check_bdd_features_dir
  check_bdd_step_definitions
  check_cross_review_capability
  check_opencode_health

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
