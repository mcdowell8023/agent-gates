#!/usr/bin/env bash
# Tests for anchor extraction in CHECK 5.
#
# Failure mode this guards (reported 2026-08-24, reproduced): `shasum` reading stdin prints
# `<hex>  -` — the trailing `-` is a filename placeholder. Pasted straight into an anchor it
# becomes `<!-- REVIEW_DIFF_SHA256: ace451e0...  - -->`, and the extraction sed required
# ` -->$` immediately after the hex ⇒ no match ⇒ empty variable ⇒ the `|| continue` on the
# next line skipped the ENTIRE report. Symptom is maximally misleading: the report exists,
# `VERDICT: PASS` is there, the hex is even correct, but the gate acts as if no review
# exists and blocks the commit.
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

# Extract the two sed expressions the gate actually uses, so this test cannot drift from
# the implementation the way a hand-copied regex would.
SED_FILES=$(grep -m1 'rf_files_sha256=\$(sed' "$GATE" | sed 's/.*sed -n .\(.*\). "\$rf".*/\1/')
SED_DIFF=$(grep -m1 'rf_diff_sha256=\$(sed' "$GATE" | sed 's/.*sed -n .\(.*\). "\$rf".*/\1/')
[[ -n "$SED_FILES" && -n "$SED_DIFF" ]] || { echo "  ✗ 无法从 gate 提取 sed 表达式"; echo "=== PASS=0 FAIL=1 ==="; exit 1; }

extract() { # extract <sed-expr> <line>
  printf '%s\n' "$2" | sed -n "$1" | head -1 | tr '[:upper:]' '[:lower:]'
}

HEX=ace451e0b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f60718293a4b5c6d

echo "=== gate anchor extraction tests ==="
echo

echo "A1: 标准锚点"
eq=$(extract "$SED_DIFF" "<!-- REVIEW_DIFF_SHA256: $HEX -->")
assert "标准形式可提取" "$([[ "$eq" == "$HEX" ]] && echo true || echo false)"

echo "A2: ⭐ shasum 的文件名占位 '  - '（报告的实际形态）"
eq=$(extract "$SED_DIFF" "<!-- REVIEW_DIFF_SHA256: $HEX  - -->")
assert "带 '  - ' 占位仍可提取 (得到 '${eq:0:12}...')" "$([[ "$eq" == "$HEX" ]] && echo true || echo false)"

echo "A3: 单空格 + 占位"
eq=$(extract "$SED_DIFF" "<!-- REVIEW_DIFF_SHA256: $HEX - -->")
assert "单空格占位可提取" "$([[ "$eq" == "$HEX" ]] && echo true || echo false)"

echo "A4: hex 后多余空白"
eq=$(extract "$SED_DIFF" "<!-- REVIEW_DIFF_SHA256: $HEX   -->")
assert "尾部空白可提取" "$([[ "$eq" == "$HEX" ]] && echo true || echo false)"

echo "A5: FILES_SHA256 同样处理"
eq=$(extract "$SED_FILES" "<!-- REVIEW_FILES_SHA256: $HEX  - -->")
assert "FILES 带占位可提取" "$([[ "$eq" == "$HEX" ]] && echo true || echo false)"

echo "A6: 大写 hex 归一化为小写"
UP=$(printf '%s' "$HEX" | tr '[:lower:]' '[:upper:]')
eq=$(extract "$SED_DIFF" "<!-- REVIEW_DIFF_SHA256: $UP -->")
assert "大写归一" "$([[ "$eq" == "$HEX" ]] && echo true || echo false)"

echo "A7: ⛔ 非 hex 内容不得被当成 hash（放宽不能放过垃圾）"
eq=$(extract "$SED_DIFF" "<!-- REVIEW_DIFF_SHA256: not-a-hash-at-all -->")
assert "非法内容不匹配 (得到 '${eq}')" "$([[ -z "$eq" || "$eq" == "not" ]] && echo true || echo false)"

echo "A8: ⛔ 缺 hex 时不得返回非空"
eq=$(extract "$SED_DIFF" "<!-- REVIEW_DIFF_SHA256:  - -->")
assert "空 hex 不产出内容" "$([[ -z "$eq" ]] && echo true || echo false)"

echo
read -r P F < "$RESULTS_FILE"
echo "=== PASS=$P FAIL=$F ==="
rm -f "$RESULTS_FILE"
[[ "$F" -eq 0 ]]
