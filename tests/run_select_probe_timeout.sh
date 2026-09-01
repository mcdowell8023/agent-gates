#!/usr/bin/env bash
# Tests for model probing in lib/hetero/select.sh — it must not be able to hang.
#
# THE BUG (measured 2026-09-01): `_probe_model` ran `opencode run --pure -m <model> "say OK"`
# — a real model call, through the one channel already known to wedge for 120–200s — with
# no timeout at all, once per candidate model. doctor.sh was observed sitting at 6+ minutes,
# CPU 0%, having never reached the point where it writes hetero-check.json.
#
# The visible consequence was elsewhere: `review_models.primary` sat on a model that had
# been retired, because the only path that refreshes it both required opencode AND took long
# enough that nobody ever completed a run. A maintenance step slow enough to never finish is
# indistinguishable from one that does not exist.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$SCRIPT_DIR/../lib/hetero/select.sh"
RESULTS_FILE=$(mktemp); echo "0 0" > "$RESULTS_FILE"

assert() {
  local name="$1" cond="$2" p f
  read -r p f < "$RESULTS_FILE"
  if [[ "$cond" == "true" ]]; then echo "  ✓ $name"; echo "$((p+1)) $f" > "$RESULTS_FILE"
  else echo "  ✗ $name"; echo "$p $((f+1))" > "$RESULTS_FILE"; fi
}
eq() { assert "$1 → $3 (实际 $2)" "$([[ "$2" == "$3" ]] && echo true || echo false)"; }

export AGENT_GATES_DIR="$(mktemp -d)"
source "$LIB"

BIN=$(mktemp -d)
# A binary that never returns. If the probe has no timeout, calling this hangs the test —
# so the assertion is on ELAPSED TIME, which is the only thing that actually distinguishes
# "bounded" from "eventually gave up".
cat > "$BIN/hangs" <<'EOF'
#!/usr/bin/env bash
sleep 20
EOF
cat > "$BIN/answers" <<'EOF'
#!/usr/bin/env bash
echo "github-copilot/gpt-5.4"
echo "github-copilot/gemini-3.1-pro-preview"
EOF
chmod +x "$BIN/hangs" "$BIN/answers"

elapsed() { local t0 t1; t0=$(date +%s); "$@" >/dev/null 2>&1 || true; t1=$(date +%s); echo $((t1 - t0)); }

echo "=== select.sh probe timeout ==="
echo

echo "T1: ⭐ detect_available_models 遇到不返回的二进制必须限时退出"
E=$(HETERO_PROBE_TIMEOUT=3 elapsed detect_available_models "$BIN/hangs")
assert "≤10s 内返回 (实际 ${E}s)" "$([[ "$E" -le 10 ]] && echo true || echo false)"

echo "T2: ⭐ _probe_model 同样限时"
E=$(HETERO_PROBE_TIMEOUT=3 elapsed _probe_model "some/model" "$BIN/hangs")
assert "≤10s 内返回 (实际 ${E}s)" "$([[ "$E" -le 10 ]] && echo true || echo false)"

echo "T3: 超时按「探测失败」处理，不是「可用」"
HETERO_PROBE_TIMEOUT=3 _probe_model "some/model" "$BIN/hangs" >/dev/null 2>&1
rc=$?
assert "非零退出 (实际 $rc)" "$([[ $rc -ne 0 ]] && echo true || echo false)"

echo "T4: 正常返回的二进制不受影响"
out=$(HETERO_PROBE_TIMEOUT=10 detect_available_models "$BIN/answers")
assert "列出 gpt-5.4" "$([[ "$out" == *"gpt-5.4"* ]] && echo true || echo false)"
assert "列出 gemini" "$([[ "$out" == *gemini* ]] && echo true || echo false)"

echo "T5: build_review_models 整体也不能挂"
E=$(HETERO_PROBE_TIMEOUT=3 OC_REVIEW_OPENCODE="$BIN/hangs" elapsed build_review_models omc /nonexistent.json)
assert "≤30s 内返回 (实际 ${E}s)" "$([[ "$E" -le 30 ]] && echo true || echo false)"

echo "T6: 超时值可配，且非法值有兜底（不能因为配错就退化成无超时）"
E=$(HETERO_PROBE_TIMEOUT=abc elapsed _probe_model "m" "$BIN/hangs")
assert "非法值仍然限时 ≤70s (实际 ${E}s)" "$([[ "$E" -le 70 ]] && echo true || echo false)"

# --- 交叉审查(gemini-3.1-pro)抓到的三条 ---
echo
echo "T7: ⭐ 环境缺失时的诊断信息不能被吞掉"
# fail-closed 的提示写到 stderr，但两个调用点都带了 `2>/dev/null` —— 提示永远到不了任何人
# 眼前，系统静默降级成「没有可用模型」。检查点会说话，但没人听得见。
# /usr/bin:/bin has grep+sed but not node (node lives in ~/homebrew/bin).
# A fully bogus PATH would also break grep and give 127 for the wrong reason.
( PATH="/usr/bin:/bin" ; out=$(detect_available_models "$BIN/answers" 2>&1 || true)
  assert "提示可见（提到 with-timeout 或 node）" "$([[ "$out" == *with-timeout* || "$out" == *node* ]] && echo true || echo false)" )

echo "T8: ⭐ HETERO_PROBE_TIMEOUT=08 不能触发八进制算术错误"
# `^[0-9]+$` 放行 08/09，而 `[[ 08 -lt 1 ]]` 在 bash 里按八进制解释 →
# `value too great for base`，一条莫名其妙的报错漏到终端。实测过。
out=$(HETERO_PROBE_TIMEOUT=08 _hetero_probe_timeout 60 2>&1)
assert "无 base 报错 (输出: $out)" "$([[ "$out" != *"base"* ]] && echo true || echo false)"
eq "08 被当成十进制 8" "$out" 8
out=$(HETERO_PROBE_TIMEOUT=09 _hetero_probe_timeout 60 2>&1)
assert "09 同样不报错" "$([[ "$out" != *"base"* ]] && echo true || echo false)"

echo "T9: 环境缺失与「真的没有模型」必须可区分"
( PATH="/usr/bin:/bin"
  detect_available_models "$BIN/answers" >/dev/null 2>&1
  eq "返回 69（环境不可用）而非 0/1" "$?" 69 )
out=$(detect_available_models "$BIN/hangs" 2>/dev/null; echo "rc=$?")
assert "而真的探不到模型时不是 69" "$([[ "$out" != *"rc=69"* ]] && echo true || echo false)"

rm -rf "$BIN" "$AGENT_GATES_DIR"
echo
read -r P F < "$RESULTS_FILE"
echo "=== PASS=$P FAIL=$F ==="
rm -f "$RESULTS_FILE"
[[ "$F" -eq 0 ]]
