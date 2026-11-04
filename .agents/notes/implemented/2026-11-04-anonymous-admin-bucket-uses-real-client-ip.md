# 同一次请求里，"来源地址"只能有一个答案

- 日期：2026-11-04
- 触发：评审——`server.ts` 的 `/admin*` 分支里，锁定按 `clientIp` 计、限流按裸 socket 地址取桶
- 状态：implemented

## 背景

反代（Caddy）后面，`request.socket.remoteAddress` 全是反代自己的地址。这个分支里同时存在两套取值：

```
const clientIp = clientIpOf(headers, request.socket.remoteAddress, trustProxy)   // 认 X-Real-IP
options.lockout?.stateOf(`admin:${clientIp}`)                                    // ← 用它
limiter.take(`admin-anonymous:${request.socket.remoteAddress}`)                  // ← 也用它？不，用裸地址
```

后果：`trustProxy: true` 的部署里，**所有**未认证的管理面请求共用一个匿名桶。
默认桶是 `capacity 60 / refill 6/s`，一次扫描或者一个页面轮询就能把所有人的额度打光 ——
症状是"管理台偶尔整个 429"，而 401/403 那几条判据全都正常。

## 决定

`admin-anonymous` 的桶键改用同一个 `clientIp`。

## 被否掉的

- **保持裸 socket 地址**（`rate-limit.ts` 头注写过"反代后面退化成一个全局桶，与不分来源等价，不更坏"）：
  那条判断在 11-03 之前成立 —— 当时这个分支只有限流。同一批改动给管理面加了
  **连续失败锁定**，而锁定必须按真实来源算（否则一次爆破把管理员自己也锁 15 分钟）。
  于是同一个请求里出现了两套"来源"，比"退化成全局桶"更糟：**同一个事实有两个答案**。
- **`clientIpOf` 无条件认 `X-Real-IP`**：等于信任任何客户端自编的头，换一个头就换一个桶，
  限流等于不存在。信任是部署决定，仍旧只由 `trustProxy` 打开。
- **在这里再写一遍 IP 解析**：同一条判据的第三份副本；`clientIpOf`（`accounts/session.ts`）是唯一出处。

## 代价

`trustProxy: true` 且反代没覆盖 `X-Real-IP` 时，客户端能自编来源地址换桶 ——
这与锁定的信任前提**完全一致**（同一个配置项、同一条部署要求），没有引入新的信任面。

`/connector/enroll` 的匿名桶**不动**：那一跳的语义是"还没有任何身份、连设备都还不算"，
`rate-limit.ts` 头注明确接受它在反代后退化成全局桶。两处不同答案是有意的，不是漏改。

## 验证

- `relay`：`tsc --noEmit` 0，`node --test` **166** 条全绿（新增 1 条）。
- 新增用例把桶压成 `capacity: 1, refillPerSecond: 0`，两次请求就能看出是不是同一个桶：
  同一来源第二次 429（桶确实生效）、**另一个来源仍是 401**。
- 变异校验：把桶键改回 `request.socket.remoteAddress` → 恰好那 1 条红
  （`别的来源不该被它打光的桶连坐`），其余 10 条全绿；还原 → 全绿。
