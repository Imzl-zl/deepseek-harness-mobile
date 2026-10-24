# Agent Note: 插件清单与行级启停 —— 方法面在 `plugin-manager`，不在 `plugin-inventory`

Status: implemented

## Problem

手机上一直没有插件页。早先的结论是"插件页无法通用渲染"（`docs/plugin-and-jobs-notes.md` A.5：
Schemastery 只发 `volatile` 字段、配置表单渲染器不存在），那条结论只否掉了
**逐插件的配置页**，没有否掉"清单 + 启用/停用"。

真正卡住的是**我第一次查错了包**：`packages/host/plugin-inventory/src/index.ts:70` 只有一个
`list()`（只读快照 `PluginInventorySnapshot`），**它没有 `@Remote`** —— 看到它就会以为"插件
没有一个能被客户端调的方法"。真正的方法面在
`packages/boot/plugin-manager/src/index.ts`：`PluginManager`（服务键 `pluginManager`，`:333`）
有 **14 个 `@Remote`**，其中三个是本任务用得到的：

- `listPlugins(): Promise<PluginInfo[]>`（`:439`）
- `setPluginEnabled(id, enabled): Promise<ChangeResult>`（`:796`）
- （`setBundleEnabled(name, enabled)`（`:814`）—— **不做**，见下）

## Decision

**只透传清单与行级启停。**

1. `plugin.list` → `{plugins: [...]}`，行就是宿主的 `PluginInfo`
   （`plugin-manager/src/types.ts:55` 的 `PluginInventoryEntry & ({patchId} | {readOnlyReason})`）：
   `entryId` / `moduleName` / `enabled` / `fiberPhase` / 可选 `meta` / `patchId` 或 `readOnlyReason`。
   **不翻译**：`meta.title` 是 `LocalizedText`（`string | {en, [locale]}`，
   `packages/util/package-manifest/src/types.ts:44`），挑哪一档是界面的事 ——
   连接器挑一遍、手机再挑一遍就会出现"同一台电脑两种语言"。
2. `plugin.setEnabled` → `{name, enabled, application?, restartReason?}`，参数 `{id, enabled}`
   （`id` 就是清单行里的 `entryId`，宿主的 `PluginEntryId`）。
   **`enabled` 是回读后的真值**：宿主 `setPluginEnabled` 写完 profile patch 会热重载，
   `application` 可能是 `overridden`（更高优先级的层盖住了）—— 那时请求值与终态不同，
   回声我们请求的 bool 就是撒谎。所以在成功之后**再读一次清单**取那一行。
3. 能力位 `caps.plugins` 与"挂不挂这两个方法"读**同一个函数**
   （`dsh/caps.ts` 的 `pluginsAvailable`）—— 与 `caps.references` 同一个套路。
   老连接器不报这个键 ⇒ 手机**不发请求**、说一句"这台电脑没有插件服务"。
4. 手机：抽屉底栏「插件」→ `PluginsPageHost`（进页拉一次、`ListenableBuilder` 重画）。
   行 = 展示名（`meta.title` 挑一档，没有就退回模块名）+ 模块名（与展示名相同时不重复画）
   + 开关。**只有宿主给了 `patchId` 的行才可点**（`PluginRow.canToggle`），
   不可点的行把原因写在下面（`management-required` → "只能在电脑上改"）。

## Alternatives considered

1. **用 `host/plugin-inventory` 的 `list()` 当数据源** —— 最强理由：它听起来就是"插件清单"。
   被否：它**没有 `@Remote`**，客户端调不到；而且它不给 `patchId` / `readOnlyReason`，
   于是"能不能改"这个判据在手机侧会变成"猜"。
2. **一起把安装 / 卸载 / 升级做掉**（`installBundle:835` / `removeBundle:999` / `updateBundle:677`）——
   最强理由：Web 的插件页有这些按钮，接口都已经核实。
   被否：它们动的是 profile 的 `package.json` 与 `pnpm-lock.yaml`，还会跑 `pnpm`；
   失败（网络 / git / registry / 版本不兼容）在手机上既看不见日志也修不了。
   风险面另议 —— 这是**范围决定**，不是"手机版少几个字段"。
3. **bundle 级启停（`setBundleEnabled`）** —— 被否：bundle 是"一层 patch"，
   关掉会连带改掉一串行；手机上呈现"哪些行跟着没了"需要另一套界面，收益不足。
4. **容器侧把 `meta` 翻成一个字符串再送** —— 被否：见 Decision 第 1 条（两份语言规则）。
5. **启停后回执只回 `{name, enabled}` 用请求值** —— 被否：`overridden` 时撒谎；
   回读一次清单的代价是用户点一次开关多一次本地读，可以接受。
6. **把插件页放进设置页** —— 被否：它答的是"这台电脑上装了什么"，是查看类入口；
   抽屉底栏已经有用量/归档同样的先例（用户 2026-10-19 明确要求"常用功能别埋太深"）。

## Consequences

- **收益**：手机上能看见这台电脑装了什么、能一行一行地启停；字段全部来自宿主，不翻译不猜。
- **代价**：一次启停 = `setPluginEnabled` + 一次回读 `listPlugins`（都是本地调用，不是网络往返）。
- **代价**：`fiberPhase` 原样过线但界面暂不展示（"在跑 / 待服务 / 加载失败"的措辞还没定，
  摆原值等于把实现细节丢给用户；等有需要再补一层显示映射）。
- **代价（门禁churn）**：`Caps` 每加一个能力位，connector 侧的测试字面量都要跟着加一行
  （本轮 `references` 与 `plugins` 各触发一次）。这是"能力位是一个封闭结构"的必然代价，
  目前按字面量逐个补齐；若再频繁，应抽一个 `tests/support/caps.ts` 的基线工厂。

## 判据

- connector **629 → 636**（`tests/plugins.test.ts` 7 条）：方法表与幂等键、清单两档行原样、
  空清单、启停回读真值、`overridden` 时不回声请求值、宿主抛错原样、caps 有/无。
- flutter **1192 → 1199**（`test/plugins_page_test.dart` 7 条）：行解析两档（语言表 / 退回模块名）、
  认不出的行丢掉、页面两行与只读开关禁用、空清单、老连接器不发请求、点开关发 `{id, enabled}`+键、
  `overridden` 时行保持原状且说清原因。
- **变异校验**：把 `PluginRow.canToggle` 改成恒真 ⇒ 恰好两条红（模型那条断言 `canToggle`、
  页面那条断言只读开关 `onChanged == null`），其余仍绿 —— 它俩守的是**同一个**不变量。做完即还原。
- `pnpm exec tsc --noEmit` 0、`pnpm build` 过、`dart analyze --fatal-infos` 0、`dart format` 0。

## 代码入口回指

- 连接器：`connector/src/dsh/plugins.ts`、`connector/src/dsh/caps.ts` 的 `pluginsAvailable`、
  `connector/src/index.ts` 的挂载点、`connector/src/handlers.ts` 的 `plugin.list` / `plugin.setEnabled`、
  `connector/src/protocol/methods.ts`（封闭集与幂等集）。
- 手机：`app/lib/model/plugins.dart`（`PluginRow` / `PluginToggleOutcome` / `localizedTextOf`）、
  `app/lib/data/app_model.dart` 的 `plugins*` / `refreshPlugins` / `setPluginEnabled`、
  `app/lib/ui/plugins_page.dart`、装配点 `app/lib/main.dart` 的抽屉底栏。
- 契约：`docs/subsystems/remote-channel.md` §5.7 的两行；边界与不做清单
  仍以 `docs/plugin-and-jobs-notes.md` 为准（本轮补了 §A.4 的一行）。
