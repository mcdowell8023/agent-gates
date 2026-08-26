#!/usr/bin/env bash
# CHECK 6: when verify docs CAN be anchored but none matches the current staged diff, that
# means "no verify exists for this change" — NOT "fall back to whichever is newest".
#
# Reported 2026-08-26 from a fresh crm-center worktree: 28 verify docs, mtimes ALL identical
# (the checkout instant), 23 of them carrying a dispatch.json, and ZERO anchoring to the
# staged diff. The mtime fallback then picked one at random (find order) — an unrelated
# task's old PASS — and compared line counts against it, producing:
#     ❌ Significant changes (115 lines) made AFTER verification — re-verify required
# which points the reader at "I changed too much" when the truth is "it grabbed a document
# that has nothing to do with this change".
#
# The earlier fix (c644cb4) made anchored selection win, but left the no-match case falling
# back to mtime. Two different situations were conflated:
#   - dispatch.json present, none matches  -> decidable: there is no verify for this diff
#   - no dispatch.json anywhere (legacy)   -> undecidable: mtime fallback is all we have
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

# high-risk path + change big enough to clear gate:29's trivial exemption, so CHECK 6 runs.
setup() {
  REPO=$(mktemp -d); cd "$REPO" || exit 1
  git init -q; git config user.email t@t.com; git config user.name T
  mkdir -p migration .agent/verify .agent/reviews
  echo init > migration/001.sql; git add -A; git commit -q -m init
  export AGENT_MODE=1
  for i in $(seq 1 25); do echo "ALTER TABLE t$i ADD c INT;" >> migration/002.sql; done
  echo "-- second file" > migration/003.sql
  git add migration/002.sql migration/003.sql
}
teardown() { cd /; [[ -n "${REPO:-}" && -d "$REPO" ]] && rm -rf "$REPO"; }

# N unrelated docs: PASS verdicts, dispatch.json present, hashes deliberately NOT ours,
# all sharing one mtime — the fresh-worktree shape.
seed_unrelated() {
  local n="${1:-5}" i
  for i in $(seq 1 "$n"); do
    printf 'VERIFY_VERDICT: PASS\nunrelated task %s\n' "$i" > ".agent/verify/2026-08-0$((i%9))-other-$i.md"
    printf '{"capability":"FULL","channel":"pi","staged_diff_hash":"beef%02d"}\n' "$i" \
      > ".agent/verify/2026-08-0$((i%9))-other-$i.dispatch.json"
  done
  touch -t 202608261358.57 .agent/verify/*
}

echo "=== CHECK 6 no-anchor semantics ==="
echo

echo "N1: ⭐ 有 dispatch.json 但零匹配 → 报「无对应 verify」，不得报「改动超限」"
(
  setup; seed_unrelated 5
  out=$(SKIP_REVIEW=1 bash "$GATE" 2>&1 || true)
  [[ "$out" == *"made AFTER verification"* ]] && r=false || r=true
  assert "不再报 'made AFTER verification'（那是误导）" "$r"
  [[ "$out" == *"No verifier evidence"* || "$out" == *"no verify"* || "$out" == *"does not match"* || "$out" == *"not anchored"* ]] && r=true || r=false
  assert "报错说明是「没有对应当前改动的 verify」" "$r"
  teardown
)

echo "N2: 报错里要说清诊断信息（份数 / 是否 mtime 全同）"
(
  setup; seed_unrelated 5
  out=$(SKIP_REVIEW=1 bash "$GATE" 2>&1 || true)
  [[ "$out" == *"5"* ]] && r=true || r=false
  assert "提到候选文档份数" "$r"
  teardown
)

echo "N3: 有一份锚定匹配时正常通过（不能因为收紧而拒掉合法的）"
(
  setup
  seed_unrelated 5
  CUR=$(git diff --cached -- ':!.agent/verify' | sha)
  printf 'VERIFY_VERDICT: PASS\nreal one\n' > .agent/verify/2026-08-26-real.md
  printf '{"capability":"FULL","channel":"pi","staged_diff_hash":"%s"}\n' "$CUR" \
    > .agent/verify/2026-08-26-real.dispatch.json
  touch -t 202608261358.57 .agent/verify/*
  out=$(SKIP_REVIEW=1 bash "$GATE" 2>&1 || true)
  [[ "$out" == *"No verifier evidence"* || "$out" == *"made AFTER verification"* ]] && r=false || r=true
  assert "锚定命中时不报错" "$r"
  teardown
)

echo "N4: 纯旧格式（无 dispatch.json）仍回落 mtime（向后兼容）"
(
  setup
  printf 'VERIFY_VERDICT: PASS\nlegacy doc\n' > .agent/verify/2026-08-26-legacy.md
  touch -t 202608261358.57 .agent/verify/*.md
  out=$(SKIP_REVIEW=1 bash "$GATE" 2>&1 || true)
  [[ "$out" == *"No verifier evidence"* ]] && r=false || r=true
  assert "旧格式不被新规则拒掉" "$r"
  teardown
)

echo
read -r P F < "$RESULTS_FILE"
echo "=== PASS=$P FAIL=$F ==="
rm -f "$RESULTS_FILE"
[[ "$F" -eq 0 ]]
