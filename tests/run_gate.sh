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
# CHECK 5b: Heterogeneous review enforcement (v1.7.0)
# =====================================================================

# Build a NEEDS_REVIEW-triggering diff (2 logic files, >50 added lines) + a fresh
# review file, and an isolated review-capability.json at $AGENT_GATES_DIR.
# $1 = REVIEW_LEVEL marker to embed ("" = none); $2 = machine capability level.
setup_review_scenario() {
  local review_marker="$1" cap_level="$2" i n
  for i in 1 2; do
    printf 'export const f%s = () => {\n' "$i" > "mod$i.ts"
    for n in $(seq 1 30); do echo "  // line $n" >> "mod$i.ts"; done
    echo "}" >> "mod$i.ts"
    echo "test('f$i', () => {})" > "mod$i.test.ts"
  done
  git add mod1.ts mod2.ts mod1.test.ts mod2.test.ts
  CAPDIR=$(mktemp -d)
  printf '{\n  "level": "%s"\n}\n' "$cap_level" > "$CAPDIR/review-capability.json"
  export AGENT_GATES_DIR="$CAPDIR"
  # Create review file LAST so its mtime is newest (passes freshness gate)
  mkdir -p .agent/reviews
  {
    [[ -n "$review_marker" ]] && echo "<!-- REVIEW_LEVEL: $review_marker -->"
    echo "# Cross-review"
    echo "Looks correct, no issues."
    echo "VERDICT: PASS"
  } > .agent/reviews/2099-01-01-test.md
}

# T11: machine L3 but review has NO REVIEW_LEVEL marker → block (same-model assumed)
test_hetero_block_unmarked() {
  echo "T11: cap L3 + review unmarked → block"
  (
    setup_mock_repo
    setup_review_scenario "" "L3"
    output=$(bash "$GATE" 2>&1)
    rc=$?
    assert "exits 1 when machine L3 but review unmarked" "$([[ $rc -ne 0 ]] && echo true || echo false)"
    assert "output mentions heterogeneous/REVIEW_LEVEL" "$(echo "$output" | grep -qiE 'heterogen|REVIEW_LEVEL|same-model' && echo true || echo false)"
    rm -rf "${CAPDIR:-}"
    teardown_mock_repo
  )
}

# T12: machine L3 + review explicitly REVIEW_LEVEL: L0 → block
test_hetero_block_l0() {
  echo "T12: cap L3 + review L0 → block"
  (
    setup_mock_repo
    setup_review_scenario "L0" "L3"
    output=$(bash "$GATE" 2>&1)
    rc=$?
    assert "exits 1 when review L0 but machine L3" "$([[ $rc -ne 0 ]] && echo true || echo false)"
    rm -rf "${CAPDIR:-}"
    teardown_mock_repo
  )
}

# T13: machine L3 + review REVIEW_LEVEL: L2 (heterogeneous) → pass
test_hetero_pass_l2() {
  echo "T13: cap L3 + review L2 → pass"
  (
    setup_mock_repo
    setup_review_scenario "L2" "L3"
    output=$(bash "$GATE" 2>&1)
    rc=$?
    assert "exits 0 when review L2 (heterogeneous)" "$([[ $rc -eq 0 ]] && echo true || echo false)"
    rm -rf "${CAPDIR:-}"
    teardown_mock_repo
  )
}

# T14: true L0 machine + unmarked review → pass (no heterogeneous tool available)
test_hetero_pass_l0machine() {
  echo "T14: cap L0 + review unmarked → pass (no alternative)"
  (
    setup_mock_repo
    setup_review_scenario "" "L0"
    output=$(bash "$GATE" 2>&1)
    rc=$?
    assert "exits 0 on true L0 machine" "$([[ $rc -eq 0 ]] && echo true || echo false)"
    rm -rf "${CAPDIR:-}"
    teardown_mock_repo
  )
}

# T15: SKIP_HETERO_CHECK=1 bypasses the block even on L3 machine
test_hetero_skip_override() {
  echo "T15: SKIP_HETERO_CHECK=1 bypasses"
  (
    setup_mock_repo
    setup_review_scenario "L0" "L3"
    output=$(SKIP_HETERO_CHECK=1 bash "$GATE" 2>&1)
    rc=$?
    assert "exits 0 with SKIP_HETERO_CHECK=1" "$([[ $rc -eq 0 ]] && echo true || echo false)"
    rm -rf "${CAPDIR:-}"
    teardown_mock_repo
  )
}

# T16: gate must pick the NEWEST review by mtime, not by filename.
# Bug: `find | sort -r | head -1` sorts by filename, so an old but
# alphabetically-later file (e.g. zzz) shadows the freshly-written one (aaa).
test_review_picks_newest_by_mtime() {
  echo "T16: gate picks newest review by mtime, not filename"
  (
    setup_mock_repo
    local i n
    for i in 1 2; do
      printf 'export const f%s = () => {\n' "$i" > "mod$i.ts"
      for n in $(seq 1 30); do echo "  // line $n" >> "mod$i.ts"; done
      echo "}" >> "mod$i.ts"
      echo "test('f$i', () => {})" > "mod$i.test.ts"
    done
    git add mod1.ts mod2.ts mod1.test.ts mod2.test.ts
    # L0 capability so Gate 2b (heterogeneity) is exempt — isolate selection logic
    CAPDIR=$(mktemp -d)
    printf '{ "level": "L0" }\n' > "$CAPDIR/review-capability.json"
    export AGENT_GATES_DIR="$CAPDIR"
    mkdir -p .agent/reviews
    # OLD file, alphabetically LAST, BAD verdict
    printf '# old\nVERDICT: ISSUES\n' > .agent/reviews/zzz-old.md
    sleep 1
    # NEW file, alphabetically FIRST, GOOD verdict
    printf '# new\nVERDICT: PASS\n' > .agent/reviews/aaa-new.md
    output=$(bash "$GATE" 2>&1)
    rc=$?
    assert "picks newest (aaa=PASS), not alphabetical-last (zzz=ISSUES)" "$([[ $rc -eq 0 ]] && echo true || echo false)"
    rm -rf "${CAPDIR:-}"
    teardown_mock_repo
  )
}

# =====================================================================
# CHECK 3: Plan gate (三态) tests — v1.11.0
# =====================================================================

# Helper: setup a non-trivial commit (multi-file >50 lines, triggers NEEDS_REVIEW)
setup_nontrivial_commit() {
  for i in 1 2 3; do
    printf 'export const fn%s = () => {\n' "$i" > "src$i.ts"
    for n in $(seq 1 25); do echo "  // line $n" >> "src$i.ts"; done
    echo "}" >> "src$i.ts"
    echo "test('fn$i', () => {})" > "src$i.test.ts"
  done
  git add src1.ts src2.ts src3.ts src1.test.ts src2.test.ts src3.test.ts
}

# T-B1: Path B + plan with PLAN_REVIEW → PASS
test_check3_plan_with_review() {
  echo "T-B1: Path B plan + PLAN_REVIEW → PASS"
  (
    setup_mock_repo
    setup_nontrivial_commit
    CAPDIR=$(mktemp -d); printf '{ "level": "L0" }\n' > "$CAPDIR/review-capability.json"
    export AGENT_GATES_DIR="$CAPDIR"
    mkdir -p .agent/reviews .agent/plans
    printf 'VERDICT: PASS\n' > .agent/reviews/r.md
    printf '# Plan\n<!-- PLAN_REVIEW: L1 -->\n<!-- PLAN_REVIEW_TOOL: codex -->\n<!-- PLAN_REVIEW_MODEL: gpt-5 -->\n' > .agent/plans/design.md
    output=$(bash "$GATE" 2>&1); rc=$?
    assert "PASS with plan+review" "$([[ $rc -eq 0 ]] && echo true || echo false)"
    rm -rf "$CAPDIR"; teardown_mock_repo
  )
}

# T-B2: Path B + no plans → FAIL
test_check3_no_plan() {
  echo "T-B2: Path B no plan → FAIL"
  (
    setup_mock_repo
    setup_nontrivial_commit
    CAPDIR=$(mktemp -d); printf '{ "level": "L0" }\n' > "$CAPDIR/review-capability.json"
    export AGENT_GATES_DIR="$CAPDIR"
    mkdir -p .agent/reviews .agent/plans
    printf 'VERDICT: PASS\n' > .agent/reviews/r.md
    # no plan file
    output=$(bash "$GATE" 2>&1); rc=$?
    assert "FAIL without plan" "$([[ $rc -ne 0 ]] && echo true || echo false)"
    rm -rf "$CAPDIR"; teardown_mock_repo
  )
}

# T-B3: Path B + plan without PLAN_REVIEW on L1+ → FAIL
test_check3_plan_no_marker_l1() {
  echo "T-B3: plan without PLAN_REVIEW on L1 → FAIL"
  (
    setup_mock_repo
    setup_nontrivial_commit
    CAPDIR=$(mktemp -d); printf '{ "level": "L1", "preferred_route": "codex" }\n' > "$CAPDIR/review-capability.json"
    export AGENT_GATES_DIR="$CAPDIR"
    mkdir -p .agent/reviews .agent/plans
    printf 'VERDICT: PASS\n<!-- REVIEW_LEVEL: L1 -->\n' > .agent/reviews/r.md
    printf '# Plan\nSome design notes without markers\n' > .agent/plans/design.md
    output=$(bash "$GATE" 2>&1); rc=$?
    assert "FAIL plan without PLAN_REVIEW on L1" "$([[ $rc -ne 0 ]] && echo true || echo false)"
    rm -rf "$CAPDIR"; teardown_mock_repo
  )
}

# T-C1: Plan no marker on L0 → PASS (L0 降级: 方案存在即可)
test_check3_l0_plan_no_marker() {
  echo "T-C1: L0 + plan no marker → PASS (降级)"
  (
    setup_mock_repo
    setup_nontrivial_commit
    CAPDIR=$(mktemp -d); printf '{ "level": "L0" }\n' > "$CAPDIR/review-capability.json"
    export AGENT_GATES_DIR="$CAPDIR"
    mkdir -p .agent/reviews .agent/plans
    printf 'VERDICT: PASS\n' > .agent/reviews/r.md
    printf '# Plan\nSome design notes\n' > .agent/plans/design.md
    output=$(bash "$GATE" 2>&1); rc=$?
    assert "PASS L0 plan exists (no marker required)" "$([[ $rc -eq 0 ]] && echo true || echo false)"
    rm -rf "$CAPDIR"; teardown_mock_repo
  )
}

# T-C2: skip-with-approval → .skip.md with GENERATED_BY → PASS
test_check3_skip_approved() {
  echo "T-C2: skip.md with GENERATED_BY → PASS"
  (
    setup_mock_repo
    setup_nontrivial_commit
    CAPDIR=$(mktemp -d); printf '{ "level": "L0" }\n' > "$CAPDIR/review-capability.json"
    export AGENT_GATES_DIR="$CAPDIR"
    mkdir -p .agent/reviews .agent/plans
    printf 'VERDICT: PASS\n' > .agent/reviews/r.md
    printf 'GENERATED_BY: agent-gates\nTIMESTAMP: 2026-06-10T00:00:00Z\nBRANCH: main\nHEAD: abc1234\nREASON: trivial config\n' > .agent/plans/config.skip.md
    output=$(bash "$GATE" 2>&1); rc=$?
    assert "PASS with approved skip" "$([[ $rc -eq 0 ]] && echo true || echo false)"
    rm -rf "$CAPDIR"; teardown_mock_repo
  )
}

# T-C3: hand-written .skip.md (no GENERATED_BY) → FAIL
test_check3_skip_handwritten() {
  echo "T-C3: hand-written skip.md → FAIL"
  (
    setup_mock_repo
    setup_nontrivial_commit
    CAPDIR=$(mktemp -d); printf '{ "level": "L0" }\n' > "$CAPDIR/review-capability.json"
    export AGENT_GATES_DIR="$CAPDIR"
    mkdir -p .agent/reviews .agent/plans
    printf 'VERDICT: PASS\n' > .agent/reviews/r.md
    printf 'I skip this\n' > .agent/plans/fake.skip.md
    output=$(bash "$GATE" 2>&1); rc=$?
    assert "FAIL hand-written skip" "$([[ $rc -ne 0 ]] && echo true || echo false)"
    rm -rf "$CAPDIR"; teardown_mock_repo
  )
}

# T-C5: SKIP_PLAN_CHECK=1 → bypass
test_check3_skip_env() {
  echo "T-C5: SKIP_PLAN_CHECK=1 → bypass"
  (
    setup_mock_repo
    setup_nontrivial_commit
    CAPDIR=$(mktemp -d); printf '{ "level": "L0" }\n' > "$CAPDIR/review-capability.json"
    export AGENT_GATES_DIR="$CAPDIR"
    mkdir -p .agent/reviews .agent/plans
    printf 'VERDICT: PASS\n' > .agent/reviews/r.md
    # no plan, no skip — would normally fail
    output=$(SKIP_PLAN_CHECK=1 bash "$GATE" 2>&1); rc=$?
    assert "PASS with SKIP_PLAN_CHECK=1" "$([[ $rc -eq 0 ]] && echo true || echo false)"
    rm -rf "$CAPDIR"; teardown_mock_repo
  )
}

# =====================================================================
# Run all tests
# =====================================================================
echo "=== agent-quality-gate.sh tests ==="
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
test_hetero_block_unmarked
test_hetero_block_l0
test_hetero_pass_l2
test_hetero_pass_l0machine
test_hetero_skip_override
test_review_picks_newest_by_mtime
# T-D1: dangerous path (migrations/*.sql) + skip → FAIL (requires-plan, skip not accepted)
test_check3_dangerous_skip_rejected() {
  echo "T-D1: dangerous path + skip → FAIL (requires-plan)"
  (
    setup_mock_repo
    # Create a migration file (dangerous category)
    mkdir -p migrations
    printf 'ALTER TABLE users ADD COLUMN role TEXT;\n' > migrations/001_add_role.sql
    echo "test('migration', () => {})" > migrations/001_add_role.sql.test.ts
    printf 'export const x = 1;\n' > app.ts
    for n in $(seq 1 25); do echo "  // line $n" >> app.ts; done
    echo "test('x', () => {})" > app.test.ts
    git add migrations/001_add_role.sql migrations/001_add_role.sql.test.ts app.ts app.test.ts
    CAPDIR=$(mktemp -d); printf '{ "level": "L0" }\n' > "$CAPDIR/review-capability.json"
    export AGENT_GATES_DIR="$CAPDIR"
    mkdir -p .agent/reviews .agent/plans
    printf 'VERDICT: PASS\n' > .agent/reviews/r.md
    printf 'GENERATED_BY: agent-gates\nTIMESTAMP: 2026-06-10\nBRANCH: main\nHEAD: abc\nREASON: quick fix\n' > .agent/plans/migration.skip.md
    output=$(bash "$GATE" 2>&1); rc=$?
    assert "FAIL dangerous + skip" "$([[ $rc -ne 0 ]] && echo true || echo false)"
    assert "mentions dangerous/requires-plan" "$(echo "$output" | grep -qiE 'dangerous|requires.*plan|skip not accepted' && echo true || echo false)"
    rm -rf "$CAPDIR"; teardown_mock_repo
  )
}

# T-D2: dangerous path + reviewed plan → PASS
test_check3_dangerous_with_plan() {
  echo "T-D2: dangerous path + reviewed plan → PASS"
  (
    setup_mock_repo
    mkdir -p migrations
    printf 'ALTER TABLE users ADD COLUMN role TEXT;\n' > migrations/001_add_role.sql
    echo "test('migration', () => {})" > migrations/001_add_role.sql.test.ts
    printf 'export const x = 1;\n' > app.ts
    for n in $(seq 1 25); do echo "  // line $n" >> app.ts; done
    echo "test('x', () => {})" > app.test.ts
    git add migrations/001_add_role.sql migrations/001_add_role.sql.test.ts app.ts app.test.ts
    CAPDIR=$(mktemp -d); printf '{ "level": "L0" }\n' > "$CAPDIR/review-capability.json"
    export AGENT_GATES_DIR="$CAPDIR"
    mkdir -p .agent/reviews .agent/plans
    printf 'VERDICT: PASS\n' > .agent/reviews/r.md
    printf '# Migration Plan\n<!-- PLAN_REVIEW: L1 -->\n<!-- PLAN_REVIEW_TOOL: codex -->\n<!-- PLAN_REVIEW_MODEL: gpt -->\n' > .agent/plans/migration.md
    output=$(bash "$GATE" 2>&1); rc=$?
    assert "PASS dangerous + reviewed plan" "$([[ $rc -eq 0 ]] && echo true || echo false)"
    rm -rf "$CAPDIR"; teardown_mock_repo
  )
}

test_check3_plan_with_review
test_check3_no_plan
test_check3_plan_no_marker_l1
test_check3_l0_plan_no_marker
test_check3_skip_approved
test_check3_skip_handwritten
test_check3_skip_env
test_check3_dangerous_skip_rejected
test_check3_dangerous_with_plan

echo ""
read -r PASS_COUNT FAIL_COUNT < "$RESULTS_FILE"
rm -f "$RESULTS_FILE"
echo "$PASS_COUNT pass · $FAIL_COUNT fail"
[[ "$FAIL_COUNT" -eq 0 ]] && exit 0 || exit 1
