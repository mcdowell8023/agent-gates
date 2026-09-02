#!/usr/bin/env bash
# Tests for the opencode row in agent-gates-status.
#
# THE BUG (found 2026-09-01 by my own two tools disagreeing): status reimplemented the
# reap criteria as "age > 1h && no `opencode run` client" and printed
# `— oc-reaper --apply`. oc-reaper itself KEEPS a serve on the shared port, because its
# lifecycle belongs to oc-review (that exemption exists precisely because the reaper once
# killed a shared serve that was in use). So status flagged "needs attention" and told the
# user to run a command that then reported `0 reapable, 1 kept` and did nothing.
#
# Advice that does not correspond to what the tool will do is worse than no advice: the
# user runs it, sees a no-op, and stops trusting the row.
#
# So status ASKS oc-reaper instead of deciding for itself. Same lesson as delegating verdict
# parsing to conclusion.sh: two implementations of one judgement always drift, and the drift
# surfaces as confident wrong output.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATUS="$SCRIPT_DIR/../bin/agent-gates-status"
RESULTS_FILE=$(mktemp); echo "0 0" > "$RESULTS_FILE"
REAL_HOME="$HOME"

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
  export AGENT_GATES_DIR="$INST" AGENT_GATES_REPO="$REPO"
  # Isolate HOME. status also checks skills under ~/.claude/skills etc., and a host missing
  # any of them sets ATTENTION=1 — so the rc assertions below would fail for a reason that
  # has nothing to do with the opencode row. With a temp HOME none of those dirs exist and
  # the skills check skips them entirely.
  FAKE_HOME=$(mktemp -d); export HOME="$FAKE_HOME"
  FAKE=$(mktemp -d)
  # `pgrep` is faked too. Without this the cases read the MACHINE's real serve count, so the
  # same code passes or fails depending on unrelated state — which is exactly how I once
  # read `PASS=8 FAIL=0` off a file that was visibly emitting two opencode rows.
  export PATH="$FAKE:$PATH"
  fake_serves 1
}
# fake_serves <n> : n fake `opencode serve` pids, and never any `opencode run` client
fake_serves() {
  # ⚠️ 不用 `seq 1 $n`：BSD seq（macOS 自带）对 `seq 1 0` 会**倒序输出 1 0 两行**，
  # GNU 版输出空。照 GNU 语义写会让 fake_serves 0 反而造出 2 个假 pid。
  cat > "$FAKE/pgrep" <<EOF
#!/usr/bin/env bash
N=$1
for a in "\$@"; do
  case "\$a" in
    *"opencode serve"*)
      i=0; while [ "\$i" -lt "\$N" ]; do i=\$((i+1)); echo \$((9000+i)); done
      [ "\$N" -gt 0 ] && exit 0 || exit 1 ;;
    *"opencode run"*) exit 1 ;;
  esac
done
exit 1
EOF
  chmod +x "$FAKE/pgrep"
}
teardown() { cd /; rm -rf "${REPO:-}" "${INST:-}" "${FAKE:-}" "${FAKE_HOME:-}"; export HOME="$REAL_HOME"; unset AGENT_GATES_OC_REAPER; }
# fake_reaper <reapable> <kept> [keep-reason]
# Touches $FAKE/reaper-called so a case can prove status actually consulted it.
fake_reaper() {
  local reason="${3:-shared serve :4096 pid=2 (managed by oc-review, age 9999s)}"
  cat > "$FAKE/oc-reaper" <<EOF
#!/usr/bin/env bash
: > "$FAKE/reaper-called"
[ "$1" -gt 0 ] && echo "[reap] serve :4096 pid=1 age 9999s"
[ "$2" -gt 0 ] && echo "[keep] $reason"
echo "---"
echo "oc-reaper: $1 reapable, $2 kept — rerun with --apply to kill"
EOF
  chmod +x "$FAKE/oc-reaper"; export AGENT_GATES_OC_REAPER="$FAKE/oc-reaper"
  rm -f "$FAKE/reaper-called"
}
# 输出不含 "N reapable, M kept" 的 reaper
fake_reaper_garbage() {
  printf '#!/usr/bin/env bash\n: > "%s/reaper-called"\necho "something unexpected"\n' "$FAKE" > "$FAKE/oc-reaper"
  chmod +x "$FAKE/oc-reaper"; export AGENT_GATES_OC_REAPER="$FAKE/oc-reaper"
  rm -f "$FAKE/reaper-called"
}
run_status() { bash "$STATUS" --no-network 2>&1; }
# 只取标签就是 opencode 的那一行 —— `skills` 行里也含 "opencode"，宽匹配会把它捞进来。
oc_row() { printf '%s\n' "$1" | grep -E '^[[:space:]]+opencode[[:space:]]' || true; }
# 断言必须落在具体那一行。O10/O11 第一版断言的是整篇输出里没有 "All current"，
# 而本机真有 serve 时 opencode 行就会让整体变成 needs attention —— 两条都空过了。
proj_row() { printf '%s\n' "$1" | grep -E '^[[:space:]]+projects[[:space:]]' || true; }

echo "=== agent-gates-status opencode row ==="
echo

echo "O1: ⭐ reaper 说 0 reapable（共享 serve 被保留）→ 不得建议 --apply、不得报 attention"
( setup; fake_reaper 0 1
  out=$(run_status); rc=$?
  row=$(oc_row "$out")
  assert "⛔ 不出现 --apply 建议 (行: $row)" "$([[ "$row" != *"--apply"* ]] && echo true || echo false)"
  assert "说明 reaper 会保留它" "$([[ "$row" == *保留* || "$row" == *keep* || "$row" == *kept* ]] && echo true || echo false)"
  assert "⭐ 确实问过 oc-reaper（不是自己判的）" "$([[ -f "$FAKE/reaper-called" ]] && echo true || echo false)"
  assert "退出码 0（不算 needs attention）(rc=$rc)" "$([[ $rc -eq 0 ]] && echo true || echo false)"
  teardown )

echo "O2: reaper 说有 reapable → 照实标出并给命令"
( setup; fake_reaper 2 0
  out=$(run_status); rc=$?
  row=$(oc_row "$out")
  assert "出现 --apply 建议 (行: $row)" "$([[ "$row" == *"--apply"* ]] && echo true || echo false)"
  # 精确匹配「2 可回收」。写成 *2* 只是在查这一行出现过字符 2 —— `12 可回收` / `20 可回收`
  # 这种错误值照样能过，等于没校验。
  assert "⭐ 数量精确为 reaper 报的 2" "$([[ "$row" == *"2 可回收"* && "$row" != *"12 可回收"* && "$row" != *"20 可回收"* ]] && echo true || echo false)"
  assert "退出码非 0 (rc=$rc)" "$([[ $rc -ne 0 ]] && echo true || echo false)"
  assert "确实问过 oc-reaper" "$([[ -f "$FAKE/reaper-called" ]] && echo true || echo false)"
  teardown )

echo "O3: 完全没有 serve → 干净行，不调 reaper 也不报"
( setup
  # 让 reaper 一被调用就失败，以此证明「无 serve 时不该调它」
  cat > "$FAKE/oc-reaper" <<'EOF'
#!/usr/bin/env bash
echo "REAPER-WAS-CALLED" >&2; exit 1
EOF
  chmod +x "$FAKE/oc-reaper"; export AGENT_GATES_OC_REAPER="$FAKE/oc-reaper"
  fake_serves 0
  out=$(run_status)
  assert "显示 no serves" "$([[ "$(oc_row "$out")" == *"no serves"* ]] && echo true || echo false)"
  assert "未调用 reaper（无 serve 时不该问）" "$([[ "$out" != *REAPER-WAS-CALLED* ]] && echo true || echo false)"
  teardown )

echo "O4: reaper 不可用 → 只报数量，不给可能无效的建议"
( setup
  export AGENT_GATES_OC_REAPER="/nonexistent/oc-reaper"
  out=$(run_status); rc=$?
  row=$(oc_row "$out")
  assert "⛔ 不给 --apply 建议 (行: $row)" "$([[ "$row" != *"--apply"* ]] && echo true || echo false)"
  assert "文案点明 oc-reaper 不可用" "$([[ "$row" == *oc-reaper* ]] && echo true || echo false)"
  # 判不出来时放行是 fail-open：有 serve 却给不出结论，必须计入 needs attention
  assert "⭐ rc 非 0（不能 fail-open）(rc=$rc)" "$([[ $rc -ne 0 ]] && echo true || echo false)"
  teardown )

echo "O6: ⭐ kept 不等于「共享 serve」—— reaper 有 7 个 keep 分支，只有 1 个是 shared"
( setup; fake_reaper 0 1 "serve :5000 pid=3 age 12s (younger than MIN_AGE)"
  out=$(run_status); row=$(oc_row "$out")
  # 把任何 kept 都说成「共享 serve 由 oc-review 管」是在用户可见输出里下错误断言
  assert "⛔ 不得声称是共享 serve (行: $row)" "$([[ "$row" != *共享* && "$row" != *"oc-review"* ]] && echo true || echo false)"
  assert "仍报出保留数量" "$([[ "$row" == *1* ]] && echo true || echo false)"
  teardown )

echo "O7: reaper 输出无法解析 → 不猜结论，且不 fail-open"
( setup; fake_reaper_garbage
  out=$(run_status); rc=$?
  row=$(oc_row "$out")
  assert "⛔ 不给 --apply 建议 (行: $row)" "$([[ "$row" != *"--apply"* ]] && echo true || echo false)"
  assert "文案说明无法解析" "$([[ "$row" == *无法解析* || "$row" == *unparse* ]] && echo true || echo false)"
  assert "⭐ rc 非 0（不能 fail-open）(rc=$rc)" "$([[ $rc -ne 0 ]] && echo true || echo false)"
  teardown )

echo "O5: ⭐ opencode 行只能有一条（重复块曾同时输出新旧两行）"
( setup; fake_reaper 0 1
  out=$(run_status)
  n=$(printf '%s\n' "$out" | grep -cE '^[[:space:]]+opencode[[:space:]]')
  assert "恰好 1 行 (实际 $n)" "$([[ "$n" == "1" ]] && echo true || echo false)"
  teardown )

echo "O8: ⭐ --full 缺 pre-merge-commit 时不能报「all current」"
# migrate 只判 shim/frozen，看不见 pre-merge-commit。老项目只有 pre-commit 时
# --full 仍报 all current，而同一仓库 merge --no-ff 进 strict 分支完全不受检 ——
# 一个直接把本版要修的洞重新藏起来的假绿。
( setup
  PROJ=$(mktemp -d); mkdir -p "$PROJ/p1/.githooks"
  git -C "$PROJ/p1" init -q 2>/dev/null
  printf '#!/usr/bin/env bash\n# agent-gates per-project gate shim\nexec "$HOME/.agent-gates/hooks/git/agent-quality-gate.sh" "$@"\n' > "$PROJ/p1/.githooks/pre-commit"
  chmod +x "$PROJ/p1/.githooks/pre-commit"
  git -C "$PROJ/p1" config core.hooksPath .githooks
  # 让 hooks-sync 可被 status 找到
  mkdir -p "$AGENT_GATES_DIR/bin" "$AGENT_GATES_DIR/hooks/git"
  cp "$SCRIPT_DIR/../bin/agent-gates-hooks-sync" "$AGENT_GATES_DIR/bin/"
  cp "$SCRIPT_DIR/../hooks/git/gate-shim.sh" "$AGENT_GATES_DIR/hooks/git/"
  out=$(bash "$STATUS" --no-network --full "$PROJ" 2>&1)
  assert "点出缺 pre-merge-commit 或提示 hooks-sync" "$([[ "$out" == *hooks-sync* || "$out" == *pre-merge-commit* ]] && echo true || echo false)"
  assert "⛔ projects 行不得报 all current" "$([[ "$(proj_row "$out")" != *"all current"* ]] && echo true || echo false)"
  rm -rf "$PROJ"; teardown )

echo "O9: --full 但 hooks-sync 不可用 → 说「未检查」且不得汇总成 All current"
( setup
  PROJ=$(mktemp -d); mkdir -p "$PROJ/p1/.githooks"; git -C "$PROJ/p1" init -q 2>/dev/null
  printf '#!/usr/bin/env bash\n# agent-gates per-project gate shim\nexit 0\n' > "$PROJ/p1/.githooks/pre-commit"
  chmod +x "$PROJ/p1/.githooks/pre-commit"; git -C "$PROJ/p1" config core.hooksPath .githooks
  # 刻意不放 hooks-sync
  out=$(bash "$STATUS" --no-network --full "$PROJ" 2>&1); rc=$?
  assert "说明未检查" "$([[ "$out" == *未检查* ]] && echo true || echo false)"
  assert "⛔ projects 行不说 all current" "$([[ "$(proj_row "$out")" != *"all current"* ]] && echo true || echo false)"
  rm -rf "$PROJ"; teardown )

echo "O10: ⭐ hooks-sync 只报 foreign 时，--full 不得报 all current"
# 我把 hooks-sync 的结果压扁成「待补/未生效」两个字段，忽略了「跳过(非本工具)」——
# 而 hooks-sync 自己把它当成需要 attention（会计数、会非零退出、还会说「merge 仍不受检」）。
# 结果：hooksPath 里放一个非 agent-gates 的 pre-merge-commit，status 报绿，
# 正好把 v2.9.1 想暴露的 merge 空洞藏回去。
( setup
  PROJ=$(mktemp -d); mkdir -p "$PROJ/p1/.githooks"; git -C "$PROJ/p1" init -q 2>/dev/null
  printf '#!/usr/bin/env bash\n# agent-gates per-project gate shim\nexit 0\n' > "$PROJ/p1/.githooks/pre-commit"
  printf '#!/bin/sh\nexit 0\n' > "$PROJ/p1/.githooks/pre-merge-commit"   # foreign
  chmod +x "$PROJ/p1/.githooks/"*
  git -C "$PROJ/p1" config core.hooksPath .githooks
  mkdir -p "$AGENT_GATES_DIR/bin" "$AGENT_GATES_DIR/hooks/git"
  cp "$SCRIPT_DIR/../bin/agent-gates-hooks-sync" "$AGENT_GATES_DIR/bin/"
  cp "$SCRIPT_DIR/../hooks/git/gate-shim.sh" "$AGENT_GATES_DIR/hooks/git/"
  out=$(bash "$STATUS" --no-network --full "$PROJ" 2>&1)
  row=$(proj_row "$out")
  assert "⛔ projects 行不得说 all current (行: ${row:-<空>})" "$([[ "$row" != *"all current"* ]] && echo true || echo false)"
  assert "projects 行体现 foreign/未触碰" "$([[ "$row" == *跳过* || "$row" == *foreign* || "$row" == *hooks-sync* ]] && echo true || echo false)"
  rm -rf "$PROJ"; teardown )

echo "O11: 只是 base hook 丢执行位时，不得误报成「缺 pre-merge-commit」"
# HS_N 读的是总「待补」，它同时含 fix-mode 项；把它硬贴成「缺 pre-merge-commit」
# 会在 base hook 丢执行位时给出错误诊断。
( setup
  PROJ=$(mktemp -d); mkdir -p "$PROJ/p1/.githooks"; git -C "$PROJ/p1" init -q 2>/dev/null
  printf '#!/usr/bin/env bash\n# agent-gates per-project gate shim\nexit 0\n' > "$PROJ/p1/.githooks/pre-commit"
  cp "$SCRIPT_DIR/../hooks/git/gate-shim.sh" "$PROJ/p1/.githooks/pre-merge-commit"
  chmod 644 "$PROJ/p1/.githooks/pre-commit"; chmod +x "$PROJ/p1/.githooks/pre-merge-commit"
  git -C "$PROJ/p1" config core.hooksPath .githooks
  mkdir -p "$AGENT_GATES_DIR/bin" "$AGENT_GATES_DIR/hooks/git"
  cp "$SCRIPT_DIR/../bin/agent-gates-hooks-sync" "$AGENT_GATES_DIR/bin/"
  cp "$SCRIPT_DIR/../hooks/git/gate-shim.sh" "$AGENT_GATES_DIR/hooks/git/"
  out=$(bash "$STATUS" --no-network --full "$PROJ" 2>&1)
  row=$(proj_row "$out")
  assert "⛔ 不谎称缺 pre-merge-commit (行: ${row:-<空>})" "$([[ "$row" != *"缺 pre-merge-commit"* ]] && echo true || echo false)"
  assert "projects 行仍标为需处理" "$([[ "$row" != *"all current"* ]] && echo true || echo false)"
  rm -rf "$PROJ"; teardown )

echo
read -r P F < "$RESULTS_FILE"
echo "=== PASS=$P FAIL=$F ==="
rm -f "$RESULTS_FILE"
[[ "$F" -eq 0 ]]
