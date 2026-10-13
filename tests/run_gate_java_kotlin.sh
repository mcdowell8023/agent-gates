#!/usr/bin/env bash
# Gate 1 对 Java / Kotlin 的测试文件名推算（v2.11.1）。
#
# 🔴 背景（2026-10-12，wb 会话 fa5cdf48 报：order-service 合并被拦「Java 源码没有对应测试」）：
#   t1=$(echo "$f" | sed 's|/main/|/test/|;s|\.\(java\|kt\)$|Test.\1|')
# 用 `|` 当分隔符时，`\|` 是**字面竖线**而不是「或」—— BSD sed（macOS）和 GNU sed（Linux）都一样，
# 所以第二段替换从不命中，推出的是 src/test/.../Foo.java（没有 Test 后缀）。
# 自 2026-05-21 首版起，Java / Kotlin 的 Gate 1 从没正确工作过；仓库里也没有任何 Java 用例，
# 所以一直没被发现。
# 契约：
#   · src/main/java/.../Foo.java  ⇒ 期望 src/test/java/.../FooTest.java（Kotlin 同理，FooTest.kt）
#   · 有 FooTest.* ⇒ 放行；没有 ⇒ 拦，提示里写的是 FooTest.*
#   · src/test/.../Foo.java（没有 Test 后缀）不算测试
#   · 路径里没有 /main/ ⇒ 期望同目录 FooTest.*。原来推算结果就是源文件自己，永远「存在」，
#     这类布局的 Gate 1 实际从未检查过 —— 修复后会开始检查
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

# ⚠️ 子 shell 里的 cd 带不回来：只回显路径，调用方显式 cd。
mkrepo() {
  local d; d=$(mktemp -d); ( cd "$d"
  git init -q -b feat .; git config user.email t@t; git config user.name t
  printf 'x\n' > README.md; git add . && git commit -q -m init ) >/dev/null 2>&1
  echo "$d"
}
put() {   # put <path> <content>
  mkdir -p "$(dirname "$1")"; printf '%s\n' "$2" > "$1"
}
GD=$(mktemp -d); printf '{"level":"L0"}\n' > "$GD/review-capability.json"
gate() { AGENT_MODE=1 AGENT_GATES_DIR="$GD" bash "$GATE" 2>&1; }
ORIG=$PWD

echo "=== ① Maven 布局：有 FooTest.java ⇒ 放行 ==="
R=$(mkrepo); cd "$R"
put src/main/java/com/wb/InnerYardiGuestController.java 'class InnerYardiGuestController {}'
put src/test/java/com/wb/InnerYardiGuestControllerTest.java 'class InnerYardiGuestControllerTest {}'
git add src; out=$(gate); rc=$?
assert "⭐ 不再报缺测试（实际 ${rc}）" "$([[ "$out" != *"No test for"* ]] && echo true || echo false)"
assert "放行" "$([[ $rc -eq 0 ]] && echo true || echo false)"
cd "$ORIG"

echo
echo "=== ② 没有测试 ⇒ 拦，提示里是 FooTest.java ==="
R=$(mkrepo); cd "$R"
put src/main/java/com/wb/Foo.java 'class Foo {}'
git add src; out=$(gate); rc=$?
assert "拦住（实际 ${rc}）" "$([[ $rc -ne 0 ]] && echo true || echo false)"
assert "⭐ 期望路径是 src/test/java/com/wb/FooTest.java" "$([[ "$out" == *"expected: src/test/java/com/wb/FooTest.java"* ]] && echo true || echo false)"
cd "$ORIG"

echo
echo "=== ③ src/test/.../Foo.java（无 Test 后缀）不算测试 ==="
R=$(mkrepo); cd "$R"
put src/main/java/com/wb/Foo.java 'class Foo {}'
put src/test/java/com/wb/Foo.java 'class Foo {}'
git add src; out=$(gate); rc=$?
assert "仍然拦（原来的错误期望正好是这个名字，修复后不能再认它）" "$([[ "$out" == *"No test for: src/main/java/com/wb/Foo.java"* ]] && echo true || echo false)"
cd "$ORIG"

echo
echo "=== ④ Kotlin：FooTest.kt ==="
R=$(mkrepo); cd "$R"
put src/main/kotlin/com/wb/Bar.kt 'class Bar'
put src/test/kotlin/com/wb/BarTest.kt 'class BarTest'
git add src; out=$(gate)
assert "有 BarTest.kt ⇒ 放行" "$([[ "$out" != *"No test for"* ]] && echo true || echo false)"
git reset -q; git rm -q --cached -r src >/dev/null 2>&1; rm -f src/test/kotlin/com/wb/BarTest.kt
git add src; out=$(gate)
assert "没有测试 ⇒ 期望 BarTest.kt" "$([[ "$out" == *"expected: src/test/kotlin/com/wb/BarTest.kt"* ]] && echo true || echo false)"
cd "$ORIG"

echo
echo "=== ⑤ 路径里没有 /main/：期望同目录 FooTest.java（原来永远通过，等于没检查）==="
R=$(mkrepo); cd "$R"
put src/com/wb/Baz.java 'class Baz {}'
git add src; out=$(gate); rc=$?
assert "⭐ 没有 BazTest.java ⇒ 拦（实际 ${rc}）" "$([[ $rc -ne 0 && "$out" == *"expected: src/com/wb/BazTest.java"* ]] && echo true || echo false)"
put src/com/wb/BazTest.java 'class BazTest {}'
git add src; out=$(gate); rc=$?
assert "同目录有 BazTest.java ⇒ 放行（实际 ${rc}）" "$([[ $rc -eq 0 ]] && echo true || echo false)"
cd "$ORIG"

echo
echo "=== ⑥ 回归：其它语言的推算不受影响 ==="
R=$(mkrepo); cd "$R"
put src/a.ts 'export const a = 1'
put src/a.test.ts 'test("a", () => {})'
put pkg/mod.py 'x = 1'
put pkg/test_mod.py 'def test_x(): pass'
put cmd/main.go 'package main'
put cmd/main_test.go 'package main'
git add src pkg cmd; out=$(gate)
assert "ts / py / go 有测试 ⇒ 都不报缺测试" "$([[ "$out" != *"No test for"* ]] && echo true || echo false)"
cd "$ORIG"

echo "=== ⑦ Python 的 test_*.py 前缀式测试文件本身不该被要求再有测试 ==="
# 原来的排除名单只有后缀式（_test. / .test.），`test_mod.py` 被当成源文件，要求有 test_test_mod.py。
R=$(mkrepo); cd "$R"
put pkg/mod.py 'x = 1'
put pkg/test_mod.py 'def test_x(): pass'
git add pkg; out=$(gate); rc=$?
assert "⭐ 有 test_mod.py ⇒ 不再报「No test for: pkg/test_mod.py」（实际 ${rc}）" "$([[ "$out" != *"No test for: pkg/test_mod.py"* ]] && echo true || echo false)"
assert "mod.py 有 test_mod.py ⇒ 放行" "$([[ $rc -eq 0 ]] && echo true || echo false)"
git reset -q; git rm -q --cached -r pkg >/dev/null 2>&1; rm -f pkg/mod.py
git add pkg; out=$(gate)
assert "⭐ 只新增一个 test_x.py ⇒ 按小改动跳过，不是被当成新源文件" "$([[ "$out" == *"trivial change skipped"* ]] && echo true || echo false)"
cd "$ORIG"

echo
read -r P F < "$RESULTS_FILE"; rm -f "$RESULTS_FILE"
echo "PASS=$P FAIL=$F"
[[ "$F" -eq 0 ]]
