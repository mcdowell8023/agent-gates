# Review Evidence Content Anchor Design

## Problem

The pre-commit gate currently uses filesystem mtime to select review evidence and to estimate post-review edits. `git worktree add` assigns checkout-time mtimes to every file, so historical review records can appear fresh and authorize unrelated staged changes.

The gate must decide whether review evidence covers the staged change without using filesystem time.

## Decision

Use content anchors (option A), not Git commit time.

`agent-gates-review` captures the following data before invoking a reviewer:

- `REVIEW_HEAD`: the reviewed repository `HEAD` SHA.
- `REVIEW_FILES`: the staged file set presented for review.
- `REVIEW_FILES_SHA256`: a stable digest of that file set.
- `REVIEW_DIFF_SHA256`: a digest of the staged binary diff, excluding review/plan/verifier evidence files.

It recalculates the snapshot after the reviewer returns. If `HEAD`, the file set, or the diff changed during review, the command refuses to emit usable review evidence. This prevents a review result from being attached to content the reviewer did not see.

Option B (`git log` time) is rejected because it only avoids checkout mtime changes. It cannot prove that a review covers the current staged files.

## Gate Matching Levels

The gate never reads mtime for cross-review freshness.

1. `HEAD` mismatch: block. The staged patch is based on a different repository state than the reviewed patch.
2. File-set mismatch: block only when the current staged code-file set is not a subset of the review-declared file set. An unreviewed file must never enter the commit.
3. Diff digest mismatch with a valid file-set subset: warn, print a compact staged diff summary, request explicit human confirmation, and allow the commit. This covers comments, typo fixes, formatting, and other visible post-review edits without forcing another model review.
4. Exact digest match: pass silently.

The explicit confirmation is the user's decision to continue the interactive `git commit` after reading the warning; the hook does not add a bypass environment variable and does not weaken the unreviewed-file block.

If multiple anchored reviews cover the same staged set, any matching `ISSUES`/`FAIL` verdict blocks. A matching `PASS` is accepted only when there is no matching negative verdict.

## Legacy Review Migration

Existing review files have no anchor fields. They remain valid historical records and are never backfilled with invented anchors.

Before selecting a grace policy, the repaired gate must be exercised against real staged TypeScript-plus-test commits in both currently hooked repositories:

- `crm-center`
- `msg-management-center`

If their normal commit path succeeds without relying on legacy evidence, no time-based grace is added. If either repository blocks only because its review is legacy, add a bounded transition:

- accept a legacy review for `N` days only when its filename or content mentions at least one staged source file;
- print a migration warning identifying the legacy file and expiry;
- never use filesystem mtime;
- document the chosen `N` and evidence-based reason.

The transition must not treat all historical review files as fresh merely because a worktree was created.

### Migration decision (2026-08-04)

No time-based legacy grace is added. The repaired authority gate was used for a real commit in a detached worktree of each installed-hook repository. Each commit modified one existing TypeScript source file and its corresponding existing test; both followed the existing trivial-change path and succeeded (`crm-center` log count `146 → 147`, `msg-management-center` `269 → 270`). Therefore the next normal small commit is not blocked merely because the repositories contain legacy reviews.

For non-trivial changes, legacy files remain historical-only and a new anchored review is required. This is intentional: filename/content correlation would still let an old verdict authorize new semantics, while the real compatibility test showed no operational need for that relaxation.

## Verification

- TDD regression: a historical PASS review becomes fresh by worktree checkout under the old gate but cannot cover unrelated staged files under the repaired gate.
- Positive commit: `AGENT_MODE=1`, existing `.ts` change plus corresponding test, commit succeeds.
- File-level negative: unreviewed new `.ts` without a corresponding test is blocked and `git log` count is unchanged.
- File-anchor negative: an additional staged file outside `REVIEW_FILES` is blocked and `git log` count is unchanged.
- Byte-level warning: an already covered file changes after review; the hook warns and the commit succeeds, with `git log` count increasing by one.
- Real legacy compatibility: the two installed-hook repositories each complete an existing `.ts` plus test commit under the repaired authority gate, or produce evidence that a bounded grace policy is required.

No validation uses `--no-verify`, no remote push or PR is performed, and CRM business source is not changed by the delivered commits.
