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

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SHIM="$SCRIPT_DIR/../hooks/git/gate-shim.sh"
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
  cp "$SHIM" .githooks/pre-merge-commit
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

echo "M3: gate-shim 可同时用作 pre-commit 与 pre-merge-commit（同一份，无需第二个实现）"
assert "shim 不含 pre-commit 专属逻辑" "$(grep -qiE 'pre-commit|hook_name|\\$0' "$SHIM" && echo false || echo true)"
assert "shim 只做 exec 转发" "$(grep -q 'exec "\$AUTH"' "$SHIM" && echo true || echo false)"

echo
read -r P F < "$RESULTS_FILE"
echo "=== PASS=$P FAIL=$F ==="
rm -f "$RESULTS_FILE"
[[ "$F" -eq 0 ]]
