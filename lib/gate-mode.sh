#!/usr/bin/env bash
# lib/gate-mode.sh — 门禁档位与 strict 分支判定（共享）。
#
# 🔴 为什么要抽出来：`bin/agent-gates-review` 需要知道「现在轮不到审查」才能拦住
# 提前审（2026-09-10 实况：一条会话每修一小条就派一个 agent 跑全量审查，
# 11 个 agent + 至少 7 次全量，而那些审查在下一次改动后锚点就作废了）。
# 判定逻辑原本只长在门禁里 —— 复制一份到 review CLI 就是第三次「两处实现分叉」，
# 而这种分叉的失败长得像「配置没生效」。⇒ 一份实现，两边 source。
#
# 依赖调用方先设好 `_GATE_CFG_PROJECT` / `_GATE_CFG_USER`；
# `_gate_resolve_project_cfg` 负责算前者（含 worktree 回退，见下）。

_gate_cfg_get() {
  [[ -f "$1" ]] || return 1
  local v
  v=$(python3 -c '
import json,sys
try:
    cur = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(0)
for k in sys.argv[2].split("."):
    if not isinstance(cur, dict): sys.exit(0)
    cur = cur.get(k)
    if cur is None: sys.exit(0)
print(cur)
' "$1" "$2" 2>/dev/null)
  [[ -n "$v" ]] || return 1
  printf '%s' "$v"
}

_gate_norm_mode() {
  case "$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')" in
    strict|relaxed|merge-only|off) printf '%s' "$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"; return 0 ;;
  esac
  return 1
}

_gate_resolve_mode() {   # <env-var-name> <cfg.path> <fallback> -> "<mode>|<source>"
  local envvar="$1" path="$2" fb="$3" raw m
  raw="$(eval "printf '%s' \"\${${envvar}:-}\"")"
  if [[ -n "$raw" ]]; then
    if m=$(_gate_norm_mode "$raw"); then printf '%s|env %s' "$m" "$envvar"; return 0; fi
    echo "⚠️  ${envvar}='${raw}' is not one of strict|relaxed|merge-only|off — ignored" >&2
  fi
  local f
  for f in "$_GATE_CFG_PROJECT" "$_GATE_CFG_USER"; do
    if raw=$(_gate_cfg_get "$f" "$path") && m=$(_gate_norm_mode "$raw"); then
      printf '%s|%s' "$m" "$f"; return 0
    fi
  done
  printf '%s|%s' "$fb" "inherited"
}

_gate_strict_branches() {
  local f
  for f in "$_GATE_CFG_PROJECT" "$_GATE_CFG_USER"; do
    [[ -f "$f" ]] || continue
    local out
    out=$(python3 -c '
import json,sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(0)
b = d.get("strict_branches")
if isinstance(b, list):
    for x in b:
        if x: print(x)
' "$f" 2>/dev/null)
    [[ -n "$out" ]] && { printf '%s' "$out"; return 0; }
  done
  printf '%s' 'test
master
main'
}

_gate_branch_is_strict() {
  local b="${1:-}" pat
  [[ -z "$b" || "$b" == "HEAD" ]] && return 1
  while IFS= read -r pat; do
    [[ -z "$pat" ]] && continue
    # Unquoted $pat on purpose — these are globs (release/*).
    [[ "$b" == $pat ]] && return 0
  done <<< "$(_gate_strict_branches)"
  return 1
}

_gate_resolve_project_cfg() {
  local rel=".agent/gates.json"
  [[ -f "$rel" ]] && { printf '%s' "$rel"; return 0; }
  # 🔴 先往上找仓库根。⛔ 不能只靠下面的 `--git-common-dir`：在**子目录**里它返回的是
  # **相对**路径（`../.git`），于是 case 落到 `*)` 分支、返回裸的相对 `.agent/gates.json`
  # —— 在子目录里不存在 ⇒ 项目配置整份丢掉，静默回落成 strict。
  # 后果是同一个仓在不同 cwd 下给出**相反**的答案（668f174f 实测：仓根 merge-only、
  # 子目录 strict）。方向偏松（门控不触发），所以不会报错，只会不生效。
  local top
  if top=$(git rev-parse --show-toplevel 2>/dev/null) && [[ -n "$top" && -f "$top/$rel" ]]; then
    printf '%s' "$top/$rel"; return 0
  fi
  local common main
  common=$(git rev-parse --git-common-dir 2>/dev/null) || { printf '%s' "$rel"; return 0; }
  # 主 worktree 里这个值是相对的 `.git`，那时父目录就是 `.`，与上面的分支等价。
  case "$common" in
    /*) main="${common%/.git}" ;;
    *)  printf '%s' "$rel"; return 0 ;;
  esac
  [[ -f "$main/$rel" ]] && { printf '%s' "$main/$rel"; return 0; }
  printf '%s' "$rel"
}


# ------------------------------------------------------------
# 「现在轮到审查了吗」—— 唯一判定实现
# ------------------------------------------------------------
# 🔴 为什么必须只有一份：这个判定有**三个**调用方 —— `agent-gates-review` 的时机门控、
# 它的 `--due` 查询子命令、以及 `rift-dispatch` 的派发前校验。三份实现一定分叉，
# 而分叉的档位判定失败长得像「配置没生效」，没人会去怀疑是两套逻辑（本仓已吃过两次）。
#
# 调用方先设好 `_GATE_CFG_PROJECT` / `_GATE_CFG_USER`，并 cd 到目标仓库。
# 结果写进全局：_TIM_DUE(yes|no) / _TIM_REASON / _TIM_BRANCH / _TIM_MODE / _TIM_WHEN
# 返回值：0=该审  1=轮不到
#
# ⛔ 非目标：它**不判**「这份改动值不值得审」「是不是已经审过了」。只判时机。
#    判「已审过」是门禁 CHECK 5 的锚点比对，不在这里重复一遍。
# 返回 1 = 有配置文件存在但坏掉（解析不了 / 顶层不是对象 / `strict_branches` 类型不对）
# ⇒ 调用方应按 **undetermined** 处理并放行。
# 🔴 为什么要单独一支：`_gate_cfg_get` / `_gate_strict_branches` 把「键不存在」和
# 「文件坏了」都当成「取不到」⇒ 静默回落到下一个来源或内置默认。对档位判定来说，
# 那个回落方向可能是**阻断**（实测：`strict_branches` 写成字符串 ⇒ 回落 test/master/main
# ⇒ 在 release/1.0 上判成 due=no），与「判不出来就放行」的原则相反。
# ⛔ 有意不改那两个函数 —— 门禁也在用它们，改动语义会连带改门禁行为。
# 返回 2 = 校验不了（python3 不在）。⛔ 必须与「配置真的坏了」分开 —— 否则 reason 会
# 拿着「unparseable / strict_branches 类型错」去指一份好得很的配置，看到这句话的人白查。
_gate_cfg_sane() {
  command -v python3 >/dev/null 2>&1 || return 2
  local f
  for f in "$_GATE_CFG_PROJECT" "$_GATE_CFG_USER"; do
    [[ -f "$f" ]] || continue
    python3 -c '
import json,sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(3)
if not isinstance(d, dict):
    sys.exit(3)
b = d.get("strict_branches")
if b is not None and not isinstance(b, list):
    sys.exit(3)
' "$f" 2>/dev/null || return 1
  done
  return 0
}

_gate_review_due_eval() {
  local gm mode rmode branch

  # ⛔ 仓库外没有「分支」这个概念 —— 判不出来就放行。
  # 旧实现在这里 branch="" ⇒ merge-only 判成「不是集成分支」⇒ exit 79，
  # 用户级配置是 merge-only/off 的机器上，任何非仓库目录都会被拦（异构审 finding 3）。
  if ! git rev-parse --git-dir >/dev/null 2>&1; then
    _TIM_DUE="yes"; _TIM_MODE="undetermined"; _TIM_BRANCH=""; _TIM_WHEN=""
    _TIM_REASON="undetermined (not inside a git repository) — failing open"
    return 0
  fi

  branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")

  local sane_rc=0
  _gate_cfg_sane || sane_rc=$?     # ⛔ 用 `|| rc=$?` 取码：裸调用在 errexit 下会直接掀桌
  if [[ "$sane_rc" -ne 0 ]]; then
    _TIM_DUE="yes"; _TIM_MODE="undetermined"; _TIM_BRANCH="$branch"; _TIM_WHEN=""
    if [[ "$sane_rc" -eq 2 ]]; then
      _TIM_REASON="undetermined (python3 unavailable — cannot validate gate config) — failing open"
    else
      _TIM_REASON="undetermined (gate config unparseable, or strict_branches is not a list) — failing open"
    fi
    return 0
  fi

  gm=$(_gate_resolve_mode AGENT_GATES_MODE mode strict 2>/dev/null || echo "strict|default")
  mode="${gm%%|*}"
  gm=$(_gate_resolve_mode AGENT_GATES_REVIEW_MODE review.mode "$mode" 2>/dev/null || echo "strict|default")
  rmode="${gm%%|*}"

  _TIM_MODE="$rmode"
  _TIM_BRANCH="$branch"
  _TIM_WHEN=$(_gate_strict_branches 2>/dev/null | tr '\n' ' ')
  _TIM_WHEN="${_TIM_WHEN%"${_TIM_WHEN##*[![:space:]]}"}"

  # 🔴 strict 分支优先级最高，必须**在 off / merge-only 之前**判。
  # 门禁在 strict 分支上强制 strict（`hooks/git/agent-quality-gate.sh` 的
  # strict_branches override）⇒ 这里口径若不一致就是死锁：门禁要审查产物，
  # 而 CLI 因为 `review.mode=off` 拒绝生成产物，只能靠 `--early` 绕（异构审 finding 2）。
  if _gate_branch_is_strict "$branch"; then
    _TIM_DUE="yes"; _TIM_MODE="strict"
    _TIM_REASON="branch '${branch}' is a strict branch — mode forced to strict (config said review=${rmode})"
    return 0
  fi

  # 走到这里分支一定**不是** strict 分支。
  if [[ "$rmode" == "off" ]]; then
    _TIM_DUE="no"; _TIM_REASON="review mode is off"
    return 1
  fi
  if [[ "$rmode" == "merge-only" ]]; then
    _TIM_DUE="no"
    _TIM_REASON="review mode is merge-only and '${branch:-?}' is not an integration branch"
    return 1
  fi
  _TIM_DUE="yes"; _TIM_REASON="review mode is ${rmode}"
  return 0
}
