#!/usr/bin/env bash
# CHECK 5 在**多份审查产物**里选哪一份，以及怎么读一份产物的结论。
#
# 🔴 起因（2026-09-11，一线被卡）：第三轮 PASS 的锚点与 commit 完全匹配，门禁却选中了
# 第二轮那份 FAIL（锚点早已失效）⇒ 「同轮任一 FAIL 会拦住后续 PASS」。
# 后果不只是卡一次：**只要同一个 HEAD 上存在过一份 FAIL，CHECK 5 就永远过不去**，
# 除非把那份产物删掉 —— 等于在教人删审查记录。而「修完再审一轮」是设计里的正常流程。
#
# 🔴 异构审查（gpt-5.6-sol）在第一版修复上又抓到两条严重的，都是**结论怎么读**：
#   ① `VERDICT: PASS_WITH_ISSUES` / `PASSENGER` 被前缀匹配成干净 PASS ⇒ 能取代真 FAIL
#   ② `**VERDICT: FAIL**`（协议允许的合法写法）门禁**根本看不到** ⇒ 击穿「同 diff 分歧
#      时 fail-closed」。而 `lib/hetero/conclusion.sh` 早就把这些处理对了。
#
# ⛔ 三条安全性质不能放松（T2/T3/T4/T4b/T8/T9/T11 锁住）：
#   - 过期 PASS ⛔ 不能盖掉命中当前 diff 的 FAIL
#   - 同一份 diff 上 FAIL 与 PASS 并存时 fail-closed（含装饰写法、含同文件两行）
#   - 没有任何产物绑定当前 diff 时，行为一字不变
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GATE="$SCRIPT_DIR/../hooks/git/agent-quality-gate.sh"
# ⛔ 核对文案里的参数时用**仓库内**这份，不是已安装那份 —— 待发布的改动才是被测对象
# （异构审指出：原来核的是 $HOME/.agent-gates/bin/，且工具缺失时直接记 PASS）。
VERIFY_IMPORT="$SCRIPT_DIR/../bin/agent-gates-verify-import"
RESULTS_FILE=$(mktemp); echo "0 0" > "$RESULTS_FILE"
assert() {
  local name="$1" cond="$2" p f
  read -r p f < "$RESULTS_FILE"
  if [[ "$cond" == "true" ]]; then echo "  ✓ $name"; echo "$((p+1)) $f" > "$RESULTS_FILE"
  else echo "  ✗ $name"; echo "$p $((f+1))" > "$RESULTS_FILE"; fi
}

# ⛔ 隔离用户级能力文件：有它 Gate 2b 会要求 REVIEW_LEVEL，与本文件被测的选取逻辑无关。
GD=$(mktemp -d); export AGENT_GATES_DIR="$GD"

STALE=deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef
_sha() { if command -v sha256sum >/dev/null 2>&1; then sha256sum | awk '{print $1}'; else shasum -a 256 | awk '{print $1}'; fi; }

# mkcase "<cur|stale>@<结论正文>" ...
#   结论正文里的 `;;` 会展开成换行（用来造「同一文件两条 verdict」）。
#   输出 = 门禁输出 + 末行 `__RC__=<退出码>`。
#   ⛔ 必须把退出码交出来：原来 mkcase 用 `|| true` 吞掉它，于是「放行」类断言只检查
#      没出现拦截文案 —— 取代之后再加一条别的 fail 也照样全绿（异构审指出）。
mkcase() {
  local d; d=$(mktemp -d)
  ( cd "$d"
    git init -q .; git config user.email t@t; git config user.name t
    git symbolic-ref HEAD refs/heads/feat/x
    mkdir -p .agent/reviews
    # ⛔ 分支**不能**出现在 strict_branches 里：那会触发门禁的「strict 分支强制 strict」
    #    覆盖，把 verify.mode=off 一起顶掉 ⇒ CHECK 6 插进来一条与本文件无关的失败，
    #    而「放行」类断言一旦要求退出码 0 就会集体假红（本轮实测）。
    #    review.mode=strict 在普通分支上照样生效，CHECK 5 该跑就跑。
    printf '{"mode":"strict","review":{"mode":"strict"},"verify":{"mode":"off"}}' \
      > .agent/gates.json
    local n i
    for n in a b c; do printf 'export const %s=1\n' "$n" > "svc$n.ts"; printf 'test\n' > "svc$n.test.ts"; done
    git add -A && git commit -q -m init
    for n in a b c; do for i in $(seq 1 25); do echo "export const v$i=$i" >> "svc$n.ts"; done; done
    git add svc*.ts

    local H FILES FSHA DSHA
    H=$(git rev-parse HEAD)
    FILES=$(git -c core.quotePath=true diff --cached --name-only --diff-filter=ACMRD -- . \
      ':(exclude).agent/reviews/**' ':(exclude).agent/verify/**' ':(exclude).agent/plans/**')
    FSHA=$(printf '%s\n' "$FILES" | _sha)
    DSHA=$(git diff --cached --binary -- . \
      ':(exclude).agent/reviews/**' ':(exclude).agent/verify/**' ':(exclude).agent/plans/**' | _sha)

    # 共享产物库的 key —— ⛔ 这是对 `_gate_artifact_store_dir` 的镜像实现。
    # 算错不会静默通过：T16 断言「共享库里的 PASS 取代了本地 FAIL」，key 不对就是红的。
    local _common _pdir _base _key STORE
    _common=$(git rev-parse --git-common-dir 2>/dev/null)
    _pdir=$(cd -P "$(dirname "$_common")" 2>/dev/null && pwd -P)
    _base=$(basename "$_common")
    _key=$(printf '%s' "$_pdir/$_base" | _sha | cut -c1-16)
    STORE="${AGENT_GATES_DIR}/artifacts/${_key}/reviews"

    local idx=0 spec which body anchor dest
    for spec in "$@"; do
      idx=$((idx+1)); which="${spec%%@*}"; body="${spec#*@}"
      # `shared-` 前缀 ⇒ 写进按仓库分键的共享库，而不是项目内 .agent/reviews/
      if [[ "$which" == shared-* ]]; then
        which="${which#shared-}"; mkdir -p "$STORE"; dest="$STORE/r${idx}.md"
      else
        dest=".agent/reviews/r${idx}.md"
      fi
      [[ "$which" == "cur" ]] && anchor="$DSHA" || anchor="$STALE"
      {
        printf '<!-- REVIEW_HEAD: %s -->\n' "$H"
        printf '%s\n' "$FILES" | sed 's/^/<!-- REVIEW_FILE: /; s/$/ -->/'
        printf '<!-- REVIEW_FILES_SHA256: %s -->\n' "$FSHA"
        printf '<!-- REVIEW_DIFF_SHA256: %s -->\n\n' "$anchor"
        printf '%s\n' "${body//;;/$'\n'}"
      } > "$dest"
    done
    local out rc
    out=$(AGENT_MODE=1 bash "$GATE" 2>&1); rc=$?
    printf '%s\n__RC__=%s\n' "$out" "$rc"
  )
}
BLOCK='Applicable review verdict is ISSUES/FAIL'
_rc()      { printf '%s\n' "$1" | sed -n 's/^__RC__=//p'; }
_blocked() { [[ "$1" == *"$BLOCK"* ]] && echo true || echo false; }
# ⭐ 「放行」必须同时满足：退出码 0 + 打出 PASSED + 没有任何 GATE: 失败行
_allowed() {
  if [[ "$(_rc "$1")" == "0" && "$1" == *"Agent Quality Gate PASSED"* && "$1" != *"❌ GATE:"* ]]
  then echo true; else echo false; fi
}

echo "=== CHECK 5 产物选取 ==="
echo
echo "--- T1 过期 FAIL + 命中当前 diff 的 PASS ⇒ ⭐ 放行（一线报的那条）---"
out=$(mkcase "stale@VERDICT: FAIL" "cur@VERDICT: PASS")
assert "⭐ 真的放行（退出码 0 + PASSED，实际 rc=$(_rc "$out")）" "$(_allowed "$out")"
assert "⭐ 说出来是被取代了（⛔ 不是静默放行）" \
  "$([[ "$out" == *取代* || "$out" == *superseded* ]] && echo true || echo false)"
assert "⛔ 也不该退化成「没有审查证据」" \
  "$([[ "$out" != *"No content-anchored review evidence"* ]] && echo true || echo false)"

echo
echo "--- T2 反向：过期 PASS + 命中当前 diff 的 FAIL ⇒ ⛔ 必须拦 ---"
out=$(mkcase "stale@VERDICT: PASS" "cur@VERDICT: FAIL")
assert "⛔ 命中当前 diff 的 FAIL 照拦" "$(_blocked "$out")"
assert "⛔ 点名的是那份 FAIL（r2）" "$([[ "$out" == *r2.md* ]] && echo true || echo false)"

echo
echo "--- T3 同一份 diff 上 FAIL 与 PASS 并存 ⇒ ⛔ fail-closed ---"
out=$(mkcase "cur@VERDICT: FAIL" "cur@VERDICT: PASS")
assert "⛔ 两个审查者对同一份代码分歧时按拦处理" "$(_blocked "$out")"

echo
echo "--- T4 只有过期 FAIL、没有任何 PASS ⇒ ⛔ 仍要拦 ---"
out=$(mkcase "stale@VERDICT: FAIL")
# ⛔ 只断言「还是红的」太松：变异测试实测，摘掉「PASS 必须命中当前 diff」后这条照样绿
#    （FAIL 被清掉，倒在「缺 PASS 结论」上，仍是红但原因变了）。⇒ 钉住拦的**理由**。
assert "⛔ 拦的理由仍是那份 FAIL，不是别的" "$(_blocked "$out")"

echo
echo "--- T4b 过期 FAIL + 过期 PASS ⇒ ⛔ 必须拦（这是真正的绕过路径）---"
# 🔴 拿到 FAIL 后随便改一行（锚点即失效），再拿一份更早的过期 PASS 顶上 ——
# 若取代逻辑不要求「PASS 精确命中当前 diff」，这里就只剩一条警告然后放行 ⇒ 门禁被绕过。
out=$(mkcase "stale@VERDICT: PASS" "stale@VERDICT: FAIL")
assert "⛔ 两份都过期时 FAIL 仍然拦住" "$(_blocked "$out")"
assert "⛔ 且确实没放行（退出码非 0）" "$([[ "$(_rc "$out")" != "0" ]] && echo true || echo false)"

echo
echo "--- T5 只有过期 PASS ⇒ 保持原行为（警告 + 放行）---"
out=$(mkcase "stale@VERDICT: PASS")
assert "⭐ 仍放行" "$(_allowed "$out")"
assert "⭐ 仍给「审查后文件又变了」的警告" \
  "$([[ "$out" == *"reviewed files changed after cross-review"* ]] && echo true || echo false)"

echo
echo "--- T6 三轮真实形态：FAIL → FAIL → PASS(命中) ⇒ ⭐ 放行 ---"
out=$(mkcase "stale@VERDICT: FAIL" "stale@VERDICT: FAIL" "cur@VERDICT: PASS")
assert "⭐ 两份过期 FAIL 都拦不住" "$(_allowed "$out")"

echo
echo "=== 结论怎么读（异构审抓到的两条严重问题）==="
echo
echo "--- T8 带限定词的结论 ⛔ 不算干净 PASS，更不能取代 FAIL ---"
for v in 'PASS_WITH_ISSUES' 'PASS-WITH-ISSUES' 'PASSENGER' 'APPROVED_WITH_CONDITIONS' 'PASS but unresolved blockers remain'; do
  out=$(mkcase "stale@VERDICT: FAIL" "cur@VERDICT: $v")
  assert "⛔ VERDICT: $v 取代不了过期 FAIL" "$(_blocked "$out")"
done

echo
echo "--- T9 装饰过的 FAIL 必须被看见（⛔ 否则同 diff 的 fail-closed 被击穿）---"
for v in '**VERDICT: FAIL**' '## VERDICT: FAIL' '- VERDICT: FAIL' 'VERDICT：FAIL' '> VERDICT: REJECT'; do
  out=$(mkcase "cur@$v" "cur@VERDICT: PASS")
  assert "⛔ 看得见 $v" "$(_blocked "$out")"
done

echo
echo "--- T10 装饰过的 PASS 是协议允许的写法 ⇒ ⭐ 不该被误拒 ---"
for v in '**VERDICT: PASS**' '## VERDICT: PASS' 'VERDICT：PASS' '- VERDICT: APPROVED'; do
  out=$(mkcase "stale@VERDICT: FAIL" "cur@$v")
  assert "⭐ 认得 $v" "$(_allowed "$out")"
done

echo
echo "--- T11 同一文件两条结论 ⇒ ⛔ 任一为 FAIL 即拦（顺序无关）---"
# ⛔ 规范解析器的 extract_conclusion_line 取 head -1；直接拿它会让「PASS 在前」退化成 PASS，
#    比现在的行为更松。必须扫**每一条** verdict 行。
out=$(mkcase "cur@VERDICT: PASS;;VERDICT: FAIL")
assert "⛔ PASS 在前 FAIL 在后：拦" "$(_blocked "$out")"
out=$(mkcase "cur@VERDICT: FAIL;;VERDICT: PASS")
assert "⛔ FAIL 在前 PASS 在后：拦" "$(_blocked "$out")"
out=$(mkcase "cur@**VERDICT: FAIL**;;VERDICT: PASS")
assert "⛔ 装饰 FAIL + 裸 PASS 同文件：拦" "$(_blocked "$out")"

echo
echo "--- T12 REVISE / ISSUES_FOUND 语义上都是「没通过」---"
for v in 'REVISE' 'ISSUES_FOUND' 'ISSUES' 'REJECTED'; do
  out=$(mkcase "cur@VERDICT: $v" "cur@VERDICT: PASS")
  assert "⛔ VERDICT: $v 按未通过处理" "$(_blocked "$out")"
done

echo
echo "=== CHECK 6 的报错必须指出 verify-import，且参数得是真的 ==="
# 🔴 原来两条报错都没提这个工具，其中一条还说「存到 .agent/verify/<date>-<topic>.md」——
# 照做**还是过不去**（手写文件没有 dispatch 记录、算不出锚点）。一线只能自己 ls bin/ 翻。
# ⛔ 提示里的参数必须是工具**真的接受**的：我第一版写了 `--topic`，而它只认
#    --imported-model / --paseo-agent。照抄一条跑不通的命令比不给提示更坑。
_check6_out() {   # _check6_out <mkverify:0|1>
  local d; d=$(mktemp -d)
  ( cd "$d"
    git init -q .; git config user.email t@t; git config user.name t
    git symbolic-ref HEAD refs/heads/feat/x
    mkdir -p .agent/reviews
    printf '{"mode":"strict","review":{"mode":"off"},"verify":{"mode":"strict"}}' \
      > .agent/gates.json
    local n i
    for n in a b c; do printf 'export const %s=1\n' "$n" > "svc$n.ts"; printf 'test\n' > "svc$n.test.ts"; done
    git add -A && git commit -q -m init
    for n in a b c; do for i in $(seq 1 25); do echo "export const v$i=$i" >> "svc$n.ts"; done; done
    git add svc*.ts
    # mk=1：造一份**带 staged_diff_hash 但对不上当前 diff** 的产物 —— 这才走到第二个
    # 报错点（"anchored to the current staged diff"）。空目录走不到那里。
    if [[ "$1" == "1" ]]; then
      mkdir -p .agent/verify
      printf 'VERIFY_VERDICT: PASS\n' > .agent/verify/2026-01-01-old.md
      printf '{"staged_diff_hash":"%s"}\n' "deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef" \
        > .agent/verify/2026-01-01-old.dispatch.json
    fi
    AGENT_MODE=1 bash "$GATE" 2>&1 || true )
}
# ⛔ 两个报错点都要测。异构审指出原来只触发了「.agent/verify 不存在」那一处，
#    另一处（有目录但没有绑定当前 diff 的产物）以后被改坏也不会红。
for mk in 0 1; do
  tag=$([[ "$mk" == "0" ]] && echo "目录不存在" || echo "有目录但无匹配产物")
  out=$(_check6_out "$mk")
  assert "⭐ [$tag] 点名 agent-gates-verify-import" \
    "$([[ "$out" == *agent-gates-verify-import* ]] && echo true || echo false)"
done
out0=$(_check6_out 0)
assert "⛔ 不再让人手写 .agent/verify/<date>-<topic>.md 了事" \
  "$([[ "$out0" != *"save output to .agent/verify"* ]] && echo true || echo false)"
# 把两处提示里出现的 --xxx 逐个对照工具真实 usage
assert "⛔ 仓库内确实有 verify-import（⛔ 缺了不能算通过）" \
  "$([[ -f "$VERIFY_IMPORT" ]] && echo true || echo false)"
if [[ -f "$VERIFY_IMPORT" ]]; then
  vi_usage=$(bash "$VERIFY_IMPORT" 2>&1 || true)
  bad=""
  for fl in $(printf '%s\n%s\n' "$out0" "$(_check6_out 1)" | grep -o '\-\-[a-z-]*' | sort -u); do
    [[ "$fl" == "--help" || "$fl" == "--" ]] && continue
    printf '%s' "$vi_usage" | grep -q -- "$fl" || bad="$bad $fl"
  done
  assert "⭐ 提示里的参数都是 verify-import 真的接受的（多余的:${bad:-无}）" \
    "$([[ -z "$bad" ]] && echo true || echo false)"
fi

echo
echo "--- T13 非法限定结论 + 合法 PASS 同文件 ⇒ ⛔ 不算干净 PASS（round2 严重）---"
# 🔴 我第一版 `_gate_classify_verdict` 遇到非法 verdict 行直接 continue、**不留痕**，
# 只要同文件里还有一条合法 PASS 就仍判 PASS ⇒ 能取代一份真 FAIL。
# ⚠️ 而我写的注释声称「带限定词的结论落到 NONE」—— **那句话是假的**，
#    只在文件里没有别的合法 PASS 时才成立。又一次「解释性文字撒谎」。
for bad in 'VERDICT: PASS_WITH_ISSUES' 'VERDICT: FAIL but blockers remain' '## VERDICT: 待定' 'VERDICT: PASSENGER'; do
  out=$(mkcase "stale@VERDICT: FAIL" "cur@${bad};;VERDICT: PASS")
  assert "⛔ [${bad}] + 合法 PASS 仍取代不了过期 FAIL" \
    "$([[ "$(_rc "$out")" != "0" ]] && echo true || echo false)"
done
out=$(mkcase "stale@VERDICT: FAIL" "cur@VERDICT: PASS_WITH_ISSUES;;VERDICT: PASS")
assert "⭐ 报错要点出那条非法结论（⛔ 否则没法修）" \
  "$([[ "$out" == *PASS_WITH_ISSUES* ]] && echo true || echo false)"

echo
echo "--- T14 合法 FAIL + 非法行 + 合法 PASS 同文件 ⇒ ⛔ FAIL 优先 ---"
out=$(mkcase "cur@VERDICT: PASS_WITH_ISSUES;;VERDICT: FAIL;;VERDICT: PASS")
assert "⛔ FAIL 仍然优先" "$(_blocked "$out")"

echo
echo "--- T15 两份都命中当前 diff 的 PASS，⛔ 不该因文件名排序产生假失败（round2 中等）---"
# 🔴 每份命中的 PASS 都无条件覆盖 PASS_REVIEW_FILE ⇒ 排序最后一份胜出。
# 若那份 REVIEW_LEVEL 更低（L0），Gate 2b 就拦 —— 而机器上明明已有一份 L1 的当前证据。
# 这是 fail-closed 方向的**假失败**：只改文件名就能改变结果。
CAP=$(mktemp -d)
printf '{"level":"L1","review_models":{"primary":"x/y","panel_pool":[],"panel_active":2,"panel_mode":"off"}}' \
  > "$CAP/hetero-check.json"
# ⛔ **两个顺序都要测**：只测「好的在前」时，「第一份胜」和「按等级择优」都会绿
#    —— 变异测试实测漏掉（我把「最后一份胜」误改成「第一份胜」，49 条全绿）。
#    好的在后能杀掉「第一份胜」，好的在前能杀掉「最后一份胜」。
out=$(AGENT_GATES_DIR="$CAP" mkcase "cur@VERDICT: PASS;;REVIEW_LEVEL: L1" "cur@VERDICT: PASS;;REVIEW_LEVEL: L0")
assert "⭐ L1 在前、L0 在后 ⇒ 放行（杀「最后一份胜」，rc=$(_rc "$out")）" \
  "$([[ "$(_rc "$out")" == "0" ]] && echo true || echo false)"
out=$(AGENT_GATES_DIR="$CAP" mkcase "cur@VERDICT: PASS;;REVIEW_LEVEL: L0" "cur@VERDICT: PASS;;REVIEW_LEVEL: L1")
assert "⭐ L0 在前、L1 在后 ⇒ 放行（杀「第一份胜」，rc=$(_rc "$out")）" \
  "$([[ "$(_rc "$out")" == "0" ]] && echo true || echo false)"
out=$(AGENT_GATES_DIR="$CAP" mkcase "cur@VERDICT: PASS" "cur@VERDICT: PASS;;REVIEW_LEVEL: L1")
assert "⭐ 无标记在前、L1 在后 ⇒ 放行" \
  "$([[ "$(_rc "$out")" == "0" ]] && echo true || echo false)"
assert "⛔ 不是靠跳过 Gate 2b 混过去的（机器仍是 L1）" \
  "$([[ "$out" != *"no REVIEW_LEVEL marker"* ]] && echo true || echo false)"
# 反向：两份都是 L0 ⇒ 仍须拦
out=$(AGENT_GATES_DIR="$CAP" mkcase "cur@VERDICT: PASS;;REVIEW_LEVEL: L0" "cur@VERDICT: PASS;;REVIEW_LEVEL: L0")
assert "⛔ 全是 L0 时 Gate 2b 照拦" \
  "$([[ "$(_rc "$out")" != "0" && "$out" == *same-model* ]] && echo true || echo false)"

echo
echo "--- T16 共享库里的当前 PASS 能取代本地过期 FAIL（round2 中等：缺回归）---"
# 产物在功能分支 worktree 生成、merge 在主仓发生 ⇒ 共享库是那条路径唯一的载体。
out=$(mkcase "stale@VERDICT: FAIL" "shared-cur@VERDICT: PASS")
assert "⭐ 共享库的 PASS 取代得了本地过期 FAIL（rc=$(_rc "$out")）" "$(_allowed "$out")"
out=$(mkcase "shared-stale@VERDICT: PASS" "cur@VERDICT: FAIL")
assert "⛔ 反向：共享库的过期 PASS 盖不掉本地当前 FAIL" "$(_blocked "$out")"

cd /
echo
read -r P F < "$RESULTS_FILE"
echo "PASS=$P FAIL=$F"
rm -f "$RESULTS_FILE"
[[ "$F" -eq 0 ]] || exit 1
