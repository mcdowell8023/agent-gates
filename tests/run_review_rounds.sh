#!/usr/bin/env bash
# 审查轮数上限（v2.10.0）。
#
# 🔴 实况（2026-09-24）：一次合并 6 轮审查、4 个审查 agent，约 $32；规则早写了
# 「迭代期别审」，09-10 照样派出 11 个 agent —— 只写规则拦不住，要在产物登记处卡。
#
# 契约：
#   批次 = 目标分支 | 源分支 | 实例（merge-base(HEAD, MERGE_HEAD) 短 sha）
#   轮次 = 共享库里同批次产物按 REVIEW_DIFF_SHA256 去重的个数
#   超过 review.max_rounds（默认 2）⇒ exit 73；--escalated "<理由>" 放行并写进产物
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REVIEW="$SCRIPT_DIR/../bin/agent-gates-review"
RESULTS_FILE=$(mktemp); echo "0 0" > "$RESULTS_FILE"
assert() {
  local name="$1" cond="$2" p f
  read -r p f < "$RESULTS_FILE"
  if [[ "$cond" == "true" ]]; then echo "  ✓ $name"; echo "$((p+1)) $f" > "$RESULTS_FILE"
  else echo "  ✗ $name"; echo "$p $((f+1))" > "$RESULTS_FILE"; fi
}

# ⚠️ 子 shell 里的 cd 带不回来：mkrepo 只回显路径，调用方显式 cd。
mkrepo() {
  local d; d=$(mktemp -d); ( cd "$d"
  git init -q -b master .; git config user.email t@t; git config user.name t
  git config merge.ff false
  mkdir -p .agent/reviews
  printf '{"mode":"strict"}\n' > .agent/gates.json
  printf 'export const a = 1\n' > a.ts && printf 'test\n' > a.test.ts
  printf 'base\n' > other.txt
  git add . && git commit -q -m init
  git checkout -q -b feat
  printf 'export const b = 2\n' >> a.ts && git commit -q -am 'feat 1'
  git checkout -q -b feat2 master
  printf 'export const c = 3\n' > c.ts && printf 'test\n' > c.test.ts
  git add . && git commit -q -m 'feat2 1'
  git checkout -q master
  ) >/dev/null 2>&1
  echo "$d"
}
mkgd() {
  local d; d=$(mktemp -d); mkdir -p "$d/bin"
  printf '{"level":"L3","review_models":{"primary":"x/y","panel_pool":[],"panel_active":2,"panel_mode":"off"}}' > "$d/hetero-check.json"
  echo "$d"
}
stage_merge() { git merge -q --no-commit --no-ff "$1" >/dev/null 2>&1; }
abort_merge() { git merge --abort >/dev/null 2>&1; }
fix_on() {   # fix_on <branch> <line> —— 在功能分支上追加一条修复
  git checkout -q "$1" && printf '%s\n' "$2" >> a.ts && git commit -q -am "fix $2" && git checkout -q master
}
imp() {      # imp <result-file> [extra args...]
  local out="$1"; shift
  AGENT_GATES_DIR="$GD" bash "$REVIEW" --import-result "$BODY" \
    --imported-model "pi/github-copilot/gpt-5.5" --result "$out" "$@"
}
marker() { sed -n "s/^<!-- $1: \(.*\) -->\$/\1/p" "$2" | head -1; }

ORIG=$PWD
BODY=$(mktemp); printf '看过了。\n\nVERDICT: PASS\n' > "$BODY"

echo "=== ①② R1、R2 放行，产物带批次与轮次；同一 diff 重复登记不占新轮 ==="
R=$(mkrepo); GD=$(mkgd); cd "$R"
MB=$(git merge-base master feat | cut -c1-12)
stage_merge feat
out=$(imp .agent/reviews/r1.md 2>&1); rc=$?
assert "R1 退出码 0（实际 ${rc}）" "$([[ $rc -eq 0 ]] && echo true || echo false)"
assert "R1 产物带 REVIEW_BATCH = master|feat|<merge-base>" \
  "$([[ "$(marker REVIEW_BATCH .agent/reviews/r1.md)" == "master|feat|$MB" ]] && echo true || echo false)"
assert "R1 产物 REVIEW_ROUND = 1" "$([[ "$(marker REVIEW_ROUND .agent/reviews/r1.md)" == 1 ]] && echo true || echo false)"
out=$(imp .agent/reviews/r1b.md 2>&1); rc=$?
assert "同一 diff 再登记一次仍放行（实际 ${rc}）" "$([[ $rc -eq 0 ]] && echo true || echo false)"
assert "同一 diff 不占新轮：REVIEW_ROUND 仍为 1" "$([[ "$(marker REVIEW_ROUND .agent/reviews/r1b.md)" == 1 ]] && echo true || echo false)"
abort_merge; fix_on feat 'fix-1'; stage_merge feat
out=$(imp .agent/reviews/r2.md 2>&1); rc=$?
assert "R2（修复后 diff 变了）放行（实际 ${rc}）" "$([[ $rc -eq 0 ]] && echo true || echo false)"
assert "R2 产物 REVIEW_ROUND = 2" "$([[ "$(marker REVIEW_ROUND .agent/reviews/r2.md)" == 2 ]] && echo true || echo false)"
assert "R2 与 R1 同批次（功能分支前进不改 merge-base）" \
  "$([[ "$(marker REVIEW_BATCH .agent/reviews/r2.md)" == "master|feat|$MB" ]] && echo true || echo false)"

echo
echo "=== ③④⑤ R3 被拒（exit 73）；--escalated 放行并记理由；空理由拒绝 ==="
abort_merge; fix_on feat 'fix-2'; stage_merge feat
out=$(imp .agent/reviews/r3.md 2>&1); rc=$?
assert "⭐ R3 退出码 73（实际 ${rc}）" "$([[ $rc -eq 73 ]] && echo true || echo false)"
assert "R3 不写产物" "$([[ ! -e .agent/reviews/r3.md ]] && echo true || echo false)"
assert "报错指向不收敛诊断，而不是让人再审一轮" "$([[ "$out" == *诊断* ]] && echo true || echo false)"
assert "报错给出 --escalated 出路" "$([[ "$out" == *--escalated* ]] && echo true || echo false)"
out=$(imp .agent/reviews/r3.md --escalated "" 2>&1); rc=$?
assert "--escalated 空理由 exit 1（实际 ${rc}）" "$([[ $rc -eq 1 ]] && echo true || echo false)"
out=$(imp .agent/reviews/r3.md --escalated $'方向问题已回方案层\n重写 a.ts ---->> 见计划' 2>&1); rc=$?
assert "⭐ --escalated 带理由放行（实际 ${rc}）" "$([[ $rc -eq 0 ]] && echo true || echo false)"
assert "产物 REVIEW_ROUND = 3" "$([[ "$(marker REVIEW_ROUND .agent/reviews/r3.md)" == 3 ]] && echo true || echo false)"
esc=$(marker REVIEW_ESCALATED .agent/reviews/r3.md)
assert "产物记下理由（压成单行）" "$([[ "$esc" == *方向问题已回方案层*重写* ]] && echo true || echo false)"
assert "理由里的 --> 被去掉，不会提前闭合注释" "$([[ "$esc" != *'-->'* ]] && echo true || echo false)"
assert "放行时告警可见" "$([[ "$out" == *escalated* ]] && echo true || echo false)"

echo
echo "=== ⑥ 不同源分支独立计数 ==="
abort_merge; stage_merge feat2
out=$(imp .agent/reviews/f2.md 2>&1); rc=$?
assert "feat2 第一轮放行（实际 ${rc}）" "$([[ $rc -eq 0 ]] && echo true || echo false)"
assert "feat2 REVIEW_ROUND = 1" "$([[ "$(marker REVIEW_ROUND .agent/reviews/f2.md)" == 1 ]] && echo true || echo false)"
abort_merge
cd "$ORIG"

echo
echo "=== ⑦ max_rounds：0 不限、环境变量覆盖配置、非法值按 2 ==="
R=$(mkrepo); GD=$(mkgd); cd "$R"
printf '{"mode":"strict","review":{"max_rounds":0}}\n' > .agent/gates.json
stage_merge feat; imp .agent/reviews/a1.md >/dev/null 2>&1
for n in 1 2; do abort_merge; fix_on feat "z$n"; stage_merge feat; imp ".agent/reviews/a$((n+1)).md" >/dev/null 2>&1; done
abort_merge; fix_on feat z3; stage_merge feat
out=$(imp .agent/reviews/a4.md 2>&1); rc=$?
assert "max_rounds=0 ⇒ 第 4 轮照样放行（实际 ${rc}）" "$([[ $rc -eq 0 ]] && echo true || echo false)"
out=$(AGENT_GATES_REVIEW_MAX_ROUNDS=3 imp .agent/reviews/a5.md 2>&1); rc=$?
assert "当前 diff 已登记过 ⇒ 环境变量设 3 也不算新一轮（实际 ${rc}）" "$([[ $rc -eq 0 ]] && echo true || echo false)"
abort_merge; fix_on feat z4; stage_merge feat
out=$(AGENT_GATES_REVIEW_MAX_ROUNDS=3 imp .agent/reviews/a6.md 2>&1); rc=$?
assert "环境变量 3 覆盖配置 0 ⇒ 第 5 轮被拒（实际 ${rc}）" "$([[ $rc -eq 73 ]] && echo true || echo false)"
out=$(AGENT_GATES_REVIEW_MAX_ROUNDS=abc imp .agent/reviews/a6.md 2>&1); rc=$?
assert "非法值按 2 ⇒ 被拒（实际 ${rc}）" "$([[ $rc -eq 73 ]] && echo true || echo false)"
assert "非法值有告警" "$([[ "$out" == *abc* ]] && echo true || echo false)"
abort_merge
cd "$ORIG"

echo
echo "=== ⑧ --route paseo 在超限时被拒，且不签发 token ==="
R=$(mkrepo); GD=$(mkgd); cd "$R"
PROMPT=$(mktemp); printf 'review this\n' > "$PROMPT"
stage_merge feat; imp .agent/reviews/p1.md >/dev/null 2>&1
abort_merge; fix_on feat p; stage_merge feat; imp .agent/reviews/p2.md >/dev/null 2>&1
abort_merge; fix_on feat q; stage_merge feat
command -v node >/dev/null 2>&1 && _node=1 || _node=0
assert "前提：本机有 node（否则 exit 75 会冒充 73）" "$([[ $_node -eq 1 ]] && echo true || echo false)"
out=$(AGENT_GATES_DIR="$GD" bash "$REVIEW" "$PROMPT" --route paseo --dispatch-out "$R/req.json" 2>&1); rc=$?
assert "⭐ 派发被拒 exit 73（实际 ${rc}）" "$([[ $rc -eq 73 ]] && echo true || echo false)"
assert "没有签发 token（pending-reviews 为空）" \
  "$([[ -z "$(ls -A "$GD/pending-reviews" 2>/dev/null)" ]] && echo true || echo false)"
assert "没有写派发请求" "$([[ ! -e "$R/req.json" ]] && echo true || echo false)"

echo
echo "=== ⑭ 直跑（不走 paseo、不导入）超限同样 exit 73，不调用审查员 ==="
out=$(AGENT_GATES_DIR="$GD" bash "$REVIEW" "$PROMPT" --result "$R/direct.md" 2>&1); rc=$?
assert "⭐ 直跑被拒 exit 73（实际 ${rc}）" "$([[ $rc -eq 73 ]] && echo true || echo false)"
assert "没有写产物" "$([[ ! -e "$R/direct.md" ]] && echo true || echo false)"

echo
echo "=== ⑧b paseo 两阶段：派发时的 --escalated 带到导入，不必重给 ==="
out=$(AGENT_GATES_DIR="$GD" bash "$REVIEW" "$PROMPT" --route paseo --dispatch-out "$R/req2.json" \
        --escalated "诊断：方向问题已回方案层" 2>&1); rc=$?
assert "带理由的派发签发 token（exit 77，实际 ${rc}）" "$([[ $rc -eq 77 ]] && echo true || echo false)"
TOKEN=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["token"])' "$R/req2.json" 2>/dev/null)
out=$(AGENT_GATES_DIR="$GD" bash "$REVIEW" --import-result "$BODY" --token "$TOKEN" \
        --imported-model "pi/github-copilot/gpt-5.5" --result .agent/reviews/p3.md 2>&1); rc=$?
assert "⭐ 导入时不重给 --escalated 也放行（实际 ${rc}）" "$([[ $rc -eq 0 ]] && echo true || echo false)"
assert "产物记下派发时的理由" \
  "$([[ "$(marker REVIEW_ESCALATED .agent/reviews/p3.md)" == *方向问题已回方案层* ]] && echo true || echo false)"
assert "产物 REVIEW_ROUND = 3" "$([[ "$(marker REVIEW_ROUND .agent/reviews/p3.md)" == 3 ]] && echo true || echo false)"
abort_merge; fix_on feat r; stage_merge feat

echo
echo "=== ⑨ --due 追加 rounds 两行，退出码契约不变；--due 与 --escalated 互斥 ==="
out=$(AGENT_GATES_DIR="$GD" bash "$REVIEW" --due 2>/dev/null); rc=$?
assert "--due 退出码仍为 0（strict 档该审，实际 ${rc}）" "$([[ $rc -eq 0 ]] && echo true || echo false)"
assert "⭐ rounds_used=3（实际数字，不是空串）" "$([[ "$out" == *$'\nrounds_used=3'* ]] && echo true || echo false)"
assert "rounds_max=2" "$([[ "$out" == *$'\nrounds_max=2'* ]] && echo true || echo false)"
assert "原有 due= 行还在" "$([[ "$out" == due=yes* ]] && echo true || echo false)"
out=$(AGENT_GATES_DIR="$GD" bash "$REVIEW" --due --escalated "x" 2>&1); rc=$?
assert "--due --escalated exit 1（实际 ${rc}）" "$([[ $rc -eq 1 ]] && echo true || echo false)"
printf '{"mode":"strict","review":{"max_rounds":5}}\n' > .agent/gates.json
out=$(AGENT_GATES_DIR="$GD" bash "$REVIEW" --due 2>/dev/null)
assert "rounds_max 跟随配置 review.max_rounds=5" "$([[ "$out" == *$'\nrounds_max=5'* ]] && echo true || echo false)"
printf '{"mode":"strict","review":{"max_rounds":"lots"}}\n' > .agent/gates.json
err=$(AGENT_GATES_DIR="$GD" bash "$REVIEW" --due 2>&1 >/dev/null)
assert "--due 不吞非法 max_rounds 的告警" "$([[ "$err" == *lots* ]] && echo true || echo false)"
printf '{"mode":"strict"}\n' > .agent/gates.json
abort_merge
out=$(AGENT_GATES_DIR="$GD" bash "$REVIEW" --due 2>/dev/null); rc=$?
assert "没有暂存内容时 rounds_used 兜底为 0" "$([[ "$out" == *$'\nrounds_used=0'* ]] && echo true || echo false)"
cd "$ORIG"
NOREPO=$(mktemp -d)
out=$(cd "$NOREPO" && AGENT_GATES_DIR="$GD" bash "$REVIEW" --due 2>/dev/null)
assert "不在 git 仓库里 rounds_used 也是数字 0" "$([[ "$out" == *$'\nrounds_used=0'* ]] && echo true || echo false)"

echo
echo "=== ⑪ 同一对分支第一批合进去后，再合第二批从第 1 轮算 ==="
R=$(mkrepo); GD=$(mkgd); cd "$R"
stage_merge feat; imp .agent/reviews/b1.md >/dev/null 2>&1
abort_merge; fix_on feat b; stage_merge feat; imp .agent/reviews/b2.md >/dev/null 2>&1
git commit -q -m 'merge feat batch 1' >/dev/null 2>&1
fix_on feat 'batch-2'; stage_merge feat
out=$(imp .agent/reviews/b3.md 2>&1); rc=$?
assert "⭐ 第二批第一轮放行（实际 ${rc}）" "$([[ $rc -eq 0 ]] && echo true || echo false)"
assert "第二批 REVIEW_ROUND = 1" "$([[ "$(marker REVIEW_ROUND .agent/reviews/b3.md)" == 1 ]] && echo true || echo false)"
assert "第二批批次键换了实例" \
  "$([[ "$(marker REVIEW_BATCH .agent/reviews/b3.md)" != "$(marker REVIEW_BATCH .agent/reviews/b1.md)" ]] && echo true || echo false)"
abort_merge
cd "$ORIG"

echo
echo "=== ⑫ 同一批内 master 被别人前进：HEAD 变、merge-base 不变，仍计入同一批 ==="
R=$(mkrepo); GD=$(mkgd); cd "$R"
stage_merge feat; imp .agent/reviews/m1.md >/dev/null 2>&1
abort_merge
printf 'moved\n' >> other.txt && git commit -q -am 'someone else on master'
fix_on feat m; stage_merge feat
out=$(imp .agent/reviews/m2.md 2>&1); rc=$?
assert "放行（实际 ${rc}）" "$([[ $rc -eq 0 ]] && echo true || echo false)"
assert "同一批次键（且非空）" "$([[ -n "$(marker REVIEW_BATCH .agent/reviews/m1.md)" && "$(marker REVIEW_BATCH .agent/reviews/m2.md)" == "$(marker REVIEW_BATCH .agent/reviews/m1.md)" ]] && echo true || echo false)"
assert "REVIEW_ROUND = 2" "$([[ "$(marker REVIEW_ROUND .agent/reviews/m2.md)" == 2 ]] && echo true || echo false)"
abort_merge
cd "$ORIG"

echo
echo "=== ⑬ 不在 merge 中：源分支 = 目标分支，实例 = HEAD ==="
R=$(mkrepo); GD=$(mkgd); cd "$R"
printf 'export const d = 4\n' >> a.ts && git add a.ts
out=$(imp .agent/reviews/n1.md 2>&1); rc=$?
assert "放行（实际 ${rc}）" "$([[ $rc -eq 0 ]] && echo true || echo false)"
assert "REVIEW_BATCH = master|master|<HEAD>" \
  "$([[ "$(marker REVIEW_BATCH .agent/reviews/n1.md)" == "master|master|$(git rev-parse HEAD | cut -c1-12)" ]] && echo true || echo false)"
cd "$ORIG"

echo
read -r P F < "$RESULTS_FILE"; rm -f "$RESULTS_FILE"
echo "PASS=$P FAIL=$F"
[[ "$F" -eq 0 ]]
