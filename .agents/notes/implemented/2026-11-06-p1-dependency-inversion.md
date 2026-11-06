# P1：依赖倒置 —— core 不再 import wire

- 日期：2026-11-06
- 触发：架构审查（`proposed/2026-11-06-branch-a-and-pr-audit.md` §四）把 `core→wire` ×2 与
  `data→wire` ×21 判成"要依赖倒置、不许把 wire 搬进 core"。P1 单独一批、单独留笔记。
- 状态：implemented（`core→wire` **已到 0**；`data` 那 21 条还没动，见末节）

## Problem

`wire/` 是线上格式的**唯一断言点**（字段名与类型只在那里出现），而 `core/` 与 `data/` 反过来
import 它 —— 方向成了"消费者依赖形状"。`core/` 这两条各是一半问题：

1. `core/sync_client_impl.dart` 的 `page()` / `refetch()` 直接调 `wire/rpc/session_page.dart`
   的 `loadSessionPage` / `loadRefetchedEvent`，并 `switch` 它的
   `SessionPageRecordWire` / `SessionPageRefetchWire`；
2. `core/items.dart` 的 `itemIdOf` 用 `wire/events.dart` 的四个读者取身份字段。

## Decision

1. **`core/history_page.dart`（新）**：`HistoryPage` / `HistoryPageItem`
   （`HistoryRecordItem` | `HistoryRefetchItem`）与**端口** `HistoryReader`
   （`loadPage` / `loadRefetched`，都用 `null` 表示"读不出来"）。
2. **实现留在 wire**：`wire/rpc/session_page.dart` 的 `WireHistoryReader` 把
   `SessionPageWire` 折成 `HistoryPage`，并把失败**报到 `WireDiagnostics`**
   （`'session.page'` / `'session.refetch'` 两个标签从连接层挪到这里 —— 报缺陷的那一处
   与知道形状的那一处对齐）。补取循环仍留在连接层：它要 `await` 自己的 `refetch`、
   按 `seq` 归位、记住 `hasMore`，那是 `SyncClient` 的状态。
3. **`core/items.dart` 的 `EventIdReaders`**（4 个方法：`toolCallId` / `toolResultId` /
   `approvalId(decided:)` / `commandId(done:)`）：**契约 §5.2 的规则留在 core**（哪个事件用
   什么当身份、八个前缀、缺了就抛），**字段名与层级留在 `wire/events.dart`**
   （`kWireEventIdReaders`）。
4. **身份只算一次**：`itemIdOf` 在**解码边界**（`_eventFromPayload` / `session_page`）跑，
   结果落 `SessionEvent.itemId`；`data/projection.dart` 的 `projectEvent` 改成**收**
   `itemId`、不再自己推一遍。改之前同一条事件被推两次（wire 解一次、投影再解一次），
   两条路径给出不同 id 就是这一层最贵的 bug（2026-10-25 计划卡静默消失同源）。
5. **解码处把那条 StateError 折成 `badFrame`**：从前它会穿过 `_dispatch` 变成**未处理的
   异步错误**（连接既不报错也不断开，症状是"这一帧之后就安静了"）。现在与"ev 帧缺少
   sid/seq"同一档：关连接 + 留声（`_protocolFailure`）。
6. **`SyncClientDeps` 两个新必填项**（`history` / `eventIds`）：不给就没有历史可翻、
   没法给事件一个稳定身份 —— 两者都不该是静默默认值。
7. **顺手修掉一个 S2 遗留**：`integration_test/local_store_test.dart` 还在调
   `SqfliteItemStore.clear()`（该方法在 `61c2b2c` 已删），所以 `integration_test` 自那以后
   **编译不过** —— 而门禁跑的是 `dart analyze lib test`，看不见它。改成 `clearSession('s1')`
   （语义正是"这个会话从头开始"）。

## 被否掉的

- **把 `SessionPageWire` / `ToolCallWire` 搬进 core**：那等于把"应答长什么样"搬进 core，
  正是不许的方向。
- **让连接层自己解 `{items, hasMore}`**：同一条，形状知识会散回消费方。
- **把补取循环搬进 wire**：它需要连接层的 `refetch` 与 `hasMore` 记账。
- **投影继续自己推 itemId（只把读者作为参数传下去）**：那要 `AppModel` 持有读者，而
  `AppModel` 在 **74 个测试文件**里被直接构造 —— 加必填参数 = 100+ 处改动；
  而且热路径上仍然推两遍。收 `itemId` 一次解决两件事。
- **测试里手写 `t:call-1` 这类 id**：等于把规则抄进测试。`app/test/projection_fixture.dart`
  用生产规则算 id，测试文件只改 import —— 55 个调用点一个字符都没动。

## 代价与已知边界

- 热路径多一次接口调用（每条事件一次，取身份字段）；省掉的是投影里那次**重复推导** ——
  净变化是"两次变一次"。
- `SessionEvent.itemId` 现在是**权威值**：夹具写错会被照用（`cold_start_restore_test`
  里就有一处写成 `m40`，本批修成 `m:m40`）。这正是要的：同一条事件不许有两个 id。
- **一处测试换了主体**：`message_rendering_test` 原来那条"坏事件不炸整批"喂的是**线上不可能
  出现**的 `SessionEvent`（载荷缺 `id` 却带着 itemId）。身份移到解码处之后它没有意义了，
  换成"带什么 id 就用什么"；"坏载荷"那条判据搬到 `sync_client_test` 的解码边界用例。
- `_projectionFailures` 那条隔离带还在（`on StateError` 包着投影与 store 写入），但
  **身份缺字段不再是它的触发源** —— 那一类失败现在在解码处。

## 验证

- `cd app && dart analyze --fatal-infos lib test integration_test`：三处都 No issues found。
- `cd app && flutter test`：**1759** 项全过（+1：解码边界那条；`message_rendering` 那条换了主体）。
- `node app/tools/verify-platform-boundary.mjs`：760 项全过（175 个 Dart 文件）。
- 协议三条：454 / 26 / 49 全过（本批没动 `protocol/`）。
- `git grep -c "import '\.\./wire/" -- app/lib/core` → **0**（本批前是 2）；
  `-- app/lib/data` → 4 个文件 / 21 条（未动，见下）。
- **变异校验**（两条，各跑一次，都变红后还原）：
  1. `kWireEventIdReaders.toolCallId` 恒回 `null` ⇒ `core_units_test` 报
     `Bad state: tool/call(seq=3) 缺少 callId`（证明读者真的接在身份推导里，不是摆设）。
  2. `projectEvent` 的 `MessageItem` 改用 `'mutation:$seq'` ⇒ `message_rendering_test`
     报 `Expected: ['m:a','m:b'] / Actual: ['mutation:7','mutation:8']`
     （证明投影真的用传进来的身份）。

## 真机验收（2026-11-06 晚，隔离实例，真模型 `spark-x2.6`）

按"改完必须手连一次"跑的。隔离实例：`DSH_HOME=D:\tmp\dsh-probe-home` + profile `probe`
（connector 0.1.21 的 tgz），直连 `0.0.0.0:18790`（8790 被日常实例占着），设备 `我的手机`
扫码配对。

| 验的东西 | 证据（电脑侧读数，不靠肉眼） |
|---|---|
| 配对 + 启动全套 `res` 解码 | `settings.describe / permission.catalog / session.modelCatalog / agentPresets.list / repo.info / endpoint.describe / workspace.list / session.list` 全部有 outbound 字节数 |
| **打开已有会话（历史解码 + 投影）** | 手机渲染出系统提示词、三条上下文注入、回答、轮次统计；`session.projections=6107` |
| **手机发消息 → 实时 `ev` 流** | `out_method.session.prompt=38`、`out_frame.ev=113251` 字节；回答流式出现（第 2 轮 7 秒 / 8.4K tok）；**全程 `logcat` 无 `[wire]`、无 `E/flutter`** |
| 退后台 → 回前台 | `online:false,foreground:false` → `online:true,foreground:true`（§2.2 行为未变） |
| 连接器进程重启 | App 自己重连回 `online:true`，无需人工干预 |
| force-stop 冷启动 | 重新起来即 `online:true` |

`ev=113251` 这一项是本批的靶心：它证明 `_eventFromPayload` 的 `itemIdOf(+EventIdReaders)`
与"投影只消费 itemId"在真事件上不报形状缺陷（有缺陷必打 `[wire]`）。

**没验到的**：翻页 `session.page` 的 `refetch` 分支（这次那 16 KB 会话里没有 >1 MiB 条目）。
三种零成本造法都试过、都不通（细节记在 `tools.md`）：① 从日常 home 拷会话日志 —— 那边的
`session.v*.jsonl.zstd` 是 0 字节壳、内容不在文件里；② 手写一个含 1.24 MB `user/message` 的会话 ——
`session.list` 认它（653 字节），但 App 抽屉里就是不出现（补 `session/title`、`session/end-seed`
也不出现）；③ 往库里塞空壳 —— 反而让整个列表查询失败。结论：要压这条，只能从手机或网页面板发一个
真 >1 MiB 的附件，让事件自己变大。它目前由 `sync_client_test` 的 refetch 用例（真封箱 `ev` + 真解码）覆盖。

**顺带发现（不是本批改的，值得记）**：DSH 那边 `session.list` 整体失败时，App 抽屉**照旧显示缓存的旧行**
（只有空态才会显示「拉取会话失败 <原因>」），也就是"列表已经坏了"在界面上看不出来。
这次的触发是库里一个 0 字节的空白会话目录（不是 App 的问题）。要不要在抽屉上加一个有缓存时的失败标识，
是产品判断，留给后面定。

隔离实例的配置落在 `D:\tmp\dsh-probe-home`（provider 与密钥都在那儿），不在仓库里。
配方与两个坑（`/v2/v1` 会 404、塞空壳会话会报 `corrupt session log`）记在 `tools.md`。

## 剩下的（实测）

**`data` 的 21 条**：`app_model.dart` 15、`host_catalogs.dart` 3、`file_preview.dart` 2、
`projection.dart` 1，用到 35 个 `wire.loadXxx(client, …)` 与 6 个应答 DTO
（`SessionListPage` / `SessionProjections` / `SettingSection` / `RepoInfo` /
`PluginInventory` / `WorkspaceSnapshot`）。倒置的形状是"端口声明在 core、`wire` 侧一个适配类
实现它、DTO 搬 core"，**但 `AppModel` 的 74 个测试文件都直接 `AppModel(...)` 构造** ——
加一个必填端口参数就是 100+ 处改动。所以这条路必须先有 `app/test` 侧的 AppModel 构造器
（fixture builder）并先把测试迁过去，否则改动量与收益不匹配。**这是 P1 剩下部分真正的
成本中心，不是接口本身**（本批不依赖它，所以没动）。
