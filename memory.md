# dsh-mobile 项目状态

> 本文件是当前状态快照 + 最近活跃窗口,允许覆盖更新。
> 决策与取舍见 `.agents/notes/`,稳定规律与坑点见 `tools.md`,现状事实见 `docs/`。

## 下一步(新会话从这里开始)

**当前里程碑**:远程通道的**电脑侧代码链路已全线打通**,且**两条路径都通**(直连监听面 / 经中转);
**手机端一行 Dart 都还没写**,所以整条链路**从未被两端同时跑过** —— 现在只有"电脑侧 + 手机替身"。

**手机端是一条长链,真机在它的末端**(不是下一步):

```text
装 Flutter SDK → 建 Flutter 工程(app/ 现在连 pubspec.yaml 都没有,只有主题层两个 dart 文件)
  → core/(纯 Dart,能跑 fixtures/vectors)   ← 判据在这一步就能拿到,不需要 UI
  → data/ + model/ → ui/(逐屏) → 三端能力包(安全存储/推送/保活) → 真机
```

1. **手机端 Dart 客户端**(需先装 Flutter SDK;`flutter test` 即可,安卓 SDK 只有到最后上真机才要):
   规格侧已备好,尤其 §3 的**行尾 `\n`**(漏了的表现是"两侧都正常、对端什么都没收到")、§4 握手、
   §5.6 幂等、§12 配对。落地顺序按 `docs/cookbook/channel-bootstrap.md` §6:
   `core/`(frame/crypto/recovery/items,纯 Dart 零平台依赖)→ `test/fixtures_test.dart` 跑同一批
   `protocol/fixtures` → `test/crypto_vectors_test.dart` 跑 `protocol/vectors` → 三端能力包最后接。
   判据:第 2、3 步在**没有 UI、没有平台代码**的情况下全绿。
   **这是当前唯一的"零进度"部分,也是后面所有事的闸门。**
   **开工提示词已备好:`docs/prompts/mobile-core-prompt.md`**(含版本闸门、已核实的本机环境、
   fixtures/vectors 的真实形状、以及"不用真机也能调"的分层答案)。
   **Flutter 版本闸门:锁 `3.41.9`(上界由鸿蒙 fork 定),不要装当前 stable 3.47.6。**
2. **直连拓扑的两个缺口**(手机端做完后要补;"两条路径都通"的拦路石):
   - **`relayUrl` 是挂载硬前置**:`connector/src/index.ts:217-225` 的 `validate-config` 里,
     `relayUrl` / `relayTokenRef` 为空就**抛错拒绝挂载** —— 所以"纯直连、不配中转"目前挂不起来。
   - **二维码里的地址永远是中转**:`pairing.ts:170` 写的是 `relay: options.relayUrl`,
     而 `index.ts:369` 传的也是 `relayUrl`;直连需要的是**电脑自己的地址**。
   两条都只影响"直连真机联调",不影响 `core/`(纯 Dart 单测)。
3. **中转多实例**:限流 / 一次性票 / 配对登记 / 路由窗口目前都是**进程内状态**;§12 的完整形态要求外部化。
4. 其余未实现面:插件面板、本机运行模式、goals·schedule·todos 三个远端动作(见 `docs/`)。
5. **真机联调**(Tailscale 可达性、WSS 证书、锁屏与强杀)——
   **前置是上面第 1 条整条链**:没有 App 就没有东西能装到真机上。现在做不了,也不该被当成"下一步"。

**做完的样子(验收)**:真机上发一句、收到一句;幂等重发不产生第二条;两条路径(Tailscale 直连 / 中转)
跑同一组用例都成立。—— 这些都**要等手机端落地**才谈得上。

## 前置事实(会卡住实施)

- **Flutter 与 Dart 都不在这台机器的 PATH 上**。写 `app/` 的 Dart、跑 `flutter test`、装
  `sqflite` / `cryptography` 之前必须先装 SDK。协议层与多端边界门禁全是 Node,不受影响。
- `connector/` 与 `relay/` 是**两个独立 pnpm 工程**(都不是 DSH workspace 成员);本仓库**没有 CI**。
  - `connector/`:插件,产物 `lib/index.js` 装进 profile;导入写 `.js`(tsdown 打包)。
  - `relay/`:独立服务,**不需要构建**;导入写 `.ts`(跑在 Node 的类型剥离下,`node --test` 直接跑测试)。
    **`ws` 是运行时依赖,必须先 `pnpm install`**(`tests/server.test.ts` 起真服务器,缺它直接
    `ERR_MODULE_NOT_FOUND`)。**别把两者的导入风格"顺手统一"** —— 运行时不同。
- 仓库是 git 仓库,远端 `github.com/Imzl-zl/deepseek-harness-mobile`;`mock/proto/shots/`(生成物)
  与 `setup-collaboration-files.backup/` 不入库。
- `app/` 只有主题层;交互基线原型 `mock/proto/` 是唯一可运行的完整形态。

## 门禁(改代码后必须全绿)

| 命令 | 覆盖 |
|---|---|
| `node protocol/verify-fixtures.mjs` | 16 条 fixture / **486 项断言** |
| `node protocol/verify-loopback.mjs` | **26 项**:手机 ⇄ 中转 ⇄ 桥接回环(含中转清空后重启) |
| `node protocol/verify-vectors.mjs` | **49 项**跨端密码学向量(改 `protocol/tools/` 后必跑) |
| `node app/tools/verify-platform-boundary.mjs` | **17 项**(含 13 条规则自检) |
| `node mock/proto/tools/verify-icons.cjs` | 原型图标集(改 `mock/proto/` 后必跑) |
| `node mock/proto/tools/verify-tool-paths.mjs` | 工具脚本不许硬编码盘符(2 条规则 / 14 个脚本) |
| `cd connector && pnpm exec tsc --noEmit` | connector 类型检查(**改任何 `.ts` 都要跑** —— 有两次只跑用例没跑它,红了没发现) |
| `cd connector && pnpm test` | connector 全套 **285 项**(含 fixtures 486 / 向量 49 的相等断言) |
| `cd connector && pnpm build` | 产出装进 profile 的那份产物 |
| `cd relay && pnpm typecheck && node --test` | relay 类型检查 + **62 条** |
| CDP 浏览器组 | `verify-proto` / `verify-authz`(18) / `verify-settings`(27) / `verify-tasks`(53) / `verify-picker` |

**项数的唯一出处是 `tools.md`**(`AGENTS.md` §5 特意不在此处复述,免得两处漂移);本表的数字
若与它不一致,以 `tools.md` 为准。**改断言必须做一次变异校验**(故意破坏不变量确认变红)。

## 已定案的契约(实施时按这个写,不要重新发明)

- **远程通道** → `docs/subsystems/remote-channel.md`:唯一规格源(信封/帧、配对与鉴权、端到端加密、
  修订号与恢复、存储边界、推送、DSH 适配表)。可执行部分是 `protocol/fixtures/` + `protocol/vectors/`。
- **三侧落地设计** → `docs/subsystems/connector-and-relay.md`(电脑侧插件与中转)、
  `docs/subsystems/app-channel-client.md`(手机端)、`docs/cookbook/channel-bootstrap.md`(开工步骤)。
- **多端边界** → `docs/subsystems/app-platform-boundaries.md`;可移植性上限见
  `.agents/notes/proposed/2026-09-30-mobile-portability-ceilings.md`。
- **握手形状**(已定,不要再改):三帧独立类型;`box` 是明文容器、不带 `fc`/`sid`;transcript 从字段拼
  (不含签名);发起方永远是手机;**`hello-ack` 的 `id` 回显 `hello` 的 `id`**(无 `sid` 的帧靠它回程,
  否则中继无法解复用)。
- **帧的认证边界**(已定):只有握手三帧、配对帧与 `presence` 明文,其余每种都封箱;
  `needsBox(t)` 是唯一判据;重放窗口**先验后进**。
- **中转的可见面**(I10):只读 `sid` / `seq` / `fc` / 帧类型 / **帧头 `id`**;方法名与载荷一律不可见。
  **无 `sid` 的帧一律按 ticket 绑定路由**(否则设备第一帧 `hello` 会被丢)。
- **幂等**(已定):两阶段 —— 先落盘 `pending` → 执行 → 成功改写 `done`;**落盘失败即拒绝该写操作**;
  失败分两类(handler 回失败 = 清 pending 可重来;抛异常/结果落盘失败 = 行停在 pending,**重发是允许的**
  ——下游 `hasPromptRequest` 会扫会话事件日志认出去重)。启动核对仍是"省一次重发"的优化,未做。
- **中转的令牌与限流**(已定):令牌**只存摘要**,签发时只打印一次;吊销是**软吊销**(`revokedAt` 留行,
  重签即轮换);限流**按身份不按 IP**、令牌桶、**HTTP 与 WS 升级共用同一个桶**;
  帧速率待压测确定(不许拿估算当结论)。
- **配对**(已定):`pairingId` = 配对码哈希的 HKDF 输出;请求带 **`codeHash`**(不是码);电脑侧出码时
  向中转**登记**;**登记不成就绝不出码**;SAS 用公钥算。

## 进行中 / 未完成

- **方法面 12/22**:`repo.info` / `devices.list` / `session.list` / `session.subscribe` / `session.unsubscribe` /
  `session.page` / `session.refetch` / `session.prompt` / `job.list` / `job.kill` / `job.follow` / `job.unfollow`;
  其余回 `connector/unsupported`。处理器表的键是"实现了什么"的唯一出处。
- **`relay/` 已可运行**:路由核心 / 配对登记 / 中转大脑 / 一次性票 / HTTP 面 / 令牌签发与吊销 / 限流 /
  可运行入口 / 配置样例。**已实测**:带密钥三方链路(真进程 + 真 socket)、设备经中转到连接器、往返。
- **直连监听面已落地**(2026-10-02):`connector/src/transport/listener.ts`;配置 `listenPort`
  (**默认 `0` = 不监听**)+ `listenHost`。每 accept 一条就 `makeConnection(dial)` 装配一次,
  与拨号路径共用同一个工厂。`ws` 因此成为**本插件第一个运行时依赖**。
  TLS 由外部终结(Tailscale / 反向代理),鉴权就是握手本身(未配对 → 关闭码 4003)。
  **同批修掉一个既有静默 bug**:`attach()` 原来没起 `start()` 的两个周期任务(攒批 flush / 保活判定)
  —— 表现是"接受来的连接能连上、能握手,但可攒批的帧一条都发不出去,且半开永远判不出来"。
- **配对链闭合**:出码(带登记)→ 换票 → 经中转转发 → 电脑侧落设备行 → 明文回执。
- **未做**:上面"下一步"的 1–4(Dart 客户端 / 多实例 / 其余面 / 真机联调 —— 最后一项被第 1 条整条链挡住);
  幂等的启动核对;中转的令牌签发目前靠 CLI(库还没落地)。
- **profile 侧已起步**:专用 profile `dsh-mobile-test` 里插件装成 `link:` 并进了 `bundles`;
  `--dump-config` 证实三个必需服务在树里都有提供者。**只验到"能挂载",没验过"能连上"** ——
  那要等手机端落地。
- **审批接管已定**:默认 `foreground` 档(前台**且**已订阅才 claim,否则交还桌面);
  `takeover.devices` 仍恒为空(设备 presence 上报未落地)。

## 仍需注意

- **稳定坑点的唯一出处是 `tools.md` → `Pitfalls`**;本文件不再复制一份。
- **改源码只用编辑工具,不用 shell 字符串替换**:shell 出错是静默的(曾把源文件写空、造出空文件、
  以及让一处计数**静默漂移 28 条**);编辑工具失败会明确报"没找到"。
- **排查失败先看完整输出再决定过滤什么**(有一次先 grep 过滤,在"取不到细节"下靠判断硬改,白花一轮)。
- **每加一个机制问三件事**:零值怎么办?它自己会增长吗?别人能调/关它吗?
- 提交信息里避免 **反引号**(pwsh 会当 Unicode 转义,整条命令在解析阶段就失败)。
- CDP 端口可能要换:开新端口前先探 `/json/version`。

## 最近活跃窗口(2026-10-01 起)

- **直连监听面(2026-10-02)**:三个岔口一次收口 —— `ws` 进运行时依赖、`attach()` 补上周期任务、
  去重噪音降级为 `debug`。**先量再下**这条纪律第三次生效:落地前先读 `attach()` 的代码,
  发现它少了 `start()` 的两个定时器(既有静默 bug,原有 2 条断言碰不到它),先复现再修。
  另一处"清单错了就改清单":`per-connection-scope` 那篇的代价段写着"需要在订阅面上做会话级去重",
  读代码后改判为**不需要去重表**(两条连接各记同一批 `seq` 是正常形态,缓冲只留一份是对的),
  只把日志从 `warn` 降为 `debug`。三处变异校验各自变红。取舍见
  `.agents/notes/implemented/2026-10-02-listener-face.md`(两篇 `proposed/` 因此归档)。
- **环境搬迁修复(2026-10-02)**:开发环境从 `C:\sudy` 搬到 `D:\sudy`(三个只读参考仓库都在 D 盘)。
  搬盘让仓库内 22 个文件写死的 `C:\sudy\...` 全部失效,其中 **11 个 CDP 脚本的 `PAGE` 指向不存在的
  file:// URL → 整组浏览器门禁静默全红**(脚本照常跑完、照常打印 JSON)。修法=路径一律从
  `import.meta.url` 派生,并新增门禁 `verify-tool-paths.mjs`(注入硬编码即红,已变异校验)。
  同批把 `relay/node_modules`(673 文件)移出版本库、修正 `relay` 需先 `pnpm install`(`ws` 是运行时
  依赖)等文档漂移。取舍见 `.agents/notes/implemented/2026-10-02-paths-must-be-derived-not-hardcoded.md`。
- **规格与协议层(轮 1–16)**:契约定稿 + `protocol/` 可执行规格(16 fixture / 486 断言、49 向量、
  26 回环);connector 从零到方法面 12/22,握手、封箱、流控、订阅骨架、幂等管道逐个落地。
- **配对与三方链路(轮 32–52)**:**里程碑** —— 手机替身带票连中转 → **经中继握手**(真签名/真 transcript)
  → **AEAD 双向业务帧**,在真进程 + 真 socket 上通过。路上修掉一个**协议层缺口**:`hello-ack` 曾自行
  生成 `id`,而中继只看得见帧头、握手帧又无 `sid`,于是回帧无法定向(症状"丢弃一帧:hello-ack 找不到
  对应设备",而两端各自看起来正常);修法=**回帧回显请求的 `id`**(`id` 不参与 transcript,故不必重生成向量)。
- **中转加固(轮 53–62)**:令牌签发(只打印一次 / 配置只放摘要)、软吊销、令牌桶限流
  (`retryAfterMs` 零补充时回 `null` 而非 `Infinity` —— 过 JSON 会变 `null`)、状态表**惰性自清**
  (限流桶 + 未使用的过期票)。
- **验证与对齐(轮 63–80)**:抓到并修掉 `internal` 之外的多处"两处来源"与文档漂移;**新增四道门禁**
  (耦合面 / 帧类型清单 / 错误码封闭表 / 方法名表 / 计数与文档一致性),其中两次当场证明必要性
  (我的断言口径错,而**差点为坏检查去改对的代码** —— 教训:断言红的时候先直接读源码确认,再决定改哪边)。
- 方法论沉淀:**"这是个大改动"应该先量再下**(一次 grep 数调用点、去重成员,把"重构"与"搬家"分开);
  **先把判定抽成纯函数,适配器剩下的就只是翻译**("需要 DSH 替身才能测"往往可以避免)。
- **每连接装配抽取落地**:量出那条缝只有 4 个成员 / 9 处调用,"重构"降级成搬家;落地时**没照搬清单** —— 读代码后把增量缓冲改判为挂载级(照搬会让恢复语义静默退化成快照)。教训:理由写在代码里,清单错了就改清单。
