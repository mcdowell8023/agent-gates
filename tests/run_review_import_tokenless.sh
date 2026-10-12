#!/usr/bin/env bash
# 免 token 登记「自己已经跑完的审查」。
#
# 卡人的实况（2026-09-10，wb 一条长会话）：它自己用 pi -p 跑了七轮审查，结论都在手上，
# 但 `--import-result` 强制要 `--token`，而 token 只能由**派发**签发 ⇒ 已经审完的东西
# 拿不到 token ⇒ 那条线判断「凑不出官方产物」，直接停在原地不合 master。
#
# ⭐ 而做同一件事的 `agent-gates-verify-import` **不要 token、锚点当场算** ——
# 同一个仓库里两种形状，后者才是对的。token 唯一证明的是「审查发生在派发之后」，
# 而锚点证明的是「审的就是这份代码」。后者才有价值，且当场算一点不削弱。
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REVIEW="$SCRIPT_DIR/../bin/agent-gates-review"
GATE="$SCRIPT_DIR/../hooks/git/agent-quality-gate.sh"
RESULTS_FILE=$(mktemp); echo "0 0" > "$RESULTS_FILE"
assert() {
  local name="$1" cond="$2" p f
  read -r p f < "$RESULTS_FILE"
  if [[ "$cond" == "true" ]]; then echo "  ✓ $name"; echo "$((p+1)) $f" > "$RESULTS_FILE"
  else echo "  ✗ $name"; echo "$p $((f+1))" > "$RESULTS_FILE"; fi
}

# ⚠️ `$(mkrepo)` 是子 shell —— 里面的 `cd` 不会带到调用方。第一版就是这么错的：
# 后面所有 git 命令都跑在测试自己的 cwd 上（症状是 `pathspec 'src.ts' did not match`）。
# 这里只建目录并回显路径，由调用方显式 cd。
mkrepo() {
  local d; d=$(mktemp -d); ( cd "$d"
  git init -q .; git config user.email t@t; git config user.name t
  mkdir -p .agent/reviews .agent/plans
  printf '{"mode":"strict"}\n' > .agent/gates.json
  printf 'export const a = 1\n' > src.ts && printf 'test\n' > src.test.ts
  git add . && git commit -q -m init
  printf 'export const b = 2\n' >> src.ts && git add src.ts
  ) >/dev/null 2>&1
  echo "$d"
}
mkgd() {
  local d; d=$(mktemp -d); mkdir -p "$d/bin"
  printf '{"level":"L3","review_models":{"primary":"x/y","panel_pool":[],"panel_active":2,"panel_mode":"off"}}' > "$d/hetero-check.json"
  echo "$d"
}

echo "=== 免 token 登记已完成的审查 ==="
echo
R=$(mkrepo); GD=$(mkgd)
ORIG=$PWD
cd "$R"   # ⚠️ 必须显式 cd：mkrepo 的 cd 死在子 shell 里
BODY=$(mktemp)
printf '看过了，没问题。\n\nVERDICT: PASS\n' > "$BODY"

echo "--- ① 不给 token 也能登记 ---"
out=$(AGENT_GATES_DIR="$GD" bash "$REVIEW" --import-result "$BODY" \
        --imported-model "pi/github-copilot/grok-4.5" \
        --result .agent/reviews/r.md 2>&1); rc=$?
assert "⭐ 退出码 0（实际 ${rc}）" "$([[ $rc -eq 0 ]] && echo true || echo false)"
assert "⭐ 产物写出来了" "$([[ -s .agent/reviews/r.md ]] && echo true || echo false)"
assert "标记 REVIEW_TOOL: external" \
  "$(grep -q 'REVIEW_TOOL: external' .agent/reviews/r.md 2>/dev/null && echo true || echo false)"
assert "标记模型为 unverified（没派发过，无从核实）" \
  "$(grep -q 'grok-4.5 (unverified)' .agent/reviews/r.md 2>/dev/null && echo true || echo false)"

echo
echo "--- ② 锚点是当场算的，且真能过 CHECK 5 ---"
assert "有 REVIEW_HEAD" "$(grep -q 'REVIEW_HEAD:' .agent/reviews/r.md && echo true || echo false)"
assert "REVIEW_HEAD == 当前 HEAD" \
  "$(grep -q "REVIEW_HEAD: $(git rev-parse HEAD)" .agent/reviews/r.md && echo true || echo false)"
assert "有 REVIEW_FILE 覆盖 staged 文件" \
  "$(grep -q 'REVIEW_FILE: src.ts' .agent/reviews/r.md && echo true || echo false)"
gout=$(AGENT_MODE=1 AGENT_GATES_DIR="$GD" bash "$GATE" 2>&1 || true)
assert "⭐⭐ 门禁 CHECK 5 认这份产物（不再报『没有锚定的审查证据』）" \
  "$([[ "$gout" != *"No content-anchored review evidence"* ]] && echo true || echo false)"

echo
echo "--- ③ 必须自报型号，⛔ 不许匿名 ---"
out=$(AGENT_GATES_DIR="$GD" bash "$REVIEW" --import-result "$BODY" --result /dev/null 2>&1); rc=$?
assert "不给 --imported-model 就拒绝（实际 ${rc}）" "$([[ $rc -ne 0 ]] && echo true || echo false)"
assert "报错说明要什么" "$([[ "$out" == *imported-model* ]] && echo true || echo false)"

echo
echo "--- ④ 免 token 模式下 ⛔ 不接受 --paseo-agent ---"
# 没有派发记录就没有 created_at，⇒ 无从证明那个 agent 后于派发创建
# （旧 agent 顶账正是 --paseo-agent 那条路要防的）⇒ fail-closed，别给假的"已核实"。
out=$(AGENT_GATES_DIR="$GD" bash "$REVIEW" --import-result "$BODY" \
        --paseo-agent 00000000-0000-0000-0000-000000000000 --result /dev/null 2>&1); rc=$?
assert "⭐ 拒绝（实际 ${rc}）" "$([[ $rc -ne 0 ]] && echo true || echo false)"
assert "报错点明为什么（无派发记录 ⇒ 无法核实 agent）" \
  "$([[ "$out" == *token* || "$out" == *created* || "$out" == *核实* ]] && echo true || echo false)"

echo
echo "--- ⑤ 没有结论行 / 没有 staged 变更 都要拒 ---"
BAD=$(mktemp); printf '我觉得还行吧\n' > "$BAD"
out=$(AGENT_GATES_DIR="$GD" bash "$REVIEW" --import-result "$BAD" \
        --imported-model "pi/x/y" --result /dev/null 2>&1); rc=$?
assert "无 VERDICT 行 → 拒（实际 ${rc}）" "$([[ $rc -ne 0 ]] && echo true || echo false)"
git reset -q HEAD -- src.ts
out=$(AGENT_GATES_DIR="$GD" bash "$REVIEW" --import-result "$BODY" \
        --imported-model "pi/x/y" --result /dev/null 2>&1); rc=$?
assert "⭐ 无 staged 变更 → 拒（没东西可锚定，实际 ${rc}）" "$([[ $rc -ne 0 ]] && echo true || echo false)"

echo
echo "--- ⑥ 带 token 的老路子不能坏（回归）---"
git add src.ts
PMT=$(mktemp); echo "审一下" > "$PMT"; DO=$(mktemp)
AGENT_GATES_DIR="$GD" bash "$REVIEW" "$PMT" --route paseo --dispatch-out "$DO" >/dev/null 2>&1
TOK=$(python3 -c "import json;print(json.load(open('$DO'))['token'])" 2>/dev/null)
assert "阶段1 仍签发 token" "$([[ -n "$TOK" ]] && echo true || echo false)"
out=$(AGENT_GATES_DIR="$GD" bash "$REVIEW" --import-result "$BODY" --token "$TOK" \
        --imported-model "pi/x/y" --result .agent/reviews/r2.md 2>&1); rc=$?
assert "⭐ 带 token 导入仍然可用（实际 ${rc}）" "$([[ $rc -eq 0 ]] && echo true || echo false)"

cd "$ORIG"
echo
read -r P F < "$RESULTS_FILE"
echo "PASS=$P FAIL=$F"
rm -f "$RESULTS_FILE"
[[ "$F" -eq 0 ]] || exit 1
