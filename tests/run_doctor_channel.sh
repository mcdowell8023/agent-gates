#!/usr/bin/env bash
# doctor 必须听通道开关。
#
# 起因（2026-09-10 实测）：用户卸载 opencode 后，`~/.opencode` 在 40 分钟内**自己回来了**，
# 端口 4096 上又起了一个 PPID=1 的 `opencode serve`（目录时间戳全是原始的 ⇒ 是被还原、
# 不是重装）。查下来最可能是 doctor：它的 D6 探测无条件 shell out 到 opencode，
# 而链路里的 `oc_serve_ensure` 会**直接把 serve 拉起来** —— 只要二进制在，
# 任何一次 doctor 都能复活它。同时它还把能力报成 "L3 (opencode + codex)"，
# 而那台机器上 opencode 已经不存在了。
#
# ⇒ `channels.opencode.enabled=false` 时，doctor 必须：① 不探测 ② 不起 serve
# ③ 能力报告按**实际可用通道**算，⛔ 不把关掉的通道算进去。
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOCTOR="$SCRIPT_DIR/../doctor.sh"
RESULTS_FILE=$(mktemp); echo "0 0" > "$RESULTS_FILE"
assert() {
  local name="$1" cond="$2" p f
  read -r p f < "$RESULTS_FILE"
  if [[ "$cond" == "true" ]]; then echo "  ✓ $name"; echo "$((p+1)) $f" > "$RESULTS_FILE"
  else echo "  ✗ $name"; echo "$p $((f+1))" > "$RESULTS_FILE"; fi
}

BIN=$(mktemp -d); CALLS=$(mktemp)
cat > "$BIN/opencode" <<'EOF'
#!/usr/bin/env bash
echo "OPENCODE_CALLED $*" >> "$FAKE_CALLS"
echo "github-copilot/gpt-5.5"
EOF
chmod +x "$BIN/opencode"
export FAKE_CALLS="$CALLS"

mkgd() {  # mkgd <opencode-enabled|->
  local d; d=$(mktemp -d)
  mkdir -p "$d/hooks/git" "$d/hooks/platform" "$d/lib/hetero" "$d/bin" "$d/data"
  echo "9.9.9" > "$d/.version"
  # ⚠️ D6 的模型探测（真正会**执行** opencode 的那一步）只在
  # `$INSTALL_DIR/lib/hetero/select.sh` 存在时才跑 —— 缺它的话 `command -v opencode`
  # 虽然被调到，fake 却一次都不会被执行，正对照就变成空心的。
  cp "$SCRIPT_DIR/../lib/hetero/select.sh" "$d/lib/hetero/" 2>/dev/null || true
  cp "$SCRIPT_DIR/../lib/hetero/serve.sh" "$d/lib/hetero/" 2>/dev/null || true
  cp "$SCRIPT_DIR/../data/review-model-recommendations.json" "$d/data/" 2>/dev/null || true
  python3 - "$d/hetero-check.json" "$1" <<'PY'
import json, sys
out, oc = sys.argv[1], sys.argv[2]
d = {"level": "L3", "decision_tree": []}
if oc != '-': d["channels"] = {"opencode": {"enabled": oc == '1'}}
json.dump(d, open(out, "w"))
PY
  echo "$d"
}

echo "=== doctor 听通道开关 ==="
echo
echo "--- opencode 通道关掉时 ---"
: > "$CALLS"
D=$(mkgd 0)
out=$(AGENT_GATES_DIR="$D" PATH="$BIN:$PATH" node "$SCRIPT_DIR/../bin/with-timeout.mjs" 90 bash "$DOCTOR" 2>&1 || true)
assert "⭐ 完全没调 opencode（不探测、更不可能起 serve）" \
  "$([[ ! -s "$CALLS" ]] && echo true || echo false)"
# ⛔ 旧断言是 `$out != *capability*opencode*` —— glob **跨行匹配**：
# 「Cross-review capability: L1 (codex)」和后面任何提到 opencode 路径的行合起来就命中
# ⇒ 它其实在测「capability 之后有没有出现过 opencode 这个词」，不是「能力报告是否声称
#    opencode 可用」。实测被一条无关的 OMO 路径警告触发（main 上就是红的）。改成只看那一行。
cap_line=$(printf '%s\n' "$out" | grep -i 'Cross-review capability' | head -1)
assert "⭐ 能力报告里不再声称 opencode 可用（只看 capability 那一行）" \
  "$([[ -n "$cap_line" && "$cap_line" != *opencode* ]] && echo true || echo false)"
assert "有说明为什么跳过（不是静默）" \
  "$(echo "$out" | grep -qiE 'opencode.*(disabled|关|跳过|skipped)' && echo true || echo false)"
assert "doctor 本身没崩（仍打出汇总行）" \
  "$(echo "$out" | grep -qE '[0-9]+ pass' && echo true || echo false)"

echo
echo "--- 通道开着时行为不变（正对照）---"
: > "$CALLS"
D=$(mkgd 1)
out=$(AGENT_GATES_DIR="$D" PATH="$BIN:$PATH" node "$SCRIPT_DIR/../bin/with-timeout.mjs" 90 bash "$DOCTOR" 2>&1 || true)
# ⚠️ 判据不能用「fake 是否被执行」：真正会 exec opencode 的是 D6 的
# detect_available_models，那条链还要 $INSTALL_DIR/bin/with-timeout.mjs 等一整套安装布局，
# fake 目录凑不出来 ⇒ 断言会永远为假（空心的正对照）。
# 改成看**能力行里有没有 opencode** —— 它直接反映「探测没被跳过」。
assert "⭐ 显式开启时 opencode 仍进入能力判定（没被跳过）" \
  "$(echo "$out" | grep -qE 'capability.*opencode' && echo true || echo false)"
assert "⭐ 且不再打印「已跳过」的说明" \
  "$(echo "$out" | grep -qiE 'opencode channel disabled' && echo false || echo true)"

echo
echo "--- 缺配置时按 config.sh 的默认（opencode=0）---"
: > "$CALLS"
D=$(mkgd -)
out=$(AGENT_GATES_DIR="$D" PATH="$BIN:$PATH" node "$SCRIPT_DIR/../bin/with-timeout.mjs" 90 bash "$DOCTOR" 2>&1 || true)
assert "⭐ 没写 channels 键也不探测（与 lib/hetero/config.sh 同口径）" \
  "$([[ ! -s "$CALLS" ]] && echo true || echo false)"

echo
echo "--- opencode 在 PATH 上但没有 serve 时，doctor 不能静默死掉 ---"
# 🔴 实测（2026-09-10）：check_opencode_health 里
#   total=$(pgrep -f "opencode serve" | wc -l | tr -d ' ')
# 在没有 serve 时 pgrep 退出码 1 ⇒ pipefail ⇒ 赋值非零 ⇒ set -e 杀掉 doctor。
# 后果是它**下一行**那个 `pass "no leaked serve processes"` 永远到不了（死代码），
# 而 doctor 不打汇总就退出 —— 看起来像"跑完了"。与一线反馈的 BUG 1 同一家族。
D=$(mkgd 1)
out=$(AGENT_GATES_DIR="$D" PATH="$BIN:$PATH" node "$SCRIPT_DIR/../bin/with-timeout.mjs" 90 bash "$DOCTOR" 2>&1 || true)
assert "⭐⭐ 仍然打出汇总行（0 个 serve 也不死）" \
  "$(echo "$out" | grep -qE '[0-9]+ pass' && echo true || echo false)"
assert "⭐ 那条原本不可达的 pass 现在到得了" \
  "$(echo "$out" | grep -qiE 'no leaked serve|serve health' && echo true || echo false)"

echo
echo "--- doctor 只能写 AGENT_GATES_DIR 里面 ---"
# 🔴 doctor 原来硬编码 INSTALL_DIR="$HOME/.agent-gates"，⇒ 任何带 AGENT_GATES_DIR 的
# 调用（包括本测试）都会写**真实**配置。本轮 RED 阶段就因此冲掉了用户手工设的
# review_models.primary 与 panel_pool，而 doctor 只打印 "wrote ~/.agent-gates/..."，
# 看不出它写的不是测试目录。
LIVE="$HOME/.agent-gates/hetero-check.json"
LIVE_BEFORE=""; [[ -f "$LIVE" ]] && LIVE_BEFORE=$(cat "$LIVE")
D=$(mkgd 0)
out=$(AGENT_GATES_DIR="$D" node "$SCRIPT_DIR/../bin/with-timeout.mjs" 90 bash "$DOCTOR" 2>&1 || true)
assert "⭐ 写进了 AGENT_GATES_DIR，不是 \$HOME/.agent-gates" \
  "$([[ "$out" == *"$D/hetero-check.json"* ]] && echo true || echo false)"
if [[ -n "$LIVE_BEFORE" ]]; then
  assert "⭐⭐ 真实配置一个字节都没被改（这条是本轮真出过事的）" \
    "$([[ "$(cat "$LIVE")" == "$LIVE_BEFORE" ]] && echo true || echo false)"
fi

echo
echo
echo "--- opencode 已卸载但 ~/.config/opencode 被别人重建 ⇒ ⛔ 不许再叫用户注册钩子 ---"
# 🔴 实况（2026-09-11 11:44）：opencode 早已卸载，PATH 里没有它，但
# `~/.config/opencode/plugins/paseo-terminal-activity.js` 又出现了 —— **Paseo 的 daemon
# 每次启动都会写这个插件**，不管 opencode 在不在，顺手把目录建回来。
# doctor 只看目录存在就判「OMO 装着」⇒ 警告用户 `install.sh --upgrade` 去给一个
# **不存在的工具**注册钩子。用户的明确要求是「不想再看到哪个 agent 和 opencode 纠缠」。
FH=$(mktemp -d)
mkdir -p "$FH/.config/opencode/plugins"
echo '// paseo plugin' > "$FH/.config/opencode/plugins/paseo-terminal-activity.js"
D=$(mkgd 0)
NODEDIR=$(dirname "$(command -v node)")
out=$(HOME="$FH" AGENT_GATES_DIR="$D" PATH="$NODEDIR:/usr/bin:/bin:/usr/sbin:/sbin" \
  bash "$DOCTOR" 2>&1 || true)
assert "⛔ 不再报 hooks.json missing" \
  "$([[ "$out" != *"OMO hooks.json missing"* ]] && echo true || echo false)"
assert "⛔ 不再让用户跑 install.sh --upgrade 去注册 opencode 钩子" \
  "$([[ "$out" != *"--upgrade to auto-register"* ]] && echo true || echo false)"
assert "⭐ 但要说清为什么跳过（⛔ 不是静默）" \
  "$(echo "$out" | grep -qiE 'opencode.*(not installed|未安装|skipping)' && echo true || echo false)"
assert "⭐ doctor 本身没崩" \
  "$(echo "$out" | grep -qE '[0-9]+ pass' && echo true || echo false)"

read -r P F < "$RESULTS_FILE"
echo "PASS=$P FAIL=$F"
rm -f "$RESULTS_FILE"
[[ "$F" -eq 0 ]] || exit 1
