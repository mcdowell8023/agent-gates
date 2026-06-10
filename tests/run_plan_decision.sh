#!/usr/bin/env bash
# Tests for bin/agent-gates-plan-decision — generate plan decision artifacts.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DECISION_CMD="$SCRIPT_DIR/../bin/agent-gates-plan-decision"
RESULTS_FILE=$(mktemp); echo "0 0" > "$RESULTS_FILE"

assert() {
  local name="$1" cond="$2" p f
  read -r p f < "$RESULTS_FILE"
  if [[ "$cond" == "true" ]]; then echo "  ✓ $name"; echo "$((p+1)) $f" > "$RESULTS_FILE";
  else echo "  ✗ $name"; echo "$p $((f+1))" > "$RESULTS_FILE"; fi
}

echo "=== agent-gates-plan-decision tests ==="
echo ""

# T1: skip generates .skip.md with metadata
test_skip_generates() {
  echo "T1: skip → .skip.md with metadata"
  ROOT=$(mktemp -d); mkdir -p "$ROOT/.agent/plans"
  cd "$ROOT" && git init -q && git commit --allow-empty -m "init" -q
  bash "$DECISION_CMD" skip --reason "trivial config change" --topic "config-fix" --dir "$ROOT" 2>/dev/null
  rc=$?
  assert "exit 0" "$([[ $rc -eq 0 ]] && echo true || echo false)"
  assert ".skip.md exists" "$([[ -f "$ROOT/.agent/plans/config-fix.skip.md" ]] && echo true || echo false)"
  assert "has GENERATED_BY" "$(grep -q 'GENERATED_BY: agent-gates' "$ROOT/.agent/plans/config-fix.skip.md" 2>/dev/null && echo true || echo false)"
  assert "has reason" "$(grep -q 'trivial config change' "$ROOT/.agent/plans/config-fix.skip.md" 2>/dev/null && echo true || echo false)"
  assert "has branch" "$(grep -q 'BRANCH:' "$ROOT/.agent/plans/config-fix.skip.md" 2>/dev/null && echo true || echo false)"
  assert "has HEAD" "$(grep -q 'HEAD:' "$ROOT/.agent/plans/config-fix.skip.md" 2>/dev/null && echo true || echo false)"
  assert "has timestamp" "$(grep -q 'TIMESTAMP:' "$ROOT/.agent/plans/config-fix.skip.md" 2>/dev/null && echo true || echo false)"
  rm -rf "$ROOT"
}

# T2: skip without --reason → error
test_skip_no_reason() {
  echo "T2: skip without --reason → error"
  ROOT=$(mktemp -d); mkdir -p "$ROOT/.agent/plans"
  bash "$DECISION_CMD" skip --topic "x" --dir "$ROOT" 2>/dev/null
  rc=$?
  assert "exit non-zero" "$([[ $rc -ne 0 ]] && echo true || echo false)"
  rm -rf "$ROOT"
}

# T3: hand-written .skip.md (no GENERATED_BY) should be distinguishable
test_handwritten_detectable() {
  echo "T3: hand-written skip detectable (no GENERATED_BY)"
  ROOT=$(mktemp -d); mkdir -p "$ROOT/.agent/plans"
  echo "I skip this because reasons" > "$ROOT/.agent/plans/fake.skip.md"
  assert "no GENERATED_BY in handwritten" "$(grep -q 'GENERATED_BY: agent-gates' "$ROOT/.agent/plans/fake.skip.md" && echo false || echo true)"
  rm -rf "$ROOT"
}

# T4: no .agent/plans → error
test_no_plans_dir() {
  echo "T4: no .agent/plans → error"
  ROOT=$(mktemp -d)
  bash "$DECISION_CMD" skip --reason "test" --topic "x" --dir "$ROOT" 2>/dev/null
  rc=$?
  assert "exit non-zero" "$([[ $rc -ne 0 ]] && echo true || echo false)"
  rm -rf "$ROOT"
}

test_skip_generates
test_skip_no_reason
test_handwritten_detectable
test_no_plans_dir

echo ""
read -r PASS FAIL < "$RESULTS_FILE"; rm -f "$RESULTS_FILE"
echo "$PASS pass · $FAIL fail"
[[ "$FAIL" -eq 0 ]] && exit 0 || exit 1
