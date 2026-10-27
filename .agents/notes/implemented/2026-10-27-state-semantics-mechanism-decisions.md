# 手机端 UI 状态：语义照宿主，机制照移动端

- 日期：2026-10-27
- 状态：implemented（五条裁定均已在 A–H 批落地，落地位置见文末"落地"一节）
- 相关：`proposed/2026-10-27-state-semantics-inventory.md`（缺口清单）、
  `proposed/2026-10-27-state-semantics-audit.md`（归属表与桌面/移动端证据）、
  `docs/subsystems/ui-state.md`（现状事实）

## Problem

复刻桌面外观时，UI 状态被当成"随手放哪都行"的局部变量：抽屉折叠态关一次就丢、
新会话没有模型默认值、草稿与页签重启即失。背后是同一个结构问题——**没有"UI 状态该住哪"的归属模型**。

更糟的是另一头：一旦决定"照桌面做"，最省事的做法是把桌面那套浏览器机制一比一翻成 Dart。
那条路会把 `localStorage` 的**便宜**（同步、整值、每变更写）当成**产品要求**，
落到 sqflite 上就是每击键一次事务；同时会与仓库既有的编号迁移（`storeSchemaVersion` +
`storeMigrations`）并存出第二套迁移。反过来，完全照移动端惯例（rikkahub 干脆不持久化草稿）
又会弱化用户明确提出的"关一次抽屉/重启不能丢"。

两头都不对，所以先把边界钉住：**数据源同一个 ⇒ 语义必须一致；技术栈不同 ⇒ 机制必须重选。**

## Decision

按下面五条裁定，每条都能用"文件/行"机械判定（判据写在括号里）：

1. **语义真值只来自宿主**：状态分类（host / browser-local-persisted / device-local）
   与每个状态的含义，一律以 DSH 源码 + 既有 RPC 字段为准；手机不新增协议方法、
   不新增宿主没有的字段与默认值（判据：`wire/rpc/` 方法集合与 `connector/` 的 `METHODS` 不增）。
2. **设备本地 UI 状态进 sqflite，走既有编号迁移**：新增一代 `storeMigrations`，
   不发明"键名带版本"、不新建持久化框架（判据：`meta`/`ui_state` 里的设备本地键全部
   有对应迁移代；`data/store.dart` 之外的 `ALTER TABLE` 数为 0）。
3. **活文本只由 `TextEditingController` 持有**；持久化是旁路（防抖 + `AppLifecycleState.paused`
   强制刷），且**不触发整页通知**（判据：草稿变化路径上不出现 `AppModel.notifyListeners()`）。
4. **选择记忆不建本地键**（判据：`meta` 表里不存在 model / reasoning / workspace 相关键）：
   模型与推理等级读 `session/modelCatalog` 的 `default`，工作区走桌面同一条派生链。
5. **动作门槛集中在一个纯函数入口**（`data/` 层），UI 只消费"能用 / 缺什么 / 该说的话"；
   门槛集合只含桌面有的条件——**不含"未选模型"**（判据：门槛函数的条件集合与
   `InputBar.tsx:343,154` + `ConversationContent.tsx:142` 逐条可对，多出一条即失败）。

## Alternatives considered

- **A. 一比一翻译桌面机制**（每变更同步写、键名带版本 `dsh.workspace.view.v5`、每会话一个键）。
  最强理由：语义与实现同源，维护者只需读一处；桌面已验证多年，行为不会跑偏。
  被否：桌面那套是 `localStorage` 的便宜（`packages/client/store/src/index.ts:159-165` 每次
  `setItem`），在 sqflite 上是每击键一次异步事务；且键名版本会与仓库既有编号迁移
  （`data/store.dart:32,199-241`）并成两套迁移，违反"三端同源、不许各处 ALTER"。
- **B. 引入第三方状态库**（riverpod / bloc）。
  最强理由：per-session scope、自动持久化、细粒度重建是它们的成熟能力，能省掉自定义机制。
  被否：仓库已有 `AppModel extends ChangeNotifier` + `ListenableBuilder` 的既定缝，
  本次真正缺的只是"一个设备本地缝"，不是全局状态图；引库会把 4078 行的 `AppModel`
  迁移变成独立工程，属于必须另开评审的决定。
- **C. 草稿不持久化**（rikkahub 的实际做法，`ui/hooks/ChatInputState.kt:12-17` 纯 UI 层）。
  最强理由：移动端成熟选择，零写盘、零迁移、天然没有"草稿串会话"风险。
  被否：用户明确要求"关一次抽屉 / 重启不能丢"，桌面也有该语义（`dsh.conversation.<sid>.draft`）；
  照 C 做等于把需求减弱成"更好维护"。
- **D. 选择记忆存本地"用户上次显式选过的那份"**。
  最强理由：不依赖目录加载时机，目录拿不到时也能显示一个模型名。
  被否：宿主已有 `agentDefaultModel`，且会话没有记录选择时**活跟随**默认
  （`packages/api/session-controller/src/agent.ts:464-472`），本地再存一份就是第二份真值；
  目录拿不到时的正确表现是"说拿不到"，不是显示一个旧值。
- **E. 请宿主新增 `runningSubagentCount` 字段**（让子代理计数一根字段拿全）。
  最强理由：客户端不用 join 两处数据，渲染层最省事。
  被否：桌面自己就是**客户端算的**（`packages/client/ui-workspace/src/client/tree.ts:381-386`），
  加字段等于新增宿主没有的边界；父行 `values.subagentCatalog` 已在 summary 键里过线。

## Consequences

收益：

- 每个状态有唯一主人，且能追溯到宿主行号；下一次有人问"这里该不该存"时有判据，不用重推。
- 迁移只有一套（编号代），与 items 同库同代，三端不会各自漂移。
- 草稿"不丢"与"不卡"同时成立：控制器持活文本，落盘走旁路。
- 门槛收在一处：新动作漏约束时是一条用例红，不是满屏找 `enabled:`。
- 页签存 id（不是下标），将来接第三方 View 不用换盘上格式。

代价：

1. 要给 sqflite 加一代迁移并在 `data/store.dart` 写 SQL —— 三端同源约束下，SQL 必须写在
   `data/`，不能在 `platform/` 悄悄 `ALTER TABLE`。
2. 旁路 + 防抖开出一个"最后一次写盘前被杀"的窗口；靠 `paused` 强制刷收窄，但**不能消除**，
   必须写进 `docs/`（"最多丢最后 N 毫秒的草稿"），否则下一个人会当 bug 修。
3. 不建本地选择键 ⇒ 首次连上、目录未到时模型 chip 仍显示「请选择模型」；这是"诚实"的代价，
   不是缺陷，要在文档里说明。
4. 离线时手机永远无法显示"上次用的模型"（接受：宿主是唯一真值）。
5. `app/lib/model/session_dot.dart:9-15` 那条"没有 `runningSubagentCount` 投影"的注释
   已改（前提错误），但**行形态仍是"一枚点 + 一行文字"**——360dp 放不下桌面的两枚点。
6. 被约束的代码入口都留了回指：`data/composer_gate.dart`（门槛）、
   `data/ui_state.dart`（设备本地缝）、`data/store.dart` 的 `storeDataMigrations`（迁移代）、
   `ui/takeover.dart`（提问草稿）、`ui/chat_page.dart` 的草稿恢复处。

## 落地（五条裁定各自在哪）

| 裁定 | 落地位置 |
|---|---|
| 1 语义真值只来自宿主 | 全部读取点；不新增协议（`wire/rpc/` 方法与连接器 `METHODS` 未增） |
| 2 设备本地状态走编号迁移 | `data/store.dart`（`storeSchemaVersion` 2 + `storeDataMigrations[1]`）、`data/ui_state.dart` |
| 3 活文本由控制器持有、落盘旁路 | `ui/chat_page.dart` 的 `_syncDraftForSession` / `_onInputChanged`；`UiStateStore.noteDraft/flushDrafts` |
| 4 选择记忆不建本地键 | `AppModel.currentModel`（回落 `catalog.defaultSelection`）、`defaultNewSessionWorkspaceId` |
| 5 动作门槛一个入口 | `data/composer_gate.dart`；UI 只消费结论（`ui/chat_page.dart`） |

批序与门禁结果见 `proposed/2026-10-27-ui-state-design.md` §9 与 git 历史（A–H 各一个提交）。
