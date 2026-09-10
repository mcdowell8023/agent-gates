#!/usr/bin/env bash
# 两条来自 wb 一线会话的实测反馈（agent 3e2ffb58，2026-09-10）。
# 我此前完全不知道这两条 —— 都不是本次会话引入的，BUG 1 追到 6fffbf9（2026-06-27）。
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
eq() { assert "$1 → 期望 [$3]，实际 [$2]" "$([[ "$2" == "$3" ]] && echo true || echo false)"; }

echo "=== 一线反馈的两条 bug ==="
echo

echo "--- BUG 1: grep -c 无匹配时 || echo 产出两行 ---"
# 根因：`grep -c` 无匹配时**打印 0 并且退出码 1** ⇒ `|| echo "0"` 再补一个 0。
# 后果：diff 里只要有纯删除文件（新增行数 0），`[[ "$v" -gt N ]]` 就抛语法错；
# `&&` 短路让循环继续，所以**不报错、不中断**，但 MAX_SINGLE_FILE_LINES 从此不再更新
# ⇒ 单文件行数上限检查静默失效。
assert "⭐ 门禁里不再有 'grep -c ... || echo' 这个形状" \
  "$(grep -qE 'grep -c[^|]*\|\| echo' "$GATE" && echo false || echo true)"

# 行为验证：让**真门禁**跑在一个只删不加的 staged diff 上。
# ⚠️ 必须带 AGENT_MODE=1 —— `agent-quality-gate.sh:8` 那行在它不为 1 时直接 exit 0、
# 一个字都不打印，第一版就因此把"输出为空"读成了断言失败。
# ⛔ 别去 eval 抽出来的代码片段 —— 那段依赖门禁里的其它变量，抽出来跑等于测另一个东西。
D=$(mktemp -d); pushd "$D" >/dev/null
git init -q . && git config user.email t@t && git config user.name t
printf 'a\nb\nc\n' > gone.txt
printf 'keep\n' > keep.txt
mkdir -p .agent && printf '{"mode":"relaxed"}\n' > .agent/gates.json
git add . && git commit -q -m init
git rm -q gone.txt          # 纯删除 ⇒ 该文件新增行数 = 0，正是触发条件
out=$(AGENT_MODE=1 AGENT_GATES_DIR=$(mktemp -d) bash "$GATE" 2>&1 || true)
assert "⭐ 纯删除文件不再触发算术语法错" \
  "$([[ "$out" != *"syntax error"* && "$out" != *"bad math"* && "$out" != *"error token"* ]] && echo true || echo false)"
assert "门禁确实跑起来了（不是空过）" \
  "$([[ "$out" == *"Agent Quality Gate"* ]] && echo true || echo false)"
popd >/dev/null

echo
echo "--- BUG 2: 新 worktree 丢 gates.json ⇒ 退回 strict ---"
# 现象：`git worktree add` 出来的目录里没有 .agent/gates.json（项目 .gitignore 里有
# `.agent/`，所以它从未被 git 跟踪），gate 找不到项目策略就按 strict 走，
# 在普通业务分支上也强制要求 review + verify 产物。
# 一线的修法建议（采纳）：gate 自己回退到**主 worktree** 找 ——
# `git rev-parse --git-common-dir` 的父目录就是主 worktree 根。一处改动覆盖所有项目，
# 且不动任何项目的 .gitignore。
R=$(mktemp -d); cd "$R"
git init -q . && git config user.email t@t && git config user.name t
printf 'x\n' > f.txt && git add . && git commit -q -m init
mkdir -p .agent && printf '{"mode":"off"}\n' > .agent/gates.json
printf '.agent/\n' > .gitignore && git add .gitignore && git commit -q -m ignore
git worktree add -q wt -b feat/x >/dev/null 2>&1
cd wt
assert "前提成立：worktree 里确实没有 gates.json" \
  "$([[ ! -f .agent/gates.json ]] && echo true || echo false)"
# ⚠️ 必须有 staged 变更：无变更时门禁提前退出、一个字都不打印，
# 断言会因为"输出为空"而假失败（第一版就是这么错的）。
printf 'y\n' > new.txt && git add new.txt
out=$(AGENT_MODE=1 AGENT_GATES_DIR=$(mktemp -d) bash "$GATE" 2>&1 || true)
# 注意实际输出是 `mode=off`（不是 `mode: off`）——第一版断言 grep 错了字面量。
assert "⭐ 仍读到主 worktree 的 mode=off" \
  "$([[ "$out" == *"mode=off"* ]] && echo true || echo false)"
# 正对照：确认它真的是从**主 worktree**读到的，不是碰巧命中别的默认
assert "⭐ 配置来源指向主 worktree 的 .agent/gates.json" \
  "$([[ "$out" == *"/.agent/gates.json"* ]] && echo true || echo false)"
assert "⭐ 不再误判成 strict" \
  "$([[ "$out" != *"mode: strict"* ]] && echo true || echo false)"
cd - >/dev/null

echo
read -r P F < "$RESULTS_FILE"
echo "PASS=$P FAIL=$F"
rm -f "$RESULTS_FILE"
[[ "$F" -eq 0 ]] || exit 1
