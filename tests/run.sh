#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$SCRIPT_DIR/../hooks/platform/memory-reminder.mjs"
FIXTURES="$SCRIPT_DIR/fixtures"
PASS=0
FAIL=0

run_test() {
  local fixture="$1"
  local expect_reminder="$2"
  local name
  name=$(basename "$fixture" .json)

  local output
  output=$(node "$HOOK" < "$fixture" 2>/dev/null)
  local has_reminder=false
  if echo "$output" | grep -q "additionalContext"; then
    has_reminder=true
  fi

  if [[ "$has_reminder" == "$expect_reminder" ]]; then
    echo "  ✓ $name"
    PASS=$((PASS + 1))
  else
    echo "  ✗ $name (expected reminder=$expect_reminder, got=$has_reminder)"
    FAIL=$((FAIL + 1))
  fi
}

# Assert which reminder fired by checking for a marker substring.
run_test_marker() {
  local fixture="$1"
  local marker="$2"
  local name
  name=$(basename "$fixture" .json)

  local output
  output=$(node "$HOOK" < "$fixture" 2>/dev/null)
  if echo "$output" | grep -q "$marker"; then
    echo "  ✓ $name → $marker"
    PASS=$((PASS + 1))
  else
    echo "  ✗ $name (expected marker '$marker' not found)"
    FAIL=$((FAIL + 1))
  fi
}

echo "Running memory-reminder.mjs tests..."
echo ""

run_test "$FIXTURES/todo-completed.json" "true"
run_test "$FIXTURES/todo-no-completion.json" "false"
run_test "$FIXTURES/omo-todo-completed.json" "true"
run_test "$FIXTURES/unrelated-tool.json" "false"
run_test "$FIXTURES/single-todo-completed.json" "true"
run_test "$FIXTURES/fallback-output-completed.json" "true"

# v1.6.1 parallelism reminder
run_test "$FIXTURES/plan-time-3-pending.json" "true"
run_test "$FIXTURES/plan-time-started.json" "false"
run_test "$FIXTURES/plan-time-omo.json" "true"            # OMO format, 3 all-pending
run_test "$FIXTURES/plan-time-missing-status.json" "false" # missing status → conservative no-fire
run_test "$FIXTURES/mixed-completed-pending-3.json" "true" # has a completed → memory reminder
run_test "$FIXTURES/malformed.json" "false"               # invalid JSON → no-op, no crash

# Verify the RIGHT reminder fires for each trigger
run_test_marker "$FIXTURES/todo-completed.json" "Memory Persistence Reminder"
run_test_marker "$FIXTURES/plan-time-3-pending.json" "Parallelism Reminder"
run_test_marker "$FIXTURES/plan-time-omo.json" "Parallelism Reminder"
# Priority: 3 todos but one completed → Memory wins, NOT parallelism
run_test_marker "$FIXTURES/mixed-completed-pending-3.json" "Memory Persistence Reminder"

echo ""
echo "Results: $PASS passed, $FAIL failed"

if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
