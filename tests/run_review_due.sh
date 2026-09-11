#!/usr/bin/env bash
# 审查的**时机**：不该审的时候，工具要拦住，而不是让 agent 白烧。
#
# 🔴 实况（2026-09-10，另一条会话自己算的账）：任务拆成小块并行开发，它**每修一条就派
# 一个 agent 跑一次全量审查**，自己每轮再复核一次全量 ——「11 个 agent + 至少 7 次全量跑」。
# 而那些审查的锚点在下一次改动后就作废了：门禁锚点（staged_diff_hash）还对得上，
# 但工作区 diff 已变，那份审查**根本没看见后来 637+ 行改动**。⇒ 伪造产物，必须在合并点重跑。
#
# ⭐ 关键：门禁配置本来就说了「现在不用审」——
#    review.mode=merge-only + strict_branches 只含 test/master/main
#    ⇒ 模块分支上迭代期不审，合并进集成分支时才审一次。
#    但那句话**只在 commit 时才打印**，写代码阶段没有任何东西拦它。
#
# ⇒ agent-gates-review 自己要会判「现在轮不到审查」，默认拒绝 + 说清什么时候该审。
#   ⛔ 逃生门保留（--early），但要被数出来、打出来 —— 设计目标是「无法静默绕过」。
set -uo pipefail

# ⛔ 隔离环境来源的档位覆盖，文件作用域。这些用例的**被测对象**就是档位判定，
# 而 `_gate_resolve_mode` 里 env 的优先级高于配置文件 ⇒ 外面事先 export 过
# AGENT_GATES_REVIEW_MODE 的话，8 条断言会假失败（实测差分跑出来的）。
unset AGENT_GATES_MODE AGENT_GATES_REVIEW_MODE AGENT_GATES_REVIEW_EARLY

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REVIEW="$SCRIPT_DIR/../bin/agent-gates-review"
GATE="$SCRIPT_DIR/../hooks/git/agent-quality-gate.sh"
RESULTS_FILE=$(mktemp); echo "0 0" > "$RESULTS_FILE"
assert() {
  local name="$1" cond="$2" p f
  read -r p f < "$RESULTS_FILE"
  if [[ "$cond" == "true" ]]; then echo "  ✓ $name"; echo "$((p+1)) $f" > "$RESULTS_FILE"
  else echo "  ✗ $name"; echo "$p $((f+1))" > "$RESULTS_FILE"; fi
}

GD=$(mktemp -d)
printf '{"level":"L3","review_models":{"primary":"x/y","panel_pool":[],"panel_active":2,"panel_mode":"off"}}' \
  > "$GD/hetero-check.json"
export AGENT_GATES_DIR="$GD"

# ⛔ FAIL-SAFE，文件作用域。审查通道是 pi，而真的 `pi` 就在 PATH 上 ——
# 不覆盖就会拿 fixture 里的 `x/y` 去发真实 API 调用并挂到 300s（本轮第一版就是这么挂的）。
FAKEBIN=$(mktemp -d)
printf '#!/usr/bin/env bash\necho call >> "%s/pi.calls"\necho "fake pi refused" >&2\nexit 1\n' \
  "$FAKEBIN" > "$FAKEBIN/pi"
: > "$FAKEBIN/pi.calls"
pi_calls() { wc -l < "$FAKEBIN/pi.calls" | tr -d ' '; }
chmod +x "$FAKEBIN/pi"
export AG_REVIEW_PI="$FAKEBIN/pi"
export AG_REVIEW_CODEX="$FAKEBIN/does-not-exist"
PMT=$(mktemp); echo "审一下" > "$PMT"

mkrepo() {   # mkrepo <mode-json>
  local d; d=$(mktemp -d)
  ( cd "$d"
    git init -q .; git config user.email t@t; git config user.name t
    git symbolic-ref HEAD refs/heads/main
    mkdir -p .agent/reviews
    printf '%s\n' "$1" > .agent/gates.json
    printf 'export const a = 1\n' > src.ts; printf 'test\n' > src.test.ts
    git add . && git commit -q -m init
  ) >/dev/null 2>&1
  echo "$d"
}

echo "=== 审查时机门控 ==="
echo
echo "--- ① merge-only + 业务分支 ⇒ 默认拒绝 ---"
R=$(mkrepo '{"mode":"merge-only","strict_branches":["test","master","main"]}')
cd "$R" && git checkout -q -b feat/module-a
printf 'export const b = 2\n' >> src.ts && git add src.ts
before=$(pi_calls)
out=$(bash "$REVIEW" "$PMT" --result /dev/null 2>&1); rc=$?
after=$(pi_calls)
assert "⭐ 拒绝（实际 ${rc}，⛔ 必须是 79 而不是随便一个非零）" \
  "$([[ $rc -eq 79 ]] && echo true || echo false)"
assert "⭐ 说清「什么时候该审」（点名 strict 分支）" \
  "$([[ "$out" == *merge-only* && ( "$out" == *test* || "$out" == *master* || "$out" == *main* ) ]] && echo true || echo false)"
assert "⭐ 给出逃生门的名字（⛔ 不是死路）" \
  "$([[ "$out" == *--early* ]] && echo true || echo false)"
# ⛔ 旧断言是「输出里没有 REVIEW_TOOL」—— fake pi 本来就失败、根本不会产出那个 marker，
# 所以门控失效、真去调了模型，它也照样绿（异构审 finding 5 抓到）。改成比调用次数。
assert "⛔ 没有真去跑审查（模型调用 ${before}→${after}）" \
  "$([[ "$before" == "$after" ]] && echo true || echo false)"

echo
echo "--- ② 同一条分支上，strict 分支则照跑（正对照）---"
git checkout -q main
printf 'export const c = 3\n' >> src.ts && git add src.ts
out=$(bash "$REVIEW" "$PMT" --result /dev/null 2>&1); rc=$?
assert "⭐ 不再因为时机被拦（rc≠79，实际 ${rc}）" "$([[ $rc -ne 79 ]] && echo true || echo false)"
assert "⛔ 不打印那条时机拒绝" "$([[ "$out" != *"--early"* ]] && echo true || echo false)"

echo
echo "--- ③ --early 能过，但要留痕 ---"
git checkout -q feat/module-a
out=$(bash "$REVIEW" "$PMT" --early --result /dev/null 2>&1); rc=$?
assert "⭐ --early 放行（rc≠79，实际 ${rc}）" "$([[ $rc -ne 79 ]] && echo true || echo false)"
assert "⭐ 明确记一笔「这是提前审、合并点仍需重跑」" \
  "$([[ "$out" == *early* || "$out" == *提前* ]] && echo true || echo false)"

echo
echo "--- ④ mode=strict 时任何分支都该审 ---"
R2=$(mkrepo '{"mode":"strict"}')
cd "$R2" && git checkout -q -b feat/x
printf 'export const d = 4\n' >> src.ts && git add src.ts
out=$(bash "$REVIEW" "$PMT" --result /dev/null 2>&1); rc=$?
assert "⭐ strict 档不拦（实际 ${rc}）" "$([[ $rc -ne 79 ]] && echo true || echo false)"

echo
echo "--- ⑤ mode=off 时审查没有意义，也该拦 ---"
R3=$(mkrepo '{"mode":"off"}')
cd "$R3" && git checkout -q -b feat/y
printf 'export const e = 5\n' >> src.ts && git add src.ts
before=$(pi_calls)
out=$(bash "$REVIEW" "$PMT" --result /dev/null 2>&1); rc=$?
after=$(pi_calls)
assert "⭐ off 档拦住（实际 ${rc}，⛔ 钉 79：75 也是非零但意思是 reviewer 跑了又失败）" \
  "$([[ $rc -eq 79 ]] && echo true || echo false)"
assert "⛔ 且一次模型都没调（${before}→${after}）" \
  "$([[ "$before" == "$after" ]] && echo true || echo false)"

echo
echo "--- ⑥ 门禁自己的档位判定不能坏（抽库回归）---"
cd "$R"; git checkout -q feat/module-a
gout=$(AGENT_MODE=1 bash "$GATE" 2>&1 || true)
assert "门禁仍认出 merge-only（钉 mode 行本身）" \
  "$([[ "$gout" == *"Agent Quality Gate mode: merge-only"* && "$gout" == *"review=merge-only"* ]] && echo true || echo false)"
cd "$R2"; git checkout -q feat/x
gout=$(AGENT_MODE=1 bash "$GATE" 2>&1 || true)
# ⛔ 旧断言匹配通用 "Agent Quality Gate"，而 trivial-skip 的横幅也含这串
# ⇒ 档位判定整个坏掉它也绿（异构审 finding 5）。strict 是默认值、**不打 mode 行**，
#   所以正判据是「没有 mode 行」；再配一条「它确实跑了」，免得早退也算通过。
assert "门禁仍认出 strict：没有 mode 行（strict 是默认值）" \
  "$([[ "$gout" != *"Agent Quality Gate mode:"* ]] && echo true || echo false)"
assert "⛔ 且它确实跑到了（不是早退成空输出）" \
  "$([[ -n "$gout" && "$gout" == *"Agent Quality Gate"* ]] && echo true || echo false)"


# ============================================================
# `--due`：只判时机、不跑审查（给 rift-dispatch 的派发前校验用）
# ============================================================
# 🔴 上面①-⑥ 那道门控只拦「走 agent-gates-review 的审查」。而烧掉 11 个 agent 的那条
# 会话是**自己用 Paseo 直接派**的 —— 根本没经过这个命令。⇒ 派发侧要能在花钱之前问一句
# 「现在轮到审查了吗」，所以需要一个零成本、可脚本解析的判定入口。
#
# 契约（rift-dispatch 会照这个写代码，⛔ 改了就是破坏调用方）：
#   exit 0  = 该审        stdout 含 due=yes
#   exit 79 = 轮不到      stdout 含 due=no
#   stdout 为 key=value 行：due / reason / branch / review_mode / when
#   ⛔ 不需要 prompt 文件、不调用任何模型、不写任何产物

echo
echo "--- ⑦ --due 基本契约：merge-only + 业务分支 ⇒ due=no / exit 79 ---"
cd "$R"; git checkout -q feat/module-a
before=$(pi_calls)
out=$(bash "$REVIEW" --due 2>/dev/null); rc=$?
after=$(pi_calls)
assert "⭐ exit 79（实际 ${rc}）" "$([[ $rc -eq 79 ]] && echo true || echo false)"
assert "⭐ stdout 含 due=no" "$([[ "$out" == *"due=no"* ]] && echo true || echo false)"
assert "⛔ 不需要 prompt 文件（不是 usage 错 exit 1）" "$([[ $rc -ne 1 ]] && echo true || echo false)"
assert "⛔ 零成本：一次模型调用都没有（${before}→${after}）" \
  "$([[ "$before" == "$after" ]] && echo true || echo false)"
assert "⭐ 可解析：reason= / branch= / review_mode= / when= 齐全" \
  "$([[ "$out" == *"reason="* && "$out" == *"branch="* && "$out" == *"review_mode="* && "$out" == *"when="* ]] && echo true || echo false)"
assert "⭐ branch= 是真分支名" "$([[ "$out" == *"branch=feat/module-a"* ]] && echo true || echo false)"
assert "⭐ when= 点名集成分支" \
  "$([[ "$out" == *"when="*main* || "$out" == *"when="*master* ]] && echo true || echo false)"
assert "⛔ stdout 只有 key=value，没有散文" \
  "$(python3 -c "
import sys
ok = all(('=' in l and ' ' not in l.split('=',1)[0]) for l in sys.stdin.read().splitlines() if l.strip())
print('true' if ok else 'false')" <<< "$out")"
assert "⛔ 不写产物（.agent/reviews 仍为空）" \
  "$([[ -z "$(ls -A .agent/reviews 2>/dev/null)" ]] && echo true || echo false)"

echo
echo "--- ⑧ --due 正对照：集成分支 ⇒ due=yes / exit 0 ---"
git checkout -q main
out=$(bash "$REVIEW" --due 2>/dev/null); rc=$?
assert "⭐ exit 0（实际 ${rc}）" "$([[ $rc -eq 0 ]] && echo true || echo false)"
assert "⭐ due=yes" "$([[ "$out" == *"due=yes"* ]] && echo true || echo false)"

echo
echo "--- ⑨ -C <dir>：从别处判定指定仓库（rift-dispatch 不在目标仓里跑）---"
cd "$R"; git checkout -q feat/module-a
cd /tmp
out=$(bash "$REVIEW" --due -C "$R" 2>/dev/null); rc=$?
assert "⭐ 认 -C 并判成 due=no（实际 ${rc}）" \
  "$([[ $rc -eq 79 && "$out" == *"due=no"* ]] && echo true || echo false)"
out=$(bash "$REVIEW" --due -C "$R2" 2>/dev/null); rc=$?
assert "⭐ -C 指向 strict 仓则 due=yes（实际 ${rc}）" \
  "$([[ $rc -eq 0 && "$out" == *"due=yes"* ]] && echo true || echo false)"
out=$(bash "$REVIEW" --due -C /nonexistent-dir-xyz 2>&1); rc=$?
assert "⛔ -C 指向不存在的目录要报错，⛔ 不能静默当成 due" \
  "$([[ $rc -ne 0 && $rc -ne 79 ]] && echo true || echo false)"

echo
echo "--- ⑩ 各档位 ---"
out=$(bash "$REVIEW" --due -C "$R3" 2>/dev/null); rc=$?
assert "⭐ mode=off ⇒ due=no（实际 ${rc}）" \
  "$([[ $rc -eq 79 && "$out" == *"due=no"* ]] && echo true || echo false)"
assert "⭐ off 档的 reason 说得出是 off" "$([[ "$out" == *off* ]] && echo true || echo false)"

echo
echo "--- ⑪ 判不出来时 fail-open：⛔ 时机门控不该变成新的堵路 ---"
# 只复制这一个可执行文件，没有 lib/ 也没有 with-timeout.mjs
BARE=$(mktemp -d); mkdir -p "$BARE/bin"
cp "$REVIEW" "$BARE/bin/agent-gates-review"
out=$(bash "$BARE/bin/agent-gates-review" --due -C "$R" 2>/dev/null); rc=$?
assert "⭐ 缺 lib/ 时放行（due=yes, exit 0，实际 ${rc}）" \
  "$([[ $rc -eq 0 && "$out" == *"due=yes"* ]] && echo true || echo false)"
reason_line=$(printf '%s\n' "$out" | sed -n 's/^reason=//p')
assert "⭐ reason= 自己就说得出判不出来（⛔ 不靠别的字段兜）" \
  "$([[ "$reason_line" == *undetermined* || "$reason_line" == *fail*open* ]] && echo true || echo false)"
assert "⭐ review_mode= 也不谎报成某个真实档位" \
  "$([[ "$out" == *"review_mode=undetermined"* ]] && echo true || echo false)"

echo
echo "--- ⑫ 非 git 目录：仓库外不拦 ---"
NG=$(mktemp -d)
out=$(bash "$REVIEW" --due -C "$NG" 2>/dev/null); rc=$?
assert "⭐ 非仓库放行（实际 ${rc}）" "$([[ $rc -eq 0 ]] && echo true || echo false)"

echo
echo "--- ⑬ --due 不破坏正常审查路径（回归）---"
cd "$R"; git checkout -q main
printf 'export const f = 6\n' >> src.ts && git add src.ts
before=$(pi_calls)
out=$(bash "$REVIEW" "$PMT" --result /dev/null 2>&1); rc=$?
after=$(pi_calls)
assert "⭐ 不带 --due 时照常走审查（真去调了模型 ${before}→${after}）" \
  "$([[ "$before" != "$after" ]] && echo true || echo false)"

echo
echo "--- ⑭ 子目录必须解析出同一份项目配置（668f174f 实测报来的）---"
# 🔴 `git rev-parse --git-common-dir` 在**子目录**里返回的是**相对**路径 `../.git`
# ⇒ 旧实现的 case 落到 `*)` 分支，返回裸的相对 `.agent/gates.json`，在子目录里不存在
# ⇒ 项目配置**整份丢掉**，静默回落成 strict。方向是「门控不触发」（偏松），
#    但它让同一个仓在不同 cwd 下给出相反答案 —— 派发侧传 worktree 子目录就会拿到错的。
SUB=$(mkrepo '{"mode":"merge-only","strict_branches":["main"]}')
( cd "$SUB" && git checkout -q -b feat/sub && mkdir -p pkg/a/b ) >/dev/null 2>&1
root_out=$(bash "$REVIEW" --due -C "$SUB" 2>/dev/null); root_rc=$?
sub_out=$(bash "$REVIEW" --due -C "$SUB/pkg" 2>/dev/null); sub_rc=$?
deep_out=$(bash "$REVIEW" --due -C "$SUB/pkg/a/b" 2>/dev/null); deep_rc=$?
assert "⭐ 仓根判 due=no（基准，实际 ${root_rc}）" \
  "$([[ $root_rc -eq 79 && "$root_out" == *"review_mode=merge-only"* ]] && echo true || echo false)"
assert "⭐ 一级子目录给出**同样**的答案（实际 ${sub_rc}）" \
  "$([[ $sub_rc -eq 79 && "$sub_out" == *"review_mode=merge-only"* ]] && echo true || echo false)"
assert "⭐ 深层子目录也一样（实际 ${deep_rc}）" \
  "$([[ $deep_rc -eq 79 && "$deep_out" == *"review_mode=merge-only"* ]] && echo true || echo false)"

echo
echo "--- ⑮ --due ⛔ 不能和正常审查参数混用（异构审 finding 1）---"
# 🔴 混用时 --due 先退出：不跑 reviewer、不写 --result，却返回 exit 0。
# 把 0 当「审查成功」的调用方会拿着一个**不存在的产物**继续往下走。
cd "$R"; git checkout -q main
RES=$(mktemp -u)
out=$(bash "$REVIEW" "$PMT" --result "$RES" --due 2>&1); rc=$?
assert "⭐ 混用要报错（⛔ 不能静默降级成查询，实际 ${rc}）" \
  "$([[ $rc -eq 1 ]] && echo true || echo false)"
assert "⭐ 报错说得出是参数冲突" \
  "$([[ "$out" == *--due* && ( "$out" == *combin* || "$out" == *mutually* || "$out" == *冲突* || "$out" == *不能* ) ]] && echo true || echo false)"
assert "⛔ 没有伪造出 --result 文件" "$([[ ! -f "$RES" ]] && echo true || echo false)"
out=$(bash "$REVIEW" --due --early 2>&1); rc=$?
assert "⭐ --due + --early 也报错（实际 ${rc}）" "$([[ $rc -eq 1 ]] && echo true || echo false)"
out=$(bash "$REVIEW" --due -C "$R" -C "$R2" 2>&1); rc=$?
assert "⭐ 重复 -C 报错，⛔ 不静默取最后一个（实际 ${rc}）" "$([[ $rc -eq 1 ]] && echo true || echo false)"

echo
echo "--- ⑯ strict 分支的 off 不能和门禁打对台（异构审 finding 2）---"
# 🔴 门禁在 strict 分支上**强制 strict**（agent-quality-gate.sh 的 strict_branches override）。
# 若 --due 在这种情况下报 due=no，就形成死锁：门禁要审查产物，CLI 拒绝生成产物。
R4=$(mkrepo '{"mode":"strict","review":{"mode":"off"},"strict_branches":["main"]}')
cd "$R4"
out=$(bash "$REVIEW" --due 2>/dev/null); rc=$?
assert "⭐ strict 分支上 off 被覆盖成该审（实际 ${rc}）" \
  "$([[ $rc -eq 0 && "$out" == *"due=yes"* ]] && echo true || echo false)"
assert "⭐ reason 说得出是 strict 分支覆盖的" \
  "$([[ "$out" == *strict* ]] && echo true || echo false)"
gout=$(AGENT_MODE=1 bash "$GATE" 2>&1 || true)
assert "⛔ 与门禁口径一致（门禁确实强制 strict）" \
  "$([[ "$gout" == *"forced to strict"* ]] && echo true || echo false)"

echo
echo "--- ⑰ 非 git 目录 + 用户级 merge-only ⇒ 仍要 fail-open（异构审 finding 3）---"
# 🔴 旧实现：branch="" ⇒ _gate_branch_is_strict 返回假 ⇒ merge-only 判成 due=no ⇒ exit 79。
# 仓库外本来就没有「分支」这个概念，判不出来就该放行。
GD2=$(mktemp -d); printf '{"mode":"merge-only"}' > "$GD2/gates.json"
NG2=$(mktemp -d)
out=$(AGENT_GATES_DIR="$GD2" bash "$REVIEW" --due -C "$NG2" 2>/dev/null); rc=$?
assert "⭐ 非仓库 + merge-only 仍放行（实际 ${rc}）" \
  "$([[ $rc -eq 0 && "$out" == *"due=yes"* ]] && echo true || echo false)"
printf '{"mode":"off"}' > "$GD2/gates.json"
out=$(AGENT_GATES_DIR="$GD2" bash "$REVIEW" --due -C "$NG2" 2>/dev/null); rc=$?
assert "⭐ 非仓库 + off 也放行（实际 ${rc}）" \
  "$([[ $rc -eq 0 && "$out" == *"due=yes"* ]] && echo true || echo false)"
assert "⭐ 并且标成 undetermined，⛔ 不谎报档位" \
  "$([[ "$out" == *"review_mode=undetermined"* ]] && echo true || echo false)"

echo
echo "--- ⑱ 配置坏了要 fail-open，⛔ 不能变成阻断（异构审 finding 4）---"
# 🔴 strict_branches 写成字符串（不是数组）⇒ 旧实现静默当缺失、回落 test/master/main
# ⇒ 在 release/1.0 上判成 due=no。「判不出来就放行」的原则在这里没兑现。
R5=$(mkrepo '{"mode":"merge-only","strict_branches":"release/*"}')
cd "$R5" && git checkout -q -b release/1.0
out=$(bash "$REVIEW" --due 2>/dev/null); rc=$?
assert "⭐ strict_branches 类型错 ⇒ 放行（实际 ${rc}）" \
  "$([[ $rc -eq 0 && "$out" == *"due=yes"* ]] && echo true || echo false)"
assert "⭐ 标成 undetermined" "$([[ "$out" == *"review_mode=undetermined"* ]] && echo true || echo false)"
R6=$(mkrepo '{"mode":"merge-only",,,BROKEN')
cd "$R6" && git checkout -q -b feat/z
out=$(bash "$REVIEW" --due 2>/dev/null); rc=$?
assert "⭐ 配置 JSON 坏掉 ⇒ 放行（实际 ${rc}）" \
  "$([[ $rc -eq 0 && "$out" == *"due=yes"* ]] && echo true || echo false)"

echo
echo "--- ⑲ 判不出来的**原因**不能瞎说（异构审 round2 低优先级残留）---"
# 🔴 `_gate_cfg_sane` 靠 python3 校验配置；python3 根本不在时它也返回「配置坏了」，
# 于是 reason 说的是「unparseable / strict_branches 类型错」—— 配置好得很。
# 方向没错（仍放行），但**诊断在撒谎**：拿着这句话去查配置的人会白查。
# ⚠️ 本轮变异测试已经吃过一次亏：reason 撒谎而断言靠别的字段兜住，全绿。
MINBIN=$(mktemp -d)
for c in git bash sed grep cut tr cat dirname wc awk; do
  p=$(command -v "$c" 2>/dev/null) && ln -sf "$p" "$MINBIN/$c"
done
R7=$(mkrepo '{"mode":"merge-only","strict_branches":["main"]}')
cd "$R7" && git checkout -q -b feat/nopy
out=$(PATH="$MINBIN" bash "$REVIEW" --due 2>/dev/null); rc=$?
assert "⛔ 先确认这个环境里真的没有 python3" \
  "$(PATH="$MINBIN" command -v python3 >/dev/null 2>&1 && echo false || echo true)"
assert "⭐ 仍然放行（实际 ${rc}）" "$([[ $rc -eq 0 ]] && echo true || echo false)"
reason_line=$(printf '%s\n' "$out" | sed -n 's/^reason=//p')
assert "⭐ reason 点名 python3，⛔ 不谎称配置坏了" \
  "$([[ "$reason_line" == *python3* ]] && echo true || echo false)"
assert "⛔ 不再说 unparseable / strict_branches" \
  "$([[ "$reason_line" != *unparseable* && "$reason_line" != *strict_branches* ]] && echo true || echo false)"

cd /
echo
read -r P F < "$RESULTS_FILE"
echo "PASS=$P FAIL=$F"
rm -f "$RESULTS_FILE"
[[ "$F" -eq 0 ]] || exit 1
