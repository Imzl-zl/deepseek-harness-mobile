# UI 状态机制设计（第 2 段：一次说清，不做 N 个补丁）

- 日期：2026-10-27
- 状态：proposed（**未动代码**；评审通过后按 §9 分批落地）
- 输入：`2026-10-27-state-semantics-audit.md`（归属表与证据）、
  `2026-10-27-state-semantics-mechanism-decisions.md`（五条裁定）
- 基线：语义 = DSH 源码；机制 = Flutter/移动端（本机 SDK 3.41.9 + rikkahub 的移动端做法）

## 0. 一句话

**一个设备本地状态缝**（`data/ui_state.dart`，键前缀 + 一处迁移 + 一处恢复 + 一处清理）、
**一个动作门槛入口**（`data/composer_gate.dart` 的纯函数）、
**一处行事实派生**（一次快照算一遍，照 DSH `tree.ts` 的形态），
`AppModel` 只做 host 投影的 façade 并**按三个簇收窄**。

---

## 1. 三类主人与读取时机（定案）

| 主人 | 内容 | 读取时机 | 失效/清理 |
|---|---|---|---|
| `host` | 会话行、投影、`subagentCatalog`、`status` 帧、jobs、queue、设置文档 | 读即用；连接后首次刷新 | 宿主说了算；手机不缓存过夜 |
| `browser-local-persisted` 的同构替代 | 每会话的页签 id、草稿、提问草稿进度；抽屉分组折叠；上次看的会话 | **首帧前**（boot splash 期间一次读） | 换电脑（重新配对）整段清；会话从清单消失则 prune |
| `device-local` | 主题、界面字号、工作步骤密度/收起时机、性能用量 | **首帧前**（同上） | **跨电脑保留**（它们与某台电脑无关） |

判据（可机械检查）：`meta` 表里每个键都能回答"换电脑后还在不在"；
同一个值不会既在 `device.*` 又在 `host.*`。

---

## 2. 一个设备本地机制

### 2.1 键方案（唯一拼写处 `data/ui_state.dart` 的 `UiKey`）

```text
device.theme_mode          'system' | 'light' | 'dark'
device.ui_scale_index      '0'..'3'
device.transcript_view     'compact' | 'standard' | 'detailed' | 'fully-open'
device.performance_view    'compact' | 'detailed'
device.collapse_timing     'completion' | 'next-input'
host.last_session          sid
host.drawer_expansion      {"<workspaceId>": true|false, ...}
host.session_view.<sid>    'chat' | 'trajectory' | …
host.session_draft.<sid>   {"text": "...", "references": []}   ← 形状照 DraftSnapshot
host.question_draft.<sid>  {"<itemId>": {"index":n,"drafts":[{"selected":[],"custom":"","skipped":false}]}}
```

- 现有键的迁移：`theme.mode` → `device.theme_mode`；`ui_scale_index` / `transcript_view` /
  `performance_usage` / `collapse_timing` → `device.*`（补前缀）；`last_session` → `host.last_session`。
- `send_mode` **这一代不动**（改走宿主 `ui-conversation.busyEnter` 是 §9 批 H；
  在同一代迁移里删它会让发送模式静默回到默认值 —— 批 B 的迁移只搬键、不删它）。
- 会话级两条用**行**（一会话一行），不用一个 JSON 大 map：草稿写得频繁，
  大 map 每次都要重写全部会话；行粒度下每次只写那一条。

### 2.2 存哪：仍然 `meta` 表，**不新增表**；但要补 `deleteMeta`

`ItemStore.readMeta/writeMeta` 已经在，且 `PreferenceStore` 是它的窄缝。
新增一张 `ui_state` 表要动 `ItemStore` 接口 + 两个实现 + 三端断言，换不来任何能力
（前缀扫描、按 sid 删行都能在 `meta` 上做）。

**但现有接口少一个"删"**：`ItemStore` 只有 `readMeta/writeMeta/clear`，
而 §2.6 的 prune（会话消失 / 工作区消失 / 提问收束）与"换电脑清 `host.*`"都需要
**按前缀删**。用空串当删除标记会把"没有这个键"与"空值"混成一件事，是坏味道。
所以本次**只加一个方法**：

```dart
// data/store.dart
Future<void> deleteMeta(String key, {bool includePrefixed = true});
Future<Map<String, String>> readMetaPrefix(String prefix);
```

**实现时发现"按前缀删"与"删这一个键"不是一回事**（原设计只写了一个 方法，落地时被
`store_contract_test` 的"精确键"用例抓住）：`host.session_view.sid-1` 是
`host.session_view.sid-10` 的字符串前缀，prune 一个会话时必须**精确删**
（`includePrefixed: false`），换电脑清 `host.*` 才按前缀。所以方法 +1 但带一个开关。

代价明确：接口 +2（`deleteMeta` / `readMetaPrefix`）、两个实现各 ~10 行、
共享存储断言 **+4 条**（前缀删 / 精确删 / 范围读 / 迁移幂等）。**判据**：`ItemStore`
新增方法数 = 2，且只有这两个。

另外给 `PreferenceStore`（`data/` 自己的窄缝，不是 `ItemStore`）补两个批量口：

```dart
Future<Map<String, String>> readAll(String prefix);     // 启动一次读完（1 条 SQL）
Future<void> writeMany(Map<String, String> values);     // 迁移/裁剪一次写完
```

理由：启动恢复从"7 次单键查"降到"1 次范围查"，迁移与 prune 也不必逐键往返。

### 2.3 迁移：同代编号，SQL + 数据两步

`storeSchemaVersion` 1 → 2。既有机制只有 SQL 字符串（`data/store.dart:199-241`），
本次补一个**同下标的 Dart 数据迁移**（新增 `storeDataMigrations`，与 `storeMigrations` 同长）：

```dart
// data/store.dart —— v1 -> v2
List<List<String>> storeMigrations   = [ ...(v0->v1 原样), <String>[] ];      // v1->v2 无 DDL
List<Future<void> Function(ItemStore)> storeDataMigrations = [
  _noop,
  _renamePrefsToScopedKeys,   // 读旧键 → 写新键 → 删旧键（幂等）
];
```

- 执行点：`platform/sqflite_item_store.dart` 的 `onUpgrade` 之后，与 SQL 用**同一个版本号**，
  不引入第二套计数；`onCreate`（全新安装）**只建表、不跑数据迁移**（没有旧键可搬）。
- 迁移必须幂等（旧键不存在就跳过），因此重跑、半途崩都能自愈。
- 迁移后删旧键，所以不存在"两套键并存"的兼容分支（照 `notes-contract` §5 的恒等边）。

### 2.4 写盘：一个旁路 sink，合并 + 生命周期强制刷

- 非高频键（主题/字号/密度/折叠/页签/上次会话）：**改了立刻写**（与桌面同语义），
  但通过一个串行队列（`Future` 链）保证顺序，不 `await` 在 UI 回调里。
- 草稿：`Timer(300ms)` 尾部防抖，**同一会话的新输入覆盖上一次待写值**；
  这些情况立刻 flush：发送成功后、`AppLifecycleState.paused`（复用
  `platform/app_state_reporter.dart` 的态，不新造观察者）、切会话前。
- 不做"每次击键落盘"：桌面能这么做是 `localStorage` 便宜
  （`packages/client/store/src/index.ts:159-165`），sqflite 是异步事务。
- 代价写进文档：**进程在最后一次防抖窗口内被杀，最多丢 300ms 内的输入**。

### 2.5 恢复：首帧前，一次读完

- 新入口 `AppModel.restoreUiState()`（或 `UiStateStore.open()` 由装配层调），
  位置在 `main.dart` 的 `_assemble()` 之后、`setState(_booting = false)` **之前**。
- 读的量：5 个 `device.*` + `host.last_session` + `host.drawer_expansion`，
  **一次 `readAll` 范围查**（§2.2 新增的批量口），同一个库连接，不额外开库。
- 会话级两条（`host.session_*.<sid>`）**不在启动时读**：`openSession(sid)` 时懒读一次
  （一次 `read`），并进内存；切走不落盘（已由防抖/立即写负责）。
- 这条同时解决现有"字号/主题首帧后跳一下"（`app_model.dart:1390-1417`、`main.dart:194`）。

### 2.6 清理与失效

| 事件 | 动作 |
|---|---|
| 重新配对（换电脑） | 删全部 `host.*`；`device.*` 保留 |
| `session.list` 里不再有某 sid | prune 该 sid 的 `host.session_*`（列表刷新后一次 `LIKE` 扫描） |
| 工作区不再存在 | `host.drawer_expansion` 按活 `workspaceId` 裁剪（照桌面 `retainAccountKeys`） |
| 提问项已收束 | 按活 `itemId` prune（照桌面 `prune(pending.liveKeys())`） |

---

## 3. 会话级状态的运行时归属

| 状态 | 活值住哪 | 落盘 | 恢复 |
|---|---|---|---|
| 草稿文本 | `ChatPageState._input`（`TextEditingController`）——**唯一主人** | `host.session_draft.<sid>`（防抖） | **不在 `build` 里读**：`initState` 里挂 `app.addListener`，回调中比较 `app.currentSid` 与已恢复的 sid；变了就 **先 flush 旧会话、再 `controller.text = draftOf(新 sid)`**（选区归零、**不请求焦点**），然后 `setState` |
| 页签 | `AppModel.viewOf(sid)`（内存 map） | `host.session_view.<sid>`（立即） | 同一个监听回调里随会话切换一起读 |
| 提问进度 | `TakeoverController`（按 sid 分桶，已有） | `host.question_draft.<sid>` | 卡出现时读一次（不在 `build` 里） |

**草稿不进 `AppModel`**：`ChangeNotifier.notifyListeners()` 是同步全量遍历
（`foundation/change_notifier.dart:410-451`），草稿一进去就是每击键整页重建。
落盘函数由 `ChatPage` 注入给 `AppModel`（或直接由页面持 `UiStateStore` 的写句柄），
`AppModel` 只提供"读一个会话的草稿"。

**为什么恢复必须挂在监听回调而不是 `build`**：本仓纪律是"读不能出现在 `build` 里"
（`AGENTS.md` §5 的持久化纪律 + `type-scale.md` 同一条），而 `build` 在每次
`AppModel` 通知时都会跑；把 `await draftOf(sid)` 放进去会变成每次重建一次异步读，
且会在流式输出期间反复覆盖用户正在打的字。

---

## 4. 动作门槛：一个入口

新文件 `data/composer_gate.dart`（纯 Dart，可单测）：

```dart
sealed class ComposerGate {}
/// 主键是"发送"：能发，且正文非空。
final class GateSend    extends ComposerGate {}
/// 主键是"停止"：在跑、且（正文空 **或** 被 owner 挡）——桌面 `primaryStops`（InputBar.tsx:341）
final class GateStop    extends ComposerGate {}
/// 主键静默禁用：正文空但没在跑（**不说任何话**，桌面此处也不给文案）
final class GateEmpty   extends ComposerGate {}
/// 主键禁用 **且要说明缺什么**：句子的来源是桌面 `blocked.reason` / `placeholder.workspace`
final class GateBlocked extends ComposerGate { final GateReason reason; final String sentence; }

enum GateReason { notPaired, noSession, noWorkspace, removed, parentOffline, subagentReadOnly }

ComposerGate composerGateOf({
  required bool paired,                // 手机独有：桌面 `!live` 的一档在这里被替换（没配对就没有输入机）
  required String? sid,
  required bool blankSession,          // hero
  required bool workspaceResolved,     // 桌面 `chipTitle !== undefined`（ConversationContent.tsx:142）
  required bool removed,
  required int? subagentMode,          // one-shot / continuable / unknown
  required bool parentOffline,
  required bool draftEmpty,
  required bool sending,               // 请求在途（手机侧对应物，**不是**桌面的 machineBusy）
});
```

- 判据逐条对桌面的行（写进文件头）：`InputBar.tsx:343` 的
  `primaryStops ? stopAction === undefined : empty | disabled | machineBusy | uploadsPending`、
  `:341` 的 `primaryStops`、`:154` 的 `removed | inert | !live | blocked | parentOffline`、
  以及 `ConversationContent.tsx:142` 的 `inert`。
- **不判**的与理由：`machineBusy`（手机没有输入机状态机，`_sending` 是"请求在途"不是"裁定/提交中"）；
  `blocked`（本版 DSH 无任何 feature 调用 `blocks.set`，全仓只有注册表与测试替身）；
  `uploadsPending`（手机附件是本地选图，没有宿主上传阶段）；
  **"未选模型"永远不进门槛**（`agent.ts:464-472` 会话活跟随宿主默认）。
- **"正文空"不给话**：桌面在 `empty` 时只是禁用，不弹文案；我们照同一形态。
  只有 `GateBlocked` 才有句子，且句子来源必须是桌面同一处（`placeholder.workspace` /
  `blocked.reason` / 子会话只读的既有说明）——**不自己发明新文案**。
- UI 只消费：主键动作 = gate 的类型；占位文案 = `sentence`（仅 Blocked）；点了被挡就 toast 同一句。
- 每句文案钉在 `composer_gate_test.dart`（一条一句），改文案必须改用例。

---

## 5. 连接瞬间一次画全

数据（**全部已有，不加协议**）：

| 事实 | 来源 |
|---|---|
| 谁在跑 | `session.list.running` + `status` 帧（既有） |
| 父会话有哪些子智能体 | 行投影 `values.subagentCatalog`（summary 键默认携带；连接器原样透传） |
| 哪个子智能体在跑 | 子会话行的 `running` / `status` 帧 |
| 待处理 | 既有投影/事件 |

派生（照桌面 `ui-workspace/src/client/tree.ts:381-386` 的公式）：

```dart
int runningChildrenOf(String parentSid) => subagentIdsOf(parentSid)
    .where((child) => runningOf(child) || rowOf(child)?.running == true).length;
```

一次快照算一遍，存 `Map<String,int>`，随列表刷新/状态帧更新（不是每次 build 现算）。

呈现（**形态按手机，不照桌面两枚点**）：

- 会话页：当前会话 `runningChildrenOf(currentSid) > 0` 时，输入栏上方**一行**
  「N 个子智能体在运行」+ 点进右抽屉子智能体页。
  - **高度必须先量后定**：这一行进 `chat_page.dart` 的 `_BottomBudget` 固定件预算，
    而 `blockMax` / `panelMax` 三个常量各有棘轮用例（`composer_layout_test` / `takeover_test`），
    规则是**常量只能 ≥ 实测**。所以批 E 的第一步是量（360dp × 字号 1.3、键盘态），
    再改常量与用例，不能先拍一个数。
  - 行用 `minHeight` 不写死高度（`type-scale.md` §5）。
  - 空态 / blank 会话不画（没有"子智能体在跑"这一事实）。
- 抽屉：**仍是一枚点**（`sessionDotOf` 优先级不变）；数量进副标题
  （`"2 个子智能体在跑"`），不画第二枚点 —— 桌面侧栏 240–420px，手机整行 360dp，
  两枚点会把标题挤到 3 行。这条写进 `docs/`，并注明"与 DSH 的有意偏离"。

---

## 6. 现有实现的统一与优化清单（本次一并收口）

### A. 必须统一（同一事实两份真值）

| # | 问题 | 证据 | 收口到 |
|---|---|---|---|
| A1 | 待处理有**两处**：`AppModel._pendingCountOf`（扫 store 的 `ApprovalItem`）与 `TakeoverController._queueOf`（事件流排队）；只有前者进界面 | `app_model.dart:3271-3277`、`:2496`；`ui/takeover.dart:152`（`pendingCountOf` **只有测试在用**） | 派生行事实一处（§6.C1）；`TakeoverController.pendingCountOf` 删除或转私有 |
| A2 | `session_dot.dart:35` 文档指向**不存在**的 `AppModel.pendingCountOf`；`:9-15` 断言"没有 `runningSubagentCount` 投影"是**错误前提** | `model/session_dot.dart:9-15,35`；桌面是客户端算的 `tree.ts:381-386` | 改注释 + 补 `runningChildrenOf` |
| A3 | 模型/推理默认缺宿主回落 | `app_model.dart:1256-1260`；桌面 `directory.ts:162,180` | `currentModel` 回落 `catalog.default` |
| A4 | `send_mode` 本地 vs 宿主 `busyEnter` | `app_model.dart:1420-1436` vs `ui-conversation/src/submission-settings.ts:1-33` | 批 H |
| A5 | 抽屉折叠按**显示标题**记 | `session_drawer.dart:200,363-367`；桌面按工作区身份 `stores.ts:25-26` | 批 B（键 = `workspaceId`） |

### B. 可以统一（同一机制的重复实现）

| # | 重复形态 | 证据 | 收口 |
|---|---|---|---|
| B1 | `(source: …, value: …)` 缓存 4 处，各自手写命中判断 | `app_model.dart:1210-1234, 1904-1925, 1954-1978, 1984-1999` | `data/cache.dart` 的 `SourceCache<T>`（`T get(source, build)`） |
| B2 | **47 个 `try` + 15 处 `_lastError =` + 81 处 `_disposed` 检查**，都是同一个"兜住但留声"的形态 | `app_model.dart:3244-3249`（三处计数由 `Select-String` 数出，2026-10-27） | `data/guarded.dart` 的 `guard(what, body)`；**保留留声语义，不吞** |
| B3 | 16 处 `'x-${DateTime.now().microsecondsSinceEpoch}'` 幂等键 | 全 `app/lib`（16 处） | `data/ids.dart` 的 `newRequestId('sel')` |
| B4 | 78 处 `notifyListeners()`，高频路径已部分合并（`upsertAll`/status 只在变化时） | `app_model.dart:2533`（已做）、`:3579`（已做） | 不改语义；把**剩下的逐条 notify 收成一次**（`_mutate(fn)` 帮助函数），逐批替换 |

### C. 可以优化（性能，都是 O(n) 在 build 里）

| # | 现状 | 证据 | 改法 |
|---|---|---|---|
| C1 | 每次列表刷新对**每个会话**扫一遍 store 算待处理 → O(会话×条目) | `app_model.dart:2496` + `:3271-3277` | `SessionStore` 维护增量计数（upsert 时更新），列表刷新 O(1)/会话 |
| C2 | `sessionOf(sid)` 线性扫 `_sessions`，10 处调用（含 build） | `app_model.dart:1165-1170` | `Map<String,SessionSummary>` 索引，随 `_sessions` 一起换 |
| C3 | `currentWorkspace` → `workspaceGroupOf` 是 O(工作区×成员)，hero/sheet 里调 3 次 | `model/workspace.dart:109-114`；`ui/chat_page.dart:2139,2145,2176` | 一次派生 `Map<sid, workspaceId>`（随 `workspace.list` 刷新） |
| C4 | `defaultNewSessionWorkspaceId` 的 `updatedAtOf` 是 O(会话) 回调，外层再遍历各组成员 → O(n²) | `app_model.dart:2956-2965`、`model/workspace.dart:141-160` | 索引 + 一次 `max updatedAt` 派生 |
| C5 | 行预览/点在 `main.dart` 的 `rowOf` 里现拼（每次通知全量重建） | `main.dart:912-941` | 与 C1 合并成"行事实"派生，一次快照算一遍 |

### D. 现存问题（顺手修，不改行为）

- D1 `theme.mode` 键名带点，与其余下划线风格不一致 → 迁移统一（§2.3）。
- D2 `AppModel` 里"通用偏好读写"（`readPreference/writePreference`，`app_model.dart:2308-2314`）
  与具名键两套入口并存，`ThemeController` 只走前者 → 统一到 `UiStateStore`，
  `AppModel` 不再暴露通用读写。
- D3 `_pendingCountOf` **只数审批**，而 `TakeoverController` 队列含提问 → 统一后
  计数按"审批 + 提问"口径（与桌面 `pendingInteraction` 的两 kind 一致；计划审查卡手机不做）。
- D4 `ChatPageState._sideFullscreen` / `_fileTab` / `_openJobs` 等临时态**继续留在 widget**
  （与桌面 transient layout 一致），但要在文件头写明"为什么它不需要活过页面"。

---

## 7. AppModel 收窄（4078 行 → façade）

按"职责簇"抽类，**AppModel 保留同名 getter 转发**，所以 UI 调用点不变：

| 新文件 | 内容 | 约 |
|---|---|---|
| `data/host_catalogs.dart` | 模型目录 / 权限目录 / 预设目录 / 设置面 / `repo.info` | ~450 行 |
| `data/file_preview.dart` | 文件打开 / 逐行差异 / 改动记录 / 正文提及词汇表 + 4 个 `SourceCache` | ~420 行 |
| `data/endpoint_book.dart` | 端点表 / 记住的那条 / 隐藏集 / 成功集 / 拨号记录 / LAN 地址 | ~360 行 |
| `data/session_rows.dart` | `_sessions` 索引 + 运行集 + 未读集 + 待处理计数 + 行事实派生 | ~300 行 |
| `data/ui_state.dart` | 设备本地缝（§2） | ~200 行 |
| `data/composer_gate.dart` | 门槛（§4） | ~90 行 |
| `data/cache.dart` / `ids.dart` / `guarded.dart` | 三个小工具 | ~120 行 |

收窄后的 `AppModel` 目标：**只做装配与转发**，不再自己写"第 20 个字段"。

---

## 8. 与既有约束的对照（逐条自检）

| 约束 | 本设计怎么满足 |
|---|---|
| 不引入第三方状态库 | 仍 `ChangeNotifier` + `ListenableBuilder`；新类不引包 |
| `data/` 不许碰平台 | `UiStateStore` 只依赖 `PreferenceStore`；flush 的 paused 态经既有 `AppStateReporter` 回调注入 |
| `wire/rpc/` 唯一解码层 | 只**增加** `subagentCatalog` 的读取（在 `wire/rpc/session.dart`），不新增 `call<` |
| 不新增协议方法/字段 | 只读已有 `values.subagentCatalog`；`busyEnter` 是宿主既有设置（补 allowlist） |
| 不新增宿主没有的边界 | 门槛集合 = 桌面集合 − 手机没有的 − 本版死分支；模型明确不在内 |
| `AppModel` 不再膨胀 | §7 三个簇抽出 + 两个新缝独立成文件 |

---

## 9. 分批落地（每批：红先用例 → 实现 → 变异 → 门禁 → 一个提交）

| 批 | 内容 | 主要文件 | 用例 |
|---|---|---|---|
| A | 动作门槛 | `data/composer_gate.dart`、`ui/chat_page.dart` | `composer_gate_test`（每条一句）+ widget：缺工作区时发送被挡且说清 |
| B | 设备本地机制 + 抽屉折叠 + 页签 | `data/ui_state.dart`（新）、`data/store.dart`（`deleteMeta` +1 + 批量口）、`platform/sqflite_item_store.dart` + 内存实现、`main.dart`、`session_drawer.dart`、`chat_page.dart` | `ui_state_test`（键/迁移幂等/清理/prune）+ 存储层断言 +1 条（两实现各跑一遍）+ 折叠态重启保持 + 页签存 id |
| C | 草稿 | `ui/chat_page.dart`（监听回调恢复）、`ui_state` 写句柄 | 重启恢复、**恢复不弹键盘**（`TestTextInput.isVisible`）、防抖只写一次、**build 里不出现读盘**（用例：通知 10 次只有 0 次 `read`） |
| D | 选择记忆默认 | `app_model.dart`（`currentModel`）、`chat_page.dart` | 新会话显示宿主默认模型/推理等级；目录拿不到时说"拿不到" |
| E | 连接瞬间复合 | `wire/rpc/session.dart`、`session_rows.dart`、`chat_page.dart`、`main.dart`、`model/session_dot.dart`（改注释） | 列表行带 `subagentCatalog`；`runningChildrenOf` 公式逐条对桌面；**先量再改** `_BottomBudget` 三常量 + 棘轮用例；会话页一行可见；抽屉副标题 |
| F | 提问草稿 | `ui/takeover.dart` | 答到第 2 题关掉再开还在；收束后 prune |
| G | 统一与优化（**拆成三簇**，见下） | `cache.dart`/`ids.dart`/`guarded.dart`/`session_rows.dart`/`host_catalogs.dart`/`file_preview.dart`/`endpoint_book.dart` | 现有全绿 + 索引/派生各一条 |
| H | `send_mode` → 宿主 | `connector/src/dsh/settings-face.ts`、`app_model.dart`、`data/store.dart`（删键） | 连接器 settings 用例 + 手机读宿主值/写回 |

**G 的实际拆分与状态（2026-10-27）**：

| 子批 | 内容 | 状态 |
|---|---|---|
| G1 | `ids.dart`（16 处幂等键）、`cache.dart`（4 处源缓存）、三处索引（`sessionOf` / 工作区 / 待处理计数） | **已落地** |
| G2 | `host_catalogs.dart`（模型/权限/预设目录） | **已落地** |
| G3 | `endpoint_book.dart`（G3-1）、`item_derivations.dart`（G3-2）、`session_rows.dart`（G3-3）、`file_preview.dart`（G3-4） | **已落地**，各一个提交与变异校验 |
| — | `guarded.dart` | **决定不做**：47 处 catch 各不相同（记 lastError / 面向用户的一句话 / 按码分支），统一模板只保住"吞掉"这一点，详见 `implemented/2026-10-27-appmodel-narrowing.md` 代价 3 |

门禁（每批都跑）：`dart analyze --fatal-infos lib test integration_test`、
`dart format --output=none --set-exit-if-changed …`、`flutter test`、
`verify-platform-boundary`、`verify-rpc-single-caller`；批 H 另加 `connector` 三条。

---

## 10. 风险与未决（评审请拍这三条）

1. **`parentOffline` 的判据**：手机只有"父会话还在 `session.list` 里"，不等于桌面的
   "有活 agent"（`manager.ts:277-286`）。建议取近似 + `docs/` 写明偏差；若评审要求严格，
   则该门槛本批**不判**（当前就是放行）。
2. **防抖窗口 300ms**：数字要由批 C 的实测（单次事务毫秒数）定，可能调大。
3. **`send_mode` 是否改走宿主**（批 H）：改要动连接器 allowlist（属补通道）；
   不改就要在 `docs/` 明确"手机本地、不回写电脑"，并接受两份真值。

---

## 11. 自审记录（2026-10-27，按"数据同 / 语义同 / 实现按本 App 栈与限制"逐条复核）

### 11.1 查出并已修的 5 处（其中 1 处是我自己写的判据错了）

| # | 原写法 | 问题 | 改成 |
|---|---|---|---|
| 1 | "**判据**：`ItemStore` 接口方法数不变" | **错**。prune/换电脑清理需要"按前缀删"，而 `ItemStore` 只有 `readMeta`/`writeMeta`/`clear`；用空串当删除哨兵会把"没有键"和"空值"混成一件事 | 接口 **+1**：`deleteMeta(key)`（按前缀，参数化 LIKE），两实现各 +5 行、共享断言 +1 条；判据改为"新增方法数 = 1，且只此一个" |
| 2 | 启动"**7 次单键读**" | 同一库连接上做 7 次往返，没必要；迁移与 prune 也会逐键往返 | `PreferenceStore`（data 层自己的窄缝）加 `readAll(prefix)` / `writeMany`：启动 1 次范围查 |
| 3 | 草稿"`openSession` 后**首次 build 前**读" | 侧效应进 `build`，违反"读不能出现在 build 里"；且流式输出期间会反复覆盖用户正在打的字 | 改成 `initState` 挂 `app.addListener`，比较 `currentSid` 变化时"先 flush 旧会话、再恢复新会话"；批 C 加一条"通知 10 次、读盘 0 次"的用例 |
| 4 | 门槛只有 `GateReady(stops)` / `GateBlocked` | 漏了桌面的 `primaryStops`（在跑 + 正文空 ⇒ 主键应变"停止"），也漏了"正文空时**不弹任何话**" | 四个变体：`GateSend` / `GateStop` / `GateEmpty`（静默禁用）/ `GateBlocked(reason, sentence)`；句子只允许来自桌面同一处 |
| 5 | 会话页新增一行只说"进 `_BottomBudget` 固定件" | 那三个常量带棘轮用例、规则是"常量 ≥ 实测"，不先量就改会红或溢出 | 批 E **第一步先量**（360dp × 字号 1.3 × 键盘态），再改常量与用例；行用 `minHeight` |

### 11.2 复核通过、确认"语义同、实现按栈"的 6 条

1. **模型/推理默认**：回落 `catalog.default` 是宿主**既有**语义（`directory.ts:162,180`、
   `agent.ts:464-472`），不是我们新加；实现放在 `AppModel.currentModel` 一处（Flutter 侧一个 getter）。
2. **工作区链**：`defaultNewSessionWorkspaceId` 已按桌面三档实现（`navigation.ts:351`），
   本设计只优化复杂度（索引），不改语义。
3. **子代理计数**：桌面就是客户端算的（`tree.ts:381-386`），手机照同一公式；
   渲染形态按 360dp 改（一枚点 + 一行文字），属形态偏离、不属语义偏离。
4. **发送门槛集合**：逐条对齐 `InputBar.tsx:341,343`、`:154`、`ConversationContent.tsx:142`；
   去掉的三项各有"手机没有对应物/本版死分支"的理由（`machineBusy` / `uploadsPending` / `blocked`）；
   **模型不在内**（两处独立实现都印证：桌面 `agent.ts:464-472`、rikkahub `ChatInput.kt:442`）。
5. **键与迁移**：没有任何"宿主没有的字段"；迁移用**编号代**（移动端原生，rikkahub 同形），
   读时容错沿用本仓既有的 `fromWire` 风格（如 `SendMode.fromWire`）。
6. **状态库**：仍是 `ChangeNotifier` + `ListenableBuilder`；新类不 import flutter（门禁可判）。

### 11.3 复核结论：HEAD 上八套门禁全绿（2026-10-27，`e25e120` 之后）

| 门禁 | 结果 |
|---|---|
| `node protocol/verify-fixtures.mjs` | 454 项断言 / 15 fixture |
| `node protocol/verify-loopback.mjs` | 26 项 |
| `node protocol/verify-vectors.mjs` | 49 项 |
| `node app/tools/verify-platform-boundary.mjs` | 613 项（25 条规则自检 + 142 个 Dart 文件） |
| `node app/tools/verify-rpc-single-caller.mjs` | PASS |
| `node mock/proto/tools/verify-icons.cjs` / `verify-tool-paths.mjs` | PASS / 24 个脚本、0 处硬编码盘符 |
| `cd app`：analyze / format / test | 0 / 0 changed / **1468 项全绿** |
| `cd connector`：tsc / build / test | 0 / OK / **686 项全绿** |
| `cd relay`：typecheck / test | 0 / **87 项全绿** |

### 11.4 本次复核**没有**改的

- 审计表的结论与行号引用（§C 的四处更正、D-1 的报错穷举）不变。
- 机制裁定五条（`state-semantics-mechanism-decisions.md`）不变 —— 上面的修改都在其判据之内
  （#1 是"接口 +1"而不是"新建表"；#2 是同一个 `PreferenceStore` 的批量口）。
