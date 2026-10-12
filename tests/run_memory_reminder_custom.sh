#!/usr/bin/env bash
# 提醒钩子的 todo 完成文案可配置（v2.11.0）。
#
# 🔴 背景：文案写死「用 Memory skill → save(…)」。用户 10-07 起改为按自己的规则写 inbox
# （红线 #12），Memory skill 也已移除 —— 每次标完 todo 都收到一条指向不存在工具的提醒。
# 契约：
#   · $AGENT_GATES_DIR/memory-reminder.md 存在且非空 ⇒ 用它作正文，不再出现内置的 Memory skill 示例
#   · 不存在 / 空文件 / 读失败 ⇒ 回落内置文案；钩子永远 exit 0（不得阻塞工具调用）
#   · 只影响 todo 完成提醒，并行提醒等其它提醒不变
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$SCRIPT_DIR/../hooks/platform/memory-reminder.mjs"
FIX="$SCRIPT_DIR/fixtures"
RESULTS_FILE=$(mktemp); echo "0 0" > "$RESULTS_FILE"
assert() {
  local name="$1" cond="$2" p f
  read -r p f < "$RESULTS_FILE"
  if [[ "$cond" == "true" ]]; then echo "  ✓ $name"; echo "$((p+1)) $f" > "$RESULTS_FILE"
  else echo "  ✗ $name"; echo "$p $((f+1))" > "$RESULTS_FILE"; fi
}
hook() { AGENT_GATES_DIR="$1" node "$HOOK" < "$2" 2>/dev/null; echo "rc=$?"; }

D=$(mktemp -d)
printf '请用 memory-inbox-add.sh 把进展写进 inbox（红线 #12）。\n' > "$D/memory-reminder.md"
out=$(hook "$D" "$FIX/todo-completed.json")
assert "⭐ 有自定义文件 ⇒ 用它的内容" "$([[ "$out" == *"memory-inbox-add.sh"* ]] && echo true || echo false)"
assert "⭐ 不再出现内置的 Memory skill 示例" "$([[ "$out" != *"Memory skill → save"* ]] && echo true || echo false)"
assert "仍然是 Memory Persistence Reminder" "$([[ "$out" == *"Memory Persistence Reminder"* ]] && echo true || echo false)"
assert "exit 0" "$([[ "$out" == *"rc=0" ]] && echo true || echo false)"

out=$(hook "$D" "$FIX/plan-time-3-pending.json")
assert "并行提醒不受影响" "$([[ "$out" == *"Parallelism Reminder"* && "$out" != *"memory-inbox-add.sh"* ]] && echo true || echo false)"

E=$(mktemp -d); : > "$E/memory-reminder.md"
out=$(hook "$E" "$FIX/todo-completed.json")
assert "空文件 ⇒ 回落内置文案" "$([[ "$out" == *"Memory skill"* ]] && echo true || echo false)"

U=$(mktemp -d); mkdir "$U/memory-reminder.md"
out=$(hook "$U" "$FIX/todo-completed.json")
assert "读失败（同名是目录）⇒ 回落内置文案" "$([[ "$out" == *"Memory skill"* ]] && echo true || echo false)"
assert "读失败也 exit 0" "$([[ "$out" == *"rc=0" ]] && echo true || echo false)"

N=$(mktemp -d)
out=$(hook "$N" "$FIX/todo-completed.json")
assert "没有文件 ⇒ 内置文案（默认行为不变）" "$([[ "$out" == *"Memory skill"* ]] && echo true || echo false)"

echo
read -r P F < "$RESULTS_FILE"; rm -f "$RESULTS_FILE"
echo "PASS=$P FAIL=$F"
[[ "$F" -eq 0 ]]
