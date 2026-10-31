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
| `device.surface_alpha` | 整数百分数 `55`..`100`（缺省 = `100`，即"不通透"）；壁纸本身不进键，见 [appearance-wallpaper.md](appearance-wallpaper.md) |
| `host.<hostId>.last_session` | sid |
| `host.<hostId>.drawer_expansion` | `{"<workspaceId>": bool}` |
| `host.<hostId>.session_view.<sid>` | 页签**注册项 id**（`chat` / `trajectory`），不是下标 |
| `host.<hostId>.session_draft.<sid>` | `{"text": "...", "references": []}`（照桌面 `DraftSnapshot`） |
| `host.<hostId>.question_draft.<sid>` | `{"item": "<itemId>", "index": n, "questions": {"<qid>": {"selected": [], "custom": "", "skipped": false}}}` |

一个键如果离开某台电脑就没有意义（会话 id / 工作区 id），它必须是 `host.`。

`<hostId>` 是那台电脑的 Ed25519 公钥（`pcSignPubHex`，配对时钉死）。**一台电脑一个桶**：
切到另一台只换桶，不删任何桶 —— 否则"切走再切回"会看不到上次的页签与草稿。
切换本身（连接 sheet 的「切换电脑」）是**换凭据槽 + 重新装配 `AppModel`**，
所以"只显示当前这台的数据"由装配结构保证，不靠界面过滤（`app-channel-client.md` §6.4）。
没有电脑身份时（未配对 / 单测没装配身份）键用 `host.<field>` 的平铺形状 ——
那是"状态不属于任何一台电脑"，**不是旧数据迁移**：拿到身份后不搬、不删（协议未发版，没有存量）。

## 3. 存储、迁移与清理

- 存储仍是 `meta` 表（`ItemStore` 的 k/v），**没有新表**；`ItemStore` 为此只加了两个方法：
  `readMetaPrefix(prefix)` 与 `deleteMeta(prefix, {includePrefixed: true})`
  （`app/lib/data/store.dart`）。后者必须能**精确删**：`sid-1` 是 `sid-10` 的字符串前缀。
- 版本：`storeSchemaVersion` 2。`storeMigrations[1]` 是空 DDL，
  真正的改写在 `storeDataMigrations[1]`（`app/lib/data/store.dart`）：
  旧键改名 → 删旧键，幂等；`schema.data_version` 记账，半途崩可自愈。
  执行点是 `platform/sqflite_item_store.dart` 的 `open()`（DDL 之后）。
- 清理：`UiStateStore.clearHostScope()` 只删**当前桶**（"忘掉这一台"），
  它是用户动作，不是配对成功的副作用；`pruneSessions(liveSids)` 只剪**当前桶**
  （`liveSids` 来自当前那台电脑的清单）；`pruneWorkspaces(liveIds)` 由
  `refreshWorkspaces` 调。`device.*` 与别的电脑的桶不参与任何清理。
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
- `app/integration_test/ui_state_live_probe_test.dart`（**真机**，复用设备上已有配对、不花模型钱）：
  真宿主上 `settings.describe` 确有 `ui-conversation.busyEnter`（取值只有 `queue` / `steer`）、
  `settings.update` 写得进并回读得到、`session.list` 的行确实带 `values.subagentCatalog`。
  2026-10-27 实测：302 行里 123 行带该键、15 行有子级。

### 真机逐条清单（2026-10-27，设备 `d61cf622`，截图在 `D:\tmp\ui-state-shots\`）

| 条目 | 结果 | 判据 |
|---|---|---|
| 抽屉折叠跨 force-stop 重启 | 通过 | 收起 easyStory 后重开仍收起；盘上 `host.drawer_expansion` 出现该 workspaceId=false |
| 页签按会话 + 跨重启 | 通过 | 重开后仍停在「轨迹」；`host.session_view.<sid>=trajectory` |
| 草稿恢复且不弹键盘 | 通过 | 重启后输入框仍是原文本，`dumpsys input_method` 的 `mInputShown=false` |
| 门槛四态 | 3/4 | 无工作区 blank：占位「选择工作区」且发送静默禁用；有工作区正文空：发送灰、模型/权限 chip 可弹；正文非空可发。「未配对」态未测（会动配对凭据） |
| 模型/推理回落宿主默认 | 通过 | 新建 blank 显示宿主默认模型名（`auto`），与 Web UI 同；该模型目录无 efforts 故不显示等级（同桌面条件渲染） |
| 子智能体在跑可见 | 未测 | 免费渠道对 agent 的真实请求回 `403`（裸 / 带 tools / 流式单独打都是 200，见提交记录），一轮都没跑成 |
| 提问草稿 | 未测 | 同上，没有 `ask_user_question` 可答 |
| 发送模式唯一真值 | **阻塞** | 真机上「设置」页整屏白屏（零语义节点、`logcat` 无 Flutter 异常、返回键能退回）—— 改发送模式的唯一入口在那一页 |
| 设备库 schema=2 与旧键 | 通过（部分） | `user_version=2`、`schema.data_version=2`、无 `theme.mode`/`ui_scale_index`/`last_session`；`device.theme_mode` 不存在，因该设备全新安装在 v2、v1 数据从未存在 |
| 断连/重连不丢状态 | 部分通过 | 停中转 → 顶栏「连接中…」；恢复中转 → 自动回「已连接」，同一会话与三轮内容仍在。**抽屉折叠/页签/草稿**没有存量可验：本轮重新配对把 `host.*` 按设计清空了 |

设备侧新增问题（未修，待下一轮）：**「设置」页白屏**。复现：抽屉底栏「设置」→ 页面全白、语义树 0 节点、
`logcat` 无 `E/flutter`、`logcat -c` 后重试同样白屏；按返回键能回到会话页。

落点本身在真机上验证过：修前每次都落到 blank（页签/草稿看起来"没恢复"），
修后重开回到原会话（见 `connect-landing.md` §2 与那篇决策笔记）。
