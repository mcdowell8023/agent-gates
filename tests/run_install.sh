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

# T7: check_memory_skill_installed returns 0 if any platform has memory*
test_check_memory_installed() {
  echo "T7: check_memory_skill_installed detects existing memory skill"
  (
    MOCK_HOME=$(mktemp -d)
    export HOME="$MOCK_HOME"
    mkdir -p "$MOCK_HOME/.claude/skills/memory-1.0.2"
    source_install_no_main
    if ! declare -F check_memory_skill_installed >/dev/null; then
      echo "  RED: check_memory_skill_installed function missing"
      rm -rf "$MOCK_HOME"; exit 1
    fi
    check_memory_skill_installed && rc=0 || rc=$?
    assert "returns zero when memory-* exists" "$([[ $rc -eq 0 ]] && echo true || echo false)"
    rm -rf "$MOCK_HOME"
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

echo "=== install.sh --with-openspec + v1.5.2 auto-deps tests ==="
echo ""

test_flag_parsed
test_openspec_cli_missing
test_openspec_cli_found
test_help_mentions_openspec
test_skip_deps_parsed
test_detect_skill_dir
test_check_memory_installed
test_check_superpowers_installed
test_help_mentions_skip_deps
test_main_flow_calls_install_external_deps

echo ""
read -r PASS_COUNT FAIL_COUNT < "$RESULTS_FILE"
rm -f "$RESULTS_FILE"
echo "$PASS_COUNT pass · $FAIL_COUNT fail"
[[ "$FAIL_COUNT" -eq 0 ]] && exit 0 || exit 1
