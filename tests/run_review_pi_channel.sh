#!/usr/bin/env bash
# agent-gates-review 的 pi 通道。
#
# THE GAP (2026-09-08 实证): `channels.opencode.enabled=false` 在 2026-08-26 就设了，
# 文档也把 opencode 降到第 3，但**代码层三处入口一处都没改**：
#
#   - `_try_review_model()` 硬编码 `${OC_REVIEW_OPENCODE:-opencode}`，⛔ 不查 channel 开关
#   - `agent-gates-review` 全文对 pi 零命中（`grep -c` 就是 0）
#   - 唯一实现了 pi 通道、唯一读 `channels.*.enabled` 的 `hetero_dispatch`，
#     **没有任何生产调用点** —— 全仓非注释引用全在 tests/ 里
#
# 后果不是"配置没生效"这么轻：用户 0818 明令「⛔ 不许用 opencode 做审查」，
# 两个子会话各自拿 opencode 审完报 PASS。规则靠任务书传递，**工具自己拦不住**。
# `bin/oc-review:69` 的注释里就写着这件事：
#   "v2.4.0 turned that channel off by default, but only hetero_dispatch consults the flag."
#
# 模型 id 两边通用（`github-copilot/gpt-5.6-sol` → pi 的 `--provider` + `--model`），
# 所以本通道复用 `review_models`，⛔ 不引入新配置键。
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
eq() { assert "$1 → 期望 [$3]，实际 [$2]" "$([[ "$2" == "$3" ]] && echo true || echo false)"; }

BIN=$(mktemp -d)
CALLS="$BIN/calls.log"

# fake pi：把收到的参数原样记下来，再吐一份合法审查文本。
cat > "$BIN/pi" <<'EOF'
#!/usr/bin/env bash
{ printf 'PI_ARGS:'; printf ' %s' "$@"; printf '\n'; } >> "$FAKE_CALLS"
echo "看过了，没问题。"
echo "VERDICT: PASS"
EOF
# fake opencode：吐 opencode 的 NDJSON 形状，好和 pi 的纯文本区分开。
cat > "$BIN/opencode" <<'EOF'
#!/usr/bin/env bash
{ printf 'OC_ARGS:'; printf ' %s' "$@"; printf '\n'; } >> "$FAKE_CALLS"
echo '{"type":"text","text":"看过了。\nVERDICT: PASS"}'
EOF
cat > "$BIN/pi-hangs" <<'EOF'
#!/usr/bin/env bash
sleep 30
EOF
chmod +x "$BIN/pi" "$BIN/opencode" "$BIN/pi-hangs"
export FAKE_CALLS="$CALLS"

# ⛔ FAIL-SAFE，文件作用域，不要移进任何函数或子 shell。
# 第一版用 PATH 收窄来隔离，结果 §7 为了把 node 放回 PATH 加了 `dirname $(which node)`
# —— 那正是 `~/homebrew/bin`，**真的 `pi` 也在里面**。于是测试拿真 pi 发了一次 API 调用
# 并挂到 120s 超时。改成用两个后端各自的覆盖变量点到 fake，PATH 怎么变都无所谓。
export AG_REVIEW_PI="$BIN/pi"
export OC_REVIEW_OPENCODE="$BIN/opencode"

# 生产里 has_valid_conclusion 由 bin/agent-gates-review 定义；pi 路径对它 fail-closed
# （缺了就拒绝，见 §13）。子 shell 统一 source 这份，别再依赖 fail-open。
HELPERS="$BIN/helpers.sh"
cat > "$HELPERS" <<'EOF'
has_valid_conclusion() { grep -qiE '^VERDICT:[[:space:]]*(PASS|FAIL|ISSUES|REVISE|APPROVED|REJECT)[[:space:]]*$' <<< "$1"; }
EOF

# serve.sh 的 fail-closed 会拦住 opencode 分支，测试里放行。
export OC_SERVE_DISABLED=1

mkcfg() {  # mkcfg <opencode-enabled|-> <pi-enabled|->
  local d; d=$(mktemp -d)
  python3 - "$d/hetero-check.json" "$1" "$2" <<'PY'
import json, sys
out, oc, pi = sys.argv[1], sys.argv[2], sys.argv[3]
ch = {}
if oc != '-': ch['opencode'] = {'enabled': oc == '1'}
if pi != '-': ch['pi'] = {'enabled': pi == '1'}
d = {'level': 'L3', 'review_models': {'primary': 'github-copilot/gpt-5.6-sol',
     'panel_pool': ['github-copilot/grok-4.5'], 'panel_active': 2, 'panel_mode': 'auto'},
     'channels': ch}
json.dump(d, open(out, 'w'))
PY
  echo "$d"
}

reset_calls() { : > "$CALLS"; }
called()      { grep -q "$1" "$CALLS" 2>/dev/null && echo true || echo false; }

echo "=== agent-gates-review pi 通道 ==="
echo

echo "--- §1 通道开关能被读到 ---"
D=$(mkcfg 0 -)
out=$(AGENT_GATES_DIR="$D" bash -c "source '$LIB'; _review_chan_enabled opencode && echo ON || echo OFF" 2>/dev/null)
eq "配置里 opencode.enabled=false" "$out" "OFF"
out=$(AGENT_GATES_DIR="$D" HETERO_CHAN_OPENCODE=1 bash -c "source '$LIB'; _review_chan_enabled opencode && echo ON || echo OFF" 2>/dev/null)
eq "env 压过配置文件" "$out" "ON"
D2=$(mktemp -d)
out=$(AGENT_GATES_DIR="$D2" bash -c "source '$LIB'; _review_chan_enabled opencode && echo ON || echo OFF" 2>/dev/null)
eq "没有配置文件 = 没人说要关（放行）" "$out" "ON"
out=$(AGENT_GATES_DIR="$D2" bash -c "source '$LIB'; _review_chan_enabled pi && echo ON || echo OFF" 2>/dev/null)
eq "pi 默认开" "$out" "ON"

echo
echo "--- §2 opencode 关掉时必须走 pi ---"
reset_calls
D=$(mkcfg 0 1)
out=$(AGENT_GATES_DIR="$D" bash -c "
  source '$LIB'; source "$HELPERS"
  _try_review_model github-copilot/gpt-5.6-sol '审一下' && echo \"TOOL=\$_REVIEW_TOOL_USED\"
" 2>/dev/null)
assert "调了 pi" "$(called PI_ARGS)"
assert "⭐ 没有调 opencode（开关生效）" "$([[ "$(called OC_ARGS)" == "false" ]] && echo true || echo false)"
assert "输出里有 VERDICT" "$([[ "$out" == *"VERDICT: PASS"* ]] && echo true || echo false)"
assert "_REVIEW_TOOL_USED=pi" "$([[ "$out" == *"TOOL=pi"* ]] && echo true || echo false)"

echo
echo "--- §3 provider 与 model 必须是两个独立参数 ---"
# 写成 `--model github-copilot/gpt-5.6-sol` 一串是文档里点名的坑；
# 而 `--provider ''` 会让 pi 报错或挂住。
A=$(grep -m1 PI_ARGS "$CALLS" 2>/dev/null)
assert "带 --provider github-copilot" "$([[ "$A" == *"--provider github-copilot"* ]] && echo true || echo false)"
assert "带 --model gpt-5.6-sol（不含斜杠）" "$([[ "$A" == *"--model gpt-5.6-sol"* ]] && echo true || echo false)"
assert "⭐ 审查者只读：带 --tools read,grep,find,ls" "$([[ "$A" == *"--tools read,grep,find,ls"* ]] && echo true || echo false)"
assert "带 -p（非交互）" "$([[ "$A" == *" -p"* ]] && echo true || echo false)"

echo
echo "--- §4 pi 的纯文本不能过 opencode 的 NDJSON 解析 ---"
reset_calls
out=$(AGENT_GATES_DIR="$D" bash -c "
  source '$LIB'; source "$HELPERS"
  # 装一个真实的 parse_opencode_json：它对纯文本会解析出空
  parse_opencode_json() { python3 -c '
import sys,json
for line in sys.stdin:
    try: d=json.loads(line)
    except Exception: continue
    if d.get(\"type\")==\"text\": sys.stdout.write(d.get(\"text\",\"\"))
'; }
  has_valid_conclusion() { grep -qE '^VERDICT:[[:space:]]*(PASS|FAIL|ISSUES)' <<< \"\$1\"; }
  _try_review_model github-copilot/gpt-5.6-sol '审一下' && echo OK || echo FAILED
" 2>/dev/null)
assert "⭐ pi 走通（没被 NDJSON 解析判成空）" "$([[ "$out" == *OK* ]] && echo true || echo false)"

echo
echo "--- §5 pi 关掉时回落 opencode，且工具名如实 ---"
reset_calls
D=$(mkcfg 1 0)
out=$(AGENT_GATES_DIR="$D" bash -c "
  source '$LIB'; source "$HELPERS"
  _try_review_model github-copilot/gpt-5.6-sol '审一下' >/dev/null && echo \"TOOL=\$_REVIEW_TOOL_USED\"
" 2>/dev/null)
assert "调了 opencode" "$(called OC_ARGS)"
assert "没调 pi" "$([[ "$(called PI_ARGS)" == "false" ]] && echo true || echo false)"
assert "_REVIEW_TOOL_USED=opencode" "$([[ "$out" == *"TOOL=opencode"* ]] && echo true || echo false)"

echo
echo "--- §6 两个都关 = 明确拒绝，不静默穿过去 ---"
reset_calls
D=$(mkcfg 0 0)
err=$(AGENT_GATES_DIR="$D" bash -c "
  source '$LIB'; source "$HELPERS"
  _try_review_model github-copilot/gpt-5.6-sol '审一下'
" 2>&1 >/dev/null); rc=$?
assert "非零退出（实际 ${rc}）" "$([[ $rc -ne 0 ]] && echo true || echo false)"
assert "两个通道都没被调用" "$([[ "$(called PI_ARGS)" == "false" && "$(called OC_ARGS)" == "false" ]] && echo true || echo false)"
assert "⭐ 报错点名两个通道（不是沉默）" \
  "$([[ "$err" == *pi* && "$err" == *opencode* ]] && echo true || echo false)"

echo
echo "--- §7 pi 不在就回落，不是整条链失败 ---"
reset_calls
D=$(mkcfg 1 1)
out=$(AGENT_GATES_DIR="$D" AG_REVIEW_PI="$BIN/does-not-exist" bash -c "
  source '$LIB'; source "$HELPERS"
  _try_review_model github-copilot/gpt-5.6-sol '审一下' >/dev/null && echo \"TOOL=\$_REVIEW_TOOL_USED\"
" 2>/dev/null)
eq "pi 缺失 → 用 opencode" "${out}" "TOOL=opencode"

echo
echo "--- §8 型号格式不合法时跳过 pi，不发 --provider '' ---"
reset_calls
D=$(mkcfg 1 1)
for bad in "gpt-5.6-sol" "github-copilot/" "/gpt-5.6-sol"; do
  AGENT_GATES_DIR="$D" bash -c "
    source '$LIB'; _try_review_model '$bad' '审一下'
  " >/dev/null 2>&1
done
assert "⭐ 三种坏格式都没走 pi" "$([[ "$(called PI_ARGS)" == "false" ]] && echo true || echo false)"

echo
echo "--- §9 pi 也必须有超时 ---"
reset_calls
D=$(mkcfg 0 1)
t0=$(date +%s)
AGENT_GATES_DIR="$D" AG_REVIEW_PI="$BIN/pi-hangs" AG_REVIEW_TIMEOUT=3 bash -c "
  source '$LIB'; _try_review_model github-copilot/gpt-5.6-sol '审一下'
" >/dev/null 2>&1
t1=$(date +%s); E=$((t1-t0))
assert "≤20s 内返回（实际 ${E}s）" "$([[ "$E" -le 20 ]] && echo true || echo false)"

echo
echo "--- §10 run_fallback_chain 也要带出工具名 ---"
reset_calls
D=$(mkcfg 0 1)
out=$(AGENT_GATES_DIR="$D" bash -c "
  source '$LIB'; source "$HELPERS"
  run_fallback_chain --primary github-copilot/gpt-5.6-sol --panel '' --prompt '审一下' >/dev/null \
    && echo \"M=\$_REVIEW_MODEL_USED T=\$_REVIEW_TOOL_USED\"
" 2>/dev/null)
eq "带出型号与工具" "$out" "M=github-copilot/gpt-5.6-sol T=pi"

echo
echo "--- §10b 两个通道的默认超时不同 ---"
# AG_REVIEW_TIMEOUT 的 120s 是给 opencode 调的 —— 那是「该通道判定为卡死」的界。
# pi 到 120s 不是卡死而是正在干活：2026-09-08/09 四次实测的真实审查在 1.5–4.5 分钟，
# 本通道第一次端到端跑就死在 200s 半途。继承 120s 会让健康的 pi 通道在每一次
# 非平凡审查上看起来是坏的。
eq "pi 默认 300s" "$(bash -c "source '$LIB'; _review_timeout_secs pi")" "300"
eq "opencode 默认仍是 120s" "$(bash -c "source '$LIB'; _review_timeout_secs opencode")" "120"
eq "AG_REVIEW_TIMEOUT 显式设置时 pi 听它" \
  "$(AG_REVIEW_TIMEOUT=45 bash -c "source '$LIB'; _review_timeout_secs pi")" "45"
eq "AG_REVIEW_PI_TIMEOUT 优先级最高" \
  "$(AG_REVIEW_TIMEOUT=45 AG_REVIEW_PI_TIMEOUT=600 bash -c "source '$LIB'; _review_timeout_secs pi")" "600"

echo
echo "--- §11 sidecar 必须能穿过命令替换 ---"
# 真实调用方是 `_raw=$(run_fallback_chain ...)`。§10 那种「同一个 shell 里读变量」
# 是测不到这一层的 —— 命令替换起子 shell，赋值随子 shell 一起消失。
reset_calls
D=$(mkcfg 0 1)
SIDE=$(mktemp)
captured=$(AGENT_GATES_DIR="$D" _REVIEW_SIDECAR="$SIDE" bash -c "
  source '$LIB'; source "$HELPERS"
  out=\$(run_fallback_chain --primary github-copilot/grok-4.5 --panel '' --prompt '审一下')
  printf 'VAR_TOOL=[%s]' \"\${_REVIEW_TOOL_USED:-}\"
" 2>/dev/null)
eq "sidecar 里的 tool" "$(sed -n 's/^tool=//p' "$SIDE" | head -1)" "pi"
eq "sidecar 里的 model" "$(sed -n 's/^model=//p' "$SIDE" | head -1)" "github-copilot/grok-4.5"
# 负对照：证明 sidecar 不是装饰 —— 变量确实穿不过去。
assert "⭐ 负对照：变量穿不过命令替换（所以 sidecar 是必需的）" \
  "$([[ "$captured" == "VAR_TOOL=[]" ]] && echo true || echo false)"

echo
echo "--- §12 派发建议不能再把 opencode 排第一 ---"
# 这一条钉的是把子会话带偏的那个东西：`--route paseo --dispatch-out` 输出的
# `suggested.provider` 原本写死 `opencode/...`、alternatives 里连 pi 都没有 ——
# 而这台机器上 channels.opencode.enabled=false 正是为了不让 agent 走它。
# 工具推荐了被禁的通道，agent 照做，禁令就这样被破了两次。
DOUT=$(mktemp); DGD=$(mktemp -d)
cp "$SCRIPT_DIR/../$(basename "$(dirname "$LIB")")/../../.version" "$DGD/.version" 2>/dev/null || echo "2.9.3" > "$DGD/.version"
python3 - "$DGD/hetero-check.json" <<'PY2'
import json, sys
json.dump({'level': 'L3', 'review_models': {'primary': 'github-copilot/gpt-5.6-sol',
          'panel_pool': [], 'panel_active': 2, 'panel_mode': 'off'}}, open(sys.argv[1], 'w'))
PY2
PMT=$(mktemp); echo "审一下" > "$PMT"
( cd "$SCRIPT_DIR/.." && AGENT_GATES_DIR="$DGD" bash bin/agent-gates-review "$PMT" \
    --route paseo --dispatch-out "$DOUT" ) >/dev/null 2>&1
SUG=$(python3 -c "
import json,sys
try: d=json.load(open(sys.argv[1]))
except Exception: print('<no dispatch-out>'); raise SystemExit
s=d.get('suggested',{})
print(s.get('provider',''), '|', ','.join(s.get('alternatives',[])), '|', 'HAS_NOAGENT' if d.get('import_cmd_no_agent') else 'NO_NOAGENT')
" "$DOUT" 2>/dev/null)
assert "⭐ suggested.provider 走 pi" "$([[ "$SUG" == pi/* ]] && echo true || echo false)"
assert "alternatives 里有 pi 的第二型号" "$([[ "$SUG" == *"pi/github-copilot/grok-4.5"* ]] && echo true || echo false)"
assert "⭐ opencode 不是首选" "$([[ "$SUG" != opencode/* ]] && echo true || echo false)"
assert "opencode 带警告出现在 alternatives 末尾" \
  "$([[ "$SUG" == *"opencode/github-copilot/gpt-5.5 (⛔"* ]] && echo true || echo false)"
assert "⭐ 给出了无 Paseo agent 的登记命令" "$([[ "$SUG" == *HAS_NOAGENT* ]] && echo true || echo false)"

echo
echo "--- §13 三条来自 pi 通道自审的修复（gpt-5.6-sol via pi）---"
# 这三条是本通道建好之后、用它自己审自己新增代码抓出来的。

# F1: has_valid_conclusion 缺失时必须 fail-closed。
# 之前是 `declare -f X && ! X` —— 函数不存在时整个校验被跳过，
# 任何非空输出（报错、拒答、半截回复）都会被当成通过的审查。
reset_calls
D=$(mkcfg 0 1)
NOVERDICT=$(mktemp -d)
cat > "$NOVERDICT/pi" <<'EOF'
#!/usr/bin/env bash
echo "我不太确定，你自己看吧。"
EOF
chmod +x "$NOVERDICT/pi"
out=$(AGENT_GATES_DIR="$D" AG_REVIEW_PI="$NOVERDICT/pi" bash -c "
  source '$LIB'; source "$HELPERS"
  # 刻意不定义 has_valid_conclusion
  _try_review_model github-copilot/gpt-5.6-sol '审一下' && echo ACCEPTED || echo REFUSED
" 2>/dev/null)
eq "⭐ 校验函数缺失 → 拒绝，不是放行" "$out" "REFUSED"

# F3: _l 不能泄漏到调用者作用域
out=$(AGENT_GATES_DIR="$D" bash -c "
  source '$LIB'; source "$HELPERS"
  _l=CALLER_VALUE
  _review_via_pi github-copilot/gpt-5.6-sol 'x' >/dev/null 2>&1
  echo \"_l=\$_l\"
" 2>/dev/null)
eq "调用者的 _l 没被覆盖" "$out" "_l=CALLER_VALUE"

echo
echo "--- §14 在调用方真实 shell 选项下复跑 ---"
# F2: 门禁 source 本文件（hooks/git/agent-quality-gate.sh:664）且跑在 set -euo pipefail 下。
# 而本文件的测试一直跑在 set -uo pipefail（没有 -e）—— 这一整类「命令替换失败导致
# 静默退出」的错误，测试根本抓不到。判据是**输出完整性**：提前死亡的表现是截断，不是报错。
run_ee() { ( set -euo pipefail; source "$LIB"; "$@" ) 2>/dev/null; }
eq "-e 下 _review_timeout_secs pi 跑到底" "$(run_ee _review_timeout_secs pi)" "300"
out=$(AGENT_GATES_DIR="$(mkcfg 0 1)" AG_REVIEW_PI="$BIN/does-not-exist" bash -c "
  set -euo pipefail
  source '$LIB'; source "$HELPERS"
  has_valid_conclusion() { grep -qE '^VERDICT:' <<< \"\$1\"; }
  _try_review_model github-copilot/gpt-5.6-sol '审一下' >/dev/null 2>&1 || true
  echo REACHED_END
")
eq "⭐ -e 下走完整条通道链（pi 缺失 + opencode 关闭）仍到达末尾" "$out" "REACHED_END"
out=$(AGENT_GATES_DIR="$(mkcfg 1 1)" AG_REVIEW_PI="$BIN/pi" bash -c "
  set -euo pipefail
  source '$LIB'; source \"$HELPERS\"
  _try_review_model github-copilot/gpt-5.6-sol '审一下' >/dev/null 2>&1 || true
  echo REACHED_END
")
eq "⭐ -e 下 pi 成功路径也到达末尾" "$out" "REACHED_END"

# ⭐ 这条才是真正抓 errexit 的那一条。上面两条**都够不到** `raw=$(...)`：
# pi 缺失时函数提前 return；pi 成功时命令替换不失败。要让 `set -e` 有机会
# 在 `rc=$?` 之前杀掉进程，pi 必须**跑起来并非零退出**。
# （第一版少了这条，注入变异后 §14 全绿 —— 空过。）
PIFAIL=$(mktemp -d)
cat > "$PIFAIL/pi" <<'EOF'
#!/usr/bin/env bash
echo "boom" >&2
exit 3
EOF
chmod +x "$PIFAIL/pi"
# ⛔ 判据不能是「跑到末尾」。`f || true` 会把整个函数放进 AND-OR 列表，
# 而 bash 在 AND-OR 列表内部**挂起 errexit** —— 加了 `|| true` 就永远测不出这个 bug
# （实测：注入变异后带 `|| true` 的用例照样全绿）。
# 唯一能区分的观察量是**错误信息有没有被打出来**：
#   有守卫 → 先打印 "pi exited 3" 再 return 1（脚本随后才因 set -e 退出）
#   无守卫 → 死在 `raw=$(...)` 那一行，一个字都没有
err=$(AGENT_GATES_DIR="$(mkcfg 1 1)" AG_REVIEW_PI="$PIFAIL/pi" bash -c "
  set -euo pipefail
  source '$LIB'; source \"$HELPERS\"
  _review_via_pi github-copilot/gpt-5.6-sol '审一下' >/dev/null
" 2>&1)
assert "⭐⭐ -e 下 pi 非零退出仍报出退出码（errexit 守卫的判别用例）" \
  "$([[ "$err" == *"pi exited 3"* ]] && echo true || echo false)"
# 同一观察量在不开 -e 时也必须成立，否则上一条可能是别的原因绿的
err2=$(AGENT_GATES_DIR="$(mkcfg 1 1)" AG_REVIEW_PI="$PIFAIL/pi" bash -c "
  source '$LIB'; source \"$HELPERS\"
  _review_via_pi github-copilot/gpt-5.6-sol '审一下' >/dev/null
" 2>&1)
assert "不开 -e 时同样报出退出码（对照）" "$([[ "$err2" == *"pi exited 3"* ]] && echo true || echo false)"

echo
read -r P F < "$RESULTS_FILE"
echo "PASS=$P FAIL=$F"
rm -f "$RESULTS_FILE"
[[ "$F" -eq 0 ]] || exit 1
