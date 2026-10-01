# Agent Note: 连接器侧的配对装配 —— 收到 `pair` 就能配上（但**还出不了码**）

Status: implemented（收码回来那半条路；出码入口与中转登记见"仍未做"）

## Problem

`pairing.ts`（核心）、`pairing-endpoint.ts`（判定与落行）与配对帧（`pair` / `pair-ack`）都已就绪，
但**插件里没有任何地方把它们接起来**：`handleFrame` 的 `switch` 没有 `pair` 分支，
`pairingEndpoint` 从未被构造。于是"手机带码回来"这条路在产品里是不通的。

## Decision

在 `start-transport` 里构造配对核心与端点，并在 `handleFrame` 里加 `case 'pair'`：

- **公钥由主种子派生**（`deriveIdentity(local.masterSeed)`）—— `Identity` 只存 `{ masterSeed, keys }`，
  二维码要的是**公钥**，所以这一步是必需的，而不是"顺手再算一遍"。
- **`putDevice` 落 `devices` 表**，并在这一层做字段名对齐：配对的设备行叫 `edPubHex` / `dhPubHex`，
  域表叫 `edPub` / `dhPub`。这种"两个形状差一个词"的地方最容易被 `spread` 静静糊过去，
  所以显式逐字段写，并在注释里点名。
- **`pair` 不是方法面方法**：它没有 `sid`、不走 `req`，所以**不能**交给 `methodFace` ——
  它是与握手帧同级的"密钥建立之前"的帧，直接进端点。
- `devicesTable` 的类型从 `{ get, keys }` 放宽到含 `put` —— 它是**唯一**能让设备数增加的路径，
  所以这一步也让"设备从哪来"这个问题在类型上有了唯一答案。

## 覆盖情况的诚实记录

- **被测的**：端点的判定与落行（5 条单测）、连接层收发明文配对帧（2 条）、
  以及真 socket 上的 `pair` → 设备行 → 明文 `pair-ack`（1 条 e2e）。这些覆盖的是**逻辑**。
- **未被测的**：本轮加的那几行**装配胶水**（构造核心与端点、字段映射、`switch` 分支）
  —— 它们只在插件挂载时才会被执行，而本仓没有"挂载整个插件"的测试夹具
  （标准做法是用 `tests/support/secure-connection.ts` 的 fixture，它装配的是同一套端点逻辑）。
  这是**已知的测试缺口**，记在这里而不是假装它不存在：要补它需要先有一个能挂载插件的夹具
  （DSH 侧的服务替身），那是一件独立的事。

## Consequences

- 收益：产品里"手机带码回来能配上"这条路通了（校验 → 落设备行 → 明文回执）；
  设备行的写入有了唯一入口，且字段对齐写在写入点旁。
- 代价/仍缺：
  1. **还出不了码** —— `pairingCore.offer()` 没有调用方。没有码就没有二维码，
     上面这条路在真机上**走不到**（这是本轮之后最该补的一步，且它需要 `ctx.commands` 的注册面，
     上一轮查证过：`register(definition)` → `CommandDefinition{name, description, handler}` →
     `{ kind:'success', text }`）。
  2. **出码时的中转登记**（`POST /pairing/register`）没接 —— 中转侧的端点已就绪
     （`POST /pairing/register` 201），连接器侧还缺一次 HTTP 调用。
  3. **每连接状态**那个岔口仍未决定（监听面/多设备）：本轮没有碰它。
