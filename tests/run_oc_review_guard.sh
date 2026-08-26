#!/usr/bin/env bash
# Tests for oc-review refusing to run when the opencode channel is disabled.
#
# Why this exists: v2.4.0 turned the opencode channel off by default, but that flag is only
# consulted by hetero_dispatch. `oc-review` is a standalone command — an agent (or a skill,
# or a habit) that calls it directly bypassed the decision entirely, started a shared
# `opencode serve`, and then blocked for the full AG_REVIEW_TIMEOUT. Observed repeatedly:
# "审查卡住导致任务无法进行" while the channel was supposedly disabled.
#
# Failing fast here is the point: 5 minutes of hanging is worse than an immediate error
# that names the alternative.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OC_REVIEW="$SCRIPT_DIR/../bin/oc-review"
RESULTS_FILE=$(mktemp); echo "0 0" > "$RESULTS_FILE"

assert() {
  local name="$1" cond="$2" p f
  read -r p f < "$RESULTS_FILE"
  if [[ "$cond" == "true" ]]; then echo "  ✓ $name"; echo "$((p+1)) $f" > "$RESULTS_FILE"
  else echo "  ✗ $name"; echo "$p $((f+1))" > "$RESULTS_FILE"; fi
}

# A fake opencode that would hang if ever reached — so "fast refusal" is provable rather
# than assumed. If the guard fails, the test times out instead of quietly passing.
FAKEBIN=$(mktemp -d)
cat > "$FAKEBIN/opencode" <<'FAKE'
#!/usr/bin/env bash
sleep 300
FAKE
chmod +x "$FAKEBIN/opencode"
cleanup() { rm -rf "$FAKEBIN" "${GD:-}"; }
trap cleanup EXIT

echo "=== oc-review channel guard tests ==="
echo

echo "G1: HETERO_CHAN_OPENCODE=0 → 立即拒绝，不起 serve"
S=$(date +%s)
out=$(PATH="$FAKEBIN:$PATH" HETERO_CHAN_OPENCODE=0 bash "$OC_REVIEW" run -m x/y "p" 2>&1); rc=$?
E=$(( $(date +%s) - S ))
assert "非零退出 (rc=$rc)" "$([[ $rc -ne 0 ]] && echo true || echo false)"
assert "5 秒内返回（实际 ${E}s，证明没去起 serve）" "$([[ $E -lt 5 ]] && echo true || echo false)"
assert "提示指向 pi" "$([[ "$out" == *pi* ]] && echo true || echo false)"
assert "说明如何恢复" "$([[ "$out" == *HETERO_CHAN_OPENCODE* || "$out" == *enabled* ]] && echo true || echo false)"

echo "G2: 配置文件禁用时同样拒绝（不只认 env）"
GD=$(mktemp -d)
printf '{"channels":{"opencode":{"enabled":false}}}\n' > "$GD/hetero-check.json"
S=$(date +%s)
out=$(PATH="$FAKEBIN:$PATH" AGENT_GATES_DIR="$GD" env -u HETERO_CHAN_OPENCODE bash "$OC_REVIEW" run -m x/y "p" 2>&1); rc=$?
E=$(( $(date +%s) - S ))
assert "配置禁用 → 非零退出 (rc=$rc)" "$([[ $rc -ne 0 ]] && echo true || echo false)"
assert "配置禁用 → 快速返回（${E}s）" "$([[ $E -lt 8 ]] && echo true || echo false)"

echo "G3: 显式启用时不被拒（守卫不能把通道彻底堵死）"
out=$(PATH="$FAKEBIN:$PATH" HETERO_CHAN_OPENCODE=1 AG_REVIEW_TIMEOUT=3 bash "$OC_REVIEW" run -m x/y "p" 2>&1); rc=$?
assert "启用后不报「通道已禁用」" "$([[ "$out" != *"channel is disabled"* && "$out" != *"通道已禁用"* ]] && echo true || echo false)"

echo "G4: 超时默认已从 300s 收窄"
grep -qE 'AG_REVIEW_TIMEOUT:-(120|90|60)\}' "$OC_REVIEW" && r=true || r=false
assert "oc-review 默认 <=120s" "$r"
grep -qE 'AG_REVIEW_TIMEOUT:-(120|90|60)\}' "$SCRIPT_DIR/../bin/agent-gates-review" && r=true || r=false
assert "agent-gates-review 默认 <=120s" "$r"
grep -qE 'AG_REVIEW_TIMEOUT:-(120|90|60)\}' "$SCRIPT_DIR/../lib/hetero/select.sh" && r=true || r=false
assert "select.sh 默认 <=120s" "$r"

echo
read -r P F < "$RESULTS_FILE"
echo "=== PASS=$P FAIL=$F ==="
rm -f "$RESULTS_FILE"
[[ "$F" -eq 0 ]]
