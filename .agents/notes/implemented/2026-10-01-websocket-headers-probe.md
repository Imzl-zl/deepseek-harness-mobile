# Agent Note: Node 的全局 `WebSocket` **能**带自定义头（实测），所以连接器仍是零依赖

Status: implemented（连接器拨号带上 `Authorization`；出码登记调用见"仍未做"）

## Problem

第 33 轮把"中转是唯一需要 `ws` 的一侧"这件事记成了事实，理由是：**Node 的全局 `WebSocket`
只有客户端、没有服务端**。而这一轮要给连接器的拨号带上连接器令牌（§2.2 的升级鉴权），
于是冒出一个必须先回答的问题：

> Node 全局 `WebSocket`（WHATWG 形状）**能不能带 `Authorization` 头**？
> WHATWG 的构造签名是 `new WebSocket(url, protocols)` —— 从形状上看**不能**。
> 如果不能，连接器就得为此引入 `ws`（或把令牌塞进查询串，那是我们明确不要的做法）。

这件事不能靠读文档猜：WHATWG 形状与 undici 的实际实现往往差一点，而"差一点"正好就在这里。

## 求证到的事实（实测，不是读文档）

一个探针（临时目录，不入库）：起 `ws` 服务端，打印它看到的 `authorization`，客户端分别尝试三种写法。

| 客户端写法 | 服务端看到的 `authorization` |
|---|---|
| `new WebSocket(url, { headers: { authorization: 'Bearer A' } })` | **`Bearer A`** ✅ |
| `new WebSocket(url, [], { headers: { authorization: 'Bearer B' } })` | `(none)` |
| `new WebSocket(url)` | `(none)` |

即：**undici 的 `WebSocket` 接受第二参数作为 options 对象并转发 `headers`** ——
这是它相对 WHATWG 的**非标准扩展**，三参数形式不被支持（静默忽略），裸调用自然也没有。

## Decision

- **连接器保持零依赖**：拨号写成 `new WebSocket(url, { headers: { authorization: 'Bearer …' } } as never)`。
  第 33 轮的结论**成立**，但它的理由要补一句：不是因为"客户端本来就能带头"，
  而是因为 undici 的扩展恰好允许 —— 实测过，所以这句是真话。
- **令牌在装配时读一次**（`readRelayToken`；它本身不缓存）。`dial` 是同步的，
  所以不能让每次拨号各读一遍凭据；代价是**运行期换令牌需要重连** —— 可接受：
  换令牌本来就意味着换一次连接。
- **`readRelayToken` 失败就抛**，于是插件在"起得来但连不上中转"之前就失败 ——
  那种"起来了但什么都不工作"的状态最难排查。
- 类型上要 `as never`（WHATWG 的类型没有 options 参数）。这是**已知的、有意的**类型逃逸，
  所以就地写清它换来了什么（零运行时依赖），免得后人把它当"类型错误随手压掉"。

准入门槛（可机械判定）：`tsc` 0 错、`pnpm test` 252 项全绿（fixture 走自己的 `dial` 桩，
所以连接器的既有用例不受影响 —— 它们覆盖的是连接层，不是这个生产拨号器）。

## Alternatives considered

1. 给连接器加 `ws` 运行时依赖
   - 最强的理由：`ws` 的构造签名本来就支持 `headers`，不必类型逃逸，也不依赖 undici 的扩展。
   - 为何被否：实测已经能带头发送，而加依赖的代价是真实的（插件多一个运行时依赖）。
     但**这是一条有时限的结论**：如果将来要带的是需要更复杂握手的东西
     （代理、mTLS、自定义子协议协商），`ws` 会重新变成正确选择 —— 那时改，理由会很清楚。
2. 令牌塞进查询串（`?token=…`）
   - 最强的理由：不用碰 `WebSocket` 的构造参数，任何实现都能带。
   - 为何被否：**URL 会进日志**（契约 §2 明写"令牌不进 URL 与日志"）。设备侧能用一次性票，
     正是因为票的泄露窗口被压到了 60 秒；连接器令牌是长连凭据，绝不能那样用。
3. 把令牌读进连接层（`createConnection` 的 options 里放一个异步 provider）
   - 最强的理由：运行期换令牌不必重连。
   - 为何被否：`connect()` 是同步的，把凭据读取塞进去会让"重连"变成异步状态机的一部分，
     而收益只是省一次重连 —— 与"换令牌=换连接"这件事相比不值得。

## Consequences

- 收益：连接器到中转的**鉴权路径**打通（升级头带 Bearer 连接器令牌），中转侧的 `authenticate`
  端口与 401 路径（第 30 轮）现在有了真实的调用方；连接器仍然零运行时依赖。
- 代价：一处有意的类型逃逸（`as never`），依赖 undici 的非标准扩展；若 Node 收紧这一点，
  症状是"服务端看不到 authorization"（探针表就在上面，复现只要一分钟）。
- **仍未做（下一轮）**：
  1. **出码登记调用**：`register = (codeHash) => POST ${relayUrl}/pairing/register`（读令牌、
     失败即不出码；核心已在第 36 轮实现并测过）。
  2. **命令接线**：`ctx.commands.register({ name:'dsh-mobile-pair', description, handler })`。
  3. 每连接状态那个岔口（监听面/多设备）仍未决定。
