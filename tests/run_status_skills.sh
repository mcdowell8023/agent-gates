#!/usr/bin/env bash
# agent-gates-status 的 skill 统计要和安装器一致（v2.11.2）。
#
# 🔴 背景（2026-10-13）：v2.11.0 让安装器可以不装 Memory skill（--skip-memory-skill，选择写进标记），
# 但状态工具的清单是写死的 5 个、含 memory、不含 agent-gates，也不认标记 ⇒
# 用了 --skip-memory-skill 的机器上永远报「skills 4/5 — re-run install.sh」，
# 照着重装一遍还是同一行 —— 一条永远红灯、又修不好的提示，比没有更糟。
# 契约：
#   · 清单 = 安装器装的那几个（init-project-gates agent-workflow-rules agent-review-protocol
#     init-deep-fallback agent-gates），有 $INSTALL_DIR/.skip-memory-skill 标记就不含 memory，否则含
#   · 缺了就报，⛔ 不因为标记而放过别的 skill
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATUS="$SCRIPT_DIR/../bin/agent-gates-status"
RESULTS_FILE=$(mktemp); echo "0 0" > "$RESULTS_FILE"
assert() {
  local name="$1" cond="$2" p f
  read -r p f < "$RESULTS_FILE"
  if [[ "$cond" == "true" ]]; then echo "  ✓ $name"; echo "$((p+1)) $f" > "$RESULTS_FILE"
  else echo "  ✗ $name"; echo "$p $((f+1))" > "$RESULTS_FILE"; fi
}

BASE5=(init-project-gates agent-workflow-rules agent-review-protocol init-deep-fallback agent-gates)
setup() {   # setup <marker 0|1> <要装进 ~/.claude/skills 的 skill...>
  local marker="$1"; shift
  MOCK_HOME=$(mktemp -d); export HOME="$MOCK_HOME"
  INST=$(mktemp -d); export AGENT_GATES_DIR="$INST"
  mkdir -p "$INST/hooks/git" "$MOCK_HOME/.claude/skills"
  echo "2.11.1" > "$INST/.version"; printf 'GATE_VERSION="2.11.1"\n' > "$INST/hooks/git/agent-quality-gate.sh"
  [[ "$marker" == 1 ]] && : > "$INST/.skip-memory-skill"
  local s; for s in "$@"; do mkdir -p "$MOCK_HOME/.claude/skills/$s"; done
  REPO=$(mktemp -d); export AGENT_GATES_REPO="$REPO"
  ( cd "$REPO" && git init -q && git config user.email t@t.com && git config user.name T && echo x > a && git add -A && git commit -q -m i )
}
run_status() { ( cd "$REPO" && bash "$STATUS" --no-network 2>&1 ); }
skills_row() { printf '%s\n' "$1" | sed 's/\x1b\[[0-9;]*m//g' | grep -E '^\s*skills' | head -1; }

echo "=== agent-gates-status：skill 统计与安装器一致 ==="
echo

echo "S1: 无标记、6 个齐全 ⇒ 全绿"
( setup 0 "${BASE5[@]}" memory
  row=$(skills_row "$(run_status)")
  assert "显示 claude 6/6" "$([[ "$row" == *"6/6"* && "$row" != *"re-run"* ]] && echo true || echo false)" )

echo "S2: 无标记、缺 memory ⇒ 报缺（默认行为不变）"
( setup 0 "${BASE5[@]}"
  row=$(skills_row "$(run_status)")
  assert "报 claude:5/6" "$([[ "$row" == *"claude:5/6"* && "$row" == *"re-run"* ]] && echo true || echo false)" )

echo "S3: ⭐ 有 .skip-memory-skill 标记、没有 memory、其余齐全 ⇒ 全绿，不再要求重装"
( setup 1 "${BASE5[@]}"
  row=$(skills_row "$(run_status)")
  assert "⭐ 显示 5/5，不报 re-run" "$([[ "$row" == *"5/5"* && "$row" != *"re-run"* ]] && echo true || echo false)" )

echo "S4: ⛔ 有标记、但缺的是 agent-gates ⇒ 仍然报缺（标记只豁免 memory）"
( setup 1 init-project-gates agent-workflow-rules agent-review-protocol init-deep-fallback
  row=$(skills_row "$(run_status)")
  assert "报缺 claude:4/5" "$([[ "$row" == *"claude:4/5"* && "$row" == *"re-run"* ]] && echo true || echo false)" )

echo "S5: ⭐ 清单含 agent-gates（原来的清单漏了它）：缺它必须被发现"
( setup 0 init-project-gates agent-workflow-rules agent-review-protocol init-deep-fallback memory
  row=$(skills_row "$(run_status)")
  assert "无标记缺 agent-gates ⇒ 报 claude:5/6" "$([[ "$row" == *"claude:5/6"* ]] && echo true || echo false)" )

echo "S6: 有标记、memory 目录残留（用户自己的）⇒ 不报错"
( setup 1 "${BASE5[@]}" memory
  row=$(skills_row "$(run_status)")
  assert "不报缺" "$([[ "$row" != *"re-run"* ]] && echo true || echo false)" )

echo
read -r P F < "$RESULTS_FILE"; rm -f "$RESULTS_FILE"
echo "PASS=$P FAIL=$F"
[[ "$F" -eq 0 ]]
