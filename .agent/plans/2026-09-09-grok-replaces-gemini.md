# grok-4.5 接掉 gemini 的审查位

用户反馈 gemini 的审查质量不行，要求换 grok-4.5。

## 背景

`review_models.panel_pool` 里配的是 `github-copilot/gemini-3.1-pro-preview`。
换型号看起来是改一行数据，但 `lib/hetero/select.sh` 的 `_extract_vendor` case 表里
没有 grok，会返回 `unknown`，而 `build_review_models` 里紧跟着
`[[ "$v" == "unknown" ]] && continue` —— 配了也进不了池，且全程无输出说明原因。

## 验收标准

1. `_extract_vendor` 对 `github-copilot/grok-4.5`、`grok-4.6` 与裸型号 `grok-4.5` 都返回 `grok`
2. `merge_capability` 内联 python 的厂商表同样含 `grok`，grok primary 在 platform 未探测出时不被误拒
3. `data/review-model-recommendations.json` 里 `vendors.gemini` 换成 `vendors.grok`，值为 `github-copilot/grok-4.5`
4. grok-4.5 能真正出现在 `build_review_models` 产出的 `panel_pool` 里（端到端，不只是返回值对）
5. `excluded_patterns` 的真实机制被如实记录：它在 `lib/` 零引用，flash 靠硬编码剔除、glm 无人拦
6. 新增测试文件被某个 runner 实际执行，而不是放在仓库里不跑
