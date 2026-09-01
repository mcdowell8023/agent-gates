#!/usr/bin/env bash
# Tests for lib/oc-serve.sh — shared opencode serve management.
# Strategy: mock curl/opencode/lsof/pgrep with fake scripts on PATH, use temp dirs
# for lock dirs, and override OC_SERVE_* vars to keep tests fast and isolated.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OC_SERVE_LIB="$SCRIPT_DIR/../lib/hetero/serve.sh"
RESULTS_FILE=$(mktemp); echo "0 0" > "$RESULTS_FILE"

assert() {
  local name="$1" cond="$2" p f
  read -r p f < "$RESULTS_FILE"
  if [[ "$cond" == "true" ]]; then echo "  ✓ $name"; echo "$((p+1)) $f" > "$RESULTS_FILE";
  else echo "  ✗ $name"; echo "$p $((f+1))" > "$RESULTS_FILE"; fi
}

# Helper: create a temp dir with fake binaries on PATH.
# Usage: setup_env; then customize fake behaviors; then source the lib.
setup_env() {
  FAKE_DIR=$(mktemp -d)
  LOCK_DIR=$(mktemp -d)/oc-serve-lock  # does not exist yet — acquire_lock creates it
  # Fake curl — default: always fail (nothing listening)
  cat > "$FAKE_DIR/curl" <<'CURL'
#!/usr/bin/env bash
exit 1
CURL
  chmod +x "$FAKE_DIR/curl"
  # Fake opencode — records invocations to a log file
  OC_LOG="$FAKE_DIR/oc-invocations"
  : > "$OC_LOG"
  cat > "$FAKE_DIR/opencode" <<FAKE
#!/usr/bin/env bash
echo "\$*" >> "$OC_LOG"
# default: just exit 0 (background nohup, won't block)
exit 0
FAKE
  chmod +x "$FAKE_DIR/opencode"
  # Fake lsof — default: no ESTABLISHED connections
  cat > "$FAKE_DIR/lsof" <<'LSOF'
#!/usr/bin/env bash
exit 1
LSOF
  chmod +x "$FAKE_DIR/lsof"
  # Fake pgrep — default: no matching processes
  cat > "$FAKE_DIR/pgrep" <<'PGREP'
#!/usr/bin/env bash
exit 1
PGREP
  chmod +x "$FAKE_DIR/pgrep"
  # Fake nohup — just exec the command (tests don't need real backgrounding)
  cat > "$FAKE_DIR/nohup" <<'NOHUP'
#!/usr/bin/env bash
exec "$@"
NOHUP
  chmod +x "$FAKE_DIR/nohup"
  export PATH="$FAKE_DIR:$PATH"
}

# Wait for the fake opencode to actually record its invocation.
#
# `_oc_serve_start` backgrounds the process (`/usr/bin/nohup … &`) and then returns as soon
# as the health check passes — and the fake curl passes instantly. So reading $OC_LOG right
# after the call reads it before nohup+bash+append have run: T11 failed 5/5 this way, which
# I had written off as "flaky". Backgrounding is correct production behaviour; the assertion
# was assuming an ordering the code never promised.
wait_for_log() {  # wait_for_log <file> <pattern> [tries]
  local f="$1" pat="$2" tries="${3:-40}" i
  for ((i=0; i<tries; i++)); do
    grep -q "$pat" "$f" 2>/dev/null && return 0
    sleep 0.05
  done
  return 1
}

# Source the lib with guard reset and overrides.
source_lib() {
  _OC_SERVE_SOURCED=""
  OC_SERVE_PORT=19876
  OC_SERVE_URL="http://127.0.0.1:19876"
  OC_SERVE_LOCK_DIR="$LOCK_DIR"
  OC_SERVE_START_RETRIES=2
  OC_SERVE_OPENCODE="$FAKE_DIR/opencode"
  # Stubs must be defined before sourcing serve.sh so oc_serve_restart won't
  # try to lazy-source janitor.sh / dispatch.sh and pull in real dependencies.
  janitor_draining_lock() { return 0; }
  hetero_kill_tree() { local p="${1:-}"; [[ -n "$p" ]] && kill -9 "$p" 2>/dev/null; return 0; }
  source "$OC_SERVE_LIB"
}

echo "=== oc-serve library tests ==="
echo ""

# ---------------------------------------------------------------------------
# Lock tests (T1-T4)
# ---------------------------------------------------------------------------

test_acquire_lock_creates_dir() {
  echo "T1: acquire_lock creates lock dir with PID"
  ( setup_env; source_lib
    oc_serve_acquire_lock; rc=$?
    assert "exit 0" "$([[ $rc -eq 0 ]] && echo true || echo false)"
    assert "lock dir exists" "$([[ -d "$LOCK_DIR" ]] && echo true || echo false)"
    pid_in_lock=$(cat "$LOCK_DIR/pid" 2>/dev/null)
    assert "pid file contains $$" "$([[ "$pid_in_lock" == "$$" ]] && echo true || echo false)"
    rm -rf "$FAKE_DIR" "$(dirname "$LOCK_DIR")" )
}

test_acquire_lock_fails_when_held() {
  echo "T2: acquire_lock fails when held by live process"
  ( setup_env; source_lib
    # Manually create the lock with current PID (which is alive)
    mkdir -p "$LOCK_DIR"
    echo $$ > "$LOCK_DIR/pid"
    oc_serve_acquire_lock; rc=$?
    assert "exit 1 (lock held)" "$([[ $rc -eq 1 ]] && echo true || echo false)"
    rm -rf "$FAKE_DIR" "$(dirname "$LOCK_DIR")" )
}

test_acquire_lock_stale_cleanup() {
  echo "T3: stale lock (dead PID) gets cleaned up"
  ( setup_env; source_lib
    # Create lock with a definitely-dead PID
    mkdir -p "$LOCK_DIR"
    echo 99999 > "$LOCK_DIR/pid"
    # Make sure PID 99999 is not alive (best-effort; extremely unlikely to be running)
    if kill -0 99999 2>/dev/null; then
      assert "SKIP: PID 99999 unexpectedly alive" "false"
    else
      oc_serve_acquire_lock; rc=$?
      assert "exit 0 (stale lock cleaned)" "$([[ $rc -eq 0 ]] && echo true || echo false)"
      pid_in_lock=$(cat "$LOCK_DIR/pid" 2>/dev/null)
      assert "pid file updated to $$" "$([[ "$pid_in_lock" == "$$" ]] && echo true || echo false)"
    fi
    rm -rf "$FAKE_DIR" "$(dirname "$LOCK_DIR")" )
}

test_release_lock_pid_check() {
  echo "T4: release_lock removes dir only if PID matches"
  ( setup_env; source_lib
    # Lock owned by us — should be removed
    mkdir -p "$LOCK_DIR"
    echo $$ > "$LOCK_DIR/pid"
    oc_serve_release_lock
    assert "lock dir removed when PID matches" "$([[ ! -d "$LOCK_DIR" ]] && echo true || echo false)"
    # Lock owned by someone else — should be kept
    mkdir -p "$LOCK_DIR"
    echo 12345 > "$LOCK_DIR/pid"
    oc_serve_release_lock
    assert "lock dir kept when PID differs" "$([[ -d "$LOCK_DIR" ]] && echo true || echo false)"
    rm -rf "$FAKE_DIR" "$(dirname "$LOCK_DIR")" )
}

# ---------------------------------------------------------------------------
# Health / ensure tests (T5-T8)
# ---------------------------------------------------------------------------

test_health_check_fails_no_server() {
  echo "T5: health_check returns 1 when nothing listening"
  ( setup_env; source_lib
    # Fake curl already exits 1
    oc_serve_health_check; rc=$?
    assert "exit 1 (no server)" "$([[ $rc -ne 0 ]] && echo true || echo false)"
    rm -rf "$FAKE_DIR" "$(dirname "$LOCK_DIR")" )
}

test_ensure_already_healthy() {
  echo "T6: ensure returns 0 immediately when already healthy"
  ( setup_env
    # Override curl to succeed
    cat > "$FAKE_DIR/curl" <<'CURL'
#!/usr/bin/env bash
exit 0
CURL
    chmod +x "$FAKE_DIR/curl"
    source_lib
    oc_serve_ensure; rc=$?
    assert "exit 0 (already healthy)" "$([[ $rc -eq 0 ]] && echo true || echo false)"
    # opencode should NOT have been called
    invocations=$(wc -l < "$OC_LOG" | tr -d ' ')
    assert "opencode not invoked" "$([[ "$invocations" == "0" ]] && echo true || echo false)"
    rm -rf "$FAKE_DIR" "$(dirname "$LOCK_DIR")" )
}

test_ensure_starts_serve() {
  echo "T7: ensure starts serve when unhealthy (mock curl fail→succeed)"
  ( setup_env
    # curl: fail first N calls, then succeed.
    # Use a counter file to track invocations.
    CURL_COUNT="$FAKE_DIR/curl-count"
    echo 0 > "$CURL_COUNT"
    cat > "$FAKE_DIR/curl" <<CURL
#!/usr/bin/env bash
n=\$(cat "$CURL_COUNT"); n=\$((n+1)); echo \$n > "$CURL_COUNT"
# First 2 calls fail (initial health check + first retry), third succeeds
[[ \$n -ge 3 ]] && exit 0 || exit 1
CURL
    chmod +x "$FAKE_DIR/curl"
    # nohup needs to be on PATH (already set up) and we need /usr/bin/nohup
    # to work. Override _oc_serve_start's nohup call by making a /usr/bin/nohup
    # wrapper. Instead, we'll just put our nohup first on PATH — but the lib
    # hard-codes /usr/bin/nohup. Work around by replacing the opencode binary
    # to also satisfy the nohup exec.
    source_lib
    oc_serve_ensure; rc=$?
    assert "exit 0 (serve started)" "$([[ $rc -eq 0 ]] && echo true || echo false)"
    # Verify opencode was called with serve --pure --port
    wait_for_log "$OC_LOG" "serve --pure --port"
    invocations=$(cat "$OC_LOG")
    assert "opencode called with 'serve --pure --port'" "$(echo "$invocations" | grep -q 'serve --pure --port' && echo true || echo false)"
    rm -rf "$FAKE_DIR" "$(dirname "$LOCK_DIR")" )
}

test_ensure_fails_no_lock_no_health() {
  echo "T8: ensure fails when start fails and lock unavailable"
  ( setup_env
    # curl always fails
    source_lib
    # Pre-create a lock held by a "live" process (current shell)
    mkdir -p "$LOCK_DIR"
    echo $$ > "$LOCK_DIR/pid"
    oc_serve_ensure; rc=$?
    assert "exit 1 (no health, no lock)" "$([[ $rc -ne 0 ]] && echo true || echo false)"
    rm -rf "$FAKE_DIR" "$(dirname "$LOCK_DIR")" )
}

# ---------------------------------------------------------------------------
# Live clients / restart tests (T9-T12)
# ---------------------------------------------------------------------------

test_has_live_clients_none() {
  echo "T9: has_live_clients returns 1 when no clients"
  ( setup_env; source_lib
    # Both lsof and pgrep fakes return 1
    oc_serve_has_live_clients; rc=$?
    assert "exit 1 (no clients)" "$([[ $rc -eq 1 ]] && echo true || echo false)"
    rm -rf "$FAKE_DIR" "$(dirname "$LOCK_DIR")" )
}

test_restart_refuses_live_clients() {
  echo "T10: restart refuses when live clients"
  ( setup_env
    # Make lsof report ESTABLISHED connections
    cat > "$FAKE_DIR/lsof" <<'LSOF'
#!/usr/bin/env bash
echo "opencode 12345 user 3u IPv4 TCP *:4096 (ESTABLISHED)"
exit 0
LSOF
    chmod +x "$FAKE_DIR/lsof"
    source_lib
    oc_serve_restart; rc=$?
    assert "exit 1 (live clients)" "$([[ $rc -eq 1 ]] && echo true || echo false)"
    # opencode should NOT have been called (no kill, no restart)
    invocations=$(wc -l < "$OC_LOG" | tr -d ' ')
    assert "opencode not invoked" "$([[ "$invocations" == "0" ]] && echo true || echo false)"
    rm -rf "$FAKE_DIR" "$(dirname "$LOCK_DIR")" )
}

test_start_calls_opencode_serve() {
  echo "T11: _oc_serve_start calls opencode serve --pure --port"
  ( setup_env
    # Make curl succeed on first health check after start
    CURL_COUNT="$FAKE_DIR/curl-count"
    echo 0 > "$CURL_COUNT"
    cat > "$FAKE_DIR/curl" <<CURL
#!/usr/bin/env bash
n=\$(cat "$CURL_COUNT"); n=\$((n+1)); echo \$n > "$CURL_COUNT"
# Succeed on first call (health check inside _oc_serve_start loop)
exit 0
CURL
    chmod +x "$FAKE_DIR/curl"
    source_lib
    _oc_serve_start; rc=$?
    assert "exit 0" "$([[ $rc -eq 0 ]] && echo true || echo false)"
    wait_for_log "$OC_LOG" "serve --pure --port 19876"
    invocations=$(cat "$OC_LOG")
    assert "called 'serve --pure --port 19876'" "$(echo "$invocations" | grep -q "serve --pure --port 19876" && echo true || echo false)"
    rm -rf "$FAKE_DIR" "$(dirname "$LOCK_DIR")" )
}

test_ensure_total_failure() {
  echo "T12: ensure returns 1 when no server, no lock, curl always fails"
  ( setup_env
    # curl always fails (default)
    # Lock dir: pre-held by current PID so acquire_lock sees live owner
    source_lib
    mkdir -p "$LOCK_DIR"
    echo $$ > "$LOCK_DIR/pid"
    OC_SERVE_START_RETRIES=2
    oc_serve_ensure; rc=$?
    assert "exit 1" "$([[ $rc -ne 0 ]] && echo true || echo false)"
    rm -rf "$FAKE_DIR" "$(dirname "$LOCK_DIR")" )
}

# ---------------------------------------------------------------------------
# Run all tests
# ---------------------------------------------------------------------------

test_acquire_lock_creates_dir
test_acquire_lock_fails_when_held
test_acquire_lock_stale_cleanup
test_release_lock_pid_check
test_health_check_fails_no_server
test_ensure_already_healthy
test_ensure_starts_serve
test_ensure_fails_no_lock_no_health
test_has_live_clients_none
test_restart_refuses_live_clients
test_start_calls_opencode_serve
test_ensure_total_failure

echo ""
read -r PASS FAIL < "$RESULTS_FILE"; rm -f "$RESULTS_FILE"
echo "$PASS pass · $FAIL fail"
[[ "$FAIL" -eq 0 ]] && exit 0 || exit 1
