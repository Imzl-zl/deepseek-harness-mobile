# dsh-mobile 项目状态

> 本文件是**当前状态快照** + 最近活跃窗口,允许覆盖更新。**不做流水追加** —— 历史属于 git 与 `.agents/notes/`。
> 决策与取舍见 `.agents/notes/`,稳定规律与坑点见 `tools.md`,现状事实见 `docs/`。
> 已落地的批次只在文末留一行索引,细节回 git 与笔记找。

## 下一步(新会话从这里开始)

> **在跑的任务书**:同一份 goal(goal-a9fd6fb1)。已落地**十二批**并**真机验证**
> （轨迹页那批验到 6+ 轮；流式文本与命令卡只验到单测，真机没看到 —— 见待办）。
>
> **用户点名的议题已全部清零**。剩下的都是"自己摸索"摸到的 + 三个待验证项。

待办:

1. **流式文本真机验收**：`live` 帧 → `AppModel.liveText` → `_LiveTurn`
   三段都有单测，但**真机没看到**（adb input text 往 MIUI 输入法注入不稳定）。
   判据：用户发一句话，正文边生成边显示。
2. **斜杠命令卡真机验收**：`command/run` + `command/done` 已接进对话流
   （真事件 + widget 测试钉住投影与渲染两段），但**真机没看到** ——
   这台电脑的 DSH profile 里没有带 `command/*` 的会话（goal 会话在
   CraftAgent 那台）。判据：在有 `/goal` 或 `/compact` 的会话里看到
   `/goal` 卡片（多行结果可展开）。
3. **用量汇总的甘特图**：现在只有账本（一轮一行）。甘特要**每步**起止，
   而 `sessionStats` 是会话级总量（llmMs/toolMs/ttftMs/decodeMs）——
   拿总量画分段只能画两条 100% 宽的段（假图）。要逐步耗时可考虑插件加投影。
4. **输入栏横滚钮组**：rikkahub 的 `weight(1f)+horizontalScroll`
   （`ChatInput.kt:302-306`）。现在四个钮不换行，加第五个时才需要。
5. **全局侧滑的真相**（别当缺口）：Flutter 原生抽屉**本来就是整页高**可拖
   （`material/drawer.dart:680` 的 `height: double.infinity`），宽度由
   `drawerEdgeDragWidth` 控制。限制在**系统返回手势**：Android 官方
   `setSystemGestureExclusionRects` **每条边最多排除 200dp 总高度**。
   **结论：当前实现已是约束下的最优**，不要再试图"整页都能拖"。
6. DSH 0.2.1 的 `registerFetchRoute` 开始校验同路径重复注册:同 path 的 GET/POST 必须合成
   一条 `methods: ['GET','POST']`(0.2.0 时是绿的)。

## 当前能力(都已在真机上跑通过)

- **会话面**:流 / 历史 / 发送 / 取消 / 排队(编辑·删除·插话)/ 插话与打断 / 列表按工作区分组。
- **交互转手机**:审批 / 提问 / 计划审查,per-session 待处理队列,跨会话角标与提示行。
- **只读面**:统计条、模型名与切换、权限档、Agent 预设目录、后台任务、子智能体目录、归档。
- **连接**:中转 + 局域网直连,**首次经中转学地址、之后走直连**(连续 3 次重连都成立)。
  **换 WiFi 自动连上已验**(2026-10-19 家→公司):重启 App 15 秒内连上,前提是电脑侧
  DSH 已在新网络跑着;新地址由 `endpoint.describe` 的 direct 通道自报学到。
  **两个功能分开**:「换个连接方式」(立刻断、只试这一条,失败回自动)与「自动队列」
  (记住的 → 同网段 → 用户顺序,失败顺延);入口是设置页顶部块 + **顶栏状态点**。
  队列可**拖动排序**、可删除 / 手填(限非公网),删掉的自报端点可在「已隐藏」里放回。
- **新会话页**:连上后落到 blank 会话 → hero(鱼 + 标题 + 预览版徽标 + 两枚 chip)。
- **PC 端**:两通道各自开关;`/api/dsh-mobile/advertise` 管上报地址(藏虚拟网卡 / 追加)。

## 五条教训(都是"替身复现的不是真形状"这一类)

1. **投影信封**:`session.projections` 回 `null | {kind, asOfSeq, values}`,**手机要 `values`**。
   连接器曾整包透传 ⇒ 统计条/权限档/子智能体在生产里全空态而单测全绿
   (修在 `connector/src/dsh/projections.ts` 的 `valuesOf`)。**新接投影面先问"替身回的是真形状吗"。**
2. **模型目录**:`buildModelCatalog` 返回**对象**(`{default, routableProviders, groups, failures}`)
   不是数组;解析器认错形状 ⇒ 生产里一次都没解析成功过。
3. **`session/select-model` 没有"不能写"的约束**:Web 调的就是它
   (`ui-model-selection/src/client/directory.ts:98`)。我曾把**测试纪律**(测试 profile 与日常
   profile 共用 `~/.dsh/`)错升成产品约束。
4. **"空"有两种表达,判空只查一种就会漏**:`items.isEmpty` 漏了 `OtherItem`(hero 从未显示);
   `usage == null` 漏了**字段齐全但全零**的对象(输入框底下显示 `0 tok`)。
5. **判据要能区分"没命中"与"没实现"**:同一句"点了没反应"可能是坐标偏 30px、也可能是回调没跑
   ——2026-10-18 两者同时发生,白查了五轮。**先加一行 `debugPrint` 确认回调跑了没有**,再怀疑手势。

## 真机联调的成本纪律(立过规,别问第二遍)

- `--profile` **只隔进程/插件/端口**;`~/.dsh/{.credentials.yaml,sessions,storages}` **全局共用**。
  **不另起测试 profile**;专用会话走「问 → 建(名字带 `[可删]`)→ 跑 → 用户确认后删」。
- **跑之前报一句"这次约几个轮次"并拿到准** —— 审批探针要模型真跑越权命令,花的是用户的钱。
- 装 App 一律 `flutter build apk --debug` + `adb install -r`;`flutter install` 与
  `flutter test integration_test/` **都会先卸载旧 App**,配对凭据一卸全没。
- 屏幕灭掉 = 引擎暂停(用例报"did not complete"且没原因)⇒ `adb shell svc power stayon true`。

## 前置事实(会卡住实施)

- **DSH 运行时 0.2.1-rc.2**(桌面版自带)。连接器 devDeps/peerDeps 都跟 0.2.1-rc.2,
  `schemastery` 跟 **3.18.5**(钉旧版会装出两份 ⇒ tsdown 报 "type cannot be named")。
- **Flutter 3.41.9 / Dart 3.11.5 版本锁死**(上界由鸿蒙 fork 定)。Android 构建要
  `ANDROID_HOME='D:\soft\android-sdk'` + `JAVA_HOME='C:\Program Files\Eclipse Adoptium\jdk-21.0.9.10-hotspot'`。
- 明文 HTTP 放行有**四处**,少一处静默不通:Android `network_security_config.xml`(debug)、
  `PairingPage.allowInsecureLocal`、`main.dart` 的 `PairingClient`、profile `cordis.patch.yml`。
- **无线直连三件一起对**:`listenPort: 8790` + `listenHost: '0.0.0.0'`、8790 监听在 `0.0.0.0`、
  `caps.direct === true`。**`relayUrl` 必须写环回** —— 写死局域网 IP 会绕开 `relayHintFor`
  的自愈,换网后手机拨不通而重新出码还是死地址。
- `connector/` 与 `relay/` 是**两个独立 pnpm 工程**,导入风格不同、别顺手统一
  (connector 写 `.js` 因 tsdown 打包,relay 直接跑 `.ts`)。本仓库**没有 CI**。

## 方法面 27/32

契约封闭集 **32**、实现 **28**,差额 4 个是契约列了没实现的:`settings.describe` /
`settings.update` / `credentials.set` / `credentials.unset`(依据见契约 §5.8)。
**两个数都从代码里数,不靠减**;数法见 `tools.md`(要数 `METHODS` + `handlers.ts` 的**两种**注册形态)。
**三处必须同步**:`tools.md`、契约 §5.7 的表、这里的"x/31"。

**`session.projections` 是打开全部只读面的那把钥匙**:请求体只有 `{sessionId}`,返回所有投影的当前值。
已核实的键:`modelSelection` / `permissions` / `subagentCatalog` / `deliverables` / `tokenUsage` /
`contextPressure` / `sessionStats` / `turnOutline` / `todos` / `goal` / `plan` / `inbox` /
`title` / `workingDirectory` / `agentPreset` / `userQuestions`。

## 已定案的契约(实施时按这个写,不要重新发明)

细则在 `docs/subsystems/` 各篇,这里只列**最容易重新发明错的**:

- **配对 v2**(`pairing-v2.md`):公开邀请与秘密分离、候选不是设备、**用户确认前不发秘密**;
  两段式 `beginPairing()`(秘密未发)→ 用户确认 → `commit(code)`。
- **一条连接只服务一台设备**:握手/AEAD 密钥/`fc`(nonce 唯一来源)/重放窗口全是每设备状态。
- **认证与可见面的边界**:只有握手三帧与 `presence` 明文(`needsBox(t)` 是唯一判据);
  中转只读 `sid`/`seq`/`fc`/帧类型/帧头 `id`,方法名与载荷不可见。
- **AEAD**:AES-256-GCM(Electron 的 crypto 没有 `chacha20-poly1305`);nonce 是 `fc` 的 96 位大端。
- **帧头 `id` 与幂等键是两个标识符**:`requestId` 只进信封(形状由业务定,如 `i:<callId>` 带冒号),
  帧头 `id` 另铸且必须过 §3 的 ASCII 安全字符集。**把业务键写进帧头 = 连接器按 bad-frame 关连接。**
- **幂等**:两阶段(落盘 `pending` → 执行 → 改 `done`);**落盘失败即拒绝该写操作**;`requestId` 在信封顶层。
- **密钥**:API 密钥值不回传手机,改密钥只发新值。

## 已知缺口(定位过、有证据,都未修)

1. **首配的匿名限流桶是单一全局桶**:形状校验在取桶之后,约 6 请求/秒即可让所有新设备换票 429
   (约 10 s 恢复)。与 `pairing-v2.md` §3 的要求不符。
2. `stats.devices` 实为**通道数**(`relay/src/core.ts`),与 §8.2 的 `devices` 表不同名同义。
3. 握手层 close 4003 与 `protocol/revoked` 帧两条兜底路径仍走退避,未收口。
4. `pairing_page.dart` 的配对码 `TextField` 没关输入法联想,**手打**的 JSON 会被破坏(粘贴没事)。
5. **PC 端「上报地址」面板没有布局/点击的自动化测试**(只有 i18n 键完整性门禁;API 侧有用例)。
6. **IPv6 隐私地址仍会上报**:这台机器报 7 条,其中 4 条是每次轮换都变的 GUA。
   `dialOrder` 已把它们排后面(不再是 30 秒冷启动的成因),但仍占列表位,要用户手动藏。

## 范围决定(别再当缺口)

- **刷新令牌轮换不做** / **中转不做多实例**(单实例 + I7 重启收敛就是个人工具的形态)。
- **鸿蒙暂缓**(不是放弃):Flutter 版本锁保留,OHOS 适配/HUKS/推送全部暂停。
- **插件不做"逐插件页面适配"**(架构上不存在通用渲染):只做清单/状态/启停/安装日志 + `volatile`
  字段通用表单。**别自己从零做通用 schema 渲染器** —— DSH 两次否决过。
- **管理页面不做**:二维码唯一出口,DSH 的 `CommandResult` 只有 text 没有图片出口。
- **不做 hard pin(钉死某个端点、失败也不换)**:用户明确要求"连接不上会自动试其他的"。
  "手动选择"= 立刻试一次(失败回自动)+ 拖动排序,不是"锁死在一条上"。
- **手机上不做(C 类)**:目录选择器、唤起电脑应用、内嵌浏览器/Office 预览、快捷键/窗口管理、
  workflow/schedule/skill、实验性功能。

## 门禁(改代码后必须全绿)

| 命令 | 覆盖 |
|---|---|
| `node protocol/verify-{fixtures,loopback,vectors}.mjs` | **486 / 26 / 49** 项 |
| `node app/tools/verify-platform-boundary.mjs` | **278 项**(22 条规则自检 + 扫 78 个 Dart 文件) |
| `node mock/proto/tools/verify-icons.cjs` / `verify-tool-paths.mjs` | 图标集(**100 个**;app/lib 引用 43 个)/ 工具脚本不许硬编码盘符(19 个) |
| `cd app && flutter test` | **769 项** |
| `cd app && dart analyze --fatal-infos lib test integration_test` + `dart format --output=none --set-exit-if-changed …` | 各 **0**(analyze 比 `flutter analyze` 严) |
| `cd connector && pnpm exec tsc --noEmit && pnpm build && pnpm test` | 类型 + 产物 + **547 项** |
| `cd relay && pnpm typecheck && pnpm test` | 类型 + **86 条** |
| CDP 浏览器组 | `verify-proto`(**31** = 顶栏与统计条 13 + 新会话页 hero 18) / `verify-authz`(18) / `verify-settings`(28) / `verify-tasks`(53) / `verify-picker` |

**项数的唯一出处是 `tools.md`**;**改断言必须做一次变异校验**(故意破坏不变量,确认**恰好**那一条红)。

## 仍未注意就会翻车的

- **改源码只用编辑工具,不用 shell 字符串替换** —— shell 出错是静默的(曾把源文件写空、造出空文件、
  让一处计数静默漂移 28 条)。批量改测试代码时用脚本文件 + 事后 `dart analyze`,别用内联 `node -e`。
- **`dart format` 会重排文件**,之后再编辑同一文件要**重新读一遍**(编辑工具会因"文件变过"拒绝)。
- 提交纪律 / 多替身接口 / 真机坐标 等**稳定坑点的唯一出处是 `tools.md` → Pitfalls**;本文件不复制一份。

## 已落地批次索引(细节回 git 与 `.agents/notes/`)

- **2026-10-19**(十二批,共 12 个提交):渲染三缺陷照 DSH 修 → 输入栏去忙时发送图标
  + 模型 chip 图标优先 → 右抽屉改真抽屉 + 快速跳转钮(rikkahub `MessageJumper`)
  → 浅色主题三档 + **全部 UI 面迁完** → 跨会话用量汇总(连接器 + 手机)
  → 输入栏几何判据 + 模型 chip 按内容宽(省 65px) → **换 WiFi 自动连上已验证**(家→公司)
  → 轨迹页接 `turnOutline` → 消息流显示流式文本 → **斜杠命令卡**
  (`command/run` + `command/done` 从 OtherItem 接进对话流)。
  **`app/test/fixtures/real-session-events.json` 是真机落盘事件** —— 手写形状的
  用例只会复述实现的假设,这是"我们以为的形状与真形状不同"的判据。
- **2026-10-18/19**(连接与端点,9 个提交):帧头 id 与幂等键分离 → 多地点端点保留 → 端点管理 UI →
  PC 端上报地址后端 → 面板 + 0.2.1 适配 → 点名连接 → 切换/重连归位 → 拖动柄 44×44 → 全零投影收起。
  **每篇都有决策笔记,哈希回 `git log` 找。**
- **更早**:`6a9249b` 顶栏一行 + 统计条横滚 + hero + 图标集 98→100;交互转手机整链 / 端点切换与
  局域网直连 / 归档面 / 排队与打断 / 设置页四组 / 标题单一真值源 / 模型目录真形状 /
  设备身份与失效恢复 / 传输分开关 / 假数据清理 / 配对 v2 三侧收口。
