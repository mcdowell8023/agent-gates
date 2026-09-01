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

# Files we ship and that agents execute. Tests are excluded on purpose: they run under a
# controlled harness, and holding them to the same bar would add noise without protecting
# anyone.
targets() {
  cd "$ROOT" || return 1
  find bin lib hooks -type f 2>/dev/null
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
printf '#!/usr/bin/env bash\nV=x\necho "申报 $V，推导"\n' > "$TMPD/bad.sh"
n=$(scan_bad "$TMPD/bad.sh" | wc -l | tr -d ' ')
assert "注入的坏写法被命中 (实际 $n)" "$([[ "$n" -ge 1 ]] && echo true || echo false)"
printf '#!/usr/bin/env bash\nV=x\necho "申报 ${V}，推导"\n' > "$TMPD/good.sh"
n=$(scan_bad "$TMPD/good.sh" | wc -l | tr -d ' ')
assert "加花括号后不命中 (实际 $n)" "$([[ "$n" -eq 0 ]] && echo true || echo false)"
printf '#!/usr/bin/env bash\n# 注释里写 $V，也不该命中\n' > "$TMPD/cmt.sh"
n=$(scan_bad "$TMPD/cmt.sh" | wc -l | tr -d ' ')
assert "注释里的同样写法不命中 (实际 $n)" "$([[ "$n" -eq 0 ]] && echo true || echo false)"
rm -rf "$TMPD"

echo "L3: ⭐ 实测确认这确实是 locale 依赖的（不是理论）"
u=$(LC_ALL=en_US.UTF-8 bash -c 'set -uo pipefail; V=x; echo "a $V，b"' 2>&1; echo "rc=$?")
c=$(LC_ALL=C bash -c 'set -uo pipefail; V=x; echo "a $V，b"' 2>&1; echo "rc=$?")
assert "UTF-8 locale 下失败" "$([[ "$u" == *"rc=127"* || "$u" == *unbound* ]] && echo true || echo false)"
assert "⚠️ LC_ALL=C 下反而通过 —— 这就是它能上线的原因" "$([[ "$c" == *"rc=0"* ]] && echo true || echo false)"

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
