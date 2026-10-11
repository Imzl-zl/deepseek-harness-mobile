# AEAD 从 ChaCha20-Poly1305 换成 AES-256-GCM:Electron 的 crypto 没有前者

- Status: implemented
- Date: 2026-10-07

## Context

真机联调走到"配对成功、App 说已连接"之后,出现一个**极难定位**的故障:

- 手机侧:**连得上,但什么都干不了** —— 会话列表永远空,"重新拉取会话"点了没有任何反应;
- 电脑侧(中转日志):`connector home-pc 断开（code=4002，原因=protocol/bad-frame）`,
  **每 30–45 秒一次**,断开后连接器重连、重放名册,循环往复;
- 但**握手是成功的**(中转日志有正常的换票与名册更新,手机显示"已连接");
- `connector` 的 292 个用例、`relay` 的 65 个、`protocol` 的三件套(486 / 26 / 49)**全绿**。

关键是拿到那帧被拒的原始载荷。中转只报"`bad-frame`",而 `bad-frame` 有十来个来源
(超限 / 不是 JSON / 缺 `t` / 字符集不对 / 握手门禁 / 解箱失败…),只说"被拒"等于没说 ——
所以先在 `connection.ts` 的收帧 catch 里补上原始行与真正的原因,一次就拿到了:

```json
{"raw":"{\"v\":1,\"t\":\"req\",\"id\":\"…\",\"box\":\"…\",\"fc\":0}",
 "message":"AEAD 无法初始化（密钥或 nonce 形状不对）：Error: Unknown cipher",
 "handshakeDone":true}
```

`box` 解出来是 53 字节真密文(37 字节明文 + 16 字节 tag,而 37 正是
`{"method":"session.list","params":{}}` 的长度),所以**手机侧编码没问题**;
`Unknown cipher` 是 Node 密码学层报的,而算法名是个常量。

## 根因

**Electron 的 `node:crypto` 不提供 `chacha20-poly1305`,而电脑侧插件跑在 Electron 里。**

同一段代码、两个运行时(`createCipheriv` + `setAAD` + `getAuthTag` 往返):

| 运行时 | `aes-256-gcm` | `chacha20-poly1305` | `getCiphers()` 条数 |
|---|---|---|---|
| stock Node 24.13 | 往返 OK | 往返 OK | 134 |
| **Electron(内 v24.18.1)** | 往返 OK | **`Unknown cipher`** | **28**(全是 AES/BF/DES/RC) |

于是症状的每一环都对上了:

- **握手成功**:握手三帧只用 Ed25519 签名与 X25519,**完全不碰 AEAD**;
- **第一帧业务请求就断**:`session.list` 是第一个要封箱的帧,一封就抛,收帧路径把它
  统一收口成 `protocol/bad-frame` 并关连接(那是正确的处置 —— 解不开的帧不该被接受);
- **测试全绿却救不了真机**:所有单测与向量都跑在 **stock Node** 下,那里两种算法都有。

契约 §4.2 原本写的是"`AEAD = ChaCha20-Poly1305`(默认)",并注明"备选 AES-GCM,
替换一行常量即可" —— **备选方案早就写在那里,但从没被接线**,因为选型时只查了
手机端的加速清单(`cryptography_flutter`),没有查**电脑侧的运行时**。

## Decision

**`AEAD = AES-256-GCM`**,契约的其余部分一字未动:nonce 仍是 `fc` 的 96 位大端(§4.2)、
AAD 拼串仍是 `v|t|id|sid|seq|fc`(§3)、密钥派生(§4.1)、箱容器 `base64url(密文‖tag)`、
标签 16 字节 —— 所以**只有算法名与向量密文变了**。

改动落在四处(必须同时改,漏一处就是"单侧绿、真机断"):

1. `connector/src/protocol/crypto.ts` 的 `AEAD_ALGORITHM`;
2. `protocol/tools/vectors-core.mjs`(参考实现,向量由它生成);
3. `app/lib/core/crypto.dart` 的 `Chacha20.poly1305Aead()` → `AesGcm.with256bits()`;
4. `connector/tests/support/phone.ts`(测试里的手机替身)。

## Alternatives considered

### 替代一:留在 ChaCha20,让插件别跑在 Electron 的 Node 里

**最强的理由**:算法不动,契约与向量一个字都不用改;而且 ChaCha20 在 ARM 手机上有
平台加速,选它当初是有理由的(避免 AES 的查表侧信道、纯 Dart 回退可用)。
理论上可以换用系统 Node 跑插件,或用 `openssl` 之类的第三方实现补上这个算法。

**为何被否**:插件**必须**跑在 `dsh-desktop-host` 子进程里(契约 §2.1,已核实),
那是 DSH 的架构,不是我们能选的;换运行时等于改 DSH 的宿主形态。
自己引第三方 ChaCha20 实现则要在**每条连接的加解密热路径**上绕开 `node:crypto`,
多一份要自己维护、自己审计的密码学代码 —— 为了保住一个算法而引入这个,不划算。
而 AES-256-GCM 在两个运行时**都有**,且 Dart 侧同样可用,是唯一"两端都确定能跑"的选择。

### 替代二:两端协商算法(握手时各报自己支持的)

**最强的理由**:最稳 —— 客户端与服务端能力不同时自动挑一个双方都有的,
将来换端(鸿蒙/iOS)不必再改契约。

**为何被否**:**这一层没有可协商的余地**。AES-GCM 与 ChaCha20 的 nonce 与 AAD 规则虽然
同构,但协商本身要把算法选择放进 transcript,**而 transcript 变了就是新协议版本** ——
代价远大于收益:为一个"两端各自都能跑"的算法再加上一整套版本协商与降级分支,
而它解决的只是一个已经查清、且已有一行常量可换的问题。
真需要多算法时,该做的是**协议版本升级**,而不是在这一层塞协商。

## Consequences

- **收益**:真机上 `bad-frame` **归零**(修前每 30–45 秒一次,修后观察窗口内 0 次),
  电脑侧不再自杀式重连;两端第一次真正跑在同一条可用的密码学通道上。
- **收益**:查出并补上了一个**测试盲区** —— "所有测试都跑在 stock Node"这件事本身,
  让一个只在 Electron 下成立的缺陷长期不可见。这条教训已写进契约 §10 的切换验收条款:
  **切换算法前必须确认目标运行时真的提供该算法**。
- **代价**:`protocol/vectors/aead.json` 的密文与 tag 全部重新生成(向量是**参考实现**的
  产物,算法变了它必须跟着变);旧密文不再能解开 —— 但这是**同一版本内的协议改动**,
  不存在需要兼容的历史连接(本通道尚未发布过)。
- **代价**:AES-GCM 在**没有 AES-NI 的旧 ARM 设备**上比 ChaCha20 慢,而手机端
  `cryptography` 包会走平台实现(Android/iOS 有 AES 加速),所以这一点在目标三端上不构成问题;
  **未实测**:鸿蒙侧的实际吞吐(契约 §10 留了基准方法)。

## 未决(如实记录,不在本篇假装已解决)

**中转丢弃电脑侧回的 `credit`。**

同一轮真机日志里还有一条:

```text
[relay:debug] 中转丢弃一帧：credit 找不到对应设备 { requestId: '' }
```

`credit` 是**双向**的流控 ack(契约 §4.3:"接收方每收到一帧立即回 `credit`"),
而它**既没有 `sid` 也没有 `id`**(被确认的序号在箱里的 `ack`,帧头只带自己的 `fc`)。
`relay/src/core.ts` 的连接器分支对"没有 `sid`"的帧**只按 `id` 回查**(那是给
`pair-ack` / `hello-ack` / `confirm` 用的),于是它查不到、被丢弃。

后果是**单向流控**:电脑侧的 `unacked` 只增不减,累积到 128 帧后暂停发送(§4.3),
表现是"手机再也收不到任何事件"。

**为什么不当场修**:修它要先回答一个**设计问题** —— 一条连接器 socket 同时服务多台设备时,
这个没有身份标记的 ack 属于谁?现有的证据不足以定案:回环测试(`verify-loopback.mjs`)
的模型是"一台手机 + 一个连接器",而 `connector/src/index.ts` 向中转只拨**一条**连接。
在没有定论前按猜测补一个路由分支,正是这套代码里已经出现过两次的那类错误
(先猜拓扑、再让真机来纠正)。**修它要先定拓扑,再动代码。**

**已定案(同批)**:拓扑就是"**每台在线设备一条数据连接**"
(`connector-and-relay.md` §1.6)。按那个形态,`credit` 与连接器自己的 `ping`
都不再需要"从帧里推断属于谁" —— **由连接本身回答**,两处缺口一起消失;
`noSidByRequestId` 这张表也可以整个删掉。实现提示词:
`docs/prompts/per-device-data-connection-prompt.md`。

## 代码入口回指

- `connector/src/protocol/crypto.ts` 的 `AEAD_ALGORITHM`(为什么不能是 ChaCha20)
- `app/lib/core/crypto.dart` 的 `_aead`(手机侧同一决定)
- `protocol/tools/vectors-core.mjs` 的 `AEAD`(参考实现;它跑在 stock Node 下,
  所以**它绿不代表真机能跑** —— 这正是当初漏掉这个缺陷的原因)
- `connector/src/transport/connection.ts` 的收帧 catch(把原始行与真实原因打进日志;
  少了它,`bad-frame` 只是个没有信息的字符串)
