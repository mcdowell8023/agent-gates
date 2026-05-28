# Memory Skill — Upstream Notes

This skill is **forked from** [clawic/skills](https://github.com/clawic/skills) (MIT license), specifically the `skills/memory/` subdirectory.

## Why bundled

agent-gates v1.5.4 bundles the Memory skill directly (instead of sparse-cloning at install time) to:

1. **Remove network dependency** at install time — works offline, in CI, behind corporate firewalls
2. **Faster install** — no git clone, just `cp`
3. **Version-locked alignment** — agent-gates ships a known-good Memory skill version

## Attribution

- **Upstream**: <https://github.com/clawic/skills>
- **Original location**: `skills/memory/` in the upstream repo
- **License**: MIT (compatible with agent-gates MIT)
- **Original metadata** preserved in `SKILL.md` frontmatter:
  - `homepage: https://clawic.com/skills/memory`
  - `version: 1.0.2`
  - `slug: memory`

## Sync from upstream

To pull the latest Memory skill from clawic/skills:

```bash
cd /path/to/agent-gates  # repo root
tmp=$(mktemp -d)
git clone --depth 1 --filter=blob:none --no-checkout https://github.com/clawic/skills "$tmp/clawic"
(
  cd "$tmp/clawic" && \
  git sparse-checkout init --cone && \
  git sparse-checkout set skills/memory && \
  git checkout
)
# Backup current bundled version first
mv skills/memory skills/memory.bak.$(date +%Y%m%d)
mkdir -p skills/memory
cp -R "$tmp/clawic/skills/memory/." skills/memory/
# Re-add this UPSTREAM.md (it's agent-gates specific, not in clawic upstream)
git checkout skills/memory/UPSTREAM.md 2>/dev/null || true
rm -rf "$tmp"

# Diff against backup to review changes
diff -r skills/memory.bak.$(date +%Y%m%d) skills/memory
# Verify, then remove backup
rm -rf skills/memory.bak.*
```

## Local modifications

**None** — the bundled version is byte-identical to upstream `clawic/skills/skills/memory/` at fork time (except this `UPSTREAM.md` file, which is agent-gates specific).

If local modifications are needed in the future, mark them in this file's "Local modifications" section + note the rationale.

## Fork date

2026-05-28 (agent-gates v1.5.4 release)

## Verification (one-time at fork)

The 6 bundled files matched upstream byte-for-byte at fork date:

| File | Size |
|------|------|
| `SKILL.md` | 7.9K |
| `_meta.json` | 240B |
| `memory-template.md` | 5.0K |
| `patterns.md` | 3.5K |
| `setup.md` | 2.5K |
| `troubleshooting.md` | 4.4K |
