#!/usr/bin/env bash
# Tests for agent-gates-hooks-sync — making the merge hook reach deployed projects.
#
# WHY (cross-review, 2026-09-01): the pre-merge-commit fix landed only in agent-gates' own
# repo. Every project deployed before it still has pre-commit alone, so a clean merge into
# their test/master branch runs no gate at all. "Fixed in the tool's own repo" is not fixed:
# the hole stays open everywhere the tool is actually used.
#
# It also answers a standing question — "is the gate really in effect here?" — because a
# hooksPath pointing at a missing hook file is silently skipped by git while `git config`
# looks perfectly correct. Two wb repos were in exactly that state.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SYNC="$SCRIPT_DIR/../bin/agent-gates-hooks-sync"
SHIM="$SCRIPT_DIR/../hooks/git/gate-shim.sh"
RESULTS_FILE=$(mktemp); echo "0 0" > "$RESULTS_FILE"

assert() {
  local name="$1" cond="$2" p f
  read -r p f < "$RESULTS_FILE"
  if [[ "$cond" == "true" ]]; then echo "  ✓ $name"; echo "$((p+1)) $f" > "$RESULTS_FILE"
  else echo "  ✗ $name"; echo "$p $((f+1))" > "$RESULTS_FILE"; fi
}

setup() {
  ROOT=$(mktemp -d); export AGENT_GATES_SHIM_SRC="$SHIM"
}
teardown() { cd /; rm -rf "${ROOT:-}"; unset AGENT_GATES_SHIM_SRC; }
# mk_repo <name> <layout>
#   githooks      : .githooks/pre-commit = shim, hooksPath=.githooks
#   external      : hooksPath -> <root>/ext/<name>, pre-commit there
#   missing       : hooksPath=.githooks but no hook file at all
#   foreign       : .githooks/pre-commit exists but is NOT an agent-gates shim
#   nogate        : plain repo, no hooksPath
mk_repo() {
  # 分两句：bash 会在执行 local 之前把整行的词全部展开，所以 `local n="$1" d="$ROOT/$n"`
  # 里的 $n 是在赋值之前被引用的，set -u 下直接 unbound。
  local n="$1" kind="$2"
  local d="$ROOT/$n"
  mkdir -p "$d" && git -C "$d" init -q && git -C "$d" config user.email t@t && git -C "$d" config user.name t
  case "$kind" in
    githooks) mkdir -p "$d/.githooks"; cp "$SHIM" "$d/.githooks/pre-commit"; chmod +x "$d/.githooks/pre-commit"
              git -C "$d" config core.hooksPath .githooks ;;
    external) mkdir -p "$ROOT/ext/$n"; cp "$SHIM" "$ROOT/ext/$n/pre-commit"; chmod +x "$ROOT/ext/$n/pre-commit"
              git -C "$d" config core.hooksPath "$ROOT/ext/$n" ;;
    missing)  git -C "$d" config core.hooksPath .githooks ;;
    foreign)  mkdir -p "$d/.githooks"; printf '#!/bin/sh\nexit 0\n' > "$d/.githooks/pre-commit"
              chmod +x "$d/.githooks/pre-commit"; git -C "$d" config core.hooksPath .githooks ;;
    nogate)   : ;;
  esac
}

[[ -x "$SYNC" ]] || { echo "  ✗ bin/agent-gates-hooks-sync 不存在（未实现）"; echo "=== PASS=0 FAIL=1 ==="; exit 1; }

echo "=== agent-gates-hooks-sync tests ==="
echo

echo "S1: ⭐ 默认 dry-run —— 不许动任何文件"
( setup; mk_repo a githooks
  out=$(bash "$SYNC" "$ROOT" 2>&1)
  assert "报出要补的项" "$([[ "$out" == *"pre-merge-commit"* ]] && echo true || echo false)"
  assert "⛔ 未真的创建文件" "$([[ ! -f "$ROOT/a/.githooks/pre-merge-commit" ]] && echo true || echo false)"
  assert "提示需要 --apply" "$([[ "$out" == *"--apply"* ]] && echo true || echo false)"
  teardown )

echo "S2: --apply 后 .githooks 布局补上 pre-merge-commit"
( setup; mk_repo a githooks
  bash "$SYNC" --apply "$ROOT" >/dev/null 2>&1
  assert "文件已创建" "$([[ -f "$ROOT/a/.githooks/pre-merge-commit" ]] && echo true || echo false)"
  assert "可执行" "$([[ -x "$ROOT/a/.githooks/pre-merge-commit" ]] && echo true || echo false)"
  assert "内容是 shim（委托全局权威）" "$(grep -q 'agent-quality-gate.sh' "$ROOT/a/.githooks/pre-merge-commit" && echo true || echo false)"
  teardown )

echo "S3: ⭐ hooksPath 指向仓库外（husky 绕法）也要补"
( setup; mk_repo b external
  bash "$SYNC" --apply "$ROOT" >/dev/null 2>&1
  assert "外置目录里补上了" "$([[ -f "$ROOT/ext/b/pre-merge-commit" ]] && echo true || echo false)"
  assert "⛔ 没在仓库里乱建 .githooks" "$([[ ! -d "$ROOT/b/.githooks" ]] && echo true || echo false)"
  teardown )

echo "S4: ⭐ hooksPath 设了但钩子文件不存在 → 报出来（git 会静默跳过，配置看着却是对的）"
( setup; mk_repo c missing
  out=$(bash "$SYNC" "$ROOT" 2>&1)
  assert "点明门禁其实没在跑" "$([[ "$out" == *"未生效"* || "$out" == *"not in effect"* ]] && echo true || echo false)"
  teardown )

echo "S5: ⛔ 不是 agent-gates 的钩子 → 一律不碰"
( setup; mk_repo d foreign
  before=$(shasum -a 256 < "$ROOT/d/.githooks/pre-commit")
  out=$(bash "$SYNC" --apply "$ROOT" 2>&1)
  after=$(shasum -a 256 < "$ROOT/d/.githooks/pre-commit")
  assert "原钩子未被改写" "$([[ "$before" == "$after" ]] && echo true || echo false)"
  assert "⛔ 未擅自补 pre-merge-commit" "$([[ ! -f "$ROOT/d/.githooks/pre-merge-commit" ]] && echo true || echo false)"
  assert "输出说明跳过原因" "$([[ "$out" == *"$ROOT/d"* || "$out" == *"skip"* || "$out" == *"跳过"* ]] && echo true || echo false)"
  teardown )

echo "S6: 没装门禁的仓库 → 不动、不报"
( setup; mk_repo e nogate
  bash "$SYNC" --apply "$ROOT" >/dev/null 2>&1
  assert "未创建任何钩子" "$([[ ! -d "$ROOT/e/.githooks" ]] && echo true || echo false)"
  teardown )

echo "S7: 幂等 —— 已有 pre-merge-commit 时重复运行不报为待补"
( setup; mk_repo a githooks
  bash "$SYNC" --apply "$ROOT" >/dev/null 2>&1
  out=$(bash "$SYNC" "$ROOT" 2>&1)
  # 只看逐仓那行。汇总行本身含「待补 0」，宽匹配会把它算成命中。
  assert "第二次不再列为待补" "$([[ "$out" != *"[dry-run] 待补"* ]] && echo true || echo false)"
  assert "汇总显示已齐" "$([[ "$out" == *"已齐 1"* ]] && echo true || echo false)"
  teardown )

echo "S8: 多仓库混合布局，一次跑完并给汇总"
( setup; mk_repo a githooks; mk_repo b external; mk_repo c missing; mk_repo d foreign; mk_repo e nogate
  out=$(bash "$SYNC" --apply "$ROOT" 2>&1)
  assert "a 补上" "$([[ -f "$ROOT/a/.githooks/pre-merge-commit" ]] && echo true || echo false)"
  assert "b 补上" "$([[ -f "$ROOT/ext/b/pre-merge-commit" ]] && echo true || echo false)"
  assert "d 未被碰" "$([[ ! -f "$ROOT/d/.githooks/pre-merge-commit" ]] && echo true || echo false)"
  assert "有汇总行" "$([[ "$out" == *"agent-gates-hooks-sync: 扫描"* ]] && echo true || echo false)"
  teardown )

echo "S9: ⭐ 已存在的 pre-merge-commit 必须验内容，不能只看存在"
# 「文件存在」当成「已齐」是同一个替换：放一个 exit 0 的假钩子，或留一个不可执行文件，
# sync 就报「已齐」而 merge 依然不受检。这是最便宜的绕过口。
( setup; mk_repo a githooks
  printf '#!/bin/sh\nexit 0\n' > "$ROOT/a/.githooks/pre-merge-commit"; chmod +x "$ROOT/a/.githooks/pre-merge-commit"
  out=$(bash "$SYNC" "$ROOT" 2>&1)
  assert "假钩子被点出来 (输出含警告)" "$([[ "$out" == *"pre-merge-commit"* && ( "$out" == *不是* || "$out" == *替换* || "$out" == *待补* ) ]] && echo true || echo false)"
  teardown )

echo "S10: ⭐ 不可执行的 pre-merge-commit 也不算已齐（git 会跳过它）"
( setup; mk_repo a githooks
  cp "$SHIM" "$ROOT/a/.githooks/pre-merge-commit"; chmod 644 "$ROOT/a/.githooks/pre-merge-commit"
  out=$(bash "$SYNC" --apply "$ROOT" 2>&1)
  assert "修成可执行" "$([[ -x "$ROOT/a/.githooks/pre-merge-commit" ]] && echo true || echo false)"
  teardown )

echo "S11: ⭐ 写入失败必须计入并让退出码非 0（不能假成功）"
( setup; mk_repo a githooks
  chmod 500 "$ROOT/a/.githooks"    # 只读目录：cp 必失败
  out=$(bash "$SYNC" --apply "$ROOT" 2>&1); rc=$?
  chmod 700 "$ROOT/a/.githooks"
  assert "退出码非 0 (rc=$rc)" "$([[ $rc -ne 0 ]] && echo true || echo false)"
  assert "汇总里体现失败" "$([[ "$out" == *FAILED* || "$out" == *失败* ]] && echo true || echo false)"
  teardown )

echo "S12: husky 项目（门禁不在 hooksPath 的 pre-commit 里）→ 报出来而非静默跳过"
( setup
  d="$ROOT/h"; mkdir -p "$d/.husky" && git -C "$d" init -q
  printf 'npx lint-staged\n' > "$d/.husky/pre-commit"
  git -C "$d" config core.hooksPath .husky
  out=$(bash "$SYNC" "$ROOT" 2>&1)
  assert "点出该仓库需要人工处理" "$([[ "$out" == *"$d"* ]] && echo true || echo false)"
  teardown )

echo "S13: ⭐ lefthook 项目（不设 core.hooksPath）→ 不能静默漏掉"
# 之前 S12 标题写着 husky/lefthook，实际只造了 husky fixture —— 所以「lefthook 整类被漏掉」
# 这个洞没有任何用例能抓到。init-project-gates 明确支持在 lefthook.yml 里挂门禁。
( setup
  d="$ROOT/lh"; mkdir -p "$d/.githooks" && git -C "$d" init -q
  cp "$SHIM" "$d/.githooks/agent-quality-gate.sh"; chmod +x "$d/.githooks/agent-quality-gate.sh"
  printf 'pre-commit:\n  commands:\n    gate:\n      run: .githooks/agent-quality-gate.sh\n' > "$d/lefthook.yml"
  out=$(bash "$SYNC" "$ROOT" 2>&1)
  assert "点出 lefthook 仓库需要人工处理" "$([[ "$out" == *"$d"* ]] && echo true || echo false)"
  # 不用 `grep -c … | grep -q '^0$'`：grep -c 无匹配时输出 0 但退出码是 1，
  # pipefail 会让整条管道取那个非零，断言被判假 —— 错在断言写法，不在代码。
  assert "⛔ 未擅自改 lefthook.yml（团队文件）" "$(grep -q 'pre-merge-commit' "$d/lefthook.yml" && echo false || echo true)"
  teardown )

echo "S14: ⭐ base pre-commit 失去执行位 → 普通 commit 根本不受检，必须报"
# 只补 pre-merge-commit 而不看 base hook 的执行位，等于把同一个「存在 ≠ 生效」
# 留在了更要紧的那个钩子上。
( setup; mk_repo a githooks
  chmod 644 "$ROOT/a/.githooks/pre-commit"
  out=$(bash "$SYNC" "$ROOT" 2>&1)
  assert "点出 pre-commit 不可执行" "$([[ "$out" == *"pre-commit"* && ( "$out" == *不可执行* || "$out" == *未生效* ) ]] && echo true || echo false)"
  bash "$SYNC" --apply "$ROOT" >/dev/null 2>&1
  assert "--apply 后修回可执行" "$([[ -x "$ROOT/a/.githooks/pre-commit" ]] && echo true || echo false)"
  teardown )

echo
read -r P F < "$RESULTS_FILE"
echo "=== PASS=$P FAIL=$F ==="
rm -f "$RESULTS_FILE"
# 零断言不算通过：一个 fixture 早退就会让整套静默变成 PASS=0 FAIL=0，
# 而按「FAIL=0 即绿」的判据它会被当成通过 —— 这次就是这样发生的。
[[ "$F" -eq 0 && "$P" -gt 0 ]]
