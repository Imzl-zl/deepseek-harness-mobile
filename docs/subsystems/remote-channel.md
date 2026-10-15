# 远程通道契约(手机 ↔ 电脑)

手机 App 连电脑上的 DSH 这条通道的**完整契约**:拓扑、帧层、连接层、会话层、交互层、存储、推送、参数、故障矩阵与验收。取舍理由见 `.agents/notes/proposed/2026-09-30-remote-channel-reverse-ws-e2ee.md` 与 `.agents/notes/implemented/2026-09-30-channel-review-corrections.md`;DSH 侧现状事实与行号见 `../channel-review-notes.md`;三侧落地设计见 `connector-and-relay.md` 与 `app-channel-client.md`。

**本文件是通道的唯一规格源。** `protocol/fixtures/` 是它的可执行部分;两侧实现(TS 插件 / Dart 手机端)各自对着同一批 fixtures 跑,不允许任何一侧自留一份协议说明。冲突时以 fixtures 为准并回来改本文件。

---

## 1. 角色、不变量与术语

| 角色 | 职责 | 明确不做 |
|---|---|---|
| 手机 App(Flutter) | 呈现与操作;本地缓存投影与落盘水位;前台维持连接 | 不推断电脑状态;不把缓存当权威;不分配修订号 |
| 中转 Server | 配对与鉴权、按连接转发、有界重放窗口、推送投递、在线态投影 | **不存内容、不做语义推断、不分配任何序号** |
| 电脑侧桥接(DSH 插件) | 读写 DSH 真值;分配会话别名与流 id;合并批量;生成推送摘要 | 不把 DSH 语义搬进中转;不重建 DSH 已有的投影 |

### 不变量(改动本子系统时必须保持)

- **I1 唯一真值源**:电脑侧是唯一真值源;中转与手机都只是投影,不得作为判据。
- **I2 两层序号分离**:连接层用 `fc`(每方向单调计数器)负责 nonce、重放防护与流控;会话层用 `seq`(DSH 事件序号)负责恢复与去重。**两者互不替代**:`fc` 不落盘、不进窗口;`seq` 不参与密码学。
- **I3 恢复只有两种结果**:`delta`(完整增量)或 `snapshot`(带原因与水位)。不存在"大概补上了"。
- **I4 瞬时事实只有两项**:电脑在线态、能力位。带 `seq` 或带 ask/outcome 的事实一律按持久条目处理(进快照、upsert、可从日志重建)。
- **I5 推与拉同一 owner**:同一事实不允许一边推、一边由另一侧拉取计算。
- **I6 推送不参与正确性**:推送丢失、重复、乱序时,App 回到前台后状态仍必须与电脑一致。
- **I7 中转可被清空**:删掉中转全部业务状态后重启,已配对设备仅凭电脑侧数据收敛,不丢事件、不产生重复条目。
- **I8 幂等**:所有写操作带幂等键;断线重发不产生第二条消息或第二次审批。
- **I9 条目身份与序号解耦**:稳定 `itemId` 由事件自身推导,**不得**用 `seq` 当主键。
- **I10 中转只读路由元数据**:会话别名、`seq`、`fc`、帧类型与帧头 `id` 可见;方法名、事件类型、载荷一律不可见。数据连接按设备与连接代次成对绑定,`id` 只关联端点请求与应答,中转不再用它猜回程。

### 术语

- **会话别名 `sid`**:电脑侧为每个 DSH 会话分配的**不透明路由标识**(16 字节随机,base64url)。它与 DSH 的 session id 解耦,中继据此索引重放窗口,无法关联外部信息。
- **流 `stream`**:一次 assistant 尝试对应的实时输出流 id(电脑侧分配,会话内单调)。
- **`job` 帧**:任务输出的**订阅流**(契约 §5.3)。它与 `live` 一样是易变流(不占 `seq`、不进重放窗口、不参与 ack、恢复时不回带),但**刻意是另一种帧类型**而不是复用 `live`:
  - `live` 的两个数字字段(`stream` / `rev`)已被 assistant 流占满,而手机侧对它们的读法是硬性的 —— `rev == last + 1` 追加、`rev` 跳跃即**丢流**(见 `app-channel-client.md` §2.2)。任务输出的"修订号"是**输出字节偏移**(会跳号),塞进去会让手机把 assistant 的流丢弃;
  - 给同一个字段第二个含义,正是 `credit` 那一处已经否掉的做法(§4.3)。
  - 载荷形状(`box` 里,明文经 AEAD)**三帧,照宿主 `jobController.follow` 的 `opened` / `output` / `status` 一对一**:
    ```ts
    type JobOutput =
      | { kind: 'opened'; jobId: string; job: JobRow; from: number }   // from = 第一帧 output 的起点
      | { kind: 'output'; jobId: string; chunks: JobChunkOut[]; next: number; lossy?: true }
      | { kind: 'status'; jobId: string; job: JobRow }                 // 结算且 drain 完之后一帧,然后流结束
    ```
    `JobRow` 与 `job.list` 的行**同形状**(不含 `owner` —— DSH 会话 id 不过线);`JobChunkOut` 是 `{ at, text, channel?, gapBefore? }`(`channel` ∈ `stdout` / `stderr` / `log`)。
- **看护超时**:桥接代为应答期间等待手机回答的上限。

---

## 2. 拓扑与连接生命周期

```text
[手机 App] ⇄(WSS: 设备身份)⇄ [中转 Server] ⇄(WSS: 连接器令牌)⇄ [电脑侧桥接] ⇄ [DSH]
```

两跳都是手机侧 / 电脑侧**主动连出**:不需要公网 IP、不需要内网穿透、不需要端口映射。中转不主动拨入。

**直连拓扑**(契约 §14.6 的第一跳):手机与电脑在同一 Tailscale 网络时,手机直接连电脑侧桥接,
不经中转。桥接此时**接受**连接而不是拨号(同一套握手与封箱),监听面见
`connector-and-relay.md` §1.7。两条路径跑同一组用例,所以协议层不为拓扑分叉 —— 差别只在
"谁发起 TCP" 与 "中转在不在中间"。

### 2.1 电脑侧形态(硬性前提,已核实)

- **必须是 npm bundle**(包清单声明 `dsh.bundle.patch`),**不能**是动态 Cordis 包:后者跑在 `node:vm` 沙箱里,`setInterval` / `fetch` / `require` 被 trap 成抛错(`packages/extensions/cordis-host-runner/src/sandbox.ts:2-7,68-80`),开不出长连接。
- 运行在 `dsh-desktop-host` 子进程里;生命周期与该子进程一致(关窗只是隐藏到托盘,真退出则连接必断)。**重连是常态,不是异常路径。**
- `ws` 可用;心跳与重连定时器用 `ctx.timer` 的 `interval` / `timeout`,随插件 dispose 自动清理。
- **状态落插件自己的持久化存储**(见 §8.1):增量缓冲、去重表、设备公钥、会话别名映射。**修订号不落插件存储**(它取自 DSH 的 `seq`)。
- 不与既有 HTTP 座位冲突:DSH 的 loopback webserver 对重复路由、重复 upgrade、fallback 属主都会抛错(`packages/host/webserver/src/index.ts:169,183,198-199`)。纯出站连接不碰这些。
- 兼容性由 **`peerDependencies` 对 `@deepseek-ai/dsh*` 的范围**判定(`packages/boot/app-boot/src/plugin-compatibility.ts:68`),不匹配的 bundle 被跳过并记入 `skippedBundles`(`packages/boot/app-boot/src/profile.ts:675-681`)。**`engines.dsh` 不参与判定**(`packages/util/package-manifest/README.md:93`),`engines` 只写 node。

### 2.2 连接状态机

```text
        ┌──────────┐  建连(WSS)   ┌────────────┐  鉴权通过  ┌───────────┐
        │  idle    │──────────────▶│ connecting │───────────▶│ handshake │
        └──────────┘               └────────────┘            └─────┬─────┘
              ▲                          │ 失败/超时                │ 握手完成
              │ 主动断开                  ▼                        ▼
        ┌─────┴──────┐               ┌─────────┐            ┌───────────┐
        │ backoff    │◀──────────────│ closed  │◀───────────│  serving  │
        └────────────┘   连接结束     └─────────┘   断开/错误 └───────────┘
```

- `connecting`:手机先 `POST /ws-ticket` 换一次性 ticket(令牌不进 URL 与日志),再带 ticket 升级。电脑侧直接带连接器令牌。
- `handshake`:见 §4.1;未完成握手的连接**只接受握手帧**(`hello` / `hello-ack` / `confirm`),其余帧一律 `protocol/bad-frame` 并关闭。
- **回帧回显请求的 `id`**:`hello-ack` 回显 `hello` 的 `id`,`pair-ack` 回显 `pair` 的 `id`,`pong` 回显 `ping` 的 `id`。没有 `sid` 的帧在链路上只能靠 `id` 定向 —— 两端各自生成 `id` 的话,中继在「一台电脑同时服务多台设备」时无法把回帧送回发起方(只能丢弃)。`id` **不参与 transcript**(§4.1),所以它只是关联标记。
  - **`ping` / `pong` 必须带 `id`,这条是被真机逼出来的**:它们原先不带,于是手机的探针能到电脑侧、而**电脑侧回的 `pong` 被中继丢弃**(中继的连接器分支对没有 `sid` 的帧只按 `id` 回查,空 `id` 查不到任何东西)。后果不是"保活失效"这么轻:手机每个心跳周期都收不到任何帧,于是**每 60 s 自己判一次半开、关掉一条完全健康的连接**,如此循环 —— 症状是"连上了但列表永远空、点什么都没反应",而两端的日志各自看起来都正常(中继只留一行 `丢弃一帧`,手机只是"重连")。中继丢弃的帧名会直接写出来(`ping 找不到对应设备`),那是唯一的路标。
  - **对称缺口(未决)**:`credit` 同样没有身份标记,电脑侧回的那一半会被丢弃。它与 `ping` 不同 —— `credit` **没有可回显的 `id`**(它没有请求方,是纯推送的累计确认),所以要修它得先定「一条连接器 socket 服务多台设备时这个 ack 属于谁」。见 `.agents/notes/implemented/2026-10-07-electron-lacks-chacha20.md` 的"未决"一节。
- `serving`:进入服务态后,手机无条件发 `hello`(§5.4)补齐状态。
- `backoff`:指数退避,`1s → 2s → 4s → … → 30s` 封顶,抖动 ±20%。**只在 App 前台重连**;切后台主动断开并停表。
- 半开连接:`serving` 期间**任一方向**连续 2 个心跳周期无任何帧 → 视为断开,重连。收帧与发帧都重置空闲计时;**唯一的例外是 `ping` 自己**——它是探针,若它重置计时,空闲期就永远攒不满两个周期,半开再也判不出来(一个空闲期只探一次,`pingedInThisIdle` 保证)。

---

## 3. 帧层

行级 UTF-8 JSON,单帧上限 **8 MiB**(与 DSH 桥接一致,便于两侧同构解析)。**每帧以 `\n` 结尾**:分帧器只在读到换行时交出一帧,漏掉它的表现是「两侧都正常、对端什么都没收到」。

```ts
/** 明文头只保留路由、补课与密码学需要的最小字段;方法名、事件类型与内容全在密封载荷里。 */
type Frame =
  // 连接层:握手(明文,密钥尚未建立)
  | { v: 1; t: 'hello';       id: string; box: string }
  | { v: 1; t: 'hello-ack';   id: string; box: string }
  | { v: 1; t: 'confirm';     id: string; box: string }
  // 连接层:保活与流控信用(空载荷也要封箱,理由见下)
  | { v: 1; t: 'ping';        id: string; fc: number; box: string }
  | { v: 1; t: 'pong';        id: string; fc: number; box: string }
  | { v: 1; t: 'credit';      fc: number; box: string }   // box = { ack } —— 见 §4.3
  // 会话层:请求 / 应答 / 事件 / 落盘水位
  | { v: 1; t: 'req';  id: string; sid?: string; fc: number; box: string }
  | { v: 1; t: 'res';  id: string; sid?: string; fc: number; ok: true;  box: string }
  | { v: 1; t: 'res';  id: string; sid?: string; fc: number; ok: false; box: string }
  | { v: 1; t: 'ev';   sid: string; seq: number; fc: number; box: string }
  | { v: 1; t: 'live'; sid: string; stream: number; rev: number; fc: number; box: string }
  | { v: 1; t: 'job';  sid: string; fc: number; box: string }
  | { v: 1; t: 'pair-commit'; id: string; fc: number; box: string }
  | { v: 1; t: 'pair-result'; id: string; fc: number; box: string }
  | { v: 1; t: 'persisted'; sid: string; seq: number; fc: number; box: string }
  // 投影:在线态(明文,中继可转发)
  | { v: 1; t: 'presence'; computer: 'online' | 'offline'; app?: 'foreground' | 'background' }
```

规则:

- **`fc` 是发送方向该连接的帧计数器**,从 0 开始,每发一帧 +1(含 `ping` / `credit`)。它是 nonce 与重放防护的唯一来源(§4.2)。握手三帧(`hello` / `hello-ack` / `confirm`)不带 `fc` —— 它们是明文且发生在密钥建立之前,盖一个计数器值只会让线上帧与本文的形状不一致。**配对两帧带 `fc`**:它们发生在受限握手**之后**(§12.1 的配对 v2),与业务帧同一条封箱路径。
- **`box` = AEAD 密文**,内含方法名 / 事件类型 / 载荷。**`res ok:false` 的错误也封箱**,明文只留帧类型。
- **唯一的明文例外是握手三帧与 `presence`**:前者发生在密钥建立之前(那时没有可用密钥),后者由中继合成(§9)因而中继必须能原样转发。**配对两帧不是明文例外**:它们出现在受限握手之后,而 `pair-commit` 的载荷正是配对码 —— 那是这一阶段唯一的授权秘密,只能以密文上线(v1 的明文 `pair` / `pair-ack` 已删除,旧形状会被拒)。**其余每一种帧都带 `box`,包括 `ping` / `pong` / `credit` / `persisted` 这些"没有内容"的控制帧** —— 它们的载荷是空串,封箱买到的不是保密而是**认证**:
  - `fc` 出现在 AAD 里,不认证就等于让**未认证的数字直接驱动重放窗口**:注入一帧 `credit{fc: 10^9}` 会把守卫推高,此后所有合法帧都被判成重放(§4.2)。
  - `credit` 与 `persisted` 都会改变对端状态(放宽发送窗口 / 允许裁剪增量缓冲),未经认证的状态变更就是可被中继伪造的状态变更。
  - 代价是每个控制帧多 16 字节认证标签 + 一次加解密,对 60 s 一次的心跳与逐帧 `credit` 都可忽略。
- **`box` 的容器格式**:`base64url(密文 ‖ 16 字节 tag)`,无填充(密文长度由总长减 16 得出,不需要额外分隔符)。选 base64url 而不是十六进制:十六进制会把载荷体积翻倍,而 8 MiB 单帧上限是按编码后的行算的 —— 翻倍等于把可用载荷预算砍半。
- **AAD 规范化**(两端必须字节一致):
  ```text
  aad = v "|" t "|" id "|" sid "|" seq "|" fc
  ```
  缺字段的位置用**空串**占位。为消除两端 JSON 转义差异,`id` 与 `sid` 限定为 ASCII 安全字符集 `[A-Za-z0-9_-]`(`id` = 16 字节 base64url;`sid` = 16 字节 base64url);数字一律十进制无前导零、无小数点。
- **中继的路由视图只有四个字段**:`t`、`sid`、`seq`、`fc`。它不解 `box`,也不推断语义。
- 未知帧类型与未知字段:**忽略并不报错**(向前兼容);未知帧类型若带 `id` 则回 `res ok:false` / `protocol/unsupported-version`。
- 单帧超 8 MiB:发送侧**不得发出**(见 §5.3 的 refetch 规则);收到即 `protocol/bad-frame` 并关闭连接。

### 3.1 错误码(封闭表)

| 码 | 含义 | 客户端行为 |
|---|---|---|
| `protocol/unsupported-version` | 对端帧版本不支持 | 提示升级,停止重试 |
| `protocol/not-paired` | 未配对或配对已撤销 | 回到配对页 |
| `protocol/revoked` | 设备已被吊销(电脑侧删除公钥) | 清除本地凭据,回到配对页。**当前无生产者**:连接器把"未配对 / 已停用 / 查不到"合并成 `protocol/not-paired`(`connector/src/protocol/handshake-driver.ts`),实际路径见 §11 故障矩阵 |
| `protocol/bad-frame` | 帧不合法(含握手前发业务帧) | 关闭并重连一次 |
| `protocol/replay` | 重放或乱序(连接层) | 关闭并重连(重连即换新密钥与计数器) |
| `rate-limited` | 触发限流 | 退避重试 |
| `session/not-found` | 会话不存在 | 从列表移除 |
| `session/window-missed` | 区间超出窗口且缓冲覆盖不到 | 走快照 |
| `session/revision-newer` | 手机水位超前于权威 | 走快照 |
| `interaction/not-pending` | 应答的交互已结束或不属于本设备 | 刷新待处理列表 |
| `job/not-found` | 任务不存在(含跨重启重用后的失效) | 刷新任务列表 |
| `settings/read-only` | 该设置项不可写 | 置灰并注明 |
| `relay/offline` | 电脑离线(仅中转能报) | 显示在线态,不重试业务请求 |
| `connector/unsupported` | 能力不存在(方法未实现) | 按钮置灰 |
| `internal` | 未归类错误 | 上报日志,可重试 |

**宿主层错误码**——DSH 在这些方法上真实返回的码(2026-10-09 逐条读 `packages/` 源码核实,
出处见 `connector/src/protocol/errors.ts` 的逐行注释)。它们描述"**这一次操作**为什么没成",
所以漏一个的后果不是"走 default",而是被归一化降级成 `internal` → 用户对着一个
永远重试也不好的操作反复点。本仓已经栽过一次(`not-paired` 被报成 `bad-frame`)。

| 码 | 含义 | 客户端行为 |
|---|---|---|
| `session/agent-busy` | 电脑正忙着,prompt 被拒 | 退避后重发(文案要说"电脑正忙") |
| `session/model-unavailable` | 还没选可用模型 | 发送前置灰并注明 |
| `session/attachment-invalid` | 附件不被当前模型接受 | 去掉那个附件 |
| `session/steer-unavailable` | 当前轮次已不能 steer | 刷新待处理(排队项作废) |
| `session/queue-item-not-found` | 排队项已不在队列 | 刷新待处理 |
| `session/writer-held` | 会话被别的写者占着 | 退避后重试 |
| `session/conflict` | 预设等冲突 | 置灰并注明 |
| `workspace/not-found` | 新建会话时 workspace 不存在 | 置灰并注明 |
| `agent-preset/conflict` | agent 预设冲突 | 置灰并注明 |
| `gateway/bad-request` | **我们发的参数宿主不认 = 我们的缺陷** | 响亮失败并记录,**不让用户重试** |
| `gateway/cancelled` | 调用被中止 | 重连一次 |
| `gateway/internal` | 宿主内部错 | 退避后重试 |
| `settings/rejected` | 设置被拒 | 置灰并注明 |
| `settings/conflict` | `expectedRevision` 过期 | 重新 describe 再改 |
| `credential/rejected` | 凭据被拒 | 置灰并注明 |

两边表(TS `ERROR_TABLE` 与 Dart `ErrorCode`)**逐字一致**,由
`connector/tests/error-table-parity.test.ts` 断言;契约与代码一致由
`connector/tests/error-code-table.test.ts` 断言。

---

## 4. 连接层:握手、密钥、计数器、流控

### 4.1 握手(每连接一次,三条消息)

设备身份 = **一个 32 字节主种子**,经 HKDF 派生两把长期密钥:

```text
seed(32B, 存系统安全存储)
  ├─ HKDF(seed, info="id-sign")  → Ed25519 身份签名密钥对
  └─ HKDF(seed, info="id-dh")    → X25519 静态 DH 密钥对
```

只存一个 secret,便于三端安全存储统一管理(鸿蒙 HUKS / iOS Keychain / Android Keystore)。

```text
手机 → 电脑   hello     { box: { ephPubA(32B), devId, nonceA(32B) } }
电脑 → 手机   hello-ack { box: { ephPubB(32B), pcId,  nonceB(32B), sigB } }
手机 → 电脑   confirm   { box: { sigA, transcriptHash[0..8) } }
```

- `transcript` = 两帧里**参与签名的字段**的规范拼接(**不含签名本身**):`dsh-mobile/v1|hello|ephPubA|devId|nonceA|hello-ack|ephPubB|pcId|nonceB`(字节序固定)。`sigB = Ed25519_sign(idSignB, transcript)`,`sigA` 同理。
  - **为什么不是"两帧 `box` 明文的拼接"**:`sigB` 就在 hello-ack 的 `box` 里(`{ ephPubB, pcId, nonceB, sigB }`),签一段包含 `sigB` 自身的字节是**循环定义** —— 不存在能自洽的取值(实测:用占位签名算 transcript 再回填,对端拿真实帧必然验不过)。所以被签的是**除签名外的字段**,签名字段不参与拼接。握手的 `box` 本来就只是编码容器、不是保密手段,把签名留在箱内不损失保密性。
- 共享密钥:
  ```text
  ss1 = X25519(ephPrivA, idDhPubB)     // 手机临时 × 电脑静态
  ss2 = X25519(idDhPrivA, ephPubB)     // 手机静态 × 电脑临时
  ss3 = X25519(ephPrivA, ephPubB)      // 双方临时
  master = HKDF-SHA256(ikm = ss1||ss2||ss3, salt = nonceA||nonceB, info = "dsh-mobile/v1/keys", len = 64)
  kA2B  = master[0..32)   // 手机→电脑方向的 AEAD 密钥
  kB2A  = master[32..64)  // 电脑→手机方向
  ```
- **前向保密**:`ss3` 强制包含双方的临时密钥 ⇒ 长期种子泄露也**不能**解密已结束连接的历史记录。每连接一把新密钥 ⇒ 无需"密钥轮换"功能。
- **相互认证**:双方都要验签对方的临时公钥;验签失败即 `protocol/not-paired` 并断开。中继替换公钥无法通过验签。
- **握手完成的判据**(两侧各自判定,不存在第四条消息):
  - 发起方(手机):收到 `hello-ack` 且**验签 `sigB` 通过** → 派生会话密钥 → 发 `confirm` → 进 `serving`;
  - 应答方(电脑):收到 `confirm` 且**验签 `sigA` 通过、`transcriptHash[0..8)` 比对一致** → 派生会话密钥 → 进 `serving`。
  - 验签失败或摘要不匹配一律 `protocol/not-paired` 并断开。
- 握手三帧的 `box` 是**明文编码容器**(§3 已注明例外):此刻会话密钥还没建立。所以「收到对方第一条能解开的 AEAD 帧」是密钥可用的**观测**,不是握手完成的判据 —— 判据只有上面那两条。
- **每次握手都必须新生成临时密钥对**,不得跨连接复用:复用会让 `fc` 从 0 重数 ⇒ nonce 重用 ⇒ 直接破掉 AEAD。握手失败后的重试同样要重新生成。
- 握手超时 10 s;失败不计入业务重试次数。

### 4.2 计数器、nonce 与重放

- **nonce = 12 字节 = `fc` 的 96 位大端表示**,`fc` 从 0 开始、每帧 +1、**不重用**。
- 不使用随机 nonce:唯一性由计数器保证,不需要 `Random.secure()`(每帧一次系统调用),也不受随机数质量影响。
- **重放防护(连接层)**:接收方维护 `maxFc`;`fc < maxFc` 即 `protocol/replay` 并断开(`fc == maxFc` 只可能来自重复投递,同样拒绝)。因为握手每连接换密钥,重放旧连接的帧必然解不开。
  - **顺序是硬规则:先验签,后推进**。只有在 AEAD 校验通过之后才允许把 `maxFc` 推到该帧的 `fc` —— 否则任何未认证的 `fc` 都能替对端"提前"推进窗口,把后续合法帧全判成重放(表现为连接被自己人反复关闭)。先解开再进门,顺序反过来就没有第二条防线。
- **乱序**:本层不允许乱序(单 TCP 流本来就保序);任何乱序都视为攻击或故障。
- **算法**:`AEAD = AES-256-GCM`。**这条是被真机逼着改的**,理由不再是"哪个更快":
  - 电脑侧插件跑在 **Electron** 里,而 **Electron 的 crypto 不提供 `chacha20-poly1305`**(整族都没有;
    实测 Electron 内 `getCiphers()` 只有 28 个,AES/BF/DES/RC,`createCipheriv('chacha20-poly1305')` 抛
    `Unknown cipher`;同一个 Node 版本用 stock Node 跑则有 134 个、能过)。
  - 症状极具误导性:**握手成功、第一帧业务请求就断**。因为握手只用 Ed25519 签名(不碰 AEAD),
    而业务帧一封箱就炸;电脑侧表现为"连接器每 30 秒因 `protocol/bad-frame` 断开"(伴随退避重连),
    手机侧表现为"连上了但列表/发送全无反应"。**所有单测与向量都跑在 stock Node 下,因此全绿却救不了真机。**
  - `AES-256-GCM` 在两个运行时都有,且 `cryptography` 包(Dart 侧)与 `node:crypto` 都支持。
  - **契约的其他部分一字未动**:nonce 仍是 `fc` 的 96 位大端(§4.2),AAD 拼串(§3)、密钥派生(§4.1)、
    箱容器 `base64url(密文‖tag)`、标签 16 字节 —— 全部不变,所以**只有算法名与向量密文变了**。
  - **验收**:改这个常量后 `verify-vectors.mjs` 必须重新生成向量并全绿;真机上必须能发出第一帧业务请求。

### 4.3 流控

- 发送方维护 `unacked`(已发未收 `credit` 的帧数),上限 **W = 128 帧**;达到上限即**暂停**发送(不是丢弃)。
  暂停的**只有可补的三类**(`ev` / `live` / `job`)—— 它们都能靠重连补齐(`ev` 有重放窗口与快照、`live` 被持久事件替换、`job` 可按 `from` 重订);
  其余帧是对端在等的应答(`res`)或正确性依赖的水位(`persisted`)与信用(`credit`),
  压住它们会死锁:手机在等 `res`,而 `res` 因为窗口满发不出去。`ping` / `pong` 不占额度。
- 接收方**每收到一帧立即回 `credit`**(不要求落盘)—— 这是**连接层信用**,与会话层的落盘水位是两件事。
  - **`credit` 的 `fc` 是它自己的帧序号,被确认的序号在箱里**:`box = {"ack": N}` 表示"我已收到 `[0, N]`"(累计确认;单 TCP 流保序,所以不需要区间集合)。
    两件事必须分开:帧头的 `fc` 是**发送方向**的计数器(nonce 与重放防护的唯一来源,§4.2),而 `ack` 说的是**对端**的计数器 —— 若用同一个字段表示,`credit` 就成了唯一一个 `fc` 语义例外的帧,重放守卫与 nonce 派生都得为它开洞。
    同 QUIC 的形状:ACK 帧承载确认信息,而它所在的包有**自己的**包号。
  - 把 `ack` 放进箱里同时解决了**伪造**:不经认证的 ack 能让对端误以为窗口已放开,额度形同虚设。
  - **`credit` 自己不再回 `credit`**:如果它也要被确认,两端就会互相刷 ack 停不下来(同 QUIC 里 ACK 帧不是 ack-eliciting 的处理)。
- 会话层落盘水位用 `persisted { sid, seq }`:手机**落盘后**才发;电脑侧据此裁剪增量缓冲(§5.5),并允许中转裁剪重放窗口。
- 两层分离的理由:流控要求即时反馈,落盘要求持久确认;混用一个 ack 会让两者互相拖累(等 fsync 才能继续收帧)。

---

## 5. 会话层:修订号、恢复、条目、幂等

### 5.1 修订号与会话别名

- **`seq` 直接取 DSH 会话事件自带的序号**:会话内单调、从 0 连续、永不重编号(`packages/core/session/src/types.ts:493-500`)。
- **`sid` 是电脑侧分配的不透明别名**(§1 术语),桥接持久维护 `sid ↔ dshSessionId` 映射。中继只看到 `sid`。
  - **别名不得由会话 id 派生**(不透明才谈得上"中继只见别名");分配时要对**同一个会话的并发分配合流**,否则两次并发会各分一个别名,其中一个成为孤儿。
- **`seq` 不是内容 ID**:崩溃尾回合的 closer 由冷读在内存合成(`packages/session-query/session-query/src/cold-read.ts:16-17`),其 `seq` 基准为 `last.seq + closers.length + 1`(`packages/core/session/src/repair.ts:89`);会话恢复后同一算法的 closer 落盘(`packages/core/agent-loop/src/index.ts:855-856`)。→ 同一个 `seq` 会经两条读路径各出现一次、**内容相同**:按 `seq` 去重是必须项,但不得用"同 seq 不同内容"判冲突。

### 5.2 条目与身份

- 条目一律 **upsert-only + 稳定 itemId**;删除用墓碑 upsert 表达(墓碑不构成恢复屏障)。
- `itemId` 由事件自身推导,规则固定:
  | 事件 | itemId |
  |---|---|
  | 带消息的事件(`user/message` / `system/message` / `developer/message` / `assistant/message`) | `m:<messageId>` |
  | `tool/call` / `tool/result` | `t:<callId>` |
  | 审批审计对(`approval/asked` / `approval/decided`) | `i:<data.id>`(两个事件共用同一个 `id`,outcome 覆盖 ask → 天然表达"已决定";`packages/interaction/user-approval/src/index.ts:225,232`) |
  | 提问 | **没有专属审计事件**,条目身份落在上面两行:提问本身是 `tool/call`(`t:<callId>`),回答是带 `source.kind='user-question-reply'` 的 `user/message`(`m:<messageId>`)。DSH 自己的提问状态就是这么折出来的:`packages/interaction/user-questions/src/projection.ts:247,260,295` |
  | 任务 | `j:<owner>:<jobId>:<startedAt>`(`JobId` 由进程内计数器生成、跨重启重用,`packages/jobs/jobs-local/src/index.ts:229-231`) |
  | 子代理 | `s:<childSessionId>` |
  | 其它 | `<type>:<seq>`(兜底,**仅**用于没有更稳定身份的事件) |

  带消息的事件**不保证 `<turn>:<step>:<kind>` 唯一**:`user/message` 是非约束事件——它可出现在 turn 之外,且同一个 turn 里可以有任意多条(直接提问、`agent.inject()` 注入的上下文、goal 续跑轮次,`packages/core/session/src/types.ts:302-308`);不变量校验对它只有裸 `break`,而 `system/message` 与 `tool/call` 都必须 `requireOpenStep`(`packages/core/session/src/invariant.ts:127,150,153`)。所以身份取消息自己的 `MessageId`——它是「跨每个表示边界保持的稳定身份」(`packages/llm/llm/src/message.ts:139-148`,铸点 `:226` 为一次性 `randomUUID`),而崩溃尾回合的合成 closer 用的是**确定性** id `${cause.kind}-tool-result-${callId}-${seq}`(`packages/core/session/src/repair.ts:169`),所以 §5.1 里"同一 `seq` 经两条读路径各出现一次"不会让 itemId 漂移。取舍见 `.agents/notes/implemented/2026-10-01-itemid-derivation.md`。

### 5.3 大对象

- 单个条目的封箱后字节 > **1 MiB**:不推内容,推 `refetch { itemId }`,由手机按需拉取(同一方法复用)。
- 图片以 base64 内联进入 `assistant/message`(`packages/api/session-controller/src/types.ts:89-97`),因此大图的条目天然走 refetch 路径。
- 任务输出**按需订阅**:展开即 `job.follow`,收起即 `job.unfollow`;截断沿用 DSH 规格(每帧 64 KiB / ring 256 KiB / 客户端尾 128 KiB / 结算后 ring 裁到 16 KiB,见 `../channel-review-notes.md` §2.7)。
  - 电脑侧**不自己写观察循环**:`jobController.follow` 已经做好了合并与限帧(100 ms 合并、64 KiB 单帧上限,`packages/api/job-controller/src/index.ts:29,32,90-96` 的 `observeJobOutput`),插件只把它输出的三帧映射成 `job` 帧(见"术语"里的载荷形状)并转发。
  - **每个 `(sid, jobId)` 至多一个订阅**:`job.follow` 对同一个任务重复调用是幂等的(返回当前起点),带**不同** `from` 时先终止旧订阅再起新的 —— 否则两路宿主流会同时把同一段输出推给手机,而手机只能看到重复。
  - **订阅跟着连接活**:手机断线即全部终止(它重连后自己按 `from` 重订),`job.unfollow` 与连接断开走同一套清理。
  - 手机侧必须**显式渲染** `gapBefore`(较早输出已丢弃)与宿主流错误两种提示,不做静默拼接(`../plugin-and-jobs-notes.md` §B.4)。

### 5.4 恢复协议

> **为什么不是"把 `sync.hello` 并进 `session.subscribe`"**(2026-10-09 评估过):
> `subscribe(sid, since)` 是**单会话**的增量入口,而 `sync.hello` 做的是两件它做不到的事 ——
> ① **一次声明整份订阅集**(手机回到前台时要恢复的是"所有会话",不是一个);
> ② **上报前后台态**(连接层据此决定要不要发心跳,§9)。所以它不是重复的入口,
> 而是"批量订阅 + 应用态声明"。真要合并,得让 `subscribe` 变成可变参数的批量形态,
> 再把应用态塞到同一个调用里 —— 那是**把两件事耦进一个方法**,比现在更难读。

```ts
type SyncHello = { sessions: Array<{ sid: string; since: number }>; app: 'foreground' | 'background' };

/** 回答一:完整增量 + 无条件附带的瞬时事实。 */
type SyncDelta = {
  sid: string; from: number; to: number;
  items: TimelineItem[];
  transient: { computer: 'online' | 'offline'; caps: string[] };   // I4:只有这两项
};

/** 回答二:要求基线快照(带原因)。 */
type SyncSnapshotRequired = {
  sid: string; reason: 'window-missed' | 'revision-newer' | 'history-rewritten' | 'no-session';
};

/** 快照响应(可分页):asOfSeq 是基线水位,手机以它为新的拼接点。 */
type SyncSnapshot = {
  sid: string; asOfSeq: number; hasMore: boolean;
  cursor?: string;                    // hasMore 为真时给出;第一版形如 "b:<beforeSeq>"
  items: TimelineItem[];
  transient: { computer: 'online' | 'offline'; caps: string[] };
};
```

规则:

1. **恢复响应永远是两段**:持久增量 + 瞬时事实全量。瞬时事实不随 `seq` 推进,即使 `since` 已是最新也必须重取。
2. **`to` 在请求时刻钉死**。恢复期间 DSH 继续产生事件不影响本轮回答,剩余部分由下一轮取走。
3. 命中任一情况返回 `snapshotRequired`:手机 `since` 大于电脑侧当前 `seq`;区间超出中转窗口且桥接增量缓冲也覆盖不到;电脑侧发现本地历史被重写;会话不存在。
4. **快照分页与拼接**(消除"快照期间丢事件"):
   - 手机收到 `SyncSnapshot` 后,把 `asOfSeq` 记为**待确认基线水位**,并继续用 `cursor` 取下一页直到 `hasMore === false`;
   - 分页期间到达的 `ev` 帧(其 `seq > asOfSeq`)一律**缓存不丢弃、不渲染**;
   - 分页结束后:以快照 items 建立基线 → 合并缓存的 `ev`(按 `seq` 排序、按 itemId upsert)→ 落盘 → 用最后一页的 `asOfSeq` 作为新水位,开始正常渲染。
   - 分页期间若快照请求失败:整轮重来(不半途拼接)。
5. **接收端按 `seq` 去重、按空洞判断**:`seq ≤ 已落盘水位` 的 `ev` 丢弃;出现 `seq > 水位 + 1` 的前向空洞即触发一次 `SyncHello`(结果自然是 `snapshotRequired`)。与 DSH `follow()` 的"跳号即抛错、倒退静默跳过"等价(`packages/api/session-controller/src/history.ts:226-231`)。
6. **中转窗口是缓存不是存档**:默认每会话最近 **1000 条或 30 分钟**(取先到者),允许丢失;丢了走 `snapshotRequired`。
7. 持久增量**可以**由中转窗口给出,但**瞬时事实永远由电脑侧给出**;中转被清空后正确性不变(I7)。

### 5.5 增量缓冲与裁剪

- 电脑侧为每个**被订阅的**会话保留增量缓冲,上限 **16 MiB 或 10000 条**(取先到者;按实测每 turn ≈ 21 事件、单事件中位 253 B 标定,见 `../channel-review-notes.md` §6)。
- 只有**全部配对设备都发过 `persisted` 覆盖该区间**后,才允许裁掉缓冲头部;未确认部分永不裁剪(内存压力下先停推、再要求快照,而不是丢)。
- 桥接重启后缓冲为空:重连一律走 §5.4 的判定,不假装有连续区间。

### 5.6 幂等

- 所有写操作带 `requestId`(手机生成,16 字节 base64url),映射到 DSH 的 `sessionController.prompt({ requestId })`;DSH 侧幂等无跨进程保证,所以**桥接自建去重表**。
- 去重表**持久化、有界、带 TTL**:键 `requestId`,容量 10000,TTL 24 h;命中即回上次结果(不重复执行)。
- **写入顺序是两阶段**:① 先落盘 `in-flight` 标记 → ② 执行 → ③ 成功后改写为 `done` + 结果引用。**不得先执行再记录**——那样崩溃窗口里会丢幂等。去重表写入失败(落盘报错)时**拒绝该写操作**,不进入执行阶段。
- **重启对账**:启动时把 `in-flight` 的键逐一向 DSH 核对(该 `requestId` 是否已随 `user/message` 落在会话日志里,`packages/api/session-controller/src/commands.ts:329-335`):已生效的改写为 `done`,未生效的退回可重发。核对不出结论的键**按未生效处理并重发**——重发是安全的,DSH 侧同一 `requestId` 还会被它自己的 inbox 检查挡一次。
- 审批与提问的应答同样带 `requestId`(形如 `i:<callId>:<decision>`),避免重复应答。

### 5.7 方法表

| 方法 | 方向 | 幂等键 | 说明 |
|---|---|---|---|
| `session.list` | 手机→电脑 | — | 会话清单(别名 + 最近活动 + 状态)。取自 `sessionController.list`(`packages/api/session-controller/src/index.ts:251-254`,已按活动排序);**标题不在这里** —— 该面不返回标题,标题由 `session-title` 提供、且它读的是**活的 `Session` 对象**(落盘-only 的会话拿不到),所以清单先不含标题,手机用 `cwd` 末段 + 相对时间兜底 |
| `session.subscribe` | 手机→电脑 | — | 开始推送该会话的 `ev` / `live`;带 `since` 即同时完成恢复 |
| `session.unsubscribe` | 手机→电脑 | — | 停止推送;桥接可释放该会话缓冲(仍需等 persisted) |
| `session.page` | 手机→电脑 | — | 历史翻页(按消息对齐,用 DSH `page()`) |
| `session.prompt` | 手机→电脑 | `requestId` | **参数是 `{ sid, content, mode? }`**,不是 `{ sid, text }`。`content` 必须是**非空数组**,每项带 `type`(照 DSH 的 `PromptContentPart`:文本是 `{type:'text', text}`)。**形状以电脑侧为准** —— 它与 DSH 的 `sessionController.prompt` 同构,手机侧没有第二条真值。`mode: 'queue' \| 'steer'` |
| `interaction.respond` | 手机→电脑 | `i:<callId>` | 提问 / 计划审查的**答案批次**:`{ sid, callId, answers: [{ id, selected[], custom? }] }`。形状与 DSH 的 `AskUserQuestionAnswer` **逐字一致**,不另造决策枚举(§6.3.1)。**同一个入口也收束在途的审批 claim**:分叉点不在方法名上,而在"这一项是不是一次在途 claim"(§6.2 的判定只有端口知道);审批的"允许一次"编码成 `selected` 含 DSH 的 outcome 值 `allowed-once`(`user-approval/src/types.ts:32`),空 `selected` 且无 `custom` = 拒绝 |
| `session.cancel` | 手机→电脑 | — | 取消当前轮次但保留待处理收件箱 |
| `session.refetch` | 手机→电脑 | — | 取单个大条目 |
| `session.modelCatalog` | 手机→电脑 | — | **只读**的模型目录(按 provider 分组 + 每档 reasoning effort + 部署默认值)。形状与 DSH 的 `modelCatalog` 逐字一致,手机据此建选择器 —— 显示的名字与电脑侧同一份真值,不手抄第二份。**拿不到就明说**(`{available:false}`),不给空数组:空数组会被读成"没有可用模型",而真实原因可能是某个 provider 的 key 没配 |
| `session.select-model` | 手机→电脑 | `requestId` | 切这个会话的模型。**与 Web 用同一个 DSH 方法**(`session-controller` 的 `selectModel`),已核实 Web 侧调的就是它(`packages/client/ui-model-selection/src/client/directory.ts:98`)—— 没有第二套接口。语义(`packages/core/agent-default-model/src/index.ts:82-94` + README):① `agents.selectForNextRequest` 让**当前会话**立即生效(README 原文 "Session-specific selection takes precedence in the consumer");② `saveSelection` 让**以后新建的 agent** 默认用它,且没有 `configEditor` 时是 **no-op**;③ **不改别的会话**。"新会话默认跟随"是 Web 一直有的行为,不是副作用 |
| `session.projections` | 手机→电脑 | — | **一个方法打开全部只读面**。DSH 的 `@Remote('projections')`(`session-controller/src/index.ts:506`)请求体只有 `{sessionId}`,返回**所有已注册投影的当前值**。已核实的键含 `modelSelection` / `permissions` / `subagentCatalog` / `deliverables` / `tokenUsage` / `contextPressure` / `sessionStats` / `turnOutline` / `todos` / `goal` / `plan` / `inbox` / `title` / `workingDirectory` / `agentPreset` / `userQuestions`。**为什么不是每面一个方法**:再开 N 个等于把 DSH 已有的投影面翻译一遍,而"翻译层就是漂移层"——投影改一个字段要跟着改 N 处;只透传这一个口,形状变了只改一处解析。按 `sessionProjections` 能力位挂(缺了方法不出现)。代价是一次响应一大包(20+ 键),若实测太大退路是"只读需要的键",但那要动契约 |
| `permission.catalog` | 手机→电脑 | — | **只读**的权限预设清单。**与 Web 同一个 DSH 方法**：`permissionPresets.catalog()`（`@Remote('catalog')`，`packages/interaction/permission-presets/src/index.ts:292`），形状是 `PermissionCatalog = {options, defaultOptions, defaultPreset}`（`types.ts:26-33`），每项 `{value, name, description?}`。**预设表是部署可配的**（`packages/bundle/base/cordis.patch.yml:262-271` 配了 `read-only` / `workspace-write` / `danger-full-access`），所以名单只能从电脑侧取 —— 手机手抄一份就是第二份真值，电脑上加一个预设手机上永远看不到。拿不到就回 `{available:false}`，**不给空数组**（空数组会被读成"没有可用预设"）。按 `permissionPresets` 能力位挂 |
| `permission.switch` | 手机→电脑 | `requestId` | 切这个会话的权限预设。**写路径是 DSH 的 `/permission <档位>` 斜杠命令**（注册在 `permission-presets/src/index.ts:255-276`；DSH 注释原话 "the one write path a web client uses" 在 `:252-254`），经 `commands.execute` 调它（`interaction/commands/src/index.ts:360` 的 `@Remote`，方法体 `:361`）。**与 Web 同一条路径**：Web 侧 `live.command('/permission ' + preset)`（`packages/client/ui-permission-presets/src/client/index.ts:126`）落到 `remote.commands.execute(sessionId, line, [])`（`session-controller/src/client/sessions/session.ts:388`）。回 `{matched, execution?}`：`matched:false` 是 DSH 回 `undefined`（这台电脑没有 `/permission` 命令，与 Web 的推导逐字一致，`session.ts:390`），`execution` 是 DSH 的 `{commandId, result}` 原样过线 —— 预设名不对时 `result.kind==='error'` 且带 DSH 的原文，手机照显示。**当前值不走这个方法读**：它在 `permissions` 投影的 `{currentValue}`（`permission-presets/src/index.ts:237-244`），随 `session.projections` 到手机。**为什么不放通用的 `command.execute`**：方法名是封闭集、每个方法对应手机上一个看得见的动作；通用命令面会让手机调到移动端没有形态的命令（`/compact`、`/export`、各插件自带的），而 `CommandResult` 只有 `{kind,text}`（`interaction/commands/src/types.ts:34-41`），副作用发生了手机上既呈现不了也撤不回来 |
| `job.list` | 手机→电脑 | — | 任务投影(严格属于该会话的行) |
| `job.follow` / `job.unfollow` | 手机→电脑 | — | 任务输出订阅:`follow({sid, jobId, from?})` → `{from}`(第一帧 output 的起点);同一个 `(sid, jobId)` 重复 follow 幂等,带不同 `from` 则先终止旧订阅。`unfollow({sid, jobId})` → `{stopped}` |
| `job.kill` | 手机→电脑 | — | **走宿主的人类发起门面**(`jobController.kill`):归属围栏由注册表判(`未知任务` 与 `不属于这个会话` **都**归 `job/not-found`),取消原因写宿主的 `cancelled by the user` —— 于是手机点停止与桌面点停止在模型眼里是同一件事。返回 `{ outcome: 'requested' \| 'already-finished' }`,**落终态等 `settled` 事件,不做乐观更新** |
| `settings.describe` / `settings.update` | 手机→电脑 | `requestId` | 读写设置(密钥面见下) |
| `credentials.set` / `credentials.unset` | 手机→电脑 | `requestId` | **单向写面**,无读方法。DSH 侧是 `settings-controller/src/credentials.ts:100` 的 `set(ref, value)` 与 `:113` 的 `unset(ref)`;`value` 是明文(§7.5 的"改密钥只发新值"由此天然成立),而读面 `describe`(:83)**默认脱敏**(`redactSecrets`) |
| `devices.list` | 手机→电脑 | — | 设备管理。**吊销不是方法**:名册的写入方本来就是电脑侧,吊销 = 不再把该设备报进名册 + 本地标 `revokedAt`(§8.2) |
| `sync.hello` | 手机→电脑 | — | §5.4 的恢复握手。**两个职责**:① 一次声明整份订阅集(手机回到前台时要恢复的是"所有会话",不是一个;断线之后 UI 不会重新 `subscribe`,所以恢复由持有连接的这一层发起);② 上报前后台态(`app`)。每个声明的会话都走同一个 `session.subscribe` 的订阅面,不另起一套恢复语义;失败语义与它逐字一致(一个别名未知就整票失败并回 `session/not-found`) |
| `endpoint.describe` | 手机→电脑 | — | **端点自报**:当前可拨的地址表(`{ endpoints: [{kind,url,label?}] }`,`kind` ∈ `relay`/`direct`)。没有直连监听面时这个方法**不出现**(能力位 `caps.direct` 为 false),而不是挂上去回 `connector/unsupported`。手机据此建"连接方式"列表,并在 IP 变了之后自愈 —— 顺序即偏好(`direct` 先于 `relay`)。取舍与被否方案(二维码字段 / mDNS / 手填 / 塞进 `sync.hello`)见 `.agents/notes/implemented/2026-10-14-endpoint-switching-lan-direct.md` |
| `repo.info` | 手机→电脑 | — | 版本、能力位、别名→会话元的映射版本 |
| `session.create` | 手机→电脑 | `requestId` | 新建会话。**与 Web 同一个 DSH 方法**(`session-controller/src/index.ts:280`,请求形状 `{workspaceId?, cwd?, sessionId?, agentPreset?}`,回 `{sessionId, agentPreset?}`)。**`workspaceId` / `cwd` 都不传**:手机侧不知道电脑有哪些工作区(那要另接 `workspace-controller`),而不传时 DSH 用它自己的当前工作区 —— 与 Web 点"新建会话"一致;硬传一个猜的比不传更糟。**只在给了参数时才进请求体**:DSH 对缺省字段有自己的默认,塞空串会被当成"显式选空" |

**没有 `push.configure`**（刻意不声明）。推送本期不做——正确性靠"回前台补课"(I6),
主链路不依赖它。等三端能力包(§10)落地后**再**把它加进方法表;今天声明一个
调不通的方法,只会让手机侧多一个必然失败的按钮。

事件(电脑→手机):`ev`(会话事件)、`live`(流式)、`job`(任务输出,订阅式,§5.3)、`presence`(在线态/前台态)。

**没有 `pending.changed` 帧**。§6.3 的待处理集合是**会话事件的投影**,随 `ev` 一起到手机 ——
审批的 ask 就是一条 `approval/asked` 会话事件(`user-approval/src/index.ts:225`),
提问的 ask 是 `ask_user_question` 的 `tool/call`。电脑侧不另推一份集合:
两份集合必然对不上,而对不上的症状是"电脑在等审批、手机上什么都没有"。
代价如实在 §6.2:`always` 档下一个没订阅该会话的手机看不到卡片,看护会走到超时并 fail-closed。

两条跨方法的规则:

- **带 `sid` 的方法在别名未知时回 `session/not-found`**(§3.1 给它的客户端行为是「从列表移除」)。**不得回空结果**:空列表说的是"这个会话没有数据",而事实是"我不认识这个会话" —— 两者对手机是不同的事(一个是刷新,一个是把这个会话删掉)。
- **`sid` 参数缺失或形状不对 → `protocol/bad-frame`**(它是请求本身不合法,不是数据不存在)。
- **凡宿主已有"人发起"门面的操作,一律走门面,不在插件里复述它的语义**(`job.kill` 是第一个):
  门面里的取消原因、归属围栏与错误码映射都是宿主的,自己抄一遍会在 DSH 改词时**静默分叉**。

### 5.8 未实现方法的 DSH 依据与落地路径(2026-10-09 逐条核实)

已实现的 21 个见连接器处理器表(它是"实现了什么"的唯一出处)。§5.7 的封闭集是 **26** 个方法名,
差额是下面这 **5 个**契约列了、连接器还没接的。每一条都标了 DSH 是否原生支持、出处与落地方式。
**结论:没有一项需要等外部条件。**

| 方法 | DSH 原生? | 出处 | 落地路径 |
|---|---|---|---|
| `session.cancel` | **是** | `session-controller/src/index.ts:472` 的 `@Remote('cancel')`(`cancel(request)` → `commands.cancel`),请求形状 `{sessionId}` | 照形状透传。语义是"取消当前轮次但**保留待处理收件箱**"(`:467-470` 的注释原话)——与 `session.prompt` 的排队/插话是同一块队列面 |
| `settings.describe` | **是** | `settings-controller/src/index.ts:97` 的 `@Remote` | 透传。它默认 `redactSecrets: true`(`:103`)——**密钥值天然不回传**,§7.5 由此成立。入口是 42 项搬运清单(`docs/settings-porting-notes.md`) |
| `settings.update` | **是** | 同上 `:115` 的 `@Remote` | 走 `write` 通道,带 `expectedRevision` 乐观锁(`:121`);过期回 `settings/conflict`(§3.1 的客户端动作是"重新 describe 再改") |
| `credentials.set` | **是** | `settings-controller/src/credentials.ts:100` | 单向写。`value` 是明文(`:26` 的 `min(1)`)——"改密钥只发新值"由此天然成立 |
| `credentials.unset` | **是** | 同上 `:113` | 单向写 |

(`push.configure` 为什么不声明见 §5.7 表后那段。)

**顺带核实到的两个原生能力**(省掉原本要做的设计):

- `userQuestions.attachWait`(`user-questions/src/index.ts:215`,`@Remote({mode:'stream'})`)——客户端可挂一个**等待流**,超时由客户端决定并自动转 pending。手机端可做"实时等回答"而不必轮询。
- `askTimed`(同上 `:229`)——前台等待的首次结算由客户端决定(`ASK_TIMED_OUT` → pending)。DSH 已处理好超时语义。

**因此没有阻塞项**:需要 DSH 的全都有现成接口;不需要 DSH 的本就是我们自己的存储面或恢复握手。

---

## 6. 交互层:审批、提问、计划审查

### 6.1 DSH 侧语义(不可发明)

- 审批与提问都是 **claim-or-delegate 的顺序 waterfall**:*"Return an outcome to claim the request or call `next()` to delegate."*(`packages/interaction/user-approval/src/types.ts:81-82`;提问同构 `packages/interaction/user-questions/src/types.ts:151-152`)。
- 审批结果词汇表封闭:`allowed-once | rejected | cancelled | unavailable`,**唯一授权值是 `allowed-once`**(`user-approval/src/types.ts:32`、`src/index.ts:211`)。→ 手机 UI **不提供**"始终允许 / 本次会话允许";要"本会话不再问"只能改会话级策略(`setPolicy` / 权限预设),且必须明确标注它是"关闭该会话全部审批"。
- `never` 策略在任何 answerer 之前直接 `rejected`(`src/index.ts:269-275`),桥接无法覆盖。
- 撤销语义:abort 立即以 `cancelled` 收束,仍悬空 answerer 的晚到回答被丢弃(`src/index.ts:127-131`)。
- ask 与 outcome **成对进入持久日志**(`src/index.ts:197-204`),且要求 turn 已打开。

### 6.2 仲裁定稿(消除"链首挡住桌面")

桥接注册 answerer,**claim 条件可机械判定**:

```text
claim(请求) :=
     手机开关 == 'always'  且 (存在任一在线设备)
  或 手机开关 == 'foreground' 且 (存在 前台 且 已订阅该 sid 的设备)      ← 默认
```

- **开关三档**,存手机本地并同步到桥接:`never`(只通知,审批仍在桌面答)/ `foreground`(**默认**)/ `always`。
- 默认取 `foreground` 的理由:不改变桌面既有行为(用户离开手机时审批照常在电脑上弹),同时"用户正看着手机"这条最常见的远程场景不被破坏。判定输入(App 前台态 + 订阅关系)都由已认证设备上报,可测。上报载体是 `sync.hello`
(§5.4 的 `app` 字段)+ 连接本身(在线)+ 订阅集变化;电脑侧记在 `connector/src/presence.ts`,
断开即整条作废(订阅集属于那条连接)。
- **多设备并列时的确定性选择**:取"最近一次与该会话交互过的前台设备";若并列,取配对时间最早者。实现必须按此顺序,便于测试。
- **claim 之后**(桥接已独占该请求,桌面看不到——这是 DSH 既有语义,与"两个浏览器同时打开"同构):
  - 把请求推给手机;启动**看护计时器**(默认 **10 min**,可配)。
  - 手机应答 → 返回对应 outcome;待处理项随下一条 `ev` 收敛(`approval/decided` 覆盖 `approval/asked`,§5.2)。
  - 看护超时 / 手机断开 / 会话被替换 → 返回 **`unavailable`(fail-closed,绝不静默放行)**,并留一条"审批在手机上未被处理"的记录。
    **本期只有日志与指标两条出口**:"推一条通知"需要一种电脑→手机的推送帧,而本期没有(见 §5.7 末尾)。
- **产品文案必须如实**:手机接管期间审批不在电脑上出现;要恢复桌面接管,把开关设为 `never` 或让 App 退到后台(`foreground` 档下会自动 delegate)。
- 演进(不在第一版):桥接可带一个 DSH 客户端插件,在桌面界面显示"手机接管中",避免用户误以为审批没弹。

#### 6.2.1 这套仲裁已经解决了"迟到即丢弃"

§6.3.1 说审批在 DSH 侧"迟到应答被构造性丢弃",而本节的设计**正是对它的补偿**,两者不矛盾:

- **看护计时器(默认 10 min)就是那个宽超时**。桥接在 claim 之后自己计时,超时即主动返回
  `unavailable`,**不把决定留给 DSH 的 signal 竞速** —— 于是"用户 3 分钟后才答"这件事被桥接
  提前收口,迟到的回答自然落在"已返回 outcome 之后",与 `:371` 的丢弃语义一致,不会出现
  "半个回合悬着等一个永不到达的应答"。
- 因此**审批转手机在技术上是成立的**,§6.4 的"本期只转提问"是**范围选择**(先把有迟到语义的
  提问转通),不是"审批转不了"。要做的时候按本节实现即可,不需要新设计。
- 反过来,**提问转手机反而没有看护计时器**(它是 fire-and-forget 的投影),超时由 DSH 自己转
  pending —— 所以手机上提问项不置灰(§6.4)。

### 6.3 待处理集合

- **来源是日志,不是内存**:ask 与 outcome 成对落盘,悬空即"有 ask、无 outcome"。桥接启动 / 重连时重放日志尾部重建集合。
- **它没有独立查询方法**:待处理集合是**会话事件的投影**,随 `ev` 帧一起到手机(§5.7 因此没有 `interaction.list`)。要"拉一次当前集合"就 `session.subscribe` 带 `since` —— 恢复语义已经把这件事做完了。
- 电脑侧**不另推一份集合**:审批的 ask 是 `approval/asked` 会话事件、提问的 ask 是 `ask_user_question` 的 `tool/call`,手机从事件投影。两份集合必然对不上(§5.7 末尾)。
- 集合是**持久条目的投影**(I4):有 itemId(`i:<callId>`)、进快照、upsert;不随连接态变化。
- 重建的边界要如实写进产品:只覆盖持久日志里的事件;日志被裁剪或会话被替换时,集合随基线快照刷新。

#### 6.3.1 审批与提问在 DSH 侧的真实机制(2026-10-09 读源码核实)

结论先说:**DSH 没有 `interaction.*` 方法名**;审批与提问是 `packages/interaction/` 下三个服务,且都以**会话事件**为真值。下表是方法表 (§5.7) 与 DSH 实现的对应关系。

| 我们的方法 | DSH 侧真实机制 | 出处 |
|---|---|---|
| `interaction.respond`(审批) | `ctx.approval.request()` 挂起,等应答链(`ctx.waterfall('approval/request')`)给出 `ApprovalOutcome` | `packages/interaction/user-approval/src/index.ts:215`、`:281` |
| `interaction.respond`(提问) | `ctx.userQuestions.ask(...)` / `askTimed(...)`;迟到的回答成为一条 `answer_to_pending_question` 用户消息 | `packages/interaction/user-questions/src/index.ts:187-191` |
| 计划审查 | 提问的一种意图:`AskUserQuestionIntent.kind === 'plan-review'`,带 `approve` 文案 | `packages/interaction/user-questions/src/types.ts:26` |

**提问转手机的完整路径(原生,不发明协议)**:

```text
手机答完 → 连接器 → ctx.get('userQuestions').answer(agent, callId, answerBatch)
                     → 服务把答案 steer 成一条 source 为 user-question-reply 的用户消息
                     → 该消息同时是投影里"这个问题已关闭"的记录
```

- `answerBatch` 就是契约 §5.7 里 `interaction.respond` 的 `answers` 字段,**原样转发**,
  连接器不做翻译(翻译层就是漂移层)。
- 入参是**完整批次**:每个问题恰好一项(`index.ts:178-185` 校验,少一项/多一项都抛
  `BAD_ANSWER`);已回答过再答抛 `REPLY_QUEUED`(`:172-174`)。
- 提问已结束(不在 continued 集合)时 `answer` 返回 `false`(`:168`)——**不是错误**,手机据此
  把那一项标成"已过期",不要弹错误。
- **`state` 决定走哪条路**(2026-10-09 读源码纠正,此前写反了):`continued`(调用已超时)走上面这条
  `answer()`;`open`(阻塞中的调用还在等)走**实时**应答链,而**那条本项目已实现**:
  `connector/src/dsh/interactions.ts` 用 `ctx.on('approval/request')` 与
  `ctx.on('user-questions/request')` 注册两个 answerer(`:118`、`:157`),claim 判据复用
  `protocol/takeover.ts`,并把 asker 的**原** signal 透传(替换它会破坏取消语义,
  `user-approval/src/index.ts:293-306`)。
  **看护超时与断开不在 answerer 这一层** —— 它委托给注入的 `RemoteInteractionPort`
  (`dsh/interactions.ts:55-69`:「实现方负责看护超时与断开,并以 fail-closed 收束」),
  所以**看护计时器的落点是 port 实现,不是 answerer**(装配时别重复挂第二个 answerer)。
  另:空 `selected` 且无 `custom` 是**合法的「显式跳过」**(`tool-ask-user/src/timed.ts:172,179`),
  连接器不得拦截。
- `agent` 参数是 **live root agent**(`assertLiveRoot`,`:131`):子代理里的提问手机答不了(§15 已记)。

三条**对实现有直接影响**的源码事实:

1. **审批无限等,除非 signal 取消**。`decide()` 在 `signal === undefined` 时直接返回那个 Promise(`user-approval/src/index.ts:293`),没有超时;有 signal 时是竞速,`abort` 赢 → `'cancelled'`。**迟到的应答被构造性丢弃**(`:303` 原话 the late answer is discarded by construction)。
2. **fail-closed 是硬规则**:应答链兜底 `'unavailable'`(`:283`),任何应答者抛错或返回野值都归一成它(`:288,291`);`'never'` 策略在 dispatch **之前**就返回 `'rejected'`(`:275`),以防后注册的 `prepend` 听众破坏这个承诺(`:270-274`)。
3. **提问可以超时转 pending,且迟到的回答有定义良好的语义**。计时形态默认 120 s(`tool-ask-user/src/timed.ts:103`),超时不失败而是返回 `{pending: true, callId, message}`(`:156-165`、`:198`),其中 `message` 明说"This is pending, not a skipped answer… The user can still answer"(`:39-42`);`timeout: -1` 则无限等(`:147`、`:203`)。

**由此得到的手机端设计约束**(写进 §6.4):

- **提问/计划审查适合转手机** —— 迟到响应有明确语义(成为用户消息),用户几分钟后才答不会破坏协议。
- **审批转手机要处理"迟到即丢弃"** —— 手机上用户很少秒回。**但 §6.2 的看护计时器(默认 10 min)
  正是对它的补偿**:桥接自己计时、超时主动返回 `unavailable`,不把决定留给 DSH 的 signal 竞速
  (见 §6.2.1)。所以审批转手机技术上也成立,§6.4 的"本期只转提问"是范围选择,不是不能做。

### 6.4 手机端表达

- 审批 / 提问**接管输入栏**(见 `design-and-tech-plan.md` §7.2、§7.8),不占顶栏状态位。
- **一个答案批次形状覆盖全部三种交互**——这是 DSH 的原生设计,不是我们的简化:
  `AskUserQuestionItem` 带一个可选 `intent` 标签,而 DSH 的注释明说
  *"an intent changes presentation only, never the protocol"*
  (`packages/interaction/user-questions/src/types.ts:17-22`)。所以:
  - **提问**:按 DSH 给出的选项(`options`),可多选(`multiSelect`),可填自由文本(`custom`);
  - **计划审查**:同一个形状,只是 `intent.kind === 'plan-review'` 且带一个 `approve` 标签。
    **通过与否由 DSH 的规则决定**:`selected` 里有那个 `approve` 标签就是同意,其余一律拒绝
    (`types.ts:28-30` 原话 "every other option declines it")—— 手机端**不自己判**,
    也就不需要一套「同意执行 / 要求修改」的私有词汇;
  - **审批**:同理走批次;`allowed-once` 只是其中一个选项标签。
- **没有「始终允许 / 本次会话允许」**这类动作:DSH 的 outcome 词汇表是封闭的,
  唯一授权值是 `allowed-once`(`user-approval/src/types.ts:32`)。要"本会话不再问"
  只能改会话级策略,且必须明确标注它是"关闭该会话全部审批"。
- `state` 字段(`'open' | 'continued'`,`user-questions/src/types.ts:72`)告诉手机这一项还能不能答:
  `open` 可以答;`continued` 只能作为新一轮的用户消息到达 —— 手机据此置灰,
  **不因为"看起来超时了"而置灰**。
- 迟到的回答**允许**:提问超时转 pending 后用户仍可答,回答以 `answer_to_pending_question`
  用户消息的形式送达(`user-questions/src/index.ts:191`)。
- **计划审查按提问渲染**:DSH 的 `intent` 只活在应答链的请求对象上,**不进会话事件**
  (`user-questions/src/projection.ts:148-161` 的 `questionsOf` 不映射 `intent`),于是从事件流里
  看不出这是计划审查。手机因此渲染通用提问流 —— 那正是 DSH 自己的投影的行为,而
  *"an intent changes presentation only, never the protocol"*(`types.ts:17-22`)保证答案编码
  完全相同:`selected` 里有那个 `approve` 标签就是同意,其余一律拒绝。

---

## 7. 任务、子代理与能力位

- 任务投影取 `ctx.jobs`(`list:117` / `read:136` / `readAt:148` / `kill:160` / `events.subscribe`,`packages/jobs/jobs/src/index.ts`)。
- **owner 过滤是必须项,且有两个反直觉点**:`list(caller)` 返回的是「该会话自己的 job」**∪「全部无主 job」**(`packages/jobs/jobs-local/src/index.ts:308`),所以桥接要"严格属于本会话"的行必须自己再排掉 `owner === undefined`;而**不传 caller 只返回无主 job**(`packages/jobs/jobs/src/index.ts:113-114`),不是全集。同理 `events.subscribe({ owner: S })` 也会收到无主 job 的事件(`jobs-local/src/events.ts:85`)——按会话分桶时无主任务会同时出现在所有会话里。
- `owner` 无主时是**键整个缺失**,不是一个 `undefined` 值(`jobs-local/src/index.ts:420` 的 spread 写法),跨 JSON 后要用 `'owner' in job` 判断。
- 状态机照抄:`running | stopping | completed | killed | failed`(`packages/jobs/jobs/src/view.ts:19`);停止是"请求",要等 `settled` 事件(`types.ts:206-218`,带 `cause` 与 `awaited`),不做乐观更新。`kill` 对处于 `stopping` 的 job **会再次调用 producer 的 `cancel`**(`jobs-local/src/index.ts:458-468`),别假设只调一次;`reason` 只在终态为 `killed` 时并入 `detail`,否则丢弃(`:584-590`)。
- **读输出只能用 `readAt(id, from, caller)`,绝不能用 `read`**:`read` 会把**模型的** `modelCursor` 推到 `total`(`jobs-local/src/index.ts:444-456`),等于吃掉模型本该看到的输出;终态首读还会把环形缓冲裁到 settled cap。`readAt` 的 caller 是**第三个**参数,省略时只有无主 job 可读。必须处理 `lossy` 与 `gapBefore`(live 只保 256 KiB、settle 后 16 KiB),静默拼接会伪造输出。
- `output` 事件**不带 payload**(`types.ts:219-226`),观察方据自己的游标调度一次 `readAt`;而且 `ctx.jobs.events` **没有任何合并窗口**,append 一次发一次(`jobs-local/src/index.ts:523-524`)——桥接必须自己节流。`flushMs`(100 ms,`observeFlushMs`)与"输出追加不刷新列表"**都是 `dsh-api-job-controller` 的行为**(`packages/api/job-controller/src/index.ts:29`、`src/rows.ts:36-40`),不在 `ctx.jobs` 里。
- 子代理取 `ctx.subagents.listChildren` / `listDescendants`(`packages/subagent/subagent/src/index.ts:374,393`,行号已核实准确)。`activity` 取值是 **`'running' | 'inactive'`**,只表达"会话是否驻留",不表达持久结局(`subagent/src/control-types.ts:26-33`)——已收工的子代理同样是 `inactive`,与"从未成功/崩溃"不可区分,要区分必须叠加 `subagentTiming.lastTurnCompleted`。**`listChildren` 的行里没有 `activity`**,只有 `listDescendants` 的行才有;后者是联合类型,`kind:'diagnostic'` 的行只有 `reason`,没有 `activity`/`mode`/`label`(`control-types.ts:53-70`)。这两个方法**没有 `@Remote`**,浏览器侧调不到,转发到手机需自建 Remote 或改读 `subagentCatalog` 投影。
- **能力位**:`repo.info` 返回 `caps`,由"服务是否存在"决定;手机据此置灰按钮,不用错误码试探。
  - `caps.direct` 是唯一一个**不由服务存在性**决定的能力位:它看连接器的直连监听面起没起来(配了 `listenPort` 且绑定成功)。理由是"这条路存在吗"与"某个 DSH 服务在不在"是两件事 —— 端口被占时监听面起不来,那时必须报 false,否则手机上会多一个必然拨不通的"同一网络"。
  - 判定**必须用 `ctx.get('<key>')`**:裸读 `ctx.sessionController` 在服务缺失或尚未就绪时是**抛异常**(`vendor/cordis/src/reflect.ts:144`、`:159-161`),而 `ctx.get('拼错的键')` 又永远静默返回 undefined(`:237-243`)——两头都不报错,所以服务键要在 `apply` 里自带一次断言与健康上报。
  - 可用的服务键与定义处:`sessions`(`packages/core/session/src/index.ts:953`)、`sessionController`(`packages/api/session-controller/src/index.ts:136`)、`sessionQuery`(`packages/session-query/session-query/src/index.ts:106`)、`approval`(`packages/interaction/user-approval/src/index.ts:156`)、`userQuestions`(`packages/interaction/user-questions/src/index.ts:85`)、`jobs`(`packages/jobs/jobs/src/index.ts:93`)、`schedule`(`packages/schedule/schedule/src/index.ts:121`)、`subagents`(`packages/subagent/subagent/src/index.ts:215`)、`settings`(`packages/settings/settings/src/index.ts:231`)、`credentials`(`packages/credentials/credentials/src/index.ts:172`)、`storageDomain`(`packages/storage/storage-domain/src/index.ts:37`)。
  - **`inject = [...]` 里写了不存在的服务 = fiber 永远 PENDING,无异常、无日志、无 UI 报错**(`vendor/cordis/src/fiber.ts:611-623`、`:625-639`)。这是纯静默降级口子:必需服务才写 `inject`,可选能力一律 `ctx.get` 读出来当能力位。
  - 参考实现用同一模式,但注意它的判定文件在 **bridge 仓库**、不是 DSH 源码:`D:\sudy\github\Agents-Anywhere\dsh-bridge-next\src\host\dsh-runtime\configuration.ts:17-18`。引用时标明来源,别混成 `packages/...`。

---

## 8. 存储边界与 schema

| 数据 | 电脑侧 | 中转 | 手机 |
|---|---|---|---|
| 会话正文 / 工具输出 / 附件 | 权威(DSH 本地) | **不存**,仅在有界窗口内转发密文 | 本地缓存(sqflite;敏感字段应用层加密),按需淘汰 |
| 修订号 | 权威(DSH `seq`,插件不分配) | 只读路由字段 | `lastSeq` 持久 |
| 增量缓冲 / 幂等去重表 | 插件持久化存储 + 有界(§5.5、§5.6) | 有界窗口(密文) | 不适用 |
| 会话别名映射 | 持久(`sid ↔ dshSessionId`) | 只见 `sid` | 只见 `sid` |
| 待审批 / 待回答 | 权威(日志里的 ask/outcome 对) | 不存,只转发 | 从日志重建的投影,不当判据 |
| 瞬时事实(在线态、能力位) | 权威,不落盘 | 只转发在线态 | 只缓存展示 |
| 设备身份种子 / 令牌摘要 | 设备公钥 | 令牌摘要 + 配对记录 | 主种子 + 刷新令牌(系统安全存储) |
| 推送 token / 平台凭据 | 不适用 | 权威(投递所需,持久保存) | 不适用 |
| 推送摘要 | 生成方 | 投递时可见(§9) | 系统通知栏可见 |

### 8.1 电脑侧存储(`ctx.storage` domain KV)

**本节是存储 schema 的唯一出处**;`connector-and-relay.md` §1.4 只写使用纪律,不重复表结构。
域名与表名必须匹配 `^[a-z][a-z0-9_]*$` —— **不允许连字符**(`packages/storage/storage/src/backend.ts:10`)。

```text
dsh_mobile_meta      表 meta        { schema: 1, connectorId, relayUrl, connTokenSecretRef, aliasVersion }
dsh_mobile_devices   表 devices     { devId: { edPub(32B), dhPub(32B), name, pairedAt, pairingId, revokedAt? } }
dsh_mobile_aliases   表 by_sid      { sid: dshSessionId }
                     表 by_session  { dshSessionId: sid }
dsh_mobile_dedupe    表 dedupe      { requestId: { at, status, resultRef } }   // 有界 10000 / TTL 24h
dsh_mobile_windows   表 windows     { sid: { frames: BoundedBuffer, trimmedUpto, lastPersisted } }  // 16 MiB / 10000
dsh_mobile_takeover  表 takeover    { devId: { mode, lastInteractedAt } }
```

- **设备公钥命名照 §4.1**:种子派生的是 Ed25519 身份签名密钥与 X25519 静态 DH 密钥,所以是 `edPub` + `dhPub`;不要写成含义含糊的 `idPub`(那会让人以为是"身份公钥"、与该签名密钥混起来)。
- **`pairingId` 必须随设备一起持久化**:它就是 §12.1 的「配对标识」(配对码的 HKDF 输出),参与 §4.1 的 `info`。每次重连都要用它重算 `master`,所以两端都得存住 —— 手机在安全存储,电脑侧在设备记录里。
- `aliasVersion` 是 `repo.info` 要报的「别名→会话元映射版本」(§5.7);`connTokenSecretRef` 是连接器令牌的凭据引用,**令牌本体走 `ctx.credentials` 具名记录面**(`credentialKey('<包名>','<id>')`)。
- `takeover` 表存每个设备的接管档位与最近交互时间,是 §6.2 仲裁判定的输入。
  **本期实现如实记录**:仲裁的**瞬时**输入(在线、前台、已订阅)只在内存里
  (`connector/src/presence.ts`),进程重启即清零、重连后由连接层重新上报;
  `mode` 是挂载级配置快照(§6.2),`lastInteractedAt` 同样不落盘 ——
  它只喂仲裁排序的一个并列判据,重启后从零开始不影响正确性。落盘的那一张表留作将来的落点。
- schema 版本与迁移写在 `meta.schema`;**不使用** DSH 的会话落盘格式(v4 且仍在演进,见 `../channel-review-notes.md` §2.7)。
- **storage domain 本身没有迁移函数**:介质格式的演进靠声明 —— `version` + `compatibleVersions` + `layout` + `invalidRecords`(`packages/storage/storage-domain/src/spec.ts:35-72`);**业务** schema 的逐代迁移要自己按 `meta.schema` 做。两个号互相独立。

### 8.2 中转存储

```text
pairings(id, pcPubEd, pcPubDh, code_hash, expires_at, consumed_at)
devices(id, pairing_id, dev_pub_ed, dev_pub_dh, name, token_hash, revoked_at)
push_tokens(device_id, platform, token, app_id, updated_at)
window(sid, seq, frame_routing_json, box, received_at)      -- 有界:1000 条/会话 或 30 min
```

- `window` 是**缓存**:允许被清空;清空后正确性不变(I7)。
- 令牌只存摘要;配对秘密只存哈希(而**哈希也不登记**);公开邀请一次性、5 分钟有效。
- **刷新令牌的摘要不在名册里**。轮换流程本期不做(决定见
  `.agents/notes/implemented/2026-10-09-token-and-scope-decisions.md`):设备令牌长期有效,
  轮换等于重新扫码。代价如实说:设备令牌泄露后在手动吊销前一直有效;补偿是吊销可用
  (电脑侧不再把该设备报进名册 + 本地标 `revoked_at`)。刷新令牌本身仍会签给手机并存进
  安全存储——它是**本机凭据**,只是不上中转(中转多存一份没有人读的摘要,只会让人以为
  轮换已经实现)。
- **`devices` 是归属的真值**(不是内存里的 ticket 绑定表):设备重连要能自己回来,所以"这台设备属于哪台连接器"
  必须落在它上面。行的写入方是**电脑侧**(`POST /devices`,只交摘要与公钥),不是中转自己算出来的。
- **本期实现如实记录**:`devices` 的落点仍是**进程内表**;I7 靠**电脑侧每次连上中转时重放名册**重建,
  而不是靠中转自己持久化。换成 SQL 是部署侧的事,接口不变。
- **候选不是设备,永不落这张表**:配对候选只活在它那条受限连接与票绑定里(§12.1),行的 `id` 一律是
  `deviceIdOf(devPubDh)` 的结果。v1 的 `pending:<…>` 临时身份已无生产者。

### 8.3 手机侧(sqflite)

```text
items(item_id PK, sid, seq, kind, payload_json, updated_at)
cursors(sid PK, last_seq, updated_at)
pending(interaction_id PK, sid, kind, payload_json, deadline_at)
jobs(job_key PK, sid, label, status, started_at, updated_at)
outbox(request_id PK, method, payload_json, created_at)      -- 待重发的写操作(幂等键保证安全)
meta(k, v)                                                    -- schema 版本、别名映射版本
```

- 主种子与设备令牌进系统安全存储(§12.2),**不进 sqflite**。刷新令牌一并存下但本期不用(§8.2)。
- 敏感字段(payload 内的正文)按字段级加密;数据库本身依赖系统级文件加密(三端默认开启)。

---

## 9. 推送与前台

推送**只负责敲门,不参与正确性**。四类触发,全部由电脑侧判定:

```text
approval-pending   新待审批        question-pending  新待回答 / 待审查计划
job-settled        后台任务终结     turn-failed       轮次异常结束
```

- **摘要由电脑侧生成与合并**:同会话同类型 60 s 内折叠为一条。
- **两档隐私开关**:`rich`(默认,带最小摘要)/ `doorbell`(只带"有新事件")。如实记录:`rich` 档下摘要对推送通道可见,正文与工具输出始终不可见。
- **兜底**:App 每次回到前台无条件发一次 `sync.hello`(§5.4)。推送丢失 / 重复 / 延迟都不影响正确性。
- **不做静默推送**(三端都不成立:iOS 静默推送被强杀后丢弃、受设备级预算限制;鸿蒙后台消息不唤醒进程;安卓无 GMS 只有厂商通知可用)。
- 心跳:**仅在前台且连接空闲时每 60 s 一次**;任一方向有帧时不额外发,切后台即停。
- 批量合并:电脑侧按 **50–100 ms 或累计 ≥4 KiB** 触发一批,不逐 token 推帧;前台用小间隔,后台不推(后台本来就没连接)。
- 命令与事件同一条连接;请求超时 60 s;结构化错误不关连接。

平台侧硬限制与依据见 §13;心跳取值依据:RFC 5382 REQ-5 规定合规 NAT 的已建立连接空闲超时 **MUST NOT be less than 2 hours 4 minutes**,但 SIGCOMM 2011 的运营商级实测显示 2 h 4 m 在现实中被普遍违反(<5 min 占 5%、5–10 min 占 10%、>30 min 占 66%),故取 60 s(与 Signal 55 s / Syncthing 1 min 同区间)。

---

## 10. 参数表(全部定值)

| 参数 | 值 | 依据 |
|---|---|---|
| 单帧上限 | 8 MiB | 与 DSH 桥接一致,便于两侧同构解析 |
| refetch 阈值 | 封箱后 >1 MiB | 绕开大对象最坏路径;生态中间值(Node ws 100 MiB / Socket.IO 1 MB / Noise 64 KB / DataChannel 建议 16 KB) |
| 批量合并 | 50–100 ms 或 ≥4 KiB | 实测事件中位 253 B、每 turn ≈ 21 事件 → 合并后每帧约 1–4 KB |
| 心跳 | 60 s(前台空闲) | RFC 5382 REQ-5 + NetPiculet 实测 + Signal/Syncthing 对照 |
| 请求超时 | 60 s | 与心跳同量级;超过即认为链路失效 |
| 重连退避 | 1→30 s 指数,抖动 ±20% | 避免惊群;30 s 上界保证"回到前台"能快速恢复 |
| 握手超时 | 10 s | 单次往返 + 签名验签,足够 |
| 流控窗口 W | 128 帧未确认 | ≈ 6 个 turn 的事件量;慢消费者最多积压 128 帧 |
| 中转重放窗口 | 每会话 1000 条或 30 min | 与 EMQX 每会话默认缓存一致;条数与 30 min 取先到者 |
| 桥接增量缓冲 | 16 MiB 或 10000 条 | 10000 × 253 B ≈ 2.5 MB,16 MiB 留 6 倍余量 |
| 快照分页 | 每页 500 条消息 | 照 DSH 客户端 `{ maxMessages: 500, turnWindow: { minMessages, minTurns: 2 } }`(`packages/api/session-controller/src/client/sessions/session.ts:54`) |
| 去重表 | 10000 条 / TTL 24 h | 覆盖"断线重发"的真实时间尺度 |
| 审批看护超时 | 10 min | 覆盖"看一眼手机再决定"的合理上限;超时 fail-closed |
| 任务输出 | 订阅式,每帧 64 KiB | 照 DSH `DEFAULT_OBSERVE_MAX_FRAME_BYTES` |
| 设备上限 | 不设上限 | 每设备一把密钥 ⇒ 吊销粒度小;重新配对即新身份,记录随用户主动重配而增加,清理走管理面 |
| 别名长度 | 16 字节 base64url | AAD 字符集要求 + 不可关联 |
| AEAD | AES-256-GCM | **Electron 不提供 ChaCha20-Poly1305**(见 §4.2 的说明);两运行时都有 + 纯 Dart 可用 |

**算法切换的验收方式**(需要时):真机跑 `1 KB × 100000` 次加解密,记录 p50/p99 与总耗时;nonce、密钥派生与 AAD 规则**不变**,替换一行常量即可。**切换前必须确认目标运行时真的提供该算法** —— 这一条是被 §4.2 那个 Electron 缺 ChaCha20 的事故换来的:选型查了手机端的加速清单,却没查**电脑侧的运行时**。

---

## 11. 故障矩阵

| 故障 | 行为 | 用户可见后果 |
|---|---|---|
| 手机切网 / 休眠 | 连接断;前台自动重连(退避) | 短暂"连接中";回来时按 §5.4 补齐 |
| 电脑侧 DSH 退出 | 桥接进程结束,连接断 | 中转报"电脑离线";只有已缓存内容可看 |
| 桥接重启(插件重载) | 缓冲与去重表从存储恢复;**待处理集合从日志重建** | 无感;审批不消失 |
| 中转重启 / 状态清空 | 手机重连后由电脑侧回答(I7) | 无感(可能多一次快照) |
| 中转不可达 | 手机显示离线;后台只依赖推送 | 无法操作,直到中继恢复 |
| DSH 升级导致插件被跳过 | `skippedBundles` | 手机显示"插件未加载",需升级 connector |
| 手机重装 / 换机 | 无本地历史;重新配对或恢复既有设备身份(若种子已备份) | 需要重新同步;新设备需重新配对 |
| 设备被吊销 / 记录被删 | 换票被拒(401,中转不区分原因)→ `protocol/not-paired` | 手机清凭据、回配对页,写明"这台电脑已不再认可本机,请重新扫码";不退避重连 |
| 会话被删除 / 压缩 | `snapshot` / `no-session` | 该会话消失或刷新为最新基线 |
| 时钟异常(两端偏差) | 协议不依赖两端时钟;仅推送合并与 TTL 用电脑侧时钟 | 无感 |
| 中继被攻破 | 只拿到 `sid` / `seq` / `fc` 与密文 | 无法读内容;设备可吊销 |
| 密文被篡改 / 认证失败 | `protocol/bad-frame`,关闭并重连(重连即换密钥与计数器) | 短暂"连接中";不会把篡改当合法帧 |
| `fc` 违反单调(重放) | `protocol/replay`,关闭并重连 | 同上;重放窗口**只在验签通过后**推进(§4.2) |
| DSH 侧日志被裁剪 | 待处理集合随快照刷新 | 极老的悬空项可能看不到 |

---

## 12. 安全与威胁模型

| 威胁 | 机制 |
|---|---|
| 被动窃听(链路/中继) | TLS + 载荷 E2EE(§4.1),中继只见路由元数据 |
| 主动 MITM(中继替换公钥) | 双向 Ed25519 签名绑定临时公钥;手机只信任**扫码得到的电脑公钥** |
| 重放 | 连接层 `fc` 单调 + 每连接新密钥;会话层 `seq` 去重 + 幂等键 |
| 伪造推送 | 推送只敲门(I6);内容只在 App 内拉取 |
| 设备失窃 | 主种子进系统安全存储(§12.2)+ 解锁/生物识别门控 + 电脑侧可吊销 |
| 中继滥用 | 配对码一次性 + 5 min;令牌只存摘要;按设备限流与审计 |
| 大对象 DoS | 单帧上限 8 MiB + refetch 阈值 1 MiB + 流控窗口 128 帧 |
| 电脑侧越权 | 插件只暴露方法白名单;密钥只有单向写面(`credentials.set/unset`) |

### 12.1 配对(电脑侧发起,一次性) —— v2

1. 电脑侧生成身份(主种子),把 `{中转地址, 电脑标识, 电脑公钥(Ed25519 + X25519), 公开邀请 offerId, 配对秘密 code}` 编成二维码;邀请 + 秘密都是一次性、5 分钟有效,且**两者独立生成、不可互推**。
2. 手机扫码后生成自己的身份,凭**公开邀请 + 候选公钥 + 设备名**向中转换一张一次性票,带票升级后与电脑侧建立一条**受限加密通道**(候选持钥证明):中转只知道公开邀请,**秘密不经它**。
3. 用户在手机上确认(此刻什么秘密都还没发出去)后,手机在密文里提交 `{offerId, code}`;电脑侧校验秘密与候选身份一致,登记设备,**签发设备令牌与刷新令牌**,把两者的**摘要**交给中转(`POST /devices`,连接器令牌鉴权),并在**密文回执**里带上明文。**身份判定由电脑侧做。**
4. 手机把 `主种子 + 设备令牌 + 刷新令牌` 写入系统安全存储;中转只存令牌摘要。

**首配的引导凭据是公开邀请**(第 2 步)。「先有设备令牌才能换票」与「设备令牌是配对的产物」不能互为前提,否则首配无入口;所以 `/ws-ticket` 有**两种形态**:

| 形态 | 认证 | 票绑的身份 | 用途 |
|---|---|---|---|
| body 带 `v:2` + `offerId` + 候选公钥 + 设备名 | **无**(凭公开邀请) | 候选(用途 `pairing`,带候选元数据) | 首次配对(此时还没有任何凭据) |
| body 为 `{}` | **设备令牌** | 名册里的真实设备 + 它的连接器 | **已配对设备的重连**(重连是常态,契约 §2 的退避 1→30 s) |

- **两种形态都吃限流桶**,桶键都不是 IP:候选是"匿名 + 每张邀请"两级,重连是"连接器 + 设备"。
- **公开邀请不因被查过而失效**(它不是一次性凭据):一次匿名试探就能让真扫码的设备配不上对,那是拒绝服务而不是安全。失效只有三种:重新出码(同一连接器覆盖)、TTL 到期、连接器断开。
- **重连不再需要秘密**(它是一次性的、用完即弃):设备令牌在名册里,就能换到票。
- 归属落**中转的 `devices` 表**(§8.2),不是只在内存的 ticket 绑定表;电脑侧重连时**重放名册**重建它,于是 I7「中转可被清空后重启,已配对设备仅凭电脑侧数据收敛」成立。
- **已知缺口(实现未达标,不要当成已成立)**:候选的匿名桶目前是**一个全局桶**,持续刷它能短暂让所有新设备换票 429;§3 要求"无效试探不能使真正的扫码设备失去授权机会",这一条**尚未满足**(见 `.agents/notes/implemented/2026-10-09-pairing-v2-test-migration.md` 的后果一节)。

**两条硬规则**:

- 手机**只信任二维码里带出的电脑公钥**,不接受任何网络下发的电脑公钥。
- 电脑侧对收到的设备公钥做**带外核对**(二维码回显短指纹 / SAS)。v2 里这层是**辅助**:授权来自"二维码固定的电脑身份 + 候选持钥证明 + 秘密校验"三者,而 SAS 由电脑侧在回执里给出,只作两端一致的辅助指纹。不做也不会静默泄密(替换手机公钥会让真手机解不开,表现为连不上),但会把攻击降级成不可检测的可用性破坏。
  - **短指纹(SAS)的定义固定为**:`sha256("dsh-mobile/v1/sas|" + pcPubEd + "|" + devPubEd)` 的前 4 字节按大端读成整数后 `mod 1000000`,补零成 **6 位数字**;两端各自算出同样的 6 位。
- 密钥派生的"配对标识"= 配对秘密的 HKDF 输出,参与 §4.1 的 `info`;定义固定为 `info = "dsh-mobile/v1/keys|" + pairingId`。
  - **`pairingId` 自身的派生(两端必须逐字一致)**:`pairingId = base64url(HKDF-SHA256(ikm = **秘密的哈希**(sha256 十六进制字符串)的 UTF-8 字节, salt = 空, info = "dsh-mobile/v1/pairing", L = 32))`。**它只用于正常业务的握手派生**,不再是授权凭据,也不登记到中转。
  - **候选通道的派生是另一套域**:`info = "dsh-mobile/v2/pairing-keys|"`,临时配对标识 = `offerId`(正式 `pairingId` 要等配对成功才派生得出,候选那一刻不该知道它)。
  - **配对握手上下文进被签的字节**(固定字段顺序,两端逐字一致):
    ```text
    dsh-mobile/pairing/v2 | <offerId> | <pcId> | <pcPubEd> | <pcPubDh> | deviceId | <devPubEd> | <devPubDh> | sha256(<设备名>)
    ```
    中转替换候选公钥、或把 A 设备的 `confirm` 挪给 B 邀请,都会在这里验签失败(电脑侧同一处见 `connector/src/device-connection.ts`)。
  - **换票请求里没有秘密**(§3):`{ "v": 2, "offerId": "<22 字符 base64url>", "devPubEd": "<hex>", "devPubDh": "<hex>", "name": "我的手机" }` —— 秘密只在受限通道的 `pair-commit` 密文里出现,中转全程看不到它。
  - **配对两帧要封箱**(§3):`pair-commit` 的载荷是 `{ "v": 2, "offerId": "<…>", "code": "<…>" }`,`pair-result` 的载荷是回执。v1 的明文 `pair` / `pair-ack` 已删除,旧形状被拒(`426`)。
  - **中转换票与路由靠公开邀请**:电脑侧出码时把 `offerId` 登记给中转(秘密**不登记**);手机换票带同一个 `offerId`,中转据此把票与那台连接器绑定,并**为这次连接生成 `channelId`**,通过控制面向电脑侧要一条数据连接(`relay.open`)。
    - **过期与断线都失效**:登记 5 分钟过期;连接器断开时它全部未认领的登记立即失效(否则设备会拿到一张指向一条已经不存在的连接的票)。
    - **设备必须先换到票才能升级**(`relay/src/server.ts` 的 `/ws/device` 要 `ticket`),受限通道也一样。
  - **设备令牌的签发在电脑侧**(第 3 步):电脑侧生成 `设备令牌 + 刷新令牌`(各 128 位随机、22 字符 base64url),把两者的**摘要**回交中转(`POST /devices`,连接器令牌鉴权),并在 `pair-result` 的**密文**里带上明文。电脑侧重连时**重放名册**让中转重建 `devices` 投影 —— 这正是 I7 的机制。
  - **`pair-result` 的载荷**(封箱;v2 之前是明文 `pair-ack`,因为那时没有会话密钥;v2 里受限握手已经把密钥谈出来了):
    ```json
    { "ok": true, "devId": "<22 字符 base64url>", "sas": "123456", "pcId": "local",
      "deviceToken": "<22 字符 base64url>", "refreshToken": "<22 字符 base64url>" }
    ```
  - **二维码载荷**(就是那段字符串,渲染成什么图形两端各自决定):
    ```json
    { "v": 2, "relay": "wss://…", "pcId": "local", "pcPubEd": "<hex>", "pcPubDh": "<hex>",
      "offerId": "<22 字符 base64url>", "code": "<22 字符 base64url>" }
    ```
    手机**只信任这里带出的 `pcPubEd` / `pcPubDh`**(§12.1 的硬规则:不接受任何网络下发的电脑公钥)。`v: 1` 的码会被拒(`protocol/unsupported-version`)。
  - **配对秘密**:16 字节 base64url(128 位)。它是一次性 bearer 凭据,所以电脑侧**只存哈希**(sha256)+ 过期时间 + 是否已用;而**哈希也不登记到中转**(登记的是公开邀请)。

### 12.2 三端设备私钥的落点与强度(不对等,如实记录)

| 端 | 落点 | 强度 |
|---|---|---|
| 鸿蒙 | HUKS 生成 X25519 + Ed25519(私钥不可导出);主种子不出安全环境 | 最强 |
| Android | Keystore(可强绑定,支持设备解锁门控) | 中上 |
| iOS | Secure Enclave 只支持 P-256 ⇒ Curve25519 只能作 **Keychain 软件密钥**(`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` + 生物识别门控可选) | 最弱 |

- iOS 的弱点是**平台能力上限**,不是实现选择;补偿手段是"每连接新密钥(前向保密)+ 设备可吊销 + 门控"。
- 鸿蒙侧必须**自写 platform channel 接 HUKS**(适配清单里的 `flutter_secure_storage` ohos fork 未见 HUKS 说明,不能推断密钥由 HUKS 保护);若 HUKS 的 X25519 协商在目标机型不可用,降级路径是"用 HUKS 的 AES 密钥包裹主种子"(强度降一档,但绝不回落成明文 preferences)。

---

## 13. 平台侧硬限制(决定实现,不是偏好)

| 平台 | 触达方式 | 硬限制 |
|---|---|---|
| iOS | **alert 推送** | APNs 每 bundle ID 只保留一条、最多 30 天;App 被强杀后不会自动拉起,只能由用户点通知或手动打开;静默推送受设备级 energy/data budget 限制 |
| Android(大陆) | **厂商通道**(华为 / 小米先行) | FCM 不可用(设备普遍无 GMS);通知权限是运行时权限;厂商侧要按"服务与通讯类"报备分类,小米 2026-07-01 起私信必须带 `channel_id` + 模板 ID,vivo 运营消息仅 7:00–23:00 可下发 |
| 鸿蒙 NEXT | **Push Kit 通知消息** | 后台消息**不能唤醒进程**;未申请"通知消息自分类权益"时**单设备每日 2 条**(5 条仅持"互联网新闻信息服务许可证"的新闻类),超发丢弃;系统会在睡眠时段暂缓投递;消息体 ≤ 4096 B;仅中国境内有效 |

- 安卓**不以前台服务保活作为通知保证**:`dataSync` 类型自 Android 15 起 24 小时内累计上限 6 小时,`specialUse` 需 Play 人工审核,Android 12+ 禁止从后台启动前台服务。
- **三端都不做后台长连接**:前台连接 + 系统推送 + 回前台补课,是唯一一套三端都成立的做法。
- 聚合推送(极光等)只统一 API 与统计,**数据面仍走系统 Push Kit**,绕不过鸿蒙频控;它不免除各厂商的账号、模板与分类报备。
- 能承诺的是"打开 App 后状态一定正确",不是"审批必达手机";鸿蒙端只做关键节点通知。
- 渲染与框架侧:`flutter_markdown` 已 discontinued(需选型替代);Impeller 三端后端不同,故口径是"视觉规格一致"而非"像素一致";Dart build hooks / native assets 在 OHOS 上不可用(ohos 工具链调用 native assets hooks 会抛 `FormatException: The OS "ohos" is not known`),需要原生库时走 `plugin_ffi` + `externalNativeOptions` 或预编译 so 打进 har。

依据:iOS [didReceiveRemoteNotification:fetchCompletionHandler:](https://developer.apple.com/documentation/uikit/uiapplicationdelegate/application(_:didreceiveremotenotification:fetchcompletionhandler:))、[Pushing background updates to your App](https://developer.apple.com/documentation/usernotifications/pushing-background-updates-to-your-app)、[Sending notification requests to APNs](https://developer.apple.com/documentation/usernotifications/sending-notification-requests-to-apns);Android [FGS 后台启动限制](https://developer.android.com/develop/background-work/services/fgs/restrictions-bg-start)、[FGS 类型必填](https://developer.android.com/about/versions/14/changes/fgs-types-required)、[FGS 超时](https://developer.android.com/develop/background-work/services/fgs/timeout);鸿蒙 [Push Kit 简介](https://developer.huawei.com/consumer/cn/doc/doccenter-capabilities/push-kit-introduction)、[开通推送服务](https://developer.huawei.com/consumer/cn/doc/doccenter-capabilities/push-config-setting);厂商规则 [阿里云 EMAS 厂商推送规范更新公告](https://help.aliyun.com/zh/document_detail/3010774.html)、[友盟厂商通道限额](https://devs.umeng.com/docs/67966/detail/206973);计费 [个推计费说明](https://docs.getui.com/getui/billing/rules/)。

---

## 14. 验证与验收

1. **fixtures 是唯一规格源**:`node protocol/verify-fixtures.mjs` 校验形状、用参考实现跑出期望,并全局守住 I3 / I4 / I7。两侧实现各自对着同一批 fixtures 跑。
2. **回环**:`node protocol/verify-loopback.mjs` 把三角色真实接线(26 项断言),覆盖在线投递、离线补课、幂等重发、瞬时事实回带,以及"中转状态清空后重启仍能收敛"。其中 `5b` 用例**强制走桥接分支**(游标最新且中转窗口为空),它是"瞬时事实必须回带"的权威断言——relay 分支会旁路 `hello()`。
3. **变异校验**(改断言时必须做):破坏一条不变量,确认断言真的变红。实测基线(2026-09-30):

   | 注入的破坏 | fixtures | 回环 |
   |---|---|---|
   | 中转不检查区间连续性(`relay.mjs` 去掉 `seq !== expected`) | 红(仅 `07-relay-restart-invariant`) | — |
   | 桥接 `hello` 不回带瞬时事实(`bridge.mjs` 的 transient 置空) | 红(`09-transient-facts-always-resent`) | **红**(`5b` 强制桥接分支) |
   | 仲裁判定去掉"前台且订阅"过滤(`takeover.mjs`) | 红(6 条,`16`) | 绿(回环不测仲裁) |

   改断言后若上表任一行不再变红,说明这条不变量失去了保护。
4. **跨端密码学向量**:`protocol/vectors/` 放一组固定 `(seed, ephemeral, nonce, plaintext, aad) → 密文` 的已知答案,TS 与 Dart 两侧都必须跑通——协议层不测加密是对的,但**两侧实现的互操作必须有向量**。
5. **本层不测什么**(有意不覆盖):WebSocket 握手、TLS、真实网络、推送投递——它们归各落地端自己的测试;语义层不得 import 任何加密实现。
6. **真机验收顺序**:Tailscale 直连跑通"发一句 / 回一句" → 审批、提问、任务输出、推送四类链路 → 切自建中转复跑同一组用例 → 三端各过一遍锁屏与强杀场景。

---

## 15. 已知限制(写进产品,不用"以后补"回避)

- 电脑关机 = 手机只能看已缓存部分;推送也发不出(推送必须由常在线的一方发出)。
- 手机换机 / 重装后本机历史不存,需要回连电脑重新同步;种子未备份则需重新配对。
- 电脑侧缓冲 / 中转窗口都有限:长期离线后首次恢复可能走全量快照(实测典型会话快照约 100 KB 级)。
- 任务结算后 DSH 侧的 ring 裁到 16 KiB:更早的输出只能靠手机本地缓存,不承诺"随时能看完整历史输出"。
- 审批看护超时后按 fail-closed 结束(不是静默放行),用户会看到该轮失败。
- 鸿蒙端不做"跑动中进度"表达,只做关键节点通知。
- 子代理里的提问**手机答不了**(DSH 要求 live root agent,`user-questions` 的 `assertLiveRoot`)。
- 待处理集合只覆盖持久日志里的事件;日志被裁剪或会话被替换时随快照刷新。
- **审批的"迟到即丢弃"依赖桥接的看护计时器兜底**。DSH 在 signal 中止后丢弃迟到应答
  (`user-approval/src/index.ts:303`),而手机上用户几分钟后才答是常态。补偿是 §6.2 的看护计时器
  (默认 10 min,超时主动返回 `unavailable`)—— 所以"转审批"要求看护计时器**已实现**;
  在它上线前,手机上只转提问与计划审查(§6.4),不留一个答了可能被丢弃的按钮。
  **推送本期不做**,所以方法表里**没有** `push.configure`——正确性靠"回前台补课"(I6),
  主链路不依赖它;等三端能力包(§10)落地后再加进方法表。
