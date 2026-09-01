#!/usr/bin/env bash
# Tests for CHECK 6's verify-document selection.
#
# Failure mode this guards (reported + reproduced 2026-08-24): selection was "newest by
# mtime within 4h", compared with a strict `>`. `git worktree add` stamps every file with
# the same mtime, so in a fresh worktree ALL historical verify docs land inside the window
# with IDENTICAL mtimes and "newest" degenerates into "whichever find returned first".
# Observed: 38 docs all at the worktree creation time; the gate picked an unrelated one
# from three weeks earlier and reported it as missing a VERIFY_VERDICT line — an error
# naming a file the agent had never heard of, which reads as "my artifact wasn't generated".
#
# CHECK 5 already anchors on the staged diff hash. CHECK 6 must do the same.
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

sha() { if command -v sha256sum >/dev/null 2>&1; then sha256sum | cut -d' ' -f1; else shasum -a 256 | cut -d' ' -f1; fi; }

# A repo on a high-risk path so CHECK 6 actually runs, with several verify docs whose
# mtimes are all identical — the worktree situation.
setup() {
  REPO=$(mktemp -d); cd "$REPO" || exit 1
  git init -q; git config user.email t@t.com; git config user.name T
  mkdir -p migration .agent/verify .agent/reviews
  echo init > migration/001.sql; git add -A; git commit -q -m init
  # AGENT_MODE=1 is required (gate:8 exits 0 for humans), and the change must exceed the
  # trivial-change exemption at gate:29 (<=15 diff lines AND <=2 files pass straight
  # through) — otherwise the gate exits 0 without running CHECK 6 at all and every
  # assertion below passes vacuously. That is exactly how the first version of this test
  # went green before the fix existed.
  export AGENT_MODE=1
  for i in $(seq 1 25); do echo "ALTER TABLE t$i ADD c INT;" >> migration/002.sql; done
  echo "-- extra" > migration/003.sql
  git add migration/002.sql migration/003.sql
  CUR_HASH=$(git diff --cached -- ':!.agent/verify' | sha)

  # Decoys: no VERIFY_VERDICT line at all, so picking one produces a nameable error.
  for n in 2026-08-01-unrelated-a 2026-08-02-unrelated-b 2026-08-03-unrelated-c; do
    printf 'some old verify notes, no verdict line here\n' > ".agent/verify/${n}.md"
    printf '{"capability":"EVIDENCE_ONLY","channel":"pi","staged_diff_hash":"deadbeef"}\n' \
      > ".agent/verify/${n}.dispatch.json"
  done
  # The real one: verdict present AND dispatch bound to the CURRENT staged diff.
  printf 'VERIFY_VERDICT: PASS\nchecked the migration\n' > .agent/verify/2026-08-24-real.md
  printf '{"capability":"FULL","channel":"pi","staged_diff_hash":"%s"}\n' "$CUR_HASH" \
    > .agent/verify/2026-08-24-real.dispatch.json

  # Stamp every doc with the SAME mtime, exactly as `git worktree add` does.
  touch .agent/verify/*.md .agent/verify/*.dispatch.json
}
teardown() { cd /; [[ -n "${REPO:-}" && -d "$REPO" ]] && rm -rf "$REPO"; }

echo "=== CHECK 6 verify selection tests ==="
echo

echo "V0: 前置——确认 CHECK 6 真的运行了（否则下面全是平凡通过）"
(
  setup
  out=$(SKIP_REVIEW=1 bash "$GATE" 2>&1 || true)
  [[ -n "$out" ]] && r=true || r=false
  assert "gate 有输出（不是直接 exit 0）" "$r"
  # ⚠️ 不能断言「输出里有 verify 字样」——CHECK 6 通过时是完全静默的，而这个用例的
  # fixture 恰好有一份锚定命中的产物，于是它就该静默通过。可靠的前置信号是「没有走
  # 那两条早退路径」：AGENT_MODE 未设（gate:8）、或 trivial 豁免（gate:29）。
  [[ "$out" != *"trivial change skipped"* ]] && r=true || r=false
  assert "未被 trivial 豁免（说明真的进入了检查阶段）" "$r"
  teardown
)

echo "V1: mtime 全同时，按 staged_diff_hash 选中真正对应的那份"
(
  setup
  out=$(SKIP_REVIEW=1 bash "$GATE" 2>&1 || true)
  # 选错会报 "missing VERIFY_VERDICT" 并指名那个 decoy
  [[ "$out" == *"unrelated-a"* || "$out" == *"unrelated-b"* || "$out" == *"unrelated-c"* ]] && r=false || r=true
  assert "未选中无关的 decoy 文件" "$r"
  [[ "$out" == *"missing VERIFY_VERDICT"* ]] && r=false || r=true
  assert "未报 missing VERIFY_VERDICT" "$r"
  teardown
)

echo "V2: 无锚点匹配时回落 mtime（向后兼容，不能因为找不到锚点就拒绝）"
(
  setup
  # 把真实那份的 hash 改掉,使没有任何 dispatch 命中当前 staged
  printf '{"capability":"FULL","channel":"pi","staged_diff_hash":"nomatch"}\n' \
    > .agent/verify/2026-08-24-real.dispatch.json
  touch .agent/verify/2026-08-24-real.dispatch.json
  # ⚠️ 这个用例与 V1 相反：V1 要「mtime 全同」，V2 要「real 那份严格更新」，否则
  # 回落 mtime 就没有可选的最新项。sleep 1 是为了跨过秒级粒度——同一秒内 touch
  # 出来的 mtime 相同，会把这条测成 V1 的场景。
  sleep 1
  touch .agent/verify/2026-08-24-real.md
  out=$(SKIP_REVIEW=1 bash "$GATE" 2>&1 || true)
  [[ "$out" == *"missing VERIFY_VERDICT"* ]] && r=false || r=true
  assert "回落 mtime 仍选中有 verdict 的那份" "$r"
  teardown
)

echo
read -r P F < "$RESULTS_FILE"
echo "=== PASS=$P FAIL=$F ==="
rm -f "$RESULTS_FILE"
[[ "$F" -eq 0 ]]
