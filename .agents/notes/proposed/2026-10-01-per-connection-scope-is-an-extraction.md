# Agent Note: "每连接状态"不是重构——它是**一次抽取**（实测：4 个成员、9 处调用）

Status: proposed（测量已完成，方案已具体到可直接执行；我此前对它的规模判断**过于悲观**）

## 我此前怎么判断的（错在哪）

第 25 轮我写下：监听面 accept 第二条 socket 时，"方法面 / 订阅 / 增量缓冲 / 配对端点"全都指向第一条连接，
而它们是在 `start-transport` 里**一次性**构造的 —— 于是结论是"要拆 `start-transport` 成按连接装配，
这是一次真正的架构改动"。第 43、49 轮我又按这个判断把这件事往后推了两次。

**我从来没有数过那条缝有多宽。** 这一轮数了：

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

## 因此它是一次抽取，不是重构

具体到可执行：

1. 定义窄端口 `ConnectionPort = Pick<Connection, 'send' | 'sendPairingFrame' | 'whenWritable' | 'state'>`
   —— **4 个成员**，与上面那张表一一对应；
2. 把 `start-transport` 里那段"构造处理器表 + 订阅 + 缓冲 + 分页器 + 配对端点"搬进
   `createConnectionScope(port, deps)`，返回这些构造物（它们只通过 `port` 碰连接）；
3. 拨号路径：`const scope = createConnectionScope(next, deps)`（行为完全不变）；
4. 监听路径（将来）：每 accept 一条 socket，`createConnectionScope(它自己的连接, deps)` ——
   **多设备自然成立**，不需要"单活动连接"那个会退化 §5.5 裁剪语义的妥协。

规模估计：**移动约 150 行、改 9 个调用点、加一个类型**。测试侧不需要新替身
（`deps` 与 `port` 都是现成的形状，fixture 已经在这条路上 —— 见第 65 轮的结论：
**"需要 DSH 替身才能测"往往是可以避免的**）。

## 这一轮的收获（比方案本身更值钱）

**"这是个大改动"的判断，应该先量再下。** 我在三轮里把这件事当成架构重构推后，
而它其实是一次 150 行的搬家 —— 差别在于我从未问"那条缝到底有多宽"。
可复用的做法：**用一次 grep 把耦合面量化**（数调用点、去重成员），再决定"重构"还是"抽取"。
这与第 61 轮那三个问题（零值 / 会增长 / 能调）是同一类纪律：**先量，再判断**。

## 执行顺序（单次上下文可完成；每步都能独立回退）

关键性质：**每一步都保持行为不变**，所以任何一步失败都可以只回退那一步，不必回到起点。

| # | 移动什么 | 为什么放这个位置 | 每步之后跑 |
|---|---|---|---|
| 1 | **配对端点**（`createPairingEndpoint` 的构造） | 最小、依赖最少（`pairingCore` + `devicesTable` + 端口的 `sendPairingFrame`）；用它**证明抽法**，风险最低 | `tsc` + `connection-surface` 门禁 + `pnpm test` |
| 2 | **会话分页器 + 增量缓冲**（`sessionPager` / `sessionBuffer`） | 它们是纯数据层，只从订阅拿 `cursor`/`ack`；不碰出帧 | 同上 |
| 3 | **两个订阅注册表**（`jobSubscriptions` / `sessionSubscriptions`） | 它们通过端口的 `send` / `whenWritable` 出帧 —— 背压语义要原样保留 | 同上（`job-subscriptions` / `session-subscriptions` 用例是判据） |
| 4 | **处理器表 + 方法面** | 依赖前三者（handlers 的 deps 里就有它们） | 同上 + `handlers`/`connection-methods` 用例 |
| 5 | **收口**：删掉临时参数、把 `createConnectionScope` 的返回值一次性喂给 `handleFrame` | 此时 `port` 已成唯一入口 | 全量门禁 |

**做法（第 1 步的具体形状，作为后续四步的模板）**：

1. 把那段构造搬进一个 `const wirePairingEndpoint = (port: ConnectionPort) => createPairingEndpoint({...})`
   —— 内部把 `next.sendPairingFrame(...)` 换成 `port.sendPairingFrame(...)`；
2. 在 `const next = createConnection({...})` 之后加 `const pairingEndpoint = wirePairingEndpoint(next)`；
3. `handleFrame` 的 `case 'pair'` 引用它（它必须声明在 `handleFrame` 之前）。

**门禁的行为**：`tests/connection-surface.test.ts` 同时数 `next.` 与 `port.`，而两条路上的成员
并集仍必须是那 4 个 —— 所以"搬一半"不会让它变红（调用点换了一条路，成员集合不变），
而"顺手加第 5 个成员"无论从哪条路都会红。这正是它该有的灵敏度。

**完成后立刻做的两件事**（否则这次搬家的收益会停在"更整齐"上）：

1. **给监听面留好接缝**：`createConnectionScope(port, deps)` 的 `port` 参数就是将来"每条 socket
   各一份"的入口 —— 那时 `ws` 进连接器的运行时依赖，并复用已就位的 `attach(socket)`。
2. **改写 `docs/subsystems/connector-and-relay.md`**：现在那里描述的是"一条连接"的装配，
   而多设备装配才是 §5.5（"全部配对设备都确认才裁"）真正要求的东西。
