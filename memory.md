# dsh-mobile 项目状态

> 本文件是当前状态快照 + 最近活跃窗口,允许覆盖更新。
> 决策与取舍见 `.agents/notes/`,稳定规律见 `tools.md`,现状事实见 `docs/`。

## 下一步(新会话从这里开始)

**目标**:落地路线第 2 步的下一半 —— 写 `connector/`(电脑侧 DSH 插件)的真实骨架,对着 `protocol/fixtures/` 跑。

**开工顺序**(依据 `docs/cookbook/channel-bootstrap.md`,照编号做完即可):

1. **第 0–3 步不需要真机**:先确认三条门禁全绿 → 定工程形态并留笔记 → 建 `connector/` 骨架 → 把 `protocol/reference/` 移植成 `src/protocol/` 并让 16 条 fixture 在 TS 侧跑绿(断言数须与 486 一致)。
2. **第 4–5 步接 DSH 适配层并真机连通**:按契约 §2.2 适配表逐项接;先 Tailscale 直连跑通"发一句/回一句",再接中转复跑同一组用例。
3. **第 6 步之后才是手机端**(前置:先装 Flutter SDK)与 `relay/` 产品化。

协议本身已经定稿(帧、握手与密钥、两层序号、流控、恢复与快照分页、审批接管判定表、参数表、故障矩阵),**不需要再决策**;`docs/subsystems/remote-channel.md` 是唯一规格源,`protocol/fixtures/` 是它的可执行部分。

**做完的样子(验收)**:

1. `connector/` 是合法 npm bundle,可装进某个 DSH profile(`dsh plugin --profile <name> add <本地路径>`);
2. 数据全部取自 DSH 已有服务——`sessionController.follow()/page()/prompt()/cancel()`、`approval`、`userQuestions`、`ctx.jobs`(适配表见 `docs/subsystems/remote-channel.md` §2.2),**不自建投影语义**;
3. 它把同一批 `protocol/fixtures/` 跑绿(`protocol/reference/` 是行为基准,**不是可搬运的代码**);
4. 三条门禁仍然全绿(见下表)。

**暂时不要做**:真实 DSH 端到端联调(要装在电脑上的 DSH 实例)、`relay/`(中转服务)、`app/` 里的 Dart 代码(见下方前置)。

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
| `node protocol/verify-vectors.mjs` | 33 项:跨端密码学向量(握手派生 + AEAD 往返 + 篡改拒绝);改 `protocol/tools/` 后必跑 |
| `node app/tools/verify-platform-boundary.mjs` | 17 项(含 13 条规则自检):多端边界与 `Platform.isOhos` 禁令 |
| `node mock/proto/tools/verify-icons.cjs` | 原型图标集(改 `mock/proto/` 后必跑) |
| `cd connector && pnpm exec tsc --noEmit` | connector 类型检查(改 `connector/src/**` 后必跑) |
| `cd connector && pnpm test` | connector 跑 `protocol/fixtures`:16 条 / **486 项断言**(须与参考侧 `verify-fixtures.mjs` 的数字相等,不等就是抄漏了断言) |
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

## 进行中 / 未完成

- **`protocol/` 已落地**:16 条 fixtures + 参考实现 + 三个校验脚本(fixtures / loopback / vectors)。参考实现**不是产品代码**,两侧(TS 插件 / Dart 手机端)要各写一遍,对着同一批 fixtures 跑。
- **`connector/` 第 1–3 步完成**:工程形态 + 骨架 + **协议层实现**。`src/protocol/` 是产品代码(frame / items / dedupe / recovery / takeover);中转与手机侧只作**测试替身**(`tests/support/relay.ts` + 测试内的手机侧),不进 `src/`。判据全过:`tsc --noEmit` 退出 0、`pnpm build` 产出 `lib/index.js` 且入口可真加载、`pnpm test` **16 条 fixture 全绿且断言数 = 486**(与参考侧相等)。取舍见 `.agents/notes/implemented/2026-10-01-connector-protocol-port.md`。**DSH 适配层(第 4 步)六个适配器全部落地**:`sessions`(follow/page/prompt/cancel,基线切点取 follow 开启帧的 `cursor`)、`interactions`(同进程直连 waterfall,不走 `$events` Remote 流)、`jobs`(只用 `readAt` 不用 `read`,`listOwnedBy` 排掉无主)、`subagents`(拍平 diagnostic 联合,只用 `listDescendants` 提供活动态)、`settings`(**安全路径唯一**:读固定 `redactSecrets`,写只走 `mutate`,凭据只有写面)、`caps`(`ctx.get` + 静默降级自报)。判据 `tests/layering.test.ts` 把第 4 步的 grep 仪式变成可机械执行的断言(协议层零 DSH 依赖 / 适配层带源码引用 / 服务键集中登记,自带规则自检)。**第 5 步(装进 profile 真机连通)未开始。**
- **`protocol/` 的连接层也在 connector 侧落地**:`crypto.ts`(X25519/Ed25519/HKDF/ChaCha20-Poly1305 + `fc` 计数器 + 重放防护)、`flow.ts`(W=128 发送窗口,保活帧不占额度)、`errors.ts`(§3.1 封闭表 + 每码的客户端行为)、`frame.ts` 补真实线级帧与 AAD 规范化。判据:`pnpm test` 跑 `protocol/vectors` 的 33 项(握手 15 + AEAD 15 + 篡改 3),与参考侧数字相等。**`transport/` / `store/` / `push/` / `index.ts` 装配仍未开始。**
- **`store/` 已落地**:存储 schema 收敛到契约 §8.1 一处(`connector-and-relay.md` §1.4 只留使用纪律 —— 之前两节对同一套表有四处不一致,见下);按**写入特征**拆两个域(`dsh_mobile_core` 小且正确性关键 / `dsh_mobile_windows` 大且可丢),因为 domain 的写入走单写链,同域会让 16 MiB 的窗口写堵住必须同步落盘的 `dedupe`。取舍见 `.agents/notes/implemented/2026-10-01-connector-store-schema.md`。**`transport/` / `push/` / `index.ts` 装配仍未开始。**
- **`transport/` 的纯逻辑部分已落地**:退避(1→30s 指数 ±20% 抖动)、保活(60s 心跳 + 2 周期半开判据)、攒批(50ms 或 ≥4KiB)、连接状态机(六态白名单迁移)。四个单元的时间与随机数**全部注入**,所以掉线/半开/攒批/非法迁移这些真机上最难复现的路径都能直接测。**WSS 接线本身未实现**(需要中转地址与令牌,属第 5 步)。
- **`push/` 与 `index.ts` 的 §1.3 生命周期装配仍未开始。**
- **`push/` 与生命周期引擎已落地**:`push/`(四类触发 + 同会话同类型 60s 折叠 + `rich`/`doorbell` 两档;**通知对象是白名单字段,没有能承载正文的位置** —— 推送通道不在端到端加密范围内)。`lifecycle.ts` 把 §1.3 的**顺序**抽成可测引擎:mount 中途失败逆序回滚、**dispose 尽力而为**(某步抛错不拦住后面的步骤,尤其 transport.stop 失败时仍必须 close-store)。**`index.ts` 的真实装配(发布服务、注册 answerer、起 transport)与 WSS 接线仍未做。**
- **`transport/codec.ts` 已落地**:行级 JSON 分帧 + §3 的四条规则(8 MiB 单帧上限、未知帧类型不带 `id` 就忽略 / 带 `id` 必须回不支持、**握手门禁**、`id`/`sid` 的 ASCII 安全字符集)。ASCII 限制在**解码处**拦的理由是:AAD 由字段拼串而来,放一个需要 JSON 转义的字符进去会让两端算出的 AAD 不同,而症状是"解不开"而不是"字段非法"。**WSS 拨号接线仍未做**;已装 `ws`(devDependency)作为测试用的服务端。
- **`transport/connection.ts` 已落地,并且第一次有端到端证据**:把状态机 + 退避 + 保活 + 攒批 + codec 接到注入的 socket 工厂上,测试里起**真的 WebSocket 服务端**当对端,走完 `idle → connecting → handshake → serving`、收发真帧、掐断重连、握手门禁拒绝业务帧 —— 5 个端到端用例全绿。接线时踩到一个**单元测试抓不到的**真 bug:`encodeFrame` 没输出行分隔符,而分帧器把最后一段当半行留着,于是每帧被永久缓冲、对端永远收不到;`decodeFrame(encodeFrame(x))` 照样过(JSON.parse 容忍尾随空白),两边各自自洽、合起来才断。修法是把分隔符放进编解码层。另一处:`fc` 的分配权收归连接层(它是 nonce 来源,不能让上层决定),且每次建连换新计数器。
- **`index.ts` 的真实装配(发布服务、注册 answerer、起 transport)与 `observability.ts` 仍未做。**
- **`index.ts` 真实装配与 `observability.ts` 已落地**:`apply(ctx, config)` 用 `lifecycle.ts` 的顺序引擎把五步接起来(校验配置 → 开两个 domain 并迁移 meta → `ctx.provide` 发布服务 → 注册 answerer → 起 transport);`inject` 只列必需服务,可选能力走 `ctx.get`;配置不全**拒绝挂载**而不是空跑。`observability.ts` 把 cordis 的 printf logger 收成两参数形状 + 内存指标。分层校验规则**扩到入口文件**(它同样直接用宿主接口,不管就会成为盲区)。**方法面(契约 §5.7)未实现**:非连接层帧显式告警并计数,不静默丢弃。
- **第 5 步已起步(装进 profile)**:专用 profile `dsh-mobile-test`(不动 `desktop` / `web`)里,插件装成 `link:` 并进了 `dsh.profile.bundles`;`--dump-config` 无跳过报告、树里有我们插入的 entry —— **设计文档里标着「尚未逐行核实」的 peer 兼容性判据,现在被实测证实通过**。只装 `dsh-base` 时插件停在 `pending (waiting for service: sessionController)`(该服务由 `dsh-web-app` 带来);换成 web 同款栈后激活。**真机连通(手机端 / 中转)仍未做。**
- **`relay/` 与 `app/` 的代码都还没开始。**
- **协议六条已定稿并进 fixtures**:live 流式帧、快照水位与分页、待审批的持久投影、流控窗口(ack 兼信用)、接收端 seen-seq、审批仲裁判定表——对应 fixture `10`–`16`。
- **审批接管已定**(不再是产品决策):默认 `foreground` 档——App 前台**且**已订阅该会话才 claim,否则 delegate 给桌面;`always` / `never` 可选;claim 后看护超时 10 min 按 fail-closed 结束。判定表可执行(fixture `16`)。
- **插件面板未实现**:范围已定(清单 + 状态 + 行级开关 + 安装日志 + volatile 表单);安装/启停属第二阶段,且要先扩电脑侧桥接。
- **本机运行模式未实现**:草案在 `docs/standalone-mode-notes.md`;**是否进第一版仍未拍板**。
- **goals / schedule / todos 未核实**(参考实现里没有这三个面):目标条与自动化任务页的远端动作仍是演示,不得假装已远程提交。

## 仍需注意的坑点

- **稳定坑点的唯一出处是 `tools.md` → `Pitfalls`**,本文件不再复制一份,避免两处漂移(历史上 `tools.md` 的边界校验自检条数就曾与实现脱节)。本次归一的取舍见 `.agents/notes/implemented/2026-10-01-collaboration-single-source-of-truth.md`。
- 当前最挡路的一条:CDP 端口可能要换 —— 9222 被日常 Chrome 占用,9400 也可能被上一轮遗留的 headless Chrome 占着,开新端口前先探 `/json/version`。

## 最近活跃窗口

- 2026-10-01 开工第 1–3 步:`connector/` 从零建到协议层跑绿 —— ① 定工程形态并留笔记(独立 pnpm 工程、九处 DSH 版本钉 `0.2.0-rc.2`、兼容性只看 peerDependencies);② 建骨架并跑通判据;③ 把 `protocol/reference/` 移植成 `src/protocol/` 的 TS(frame / items / dedupe / recovery / takeover),中转与手机侧只作测试替身,**16 条 fixture 全绿且断言数 = 486 与参考侧相等**。顺带排掉两个坑:pnpm 11 的构建脚本审批闸记在 `pnpm-workspace.yaml` 的 `allowBuilds`(旧写法不生效)且会拦下每一次 `pnpm exec`;tsdown 在 node 平台默认输出 `.mjs`,与声明的 `lib/index.js` 对不上。第 4 步(DSH 适配层)未开始。

- 2026-10-01 协作体系归一 + 建仓:每个事实只留一个家 —— 坑点归 `tools.md`、模块规则下沉到新建的 `mock/proto/AGENTS.md`、`.serena` 记忆清成纯指针;修掉 `tools.md` 的「自检 10 条」(实际 13 条)、补齐根 `AGENTS.md` §5 门禁清单与 `docs/architecture.md`(补上 `protocol/` 与四个子系统)。建 git 仓库并接远端,让「代码与笔记同批提交」从纸面变成可执行。十条门禁跑通,写进文档的条数全部按实测复核。取舍见 `.agents/notes/implemented/2026-10-01-collaboration-single-source-of-truth.md`。

- 2026-09-30 通道评审落盘:三轮外部调研 + DSH 源码逐条核实 + 本仓实测(门禁四条全绿;变异校验复现出覆盖空洞——"瞬时事实回带"在回环里没被抓住)。契约同步修正 6 处事实与 3 条缺口:§2.1 兼容性判据(`peerDependencies`)与修订号归属、§2.2 附件上限与格式版本 v4、§3 `live` 帧与 seen-seq、§4 配对硬规则、§5 nonce 策略、§6 快照三要素与待审批持久化、§7 存储边界、§9 待审批重建、§10 变异校验表述、§11 前提与鸿蒙版本线。

- 2026-09-30 多端定案收口:三份实证到齐。Flutter 官方只有 **7 个 `.adaptive()` 构造器**、`flutter_adaptive_scaffold` 已停更、AppBar/底部导航/对话框被官方划为"设计期决策";官方示例 `platform_design`("platform-agnostic content + platform-specific chrome")与 Google Classroom 的公开数据支撑三层结构。开源实践里**无一主流项目**用 `platform/` 目录或 conditional import。另核实 `Platform.isOhos` 会导致构建失败,已进门禁。
- 2026-09-30 多端重新定案(体验判据):否掉"三端全原生""全共享 UI 不做平台表达""散落 `if (platform)`";定为三层 + C1–C6;旧笔记标注"判据被取代"后移入 `archived/`。核实三端体验不对等(iOS 锁屏常驻 8h/12h、安卓提升通知禁"其他方触发"、鸿蒙实况窗排除后台自动任务)。
- 2026-09-30 通道协议层落地:先写 9 条 fixtures(规格先行)→ 参考实现 → 241 项断言全绿;回环 20 项(含中转清空重启、中转对内容盲);**两处变异校验**证明断言非恒真。
- 2026-09-30 通道调研四轮收敛:插件可自开长连接但必须是 npm bundle;电脑侧定为薄适配层;DSH 的 `seq` 可直接当修订号但不是内容 ID;幂等靠 `requestId`(DSH 无 `clientMessageId`);审批动作只有允许一次/拒绝。
- 2026-09-30 远程通道方案定稿:反向 WebSocket + 哑中转 + 端到端加密 + 敲门式推送;修正 §2/§9 的过期结论(审批与计划审查回应**已支持**);新增 `docs/subsystems/remote-channel.md`。
- 更早(2026-09-30 同日,已落进 `docs/` 与原型):建立协作体系、设置项 42 项调研、插件页结论、授权矩阵 18 项、输入区重构、目标条/自动化任务页、`verify-tasks.mjs`(53)与 `verify-settings.mjs`(27)。
