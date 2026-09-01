#!/usr/bin/env bash
# Tests for agent-gates-plan-review — recording a plan review as a CHECK 3 artifact.
#
# THE GAP (found 2026-09-01 by running the gate on this repo's own commit): CHECK 3 blocks
# with `Fix: run agent-gates-review --plan <plan>` — and that flag does not exist anywhere
# in bin/ or lib/. Nothing writes PLAN_REVIEW / PLAN_REVIEW_TOOL / PLAN_REVIEW_MODEL either.
# So the only way to satisfy CHECK 3 was to hand-write the three markers, and the gate only
# greps for their presence — hand-writing IS passing. Same defect class as the dispatch→
# CHECK 6 break fixed in v2.6.0, and the same words apply: a gap that forces fabrication is
# a design defect, not a user error.
#
# Two further holes this closes, both of the "receipt exists, nobody read it" kind:
#   - markers survived a plan rewrite, so a review of last month's plan satisfied today's
#   - a plan review whose verdict was FAIL still passed, because only presence was checked
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PR="$SCRIPT_DIR/../bin/agent-gates-plan-review"
RESULTS_FILE=$(mktemp); echo "0 0" > "$RESULTS_FILE"

assert() {
  local name="$1" cond="$2" p f
  read -r p f < "$RESULTS_FILE"
  if [[ "$cond" == "true" ]]; then echo "  ✓ $name"; echo "$((p+1)) $f" > "$RESULTS_FILE"
  else echo "  ✗ $name"; echo "$p $((f+1))" > "$RESULTS_FILE"; fi
}
eq() { assert "$1 → $3 (实际 $2)" "$([[ "$2" == "$3" ]] && echo true || echo false)"; }
mk() { sed -n "s/^$2:[[:space:]]*//p" "$1" 2>/dev/null | head -1; }
# BRE `.*` is greedy, so it swallows the space before `-->` and the value comes back with
# a trailing blank. Trim rather than fight the regex.
mkc() { sed -n "s/^<!--[[:space:]]*$2:[[:space:]]*\(.*\)-->$/\1/p" "$1" 2>/dev/null | head -1 | sed 's/[[:space:]]*$//'; }

setup() {
  T=$(mktemp -d); cd "$T" || exit 1
  mkdir -p .agent/plans
  cat > .agent/plans/p.md <<'EOF'
# 导出功能

## 验收标准
- 用户可以搜索
- 用户可以导出
EOF
  cat > review.md <<'EOF'
计划整体成立，但 E3 只查文件存在会被指鹿为马打穿。

VERDICT: PASS
EOF
  export AGENT_GATES_DIR="$(mktemp -d)"
}
teardown() { cd /; rm -rf "${T:-}" "${AGENT_GATES_DIR:-}"; }

[[ -x "$PR" ]] || { echo "  ✗ bin/agent-gates-plan-review 不存在（未实现）"; echo "=== PASS=0 FAIL=1 ==="; exit 1; }

echo "=== agent-gates-plan-review tests ==="
echo

echo "PR1: 缺来源 → 拒绝（无来源的产物看着像证据，实际什么都没证明）"
( setup
  out=$(bash "$PR" .agent/plans/p.md --result review.md 2>&1); rc=$?
  assert "非零退出 (实际 $rc)" "$([[ $rc -ne 0 ]] && echo true || echo false)"
  assert "⛔ 未写入任何标记" "$(grep -q 'PLAN_REVIEW' .agent/plans/p.md && echo false || echo true)"
  teardown )

echo "PR2: ⛔ 审查正文没有结论行 → 拒绝，不代填"
( setup
  printf '看着还行。\n' > review.md
  out=$(bash "$PR" .agent/plans/p.md --result review.md --model github-copilot/gpt-5.4 2>&1); rc=$?
  eq "exit 3 拒绝" "$rc" 3
  assert "⛔ 未写入任何标记" "$(grep -q 'PLAN_REVIEW' .agent/plans/p.md && echo false || echo true)"
  assert "提示要 VERDICT 行" "$([[ "$out" == *VERDICT* ]] && echo true || echo false)"
  teardown )

echo "PR3: 正常路径 → 写入四个标记"
( setup
  out=$(bash "$PR" .agent/plans/p.md --result review.md --model github-copilot/gpt-5.4 2>&1); rc=$?
  eq "exit 0" "$rc" 0
  P=.agent/plans/p.md
  assert "PLAN_REVIEW 存在" "$(grep -q 'PLAN_REVIEW:' "$P" && echo true || echo false)"
  assert "PLAN_REVIEW_TOOL 存在" "$(grep -q 'PLAN_REVIEW_TOOL:' "$P" && echo true || echo false)"
  assert "PLAN_REVIEW_MODEL 存在" "$(grep -q 'PLAN_REVIEW_MODEL:' "$P" && echo true || echo false)"
  assert "PLAN_REVIEW_SHA256 存在" "$(grep -qE 'PLAN_REVIEW_SHA256: [0-9a-f]{64}' "$P" && echo true || echo false)"
  assert "PLAN_REVIEW_VERDICT 存在" "$(grep -q 'PLAN_REVIEW_VERDICT:' "$P" && echo true || echo false)"
  assert "记下模型" "$(grep -q 'gpt-5.4' "$P" && echo true || echo false)"
  assert "⭐ 逐字记下审查者的结论行以便核对" "$(grep -qF 'VERDICT: PASS' "$P" && echo true || echo false)"
  teardown )

echo "PR4: ⭐ 结论是 FAIL 就记 FAIL，不洗成通过"
( setup
  printf '这个方案前提就不成立。\n\nVERDICT: FAIL\n' > review.md
  bash "$PR" .agent/plans/p.md --result review.md --model github-copilot/gpt-5.4 >/dev/null 2>&1
  eq "PLAN_REVIEW_VERDICT" "$(mkc .agent/plans/p.md PLAN_REVIEW_VERDICT)" FAIL
  teardown )

echo "PR5: 重复运行是幂等的，不叠加重复标记"
( setup
  bash "$PR" .agent/plans/p.md --result review.md --model github-copilot/gpt-5.4 >/dev/null 2>&1
  bash "$PR" .agent/plans/p.md --result review.md --model github-copilot/gpt-5.4 >/dev/null 2>&1
  eq "PLAN_REVIEW 行只有一条" "$(grep -c 'PLAN_REVIEW:' .agent/plans/p.md | tr -d ' ')" 1
  eq "SHA256 行只有一条" "$(grep -c 'PLAN_REVIEW_SHA256:' .agent/plans/p.md | tr -d ' ')" 1
  teardown )

echo "PR6: ⭐ 哈希排除标记自身 —— 否则写入标记就把自己的锚点作废了"
( setup
  bash "$PR" .agent/plans/p.md --result review.md --model github-copilot/gpt-5.4 >/dev/null 2>&1
  H1=$(mkc .agent/plans/p.md PLAN_REVIEW_SHA256)
  bash "$PR" .agent/plans/p.md --result review.md --model github-copilot/gpt-5.4 >/dev/null 2>&1
  H2=$(mkc .agent/plans/p.md PLAN_REVIEW_SHA256)
  assert "两次哈希一致（标记不进哈希）" "$([[ -n "$H1" && "$H1" == "$H2" ]] && echo true || echo false)"
  teardown )

echo "PR7: ⭐ 计划正文改了 → 哈希变化（旧审查不该继续算数）"
( setup
  bash "$PR" .agent/plans/p.md --result review.md --model github-copilot/gpt-5.4 >/dev/null 2>&1
  H1=$(mkc .agent/plans/p.md PLAN_REVIEW_SHA256)
  printf '\n## 新增一节\n- 又加了个需求\n' >> .agent/plans/p.md
  # 用同一份计划重算（不重新写标记）
  H2=$(bash "$PR" .agent/plans/p.md --print-hash 2>/dev/null)
  assert "哈希不同" "$([[ -n "$H2" && "$H1" != "$H2" ]] && echo true || echo false)"
  teardown )

echo "PR8: ⭐ 异构判定 —— 同族模型记 L0，异族记 L1"
( setup
  printf '{"implementer_family":"anthropic"}\n' > "$AGENT_GATES_DIR/hetero-check.json"
  bash "$PR" .agent/plans/p.md --result review.md --model github-copilot/claude-opus-5 >/dev/null 2>&1
  eq "同族(anthropic 审 anthropic) → L0" "$(mkc .agent/plans/p.md PLAN_REVIEW)" L0
  teardown )
( setup
  printf '{"implementer_family":"anthropic"}\n' > "$AGENT_GATES_DIR/hetero-check.json"
  bash "$PR" .agent/plans/p.md --result review.md --model github-copilot/gpt-5.4 >/dev/null 2>&1
  eq "异族(openai 审 anthropic) → L1" "$(mkc .agent/plans/p.md PLAN_REVIEW)" L1
  teardown )

echo "PR9: 计划文件不存在 → 拒绝"
( setup
  out=$(bash "$PR" .agent/plans/ghost.md --result review.md --model github-copilot/gpt-5.4 2>&1); rc=$?
  assert "非零退出 (实际 $rc)" "$([[ $rc -ne 0 ]] && echo true || echo false)"
  teardown )

echo "PR10: 审查正文文件不存在 → 拒绝，且不动计划"
( setup
  out=$(bash "$PR" .agent/plans/p.md --result ghost.md --model github-copilot/gpt-5.4 2>&1); rc=$?
  assert "非零退出 (实际 $rc)" "$([[ $rc -ne 0 ]] && echo true || echo false)"
  assert "计划未被改动" "$(grep -q 'PLAN_REVIEW' .agent/plans/p.md && echo false || echo true)"
  teardown )

echo "PR11: 未知族的模型 → fail-closed 记 L0（不能因为不认识就当异构）"
( setup
  printf '{"implementer_family":"anthropic"}\n' > "$AGENT_GATES_DIR/hetero-check.json"
  bash "$PR" .agent/plans/p.md --result review.md --model somevendor/unknown-model-9 >/dev/null 2>&1
  eq "未知族 → L0" "$(mkc .agent/plans/p.md PLAN_REVIEW)" L0
  teardown )

# --- 交叉审查(gpt-5.4)抓到的假失败源：我重新发明了解析器 ---
# lib/hetero/conclusion.sh 早就有规范实现，容忍 markdown 装饰与全角冒号、且用完整取值表
# 拒绝带限定的结论。自己写一个只认裸 ASCII 的版本，会把协议明确允许的正常输出全部误拒 ——
# 而 v2.0.2 那次同样的形状被报成「所有审查模型都失败」，把排查方向指向了传输层，花掉一整天。
echo "PR12: 协议允许的装饰形式必须接受"
for LINE in '**VERDICT: PASS**' '## VERDICT: PASS' '> VERDICT: PASS' '`VERDICT: PASS`' '- VERDICT: PASS'; do
  ( setup
    printf '审过了。\n\n%s\n' "$LINE" > review.md
    bash "$PR" .agent/plans/p.md --result review.md --model github-copilot/gpt-5.4 >/dev/null 2>&1
    eq "接受 $LINE" "$(mkc .agent/plans/p.md PLAN_REVIEW_VERDICT)" PASS
    teardown )
done

echo "PR13: 全角冒号（中文语境常见）必须接受"
( setup
  printf '审过了。\n\nVERDICT：PASS\n' > review.md
  bash "$PR" .agent/plans/p.md --result review.md --model github-copilot/gpt-5.4 >/dev/null 2>&1
  eq "接受全角冒号" "$(mkc .agent/plans/p.md PLAN_REVIEW_VERDICT)" PASS
  teardown )

echo "PR14: 审查侧词表（ISSUES / REVISE）要能映射，不能当成不认识"
( setup
  printf '有几个问题。\n\nVERDICT: ISSUES\n' > review.md
  bash "$PR" .agent/plans/p.md --result review.md --model github-copilot/gpt-5.4 >/dev/null 2>&1
  V="$(mkc .agent/plans/p.md PLAN_REVIEW_VERDICT)"
  assert "ISSUES 被接受且不是 PASS (实际 $V)" "$([[ -n "$V" && "$V" != "PASS" ]] && echo true || echo false)"
  teardown )

echo "PR15: ⛔ 带限定的结论不能被读成 PASS"
( setup
  printf '还行但有问题。\n\nVERDICT: PASS_WITH_ISSUES\n' > review.md
  bash "$PR" .agent/plans/p.md --result review.md --model github-copilot/gpt-5.4 >/dev/null 2>&1
  V="$(mkc .agent/plans/p.md PLAN_REVIEW_VERDICT)"
  assert "不得记成 PASS (实际 '${V:-<未写入>}')" "$([[ "$V" != "PASS" ]] && echo true || echo false)"
  teardown )

echo
read -r P F < "$RESULTS_FILE"
echo "=== PASS=$P FAIL=$F ==="
rm -f "$RESULTS_FILE"
[[ "$F" -eq 0 ]]
