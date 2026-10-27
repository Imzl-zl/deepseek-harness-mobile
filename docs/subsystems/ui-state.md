# UI 状态：谁拥有、存哪里、什么时候恢复

手机侧的每个可见状态都必须能回答"主人是谁"。**没有第四种主人**：`widget` 里存的
只能是"活过这一帧就够"的东西（卡片展开、`@` 候选 drill、拖动高亮）。

判据与取舍的因果在 `.agents/notes/proposed/2026-10-27-state-semantics-audit.md`（归属表）
与 `implemented/2026-10-27-state-semantics-mechanism-decisions.md`（五条裁定）。

## 1. 三类主人

| 主人 | 内容 | 读取时机 | 失效 |
|---|---|---|---|
| `host` | 会话行、投影（`subagentCatalog` / `modelSelection` / `permission`…）、`status` 帧、jobs、queue、**设置文档** | 读即用 | 宿主说了算；手机不缓存过夜 |
| `browser-local-persisted` 的同构替代 | 每会话页签、草稿、提问进度；抽屉分组折叠；上次看的会话 | **首帧前**（`AppModel.loadUiState()`） | 换电脑整段清；会话/工作区消失则 prune |
| `device-local` | 主题、界面字号、工作步骤密度、收起时机、性能用量 | **首帧前**（同上） | **跨电脑保留**（与某台电脑无关） |

发送模式**不在**这三类里：它属于 `host`（`ui-conversation.busyEnter`），
见 §5。

## 2. 键方案（唯一拼写处 `app/lib/data/ui_state.dart` 的 `UiKey`）

| 键 | 值 |
|---|---|
| `device.theme_mode` | `system` / `light` / `dark` |
| `device.ui_scale_index` | `0`..`3` |
| `device.transcript_view` | `compact` / `standard` / `detailed` / `fully-open` |
| `device.performance_view` | `compact` / `detailed` |
| `device.collapse_timing` | `completion` / `next-input` |
| `host.last_session` | sid |
| `host.drawer_expansion` | `{"<workspaceId>": bool}` |
| `host.session_view.<sid>` | 页签**注册项 id**（`chat` / `trajectory`），不是下标 |
| `host.session_draft.<sid>` | `{"text": "...", "references": []}`（照桌面 `DraftSnapshot`） |
| `host.question_draft.<sid>` | `{"item": "<itemId>", "index": n, "questions": {"<qid>": {"selected": [], "custom": "", "skipped": false}}}` |

一个键如果离开某台电脑就没有意义（会话 id / 工作区 id），它必须是 `host.`。

## 3. 存储、迁移与清理

- 存储仍是 `meta` 表（`ItemStore` 的 k/v），**没有新表**；`ItemStore` 为此只加了两个方法：
  `readMetaPrefix(prefix)` 与 `deleteMeta(prefix, {includePrefixed: true})`
  （`app/lib/data/store.dart`）。后者必须能**精确删**：`sid-1` 是 `sid-10` 的字符串前缀。
- 版本：`storeSchemaVersion` 2。`storeMigrations[1]` 是空 DDL，
  真正的改写在 `storeDataMigrations[1]`（`app/lib/data/store.dart`）：
  旧键改名 → 删旧键，幂等；`schema.data_version` 记账，半途崩可自愈。
  执行点是 `platform/sqflite_item_store.dart` 的 `open()`（DDL 之后）。
- 清理：`UiStateStore.clearHostScope()`（换电脑删 `host.*`）由
  `main.dart` 的 `_onPaired` 调；`pruneSessions(liveSids)` / `pruneWorkspaces(liveIds)`
  由 `refreshSessions` / `refreshWorkspaces` 调。`device.*` 不参与任何清理。
- 写：非高频值走串行链立即写；**草稿防抖 300 ms**，`AppLifecycleState.paused`、
  切会话、发送成功、`dispose` 时 flush。代价：进程在窗口内被杀最多丢这段输入。

## 4. 会话级状态的运行时归属

| 状态 | 活值 | 说明 |
|---|---|---|
| 草稿文本 | `ChatPageState._input`（`TextEditingController`） | **唯一主人**。恢复走 `AppModel` 监听回调（不在 `build` 里读盘），只设 `controller.text`、**不请求焦点**（输入法只许用户点输入框引起，`input-focus.md`） |
| 页签 | `AppModel.viewOf(sid)`（内存 map，`openSession` 时懒读一次） | 写的是 id |
| 提问进度 | `TakeoverController`（读写端口注入，页面接到 `AppModel`） | 形状见 §2；收束时删 |

草稿**不进** `AppModel` 的通知路径：`ChangeNotifier.notifyListeners()` 同步遍历全部监听者
（`packages/flutter/lib/src/foundation/change_notifier.dart:410-451`），草稿一进去就是每击键整页重建。

## 5. 选择记忆：默认值来自宿主

- 模型与推理等级：`AppModel.currentModel` = 会话行/投影的 `modelSelection`，
  没有记录时回落 `session/modelCatalog` 的 `default`
  （桌面 `ui-model-selection/src/client/directory.ts:162,180`）；
  会话侧也活跟随默认（`api/session-controller/src/agent.ts:464-472`）。
  **手机不存"上次选的模型"**。目录拿不到时 `currentModel` 为 `null`，界面说"拿不到"。
- 新会话落哪个工作区：`defaultNewSessionWorkspaceId`（当前会话的工作区 → 最近更新的），
  实现与偏离见 `model/workspace.dart` 的 `newSessionWorkspaceId`。
- 发送模式：读 `settings.describe` 的 `ui-conversation.busyEnter`，切模式写
  `settings.update`（连接器 allowlist 各有一条）。老连接器没有这个设置面时，
  本机 `meta.send_mode` 是**退路**，不是第二条主路。

## 6. 动作可用性：一个入口

`app/lib/data/composer_gate.dart` 的 `composerGateOf(...)` 返回四种结论：
`GateSend` / `GateStop` / `GateDisabled`（静默禁用）/ `GateBlocked(reason, sentence)`。

- 条件集合 = 桌面集合 − 手机没有的：`machineBusy`（手机没有输入机状态机）、
  `uploadsPending`（手机没有宿主上传阶段）、`blocked`（本版 DSH 无 feature 使用它）。
- **"未选模型"永远不是门槛**（宿主 prompt 路径不校验模型）。
- 只有 `GateBlocked` 带句子；`noWorkspace` / `subagentReadOnly` / `parentOffline`
  三档会替换输入栏占位文案，`notPaired` / `noSession` 保持原型基线文案。
- `parentOffline` 是**近似判据**：桌面看客户端"父会话有活 agent"
  （`session-controller/src/client/sessions/manager.ts:277-286`），手机只能看
  "父会话还在 `session.list` 里"。

## 7. 连接瞬间的复合状态

`AppModel.runningChildrenOf(sid)` = 父行 `values.subagentCatalog` 里的子 id 中
`running` 为真的个数（公式照桌面 `ui-workspace/src/client/tree.ts:381-386`；
手机侧状态帧与列表行已合成 `_runningSids`，故只读那一份）。

- 会话页：`> 0` 时输入栏上方一行「N 个子智能体在运行」，点击进右抽屉子智能体面板。
- 抽屉：行首仍是**一枚**状态点；数量进副标题「N 个子智能体在跑」——
  桌面是两枚点，360dp 放不下（**有意偏离**）。

## 8. 验证

- `app/test/ui_state_test.dart`：键 / 迁移幂等 / 三类清理 / 页签 / 草稿形状与防抖。
- `app/test/ui_state_wiring_test.dart`：启动前置读、页签按会话、抽屉按工作区身份、换电脑只清 `host.*`。
- `app/test/store_contract_test.dart`：`deleteMeta`（前缀删 / 精确删）、`readMetaPrefix`、v1→v2 迁移（两个实现各跑一遍）。
- `app/test/composer_gate_test.dart` + `composer_gate_wiring_test.dart`：门槛矩阵与接线（含"正文空不锁整条栏"）。
- `app/test/draft_wiring_test.dart`：重启恢复、**恢复不弹键盘**、按会话切换。
- `app/test/question_draft_test.dart`：答一半离开回来还在、收束即删。
- `app/test/subagent_running_test.dart`：计数公式、会话页一行、360dp × 字号 1.3 × 键盘态不溢出。
- `app/test/send_mode_host_test.dart` + `connector/tests/settings-face.test.ts`：发送模式以宿主为准、老连接器退路。
