#!/usr/bin/env bash
# End-to-end: plan → emit-prompt → verifier answers → harvest → gate.
#
# Why a separate e2e file: the unit fixtures are shaped by my assumptions about what each
# piece produces. Building a fake from the field names I expected — rather than from the
# real command's output — once gave 25 green assertions that did not hold against the
# actual CLI. So this walks the real commands in order and only asserts on what they
# actually wrote.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HARVEST="$ROOT/bin/agent-gates-verify-harvest"
GATE="$ROOT/hooks/git/agent-quality-gate.sh"
RESULTS_FILE=$(mktemp); echo "0 0" > "$RESULTS_FILE"

assert() {
  local name="$1" cond="$2" p f
  read -r p f < "$RESULTS_FILE"
  if [[ "$cond" == "true" ]]; then echo "  ✓ $name"; echo "$((p+1)) $f" > "$RESULTS_FILE"
  else echo "  ✗ $name"; echo "$p $((f+1))" > "$RESULTS_FILE"; fi
}
sha() { if command -v sha256sum >/dev/null 2>&1; then sha256sum | cut -d' ' -f1; else shasum -a 256 | cut -d' ' -f1; fi; }

# A repo on a strict branch (master) with a real requirement doc and a real change.
setup() {
  REPO=$(mktemp -d); cd "$REPO" || exit 1
  git init -q; git config user.email t@t.com; git config user.name T
  mkdir -p src/pages src/server .agent/plans .agent/verify .agent/reviews
  echo "<template><div>列表</div></template>" > src/pages/List.vue
  git add -A; git commit -q -m init
  git branch -M master 2>/dev/null || true
  export AGENT_MODE=1
  AGENT_GATES_DIR=$(mktemp -d); export AGENT_GATES_DIR
  cat > .agent/plans/2026-09-01-export.md <<'EOF'
# 表格导出

## 背景
用户要能把当前表格内容全量导出。

## 验收标准
- 用户可以在列表页按关键词搜索
- 用户可以把当前筛选结果全量导出为 CSV

## 实现步骤
- [ ] 写导出接口
- [ ] 加导出按钮
EOF
  RID="20260901-140000-e2e"
}
teardown() { cd /; [[ -n "${REPO:-}" && -d "$REPO" ]] && rm -rf "$REPO"; rm -rf "${AGENT_GATES_DIR:-}"; }

# The change under test: backend only, 25+ lines so CHECK 6 triggers.
# Test files are staged alongside: Gate 1 requires a test per source file and fires long
# before CHECK 6. Without them the whole e2e blocks on Gate 1 and every "should pass"
# assertion fails for a reason that has nothing to do with the matrix — which is exactly
# what happened on the first run of this file.
stage_backend_only() {
  # 160 lines: CHECK 6 triggers on MAX_SINGLE_FILE_LINES > 150, which is independent of how
  # many files a given case stages. Sizing by file count instead made CHECK 6 skip entirely
  # in the backend-only cases, and every assertion there passed with rc=0 — a green run that
  # proved nothing.
  { echo "export function search(q: string) {"
    for i in $(seq 1 158); do echo "  // search line $i"; done
    echo "}"; } > src/server/search.ts
  echo "test('search', () => {})" > src/server/search.test.ts
  git add src/server/search.ts src/server/search.test.ts
}
stage_backend_and_ui() {
  stage_backend_only
  { echo "export function exportCsv() {"
    for i in $(seq 1 24); do echo "  // export line $i"; done
    echo "}"; } > src/server/export.ts
  echo "test('export', () => {})" > src/server/export.test.ts
  printf '<template><div>列表<button>导出</button></div></template>\n' > src/pages/List.vue
  git add src/server/export.ts src/server/export.test.ts src/pages/List.vue
}
# CHECK 5 has no skip switch — it fires purely on the change metrics, and these fixtures
# are deliberately large enough to trigger CHECK 6, which means they trigger CHECK 5 too.
# So a genuinely anchored review has to exist, or every "should pass" case blocks on the
# review instead and the verify assertions never get exercised.
_review_files() {
  git -c core.quotePath=true diff --cached --name-only --diff-filter=ACMRD -- . \
    ':(exclude).agent/reviews/**' ':(exclude).agent/verify/**' ':(exclude).agent/plans/**'
}
seed_review() {
  local f files
  f=".agent/reviews/2099-01-01-review.md"
  files=$(_review_files)
  { printf '<!-- REVIEW_LEVEL: L0 -->\n'
    printf '<!-- REVIEW_HEAD: %s -->\n' "$(git rev-parse HEAD)"
    while IFS= read -r rf; do [[ -n "$rf" ]] && printf '<!-- REVIEW_FILE: %s -->\n' "$rf"; done <<< "$files"
    printf '<!-- REVIEW_FILES_SHA256: %s -->\n' "$(printf '%s\n' "$files" | sha)"
    printf '<!-- REVIEW_DIFF_SHA256: %s -->\n' \
      "$(git diff --cached --binary -- . ':(exclude).agent/reviews/**' ':(exclude).agent/verify/**' ':(exclude).agent/plans/**' | sha)"
    echo '# Anchored review'
    printf 'VERDICT: PASS\n'
  } > "$f"
}
seed_dispatch() {
  local cur; cur=$(git diff --cached -- ':!.agent/verify' | sha)
  printf '{"verify_run_id":"%s","channel":"pi","capability":"FULL","staged_diff_hash":"%s","HEAD":"%s"}\n' \
    "$RID" "$cur" "$(git rev-parse HEAD)" > ".agent/verify/${RID}.dispatch.json"
}
run_gate() { SKIP_REVIEW=1 SKIP_PLAN_CHECK=1 bash "$GATE" 2>&1; }

echo "=== requirement matrix end-to-end ==="
echo

echo "E2E-0: 前置——分支是 strict，需求源被识别为 2 条"
( setup; stage_backend_only; seed_review
  b=$(git rev-parse --abbrev-ref HEAD)
  assert "分支是 master (实际 $b)" "$([[ "$b" == "master" ]] && echo true || echo false)"
  n=$(bash "$HARVEST" --emit-prompt --req-source .agent/plans/2026-09-01-export.md 2>/dev/null | grep -cE '^  [0-9]+\. ')
  assert "emit-prompt 列出 2 条需求 (实际 $n)" "$([[ "$n" == "2" ]] && echo true || echo false)"
  out=$(run_gate)
  assert "Gate 1 不是拦路者（否则后面的断言全都对不上因果）" "$([[ "$out" != *"No test for"* ]] && echo true || echo false)"
  assert "CHECK 5 不是拦路者" "$([[ "$out" != *"content-anchored review"* ]] && echo true || echo false)"
  # No verify artifact at all here, so CHECK 6 stops at "no evidence" — that IS reaching
  # CHECK 6. Asserting on the matrix line would be asserting the wrong milestone.
  assert "走到了 CHECK 6 (实际: $(printf '%s' "$out" | grep -oiE 'verifier evidence|需求矩阵|CHECK 6[^\n]*' | head -1))" \
    "$([[ "$out" == *erifier* || "$out" == *"需求矩阵"* ]] && echo true || echo false)"
  teardown )

echo "E2E-1: ⭐ 只写后端、验收模型如实报 MISSING → 门禁拦住"
( setup; stage_backend_only; seed_dispatch; seed_review
  # 验收模型的真实回答：搜索做了，导出没做
  cat > ".agent/verify/${RID}.evidence.json" <<'EOF'
逐条核对。

REQ_ITEM: 1 | COVERED | api:src/server/search.ts:1, ui:~src/pages/List.vue:1 | 搜索接口已实现，列表页既有入口
REQ_ITEM: 2 | MISSING | - | 没有导出接口，列表页也没有导出按钮，用户点不到

VERDICT: FAIL
EOF
  h=$(bash "$HARVEST" "$RID" --req-source .agent/plans/2026-09-01-export.md 2>&1); hrc=$?
  assert "harvest 成功 (rc=$hrc)" "$([[ $hrc -eq 0 ]] && echo true || echo false)"
  out=$(run_gate); rc=$?
  assert "门禁拦住 (rc=$rc)" "$([[ $rc -ne 0 ]] && echo true || echo false)"
  assert "打印 MISSING=1" "$([[ "$out" == *"MISSING=1"* ]] && echo true || echo false)"
  teardown )

echo "E2E-2: ⭐⭐ 只写后端、验收模型谎报两条都 COVERED → 引用校验把它抓出来"
( setup; stage_backend_only; seed_dispatch; seed_review
  # 第 2 条其实没做，但模型硬指了一个真实存在的既有前端文件当入口
  cat > ".agent/verify/${RID}.evidence.json" <<'EOF'
REQ_ITEM: 1 | COVERED | api:src/server/search.ts:1, ui:~src/pages/List.vue:1 | 搜索已实现
REQ_ITEM: 2 | COVERED | api:src/server/export.ts:1, ui:src/pages/List.vue:1 | 导出已实现

VERDICT: PASS
EOF
  bash "$HARVEST" "$RID" --req-source .agent/plans/2026-09-01-export.md >/dev/null 2>&1
  out=$(run_gate); rc=$?
  assert "门禁拦住 (rc=$rc)" "$([[ $rc -ne 0 ]] && echo true || echo false)"
  # 两个谎都被抓：export.ts 根本不存在；List.vue 存在但本次没改，不能标成 COVERED
  assert "点出 export.ts 不存在" "$([[ "$out" == *"src/server/export.ts"* ]] && echo true || echo false)"
  assert "点出 List.vue 不在本次改动内" "$([[ "$out" == *"src/pages/List.vue"* ]] && echo true || echo false)"
  teardown )

echo "E2E-3: 前后端都写了、逐条如实 COVERED → 门禁放行"
( setup; stage_backend_and_ui; seed_dispatch; seed_review
  cat > ".agent/verify/${RID}.evidence.json" <<'EOF'
REQ_ITEM: 1 | COVERED | api:src/server/search.ts:1, ui:~src/pages/List.vue:1 | 搜索接口 + 既有列表页
REQ_ITEM: 2 | COVERED | api:src/server/export.ts:1, ui:src/pages/List.vue:1 | 导出接口 + 本次新增的导出按钮

VERDICT: PASS
EOF
  bash "$HARVEST" "$RID" --req-source .agent/plans/2026-09-01-export.md >/dev/null 2>&1
  out=$(run_gate); rc=$?
  assert "放行 (rc=$rc)" "$([[ $rc -eq 0 ]] && echo true || echo false)"
  assert "打印 COVERED=2" "$([[ "$out" == *"COVERED=2"* ]] && echo true || echo false)"
  teardown )

echo "E2E-4: ⭐ 增量交付：第 2 条明确 DEFERRED → 放行且不必回去改需求文档"
( setup; stage_backend_only; seed_dispatch; seed_review
  cat > ".agent/verify/${RID}.evidence.json" <<'EOF'
REQ_ITEM: 1 | COVERED | api:src/server/search.ts:1, ui:~src/pages/List.vue:1 | 本次交付
REQ_ITEM: 2 | DEFERRED | - | 导出留到下个 PR，见 issue #42

VERDICT: PASS
EOF
  bash "$HARVEST" "$RID" --req-source .agent/plans/2026-09-01-export.md >/dev/null 2>&1
  out=$(run_gate); rc=$?
  assert "放行 (rc=$rc)" "$([[ $rc -eq 0 ]] && echo true || echo false)"
  assert "DEFERRED 计数可见" "$([[ "$out" == *"DEFERRED=1"* ]] && echo true || echo false)"
  # 需求文档没有被篡改——这正是 DEFERRED 存在的理由
  n=$(bash "$HARVEST" --emit-prompt --req-source .agent/plans/2026-09-01-export.md 2>/dev/null | grep -cE '^  [0-9]+\. ')
  assert "需求源仍是 2 条，未被删减 (实际 $n)" "$([[ "$n" == "2" ]] && echo true || echo false)"
  teardown )

echo "E2E-5: ⛔ 验收模型只答 1 条 → harvest 拒绝，且门禁不会读到半份产物"
( setup; stage_backend_only; seed_dispatch; seed_review
  printf 'REQ_ITEM: 1 | COVERED | api:src/server/search.ts:1 | 只答了这条\n\nVERDICT: PASS\n' \
    > ".acgent-tmp" && mv ".acgent-tmp" ".agent/verify/${RID}.evidence.json"
  h=$(bash "$HARVEST" "$RID" --req-source .agent/plans/2026-09-01-export.md 2>&1); hrc=$?
  assert "harvest exit 3 (实际 $hrc)" "$([[ $hrc -eq 3 ]] && echo true || echo false)"
  assert "不生成 .md" "$([[ ! -f ".agent/verify/${RID}.md" ]] && echo true || echo false)"
  out=$(run_gate); rc=$?
  assert "门禁因缺产物而拦住 (rc=$rc)" "$([[ $rc -ne 0 ]] && echo true || echo false)"
  teardown )

echo "E2E-6: ⭐ 事后删掉需求里最难那条 → 哈希失配被点出来"
( setup; stage_backend_and_ui; seed_dispatch; seed_review
  cat > ".agent/verify/${RID}.evidence.json" <<'EOF'
REQ_ITEM: 1 | COVERED | api:src/server/search.ts:1, ui:~src/pages/List.vue:1 | 搜索
REQ_ITEM: 2 | COVERED | api:src/server/export.ts:1, ui:src/pages/List.vue:1 | 导出

VERDICT: PASS
EOF
  bash "$HARVEST" "$RID" --req-source .agent/plans/2026-09-01-export.md >/dev/null 2>&1
  before=$(grep '^REQ_BLOCK_SHA256:' ".agent/verify/${RID}.md" | awk '{print $2}')
  # 收割之后把第 2 条需求删掉
  python3 - <<'PYEOF'
import pathlib, re
p = pathlib.Path('.agent/plans/2026-09-01-export.md')
s = p.read_text()
s = s.replace("- 用户可以把当前筛选结果全量导出为 CSV\n", "")
p.write_text(s)
PYEOF
  after=$( source "$ROOT/lib/verify/reqmatrix.sh"; reqmatrix_block_hash .agent/plans/2026-09-01-export.md )
  assert "改需求条目后哈希变化" "$([[ -n "$before" && -n "$after" && "$before" != "$after" ]] && echo true || echo false)"
  out=$(run_gate); rc=$?
  # 条数从 2 变 1，矩阵还写着 2 条 → 对不上
  assert "门禁因条数不符而拦住 (rc=$rc)" "$([[ $rc -ne 0 ]] && echo true || echo false)"
  teardown )

echo
read -r P F < "$RESULTS_FILE"
echo "=== PASS=$P FAIL=$F ==="
rm -f "$RESULTS_FILE"
[[ "$F" -eq 0 ]]
