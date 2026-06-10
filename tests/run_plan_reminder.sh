#!/usr/bin/env bash
# Tests for memory-reminder.mjs detectSourceEditWithoutDecision (v1.11.0).
# Feeds JSON payloads to the hook and checks whether the plan reminder fires.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$SCRIPT_DIR/../hooks/platform/memory-reminder.mjs"
RESULTS_FILE=$(mktemp); echo "0 0" > "$RESULTS_FILE"

assert() {
  local name="$1" cond="$2" p f
  read -r p f < "$RESULTS_FILE"
  if [[ "$cond" == "true" ]]; then echo "  ✓ $name"; echo "$((p+1)) $f" > "$RESULTS_FILE";
  else echo "  ✗ $name"; echo "$p $((f+1))" > "$RESULTS_FILE"; fi
}

run_hook() {
  echo "$1" | node "$HOOK" 2>/dev/null
}

echo "=== plan-reminder (PostToolUse) tests ==="
echo ""

# T-P1: Edit src file + no plan → fires plan reminder
test_edit_src_no_plan() {
  echo "T-P1: Edit src + no plan → plan reminder"
  local ROOT=$(mktemp -d); mkdir -p "$ROOT/.agent/plans"
  local payload='{"tool_name":"Edit","tool_input":{"file_path":"'"$ROOT"'/src/app.ts","old_string":"x","new_string":"y"}}'
  out=$(run_hook "$payload")
  assert "fires plan reminder" "$(echo "$out" | grep -q 'Plan.*Decision\|方案.*决策\|plan.*decision' && echo true || echo false)"
  rm -rf "$ROOT"
}

# T-P2: Edit src + plan with PLAN_REVIEW → silent
test_edit_src_with_plan() {
  echo "T-P2: Edit src + plan with PLAN_REVIEW → silent"
  local ROOT=$(mktemp -d); mkdir -p "$ROOT/.agent/plans"
  printf '# Plan\n<!-- PLAN_REVIEW: L1 -->\n<!-- PLAN_REVIEW_TOOL: codex -->\n<!-- PLAN_REVIEW_MODEL: gpt -->\n' > "$ROOT/.agent/plans/design.md"
  local payload='{"tool_name":"Edit","tool_input":{"file_path":"'"$ROOT"'/src/app.ts","old_string":"x","new_string":"y"}}'
  out=$(run_hook "$payload")
  assert "silent (no plan reminder)" "$(echo "$out" | grep -q 'Plan.*Decision\|方案.*决策\|plan.*decision' && echo false || echo true)"
  rm -rf "$ROOT"
}

# T-P3: Edit src + old plan without markers → fires (v0.4 收紧)
test_edit_src_old_plan_no_markers() {
  echo "T-P3: Edit src + old plan no markers → fires"
  local ROOT=$(mktemp -d); mkdir -p "$ROOT/.agent/plans"
  printf '# Plan\nSome old notes\n' > "$ROOT/.agent/plans/old.md"
  local payload='{"tool_name":"Edit","tool_input":{"file_path":"'"$ROOT"'/src/app.ts","old_string":"x","new_string":"y"}}'
  out=$(run_hook "$payload")
  assert "fires (old plan no markers)" "$(echo "$out" | grep -q 'Plan.*Decision\|方案.*决策\|plan.*decision' && echo true || echo false)"
  rm -rf "$ROOT"
}

# T-P4: Edit non-src (.md) → silent
test_edit_nonsrc() {
  echo "T-P4: Edit .md → silent"
  local ROOT=$(mktemp -d); mkdir -p "$ROOT/.agent/plans"
  local payload='{"tool_name":"Edit","tool_input":{"file_path":"'"$ROOT"'/docs/readme.md","old_string":"x","new_string":"y"}}'
  out=$(run_hook "$payload")
  assert "silent for .md" "$(echo "$out" | grep -q 'Plan.*Decision\|方案.*决策\|plan.*decision' && echo false || echo true)"
  rm -rf "$ROOT"
}

# T-P5: Edit src but no .agent/ → silent (not init'd project)
test_edit_no_agent_dir() {
  echo "T-P5: Edit src, no .agent/ → silent"
  local ROOT=$(mktemp -d)
  local payload='{"tool_name":"Edit","tool_input":{"file_path":"'"$ROOT"'/src/app.ts","old_string":"x","new_string":"y"}}'
  out=$(run_hook "$payload")
  assert "silent (no .agent)" "$(echo "$out" | grep -q 'Plan.*Decision\|方案.*决策\|plan.*decision' && echo false || echo true)"
  rm -rf "$ROOT"
}

# T-P6: Write tool (not Edit) → also triggers if src
test_write_src_no_plan() {
  echo "T-P6: Write src + no plan → plan reminder"
  local ROOT=$(mktemp -d); mkdir -p "$ROOT/.agent/plans"
  local payload='{"tool_name":"Write","tool_input":{"file_path":"'"$ROOT"'/lib/util.py","content":"print(1)"}}'
  out=$(run_hook "$payload")
  assert "fires for Write too" "$(echo "$out" | grep -q 'Plan.*Decision\|方案.*决策\|plan.*decision' && echo true || echo false)"
  rm -rf "$ROOT"
}

# T-P7: skip.md with GENERATED_BY → silent
test_edit_src_with_skip() {
  echo "T-P7: Edit src + approved skip → silent"
  local ROOT=$(mktemp -d); mkdir -p "$ROOT/.agent/plans"
  printf 'GENERATED_BY: agent-gates\nTIMESTAMP: 2026-06-10\nBRANCH: main\nHEAD: abc\nREASON: ok\n' > "$ROOT/.agent/plans/x.skip.md"
  local payload='{"tool_name":"Edit","tool_input":{"file_path":"'"$ROOT"'/src/app.ts","old_string":"x","new_string":"y"}}'
  out=$(run_hook "$payload")
  assert "silent (approved skip)" "$(echo "$out" | grep -q 'Plan.*Decision\|方案.*决策\|plan.*decision' && echo false || echo true)"
  rm -rf "$ROOT"
}

test_edit_src_no_plan
test_edit_src_with_plan
test_edit_src_old_plan_no_markers
test_edit_nonsrc
test_edit_no_agent_dir
test_write_src_no_plan
test_edit_src_with_skip

echo ""
read -r PASS FAIL < "$RESULTS_FILE"; rm -f "$RESULTS_FILE"
echo "$PASS pass · $FAIL fail"
[[ "$FAIL" -eq 0 ]] && exit 0 || exit 1
