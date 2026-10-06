# 远程通道方案评审:可行性、优越性与待补项

> 对象:`design-and-tech-plan.md` §2/§9、`subsystems/remote-channel.md`、`protocol/`。
> 方法:本仓实测(可复现命令见 §7)、DSH 源码逐条核实、三组外部对标调研(开源项目 / 标准 / 平台政策)。
> 证据等级:标注「一手」= 本次直接读到原文或源码;「转述」= 调研员检索所得、附 URL 但未由本次逐字复核;「未找到」= 检索无结论。
> `docs/AGENTS.md` 约定:本文件只写当下事实与接口契约;为什么这样定、否定过什么,见 `.agents/notes/implemented/2026-09-30-channel-review-corrections.md`。

---

## 0. 结论

骨架成立,且不是纸面方案:`protocol/` 已可执行,四条门禁全绿(241 / 20 / 17 项 + 98 图标),变异校验能真的变红。

| 维度 | 判断 | 依据 |
|---|---|---|
| 技术可行性 | 高 | 三条硬前提(插件持出站长连接、`seq` 当修订号、电脑侧薄适配层)均已核实;无阻塞性未知项 |
| 架构优越性 | 高 | 哑中继有生产级同构先例;恢复语义有**标准级**先例(JMAP),且严格于 Matrix |
| 安全 | 中上 | 算法选型是三端约束下的唯一解;缺前向保密与轮换;配对缺带外核对 |
| 性能 | 高 | 实测事件规模下,1000 条窗口与 8 MiB 帧上限都极宽松 |
| 规格完备度 | 中 | §3 六条未覆盖;其中「待审批被当成瞬时事实」会击穿审批承诺 |
| 交付风险 | 中高 | 鸿蒙推送频控与版本线 |

**一句话:** 拓扑与数据源选择没有方向性错误;扣分集中在"协议还没覆盖到 DSH 的真实形态"与平台侧两条硬限制上,均可在写代码前解决。

---

## 1. 优越性(与开源实现和标准的对照)

### 1.1 哑中继不是自创,是 Tailscale DERP 的同构

> "there is never a way for a DERP server to decrypt your traffic. It just blindly forwards already-encrypted traffic from one node to another." —— Tailscale 官方博客(一手)

差别只在补课能力:DERP 只转发在线流量,本方案在中继上加**有界重放窗口**(按会话保留最近若干帧,给不出连续区间就明确说给不了)。这条加法换来的是可执行不变量:「删掉中继全部业务状态后重启仍能收敛」,已由 `protocol/verify-loopback.mjs` 守住。

### 1.2 恢复语义有标准级先例:JMAP 的 `cannotCalculateChanges`

JMAP(RFC 8620 §5.2)规定:服务端无法计算中间变更时**必须返回错误**,而不是给出不完整结果(转述,来源见 §9);IMAP QRESYNC(RFC 7162)提供 modseq 增量 + `VANISHED` 墓碑 + `NOMODSEQ` 退化为全量(转述)。

这两条与本方案的判定完全同形:**要么完整增量,要么明确要求基线快照**;墓碑(upsert 删除)**不构成恢复屏障**。

### 1.3 反面案例:Matrix 允许"第三种状态"

Matrix `/sync` 的 `limited: true` 表示"扣下了一部分事件但仍返回增量",官方作者 ara4n 给的兜底是"直接丢掉该房间的历史,需要时再 backfill",并注明 *"this is what Riot does on Mobile"*;libQuotient 把"从不取回被扣下的事件"记为 bug,原文 *"leaving irrecoverable gaps in the timeline"*(一手,issue #232,2018 年报告、2024 年仍在 backlog)。

**同一问题在本方案里不存在,因为协议不允许第三态。** 但要如实说明适用条件:这份严格性建立在单用户、事件量小的前提上(§6 的实测标定),Matrix 的宽松是超大规模房间的必然妥协。

### 1.4 数据源复用而非重建

- 修订号直接取 `SessionEvent.seq`:会话内单调、从 0 连续、永不重编号(`packages/core/session/src/types.ts:493-500`;持久化 seam 侧 "events are contiguous from seq 0 and never rewritten" —— `packages/session/session-persistence/src/index.ts:118`,转述核实)。
- 基线与增量同源:`follow()` 开场快照 + 无缺口事件帧(`packages/api/session-controller/src/history.ts:120-203`);历史翻页 `page()`(同文件 `:77-112`)。
- 稳定 itemId 由事件自身推导,不用 `seq` 当主键(理由见 §2.6)。

### 1.5 与参考实现 Agents-Anywhere 的差异是硬的

参考实现是「服务端权威 + 存内容」形态,且**全仓库检索 `e2ee` 0 命中**(转述:其 README 自述会话内容、Timeline、上传附件会经服务器或存于服务器;server-architecture 以 PostgreSQL 为 durable source of truth,Timeline upsert 先入 Redis 写缓冲,并自陈两个丢失窗口与修订区间租约、v2.24 不 writer-compatible)。

本方案的取舍点因此是可验证的:**内容不进中继**、**中继无状态**(运维面小一个数量级)、**两侧均主动连出**(零公网暴露)。

另有一处能力差异已核实:参考实现把 `origin === 'subagent'` 的会话**隐藏**(`D:\sudy\github\Agents-Anywhere\dsh-bridge-next\src\host\dsh-runtime\visibility.ts:11`;`native.ts:231` 对不可见会话直接抛 `SESSION_NOT_FOUND`,一手);本方案把后台任务与子代理投影成一等条目,属于净增能力。

### 1.6 参数落点与主流一致

| 参数 | 本方案 | 对照 |
|---|---|---|
| 重放窗口 | 每会话最近 1000 条 | EMQX 每会话默认缓存 1000 条(转述);MQTT5 `Session Present` 布尔位天然两态 |
| 心跳 | 前台空闲时 60 s | Signal 55 s、Syncthing 1 min、ttyd 5 s、Tailscale UDP 映射常见 30 s(转述) |
| 单帧上限 | 8 MiB,>1 MiB 改推 `refetch` | Node ws 默认 100 MiB、Socket.IO 1 MB、Noise 单消息 ≤65535 B、WebRTC DataChannel 建议 ≤16 KB(转述) |
| 触发式推送 | 4 类,一律给用户看的通知 | 与 Apple 对静默推送的限制一致(§1.7) |

`>1 MiB 改推 refetch` 这条把最坏路径绕开了,是容易被低估的设计。

### 1.7 不做静默推送有平台一手依据

Apple 官方:静默推送在用户强杀 App 后由系统丢弃;受设备级 energy/data budget 限制,预算耗尽后当日不再投递;APNs 每 bundle ID 只保留一条、最多 30 天(一手 + 转述)。三端同理(鸿蒙后台消息不唤醒进程、安卓大陆只有厂商通知可用)。→「推送只敲门、正确性靠回前台补课」是唯一三端都成立的形态。

### 1.8 验证方法本身是资产

`protocol/fixtures/` 是唯一规格源、两侧各跑一遍、参考实现只作行为基准不作产品代码;`verify-loopback.mjs` 把三角色真实接线,并覆盖"中转状态清空后重启仍收敛";改断言必须做变异校验。这套做法在同类项目里罕见(见 §7 的实测)。

### 1.9 三端维护策略:业界两种做法都在,分界线是"有多少平台原生的活"

调研四个已上架鸿蒙的真实产品(2026-10 查证),它们选了**相反**的路,且各自都有理由:

| 产品 | 做法 | 关键事实 |
|---|---|---|
| 微信 | **各端各自维护**(鸿蒙用 ArkTS 重写) | 腾讯官方原话:鸿蒙是全新框架,"过去十几年积累的功能**无法直接迁移,必须从零重写**";专设"鸿蒙移动端开发中心"满建制团队,内部目标"对齐甚至超过 iOS" |
| 小红书 | **各端各自维护**(鸿蒙用 ArkTS 原生) | 2023-08 签约首批鸿蒙开发,华为**驻厂工程师**每日共同攻关;产出行业第一份鸿蒙开发指南 |
| 海底捞 | **一套 Flutter 代码** | 2024-06 启动 → 09 首版上架 → 2025-01 全量商用;华为团队全程技术支持 |
| 锅圈云铺 | **一套 Flutter 代码** | **一个人两个月**完成适配并上架,拿到鸿蒙激励金 |

**必须拆穿的术语**:"一次开发,多端部署"是华为对**鸿蒙生态内部**多设备(手机/平板/手表/车机)的说法(ArkUI 自适应布局 + 断点体系),**不是**跨 iOS/安卓/鸿蒙。小红书在 iOS/安卓/鸿蒙三端**仍然各写各的**。

**分界线**:看 App 有多少必须碰系统底层的活。微信(支付、音视频、小程序运行时)重写比适配划算且养得起团队;锅圈/海底捞(商品、订单、列表、表单)纯 Dart 直接跑,只有少数插件要换。

**"跨平台搞定"的真实代价**(海底捞清单,与本项目文档的预判高度一致):Flutter 版本要**降级**做 API 适配;三方库逐个换鸿蒙适配版(`dependency_overrides`);未适配的库要**自己用 ArkTS 重写插件**;字体渲染差异逐端校准;ArkUI 与 Flutter 引擎的**帧率同步**问题。

**对本项目的结论**:dsh-mobile 属于锅圈/海底捞那一类 —— 消息流、列表、Markdown、时间线都是纯 Dart 能覆盖的,碰原生的只有**推送 / 安全存储 / 长连接保活**三块,而这三块正是 `subsystems/app-platform-boundaries.md` 的"按能力切包"要解决的。锅圈案例(一人两月)的坑与本文档的预判一致(换插件、`dependency_overrides`、权限需同步配 `config.json`、禁用硬编码尺寸)。海底捞"降级 Flutter 版本"这条,是 §5 版本闸门锁死一条线的**外部实证**。

**证据等级**:四个案例均为**转述**(各自官方/媒体稿,附 URL 见 §9),其中微信"必须从零重写"与海底捞适配清单为腾讯/华为官方口径。

---

## 2. 通道协议的关键事实(实现前必须知道)

### 2.1 会话事件流与实时流是两条流,后者不占 `seq`

- 持久侧:一个 step 的完整输出作为**一条事件**落盘,内嵌精确流记录(`packages/core/session/src/types.ts:341-349` 的 `assistant/message` 带 `stream: AssistantStreamRecord[]`;记录形态见 `packages/llm/llm/src/assistant-stream.ts:20-47`,含 `text-chunks` 的 `time0/index/dt[]/texts[]`)。
- 实时侧:`follow({ assistantStream: true })` 另推 `start/delta/end` 帧,`start` 带 `startedAfterSeq` 水标,并有 ordinal 与 revision 语义(`packages/api/session-controller/src/history.ts:165-175,185-203,283-293`)。
- **这些帧不推进会话 `seq`。**

### 2.2 `follow()` 的开场快照本身是有界分页的

`maxMessages` 默认 **50** + `hasMore`(`history.ts:38,184,193-203`);DSH 客户端的分页策略是 `{ maxMessages: 500, turnWindow: { minMessages, minTurns: 2 } }`(`packages/api/session-controller/src/client/sessions/session.ts:54`)。快照帧携带 `cursor` 与 `projections.asOfSeq`。

### 2.3 审批与提问都是「claim 或 delegate」的顺序 waterfall

源码原话(一手):

> "Ask composed answerers for one decision. **Return an outcome to claim the request or call `next()` to delegate.**" —— `packages/interaction/user-approval/src/types.ts:81-82`;提问同构:`packages/interaction/user-questions/src/types.ts:151-152`

配套事实:

- 审批结果词汇表封闭:`allowed-once | rejected | cancelled | unavailable`,**唯一授权值是 `allowed-once`**(`user-approval/src/types.ts:32`、`src/index.ts:211`)。「始终允许 / 本次会话允许」不是审批结果;能表达"本会话不再问"的只有会话级策略覆盖(`setPolicy`)或 `danger-full-access` 预设,语义是关闭该会话全部审批。
- `never` 策略在**任何 answerer 之前**决定并直接 `rejected`(`src/index.ts:269-275`),answerer 无法覆盖。
- 撤销语义可用:abort 立即以 `cancelled` 收束,仍悬空 answerer 的晚到回答被丢弃(`src/index.ts:127-131`)。
- 官方 Web 客户端的做法是"不适用就 delegate"(`packages/client/ui-approval/src/client/index.ts:44,63,104`,一手)。

### 2.4 审批的问答对写在持久日志里

`user-approval/src/index.ts:197-204` 原文(一手):

> "The request requires an open turn because **the audit pair must be enclosed by the durable log's commit/replay boundary**; an idle ask rejects before appending anything."

即:ask 与 outcome 成对进入持久日志(有 `seq`、可重放);"悬空"在日志中的形态是**有 ask、无 outcome**。→ 待审批/待回答是**持久事实的投影**,不是连接态。

### 2.5 可转发事件白名单与逐会话流

`API_REMOTE_FORWARDED_EVENTS` 共 27 条(`packages/api/remotes/src/remote-events.ts:20-48`,一手),其中 `approval/request` 与 `user-questions/request` 是 `waterfall` 模式;逐会话事件流不在名单内。名单是编译期常量,网关的 remote-event source 是**单槽**、第二次注册直接抛错(gateway source 注释:"Register the sole application-selected forwarded-event source",转述核实)。逐会话 timeline 走普通 Remote 方法流(`remote.session.follow` / `page` / `cancel`),不依赖白名单。

### 2.6 `seq` 会被两条读路径各出现一次,内容相同

崩溃尾回合的 closer 由冷读在内存合成(`packages/session-query/session-query/src/cold-read.ts:16-17` "nothing is written back"),其 seq 基准为 `last.seq + closers.length + 1`(`packages/core/session/src/repair.ts:89`);会话恢复后同一算法的 closer 落盘(`packages/core/agent-loop/src/index.ts:855-856`),契约测试明确落盘事件不被改写(转述:`session-checkpoint-policy/tests/crash-recovery.e2e.ts:67-78` "the stored events stay untouched")。

→ 客户端按 `seq` **去重是必须项**;不得用"同 seq 不同内容"判冲突。

### 2.7 数据源其余关键事实

| 项 | 事实 | 证据 |
|---|---|---|
| 发消息 | `prompt({ requestId, mode: 'queue' \| 'steer' })`;**全仓库无 `clientMessageId`** | `packages/api/session-controller/src/types.ts:332-341` |
| 幂等 | 以 `requestId` 查 inbox;`rpcId` 随 `user/message` 落盘 | `src/commands.ts:329-335`(转述核实) |
| 取消 | `cancel()` 保留待处理收件箱 | `src/commands.ts:511-525`(转述) |
| 后台任务 | `list` / `readAt`(不移动模型游标)/ `kill`(仅请求,等 settled)/ `events.subscribe`;`JobId` 形如 `bash-1` 由**进程内计数器**生成、跨重启重用;无主任务并进每个会话 | `packages/jobs/jobs/src/index.ts:100-192`、`jobs-local/src/index.ts:229-231`(一手 + 转述) |
| 任务输出截断 | 每帧 64 KiB / ring 256 KiB / 客户端尾 128 KiB;结算后 ring 裁到 16 KiB | `api/job-controller/src/index.ts:32`、`jobs-local/src/index.ts:36,39`、`api/job-controller/src/client/model.ts:16`(转述) |
| 子代理 | `listChildren` / `listDescendants`;`activity` 只表达"会话是否驻留" | `subagent/src/index.ts:374,393`(一手) |
| 附件 | 图片内联 base64;文件走前置上传拿 receipt;MIME 名单实名 `mediaTypes`(`ImageMediaType`) | `api/session-controller/src/types.ts:89-97`、`packages/attachment/attachment/src/types.ts:8`(一手) |
| 密钥 | `credentials.resolve()` **会返回值本身**;"不回传"是 Remote 面(describe)的性质 | `tool-cordis/src/api-catalog.ts:767,770,773-776`(一手) |
| 会话落盘 | JSONL + 可选压缩(zstd/none)、sqlite 查询索引层;格式版本 **4**,迁移链 v0→v1→v2→v3→v4 | `packages/core/session/src/types.ts:89`(一手)、迁移包与压缩默认值为转述 |
| 设置写路径 | 非 loopback 页面:写操作不发线并返回 false,镜像态 `unavailable` | `client/ui-settings/src/client/config-form.ts:175`、`settings-mirror.ts:86,89`(一手) |
| loopback 判定 | 依据**页面 authority**,不是网络路径 | `client/connection/src/client/index.ts:248`、`loopback-hostname.ts:12-17`(一手) |
| webserver 座位 | 重复路由 / 重复 upgrade / fallback 二次注册均抛错 | `packages/host/webserver/src/index.ts:169,183,198-199`(一手) |
| 插件兼容性 | **`engines.dsh` 不被强制**;兼容性由 `peerDependencies` 对 `@deepseek-ai/dsh*` 的范围决定,不匹配则跳过并记入 `skippedBundles` | `packages/util/package-manifest/README.md:93`、`boot/app-boot/src/plugin-compatibility.ts:68`、`profile.ts:675-681`(一手) |

---

## 3. 协议定稿时补齐的六条

以下六条已全部定稿并落成可执行 fixtures(`10`–`16`),参考实现见 `protocol/reference/`,契约条文见 `subsystems/remote-channel.md`;本节保留的是**定稿依据**。按影响排序。

### 3.1 缺「易变流式帧」这一帧类型(影响核心体验)

信封的 `ev` 必带 `seq`,而实时流帧不占 `seq`(§2.1)。若把流式帧塞进 `seq` 空间,会破坏"修订号 = 会话事件 seq"这个唯一真值基础;若不表达,手机拿不到逐 token 数据,§7.2/§7.3 的流式打字与甘特 TTFT 渐变没有数据来源。

建议形态:新增 `t:'live'`,字段 `{ sid, streamId, startedAfterSeq, revision, box }`;规则——**不入重放窗口、不参与 ack、可丢弃、恢复时不回带**(最终文本由持久事件还原)。配一条 fixture:live 帧丢失/乱序/截断后,持久事件仍收敛。

### 3.2 基线快照缺三要素:水位、分页、续传游标

`SyncSnapshotRequired` 只有 `sid` + `reason`;参考实现的 `snapshotItems()` 一次给全、没有页概念(`protocol/reference/bridge.mjs:97-103`)。缺 `asOfSeq` 会导致:快照基于 seq=1000 生成、而 since=1050 的请求在快照之后到达时静默丢一段(可能正好是任务终结或审批)。

建议形态:快照响应携带 `(asOfSeq, hasMore, cursor)`,照 DSH 的 `follow()` 快照语义(§2.2);并写清"快照期间产生的增量如何与新基线拼接"。先例:JMAP state string、Matrix `next_batch`。

### 3.3 「待审批 / 待回答」的归类与重建

它们进入 `TransientFacts` 与事实不符(§2.4):应作为**持久条目投影**(有 itemId、进快照、upsert)。当前 §9 的后果描述("桥接进程重启后集合就空")因此不是 DSH 的限制,而是缺少重建步骤;实现上可在重连时重放日志尾部,以"有 ask、无 outcome"重建未决集合。

真正的瞬时事实只剩:电脑在线态、能力位。

### 3.4 缺流控/背压

除"任务输出按需订阅"外,协议没有 ack 窗口、发送配额或丢弃策略。慢消费者会让 WS 缓冲无界增长。已有的 `ack{sid,seq}` 可扩展为窗口;§6 规则 4 的"收到全部配对设备 ack 后才裁缓冲"是同一机制的现成挂点。

### 3.5 缺接收端 seen-seq 规则与去重表持久化约束

协议未显式规定"收到 `seq ≤ 已落盘水位` 的 `ev` 帧"与"收到 `seq` 跳跃"时的行为。DSH 侧 `follow()` 对前向缺口抛错、对倒退静默跳过(`history.ts:226-231`),帧层需要等价规则:重复即丢、空洞即 `snapshotRequired:true`。

配套:写操作幂等键的**去重表必须持久化且有界**——若只在内存且在重启后失效,超出窗口的重放可能二次执行。

### 3.6 审批仲裁未定(核心链路)

桥接注册为 answerer 后与桌面 UI 在**同一条** claim-or-delegate 链上(§2.3):链首 claim 会挡住下游。三条可选路径:

| 路径 | 形态 | 代价 |
|---|---|---|
| 竞速裁判 | 桥接 claim 的同时调 `next()` 取桌面结果,谁先答用谁,另一个用 `signal` 撤销 | 实现最复杂;须正确处理桌面弹窗被撤销 |
| 超时降级 | claim 后 N 秒无人答则撤销并 delegate | 手机端无人在场时审批仍会回到桌面;不静默放行 |
| 独占 | 手机在线时审批只在手机答,桌面不参与 | 最简单、可判定;改变了桌面既有行为,需产品确认 |

叠加 §3.3 的重建步骤后,审批链路的可靠性上限才能写进产品承诺。

---

## 4. 安全评估

### 4.1 配对阶段的中间人边界

手机扫码是带外信道 → "中继冒充电脑"会被手机发现(它拿不到电脑私钥);但"中继替换手机公钥"会让中继与电脑正常通信、真手机解不开,**表现为连不上(可用性破坏),不是静默泄密**。两条必须写进规范:

1. 手机**绝不接受**任何网络下发的电脑公钥,只信扫码值;
2. 电脑侧应对收到的设备公钥做带外核对(SAS / 短指纹)。

另:密钥派生的"配对标识"当前未定义(是否含一次性配对码),属安全参数,须先定。

### 4.2 三端设备私钥的保护层级不对等

| 端 | 归宿 | 强度 |
|---|---|---|
| 鸿蒙 | HUKS 支持 X25519 生成/协商/HKDF 派生/密钥证明,**私钥不可导出**(转述:华为官方文档) | 最强 |
| Android | Keystore(可强绑定) | 中上 |
| iOS | Secure Enclave 只支持 P-256 → Curve25519 只能作 **Keychain 软件密钥**(转述:Apple 文档) | 最弱 |

叠加"长期密钥 + 无前向保密 + 第一版无轮换":私钥被提取即可解密窗口内历史(Matrix Megolm 官方文档对同一形态有明文警告,转述)。缓解:Keychain/Keystore 访问控制(解锁或生物识别门控)+ 把密钥轮换提前进第一版。

### 4.3 nonce 策略与算法选型

`cryptography` 的 X25519 与 `Xchacha20.poly1305Aead` 均有纯 Dart 实现,而 `Ecdh.p256/p384/p521` **没有**纯 Dart 实现(pub.dev 页原文,一手)→ 鸿蒙既非 Android 也非 iOS,X25519 是三端唯一可行的密钥协商;**这是选型的真实理由**,应写进文档。

两处待定:

- **加速**:`cryptography_flutter` 的加速清单不含 XChaCha20(转述),它始终走纯 Dart;包自报 ChaCha20-Poly1305 约 30 MB/s(1 MB 消息,MacBook Pro,一手)。
- **nonce 来源**:XChaCha20 的 24 字节随机 nonce 每帧一次随机数;`cryptography` 默认随机源为 `Random.secure()`(系统调用,一手:包文档)。逐帧封箱即逐帧系统调用。

建议:`ev` 帧的 nonce 由 `(sid, seq)` 派生(seq 会话内单调不重复 → 天然唯一、无状态、不依赖随机数质量),`req`/`res` 用随机 96-bit nonce;据此可选 ChaCha20-Poly1305 或 AES-GCM(均有平台加速)。**算法最终取舍以真机小帧基准为准**(1 KB × 10 万次)。

### 4.4 其余两处

- `res ok:false` 的 `err` 在明文头里,与"中继看不到方法名与事件类型"不一致;至少 `msg` 应封箱。
- AAD = `v|t|id|sid|seq` 的规范化未定义(`presence`/`ping`/`pong` 无 `id/sid/seq`);两端独立实现拼串易不一致,须写死缺省表示。

### 4.5 中转的合规与成本(产品前置)

公网中转服务在中国大陆涉及 ICP 备案(域名 + 服务器);元数据仍属个人信息(PIPL 义务);另有带宽成本与推送通道的账号/模板/分类报备。不影响技术可行性,影响上线时间。

---

## 5. 平台侧事实

| 项 | 事实 | 等级 |
|---|---|---|
| 鸿蒙 Flutter 版本线 | 当前最新稳定线基于上游 **3.41.9**(tag `3.41.10-ohos-1.0.1` / `3.41.9+ohos-1.0.2`,同一条线两种命名);上一档 3.35.7(`3.35.8-ohos-1.0.4`);规划表:3.35 滞后 7 个月,3.41/3.44/3.47 各 4 个月。**3.44 截至 2026-10 仍无稳定版**,只有 canary `3.44.9+ohos-0.0.1-canary1`(2026-08-21),而 3.41/3.35/3.27 三线在 2026-09-24 均有新 tag → 规划表的"3.44 于 2026/09 发布"**未兑现** | 一手(CPF-Flutter docs 仓 `OrganizationDescription.md` + AtomGit API v5 tags) |
| 鸿蒙 Flutter 维护方 | **CPF-Flutter 团队**(OpenHarmony 跨平台框架 PMC 下属 **Flutter SIG** 主导的开放社区组织),**不是华为内部团队**;旧组织 `openharmony-tpc` / `openharmony-sig` / `OpenHarmony-Flutter` 已整体迁入并**全面停更**。同生态另有 `oh-flutter` / `hxa-flutter` 两个社区补三方库 | 一手(CPF-Flutter docs 仓原文:"由 CPF-Flutter 团队维护") |
| 鸿蒙安全存储 | 适配清单收录 `flutter_secure_storage` 的 ohos fork;其实现在公开说明中未见 HUKS 相关描述,不能据此推断密钥由 HUKS 保护 → 满足密钥要求时须自写 platform channel 接 HUKS | 一手(清单)+ 转述(实现) |
| Dart build hooks / native assets 在 OHOS | ohos 工具链调用时抛 `FormatException: The OS "ohos" is not known`(PR 仍 open);替代路径:`flutter create -t plugin_ffi --platforms ohos` + `ohos/build-profile.json5` 的 `externalNativeOptions`,或预编译 so 打进 har | 转述(dart-lang/native PR #3409),实现前建议复跑 |
| 鸿蒙推送 | 未申请「通知消息自分类权益」时**单设备每日 2 条**(5 条仅持证新闻类),超发丢弃;后台消息不唤醒进程 | 转述(华为官方文档);聚合推送(极光)数据面仍走 Push Kit,绕不过频控 |
| 安卓 | `dataSync` 前台服务自 Android 15 起 24 小时累计 6 小时上限;大陆无 GMS,FCM 不可用 | 转述(Android 官方);官方原文未取到的项见 §9 |
| iOS | 静默推送强杀后丢弃、受设备级预算限制;APNs 每 bundle ID 只保留一条、最多 30 天 | 一手/转述(Apple 官方) |
| 渲染后端 | Impeller 三端后端不同(鸿蒙由 `buildinfo.json5` 控制,模拟器不支持 Vulkan)→ 三端"像素一致"只能是视觉规格一致 | 转述 |
| Markdown 渲染 | `flutter_markdown` 已 discontinued;长文本排版有已知性能坑(dart:ui 排版仅主 isolate)→ 需显式选型 + 按块懒加载、已完成消息冻结 | 转述(pub.dev / flutter issue) |

---

## 6. 性能量级(实测标定)

扫 DSH 仓库 `snapshots/` 下 444 个 `.jsonl`,其中 417 个可解析为事件流(命令见 §7):

| 指标 | 值 |
|---|---|
| 每会话事件数 | 中位 22 / p90 35 / p99 83 / max 99 |
| 每 turn 事件数 | 中位 21 / p90 30 / max 99 |
| 单事件字节 | 中位 253 B / p95 3.3 KB / max 7 KB |
| 最大会话 | 99 事件 / 约 65 KB |

推论:

1. **中转的"1000 条"约覆盖数十个 turn**,条数不是约束;"30 分钟"才是主要约束。
2. **基线快照成本约 100 KB 级**,严格恢复语义在成本上完全可承受(数百 turn 的极大会话才会到 MB 级,而 `follow()` 快照本身有 50 条消息的分页上限)。
3. **8 MiB 单帧对事件流极宽松**;真正的大对象是图片 base64 与任务输出(后者已有 64 KiB/帧 + 128 KiB 尾巴的截断规格)。
4. AEAD 的**每帧固定开销**(nonce 生成/MAC/async)比吞吐更需要实测——帧是百字节级。
5. 心跳依据:RFC 5382 REQ-5 原文 "the value of the 'established connection idle-timeout' MUST NOT be less than 2 hours 4 minutes"(一手);但 SIGCOMM 2011 的运营商级实测(393 用户 / 107 运营商)显示空闲超时 <5 min 占 5%、5–10 min 占 10%、10–20 min 8%、20–30 min 11%、>30 min 66%(转述,2011 年 3G 数据,未找到更新的一手实测)→ 60 s 心跳是必要的保守值。

---

## 7. 可复现验证

```powershell
# 四条门禁(纯 Node,不需要浏览器/手机)
node protocol/verify-fixtures.mjs          # 241 项断言 / 9 条 fixture
node protocol/verify-loopback.mjs          # 20 项(含中转清空后重启仍收敛)
node app/tools/verify-platform-boundary.mjs # 17 项(含 13 条规则自检)
node mock/proto/tools/verify-icons.cjs     # 98 图标
```

变异校验(把 `protocol/` 复制到临时目录后注入,不碰仓库):

| 注入的破坏 | fixtures | loopback |
|---|---|---|
| 中转不再检查区间连续性(`relay.mjs` 去掉 `seq !== expected` 判定) | FAIL 1/241(仅 `07-relay-restart-invariant` 一条断言) | — |
| 桥接恢复不回带瞬时事实(`bridge.mjs` 的 `hello` 返回空 transient) | FAIL 2/241(`09-transient-facts-always-resent`) | **全绿(未抓住)** |

第二行说明:`verify-loopback.mjs:66` 在 relay 分支自行调用 `bridge.transientOf(sid)` 取瞬时事实,绕过了 `hello()`,因此该不变量在回环层没有覆盖。修法:加一条"游标最新且中转窗口为空"强制走桥接分支的用例,或让 relay 分支不再自行取 transient。当前连续性不变量只有一个断言位,建议补一条"窗口被滚动挤出中间帧(而非 evictAll)"的 fixture。

> 本节结论与 `subsystems/remote-channel.md` §10 的"变异校验"表述不一致之处,以本节实测为准(该表述已在同批修正)。

---

## 8. 待落地清单

### P0(写 `connector/` 之前落进 `protocol/`)

**状态:六条已全部落地**——fixtures `10`–`16` 与 `protocol/reference/` 是它们的可执行形态,开工顺序见 `cookbook/channel-bootstrap.md`。1. `live` 流式帧类型(§3.1)
2. 快照三要素 `asOfSeq` / `hasMore` / `cursor` + 拼接规则(§3.2)
3. 待审批/待回答改为持久投影 + 重连重建(§3.3)
4. 流控:ack 扩展为窗口(§3.4)
5. 接收端 seen-seq 规则 + 去重表持久化(§3.5)
6. 审批仲裁路径定稿(§3.6)

配套 fixture 变更(名字与断言):

| fixture | 断言 |
|---|---|
| `10-live-frames-are-ephemeral` | live 帧不推进游标、不入重放窗口;丢失/乱序后由持久事件收敛 |
| `11-snapshot-carries-watermark` | 快照响应带 `asOfSeq`;快照期间到达的增量不与基线重叠、不丢事件 |
| `12-snapshot-paginates` | 快照分页:`hasMore` 为真时给出续传游标;分页与增量并发后仍收敛 |
| `13-pending-approval-rebuilt-from-log` | 桥接重启后仅凭日志重建"有 ask、无 outcome"的待审批集合 |
| `14-flow-control-window` | 未 ack 超过窗口时发送方停止;慢消费者不导致缓冲无界增长 |
| `15-seen-seq-rejects-replay` | 重复 `ev` 丢弃、`seq` 空洞要求快照;写操作重放不产生第二条消息 |
| `16-approval-arbitration` | 桌面与手机同时可答时按选定路径产生唯一结局(需要先定 §3.6 的路径) |

### P1

7. 配对规范:手机只信扫码公钥 + 电脑侧核对设备公钥;定义"配对标识"
8. E2EE 跨端 KAT 向量 + nonce 派生策略 + 真机小帧基准
9. `err` 封箱 + AAD 规范化
10. push token 进存储边界表;任务条目 id 用 `(owner, JobId, startedAt)`
11. 文档修正:§2.1(兼容性判据)、§2.2(格式版本/上传上限/MIME 层级说明)、§6(seq 复用机制)、§10(变异校验表述)、§9(AA 契约字段名层级)
12. `connector/` 工程形态照抄参考插件样板(见 §9)

### P2

13. 鸿蒙版本线锁 3.41(当前稳定 tag `3.41.10-ohos-1.0.1`,2026-08-17;3.44 尚无稳定版,见 §5)
14. 渲染层选型(替代已 discontinued 的 `flutter_markdown`);三端"像素一致"改口径
15. 中转的备案/合规/成本预案进风险表
16. 长期候选:QUIC 连接迁移(消掉"切网必重连")、直连优先 + 中继兜底

---

## 9. 证据等级与未找到项

**一手(本次直接读到原文/源码)**:RFC 5382 REQ-5;Tailscale 官方博客;libQuotient #232 及其作者回复;pub.dev `cryptography` 页;CPF-Flutter docs 仓 `OrganizationDescription.md`(版本规划表、稳定版表、维护方表述)与 AtomGit API v5 的 tags/branches(§5 的版本线与"3.44 无稳定版"结论由此得出);§2 表格中标注"一手"的 DSH 源码行;参考插件 `dsh-bridge-next` 的 `package.json` 与 `cordis.patch.yml`(其形状:`dsh.bundle.patch` + `peerDependencies` 用精确版本 `@deepseek-ai/cordis 4.0.4` / `@deepseek-ai/dsh-typert-protocol 0.2.0-rc.1` / `@deepseek-ai/schemastery 3.18.4`,`engines` 只写 node,DSH 各包以 `0.2.0-rc.1` 作为 devDependencies 供类型检查;接入文件只有 4 行 `insert`)。

**转述(附 URL,未逐字复核)**:JMAP RFC 8620 §5.2 与 IMAP RFC 7162;EMQX 会话过期与队列默认值;Signal/Syncthing/WebRTC/Node ws 等生态参数;NetPiculet(SIGCOMM 2011)超时分布;华为 HUKS/Push Kit 文档;Apple 静默推送与 Secure Enclave 文档;Android 前台服务限制;小米/vivo 厂商规则;Impeller 与 `flutter_markdown` 状态;`dart-lang/native` PR #3409;Agents-Anywhere 的 server 架构文档与其 `e2ee` 检索结果;**§1.9 的四个鸿蒙上架案例**(微信 <https://m.mydrivers.com/newsview/1057612.html>、小红书 <https://www.geekpark.net/news/330773>、海底捞 <https://www.cnblogs.com/HarmonyOS5/p/19023040>、锅圈云铺 <https://ost.51cto.com/posts/37697>)。

**未找到**:微信与 Telegram 的官方心跳值(方案 §8 引用的"微信 5 分钟"缺一手来源);FCM 大陆不可用的官方条文;`specialUse` 需 Play 审核与 Android 12+ 后台启动前台服务的官方条文;vivo 运营消息时段限制的官方正文;XChaCha20-Poly1305 的手机端吞吐一手数据;`ws` 默认 `maxPayload` 的本机复核(依赖未安装,按库文档值计)。

**评审中驳回的三条外部反馈**(理由见 `.agents/notes/implemented/2026-09-30-channel-review-corrections.md`):"插件持长连接不可行"、"`ctx.storage` 无 revision 需改设计"、"附件 MIME 字段实名应统一为 `mediaTypes`"。
