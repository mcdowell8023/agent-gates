#!/usr/bin/env bash
# Tests for oc-reaper's three-layer spin judgment (added 2026-08-20).
#
# Why three layers and not "no children + high CPU":
#   Layer 1  working child          -> real work, keep at any CPU
#                                      (a serve awaiting jest parks in kevent64 at ~100%,
#                                       indistinguishable from GC spin without this layer)
#   Layer 2  no child, low CPU      -> idle, harmless, keep
#   Layer 3  no child, high CPU     -> must PROVE it is GC spin (main thread parked in
#                                      kevent64) and not heavy JS, else keep
#
# Strategy: fake `lsof` (satisfies the ESTABLISHED branch that guards all three layers),
# fake `sample` (controls the layer-3 verdict), `exec -a` renamed processes as serves.
set -uo pipefail
set +m   # silence "Terminated" job notices from the killed fakes

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REAPER="$SCRIPT_DIR/../bin/oc-reaper"
RESULTS_FILE=$(mktemp)
echo "0 0" > "$RESULTS_FILE"
FAKEBIN=$(mktemp -d)
SPAWNED=""

assert() {
  local name="$1" cond="$2" p f
  read -r p f < "$RESULTS_FILE"
  if [[ "$cond" == "true" ]]; then echo "  ✓ $name"; echo "$((p+1)) $f" > "$RESULTS_FILE"
  else echo "  ✗ $name"; echo "$p $((f+1))" > "$RESULTS_FILE"; fi
}

# --- fakes -------------------------------------------------------------------
# lsof: `command -v lsof` must succeed, and the ESTABLISHED probe must return 0 so the
# three-layer block is reached at all.
cat > "$FAKEBIN/lsof" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

# sample: mirrors the real report shape the parser greps for --
#   "   2307 Thread_1  DispatchQueue_1"   -> total samples
#   "     2231 kevent64  (in ...)"        -> parked samples
# FAKE_SAMPLE_KEV controls the ratio; FAKE_SAMPLE_FAIL=1 makes it exit non-zero.
cat > "$FAKEBIN/sample" <<'EOF'
#!/usr/bin/env bash
[[ "${FAKE_SAMPLE_FAIL:-0}" == "1" ]] && exit 1
out=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -f) out="${2:-}"; shift 2 ;;
    *)  shift ;;
  esac
done
kev="${FAKE_SAMPLE_KEV:-2231}"
other="${FAKE_SAMPLE_OTHER_KEV:-0}"
[[ -z "$out" ]] && exit 0
# Mirrors the real report shape: per-thread sections. A second thread is emitted so the
# parser cannot mix one thread's kevent64 count with another thread's sample total.
cat > "$out" <<INNER
Analysis of sampling fake-serve (process 1) written to file
    2307 Thread_1   DispatchQueue_1
      $kev kevent64  (in libsystem_kernel.dylib)
    900 Thread_2
      $other kevent64  (in libsystem_kernel.dylib)
INNER
exit 0
EOF
chmod +x "$FAKEBIN/lsof" "$FAKEBIN/sample"

# Stubs for functions dispatch.sh would provide.
janitor_draining_lock() { return 0; }
hetero_kill_tree() { local p="${1:-}"; [[ -n "$p" ]] && kill -9 "$p" 2>/dev/null; return 0; }
export -f janitor_draining_lock hetero_kill_tree

# Spawn a fake serve in its OWN process group (so --apply's group kill cannot hit us).
# mode: idle | busy | with_child | with_lsp_child
spawn_serve() {
  local port="$1" mode="$2" inner
  case "$mode" in
    idle)  inner='exec -a "opencode serve --port PORT" sleep 300' ;;
    busy)  inner='exec -a "opencode serve --port PORT" yes' ;;
    with_child)
      inner='bash -c "exec -a work-child sleep 300" & exec -a "opencode serve --port PORT" sleep 300' ;;
    with_lsp_child)
      inner='bash -c "exec -a node-lsp-daemon-cli sleep 300" & exec -a "opencode serve --port PORT" yes' ;;
    # 跑完不退的 jest：进程在、CPU 恒为 0
    with_idle_child)
      inner='bash -c "exec -a jest-finished-but-hanging sleep 300" & exec -a "opencode serve --port PORT" yes' ;;
    # 真在跑的测试：子进程持续烧 CPU
    with_busy_child)
      inner='bash -c "exec -a jest-actually-running yes" & exec -a "opencode serve --port PORT" yes' ;;
  esac
  inner="${inner//PORT/$port}"
  perl <<PERL >/dev/null 2>&1 &
use POSIX ();
POSIX::setsid();
exec q{bash -c '$inner >/dev/null 2>&1'};
PERL
  SPAWNED="$SPAWNED $!"
}

# Kill only the most recently spawned fake, by PGID. Never pattern-match: `pkill -f
# "opencode serve --port 4096"` would be one typo away from killing the real shared serve,
# and a pattern can match the killing command's own argv.
kill_last() {
  local p="${SPAWNED##* }"
  [[ -n "$p" ]] || { sleep 0.4; return; }
  kill -- -"$p" 2>/dev/null || kill "$p" 2>/dev/null
  # Reap the job so bash does not print an async "Terminated" notice over the results.
  wait "$p" 2>/dev/null || true
  sleep 0.4
}

# `VAR=v run_reaper` only sets a shell variable; the fake `sample` is a child process and
# needs it in its environment, so pass it through explicitly.
# Guard against the failure mode that produced four false passes while these tests were
# being written: a fake that never starts makes every "not listed as reapable" assertion
# trivially true. Assert the process is actually up before asserting anything about it.
assert_fake_up() {
  local port="$1" pid p f
  pid=$(pgrep -f "opencode serve --port $port" | head -1)
  if [[ -n "$pid" ]]; then
    assert "fake serve :$port actually started (pid=$pid)" true
    return 0
  fi
  assert "fake serve :$port actually started" false
  return 1
}

run_reaper() { PATH="$FAKEBIN:$PATH" OC_REAPER_MIN_AGE=0 OC_REAPER_SPIN_WINDOW=1 \
  OC_REAPER_SPIN_CPU="${OC_REAPER_SPIN_CPU:-20}" \
  OC_REAPER_SPIN_SAMPLE_SECS=1 \
  FAKE_SAMPLE_KEV="${FAKE_SAMPLE_KEV:-2231}" FAKE_SAMPLE_FAIL="${FAKE_SAMPLE_FAIL:-0}" \
  FAKE_SAMPLE_OTHER_KEV="${FAKE_SAMPLE_OTHER_KEV:-0}" \
  bash "$REAPER" 2>&1; }

cleanup() {
  local p
  for p in $SPAWNED; do kill -- -"$p" 2>/dev/null || kill "$p" 2>/dev/null; done
  wait 2>/dev/null
  rm -rf "$FAKEBIN"
}
trap cleanup EXIT

echo "=== oc-reaper three-layer judgment tests ==="
echo

# L1: working child -> keep even at high CPU
echo "L1: working child + high CPU -> kept"
spawn_serve 9911 with_child
sleep 1
assert_fake_up 9911
out=$(run_reaper)
[[ "$out" == *"9911"* && "$out" == *"would reap"* ]] && r=false || r=true
assert "serve with a spawned tool child is kept" "$r"
kill_last

# L1b: lsp-daemon child does NOT count as work -> falls through and gets reaped
echo "L1b: only lsp-daemon child + high CPU + GC spin -> reaped (lsp does not count)"
spawn_serve 9912 with_lsp_child
sleep 1
assert_fake_up 9912
out=$(FAKE_SAMPLE_KEV=2231 run_reaper)
[[ "$out" == *"9912"* && "$out" == *"would reap"* ]] && r=true || r=false
assert "lsp-daemon child is not treated as real work" "$r"
kill_last

# L2: no child, low CPU -> keep
echo "L2: no child + low CPU -> kept"
spawn_serve 9913 idle
sleep 1
assert_fake_up 9913
out=$(run_reaper)
[[ "$out" == *"9913"* && "$out" == *"would reap"* ]] && r=false || r=true
assert "idle serve with no child is kept" "$r"
kill_last

# L3a: no child, high CPU, main thread parked -> reap
echo "L3a: no child + high CPU + main thread 96% kevent64 -> reaped"
spawn_serve 9914 busy
sleep 1
assert_fake_up 9914
out=$(FAKE_SAMPLE_KEV=2231 run_reaper)
[[ "$out" == *"9914"* && "$out" == *"would reap"* ]] && r=true || r=false
assert "GC-spinning serve is reaped" "$r"
[[ "$out" == *"in GC"* ]] && r2=true || r2=false
assert "reason names GC spin" "$r2"
kill_last

# L3b: no child, high CPU, but main thread executing JS -> keep  (the `yes` case)
echo "L3b: no child + high CPU + main thread busy in JS -> kept"
spawn_serve 9915 busy
sleep 1
assert_fake_up 9915
out=$(FAKE_SAMPLE_KEV=100 run_reaper)
[[ "$out" == *"9915"* && "$out" == *"would reap"* ]] && r=false || r=true
assert "serve burning CPU in JS is NOT reaped" "$r"
kill_last

# L3c: sample unavailable / failing -> cannot prove -> keep
echo "L3c: sample fails -> cannot prove spin -> kept"
spawn_serve 9916 busy
sleep 1
assert_fake_up 9916
out=$(FAKE_SAMPLE_FAIL=1 run_reaper)
[[ "$out" == *"9916"* && "$out" == *"would reap"* ]] && r=false || r=true
assert "unprovable spin keeps the serve" "$r"
kill_last

# L3d: another thread's kevent64 count must NOT be credited to the main thread.
# Main thread is busy in JS (100/2307 = 4%), while Thread_2 is parked (890/900 = 99%).
# Taking the max across the whole report would read 890/2307 = 38%... still under 95%, so
# push Thread_2 above the main thread's total to make the mismatch decisive: 3000/2307
# would exceed 100% and clear any threshold. Found by cross-review 2026-08-20.
echo "L3d: 其他线程的 kevent64 不得计入主线程 → 主线程在跑 JS 时必须保留"
spawn_serve 9917 busy
sleep 1
assert_fake_up 9917
out=$(FAKE_SAMPLE_KEV=100 FAKE_SAMPLE_OTHER_KEV=3000 run_reaper)
[[ "$out" == *"9917"* && "$out" == *"would reap"* ]] && r=false || r=true
assert "分子分母不混用（主线程 4% 忙于 JS ⇒ 保留）" "$r"
kill_last

# KEEP_PORT: shared serve protected even when OC_REVIEW_PORT is unset
echo "KEEP: shared port 4096 protected with no env vars set"
spawn_serve 4096 idle
sleep 1
assert_fake_up 4096
out=$(env -u OC_REVIEW_PORT -u OC_SERVE_PORT PATH="$FAKEBIN:$PATH" \
      OC_REAPER_MIN_AGE=0 OC_REAPER_SPIN_WINDOW=1 bash "$REAPER" 2>&1)
[[ "$out" == *"[keep] shared serve :4096"* ]] && r=true || r=false
assert "port 4096 kept by default and announced" "$r"
[[ "$out" == *"4096"* && "$out" == *"would reap"* ]] && r2=false || r2=true
assert "port 4096 never listed as reapable" "$r2"
kill_last

# L1c: a child that EXISTS is not the same as a child that is WORKING.
#
# Reported 2026-08-31: jest processes that finished their run but never exited — test code
# left a listening server (TCP 127.0.0.1:7777) and other open handles, so Node's event loop
# refused to exit, and none of the commands carried --forceExit. Those processes sit at
# CPU=0 forever while still being children of the serve. Under the old layer-1 rule that
# reads as "real work in flight", so the serve would never be reclaimed — the exact
# "existence stands in for liveness" substitution this file's own comments warn about.
echo "L1c: ⭐ 子进程存在但 CPU=0（跑完不退的 jest）→ 不算在干活"
spawn_serve 9921 with_idle_child
sleep 1
assert_fake_up 9921
out=$(FAKE_SAMPLE_KEV=2231 run_reaper)
[[ "$out" == *"9921"* && "$out" == *"would reap"* ]] && r=true || r=false
assert "闲置子进程不再阻止回收" "$r"
kill_last

echo "L1d: 子进程真在烧 CPU → 仍然保留（不能误杀在跑的测试）"
spawn_serve 9922 with_busy_child
sleep 1
assert_fake_up 9922
out=$(FAKE_SAMPLE_KEV=2231 run_reaper)
[[ "$out" == *"9922"* && "$out" == *"would reap"* ]] && r=false || r=true
assert "活跃子进程仍然保护 serve" "$r"
kill_last

echo
read -r P F < "$RESULTS_FILE"
echo "=== PASS=$P FAIL=$F ==="
rm -f "$RESULTS_FILE"
[[ "$F" -eq 0 ]]
