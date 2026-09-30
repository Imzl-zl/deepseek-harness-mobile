# 权限折进通用设置,并按 settings.general.item 的真实 order 排列

- 状态:已落地(`mock/proto/` 设置页通用二级页)
- 日期:2026-09-30

## 背景与约束

设置首页原来把「权限与会话」当作一个顶层设置组,和 DSH 的真实结构不符:权限根本不注册 `settings.section`,而是注册成 **`settings.general.item`**(`ui-permission-presets/src/client/index.ts:159-165`,id=`permission`,order **-20**,即通用设置里的第一行)。

更麻烦的是**语义混淆**:DSH 里这是两个不同设置项 ——

- 「新会话默认权限」= `permission.defaultPreset`,注册在通用设置里(`PermissionRow.tsx:41-89`);
- 「当前会话权限」= 输入栏的 `/permission` 浮层(`index.ts:167-174`,slot `conversation.input.permission`)。

原型的旧页面把两者合并成一个 badge,点开的是**当前会话**的访问模式 sheet,等于用一个 store 冒充两个设置项;`docs/settings-porting-notes.md` §7.5 第 1 条早已点出这个混淆。

同一次核对还查明:通用设置里一共有 12 行,顺序为 权限(-20)、语言(0)、外观(10)、字号(11)、工作步骤展示(12)、显示代码工作视图(15)、快捷键(16)、网页链接(17)、繁忙时发送(20)、性能与用量(30)、Session Log(90)、当前版本(100)(依据同清单 §33)。

## 候选方案

1. **保留顶层「权限与会话」页**,把它改成一个"下级入口行"放进通用设置(两级返回)。
2. **把权限直接摊进通用设置**,默认档与当前档拆成两行,删掉顶层页。
3. 保持现状(两层混用一个 store),只在文案上区分。

## 决定与理由

选 **2**。

- 方案 1 要在 `renderSettingsDetail` 里加一层返回栈,只为一行;而 DSH 的 `settings.general.item` 本来就是**行内**渲染,通用设置页里没有"再进一层"这回事。
- 方案 3 是把这个 bug 留在基线里,和 §7.5 的结论直接冲突。
- 方案 2 同时解决两件事:结构对齐(权限在通用设置里,且是第一行)+ 语义拆分(两个 store)。风险门也不重造,而是给 `Takeovers.gateSheet` 加一个可选落点参数(`interactions.js`,缺省仍是当前会话档),这样"切完全权限要勾风险确认"这条规则只有一份实现。
- 默认档候选**不含 Auto review**:`auto` 只属于当前会话档(`presentation.ts:15-19`),UI 上必须体现这个差别。

## 代价

- **通用设置页变长**(4 组 11 行):手机上一个二级页要滚。换来的是与 DSH 一致的排列,学习成本靠顺序而不是靠分组标题。
- **`当前版本` 的行序偏离**:DSH order 是 100(通用设置末行),手机端按第一版分组留在「关于与连接」(docs/design-and-tech-plan.md §391),避免同一事实在两页各写一遍。代价是通用设置比 DSH 少一行。
- **删掉两段不可达的二级页配置**:`permission` 与 `plugin-manager` 都不再有首页入口(前者折进通用,后者属独立主面板),留着就是死代码。
- `verify-settings.mjs` 从"权限与会话是顶层页"的旧断言改成按 `settings.general.item` 的 order 断言 11 行的**顺序**;顺序一旦被改乱就会红,而不是只测"页能不能打开"。

## 影响

- 通用设置行顺序成为受测契约:`verify-settings.mjs` 用 `#settingsDetail .settings-control .control-title` 的 DOM 顺序对齐 DSH order 列表。
- 快捷键(16)手机不搬,页面用一行 note 说明它被有意跳过,免得后来者当成漏做。
- 后续若 bridge 补上 `settings.update`,`新会话默认权限` 的落点就是 `permission.defaultPreset`,不再需要新概念。
- 顺带修掉一处同类缺陷:`.page--settings` 不在 `.motion` 的过渡名单里,设置页一直是**整页瞬移**(实测 `transition: all 0s`)。本次把 `.page--settings` 与 `.page--tasks` 一并挂进名单 —— 与 `jobs-in-side-drawer-not-standalone-page.md` 里记的"漏挂过渡"是同一类坑,tools.md 已把规则扩成"所有从右滑入的全屏页"。
