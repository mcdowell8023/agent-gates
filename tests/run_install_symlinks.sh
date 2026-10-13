#!/usr/bin/env bash
# install.sh 的 create_symlinks：目标已存在（不是软链）时不能让整个安装退出（v2.11.3）。
#
# 🔴 背景（2026-10-13，往 Hub 装 v2.11.2 时撞到）：Hub 上 ~/.claude/skills、~/.config/opencode/skills、
# ~/.agents/skills 里的 skill 都是**真实目录**（别的方式装的）。循环体最后一句是
#   [[ -L "$dst" || ! -e "$dst" ]] && ln -sfn ... && info ...
# 目标是真实目录时 [[ ]] 为假 ⇒ 这句返回 1；它恰好是最后一次迭代 ⇒ for 返回 1 ⇒ 函数返回 1 ⇒
# main 里 `create_symlinks` 在 set -e 下直接退出，rc=1、没有任何报错，后面的「安装全局门禁文件」
# 一步都没执行 —— 装了一半：skill 是新的，全局门禁还是旧版本。
# 契约：
#   · 真实目录 / 普通文件挡路 ⇒ 不覆盖，**说出来**（逐条路径），函数返回 0，安装继续
#   · 软链照旧刷新；不存在照旧新建
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_SCRIPT="$SCRIPT_DIR/../install.sh"
RESULTS_FILE=$(mktemp); echo "0 0" > "$RESULTS_FILE"
assert() {
  local name="$1" cond="$2" p f
  read -r p f < "$RESULTS_FILE"
  if [[ "$cond" == "true" ]]; then echo "  ✓ $name"; echo "$((p+1)) $f" > "$RESULTS_FILE"
  else echo "  ✗ $name"; echo "$p $((f+1))" > "$RESULTS_FILE"; fi
}
source_install_no_main() {
  local tmp; tmp=$(mktemp)
  sed '/^main "\$@"$/d' "$INSTALL_SCRIPT" > "$tmp"
  # shellcheck disable=SC1090
  source "$tmp"; rm -f "$tmp"
}
setup() {
  MOCK_HOME=$(mktemp -d); export HOME="$MOCK_HOME"
  source_install_no_main
  # ⚠️ 这里**不能** set +e：本测试要测的正是返回值，关掉就测不到 main 里 set -e 下的行为。
  INSTALL_DIR="$MOCK_HOME/.agent-gates"; mkdir -p "$INSTALL_DIR"
  TARGET_DIR="$MOCK_HOME/.cc-switch/skills"; SKIP_MEMORY_SKILL=1
  SKILLS=(alpha beta memory gamma)
  mkdir -p "$TARGET_DIR/alpha" "$TARGET_DIR/beta" "$TARGET_DIR/gamma"
  mkdir -p "$MOCK_HOME/.claude/skills" "$MOCK_HOME/.agents/skills"
}

echo "=== ① 最后一个目标是真实目录 ⇒ 返回 0、不覆盖、说出来 ==="
( setup
  mkdir -p "$MOCK_HOME/.agents/skills/gamma"; echo mine > "$MOCK_HOME/.agents/skills/gamma/SKILL.md"
  out=$(create_symlinks 2>&1) && rc=0 || rc=$?   # install.sh 开着 set -e：不显式接住返回值，子 shell 会静默退出、断言一条不跑
  assert "⭐ 返回 0（实际 ${rc}）" "$([[ $rc -eq 0 ]] && echo true || echo false)"
  assert "真实目录没被动" "$([[ -d "$MOCK_HOME/.agents/skills/gamma" && ! -L "$MOCK_HOME/.agents/skills/gamma" && "$(cat "$MOCK_HOME/.agents/skills/gamma/SKILL.md")" == mine ]] && echo true || echo false)"
  assert "⭐ 逐条点名没替换的路径" "$([[ "$out" == *"$MOCK_HOME/.agents/skills/gamma"* ]] && echo true || echo false)"
  assert "其余照常建软链" "$([[ -L "$MOCK_HOME/.agents/skills/alpha" && -L "$MOCK_HOME/.claude/skills/gamma" ]] && echo true || echo false)" )

echo "=== ② 在 set -e 下调用（main 的实际环境）也不退出 ==="
_flag=$(mktemp)
( setup
  mkdir -p "$MOCK_HOME/.agents/skills/gamma"
  set -e
  create_symlinks >/dev/null 2>&1
  echo reached > "$_flag" )
assert "⭐ create_symlinks 之后的语句还能执行（set -e 下）" "$([[ "$(cat "$_flag")" == reached ]] && echo true || echo false)"

echo "=== ③ 普通文件挡路同样处理；软链照旧刷新 ==="
( setup
  echo f > "$MOCK_HOME/.claude/skills/beta"                       # 普通文件
  ln -s /nonexistent "$MOCK_HOME/.claude/skills/alpha"             # 悬空软链 ⇒ 应被刷新
  out=$(create_symlinks 2>&1) && rc=0 || rc=$?   # install.sh 开着 set -e：不显式接住返回值，子 shell 会静默退出、断言一条不跑
  assert "返回 0（实际 ${rc}）" "$([[ $rc -eq 0 ]] && echo true || echo false)"
  assert "普通文件没被覆盖" "$([[ -f "$MOCK_HOME/.claude/skills/beta" && ! -L "$MOCK_HOME/.claude/skills/beta" ]] && echo true || echo false)"
  assert "悬空软链被刷新指向真实目录" "$([[ "$(readlink "$MOCK_HOME/.claude/skills/alpha")" == "$TARGET_DIR/alpha" ]] && echo true || echo false)" )

echo
read -r P F < "$RESULTS_FILE"; rm -f "$RESULTS_FILE"
echo "PASS=$P FAIL=$F"
[[ "$F" -eq 0 ]]
