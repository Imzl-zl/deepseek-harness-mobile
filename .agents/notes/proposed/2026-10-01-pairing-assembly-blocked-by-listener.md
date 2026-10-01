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
