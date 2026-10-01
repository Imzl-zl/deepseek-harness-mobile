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
- **I10 中转只读路由元数据**:会话别名、`seq`、`fc` 与帧类型可见;方法名、事件类型、载荷一律不可见。

### 术语

- **会话别名 `sid`**:电脑侧为每个 DSH 会话分配的**不透明路由标识**(16 字节随机,base64url)。它与 DSH 的 session id 解耦,中继据此索引重放窗口,无法关联外部信息。
- **流 `stream`**:一次 assistant 尝试对应的实时输出流 id(电脑侧分配,会话内单调)。
- **看护超时**:桥接代为应答期间等待手机回答的上限。

---

## 2. 拓扑与连接生命周期

```text
[手机 App] ⇄(WSS: 设备身份)⇄ [中转 Server] ⇄(WSS: 连接器令牌)⇄ [电脑侧桥接] ⇄ [DSH]
```

两跳都是手机侧 / 电脑侧**主动连出**:不需要公网 IP、不需要内网穿透、不需要端口映射。中转不主动拨入。

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
- `handshake`:见 §4.1;未完成握手的连接**只接受握手帧**,其余帧一律 `protocol/bad-frame` 并关闭。
- `serving`:进入服务态后,手机无条件发 `hello`(§5.4)补齐状态。
- `backoff`:指数退避,`1s → 2s → 4s → … → 30s` 封顶,抖动 ±20%。**只在 App 前台重连**;切后台主动断开并停表。
- 半开连接:`serving` 期间任一方向连续 2 个心跳周期无任何帧 → 视为断开,重连。

---

## 3. 帧层

行级 UTF-8 JSON,单帧上限 **8 MiB**(与 DSH 桥接一致,便于两侧同构解析)。

```ts
/** 明文头只保留路由、补课与密码学需要的最小字段;方法名、事件类型与内容全在密封载荷里。 */
type Frame =
  // 连接层:握手与保活
  | { v: 1; t: 'hello';       id: string; box: string }
  | { v: 1; t: 'hello-ack';   id: string; box: string }
  | { v: 1; t: 'ping';        fc: number }
  | { v: 1; t: 'pong';        fc: number }
  // 连接层:流控信用(收到即回,不要求落盘)
  | { v: 1; t: 'credit';      fc: number }
  // 会话层:请求 / 应答 / 事件 / 落盘水位
  | { v: 1; t: 'req';  id: string; sid?: string; fc: number; box: string }
  | { v: 1; t: 'res';  id: string; sid?: string; fc: number; ok: true;  box: string }
  | { v: 1; t: 'res';  id: string; sid?: string; fc: number; ok: false; box: string }
  | { v: 1; t: 'ev';   sid: string; seq: number; fc: number; box: string }
  | { v: 1; t: 'live'; sid: string; stream: number; rev: number; fc: number; box: string }
  | { v: 1; t: 'persisted'; sid: string; seq: number; fc: number }
  // 投影:在线态(明文,中继可转发)
  | { v: 1; t: 'presence'; computer: 'online' | 'offline'; app?: 'foreground' | 'background' }
```

规则:

- **`fc` 是发送方向该连接的帧计数器**,从 0 开始,每发一帧 +1(含 `ping` / `credit`)。它是 nonce 与重放防护的唯一来源(§4.2)。
- **`box` = AEAD 密文**,内含方法名 / 事件类型 / 载荷。**`res ok:false` 的错误也封箱**,明文只留帧类型。
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
| `protocol/revoked` | 设备已被吊销(电脑侧删除公钥) | 清除本地凭据,回到配对页 |
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
手机 → 电脑   hello     { box: { ephPubA(32B), devId, nonceA(32B) } }        签名在本帧之后附于 hello-ack 的 transcript
电脑 → 手机   hello-ack { box: { ephPubB(32B), pcId,  nonceB(32B), sigB } }
手机 → 电脑   confirm   { box: { sigA, transcriptHash[0..8) } }              ← 即第一条业务帧
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
- **确认**:收到对方第一条能解开的 AEAD 帧即确认;`confirm` 内的 `transcriptHash[0..8)` 不匹配即断开。
- **每次握手都必须新生成临时密钥对**,不得跨连接复用:复用会让 `fc` 从 0 重数 ⇒ nonce 重用 ⇒ 直接破掉 AEAD。握手失败后的重试同样要重新生成。
- 握手超时 10 s;失败不计入业务重试次数。

### 4.2 计数器、nonce 与重放

- **nonce = 12 字节 = `fc` 的 96 位大端表示**,`fc` 从 0 开始、每帧 +1、**不重用**。
- 不使用随机 nonce:唯一性由计数器保证,不需要 `Random.secure()`(每帧一次系统调用),也不受随机数质量影响。
- **重放防护(连接层)**:接收方维护 `maxFc`;`fc < maxFc` 即 `protocol/replay` 并断开(`fc == maxFc` 只可能来自重复投递,同样拒绝)。因为握手每连接换密钥,重放旧连接的帧必然解不开。
- **乱序**:本层不允许乱序(单 TCP 流本来就保序);任何乱序都视为攻击或故障。
- **算法**:`AEAD = ChaCha20-Poly1305`(默认)。选它的理由:①在 `cryptography_flutter` 的平台加速清单内(Android/iOS 走系统实现);②96 位 nonce 在计数器方案下足够(不需要 XChaCha20 的 192 位随机空间);③纯 Dart 回退也可用。
  - 备选 `AES-GCM`:同一 nonce 规则、同一密钥派生,只换一行常量。鸿蒙侧若实测 AES 明显更快(ARMv8 加密扩展),按 §10 的基准切换,**协议不变**。

### 4.3 流控

- 发送方维护 `unacked`(已发未收 `credit` 的帧数),上限 **W = 128 帧**;达到上限即暂停发送(优先暂停 `ev` 与 `live`,`ping` / `pong` 不占额度)。
- 接收方**每收到一帧立即回 `credit { fc }`**(不要求落盘)——这是**连接层信用**,与会话层的落盘水位是两件事。
- 会话层落盘水位用 `persisted { sid, seq }`:手机**落盘后**才发;电脑侧据此裁剪增量缓冲(§5.5),并允许中转裁剪重放窗口。
- 两层分离的理由:流控要求即时反馈,落盘要求持久确认;混用一个 ack 会让两者互相拖累(等 fsync 才能继续收帧)。

---

## 5. 会话层:修订号、恢复、条目、幂等

### 5.1 修订号与会话别名

- **`seq` 直接取 DSH 会话事件自带的序号**:会话内单调、从 0 连续、永不重编号(`packages/core/session/src/types.ts:493-500`)。
- **`sid` 是电脑侧分配的不透明别名**(§1 术语),桥接持久维护 `sid ↔ dshSessionId` 映射。中继只看到 `sid`。
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

### 5.4 恢复协议

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
| `session.list` | 手机→电脑 | — | 会话清单(含别名、标题、状态、最近活动) |
| `session.subscribe` | 手机→电脑 | — | 开始推送该会话的 `ev` / `live`;带 `since` 即同时完成恢复 |
| `session.unsubscribe` | 手机→电脑 | — | 停止推送;桥接可释放该会话缓冲(仍需等 persisted) |
| `session.page` | 手机→电脑 | — | 历史翻页(按消息对齐,用 DSH `page()`) |
| `session.prompt` | 手机→电脑 | `requestId` | `mode: 'queue' \| 'steer'` |
| `session.cancel` | 手机→电脑 | — | 取消当前轮次但保留待处理收件箱 |
| `session.refetch` | 手机→电脑 | — | 取单个大条目 |
| `interaction.respond` | 手机→电脑 | `i:<callId>:<decision>` | 审批 / 提问 / 计划审查的应答 |
| `interaction.list` | 手机→电脑 | — | 待处理集合(从日志重建,§6.3) |
| `job.list` / `job.follow` / `job.unfollow` / `job.kill` | 手机→电脑 | — | 任务投影与输出流 |
| `settings.describe` / `settings.update` | 手机→电脑 | `requestId` | 读写设置(密钥面见下) |
| `credentials.set` / `credentials.unset` | 手机→电脑 | `requestId` | **单向写面**,无读方法 |
| `devices.list` / `devices.revoke` | 手机→电脑 | — | 设备管理(吊销 = 电脑侧删公钥) |
| `push.configure` | 手机→电脑 | — | 推送档位(rich / doorbell)与令牌登记 |
| `sync.hello` | 手机→电脑 | — | §5.4 的恢复握手 |
| `repo.info` | 手机→电脑 | — | 版本、能力位、别名→会话元的映射版本 |

事件(电脑→手机):`ev`(会话事件)、`live`(流式)、`job.output`(任务输出,订阅式)、`presence`(在线态/前台态)、`pending.changed`(待处理集合变化)。

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
- 默认取 `foreground` 的理由:不改变桌面既有行为(用户离开手机时审批照常在电脑上弹),同时"用户正看着手机"这条最常见的远程场景不被破坏。判定输入(App 前台态 + 订阅关系)都由已认证设备上报,可测。
- **多设备并列时的确定性选择**:取"最近一次与该会话交互过的前台设备";若并列,取配对时间最早者。实现必须按此顺序,便于测试。
- **claim 之后**(桥接已独占该请求,桌面看不到——这是 DSH 既有语义,与"两个浏览器同时打开"同构):
  - 把请求推给手机;启动**看护计时器**(默认 **10 min**,可配)。
  - 手机应答 → 返回对应 outcome;立刻回 `pending.changed`。
  - 看护超时 / 手机断开 / 会话被替换 → 返回 **`unavailable`(fail-closed,绝不静默放行)**,并推一条"审批在手机上未被处理"的通知。
- **产品文案必须如实**:手机接管期间审批不在电脑上出现;要恢复桌面接管,把开关设为 `never` 或让 App 退到后台(`foreground` 档下会自动 delegate)。
- 演进(不在第一版):桥接可带一个 DSH 客户端插件,在桌面界面显示"手机接管中",避免用户误以为审批没弹。

### 6.3 待处理集合

- **来源是日志,不是内存**:ask 与 outcome 成对落盘,悬空即"有 ask、无 outcome"。桥接启动 / 重连时重放日志尾部重建集合,`interaction.list` 返回它。
- 集合是**持久条目的投影**(I4):有 itemId(`i:<callId>`)、进快照、upsert;不随连接态变化。
- 重建的边界要如实写进产品:只覆盖持久日志里的事件;日志被裁剪或会话被替换时,集合随基线快照刷新。

### 6.4 手机端表达

- 审批 / 提问**接管输入栏**(见 `design-and-tech-plan.md` §7.2、§7.8),不占顶栏状态位。
- 动作集合:审批只有「允许一次」「拒绝」;提问按 DSH 给出的选项;计划审查只有「同意执行」「要求修改」(非 approve 一律视为拒绝)。
- 计划审查的 `detail` 是计划全文,`intent.kind === 'plan-review'`。

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
  - 判定**必须用 `ctx.get('<key>')`**:裸读 `ctx.sessionController` 在服务缺失或尚未就绪时是**抛异常**(`vendor/cordis/src/reflect.ts:144`、`:159-161`),而 `ctx.get('拼错的键')` 又永远静默返回 undefined(`:237-243`)——两头都不报错,所以服务键要在 `apply` 里自带一次断言与健康上报。
  - 可用的服务键与定义处:`sessions`(`packages/core/session/src/index.ts:953`)、`sessionController`(`packages/api/session-controller/src/index.ts:136`)、`sessionQuery`(`packages/session-query/session-query/src/index.ts:106`)、`approval`(`packages/interaction/user-approval/src/index.ts:156`)、`userQuestions`(`packages/interaction/user-questions/src/index.ts:85`)、`jobs`(`packages/jobs/jobs/src/index.ts:93`)、`schedule`(`packages/schedule/schedule/src/index.ts:121`)、`subagents`(`packages/subagent/subagent/src/index.ts:215`)、`settings`(`packages/settings/settings/src/index.ts:231`)、`credentials`(`packages/credentials/credentials/src/index.ts:172`)、`storageDomain`(`packages/storage/storage-domain/src/index.ts:37`)。
  - **`inject = [...]` 里写了不存在的服务 = fiber 永远 PENDING,无异常、无日志、无 UI 报错**(`vendor/cordis/src/fiber.ts:611-623`、`:625-639`)。这是纯静默降级口子:必需服务才写 `inject`,可选能力一律 `ctx.get` 读出来当能力位。
  - 参考实现用同一模式,但注意它的判定文件在 **bridge 仓库**、不是 DSH 源码:`C:\sudy\github\Agents-Anywhere\dsh-bridge-next\src\host\dsh-runtime\configuration.ts:17-18`。引用时标明来源,别混成 `packages/...`。

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
dsh_mobile_devices   表 devices     { devId: { edPub(32B), dhPub(32B), name, pairedAt, revokedAt? } }
dsh_mobile_aliases   表 by_sid      { sid: dshSessionId }
                     表 by_session  { dshSessionId: sid }
dsh_mobile_dedupe    表 dedupe      { requestId: { at, status, resultRef } }   // 有界 10000 / TTL 24h
dsh_mobile_windows   表 windows     { sid: { frames: BoundedBuffer, trimmedUpto, lastPersisted } }  // 16 MiB / 10000
dsh_mobile_takeover  表 takeover    { devId: { mode, lastInteractedAt } }
```

- **设备公钥命名照 §4.1**:种子派生的是 Ed25519 身份签名密钥与 X25519 静态 DH 密钥,所以是 `edPub` + `dhPub`;不要写成含义含糊的 `idPub`(那会让人以为是"身份公钥"、与该签名密钥混起来)。
- `aliasVersion` 是 `repo.info` 要报的「别名→会话元映射版本」(§5.7);`connTokenSecretRef` 是连接器令牌的凭据引用,**令牌本体走 `ctx.credentials` 具名记录面**(`credentialKey('<包名>','<id>')`)。
- `takeover` 表存每个设备的接管档位与最近交互时间,是 §6.2 仲裁判定的输入。
- schema 版本与迁移写在 `meta.schema`;**不使用** DSH 的会话落盘格式(v4 且仍在演进,见 `../channel-review-notes.md` §2.7)。
- **storage domain 本身没有迁移函数**:介质格式的演进靠声明 —— `version` + `compatibleVersions` + `layout` + `invalidRecords`(`packages/storage/storage-domain/src/spec.ts:35-72`);**业务** schema 的逐代迁移要自己按 `meta.schema` 做。两个号互相独立。

### 8.2 中转存储

```text
pairings(id, pcPubEd, pcPubDh, code_hash, expires_at, consumed_at)
devices(id, pairing_id, dev_pub_ed, dev_pub_dh, name, token_hash, refresh_hash, revoked_at)
push_tokens(device_id, platform, token, app_id, updated_at)
window(sid, seq, frame_routing_json, box, received_at)      -- 有界:1000 条/会话 或 30 min
```

- `window` 是**缓存**:允许被清空;清空后正确性不变(I7)。
- 令牌只存摘要;配对码只存哈希;`code_hash` 一次性、5 分钟有效。

### 8.3 手机侧(sqflite)

```text
items(item_id PK, sid, seq, kind, payload_json, updated_at)
cursors(sid PK, last_seq, updated_at)
pending(interaction_id PK, sid, kind, payload_json, deadline_at)
jobs(job_key PK, sid, label, status, started_at, updated_at)
outbox(request_id PK, method, payload_json, created_at)      -- 待重发的写操作(幂等键保证安全)
meta(k, v)                                                    -- schema 版本、别名映射版本
```

- 主种子与刷新令牌进系统安全存储(§12.2),**不进 sqflite**。
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
| 设备上限 | 每电脑 8 台 | 每设备一把密钥 ⇒ 吊销粒度小;超过应重配而非堆积 |
| 别名长度 | 16 字节 base64url | AAD 字符集要求 + 不可关联 |
| AEAD | ChaCha20-Poly1305(备选 AES-GCM) | 加速清单内 + 96 位 nonce 足够 + 纯 Dart 回退可用 |

**算法切换的验收方式**(需要时):真机跑 `1 KB × 100000` 次加解密,记录 p50/p99 与总耗时;若 AES-GCM 明显更快则切换——nonce、密钥派生与 AAD 规则**不变**,替换一行常量即可。

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
| 设备被吊销 | `protocol/revoked` | 清除凭据,回到配对页 |
| 会话被删除 / 压缩 | `snapshot` / `no-session` | 该会话消失或刷新为最新基线 |
| 时钟异常(两端偏差) | 协议不依赖两端时钟;仅推送合并与 TTL 用电脑侧时钟 | 无感 |
| 中继被攻破 | 只拿到 `sid` / `seq` / `fc` 与密文 | 无法读内容;设备可吊销 |
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

### 12.1 配对(电脑侧发起,一次性)

1. 电脑侧生成身份(主种子),把 `{中转地址, 配对码, 电脑公钥(Ed25519 + X25519)}` 编成二维码;配对码一次性、5 分钟有效。
2. 手机扫码后生成自己的身份,把 `{配对码, 设备公钥, 设备名}` 经中转转给电脑。
3. 电脑侧校验配对码,记录设备公钥并回执;中转签发设备令牌。**身份判定由电脑侧做,中转只转发与记账。**
4. 手机把主种子与刷新令牌写入系统安全存储;中转只存令牌摘要。

**两条硬规则**:

- 手机**只信任二维码里带出的电脑公钥**,不接受任何网络下发的电脑公钥。
- 电脑侧对收到的设备公钥做**带外核对**(二维码回显短指纹 / SAS)。不做也不会静默泄密(替换手机公钥会让真手机解不开,表现为连不上),但会把攻击降级成不可检测的可用性破坏。
- 密钥派生的"配对标识"= 配对码的 HKDF 输出,参与 §4.1 的 `info`;定义固定为 `info = "dsh-mobile/v1/keys|" + pairingId`。

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
