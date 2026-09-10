#!/usr/bin/env bash
# Tests that a merge into a strict branch is actually gated.
#
# THE HOLE (measured 2026-09-01): v2.7.0 added "a merge into a strict branch is NOT skipped"
# to the gate, and `merge-only` mode defers review to exactly that moment. But git runs
# **pre-merge-commit** for a merge commit, not pre-commit — and agent-gates only ever
# installed pre-commit. So:
#   - a clean non-ff merge ran no gate at all
#   - a fast-forward merge creates no commit, so there is no hook point whatsoever
#   - only a CONFLICTED merge (resolve, then `git commit`) reached the gate, because that
#     path does run pre-commit with MERGE_HEAD set
# Net effect: `merge-only` deferred review to a checkpoint that did not exist.
#
# Verified empirically with a scratch repo carrying both hooks: the merge fired
# pre-merge-commit and never pre-commit.
set -uo pipefail

# ⛔ FAIL-SAFE: 真的 `pi` 在 PATH 上，而 pi 通道排在 opencode 之前。本文件只 fake 了
# opencode，不显式把 pi 指向不存在的路径就会发真实 API 调用（踩过，挂到 120s）。
# ⚠️ opencode 二进制已于 2026-09-10 卸载，但这些用例走的是 OC_REVIEW_OPENCODE 指定的
# **fake**，与真机是否装了 opencode 无关 ⇒ 照常有效。
export AG_REVIEW_PI="${AG_REVIEW_PI:-/nonexistent/pi-must-not-run-in-tests}"
# v2.9.4: opencode 现在默认**关**（与 lib/hetero/config.sh 同口径）。本文件测的就是
# opencode 路径，所以显式打开 —— 否则通道被跳过，断言看起来像"审查功能坏了"。
export HETERO_CHAN_OPENCODE="${HETERO_CHAN_OPENCODE:-1}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SHIM="$SCRIPT_DIR/../hooks/git/gate-shim.sh"
# ⭐ 测试必须用**本次新增的那个文件**，不是它的来源。原来 fixture 复制的是
# hooks/git/gate-shim.sh —— 于是 .githooks/pre-merge-commit 写坏、写旧、权限不对，
# 这套测试照样绿。这次改动最直接新增的那个文件，反而没被覆盖到。
REAL_HOOK="$SCRIPT_DIR/../.githooks/pre-merge-commit"
GATE="$SCRIPT_DIR/../hooks/git/agent-quality-gate.sh"
RESULTS_FILE=$(mktemp); echo "0 0" > "$RESULTS_FILE"

assert() {
  local name="$1" cond="$2" p f
  read -r p f < "$RESULTS_FILE"
  if [[ "$cond" == "true" ]]; then echo "  ✓ $name"; echo "$((p+1)) $f" > "$RESULTS_FILE"
  else echo "  ✗ $name"; echo "$p $((f+1))" > "$RESULTS_FILE"; fi
}

setup() {
  REPO=$(mktemp -d); cd "$REPO" || exit 1
  git init -q -b master; git config user.email t@t.com; git config user.name T
  mkdir -p .githooks src .agent/plans .agent/reviews .agent/verify
  cp "$SHIM" .githooks/pre-commit
  cp "$REAL_HOOK" .githooks/pre-merge-commit
  chmod +x .githooks/*
  git config core.hooksPath .githooks
  export AGENT_GATES_GATE="$GATE" AGENT_MODE=1
  AGENT_GATES_DIR=$(mktemp -d); export AGENT_GATES_DIR
  printf '{"mode":"merge-only"}\n' > .agent/gates.json
  # --no-verify for FIXTURE commits only: this file tests the MERGE hook, so the commits
  # that build the scenario must not be subject to the commit hook. Letting them run it made
  # setup itself fail on CHECK 3 and the real assertions never got a valid starting state.
  echo init > src/a.ts; git add -A; git commit -q --no-verify -m init
}
teardown() { cd /; rm -rf "${REPO:-}" "${AGENT_GATES_DIR:-}"; unset AGENT_GATES_GATE; }

# A feature branch carrying a change big enough to need review
make_feature() {
  git checkout -q -b feat/big
  { echo "export const f = () => {"; for i in $(seq 1 158); do echo "  // l $i"; done; echo "}"; } > src/big.ts
  echo "test('f',()=>{})" > src/big.test.ts
  git add -A
  git commit -q --no-verify -m "big change"
  git checkout -q master
  echo other > src/other.txt; git add -A; git commit -q --no-verify -m other
}

echo "=== merge into a strict branch is gated ==="
echo

echo "M0: 前置——业务分支上 merge-only 确实跳过 CHECK 5/6"
( setup
  git checkout -q -b feat/x
  echo y > src/y.ts; echo "test('y',()=>{})" > src/y.test.ts; git add -A
  out=$(SKIP_PLAN_CHECK=1 bash .githooks/pre-commit 2>&1); rc=$?
  # 证明确实走到了分级判断，而不是被别的检查早退
  assert "输出提到 merge-only 跳过" "$([[ "$out" == *"merge-only"* ]] && echo true || echo false)"
  assert "业务分支放行 (rc=$rc)" "$([[ $rc -eq 0 ]] && echo true || echo false)"
  teardown )

echo "M1: ⭐ 非 ff merge 进 strict 分支 → pre-merge-commit 必须拦住（无审查产物）"
( setup; make_feature
  out=$(SKIP_PLAN_CHECK=1 git merge --no-ff feat/big --no-edit 2>&1); rc=$?
  assert "merge 被拦 (rc=$rc)" "$([[ $rc -ne 0 ]] && echo true || echo false)"
  assert "输出来自门禁" "$([[ "$out" == *"Quality Gate"* ]] && echo true || echo false)"
  # 拦住的路径是「分支本身是 strict → 强制 strict」，而不是门禁里那条 MERGE_HEAD 分支：
  # pre-merge-commit 运行时 MERGE_HEAD 还没写入。功能等价，但断言要写实际发生的事。
  assert "说明被强制为 strict" "$([[ "$out" == *"forced to strict"* ]] && echo true || echo false)"
  assert "给出可操作的修复指引" "$([[ "$out" == *"agent-gates-review"* || "$out" == *"cross-review"* ]] && echo true || echo false)"
  teardown )

echo "M2: ⛔ 没有 pre-merge-commit 钩子时，同一个 merge 完全不受检（这就是原先的空洞）"
( setup; rm -f .githooks/pre-merge-commit; make_feature
  out=$(SKIP_PLAN_CHECK=1 git merge --no-ff feat/big --no-edit 2>&1); rc=$?
  assert "merge 通过了（证明空洞真实存在）(rc=$rc)" "$([[ $rc -eq 0 ]] && echo true || echo false)"
  assert "门禁一个字都没输出" "$([[ "$out" != *"Quality Gate"* ]] && echo true || echo false)"
  teardown )

echo "M3: 仓库里那个 pre-merge-commit 就是 shim 本身，且不含 pre-commit 专属逻辑"
# 原断言写的是 grep -qiE 'pre-commit|hook_name|\$0'，而它**匹配不到字面量 $0**
# （实测 printf '$0\n' | grep -qiE '…\$0' 返回 1）—— 声称在防 hook-name 分支逻辑，
# 实际是空心的。改用固定字符串逐个查，并加一条自检证明这种查法确实生效。
assert "⭐ .githooks/pre-merge-commit 与 gate-shim.sh 内容一致" \
  "$([[ -f "$REAL_HOOK" ]] && cmp -s "$REAL_HOOK" "$SHIM" && echo true || echo false)"
assert "⭐ 该文件可执行" "$([[ -x "$REAL_HOOK" ]] && echo true || echo false)"
for pat in 'pre-commit' 'hook_name' '$0'; do
  assert "不含 pre-commit 专属逻辑: $pat" "$(grep -qF -- "$pat" "$REAL_HOOK" && echo false || echo true)"
done
assert "自检：固定串查法确实生效" "$(grep -qF -- 'AUTH' "$REAL_HOOK" && echo true || echo false)"
assert "只做 exec 转发" "$(grep -qF 'exec "$AUTH"' "$REAL_HOOK" && echo true || echo false)"

echo
read -r P F < "$RESULTS_FILE"
echo "=== PASS=$P FAIL=$F ==="
rm -f "$RESULTS_FILE"
[[ "$F" -eq 0 ]]
