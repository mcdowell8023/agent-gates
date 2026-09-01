#!/usr/bin/env bash
# Tests for gate modes: strict / relaxed / off, plus the strict-branch override.
#
# Why (2026-09-01): review had become the bottleneck rather than development — one change
# went through five rounds. The gate treated every commit on a feature branch with the same
# severity as a merge into test/master, so iteration paid the full price every time.
#
# The model: be permissive while iterating on a feature branch, strict at the boundary where
# work enters an integration branch.
#
#   strict   (default)  today's behaviour — verdicts enforced
#   relaxed             evidence must EXIST (reviewed once) but the verdict is not enforced
#   off                 no checks, and it says so loudly — never silently
#
#   strict_branches     on these branches, and on merges INTO them, strict is forced
#                       regardless of configuration
#
# ⚠️ relaxed is not "off". "Reviewed once, outcome not enforced" still requires a review to
# have happened and to be anchored to this diff — otherwise the two modes would be the same
# thing with different names.
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

# A change big enough to clear the trivial exemption, on a high-risk path so CHECK 6 runs.
setup() {
  REPO=$(mktemp -d); cd "$REPO" || exit 1
  git init -q; git config user.email t@t.com; git config user.name T
  mkdir -p migration .agent/verify .agent/reviews .agent/plans
  echo init > migration/001.sql; git add -A; git commit -q -m init
  # Must be on a NON-strict branch: the default strict_branches include main/master, and
  # `git init` lands on one of them — otherwise every case gets forced to strict and the
  # mode assertions all pass or fail for the wrong reason.
  git checkout -q -b feat/work
  export AGENT_MODE=1
  for i in $(seq 1 25); do echo "ALTER TABLE t$i ADD c INT;" >> migration/002.sql; done
  echo "-- second" > migration/003.sql
  git add migration/002.sql migration/003.sql
  AGENT_GATES_DIR=$(mktemp -d); export AGENT_GATES_DIR
  unset AGENT_GATES_MODE
}
teardown() { cd /; [[ -n "${REPO:-}" && -d "$REPO" ]] && rm -rf "$REPO"; rm -rf "${AGENT_GATES_DIR:-}"; }

# A verify artifact anchored to the current staged diff, with a chosen verdict.
seed_verify() {  # seed_verify <verdict>
  local rid="20260901-100000-aaa" cur
  cur=$(git diff --cached -- ':!.agent/verify' | sha)
  printf 'reviewed\n\nVERIFY_VERDICT: %s\n' "$1" > ".agent/verify/${rid}.md"
  printf '{"verify_run_id":"%s","channel":"pi","capability":"FULL","staged_diff_hash":"%s","HEAD":"%s"}\n' \
    "$rid" "$cur" "$(git rev-parse HEAD)" > ".agent/verify/${rid}.dispatch.json"
}
write_user_cfg()    { printf '%s\n' "$1" > "$AGENT_GATES_DIR/gates.json"; }
write_project_cfg() { printf '%s\n' "$1" > .agent/gates.json; }
run_gate() { SKIP_REVIEW=1 bash "$GATE" 2>&1; }

echo "=== gate mode tests ==="
echo

echo "G0: 前置——fixture 必须落在非 strict 分支（否则模式断言全部无意义）"
( setup
  b=$(git rev-parse --abbrev-ref HEAD)
  assert "分支是 feat/work (实际 $b)" "$([[ "$b" == "feat/work" ]] && echo true || echo false)"
  out=$(run_gate)
  assert "未被 strict_branches 强制覆盖" "$([[ "$out" != *"forced to strict"* ]] && echo true || echo false)"
  teardown )

echo "G1: 无配置 → strict（保持现状行为）"
( setup
  out=$(run_gate); rc=$?
  assert "无 verify 产物时仍然拦住 (rc=$rc)" "$([[ $rc -ne 0 ]] && echo true || echo false)"
  assert "不声称自己是 relaxed" "$([[ "$out" != *relaxed* ]] && echo true || echo false)"
  teardown )

echo "G2: 用户级 gates.json mode=relaxed → 生效"
( setup; write_user_cfg '{"mode":"relaxed"}'
  out=$(run_gate)
  assert "输出标明 relaxed" "$([[ "$out" == *relaxed* || "$out" == *RELAXED* ]] && echo true || echo false)"
  teardown )

echo "G3: 项目级 .agent/gates.json 覆盖用户级"
( setup; write_user_cfg '{"mode":"off"}'; write_project_cfg '{"mode":"relaxed"}'
  out=$(run_gate)
  assert "取项目级 relaxed 而非用户级 off" "$([[ "$out" == *relaxed* || "$out" == *RELAXED* ]] && echo true || echo false)"
  teardown )

echo "G4: env AGENT_GATES_MODE 覆盖两层配置"
( setup; write_user_cfg '{"mode":"relaxed"}'; write_project_cfg '{"mode":"relaxed"}'
  out=$(AGENT_GATES_MODE=strict run_gate); rc=$?
  assert "env=strict 生效，仍然拦 (rc=$rc)" "$([[ $rc -ne 0 ]] && echo true || echo false)"
  teardown )

echo "G5: off → 放行，但必须明说（不许静默）"
( setup; write_user_cfg '{"mode":"off"}'
  out=$(run_gate); rc=$?
  assert "exit 0 (实际 $rc)" "$([[ $rc -eq 0 ]] && echo true || echo false)"
  assert "输出明说门禁被关闭" "$([[ "$out" == *DISABLED* || "$out" == *disabled* || "$out" == *关闭* ]] && echo true || echo false)"
  assert "指出配置来源，便于排查" "$([[ "$out" == *gates.json* ]] && echo true || echo false)"
  teardown )

echo "G6: ⭐ relaxed + 有产物但 verdict=FAIL → 放行并警告（审一次，不看结果）"
( setup; write_user_cfg '{"mode":"relaxed"}'; seed_verify FAIL
  out=$(run_gate); rc=$?
  assert "exit 0 (实际 $rc)" "$([[ $rc -eq 0 ]] && echo true || echo false)"
  assert "明说是宽松放行而非通过" "$([[ "$out" == *relaxed* || "$out" == *RELAXED* ]] && echo true || echo false)"
  teardown )

echo "G7: ⛔ relaxed + 完全没审过 → 仍然拦（宽松不等于不审）"
( setup; write_user_cfg '{"mode":"relaxed"}'
  out=$(run_gate); rc=$?
  assert "没有任何产物时仍然拦 (rc=$rc)" "$([[ $rc -ne 0 ]] && echo true || echo false)"
  teardown )

echo "G8: ⭐ 当前分支是 strict 分支 → 强制 strict，无视配置"
( setup; write_user_cfg '{"mode":"relaxed","strict_branches":["test","master"]}'
  git checkout -q -b test 2>/dev/null || git symbolic-ref HEAD refs/heads/test
  seed_verify FAIL
  out=$(run_gate); rc=$?
  assert "在 test 分支上 FAIL 仍然拦 (rc=$rc)" "$([[ $rc -ne 0 ]] && echo true || echo false)"
  assert "输出说明被强制为 strict" "$([[ "$out" == *strict* ]] && echo true || echo false)"
  teardown )

echo "G9: merge 到非 strict 分支 → 仍然放行（保持现状，业务分支间合并不卡）"
( setup; write_user_cfg '{"mode":"relaxed","strict_branches":["test","master"]}'
  # 必须是有效 commit SHA：`git rev-parse MERGE_HEAD` 对无效内容直接失败，于是 merge
  # 分支压根不会被走到——G10 那条曾因此「假通过」（它期望拦住，而解析失败也导致拦住）
  git rev-parse HEAD > .git/MERGE_HEAD
  out=$(run_gate); rc=$?
  assert "exit 0 (实际 $rc)" "$([[ $rc -eq 0 ]] && echo true || echo false)"
  teardown )

echo "G10: ⭐ merge 到 strict 分支 → 不再无条件放行"
( setup; write_user_cfg '{"mode":"relaxed","strict_branches":["test","master"]}'
  git checkout -q -b test 2>/dev/null || git symbolic-ref HEAD refs/heads/test
  # 必须是有效 commit SHA：`git rev-parse MERGE_HEAD` 对无效内容直接失败，于是 merge
  # 分支压根不会被走到——G10 那条曾因此「假通过」（它期望拦住，而解析失败也导致拦住）
  git rev-parse HEAD > .git/MERGE_HEAD
  out=$(run_gate); rc=$?
  assert "合并进 test 时门禁生效 (rc=$rc)" "$([[ $rc -ne 0 ]] && echo true || echo false)"
  assert "⭐ 明确是因为 merge 进 strict 分支（而非 MERGE_HEAD 解析失败）" \
    "$([[ "$out" == *"merge into strict branch"* ]] && echo true || echo false)"
  teardown )

# ---- merge-only：小分支上完全不审，只在进集成分支时严格 ----
#
# 需求（2026-09-01）：relaxed 仍要求每次 commit 审一次，迭代时那也是负担。
# merge-only 把审查/验收整体推迟到「工作进入集成分支」那一刻。
# ⚠️ 它只放宽 review/verify，**不放宽** Gate 1（测试文件必须存在）与 CHECK 3（plan）——
# 那两条是写代码时的纪律，跟审查时机无关。

echo "M1: ⭐ merge-only + 小分支 + 零产物 → 放行（审查整体推迟）"
( setup; write_user_cfg '{"mode":"merge-only"}'
  out=$(run_gate); rc=$?
  assert "exit 0 (实际 $rc)" "$([[ $rc -eq 0 ]] && echo true || echo false)"
  assert "输出标明 merge-only" "$([[ "$out" == *merge-only* ]] && echo true || echo false)"
  assert "说明审查被推迟到合并时" "$([[ "$out" == *deferred* || "$out" == *推迟* || "$out" == *merge* ]] && echo true || echo false)"
  teardown )

echo "M2: ⛔ merge-only 不放宽测试文件要求（那是写代码时的纪律）"
( setup; write_user_cfg '{"mode":"merge-only"}'
  # 加一个没有对应测试的源文件——Gate 1 该拦住，与审查时机无关
  mkdir -p src && printf 'export const f = () => 1;\n' > src/thing.ts
  for i in $(seq 1 20); do echo "// pad $i" >> src/thing.ts; done
  git add src/thing.ts
  out=$(run_gate); rc=$?
  assert "缺测试文件仍被拦 (rc=$rc)" "$([[ $rc -ne 0 ]] && echo true || echo false)"
  assert "报的是测试文件而非审查" "$([[ "$out" == *"No test for"* ]] && echo true || echo false)"
  teardown )

echo "M3: merge-only + strict 分支 → 强制 strict（边界上要全面审查）"
( setup; write_user_cfg '{"mode":"merge-only","strict_branches":["test","master"]}'
  git checkout -q -b test 2>/dev/null || git symbolic-ref HEAD refs/heads/test
  out=$(run_gate); rc=$?
  assert "在 test 分支上零产物被拦 (rc=$rc)" "$([[ $rc -ne 0 ]] && echo true || echo false)"
  assert "说明被强制为 strict" "$([[ "$out" == *"forced to strict"* ]] && echo true || echo false)"
  teardown )

echo "M4: merge-only + merge 进 strict 分支 → 门禁生效"
( setup; write_user_cfg '{"mode":"merge-only","strict_branches":["test","master"]}'
  git checkout -q -b test 2>/dev/null || git symbolic-ref HEAD refs/heads/test
  git rev-parse HEAD > .git/MERGE_HEAD
  out=$(run_gate); rc=$?
  assert "合并进 test 时被拦 (rc=$rc)" "$([[ $rc -ne 0 ]] && echo true || echo false)"
  teardown )

# ---- review / verify 独立分级 ----
#
# 审查（看代码）与验收（跑起来）是两件事，严厉度不必一致。
echo "S1: ⭐ review 与 verify 可以各自设级别"
( setup; write_user_cfg '{"mode":"strict","review":{"mode":"merge-only"},"verify":{"mode":"strict"}}'
  out=$(run_gate); rc=$?
  assert "verify 仍严格 → 零产物被拦 (rc=$rc)" "$([[ $rc -ne 0 ]] && echo true || echo false)"
  assert "被拦的是 verify 而非 review" "$([[ "$out" == *erif* ]] && echo true || echo false)"
  teardown )

echo "S2: verify 单独放到 merge-only，review 保持 strict"
( setup; write_user_cfg '{"mode":"strict","verify":{"mode":"merge-only"}}'
  out=$(run_gate)
  assert "输出不再要求 verify 产物" "$([[ "$out" != *"No verifier evidence"* ]] && echo true || echo false)"
  teardown )

echo "S3: 未指定分项时继承总 mode（向后兼容）"
( setup; write_user_cfg '{"mode":"merge-only"}'
  out=$(run_gate); rc=$?
  assert "总 mode 生效于两项 (rc=$rc)" "$([[ $rc -eq 0 ]] && echo true || echo false)"
  teardown )

echo
read -r P F < "$RESULTS_FILE"
echo "=== PASS=$P FAIL=$F ==="
rm -f "$RESULTS_FILE"
[[ "$F" -eq 0 ]]
