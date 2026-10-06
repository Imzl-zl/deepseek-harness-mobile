# Agent Note: 监听面撬动的是"每连接状态"——两个必须先定的事实

Status: archived（2026-10-02 被 `implemented/2026-10-02-listener-face.md` 取代：两件事都定了，
监听面已落地。本篇结论不改，只作历史记录）

> 取代者：`.agents/notes/implemented/2026-10-02-listener-face.md`
>
> 两件事的结局：
> - **事实一（`ws` 依赖）**：定了 —— `ws` 进 `dependencies`，成为本插件第一个运行时依赖。
>   本篇列的"要么接受它、要么只在测试模式启用监听"两条路里选了前者，因为后者等于
>   "真机直连不是产品能力"，而契约 §14.6 要求先跑通直连。
> - **事实二（单槽 `connection`）**：先由 `implemented/2026-10-01-per-connection-scope-is-an-extraction.md`
>   解决（每连接装配抽成 `createConnectionScope`，实测只有 4 个成员），
>   本篇列的三条路里走了"路 1（每连接一套）"。
>
> 本篇还留着一个当时没看出来的东西：它说 `attach(socket)` "已经就绪"，而实际上
> `attach()` **没有起 `start()` 的那两个周期任务**（攒批 flush 与保活判定）——
> 所以它当时并不真的就绪。这个缺口在落地时先被复现、后被补上，见取代者那篇的 Problem 第二节。

## Problem

### 一、我把这件事当成"架构重构"推后了三轮

第 25 轮我写下：监听面 accept 第二条 socket 时，"方法面 / 订阅 / 增量缓冲 / 配对端点"全都指向第一条连接，
而它们是在 `start-transport` 里**一次性**构造的 —— 于是结论是"要拆 `start-transport` 成按连接装配，
这是一次真正的架构改动"。第 43、49 轮我又按这个判断把它往后推了两次。

**我从来没有数过那条缝有多宽。** 第 66 轮数了：

```
2x  if (next.state !== 'serving') return 'closed'
1x  if (!next.send(response)) { ... }
1x  next.send({ v: 1, t: 'pong', box: '' })
1x  next.sendPairingFrame({ v: 1, t: 'pair-ack', ... })
1x  next.start()
1x  return next.send({ v: 1, t: 'job', sid, box: ... })
1x  return next.send(frame) ? 'sent' : 'paused'
1x  waitWritable: () => next.whenWritable('ev'),
1x  waitWritable: () => next.whenWritable('job'),
```

**9 处，去重后只有 4 个成员**：

| 成员 | 用途 |
|---|---|
| `send(frame)` | 出帧（应答、事件、任务输出、pong） |
| `sendPairingFrame(frame)` | 配对回执 |
| `whenWritable(type)` | 背压（订阅在满窗时等它） |
| `state` | 只在 `serving` 时算"已投递" |

（`next.start()` 是**连接自己的生命周期**，不属于"每连接状态"。）

### 二、落地时才发现：清单里混进了一个**跨连接**的量

第 66 轮的执行清单把 `sessionBuffer`（增量缓冲）和 `sessionPager`、两个订阅注册表并列，
都划给了"每连接"。真去搬的时候才看明白：**增量缓冲是跨连接的** —— 它的文件头第一句就写着理由
（"手机断线重连后要'从上次的水位接着收'"）。见 Decision 的第二条。

## Decision

**把每连接的构造物搬进 `createConnectionScope(port, deps)`，`port` 就是"每条 socket 各一份"的入口。**

`deps` 里全是**挂载级**的东西（会话与任务适配器、幂等表、配对核心、设备行写入、能力位），
一条 socket 一份的只有 `port`。拨号路径行为不变；监听面将来每 accept 一条就调一次，多设备自然成立。

### 落地时的一处偏离：增量缓冲留在挂载级

原清单说搬，实现**没搬**，理由是三条叠在一起：

1. 它的存在理由就是"断线重连后按 `since` 接着收"。挂在连接上，新连接一建缓冲就是空的 ——
   `tailFrom` 覆盖不到水位，恢复语义**静默退化成每次灌一份完整快照**
   （症状是"每次重连都从头刷一遍"，不报错、不告警）。
2. **翻页器跟着它一起退化**：`session.page` 的水位来自订阅面的开启帧缓存，
   而那个缓存是每连接的 —— 重连后就没了。而水位**恰好**能从缓冲里补回来
   （`tailFrom` 找得到 `since + 1` 时，`since` 就是可用的基线切点）。缓冲留在挂载级时这条路是通的。
3. 它的裁剪点本来就是**跨设备**的量（§5.5"全部配对设备水位的最小值"），而设备横跨连接。

因此 `sessionBuffer` 与 `sessionPager` **分开归属**：缓冲挂载级，翻页器每连接（它的 `cursorOf`
要读**本条连接**的订阅水位）。

准入门槛（可机械判定）：

1. **4 个成员，一个不多**：`ConnectionPort = Pick<Connection, 'send'|'sendPairingFrame'|'whenWritable'|'state'>`，
   而 `tests/connection-surface.test.ts` 扫 `index.ts` 与 `connection-scope.ts` 的源码，
   断言成员集合**恰好**是这 4 个（加第 5 个即红）。
2. **每连接的三件东西不许从外面传进来**：`ConnectionScopeDeps.handlers` 是
   `Omit<HandlerDeps, 'jobSubscriptions'|'sessionSubscriptions'|'sessionPager'>` ——
   类型上就传不了，"两条连接共用一个订阅表"这种不会报错、只会串台的状态写不出来。
3. **每连接装配不知道宿主长什么样**：`connection-scope.ts` 不收 `ctx`、不 import `@deepseek-ai/*`。
4. **`scope` 必须在 `next.start()` 之前赋值**：`start()` 会**同步**推进状态（`idle → connecting`），
   回调里的 `scopeOf()` 是装配顺序的断言，不是防御性写法。

## Alternatives considered

1. **保持原样（每连接构造物留在 `start-transport` 里）**
   - 最强的理由：零风险，不动一行已经测通的装配代码；多设备是一个还没有排期的功能。
   - 为何被否：它把代价推到将来 —— 那时要一边加监听面一边改装配，两件事的失败面叠在一起。
     而这条缝**只有 4 个成员**（实测）：现在搬是一次搬家，将来搬就是在一个同时在长大的函数里搬家。
2. **增量缓冲也搬进 scope（＝第 66 轮原清单的步骤 2）**
   - 最强的理由：清单整齐 —— "每连接的活物"一个不落，归属规则一句话说完，不用记例外。
   - 为何被否：见 Decision 的三条。整齐换来的是**恢复语义静默退化成快照**，
     而这类退化的表现是"每次重连多刷一份快照"，看起来只是慢，不会有人报 bug。
3. **`createConnectionScope` 收 `ctx`（宽依赖）**
   - 最强的理由：省掉一层翻译 —— `caps` / `jobs` / `jobController` / `sessionController`
     都在原来那几行旁边，装配代码几乎不用动。
   - 为何被否：那会让"每连接装配"与宿主版本耦合，多设备那条路（将来可能由监听面或另一份装配驱动）
     就得各自再写一遍取服务的逻辑 —— 而两处取服务的写法正是会分叉的地方
     （`caps.ts` 记着"拼错的服务键静默返回 undefined"这个坑）。
4. **单活动连接的妥协（后来者连上就踢掉前一条）**
   - 最强的理由：不用改装配，`currentDeviceId` 这个单值也不会失真。
   - 为何被否：它会让 §5.5 的"全部配对设备都确认才裁"退化成"最后一条连接确认就裁" ——
     裁剪语义被悄悄改掉，而这条语义正是增量缓冲存在的理由。等于用"少写一层"换一个协议不变量。

## Consequences

- 收益：监听面 accept 第二条 socket 的接缝就位（`port` 即入口，连接层的 `attach(socket)` 已在）；
  耦合面被**类型**（`ConnectionPort`）与**运行时门禁**（扫源码断言 4 个成员）从两侧钉住；
  `index.ts` 的 `start-transport` 只剩"建挂载级依赖 → 拨号 → 建 scope"，挂载级与每连接的分界在代码里可见。
- 代价：`onStateChange` 现在只终止订阅流，**不**清缓冲 —— 未确认的区间会留到该设备重新连上并
  `persisted`（或超限转为"只走快照"）。缓冲自带 10000 条 / 16 MiB 上界，所以不会无界增长，
  但"断开即释放"这条直觉在缓冲上不再成立。
- 代价：`scope` 只能在 `createConnection` **之后**赋值（它需要 `port`），所以三个回调都要经过一个
  `null` 检查。选了"抛错断言"而不是 `scope?.`：后者在装配顺序错了的时候是**静默丢帧**。
- **监听面落地时会撞到、本轮未解决**：两条连接都订阅同一个会话时，同一批 `seq` 会被两条流各记一次。
  缓冲的 `record` 只接受严格递增，于是后记的那条被拒绝并留声 —— 语义上没错（缓冲只留一份，
  两台设备各自的帧仍从各自的 `port` 出去），但会有持续告警噪音，需要在订阅面上做会话级去重。
  （落地时改判：**不需要**去重表，只需把这条日志从 `warn` 降为 `debug` —— 见取代者那篇的
  Alternatives 第 5 条。）

## 这一轮的收获（比方案本身更值钱）

**"这是个大改动"的判断，应该先量再下。** 我在三轮里把这件事当成架构重构推后，
而它其实是一次 150 行的搬家 —— 差别在于我从未问"那条缝到底有多宽"。
可复用的做法：**用一次 grep 把耦合面量化**（数调用点、去重成员），再决定"重构"还是"抽取"。
这与第 61 轮那三个问题（零值 / 会增长 / 能调）是同一类纪律：**先量，再判断**。

**同一条纪律第二次生效**：落地时没有照着清单搬 `sessionBuffer`，而是回去读了它的文件头 ——
清单是上一轮的判断，而它的理由写在代码里。清单错了就改清单，别改事实。

## 落地时改动的文件

| 文件 | 做了什么 |
|---|---|
| `connector/src/connection-scope.ts` | **新增**：每连接装配（`createConnectionScope` 与它的 deps / 接口） |
| `connector/src/index.ts` | `start-transport` 只剩挂载级依赖 + 拨号 + 建 scope；删掉 `currentDeviceId` |
| `connector/src/transport/connection.ts` | `ConnectionPort` 的注释改成"已有调用方"（类型本身上一轮就已声明） |
| `connector/tests/connection-surface.test.ts` | 扫描范围 `index.ts` → 两处；断言不变（仍是那 4 个成员） |
| `connector/tests/connection-scope.test.ts` | **新增** 2 条：两条连接互不串台；设备身份每连接 + 缓冲挂载级共享 |

证据：`tsc --noEmit` 0 错、`pnpm test` **275 项**全绿（273 + 新增 2）、`pnpm build` 出产物。
两处变异校验：把出帧口改成"最后一条连接" → 新用例 3 ms 内红（A 的 pong 落到了 B 的端口上）；
在 scope 里加第 5 个成员 `port.attach` → 耦合面门禁红（`actual` 里多出 `attach`）。
