# 连接器标识：新装随机，老装只在没有配对时迁移

> 已被 `implemented/2026-11-07-connector-id-force-random.md` 取代（2026-11-07）：
> 用户拍板用户少、未宣发，所有 `local` 一律强制迁移，不再保留有配对的老装。
> 本文件结论不改，移入 `archived/` 冻结。

Status: archived

## Problem

2026-11-06 生产：`dsh.0t0.me` 上两个账号的电脑都用旧默认 `local`，令牌表出现两条指向
同一 `connectorId` 的记录；中转重启时按启动校验拒绝启动，停了 4 分钟（`relay/src/token-table.ts`
的 `byConnector` 唯一性）。根因是 `connector/src/index.ts` 把字面量 `local` 作为首装默认值
写进存储，而这个值同时是**中转控制面的连接器身份**（`?id=`），在共用中转上必然跨租户相撞。

候选与被否方案的初稿见 `archived/2026-11-06-connector-pcid-collides-across-tenants.md`。

## Decision

1. **新装生成随机标识** `pc-` + 12 字节 base64url（`connector/src/connector-id.ts` 的
   `newConnectorId()`），首装写进 `meta.connectorId`，之后一直读它。
2. **老装 `local` 只在没有已配对设备时迁移**：设备表为空 ⇒ 没有东西可破坏，顺手换成随机值；
   有已配对设备 ⇒ 保留 `local` 并记一条告警（换它会让所有手机握手 transcript 验签失败，
   等价于全部重新扫码）。
3. **面板显示本机标识**：`GET /api/dsh-mobile/status` 增带 `connectorId`，插件「连接」卡
   展示它。中转「添加我的电脑」的 id 必须与 `?id=` 一致，随机值之后用户没有别处能拿到。
4. 中转管理台「添加我的电脑」不再预填 `local`，提示去插件面板「连接」卡取值。

## Alternatives considered

1. **保持 `local`，只靠 cookbook §6.6 重启前手工检查**
   - 最强的理由：零迁移成本、老用户完全不受影响。
   - 为何被否：新装仍会持续制造冲突；每次重启中转都要人肉查表，事故只是被推迟。
2. **`pcId` 由 `pcSignPubHex` 派生（一台电脑一个稳定 id）**
   - 最强的理由：天然唯一、可重算，不依赖随机数存储。
   - 为何被否：升级时所有老装机的 `pcId` 都会变 —— 等价于全部重新配对；而这次问题
     不需要用"所有用户重扫"来换。随机值同样唯一，且只影响新装。
3. **把中转身份与握手 `pcId` 拆成两个字段（relayId + pcId）**
   - 最强的理由：从根上消除"换中转身份 = 重配"的耦合；老装机也能无痛变唯一。
   - 为何被否（本轮）：中转端按 `connectorId` 键控控制面/名册/额度，拆字段要么做
     `(userId, connectorId)` 复合键（中转大改，安全边界要重审），要么让老装机重新兑换
     令牌（仍可能断线）。本轮先用"新装随机 + 老装告警"止血；若老装机冲突变成常态，
     这条是下一轮的结构性候选。
4. **强制所有 `local` 迁移到随机值**
   - 最强的理由：一次到位，全网唯一。
   - 为何被否：所有已配对手机都要重新扫码；用户没有同意这个代价。

## Consequences

- 收益：新装不再产生 `local`；没有配对的老装自动得到唯一 id；有配对的老装不被静默
  踢回配对页，但会留下一条明确告警。
- 代价：**有已配对设备的老装仍保留 `local`**，多租户共用中转时仍可能在重启时冲突；
  这类装机要按 `docs/cookbook/relay-on-a-server.md` §6.6 清掉一条令牌绑定，或由用户
  主动重新配对换新身份。这不是"已修好"，是"新装不再复发 + 老装可见"。
- 证据：`connector/tests/connector-id.test.ts`（随机形状/迁移边界）、
  `connector/tests/admin-face.test.ts`（status 带 connectorId）、
  `connector/tests/client-panel.test.ts`（连接卡显示本机标识）。
- 生产：本轮没有改线上中转；下次重启 `dsh.0t0.me` 前仍按 §6.6 查令牌表。
