# dsh-mobile 项目状态

> 本文件是**当前状态快照** + 最近活跃窗口,允许覆盖更新。**不做流水追加** —— 历史属于 git 与 `.agents/notes/`。
> 决策与取舍见 `.agents/notes/`,稳定规律与坑点见 `tools.md`,现状事实见 `docs/`。

## 下一步(新会话从这里开始)

> **开工提示词:`docs/cookbook/next-session-interaction-to-phone.md`** —— 下一个会话直接用它
> (覆盖"交互转手机"完整开发 + 真机连通;真机跑法细节见 `next-session-real-device.md`)。

**当前里程碑**:配对 v2(公开邀请 + 候选身份 + 每设备一条数据连接)三侧收口完毕、门禁全绿,
**跨实现一致性已闭环**(Dart 与 TS 产品代码真打一次握手与双向封箱)。
**「交互转手机」的内核已落地但未接线**;「第一次真机连通」仍未验证。

**下一件事(接线,别重新设计)**:`connector/src/interaction-face.ts`(投影 + `interaction.respond`
路由 + 看护计时器)已建好、31 项单测绿,但**没有 handler、没有装配**。三件事:

1. **加 `interaction.respond` handler**(契约 §5.7 形状 `{sid, callId, answers}`,幂等键
   `i:<callId>`),路由到 `userQuestions.answer()` —— 只覆盖 `state === 'continued'` 的提问。
2. **实现 `RemoteInteractionPort`**(`connector/src/dsh/interactions.ts:55-69` 要求的契约):
   看护超时 + 断开 + fail-closed。**复用 `interaction-face.ts` 的 `createWatchdog`**,
   **不要**在 answerer 上再挂一个(waterfall 只走先注册的,另一个静默不触发)。
3. **接线投影**:`pending.changed` / `ev` 带上待处理项,手机才能渲染。
   `open` 态的实时路径**已经能跑**(`dsh/interactions.ts` 已注册两个 answerer),
   缺的就是 port 实现。

**`port` 现在是什么(2026-10-09 读 `index.ts` 确认)**:`index.ts:201-213` 是一个**故意的
fail-closed 桩** —— `askApproval` 记 `METRIC.failClosed` 后返回 `'reject'`,
`askQuestion` 直接抛(注释:"不能返回空答案伪装成「用户全跳过」")。
answerer 已在 `index.ts:302` 注册。**所以缺的只有这一件事:把桩换成真实现。**

**但真实现前面还有一件更前的(2026-10-09 读源码才发现)**:`index.ts:156-162` 的注释自己写着
`liveRegistry` **现在恒为空** —— 没有设备 presence 上报。于是完整因果链是:

```text
没人写 liveRegistry → liveDevices() 返回 [] → decideTakeover 永不 claim
→ answerer 永远 next() 交还桌面 → 那个 fail-closed 桩根本跑不到
```

**所以"交互转手机"是三件事,必须按顺序做**:

1. **presence 上报(最前面,现在完全没做)**:手机声明在线/前台/已订阅会话,连接层写进
   `liveRegistry`。**契约里已有载体**:`sync.hello` 的 `app: 'foreground'|'background'`
   (§5.4)就是干这个的;`online` 由连接本身表达,`subscribed` 在 `connection-scope.ts` 里
   **本来就有**(`sessionSubscriptions`),`lastInteractedAt` 由手机每次答话时带上。
   → 落点:`connection-scope.ts` 在鉴权完成/断开/订阅变化/sync.hello 时回调挂载级。
2. **port 实现**:把 `index.ts:201-213` 的桩换成真实现 —— 推到 `decideTakeover` 给出的
   **那台**手机(`takeover.ts:37` 的返回本来就带 `deviceId`,`interactions.ts:128` 现在只用了
   `.claim` 把它丢了),等它答,看护/断连走 `interaction-face.ts` 的 `createWatchdog`,
   一律 fail-closed。
3. **`interaction.respond` handler**:手机答的话从**那条连接**回来,所以 handler 属于
   `connection-scope.ts`(每连接),挂载级只负责"送到哪条连接"。

**顺序不能颠倒**:没有 1,2 和 3 写了也跑不到(这是现在这个桩的真实状态)。

**再往后**:手机侧 UI(输入栏接管 + 批次构造)→ 真机验证(`channel_e2e_test.dart` 之后再叠加
交互链路)→ 方法面剩 8 个 → `ui/adaptive` / 三端能力包(鸿蒙暂缓)/ 相机扫码。

**两个待拍板的**(内核已按最稳做法实现,装配时必须表态):
- 审批应答者取舍:正确做法是**保留 `dsh/interactions.ts` 的现有 answerer,把看护做进 port**
  (理由见 `remote-channel.md` §6.3.1),而不是二选一。
- `REPLY_QUEUED` / `BAD_ANSWER` 目前都映射 `interaction/not-pending`(客户端动作
  refresh-pending 正是恢复动作);要区分就得给封闭错误表加码(契约变更)。

## 已知缺口(定位过、有证据;除第 1 条外都未修)

1. ~~`--issue-token device` 签的令牌换不到票(403)~~ **已修**:中转不再签发设备令牌,
   摘要表只放连接器令牌(出现 device 条目即拒绝启动)。见
   `.agents/notes/implemented/2026-10-09-relay-never-issues-device-tokens.md`。
2. **首配的匿名限流桶是单一全局桶**:形状校验在取桶之后,持续约 6 请求/秒即可让所有新设备换票 429
   (约 10 s 恢复)。这与 `pairing-v2.md` §3"无效试探不能使真正的扫码设备失去授权机会"**不符**。
3. `stats.devices` 实为**通道数**(`relay/src/core.ts`),与 §8.2 的 `devices` 表不同名同义。

## 范围决定(2026-10-09,别再当缺口)

见 `.agents/notes/implemented/2026-10-09-token-and-scope-decisions.md`:

- **刷新令牌轮换不做**:设备令牌长期有效 + 手动吊销;刷新令牌仍是签给手机的本机凭据,
  但**摘要不再上报中转**(`refresh_hash` 已从名册协议删掉 —— 多存一份没人读的摘要
  只会让人以为轮换已实现)。
- **中转不做多实例**:单实例 + I7 重启收敛就是个人工具的形态。
- **鸿蒙暂缓**(不是放弃):Flutter 3.41.9 版本锁继续保留,OHOS 适配/HUKS/推送全部暂停;
  `docs/` 里既有的鸿蒙一手调研原样保留。

## 前置事实(会卡住实施)

- **Flutter 3.41.9 / Dart 3.11.5 已装好**(版本**锁死**:上界由鸿蒙 fork 定)。
  Android 构建需要 `ANDROID_HOME='D:\soft\android-sdk'` 与
  `JAVA_HOME='C:\Program Files\Eclipse Adoptium\jdk-21.0.9.10-hotspot'`。
- **真机联调的两个坑**(集成用例文件头也写了):屏幕灭掉 = Flutter 引擎暂停(用例报
  "did not complete"且**没有原因**)⇒ `adb shell svc power stayon true`;Android 9 起**默认禁明文
  HTTP**,放行范围钉在 debug 构建的 `network_security_config.xml`,Dart 侧对应开关是
  `PairingPage.allowInsecureLocal`(**两处都要开**,否则"码认了、票换不了")。
- **本机联调的服务编排**:中转 `cd relay; node src/main.ts --config relay.config.json`,
  **改了 `relay/src/**` 必须重启它**;电脑侧 `dsh --profile dsh-mobile-test --no-open --port 8099`
  (**不碰用户日常 GUI 的 19387**),**改了 `connector/src/**` 必须先 `pnpm build`**;
  **重启 profile 前确认没有旧进程残留**(两个进程抢同一身份会让中转不停"新连接顶掉旧连接")。
- `connector/` 与 `relay/` 是**两个独立 pnpm 工程**(都不是 DSH workspace 成员);本仓库**没有 CI**。
  **两处导入风格不同、别"顺手统一"**:connector 写 `.js`(tsdown 打包),relay 直接跑 `.ts`。
  `relay` 的 `ws` 是**运行时依赖**,须先 `pnpm install`。
- 仓库是 git 仓库,远端 `github.com/Imzl-zl/deepseek-harness-mobile`;
  `mock/proto/shots/`(生成物)与 `setup-collaboration-files.backup/` 不入库。

## 门禁(改代码后必须全绿)

| 命令 | 覆盖 |
|---|---|
| `node protocol/verify-fixtures.mjs` | 16 条 fixture / **486 项断言** |
| `node protocol/verify-loopback.mjs` | **26 项**:手机 ⇄ 中转 ⇄ 桥接回环 |
| `node protocol/verify-vectors.mjs` | **49 项**跨端密码学向量 |
| `node app/tools/verify-platform-boundary.mjs` | **182 项**(22 条规则自检 + 扫 50 个 Dart 文件) |
| `node mock/proto/tools/verify-icons.cjs` / `verify-tool-paths.mjs` | 原型图标集 / 工具脚本不许硬编码盘符 |
| `cd app && flutter test` | **340 项** |
| `cd app && dart analyze --fatal-infos lib test integration_test` | 0 问题(比 `flutter analyze` 严) |
| `cd app && dart format --output=none --set-exit-if-changed lib test integration_test` | 0 文件需重排 |
| `cd connector && pnpm exec tsc --noEmit && pnpm build && pnpm test` | 类型 + 产物 + **304 项** |
| `cd relay && pnpm typecheck && pnpm test` | 类型 + **75 条** |
| CDP 浏览器组 | `verify-proto` / `verify-authz`(18) / `verify-settings`(27) / `verify-tasks`(53) / `verify-picker` |
| `node app/tools/gen-pairing-vectors.mjs` | 重新生成配对向量(**改了配对派生规则后必须重跑**) |

**项数的唯一出处是 `tools.md`**;**改断言必须做一次变异校验**(故意破坏不变量,确认**恰好**那一条红)。

## 已定案的契约(实施时按这个写,不要重新发明)

- **配对 v2** → `docs/subsystems/pairing-v2.md`(唯一规格源):公开邀请与秘密分离、候选不是设备、
  受限通道只允许保活/流控与 `pair-commit`、**用户确认前不发秘密**。
- **远程通道** → `docs/subsystems/remote-channel.md`(§3 帧类型含 `pair-commit`/`pair-result`,
  §12.1 已改写为 v2)。可执行部分是 `protocol/fixtures/` + `protocol/vectors/`。
- **连接粒度**(硬约束):**一条连接只服务一台设备**;经中转时每台在线设备各拨一条数据连接
  (`/ws/connector?dev=&channel=`),控制面另有一条(`/ws/connector`)。理由:握手/AEAD 密钥/
  `fc`(nonce 唯一来源)/重放窗口**全是每设备状态**。
- **帧的认证边界**:只有握手三帧与 `presence` 明文,**配对两帧封箱**(`pair-commit` 的载荷就是秘密);
  `needsBox(t)` 是唯一判据;**握手门禁只放行握手三帧**(与电脑侧 `transport/codec.ts` 逐字对齐)。
- **首配两段**(手机侧):`beginPairing()`(换票 → 升级 → 受限握手,秘密未发)→ 用户确认 →
  `commit(code)`(发 `pair-commit`,收 `pair-result`)。
- **AEAD**:AES-256-GCM(Electron 的 crypto 没有 `chacha20-poly1305`);nonce 仍是 `fc` 的 96 位大端。
- **中转的可见面**(I10):只读 `sid` / `seq` / `fc` / 帧类型 / 帧头 `id`;方法名与载荷一律不可见。
- **幂等**:两阶段(先落盘 `pending` → 执行 → 成功改 `done`);**落盘失败即拒绝该写操作**。
  **`requestId` 在请求信封顶层**。
- **密钥**:API 密钥值不回传手机,改密钥只发新值。

## 进行中 / 未完成

- **方法面 12/20**:`repo.info` / `devices.list` / `session.list` / `session.subscribe` /
  `session.unsubscribe` / `session.page` / `session.refetch` / `session.prompt` / `job.list` /
  `job.kill` / `job.follow` / `job.unfollow`;其余回 `connector/unsupported`。
  **处理器表的键是"实现了什么"的唯一出处**;契约 §5.7 的方法表已逐条标注 DSH 侧依据。
  **20 的来历**:原 22 删掉 `interaction.list`(待处理集合是投影,没有独立查询)、
  `devices.revoke`(吊销不是方法:名册写入方本来就是电脑侧)、`push.configure`(推送本期不做),
  加入 `session.create`(DSH 原生)。`METHODS` 与契约**逐字对应**——契约外的方法不该被
  `isMethod` 放行(那会让"不存在"看起来像"没实现")。
- **错误码表 30 个**(15 协议层 + 15 DSH 宿主层),两边(TS `ERROR_TABLE` / Dart `ErrorCode`)
  **逐字一致**,由 `tests/error-table-parity.test.ts` 断言(做过变异校验:改一个动作即红并点名)。
  **宿主层漏码的后果是被归一化降级成 `internal`** → 用户对着永远重试也不好的操作反复点;
  2026-10-09 就真的漏了 15 个(`session/agent-busy` 等),已补并加了两道一致性门禁。
- **跨实现一致性已闭环**:`connector/tests/cross-language-handshake.test.ts` 让 Dart 与 TS 的
  **产品代码**真打一次握手 + 双向封箱,比对派生的密钥与解开的明文(做过变异校验:
  换掉 Dart 侧 transcript 字段顺序即红)。这是此前完全缺失的一类证据 ——
  两套独立实现各自自洽不等于能互通,而分歧的症状是"验签失败 / 解不开"。
- **DSH 侧能力已核实(2026-10-09 读源码)**:`session.create` **存在**
  (`packages/api/session-controller/src/commands.ts:105`)——此前 memory 说"电脑侧没有它"是错的,
  那说的是我们的处理器表没实现;`settings.describe`/`update`(`settings-controller/src/index.ts:98,116`)、
  `credentials.set/unset/describe`(`settings-controller/src/credentials.ts:83,100,113`)都在;
  **`interaction.*` / `push.*` / `devices.revoke` 在 DSH 里不存在**——审批与提问是
  `packages/interaction/` 下三个服务且以会话事件为真值(`remote-channel.md` §6.3.1 有逐条出处)。
- **`relay/` 已可运行**:路由核心(按通道绑定)/ 配对登记 / 一次性票 / HTTP 面 / 令牌签发与软吊销 /
  限流 / 设备名册 / 可运行入口 / 配置样例。
- **直连监听面已落地,形态已定案**:`connector/src/transport/listener.ts`(`listenPort` 默认 `0` = 不监听),
  **继续自起监听,不改用 DSH 的 `registerUpgrade`**。2026-10-09 读过 `packages/host/webserver`:
  插件**能**注册升级路由,但 TLS 与绑定地址都是**监听器级**的(插件碰不到),切过去会把 DSH 的
  浏览器面一起暴露到 tailnet,且没有"在 upgrade handler 里完整实现 WS 服务端握手"的先例。
  完整取舍与"什么时候该重新考虑"见
  `.agents/notes/implemented/2026-10-09-direct-listener-keeps-own-socket.md` 与
  `connector-and-relay.md` §1.7。**这个问题已关箱,不必重调研。**
- **剩下的缺口**:见上面"已知缺口"2、3;另有插件面板 / 本机运行模式 / goals·schedule·todos 未做;
  三端能力包(鸿蒙暂缓后,iOS/安卓两端仍要做)。

## 仍需注意

- **稳定坑点的唯一出处是 `tools.md` → Pitfalls**;本文件不复制一份。
- **改源码只用编辑工具,不用 shell 字符串替换** —— shell 出错是静默的
  (曾把源文件写空、造出空文件、让一处计数**静默漂移 28 条**;本轮又差点用 `-replace` 改测试文件)。
- **`dart format` 会重排文件**,之后再编辑同一文件要重新读一遍(编辑工具会因"文件变过"拒绝)。
- **别把"重启后的第一次成功"当能力**;判据要包含"连续重连 N 次都成立"。
- **提交信息里避免反引号**(pwsh 会当 Unicode 转义,整条命令在解析阶段就失败)。

## 最近活跃窗口(2026-10-09)

- **配对 v2 三侧收口**:relay 测试迁到 v2 API(删掉的都是**已删除机制**的用例);
  connector 两条棘轮按事实更新(帧类型清单同步契约、耦合面 4→3 个成员并做变异校验),
  三条 v1 流程 e2e 因"机制已被设计删除"删除并写明替代覆盖;app 侧新增
  `core/pairing_channel.dart` + 两段式编排 + 两段式配对页,17 个静态错误与 12 条失败清零(305→340 项)。
  见 `.agents/notes/implemented/2026-10-09-pairing-v2-test-migration.md` 与
  `2026-10-09-app-pairing-v2-two-phase.md`、`2026-10-08-pairing-v2-and-device-connections.md`。
- **中转不再签发设备令牌**:删掉 `--issue-token device` / `--revoke-token device`,
  摘要表只放连接器令牌(出现 device 条目即拒绝启动),认证顺序改成先名册后摘要。75 项。
  见 `.agents/notes/implemented/2026-10-09-relay-never-issues-device-tokens.md`。
- **顺手清掉的死代码**:`relay/src/routing.ts` / `protocol-view.ts` + 它们的 7 条用例、
  `pendingDeviceIdOf`;仓库根的调试脚本 `check-roster.cjs`。
- **上一轮(2026-10-07/08)**:配对链真机跑通(换票 → 升级 → `pair` → 令牌落 Keystore);
  之后 GPT 那一轮把它整体改成 v2 但没收口(实现改了、调用方与文档没跟上),本轮接上。
