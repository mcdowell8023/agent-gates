#!/usr/bin/env bash
# Static checks over the shipped shell scripts — for defect CLASSES, not single instances.
#
# WHY (2026-09-01): `echo "申报 $VAR，推导"` dies with `unbound variable` (exit 127) under a
# UTF-8 locale, because bash extends the variable name into the first byte of the CJK comma —
# and it does so even when VAR is set. Under LC_ALL=C the same line works.
#
# That locale dependence is why it shipped: this session had standardised on
# `LC_ALL=C bash tests/...` (added to dodge an unrelated `sed: illegal byte sequence`), and
# under LC_ALL=C the bug is invisible. A test of the one affected message would not have
# caught it either — it passed, mutation and all, because the harness set LC_ALL=C.
#
# So the check is static and locale-independent: no `$NAME` may be immediately followed by a
# non-ASCII byte anywhere in a shipped script. Braces (`${NAME}`) are the fix and are always
# safe.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
RESULTS_FILE=$(mktemp); echo "0 0" > "$RESULTS_FILE"

assert() {
  local name="$1" cond="$2" p f
  read -r p f < "$RESULTS_FILE"
  if [[ "$cond" == "true" ]]; then echo "  ✓ $name"; echo "$((p+1)) $f" > "$RESULTS_FILE"
  else echo "  ✗ $name"; echo "$p $((f+1))" > "$RESULTS_FILE"; fi
}

# Everything executable in the repo, tests INCLUDED.
#
# The first version excluded tests/ with the reasoning "they run under a controlled harness".
# Within minutes that exemption let the identical bug through in tests/run-all.sh — the
# exemption's own justification was what hid it. Test scripts are run by agents and CI too;
# there is no controlled harness that makes a bash parse error harmless.
targets() {
  cd "$ROOT" || return 1
  find bin lib hooks tests -type f 2>/dev/null
  ls doctor.sh install.sh uninstall.sh 2>/dev/null
}

echo "=== shell lint (defect classes) ==="
echo

echo "L1: ⭐ 禁止 \$NAME 紧跟非 ASCII 字节（UTF-8 locale 下会 unbound variable 退出 127）"
# ⚠️ 用 python 而不是 grep -P：macOS 自带 BSD grep 不支持 -P，命中会静默变成 0，
# 这条 lint 就成了永远通过的装饰。第一版正是这样 —— 自检用例当场把它抓了出来。
scan_bad() {  # scan_bad <file...> ; 输出 "文件:行号: 内容"
  python3 -c '
import re, sys
pat = re.compile(rb"\$[A-Za-z_][A-Za-z_0-9]*[\x80-\xff]")
for path in sys.argv[1:]:
    try:
        with open(path, "rb") as fh:
            for i, line in enumerate(fh, 1):
                if line.lstrip().startswith(b"#"):
                    continue          # 注释不执行；规则本身要能被文字描述
                if pat.search(line):
                    sys.stdout.write("%s:%d: %s" % (path, i, line.decode("utf-8", "replace")))
    except OSError:
        pass
' "$@"
}
BAD=$(cd "$ROOT" && scan_bad $(targets) 2>/dev/null)
assert "无命中${BAD:+ —— 命中如下:
$BAD}" "$([[ -z "${BAD//[[:space:]]/}" ]] && echo true || echo false)"

echo "L2: 自检——这条 lint 真的能抓到（在临时副本上注入）"
TMPD=$(mktemp -d)
# 坏模式一律拼出来，不写成字面量：写成字面量会让本文件被自己的 lint 命中，
# 而给自己开豁免正是上一次漏掉同类 bug 的原因。
CJK_COMMA=$(printf '\xef\xbc\x8c')
{ printf '#!/usr/bin/env bash\nV=x\n'; printf 'echo "a $V%s b"\n' "$CJK_COMMA"; } > "$TMPD/bad.sh"
n=$(scan_bad "$TMPD/bad.sh" | wc -l | tr -d ' ')
assert "注入的坏写法被命中 (实际 $n)" "$([[ "$n" -ge 1 ]] && echo true || echo false)"
{ printf '#!/usr/bin/env bash\nV=x\n'; printf 'echo "a ${V}%s b"\n' "$CJK_COMMA"; } > "$TMPD/good.sh"
n=$(scan_bad "$TMPD/good.sh" | wc -l | tr -d ' ')
assert "加花括号后不命中 (实际 $n)" "$([[ "$n" -eq 0 ]] && echo true || echo false)"
# 用拼接而不是字面量写这个 fixture：直接写出坏模式会让本文件被自己的 lint 命中，
# 而那是一段字符串、不是可执行代码 —— 一个纯粹的假失败。
CJK_COMMA=$(printf '\xef\xbc\x8c')
{ printf '#!/usr/bin/env bash\n'; printf '# comment with $V%s tail\n' "$CJK_COMMA"; } > "$TMPD/cmt.sh"
n=$(scan_bad "$TMPD/cmt.sh" | wc -l | tr -d ' ')
assert "注释里的同样写法不命中 (实际 $n)" "$([[ "$n" -eq 0 ]] && echo true || echo false)"
rm -rf "$TMPD"

echo "L3: ⭐ 实测确认这确实是 locale 依赖的（不是理论）"
: "${CJK_COMMA:=$(printf '\xef\xbc\x8c')}"
# 挑一个本机真的有的 UTF-8 locale。写死 en_US.UTF-8 在很多 Linux/CI 上不存在，
# L3 会因为环境缺 locale 而失败 —— 那是假失败，报的不是代码问题。
UTF8_LOC=""
for L in C.UTF-8 en_US.UTF-8 en_US.utf8 C.utf8; do
  if LC_ALL="$L" bash -c 'true' 2>/dev/null && [[ "$(LC_ALL="$L" locale charmap 2>/dev/null)" == *UTF*8* ]]; then UTF8_LOC="$L"; break; fi
done
if [[ -z "$UTF8_LOC" ]]; then
  assert "跳过（本机没有可用的 UTF-8 locale，无法测该分支）" "true"
  u="rc=127"   # 使下面的断言语义保持一致
else
_BAD_SNIP='set -uo pipefail; V=x; echo "a $V'"$CJK_COMMA"'b"'
u=$(LC_ALL="$UTF8_LOC" bash -c "$_BAD_SNIP" 2>&1; echo "rc=$?")
c=$(LC_ALL=C bash -c "$_BAD_SNIP" 2>&1; echo "rc=$?")
assert "UTF-8 locale 下失败" "$([[ "$u" == *"rc=127"* || "$u" == *unbound* ]] && echo true || echo false)"
assert "⚠️ LC_ALL=C 下反而通过 —— 这就是它能上线的原因" "$([[ "$c" == *"rc=0"* ]] && echo true || echo false)"
fi

echo "L4: 所有 shell 脚本语法正确"
SYNTAX_BAD=""
while IFS= read -r f; do
  [[ -z "$f" || ! -f "$ROOT/$f" ]] && continue
  case "$f" in *.mjs|*.js|*.json|*.md) continue ;; esac
  head -1 "$ROOT/$f" | grep -q 'bash\|sh' || continue
  bash -n "$ROOT/$f" 2>/dev/null || SYNTAX_BAD="$SYNTAX_BAD $f"
done < <(targets)
assert "无语法错误${SYNTAX_BAD:+ —— 出错:$SYNTAX_BAD}" "$([[ -z "${SYNTAX_BAD// /}" ]] && echo true || echo false)"

echo
read -r P F < "$RESULTS_FILE"
echo "=== PASS=$P FAIL=$F ==="
rm -f "$RESULTS_FILE"
[[ "$F" -eq 0 && "$P" -gt 0 ]]
