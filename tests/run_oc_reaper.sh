#!/usr/bin/env bash
# Tests for bin/oc-reaper — orphaned `opencode serve` process reaper.
# Strategy: spawn fake "opencode serve" processes via `exec -a` renaming sleep,
# then verify the reaper correctly identifies orphans, keeps protected/young/in-use
# serves, and actually kills with --apply.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REAPER="$SCRIPT_DIR/../bin/oc-reaper"
RESULTS_FILE=$(mktemp)
echo "0 0" > "$RESULTS_FILE"

assert() {
  local name="$1" cond="$2" p f
  read -r p f < "$RESULTS_FILE"
  if [[ "$cond" == "true" ]]; then echo "  ✓ $name"; echo "$((p+1)) $f" > "$RESULTS_FILE";
  else echo "  ✗ $name"; echo "$p $((f+1))" > "$RESULTS_FILE"; fi
}

# Helper: kill all background jobs in current shell, wait for them to exit.
# Skips killing the current shell's own PGID — non-setsid'd background jobs
# (e.g. `opencode run --attach` fakes) share the caller's PGID, and killing
# the PGID would terminate the test subshell mid-cleanup.
cleanup_bg() {
  local p
  for p in $(jobs -p); do
    kill "$p" 2>/dev/null || true
  done
  pkill -f "opencode serve --port 990" 2>/dev/null || true
  pkill -f "opencode run --attach http://127.0.0.1:990" 2>/dev/null || true
  wait 2>/dev/null
}

# Helper: spawn a fake "opencode serve" process in its OWN process group.
# Uses perl POSIX::setsid() so the child's PGID != test shell's PGID.
# This is critical: oc-reaper --apply calls hetero_kill_tree which does
# `kill -TERM -- -$pgid`; if the fake process shared the test shell's PGID
# it would kill the entire test.
spawn_fake_serve() {
  local port="$1"
  perl <<PERL &
use POSIX ();
POSIX::setsid();
exec q{bash -c 'exec -a "opencode serve --port $port" sleep 300'};
PERL
}

# Stub functions exported to child bash processes (bash "$REAPER").
# dispatch.sh overrides hetero_kill_tree when present; these are fallbacks only.
janitor_draining_lock() { return 0; }
hetero_kill_tree() { local p="${1:-}"; [[ -n "$p" ]] && kill -9 "$p" 2>/dev/null; return 0; }
export -f janitor_draining_lock hetero_kill_tree

echo "=== oc-reaper tests ==="
echo ""

# T1: orphan serve (no client, old enough) → dry-run lists it
test_orphan_dryrun() {
  echo "T1: orphan serve → dry-run lists it as reapable"
  (
    trap cleanup_bg EXIT
    spawn_fake_serve 9901
    sleep 0.3
    out=$(OC_REAPER_MIN_AGE=0 OC_REVIEW_PORT="" bash "$REAPER" 2>&1)
    rc=$?
    assert "exit 0" "$([[ $rc -eq 0 ]] && echo true || echo false)"
    assert "dry-run lists port 9901" "$(echo "$out" | grep -q '\[dry-run\].*:9901' && echo true || echo false)"
    assert "shows 1 reapable" "$(echo "$out" | grep -q '1 reapable' && echo true || echo false)"
  )
}

# T2: serve with --attach client → kept (live client via pgrep pattern)
test_serve_with_attach_client() {
  echo "T2: serve with --attach client → kept"
  (
    trap cleanup_bg EXIT
    spawn_fake_serve 9902
    bash -c 'exec -a "opencode run --attach http://127.0.0.1:9902" sleep 300' &
    sleep 0.3
    out=$(OC_REAPER_MIN_AGE=0 OC_REVIEW_PORT="" bash "$REAPER" 2>&1)
    rc=$?
    assert "exit 0" "$([[ $rc -eq 0 ]] && echo true || echo false)"
    assert "port 9902 NOT listed as reapable" "$(echo "$out" | grep -q ':9902' && echo false || echo true)"
    assert "kept count includes it" "$(echo "$out" | grep -q 'kept' && echo true || echo false)"
  )
}

# T3: shared port (OC_REVIEW_PORT) → always kept
test_shared_port_kept() {
  echo "T3: shared port (OC_REVIEW_PORT) → always kept"
  (
    trap cleanup_bg EXIT
    spawn_fake_serve 9903
    sleep 0.3
    out=$(OC_REAPER_MIN_AGE=0 OC_REVIEW_PORT=9903 bash "$REAPER" 2>&1)
    rc=$?
    assert "exit 0" "$([[ $rc -eq 0 ]] && echo true || echo false)"
    assert "port 9903 NOT listed as reapable" "$(echo "$out" | grep -q ':9903' && echo false || echo true)"
    assert "0 reapable" "$(echo "$out" | grep -q '0 reapable' && echo true || echo false)"
  )
}

# T4: young serve (MIN_AGE=999) → kept because too young
test_young_serve_kept() {
  echo "T4: young serve (MIN_AGE=999) → kept"
  (
    trap cleanup_bg EXIT
    spawn_fake_serve 9904
    sleep 0.3
    out=$(OC_REAPER_MIN_AGE=999 OC_REVIEW_PORT="" bash "$REAPER" 2>&1)
    rc=$?
    assert "exit 0" "$([[ $rc -eq 0 ]] && echo true || echo false)"
    assert "port 9904 NOT listed as reapable" "$(echo "$out" | grep -q ':9904' && echo false || echo true)"
    assert "0 reapable" "$(echo "$out" | grep -q '0 reapable' && echo true || echo false)"
  )
}

# T5: --apply actually kills orphan (check process is gone after)
test_apply_kills_orphan() {
  echo "T5: --apply kills orphan process"
  (
    trap cleanup_bg EXIT
    spawn_fake_serve 9905
    local serve_pid=$!
    sleep 0.3
    # verify process exists before reaping
    assert "process alive before reap" "$(kill -0 $serve_pid 2>/dev/null && echo true || echo false)"
    out=$(OC_REAPER_MIN_AGE=0 OC_REVIEW_PORT="" bash "$REAPER" --apply 2>&1)
    rc=$?
    sleep 0.3
    assert "exit 0" "$([[ $rc -eq 0 ]] && echo true || echo false)"
    assert "reaped message for port 9905" "$(echo "$out" | grep -q 'reaped serve :9905' && echo true || echo false)"
    assert "process gone after reap" "$(kill -0 $serve_pid 2>/dev/null && echo false || echo true)"
  )
}

# T6: no opencode serve processes → clean exit, 0 reaped
test_no_processes() {
  echo "T6: no opencode serve processes → clean exit"
  (
    # no fake processes spawned
    out=$(OC_REAPER_MIN_AGE=0 OC_REVIEW_PORT="" bash "$REAPER" 2>&1)
    rc=$?
    assert "exit 0" "$([[ $rc -eq 0 ]] && echo true || echo false)"
    assert "0 reapable" "$(echo "$out" | grep -q '0 reapable' && echo true || echo false)"
    assert "no negative kept" "$(echo "$out" | grep -qE '[0-9]+ kept' && echo true || echo false)"
  )
}

# T7: multiple serves, mixed — one orphan + one with client → only orphan listed
test_mixed_multiple() {
  echo "T7: mixed — orphan + client-attached → only orphan listed"
  (
    trap cleanup_bg EXIT
    # orphan on 9907
    spawn_fake_serve 9907
    # serve on 9908 with a live --attach client
    spawn_fake_serve 9908
    bash -c 'exec -a "opencode run --attach http://127.0.0.1:9908" sleep 300' &
    sleep 0.3
    out=$(OC_REAPER_MIN_AGE=0 OC_REVIEW_PORT="" bash "$REAPER" 2>&1)
    rc=$?
    assert "exit 0" "$([[ $rc -eq 0 ]] && echo true || echo false)"
    assert "orphan 9907 listed as reapable" "$(echo "$out" | grep -q '\[dry-run\].*:9907' && echo true || echo false)"
    assert "client-attached 9908 NOT listed" "$(echo "$out" | grep -q ':9908' && echo false || echo true)"
    assert "1 reapable" "$(echo "$out" | grep -q '1 reapable' && echo true || echo false)"
    assert "at least 1 kept" "$(echo "$out" | grep -qE '[1-9][0-9]* kept' && echo true || echo false)"
  )
}

test_stale_serve_with_connection_is_reaped() {
  echo "T8: connected but no opencode run client, past MAX_AGE → reaped"
  # A Paseo-managed serve holds a permanent connection to the Paseo daemon, so the
  # ESTABLISHED signal never clears. Before this, that single signal kept the serve forever:
  # two were observed alive at 23h with zero `opencode run` processes on the machine, and
  # `--apply` reaped none of them. Age must win over a bare connection.
  ( FAKE=$(mktemp -d)
    printf '#!/usr/bin/env bash\nexit 0\n' > "$FAKE/lsof"   # always reports a connection
    chmod +x "$FAKE/lsof"
    export PATH="$FAKE:$PATH"
    spawn_fake_serve 9931
    sleep 1
    out=$(OC_REAPER_MIN_AGE=0 OC_REAPER_MAX_AGE=0 bash "$REAPER" 2>&1)
    assert "connected-but-clientless serve is reapable" \
      "$(echo "$out" | grep -q '9931' && echo true || echo false)"
    cleanup_bg; rm -rf "$FAKE" )
}

test_active_client_keeps_serve_at_any_age() {
  echo "T9: real opencode run client → kept even past MAX_AGE"
  ( FAKE=$(mktemp -d)
    printf '#!/usr/bin/env bash\nexit 0\n' > "$FAKE/lsof"
    chmod +x "$FAKE/lsof"
    export PATH="$FAKE:$PATH"
    spawn_fake_serve 9932
    bash -c 'exec -a "opencode run --attach http://127.0.0.1:9932" sleep 60' &
    sleep 1
    out=$(OC_REAPER_MIN_AGE=0 OC_REAPER_MAX_AGE=0 bash "$REAPER" 2>&1)
    assert "kept because a real client exists" \
      "$(echo "$out" | grep -q '9932' && echo false || echo true)"
    cleanup_bg; rm -rf "$FAKE" )
}

test_orphan_dryrun
test_serve_with_attach_client
test_stale_serve_with_connection_is_reaped
test_active_client_keeps_serve_at_any_age
test_shared_port_kept
test_young_serve_kept
test_apply_kills_orphan
test_no_processes
test_mixed_multiple

echo ""
read -r PASS FAIL < "$RESULTS_FILE"
rm -f "$RESULTS_FILE"
echo "$PASS pass · $FAIL fail"
[[ "$FAIL" -eq 0 ]] && exit 0 || exit 1
