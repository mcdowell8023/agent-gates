#!/usr/bin/env bash
# Tests for effort selection + is_high_risk_path in lib/hetero/select.sh — P4 effort.
#
# Coverage:
#   T1  select_effort reviewer 0  → "medium" (normal tier default)
#   T2  select_effort reviewer 1  → "high"   (high_risk tier default)
#   T3  env HETERO_EFFORT_VERIFIER_NORMAL=low → select_effort verifier 0 → "low"
#   T4a is_high_risk_path src/auth/login.ts  → exit 0 (high risk)
#   T4b is_high_risk_path README.md          → exit 1 (not high risk)
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SELECTION_LIB="$SCRIPT_DIR/../lib/hetero/select.sh"
RESULTS_FILE=$(mktemp); echo "0 0" > "$RESULTS_FILE"

assert() {
  local name="$1" cond="$2" p f
  read -r p f < "$RESULTS_FILE"
  if [[ "$cond" == "true" ]]; then echo "  ✓ $name"; echo "$((p+1)) $f" > "$RESULTS_FILE";
  else echo "  ✗ $name"; echo "$p $((f+1))" > "$RESULTS_FILE"; fi
}

echo "=== hetero effort selection tests (P4) ==="
echo ""

# T1: select_effort reviewer 0 → "medium" (normal tier default)
test_t1_select_effort_reviewer_normal() {
  echo "T1: select_effort reviewer 0 → medium (normal tier default)"
  (
    unset HETERO_EFFORT_REVIEWER_NORMAL HETERO_EFFORT_REVIEWER_HIGH_RISK 2>/dev/null || true
    source "$SELECTION_LIB"
    local result
    result=$(select_effort "reviewer" "0")
    assert "reviewer 0 → medium (实际 $result)" "$([[ "$result" == "medium" ]] && echo true || echo false)"
  )
}

# T2: select_effort reviewer 1 → "high" (high_risk tier default)
test_t2_select_effort_reviewer_high_risk() {
  echo "T2: select_effort reviewer 1 → high (high_risk tier default)"
  (
    unset HETERO_EFFORT_REVIEWER_NORMAL HETERO_EFFORT_REVIEWER_HIGH_RISK 2>/dev/null || true
    source "$SELECTION_LIB"
    local result
    result=$(select_effort "reviewer" "1")
    assert "reviewer 1 → high (实际 $result)" "$([[ "$result" == "high" ]] && echo true || echo false)"
  )
}

# T3: env override HETERO_EFFORT_VERIFIER_NORMAL=low → select_effort verifier 0 → "low"
test_t3_env_override_verifier_normal() {
  echo "T3: env 覆盖 HETERO_EFFORT_VERIFIER_NORMAL=low → verifier 0 → low"
  (
    unset HETERO_EFFORT_VERIFIER_NORMAL 2>/dev/null || true
    source "$SELECTION_LIB"
    local result
    HETERO_EFFORT_VERIFIER_NORMAL="low" result=$(select_effort "verifier" "0")
    assert "verifier 0 → low (env 覆盖) (实际 $result)" "$([[ "$result" == "low" ]] && echo true || echo false)"
  )
}

# T4a: is_high_risk_path with auth/ file → exit 0 (high risk)
test_t4a_is_high_risk_auth() {
  echo "T4a: is_high_risk_path src/auth/login.ts → exit 0 (高风险)"
  (
    unset HETERO_HIGH_RISK_PATTERNS 2>/dev/null || true
    source "$SELECTION_LIB"
    is_high_risk_path "src/auth/login.ts" 2>/dev/null
    local rc=$?
    assert "auth/ → exit 0 (高风险) (实际 rc=$rc)" "$([[ "$rc" == "0" ]] && echo true || echo false)"
  )
}

# T4b: is_high_risk_path with plain file → exit 1 (not high risk)
test_t4b_is_high_risk_readme() {
  echo "T4b: is_high_risk_path README.md → exit 1 (非高风险)"
  (
    unset HETERO_HIGH_RISK_PATTERNS 2>/dev/null || true
    source "$SELECTION_LIB"
    is_high_risk_path "README.md" 2>/dev/null
    local rc=$?
    assert "README.md → exit 1 (非高风险) (实际 rc=$rc)" "$([[ "$rc" == "1" ]] && echo true || echo false)"
  )
}

test_t1_select_effort_reviewer_normal
test_t2_select_effort_reviewer_high_risk
test_t3_env_override_verifier_normal
test_t4a_is_high_risk_auth
test_t4b_is_high_risk_readme

echo ""
read -r PASS FAIL < "$RESULTS_FILE"
rm -f "$RESULTS_FILE"
echo "$PASS pass · $FAIL fail"
[[ "$FAIL" -eq 0 ]] && exit 0 || exit 1
