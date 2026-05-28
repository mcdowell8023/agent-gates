#!/usr/bin/env bash
# Tests for doctor.sh — three P0 fixes (v1.3.1).
# Strategy: source doctor.sh under a mocked $HOME and INSTALL_DIR, invoke
# individual check_* functions, assert PASS/WARN/FAIL array contents.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOCTOR="$SCRIPT_DIR/../doctor.sh"
PASS_COUNT=0
FAIL_COUNT=0

# Each test runs in a subshell with its own mocked HOME + INSTALL_DIR.
# Override functions we don't want to actually execute so we can call main()
# or individual checks in isolation.

setup_mock_home() {
  MOCK_HOME=$(mktemp -d)
  export HOME="$MOCK_HOME"
  export INSTALL_DIR="$MOCK_HOME/.agent-gates"
  mkdir -p "$INSTALL_DIR/hooks/platform" "$INSTALL_DIR/hooks/git"
  echo "1.3.1" > "$INSTALL_DIR/.version"
  echo '#!/usr/bin/env node' > "$INSTALL_DIR/hooks/platform/memory-reminder.mjs"
  echo '#!/usr/bin/env bash' > "$INSTALL_DIR/hooks/git/agent-quality-gate.sh"
  chmod +x "$INSTALL_DIR/hooks/git/agent-quality-gate.sh"
}

teardown_mock_home() {
  [[ -n "${MOCK_HOME:-}" && -d "$MOCK_HOME" ]] && rm -rf "$MOCK_HOME"
}

# Source doctor.sh without running main() — we define check functions only.
# doctor.sh runs `main "$@"` at the end; we bypass by sourcing in a way that
# defines functions but skips the trailing main call. Easiest: extract via
# stripping `main "$@"` line.
source_doctor_no_main() {
  local tmp
  tmp=$(mktemp)
  # Strip the final `main "$@"` invocation, keep all function defs.
  sed '/^main "\$@"$/d' "$DOCTOR" > "$tmp"
  # shellcheck disable=SC1090
  source "$tmp"
  rm -f "$tmp"
}

assert() {
  local name="$1"
  local cond="$2"
  if [[ "$cond" == "true" ]]; then
    echo "  ✓ $name"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo "  ✗ $name"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
}

# --- P0-1: check_omo_registration must exist and detect OMO hooks.json ---
test_p0_1_omo_check_exists() {
  echo "P0-1: check_omo_registration exists and works"
  (
    setup_mock_home
    mkdir -p "$HOME/.config/opencode"
    cat > "$HOME/.config/opencode/hooks.json" << 'EOF'
{
  "hooks": {
    "PostToolUse": [
      {"matcher": "TaskUpdate", "hooks": [{"type": "command", "command": "node memory-reminder.mjs"}]}
    ]
  }
}
EOF
    source_doctor_no_main
    if ! declare -F check_omo_registration >/dev/null; then
      echo "  RED: check_omo_registration function missing"
      teardown_mock_home
      exit 1
    fi
    PASS=(); WARN=(); FAIL=()
    QUIET=1
    check_omo_registration
    local found=false
    for x in "${PASS[@]:-}"; do
      [[ "$x" == *"OMO"* ]] && found=true
    done
    if [[ "$found" == "true" ]]; then
      teardown_mock_home
      exit 0
    else
      echo "  RED: expected PASS containing OMO, got PASS=(${PASS[*]:-}) WARN=(${WARN[*]:-}) FAIL=(${FAIL[*]:-})"
      teardown_mock_home
      exit 1
    fi
  )
  local rc=$?
  assert "P0-1 OMO check present and detects valid hook" "$([[ $rc -eq 0 ]] && echo true || echo false)"
}

test_p0_1_omo_missing_hook() {
  echo "P0-1b: check_omo_registration warns when hook missing"
  (
    setup_mock_home
    mkdir -p "$HOME/.config/opencode"
    echo '{"hooks":{}}' > "$HOME/.config/opencode/hooks.json"
    source_doctor_no_main
    if ! declare -F check_omo_registration >/dev/null; then
      teardown_mock_home; exit 1
    fi
    PASS=(); WARN=(); FAIL=()
    QUIET=1
    check_omo_registration
    # Should be WARN (not registered) or FAIL — either is correct, but not PASS
    local pass_count=${#PASS[@]}
    if [[ $pass_count -eq 0 ]]; then
      teardown_mock_home; exit 0
    else
      echo "  expected no PASS, got PASS=(${PASS[*]})"
      teardown_mock_home; exit 1
    fi
  )
  local rc=$?
  assert "P0-1b OMO check warns/fails when hook missing" "$([[ $rc -eq 0 ]] && echo true || echo false)"
}

# --- P0-2: OMC matcher-mismatch must FAIL, not WARN ---
test_p0_2_matcher_mismatch_is_fail() {
  echo "P0-2: OMC matcher without TaskUpdate must FAIL (not WARN)"
  (
    setup_mock_home
    mkdir -p "$HOME/.claude"
    cat > "$HOME/.claude/settings.json" << 'EOF'
{
  "hooks": {
    "PostToolUse": [
      {"matcher": "TodoWrite", "hooks": [{"type": "command", "command": "node memory-reminder.mjs"}]}
    ]
  }
}
EOF
    source_doctor_no_main
    PASS=(); WARN=(); FAIL=()
    QUIET=1
    check_omc_registration
    local in_fail=false
    for x in "${FAIL[@]:-}"; do
      [[ "$x" == *"matcher"* || "$x" == *"TaskUpdate"* ]] && in_fail=true
    done
    if [[ "$in_fail" == "true" ]]; then
      teardown_mock_home; exit 0
    else
      echo "  RED: expected FAIL with matcher message; PASS=(${PASS[*]:-}) WARN=(${WARN[*]:-}) FAIL=(${FAIL[*]:-})"
      teardown_mock_home; exit 1
    fi
  )
  local rc=$?
  assert "P0-2 OMC matcher mismatch goes to FAIL" "$([[ $rc -eq 0 ]] && echo true || echo false)"
}

# --- P0-3: check_transcript_errors must not hang on empty/no-match input ---
test_p0_3_no_hang_on_empty() {
  echo "P0-3: check_transcript_errors completes within 5s on empty transcripts"
  (
    setup_mock_home
    mkdir -p "$HOME/.claude/projects/sample"
    # Create jsonl with no hook_non_blocking_error matches.
    echo '{"type":"user","content":"hello"}' > "$HOME/.claude/projects/sample/sess.jsonl"
    source_doctor_no_main
    PASS=(); WARN=(); FAIL=()
    QUIET=1
    # Wall-clock timer: run in foreground, fail if it takes > 5s.
    SECONDS=0
    check_transcript_errors &>/dev/null
    elapsed=$SECONDS
    teardown_mock_home
    if (( elapsed < 5 )); then
      exit 0
    else
      echo "  RED: check_transcript_errors took ${elapsed}s (hang suspected)"
      exit 1
    fi
  )
  local rc=$?
  assert "P0-3 no hang on empty transcript set" "$([[ $rc -eq 0 ]] && echo true || echo false)"
}

# Workaround: doctor.sh check_transcript_errors function we'll test directly.
# Need an alternate runner that captures the pipeline within the subshell.
# Embed it inline so we can timeout-wrap without process group quirks.

test_p0_3_no_hang_direct() {
  echo "P0-3b: direct pipeline test for hang on no hook_non_blocking_error matches"
  local tmp
  tmp=$(mktemp -d)
  mkdir -p "$tmp/projects/sample"
  echo '{"type":"user"}' > "$tmp/projects/sample/a.jsonl"
  # Reproduce the original buggy pipeline; should hang without -r on second xargs.
  # Use a subshell + kill to detect hang.
  (
    find "$tmp/projects" -name "*.jsonl" -mtime -7 -print0 2>/dev/null \
      | xargs -0 grep -l "hook_non_blocking_error" 2>/dev/null \
      | xargs grep -l "memory-reminder" 2>/dev/null \
      | wc -l
  ) &
  pid=$!
  sleep 3
  if kill -0 $pid 2>/dev/null; then
    kill -9 $pid 2>/dev/null
    echo "  CONFIRMED: original pipeline hangs (P0-3 reproducible)"
    rm -rf "$tmp"
    # This is informational — the real assert is the function-level test above.
  fi
  rm -rf "$tmp"
}

# --- v1.4: check_openspec_install ---
test_v14_openspec_detected() {
  echo "v1.4: check_openspec_install detects openspec/changes/"
  (
    setup_mock_home
    tmp_repo=$(mktemp -d)
    cd "$tmp_repo"
    mkdir .git  # marker only — doctor uses [[ -d .git ]], no git binary needed
    mkdir -p openspec/changes/foo
    source_doctor_no_main
    if ! declare -F check_openspec_install >/dev/null; then
      echo "  RED: check_openspec_install function missing"
      teardown_mock_home; rm -rf "$tmp_repo"; exit 1
    fi
    PASS=(); WARN=(); FAIL=()
    QUIET=1
    check_openspec_install
    local found=false
    for x in "${PASS[@]:-}"; do
      [[ "$x" == *"OpenSpec"* ]] && found=true
    done
    teardown_mock_home; rm -rf "$tmp_repo"
    [[ "$found" == "true" ]] && exit 0 || exit 1
  )
  local rc=$?
  assert "v1.4 check_openspec_install detects openspec/changes/" "$([[ $rc -eq 0 ]] && echo true || echo false)"
}

test_v14_openspec_absent() {
  echo "v1.4: check_openspec_install notes when project has no OpenSpec"
  (
    setup_mock_home
    tmp_repo=$(mktemp -d)
    cd "$tmp_repo"
    mkdir .git  # marker only — doctor uses [[ -d .git ]], no git binary needed
    source_doctor_no_main
    PASS=(); WARN=(); FAIL=()
    QUIET=0  # we want to verify note (which prints to stdout)
    note_output=$(check_openspec_install 2>&1)
    teardown_mock_home; rm -rf "$tmp_repo"
    if [[ "$note_output" == *"OpenSpec not installed"* ]]; then
      exit 0
    else
      echo "  RED: expected 'OpenSpec not installed' note, got: $note_output"
      exit 1
    fi
  )
  local rc=$?
  assert "v1.4 check_openspec_install notes absence" "$([[ $rc -eq 0 ]] && echo true || echo false)"
}

# --- v1.4: check_bdd_features_dir ---
test_v14_bdd_features_present() {
  echo "v1.4: check_bdd_features_dir detects .feature files"
  (
    setup_mock_home
    tmp_repo=$(mktemp -d)
    cd "$tmp_repo"
    mkdir .git  # marker only — doctor uses [[ -d .git ]], no git binary needed
    mkdir -p features
    cat > features/sample.feature << 'EOF'
Feature: Sample
  Scenario: Hello
    Given a user
    When they greet
    Then output is "hi"
EOF
    source_doctor_no_main
    if ! declare -F check_bdd_features_dir >/dev/null; then
      echo "  RED: check_bdd_features_dir function missing"
      teardown_mock_home; rm -rf "$tmp_repo"; exit 1
    fi
    PASS=(); WARN=(); FAIL=()
    QUIET=1
    check_bdd_features_dir
    local found=false
    for x in "${PASS[@]:-}"; do
      [[ "$x" == *"BDD"* || "$x" == *".feature"* ]] && found=true
    done
    teardown_mock_home; rm -rf "$tmp_repo"
    [[ "$found" == "true" ]] && exit 0 || exit 1
  )
  local rc=$?
  assert "v1.4 check_bdd_features_dir detects .feature" "$([[ $rc -eq 0 ]] && echo true || echo false)"
}

test_v14_bdd_features_empty() {
  echo "v1.4: check_bdd_features_dir WARNs when features/ exists but no .feature"
  (
    setup_mock_home
    tmp_repo=$(mktemp -d)
    cd "$tmp_repo"
    mkdir .git  # marker only — doctor uses [[ -d .git ]], no git binary needed
    mkdir -p features  # empty
    source_doctor_no_main
    PASS=(); WARN=(); FAIL=()
    QUIET=1
    check_bdd_features_dir
    local has_warn=false
    for x in "${WARN[@]:-}"; do
      [[ "$x" == *"no .feature"* ]] && has_warn=true
    done
    teardown_mock_home; rm -rf "$tmp_repo"
    [[ "$has_warn" == "true" ]] && exit 0 || exit 1
  )
  local rc=$?
  assert "v1.4 check_bdd_features_dir WARNs on empty features/" "$([[ $rc -eq 0 ]] && echo true || echo false)"
}

test_v14_not_git_repo_skip() {
  echo "v1.4: project-level checks skip outside git repo"
  (
    setup_mock_home
    tmp_dir=$(mktemp -d)
    cd "$tmp_dir"  # NOT a git repo
    source_doctor_no_main
    PASS=(); WARN=(); FAIL=()
    QUIET=0
    note_output=$(check_openspec_install 2>&1)
    teardown_mock_home; rm -rf "$tmp_dir"
    if [[ "$note_output" == *"not a git repo"* ]]; then
      exit 0
    else
      echo "  RED: expected 'not a git repo' note, got: $note_output"
      exit 1
    fi
  )
  local rc=$?
  assert "v1.4 project-level checks skip when not in git repo" "$([[ $rc -eq 0 ]] && echo true || echo false)"
}

# --- v1.5: check_bdd_step_definitions ---
test_v15_step_defs_present() {
  echo "v1.5: check_bdd_step_definitions detects step_definitions/"
  (
    setup_mock_home
    tmp_repo=$(mktemp -d)
    cd "$tmp_repo"
    mkdir .git
    mkdir -p features/step_definitions
    echo "import { Given } from '@cucumber/cucumber';" > features/step_definitions/login.steps.ts
    cat > features/login.feature << 'EOF'
Feature: Login
  Scenario: Valid
    Given a user
    Then success
EOF
    source_doctor_no_main
    if ! declare -F check_bdd_step_definitions >/dev/null; then
      echo "  RED: check_bdd_step_definitions function missing"
      teardown_mock_home; rm -rf "$tmp_repo"; exit 1
    fi
    PASS=(); WARN=(); FAIL=()
    QUIET=1
    check_bdd_step_definitions
    local found=false
    for x in "${PASS[@]:-}"; do
      [[ "$x" == *"step"* || "$x" == *"Step"* ]] && found=true
    done
    teardown_mock_home; rm -rf "$tmp_repo"
    [[ "$found" == "true" ]] && exit 0 || exit 1
  )
  local rc=$?
  assert "v1.5 check_bdd_step_definitions detects step_definitions/" "$([[ $rc -eq 0 ]] && echo true || echo false)"
}

test_v15_step_defs_missing() {
  echo "v1.5: check_bdd_step_definitions WARNs when features/ has no step_definitions/"
  (
    setup_mock_home
    tmp_repo=$(mktemp -d)
    cd "$tmp_repo"
    mkdir .git
    mkdir -p features
    cat > features/login.feature << 'EOF'
Feature: Login
  Scenario: Valid
    Given a user
    Then success
EOF
    source_doctor_no_main
    if ! declare -F check_bdd_step_definitions >/dev/null; then
      echo "  RED: check_bdd_step_definitions function missing"
      teardown_mock_home; rm -rf "$tmp_repo"; exit 1
    fi
    PASS=(); WARN=(); FAIL=()
    QUIET=1
    check_bdd_step_definitions
    local has_warn=false
    for x in "${WARN[@]:-}"; do
      [[ "$x" == *"step_definitions"* ]] && has_warn=true
    done
    teardown_mock_home; rm -rf "$tmp_repo"
    [[ "$has_warn" == "true" ]] && exit 0 || exit 1
  )
  local rc=$?
  assert "v1.5 check_bdd_step_definitions WARNs when missing" "$([[ $rc -eq 0 ]] && echo true || echo false)"
}

test_v15_step_defs_skip_no_features() {
  echo "v1.5: check_bdd_step_definitions skips when no features/"
  (
    setup_mock_home
    tmp_repo=$(mktemp -d)
    cd "$tmp_repo"
    mkdir .git
    source_doctor_no_main
    if ! declare -F check_bdd_step_definitions >/dev/null; then
      echo "  RED: check_bdd_step_definitions function missing"
      teardown_mock_home; rm -rf "$tmp_repo"; exit 1
    fi
    PASS=(); WARN=(); FAIL=()
    QUIET=1
    check_bdd_step_definitions
    local has_any=false
    for x in "${PASS[@]:-}"; do [[ -n "$x" ]] && has_any=true; done
    for x in "${WARN[@]:-}"; do [[ -n "$x" ]] && has_any=true; done
    for x in "${FAIL[@]:-}"; do [[ -n "$x" ]] && has_any=true; done
    teardown_mock_home; rm -rf "$tmp_repo"
    [[ "$has_any" == "false" ]] && exit 0 || exit 1
  )
  local rc=$?
  assert "v1.5 check_bdd_step_definitions skips when no features/" "$([[ $rc -eq 0 ]] && echo true || echo false)"
}

# --- v1.5.1: check_superpowers_install ---
# Detects 5 upstream superpowers skills across 5 platform skill dirs:
#   - test-driven-development, brainstorming, verification-before-completion,
#     writing-plans, executing-plans
# search dirs: ~/.claude/skills, ~/.config/opencode/skills, ~/.codex/skills,
#              ~/.cc-switch/skills, ~/.agents/skills

create_all_superpowers() {
  local parent="$1"
  mkdir -p "$parent/test-driven-development"
  mkdir -p "$parent/brainstorming"
  mkdir -p "$parent/verification-before-completion"
  mkdir -p "$parent/writing-plans"
  mkdir -p "$parent/executing-plans"
}

test_v151_superpowers_function_declared() {
  echo "v1.5.1: check_superpowers_install function is declared after sourcing doctor.sh"
  (
    setup_mock_home
    source_doctor_no_main
    if declare -F check_superpowers_install >/dev/null; then
      teardown_mock_home; exit 0
    else
      echo "  RED: check_superpowers_install function not defined"
      teardown_mock_home; exit 1
    fi
  )
  local rc=$?
  assert "v1.5.1 check_superpowers_install function declared" "$([[ $rc -eq 0 ]] && echo true || echo false)"
}

test_v151_superpowers_all_present_cc_switch() {
  echo "v1.5.1: all 5 superpowers under ~/.cc-switch/skills/ -> PASS"
  (
    setup_mock_home
    create_all_superpowers "$HOME/.cc-switch/skills"
    source_doctor_no_main
    if ! declare -F check_superpowers_install >/dev/null; then
      echo "  RED: check_superpowers_install function missing"
      teardown_mock_home; exit 1
    fi
    PASS=(); WARN=(); FAIL=()
    QUIET=1
    check_superpowers_install
    local found=false
    for x in "${PASS[@]:-}"; do
      [[ "$x" == *"superpowers"* || "$x" == *"Superpowers"* ]] && found=true
    done
    teardown_mock_home
    if [[ "$found" == "true" && ${#WARN[@]} -eq 0 ]]; then
      exit 0
    else
      echo "  RED: expected PASS containing superpowers, no WARN; got PASS=(${PASS[*]:-}) WARN=(${WARN[*]:-})"
      exit 1
    fi
  )
  local rc=$?
  assert "v1.5.1 all 5 superpowers present in cc-switch -> PASS" "$([[ $rc -eq 0 ]] && echo true || echo false)"
}

test_v151_superpowers_partial_missing_brainstorming() {
  echo "v1.5.1: missing brainstorming -> WARN mentioning 'brainstorming'"
  (
    setup_mock_home
    mkdir -p "$HOME/.cc-switch/skills/test-driven-development"
    mkdir -p "$HOME/.cc-switch/skills/verification-before-completion"
    mkdir -p "$HOME/.cc-switch/skills/writing-plans"
    mkdir -p "$HOME/.cc-switch/skills/executing-plans"
    source_doctor_no_main
    if ! declare -F check_superpowers_install >/dev/null; then
      echo "  RED: check_superpowers_install function missing"
      teardown_mock_home; exit 1
    fi
    PASS=(); WARN=(); FAIL=()
    QUIET=1
    check_superpowers_install
    local mentions_bs=false
    for x in "${WARN[@]:-}"; do
      [[ "$x" == *"brainstorming"* ]] && mentions_bs=true
    done
    teardown_mock_home
    if [[ "$mentions_bs" == "true" ]]; then
      exit 0
    else
      echo "  RED: expected WARN mentioning brainstorming; got PASS=(${PASS[*]:-}) WARN=(${WARN[*]:-})"
      exit 1
    fi
  )
  local rc=$?
  assert "v1.5.1 missing brainstorming -> WARN mentions name" "$([[ $rc -eq 0 ]] && echo true || echo false)"
}

test_v151_superpowers_all_missing() {
  echo "v1.5.1: all missing (no platform dirs) -> WARN mentioning install"
  (
    setup_mock_home
    source_doctor_no_main
    if ! declare -F check_superpowers_install >/dev/null; then
      echo "  RED: check_superpowers_install function missing"
      teardown_mock_home; exit 1
    fi
    PASS=(); WARN=(); FAIL=()
    QUIET=1
    check_superpowers_install
    local mentions_install=false
    for x in "${WARN[@]:-}"; do
      [[ "$x" == *"install"* || "$x" == *"Install"* || "$x" == *"INSTALL"* ]] && mentions_install=true
    done
    teardown_mock_home
    if [[ "$mentions_install" == "true" && ${#PASS[@]} -eq 0 ]]; then
      exit 0
    else
      echo "  RED: expected WARN mentioning install, no PASS; got PASS=(${PASS[*]:-}) WARN=(${WARN[*]:-})"
      exit 1
    fi
  )
  local rc=$?
  assert "v1.5.1 all missing -> WARN mentions install" "$([[ $rc -eq 0 ]] && echo true || echo false)"
}

test_v151_superpowers_cross_platform() {
  echo "v1.5.1: skills spread across ~/.claude/skills and ~/.agents/skills (not in cc-switch) -> PASS"
  (
    setup_mock_home
    mkdir -p "$HOME/.claude/skills/test-driven-development"
    mkdir -p "$HOME/.claude/skills/brainstorming"
    mkdir -p "$HOME/.claude/skills/verification-before-completion"
    mkdir -p "$HOME/.agents/skills/writing-plans"
    mkdir -p "$HOME/.agents/skills/executing-plans"
    source_doctor_no_main
    if ! declare -F check_superpowers_install >/dev/null; then
      echo "  RED: check_superpowers_install function missing"
      teardown_mock_home; exit 1
    fi
    PASS=(); WARN=(); FAIL=()
    QUIET=1
    check_superpowers_install
    local found=false
    for x in "${PASS[@]:-}"; do
      [[ "$x" == *"superpowers"* || "$x" == *"Superpowers"* ]] && found=true
    done
    teardown_mock_home
    if [[ "$found" == "true" && ${#WARN[@]} -eq 0 ]]; then
      exit 0
    else
      echo "  RED: expected PASS containing superpowers across platforms, no WARN; got PASS=(${PASS[*]:-}) WARN=(${WARN[*]:-})"
      exit 1
    fi
  )
  local rc=$?
  assert "v1.5.1 cross-platform detection -> PASS" "$([[ $rc -eq 0 ]] && echo true || echo false)"
}

# --- v1.5.2 F1: check_omc_registration with "not installed" skip ---
# Behavior: if ~/.claude/ does not exist, NOTE-skip (don't WARN)
# Align with OMO / OMX which both have this skip-prefix.

test_v152_omc_skip_when_not_installed() {
  echo "v1.5.2: check_omc_registration skips when ~/.claude/ missing (not installed)"
  (
    setup_mock_home
    # No ~/.claude/ dir at all — Claude Code not installed
    source_doctor_no_main
    PASS=(); WARN=(); FAIL=()
    QUIET=1
    check_omc_registration
    local has_skip_note=false has_warn=false
    for x in "${WARN[@]:-}"; do
      [[ -n "$x" ]] && has_warn=true
    done
    teardown_mock_home
    if [[ "$has_warn" == "false" ]]; then
      exit 0
    else
      echo "  RED: expected no WARN when Claude Code not installed, got WARN=(${WARN[*]:-})"
      exit 1
    fi
  )
  local rc=$?
  assert "v1.5.2 OMC skip when ~/.claude/ missing" "$([[ $rc -eq 0 ]] && echo true || echo false)"
}

test_v152_omc_warn_when_installed_no_settings() {
  echo "v1.5.2: check_omc_registration WARNs when Claude Code installed but settings.json missing"
  (
    setup_mock_home
    mkdir -p "$HOME/.claude"
    # ~/.claude/ exists but no settings.json — installed but not initialized
    source_doctor_no_main
    PASS=(); WARN=(); FAIL=()
    QUIET=1
    check_omc_registration
    local has_warn=false
    for x in "${WARN[@]:-}"; do
      [[ "$x" == *"settings.json"* || "$x" == *"not initialized"* ]] && has_warn=true
    done
    teardown_mock_home
    if [[ "$has_warn" == "true" ]]; then
      exit 0
    else
      echo "  RED: expected WARN about settings.json, got WARN=(${WARN[*]:-})"
      exit 1
    fi
  )
  local rc=$?
  assert "v1.5.2 OMC WARNs when installed but missing settings.json" "$([[ $rc -eq 0 ]] && echo true || echo false)"
}

# --- v1.5.2 F2: OMO auto-registration (install.sh writes hooks.json) ---
# Tested in tests/run_install.sh — doctor side just verifies result.

echo "Running doctor.sh tests..."
echo ""
test_p0_1_omo_check_exists
test_p0_1_omo_missing_hook
test_p0_2_matcher_mismatch_is_fail
test_p0_3_no_hang_on_empty
test_p0_3_no_hang_direct
test_v14_openspec_detected
test_v14_openspec_absent
test_v14_bdd_features_present
test_v14_bdd_features_empty
test_v14_not_git_repo_skip
test_v15_step_defs_present
test_v15_step_defs_missing
test_v15_step_defs_skip_no_features
test_v152_omc_skip_when_not_installed
test_v152_omc_warn_when_installed_no_settings
test_v151_superpowers_function_declared
test_v151_superpowers_all_present_cc_switch
test_v151_superpowers_partial_missing_brainstorming
test_v151_superpowers_all_missing
test_v151_superpowers_cross_platform

echo ""
echo "Results: $PASS_COUNT passed, $FAIL_COUNT failed"
[[ $FAIL_COUNT -gt 0 ]] && exit 1
exit 0
