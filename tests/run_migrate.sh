#!/usr/bin/env bash
# Tests for bin/agent-gates-migrate — bulk-migrate per-project full-copy gates to the shim.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MIGRATE="$SCRIPT_DIR/../bin/agent-gates-migrate"
SHIM_REAL="$SCRIPT_DIR/../hooks/git/gate-shim.sh"
RESULTS_FILE=$(mktemp); echo "0 0" > "$RESULTS_FILE"

assert() {
  local name="$1" cond="$2" p f
  read -r p f < "$RESULTS_FILE"
  if [[ "$cond" == "true" ]]; then echo "  ✓ $name"; echo "$((p+1)) $f" > "$RESULTS_FILE";
  else echo "  ✗ $name"; echo "$p $((f+1))" > "$RESULTS_FILE"; fi
}

# Build a tree: proj-old (full-copy gate, no shim marker), proj-shim (already shim).
make_tree() {
  ROOT=$(mktemp -d)
  mkdir -p "$ROOT/proj-old/.githooks" "$ROOT/proj-shim/.githooks"
  printf '#!/usr/bin/env bash\n# Agent Quality Gate v1.3\necho old gate\n' > "$ROOT/proj-old/.githooks/agent-quality-gate.sh"
  cp "$SHIM_REAL" "$ROOT/proj-shim/.githooks/agent-quality-gate.sh"
}

echo "=== agent-gates-migrate tests ==="
echo ""

# T1: dry-run → reports 1 to migrate, 1 already shim, modifies NOTHING
test_dryrun() {
  echo "T1: dry-run lists, modifies nothing"
  ( make_tree
    before=$(md5 -q "$ROOT/proj-old/.githooks/agent-quality-gate.sh" 2>/dev/null || md5sum "$ROOT/proj-old/.githooks/agent-quality-gate.sh" | awk '{print $1}')
    out=$(AGENT_GATES_SHIM_SRC="$SHIM_REAL" bash "$MIGRATE" "$ROOT" 2>&1); rc=$?
    after=$(md5 -q "$ROOT/proj-old/.githooks/agent-quality-gate.sh" 2>/dev/null || md5sum "$ROOT/proj-old/.githooks/agent-quality-gate.sh" | awk '{print $1}')
    assert "exit 0" "$([[ $rc -eq 0 ]] && echo true || echo false)"
    assert "reports proj-old as to-migrate" "$(echo "$out" | grep -q 'proj-old' && echo true || echo false)"
    assert "dry-run did NOT modify old gate" "$([[ "$before" == "$after" ]] && echo true || echo false)"
    rm -rf "$ROOT" )
}

# T2: --apply → old gate becomes shim, shim one untouched
test_apply() {
  echo "T2: --apply migrates full-copy → shim"
  ( make_tree
    AGENT_GATES_SHIM_SRC="$SHIM_REAL" bash "$MIGRATE" --apply "$ROOT" >/dev/null 2>&1
    assert "old gate now contains shim marker" "$(grep -q 'per-project gate shim' "$ROOT/proj-old/.githooks/agent-quality-gate.sh" && echo true || echo false)"
    assert "old gate executable" "$([[ -x "$ROOT/proj-old/.githooks/agent-quality-gate.sh" ]] && echo true || echo false)"
    assert "already-shim project unchanged (still shim)" "$(grep -q 'per-project gate shim' "$ROOT/proj-shim/.githooks/agent-quality-gate.sh" && echo true || echo false)"
    rm -rf "$ROOT" )
}

# T3: no dirs → usage error
test_no_dirs() {
  echo "T3: no dirs → usage exit 64"
  ( AGENT_GATES_SHIM_SRC="$SHIM_REAL" bash "$MIGRATE" >/dev/null 2>&1; rc=$?
    assert "exit 64 (usage)" "$([[ $rc -eq 64 ]] && echo true || echo false)" )
}

# T4: shim source missing → exit 69
test_no_shim_src() {
  echo "T4: shim src missing → exit 69"
  ( make_tree
    AGENT_GATES_SHIM_SRC="/nonexistent/gate-shim.sh" bash "$MIGRATE" "$ROOT" >/dev/null 2>&1; rc=$?
    assert "exit 69 (shim src missing)" "$([[ $rc -eq 69 ]] && echo true || echo false)"
    rm -rf "$ROOT" )
}

# T5: a custom/unknown hook sharing the name must NOT be overwritten (codex REVISE #2)
test_unknown_hook_untouched() {
  echo "T5: unknown same-name hook NOT migrated"
  ( ROOT=$(mktemp -d)
    mkdir -p "$ROOT/p-custom/.githooks"
    printf '#!/usr/bin/env bash\n# my hand-written pre-commit, nothing to do with agent-gates\necho custom\n' > "$ROOT/p-custom/.githooks/agent-quality-gate.sh"
    before=$(md5 -q "$ROOT/p-custom/.githooks/agent-quality-gate.sh" 2>/dev/null || md5sum "$ROOT/p-custom/.githooks/agent-quality-gate.sh" | awk '{print $1}')
    out=$(AGENT_GATES_SHIM_SRC="$SHIM_REAL" bash "$MIGRATE" --apply "$ROOT" 2>&1)
    after=$(md5 -q "$ROOT/p-custom/.githooks/agent-quality-gate.sh" 2>/dev/null || md5sum "$ROOT/p-custom/.githooks/agent-quality-gate.sh" | awk '{print $1}')
    assert "custom hook NOT overwritten" "$([[ "$before" == "$after" ]] && echo true || echo false)"
    assert "reports unknown-skipped" "$(echo "$out" | grep -qiE 'unknown|not a recognizable' && echo true || echo false)"
    rm -rf "$ROOT" )
}

test_dryrun
test_apply
test_no_dirs
test_no_shim_src
test_unknown_hook_untouched

echo ""
read -r PASS FAIL < "$RESULTS_FILE"; rm -f "$RESULTS_FILE"
echo "$PASS pass · $FAIL fail"
[[ "$FAIL" -eq 0 ]] && exit 0 || exit 1
