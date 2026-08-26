#!/usr/bin/env bash
# Tests that `install.sh --local` does not delete the checkout's parent directory.
#
# The bug this pins (2026-08-21..26, six occurrences, ~data loss):
#   fetch_repo:  --local sets REPO_DIR="$SCRIPT_DIR"   (the user's own checkout)
#   cleanup:     rm -rf "$(dirname "$REPO_DIR")"       (⇒ rm -rf <parent of checkout>)
# In remote mode REPO_DIR is "$tmp_dir/agent-gates", so dirname is the temp dir and deleting
# it is correct. In --local mode it wiped ~/AgentWorkspace/projects/tools — the checkout and
# everything beside it — on every single install. It was misdiagnosed as syncthing
# propagating a remote deletion; the syncthing DB actually showed the delete originating
# from THIS device, which is what finally pointed here.
#
# The trap is on EXIT, so cleanup runs even when install fails early. That makes this test
# valid without needing a fully working install.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_SH="$SCRIPT_DIR/../install.sh"
RESULTS_FILE=$(mktemp); echo "0 0" > "$RESULTS_FILE"

assert() {
  local name="$1" cond="$2" p f
  read -r p f < "$RESULTS_FILE"
  if [[ "$cond" == "true" ]]; then echo "  ✓ $name"; echo "$((p+1)) $f" > "$RESULTS_FILE"
  else echo "  ✗ $name"; echo "$p $((f+1))" > "$RESULTS_FILE"; fi
}

echo "=== install.sh --local safety tests ==="
echo

echo "I1: --local 不得删除 checkout 的父目录"
(
  PARENT=$(mktemp -d)          # 扮演 projects/tools
  CHECKOUT="$PARENT/agent-gates"
  mkdir -p "$CHECKOUT/skills/dummy" "$CHECKOUT/bin" "$CHECKOUT/hooks/git" "$CHECKOUT/hooks/platform"
  echo "9.9.9" > "$CHECKOUT/.version"
  cp "$INSTALL_SH" "$CHECKOUT/install.sh"
  # 哨兵：与 checkout 平级,若父目录被 rm -rf 则一起消失
  echo sentinel > "$PARENT/DO_NOT_DELETE_ME.txt"
  FAKE_HOME=$(mktemp -d)       # 隔离安装目标（INSTALL_DIR="$HOME/.agent-gates"）

  HOME="$FAKE_HOME" bash "$CHECKOUT/install.sh" --local >/dev/null 2>&1 || true

  assert "父目录仍存在" "$([[ -d "$PARENT" ]] && echo true || echo false)"
  assert "⭐ 平级哨兵文件未被删" "$([[ -f "$PARENT/DO_NOT_DELETE_ME.txt" ]] && echo true || echo false)"
  assert "checkout 本身未被删" "$([[ -d "$CHECKOUT" ]] && echo true || echo false)"
  assert "checkout 里的 .version 还在" "$([[ -f "$CHECKOUT/.version" ]] && echo true || echo false)"
  rm -rf "$PARENT" "$FAKE_HOME"
)

echo "I2: cleanup 只删自己 mktemp 出来的目录（代码层面钉住）"
# 只看非注释行——那行旧代码现在被引用在注释里作为说明，grep 不区分两者
grep -vE '^[[:space:]]*#' "$INSTALL_SH" | grep -q 'rm -rf "$(dirname "$REPO_DIR")"' && r=false || r=true
assert "不再用 dirname \$REPO_DIR 做删除目标" "$r"
grep -qE '_TMP_FETCH_DIR|_FETCH_TMP_DIR' "$INSTALL_SH" && r=true || r=false
assert "改为只删记录下来的临时目录" "$r"

echo
read -r P F < "$RESULTS_FILE"
echo "=== PASS=$P FAIL=$F ==="
rm -f "$RESULTS_FILE"
[[ "$F" -eq 0 ]]
