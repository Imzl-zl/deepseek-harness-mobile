# Agent Note: 「我们替 DSH 做了决定」总账 —— 待逐条求证与归类

Status: proposed

## 目的

2026-10-23 的交互改造里，用户两次点破同一个毛病：**替宿主做了它已经做过的决定**
（给审批加 10 分钟超时、给审批加"谁接管"三档）。那三处已经删掉（`08fe52d` 前后，
原则见 `implemented/2026-10-24-native-semantics-first.md`）。

这篇是**总账**：把"可能还是我们自创的规则"和"已经记录但没修的缺口"放在一张表里，
每条都带**为什么可疑 / 怎么求证 / 初步归类**。下一轮只做**求证与归类**，不实现
（除非用户点头）。提示词见 `2026-10-24-next-round-native-rules-audit.md`。

## 方法（0 个真机回合优先）

1. **先读源码**：我们这边的判定点 + DSH 对应位置（`packages/...:行号`）。查不到就写「未找到」，不许猜。
2. **三问**（与 `AGENTS.md` 的常驻军规一致）：
   ① 删掉这条规则，DSH 会不会已经给出答案？② 它是补我们的通道，还是替宿主做决定？
   ③ 它写进 `docs/` 了吗、是不是只有一处表达？
3. **优先级**：DSH 自家的测试 > DSH 源码 > 我们的单测 > 真机。**要真机先报价**（约几个轮次）。
4. 每条结论必须落到一个**归类**（下面是闭集）：

| 归类 | 含义 |
|---|---|
| `自作主张` | 替 DSH 决定了它已经决定的事（超时 / 档位 / 兜底 / 终态） |
| `设计缺陷` | 我们自己的通道/架构选型逼出来的补丁（不删 DSH 语义，但形状可疑） |
| `逻辑语义` | 状态机 / 终态 / 重试 / 幂等的语义错（不是风格问题） |
| `实现缺陷` | 局部写错（键、过滤、解析） |
| `验证缺口` | 造不出场景 / 只有单测，行为未被真机或对端证实 |
| `有意偏离` | 文档已写的产品决定（手机形态、白名单、密钥不回传…），**不是缺陷** |
| `未实现` | 范围外、开工单在 `proposed/` |

## A. 已收口（本轮删掉的，列出来防止重开）

| # | 撤掉的规则 | 证据 | 归类 |
|---|---|---|---|
| A1 | 审批看护超时（10 min，`Watchdog` / `approvalWatchdogMin`） | 浏览器卡无超时：`packages/client/ui-approval/src/client/index.ts:59-69` | 自作主张（已删） |
| A2 | "未处理记录" + `METRIC.failClosed` + `hold`（沉默） | DSH 自己的兜底是 `unavailable`：`user-approval/src/index.ts:281-283` | 自作主张（已删） |
| A3 | 三档 `approvalTakeover` + `decideTakeover` + `fixture 16` + `takeover.mjs` + store 的 `takeover` 表 | 委托语义与"全员 next 才交还"：`gateway-stream.host.spec.ts:1402` | 自作主张（已删） |
| A4 | 端口前"设备离线就不呈示"的兜底 | 连着就是 client（有投递），不连就没有 | 自作主张（已删） |

## B. 待求证候选（**这轮没动，需要新会话核实**）

每条都给：位置 / 现象 / 为什么可疑 / 怎么求证 / 初步归类（待证）。

### B1 `question-call.ts` 从会话日志推 callId

- 位置：`connector/src/dsh/question-call.ts:76`（`resolveQuestionCall`）。
- 现象：legacy 提问没有 `wait.callId`，我们扫日志找**唯一**一条未结算的 `ask_user_question` `tool/call` 当键。
- 可疑：DSH 浏览器**不需要**这个 id（答案沿它自己那条 claim 回去）；我们需要，是因为手机走
  `interaction.respond` 这条**独立通道**，得把"手机那一下"配回某次 ask。
- 求证：① `ui-user-questions` 在 legacy（无 `wait.callId`）时怎么显示卡、怎么回答；
  ② 手机答案能否像审批那样**当 result 回给 waterfall**（若能，整个身份推断可以删）。
- 初步归类：`设计缺陷`（通道选型逼出来的补丁）。

### B2 审批对 `callId` 的依赖 → 没 callId 就委托

- 位置：`connector/src/dsh/interaction-client.ts:331`。
- 现象：`callId` 只在 asker 有 tool call 时才给；没有就回 `next()`。
- 可疑：DSH 浏览器把 `callId` 只当**卡片关联键**（`ui-approval/src/client/index.ts:47-53`），
  没有它照样弹卡、照样 `answer()`。我们却因此少答一类审批。
- 求证：`callId === undefined` 时浏览器是否仍显示并回答；若是，我们也能（用 `eventId` 当键）。
- 初步归类：`自作主张`。

### B3 App 的失败分类（`not-pending` 撤卡，其余留卡）

- 位置：`app/lib/ui/chat_page.dart:371-384`。
- 可疑：DSH 浏览器没有"按错误码决定卡的去留"这套，它只有三个出口（answer / delegate / abort）。
- 求证：这三个出口能否覆盖我们的失败分类；若不能，我们的分类是否只是"通道会失败"的必要补丁。
- 初步归类：`设计缺陷`（或 `有意偏离`，取决于是否能与浏览器三出口一一对应）。

### B4 App 的 `danger-full-access` 下"审批不入队"

- 位置：`app/lib/ui/takeover.dart:192-195`（注释写"原型 `enqueue` 的同一条逻辑"）。
- 可疑：原型是我们自己写的，不是 DSH。若 DSH 在 full access 下**根本不产生审批**
  （policy 不触发），这条过滤就是在替宿主兜一个不会发生的场景 ⇒ 死规则。
- 求证：`danger-full-access` 时 DSH 是否仍可能发 `approval/request`（hook / 显式 ask）。
- 初步归类：`自作主张`（候选）。

### B5 重连重建运行态（`_runningSids` + 轮次代号）

- 位置：`app/lib/data/app_model.dart:1914,1927`；判据 `app/test/running_reconnect_test.dart`（6 条）。
- 可疑：这是我们为"断线期间收不到 `turn/end`"发明的和解规则；DSH Web 靠持久连接，不需要。
- 求证：宿主是否有原生的"会话是否在跑"字段可读（如 `session.list` 行或某个投影）；若有，应改读它。
- 初步归类：`设计缺陷`（用 App 侧状态机补协议缺口）。

### B6 `interaction.respond` 的键形状（`i:<callId>`）与"卡 id"概念

- 位置：契约 §5.7 的 `interaction.respond` 行；`connector/src/handlers.ts` 的幂等键。
- 可疑：DSH 没有"卡 id"；它的 `ApprovalRequestId` 与 `callId` 是两件事。我们把"待处理项 id"钉在
  `callId` 上，才有了 B1 那套推断。
- 求证：待处理项的身份能否用 DSH 自己的 `ApprovalRequestId` / 投影里的 callId 表达。
- 初步归类：`设计缺陷`。

### B7 `presence` 的前后台态与 `onOffline`（规则删了，字段还在）

- 位置：`connector/src/presence.ts:81`（`onOffline` 定义）、`:177`（实现）；`sync.hello.app`（契约 §5.4）。
- 现象：`onOffline` **生产无调用方**（只有一条单测），注释还写着"看护要靠它收口"；
  前后台态/订阅集现在只喂管理面列表。
- 求证：还有没有别的消费方；没有就删（连同 `sync.hello.app` 的去留一并定，它在契约里）。
- 初步归类：`实现缺陷`（死代码 + 过期注释）。

### B8 `command.execute` 白名单（`MOBILE_COMMANDS`）

- 位置：`connector/src/handlers.ts:77`。
- 归类：`有意偏离`（准入三条写在契约 §5.7；不是替 DSH 决定，是手机形态的范围决定）。
- 待复核：白名单里的 `/goal`、`/plan` 是否仍满足那三条准入判据。

### B9 `settings` / `credentials` 的 allowlist 与"密钥不回传"

- 位置：`connector/src/dsh/settings.ts` / `settings-face.ts`；契约 §7.5。
- 归类：`有意偏离`（安全政策）。待复核：allowlist 有没有漏项导致"该只读的能写"。

### B10 `session-refetch` 的阈值与"大对象改走重取"

- 位置：`connector/src/config.ts` 的 `refetchThresholdBytes`；契约 §5.3 / §5.5。
- 可疑：`refetchThresholdBytes` 这个名字是我们起的；DSH 侧对应概念待核。
- 初步归类：`有意偏离`（协议参数，契约有依据）。

### B11 App 的"一问一队 + 计划 2 > 提问 1 > 审批 0"

- 位置：`app/lib/ui/takeover.dart:36-37,206`（注释已引 DSH 两处：`ui-user-questions/src/client/index.ts:372`、
  `ui-approval/src/client/index.ts:89`）。
- 归类：`有意偏离 / 已对齐` —— **不是缺陷**，但要复核引用的行号是否仍指向优先级（DSH 升级会漂）。

### B12 待处理集合只从会话事件来（所以"没订阅就看不到卡"）

- 位置：契约 §6.3；`session-subscriptions.ts` 的 `pendingOf`。
- 现象：手机没订阅该会话 ⇒ 看不到卡（桌面照常答）。这是**通道**的形态，不是替宿主决定。
- 归类：`设计缺陷`（可接受）：要改就得加推送帧（`pending.changed`），代价大、收益小。

### B13 App 手抄的「内置预设文案」与「内置权限档图标」

- 位置：`app/lib/model/agent_preset.dart:38-60`（四档内置文案，注释写"逐字移植
  `ui-agent-preset/src/client/locales.ts:95-102`"）；`app/lib/model/permission.dart:160-181`
  （三个内置权限档键 → 图标/文案）。
- 为什么手抄：内置预设的**显示名只存在于客户端的 locale 包**，宿主不发布
  （`packages/preset/agent-preset-registry/src/display.ts:48-49` 只给自建的 `name`）——
  手机拿不到，只能抄。
- 可疑点：这是**第二份真值**；DSH 改文案 / 加一档时手机会静默漂移。判据是"抄的是不是**只读**数据、
  有没有一条测试钉住它与 DSH 一致"。
- 求证：有没有门禁比对这两张表与 DSH 的 locale（现在应当没有）；若没有，至少把"DSH 升级后重抄"
  写进 `tools.md` 的升级清单。
- 初步归类：`有意偏离`（可接受的第二份真值 + 缺一条升级提醒）。

## C. 已记录但未修的缺口（按归类重排，引 `memory.md` 的条目号）

| 归类 | 条目（memory.md） | 一句话 |
|---|---|---|
| `逻辑语义` | 待办 4 | 中转重启 → 名册空 → 换票 401 → App 归成**终态** `notPaired` ⇒ 清凭据回配对页 |
| `逻辑语义` | 已知缺口 3 | 握手层 close 4003 与 `protocol/revoked` 帧两条兜底仍走退避（终态被当可重试） |
| `实现缺陷` | 已知缺口 1 | 首配匿名限流是**单一全局桶**（约 6 req/s 就能让所有新设备 429） |
| `实现缺陷` | 已知缺口 2 | `stats.devices` 实为**通道数**（名字与语义不符） |
| `实现缺陷` | 已知缺口 4 | 配对码 `TextField` 没关输入法联想（**手打**的 JSON 会被破坏） |
| `实现缺陷` | 已知缺口 6 | IPv6 隐私地址仍上报（只被排后，仍占列表位） |
| `实现缺陷` | 本轮新增 | `presence.onOffline` 死 API + 过期注释 |
| `验证缺口` | 已知缺口 5 | PC「上报地址」面板没有布局/点击的自动化测试 |
| `验证缺口` | 已知缺口 10 | `workspace.createdAt` 的"空工作区当最近"只有单测，真机够不到 |
| `验证缺口` | 待办 7 | 失败回合 / 压缩标记造不出（没有稳定制造失败的手段） |
| `设计缺陷` | 待办 11 尾巴 | 计划审查卡：卡只从 `ask_user_question` 的 `tool/call` 生成，`/exit_plan_mode` 没有卡 |
| `设计缺陷` | 待办 1 尾巴 | 收起/展开改变格数 ⇒ `reverse:true` 下点开的那一轮可能在屏幕外 |
| `设计缺陷` | 本轮新增 | `$events` 换代窗口：在途 claim 被撤，此时手机点答拿 `not-pending`（App 撤卡、桌面卡还在） |
| `未实现` | 待办 8 | 上传文件（8 个触达点，开工单在 `proposed/2026-10-20-file-upload-shape.md`） |
| `未实现` | 待办 1 | 轮组阶段 2「语义过程组」（暂不做：390dp 上两层组头要两次点） |

## D. 明确"不做"的（防止新人重开）

timed 部署（桌面倒计时 + 模型 120 s 后继续）、失败回合手动重试（DSH Web 也没有）、
刷新令牌轮换、中转多实例、鸿蒙适配、逐插件页面、PC 端管理页面、
"所有会话都在手机上推送"（= 加推送帧，见 B12）。

## 输出要求（下一轮）

一张表，每行：`# | 结论（自创 / 不是） | 归类 | 证据（我们 file:line + DSH packages/...:行号） | 与原生语义的差异 | 建议（删 / 改读原生 / 保留并写进 docs）`。
**不许**出现"通常如此""应该没问题"；查不到就写「未找到」。
