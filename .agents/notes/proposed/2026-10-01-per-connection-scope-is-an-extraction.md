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

## 仍未做

- 执行上面 4 步（下一轮，规模已知）；之后才谈"桥接监听面"本身（它还要 `ws` 进连接器的运行时依赖）；
- 手机端 Dart 客户端；真机联调；中转多实例。
