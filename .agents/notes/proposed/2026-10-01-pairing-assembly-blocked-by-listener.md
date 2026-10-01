# Agent Note: 出码入口的 API 已查清，但装配前撞上一个真障碍：桥接只会拨号

Status: proposed（`src/pairing.ts` 与 `src/pairing-endpoint.ts` 已就绪；**产品装配被一个架构缺口挡住**）

## 查证到的事实（都不再需要猜）

- **斜杠命令的注册面**：`ctx.commands.register(definition): () => void`
  （`packages/interaction/commands/src/index.ts:285`）。
  `CommandDefinition = { name（小写、不带斜杠）, description, handler(invocation) }`（同文件 `:61-77`）。
  `CommandResult = { kind:'success'; text?: string } | { kind:'error'; text: string }`
  （`packages/interaction/commands/src/types.ts:34-43`）。
  所以"电脑侧出码"这条入口可以做得很小：一个命令，`handler` 里 `pairing.offer()`，
  把 `payload` 放进 `text` 返回给操作者。
- **设备行的字段名**：`store/` 的 `devices` 表是 `{ edPub, dhPub, name, pairedAt, pairingId, revokedAt? }`
  （`connector/src/store/index.ts:46-60`）——注意与 `pairing.ts` 里设备行的 `edPubHex` / `dhPubHex`
  **拼写不同**，装配时要逐字段映射（这正是"顺手 spread 一下"会踩的坑）。
- **本机公钥怎么来**：`Identity` 只有 `{ masterSeed, keys }`（`dsh/identity.ts:53-56`），
  而二维码要的是**公钥**；`deriveIdentity(masterSeed)` 就给出 `sign.publicKeyHex` / `dh.publicKeyHex`
  （`protocol/crypto.ts`，fixture 里就是这么用的）。

## 真障碍：桥接是**客户端**，没有监听面

`createConnection` 是 `{ url, dial }` 形状（`connector/src/index.ts:434-437` 传的是
`dial: (url) => new WebSocket(url)`）——**桥接只会连出去**，不会接受连接。
而契约 §2 的拓扑正是 `[手机] ⇄ [中转] ⇄ [桥接]`：**手机连的是中转**。

于是"直连配对"（二维码里带电脑的地址、手机直接连电脑）在当前架构下**做不到**：
即便电脑在 Tailscale 上可达，也**没有东西在监听那个端口**。要走这条路，必须先给桥接加一个监听面
（接受 WSS 连接 → 复用同一个 `createConnection` 的核心逻辑）；而 `createConnection` 目前的形状
（`dial` 是外部注入的）说明它能支持这件事，但"接受连接"这条路径**还没有被写过**。

## 因此本轮的处理

**不硬塞装配代码**。理由：装配的核心价值在于"配对成功后能真的握上手"，
而这条链路的最后一环（谁接受连接）现在没有答案；把出码入口与端点先接上，
只会得到"二维码扫了、`pair` 到了、设备行写了、然后**没有任何东西能接住手机的握手**"的半成品，
而那种半成品在真机上表现与"配对没做"一样。

## 摆在面前的两条路（需要定夺，不是我可以自行选定的）

1. **先做 `relay/`**：照契约 §2 的拓扑。手机连中转，中转连桥接（桥接仍然是客户端 ✓ 现有形状就够）。
   代价：中转是一个全新组件——配对请求的转发与记账、设备令牌签发（§12.2）、限流、重放窗口。
2. **给桥接加监听面**：让二维码里的地址就是电脑自己（Tailscale 直连），
   配对与后续握手都直连。代价：`createConnection` 要支持"接受连接"（现在是拨号专用）；
   但之后**真机联调不需要中转**，这是最短路径。

两者的**配对逻辑与帧协议完全相同**（`pair` / `pair-ack`、`codeHash`、`pairingId` 派生），
所以这个选择**只影响传输装配**，不影响已完成的任何一层。

## 选 2 之前必须知道的一件事：接受来的连接**不该自愈**

读了一遍拨号路径（`connection.ts:530-594`），`connect()` 做四件事：重置（`window` / `handshakeDone` / `session`）
→ `options.dial(url)` → 接线（`onopen` 里 `transition('handshake')` + 建握手会话；`onmessage` → `handleMessage`；
`onclose` 收口）→ `onclose` 里**退避重连**（`transition('closed')` → `backoff` → `schedule(connect)`）。

关键在于最后一件：**拨号连接的 `onclose` 会自己连回去**。而"接受来的连接"没有拨号目标 ——
它的对端走了就该由**监听面**决定要不要再接一个，而不是让这条连接去拨一个它从未拨过的地址。
所以 `attach(socket)` 不是把接线那段抽出来就完事，它引入的是**第二种生命周期**：

| | 拨号连接（现役） | 接受连接（要加的） |
|---|---|---|
| 谁发起 | 本侧 `dial(url)` | 对端（监听面 accept 后交给它） |
| 就绪事件 | `onopen` 会触发 | **已经 OPEN**：`onopen` 不会再触发，得直接走一次"打开"处理 |
| 断开后 | 退避重连 | **不重连**，收口后由监听面决定（`stopped = true` 或交给下一条连接） |
| 地址 | 一个必须配置的 `url` | 没有 `url`（`url` 只是给 `dial` 用的） |

**可复用的那一段**：`onmessage` → `handleMessage` 与 `onclose` 的收口（清 `socket`/`session`/`cipher`、
`transition('closed')`）两边完全一样；而"打开之后做什么"（`transition('handshake')` + 建握手会话）
也一样，只是触发时机不同。所以正确的抽法是 `wireSocket(socket, { alreadyOpen })` 加一个
"要不要自愈"的开关，而不是抽完 `onopen` 就以为完事。

**这一步的意义**：它把"加个监听面"从"再写几百行"缩成"抽出一段接线 + 一个生命周期开关"，
但**必须先想清楚不自愈这条**（否则接受来的连接会在对端断开后去拨 `relayUrl`，
症状是"监听模式下桥接莫名其妙连去中转"）。

## 进展（同日）：接受路径已经落地

按上面那张表实现了 `attach(socket)`（`connector/src/transport/connection.ts`）：

- `connect()` 里那段接线抽成了 **`wireSocket(socket, { alreadyOpen, heals })`** ——
  "打开之后做什么"提成 `onOpen()`，拨号与接受共用同一份；
- `attach(socket)` 用 `{ alreadyOpen: true, heals: false }`：**直接**走一次 `onOpen()`（不等 `onopen`），
  断开后**不自愈**；
- 测试 `tests/connection-accept.test.ts`：真 `ws` 服务器 accept → `attach` → 状态**直接进 `handshake`**
  （证明 `alreadyOpen` 那条），对端断开后 `dials === 0` 且状态**不是** `backoff`/`connecting`
  （证明不自愈那条）。拨号路径行为不变（原有 244 项一条没改地绿）。

**仍然缺的**（剩下的是装配，不是机制）：
1. **监听面本身**：一个接受 WSS 连接并把它交给 `attach` 的地方（`ws` 的 `WebSocketServer` +
   与 `createConnection` 的接线），以及它在生命周期里的位置（与拨号互斥还是并存）。
2. **产品的出码入口**：`ctx.commands.register` 那条命令（API 已查清，见上）。
3. **端点装配**：把 `pairingEndpoint` 接进 `index.ts` 的 `handleFrame`（`case 'pair'`）与
   `devices` 表写入（注意 `edPubHex` → `edPub` 的字段改名）。
4. **`pair` → 握手 → `session.prompt` 的本机回环 e2e**：接受路径上把整条链路跑通
   （不需要 Tailscale，先把同一台机器上的"配对 → 发送"证出来）。
