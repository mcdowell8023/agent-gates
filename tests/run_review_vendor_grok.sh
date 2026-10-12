#!/usr/bin/env bash
# grok 进入审查候选池。
#
# 起因：用户报告 gemini 的审查质量不行，要求让 grok-4.5 接掉 gemini 的位置。
# 换型号本身是改一行数据，但光改数据不生效 —— `_extract_vendor` 的 case 表里没有
# grok，返回 "unknown"，而 build_review_models 里紧跟着一句
# `[[ "$v" == "unknown" ]] && continue`。所以配置里写了 grok，池子里也不会有它，
# 而且是静默的：没有任何一行输出说"我认不出这个厂商所以跳过了"。
#
# 顺带确认 gemini 该退场：`opencode models` 与 pi 的 github-copilot catalog（2026-09-08
# 实测）都已经没有 gemini-3.1-pro-preview，只剩 gemini-*-flash，而 build_review_models 里
# 有一句硬编码的 `[[ "$name" == *flash* ]] && continue`。也就是说 gemini 那个格子早就是空的。
#
# ⚠️ 剔 flash 靠的是那句**硬编码**，不是 data/review-model-recommendations.json 里的
# `excluded_patterns` —— 那个字段全库 lib/ 零引用（见 §4）。第一版这个文件把机制写成
# 「命中 excluded_patterns」，两个审查模型都指出来了：一条只读 JSON 字段的断言，
# 名字叫「仍然排除」，实际什么行为都没验证，等于给一份死配置续命。
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$SCRIPT_DIR/../lib/hetero/select.sh"
REC="$SCRIPT_DIR/../data/review-model-recommendations.json"
RESULTS_FILE=$(mktemp); echo "0 0" > "$RESULTS_FILE"

assert() {
  local name="$1" cond="$2" p f
  read -r p f < "$RESULTS_FILE"
  if [[ "$cond" == "true" ]]; then echo "  ✓ $name"; echo "$((p+1)) $f" > "$RESULTS_FILE"
  else echo "  ✗ $name"; echo "$p $((f+1))" > "$RESULTS_FILE"; fi
}
eq() { assert "$1 → 期望 $3，实际 $2" "$([[ "$2" == "$3" ]] && echo true || echo false)"; }

export AGENT_GATES_DIR="$(mktemp -d)"
source "$LIB"

echo "=== grok 作为审查候选 ==="
echo

echo "--- §1 厂商识别 ---"
eq "_extract_vendor github-copilot/grok-4.5" "$(_extract_vendor github-copilot/grok-4.5)" grok
eq "_extract_vendor github-copilot/grok-4.6" "$(_extract_vendor github-copilot/grok-4.6)" grok
# 裸型号也要认。family.sh 的注释里记着同一个教训：paseo 接 `--provider claude/opus`
# 会剥成 "opus"，漏掉裸形式就是一个改标签的洞。
eq "_extract_vendor grok-4.5（裸型号）" "$(_extract_vendor grok-4.5)" grok

echo
echo "--- §2 未知厂商不再互相顶掉 ---"
# filter_panel_pool 末尾 `awk '!seen[$2]++'` 按厂商去重。grok 归到 unknown 时，
# 它会和任何一个真正认不出的型号抢同一个格子 —— 谁先排到谁留下。
T2=$(filter_panel_pool claude github-copilot/gpt-5.6-sol \
  github-copilot/grok-4.5 vendorx/whatever-1 2>/dev/null)
assert "grok-4.5 在池中" "$([[ "$T2" == *grok-4.5* ]] && echo true || echo false)"
assert "另一个未知厂商也在池中（两者不再挤同一格）" \
  "$([[ "$T2" == *whatever-1* ]] && echo true || echo false)"

echo
echo "--- §3 merge_capability 不误拒 grok primary ---"
# platform 未知 → coding_vendor=unknown。grok 也判成 unknown 时，
# `pv == coding_vendor` 成立，本地配置被整份拒绝（exit 1），且调用方只看到"合并失败"。
D=$(mktemp -d)
# coding_vendor 在 review_models 里面，不在顶层 —— 第一版 fixture 放错了位置，
# 于是断言无条件通过，看起来像"这个 bug 不存在"。
printf '%s' '{"review_models":{"coding_vendor":"unknown","primary":"github-copilot/claude-sonnet-4.6","panel_pool":[],"panel_active":2,"panel_mode":"auto"}}' > "$D/review-capability.json"
printf '%s' '{"review_models":{"primary":"github-copilot/grok-4.5"}}' > "$D/review-capability.local.json"
T3=$(merge_capability "$D" 2>/dev/null); rc3=$?
assert "合并成功（实际 rc=${rc3}）" "$([[ $rc3 -eq 0 ]] && echo true || echo false)"
# 解析字段，不要 `== *grok-4.5*` 匹配整份 JSON —— 那样只要输出里任何位置留着这个字符串
# （比如 panel_pool 原样带过来）断言就绿，而 primary 合并失败也照样绿。
T3_PRIMARY=$(printf '%s' "$T3" | python3 -c "
import json,sys
try: print(json.load(sys.stdin)['review_models']['primary'])
except Exception: print('<解析失败>')
")
eq "review_models.primary" "$T3_PRIMARY" "github-copilot/grok-4.5"

echo
echo "--- §4 推荐数据 ---"
GROK_REC=$(python3 -c "
import json,sys
d=json.load(open(sys.argv[1]))
print('\n'.join(d.get('vendors',{}).get('grok',[])))
" "$REC" 2>/dev/null)
eq "vendors.grok" "$GROK_REC" "github-copilot/grok-4.5"

HAS_GEMINI=$(python3 -c "
import json,sys
d=json.load(open(sys.argv[1]))
print('yes' if 'gemini' in d.get('vendors',{}) else 'no')
" "$REC" 2>/dev/null)
eq "vendors 里不再有 gemini（型号已下架，剩下的全是 flash）" "$HAS_GEMINI" "no"

# ⚠️ 特征测试（characterization test）：断言的是**当前实际行为**，不是期望行为。
# `excluded_patterns` 在 lib/ 里零引用 —— flash 被剔靠 build_review_models / filter_panel_pool
# 里两句硬编码 `[[ "$name" == *flash* ]]`，而 `glm` 没有任何地方拦。所以配置里写了
# "glm" 也拦不住 glm 型号进池。
# 把这条钉成测试的目的：等有人真去实现 `excluded_patterns` 时，这条会**变红**，
# 提醒他同时把这里和文档改掉。⛔ 别把它当成"glm 应该能进池"。
BIN4=$(mktemp -d)
cat > "$BIN4/oc" <<'EOF'
#!/usr/bin/env bash
echo "github-copilot/gpt-5.5"
echo "bailian/glm-4.7"
EOF
chmod +x "$BIN4/oc"
REC4=$(mktemp)
printf '%s' '{"vendors":{"gpt":["github-copilot/gpt-5.5"],"glm":["bailian/glm-4.7"]},"excluded_patterns":["flash","glm"]}' > "$REC4"
T4=$(HETERO_PROBE_TIMEOUT=10 OC_REVIEW_OPENCODE="$BIN4/oc" build_review_models omc "$REC4" 2>/dev/null)
assert "glm 型号仍然进池 —— 证实 excluded_patterns 是死字段（不是期望行为）" \
  "$(python3 -c "
import json,sys
try: d=json.loads(sys.argv[1])
except Exception: print('false'); raise SystemExit
print('true' if any('glm' in m for m in d.get('panel_pool',[])) else 'false')
" "$T4")"

# 而 flash 的剔除是真的（硬编码那条）—— 两者对比才说明问题出在哪一层。
BIN4B=$(mktemp -d)
cat > "$BIN4B/oc" <<'EOF'
#!/usr/bin/env bash
echo "github-copilot/gpt-5.5"
echo "github-copilot/gemini-3.8-flash"
EOF
chmod +x "$BIN4B/oc"
REC4B=$(mktemp)
printf '%s' '{"vendors":{"gpt":["github-copilot/gpt-5.5"],"gemini":["github-copilot/gemini-3.8-flash"]},"excluded_patterns":[]}' > "$REC4B"
T4B=$(HETERO_PROBE_TIMEOUT=10 OC_REVIEW_OPENCODE="$BIN4B/oc" build_review_models omc "$REC4B" 2>/dev/null)
assert "excluded_patterns 为空也照样剔掉 flash —— 剔除来自硬编码" \
  "$(python3 -c "
import json,sys
try: d=json.loads(sys.argv[1])
except Exception: print('false'); raise SystemExit
print('true' if not any('flash' in m for m in d.get('panel_pool',[])) else 'false')
" "$T4B")"

echo
echo "--- §5 端到端：grok 必须真的进池 ---"
BIN=$(mktemp -d)
# 一个 fake opencode：既回答 detect_available_models 的列举，也让 _probe_model 通过。
cat > "$BIN/oc" <<'EOF'
#!/usr/bin/env bash
echo "github-copilot/gpt-5.5"
echo "github-copilot/grok-4.5"
echo "github-copilot/gemini-3.8-flash"
EOF
chmod +x "$BIN/oc"

T5=$(HETERO_PROBE_TIMEOUT=10 OC_REVIEW_OPENCODE="$BIN/oc" build_review_models omc "$REC" 2>/dev/null)
assert "panel_pool 含 grok-4.5" \
  "$(python3 -c "
import json,sys
try: d=json.loads(sys.argv[1])
except Exception: print('false'); raise SystemExit
print('true' if any('grok-4.5' in m for m in d.get('panel_pool',[])) else 'false')
" "$T5")"
assert "panel_pool 不含 flash 型号" \
  "$(python3 -c "
import json,sys
try: d=json.loads(sys.argv[1])
except Exception: print('false'); raise SystemExit
print('true' if not any('flash' in m for m in d.get('panel_pool',[])) else 'false')
" "$T5")"

echo
read -r P F < "$RESULTS_FILE"
echo "PASS=$P FAIL=$F"
rm -f "$RESULTS_FILE"
[[ "$F" -eq 0 ]] || exit 1
