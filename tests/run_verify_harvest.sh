#!/usr/bin/env bash
# Tests for agent-gates-verify-harvest — turning what hetero_dispatch produced into the
# artifact CHECK 6 actually reads.
#
# The gap (reported 2026-08-31): hetero_dispatch writes only <run-id>.evidence.json and
# <run-id>.dispatch.json. CHECK 6 reads .agent/verify/*.md and anchors on a bare
# `^VERIFY_VERDICT:` line. Nothing in lib/ or bin/ ever wrote a .md — so every caller of
# that path had to hand-write one. And hand-writing the .md means hand-writing the verdict,
# which is precisely the entry point for forging a judgement. The reporter did it as a
# verbatim transcription and said so, but the mechanism should not require that.
#
# So the verdict must come out of the model's own output, and the tool may only normalise
# the label mechanically (VERDICT: -> VERIFY_VERDICT:), recording the original text so the
# transcription is checkable.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HARVEST="$SCRIPT_DIR/../bin/agent-gates-verify-harvest"
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
  mkdir -p migration .agent/verify .agent/reviews
  echo init > migration/001.sql; git add -A; git commit -q -m init
  export AGENT_MODE=1
  for i in $(seq 1 25); do echo "ALTER TABLE t$i ADD c INT;" >> migration/002.sql; done
  echo "-- second" > migration/003.sql
  git add migration/002.sql migration/003.sql
  RID="20260831-120000-abc123"
  CUR=$(git diff --cached -- ':!.agent/verify' | sha)
  AGENT_GATES_DIR=$(mktemp -d); export AGENT_GATES_DIR
}
teardown() { cd /; [[ -n "${REPO:-}" && -d "$REPO" ]] && rm -rf "$REPO"; rm -rf "${AGENT_GATES_DIR:-}"; }

# what dispatch leaves behind
seed_dispatch() {  # seed_dispatch <channel> <capability>
  printf '{"verify_run_id":"%s","channel":"%s","capability":"%s","staged_diff_hash":"%s","HEAD":"%s"}\n' \
    "$RID" "$1" "$2" "$CUR" "$(git rev-parse HEAD)" > ".agent/verify/${RID}.dispatch.json"
}

echo "=== agent-gates-verify-harvest tests ==="
echo

[[ -x "$HARVEST" ]] || { echo "  ✗ bin/agent-gates-verify-harvest 不存在（未实现）"; echo "=== PASS=0 FAIL=1 ==="; exit 1; }

echo "H1: pi 通道（纯文本 evidence）→ 产出 .md，结论来自模型输出"
(
  setup; seed_dispatch pi FULL
  printf 'Checked the migration.\nNo destructive statements found.\n\nVERDICT: PASS\n' > ".agent/verify/${RID}.evidence.json"
  out=$(bash "$HARVEST" "$RID" 2>&1); rc=$?
  assert "exit 0 (实际 $rc)" "$([[ $rc -eq 0 ]] && echo true || echo false)"
  assert "生成 .md" "$([[ -f ".agent/verify/${RID}.md" ]] && echo true || echo false)"
  assert "模型正文原样保留" "$(grep -q 'No destructive statements found' ".agent/verify/${RID}.md" 2>/dev/null && echo true || echo false)"
  assert "⭐ VERIFY_VERDICT 是裸行（gate 严格行首解析）" "$(grep -qE '^VERIFY_VERDICT: PASS$' ".agent/verify/${RID}.md" 2>/dev/null && echo true || echo false)"
  assert "记录了原始结论行以便逐字核对" "$(grep -qE 'VERDICT: PASS' ".agent/verify/${RID}.md" 2>/dev/null && echo true || echo false)"
  teardown
)

echo "H2: ⛔ 模型没给结论行 → 拒绝，不代填"
(
  setup; seed_dispatch pi FULL
  printf 'The migration looks fine to me, no problems.\n' > ".agent/verify/${RID}.evidence.json"
  out=$(bash "$HARVEST" "$RID" 2>&1); rc=$?
  assert "非零退出 (rc=$rc)" "$([[ $rc -ne 0 ]] && echo true || echo false)"
  assert "报错说明要在 prompt 里要求结论行" "$([[ "$out" == *VERDICT* ]] && echo true || echo false)"
  assert "未产出 .md" "$([[ ! -f ".agent/verify/${RID}.md" ]] && echo true || echo false)"
  teardown
)

echo "H3: opencode 通道（NDJSON evidence）→ 先解析再提取"
(
  setup; seed_dispatch opencode EVIDENCE_ONLY
  {
    printf '{"type":"text","part":{"text":"Reviewed the DDL."}}\n'
    printf '{"type":"text","part":{"text":"\\n\\nVERDICT: FAIL\\n"}}\n'
  } > ".agent/verify/${RID}.evidence.json"
  out=$(bash "$HARVEST" "$RID" 2>&1); rc=$?
  assert "exit 0 (实际 $rc)" "$([[ $rc -eq 0 ]] && echo true || echo false)"
  assert "NDJSON 被解析出正文" "$(grep -q 'Reviewed the DDL' ".agent/verify/${RID}.md" 2>/dev/null && echo true || echo false)"
  assert "FAIL 被正确带出" "$(grep -qE '^VERIFY_VERDICT: FAIL$' ".agent/verify/${RID}.md" 2>/dev/null && echo true || echo false)"
  teardown
)

echo "H4: review 取值映射到 verify 语义（机械映射，须记原文）"
(
  setup; seed_dispatch pi FULL
  printf 'Found two real problems.\n\nVERDICT: ISSUES\n' > ".agent/verify/${RID}.evidence.json"
  bash "$HARVEST" "$RID" >/dev/null 2>&1
  assert "ISSUES → FAIL" "$(grep -qE '^VERIFY_VERDICT: FAIL$' ".agent/verify/${RID}.md" 2>/dev/null && echo true || echo false)"
  assert "映射关系写在产物里（可核对）" "$(grep -qiE 'ISSUES' ".agent/verify/${RID}.md" 2>/dev/null && echo true || echo false)"
  teardown
)

echo "H5: 装饰过的结论行也能提取（模型常输出 **VERDICT: PASS**）"
(
  setup; seed_dispatch pi FULL
  printf 'All good.\n\n**VERDICT: PASS**\n' > ".agent/verify/${RID}.evidence.json"
  bash "$HARVEST" "$RID" >/dev/null 2>&1
  assert "装饰被剥掉，产出裸行" "$(grep -qE '^VERIFY_VERDICT: PASS$' ".agent/verify/${RID}.md" 2>/dev/null && echo true || echo false)"
  teardown
)

echo "H6: ⛔ evidence 为空（通道挂了）→ 拒绝"
(
  setup; seed_dispatch pi FULL
  : > ".agent/verify/${RID}.evidence.json"
  out=$(bash "$HARVEST" "$RID" 2>&1); rc=$?
  assert "非零退出 (rc=$rc)" "$([[ $rc -ne 0 ]] && echo true || echo false)"
  assert "未产出 .md" "$([[ ! -f ".agent/verify/${RID}.md" ]] && echo true || echo false)"
  teardown
)

echo "H7: ⭐ 端到端——harvest 之后 CHECK 6 真的认"
(
  setup; seed_dispatch pi FULL
  printf 'Checked it.\n\nVERDICT: PASS\n' > ".agent/verify/${RID}.evidence.json"
  bash "$HARVEST" "$RID" >/dev/null 2>&1
  out=$(SKIP_REVIEW=1 bash "$GATE" 2>&1 || true)
  [[ "$out" == *"No verifier evidence"* ]] && r=false || r=true
  assert "不报「无对应 verify」" "$r"
  [[ "$out" == *"missing VERIFY_VERDICT"* ]] && r=false || r=true
  assert "不报「缺 VERIFY_VERDICT」" "$r"
  teardown
)

echo
read -r P F < "$RESULTS_FILE"
echo "=== PASS=$P FAIL=$F ==="
rm -f "$RESULTS_FILE"
[[ "$F" -eq 0 ]]
