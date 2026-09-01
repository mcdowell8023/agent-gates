#!/usr/bin/env bash
# hetero-check.json persistence — merge, never overwrite.
#
# THE BUG THIS FIXES (2026-09-01): doctor.sh built the entire file with a fixed heredoc and
# `mv`'d it into place. `implementer_family`, `pi_models` and `channels` appear ZERO times
# in doctor.sh, so every run silently dropped them.
#
# The loss itself is not the worst part. `channels.opencode.enabled=false` was set
# deliberately, because the opencode review channel was observed wedging agents for
# 120–200s per attempt; wiping it RE-ENABLES that channel. A maintenance command that
# quietly undoes a deliberate safety setting is worse than one that fails loudly — the
# setting looks present in everyone's mental model and is simply gone.
#
# Ownership rule: doctor owns the keys it writes. Everything else in the file belongs to
# whoever put it there and must survive.

# hetero_merge_check_json <target-file> <json-fragment>
#   Merges <json-fragment> into <target-file> one level deep (nested objects are merged
#   key-by-key, so writing review_models.primary does not drop review_models.panel_pool).
#   Atomic: writes a temp file in the same directory and renames.
#   exit 0 merged · 2 bad fragment · 3 target exists but is not parseable JSON
hetero_merge_check_json() {
  local target="$1" fragment="$2"
  [[ -n "$target" ]] || return 2
  python3 -c '
import json, os, sys, tempfile

target, fragment = sys.argv[1], sys.argv[2]

try:
    new = json.loads(fragment)
    if not isinstance(new, dict):
        raise ValueError("fragment is not an object")
except Exception as e:
    print("hetero_merge_check_json: 新片段不是合法 JSON 对象: %s" % e, file=sys.stderr)
    sys.exit(2)

cur = {}
if os.path.exists(target):
    try:
        with open(target, encoding="utf-8") as fh:
            cur = json.load(fh)
        if not isinstance(cur, dict):
            raise ValueError("existing file is not an object")
    except Exception as e:
        # Refuse rather than overwrite. A file that fails to parse is usually one somebody
        # hand-edited, and it still holds whatever they were trying to set. Clobbering it
        # loses that AND hides the mistake.
        print("hetero_merge_check_json: %s 存在但不是合法 JSON（%s）—— 拒绝覆盖，"
              "请先修好它或手工移走" % (target, e), file=sys.stderr)
        sys.exit(3)

for k, v in new.items():
    if isinstance(v, dict) and isinstance(cur.get(k), dict):
        merged = dict(cur[k])
        merged.update(v)
        cur[k] = merged
    else:
        cur[k] = v

d = os.path.dirname(os.path.abspath(target)) or "."
fd, tmp = tempfile.mkstemp(dir=d, prefix=".hetero-check.", suffix=".tmp")
try:
    with os.fdopen(fd, "w", encoding="utf-8") as fh:
        json.dump(cur, fh, ensure_ascii=False, indent=2)
        fh.write("\n")
    os.replace(tmp, target)
except Exception:
    try:
        os.unlink(tmp)
    except Exception:
        pass
    raise
' "$target" "$fragment"
}
