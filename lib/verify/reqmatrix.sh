#!/usr/bin/env bash
# Requirement matrix — CHECK 6's omission detector.
#
# WHY: a missing feature leaves no trace in the diff. CHECK 5 reads the diff, sees only
# correct code, and passes. Tests are no better: the implementer did not build the thing,
# so it did not write the test either — "all green" and "half the requirement missing"
# coexist. Every checklist derived FROM CODE (diff, tests, coverage) is structurally blind
# to omission. The only one that works is derived from the REQUIREMENT.
#
# SCOPE — this library enforces FORM, never substance:
#   E1 item count comes from the requirement source, not from the model
#   E2 the extracted item block is hashed, so items cannot be edited after the fact
#   E3 a citation without `~` must land inside this change; with `~` it must exist in tree
#   E4 the verdict is derived from the items, not read from the model's own line
#   E6 evidence is surface-tagged, so "backend written, frontend never" cannot hide
#
# "Does this evidence actually complete this requirement" is a semantic judgment shell
# cannot make. That stays with the heterogeneous verifier. What this buys is that the
# verifier cannot silently skip an item — every requirement must carry a disposition.

# Requirement-source section headings that hold acceptance items.
_REQMATRIX_HEADINGS='验收标准|验收清单|验收条件|Acceptance|Acceptance Criteria|验收'

# Statuses. Order matters only for the severity mapping in _reqmatrix_rank.
_REQMATRIX_STATUSES='COVERED|PREEXISTING|PARTIAL|DEFERRED|NA|MISSING'

# Surfaces that carry a repo path (checked by E3) vs ones exempt from path resolution.
_REQMATRIX_PATH_SURFACES='ui|api|db|job|cfg'
_REQMATRIX_FREE_SURFACES='RUN|EXT|NO_UI'

# ---------------------------------------------------------------------------
# E1 — extract requirement items from the source. Tool-side, deterministic.
#
# Two accepted shapes, both of which people already write. v1 of this design invented
# `<!-- REQ:BEGIN -->` markers and was rejected on review with an argument that holds:
# mandate it and nobody writes it, make it optional and the check degrades to a warning
# forever, i.e. decoration. So: a named section, or Gherkin.
#
# ⛔ Deliberately NOT counting `- [ ]` checkboxes across the whole document. Those are
# implementation tasks, not requirements; counting them produces noise, and a gate that
# fails for noise is a gate people route around.
#
# exit 3 = no parseable acceptance items (tier "none"). Caller decides what that means;
# this function refuses to guess.
# ---------------------------------------------------------------------------
reqmatrix_extract_items() {
  local src="$1"
  [[ -f "$src" ]] || return 2
  python3 -c '
import re, sys
src = sys.argv[1]
headings = sys.argv[2]
try:
    lines = open(src, encoding="utf-8", errors="replace").read().replace("\r\n", "\n").split("\n")
except Exception:
    sys.exit(2)

items = []
if src.endswith(".feature"):
    for ln in lines:
        m = re.match(r"^\s*(?:Scenario|Scenario Outline|场景|场景大纲)\s*:\s*(.+?)\s*$", ln)
        if m:
            items.append(m.group(1))
else:
    # A trailing qualifier is allowed: `## 验收标准（MVP）`, `## Acceptance Criteria:`,
    # `## 验收清单——最小集` are all how people actually write it, and rejecting them dropped
    # the doc to the `bad-source` tier — a hard failure on a strict branch over punctuation.
    # The qualifier must START with a bracket / colon / dash, so `## 验收标准之外的说明` is
    # still NOT an acceptance section: widening to `.*` would swallow neighbouring sections
    # and throw the item count off, which is worse than the friction.
    hre = re.compile(r"^(#{2,6})\s*(?:" + headings + r")\s*(?:[（(\[:：\-—–].*)?$")
    depth = None
    inside = False
    for ln in lines:
        if not inside:
            m = hre.match(ln.strip())
            if m:
                inside = True
                depth = len(m.group(1))
            continue
        # Any heading at the same or shallower depth ends the section.
        hm = re.match(r"^(#{1,6})\s+", ln)
        if hm and len(hm.group(1)) <= depth:
            break
        # Top-level list items only: no leading whitespace. Nested sub-bullets are
        # detail of the item above them, not separate requirements.
        m = re.match(r"^(?:[-*+]|\d+[.)])\s+(.*\S)\s*$", ln)
        if m:
            txt = m.group(1)
            txt = re.sub(r"^\[[ xX]\]\s*", "", txt)   # tolerate a checkbox marker
            if txt:
                items.append(txt)

if not items:
    sys.exit(3)
for it in items:
    print(it)
' "$src" "$_REQMATRIX_HEADINGS"
}

# ---------------------------------------------------------------------------
# E2 — hash the extracted item block, NOT the whole document.
#
# Hashing the file punished a typo fix in unrelated prose (flagged on review). Hashing
# the items is what actually needs pinning: shrinking or rewording a requirement after
# the matrix was produced must invalidate it.
# Normalisation: strip trailing whitespace per line, CRLF already handled upstream.
# ---------------------------------------------------------------------------
reqmatrix_block_hash() {
  local src="$1" body
  body=$(reqmatrix_extract_items "$src") || return $?
  printf '%s\n' "$body" \
    | sed -e 's/[[:space:]]*$//' \
    | { command -v sha256sum >/dev/null 2>&1 && sha256sum || shasum -a 256; } \
    | awk '{print $1}'
}

# ---------------------------------------------------------------------------
# Parse the matrix. Output: <n>|<status>|<evidence>|<note>
#
# fail-closed: unknown status, duplicate numbers, or non-contiguous 1..N all reject.
# A matrix whose numbering does not line up 1..N cannot be checked against a count, and
# "cannot be checked" must never read as "checked and fine".
# ---------------------------------------------------------------------------
reqmatrix_parse() {
  local vf="$1"
  [[ -f "$vf" ]] || return 2
  python3 -c '
import re, sys
vf, statuses = sys.argv[1], sys.argv[2].split("|")
rows, errs, seen = [], [], set()
for ln in open(vf, encoding="utf-8", errors="replace"):
    ln = ln.rstrip("\n").rstrip("\r")
    if not re.match(r"^REQ_ITEM:", ln):
        continue
    body = ln.split(":", 1)[1]
    parts = body.split("|")
    if len(parts) < 3:
        errs.append("malformed REQ_ITEM line (需要 编号|状态|证据|说明): " + ln.strip())
        continue
    num = parts[0].strip()
    status = parts[1].strip().upper()
    evidence = parts[2].strip()
    note = parts[3].strip() if len(parts) > 3 else ""
    if len(parts) > 4:
        note = "|".join(p.strip() for p in parts[3:])
    if not num.isdigit():
        errs.append("REQ_ITEM 编号不是数字: " + num)
        continue
    n = int(num)
    if status not in statuses:
        errs.append("未知状态 " + status + " (允许: " + ", ".join(statuses) + ")")
        continue
    if n in seen:
        errs.append("REQ_ITEM 编号重复: " + str(n))
        continue
    seen.add(n)
    rows.append((n, status, evidence, note))

if errs:
    for e in errs:
        print("ERROR: " + e, file=sys.stderr)
    sys.exit(4)
if not rows:
    print("ERROR: 文件里没有 REQ_ITEM 行", file=sys.stderr)
    sys.exit(3)
nums = sorted(r[0] for r in rows)
if nums != list(range(1, len(nums) + 1)):
    print("ERROR: REQ_ITEM 编号必须是 1..N 连续，实际: " + ",".join(map(str, nums)), file=sys.stderr)
    sys.exit(5)
for r in sorted(rows):
    print("%d|%s|%s|%s" % r)
' "$vf" "$_REQMATRIX_STATUSES"
}

# ---------------------------------------------------------------------------
# E4 — derive the verdict from the items. compute, don't accept.
# ---------------------------------------------------------------------------
reqmatrix_derive_verdict() {
  local vf="$1" rows
  rows=$(reqmatrix_parse "$vf") || return $?
  if grep -q '|MISSING|' <<<"$rows"; then echo FAIL; return 0; fi
  if grep -q '|PARTIAL|' <<<"$rows"; then echo QUESTIONS; return 0; fi
  echo PASS
}

# NOTE: `tr`, not ${v^^} — macOS ships bash 3.2 and ${v^^} is a runtime "bad
# substitution" there. It failed in the worst possible direction: both ranks came back
# empty, `[[ "" -ge "" ]]` compared as 0 >= 0 and was TRUE, so the model's generous
# verdict was kept — exactly what E4 exists to prevent.
_reqmatrix_rank() {
  case "$(printf '%s' "${1:-}" | tr '[:lower:]' '[:upper:]')" in
    FAIL) echo 3 ;;
    QUESTIONS|INCOMPLETE) echo 2 ;;
    PASS) echo 0 ;;
    *) echo 1 ;;   # unknown is worse than PASS, better than an explicit problem
  esac
}

# Reconcile the model's declared verdict with the derived one and keep the STRICTER.
# Derived wins when the model is more generous (that is the anti-fabrication direction);
# the model's own verdict stands when it is harsher — nobody's conclusion gets relaxed
# by a mechanical step.
reqmatrix_reconcile_verdict() {
  local vf="$1" declared derived rd rv
  derived=$(reqmatrix_derive_verdict "$vf") || return $?
  # `|| true` is load-bearing: under the caller's `set -euo pipefail`, a grep that finds
  # nothing returns 1, pipefail promotes it, and the assignment itself exits the shell —
  # so the "no declared verdict, fall back to derived" branch below was unreachable.
  declared=$(grep -oiE '^VERIFY_VERDICT:[[:space:]]*(PASS|FAIL|QUESTIONS|INCOMPLETE)' "$vf" 2>/dev/null \
    | grep -oiE 'PASS|FAIL|QUESTIONS|INCOMPLETE' | head -1 | tr '[:lower:]' '[:upper:]' || true)
  [[ -z "$declared" ]] && { echo "$derived"; return 0; }
  rd=$(_reqmatrix_rank "$declared"); rv=$(_reqmatrix_rank "$derived")
  # Bias strict if either rank came back empty: an unreadable rank must never resolve
  # into "keep the more favourable verdict".
  if [[ "${rd:-9}" -ge "${rv:-0}" ]]; then echo "$declared"; else echo "$derived"; fi
}

# ---------------------------------------------------------------------------
# E1 reconciliation — the count check. This is the core mechanism: the model fills in a
# disposition per item but has no say in HOW MANY items there are.
# ---------------------------------------------------------------------------
reqmatrix_check_count() {
  local vf="$1" src="$2" want got rows
  want=$(reqmatrix_extract_items "$src" | wc -l | tr -d ' ') || return $?
  rows=$(reqmatrix_parse "$vf") || return $?
  got=$(printf '%s\n' "$rows" | grep -c '^[0-9]' || true)
  if [[ "$want" != "$got" ]]; then
    echo "需求源有 $want 条验收条目，矩阵只写了 $got 条" >&2
    if [[ "$got" -lt "$want" ]]; then
      local missing=""
      for ((i = got + 1; i <= want; i++)); do missing="$missing $i"; done
      echo "缺少编号:$missing" >&2
      echo "对应需求:" >&2
      reqmatrix_extract_items "$src" | sed -n "$((got + 1)),${want}p" | sed 's/^/   - /' >&2
    fi
    return 6
  fi
  return 0
}

# ---------------------------------------------------------------------------
# E3 — citations must land inside this change.
#
# v1 only required "the file exists", which review demolished: a model that skipped the
# frontend can cite package.json and pass. So a citation without `~` must appear in the
# staged diff (A/M/D — a deletion counts, otherwise "delete the legacy exporter" would
# false-fail). `~` marks pre-existing-and-untouched and only needs to resolve in the tree:
# without it, "the button already existed, this change adds the API" — an ordinary
# increment — could not be expressed at all.
# ---------------------------------------------------------------------------
reqmatrix_check_citations() {
  local vf="$1" rows
  rows=$(reqmatrix_parse "$vf") || return $?
  # Lists via env, not argv: a large repo's staged list can approach ARG_MAX.
  # --no-renames on purpose: with rename detection, `--name-only` reports ONLY the
  # destination, so a requirement like "把 old.ts 挪走" citing the old path was a false
  # failure. Disabling detection makes a rename appear as delete(old) + add(new), and both
  # paths are genuinely "touched by this change". Verified against git, not assumed.
  _RM_STAGED=$(git diff --cached --name-only --diff-filter=ACMRD --no-renames 2>/dev/null || true) \
  _RM_DIRTY=$(git diff --name-only 2>/dev/null || true) \
  _RM_SURF_PATH="$_REQMATRIX_PATH_SURFACES" \
  _RM_SURF_FREE="$_REQMATRIX_FREE_SURFACES" \
  python3 -c '
import os, re, subprocess, sys

# Implemented in python rather than bash deliberately. Two of the three defects the first
# independent review found here were bash string handling:
#   `tr "," "\n"` is a blind character substitution, so a comma inside a free-form
#   EXT:/RUN: note ("EXT:JIRA-123, 已与 PM 确认") got split, the fragment lost its prefix,
#   fell into the path branch and produced a false failure — while the comment right above
#   it claimed those commas were tolerated. A comment that lies about the code is worse
#   than no comment.
#   And `ui: src/List.vue` (a space after the colon, which models write constantly) left a
#   leading blank on the path, so every existence and membership check missed.
# One regex split and one strip remove that entire class.

staged = set(l for l in os.environ.get("_RM_STAGED", "").split("\n") if l)
dirty  = set(l for l in os.environ.get("_RM_DIRTY",  "").split("\n") if l)
surf_path = os.environ.get("_RM_SURF_PATH", "")
surf_free = os.environ.get("_RM_SURF_FREE", "")

# Split only at a comma that introduces a recognised surface token. Anything else is prose
# belonging to the entry before it.
SPLIT = re.compile(r"\s*,\s*(?=(?:" + surf_path + "|" + surf_free + r")\s*:)")
FREE  = re.compile(r"^(?:" + surf_free + r")\s*:", re.I)
PATHS = re.compile(r"^(" + surf_path + r")\s*:\s*(.*)$", re.I)
LINENO = re.compile(r"(?::\d+)+$")

errs = []
rows = []
pre_claims = []     # (item, surface, path) claimed as pre-existing

for line in sys.stdin.read().split("\n"):
    if not line.strip():
        continue
    parts = line.split("|")
    if len(parts) < 3:
        continue
    n, status, evidence = parts[0], parts[1], parts[2]
    if status in ("MISSING", "DEFERRED", "NA"):
        continue    # nothing to cite, by definition

    entries = [e.strip() for e in SPLIT.split(evidence) if e.strip() and e.strip() != "-"]
    # An empty evidence column was the cheapest silent bypass of the lot: `COVERED | - |`
    # passed every check and printed COVERED=1, because "no citations" satisfies the
    # citation rules trivially. A claim of done with nothing to point at is not a claim.
    if not entries:
        errs.append("条目 %s: 状态是 %s 但没有任何证据 —— 声称做了却指不出东西" % (n, status))
        continue
    rows.append((n, status, entries))

for n, status, entries in rows:
    for entry in entries:
        if FREE.match(entry):
            continue                      # RUN: / EXT: / NO_UI: carry no repo path
        m = PATHS.match(entry)
        surface, rest = (m.group(1), m.group(2)) if m else ("", entry)
        rest = rest.strip()
        pre = rest.startswith("~")
        if pre:
            rest = rest[1:].strip()
        rest = LINENO.sub("", rest).strip()
        if not rest:
            # "ui:" with nothing after it still registered as ui evidence and silenced the
            # missing-entry-point warning. A surface with no path is not evidence.
            errs.append("条目 %s: 证据 %r 只有层面没有路径" % (n, entry))
            continue

        if pre or status == "PREEXISTING":
            pre_claims.append((n, surface, rest))
            continue

        if rest in staged:
            continue
        hint = (surface + ":") if surface else ""
        if rest in dirty:
            # Distinct from "not part of this change": the file WAS edited, it just was not
            # `git add`ed. Saying only the former sends people hunting the wrong bug.
            errs.append("条目 %s: %s 有改动但没有 git add —— 门禁只看已暂存内容" % (n, rest))
        elif os.path.exists(rest):
            errs.append("条目 %s: %s 存在但不在本次改动内 —— 本次未改动的既有代码请写成 %s~%s"
                        % (n, rest, hint, rest))
        else:
            errs.append("条目 %s: 证据路径不存在: %s" % (n, rest))

# Pre-existing claims are checked against git in ONE batch. os.path.exists() alone accepted
# files git has never seen, so `ui:~src/Whatever.vue` could be forged with a scratch file —
# and that is exactly the mixed-layer case the `~` form was added to express honestly.
if pre_claims:
    want = sorted({p for _, _, p in pre_claims})
    tracked = set()
    try:
        out = subprocess.run(["git", "ls-files", "-z", "--"] + want,
                             capture_output=True, text=True, timeout=30)
        tracked = set(x for x in out.stdout.split("\0") if x)
    except Exception:
        tracked = None      # git unavailable: fall back to existence, and say so
    for n, surface, path in pre_claims:
        if tracked is None:
            if not os.path.exists(path):
                errs.append("条目 %s: 既有证据路径不存在: %s" % (n, path))
        elif path not in tracked:
            if os.path.exists(path):
                errs.append("条目 %s: %s 在磁盘上存在但 git 从未跟踪它 —— 未纳入版本控制的文件"
                            "不能当作「既有代码」" % (n, path))
            else:
                errs.append("条目 %s: 既有证据路径不存在: %s" % (n, path))

for e in errs:
    print(e, file=sys.stderr)
sys.exit(7 if errs else 0)
' <<<"$rows"
}

# ---------------------------------------------------------------------------
# E6 + escape-hatch visibility.
#
# Every hatch (NA / DEFERRED / PREEXISTING / all-`~` evidence) can be used to cover an
# omission, and no mechanism can stop that without producing false failures. So they are
# counted and printed instead. The design goal is not "impossible to bypass" — it is
# "impossible to bypass silently".
# ---------------------------------------------------------------------------
reqmatrix_surface_report() {
  local vf="$1" rows
  rows=$(reqmatrix_parse "$vf") || return $?
  python3 -c '
import re, sys
rows = [l for l in sys.stdin.read().split("\n") if l.strip()]
counts = {}
total = 0
ui_seen = no_ui_declared = 0
nothing_touched = []
no_evidence = []
external_only = []
for line in rows:
    parts = line.split("|")
    if len(parts) < 3:
        continue
    n, status, evidence = parts[0], parts[1], parts[2]
    total += 1
    counts[status] = counts.get(status, 0) + 1
    # Same split and strip rules as reqmatrix_check_citations — if these two disagree, a
    # matrix passes the citation check and then gets reported as having no ui: evidence.
    SPLIT = re.compile(r"\s*,\s*(?=(?:ui|api|db|job|cfg|RUN|EXT|NO_UI)\s*:)")
    entries = [e.strip() for e in SPLIT.split(evidence) if e.strip() and e.strip() != "-"]
    touched = 0
    for e in entries:
        if re.match(r"^NO_UI\s*:", e):
            no_ui_declared += 1
            continue
        m = re.match(r"^(ui|api|db|job|cfg)\s*:\s*(.*)$", e, re.I)
        surface, rest = (m.group(1).lower(), m.group(2).strip()) if m else ("", e)
        if surface == "ui":
            ui_seen += 1
        if re.match(r"^(RUN|EXT)\s*:", e):
            # A run artifact or an out-of-repo change also answers "can the user get to it".
            # §4.6 calls a real run the STRONGER form of evidence, so demanding an in-repo
            # `ui:` on top of it contradicted the design and false-flagged items whose UI
            # lives in another repo or is only provable by an E2E result. They still land in
            # EXTERNAL_ONLY below, so nothing inside the repo backing them stays visible.
            ui_seen += 1
            touched += 1
            continue
        if not rest.startswith("~"):
            touched += 1
    if status in ("COVERED", "PARTIAL"):
        if not entries:
            # Reported, not silent. `COVERED | - |` used to print COVERED=1 and pass.
            no_evidence.append(n)
        elif touched == 0:
            nothing_touched.append(n)
        elif all(re.match(r"^(RUN|EXT)\s*:", e) for e in entries):
            # Allowed by design (4.6: a real run is the STRONGER form, and a non-code
            # requirement has no path to cite) — but nothing inside the repo backs it, so
            # it has to be visible.
            external_only.append(n)

for k in ("COVERED", "PREEXISTING", "PARTIAL", "DEFERRED", "NA", "MISSING"):
    print("%s=%d" % (k, counts.get(k, 0)))
print("TOTAL=%d" % total)
print("NO_UI_DECLARED=%d" % no_ui_declared)
print("UI_CITATIONS=%d" % ui_seen)
if ui_seen == 0 and no_ui_declared == 0:
    print("NO_UI_EVIDENCE")
if total and counts.get("PREEXISTING", 0) == total:
    print("ALL_PREEXISTING")
if nothing_touched:
    print("NOTHING_TOUCHED=" + ",".join(nothing_touched))
if no_evidence:
    print("NO_EVIDENCE=" + ",".join(no_evidence))
if external_only:
    print("EXTERNAL_ONLY=" + ",".join(external_only))
' <<<"$rows"
}
