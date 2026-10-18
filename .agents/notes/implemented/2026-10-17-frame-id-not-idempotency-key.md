# Agent Note: 帧头 `id` 与幂等键是两个标识符 —— 出帧口曾把 `requestId` 写进帧头

Status: implemented

## Problem

2026-10-17 全量门禁时 `flutter test` 两条红（`电脑侧拒绝（ok:false）照原样抛`、
`同键重发不建第二个等待`），都是同月刚加的带键写用例。两条红的报错都是
`ProtocolException(relay/offline): 连接已断开，在途请求被取消`，栈是
`_onLine → _protocolFailure → _enterClosed → CallRegistry.failAll`。

追下去不是测试写错：用例喂的 `res` 帧 `id` 是 `i:c1`（`interaction.respond` 的
幂等键，契约 §5.7 规定的形状），而 `decodeFrame`（`app/lib/core/frame.dart:283`）
按契约 §3 的 `ID_PATTERN = ^[A-Za-z0-9_-]+$` 校验帧头 `id` / `sid`，**冒号不在字符集里**，
于是这一帧被当成坏帧、连接被关。

顺着查到线上：`sync_client_impl.dart` 的出帧口（`attachSender`）把帧头 `id` 直接写成
`entry.requestId`。也就是说**生产里每次点「允许一次 / 拒绝 / 同意执行」，手机发出的
`req` 帧头 `id` 都带着冒号**，连接器按 `protocol/bad-frame` 拒收并关连接
（`connector/src/transport/codec.ts:118` 的 `ID_PATTERN`，收帧处
`connection.ts:539,571`）。我用连接器自己的解码器实测过：

```
i:c1    => REJECTED protocol/bad-frame | id 不是 ASCII 安全字符集：i:c1
abc-123 => ACCEPTED
```

症状与 `docs/postmortem/2026-09-30-approval-answer-silently-dropped.md` 记载的
"队列不推进、面板不消失、看起来像已经生效"**逐字相同**；那篇复盘把根因归给
`interactions.js` 裸调 `haptic()`，那是原型侧的另一处断裂，**本条是同一个用户可见
症状在真机链路上的第二个、且更根本的成因**（原型修好之后，真机上仍然点不动）。

三条纪律本来都写着，是**实现违反了它们**：

- §I10（`remote-channel.md:28`）：帧头 `id` "只关联端点请求与应答"；
- §5.6（`:359`）：`requestId` 是信封里的幂等键；
- 术语表（`:36`）："给同一个字段第二个含义，正是 `credit` 那一处已经否掉的做法"。

而 §5.6 原文还把 `requestId` 描述成"16 字节 base64url"——这句话**只对默认形状成立**，
业务键 `i:<callId>` 不在其内，读者由此误以为"键永不上帧头也没事"。文档侧同因。

## Decision

把两个标识符拆开，各归其位：

1. **`OutboxEntry` 增加 `frameId`**（帧头 `id`），`requestId` 保持不变。
   帧号**不落盘** —— 它只关联一个**活的**完成器，进程没了调用方也没了，旧帧号无人等待；
   从盘上恢复的旧行由 `Outbox.restore` 补铸（原调用方已随上一个进程消失）。
2. **出帧口写 `entry.frameId`**，`requestId` 仍旧只进信封顶层。
3. **帧号由调用方在 `flush()` 之前铸**，因为 `res` 只在帧写出去之后到达 ——
   登记晚于它就等于把应答当成"迟到的"丢掉、调用方永远挂着。队列自己不铸：它铸了
   也没人来得及登记。
4. **`CallRegistry` 判据从"帧号"改成"幂等键"**（`isPendingRequest`）：每次重发都会
   换一个新帧号，按帧号判就会漏。条目带上 `requestId`（只读方法没有）。
5. **`enqueue` 同键从"无操作"改成"用新条目替换"**：排着队而没人等的同一键只可能是
   上一次尝试的残留（那次抛了 `relay/offline`，已撤销在途登记）。键不变 ⇒ 电脑侧仍然
   去重；帧号换新 ⇒ 这次的调用方能被兑现。落盘顺序也顺带修正为先落盘后进内存镜像
   （原先先加内存再落盘，落盘抛错时队列里留着一条盘上没有的条目 —— 既有用例
   「落盘失败即拒绝入队」当场抓住）。

文档同步：`remote-channel.md` §5.6 写明 `requestId` 只活在信封里、形状由业务定、
帧头 `id` 是另一个标识符；§5.7 的 `i:<callId>` 补一句"键形状由业务定"。
另删掉 `outbox.dart` 里死掉的 `encodeRequest`（与 `sync_client_impl.dart` 的
`encodeRequestEnvelope` 是同一份线上形状的两个编码器 —— 正是这次漂移的土壤）。

## Alternatives considered

1. 放宽 `ID_PATTERN` 允许冒号（两端 + 49 条跨端向量 + 契约 §3 一起改）
   - 最强的理由：改动最小，`i:<callId>` 直接就能上线。
   - 为何被否：字符集的存在理由是"AAD 是把字段拼串再哈希，两端 JSON 转义习惯不同"
     （`frame.dart:86-90`）。冒号本身确实不需要转义，但这一放宽会把"AAD 输入必须
     与转义无关"这条纪律的口子撕开，而**收益为零** —— 帧号本来就可以另铸。
     为迁就一个坏约定去改密码学边界，方向是反的。
2. 把 `requestId` 的形状改成字符集安全的形式（如 `i-<callId>`）
   - 最强的理由：`id` 与键继续共用，`call()` 一行不用动。
   - 为何被否：`i:<callId>` 是契约 §5.7 规定的形状，连接器侧 `interaction-face.ts`
     与投影面的 `itemId` 都按它认；改形状要么改契约（牵连文档、用例、投影），
     **要么只改手机一侧**——那就是又一处"两侧各写一遍"的漂移源。且它治的是症状：
     只要帧头 `id` 还允许被业务键占用，下一个带冒号的键（或任何非 ASCII 安全形状的键）
     会再次击穿。
3. 让 `res` 信封回带 `requestId`，帧头 `id` 就纯粹当路由令牌
   - 最强的理由：关联改由信封承担，帧号可以每次重发都换，语义最干净。
   - 为何被否：`ResponseEnvelope` 现在是 `{ok,result}` / `{ok,code,message}`
     （`connector/src/protocol/methods.ts:149`），加字段要改跨端契约；而帧头 `id`
     回显已经是 `resFrame` 的既定行为（`method-face.ts:81`），**不需要新机制**。
     在一个已经够用的机制上再加一层，是净复杂度。

## Consequences

- 收益：真机上点审批/提问答复不再把连接打死；`interaction.respond` 的
  "失败照原样抛 → 调用方把那一项标成已过期"这条链第一次真正接通
  （旧行为里 `res {ok:false}` 在返回前就被丢掉，电脑侧的拒绝从来到不了 App）。
  顺带修掉一个并发窗口：判据与登记之间原先有一个 `await`（落盘），两次并发调用
  会都通过判据、后一个覆盖前一个的完成器。
- 代价：`OutboxEntry` 多一个字段，且它**不落盘**，于是恢复路径要补铸
  （`restore` 一行 + 一条用例）。这是"帧号是活完成器的关联符"这一语义的直接后果，
  比"把它落盘、再处理旧帧号"少一整类问题。
- 代价：帧号与幂等键从此是两个概念，读代码时要分辨。已在两处的 docstring 里
  互指，并用一条遍历生产全部键形状的用例把"业务键永不上帧头"钉成不变量。
- 观测点：`app/test/sync_client_test.dart` 的「帧头 id 与幂等键是两个标识符」
  （遍历 `app_model.dart` 六处键形状 + 契约的 `i:<callId>`）、
  「从盘上恢复的旧行没有帧号」、「同一幂等键重复入队：只留一条，且换成新条目的帧号」。
  变异校验：把出帧口改回 `entry.requestId`，恰好 4 条变红，还原后全绿。
- 遗留（未修，有证据）：第一次应答已收完之后再来一次同键调用，电脑侧会从幂等缓存
  回一份 `res`，其帧头用的是**第一次**的帧号，而这次登记的帧号等不到它 —— 会挂到
  `failAll`。UI 上不可达（卡片settle 后按钮消失），且与本次修改前的行为相同，
  故不在本条范围内；真要修得让 `res` 信封回带 `requestId`（见备选 3）。
