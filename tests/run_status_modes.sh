#!/usr/bin/env bash
# Tests for the gate-mode row in agent-gates-status.
#
# WHY: modes (strict / relaxed / merge-only / off) and `verify.require_matrix` are now the
# main thing deciding whether anything is actually checked — and every one of them is
# invisible until a commit happens. "off" is the dangerous case: the gate exits 0 and the
# repo looks healthy. A status command that reports "All current." while nothing is being
# reviewed is reporting the wrong thing.
#
# So: the row states the effective mode and where it came from, and a globally disabled
# gate counts as needing attention rather than passing quietly.
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

setup() {
  INST=$(mktemp -d); mkdir -p "$INST/hooks/git" "$INST/bin"
  echo "2.9.0" > "$INST/.version"
  printf 'GATE_VERSION="2.9.0"\n' > "$INST/hooks/git/agent-quality-gate.sh"
  REPO=$(mktemp -d); cd "$REPO" || exit 1
  git init -q; git config user.email t@t.com; git config user.name T
  echo x > a.txt; git add -A; git commit -q -m init
  export AGENT_GATES_DIR="$INST"
  export AGENT_GATES_REPO="$REPO"   # keep the repo row off the real checkout
}
teardown() { cd /; rm -rf "${REPO:-}" "${INST:-}"; }
run_status() { bash "$STATUS" --no-network 2>&1; }

echo "=== agent-gates-status gate-mode row ==="
echo

echo "M0: 前置——status 本身能跑起来（否则后面的断言全无意义）"
( setup
  out=$(run_status)
  assert "输出里有 agent-gates 版本行" "$([[ "$out" == *"agent-gates"* ]] && echo true || echo false)"
  teardown )

echo "M1: 无任何配置 → 显示 strict（默认），不报 attention"
( setup
  out=$(run_status)
  assert "显示 strict" "$([[ "$out" == *strict* ]] && echo true || echo false)"
  teardown )

echo "M2: ⭐ 用户级 mode=off → 必须显示且计入 attention（门禁全关不能静默）"
( setup
  printf '{"mode":"off"}\n' > "$AGENT_GATES_DIR/gates.json"
  out=$(run_status); rc=$?
  assert "显示 off" "$([[ "$out" == *off* || "$out" == *OFF* ]] && echo true || echo false)"
  assert "退出码非 0（needs attention）(rc=$rc)" "$([[ $rc -ne 0 ]] && echo true || echo false)"
  teardown )

echo "M3: ⭐ --quiet 下门禁全关也要说出来（钩子/脚本读的是这一行）"
( setup
  printf '{"mode":"off"}\n' > "$AGENT_GATES_DIR/gates.json"
  out=$(bash "$STATUS" --no-network --quiet 2>&1)
  assert "quiet 摘要提到 attention" "$([[ "$out" == *attention* ]] && echo true || echo false)"
  teardown )

echo "M4: 项目级 .agent/gates.json 覆盖用户级，并标明来源"
( setup
  printf '{"mode":"strict"}\n' > "$AGENT_GATES_DIR/gates.json"
  mkdir -p .agent; printf '{"mode":"relaxed"}\n' > .agent/gates.json
  out=$(run_status)
  assert "显示 relaxed" "$([[ "$out" == *relaxed* ]] && echo true || echo false)"
  # 只看 gate mode 那一行。整篇输出里 "projects" 行本来就含 "project"，
  # 之前这条断言就是靠它空过的。
  ROW=$(printf '%s\n' "$out" | grep 'gate mode' || true)
  assert "gate mode 行标明来源是项目级 (行: ${ROW//[[:space:]]+/ })" "$([[ "$ROW" == *project* ]] && echo true || echo false)"
  teardown )

echo "M5: review 与 verify 各自分级时分别显示"
( setup
  printf '{"review":{"mode":"merge-only"},"verify":{"mode":"strict"}}\n' > "$AGENT_GATES_DIR/gates.json"
  out=$(run_status)
  assert "显示 review=merge-only" "$([[ "$out" == *merge-only* ]] && echo true || echo false)"
  assert "同时显示 verify" "$([[ "$out" == *verify* ]] && echo true || echo false)"
  teardown )

echo "M6: verify.require_matrix=false → 明说需求遗漏检查被关掉"
( setup
  printf '{"verify":{"require_matrix":false}}\n' > "$AGENT_GATES_DIR/gates.json"
  out=$(run_status)
  assert "提到 matrix / 需求" "$([[ "$out" == *matrix* || "$out" == *需求* ]] && echo true || echo false)"
  teardown )

echo "M8: ⭐ status 与门禁对同一份配置判定一致（防解析逻辑分叉）"
# status 重新实现了一遍模式解析。两边分叉的后果是 status 变成一个自信的骗子 ——
# 它说 strict 而门禁其实在 relaxed。所以直接对比两者的输出。
( setup
  GATE="$SCRIPT_DIR/../hooks/git/agent-quality-gate.sh"
  mkdir -p .agent/verify .agent/reviews .agent/plans migration
  for cfg in '{"mode":"relaxed"}' '{"mode":"merge-only"}' '{"review":{"mode":"relaxed"},"verify":{"mode":"merge-only"}}'; do
    printf '%s\n' "$cfg" > "$AGENT_GATES_DIR/gates.json"
    git checkout -q -b feat/x 2>/dev/null || true
    for i in $(seq 1 25); do echo "ALTER TABLE t$i ADD c INT;" >> migration/002.sql; done
    git add migration/002.sql 2>/dev/null
    gout=$(AGENT_MODE=1 bash "$GATE" 2>&1 || true)
    sout=$(run_status)
    for m in relaxed merge-only; do
      if [[ "$gout" == *"$m"* ]]; then
        assert "配置 $cfg: 门禁提到 $m，status 也提到" "$([[ "$sout" == *"$m"* ]] && echo true || echo false)"
      fi
    done
    git reset -q; rm -f migration/002.sql
  done
  teardown )

echo "M7: 不在 git 仓库里也不能崩"
( setup
  cd /tmp || exit 1
  out=$(run_status); rc=$?
  assert "仍有输出" "$([[ -n "$out" ]] && echo true || echo false)"
  assert "未因不在仓库而崩（有版本行）" "$([[ "$out" == *"agent-gates"* ]] && echo true || echo false)"
  teardown )

echo
read -r P F < "$RESULTS_FILE"
echo "=== PASS=$P FAIL=$F ==="
rm -f "$RESULTS_FILE"
[[ "$F" -eq 0 ]]
