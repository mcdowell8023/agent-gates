#!/usr/bin/env bash
# SKIP_REVIEW=1 ——「异构 > 同构 > 不查」的最后一档（v2.10.0）。
#
# 🔴 背景：skill §1 与 README 一直写着 `SKIP_REVIEW=1 git commit ...` 可以跳过 CHECK 5，
# 但 hook 从没读过这个变量 —— 文档承诺的出口实际不存在，同构也跑不了时只能卡死。
# 契约：
#   · 需要审查、没有产物 ⇒ 照旧阻断
#   · SKIP_REVIEW=1 ⇒ 跳过 CHECK 5，⛔ 但要醒目打印，不静默
#   · 只管 CHECK 5：CHECK 6（verify）照旧要产物，它有自己的 SKIP_VERIFY
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GATE="$SCRIPT_DIR/../hooks/git/agent-quality-gate.sh"
RESULTS_FILE=$(mktemp); echo "0 0" > "$RESULTS_FILE"
assert() {
  local name="$1" cond="$2" p f
  read -r p f < "$RESULTS_FILE"
  if [[ "$cond" == "true" ]]; then echo "  ✓ $name"; echo "$((p+1)) $f" > "$RESULTS_FILE"
  else echo "  ✗ $name"; echo "$p $((f+1))" > "$RESULTS_FILE"; fi
}

# ⚠️ 子 shell 里的 cd 带不回来：只回显路径，调用方显式 cd。
mkrepo() {   # mkrepo <gates-json> —— 暂存一笔超过审查阈值的改动（两个逻辑文件、>50 行）
  local d i n; d=$(mktemp -d); ( cd "$d"
  git init -q -b feat .; git config user.email t@t; git config user.name t
  mkdir -p .agent/reviews .agent/verify
  printf '%s\n' "$1" > .agent/gates.json
  printf 'x\n' > README.md; git add . && git commit -q -m init
  for i in 1 2; do
    printf 'export const f%s = () => {\n' "$i" > "mod$i.ts"
    for n in $(seq 1 30); do echo "  // line $n" >> "mod$i.ts"; done
    echo "}" >> "mod$i.ts"
    echo "test('f$i', () => {})" > "mod$i.test.ts"
  done
  git add mod1.ts mod2.ts mod1.test.ts mod2.test.ts
  ) >/dev/null 2>&1
  echo "$d"
}
GD=$(mktemp -d); printf '{"level":"L1"}\n' > "$GD/review-capability.json"
gate() { AGENT_MODE=1 AGENT_GATES_DIR="$GD" SKIP_PLAN_CHECK=1 bash "$GATE" 2>&1; }
ORIG=$PWD

echo "=== ① 需要审查、没有产物 ⇒ 照旧阻断 ==="
R=$(mkrepo '{"mode":"strict","verify":{"mode":"off"}}'); cd "$R"
out=$(gate); rc=$?
assert "阻断（实际 ${rc}）" "$([[ $rc -ne 0 ]] && echo true || echo false)"
assert "报的是缺审查证据" "$([[ "$out" == *"No content-anchored review evidence"* ]] && echo true || echo false)"
cd "$ORIG"

echo
echo "=== ② SKIP_REVIEW=1 ⇒ 跳过 CHECK 5 并醒目打印 ==="
R=$(mkrepo '{"mode":"strict","verify":{"mode":"off"}}'); cd "$R"
out=$(SKIP_REVIEW=1 gate); rc=$?
assert "⭐ 放行（实际 ${rc}）" "$([[ $rc -eq 0 ]] && echo true || echo false)"
assert "不再报缺审查证据" "$([[ "$out" != *"No content-anchored review evidence"* ]] && echo true || echo false)"
assert "⭐ 打印出是 SKIP_REVIEW 跳过的（不静默）" "$([[ "$out" == *"SKIP_REVIEW=1"* && "$out" == *"不查"* ]] && echo true || echo false)"
cd "$ORIG"

echo
echo "=== ③ SKIP_REVIEW=1 不影响 CHECK 6 ==="
R=$(mkrepo '{"mode":"strict"}'); cd "$R"
out=$(SKIP_REVIEW=1 gate); rc=$?
assert "verify 没有产物 ⇒ 仍然阻断（实际 ${rc}）" "$([[ $rc -ne 0 ]] && echo true || echo false)"
assert "阻断来自 CHECK 6，不是 CHECK 5" \
  "$([[ "$out" != *"No content-anchored review evidence"* && "$out" == *"Verifier evidence missing"* ]] && echo true || echo false)"
cd "$ORIG"

echo
echo "=== ④ 不需要审查的小改动：SKIP_REVIEW=1 不打印（没有东西被跳过）==="
R=$(mkrepo '{"mode":"strict","verify":{"mode":"off"}}'); cd "$R"
git reset -q; printf 'y\n' >> README.md; git add README.md
out=$(SKIP_REVIEW=1 gate)
assert "没有 SKIP_REVIEW 提示" "$([[ "$out" != *"SKIP_REVIEW=1"* ]] && echo true || echo false)"
cd "$ORIG"

echo
read -r P F < "$RESULTS_FILE"; rm -f "$RESULTS_FILE"
echo "PASS=$P FAIL=$F"
[[ "$F" -eq 0 ]]
