#!/usr/bin/env bash
# 单维档位 `review.mode` / `verify.mode` 设成 `off` 时，门禁必须真的不查那一维。
#
# 🔴 实测（2026-09-11）：门禁自己打印 `review=off, verify=off`，**然后两个都照样拦**：
#     ℹ️  Agent Quality Gate mode: strict (…) — review=off, verify=off
#     ❌ GATE: No content-anchored review evidence covers the staged change
#     ❌ GATE: No verifier evidence (.agent/verify/ missing)
# 源码里 `merge-only` 和 `relaxed` 各有处理，**`off` 只在需求矩阵那一处被认**
# （`_V6_MATRIX_REQUIRED=0`），主 enforcement 一路无视。
#
# ⚠️ 而 `bin/agent-gates-review --due` 是认 `review.mode=off` 的（判 due=no）⇒ 两边口径分叉：
#    CLI 说「现在不用审」，门禁说「没有审查证据，拒绝提交」。⛔ 这类分叉的失败长得像
#    「配置没生效」，没人会去怀疑是两套逻辑。
#
# ⛔ 不能放松的：strict 分支上的 strict_branches override 优先级更高 —— 那里强制 strict，
#    `off` 不该把它顶掉（T4 锁住）。
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
GD=$(mktemp -d); export AGENT_GATES_DIR="$GD"
unset AGENT_GATES_MODE AGENT_GATES_REVIEW_MODE AGENT_GATES_VERIFY_MODE 2>/dev/null || true

run() {   # run <gates.json> [branch]
  local d; d=$(mktemp -d)
  ( cd "$d"
    git init -q .; git config user.email t@t; git config user.name t
    git symbolic-ref HEAD "refs/heads/${2:-feat/x}"
    mkdir -p .agent/reviews
    printf '%s' "$1" > .agent/gates.json
    local n i
    for n in a b c; do printf 'export const %s=1\n' "$n" > "svc$n.ts"; printf 'test\n' > "svc$n.test.ts"; done
    git add -A && git commit -q -m init
    for n in a b c; do for i in $(seq 1 25); do echo "export const v$i=$i" >> "svc$n.ts"; done; done
    git add svc*.ts
    local out rc; out=$(AGENT_MODE=1 bash "$GATE" 2>&1); rc=$?
    printf '%s\n__RC__=%s\n' "$out" "$rc" )
}
_rc() { printf '%s\n' "$1" | sed -n 's/^__RC__=//p'; }
NOREV='No content-anchored review evidence'
NOVER='No verifier evidence'

echo "=== 单维 off ==="
echo
echo "--- T1 review.mode=off ⇒ ⛔ 不许再查审查证据 ---"
out=$(run '{"mode":"strict","review":{"mode":"off"}}')
assert "⛔ 不再报「没有审查证据」" "$([[ "$out" != *"$NOREV"* ]] && echo true || echo false)"
assert "⭐ 要说出来是被 off 跳过的（⛔ 不是静默）" \
  "$([[ "$out" == *"CHECK 5"*off* || "$out" == *"review mode is off"* ]] && echo true || echo false)"
assert "⛔ verify 维度不受影响，仍然查" "$([[ "$out" == *"$NOVER"* ]] && echo true || echo false)"

echo
echo "--- T2 verify.mode=off ⇒ ⛔ 不许再查 verify 证据 ---"
out=$(run '{"mode":"strict","verify":{"mode":"off"}}')
assert "⛔ 不再报「没有 verify 证据」" "$([[ "$out" != *"$NOVER"* ]] && echo true || echo false)"
assert "⭐ 要说出来是被 off 跳过的" \
  "$([[ "$out" == *"CHECK 6"*off* || "$out" == *"verify mode is off"* ]] && echo true || echo false)"
assert "⛔ review 维度不受影响，仍然查" "$([[ "$out" == *"$NOREV"* ]] && echo true || echo false)"

echo
echo "--- T3 两维都 off ⇒ ⭐ 直接通过（Gate 1 仍在：测试文件齐备）---"
out=$(run '{"mode":"strict","review":{"mode":"off"},"verify":{"mode":"off"}}')
assert "⭐ 真的放行（rc=$(_rc "$out")）" \
  "$([[ "$(_rc "$out")" == "0" && "$out" == *"PASSED"* ]] && echo true || echo false)"

echo
echo "--- T4 ⛔ strict 分支的 override 优先：off 顶不掉它 ---"
out=$(run '{"mode":"strict","review":{"mode":"off"},"verify":{"mode":"off"},"strict_branches":["feat/x"]}')
assert "⛔ 仍强制 strict" "$([[ "$out" == *"forced to strict"* ]] && echo true || echo false)"
assert "⛔ 审查证据照查" "$([[ "$out" == *"$NOREV"* ]] && echo true || echo false)"
assert "⛔ verify 证据照查" "$([[ "$out" == *"$NOVER"* ]] && echo true || echo false)"

echo
echo "--- T5 整体 mode=off 仍照旧（回归）---"
out=$(run '{"mode":"off"}')
assert "⭐ 整体 off 时明确说 DISABLED" "$([[ "$out" == *DISABLED* ]] && echo true || echo false)"
assert "⭐ 且放行" "$([[ "$(_rc "$out")" == "0" ]] && echo true || echo false)"

echo
echo "--- T6 ⛔ 与 agent-gates-review --due 口径一致 ---"
REVIEW="$SCRIPT_DIR/../bin/agent-gates-review"
d=$(mktemp -d)
( cd "$d"; git init -q .; git config user.email t@t; git config user.name t
  git symbolic-ref HEAD refs/heads/feat/x; mkdir -p .agent
  printf '{"mode":"strict","review":{"mode":"off"}}' > .agent/gates.json
  printf 'x\n' > f; git add -A; git commit -q -m i ) >/dev/null 2>&1
dout=$(bash "$REVIEW" --due -C "$d" 2>/dev/null); drc=$?
assert "⭐ --due 说 due=no（rc=${drc}）" \
  "$([[ $drc -eq 79 && "$dout" == *"due=no"* && "$dout" == *off* ]] && echo true || echo false)"
gout=$(run '{"mode":"strict","review":{"mode":"off"}}')
assert "⭐ 门禁也不要求审查证据 —— 两边说同一件事" \
  "$([[ "$gout" != *"$NOREV"* ]] && echo true || echo false)"

cd /
echo
read -r P F < "$RESULTS_FILE"
echo "PASS=$P FAIL=$F"
rm -f "$RESULTS_FILE"
[[ "$F" -eq 0 ]] || exit 1
