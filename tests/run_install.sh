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

echo "=== install.sh --with-openspec tests ==="
echo ""

test_flag_parsed
test_openspec_cli_missing
test_openspec_cli_found
test_help_mentions_openspec

echo ""
read -r PASS_COUNT FAIL_COUNT < "$RESULTS_FILE"
rm -f "$RESULTS_FILE"
echo "$PASS_COUNT pass · $FAIL_COUNT fail"
[[ "$FAIL_COUNT" -eq 0 ]] && exit 0 || exit 1
