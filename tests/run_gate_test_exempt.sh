#!/usr/bin/env bash
# Gate 1 的 tests.exempt 豁免（v2.10.0）。
#
# 🔴 背景（2026-10-10）：Gate 1 要求每个新源文件都配一个测试文件，DTO、枚举、模块注册
# 这类没有逻辑的文件也得配 —— 测试代码量超过业务代码的推手之一。
# 契约：
#   · 不配置时行为完全不变
#   · 命中 glob 的文件跳过 Gate 1，⛔ 但要打印出来，不静默放行
#   · 项目配置整份优先于用户配置（与 strict_branches 同口径）
#   · 列表必须按列表读：用标量读取器会得到 Python repr（['x']），glob 永远不命中
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GATE="$SCRIPT_DIR/../hooks/git/agent-quality-gate.sh"
RESULTS_FILE=$(mktemp); echo "0 0" > "$RESULTS_FILE"
assert() {
  local name="$1" cond="$2" p f
  read -r p f < "$RESULTS_FILE"
  if [[ "$cond" == "true" ]]; then echo "  ✓ $name"; echo "$((p+1)) $f" > "$RESULTS_FILE"
  else echo "  ✗ $name"; echo "$p $((f+1))" > "$RESULTS_FILE"; fi
}

# ⚠️ 子 shell 里的 cd 带不回来：只回显路径，调用方显式 cd。
mkrepo() {   # mkrepo <project-gates-json>
  local d; d=$(mktemp -d); ( cd "$d"
  git init -q -b feat .; git config user.email t@t; git config user.name t
  mkdir -p .agent/reviews src/dto src/svc
  printf '%s\n' "$1" > .agent/gates.json
  printf 'x\n' > README.md
  git add . && git commit -q -m init
  printf 'export interface UserDto { id: string }\n' > src/dto/user.dto.ts
  printf 'export const run = () => 1\n' > src/svc/run.ts
  git add src
  ) >/dev/null 2>&1
  echo "$d"
}
gate() { AGENT_MODE=1 AGENT_GATES_DIR="$GD" bash "$GATE" 2>&1; }

ORIG=$PWD
GD=$(mktemp -d)

echo "=== ① 不配置：行为不变，两个文件都要测试 ==="
R=$(mkrepo '{"mode":"merge-only"}'); cd "$R"
out=$(gate)
assert "DTO 仍报缺测试" "$([[ "$out" == *"No test for: src/dto/user.dto.ts"* ]] && echo true || echo false)"
assert "业务文件仍报缺测试" "$([[ "$out" == *"No test for: src/svc/run.ts"* ]] && echo true || echo false)"
assert "没有豁免提示" "$([[ "$out" != *"tests.exempt"* ]] && echo true || echo false)"
cd "$ORIG"

echo
echo "=== ② 项目配置豁免 DTO：DTO 放行并打印，业务文件照样拦 ==="
R=$(mkrepo '{"mode":"merge-only","tests":{"exempt":["src/dto/*","*.enum.ts"]}}'); cd "$R"
out=$(gate); rc=$?
assert "⭐ DTO 不再报缺测试" "$([[ "$out" != *"No test for: src/dto/user.dto.ts"* ]] && echo true || echo false)"
assert "⭐ 豁免打印出来（不静默）" "$([[ "$out" == *"exempt via tests.exempt"* && "$out" == *"src/dto/user.dto.ts"* ]] && echo true || echo false)"
assert "未命中的业务文件仍报缺测试" "$([[ "$out" == *"No test for: src/svc/run.ts"* ]] && echo true || echo false)"
assert "整体仍然失败（实际 ${rc}）" "$([[ $rc -ne 0 ]] && echo true || echo false)"
cd "$ORIG"

echo
echo "=== ③ * 跨目录：src/* 覆盖子目录里的文件 ==="
R=$(mkrepo '{"mode":"merge-only","tests":{"exempt":["src/*"]}}'); cd "$R"
out=$(gate)
assert "两个文件都被豁免" "$([[ "$out" != *"No test for:"* ]] && echo true || echo false)"
cd "$ORIG"

echo
echo "=== ④ 用户级配置生效；项目配置有 tests.exempt 时整份覆盖用户级 ==="
printf '{"tests":{"exempt":["src/svc/*"]}}\n' > "$GD/gates.json"
R=$(mkrepo '{"mode":"merge-only"}'); cd "$R"
out=$(gate)
assert "项目没配 ⇒ 用户级豁免 svc" "$([[ "$out" != *"No test for: src/svc/run.ts"* ]] && echo true || echo false)"
assert "用户级没列 DTO ⇒ DTO 仍拦" "$([[ "$out" == *"No test for: src/dto/user.dto.ts"* ]] && echo true || echo false)"
cd "$ORIG"
R=$(mkrepo '{"mode":"merge-only","tests":{"exempt":["src/dto/*"]}}'); cd "$R"
out=$(gate)
assert "项目配置整份覆盖：svc 不再豁免" "$([[ "$out" == *"No test for: src/svc/run.ts"* ]] && echo true || echo false)"
assert "项目配置的 DTO 豁免生效" "$([[ "$out" != *"No test for: src/dto/user.dto.ts"* ]] && echo true || echo false)"
cd "$ORIG"
rm -f "$GD/gates.json"

echo
echo "=== ⑤ 非法配置（不是列表）：当作没配，不静默豁免 ==="
R=$(mkrepo '{"mode":"merge-only","tests":{"exempt":"src/*"}}'); cd "$R"
out=$(gate)
assert "字符串不当列表用：两个文件仍报缺测试" \
  "$([[ "$out" == *"No test for: src/dto/user.dto.ts"* && "$out" == *"No test for: src/svc/run.ts"* ]] && echo true || echo false)"
cd "$ORIG"

echo
echo "=== ⑥ 项目显式写空列表 = 不豁免，⛔ 不继承用户级 ==="
printf '{"tests":{"exempt":["src/*"]}}\n' > "$GD/gates.json"
R=$(mkrepo '{"mode":"merge-only","tests":{"exempt":[]}}'); cd "$R"
out=$(gate)
assert "项目 exempt=[] ⇒ 两个文件仍报缺测试" \
  "$([[ "$out" == *"No test for: src/dto/user.dto.ts"* && "$out" == *"No test for: src/svc/run.ts"* ]] && echo true || echo false)"
cd "$ORIG"; rm -f "$GD/gates.json"

echo
echo "=== ⑦ 与后缀 spec（v2.10.1）同时生效：豁免、后缀测试、真缺测试各走各的 ==="
R=$(mkrepo '{"mode":"merge-only","tests":{"exempt":["src/dto/*"]}}'); cd "$R"
printf 'test\n' > src/svc/run.public.spec.ts
printf 'export const z = 1\n' > src/svc/zero.ts
git add src/svc/run.public.spec.ts src/svc/zero.ts
out=$(gate)
assert "DTO 走豁免" "$([[ "$out" == *"exempt via tests.exempt"* && "$out" != *"No test for: src/dto/user.dto.ts"* ]] && echo true || echo false)"
assert "run.ts 有 run.public.spec.ts ⇒ 不报缺测试" "$([[ "$out" != *"No test for: src/svc/run.ts"* ]] && echo true || echo false)"
assert "zero.ts 真没测试 ⇒ 仍然拦" "$([[ "$out" == *"No test for: src/svc/zero.ts"* ]] && echo true || echo false)"
cd "$ORIG"

echo
read -r P F < "$RESULTS_FILE"; rm -f "$RESULTS_FILE"
echo "PASS=$P FAIL=$F"
[[ "$F" -eq 0 ]]
