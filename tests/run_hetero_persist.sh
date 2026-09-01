#!/usr/bin/env bash
# Tests for hetero-check.json persistence — doctor must not destroy hand-set config.
#
# THE BUG (found 2026-09-01): doctor.sh built the whole file with a fixed heredoc and
# `mv`'d it into place. `implementer_family`, `pi_models` and `channels` appear ZERO times
# in doctor.sh, so every run silently dropped them. The worst consequence is not the loss
# itself: `channels.opencode.enabled=false` was set deliberately to stop agents wedging on
# the opencode review channel, and wiping it RE-ENABLES that channel. A maintenance command
# that quietly undoes a deliberate safety setting is worse than one that fails loudly.
#
# So the write must MERGE: doctor owns its own keys and leaves everything else alone.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$SCRIPT_DIR/../lib/hetero/persist.sh"
RESULTS_FILE=$(mktemp); echo "0 0" > "$RESULTS_FILE"

assert() {
  local name="$1" cond="$2" p f
  read -r p f < "$RESULTS_FILE"
  if [[ "$cond" == "true" ]]; then echo "  ✓ $name"; echo "$((p+1)) $f" > "$RESULTS_FILE"
  else echo "  ✗ $name"; echo "$p $((f+1))" > "$RESULTS_FILE"; fi
}
eq() { assert "$1 → $3 (实际 $2)" "$([[ "$2" == "$3" ]] && echo true || echo false)"; }
jget() { python3 -c '
import json,sys
cur=json.load(open(sys.argv[1]))
for k in sys.argv[2].split("."):
    if not isinstance(cur,dict): print(""); sys.exit(0)
    cur=cur.get(k)
    if cur is None: print(""); sys.exit(0)
print(json.dumps(cur, ensure_ascii=False) if isinstance(cur,(dict,list,bool)) else cur)' "$1" "$2" 2>/dev/null; }

[[ -f "$LIB" ]] || { echo "  ✗ lib/hetero/persist.sh 不存在（未实现）"; echo "=== PASS=0 FAIL=1 ==="; exit 1; }
source "$LIB"

echo "=== hetero-check.json persistence tests ==="
echo

T=$(mktemp -d)
seed() {
  cat > "$T/hc.json" <<'EOF'
{
  "detected_at": "2026-01-01T00:00:00Z",
  "level": "L1",
  "review_models": { "primary": "github-copilot/gpt-5.5" },
  "implementer_family": "anthropic",
  "pi_models": { "primary": "volcengine-coding/deepseek-v4-flash" },
  "channels": { "paseo": { "enabled": false }, "opencode": { "enabled": false } },
  "_note_channels": "手工写的说明，也不该丢"
}
EOF
}
NEW='{"detected_at":"2026-09-01T00:00:00Z","detected_by":"doctor","level":"L3","preferred_route":"pi"}'

echo "P1: ⭐ doctor 不拥有的键必须保留"
seed
hetero_merge_check_json "$T/hc.json" "$NEW"
eq "implementer_family 保留" "$(jget "$T/hc.json" implementer_family)" anthropic
eq "pi_models.primary 保留" "$(jget "$T/hc.json" pi_models.primary)" volcengine-coding/deepseek-v4-flash
# 这条是本次最要紧的：抹掉它等于把 opencode 通道重新打开
eq "⭐ channels.opencode.enabled 保留为 false" "$(jget "$T/hc.json" channels.opencode.enabled)" false
eq "channels.paseo.enabled 保留为 false" "$(jget "$T/hc.json" channels.paseo.enabled)" false
eq "_note_channels 保留" "$(jget "$T/hc.json" _note_channels)" "手工写的说明，也不该丢"

echo "P2: doctor 拥有的键必须被更新"
eq "level 更新" "$(jget "$T/hc.json" level)" L3
eq "detected_at 更新" "$(jget "$T/hc.json" detected_at)" 2026-09-01T00:00:00Z
eq "preferred_route 写入" "$(jget "$T/hc.json" preferred_route)" pi

echo "P3: 文件仍是合法 JSON"
python3 -c "import json,sys; json.load(open('$T/hc.json'))" 2>/dev/null
eq "可解析" "$?" 0

echo "P4: 目标文件不存在 → 直接写入，不报错"
rm -f "$T/hc.json"
hetero_merge_check_json "$T/hc.json" "$NEW"
eq "退出码 0" "$?" 0
eq "level 写入" "$(jget "$T/hc.json" level)" L3

echo "P5: 目标文件是坏 JSON → 不静默丢弃，退出非零且保留原文件"
printf 'this is not json{{{\n' > "$T/hc.json"
hetero_merge_check_json "$T/hc.json" "$NEW" >/dev/null 2>&1
rc=$?
assert "非零退出 (实际 $rc)" "$([[ $rc -ne 0 ]] && echo true || echo false)"
# 坏 JSON 可能是人手工编辑写坏的，里面仍有他要的内容。直接覆盖会让他丢东西且不知道。
assert "⛔ 原文件未被覆盖（可能含用户手工内容）" "$(grep -q 'not json' "$T/hc.json" && echo true || echo false)"

echo "P6: 新片段本身是坏 JSON → 拒绝，绝不破坏目标"
seed
hetero_merge_check_json "$T/hc.json" '{broken' >/dev/null 2>&1
rc=$?
assert "非零退出 (实际 $rc)" "$([[ $rc -ne 0 ]] && echo true || echo false)"
eq "目标 implementer_family 仍在" "$(jget "$T/hc.json" implementer_family)" anthropic

echo "P7: 写入是原子的——不留 .tmp 残骸"
seed
hetero_merge_check_json "$T/hc.json" "$NEW"
n=$(find "$T" -name 'hc.json.tmp*' 2>/dev/null | wc -l | tr -d ' ')
eq "无 tmp 残留" "$n" 0

echo "P8: 嵌套键按对象合并，不整块替换"
seed
hetero_merge_check_json "$T/hc.json" '{"review_models":{"primary":"github-copilot/gpt-5.6-sol"}}'
eq "primary 被更新" "$(jget "$T/hc.json" review_models.primary)" github-copilot/gpt-5.6-sol
eq "同级 channels 未受影响" "$(jget "$T/hc.json" channels.opencode.enabled)" false

# ---------------------------------------------------------------------------
# doctor.sh 的调用点
#
# 直接跑 doctor.sh 验证不可行：它的 D6 步骤经 opencode 探测模型，而那正是会挂
# 120–200s 的通道 —— 实测跑了 6 分钟仍卡在写入之前、CPU 0%，集成测试拿不到结论。
# （顺带说明了为什么 review_models.primary 一直停在一个已下架的型号：刷新路径
# 既依赖 opencode，又慢到没人会跑。）
# 所以这里验证两件确定性的事：破坏性写法没了，且它构造的 JSON 经 merge 后手工键存活。
# ---------------------------------------------------------------------------
echo
echo "D: doctor.sh 的写入路径"
DOC="$SCRIPT_DIR/../doctor.sh"

echo "D1: 不再整表覆盖 hetero-check.json"
assert "已改用 hetero_merge_check_json" "$(grep -q 'hetero_merge_check_json "\$out_file"' "$DOC" && echo true || echo false)"
# 旧写法是 `cat > "$tmp_file" <<RCEOF … RCEOF` 紧跟 `mv "$tmp_file" "$out_file"`
assert "⛔ 不再有 mv tmp → hetero-check.json" "$(grep -q 'mv "\$tmp_file" "\$out_file"' "$DOC" && echo false || echo true)"
assert "review-capability.json 也走 merge 而非 cp" "$(grep -q 'cp "\$out_file" "\$INSTALL_DIR/review-capability.json"' "$DOC" && echo false || echo true)"
assert "缺 persist.sh 时不用全量覆盖兜底" "$(grep -q '绝不用全量覆盖兜底' "$DOC" && echo true || echo false)"

echo "D2: doctor 构造的 JSON 片段合法，且 merge 后手工键存活"
for RMJ in "" ',
  "review_models": {"primary":"github-copilot/gpt-5.6-sol"}'; do
  (
    # 抽出 doctor 里的 heredoc，喂桩变量执行 —— 测的是它真正构造出来的字符串，
    # 不是我照字段名重造的假设（照假设造 fake 曾让 25 条断言全绿而对真命令一条不成立）。
    detected_at="2026-09-01T00:00:00Z"; level="L3"; env_type="local"
    opencode_available=false; codex_available=true; omc_codex_plugin=true; paseo_available=true
    esc_opencode_path="/x/opencode"; esc_codex_path="/x/codex"; esc_codex_version="1.0"
    preferred="pi"; fallback="codex"; review_models_json="$RMJ"
    BODY=$(awk '/doctor_json=\$\(cat <<RCEOF/{f=1;next} /^RCEOF$/{if(f){exit}} f' "$DOC")
    FRAG=$(eval "cat <<RCEOF
$BODY
RCEOF")
    printf '%s' "$FRAG" > "$T/frag.json"
    python3 -c "import json,sys; json.load(open('$T/frag.json'))" 2>/dev/null
    eq "片段是合法 JSON (review_models=${RMJ:+有}${RMJ:-无})" "$?" 0
    seed
    hetero_merge_check_json "$T/hc.json" "$FRAG"
    eq "  merge 后 implementer_family 存活" "$(jget "$T/hc.json" implementer_family)" anthropic
    eq "  merge 后 opencode 通道仍为关闭" "$(jget "$T/hc.json" channels.opencode.enabled)" false
    eq "  level 被 doctor 更新" "$(jget "$T/hc.json" level)" L3
  )
done

rm -rf "$T"
echo
read -r P F < "$RESULTS_FILE"
echo "=== PASS=$P FAIL=$F ==="
rm -f "$RESULTS_FILE"
[[ "$F" -eq 0 ]]
