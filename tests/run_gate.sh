#!/usr/bin/env bash
# Tests for agent-quality-gate.sh — CHECK 1 (OpenSpec) + CHECK 2 (BDD .feature).
# Strategy: create a mock git repo with staged files, run the gate script,
# assert exit codes and output messages.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GATE="$SCRIPT_DIR/../hooks/git/agent-quality-gate.sh"
RESULTS_FILE=$(mktemp)
echo "0 0" > "$RESULTS_FILE"

setup_mock_repo() {
  MOCK_REPO=$(mktemp -d)
  cd "$MOCK_REPO" || exit 1
  git init -q
  git config user.email "test@test.com"
  git config user.name "Test"
  # Initial commit so HEAD exists
  echo "init" > README.md
  git add README.md
  git commit -q -m "init"
  export AGENT_MODE=1
}

teardown_mock_repo() {
  cd /
  [[ -n "${MOCK_REPO:-}" && -d "$MOCK_REPO" ]] && rm -rf "$MOCK_REPO"
}

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

# =====================================================================
# CHECK 1: OpenSpec change detection (Path A only)
# =====================================================================

# T1: PASS when openspec/changes/ has an active change directory
test_check1_pass_with_active_change() {
  echo "T1: CHECK 1 passes when openspec/changes/ has active change"
  (
    setup_mock_repo
    mkdir -p openspec/changes/add-login
    echo "name: add-login" > openspec/changes/add-login/change.yaml
    mkdir -p features
    echo -e "Feature: Login\n  Scenario: Valid\n    Given a user\n    Then success" > features/login.feature
    # Create a source file + test to satisfy Gate 1
    echo "export const login = () => {}" > src.ts
    echo "test('login', () => {})" > src.test.ts
    git add src.ts src.test.ts
    output=$(bash "$GATE" 2>&1)
    rc=$?
    assert "exits 0 with active OpenSpec change" "$([[ $rc -eq 0 ]] && echo true || echo false)"
    teardown_mock_repo
  )
}

# T2: FAIL when openspec/changes/ exists but is empty (no active change)
test_check1_fail_no_active_change() {
  echo "T2: CHECK 1 fails when openspec/changes/ exists but empty"
  (
    setup_mock_repo
    mkdir -p openspec/changes
    # Source file that triggers non-trivial gate
    echo "export const login = () => {}" > src.ts
    echo "test('login', () => {})" > src.test.ts
    git add src.ts src.test.ts
    output=$(bash "$GATE" 2>&1)
    rc=$?
    assert "exits 1 when no active OpenSpec change" "$([[ $rc -ne 0 ]] && echo true || echo false)"
    assert "output mentions OpenSpec" "$(echo "$output" | grep -qi 'openspec' && echo true || echo false)"
    teardown_mock_repo
  )
}

# T3: SKIP when project has no openspec/ at all (Path B — no check)
test_check1_skip_path_b() {
  echo "T3: CHECK 1 skips for Path B (no openspec/)"
  (
    setup_mock_repo
    echo "export const foo = () => {}" > src.ts
    echo "test('foo', () => {})" > src.test.ts
    git add src.ts src.test.ts
    output=$(bash "$GATE" 2>&1)
    rc=$?
    assert "exits 0 for Path B project" "$([[ $rc -eq 0 ]] && echo true || echo false)"
    assert "no OpenSpec mention for Path B" "$(echo "$output" | grep -qi 'openspec' && echo false || echo true)"
    teardown_mock_repo
  )
}

# =====================================================================
# CHECK 2: BDD .feature file detection (Path A; recommended Path B)
# =====================================================================

# T4: PASS when new source has corresponding .feature
test_check2_pass_with_feature() {
  echo "T4: CHECK 2 passes when features/*.feature exists for new source"
  (
    setup_mock_repo
    mkdir -p openspec/changes/add-login
    echo "name: add-login" > openspec/changes/add-login/change.yaml
    mkdir -p features
    cat > features/login.feature << 'FEAT'
Feature: Login
  Scenario: Valid login
    Given a user
    When they login
    Then success
FEAT
    echo "export const login = () => {}" > src.ts
    echo "test('login', () => {})" > src.test.ts
    git add src.ts src.test.ts
    output=$(bash "$GATE" 2>&1)
    rc=$?
    assert "exits 0 with .feature present" "$([[ $rc -eq 0 ]] && echo true || echo false)"
    teardown_mock_repo
  )
}

# T5: FAIL when Path A project has new source but no features/ at all
test_check2_fail_no_features_dir() {
  echo "T5: CHECK 2 fails when Path A has new source but no features/"
  (
    setup_mock_repo
    mkdir -p openspec/changes/add-login
    echo "name: add-login" > openspec/changes/add-login/change.yaml
    echo "export const login = () => {}" > src.ts
    echo "test('login', () => {})" > src.test.ts
    git add src.ts src.test.ts
    output=$(bash "$GATE" 2>&1)
    rc=$?
    assert "exits 1 without features/" "$([[ $rc -ne 0 ]] && echo true || echo false)"
    assert "output mentions .feature" "$(echo "$output" | grep -qi 'feature' && echo true || echo false)"
    teardown_mock_repo
  )
}

# T6: FAIL when Path A has features/ but no .feature files
test_check2_fail_empty_features() {
  echo "T6: CHECK 2 fails when features/ exists but no .feature files"
  (
    setup_mock_repo
    mkdir -p openspec/changes/add-login
    echo "name: add-login" > openspec/changes/add-login/change.yaml
    mkdir -p features
    echo "export const login = () => {}" > src.ts
    echo "test('login', () => {})" > src.test.ts
    git add src.ts src.test.ts
    output=$(bash "$GATE" 2>&1)
    rc=$?
    assert "exits 1 with empty features/" "$([[ $rc -ne 0 ]] && echo true || echo false)"
    teardown_mock_repo
  )
}

# T7: SKIP CHECK 2 for Path B (no openspec/) — .feature not required
test_check2_skip_path_b() {
  echo "T7: CHECK 2 skips for Path B (no openspec/)"
  (
    setup_mock_repo
    echo "export const foo = () => {}" > src.ts
    echo "test('foo', () => {})" > src.test.ts
    git add src.ts src.test.ts
    output=$(bash "$GATE" 2>&1)
    rc=$?
    assert "exits 0 for Path B without features/" "$([[ $rc -eq 0 ]] && echo true || echo false)"
    teardown_mock_repo
  )
}

# T8: Trivial change skips all gates (including CHECK 1 + 2)
test_trivial_skip() {
  echo "T8: Trivial change skips all gates"
  (
    setup_mock_repo
    mkdir -p openspec/changes  # empty openspec — would fail CHECK 1 if not trivial
    echo "fix typo" >> README.md
    git add README.md
    output=$(bash "$GATE" 2>&1)
    rc=$?
    assert "exits 0 for trivial change even with empty openspec" "$([[ $rc -eq 0 ]] && echo true || echo false)"
    teardown_mock_repo
  )
}

# T9: Path A via .claude/skills/openspec-propose (no openspec/changes/ dir)
test_check1_skill_dir_no_changes() {
  echo "T9: CHECK 1 skips when Path A via skill dir but no openspec/changes/"
  (
    setup_mock_repo
    mkdir -p .claude/skills/openspec-propose
    mkdir -p features
    echo -e "Feature: X\n  Scenario: Y\n    Given a\n    Then b" > features/x.feature
    echo "export const foo = () => {}" > src.ts
    echo "test('foo', () => {})" > src.test.ts
    git add src.ts src.test.ts
    output=$(bash "$GATE" 2>&1)
    rc=$?
    assert "does not crash when openspec/changes/ absent" "$([[ $rc -eq 0 ]] && echo true || echo false)"
    teardown_mock_repo
  )
}

# T10: Path A via .opencode/skills/openspec-propose
test_check1_opencode_skill_dir() {
  echo "T10: Path A detected via .opencode/skills/openspec-propose"
  (
    setup_mock_repo
    mkdir -p .opencode/skills/openspec-propose
    # No openspec/changes/ and no features/ → CHECK 2 should fail
    echo "export const foo = () => {}" > src.ts
    echo "test('foo', () => {})" > src.test.ts
    git add src.ts src.test.ts
    output=$(bash "$GATE" 2>&1)
    rc=$?
    assert "exits 1 (CHECK 2 fails, no features/)" "$([[ $rc -ne 0 ]] && echo true || echo false)"
    assert "is treated as Path A" "$(echo "$output" | grep -qi 'feature' && echo true || echo false)"
    teardown_mock_repo
  )
}

# =====================================================================
# Run all tests
# =====================================================================
echo "=== agent-quality-gate.sh CHECK 1 + CHECK 2 tests ==="
echo ""

test_check1_pass_with_active_change
test_check1_fail_no_active_change
test_check1_skip_path_b
test_check2_pass_with_feature
test_check2_fail_no_features_dir
test_check2_fail_empty_features
test_check2_skip_path_b
test_trivial_skip
test_check1_skill_dir_no_changes
test_check1_opencode_skill_dir

echo ""
read -r PASS_COUNT FAIL_COUNT < "$RESULTS_FILE"
rm -f "$RESULTS_FILE"
echo "$PASS_COUNT pass · $FAIL_COUNT fail"
[[ "$FAIL_COUNT" -eq 0 ]] && exit 0 || exit 1
