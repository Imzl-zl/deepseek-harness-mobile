# dsh-mobile 项目状态

> 本文件是当前状态快照 + 最近活跃窗口,允许覆盖更新。
> 决策与取舍见 `.agents/notes/`,稳定规律与坑点见 `tools.md`,现状事实见 `docs/`。

## 下一步(新会话从这里开始)

**当前里程碑**:电脑侧两条路径都通(直连监听面 / 经中转);**手机端 `core/` 全部落地**
(会话层 + 连接层,`flutter test` **128 项**全绿);**两端尚未在真 socket 上互连过** ——
下一步是 `data/`+`model/`,然后是 `ui/`。

**手机端剩下的链**(真机仍在末端):

```text
[✅] 装 Flutter SDK(3.41.9) + flutter create + cryptography
[✅] core/ 会话层(frame/crypto/handshake/items/recovery/flow)—— 两批规格全绿
[✅] core/ 连接层(errors/connection/keepalive/transport/box/handshake_driver/outbox/sync_client)
[✅] core/ 配对(pairing.dart:二维码解析 + pairingId/SAS/codeHash 派生,跨端向量钉住)
[✅] platform/ 真实 ChannelTransport(web_socket_channel 的 io 入口 + 6 项真 socket 用例)
[✅] platform/ 凭据安全存储(pairing_store.dart,主种子进 Keystore;真机 integration_test 验)
[✅] model/ + data/(领域模型、事件投影、条目表、应用级状态)
[✅] ui/ 配对页 + 会话列表 + 对话页(安卓模拟器实跑截图见 docs/shots/)
[  ] data/store.dart(sqflite 本地库 —— 现在条目只在内存,重启即空)
[  ] ui/adaptive/(系统紧耦合控件的平台惯例层)
[  ] 三端能力包(secure_store_* / notify / live_surface / keepalive)
[  ] 相机扫码(增量,加在 pairing_page 上)
[  ] 真机联调(前置:上面整条链 + 直连的两个缺口)
```

1. **手机端剩下的层**:`platform/` 的真实 `ChannelTransport`(用 `dart:io` 的 `WebSocket`;
   `core/` 只留缝,实现归装配点)→ `data/`+`model/` → `ui/` 逐屏。
   **`ui/` 能在 Windows 桌面上跑起来**(`flutter run -d windows`)——
   本机 VS 18 + MSVC + Windows SDK 齐全,**不需要模拟器、不需要真机**。
   规格:`docs/subsystems/app-channel-client.md`(§2 关键类型、§2.1 状态机、§6 UI 接线点、§7 测试策略)。
   **开工提示词:`docs/prompts/mobile-core-prompt.md`**(含版本闸门、本机环境、fixtures/vectors 的真实形状)。
   **Flutter 版本闸门:锁 `3.41.9`(上界由鸿蒙 fork 定),不要装当前 stable 3.47.6。**
2. **直连拓扑的两个缺口**(直连真机联调前必须补;"两条路径都通"的拦路石):
   - **`relayUrl` 是挂载硬前置**:`connector/src/index.ts:217-225` 的 `validate-config` 里,
     `relayUrl` / `relayTokenRef` 为空就**抛错拒绝挂载** —— 所以"纯直连、不配中转"目前挂不起来。
   - **二维码里的地址永远是中转**:`pairing.ts:170` 写的是 `relay: options.relayUrl`,
     而 `index.ts:369` 传的也是 `relayUrl`;直连需要的是**电脑自己的地址**。
   两条都只影响"直连真机联调",不影响已落地的 `core/`(纯 Dart 单测)。
3. **中转多实例**:限流 / 一次性票 / 配对登记 / 路由窗口目前都是**进程内状态**;§12 的完整形态要求外部化。
4. 其余未实现面:插件面板、本机运行模式、goals·schedule·todos 三个远端动作(见 `docs/`)。
5. **真机联调**(Tailscale 可达性、WSS 证书、锁屏与强杀)——
   **前置是上面第 1 条整条链**:没有 UI 就没有东西能装到真机上。现在做不了,也不该被当成"下一步"。
   只有三件事真机不可替代(三端专属表达 / 推送锁屏强杀 / force-stop),且属**验收**不属开发。

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
| `node app/tools/verify-platform-boundary.mjs` | **104 项**(含 18 条规则自检 + 扫描 30 个 Dart 文件) |
| `cd app && flutter test` | **147 项**(core 53 + 连接层 59 + 平台层 6 + 配对 6 + 界面 3 + 向量 16 + fixtures 回放 1 + 其它) |
| `cd app && flutter test integration_test/pairing_flow_test.dart -d emulator-5554` | **2 项**(真机验安全存储:纯单测验不了插件) |
| `cd app && dart analyze --fatal-infos lib test` | 0 问题(比 `flutter analyze` 严) |
| `cd app && dart format --output=none --set-exit-if-changed lib test` | 0 文件需重排(Dart 社区硬规范) |
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
- **未做**:上面"下一步"的 1–5(手机端上层 / 直连缺口 / 多实例 / 其余面 / 真机);  幂等的启动核对;中转的令牌签发目前靠 CLI(库还没落地)。
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

- **手机端配对落地(2026-10-02)**:此前 App 是个空壳(`BootstrapConfig` 是占位值 → 只能显示
  "连不上")。现在整条链通了:**配对页 → 派生 `pairingId`/SAS → 主种子进系统安全存储 →
  建连**。三条要害:
  - **派生规则"算错了却不报错"**,所以用**跨端向量**钉住:`app/tools/gen-pairing-vectors.mjs`
    **调真实的 `connector/src/pairing.ts`** 产期望值(不是我在 Dart 里重写一遍再对拍 ——
    那只能证明"我两次写的一样")。最易错的一处:`pairingId` 的 `ikm` 是
    **码的哈希的 UTF-8 字节**,不是码本身(两者各自自洽,**只在两端互连时暴露**);
    变异校验证实改错立刻红。
  - **电脑公钥只有一个入口** `PairingOffer.fromQrPayload`(契约 §12.1 硬规则),代码里
    没有任何"从网络读公钥"的路径。
  - **主种子进系统密钥库**(契约 §12.2 明令**绝不回落成明文 preferences**)。
    用 `flutter_secure_storage`(安卓 Keystore + AES-GCM/RSA-OAEP;
    **v11 的 `AndroidOptions` 已无 `encryptedSharedPreferences`** —— 写它是编译错误)。
    **鸿蒙那端它不够**(契约要求自写 platform channel 接 HUKS),等鸿蒙开工按
    `packages/secure_store_ohos` 做,接口不变。
  - 相机扫码**暂不做**:属三端能力包(三套权限+相机 API),而粘贴**功能等价**
    (二维码里就是一段 JSON)、零权限、**可测**。扫码作为增量加在 `pairing_page.dart` 上。
  - 见 `.agents/notes/implemented/2026-10-02-mobile-pairing.md`。
- **手机端安卓跑通(2026-10-02,同批)**:`model/` + `data/` + `ui/` 三层落地,
  `flutter build apk --debug` + 模拟器实机截图验证(见 `docs/shots/`)。接线时挖出一个真缺口:
  **`core/` 解析了事件却把 `type`/`data` 丢了**(`SessionDelta.items` 只有 itemId/text/seq),
  逼上层从空的 text 里猜事件类型 → 改成带 `SessionEvent`(身份推导留 core,
  原始载荷给上层),并把流式与持久在**类型上**分开(`events` vs `liveText`)。
  另修:`verify-platform-boundary.mjs` 的 `ui-no-platform-import` 曾与 core 共用禁用表
  (含 `material.dart`)→ **每个 UI 文件都误报**;改成 ui 只拦 `dart:io` 并补两条自检。
- **手机端平台层 + 选型查一手来源(2026-10-02,同批)**:`lib/platform/websocket_transport.dart`
  首次落地(真实 WSS)。**三处选型都查了一手来源**,不是想当然:
  - **WebSocket 用 `web_socket_channel`(Dart 官方包)**,但**必须用 `IOWebSocketChannel.connect`**
    —— 跨平台的 `WebSocketChannel.connect` **不接受 `headers`**(核实了 3.0.3 源码的签名),
    而契约 §2.2 要求令牌走 `Authorization` 升级头(不进 URL)。代价如实记录:这一层因此 **io 专有**。
  - **`pingInterval` 传 `null`(关掉)**:契约 §2.2 有自己的心跳与半开判定,而它依据的是
    **业务帧**的收发时刻;让协议层再发一套 ping 会多出一路**不受我们控制**的保活流量。
  - **随机源删掉自己包的 `_SecureSource` 与手写 LCG**(后者用 `DateTime.now()` 播种 =
    **隐藏的时钟依赖**),改用 `cryptography` 的 `SecureRandom.system`。
  - **本地存储定 `sqflite`**(核实 CPF-Flutter 的 `flutter_sqflite` 有 **`br_3.41_dev`** 分支,
    正好对应本仓锁的 3.41 线;`drift`/`realm` 不在适配清单里)。
  - **读包源码找到一个真根因**:建连失败后**卡死** —— `sink.close()` 的 Future **永远不完成**,
    因为 `AdapterWebSocketChannel` 只在 `webSocketFuture.then(...)` 里订阅内部流,
    而连不上时那段**从不执行**(走 `onError` 分支,只关 local sink)。症状极具误导性:
    3 s 的 `connectTimeout` 变成 30 s 的测试超时。修法:清场是礼节,`unawaited(...)` 不等它。
  - 教训沉淀:**"库的 Future 永远不完成"只能读源码确认,不能从签名推断**;
    **本仓三个参考仓库一个 `.dart` 都没有**,Flutter 侧只能查 pub.dev 文档 + 已安装包的源码。
  见 `.agents/notes/implemented/2026-10-02-mobile-platform-layer-sourcing.md`。
- **手机端连接层拆分(2026-10-02,同批)**:`sync_client_impl.dart` 971 行,先量三个候选簇再决定 ——
  ① 每连接状态 6 字段 **33 处引用**、且建连/断连**各写一遍同一个重置清单** → 收成
  `ConnectionResources`(该拆);② 在途请求表既无超时、断连也不清 → 收成 `CallRegistry`
  (**该拆,而且顺带修掉一个真缺口**:连接在请求在途时断掉,调用方的 `await` **永远不返回** ——
  断连是常态,所以 UI 会永久转圈;修法是"连接级拒绝",错误码 `relay/offline`);
  ③ 订阅面只有 **17 处引用**、没有重复清单 → **不拆**(拆它只是搬家)。
  顺带删掉 15 行死代码 `_writableWaiters`(手机侧只发 `req`/`res`/`credit`/`persisted`/`ping`,
  而 §4.3 只压可补的 `ev`/`live`/`job` —— 手机一个都不发,所以那套唤醒机制没有生产者)。
  **如实记录:`sync_client_impl.dart` 没有变短(971 → 969 行)** —— 这次拆分的收益是
  **正确性**(两处真耦合 + 一个真缺口),不是行数。
  另一处**验证了但没有 bug**:怀疑 `Keepalive` 不随连接重置会让"旧连接的沉默算到新连接头上",
  两版用例都通过 —— 原因是 `hello` 经 `_write` 会重置它(隐式耦合,留作观察)。
  见 `.agents/notes/implemented/2026-10-02-mobile-connection-layer-split.md`。
- **手机端连接层落地(2026-10-02)**:`core/` 补齐 errors / connection / keepalive / transport /
  box / handshake_driver / outbox / sync_client(实现 900 余行)。
  **测试 71 → 128 项**:最难在真机复现的四类场景(断连 / 退避 / 半开 / 握手失败)
  现在都由**假传输**在毫秒内驱动(`ChannelTransport` 是注入的缝,`core/` 仍是纯 Dart)。
  两处判断值得记:
  - **错误码从字符串换成枚举** —— 因为报错类别决定下一步动作,而字符串拼错会**静默降级**
    (`'protocol/bad-fram'` → `internal`)。切法是"自己构造用枚举、对端给的走 `fromWire`"。
  - **`SyncClient` 的诊断面拆成 `SyncClientProbe`** —— UI 不该看到帧列表(会诱使它自己解析帧)。
  迁移用了**带命中数断言的一次性脚本**,它两次拦住真问题(期望值数错、正则留下 `,,` 残渣)。
  测试抓到一个真 bug:注入的定时器在回调末尾**无条件续期**,于是"该死了"的 tick
  在 `_connect()` 的 `await` 中途把状态推成 `closed`,回来后的 `to(handshake)` 变成非法迁移。
  见 `.agents/notes/implemented/2026-10-02-mobile-connection-layer.md`。
- **手机端 `core/` 会话层(2026-10-02)**:Flutter `3.41.9`(版本闸门:上界由鸿蒙 fork 定,
  当前 stable 3.47.6 不许装)装到 `D:\soft\flutter`;`flutter create` 建出工程(90 文件,
  含 windows 端 —— **桌面调试用**,本机 VS 18 齐全,不需要模拟器/真机);依赖只有 `cryptography`。
  六层 `app/lib/core/`:frame / crypto / handshake / items / recovery / flow,**纯 Dart 零平台依赖**。
  判据:`test/crypto_vectors_test.dart` **16 项**(与 TS 侧逐字节相同的已知答案)+
  `test/fixtures_test.dart` **16 条 fixture / 494 项断言**(三角色回放;桥接与中转是 `test/support/` 替身)。
  抓到一个真 bug:`deriveSessionKeys` 最初返回**位置值**而当协议编号用 ——
  应答方的 `ss1` 实际等于 `ss2`,而**主密钥仍然正确**(所以握手"看起来成功"),
  只有"双侧派生"那两条断言能抓到。见 `.agents/notes/implemented/2026-10-02-mobile-core-crypto-choice.md`。
  同批修掉边界门禁的一个误报(两条 import 规则原本按正文 grep,把"说明规则的注释"判成违规)。
- **按社区规范收口(2026-10-02,同批)**:
  - **`dart format`** 是 Dart 社区硬规范(Flutter CI 一直当门禁),接入后 10 个文件不合规 → 全量重排。
  - **`dart analyze --fatal-infos`**(比 `flutter analyze` 严:info 也当失败)→ 0 问题。
  - **lint 规则集写进 `app/analysis_options.yaml`,每条注明它针对的具体失败模式** ——
    `public_member_api_docs` **刻意不开**:实测本层每个函数与类型都已有文档,缺的 66 处
    全是字段/构造器,一开只会长出复述字段名的噪音(注释里写了理由,不是"懒得加")。
  - **补 `core_units_test.dart`(53 项)**:此前 26 个公开符号**没有任何测试**
    (`itemIdOf` / `needsBox` / `assertHandshakePhase` / `decideRecovery` / `SendWindow` /
    握手三帧编解码 / `verifySignature` / `verifyConfirm` …)。这些是"写错也不会让
    已有两批规格变红"的判据(向量比的是值、fixtures 比的是端到端结论)。
  - **同批抓到一个真 bug**:`verifySignature` 里 `fromHex` 在 try 之外,坏十六进制会漏出
    `protocol/bad-frame` —— 而手机按错误码分派动作(`not-paired` = 回配对页,
    `bad-frame` = 重试),报错类别错了**用户永远卡在重试上**。已归一,并补坏输入用例。
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
