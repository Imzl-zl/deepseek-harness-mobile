# Agent Note: 配对 v2 的测试面迁移（以及三处"被设计删除"的用例）

## Problem

配对 v2（见 `2026-10-08-pairing-v2-and-device-connections.md`）换掉了三样东西：
首配凭据（`codeHash` → 公开邀请 + 候选身份）、连接粒度（一条连接服务多设备 → 每台设备
一条数据连接）、以及帧的回程机制（按 `sid` 广播 / 按帧头 `id` 猜 → 按 `channelId` 成对绑定）。
实现改了，测试面只跟了一半，三个工程同时红：

- `relay`：`pnpm typecheck` exit 2、`pnpm test` 71 项里 39 红（5 个旧测试文件还在调
  `attachDevice` / `claimTicket` / `PairingRegistry.claim` / `tickets.issue(string)`）；
- `connector`：304 项里 5 红（2 条门禁断言过时 + 3 条 v1 流程 e2e 被中转**有意**回 426）；
- `app`：17 个静态错误、12 条测试红（其中 9 条是 `handshake_driver.dart` 一处漏参数
  导致的连锁编译失败）。

## Decision

**迁移，不保留旧机制**：测试改写到 v2 的形状，实现一行不改（除下文点名的两处删除）。

1. `relay/tests/` 8 个文件迁到新 API（`openDevice` / `closeChannel` / `lookup` /
   `DeviceBinding` / 新的桶键），断言强度只增不减：例如"按 `sid` 广播 → 没听众就不投"
   改成"通道绑定即订阅"，并加了一条更强的反面断言（绑定通道上非 JSON 载荷**逐字转发**）。
2. `connector` 的两条门禁按事实更新：
   - **帧类型清单**：契约 §3 的联合类型补 `pair-commit` / `pair-result`、删 `pair` / `pair-ack`
     （唯一一份来源仍是契约，代码只是跟着它）；
   - **每连接耦合面**：`sendPairingFrame` 随 v1 明文配对一起消失，棘轮从 4 个成员收到 3 个，
     并按"棘轮改了就要证明它还会红"做了变异校验（加一个假成员 → 红并点名）。
3. **三处用例按"机制已被设计删除"处置，而不是硬迁**：
   - `connector/tests/relay-keyed-three-party.test.ts`（整文件删除）；
   - `connector/tests/relay-transport-seam.test.ts` 里的"设备经中转抵达连接器"与"往返"两条。

   它们验的是"一个裸 `createConnection` 从 `/ws/connector` 同时承载设备帧，
   回程靠 `sid` / 帧头 `id`" —— 而 v2 明写不这么做（`pairing-v2.md` §2），
   数据连接由连接器收到 `relay.open` 之后自己拨（`connector-and-relay.md` §1.6）。
   同一批不变量现在由 `relay/tests/server.test.ts`（三条真 socket 的双向投递与断开收敛）
   与 `connector/tests/pairing-e2e.test.ts`（真中转 + `createRelayLink` + `createDeviceConnection`
   的握手与 AEAD 双向、多设备、I7 重启）覆盖。
4. **删掉 v1 的死代码**：`relay/src/routing.ts`、`relay/src/protocol-view.ts` 与
   `relay/tests/routing.test.ts`（中转路径早已不经过它们），`pendingDeviceIdOf`
   （`pending:` 形状在 v2 已无生产者）。

## Alternatives considered

- **把旧机制改回来让旧测试变绿**：那正是 v2 要删的东西（多设备共用一条 socket、
  按 `id` 猜回程）。否决。
- **让它们红着并要求实现支持**：门禁的意义是"红=有人要处理"，长期红等于没有门禁。否决。
- **把三条用例改写成 v2 形状**：改写后与 `pairing-e2e.test.ts` / `server.test.ts` 逐条重复，
  两份断言都要维护且会漂移。否决（改为在文件头写明替代覆盖在哪）。
- **保留 `routing.ts` 与它的 7 条测试**：它们只测死代码，制造"有覆盖"的错觉，并会挡住
  后续重构（改一处中转实现要先安抚一个没人走的模块）。否决。

## Consequences

- 项数变化（都是**净减少**，原因见上）：`relay` 79 → 72、`connector` 304 → 301、
  `app` 305 → 340（app 是净增：新加了配对通道与地址边界的用例）。
- 删除发生在"被删除的机制"上，不变量本身没丢；但它**换了一个位置**，所以将来若有人想
  把 `sid` 广播或明文配对加回来，会发现没有现成用例可依靠 —— 这是刻意的：
  那两种形状在 v2 里是被明确否决的。
- `pending:` 前缀与 `isPendingDevice` 保留了（名册里出现旧形状 id 时的防御，一次 `startsWith`）。
