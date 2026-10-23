# Agent Note: 「我们替 DSH 做了决定」总账 —— 已逐条求证 + 归类

Status: proposed（**结论已求证**；10/11 已落地，剩 W4）

## 落地进度（2026-10-24，每件一个提交）

| 单 | 状态 | 提交 / 笔记 |
|---|---|---|
| W1 身份面改读原生 | ✅ | `4acb23c` · `implemented/2026-10-24-interaction-identity-from-native-ids.md` |
| W2 换代不撤在途 claim | ✅ | `1ba20a0` · `implemented/2026-10-24-claims-survive-stream-generation.md` |
| Z1 删 `full-access` 审批过滤 | ✅ | `cdc9aa9` |
| Z2 删 `presence.onOffline` | ✅ | `55ea630` |
| Z3 匿名限流按来源地址分桶 | ✅ | `eee1569` |
| Z4 删 `relay.stats.devices` | ✅ | `bbfa5f7` |
| Z5 配对码输入关联想 | ✅ | `67d0397` |
| Z6a 预设文案跟上 DSH | ✅ | `748edcf` |
| Z6b IPv6 仅排后写进 §15 | ✅ | `e1a421a` |
| **W3 终态只有一个来源** | ✅（代码）／真机待跑 | 见 `implemented/2026-10-24-terminal-identity-from-pc.md`；**真机 1–2 回合未跑** |
| **W4 运行态改读原生** | ⏳ | 要加一条契约帧（最大一件），1 个真机回合 |

门禁（10 件落地后）：protocol **454·26·49**、boundary **360**、connector **615**、
relay **87**、flutter **1144**、analyze/format **0**、icons / tool-paths 绿。
真机回合：**0**（W3 的验证 1–2 回合、W4 的 1 回合另计，均未跑）。

## 这一轮做了什么

2026-10-23 的交互改造里，用户两次点破同一个毛病：**替宿主做了它已经做过的决定**
（给审批加 10 分钟超时；给审批加"谁接管"三档）。那三处已删（原则见
`implemented/2026-10-24-native-semantics-first.md`）。本篇是**总账的第二版**：把第一版里
13 条"待求证候选"与 15 行"已知缺口"逐条落成**结论 + 归类 + 证据 + 建议**。

判据没变，仍是那三问：

1. **删掉这条规则，DSH 会不会已经给出答案？** 会 ⇒ 我们不该有。
2. **它是在补"我们这条通道没有的东西"，还是替宿主做决定？** 补通道可以，替决定不行。
3. **它写进 `docs/` 了吗？同一件事是不是只有一处表达？**

证据等级：DSH 自家测试 > DSH 源码 `packages/...:行号` > 我们的单测 > 真机。
**本轮 0 个真机回合**（全部靠源码与单测定论），未找到的写「未找到」，不猜。

## 结论摘要（先看这六行）

- **真正"替宿主做决定"的只剩两条**：审批没有 `callId` 就不参与（B2）、
  `danger-full-access` 下审批不入队（B4）。前者是因为**我们把身份钉死在 tool call 上**，
  后者是**永久不可达的死规则**。
- **两条"设计缺陷"其实是同一个动作的两个影子**：待处理项的键选了 `callId`
  （B1/B6），于是审批没 `callId` 就答不了（B2）—— 这一半已经按原生收口（W1 已落地）。
  **另一半（C11 计划审查）查完发现不是同一个病**：身份（`intent.callId`）拿得到，
  但手机那张卡**根本不存在**，所以改判 `未实现`，要的是"卡来自请求"的投递（B12 升级）。
- **宿主早就给了"会话在不在跑"这个事实**（`SessionSummary.running` +
  `api-session/status` 推送，DSH 浏览器就是吃这条），我们没转发，于是手机自己用
  `turn/start`/`turn/end` 加一轮"代号护栏"重建（B5）。
- **`$events` 换代时撤掉在途 claim 是我们自己发明的"终态"**（C13）：DSH 换代只撤**投递**、
  不结算（`api/gateway/src/index.ts:717-721`），新 client 上来还会**重投**（`:571`）。
- **手抄的第二份真值已经漂了**：极简模式的描述在 DSH 是"终端和图片读取工具，并支持上下文压缩"，
  我们抄的是旧文案（B13），而且测试复述的是同一份手抄字符串。
- 立得住、不用改的：命令白名单（B8）、设置 allowlist（B9）、大对象阈值（B10）、
  优先级 2>1>0（B11）、待处理集合只从会话事件来（B12）、App 的失败分类（B3）。

## B. 逐条求证（原"待求证候选"13 条）

| # | 结论 | 归类 | 我们 file:line | DSH 证据 | 与原生语义的差异 | 建议 |
|---|---|---|---|---|---|---|
| B1 | **不是自创**（日志推断是补通道），但**根因是我们自选的键** | `设计缺陷` | `connector/src/dsh/question-call.ts:76-95`；`connector/src/dsh/interaction-client.ts:368-393` | 浏览器回答**不需要** callId：`ui-user-questions/src/client/index.ts:107-115`（没有 callId 就新建一张卡）、`:217-218`、`:275-276`；timed 形态才带 `wait.callId`（`user-questions/src/types.ts:136-145`）；计划审查的原生身份在 `intent.callId`（`plan-mode/src/index.ts:326`） | 我们把"待处理项的身份"等同于 `tool/call` 的 id。原生有两处身份：`wait.callId`（timed）与 `intent.callId`（计划审查），后者我们**完全没读** | **改读原生**（顺序：`wait.callId` → 日志推断），**不接 `intent.callId`**（计划审查的卡在手机上不存在，claim 它会把 DSH 的 fail-closed 换成挂起）—— **已落地**，见 `implemented/2026-10-24-interaction-identity-from-native-ids.md` |
| B2 | **自创** | `自作主张` | `connector/src/dsh/interaction-client.ts:330-335` | 浏览器在 `callId === undefined` 时**照样弹卡、照样答**（`ui-approval/src/client/index.ts:45-53`、`:59-65`）；审批的原生身份是服务铸的 `ApprovalRequestId`（`user-approval/src/types.ts:13-17`、`index.ts:224-232`）。**未找到**"没有 callId 就拒答"的 DSH 规则（`acp/src/index.ts:161` 那条是 ACP **自己的协议**要求 toolCallId，不是 approval 的语义） | 我们**替宿主决定"手机不参与这类审批"**；后果比"少答一类"更宽：这条审批**连重投也拿不到**（`connector/src/dsh/ask-event.ts:65` 按 callId 匹配） | **改读原生**：审批的 claim 键改成 `approval/asked.id`（手机侧早就在用它当卡 id，`app/lib/data/projection.dart:997,1003`）—— **已落地**，见 `implemented/2026-10-24-interaction-identity-from-native-ids.md` |
| B3 | **不是自创** | `设计缺陷`（可接受） | `app/lib/ui/chat_page.dart:378-395` | 浏览器的三个出口（答 / `next()` 委托 / `signal` 中止）在 `ui-approval/src/client/index.ts:59-69`、`ui-user-questions/src/client/index.ts:258-266`；`interaction/not-pending` 的客户端动作在契约 §3.1（`docs/subsystems/remote-channel.md:154`） | 浏览器只有"这条 invocation 结束"这一种终态；我们的卡是**会话事件的投影**，通道失败时那条 `approval/decided` 还没来 ⇒ "其余留卡"是通道层的必要补丁，不是替宿主决定 | **保留**；把"其余错误留卡可重试"一句补进契约 §3.1（现在只在代码注释里） |
| B4 | **自创**（且在本部署**不可达**） | `自作主张` | `app/lib/ui/takeover.dart:193-195`；提示语 `app/lib/ui/chat_page.dart:353-358` | `danger-full-access` 预设 = `sandbox: danger-full-access, approval: 'never'`（`bundle/base/cordis.patch.yml:274-276`、`permission-presets/src/index.ts:193-195`）；`'never'` 在 **dispatch 之前**就 `rejected`（`user-approval/src/index.ts:270-275`）⇒ **根本不产生 `approval/request`**。浏览器侧没有任何同类过滤 | 多了一层 DSH 没有的过滤，而它过滤的是一个不会发生的场景；那句"完全权限下不再逐步确认：X 直接执行"因此是一条**永远显示不出来**的提示（promise-preset 与 policy 只由 `permissionPresets.set` 成对写，`:272`） | **删**（过滤 + 那条 toast），见 Z1 |
| B5 | **自创**（原生已有该事实，我们没转发） | `设计缺陷` | `app/lib/data/app_model.dart:1899-1933`（重建）、`:2738-2751`（代号）、`:2756-2777`（唯一真值） | `SessionSummary.running`（`api/session-controller/src/types.ts:185`，取值 `list.ts:120` 的 `agent.status === 'running'`）；**原生推送** `api-session/status`（`types.ts:617-622`、`index.ts:204-205`），在转发清单里（`api/remotes/src/remote-events.ts:33`），DSH 浏览器直接吃（`session-controller/src/client/index.ts:118-119`、`manager.ts:726-734`） | 宿主把"在不在跑"当**一条推送**；我们用两条会话事件 + 一次列表重读 + 代号护栏重建同一事实 | **改读原生**：连接器订阅 `api-session/status` 并转发，App 删掉重建与代号；见 W4（**收益最大、代价也最大**：要动契约帧） |
| B6 | **自创** | `设计缺陷` | `connector/src/interaction-claims.ts:63-77`（`callId` 必填）；`connector/src/interaction-face.ts:200-204`（`RespondParams.callId`）；幂等键 `app/lib/data/app_model.dart:3160`（`i:<callId>`） | DSH 没有"卡 id"这个概念：审批是 `ApprovalRequestId`（`user-approval/src/types.ts:17`），提问的卡按 `ToolCallId` 分组（`ui-user-questions/src/client/index.ts:87-89`），计划审查挂在 `intent.callId` 上（`plan-mode/src/index.ts:326`） | 我们把"待处理项身份"折成**一个** `callId`，于是两个原生的身份里必须有一个能伪装成另一个 | **改读原生**：`interaction.respond` 的键改成 `itemId`（`i:<approvalRequestId>` / `t:<callId>`），与手机已有的 `itemId` 对齐；见 W1 |
| B7 | **不是自创**（它是被删规则的配套） | `实现缺陷`（死代码 + 过期注释） | `connector/src/presence.ts:73-81`（契约面）、`:94-95`、`:125-135`（触发）、`:177-188`（实现）；生产**零调用**（只有 `presence.test.ts` 一条） | 触发它的那条规则已经删了：DSH 里"手机断开"不结算任何交互（`api/gateway/src/index.ts:717-721` 只撤投递；A2/A4 已收口） | 注释还写着"在途审批的看护要靠它收口、契约 §6.2 的『手机断开 → unavailable』"—— 那条规则**不存在了** | **删**（字段 + 监听桶 + 注释），见 Z2 |
| B8 | **不是自创** | `有意偏离` | `connector/src/handlers.ts:77`（名单）、`:952`（拦） | `/goal` 注册在 `goal/command-goal/src/index.ts:191-197`，已有目标拒 `create`（`:143-149`）、`clear` 重复是 no-op（`:171-174`）；`/plan` 注册在 `plan/plan-mode/src/index.ts:230-274`，`set` 回 `committed/queued/cancelled/noop` | 无（准入三条齐备，且只有一处表达：契约 §5.7 的 `command.execute` 行 + `MOBILE_COMMANDS`） | **保留**；复核已过（`/plan <message>` 会 steer 一条用户消息，仍在会话之内，不违反准入①） |
| B9 | **不是自创** | `有意偏离` | `connector/src/dsh/settings-face.ts:26-40` | 三条写面与 Web 逐条对齐：`permission.defaultPreset`（`ui-permission-presets/src/client/settings-store.ts:122-126`）、`agent-preset-registry.selectedDefault`（`ui-agent-preset/src/client/settings-store.ts:30-37`）、`session-log-deepseek.enabled`（`ui-settings-session-log/src/client/index.ts:36-37` → `config-form.ts:129-134` 落到同一个 `settings.mutate(ns, …)`） | 无（**没有漏项**，也没有"该只读的能写"；Web 侧读 `writable` 再写，我们不预判、把宿主的拒绝原样报出，方向是"宿主是权威"） | **保留** |
| B10 | **不是自创** | `有意偏离`（协议参数） | `connector/src/config.ts:38,55`（默认 1 MiB）；`connector/src/session-page.ts:40,75` | **未找到** DSH 侧的字节阈值：`threshold` 全仓命中都无关（compaction / ui / webserver 压缩）。DSH 的大条目靠分页（`session.page`）与投影，不靠"改走重取" | 这是我们这条通道的成本决定（8 MiB 单帧上限 + 封箱放大 ≈1.78×），宿主没有对应概念 | **保留**；契约 §5.3（`remote-channel.md:295`）已经写明这是本仓参数 |
| B11 | **不是自创**（已对齐） | `有意偏离` | `app/lib/ui/takeover.dart:36-38`、`:219-225` | 行号仍指向优先级本体：`ui-user-questions/src/client/index.ts:371-373`（`plan-review ? 2 : 1`）、`ui-approval/src/client/index.ts:88-90`（`() => 0`） | 无 | **保留**（本轮复核通过；下次 DSH 升级再核一次行号） |
| B12 | **不是自创** | `设计缺陷`（可接受） | 契约 §6.3（`remote-channel.md:514-520`）；`connector/src/session-subscriptions.ts:282`；判据 `connector/src/dsh/interaction-client.ts:419-424` | DSH 的浏览器也在**会话作用域**里看待处理项（`ui-approval` 用 `ctx.sessions.scopeOf`，`:43-44`）；它的"没打开这个会话也照样收到"靠的是**一条常连**，我们靠订阅 | 手机不订阅 ⇒ 看不到卡；但连接器**照旧 claim**（`sidOf` 只看别名表，不看订阅），于是"一台看不到卡的手机接住了一条等待"。无害（桌面照旧答、订阅后还能补答），但要在契约里写明 | **保留 + 写进 docs**：§6.3 补一句"claim 判据是会话登记，不是订阅" |
| B13 | **是有意偏离，但已经坏了** | `实现缺陷`（第二份真值已漂移） | `app/lib/model/agent_preset.dart:42-56`（四档文案）、`:28`（`isBuiltIn` 判据）；`app/lib/model/permission.dart:160-191`（三档图标/文案） | 内置名只在**客户端 locale 包**里：`ui-agent-preset/src/client/locales.ts:95-102`；宿主只给自建预设的 `name`（`agent-preset-registry/src/display.ts:48-49,63-73`）⇒ 手机拿不到，只能抄 | **已漂**：`minimal` 的描述 DSH 是"Agent 使用终端和图片读取工具，并支持上下文压缩…"（`locales.ts:100`），我们抄的是旧文案（`agent_preset.dart:51`）。且 `app/test/agent_preset_test.dart:103-106` **复述同一份手抄字符串**，测不出漂移 | **保留手抄**（宿主不发布）+ **修字** + 一条"DSH 升级后重抄"的清单；见 Z6a |

## C. 已知缺口逐行求证（原"按归类重排"15 行）

| # | 结论 | 归类 | 我们 file:line | DSH 证据 / 事实出处 | 与原生语义的差异 | 建议 |
|---|---|---|---|---|---|---|
| C1（待办 4） | 不是自创（我们自己的中转/App 形状） | `逻辑语义` | `app/lib/core/pairing_client.dart:80`（401/409 → `notPaired`）；`app/lib/core/errors.dart:92-93`（→ `rePair`）；`app/lib/platform/ticketed_transport.dart:68-77`；`app/lib/core/sync_client_impl.dart:311-320` | 未找到 DSH 对应（中转是本仓的）。中转把三件事合成 401：令牌无效 / 已吊销 / 没见过（`relay/src/device-registry.ts:88`、`relay/src/digest-auth.ts:43,59`、`relay/src/http-face.ts:61`） | "名册被我清空了"（**可恢复**）与"你被停用了"（**终态**）在线上是同一条 401，而 App 把它读成终态并清凭据 | **改**：换票 401 **不再当终态**（中转只知道"名册里没有我"，而名册是电脑推的 ⇒ 可恢复）；终态只认电脑侧的**明说**（close 4003 + 身份类协议码）。**不让中转假装知道 revoked** —— 它不知道，造那条知识要新加一个协议面 —— **已落地**，见 `implemented/2026-10-24-terminal-identity-from-pc.md` |
| C2（已知缺口 3） | 不是自创 | `逻辑语义` | 服务端 `connector/src/transport/connection.ts:660`（close 4003）；错误表 `connector/src/protocol/errors.ts:30`；客户端终态判据只覆盖**建连失败**（`app/lib/core/sync_client_impl.dart:316-320`） | 未找到 DSH 对应（握手是本仓的）；"身份不被认 = 终态"这条原则已在 `sync_client_impl.dart:311-315` 与 `endpoint_transport.dart:142-153` 写死 | 同一件事有两条路：换票 401 走终态，握手 close 4003 / `protocol/revoked` 帧仍走退避 ⇒ "终态被当成可重试" | **改**：与 C1 同批收口（终态判据只写一处）—— **已落地**：`TransportClosed` 按**理由**判，4003 + `rePair` 码才是终态；见 `implemented/2026-10-24-terminal-identity-from-pc.md` |
| C3（已知缺口 1） | 不是自创 | `实现缺陷` | `relay/src/http-face.ts:41`（键是字面量 `'pairing:anonymous'`）；桶参数 `relay/src/server.ts:68`（60 容量 / 6 每秒） | 未找到 DSH 对应（中转是本仓的） | 所有**未配对**设备共用一个桶 ⇒ 约 6 req/s 就能让全部新设备 429 | **改**：匿名键按来源地址分桶（与设备键同一个 limiter）；见 Z3 |
| C4（已知缺口 2） | 不是自创 | `实现缺陷`（名字与语义不符） | `relay/src/core.ts:61-62`：`devices: channels.size` 与 `channels: channels.size` **恒等** | 未找到 DSH 对应 | 两个字段同义 ⇒ `devices` 不携带信息，读它的人会以为在数设备 | **删** `devices` 字段（或改成 distinct deviceId 数）；见 Z4 |
| C5（已知缺口 4） | 不是自创 | `实现缺陷` | `app/lib/ui/pairing_page.dart:413`（`TextField` 无 `enableSuggestions` / `autocorrect` / `keyboardType`） | 未找到 DSH 对应（配对码是本仓的） | 输入法联想会把**手打**的 JSON 改坏（粘贴没事） | **改**：一行（`enableSuggestions: false, autocorrect: false`）；见 Z5 |
| C6（已知缺口 6） | 不是自创 | `实现缺陷` | `connector/src/transport/listener.ts:131-145`（只跳 `fe80`） | 未找到 DSH 对应 | RFC 4941 隐私地址仍进候选列表（只被 IPv4 排前，`listener.ts:150`） | **不改**：Node 的 `os.networkInterfaces()` 不暴露 `temporary` 标记，判据只能靠前缀猜 ⇒ 写进契约 §15（"仍会上报、只排后"），见 Z6b |
| C7（本轮新增） | = **B7** | `实现缺陷` | 同 B7 | 同 B7 | 同 B7 | 同 B7（只计一次） |
| C8（已知缺口 5） | 不是自创 | `验证缺口` | `connector/src/admin/advertise.ts`（逻辑）；HTTP 面 `connector/src/admin/routes.ts:205,252-282` | 未找到 DSH 对应 | API 有单测、i18n 有键完整性门禁，但**面板的布局与点击没有自动化** | **补一条**（CDP 组里加一个断言即可）；优先级低于 W1 |
| C9（已知缺口 10） | 不是自创 | `验证缺口` | 单测 `app/test/new_session_workspace_test.dart:203-231,368-393`；`connector/tests/workspaces-archive.test.ts:55-76` | 宿主字段 `WorkspaceView.createdAt`（`api/workspace-controller/src/types.ts:27`）；同一判据 `ui-workspace/.../navigation.ts:565` 的 `recentWorkspace` | 无（判据同源）；只是真机**够不到**那条分支（手机总会恢复上一次会话） | **保留**（要验得先有"无当前会话"入口）；写进 §15 的方式已在 memory 记着 |
| C10（待办 7） | 不是自创 | `验证缺口` | `app/lib/data/projection.dart`（异常结局 / 压缩标记的解析）；没有稳定制造失败回合的手段 | DSH 侧压缩标记是既有事件（`compaction/compaction`） | 无（能力有，场景造不出） | **保留**（要一次真机 + 一个会失败的回合，成本 1–2 回合，未开） |
| C11（待办 11 尾巴） | **不是自创**（改判：身份拿得到，缺的是**投递**） | `未实现` | `connector/src/dsh/interaction-client.ts:368-393`（只读 `wait.callId` + 只认 `ask_user_question` 的 tool/call）；演示入口 `app/lib/ui/chat_page.dart:2385-2388`（`_enqueueDemoTakeovers`） | 计划审查是**程序化** `ask()`，无 `wait`，但**带 `intent.callId`**（`plan-mode/src/index.ts:313-330`，`callId: exec.callId` 在 `:326`）；浏览器照样弹卡（`ui-user-questions/src/client/index.ts:107-115`） | **计划审查卡在手机上不存在**（`InteractionKind.plan` 只有演示能造）。原因不是少读一个字段：手机的卡只从 `ask_user_question` 的 `tool/call` 生成，`exit_plan_mode` 只落一条普通工具行 | **不做**（原来写"改读 `intent.callId`"是**错的**：claim 一条用户看不到的交互，会把 `NO_PROVIDER` 的 fail-closed 换成永远挂起）。限制已写进契约 §15/§6.3.1；要真答需"卡来自请求"的投递（B12 升级） |
| C12（待办 1 尾巴） | 不是自创 | `设计缺陷` | `app/lib/ui/chat_page.dart:2993`（`reverse: true`）；`chat_jumper.dart:32-34`、`chat_page.dart:2704-2723` | 未找到 DSH 对应（DSH 是 DOM 滚动，不做列表 `reverse`） | 收起/展开改变格数 ⇒ 点开的那一轮可能移出屏幕 | **保留**（390dp 上做锚点滚动的代价大于收益）；已写进 `docs/subsystems/turn-groups.md` 的边界 |
| C13（本轮新增） | **自创** | `逻辑语义` | `connector/src/dsh/interaction-client.ts:497-504`（换代时 `cancelDelivery` 全部 + `await Promise.allSettled(tasks)`） | DSH：换代只撤**投递**、**不结算**（`api/gateway/src/index.ts:717-721`）；新 client 上来**重投**同一 `eventId`（`:571`）；重复/迟到结果是 no-op（`:696-699`）；`{kind:'next'}` 只是撤掉自己那一份投递（`:700-709`） | 我们把"这条流换代了"当成"这条 claim 结束了"——**用连接态覆盖了宿主态**。于是手机点答拿 `not-pending`、App 撤卡，而桌面那张卡还在 | **改**：换代不撤 claim（只撤投递、只换 clientId），`dispose()` 才撤 —— **已落地**，见 `implemented/2026-10-24-claims-survive-stream-generation.md` |
| C14（待办 8） | 不是自创 | `未实现` | 开工单 `proposed/2026-10-20-file-upload-shape.md` | DSH 入口 `client/file-upload/src/index.ts:105,118` | 无（范围外） | 保持（8 个触达点，别半截提交） |
| C15（待办 1） | 不是自创 | `未实现` | `docs/subsystems/turn-groups.md` §"阶段 2" | —— | 无（产品决定：390dp 上两层组头要两次点击） | 保持（暂不做） |

## N. 本轮新发现（原总账里没有的）

| # | 发现 | 归类 | 证据 | 建议 |
|---|---|---|---|---|
| N1 | `InteractionFace.pendingOf` / `projectPendingQuestions` / `PendingItem` / `itemIdOf` 在**生产里零调用**（只有 `connector/tests/interaction-face.test.ts:139-142` 用）；它的 id 约定 `i:<callId>`（`interaction-face.ts:101-105,132-134`）与手机侧 `i:<approvalId>`（`projection.dart:1003`）/ `t:<callId>`（`:1031`）**已经不一致** | `实现缺陷`（死码 + 两处约定） | 见左 | **已落地**（W1 里删死码，`itemIdOf` 换成 `approvalItemId` / `questionItemId` / `interactionItemOf`） |
| N2 | 内置预设文案**已经漂移**（见 B13），且现有测试复述同一份手抄字符串 | `实现缺陷` | `app/lib/model/agent_preset.dart:51` vs `ui-agent-preset/src/client/locales.ts:100`；`app/test/agent_preset_test.dart:103-106` | Z6a |
| N3 | 计划审查卡在手机上**不可达**；改判原因是**没有卡**（不是没读 `intent.callId`）—— 见 C11 | `未实现` | C11 行 | 不做，限制写进契约 §15/§6.3.1 |
| N4 | 没有 `callId` 的审批不仅答不了，**重投也拿不到**（`ask-event.ts:54-68` 按 callId 匹配 `approval/asked`）⇒ B2 的后果比原判断更宽 | `自作主张` | 见左 | **已落地**（W1：键换成 `ApprovalRequestId`，重投按 `id` 匹配） |

## 归类统计

| 归类 | B 表 | C 表 | N 表 | 合计 | 分别是 |
|---|---|---|---|---|---|
| `自作主张` | 2 | 0 | 1 | **3** | B2（审批无 callId 就不参与，**已落地修**）、B4（fullAccess 过滤）、N4（B2 的加重项，**已落地修**） |
| `设计缺陷` | 5 | 1 | 0 | **6** | B1、B3、B5、B6、B12、C12 |
| `逻辑语义` | 0 | 3 | 0 | **3** | C1、C2、C13 |
| `实现缺陷` | 2 | 4 | 2 | **8** | B7、B13、C3、C4、C5、C6、N1（**已落地修**）、N2 |
| `验证缺口` | 0 | 3 | 0 | **3** | C8、C9、C10 |
| `有意偏离` | 4 | 0 | 0 | **4** | B8、B9、B10、B11（**不是缺陷**） |
| `未实现` | 0 | 3 | 1 | **4** | C11（改判）、C14、C15、N3 |

（C7 = B7，只计一次。）

**只看你要的两张表（B1–B13 + C 表，去重后 27 行）**：
`自作主张` **2** / `设计缺陷` **6** / `逻辑语义` **3** / `实现缺陷` **6** /
`验证缺口` **3** / `有意偏离` **4** / `未实现` **3**。
加 N 表的四条新发现共 31 行（N4 与 B2 同一处，按行数仍记 4 条）。

**改判记录（2026-10-24，W1 落地时）**：C11 从 `设计缺陷` → `未实现`。原判断"读漏了
`intent.callId`"只对了一半：身份确实拿得到，但手机那张卡根本不存在，所以 claim 它只会把
DSH 的 `NO_PROVIDER` fail-closed 换成永远挂起。

**最值得先做的一条：W1（身份面改读原生）。** 三个理由：

1. **一条收口三处登记**：B1（日志推断只剩提问需要）、B2（审批不再因为没 callId 就退出）、
   B6（respond 的键不再是 `callId`）。
2. **它是"删规则"而不是"加边界"**：删掉的是"没有 callId 就不参与"这条**替宿主决定**的判断，
   换上来的是宿主自己铸的 id（`ApprovalRequestId`）。
3. **证据最硬、改动面最小**：手机侧**早就在用** `approval/asked.id` 当卡 id

   （`projection.dart:997,1003`），连接器也早就在日志里按 `id` 配 asked/decided
   （`ask-event.ts:58-61`）——只差"把它当键读出来"。

**✅ 已落地（2026-10-24）**：`implemented/2026-10-24-interaction-identity-from-native-ids.md`
（connector 611 → 615、flutter 1140 全绿、变异校验两组各恰好红在对应条目）。

## 根因分段（同类问题的共同形状）

1. **身份被钉死在 tool call 上**（B1 / B2 / B6 / C11 / N1 / N3）
   一条链：待处理项的键选了 `callId` ⇒ 审批没有它就"不参与"；提问没有它就去日志里猜；
   而 `approval/asked.id`（服务铸的、asked/decided 的配对键）明明在手，却没用来当键。
   计划审查是这条链的**另一半**：身份拿得到（`intent.callId`），但**卡本身不存在** ——
   所以它不是"身份"问题，是"投递"问题（C11 因此改判 `未实现`）。
   **形状**：把"某个具体形态的身份"当成"这件事的身份"。

2. **把连接态当语义态**（C1 / C2 / C13）
   中转重启、流换代、进程重启 —— 这些都是**通道事件**，却被翻译成宿主语义：
   claim 结束（C13）、设备未配对（C1）、终态不重试（C2）。
   **形状**：可重试的当成终态；宿主还挂着的当成撤卡。DSH 的规则恰好相反：
   断线只撤**投递**（`api/gateway/src/index.ts:717-721`），claim 挂在 Host 上。

3. **用 App 侧状态机补协议缺口**（B5 / B12 / B3）
   宿主已经有的事实（`running` + `api-session/status` 推送、`writable`、审批 id）
   没转发，于是手机自己推（`_runningSids` + 轮次代号）、自己分类失败、自己判卡的去留。
   **形状**：一份真值长在两端，靠"重建 + 护栏"对齐。

4. **第二份真值 + 没有门禁**（B13 / N2）
   内置预设的显示名宿主不发布，只能抄 —— 这是**可接受**的偏离；但抄的东西没有比对门禁，
   于是它已经静默漂了一条（极简模式），而测试复述的还是同一份手抄串。

5. **规则删了、字段还在**（B7 / N1）
   A2/A4 删掉看护与离线兜底之后，配套的 `onOffline`、"待处理集合"API 没跟着删，
   注释还指着已删的规则（"看护要靠它收口"）。**形状**：删除只删了行为，没删接口与说法。

6. **"看起来更安全"的过滤**（B4）
   `danger-full-access` 下不给审批入队 —— 而 DSH 用 `policy: 'never'` 在 dispatch 之前
   就拒了（`user-approval/src/index.ts:270-275`），这条过滤**永久不可达**。
   **形状**：为一个不会发生的场景加一层边界，并配一句永远显示不出来的承诺。

## 开工单（每件一个提交）

| 单 | 标题 | 覆盖 | 笔记 |
|---|---|---|---|
| ~~W1~~ | ~~身份面改读原生~~ **✅ 已落地（`2026-10-24`）** | B1、B2、B6、C11（改判）、N1、N3、N4 | `implemented/2026-10-24-interaction-identity-from-native-ids.md` |
| ~~W2~~ | ~~换代不撤在途 claim~~ **✅ 已落地（`2026-10-24`）** | C13 | `implemented/2026-10-24-claims-survive-stream-generation.md` |
| W3 | 终态身份面收口（中转分开说） | C1、C2 | `proposed/2026-10-24-terminal-identity-from-relay.md` |
| W4 | 运行态改读原生 `api-session/status` | B5 | `proposed/2026-10-24-running-from-native-status.md` |
| Z1–Z6 | 零碎清理（每行一个提交，无备选方案故不各自立笔记） | Z1 B4 / Z2 B7 / Z3 C3 / Z4 C4 / Z5 C5 / Z6 C6·B13 | `proposed/2026-10-24-audit-cleanup-batch.md` |

**审计外的顺手修（已落地 `2da3745`）**：`app/test/fixtures_test.dart` 还写死"16 条 fixtures"，
而 `fce4f9e` 删了 fixture 16 ⇒ `flutter test` 从那时起一直是红的。这正是"条数要几处同步"
那条纪律漏掉的第四处；文件头已写清。

**执行顺序（用户已准 2026-10-24，每件一个提交，0 真机优先）**：
~~W1~~ **✅ 已落地** → W2 → Z5 → Z2 → Z1 → Z4 → Z3 → Z6a → Z6b → W3（1–2 回合）→
W4（1 回合，要加一条契约帧）。
铁律：**别擅自加规则，DSH 原生就行** —— 剩下的十件里没有一件是"新增边界"，全是删规则、
改读原生，或把已存在的限制如实写进 docs。

**不动代码就要补进 docs 的两句**（随对应工单落地，不单独提交）：

- 契约 §3.1：`interaction/not-pending` 之外的失败**留卡可重试**（B3）。
- 契约 §6.3：claim 的判据是"会话登记给手机"，不是"手机订阅了"（B12）。

## A. 已收口（原样保留，防止重开）

| # | 撤掉的规则 | 证据 | 归类 |
|---|---|---|---|
| A1 | 审批看护超时（10 min，`Watchdog` / `approvalWatchdogMin`） | 浏览器卡无超时：`packages/client/ui-approval/src/client/index.ts:59-69` | 自作主张（已删） |
| A2 | "未处理记录" + `METRIC.failClosed` + `hold`（沉默） | DSH 自己的兜底是 `unavailable`：`user-approval/src/index.ts:281-283` | 自作主张（已删） |
| A3 | 三档 `approvalTakeover` + `decideTakeover` + `fixture 16` + `takeover.mjs` + store 的 `takeover` 表 | 委托语义与"全员 next 才交还"：`gateway-stream.host.spec.ts:1402` | 自作主张（已删） |
| A4 | 端口前"设备离线就不呈示"的兜底 | 连着就是 client（有投递），不连就没有 | 自作主张（已删） |

本轮复核：这四条删得对，且**没有回来** —— `connector/src` 与 `app/lib` 里
`approvalTakeover` / `decideTakeover` / `failClosed` / `UnhandledInteraction` **零命中**；
`Watchdog` 只剩 `connector/src/transport/relay-link.ts:62` 的**链路心跳**（`armWatchdog`，
与审批无关，别误删）。唯一残留是 A2/A4 的配套接口（B7）。

## D. 明确"不做"的（防止新人重开，本轮未重开）

timed 部署（桌面倒计时 + 模型 120 s 后继续）、失败回合手动重试（DSH Web 也没有）、
刷新令牌轮换、中转多实例、鸿蒙适配、逐插件页面、PC 端管理页面、
"所有会话都在手机上推送"（= 加推送帧，见 B12）。

## 引用纪律（本轮自查）

- 每个"DSH 这么做"都给到 `packages/...:行号` 或 DSH 自家用例；**未找到**写在单元格里（B9 的漏项、B10 的阈值、C6 的隐私地址判据）。
- 三条 DSH 自家用例是本轮最硬的外部证据：`gateway-stream.host.spec.ts:1320`（fan-out + 第一个 result 结算）、`:1402`（全员 next 才交还 Host）、`:1368`（第一个 rejected 结算）。
- 手机侧的三处断言（`app/test/agent_preset_test.dart:103-106`）**不算证据** —— 它复述的是实现。
