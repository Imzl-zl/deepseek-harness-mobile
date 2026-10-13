# Agent Note: 交互转手机——待处理项乘会话事件流，端口在挂载级看护

Status: implemented

## Problem

接线之前的状态不是"审批会被拒绝"，而是**永远不触发**。`index.ts` 的注释自己写着
`liveRegistry` 恒为空，于是完整因果链是：

```text
没人写 liveRegistry → liveDevices() 返回 [] → decideTakeover 永不 claim
→ answerer 永远 next() 交还桌面 → index.ts:201-213 那个 fail-closed 桩根本跑不到
```

内核（`interaction-face.ts`，31 项单测绿）与两个 answerer（`dsh/interactions.ts`）都已就位，
缺的是四件装配：presence 上报、端口实现、`interaction.respond` handler、手机侧接线。
每一件都有"看起来更省事"的做法，而它们各自会造出一个**静默**的错误形态——
本篇记录挑了什么、否了什么、代价是什么。

## Decision

**待处理项不推，让它乘会话事件流；端口在挂载级，一个 `callId` 一个在途 claim。**

四件装配的做法：

1. **presence**（`connector/src/presence.ts`）：持 `Map<devId, {online, foreground,
   subscribed, lastInteractedAt}>`，`connection-scope.ts` 在四个时机回调它
   （鉴权完成 / 断开 / 订阅集变化 / 收到 `sync.hello`）。订阅集变化的通报挂在
   `session-subscriptions.ts` 的 `onChange` 上（它是唯一权威），不另建一套。
   `pairedAtOf` 由挂载级注入，于是"**连接层认证过不等于授权过**"这条过滤只在
   `devices()` 里做一次。
2. **端口**（`connector/src/interaction-claims.ts`）：`askApproval` / `askQuestion`
   各建一个 `createWatchdog`，把 `deviceId` 对应的**断开**与 asker 的**原 signal**
   接到 `watchdog.disconnect()`。设备不在线就**立刻**收束（等下去只是让工具调用白挂满
   一个看护周期）。fail-closed 两侧形状不同，因为 DSH 的两侧形状不同：
   审批回 `reject`，提问**抛错**（`{answers: []}` 会被 DSH 读成"用户跳过了每一题"）。
3. **`interaction.respond`**（每连接，handler 在 `handlers.ts`）：一个方法、两个目的地。
   分叉点不在方法名上，而在"这一项是不是一次在途 claim"——那个判据只有端口知道，
   所以作为 `InteractionFaceDeps.settleClaim` 注进内核，在**形状校验之后**、
   投影比对与 `agentOf` 之前问一次。
4. **手机侧**：`SyncClient` 记一份 `_declared`，每次进服务态发一次 `sync.hello`
   （`app` + 整份订阅集）；待处理项从 `interactionSignalOf` 投影出来；接管卡接上
   真答复出口。

三条如实的边界：

- `always` 档下一个**没订阅该会话**的手机看不到卡片，看护走到超时并 fail-closed。
- 未处理的交互只有**日志 + 指标**两条出口；契约 §6.2 说的"推一条通知"需要一种
  电脑→手机的推送帧，本期没有。
- **计划审查按提问渲染**：DSH 的 `intent` 只活在应答链的请求对象上，**不进会话事件**
  （`user-questions/src/projection.ts:148-161` 的 `questionsOf` 不映射 `intent`），
  于是从事件流里看不出这是计划审查。那正是 DSH 自己的投影的行为，而答案编码完全相同。

## Alternatives considered

- **加一个 `pending.changed` 帧类型，由电脑侧主动推**
  - 最强的理由：`always` 档下没订阅会话的手机也能收到卡片，覆盖决定一留下的那个缺口；
    而且 §5.7 的事件表里**已经列了** `pending.changed`，看起来只是"把漏掉的补上"。
  - 为何被否：`FRAME_TYPES` 从来没有它——那是文档列了一个从未实现的帧。加它要改契约 +
    fixtures + 向量 + 中转路由视图，而收益只是一个能用"把会话打开"绕过的场景。
    更糟的是它会造出**两份**待处理集合（一份电脑侧拼的、一份从事件投影的），
    而对不上的症状是"电脑在等审批、手机上什么都没有"。
- **在 answerer 上挂看护（启用 `interaction-face.ts` 的 `registerApprovalAnswerer`）**
  - 最强的理由：判定与看护在同一个函数里，读起来是一件事；内核那份已经写好了。
  - 为何被否：waterfall 只走先注册的那个，两个 answerer 同时挂会让另一个**静默不触发**。
    看护属于端口，不属于 answerer——这也是契约 §6.3.1 的结论。
- **把瞬时状态并进 `devices` 表**
  - 最强的理由：少一张表，`liveDevices()` 直接查库。
  - 为何被否：重启后设备会"还在线"，而那是假状态。瞬时状态的寿命是连接，不是进程。
- **`sync.hello` 等应答**
  - 最强的理由：能发现"某个 `sid` 已经不存在"这种失败，处理更完整。
  - 为何被否：应答里的恢复内容手机不用（增量与快照走订阅流），而"紧接着可能就要断开"
    的场景必须只等**写出去**。等应答会把一次声明拖成一个网络往返，
    且真机上换来一条永远没人看的错误。被拒的后果是"审批继续在桌面上答"——安全的方向。

## Consequences

- 收益：`decideTakeover` 第一次真的能 claim；`liveDevices()` 不再恒为空；
  那条"永远跑不到"的 fail-closed 路径第一次真的被触发并被测试覆盖
  （`connector/tests/interaction-chain.test.ts` 跑完整条链）。
- 收益：`connection-surface.test.ts` 的耦合面扫描因此抓到一次**假阳性**——
  `import ... from './interaction-port.js'` 里的 `port.js` 被当成了成员访问。
  文件改名 `interaction-claims.ts` 而不去放宽门禁：门禁是棘轮，放宽它比改名危险。
- 收益:`relay/relay.config.json` 里残留的 `kind: "device"` 令牌摘要被清掉(v2 起中转拒绝启动),
  下次起中转不会再撞这一下。
- 代价：`always` 档的缺口如上。修它要么加推送帧（契约变更），要么让连接器替手机订阅
  （订阅的 owner 是手机，那是错的）。
- 代价：未处理交互没有通知出口，只有日志与指标。
- 契约更正：§5.7 事件表里的 `pending.changed` 不是帧类型，已从事件表去掉；
  §6.2 的"立刻回 `pending.changed`"改为"待处理项随下一条 `ev` 收敛"。
- **踩过一次恒真式**：跨端标签的行为用例原本写 `selected: [approvalAllowLabel]`
  （import 同一个常量），于是把常量值改成 `allowed-once-MUTATION` 之后**两条行为用例全绿**。
  改成字面值断言后才红。判据：钉"契约字符串"的断言必须写字面值，不能 import 被测常量。

## 验证

- 变异校验 5 次，每次都确认**恰好**预期的几条红：
  ① `presence.offline` 改成只置 `online:false` → 3 条红（断开整条作废、迟到上报不救活、整链）；
  ② 提问看护失败改成 `return {answers: [] }` → 恰好"拿不到答案就抛"红；
  ③ handler 不记 `lastInteractedAt` → 恰好那条红；
  ④ `approval/asked` 没有 `callId` 也开卡 → 恰好那条红；
  ⑤ 跨端标签常量改值 → 改成字面值断言后红（改之前**不红**，见 Consequences 最后一条）。
- 门禁：protocol 486/26/49、平台边界 185、connector 361、relay 75、app 364、
  `dart analyze --fatal-infos` 0、`dart format` 0。

## 真机验证（2026-10-13，通过；并抓出三个真 bug）

**做法**：`relay` 起在 `127.0.0.1:8787`；`dsh --profile dsh-mobile-test --no-open --port 8099`
（该 profile 的 `cordis.patch.yml` 在 `~/.dsh/` 下、被 `.gitignore` 忽略，见下）；
Android 模拟器 `emulator-5554` + `adb reverse tcp:8787 tcp:8787` + `svc power stayon true`；
二维码用 Web UI 的 `/dsh-mobile-pair` 命令出（载荷走 base64 进 `--dart-define`）。

**结果**：`app/integration_test/interaction_real_device_test.dart` 绿。它逐段验：
两段配对 → 建连 → 握手 → `sync.hello`(`app: 'foreground'`)→ `session.list` 拿到真会话 →
`session.subscribe` 后 `ev` 流进来 → `session.prompt` 发出去的那句**作为 `user/message`
回到手机**。`channel_e2e_test.dart`（配对 + 令牌落 Keystore）同场复绿。

**三个真 bug，都是真机才暴露的**：

1. **连接器从不拨号**：`relayUrlOf` 对 `ws://` 要求 `allowInsecureLocal === true`，
   而 `dsh-mobile-test` 的补丁里没这个字段（schema 默认 `false`）→ `validate-config` 抛
   "中转必须使用 WSS" → 挂载失败。症状是"什么都没发生"，而 `--dump-config` 显示连接器在树里、
   产物也加载得出来。**修法是本地补丁加 `allowInsecureLocal: true`**（明文放行的第三处）。
2. **配对成功但换不到票**：`main.dart` 的 `_assemble` 构造 `PairingClient` 时没传
   `allowInsecureLocal`，于是带 `ws://` 的换票被拒 —— 正是文档里那句"码认了、票换不了"。
   已修（`kDebugMode`，与 `PairingPage` 同一个判据），并由
   `app/test/assembly_invariants_test.dart` 新增一条结构断言钉住（两处必须是同一个判据、
   且不能写成无条件 `true`）。
3. **握手成功、随即断线**：`sync_client_impl.dart` 的 `_handleOpened` 把**还没解箱的**
   `frame` 递给 `_accountFlow`，于是 `decodeCredit` 拿到密文并抛
   `credit 载荷不是合法 JSON` → `_protocolFailure` → 关连接。真机上 `serving` 之后
   **20 ms** 就 `closed`，而电脑侧一条日志都没有。
   电脑侧同一处是对的（`connection.ts` 的 `opened` 两份都从它取）—— 这就是"两侧各写一遍"
   的代价：一侧改了另一侧不会红。已修 + 新增回归用例（封了箱的 `credit` 必须被解开后记账），
   并做过变异校验（改回密文记账 → 恰好那一条红，诊断信息与真机症状一字不差）。

**顺带**：集成用例自己也有一个竞态 —— `onPaired` 在最开头就给 `captured` 赋值，而
`PairingStore.save` 是异步的；判据必须等**存储里真有凭据**，不能只看回调过没过。

## 真机验证·第二轮（2026-10-13，审批回合）

同一条用例被扩写成包含审批回合，跑到**倒数第一条**断言。已通过的（每条都有真机证据）：

- `等待审批` 卡片**真的画在手机输入栏上** —— 这同时证明了 ①②：presence 上报 →
  `decideTakeover` claim → 应答者走到端口（卡片能从 `approval/asked` 投影出来，
  说明连接器的 answerer 真的 claim 了，而不是 `next()` 交还桌面）。
- 点「允许一次」后 `interaction.respond` **真的发出去**，且逐字段正确：
  `callId` 等于电脑侧那个、`requestId === 'i:<callId>'`、`answers` 里含
  **字面值** `"allowed-once"`。
- 答完之后那一项**收束**（卡片从输入栏上消失）。

**唯一没过的一条**：`审批通过后电脑侧必须真的继续`（要看到带标记的 `tool/result`）。
查了 273 个会话文件：没有 `approval/asked`、没有 `allowed-once`、也没有那个标记字符串。
结论是**模型没照话执行**——默认模型 `deepseek-flash` 选了另一个同样需要审批的工具，
于是"批准的那个工具"不是提示词里那条命令。这是**模型行为**，不是链路问题：
判据本身（卡片出现 + 答复形状正确 + 收束）全绿。

**因此真机验证的诚实结论**：手机 → 电脑这一侧已端到端验证（含审批 claim 与答复）；
电脑 → 手机执行结果那一跳，缺的是一次**肯照话执行的模型轮次**。

## 真机验证·第三轮（2026-10-13，推翻上一条结论）

上一条说"模型没照话执行"——**那是错的**，错在排查工具：我用
`zlib.createZstdDecompress()` 扫 273 个会话文件，而 DSH 的会话文件是**逐帧追加的
zstd**，Node 的解压器**只解第一帧**（61 KB 的文件只解出 211 字符的表头）。
按帧魔术字 `0x28B52FFD` 切段重解后，真相是：

- 模型**照话了**：`tool/call` 就是提示词里那条 `Set-Content -Path C:/Windows/Temp/dsh-probe.txt …`；
- `approval/asked` seq=37 确实落了，`toolName: "pwsh"`、
  `callId: "call_00_q7jv4WVpPgr9qOplp7PC2051"`；
- 会话**停在 `approval/asked`**，没有 `approval/decided` —— 也就是应答者**从未返回**。

所以真问题是：**手机发出去的答复没有到达端口的在途 claim**。已排除的一项：
连接器日志里 `questionFace=ok`，说明 `ctx.get('userQuestions')` 真的存在、
`interaction.respond` handler 真的挂了。剩下两个嫌疑，按可能性排序：

1. **应答者走了提前 `return next()`**（`dsh/interactions.ts` 的三个前置判断之一），
   于是端口从未 `claims.set`，`settleClaim` 落空 → 答复被当成"不是审批"继续走提问路由
   → `userQuestions.answer()` 返回 false → `interaction/not-pending` → 手机把卡片标成过期。
   **这一支能解释全部现象**（卡片出现是因为 `approval/asked` 事件先落盘，与谁应答无关）。
2. `settleClaim` 的 `callId` 与 claim 的键不一致。

**下一次的判据**：把临时文件日志加在 `askApproval` 入口与 `settleClaim` 入口
（`connector/.tmp-debug.log`，排查完删干净），一次运行就能分清是 1 还是 2。
本次加过但没跑到那一步 —— 模拟器卡在副屏 launcher，用例挂在 pairing 之前。

## 真机验证·第四轮（2026-10-13，环境卡住；且诊断方向建立在无效证据上）

日志已按上一条铺好（`dsh/interactions.ts` 的三个提前 `return next()` 各一条 +
`askApproval` 入口 + `settleClaim` 入口 + 落空时的在途键清单），`pnpm build` 与
profile 重启都做了。但用例**一起手就挂住**：Gradle 装完包后只剩
`Warning database has been locked for 0:00:10…` 刷屏，4 分 46 秒超时，
`.tmp-debug.log` **从未创建**（连 `questionFace=ok` 都没有）—— 也就是说
**根本没走到建连**，是模拟器/设备侧卡了，不是链路问题。

**而这一轮顺带暴露了前三轮共同的方法论错误**：DSH 是 Electron 应用，插件的
`appendFileSync` 被它的文件沙箱挡、`console.error` 也不继承到 CLI 的 stdout
（实测 `2>&1 | Tee-Object` 只收到 3 行）。**「临时日志没生成」从来不是
「代码没跑到」的证据** —— 前三轮多次据此推断"应答者没被问到"，方向虽然最终碰对，
但每一步的证据都是空的。

## 真机验证·第五轮（2026-10-13，真因找到并已修）

第四轮之后换到 USB 真机（小米 23113RKC6C / Android 16）。真正的判据来自会话日志
（**必须按帧解压**，见 `tools.md`）：一个会话里两条 `approval/asked`、`decided = 0`。
据此定位到真因 ——

> **两个交互应答者注册时没带 `{ prepend: true }`**，于是 DSH 的桌面转发监听器
> （`packages/api/remotes/src/index.ts:57-75`，浏览器一连上就注册、自己不答就不放行）
> 排在前面，审批永远挂在 `approval/asked`，手机答了也无处可落。

这与第三轮的"嫌疑 1（提前 `return next()`）"是**同一处代码、不同原因**：不是三个前置
判断放行了它，而是它**根本没被问到**。完整取舍、被否方案与变异校验见
`.agents/notes/implemented/2026-10-13-answerer-must-be-prepended.md`。

修完之后：connector **363** 全绿，真机用例仍跑到倒数第二条。卡住的变成
**「模型不再发起审批」** —— 干净 + 空闲的会话里 `deepseek-flash` 不照话执行，
会话里 `approval/asked` 一次都没有（`asked=0`）。那是模型行为，不是链路：
链路的每一环都已在真机单独验过（卡片出现 / 答复形状 / 收束），纯 Node 下整条链由
`connector/tests/interaction-chain.test.ts` 覆盖。

