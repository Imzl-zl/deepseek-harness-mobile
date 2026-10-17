# mock/proto 原型规则

本目录是**交互基线原型**,也是本仓当前唯一可运行的完整形态。行为以能跑通的验证脚本为准,不以文档描述为准(见根 `AGENTS.md` §2)。

后续要把这里的行为同步到 `app/`(Flutter 落地端);**不允许两边各自漂移**。

## 硬规则

- 图标一律走 `window.DshIcons`(`icons.js`),用 `data-icon` 绘制;**禁止新增 unicode 字形当图标** —— `verify-icons.cjs` 会拦。
- `icons.js` 由 `tools/extract-dsh-icons.mjs` 机生成,DSH 升级后重跑,**勿手改产物**。
- 改 `styles.css` 后必须确认 `{` 与 `}` 计数相等:历史上手改样式表曾截断规则,截断处之后所有规则静默失效。
- 视觉与文案以 `docs/design-and-tech-plan.md` 为基线;与文档冲突时**先改文档再改代码**。
- 本目录**无构建步骤、无 npm 依赖**;不要引入打包器或 `package.json`。
- 所有交互用 Pointer Events 手写(便于真机触屏复现),不引第三方手势库。

## 文件职责

| 文件 | 职责 |
|---|---|
| `index.html` | 全部页面标记 |
| `styles.css` | 设计 token 与组件样式 |
| `app.js` | 手势 / 抽屉 / sheet / 文件页 / 任务 / 输入栏 |
| `interactions.js` | 输入栏接管(审批 / 提问 / 计划) |
| `icons.js` | 100 个 DSH 图标(机生成,勿手改) |
| `tools/` | 抽取器与验证脚本 |
| `shots/` | 截图产物(不入库,由 `shoot*.mjs` 重新生成) |

## 分层约束

`interactions.js` 通过注入的 `api` 调用 `app.js`,**不得裸调对方私有符号**。

两个文件同页加载,裸调在书写时"看起来"能通,实际是 `ReferenceError`;而且它发生在异步回调与 `setTimeout` 里,不冒泡到页面级错误处理,**静默失败**。事故复盘见 `docs/postmortem/2026-09-30-approval-answer-silently-dropped.md`。

## 层与动效

- **切 sheet 不得"先 `close` 再 `open`"**:异步 popstate 会把刚打开的 sheet 弹掉。`openSheet` 内部复用同一层。
- **全屏页必须挂过渡**:从右滑入的全屏页(`.page--settings` / `.page--tasks`)都要列进 `.motion ...` 那份过渡名单,漏了整页瞬移。
- **从抽屉切全屏页要同步摘掉 drawer 层**:`settings-open` / `tasks-open` 都必须 `D.set(0, true)` + `closeLayer("drawer", true)`;漏了页面会开在没收起的抽屉后面,并留下 `drawer` 幽灵层。
- `.page--side` 必须挂过渡并配 `.side-scrim` 遮罩,否则抽屉"啪一下"且无遮罩。

## CSS 坑点

- **`[hidden]` 会被组件级 `display:flex` 盖掉**:组件级 `display` 规则要配 `[hidden]{display:none!important}`。
- **覆盖 `.btn` 的 `flex` / `min-height` 必须带 `.btn` 前缀**:`.btn` 在样式表里更靠后,同权重下会盖掉前面对 `.xxx-new` 的覆盖(表现是筛选行被挤到换行)。
- **别用 `scrollWidth` 判断文字有没有换行**:换行后并不横向溢出,要数文本节点的 `Range.getClientRects().length`。
- **UI 外壳默认不可选中文本**,消息 / 代码 / diff 单独放开。

## 验证

改本目录后**至少**跑 `node mock/proto/tools/verify-icons.cjs`(不需要浏览器)。动了布局/交互再跑 CDP 组:

```powershell
pwsh -File mock/proto/tools/cdp.ps1 -Port 9400
$env:CDP_URL='http://127.0.0.1:9400'; $env:NO_PROXY='127.0.0.1,localhost'
node mock/proto/tools/verify-proto.mjs      # 布局与交互
node mock/proto/tools/verify-authz.mjs      # 授权矩阵 18 项,必须 0 失败
```

完整的脚本清单、断言条数与截图命令见根 `tools.md`,此处不复述。
