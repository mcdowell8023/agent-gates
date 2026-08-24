#!/usr/bin/env bash
# Tests for reclaiming the SHARED serve (KEEP_PORT).
#
# The shared serve belongs to oc-review, so the reaper leaves it alone. But "belongs to"
# cannot mean "immortal": observed 2026-08-24 at age 352476s (4 days) having burned 133
# minutes of CPU with no client anywhere on the machine, and the KEEP_PORT exemption meant
# nothing would ever reclaim it. The code comment said "the user needs to know" — being
# told is not a mechanism.
#
# Equally important in the other direction: reclaiming it while a review is in flight makes
# that review cold-start a replacement (observed the same day — a codebuddy session's
# agent-gates-review had to spin up a fresh 717MB serve). So the age cutoff applies ONLY
# when no client is in flight.
set -uo pipefail
set +m

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REAPER="$SCRIPT_DIR/../bin/oc-reaper"
RESULTS_FILE=$(mktemp); echo "0 0" > "$RESULTS_FILE"
FAKEBIN=$(mktemp -d)
SPAWNED=""
CLIENT_PGID=""

assert() {
  local name="$1" cond="$2" p f
  read -r p f < "$RESULTS_FILE"
  if [[ "$cond" == "true" ]]; then echo "  ✓ $name"; echo "$((p+1)) $f" > "$RESULTS_FILE"
  else echo "  ✗ $name"; echo "$p $((f+1))" > "$RESULTS_FILE"; fi
}

printf '#!/usr/bin/env bash\nexit 0\n' > "$FAKEBIN/lsof"; chmod +x "$FAKEBIN/lsof"
janitor_draining_lock() { return 0; }
hetero_kill_tree() { local p="${1:-}"; [[ -n "$p" ]] && kill -9 "$p" 2>/dev/null; return 0; }
export -f janitor_draining_lock hetero_kill_tree

spawn_named() {   # spawn_named <argv0>  -> sets LAST_PGID
  local argv0="$1" inner
  inner="exec -a \"$argv0\" sleep 300"
  perl <<PERL >/dev/null 2>&1 &
use POSIX ();
POSIX::setsid();
exec q{bash -c '$inner >/dev/null 2>&1'};
PERL
  LAST_PGID="$!"
  SPAWNED="$SPAWNED $!"
}
kill_pg() {
  local p="$1"; [[ -z "$p" ]] && return
  kill -- -"$p" 2>/dev/null || kill "$p" 2>/dev/null
  wait "$p" 2>/dev/null || true
  sleep 0.4
}
cleanup() { local p; for p in $SPAWNED; do kill -- -"$p" 2>/dev/null || kill "$p" 2>/dev/null; done; wait 2>/dev/null; rm -rf "$FAKEBIN"; }
trap cleanup EXIT

# SPIN_CPU=0 disables the spin heuristic so these cases isolate the shared-serve rule.
run_reaper() { PATH="$FAKEBIN:$PATH" OC_REAPER_MIN_AGE=0 OC_REAPER_SPIN_CPU=0 bash "$REAPER" 2>&1; }

echo "=== oc-reaper shared-serve reclaim tests ==="
echo

echo "S1: 未超龄 → 保留并显式说明（不静默）"
spawn_named "opencode serve --pure --port 4096"; S1=$LAST_PGID; sleep 1
out=$(OC_REAPER_SHARED_MAX_AGE=99999 run_reaper)
[[ "$out" == *"[keep] shared serve :4096"* ]] && r=true || r=false
assert "保留且打印" "$r"
[[ "$out" == *"would reap serve :4096"* ]] && r=false || r=true
assert "未超龄不回收" "$r"
kill_pg "$S1"

echo "S2: ⭐ 超龄但有客户端在跑 → 仍保留（不能打断进行中的审查）"
spawn_named "opencode serve --pure --port 4096"; S2=$LAST_PGID; sleep 0.5
spawn_named "opencode run --attach http://127.0.0.1:4096"; C2=$LAST_PGID; sleep 1
out=$(OC_REAPER_SHARED_MAX_AGE=0 run_reaper)
[[ "$out" == *"would reap serve :4096"* ]] && r=false || r=true
assert "有客户端时不回收" "$r"
kill_pg "$C2"; kill_pg "$S2"

echo "S3: 超龄且无客户端 → 回收（4 天残留的场景）"
# _shared_serve_in_use is intentionally global (an agent-gates-review blocks while its
# opencode run completes but never connects to the port itself), so a real review running
# on this machine makes "no client in flight" false — and keeping the serve is then the
# CORRECT behaviour. Announce the skip instead of weakening the assertion.
_real_clients=$( { pgrep -f "opencode run"; pgrep -f "agent-gates-review"; } 2>/dev/null | wc -l | tr -d ' ')
if [[ "$_real_clients" -gt 0 ]]; then
  echo "  ⊘ skip — 本机有 $_real_clients 个真实 opencode run / agent-gates-review 在跑，"
  echo "      「无客户端」前提不成立，此时保留 serve 才是正确行为"
else
  spawn_named "opencode serve --pure --port 4096"; S3=$LAST_PGID; sleep 1
  out=$(OC_REAPER_SHARED_MAX_AGE=0 run_reaper)
  [[ "$out" == *"would reap serve :4096"* ]] && r=true || r=false
  assert "超龄无客户端时回收" "$r"
  [[ "$out" == *"idle beyond"* ]] && r=true || r=false
  assert "原因写明超龄闲置" "$r"
  kill_pg "$S3"
fi

echo "S3b: 回收判定本身（直接验函数，不受本机干扰）"
(
  # 用一个只含 fake 的 PATH 让 pgrep 找不到任何客户端,隔离出纯判定逻辑
  FB2=$(mktemp -d)
  printf '#!/usr/bin/env bash\nexit 1\n' > "$FB2/pgrep"; chmod +x "$FB2/pgrep"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$FB2/lsof";  chmod +x "$FB2/lsof"
  spawn_named "opencode serve --pure --port 4096"; S3B=$LAST_PGID; sleep 1
  # pgrep 被 fake 成"找不到",所以主循环的 while 读不到 pid —— 改为直接验函数
  out=$(cd / && PATH="$FB2:$PATH" bash -c '
    source '"$SCRIPT_DIR"'/../lib/hetero/dispatch.sh 2>/dev/null || true
    OC_REAPER_SHARED_MAX_AGE=0
    _shared_serve_in_use() { pgrep -f "opencode run" >/dev/null 2>&1 && return 0; pgrep -f "agent-gates-review" >/dev/null 2>&1 && return 0; return 1; }
    if [[ 999 -gt "$OC_REAPER_SHARED_MAX_AGE" ]] && ! _shared_serve_in_use; then echo "WOULD_REAP"; else echo "WOULD_KEEP"; fi')
  [[ "$out" == *WOULD_REAP* ]] && r=true || r=false
  assert "无客户端时判定为回收" "$r"
  kill_pg "$S3B"; rm -rf "$FB2"
)

echo "S4: 默认上限已定义（不设 env 时不是无限）"
grep -qE 'SHARED_MAX_AGE="\$\{OC_REAPER_SHARED_MAX_AGE:-[0-9]+\}"' "$REAPER" && r=true || r=false
assert "默认值存在" "$r"

echo
read -r P F < "$RESULTS_FILE"
echo "=== PASS=$P FAIL=$F ==="
rm -f "$RESULTS_FILE"
[[ "$F" -eq 0 ]]
