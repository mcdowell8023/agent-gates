#!/usr/bin/env bash
# Gate 1（测试文件对应）—— 带后缀的 spec 文件名。
#
# 背景：Gate 1 只认 <name>.test.<ext> / <name>.spec.<ext>。真实项目里大量测试叫
# <name>.public.spec.ts / <name>.e2e.spec.ts / <name>.db.spec.ts —— 测试确实存在，
# 只是文件名带了个语义后缀。Gate 1 把这些一律报成「No test for」，是误报。
#
# ⛔ 放宽的边界（本文件 T4 锁住）：<name>.*.spec.<ext> 不能无条件放行 ——
#    a.b.spec.ts 是 a.b.ts 的测试，不该拿来给「自己没有测试的 a.ts」放行。
#    判据：候选 spec 去掉 .spec.<ext> 后若存在同名源文件，且那个源文件不是当前文件，
#    则该 spec 归属于它，不算作当前文件的测试。

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GATE="$SCRIPT_DIR/../hooks/git/agent-quality-gate.sh"
RESULTS_FILE=$(mktemp)
echo "0 0" > "$RESULTS_FILE"

setup_mock_repo() {
  MOCK_REPO=$(mktemp -d)
  cd "$MOCK_REPO" || exit 1
  git init -q
  git config user.email "test@test.com"; git config user.name "Test"
  echo "init" > README.md; git add README.md; git commit -q -m "init"
  export AGENT_MODE=1
}
teardown_mock_repo() { cd /; [[ -n "${MOCK_REPO:-}" && -d "$MOCK_REPO" ]] && rm -rf "$MOCK_REPO"; }

assert() {
  local name="$1" cond="$2" p f
  read -r p f < "$RESULTS_FILE"
  if [[ "$cond" == "true" ]]; then echo "  ✓ $name"; echo "$((p+1)) $f" > "$RESULTS_FILE"
  else echo "  ✗ $name"; echo "$p $((f+1))" > "$RESULTS_FILE"; fi
}

# 让改动够大，避免走 trivial 快捷路径把 Gate 1 整个跳过
pad() { local file="$1"; for i in $(seq 1 25); do echo "// pad $i" >> "$file"; done; }

# ⚠️ 断言只看 Gate 1 自己的那条消息，⛔ 不看退出码 —— 退出码会被审查/验证等其它
#    检查影响，用它做判据会让本文件在无关改动下变红。
gate_out() { bash "$GATE" 2>&1; }

# T1 🔴 真实误报：intake.service.ts 的测试在 intake.service.public.spec.ts
t1_suffixed_spec_accepted() {
  echo "T1: <name>.public.spec.ts 应当被认作 <name>.ts 的测试"
  ( setup_mock_repo
    mkdir -p src
    echo "export const submitPublic = () => {}" > src/intake.service.ts; pad src/intake.service.ts
    echo "describe('IntakeService.submitPublic', () => {})" > src/intake.service.public.spec.ts
    git add src/intake.service.ts src/intake.service.public.spec.ts
    out=$(gate_out)
    assert "不再报 No test for" "$([[ "$out" != *"No test for"* ]] && echo true || echo false)"
    teardown_mock_repo )
}

# T2 同族：.e2e.spec / .db.spec
t2_other_suffixes_accepted() {
  echo "T2: .e2e.spec.ts / .db.spec.ts 同样被接受"
  ( setup_mock_repo
    mkdir -p src
    echo "export const c = () => {}" > src/community.controller.ts; pad src/community.controller.ts
    echo "describe('c', () => {})" > src/community.controller.e2e.spec.ts
    echo "export const g = () => {}" > src/intake-signature.guard.ts; pad src/intake-signature.guard.ts
    echo "describe('g', () => {})" > src/intake-signature.guard.db.spec.ts
    git add src/
    out=$(gate_out)
    assert "两个带后缀 spec 都被接受" "$([[ "$out" != *"No test for"* ]] && echo true || echo false)"
    teardown_mock_repo )
}

# T3 🔴 反方向：真的没有测试，必须还拦得住
t3_missing_test_still_blocked() {
  echo "T3: 真的没有任何测试 → 仍然拦住（放宽不得变成放行）"
  ( setup_mock_repo
    mkdir -p src
    echo "export const f = () => 1" > src/thing.ts; pad src/thing.ts
    git add src/thing.ts
    out=$(gate_out)
    assert "仍报 No test for" "$([[ "$out" == *"No test for"* ]] && echo true || echo false)"
    assert "报的正是 thing.ts" "$([[ "$out" == *"thing.ts"* ]] && echo true || echo false)"
    teardown_mock_repo )
}

# T4 🔴 过度匹配防护：a.b.spec.ts 属于 a.b.ts，不能给没测试的 a.ts 放行
t4_sibling_spec_does_not_cover_shorter_name() {
  echo "T4: a.b.spec.ts 归 a.b.ts 所有 → 不给自己没测试的 a.ts 放行"
  ( setup_mock_repo
    mkdir -p src
    echo "export const b = () => 1" > src/a.b.ts
    echo "describe('a.b', () => {})" > src/a.b.spec.ts        # 这是 a.b.ts 的测试
    git add src/a.b.ts src/a.b.spec.ts; git commit -q -m "a.b with its own spec"
    echo "export const a = () => 1" > src/a.ts; pad src/a.ts   # a.ts 自己没有测试
    git add src/a.ts
    out=$(gate_out)
    assert "a.ts 仍被拦（不被 a.b.spec.ts 冒领）" "$([[ "$out" == *"No test for"* && "$out" == *"src/a.ts"* ]] && echo true || echo false)"
    teardown_mock_repo )
}

# T5 回归：精确同名仍然通过（原有行为不变）
t5_exact_spec_still_accepted() {
  echo "T5: <name>.spec.ts 精确同名 —— 原行为不变"
  ( setup_mock_repo
    mkdir -p src
    echo "export const b = () => 1" > src/a.b.ts; pad src/a.b.ts
    echo "describe('a.b', () => {})" > src/a.b.spec.ts
    git add src/
    out=$(gate_out)
    assert "精确同名被接受" "$([[ "$out" != *"No test for"* ]] && echo true || echo false)"
    teardown_mock_repo )
}

# T6 🔴 绕过复现（本次放宽自己开的洞）：同一次提交里把 owner 源文件删掉，
#    a.b.spec.ts 就被重新归给 a.ts。判据只查工作区时必然放行。
t6_deleting_owner_must_not_reattribute_spec() {
  echo "T6: 同一 diff 删掉 a.b.ts，a.b.spec.ts 不得改归 a.ts"
  ( setup_mock_repo
    mkdir -p src
    echo "export const b = () => 1" > src/a.b.ts
    echo "describe('a.b', () => {})" > src/a.b.spec.ts
    git add src/a.b.ts src/a.b.spec.ts; git commit -q -m "a.b with its own spec"
    git rm -q src/a.b.ts                                       # ⛔ 同一次提交里删掉 owner
    echo "export const a = () => 1" > src/a.ts; pad src/a.ts    # a.ts 自己没有测试
    git add src/a.ts
    out=$(gate_out)
    assert "a.ts 仍被拦（删 owner 不得洗白）" "$([[ "$out" == *"No test for"* && "$out" == *"src/a.ts"* ]] && echo true || echo false)"
    teardown_mock_repo )
}

# T7 owner 只存在于索引（已 git add，工作区被删）—— 同样不得改归
t7_owner_in_index_only_still_blocks() {
  echo "T7: owner 只在索引里（工作区已删）→ 仍不得改归"
  ( setup_mock_repo
    mkdir -p src
    echo "export const b = () => 1" > src/a.b.ts
    echo "describe('a.b', () => {})" > src/a.b.spec.ts
    git add src/a.b.ts src/a.b.spec.ts
    rm -f src/a.b.ts                                           # 只从工作区删，索引里还在
    echo "export const a = () => 1" > src/a.ts; pad src/a.ts
    git add src/a.ts
    out=$(gate_out)
    assert "a.ts 仍被拦（索引里的 owner 也算数）" "$([[ "$out" == *"No test for"* && "$out" == *"src/a.ts"* ]] && echo true || echo false)"
    teardown_mock_repo )
}

# T8 🔴 非普通文件伪装（放宽引入的第二个洞，gpt-5.6-sol 验收抓到）：
#    原来的精确同名判断用 `[[ -f ... ]]`，天然排除目录；glob 不排除。
#    建一个叫 src/thing.fake.spec.ts 的【目录】，没有测试的 src/thing.ts 就被放行。
t8_directory_disguised_as_spec_rejected() {
  echo "T8: 名字像 spec 的【目录】不算测试"
  ( setup_mock_repo
    mkdir -p src
    echo "export const f = () => 1" > src/thing.ts; pad src/thing.ts
    mkdir -p src/thing.fake.spec.ts          # ⛔ 目录，不是文件
    git add src/thing.ts
    out=$(gate_out)
    assert "目录不得冒充测试" "$([[ "$out" == *"No test for"* && "$out" == *"src/thing.ts"* ]] && echo true || echo false)"
    teardown_mock_repo )
}

t1_suffixed_spec_accepted
t2_other_suffixes_accepted
t3_missing_test_still_blocked
t4_sibling_spec_does_not_cover_shorter_name
t5_exact_spec_still_accepted
t6_deleting_owner_must_not_reattribute_spec
t7_owner_in_index_only_still_blocks
t8_directory_disguised_as_spec_rejected

echo ""
read -r PASS_COUNT FAIL_COUNT < "$RESULTS_FILE"
rm -f "$RESULTS_FILE"
echo "$PASS_COUNT pass · $FAIL_COUNT fail"
[[ "$FAIL_COUNT" -eq 0 ]] && exit 0 || exit 1
