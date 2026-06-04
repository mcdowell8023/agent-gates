#!/usr/bin/env bash
# Tests for bin/agent-gates-version — show the global gate authority version, and
# optionally per-project shim/stale status.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERSION_BIN="$SCRIPT_DIR/../bin/agent-gates-version"
SHIM_REAL="$SCRIPT_DIR/../hooks/git/gate-shim.sh"
RESULTS_FILE=$(mktemp); echo "0 0" > "$RESULTS_FILE"

assert() {
  local name="$1" cond="$2" p f
  read -r p f < "$RESULTS_FILE"
  if [[ "$cond" == "true" ]]; then echo "  ✓ $name"; echo "$((p+1)) $f" > "$RESULTS_FILE";
  else echo "  ✗ $name"; echo "$p $((f+1))" > "$RESULTS_FILE"; fi
}

# Fake install dir with .version + a stamped authority gate.
make_install() {
  local ver="$1" stamped="$2"
  INST=$(mktemp -d); mkdir -p "$INST/hooks/git"
  echo "$ver" > "$INST/.version"
  printf '#!/usr/bin/env bash\nGATE_VERSION="%s"\n' "$stamped" > "$INST/hooks/git/agent-quality-gate.sh"
}

echo "=== agent-gates-version tests ==="
echo ""

# T1: prints global authority version
test_global_version() {
  echo "T1: prints global version"
  ( make_install "1.9.0" "1.9.0"
    out=$(AGENT_GATES_DIR="$INST" bash "$VERSION_BIN" 2>&1); rc=$?
    assert "exit 0" "$([[ $rc -eq 0 ]] && echo true || echo false)"
    assert "shows v1.9.0" "$(echo "$out" | grep -q 'v1.9.0' && echo true || echo false)"
    rm -rf "$INST" )
}

# T2: stamped != .version → warns drift
test_stamp_drift_warn() {
  echo "T2: stamped≠.version → warn"
  ( make_install "1.9.0" "1.8.0"
    out=$(AGENT_GATES_DIR="$INST" bash "$VERSION_BIN" 2>&1)
    assert "warns about stamp drift" "$(echo "$out" | grep -qiE 'upgrade|≠|!=|drift' && echo true || echo false)"
    rm -rf "$INST" )
}

# T3: with dir → lists shim vs stale projects
test_per_project() {
  echo "T3: per-project shim/stale listing"
  ( make_install "1.9.0" "1.9.0"
    ROOT=$(mktemp -d)
    mkdir -p "$ROOT/p-shim/.githooks" "$ROOT/p-old/.githooks"
    cp "$SHIM_REAL" "$ROOT/p-shim/.githooks/agent-quality-gate.sh"
    printf '# Agent Quality Gate v1.3\n' > "$ROOT/p-old/.githooks/agent-quality-gate.sh"
    out=$(AGENT_GATES_DIR="$INST" bash "$VERSION_BIN" "$ROOT" 2>&1)
    assert "p-shim shown as shim" "$(echo "$out" | grep -E 'p-shim' | grep -qi 'shim' && echo true || echo false)"
    assert "p-old shown as stale" "$(echo "$out" | grep -E 'p-old' | grep -qiE 'stale|migrate' && echo true || echo false)"
    rm -rf "$INST" "$ROOT" )
}

# T4: not installed → exit 69
test_not_installed() {
  echo "T4: not installed → exit 69"
  ( AGENT_GATES_DIR="/nonexistent/agent-gates-xyz" bash "$VERSION_BIN" >/dev/null 2>&1; rc=$?
    assert "exit 69" "$([[ $rc -eq 69 ]] && echo true || echo false)" )
}

# T5: .version present but authority gate missing/not-exec → warn "enforce nothing" (codex REVISE #3)
test_authority_gate_missing() {
  echo "T5: authority gate missing → warn (shim projects enforce nothing)"
  ( INST=$(mktemp -d); mkdir -p "$INST/hooks/git"; echo "1.9.0" > "$INST/.version"
    # no agent-quality-gate.sh authority gate created
    out=$(AGENT_GATES_DIR="$INST" bash "$VERSION_BIN" 2>&1); rc=$?
    assert "still prints version (exit 0)" "$([[ $rc -eq 0 ]] && echo true || echo false)"
    assert "warns authority missing / enforce nothing" "$(echo "$out" | grep -qiE 'missing|enforce nothing|not executable' && echo true || echo false)"
    rm -rf "$INST" )
}

test_global_version
test_stamp_drift_warn
test_per_project
test_not_installed
test_authority_gate_missing

echo ""
read -r PASS FAIL < "$RESULTS_FILE"; rm -f "$RESULTS_FILE"
echo "$PASS pass · $FAIL fail"
[[ "$FAIL" -eq 0 ]] && exit 0 || exit 1
