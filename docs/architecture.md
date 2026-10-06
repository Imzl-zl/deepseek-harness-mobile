# dsh-mobile 架构

## 全景

项目分三个层面:

1. **交互基线原型**:`mock/proto/` 是当前唯一完整可运行的移动端交互参考。它用原生 HTML/CSS/JS 模拟聊天主页、左会话抽屉、右侧上下文抽屉、底部 sheet、输入栏接管、文件预览、任务/子代理和设置页。
2. **跨端协议层**:`protocol/` 是手机 ⇄ 中转 ⇄ 电脑侧桥接的契约与可执行规格。`fixtures/` 是规格真身,`reference/` 只是行为基准(**不是可搬运的产品代码**),`vectors/` 是跨端密码学向量。两侧实现(TS 插件 / Dart 手机端)各写一遍,对着同一批 fixtures 跑。
3. **Flutter 落地端**:`app/` 目前只有主题层(`app/lib/theme/`)。通道客户端的 core 分层、多端边界与能力包已设计(见 `subsystems/app-channel-client.md`、`subsystems/app-platform-boundaries.md`),Dart 代码尚未开始。

电脑侧事实来源:

- DSH 源码:`D:\sudy\github\deepseek-harness`。
- AA bridge/connector:`D:\sudy\github\Agents-Anywhere`。
- 本机运行模式调研与 provider 密钥策略见 `standalone-mode-notes.md`。

## 子系统索引

- 会话与移动导航 → `design-and-tech-plan.md` §1、§2、§6、§7.1–§7.4
- 输入栏与 composer takeover → `design-and-tech-plan.md` §7.2、`mock/proto/app.js`、`mock/proto/interactions.js`
- 文件 / 任务 / 子代理上下文抽屉 → `design-and-tech-plan.md` §7.8、`plugin-and-jobs-notes.md` §B
- 设置页与 bridge 边界 → `design-and-tech-plan.md` §7.5、`settings-porting-notes.md`
- 插件管理与插件自定义页面边界 → `design-and-tech-plan.md` §12、`plugin-and-jobs-notes.md` §A、§C
- 远程通道规格(信封、配对与鉴权、端到端加密、修订号与恢复语义、存储边界、推送、DSH 侧数据源适配表)→ `subsystems/remote-channel.md`;评审证据与 DSH 侧行号 → `channel-review-notes.md`
- 电脑侧桥接与中转的落地设计 → `subsystems/connector-and-relay.md`
- 手机端通道客户端设计(core 分层、连接状态机、渲染性能、测试策略)→ `subsystems/app-channel-client.md`
- 手机端多端边界(iOS / 安卓 / 鸿蒙:核心零平台分支、按能力切包、可机械判定的边界规则)→ `subsystems/app-platform-boundaries.md`
- 开工步骤与精确验证命令 → `cookbook/channel-bootstrap.md`
- 本机运行模式 → `design-and-tech-plan.md` §13、`standalone-mode-notes.md`
- 事故与可复用故障规则 → `postmortem/`

## 关键数据流

- 原型入口:`mock/proto/index.html` → `icons.js` / `interactions.js` / `app.js`。
- 手机连接电脑模式:Flutter UI ⇄(WS + 端到端加密)⇄ 哑中转 ⇄(WS)⇄ 电脑侧桥接(DSH 插件)⇄ DSH session/settings/jobs/plugin runtime。修订号由电脑侧分配,中转不存内容、不解析语义。
- 手机本机模式:Flutter UI → 手机安全存储的 provider 凭据 → provider API;不复用电脑端 workspace 权限语义。
- 设置页第一版:手机本地偏好直接落手机;电脑侧设置只在 bridge 能力明确后读写;API key 只走单向写入,不回传值。
- 插件:通用管理面覆盖清单/状态/启停/安装日志;配置只对 Schemastery `volatile` 字段做通用表单;自定义 React 页面显示电脑端编辑/打开边界。

## 扩展点

- 新增移动端页面先进入原型信息架构,再进入 Flutter 页面;原型与 Flutter 不允许各自发明状态真值。
- 新增电脑侧能力先核对桥接的**实际实现**,再改协议;不能只按 schema 文件或契约文本枚举能力(审批回应的"不支持"结论就是这么过期的)。
- 新增通道能力先改 `protocol/fixtures/`,再改两侧实现;两端共用同一批 fixtures,不允许各自维护一份协议说明。
- 新增平台 = 在 `app/packages/` 加能力包实现 + 在 `app/lib/platform/` 注册,不得修改 `lib/core` / `lib/data` / `lib/model` / `lib/ui`(由 `app/tools/verify-platform-boundary.mjs` 拦)。
- 新增设置项先在 `settings-porting-notes.md` 逐项给出 DSH 路径、行号、取值来源与处置,再加入页面映射。
- 新增插件支持优先扩展声明式/Schema 能力,不做逐插件原生页面适配。

## 验证入口

不需要浏览器:

- `node protocol/verify-fixtures.mjs`、`node protocol/verify-loopback.mjs`、`node protocol/verify-vectors.mjs`
- `node app/tools/verify-platform-boundary.mjs`
- `node mock/proto/tools/verify-icons.cjs`

需要浏览器(独立 headless,不碰日常浏览器):

```powershell
pwsh -File mock/proto/tools/cdp.ps1 -Port 9400
$env:CDP_URL='http://127.0.0.1:9400'; $env:NO_PROXY='127.0.0.1,localhost'
node mock/proto/tools/verify-proto.mjs
node mock/proto/tools/verify-authz.mjs
```

完整脚本清单、断言条数与截图命令见根 `tools.md`。
