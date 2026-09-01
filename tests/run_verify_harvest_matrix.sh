#!/usr/bin/env bash
# Tests for the requirement-matrix half of agent-gates-verify-harvest.
#
# The rule that shapes all of this: the tool may NOT supply an answer the model did not
# give. harvest already refuses to invent a verdict; the same applies per requirement item.
# An unanswered acceptance item that got written out as COVERED would be the exact forgery
# the matrix exists to prevent, and one written out as MISSING would mislabel "nobody
# asked" as "it was not built".
#
# So the skeleton goes into the PROMPT, not into the conclusion:
#   --emit-prompt   prints the numbered items + the required answer format, for dispatch
#   normal run      copies the model's REQ_ITEM lines verbatim, refuses if any are absent
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HARVEST="$SCRIPT_DIR/../bin/agent-gates-verify-harvest"
LIB="$SCRIPT_DIR/../lib/verify/reqmatrix.sh"
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
  mkdir -p migration src .agent/verify .agent/plans
  echo init > migration/001.sql; echo "<template/>" > src/List.vue
  git add -A; git commit -q -m init
  export AGENT_MODE=1
  for i in $(seq 1 25); do echo "ALTER TABLE t$i ADD c INT;" >> migration/002.sql; done
  git add migration/002.sql
  RID="20260901-120000-abc123"
  CUR=$(git diff --cached -- ':!.agent/verify' | sha)
  AGENT_GATES_DIR=$(mktemp -d); export AGENT_GATES_DIR
  cat > .agent/plans/req.md <<'EOF'
# 导出功能

## 验收标准
- 表格支持关键词搜索
- 支持导出全部内容为 CSV
EOF
}
teardown() { cd /; [[ -n "${REPO:-}" && -d "$REPO" ]] && rm -rf "$REPO"; rm -rf "${AGENT_GATES_DIR:-}"; }
seed_dispatch() {
  printf '{"verify_run_id":"%s","channel":"pi","capability":"FULL","staged_diff_hash":"%s","HEAD":"%s"}\n' \
    "$RID" "$CUR" "$(git rev-parse HEAD)" > ".agent/verify/${RID}.dispatch.json"
}

echo "=== verify-harvest requirement-matrix tests ==="
echo

[[ -x "$HARVEST" ]] || { echo "  ✗ bin/agent-gates-verify-harvest 不存在"; echo "=== PASS=0 FAIL=1 ==="; exit 1; }

echo "HM1: --emit-prompt 打印编号需求 + 要求的回答格式"
( setup
  out=$(bash "$HARVEST" --emit-prompt --req-source .agent/plans/req.md 2>&1); rc=$?
  assert "exit 0 (实际 $rc)" "$([[ $rc -eq 0 ]] && echo true || echo false)"
  assert "含第1条需求原文" "$([[ "$out" == *"表格支持关键词搜索"* ]] && echo true || echo false)"
  assert "含第2条需求原文" "$([[ "$out" == *"导出全部内容"* ]] && echo true || echo false)"
  assert "给出 REQ_ITEM 回答格式" "$([[ "$out" == *"REQ_ITEM:"* ]] && echo true || echo false)"
  assert "说明 ~ 表示既有未改" "$([[ "$out" == *"~"* ]] && echo true || echo false)"
  assert "列出允许的状态" "$([[ "$out" == *DEFERRED* && "$out" == *PREEXISTING* ]] && echo true || echo false)"
  teardown )

echo "HM2: --emit-prompt 遇到没有验收章节的文档 → 拒绝并说清怎么补"
( setup
  printf '# 计划\n\n## 实现步骤\n- [ ] 甲\n' > .agent/plans/nosec.md
  out=$(bash "$HARVEST" --emit-prompt --req-source .agent/plans/nosec.md 2>&1); rc=$?
  assert "非零退出 (实际 $rc)" "$([[ $rc -ne 0 ]] && echo true || echo false)"
  assert "提示补验收章节" "$([[ "$out" == *"验收标准"* ]] && echo true || echo false)"
  teardown )

echo "HM3: ⭐ 模型答满两条 → .md 带 REQ_SOURCE / 哈希 / 条数 / 逐条原文"
( setup; seed_dispatch
  cat > ".agent/verify/${RID}.evidence.json" <<'EOF'
逐条核对如下。

REQ_ITEM: 1 | COVERED | db:migration/002.sql:1, ui:~src/List.vue:1 | 搜索条件已接
REQ_ITEM: 2 | MISSING | - | 导出接口未实现，前端也没有导出入口

VERDICT: FAIL
EOF
  out=$(bash "$HARVEST" "$RID" --req-source .agent/plans/req.md 2>&1); rc=$?
  MD=".agent/verify/${RID}.md"
  assert "exit 0 (实际 $rc)" "$([[ $rc -eq 0 ]] && echo true || echo false)"
  assert "写出 REQ_SOURCE" "$(grep -qE '^REQ_SOURCE: \.agent/plans/req\.md$' "$MD" 2>/dev/null && echo true || echo false)"
  assert "写出 REQ_ITEMS: 2" "$(grep -qE '^REQ_ITEMS: 2$' "$MD" 2>/dev/null && echo true || echo false)"
  assert "写出 REQ_BLOCK_SHA256" "$(grep -qE '^REQ_BLOCK_SHA256: [0-9a-f]{64}$' "$MD" 2>/dev/null && echo true || echo false)"
  assert "⭐ 逐条原样保留（可与 transcript 对照）" "$(grep -qF 'REQ_ITEM: 2 | MISSING | - | 导出接口未实现，前端也没有导出入口' "$MD" 2>/dev/null && echo true || echo false)"
  assert "VERIFY_VERDICT 仍是裸行" "$(grep -qE '^VERIFY_VERDICT: FAIL$' "$MD" 2>/dev/null && echo true || echo false)"
  teardown )

echo "HM4: 哈希与 reqmatrix_block_hash 一致（门禁重算得对得上）"
( setup; seed_dispatch
  printf 'REQ_ITEM: 1 | COVERED | db:migration/002.sql:1 | x\nREQ_ITEM: 2 | COVERED | db:migration/002.sql:2 | y\n\nVERDICT: PASS\n' \
    > ".agent/verify/${RID}.evidence.json"
  bash "$HARVEST" "$RID" --req-source .agent/plans/req.md >/dev/null 2>&1
  got=$(grep -oE '^REQ_BLOCK_SHA256: [0-9a-f]{64}$' ".agent/verify/${RID}.md" | awk '{print $2}')
  want=$( source "$LIB"; reqmatrix_block_hash .agent/plans/req.md )
  assert "哈希一致" "$([[ -n "$got" && "$got" == "$want" ]] && echo true || echo false)"
  teardown )

echo "HM5: ⛔ 模型只答了 1 条（需求有 2 条）→ 拒绝，不代填"
( setup; seed_dispatch
  printf 'REQ_ITEM: 1 | COVERED | db:migration/002.sql:1 | 只答了这条\n\nVERDICT: PASS\n' \
    > ".agent/verify/${RID}.evidence.json"
  out=$(bash "$HARVEST" "$RID" --req-source .agent/plans/req.md 2>&1); rc=$?
  # exit 3 specifically = refusal. Before implementation this returned 2 (unknown option)
  # and the loose "非零" assertion passed for entirely the wrong reason.
  assert "exit 3 拒绝 (实际 $rc)" "$([[ $rc -eq 3 ]] && echo true || echo false)"
  assert "点出未回答的条目号" "$([[ "$out" == *"2"* ]] && echo true || echo false)"
  assert "点出未回答的需求原文" "$([[ "$out" == *"导出全部内容"* ]] && echo true || echo false)"
  assert "⛔ 不生成 .md（半份产物比没有更糟）" "$([[ ! -f ".agent/verify/${RID}.md" ]] && echo true || echo false)"
  assert "指向 --emit-prompt 重新派发" "$([[ "$out" == *"--emit-prompt"* ]] && echo true || echo false)"
  teardown )

echo "HM6: ⛔ 模型一条都没答 → 拒绝（不能退化成只写 VERIFY_VERDICT 蒙过去）"
( setup; seed_dispatch
  printf '看起来都做完了。\n\nVERDICT: PASS\n' > ".agent/verify/${RID}.evidence.json"
  out=$(bash "$HARVEST" "$RID" --req-source .agent/plans/req.md 2>&1); rc=$?
  assert "exit 3 拒绝 (实际 $rc)" "$([[ $rc -eq 3 ]] && echo true || echo false)"
  assert "不生成 .md" "$([[ ! -f ".agent/verify/${RID}.md" ]] && echo true || echo false)"
  teardown )

echo "HM7: 不传 --req-source → 完全按老行为走（向后兼容）"
( setup; seed_dispatch
  printf '看过了，没问题。\n\nVERDICT: PASS\n' > ".agent/verify/${RID}.evidence.json"
  out=$(bash "$HARVEST" "$RID" 2>&1); rc=$?
  MD=".agent/verify/${RID}.md"
  assert "exit 0 (实际 $rc)" "$([[ $rc -eq 0 ]] && echo true || echo false)"
  assert "生成 .md" "$([[ -f "$MD" ]] && echo true || echo false)"
  assert "不凭空塞 REQ_SOURCE" "$(grep -q '^REQ_SOURCE:' "$MD" 2>/dev/null && echo false || echo true)"
  teardown )

echo "HM8: --req-source 指向不存在的文件 → 拒绝"
( setup; seed_dispatch
  printf 'REQ_ITEM: 1 | COVERED | a:1 | x\n\nVERDICT: PASS\n' > ".agent/verify/${RID}.evidence.json"
  out=$(bash "$HARVEST" "$RID" --req-source .agent/plans/ghost.md 2>&1); rc=$?
  assert "非零退出 (实际 $rc)" "$([[ $rc -ne 0 ]] && echo true || echo false)"
  teardown )

echo "HM10: REQ_ITEM 行被列表符号包住（行首不匹配）→ 明确点出装饰问题"
( setup; seed_dispatch
  printf -- '- REQ_ITEM: 1 | COVERED | db:migration/002.sql:1 | x\n- REQ_ITEM: 2 | COVERED | db:migration/002.sql:2 | y\n\nVERDICT: PASS\n' \
    > ".agent/verify/${RID}.evidence.json"
  out=$(bash "$HARVEST" "$RID" --req-source .agent/plans/req.md 2>&1); rc=$?
  assert "exit 3 拒绝 (实际 $rc)" "$([[ $rc -eq 3 ]] && echo true || echo false)"
  # Without this the operator reads "模型一条没答" and goes looking at the model, when the
  # actual problem is two characters of markdown at line start.
  assert "⭐ 点出「不在行首」而不是含糊说没回答" "$([[ "$out" == *"行首"* ]] && echo true || echo false)"
  teardown )

echo "HM11: ⭐ 模型申报 PASS 而矩阵有 MISSING → harvest 原样记录，不在这里悄悄收紧"
( setup; seed_dispatch
  cat > ".agent/verify/${RID}.evidence.json" <<'EOF'
REQ_ITEM: 1 | COVERED | db:migration/002.sql:1 | 做了
REQ_ITEM: 2 | MISSING | - | 没做，但我申报 PASS

VERDICT: PASS
EOF
  bash "$HARVEST" "$RID" --req-source .agent/plans/req.md >/dev/null 2>&1
  MD=".agent/verify/${RID}.md"
  # harvest 的契约：verdict 取自模型，只做机械改写。按矩阵推导是判断、不是改写，
  # 而且门禁的 E4 会推导并**打印差异**；放到这里静默收紧就把那条差异抹掉了。
  # 2026-09-01 一个自动审查者恰好加了这个改动，看起来完全合理 —— 所以钉住它。
  assert "⭐ 原样记录模型的 PASS" "$(grep -qE '^VERIFY_VERDICT: PASS$' "$MD" 2>/dev/null && echo true || echo false)"
  assert "模型原始结论行留在产物里可核对" "$(grep -qF 'VERDICT: PASS' "$MD" 2>/dev/null && echo true || echo false)"
  # 收紧发生在门禁，并且要说出来
  out=$(SKIP_REVIEW=1 SKIP_PLAN_CHECK=1 bash "$SCRIPT_DIR/../hooks/git/agent-quality-gate.sh" 2>&1 || true)
  assert "门禁负责收紧并打印差异" "$([[ "$out" == *"采用推导结果"* || "$out" == *"MISSING=1"* ]] && echo true || echo false)"
  teardown )


echo "HM9: 产出的 .md 能直接过 reqmatrix 解析（端到端，不是照字段名造的假设）"
( setup; seed_dispatch
  printf 'REQ_ITEM: 1 | COVERED | db:migration/002.sql:1 | x\nREQ_ITEM: 2 | COVERED | db:migration/002.sql:2 | y\n\nVERDICT: PASS\n' \
    > ".agent/verify/${RID}.evidence.json"
  bash "$HARVEST" "$RID" --req-source .agent/plans/req.md >/dev/null 2>&1
  MD=".agent/verify/${RID}.md"
  n=$( source "$LIB"; reqmatrix_parse "$MD" | wc -l | tr -d ' ' )
  assert "reqmatrix_parse 解析出 2 行" "$([[ "$n" == "2" ]] && echo true || echo false)"
  rc2=$( source "$LIB"; reqmatrix_check_count "$MD" .agent/plans/req.md >/dev/null 2>&1; echo $? )
  assert "reqmatrix_check_count 通过" "$([[ "$rc2" == "0" ]] && echo true || echo false)"
  v=$( source "$LIB"; reqmatrix_reconcile_verdict "$MD" )
  assert "推导判定为 PASS (实际 $v)" "$([[ "$v" == "PASS" ]] && echo true || echo false)"
  teardown )

echo
read -r P F < "$RESULTS_FILE"
echo "=== PASS=$P FAIL=$F ==="
rm -f "$RESULTS_FILE"
[[ "$F" -eq 0 ]]
