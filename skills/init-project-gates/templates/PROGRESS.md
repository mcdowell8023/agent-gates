# 开发进度跟踪 — {{PROJECT_NAME}}

> 供汇报 / 工时记录 / 跨会话引用  
> 分支：`{{BRANCH}}`  
> Worktree：`{{WORKTREE_PATH}}`  
> 排期：{{START_DATE}} ~ {{END_DATE}}（{{WORKDAYS}} 工作日）

---

## 当前状态

| 指标 | 值 |
|------|-----|
| 当前阶段 | {{CURRENT_PHASE}} |
| 总体进度 | {{PROGRESS_BAR}} |
| 最新 commit | `{{LATEST_COMMIT}}` {{COMMIT_MSG}} |
| 测试 | {{TEST_PASSED}} passed / {{TEST_FAILED}} failed |
| 编译 | {{BUILD_STATUS}} |

---

## 每日进度

### {{TODAY_DATE}} (D1)

**完成：**
- [x] 项目初始化：worktree 创建、依赖安装、编译验证
- [x] Agent Quality Gate 安装
- [x] AGENTS.md 生成
- [x] 进度跟踪系统建立

**产出：**
- N files changed, +N lines
- Commit: `{{HASH}}` on `{{BRANCH}}`

**待完成：**
- [ ] {{NEXT_TASK_1}}
- [ ] {{NEXT_TASK_2}}

---

## 排期 vs 实际

| Day | 计划 | 实际 |
|-----|------|------|
| D1 ({{D1_DATE}}) | 环境搭建 + 基础设施 | — |
| D2 | — | — |
| D3 | — | — |

---

## Commit 日志

| Hash | Date | Message |
|------|------|---------|
| — | — | — |

---

## 工时参考

| 日期 | 工时(h) | 任务描述 |
|------|---------|----------|
| — | — | — |

---

## 关键信息（跨会话引用）

```
项目：{{PROJECT_NAME}}
分支：{{BRANCH}}
Worktree：{{WORKTREE_PATH}}
需求文档：{{REQUIREMENT_DOC_PATH}}
门禁文档：.agent/GATES.md
进度文档：.agent/PROGRESS.md（本文件）
Agent Memory：.agent/memory/
实现计划：.agent/plans/
测试命令：{{TEST_CMD}}
编译命令：{{BUILD_CMD}}
安装命令：{{INSTALL_CMD}}
```

---

> 文档版本：持续更新  
> 最后更新：{{TODAY_DATE}}
