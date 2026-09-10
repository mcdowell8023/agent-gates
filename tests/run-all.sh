#!/usr/bin/env bash
# tests/run-all.sh — run every test file and report one verdict.
#
# WHY (cross-review, 2026-09-01): the repo had 40+ `tests/run_*.sh` and nothing that ran
# them together. `tests/run.sh` only exercises the memory-reminder fixtures. So test content
# was not empty but test WIRING was: a change could land with several suites never executed
# and nothing would show a red light.
#
# Two deliberate choices:
#
#   1. A suite reporting `PASS=0 FAIL=0` counts as FAILED. A fixture that exits early makes
#      a whole file silently run zero assertions, and under a "FAIL=0 means green" rule that
#      reads as success — which happened here (an `unbound variable` in a helper).
#
#   2. LC_ALL is NOT forced. Individual invocations in this session had been prefixed with
#      `LC_ALL=C` (to dodge an unrelated `sed: illegal byte sequence`), and that silently
#      disabled detection of `$VAR<CJK>` bugs, which only fail under a UTF-8 locale. The
#      suite must run in the locale agents actually use.
#
# Usage: tests/run-all.sh [-k <pattern>]     # -k: only files whose name matches
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FILTER=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -k) [[ $# -ge 2 ]] || { echo "-k needs a pattern" >&2; exit 64; }; FILTER="$2"; shift 2 ;;
    -h|--help) sed -n '3,22p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "run-all: unknown arg '$1'" >&2; exit 64 ;;
  esac
done

G='\033[0;32m'; R='\033[0;31m'; Y='\033[1;33m'; N='\033[0m'
files=0; green=0; red=0; empty=0
FAILED_LIST=""

# tests/run.sh is included explicitly: the glob `run_*.sh` excludes it (no underscore), so
# the one pre-existing suite was permanently outside the aggregator that claims to run
# "every test file".
for f in "$SCRIPT_DIR"/run.sh "$SCRIPT_DIR"/run_*.sh; do
  [[ -f "$f" ]] || continue
  base=$(basename "$f")
  [[ -n "$FILTER" && "$base" != *"$FILTER"* ]] && continue
  files=$((files + 1))
  out=$(bash "$f" 2>&1); file_rc=$?
  last=$(printf '%s\n' "$out" | tail -1)
  # Four report shapes exist in this repo. Enumerate them: an unparsed line is treated as a
  # failure below, so a missing shape shows up loudly rather than as a silent skip.
  #   "=== PASS=n FAIL=m ==="
  #   "n pass · m fail"
  #   "Results: n passed, m failed"
  #   "Results: n/m passed"
  p=$(printf '%s' "$last" | sed -n 's/.*PASS=\([0-9]*\).*/\1/p')
  fl=$(printf '%s' "$last" | sed -n 's/.*FAIL=\([0-9]*\).*/\1/p')
  if [[ -z "$p" ]]; then
    p=$(printf '%s' "$last" | sed -n 's/^[^0-9]*\([0-9]*\) pass.*/\1/p')
    fl=$(printf '%s' "$last" | sed -n 's/.*·[^0-9]*\([0-9]*\) fail.*/\1/p')
  fi
  if [[ -z "$p" ]]; then
    p=$(printf '%s' "$last" | sed -n 's/.*Results:[^0-9]*\([0-9]*\) passed.*/\1/p')
    fl=$(printf '%s' "$last" | sed -n 's/.*passed,[^0-9]*\([0-9]*\) failed.*/\1/p')
  fi
  if [[ -z "$p" ]]; then
    # "Results: n/m passed" — equal means all green; otherwise the difference failed.
    _a=$(printf '%s' "$last" | sed -n 's/.*Results:[^0-9]*\([0-9]*\)\/\([0-9]*\) passed.*/\1/p')
    _b=$(printf '%s' "$last" | sed -n 's/.*Results:[^0-9]*\([0-9]*\)\/\([0-9]*\) passed.*/\2/p')
    if [[ -n "$_a" && -n "$_b" ]]; then p="$_a"; fl=$(( _b - _a )); fi
  fi
  if [[ -z "$p" && -z "$fl" ]]; then
    printf "  ${Y}%-40s 无法解析结果行${N}\n" "$base"
    red=$((red + 1)); FAILED_LIST="$FAILED_LIST $base(unparseable)"
    continue
  fi
  if [[ "${fl:-0}" -gt 0 ]]; then
    printf "  ${R}%-40s PASS=%s FAIL=%s${N}\n" "$base" "${p:-?}" "${fl:-?}"
    red=$((red + 1)); FAILED_LIST="$FAILED_LIST $base"
  elif [[ "${p:-0}" -eq 0 ]]; then
    # Zero assertions is not success — see the header.
    printf "  ${R}%-40s 零断言（fixture 早退？）${N}\n" "$base"
    empty=$((empty + 1)); FAILED_LIST="$FAILED_LIST $base(0-assertions)"
  elif [[ "$file_rc" -ne 0 ]]; then
    # The exit code is authority, not the last printed line. A file can print
    # `=== PASS=n FAIL=0 ===` and then `exit 1`; trusting the text alone made that green —
    # the same "looks reported, nothing checked" shape this runner exists to close.
    printf "  ${R}%-40s 尾行像通过但退出码 %s${N}\n" "$base" "$file_rc"
    red=$((red + 1)); FAILED_LIST="$FAILED_LIST $base(rc=$file_rc)"
  else
    printf "  ${G}%-40s PASS=%s${N}\n" "$base" "$p"
    green=$((green + 1))
  fi
done

echo "---"
if [[ "$files" -eq 0 ]]; then
  # An empty run must not print "all passed". With `-k` matching nothing this exited 0 and
  # read as green — the aggregator itself being vacuous.
  printf "${R}run-all: 没有匹配到任何测试文件${FILTER:+ (-k ${FILTER})}${N}\n"
  exit 1
fi
if [[ "$red" -eq 0 && "$empty" -eq 0 ]]; then
  printf "${G}run-all: %d 个文件全部通过${N}\n" "$files"
  exit 0
fi
printf "${R}run-all: %d 个文件，通过 %d，失败 %d，零断言 %d${N}\n" "$files" "$green" "$red" "$empty"
echo "  失败:$FAILED_LIST"
exit 1
