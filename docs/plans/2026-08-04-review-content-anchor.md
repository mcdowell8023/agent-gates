# Review Evidence Content Anchor Implementation Plan

<!-- PLAN_REVIEW: L2 -->
<!-- PLAN_REVIEW_TOOL: opencode/oc-review -->
<!-- PLAN_REVIEW_MODEL: github-copilot/gemini-3.1-pro-preview -->

> **For Codex:** Execute this plan directly with strict RED → GREEN → REFACTOR. Do not delegate implementation.

**Goal:** Replace review-evidence mtime freshness with staged-content anchors while blocking unreviewed files and warning on post-review byte changes.

**Architecture:** `agent-gates-review` snapshots `HEAD`, the staged file manifest, and an evidence-excluded binary diff before and after review, then appends machine-readable markers only when both snapshots match. The pre-commit gate scans anchored records for coverage, blocks `HEAD` or file-set mismatches, warns on diff mismatch, and uses evidence-based legacy compatibility only if two installed-hook repositories prove it necessary.

**Tech Stack:** Bash, Git plumbing/diff, SHA-256 (`sha256sum` or `shasum`), shell fixture tests.

---

### Task 1: Capture the historical worktree false-pass

**Files:**
- Read: `hooks/git/agent-quality-gate.sh`
- Evidence only: `/private/tmp/agent-gates-mtime-before.log`

**Step 1:** Create an isolated Git fixture with a committed historical PASS review and corresponding plan/verifier artifacts.

**Step 2:** Set the source review mtime old, add a new worktree, and confirm checkout refreshes the review mtime.

**Step 3:** Stage a substantial TypeScript-plus-test change unrelated to the historical review and run the unmodified gate.

**Step 4:** Save the actual command output showing the old gate passes or selects the checkout-refreshed legacy review.

### Task 2: RED — review command emits stable anchors only

**Files:**
- Modify: `tests/run_review_cmd.sh`
- Later modify: `bin/agent-gates-review`

**Step 1:** Add tests asserting a successful staged review result includes `REVIEW_HEAD`, one `REVIEW_FILE` marker per staged file, `REVIEW_FILES_SHA256`, and `REVIEW_DIFF_SHA256`.

**Step 2:** Add a fake reviewer mode that changes the staged patch during review; assert the command exits non-zero and does not emit usable anchored evidence.

**Step 3:** Run `bash tests/run_review_cmd.sh` and record the expected failures caused by missing anchors/change detection.

**Step 4:** Implement portable snapshot helpers and append anchors to every successful review route.

**Step 5:** Re-run `bash tests/run_review_cmd.sh`; require zero failures.

### Task 3: RED — gate enforces file coverage and warns on bytes

**Files:**
- Modify: `tests/run_gate.sh`
- Later modify: `hooks/git/agent-quality-gate.sh`

**Step 1:** Replace the mtime-selection regression with anchored scenarios covering exact match, `HEAD` mismatch, staged-file superset, diff mismatch, and negative-verdict precedence.

**Step 2:** Add a worktree regression proving checkout-refreshed legacy review mtime does not authorize unrelated staged files.

**Step 3:** Run `bash tests/run_gate.sh` and record the expected failures under the old implementation.

**Step 4:** Implement anchor parsing and portable current-snapshot calculation. Remove all review selection/post-review logic based on `find -mmin` or `stat`.

**Step 5:** Enforce:
- `HEAD` mismatch → BLOCK;
- current staged reviewable file set not a subset of declared files → BLOCK;
- covered file set with diff mismatch → WARN plus `git diff --cached --stat` and allow;
- any applicable negative verdict → BLOCK;
- exact anchored PASS → allow.

**Step 6:** Re-run `bash tests/run_gate.sh`; require zero failures.

### Task 4: Document and run the full agent-gates suite

**Files:**
- Modify: `docs/plans/2026-08-04-review-content-anchor-design.md`
- Modify: `CHANGELOG.md`

**Step 1:** Record the actual legacy outcome and selected grace policy in the design document.

**Step 2:** Add a changelog entry describing marker format, two-level matching, migration behavior, and removal of review mtime.

**Step 3:** Run `bash tests/run.sh`, `git diff --check`, and shell syntax checks for modified scripts.

### Task 5: Commit-level acceptance fixtures

**Files:**
- Disposable Git worktrees/fixtures only; no delivered business-source edits.
- Evidence logs under `/private/tmp/` until copied into report 221.

**Step 1:** Positive: existing `.ts` plus corresponding test, `AGENT_MODE=1 git commit` succeeds; record log count before/after.

**Step 2:** Negative: new `.ts` without test is blocked; record identical log counts.

**Step 3:** File coverage: add an unreviewed staged `.ts` with a test after anchoring; commit is blocked and log count stays unchanged.

**Step 4:** Byte warning: modify a covered `.ts` after anchoring; hook prints warning/diff summary, commit succeeds, and log count increases by one.

**Step 5:** New worktree: run the repaired gate against old review files and record that they are not treated as relevant despite fresh checkout mtime.

### Task 6: Real legacy compatibility in installed-hook repositories

**Files:**
- Disposable worktrees based on `crm-center` and `msg-management-center`; restore/remove all test-only commits after evidence capture.
- Do not modify `crm-platform/bridge/src/**`.

**Step 1:** In each repository, modify an existing `.ts` and its corresponding existing test in a disposable worktree.

**Step 2:** Point the shim to the repaired authority gate and run `AGENT_MODE=1 git commit` without `--no-verify`.

**Step 3:** If both pass, keep legacy records historical-only and document why no N-day relaxation is needed.

**Step 4:** If either blocks only due to legacy format, add a TDD-covered bounded filename/content correlation grace, choose `N` from observed repository cadence, warn on every use, and rerun both commits.

### Task 7: Cross-review and local agent-gates commit

**Files:**
- Create: `.agent/reviews/2026-08-04-review-content-anchor.md`
- Create/update verifier evidence only if the local gate requires it.

**Step 1:** Use a read-only heterogeneous CLI model to review the uncommitted implementation; do not delegate edits.

**Step 2:** Fix supported findings and re-run targeted plus full tests.

**Step 3:** Save explicit `VERDICT: PASS` evidence with model/tool markers and current content anchors.

**Step 4:** Commit locally with `AGENT_MODE=1`; do not push.

### Task 8: Install crm-platform hooks only after Task 7 passes

**Files:**
- Create: `crm-platform` worktree `.githooks/pre-commit`
- Create: `crm-platform` worktree `.githooks/agent-quality-gate.sh`

**Step 1:** Create a worktree branch based on the current local `test` commit; do not checkout the main repo.

**Step 2:** Copy the two tracked blob-identical files from `crm-center/.githooks/` and preserve mode `100755`.

**Step 3:** Verify only `.githooks/` changed, both blobs match `190a65d2`, and no CI/Jenkins file changed.

**Step 4:** Commit locally with `AGENT_MODE=1`, then fast-forward the main repo's current `test` branch locally. Do not push.

### Task 9: Report and final verification

**Files:**
- Create: `/Users/mcdowell/wb/docs/CRM/221-agent-gates-mtime修复与补装.md`

**Step 1:** Include exact commands and actual output for old/new mtime behavior, positive commit, no-test block with zero commits, file-set block with zero commits, byte WARN with successful commit, and both real legacy repository commits.

**Step 2:** Include chosen scheme, migration decision, local branches/commits, file modes, scope checks, and the fact that no push/PR/CI/business-source changes occurred.

**Step 3:** Run a separate read-only heterogeneous documentation review, fix supported findings, and re-check for secrets/tokens.

**Step 4:** Run final fresh tests/status/log checks and persist workspace memory before reporting completion.
