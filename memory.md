# dsh-mobile 项目状态

> 本文件是当前状态快照 + 最近活跃窗口,允许覆盖更新。
> 决策与取舍见 `.agents/notes/`,稳定规律见 `tools.md`,现状事实见 `docs/`。

## 下一步(新会话从这里开始)

**目标**:把会话面往上推一档 —— 先给 `jobs`/`subagents`/`settings` 补测试(装配前提),再决定 `session.page` / `session.subscribe` 的接法。

**开工顺序**:

1. **补三份适配器的测试**(`src/dsh/jobs.ts` / `subagents.ts` / `settings.ts`):它们至今零覆盖,而装配它们的前一步必须是有测试。`jobs` 的坑最密(`readAt` vs `read`、无主 job、`kill` 会二次 cancel),值得先补。
2. **`job.list`(方法)**:接上 `jobs` 适配器 —— 它不需要订阅,是最干净的第二个数据面方法。
3. **会话订阅与翻页**(`session.subscribe` / `session.page` / `session.unsubscribe`):要 `follow` 的开启帧 `cursor` 当基线水位、要订阅生命周期与 `ev`/`live` 出帧路径,比 `list` 复杂一档,值得单独一轮。
4. **配对流程(§12.1)**:二维码 / 配对码 → 写设备记录(含 `pairingId`)与手机侧凭据。没有它就**没有设备行**,`peerOf` 恒返回 undefined,握手一律 `protocol/not-paired` —— 真机联调的最后一块空白。
5. **`relay/` 产品化**与**手机端 Dart**(后者前置:先装 Flutter SDK)。

协议本身已定稿,**不需要再决策**;`docs/subsystems/remote-channel.md` 是唯一规格源,`protocol/fixtures/` 与 `protocol/vectors/` 是它的可执行部分。

**做完的样子(验收)**:真机上发一句、收到一句;幂等重发不产生第二条;两条路径(Tailscale 直连 / 中转)跑同一组用例都成立。

**暂时不要做**:三端 UI 层面的东西;`app/` 里的 Dart 代码(前置见下)。

## 前置事实(会卡住实施)

- **Flutter 与 Dart 都不在这台机器的 PATH 上**(2026-09-30 核实)。`app/` 里写 Dart 代码、跑 `flutter test`、装 `sqflite` / `cryptography` 之前必须先装 SDK。协议层与多端边界门禁全是 Node,不受影响。
- **`connector/` 已引入本仓库第一套包管理配置**(pnpm 11.13.0;取舍见 `.agents/notes/implemented/2026-10-01-connector-workspace-shape.md`)。`relay/` 尚未开始,预计同样用 pnpm。本仓库仍然**没有 CI**。
- **仓库已是 git 仓库**(2026-10-01),远端 `github.com/Imzl-zl/deepseek-harness-mobile`;`mock/proto/shots/`(生成物,约 9 MB)与 `setup-collaboration-files.backup/` 不入库,靠 `.gitignore` 维护。
- `app/` 只有主题层(`app/lib/theme/`),无 Flutter 工程文件、无 UI;交互基线原型 `mock/proto/` 是唯一可运行的完整形态。

## 门禁(改代码后必须全绿)

| 命令 | 覆盖 |
|---|---|
| `node protocol/verify-fixtures.mjs` | 16 条 fixture / 486 项断言:恢复只有"增量或快照"两种结果;快照带水位与分页;待审批可从日志重建;live 帧不入账 |
| `node protocol/verify-loopback.mjs` | 26 项:手机 ⇄ 中转 ⇄ 电脑侧桥接回环,含"中转状态清空后重启仍收敛"与强制走桥接分支的 `5b` |
| `node protocol/verify-vectors.mjs` | 49 项:跨端密码学向量(握手派生 13 + 设备身份 5 + 拼串与签名 3 + AEAD 与箱容器 25 + 篡改 3);改 `protocol/tools/` 后必跑 |
| `node app/tools/verify-platform-boundary.mjs` | 17 项(含 13 条规则自检):多端边界与 `Platform.isOhos` 禁令 |
| `node mock/proto/tools/verify-icons.cjs` | 原型图标集(改 `mock/proto/` 后必跑) |
| `cd connector && pnpm exec tsc --noEmit` | connector 类型检查(改 `connector/src/**` 后必跑) |
| `cd connector && pnpm test` | connector 全套 **155 项**:跑 `protocol/fixtures`(16 条 / **486 项断言**)与 `protocol/vectors`(**49 项**),外加握手驱动 / 封箱 / 流控 / 方法面 / 幂等 / 会话适配器 / 连接级 e2e / 身份落点 / 分层校验(断言数与参考侧不等就是抄漏了) |
| `cd connector && pnpm build` | 产出 `lib/index.js` + `lib/index.d.ts`(装进 profile 的那份产物) |
| CDP 浏览器组 | `verify-proto` / `verify-authz`(18) / `verify-settings`(27) / `verify-tasks`(53) / `verify-picker`;跑法见 `tools.md` |

**改断言时必须做一次变异校验**:故意破坏一条不变量,确认断言真的变红(做过两次,见下"最近活跃窗口")。

## 已定案的契约(实施时按这个写,不要重新发明)

- **远程通道** → `docs/subsystems/remote-channel.md`:信封与帧、配对与鉴权、端到端加密、修订号与恢复语义、存储边界、推送与前台优化、DSH 侧数据源适配表(§2.2)、待验证前提(§11)。取舍见 `.agents/notes/proposed/2026-09-30-remote-channel-reverse-ws-e2ee.md`。
- **通道评审结论** → `docs/channel-review-notes.md`:优越性对照(Tailscale DERP / JMAP / Matrix / EMQX)、DSH 侧关键事实与行号、协议待补六条、平台侧事实、可复现实测与证据等级。落盘理由与被驳回的反馈见 `.agents/notes/implemented/2026-09-30-channel-review-corrections.md`。
- **三侧落地设计** → `docs/subsystems/connector-and-relay.md`(电脑侧插件与中转)、`docs/subsystems/app-channel-client.md`(手机端客户端)、`docs/cookbook/channel-bootstrap.md`(开工步骤与验证命令)。
- **多端边界** → `docs/subsystems/app-platform-boundaries.md`:三层结构、C1–C6 判据、版本闸门、已知框架缺口。取舍见 `.agents/notes/proposed/2026-09-30-experience-first-three-layer-split.md`。
- **三端可移植性上限** → `.agents/notes/proposed/2026-09-30-mobile-portability-ceilings.md`(加密 `cryptography`、本地库 sqflite、三端都不做后台长连接)。
- **规格的可执行部分** → `protocol/fixtures/` + `protocol/reference/`;为什么规格是 fixtures 而不是 JSON Schema,见 `.agents/notes/implemented/2026-09-30-protocol-fixtures-as-spec.md`。
- **connector 协议层** → `src/protocol/` 自持实现(不 import DSH 类型);中转与手机侧只作测试替身;**断言数必须 = 486**。取舍与被否方案见 `.agents/notes/implemented/2026-10-01-connector-protocol-port.md`。
- **connector 工程形态** → 独立 pnpm 工程(**不是** DSH workspace 成员,最终以 npm bundle 装进 profile)、`packageManager` 钉 `pnpm@11.13.0`、十三个 DSH 版本(10 dev + 3 peer)全钉 `0.2.0-rc.2` 精确版、兼容性**只看 `peerDependencies`**(不匹配会被静默跳过,写 `engines.dsh` 无效)、`src/protocol/` 不得 import DSH 类型。取舍与被否方案见 `.agents/notes/implemented/2026-10-01-connector-workspace-shape.md`。
- **握手的具体形状**(已定,不要再改):三帧都是**独立的帧类型**(`hello` / `hello-ack` / `confirm`),`box` 是明文编码容器、不带 `fc`/`sid`;transcript 从字段拼(`dsh-mobile/v1|hello|ephPubA|devId|nonceA|hello-ack|ephPubB|pcId|nonceB`,不含签名);发起方永远是手机,电脑侧只做应答方;`serving` 只能由"两道校验都过"推进。契约 §2.2 / §3 / §4.1 是唯一出处,取舍见 `.agents/notes/implemented/2026-10-01-handshake-third-frame.md` 与 `...-handshake-on-connection.md`。
- **电脑侧身份与配对标识的落点**(已定):主种子进 `ctx.credentials` 具名记录面(`dsh-mobile-connector/identity`,grant 载荷,首启生成、读不懂即抛错不覆盖);`pairingId` 随设备记录持久化(§8.1)。取舍与被否方案见 `.agents/notes/implemented/2026-10-01-connector-identity-home.md`。
- **帧的认证边界**(已定):只有握手三帧与 `presence` 明文,其余每种帧(含 `ping`/`pong`/`credit`/`persisted`)都封箱;箱容器 = `base64url(密文‖tag)`;重放窗口**先验后进**;`needsBox(t)` 是"该不该封箱"的唯一判据。取舍与被否方案见 `.agents/notes/implemented/2026-10-01-business-frame-sealing.md`。

## 进行中 / 未完成

- **`protocol/`(规格的可执行部分)已落地**:16 条 fixtures + 参考实现 + 三个校验脚本。参考实现**不是产品代码**,两侧(TS 插件 / Dart 手机端)要各写一遍,对着同一批 fixtures 与 vectors 跑。
- **`connector/` 已完成的层**:工程形态(独立 pnpm 工程,以 npm bundle 装进 profile)、协议层(`frame` / `crypto` / `items` / `dedupe` / `recovery` / `flow` / `errors` / `takeover` / `methods` / `handshake` / `handshake-frames` / `handshake-driver` / `identity`)、DSH 适配层六个适配器、`store/`(两域 + v2 schema)、`push/`、`transport/`(退避 / 保活 / 攒批 / 状态机 / codec / 拨号接线)、`lifecycle.ts` 顺序引擎、`observability.ts`、`index.ts` 六步装配、`alias.ts` 会话别名。判据:`tsc --noEmit` 0、`pnpm build` 产出 `lib/index.js`、`pnpm test` 97 项全绿(fixtures 486 项与向量 39 项与参考侧数字相等)。
- **握手真的跑在连接上**:连接进 `handshake` 即启动注入的驱动器(**只做应答方**),`hello-ack` 走一条**只放握手帧**的出帧路径,两道校验都过才进 `serving` 并把会话密钥交给上层。证据是连接级 e2e:真 WebSocket + 手机侧独立替身,两侧派生的密钥能用同一把 `kA2B` 往返。取舍见 `.agents/notes/implemented/2026-10-01-handshake-on-connection.md`。
- **规格本轮补了两处洞**(均先改 `remote-channel.md` 再改代码):① `confirm` 从"帧联合里根本没有"变成 §3 里的第三个握手帧,同时删掉 §4.1 中"即第一条业务帧""第一帧能解开即确认"这两句与 §2.2 硬冲突的话;② `pairingId` 进 §8.1 设备记录(否则每次重连算不出 `master`)。取舍见 `...-handshake-third-frame.md` 与 `...-connector-identity-home.md`。
- **电脑侧身份种子有落点了**:`ctx.credentials` 具名记录面(`dsh-mobile-connector/identity`,grant 载荷),首启生成一次、读不懂就抛错**绝不覆盖**;`credentials` 因此从可选升为必需服务。**未实测**:真实 `credentials-local` 上的写入(记录面语义由单测覆盖,服务存在性由 `--dump-config` 证实)。
- **业务帧的封箱已落地**:`protocol/box.ts` —— 除握手三帧与 `presence` 外**每帧都封箱**(控制帧封空载荷:`fc` 在 AAD 里,不认证就等于让未认证的数字驱动重放窗口),箱 = `base64url(密文‖tag)`,**重放窗口只在认证通过后推进**。封箱是连接层出帧/收帧的单一收口(`write` 里"分配 `fc`"与"封箱"紧挨着),上层看到的 `box` 永远是明文;`secure` 把握手与密码器绑成一个对象,配了就不可能明文上线。证据:连接级 e2e 用**手机侧独立实现**(自己拼 nonce/AAD/容器,不 import `box.ts`)双向跑通,篡改/重放/缺 box 三种形状各有关连接的错误码。取舍见 `.agents/notes/implemented/2026-10-01-business-frame-sealing.md`。
- **流控已接线**:W=128 窗口 + "收到即回 `credit`";`credit` 的 `fc` 是它自己的序号、**被确认的序号在箱里**(`{"ack":N}`,累计确认,QUIC 同形),`credit` 自己不再回 `credit`;满窗**只压可补的两类**(`ev`/`live`)—— 压 `res` 会死锁;暂停不是丢弃(队列里的帧等 `credit` 到达再放)。取舍与被否方案见 `.agents/notes/implemented/2026-10-01-flow-control-wiring.md`。
- **方法面已接线,3/22 个方法可用**:`src/method-face.ts`(解信封 → 分发 → 封 `res`,从不抛、从不碰 `fc`/封箱,返回值收窄成 `ResFrame`)+ `src/handlers.ts`(**"实现了什么"的唯一出处**:`repo.info` 报的就是这张表的键)。已实现 `repo.info` / `devices.list` / `session.list`;其余一律回 `connector/unsupported`。取舍见 `.agents/notes/implemented/2026-10-01-method-face-wiring.md`。
- **`session.list` 已落地**:清单取自 `sessionController.list`(权威、**已按活动排序**、且是已有必需服务),**不带标题**(该面不返回标题;`session-title` 读的是活的 `Session`,落盘-only 拿不到 → 契约 §5.7 那一行已改写明);别名在方法面合成,给手机的行**逐字段构造**(DSH 会话 id 绝不过线,e2e 有断言)。取舍与欠账见 `.agents/notes/implemented/2026-10-01-session-list-wiring.md`。
- **`dsh/` 适配器有三份零测试**:`jobs` / `subagents` / `settings` 还没被任何测试覆盖(只有 `sessions` 本轮补上、`caps`/`identity` 早有)。**装配它们之前必须先补测试** —— 否则第一次装配就是第一次运行。
- **幂等已接线(但还没被真实方法用到)**:`src/idempotency.ts` —— 只记成功、失败不进表;同键并发**合流**(只执行一次);崩溃窗口里重放执行(带键的四个方法各有下游保障);表无定时器,**TTL 靠惰性过期兜正确性**(读到过期条目即当未命中),空间回收是**有界清扫**(单次 500 条 —— 域表写入走单写链,一次一万条删除会让挂载卡几十秒)。方法面只对 `IDEMPOTENT_METHODS` 生效(只读方法带键也不进表)。**注意:那四个带键方法(`session.prompt` / `interaction.respond` / `settings.update` / `credentials.set|unset`)都还没实现**,所以本轮交付的是管道 + 判据,e2e 用的是假 handler。取舍与被否方案(含"为什么不像 Stripe 那样连失败也记")见 `.agents/notes/implemented/2026-10-01-idempotency-wiring.md`。
- **`session.list` 未实现**:需要新接 `sessionQuery`(服务键已在契约 §7 列出);`devices.revoke` 需要写存储 + 清在线会话,两者都留到各自轮次。
- **配对流程未实现**(§12.1):二维码 / 配对码 → 写设备记录(含 `pairingId`)。没有它就没有设备行,`peerOf` 恒 undefined、握手一律 `protocol/not-paired`。
- **`relay/`(中转)与 `app/`(手机端)的代码都还没开始**,后者前置是先装 Flutter SDK。
- **profile 侧已起步**:专用 profile `dsh-mobile-test`(不动 `desktop` / `web`)里插件装成 `link:` 并进了 `bundles`;`--dump-config` 证实 `credentials` / `storageDomain` / `sessionController` 三个必需服务在树里都有提供者,插件也未被跳过。**真机连通未做。**
- **协议六条已定稿并进 fixtures**:live 流式帧、快照水位与分页、待审批的持久投影、流控窗口(ack 兼信用)、接收端 seen-seq、审批仲裁判定表 —— 对应 fixture `10`–`16`。
- **审批接管已定**(不再是产品决策):默认 `foreground` 档 —— App 前台**且**已订阅该会话才 claim,否则 delegate 给桌面;`always` / `never` 可选;claim 后看护超时 10 min 按 fail-closed 结束。判定表可执行(fixture `16`)。`takeover.devices` 仍恒为空(设备鉴权与 presence 上报未落地)。
- **插件面板 / 本机运行模式 / goals·schedule·todos 三个面都未实现**:范围分别见 `docs/plugin-and-jobs-notes.md` 与 `docs/standalone-mode-notes.md`(本机模式是否进第一版仍未拍板);目标条与自动化任务页的远端动作仍是演示,**不得假装已远程提交**。

## 仍需注意的坑点

- **稳定坑点的唯一出处是 `tools.md` → `Pitfalls`**,本文件不再复制一份,避免两处漂移(历史上 `tools.md` 的边界校验自检条数就曾与实现脱节)。本次归一的取舍见 `.agents/notes/implemented/2026-10-01-collaboration-single-source-of-truth.md`。
- 当前最挡路的一条:CDP 端口可能要换 —— 9222 被日常 Chrome 占用,9400 也可能被上一轮遗留的 headless Chrome 占着,开新端口前先探 `/json/version`。

## 最近活跃窗口

- 2026-10-01 session.list 落地(本轮):手机首页要的第一个数据面方法通了。三处定案(各查过源码,不猜):① 清单取自 **`sessionController.list`**(权威、已按活动排序、且是已有必需服务 —— 不必为它新接 `sessionQuery`);② **不带标题**(该面不返回标题;`session-title` 读的是活的 `Session` 对象,落盘-only 会话拿不到;投影里只有 `blank`/`lastPromptAt`)—— 契约 §5.7 那一行已改写,手机用 `cwd` 末段 + 相对时间兜底;③ **别名在方法面合成**,适配器只做 DSH 映射,给手机的行逐字段构造。顺带修掉一个并发隐患:`alias.ensure` 同会话并发会各分一个别名(留下孤儿 `bySid`),现在合流。**还补上了 `sessions` 适配器的测试 —— `src/dsh/` 下此前四份适配器零测试,这是第一次真正装配其中一个。** 证据:`pnpm test` **155 项**、`tsc` 0、`pnpm build`、三条 protocol 门禁 486/26/49、多端边界 17;三处变异 ㉙㉚㉛ 命中,其中 ㉛ **第一次全绿**,追出"替身把 `put` 写成同步改内存、抹掉了真实域表'先落盘再改内存'的 await 边界"这个测试保真度问题(教训已进 `tools.md`)。

- 2026-10-01 幂等接线:把 I8 的最后一段接上 —— 新增 `src/idempotency.ts`(只记成功、失败不进表;同键并发**合流**;崩溃窗口里重放执行;TTL 靠**惰性过期**兜正确性,空间回收**单次有界** 500 条 —— 域表单写链下清一万条会让挂载卡几十秒),方法面只对 `IDEMPOTENT_METHODS` 生效。三处定案各有被否方案(为何不像 Stripe 那样连失败也记、为何不写 `pending` 行、为何并发不给 409)。**如实记:那四个带键方法都还没实现**,本轮交付的是管道 + 判据。取舍见 `.agents/notes/implemented/2026-10-01-idempotency-wiring.md`。

- 2026-10-01 幂等接线(本轮):把 I8 的最后一段接上 —— 新增 `src/idempotency.ts`(只记成功、失败不进表;同键并发**合流**成一次执行;崩溃窗口里重放执行而不是 fail-closed;收敛点取挂载与超容量两处),方法面只对 `IDEMPOTENT_METHODS` 生效(只读方法带键也不进表),`index.ts` 从 `dedupe` 表建它并在挂载时先 `prune()` 一次。三处定案各有被否方案:① 为什么不像 Stripe 那样"连失败也记"(会把瞬时故障变成 24h 死路,而带键的四个方法各有下游保障 —— 这份清单必须随新方法复核);② 为什么不写 `pending` 行做 fail-closed(桥接单进程,重放安全,而 pending 行永远读不到);③ 为什么并发同键给确定答复而不是 409(执行就在本进程里)。**如实记:那四个带键方法都还没实现**,所以本轮交付的是管道 + 判据。证据:`pnpm test` **145 项**、`tsc` 0、`pnpm build`、三条 protocol 门禁 486/26/49、多端边界 17;三处变异 ㉕㉖㉗ 逐条命中(㉖ 让 e2e 的 I8 用例红 —— 真实重发被算了两次)。

- 2026-10-01 方法面接线:第一次让手机能"问一句、拿一句" —— 新增 `src/method-face.ts`(解信封 → `dispatch` → 封 `res`;从不抛、从不分配 `fc`/封箱,返回值收窄成 `ResFrame`)与 `src/handlers.ts`(**"实现了什么"的唯一出处**,`repo.info` 报的就是这张表的键),已实现 `repo.info` 与 `devices.list`。三处定案:`res` 必须回带 `id`/`sid`、帧头与信封的 `ok` 只在 `resFrame()` 里同时写一次、能力位与已实现方法是两件事。取舍见 `.agents/notes/implemented/2026-10-01-method-face-wiring.md`。

- 2026-10-01 方法面接线(本轮):第一次让手机能"问一句、拿一句" —— 新增 `src/method-face.ts`(解信封 → `dispatch` → 封 `res`;**从不抛**、**从不分配 `fc`/封箱**,返回值收窄成 `ResFrame`)与 `src/handlers.ts`(**"实现了什么"的唯一出处**,`repo.info` 报的就是这张表的键),已实现 `repo.info` 与 `devices.list`,其余回 `connector/unsupported`;`index.ts` 的收帧分支把 `req` 交给它,应答走同一条出帧路径(发不出去会 `metrics + log`,不静默丢弃)。三处定案:`res` 必须回带 `id`/`sid`(关联一断手机永远等不到回应)、帧头与信封的 `ok` 只在 `resFrame()` 里同时写一次、能力位(`caps`:服务在不在)与已实现方法(`methods`:我们接没接上)是两件事。证据:`pnpm test` **132 项**、`tsc` 0、`pnpm build`、三条 protocol 门禁 486/26/49、多端边界 17;三处变异 ㉒㉓㉔ 逐条命中(其中 ㉓ 证明"结构化错误不关连接"这条判据是真的)。

- 2026-10-01 流控接线:把 §4.3 的 W=128 与"收到即回 `credit`"接到收发路径上,并定案三处 —— ① `credit` 的 `fc` 是**它自己**的序号,被确认的序号放进箱里 `{"ack":N}`(QUIC 同形);② `credit` 自己不再回 `credit`(否则两端互刷 ack);③ 满窗只压可补的两类(压 `res` 会死锁),且暂停不是丢弃。变异校验抓出一处重复逻辑(早返回 + 谓词把同一条规则写了两遍、谓词成死逻辑),改成两个并列 `if` 后同一变异立刻命中。取舍见 `.agents/notes/implemented/2026-10-01-flow-control-wiring.md`。

- 2026-10-01 流控接线(本轮):把 §4.3 的 W=128 与"收到即回 `credit`"接到收发路径上,并定案三处纸面上说不清的语义 —— ① `credit` 的 `fc` 是**它自己**的序号(与 nonce、重放守卫同一套语义),被确认的序号放进箱里 `{"ack":N}`(累计确认;QUIC 的 ACK 在保护包内、包号仍是自己的);② `credit` 自己不再回 `credit`(否则两端互刷 ack),并与 QUIC 的"ACK 不是 ack-eliciting"对齐;③ 满窗**只压可补的两类**(压 `res` 会死锁),且暂停不是丢弃(队列里的帧等 `credit` 到达再放)。实现:`flow.ts` 的 `canSend` 自带优先级、`encodeCredit`/`decodeCredit`、连接层 `accountFlow`(在解箱之后记账)+ `drainBatch` 重入队 + `write` 在分配 `fc` 之前查窗口。**变异校验抓出一处重复逻辑**:最初"早返回 + 谓词"把同一条规则写了两遍、谓词成死逻辑,改成一个变异都不红;改成两个并列 `if` 后同一变异立刻命中。证据:`pnpm test` **117 项**、`tsc` 0、`pnpm build`、三条 protocol 门禁 486/26/49、多端边界 17;两处新变异 ⑳㉑ 逐条命中。

- 2026-10-01 业务帧封箱:把 `box` 的 AEAD 补上,并修掉它暴露的三处问题 —— ① `ping`/`pong`/`credit`/`persisted` 带 `fc` 却没有 `box`(未认证的数字直接驱动重放窗口,`credit`/`persisted` 还可被中继伪造改状态)→ 除握手三帧与 `presence` 外一律封箱;② 箱的容器格式没定义 → 定为 `base64url(密文‖tag)` 并**进向量**(39 → **49 项**);③ `crypto.open` 把 `node:crypto` 裸错误漏给协议层 → 认证失败转 `protocol/bad-frame`。证据:连接级 e2e 用手机侧**独立实现**(自己拼 nonce/AAD/容器,不 import `box.ts`)双向跑通;四处变异 ⑯⑰⑱⑲ 逐条命中。取舍见 `.agents/notes/implemented/2026-10-01-business-frame-sealing.md`。

- 2026-10-01 业务帧封箱(本轮):把 `box` 的 AEAD 补上,并修掉它暴露的三处问题 —— ① `ping`/`pong`/`credit`/`persisted` 带 `fc` 却没有 `box`(未认证的数字直接驱动重放窗口,`credit`/`persisted` 还可被中继伪造改状态)→ 除握手三帧与 `presence` 外一律封箱;② 箱的容器格式没定义 → 定为 `base64url(密文‖tag)` 并**进向量**(5 条 AEAD 各加容器与容器往返两项,39 → **49 项**);③ `crypto.open` 把 `node:crypto` 裸错误漏给协议层 → 认证失败转 `protocol/bad-frame`。实现:`protocol/box.ts`(方向映射 + 容器 + 重放守卫"先验后进" + 同一 `fc` 不许封两次的绊线)、连接层 `secure` 把握手与密码器绑成一个对象、`needsBox`/`hasBox` 两个判据收敛到协议层一处。证据:`pnpm test` **111 项**、`tsc` 0、`pnpm build` 出产物、三条 protocol 门禁 486/26/49、多端边界 17、图标 98;四处变异校验 ⑯⑰⑱⑲ 逐条命中(见 `tools.md`)。

- 2026-10-01 握手接线:把「握手的发帧与状态推进」接到 `transport/connection.ts` —— 新增 `protocol/handshake-driver.ts`(应答方状态机:hello → 签 hello-ack → 验 confirm → 派生)、连接层给它一条**只放握手帧**的出帧路径并把握手帧路由进去、成功后由 `established` 推进 `serving` 并把密钥交给上层;新增 `dsh/identity.ts`(身份种子落凭据记录面),设备记录补 `pairingId`(schema v1→v2),`credentials` 升为必需服务。**顺带修掉三处漂移**:① `confirm` 在帧联合里根本不存在;② 跨端向量签的还是旧 transcript 定义(33 → **39 项**);③ `write()` 发帧不重置空闲计时。取舍见 `.agents/notes/implemented/2026-10-01-handshake-on-connection.md`、`...-handshake-third-frame.md`、`...-connector-identity-home.md`。

- 2026-10-01 握手接线(本轮):把「握手的发帧与状态推进」接到 `transport/connection.ts` —— 新增 `protocol/handshake-driver.ts`(应答方状态机:hello → 签 hello-ack → 验 confirm → 派生)、连接层给它一条**只放握手帧**的出帧路径并把握手帧路由进去、成功后由 `established` 推进 `serving` 并把密钥交给上层;新增 `dsh/identity.ts`(身份种子落凭据记录面)与 `protocol/deriveIdentity`,设备记录补 `pairingId`(schema v1→v2),`credentials` 升为必需服务。**顺带修掉三处漂移**:① `confirm` 在帧联合里根本不存在(补进 §3 与握手期白名单);② 跨端向量签的还是旧 transcript 定义(改成从字段重拼再重签,并补设备身份向量,33 → **39 项**);③ `write()` 发帧不重置空闲计时,与 §2.2「任一方向」相悖(改成"发帧也重置,`ping` 除外")。门禁:三条 protocol 脚本全绿(486 / 26 / 39)、`pnpm test` **97 项**、`tsc` 0、`pnpm build` 出产物、多端边界 17 项、图标 98;三处变异校验 ⑬⑭⑮ 逐条命中预期(见 `tools.md`)。取舍见 `.agents/notes/implemented/2026-10-01-handshake-on-connection.md`、`...-handshake-third-frame.md`、`...-connector-identity-home.md`。

- 2026-10-01 开工第 1–3 步:`connector/` 从零建到协议层跑绿 —— ① 定工程形态并留笔记(独立 pnpm 工程、九处 DSH 版本钉 `0.2.0-rc.2`、兼容性只看 peerDependencies);② 建骨架并跑通判据;③ 把 `protocol/reference/` 移植成 `src/protocol/` 的 TS(frame / items / dedupe / recovery / takeover),中转与手机侧只作测试替身,**16 条 fixture 全绿且断言数 = 486 与参考侧相等**。顺带排掉两个坑:pnpm 11 的构建脚本审批闸记在 `pnpm-workspace.yaml` 的 `allowBuilds`(旧写法不生效)且会拦下每一次 `pnpm exec`;tsdown 在 node 平台默认输出 `.mjs`,与声明的 `lib/index.js` 对不上。第 4 步(DSH 适配层)未开始。

- 2026-10-01 协作体系归一 + 建仓:每个事实只留一个家 —— 坑点归 `tools.md`、模块规则下沉到新建的 `mock/proto/AGENTS.md`、`.serena` 记忆清成纯指针;修掉 `tools.md` 的「自检 10 条」(实际 13 条)、补齐根 `AGENTS.md` §5 门禁清单与 `docs/architecture.md`(补上 `protocol/` 与四个子系统)。建 git 仓库并接远端,让「代码与笔记同批提交」从纸面变成可执行。十条门禁跑通,写进文档的条数全部按实测复核。取舍见 `.agents/notes/implemented/2026-10-01-collaboration-single-source-of-truth.md`。

- 2026-09-30 通道评审落盘:三轮外部调研 + DSH 源码逐条核实 + 本仓实测(门禁四条全绿;变异校验复现出覆盖空洞——"瞬时事实回带"在回环里没被抓住)。契约同步修正 6 处事实与 3 条缺口:§2.1 兼容性判据(`peerDependencies`)与修订号归属、§2.2 附件上限与格式版本 v4、§3 `live` 帧与 seen-seq、§4 配对硬规则、§5 nonce 策略、§6 快照三要素与待审批持久化、§7 存储边界、§9 待审批重建、§10 变异校验表述、§11 前提与鸿蒙版本线。

- 2026-09-30 多端定案收口:三份实证到齐。Flutter 官方只有 **7 个 `.adaptive()` 构造器**、`flutter_adaptive_scaffold` 已停更、AppBar/底部导航/对话框被官方划为"设计期决策";官方示例 `platform_design`("platform-agnostic content + platform-specific chrome")与 Google Classroom 的公开数据支撑三层结构。开源实践里**无一主流项目**用 `platform/` 目录或 conditional import。另核实 `Platform.isOhos` 会导致构建失败,已进门禁。
- 2026-09-30 多端重新定案(体验判据):否掉"三端全原生""全共享 UI 不做平台表达""散落 `if (platform)`";定为三层 + C1–C6;旧笔记标注"判据被取代"后移入 `archived/`。核实三端体验不对等(iOS 锁屏常驻 8h/12h、安卓提升通知禁"其他方触发"、鸿蒙实况窗排除后台自动任务)。
- 2026-09-30 通道协议层落地:先写 9 条 fixtures(规格先行)→ 参考实现 → 241 项断言全绿;回环 20 项(含中转清空重启、中转对内容盲);**两处变异校验**证明断言非恒真。
- 2026-09-30 通道调研四轮收敛:插件可自开长连接但必须是 npm bundle;电脑侧定为薄适配层;DSH 的 `seq` 可直接当修订号但不是内容 ID;幂等靠 `requestId`(DSH 无 `clientMessageId`);审批动作只有允许一次/拒绝。
- 2026-09-30 远程通道方案定稿:反向 WebSocket + 哑中转 + 端到端加密 + 敲门式推送;修正 §2/§9 的过期结论(审批与计划审查回应**已支持**);新增 `docs/subsystems/remote-channel.md`。
- 更早(2026-09-30 同日,已落进 `docs/` 与原型):建立协作体系、设置项 42 项调研、插件页结论、授权矩阵 18 项、输入区重构、目标条/自动化任务页、`verify-tasks.mjs`(53)与 `verify-settings.mjs`(27)。
