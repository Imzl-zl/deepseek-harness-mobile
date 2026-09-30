# dsh-mobile AGENTS

## 常驻军规

- 改 `mock/proto/` 下任何东西后,至少跑 `node mock/proto/tools/verify-icons.cjs`;动了布局/交互再跑 `verify-proto.mjs`,动了权限路径必须跑 `verify-authz.mjs`(18 项须全绿)。
- 原型里所有图标走 `window.DshIcons`(`mock/proto/icons.js`);**禁止新增 unicode 字形当图标**,`node mock/proto/tools/verify-icons.cjs` 会拦。
- 视觉与文案以 `docs/design-and-tech-plan.md` 为基线;与文档冲突时先改文档再改代码。
- 非平凡改动必须留下决策笔记,代码与笔记同批提交;格式与判定见 `decision-notes` 技能。
- 引用 DSH 行为时给出 `packages/...:行号`;查不到就写「未找到」,**禁止猜**。
- `mock/proto/` 是交互基线,`app/` 是 Flutter 落地端;**改基线要同步改落地端,不允许两边各自漂移**。

## 0. 实施基线

- 环境:Windows / PowerShell(pwsh);Node.js 可用(`node --check`、验证脚本均以 node 运行)。
- 语言/运行时:原型 = 纯浏览器 JS/CSS/HTML(无构建步骤、无 npm 依赖);App = Dart / Flutter(仅主题层已落地)。
- 主要技术栈:Flutter(目标 iOS / 安卓 / 鸿蒙 OHOS fork);原型用原生 DOM + 手写手势。
- 配置根目录:无(本仓库无 `package.json` / `pubspec.yaml` / CI 配置;`app/` 尚无 Flutter 工程文件)。
- 标准验证命令:
  - `node mock/proto/tools/verify-icons.cjs` —— 图标集完整性(不需要浏览器)
  - `pwsh -File mock/proto/tools/cdp.ps1` 起 headless Chrome,再设 `CDP_URL` / `NO_PROXY` 后跑 `verify-proto.mjs` / `verify-authz.mjs` / `verify-picker.mjs` / `measure-composer.mjs`
  - `node --check mock/proto/app.js`(以及 `interactions.js`、`tools/*.mjs`)

## 1. 作用

- 本文件是项目级硬规则,只保留长期约束实现结构的内容。
- 详细设计、字段说明、逐屏规格统一回到 `docs/`。

## 2. Source of Truth

- `docs/design-and-tech-plan.md` —— 设计与技术基线(总纲);冲突时以它为准,改它再改代码。
- `docs/settings-porting-notes.md` —— 设置项逐项搬运清单(42 项:搬/只读/不做/必须分叉)。
- `docs/plugin-and-jobs-notes.md` —— 插件体系与后台任务的移动端边界(含"插件页为何无法通用渲染")。
- `docs/standalone-mode-notes.md` —— 本机运行模式(不连电脑)调研与设计草案。
- 原型即事实:`mock/proto/` 的行为以能跑通的验证脚本为准,不以文档描述为准。
- `tools.md` / `memory.md` 只做协作辅助,不覆盖正式设计真值。
- `.agents/notes/` 是因果真理源:现状事实不写进笔记,笔记结论也不替代 `docs/`。

## 3. 架构与项目结构

- `app/lib/theme/` —— Flutter 主题层(`dsh_colors.dart` / `dsh_theme.dart`),token 抽自 DSH `ui-theme`,三端落地的唯一颜色/字体来源。
- `mock/proto/` —— **交互基线原型**(唯一可运行的完整形态):
  - `index.html` 全部页面标记;`styles.css` 设计 token 与组件样式;`app.js` 手势/抽屉/sheet/文件页/任务/输入栏;`interactions.js` 输入栏接管(审批/提问/计划);`icons.js` 98 个 DSH 图标(机生成,勿手改)。
  - `tools/` 抽取器与验证脚本;`shots/` 截图产物。
- `docs/` —— 现状事实与设计真值(见 §2)。
- 分层方向:原型内 `interactions.js` 通过注入的 `api` 调用 `app.js`,**不得裸调对方私有符号**(历史事故,见 §6)。
- 模块级约束就近写在该目录的 `AGENTS.md`(现有:`mock/proto/AGENTS.md`、`docs/AGENTS.md`、`.agents/notes/AGENTS.md`),本节不复述。

## 4. 协作文件与决策笔记规则

- 开始任务前,优先读取项目根 `tools.md`、`memory.md` 与 `.agents/notes/AGENTS.md`。
- 只读取当前项目根的协作文件;旧 `memory/archive/` 只按需读当月或最近一个归档,不批量加载历史。
- `tools.md` 记录稳定可复用的命令、路径、模式、坑点;写入前先读;不写单次任务日志。
- `memory.md` 是当前状态快照 + 最近活跃窗口;完整功能/修复闭环后整体覆盖更新,不做流水追加,移除失效项,目标 ≤120 行。
- 非平凡改动(行为 / 架构 / 跨文件契约 / 流程与工具链 / 测试策略 / 落盘格式)必须留下决策笔记,代码与笔记**同批提交**;判定表与四格写法见 `decision-notes` 技能。
- 笔记状态由目录位置决定:`proposed/`、`implemented/`、`rejected/`、`archived/`。严禁创建总索引文件。
- 已经发生的决定不能删:失效的旧笔记结论不改,标注被谁取代后移入 `archived/`;`archived/` 永久冻结。
- 被约束的代码入口留一行注释回指对应笔记。
- `docs/postmortem/` 是唯一允许写事故与血泪史的地方;结论要沉淀成一行回到本文件。

## 5. 验证、入口与关键路径

- 无浏览器验证:`node mock/proto/tools/verify-icons.cjs`;语法检查 `node --check <file>`。
- 通道协议验证(不需要浏览器/手机/公网):`node protocol/verify-fixtures.mjs`(16 条 fixture / 486 项:恢复只有"增量或快照"两种结果)、`node protocol/verify-loopback.mjs`(26 项三角色回环,含中转清空后重启)、`node protocol/verify-vectors.mjs`(33 项跨端密码学向量)。**改 `protocol/` 后三条都必须全绿**;改断言时补一次变异校验(做法见 `tools.md`)。
- 多端边界校验(不需要 Flutter 工程):`node app/tools/verify-platform-boundary.mjs` —— 6 条规则扫 `app/lib` 与 `app/packages`,自带 13 条规则自检(细则见 `tools.md`)。**改 `app/lib/` 或 `app/packages/` 后必须跑。**
- 浏览器验证(独立 headless,不碰日常浏览器):`pwsh -File mock/proto/tools/cdp.ps1 -Port 9400`,然后
  `$env:CDP_URL='http://127.0.0.1:9400'; $env:NO_PROXY='127.0.0.1,localhost'` 再跑对应脚本。
  - `verify-proto.mjs` 布局与交互;`verify-authz.mjs` 授权矩阵 18 项;`verify-picker.mjs` 列表列固定;`verify-settings.mjs` 设置页导航与边界;`verify-tasks.mjs` 对话 dock 与自动化任务页;`measure-composer.mjs` 量尺寸。
  - `shoot*.mjs` 截图到 `mock/proto/shots/`。
  - 也可用 chrome-devtools MCP 直接驱动**已打开**的 `mock/proto/index.html` 做交互式排查(断言口径同 `verify-*.mjs`)。注意它连的是日常浏览器,而上面这条走独立 headless;**门禁以 headless 那组为准**。
- 关键入口:`mock/proto/index.html`(原型唯一入口);`app/lib/theme/dsh_theme.dart`(Flutter 主题入口)。
- 图标机生成:`node mock/proto/tools/extract-dsh-icons.mjs`(DSH 升级后重跑,勿手改产物)。
- 参考源码(只读,勿改):DSH `C:\sudy\github\deepseek-harness`;Agents-Anywhere `C:\sudy\github\Agents-Anywhere`;rikkahub `C:\sudy\github\rikkahub`。

## 6. 项目特定规则

- **DSH 是权威,但手机不是缩小版桌面**:结构与文案优先照 DSH 源码;当 DSH 的桌面形态不适合触屏时(如模型放右侧、统计条位置)允许**有意偏离**,但必须在 `docs/design-and-tech-plan.md` 写明"这是有意偏离 + 原因"。
- **输入区三条硬规则**(方案 §7.2):附件在卡片内部上方;文字独占一行;控制行左组(`＋`/模型/权限)+ 右只有发送。
- **选择类列表**:行 = `[名称 / 其下标签组] [勾位(恒占位)]`;能力**不得**做成与名称同行的第三列(方案 §7.9)。
- **授权路径**:未授权绝不生效、勾选态不跨次残留、"允许一次"≠永久授权(方案 §7.10)。
- **插件**:不做"逐插件页面适配"(架构上不存在通用渲染);只做清单/状态/启停/安装日志 + `volatile` 字段通用表单,其余标注"需在电脑上编辑"(方案 §12)。
- **密钥**:API 密钥值不回传手机,改密钥只发新值(方案 §7.5)。

## 7. 维护原则

- 本文件保持短、小、硬,≤1,950 词;超限先下沉到 `docs/` 再精简,不删约束凑数。
- 近期状态放 `memory.md`,稳定协作知识放 `tools.md`,现状事实放 `docs/`,因果取舍放 `.agents/notes/`。
- 模块级规则就近放子目录 `AGENTS.md`,不往根上堆。
- 解释性长文回到 `docs/`。
