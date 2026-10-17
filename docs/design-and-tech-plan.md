# DSH Mobile 移动端设计与技术方案

> 手机端控制电脑端 DSH(DeepSeek Harness,web 版 + 桌面版)的跨平台 App。
> 电脑侧装插件转发,任务在电脑本地执行,手机看/操作会话。
> 本文是设计与技术基线;与本文冲突的实现视为需要先改本文再改代码。

---

## 1. 定位与目标

- **手机负责控制,电脑负责执行。** 不是云端远控电脑;会话、任务在电脑本地跑,手机通过插件转发看进度、发消息、审批。
- **通用插件、多用户**(非纯自用)。
- **体验优先**:原生级手感 + 三端(iOS / 安卓 / 鸿蒙)视觉规格一致 + 视觉与 DSH 一模一样。
- **不做**(第一版):Admin、账单、知识库、MCP/Skill 的复杂编辑(与 DEEIX 移动端边界一致,见其 `docs/ARCHITECTURE.md`)。

---

### 渲染策略:是 DSH,但更精致

DSH 桌面的内容渲染偏朴素,移动端要更好看。原则分两层,避免"改到不像 DSH":

- **保持一致(照搬 DSH)**:主题 token(§5)、配色、信息架构、页面结构、术语、状态语义 —— 一眼就是 DSH。
- **可以更精致(借 rikkahub / DEEIX)**:Markdown 排版、代码块(语法高亮/复制/折叠/横滑)、消息气泡与间距、流式打字动效、图片/附件卡、加载骨架、手势与过渡。质感往上提,但只用 DSH 的色板和圆角,不引入异色。

一句话:**视觉基调和骨架跟随 DSH,渲染质感对齐 rikkahub / DEEIX 的水准。**

### 移动端交互与布局规范(不是把桌面缩小)

DSH 桌面是宽屏、鼠标 hover、信息密集。移动端**皮肤跟 DSH,交互壳按手机习惯重构**:

- **触摸目标 ≥ 44×44pt(iOS)/ 48dp(安卓)**:图标按钮、列表行、tab 都要够大点得中。内容字号仍按 DSH(正文 13、可调),但**可点区域独立放大**,不跟着字号缩。
- **拇指热区**:高频操作(发送、新建、审批、切模型)一律**底部锚定**;顶部只放返回/标题/更多。
- **聊天即主页 + 抽屉**(照 rikkahub `ChatPage.kt` 的 `ModalNavigationDrawer`):主屏就是当前会话,左上角 ☰ 开**抽屉**看会话历史/新建/设备/进设置;`新建` 在顶栏图标。这是成熟 AI 聊天 App 的主流做法,比"列表优先 + 底部导航"更顺手;大屏用永久抽屉。
- **底部 sheet 替代 popover / tooltip**:会话统计 / Token / 上下文、模型+权限选择、消息操作、轮次大纲,全部从底部滑出(可拖拽高度)。
- **手势**:列表左滑归档/删除;`对话 ⇄ 轨迹` 左右滑切换;下拉刷新会话列表;消息**长按**出操作菜单(替代桌面 hover)。
- **原生组件**:分段控件、bottom sheet、下拉刷新、SnackBar/Toast、系统级图片查看器(捏合缩放)、键盘感知(输入栏随键盘上移)。
- **安全区**:适配刘海/灵动岛与底部 Home 指示条;输入栏、底部导航吃 safe-area inset,内容不被遮挡。
- **一屏一焦点**:桌面并排的多栏(会话 + 侧栏 + 终端)在手机拆成可切换的独立页,不并排硬塞。
- **反馈与动效**:点击涟漪/高亮、流式打字、骨架屏、过渡,用 Flutter 原生手感,别做出网页感。

一句话:**DSH 决定"长什么样",手机习惯决定"怎么摸"。**

---

## 2. 总体架构 —— 反向连接 + 哑中转(为什么不需要内网穿透)

家用/办公电脑在 NAT 后面,没有公网 IP。让"手机连进电脑"要内网穿透,痛且不安全。正确做法是**两侧都主动连出到中转**:

```text
[手机 App]  ⇄(WS)⇄  [中转 Server(公网)]  ⇄(WS)⇄  [电脑侧桥接]  ⇄  [DSH]
   连出              不存内容、不解析语义            连出          本地执行
```

- **中转是哑转发器**:不存会话内容、不解析语义、不分配修订号,只做配对鉴权、按连接转发、有界重放窗口与推送投递 → 不配路由器、不要公网 IP、不要内网穿透。
- **电脑侧是唯一真值源**:每个会话的修订号由电脑侧分配并落盘;重连只有两种结果——完整增量,或明确要求基线快照,不存在"大概补上了"。
- **载荷端到端加密**(X25519 协商 + AEAD 封箱):中转只读路由元数据,连"这一帧是发消息还是改密钥"都看不到。
- **锁屏/被杀只发敲门式推送**(待审批、待回答、任务终结、轮次失败四类,一律是给用户看的通知、不做静默推送),正确性由"回到前台无条件补课"保证 → 推送丢了也不丢状态。
- 通道契约(信封、配对、恢复语义、存储边界、推送与前台优化)见 `subsystems/remote-channel.md`;取舍与否决方案见 `.agents/notes/proposed/2026-09-30-remote-channel-reverse-ws-e2ee.md`;可行性、优越性、协议待补项与可复现实测见 `channel-review-notes.md`。
- 参考实现是 `Agents-Anywhere`(Client ⇄ Server ⇄ Connector ⇄ DSH,可自托管):**照它的分层思路自研**,并在四处做得更好——后台任务作为一等公民投影、审批按 DSH 真实动作集、设备配对不做账号体系、内容端到端加密且中转不长期存内容。

### 安全底线(公网中转必须做)
- TLS 全程加密;**配对码一次性、5 分钟有效**;身份由电脑侧判定,中转只转发与记账。
- 手机侧设备私钥与刷新令牌存 iOS Keychain / 安卓 Keystore / 鸿蒙密钥库;访问令牌只存内存;WS 升级用一次性 ticket,令牌不进 URL 与日志。
- **设备可吊销**:电脑侧删除设备公钥即失效。DSH 远控权限很高,插件侧要做**操作白名单 + 审批**,默认不放开高危操作。

---

## 3. 技术栈决策:Flutter(含鸿蒙 ohos fork)

| 维度 | 结论 |
|---|---|
| 覆盖三端 | 一套 Dart 代码 → iOS / 安卓 / 鸿蒙。鸿蒙走 CPF-Flutter 维护的 Flutter OHOS fork(`flutter_flutter`,由 OpenHarmony 跨平台框架 PMC 下属 Flutter SIG 主导的开放社区组织)。 |
| 体验 | 自绘引擎(Skia/Impeller),120fps,三端视觉规格一致(渲染后端不同:鸿蒙由 `buildinfo.json5` 控制、模拟器不支持 Vulkan),复杂时间线/甘特/流式动画好控。 |
| 已排除 | RN+RNOH(鸿蒙滞后上游、三方库仅约 205/368 适配)、uni-app(复杂 UI 天花板)、纯原生三端(3 套代码维护不起)、WebView 薄壳(手感将就)。 |
| 代价 | DSH 的 Markdown/代码高亮/时间线/甘特要用 Dart 重写。**用第 5 节抽出的真实 token + 组件规格**保证"重写=换语言,不是重设计"。 |

**鸿蒙现实**:纯血鸿蒙(HarmonyOS NEXT/5)不兼容安卓 APK,是独立 ArkTS/ArkUI 栈 → 原生安卓覆盖不了,必须跨平台框架。SDK 在 **CPF-Flutter**(AtomGit,由 Flutter SIG 主导;旧组织 `openharmony-tpc` / `openharmony-sig` / `OpenHarmony-Flutter` 已整体迁入并停更),稳定版本按 tag 发布,当前最新稳定线基于上游 **3.41.9**(`3.41.10-ohos-1.0.1` / `3.41.9+ohos-1.0.2`),其规划滞后 4 个月(3.35 线为 7 个月)→ **锁 3.41 线**;三方库选型以 CPF-Flutter 的适配清单为闸门,详见 `subsystems/remote-channel.md`。**注意 tag 有两种命名格式并存**(`3.41.10-ohos-1.0.1` 与 `3.41.9+ohos-1.0.2` 是同一条线),写依赖时按实际存在的 tag 为准。另外 **Dart build hooks(native assets)在 OHOS 上不可用**,需要原生库时走 `plugin_ffi` + `externalNativeOptions` 或预编译 so。

---

## 4. 工程结构

```text
dsh-mobile/
├── app/                      Flutter 应用(唯一 UI 与业务)
│   ├── lib/
│   │   ├── core/             纯 Dart 零平台依赖:通道客户端、流帧解析、恢复引擎、消息 reducer
│   │   ├── data/             DTO / 协议编解码(对齐 protocol/ fixtures)、存储与密钥的注入接口
│   │   ├── model/            共享领域模型:session / device / timeline item / usage / context
│   │   ├── theme/            ★ 从 DSH 抽出的 DshTheme(第 5 节)
│   │   ├── ui/               screens + widgets(逐屏,第 7 节,不含平台分支)
│   │   ├── platform/         ★ 唯一装配点:选择各能力实现
│   │   └── main.dart
│   ├── packages/             ★ 按能力切包:secure_store / push / keepalive,各含接口 + 各端实现
│   ├── ios/ android/ ohos/   壳工程;各端原生代码只住在这里
│   └── tools/                多端边界校验脚本
├── protocol/                 通道规格唯一源:信封定义 + fixtures + 向量 + 校验脚本(两侧共用)
├── connector/                电脑侧:DSH 插件(薄适配层,自己持有出站长连接)
├── relay/                    中转服务:配对、转发、有界重放窗口、推送投递
└── docs/                     本文档、子系统规范与 cookbook
```

通道四件的职责与契约见 `subsystems/remote-channel.md`;多端边界(核心零平台分支、按能力切包、边界规则)见 `subsystems/app-platform-boundaries.md`;电脑侧与中转的落地设计见 `subsystems/connector-and-relay.md`,手机端客户端见 `subsystems/app-channel-client.md`,开工步骤与验证命令见 `cookbook/channel-bootstrap.md`。

分层依赖只向下:`ui → core/model`,`data → model`,`core` 零平台依赖(I/O 注入,可在纯 Dart 单测)。参考 DEEIX 的 `packages/core` 与 AA 的 `android/ARCHITECTURE.md` 分层。

### 鸿蒙接入要点
- 用 Flutter OHOS fork 的 SDK + DevEco Studio;`ohos/` 是 ArkTS 宿主工程,加载 Flutter engine。
- CI 里鸿蒙目标单独一条流水线(与 iOS/安卓的 `flutter build` 分开)。
- 三方库风险:选 Flutter 插件时优先挑纯 Dart 或已适配 OHOS 的;涉及原生能力(推送、安全存储、相机)的插件要确认鸿蒙实现或自己写 ohos platform channel。

---

## 5. 设计系统(从 DSH 源码抽取的真实 token → Flutter)

来源:`deepseek-harness/packages/client/ui-theme/src/styles/design-platform.css` 的 `body[data-ds-dark-theme]` 等。以下为**深色**取值(DSH 默认深色)。

### 5.1 颜色

| 用途 | DSH alias | 值(hex) |
|---|---|---|
| 根背景 | `bg-base` | `#151517` |
| 侧栏 | `sidebar-fill` | `#1B1B1C` |
| 卡片/面板/主表面 | `bg-layer-1` | `#232324` |
| 抬升表面 | `bg-layer-2` | `#2C2C2E` |
| 最高表面/中性 chip | `bg-layer-3` / `module` | `#353638` |
| 浮层/菜单(半透明) | `menu-surface` | `rgba(67,69,74,0.45)`,不透明近似 `#43454A` |
| 分隔线 | `border-l1/l2/l3/l4` | 白 6% / 12% / 16% / 20%,常用 `0.5px` 发丝线 |
| 主文字 | `label-primary` | `#F9FAFB` |
| 次文字 | `label-secondary` | `#CFD3D6` |
| 弱文字 | `label-tertiary` | `#ADB2B8` |
| 说明文字 | `label-caption` | `#81858C` |
| 强调蓝(accent) | `brand-primary-new` | `#5686FE` |
| 业务蓝/焦点/链接 | `business-primary` / `link` | `#7AAAFF` |
| 主按钮填充(深色近白) | `brand-primary` | `#F9FAFB`(文字用 `#0F1115`) |
| hover / active 叠加 | — | 白 8% / 白 14% |

### 5.2 角色 / 徽标色(时间线、轨迹)

来源:`ui-trajectory/.../TrajectoryTable.module.css`。

| 角色 | 文字 | 底色 |
|---|---|---|
| 上下文 context | 绿 `#22C55E`(与次文字 mix) | 深绿 `#233C2C` |
| 助手 assistant | 紫(蓝 `#5686FE` 60% mix 红 `#F25A5A`) | 该紫 @15% 叠在 `#232324` 上 |
| 工具 tool | 琥珀 `#DD8629` | 深琥珀 `#27241F` |
| 错误 error | 红 `#F25A5A` | 红 @12% 叠在 `#232324` |
| 系统/中性 | 次文字 `#CFD3D6` | `#353638` |

> 助手紫和 message 解码色在 DSH 里是 CSS `color-mix()` 运行时算的;Flutter 里用 `Color.lerp(蓝, 红, 0.4)` 近似,或直接固化成一个紫常量。

### 5.3 甘特 / 时间线条(`data-timeline-span`)

来源:`ui-trajectory/.../TrajectoryTimeline.module.css`。

| span | 填充 |
|---|---|
| user 输入 | `#7AAAFF` |
| context 上下文 | 绿 mix `#22C55E` |
| message 助手(TTFT→解码 渐变) | 紫;TTFT 段更浅(紫 54% mix `#2C2C2E`),左→右渐变 |
| tool / subtool 工具 | 琥珀 `#DD8629` |
| 出错 | 红 `#F25A5A` |

### 5.4 上下文用量环 / 分段(ContextMeter)

来源:`ui-conversation/.../ContextMeter.module.css`。SVG 环 14px viewBox,r=5.5,2px stroke。分段条 4px。

| 分段 | 色 |
|---|---|
| 系统提示词 | `#ADB2B8` |
| 工具定义 | 紫 `#A78BFA`(字面量) |
| 对话消息 | 蓝 `#4D93F8` |

### 5.5 圆角 / 字体 / 动效

- 圆角:`xs 4 / sm 8 / md 12 / lg 16 / xl 20 / panel 28`;全圆胶囊 999。
- 字号(weight size/line):body 默认 **13/20**;说明 11–12;标题 20/28、24/32;正文内容可缩放,默认 14。
- 字体:Sans 含 `PingFang SC / Microsoft YaHei`;**等宽(代码/工具参数)**:`SF Mono / JetBrains Mono / Fira Code / Consolas`(故意不落 `monospace`)。
- 动效:`cubic-bezier(0.4,0,0.2,1)`,时长 0.1 / 0.2 / 0.3s。SegmentedControl 指示器 160ms 滑动。
- **缺口**:阴影 elevation token(soft/prominent)DSH 引用上游 `deepsuite`,本仓库没有 → 需从运行态量或找设计平台要;暂用 Material 轻阴影占位并标 TODO。

### 5.6 diff 配色(代码变更,深色)

来源:`ui-theme/.../design-platform.css` 暗色块(L360–367) + `ui-primitives/DiffBlock`、`ui-deliverables/FileDiff`。

| 用途 | 值 |
|---|---|
| 内联 diff 增行底(code-diff-added) | 绿 `#22C55E` @12% |
| 内联 diff 删行底(code-diff-deleted) | 红 `#F25A5A` @12% |
| 文件 diff 增行:底 / 行号槽 / 标记 | `#1F3124` / `#132016` / `#41C977` |
| 文件 diff 删行:底 / 行号槽 / 标记 | `#3C1F1B` / `#28130E` / `#FA423E` |
| 工具行 +N/−M 统计 | 增=绿标记,删=红标记 |

### 5.7 Flutter 落地

**落地代码即真值,本节不抄第二份**:色板在 `app/lib/theme/dsh_colors.dart`(`DshColors`),
圆角 / 排版 / 等宽栈在 `app/lib/theme/dsh_theme.dart`(`DshRadius` / `DshTheme` / `dshMonoFallback`)。
两者按 §5.1–§5.6 的 token 落地,各有 `design-platform.css` 的来源注释。

**改色板改 Dart 文件,不要改本文档** —— 按 `docs/AGENTS.md`「严禁人肉手抄生成物」,
本节只留指针,不复制代码(副本必然与代码漂移)。

---

## 6. 信息架构(聊天即主页 + 抽屉,照 rikkahub)

不是"列表优先 + 底部导航",而是成熟 AI 聊天 App 的主流结构(rikkahub `ChatPage.kt` 用 `ModalNavigationDrawer`):

- **主屏 = 当前会话**(聊天页)。顶栏:**☰ 左抽屉 / 标题 / ● 连接状态点 / ⊕ 新建**。两个抽屉**都还能从边跟手拖出**:左缘 `drawer`、右缘 `endDrawer`(`Scaffold.drawerEdgeDragWidth: 32`);右缘另有一条 4×40 的**棒棒**当"这侧能划"的标识,**右抽屉开着时它消失**。与**系统返回手势**的冲突用官方 `View.setSystemGestureExclusionRects`(API 29+)解决 —— 只排除左右各 32×192dp 的**上半屏**边带(`platform/gesture_exclusion.dart`),下半屏整条留给系统。
- **左侧抽屉** = 会话历史(搜索/切换/归档/删除)+ 新建 + 设备与中转连接状态 + 进入 设置/文件/终端。大屏(横屏/平板)用**永久抽屉**常驻左侧。
- **归档面**(2026-10-16 接上 `workspace.archive` / `unarchive` + 抽屉底栏「归档」):归档过的会话**默认不列**(照 Web 的默认过滤档,`ui-workspace/src/client/tree.ts:247-248`);它们在底栏「归档」那张列表里,行上只有「取消归档」——已归档的**不能直接打开**(DSH 同一条:`toast.archivedNotOpenable`)。左滑归档一个**还在跑**的会话时宿主会拒(`workspace/session-active`),界面弹「停止并归档」(照 Web 的门,`ui-workspace/src/client/index.ts:190-208`)。
- 文件 / 终端 / 设置 是从抽屉进入的**独立页**(NavHost 路由),不并排硬塞。
- 第一版:会话(聊天)+ 抽屉(历史/新建/连接)+ 设置;文件/终端按 bridge 能力再上。

---

## 7. 逐屏设计

### 7.1 会话列表(首页)
```
┌──────────────────────────┐
│ ☰  会话           ⊕ 新建 │
│ [活跃] [归档] [设备]      │  分段(AA: Active/Archived/Devices)
│ 🖥 我的电脑 · 已连接 🟢   │  中转连接状态条(离线要显眼)
│ ● 会话标题                │
│   claude-opus · 3分钟前   │
│   1轮 · 516 tok/s     ›  │  卡片带迷你指标
└──────────────────────────┘
```

### 7.2 会话详情 · 对话
```
┌──────────────────────────┐
│ 标题(≤220,14px,超长省略) ● ⊕ │  顶栏三件:标题 / ● 连接状态点 / ⊕ 新会话(☰ 在最左)
│ [对话]   轨迹            │  顶部分段(对应 conversation.view: chat/trajectory)
│  用户气泡(右)            │
│  助手:Markdown + 代码块  │  复用 DSH 渲染规格
│  ▸ 工具 glob …(折叠卡)   │  工具调用默认折叠
│──────────────────────────│
│ ┌──────────────────────┐ │
│ │ [附件轨(有附件才出现)] │ │  ★ 附件在输入卡片**内部**上方
│ │ 输入消息…             │ │  ★ 文字独占一行
│ │ ＋ 模型·等级 权限   ↑ │ │  ★ 左一组 / 右只有发送(手机主流,偏离桌面)
│ └──────────────────────┘ │
│ ⏱1轮·3步 🗄302K ◔3%     │  dock:统计在输入卡片**下面**(DSH InputBar.tsx:499),点弹 sheet(7.4)
└──────────────────────────┘
```

**输入区的三条硬规则**(踩过坑,写死):

1. **附件在卡片内部上方**,不是卡片外单独一行 —— 卡片外会被状态行和输入框夹住,视觉上像"被顶上去的一块"。
2. **文字独占一行**,`＋` 和发送键**不进文字行** —— 否则占位符被迫折行、模型名被截成 `claude-...`。
3. **控制行按手机主流排:左边一组(`＋` / 模型·等级 / 权限图标 / 发送模式图标),右边只有发送键。**
   - **这是有意偏离 DSH 桌面结构**:桌面 `InputBar` 把模型放在 `.trailing`(右侧),和发送键一组;手机上主流是左侧集中、右侧单发送,所以不照抄。
   - 模型 chip 可压缩(名字长了省略号,上限 62%),权限与发送模式各是 34px 恒宽图标 —— 保证**长模型名不会挤走这两个图标或发送键**(窄屏 360px 有用例钉不溢出)。
   - 权限名字与说明进 aria-label/title;**完全权限 / Auto review 用告警色**(`is-warn`)一眼看出当前是危险档。
   - 后台任务不常驻输入栏,只看顶栏下方的计数 chip 行(§7.8)。

**发送模式图标**(2026-10-13 补的第四个控件):DSH 原生就有"繁忙时的发送行为"二选一 —— 排队发送 / 插话发送(`packages/client/ui-conversation/src/client/locales.ts:73-76`,存 Host,决定调 `session.startTurn` 还是 `session.steer`)。我们这边一个方法带 `mode` 参数(`connector/src/handlers.ts` 的 `session.prompt` 收 `'queue'|'steer'`),所以**不扩方法面,照搬二选一**。**放进行控区而不是(还没做的)设置页**:它只在会话正在跑轮次时才有区别,是发送当下的选择;插话那一项在会话没在跑时**禁用**(DSH 文案"仅运行中可插话发送",`locales.ts:365`),不是"点了再报错"。偏好落 `meta` 表(`AppModel.kSendModeKey`),重启后还是用户选的那个。

输入框占位符用 DSH 原文:`发消息或创建任务, / 调用指令, @ 文件或对话`(短屏由 CSS 自然折行,不手动截断)。

**排队条与停止键**(2026-10-17 落地,照 DSH Web 的 `conversation.input.dock` 槽):

- 会话正在跑时发出去的消息排进下一个轮次,输入卡片**上方**一条排队条列出来
  (`{n} 条排队消息` 计数头,多条时折叠),每项可**编辑 / 删除 / 插话**。
  队列读 `inbox` 投影的 `next-turn` 段,三个动作走 `session.updateQueue`
  (与 Web 排队 dock 同一个 DSH 方法);插话仅运行中可点(DSH 文案"仅运行中可插话发送"),
  编辑只对纯文本项可点(DSH 的 `updateQueue` 编辑只收纯文本)。
- **主键在运行中且没有草稿时是"停止"**(照 Web `InputBar.tsx:323` 的 `primaryStops`),
  走 `session.cancel`("取消当前轮次但保留待处理收件箱");有草稿时主键仍是发送,
  按当前发送模式排队/插进去。停止键**不受"空草稿"门限**(那会儿门是"有没有停止出口")。

**思考过程 / 附件 / 工具明细 / 插话标**(2026-10-17 补齐,形状照真实会话日志):

- 助手消息的 `{type:'reasoning'}` 块渲染成可折叠的「思考过程」(默认收起);
- 用户消息的图片/文件块**计数显示**(读附件要 `session/attachment`,本期未接);
- 工具卡展开区显示**结果输出预览**;`metadata.diffs` hunks 折成 +N/−M 小计;
- 轮次跑到一半插进去的用户消息带「插话」标(判据逐字移植 DSH `SteeringHistory`)。

**动效**(容易漏,记在这):右抽屉是"抽屉",必须有位移+遮罩过渡 —— 过渡挂在 `.page--side`(`transform/opacity 0.3s cubic-bezier(.4,0,.2,1)`),背后压一层 `.side-scrim`(点它关闭);抽屉内切换面板用轻微横向淡入;输入栏接管卡从下往上浮入。**只做位移不做遮罩、或忘了挂过渡,都会变成"啪一下"**。

### 7.9 选择类列表的行结构(别自己发明第三列)

模型 / 推理等级 / 任何单选列表,行结构照主流(核对过两个来源):

| 来源 | 行的构成 |
|---|---|
| DSH `ModelSelect.tsx:587-594` | `[名称(占满)] [勾位]` —— **能力项根本不渲染**,没有第三列 |
| rikkahub `ModelList.kt:742-805` | `[图标] [名称 + 其下标签组] [tail(勾)]` —— **能力标签在名称下面第二行**,用 `FlowRow` 排 `ModelTypeTag`/`ModelModalityTag`/`ModelAbilityTag` |

**规则**:`[名称 / 其下标签组] [勾位(恒占位)]`。

- 能力**不要**做成"和名称同一行的第三列" —— 一旦同行,列宽互相牵制:勾一出现(或能力文字长短不一)就把邻列顶走。这正是"选中哪个,`图片/纯文本` 那列就跟着挪"的成因。
- 标签放名称下方,长短不一也不影响其它列;勾位 `flex: 0 0 16px` 恒占位(照 DSH `.check { flex: 0 0 14px }`),**不要"选中才渲染勾"**。
- 验证:`mock/proto/tools/verify-picker.mjs` 断言"切换选中前后 `nameRight`/`ckLeft` 不变 + 标签确实在第二行"。

### 7.10 授权边界(必须按"未授权 → 绝不生效"验收)

权限相关的路径不能只靠肉眼点一遍,已写成可重跑的验证脚本 `mock/proto/tools/verify-authz.mjs`(18 项),要求全绿:

| 场景 | 期望 |
|---|---|
| 打开风险门但**不勾**"我已了解风险"就点启用 | 权限不变、门仍开着、返回栈不被误关 |
| 勾选后点**取消** | 权限不变 |
| 关掉后**重开**风险门 | 勾选态**不残留**,点启用仍无效 |
| 勾选 + 启用 | 才切到 `danger-full-access`,图标转告警色 |
| 已是完全权限时 | 审批**不入队**(这是"已授权"的结果,不是绕过) |
| 回到安全档 | 越权调用**重新入队**等审批 |
| 点"拒绝" | 队列清空 + 产生回执节点 |
| 点"允许一次" | **只对这一次**;下一次仍重新要授权 |
| 提问未回答 | 队列不减;放弃整组问题后才出队 |

**踩过的坑**:`interactions.js` 里曾裸调 `app.js` 作用域内的 `haptic()`,在异步回答回调里抛 `ReferenceError`,导致"拒绝/允许一次"点了不推进队列、也不出回执 —— 表面像权限生效了。**跨模块只走注入的 `api`,不要裸调对方的私有符号**。

**sheet 切 sheet 的返回栈约束**(踩过,安全相关):`openSheet` 内部**复用同一个 sheet 层**(`topLayer().kind === 'sheet'` 时不压新栈),`perm-set → 风险确认门` 这类"关一个 sheet 立刻开另一个"的路径**不要先 `closeSheet()`** —— `closeSheet` 会 `history.back()`,与 `openSheet` 的 `pushState` 交错后,晚到的 popstate 会按"层数自愈"把**刚打开的风险门**弹掉(等于确认门永远打不开)。只换 DOM 不压栈,是最稳的做法。

### 7.3 会话详情 · 轨迹
```
┌──────────────────────────┐
│  对话   [轨迹]           │
│ [时长][轮次][调用]   🔍  │  子分段(toolbar: duration/turns/calls),32px
│ 输入 ▓▓▓░░               │ ┐ 迷你甘特(横滑),色见 5.3
│ 模型 ░░░▓▓▓░             │ ┤ TTFT→解码渐变
│ 工具 ░░░░░▓▓▓  →         │ ┘
│ ●─上下文  Current runt…  │ ┐ 竖向 ledger,角色色见 5.2
│ ●─助手   我先快速看…     │ ┤
│ ●─工具   glob → 结果  ›  │ ┘ 点开详情
└──────────────────────────┘
```
桌面甘特是宽横条,手机唯一必须"改造"的地方 → 迷你横滑甘特,不 1:1 照搬。

### 7.4 状态 chip → 三个底部 sheet(照搬 DSH 三浮层)
```
⏱ 会话统计            🗄 Token 用量           ◔ 上下文已用 34%
模型用时  llmTime      缓存命中 cacheHit       ▓▓░░ ~32.6K/1M
工具用时  toolTime     未缓存输入 input        系统提示词(灰)
首token TTFT ttft      缓存读取 cacheRead      工具定义(紫)
输出速度 TPS speed     缓存写入/输出 output    对话消息(蓝)
```
桌面 popover → 手机 bottom sheet,内容与 DSH 一致(源:`StatsPills` / `TurnUsagePanel` / `ContextMeter`)。

**数值全部来自投影,哪项没有数据就不摆那一行**(与 Web 的 `stats.llmMs > 0 && …` 同一个门)——
2026-10-17 之前这三个 sheet 是写死的五个数(`12.4 / 3.8 / 420 / 516 / 1 · 3`),与电脑侧毫无关系。
文案与 Web 逐字一致:用量 pill 是 `{total} tok · 缓存命中 {percent}%`
(`locale.ts:78` 的 `stats.cacheHit`;合计 = `billedInput + output`,`StatsPills.tsx:295`);
命中率用 Web 的 `formatCacheHitPercent`(**部分命中绝不四舍五入成 100**,补小数位直到诚实)。
布局是 `Wrap` 不是 `Row`:三项宽度都随数字变(四位数 token、三位数百分比),`Row` 超屏时会把
末项**整块裁掉**(release 里没有溢出条纹,只是看不见——真机"上下文百分比不显示"正是这么来的)。
上下文 chip 带 14px 小环(照 `ContextMeter.tsx:119-129`)。`简洁` 档(性能与用量偏好)只留
速率与缓存命中两个读数(Web 的 `usePerformanceUsage === 'compact'`)。

### 7.5 设置 / 模型 / 插件

**逐项清单见 `docs/settings-porting-notes.md`**(42 项,每项带 DSH 源码 `路径:行号`、控件形态、取值来源、处置与理由)。本节只定原则与边界。

**处置分四档**:搬(19)/ 只读(2)/ 不做(6)/ 必须分叉(15)。

**一、DSH 的设置面是六个平面,不是一个页面**

`settings.section` 只有五项:`account`(-10,仅已登录时注册)/ `general`(0)/ `models`(10)/ `plugins`(15)/ `agent-presets`(20)。**子智能体 / Agent 循环 / 终端 / 网页搜索不在设置页里** —— 它们注册在侧边栏 Plugins 面板的 `plugins.item` 上。插件安装/启停/卸载同样在侧边栏面板(`PANEL_ID='plugins'`),而设置页里的"内置插件"只是个只读清单外壳。手机端按这六个平面分别落页,不压成一页。

**二、纯 UI 偏好:有意偏离 DSH,改存手机本地**

外观 / 语言 / 字号 / 工作步骤展示 / 性能与用量 / 网页链接打开方式 / 繁忙时发送行为 —— 在 DSH 里这些**全部存电脑**(Host user-settings 文档),只有快捷键是本地。手机端把这七项改存**手机本地**,理由:它们只影响这台手机的呈现,下发到电脑既无意义也会和电脑上的设置互相覆盖。这是**有意偏离**,不是漏做。

**三、模型与密钥(必须分叉)**

连电脑模式下模型目录来自电脑;本机运行模式下手机自持(见 §13)。密钥按下面四条,由 DSH 源码结构强制:

- 读半侧**结构上装不下密钥值**:`CredentialInfo` 只有 `configured`/`source`/`writable`,注释写明没有任何字段能承载值。
- 写半侧**单向**:`credentials.set/unset` 有写无读,值只朝一个方向过线。
- 因此手机**能加/改/删密钥,但拿不到密钥值**;改密钥只发新值(经中转端到端加密)。
- bridge 侧照抄 DSH 既有方法名 `credentials.describe/set/unset` 与 `settings.describe/update/replace/mutate` 即可。

**四、一个决定性约束:DSH 有意关闭了"非本机改设置"**

DSH 客户端对**非 loopback** 的浏览器把持久化降级为 `memory`,该模式下**所有写操作被直接拒绝**,表单永久 `unavailable`。也就是说"从手机改电脑设置"在 DSH 当前设计里是**被有意关掉的路径**,不是漏做的接口。我们的 bridge 是 DSH 插件(有完整 ctx),可以绕开这一层直接调 `ctx.settings`,但必须知道:这不是"补个 RPC",而是**扩展一个 DSH 明确设了边界的面**,要按 `settings-write-path-integrity` / `config-boundaries` 的约束做,并接受 DSH 升级时被影响的可能。

**五、配置状态有四种,不是"只读"两种**

`readOnly`(本部署只读)/ `unavailable`(该插件当前未加载)/ `overridden` + 重置(已覆盖可恢复默认)/ `saveFailed`(保存失败)。手机端四态都要表达,尤其 `unavailable` —— 插件没加载是常见情况,不能显示成空表单。

**六、bridge 现状与工作量**

- **已有**:`settings-controller` 已实现完整 `settings.describe/update/replace/mutate` + `credentials.describe/set/unset`,**读半侧已按 secret 脱敏**。bridge 的主要工作是**转发**既有 Remote 方法,不是从零设计协议。
- **落点**:`dsh-bridge/src/bridge-service.ts` 的 `static inject` 加 `settings` / `credentials`,并同步扩写路径白名单。
- **注意契约与实现的落差**:`contracts/dsh-bridge/1.0/schemas/request.schema.json` 列了 `catalog.listAgentPresets`、`runtime.sync.*`,但当前 `dsh-bridge` 的 switch **未实现**(只在 `dsh-bridge-next`)。**别按契约枚举估工作量**,按实际要用的那份实现估。
- `runtime.getConfig` 返回的是 **bridge 插件自身配置**,不是 DSH 用户设置,别误用。
- 另有两条已确认落地:`session.steer`(插话)与 `session.startTurn`(排队)**都已实现** → "繁忙时发送行为"无需扩 bridge。

**第一版设置页只做 5 组**:通用(含权限与 Session Log,视模式决定是否下发)、模型、内置插件、Agent 预设、关于/连接。逐组形态见下方"已落地形态"。

**落地端实际落了四组**(2026-10-17):通用(工作步骤展示 / 性能与用量 / 繁忙时发送,三项全部**落手机本地**,是有意偏离)、模型(只读 + 拉取失败的 provider)、连接方式、关于与连接(App 版本 + 连接状态)。**账号 / 内置插件 / Agent 预设不进本版** —— 三者都要先扩连接器方法面(账号状态、插件清单、预设目录今天都没有查询方法),摆一行点下去只弹"还没做"的假入口比没有这一行更糟。判据 = **这一行点了真的有作用**。取舍见 `.agents/notes/implemented/2026-10-17-settings-page-v1-four-groups.md`。

**导航顺序按 DSH `settings.section` 排序**:账号与余额(仅已登录时,order -10) → 通用设置(0) → 模型(10) → 内置插件(15) → Agent 预设(20)。手机额外的「关于与连接」在末尾;插件管理与自动化任务属于独立主面板,不混入设置组。依据:`packages/client/ui-settings-account/src/client/index.ts:289-296`、`ui-settings-general/src/client/index.ts:231-238`、`ui-settings-models/src/client/index.ts:138-148`、`ui-settings-plugins/src/client/index.ts:76-83`、`ui-agent-preset/src/client/index.ts:223-226`、`ui-schedule/src/client/index.ts:64-65`。

**目标、任务清单和自动化任务是三种不同的会话能力**:

- 目标:DSH `ui-goal/src/client/GoalBar.tsx:1-8,138-176` 挂在 `conversation.input.dock`,展示当前目标与阶段,提供暂停/恢复、内联编辑、清除;新建走 `/goal`,不在条上创建。变更使用 `ctx.remote.goals.edit/pause/resume/clear`(`ui-goal/src/client/index.ts:121-140`),必须带当前 id+revision 做 CAS。手机原型只模拟动作并标示演示,不把本地状态说成电脑已变更。
- 任务清单:DSH `ui-conversation/src/client/skeleton/TodoPanel.tsx:65-108` 同样挂在输入区 dock,默认收起,点击标题展开;列表来自 `useProjection('todos')`,状态仅 pending/in_progress/completed。它是**只读进度**而非「自动化任务」,不能给每项虚构停止/删除按钮。
- 自动化任务:DSH `ui-schedule/src/client/TaskManagerPage.tsx:99-211` 是独立主面板(schedules),有全部/已开启/已结束、搜索、详情;`TaskDetail.tsx:761-847,850-863` 允许编辑规则与确认删除,删除会停止后续触发并删除记录,保留原会话(`task-manager-locales.ts:269-278`)。不能把「删除」标成「暂停」;任务结束后只读。当前 AA `dsh-bridge/src/bridge-service.ts` 与 `dsh-bridge-next/src/host/dsh-runtime/router.ts` 未找到 goals/schedule/todos 方法,这些远端动作须补桥接,原型不得假装已远程提交。

**移动端页面形态已在 `mock/proto` 落地**:

- 设置首页 = 连接卡 + 六组入口(账号与余额 / 通用设置 / 模型与服务商 / 内置插件 / Agent 预设 / 关于与连接),不平铺 42 项。
- 通用二级页 = 权限 / 显示 / 输入与性能 / 日志四组,行序照 DSH `settings.general.item` 的 order(逐行顺序见 `settings-porting-notes.md` §33,不在此复抄)。本地偏好用开关/值 chip,并明确"不覆盖电脑 DSH 同名偏好"。
- 权限是通用设置里的一组,不是顶层设置组:「新会话默认权限」(候选不含 Auto review)与「当前会话权限」是两个设置项,前者改动仍需风险确认门;当前会话档复用输入栏盾牌的访问模式 sheet,风险门不复制第二套。依据 `ui-permission-presets/src/client/index.ts:159-165,167-174`。
- 模型 / 内置插件 / Agent 预设 / 关于与连接四个二级页:模型只读展示当前模型与 provider(密钥只显示"已设置/不回传",添加 provider 标"需 bridge");插件为只读清单 + 运行中/unavailable,自定义页面标"电脑端编辑";预设列表 + 当前默认,配置只读;关于页给连接状态、版本(手机 App;电脑端 DSH 版本需 bridge)与配置文件入口。
- 自动化任务页 = 独立主面板,入口在左会话抽屉底栏(DSH 侧栏面板的对应位):全部/已开启/已结束筛选 + 搜索 + 行内频率与下次计划时间;详情做规则(名称/内容)与删除确认,已结束任务整块只读;不做时间规则编辑(cron 与时区选择器)与任务运行记录(`schedule.records` 未进 bridge)。依据 `ui-schedule/src/client/TaskManagerPage.tsx:114-203`、`ui-schedule/src/client/TaskDetail.tsx:758-863`。
- **有意偏离(2026-10-16)**:落地端(`app/`)的抽屉底栏只有 **文件 / 归档 / 设置** 三项 ——「演示」「自动化」已删。理由:自动化所属的 `schedule.*` 是范围决定里的 C 类(不上手机),留着只能给一句"还没做";演示数据对"已配对"这个主要状态没用(示例会话混进真实列表)。原型(`mock/proto`)保留五项与完整的自动化任务演示页 —— 原型是 IA 基线,展示 DSH 侧栏的完整形态,`verify-tasks.mjs` 的 53 项断言依赖它。取舍见 `.agents/notes/implemented/2026-10-16-drawer-foot-drops-demo-and-automation.md`。

**不进第一版**:快捷键(无物理键盘,且录键保护是桌面原生能力)、子智能体 / Agent 循环 / 终端 / 网页搜索(属侧边栏插件面板,且需先扩 bridge)、桌面更新、预览版说明、首次引导。

**关于"从手机装插件"**:装插件的信任判断由用户自己做,与直接在电脑上装是同一个决定 —— 中转只把命令送过去,不改变这件事,**不需要**为插件安装单独加二次审批。要守的是**通道本身**(仅配对设备 + 端到端加密 + 设备可吊销)。唯一例外:**安装脚本批准**(`approvedBuilds` 会执行任意包脚本)必须保留显式确认,它是插件安装里唯一能执行代码的权限。

---

### 7.6 富内容渲染(消息 / 工具结果里的 diff、预览等)

DSH 会话里不止文字,还有这些内容类型,移动端都要还原(括号=源包):

- **内联 diff 卡**(`ui-primitives/DiffBlock`):工具编辑结果里的 +/− 变更,增行绿底、删行红底(色见 5.6)。手机等宽字体、长行可横滑。
- **文件 diff / 审查视图**(`ui-deliverables/FileDiff`):行号 + hunk 头 + 行号槽标记;支持 unified 与 split(`data-diff-side`)。**手机默认 unified**(split 太宽),横屏/宽屏可切 split。状态要处理:loading / missing / binary(二进制) / oversized(过大) / created(新建) / deleted(删除) / unchanged(无变更) / coarse(粗粒度);超长按 `MAX_RENDERED_LINES` 截断,提示"只显示前 N 行"。
- **变更文件列表 + 审查 tab**(`ui-deliverables` ChangedFiles/ReviewTab):列出改了哪些文件 + 每个 +N/−M。桌面 hover 预览 → 手机改成点击进入 diff 页。
- **工具行 diff 统计**(`ui-tool` ToolRow):工具行右侧 +N/−M 小计,增绿删红。
- **图片**(`ui-attachment` MessageImage):消息内缩略图(多图 64px 方块、单图按比例),点开**全屏 lightbox 原图预览**(手机加双指缩放 / 滑动切换);草稿附件在输入区也有预览。
- **交付物预览**(`ui-deliverables` PresentedFileCard):docx/pdf/表格等产出物,桌面"在侧栏预览"。手机无侧栏 → **全屏预览页 / 底部 sheet**(文本/markdown 直接渲染;office/pdf 走系统预览或转图)。
- **Prompt diff**(`ui-trajectory` promptDiff):系统提示词变更的分段 diff,轨迹里展示。

**移动端通则**:凡 DSH 用"侧栏 / hover / split"呈现的,手机一律换成**全屏页或底部 sheet + 点击进入**;diff 默认单栏;长内容截断 + "展开/查看全部"。

### 7.7 会话节点导航(轮次轨 / TurnNavigator)
DSH 右侧有一条**轮次导航轨**(`ui-chat/TurnNavigator.tsx`):每一轮一个标记(mark),点击跳转到该轮(`navigateToTurn`);悬停/聚焦弹出**预览**,显示该轮的用户提问 + 回复摘要(即截图那个)。数据 = 已加载轮次(`navigation.items()`)与整段大纲投影(`turnOutline`)合并(`mergeTurnRailItems`),未加载的轮次也在轨上;正在分页加载的标记会脉冲。locale:`chat.turnNavigation.jump/jumpLoad/label/turn`。

移动端改造:
- 右边缘保留一条**细轮次轨**(每轮一个点,可拖动 scrub 快速定位);桌面的 hover 预览改成**点按弹预览气泡 / 长按**。
- 另给一个"大纲/跳转"入口(标题栏图标或 ⋮)→ 打开**底部 sheet / 全屏的轮次大纲列表**(每轮:提问 + 回复摘要 + 时间),点一条跳过去。手指操作比细轨更稳。
- 状态照搬:当前轮高亮、加载中脉冲、点击 `navigateToTurn`。

### 7.8 右侧抽屉:一个抽屉,三个面板(文件 / 任务 / 子代理)

桌面 DSH 是宽屏:右侧栏放 diff 与交付物,会话里内联任务区。手机**没有右侧栏**,而"看一眼就走"的东西有三类,分散在对话流里既占屏又割裂,所以合并成**一个右抽屉**:

```
┌──────────────────────────────┐
│ ☰  会话标题(≤220,14px,超长省略) ● ⊕ │  顶栏:☰ 左抽屉 / ● 连接状态点 / ⊕ 新建(§7.8)
├──────────────────────────────┤
│ ›  chat_page.dart        ⋯   │  抽屉抬头:标题随面板变;+N/−M 只对文件有意义
│ [文件] [任务 ②] [子代理 ①]    │  面板切换(计数徽标只在有运行中时出现)
├──────────────────────────────┤
│ 已修改 dart 1.8 KB  [统一][换行] │  面板 1:文件 —— 差异 ⇄ 文件内容 + 工具条
│ @@ -112,9 +112,14 @@ …        │
├──────────────────────────────┤
│ 进行中                        │  面板 2:任务 —— 两行(进行中)/ 一行(已结束)
│ ○ flutter build apk  02:48 ■  │     停止 = 图标按钮 + 二次点击"确认停止"
│ ● flutter pub get  exit code:0│
├──────────────────────────────┤
│ agent Research DSH plugins …  │  面板 3:子代理 —— 与任务同一套行样式
└──────────────────────────────┘
```

**什么时候是右抽屉、什么时候是全屏**:横屏,或宽度 ≥700(平板/折叠屏展开)→ 右抽屉(宽 `min(62%,560)`,左边缘圆角 + 描边);**竖屏手机 → 全屏**(390 宽里再切一块,会话和 diff 两边都不够用)。收起手势跟着换边:右抽屉从**右缘**往右划,全屏时从左缘往右划。

**入口只有一个,而且不跨抽屉**:

- **顶栏三件 + 两条边**(2026-10-16 定稿;"旧状态位"分法见下方偏离说明):
  - `☰` **左抽屉**(图标在**顶栏左侧** —— 用户纠正过我把它移到屏幕边缘那一版):
    点它开;也能从**左缘跟手拖出**(原生 `drawer` + `drawerEdgeDragWidth`)。
  - `●` **连接状态点**:服务中=绿点、连接中/握手中/重连中=转圈、其余(未连接/已断开/连接不上)=红点。
    形状与颜色照 DSH `ui-primitives/src/StateDot.tsx:44-77` 与 `StateDot.module.css:1-45`(10px 槽里画 6px 核;转圈 14px、1.5s 匀速);三档语义照
    `ui-primitives/src/ConnectionIndicator.tsx:7-11`。**点它弹「连接操作」sheet**(重试 / 重新配对 / 打开侧面板 / 断开)——
    照 DSH 的按钮语义:`ConnectionIndicator` 的异常/重连态本身就是"立即重连"按钮(`:75-81`)。
  - `⊕` 新建会话。
  - **右边不加图标**:右缘一条 **4×40 的棒棒**(`ui/edge_stick.dart`)当"这侧能划"的标识,
    从**右缘跟手拖出**右抽屉(原生 `endDrawer`);**右抽屉开着时棒棒整条消失**。
- **与系统返回手势的冲突:用官方排除 API**,不是把把手往里挪 ——
  `platform/gesture_exclusion.dart` 把左右各 32×192dp 的**上半屏**边带报给
  `View.setSystemGestureExclusionRects`(Android 10+;限制**每条边最多 200dp**,
  见 <https://medium.com/androiddevelopers/gesture-navigation-handling-gesture-conflicts-8ee9c2665c69>)。
  上半屏归我们、**下半屏整条留给系统返回**(真机实测:下半屏划一下 App 退到桌面,正是要的)。
- **标题限宽 `220px`、字号 `14px` / 粗细 `w500`**(都照 DSH 的 `.crumb`:`max-width:220px; font-size:14px; line-height:20px`,当前那条是 `w500`,`ui-conversation/src/client/skeleton/ConversationRoot.module.css:125-139`):
  标题可省略,但**不许吃掉整行**。子智能体 / 后台任务计数走**自己那一行**(`_LiveChipsRow`,顶栏之下、对话·轨迹分段之上;常态一行,放不下才换行),
  与标题**不争同一条宽度** —— 结构上等价于 DSH header 的 `.headerActions{flex:none}` band(`:156-161`)。
- 文件变更那一档**仍未接**(手机的文件面没接 `workspace-files`);显示"0 个文件变更"是把"没接"说成"没有"。
- **已否决**:左抽屉里再放一个「任务」入口去开右抽屉 —— 两个抽屉互相跳没有道理;也否决了在对话流里内联铺开任务明细(占屏)。
- 审批 / 提问**接管输入栏**(§7.8 之外的 composer takeover),本来就在眼前,**不占顶栏**。

> **有意偏离(2026-10-16)**:①**计数 chip 不与标题同行**(Web 把计数放在 header 同一行的 actions band):360~390px 上
> `☰`+`●`+`⊕` 已占约 124px,两枚两位数 chip 约 250px,标题将无位可放 —— 所以手机上让计数**另起一行**。
> ②**连接正常时仍显示绿点**(Web 的连接指示器只在异常 / 重连 / 刚恢复三态出现,正常时什么都不显示):用户明确要求"显示个绿点啥的就行",
> 且手机没有第二个地方能一眼确认连线。**代价**:顶栏常驻一个 10px 的点。取舍见
> `.agents/notes/implemented/2026-10-16-topbar-connection-dot-and-title-cap.md`。

**多会话并行:一个会话一队**(2026-10-13 对齐 DSH 原生):

- DSH 的待处理是 **per-session** 的:`PendingApproval` / `PendingQuestion` 都带 `sessionId`,注册进**那个会话**的 composer(`packages/client/ui-session/src/client/index.ts:391`、`ui-approval/src/client/contract/slots.ts:101`),scope 不到会话就 `next()` 不接(`ui-approval/src/client/index.ts:43-44`)。电脑上并行开着几个会话时,每个会话各有各的待处理,**切到哪个会话就处理哪个**。
- 手机侧同构:`TakeoverController` 按 sid 分桶,当前会话显示该会话的队首(一次只处理队首的瀑布语义不变);切会话 = 换桶,另一个会话的待处理不插到眼前、也不丢。
- 跨会话必须可见,否则用户没有理由知道要切:① 会话行副标题显示「N 个待处理」(本地从投影数,`AppModel`);② 本会话输入栏空着时,显示一行「其他会话还有待处理,去会话列表切换」。
- 同一会话多个待处理的先后照 DSH 的确定性优先级,**大的赢**:计划审查 2 > 提问 1 > 审批 0(`ui-user-questions/src/client/index.ts:372`、`ui-approval/src/client/index.ts:89`)。**不自己发明"审批最急"**。
- 收束(电脑侧答了 / 会话被替换)**不带 sid、全桶找**:迟到事件可能属于另一个会话,限定当前桶会让那张卡永远挂着。

**为什么不做第二个独立页**:同一件事两个入口 + 换页没有到位反馈,用户会以为没做(已发生并被指出)。抽屉的切换必须有明确反馈:tab 高亮 + 计数徽标 + 标题随面板变。

## 8. DSH → 移动端 组件对照表

| DSH 包 / 组件 | 移动端对应 |
|---|---|
| `ui-conversation` skeleton + `conversation.view` slot | 会话详情容器 + 对话/轨迹 分段 |
| `ui-chat` ChatView/MessageItem/AssistantMarkdown | 对话消息列表 + Markdown/代码渲染 |
| `ui-chat` StatsPills / stat-dialog / TurnUsagePanel | 状态 chip + 会话统计/Token sheet |
| `ui-conversation` ContextMeter | 上下文环 + 上下文 sheet |
| `ui-trajectory` Toolbar/Timeline/Table | 轨迹子分段 + 迷你甘特 + ledger |
| `ui-primitives` SegmentedControl/tabs/code card | 通用分段控件/标签/代码卡 |
| `ui-primitives` DiffBlock / `ui-deliverables` FileDiff | 内联 diff 卡 / 文件 diff(unified 优先) |
| `ui-deliverables` ChangedFiles/ReviewTab/PresentedFileCard | 变更文件列表 + 审查 + 交付物预览 |
| `ui-attachment` MessageImage/ComposerAttachments | 消息图片 + lightbox + 草稿附件预览 |
| `ui-chat` TurnNavigator | 会话节点导航(轮次轨 + 预览 + 跳转) |
| `ui-settings*` sections/items | 设置页分组与项 |
| `ui-settings-models` | 模型提供商/密钥/base URL/协议/模型目录 配置 |
| `ui-plugin-manager` | 插件安装/启停/组件开关/配置/安装源 |
| `contracts/dsh-bridge` (AA) | `core` 里的 bridge 协议客户端 |

---

## 8.5 完整界面清单(DSH `packages/client/ui-*` → 移动端覆盖)

对着 DSH 全部 ui-* 包核对,避免遗漏。★=控制类 App 必需,○=功能面,△=按需/低优先。

**已在本文覆盖**:ui-conversation/ui-chat(对话)、ui-trajectory(轨迹/甘特)、ui-tool(工具行)、ui-deliverables(diff/交付物预览)、ui-attachment(图片)、ui-theme(主题)、ui-primitives(基础组件)、ui-settings*/ui-plugin-manager/ui-permission-presets/ui-agent-preset(设置/模型/插件)。

**★ 控制类必需**(之前漏了,是远程控制的核心):
`ui-approval`(工具/权限审批)→ 待审批卡 + 推送,允许/拒绝;
`ui-user-questions`(Agent 提问)→ 输入区上方插卡回答;
`ui-model-selection`(会话内模型 + 权限模式)→ 输入栏模型选择器;
`ui-plan`(计划审查)→ 计划卡:批准/修改/继续;
`ui-conversation composer`(输入/排队/打断)→ 输入栏 + 排队消息 + 运行中打断。

**○ 功能面**(逐步补):`ui-goal` 目标卡;`ui-jobs` 与 `ui-subagent` → **右侧抽屉的「任务」「子代理」面板**(行规格照源码,停止两段式不乐观更新,不做重试);`ui-schedule`/`ui-input-trigger` 任务管理页 + 触发来源标记;`ui-commands` 输入栏 "/" 唤起;`ui-skill` 技能列表;`ui-workflow-run` 运行进度;`ui-reference` @ 引用;`ui-message-feedback` 消息反馈;`ui-settings-web-search` 设置项;`ui-workspace`/`ui-directory-picker` 新建会话选目录;`connection` 复用为"中转连接/设备在线"状态。

**△ 侧栏族**(桌面侧栏 → 手机全屏页/sheet,按 bridge 能力上):`ui-sidebar-files` 文件页、`ui-sidebar-terminal` 终端页、`ui-sidebar-documentpreview` 全屏预览、`ui-sidebar-browser` 应用内 WebView 或系统浏览器、`ui-sidebar-right` 帮助/引导页。

**基建(不单独做界面)**:`ui-layout` / `ui-dockkit` / `ui-slots` / `ui-renderer` / `ui-session` / `ui-open-in-app` / `ui-brand-official` / `product-analytics` / `store` / `hmr` / `modules` / `resources` / `locale` / `shortcuts` / `file-upload` / `web`。其中 **`ui-renderer`** 是内容渲染基座(Markdown/代码)= 我们的渲染层;**`file-upload`** = 附件上传能力。

## 9. 协议与桥接面

**通道协议自研**,契约见 `subsystems/remote-channel.md`;参考实现的契约与 fixtures 在 AA `dsh-bridge` 1.0 / next(JSON-RPC over WebSocket,行级 UTF-8 帧,8 MiB 上限),可按需核对方法形状:`session.list/getSnapshot/getState/getNotices/getCapabilities`,写侧 `createAndStart`、`startTurn`(带 `clientMessageId`)、`interrupt`、`steer`、`respondInteraction`,事件 `runtime.sync.subscribe/batch/ack`;图片附件在 **AA 契约层**叫 `allowedMimeTypes`(= png/jpeg/webp/gif),在 **DSH 侧**实名是 `mediaTypes`(`ImageMediaType` 联合,`packages/attachment/attachment/src/types.ts:8`)——两层名字不同,别互相检索。

**审批与计划审查:已具备。** 出货的 `dsh-bridge-next` 把审批作为 interaction notice 送出并接受应答(单次允许 / 拒绝两个动作),计划审查走 question 的 `plan-review` intent 并保留完整计划文本;1.0 契约文本里"不支持"的表述与实现不符,**以实际服务为准**。第一版按这两个动作起步。

**一个必须纠正的名字**:DSH 自己的服务里**没有** `session.startTurn` / `clientMessageId`(全仓库无此字段),发送是 `sessionController.prompt({ requestId, mode: 'queue' | 'steer' })`,幂等靠 `requestId` → 桥接的幂等键就映射到它,并且桥接要自建去重表(DSH 没有跨进程去重存储)。

**电脑侧只做适配,不重建投影语义**:会话流、审批、提问、历史、任务都取自 DSH 已有服务(`sessionController.follow/page/prompt/cancel`、`approval`、`userQuestions`、`ctx.jobs`),映射表见 `subsystems/remote-channel.md` §2.2。注意:**后台任务在参考实现里没有任何投影**(它甚至主动隐藏 subagent 会话),而在 DSH 侧 `ctx.jobs` 是真的 → 这一块必须自己投影(见 §12)。

**契约与实现有落差,别按契约估工作量**:`request.schema.json` 列了 `catalog.listAgentPresets`、`runtime.sync.*`,但 `dsh-bridge` 的 switch 未实现、只在 `dsh-bridge-next`。按实际要用的那份实现估。

**扩桥接面的落点**(设置/模型/插件):DSH 侧 `settings-controller` 已实现完整 `settings.describe/update/replace/mutate` + `credentials.describe/set/unset`(读半侧已按 secret 脱敏)→ 桥接主要做**转发**;落点是桥接插件注入这两个服务并同步扩写路径白名单。该面是 DSH **有意设的边界**(非 loopback 客户端不给写设置),详见 §7.5。

---

## 10. 落地路线(每步独立可交付)

操作步骤、精确验证命令与完成判据见 `cookbook/channel-bootstrap.md`。

1. **交互基线**(已完成):`mock/proto/` 可运行原型 + 验证脚本,覆盖抽屉、文件预览、授权接管、输入栏、任务与子代理。
2. **协议规格与回环**(已完成):`protocol/` 的 16 条 fixtures + 参考实现 + 三个校验脚本(恢复只有两种结果、三角色回环、**中转状态清空后重启仍能收敛**、跨端密码学向量)。
3. **电脑侧插件骨架**(已完成):`connector/` 做成 npm bundle,数据取自 DSH 已有服务(`sessionController.follow/page/prompt/cancel`、`approval`、`userQuestions`、`ctx.jobs`),对着同一批 fixtures 跑(275 项全绿)。**工程形态照参考插件的形状定**:`dsh.bundle.patch` 指向 4 行 `cordis.patch.yml`(`insert: [{ id, name, config }]`),`peerDependencies` 对 `@deepseek-ai/dsh*` 用精确版本(兼容性判据是它,不是 `engines.dsh`),`engines` 只写 node,DSH 各包(`0.2.0-rc.2` 线)以 devDependencies 供类型检查。
4. **连通验证**:**分两件事**。① 传输层连通:目前只有**测试替身**(`connector/tests/support/phone.ts`)在真 socket 上跑通过,**仓库里没有任何可运行的客户端**;要真跑一次得先写一个临时客户端(纯 Node,不碰 Flutter,比手机端小得多)。② *真机*跑通"发一句/回一句"——**前置是第 5 步整条链**,没有 App 就没有东西能发起握手。本条排在第 5 步之前只表示"验证手段先备好",**不表示它先完成**。
5. **Flutter 工程 + 骨架 + 主题**:先 `flutter create` 建出工程(`app/` 只有主题层,连 `pubspec.yaml` 都没有),再把 §5 token 与原型交互在 Dart 复刻骨架,一屏 Demo 对比原型验收还原度。**前置:先装 Flutter SDK**。**这是当前唯一"零进度"的部分,也是第 4 步②与所有手机端工作的闸门。**
6. **只读会话**:接通道,手机看会话列表 + 对话 + 轨迹(不可发)。
7. **可操作**:发消息 / 打断 / 插话 / 提问与审批回应。
8. **后台任务面板**:投影 `ctx.jobs`(清单 + 状态 + 按需输出流 + 停止 + 清空为本地隐藏)。
9. **每端专属表达**(体验上限,按 `subsystems/app-platform-boundaries.md` §2 分端做):iOS 锁屏实时活动 + 通知上直接审批;安卓进度通知(提升通知只用于**本机发起**的任务)+ 厂商通道;鸿蒙关键节点通知 + 服务与通讯类权益。
10. **轨迹甘特**:迷你横滑甘特 + 三个统计 sheet。
11. **设置页第一版**:5 组(通用 / 模型 / 内置插件 / Agent 预设 / 关于连接),逐项处置见 `docs/settings-porting-notes.md`。
12. **中转产品化**:自建中转替掉 Tailscale,补齐配对 / 鉴权 / 限流 / 吊销。
13. **鸿蒙目标**:接 Flutter OHOS(锁同一条版本线),过一遍三方库适配(安全存储 / 本地库 / 推送)与 §5 的鸿蒙已知问题清单。

---

## 11. 风险与待确认

- **自研通道 = 净增三块维护面**(电脑侧桥接、中转、手机端协议栈)。参考实现已经踩过的坑集中在**恢复语义**(重连补课、幂等重发、单帧上限)与受监管重订阅上;这三块必须自己做对并有可执行用例,不允许"先全量刷新、以后再补增量"。**当前协议未覆盖的六条**(流式帧、快照水位与分页、待审批的持久投影、流控、接收端重放规则、审批仲裁)见 `channel-review-notes.md` §3。
- **端到端加密的算法与 nonce 策略待实测择定**:XChaCha20 不在 `cryptography_flutter` 的平台加速清单里(始终纯 Dart),且 `cryptography` 的默认随机源是 `Random.secure()`(系统调用)——逐帧随机 nonce 等于逐帧系统调用。→ `ev` 帧的 nonce 由 `(sid, seq)` 派生,算法以真机小帧基准择定(候选 ChaCha20-Poly1305 / AES-GCM)。另:无前向保密、第一版无密钥轮换,且三端保护强度不对等(鸿蒙 HUKS 支持 X25519 且私钥不可导出;iOS Secure Enclave 只支持 P-256,Curve25519 只能作 Keychain 软件密钥)。
- **中转是常在线组件**:需要限流、审计、吊销与最小权限。内容端到端加密且不长期存内容,但推送摘要对通道可见——已写成用户可选的两档开关。
- **推送必须由常在线的一方发出**:电脑侧桥接不在线时不会有任何通知;电脑关机 = 手机只能看已缓存部分。
- **通道前提**(逐条见 `subsystems/remote-channel.md` §11):插件自开长连接与持久化**已确认可行**(必须是 npm bundle,不能用动态 Cordis 包;**兼容性判据是 `peerDependencies` 而非 `engines.dsh`**);DSH 的会话 `seq` 可直接当修订号、`sessionController` 可由插件直调、心跳取 60 秒均已确认。**审批的仲裁路径也已核实**:`ctx.approval.request()` 无限等(仅 signal 取消竞速)、应答链 fail-closed、迟到应答被丢弃;提问可 120 s 转 pending 且迟到应答成为 `answer_to_pending_question` 用户消息(逐条出处见 `remote-channel.md` §6.3.1)。据此,手机上先转**提问与计划审查**,审批留桌面。仍待定的是鸿蒙端的自写范围(设备私钥 channel / 本地库 / 推送)。
- **推送的触达能力被平台政策封顶**:iOS 被强杀后只能靠用户点通知(静默推送会被丢弃);安卓大陆 FCM 不可用、须走厂商通道并接受分类报备与模板(小米 2026-07-01 起私信须带 `channel_id` + 模板 ID,vivo 运营消息仅 7:00–23:00 可下发);鸿蒙未申请"通知消息自分类权益"时**单设备每日 2 条**(5 条仅持证新闻类),超发直接丢弃,且聚合推送(极光等)数据面仍走系统 Push Kit、**绕不过该频控**。→ 能承诺的是"打开 App 后状态一定正确",不是"审批必达手机";鸿蒙端只做关键节点通知。
- **鸿蒙 Flutter fork**:非上游主线,版本跟随 CPF-Flutter / Flutter SIG 节奏(当前稳定线基于上游 3.41.9,滞后 4 个月;3.35 线 7 个月,见 §3);**设备安全存储必须自写 platform channel 接 HUKS**(适配表里的 secure storage fork 无 HUKS 说明,不能当作已解决);推送只能走 Push Kit(未申请自分类权益时单设备每日 2 条);`sqlite3` / `drift` 无适配,本地库只能选 sqflite 或 realm;**Dart build hooks 在 OHOS 不可用**(需要原生库时走 `plugin_ffi` + `externalNativeOptions`)→ 三端同期交付仍有真实风险,落地路线第 13 步已把它排在最后。
- **阴影 token 缺失**:DSH elevation 在上游 `deepsuite`,需量取或索取,否则阴影只能近似。
- **助手紫/渐变**:DSH 是 `color-mix` 运行时算,移动端用近似常量,验收时对比微调。
- **改电脑设置是 DSH 有意关闭的路径**:非 loopback 客户端持久化降级 `memory`、写被拒;我们靠"桥接是插件、有完整 ctx"绕过,需承担升级被影响的可能(见 §7.5)。
- **插件自定义界面无法通用渲染**(架构限制),第一版只做管理面 + volatile 表单(见 §12)。

---

## 12. 插件与后台任务(手机端边界,已查实)

**逐条依据(带 DSH 源码 `路径:行号`)见 `docs/plugin-and-jobs-notes.md`**;本节只定边界结论。

**后台任务(ui-jobs)—— 放右侧抽屉,不在对话流里铺开**:明细在右侧抽屉(§7.8),会话里只留一行提示。状态机照抄 `running | stopping | completed | killed | failed`;行规格分进行中两行 / 已结束一行。停止是**行尾图标按钮 + 二次点击确认**,先落 `stopping` 等权威帧、**不乐观更新**。"清空"只是客户端本地隐藏(**不承诺删除**),**不做"重试"**(无该接口)。详情展开即订阅输出流、收起即停;截断阈值与"结算后 DSH 侧只留 16 KiB"见专项文档。

**插件(ui-plugin-manager / ui-settings-plugin-inventory)—— 手机做不到什么**:

- **不能渲染插件自己的界面**。插件 UI = 浏览器里的 React 组件 + slot 注册表,slot 拿到的是 `state`/`mutate` **活对象**,**没有可序列化的页面描述** → 让手机渲染任意插件页 ≡ 在手机上跑 DSH Web 客户端。这是**架构性限制,不是工作量问题**。
- **但配置有一条真实通用路径**:Schemastery `schema.toJSON()` 信封带 UI 元数据,可 rehydrate;限制是只有 `.volatile()` 字段过线。→ **配置分两档**:`volatile` 用自建通用表单,其余只读并标"需在电脑上编辑"。
- **三条策略**:不做逐插件页面适配;给插件作者正路(声明 `.volatile()` + `description` 即自动进手机表单);其余标"在电脑端打开"。
- 手机**可做**:只读清单 + 状态、行级开关、安装日志、安装卸载(两段确认)。**不该做**:静默批准 build script、安装做成一次点击。

> **有意偏离 DSH 插件管理器范式(2026-10-15)**:电脑侧设备管理面支持**行首 checkbox + 顶部浮现操作栏的多选删除**(DSH 插件管理器逐行开关 + 逐个确认、无多选)。**原因**:真机联调会攒几十行"配对过、连过一次、再没连过"的记录,挑几台删是真实场景;不选"编辑模式"是因为多选是临时动作,模式切换会改变整个列表的交互语义。**其余仍照 DSH 范式**:停用/启用一对布尔端点(照 `setBundleEnabled`)、启用不确认、硬删走页面内命名确认对话框(照 `confirmUninstall`,不用 `window.confirm`)、失败带原因。取舍见 `.agents/notes/implemented/2026-10-15-device-admin-face-dsh-house-style.md`。

---

## 13. 本机运行模式(不连电脑)

**调研与设计草案见 `docs/standalone-mode-notes.md`**(rikkahub 对照);本节只定结论。

- **定位**:同一个 App 两条路 —— ①连接电脑上的 DSH(遥控器)②**手机自己跑**(自带服务商/密钥/模型参数)。首启动就让用户选,别默认进聊天再报错。
- **推理档位**:rikkahub 是跨 provider 统一的 7 档枚举 + 离散滑杆;**DSH 是按模型的能力**(`reasoning.efforts`/`defaultEffort`,菜单两格钻取)。手机端**跟随 DSH 这套**;本机模式再退回滑杆。风险:7 档在各家语义**不等价** → 第一版只做兜底 `reasoning_effort` + 白名单,并在 UI 标注翻译可能与预期不同。
- **不照抄 rikkahub 的两处**:密钥它**完全明文**(DataStore + 备份 ZIP 明文含 Key)→ 我们走 iOS Keychain / Android Keystore / 鸿蒙 HUKS;附件它把二进制当文本读 → 不要重复这个坑。
- 两模式共存时,密钥库里**绝不能出现 DSH 凭据**(§7.5:密钥不回传手机)。

