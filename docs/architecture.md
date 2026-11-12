# dsh-mobile 架构

## 全景

项目分三个层面:

1. **交互基线原型**:`mock/proto/` 是移动端交互的**基线**(纯浏览器 JS/CSS/HTML,无构建)。落地端 `app/` 与它同源:改基线要同步改落地端,不允许两边各自漂移。
2. **跨端协议层**:`protocol/` 是手机 ⇄ 中转 ⇄ 电脑侧桥接的契约与可执行规格。`fixtures/` 是规格真身,`reference/` 只是行为基准(**不是可搬运的产品代码**),`vectors/` 是跨端密码学向量。两侧实现(TS 插件 / Dart 手机端)各写一遍,对着同一批 fixtures 跑。
3. **Flutter 落地端**:`app/` 是**产品实现**,七层 —— `core/`(通道客户端、恢复引擎,纯 Dart)、`data/`(DTO 与存储)、`model/`(领域模型)、`wire/`(线上形状的唯一解码层)、`theme/`、`ui/`(逐屏)、`platform/`(各端实现与唯一装配点)。分层判据见 `subsystems/app-channel-client.md` 与 `subsystems/app-platform-boundaries.md`。

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
- 手机端多端边界(iOS / 安卓 / 鸿蒙:核心零平台分支、平台实现只住 `lib/platform/`、可机械判定的边界规则)→ `subsystems/app-platform-boundaries.md`
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

- 新增移动端页面:先判它属于哪个面（见「基线划分」）—— 会话页 / 输入栏相关的**先进原型**再进 Flutter；其余直接以 `docs/` 为基线进 Flutter，**不进原型**。两边都不允许各自发明状态真值。
- 新增电脑侧能力先核对桥接的**实际实现**,再改协议;不能只按 schema 文件或契约文本枚举能力(审批回应的"不支持"结论就是这么过期的)。
- 新增通道能力先改 `protocol/fixtures/`,再改两侧实现;两端共用同一批 fixtures,不允许各自维护一份协议说明。
- 新增平台 = 在 `app/lib/platform/` 加 `<能力>_<端>.dart`(端口在 `<能力>.dart`,兜底是 `<能力>_memory.dart`),并在同一个装配点登记;不得修改 `lib/core` / `lib/data` / `lib/model` / `lib/ui`(由 `app/tools/verify-platform-boundary.mjs` 拦)。
- 新增设置项先在 `settings-porting-notes.md` 逐项给出 DSH 路径、行号、取值来源与处置,再加入页面映射。
- 新增插件支持优先扩展声明式/Schema 能力,不做逐插件原生页面适配。

## 基线划分（一个面只有一条基线）

项目同时存在两个可执行的“真相层”，均有一个面由两边共同描述就会出现两套真值。划分如下：

| 面 | 基线在哪 | 守卫在哪 |
|---|---|---|
| 会话页、输入栏、抽屉、右侧面板、后台任务页的手势与布局 | `mock/proto/` | `verify-proto` / `verify-authz` / `verify-picker` / `verify-tasks` / `verify-drawer` |
| 用量、插件、轨迹、文件预览、设置、配对、扫码 | `docs/` + `app/test/` | `flutter test` |
| 通道协议、密码学、恢复语义 | `protocol/fixtures` + `protocol/vectors` | `verify-fixtures` / `verify-loopback` / `verify-vectors` |

为什么这样划：**近 60 次提交里 `app/` 改了 197 个文件、`mock/proto/` 只碰过 1 个**，而原型只有 694 行、产品 UI 有 2.6 万行。
若继续要求“新页面也进原型”，守住的是“两边都不漂移”这句话本身，而不是它想防的问题——真正的漂移是“产品与 `docs/` 对不上”，而那不是原型能拦的。

三条推论：

1. **原型里有的面**：改基线要同步改落地端（`verify-*.mjs` 的断言就是这份基线）。
2. **原型里没有的面**：基线是 `docs/`。**不要为了“同步”塞进原型**（那是把一个面的真值拆成两处）。
3. **落地端有意偏离原型时**：偏离写进 `docs/`（“有意偏离 + 原因”，见 `design-and-tech-plan.md`），不靠改原型来“对齐”。

取舍与代价见 `.agents/notes/implemented/2026-11-10-baseline-per-surface.md`。

## 结构性约束与守卫

本仓的硬约束都有一条**可机械执行**的守卫。这张表是“哪条约束、破在哪”的总图（命令与项数在 `tools.md`，此处不复述）。

| 约束 | 守卫 | 破了会红的样子 |
|---|---|---|
| 七层依赖方向（`core` 不认平台、UI 不认实现） | `verify-platform-boundary.mjs`（9 条） | 某个文件 import 了错的层 |
| 协议知识只在 `wire/` | `verify-rpc-single-caller.mjs`（零例外） | `client.call<` 漏在 `wire/` 外 |
| 事件载荷字段名只一个读者 | 同上脚本的 `wire-field-single-reader` / `data-no-field-name` | `data/` 里按线上字段名取值 |
| 图标只有一个来源 | `verify-icons.cjs` + `no-material-icons` | 新增 unicode 字形当图标 |
| 工具脚本不许写盘符 | `verify-tool-paths.mjs`（3 条） | 写了个 `D:\…` 字面量 |
| **文件/类不得无声长大** | `verify-size.mjs`（4 条，棘轮） | 给 `AppModel` 多一个方法 / 文件超表内行数 |
| 线上形状不得漂 | `connector/tests/wire-shapes.test.ts` + `app/test/wire_shapes_replay_test.dart` | 连接器改了应答而 App 没跟 |
| 恢复只有“增量或快照”两种结果 | `verify-fixtures.mjs` + connector 的 `flow` 用例 | 出现第三种“看起来补上了” |
| 不得新增宿主没有的边界 | **无机械守卫**（靠 `proposed/2026-10-24-native-rules-audit.md` 的人工审计 + review） | — |

最后一行是故意的：它是**基于语义的判断**（“这条规则删掉，DSH 会不会已经给出答案？”），不是文本模式能判的。
它的代价是每次都可能悄悄回来，所以审计要周期性重跑，而不是当成一次性完成的事。

## 验证入口

不需要浏览器:

- `node protocol/verify-fixtures.mjs`、`node protocol/verify-loopback.mjs`、`node protocol/verify-vectors.mjs`
- `node app/tools/verify-platform-boundary.mjs`
- `node app/tools/verify-size.mjs`
- `node mock/proto/tools/verify-icons.cjs`

需要浏览器(独立 headless,不碰日常浏览器):

```powershell
pwsh -File mock/proto/tools/cdp.ps1 -Port 9400
$env:CDP_URL='http://127.0.0.1:9400'; $env:NO_PROXY='127.0.0.1,localhost'
node mock/proto/tools/verify-proto.mjs
node mock/proto/tools/verify-authz.mjs
```

完整脚本清单、断言条数与截图命令见根 `tools.md`。
