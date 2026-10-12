#!/usr/bin/env bash
# 安装器：Memory skill 可选 + SKILL.md 备份移出 skill 目录（v2.11.0）。
#
# 🔴 实况（2026-10-11 / 10-12 三次安装）：
#   · `memory` 写死在 SKILLS 里，每次都装回 —— 用户 10-07 已移除它，每次装完都要手工还原
#   · 备份是原地 `SKILL.md.bak.<ts>`（规则禁止），触发条件是「新旧内容不同」，升级时必然不同，
#     于是每次都备份，还误报成「本地改过」
# 契约：
#   · --skip-memory-skill：不装、不建软链，写标记，之后的安装沿用；--with-memory-skill 恢复
#   · 已存在的 memory 目录 / 软链：⛔ 不自动删，打印清理指引
#   · 备份落在 $INSTALL_DIR/backups/skills/<skill>/，skill 目录里不留 .bak
#   · 只在「已装文件 ≠ 上次安装记录的 sha256（按绝对路径记）」时备份；没有记录 ⇒ 保守备份
#   · uninstall 不带 --purge-backups 时保留备份（它原本 rm -rf 整个 ${INSTALL_DIR}）
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_SCRIPT="$SCRIPT_DIR/../install.sh"
UNINSTALL_SCRIPT="$SCRIPT_DIR/../uninstall.sh"
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
# 一个假仓库：两个 skill（memory 与 alpha），各带 SKILL.md
mkrepo() {
  local r; r=$(mktemp -d)
  mkdir -p "$r/skills/memory" "$r/skills/alpha"
  printf 'memory v%s\n' "$1" > "$r/skills/memory/SKILL.md"
  printf 'alpha v%s\n' "$1" > "$r/skills/alpha/SKILL.md"
  echo "$r"
}
setup() {   # 在子 shell 里调用：隔离 HOME / 安装器全局变量
  MOCK_HOME=$(mktemp -d); export HOME="$MOCK_HOME"
  source_install_no_main
  # ⚠️ install.sh 开着 set -euo pipefail：不关掉的话，任何一处出错都会让这个子 shell 悄悄退出，
  #    整组断言一条不跑、也不报错（第一次跑 RED 时就是这样）。
  set +e +u
  INSTALL_DIR="$MOCK_HOME/.agent-gates"; mkdir -p "$INSTALL_DIR"
  TARGET_DIR="$MOCK_HOME/.cc-switch/skills"; mkdir -p "$TARGET_DIR" "$MOCK_HOME/.claude/skills"
  SKILLS=(alpha memory)
  BACKED_UP_SKILLS=()
}
nobak() { [[ -z "$(find "$TARGET_DIR" -name 'SKILL.md.bak*' 2>/dev/null)" ]]; }
nbackups() { find "$INSTALL_DIR/backups" -type f 2>/dev/null | wc -l | tr -d ' '; }

echo "=== Memory skill 可选 ==="
( setup; REPO_DIR=$(mkrepo 1)
  MEMORY_SKILL_PREF=""; resolve_memory_skill_pref >/dev/null 2>&1
  install_skills >/dev/null 2>&1
  assert "默认（无标记）仍装 memory（其他用户不受影响）" "$([[ -f "$TARGET_DIR/memory/SKILL.md" ]] && echo true || echo false)" )

( setup; REPO_DIR=$(mkrepo 1)
  # ⚠️ 不能写 out=$(resolve_memory_skill_pref)：命令替换是子 shell，它设的 SKIP_MEMORY_SKILL 带不回来。
  _o=$(mktemp); MEMORY_SKILL_PREF="skip"; resolve_memory_skill_pref > "$_o" 2>&1; out=$(cat "$_o")
  install_skills >/dev/null 2>&1; create_symlinks >/dev/null 2>&1
  assert "⭐ --skip-memory-skill：不装 memory" "$([[ ! -e "$TARGET_DIR/memory" ]] && echo true || echo false)"
  assert "其它 skill 照装" "$([[ -f "$TARGET_DIR/alpha/SKILL.md" ]] && echo true || echo false)"
  assert "不建 memory 软链" "$([[ ! -e "$MOCK_HOME/.claude/skills/memory" && ! -L "$MOCK_HOME/.claude/skills/memory" ]] && echo true || echo false)"
  assert "写了标记文件" "$([[ -f "$INSTALL_DIR/.skip-memory-skill" ]] && echo true || echo false)"
  assert "打印说明，不静默" "$([[ "$out" == *"--with-memory-skill"* ]] && echo true || echo false)" )

( setup; REPO_DIR=$(mkrepo 1)
  touch "$INSTALL_DIR/.skip-memory-skill"
  MEMORY_SKILL_PREF=""; resolve_memory_skill_pref >/dev/null 2>&1
  install_skills >/dev/null 2>&1
  assert "⭐ 有标记、不带参数 ⇒ 之后的安装沿用跳过" "$([[ ! -e "$TARGET_DIR/memory" ]] && echo true || echo false)" )

( setup; REPO_DIR=$(mkrepo 1)
  touch "$INSTALL_DIR/.skip-memory-skill"
  MEMORY_SKILL_PREF="with"; resolve_memory_skill_pref >/dev/null 2>&1
  install_skills >/dev/null 2>&1
  assert "--with-memory-skill ⇒ 删标记" "$([[ ! -f "$INSTALL_DIR/.skip-memory-skill" ]] && echo true || echo false)"
  assert "--with-memory-skill ⇒ 恢复安装" "$([[ -f "$TARGET_DIR/memory/SKILL.md" ]] && echo true || echo false)" )

( setup; REPO_DIR=$(mkrepo 1)
  mkdir -p "$TARGET_DIR/memory"; echo old > "$TARGET_DIR/memory/SKILL.md"
  ln -s "$TARGET_DIR/memory" "$MOCK_HOME/.claude/skills/memory"
  MEMORY_SKILL_PREF="skip"; out=$(resolve_memory_skill_pref 2>&1)
  assert "⛔ 已存在的 memory 目录不自动删" "$([[ -f "$TARGET_DIR/memory/SKILL.md" ]] && echo true || echo false)"
  assert "已存在的软链不自动删" "$([[ -L "$MOCK_HOME/.claude/skills/memory" ]] && echo true || echo false)"
  assert "打印逐条路径" "$([[ "$out" == *"$TARGET_DIR/memory"* && "$out" == *".claude/skills/memory"* ]] && echo true || echo false)" )

echo
echo "=== SKILL.md 备份移出 skill 目录，且只在本地改过时备份 ==="
( setup; REPO_DIR=$(mkrepo 1); MEMORY_SKILL_PREF="skip"; resolve_memory_skill_pref >/dev/null 2>&1
  mkdir -p "$TARGET_DIR/alpha"; echo "pre-existing" > "$TARGET_DIR/alpha/SKILL.md"   # 老版本装的，没有清单
  install_skills >/dev/null 2>&1
  assert "无清单记录 ⇒ 保守备份一次" "$([[ "$(nbackups)" == 1 ]] && echo true || echo false)"
  assert "⭐ 备份在 \$INSTALL_DIR/backups/skills/alpha/ 下" "$([[ -n "$(find "$INSTALL_DIR/backups/skills/alpha" -name 'SKILL.md.*' 2>/dev/null)" ]] && echo true || echo false)"
  assert "⭐ skill 目录里没有 .bak" "$(nobak && echo true || echo false)"
  assert "装完写入清单（绝对路径）" "$(grep -qF "$TARGET_DIR/alpha/SKILL.md" "$INSTALL_DIR/installed-skills.sha256" 2>/dev/null && echo true || echo false)"
  # 升级：源变了，已装文件没被动过 ⇒ 不备份
  REPO_DIR=$(mkrepo 2); BACKED_UP_SKILLS=()
  out=$(install_skills 2>&1)
  assert "⭐ 升级、未本地修改 ⇒ 不备份" "$([[ "$(nbackups)" == 1 ]] && echo true || echo false)"
  assert "不再误报「本地改过」" "$([[ "$out" != *"backed up"* && "$out" != *"Backed up"* ]] && echo true || echo false)"
  assert "确实装上了新版" "$(grep -q 'alpha v2' "$TARGET_DIR/alpha/SKILL.md" && echo true || echo false)"
  # 本地改过 ⇒ 备份
  echo "my local edit" >> "$TARGET_DIR/alpha/SKILL.md"
  REPO_DIR=$(mkrepo 3); BACKED_UP_SKILLS=()
  install_skills >/dev/null 2>&1
  assert "⭐ 本地改过 ⇒ 备份" "$([[ "$(nbackups)" == 2 ]] && echo true || echo false)"
  assert "备份里有本地改动" "$(grep -rqs 'my local edit' "$INSTALL_DIR/backups/skills/alpha/" && echo true || echo false)"
  assert "skill 目录里仍没有 .bak" "$(nobak && echo true || echo false)" )

( setup; REPO_DIR=$(mkrepo 1); MEMORY_SKILL_PREF="skip"; resolve_memory_skill_pref >/dev/null 2>&1
  install_skills >/dev/null 2>&1                       # 默认目标装一次，清单有记录
  OTHER="$MOCK_HOME/other-target"; mkdir -p "$OTHER/alpha"
  cp "$TARGET_DIR/alpha/SKILL.md" "$OTHER/alpha/SKILL.md"; echo "edit in other" >> "$OTHER/alpha/SKILL.md"
  TARGET_DIR="$OTHER"; REPO_DIR=$(mkrepo 2); BACKED_UP_SKILLS=()
  install_skills >/dev/null 2>&1
  assert "⭐ 清单按绝对路径记：换了目标目录、本地改过的文件不会被误判为未改" \
    "$(grep -rqs 'edit in other' "$INSTALL_DIR/backups/skills/alpha/" && echo true || echo false)" )

echo
echo "=== uninstall 不带 --purge-backups 时保留备份 ==="
( MOCK_HOME=$(mktemp -d); export HOME="$MOCK_HOME"
  mkdir -p "$MOCK_HOME/.agent-gates/backups/skills/alpha" "$MOCK_HOME/.agent-gates/bin"
  echo keep > "$MOCK_HOME/.agent-gates/backups/skills/alpha/SKILL.md.20261012-000000"
  echo x > "$MOCK_HOME/.agent-gates/bin/tool"
  bash "$UNINSTALL_SCRIPT" --keep-skills >/dev/null 2>&1
  assert "⭐ 不带 --purge-backups ⇒ 备份还在" "$([[ -f "$MOCK_HOME/.agent-gates/backups/skills/alpha/SKILL.md.20261012-000000" ]] && echo true || echo false)"
  assert "其余安装内容已删" "$([[ ! -e "$MOCK_HOME/.agent-gates/bin" ]] && echo true || echo false)"
  bash "$UNINSTALL_SCRIPT" --keep-skills --purge-backups >/dev/null 2>&1
  assert "--purge-backups ⇒ 备份也删" "$([[ ! -e "$MOCK_HOME/.agent-gates/backups" ]] && echo true || echo false)" )

echo
read -r P F < "$RESULTS_FILE"; rm -f "$RESULTS_FILE"
echo "PASS=$P FAIL=$F"
[[ "$F" -eq 0 ]]
