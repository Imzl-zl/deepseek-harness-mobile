# Agent Note: 下一轮提示词 —— 原生规则审计（求证 + 归类，不实现）

Status: proposed

## 提示词（整段复制）

```text
项目：dsh-mobile（D:\sudy\myproject\dsh-mobile，Windows / pwsh）。中文回复。

本轮只有一件：**审计「我们替 DSH 做了决定」的地方 —— 逐条求证、归类、统计**。
默认**不改代码**；每条给出「删 / 改读原生 / 保留并写进 docs」的建议，动手前先问用户。

## 0 先读（别跳）

- AGENTS.md 的常驻军规「**宿主语义优先**」（新增）与 §5 的门禁口径
- `.agents/notes/implemented/2026-10-24-native-semantics-first.md`（原则 + 已撤掉的三处）
- `.agents/notes/proposed/2026-10-24-native-rules-audit.md`（**总账**：A 已收口 / B 待求证候选 / C 已知缺口 / D 不做）
- `.agents/notes/implemented/2026-10-23-interaction-as-gateway-client.md`（上一轮真机证据与代价）
- memory.md 的「待办」「已知缺口」「前置事实」「真机联调的成本纪律」
- docs/subsystems/remote-channel.md §6.2（没有档位/没有超时）、§6.3.1、§15

## 1 本轮要交的东西

1. **一张总表**，覆盖总账里的 B1–B13 与 C 表每一行：
   `# | 结论（自创 / 不是自创） | 归类 | 我们 file:line | DSH 证据（packages/...:行号 或 测试名） | 与原生语义的差异 | 建议`
2. **归类统计**：`自作主张 / 设计缺陷 / 逻辑语义 / 实现缺陷 / 验证缺口 / 有意偏离 / 未实现` 各几条，
   并给一句"最值得先做哪一条、为什么"。
3. **根因分段**：把同类问题放在一起说明共同的形状（例：终态被当成可重试 / 用 App 侧状态机补协议缺口 /
   把"没有稳定身份"当成拒绝参与的理由）。
4. 结论写回总账（把"待求证"改成"已求证 + 结论 + 归类"）。若结论是"现状成立"⇒ 整篇移入
   `implemented/`；若要改 ⇒ 保留在 `proposed/` 并把每件要改的拆成独立开工单（一件一提交）。

## 2 判据（机械）

- 每条结论必须有证据：DSH 自家测试 > DSH 源码行号 > 我们的单测 > 真机。**查不到就写「未找到」，禁止猜。**
- 「自创」的判据是三问：① 删掉这条规则，DSH 会不会已经给出答案？② 它是在补我们的通道，还是替宿主
  做决定？③ 它写进 docs 了吗、是不是只有一处表达？
- **不要**把"手机形态的有意偏离"（白名单、密钥不回传、字号倍率…）算成缺陷 —— 它们归 `有意偏离`。
- **不重开**总账 D 表里的决定（timed 部署、手动重试、刷新令牌轮换、多实例中转、鸿蒙、逐插件页…）。
- 0 个真机回合优先：能靠源码与单测定论的就别上真机；**要真机先报价**（约几个轮次）并拿到准。
- 本轮若只读不写：`git status` 必须为空；若写了分析文档，一个提交（笔记 + 文档同批），提交前看完整清单。
- 门禁口径：connector 611 / flutter 1140 / boundary 360 / relay 86 / protocol 454·26·49 / icons /
  tool-paths 23 / CDP（proto·authz 18·settings 28·tasks 53·picker·drawer 25·subs 41·turns 60）。
  **只读审计不跑全套**；一旦改代码，按 AGENTS.md §5 跑对应门禁，且**不许降**（两处已记录的下降除外）。

## 3 特别提醒（上一轮的教训）

- **别把"看起来更安全"当成理由就加边界**：超时 / 档位 / 失败兜底 / 未处理记录都是这么长出来的。
- **DSH 的浏览器客户端是参照系**：`packages/client/ui-approval/src/client/index.ts`、
  `ui-user-questions/src/client/index.ts` —— 它怎么答、什么时候放弃、卡片怎么关，就是"原生"。
- **网关的多客户端语义**：`packages/api/gateway/src/index.ts:571,676-679,696-699,717-721,734-745`，
  以及 DSH 自家用例 `packages/api/gateway/tests/gateway-stream.host.spec.ts:1320,1402`
  （fan-out + 第一个 result 结算；全员 next 才交还 Host）。
- 若要动 `protocol/`：fixtures 断言数须与 `connector/tests/fixtures.test.ts` 的
  `REFERENCE_CHECK_COUNT` 相等（当前 **454**），两侧同时改。

## 4 收尾

- 分析结论落到总账（见 1.4）；
- memory.md 的待办/已知缺口按结论更新（收口的划掉、新发现的补上）；
- `git status` 只剩有意改动；一个提交。
```

## 说明（给用户，不用贴）

- 这轮不实现是**故意的**：上一轮就是在实现里连续两次"顺手加了边界"，先求证再动手更省。
- 最可能被抓出来的三处（按我的判断）：**审批对 `callId` 的依赖**（B2，浏览器没有这个依赖）、
  **`question-call.ts` 的身份推断**（B1，是我们通道选型逼出来的）、
  **App 的 `danger-full-access` 入队过滤**（B4，可能是一条永远不会命中的规则）。
- 真机成本：这次三条都能用源码/单测定论，预计 **0 个真机回合**；若某条必须真机，先报价再跑。
