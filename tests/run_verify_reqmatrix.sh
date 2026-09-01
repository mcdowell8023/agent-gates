#!/usr/bin/env bash
# Tests for the requirement matrix — CHECK 6's omission detector.
#
# WHY THIS EXISTS: a missing feature leaves no trace in the diff, so a diff-scoped
# reviewer (CHECK 5) sees only correct code and passes. Tests written by the
# implementer are equally blind: it did not build the thing, so it did not write the
# test for it — "all green" and "half the requirement missing" coexist happily.
# The only checklist that can catch omission is one derived from the REQUIREMENT.
#
# The gate enforces FORM (count matches, every item has a disposition, citations land
# inside this change, surfaces declared). Substance — "does this evidence actually
# complete this requirement" — is a semantic judgment shell cannot make and is left to
# the heterogeneous verifier. These tests therefore assert form only, and several
# deliberately assert that a plausible-looking bypass is NOT reported as a failure,
# because a gate that produces false failures is a gate people route around.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$SCRIPT_DIR/../lib/verify/reqmatrix.sh"
RESULTS_FILE=$(mktemp); echo "0 0" > "$RESULTS_FILE"

# Isolate from this machine's real config. A legitimate ~/.agent-gates/*.json has
# flipped assertions before and read exactly like a code regression (2026-08-31).
export AGENT_GATES_DIR="$(mktemp -d)"

assert() {
  local name="$1" cond="$2" p f
  read -r p f < "$RESULTS_FILE"
  if [[ "$cond" == "true" ]]; then echo "  ✓ $name"; echo "$((p+1)) $f" > "$RESULTS_FILE"
  else echo "  ✗ $name"; echo "$p $((f+1))" > "$RESULTS_FILE"; fi
}
eq() { # eq <label> <got> <want>
  assert "$1 → $3 (实际 $2)" "$([[ "$2" == "$3" ]] && echo true || echo false)"
}
contains() { # contains <label> <haystack> <needle>
  assert "$1" "$(grep -qF -- "$3" <<<"$2" && echo true || echo false)"
}
notcontains() {
  assert "$1" "$(grep -qF -- "$3" <<<"$2" && echo false || echo true)"
}

[[ -f "$LIB" ]] || { echo "  ✗ lib/verify/reqmatrix.sh 不存在（未实现）"; echo "=== PASS=0 FAIL=1 ==="; exit 1; }
source "$LIB"

echo "=== verify requirement-matrix tests ==="
echo

# ---------------------------------------------------------------------------
# E1 提取：条目数由工具从需求源数出来，模型无权决定有几条
# ---------------------------------------------------------------------------
echo "X1: 从 '## 验收标准' 章节取一级列表项"
T=$(mktemp -d)
cat > "$T/plan.md" <<'EOF'
# 导出功能

## 背景
用户需要导出。这里写点散文，带一个 - 破折号列表项也不该被数进去。

## 验收标准
- 表格支持关键词搜索
- 支持导出全部内容为 CSV
- 导出失败时给出错误提示

## 实现步骤
- [ ] 写接口
- [ ] 写前端
EOF
eq "条目数" "$(reqmatrix_extract_items "$T/plan.md" | wc -l | tr -d ' ')" 3
contains "第1条内容" "$(reqmatrix_extract_items "$T/plan.md")" "表格支持关键词搜索"
notcontains "不含实现步骤" "$(reqmatrix_extract_items "$T/plan.md")" "写接口"
notcontains "不含背景散文" "$(reqmatrix_extract_items "$T/plan.md")" "破折号"

echo "X2: 嵌套子项不单独计条"
cat > "$T/nested.md" <<'EOF'
## 验收标准
- 支持导出
  - CSV 格式
  - Excel 格式
- 支持搜索
EOF
eq "嵌套只算父项" "$(reqmatrix_extract_items "$T/nested.md" | wc -l | tr -d ' ')" 2

echo "X3: 章节别名"
for h in "## Acceptance" "## 验收清单" "## Acceptance Criteria"; do
  printf '%s\n- 一条需求\n' "$h" > "$T/alias.md"
  eq "识别 '$h'" "$(reqmatrix_extract_items "$T/alias.md" | wc -l | tr -d ' ')" 1
done

echo "X3b: 章节名带限定词也要识别（接入摩擦 = 严格分支上的硬失败）"
for h in "## 验收标准（MVP）" "## Acceptance Criteria:" "## 验收标准 (第一期)" "### 验收清单——最小集"; do
  printf '%s\n- 一条需求\n- 又一条\n' "$h" > "$T/alias2.md"
  eq "识别 '$h'" "$(reqmatrix_extract_items "$T/alias2.md" | wc -l | tr -d ' ')" 2
done

echo "X3c: ⛔ 但不能宽到把别的章节也当验收（否则条数全乱）"
printf '## 验收标准之外的说明\n- 不是需求\n' > "$T/alias3.md"
reqmatrix_extract_items "$T/alias3.md" >/dev/null 2>&1
eq "「验收标准之外的说明」不算验收章节" "$?" 3

echo "X4: 到下一个同级标题为止"
cat > "$T/stop.md" <<'EOF'
## 验收标准
- 甲
- 乙
## 其他
- 丙
- 丁
EOF
eq "不越过下个 ## " "$(reqmatrix_extract_items "$T/stop.md" | wc -l | tr -d ' ')" 2

echo "X5: Gherkin Scenario 每个算一条"
cat > "$T/f.feature" <<'EOF'
Feature: 导出
  Scenario: 搜索后导出
    Given 有数据
  Scenario: 空结果导出
    Given 无数据
  场景: 中文场景关键字
    Given 啥都行
EOF
eq "Scenario+场景 计数" "$(reqmatrix_extract_items "$T/f.feature" | wc -l | tr -d ' ')" 3

echo "X6: 没有验收章节 → tier none（退出码 3），不猜"
printf '# 计划\n\n## 实现步骤\n- [ ] 甲\n- [ ] 乙\n- [ ] 丙\n' > "$T/nosec.md"
reqmatrix_extract_items "$T/nosec.md" >/dev/null 2>&1
eq "退出码 3" "$?" 3

echo "X7: ⛔ 绝不去数实现任务的 checkbox（会把噪音当需求）"
eq "无验收章节时输出为空" "$(reqmatrix_extract_items "$T/nosec.md" 2>/dev/null | wc -l | tr -d ' ')" 0

# ---------------------------------------------------------------------------
# 矩阵行解析
# ---------------------------------------------------------------------------
echo
echo "P1: 解析 REQ_ITEM 行"
cat > "$T/v.md" <<'EOF'
VERIFY_VERDICT: PASS
REQ_SOURCE: plan.md
REQ_ITEMS: 2

REQ_ITEM: 1 | COVERED | ui:src/List.vue:88, api:src/api.ts:12 | 搜索已接
REQ_ITEM: 2 |  COVERED  |  api:src/api.ts:40  |  导出已接
EOF
eq "解析出 2 行" "$(reqmatrix_parse "$T/v.md" | wc -l | tr -d ' ')" 2
contains "第1行状态" "$(reqmatrix_parse "$T/v.md")" "1|COVERED|"
contains "多余空白被裁掉" "$(reqmatrix_parse "$T/v.md")" "2|COVERED|api:src/api.ts:40|导出已接"

echo "P2: 未知状态 → 拒绝（fail-closed）"
printf 'REQ_ITEM: 1 | DONE | a.ts:1 | 说明\n' > "$T/bad.md"
reqmatrix_parse "$T/bad.md" >/dev/null 2>&1
assert "未知状态非零退出" "$([[ $? -ne 0 ]] && echo true || echo false)"

echo "P3: 编号重复 → 拒绝"
printf 'REQ_ITEM: 1 | COVERED | a.ts:1 | x\nREQ_ITEM: 1 | COVERED | b.ts:1 | y\n' > "$T/dup.md"
reqmatrix_parse "$T/dup.md" >/dev/null 2>&1
assert "重复编号非零退出" "$([[ $? -ne 0 ]] && echo true || echo false)"

echo "P4: 编号必须 1..N 连续"
printf 'REQ_ITEM: 1 | COVERED | a.ts:1 | x\nREQ_ITEM: 3 | COVERED | b.ts:1 | y\n' > "$T/gap.md"
reqmatrix_parse "$T/gap.md" >/dev/null 2>&1
assert "跳号非零退出" "$([[ $? -ne 0 ]] && echo true || echo false)"

# ---------------------------------------------------------------------------
# E4 判定由门禁推导
# ---------------------------------------------------------------------------
echo
echo "V1: 全 COVERED → PASS"
printf 'REQ_ITEM: 1 | COVERED | a.ts:1 | x\nREQ_ITEM: 2 | COVERED | b.ts:1 | y\n' > "$T/d1.md"
eq "推导" "$(reqmatrix_derive_verdict "$T/d1.md")" PASS

echo "V2: 任一 MISSING → FAIL"
printf 'REQ_ITEM: 1 | COVERED | a.ts:1 | x\nREQ_ITEM: 2 | MISSING | - | 没做\n' > "$T/d2.md"
eq "推导" "$(reqmatrix_derive_verdict "$T/d2.md")" FAIL

echo "V3: 任一 PARTIAL → QUESTIONS"
printf 'REQ_ITEM: 1 | COVERED | a.ts:1 | x\nREQ_ITEM: 2 | PARTIAL | b.ts:1 | 缺分页\n' > "$T/d3.md"
eq "推导" "$(reqmatrix_derive_verdict "$T/d3.md")" QUESTIONS

echo "V4: DEFERRED / NA / PREEXISTING 不导致 FAIL"
printf 'REQ_ITEM: 1 | DEFERRED | - | 下个PR\nREQ_ITEM: 2 | NA | - | 不适用\nREQ_ITEM: 3 | PREEXISTING | a.ts:1 | 既有\n' > "$T/d4.md"
eq "推导" "$(reqmatrix_derive_verdict "$T/d4.md")" PASS

echo "V5: MISSING 优先于 PARTIAL（取最严）"
printf 'REQ_ITEM: 1 | PARTIAL | a.ts:1 | x\nREQ_ITEM: 2 | MISSING | - | 没做\n' > "$T/d5.md"
eq "推导" "$(reqmatrix_derive_verdict "$T/d5.md")" FAIL

echo "V6: 模型申报比推导宽松 → 采用推导（compute, don't accept）"
printf 'VERIFY_VERDICT: PASS\nREQ_ITEM: 1 | MISSING | - | 没做\n' > "$T/d6.md"
eq "推导压过申报" "$(reqmatrix_reconcile_verdict "$T/d6.md")" FAIL

echo "V7: 模型申报比推导更严 → 保留申报（不放宽别人的结论）"
printf 'VERIFY_VERDICT: FAIL\nREQ_ITEM: 1 | COVERED | a.ts:1 | x\n' > "$T/d7.md"
eq "保留 FAIL" "$(reqmatrix_reconcile_verdict "$T/d7.md")" FAIL

# ---------------------------------------------------------------------------
# E1 对账：条数不符必须说清缺哪几号
# ---------------------------------------------------------------------------
echo
echo "C1: 条数不符 → 非零退出并点出缺号"
printf '## 验收标准\n- 甲\n- 乙\n- 丙\n' > "$T/src3.md"
printf 'REQ_ITEM: 1 | COVERED | a.ts:1 | x\nREQ_ITEM: 2 | COVERED | b.ts:1 | y\n' > "$T/m2.md"
OUT=$(reqmatrix_check_count "$T/m2.md" "$T/src3.md" 2>&1); RC=$?
assert "非零退出" "$([[ $RC -ne 0 ]] && echo true || echo false)"
contains "点出需求 3 条" "$OUT" "3"
contains "点出矩阵 2 条" "$OUT" "2"

echo "C2: 条数相符 → 通过"
printf 'REQ_ITEM: 1 | COVERED | a.ts:1 | x\nREQ_ITEM: 2 | COVERED | b.ts:1 | y\nREQ_ITEM: 3 | MISSING | - | z\n' > "$T/m3.md"
reqmatrix_check_count "$T/m3.md" "$T/src3.md" >/dev/null 2>&1
eq "退出码 0" "$?" 0

# ---------------------------------------------------------------------------
# E2 哈希只覆盖条目块
# ---------------------------------------------------------------------------
echo
echo "H1: 改章节外的散文不改变哈希"
printf '# 标题\n\n## 背景\n原文\n\n## 验收标准\n- 甲\n- 乙\n' > "$T/h1.md"
printf '# 标题\n\n## 背景\n原文改了个错别字\n\n## 验收标准\n- 甲\n- 乙\n' > "$T/h2.md"
eq "两者哈希相同" "$([[ "$(reqmatrix_block_hash "$T/h1.md")" == "$(reqmatrix_block_hash "$T/h2.md")" ]] && echo same || echo diff)" same

echo "H2: 改条目本身 → 哈希变化"
printf '## 验收标准\n- 甲\n- 丙\n' > "$T/h3.md"
eq "哈希不同" "$([[ "$(reqmatrix_block_hash "$T/h1.md")" == "$(reqmatrix_block_hash "$T/h3.md")" ]] && echo same || echo diff)" diff

echo "H3: 删掉一条 → 哈希变化（这是要防的）"
printf '## 验收标准\n- 甲\n' > "$T/h4.md"
eq "哈希不同" "$([[ "$(reqmatrix_block_hash "$T/h1.md")" == "$(reqmatrix_block_hash "$T/h4.md")" ]] && echo same || echo diff)" diff

echo "H4: 行尾空白/CRLF 归一化后不影响"
printf '## 验收标准\n- 甲   \n- 乙\t\n' > "$T/h5.md"
eq "哈希相同" "$([[ "$(reqmatrix_block_hash "$T/h1.md")" == "$(reqmatrix_block_hash "$T/h5.md")" ]] && echo same || echo diff)" same

# ---------------------------------------------------------------------------
# E3 引用必须落在本次改动内
# ---------------------------------------------------------------------------
echo
echo "G: 引用校验（需要 git 仓库）"
G=$(mktemp -d)
(
  cd "$G" || exit 1
  git init -q . && git config user.email t@t && git config user.name t
  mkdir -p src
  echo "old" > src/kept.ts
  echo "old" > src/deleted.ts
  echo "old" > src/untouched.ts
  echo "old" > src/dirty.ts
  echo "long enough content that rename detection pairs these two paths" > src/renamed-from.ts
  git add -A && git commit -qm init
  echo "new" >> src/kept.ts
  git rm -q src/deleted.ts
  echo "brand new" > src/added.ts
  git mv src/renamed-from.ts src/renamed-to.ts
  git add -A
  # modified in the worktree, deliberately NOT staged — a pre-commit hook must judge the
  # staged tree, but the message for this case has to say WHY, not just "not in this change"
  echo "not added" >> src/dirty.ts
  # exists on disk but git has never seen it: os.path.exists() alone would accept this
  # as "pre-existing code", turning `ui:~…` into something a scratch file can forge
  echo "fake" > src/untracked.ts
) || true

run_g() { ( cd "$G" && reqmatrix_check_citations "$1" 2>&1 ); }
rc_g()  { ( cd "$G" && reqmatrix_check_citations "$1" >/dev/null 2>&1; echo $? ); }

printf 'REQ_ITEM: 1 | COVERED | api:src/kept.ts:2 | 改过\n' > "$T/g1.md"
eq "G1 COVERED 引用已 staged 修改的文件 → 0" "$(rc_g "$T/g1.md")" 0

printf 'REQ_ITEM: 1 | COVERED | api:src/added.ts:1 | 新增\n' > "$T/g2.md"
eq "G2 COVERED 引用新增文件 → 0" "$(rc_g "$T/g2.md")" 0

printf 'REQ_ITEM: 1 | COVERED | api:src/deleted.ts:1 | 已删除\n' > "$T/g3.md"
eq "G3 COVERED 引用已删除文件 → 0（删除类需求）" "$(rc_g "$T/g3.md")" 0

printf 'REQ_ITEM: 1 | COVERED | api:src/untouched.ts:1 | 存在但没改\n' > "$T/g4.md"
assert "G4 COVERED 引用未改动文件 → 非零（指鹿为马）" "$([[ "$(rc_g "$T/g4.md")" != "0" ]] && echo true || echo false)"
contains "G4 点出该路径" "$(run_g "$T/g4.md")" "src/untouched.ts"

printf 'REQ_ITEM: 1 | COVERED | api:src/ghost.ts:1 | 编造的\n' > "$T/g5.md"
assert "G5 COVERED 引用不存在文件 → 非零" "$([[ "$(rc_g "$T/g5.md")" != "0" ]] && echo true || echo false)"

printf 'REQ_ITEM: 1 | PREEXISTING | api:src/untouched.ts:1 | 既有覆盖\n' > "$T/g6.md"
eq "G6 PREEXISTING 引用未改动但存在的文件 → 0" "$(rc_g "$T/g6.md")" 0

printf 'REQ_ITEM: 1 | PREEXISTING | api:src/ghost.ts:1 | 编造的\n' > "$T/g7.md"
assert "G7 PREEXISTING 引用不存在文件 → 非零" "$([[ "$(rc_g "$T/g7.md")" != "0" ]] && echo true || echo false)"

printf 'REQ_ITEM: 1 | MISSING | - | 没做\n' > "$T/g8.md"
eq "G8 MISSING 无需引用 → 0" "$(rc_g "$T/g8.md")" 0

printf 'REQ_ITEM: 1 | COVERED | RUN:.agent/verify/runs/e2e.json | 跑过 E2E\n' > "$T/g9.md"
eq "G9 RUN: 运行产物豁免路径解析 → 0" "$(rc_g "$T/g9.md")" 0

printf 'REQ_ITEM: 1 | COVERED | EXT:阿里云控制台 SLB 配置 | 仓外变更\n' > "$T/g10.md"
eq "G10 EXT: 仓外证据豁免 → 0" "$(rc_g "$T/g10.md")" 0

printf 'REQ_ITEM: 1 | DEFERRED | - | 下个PR做\n' > "$T/g11.md"
eq "G11 DEFERRED 无需引用 → 0" "$(rc_g "$T/g11.md")" 0

# v4: 状态下沉到每条证据。`~` = 既有、本次未改。
# 若无此表达，「UI 早就有、本次只补 api」这类真完成项会被 E3+E6 联动误伤 —— 而
# 假失败比漏抓更贵，它会让人直接绕过门禁。
printf 'REQ_ITEM: 1 | COVERED | api:src/kept.ts:2, ui:~src/untouched.ts:1 | 按钮既有，本次补接口\n' > "$T/g12.md"
eq "G12 混合层：本次改 api + 既有 ui(~) → 0" "$(rc_g "$T/g12.md")" 0

printf 'REQ_ITEM: 1 | COVERED | api:src/kept.ts:2, ui:~src/ghost.vue:1 | 编造既有入口\n' > "$T/g13.md"
assert "G13 ~ 路径不存在 → 非零" "$([[ "$(rc_g "$T/g13.md")" != "0" ]] && echo true || echo false)"

printf 'REQ_ITEM: 1 | COVERED | ui:~src/untouched.ts:1 | 全是既有\n' > "$T/g14.md"
eq "G14 全 ~ 的引用本身合法 → 0（由 surface_report 报 NOTHING_TOUCHED）" "$(rc_g "$T/g14.md")" 0

# --- 分隔与空白：模型的真实书写习惯 ---
# 这几条来自 gemini-3.1-pro 对实现的审查。第一条尤其要记：`tr ',' '\n'` 是字符级盲替，
# 而代码注释当时声称「EXT:/RUN: 里的逗号被容忍」—— 注释在骗人，比没注释更糟。
printf 'REQ_ITEM: 1 | COVERED | EXT:JIRA-123, 已与 PM 确认过配置\n' > "$T/g15.md"
eq "G15 EXT: 自由文本里的逗号不被切开 → 0" "$(rc_g "$T/g15.md")" 0

printf 'REQ_ITEM: 1 | COVERED | RUN:.agent/verify/runs/e2e.json, 详见附件说明\n' > "$T/g16.md"
eq "G16 RUN: 自由文本里的逗号不被切开 → 0" "$(rc_g "$T/g16.md")" 0

printf 'REQ_ITEM: 1 | COVERED | api: src/kept.ts:2 | 冒号后有空格\n' > "$T/g17.md"
eq "G17 冒号后带空格仍能解析 → 0" "$(rc_g "$T/g17.md")" 0

printf 'REQ_ITEM: 1 | COVERED | api:src/kept.ts:2, ui: ~src/untouched.ts:1 | 空格加波浪号\n' > "$T/g18.md"
eq "G18 冒号后空格 + ~ 仍识别为既有 → 0" "$(rc_g "$T/g18.md")" 0

printf 'REQ_ITEM: 1 | COVERED | api:src/dirty.ts:1 | 改了但没 git add\n' > "$T/g19.md"
assert "G19 引用改了但未 staged 的文件 → 非零" "$([[ "$(rc_g "$T/g19.md")" != "0" ]] && echo true || echo false)"
# "存在但不在本次改动内" would send the operator looking for the wrong problem.
contains "G19 ⭐ 报错说清是「未 git add」而非「不在本次改动内」" "$(run_g "$T/g19.md")" "git add"

# rename 的旧路径在 `--name-only` 里根本不出现（只报目标），所以「把 old 挪走」这类需求
# 引用旧路径会假失败。实测确认过 git 的行为，不是推断。
printf 'REQ_ITEM: 1 | COVERED | api:src/renamed-from.ts:1 | 改名的旧路径\n' > "$T/g27.md"
eq "G27 rename 的旧路径算本次改动 → 0" "$(rc_g "$T/g27.md")" 0
printf 'REQ_ITEM: 1 | COVERED | api:src/renamed-to.ts:1 | 改名的新路径\n' > "$T/g28.md"
eq "G28 rename 的新路径算本次改动 → 0" "$(rc_g "$T/g28.md")" 0

printf 'REQ_ITEM: 1 | COVERED | api:src/kept.ts:2 , ui:~src/untouched.ts:1 | 逗号两边都有空格\n' > "$T/g20.md"
eq "G20 逗号前后空白不影响切分 → 0" "$(rc_g "$T/g20.md")" 0

# --- 空证据与伪造既有：gpt-5.4 复审三个 P0 里的两个 ---
printf 'REQ_ITEM: 1 | COVERED | - | 我说做了\n' > "$T/g21.md"
assert "G21 ⛔ COVERED 但证据为空 → 非零（最便宜的静默绕过）" "$([[ "$(rc_g "$T/g21.md")" != "0" ]] && echo true || echo false)"

printf 'REQ_ITEM: 1 | COVERED | ui: | 我说做了\n' > "$T/g22.md"
assert "G22 ⛔ 层面有但路径为空 → 非零" "$([[ "$(rc_g "$T/g22.md")" != "0" ]] && echo true || echo false)"

printf 'REQ_ITEM: 1 | PARTIAL | - | 做了一半\n' > "$T/g23.md"
assert "G23 ⛔ PARTIAL 也必须给证据 → 非零" "$([[ "$(rc_g "$T/g23.md")" != "0" ]] && echo true || echo false)"

printf 'REQ_ITEM: 1 | COVERED | api:src/kept.ts:2, ui:~src/untracked.ts:1 | 拿未跟踪文件冒充既有入口\n' > "$T/g24.md"
assert "G24 ⛔ ~ 引用 git 从未跟踪的文件 → 非零" "$([[ "$(rc_g "$T/g24.md")" != "0" ]] && echo true || echo false)"
contains "G24 点出该路径" "$(run_g "$T/g24.md")" "src/untracked.ts"

printf 'REQ_ITEM: 1 | PREEXISTING | ui:src/untracked.ts:1 | 同样不算既有\n' > "$T/g25.md"
assert "G25 ⛔ PREEXISTING 引用未跟踪文件 → 非零" "$([[ "$(rc_g "$T/g25.md")" != "0" ]] && echo true || echo false)"

printf 'REQ_ITEM: 1 | NA | - | 不适用\nREQ_ITEM: 2 | DEFERRED | - | 下个PR\nREQ_ITEM: 3 | MISSING | - | 没做\n' > "$T/g26.md"
eq "G26 NA/DEFERRED/MISSING 本就无证据 → 0（不能连带误伤）" "$(rc_g "$T/g26.md")" 0


# ---------------------------------------------------------------------------
# E6 层面声明
# ---------------------------------------------------------------------------
echo
echo "S1: 整个矩阵零 ui: 证据 → 报告缺 UI"
printf 'REQ_ITEM: 1 | COVERED | api:src/a.ts:1 | 后端\nREQ_ITEM: 2 | COVERED | api:src/b.ts:1 | 后端\n' > "$T/s1.md"
contains "报告 no-ui" "$(reqmatrix_surface_report "$T/s1.md")" "NO_UI_EVIDENCE"

echo "S2: 有 ui: 证据 → 不报"
printf 'REQ_ITEM: 1 | COVERED | ui:src/A.vue:1, api:src/a.ts:1 | 全链路\n' > "$T/s2.md"
notcontains "不报 no-ui" "$(reqmatrix_surface_report "$T/s2.md")" "NO_UI_EVIDENCE"

echo "S3: 显式 NO_UI:<理由> → 不报，但计数"
printf 'REQ_ITEM: 1 | COVERED | api:src/a.ts:1, NO_UI:纯定时任务 | 无界面\n' > "$T/s3.md"
OUT=$(reqmatrix_surface_report "$T/s3.md")
notcontains "不报 no-ui" "$OUT" "NO_UI_EVIDENCE"
contains "记录声明数" "$OUT" "NO_UI_DECLARED=1"

echo "S4: 逃逸口计数打印（可见性是唯一缓解手段）"
printf 'REQ_ITEM: 1 | NA | - | 不适用\nREQ_ITEM: 2 | DEFERRED | - | 下个PR\nREQ_ITEM: 3 | PREEXISTING | a.ts:1 | 既有\nREQ_ITEM: 4 | COVERED | ui:b.vue:1 | 做了\n' > "$T/s4.md"
OUT=$(reqmatrix_surface_report "$T/s4.md")
contains "NA 计数" "$OUT" "NA=1"
contains "DEFERRED 计数" "$OUT" "DEFERRED=1"
contains "PREEXISTING 计数" "$OUT" "PREEXISTING=1"

echo "S5: 全部 PREEXISTING → 额外告警（等于啥也没干也能过）"
printf 'REQ_ITEM: 1 | PREEXISTING | a.ts:1 | 既有\nREQ_ITEM: 2 | PREEXISTING | b.ts:1 | 既有\n' > "$T/s5.md"
contains "报 ALL_PREEXISTING" "$(reqmatrix_surface_report "$T/s5.md")" "ALL_PREEXISTING"

echo "S6: COVERED 但全部证据带 ~ → 报 NOTHING_TOUCHED（本次其实啥也没干）"
printf 'REQ_ITEM: 1 | COVERED | ui:~a.vue:1, api:~b.ts:1 | 全既有\n' > "$T/s6.md"
contains "报 NOTHING_TOUCHED" "$(reqmatrix_surface_report "$T/s6.md")" "NOTHING_TOUCHED"

echo "S7: ui:~ 也算 ui 层面证据（入口既有也是入口）"
printf 'REQ_ITEM: 1 | COVERED | api:b.ts:1, ui:~a.vue:1 | 补接口\n' > "$T/s7.md"
notcontains "不报 no-ui" "$(reqmatrix_surface_report "$T/s7.md")" "NO_UI_EVIDENCE"

echo "S8: 至少一条不带 ~ 时不报 NOTHING_TOUCHED"
notcontains "不报 NOTHING_TOUCHED" "$(reqmatrix_surface_report "$T/s7.md")" "NOTHING_TOUCHED"

echo "S9: 冒号后带空格的 ui: 也要算成 ui 证据（否则误报纵向漏层）"
printf 'REQ_ITEM: 1 | COVERED | ui: a.vue:1, api: b.ts:1 | 冒号后空格\n' > "$T/s9.md"
notcontains "不报 no-ui" "$(reqmatrix_surface_report "$T/s9.md")" "NO_UI_EVIDENCE"


echo "S11: 只有 RUN:/EXT: 证据 → 计数打印（设计上允许，但要可见）"
printf 'REQ_ITEM: 1 | COVERED | RUN:.agent/verify/runs/e2e.json | 只有运行产物\n' > "$T/s11.md"
contains "报 EXTERNAL_ONLY" "$(reqmatrix_surface_report "$T/s11.md")" "EXTERNAL_ONLY=1"

echo "S13: ⭐ 只有 RUN: 运行产物 → 不该误报缺 UI（运行本身就证明了可达）"
# 计划 §4.6 说运行产物是更强的证据，E6 又把可达性硬绑定到仓内 ui: —— 两处打架。
# 真实完成但 UI 在别的仓、或只能靠 E2E 结果证明可达的条目会被误报。
printf 'REQ_ITEM: 1 | COVERED | RUN:.agent/verify/runs/e2e.json | E2E 跑通了完整用户路径\n' > "$T/s13.md"
OUT=$(reqmatrix_surface_report "$T/s13.md")
notcontains "不报 no-ui" "$OUT" "NO_UI_EVIDENCE"
contains "但仍计入 EXTERNAL_ONLY（可见）" "$OUT" "EXTERNAL_ONLY=1"

echo "S14: EXT: 仓外证据同样算可达，也同样计数"
printf 'REQ_ITEM: 1 | COVERED | EXT:阿里云控制台已配置 | 仓外变更\n' > "$T/s14.md"
OUT=$(reqmatrix_surface_report "$T/s14.md")
notcontains "不报 no-ui" "$OUT" "NO_UI_EVIDENCE"

echo "S15: ⛔ 纯 api: 证据仍然要报缺 UI（这才是纵向漏层）"
printf 'REQ_ITEM: 1 | COVERED | api:src/a.ts:1 | 只有后端\n' > "$T/s15.md"
contains "报 NO_UI_EVIDENCE" "$(reqmatrix_surface_report "$T/s15.md")" "NO_UI_EVIDENCE"

echo "S12: COVERED 证据为空 → 报 NO_EVIDENCE（别静默）"
printf 'REQ_ITEM: 1 | COVERED | - | 我说做了\n' > "$T/s12.md"
contains "报 NO_EVIDENCE" "$(reqmatrix_surface_report "$T/s12.md")" "NO_EVIDENCE"

echo "S10: EXT: 自由文本里的逗号不该被当成第二条证据"
printf 'REQ_ITEM: 1 | COVERED | ui:a.vue:1, EXT:配置已改, 与运维确认\n' > "$T/s10.md"
OUT=$(reqmatrix_surface_report "$T/s10.md")
notcontains "不报 no-ui" "$OUT" "NO_UI_EVIDENCE"
notcontains "不报 NOTHING_TOUCHED" "$OUT" "NOTHING_TOUCHED"

# ---------------------------------------------------------------------------
# errexit — the caller runs under `set -euo pipefail`
#
# WHY THIS SECTION EXISTS: this test file runs under `set -uo pipefail` (no -e), but the
# gate that calls this library runs with -e. A pipeline like `grep -v` over an empty list
# returns 1, pipefail promotes it to the pipeline's status, and `X=$(...)` then exits the
# whole script. That is exactly what happened: the gate died silently right after its
# banner and 16 unrelated tests failed with "expected exit 0" while the output looked
# clean. Every assertion in this file passed throughout — because the harness had -e off.
#
# So each public function is exercised again under the caller's real shell options, and
# the assertion is on OUTPUT COMPLETENESS: premature death truncates, it does not shout.
# ---------------------------------------------------------------------------
echo
echo "E: set -euo pipefail 下不得提前死亡（调用方的真实 shell 选项）"
EE=$(mktemp -d)
printf '## 验收标准\n- 甲\n- 乙\n' > "$EE/src.md"
printf '# 无验收章节\n\n## 实现\n- [ ] x\n' > "$EE/nosec.md"
printf 'VERIFY_VERDICT: PASS\nREQ_ITEM: 1 | COVERED | api:a.ts:1 | x\nREQ_ITEM: 2 | PREEXISTING | ui:~b.vue:2 | y\n' > "$EE/m.md"
run_ee() { ( set -euo pipefail; source "$LIB"; "$@" ) 2>/dev/null; }
rc_ee()  { ( set -euo pipefail; source "$LIB"; "$@" ) >/dev/null 2>&1; echo $?; }

eq "E1 extract_items 输出完整（2 条）" "$(run_ee reqmatrix_extract_items "$EE/src.md" | wc -l | tr -d ' ')" 2
eq "E2 无章节时干净返回 3 而非崩在半路" "$(rc_ee reqmatrix_extract_items "$EE/nosec.md")" 3
eq "E3 block_hash 输出 64 位 hex" "$(run_ee reqmatrix_block_hash "$EE/src.md" | tr -d '\n' | wc -c | tr -d ' ')" 64
eq "E4 parse 输出完整（2 行）" "$(run_ee reqmatrix_parse "$EE/m.md" | wc -l | tr -d ' ')" 2
eq "E5 derive_verdict 有输出" "$(run_ee reqmatrix_derive_verdict "$EE/m.md")" PASS
eq "E6 reconcile_verdict 有输出" "$(run_ee reqmatrix_reconcile_verdict "$EE/m.md")" PASS
eq "E7 check_count 条数相符 → 0" "$(rc_ee reqmatrix_check_count "$EE/m.md" "$EE/src.md")" 0
# surface_report is the one most exposed: it loops entries and greps for tokens that are
# usually absent, i.e. exactly the pattern that returns non-zero and takes -e with it.
OUT=$(run_ee reqmatrix_surface_report "$EE/m.md")
contains "E8 surface_report 跑到最后（有 TOTAL）" "$OUT" "TOTAL=2"
contains "E8 surface_report 逃逸口计数完整" "$OUT" "PREEXISTING=1"
( cd "$G" && ee_rc=$( ( set -euo pipefail; source "$LIB"; reqmatrix_check_citations "$T/g12.md" ) >/dev/null 2>&1; echo $? )
  eq "E9 check_citations 混合层引用 → 0" "$ee_rc" 0 )
# reconcile 在没有 VERIFY_VERDICT 行时要回退到推导值。set -e 下 grep 找不到会让赋值
# 语句非零、直接退出，fallback 那行根本走不到 —— gate 目前没炸只是因为上游先要求了
# VERIFY_VERDICT，库函数本身仍然不安全（gpt-5.4 实测复现）。
printf 'REQ_ITEM: 1 | MISSING | - | 没做\n' > "$EE/noverdict.md"
eq "E10 无 VERIFY_VERDICT 行时回退到推导值" "$(run_ee reqmatrix_reconcile_verdict "$EE/noverdict.md")" FAIL
eq "E11 无 VERIFY_VERDICT 行时退出码为 0" "$(rc_ee reqmatrix_reconcile_verdict "$EE/noverdict.md")" 0
rm -rf "$EE"

rm -rf "$T" "$G" "$AGENT_GATES_DIR"
echo
read -r P F < "$RESULTS_FILE"
echo "=== PASS=$P FAIL=$F ==="
rm -f "$RESULTS_FILE"
[[ "$F" -eq 0 ]]
