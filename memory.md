# dsh-mobile 项目状态

> 本文件是**当前状态快照** + 最近活跃窗口,允许覆盖更新。**不做流水追加** —— 历史属于 git 与 `.agents/notes/`。
> 决策与取舍见 `.agents/notes/`,稳定规律与坑点见 `tools.md`,现状事实见 `docs/`。

## 下一步(新会话从这里开始)

> **开工提示词:`docs/cookbook/next-session-interaction-to-phone.md`** —— 下一个会话直接用它
> (真机跑法 + 免费渠道 + 成本纪律 + 两次尝试的完整证据 + 已装好的仪器)。

**当前里程碑**:**「审批 / 提问 / 计划审查转到手机」整条链已接线**;两处小改已完成
(① 步骤 ④ 等待窗口调到 `_waitForModel` 档;② lifecycle observer 挂上,前后台态自此
真的报给连接)。**发送模式(排队/插话)已照搬 DSH 二选一并放进入控区**;**
待处理已改成 per-session(一会话一队)**,并发会话可切换着答,跨会话有角标与提示行。
门禁全绿:connector **369** / relay **75** / app **390** / 平台边界 **189**。
**唯一没过的:真机审批回合** —— 2026-10-13 自动跑过两次,都卡在最后一跳,证据与仪器
见 cookbook 的「真机两次尝试」一节;下次直接从那里接。

**真机上抓出并修掉的四个 bug**(都只在真机暴露,细节见两篇决策笔记):
① profile 补丁漏 `allowInsecureLocal` → 连接器**从不拨线**(什么都没发生);
② `main.dart` 的 `PairingClient` 漏同一个字段 → **配对成功但换不到票**;
③ `_handleOpened` 把**密文**喂给 `_accountFlow` → `credit 载荷不是合法 JSON` →
**握手成功 20 ms 后断线**;
④ **两个交互应答者没带 `{ prepend: true }`** → DSH 的桌面转发监听器
(`packages/api/remotes/src/index.ts:57-75`,浏览器一连上就注册、自己不答就不放行)
排在前面 → **审批永远挂在 `approval/asked`,手机答了也无处可落**。
**④ 是「审批转手机」最后一跳的真因**,已修 + 有专属回归用例 + 变异校验。

**已修根的四个 bug**(细节见两篇决策笔记,都只在真机暴露):
① profile 补丁漏 `allowInsecureLocal` → 连接器**从不拨线**(什么都没发生);
② `main.dart` 的 `PairingClient` 漏同一个字段 → **配对成功但换不到票**;
③ `_handleOpened` 把**密文**喂给 `_accountFlow` → `credit 载荷不是合法 JSON` →
**握手成功 20 ms 后断线**;
④ **两个交互应答者没带 `{ prepend: true }`** → DSH 的桌面转发监听器
(`packages/api/remotes/src/index.ts:57-75`,浏览器一连上就注册、自己不答就不放行)
排在前面 → **审批永远挂在 `approval/asked`,手机答了也无处可落**。
⑤ `askApproval` 曾在"呈示不了"时 `return 'reject'`,**替用户做一个他没做过的决定**
(真机 322ms 回 `rejected`,而用户什么都没点)—— 已改成抛,由 `interactions.ts`
归一成 `'unavailable'`。见 `.agents/notes/implemented/2026-10-13-approval-must-not-fake-rejection.md`。

**当前卡点(2026-10-13 三次真机,第三次根因已确定)**:审批探针发出去后卡片不出现。
**根因**:靶子会话的工作区目录已不存在(`C:\Users\zhanglu\.ssh-server` 被删)——
DSH 照常把 `user/message` 落盘(所以④的回读判据满足),但那个会话的 agent 永远
起不来、轮次从不启动,于是永远等不到 `approval/asked`。**全程零痕迹**:手机侧
连接 serving、`send` 全 true、连接器 dedupe 也有 `done`。前两次的"零痕迹"同此,
**不是帧丢失也不是拒收**。
**修法(未做)**:`connector/src/handlers.ts` 的 `session.list` 把 `cwd` 过线,
手机侧 `SessionSummary` 收下,真机用例挑靶子加"cwd 存在"判据。
**另一条已定位的环境因素**:步骤 ②/⑤ 挑靶子会叫醒别人的 agent 会话 —— 现已优先
挑 `blank`(从没跑过)的会话缓解;彻底办法是靶子只建在专用工作区
`D:\sudy\myproject\dsh-mobile-test`(目录已建,工作区待用户在 Web UI 添加)。
完整证据见 cookbook「真机三次尝试」。

**模型/状态显示已对齐 DSH 真值**(2026-10-13):手机上原来的模型名是**写死的** `'claude-opus'`
外加一份手抄的四个模型列表,与电脑侧毫无关系。现在接 DSH 原生的两条通道:
`session/modelCatalog`(目录,原样过线)+ `modelSelection` 投影(每会话当前模型)。
连接器新增 `session.modelCatalog` 方法、`session.list` 的行带 `model` 字段;
手机侧 `SessionSummary.model` + `chat_page.dart` 的 `_modelLabel` / `_reasoningLabel`。
**拿不到就显示"未选择",不猜。** 见 `connector/src/dsh/models.ts` 的文件头。
**还没做**:模型**切换**（`session/select-model` 会回写全局默认,本期只读不写）、
模型 picker 接真目录（现在还是手抄列表）。
**改 `connector/src/**` 必须先 `pnpm build`**(真加载的是 `lib/index.js`)。

## 真机联调的成本纪律(2026-10-13 立规,拿钱换来的)

**根因**:`--profile dsh-mobile-test` **只隔进程/插件/端口**;
`~/.dsh/.credentials.yaml`、`~/.dsh/sessions/`、`~/.dsh/storages/` **全是全局共用**。
所以"起个测试 profile"给不了任何隔离感 —— 在里面建会话、发 prompt,
一样记在用户的官方账号上,并且污染他的会话列表(截图里那些"未分组"就是这么来的)。
一次 `interaction_real_device_test.dart` 至少 2 个模型轮次(标记回显 + 审批探针),
此前无人授权地跑了十几轮。

**规矩(下次照做,别问第二遍)**:
1. **不另起测试 profile**。就用用户当前在用的那个渠道/进程 —— profile 只隔进程,
   不隔账号,多起一个只是多一层"我在沙箱里"的错觉。
2. **不撒着用他的现成会话**。测试的挑选过滤(`!running` + 无未决审批)会逐个消耗
   用户的真实会话,还在里面留标记和未决审批 —— 比专用会话更糟。
3. **要一个专用会话,但要走"问 → 建 → 跑 → 删"四步**:跑之前问用户要不要建;
   建一个(名字带 `[可删]`、带上分组,别再是"未分组");测试只往这一个里发 prompt;
   **跑完由用户确认后删掉**——删除是破坏性操作,不擅自做。
4. **每次跑之前报一句"这次约 2 个轮次"**,拿到准再跑。
5. **跑完把自己起的进程杀干净**(profile + 中继),别留着继续计费。

**注意"没有免费会话"**:第五步的审批探针必须 `session.prompt` 让模型跑一条越权命令,
这是真金白银的轮次 —— 不管在哪个会话里发都花用户的钱。"不建新会话"只少污染列表,
省不了钱。想零成本就只有不跑(代价见上:prepend 在活宿主里的效果没验过)。

**已经付出的代价**(未删,要清由用户定):`~/.dsh/sessions/` 下若干
"dsh-mobile 真机联调"会话,散在多个工作区目录里。

**如果哪天想让它免费**:链路的逻辑已由 `connector/tests/interaction-chain.test.ts`
(纯 Node、零成本)覆盖;真机用例只剩"宿主接线"这一件事(应答者 prepend 顺序、
真实 claim、真实 settle)。要再压缩成本,方向是让宿主侧不靠模型就产出一次
`approval/asked` —— 目前没找到非模型路径,所以只能靠"问清了再跑"。

**方法面剩 8 个**:`session.create` / `session.cancel` / `settings.describe` / `settings.update` /
`credentials.set` / `credentials.unset` / `devices.revoke` 不做 / `push.configure` 本期不做。
再往后:`ui/adaptive` / 三端能力包(鸿蒙暂缓)/ 相机扫码。

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
| `node app/tools/verify-platform-boundary.mjs` | **189 项**(22 条规则自检 + 扫 53 个 Dart 文件) |
| `node mock/proto/tools/verify-icons.cjs` / `verify-tool-paths.mjs` | 原型图标集 / 工具脚本不许硬编码盘符 |
| `cd app && flutter test` | **390 项** |
| `cd app && dart analyze --fatal-infos lib test integration_test` | 0 问题(比 `flutter analyze` 严) |
| `cd app && dart format --output=none --set-exit-if-changed lib test integration_test` | 0 文件需重排 |
| `cd connector && pnpm exec tsc --noEmit && pnpm build && pnpm test` | 类型 + 产物 + **369 项** |
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

## 最近活跃窗口(2026-10-13)

- **「交互转手机」整链接线 + 真机验证到「手机答审批」**:presence 上报
  (`connector/src/presence.ts`,四个时机回调)→ `sync.hello`(批量订阅 + 前后台态)→
  `decideTakeover` 第一次真的 claim → `interaction-claims.ts`(看护 + 断开 + fail-closed)
  替换掉那个**永远跑不到**的桩 → `interaction.respond`(每连接)收束在途 claim /
  路由到 `userQuestions.answer`。手机侧:`sync.hello` 上报 + 输入栏接管接真实事件 +
  多题向导 + 显式跳过。见 `.agents/notes/implemented/2026-10-10-interaction-to-phone-chain.md`。
- **真机验证到「手机答审批」**:`app/integration_test/interaction_real_device_test.dart`
  跑到倒数一条断言;卡片出现、答复形状、收束全绿。
- **第三轮推翻了一个误判**:Node 的 zstd 解压**只解第一帧**,而 DSH 会话文件是**逐帧追加**的 ——
  按帧魔术字 `0x28B52FFD` 重解后确认**模型照话了**、`approval/asked` 落了、
  但**没有 `approval/decided`**(应答者从未返回)。这是当前唯一未解的真问题。
- **三个真机才暴露的 bug 已修**:连接器从不拨号(profile 漏 `allowInsecureLocal`)、
  配对成功但换不到票(`main.dart` 的 `PairingClient` 漏同一个字段,已加结构断言)、
  握手成功 20 ms 后断线(`_handleOpened` 把密文喂给 `_accountFlow`,已加回归用例 + 变异校验)。
- **上一轮(2026-10-09/10)**:配对 v2 三侧收口、错误码表补齐、跨实现一致性闭环;
  relay 不再签发设备令牌;直连监听面继续自起监听(关箱)。
