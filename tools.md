# dsh-mobile Tools

## Concepts

- 本文件记录项目协作知识,不替代正式设计文档、`docs/` 或当前代码。
- 真值优先级:`docs/design-and-tech-plan.md`(总纲)> 三份 `docs/*-notes.md`(专项)> 可跑通的验证脚本 > 本文件。
- 主链路:改 `mock/proto/` → 跑验证脚本 → 截图 → 同步 `app/`(Flutter 落地端)。
- 本仓库**没有 CI**;`mock/proto/`、`protocol/`、`app/tools/` 全是显式 `node` 脚本,不存在 `npm test` 这类约定命令。**例外:`connector/` 是 pnpm 工程**(见下),它的命令走 `pnpm exec` / `pnpm test`。
- **`relay/` 也是工程,不需要构建**:`cd relay; pnpm install; node --test` 直接跑(**75 条**)。它靠 Node 的**类型剥离**(≥22.6,本机 24.13)运行,所以**导入写 `.ts` 结尾**——Node 不做 `.js` → `.ts` 映射(写 `.js` 报 `ERR_MODULE_NOT_FOUND`,实测)。**`ws` 是运行时依赖,必须先 `pnpm install`**(`tests/server.test.ts` 起真服务器,缺 `ws` 直接 `ERR_MODULE_NOT_FOUND`);类型检查 `cd relay; pnpm typecheck`。**别把 relay 的导入"顺手统一"成连接器那样的 `.js`**:连接器是插件(要产物,tsdown 打包),中转是独立服务(直接 `node src/main.ts` 起),两者运行时不同。
  - **令牌 CLI 只签连接器**:`--issue-token connector <id>` / `--revoke-token connector <id>`。设备令牌**不由中转签发**(电脑侧签、摘要经 `POST /devices` 进名册),所以 CLI 收到 `device` 明确退出 2;摘要表里残留 `device` 条目也**拒绝启动**。取舍见 `.agents/notes/implemented/2026-10-09-relay-never-issues-device-tokens.md`。
- **`/ws-ticket` 有两种凭据形态**(配对 v2 的引导,见 `docs/subsystems/pairing-v2.md` §3):body 带 `v:2` + `offerId` + 候选公钥 + 设备名 = **首配**(凭**公开邀请**,无令牌;票绑候选与用途 `pairing`,带候选元数据),body 为 `{}` = **重连**(凭设备令牌;票绑名册里的真实设备 + 它的连接器)。**两种都吃限流桶,桶键都不是 IP**(候选是"匿名 + 每张邀请"两级;见 memory.md 的已知缺口 2)。**旧形状(`codeHash`)被回 426**(`pairing-version-unsupported`)。设备名册走 `POST /devices`(连接器令牌,只交**摘要**)。

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

- 多端边界校验(不需要 Flutter 工程):`node app/tools/verify-platform-boundary.mjs` —— 扫描 `app/lib` 与 `app/packages`,共 6 条规则:  1. `core-no-platform-import`:`app/lib/{core,data,model}` 禁 `dart:io` 与 `package:flutter/{services,widgets,material}.dart`(否则纯 Dart 单测写不了)
  2. `ui-no-impl-import`:`app/lib/ui` 禁 import 各端实现包(`*_(ios|android|ohos)/`)
  3. `ui-no-platform-import`:`app/lib/ui` 禁 `dart:io`
  4. `branch-whitelist`:平台分支(`Platform.` / `defaultTargetPlatform` / `MethodChannel` / `EventChannel`)只允许出现在 `app/packages/**`、`app/lib/platform/**`、`app/lib/ui/adaptive/**`
  5. `no-platform-isohos`:全仓禁 `Platform.isOhos`(会导致 `flutter run` / `build har` / `attach` 失败,鸿蒙判断用 `defaultTargetPlatform`)
  6. `fallback-not-in-release`:`app/lib/platform/registry.dart` 引用兜底实现(`InMemory` / `NullPush` / `Noop`)必须带 `kDebugMode` 守卫

  **两条 import 规则只认 `import` / `export` 指令本身,不按正文 grep** —— 否则文件头那句「不许 import `dart:io`」会被自己判成违规(等于惩罚把规则写进代码)。自带规则自检 **22** 条,所以 `lib/` 还没代码时也不是空转(当前输出:`规则自检 22 条 + 扫描 50 个 Dart 文件` = **182 项**)
- 通道协议验证(不需要浏览器/手机/公网):`node protocol/verify-fixtures.mjs` —— 16 条 fixture / 486 项断言(两种结果规则、快照水位与分页、待审批重建、live 帧不入账);`node protocol/verify-loopback.mjs` —— 26 项,手机 ⇄ 中转 ⇄ 电脑侧桥接回环(含"中转状态清空后重启"与强制走桥接分支的 `5b`)。改 `protocol/` 后两条必须全绿;`DSH_DEBUG=1` 可打印每条恢复应答
- 变异校验(验证断言不是恒真,不碰仓库):把 `protocol/` 复制到临时目录后注入,再跑两个脚本。**参考侧实测基线**:① `reference/relay.mjs` 去掉 `seq !== expected` → fixtures 红(仅 `07`);② `reference/bridge.mjs` 的 `hello` 返回空 `transient` → fixtures 红(`09`)**且回环红(`5b`)**;③ `reference/takeover.mjs` 去掉"前台且订阅"过滤 → fixtures 红(6 条,`16`)
  - **connector 侧实测基线**(直接改 `connector/src/protocol/` 后 `git checkout --` 还原,同法可复用):④ `recovery.ts` 的 `hello` delta 返回空 `transient` → 2 项红,全在 `09`;⑤ `takeover.ts` 去掉"前台且订阅"过滤 → 6 项红,全在 `16`;⑥ `crypto.ts` 的 `deriveHandshake` 从 `ikm` 去掉 `ss3`(破坏前向保密)→ vector 测试 3 项红,恰好是 `master` / `kA2B` / `kB2A`(断言数不变);⑦ `transport/keepalive.ts` 把 `halfOpenAfterMs` 设成 `Infinity`(关掉半开检测)→ 2 项红,恰好是那两条断言半开的保活用例;⑧ `lifecycle.ts` 的 `unwind` 改成"遇错即停"(不再收集)→ 1 项红,恰好是「dispose 尽力而为」那条;⑨ `transport/codec.ts` 的 `assertHandshakePhase` 直接 `return`(拆掉握手门禁)→ 1 项红,恰好是「握手门禁」那条;⑩ `protocol/methods.ts` 把幂等键强制那条 `if` 短路成 `if (false)` → 1 项红,恰好是「漏键时在分发前被拦」;⑪ `alias.ts` 的 `reconcile` 开头加 `if (true) return 0`(变空操作)→ 2 项红,恰好是那两条构造"崩在中间"状态的用例(而「干净状态」那条正确地仍通过);⑫ `protocol/handshake.ts` 的 `verifySignature` 开头加 `if (true) return`(验签永远通过)→ 3 项红,恰好是三条断言"该拒"的用例(而「正确签名通过」那条正确地仍通过);⑬ `transport/codec.ts` 的 `HANDSHAKE_FRAME_TYPES` 去掉 `'confirm'` → **4 项红**:`isHandshakeFrame` 判据、握手门禁、连接级 e2e 两条(而驱动器单测正确地仍全绿 —— 门禁是连接层的职责,不归驱动器);⑭ `protocol/handshake-driver.ts` 里 `verifySignature(...)` 换成 `void 0`(验签永远通过)→ 2 项红,恰好是「签名是别人签的」与「伪造 confirm 的 e2e」两条,而"正确签名通过"的两条仍绿;⑮ `transport/connection.ts` 的 `write()` 去掉 `frame.t !== 'ping'` 这个例外(让心跳也重置空闲计时)→ 1 项红,恰好是「完全空闲仍会判半开」那条 —— 而它红的方式是**超时**:半开再也判不出来;⑯ `protocol/box.ts` 的 `openFrame` 把 `guard.accept(fc)` 提到解箱之前(守卫先于认证推进)→ 6 项红,含「先验后进:伪造的 fc 推不动重放窗口」与 e2e 那条「同一帧重放」;⑰ `transport/connection.ts` 的 `handleFrame` 里把 `cipher !== null && needsBox(...)` 短路成 `false &&`(永不收箱)→ 4 项红:手机封电脑解、篡改、重放、缺 box 四条 e2e;⑱ `protocol/box.ts` 把方向映射写死成 `kA2B`/`kB2A`(不再按角色)→ 7 项红,含两个方向的 e2e(而"同向自解"的用例正确地仍绿);⑲ `protocol/crypto.ts` 的 `open` 去掉 `ProtocolError` 包装(让 node:crypto 的裸错误漏出去)→ **2 项红,全在单测**(`AAD 绑定`、`先验后进` 断言的是错误码),而 e2e 的篡改用例**仍绿** —— 因为连接层把非协议错误统一按 `protocol/bad-frame` 关闭,分不出类型。这条正好说明:**错误码的正确性只有单测能盯住**;⑳ `protocol/flow.ts` 的 `canSend` 去掉优先级例外(满窗时连 `res` 也压住)→ 2 项红:「满窗时 res 照发」e2e 与流控单测;㉑ `transport/connection.ts` 的 `accountFlow` 里把 `if (elicitsCredit(frame.t))` 改成 `if (true)`(连 `credit` 也回执)→ 1 项红,恰好是「credit 自己不再回 credit」那条。**㉑ 第一次跑时是全绿的**:当时这条规则被"早返回 + 谓词"写了两遍、谓词是死逻辑;改成两个并列 `if` 后,同一个变异立刻命中。结论:**变异不红时先怀疑测试或重复逻辑,而不是记一笔"覆盖不到"**;㉒ `method-face.ts` 的 `resFrame` 把 `id` 写成固定值(不回带请求 id)→ 4 项红(两条 e2e + 单测两条),关联一断手机就永远等不到回应;㉓ `method-face.ts` 的解信封 try/catch 改成 `throw`(载荷错误直接抛)→ 2 项红:单测「载荷坏」与 e2e「载荷不是 JSON」—— 而且 e2e 那条红的方式是**连接被关**,正好证明"结构化错误不关连接"这条判据是真的;㉔ `handlers.ts` 的 `repo.info` 把 `methods` 写死成 `['repo.info']`(手抄清单)→ 2 项红:单测「报的必须是表的键」与 e2e 那条;㉕ `idempotency.ts` 去掉 `if (envelope.ok)` 判断(失败也记进表)→ 1 项红,恰好是「失败不进表:第二次仍会真的执行」;㉖ `idempotency.ts` 的 `rows.get(requestId)` 恒当未命中(不查缓存)→ 4 项红:两条单测 + 方法面那条 + **e2e 的 I8 用例**(真实重发被算了两次);㉗ `method-face.ts` 去掉 `requiresIdempotencyKey` 判断(只读方法也进表)→ 1 项红,恰好是「只读方法带键也不进表」;㉘ `idempotency.ts` 的惰性过期判断改成 `if (false)`(过期条目照旧当命中)→ 1 项红,恰好是「惰性过期:过期条目按未命中处理」;㉙ `dsh/sessions.ts` 的 `list` 改成 `{ ...item }`(spread 整个 DSH 行)→ 1 项红,恰好是「只映射该映射的字段」;㉚ `handlers.ts` 的 `session.list` 改成 `{ sid, ...row }`(把适配器行整个发出去)→ 2 项红:单测那条与 e2e 的「DSH 会话 id 不过线」;㉛ `alias.ts` 的 `ensure` 去掉同键合流 → 1 项红,恰好是「并发 ensure 合流成一个 sid」。**㉛ 第一次跑时全绿**:不是用例没写,而是替身不忠实 —— 内存表的 `put` 被写成同步改内存,而真实域表是"先落盘、再改内存"(单写链),那个 await 边界正是并发撞车的窗口。给替身补上这个边界后同一变异立刻命中。教训:**测并发的替身必须保留真实介质的时序特征**;㉜ `dsh/jobs.ts` 的 `listOwnedBy` 去掉"排掉无主"的 filter → 1 项红;㉝ `dsh/jobs.ts` 的 `readAt(id, from, caller)` 把 caller 与 from 对调 → 1 项红;㉞ `dsh/jobs.ts` 的 subscribe 恢复成旧的 output 放行(无主 output 不排)→ 1 项红,恰好是「无主事件两种形状都要排掉」——**这条变异保护的正是本轮修掉的那个真缺陷**;㉟ `dsh/settings.ts` 的 `describe()` 不传 `redactSecrets` → 1 项红,恰好是「必须传 redactSecrets」;㊱ `dsh/settings.ts` 的 `setField` 改用 `replace` → 1 项红,恰好是「绝不走 replace」;㊲ `dsh/subagents.ts` 去掉 `kind === 'diagnostic'` 分支(让诊断行走 child 分支)→ 1 项红,恰好是「联合拍平」那条。**㊲ 第一次的变异是错的**:把诊断行原样展开(`{...entry, parentId, depth}`)语义没变,自然全绿 —— 换成真实失效形状(诊断行带 undefined 的 child 字段)后立刻命中。教训:**变异必须改变语义,不只是改变写法**;**还有第三种"绿得不是地方":用例可能被别的路径满足** —— 「窗口松开必须唤醒」的第一版是 `await pending` + 断言 `resumed === true`,而 ㊼ 变异**没让它红**(它跑了 16 秒,被**连接自己断开**时的另一处兑现唤醒,断言照样成立)。修法:**有界等待**(`Promise.race` 500 ms)+ 断言唤醒发生在连接**还活着**时(`state === 'serving'`,且醒来后重发那一帧要被接受),改完同一个变异 0.9 秒内精确红。三次同类教训的共同点:**证据本身要被质疑** —— 断言要表达"我关心的那条机制",而不是"最后有没有个好结果"㊳ `handlers.ts` 的 `requireSession` 未知别名不再抛错(返回空串)→ 2 项红(单测 + e2e 的 not-found);㊴ `handlers.ts` 去掉 `sid` 形状检查 → 1 项红,恰好是「sid 缺失或形状不对 → bad-frame」;㊵ `handlers.ts` 的 `if (deps.jobs !== undefined)` 改成 `if (true)`(缺服务也挂 `job.list`)→ 2 项红,含「可选服务缺了:`job.*` 干脆不在表里」;㊶ `dsh/jobs.ts` 的 `createJobControlPort` 不再把 `job/not-found` 转成协议码 → 1 项红(适配器那条);㊷ 把**一切**错误都伪装成 `job/not-found` → 1 项红,恰好是「producer 的取消抛错不得伪装」—— 这条正是宿主注释里那句 "instead of masquerading as job-not-found";㊸ `handlers.ts` 去掉 `jobId` 形状校验 → 1 项红;㊹ `handlers.ts` 用 `deps.jobs` 的存在与否来挂 `job.kill`(把两种能力混成一种)→ 5 项红,含「两种任务能力可以独立缺失」。㊺ `protocol/frame.ts` 的 `FRAME_TYPES` 去掉 `'job'` → 1 项红(清单与契约逐项相等那条);㊻ `flow.ts` 的 `pausable` 去掉 `'job'`(不再可暂停/攒批)→ 3 项红(含「满窗时 job 也必须被拒绝」);㊼ `connection.ts` 窗口松开处不再 `notifyWritable()` → 1 项红(0.9 s 内——见下面那条教训);㊽ `connection.ts` 离开服务态处不再 `notifyWritable()` → 1 项红(0.76 s);㊾ `job-subscriptions.ts` 去掉 `follow` 的幂等分支(每次重开流)→ 1 项红(「同一个任务重复 follow 不重开流」);㊿ `job-subscriptions.ts` 的 `finally` 去掉 `if (isCurrent())`(无条件清表)→ 1 项红(「换起点」那条 —— 新订阅被旧循环收尾时误删);(51) `job-subscriptions.ts` 卡在 `waitWritable` 时不再检查 `aborted` → 1 项红(「卡在满窗等待时被收起」);(52) `handlers.ts` 去掉 `from` 形状校验 → 1 项红;(53) `tests/support/secure-connection.ts` 去掉离开服务态时的 `stopAll()` → 1 项红(e2e「连接断开时任务输出订阅全停」)。**另有两条变异没红并被正确处理**:`job-subscriptions.ts` 的**外层**"是不是当前订阅"判据删掉后无红 —— 追查发现它不可达(替换/收起/停止三个入口都会 abort,而迭代器在 `next()` 里就中止),按"不留不可达防御代码"删除,并把承重的 `finally` 判据与"卡在满窗时被收起"补成会红的用例。(54) `session-subscriptions.ts` 开启快照的 `records` 不再展开成 `ev`(补课事件静默丢掉)→ 2 项红(单测 + e2e);(55) `session-subscriptions.ts` 的 `streamIdOf` 一律返回 1(换尝试不换流号)→ 1 项红;(56) `handlers.ts` 去掉 `since` 形状校验 → 1 项红。**另有一条在重构中被测试抓住的语义合并**:抽订阅骨架时,"宿主抛错"与"有序结束却没终止帧"被合并成同一条 tail 帧,而两者给手机显示的话不同 —— 骨架因此加了 `onError`,与 `onEndWithoutTerminal` 分开(这就是"重构时旧测试不许改"的价值)。④⑤⑥⑦⑧⑨⑩⑪⑫⑬⑭⑮⑯⑰⑱⑲⑳㉑㉒㉓㉔㉕㉖㉗㉘㉙㉚㉛㉜㉝㉞㉟㊱㊲㊳㊴㊵㊶㊷㊸㊹㊺㊻㊼㊽㊾㊿(51)(52)(53) 与参考侧基线 ②③ **逐条对上**。
- 会话规模标定(只读 DSH 仓库,用于标定重放窗口与帧上限):统计 `D:\sudy\github\deepseek-harness\snapshots\**\*.jsonl` 的事件数 / turn 数 / 单事件字节(结果:中位 21 事件/turn、单事件 max 7 KB、最大会话 99 事件,见 `docs/channel-review-notes.md` §6)
- 跨端密码学向量:`node protocol/tools/gen-vectors.mjs` 机生成(用 `node:crypto`,勿手改产物),`node protocol/verify-vectors.mjs` 重算比对(**49 项**:握手派生 10 字段 + 设备身份 4 字段 + 身份两把密钥不同 1 + transcript 拼串与签名 3 + AEAD 5 条 × (密文/标签/**箱容器**/容器往返/解密往返) + 篡改拒绝 3)。**两侧实现各自跑同一批向量**,`connector/tests/vectors.test.ts` 的断言数必须与它相等(不等就是抄漏了断言)
- 图标集校验(不需要浏览器):`node mock/proto/tools/verify-icons.cjs`
- **手机端 `app/`(Flutter 工程;`flutter` 装在 `D:\soft\flutter`,已进用户 PATH)**:
  - **版本闸门:锁 Flutter `3.41.9`**(上界由鸿蒙 fork 定,`app-platform-boundaries.md` §4)。当前上游 stable 是 3.47.6,**不许装** —— Dart SDK 版本决定语言特性,升上去等接鸿蒙时要回改一大片。自带 Dart 3.11.5。
  - `cd app; flutter test` —— 跑 `test/`,当前 **340 项**:core 单测(含封箱判据/握手门禁/恢复判定等)+ 连接层(状态机/退避/心跳半开/箱与握手/接线 e2e/outbox/LiveAccumulator/断连拒绝在途请求/落盘与 persisted)+ 平台层(真 socket)+ 配对(跨端向量:SAS/pairingId/设备标识/**握手上下文**)+ **配对客户端(状态码 → `ClientAction`,含 426 → 升级)** + **候选身份与上下文形状** + **配对通道 9(真驱动一个电脑侧替身:握手两帧、秘密只在密文里、`fc` 从 0 起、`pong` 回显)** + **配对编排(两段:确认前不发秘密)** + **带票传输(换票失败如实抛)** + **地址边界(升级 URL 形状 / 只认 wss)** + 图标(含**数像素**)+ **本地库(同一套断言在 sqflite 与内存实现上各跑一遍)** + 装配不变量 + 界面 + 跨端向量 + fixtures 三角色回放
  - **配对链的纯 Dart 单测**(`pairing_client_test` / `pairing_exchange_test` / `pairing_flow_test` / `pairing_channel_test` / `pairing_vectors_test` / `ticketed_transport_test` / `endpoint_test`)是**客户端动作**的判据:状态码错了用户就永远卡在重试上(踩过一次 `not-paired` 报成 `bad-frame`)。它们不需要中转 —— `HttpSender`、传输与"电脑侧那一半"(`test/support/fake_pc.dart`)都是注入的缝。**注意替身必须按序处理帧**(Dart 的密码学是 `Future`,真电脑侧是同步派生;不排队会让 `pair-commit` 插到 `confirm` 前面,伪装成"手机侧提交太早")。
  - `cd app; flutter test integration_test/ -d emulator-5554` —— **真机/模拟器组**(当前 4 项):验 `flutter_secure_storage` 真的落到设备密钥库(2)+ `sqflite` 在**设备原生 SQLite** 上建表/落盘/重开还在(2)。**纯单测做不了这个**(插件在 Dart VM 里没有实现,调用会抛 `MissingPluginException`;而单测里的 sqflite 走 ffi,不是同一个驱动)。需要 `ANDROID_HOME`/`JAVA_HOME` 都在环境里,否则报 `Could not locate aapt`
    - 另外两条**需要真中转 + 真机**、不给前置就自动跳过:`integration_test/channel_e2e_test.dart`(两段配对 → 令牌落 Keystore,跑法见 `docs/cookbook/next-session-real-device.md`)与 `integration_test/pairing_flow_test.dart`(连不上时如实报错 + 密钥库往返)
  - `cd app; dart analyze --fatal-infos lib test integration_test` —— **社区口径的静态检查**(比 `flutter analyze` 严:把 info 也当失败)。0 问题才算干净
  - `cd app; dart format --output=none --set-exit-if-changed lib test integration_test` —— **Dart 社区硬规范**(Flutter CI 一直拿它当门禁)。`--set-exit-if-changed` 是判据,不是"看一眼"
  - `node app/tools/gen-pairing-vectors.mjs` —— **重新生成配对向量**(调真实的 `connector/src/pairing.ts`)。改了配对派生规则后必须重跑,否则 fixture 与实际实现脱节
  - `node app/tools/make-pairing-qr.mjs` —— 出一份**真的**二维码载荷(给模拟器喂数据/手工排查用)
  - `cd app; flutter pub get` —— 装依赖(`cryptography` 是唯一的非 SDK 依赖)
  - `cd app; flutter run -d windows` —— **桌面调试**。本机 VS 18 + MSVC + Windows SDK 齐全,所以 UI 与状态机**不需要模拟器、不需要真机**
  - lint 规则集在 `app/analysis_options.yaml`,**每条都写了它针对的具体失败模式**(不是"更严格就好");改它要连注释一起改
  - 新增依赖前先看 `.agents/notes/implemented/2026-10-02-mobile-core-crypto-choice.md` 的选型闸门
- 工具脚本路径门禁(不需要浏览器):`node mock/proto/tools/verify-tool-paths.mjs` —— 扫 `mock/proto/tools/*.mjs`,2 条规则:禁 `file:///` + 盘符的字面量、禁 `C:\sudy` / `C:/sudy`(旧环境根)。**本仓库内的路径必须从 `import.meta.url` 派生**;理由与代价见 `.agents/notes/implemented/2026-10-02-paths-must-be-derived-not-hardcoded.md`(一次搬盘让 11 个脚本的 `PAGE` 全部指向不存在的 URL,而门禁是**静默全红**:脚本照常跑完、照常打印 JSON)
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
  - `pnpm test` —— 跑 `protocol/fixtures` 与 `protocol/vectors`,外加握手/封箱/流控/任务帧/订阅骨架/每连接装配/方法面/幂等/四个 DSH 适配器/连接/身份/直连监听面等接线用例(当前 **301 项**;其中 fixtures 的断言数须与 `verify-fixtures.mjs` 的 486 一致、向量的与 `verify-vectors.mjs` 的 49 一致)
    - **`tests/pairing-e2e.test.ts` 是配对链的验收判据**:真中转**子进程** + 真 HTTP + 真 WS,跑完"出码 → 凭**公开邀请**换候选票 → 升级 → 受限握手(`pairingKeyInfo` + 上下文进 transcript)→ `pair-commit`(密文里是秘密)→ `pair-result`(密文里是令牌)→ 凭令牌换票 → 升级 → 真握手 → 双向 AEAD",外加 I7(中转**真的换进程重启**后只凭名册收敛)与敌对中转反例(替换候选公钥 / 拿公开邀请或旧 `codeHash` 授权)。它用的夹具是 `tests/support/pairing-chain.ts`(TS 写的手机替身)。
    - `tests/support/relay-process.ts` 的 `port` 是**自己探的空闲端口**而不是 `0`:I7 要能把中转**杀掉并在同一个端口上重起**,`0` 会让第二轮换一个端口、于是连接器的 `relayUrl` 指向别处。
    - **这一行是项数的唯一出处**(`AGENTS.md` §5 特意不在此处复述,就是为了只留一处)。改测试后同步它。
      它已经**静默漂移过一次**(245 → 273):当时用 shell 的 `.Replace` 更新,没匹配上就**什么都不做** ✗ ——
      所以改这行用编辑工具,改完跑一次 `pnpm test` 对一下数。
- 图标重新抽取(DSH 升级后):`node mock/proto/tools/extract-dsh-icons.mjs`
- **图标只有一个来源**(硬规则):DSH 的 98 个图标 → `mock/proto/icons.js`(机生成) → **同一份**产出 Flutter 侧 `app/lib/theme/dsh_icons.dart`。
  - 重新生成 Dart 侧:`node app/tools/extract-dsh-icons-dart.mjs`。**改 DSH 图标后必须重跑**(先跑上面那条,再跑这条)。
  - Dart 侧实现写在 `app/tools/dsh_icons.template.dart`(带 `@@…@@` 占位符的普通 Dart 文件)。**不要把它写成 JS 模板字符串** —— Dart 文档注释里全是反引号,塞进模板字符串会直接语法错误(踩过)。
  - **`ui/` 层禁止 `Icons.*`**(Material 图标),有门禁 `no-material-icons` 拦着(只扫 `app/lib/ui/`)。要用图标就 `DshIcon('<DSH 名字>', color: …)`。
  - 三个坑(都已由生成器处理,改生成器前先看):
    ① **颜色在编译期替换**:98 个图标全用 `currentColor`,而 `flutter_svg` 对它支持有缺口(flutter/flutter#158680、dnfield/flutter_svg#31)→ 生成期换成字面色值;
    ② **按默认尺寸烘焙**:`%%E:strokeWidth + 3%%` 这类表达式在 size 变化时会算出**不同几何**(实测 `treeCorner` 的 `x="8"` → size=20 时变成 `x="16"`)→ 所以只换根节点 `width`/`height`,缩放交给 `viewBox`;
    ③ **只换根节点那三个属性**:`archiveOff` 的默认尺寸是 16,而它坐标里有 **6 处** `="16"`(含 `<mask>` 与 `<rect>` 的几何值),全换会让 SVG 非法、图标静默画不出。
- 关键入口:`mock/proto/index.html`(原型唯一入口);`app/lib/theme/dsh_theme.dart`(Flutter 主题)
- 直连监听面(契约 §14.6 第一跳;设计见 `docs/subsystems/connector-and-relay.md` §1.7):配置 `listenPort`(**默认 `0` = 不监听**)+ `listenHost`(默认 `127.0.0.1`);代码 `connector/src/transport/listener.ts`。
  - **`ws` 是运行时依赖**(本插件唯一一个,`dependencies` 里);它只在配了 `listenPort` 时才被 import,但**产物里是顶层 `import`**(tsdown 外部化,不按需加载)—— 所以装进 profile 时 `ws` 必须装得上,否则 `lib/index.js` 直接加载失败。
  - TLS **不在插件里终结**(Tailscale `tailscale serve` / 反向代理);手机侧始终拨 `wss://`。
  - 鉴权就是握手本身:未配对设备在 `hello` 处被拒(关闭码 `4003`),监听面没有第二层令牌。
  - 起监听面的用例用 `port: 0`(系统分配),所以不受固定端口占用影响;`startListener` 的 `port: 0` 是"随便给一个口",**不是**"不监听"(那是装配层按配置判断的)
- 只读参考源码:DSH `D:\sudy\github\deepseek-harness`;Agents-Anywhere `D:\sudy\github\Agents-Anywhere`;rikkahub `D:\sudy\github\rikkahub`
- DSH 侧高信号入口(只读):
  - 开发者文档 <https://deepseek-harness.github.io/deepseek-harness/reference/> —— 子系统 `reference/subsystems/web-server`、`web-client`、`client-modules`;另有 `develop/basic/`、`guide/quickstart`
  - 架构决策笔记金矿 `D:\sudy\github\deepseek-harness\.agents\notes\archived\architecture\`:`2026-07-19-gui-layering-and-rpc-protocol`(GUI 分层与 RPC 协议)、`2026-07-23-unified-session-query-service`(统一会话查询服务)、`2026-07-25-web-command-surfaces-and-assembly`(命令面与装配)、`2026-07-25-web-input-machine-and-slash-pipeline`(输入状态机与 slash 流水线)、`2026-07-28-user-settings-seam`(用户设置缝)。每篇都带 `.zh.md`
  - **交互层(审批/提问/计划审查,2026-10-09 核实)**:`packages/interaction/user-approval/src/index.ts:215` 的 `request()` 与 `:267` 的 `decide()`(无限等 + signal 竞速 + 迟到丢弃 + fail-closed);`packages/interaction/user-questions/src/index.ts:187`(回答成为 `answer_to_pending_question` 用户消息)、`src/types.ts:26`(plan-review 意图);`packages/interaction/tool-ask-user/src/timed.ts:103`(计时提问默认 120 s、`-1` 无限等、超时转 pending)
  - **方法面与设置/凭据**:`packages/api/session-controller/src/commands.ts:105`(`create`)、`:311`(`prompt`,自带 requestId 幂等);`packages/api/settings-controller/src/index.ts:98,116`(`describe` 默认脱敏 / `update`);`packages/api/settings-controller/src/credentials.ts:83,100,113`(`describe`/`set`/`unset`)
  - **web server 的 TLS 与升级路由**:`packages/host/webserver/src/index.ts:13`(`node:https`)、`:55-61`(`WebUpgradeRoute`)、`:68-94`(`TlsConfig`,读不到即拒绝初始化)

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
- **本仓库内的路径必须从 `import.meta.url` 派生,不许写死盘符**(`node mock/proto/tools/verify-tool-paths.mjs` 会拦):环境从 `C:\sudy` 搬到 `D:\sudy` 后,11 个 CDP 脚本里写死的 `file:///C:/.../index.html` 让整组浏览器门禁**静默全红** —— 脚本照常跑完、照常打印 JSON,红的原因是路径而不是代码(最坏的一种红:看起来像回归)。同理 `OUT` 不要写成 `'mock/proto/shots'`(那是依赖 cwd 的第二种硬编码)。参考仓库路径的单一来源是 `AGENTS.md` §5 与 `tools.md`。取舍见 `.agents/notes/implemented/2026-10-02-paths-must-be-derived-not-hardcoded.md`
- **`start()` 起的周期任务,`attach()` 也得起 —— 否则接受来的连接是"能连上但收不到东西"**:`createConnection` 的两个周期任务(攒批 flush、保活判定)原本只在 `start()` 里起,而接受路径走 `attach()`。少了它们的表现是**静默的**:`send({t:'ev'})` 照样回 `true`,而那一帧进了 batcher 就再没人 flush(可攒批的 `ev`/`live`/`job` **一条都出不去**),`keepalive.tick()` 不被调用则**半开永远判不出来**(连接死了也不收口)。修法是抽一个**幂等**的 `startTimers()`,两条路共用(`attach` 可被调多次,重复起定时器会漏掉旧的)。教训:**"这段接线已经就绪"要读代码确认,不能从测试通过反推** —— `connection-accept.test.ts` 当时有 2 条断言全绿,但它们碰不到定时器。见 `.agents/notes/implemented/2026-10-02-listener-face.md`
- **同一批 `seq` 被多条连接各记一次是正常形态,不是告警**:监听面下每台设备各自从自己的水位订阅同一会话,各自都会把同一段事件推给增量缓冲;缓冲只留一份(拒绝重复)是**对的**,但**不能用 `warn` 播报** —— 每台设备每批事件刷一行会把真正的告警淹掉。判据是"这件事会不会在正常运行时反复发生":会,就 `debug`。别为它加去重表(那是把正常形态当成故障处理)
- **`ss1` / `ss2` 是「角色调整后的绝对编号」,不是「自己的临时 × 对端的静态」**:协议里 `ss1` 的定义是**发起方**临时 × **应答方**静态,而代码里最自然的写法(自己的临时 × 对端的静态)在**应答方算出的其实是 `ss2`**。把位置值当协议编号返回的后果是:**派生的主密钥仍然完全正确**(`ikm` 用的是调整后的顺序),所以握手会"看起来成功"、AEAD 也能正常解封 —— 只有那两条 `ss1`/`ss2` 断言会红。Dart 侧本轮真的踩了(见 `.agents/notes/implemented/2026-10-02-mobile-core-crypto-choice.md`)。判据:向量测试里 `asInitiator` 与 `asResponder` 的**六个字段各自**都要等于向量值,只验一侧等于没验
- **`cryptography` 的 `SecretBox.concatenation()` 拼的是 `nonce ‖ 密文 ‖ mac`,而我们的容器是 `base64url(密文 ‖ tag)`(nonce 不上线,它由 `fc` 派生)**:用错的话单侧测试全绿、真机才断(症状"解不开")。箱容器必须手工拼,并且**进向量断言**(`箱容器` / `容器往返` 两条)—— 这正是"各写各的容器在单侧测试里都是绿的"要防的
- **`flutter create` 会覆盖 `lib/main.dart` 与 `test/widget_test.dart`,但不碰 `lib/theme/`**:在已有 `app/` 上跑 `flutter create .` 之前先确认主题层没被改(本项目跑完两个主题文件原样保留)。另外它生成的 90 个文件(三端脚手架)必须入库,否则 `flutter run` 起不来
- **fixtures 的 `snapshotPageSize` 必须读,不能写死**:替身里把页大小写成 100 会让"分页"永远只走一页,于是 `hasMore` / 续页 / **分页期间的并发增量**全都测不到 —— 而 fixture 12 就是专门测这个的(它给的是 2)。表现是"没有进行中的快照"抛错或静默少断言
- **`protocol/not-paired` 与 `protocol/bad-frame` 的边界要**整段**收口,不能让解析层的错误漏出去**:手机按错误码决定下一步 —— `not-paired` 是"清除本地凭据、回配对页",`bad-frame` 是"这一帧格式不对、重试"。实测踩过:`verifySignature` 里 `fromHex(publicKeyHex)` 原本在 try **之外**,于是"公钥不是合法十六进制"漏出 `bad-frame`,把"设备身份不对"报成了"帧格式不对" —— **用户就永远卡在重试上**。修法不是 `try/on ProtocolException/rethrow`(那会把 `fromHex` 的 `bad-frame` 一起放行,**因为它是同一个异常类型**),而是显式把它翻译成 `not-paired`。教训:凡是"按错误码分派动作"的地方,要有一条**坏输入**的用例(合法十六进制但长度不对、奇数长度、非十六进制字符各一条)
- **Dart 社区的两条硬规范要在改完就跑,别攒着**:`dart format --output=none --set-exit-if-changed lib test`(Flutter CI 一直拿它当门禁)与 `dart analyze --fatal-infos lib test`(比 `flutter analyze` 严)。实测:`dart format` 会**重排 `if` 的花括号**,于是它能把一条**被 lint 拦下的写法**暴露出来(`curly_braces_in_flow_control_structures`)—— 所以顺序是先 format 再 analyze,反了会看到"刚改完又冒出新问题"
- **`ev` 帧的载荷是**真实 DSH 事件** `{type, seq, time, data}`,不是 fixtures 的 `{itemId, text}`** —— 后者是词汇层的**可逆占位**(`connector/src/protocol/recovery.ts:144`),而线上封的是 `JSON.stringify(record.event)`(`connector/src/session-subscriptions.ts:170,175`),`record.event` 是 `SessionWireEvent`(`packages/api/session-controller/src/types.ts` 的 `{type, seq, time, data}`)。**按 fixture 形状解析真实流量会在第一个事件上就抛"缺少 itemId"** —— 而 fixtures 与向量全绿(它们根本不经过这条路径),所以这个 bug 只能靠"真事件形状"的用例抓。修法:`itemId` 走 `itemIdOf`(契约 §5.2 的推导表),**文本留空**交给渲染层投影(这一层不认识 `type` 的语义)。教训:凡是"fixtures 里有一个形状、线上是另一个形状"的地方,要有一条**按线上形状**构造的用例
- **`core/` 里"错误码"必须是枚举,不能是字符串** —— 因为**报错类别决定下一步动作**。电脑侧(`connector/src/protocol/errors.ts`)的 `ProtocolError` 收 `string` 再归一(不在封闭表里就降级成 `internal`):那条归一化是**为对端给的码**设计的,但用在**我们自己构造**的码上时,`'protocol/bad-fram'`(少个 e)会**静默变成 `internal`** —— 编译通过、测试可能也过,只是类别变了。实测踩过:`not-paired` 被报成 `bad-frame`,而两者的动作是"清除凭据回配对页"与"重试",**报错类别错了用户就永远卡在重试上**。Dart 侧的切法:**自己构造用枚举**(拼错即编译错误)、**对端给的走 `ErrorCode.fromWire`**(未知归 `internal`)。新增错误码要改**两边**(TS 表 + Dart 枚举),目前没有门禁盯这件事
- **一次性迁移脚本要带"命中数断言",而且断言不止一种**:`app/tools/migrate-error-codes.mjs` 是本项目第一个这种脚本(27 处替换),它两次拦住了真问题 —— ① 我按 `Select-String` 的输出数命中数(每行只报第一个匹配),期望值偏小 → 脚本拒绝写盘;② 正则没吞掉原逗号,替换后留下 `ErrorCode.x,,`(数量是对的,**数量守卫拦不住**) → 补了一条"改完不许出现 `,,`"的兜底断言。教训:**机械替换的数量断言只能证明"改了几处",不能证明"改对了"**,要再加一条针对残渣形状的断言
- **注入的定时器在回调末尾"无条件续期"是个静默 bug**:`_startTicking` 的 `run()` 原本在末尾无条件重排下一次 tick,而半开路径会调 `_enterClosed()`(它取消了 tick 并可能已进退避)→ 那个"该死了"的定时器继续跑,在 `_connect()` 的 `await` 中途再调一次 `_enterClosed()`,把状态从 `connecting` 推到 `closed`,于是 `await` 回来后的 `to(handshake)` 变成**非法迁移**(实测报错 `backoff → handshake`)。修法:续期前判断 `_closed || _cancelTick == null`。**判据是测试给的**:推进 4 个心跳周期后状态机抛错
- **`core/` 的异步边界:测试要"把事件循环跑到静默"再断言**:从种子建密钥对、验签、派生、封箱**全是 `Future`**(`cryptography` 的 API 如此),所以"`start()` 返回"不等于"`hello` 已发出"。真实客户端是长活的、那一拍无所谓;测试需要一个 `pump()` 辅助(若干次 `Future.delayed(Duration.zero)`),否则断言会看到空列表而误判成"没实现"
- **拆分的信号是"重复的清单"与"缺失的所有者",不是"文件太长"**:实测 `sync_client_impl.dart` 971 行时量了三个候选簇 —— ① 每连接状态 6 字段 **33 处引用**,而且 `_connect()` 与 `_enterClosed()` **各写一遍同一个重置清单**(→ 该拆:收成 `ConnectionResources`);② 在途请求表既无超时、断连也不清(→ 该拆:收成 `CallRegistry`,顺带修掉"调用方永远不返回");③ 订阅面只有 **17 处引用**、没有重复清单(→ **不拆**:拆它只是搬家,收益是"看起来整齐",代价是多一层间接)。结论:尺寸限制属于 linter,不属于人的判断;**先量引用数与"有没有第二份清单",再决定拆不拆**
- **`StreamSubscription.cancel()` 返回的 Future 只表示"清理完成",不表示"还会收事件"**:调用 `cancel()` 的那一刻起事件就不再投递了,所以**收口路径不该 `await` 它**。实测踩过:把每连接资源的 `dispose()` 写成 `await subscription.cancel()`,于是"资源已死"与"状态已 closed"之间多了一个 `await` 窗口 —— 而收口路径全在事件回调里,任何一条都可能在那个窗口里被再次触发,结果是**退避计时器起点漂移**(一条重连用例因此失败,不是崩溃,是时序漂)。修法:同步 `dispose()` + `unawaited(cancel().catchError(...))`
- **"整体作废"比"每个加超时"更准确**:在途请求遇到断连要**立刻以错误结束**,否则调用方的 `await` 永远不返回(UI 表现是"转圈转到天荒地老",用户只能杀 App)。两种做法都能让它返回,但**客户端动作不同**:连接级拒绝 → `relay/offline` → "退避重试"(请求本身没问题);每请求超时 → "超时重试"(而请求可能已经在电脑侧执行了)。用连接级拒绝,而且它不需要每请求一个定时器
- **测试"永远挂着"这类 bug 时,断言要在触发前挂好**:`expectLater(pending, throwsA(...))` 必须写在"断开"**之前** —— 否则那个错误 Future 在 Dart 里会被当成未处理异常直接报出来,测试红在断言之前,看起来像"bug 没修"。变异校验时它红的方式很典型:**挂 30 s 后超时**(正是"永远不返回"的症状)
- **库的 `Future` "永远不完成"这类前提,只能读源码确认,不能从签名推断**:实测踩过 —— `web_socket_channel` 的 `channel.sink.close()` 返回 `Future<void>`,签名看起来完全正常,但**建连失败时它永远不完成**。根因(读 `adapter_web_socket_channel.dart` 得到):`AdapterWebSocketChannel` 只在 `webSocketFuture.then(...)` 里订阅内部流,而连不上时那段**从不执行**(走 `onError` 分支:只 `addError` + 关闭 **local** sink,**从不订阅 foreign sink**)。症状极具误导性:**3 s 的 `connectTimeout` 变成 30 s 的测试超时**,报错指向"测试超时"而不是"连不上"。修法:清场是礼节,`unawaited(...)` 发出去、不等它
- **选型要有可核实的一手依据,不能"想当然"**:本仓的三个参考仓库(`rikkahub` / `Agents-Anywhere` / `deepseek-harness`)**一个 `.dart` 文件都没有**(实测),所以 Flutter 侧的"参考成熟设计"只能查 pub.dev 文档 + **已安装包的源码**(`<pub-cache>/<包>-<版本>/lib/`)。实测差点选错的一例:跨平台的 `WebSocketChannel.connect` **不接受 `headers`**(`static WebSocketChannel connect(Uri uri, {Iterable<String>? protocols})`),而契约要求连接器令牌走 `Authorization` 升级头 —— 要迁就它就得改协议,方向反了;正确做法是用 `IOWebSocketChannel.connect`(它收 `headers`),并**如实记下代价**(这一层因此 io 专有)。纪律:**新依赖在 `pubspec.yaml` 注释里写明"核实了哪个签名/哪个能力"**,关键行为补一条真 socket 用例
- **删掉没有附加价值的包装层**:我自己包过一层只有一个方法的 `_SecureSource`(转发 `Random.secure()`),还手写过 LCG(用 `DateTime.now()` 播种 —— **隐藏的时钟依赖**,测试随时钟漂移)。两者都是"想当然"的产物。标准库与 `cryptography` 包里就有现成的(`Random`、`SecureRandom.system`),用它
- **手机端依赖现状**(每个都在 `pubspec.yaml` 注释里写了"为什么"):`cryptography`(纯 Dart 密码学)、`web_socket_channel`(Dart 官方 WebSocket,1.6k likes;用 `IOWebSocketChannel.connect` 因为**只有它收 headers**)。**本地存储定 `sqflite`**:已核实 CPF-Flutter 的 `flutter_sqflite` 有 **`br_3.41_dev` 分支**(正好对应本仓锁的 3.41 线),而 `drift` / `realm` 不在适配清单里
- **安卓模拟器(无真机也能跑 UI)**:`D:\soft\android-sdk` 已装 `emulator` + `system-images;android-36;google_apis;x86_64`,AVD 名 `dsh_test`。
  - 起模拟器:`& D:\soft\android-sdk\emulator\emulator.exe -avd dsh_test -no-snapshot-load -no-boot-anim -gpu swiftshader_indirect`(**后台跑,输出必须重定向到文件**)。
    **血泪点**:① 不要用 `| Select-Object -First N` 接它的输出 —— 管道关闭会**杀掉模拟器**(实测:进程退出、exit 0,看起来像"启动成功");② `job_kill` 杀不掉子进程 `qemu-system-x86_64`,残留会让下次启动报 `FATAL | Running multiple emulators with the same AVD`。清场:`Get-Process -Name 'emulator*','qemu*' | Stop-Process -Force`。
  - 等启动完成:轮询 `adb shell getprop sys.boot_completed` 直到 `1`(实测约 80 秒);`adb devices` 要是 `device` 而不是 `offline`。
  - 环境变量:`ANDROID_HOME`/`ANDROID_SDK_ROOT=D:\soft\android-sdk`,`JAVA_HOME=C:\Program Files\Eclipse Adoptium\jdk-21.0.9.10-hotspot`。
  - 首次 `flutter build apk --debug` 要下 Gradle 与依赖(**约 1.5 GB**,十几分钟),之后快。
- **Gradle wrapper 在国内下不动**(首次构建的绊脚石,实测浪费 40 分钟):`services.gradle.org` 的 TLS 握手失败(`SSLException` in `GradleWrapperMain`),症状是**跑很久才报错**、且只留一个 0 字节的 `.part`。
  - **最快的判断办法**:看 `~/.gradle/wrapper/dists/<版本>/` 下是不是只有一个 0 字节的 `*.zip.part`。
  - 修法:`app/android/gradle/wrapper/gradle-wrapper.properties` 的 `distributionUrl` 换国内镜像(本仓用 `https://mirrors.cloud.tencent.com/gradle/gradle-8.14-all.zip`,实测 HTTP 200 / 214 MB),清掉那个未完成目录再重跑。
  - **坑**:`.properties` 里冒号只需**一个**反斜杠(`https\://…`)。写成 `https\\://` 会报 `URISyntaxException: Illegal character in scheme name at index 5` —— 那是 Java properties 的转义规则,不是 URL 语法。
- **界面层必须能 `import 'package:flutter/material.dart'`**:`verify-platform-boundary.mjs` 的 `ui-no-platform-import` 规则**只拦 `dart:io`**。它曾与 `core-no-platform-import` 共用同一张禁用表(那张表含 `material.dart`),结果是**每个 UI 文件都误报**"平台细节漏进了界面层"。已有两条自检钉住(`material.dart`/`widgets.dart` 在 `ui/` 下必须**不**失败),改这条规则前先看那两条。
- **Dart 里 `ConnectionState` / `AppState` 有同名冲突**:Flutter 的 `material.dart` 也导出 `ConnectionState`(那是 `AsyncSnapshot` 的 none/waiting/active/done),与我们 core 的连接状态机同名。解法:UI/测试里 `import 'package:flutter/material.dart' hide ConnectionState;`。同理 `core.AppState`(前后台)与数据层的应用级状态不能同名 —— 后者已改名 `AppModel`(在 `data/app_model.dart`)。
- **真机验插件是必需的,不是可选的**:`flutter_secure_storage` 这类**平台插件**在纯 Dart 单测里没有实现 —— 调用会抛 `MissingPluginException`,而"写进内存的假实现永远返回成功"。所以"密钥到底有没有落到 Keystore"只有 `integration_test` 跑在设备上才能回答。做法:`flutter test integration_test/xxx_test.dart -d emulator-5554`(记得 `ANDROID_HOME`/`JAVA_HOME` 在环境里,否则报 `Could not locate aapt`)。
- **`adb shell input text` 不能输入引号**(实测报 `no closing quote`),所以**满是引号的 JSON 没法手工灌进输入框**。要往设备上的输入框喂数据,用 `integration_test` 的 `enterText`。
- **widget 测试的默认视口比真机大**:模拟器是 320×640,而确认按钮落在 y=646 —— `tap` 打不中并报 `would not hit test on the specified widget`。做法:先 `await tester.ensureVisible(finder)` 再点。**这同时是对真机可用性的检查**:小屏上够不着的按钮是真问题。
- **一个漏传的参数能让 9 个测试文件一起"红",而真因只有一个**:`handshake_driver.dart` 的
  `createHandshakeDriver` 收了 `transcriptContext` 却没往下传 ⇒ 那 9 个文件的**编译失败**被报成
  "loading … [E] Compilation failed"。**看到多条红先读第一条**:若输出里出现
  `Compilation failed` / `The Dart compiler exited unexpectedly`,那是编译面而不是断言面,
  修一处就能消掉一大片(本轮 12 条红里 9 条是它)。
- **"半迁移"的识别与处置**:红的方式若是"调用已被删除的 API"或"断言里的清单没跟上实现",
  它既不是实现坏了、也不是测试写错了,而是**迁移没做完**。处置只有两条,且都要**写明**:
  ① 把调用方/断言迁到新形状(断言强度不降);② 若被断言的行为**已被设计删除**,
  删掉那条用例并在文件头写明"同一不变量现在由 X 覆盖"。**不要**把断言改宽让它变绿。
- **棘轮/清单类门禁改完必须做一次变异校验**:`connection-surface.test.ts` 的成员清单
  从 4 收到 3 时,我往被扫的源码里塞了一个假成员 `port.zzzTempMutationMember`,
  确认它红并**点名**那个成员,再撤回。清单类断言最容易被改成恒真,而恒真的清单比没有清单更坏。
- **`dart format` 会重排文件,之后再用编辑工具改同一文件会被拒**(要求先重读)。
  顺序应是:改 → `dart format` → 若还要改就先读一遍,别把"文件变过"当成工具故障。
- 血泪史条目见 `docs/postmortem/`;此处只留结论。
