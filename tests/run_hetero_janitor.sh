#!/usr/bin/env bash
# Tests for lib/hetero/janitor.sh — P3-A janitor measurement functions.
#
# Coverage (T1-T3 per P3-A spec):
#   T1  janitor_measure_rss_tree $$ returns a positive integer (current process has RSS)
#   T2  janitor_measure_age $$    returns a positive integer (current shell has been alive)
#   T3  janitor_measure_runs      returns 0 for empty dir; returns 5 after writing "5"
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JANITOR_LIB="$SCRIPT_DIR/../lib/hetero/janitor.sh"
RESULTS_FILE=$(mktemp); echo "0 0" > "$RESULTS_FILE"

assert() {
  local name="$1" cond="$2" p f
  read -r p f < "$RESULTS_FILE"
  if [[ "$cond" == "true" ]]; then echo "  ✓ $name"; echo "$((p+1)) $f" > "$RESULTS_FILE";
  else echo "  ✗ $name"; echo "$p $((f+1))" > "$RESULTS_FILE"; fi
}

# Source janitor lib with fresh state each test.
source_janitor() {
  _HETERO_JANITOR_SOURCED=""
  source "$JANITOR_LIB"
}

echo "=== hetero janitor measurement tests (P3-A) ==="
echo ""

# ────────────────────────────────────────────────
echo "T1: janitor_measure_rss_tree \$\$ returns >0"
# ────────────────────────────────────────────────
(
  source_janitor
  rss_val=$(janitor_measure_rss_tree $$)
  assert "rss_val is non-empty"      "$([[ -n "$rss_val" ]] && echo true || echo false)"
  assert "rss_val matches integer"   "$([[ "$rss_val" =~ ^[0-9]+$ ]] && echo true || echo false)"
  assert "rss_val > 0"               "$([[ "$rss_val" -gt 0 ]] && echo true || echo false)"
)
echo ""

# ────────────────────────────────────────────────
echo "T2: janitor_measure_age returns >0 for a process known to be alive > 0 s"
# ────────────────────────────────────────────────
# NOTE: $$ (the test runner) can have etime "00:00" when fresh, and $PPID can also
# be a newly-forked process. We start a background `sleep 10`, wait 1 s to ensure
# its etime becomes "00:01" or higher, then measure it — guaranteeing age > 0.
(
  source_janitor
  # Start a background sleep and capture its PID
  sleep 10 &
  sleep_pid=$!
  sleep 1   # wait at least 1 s so etime > 0

  age_val=$(janitor_measure_age "$sleep_pid")

  # Clean up background sleep
  kill "$sleep_pid" 2>/dev/null; wait "$sleep_pid" 2>/dev/null || true

  assert "age_val is non-empty"     "$([[ -n "$age_val" ]] && echo true || echo false)"
  assert "age_val matches integer"  "$([[ "$age_val" =~ ^[0-9]+$ ]] && echo true || echo false)"
  assert "age_val > 0"              "$([[ "$age_val" -gt 0 ]] && echo true || echo false)"
)
echo ""

# ────────────────────────────────────────────────
echo "T3: janitor_measure_runs — empty dir → 0; after write '5' → 5"
# ────────────────────────────────────────────────
(
  source_janitor
  TEST_LOCK_DIR=$(mktemp -d)

  runs_empty=$(janitor_measure_runs "$TEST_LOCK_DIR")
  assert "empty lock_dir returns 0"  "$([[ "$runs_empty" == "0" ]] && echo true || echo false)"

  echo "5" > "$TEST_LOCK_DIR/run_count"
  runs_five=$(janitor_measure_runs "$TEST_LOCK_DIR")
  assert "after writing 5 returns 5" "$([[ "$runs_five" == "5" ]] && echo true || echo false)"

  rm -rf "$TEST_LOCK_DIR"
)
echo ""

# ────────────────────────────────────────────────
echo "T4: janitor_check_budget — run_count > max_runs → 1; run_count < max_runs → 0"
# ────────────────────────────────────────────────
(
  source_janitor

  TEST_LOCK_DIR=$(mktemp -d)
  # Spawn a real background sleep so we have a real PID (rss/age will be small).
  sleep 300 &
  FAKE_PID=$!

  # Override config vars directly (bypass config.sh file read).
  export HETERO_OC_RSS_MAX_MB=99999
  export HETERO_OC_MAX_AGE_S=99999
  export HETERO_OC_MAX_RUNS=2

  # Exceeds max_runs=2 → should return 1.
  echo "3" > "$TEST_LOCK_DIR/run_count"
  out_exceed=$(janitor_check_budget "$FAKE_PID" "$TEST_LOCK_DIR" 2>&1); rc_exceed=$?
  assert "run_count=3 > max_runs=2 returns 1" "$([[ $rc_exceed -eq 1 ]] && echo true || echo false)"
  assert "exceed output contains 'EXCEEDED'" "$([[ "$out_exceed" == *EXCEEDED* ]] && echo true || echo false)"

  # Within budget: max_runs=2, run_count=1 → should return 0.
  echo "1" > "$TEST_LOCK_DIR/run_count"
  out_ok=$(janitor_check_budget "$FAKE_PID" "$TEST_LOCK_DIR" 2>&1); rc_ok=$?
  assert "run_count=1 <= max_runs=2 returns 0" "$([[ $rc_ok -eq 0 ]] && echo true || echo false)"
  assert "ok output contains 'OK'" "$([[ "$out_ok" == *OK* ]] && echo true || echo false)"

  kill "$FAKE_PID" 2>/dev/null; wait "$FAKE_PID" 2>/dev/null || true
  rm -rf "$TEST_LOCK_DIR"
)
echo ""

# ────────────────────────────────────────────────
echo "T5: janitor_draining_lock — acquire→check→re-acquire→release→check"
# ────────────────────────────────────────────────
(
  source_janitor

  TEST_LOCK_DIR=$(mktemp -d)

  # acquire → check should see it present (return 0).
  janitor_draining_lock "$TEST_LOCK_DIR" "acquire"; rc_acq=$?
  assert "acquire returns 0" "$([[ $rc_acq -eq 0 ]] && echo true || echo false)"

  janitor_draining_lock "$TEST_LOCK_DIR" "check"; rc_chk=$?
  assert "check while locked returns 0" "$([[ $rc_chk -eq 0 ]] && echo true || echo false)"

  # Second acquire should fail (already locked).
  janitor_draining_lock "$TEST_LOCK_DIR" "acquire"; rc_acq2=$?
  assert "second acquire returns 1" "$([[ $rc_acq2 -eq 1 ]] && echo true || echo false)"

  # release → check should see it gone (return 1).
  janitor_draining_lock "$TEST_LOCK_DIR" "release"
  janitor_draining_lock "$TEST_LOCK_DIR" "check"; rc_chk2=$?
  assert "check after release returns 1" "$([[ $rc_chk2 -eq 1 ]] && echo true || echo false)"

  rm -rf "$TEST_LOCK_DIR"
)
echo ""

# ────────────────────────────────────────────────
echo "T6: janitor_recycle_serve — no live clients → recycle succeeds + lock released"
# ────────────────────────────────────────────────
(
  source_janitor

  TEST_LOCK_DIR=$(mktemp -d)

  # Spawn a fake "serve" process (sleep) and write its PID into the lock dir.
  sleep 300 &
  FAKE_SERVE_PID=$!
  echo "$FAKE_SERVE_PID" > "$TEST_LOCK_DIR/serve_pid"

  # Mock oc_serve_has_live_clients to always return 1 (no clients).
  oc_serve_has_live_clients() { return 1; }
  export OC_SERVE_PORT=14096  # avoid colliding with a real serve

  # Also mock hetero_kill_tree so we don't actually SIGTERM random processes;
  # just record the call and kill our fake sleep.
  _KILL_TREE_CALLED=""
  hetero_kill_tree() {
    _KILL_TREE_CALLED="yes"
    kill "$FAKE_SERVE_PID" 2>/dev/null || true
  }

  janitor_recycle_serve "$TEST_LOCK_DIR"; rc_recycle=$?
  assert "recycle returns 0" "$([[ $rc_recycle -eq 0 ]] && echo true || echo false)"
  assert "hetero_kill_tree was called" "$([[ "$_KILL_TREE_CALLED" == "yes" ]] && echo true || echo false)"

  # .draining lock must be released after recycle.
  janitor_draining_lock "$TEST_LOCK_DIR" "check"; rc_drain=$?
  assert ".draining lock released after recycle" "$([[ $rc_drain -eq 1 ]] && echo true || echo false)"

  wait "$FAKE_SERVE_PID" 2>/dev/null || true
  rm -rf "$TEST_LOCK_DIR"
)
echo ""

# ────────────────────────────────────────────────
echo "T7: janitor_record_exit writes JSON file with correct fields"
# ────────────────────────────────────────────────
(
  source_janitor

  TEST_LOCK_DIR=$(mktemp -d)
  export HETERO_LOCK_DIR="$TEST_LOCK_DIR"

  sleep 999 &
  SLEEP_PID=$!

  STARTED_AT=$(date +%s)
  janitor_record_exit "test/model" "$SLEEP_PID" "$SLEEP_PID" 42 "$STARTED_AT"

  EXIT_FILE="$TEST_LOCK_DIR/exits/test_model.${STARTED_AT}.json"
  assert "T7 exit file exists"  "$([[ -f "$EXIT_FILE" ]] && echo true || echo false)"

  EC=$(python3 -c "import json,sys; d=json.load(open(sys.argv[1])); print(d.get('exit_code',''))" "$EXIT_FILE" 2>/dev/null)
  assert "T7 exit_code=42"      "$([[ "$EC" == "42" ]] && echo true || echo false)"

  KEY=$(python3 -c "import json,sys; d=json.load(open(sys.argv[1])); print(d.get('key',''))" "$EXIT_FILE" 2>/dev/null)
  assert "T7 key=test/model"    "$([[ "$KEY" == "test/model" ]] && echo true || echo false)"

  kill "$SLEEP_PID" 2>/dev/null; wait "$SLEEP_PID" 2>/dev/null || true
  rm -rf "$TEST_LOCK_DIR"
)
echo ""

# ────────────────────────────────────────────────
echo "T8: janitor_sweep reaps dead process — spawn cleaned, exit recorded"
# ────────────────────────────────────────────────
(
  source_janitor
  _HETERO_DISPATCH_SOURCED=""
  source "${JANITOR_LIB%/*}/dispatch.sh"

  TEST_LOCK_DIR=$(mktemp -d)
  export HETERO_LOCK_DIR="$TEST_LOCK_DIR"

  sleep 99 &
  TEST_PID=$!
  hetero_register_spawn "test/t8-sweep" "$TEST_PID" "$TEST_PID"
  kill "$TEST_PID" 2>/dev/null; wait "$TEST_PID" 2>/dev/null || true

  janitor_sweep "$TEST_LOCK_DIR"

  SPAWN_COUNT=$(find "$TEST_LOCK_DIR/spawns" -name "*.json" 2>/dev/null | wc -l | tr -d '[:space:]')
  assert "T8 spawn file cleaned up" "$([[ "$SPAWN_COUNT" -eq 0 ]] && echo true || echo false)"

  EXIT_COUNT=$(find "$TEST_LOCK_DIR/exits" -name "*.json" 2>/dev/null | wc -l | tr -d '[:space:]')
  assert "T8 exit record created"   "$([[ "$EXIT_COUNT" -gt 0 ]] && echo true || echo false)"

  rm -rf "$TEST_LOCK_DIR"
)
echo ""

# ────────────────────────────────────────────────
echo "T9: hetero_kill_tree kills parent+child+grandchild (full PGID)"
# ────────────────────────────────────────────────
(
  source_janitor
  _HETERO_DISPATCH_SOURCED=""
  source "${JANITOR_LIB%/*}/dispatch.sh"

  TMPSCRIPT=$(mktemp /tmp/t9_tree_XXXXXX.sh)
  printf '#!/usr/bin/env bash\nbash -c '"'"'sleep 999 & sleep 999'"'"' &\nsleep 999\n' > "$TMPSCRIPT"
  chmod +x "$TMPSCRIPT"

  export HETERO_KILL_GRACE_S=0
  hetero_spawn_pg bash "$TMPSCRIPT"
  PGID="$HETERO_LAST_PGID"
  ROOT_PID="$HETERO_LAST_ROOT_PID"

  sleep 1  # let all child processes start

  COUNT_BEFORE=$(pgrep -g "$PGID" 2>/dev/null | wc -l | tr -d '[:space:]')
  assert "T9 >=3 processes in group before kill" "$([[ "$COUNT_BEFORE" -ge 3 ]] && echo true || echo false)"

  hetero_kill_tree "$PGID"
  sleep 1
  wait "$ROOT_PID" 2>/dev/null || true  # reap root zombie

  COUNT_AFTER=$(pgrep -g "$PGID" 2>/dev/null | wc -l | tr -d '[:space:]')
  assert "T9 0 processes in group after kill"    "$([[ "$COUNT_AFTER" -eq 0 ]] && echo true || echo false)"

  rm -f "$TMPSCRIPT"
)
echo ""

# ────────────────────────────────────────────────
# Summary
# ────────────────────────────────────────────────
read -r passed failed < "$RESULTS_FILE"
rm -f "$RESULTS_FILE"
total=$((passed + failed))
echo "Results: $passed/$total passed"
[[ $failed -eq 0 ]] && exit 0 || exit 1
