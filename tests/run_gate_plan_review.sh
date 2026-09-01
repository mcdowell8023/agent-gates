#!/usr/bin/env bash
# Tests for CHECK 3 actually reading the plan-review markers it demands.
#
# Before this, CHECK 3 grepped only for the PRESENCE of PLAN_REVIEW / _TOOL / _MODEL. Three
# consequences, all of the "receipt exists, nobody read it" kind:
#   - hand-writing three comment lines was indistinguishable from a real review, and the
#     命令 the gate told you to run (`agent-gates-review --plan`) did not exist at all
#   - markers survived a plan rewrite, so a review of last month's plan satisfied today's
#   - a plan review whose verdict was FAIL still passed
#
# Backward compatibility is mandatory: existing plans carry the three markers with no hash
# and no verdict, and tests/run_gate.sh encodes that they pass. Legacy markers therefore
# warn, they do not block — otherwise this change breaks every deployed repo at once.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GATE="$SCRIPT_DIR/../hooks/git/agent-quality-gate.sh"
PR="$SCRIPT_DIR/../bin/agent-gates-plan-review"
RESULTS_FILE=$(mktemp); echo "0 0" > "$RESULTS_FILE"

assert() {
  local name="$1" cond="$2" p f
  read -r p f < "$RESULTS_FILE"
  if [[ "$cond" == "true" ]]; then echo "  ✓ $name"; echo "$((p+1)) $f" > "$RESULTS_FILE"
  else echo "  ✗ $name"; echo "$p $((f+1))" > "$RESULTS_FILE"; fi
}

setup() {
  REPO=$(mktemp -d); cd "$REPO" || exit 1
  git init -q; git config user.email t@t.com; git config user.name T
  mkdir -p src .agent/plans .agent/reviews .agent/verify
  echo init > src/a.ts; git add -A; git commit -q -m init
  git checkout -q -b feat/work
  export AGENT_MODE=1
  # big enough that CHECK 3 triggers (MAX_SINGLE_FILE_LINES > 150)
  { echo "export const f = () => {"; for i in $(seq 1 158); do echo "  // l $i"; done; echo "}"; } > src/big.ts
  echo "test('f',()=>{})" > src/big.test.ts
  git add src/big.ts src/big.test.ts
  AGENT_GATES_DIR=$(mktemp -d); export AGENT_GATES_DIR
  printf '{ "level": "L3" }\n' > "$AGENT_GATES_DIR/review-capability.json"
  printf '{"implementer_family":"anthropic","level":"L3"}\n' > "$AGENT_GATES_DIR/hetero-check.json"
  cat > .agent/plans/p.md <<'EOF'
# 大改动

## 验收标准
- 用户可以用 f
EOF
  cat > review.md <<'EOF'
方案成立。

VERDICT: PASS
EOF
}
teardown() { cd /; rm -rf "${REPO:-}" "${AGENT_GATES_DIR:-}"; }
# SKIP_REVIEW/SKIP_VERIFY keep CHECK 5/6 out of the way — this file is about CHECK 3 only.
run_gate() { SKIP_VERIFY=1 bash "$GATE" 2>&1; }
c3() { printf '%s\n' "$1" | grep -iE 'CHECK 3|PLAN_REVIEW|plan' || true; }

echo "=== CHECK 3 plan-review verification ==="
echo

echo "C0: 前置——确认 CHECK 3 真的被触发（否则后面断言全无意义）"
( setup; rm -f .agent/plans/p.md
  out=$(run_gate)
  assert "无计划时 CHECK 3 拦住" "$([[ "$out" == *"no plan or approved skip"* ]] && echo true || echo false)"
  teardown )

echo "C1: ⭐ 工具生成的标记 + 结论 PASS → 通过"
( setup
  bash "$PR" .agent/plans/p.md --result review.md --model github-copilot/gpt-5.4 >/dev/null 2>&1
  out=$(run_gate)
  assert "CHECK 3 不再报缺标记" "$([[ "$out" != *"missing PLAN_REVIEW markers"* ]] && echo true || echo false)"
  assert "CHECK 3 不报锚点失配" "$([[ "$out" != *"计划在审查之后被改过"* ]] && echo true || echo false)"
  teardown )

echo "C2: ⭐ 记录之后改计划正文 → 锚点失配被抓住"
( setup
  bash "$PR" .agent/plans/p.md --result review.md --model github-copilot/gpt-5.4 >/dev/null 2>&1
  printf '\n## 又加一条\n- 新需求，没人审过\n' >> .agent/plans/p.md
  out=$(run_gate); rc=$?
  assert "拦住 (rc=$rc)" "$([[ $rc -ne 0 ]] && echo true || echo false)"
  assert "点明计划被改过" "$([[ "$out" == *"计划在审查之后被改过"* ]] && echo true || echo false)"
  teardown )

echo "C3: ⭐ 计划审查结论是 FAIL → 拦住（原先只看标记存不存在）"
( setup
  printf '前提就不成立。\n\nVERDICT: FAIL\n' > review.md
  bash "$PR" .agent/plans/p.md --result review.md --model github-copilot/gpt-5.4 >/dev/null 2>&1
  out=$(run_gate); rc=$?
  assert "拦住 (rc=$rc)" "$([[ $rc -ne 0 ]] && echo true || echo false)"
  # `*FAIL*` matched the gate's own "Agent Quality Gate FAILED" footer — vacuous.
  assert "点明审查结论不是 PASS" "$([[ "$out" == *"计划审查的结论是 FAIL"* ]] && echo true || echo false)"
  teardown )

echo "C4: ⭐ L3 机器上的同族(L0)计划审查 → 拦住（自审不算审）"
( setup
  bash "$PR" .agent/plans/p.md --result review.md --model github-copilot/claude-opus-5 >/dev/null 2>&1
  out=$(run_gate); rc=$?
  assert "拦住 (rc=$rc)" "$([[ $rc -ne 0 ]] && echo true || echo false)"
  assert "点明是同族审查" "$([[ "$out" == *L0* ]] && echo true || echo false)"
  teardown )

echo "C5: ⛔ 向后兼容——旧标记（无哈希无结论）仍然通过，只告警"
( setup
  cat > .agent/plans/p.md <<'EOF'
# 大改动
<!-- PLAN_REVIEW: L1 -->
<!-- PLAN_REVIEW_TOOL: codex -->
<!-- PLAN_REVIEW_MODEL: gpt-5 -->
EOF
  out=$(run_gate)
  assert "CHECK 3 不拦" "$([[ "$out" != *"missing PLAN_REVIEW markers"* && "$out" != *"计划在审查之后被改过"* ]] && echo true || echo false)"
  assert "但要告警说锚点缺失" "$([[ "$out" == *"无锚点"* || "$out" == *"PLAN_REVIEW_SHA256"* ]] && echo true || echo false)"
  teardown )

echo "C6: 修复提示必须指向真实存在的命令"
( setup; rm -f .agent/plans/p.md
  out=$(run_gate)
  # `agent-gates-review --plan` 这个 flag 从来不存在，提示它等于把人指向一条死路
  assert "⛔ 不再提示不存在的 --plan flag" "$([[ "$out" != *"agent-gates-review --plan"* ]] && echo true || echo false)"
  teardown )

echo "C7: 有计划但完全没标记 → 仍按原逻辑拦（L3 机器）"
( setup
  out=$(run_gate); rc=$?
  assert "拦住 (rc=$rc)" "$([[ $rc -ne 0 ]] && echo true || echo false)"
  assert "提示用 agent-gates-plan-review" "$([[ "$out" == *"agent-gates-plan-review"* ]] && echo true || echo false)"
  teardown )

# --- 交叉审查(gpt-5.4)抓到的两条假失败源 ---
echo "C8: ⭐ 多个计划共存时，先扫到的坏计划不能掩盖有效计划"
( setup
  # 一个旧计划：审过但之后被改过（锚点失配）
  cat > .agent/plans/a-old.md <<'EOF'
# 上个月的计划
## 验收标准
- 老需求
EOF
  bash "$PR" .agent/plans/a-old.md --result review.md --model github-copilot/gpt-5.4 >/dev/null 2>&1
  printf '\n改了一笔，锚点作废\n' >> .agent/plans/a-old.md
  # 当前计划：审过且有效
  bash "$PR" .agent/plans/p.md --result review.md --model github-copilot/gpt-5.4 >/dev/null 2>&1
  out=$(run_gate); rc=$?
  # find 的返回顺序里 a-old.md 在 p.md 之前；原实现 break 在第一个命中就停，
  # 于是有效计划根本没机会被看到 —— 一个纯粹的假失败。
  # 断言落在 CHECK 3 上：整体 rc 会被 CHECK 5（本文件不涉及，且无跳过开关）带偏。
  assert "CHECK 3 不报锚点失配" "$([[ "$out" != *"计划在审查之后被改过"* ]] && echo true || echo false)"
  assert "CHECK 3 不报缺标记" "$([[ "$out" != *"missing PLAN_REVIEW markers"* ]] && echo true || echo false)"
  teardown )

echo "C9: 所有计划都不成立 → 仍然拦"
( setup
  printf '不行。\n\nVERDICT: FAIL\n' > review.md
  bash "$PR" .agent/plans/p.md --result review.md --model github-copilot/gpt-5.4 >/dev/null 2>&1
  out=$(run_gate); rc=$?
  # rc 非零会被 CHECK 5 顶起来，所以断言 CHECK 3 自己的话
  assert "CHECK 3 点明结论非 PASS" "$([[ "$out" == *"计划审查的结论是 FAIL"* ]] && echo true || echo false)"
  teardown )

echo "C10: dangerous 判定不能误伤 author.ts / oauth.ts 这类普通命名"
( setup
  git reset -q
  { echo "export const author = 1"; for i in $(seq 1 158); do echo "  // l $i"; done; } > src/author.ts
  echo "test('a',()=>{})" > src/author.test.ts
  git add src/author.ts src/author.test.ts
  bash bin/../bin/agent-gates-plan-decision skip --reason "trivial 重命名" --topic rename >/dev/null 2>&1 \
    || bash "$SCRIPT_DIR/../bin/agent-gates-plan-decision" skip --reason "trivial 重命名" --topic rename >/dev/null 2>&1
  rm -f .agent/plans/p.md
  out=$(run_gate); rc=$?
  # `auth` 作为子串匹配会把 author.ts 判成危险路径，于是明明有批准的 skip 也被拒
  assert "不把 author.ts 判成危险路径 (rc=$rc)" "$([[ "$out" != *"Dangerous change"* ]] && echo true || echo false)"
  teardown )

echo "C11: 真正的 auth 路径仍然要被判危险"
( setup
  git reset -q
  mkdir -p src/auth
  { echo "export const login = 1"; for i in $(seq 1 158); do echo "  // l $i"; done; } > src/auth/login.ts
  echo "test('l',()=>{})" > src/auth/login.test.ts
  git add src/auth/login.ts src/auth/login.test.ts
  bash "$SCRIPT_DIR/../bin/agent-gates-plan-decision" skip --reason "x" --topic skipme >/dev/null 2>&1
  rm -f .agent/plans/p.md
  out=$(run_gate)
  assert "src/auth/ 仍判为危险，skip 不被接受" "$([[ "$out" == *"Dangerous change"* ]] && echo true || echo false)"
  teardown )

echo
read -r P F < "$RESULTS_FILE"
echo "=== PASS=$P FAIL=$F ==="
rm -f "$RESULTS_FILE"
[[ "$F" -eq 0 ]]
