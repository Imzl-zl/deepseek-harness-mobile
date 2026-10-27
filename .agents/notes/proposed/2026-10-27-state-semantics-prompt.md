# 新会话提示词：审计并统一"UI 状态语义"（按 Flutter 与移动端规范，不是补丁）

你在 `D:\sudy\myproject\dsh-mobile` 工作（Windows / pwsh，Flutter + Dart，`connector/` 是 TS 网关）。
先读：根 `AGENTS.md`、`tools.md`、`memory.md`、`docs/AGENTS.md`、`.agents/notes/AGENTS.md`、
`docs/subsystems/app-platform-boundaries.md`、`docs/subsystems/input-focus.md`、
`docs/subsystems/type-scale.md`、`docs/subsystems/app-channel-client.md`，
再读 `.agents/notes/proposed/2026-10-27-state-semantics-inventory.md`（已发现的缺口与不变量）。

## 背景（用户原话，必须当真）

> "你很显然只是复刻了外貌，深层次的你根本没看，不知道还有多少同样的问题。"
> "不要到处打补丁了……这应该涉及到状态管理了吧？给我看看怎么样优雅解决。"
> "你这个肯定是按照移动端的规范来还有这个技术栈的规范来，可不是你随便说的。"

已确认的同类问题只是样本：抽屉折叠态关一次就丢；模型/思考程度/工作区不记用户选择；
空白会话能直接发送（桌面不许，发了就失败）；连接时"运行中 + 子智能体后台任务"呈现不全。
共同点：**状态没有唯一主人、约束没有唯一落点。**

## 规范基线（违反任一条，方案即被否）

**Flutter / Dart 技术栈**

- 状态管理**复用本仓既有那套**：`AppModel extends ChangeNotifier` + 页面 `ListenableBuilder`；
  `data/` 的 `PreferenceStore`（`MetaPreferences` 包 `ItemStore.meta`）是本地偏好的唯一缝。
  **不引入新的第三方状态库**（provider / riverpod / bloc…）；确需，另开评审，不在本批。
- 分层与依赖方向：`core/` 纯 Dart 无平台分支、`model/` 纯值解析、`data/` 编排、`ui/` 只画；
  `wire/rpc/` 是线上形状唯一解码层（`verify-rpc-single-caller.mjs` 会拦）。
  新状态机制必须落在 `data/`（编排）或 `core/`（纯逻辑），**不许在 `ui/` 里读本地库或拼键名**。
- 平台差异只住 `app/packages/*`（`app-platform-boundaries.md`）；`core/` 里出现平台分支即失败。
- Flutter 行为**先查本机 SDK**：`node app/tools/flutter-api.mjs <符号>`，引用写
  `packages/flutter/lib/src/...:行号`；查不到按 `tools.md`「Flutter 行为查证」的顺序，**量了才算数**。
- `AppModel` 已 4000+ 行：新机制若让它继续膨胀，方案里要给**拆分或收窄**的计划，
  而不是再往里堆第 20 个字段。

**移动端规范（Android / iOS / OHOS）**

- **冷启动恢复**：进程被杀后重开，用户应回到同一屏同一状态；恢复顺序固定为
  "本地偏好 → 宿主投影/列表 → 冲突以宿主为准"，且**恢复不得阻塞首帧**（异步、可渲染中间态）。
- **前后台切换**：不因一次后台而丢状态；不在 UI 层做节流以外的持久化节流黑魔法。
- 输入焦点照 `input-focus.md`：输入法只允许**用户点输入框**引起，状态恢复不得弹出键盘。
- 键盘/窄屏：任何新 chip/行都要过 360px 不溢出（`type-scale.md` 的 minHeight 规则）。
- 性能：持久化写入必须异步、合并（不得每次击键落盘）；读不能出现在 `build` 里。
- 真机验证只在 `dsh-mobile-test` profile；**不开辅助功能、不改 TalkBack/导航模式**；
  需要扫码配对或重启桌面 DSH 时停下来问用户。

**文档纪律（本仓规矩，别搞错）**

- 审计表与设计文档在**落地前放 `proposed/`**；`docs/subsystems/` 只写**现状事实**，
  落地那一批再更新，且同批改 `docs/AGENTS.md` 索引。
- 决策笔记与代码同批提交；被否方案与代价必须写。

## 任务（严格三段，每段结束**停下来等评审**）

### 第 1 段：全量审计（只读，不改代码）

把 `app/lib` 里所有"跨页面 / 跨重启 / 跨连接该活下来"的状态找出来，逐个回答：
它是什么；桌面对应物与主人（联网源码 `D:\sudy\github\deepseek-harness`，给 `packages/...:行号`）；
手机现在住在哪里；现在丢不丢、什么时候丢；恢复时机（首帧前 / 首帧后）。
同时列**动作前置约束**（发送、分支、打开文件、切模型…）：桌面什么条件下禁用、依据哪一行、
手机是否同样禁用、缺什么该说哪句话。
产出：归属表（状态/动作 → 主人 → 存储（哪个缝/哪个键）→ 读取与恢复时机 → 桌面证据）。
**交表即停**，等我点头再进第 2 段。

### 第 2 段：机制设计（一次说清，不许写成 N 个补丁）

- 三类主人：`host`（只读）、`browser-local-persisted`（桌面自己持久化的浏览器状态，手机用同构替代）、
  `device-local`（手机偏好）。每类给读取时机、失效与迁移规则（版本号 + 迁移）。
- 设备本地状态**一个机制**：统一键前缀、统一序列化与迁移、统一恢复点（`AppModel.start()` 一处）、
  统一清理；widget 不再持有这类状态。
- 动作可用性**一个入口**（如 `composerGateOf(...)` 返回"能用 / 缺什么 / 该说的话"），UI 只消费。
- 连接瞬间的快照：进服务态后一次画全（运行中、子智能体后台任务、待处理、计数），只来自宿主已有字段。
- 与既有约束一致：手机不拼 cwd、不伪造 fork、不代理宿主 HTTP、不新增宿主没有的边界。
- 产出：设计文档 + 决策笔记（含被否方案与代价）+ **要动的文件清单与拆分计划**。**再停一次**。

### 第 3 段：分批落地

每批：红先写用例 → 实现 → 变异校验（故意破坏，恰好那几条红，条数写进提交）→ 门禁全绿 → 一个提交。
建议顺序（可按审计调整）：

1. 发送门槛（缺工作区/模型置灰 + 说清缺什么）；
2. 设备本地状态机制 + 抽屉折叠态 / 对话·轨迹页签 / 草稿接入；
3. 选择记忆：模型 / 推理等级 / 工作区——**默认值优先从宿主拿**（`agent-default-model`、
   `permission.catalog` 默认档、最近选择的会话），手机只存"用户显式选过"的那份；
4. 连接时的复合状态：子智能体后台任务在会话页可见；
5. 回验收：补改动卡 / 逐行差异 / 正文提及的真机验收。

门禁：`cd app && dart analyze --fatal-infos lib test integration_test`、
`dart format --output=none --set-exit-if-changed lib test integration_test`、`flutter test`、
`node app/tools/verify-platform-boundary.mjs`、`node app/tools/verify-rpc-single-caller.mjs`；
动连接器再加 `cd connector && pnpm exec tsc --noEmit && pnpm build && pnpm test`。

## 硬规则

- 先审计后设计，**不允许先改代码再解释**；每个结论给 `packages/...:行号` 或本仓 `文件:行号`，查不到写「未找到」。
- **约束以 DSH 源码为基线，外观/文案以 `docs/design-and-tech-plan.md` 为基线**；两者冲突时先改文档再改代码。
- 不删/不弱化已有用例；改断言必须做一次变异校验并写清红了几条。
- 每批只解决一类问题；发现新的同类问题**记进清单**，不顺手打进当前批。
- 不新增协议方法、不新增宿主没有的字段；需要时先提案并停。

## 交付物

1. 状态/约束审计表（`proposed/`）；
2. 设计文档 + 决策笔记（含被否方案与代价）+ 文件清单/拆分计划；
3. 按批提交（每批一个，消息里写变异校验红了几条）；
4. 真机证据（截图/日志）与门禁输出；落地那批再更新 `docs/subsystems/` 与索引。
