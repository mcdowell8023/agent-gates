#!/usr/bin/env bash
# 审查级别按实际模型定，遵循「异构 > 同构 > 不查」（v2.10.0）。
#
# 🔴 背景：免 token 导入一律记本机能力级别（L1），不看是谁审的；paseo 导入遇到 claude
# provider 又直接 exit 75 拒绝 —— 一边不判、一边过严。派发建议还写死了已移除的
# github-copilot 型号。
# 契约：
#   · 三条导入路径（免 token / 带 token 声明式 / 带 token 已验证 agent）共用一个定级函数：
#     审查者族 ≠ 实现者族 ⇒ 本机级别；同族或认不出 ⇒ L0（门禁只告警）
#   · 已验证 agent 先看 Model 的族，认不出再看 Provider；⛔ 不把 claude 固定判 L0
#   · 派发建议读配置（hetero_models 优先），不写死型号
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

# ⚠️ 子 shell 里的 cd 带不回来：只回显路径，调用方显式 cd。
mkrepo() {   # 暂存一笔超过审查阈值的改动（两个逻辑文件、>50 行）
  local d i n; d=$(mktemp -d); ( cd "$d"
  git init -q -b feat .; git config user.email t@t; git config user.name t
  mkdir -p .agent/reviews .agent/verify
  printf '{"mode":"strict","verify":{"mode":"off"}}\n' > .agent/gates.json
  printf 'x\n' > README.md; git add . && git commit -q -m init
  for i in 1 2; do
    printf 'export const f%s = () => {\n' "$i" > "mod$i.ts"
    for n in $(seq 1 30); do echo "  // line $n" >> "mod$i.ts"; done
    echo "}" >> "mod$i.ts"
    echo "test('f$i', () => {})" > "mod$i.test.ts"
  done
  git add mod1.ts mod2.ts mod1.test.ts mod2.test.ts
  ) >/dev/null 2>&1
  echo "$d"
}
mkgd() {   # mkgd <models-key> <primary> <panel> —— 本机 L1、实现者 anthropic
  local d; d=$(mktemp -d)
  python3 - "$d/hetero-check.json" "$@" <<'PY'
import json, sys
p, key, primary, panel = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
d = {"level": "L1", "implementer_family": "anthropic"}
if key != "none":
    d[key] = {"primary": primary, "panel_pool": [x for x in panel.split(",") if x],
              "panel_active": 2, "panel_mode": "off"}
json.dump(d, open(p, "w"))
PY
  echo "$d"
}
BODY=$(mktemp); printf '看过了。\n\nVERDICT: PASS\n' > "$BODY"
PROMPT=$(mktemp); printf '审查。最后一行 VERDICT: PASS 或 VERDICT: ISSUES\n' > "$PROMPT"
lvl() { sed -n 's/^<!-- REVIEW_LEVEL: \(.*\) -->$/\1/p' "$1" | tail -1; }
imp() {   # imp <model> <out> [env...]
  local model="$1" out="$2"; shift 2
  env AGENT_GATES_DIR="$GD" "$@" bash "$REVIEW" --import-result "$BODY" --imported-model "$model" --result "$out" 2>&1
}
ORIG=$PWD

echo "=== ① 免 token 导入：按型号定级 ==="
R=$(mkrepo); GD=$(mkgd review_models x/y ""); cd "$R"
imp "pi/github-copilot/gpt-5.5" .agent/reviews/a.md >/dev/null
assert "⭐ 异构（openai 审 anthropic 实现）记 L1" "$([[ "$(lvl .agent/reviews/a.md)" == L1 ]] && echo true || echo false)"
out=$(imp "anthropic/claude-opus-5" .agent/reviews/b.md)
assert "⭐ 同族（claude-opus-5）记 L0" "$([[ "$(lvl .agent/reviews/b.md)" == L0 ]] && echo true || echo false)"
assert "同族时 stderr 说明是同族审查" "$([[ "$out" == *same-family* ]] && echo true || echo false)"
imp "acme/weird-model-x" .agent/reviews/c.md >/dev/null
assert "认不出的型号记 L0（fail-closed）" "$([[ "$(lvl .agent/reviews/c.md)" == L0 ]] && echo true || echo false)"
imp "anthropic/claude-opus-5" .agent/reviews/d.md HETERO_IMPLEMENTER_FAMILY=openai >/dev/null
assert "实现者 openai ⇒ claude 审查记 L1" "$([[ "$(lvl .agent/reviews/d.md)" == L1 ]] && echo true || echo false)"
imp "pi/github-copilot/gpt-5.5" .agent/reviews/e.md HETERO_IMPLEMENTER_FAMILY=openai >/dev/null
assert "实现者 openai ⇒ gpt 审查记 L0" "$([[ "$(lvl .agent/reviews/e.md)" == L0 ]] && echo true || echo false)"
cd "$ORIG"

echo
echo "=== ② 带 token 声明式导入（无 --paseo-agent）同样按型号定级 ==="
R=$(mkrepo); GD=$(mkgd review_models x/y ""); cd "$R"
AGENT_GATES_DIR="$GD" bash "$REVIEW" "$PROMPT" --route paseo --dispatch-out "$R/req.json" >/dev/null 2>&1
TOKEN=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["token"])' "$R/req.json" 2>/dev/null)
AGENT_GATES_DIR="$GD" bash "$REVIEW" --import-result "$BODY" --token "$TOKEN" \
  --imported-model "anthropic/claude-sonnet-5" --result .agent/reviews/t.md >/dev/null 2>&1; rc=$?
assert "导入成功（实际 ${rc}）" "$([[ $rc -eq 0 ]] && echo true || echo false)"
assert "⭐ 同族型号记 L0，⛔ 不沿用本机级别" "$([[ "$(lvl .agent/reviews/t.md)" == L0 ]] && echo true || echo false)"
cd "$ORIG"

echo
echo "=== ③ 带 token 已验证 agent（假 paseo）：先看 Model 的族，再看 Provider ==="
FAKE=$(mktemp -d); cat > "$FAKE/paseo" <<'FAKEP'
#!/usr/bin/env bash
if [[ "${1:-}" == "agent" && "${2:-}" == "inspect" ]]; then
  [[ -f "${FAKE_PASEO_AGENTS:-}" ]] && grep -q "\"Id\":\"${3:-}\"" "$FAKE_PASEO_AGENTS" && cat "$FAKE_PASEO_AGENTS"
  exit 0
fi
exit 1
FAKEP
chmod +x "$FAKE/paseo"
verified() {   # verified <provider> <model> <out> [env...]
  local prov="$1" model="$2" out="$3" tok aj; shift 3
  AGENT_GATES_DIR="$GD" bash "$REVIEW" "$PROMPT" --route paseo --dispatch-out "$R/rq.json" >/dev/null 2>&1
  tok=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["token"])' "$R/rq.json" 2>/dev/null)
  aj=$(mktemp)
  printf '{"Id":"ag1","Name":"[review]","Provider":"%s","Model":"%s","CreatedAt":"2099-01-01T00:00:00Z","Status":"idle","Cwd":"/tmp"}\n' "$prov" "$model" > "$aj"
  env AGENT_GATES_DIR="$GD" AG_REVIEW_PASEO="$FAKE/paseo" FAKE_PASEO_AGENTS="$aj" "$@" \
    bash "$REVIEW" --import-result "$BODY" --token "$tok" --paseo-agent ag1 --result "$out" 2>&1
}
R=$(mkrepo); GD=$(mkgd review_models x/y ""); cd "$R"
out=$(verified claude opus .agent/reviews/v1.md); rc=$?
assert "⭐ Provider=claude 不再被拒（实际 ${rc}）" "$([[ $rc -eq 0 ]] && echo true || echo false)"
assert "Provider=claude、实现者 anthropic ⇒ L0" "$([[ "$(lvl .agent/reviews/v1.md)" == L0 ]] && echo true || echo false)"
verified claude opus .agent/reviews/v2.md HETERO_IMPLEMENTER_FAMILY=openai >/dev/null
assert "⭐ 实现者 openai + Provider=claude ⇒ L1（⛔ 不固定判 L0）" "$([[ "$(lvl .agent/reviews/v2.md)" == L1 ]] && echo true || echo false)"
verified opencode claude-opus-5 .agent/reviews/v3.md >/dev/null
assert "Provider=opencode、Model=claude-opus-5 ⇒ 按 Model 判族记 L0" "$([[ "$(lvl .agent/reviews/v3.md)" == L0 ]] && echo true || echo false)"
verified codex gpt-5.5 .agent/reviews/v4.md >/dev/null
assert "Provider=codex、Model=gpt-5.5 ⇒ L1" "$([[ "$(lvl .agent/reviews/v4.md)" == L1 ]] && echo true || echo false)"
cd "$ORIG"

echo
echo "=== ④ 派发建议读配置，不写死型号 ==="
sug() { python3 -c 'import json,sys;print(json.dumps(json.load(open(sys.argv[1])),ensure_ascii=False))' "$1" 2>/dev/null; }
R=$(mkrepo); GD=$(mkgd review_models bailian-token-plan/qwen3.8-max volcengine-coding/glm-5.3); cd "$R"
AGENT_GATES_DIR="$GD" bash "$REVIEW" "$PROMPT" --route paseo --dispatch-out "$R/s1.json" >/dev/null 2>&1
S=$(sug "$R/s1.json")
assert "⭐ 首选取配置的 primary" "$([[ "$S" == *"pi/bailian-token-plan/qwen3.8-max"* ]] && echo true || echo false)"
assert "备选含配置的 panel" "$([[ "$S" == *"pi/volcengine-coding/glm-5.3"* ]] && echo true || echo false)"
assert "⭐ 不再出现写死的 github-copilot" "$([[ "$S" != *github-copilot* ]] && echo true || echo false)"
assert "有同构兜底说明" "$([[ "$S" == *同族* ]] && echo true || echo false)"
GD=$(mkgd hetero_models codex/gpt-5.5 ""); python3 - "$GD/hetero-check.json" <<'PY'
import json,sys; p=sys.argv[1]; d=json.load(open(p))
d["review_models"]={"primary":"should-not-win/x","panel_pool":[],"panel_active":2,"panel_mode":"off"}
json.dump(d,open(p,"w"))
PY
AGENT_GATES_DIR="$GD" bash "$REVIEW" "$PROMPT" --route paseo --dispatch-out "$R/s2.json" >/dev/null 2>&1
S=$(sug "$R/s2.json")
assert "hetero_models 键优先于 review_models" "$([[ "$S" == *"codex/gpt-5.5"* && "$S" != *should-not-win* ]] && echo true || echo false)"
GD=$(mkgd none "" ""); printf '{"level":"L1","implementer_family":"anthropic"}\n' > "$GD/hetero-check.json"
AGENT_GATES_DIR="$GD" bash "$REVIEW" "$PROMPT" --route paseo --dispatch-out "$R/s3.json" >/dev/null 2>&1
S=$(sug "$R/s3.json")
assert "无模型配置 ⇒ 通用提示，仍不写死型号" "$([[ "$S" == *任意异构模型* && "$S" != *github-copilot* ]] && echo true || echo false)"
cd "$ORIG"

echo
echo "=== ⑤ CHECK 5：同一 diff 一份 L0 PASS + 一份 L1 PASS ⇒ 不打同族告警 ==="
R=$(mkrepo); GD=$(mkgd review_models x/y ""); cd "$R"
# ⚠️ 顺序要让 L0 **最后**被扫到：共享库文件名是 <时间戳>-<pid>.md，按字典序扫，
#    后导入的排在后面。先 L1、隔一秒再 L0 —— 没有「异构优先」时最后那份 L0 会覆盖 L1。
imp "pi/github-copilot/gpt-5.5" .agent/reviews/a-l1.md >/dev/null
sleep 1
imp "anthropic/claude-opus-5" .agent/reviews/z-l0.md >/dev/null
out=$(AGENT_MODE=1 AGENT_GATES_DIR="$GD" SKIP_PLAN_CHECK=1 bash "$GATE" 2>&1); rc=$?
assert "放行（实际 ${rc}）" "$([[ $rc -eq 0 ]] && echo true || echo false)"
assert "⭐ 选中 L1 那份，不打同族告警" "$([[ "$out" != *same-family* ]] && echo true || echo false)"
rm -f .agent/reviews/a-l1.md "$GD"/artifacts/*/reviews/*
imp "anthropic/claude-opus-5" .agent/reviews/only-l0.md >/dev/null
out=$(AGENT_MODE=1 AGENT_GATES_DIR="$GD" SKIP_PLAN_CHECK=1 bash "$GATE" 2>&1); rc=$?
assert "只有 L0 PASS ⇒ 放行（实际 ${rc}）" "$([[ $rc -eq 0 ]] && echo true || echo false)"
assert "只有 L0 PASS ⇒ 打同族告警" "$([[ "$out" == *same-family* ]] && echo true || echo false)"
cd "$ORIG"

echo
read -r P F < "$RESULTS_FILE"; rm -f "$RESULTS_FILE"
echo "PASS=$P FAIL=$F"
[[ "$F" -eq 0 ]]
