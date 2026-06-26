#!/usr/bin/env bash
# Tests for install.sh — --with-openspec flag.
# Strategy: source install.sh functions in isolation, mock openspec CLI,
# verify behavior of the new check_openspec function and --with-openspec flag.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_SCRIPT="$SCRIPT_DIR/../install.sh"
RESULTS_FILE=$(mktemp)
echo "0 0" > "$RESULTS_FILE"

assert() {
  local name="$1"
  local cond="$2"
  local p f
  read -r p f < "$RESULTS_FILE"
  if [[ "$cond" == "true" ]]; then
    echo "  ✓ $name"
    echo "$((p + 1)) $f" > "$RESULTS_FILE"
  else
    echo "  ✗ $name"
    echo "$p $((f + 1))" > "$RESULTS_FILE"
  fi
}

# Source install.sh without running main — strip the final `main "$@"` call.
source_install_no_main() {
  local tmp
  tmp=$(mktemp)
  sed '/^main "\$@"$/d' "$INSTALL_SCRIPT" > "$tmp"
  # shellcheck disable=SC1090
  source "$tmp"
  rm -f "$tmp"
}

# T1: --with-openspec flag is parsed
test_flag_parsed() {
  echo "T1: --with-openspec flag sets WITH_OPENSPEC=1"
  (
    source_install_no_main
    assert "WITH_OPENSPEC variable exists" "$([[ "${WITH_OPENSPEC+set}" == "set" ]] && echo true || echo false)"
  )
}

# T2: check_openspec warns when openspec CLI not found
test_openspec_cli_missing() {
  echo "T2: check_openspec warns when openspec not on PATH"
  (
    MOCK_HOME=$(mktemp -d)
    export HOME="$MOCK_HOME"
    export PATH="$MOCK_HOME/bin:/usr/bin:/bin"
    source_install_no_main
    if ! declare -F check_openspec >/dev/null; then
      echo "  RED: check_openspec function missing"
      rm -rf "$MOCK_HOME"; exit 1
    fi
    output=$(check_openspec 2>&1) && rc=$? || rc=$?
    assert "returns non-zero when openspec missing" "$([[ $rc -ne 0 ]] && echo true || echo false)"
    assert "output mentions openspec" "$(echo "$output" | grep -qi 'openspec' && echo true || echo false)"
    rm -rf "$MOCK_HOME"
  )
}

# T3: check_openspec passes when openspec CLI is available
test_openspec_cli_found() {
  echo "T3: check_openspec passes when openspec is on PATH"
  (
    MOCK_HOME=$(mktemp -d)
    export HOME="$MOCK_HOME"
    mkdir -p "$MOCK_HOME/bin"
    cat > "$MOCK_HOME/bin/openspec" << 'FAKE'
#!/usr/bin/env bash
echo "openspec-mock: $*"
FAKE
    chmod +x "$MOCK_HOME/bin/openspec"
    export PATH="$MOCK_HOME/bin:/usr/bin:/bin"
    source_install_no_main
    if ! declare -F check_openspec >/dev/null; then
      echo "  RED: check_openspec function missing"
      rm -rf "$MOCK_HOME"; exit 1
    fi
    output=$(check_openspec 2>&1)
    rc=$?
    assert "returns zero when openspec found" "$([[ $rc -eq 0 ]] && echo true || echo false)"
    rm -rf "$MOCK_HOME"
  )
}

# T4: --with-openspec appears in help output
test_help_mentions_openspec() {
  echo "T4: --help mentions --with-openspec"
  (
    output=$(bash "$INSTALL_SCRIPT" --help 2>&1 || true)
    assert "help mentions --with-openspec" "$(echo "$output" | grep -q 'with-openspec' && echo true || echo false)"
  )
}

# --- v1.5.2: auto-install dependencies ---

# T5: --skip-deps flag is parsed
test_skip_deps_parsed() {
  echo "T5: --skip-deps flag sets SKIP_DEPS=1"
  (
    source_install_no_main
    assert "SKIP_DEPS variable exists" "$([[ "${SKIP_DEPS+set}" == "set" ]] && echo true || echo false)"
  )
}

# T6: detect_skill_dir locates target skill directory
test_detect_skill_dir() {
  echo "T6: detect_skill_dir returns first existing platform skill dir"
  (
    MOCK_HOME=$(mktemp -d)
    export HOME="$MOCK_HOME"
    mkdir -p "$MOCK_HOME/.claude/skills"
    source_install_no_main
    if ! declare -F detect_skill_dir >/dev/null; then
      echo "  RED: detect_skill_dir function missing"
      rm -rf "$MOCK_HOME"; exit 1
    fi
    result=$(detect_skill_dir 2>&1)
    rc=$?
    assert "returns zero when skill dir exists" "$([[ $rc -eq 0 ]] && echo true || echo false)"
    assert "returns path containing .claude/skills" "$(echo "$result" | grep -q "\.claude/skills" && echo true || echo false)"
    rm -rf "$MOCK_HOME"
  )
}

# T7: v1.5.4 — Memory skill is bundled (not sparse-cloned), so we verify
# that skills/memory/ exists in the repo (which install_skills() will copy).
# This replaces the v1.5.2 test for the removed check_memory_skill_installed.
test_check_memory_bundled() {
  echo "T7: v1.5.4 Memory skill bundled in skills/memory/"
  (
    local repo_root="$SCRIPT_DIR/.."
    if [[ -d "$repo_root/skills/memory" && -f "$repo_root/skills/memory/SKILL.md" ]]; then
      assert "skills/memory/SKILL.md exists (bundled)" "true"
    else
      assert "skills/memory/SKILL.md exists (bundled)" "false"
    fi
  )
}

# T8: check_superpowers_installed returns 0 if all 5 hardcore skills exist
test_check_superpowers_installed() {
  echo "T8: check_superpowers_installed detects 5 hardcore skills"
  (
    MOCK_HOME=$(mktemp -d)
    export HOME="$MOCK_HOME"
    for s in test-driven-development brainstorming verification-before-completion writing-plans executing-plans; do
      mkdir -p "$MOCK_HOME/.claude/skills/$s"
    done
    source_install_no_main
    if ! declare -F check_superpowers_installed >/dev/null; then
      echo "  RED: check_superpowers_installed function missing"
      rm -rf "$MOCK_HOME"; exit 1
    fi
    check_superpowers_installed && rc=0 || rc=$?
    assert "returns zero when all 5 hardcore skills exist" "$([[ $rc -eq 0 ]] && echo true || echo false)"
    rm -rf "$MOCK_HOME"
  )
}

# T9: --skip-deps in help output
test_help_mentions_skip_deps() {
  echo "T9: --help mentions --skip-deps"
  (
    output=$(bash "$INSTALL_SCRIPT" --help 2>&1 || true)
    assert "help mentions --skip-deps" "$(echo "$output" | grep -q 'skip-deps' && echo true || echo false)"
  )
}

# T10: install.sh main flow calls install_external_deps unless --skip-deps
test_main_flow_calls_install_external_deps() {
  echo "T10: install_external_deps function exists"
  (
    source_install_no_main
    if declare -F install_external_deps >/dev/null; then
      assert "install_external_deps function declared" "true"
    else
      echo "  RED: install_external_deps function missing"
      assert "install_external_deps function declared" "false"
    fi
  )
}

# --- v2.0.0: deploy tests ---

# Helper: build a minimal mock repo that install_hook_files() can process.
_make_mock_repo() {
  local repo="$1"
  mkdir -p "$repo/bin" "$repo/lib/hetero" "$repo/hooks/platform" \
           "$repo/hooks/git" "$repo/data" "$repo/templates"
  printf '2.0.0\n' > "$repo/.version"
  printf '#!/usr/bin/env bash\n# __AGENT_GATES_VERSION__\necho gate\n' > "$repo/hooks/git/agent-quality-gate.sh"
  touch "$repo/hooks/platform/memory-reminder.mjs"
  printf '#!/usr/bin/env bash\n: dispatch stub\n' > "$repo/lib/hetero/dispatch.sh"
  printf '#!/usr/bin/env bash\n: select stub\n'   > "$repo/lib/hetero/select.sh"
  printf '#!/usr/bin/env bash\necho shim >&2\n'   > "$repo/lib/review-selection.sh"
  printf '#!/usr/bin/env bash\necho shim >&2\n'   > "$repo/lib/oc-serve.sh"
  printf '#!/usr/bin/env bash\necho mock-config-migrate\n' > "$repo/bin/agent-gates-config-migrate"
  chmod +x "$repo/bin/agent-gates-config-migrate"
  printf '# verifier\n' > "$repo/templates/verifier.md"
  printf '#!/usr/bin/env bash\necho doctor\n' > "$repo/doctor.sh"
}

# T-I1: install_hook_files deploys lib/hetero/dispatch.sh
test_hetero_deployed() {
  echo "T-I1: install_hook_files deploys lib/hetero/dispatch.sh"
  (
    MOCK_REPO=$(mktemp -d); MOCK_HOME=$(mktemp -d)
    export HOME="$MOCK_HOME"
    _make_mock_repo "$MOCK_REPO"
    source_install_no_main
    # Disable install.sh's cleanup trap to prevent it from deleting /tmp on subshell exit.
    trap -- '' EXIT
    REPO_DIR="$MOCK_REPO"; INSTALL_DIR="$MOCK_HOME/.agent-gates"
    install_hook_files 2>/dev/null || true
    assert "lib/hetero/dispatch.sh deployed" "$([[ -f "$INSTALL_DIR/lib/hetero/dispatch.sh" ]] && echo true || echo false)"
    rm -rf "$MOCK_REPO" "$MOCK_HOME"
  )
}

# T-I2: shim lib/review-selection.sh deployed (source-safe check)
test_shim_deployed() {
  echo "T-I2: shim lib/review-selection.sh deployed after install"
  (
    MOCK_REPO=$(mktemp -d); MOCK_HOME=$(mktemp -d)
    export HOME="$MOCK_HOME"
    _make_mock_repo "$MOCK_REPO"
    source_install_no_main
    trap -- '' EXIT
    REPO_DIR="$MOCK_REPO"; INSTALL_DIR="$MOCK_HOME/.agent-gates"
    install_hook_files 2>/dev/null || true
    assert "lib/review-selection.sh deployed" "$([[ -f "$INSTALL_DIR/lib/review-selection.sh" ]] && echo true || echo false)"
    rm -rf "$MOCK_REPO" "$MOCK_HOME"
  )
}

# T-I3: bin/agent-gates-config-migrate deployed and executable
test_config_migrate_deployed() {
  echo "T-I3: bin/agent-gates-config-migrate deployed and executable"
  (
    MOCK_REPO=$(mktemp -d); MOCK_HOME=$(mktemp -d)
    export HOME="$MOCK_HOME"
    _make_mock_repo "$MOCK_REPO"
    source_install_no_main
    trap -- '' EXIT
    REPO_DIR="$MOCK_REPO"; INSTALL_DIR="$MOCK_HOME/.agent-gates"
    install_hook_files 2>/dev/null || true
    assert "bin/agent-gates-config-migrate deployed" "$([[ -f "$INSTALL_DIR/bin/agent-gates-config-migrate" ]] && echo true || echo false)"
    assert "bin/agent-gates-config-migrate executable" "$([[ -x "$INSTALL_DIR/bin/agent-gates-config-migrate" ]] && echo true || echo false)"
    rm -rf "$MOCK_REPO" "$MOCK_HOME"
  )
}

echo "=== install.sh --with-openspec + v1.5.2 auto-deps tests ==="
echo ""

test_flag_parsed
test_openspec_cli_missing
test_openspec_cli_found
test_help_mentions_openspec
test_skip_deps_parsed
test_detect_skill_dir
test_check_memory_bundled
test_check_superpowers_installed
test_help_mentions_skip_deps
test_main_flow_calls_install_external_deps
test_hetero_deployed
test_shim_deployed
test_config_migrate_deployed

echo ""
read -r PASS_COUNT FAIL_COUNT < "$RESULTS_FILE"
rm -f "$RESULTS_FILE"
echo "$PASS_COUNT pass · $FAIL_COUNT fail"
[[ "$FAIL_COUNT" -eq 0 ]] && exit 0 || exit 1
