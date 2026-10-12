# 补上 merge 的钩子点

## 背景

git 对 merge commit 走 `pre-merge-commit`，不是 `pre-commit`，而 agent-gates 从来只装
`pre-commit`。所以干净的非 ff merge 完全不受门禁检查 —— 而 `merge-only` 档整套设计
正是把审查推迟到「合并进集成分支」那一刻，于是它推迟到了一个不存在的检查点。

## 验收标准

- 新增 `.githooks/pre-merge-commit`（复用 gate-shim），使干净的非 ff merge 也经过门禁
- `init-project-gates` 的 lefthook / husky / bare git 三种安装模式都改成装两个钩子，且 husky 那份能真正执行
- 文档写明 ff merge 仍无钩子点须用 `--no-ff`，且钩子必须可执行
- 测试中有一条用例刻意删掉钩子来证明空洞真实存在

## 已知局限

fast-forward merge 不产生 commit，没有钩子点。可配 `merge.ff=false`，但显式 `--ff-only`
仍能压过（实测）。完整解法是 `pre-push` 门禁，本次不做。
