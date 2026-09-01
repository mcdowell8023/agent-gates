#!/usr/bin/env bash
# Tests for CHECK 6's requirement-matrix enforcement inside the gate.
#
# WHY the matrix is demanded on STRICT BRANCHES ONLY, not by mode:
# the default mode is strict, so keying the requirement off the mode would make the very
# next commit in every already-deployed repo fail for lack of a matrix — a regression
# dressed up as a feature. Keying it off the strict branch matches what was actually
# asked for ("只关注合并到 test 或者 master 要求审查通过") and its blast radius is the
# boundary where the whole requirement is supposed to be finished anyway.
#
# On a feature branch a matrix is still parsed if present, and its findings printed. Free
# signal, no blocking: a partial requirement is the normal state there.
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
sha() { if command -v sha256sum >/dev/null 2>&1; then sha256sum | cut -d' ' -f1; else shasum -a 256 | cut -d' ' -f1; fi; }

setup() {
  REPO=$(mktemp -d); cd "$REPO" || exit 1
  git init -q; git config user.email t@t.com; git config user.name T
  mkdir -p migration src .agent/verify .agent/reviews .agent/plans
  echo init > migration/001.sql
  echo "<template><div/></template>" > src/List.vue
  git add -A; git commit -q -m init
  git checkout -q -b feat/work
  export AGENT_MODE=1
  for i in $(seq 1 25); do echo "ALTER TABLE t$i ADD c INT;" >> migration/002.sql; done
  echo "-- second" > migration/003.sql
  git add migration/002.sql migration/003.sql
  AGENT_GATES_DIR=$(mktemp -d); export AGENT_GATES_DIR
  unset AGENT_GATES_MODE
  cat > .agent/plans/req.md <<'EOF'
# 导出功能

## 验收标准
- 表格支持关键词搜索
- 支持导出全部内容为 CSV
EOF
}
teardown() { cd /; [[ -n "${REPO:-}" && -d "$REPO" ]] && rm -rf "$REPO"; rm -rf "${AGENT_GATES_DIR:-}"; }
on_strict() { git checkout -q -b master 2>/dev/null || git symbolic-ref HEAD refs/heads/master; }

# seed_verify <verdict> [matrix-body]
seed_verify() {
  local rid="20260901-100000-aaa" cur
  cur=$(git diff --cached -- ':!.agent/verify' | sha)
  { printf 'reviewed\n\nVERIFY_VERDICT: %s\n' "$1"
    [[ -n "${2:-}" ]] && printf 'REQ_SOURCE: .agent/plans/req.md\n%s\n' "$2"
  } > ".agent/verify/${rid}.md"
  printf '{"verify_run_id":"%s","channel":"pi","capability":"FULL","staged_diff_hash":"%s","HEAD":"%s"}\n' \
    "$rid" "$cur" "$(git rev-parse HEAD)" > ".agent/verify/${rid}.dispatch.json"
}
write_user_cfg() { printf '%s\n' "$1" > "$AGENT_GATES_DIR/gates.json"; }
run_gate() { SKIP_REVIEW=1 SKIP_PLAN_CHECK=1 bash "$GATE" 2>&1; }

MATRIX_OK='REQ_ITEM: 1 | COVERED | db:migration/002.sql:1, ui:~src/List.vue:1 | 搜索已接
REQ_ITEM: 2 | COVERED | db:migration/003.sql:1, ui:~src/List.vue:1 | 导出已接'

echo "=== gate requirement-matrix tests ==="
echo

echo "R0: 前置——确认走到了 CHECK 6，而不是被前面的检查早退"
# A passing check is SILENT, so asserting on success text proves nothing. Negate the
# known early exits instead.
( setup; on_strict; seed_verify PASS "$MATRIX_OK"
  out=$(run_gate)
  assert "未因 AGENT_MODE 早退" "$([[ -n "$out" ]] && echo true || echo false)"
  assert "未被 trivial 豁免" "$([[ "$out" != *"trivial"* ]] && echo true || echo false)"
  assert "verify 未被 off/merge-only 跳过" "$([[ "$out" != *"CHECK 6 skipped"* ]] && echo true || echo false)"
  teardown )

echo "R1: ⭐ strict 分支 + verify 产物无矩阵 → 拦住并点明缺矩阵"
( setup; on_strict; seed_verify PASS
  out=$(run_gate); rc=$?
  assert "拦住 (rc=$rc)" "$([[ $rc -ne 0 ]] && echo true || echo false)"
  assert "点明缺需求矩阵" "$([[ "$out" == *REQ_ITEM* ]] && echo true || echo false)"
  teardown )

echo "R2: 特性分支 + 无矩阵 → 放行（向后兼容，不能让已部署仓库下一次提交全撞墙）"
( setup; seed_verify PASS
  out=$(run_gate); rc=$?
  assert "放行 (rc=$rc)" "$([[ $rc -eq 0 ]] && echo true || echo false)"
  teardown )

echo "R3: strict 分支 + 完整矩阵、条数对上、引用合法 → 放行"
( setup; on_strict; seed_verify PASS "$MATRIX_OK"
  out=$(run_gate); rc=$?
  assert "放行 (rc=$rc)" "$([[ $rc -eq 0 ]] && echo true || echo false)"
  teardown )

echo "R4: ⭐ 矩阵里有 MISSING → 拦住（这就是要抓的漏做）"
( setup; on_strict
  seed_verify FAIL 'REQ_ITEM: 1 | COVERED | db:migration/002.sql:1, ui:~src/List.vue:1 | 搜索已接
REQ_ITEM: 2 | MISSING | - | 导出接口没写，前端无导出入口'
  out=$(run_gate); rc=$?
  assert "拦住 (rc=$rc)" "$([[ $rc -ne 0 ]] && echo true || echo false)"
  # Without this, the case passes vacuously: seed_verify declared FAIL, so the pre-existing
  # verdict branch blocks it and the matrix is never consulted. Assert the matrix ran.
  assert "矩阵路径确实执行了（打出 MISSING 计数）" "$([[ "$out" == *"MISSING=1"* ]] && echo true || echo false)"
  teardown )

echo "R5: ⭐ 条数少于需求源 → 拦住并说清缺哪条（静默丢条目的唯一防线）"
( setup; on_strict
  seed_verify PASS 'REQ_ITEM: 1 | COVERED | db:migration/002.sql:1, ui:~src/List.vue:1 | 只写了一条'
  out=$(run_gate); rc=$?
  assert "拦住 (rc=$rc)" "$([[ $rc -ne 0 ]] && echo true || echo false)"
  assert "点出需求源 2 条" "$([[ "$out" == *"2 条"* || "$out" == *" 2 "* ]] && echo true || echo false)"
  assert "点出漏掉的需求原文" "$([[ "$out" == *"导出全部内容"* ]] && echo true || echo false)"
  teardown )

echo "R6: ⭐ COVERED 引用未改动的既有文件（指鹿为马）→ 拦住"
( setup; on_strict
  seed_verify PASS 'REQ_ITEM: 1 | COVERED | ui:src/List.vue:1 | 没加 ~，冒充本次改动
REQ_ITEM: 2 | COVERED | db:migration/003.sql:1 | 真改过'
  out=$(run_gate); rc=$?
  assert "拦住 (rc=$rc)" "$([[ $rc -ne 0 ]] && echo true || echo false)"
  assert "提示改用 ~ 写法" "$([[ "$out" == *"~"* ]] && echo true || echo false)"
  teardown )

echo "R7: ⭐ 申报 PASS 但有 MISSING → 采用推导的 FAIL"
( setup; on_strict
  seed_verify PASS 'REQ_ITEM: 1 | COVERED | db:migration/002.sql:1 | 做了
REQ_ITEM: 2 | MISSING | - | 没做但我申报 PASS'
  out=$(run_gate); rc=$?
  assert "拦住 (rc=$rc)" "$([[ $rc -ne 0 ]] && echo true || echo false)"
  # ⭐ 只断言 rc≠0 是空过：门禁在这条消息里因 `$VAR，` 未加花括号而 unbound variable
  # 退出 127，同样满足 rc≠0。必须断言这条消息真的打印出来了。
  assert "⭐ 打印出申报与推导的差异" "$([[ "$out" == *"按矩阵推导为"* ]] && echo true || echo false)"
  assert "⛔ 没有 unbound variable 崩溃" "$([[ "$out" != *"unbound variable"* ]] && echo true || echo false)"
  teardown )

echo "R8: 零 ui: 证据 → 打印告警（纵向漏层的信号）"
( setup; on_strict
  seed_verify PASS 'REQ_ITEM: 1 | COVERED | db:migration/002.sql:1 | 只有后端
REQ_ITEM: 2 | COVERED | db:migration/003.sql:1 | 只有后端'
  out=$(run_gate)
  assert "输出提到无用户入口证据" "$([[ "$out" == *"用户入口"* || "$out" == *NO_UI* ]] && echo true || echo false)"
  teardown )

echo "R9: verify.require_matrix=false → strict 分支上也不强制（留逃生门）"
( setup; on_strict; write_user_cfg '{"verify":{"require_matrix":false}}'; seed_verify PASS
  out=$(run_gate); rc=$?
  assert "放行 (rc=$rc)" "$([[ $rc -eq 0 ]] && echo true || echo false)"
  teardown )

echo "R10: verify.require_matrix=true → 特性分支上也强制（可主动加严）"
( setup; write_user_cfg '{"verify":{"require_matrix":true}}'; seed_verify PASS
  out=$(run_gate); rc=$?
  assert "拦住 (rc=$rc)" "$([[ $rc -ne 0 ]] && echo true || echo false)"
  teardown )

echo "R11: 特性分支 + 矩阵有 MISSING → 放行但打印（免费信号，不阻断迭代）"
( setup
  seed_verify PASS 'REQ_ITEM: 1 | COVERED | db:migration/002.sql:1 | 做了
REQ_ITEM: 2 | MISSING | - | 还没做'
  out=$(run_gate); rc=$?
  assert "放行 (rc=$rc)" "$([[ $rc -eq 0 ]] && echo true || echo false)"
  assert "但把 MISSING 打出来" "$([[ "$out" == *MISSING* ]] && echo true || echo false)"
  teardown )

echo "R12: ⭐ 需求只放在深层 features/ 子目录 → 仍要被发现（否则放深一层就绕过了）"
( setup; on_strict
  rm -f .agent/plans/req.md
  mkdir -p features/api/admin
  cat > features/api/admin/export.feature <<'EOF'
Feature: 导出
  Scenario: 搜索后导出
    Given 有数据
  Scenario: 空结果导出
    Given 无数据
EOF
  seed_verify PASS
  out=$(run_gate); rc=$?
  # gpt-5.4 实测复现过这个绕过：maxdepth 2 时 gate 报「找不到需求文档」然后 PASSED。
  assert "拦住 (rc=$rc)" "$([[ $rc -ne 0 ]] && echo true || echo false)"
  assert "⛔ 不能报「找不到需求文档」" "$([[ "$out" != *"找不到带"* ]] && echo true || echo false)"
  teardown )

echo "R13: 确实没有任何需求源 → 明说未启用，不阻断（auto 档的向后兼容）"
( setup; on_strict
  rm -f .agent/plans/req.md
  seed_verify PASS
  out=$(run_gate); rc=$?
  assert "放行 (rc=$rc)" "$([[ $rc -eq 0 ]] && echo true || echo false)"
  assert "明说未启用并给出启用方法" "$([[ "$out" == *"未启用需求遗漏检查"* && "$out" == *"验收标准"* ]] && echo true || echo false)"
  teardown )

echo "R14: ⭐ REQ_BLOCK_SHA256 被篡改 → 拦住（否则这个字段是死的）"
( setup; on_strict
  seed_verify PASS "REQ_BLOCK_SHA256: deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef
$MATRIX_OK"
  out=$(run_gate); rc=$?
  assert "拦住 (rc=$rc)" "$([[ $rc -ne 0 ]] && echo true || echo false)"
  assert "点明是需求条目块变了" "$([[ "$out" == *"REQ_BLOCK_SHA256"* || "$out" == *"需求条目"* ]] && echo true || echo false)"
  teardown )

echo "R15: REQ_BLOCK_SHA256 正确 → 放行"
( setup; on_strict
  H=$( source "$SCRIPT_DIR/../lib/verify/reqmatrix.sh"; reqmatrix_block_hash .agent/plans/req.md )
  seed_verify PASS "REQ_BLOCK_SHA256: $H
$MATRIX_OK"
  out=$(run_gate); rc=$?
  assert "放行 (rc=$rc)" "$([[ $rc -eq 0 ]] && echo true || echo false)"
  teardown )

echo "R16: ⭐ 收割后改写需求条目文字（条数不变）→ 哈希失配抓住"
( setup; on_strict
  H=$( source "$SCRIPT_DIR/../lib/verify/reqmatrix.sh"; reqmatrix_block_hash .agent/plans/req.md )
  seed_verify PASS "REQ_BLOCK_SHA256: $H
$MATRIX_OK"
  # 条数仍是 2，所以 count 检查过得去；只有哈希能发现条目被改写
  python3 - <<'PYEOF'
import pathlib
p = pathlib.Path('.agent/plans/req.md')
s = p.read_text()
s = s.replace("- 支持导出全部内容为 CSV", "- 支持导出当前页内容为 CSV")
p.write_text(s)
PYEOF
  out=$(run_gate); rc=$?
  assert "拦住 (rc=$rc)" "$([[ $rc -ne 0 ]] && echo true || echo false)"
  assert "⛔ 不是靠条数（条数没变）" "$([[ "$out" != *"条目数与需求源不符"* ]] && echo true || echo false)"
  teardown )

echo "R17: 没写 REQ_BLOCK_SHA256 的矩阵 → 不因此拦（旧产物向后兼容），但要提示"
( setup; on_strict; seed_verify PASS "$MATRIX_OK"
  out=$(run_gate); rc=$?
  assert "放行 (rc=$rc)" "$([[ $rc -eq 0 ]] && echo true || echo false)"
  teardown )


echo
read -r P F < "$RESULTS_FILE"
echo "=== PASS=$P FAIL=$F ==="
rm -f "$RESULTS_FILE"
[[ "$F" -eq 0 ]]
