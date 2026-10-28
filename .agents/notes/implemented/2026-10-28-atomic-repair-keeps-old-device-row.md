# 重新配对不删旧行：轮换与"新凭据送达手机"不是一件事

- 日期：2026-10-28
- 状态：implemented
- 取代：`.agents/notes/implemented/2026-10-17-repair-replaces-device-row.md` 中
  "先删旧行再写新行"的那条顺序（"替换而不是攒行"的结论不变）

## Problem

2026-10-28 真机现场：手机显示「这台电脑已不再认可本机（可能已停用，或凭据已失效）」，
随后**自己清掉了凭据**（抽屉变「未配对」）。用户原话："不是说凭证是永久的除非手动删除，
禁用？？"

链路（全部有源码依据）：

1. 重新配对提交的顺序是「删旧行 → 写新行 → 通知中转 → **最后**把新令牌回给手机」
   （`connector/src/pairing-endpoint.ts:106-127` 旧代码）。
2. `pair-result` 可能没送到手机 —— 代码里本来就有这条 warn（`connection-scope.ts:197-199`）。
3. 于是电脑侧只剩新行、手机手里还是旧凭据：既换不到票（401），握手也会被
   `peerOf` 拒（旧 devId 的行没了）→ 关闭码 4003 + `protocol/not-paired`。
4. 手机的契约动作是 `rePair`：清本地凭据 + 回配对页（`connection_recovery.dart:80-90`）。

所以"凭据失效"不是过期，而是**旧的被删了、新的没送到**。旧顺序的注释只考虑了
"崩在中间 ⇒ 这次配对没成"，漏了"服务端成功、客户端没收到"这一档。

## Decision

**提交只写新行，旧行留到新身份真的握手成功再裁。**

- 新行带 `replaces: 旧 devId`（`store/index.ts` 的 `deviceSchema.replaces`）。
- 两行都进名册，中转同时认旧、新两把令牌（轮换期间手机手里那把仍然可用）。
- 新身份握手成功（`connection-scope.deviceEstablished` → `scopeDeps.onDeviceEstablished`）
  时调 `pruneReplaced(devId)`：删掉 `replacedRowsOf` 指出的旧行，再重报名册。
- 幂等：`replacedRowsOf` 是纯函数，只读自己那行的 `replaces`；旧行没了就什么都不做。
- 同一 devId（手机复用密钥）没有两行可留，仍然只覆盖。

## Alternatives considered

- **旧令牌保留 N 分钟宽限**。
  最强理由：不改删除时机，只在名册里多带一个 `prevTokenHash` + 过期时刻，改动面最小。
  被否：宽限期本身是个新参数（多久？谁来清理？），且它只**推迟**孤儿问题；
  而"等新身份连上再裁"用的是已经存在的事实（握手成功），不需要新参数。
- **两阶段提交（新增 `pair-ack` 帧）**。
  最强理由：语义最干净 —— 手机确认落盘后电脑才轮换，任何一方崩都无歧义。
  被否：要动协议帧类型 + 两端状态机 + 契约章节，收益与"等握手成功"重叠，
  当前阶段不值得。若将来出现"手机拿到令牌却不落盘"的反复故障，这是正解。
- **什么都不改，只把报错说准**。
  最强理由：零风险，用户重扫一次就好。
  被否：那正是用户今天拒绝的方案 —— 凭据被清、需要重新扫码，是可避免的破坏。

## Consequences

收益：

1. `pair-result` 丢失不再导致手机失去凭据 —— 它继续用旧凭据连，等下次重配或电脑侧裁剪；
2. 旧行在轮换窗口内仍可用，用户不需要"扫完立刻检查有没有连上"；
3. 管理面板在窗口期内会看到两行（旧行标着被替换），裁剪后自动收敛 —— 这是如实的状态。

代价：

1. 轮换窗口内旧令牌仍然有效：如果旧凭据已泄露，攻击者在这个窗口里仍能用它。
   窗口的结束由"新身份连上"触发，手机端可控；操作者也可直接停用/删除旧行。
2. 新增一个设备字段 `replaces`（可选，旧数据不受影响）。
3. 需要一次 `announce()`：裁剪后重报名册，让中转让旧摘要失效。

## Verification

- `connector/tests/pairing-endpoint.test.ts`：替换后**旧行仍在**、新行 `replaces` 指向旧 devId、
  `replacedRowsOf` 指出的正是那一行、重复提交不写第二行。
- `relay/tests/device-registry.test.ts`：`classify` 区分 ok / revoked / unknown。
- `relay/tests/http-face.test.ts`：401 body 分 `device-unknown` / `device-revoked`。
- `app/test/pairing_client_test.dart`：两类 401 映射到不同动作（revoked → 终态；unknown → 离线重试，
  文案明说"不必重新配对"）。
