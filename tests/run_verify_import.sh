#!/usr/bin/env bash
# Tests for agent-gates-verify-import — the missing counterpart to
# `agent-gates-review --import-result`.
#
# Why it exists (reported 2026-08-26, and it blocked a real commit): CHECK 6 wants a
# VERIFY_VERDICT document plus a dispatch record whose staged_diff_hash binds the current
# staged diff. `agent-gates-review --route paseo` / `--import-result` produce the REVIEW_*
# shape instead, so on a machine where the automatic verify channels are unusable there was
# NO official way to produce a compliant verify artifact. Agents were left with two options:
# hand-write the dispatch.json (fabricating a dispatch that never happened) or stop. One
# session correctly refused both and stopped — that is the gap this closes.
#
# ⛔ What this does NOT do: it never claims the review happened through a channel it did
# not. Provenance must be declared (--imported-model or --paseo-agent), and the anchors are
# computed by the tool, never accepted from the caller. That is exactly the difference
# between "importing an external review" and "forging a receipt".
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMPORT="$SCRIPT_DIR/../bin/agent-gates-verify-import"
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
  BODY=$(mktemp)
  printf 'Reviewed the migration end to end.\nNo destructive statements.\n\nVERIFY_VERDICT: PASS\n' > "$BODY"
  AGENT_GATES_DIR=$(mktemp -d); export AGENT_GATES_DIR
}
teardown() { cd /; [[ -n "${REPO:-}" && -d "$REPO" ]] && rm -rf "$REPO"; rm -f "${BODY:-}"; rm -rf "${AGENT_GATES_DIR:-}"; }

echo "=== agent-gates-verify-import tests ==="
echo

[[ -x "$IMPORT" ]] || { echo "  ✗ bin/agent-gates-verify-import 不存在（未实现）"; echo "=== PASS=0 FAIL=1 ==="; exit 1; }

echo "V1: 正常导入 → 产出 .md + .dispatch.json，锚点由工具计算"
(
  setup
  out=$(bash "$IMPORT" "$BODY" --imported-model "volcengine-coding/deepseek-v4-flash" 2>&1); rc=$?
  assert "exit 0 (实际 $rc)" "$([[ $rc -eq 0 ]] && echo true || echo false)"
  MD=$(ls .agent/verify/*.md 2>/dev/null | head -1)
  DJ="${MD%.md}.dispatch.json"
  assert "生成了 .md" "$([[ -n "$MD" && -f "$MD" ]] && echo true || echo false)"
  assert "生成了 .dispatch.json" "$([[ -f "$DJ" ]] && echo true || echo false)"
  assert "正文原样保留" "$(grep -q 'No destructive statements' "$MD" 2>/dev/null && echo true || echo false)"
  assert "含 VERIFY_VERDICT 行" "$(grep -qE '^VERIFY_VERDICT:[[:space:]]*PASS' "$MD" 2>/dev/null && echo true || echo false)"
  WANT=$(git diff --cached -- ':!.agent/verify' | sha)
  GOT=$(sed -n 's/.*"staged_diff_hash"[[:space:]]*:[[:space:]]*"\([0-9a-fA-F]*\)".*/\1/p' "$DJ" | head -1)
  assert "staged_diff_hash 与当前 staged 一致" "$([[ "$GOT" == "$WANT" ]] && echo true || echo false)"
  assert "记录了来源模型" "$(grep -q 'deepseek-v4-flash' "$DJ" 2>/dev/null && echo true || echo false)"
  teardown
)

echo "V2: ⛔ 正文缺 VERIFY_VERDICT → 拒绝（不代填）"
(
  setup
  printf 'looks fine to me\n' > "$BODY"
  out=$(bash "$IMPORT" "$BODY" --imported-model x/y 2>&1); rc=$?
  assert "非零退出 (rc=$rc)" "$([[ $rc -ne 0 ]] && echo true || echo false)"
  assert "报错提到 VERIFY_VERDICT" "$([[ "$out" == *VERIFY_VERDICT* ]] && echo true || echo false)"
  assert "未产出任何文件" "$([[ -z "$(ls .agent/verify/ 2>/dev/null)" ]] && echo true || echo false)"
  teardown
)

echo "V3: ⛔ 未声明来源 → 拒绝（不接受来源不明的验收）"
(
  setup
  out=$(bash "$IMPORT" "$BODY" 2>&1); rc=$?
  assert "非零退出 (rc=$rc)" "$([[ $rc -ne 0 ]] && echo true || echo false)"
  assert "报错要求声明来源" "$([[ "$out" == *imported-model* || "$out" == *paseo-agent* ]] && echo true || echo false)"
  teardown
)

echo "V4: capability 按族判定（与 dispatch 同一套语义）"
(
  setup
  export HETERO_IMPLEMENTER_FAMILY=anthropic
  bash "$IMPORT" "$BODY" --imported-model "volcengine-coding/deepseek-v4-flash" >/dev/null 2>&1
  DJ=$(ls .agent/verify/*.dispatch.json | head -1)
  assert "异构 → FULL" "$(grep -q '"capability"[^,]*FULL' "$DJ" 2>/dev/null && echo true || echo false)"
  rm -f .agent/verify/*
  bash "$IMPORT" "$BODY" --imported-model "github-copilot/claude-sonnet-4.6" >/dev/null 2>&1
  DJ=$(ls .agent/verify/*.dispatch.json | head -1)
  assert "同族 → EVIDENCE_ONLY" "$(grep -q 'EVIDENCE_ONLY' "$DJ" 2>/dev/null && echo true || echo false)"
  teardown
)

echo "V5: ⭐ 端到端——导入后 CHECK 6 真的认（这才是它存在的意义）"
(
  setup
  export HETERO_IMPLEMENTER_FAMILY=anthropic
  bash "$IMPORT" "$BODY" --imported-model "volcengine-coding/deepseek-v4-flash" >/dev/null 2>&1
  out=$(SKIP_REVIEW=1 bash "$GATE" 2>&1 || true)
  [[ "$out" == *"No verifier evidence"* ]] && r=false || r=true
  assert "不再报「无对应 verify」" "$r"
  [[ "$out" == *"made AFTER verification"* ]] && r=false || r=true
  assert "不报「改动超限」" "$r"
  [[ "$out" == *"missing VERIFY_VERDICT"* ]] && r=false || r=true
  assert "不报「缺 VERIFY_VERDICT」" "$r"
  teardown
)

echo "V6: 重复导入不互相覆盖（run-id 唯一）"
(
  setup
  bash "$IMPORT" "$BODY" --imported-model x/y >/dev/null 2>&1
  sleep 1
  bash "$IMPORT" "$BODY" --imported-model x/y >/dev/null 2>&1
  n=$(ls .agent/verify/*.md 2>/dev/null | wc -l | tr -d ' ')
  assert "两次导入产出两份 (实际 $n)" "$([[ "$n" -eq 2 ]] && echo true || echo false)"
  teardown
)

echo
read -r P F < "$RESULTS_FILE"
echo "=== PASS=$P FAIL=$F ==="
rm -f "$RESULTS_FILE"
[[ "$F" -eq 0 ]]
