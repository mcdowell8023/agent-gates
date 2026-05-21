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

echo "Running memory-reminder.mjs tests..."
echo ""

run_test "$FIXTURES/todo-completed.json" "true"
run_test "$FIXTURES/todo-no-completion.json" "false"
run_test "$FIXTURES/omo-todo-completed.json" "true"
run_test "$FIXTURES/unrelated-tool.json" "false"
run_test "$FIXTURES/single-todo-completed.json" "true"
run_test "$FIXTURES/fallback-output-completed.json" "true"

echo ""
echo "Results: $PASS passed, $FAIL failed"

if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
