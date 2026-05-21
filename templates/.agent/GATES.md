# Quality Gates Checklist

## Pre-Commit (Automated — agent-quality-gate.sh v1.3)

- [ ] Gate 1: Every source file has corresponding test file
- [ ] Gate 2: Cross-review evidence present (when threshold met)
  - Trigger: `(LOGIC_FILES > 1 AND DIFF > 50) OR MAX_SINGLE_FILE > 150`
  - Evidence: `.agent/reviews/*.md` within 4h, ending with `VERDICT: PASS`

## Pre-Merge (Manual — agent-review-protocol)

- [ ] Three-Agent Review completed (if scope warrants)
- [ ] All review findings addressed or deferred with justification
- [ ] PROGRESS.md updated with session summary

## Session End (Memory Persistence — 红线 #12)

- [ ] Key decisions saved to Memory skill
- [ ] PROGRESS.md updated with today's work
- [ ] Blockers documented if any
