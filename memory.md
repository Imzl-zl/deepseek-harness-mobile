# dsh-mobile 项目状态

> 本文件是**当前状态快照** + 最近活跃窗口,允许覆盖更新。**不做流水追加** —— 历史属于 git 与 `.agents/notes/`。
> 决策与取舍见 `.agents/notes/`,稳定规律与坑点见 `tools.md`,现状事实见 `docs/`。
> 已落地的批次只在文末留一行索引,细节回 git 与笔记找。

## 下一步(新会话从这里开始)

> **开工提示词:`docs/cookbook/next-session-acceptance-and-rendering.md`** ——
> 它的四条里**前两条与 ③ 都已落地并全绿**(commit `6a9249b`),剩下两件事:
> **① 真机验收**(用户刚换局域网;①②③ 还没有一张带数据的真机画面)、
> **② ④ 会话渲染对齐 DSH**。④ 的调研结论(带 `packages/...:行号`)照旧可用;
> **③ 的落地结论在 `docs/subsystems/blank-session-hero.md` 与
> `.agents/notes/implemented/2026-10-17-blank-session-hero.md`**,别再从任务书里读 ③。
> 旧的那份 `next-session-interaction-to-phone.md` 任务已完成,**别再照它跑**。

## 当前能力(都已在真机上跑通过一次)

- **会话面**:流 / 历史 / 发送 / 取消 / 排队(编辑·删除·插话)/ 插话与打断。
- **交互转手机**:审批 / 提问 / 计划审查,per-session 待处理队列,跨会话角标与提示行。
- **只读面**:统计条、模型名与切换、权限档(读目录+切档)、Agent 预设目录、后台任务(全四条)、
  子智能体目录、端点切换、配对扫码、归档。
- **连接**:中转 + 局域网直连,端点按"direct 先于 relay"自愈,换端点不重扫码。
- **新会话页(③)**:连上后落到 blank 会话 → hero(鱼 + 标题 + 预览版徽标 + 两枚 chip)。

## 三条仍然有用的教训(都是"替身复现的不是真形状"这一类)

1. **投影信封**:`session.projections` 回的是 `null | {kind, asOfSeq, values}`,**手机要 `values`**。
   连接器曾整包透传 ⇒ 统计条/权限档/子智能体在生产里全空态而单测全绿(修在
   `connector/src/dsh/projections.ts` 的 `valuesOf`)。**新接任何投影面先问"替身回的是真形状吗"。**
2. **模型目录**:DSH 的 `buildModelCatalog` 返回**对象**(`{default, routableProviders, groups, failures}`)
   不是数组;解析器认错形状 ⇒ 生产里一次都没解析成功过。
3. **`session/select-model` 没有"不能写"的约束**:Web 调的就是它
   (`ui-model-selection/src/client/directory.ts:98`),语义是"当前会话立即生效 / 以后新建的默认跟随 /
   不改别的会话"。我曾把**测试纪律**(测试 profile 与日常 profile 共用 `~/.dsh/`)错升成产品约束。

## 真机联调的成本纪律(立过规,别问第二遍)

- `--profile` **只隔进程/插件/端口**;`~/.dsh/{.credentials.yaml,sessions,storages}` **全局共用**。
  **不另起测试 profile**;要专用会话走「问 → 建(名字带 `[可删]`)→ 跑 → 用户确认后删」。
- **每次跑之前报一句"这次约几个轮次"并拿到准** —— 审批探针要模型真跑一条越权命令,花的是用户的钱。
- 装 App 一律 `flutter build apk --debug` + `adb install -r`;`flutter install` 与
  `flutter test integration_test/` **都会先卸载旧 App**,配对凭据在私有目录里,一卸全没。
- 屏幕灭掉 = Flutter 引擎暂停(用例报"did not complete"且没有原因)⇒ `adb shell svc power stayon true`。

## 前置事实(会卡住实施)

- **Flutter 3.41.9 / Dart 3.11.5 已装好且版本锁死**(上界由鸿蒙 fork 定)。Android 构建要
  `ANDROID_HOME='D:\soft\android-sdk'` + `JAVA_HOME='C:\Program Files\Eclipse Adoptium\jdk-21.0.9.10-hotspot'`。
- 明文 HTTP 放行有**四处**,少一处静默不通:Android `network_security_config.xml`(debug)、
  `PairingPage.allowInsecureLocal`、`main.dart` 的 `PairingClient`、profile `cordis.patch.yml`。
- **无线直连三件一起对**(换过局域网就要重看):profile 补丁 `listenPort: 8790` + `listenHost: '0.0.0.0'`、
  `Get-NetTCPConnection -State Listen -LocalPort 8790` 显示 `0.0.0.0`、连接器状态面 `caps.direct === true`。
  判据与"换 IP 无感是部署选择不是代码缺口"见 `tools.md` 的「无线局域网直连」。
- `connector/` 与 `relay/` 是**两个独立 pnpm 工程**;导入风格不同、别顺手统一
  (connector 写 `.js` 因 tsdown 打包,relay 直接跑 `.ts`)。`relay` 的 `ws` 须先 `pnpm install`。
- 本仓库**没有 CI**;`mock/proto/shots/` 与 `setup-collaboration-files.backup/` 不入库。
## 方法面 27/31

契约封闭集 **31**、实现 **27**,差额 4 个是契约列了没实现的:`settings.describe` /
`settings.update` / `credentials.set` / `credentials.unset`(依据见契约 §5.8)。

**这两个数从代码里数,不靠减**(30 减 4 明明是 26,而文档曾写成"30(实现 25)"—— 两个数一起写就会一起错)。
数法:`METHODS` 数组 + `handlers.ts` 的**两种**注册形态(对象字面量键 `'x.y': async (…) =>`
与赋值 `handlers['x.y'] = …`),只数前者会漏掉大半。**三处必须同步**:`tools.md` 的方法数、
契约 §5.7 的表、这里的"x/31"。

**`session.projections` 是打开全部只读面的那把钥匙**:请求体只有 `{sessionId}`,返回所有已注册投影的当前值。
已核实的键:`modelSelection` / `permissions` / `subagentCatalog` / `deliverables` / `tokenUsage` /
`contextPressure` / `sessionStats` / `turnOutline` / `todos` / `goal` / `plan` / `inbox` /
`title` / `workingDirectory` / `agentPreset` / `userQuestions`。
## 已定案的契约(实施时按这个写,不要重新发明)

细则在 `docs/subsystems/` 各篇,这里只列**最容易重新发明错的**:

- **配对 v2**(`pairing-v2.md`):公开邀请与秘密分离、候选不是设备、**用户确认前不发秘密**。
- **一条连接只服务一台设备**:握手/AEAD 密钥/`fc`(nonce 唯一来源)/重放窗口全是每设备状态。
- **帧的认证边界**:只有握手三帧与 `presence` 明文;`needsBox(t)` 是唯一判据。
- **首配两段**:`beginPairing()`(秘密未发)→ 用户确认 → `commit(code)`。
- **AEAD**:AES-256-GCM(Electron 的 crypto 没有 `chacha20-poly1305`);nonce 是 `fc` 的 96 位大端。
- **中转的可见面**:只读 `sid`/`seq`/`fc`/帧类型/帧头 `id`;方法名与载荷不可见。
- **幂等**:两阶段(落盘 `pending` → 执行 → 改 `done`);**落盘失败即拒绝该写操作**;`requestId` 在信封顶层。
- **密钥**:API 密钥值不回传手机,改密钥只发新值。
## 已知缺口(定位过、有证据,都未修)

1. **首配的匿名限流桶是单一全局桶**:形状校验在取桶之后,持续约 6 请求/秒即可让所有新设备换票 429
   (约 10 s 恢复)。这与 `pairing-v2.md` §3"无效试探不能使真正的扫码设备失去授权机会"不符。
2. `stats.devices` 实为**通道数**(`relay/src/core.ts`),与 §8.2 的 `devices` 表不同名同义。
3. 握手层 close 4003 与 `protocol/revoked` 帧两条兜底路径仍走退避,未收口。
4. `pairing_page.dart` 的配对码 `TextField` 没关输入法联想,**用户手打**那段 JSON 会被破坏(粘贴不受影响)。

## 范围决定(别再当缺口)

- **刷新令牌轮换不做** / **中转不做多实例**(单实例 + I7 重启收敛就是个人工具的形态)。
- **鸿蒙暂缓**(不是放弃):Flutter 版本锁保留,OHOS 适配/HUKS/推送全部暂停。
- **插件不做"逐插件页面适配"**(架构上不存在通用渲染):只做清单/状态/启停/安装日志 + `volatile`
  字段通用表单。**别自己从零做通用 schema 渲染器** —— DSH 两次否决过。
- **管理页面不做**:二维码唯一出口,DSH 的 `CommandResult` 只有 text 没有图片出口。
- **手机上不做(C 类)**:目录选择器、唤起电脑应用、内嵌浏览器/Office 预览、快捷键/窗口管理、
  workflow/schedule/skill、实验性功能。

## 门禁(改代码后必须全绿)

| 命令 | 覆盖 |
|---|---|
| `node protocol/verify-{fixtures,loopback,vectors}.mjs` | **486 / 26 / 49** 项 |
| `node app/tools/verify-platform-boundary.mjs` | **266 项**(22 条规则自检 + 扫 74 个 Dart 文件) |
| `node mock/proto/tools/verify-icons.cjs` / `verify-tool-paths.mjs` | 原型图标集(**100 个**)/ 工具脚本不许硬编码盘符(19 个) |
| `cd app && flutter test` | **707 项** |
| `cd app && dart analyze --fatal-infos lib test integration_test` + `dart format --output=none --set-exit-if-changed …` | 各 **0**(analyze 比 `flutter analyze` 严) |
| `cd connector && pnpm exec tsc --noEmit && pnpm build && pnpm test` | 类型 + 产物 + **533 项** |
| `cd relay && pnpm typecheck && pnpm test` | 类型 + **86 条** |
| CDP 浏览器组 | `verify-proto`(**31** = 顶栏与统计条 13 + 新会话页 hero 18) / `verify-authz`(18) / `verify-settings`(28) / `verify-tasks`(53) / `verify-picker` |

**项数的唯一出处是 `tools.md`**;**改断言必须做一次变异校验**(故意破坏不变量,确认**恰好**那一条红)。

## 仍未注意就会翻车的

- **改源码只用编辑工具,不用 shell 字符串替换** —— shell 出错是静默的(曾把源文件写空、造出空文件、
  让一处计数静默漂移 28 条)。
- **`dart format` 会重排文件**,之后再编辑同一文件要**重新读一遍**(编辑工具会因"文件变过"拒绝)。
- **别把"重启后的第一次成功"当能力**;判据要包含"连续重连 N 次都成立"。
- **提交信息里避免反引号**(pwsh 会当 Unicode 转义,整条命令在解析阶段失败);长消息写临时文件用 `git commit -F`。
- **提交前看 `git status` 完整清单**,重点是意外的文件(空的、消失的、没见过的新文件)。
- 先查 DSH 开发者文档站再读源码最后才逆向;`web_fetch` 拿不到它,用已连的 Chrome 开 `isolatedContext` 读。
- **稳定坑点的唯一出处是 `tools.md` → Pitfalls**;本文件不复制一份。

## 已落地批次索引(细节回 git 与 `.agents/notes/`)

- `6a9249b` 顶栏收成一行 + 统计条单行横滚 + 任务 ③ 新会话页 hero + 图标集对齐 DSH(98→100)
  —— 同批还修了三个工具链缺口:抽取器解析漏一种函数写法、Dart 图标产物不是格式稳定的
  (生成器现在自己跑 `dart format`)、抽方法名的正则服务名段漏驼峰。
- 更早:交互转手机整链 / 端点切换与局域网直连 / 归档面 / 排队与打断 / 设置页四组 /
  标题单一真值源 / 模型目录真形状 / 统计条对齐 Web / 设备身份与失效恢复 / 传输分开关 /
  假数据清理 / 配对 v2 三侧收口。**每篇都有决策笔记,别在这里复述。**