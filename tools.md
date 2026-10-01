# dsh-mobile Tools

## Concepts

- 本文件记录项目协作知识,不替代正式设计文档、`docs/` 或当前代码。
- 真值优先级:`docs/design-and-tech-plan.md`(总纲)> 三份 `docs/*-notes.md`(专项)> 可跑通的验证脚本 > 本文件。
- 主链路:改 `mock/proto/` → 跑验证脚本 → 截图 → 同步 `app/`(Flutter 落地端)。
- 本仓库**没有 CI**;`mock/proto/`、`protocol/`、`app/tools/` 全是显式 `node` 脚本,不存在 `npm test` 这类约定命令。**例外:`connector/` 是 pnpm 工程**(见下),它的命令走 `pnpm exec` / `pnpm test`。

## Read First

- `docs/design-and-tech-plan.md` —— 设计与技术基线(冲突时以它为准)
- `docs/subsystems/remote-channel.md` + `docs/channel-review-notes.md` —— 通道契约与评审(后者含 DSH 行号、待补六条、实测数据)
- `docs/subsystems/connector-and-relay.md` + `docs/subsystems/app-channel-client.md` —— 电脑侧/中转与手机端的落地设计
- `docs/cookbook/channel-bootstrap.md` —— 开工步骤与精确验证命令(新会话从这里开始动手)
- `docs/settings-porting-notes.md` —— 设置项搬运清单(42 项)
- `docs/plugin-and-jobs-notes.md` —— 插件与后台任务边界
- `docs/standalone-mode-notes.md` —— 本机运行模式
- `.agents/notes/AGENTS.md` —— 决策笔记不变量
- `memory.md` —— 当前状态快照

## Tools

- 多端边界校验(不需要 Flutter 工程):`node app/tools/verify-platform-boundary.mjs` —— 扫描 `app/lib` 与 `app/packages`,共 6 条规则:
  1. `core-no-platform-import`:`app/lib/{core,data,model}` 禁 `dart:io` 与 `package:flutter/{services,widgets,material}.dart`(否则纯 Dart 单测写不了)
  2. `ui-no-impl-import`:`app/lib/ui` 禁 import 各端实现包(`*_(ios|android|ohos)/`)
  3. `ui-no-platform-import`:`app/lib/ui` 禁 `dart:io`
  4. `branch-whitelist`:平台分支(`Platform.` / `defaultTargetPlatform` / `MethodChannel` / `EventChannel`)只允许出现在 `app/packages/**`、`app/lib/platform/**`、`app/lib/ui/adaptive/**`
  5. `no-platform-isohos`:全仓禁 `Platform.isOhos`(会导致 `flutter run` / `build har` / `attach` 失败,鸿蒙判断用 `defaultTargetPlatform`)
  6. `fallback-not-in-release`:`app/lib/platform/registry.dart` 引用兜底实现(`InMemory` / `NullPush` / `Noop`)必须带 `kDebugMode` 守卫

  自带规则自检 13 条,所以 `lib/` 还没代码时也不是空转(当前输出:`规则自检 13 条 + 扫描 2 个 Dart 文件`)- 通道协议验证(不需要浏览器/手机/公网):`node protocol/verify-fixtures.mjs` —— 16 条 fixture / 486 项断言(两种结果规则、快照水位与分页、待审批重建、live 帧不入账);`node protocol/verify-loopback.mjs` —— 26 项,手机 ⇄ 中转 ⇄ 电脑侧桥接回环(含"中转状态清空后重启"与强制走桥接分支的 `5b`)。改 `protocol/` 后两条必须全绿;`DSH_DEBUG=1` 可打印每条恢复应答
- 变异校验(验证断言不是恒真,不碰仓库):把 `protocol/` 复制到临时目录后注入,再跑两个脚本。**参考侧实测基线**:① `reference/relay.mjs` 去掉 `seq !== expected` → fixtures 红(仅 `07`);② `reference/bridge.mjs` 的 `hello` 返回空 `transient` → fixtures 红(`09`)**且回环红(`5b`)**;③ `reference/takeover.mjs` 去掉"前台且订阅"过滤 → fixtures 红(6 条,`16`)
  - **connector 侧实测基线**(直接改 `connector/src/protocol/` 后 `git checkout --` 还原,同法可复用):④ `recovery.ts` 的 `hello` delta 返回空 `transient` → 2 项红,全在 `09`;⑤ `takeover.ts` 去掉"前台且订阅"过滤 → 6 项红,全在 `16`;⑥ `crypto.ts` 的 `deriveHandshake` 从 `ikm` 去掉 `ss3`(破坏前向保密)→ vector 测试 3 项红,恰好是 `master` / `kA2B` / `kB2A`(断言数不变);⑦ `transport/keepalive.ts` 把 `halfOpenAfterMs` 设成 `Infinity`(关掉半开检测)→ 2 项红,恰好是那两条断言半开的保活用例;⑧ `lifecycle.ts` 的 `unwind` 改成"遇错即停"(不再收集)→ 1 项红,恰好是「dispose 尽力而为」那条;⑨ `transport/codec.ts` 的 `assertHandshakePhase` 直接 `return`(拆掉握手门禁)→ 1 项红,恰好是「握手门禁」那条;⑩ `protocol/methods.ts` 把幂等键强制那条 `if` 短路成 `if (false)` → 1 项红,恰好是「漏键时在分发前被拦」;⑪ `alias.ts` 的 `reconcile` 开头加 `if (true) return 0`(变空操作)→ 2 项红,恰好是那两条构造"崩在中间"状态的用例(而「干净状态」那条正确地仍通过);⑫ `protocol/handshake.ts` 的 `verifySignature` 开头加 `if (true) return`(验签永远通过)→ 3 项红,恰好是三条断言"该拒"的用例(而「正确签名通过」那条正确地仍通过);⑬ `transport/codec.ts` 的 `HANDSHAKE_FRAME_TYPES` 去掉 `'confirm'` → **4 项红**:`isHandshakeFrame` 判据、握手门禁、连接级 e2e 两条(而驱动器单测正确地仍全绿 —— 门禁是连接层的职责,不归驱动器);⑭ `protocol/handshake-driver.ts` 里 `verifySignature(...)` 换成 `void 0`(验签永远通过)→ 2 项红,恰好是「签名是别人签的」与「伪造 confirm 的 e2e」两条,而"正确签名通过"的两条仍绿;⑮ `transport/connection.ts` 的 `write()` 去掉 `frame.t !== 'ping'` 这个例外(让心跳也重置空闲计时)→ 1 项红,恰好是「完全空闲仍会判半开」那条 —— 而它红的方式是**超时**:半开再也判不出来;⑯ `protocol/box.ts` 的 `openFrame` 把 `guard.accept(fc)` 提到解箱之前(守卫先于认证推进)→ 6 项红,含「先验后进:伪造的 fc 推不动重放窗口」与 e2e 那条「同一帧重放」;⑰ `transport/connection.ts` 的 `handleFrame` 里把 `cipher !== null && needsBox(...)` 短路成 `false &&`(永不收箱)→ 4 项红:手机封电脑解、篡改、重放、缺 box 四条 e2e;⑱ `protocol/box.ts` 把方向映射写死成 `kA2B`/`kB2A`(不再按角色)→ 7 项红,含两个方向的 e2e(而"同向自解"的用例正确地仍绿);⑲ `protocol/crypto.ts` 的 `open` 去掉 `ProtocolError` 包装(让 node:crypto 的裸错误漏出去)→ **2 项红,全在单测**(`AAD 绑定`、`先验后进` 断言的是错误码),而 e2e 的篡改用例**仍绿** —— 因为连接层把非协议错误统一按 `protocol/bad-frame` 关闭,分不出类型。这条正好说明:**错误码的正确性只有单测能盯住**;⑳ `protocol/flow.ts` 的 `canSend` 去掉优先级例外(满窗时连 `res` 也压住)→ 2 项红:「满窗时 res 照发」e2e 与流控单测;㉑ `transport/connection.ts` 的 `accountFlow` 里把 `if (elicitsCredit(frame.t))` 改成 `if (true)`(连 `credit` 也回执)→ 1 项红,恰好是「credit 自己不再回 credit」那条。**㉑ 第一次跑时是全绿的**:当时这条规则被"早返回 + 谓词"写了两遍、谓词是死逻辑;改成两个并列 `if` 后,同一个变异立刻命中。结论:**变异不红时先怀疑测试或重复逻辑,而不是记一笔"覆盖不到"**。④⑤⑥⑦⑧⑨⑩⑪⑫⑬⑭⑮⑯⑰⑱⑲⑳㉑ 与参考侧基线 ②③ **逐条对上**。
- 会话规模标定(只读 DSH 仓库,用于标定重放窗口与帧上限):统计 `C:\sudy\github\deepseek-harness\snapshots\**\*.jsonl` 的事件数 / turn 数 / 单事件字节(结果:中位 21 事件/turn、单事件 max 7 KB、最大会话 99 事件,见 `docs/channel-review-notes.md` §6)
- 跨端密码学向量:`node protocol/tools/gen-vectors.mjs` 机生成(用 `node:crypto`,勿手改产物),`node protocol/verify-vectors.mjs` 重算比对(**49 项**:握手派生 10 字段 + 设备身份 4 字段 + 身份两把密钥不同 1 + transcript 拼串与签名 3 + AEAD 5 条 × (密文/标签/**箱容器**/容器往返/解密往返) + 篡改拒绝 3)。**两侧实现各自跑同一批向量**,`connector/tests/vectors.test.ts` 的断言数必须与它相等(不等就是抄漏了断言)
- 图标集校验(不需要浏览器):`node mock/proto/tools/verify-icons.cjs`
- 起独立 headless Chrome(不碰日常浏览器,默认端口 9400):`pwsh -File mock/proto/tools/cdp.ps1 -Port 9400`
- 设环境后跑验证:`$env:CDP_URL='http://127.0.0.1:9400'; $env:NO_PROXY='127.0.0.1,localhost'`
  - `node mock/proto/tools/verify-proto.mjs` —— 布局与交互(顺序、控件位置、搜索过滤、动画、遮罩)
  - `node mock/proto/tools/verify-authz.mjs` —— **授权矩阵 18 项**,必须 0 失败
  - `node mock/proto/tools/verify-picker.mjs` —— 选择类列表列固定
  - `node mock/proto/tools/verify-settings.mjs` —— 设置页导航/控件/边界回归,27 项(首页分组顺序 + 通用页 11 行顺序)
  - `node mock/proto/tools/verify-tasks.mjs` —— 对话 dock(目标 / 任务清单)+ 自动化任务页,53 项
  - `node mock/proto/tools/measure-composer.mjs` —— 量输入区控件几何
  - `node mock/proto/tools/shoot.mjs` / `shoot-composer.mjs` / `shoot-picker.mjs` / `shoot-settings.mjs` / `shoot-tasks.mjs` —— 截图到 `mock/proto/shots/`
- 语法检查:`node --check mock/proto/app.js`(同 `interactions.js`、`tools/*.mjs`)
- `connector/`(DSH 插件,pnpm 工程;工程形态与版本策略见 `.agents/notes/implemented/2026-10-01-connector-workspace-shape.md`):
  - `cd connector; pnpm install` —— 装依赖,**必须 0 退出**(见 Pitfalls 的构建脚本闸)
  - `pnpm exec tsc --noEmit` —— 类型检查(开工步骤第 2 步的判据)
  - `pnpm build` —— tsdown 产出 `lib/index.js` + `lib/index.d.ts`,即装进 profile 的那份产物;路径对齐靠 `connector/tsdown.config.ts`
  - `pnpm test` —— 跑 `protocol/fixtures` 与 `protocol/vectors`,外加握手/封箱/流控/连接/身份等接线用例(当前 **117 项**;其中 fixtures 的断言数须与 `verify-fixtures.mjs` 的 486 一致、向量的与 `verify-vectors.mjs` 的 49 一致)
- 图标重新抽取(DSH 升级后):`node mock/proto/tools/extract-dsh-icons.mjs`
- 关键入口:`mock/proto/index.html`(原型唯一入口);`app/lib/theme/dsh_theme.dart`(Flutter 主题)
- 只读参考源码:DSH `C:\sudy\github\deepseek-harness`;Agents-Anywhere `C:\sudy\github\Agents-Anywhere`;rikkahub `C:\sudy\github\rikkahub`
- DSH 侧高信号入口(只读):
  - 开发者文档 <https://deepseek-harness.github.io/deepseek-harness/reference/> —— 子系统 `reference/subsystems/web-server`、`web-client`、`client-modules`;另有 `develop/basic/`、`guide/quickstart`
  - 架构决策笔记金矿 `C:\sudy\github\deepseek-harness\.agents\notes\archived\architecture\`:`2026-07-19-gui-layering-and-rpc-protocol`(GUI 分层与 RPC 协议)、`2026-07-23-unified-session-query-service`(统一会话查询服务)、`2026-07-25-web-command-surfaces-and-assembly`(命令面与装配)、`2026-07-25-web-input-machine-and-slash-pipeline`(输入状态机与 slash 流水线)、`2026-07-28-user-settings-seam`(用户设置缝)。每篇都带 `.zh.md`

## Patterns

- **先查源码再动手**:任何"DSH 是怎么做的"问题,先 grep 出 `packages/...:行号` 再改代码;结论写进 `docs/`,不留在对话里。
- **验证脚本是规格**:行为改动先改/加断言,再改实现,最后跑全绿。
- **结构照 DSH,形态按触屏**:能照抄就照抄;触屏不适用时有意偏离,并在方案文档写明原因。
- **纯浏览器原型**:`mock/proto/` 无构建步骤,双击 `index.html` 即可验证;所有交互用 Pointer Events 手写,便于真机触屏复现。
- **跨模块只走注入的 api**:`interactions.js` 不裸调 `app.js` 私有符号。
- **批量改文档用「临时 `node` 脚本 + 每处断言恰好命中一次」**:比手写多次替换稳;命中数不等于预期就报错退出,避免静默改错行。

## Pitfalls

- **装进 profile 试跑的正确姿势(实测)**:
  - `dsh plugin --profile <名字> add <本地路径>` 会自动建 profile 并把包加进 `dsh.profile.bundles`(`link:` 到本地);**注意 `dsh plugin --profile x --help` 也会顺手建出 profile** —— 只想看帮助也会留下目录。
  - `dsh --profile <名字> --dump-config` 组合 profile 树并退出,**不打日志也不起服务**,适合验"有没有被跳过"。看不到 `skipping profile bundle` 就是兼容性检查通过了。
  - **`@deepseek-ai/dsh-base` 里没有 `sessionController`** —— 它由 `@deepseek-ai/dsh-web-app` 带来。所以只装 base 的 profile 会让依赖会话服务的插件停在 `pending (waiting for service: sessionController)`。
  - **`dsh --profile <名字>` 不带 app 参数会真的把 app 跑起来**:web 栈会起 web 服务并**自动打开浏览器**。想只验证挂载就加超时并自己终止,别让它自己跑。
- **`inject` 缺服务不是静默的**(我先前判断错了,已按实测改正):DSH 会打 `dsh: warning: 1 entry did not activate` 加 `pending (waiting for service: <键名>)`。所以它可查,只是那行容易被启动日志淹没 —— 插件仍值得自报一遍健康。
- **cordis 的 `Volatile<T>` 是稳定引用,不是值**:Schemastery `.volatile()` 字段的类型是 `{ get(): VolatileSnapshot<T> }`(`@deepseek-ai/cosmokit` 的 `volatile.d.ts:7-10`),所以 `config.relayUrl` **不能当字符串用** —— 直接比较会得到 `TS2367 两个类型没有重叠`。正确写法是 `config.relayUrl.get()`,而且文档明说「保留引用,或为单次操作取值」:要热改就得每次重读,要一次性用就取一次(取了之后改动不会自动生效,连接也不会自己换地址)。
- **`ctx.logger` 是服务,不是 logger 实例**:要 `ctx.logger(name)` 取具名 logger(`vendor/cordis/src/context.ts:27-28`);方法签名是 **printf 风格** `(format, ...params)`,不是 `(message, detail)`。本插件在 `observability.ts` 里收成两参数形状(`%s` / `%O`),免得每个调用点都记占位符、或者 detail 忘了格式化被吞掉。
- **「两侧各算一遍」的协议,必须有一条真的跑两侧、比对同一结果的测试**:实测踩过 —— X3DH 的三份共享密钥是**角色相关**的:`ss1` 的定义是「发起方临时 × 应答方静态」,而同一个 DH 表达式 `DH(自己的临时, 对端的静态)` 在发起方算出的正是 `ss1`、在应答方算出的却是 `ss2`。派生函数不传角色就无从决定拼接顺序,而顺序反了**不会报错**:两侧各算出一把主密钥,握手看起来走完,AEAD 永远解不开。**这类错误向量测试抓不到** —— 向量的输入是四个种子,形状本身就绕开了"谁在哪个位置"。所以凡是"两侧各算一遍"的协议,要有一条真的跑两侧、比对同一结果的测试;只验单侧输入输出的测试在这里是无效证据。
- **封箱必须和 `fc` 的分配挨着**,否则必然出现"封的时候用了另一个 `fc`"或"同一个 `fc` 封两次" —— 后者是 nonce 重用,直接破 AEAD。做法:连接层在 `write()` 里先分配 `fc` 再立刻封箱,并让驱动器/上层只看到明文 `box`;`box.ts` 另设一道"同一个 `fc` 不许封第二次"的绊线,变异校验 ⑯⑱ 覆盖了这条链路。
- **握手之后的每一种帧都要认证,包括"没有内容"的控制帧**:`fc` 在 AAD 里,不认证就等于让未认证的数字驱动重放窗口;`credit` / `persisted` 还会改对端状态(放宽发送窗口 / 允许裁剪缓冲)。QUIC 与 TLS 1.3 都没有"握手后的明文控制帧"这一档。**顺序是硬规则:先验签、后推进 `maxFc`** —— 反过来,一帧伪造的 `fc=10^9` 就能把后续所有合法帧判成重放(症状是连接被自己人反复关闭)。
- **AEAD 认证失败要转成协议错误码,别让 `node:crypto` 的裸错误漏到协议层**:调用方按 `instanceof ProtocolError` 分类,漏出去就会把"这一帧不该被接受"归到"未归类内部错误"。注意**只有单测能盯住这件事**:连接层对非协议错误统一按 `protocol/bad-frame` 关闭,e2e 看不出类型差别(变异校验 ⑲ 的证据)。
- **9222 端口不可用**:本机日常 Chrome 占用它,CDP 探测返回 `404 page not found`。用 `cdp.ps1` 换端口(默认 9400);9400 也可能被上一轮遗留的 headless Chrome 占着,开新端口前先探 `http://127.0.0.1:<port>/json/version`。
- **pnpm 的严格隔离下,给一个「DSH 包也依赖的库」钉不同版本会装出两份副本,类型不互通且运行时炸**:实测 `@deepseek-ai/dsh-storage-domain` 的 `domainTable(schema)` 只接受**它自己那份** zod 的 `ZodType`;我们直接声明 `zod@^4.4.3` 会装成 4.4.3,而它解析到 4.6.5 —— 症状是 `tsc` 报一长串 `def.checks are incompatible between these types`(路径里同时出现两份 zod),运行时则是 `Cannot read properties of undefined (reading 'safeParse')`。修法:在 `connector/pnpm-workspace.yaml` 用 `overrides` 钉死版本(`zod: 4.6.5`),让全树共用一份。**判断依据看 `pnpm-lock.yaml` 里有几个 `zod@x.y.z` 条目,不要看 `.pnpm/` 目录**(那里会留无引用的旧副本)。
- **行级协议的「分隔符由谁负责」必须只有一个答案,而且要靠端到端测试兜**:实测踩过 —— `encodeFrame` 没输出 `\n`,而 `createLineSplitter` 按 `\n` 切分并把最后一段当**半行**留着,于是**每一帧都被永久缓冲,对端永远收不到**。阴的是**单元测试抓不到**:`decodeFrame(encodeFrame(x))` 照样过(`JSON.parse` 容忍尾随空白),分帧测试也自己喂了 `\n` —— 两边各自自洽,合起来才断。修法是把分隔符放进编解码层(`encodeFrame` 带 `\n`),并补一条真的起 WebSocket 服务端、收发真帧的端到端用例。教训:**两个零件各自测过,不等于接起来能跑**。
- **`fc` 的分配权属于连接层,不属于调用方**:`fc` 是每连接的帧计数器、也是 nonce 来源;让上层决定它等于给上层机会重用 nonce,而重用 nonce 直接破 AEAD。做法是把待发帧类型定义成 `Omit<WireFrame,'fc'> & { fc?: number }`(注意内置 `Omit` 会把联合塌平,要写分配式版本),发送时统一盖上;并且**每次建连都换一个新的计数器**(新连接新密钥,`fc` 从 0 重数)。**握手三帧是例外**:它们的线上形状里没有 `fc`(§3),给它们盖一个不但白白消耗计数值,还让线上帧与契约形状不一致 —— 所以 `write()` 按帧类型分支(`isHandshakeFrameType`),并由 e2e 断言"握手后第一帧业务帧的 `fc` 仍是 0"。
- **心跳不能重置空闲计时,否则半开永远判不出来**:半开判据是"任一方向连续 2 个周期无帧",而 `keepalive.tick()` 在发 `ping` 时已经为它重置过一次(`pingedInThisIdle` 保证一个空闲期只探一次)。若调用方在 `write()` 里对**所有**出站帧都调 `onFrame`,每周期都会重发 ping、沉默时间永远攒不满两个周期 —— 表现是**连接死了也永不重连**。正确写法是"发帧重置,`ping` 除外",两半各有一条 e2e 盯着(变异校验 ⑮ 就是拆掉这个例外)。
- **握手期一帧都不发,所以测试里别用真实心跳周期**:`connection.test.ts` 早先有一条用例用 `heartbeatMs: 40`(半开阈值 80 ms),而握手要等测试调 `markHandshakeDone()`;机器一忙,连接会在握手走完之前被判半开并重连,用例随机变红。**接线类用例一律把心跳拉到 5 s**,把半开单独交给"故意用短心跳"的两条用例。
- **凭据记录面是"载荷由拥有者解释"的地方,不是配置项**:`ctx.credentials` 的 `CredentialKey` 面(`credentialKey(scope,id)` → `readRecord` / `modifyRecord`)存的是 `GrantRecord.payload`,按定义只有拥有者能解释它 —— 自持密钥(如本插件的主种子)该落这里,而**设置面天然带读**(`describe` 会返回 `value`),配置文件更是明文。两个配套纪律:写入走**唯一**的 `modifyRecord`(读-改-写在一把锁里,并发首启以回调返回的那条为准),以及**读到读不懂的记录一律抛错、绝不覆盖**(覆盖等于把所有已配对设备一次性作废,而症状只是"手机连不上")。
- **`defineDomain` 的三条规则在模块加载期就抛**:域名/表名必须匹配 `^[a-z][a-z0-9_]*$`(**不允许连字符**,与 `CredentialKey` 要求的"必须有连字符"正好相反)、`version` 必须是非负整数、**global schema 不得接受 `null`**(null 是后端「从未写过」的哨兵,可空的 global 重开时会被静默当成没写过)。另外 `global` 不是裸 schema,是 `{ schema, initial }`。
- **pnpm 的构建脚本审批闸拦的是每一次 `pnpm exec` / `pnpm run`,不只是 install**:`esbuild`(经 `tsx` 传入的传递依赖)的 postinstall 未获批准时,pnpm 在跑任何脚本前会内部重跑 install 并以 `ERR_PNPM_IGNORED_BUILDS` 退出 1 —— **连 `pnpm exec tsc --noEmit` 都跑不起来**,容易误判成"依赖装坏了"。审批结果记在 `connector/pnpm-workspace.yaml` 的 `allowBuilds`(不是 package.json;`pnpm.ignoredBuiltDependencies` 是旧写法,pnpm 11 不认,写了也不生效)。非交互地记为拒绝:`pnpm approve-builds '!esbuild'`。**实测:记为拒绝后 `tsx` / `esbuild` 照常可用**——平台包 `@esbuild/win32-x64` 是独立安装的,postinstall 只做校验;所以没有理由为它放行任意构建脚本。
- **tsdown 在 `platform: 'node'` 时默认输出 `.mjs` / `.d.mts`**:`fixedExtension` 默认为 true,产物是 `dist/index.mjs`,与文档声明的 `lib/index.js` 对不上——装上后 `main` / `exports` 指向一个不存在的文件。用 `outExtensions` 覆盖(见 `connector/tsdown.config.ts`)。验证方式不是"能编译",而是 `node -e "import('./lib/index.js')"` 真能加载出 `apply` / `Config`。
- **`cdp.ps1` 跑完不会自己关浏览器 —— 端口被占的根因**:脚本 `Start-Process` 起 headless 之后既不等待也不停止(`-KeepOpen` 只决定要不要拿 `-PassThru` 的那个对象),`%TEMP%\proto-cdp-*` profile 也从不清理。所以**每跑一轮验证就漏一个 headless + 约 500 个文件的临时目录**,端口就这样被逐个占满(实测 9400 与 9410 各挂了一个)。收工清理,只匹配 `proto-cdp` 因此不会碰日常浏览器:

  ```powershell
  Get-CimInstance Win32_Process -Filter "Name='chrome.exe'" |
    Where-Object { $_.CommandLine -match 'proto-cdp' } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force }
  Get-ChildItem -Directory $env:TEMP -Filter 'proto-cdp-*' | Remove-Item -Recurse -Force
  ```

  停止的判定:`Get-NetTCPConnection -State Listen -LocalPort 9400` 无输出 = 已释放。
- **代理会拦 localhost**:若环境有 HTTP 代理,CDP 请求会被拦成 404;跑脚本时带 `NO_PROXY=127.0.0.1,localhost`。
- **PowerShell 里的 Node 内联脚本会被转义搞坏**:多行 `node -e "..."` 遇中文/引号易碎,改为写临时 `.mjs` 文件再跑。
- **手改 `styles.css` 曾截断规则**:改完必须确认 `{` 与 `}` 计数相等,并用浏览器跑一次 `verify-proto.mjs`。
- **`openSheet` 切 sheet 的返回栈竞态**:不要"先 close 再 open"(异步 popstate 会把新开的 sheet 弹掉),`openSheet` 内部复用同一层。
- **`.page--side` 必须挂过渡**:漏了就没有抽屉动画,视觉上是"啪一下"。所有从右滑入的全屏页(`.page--settings` / `.page--tasks`)都要列进 `.motion ...` 那份过渡名单,否则整页瞬移。
- **从抽屉切全屏页要同步摘掉 drawer 层**:`settings-open` / `tasks-open` 都必须 `D.set(0, true)` + `closeLayer("drawer", true)`;漏了页面会开在没收起的抽屉后面,还留下 `drawer` 幽灵层。
- **覆盖 `.btn` 的 `flex` / `min-height` 必须带 `.btn` 前缀**:`.btn` 在样式表里更靠后,同权重下会盖掉前面对 `.xxx-new` 的覆盖(表现是筛选行被挤到换行)。
- **别用 `scrollWidth` 判断文字有没有换行**:换行后并不横向溢出,要数文本节点的 `Range.getClientRects().length`。
- **`[hidden]` 会被 `display:flex` 盖掉**:组件级 `display` 规则要配 `[hidden]{display:none!important}`。
- **`engines.dsh` 不参与任何判定**:DSH 插件兼容性看 `peerDependencies` 对 `@deepseek-ai/dsh*` 的范围,不匹配会**静默跳过**并记入 `skippedBundles`(`packages/util/package-manifest/README.md:93`、`packages/boot/app-boot/src/plugin-compatibility.ts:68`);写 `engines.dsh` 既不报错也不拦截
- **DSH 引用行号会漂移**:改文档时顺手核对被引行是否仍指向该内容(已发生过 §7.5 密钥原则从 :313 漂到 :366)。
- 血泪史条目见 `docs/postmortem/`;此处只留结论。
