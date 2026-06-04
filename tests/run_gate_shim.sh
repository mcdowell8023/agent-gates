#!/usr/bin/env bash
# Tests for hooks/git/gate-shim.sh — the per-project thin shim that delegates to the
# globally-installed authority gate (so install --upgrade upgrades every project).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SHIM="$SCRIPT_DIR/../hooks/git/gate-shim.sh"
RESULTS_FILE=$(mktemp); echo "0 0" > "$RESULTS_FILE"

assert() {
  local name="$1" cond="$2" p f
  read -r p f < "$RESULTS_FILE"
  if [[ "$cond" == "true" ]]; then echo "  ✓ $name"; echo "$((p+1)) $f" > "$RESULTS_FILE";
  else echo "  ✗ $name"; echo "$p $((f+1))" > "$RESULTS_FILE"; fi
}

# Fake authority gate whose exit code + echoed args we control.
make_fake_authority() {
  FAKE_DIR=$(mktemp -d)
  local rc="$1"
  cat > "$FAKE_DIR/authority" <<FAKE
#!/usr/bin/env bash
echo "AUTHORITY RAN: \$*"
exit $rc
FAKE
  chmod +x "$FAKE_DIR/authority"
}

echo "=== gate-shim.sh tests ==="
echo ""

# T1: authority present → shim delegates, passes args, returns authority's exit 0
test_delegates_pass() {
  echo "T1: authority present → delegate + pass args (exit 0)"
  ( make_fake_authority 0
    out=$(AGENT_GATES_GATE="$FAKE_DIR/authority" bash "$SHIM" some-arg 2>/dev/null); rc=$?
    assert "exit 0 from authority" "$([[ $rc -eq 0 ]] && echo true || echo false)"
    assert "delegated (AUTHORITY RAN)" "$(echo "$out" | grep -q 'AUTHORITY RAN: some-arg' && echo true || echo false)"
    rm -rf "$FAKE_DIR" )
}

# T2: authority returns non-zero → shim preserves it (exec)
test_preserves_exit() {
  echo "T2: authority exit 1 → shim exit 1 (exec preserves)"
  ( make_fake_authority 1
    AGENT_GATES_GATE="$FAKE_DIR/authority" bash "$SHIM" >/dev/null 2>&1; rc=$?
    assert "exit 1 preserved" "$([[ $rc -eq 1 ]] && echo true || echo false)"
    rm -rf "$FAKE_DIR" )
}

# T3: authority missing → shim does NOT block (exit 0) + warns
test_missing_authority_skips() {
  echo "T3: authority missing → exit 0 (don't block) + warn"
  ( out=$(AGENT_GATES_GATE="/nonexistent/authority/gate.sh" bash "$SHIM" 2>&1); rc=$?
    assert "exit 0 (commit not blocked)" "$([[ $rc -eq 0 ]] && echo true || echo false)"
    assert "warns about missing authority" "$(echo "$out" | grep -qi 'agent-gates' && echo true || echo false)" )
}

# T4: args with spaces are passed through intact (exec "$@") (codex REVISE #6)
test_args_with_spaces() {
  echo "T4: arg with spaces preserved through delegation"
  ( make_fake_authority 0
    out=$(AGENT_GATES_GATE="$FAKE_DIR/authority" bash "$SHIM" "arg with spaces" second 2>/dev/null)
    # fake echoes "AUTHORITY RAN: $*"; with 2 args the spaced one must stay one token
    assert "spaced arg intact (not split)" "$(echo "$out" | grep -q 'AUTHORITY RAN: arg with spaces second' && echo true || echo false)"
    rm -rf "$FAKE_DIR" )
}

test_delegates_pass
test_preserves_exit
test_missing_authority_skips
test_args_with_spaces

echo ""
read -r PASS FAIL < "$RESULTS_FILE"; rm -f "$RESULTS_FILE"
echo "$PASS pass · $FAIL fail"
[[ "$FAIL" -eq 0 ]] && exit 0 || exit 1
