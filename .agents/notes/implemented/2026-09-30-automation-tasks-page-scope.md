# 自动化任务页:入口放左抽屉底栏、详情只做规则与删除

- 状态:已落地(`mock/proto/` 自动化任务页 + `tools/verify-tasks.mjs`)
- 日期:2026-09-30

## 背景与约束

DSH 的 `ui-schedule` 是**独立主面板**(`TaskManagerPage.tsx`),由侧栏 `sidebar.panellist` 承载(`TaskManagerIcon.tsx:14-16` 直接渲染时钟轮廓图标),不是设置项:它不注册 `settings.section`,只在自己的面板里列任务。手机上"侧栏"对应左会话抽屉,而抽屉底栏已经是"从主界面跳到另一个主面板"的既有通道(`设置`)。

同时手机屏幕放不下 DSH 详情页的能力面:`TaskDetail.tsx` 里能动的东西包括运行时间(日期/时间/时区/cron/星期/间隔)与任务运行记录(`DeliveryHistory`),而这两类数据在 bridge 侧都不存在。

## 候选方案

1. **照搬桌面详情**:规则编辑 + 运行记录两个 tab 全做。
2. **入口放设置组**:像"模型与服务商"那样做成设置二级页。
3. **独立主面板 + 只做规则与删除**:入口进抽屉底栏,详情只保留名称/内容与删除确认。

## 决定与理由

选 **3**。

- 方案 1 会**伪造数据**:运行记录要 `schedule.records`,`TaskDetail.tsx:813-824` 的 DeliveryHistory 依赖 `loadHistory`;bridge 的 `dsh-bridge` / `dsh-bridge-next` 都没有 schedule 方法。原型不许假装已远程提交(方案 §7.10 同一条纪律)。时间规则编辑还要 cron 解析与时区选择器(`task-cron.ts` 25KB、`ClockPicker`/`DatePicker`),在触屏上是一整套新交互,性价比极低。
- 方案 2 与 DSH 结构冲突:docs/design-and-tech-plan.md §393 已写明"插件管理与自动化任务属于独立主面板,不混入设置组";而且左抽屉点入口去开"设置里的一个二级页"会复刻 2026-09-30 那次"两个抽屉互相跳、用户以为没做"的错位(见 `jobs-in-side-drawer-not-standalone-page.md`)。
- 方案 3 保住了 DSH 的**结构对应**(面板 → 面板),又只落地能证实的东西。

## 代价

- **底栏标签取短名「自动化」**:DSH 面板名与页面标题都是「自动化任务」,但底栏其余四项(文件/归档/演示/设置)都是两字,320px 宽下 5 项会把「自动化任务」挤换行、整条底栏从 52px 撑到 65px。完整名保留在 `aria-label` 与页面标题。这是有意偏离,依据是同一栏的既有惯例。
- **详情能力面小于桌面**:时间规则编辑与运行记录都不做,页面底部用一行明确写"演示数据:`schedule.list/update/delete` 未进 bridge"。「关联会话·打开原会话」标 `需 bridge`(要会话目录才能把 `sessionId` 映射到本地会话行)。
- **"新建"不建任务**:DSH 的 `onNewTask` 是开新会话让模型建任务,页面本身没有创建表单(`TaskManagerPage.tsx:22-27,120`)。原型如实说成"已请求电脑端新建会话",不造一个假表单。
- 详情做成**页内第二层**而不是新的返回栈层:手机上详情从右压入,系统返回键只关整页;这与 DSH 的"列表 + 详情并排"是同一信息架构的两种形态。

## 影响

- 左抽屉 → 全屏页必须**先同步摘掉 drawer 层**:`tasks-open` 复制了 `settings-open` 的写法(`D.set(0, true)` + `closeLayer("drawer", true)`)。漏掉时页面会开在没收起的抽屉后面,并留下 `drawer` 幽灵层 —— 首次实现就漏了,是截图时发现的。
- 底栏从 4 项变 5 项,`verify-tasks.mjs` 用"逐项数标签行数 + 高度"守住 320px 不换行;`scrollWidth` 测不出换行(换行后不横向溢出),不能用它当断言。
- 任务列表行序照 `TaskManagerPage.tsx:64-65` 按 `scheduledAt` 升序,所以**已结束/逾期的任务排在最前**。
