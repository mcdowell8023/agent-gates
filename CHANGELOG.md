# Changelog

All notable changes to agent-gates will be documented in this file.

## v2.9.8 — 审查产物终于能跨 worktree 被门禁看见

🔴 卡人的实况（2026-09-10，我自己撞的）：`.gitignore` 排除 `.agent/reviews/` 与
`.agent/verify/`（wb 的项目更狠，整个 `.agent/` 都 ignore），而 `merge-only` 档把
审查推迟到「合并进 strict 分支」那一刻。产物在**功能分支的 worktree** 里生成、
merge 发生在**主仓 worktree** —— 既不进 git 又不跨 worktree
⇒ **它永远到不了那个检查点**。当天我是手工 `cp` 过去才让门禁通过的。

⇒ 产物同时写进按**仓库**（不是按 worktree）分键的共享库：

```
$AGENT_GATES_DIR/artifacts/<repo-key>/reviews/
```

`repo-key` 取自 `git rev-parse --git-common-dir` ⇒ 同一仓库的所有 worktree 同键，
不同仓库不同键。CHECK 5 现在同时扫项目内的 `.agent/reviews/` 和这个共享库。
⛔ 不动任何项目的 `.gitignore` —— 那要各项目分别改，而且会把审查正文推进 git 历史。

### ⚠️ 差点埋进去的坑：macOS 的 /var 软链

worktree 里 `git-common-dir` 返回 `/private/var/...`，主 worktree 返回**相对**的 `.git`。
把相对值转绝对得到 `/var/...` —— 而 `/var` 是 `/private/var` 的软链 ⇒ **同一个仓库在
两个 worktree 里算出不同的 key，共享库当场失效**。实测撞到，两处实现都改成 `pwd -P`
统一到物理路径。

两处实现分叉的失败**长得像「审查根本没做」**，所以测试里钉了一条可观察的断言：
主仓与 worktree 各登记一次后，键目录必须仍是 1 个。
（⛔ 别把 CLI 当库 source 去问它算出什么 —— 它会跑主流程。第一版就是这么写的。）

### 顺带修掉一处 fail-open

`output_result()` 原来是裸 `> "$RESULT_FILE"`：父目录不存在时重定向失败，
而函数照样返回 0、调用方照样 `exit 0` —— 表现为**「命令说成功了，产物却不在」**。
而 `.agent/reviews/` 正是被 gitignore 的目录，新 worktree 里天然不存在 ⇒ 必踩。
现在建父目录 + 写失败返回 75，调用方检查返回值。

### 已知未做

verify 侧（CHECK 6）还没接共享库：它的产物是 `.md` + `.dispatch.json` 成对的，
接进去要动 CHECK 6 的配对逻辑，是另一块。⚠️ 但那一侧目前没有同等的卡点 ——
`agent-gates-verify-import` 本来就不要 token、锚点当场算，可以直接在主仓生成。

## v2.9.7 — 免 token 登记「自己已经跑完的审查」

🔴 卡人的实况（2026-09-10，wb 一条长会话）：它用 `pi -p` 跑完七轮审查、结论都在手上，
但 `--import-result` **强制要 `--token`**，而 token 只能由**派发**签发 ⇒ 已经审完的东西
拿不到 token ⇒ 那条线判断「凑不出官方产物」，停在原地不合 master。

而做同一件事的 `agent-gates-verify-import` **不要 token、锚点当场算**。同一个仓库里
两种形状，后者才是对的：

| | token 证明的 | 锚点证明的 |
| --- | --- | --- |
| 内容 | 审查发生在派发**之后** | 审的**就是这份代码** |
| 价值 | 只是顺序 | 顺序防不住的实际问题它都能防 |
| 当场算会不会削弱 | — | ⛔ 不会 |

⇒ `--import-result` 不带 `--token` 时走 `tokenless_import()`：`capture_review_anchor`
当场算锚点（⛔ 从不接受调用方传进来的锚点），产物记 `REVIEW_TOOL: external` +
模型 `unverified`，CHECK 5 照常认。

### 三条 fail-closed

- **必须自报型号**：不给 `--imported-model` 直接拒 —— 匿名审查无法记账，
  异构是按「产出它的模型」判的
- **⛔ 免 token 模式不接受 `--paseo-agent`**：没有派发记录就没有 `created_at`，
  无从排除「旧 agent 给新审查顶账」（那正是 `--paseo-agent` 那条路要防的）⇒
  与其发一份假的「已核实」，不如拒绝并说明
- **没有 staged 变更就拒**：没东西可锚定

### 测试

`tests/run_review_import_tokenless.sh` 16 条，含带 token 老路子的回归。
⚠️ 测试第一版 harness 自己有 bug：`$(mkrepo)` 是子 shell，里面的 `cd` 带不到调用方，
后面所有 git 命令都跑在测试自己的 cwd 上（症状是 `pathspec 'src.ts' did not match`），
而那时 ③④⑤ 三段是**空过**的 —— token 那道门把所有输入都挡在前面，看起来全绿。

## v2.9.6 — doctor 不再复活 opencode，也不再静默死掉

起因：用户 2026-09-10 卸载 opencode 后，`~/.opencode` 在 40 分钟内**自己回来了**，
端口 4096 上又起了一个 PPID=1 的 `opencode serve`（目录时间戳全是原始的 ⇒ 是被还原、
不是重装）。排查排除了 Syncthing（三个 folder 都不覆盖它）、cron、hermes。
最可能的机制是 doctor：它的 D6 探测**无条件** shell out 到 opencode，链路里的
`oc_serve_ensure` 会直接把 serve 拉起来 —— 只要二进制还在，任何一次 doctor 都能复活它。
同时它把能力报成 `L3 (opencode + codex)`，而那台机器上 opencode 已经不存在。

⭐ 一个把用户明确关掉的通道重新拉起来的体检命令，比一个大声失败的更糟：
设置在所有人认知里还在，实际已经被绕过。

### 改了三处

**① opencode 探测先过通道开关。** `channels.opencode.enabled=false`（或
`HETERO_CHAN_OPENCODE=0`）时完全不探测、不进能力判定，并打印跳过原因。
`check_opencode_health` 整段一起门控 —— 关掉之后不该再有任何代码去 pgrep 它的 serve。
⚠️ 读取是**内联**的，⛔ 不 source `lib/hetero/select.sh`：doctor 跑在 `set -euo pipefail`
下，整份 source 会连带执行库的顶层代码，实测同一份 doctor 在两个 fake 目录下走出了
两条不同的路。默认值必须与 `_review_chan_default` 保持一致（opencode=0，其余=1）。

**② `INSTALL_DIR` 改为听 `AGENT_GATES_DIR`。** 原来硬编码 `$HOME/.agent-gates`
⇒ **任何一次带 `AGENT_GATES_DIR` 的 doctor 调用（包括测试）都会写真实配置**。
本轮 RED 阶段一次测试跑就把用户手工设的 `review_models.primary`
（`gpt-5.6-sol` → `gpt-5.5`）和 `panel_pool`（`[grok-4.5]` → `[]`）冲掉了，
而 doctor 只打印 `wrote ~/.agent-gates/hetero-check.json`，看不出它写的不是测试目录。
已从备份恢复。测试里加了一条断言：跑完后真实配置**一个字节都不能变**。

**③ `check_opencode_health` 在 0 个 serve 时会把 doctor 杀掉。**

```bash
total=$(pgrep -f "opencode serve" 2>/dev/null | wc -l | tr -d ' ')
if [[ "${total:-0}" -eq 0 ]]; then pass "opencode: no leaked serve processes"; return 0; fi
```

`pgrep` 无匹配退出码 1 ⇒ pipefail 放大 ⇒ 赋值非零 ⇒ `set -e` 直接退出。
**后果是下一行那个 `pass` 永远到不了 —— 它看着在处理"零个 serve"，实际是死代码**；
而 doctor 在 opencode 在 PATH 上、却没有 serve 在跑时，会**不打汇总就退出**，
看起来像"跑完了"。同族的 `serve_pid=$(pgrep ... | head -1)` 一并修。

⚠️ 这与本轮一线反馈的 BUG 1（`grep -c ... || echo`）**是同一个家族**：
命令"打印了结果但退出码非零"，而调用方用管道赋值。一天里同一类踩了三次
（BUG 1 两处 + 这里两处），全仓已扫过 `=$( (pgrep|grep -c) ... |` 形状，无残留。

### 测试

`tests/run_doctor_channel.sh` 11 条。⚠️ 正对照改过两次判据：
最初用「fake opencode 是否被执行」，但真正会 exec 它的是 D6 的
`detect_available_models`，那条链还要 `$INSTALL_DIR/bin/with-timeout.mjs` 等一整套
安装布局，fake 目录凑不出来 ⇒ 断言永远为假，是个**空心的正对照**。
最终判据落在「能力行里有没有 opencode」。

## v2.9.5 — 一线反馈的两条 bug（都不是本次会话引入的）

来自 `~/wb` 一条长会话的实测反馈（Paseo agent `3e2ffb58`，2026-09-10）。⚠️ 这两条我
**此前完全不知道**，而且 BUG 1 就在我这两天连改三轮的那个文件里。

## BUG 1 — `grep -c` + `|| echo "0"` 产出两行，静默废掉行数上限检查

`hooks/git/agent-quality-gate.sh:273` 与 `:1047`（反馈里的 327/1101 是 2.9.1 行号）：

```bash
flines=$(git diff --cached -- "$f" | grep -c '^+[^+]' 2>/dev/null || echo "0")
```

`grep -c` 无匹配时**打印 `0` 并且退出码 1** ⇒ 那个 `||` 再补一个 `0`，变量成了 `0\n0`，
随后 `[[ "$flines" -gt N ]]` 抛算术语法错。**`&&` 短路让循环继续，所以不报错、不中断**
—— `MAX_SINGLE_FILE_LINES` 从此不再更新，单文件行数上限检查静默失效；`:1047` 那处
同理会中断 `POST_VERIFY_LINES` 的累加。

触发条件只需 diff 里有**一个纯删除文件**（新增行数 0）。引入于 `6fffbf9`
（2026-06-27）—— 存在两个半月。

改成 `{ grep -c '^+[^+]' 2>/dev/null || true; }`（`grep -c` 本来就一定打印数字）。
全仓扫过，没有第三处同形状。

## BUG 2 — 新 worktree 丢 `gates.json` ⇒ 门禁退回 strict

项目 `.gitignore` 里有 `.agent/`（wb 的 crm-center / crm-platform 都是）⇒ `gates.json`
从未被 git 跟踪 ⇒ `git worktree add` 出来的目录里根本没有它。门禁找不到项目策略就按
**strict** 走，在普通业务分支上也强制要求 review + verify 产物，每建一个 worktree
都得手工 `cp` 一份。

采纳反馈里的第二个建议：**回退到主 worktree 去找**。`git rev-parse --git-common-dir`
在 worktree 里返回主仓的 `.git`，其父目录就是主 worktree 根。一处改动覆盖所有项目，
⛔ 不动任何项目的 `.gitignore`（那要各项目分别改，且会把策略文件推进 git）。

⚠️ **我今天撞到的是同一族的另一个面**却没往上想一层：`.agent/reviews/` 被 ignore，
导致审查产物在功能分支 worktree 里生成、merge 在主仓发生、**产物到不了那个检查点** ——
当时我是手工 `cp` 过去才让门禁通过的（见 v2.9.3 的「已知未修」）。同一个根因。

## 测试

`tests/run_gate_reported_bugs.sh` 7 条。⚠️ 测试自己踩了两个坑，都写进注释：

- `agent-quality-gate.sh:8` 那行 `AGENT_MODE != 1` **直接 exit 0、一个字不打印** ——
  第一版没设它，把"输出为空"读成了断言失败
- 断言 grep 的是 `mode: off`，而实际输出是 `mode=off`

另外第一版试图 `eval` 从门禁里抽出来的代码片段做行为验证 —— 那段依赖门禁里的其它变量，
抽出来跑等于测另一个东西。改成让**真门禁**跑在一个只删不加的 staged diff 上。

## v2.9.4 — opencode 从审查路径彻底移除

用户 2026-09-10 卸载 opencode（`~/.opencode` 185MB + volta 上的 `oh-my-opencode` +
`.zshrc` 的 PATH + Paseo 里 6 个残留 profile；卸载时端口 4096 上**正挂着一个
`opencode serve`**）。它的历史成本全是实测的：`agent-gates-review` 走它 120s 超时、
手动 `--attach` 200s，同一任务 pi 约 7s；一个 serve 被观察到 4 天不退、133 分钟 CPU、
机器上零客户端；每个 Paseo agent 起自己那份 1–1.5GB 且 idle 后不回收。

### 删掉的东西

- `lib/hetero/select.sh` 的 `_review_via_opencode()`（94 行）—— `_try_review_model`
  现在是 pi-only
- `bin/agent-gates-review` 的 `run_opencode()`（58 行）—— ⚠️ 它是 **legacy L0–L3 路由**
  那条独立的 opencode 通道，与 hetero 分支那份是**两份实现**，只拔一份等于没拔
- 9 个纯 opencode 测试文件：`run_oc_review` / `run_oc_review_guard` / `run_oc_serve` /
  `run_oc_reaper` ×3 / `run_review_cmd`（60 条断言里 64 处提 opencode，是 legacy 路由的
  集成测试）

⚠️ **清理侧的 `oc-reaper` / `lib/hetero/serve.sh` 暂留** —— 万一哪天冒出个野 serve
还能清，且它们不参与审查路径。`agent-gates-status` 的 opencode 行同理。

⛔ 不要"为了兼容"把审查通道加回来。要加通道就加新的 one-shot CLI，
别复活需要常驻 serve 的。

### 同时修掉前一版审查抓到的 8 条

`gpt-5.6-sol`（走新 pi 通道，产物 marker `REVIEW_TOOL: pi`）+ `grok-4.5` 两路并审：

1. **通道默认与 `config.sh` 相反**（高）—— `_review_chan_enabled` 照抄了
   `bin/oc-review` 的守卫，缺文件/缺键时把 opencode 判为**开**；而
   `lib/hetero/config.sh` 是 `0`，`tests/run_hetero_chan_defaults.sh` D1 也钉着
   「无配置 opencode=0」。⇒ **同一仓库两套相反默认，两边测试都绿**。两个审查者独立抓到。
   现在按 channel 各自的默认（opencode=0，其余=1），且缺键/坏 JSON 一律落到默认而非放行。
2. **`AG_REVIEW_TIMEOUT` 一存在，pi 的 300s 就永不生效**（高）——
   写的是 `${AG_REVIEW_PI_TIMEOUT:-${AG_REVIEW_TIMEOUT:-300}}`，而那个变量在文档和
   环境里常见 `120`。CHANGELOG 上一段刚论证「pi 该有自己的默认」，下一行就撤销了，
   而且测试把它锁死成「pi 听 AG_REVIEW_TIMEOUT」。现在两个旋钮完全独立。
3. **here-string 建临时文件失败 → `timeout_cmd` 空数组 → pi 无界运行**（高）——
   fail-closed 被一个无关的磁盘问题绕过。改成断言数组长度。
4. **sidecar 写失败被 `|| true` 吞**（高）—— 调用方读到空 sidecar 后转成
   `tool=unknown` + `model=<primary 兜底>`，然后 exit 0 交出格式完好的产物。
   一份同时写错工具和模型的凭据比没有凭据更糟（`REVIEW_MODEL` 存在的意义就是异构记账）。
   两侧都改 fail-closed。
5. `_REVIEW_CHAN_NOTES` 在 `set -u` 下直接调 helper 会 unbound
6. 通道链尾的 `agent-tool` 兜底不存在（文档已改）
7. `suggested` 写死推荐 opencode、alternatives 里连 pi 都没有 —— 在一台
   `channels.opencode.enabled=false` 的机器上。**工具在推荐被禁的通道，agent 照做**，
   这就是那条禁令被破两次的机制。现在按实时开关生成，并给出 `import_cmd_no_agent`。
8. `AG_REVIEW_PI` / `AG_REVIEW_PI_TIMEOUT` 完全没文档化；头部还写着
   `AG_REVIEW_TIMEOUT` default 300 而代码是 120

### 测试

41 个文件全绿，进程零残留。⚠️ errexit 那条断言**空过了两次**才修对：
两个用例都够不到 `raw=$(...)`（pi 缺失时提前 return、pi 成功时命令替换不失败）；
补了 pi 非零退出的用例后**仍然**空过 —— 因为 `f || true` 把整个函数放进 AND-OR 列表，
而 bash 在 AND-OR 列表内部**挂起 errexit**。最终判据落在**错误信息有没有被打出来**
（有守卫先打印再 return；无守卫死在赋值行、一字不出），注入变异确认变红。

## v2.9.3 — agent-gates-review 终于真的能用 pi 审查

`channels.opencode.enabled=false` 是 2026-08-26 设的，文档也把 opencode 降到第 3，
但**代码层三处入口一处都没改**：

- `_try_review_model()` 硬编码 `${OC_REVIEW_OPENCODE:-opencode}`，⛔ 不查任何通道开关
- `agent-gates-review` 全文对 pi **零命中**（`grep -c` 就是 0）
- 唯一实现了 pi 通道、唯一读 `channels.*.enabled` 的 `hetero_dispatch`，
  **没有任何生产调用点** —— 全仓非注释引用全在 `tests/` 里

`bin/oc-review:69` 的注释里早就写着这件事：
"v2.4.0 turned that channel off by default, but only hetero_dispatch consults the flag."

后果不是「配置没生效」这么轻。用户 0818 明令「⛔ 不许用 opencode 做审查」，两个子会话
各自拿 opencode 审完报 PASS。**规则靠任务书传递，工具自己拦不住。** 更糟的是
`--route paseo --dispatch-out` 输出的 `suggested.provider` 写死 `opencode/...`、
alternatives 里连 pi 都没有 —— 工具在推荐被禁的通道，agent 照做。

### 改了什么

`_try_review_model` 变成通道路由器，原 opencode 主体拆成 `_review_via_opencode`，
新增 `_review_via_pi`。顺序即偏好：**pi 优先，opencode 末位**。

- `_review_chan_enabled <chan>`：env `HETERO_CHAN_<CHAN>` > `channels.<chan>.enabled`；
  只强制「显式关闭」，缺文件缺键都按放行（与 `bin/oc-review` 的守卫同口径）
- 模型 id 两边通用（`github-copilot/gpt-5.6-sol` → pi 的 `--provider` + `--model`），
  所以复用 `review_models`，⛔ 不引入新配置键
- ⛔ pi 一律带 `--tools read,grep,find,ls`。pi 默认工具集含 edit/write/bash，
  2026-09-01 实测一个审查者改了被审源文件、建了分支、还 push 了
- ⛔ pi 返回**纯文本**，不能过 `parse_opencode_json`（那个 helper 对纯文本解析出空，
  会读成「模型什么都没说」而丢掉一份好审查）
- `append_marker` 不再写死 `"opencode"`。工具名经 **sidecar 文件**回传 ——
  真实调用方是 `_raw=$(run_fallback_chain ...)`，命令替换里的赋值随子 shell 消失。
  `_REVIEW_MODEL_USED` 一直有这个洞，只是调用方静默兜底成 primary，所以 panel 模型的
  审查一直被盖上 primary 的名字
- pi 单独的默认超时 **300s**（`AG_REVIEW_PI_TIMEOUT` 可覆盖）。`AG_REVIEW_TIMEOUT` 的
  120s 是给 opencode 调的 —— 那是「该通道判定为卡死」的界；pi 到 120s 是**正在干活**：
  四次实测真实审查在 1.5–4.5 分钟，本通道第一次端到端跑就死在 200s 半途
- `suggested` 改成 pi 首选、opencode 末位带警告；`import_cmd_no_agent` 一并给出 ——
  自己跑完审查的会话没有 Paseo agent，此前因此认为「凑不出官方产物」而停在原地

### 三条来自本通道自审的修复

通道建好后拿它自己审自己（产物 marker 写着 `REVIEW_TOOL: pi`、
`REVIEW_MODEL: github-copilot/gpt-5.6-sol`），抓到三条并全部修掉：

1. **`has_valid_conclusion` 缺失时 fail-open** —— `declare -f X && ! X` 的写法在函数
   不存在时跳过整个校验，任何非空输出（报错、拒答、半截回复）都算通过。pi 的 raw 就是
   最终产物，select.sh 内部没有第二道解析兜得住它 ⇒ 改成 fail-closed
2. **`X=$(...)` 后跟 `rc=$?`** —— 门禁 source 本文件（`agent-quality-gate.sh:664`）
   且跑在 `set -euo pipefail` 下，命令替换失败会在 `rc=$?` 之前杀掉进程，整段错误处理
   不可达。两处都改成 `if X=$(...); then`（既有的 opencode 路径是同一形状，
   只修新的就是下次还会咬）
3. `_l` 未声明 `local`，会覆盖调用者同名变量

### 测试

`tests/run_review_pi_channel.sh` 42 条。⚠️ 其中 errexit 那条**第一版是空过的**：
两个用例都够不到 `raw=$(...)`（pi 缺失时提前 return、pi 成功时命令替换不失败），
注入变异后照样全绿。补了 pi **非零退出**的判别用例后**仍然**空过 —— 因为 `f || true`
把整个函数放进 AND-OR 列表，而 bash 在 AND-OR 列表内部**挂起 errexit**。
最终判据落在**错误信息有没有被打出来**（有守卫先打印再 return；无守卫死在赋值行、
一字不出），注入变异确认变红。

同时给 12 个早于本通道的测试文件补了文件作用域 fail-safe
`export AG_REVIEW_PI="${AG_REVIEW_PI:-/nonexistent/pi-must-not-run-in-tests}"` ——
它们只 fake 了 opencode，而 pi 现在排第一且真的 `pi` 就在 PATH 上。
第一版试图用收窄 PATH 来隔离，结果为了把 node 放回去写了 `dirname $(which node)`，
那正是 `~/homebrew/bin` —— **真 pi 也在里面**，测试当场发了一次真实 API 调用并挂到 120s。

### ⚠️ 本次发现但未修

`.gitignore` 排除了 `.agent/reviews/` 与 `.agent/verify/`，而 `merge-only` 档把审查
推迟到 merge 那一刻。审查产物在功能分支的 worktree 里生成，merge 发生在主仓 worktree
—— **产物既不进 git 又不跨 worktree，等于永远到不了那个检查点**。本次是手工 `cp`
过去才让门禁通过的。另外 `--import-result` 强制要 `--token`（只能由派发签发），
而同样的 `agent-gates-verify-import` **不需要 token、锚点当场算** —— 后者才是对的形状。

## v2.9.2 — grok 接掉 gemini 的位置，顺带发现那个格子早就是空的

用户反馈 gemini 的审查质量不行，要求换 grok-4.5。换型号本来是改一行数据，但查下去发现
四件事。

**1. 光改数据不生效。** `lib/hetero/select.sh` 的 `_extract_vendor` case 表里没有 grok，
返回 `unknown`，而 `build_review_models` 里紧跟着一句 `[[ "$v" == "unknown" ]] && continue`
—— 配置里写了 grok，池子里也不会有它，且全程没有一行输出说明原因。同一张表在
`merge_capability` 的内联 python 里还有第二份（`vendors = [...]`），漏了 grok 会让
`pv` 判成 `unknown`，与 platform 未探测出来时的 `coding_vendor='unknown'` 相等，
于是**整份本地配置被 exit 1 拒掉**。两处都补了（`lib/hetero/family.sh` 早就有
`grok-* → xai`，那张是公司名族表，不需要改）。

**2. gemini 那个格子在被发现之前就已经是空的。**
`github-copilot/gemini-3.1-pro-preview` 在 `opencode models` 和 pi 的 catalog 里都查不到
（2026-09-08 实测），剩下的 gemini 型号全是 `gemini-*-flash`，而 `build_review_models`
里有一句硬编码 `[[ "$name" == *flash* ]] && continue`。那一项从型号下架起就没被选中过。

**3. `data/review-model-recommendations.json` 里 `excluded_patterns` 是个装饰字段。**
声明了 `["flash","glm"]`，但**全库 lib/ 零引用** —— flash 的剔除来自上面那句硬编码
（`build_review_models` 和 `filter_panel_pool` 各一份），`glm` 则完全没有拦，
写在配置里也照样进池。⚠️ 本次第一版把机制写成「flash 命中 excluded_patterns」，
两个审查模型都指出这是假叙事，并且配的那条测试（只读 JSON 字段、名字叫「仍然排除」）
是**给死配置续命的假绿**。已改成两条特征测试：一条证实 glm 型号进得去，
一条证实 `excluded_patterns` 为空也照样剔 flash —— 真去实现这个字段时它们会变红。

**4. `skills/agent-review-protocol/SKILL.md` 的推荐表里有两行填不出来的型号。**
除 gemini 那条，还有 `openai/gpt-5.5-pro` —— **`openai` 这个 provider 根本不存在**
（opencode 侧只有 github-copilot / opencode / openrouter-free / volcengine-*；pi 侧只有
volcengine-coding / volcengine-agent-plan / jdcloud-joyagent / github-copilot）。
表已重写，逐个探活过。同一次复查还发现推荐数据里三个 `bailian/*` 也是同样状态
（本机没有 bailian provider），已就地标注而非删除 —— 别的机器可能配了。

`tests/run_review_vendor_grok.sh` 13 条，含一条端到端：fake opencode 列出 grok-4.5，
断言它必须真的出现在 `panel_pool` —— 只测 `_extract_vendor` 的返回值不够，那句
`continue` 在别的函数里。

`tests/run-all.sh` 一并带入。⚠️ 不带它这个新测试文件就是装饰：main 上唯一的 runner
`tests/run.sh` 只跑 memory-reminder fixture，`run_*.sh` 一个都不执行 —— 审查抓到的，
和之前「测试没覆盖本次新增文件」是同一类。

### 顺带纠正文档里的三处错误断言

- `panel_active` 被写成 "concurrent reviewers"。**一次异构审查只有一路。** 两边都是串行
  fallback、第一个成功就停。`panel_active` 准确说是 `panel_pool[:panel_active]` 的切片上限，
  实际链长 = `min(panel_active, len(panel_pool))`，还要再过 `panel_mode`。
- 通道链尾写成 `→ codebuddy → agent-tool`。实际 codebuddy 之后 `channel` 保持
  `exhausted`，**没有 agent-tool 兜底**。
- 把 `panel_pool` 和 `channels.opencode.enabled` 绑在一起说 —— 这是本次新造的错误断言。
  两套机制互不相干：`hetero_dispatch` 受 `channels.*` 约束、读 `pi_models.primary`；
  而 `panel_pool` 走 `bin/agent-gates-review` → `run_fallback_chain`，
  **完全不看 channel 开关**，只要 `opencode` 二进制在、serve 起得来就会用。
  文档里补了一张两列对照表。
- 「第二轮必须换族」改成「建议」：仓库不记录上一轮 reviewer 的族，也没有跨轮校验，
  那是外部工作规则，不是 agent-gates 能强制的。

⚠️ 已知未改：`_extract_vendor`（8 个厂商，marketing 名）与 `lib/hetero/family.sh`
（14 个族，公司名）是同一个概念的两份实现。合并要连 `infer_coding_vendor`、`select_primary`
和所有已存配置里的 `coding_vendor` 一起改，超出本次范围。代价是
`doubao` / `hunyuan` / `mai-code` / `minimax` 在 select.sh 里仍然落在 `unknown`。

### 审查记录

两路并行、都是异构（实施者是 claude/anthropic）：`github-copilot/gpt-5.6-sol`（openai）
7 条 → **FAIL**，`github-copilot/grok-4.5`（xai）多条 → **FAIL**。
两边独立指向同一个核心问题（`excluded_patterns` 假叙事 + 那条假绿测试）；
grok 另外单独抓到 `panel_pool` ↔ `channels.opencode` 那条错误绑定，gpt 没抓到。
全部修完后复审。

## v2.9.1 — merge 门禁此前没有可运行的钩子点

`merge-only` 档把审查推迟到「合并进集成分支」那一刻。而 git 对 merge commit 走的是
**`pre-merge-commit`**，不是 `pre-commit`，agent-gates 从来只装 `pre-commit` ——
所以干净的非 ff merge 完全不受检，那个推迟指向的是一个**不存在的检查点**。
（scratch 仓同时挂两个钩子实测确认：merge 只触发前者。）

`gate-shim.sh` 本来就只做 `exec` 转发、不含任何 pre-commit 专属逻辑，同一份直接作为
`pre-merge-commit` 装上即可，无需第二个实现。项目现在需要**两个**钩子，
`init-project-gates` 的三种安装模式（lefthook / husky / bare git）已同步。

`tests/run_gate_merge_hook.sh` 10 条，其中一条**刻意删掉钩子来证明空洞真实存在**
（merge 通过且门禁零输出）—— 没有这条，这个修复看起来只是「多装一个文件」。

⚠️ **fast-forward merge 仍然没有钩子点**（它不产生 commit）。合并进集成分支请用 `--no-ff`，
或在仓库里配 `git config merge.ff false`（⛔ 显式 `--ff-only` 仍能压过它，实测）。

## v2.9.0 — 验收改成查需求遗漏，而不是第二次代码审查

### 问题

CHECK 6「验收」实质退化成了第二次代码审查：触发条件和 CHECK 5 一样，产物也一样是
「让模型读代码」，`templates/verifier.md` 里那句「验收标准是否逐条满足」**没有任何机制支撑**
—— 门禁只校验 `^VERIFY_VERDICT:` 这行存在、dispatch 锚定了 staged diff、capability 分级。
一段关于 diff 的散文加一行 PASS 就能过。

而验收真正要抓的是**漏做**，两种形态：

- **纵向漏层**：后端接口写了，前端一行没写 → 用户根本用不了
- **横向漏项**：需求「导出全部表格内容」，搜索做了，导出接口没写

漏做的共同属性是**在 diff 里不留痕迹**：CHECK 5 读 diff，看到的每一行都是对的；
实现者自己写的测试同样失明 —— 它没做的部分没写测试，**测试全绿和需求少一半可以同时成立**。
一切从代码派生的清单（diff / 测试 / 覆盖率）对漏做结构性无效。

需求清单本来就在盘上（CHECK 3 要求的 `.agent/plans/`、CHECK 2 要求的 `features/*.feature`），
CHECK 6 从不读它 —— 和 v2.6.0 修的 dispatch→CHECK 6 断链是同一个形状：
**承载真相的产物存在，检查点不读它。**

### Added — 需求矩阵 `lib/verify/reqmatrix.sh`

验收产物增加逐条矩阵，每条需求一行：

```
REQ_SOURCE: .agent/plans/2026-09-01-export.md
REQ_BLOCK_SHA256: 3f2a…
REQ_ITEMS: 2
REQ_ITEM: 1 | COVERED | api:src/export.ts:18, ui:~src/List.vue:88 | 按钮既有，本次补接口
REQ_ITEM: 2 | MISSING | - | 导出接口未实现，前端无导出入口
```

门禁强制的是**形式**，五条都是确定性可测的：

| | 机制 |
|---|---|
| E1 | 条目数由门禁从需求源数出来，模型只能填每条的处置、**无权决定有几条** |
| E2 | 只哈希提取出的条目块 —— 事后删改需求条目会失效，改文档别处的错别字不会 |
| E3 | 不带 `~` 的引用必须落在本次 staged diff 内（含删除）；带 `~` 只需在工作树存在 |
| E4 | 判定由矩阵推导，不采信模型申报那行；只收紧，不放宽 |
| E6 | 证据按 `ui:`/`api:`/`db:`/`job:`/`cfg:` 分层声明，零 `ui:` 证据会被点出来 |

状态取值 `COVERED` / `PREEXISTING` / `PARTIAL` / `DEFERRED` / `NA` / `MISSING`。

### 目标是「无法静默绕过」，不是「无法绕过」

铁了心撒谎的模型总能撒谎（把漏做的标 `NA`、编一个 `ui:~` 路径冒充入口）。
想堵死只会造出一堆假失败，而假失败比漏抓更贵 —— 它让人直接绕过门禁。
所以：**逃逸口一律计数打印**（`NA=` / `DEFERRED=` / `PREEXISTING=` / `NOTHING_TOUCHED=`），
把「悄悄少做一半」变成「必须写下来说我少做了什么」。

分工写明：**门禁管形式，异构验收模型管实质。** 「这条证据是否真的完成了这条需求」
是语义判断，shell 做不到，不声称能做。门禁的贡献是让验收模型无法静默跳过任何一条。

### Added — `verify-harvest --emit-prompt` / `--req-source`

骨架进**提问**，不进结论：

- `--emit-prompt --req-source <f>` 输出逐条提问块（编号需求 + 要求的回答格式）供派发
- `--req-source <f>` 收割时校验模型答满了每一条；**漏答则拒绝生成产物**（exit 3）

不代填是硬规则：填 `COVERED` 是凭空造一个通过，填 `MISSING` 则把「没人问」误记成「没做完」。
另外，`REQ_ITEM:` 行被列表符号/缩进包住时会明确报「不在行首」，而不是含糊地说没回答 ——
否则排查方向会跑到模型身上，而真正的问题是行首那两个字符。

### 触发时机：strict 分支 + 需求源真的存在（`verify.require_matrix`，默认 `auto`）

第一版按 strict 分支单独判定，当场打挂 12 个既有门禁测试 —— 全是「在 master 上提交、
verify 产物是旧格式」的 fixture，而那正是已部署仓库的样子。照那样发布，等于
「每次 master 提交都失败，直到你手写一个新产物」，可预见的反应是设 `mode:off`。

`auto` 把要求绑定到它自己的输入是否存在：写了 `## 验收标准` 章节才启用，滚动自然发生。
`true` 强制、`false` 关闭。特性分支上矩阵若已存在仍会解析并打印结论，不阻断 —— 迭代中
需求只完成一部分是正常状态。

### Added — `templates/plan.md`

带 `## 验收标准` 章节的计划模板。gemini 的审查意见成立：发明 `<!-- REQ:BEGIN -->` 这类
标记，强制则没人写、不强制则永远降级为告警沦为摆设。改用人本来就会写的命名章节，
模板让写它零额外成本。

### 三轮异构审查（gemini-3.1-pro + gpt-5.4）

方案前两轮均 FAIL，采纳 14 条，其中改变设计的 4 条：

- **E3 只查「文件存在」被一击打穿**：漏做功能时把证据指向 `package.json` 即可放行。
  → 改为必须落在本次 staged diff 内
- **`E3+E6` 联动误伤真完成项**：「UI 按钮早就有，本次只补 api」交付后用户确实能用，
  却因为那个 UI 文件不在 diff 里而无法合法表达。根因是**一条 REQ_ITEM 只有一个状态，
  表达不了逐层混合**。→ 状态下沉到每条证据，`~` 前缀
- **「任一 MISSING → FAIL」制造反向激励**：会逼开发者回去删 plan 里的后两条需求才能提交。
  → 新增 `DEFERRED`
- **`REQ_SOURCE` 指向无验收块的文件时降级为告警 = 绕过口** → 新增 `bad-source` 档直接 FAIL

### Fixed — 三处会造成假失败的地方（交叉审查抓到）

**结论解析器我重新发明了一遍。** `lib/hetero/conclusion.sh` 早就有规范实现，
容忍 markdown 装饰与全角冒号、并用完整取值表拒绝带限定的结论。`agent-gates-plan-review`
第一版自己写了个只认裸 ASCII 的，后果两条：协议明确允许的 `**VERDICT: PASS**` /
`## VERDICT: PASS` / `VERDICT：PASS` 全被误拒 —— 正是 v2.0.2 那次被报成「所有审查模型都失败」、
把排查方向指向传输层花掉一天的同一形状；更糟的是 `VERDICT: PASS_WITH_ISSUES` 匹配到 `PASS`
前缀被记成干净通过，**把审查结论反了过来**。改为委托 `conclusion.sh`。

**多计划共存时首个命中掩盖有效计划。** `find` 按字母序返回，一个旧计划锚点失配就 `break`，
当前那个有效计划根本没机会被看到。改为：任一计划成立即通过，只在无一成立时报告。

**dangerous 路径判定用子串匹配。** `auth` 命中 `author.ts` / `oauth.ts`，`acl` 命中
`oracle.ts`（or-**acl**-e）。每一次都让「已批准的 skip」被拒成「危险改动」—— 一次重命名就撞上。
改为按路径分隔符切词；`author` 与 `authentication` 共享前缀、没有边界规则能分开，
所以 auth 系拼法改成显式列举。

**另三条来自 select.sh 超时改动的审查**：`2>/dev/null` 加在调用点，把 fail-closed 的诊断
一起吞掉了（检查点会说话，但没人听得见）—— 改成只静音被探测工具自己的 stderr；
`HETERO_PROBE_TIMEOUT=08` 通过 `^[0-9]+$` 后被 bash 当八进制，`value too great for base`
漏到终端（实测）—— 改用 `10#` 强制十进制；`_hetero_bounded` 的 69 状态被管道吞掉，
「node 缺失」和「这个工具没有模型」变成同一个可观测现象 —— 改为先取值再判状态。

### Fixed — CHECK 3 的修复路径不存在，手写标记就是通过

跑本仓库自己的门禁时撞上：CHECK 3 报 `Plan exists but missing PLAN_REVIEW markers`，
提示 `Fix: run agent-gates-review --plan <plan>` —— 而**那个 flag 在 `bin/` `lib/` 里
根本不存在**，`PLAN_REVIEW` / `_TOOL` / `_MODEL` 三个标记也没有任何工具会写
（`bin/` `lib/` `skills/` `templates/` 全 grep 不到）。`plan-decision` 只支持 `skip`。

于是唯一能满足 CHECK 3 的路径就是手写那三行注释，而门禁只 grep 它们存不存在 ——
**手写即通过**。同一形状还有两个洞：标记能活过计划重写（上个月的审查满足今天的计划）；
审查结论是 FAIL 也照样过。

新增 `bin/agent-gates-plan-review`，照 `verify-import` 的形状：
- 来源必填（`--model <provider/model>`），无来源的产物看着像证据、实际什么都没证明
- **拒绝代填判定**：审查正文没有 `VERDICT:` 行就 exit 3
- 锚点由工具算（`PLAN_REVIEW_SHA256`，哈希排除标记自身，否则写入标记就把自己的锚点作废）
- 异构判定 fail-closed：族不可解析记 `L0`，绝不记 `L1`

CHECK 3 现在真的读这些标记：锚点失配 → 拦；结论非 PASS → 拦；L3 机器上的 `L0`
（同族自审）→ 拦。⚠️ 旧标记（无哈希无结论）仍然通过、只告警 —— 每个已部署仓库都是那个样子，
改成硬失败会让它们下一次提交全部撞墙。

### Fixed — 模型探测没有超时，导致模型配置从不刷新

`_probe_model` 直接跑 `opencode run --pure -m <model> "say OK"` —— 真实模型调用，
走的正是已知会挂 120–200s 的通道，**每个候选模型一次、且没有超时**。
实测 doctor.sh 卡在 6 分钟、CPU 0%，从未走到写 hetero-check.json 那一步。

可见的症状在别处：`review_models.primary` 长期停在一个已下架的型号，因为唯一能刷新它的路径
既依赖 opencode、又慢到没人跑得完。**一个慢到永远跑不完的维护步骤，和不存在没有区别。**

两个探测都套上硬超时（`HETERO_PROBE_TIMEOUT`，列表默认 20s、探测默认 60s，非法值有兜底 ——
配错不能退化成无超时）。超时按「无法确认」处理，绝不当「可用」：一个无法确认的模型被写成
primary，正是配置指向不可达型号的成因。超时用 `bin/with-timeout.mjs`（杀整个进程组，
只杀直接子进程的话孙子还占着管道、命令替换照样阻塞）；wrapper 不可用时**拒绝执行**而非无超时调用。

### Fixed — `run_oc_serve.sh` T11 是确定性失败，不是 flaky

我之前记它「既有 flaky」，实测**连跑 5 次全失败**。真因：`_oc_serve_start` 用 `&` 后台起进程，
然后健康检查（fake curl 立即成功）让它马上返回，而断言**立刻**读 fake 的日志 ——
后台的 nohup+bash+append 每次都输。后台化是正确的生产行为，是断言假设了一个代码
从未承诺的顺序。改成有界轮询等日志；T7 同形态一并改（它此前只是靠 `oc_serve_ensure`
多做几步碰巧赢了竞态）。

### Fixed — `doctor.sh` 每次运行都在抹掉手工配置

`hetero-check.json` 的写入是固定 heredoc + `mv`，而 `implementer_family` / `pi_models` /
`channels` 在 `doctor.sh` 里出现 **0 次** —— 每跑一次 doctor 就把这三个键静默删掉，
`review-capability.json` 那份 `cp` 同理。

最严重的不是丢配置，是 **`channels.opencode.enabled=false` 被抹掉等于把 opencode 通道
重新打开** —— 那个设置是专门为了让 agent 不再卡在 opencode 审查上才加的。
一个悄悄撤销安全设置的维护命令，比一个大声失败的更糟：设置在所有人的认知里还在，实际已经没了。

改为 `lib/hetero/persist.sh` 的 `hetero_merge_check_json`：doctor 只更新自己拥有的键，
其余原样保留；嵌套对象按键合并（写 `review_models.primary` 不会带走 `panel_pool`）；
目标文件是坏 JSON 时**拒绝覆盖并报错**（那通常是人手工编辑写坏的，里面仍有他要的内容）。

⚠️ 附带查明的一件事：doctor 的 D6 模型选择走 **opencode** 探测，实测卡 6 分钟仍未写入、
CPU 0%。这解释了为什么 `review_models.primary` 长期停在一个已下架型号 ——
刷新路径既依赖正在退役的 opencode，又慢到没人会跑。本次未改这条路径。

### Added — `agent-gates-status` 显示门禁档位

档位（strict / relaxed / merge-only / off）和 `verify.require_matrix` 现在决定了到底有没有在检查，
而它们**在真的 commit 之前完全不可见**。`off` 最危险：门禁 exit 0、仓库看起来一切正常。
一个在「什么都没审」时还打印 "All current." 的 status，回答的是错的问题。

新增 `gate mode` 行：显示 review / verify 各自档位 + 配置来源 + 需求矩阵是否强制；
任一侧被关闭或矩阵被显式关闭都计入 needs attention。
配套一条测试断言 **status 与门禁对同一份配置判定一致** —— 两边分叉会让 status 变成一个自信的骗子。

### Fixed — bash 3.2 与 errexit 两处自伤

- `${1^^}` 在 macOS 自带 bash 3.2 是运行时 bad substitution，两个 rank 都成空串，
  `[[ "" -ge "" ]]` 被当成 `0 -ge 0` 为真 → **保留了模型那个宽松的 PASS**，
  正好是 E4 要防的方向。改用 `tr`，并对空 rank 偏严兜底。
- `X=$(printf … | grep -v '^$' | head -1)`：列表为空时 grep 返回 1，`pipefail` 把管道
  状态变成 1，赋值语句本身非零，`set -e` 静默杀掉门禁 —— 输出只有横幅、exit 1，
  16 个无关测试报「期望 exit 0」而输出看着完全正常。

第二条暴露了测试口径问题：**lib 测试跑在 `set -uo pipefail` 下，而调用它的门禁开着 `-e`**，
这一类错误测试根本抓不到。已补一整节在 `set -euo pipefail` 下复跑每个公开函数、
断言输出未被截断（注入变异验证过不是空过）。

## v2.8.0 — merge-only 级别 + review/verify 各自分级

### Added — `merge-only`：小分支上完全不审

`relaxed` 仍要求每次 commit 审一次，迭代时那也是负担。`merge-only` 把审查/验收
**整体推迟**到工作进入集成分支的那一刻。

| mode | 小分支上的 commit | 合并进 strict 分支 |
|---|---|---|
| `strict` | review + verify 都强制 verdict | 同左 |
| `relaxed` | 各审一次，不看结论 | 强制（strict_branches 覆盖）|
| `merge-only` | **完全不审** | 强制 |
| `off` | 不检查 | 不检查 |

⚠️ **`merge-only` 只放宽 review/verify**。Gate 1（对应测试文件必须存在）与 CHECK 3
（plan）照常执行——那两条是**写代码时**的纪律，与审查时机无关。有断言钉住这一点。

### Added — review 与 verify 各自设级别

审查（读代码）与验收（确认真的跑起来）是两件事，严厉度不必一致：

```json
{
  "mode": "merge-only",
  "review": { "mode": "relaxed" },
  "verify": { "mode": "merge-only" },
  "strict_branches": ["test", "master", "main", "release/*"]
}
```

未指定的分项继承总 `mode`（向后兼容）。env 同样分三个：`AGENT_GATES_MODE` /
`AGENT_GATES_REVIEW_MODE` / `AGENT_GATES_VERIFY_MODE`。
strict_branches 覆盖时**三个一起**变 strict。

### Changed — 配置读取改用 python3

`review.mode` / `verify.mode` 是嵌套路径，而用正则扫嵌套 JSON 正是「从错误的对象里
取到值」的经典来源。改为按点分路径精确取值。

### ⚠️ 一个仍未解决的设计问题（记录在此，等决策）

核实发现：**CHECK 6「验收」目前实质是第二次代码审查**——
- 触发条件与 CHECK 5 几乎相同（`LOGIC_FILES>1 && DIFF_LINES>50` / `MAX_SINGLE_FILE_LINES>150`）
- 产物三条来源（harvest / import / 手写）全都是「让模型看代码」
- `grep -rilE 'playwright|puppeteer|browser|e2e|selenium' bin/ lib/ hooks/` **一处真实机制都没有**

也就是说同一份改动被两个几乎一样的检查各审一遍，这正是「反复审了 5 轮」的结构性来源。
真实端到端在 commit 时做不到（端到端要先部署、部署要先 commit、commit 要先 verify），
当初就是用「再审一遍代码」顶了这个位置。

两条路待定：**verify 改为只接受真实运行证据**（测试报告 / E2E 结果 / 部署后验证，
天然只在合并进集成分支时要求），或**承认 verify 是第二道审查**、只做分级。
本版把分级能力做好，对两条路都是前置。

## v2.7.0 — 门禁分级：迭代时宽松，进集成分支时严格

**起因**（2026-09-01）：审查成了瓶颈而非开发本身——一个改动被反复审了 5 轮。
门禁对「业务分支上的一次 commit」和「合并进 test/master」施加同等严厉度，
于是每次迭代都付全额代价。

模型：**在业务分支上迭代时宽松，在工作进入集成分支的那个边界上严格。**

### Added — 三种模式

| mode | 语义 |
|---|---|
| `strict` | 默认。强制 verdict，即 v2.6.x 之前的行为 |
| `relaxed` | 产物必须**存在**且锚定当前 diff，但**不强制其结论**——「审过一次，成败都放行」 |
| `off` | 不做任何检查，**并且大声说出来**，绝不静默 |

⚠️ **`relaxed` 不等于 `off`**：「审过一次但不看结果」仍然要求审查真的发生过、
且锚定到这次改动。否则两种模式就是同一件事的两个名字。完全没审的改动在
relaxed 下**照样被拦**。

配置解析顺序（先命中者生效）：

```
AGENT_GATES_MODE  →  .agent/gates.json  →  $AGENT_GATES_DIR/gates.json  →  strict
```

```json
{ "mode": "relaxed", "strict_branches": ["test", "master", "main", "release/*"] }
```

项目级覆盖用户级；env 覆盖两者，便于单次提交临时切换。

### Added — `strict_branches`：严格性落在边界上

在这些分支上、以及**合并进这些分支时**，无论配置什么都强制 `strict`。
默认 `test` / `master` / `main`，支持 glob（`release/*`）。

这就是「业务分支合并进 test、master 之前要求一次全面审查」的落点。

### Fixed — merge 不再被无条件跳过

```bash
# 此前：agent-quality-gate.sh:10
git rev-parse MERGE_HEAD &>/dev/null 2>&1 && exit 0
```

merge 曾被无条件放行——而那恰恰是最该全面审查的时刻：工作正在进入集成分支。
现在只在**目标分支不是 strict 分支**时才跳过（业务分支之间的合并不卡）。

### Changed — gate 会说出自己在什么模式

非 `strict` 时打印 `ℹ️ Agent Quality Gate mode: <mode> (from <来源>)`。
一个悄悄改变严厉度的门禁比严格的门禁更糟：没人能判断一次提交为什么通过了。
`relaxed` 放行时也明说「⛔ 这是宽松放行，不是通过；合并进 strict 分支会重新全面审查」。

### Fixed — 测试里的硬编码时间戳（4 个文件）

`touch -t 202608261358.57` 这类绝对时间戳会随日期漂移失效：CHECK 6 只看
`-mmin -240`（4 小时），写死的 8-26 到 9-01 就全部掉出窗口，测试于是走了完全
不同的分支并给出误导性的失败。改用 `touch`（当前时间，且一次 touch 多个文件
天然 mtime 相同，「fresh worktree 全同 mtime」这个形状照样能造）。
⚠️ `run_gate_verify_select.sh` 的 V2 是**相反**的场景（需要 mtime 有差异），
单独用 `sleep 1` 跨过秒级粒度，注释里标清了两类场景的区别。

## v2.6.1 — 层1：子进程「存在」不等于「在干活」

外部反馈（2026-08-31）报了一批 jest 进程：**测试全部跑完、结果 3.6 MB 已落盘
（345 套件 / 8037 用例），但进程永不退出**。原因是测试代码留下未关闭的 handle
（`TCP 127.0.0.1:7777 (LISTEN)` + 5 个 ESTABLISHED + PIPE/KQUEUE），Node 事件循环
因此拒绝退出，而这批命令**一个都没带 `--forceExit`**。它们此后 CPU 恒为 0。

jest 本身不属于 agent-gates，但它**削弱了 v2.2.0 引入的三层判据**：
`serve_has_working_children` 只检查「有没有非 lsp 子进程」，于是一个跑完不退的
jest 会永久充当「在干活」的证据 ⇒ **那个 serve 永不回收**。

⚠️ 这正是本文件注释自己警告过的替换——*judge whether the business entity is still
alive, not whether some parent or socket still exists*——却在层1 的实现里又犯了一次：
**用「存在」代替「在干活」**。

### Fixed
- 层1 现在要求至少一个非 lsp 子进程**真的在消耗 CPU**：取两次 cputime 采样求差。
  `ps -o pcpu=` 不能用——它是生命周期均值，对「跑完后挂住」的进程仍显示历史占用
- 采样成本只在**确实存在子进程**时才付（新增 `OC_REAPER_CHILD_WINDOW`，默认 1 秒）
- ⛔ 每个未知都保守处理：子进程采样中途消失、或 cputime 读不到 → 当作在干活、保留 serve

新增 L1c（闲置子进程不再阻止回收）/ L1d（活跃子进程仍然保护 serve，不能误杀在跑的测试）。

## v2.6.0 — 补上 dispatch 与 CHECK 6 之间的那段断链

### 缺口（2026-08-31 反馈）

`hetero_dispatch` 只写 `<run-id>.evidence.json` + `<run-id>.dispatch.json`。
CHECK 6 读的是 `.agent/verify/*.md`，并以**裸行** `^VERIFY_VERDICT:` 锚定。
`grep -rn VERIFY_VERDICT lib/ bin/` 在此版本之前**一处都不命中** —— 也就是说
中间从来没有任何官方步骤把 evidence 变成 `.md`。

于是走这条路的人只能**手工补 `.md`**。而手工写 `.md` 就是手工写 verdict——
**那正是伪造判定的入口**。反馈者这次是逐字转写并主动说明了，但机制不该逼人这么做。
⇒ 一个迫使人伪造的缺口是设计缺陷，不是使用者的问题。

### Added — `agent-gates-verify-harvest <run-id>`

```bash
agent-gates-verify-harvest 20260831-120000-abc123 [--result <file>]
```

- 按 `dispatch.json` 里的 `channel` 决定怎么解析 evidence：`opencode` 是 NDJSON
  （`obj["part"]["text"]`），其余通道是模型 stdout 原文。⚠️ 两者扩展名都叫
  `.evidence.json`，所以靠 channel 判断而不是嗅探内容
- **verdict 取自模型自己的输出**。工具只做机械改写：`VERDICT:` → `VERIFY_VERDICT:`，
  以及 review 词表 → CHECK 6 词表（`ISSUES`/`REVISE` → `FAIL`）。**原始结论行逐字
  记进产物**，所以转写可核对而不是靠信任
- ⛔ evidence 里没有结论行 → **拒绝**（exit 3），并提示去 prompt 里要求结论行。
  工具不代填：reviewer 没说过的结论就是伪造
- ⛔ evidence 为 0 字节（通道挂了）→ 拒绝（exit 4），并明确写出「不要手写 .md 绕过」
- 产出的 `VERIFY_VERDICT` 是**裸行无装饰**——CHECK 6 的 `^VERIFY_VERDICT:` 对
  markdown 零容忍，而模型常输出 `**VERDICT: PASS**`，装饰在这里被剥掉

`hetero_dispatch` 现在会在派发后打印 evidence 路径与这条 harvest 命令，
并写明「⛔ 不要手写那个文件」。

### Changed — `parse_opencode_json` / `has_valid_conclusion` 提取到 lib

移到 `lib/hetero/conclusion.sh`，review 与 verify 两侧共用同一份实现。
`lib/hetero/select.sh` 早就在用 `declare -f` 探测这两个函数，那本身就是它们该在
库里的信号。`agent-gates-review` 现在 source 它，**库缺失时 fail-closed 退出 69**——
静默缺失的结论检查会把任何输出都当成合格审查。

新增 `extract_conclusion_line`（取原文，供核对）、`extract_verdict_value`（剥装饰取值）、
`map_verdict_to_verify`（词表映射）。

## v2.5.1 — verify-import 读不到配置

`agent-gates-verify-import` 只 source 了 `family.sh`，没有 source `config.sh` 并调
`hetero_load_config` ⇒ `implementer_family` **只认 env**，读不到
`hetero-check.json`。实际使用中该变量不会被设置，于是 capability 永远落
`EVIDENCE_ONLY`、高风险路径永远降级 INCOMPLETE、用户每次都要签 ACK——
正是这一系列工作要消除的问题。

与 `af4c6c8` 修的是同一个坑，在新命令里又犯了一次。**单元测试全部显式
`export` 了那个变量，所以一条都没暴露；只有端到端跑真实流程时才发现。**

新增 V7/V8：配置文件里的 `implementer_family` 生效、env 仍优先于配置。

## v2.5.0 — verify 侧补上 CLI 入口

### Added — `agent-gates-verify-import`

CHECK 6 要的是 `VERIFY_VERDICT` 文档 + `staged_diff_hash` 锚定当前 staged 的 dispatch
记录。而 `agent-gates-review --route paseo` / `--import-result` 产出的是 `REVIEW_*` 形状。
⇒ 在自动 verify 通道不可用的机器上，**根本没有官方路径能产出合规的 verify 产物**，
agent 只剩两个选择：手写 `dispatch.json`（伪造一次从未发生的派发）或者停下。

2026-08-26 一个会话正确地两个都拒绝、停了下来，后面压着一个真实的提交。这个缺口
本身就在**诱导造假**——它是 P0「为不存在的 agent 记 FULL」的同一个病因：没有合法
路径时，就会有人去拼一条。

```bash
agent-gates-verify-import <body.md> --imported-model <provider/model> [--result <file>]
agent-gates-verify-import <body.md> --paseo-agent <agent-id>          [--result <file>]
```

**它刻意不做的三件事**：
- ⛔ 不声称用过没用过的通道——**来源必须显式声明**，二者给一个
- ⛔ **锚点绝不接受调用方传入**，`HEAD` 与 `staged_diff_hash` 都在这里计算。
  这正是「导入外部审查」与「伪造回执」的分界：工具算出的锚点证明的是
  「导入时刻 staged 的内容」——一个它能确立的事实；而手填的 hash 什么都不证明
- ⛔ 不代填结论。正文里没有 `VERIFY_VERDICT` 行就拒绝（exit 3）

`capability` 与 `hetero_dispatch` 同一套语义：只有评审模型族**可证不同于**声明的
实施族才给 `FULL`，未声明或解析不出一律 `EVIDENCE_ONLY`（fail-closed）。
`--paseo-agent` 时向 Paseo `inspect` 问模型，而不是相信参数；问不到就记
`paseo_verified: no`。

测试 `tests/run_verify_import.sh`（18 断言），其中 V5 是端到端：导入后真的跑 gate，
确认 CHECK 6 不再报「无对应 verify」「改动超限」「缺 VERIFY_VERDICT」。

## v2.4.2 — CHECK 6 在新 worktree 里的两处误判

现场（2026-08-26，crm-center 的新 worktree）：28 份 verify 文档、mtime **全部相同**
（`git worktree add` 的 checkout 时刻）、23 份带 `staged_diff_hash`、**0 份锚定当前改动**。
报错是：

```
❌ Significant changes (115 lines) made AFTER verification — re-verify required
```

**这个报错指向了完全错误的方向**——听起来像「你改太多了」，实际是「它随机挑了一份
跟这次改动无关的旧 PASS 来比」。两处独立缺陷叠加：

### Fixed — 「一份都没锚定」不等于「回落 mtime 猜一个」

v2.4.0 让锚定命中优先，但**无匹配时仍回落 mtime**。两种情况被混为一谈：

| 情况 | 含义 | 现在 |
|---|---|---|
| 有 `staged_diff_hash` 但全不匹配 | **可判定：这次改动没有 verify** | 明确报错，不猜 |
| 无 `staged_diff_hash`（旧产物） | 不可判定 | 回落 mtime（兼容） |

新报错带诊断：候选份数、其中多少可判定，以及「这 N 份 mtime 全同——典型的新建
worktree，此时『按 mtime 选最新』本就是任意挑一个，所以不猜」。

⚠️ 「可判定」要求**真的有 `staged_diff_hash` 字段**，不是「有 dispatch.json 就算」。
只带 `channel`/`capability` 的旧记录无法锚定，把它们算作可判定会把「没有 hash 可比」
变成「等于没验证」——这样写会打掉 16 条既有断言。

### Fixed — 锚定命中后不该再被 mtime 推翻

`PASS` 分支的新鲜度检查比较「源文件 mtime vs verify 文档 mtime」，超过 20 行就拦。
但 `git worktree add` 让**每个源文件都比每份 verify 文档新**，于是全部改动被算作
「验证后的」。而锚点命中意味着 staged 内容与验证时**逐字节相同**——「验证后改了吗」
已经有答案了：没有。

⇒ 锚定命中时跳过 mtime 比较。**强证据不该被弱证据推翻**；mtime 只在没有锚点可比时
才是唯一信号（此时报错会附一句说明用的是 mtime 判据）。

## v2.4.1 — 堵住绕过 opencode 通道开关的那条路

v2.4.0 把 opencode 通道默认关了，但**只有 `hetero_dispatch` 会看那个开关**。
`oc-review` 是独立入口：agent、skill 或习惯直接调它，就完全绕过了这个决定——
起一个共享 `opencode serve`，然后阻塞整个 `AG_REVIEW_TIMEOUT`。会话继续反馈
「审查卡住导致任务无法进行」，而通道名义上是禁用的。

### Fixed
- `oc-review` 在 opencode 通道被显式禁用时**立即拒绝**（exit 69 `EX_UNAVAILABLE`），
  在碰到 serve 之前就返回。实测 **0 秒**返回，对比之前挂满超时。
  报错直接给出替代命令与恢复方式，而不是只说「失败了」：
  ```
  Use instead:  pi -p --provider <provider> --model <model> "<prompt>"
  Re-enable:    HETERO_CHAN_OPENCODE=1, or channels.opencode.enabled=true
  ```
  env 优先于配置，与 `config.sh` 同一套优先级。**没有配置文件时不拦**——
  这道守卫只执行「显式禁用」，默认值仍由 dispatch 自己决定
- `AG_REVIEW_TIMEOUT` 默认 **300s → 120s**（三处：`oc-review`、
  `agent-gates-review`、`lib/hetero/select.sh`）。五分钟才浮出水面的挂起，
  读起来就是「门禁坏了」；而 pi 对同一任务约 7s 返回，120s 对正常审查够用

### Added
- `tests/run_oc_review_guard.sh`（10 断言）。**fake 的 opencode 会 sleep 300** ——
  守卫失效时测试会超时而不是静默通过，所以「快速拒绝」是可证的而非假设的

### Changed
- `tests/run_oc_review.sh` 显式 `export HETERO_CHAN_OPENCODE=1`：它测的就是
  oc-review，这个依赖应当写出来而不是继承本机配置

### 同期改的（不在本仓）
审查工具优先级已在指令层同步调整——**agent 读到的东西才决定它调什么**：
- `agent-review-protocol/SKILL.md` §8：pi 升为首选，opencode 降到第 3 并标注原因
- `agent-workflow-rules/SKILL.md`：路由描述改为 `pi → codex → codebuddy`
- 全局规则 `30-delegation.md`：工具优先级同步，并写明「撞到 opencode 超时不要收窄
  prompt 重试——极小 prompt 也超时」

## v2.4.0 — opencode 不再是默认审查通道

⚠️ **行为变更**：`opencode` 通道默认关闭。六通道顺序实际变为
`paseo → pi → codex → codebuddy → echo-fallback`，opencode 需显式启用才参与。

### 为什么

实测它作为审查通道反复超时，而这直接堵住开发：

| 路径 | 结果 |
|---|---|
| `agent-gates-review`（走 opencode 通道） | 120s 超时，**极小 prompt 也一样** |
| 手动 `opencode run --pure --attach` | 200s 超时 |
| `pi -p`（同一审查任务） | **~7s 返回，evidence 立即可得** |

它还需要常驻 `opencode serve`：实测一个跑了 **4 天、烧掉 133 分钟 CPU、机器上零客户端**，
而 `KEEP_PORT` 豁免让 reaper 永不回收（v2.3.0 已加超龄回收）。多个会话连续反馈
「审查卡住导致任务无法进行」——**卡点在审查，不在开发**。

### ⛔ 不是删除

通道代码完整保留，别人可能仍依赖它。恢复只需一个开关：

```json
{ "channels": { "opencode": { "enabled": true } } }
```

或 `HETERO_CHAN_OPENCODE=1`（env 优先于配置）。`agent-gates-review --route paseo`
与 `--import-result` 是独立路径，不受影响。

### Changed
- `_hetero_resolve_chan` 新增第三个参数（per-channel 默认值），签名
  `_hetero_resolve_chan <env_var> <channel> [default=1]`。仅 opencode 传 0
- `dispatch.sh` 里未 source config 时的兜底默认同步改为 0（两处），保持一致
- 测试 `run_hetero_dispatch.sh` / `run_hetero_pi_channel.sh` 显式
  `export HETERO_CHAN_OPENCODE=1`——它们测的就是 opencode 通道，这个依赖应当写出来
  而不是靠默认值

### Added
- `tests/run_hetero_chan_defaults.sh`（7 断言）：默认值、配置可恢复、env 优先、
  以及对称性（默认开启的通道也能被配置关掉）

## v2.3.0 — 审查不再是卡点

起因是真实反馈：「每天没有一个 agent 能跑过，开发不是卡点，审查才是卡点」。
查下来是**五环死锁**，每一环单看都合理：

```
① 审查真的 PASS 了
② 通道给的 capability=EVIDENCE_ONLY
③ gate：high-risk + EVIDENCE_ONLY + PASS → 强制改写成 INCOMPLETE
④ INCOMPLETE 要 USER_ACK
⑤ verify-ack 在 AGENT_MODE=1 时硬性 exit 1
⇒ 用户手工签
```

### Fixed — capability 的评级是反的

`capability` 此前回答「有没有走 paseo 通道」，而 paseo 分支**硬编码
`--provider claude/opus`**。主会话本身就是 Claude ⇒ **唯一能拿 FULL 的通道
派的是同族评审（自审）**；而 pi / opencode 明确配了异构模型，永远只能拿
EVIDENCE_ONLY。它还与 `_paseo_verify_agent`（要求被核实 agent 的 `Provider`
非 claude）自相矛盾——dispatch 派的就是 claude，所以 paseo 的 FULL 从来没
真正работ过。

现在只回答一个问题：**dispatch 层是否记录了一个模型族可证不同于实施族的评审方**。
三个通道共用 `_hetero_capability_for`。

⚠️ **边界写清楚，不要读成安全保证**：`HETERO_IMPLEMENTER_FAMILY` 与评审模型 id
**都由调用方自报**，工具只比对两个字符串的族归属，既不验证审查正文真出自该模型，也
无法锚定实施族的真实性。对一个决心伪造的 agent，这一层是 fail-open——旧的 FULL 同样
如此（它甚至连族都没比）。它防的是「配置错了/图省事」，不是恶意。真正的兜底仍然是
锚点时序（审查期间 staged 未变）与 ⛔ 伪造禁令。

### Fixed — ack 门控从「谁签的」改成「是否如实」

`verify-ack` 不记录、也无法记录签署者身份（能运行它的人就能设任何环境变量），
所以卡 `ASK_USER_CONFIRMED` 没有证明力，只换来用户必须亲手签。v2.1.0 的文档
已改口径说「agent 可以代跑 ack」，**但代码里这道拦截一直在**。

- `AGENT_MODE=1` 且无 `ASK_USER_CONFIRMED` ⇒ 必须显式给 reason，因为默认
  reason（"user confirmed"）在 agent 代签时是假话
- `.ack` 新增 `signed_by: human|agent`，产物自己说清
- ack 时效改为可配（`AGENT_GATES_ACK_TTL`，默认仍 14400）

### Added — 异构判定改为族级，不绑任何具体 provider

新增 `lib/hetero/family.sh`。provider 会变（opencode 要卸载、订阅会换、新厂商
会加），不变的只有「评审族 ≠ 实施族」。

- 解析前剥掉 provider 前缀：族是模型的属性，不是谁在提供它。
  `github-copilot/gpt-5.4` 与 `azure/gpt-5.4` 同为 openai；
  `volcengine-coding/deepseek-v4-flash` 与 `volcengine-chat/…` 同为 deepseek
- 内置 14 个族的规则，可在 `.agent/hetero-check.json` 的 `model_families`
  覆盖或新增（配置优先于内置）
- 新增 `HETERO_IMPLEMENTER_FAMILY`（调用方声明实施族）、`HETERO_PASEO_MODEL`
  （paseo 通道模型可配，默认仍 claude/opus）
- ⛔ fail-closed：族解析不出来时永远不满足「不同」。否则任何不认识的 model id
  都能静默通过异构要求

### 交叉审查（deepseek-v4-flash）报了 8 条，3 条为真缺陷已修

放宽门禁必须自己先被审。异构审查报了 8 条绕过点，核实后 3 条属真缺陷：

| # | 缺陷 | 修法 |
|---|---|---|
| 3 | `.agent/hetero-check.json` 在**被审查 agent 可写**的工作树内，且优先于 home 配置 ⇒ 写一行 `{"model_families":{"claude-*":"openai"}}` 就能把同族自审说成异构、直接拿 FULL | 配置源按可信度分级：home（用户控制）可覆盖内置；**仓库内配置只能为内置认不出的 id 补充族，不得改写已知族** |
| 7 | `ASK_USER_CONFIRMED=1` 是 agent 自己能设的 env，却被用来豁免 reason 要求；`signed_by` 字段**写了却没人读**，纯装饰 | AGENT_MODE 下一律要 reason，该 flag 只影响记录的 signer；gate 侧读 `signed_by`，agent 代签时显式打印签署方与理由 |
| 8 | `AGENT_GATES_ACK_TTL` 从 env 读，设极大值等于退役时效检查 | 加硬上限 24h，非数字回落默认值 |

另 5 条未采纳，因为它们描述的是**已声明的设计边界**而非隐藏漏洞：实施族与评审模型 id
都是自报（#1 #2 #5）、ack 的理由无真实性校验（#6）、通配规则可让 family 永不 unknown
（#4，但两边同族仍会被拒，单独不构成绕过）。这些已在上面的边界说明里写明。

### 选型口径：工具只校验异构，具体模型交给调用方

工具**不推荐、也不硬编码**任何特定模型。原则是：优先 gpt-5.5 及以上；没有就用
任何满足异构的模型；`deepseek-v4-flash` 性价比很高，推荐使用，**前提是先过异构
校验**。capability 降级时会明确打印缺什么，而不是静默降级。

### ⚠️ 这次改动对 ack 需求的净效果

单看 capability 那条改动，**ack 会变多**——同族自审从 FULL 降成
EVIDENCE_ONLY，高风险路径因此需要 ack。这是有意的：同族自审本来就不该算最高等级。

净效果取决于配置。配好之后高风险路径直接 FULL、无需 ack：

```bash
export HETERO_IMPLEMENTER_FAMILY=anthropic                     # 主会话是 Claude
export HETERO_PI_MODEL=volcengine-coding/deepseek-v4-flash     # 异构评审方
```

没配好也不再阻塞——agent 可以自己签 ack，只要说清用户授权了什么。方向是把
「绕过门禁」换成「配置正确就直接通过」。

## v2.2.0 — pi 通道 + oc-reaper 三层空转判据

两件事都源自 2026-08-20 的一次现场：机器可用内存掉到 70MB、load 14.6，三个
`opencode serve` 各烧 52-86% CPU 而手上零活，`oc-reaper` 却报 `0 reapable, 7 kept`。

### Added
- **`pi` 通道**，排在 paseo 之后、opencode 之前。六通道顺序变为
  `paseo → pi → opencode → codex → codebuddy → echo-fallback`
- 新 env / 配置：`HETERO_PI_MODEL`（`<provider>/<model>` 格式）、`HETERO_BIN_PI`、
  `HETERO_CHAN_PI`，以及 `hetero-check.json` 的 `pi_models.primary`
- `tests/run_hetero_pi_channel.sh`（13 断言）、`tests/run_oc_reaper_layers.sh`（16 断言）

### 为什么 pi 排在 opencode 之前
`pi` 是 one-shot——`--help` 里没有 serve / daemon / port 任何子命令，`-p` 处理完即退出。
`opencode` 需要常驻 `opencode serve`，而 Paseo 驱动它时**每个 agent 起一个独立 serve**，
实测 1-1.5GB RSS 且 agent idle 后不回收。实测对比（含 bug 的 JS + 要求结论行）：

| 通道 | 耗时 | 峰值 RSS | 跑完残留 |
|---|---|---|---|
| pi `github-copilot/gpt-5.4` | 29.9s | 197MB | 零 |
| pi `volcengine-coding/deepseek-v4-flash` | 12.7s | 216MB | 零 |
| opencode 共享 serve `:4096`（`--attach`） | — | 619MB 常驻 | 1 个，受 oc-review 管 |
| opencode Paseo 托管 | — | 1-1.5GB / 个 | 不回收 |

⚠️ **注意区分**：共享 serve 那一行是**健康**的（3h10m 均值 5% CPU）。烧机器的从来不是
「用 opencode 审查」，而是「每次调用新起一个 serve」。`oc-review` v1.13.0 的 `--attach`
已经消掉了 per-run 堆叠——绕过它的调用**跑一次就漏一个 1GB serve**，与调用频次无关。

### Changed
- `HETERO_PI_MODEL` 未配置时**静默跳过该通道**，不给默认值：加通道不能悄悄改变既有路由。
  `config.sh` 也刻意**不**回退到 `review_models.primary`，否则所有已配 reviewer 的安装
  都会被自动切到 pi
- 模型缺 provider 前缀（无 `/`）→ 报错跳过，不猜。pi 的 `--provider` 与 `--model` 是两个
  独立参数，必须显式拆分
- pi 通道 capability 仍为 `EVIDENCE_ONLY`。`FULL` 是 paseo 专属语义（可核实的异构 agent
  身份），pi 给不出；输出契约与 opencode 通道一致——stdout 落进 evidence 文件

### Fixed
- **`oc-reaper` 的空转判据从全局门控改为 per-serve 三层判定。** 原 `spin_check_allowed()`
  只要 Paseo 上有**任何一个** opencode agent 处于 running，就对**所有** Paseo 托管的 serve
  关闭空转检测。现场把 `OC_REAPER_SPIN_CPU` 降到 30 仍是 `0 reapable`，证明挡住它的是门控
  本身而非阈值。新判据：

  ```
  层1  有工作子进程（排除 lsp-daemon）        → 在干活，任何 CPU 都保留
  层2  无工作子进程 + CPU 低                  → 空闲无害，保留
  层3  无工作子进程 + CPU 高 + 主线程 ≥95%
       采样卡在 kevent64                      → 才判 GC 空转
  ```

  三层都不能省。**层1 不能省**：等 jest 子进程返回的 serve 主线程同样 100% 卡在
  `kevent64`，与 GC 空转无法区分——「主线程 kevent64 即空转」这条判据**单独使用是错的**，
  当天差点据此杀掉一个已跑 40 分钟的测试。**层3 不能省**：纯 JS 重计算也符合「无子进程 +
  高 CPU」，只有采样能区分 GC 与 JS（实测一个 100% CPU 的 `yes` 被层3 正确挡住）。
  `sample` 缺失或失败一律保留——无法证明就不动手。新增 `OC_REAPER_SPIN_IDLE_PCT`（默认 95）、
  `OC_REAPER_SPIN_SAMPLE_SECS`（默认 2）
- **`oc-reaper` 不再清掉 agent-gates 自己的共享 serve。** `KEEP_PORT` 原为
  `${OC_REVIEW_PORT:-}`，默认空；该变量平时不设置，于是 reaper 认不出 4096 需要保护，把
  `lib/hetero/serve.sh` 那个「存在目的就是消除 per-run 堆叠」的持久 serve 当泄漏回收
  （实测 age 38051s 被清）。现与 `serve.sh` 完全对齐为
  `${OC_SERVE_PORT:-${OC_REVIEW_PORT:-4096}}`，命中时**显式打印一行**而非静默计入 kept
- `tests/run_oc_reaper.sh` 两处断言缺陷：4 处用 `grep ':<port>'` 判断是否被回收——端口号
  出现不等于被回收，新增的 `[keep]` 行同样含 `:<port>` ⇒ 误判；`0 reapable` 是全局计数，
  机器上有其他 opencode serve 时必然失败（实测 1/3 概率），现改为检测到非测试 serve 时
  **显式跳过并说明**，不静默弱化断言

### v2.1.0 的一条「已知限制」已失效
v2.1.0 记「工具不能自己派本机 Paseo，`paseo run` exit 0 但 agent 根本没创建」——**归因错了**。
真因是 `~/.local/bin/paseo` 那条软链指向了 Paseo.app 的**主 APPL 可执行文件**；官方包装器
`Contents/Resources/bin/paseo` 会先进 `Paseo Helper`，走它 `run -d` **可以正常创建 agent**。
软链已修正（2026-08-17）。`dispatch.sh` 里检测 `.app/Contents/MacOS` 就跳过 paseo 通道的守卫
仍然保留——它防的是「给从未存在的 agent 记 FULL」那种假通过。

## v2.1.0 — 外部审查导入通道（Paseo 子会话）

v2.0.2 把审查失败的**报错**说清了，但**可用通道**没变多。两条通道同时不可用时（自审 dogfooding 就撞上：共享 serve 死 + codex 超时），agent 没有任何合法路径产出审查证据——手工填锚点绕掉的正是「审查前捕获、审查后校验」的时序保证，所以被明令禁止。

本版补上这条路径：**派发交给调用方 agent，锚点仍由工具掌管**。

### Added
- `--route paseo --dispatch-out <file>`：捕获锚点 + 把 prompt 复制成**不可变快照** + 写 pending 目录 + 输出派发请求，退出码 **77**（新增：需外部派发）。请求里带 `requirements` 块（结论行格式、异构要求），抄进子会话 prompt 即可
- `--import-result <md> --token <t> --paseo-agent <id>`：**整目录原子 claim** → 校验链 → 写产物。产物格式与其他通道完全一致（`REVIEW_TOOL: paseo` + 三个锚点），**gate hook 无需任何改动**
- `paseo agent inspect <id> --json` 来源核实：agent 存在、`Provider` 非 claude、`CreatedAt` 晚于派发时刻
- 新 env：`AG_REVIEW_PASEO`（paseo 二进制）、`AG_REVIEW_PASEO_TTL`（token 有效期，默认 7200s）、`AG_REVIEW_PROCESSING_STALE`（崩溃残留阈值，默认 3600s）
- `tests/run_review_paseo_channel.sh`（27 用例）

### 这条通道保证什么、不保证什么
**保证**：staged diff 在派发与导入之间未变；reviewer 拿到的是派发时快照的 prompt；确实存在一个 provider 非 claude、创建于派发之后的 Paseo agent；token 只能用一次。
**不保证**：⛔ **不证明审查正文出自那个 agent**（调用方可真派一个异构 agent 却提交自己写的正文）；token 不是授权凭据，它在 agent 可写目录里；锚点只覆盖 **staged diff**，未 staged 改动、untracked 文件、依赖版本、运行态都不在范围内。完整表述见 `docs/plans/2026-08-13-paseo-review-channel.md` §4

### 实现上值得记的几处
- **pending 记录用目录而非平行文件**：claim 必须原子，而目录 rename 是原子的、两个文件的 rename 不是。早先的 `<token>.json` + `<token>.prompt` 布局在 claim 时只搬走记录，快照会永久堆积
- **不可恢复的校验排在可恢复的之前**：锚点已变时若先撞上 agent 核实失败，token 会被移回 pending，引来永远不可能成功的重试
- **`CreatedAt` 解析失败按拒绝处理**：条件式放行等于在 Paseo 改格式时静默放过来源不明的 agent
- **崩溃残留按目录 mtime 判定**，不按 `record.created_at`——后者会让长时间 pending 的记录一 claim 就被回收
- **来源核实用 `inspect` 不用 `ls`**：`ls --json` 的 `created` 是相对时间串（`"4 minutes ago"`）无法判定先后，且 `ls` 与 `inspect` 的字段名与结构都不同。`inspect` 对不存在的 id 也 exit 0，缺失只能从 payload 判断

### 已知限制
- 工具**不能自己派本机 Paseo**：`paseo run` 会尝试拉起 Electron，exit 0 但 agent 根本没创建（前台 / `-d` / `--host` 三种模式实测一致）。派发只能由 agent 走 MCP `create_agent`
- 跨 provider `create_agent` 不能继承 `bypassPermissions`，必须显式传 mode

### 门禁不再卡死自己人（口径变更）

真实反馈：并发开发多条线时，门禁成了阻塞项——一条 CRM 任务在 verify 上耗了两天，而卡它的三件事全是 agent-gates 自己的缺陷。

- **「伪造证据」与「用户授权放行」拆成两类。** 前者永远禁止（手填锚点、改 verdict、编报告、不带 `AGENT_MODE=1` 偷提交）；后者是**合法路径**：用户明确授权时，`SKIP_VERIFY=1` / `SKIP_REVIEW=1` / `agent-gates-verify-ack` 都可以用，agent 也可以代跑 ack。三个条件只关于**如实**：用户真说了、报告写明是授权放行而非通过、待补项写清楚
- **说清 ack 是什么**：gate 对它只校验 diff hash 与 4h 时效，**不记录任何签署者身份**。所以「只有人能签」从来不是技术保证，只是一条纪律，且代价是每次都要人 cd 进目录跑命令。它的实际作用是审计记录
- **点名一个闭环死锁**：verify 可能仅因端到端未做而判 `INCOMPLETE`，而端到端要先部署、部署要先 commit、commit 又要 verify 过。**这个环再努力也出不去**，授权放行就是为它准备的
- **gate 的 INCOMPLETE 提示自己给出放行命令**。旧文案是 "confirm via workflow"——不说跑什么，逼每个 agent 重新推导机制再向用户解释一遍。现在直接打印 `agent-gates-verify-ack <run-id>`、4h 时效与 hash 绑定的注意事项，以及那个死锁的说明

### 通道不强制，只规定证据
- `--import-result` 的 `--paseo-agent` **改为可选**，新增 `--imported-model`。任意通道产出的审查都能导入：opencode CLI、codex、别的 agent、人工看的都行。两者必须给一个，所以不会出现来源完全不明的审查
- 差别只在对来源是否诚实：带 `--paseo-agent` 时工具核实 agent 存在且异构，产物记该 agent；带 `--imported-model` 时记 `REVIEW_TOOL: external` 并把模型标 `unverified`，stderr 同步说明。**锚点保证两者完全相同**——gate 认的是「审查期间 staged 没动」，不是「用了哪个工具」

### Fixed：oc-reaper 对 Paseo 托管的 serve 完全失效
- 判据里「端口上有 ESTABLISHED 连接就保留」排在「有没有真实 `opencode run` 客户端」之前，而 **Paseo 托管的 serve 与 Paseo daemon 之间的连接永不断开** ⇒ 该信号永远为真、serve 永远被保留。实测：两个 serve 存活 **23 小时**，全机零个 `opencode run`，`--apply` 一个也没回收
- 改为先看真实客户端（有则任何年龄都保留），裸连接只在 `OC_REAPER_MAX_AGE`（默认 7200s）以内提供保护，超龄按泄漏处理
- 这与 `agent-resource-lifecycle.md` 记的是同一个错误的又一次复现：**判定该看业务实体还在不在，不是看父进程或 socket 还在不在**

### Fixed：install.sh 自己就是假回执
- `fetch_repo()` **无条件从 GitHub clone main**，`REPO_URL` 是硬编码常量不可覆盖 ⇒ 在本地 checkout 里跑 `./install.sh --upgrade`，装的是远程代码，**本地改动一个字节都装不上**。而横幅那句 `Installer vX.Y.Z` 读的是本地 `.version` ⇒ **显示本地版本号、装远程代码**，还逐行打印 `✓ Installed: bin/...`、exit 0 全绿
- 新增 `--local`：从 install.sh 所在的 checkout 安装。默认（clone）路径下也会打印 `Source: remote ... — use --local to install the checkout you are in`，让来源不再靠猜

### Fixed（verify 侧，与 review 侧同类缺陷）
- 🔴 **`HETERO_OC_MODEL` 此前在 `config.sh` 里完全没有定义** ⇒ `dispatch.sh` 实际执行 `opencode run -m ""`，它**不快速失败而是挂起**，evidence 文件建了但停在 0 字节，调用方一直轮询等一个永远不来的结果。**verify 的 opencode channel 从来就没工作过**，除非调用方碰巧手工 export 过。现在从 `hetero_models.primary` / `review_models.primary` 解析，默认 `github-copilot/gpt-5.5`；空模型时跳过该 channel 并明确报错
- 🔴 **paseo channel 会为不存在的 agent 开出回执**：macOS 上 `paseo` 软链指向 Paseo.app 的 Electron 本体，headless 运行直接 `FATAL: Unable to find helper app`（exit 133）——但 `hetero_spawn_pg` 后台 spawn 从不等退出码，`2>/dev/null` 又吞掉 stderr，于是 `dispatch.json` 照写 `capability=FULL`。现在用 `readlink -f` 探测 `.app/Contents/MacOS` 并跳过该 channel，提示改由 MCP 派发
- 这两条与 v2.0.2 修的 `HETERO_EXHAUSTED` 是同一形状：**检查点存在，但检查的不是真正该检查的东西**；回执写得漂亮，事情没发生

## v2.0.2 — 审查失败可诊断 + 调用超时 + VERDICT 容错

起因：`HETERO_EXHAUSTED: all review models failed` 被用于五种互不相关的失败，其中占比最高的一种是「模型正常答了，但输出里没有行首 `VERDICT:` 行」。这句报错把排查引向通道与版本，2026-08-13 因此产生一次误诊，把根因写成「opencode 1.17.15 的 `--format json` 挂死」——实测四条路径（裸跑 / `--attach` × 带 json / 不带）全部 4~20 秒返回、输出为标准 NDJSON，该结论已证伪。

### Fixed
- **审查失败现在可区分**：五种失败各自单独报行，前缀 `review-fail[<model>]:` —— 二进制缺失 / serve 不健康 / 超时 / 非零退出 / 空输出 / NDJSON 解析空 / 缺 VERDICT 行。缺 VERDICT 时附带模型输出前 200 字符，可直接看出它确实答了。`HETERO_EXHAUSTED` 降为汇总行，保留给既有日志抓取
- **VERDICT 匹配容忍装饰**：`**VERDICT: PASS**`、`## VERDICT: PASS`、`- ` / `> ` 前缀、反引号、缩进、中文冒号 `VERDICT：`、`VERDICT: **PASS**` 全部接受。取值不在枚举内（`VERDICT: OK`）与整段无结论行仍拒。正则改用 POSIX 字符类，不再依赖 GNU 的 `\s`
- **所有外部审查调用套超时**：`select.sh` / `oc-review` / `run_opencode` / `run_codex` 全部经 `bin/with-timeout.mjs`（`AG_REVIEW_TIMEOUT`，默认 300s）。该 wrapper 此前存在但**零调用点**，一个无边界 prompt 曾跑 80 分钟、exit 0、零产出
- **`with-timeout.mjs` 改为杀整个进程组**：只杀直接子进程时，孙子进程继承 stdout 并继续持有管道，调用方的命令替换照样阻塞——超时形同没有。改用 `detached` + `kill(-pid)`，并显式转发 SIGINT / SIGTERM 以保留 Ctrl-C
- **hetero 分支可落回 codex**：该分支原先直接 `exit 75`，`fallback_route` 是死配置。更深一层的原因是 `run_codex` 定义在文件靠后位置、hetero 分支执行时它还不存在；现已包成 `run_hetero_review()` 并推后到所有 helper 定义之后调用。`HETERO_EXHAUSTED` stub 改在 codex 也失败后才写，避免覆盖 codex 的成功产物
- **不可用的回答会换下一个模型**：VERDICT 判定下推到 `_try_review_model`，primary 给不出可用结论时继续试 panel，而不是在调用方终止整条链
- **结论行只承载取值**：原先是前缀匹配（`FAILED` 能当 `FAIL` 用），同一条规则让 `VERDICT: PASS_WITH_ISSUES` 被当成干净通过——**结论被反转**，比判失败更糟；`VERDICT: PASSENGER` 同样能过。仅加词边界还不够：`PASS-WITH-ISSUES` / `PASS.WITH.ISSUES` 会从标点处漏过去（异构审查第二轮抓到）。现在取值显式列出（含 `PASSED`/`FAILED`/`ISSUES_FOUND`/`REJECTED` 等变体），且取值之后只允许装饰符、空白与句末句号直到行尾——与文档要求 prompt 输出的形态一致。带限定词的结论一律判失败并明确报错，不再静默读成 PASS
- **超时包装器的信号处理**：转发 SIGINT / SIGTERM 后**等待进程组真正退出**（3s grace 后补 SIGKILL），而不是转发完立即退出——后者会让忽略信号的进程组继续持有 stdout，正是这个 wrapper 要防的挂死
- **保留 128+signal 退出码语义**：子进程被信号杀死时 `code === null`，原先一律返回 1，调用方分不清「命令失败」与「命令被杀」
- **超时包装器缺失时 fail-closed**：`node` 或 `bin/with-timeout.mjs` 不可用时，`select.sh` / `oc-review` / `agent-gates-review` 一律拒绝执行并明确报错，不再静默退化为无超时运行（与 serve 守卫的 fail-closed 姿态一致）
- 🔴 **hetero 分支会自愈共享 serve**：`_try_review_model` 原先只用 `oc_serve_health_check` **探测**，所以共享 serve 一死，opencode 通道就**永久不可用**——每次审查都落到 codex，而旧版报错完全看不出是 serve 的事。注意这里的不对称：legacy 的 `run_opencode` 一直用的是 `oc_serve_ensure`，**hetero 分支比它取代的那条路更脆弱**。改用 `oc_serve_ensure` 后仍然产出 attach URL 或失败，fail-closed 保证不变。用修好的工具自审时正好撞上这一条
- **`HETERO_EXHAUSTED` 不再重复打印**：`run_fallback_chain` 本身会输出一条，上层无条件再输出一条 ⇒ 同一次失败看起来像两次。改为仅在绕过该路径时补（`panel_mode: off` 直接调 `_try_review_model`，它只报各模型的原因）

### Changed（行为变化）
- 配置里有 `review_models` / `hetero_models` 且 `fallback_route: codex` 时，hetero 模型耗尽后**会额外调用一次 codex**。这是 F4 的目的，但意味着一次失败的审查现在会多花一次 codex 的时间与额度。测试若断言「耗尽即失败」，需要把 `AG_REVIEW_CODEX` 指向不存在的路径（`tests/run_review_cmd.sh` 已按此调整）

### Docs
- README / README.zh-CN 新增 Troubleshooting 子节「审查失败：先看 review-fail 那一行」：五种失败对照表、prompt 结论行模板、接受与拒绝的格式清单、两个「不是原因」的东西（`--format json`、macOS 缺 GNU `timeout`）、以及为什么不能伪造锚点通过
- `skills/agent-review-protocol` 同步同一份处置表；更正其中「`MAX_CHARS` 自动降级」的适用范围——该降级只在 legacy L0-L3 路由生效，hetero 分支不检查 prompt 长度

### Tests
- 新增 `tests/run_review_verdict_diagnostics.sh`：五种失败各自可辨识、VERDICT 格式与限定词用例、超时边界（含「不留孤儿孙子进程」断言）、wrapper 缺失 fail-closed、hetero→codex fallback
- 拒绝类断言不再只看退出码：只断言「非 0 退出」的话，语法错误、`set -u` 未绑定变量、超时都会让用例变绿，实际上已经不再测判定逻辑。现在同时要求报错里出现对应的拒绝原因
- 接受类断言同时要求产物落地（`REVIEW_TOOL` marker 存在），而不是只看 exit 0

## v2.0.0 — hetero-check 异构检查子系统 + Verifier

### Breaking Changes
- `lib/review-selection.sh` → `lib/hetero/select.sh`（shim 保留一个 minor）
- `lib/oc-serve.sh` → `lib/hetero/serve.sh`（shim 保留）
- `review-capability.json` → `hetero-check.json`（`agent-gates-config-migrate` 自动转换）
- `review_models` 字段 → `hetero_models`

### Added
- **Verifier 角色**：`templates/verifier.md` + CHECK 6 gate（四态 PASS/FAIL/QUESTIONS/INCOMPLETE + USER_ACK 方案 A）
- **hetero-check 子系统** `lib/hetero/`：config / discover / select / dispatch / serve / janitor
- **资源生命周期层**：进程组 spawn(setsid/perl) + PGID kill + .draining 回收 + 熔断 + 墙钟 watcher + 归因
- **effort 维度**：`(model, effort)` 二元组，按风险分级
- **opencode fail-closed**：无 attach URL 禁裸跑（防事故 1 复发）
- `bin/agent-gates-verify-ack`：USER_ACK 写入工具（绑 diff-hash + HEAD）
- `bin/agent-gates-verify-strip`：strip agent 输出的 USER_ACK 串
- `bin/agent-gates-config-migrate`：v1→v2 配置迁移

### Fixed
- macOS `pkill -P` 不杀孙进程 → 进程组 `kill -TERM/-KILL -- -<PGID>`
- opencode serve 堆叠 OOM（事故 1）→ fail-closed + 共享 serve
- codebuddy --acp 崩溃循环（事故 2）→ janitor 熔断 + 整树清理
- **审查证据不再使用文件 mtime**：`agent-gates-review` 写入 `REVIEW_HEAD`、逐文件 `REVIEW_FILE`、文件清单摘要与 staged binary diff 摘要，并在审查前后快照变化时拒绝生成有效证据。gate 对 HEAD/未审查文件执行 BLOCK，对覆盖文件的后续字节变化打印 diff 摘要并 WARN 放行；任一适用负 verdict 优先。旧格式 review 仅保留为历史记录，不按 checkout 刷新的 mtime 复活。

## [1.13.0] - 2026-06-16

### Added (共享 serve + D6 选型 + HETERO_EXHAUSTED)

- **`lib/oc-serve.sh` 共享 serve 库** — 常驻 `opencode serve --pure --port 4096`，所有审查通过 `--attach` 复用，消除 per-run serve 堆叠（P1 内存泄漏，实测 2.7GB RSS 导致 kernel panic）。`mkdir` 原子锁 + PID 写入检测死进程，ensure 失败降级裸 run 不阻断审查。`OC_SERVE_DISABLED=1` 跳过集成。
- **`bin/oc-review` v2** — 自动管理共享 serve，启动时 `oc_serve_ensure()`，注入 `--attach` 到 `run` 子命令后。R4: 检查参数是否已有 `--attach` 避免重复。null-delimited `_build_args()` 安全传参。
- **`data/review-model-recommendations.json`** — 静态模型推荐：gpt/gemini/deepseek/kimi/qwen vendors，excluded_patterns (flash, glm)。
- **`lib/review-selection.sh` D6 选型** — `detect_available_models()` + `build_review_models()` + `_probe_model()`：vendor 归组 → 剔除 flash/coding 同源 → 交集推荐列表 → 实测可达 → 输出 review_models JSON。`_try_review_model()` 改用 `--attach` 复用共享 serve。
- **`doctor.sh` D6 集成** — `check_cross_review_capability()` 调 `build_review_models()`，结果写入 review-capability.json `review_models` 段。`check_opencode_health()` 增加共享 serve RSS/运行时长监控（>512MB warn，>1024MB restart）。
- **Gate 2b HETERO_EXHAUSTED** — 全异构模型失败 → agent-tool L0 → Gate 2b 不再死锁。双条件防绕过：`<!-- HETERO_EXHAUSTED:` HTML 注释格式 + `REVIEW_LEVEL: L0` 同时满足才放行。
- **`bin/oc-reaper` 增强** — pgrep 增加 `opencode run.*attach.*:${port}` 辅助信号，精确识别 `--attach` 客户端。
- **`install.sh` R3 修复** — 部署 `lib/` 和 `data/` 目录（v1.12.0 预存 bug：安装态缺 review-selection.sh）。
- **`install.sh` R2 修复** — `detect_review_capability()` 保留已有 `review_models` 段，不再覆盖 doctor.sh 的 D6 输出。
- **`agent-review-protocol` SKILL.md** — 所有 `opencode run` 模板加 `--pure`，§8 Route 1 描述更新为共享 serve + D6 model selection。

### Why / 背景

- 根因（实证 2026-06-16）：Paseo 管理的 `opencode serve` 每次 run 新起随机端口 serve，20000+ timeline items 堆到 2.7GB RSS，触发 macOS kernel panic。v1.8.0 的 reaper 不覆盖 Paseo 管的 serve。
- 方案：常驻共享 serve + `--attach` 复用，Phase 0 验证 `--attach --pure` 兼容性通过。
- D6 选型算法：解决 doctor.sh 只检测工具存在不选模型的问题，反向异构（coding vendor 是 Claude → primary 选 GPT/Gemini）+ 推荐列表交集 + 实测可达。
- HETERO_EXHAUSTED：解决全异构失败时 Gate 2b block 死锁（agent-tool L0 是唯一出路但 gate 不允许 L0）。

## [1.9.0] - 2026-06-03

### Added (全局升级 — 终结"每个项目手动升级"的黑暗时刻)

- **`hooks/git/gate-shim.sh` 瘦 shim** — per-project `.githooks/agent-quality-gate.sh` 从"冻结完整拷贝"改为 ~10 行壳,`exec` 全局权威 gate。**`install.sh --upgrade` 一次升级所有 shim'd 项目**,不再逐个 re-init。权威缺失(没装 agent-gates)则放行不挡 commit(契合 AGENT_MODE=1 "humans pass through")。`AGENT_GATES_GATE` 可覆盖(测试)。TDD 5 用例。
- **`bin/agent-gates-migrate`** — 扫描指定根目录(可多个),把老的完整拷贝 gate 批量换成 shim。默认 dry-run,`--apply` 才替换(只换 gate,不做完整 re-init,不碰 AGENTS.md/CLAUDE.md)。逐项目报告。TDD 8 用例。
- **`bin/agent-gates-version`** — 查看全局门禁版本(= 所有 shim 项目实际跑的版本);传项目根目录则列各项目 shim/stale 状态 + stamp drift 提醒。TDD 6 用例。
- **`install.sh`** 部署 gate-shim.sh → `~/.agent-gates/hooks/git/`;bin/* 自动部署 migrate + version。
- **`init-project-gates` SKILL.md** 改为写 shim(不再完整拷贝)+ 迁移/版本命令说明。

### Why / 背景

- 痛点(用户实测): per-project gate 是冻结拷贝,发新版后每个项目都要手动 re-init,tenant-app 卡在 v1.3 裸奔。用户预期"全局升级 + reload 即可"——五个部件里只有 gate 不满足,v1.9.0 把它补齐。
- 决策: 只换 gate 成 shim(外科手术),不批量跑完整 re-init(避免覆盖手改的 AGENTS.md/CLAUDE.md)。
- trade-off: shim 后 gate 逻辑不再 commit 进项目仓(只剩壳),依赖 ~/.agent-gates;对个人用法全是好处,团队仓队友需装 agent-gates(没装则放行)。
- 迁移老项目: `~/.agent-gates/bin/agent-gates-migrate --apply <root>` 一次清存量。

### codex 交叉审查 VERDICT: REVISE → 已修

- **#2 migrate 防误删**: 原来只靠 shim marker 排除,会覆盖任何同名文件 → 改为**正向指纹**(必须含 `Agent Quality Gate`/`GATE_VERSION`/repo URL 才迁移),unknown 同名 hook(如手写的自定义 pre-commit)一律 skip 不碰。补 T5(自定义 hook 不被覆盖)。
- **#3 version 误报**: `.version` 在就报全局版本,但权威 gate 缺失/不可执行时 shim 实际放行 → 现检查 `$GATE` 存在+可执行,缺失则 WARN "shim 项目当前不强制任何东西"。补 T5(authority 缺失告警)。
- **#6 测试缺口**: 补 shim 参数含空格(T4)、migrate unknown-hook(T5)、version authority-missing(T5)。新增脚本测试 19→24。
- 全套件 124 全绿。

## [1.8.0] - 2026-06-02

### Added (opencode 跨模型审查可靠性 — oc-review + oc-reaper)

- **`bin/oc-review`** — `opencode run` 的 retry-on-empty 包装。opencode 偶发 exit 0 但**空输出**(裸 run 和 --attach 都犯,POC 实证),导致审查无声失败。检测空输出→重试(默认 +2 次);仍空则 exit **75 (EX_TEMPFAIL)** + `oc-review:` 前缀 stderr,调用方据此 fallback codex(§8)。**治 P2 卡死**。TDD 9 用例(mock opencode 模拟空输出)。
- **`bin/oc-reaper`** — 清孤儿 `opencode serve`。opencode run 每次起随机端口 serve,hung run 留孤儿堆叠(实测 6 个)。多信号判定(端口/年龄>2min/存活/无 ESTABLISHED 连接/无匹配 run),**默认 dry-run**,`--apply` 才 SIGKILL(opencode serve 不响应 SIGTERM,POC 实证)。**治 P1 泄漏**。真实数据验证: 现存 5 孤儿正确识别、1 保留、dry-run 不杀。
- **`install.sh`** 部署 `bin/*` → `~/.agent-gates/bin/`。
- **`doctor.sh` check_opencode_health** — 检测孤儿 serve 数(无 ESTABLISHED 连接),≥1 孤儿或 ≥3 堆叠 → warn 提示跑 oc-reaper。只检测不清理。
- **`agent-review-protocol` §8** — route 1 opencode 改用 `oc-review`(retry + exit 75 fallback);route 2 codex 明确 **prompt 走 stdin**(`codex exec -s read-only < prompt`),不要当位置参数(否则卡 "Reading additional input from stdin")。

### Why / 方案历程

- 根因(实证): opencode run 每次起随机端口 serve、不复用(`--port` 默认 0)→ 并发堆叠 + hang 留孤儿(P1);run 偶发空输出(P2)。
- 方案经 **gpt-5.5 审查(REVISE)+ codex 审查(PASS-with-nits)** 两轮,关键决策: **POC 实证共享 server + --attach 能消 P1 堆叠但不解决 P2 空输出** → 放弃共享 server 复杂度(锁/多会话/单点),简化为 **retry(治 P2)+ reaper(治 P1)**(§10 反过度设计)。
- 方案文档: `~/AgentWorkspace/docs/research/opencode-serve-leak-fix.md`(v0.3)。
- 诚实边界: P2 根因仍未完全证实(疑似 opencode 自身 flake),retry 是症状级缓解非根治;reaper 的 lsof/etime 已做 macOS/Linux 可移植处理。

### codex 交叉审查 VERDICT: REVISE → 已修(讽刺旁证: opencode 审查这轮第 3 次卡死,实际走了 §8 codex fallback)

- **#1(阻塞)oc-review 不再吞 opencode 非零退出**: 原 `|| true` 会让"非零+有输出"误判成功、"非零+空"误报 P2。改为捕获 rc + stderr,成功 = rc==0 且非空;非零退出单独报错并透出 opencode stderr。补 T4/T5(非零退出 / 非零+输出不当成功),oc-review 测试 9→14。
- **#4 doctor check_opencode_health 加 age 门槛 + keep-port**: 只看"无 ESTABLISHED"会把刚起/idle serve 误判孤儿;现加 >2min 年龄 + 跳过 OC_REVIEW_PORT。实测正确报 5/6 孤儿(与 reaper 一致)。
- **#5 §8 路径统一**: route 1 表格用全路径 `~/.agent-gates/bin/oc-review`(未加 PATH)。
- #2(reaper pgrep 较粗)为低风险且偏保守(宁可不杀在用的),记为已知小项。

## [1.7.2] - 2026-06-02

### Fixed (v1.7.1 banner 回归 — 显示 "v?")

- **`install.sh` banner 显示 `v?`** — v1.7.1 让 banner 读 `$REPO_DIR/.version`,但 banner 在 `main()` 顶部跑,而 `REPO_DIR` 要到 `fetch_repo()`(main 后段)才赋值 → 读不到 → "?"。
  - 修法: 顶部新增 `SCRIPT_DIR`(解析 install.sh 自身所在目录 = 本地 repo;`curl|bash` 管道场景为空)。banner 版本从多来源按序解析: `SCRIPT_DIR` → `REPO_DIR` → `INSTALL_DIR`,取第一个有 `.version` 的。
  - 本地 repo 运行: banner 正确显示 1.7.2。验证: 12 install 测试通过 + banner 实测 1.7.2。
- 教训(§9.2 现身说法): v1.7.1 banner 只在隔离环境(手动设 REPO_DIR)测过,没在真实 install 上下文测 → "v?" 漏到了线上。修复类改动必须在真实调用路径验证,不只构造环境。

## [1.7.1] - 2026-06-02

### Fixed (gate 版本号 stale — 误导了别的会话)

- **`agent-quality-gate.sh` 版本号从硬编码改为 install 时戳入** — 头部注释 + 运行时 banner 长期硬编码 `v1.5`(自 v1.5 起就没更新),导致**别的会话读 banner 以为部署的是 v1.5**,实际是 v1.7.0。根因:版本字符串和 `.version` 没有任何同步机制。
  - gate 改用 `GATE_VERSION="__AGENT_GATES_VERSION__"` 占位符,`install.sh` 复制时 `sed` 戳入 `.version` 真实版本;直接跑源码(repo/测试)显示 `dev`。
  - per-project copy 从已戳版的 authority 拷贝 → 诚实显示自己被戳的版本(stale copy 不再谎称 v1.5)。
- **`init-project-gates` SKILL.md** — 删掉 "(v1.5)" 硬编码 + 旧 check 清单,改为"始终从 authority 拷最新、版本看 `.version`/CHANGELOG",补 Gate 2b(v1.7.0)说明 + 直接给 `cp` 命令。
- **`install.sh` banner**(gpt-5.5 审查发现的同类漏网)— main() banner 原硬编码 `Agent Gates Installer v1.5`,改为按 `$REPO_DIR/.version` 动态居中(同 doctor.sh v1.5.3 做法)。+ sed 戳版本前加 semver 校验守卫(`^[0-9A-Za-z.+-]+$`,防 `/&` 破坏替换,异常 fallback dev)。

### Why

- 真实事件: 一个 restart 后的会话读 gate banner 显示 "v1.5",误判权威版本,差点按错误版本决策。这是 v1.5.3 banner 硬编码 bug 的同类复发(换了个位置)。根治:版本号只有一个来源(`.version`),其余位置 install 时注入,不再手写。

## [1.7.0] - 2026-06-02

### Added (异构审查物理强制 — gate 长牙,堵"Opus 审 Opus")

- **`agent-quality-gate.sh` Gate 2b** — CHECK 5 确认 `VERDICT: PASS` 后,读 `~/.agent-gates/review-capability.json`:若机器能力 ≥ L1(装了 opencode/codex)但 review 文件 `REVIEW_LEVEL: L0` 或**无 REVIEW_LEVEL 标注** → **阻断 commit**。真 L0 机器(无异构工具)豁免。逃生口 `SKIP_HETERO_CHECK=1`。配置缺失/损坏 → 不阻断(优雅降级)。配置路径可经 `AGENT_GATES_DIR` 覆盖(测试隔离)。
- **gate 测试 +5(T11-T15)** — cap L3+无标注→阻断 / cap L3+L0→阻断 / cap L3+L2→放行 / 真 L0→放行 / SKIP_HETERO_CHECK 绕过。gate 测试 15→20 用例,TDD(先 RED 后 GREEN)。

### Fixed (review 文件选择 bug — 按文件名而非 mtime)

- **`agent-quality-gate.sh:113`** — 原 `find .agent/reviews/ -mmin -240 | sort -r | head -1` 按**文件名**降序挑,4 小时内有多个 review 时会挑中字母序最末的旧文件(如 `ux-fixes.md` 盖过新写的 `round1.md`),导致校验/Gate 2b 看错文件。改为遍历 + `stat` mtime 选真正最新。回归测试 T16 钉死。**这直接修了截图里"gate 挑中旧 ux-fixes 而非新 review"的真实故障**——不再需要"改名让它排最后"的 workaround。

### Changed (文档层定性)

- **`agent-review-protocol` §8** — 新增 "L0 Fallback is a VIOLATION When L1+ is Available":机器能做异构却走同模型兜底 = 违反红线 #8,不是可接受降级。明确"opencode 卡死过 / 派 subagent 更快"不是借口。补 "Physical Enforcement (v1.7.0)" 小节说明 gate 行为。
- **§1 工具优先级表** — 兜底档(code-reviewer)标注"仅真 L0 机器,装了 opencode/codex 时不是捷径"。
- **`agent-workflow-rules` §15** — 反模式新增一行:opencode/codex 已装却派 general-purpose/oracle 不指定 model → STOP(同模型 Opus 审 Opus)。

### Why

- 真实数据(412 transcript 挖矿,2026-06-02): 20 个有交叉审查活动的会话,只有 2 个用了真异构工具,**~90% 是同模型兑水**。截图实证:某 agent 派 general-purpose 不指定 model → 继承 Opus → Opus 审 Opus,只满足红线 #8 兜底档不满足核心"不同模型"。
- v1.6.0 建了检测(review-capability.json)却没接到 gate;v1.7.0 把检测接到闸门 = 物理强制。规则早就存在却被忽略 90%,只有硬阻断能改。
- 诚实边界: 残留洞——agent 可谎报 `REVIEW_LEVEL: L2` 而没真跑异构工具(更主动的违规)。留待 C 档(证据嵌入)按需再堵。per-project hook 是 copy,老项目需 re-init 才获得本强制。

### Known Limitations (gpt-5.5 审查 VERDICT: ISSUES → 已记录,非本版修)

- **freshness 同秒竞态**(预存,非本版引入): post-review 改动检测用秒级 mtime + `SF_MTIME > REVIEW_MTIME`,review 后**同一秒**改源码会漏判。改 `>=` 会误伤正常流程,sub-second 不可移植 → 接受该罕见竞态,代码注释 + 本条记录。backlog 跟进。
- **谎报 REVIEW_LEVEL**: 见上,C 档跟进。
- 审查过程教训: 首轮派审查 prompt 漏"只读约束",审查 agent 误建 worktree `memory/`(已清理)。第二轮补只读约束后正常。→ §9 prompt 模板应默认带只读头(backlog)。

## [1.6.3] - 2026-06-02

### Added (规则沉淀: 合成 fixture ≠ 真实数据证据)

- **`agent-workflow-rules` SKILL.md §9.2 新增** — "Synthetic Fixtures ≠ Real-Data Evidence":对启发式/触发条件/阈值/分类器类逻辑,绿色单测(手写 fixture)不证明正确性,必须用**真实输入样本**(日志/transcript/真实 payload)校准并报告真实命中/漏报率。
- §9.1 证据表加一行(heuristic/trigger/threshold → 需真实数据验证)。
- §15.1 反合理化表加一行("所有 fixture 都过" → 跑真实数据)。

### Why

- 直接来自 v1.6.1→v1.6.2 的真实教训: Parallelism Reminder 16 个 fixture 全绿,但 fixture 全是"全 pending",而真实 64% 是"首条 in_progress" → 漏掉大多数。bug 是 transcript 挖矿发现的,不是测试。把这条沉淀成可复用规则,避免重蹈。

### gpt-5.5 交叉审查修订 (VERDICT: ISSUES → 已修)

- 防误读: §9.2 显式声明"**不替代 §4 TDD**,fixture 仍必要,只是对 pattern 类逻辑'必要但不足'",避免被速读成否定单测。
- 可审计: 真实数据验证需注明样本量 + 来源,非平凡时(脱敏后)存 `.agent/reviews/`。

## [1.6.2] - 2026-06-02

### Fixed (Parallelism Reminder 触发门槛按真实数据校准)

- **`memory-reminder.mjs` detectPlanTimeTodos 放宽门槛** — 从"≥3 且**全** pending"改为 **"≥3 且 0 completed 且 ≤1 in_progress 且无未知状态"**。真实 transcript 抽样显示 64%(7/11)的计划写入首条已是 in_progress(agent 写计划时常直接起手第一项),旧的"全 pending"门槛把这些全漏了。校准后真实计划写入触发率从 ~33%(4/12)升到 ~92%(11/12)。
- 保留 v1.6.1 的 malformed 防护: 未知/缺失 status 计入 `unknown` 并阻止触发(well-formed TodoWrite 总会带 status)。
- 2 个 in_progress 或任意 completed → 判定为"工作已进行中",不触发。

### Added (tests)

- `work-underway.json` fixture(2 in_progress → 不触发);`plan-time-started.json` 期望从 false 翻为 true(现覆盖 64% 真实模式)+ Parallelism marker 断言。hook 测试 16→18 用例。

### Why / 元教训

- **单元 fixture ≠ 真实数据分布**: v1.6.1 的 16 个测试全绿,但 fixture 全是"全 pending",而真实世界 64% 是"首条 in_progress"。bug 是靠"本地跑 + transcript 挖矿"发现的,不是单测。
- 顺带排除伪问题: 全局 1738 次 `todowrite` vs 0 次 `TaskCreate` → TaskCreate 跨调用 state 不做(非真实工作流)。

### gpt-5.5 交叉审查修订 (VERDICT: ISSUES → 已修)

- **补 5 个边界 fixture**: all-in-progress / completed+in_progress / empty-status / garbage-status / omo-done(把 gpt-5.5 手测的边界固化成回归测试)。hook 测试 18→25 用例。
- **顺带修预存 bug**: OMO completed 检测(`detectTodoCompleted` line 75-77)原只认 `completed`,不认 `done`,与 OMC/OMX 路径不一致 → 补 `|| status === 'done'`。
- 逻辑/优先级/malformed 防护经 gpt-5.5 6 个 ad-hoc 边界验证全部正确。

## [1.6.1] - 2026-06-02

### Added (并行优先 — 减少独立任务被串行处理)

- **`memory-reminder.mjs` 新增 Parallelism Reminder** — 当 agent 一次性创建 ≥3 个全 pending 的 todo(刚做完计划、未动工)时,注入 `[AGENT-GATES: Parallelism Reminder]`,提示按 §18 判断哪些独立、用机制 A(批量 tool call)还是 B(子 agent)。只在计划时触发一次,开工后(有 todo 转 in_progress)不再刷,避免提醒疲劳。matcher 已含 `TaskCreate`,无需改注册。
- **tests: 2 个新 fixture** — `plan-time-3-pending.json`(≥3 全 pending → 触发) + `plan-time-started.json`(已有 in_progress → 不触发); run.sh 新增 marker 断言验证两种 reminder 各自正确触发。

### Changed

- **`agent-workflow-rules` SKILL.md §18 重写** — 拆分两种并行机制: A. 批量 tool call(同消息多 Read/Edit/Bash,轻量独立操作) vs B. 子 agent 并行(重独立工作流)。加判定线 + 真实案例 2(某 agent 5 个独立 UX 修复串行、用户纠正三次的"A/B 没分清"教训)。

### Why

- v1.6.0 后观察到: §18 把"批量 tool call"和"子 agent 并行"揉成一条,导致 agent 被纠正三次仍误解用户意图。根因是概念没分清,不是规则没写。本版先拆概念(治根因)+ 加 plan-time 软提醒(补运行时激活)。
- 诚实边界: 这是软提醒(同 memory reminder 层级),非硬门控。"串行"不是可拦截的事件,只能降频率,不能消灭。

### gpt-5.5 交叉审查修订 (VERDICT: ISSUES → 已修)

- **判定改保守**: `detectPlanTimeTodos` 要求 status **显式** `=== 'pending'`,缺失/空 status 不触发(防异常 payload 误触发)。
- **诚实声明无去重**: hook 无状态,不跨调用去重。注释 + §18.5 + CHANGELOG 不再声称"触发一次",改为"全 pending 时触发,实践中一次 TodoWrite 计划写入触发一次"。stateful 去重会破坏测试幂等性且引入跨 turn 状态脆弱性,故不做。
- **测试补全**: 新增 4 个 fixture(OMO plan-time / 缺失 status / completed+pending 优先级 / malformed JSON),hook 测试 6→16 用例。

## [1.6.0] - 2026-05-29

### Added (跨平台审查路由 — 磨平不同 AI agent 平台的审查能力差距)

- **`doctor.sh` 新增 `check_cross_review_capability`** — 每次 doctor 运行时重新检测所有异构审查工具(opencode CLI / codex CLI / OMC codex 插件 / Paseo),计算能力等级(L0-L3),写入 `~/.agent-gates/review-capability.json` 持久化配置。含 CI / Windows / WSL / 容器环境检测。L0 时输出升级建议。
- **`install.sh` 新增 `detect_review_capability`** — 安装时首次检测审查能力,写入持久化配置。L0 时输出详细安装引导(codex CLI / opencode CLI)。
- **`agent-review-protocol` SKILL.md §8 Cross-Check Platform Routing** — 审查时读 `review-capability.json`,按优先级瀑布式路由: opencode → codex → OMC codex plugin → Paseo → agent-tool (最终兜底)。含超时处理、环境适配、`REQUIRE_HETEROGENEOUS=1` 严格模式。
- **`agent-review-protocol` SKILL.md §9 Review Prompt Templates** — 预写好 Spec Review / Quality Review / Cross-Check 三套 prompt 模板,解决"子 agent 不知道干啥"的问题。
- **`~/.agent-gates/review-capability.json`** — 新增持久化配置文件,记录决策树(5 个路线的可用性 + 路径 + 版本)、能力等级、首选/备选/兜底路线。

### Changed
- **`agent-workflow-rules` SKILL.md §12.1** — 交叉审查 tool priority 从固定列表改为引用 `agent-review-protocol` §8 自适应路由。新增 `REVIEW_LEVEL` 强制标注要求。

### Design Decisions
- 决策树在 install/doctor 时确定并持久化,审查时只读配置 + 失败回退,不做实时检测
- Paseo 标注可用但不参与自动等级计算(它是编排层不是审查工具)
- L0 (同模型审查) 默认 warn 不阻塞,可通过 `REQUIRE_HETEROGENEOUS=1` 升级为 fail
- review 文件必须标注 `<!-- REVIEW_LEVEL: L0/L1/L2/L3 -->` 供 doctor 事后检查

### Notes
- gpt-5.5 异构审查 VERDICT: REVISE → 采纳 4 条(health probe / 迁移表 / REVIEW_LEVEL / 失败回退) + CI/Win/容器
- 后置 9 项(D1-D9)记录在方案文档,留 Rampart 跟进
- 方案文档: `~/AgentWorkspace/docs/research/v1.6-cross-review-routing.md`

## [1.5.5] - 2026-05-28

### Fixed (E2E 测试发现的两个小改进)
- **`hooks/git/agent-quality-gate.sh` trivial skip 加 info 输出** — 之前 trivial 改动直接 `exit 0` 静默，用户看 commit 输出不知道 gate 是否运行过。现在输出 `✅ Agent Quality Gate: trivial change skipped (N file(s), +N lines)` 让用户明确知道 gate 工作了并决定跳过。
- **`doctor.sh check_hook_output_schema` 使用 `|| return 0`** — 之前 `[[ -f "$mjs" ]] || return` 在 `set -e` + 残缺 mock 环境下会触发隐式 return 非 0 让脚本中止，summary 不输出。改为显式 `return 0` 保证 graceful skip。仅 mock / 残缺安装场景触发，实际用户安装无感知。

### Notes
- 两项均为 E2E 测试发现的非阻塞改进（v1.5.4 全部 79/79 测试通过，但这两项 UX/健壮性可以更好）
- 测试: 60 unit + 19 E2E = 79 pass / 0 fail（无回归）

## [1.5.4] - 2026-05-28

### Changed (Memory skill 从 sparse-clone 改为内置)
- **`skills/memory/`** 新增 — fork 自 [clawic/skills](https://github.com/clawic/skills) MIT 的 `skills/memory/` 子目录（6 个文件：`SKILL.md` / `_meta.json` / `memory-template.md` / `patterns.md` / `setup.md` / `troubleshooting.md`）+ 新增 `UPSTREAM.md` 标明 attribution 和上游同步流程。
- **`install.sh` SKILLS 数组** 加 `memory` — 走标准 `install_skills()` 流程（与 `init-project-gates` / `agent-workflow-rules` / `agent-review-protocol` / `init-deep-fallback` 同等地位）。
- **删除 `install_memory_skill()` 函数 + sparse-clone 逻辑** — 不再需要 install 时 git clone clawic/skills。安装更稳（无网络依赖）+ 更快（直接 cp）。
- **删除 `check_memory_skill_installed()` 函数**（dead code，无调用方）+ 删除 `MEMORY_SKILL_REPO` / `MEMORY_SKILL_SUBPATH` 常量。
- **`install_external_deps()` 简化** — 只剩 Superpowers + OpenSpec 两层（Memory 已交给 `install_skills()`）。

### Removed
- 网络依赖（针对 Memory skill）— 内网用户 / CI / 离线环境也能装

### Documentation
- README.md / README.zh-CN.md 双语同步：Architecture 目录树补 `memory/` + `init-deep-fallback/` + Auto-Installed Dependencies 表 Memory 行从 "sparse-clone" → "Bundled"（attribution 指向 `skills/memory/UPSTREAM.md`）+ Skills 表加 memory + init-deep-fallback 两行
- docs/explainer.zh.md L156 sparse-clone 描述同步更新
- `skills/memory/UPSTREAM.md` 记录 fork 来源 / 同步命令 / license attribution

### Test Coverage
- `tests/run_install.sh` T7 改为验证 `skills/memory/SKILL.md` 内置存在（替代旧 `check_memory_skill_installed` 测试）

### Notes
- Superpowers 14 个 skill **不内置**（仓库 ~MB 级，且 obra/superpowers 更新频繁，sparse-clone 更合理）
- Memory skill 与 clawic 上游分叉风险：v1.5.4 fork 时与上游字节一致；后续 clawic 更新由 agent-gates 维护者按 UPSTREAM.md 手动同步（频率低，clawic 自身 Memory skill 已稳定在 v1.0.2）

## [1.5.3] - 2026-05-28

### Fixed
- **`doctor.sh` banner 动态版本号** — 之前 hardcode `Agent Gates Doctor v1.5`，v1.5.1 / v1.5.2 升级后 banner 不变，给用户造成"装的版本是不是没生效"的错觉。改为从 `~/.agent-gates/.version` 动态读取并居中对齐（自动 padding，支持任意长度版本号如 `v1.5.3` / `v2.0.0-beta` / `v10.0.0` 都不破坏 box 框线）。
- `.version` 缺失时 banner 显示 `Agent Gates Doctor v?`（不再误报）。

### Notes
- 纯 cosmetic patch，零功能变更。
- 所有测试不受影响（doctor 内部 check_* 函数行为不变）。
- v1.5.4 计划：Memory skill 内置（fork `clawic/skills/skills/memory/` 到 `agent-gates/skills/memory/`，避免 install 时网络依赖）。

## [1.5.2] - 2026-05-28

### Added (依赖自动安装)
- **`install.sh` 默认自动安装外部依赖**（强制依赖开箱即用）：
  - **Memory skill** — sparse-clone `clawic/skills`（MIT），仅 `skills/memory/`，复制到主 platform skill dir。已装则 skip。
  - **Superpowers 14 个 skill** — clone `obra/superpowers`，全部 `skills/*` 复制。已装 5 个 hardcore（test-driven-development / brainstorming / verification-before-completion / writing-plans / executing-plans）则 skip 整批。
  - **OpenSpec CLI** — 检测 `which openspec`，缺失时**交互式询问 y/N** 执行 `npm install -g @openspec/cli`。非交互 shell 默认 N。明确告知用户全局环境影响（红线 #2）。
- `--skip-deps` 参数：opt-out 外部依赖安装（CI / 老用户保留入口）

### Fixed (平台检测一致性)
- **F1: `doctor.sh check_omc_registration`** 加"未装则 skip"前置 — 与 OMO/OMX 行为对齐。之前 Claude Code 未装时 doctor 报 WARN "settings.json missing — not initialized?"，现在改为 NOTE skip "OMC not installed"。
- **F2: `install.sh` OMO 自动 hook 注册** — 之前 v1.4 标记为 "automated registration not yet supported"，现已确认 OMO `~/.config/opencode/hooks.json` schema 等价 OMC/OMX，复用 `register_hook()` jq 注册逻辑，OpenCode 用户不再需要手动配置。

### Changed (init-project-gates Step 6)
- **跨平台 init 决策树**（D 方案 — `/init` 兜底）：
  1. Claude Code + OMC plugin 装了 → OMC `deepinit` (hierarchy)
  2. OpenCode + OMO 包装了 → `/init-deep` (hierarchy)
  3. 任意 platform → 平台原生 `/init` (单根)
  4. 都不行 → agent 手写最小根 AGENTS.md
- 不强制装 OMC/OMO plugin；hierarchy 是 nice-to-have。跨平台统一接口留待 Rampart 基座层。

### Removed (脱敏)
- `init-project-gates/SKILL.md` 删除 `pingcode-log` 引用（公司内部 PingCode 工时工具）
- `init-project-gates/SKILL.md` 删除 `waza-check` 引用（无功能依赖的关联文档）
- `templates/PROGRESS.md` "PingCode 工时参考" → "工时参考"（脱敏）
- CLAUDE.md 注入模板里的 "PingCode" 字样泛化为 "工时"

### Test Coverage
- run.sh: 6 pass
- run_doctor.sh: **19 pass**（v1.5.1 17 + F1 OMC skip 2 个新测试）
- run_gate.sh: 14 pass
- run_install.sh: **12 pass**（v1.5.1 5 + 7 个新 auto-deps 测试）
- run_codegraph_hook.sh: 9 pass
- **总计: 60 pass / 0 fail**（v1.5.1 是 51）

### Notes
- v1.5.2 仍是 agent-gates 的维护版。**Rampart 是基座重构**，会磨平各 platform 差异（rampart init-deep 统一接口，自动选 OMC/OMO/fallback）。
- 现在的 v1.5.2 用户开箱可用：装好就有 Memory + Superpowers，OpenSpec 询问后装，hook 自动注册到所有已装 platform。

## [1.5.1] - 2026-05-28

### Added
- **`doctor.sh check_superpowers_install`**(TDD 实现) — 检测 5 个上游 superpowers skill (test-driven-development / brainstorming / verification-before-completion / writing-plans / executing-plans) 在 5 个平台 skill dir (~/.claude/skills、~/.config/opencode/skills、~/.codex/skills、~/.cc-switch/skills、~/.agents/skills) 的存在。全部 found → PASS;部分 → WARN 列出 missing;全无 → WARN 提示 install URL。`tests/run_doctor.sh` 加 5 个新测试 (17/17 全绿)。
- **CodeGraph chpwd hook 集成**(v1.4 后遗留功能) — `hooks/shell/codegraph-chpwd.zsh` + `tests/run_codegraph_hook.sh` (9/9 通过) + `install.sh --codegraph-hook` 参数注册到 `~/.zshrc` + `init-project-gates` 可选 Step 7 引导。Cherry-picked from feat/codegraph-chpwd (e41c5d6)。
- **`agent-workflow-rules` SKILL.md §17 迭代收敛规则**(同步到 `~/.claude/rules/global/10-workflow.md`) — 同一文档/实现 ≥ 2 轮独立审查仍 REVISE → 强制反思整体思路,禁止继续 patch。来源:Drift Review v0.1→v0.3 教训。
- **`agent-workflow-rules` SKILL.md §18 团队模式 / 并行优先**(同步到镜像) — 复杂多任务必须优先并行派出子 agent,≥ 2 个互不依赖子任务必须并行。

### Fixed
- 无 (v1.5.0 ship 后未发现需修复缺陷)

### Notes
- v1.5.1 是 agent-gates 的**最后一个 feature 版本**。后续工作转移到独立仓 **Rampart** (基座 + 可扩展模块架构重构)。agent-gates 进入维护状态,仅做安全/兼容性修复。
- Vault `BDD-CLI-Gate-OpenSpec整合方案.md` §实施现状对照表同步更新到 v1.5.1 (100% 对齐设计层)。

### Test Coverage
- run.sh: 6/6
- run_doctor.sh: 17/17 (v1.5 12 + v1.5.1 新增 5)
- run_gate.sh: 14/14
- run_install.sh: 5/5
- run_codegraph_hook.sh: 9/9
- **总计: 51/51 pass** (v1.5.0 是 37/37)

## [1.5.0] - 2026-05-27

### Added
- **`agent-quality-gate.sh` v1.5** — two new pre-commit checks for Path A (OpenSpec) projects:
  - **CHECK 1**: `openspec/changes/` must contain at least one active change directory. Blocks commit when the directory exists but is empty.
  - **CHECK 2**: New source files in Path A projects require `features/*.feature` BDD scenarios. Blocks commit when no `.feature` files exist.
  - Path detection added: auto-detects Path A via `openspec/changes/`, `.opencode/skills/openspec-propose/`, or `.claude/skills/openspec-propose/`. Path B projects skip CHECK 1 and CHECK 2.
- **`doctor.sh` v1.5** — `check_bdd_step_definitions`: detects `features/step_definitions/` and counts step definition files (`.ts`, `.js`, `.py`, `.java`, `.rb`). PASS when files found, WARN when missing.
- **`install.sh` v1.5** — `--with-openspec` flag: checks for `openspec` CLI on PATH, reports version or install instructions.
  - New `check_openspec()` function.
- **BDD scaffolding templates** in `templates/features/`:
  - `example.feature` — starter Gherkin scenario
  - `step_definitions/example.steps.ts` — TypeScript (Cucumber.js)
  - `step_definitions/example_steps.py` — Python (pytest-bdd)
  - `step_definitions/ExampleSteps.java` — Java (Cucumber-JVM)
- **`init-project-gates` SKILL.md** — Step 5b: BDD scaffolding for Path A projects. Auto-detects project stack and copies matching templates.
- **`agent-workflow-rules` SKILL.md** — §6.6 (step definitions directory structure), §6.7 (scenario reference in TDD RED), §6.8 (commit message scenario reference).
- **Tests**: `tests/run_gate.sh` (11 tests for CHECK 1 + CHECK 2), `tests/run_install.sh` (5 tests for --with-openspec), 3 new tests in `tests/run_doctor.sh`.

### Documentation
- **README** — new "BDD Quick Start" and "OpenSpec Integration" sections. Updated gate descriptions and doctor sample output to include CHECK 1, CHECK 2, and step_definitions check.

### Why
- v1.4.0 had zero integration points for OpenSpec and BDD despite them being core to the Path A workflow design. CHECK 1 + CHECK 2 close the gap between the documented rules and actual enforcement. BDD templates lower the adoption friction for teams starting with Gherkin.

## [1.4.0] - 2026-05-22

### Added
- **`doctor.sh` v1.4** — two new project-level checks that run when the cwd is a git repo (detected via `[[ -d .git ]] || [[ -f .git ]]`, no `git` binary needed so Xcode-license issues on macOS don't break the check):
  - `check_openspec_install` — detects `.opencode/skills/openspec-propose/`, `.claude/skills/openspec-propose/`, or `openspec/changes/` and reports which workflow path applies (Path A with OpenSpec vs Path B without). PASS when present, informational `note` when absent.
  - `check_bdd_features_dir` — counts `features/*.feature` files. PASS when ≥1 file present, WARN when `features/` exists but is empty (Path A requires BDD scenarios), `note` when the directory is absent.
- Banner bumped to `Agent Gates Doctor v1.4`.
- `tests/run_doctor.sh` — 5 new test cases covering: OpenSpec detected via `openspec/changes/`, OpenSpec absent (informational), `.feature` files present, `features/` empty WARN, project-level checks skip when not in a git repo. 9/9 tests pass.

### Documentation
- **README** — new `Workflow Paths: A (OpenSpec) vs B (no OpenSpec)` section explaining auto-detection, planning/acceptance/implementation differences per path, and the shared `agent-workflow-rules` skill as canonical source. Doctor sample output updated to 13 PASS lines reflecting the new checks.
- **`docs/platform-hooks.md`** — new `Project-level checks (v1.4)` addendum clarifying that the doctor's openspec/bdd checks are unrelated to the platform hook registration and only run inside a git repo.
- **Global rule sync** (`~/.claude/rules/global/10-workflow.md`) — rewritten as a concise mirror that points to `agent-workflow-rules` SKILL.md as the canonical source. Keeps the entry-point essentials (intent recognition, 🔴 Skill Gate hard gates, trivial standard, anti-pattern self-check, red-line references) and routes section detail (TDD / OpenSpec / BDD / Plan Review / CLI Gate / Verification / Anti-Over-Engineering / Debugging) through the skill's §3–§16. Conflict resolution: skill wins.

### Why
- v1.3.x doctor only inspected platform/hook health; project-level workflow readiness (OpenSpec install, BDD `.feature` coverage) was invisible. v1.4 surfaces both so agents and users know which workflow path applies before starting work.
- The global 10-workflow.md and the skill SKILL.md had drifted into two near-duplicates that contradicted on small points. The mirror pattern (skill = canonical, global rule = pointer) eliminates the maintenance trap and matches the convention used elsewhere in the rule system.

### Known limitations
- `doctor.sh` does not yet probe upstream `agent-superpowers` skills (`test-driven-development`, `brainstorming`, `verification-before-completion`, `opsx:explore`). The workflow rules and global mirror reference them as hard Skill Gate triggers, but their presence is currently the user's responsibility. A `check_superpowers_install` analogous to `check_openspec_install` is planned for v1.5.
- `install.sh` does not auto-install upstream skills or the OpenSpec CLI. This is intentional per the project's destructive-command red line — third-party tooling must be installed by the user (see README "Upstream skill dependencies"). The installer prints candidate paths when missing but never mutates the system on the user's behalf.

## [1.3.1] - 2026-05-22

### Fixed (three equal-priority P0 regressions in v1.3.0 doctor.sh)

- **P0-1 — Missing OMO health check.** `doctor.sh` covered OMC and OMX but had no `check_omo_registration` for the OpenCode platform. v1.3.1 adds it: skips with `note` when `~/.config/opencode/` is absent, otherwise validates `~/.config/opencode/hooks.json` contains a `.hooks.PostToolUse[].hooks[].command` matching `memory-reminder` (jq probe). Returns `WARN` when the file or hook is missing — matches the existing OMX behavior. The OpenCode platform is now first-class in the health report.
- **P0-2 — Matcher-mismatch silently passed.** When OMC `settings.json` contained a memory-reminder hook but the matcher lacked `TaskUpdate`, the v1.3.0 code path reported `WARN`. That is the exact failure mode v1.1.2 was created to surface — Claude Code's current tool name is `TaskUpdate`, so a matcher without it means the hook never fires. v1.3.1 reclassifies this branch to `FAIL` so doctor exits non-zero and CI / users get a clear signal to re-run `install.sh`.
- **P0-3 — Pipeline hang on no-match transcripts.** `check_transcript_errors` used `find … | xargs -0 grep -l … | xargs grep -l "memory-reminder" | wc -l`. On macOS BSD `xargs`, an empty stdin makes the second `xargs` invoke `grep` with no file arguments, which then blocks reading from stdin — the script hangs forever. v1.3.1 rewrites the function with a `while IFS= read -r f; do … done < <(find …)` loop that has no `xargs`, no pipefail interaction, and no empty-stdin trap. Also avoids a second class of bug from the obvious "just add `|| true`" patch: a partially-failing pipeline produced concatenated output (e.g., `"4\n0"`) that broke the `== "0"` comparison and showed garbled counts.

### Tests
- New `tests/run_doctor.sh` — sources `doctor.sh` under a mocked `$HOME` and `$INSTALL_DIR`, invokes the affected check functions directly, asserts the `PASS / WARN / FAIL` arrays.
  - `P0-1`: OMO hook detected → `PASS`.
  - `P0-1b`: OMO hook missing → not `PASS` (either `WARN` or `FAIL`).
  - `P0-2`: OMC matcher missing `TaskUpdate` → `FAIL`.
  - `P0-3`: `check_transcript_errors` completes in <5s on transcripts with no matches.
  - `P0-3b`: companion direct-pipeline reproducer that demonstrates the original BSD-xargs hang (informational; the function-level test above is the real assertion).

### Cross-platform notes
- The transcript scan now works identically on macOS (BSD xargs) and Linux (GNU xargs) — both have the same hang behavior on the original code, both work cleanly with the while-read loop.

## [1.3.0] - 2026-05-22

### Added
- **`doctor.sh`** — standalone deployment health-check tool. 10 checks: node ≥18, jq, Memory skill detection, local `.version`, remote `.version` parity, hook files present + executable, OMC `settings.json` hook registration (with matcher inspection for `TaskUpdate` presence), OMX `~/.codex/hooks.json` registration, end-to-end hook output schema validation (executes `memory-reminder.mjs` with a sample payload and asserts `hookEventName=PostToolUse` + reminder body contains the `AGENT-GATES` tag), and a 7-day transcript scan for `hook_non_blocking_error` related to memory-reminder. Outputs `PASS / WARN / FAIL` table + summary count. Exits `0` on no-fail (warnings allowed), `1` on any fail — CI-friendly. Flags: `--quiet`, `--no-network`, `--help`.
- `install.sh` now deploys `doctor.sh` to `$INSTALL_DIR/doctor.sh` alongside the hook scripts. The "Done!" summary points users to the verify path.
- README: new `Doctor` section with sample output, flag table, and CI usage hint.

### Why
- The v1.2.1 root cause (missing `hookEventName` field) was invisible without inspecting transcript JSONL — there was no easy way for a user to confirm "hook is actually wired up correctly". Doctor turns that into one command.

## [1.2.1] - 2026-05-22

### Fixed (critical)
- **`memory-reminder.mjs`**: emitted JSON now includes the required `hookSpecificOutput.hookEventName: "PostToolUse"` field. Without it, Claude Code's hook-output validator rejects the response, writes a `hook_non_blocking_error` attachment to the session transcript (visible in `~/.claude/projects/<repo>/<session>.jsonl`), and **silently drops the reminder**. Net effect: `[AGENT-GATES: Memory Persistence Reminder]` never reached the agent on Claude Code since the hook's introduction.
- End-to-end verified by spawning a fresh Paseo `claude/sonnet` agent in `cwd=~/Projects/agent-gates`, having it call `TaskCreate` + `TaskUpdate(status=completed)`, then reading back the injected reminder verbatim. Pre-fix run reported `NO`; post-fix run reported `YES` with the first three lines of the reminder body matching.

### Discovery context
- v1.1.2 fixed where the hook is registered (`settings.json` not `hooks.json`) and the matcher (`TaskUpdate`/`TaskCreate` added). That made Claude Code attempt to invoke our hook for the first time — at which point the schema mismatch surfaced. v1.0.0–v1.2.0 all had this defect; it was latent because earlier sessions never reached the validator code path.

## [1.2.0] - 2025-05-21

### Added
- **agent-workflow-rules SKILL.md §8 Memory Persistence (⛔ Hard Constraint)** — new section detailing when to save (each completed todo, each phase delivery, session end), how to act on the `[AGENT-GATES: Memory Persistence Reminder]` system-reminder injected by `memory-reminder.mjs`, what to record, what NOT to save, loading prior memory on session start, and the no-Memory-skill fallback flow using `.agent/PROGRESS.md` + `.agent/memory/`.
- §0 Precedence note updated to describe the new §8 in relation to global rules.

### Changed
- Renumbered subsequent SKILL.md sections: Progress Tracking → §9, Anti-Pattern Self-Check → §10, Completion Definition → §11.

## [1.1.2] - 2025-05-21

### Fixed (critical)
- **install.sh**: hook registration now writes to `~/.claude/settings.json` `.hooks.PostToolUse[]` for OMC and `~/.codex/hooks.json` `.hooks.PostToolUse[]` for OMX. Previously wrote to `~/.claude/hooks.json` and root-level `.PostToolUse`, which **Claude Code does not read** — meaning the memory-reminder hook never actually fired on Claude Code since v1.0.0.
- **install.sh**: PostToolUse matcher expanded from `TodoWrite|todowrite` to `TodoWrite|todowrite|TaskUpdate|TaskCreate` to cover Claude Code's current todo tool names. The old matcher never matched on Claude Code installations.
- **install.sh**: `register_hook` now uses the nested `.hooks.PostToolUse` schema for both OMC and OMX, idempotent merge via `jq` that preserves all unrelated top-level settings.json keys (model, permissions, theme, etc.).
- **uninstall.sh**: removes hook entries from `~/.claude/settings.json` and `~/.codex/hooks.json` using the nested schema; preserves all other settings.json keys; also sweeps the legacy `~/.claude/hooks.json` path so users on prior versions get cleaned up.

### Changed
- README "Supported Platforms" table now shows the actual config file path and schema per platform; OMO marked as manual until v1.2.0.
- OMO automated registration deferred — added warning + manual instructions in installer output.

### Known limitations
- Claude Code does NOT hot-reload `settings.json`. Hook activation requires a new Claude Code session after install.

## [1.1.1] - 2025-05-21

### Added
- `install.sh`: hard `check_dependencies` for Node.js ≥18 (fails with install hint when missing)
- `install.sh`: `check_optional_deps` — detects `jq` and Memory skill, prints platform-specific install commands when missing (does not auto-mutate system)
- `install.sh`: backs up user-modified `SKILL.md` as `SKILL.md.bak.<timestamp>` before overwriting on upgrade; final summary lists all backups
- `install.sh`: `--upgrade` alias for `--force`; `--help` flag with usage
- `uninstall.sh`: `--purge-backups` to remove generated `SKILL.md.bak.*` files; `--help` flag
- README: Prerequisites entry for Memory skill; new `Upgrade` section with limitations; new `Troubleshooting` table

### Changed
- Installer "Done" summary now lists backed-up skill files and a per-project hook upgrade reminder
- `register_hook_json` fallback message now includes the platform-specific `jq` install command

## [1.1.0] - 2025-05-21

### Fixed
- **memory-reminder.mjs**: False-positive detection when todo content contains "completed"/"done" — now checks `todos[].status` field specifically
- **install.sh**: Can now merge into existing `hooks.json` via `jq` (previously required manual merge)
- **install.sh**: Detects OMO (OpenCode) override path `~/.config/opencode/hooks.json`

### Added
- `uninstall.sh` for clean removal of hooks, skills, and platform registrations
- `.version` file for version pinning and upgrade detection
- `tests/` directory with hook test fixtures and runner
- Code readability improvements (stdin fd, exit code, fallback regex documentation)

## [1.0.0] - 2025-05-20

### Added
- Initial monorepo structure with 3 skills: `init-project-gates`, `agent-workflow-rules`, `agent-review-protocol`
- `hooks/git/agent-quality-gate.sh` v1.3 — test correspondence + cross-review enforcement
- `hooks/platform/memory-reminder.mjs` — PostToolUse hook for Memory persistence reminders
- `install.sh` — multi-platform installer with auto-detection
- `templates/.agent/` — project-level PROGRESS.md, GATES.md, .gitignore
- `docs/platform-hooks.md` — hook registration documentation
- `README.md` — architecture overview and quick-start guide
