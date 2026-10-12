#!/usr/bin/env bash
# 审查/验收产物必须能跨 worktree 被门禁看见。
#
# 🔴 卡人的实况（2026-09-10，我自己撞的）：`.gitignore` 排除 `.agent/reviews/` 与
# `.agent/verify/`（wb 的项目更狠，整个 `.agent/` 都 ignore），而 `merge-only` 档把
# 审查/验收推迟到「合并进 strict 分支」那一刻。产物在**功能分支的 worktree** 里生成，
# merge 发生在**主仓 worktree** —— 产物既不进 git 又不跨 worktree
# ⇒ **它永远到不了那个检查点**。当天我是手工 `cp` 过去才让门禁通过的。
#
# ⇒ 产物同时写进一个按仓库（不是按 worktree）分键的共享库：
#    `$AGENT_GATES_DIR/artifacts/<repo-key>/{reviews,verify}/`
#    repo-key 取自 `git rev-parse --git-common-dir` —— 同一仓库的所有 worktree 同键。
#    ⛔ 不动任何项目的 .gitignore（那要各项目分别改，且会把审查正文推进 git 历史）。
set -uo pipefail

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

MAIN=$(mktemp -d)
( cd "$MAIN"
  git init -q .; git config user.email t@t; git config user.name t
  mkdir -p .agent/reviews
  printf '{"mode":"strict"}\n' > .agent/gates.json
  # ⭐ 复刻真实条件：产物目录被 gitignore
  printf '.agent/reviews/\n.agent/verify/\n' > .gitignore
  printf 'export const a = 1\n' > src.ts; printf 'test\n' > src.test.ts
  printf 'export const c = 1\n' > other.ts; printf 'test\n' > other.test.ts
  git add . && git commit -q -m init
) >/dev/null 2>&1

WT="$MAIN-wt"
git -C "$MAIN" worktree add -q "$WT" -b feat/x >/dev/null 2>&1

bigchange() {   # 造出足以触发 CHECK 5 的 staged diff（>1 逻辑文件 且 >50 行）
  local i
  for i in $(seq 1 30); do echo "export const s$i = $i"; done >> src.ts
  for i in $(seq 1 30); do echo "export const o$i = $i"; done >> other.ts
  git add src.ts other.ts
}
BODY=$(mktemp); printf '看过了。\n\nVERDICT: PASS\n' > "$BODY"

echo "=== 产物跨 worktree 可见 ==="
echo
echo "--- ① 在功能分支 worktree 里登记审查 ---"
cd "$WT"
bigchange
out=$(bash "$REVIEW" --import-result "$BODY" --imported-model "pi/x/y" \
        --result .agent/reviews/r.md 2>&1); rc=$?
assert "登记成功（实际 ${rc}）" "$([[ $rc -eq 0 ]] && echo true || echo false)"
assert "worktree 本地有产物" "$([[ -s .agent/reviews/r.md ]] && echo true || echo false)"
assert "⭐ 也写进了共享库" \
  "$([[ -n "$(find "$GD/artifacts" -name '*.md' -path '*reviews*' 2>/dev/null)" ]] && echo true || echo false)"
assert "共享库按仓库分键（同仓库只有一个键）" \
  "$([[ "$(find "$GD/artifacts" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')" == "1" ]] && echo true || echo false)"

echo
echo "--- ② 主仓 worktree 里门禁能看见它（就是 merge 那一刻的场景）---"
cd "$MAIN"
bigchange
assert "前提成立：主仓本地没有这份产物" \
  "$([[ ! -f .agent/reviews/r.md ]] && echo true || echo false)"
gout=$(AGENT_MODE=1 bash "$GATE" 2>&1 || true)
assert "⭐⭐ 门禁不再报『没有锚定的审查证据』" \
  "$([[ "$gout" != *"No content-anchored review evidence"* ]] && echo true || echo false)"
assert "⭐ 也不报『HEAD 不匹配』（说明它真读到了那份产物）" \
  "$([[ "$gout" != *"Review HEAD does not match"* ]] && echo true || echo false)"

echo
echo "--- ③ 别的仓库看不到（⛔ 不能跨仓串） ---"
OTHER=$(mktemp -d)
( cd "$OTHER"
  git init -q .; git config user.email t@t; git config user.name t
  mkdir -p .agent/reviews; printf '{"mode":"strict"}\n' > .agent/gates.json
  printf 'export const z = 1\n' > z.ts; printf 'test\n' > z.test.ts
  git add . && git commit -q -m init
  printf 'export const z2 = 1\n' > z2.ts; printf 'test\n' > z2.test.ts
  git add . && git commit -q -m more
  for i in $(seq 1 30); do echo "export const q$i = $i"; done >> z.ts
  for i in $(seq 1 30); do echo "export const r$i = $i"; done >> z2.ts
  git add z.ts z2.ts
) >/dev/null 2>&1
cd "$OTHER"
gout=$(AGENT_MODE=1 bash "$GATE" 2>&1 || true)
assert "⭐ 另一个仓库仍然要求自己的审查证据" \
  "$([[ "$gout" == *"No content-anchored review evidence"* || "$gout" == *"Review HEAD does not match"* ]] && echo true || echo false)"

echo
echo "--- ④ 两边的 repo-key 算法必须一致（这条是真出过事的）---"
# macOS 上 worktree 里 git-common-dir 返回 /private/var/...，主仓返回相对 `.git`；
# 相对转绝对得到 /var/...，而 /var 是 /private/var 的软链 ⇒ 同一仓库两个 worktree
# 算出**不同的 key**，共享库当场失效。两处实现分叉的失败长得像「审查根本没做」。
# ⛔ 别把 CLI 当库 source 来问它算出什么 —— 它会跑主流程。用可观察的判据：
# 两个 worktree 各登记一次，共享库里**仍然只有一个键目录**。
cd "$MAIN"
bash "$REVIEW" --import-result "$BODY" --imported-model "pi/x/y" \
  --result "$(mktemp)" >/dev/null 2>&1 || true
KEYS=$(find "$GD/artifacts" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')
assert "⭐⭐ 主仓与 worktree 各登记一次后，键目录仍是 1 个（算法没分叉）" \
  "$([[ "$KEYS" == "1" ]] && echo true || echo false)"
assert "该键下有两份产物" \
  "$([[ "$(find "$GD/artifacts" -name '*.md' -path '*reviews*' 2>/dev/null | wc -l | tr -d ' ')" -ge 2 ]] && echo true || echo false)"

echo
read -r P F < "$RESULTS_FILE"
echo "PASS=$P FAIL=$F"
rm -f "$RESULTS_FILE"
[[ "$F" -eq 0 ]] || exit 1
